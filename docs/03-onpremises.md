# ③ オンプレミス Windows Server を Arc PLS と AMPLS に登録する

[README](../README.md) → [② Azure VM](02-azure.md) → ③ → [結果の確認](validation.md)

## この章で行うこと

オンプレミスの Windows Server を Azure Arc に登録し、②で作成した Log Analytics ワークスペースでログを確認します。次の順に進めます。

1. Azure Arc 用のプライベート エンドポイントを作成し、サーバーから名前解決・接続できるようにします。
2. サーバーを Azure Arc に登録します。Arc の管理通信はプライベート エンドポイントを使い、認証などのインターネット接続が必要な通信は Azure Firewall のプロキシを使います。
3. Azure Monitor Agent を導入し、②の AMPLS のプライベート エンドポイント経由でログを送ります。サーバーの稼働状況を示す Heartbeat と、自分で作成した検証イベントを確認します。

最後に、サーバーがインターネットへ直接接続できない状態でも、Arc の接続とログ収集が続くことを確認します。

本ハンズオンは、同じ VNet / DNS 解決範囲の Arc サーバーがすべて Private Link を使う構成です。Private Link を使わない Arc サーバーも混在させる場合は、共有する DNS の解決結果が通信に影響するため、[公式資料の制約と設計](https://learn.microsoft.com/azure/azure-arc/servers/private-link-security#restrictions-and-limitations)を確認してから構成を決めてください。

### 入力に使う値

①の既定 prefix `arclab` を使う場合の入力例です。②の収集リソースも次の名前で作成したものとして示します。自分が作成したリソース名を使ってください。

| 項目 | ①②の環境の例 | 取得場所 |
|---|---|---|
| サブスクリプション / RG | 承認したサブスクリプション / `rg-arclab-lab` | ②で使った作成先 |
| リージョン | Japan East / コマンドでは `japaneast` | ②で使ったリージョン |
| hub VNet / PE subnet | `arclab-hub` / `snet-pe` | [②の PE 作成](02-azure.md#2-4-ampls-の-private-endpoint-と-dns-を構成する)と同じ |
| Resolver Inbound IP | `10.20.2.4` | Portal で「DNS Private Resolver」を検索 → 対象 Resolver →「受信エンドポイント」→ 対象エンドポイントの IP |
| Windows DNS IP | `10.30.1.5` | 既存 Windows DNS サーバーの IP。①では DNS VM の「概要 → プライベート IP アドレス」 |
| Firewall のプライベート IP | `10.20.0.4` | Portal で「ファイアウォール」を検索 → 対象 Firewall →「概要」 |
| DCE の構成アクセス FQDN | 作成した DCE の値 | [②の DCE 概要](02-azure.md#dce-fqdn) |
| LAW の ODS FQDN と PE IP | 作成した PE の値 | [②の PE の DNS 構成](02-azure.md#law-ods-fqdn) |
| LAW / DCE / DCR | `law-arclab` / `dce-arclab` / `dcr-arclab-windows` | ②で作成したリソース |

## 3-1. Arc Private Link Scope と専用 PE を作成する

操作場所は Azure Portal です。

1. 上部の検索で「Azure Arc Private Link Scopes」を開き、「作成」を選びます。
2. サブスクリプション、RG、名前 `arcpls-handson`、リージョン Japan East を指定します。「パブリック ネットワーク アクセスを許可」はオフにします。
3. 「Private Endpoint」タブで、プライベート エンドポイントの追加を選び、次を指定します。

   | 項目 | 入力例 |
   |---|---|
   | PE のサブスクリプション / RG | ②と同じ作成先 / `rg-arclab-lab` |
   | 名前 | `pe-arc-handson` |
   | リージョン | hub VNet と同じ Japan East |
   | 仮想ネットワーク | ②の AMPLS PE と同じ `arclab-hub` |
   | サブネット | ②と同じ `snet-pe` |
   | プライベート DNS ゾーンと統合する | はい |
   | DNS ゾーンのサブスクリプション / RG | ②と同じ作成先 / `rg-arclab-lab` |
   | 新規作成する DNS ゾーン | `privatelink.his.arc.azure.com`、`privatelink.guestconfiguration.azure.com` |

   既存の承認済み DNS ゾーンがある場合は、それを選択します。AMPLS のゾーンはここでは選びません。
4. PE の入力画面の「OK / 追加」を押して Arc PLS の作成画面へ戻ります。「確認および作成 → 作成」を押し、デプロイの完了を待ちます。PE の入力だけでは、リソース作成は完了していません。
5. Portal の検索で「リソース グループ」を開き、`rg-arclab-lab` → `arcpls-handson` を開きます。「プライベート エンドポイント接続」で `pe-arc-handson` の接続状態が `Approved` であることを確認します。承認待ちの場合は Arc PLS の所有者へ承認を依頼します。
6. 同じ RG から `pe-arc-handson` →「DNS の構成」を開きます。HIS と Guest Configuration の公開 FQDN と、それぞれのプライベート IP を控えます。後のコマンドには `privatelink` 付きの名前ではなく、この画面にある公開 FQDN を使います。
7. Portal の検索で「プライベート DNS ゾーン」を開き、上記2ゾーンをそれぞれ開きます。「仮想ネットワーク リンク」に `arclab-hub` があり、リンク状態が `Completed` であることを確認します。なければ「追加」で hub VNet を選び、「自動登録を有効にする」をオフにして作成します。PE のレコードは DNS 統合で管理するため、VM の名前を自動登録する必要はありません。

確認: Arc PLS の公開アクセスが無効で、Arc PE が承認済みです。Arc PLS と後で登録する Arc サーバーは同じリージョンを使います。Arc PE と②の AMPLS PE は別のリソースです。

<a id="windows-dns"></a>

## 3-2. Windows DNS に条件付きフォワーダーを追加する

操作場所は既存 Windows DNS サーバーの「DNS マネージャー」です。AD 統合 DNS の設定は複製先にも適用されます。既存基盤では同名のゾーン・フォワーダーを上書きせず、保存・複製範囲を管理者の運用方針に合わせます。新規の専用ラボでは次の7件を追加します。

1. 「DNS マネージャー」で対象 DNS サーバー →「条件付きフォワーダー」を右クリックし、「新しい条件付きフォワーダー」を選びます。
2. 次の各行について「DNS ドメイン」と「マスター サーバーの IP アドレス」を入力し、「OK」を押します。7件とも同じ Resolver Inbound IP を指定します。

   | DNS ドメイン | マスター サーバーの IP アドレス |
   |---|---|
   | `his.arc.azure.com` | `10.20.2.4` |
   | `guestconfiguration.azure.com` | `10.20.2.4` |
   | `monitor.azure.com` | `10.20.2.4` |
   | `oms.opinsights.azure.com` | `10.20.2.4` |
   | `ods.opinsights.azure.com` | `10.20.2.4` |
   | `agentsvc.azure-automation.net` | `10.20.2.4` |
   | `blob.core.windows.net` | `10.20.2.4` |

3. Arc を導入するサーバーで Windows PowerShell を開き、次を実行します。`Get-DnsClientServerAddress` の結果は、この Windows DNS サーバーの IP になっている必要があります。①の L2 は構築済みの設定を使います。別環境では対象サーバーのネットワーク アダプターの IPv4 DNS 設定に Windows DNS の IP を指定します。

   ```powershell
   $dnsServer = '10.30.1.5'
   $arcHis = '<3-1 の Arc PE にある HIS の公開 FQDN>'
   $arcGuestConfig = '<3-1 の Arc PE にある Guest Configuration の公開 FQDN>'
   $dce = '<②の DCE 構成アクセス FQDN>'
   $ods = '<②の LAW ODS FQDN>'
   Get-DnsClientServerAddress -AddressFamily IPv4
   foreach ($fqdn in @($arcHis, $arcGuestConfig, $dce, $ods)) {
       Resolve-DnsName $fqdn -Server $dnsServer -ErrorAction Stop
       Test-NetConnection $fqdn -Port 443
   }
   ```

確認: 最終 A レコードが対応する PE の IP で、`TcpTestSucceeded` が `True` です。DNS マネージャーで Resolver の検証に警告が出る場合も、実際の名前解決結果で確認します。既存基盤では、利用中の監視サービスと Blob の名前解決・利用が変更前どおりであることも確認してください。

<a id="explicit-proxy"></a>

## 3-3. Azure Firewall の Explicit Proxy を設定する

操作場所は Azure Portal です。①の環境は Firewall Standard を使います。

1. 上部の検索で「ファイアウォール」を開き、対象 Firewall →「概要」でプライベート IP を確認します。関連付けられた Firewall Policy のリンクを開きます。
2. Policy の「Explicit Proxy / 明示的なプロキシ」を開き、有効にします。HTTP 待受ポートには使用可能な任意のポート番号を指定します。本ハンズオンは例として `3128` を使い、以降の接続許可と Proxy URL もこの番号で統一します。HTTP と HTTPS は同じ待受ポートを使います。

   Azure Arc の Agent に直接 Proxy URL を指定するため、Proxy PAC は利用しません。「プロキシの自動構成を有効にする」はチェックせず、「保存」を押します。
3. Policy の「規則コレクション」から「規則コレクションの追加」を開き、次を入力して「追加」を押します。①の専用ハンズオン環境向けの例です。共有環境では既存の優先度と許可先に合わせ、ソースは対象サーバーの送信元 IP（NAT がある場合は変換後の IP）に限定してください。

   | 規則コレクションの項目 | 入力例 |
   |---|---|
   | 名前 | `arc-public-outbound` |
   | 規則コレクションの種類 | Application |
   | 規則コレクション グループ | `DefaultApplicationRuleCollectionGroup` |
   | 優先度 | `200`。既存コレクションと重複しない値 |
   | アクション | Allow / 許可 |

   コレクション内に次の規則を追加します。すべてソースの種類は「IP アドレス」、ソースは `*`、プロトコルは `HTTPS:443`、宛先の種類は「FQDN」です。

   | 規則名 | 対象 FQDN |
   |---|---|
   | `arc-auth` | `login.microsoftonline.com`、`*.login.microsoft.com`、`pas.windows.net` |
   | `arc-arm` | `management.azure.com` |
   | `arc-notifications` | `guestnotificationservice.azure.com`、`*.guestnotificationservice.azure.com`、`*.servicebus.windows.net` |
   | `arc-download` | `aka.ms`、`download.microsoft.com`、`gbl.his.arc.azure.com` |

   これは [Arc の公式ネットワーク要件](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements#urls)に基づく例です。ダウンロードの転送先や導入する拡張機能に追加の宛先が必要な場合は、失敗した接続先を確認して追加します。Arc の HIS / Guest Configuration と AMA の送信先は PE に直接接続するため、この Proxy 規則には追加しません。
4. Policy の「DNS」を開き、「DNS サーバー」でカスタムを選び、Resolver Inbound IP（例 `10.20.2.4`）を入力して「保存」を押します。DNS Proxy は、このハンズオンでは①の設定を維持します。対象サーバーの DNS は [3-2 の Windows DNS](#windows-dns)を使います。
5. Premium を使う場合は、追加した Application 規則を開き、「TLS 検査」をチェックせず保存します。Arc 用の通信は証明書を置き換えません。①の Standard には TLS 検査の設定がないため、この操作は不要です。共有 Policy の TLS 検査全体は変更しません。
6. Firewall 本体の「診断設定 → 診断設定を追加」を開き、Application rule のログを選択します。「Log Analytics ワークスペースに送信する」で②の LAW を指定し、宛先テーブルに「リソース固有」を選んで保存します。ログは `AZFWApplicationRule` に入ります。既に同じ設定があれば追加不要です。診断ログの取り込み費用が発生します。
7. Arc を導入するサーバーの Windows PowerShell で次を実行します。

   ```powershell
   $proxyIp = '10.20.0.4'
   $proxyPort = 3128
   $proxyUrl = "http://${proxyIp}:$proxyPort"
   Test-NetConnection $proxyIp -Port $proxyPort
   $response = Invoke-WebRequest -UseBasicParsing `
       -Uri 'https://management.azure.com/metadata/endpoints?api-version=2020-06-01' `
       -Proxy $proxyUrl -ErrorAction Stop
   $response.StatusCode
   ```

確認: `TcpTestSucceeded` が `True`、HTTP ステータスが `200` です。これは Proxy 経由の HTTPS 疎通確認であり、Arc の認証確認は次の登録操作で行います。

<a id="arc-onboarding"></a>

## 3-4. Azure Portal から Arc に登録する

オンプレミスにある Azure Arc 導入対象のサーバーで、管理者 Windows PowerShell 5.1（64ビット）を起動して操作します。①では L2 ゲストを使います。リポジトリ独自の導入・登録スクリプトは使いません。

1. 管理端末の Azure Portal で「Azure Arc」を検索し、「インフラストラクチャ → マシン → オンボード / 作成 → 既存マシンのオンボード」を開きます。
2. 「基本」で次を指定します。

   | 項目 | 入力例 |
   |---|---|
   | サブスクリプション / RG | 承認した作成先 / `rg-arclab-lab` |
   | リージョン | Arc PLS と同じ Japan East |
   | オペレーティング システム | Windows |
   | 接続方法 | Private endpoint |
   | Private Link Scope | `arcpls-handson` |
   | Proxy サーバー URL | `http://10.20.0.4:3128` |
   | 認証 | マシンを手動で認証 |

3. 「次へ」で「タグ」を開き、`ArcSQLServerExtensionDeployment` = `Disabled` を追加します。本ハンズオンでは SQL Server 拡張機能を自動導入しません。
4. 「次へ → スクリプトのダウンロードと実行」で作成先と接続方法を確認し、「ダウンロード」を押します。Microsoft が生成する `OnboardingScript.ps1` を対象サーバーの任意の作業フォルダー（例 `C:\ArcOnboarding`）へ配置します。①でも L1 ではなく L2 へ配置してください。
5. ダウンロードしたファイルをエディターで開きます。生成ファイルの Proxy 設定を次のようにそろえます。

   - `SetEnvironmentVariable` を検索します。`HTTPS_PROXY` を `Machine` に保存する行があれば削除します。本ハンズオンではマシン全体の Proxy と既存のサービス設定を変更しません。
   - ダウンロード処理より前に次の1行を追加します。この値は実行中の PowerShell とその子プロセスだけに適用します。生成ファイルがインストーラーへ渡す `-Proxy` の値も、Portal に入力した同じ URL とします。

     ```powershell
     $env:HTTPS_PROXY = 'http://10.20.0.4:3128'
     ```

   - `--resource-group` と `--tenant-id` を指定する Agent の `connect` 呼び出しを探します。インストール処理が完了した後、この呼び出しの直前に次を追加します。複数行のコマンドの途中には入れません。既に同じ設定がある場合は追加不要です。

   ```powershell
   $arc = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
   & $arc config set proxy.url 'http://10.20.0.4:3128'
   if ($LASTEXITCODE -ne 0) { throw 'Arc Proxy の設定に失敗しました。' }
   & $arc config set proxy.bypass 'Arc'
   if ($LASTEXITCODE -ne 0) { throw 'Arc Proxy bypass の設定に失敗しました。' }
   ```

   `Arc` の指定で HIS / Guest Configuration は PE に直接接続し、認証・ARM 等は Proxy を使います。この指定は [公式の Agent 固有 Proxy 設定](https://learn.microsoft.com/azure/azure-arc/servers/manage-agent-proxy-settings#proxy-bypass-for-private-endpoints)です。独自の登録スクリプトを作らず、公式の生成ファイルに本ハンズオンで必要な設定だけを追加します。
6. 対象サーバーの管理者 Windows PowerShell で、ファイルの配置先へ移動して実行します。

   ```powershell
   Set-Location 'C:\ArcOnboarding'
   .\OnboardingScript.ps1
   ```

   公式スクリプトが Agent のダウンロード、インストール、Arc 登録を行います。画面に表示された認証 URL を管理端末で開き、表示されたコードで認証します。コード・トークン・認証画面は記録や画像に含めません。デバイスコード認証が禁止されている場合は、[公式の別認証方法](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-connect)を選びます。登録と手順8の確認が終わったら、この PowerShell を閉じてセッション限定の Proxy を終了します。
7. Portal の「Azure Arc → インフラストラクチャ → マシン」を開き、登録したサーバーの状態が `Connected` であることを確認します。対象を開いて作成先とリージョンを確認し、「概要 → JSON ビュー」の `id` を控えます。KQL に使うのはこの Arc リソース ID です。①の L1 の VM ID とは異なります。
8. 対象サーバーの管理者 Windows PowerShell で次を実行します。

   ```powershell
   $arc = "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
   & $arc show
   if ($LASTEXITCODE -ne 0) { throw 'Arc の状態取得に失敗しました。' }
   & $arc check --location japaneast --enable-pls-check
   if ($LASTEXITCODE -ne 0) { throw 'Arc のネットワークチェックに失敗しました。' }
   ```

確認: 有効な Proxy URL が指定どおりで、bypass が `Arc` です。ネットワークチェックでは HIS / Guest Configuration が Private Endpoint を使い、認証・ARM 等の必須チェックも成功します。

<a id="arc-monitoring"></a>

## 3-5. AMA と DCR / DCE を関連付けてログを確認する

1. Portal で「監視」を検索し、「設定 → データ収集ルール」から②の `dcr-arclab-windows` を開きます。「リソース → 追加」で登録した Arc サーバーを選び、「適用」を押します。Portal が AMA を導入します。
2. Arc サーバーの「拡張機能」で `AzureMonitorWindowsAgent` のプロビジョニング状態が `Succeeded` になるまで待ちます。
3. 「監視 → 設定 → データ収集エンドポイント」から②の `dce-arclab` を開き、「リソース → 追加」で同じ Arc サーバーを選びます。DCR にも DCE にも対象があることを確認します。DCE は AMA の設定取得先です。
4. AMA の拡張機能の「JSON ビュー」で settings の proxy を確認します。`mode=none` に設定済みなら次へ進みます。別の Proxy 設定がある場合や直接接続を確認できない場合は、後述の[管理端末の補助操作](#management-commands)で `none` にします。
5. 閉域収集を判定する前に、②の LAW の公開取り込みが無効、DCE の公開アクセスが無効、AMPLS の取り込みモードが `Private Only` であることを確認します。①のラボは既存の Restricted NSG を維持します。実オンプレミスでは管理者が対象サーバーの公開直接通信を制限し、Windows DNS、PE、Proxy と管理接続を許可した状態で試験します。

   対象サーバーで次を実行します。直接接続は `False`、Proxy 待受ポートへの接続は `True` が期待結果です。

   ```powershell
   Test-NetConnection management.azure.com -Port 443
   Test-NetConnection '10.20.0.4' -Port 3128
   [datetime]::UtcNow.ToString('o')
   ```

   出力した UTC 時刻を基準時刻として控えます。既に制限済みの環境も公開アクセスを戻しません。
6. 対象サーバーの管理者 Windows PowerShell 5.1 で、次を1回実行します。Application に検証イベントを1件書き込みます。

   ```powershell
   $ErrorActionPreference = 'Stop'
   if ($PSVersionTable.PSEdition -ne 'Desktop' -or
       $PSVersionTable.PSVersion.Major -ne 5 -or
       $PSVersionTable.PSVersion -lt [version]'5.1') {
       throw '管理者 Windows PowerShell 5.1 で実行してください。'
   }
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = New-Object Security.Principal.WindowsPrincipal($identity)
   if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
       throw 'Windows PowerShell を管理者として実行してください。'
   }
   $source = 'AmplsArcHandson'
   if ([Diagnostics.EventLog]::SourceExists($source) -and
       [Diagnostics.EventLog]::LogNameFromSourceName($source, '.') -ne 'Application') {
       throw '同名のイベントソースが別のログに属しています。'
   }
   if (-not [Diagnostics.EventLog]::SourceExists($source)) {
       New-EventLog -LogName Application -Source $source
   }
   $marker = [guid]::NewGuid().ToString()
   $utc = [datetime]::UtcNow.ToString('o')
   Write-EventLog -LogName Application -Source $source -EventId 9001 `
       -EntryType Information -Message "AmplsArcHandson marker=$marker; utc=$utc"
   [pscustomobject]@{
       Marker = $marker
       GeneratedUtc = $utc
       Computer = $env:COMPUTERNAME
       EventId = 9001
       Source = $source
   }
   ```

7. Portal の②の LAW →「ログ」を開き、「KQL モード」で次を実行します。表示上限は「表示 → カスタム → 100」にします。Arc の JSON ビューで取得した `id` と、手順5の基準 UTC 時刻を貼り付けます。

   ```kusto
   let targetResourceId = "<Arc サーバーの JSON ビューの id>";
   let restrictedSince = todatetime("<手順5で控えた UTC 時刻>");
   Heartbeat
   | where TimeGenerated > ago(30m)
   | where _ResourceId =~ targetResourceId
   | where Category == "Azure Monitor Agent"
   | where TimeGenerated > restrictedSince and ingestion_time() > restrictedSince
   | project TimeGenerated, IngestedAt=ingestion_time(), Computer, _ResourceId
   | order by TimeGenerated desc
   | take 100
   ```

8. 同じ画面で、今回のイベントの Marker と GeneratedUtc を貼り付けて実行します。検索期間は生成時刻の1分前から29分後までの30分、上限100件です。

   ```kusto
   let targetResourceId = "<Arc サーバーの JSON ビューの id>";
   let marker = "<今回の Marker>";
   let generatedUtc = todatetime("<今回の GeneratedUtc>");
   Event
   | where TimeGenerated between ((generatedUtc - 1m) .. (generatedUtc + 29m))
   | where _ResourceId =~ targetResourceId
   | where Source == "AmplsArcHandson" and EventID == 9001
   | where RenderedDescription contains marker
   | project TimeGenerated, IngestedAt=ingestion_time(), Computer, EventID,
             Source, RenderedDescription, _ResourceId
   | order by TimeGenerated desc
   | take 100
   ```

確認: 制限確認後の Heartbeat と今回の Marker の Event が対象 Arc サーバーから到着します。初回は15分を目安に待ちます。0件の場合は検索期間と結果を記録し、検索エラーの場合はエラーを記録して[障害調査](troubleshooting.md)へ進みます。

閉域経路の合格には、[3-2 の DNS / TCP](#windows-dns)、[Arc のチェック](#arc-onboarding)、[②と同じ AMA の実接続確認](02-azure.md#ama-peers)も必要です。AMA の PID と実行ファイルを照合し、DCE と LAW の両接続先が AMPLS PE の対応する IP であることを確認します。接続を取得できなければ未取得として記録し、ログの到着だけで閉域経路の合格にはしません。①②の Azure VM と③の Arc サーバーの結果は、それぞれのリソース ID で区別します。

### Proxy を通った公開通信の確認

Firewall の診断設定で指定した LAW の「ログ」で次を実行します。①の L2 は WinNAT を通るため、Firewall が観測する送信元は L1 の `10.30.1.4` です。規則のソースを `*` にしていても、検索は対象送信元と実施時刻に絞ります。

```kusto
let sourceIp = "10.30.1.4";
let startedUtc = todatetime("<手順5で控えた UTC 時刻>");
AZFWApplicationRule
| where TimeGenerated between (startedUtc .. (startedUtc + 30m))
| where SourceIp == sourceIp
| project TimeGenerated, SourceIp, Fqdn, Action, Protocol
| order by TimeGenerated desc
| take 100
```

確認: Arc の認証先・管理先への Allow を確認します。詳細な試験番号と記録方法は[結果の確認](validation.md)にまとめています。

<a id="management-commands"></a>

### 必要な場合だけ使う管理端末の補助操作

対象サーバー内では実行しません。管理端末の PowerShell 7 と、[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)を使います。事前確認で決めた認証方法で対象テナントへサインインし、`az account show` の tenant / subscription / 実行 ID / 認証種別を承認記録と照合します。証明書を使う場合は[事前確認](prerequisites.md)に従ってください。

Arc サーバーと DCE の「概要 → JSON ビュー」の `id` をコピーします。Portal で設定取得用 DCE を関連付けられない場合は、[公式 CLI コマンド](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-vm-kubernetes#associate-vmcluster-with-dce)を実行します。DCE の「リソース」と既存の関連付けを確認し、別の DCE が関連付いている場合は置き換えず管理者と調整してください。

```powershell
$subscriptionId = '<承認した Subscription ID>'
$arcId = '<Arc サーバーの JSON ビューの id>'
$dceId = '<DCE の JSON ビューの id>'
az monitor data-collection rule association list `
    --resource $arcId --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw '既存の関連付け取得に失敗しました。' }
```

表示された `dataCollectionEndpointId` が空で、新たに関連付ける場合だけ次を実行します。同じ DCE の関連付けがあれば追加不要です。

```powershell
az monitor data-collection rule association create `
    --association-name configurationAccessEndpoint `
    --data-collection-endpoint-id $dceId --resource-uri $arcId `
    --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw 'DCE の関連付けに失敗しました。' }
```

AMA の直接接続を明示設定する場合は、次を実行します。[公式拡張機能 CLI](https://learn.microsoft.com/cli/azure/connectedmachine/extension#az-connectedmachine-extension-update)で既存 settings を取得し、proxy だけを `none` に変えます。CLI の拡張機能が不足する場合は、公式コマンドページのインストール手順に従って準備してください。

```powershell
$subscriptionId = '<承認した Subscription ID>'
$resourceGroup = '<Arc サーバーの RG>'
$machineName = '<Portal にある Arc サーバー名>'
$raw = az connectedmachine extension show --name AzureMonitorWindowsAgent `
    --machine-name $machineName --resource-group $resourceGroup `
    --subscription $subscriptionId --output json
if ($LASTEXITCODE -ne 0) { throw 'AMA の設定取得に失敗しました。' }
$extension = ($raw -join "`n") | ConvertFrom-Json -AsHashtable
if ($extension.publisher -ne 'Microsoft.Azure.Monitor') {
    throw '対象の拡張機能は AMA ではありません。'
}
$settings = $extension.settings
if ($null -eq $settings) { $settings = @{} }
$settings['proxy'] = @{ mode = 'none' }
$file = New-TemporaryFile
try {
    $settings | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $file.FullName -Encoding utf8NoBOM
    az connectedmachine extension update --name AzureMonitorWindowsAgent `
        --machine-name $machineName --resource-group $resourceGroup `
        --subscription $subscriptionId --settings ('@' + $file.FullName)
    if ($LASTEXITCODE -ne 0) { throw 'AMA の Proxy 設定に失敗しました。' }
} finally {
    Remove-Item -LiteralPath $file.FullName
}
```

操作後は Portal の拡張機能で `Succeeded` と `settings.proxy.mode=none` を確認します。AMA の配布失敗と稼働通信は分けて扱い、配布先を許可する場合も対象と期間を限定してください。

## 根拠

- [Arc PLS と制約](https://learn.microsoft.com/azure/azure-arc/servers/private-link-security)
- [Portal が生成する公式導入・登録スクリプト](https://learn.microsoft.com/azure/azure-arc/servers/onboard-portal)
- [Arc の Proxy / bypass](https://learn.microsoft.com/azure/azure-arc/servers/manage-agent-proxy-settings)
- [Arc ネットワーク要件](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements)
- [Explicit Proxy](https://learn.microsoft.com/azure/firewall/explicit-proxy)
- [Firewall の DNS 設定](https://learn.microsoft.com/azure/firewall/dns-settings)
- [Premium の Application 規則と TLS 検査](https://learn.microsoft.com/azure/firewall/premium-portal#rule-configuration)
- [DCE の関連付け](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-vm-kubernetes)
- [AMA のネットワーク設定](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
