# ③ オンプレミス Windows Server を Arc PLS と AMPLS に登録する

[README](../README.md) → [② Azure VM](02-azure.md) → ③ → [結果の確認](validation.md)

## この章の完了条件

- Arc の HIS / Guest Configuration への通信は Arc PE に直接接続する。
- Arc の必要な公開通信は AzFW Explicit Proxy を使用する。
- AMA は Proxy なしで②の AMPLS に直接接続し、同じ LAW に新規イベントを送る。
- 対象サーバーからの直接の公開通信を遮断しても、上記の収集が成立する。

実オンプレミスの Windows Server と既存 Windows DNS を使う場合、①は不要です。任意ラボは L2 ゲストだけで実施します。L1 ホストを Arc に登録せず、L1 の IMDS / Azure VM Agent を変更しません。

## 3-1. Arc Private Link Scope と専用 PE を作成する

操作場所は Azure Portal です。

1. 「Azure Arc Private Link Scopes」を検索し、「作成」を選びます。
2. 承認したサブスクリプション、作業用 RG、名前 `arcpls-handson`、②と同じリージョンを指定します。
3. 「パブリック ネットワーク アクセスを許可」をオフにします。
4. 「Private Endpoint」で新規 PE `pe-arc-handson` を作ります。hub VNet と PE subnet、Private DNS 統合を選びます。
5. 別画面から PE を作成する場合、対象は `Microsoft.HybridCompute/privateLinkScopes`、作成した Arc PLS、サブリソースは `hybridcompute` です。AMPLS の `azuremonitor` と混同しません。
6. 次の zone と DNS zone group を確認します。

   ```text
   privatelink.his.arc.azure.com
   privatelink.guestconfiguration.azure.com
   ```

7. zone の hub VNet へのリンクを確認します。PE 接続が Approved であることと、PE の「DNS の構成」にある FQDN / Private IP の一覧を記録します。

**期待結果**: AMPLS PE と Arc PE が別々に存在します。Arc PLS の publicNetworkAccess が Disabled です。Arc リソースと Arc PLS は同じリージョンで作成します。

同じ VNet / DNS 解決範囲で Private Link を使用する Arc と、Private Link を使用しない Arc を混在させる場合、既存サーバーの名前解決に影響します。承認した対象外の Arc がある場合は、ここで作業を止めて設計を確認してください。

## 3-2. 既存 Windows DNS に条件付きフォワーダーを追加する

操作場所は既存 Windows DNS サーバーの「DNS マネージャー」です。AD 統合 DNS の場合、複製先の全 DNS 利用者に影響することがあります。

1. 事前確認で記録した既存条件付きフォワーダー、zone、既定フォワーダーの値を再確認します。
2. 「条件付きフォワーダー → 新しい条件付きフォワーダー」を選びます。
3. 次の7件を1件ずつ設定します。転送先 IP はすべて hub Resolver Inbound IP です。

   | DNS ドメイン | マスター サーバー |
   |---|---|
   | `his.arc.azure.com` | `<Resolver Inbound IP>` |
   | `guestconfiguration.azure.com` | `<Resolver Inbound IP>` |
   | `monitor.azure.com` | `<Resolver Inbound IP>` |
   | `oms.opinsights.azure.com` | `<Resolver Inbound IP>` |
   | `ods.opinsights.azure.com` | `<Resolver Inbound IP>` |
   | `agentsvc.azure-automation.net` | `<Resolver Inbound IP>` |
   | `blob.core.windows.net` | `<Resolver Inbound IP>` |

