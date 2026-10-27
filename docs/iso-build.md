# ISO から Nested Hyper-V L2 を作成する

## 対象と実装状況

Windows Server 2022 L1（10.30.1.4、OS build 20348）上で、Windows Server 2022 x64 Standard / Datacenter **Desktop Experience** の L2 を作る。評価版を使用できる。Windows Server 2025、Server Core、ARM64、ESD、Azure Marketplace イメージは対象外。

この方式では利用者による事前 VHDX 作成と手動 OOBE は不要。既存の `New-NestedLab.ps1 -SourceVhdx` によるコピー方式も残してある。このガイドの新方式はそのスクリプトを呼ばず、ネットワーク初期化と既存のゲスト設定・IMDS 検証を共有する。

**実装ファイルを作成した段階であり、実 ISO/WIM の適用、VM 起動、認証、ダウンロード、activation は未検証。** オフラインテストも実行担当者による実行が必要。

MSLab の親ディスク・差分ディスク・応答ファイルの考え方を参考に、Windows 標準機能で独自実装している。MSLab 全体、DC、ドメイン参加、Arc、AMA は導入しない。外部スクリプトをダウンロードして実行しない。Windows 媒体や他ライセンスのバイナリをリポジトリに同梱しない。

## 前提条件と範囲

- 実行場所は L1 の管理者 Windows PowerShell **5.1**。PowerShell 7 では実行しない。
- L1 の Hyper-V ロール、Hyper-V PowerShell モジュール、稼働中の `vmms`、Storage / NetTCPIP / NetNat / Dism モジュール、標準の DISM と BCDBoot が必要。Hyper-V 有効化と再起動は別途実施する。
- L1/媒体とも Windows Server 2022。ホスト DISM より新しい OS を適用する構成は扱わない。サポート対象のホストを更新してから開始する。
- ローカル NTFS、十分な容量（ISO、展開後 OS、動的親ディスク、子ディスク増分、作業領域分）を確保する。親の仮想容量は既定 60 GiB。UNC、ReFS、リパースポイント配下は使用しない。
- `C:\NestedIsoCache` と `C:\NestedIsoGuests` は専用の新規ディレクトリとする。既存の無関係なディレクトリの ACL は変更しない。スクリプト専用 marker のあるディレクトリだけを再利用する。キャッシュとゲストのツリーは重ねない。
- 構成①のインターネット許可期間に行う。L1 から Microsoft 公式 HTTPS 配布先へ接続でき、L2 は既存構成の NAT・NSG 経由でインターネット接続できる必要がある。PIP/NSG、Azure 認証、L1 OS ディスク、Azure VM agent、L1 IMDS はこのスクリプトで変更しない。
- VM 名は Windows コンピューター名にもなる。英数字とハイフンで最大 15 文字、数字のみや末尾ハイフンは不可。

## ISO URL と公開 SHA256 の準備

1. [Microsoft Evaluation Center: Windows Server 2022](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022) で利用条件、登録要否、評価版の条件を確認する。応答ファイルで EULA 画面を非表示にするため、実行前の確認を省略しない。
2. 公式手続きで得た **ISO 本体の直接 HTTPS URL** を確認する。Evaluation Center の HTML ページや `aka.ms` をそのまま入力しない。固定の可変 URL を無検証で使用しない。
3. **同じ媒体について Microsoft が公開した SHA256 値と、その掲載ページの HTTPS URL** を確保する。ダウンロード済みファイルから自分で計算した値だけでは真正性の根拠にならない。公式 SHA256 の掲載元が見つからない場合、このガイドの条件では停止する。スクリプトは掲載元 URL の形式を確認・記録するが、ページを解析してハッシュの真正性を自動証明しない。媒体との対応は利用者が確認する。
4. `-DownloadUri`、64 桁の `-Sha256`、掲載元の `-HashSourceUri` を渡す。掲載元は HTTPS の `microsoft.com` またはそのサブドメインに限定し、query/fragment/ユーザー情報は受け付けない。パスワード、秘密、認証ヘッダー、独自の認証情報を URL に含めない。

配布先の許可ホストは次の **完全一致のみ**。初期 URL、各リダイレクト先、実際の応答 URL をすべて HTTPS/443 で検証する。最大 5 リダイレクト。HTTP、ユーザー情報、フラグメント、未知ホストは拒否し、既定資格情報は送信しない。

- `download.microsoft.com`
- `software-download.microsoft.com`
- `software-static.download.prss.microsoft.com`

