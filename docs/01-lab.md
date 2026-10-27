# ① 任意：検証用ラボの構築

[トップ](../README.md) | [前提条件](./prerequisites.md) | [② Azure VM](./02-azure.md) | [③ オンプレミス Windows](./03-onpremises.md)

講師・検証者が、本番に近いネットワークと既存 Windows サーバーを再現するための任意章です。お客様の既存環境を使用する場合は、この章を省略して②③へ進みます。ここで作る onpre VNet は、Azure 上でオンプレミスを模擬するものです。

**実行すると費用が発生します。** Azure Firewall Standard、Azure Bastion Standard、DNS Private Resolver、それぞれの Public IP、3 台の Azure VM、ディスクなどは、作成時から課金対象です。VM の割り当て解除後も Bastion、Firewall、Resolver、Public IP、ディスク等の課金は続くため、終了時には対象を確認して削除してください。リージョン別の提供状況、見積額、利用可能クォータ、割り当て可能容量を実行前に確認してください。

## 1. 構成と準備

| ネットワーク | サブネット・機器 | 設定 |
|---|---|---|
| spoke1 `10.10.0.0/16` | snet-workload `10.10.1.0/24` | Windows Server 2022 workload VM `10.10.1.4`、VNet DNS `10.20.2.4` |
| hub `10.20.0.0/16` | AzureFirewallSubnet `10.20.0.0/26` | Azure Firewall Standard、専用 Standard Public IP、空の Firewall Policy |
| 同上 | snet-pe `10.20.1.0/24` | ②③の Private Endpoint 用に空で確保 |
| 同上 | snet-resolver-inbound `10.20.2.0/28` | DNS Private Resolver、静的 inbound IP `10.20.2.4` |
| 同上 | AzureBastionSubnet `10.20.3.0/26` | Azure Bastion Standard（2インスタンス）、専用 Standard Public IP、ネイティブクライアント接続を有効化 |
| onpre `10.30.0.0/16` | snet-onpre `10.30.1.0/24` | Windows DNS VM `10.30.1.5`、L1 Hyper-V ホスト `10.30.1.4`、VNet DNS `10.30.1.5` |
| L1 内部 | Internal vSwitch、WinNAT `192.168.100.0/24` | L1 内部 NIC `192.168.100.1`、L2 Windows Server `192.168.100.10/24`、GW `.1`、DNS `10.30.1.5` |

spoke1↔hub、onpre↔hub に双方向 peering を作り、VNet access を有効にします。各 VNet は hub の DNS、Private Endpoint、Proxy に接続します。VM の管理には hub の Bastion を使用してください。管理端末から Bastion へ HTTPS、Bastion から各 Azure VM の Private IP へ RDP で接続します。Firewall と Bastion はそれぞれ専用の Public IP を使用し、各 VM は Private IP で管理します。

各章で作成・設定する範囲は次のとおりです。

| 章 | 作成・設定するもの |
|---|---|
| ① 環境準備 | 3 VNet、peering、Azure Firewall と空の Firewall Policy、Bastion Standard、Resolver Inbound endpoint、VM、Windows DNS、Nested Hyper-V |
| ② Azure VM の登録 | LAW、DCE、AMPLS、専用 Private Endpoint、Private DNS zone、DCR、Azure VM の AMA と関連付け |
| ③ オンプレミスの登録 | Arc PLS と専用 Private Endpoint、Arc 用 DNS zone、条件付きフォワーダー、Explicit Proxy（TCP 3128）と許可ルール、Arc 登録、オンプレミス VM の AMA と関連付け |

①で用意したネットワークを使い、②③で受講者が収集・登録に必要な設定を行ってください。

準備するもの：

- 専用の空のリソースグループと、リソース作成権限のあるお客様用アカウント。
- ローカル端末：PowerShell **7**、Azure CLI、Bicep **0.31 以降**。ゲスト用スクリプトは Windows PowerShell **5.1** で実行します。`infra/lab/guest/*.ps1` の本文は、Windows PowerShell 5.1 で読み込める ASCII です。
- **Bastion を使用する管理端末と権限**。管理端末から Azure Portal と Bastion への HTTPS / TCP 443 を許可します。対象 VM、NIC、Bastion、対象 VNet の Reader 権限と、Windows のローカル管理者資格情報を用意してください。ファイル転送には Windows 管理端末の Azure CLI **2.62.0 以降**とネイティブ RDP クライアントを使用します。L2 の操作は、Bastion で L1 に接続して行います。
- L1 の既定 SKU `Standard_D8s_v5` について、対象リージョンでの nested virtualization 対応、Gen2 対応、クォータ、容量を構築前に確認します。SKU を変更する場合も同様です。`securityType: Standard` を指定し、Gen2 対応と nested virtualization 対応をそれぞれ確認してください。
- L2 用の適正な Windows Server 利用権と、利用者が合法に準備した **sysprep 済み Gen2 VHDX**。Azure VM Guest Agent を含まないオンプレミス用イメージを用意し、Bastion のネイティブ RDP 接続で L1 に配置してください。