4. AD への保存・複製範囲は、承認された既存 DNS の運用方針に合わせます。ハンズオンの都合で「フォレスト全体」を選ばないでください。
5. 同名の既存 zone / 条件付きフォワーダーがある場合、削除して作り直しません。既存と希望値を照合し、担当者の承認がなければ停止します。
6. L2 / 実オンプレミスの対象サーバーの DNS は、**既存 Windows DNS**を指定します。Resolver IP へ直接向けて済ませないでください。
7. 対象サーバーで、実際の Arc PE / AMPLS PE の各 FQDN と、既存業務の監視名・Blob 名を解決します。

   ```powershell
   Get-DnsClientServerAddress -AddressFamily IPv4
   Resolve-DnsName '<Arc PE の実際の FQDN>' -Server '<Windows DNS IP>'
   Resolve-DnsName '<DCE 構成アクセス FQDN>' -Server '<Windows DNS IP>'
   Resolve-DnsName '<Workspace ID>.ods.opinsights.azure.com' -Server '<Windows DNS IP>'
   ```

**期待結果**: 対象サービスの最終 A レコードが PE の IP です。既存業務の名前解決結果と疎通も変更前どおりです。DNS の GUI が Inbound endpoint を権威 DNS として検証できない場合もあるため、GUI の検証表示だけでなく実クエリを確認します。

この変更だけで Arc / AMA の Proxy 設定は変更されません。問題が発生したら[切り戻し](cleanup.md)を行い、既存業務を優先します。

## 3-3. AzFW Explicit Proxy を設定する

操作場所は Azure Portal の **Firewall Policy** です。Firewall 本体の IP を Proxy URL に使いますが、有効化は Policy で行います。

1. 対象 Firewall が Standard または Premium で、想定した Policy に関連付いていることを確認します。
2. Policy の「Explicit Proxy」で有効化し、HTTP 待受ポートを例として `3128` にします。PAC は有効にしません。
3. Application rule collection に Allow のコレクションを用意します。送信元は対象サーバーの IP に限定します。任意ラボでは WinNAT 後の L1 ホスト `10.30.1.4` です。実環境に途中 NAT があれば実際の送信元を確認します。
4. プロトコル / 宛先ポートは HTTPS / `443` とし、次の公開宛先を現行の[公式ネットワーク要件](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)と照合して許可します。

   | 分類 | 対象 FQDN の例 | 用途 |
   |---|---|---|
   | 認証 | `login.microsoftonline.com`、`*.login.microsoft.com`、`pas.windows.net` | Entra ID。リージョンの認証先も必要 |
   | リソース管理 | `management.azure.com` | Arc の登録 / 解除 |
   | 通知 | `guestnotificationservice.azure.com`、`*.guestnotificationservice.azure.com`、公式 allowlist で取得した Service Bus の実 FQDN | 拡張機能・接続通知 |
   | 初回取得 / 更新 | `aka.ms`、`download.microsoft.com` と実際のリダイレクト先 | Windows インストーラー取得 |

   これは導入時に照合する一覧であり、将来の全バージョンに固定した完全な許可リストではありません。使用する Agent / 拡張機能の現行要件で不足を確認します。通知先は、インターネットに接続できる管理端末の PowerShell で公式 API を参照し、対象リージョンの応答から実際の FQDN を記録します。

   ```powershell
   $region = 'japaneast'
   Invoke-RestMethod -Uri "https://guestnotificationservice.azure.com/urls/allowlist?api-version=2020-01-01&location=$region" |
     ConvertTo-Json -Depth 10
   ```

   応答を取得できなければ停止します。`azgn*` 等の途中ワイルドカードをそのまま AzFW の対象 FQDN に転記しません。許可先が変更された場合は変更管理の対象にします。

5. Arc PLS へ向かう `*.his.arc.azure.com` / `*.guestconfiguration.azure.com` は Proxy の公開許可で代用しません。AMA の Monitor 宛先も公開 Proxy 経由にしません。
6. TLS 検査を適用しません。Firewall の DNS は hub Resolver へそろえ、FQDN の解決結果を確認します。DNS Proxy と Explicit HTTP Proxy は別機能です。
7. 検証用に Firewall の診断設定を有効にし、Application rule のログを②の LAW または承認済みの別の記録先へ送ります。resource-specific の場合は `AZFWApplicationRule` を使用します。診断設定による取り込みにも費用が発生します。
8. 対象サーバーから `<FW IP>:3128` への TCP 接続と、Proxy を指定した公開 URL の HTTP 応答を確認します。

