# ① 任意：検証用ラボの構築

[トップ](../README.md) | [前提条件](./prerequisites.md) | [② Azure VM](./02-azure.md) | [③ オンプレミス Windows](./03-onpremises.md)

本番に近いネットワークと既存 Windows サーバーを再現するための任意章です。
既存環境を使用する場合は、この章を省略して②③へ進みます。

**実行すると費用が発生します。** Azure Firewall Standard、Azure Bastion Standard、DNS Private Resolver、3 台の Azure VM、ディスク、計5個の Public IP（Firewall・Bastion・各 VM）を予算に含めてください。VM の割り当て解除後も Bastion、Firewall、Resolver、Public IP、ディスク等の課金は続くため、終了時には対象を確認して削除します。リージョン別の提供状況、見積額、利用可能クォータ、割り当て可能容量を実行前に確認してください。

// 想定費用、約　￥　/日

サブスクリプションで Defender for Servers などの有料機能が有効な場合、作成した VM も課金対象になることがあります。自動的に導入される拡張機能と、その費用も実行前に確認してください。

## 1. 実施者が行うことと自動構築すること

実施者は、管理端末でコマンドを実行し、入力と実行承認を行います。以降はスクリプトがリソース作成、各 VM の構成、L2 の生成、確認、Internet 制限までを進めます。完了表示後に Bastion で各 VM の状況を確認してください。

| 順番 | 実施内容 | 実施者 |
|---|---|---|
| 1 | 一括デプロイのコマンドを実行 | 人 |
| 2 | サブスクリプション、RG、名前の接頭辞、管理者情報を入力し、計画を承認 | 人 |
| 3 | VNet、Firewall、Bastion、Resolver、3 VM と各 PIP・NSG をデプロイ | スクリプト |
| 4 | 完全なコミット SHA を固定し、各 VM が同じコミットの ZIP を GitHub から取得・展開 | スクリプト |
| 5 | DNS ロール、Hyper-V、再起動、公式 ISO からの L2 無人構築を実行 | スクリプト |
| 6 | L1 から PowerShell Direct で L2 に本編用スクリプトを配置し、状態を確認 | スクリプト |
| 7 | 必要ファイルと構成結果を照合し、3台の NSG を Restricted に切替・検証 | スクリプト |
| 8 | CLI の完了結果を確認し、Bastion で各 VM に接続 | 人 |

自動化の構成、資格情報の扱い、判定方法は[一括デプロイの実行設計](automation.md)を参照してください。

## 2. 管理端末を準備する

- PowerShell 7、Azure CLI、GitHub CLI と Bicep を用意してください。実行端末から Azure、GitHub API と codeload.github.com に HTTPS 接続できることを確認します。
- Azure には、専用 RG の作成、ネットワーク・VM・Bastion・Resolver の作成、VM 再起動、Managed Run Command の作成・実行を許可された実施者のアカウント、または証明書で事前認証したサービスプリンシパルを使用します。
- Private リポジトリには、読み取り権限のある GitHub アカウントを使用します。サインインが必要な場合は、コマンドの案内に従い管理端末で対話認証してください。
- 既定の L1 サイズ `Standard_D8s_v5` について、リージョンの提供状況、Gen2・Nested Virtualization 対応、容量とクォータを確認します。
- Windows Server 評価版の利用条件に従って使用してください。既定の ISO はコードに定義した Microsoft 公式 Windows Server 2022 x64 英語評価版です。

VM に Git や GitHub CLI を事前導入する作業は、構築の前提に含めません。各 VM は Managed Run Command から渡された短期 URL を使用し、PowerShell で ZIP を取得します。

### 使用するコミット

既定では `main` を一度だけ完全なコミット SHA に解決し、その ZIP に含まれる Bicep とゲストスクリプトを使用します。実行途中の `main` 更新による混在を防ぐため、以降の取得は同じ SHA に固定します。

Private リポジトリの長期 GitHub トークンは管理端末で使用し、VM には短期の ZIP 取得 URL を保護パラメーターで渡します。取得した ZIP のハッシュと必要ファイルを照合してください。詳細は[実行設計](automation.md)に記載しています。

ローカルで変更しただけのコードは VM の取得対象には含まれません。変更を使用する場合は、そのコミットをリポジトリへ反映してから `-SourceRef` に指定してください。公開済みコミットに必要な自動化ファイルがそろっていない場合は、リソース作成前に停止します。

## 3. 一括デプロイを実行する

取得したリポジトリのルートで、PowerShell 7 から実行してください。

```powershell
.\infra\lab\Deploy-Lab.ps1
```

