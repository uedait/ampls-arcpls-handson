# 結果の確認

[README](../README.md) / [② Azure VM](02-azure.md) / [③ オンプレミス](03-onpremises.md)

## 1. 証跡と合否を分ける

各試験について、実施者が「合格 / 不合格 / 未実施」を記録します。画面例の架空の成功値は用意していません。エラー、待機時間、取得上限も記録し、検索失敗を「該当なし」と扱いません。

```text
試験番号:
実施者・承認者:
実施 UTC 時刻と対象:
設定前後の値:
確認方法・検索期間・取得上限:
観測結果:
判定（合格 / 不合格 / 未実施）:
切り戻し・残件:
```

作業記録や画面キャプチャにはデバイスコード、認証情報、実ログ本文を不用意に含めないでください。このハンズオンでは、自分で生成した合成イベントを使用します。

## 2. 名前解決と TCP を確認する

Azure VM とオンプレミス Windows Server の両方で、PE の「DNS の構成」にある実 FQDN を確認します。オンプレミスでは既存 Windows DNS に問い合わせ、Resolver へ直接向けて検証を代替しません。

| 番号 | 操作 | 合格条件 |
|---|---|---|
| DNS-1 | DCE の構成アクセス FQDN を解決 | AMPLS PE の一覧にある Private IP を返す |
| DNS-2 | `<Workspace ID>.ods.opinsights.azure.com` を解決 | AMPLS PE の Private IP を返す |
| DNS-3 | Arc PE の HIS / Guest Configuration の実 FQDN を解決 | Arc PE の Private IP を返す |
| DNS-4 | 変更前に記録した既存監視 / Blob の FQDN を解決・利用 | 変更前の正常性を維持 |
| TCP-1 | 上記の各 IP / FQDN の TCP 443 を検証 | 到達できる |
| TCP-2 | オンプレミスから AzFW Private IP の TCP 3128 を検証 | 到達できる |

`Test-NetConnection` は Agent の Proxy を使用しない直接 TCP の確認です。TCP 成功だけでは TLS 認証や Private Link の利用を証明できません。

```powershell
Resolve-DnsName '<実際の FQDN>' -Server '<対象サーバーが使う DNS IP>'
Test-NetConnection '<実際の FQDN>' -Port 443
Get-NetTCPConnection -State Established |
  Where-Object RemotePort -In 443, 3128 |
  Select-Object LocalAddress, RemoteAddress, RemotePort, OwningProcess
```

接続が短時間で終了する場合は、生成イベントを送る時刻に合わせて確認します。PID は `Get-Process -Id <PID>` で照合し、AMA と Arc の接続を区別します。ネットワーク追跡を追加する場合は取得範囲の承認を得てください。

## 3. Heartbeat と新規 Event を確認する

Portal で今回の LAW の「ログ」を開きます。最初の確認期間は30分、表示上限は100件にします。データがまだないテーブルでは KQL が「テーブルなし」になることもあります。クエリの成功・失敗と0件を区別します。

[Heartbeat クエリ](../queries/heartbeat.kql):

```kusto
Heartbeat
| where TimeGenerated > ago(30m)
| summarize LastHeartbeat=max(TimeGenerated), Records=count() by Computer, _ResourceId
| order by LastHeartbeat desc
| take 100
```

対象 Azure VM の ID は `Microsoft.Compute/virtualMachines`、Arc の ID は `Microsoft.HybridCompute/machines` です。Computer の名前だけで同一対象と判断しません。Heartbeat は稼働確認であり、イベントの収集定義が正しいことまでは証明しません。

[合成イベントのクエリ](../queries/test-events.kql):

```kusto
Event
| where TimeGenerated > ago(30m)
| where Source == "AmplsArcHandson" and EventID == 9001
| project TimeGenerated, IngestedAt=ingestion_time(), Computer, EventID,
          Source, RenderedDescription, _ResourceId
| order by TimeGenerated desc
| take 100
```

`Write-HandsonEvent.ps1` が返した Marker と生成 UTC 時刻を照合します。イベント本文は `AmplsArcHandson marker=<GUID>; utc=<UTC>` です。必要なら `where RenderedDescription contains "<今回の Marker>"` を追加します。Event は SecurityEvent テーブルではありません。

| 番号 | 合格条件 |
|---|---|
| LOG-1 | Azure VM の Heartbeat と、②で生成した今回の Marker の Event がある |
| LOG-2 | Arc サーバーの Heartbeat と、③で生成した今回の Marker の Event がある |
| LOG-3 | LAW の公開取り込み Disabled、AMPLS の取り込み PrivateOnly のまま LOG-1 / LOG-2 が成功 |
| LOG-4 | DCE の設定取得先と LAW の実接続先がそれぞれ PE の IP である |

