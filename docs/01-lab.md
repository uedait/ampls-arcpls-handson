# ① 任意：検証用ラボの構築

[トップ](../README.md) | [前提条件](./prerequisites.md) | [② Azure VM](./02-azure.md) | [③ オンプレミス Windows](./03-onpremises.md)

講師・検証者が、本番に近いネットワークと既存 Windows サーバーを再現するための任意章です。お客様の既存環境を使用する場合は、この章を省略して②③へ進みます。ここで作る onpre VNet は、Azure 上でオンプレミスを模擬するものです。

**実行すると費用が発生します。** Azure Firewall Standard、DNS Private Resolver、Public IP、3 台の Azure VM、ディスクなどは、LAW やログをまだ作っていなくても課金対象です。VM の割り当て解除だけでは Firewall、Resolver、ディスク等の課金は止まりません。リージョン別の提供状況、見積額、利用可能クォータ、割り当て可能容量を実行前に確認してください。本成果物では実環境へのデプロイ、提供状況・費用・クォータ・起動状態の実確認は行っていません。

## 1. 構成と準備

| ネットワーク | サブネット・機器 | 設定 |
|---|---|---|
| spoke1 `10.10.0.0/16` | snet-workload `10.10.1.0/24` | Windows Server 2022 workload VM `10.10.1.4`、VNet DNS `10.20.2.4` |
| hub `10.20.0.0/16` | AzureFirewallSubnet `10.20.0.0/26` | Azure Firewall Standard、専用 Standard Public IP、空の Firewall Policy |
| 同上 | snet-pe `10.20.1.0/24` | ②③の Private Endpoint 用に空で確保 |
| 同上 | snet-resolver-inbound `10.20.2.0/28` | DNS Private Resolver、静的 inbound IP `10.20.2.4` |
| onpre `10.30.0.0/16` | snet-onpre `10.30.1.0/24` | Windows DNS VM `10.30.1.5`、L1 Hyper-V ホスト `10.30.1.4`、VNet DNS `10.30.1.5` |
| L1 内部 | Internal vSwitch、WinNAT `192.168.100.0/24` | L1 内部 NIC `192.168.100.1`、L2 Windows Server `192.168.100.10/24`、GW `.1`、DNS `10.30.1.5` |

spoke1↔hub、onpre↔hub に双方向 peering を作り、VNet access を有効にします。peering は推移的ではなく、spoke1↔onpre の直接接続は作りません。UDR、NAT Gateway、VM Public IP、公開 RDP、Bastion は作りません。Firewall の Public IP を VM の管理接続に使用することもありません。すべての通信を Firewall に強制する構成ではありません。

**①では AMPLS、Arc Private Link Scope、Private Endpoint、Private DNS zone、LAW、AMA、Arc 登録、DCR を作りません。** これらは受講者が②③で作成します。Firewall Policy は作成しますが、**explicit proxy（TCP 3128）も許可ルールも①では設定しません。③で Portal から設定するまで、プロキシは使用できません。**

準備するもの：

- 専用の空のリソースグループと、リソース作成権限のあるお客様用アカウント。
- ローカル端末：PowerShell **7**、Azure CLI、Bicep **0.31 以降**。ゲスト用スクリプトは Windows PowerShell **5.1** で実行します。`infra/lab/guest/*.ps1` の本文はすべて ASCII とし、BOM なしでも Windows PowerShell 5.1 の文字コード解釈に依存しない構成です。
- **既存の承認済みプライベート管理接続**。既存の管理 VNet からの peering、VPN 等により対象 VM のプライベート IP へ到達でき、必要な管理通信が許可されていることを確認します。テンプレートは管理接続を作りません。hub との peering だけで別の管理 VNet まで推移的に接続されるわけではありません。L2 操作には L1 上の管理者対話セッションが必要です。
- L1 の既定 SKU `Standard_D8s_v5` について、対象リージョンでの nested virtualization 対応、Gen2 対応、クォータ、容量を構築前に確認します。SKU を変更する場合も同様です。Trusted Launch ではなく `securityType: Standard` を指定します。SKU 一覧で Gen2 対応が分かっても nested virtualization 対応の証明にはなりません。
- L2 用の適正な Windows Server 利用権と、利用者が合法に準備した **sysprep 済み Gen2 VHDX**。Azure VM の OS ディスクを流用せず、Azure VM Guest Agent の入っていないオンプレミス用イメージを用意します。VHDX は承認済み管理接続で利用者が L1 に配置します。転送は本スクリプトでは自動化しません。ISO/VHDX の外部ダウンロードも行いません。

