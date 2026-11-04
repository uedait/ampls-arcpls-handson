# 事前確認

[README](../README.md) → 事前確認 → [② Azure VM](02-azure.md)

## 1. 実施対象を決める

最初は業務負荷のない Windows VM とオンプレミス Windows Server を各1台選びます。既存環境を使う場合は、その VNet と Firewall を使用します。検証用のリソースグループを用意しても、共有 DNS の変更はほかの環境に影響します。

Portal 右上のディレクトリと、各作成画面のサブスクリプションを照合してください。複数テナント、複数リージョン、Lighthouse、Azure Arc Gateway、Microsoft Sentinel、VM Insights、性能カウンターはこのハンズオンの対象外です。既存の導入がある場合は、既存設定との併存を担当者が確認してから実施します。

## 2. 値を記録する

実際の値はアクセスを制限した作業記録に記載してください。表の名前と IP は例です。実施環境の値に置き換え、Portal の表示と照合してください。

| 項目 | 例 / 選び方 |
|---|---|
| Tenant ID / Subscription ID | Portal の「ディレクトリとサブスクリプション」で照合 |
| 作業用 RG | `rg-ampls-arc-handson`。既存リソースと所有者を区別する |
| Location | `japaneast`。VM、Arc リソース、DCE、LAW、DCR は同じリージョンにそろえる |
| LAW / DCE / DCR | `law-handson` / `dce-handson` / `dcr-handson-windows` |
| AMPLS / AMPLS PE | `ampls-handson` / `pe-ampls-handson` |
| Arc PLS / Arc PE | `arcpls-handson` / `pe-arc-handson` |
| Azure VM / その RG | 専用検証 VM の名前、完全なリソース ID |
| Arc machine name | `onprem-win01`。対象 RG で一意の名前を選ぶ |
| hub VNet / PE subnet | 空き IP のある PE 専用 subnet。例 `10.20.1.0/24` |
| Resolver Inbound IP | 例 `10.20.2.4` |
| Windows DNS IP | 実際の既存 DNS。任意ラボでは `10.30.1.5` |
| Explicit Proxy URL | 例 `http://10.20.0.4:3128` |
| LAW Workspace ID | 作成後に記録。サブスクリプション ID と別 |
| DCE configuration access FQDN | 作成後、DCE の概要から記録 |
| AMPLS / Arc PE の FQDN・Private IP 一覧 | 作成後、各 PE の「DNS の構成」で記録 |
| 観測時間・タイムゾーン | 例、操作時刻は JST、Azure の照合は UTC |
| 予算・通貨・期限・削除担当 | 利用者が決める。月額上限だけでなく停止時刻も記録 |

AMPLS 自体の location はグローバルです。DCE の設定取得先は監視対象と同じリージョン、DCR の送信先 LAW も同じリージョンにします。それぞれのリソースの配置を確認してください。

## 3. 権限とソフトウェアを確認する

| 担当 | 必要な操作 |
|---|---|
| Azure 管理担当 | RG 内の LAW、DCE、DCR、AMPLS、Arc PLS、VM 拡張機能の作成・関連付け |
| ネットワーク担当 | PE / DNS zone / VNet link / Firewall Policy の作成・変更、NSG の検証 |
| Arc 登録担当 | 対象 RG への Azure Connected Machine Onboarding または必要な Resource Administrator 権限 |
| Windows 担当 | 対象サーバーのローカル管理者、Windows DNS の変更権限 |
| 閲覧担当 | 対象 LAW のクエリ権限 |

最小権限の割り当ては組織の RBAC 方針で決め、担当ごとに必要なロールを付与してください。Azure VM に既存のユーザー割り当て ID がある場合は、利用先と維持すべき設定を確認します。既存 ID の不用意な置き換えはアプリケーションの認証を停止させるリスクがあるため、実施しないでください。