**期待結果**: Application rule で対象送信元からの許可要求を観測できます。HTTP 400 / 401 等は、その URL の要求形式によることがあります。HTTP 応答があることと、Agent の認証成功は区別します。

## 3-4. 公開宛先への直接通信を制限する

最初に復旧用のプライベート管理接続と担当者を確認します。この試験は専用の対象サーバーだけで行い、共有の Firewall / Proxy は停止しません。

- 許可: 対象サーバー → Windows DNS、Arc PE / AMPLS PE の全対象 IP、AzFW の Proxy 待受ポート。
- 禁止: 対象サーバーから公開宛先への直接通信。既存の既定経路は変更しません。
- 任意ラボ: onpre subnet の NSG に、送信元を **L1 ホストの Private IP** に限定した `Internet` 宛ての Outbound Deny を追加します。必要な私用宛先の Allow と優先順位、既存管理経路、Azure プラットフォーム通信への影響を確認します。DNS VM 全体や VNet 全体を一括遮断しません。
- 実環境: 既存の境界 Firewall 等で対象送信元に適用します。変更記録と復元値を残します。

ルールの反映後、対象サーバーで `Test-NetConnection management.azure.com -Port 443` の直接 TCP が失敗し、Proxy 待受ポートは成功することを確認します。既存の NAT Gateway や別 Proxy、OS / 環境変数の Proxy による迂回がないかも確認してください。

## 3-5. Connected Machine agent をインストールする

操作場所は対象サーバーの管理者 Windows PowerShell です。任意ラボでは L2 内です。

1. `scripts\Install-ArcAgent.ps1` と `scripts\Connect-ArcServer.ps1` を承認された経路で対象にコピーします。
2. 既存 Arc が未導入の専用対象で、次を実行します。

   ```powershell
   .\Install-ArcAgent.ps1 -ProxyUri 'http://<FW IP>:3128'
   ```

このスクリプトは、ダウンロード自体に Proxy を指定し、Microsoft 署名を検証して MSI を導入します。OS 全体の Proxy は変更しません。既存 Agent がある場合は更新せず停止します。ネットワークからの取得を許可しない環境では、公式 MSI を承認済み経路で配置し、`-InstallerPath` で指定します。

```powershell
.\Install-ArcAgent.ps1 -InstallerPath 'C:\Staging\AzureConnectedMachineAgent.msi'
```

**期待結果**: `%ProgramFiles%\AzureConnectedMachineAgent\azcmagent.exe` が存在します。再起動要求が出た場合は承認した時間に再起動してから続けます。MSI の導入成功を Arc 登録成功と混同しません。

## 3-6. Proxy / bypass を設定して Arc に登録する