### 証明書で認証したサービスプリンシパルを使う場合

実施環境の認証手順で証明書による Azure CLI ログインと接続先の確認を済ませ、同じ PowerShell プロセスで専用の認証キャッシュと3つの ID を指定します。次の値は実施環境の値に置き換えてください。証明書、秘密鍵、認証キャッシュをリポジトリに保存しないでください。

```powershell
$env:AZURE_CONFIG_DIR = '<事前認証した専用キャッシュの絶対パス>'
.\infra\lab\Deploy-Lab.ps1 `
    -TenantId '<Tenant ID>' `
    -SubscriptionId '<Subscription ID>' `
    -ClientId '<サービスプリンシパルのクライアント ID>'
```

この実行では、スクリプトが再ログインやサブスクリプションの選択変更を行うことはありません。接続情報と実行 ID が一致しなければ停止します。証明書認証に対応したコミットを公開してから実行してください。認証の責任分担と再照合の詳細は[実行設計](automation.md#azure-の認証と接続先)を参照してください。

### 構築内容を確認する

対話では次の値を確認します。

| 項目 | 既定値・方針 |
|---|---|
| サブスクリプション | 利用者ログインでは選択中の ID を既定として確認。サービスプリンシパルでは引数で指定した ID を照合 |
| RG | `rg-arclab-lab`。新規または空の専用 RG |
| 名前の接頭辞 | `arclab`。VM 名は `-workload`、`-dns`、`-hyperv` を付ける |
| Azure VM の管理者 | 既定ユーザー名 `labadmin`。3台に使うパスワードを非表示で入力 |
| L2 の管理者 | `Administrator` のパスワードを非表示で入力 |
| 実行承認 | 対象、コミット、課金対象、Nested 対応・クォータ・予算・期限を確認して `APPROVE` |

ISO の URL・SHA-256・利用条件の確認を追加のヒアリング項目には含めません。既定の公式配布物から取得し、SHA-256 は取得ファイルの識別とキャッシュ照合に使用します。公開元の既知ハッシュとの照合とは区別してください。

既知の値を引数で渡す場合は、次のように実行できます。パスワードは対話で入力してください。

```powershell
.\infra\lab\Deploy-Lab.ps1 `
    -SubscriptionId '<Subscription ID>' `
    -ResourceGroupName 'rg-arclab-lab' `
    -Prefix 'arclab' `
    -Location 'japaneast' `
    -SourceRef '<使用する完全なコミット SHA>'
```

実行中は段階名と状態を CLI に表示します。VM 内でスクリプトを手動実行する操作や、L1 の再起動ボタンの操作は、自動構築の通常手順には含めません。

サービスプリンシパルで単独のゲスト操作を行う場合は `Invoke-LabGuest.ps1` に `-TenantId`、`-SubscriptionId`、`-ClientId` を指定します。`Set-LabInternetAccess.ps1` では `-ExpectedTenantId`、`-ExpectedSubscriptionId`、`-ExpectedClientId` を指定します。いずれも事前認証した専用の `AZURE_CONFIG_DIR` が必要です。操作内容の承認は各スクリプトで別途行います。

## 4. 自動構築される内容

| ネットワーク | 対象 | 設定 |
|---|---|---|
| spoke1 `10.10.0.0/16` | workload VM | Windows Server 2022、`10.10.1.4`、既定 `Standard_D2s_v5` |
| hub `10.20.0.0/16` | Azure Firewall Standard と Policy | AzureFirewallSubnet `10.20.0.0/26`、専用 Public IP |
| 同上 | PE 用の空き subnet | `10.20.1.0/24` |
| 同上 | DNS Private Resolver Inbound | subnet `10.20.2.0/28`、IP `10.20.2.4` |
| 同上 | Bastion Standard | AzureBastionSubnet `10.20.3.0/26`、2インスタンス、専用 Public IP、ネイティブクライアント対応 |
| onpre `10.30.0.0/16` | Windows DNS VM | `10.30.1.5`、既定 `Standard_D2s_v5`、既定フォワーダー `168.63.129.16` |
| 同上 | L1 Hyper-V ホスト | `10.30.1.4`、既定 `Standard_D8s_v5`、Standard セキュリティ |
| L1 内部 | L2 Windows Server | 公式 ISO の WIM から Gen2 親・差分 VHDX、2 vCPU・4 GB、無人 specialize / OOBE |
| L2 のネットワーク | Internal vSwitch と WinNAT | IP `192.168.100.10/24`、GW `192.168.100.1`、DNS `10.30.1.5` |

