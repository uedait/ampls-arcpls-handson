# ISO から Nested Hyper-V L2 を作成する

## 対象と実装状況

Windows Server 2022 L1（10.30.1.4、OS build 20348）上で、Windows Server 2022 x64 Standard / Datacenter **Desktop Experience** の L2 を作る。評価版を使用できる。Windows Server 2025、Server Core、ARM64、ESD、Azure Marketplace イメージは対象外。

この方式では利用者による事前 VHDX 作成と手動 OOBE は不要。既存の `New-NestedLab.ps1 -SourceVhdx` によるコピー方式も残してある。このガイドの新方式はそのスクリプトを呼ばず、ネットワーク初期化と既存のゲスト設定・IMDS 検証を共有する。

**コード実装段階。実 ISO の GET、WIM 適用、VM 起動、PowerShell Direct、activation、NSG 制限後の実機検証は未実施。** 合成テストと実環境の合格判定を区別する。

MSLab の親ディスク・差分ディスク・応答ファイルの考え方を参考に、Windows 標準機能で独自実装している。MSLab 全体、DC、ドメイン参加、Arc、AMA は導入しない。実行する構築コードは指定 commit の検証済み ZIP 内のものに限定し、追加の第三者スクリプトを取得・実行しない。Windows 媒体や他ライセンスのバイナリをリポジトリに同梱しない。

## 前提条件と範囲

- 実行場所は L1 の管理者 Windows PowerShell **5.1**。PowerShell 7 では実行しない。
- L1 の Hyper-V ロール、Hyper-V PowerShell モジュール、稼働中の `vmms`、Storage / NetTCPIP / NetNat / Dism モジュール、標準の DISM と BCDBoot が必要。自動経路では `PrepareHyperV` がロールを導入し、必要な再起動はローカル controller が実施する。guest スクリプト自身はホストを再起動しない。
- L1/媒体とも Windows Server 2022。ホスト DISM より新しい OS を適用する構成は扱わない。サポート対象のホストを更新してから開始する。
- ローカル NTFS、十分な容量（ISO、展開後 OS、動的親ディスク、子ディスク増分、作業領域分）を確保する。親の仮想容量は既定 60 GiB。UNC、ReFS、リパースポイント配下は使用しない。
- `C:\NestedIsoCache` と `C:\NestedIsoGuests` は専用の新規ディレクトリとする。既存の無関係なディレクトリの ACL は変更しない。スクリプト専用 marker のあるディレクトリだけを再利用する。キャッシュとゲストのツリーは重ねない。
- 構成①のインターネット許可期間に行う。L1 から Microsoft 公式 HTTPS 配布先へ接続でき、L2 は既存構成の NAT・NSG 経由でインターネット接続できる必要がある。PIP/NSG、Azure 認証、L1 OS ディスク、Azure VM agent、L1 IMDS はこのスクリプトで変更しない。
- VM 名は Windows コンピューター名にもなる。英数字とハイフンで最大 15 文字、数字のみや末尾ハイフンは不可。

## 既定方式：ローカル controller による無人構築

承認済みの構成①では、ローカル `Deploy-Lab` controller から各 VM の Managed Run Command を呼ぶ。ISO の URL、SHA256、利用条件の追加入力は求めない。Bastion は構築完了後の人による最終確認に使用し、構築中の手作業には依存しない。

既定媒体は Windows Server 2022 x64 English Evaluation、Standard Desktop Experience。配布元は次の Microsoft 公式 HTTPS URI に固定する。

```text
https://software-static.download.prss.microsoft.com/sg/download/888969d5-f34g-4e03-ac9d-1f9786c66749/SERVER_EVAL_x64FRE_en-us.iso
```

この URI は親 controller 担当者が HEAD 200、Content-Length **5,044,094,976 bytes** を確認済み。実 GET は未検証。ゲスト実行時も HTTPS/443、Microsoft の完全一致ホスト allowlist、各 redirect と最終応答 URI、Content-Length と保存後の長さを検査する。媒体更新・転送先変更・サイズ変更時は停止する。