到着だけで閉域と判定しません。DNS、接続先、設定値を併せて判定します。

## 4. Arc の Private Link と Proxy を確認する

対象サーバーの管理者 Windows PowerShell で実行します。

```powershell
$arc = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
& $arc show
& $arc config get proxy.url
& $arc config get proxy.bypass
& $arc check --location japaneast --enable-pls-check
```

| 番号 | 合格条件 |
|---|---|
| ARC-1 | 正しい Tenant / Subscription / machine、Connected、所定の Arc PLS と関連付け済み |
| ARC-2 | `proxy.url` が承認した AzFW URL、`proxy.bypass` が `Arc` |
| ARC-3 | HIS / Guest Configuration のチェックが Private Endpoint 経由で成功 |
| ARC-4 | 必須の公開宛先のチェックが Proxy 経由で成功 |

Portal の Firewall ログでも、対象送信元と試験時間に絞り、許可された認証先・ARM 等の要求を確認します。Resource-specific の `AZFWApplicationRule` を使う場合の例です。

```kusto
AZFWApplicationRule
| where TimeGenerated > ago(30m)
| where SourceIp == "<実際に FW が観測する対象送信元 IP>"
| project TimeGenerated, SourceIp, Fqdn, Action, Protocol
| order by TimeGenerated desc
| take 100
```

Legacy の AzureDiagnostics に出力している場合は、診断設定に合わせてクエリを変更します。別の LAW に送った診断ログを今回の LAW で探さないでください。TLS トンネル内の要求すべてをログが表示するとは限らないため、Agent の診断結果も組み合わせます。

## 5. 公開通信が Proxy のみで成立するかを試す

専用の対象サーバーだけで実施します。共有 Firewall の停止、共有ルールの削除、既存サーバーの一括変更はしません。失敗時は試験を止め、変更した値を戻して管理担当に連絡します。

1. ③の制限により、対象から公開宛先への直接 TCP 443 が失敗することを確認します。PE と Proxy は到達できる状態を維持します。
2. `azcmagent check` と Firewall ログで、Proxy 経由の公開通信が成功することを確認します。
3. 現在の `proxy.url` と `proxy.bypass` を安全な作業記録に保存します。
4. 対象の Arc Agent だけ、Proxy URL を一時的にクリアします。

   ```powershell
   & $arc config clear proxy.url
   & $arc check --location japaneast --enable-pls-check
   ```

5. 公開宛先のチェックが失敗することを確認します。Arc PLS の DNS / Private IP の疎通と混同しません。`azcmagent check` の全体が成功した場合は、Proxy 環境変数や直接の出口が残っていないか調べます。
6. 同じ時間帯に `Write-HandsonEvent.ps1` を再実行し、**その新しい Marker** が AMA から届くか確認します。既送信ログの遅延到着を使いません。短時間の試験であり、Arc の認証を無期限に切った状態で AMA が稼働する保証にはなりません。
7. 直ちに Proxy URL と bypass を元の値へ戻し、`azcmagent check` の成功を確認します。確認後も Arc を切断した状態のまま放置しません。

   ```powershell
   & $arc config set proxy.url 'http://<FW IP>:3128'
   & $arc config set proxy.bypass 'Arc'
   & $arc check --location japaneast --enable-pls-check
   ```

8. 新しい公開要求が Firewall に記録されることを確認します。ARM の登録 / 解除だけを試験のために繰り返さず、ネットワークチェックと認証要求の結果で確認します。キャッシュ済み認証だけを使った画面表示では判定しません。

**合格条件**: 直接の公開通信は失敗し、Proxy 指定ありの公開チェックは成功、指定を外すと失敗、復元後は成功します。同時に AMA の新規 Event は PE 経由で到着します。どの段階でも失敗した場合、成功へ書き換えず観測値を記録します。

## 6. 導入・更新の確認を別に残す

| 工程 | 記録する内容 |
|---|---|
| Arc MSI 取得 | バージョン、取得先、Microsoft 署名、Proxy または事前配布 |
| Arc 登録 | PLS と Proxy のチェック、正しいリソース ID |
| AMA 初回配布 | Arc 拡張機能の導入成功、必要な実 FQDN |
| 稼働中 | DCE の設定取得、LAW の新規 Event / Heartbeat、接続先 IP |
| Arc / AMA 更新 | 更新前後のバージョン、配布経路、更新後の新規ログ |

更新試験には別途変更承認と復旧計画が必要です。未実施なら未実施と記録し、「導入・更新も Agent Proxy のみで完了」と結論づけません。
