# ② 既存 Azure VM のログを AMPLS 経由で収集する

[README](../README.md) → [① 検証用ラボ（任意）](01-lab.md) → ② → [③ オンプレミス](03-onpremises.md)

## この章の完了条件

対象 Azure VM の Azure Monitor Agent（AMA）が Data Collection Endpoint（DCE）から設定を取得し、Log Analytics Workspace（LAW）へ新しい Heartbeat を送信することを確認します。合格には、DCE の公開アクセス無効、LAW の公開取り込み無効、Azure Monitor Private Link Scope（AMPLS）の取り込み PrivateOnly、Restricted NSG、DNS と TCP の成功、AMA 自身の DCE と LAW への接続先がそれぞれ Private Endpoint（PE）の IP、制限確認後の新しい Heartbeat のすべてが必要です。Windows イベントの生成と確認は任意試験です。

以下は新規の専用収集リソースを作る手順です。同じ DNS 解決範囲に既存 AMPLS がある場合は、競合と既存監視への影響を確認し、管理者の承認を得てから進めてください。

①のラボでは workload VM の専用 PIP を維持し、NIC NSG は Restricted の状態で実施します。AMA の初回配布に公開宛先が必要な場合は、配布先と必要な通信を特定して変更を承認してください。配布用の例外は対象・期間を限定し、例外終了後の Restricted 状態で閉域収集の合否を判定します。

### 画面例の環境

画面例は 2026 年 10 月 31 日の Azure Portal で撮影した実画面です。名前は次の専用ラボの値を使用しています。実施時には、作成先、名前、ID、FQDN、観測時刻を承認した環境の値に置き換えてください。

| 対象 | 画面例の値 |
|---|---|
| RG / リージョン | `rg-1031-lab` / Japan East |
| 対象 Azure VM | `lab1031-workload` |
| LAW / DCE | `law-lab1031` / `dce-lab1031` |
| AMPLS / PE | `ampls-lab1031` / `pe-ampls-lab1031` |
| DCR | `dcr-lab1031-windows` |
| hub / PE subnet | `lab1031-hub` / `snet-pe` |

画面例は操作箇所を示します。過去のログ結果は今回の合格判定に使わず、実施者が今回の対象と時刻で確認してください。認証情報は画像や作業記録に含めないでください。

## 2-1. Log Analytics Workspace を作成する

操作場所は Azure Portal です。

1. 上部の検索で「Log Analytics ワークスペース」を開き、「作成」を選びます。

   ![Portal 上部の検索窓に「Log Analytics ワークスペース」と入力した状態](images/02-azure/2-1-01-law-search.png)

2. 次を指定します。

   | 項目 | 入力 |
   |---|---|
   | サブスクリプション / RG | 今回使用する作業先。①のラボを使用する場合は、①で指定したサブスクリプションとラボ専用 RG |
   | 名前 | `law-lab1031` など、記録した名前 |
   | リージョン | 対象 VM と同じ。例 Japan East |

   ![LAW の作成画面で RG、名前、日本東を指定した状態](images/02-azure/2-1-02-law-basics.png)

3. 「確認および作成」で費用と入力値を確認し、作成します。

   ![LAW の作成先、名前、リージョンと従量課金プランの確認画面](images/02-azure/2-1-03-law-review.png)

4. 作成後の「概要」で、作成したワークスペースを確認します。

   ![作成した LAW の概要と Workspace ID](images/02-azure/2-1-04-law-overview.png)

5. 「使用量と推定コスト」で保持期間、日次上限、取り込みプランを確認します。日次上限に到達すると検証ログも止まるため、ログが到着しない場合は上限の到達状況も確認してください。

   ![LAW の使用量と推定コストで従量課金プランを確認する画面](images/02-azure/2-1-05-law-cost.png)

   ![LAW の日次上限を1GBに設定した確認画面](images/02-azure/2-1-06-law-dailycap.png)

   ![LAW の保持期間を30日に設定した確認画面](images/02-azure/2-1-07-law-retention.png)