3台の Azure VM には、それぞれ専用の Standard 静的 PIP と NIC NSG を関連付けます。RDP は Bastion subnet から許可し、それ以外からの RDP と Internet からの着信を遮断します。構築中の外向き通信には各 VM の PIP を使用します。

DNS ロールの導入前は、onpre の2台の NIC に Azure DNS を指定して、VM Agent と GitHub 取得の経路を確保します。DNS VM の構成成功後に、NIC とゲストの DNS を `10.30.1.5` へそろえます。

L2 はワークグループの Windows Server として作成し、Azure / Azure Local IMDS の TCP 80 を遮断します。L1 の IMDS と Azure VM Agent は維持してください。ISO の展開方法は[ISO 自動構築ガイド](iso-build.md)を参照します。

L2 の `C:\Handson` には `Install-ArcAgent.ps1`、`Connect-ArcServer.ps1`、`Write-HandsonEvent.ps1` を PowerShell Direct で配置し、ハッシュを照合します。

②では LAW、DCE、AMPLS、PE、Private DNS、DCR、Azure VM の AMA を受講者が設定します。③では Arc PLS、Arc 用 PE / DNS、7条件付きフォワーダー、Explicit Proxy と許可ルール、Arc 登録、L2 の AMA を設定してください。

## 5. 自動確認と Restricted への切替

ゲストの終了コード、コミット SHA、Run ID、必要ファイルと役割別の実状態がそろったことを確認し、最後に3台の `LabInternetOutbound` を Allow から Deny に切り替えます。

| 確認対象 | 完了条件 |
|---|---|
| 同じソース | 3台の ZIP ハッシュ・コミットと今回の Run ID が一致 |
| DNS VM | DNS ロール、既定転送先、実際の DNS 応答を確認 |
| L1 / L2 | Hyper-V、再起動後の復帰、L2 起動・IP / DNS・IMDS 遮断・ライセンス状態・本編用ファイルを確認 |
| workload VM | 必要ファイル、DNS、RDP サービスを確認 |
| 制限後 | 3台と L2 の新規公開接続が失敗し、DNS と RDP サービスを維持 |

DNS、PE subnet の TCP 443、AzFW Private IP の TCP 3128、必要な Azure プラットフォーム通信は明示的に許可します。Arc が Proxy を指定したときに VM の NSG が見る宛先は `10.20.0.4:3128` です。Entra ID 等への公開接続は AzFW が別に行い、③の Firewall Policy で許可します。

NSG はステートフルなので、制限の確認には新しい接続を使用します。③で Proxy を構成した後に、必要な公開通信が Proxy 経由で成功することを確認してください。

## 6. 完了結果と Bastion での確認

すべての段階が成功した場合に、CLI に完了、RG、コミット SHA、Bastion 名、Restricted の結果を表示します。実行状態は Git 対象外の `.local\runs\<Run ID>\state.json` に保存します。

1. Portal で対象 RG と各 VM の Private IP を確認します。
2. 各 VM の「接続 → Bastion」から `labadmin` と入力したパスワードで接続してください。
3. workload、DNS、L1 の3台でホスト名と構成を確認します。
4. L1 の Hyper-V Manager / VMConnect で L2 を開き、Administrator の入力したパスワードで接続します。
5. 3台の NIC NSG が Restricted であることと、②③で使用するファイルの配置を確認してください。

通常の VM 操作はブラウザーの Bastion 接続で行えます。補修時にファイル転送が必要な場合は、Bastion のネイティブ RDP 接続を使用します。

## 7. 失敗時と後片付け

失敗時は段階を表示して停止し、完了とは表示しません。`.local` の安全な実行状態と、対象 VM の Managed Run Command を照合してください。構築失敗時にはリソースと Build の公開送信許可が残る場合があります。NSG 切替の途中で失敗した場合は3台それぞれの実際の規則を確認します。

既存リソースを含む RG への再実行は停止します。復旧または別の専用 RG での構築は、対象と影響を確認して承認を取得してください。自動削除による復旧は行いません。

②③の Agent 配布が制限で失敗する場合は、必要な配布先と経路を特定して変更を承認してください。収集の合否は Restricted の状態で新規ログを使って判定します。

終了時は、VM 内の必要ファイルを回収し、Bastion、Firewall、Resolver、5個の PIP、3個の NIC NSG、VM、親・差分ディスク、Managed Run Command の残存を確認して、承認後に[後片付け](cleanup.md)を実施してください。

参考：[Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)、[Bastion と VNet Peering](https://learn.microsoft.com/azure/bastion/vnet-peering)、[PowerShell Direct](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct)。
