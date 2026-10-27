# 障害調査

[README](../README.md) / [合格条件](validation.md) / [切り戻し](cleanup.md)

失敗した操作、対象、UTC 時刻、終了コード、検索期間を記録します。公開アクセスを広げる、bypass に AAD / ARM を足す、TLS の検証を無効にする方法で成功扱いにしません。

| 症状 | 最初の確認 | 次の対応 |
|---|---|---|
| Portal にリソースが出ない | Tenant / Subscription / Region / RBAC | 正しいスコープを確認する。別のサブスクリプションへ勝手に作らない |
| PE が Pending | 接続承認の状態と対象 resource ID | リソース所有者に承認依頼 |
| DNS が公開 IP を返す | 対象サーバーの DNS、7公開ドメインの転送先、hub link、PE の zone group | Windows DNS 経由と Inbound 直接の結果を、承認範囲で比較 |
| DNS が NXDOMAIN | 実 FQDN、必要な A レコード、空の zone、既存 zone の上書き | 変更前の応答と照合し、既存業務への影響があれば直ちに切り戻す |
| TCP 443 が失敗 | PE 全 IP、Peering / ER、NSG / Firewall、ルート | UDR を追加して原因を隠さず到達性を確認 |
| Proxy 3128 に接続できない | Firewall Policy の有効化、待受ポート、Private IP、送信元 | Application rule の宛先ポート 443 と待受 3128 を区別 |
| Proxy が拒否する | FW が見た NAT 後送信元、FQDN、Rule priority | 必須の個別宛先を現行の公式要件で確認。Internet 全許可にしない |
| MSI の署名検証失敗 | 取得 URL、署名、時刻、証明書チェーン | 証明書検証を無効化しない。配布・PKI 担当へ相談 |
| Arc 登録で認証失敗 | Tenant、権限、デバイスコード制限、認証先の FQDN | 条件付きアクセスを迂回しない。管理者と許可された認証方式を選ぶ |
| Arc PLS のチェックが失敗 | `--private-link-scope`、PLS 関連付け、bypass、Arc PE の DNS | AMPLS の設定だけでは Arc を閉域化できない |
| Arc が Azure VM と判定される | 実行場所が L1 ではなく L2 か、L2 の IMDS 遮断 | L1 IMDS を変更しない。ゲストの隔離を修正 |
| AMA が Provisioning failed | Arc / VM の拡張機能状態、配布の必要 FQDN | 初回配布と AMA の稼働通信を分ける |
| AMA は成功したがログなし | DCR と対象の関連付け、DCE 設定取得の関連付け、AMPLS に LAW / DCE があるか | DCE の欄に名前を入れただけで対象との関連付けが済んだと判断しない |
| Heartbeat だけある | DCR の XPath、Event Source / ID、今回の Marker | `Event` を検索する。`SecurityEvent` ではない |
| 一方の VM しか見えない | KQL の `_ResourceId`、VM / Arc の区別、対象の DCR / DCE | 同じ Computer 名の別リソースを見ていないか確認 |
| Proxy を外しても公開通信が成功 | 環境変数 / OS Proxy、直接の NAT / 別の出口、チェック結果 | 直接出口の遮断範囲を確認し、否定試験をやり直す |
| Query だけ失敗 | LAW の query public access、閲覧端末の DNS / PE 到達性 | 取り込みの成功と query の経路は別に確認 |
| KQL が0件 / エラー | LAW、時間範囲、日次上限、テーブルの存在、権限 | エラーを0件と扱わない。上限や反映待ちも記録する |

## 読み取り確認の例

対象 Windows Server で使用します。サインイン用コードや機密値が表示された場合、共有資料に貼り付けません。

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

実ログの転送が必要になった場合、取得先、時刻、最大件数、秘密情報の除外、共有先を管理者と決めてください。無制限のログ採取や診断パッケージの公開アップロードは行いません。