公開取り込みの制限は、初回 Heartbeat を確認した後の [2-8](#restricted-check) で行います。既に制限済みの環境は、その設定を維持してください。Portal で結果を見るため、クエリの公開アクセスは有効のままにします。閲覧には Azure の認証と RBAC の閲覧権限が必要です。

確認: 概要で「成功」と、指定した RG・リージョンを確認します。

## 2-2. Data Collection Endpoint を作成する

1. Portal の検索で「監視」を開き、「設定 → データ収集エンドポイント → 作成」を選びます。「監視」は Azure Monitor の検索名で、画面のタイトルは「モニター」と表示されます。

   ![Portal で Azure Monitor の監視サービスを検索した画面](images/02-azure/2-2-01-monitor-search.png)

   ![Monitor の設定メニューにあるデータ収集エンドポイント](images/02-azure/2-2-02-monitor-menu.png)

2. 作業用 RG、名前 `dce-lab1031`、対象 VM と同じリージョンを指定します。

   ![DCE の名前、作成先 RG、日本東を指定した作成画面](images/02-azure/2-2-03-dce-basics.png)

3. プラットフォームを指定する画面では Windows を選択し、作成します。

   ![DCE の入力値の確認画面](images/02-azure/2-2-04-dce-review.png)

4. DCE の「概要」の右上にある「構成アクセス」の値をコピーします。「ログ インジェスト」の行は使いません。

   ![作成した DCE の概要と構成アクセスエンドポイント](images/02-azure/2-2-05-dce-overview.png)

<a id="dce-fqdn"></a>

DNS 検証に使う DCE FQDN は、この「構成アクセス」の URL のホスト名です。画面例の完全な値は `dce-lab1031-e74e.japaneast-1.handler.control.monitor.azure.com` です。名前から推測せず、今回のリソースの値をコピーしてください。URL から取り出す場合は VM の Windows PowerShell で次を使用します。

```powershell
$configurationAccess = '<今回コピーした構成アクセス URL 全体>'
([uri]$configurationAccess).DnsSafeHost
```

DCE は AMA が Data Collection Rule（DCR）の設定を取得するために必要です。DCR は収集対象と保存先を定義し、送信先は LAW です。2-6 で DCE を対象 VM の設定取得先として関連付けてください。

**確認**: DCE と VM のリージョンが一致すること。

## 2-3. AMPLS を作成して LAW と DCE を追加する

1. Portal の検索で「Azure Monitor Private Link Scopes」を開き、「作成」を選びます。

   ![Azure Monitor Private Link Scopes を検索した画面](images/02-azure/2-3-01-ampls-search.png)

   ![AMPLS 一覧の作成ボタン](images/02-azure/2-3-02-ampls-list.png)

2. サブスクリプション、作業用 RG、名前 `ampls-lab1031` を指定します。
3. 取り込みのアクセスモードを `Private Only` にします。クエリのアクセスモードは `Open` とします。

   ![AMPLS の名前、RG、クエリ Open と取り込み Private Only の入力画面](images/02-azure/2-3-03-ampls-basics.png)

   ![AMPLS の入力値とアクセスモードの確認画面](images/02-azure/2-3-04-ampls-review.png)

4. 作成した AMPLS を開き、「構成 → Azure Monitor リソース」で「追加」を選びます。

   ![作成した AMPLS の概要](images/02-azure/2-3-05-ampls-overview.png)

5. **LAW と DCE の両方**を追加します。画面例の「範囲の選択」では1件ずつ選ぶため、LAW を選んで適用し、もう一度「追加」から DCE を選んで適用します。対象名とリソース ID を照合します。

   ![作業先を絞り込んで LAW を1件選択する画面](images/02-azure/2-3-07-ampls-add-law.png)

   ![同じ作業先の DCE を1件選択する画面](images/02-azure/2-3-08-ampls-add-dce.png)

   ![LAW と DCE の両方が関連付いた AMPLS の一覧](images/02-azure/2-3-06-ampls-resources.png)

AMA の設定取得には DCE、ログ送信には LAW の関連付けを使用します。DCR は 2-6 で対象 VM に関連付けてください。

<a id="ampls-resources"></a>

確認: AMPLS の「構成 → Azure Monitor リソース」で、今回の LAW と DCE の2行を確認します。[一覧の画面例](images/02-azure/2-3-06-ampls-resources.png)と照合し、既存の関連付けも維持します。

## 2-4. AMPLS の Private Endpoint と DNS を構成する

1. AMPLS の「Private Endpoint 接続」から Private Endpoint を作成します。

   ![AMPLS の Private Endpoint 接続画面にある作成操作](images/02-azure/2-4-01-pe-connections.png)

2. 次を指定します。

   | タブ / 項目 | 入力 |
   |---|---|
   | 基本 | `pe-ampls-lab1031`、hub と同じリージョン |
   | リソース | 作成した AMPLS、サブリソース `azuremonitor` |
   | 仮想ネットワーク | hub VNet、IP に余裕のある PE subnet |
   | DNS | Private DNS zone と統合する |

   ![PE の名前、NIC 名、RG、日本東を入力した画面](images/02-azure/2-4-02-pe-basics.png)

   ![接続先の AMPLS とサブリソース azuremonitor を選択した画面](images/02-azure/2-4-03-pe-resource.png)

   ![hub VNet、snet-pe と動的 IP 割り当ての選択画面](images/02-azure/2-4-04-pe-vnet.png)

3. DNS タブで「プライベート DNS ゾーンと統合する」を「はい」にします。承認済みの既存ゾーンがなければ、次の5つのゾーンを新規作成する設定にし、各ゾーンの作成先 RG を確認します。画面にゾーン名が自動表示される場合は手入力不要です。手動で作成する場合は、次の名前をそのまま入力します。既存ゾーンを再利用する場合は、今回の利用を承認したゾーンだけを選択してください。

   ```text
   privatelink.monitor.azure.com
   privatelink.oms.opinsights.azure.com
   privatelink.ods.opinsights.azure.com
   privatelink.agentsvc.azure-automation.net
   privatelink.blob.core.windows.net
   ```

   ![5つの Private DNS zone をラボ RG へ新規作成する統合設定](images/02-azure/2-4-05-pe-dns.png)

   ![PE の接続先、仮想ネットワークと DNS の確認画面](images/02-azure/2-4-06-pe-review.png)

4. PE を作成し、接続状態が `Approved`、デプロイが成功したことを確認します。承認待ちなら、リソース所有者に承認を依頼します。

   ![PE の作成後に hub、subnet、NIC と承認済み状態を確認した概要](images/02-azure/2-4-07-pe-overview.png)

5. 各 Private DNS zone の「仮想ネットワーク リンク」で、Resolver Inbound endpoint がある hub VNet へのリンクを確認し、なければ追加します。自動登録は無効にします。PE の A レコードは PE の DNS 統合で管理します。このゾーンへの VM 名の自動登録は不要です。自動登録が無効でも、リンクを通じた名前解決は利用できます。

   ![Monitor zone の hub リンク、Completed と自動登録無効](images/02-azure/2-4-10-monitor-link.png)

   ![OMS zone の hub リンク、Completed と自動登録無効](images/02-azure/2-4-11-oms-link.png)

   ![ODS zone の hub リンク、Completed と自動登録無効](images/02-azure/2-4-12-ods-link.png)

   ![Agent service zone の hub リンク、Completed と自動登録無効](images/02-azure/2-4-13-agentsvc-link.png)

   ![Blob zone の hub リンク、Completed と自動登録無効](images/02-azure/2-4-14-blob-link.png)

6. PE の「DNS の構成」で、FQDN と Private IP の全一覧を記録します。実際に作成された A レコードを各 zone で照合してください。名前解決には DNS zone のレコードを使用します。

   ![PE の顧客向け FQDN と Private IP の対応一覧](images/02-azure/2-4-08-pe-fqdn.png)

   ![Private DNS zone と実際の A レコード、IP、zone group の一覧](images/02-azure/2-4-09-pe-zone-records.png)

<a id="law-ods-fqdn"></a>

   LAW の DNS 検証には、PE の「DNS の構成」で公開 FQDN `<guid>.ods.opinsights.azure.com` の行をコピーします。`privatelink` を含む別名は使いません。同じ行の Private IP を LAW の比較対象にします。Workspace ID を別途記録して組み立てる必要はありません。DCE の比較対象 IP も、[構成アクセス FQDN](#dce-fqdn)に対応する PE の行で確認します。

<a id="ampls-pe-approved"></a>

7. AMPLS の「構成 → プライベート エンドポイント接続」で、今回の `pe-ampls-lab1031` の行が `Approved` であることを確認します。

   ![AMPLS のプライベートエンドポイント接続の確認場所](images/02-azure/2-4-01-pe-connections.png)

   ![作成した PE の承認済み状態](images/02-azure/2-4-07-pe-overview.png)

8. 同じ AMPLS の「構成 → Azure Monitor リソース」で、今回の LAW と DCE の2行を確認します。

   ![LAW と DCE の関連付け一覧](images/02-azure/2-3-06-ampls-resources.png)

公開アクセスの制限は [2-8](#restricted-check) で行います。既に制限済みなら維持します。

**確認**: PE は複数の IP を使用します。必要な IP の確保と接続承認の完了を確認してから進んでください。AMPLS の PE には少なくとも /27 の subnet が必要で、このサンプルは /24 を使用します。

<a id="vm-dns-tcp"></a>

## 2-5. Azure VM から名前解決する

1. 対象 Azure VM の「接続 → Bastion」からサインインします。既存環境は承認済みの管理接続を使用します。VM の管理者ユーザー名は構築担当者から取得し、認証情報を手順書や作業記録に記載しないでください。Bastion の利用権限と VM のサインイン権限が必要です。VM のスタートメニューで「Windows PowerShell」を検索し、「管理者として実行」で Windows PowerShell 5.1 を開きます。
2. DNS は既存の設計を維持します。任意ラボは Resolver Inbound IP を使用します。お客様環境では、既存 DNS が対象公開ドメインを Resolver へ転送する経路を管理者が用意してください。
3. 次の取得場所から値をコピーし、VM の Windows PowerShell 5.1 で実行します。

   | 入力値 | 取得場所 |
   |---|---|
   | DCE FQDN | [DCE 概要の「構成アクセス」](#dce-fqdn)のホスト名 |
   | LAW ODS FQDN | [PE の「DNS の構成」](#law-ods-fqdn)の公開 ODS FQDN |
   | 各 FQDN の比較対象 IP | 同じ [PE の「DNS の構成」](#law-ods-fqdn)の対応する Private IP |

   ```powershell
   $dceFqdn = '<コピーした DCE の構成アクセス FQDN>'
   $lawFqdn = '<コピーした LAW の公開 ODS FQDN>'
   Get-DnsClientServerAddress -AddressFamily IPv4
   foreach ($fqdn in @($dceFqdn, $lawFqdn)) {
       Resolve-DnsName -Name $fqdn -ErrorAction Stop
       Test-NetConnection -ComputerName $fqdn -Port 443
   }
   ```

**期待結果**: A レコードの IP が PE 一覧に含まれ、TCP 443 が成功します。CNAME 自体は公開ドメインでも、最終的な A レコードが PE の IP なら想定した解決です。ログの到着は 2-7 で別途確認してください。

このコマンドは VM からの到達性を確認します。AMA 自身が利用した接続先は、導入後の [2-8](#ama-peers) で別途確認します。

## 2-6. DCR を作成し AMA と DCE を関連付ける

本手順は動作確認済みの Windows イベント DCR を使用します。Heartbeat は AMA の稼働に伴って自動送信されるため、DCR のデータソースとして「Heartbeat」を選択する操作はありません。以下の XPath と LAW 宛先は構成に残し、イベントの生成だけを任意試験に分けます。

1. Portal の「モニター → 設定 → データ収集ルール → データ収集ルールの作成」を開きます。

   ![Monitor のデータ収集ルールの作成操作](images/02-azure/2-6-01-dcr-create.png)

2. RG、名前 `dcr-lab1031-windows`、LAW と同じリージョンを指定します。
3. DCE の選択欄で `dce-lab1031` を選びます。画面例では「テレメトリの種類 = Agent-based - Windows or Linux」を選択します。収集するデータ ソースは Windows イベント ログに限定します。従来の画面では「プラットフォームの種類 = Windows」を指定します。項目名が異なる場合は[公式手順](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection)の新旧画面を確認してください。

   ![DCR の名前、作業先、日本東、Agent-based と DCE の指定画面](images/02-azure/2-6-02-dcr-basics.png)

4. 「リソース」で対象 Azure VM を1台だけ追加します。マネージド ID が必要です。新規の専用 VM はシステム割り当て ID を有効にします。既存ユーザー割り当て ID がある VM は、利用先と管理方針を確認して適切な ID を選んでください。

   ![対象の workload VM だけを選択する画面](images/02-azure/2-6-03-dcr-vm-select.png)

   ![対象 VM のシステム割り当て ID がオンの確認画面](images/02-azure/2-6-12-vm-identity.png)

5. 「データ収集エンドポイント列を表示する」を有効にし、対象 VM の行を選択して「データ収集エンドポイントの編集」から `dce-lab1031` を指定します。従来の画面では「データ収集エンドポイントを有効にする」を使用します。画面にない場合は、作成後に DCE の「リソース → 追加」から対象 VM を関連付けます。

   ![VM が設定取得に使う DCE を指定する入力画面](images/02-azure/2-6-04-dcr-vm-dce.png)

6. 「収集と配信 → 新しいデータ ソースを追加」で「Windows イベント ログ」を選択します。「イベント ログ選択モード」を「カスタム」にして次の XPath を入力し、「追加」で一覧へ反映します。

   ```text
   Application!*[System[(EventID=9001) and Provider[@Name='AmplsArcHandson']]]
   ```

   ![Windows イベント ログをカスタム XPath で収集する入力画面](images/02-azure/2-6-05-dcr-xpath.png)

7. 「宛先 → 宛先の追加」で「Log Analytics ワークスペース」の `law-lab1031` を選びます。収集対象は上記 XPath のイベントに限定してください。

   ![同じリージョンの LAW をイベントの送信先として選択した画面](images/02-azure/2-6-06-dcr-destination.png)

   ![Windows イベント ログ1件と LAW の収集・配信設定の一覧](images/02-azure/2-6-07-dcr-collection.png)

8. 確認して作成します。Portal は関連付けた対象に AMA がなければ拡張機能を導入します。AMA の導入はこの DCR 関連付けの操作で行います。

   ![DCR の対象 VM、DCE と Windows イベント送信先の確認画面](images/02-azure/2-6-08-dcr-review.png)

   ![作成後の Windows DCR、DCE と接続済みリソース1件の概要](images/02-azure/2-6-09-dcr-overview.png)

9. 対象 VM の「拡張機能とアプリケーション」で `AzureMonitorWindowsAgent` が Provisioning succeeded になるまで確認します。

   ![AMA と既存 Defender 拡張機能の Provisioning succeeded](images/02-azure/2-6-13-ama-extension.png)

   ![AMA の詳細で Success とハンドラー Ready を確認した画面](images/02-azure/2-6-14-ama-ready.png)

10. DCR の「リソース」と DCE の「リソース」で、それぞれ対象 VM が存在することを確認します。DCR に DCE を記入したことと、**VM に設定取得用 DCE が関連付いていること**は別の確認項目です。

    ![DCR のリソース一覧にある workload VM と設定取得用 DCE](images/02-azure/2-6-10-dcr-resources.png)

    ![DCE のリソース一覧に workload VM が1件関連付いている画面](images/02-azure/2-6-11-dce-resources.png)

AMA はプロキシを使わない直接接続 `proxy.mode=none` が必須です。対象 VM の AMA 拡張機能の「JSON ビュー」で settings の proxy を確認し、既存の設定・導入時の設定記録も照合します。proxy 設定がない新規ラボは既定の直接接続を使用します。ほかの proxy 設定がある場合、または直接接続を確認できない場合は、次の補助操作で `none` を明示設定してから進めます。

### 必要な場合だけ使う管理端末の補助操作

操作場所はリポジトリを配置した管理端末の PowerShell 7 です。VM 内では実行しません。承認済みの変更範囲を確認し、実施環境の認証手順で Azure CLI にサインインしてください。`az account show` の `tenantId`、`id`（Subscription ID）、`user`（実行 ID と認証種別）を今回の作業先と照合します。

Tenant ID は Portal の「Microsoft Entra ID → 概要」で、Subscription ID は対象サブスクリプションの「概要」で確認します。VM と DCE の完全なリソース ID が必要な場合は、そのリソースの Portal「概要 → JSON ビュー」の `id` をコピーします。VM の RG と名前は VM の概要で確認します。

Portal で設定取得用 DCE を関連付けられない場合だけ、リポジトリのルートで次を実行します。VM に DCE 関連付けを作成します。別の DCE が既に関連付いている場合は、置き換えず停止します。

```powershell
.\scripts\Set-DceAssociation.ps1 `
  -ExpectedTenantId '<Tenant ID>' `
  -ExpectedSubscriptionId '<Subscription ID>' `
  -ResourceId '<Azure VM の完全なリソース ID>' `
  -DceId '<DCE の完全なリソース ID>'
```

既存 proxy がある場合、または直接接続を確認できない場合だけ、次を実行して AMA の proxy を `none` に変更します。

```powershell
.\scripts\Set-AmaDirect.ps1 `
  -ExpectedTenantId '<Tenant ID>' `
  -ExpectedSubscriptionId '<Subscription ID>' `
  -ResourceType AzureVm `
  -ResourceGroup '<Azure VM の RG>' `
  -MachineName '<Azure VM 名>'
```

`Set-AmaDirect.ps1` は対象 VM の AMA 拡張機能に `{"proxy":{"mode":"none"}}` を設定します。既存 settings のうち proxy だけを変更し、ほかの設定を維持します。

**確認**: AMA の導入成功、DCR 関連付け、設定取得用 DCE 関連付けの3点を記録してください。これらをそろえてからログの到着を確認します。

## 2-7. 初回 Heartbeat を確認する

操作場所は Portal の今回の LAW「ログ」です。「作業モード」を「KQL モード」にし、「表示 → カスタム」で100件を指定します。対象 VM の「概要 → JSON ビュー」の `id` をコピーし、次の `targetResourceId` に貼り付けます。対象 VM の Computer と `_ResourceId` を照合してください。

```kusto
let targetResourceId = "<対象 Azure VM の JSON ビューの id>";
Heartbeat
| where TimeGenerated > ago(30m)
| where _ResourceId =~ targetResourceId
| where Category == "Azure Monitor Agent"
| project TimeGenerated, IngestedAt=ingestion_time(), Computer, _ResourceId
| order by TimeGenerated desc
| take 100
```

確認: 対象 VM の Heartbeat が到着します。初回設定の反映を15分程度待ち、到着しなければ検索期間、0件またはエラー、確認 UTC 時刻を記録して[障害調査](troubleshooting.md)へ進みます。初回到着だけでは閉域収集の合格としません。既に制限済みのラボも公開アクセスを再び有効にせず、次の設定確認と新規記録の試験を実施します。

<a id="restricted-check"></a>

## 2-8. 公開取り込みを制限して閉域収集を確認する

1. Portal の LAW「ネットワークの分離 → Public access → 管理」で、`Ingestion access` を「制限されたパブリック受信、有効なパブリック送信」にします。従来の画面では取り込みの公開アクセスを「無効 / いいえ」にします。`Query access` は「すべてのネットワークから有効」のまま維持します。検索には認証と RBAC 権限が必要です。

   ![LAW の取り込み制限と公開クエリ許可](images/02-azure/2-1-08-law-isolation.png)

2. DCE の「ネットワークの分離 → Public access → 管理」でも「制限されたパブリック受信、有効なパブリック送信」にして公開アクセスを無効にします。Private Link の設定取得を維持します。

   ![DCE の公開アクセス制限](images/02-azure/2-4-15-dce-isolation.png)

3. 保存・反映後の画面で LAW の取り込み無効、DCE の公開アクセス無効、AMPLS の取り込み PrivateOnly を確認します。[PE の Approved](#ampls-pe-approved)と [LAW / DCE の2行](#ampls-resources)、①の Restricted NSG も確認します。既に制限済みなら変更せず、現在の値を記録します。VM の PowerShell で次を実行し、この確認後の UTC 時刻を基準時刻として保存します。

   ```powershell
   [datetime]::UtcNow.ToString('o')
   ```

4. [2-5](#vm-dns-tcp)の DNS / TCP コマンドを再実行し、DCE と LAW の最終 A レコードがそれぞれ PE 一覧の対応する IP、TCP 443 が成功であることを確認します。

<a id="ama-peers"></a>

5. 同じ VM の管理者 Windows PowerShell 5.1 で次を実行します。最大5分、2秒間隔で AMA 自身の TCP 443 接続を読み取り、PID と実行ファイルを照合します。AMA の再起動や設定変更は行いません。

   ```powershell
   $deadline = [datetime]::UtcNow.AddMinutes(5)
   $seen = @{}
   do {
       $connections = @(Get-NetTCPConnection -State Established -ErrorAction Stop |
           Where-Object { $_.RemotePort -eq 443 })
       foreach ($connection in $connections) {
           $owner = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
           if ($null -eq $owner -or $owner.ProcessName -notin @('MonAgentManager', 'MonAgentCore')) {
               continue
           }
           try { $path = $owner.Path } catch { $path = $null }
           if ([string]::IsNullOrWhiteSpace($path)) { continue }
           $key = '{0}|{1}|{2}' -f $owner.Id, $path, $connection.RemoteAddress
           if (-not $seen.ContainsKey($key)) {
               $seen[$key] = $true
               [pscustomobject]@{
                   ObservedUtc = [datetime]::UtcNow.ToString('o')
                   ProcessId = $owner.Id
                   ProcessPath = $path
                   RemoteAddress = $connection.RemoteAddress
                   RemotePort = $connection.RemotePort
               }
           }
       }
       Start-Sleep -Seconds 2
   } while ([datetime]::UtcNow -lt $deadline)
   ```

   `ProcessPath` が対象 VM の AMA の実行ファイルであることを確認します。`MonAgentManager.exe` の接続先を DCE の PE IP、`MonAgentCore.exe` の接続先を LAW の PE IP と照合してください。短時間の接続は取得できない場合があります。5分で片方でも取得できなければ「接続未取得」と記録し、合格にはしません。必要なら同じ上限で再観測し、待機時間と結果を記録します。DNS / TCP の成功を AMA の実接続の証拠にはしません。

6. LAW の「ログ」で、基準 UTC 時刻を `restrictedSince` に、VM の JSON ビューの `id` を `targetResourceId` に貼り付けて実行します。

   ```kusto
   let targetResourceId = "<対象 Azure VM の JSON ビューの id>";
   let restrictedSince = todatetime("<設定確認後に記録した UTC 時刻>");
   Heartbeat
   | where TimeGenerated > ago(30m)
   | where _ResourceId =~ targetResourceId
   | where Category == "Azure Monitor Agent"
   | where TimeGenerated > restrictedSince and ingestion_time() > restrictedSince
   | project TimeGenerated, IngestedAt=ingestion_time(), Computer, _ResourceId
   | order by TimeGenerated desc
   | take 100
   ```

確認: 生成時刻と取り込み時刻が両方とも基準時刻より後の Heartbeat が到着し、上記の設定、DNS / TCP、AMA の両接続がすべて成立したら LOG-1 の合格を記録します。過去の記録や制限前の到着は合格判定に使いません。到着しなければ15分を目安に待ち、検索期間と0件またはエラーを記録します。LAW 取り込み無効、DCE 公開アクセス無効、AMPLS PrivateOnly、Restricted NSG を維持して③に進みます。

<a id="optional-event"></a>

## 2-9. 任意試験 LOG-1E: Windows イベントを1件送る

DCR の XPath で指定したイベントが収集されることを追加確認する場合に実施します。対象 VM の Bastion セッションで、管理者 Windows PowerShell 5.1 に次を貼り付けます。既存の同名ソースが別ログに属する場合は停止し、ソースがない場合だけ作成します。Application に EventID 9001 を1件書き込みます。

```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or
    $PSVersionTable.PSVersion -lt [version]'5.1') {
    throw 'Windows PowerShell 5.1 で実行してください。'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Windows PowerShell を管理者として実行してください。'
}
$source = 'AmplsArcHandson'
if ([Diagnostics.EventLog]::SourceExists($source) -and
    [Diagnostics.EventLog]::LogNameFromSourceName($source, '.') -ne 'Application') {
    throw '同名のイベントソースが別のイベントログに属しています。'
}
if (-not [Diagnostics.EventLog]::SourceExists($source)) {
    New-EventLog -LogName Application -Source $source
}
$marker = [guid]::NewGuid().ToString()
$utc = [datetime]::UtcNow.ToString('o')
Write-EventLog -LogName Application -Source $source -EventId 9001 `
    -EntryType Information -Message "AmplsArcHandson marker=$marker; utc=$utc"
[pscustomobject]@{ Marker = $marker; GeneratedUtc = $utc; Computer = $env:COMPUTERNAME; EventId = 9001; Source = $source }
```

既存の `scripts\Write-HandsonEvent.ps1` と同じ本文・出力形式です。出力された Marker、GeneratedUtc、Computer を保存します。LAW の「ログ」で次を実行し、対象 ID、今回の Marker、今回の生成 UTC 時刻を置き換えます。生成時刻の1分前から29分後までの30分、上限100件で確認します。

```kusto
let targetResourceId = "<対象 Azure VM の JSON ビューの id>";
let marker = "<今回出力された Marker>";
let generatedUtc = todatetime("<今回出力された GeneratedUtc>");
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

確認: 今回の Marker を含む対象 VM のイベントが到着したら LOG-1E の合格を記録します。未実施でも LOG-1 の基本試験は実施できます。初回は15分を目安に待ち、0件と検索失敗を区別して記録します。

次の画像は 2026年10月31日 07:23〜07:53 UTC の過去の任意イベント試験の参考です。今回の検証結果を示すものではありません。

![過去の任意イベント試験の KQL](images/02-azure/2-7-02-event-query.png)

![過去の任意イベント試験の結果](images/02-azure/2-7-03-event-result.png)

## 根拠

- [AMPLS / PE / DNS の構成](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure)
- [AMA の Private Link と DCE 関連付け](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-vm-kubernetes)
- [DCR の Portal 作成と AMA 導入](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection)
- [Windows Event と XPath](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection-windows-events)
- [AMA の Proxy 設定](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
