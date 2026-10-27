# 構成と通信

[README](../README.md) / [事前確認](prerequisites.md)

## 対象と役割

| 場所 | 対象 | 役割 |
|---|---|---|
| 既存 Azure 環境 | Windows VM | Azure VM のマネージド ID と AMA でログを収集する |
| hub | DNS Private Resolver の Inbound endpoint | オンプレミスからの DNS クエリを受信する |
| hub | AMPLS 用 Private Endpoint | AMA の設定取得・ログ送信先への閉域接続 |
| hub | Arc PLS 用 Private Endpoint | Arc の管理先への閉域接続。AMPLS の PE とは別 |
| hub | Azure Firewall Standard または Premium | Explicit Proxy として Arc の公開宛先への HTTPS を許可する |
| hub（講師用ラボ） | Azure Bastion Standard | Peering 経由で workload、DNS、L1 の Private IP へ RDP 接続する |
| オンプレミス | 既存 Windows DNS Server | 7ドメインの条件付きフォワーダーを追加する |
| オンプレミス | Windows Server | Connected Machine agent と AMA を導入する |
| VNet 外の論理リソース | LAW、DCE、DCR、AMPLS、Arc PLS | データ格納、収集定義、接続範囲を管理する |

LAW は Log Analytics Workspace、DCE は Data Collection Endpoint、DCR は Data Collection Rule の略です。AMPLS と Arc PLS は別のサービスです。DCR は収集するデータと送信先を定義します。Heartbeat は AMA の稼働に伴って収集される情報で、Windows Event の DCR とは別に確認します。

## 通信を分ける

| 通信 | 経路 | 設定 |
|---|---|---|
| Azure VM / オンプレミス AMA の設定取得・ログ送信 | AMPLS PE へ直接 HTTPS | AMA `proxy.mode=none`、DCR / DCE の関連付け |
| Arc の HIS / Guest Configuration | Arc PLS PE へ直接 HTTPS | `proxy.bypass=Arc`、Arc PLS への関連付け |
| Arc の Entra ID / ARM 等の公開宛先 | AzFW Explicit Proxy → HTTPS の宛先 | `proxy.url=http://<FW のプライベート IP>:3128` |
| オンプレミスからの対象7ドメインの DNS | Windows DNS → Inbound endpoint → Private DNS zone | 条件付きフォワーダー |
| インストーラー取得 | ダウンロード処理で明示的に Proxy を指定 | Agent 設定の適用前に確認する |
| 講師の VM 操作 | 管理端末 → hub Bastion → 各 Azure VM | 端末から HTTPS / 443、Bastion から Private IP の RDP / 3389 |

必要な公開通信の出口を明示 Proxy に限定し、Arc Agent 固有の設定で通信させます。既存オンプレミスの既定経路と OS 全体の Proxy 設定は維持してください。Firewall への転送は Agent の Proxy 指定で行います。

AzFW の Explicit Proxy は Firewall Policy で有効化します。HTTP の同じ待受ポートが HTTP と HTTPS の要求を受け付け、HTTPS では CONNECT を使用します。Firewall Policy の Application rule で、必要な FQDN と宛先ポートを許可します。待受ポート `3128` と宛先 HTTPS の `443` をそれぞれ設定してください。Agent に Proxy URL を直接指定し、TLS は Agent と接続先の間で終端します。TLS 検査による証明書の置き換えは Agent の接続を失敗させるリスクがあるため、これらの通信には適用しないでください。

## 名前解決の対応表

Windows DNS の条件付きフォワーダーには、次の表の公開ドメインを指定してください。公開名からの CNAME 解決を経て、PE の Private IP に到達させます。

| 条件付きフォワーダー | hub にリンクする Private DNS zone | 対象 |
|---|---|---|
| `his.arc.azure.com` | `privatelink.his.arc.azure.com` | Arc PLS |
| `guestconfiguration.azure.com` | `privatelink.guestconfiguration.azure.com` | Arc PLS |
| `monitor.azure.com` | `privatelink.monitor.azure.com` | AMPLS / DCE |
| `oms.opinsights.azure.com` | `privatelink.oms.opinsights.azure.com` | AMPLS |
| `ods.opinsights.azure.com` | `privatelink.ods.opinsights.azure.com` | AMPLS |
| `agentsvc.azure-automation.net` | `privatelink.agentsvc.azure-automation.net` | AMPLS |
| `blob.core.windows.net` | `privatelink.blob.core.windows.net` | AMPLS に必要な対象レコード |

AMPLS の PE は複数の IP を使用します。PE の DNS 構成画面に表示された実際の FQDN と IP をすべて記録し、各 FQDN の応答を検証してください。`blob.core.windows.net` の転送では、Private DNS zone に登録された対象のレコードを PE の IP に解決します。それ以外の既存 Blob サービスについても、名前解決と利用状況を変更前後で比較してください。

Inbound endpoint が配置された hub VNet に zone をリンクします。このサンプルの転送方向はオンプレミスから Azure です。Resolver は Inbound endpoint を使用します。

## お客様環境と任意ラボの違い

お客様は既存の ExpressRoute 等で、オンプレミスから hub の DNS / PE / Proxy に到達できることが前提です。①の任意ラボは VNet Peering でこの到達性を代用します。ExpressRoute の帯域、ゲートウェイ、経路伝播、SLA は、お客様の実際の接続環境で評価してください。

任意ラボでは Azure VM 内に Hyper-V を構成し、その L2 ゲストだけを Arc に登録します。L1 ホストは Azure VM として管理します。L2 は Internal vSwitch と WinNAT を使用し、Azure / Azure Local IMDS への接続を遮断します。この構成は Azure 内の評価用です。本番環境への適用時は、実際のサーバーと接続方式に合わせて設計してください。

講師用の管理接続には hub の `AzureBastionSubnet`（`10.20.3.0/26`）へ Bastion Standard をデプロイします。ブラウザーから3台の Azure VM を操作し、ファイル転送には有効化済みのネイティブ RDP 接続を使います。L2 は L1 の VMConnect / PowerShell Direct を使用してください。Bastion と Firewall はそれぞれ専用 Public IP を持ち、VM は Private IP で管理します。お客様が既存環境で②③を実施する場合は、既存の承認済み管理接続を使用してください。

## 最小変更として評価する項目

1. 既存 Windows DNS への7条件付きフォワーダー追加。
2. 対象サーバーへの Arc 導入・登録と、Arc 固有の Proxy / bypass 設定。
3. 対象サーバーへの AMA 拡張機能導入、直接接続の指定、DCR / DCE 関連付け。
4. DNS、PE、Proxy への到達を許可する既存 Firewall 等の設定。
5. Azure 側の AMPLS、Arc PLS、PE、DNS zone、収集リソースの準備。

「最小変更」は実機検証で確定する結果です。既存の監視、DNS、更新経路によって追加の調整が必要になる場合があります。

## 根拠

- [Azure Firewall Explicit Proxy](https://learn.microsoft.com/azure/firewall/explicit-proxy)
- [Arc の Proxy / bypass](https://learn.microsoft.com/azure/azure-arc/servers/manage-agent-proxy-settings)
- [Arc Private Link](https://learn.microsoft.com/azure/azure-arc/servers/private-link-security)
- [AMA のネットワークと Proxy](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
- [AMPLS の設計](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-design)
- [Bastion と VNet Peering](https://learn.microsoft.com/azure/bastion/vnet-peering)
- [Bastion のネイティブクライアント](https://learn.microsoft.com/azure/bastion/native-client)