VHDX は起動可能な UEFI/Gen2 用 OS ディスクとし、L2 の OOBE 完了後のローカル管理者資格情報を用意します。generalize 後の初回セットアップを無人化する場合も、正規のメディアと安全なイメージ作成手順を使用し、資格情報はアクセスを制限した保管先で管理してください。対話セットアップの場合は、Bastion の RDP セッション内で L1 の Hyper-V Manager / VMConnect を開き、L2 の OOBE を完了します。

**Bastion で対象 VM に接続できない場合は、ゲスト構成を停止し、権限、peering、RDP の許可を確認してください。** インターネットからの RDP 全許可などは不正アクセスのリスクがあるため、管理接続の代用として設定しないでください。

Bastion の費用をラボの予算に含めてください。OS 更新ファイルや Windows 機能ソースは、Bastion のネイティブ RDP 接続で事前に配置します。Bastion は管理接続用で、VM のインターネット向け Proxy は③で設定します。新規 VNet の default outbound access に頼ると、公開配布先に接続できず構成が中断する可能性があるため、必要なファイルと配布経路を事前に確認してください。

VM Agent / Run Command の拡張機能ハンドラーの初回配布・更新等には、公開配布先への通信が必要になる場合があります。Run Command を補助経路として利用する場合は、必要な配布先への到達性とスクリプトの実行結果を確認してください。VM の起動状態、プラットフォーム IP `168.63.129.16` への到達性、配布先への接続をそれぞれ確認します。③で有効化する Explicit Proxy は、以降の Arc 公開通信に使用します。

## 2. ローカル確認とデプロイ

リポジトリのルートで PowerShell 7 を起動します。`infra/lab/example.bicepparam` の prefix、location、VM サイズを編集します。prefix は英小文字から始まる英小文字・数字 2～12 文字にしてください。パスワードは後述の Azure CLI の非表示プロンプトで入力します。パラメータファイルへのパスワード追記は Git 経由の漏えいにつながるため、実施しないでください。`using none` は非秘密値だけの独立したパラメータセットを作るために使用し、runner が `main.bicep` と組み合わせます。

```powershell
# PowerShell の構文と Bicep をローカルで検査する。
& .\infra\lab\Test-LabStatic.ps1
```

ローカル検査は PS7 パーサによる構文確認と Bicep コンパイルです。PS5.1 での実行互換性や実環境動作は別途確認します。Bicep CLI が PATH にない場合は明示エラーで終了します。

次に、お客様自身の Azure CLI 対話認証を使用します。Portal でも同じディレクトリとサブスクリプションを選択してください。認証情報は実施者の管理端末で管理します。

```powershell
$tenantId = Read-Host '対象 Tenant ID'
$subscriptionId = Read-Host '対象 Subscription ID'
$resourceGroupName = Read-Host 'ラボ専用の空の Resource Group 名'
az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'ログイン失敗' }

& .\infra\lab\Deploy-Lab.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName
```

runner はテナント、サブスクリプション、有効状態、本人ユーザー認証を照合し、対象 ID の再入力と費用・SKU 等の確認を求めます。全 Azure リソースコマンドに対象サブスクリプションを明示します。対象 RG がなければ作成し、既存の場合は空であることを要求します。同一 RG の作業は担当者を決めて直列に実行してください。同時実行は、確認後に別の作業者が作ったリソースへ干渉するリスクがあるため、実施しないでください。

デプロイの実体は、保存済み runner 内の `az deployment group create --template-file main.bicep --parameters @<秘密なしのJSONファイル> --mode Incremental --output none` です。runner は `.generated` 配下に非秘密のパラメータ JSON を生成します。必須の `@secure()` パラメータ `adminPassword` は Azure CLI の非表示対話プロンプトで入力します。既定ユーザー名は `labadmin` です。パスワードをコマンド引数、環境変数、ファイル、ログに転記すると認証情報が漏れるリスクがあるため、実施しないでください。入力中の端末録画・入力記録と `--debug` は機密値を記録するリスクがあるため、有効にしないでください。この runner は対話実行し、パスワード入力を可能にするため `--no-prompt` は指定しないでください。