公式でもリスト外のホストへの転送は停止する。無条件の許可拡大はしない。必要なら利用者が公式サイトで別途取得し、ローカル ISO と公式 SHA256 を使う。Evaluation Center から現在の URL や SHA256 を無人取得できることは保証しない。この実装は **利用者入力が前提** で、媒体 URL や公開 SHA256 を捏造・固定していない。

ダウンロードは L1 のみで行う。転送失敗は `.partial` を残して停止する。ハッシュ不一致は `HashMismatch` として使用を拒否する。部分ファイルが残った状態で上書き再開しない。既存 ISO も毎回 SHA256 を確認する。

## 実行

作業フォルダーを `infra\lab\guest` にし、管理者 Windows PowerShell 5.1 で実行する。URL や SHA256 の例には実媒体値を埋め込んでいない。

```powershell
# Read-Host prevents accidentally treating example placeholders as real media.
$isoUri = [uri](Read-Host 'Official direct ISO HTTPS URL')
$sha256 = Read-Host 'Microsoft published SHA256 (64 hexadecimal digits)'
$hashSource = [uri](Read-Host 'Microsoft HTTPS page publishing that SHA256')
$imageName = Read-Host 'Exact WS2022 Desktop Experience image name'
.\New-NestedLabFromIso.ps1 -DownloadUri $isoUri -Sha256 $sha256 `
    -HashSourceUri $hashSource -AcceptedMediaTerms -ImageName $imageName
```

ローカル ISO の場合：

```powershell
$sha256 = Read-Host 'Microsoft published SHA256'
$hashSource = [uri](Read-Host 'Microsoft HTTPS page publishing that SHA256')
$imageName = Read-Host 'Exact WS2022 Desktop Experience image name'
.\New-NestedLabFromIso.ps1 -IsoPath 'C:\Media\WindowsServer2022.iso' `
    -Sha256 $sha256 -HashSourceUri $hashSource -AcceptedMediaTerms `
    -ImageName $imageName -VmName 'ArcOnpremL2' `
    -TimeZone 'Tokyo Standard Time' -ReadinessTimeoutSeconds 1800
```

`Get-Credential` のユーザー名は **厳密に `Administrator`**。`.\Administrator`、ドメイン修飾、別名管理者は受け付けない。新規 L2 の組み込み Administrator に設定するパスワードを画面の資格情報ダイアログで入力する。パスワードは OS の複雑性要件を満たすこと。コマンド引数、パラメーターファイル、ログ、Git、親 VHDX に書かない。PowerShell transcript やデバッグで応答 XML を出力しない。

引数 `-IsoUri` は `-DownloadUri`、`-ExpectedSha256` は `-Sha256` の別名として使用できる。ローカル ISO とダウンロード URL は別の parameter set であり、同時指定しない。既定パスワードはない。

### ImageName の確認

index は媒体ごとに異なるので固定しない。ISO を検証した後、スクリプトは `Get-WindowsImage` の各 index の詳細メタデータを取得し、Version build 20348、EditionId Standard/Datacenter（Eval 含む）、InstallationType `Server`（Desktop Experience）、x64 で絞り込む。候補が 1 つでない場合は停止し、正確な `-ImageName` が必要。明示名があっても OS 条件は緩和しない。

利用者が image 名を調べる場合は、SHA256 確認済み ISO を手動でマウントし、読み取り専用で次を実行する。`X:` はその ISO のドライブ文字に置き換える。完了後は自身でマウント解除する。スクリプトは既存マウントを引き継がない。

```powershell
Get-WindowsImage -ImagePath 'X:\sources\install.wim' |
    ForEach-Object {
        Get-WindowsImage -ImagePath 'X:\sources\install.wim' -Index $_.ImageIndex
    } | Format-Table ImageIndex, ImageName, Version, EditionId, InstallationType, Architecture
```

### 作成内容