1. Portal の「Azure Arc → インフラストラクチャ → マシン → 既存マシンのオンボード」を開きます。
2. 対象の Subscription / RG / Region / Windows を指定し、Private endpoint と作成済み Arc PLS を選択します。Proxy URL は AzFW の URL、認証は手動認証を選びます。
3. 生成内容を確認し、特に Tenant ID、Subscription ID、Arc PLS の完全なリソース ID、地域を作業記録と照合します。自動生成スクリプトには導入・登録がまとまっているため、**3-5 と二重実行せず**、本ハンズオンでは次の保存済みスクリプトで登録します。
4. 対象サーバーで実行します。

   ```powershell
   .\Connect-ArcServer.ps1 `
     -TenantId '<Tenant ID>' `
     -SubscriptionId '<Subscription ID>' `
     -ResourceGroup '<Arc を作る RG>' `
     -Location 'japaneast' `
     -MachineName 'onprem-win01' `
     -PrivateLinkScopeId '<Arc PLS の完全なリソース ID>' `
     -ProxyUri 'http://<FW IP>:3128'
   ```

5. 表示されたデバイスコードの認証先 URL を、承認された管理端末のブラウザーで開きます。コードやトークンを画面キャプチャ、Git、共有資料に残しません。組織の条件付きアクセスがデバイスコードを許可しない場合は、管理者と[公式の代替認証方式](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-connect)を選び直し、回避しません。

スクリプトは登録前に、次を Agent 固有に設定します。

```text
proxy.url = http://<FW IP>:3128
proxy.bypass = Arc
```

Entra ID や ARM を bypass に追加しません。Arc PLS 宛てだけが直接接続になります。自動的に SQL Server 拡張機能が導入されないように、登録時のタグ `ArcSQLServerExtensionDeployment=Disabled` も設定します。

6. 登録後に確認します。

   ```powershell
   $arc = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
   & $arc show
   & $arc check --location japaneast --enable-pls-check
   ```

7. Portal の Arc machine で状態 Connected、正しい RG / Region、Arc PLS への関連付けを確認します。PLS の一覧側からも対象 machine の関連付けを確認します。

**期待結果**: Arc の Private Endpoint と Proxy を使う宛先を `azcmagent check` の結果で区別でき、必須チェックが成功します。「Connected」だけで閉域接続を証明したとは扱いません。

## 3-7. Arc サーバーに DCR / DCE と AMA を関連付ける

1. ②で作成した DCR を Portal で開き、「リソース → 追加」で今回の Arc machine を選びます。
2. DCR への関連付けにより、Portal が `AzureMonitorWindowsAgent` 拡張機能を導入します。Arc machine の「拡張機能」で Provisioning succeeded を確認します。Azure VM 用の `az vm extension` コマンドを Arc machine に使わないでください。
3. DCE の「リソース」で Arc machine を追加し、設定取得先を関連付けます。選択画面に対象が出ない場合は、リージョンと権限を確認し、[公式 DCE 関連付け手順](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-vm-kubernetes)に従います。
   Portal に選択肢がない場合は、②と同じ `scripts\Set-DceAssociation.ps1` の `-ResourceId` に **Arc machine の完全な ID**を指定します。DCE に記入する ID と対象 machine の ID を取り違えないでください。
4. 管理端末 / Cloud Shell の PowerShell 7 で、対象テナントとサブスクリプションへの CLI 接続を照合して実行します。

   ```powershell
   .\scripts\Set-AmaDirect.ps1 `
     -ExpectedTenantId '<Tenant ID>' `
     -ExpectedSubscriptionId '<Subscription ID>' `
     -ResourceType ArcServer `
     -ResourceGroup '<Arc の RG>' `
     -MachineName 'onprem-win01'
   ```

5. Arc 拡張機能の settings に `proxy.mode=none` が設定され、DCR と DCE の両方に今回の対象が関連付いていることを確認します。
6. L2 / 対象サーバーに `scripts\Write-HandsonEvent.ps1` をコピーし、管理者 Windows PowerShell から1回実行します。
7. [結果の確認](validation.md)で今回の Marker と Arc リソース ID を照合します。②の Azure VM の結果と混同しないでください。

AMA の導入ファイル配布は Arc の拡張機能管理を使います。初回配布または更新で失敗する場合、必要な実際の FQDN と経路を調査します。AMA の稼働通信を公開 Proxy に切り替えて成功扱いにしません。

## 根拠

- [Arc PLS と制約](https://learn.microsoft.com/azure/azure-arc/servers/private-link-security)
- [Windows への導入と Portal 生成スクリプト](https://learn.microsoft.com/azure/azure-arc/servers/onboard-portal)
- [Arc の Proxy / bypass](https://learn.microsoft.com/azure/azure-arc/servers/manage-agent-proxy-settings)
- [Arc ネットワーク要件](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
- [Explicit Proxy](https://learn.microsoft.com/azure/firewall/explicit-proxy)
- [AMA の導入方法](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage)
- [AMA の Proxy](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