完了まで数十分程度を見込みますが、所要時間は環境依存です。失敗時も作成済みリソースは残ります。Portal の RG → デプロイでエラーを確認し、残存リソースと所有者を記録して、復旧手順の承認を取得してください。runner は非空 RG への再実行を停止します。残存リソースの一括削除・再作成はデータや管理設定を失うリスクがあるため、対象と影響の承認を得る前に実施しないでください。

### Bastion から各 Azure VM に接続する

1. Portal の RG → デプロイ → `optional-lab` →「出力」で `bastionName` と `vmNames` を確認します。既定の名前は `arclab-bastion`、`arclab-workload`、`arclab-dns`、`arclab-hyperv` です。
2. Bastion のデプロイが成功し、hub↔spoke1 と hub↔onpre の peering が Connected であることを確認します。
3. 対象 VM の「接続 → Bastion」を開き、hub の Bastion、RDP / TCP 3389、認証方式「VM パスワード」を選びます。`labadmin` とデプロイ時に入力したパスワードで接続してください。
4. workload、DNS、L1 の3台それぞれで Windows のデスクトップを開き、ホスト名と Private IP を確認します。
5. NSG や Windows Firewall を変更する場合は、送信元 `10.20.3.0/26`（AzureBastionSubnet）から対象 VM の TCP 3389 を許可してください。テンプレートの既定構成では VNet 間通信と Windows の RDP 設定を使用します。AzureBastionSubnet に NSG を追加する場合は、[Bastion に必要な NSG 規則](https://learn.microsoft.com/azure/bastion/bastion-nsg)をすべて満たしてください。

### スクリプトと VHDX を転送する

Bastion Standard はネイティブクライアント接続を有効にしてデプロイします。Windows 管理端末で次を実行し、Azure CLI の tenant / subscription がデプロイ先と一致することを確認してください。`bastion` 拡張機能が必要な場合は、組織の手順で追加します。

```powershell
az account show --query '{tenant:tenantId,subscription:id}' --output table
$targetVmId = Read-Host '転送先 VM の完全なリソース ID'
az network bastion rdp `
    --name 'arclab-bastion' `
    --resource-group $resourceGroupName `
    --target-resource-id $targetVmId `
    --subscription $subscriptionId
```

prefix を変更した場合は Bastion 名も置き換えてください。MSTSC の認証画面で対象 VM の資格情報を入力し、接続後に管理端末からファイルをコピーして対象 VM へ貼り付けます。ブラウザー接続は VM 操作用、ネイティブ RDP 接続はファイル転送にも使用します。ネイティブ接続は Windows 管理端末から実行してください。

- DNS VM: `infra\lab\guest` を `C:\LabScripts\guest` に配置。
- L1: 同じスクリプト一式と VHDX を `C:\LabScripts\guest`、`C:\LabMedia` に配置。③で使う `scripts\Install-ArcAgent.ps1`、`scripts\Connect-ArcServer.ps1`、`scripts\Write-HandsonEvent.ps1` は `C:\LabScripts\handson` に配置。
- workload VM: ②の `scripts\Write-HandsonEvent.ps1` を作業フォルダーに配置。

VHDX のサイズに応じた転送時間と空きディスク容量を確保し、転送元・転送先の `Get-FileHash -Algorithm SHA256` の結果を照合してから使用してください。RDP のファイル転送が組織のポリシーで制限されている場合は、許可された配布方法を管理者と決めてください。

L2 は L1 内部の NAT ネットワークにあります。Bastion の接続対象は L1 を選び、そのデスクトップ上の Hyper-V Manager / VMConnect または PowerShell Direct で L2 を操作してください。L2 の管理は、この L1 経由の経路に統一します。

## 3. Windows DNS と Hyper-V ロールの準備

Portal で 3 台の VM の起動と peering を確認し、Bastion で DNS VM と L1 に管理者として接続します。利用者が `infra/lab/guest` のスクリプトを各 VM の `C:\LabScripts\guest` に配置し、以下を **それぞれの VM 上の管理者 Windows PowerShell 5.1** で実行します。

```powershell
# DNS VM (10.30.1.5) 上
& C:\LabScripts\guest\Initialize-WindowsDns.ps1
```

```powershell
# L1 Hyper-V ホスト (10.30.1.4) 上
& C:\LabScripts\guest\Install-HyperV.ps1
```

**Run Command は任意の補助経路です。** 前述の VM Agent / ハンドラー配布等の通信要件と到達性を確認済みの場合だけ、ローカル端末の PowerShell 7 から保存済み runner で同じスクリプトを呼び出せます。prefix を変更した場合は同じ値を指定します。ゲスト構成の基本手順は Bastion で接続して実行してください。追加の接続経路が必要な場合は、変更するリソース、費用、通信への影響を提示して承認を取得します。

```powershell
& .\infra\lab\Invoke-LabGuest.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -Prefix arclab -Action InitializeDns

& .\infra\lab\Invoke-LabGuest.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -Prefix arclab -Action InstallHyperV
```

それぞれ VM 名を再入力して操作を承認します。Run Command の応答と、ゲストスクリプトの標準出力・標準エラー・終了状態を確認して成否を判定してください。

DNS スクリプトは検証用 DNS VM `10.30.1.5` 上に DNS ロールを導入し、既定 forwarder を Azure の `168.63.129.16` に設定します。DNS 自体の標準ロール規則に加え、模擬 onpre 範囲から TCP/UDP 53 を許可します。異なる既存 forwarder や同名の異なる規則があれば停止するため、既存値を確認してください。**このスクリプトを実際のオンプレミス DNS で実行すると、既定転送先の変更により業務の名前解決が停止するリスクがあるため、実行しないでください。** 本番 DNS は既定 forwarder を維持し、③の条件付きフォワーダー追加を実施します。

Hyper-V 導入後に再起動が必要と表示されたら、ローカル端末の PowerShell 7 で次を実行します。この `RestartHyperV` は Azure の VM 再起動 API を使用します。ホスト上の対話セッションは切断されます。Portal で再起動完了を確認し、Bastion で再接続して、L1 上の `C:\LabScripts\guest\Install-HyperV.ps1` を再実行します。

```powershell
& .\infra\lab\Invoke-LabGuest.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -Prefix arclab -Action RestartHyperV
```

次の7条件付き forwarder は、③で Windows DNS Manager から転送先 `10.20.2.4` として手動設定します。Private DNS zone と VNet link も②③で作成します。

```text
his.arc.azure.com
guestconfiguration.azure.com
monitor.azure.com
oms.opinsights.azure.com
ods.opinsights.azure.com
agentsvc.azure-automation.net
blob.core.windows.net
```

## 4. L2 Windows Server の自動構成

Bastion のネイティブ RDP 接続で L1 `10.30.1.4` に接続し、`infra/lab/guest` のスクリプト一式と自分で用意した VHDX を配置します。ここでは例として `C:\LabScripts\guest` と `C:\LabMedia\WindowsServer2022-Generalized.vhdx` を使用します。配置と転送は利用者が行います。

L1 上の **管理者 Windows PowerShell 5.1** で実行します。

```powershell
& C:\LabScripts\guest\New-NestedLab.ps1 `
    -SourceVhdx C:\LabMedia\WindowsServer2022-Generalized.vhdx
```

スクリプトは Internal vSwitch、WinNAT、4 GB / 2 vCPU の Gen2 L2 VM を作成し、元 VHDX のコピーを OS ディスクとして起動します。既存 VM の世代・接続先・ディスク、vSwitch の種類、IP、NAT 名・範囲が異なる場合や、別の WinNAT がある場合は停止します。競合した設定と所有者を確認し、利用する環境を担当者と決めてください。

**L2 内のローカル管理者資格情報**を `Get-Credential` に入力します。L1 側は管理者権限で実行し、認証には L2 の有効なローカル管理者アカウントを指定してください。資格情報はプロンプトで入力します。PowerShell Direct には VM が Running で、ゲスト OS と必要な統合サービスが起動し、OOBE が完了していることが必要です。初回起動直後は準備完了まで待ちます。PowerShell Direct が使えない場合はスクリプトがエラーを返すため、L2 の初回セットアップと起動を完了し、同じコマンドを再実行してください。既存の適合する VM は再利用します。L2 内の構成結果まで確認してから完了と判定してください。

PowerShell Direct 経由で L2 の BIOS GUID を照合してから、次を実施します。

- L2 のみ、Azure IMDS `169.254.169.254` と Local IMDS `169.254.169.253` への **送信 TCP 80** を Windows Firewall で遮断。
- `192.168.100.10/24`、GW `192.168.100.1`、DNS `10.30.1.5` を設定。異なる既存静的 IP や既定経路がある場合はエラーを返すため、競合した設定を確認。
- DNS 名前解決を確認し、実効ファイアウォール規則と両 IMDS 宛て TCP 接続失敗を確認。

Arc 登録と IMDS 遮断の対象は L2 のみです。L1 や Azure workload VM の IMDS を遮断すると Azure の ID 取得等に影響するリスクがあるため、これらの VM に L2 用の設定を適用しないでください。スクリプトでは TCP 接続失敗に加え、ActiveStore の遮断規則と全プロファイルの有効状態も確認します。

### ③で使うスクリプトを L2 に配置する

L2 の OOBE と自動構成が完了したら、L1 の管理者 Windows PowerShell で PowerShell Direct セッションを開きます。Hyper-V Manager に表示される L2 の VM 名と、L2 内のローカル管理者資格情報を入力してください。

```powershell
$nestedVmName = Read-Host 'Hyper-V 上の L2 VM 名'
$session = New-PSSession -VMName $nestedVmName -Credential (Get-Credential)
try {
    Invoke-Command -Session $session -ScriptBlock {
        New-Item -ItemType Directory -Path 'C:\Handson' -Force | Out-Null
    }
    Copy-Item -Path 'C:\LabScripts\handson\*.ps1' -Destination 'C:\Handson' -ToSession $session
} finally {
    Remove-PSSession -Session $session
}
```

L1 の VMConnect で L2 のデスクトップを開き、`C:\Handson` の3スクリプトを確認してください。③の Arc 導入・登録・イベント生成は、この L2 内の管理者 Windows PowerShell から実行します。

## 5. 完了確認と②③への引き継ぎ

| 合格条件 | 確認方法 |
|---|---|
| 3 VNet と 4 本の peering が存在し接続済み | Portal → 各 VNet → アドレス空間 / ピアリング |
| hub の Bastion Standard から3台の Azure VM を操作できる | 各 VM → 接続 → Bastion。workload、DNS、L1 のホスト名と Private IP を確認 |
| ネイティブ RDP で必要ファイルを L1 へ配置できる | MSTSC 接続と転送後のファイルハッシュを照合 |
| L1 経由で L2 のコンソールを操作できる | L1 の Hyper-V Manager / VMConnect と PowerShell Direct |
| Resolver inbound が `10.20.2.4`、spoke DNS が同 IP | Portal → DNS Private Resolver と spoke1 の DNS サーバー |
| Firewall Standard と Policy を②③で使用できる | Portal → Firewall / Firewall Policy。Explicit Proxy と許可ルールは③で設定 |
| PE 用サブネットに②③で使う空き IP を確保できている | Portal → RG リソース一覧 / hub のサブネット |
| DNS VM で DNS が動作し、既定転送先が `168.63.129.16` | DNS スクリプト出力と DNS Manager。7 条件付き forwarder は③で設定 |
| L1 Hyper-V ロールと VMMS が動作 | 再起動後の Install-HyperV 出力、Hyper-V Manager |
| L2 の IP / GW / DNS が指定値で、通常の DNS 解決に成功 | New-NestedLab 内のゲスト出力 |
| L2 から両 IMDS の TCP 80 に接続できず遮断規則が有効 | Test-NestedImds の 2 件の PASS。L1 への規則追加がないことも確認 |

Portal → RG → デプロイ → `optional-lab` → 出力の `firewallPrivateIp` を③で proxy 設定のために使用します。workload VM を②の Azure 既存 VM、L2 を③のオンプレミス Windows として引き継ぎます。ログ収集、プライベート名前解決、Arc 接続の最終合格判定は②③で行います。

終了後は残存する Bastion、Firewall、Resolver、それぞれの Public IP、VM、ディスク等を棚卸しし、対象と影響について承認を得てから[後片付け](cleanup.md)を実施してください。

参考：[Bicep パラメータファイル](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files)、[Azure 上の nested virtualization](https://learn.microsoft.com/azure/virtual-machines/windows/nested-virtualization)、[PowerShell Direct](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct)、[Bastion と VNet Peering](https://learn.microsoft.com/azure/bastion/vnet-peering)、[ネイティブクライアント](https://learn.microsoft.com/azure/bastion/native-client)、[ファイル転送](https://learn.microsoft.com/azure/bastion/vm-upload-download-native)。
