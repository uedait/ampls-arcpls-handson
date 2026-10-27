# ② 既存 Azure VM のログを AMPLS 経由で収集する

[README](../README.md) → [事前確認](prerequisites.md) → ② → [③ オンプレミス](03-onpremises.md)

## この章の完了条件

対象 Azure VM の AMA が DCE から設定を取得し、LAW の公開取り込みを無効にした状態で、検証用イベントと Heartbeat が到着します。名前解決と実際の接続先が AMPLS PE の IP であることも確認します。

以下は新規の専用収集リソースを作る手順です。同じ DNS 解決範囲に既存 AMPLS がある場合は、[事前確認](prerequisites.md)で競合と影響を確認し、管理者の承認を得てから進めてください。

①のラボでは workload VM の専用 PIP を維持し、NIC NSG は Restricted の状態で実施します。AMA の初回配布に公開宛先が必要な場合は、配布先と必要な通信を特定して変更を承認してください。配布用の例外は対象・期間を限定し、例外終了後の Restricted 状態で閉域収集の合否を判定します。

## 2-1. Log Analytics Workspace を作成する

操作場所は Azure Portal です。

1. 上部の検索で「Log Analytics ワークスペース」を開き、「作成」を選びます。
2. 次を指定します。

   | 項目 | 入力 |
   |---|---|
   | サブスクリプション / RG | 事前確認で承認した作業先 |
   | 名前 | `law-handson` など、記録した名前 |
   | リージョン | 対象 VM と同じ。例 Japan East |

3. 「確認および作成」で費用と入力値を確認し、作成します。
4. 作成後の「概要」で Workspace ID と完全なリソース ID を記録します。
5. 「使用量と推定コスト」で保持期間、日次上限、取り込みプランを確認します。日次上限に到達すると検証ログも止まるため、ログが到着しない場合は上限の到達状況も確認してください。
6. 「ネットワーク分離」で、取り込みの公開アクセスを「無効 / いいえ」にします。作成直後にこの項目が選べない場合は、2-4 の PE 承認後、**AMA を関連付ける前に**設定します。

クエリの公開アクセスは、本ハンズオンでは承認した閲覧端末から Portal の Logs を使える設定を維持します。取り込みとクエリのアクセス設定は個別に確認してください。クエリも閉域にする場合は、閲覧端末に PE の名前解決・接続経路を用意してから変更します。

**確認**: LAW の Provisioning state が Succeeded。作成先とリージョンが記録どおりであること。

## 2-2. Data Collection Endpoint を作成する

1. Portal の「Monitor」から「データ収集エンドポイント」を開き、「作成」を選びます。
2. 作業用 RG、名前 `dce-handson`、対象 VM と同じリージョンを指定します。
3. プラットフォームを指定する画面では Windows を選択し、作成します。
4. DCE の概要にある「構成アクセス エンドポイント」のホスト名を記録します。URL の `https://` や末尾のパスを除いた FQDN を、後で DNS 検証に使用します。

DCE は AMA が DCR 等の設定を取得するために必要です。本編の Windows Event の送信先は LAW です。2-6 で DCE を対象 VM の設定取得先として関連付けてください。

**確認**: DCE と VM のリージョンが一致すること。

## 2-3. AMPLS を作成して LAW と DCE を追加する

1. Portal の検索で「Azure Monitor Private Link Scopes」を開き、「作成」を選びます。
2. サブスクリプション、作業用 RG、名前 `ampls-handson` を指定します。
3. 取り込みのアクセスモードを `Private Only` にします。クエリは事前確認の方針に合わせ、このハンズオンの初期値は `Open` とします。
4. 作成した AMPLS を開き、「Azure Monitor リソース」で「追加」を選びます。
5. **LAW と DCE の両方**を追加します。対象名とリソース ID を照合します。

AMA の設定取得には DCE、ログ送信には LAW の関連付けを使用します。DCR は 2-6 で対象 VM に関連付けてください。