- 管理端末: Azure Portal と、必要箇所で Azure CLI が動く PowerShell 7 / Cloud Shell。
- Windows サーバー: 64-bit Windows PowerShell 5.1。スクリプトごとの `#Requires` に従う。
- ソースを取得した管理端末とサーバー間に、承認されたファイル転送・管理接続があること。
- ①の自動構築では、管理端末に PowerShell 7、Azure CLI、GitHub CLI と Bicep を用意すること。対象 RG の作成・デプロイと Managed Run Command の実行・VM 再起動を許可された Azure アカウント、または証明書で事前認証したサービスプリンシパルを使用すること。現行のスクリプトは公開リポジトリでも GitHub CLI の認証が必要。Private リポジトリを使用する場合は、その読み取り権限も必要。認証の手順とサービスプリンシパルの指定方法は[①の手順](01-lab.md#自動構築で使用する-github-アカウントを認証する)を参照すること。
- ①の完了確認では、hub の Bastion Standard への HTTPS 接続、VM / NIC / Bastion / 対象 VNet の Reader 権限、VM のローカル管理者資格情報を用意すること。補修時のファイル転送には Windows 管理端末のネイティブ RDP と Azure CLI 2.62.0 以降を使用すること。
- L2 の自動構築はコードに定義した公式 Windows Server 2022 x64 英語評価版 ISO を使用すること。URL・SHA-256 を入力するヒアリングは省き、HTTPS 配布元の検査と取得後ハッシュによるキャッシュ照合を行う。[専用ガイド](iso-build.md)の評価条件と自動構築の範囲を確認すること。
- PowerShell の実行ポリシーとコード署名の社内ルールを確認すること。署名が必要な場合は承認済みの署名手続きを行うこと。実行ポリシーや証明書検証の無効化は、改ざんされたスクリプトを実行するリスクがあるため、実施しないでください。
- Arc と AMA の現行サポート対象 OS、TLS、署名検証、時刻同期を確認すること。
- 利用するリソースプロバイダーの登録状況を Portal の「サブスクリプション → リソース プロバイダー」で確認すること。主に `Microsoft.Network`、`Microsoft.Compute`、`Microsoft.OperationalInsights`、`Microsoft.Insights`、`Microsoft.HybridCompute`、`Microsoft.GuestConfiguration` を使用する。登録には別途権限が必要。

CLI の補助操作には `connectedmachine` と、DCE 関連付けを CLI で行う場合は `monitor-control-service` 拡張機能が必要です。管理端末で導入状況を `az extension list` で確認し、未導入なら承認された方法で追加してください。対象 Windows サーバーでの Arc 登録には、`azcmagent` 自体の手動認証を使用します。

本編の対話操作では実施者のアカウントを使用します。①の自動構築では証明書で認証したサービスプリンシパルも使用できます。認証情報は組織の保管方針に従って管理してください。

## 4. 変更前に既存設定を確認する

実施者と各担当者が次を確認し、承認結果と切り戻し担当を記録します。

| 対象 | 確認・保存する内容 | 進めない条件 |
|---|---|---|
| AMPLS | 同じ DNS 範囲の既存 scope、PE、関連付け済み LAW / DCE、取り込み・クエリのモード | 既存の scope / 監視先への影響が不明 |
| Private DNS | zone、VNet link、A / CNAME、zone group、既存レコードの応答 | 同じ FQDN の上書きが必要、所有者が不明 |
| Windows DNS | 7ドメインの既存 zone / 条件付きフォワーダー、転送先、AD 複製範囲、既定フォワーダー | 名前の競合、別サービスで使用中、復元値が不明 |
| Firewall | 既存 Policy、Application rule、Explicit Proxy、DNS、TLS 検査設定 | 既存利用者に影響する変更が未承認 |
| 対象 VM / サーバー | 既存 AMA / Arc、DCR / DCE、ID、Proxy、Windows Firewall、復旧用の管理経路 | 既存監視を上書きする必要がある |
| 自動管理の適用 | Azure Policy、Defender、Arc 拡張機能の自動配布、SQL Server 自動登録の方針 | 今回以外の Agent / 有料機能が自動導入される影響が不明 |
| DNS 利用者 | 変更前の正常応答、監視サービス名、既存 Blob サービス名の応答と利用状況 | 検証対象以外の疎通を確認できない |

同じ DNS 解決範囲には、原則として単一の AMPLS を使用します。既存 AMPLS がある場合は、既存 scope へ対象リソースを追加する設計を管理者と確認してください。同じ解決範囲への別 AMPLS の追加は既存監視の名前解決を変えるリスクがあるため、競合が解消するまで実施しないでください。既存環境への変更を承認できなければ、①の任意ラボ等の分離された検証環境を使います。

`blob.core.windows.net` への転送は広い範囲に影響します。PE 用レコードと既存の別 Blob アカウントの両方が想定どおり使えることを確認してください。同名の条件付きフォワーダーがある場合は、転送先・複製範囲・利用者を照合し、担当者と変更方法を決めてください。

## 5. 到達性と費用を確認する

- Windows DNS → Resolver Inbound IP: UDP / TCP 53。
- 対象 Windows Server → 自環境の Windows DNS: UDP / TCP 53。
- 対象 VM / Windows Server → AMPLS PE の各 IP: TCP 443。
- オンプレミス Windows Server → Arc PE の各 IP: TCP 443。
- オンプレミス Windows Server → AzFW Private IP: TCP 3128。
- AzFW → 必須公開 FQDN: HTTPS / 443。現行の[Arc ネットワーク要件](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)で確認。

NSG やオンプレミス Firewall の変更は対象サーバーに限定します。共有 Firewall の停止や既存サーバーの公開通信の一括遮断は、業務通信を停止させるリスクがあるため、否定試験で実施しないでください。

LAW の取り込み量と保持、PE、Resolver、Firewall、VM・ディスクなどに費用が発生します。①では Bastion Standard、計5個の Public IP、ISO と親・差分 VHDX のディスク容量も含めてください。Windows Event は Application の検証用イベントだけに絞ってください。Security ログや全イベントの収集は、機密情報の取り込みや費用増加につながるため、本ハンズオンでは追加しないでください。Azure Budget の通知を受け取る担当者と、停止・削除を実施する担当者を決めます。①の VM を停止しても Bastion、Firewall、Resolver、PE 等の課金は残るため、終了時には対象を確認して削除してください。

## 6. 実行前の確認

次を記録してから②へ進みます。

```text
対象 Tenant / Subscription:
対象 Azure VM / オンプレミス Windows Server:
変更する DNS / Firewall / VNet:
既存 AMPLS / DNS との競合確認:
変更担当・承認者・実施時間:
予算・通貨・期限:
DNS と監視の切り戻し方法・連絡先:
```

後片付けの承認は構築承認と別に取得します。[後片付け](cleanup.md)で既存リソースを残す範囲も決めておいてください。