**この媒体に対応する Microsoft 公開 SHA256 は確認できていない。取得後の SHA256 はキャッシュ整合性の検査・媒体識別のみに使用し、公式値との照合や独立した真正性証明とは扱わない。** 信頼の根拠は公式 HTTPS 配布元の検証であり、WIM の OS/edition/architecture/language metadata 検査も継続する。`SourceUri` は配布元参照、`HashSourceUri=null`、`HashMeaning=CacheIntegrityOnly`。配布元 URL を「公開ハッシュ掲載元」として記録しない。

既定経路は build 20348、`ServerStandardEval`、x64、`InstallationType=Server`、`en-US` の候補が厳密に 1 つであることを要求する。index は固定しない。ユーザーによる媒体指定を必要とする高度な手動経路は後述する。

### guest bootstrap と状態契約

`infra/lab/guest/Invoke-LabRole.ps1` 自体の内容を controller が inline script として送信する。ZIP 取得に companion の事前配置は不要。Windows PowerShell 5.1 の管理者または SYSTEM で非対話実行する。各 VM に同じ full 40 桁 `CommitSha`、`Repository=uedait/ampls-arcpls-handson`、32 桁 hex またはハイフン付き GUID の `RunId` を渡す。

`ArchiveUri` と `L2Password` は Run Command の **protected parameters** で渡し、標準出力、状態 manifest、transcript に記録しない。ただし Windows の handler はゲスト内でパラメーターを引数として扱うため、protected parameters を「ゲスト内で永続的に非露出」とは表現しない。ゲスト管理者からの完全な秘匿も保証しない。

1. on-premises 側の初期 NIC DNS は `168.63.129.16`。controller が各 VM の handler を prewarm し、その VM 用の短期 `codeload.github.com` URL を直前発行して、直ちに `StageSource` を呼ぶ。workload の resolver は `10.20.2.4` のままとする。3 VM すべての staging 成功を確認してから role 構成を開始する。
2. 全 VM が同一 ZIP の指定 `ArchiveSha256` を照合する。URI/全 redirect/実応答は HTTPS/443、`codeload.github.com` / `api.github.com` / `github.com` 完全一致のみ。長期 GitHub token は VM に送らない。短期 URL の query も秘密情報として扱う。
3. ZipSlip、絶対パス、`..`、Windows パスの別名、大小文字の衝突、file/directory 衝突、symlink/reparse 相当、複数 top folder を拒否する。選択した `infra/lab/guest/*.ps1` と手渡し用 3 スクリプトのみを取り出す。既存の commit ディレクトリは上書きしない。
4. `StageSource` は全 role 共通で ZIP 取得・hash 検証・必要ファイルの実照合のみを行う。`C:\ProgramData\AmplsArcHandson\Source\<CommitSha>` に配置し、commit/ZIP hash/各ファイル SHA256 の `source-package.json` を保存する。download は redirect/応答待機/body read 全体で 600 秒の期限を共有し、無制限 retry はしない。以降の Action は `ArchiveUri` を渡さず owned cache 必須とし、毎回 marker と実ファイル hash を照合する。欠損や不一致時の download fallback・存在だけの成功判定は行わない。
5. `InitializeDns(dns)` が DNS role と forwarder `168.63.129.16` を構成する。DNS service の Running、有効な forwarder、自身 `10.30.1.5` に明示した DNS query の成功を確認した後にのみ、対象 NIC の client DNS を `10.30.1.5` に設定し再検査する。③の 7 conditional forwarders は作らない。完了後 controller が on-premises 2 NIC の DNS 設定を `10.30.1.5` に更新する。失敗や再起動後に DNS/NIC の元値へ戻す暗黙の rollback は行わない。
6. `PrepareHyperV(hyperv)` は対象 NIC の DNS を `10.30.1.5` に設定し、実 query 成功後に Hyper-V を導入する。`RebootRequired=true` の場合は controller が VM を再起動する。DNS role 導入で再起動が必要な場合も `DnsReady=false` と共に返し、controller が再起動後に `InitializeDns` を再実行する。
7. `BuildNested(hyperv)` は protected password を `Administrator` の `PSCredential` に変換し、`New-NestedLabFromIso.ps1 -UseDefaultMedia -Credential ...` を呼ぶ。Credential 指定時はダイアログを出さない。親 VHDX、差分ディスク、unattend、L2、有限の PowerShell Direct 待機、IP/DNS/IMDS 設定を実施する。
8. L2 の `C:\Handson` へ同じ ZIP の `Install-ArcAgent.ps1`、`Connect-ArcServer.ps1`、`Write-HandsonEvent.ps1` を PowerShell Direct でコピーし、各 hash を照合する。Arc の導入や登録自体は行わない。workload 上の event script は上記 verified source package の `scripts` 配下で hash/metadata を確認する。
9. 正規の `slmgr.vbs /ato` を試し、実際の Windows `LicenseStatus=1` を確認する。未認証は明示的失敗であり、Internet 制限には進めない。ライセンス変更・rearm・回避処理はしない。全 Windows Update の自動完了は範囲外で、更新基準は **標準 image** とする。
10. 全 role の `VerifyBuild` が実状態と hash を検査した後にのみ、controller が NIC NSG を Restricted に切り替える。`VerifyRestricted` は各 host と L2 の新規 public TCP/443 接続不可、DNS、RDP service、IMDS、手渡しファイル等を再検査する。NSG の設定自体の検証は controller 担当。③の Firewall Proxy 到達性は要件にしない。Windows platform 通信や private 通信全体を証明したものとは扱わない。