1. 公式ハッシュ確認済み ISO を専用マウント。新規 dynamic VHDX のみをマウントし、その `Get-Disk` のディスク番号だけを使用する。
2. GPT、EFI 260 MiB/FAT32、MSR 16 MiB、残り Windows/NTFS を作成。DISM `/Apply-Image /CheckIntegrity`、適用 OS の BCDBoot `/s ... /f UEFI` で Gen2 起動ディスクにする。既存の物理ディスクや他のマウントは初期化しない。
3. 親をマウント解除し、読み取り専用属性を付け、ISO SHA256・image index/name/version/edition/type・親の SHA256 に結び付く JSON manifest を保存する。親は一度も起動せず、応答ファイルや資格情報を入れない。Ready の親だけをハッシュ再確認して再利用する。
4. VM ごとの差分 VHDX を作成し、**子の** `Windows\Panther\unattend.xml` に specialize/OOBE の ComputerName、TimeZone、AdministratorPassword を注入する。XML API で特殊文字をエスケープする。平文パスワードを一時保存しており、Base64 を暗号化とは扱わない。AutoLogon は設定しない。
5. Internal vSwitch `OptionalLab-Internal`、WinNAT `192.168.100.0/24`、L1 側 `192.168.100.1/24` を既存スクリプトと共有。競合 NAT、スイッチ種別、IP は勝手に置換・削除しない。
6. Gen2、2 vCPU、固定 4 GiB、Secure Boot MicrosoftWindows の VM を作成し、起動する。
7. PowerShell Direct が使えるまで既定 30 分（60～7200 秒で指定可）待機する。認証情報を毎回明示し、ネットワーク WinRM にはフォールバックしない。ドキュメントにある英語の特定 boot/service transport エラーだけを再試行し、認証失敗・未知エラー・他言語の識別不能エラーは即停止する。待機は個別試行を含む期限で管理する。認証エラーは OOBE 未完了が原因でも無条件に待機し続けない。
8. BIOS GUID と L1 IP 不在で L2 を確認後、下記の既知の応答ファイルパスだけを削除・不在確認する。
9. 既存 `Set-NestedGuest.ps1` と `Test-NestedImds.ps1` を PowerShell Direct で実行。L2 は `192.168.100.10/24`、GW `.1`、DNS `10.30.1.5`。L2 のみで `169.254.169.254` / `.253` TCP/80 を遮断し、有効な firewall rule、接続失敗、Microsoft 公開名の DNS 解決を検証する。
10. L2 の SoftwareLicensingProduct を読み、LicenseStatus と GracePeriodRemaining（分）を表示する。自動 activation、更新適用は行わない。未認証なら警告する。成功しても `InternetDenyReady=false` とする。

## 秘密の残存、失敗、再実行

専用 L1 ディレクトリには継承を無効にした ACL を設定し、SYSTEM と組み込み Administrators に限定する。Hyper-V は実行に必要な VM 固有のアクセス権を子ディスク等へ追加する場合がある。L1 管理者やストレージ管理者に対する暗号化保護にはならない。親と子を共有フォルダーや Git に置かない。

成功時に L2 内で削除する確定パス：

- `%SystemRoot%\Panther\unattend.xml`（注入元・標準キャッシュ）
- `%SystemRoot%\Panther\Unattend\unattend.xml`
- `%SystemRoot%\System32\Sysprep\unattend.xml`

これ以外のファイルを探索して一括削除しない。Windows Setup が追加ファイルを残す可能性は実機で確認する。**ファイル削除は安全な消去ではない。** VHDX の未使用領域、チェックポイント、バックアップには平文が残り得るため、成功後も子を機密扱いにする。manifest の `SecretMayRemain=true` は成功時も維持する。運用へ持ち込むなら初期パスワード変更、バックアップ・残存データ保護を別途実施する。

途中失敗・中断の場合：

- VM、差分ディスク、部分 ISO、manifest、作成済みネットワークを自動削除しない。
- 子ディレクトリの `deployment.json` が `Preparing` / `Booting` / `Configuring` のまま、または `Failed` の場合は未完了。応答ファイルが残っている前提でアクセスを制限する。子のパスを警告するが秘密値は表示しない。
- 通常の失敗では `FailureStage` / `FailureKind` に段階と安全な分類を記録し、例外にも表示する。`HashMismatch`、image 選択必須、認証・アクセス拒否、readiness timeout を区別する。元の例外本文や応答 XML を無条件にログへ出さない。子を作る前の親作成失敗では、親 manifest と表示された段階を確認する。
- 親 manifest が `Building` / `Failed`、破損、ハッシュ不一致なら再利用しない。子の有無・既存 VM の競合も上書きしない。成功済みでも同名 VM を再展開しない。
- 自分が開始した ISO / VHD マウントは `finally` で解除を試みる。プロセス強制終了・ホスト障害は finally を保証できないので、実行者が対象パスとマウント状態を確認する。解除失敗は成功扱いにしない。
- 応答ファイルの内容を画面に出して診断しない。VMConnect で OOBE・ブート状態を調べ、失敗カテゴリと状態ファイルを確認する。ローカライズされた transport エラーは再試行されないことがある。
- 調査・削除の承認後に、保護された子の残存応答ファイルを処理するか、機密ストレージの方針に従い VM/子を廃棄する。再実行のために manifest の Status を手編集して成功にしない。安全な別 VM 名/新規ディレクトリで開始するか、承認済みの後片付けを完了する。