VHDX は起動可能な UEFI/Gen2 用 OS ディスクとし、L2 の OOBE 完了後のローカル管理者資格情報を用意します。generalize 後の初回セットアップを無人化する場合も、正規のメディアと安全なイメージ作成手順で行い、資格情報をこのリポジトリに保存しないでください。無人セットアップを用意しない場合は、承認済みの GUI 管理接続から Hyper-V Manager / VMConnect を使用して OOBE を完了します。その管理接続を用意できない場合、L2 自動構成は進められません。

**停止条件：この新規ラボ単体には、管理端末から VM への接続経路はありません。既存 peering / VPN 等による承認済み管理接続を準備できない場合は、ゲスト構成へ進まず停止してください。** 管理接続の追加が必要なら、対象と影響を確認して別途承認を得ます。公開 RDP や Run Command による代替成功を前提に進めません。

Bastion が必要なら別途設計・承認し、追加料金を確認します。本テンプレートに暗黙では追加しません。2026 年の新規 VNet では default outbound access による暗黙の外向き通信を保証できません。本章はそれに依存せず、UDR / NAT Gateway / VM Public IP も追加しません。一般インターネットへの直接送信を前提にした OS 更新・機能ソース取得は保証しないため、必要な Windows 機能ソースも事前に準備してください。

VM Agent / Run Command の拡張機能ハンドラーの初回配布・更新等には、公開の配布先への通信が必要になる場合があります。プラットフォーム IP `168.63.129.16` に到達できることや、Portal で VM が起動済みと表示されることだけでは、この通信や Run Command の利用成功は保証されません。これらの公開宛先要求と到達性は**別途確認する前提であり、本成果物では未検証**です。必要な送信経路・許可が確認できた環境でのみ Run Command を補助経路として利用します。①では explicit proxy も未有効のため、これを初回配布の経路として扱いません。

## 2. ローカル確認とデプロイ

リポジトリのルートで PowerShell 7 を起動します。`infra/lab/example.bicepparam` の prefix、location、VM サイズだけを編集します。prefix は英小文字から始まる英小文字・数字 2～12 文字にしてください。パスワードを追記してはいけません。`using none` は秘密なしの独立したパラメータセットを作るために使用し、runner が `main.bicep` と組み合わせます。

```powershell
# ローカルのみ。Azure への認証・デプロイは行わない。
& .\infra\lab\Test-LabStatic.ps1
```

ローカル検査は PS7 パーサによる構文確認と Bicep コンパイルです。PS5.1 での実行互換性や実環境動作は別途確認します。Bicep CLI が PATH にない場合は明示エラーで終了します。

次に、お客様自身の Azure CLI 対話認証を使用します。Portal でも同じディレクトリとサブスクリプションを選択してください。開発者の workspace `.env`、サービスプリンシパル、証明書や認証キャッシュをコピーしません。

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

runner はテナント、サブスクリプション、有効状態、本人ユーザー認証を照合し、対象 ID の再入力と費用・SKU 等の確認を求めます。全 Azure リソースコマンドに対象サブスクリプションを明示します。対象 RG がなければ作成し、既存の場合は空であることを要求します。既存リソースの上書きや自動削除は行いません。複数作業者による同時実行は避けてください。

デプロイの実体は、保存済み runner 内の `az deployment group create --template-file main.bicep --parameters @<秘密なしのJSONファイル> --mode Incremental --output none` です。runner は `.generated` 配下に非秘密のパラメータ JSON を生成します。必須の `@secure()` パラメータ `adminPassword` はパラメータファイルに含めず、Azure CLI の安全な対話プロンプトで入力します。既定ユーザー名は `labadmin` です。runner はパスワードを変数で受け取ったり標準出力・ログへ書き出したりせず、デプロイ応答の標準出力も抑止します。パスワードをコマンド引数や環境変数、ファイル、ログへ渡さないでください。秘密を含むデバッグ記録や端末録画・入力記録を有効にせず、`--debug`、非対話実行、`--no-prompt` は使用しません。