host IP の対応は workload `10.10.1.4`、dns `10.30.1.5`、hyperv `10.30.1.4`。不一致は停止する。L2 は BIOS GUID と L1 IP 不在を確認してから操作する。

成功時の標準出力最終行は `LAB_RESULT:` に compact JSON を連結した 1 行。全 Action 共通で `RunId/Role/Action/CommitSha/Succeeded/FilesReady/RebootRequired` を返す。controller は exit 0 と最終一致行の両方を検査する。

| Action | 実状態に基づく public checks |
|---|---|
| StageSource | 全 role 共通 `SourceVerified=true,FilesReady=true`。role 構成・再起動・DNS 変更は行わない |
| InitializeDns | `DnsReady=true`。再起動待ちは `RebootRequired=true,DnsReady=false,RoleReady=false` |
| PrepareHyperV | `RebootRequired` は boolean。false の場合 `HyperVReady=true` |
| BuildNested | `L2Ready/HandoverReady/ImdsBlocked/Licensed=true` |
| VerifyBuild | 全 role `DnsReady/RdpReady=true`。hyperv は上記 L2 の 4 checks も true |
| VerifyRestricted | 全 role `InternetBlocked/DnsReady/RdpReady=true`。hyperv は `L2InternetBlocked/ImdsBlocked/HandoverReady=true` も必要 |

`RebootRequired=true` はロール導入ステージの成功であり、構築全体の完了を意味しない。失敗時は非ゼロ終了、安全な `LAB_ERROR:Stage=...;Kind=...` のみを返し、成功風 JSON を返さない。実環境の結果を過去の manifest だけで代用しない。ZIP URL 期限切れも明示的失敗とし、controller は `StageSource` の download 段階だけを新 URL で限定 retry できる。`StageSource` 以外に `ArchiveUri` を渡した場合は拒否する。

## 高度な手動方式：ISO URL と公開 SHA256 の準備

1. [Microsoft Evaluation Center: Windows Server 2022](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022) で利用条件、登録要否、評価版の条件を確認する。応答ファイルで EULA 画面を非表示にするため、実行前の確認を省略しない。
2. 公式手続きで得た **ISO 本体の直接 HTTPS URL** を確認する。Evaluation Center の HTML ページや `aka.ms` をそのまま入力しない。固定の可変 URL を無検証で使用しない。
3. この高度な経路では **同じ媒体について Microsoft が公開した SHA256 値と、その掲載ページの HTTPS URL** を確保する。掲載元が見つからない場合、この手動経路では停止する。ダウンロード済みファイルから自分で計算した値を公開値と偽称しない。既定の公式媒体経路は前節の異なる信頼モデルを使用する。手動経路のスクリプトは掲載元 URL の形式を確認・記録するが、ページの内容を解析してハッシュの真正性を自動証明しない。
4. `-DownloadUri`、64 桁の `-Sha256`、掲載元の `-HashSourceUri` を渡す。掲載元は HTTPS の `microsoft.com` またはそのサブドメインに限定し、query/fragment/ユーザー情報は受け付けない。パスワード、秘密、認証ヘッダー、独自の認証情報を URL に含めない。

