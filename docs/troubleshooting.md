# 障害調査

[README](../README.md) / [② Azure VM](02-azure.md) / [③ オンプレミス](03-onpremises.md) / [切り戻し](cleanup.md)

失敗した操作、対象、UTC 時刻、終了コード、検索期間を記録し、次の表で原因を切り分けてください。公開アクセスの全許可、bypass への AAD / ARM の追加、TLS 証明書検証の無効化は、必要な通信制限を外し検証する経路を変えるリスクがあるため、障害回避のために実施しないでください。

| 症状 | 最初の確認 | 次の対応 |
|---|---|---|
| Portal にリソースが出ない | Tenant / Subscription / Region / RBAC | 作業記録の対象 ID と Portal のスコープを照合する |
| Bastion から Azure VM に接続できない | Bastion のデプロイ状態、hub との peering、Reader 権限、VM の RDP 設定、NSG / Windows Firewall | AzureBastionSubnet `10.20.3.0/26` から対象 Private IP の TCP 3389 を確認する |
| Bastion のファイル転送に失敗する | Standard SKU、Native Client Support、Windows 管理端末、MSTSC の転送ポリシー、空き容量 | ネイティブ RDP 接続で転送し、転送元・先のハッシュを照合する |
| L2 の画面を開けない | L1 の Bastion 接続、Hyper-V / VMMS、L2 の起動状態 | L1 内の Hyper-V Manager / VMConnect で L2 を開く。PowerShell Direct は L2 のローカル資格情報を使う |
| ISO の取得・ハッシュ検証で失敗 | L1 の Build フェーズ、公式 HTTPS URL、リダイレクト先、公開元の SHA-256、空き容量 | 配布元と承認した入力を照合する。ハッシュ不一致の ISO は使用を停止する |
| L2 の無人セットアップが完了しない | ISO のバージョン / WIM エディション、Gen2 起動、応答ファイル、PowerShell Direct の待機期限 | L1 の VMConnect で実際の画面を確認し、資格情報を含む応答ファイルとディスクを保護して原因を調査する |
| PIP があるのに公開宛先へ接続できない | NIC NSG の `LabInternetOutbound` と有効な規則、新規 TCP 接続 | Restricted では意図した結果。構築作業が必要なら承認を得て Build へ戻す |
| Proxy も NSG で遮断されたように見える | 宛先が AzFW の Private IP / 3128 か、`AllowExplicitProxy` と優先度、FW の待受状態 | VM→Private Proxy の到達性と FW→公開宛先の Application rule を個別に確認する |
| 制限後も以前の公開接続だけ続く | 接続開始時刻と既存フロー、NSG のステートフル処理 | 構築中の通信を終了し、新しい接続で Deny を検証する |
| PE が Pending | 接続承認の状態と対象 resource ID | リソース所有者に承認依頼 |
| DNS が公開 IP を返す | 対象サーバーの DNS、7公開ドメインの転送先、hub link、PE の zone group | Windows DNS 経由と Inbound 直接の結果を、承認範囲で比較 |
| DNS が NXDOMAIN | 実 FQDN、必要な A レコード、空の zone、既存 zone の上書き | 変更前の応答と照合し、既存業務への影響があれば直ちに切り戻す |
| TCP 443 が失敗 | PE 全 IP、Peering / ER、NSG / Firewall、ルート | PE への各経路のルートと許可規則を照合する |
| Proxy 3128 に接続できない | Firewall Policy の有効化、待受ポート、Private IP、送信元 | Application rule の宛先ポート 443 と待受 3128 を区別 |
| Proxy が拒否する | FW が見た NAT 後送信元、FQDN、Rule priority | 必須の個別宛先を現行の公式要件と照合し、対象の許可規則を確認する |
| MSI の署名検証失敗 | 取得 URL、署名、時刻、証明書チェーン | 配布・PKI 担当へ相談し、公式 MSI と検証用の証明書チェーンを確認する |
| Arc 登録で認証失敗 | Tenant、権限、デバイスコード制限、認証先の FQDN | 管理者と組織が許可した認証方式を選ぶ |
| Arc PLS のチェックが失敗 | `--private-link-scope`、PLS 関連付け、bypass、Arc PE の DNS | Arc 専用の PLS / PE / DNS と対象 machine の関連付けを確認する |
| Arc が Azure VM と判定される | L2 で実行しているか、L2 の IMDS 遮断 | L2 の遮断規則を修正し、L1 の IMDS は現在の設定を維持する |
| AMA が Provisioning failed | Arc / VM の拡張機能状態、配布の必要 FQDN | 初回配布と AMA の稼働通信を分ける |
| AMA は成功したがログなし | DCR と対象の関連付け、DCE 設定取得の関連付け、AMPLS に LAW / DCE があるか | DCR と DCE の両リソース一覧に対象 VM / machine があることを確認する |
| Heartbeat だけある | DCR の XPath、Event Source / ID、今回の Marker | `Event` テーブルを今回の Marker で検索する |
| 一方の VM しか見えない | KQL の `_ResourceId`、VM / Arc の区別、対象の DCR / DCE | 同じ Computer 名の別リソースを見ていないか確認 |
| Proxy を外しても公開通信が成功 | 環境変数 / OS Proxy、直接の NAT / 別の出口、チェック結果 | 直接出口の遮断範囲を確認し、否定試験をやり直す |
| Query だけ失敗 | LAW の query public access、閲覧端末の DNS / PE 到達性 | 取り込みの成功と query の経路は別に確認 |
| KQL が0件 / エラー | LAW、時間範囲、日次上限、テーブルの存在、権限 | 成功して0件だった結果とクエリエラーを区別し、上限や待機時間も記録する |

## 読み取り確認の例

対象 Windows Server で使用します。共有する結果は対象と診断項目に絞り、認証情報が含まれていないことを確認してください。

```powershell
$arc = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
& $arc show
& $arc check --location japaneast --enable-pls-check
Get-Service himds, GCArcService, ExtensionService -ErrorAction Stop
Get-DnsClientServerAddress -AddressFamily IPv4
Get-NetTCPConnection -State Established |
  Where-Object RemotePort -In 443, 3128 |
  Select-Object LocalAddress, RemoteAddress, RemotePort, OwningProcess
```

Arc のログは `%ProgramData%\AzureConnectedMachineAgent\Log`、AMA 拡張機能の情報は VM / Arc の「拡張機能」と対象 OS 内の拡張機能ログを確認します。パスや機能は Agent バージョンによって異なるため、[AMA のトラブルシューティング](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-troubleshoot-windows-vm)も確認してください。

実ログの転送が必要になった場合は、取得先、時刻、最大件数、秘密情報の除外、共有先を管理者と決めてください。無制限のログ採取や診断パッケージの公開アップロードは、業務情報の過剰取得や漏えいのリスクがあるため、実施しないでください。