完了まで数十分程度を見込みますが、所要時間は環境依存です。失敗時も作成済みリソースは残ります。まず Portal の RG → デプロイでエラーを確認し、承認なしに削除・再作成しないでください。安全のため runner は非空 RG への再実行を止めます。途中失敗からの復旧では、残存リソースを確認してから別途変更計画を決定します。

## 3. Windows DNS と Hyper-V ロールの準備

Portal で 3 台の VM の起動と peering を確認し、承認済みプライベート管理接続で DNS VM と L1 に管理者として接続します。利用者が `infra/lab/guest` のスクリプトを各 VM の `C:\LabScripts\guest` に配置し、以下を **それぞれの VM 上の管理者 Windows PowerShell 5.1** で実行します。公開 RDP は使用しません。

```powershell
# DNS VM (10.30.1.5) 上
& C:\LabScripts\guest\Initialize-WindowsDns.ps1
```

```powershell
# L1 Hyper-V ホスト (10.30.1.4) 上
& C:\LabScripts\guest\Install-HyperV.ps1
```

**Run Command は任意の補助経路です。** 前述の VM Agent / ハンドラー配布等の通信要件と到達性を確認済みの場合だけ、ローカル端末の PowerShell 7 から保存済み runner で同じスクリプトを呼び出せます。prefix を変更した場合は同じ値を指定します。Run Command が利用できない場合は承認済みプライベート管理接続を使用し、その接続もない場合は停止します。公開通信を通すための隠れた UDR / NAT 追加や、③より前の proxy 有効化は行いません。

```powershell
& .\infra\lab\Invoke-LabGuest.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -Prefix arclab -Action InitializeDns

& .\infra\lab\Invoke-LabGuest.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -Prefix arclab -Action InstallHyperV
```

それぞれ VM 名を再入力して操作を承認します。Run Command の HTTP 成功だけではゲストスクリプト成功と判断できません。返された標準出力・標準エラーと終了状態を確認してください。

DNS スクリプトは `10.30.1.5` 上に DNS ロールを導入し、既定 forwarder を Azure の `168.63.129.16` に設定します。これは模擬環境のための設定です。**実際のオンプレミスでは既存の既定 forwarder を維持し、このスクリプトを実行しません。** 異なる既存 forwarder や同名の異なる規則があれば、勝手に上書きせず停止します。DNS 自体の標準ロール規則に加え、模擬 onpre 範囲から TCP/UDP 53 を許可します。

Hyper-V 導入後に再起動が必要と表示されたら、ローカル端末の PowerShell 7 で次を実行します。この `RestartHyperV` は Azure の VM 再起動 API を使用し、ゲストの Run Command ハンドラーは使用しません。ホスト上の対話セッションは切断されます。Portal で再起動完了を確認し、承認済みプライベート管理接続で再接続して、L1 上の `C:\LabScripts\guest\Install-HyperV.ps1` を再実行します。

```powershell
& .\infra\lab\Invoke-LabGuest.ps1 `
    -TenantId $tenantId -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -Prefix arclab -Action RestartHyperV
```

①では次の **7 条件付き forwarder は作りません**。③で Windows DNS Manager から、それぞれ転送先 `10.20.2.4` として手動設定します。Private DNS zone と VNet link も②③で作成します。

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

承認済み管理経路で L1 `10.30.1.4` に接続し、`infra/lab/guest` のスクリプト一式と自分で用意した VHDX を配置します。ここでは例として `C:\LabScripts\guest` と `C:\LabMedia\WindowsServer2022-Generalized.vhdx` を使用します。配置と転送は利用者が行います。

L1 上の **管理者 Windows PowerShell 5.1** で実行します。

```powershell
& C:\LabScripts\guest\New-NestedLab.ps1 `
    -SourceVhdx C:\LabMedia\WindowsServer2022-Generalized.vhdx
```