配布先の許可ホストは次の **完全一致のみ**。初期 URL、各リダイレクト先、実際の応答 URL をすべて HTTPS/443 で検証する。最大 5 リダイレクト。HTTP、ユーザー情報、フラグメント、未知ホストは拒否し、既定資格情報は送信しない。

- `download.microsoft.com`
- `software-download.microsoft.com`
- `software-static.download.prss.microsoft.com`

公式でもリスト外のホストへの転送は停止する。無条件の許可拡大はしない。手動経路では必要に応じて利用者が公式サイトで取得し、ローカル ISO と公式 SHA256 を使用する。Evaluation Center のページから URL や SHA256 を自動抽出する実装ではない。

ダウンロードは L1 のみで行う。転送失敗は `.partial` を残して停止する。ハッシュ不一致は `HashMismatch` として使用を拒否する。部分ファイルが残った状態で上書き再開しない。既存 ISO も毎回 SHA256 を確認する。

## 高度な手動実行

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

`Get-Credential` のユーザー名は **厳密に `Administrator`**。`.\Administrator`、ドメイン修飾、別名管理者は受け付けない。手動経路で `-Credential` を省略した場合だけ入力ダイアログを使用する。指定時は非対話実行できる。パスワードは OS の複雑性要件を満たすこと。平文のコマンド引数、パラメーターファイル、ログ、Git、親 VHDX に書かない。PowerShell transcript やデバッグで応答 XML を出力しない。

引数 `-IsoUri` は `-DownloadUri`、`-ExpectedSha256` は `-Sha256` の別名として使用できる。ローカル ISO とダウンロード URL は別の parameter set であり、同時指定しない。既定パスワードはない。

### ImageName の確認

index は媒体ごとに異なるので固定しない。ISO を検証した後、スクリプトは `Get-WindowsImage` の各 index の詳細メタデータを取得し、Version build 20348、EditionId Standard/Datacenter（Eval 含む）、InstallationType `Server`（Desktop Experience）、x64 で絞り込む。手動経路で候補が 1 つでない場合は正確な `-ImageName` が必要。既定経路はさらに Standard Evaluation/English に限定する。明示名があっても OS 条件は緩和しない。

利用者が image 名を調べる場合は、SHA256 確認済み ISO を手動でマウントし、読み取り専用で次を実行する。`X:` はその ISO のドライブ文字に置き換える。完了後は自身でマウント解除する。スクリプトは既存マウントを引き継がない。

```powershell
Get-WindowsImage -ImagePath 'X:\sources\install.wim' |
    ForEach-Object {
        Get-WindowsImage -ImagePath 'X:\sources\install.wim' -Index $_.ImageIndex
    } | Format-Table ImageIndex, ImageName, Version, EditionId, InstallationType, Architecture
```

### 作成内容

1. 既定方式では公式 HTTPS 配布元・サイズ・computed cache hash を、手動方式では指定 SHA256 を検証した ISO を専用マウント。新規 dynamic VHDX のみをマウントし、その `Get-Disk` のディスク番号だけを使用する。
2. GPT、EFI 260 MiB/FAT32、MSR 16 MiB、残り Windows/NTFS を作成。DISM `/Apply-Image /CheckIntegrity`、適用 OS の BCDBoot `/s ... /f UEFI` で Gen2 起動ディスクにする。既存の物理ディスクや他のマウントは初期化しない。
3. 親をマウント解除し、読み取り専用属性を付け、ISO SHA256・image index/name/version/edition/type・親の SHA256 に結び付く JSON manifest を保存する。親は一度も起動せず、応答ファイルや資格情報を入れない。Ready の親だけをハッシュ再確認して再利用する。
4. VM ごとの差分 VHDX を作成し、**子の** `Windows\Panther\unattend.xml` に specialize/OOBE の ComputerName、TimeZone、AdministratorPassword を注入する。XML API で特殊文字をエスケープする。平文パスワードを一時保存しており、Base64 を暗号化とは扱わない。AutoLogon は設定しない。
5. Internal vSwitch `OptionalLab-Internal`、WinNAT `192.168.100.0/24`、L1 側 `192.168.100.1/24` を既存スクリプトと共有。競合 NAT、スイッチ種別、IP は勝手に置換・削除しない。
6. Gen2、2 vCPU、固定 4 GiB、Secure Boot MicrosoftWindows の VM を作成し、起動する。
7. PowerShell Direct が使えるまで既定 30 分（60～7200 秒で指定可）待機する。認証情報を毎回明示し、ネットワーク WinRM にはフォールバックしない。ドキュメントにある英語の特定 boot/service transport エラーだけを再試行し、認証失敗・未知エラー・他言語の識別不能エラーは即停止する。待機は個別試行を含む期限で管理する。認証エラーは OOBE 未完了が原因でも無条件に待機し続けない。
8. BIOS GUID と L1 IP 不在で L2 を確認後、下記の既知の応答ファイルパスだけを削除・不在確認する。
9. 既存 `Set-NestedGuest.ps1` と `Test-NestedImds.ps1` を PowerShell Direct で実行。L2 は `192.168.100.10/24`、GW `.1`、DNS `10.30.1.5`。L2 のみで `169.254.169.254` / `.253` TCP/80 を遮断し、有効な firewall rule、接続失敗、Microsoft 公開名の DNS 解決を検証する。
10. 手渡し 3 ファイルを配置・hash 確認し、正規の `/ato` を試す。SoftwareLicensingProduct の LicenseStatus=1 が必須。実状態の IP/GW/DNS/IMDS/応答ファイル不在/hash/認証を `Test-LabNestedReadiness.ps1` で再検査した後だけ `InternetDenyReady=true` とする。全 Windows Update 完了とは扱わない。