### 差分ディスクと削除順

子は親の絶対パスと不変な内容に依存する。親を移動、編集、差し替え、再作成、起動しない。ACL/読み取り専用属性だけで管理者による変更を完全に防げるわけではない。親を別媒体に更新する場合は別 cache key/新規子を使用する。

削除は本スクリプトの機能ではない。対象と影響の個別承認を得た後に、VM 停止 → VM 登録/チェックポイント/子差分ディスク → 当該親を使う全子の不存在確認 → 親 VHDX/manifest → 不要な ISO/専用ディレクトリの順で扱う。共用 NAT/vSwitch は他の利用者・VM がいないことを確認するまで残す。親だけを先に削除しない。

## ①インターネット拒否へ進む前のチェックリスト

- [ ] L2 が OOBE なしで起動し、PowerShell Direct 認証できる。ComputerName/TimeZone が正しい。
- [ ] manifest は `Configured`、`AnswerFilesRemoved=true`。既知の応答ファイルが不在。子は依然機密扱い。
- [ ] DNS `10.30.1.5` の名前解決、L2 固定 IP/GW、IMDS 両アドレスの有効な TCP/80 block と接続失敗を確認。
- [ ] L1 の IMDS、OS disk、Azure VM agent に変更がない。
- [ ] 評価版は **180 日**、失効防止のため **最初の 10 日以内にインターネットで activation** する条件を公式サイトで確認。LicenseStatus=1、残存期間と必要なインターネット接続を利用者が確認。スクリプトは状態参照のみで activation や猶予延長・ライセンス回避はしない。
- [ ] 必要な Windows Update と再起動をインターネット許可中に別途完了。自動更新・自動 activation を完了したと誤認しない。
- [ ] このスクリプトが行わない Arc/AMA の導入・登録・接続検証は、全体ガイドと承認済み手順で実施。
- [ ] 未完了の activation/更新/機密残存対策を記録し、完了を確認してから①の deny 切り替え判断を行う。

## オフラインテストと実機の合格条件

親セッション/実行担当者が次を Windows PowerShell 5.1 で実施する。Pester の追加は不要。テストは合成データのみで XML escaping、URI allowlist と redirect 拒否、hash mismatch、image metadata 選択、認証エラーの非再試行、全 guest PS1 の ASCII/構文を確認する。媒体取得、VM、ネットワーク、ファイル書き込みは行わない。

```powershell
powershell.exe -NoProfile -File .\infra\lab\guest\Test-NestedIsoHelpers.ps1
```

実機検証は別途承認を得て、公式媒体の詳細メタデータを確認し、次を検証する。

1. WS2022 の親作成・GPT/EFI/MSR/NTFS・DISM・BCDBoot・Secure Boot が成功。親に応答ファイルがない。
2. `Ready` 親の再利用時に同一ハッシュを確認し、既存子や VM、途中 manifest には停止する。
3. 特殊文字入りのパスワードが OOBE と PowerShell Direct で使える。正しい GUID の L2 のみ設定する。
4. 起動待ち、transport 一時エラー、認証誤り、タイムアウト、途中停止、マウント解除失敗が成功に見えない。30 分上限と中断時の残存状態を確認。
5. ACL と Hyper-V の VM アクセス、既知のキャッシュ応答ファイル、Setup のその他残存、機密値が親/manifest/コンソールにないことを確認。
6. HTTP/未知ホストへの redirect と不正 SHA256 を、実媒体を配布しない隔離テストで拒否できることを確認。
7. 既存 SourceVhdx 経路も、共通化したネットワーク初期化で退行しない。

## 参考

- [PowerShell Direct の要件とエラー](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/powershell-direct)
- [DISM の対応プラットフォーム](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-supported-platforms)
- [BCDBoot](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di)
- [MSLab: Scripts/2_CreateParentDisks.ps1](https://github.com/microsoft/MSLab/blob/master/Scripts/2_CreateParentDisks.ps1)
- [MSLab: Scripts/3_Deploy.ps1（CreateUnattendFileNoDjoin）](https://github.com/microsoft/MSLab/blob/master/Scripts/3_Deploy.ps1)
- [MSLab: Tools/Convert-WindowsImage.ps1](https://github.com/microsoft/MSLab/blob/master/Tools/Convert-WindowsImage.ps1)