スクリプトは Internal vSwitch、WinNAT、4 GB / 2 vCPU の Gen2 L2 VM を作成し、元 VHDX を変更せずコピーして起動します。既存 VM の世代・接続先・ディスク、vSwitch の種類、IP、NAT 名・範囲が異なる場合は停止します。別の WinNAT がある場合も停止し、既存設定の削除や上書きはしません。

**L2 内のローカル管理者資格情報**を `Get-Credential` に入力します。L1 の資格情報とは限りません。L1 側は管理者権限で実行し、L2 側も有効なローカル管理者アカウントを使用します。資格情報はディスクに保存しません。PowerShell Direct には VM が Running で、ゲスト OS と必要な統合サービスが起動し、OOBE が完了していることが必要です。初回起動直後は準備完了まで待ちます。スクリプトは無限に待機せず、PowerShell Direct が使えない場合は明示エラーになります。L2 の初回セットアップと起動を完了し、同じコマンドを再実行してください。既存の適合する VM は再利用し、削除・再作成しません。L2 内を操作できない場合、成功扱いにはしません。

PowerShell Direct 経由で L2 の BIOS GUID を照合してから、次を実施します。

- L2 のみ、Azure IMDS `169.254.169.254` と Local IMDS `169.254.169.253` への **送信 TCP 80** を Windows Firewall で遮断。
- `192.168.100.10/24`、GW `192.168.100.1`、DNS `10.30.1.5` を設定。異なる既存静的 IP や既定経路は削除せずエラー。
- DNS 名前解決を確認し、実効ファイアウォール規則と両 IMDS 宛て TCP 接続失敗を確認。

**L1 の IMDS アクセスは変更しません。Arc 登録対象は L2 のみです。** L1 や Azure workload VM をオンプレミスサーバーとして Arc 登録しないでください。TCP 接続失敗だけでは遮断規則による拒否の証明にならないため、スクリプトでは ActiveStore の規則と全プロファイル有効状態も確認します。

## 5. 完了確認と②③への引き継ぎ

| 合格条件 | 確認方法 |
|---|---|
| 3 VNet と 4 本の peering が存在し接続済み | Portal → 各 VNet → アドレス空間 / ピアリング |
| Resolver inbound が `10.20.2.4`、spoke DNS が同 IP | Portal → DNS Private Resolver と spoke1 の DNS サーバー |
| Firewall Standard と Policy があり、proxy は未設定 | Portal → Firewall / Firewall Policy。TCP 3128 が使えるとは判断しない |
| PE 用サブネットが空で、Private DNS zone 等は未作成 | Portal → RG リソース一覧 / hub のサブネット |
| DNS VM で DNS が動作し、既定転送先が `168.63.129.16` | DNS スクリプト出力と DNS Manager。7 条件付き forwarder はまだ不要 |
| L1 Hyper-V ロールと VMMS が動作 | 再起動後の Install-HyperV 出力、Hyper-V Manager |
| L2 の IP / GW / DNS が指定値で、通常の DNS 解決に成功 | New-NestedLab 内のゲスト出力 |
| L2 から両 IMDS の TCP 80 に接続できず遮断規則が有効 | Test-NestedImds の 2 件の PASS。L1 への規則追加がないことも確認 |

Portal → RG → デプロイ → `optional-lab` → 出力の `firewallPrivateIp` を③で proxy 設定のために使用します。workload VM を②の Azure 既存 VM、L2 を③のオンプレミス Windows として引き継ぎます。ログ収集、プライベート名前解決、Arc 接続の最終合格判定は②③で行います。

終了後は残存する Firewall、Resolver、Public IP、VM、ディスク等を棚卸しし、対象と影響について承認を得てから削除してください。**この章のスクリプトには削除操作や自動クリーンアップはありません。**

参考：[Bicep パラメータファイル](https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files)、[Azure 上の nested virtualization](https://learn.microsoft.com/azure/virtual-machines/windows/nested-virtualization)、[PowerShell Direct](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct)。