**確認**: AMPLS の関連付け一覧に LAW と DCE の2件があること。既存の関連付けも作業前の記録どおり維持されていること。

## 2-4. AMPLS の Private Endpoint と DNS を構成する

1. AMPLS の「Private Endpoint 接続」から Private Endpoint を作成します。
2. 次を指定します。

   | タブ / 項目 | 入力 |
   |---|---|
   | 基本 | `pe-ampls-handson`、hub と同じリージョン |
   | リソース | 作成した AMPLS、サブリソース `azuremonitor` |
   | 仮想ネットワーク | hub VNet、IP に余裕のある PE subnet |
   | DNS | Private DNS zone と統合する |

3. DNS は、次の5 zone と整合する構成にします。既存 zone がある場合は、管理者が承認した zone を選んで統合してください。

   ```text
   privatelink.monitor.azure.com
   privatelink.oms.opinsights.azure.com
   privatelink.ods.opinsights.azure.com
   privatelink.agentsvc.azure-automation.net
   privatelink.blob.core.windows.net
   ```

4. PE を作成し、接続状態が `Approved`、デプロイが成功したことを確認します。承認待ちなら、リソース所有者に承認を依頼します。
5. 各 Private DNS zone の「仮想ネットワーク リンク」で、**Resolver Inbound endpoint がある hub VNet**へのリンクを確認します。リンクの自動登録は無効にしてください。
6. PE の「DNS の構成」で、FQDN と Private IP の全一覧を記録します。実際に作成された A レコードを各 zone で照合してください。名前解決には DNS zone のレコードを使用します。
7. AMPLS 側の PE 接続と、LAW / DCE の関連付けが残っていることを確認します。
8. LAW の公開取り込みが無効であることを再確認します。DCE のネットワーク分離でも、Private Link からの設定取得を維持したまま公開アクセスを無効にします。

**確認**: PE は複数の IP を使用します。必要な IP の確保と接続承認の完了を確認してから進んでください。AMPLS の PE には少なくとも /27 の subnet が必要で、このサンプルは /24 を使用します。

## 2-5. Azure VM から名前解決する

1. 専用の対象 Azure VM に、承認された管理接続でサインインします。①の講師用ラボでは、workload VM の「接続 → Bastion」から接続してください。
2. DNS は既存の設計を維持します。任意ラボは Resolver Inbound IP を使用します。お客様環境では、既存 DNS が対象公開ドメインを Resolver へ転送する経路を管理者が用意してください。
3. Windows PowerShell で、記録した実際の値を使用します。

   ```powershell
   Get-DnsClientServerAddress -AddressFamily IPv4
   Resolve-DnsName '<DCE の構成アクセス FQDN>'
   Resolve-DnsName '<Workspace ID>.ods.opinsights.azure.com'
   Test-NetConnection '<DCE の構成アクセス FQDN>' -Port 443
   Test-NetConnection '<Workspace ID>.ods.opinsights.azure.com' -Port 443
   ```

**期待結果**: A レコードの IP が PE 一覧に含まれ、TCP 443 が成功します。CNAME 自体は公開ドメインでも、最終的な A レコードが PE の IP なら想定した解決です。ログの到着は 2-7 で別途確認してください。

## 2-6. DCR を作成し AMA と DCE を関連付ける

1. Portal の「Monitor → データ収集ルール → 作成」を開きます。
2. RG、名前 `dcr-handson-windows`、LAW と同じリージョンを指定します。
3. DCE の選択欄で `dce-handson` を選びます。従来の画面では「プラットフォームの種類 = Windows」を指定します。新しい画面では Windows Event を収集できるテレメトリ種別を選びます。項目名が異なる場合は[公式手順](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection)の新旧画面を確認してください。
4. 「リソース」で対象 Azure VM を1台だけ追加します。マネージド ID が必要です。新規の専用 VM はシステム割り当て ID を有効にします。既存ユーザー割り当て ID がある VM は、利用先と管理方針を確認して適切な ID を選んでください。
5. 従来の画面にある「データ収集エンドポイントを有効にする」で対象 DCE を選びます。画面にない場合は、作成後に DCE の「リソース → 追加」から対象 VM を関連付けます。
6. 「収集と配信 / データソース」で Windows Event Logs を追加します。「カスタム」の XPath に次を指定します。

   ```text
   Application!*[System[(EventID=9001) and Provider[@Name='AmplsArcHandson']]]
   ```