## 秘密の残存、失敗、再実行

専用 L1 ディレクトリには継承を無効にした ACL を設定し、SYSTEM と組み込み Administrators に限定する。Hyper-V は実行に必要な VM 固有のアクセス権を子ディスク等へ追加する場合がある。L1 管理者やストレージ管理者に対する暗号化保護にはならない。親と子を共有フォルダーや Git に置かない。

成功時に L2 内で削除する確定パス：

- `%SystemRoot%\Panther\unattend.xml`（注入元・標準キャッシュ）
- `%SystemRoot%\Panther\Unattend\unattend.xml`
- `%SystemRoot%\System32\Sysprep\unattend.xml`

これ以外のファイルを探索して一括削除しない。Windows Setup が追加ファイルを残す可能性は実機で確認する。**ファイル削除は安全な消去ではない。** VHDX の未使用領域、チェックポイント、バックアップには平文が残り得るため、成功後も子を機密扱いにする。manifest の `SecretMayRemain=true` は成功時も維持する。運用へ持ち込むなら初期パスワード変更、バックアップ・残存データ保護を別途実施する。

途中失敗・中断の場合：

- VM、差分ディスク、部分 ISO、manifest、作成済みネットワークを自動削除しない。bootstrap ZIP の失敗時に限り、その呼出しが作成した exact file と空の一時ディレクトリだけを後片付けする。source root の再帰削除は行わない。
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
- [ ] 評価版の有効期間と activation 条件を公式サイトで確認。自動 `/ato` 後の実 LicenseStatus=1 を確認済み。猶予延長・ライセンス回避は行わない。継続利用時の期限管理は別途必要。
- [ ] 今回の更新基準は標準 image。全 Windows Update 自動完了を要件・成功判定に含めない。追加の更新が必要な場合は別途計画・承認する。
- [ ] このスクリプトが行わない Arc/AMA の導入・登録・接続検証は、全体ガイドと承認済み手順で実施。
- [ ] 全 VM の実 `VerifyBuild` 成功後にのみ①の deny に切り替え、`VerifyRestricted` も完了する。機密残存と未実施の更新を記録する。

## オフラインテストと実機の合格条件

親セッション/実行担当者が次を Windows PowerShell 5.1 で実施する。Pester の追加は不要。テストは合成データのみで XML escaping、URI allowlist と redirect 拒否、hash mismatch、image metadata 選択、認証エラーの非再試行、ZIP entry/marker/role-action 衝突、安全な compact JSON、全 guest PS1 の ASCII/構文を確認する。媒体取得、VM、ネットワーク、ファイル書き込みは行わない。

```powershell
powershell.exe -NoProfile -File .\infra\lab\guest\Test-NestedIsoHelpers.ps1
powershell.exe -NoProfile -File .\infra\lab\guest\Test-LabRoleHelpers.ps1
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