7. 送信先は Azure Monitor Logs の `law-handson` を選び、収集対象は上記 XPath のイベントに限定してください。
8. 確認して作成します。Portal は関連付けた対象に AMA がなければ拡張機能を導入します。AMA の導入はこの DCR 関連付けの操作で行います。
9. 対象 VM の「拡張機能とアプリケーション」で `AzureMonitorWindowsAgent` が Provisioning succeeded になるまで確認します。
10. DCR の「リソース」と DCE の「リソース」で、それぞれ対象 VM が存在することを確認します。DCR に DCE を記入したことと、**VM に設定取得用 DCE が関連付いていること**は別の確認項目です。

AMA を明示的に直接接続へ設定します。管理端末の PowerShell 7 で、Azure CLI に対象テナントでサインインし、`az account show` の tenant / subscription を目視でも照合してから実行してください。スクリプトが同じ照合を行い、対象の AMA が存在しない場合は停止します。

Portal で設定取得用 DCE の関連付けが選べない場合は、管理端末で次の補助スクリプトを使用します。別の DCE が既に関連付いている場合は、置き換えず停止します。

```powershell
.\scripts\Set-DceAssociation.ps1 `
  -ExpectedTenantId '<Tenant ID>' `
  -ExpectedSubscriptionId '<Subscription ID>' `
  -ResourceId '<Azure VM の完全なリソース ID>' `
  -DceId '<DCE の完全なリソース ID>'
```

```powershell
.\scripts\Set-AmaDirect.ps1 `
  -ExpectedTenantId '<Tenant ID>' `
  -ExpectedSubscriptionId '<Subscription ID>' `
  -ResourceType AzureVm `
  -ResourceGroup '<Azure VM の RG>' `
  -MachineName '<Azure VM 名>'
```

この設定で Agent は `{"proxy":{"mode":"none"}}` を使用します。スクリプトは既存 settings を取得し、proxy だけを変更して、ほかの設定を維持します。

**確認**: AMA の導入成功、DCR 関連付け、設定取得用 DCE 関連付けの3点を記録してください。これらをそろえてからログの到着を確認します。

## 2-7. 検証用イベントを1件送る

1. 対象 Azure VM に `scripts\Write-HandsonEvent.ps1` をコピーします。①の講師用ラボでは、[Bastion のネイティブ RDP 接続](01-lab.md)を使用してください。
2. 管理者の Windows PowerShell で実行します。

   ```powershell
   .\Write-HandsonEvent.ps1
   ```

3. 出力された Marker、生成 UTC 時刻、Computer を作業記録に残します。
4. Portal の LAW →「ログ」で、[結果の確認](validation.md)の KQL を実行します。

**期待結果**: 対象 VM の Heartbeat と、Source `AmplsArcHandson` / EventID `9001` / 今回の Marker を含む Event が到着します。初回設定の反映に時間がかかる場合があります。15分を本ハンズオンの初回確認の目安として、到着しなければ時刻を記録して[障害調査](troubleshooting.md)へ進んでください。

公開取り込み Disabled の状態で判定した結果を記録してから③に進んでください。公開取り込みを有効にして判定すると公開経路の通信を閉域収集と誤認するリスクがあるため、その設定で合格としないでください。

## 根拠

- [AMPLS / PE / DNS の構成](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-configure)
- [AMA の Private Link と DCE 関連付け](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-vm-kubernetes)
- [DCR の Portal 作成と AMA 導入](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection)
- [Windows Event と XPath](https://learn.microsoft.com/azure/azure-monitor/vm/data-collection-windows-events)
- [AMA の Proxy 設定](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-network-configuration)
