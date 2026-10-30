# ① 一括デプロイの実行設計

[①の手順](01-lab.md) / [構成と通信](architecture.md)

## 実行場所と入力

管理端末の PowerShell 7 から `infra\lab\Deploy-Lab.ps1` を実行します。Azure CLI、GitHub CLI、Bicep を事前に用意し、対象の Azure サブスクリプションと Private GitHub リポジトリを利用できるアカウントを使用してください。

対話入力は対象サブスクリプション、ラボ専用 RG、名前の接頭辞、Azure VM の管理者情報、L2 の Administrator パスワードを中心に行います。IP、VM の役割別サフィックス、リージョン、VM サイズには既定値を使用します。作成先、取得コミット、課金対象と最終的な送信制限を表示し、承認後に構築を開始します。

L2 は既定の Microsoft 公式 Windows Server 2022 x64 英語評価版 ISO を使用します。ISO の URL、ハッシュ、利用条件の確認を対話項目には含めません。配布元はコード内の公式 HTTPS URL に限定し、リダイレクト先も検査します。取得後の SHA-256 はキャッシュ照合とファイル識別に使い、公開元の既知ハッシュとの照合とは区別します。Windows の評価条件に従って使用してください。

## Azure の認証と接続先

利用者の対話ログインと、事前に証明書で認証したサービスプリンシパルを使用できます。サービスプリンシパルを使用する場合は `-TenantId`、`-SubscriptionId`、`-ClientId` を明示し、専用の認証キャッシュを `AZURE_CONFIG_DIR` に設定してから実行します。必要な作成・変更権限はサービスプリンシパルに付与してください。

証明書でのログインと接続先の事前確認は、実施環境の認証手順で行います。本リポジトリのスクリプトは証明書や `.env` を読みません。`az account show` だけでは証明書認証とクライアントシークレット認証を区別できないため、証明書を使用したことは事前の認証手順で確認します。

`-ClientId` を指定した実行では、Azure CLI のテナント、サブスクリプション、クライアント ID、認証種別 `servicePrincipal`、有効状態 `Enabled` を照合します。認証キャッシュの絶対パスを実行開始時に保持し、後続の Azure 操作前にも現在の環境変数と接続情報を再照合します。不一致、未認証、キャッシュ未指定の場合は停止します。再ログイン、既定キャッシュへの切り替え、サブスクリプションの選択変更は行いません。

同じ照合をリソース操作、Managed Run Command、VM 再起動、NIC の変更、最終的な NSG の切り替えに適用します。単独のゲスト操作と NSG 切り替えにもクライアント ID を指定できます。取得したコミットの NSG スクリプトがクライアント ID の引き渡しに対応していない場合は、リソース作成前に停止します。

`-ClientId` を省略した場合は既存の利用者ログインを使用します。未認証なら対話ログインを案内し、対象サブスクリプションを選択します。サービスプリンシパルのログインを利用者ログインとして扱うことはありません。Azure の認証と GitHub の認証は別に行い、GitHub トークンを Azure の認証に使用しません。

## 自動実行する順序

VM の配置先に可用性ゾーンは指定しません。VM サイズの利用制限は種類を区別し、ゾーン限定の制限だけであれば構築を続行します。リージョン全体の制限や種類を判別できない制限が含まれる場合は停止します。Gen2 の対応も確認します。この事前確認は、デプロイ時に必要な容量を確保できることを保証しません。

VM の `securityType` は `Standard` を明示し、Microsoft.Compute の VM API `2025-11-01` を使用します。サブスクリプション全体の機能登録を自動的に変更することはありません。

Azure VM の IMDS 通信はプラットフォームの既定動作を維持し、NSG に `AzurePlatformIMDS` タグの規則を追加しません。L2 からの IMDS 接続だけを L2 内の Windows Firewall で遮断します。

内部スイッチを作成した後は、その仮想 NIC の出現を最大30秒待ちます。IPv4 がまだ設定されていない状態は正常な初期状態として扱い、`192.168.100.1/24` を構成します。既存の異なる IP や NAT を削除・上書きすることはありません。NIC の照会自体が失敗した場合も、未設定として扱わず停止します。

L2 の BIOS GUID は、Hyper-V の VM ID に対応する `Msvm_VirtualSystemSettingData` の現在の設定から取得します。対象が1件で、BIOS GUID が有効かつ空でないことを要求します。スナップショットや別 VM の設定、VM ID 自体を BIOS GUID の代わりに使用することはありません。

1. GitHub の ref を完全なコミット SHA に解決し、同じコミットの ZIP を管理端末に取得します。展開したコミット内の Bicep とゲストスクリプトを使用します。
2. 3 VNet、Firewall、Bastion、Resolver、3台の VM と各 PIP・NIC NSG をデプロイします。構築中の外向き通信を許可します。
3. Managed Run Command の実行経路を確認した後、各 VM に ZIP の短期取得 URL を渡して取得・展開します。各 VM の ZIP ハッシュとコミットを照合します。
4. DNS VM の DNS ロールを構成します。DNS 構成前の onpre VM は Azure DNS で起動し、DNS の準備完了後に onpre の NIC とゲストの DNS を `10.30.1.5` にそろえます。
5. L1 に Hyper-V を導入し、必要な再起動と VM Agent の復帰を待ちます。
6. L1 が公式 ISO から L2 を作成し、応答ファイルで初回セットアップを実施します。PowerShell Direct で IP、DNS、IMDS 遮断、ライセンス状態と本編用ファイルの配置を確認します。
7. 3台のコミット、必要ファイルと役割別の実状態を検証します。すべて成功した場合に NIC NSG を Restricted に切り替え、新規公開接続の失敗と DNS の維持を確認します。
8. CLI に対象 RG、各 VM、コミット、完了結果と Bastion での確認先を表示します。

Azure API の要求成功、Run Command の ProvisioningState、ゲストスクリプトの成否は別に確認します。Managed Run Command は instanceView の実行状態、終了コード、ゲストが返した今回の Run ID・コミット・役割・確認結果を照合して判定します。

管理端末のソース取得処理は、コミット SHA、ZIP の SHA-256、展開先を含む単一のハッシュテーブルを返します。ダウンロードの内部処理の戻り値は出力に含めません。

親ディスクのビルダーは、完成した VHDX のパスを文字列1件だけ返します。通常処理と例外発生時の後始末のどちらでも、マウント解除の完了用オブジェクトは出力しません。マウント解除の失敗はエラーとして伝えます。

## 資格情報と取得ファイル

Private GitHub の長期トークンは管理端末の GitHub CLI 認証から使用します。各 VM にはコミット固定 ZIP の短期取得 URL を Managed Run Command の保護パラメーターで渡します。URL を発行してから直ちに使用し、GitHub トークン自体を各 VM に保存する方式は採用しません。

Azure の管理者パスワードは secure パラメーターとして ARM の要求本文へ渡し、CLI 引数や生成パラメーターファイルへ保存しません。L2 パスワードと短期取得 URL は Run Command の保護パラメーターを使用します。Windows の Run Command ハンドラー内部では保護パラメーターが引数として展開されるため、VM 管理者と Azure の実行権限も適切に制限してください。

初回セットアップ用の応答ファイルは L2 用ディスクで一時的に扱います。成功後に既知の配置先を除去し、削除済みブロックが残り得る VHDX も機密性のあるファイルとして保護します。コンソールと実行状態にはパスワード、トークン、短期 URL、応答 XML を出力しません。

## 失敗時と再実行

失敗した段階、対象 VM、確認済みの結果と残存状態を表示し、完了とは表示しません。構築に失敗した段階では、後続の Restricted 切替を実施しません。制限切替の途中で失敗した場合は、3台それぞれの NSG の状態を照合してください。

自動削除・既存リソースの上書き・未確認の状態を使った継続は行いません。再実行時は保存した今回の状態と Azure・ゲストの実状態を確認して、復旧または別の専用 RG での構築を承認してください。構築失敗時もリソースの課金と、Build 状態の外向き通信が残ることを確認します。

### 承認した既存リソースを使う復旧

通常の `Deploy-Lab.ps1` は、新規または空の専用 RG だけを使用します。構築途中の失敗を同じ RG で復旧する場合は、既存リソースを再利用する対象と影響について別途承認を得て、保存した復旧用スクリプトから `Invoke-LabAutomation` の `Recovery` 引数へ次の情報を渡します。

- `PreviousRunDirectory`: 元の `state.json` と `approval.json` がある実行ディレクトリの絶対パス。
- `ApprovedResourceIds`: 再利用を承認した既存リソースの完全な ID の配列。
- `ResumeFrom`: `DeployResources`、`InitializeDns`、`BuildNested`、`CompleteNested`、`VerifyBuild` のいずれか。省略した場合は `DeployResources`。

元の実行は指定した `ResumeFrom` で `Failed` になっている必要があります。元の実行記録と承認記録の Run ID、コミット、対象 RG、テナント、サブスクリプション、接頭辞、リージョン、取得元を照合します。新しい実行 ID を使い、元の実行記録と保存済み資格情報を上書きしません。復旧用スクリプトは、同じ Windows ユーザーと端末で元の資格情報を復号して同じ値を使用します。復号や再保存の照合に失敗した場合は変更前に停止し、別の資格情報へ自動的に切り替えません。

指定した ID はすべて対象 RG 配下であることを要求します。実際のリソース ID 一覧が承認した一覧と完全に一致する場合だけ、指定した段階から復旧処理を開始します。追加、欠落、重複、別 RG の ID、元の失敗記録との不一致があれば変更前に停止します。既存リソースのある RG に対し、`Recovery` を指定せずに構築を続けることはありません。

復旧前に親デプロイの終了を確認します。`DeployResources` の復旧では、同じ構成を Incremental モードで再デプロイしてからゲスト構成へ進みます。

`InitializeDns` の復旧では、元の対象が DNS VM で、記録された最後の Run Command が元の Run ID の DNS 構成処理であることも要求します。承認した ID 一覧には3台すべての VM を含めます。VM とネットワークのデプロイを省略し、承認された修正コミットのソースを3台へ再配置してから、DNS、Hyper-V、L2、送信制限と各確認を実行します。既存 VM の再作成や、Defender の設定変更は行いません。

`BuildNested` の復旧では、元の対象が Hyper-V ホストで、最後の Run Command が元の Run ID の L2 構築処理であることを要求します。3台の VM を含む承認済み ID を照合し、修正コミットのソースを3台へ再配置します。VM とネットワークのデプロイ、DNS、Hyper-V の構成は繰り返さず、L2 の構築と、その後の確認・送信制限を実行します。親ディスクの Ready 記録とハッシュが一致する場合は、完成済みキャッシュを再利用します。既存 L2 の VM またはディレクトリがある場合は上書きせず停止します。

DNS 転送先の未設定は、初回構成時には正常な状態として扱います。設定後の確認では、転送先が `168.63.129.16` の1件だけであることを要求します。

`CompleteNested` は、L2 の作成後に PowerShell Direct 接続待ちで停止した場合の完了処理です。元の制御記録は BuildNested / Failed、対象は Hyper-V ホストで、最後の Run Command は元の Run ID の BuildNested または CompleteNested であることを要求します。元の管理コマンドの実行状態が Failed、Canceled、TimedOut のいずれかであることを、ソース再配置やゲスト設定の前に確認します。実行中、保留中、成功、不明の場合は継続せず、元の処理との重複を防ぎます。

ゲストの作成記録は Failed / PowerShellDirectReadiness、または初回設定前の Booting を対象にします。Booting は、応答ファイル削除・認証確認・Internet 遮断準備がすべて未完了で、失敗段階と失敗種別が空の場合に限ります。電源断で失敗を記録できなかった状態も、記録を人為的に Failed へ書き換えず扱います。Configuring や Configured の状態から設定を繰り返す経路には使いません。作成済み L2 の VM ID、BIOS GUID、Generation 2、接続ディスクと親参照、内部スイッチが作成記録と一致する場合だけ設定を続行します。不一致の場合に新規作成へ切り替えることはありません。

この経路では VM、親・子ディスク、応答ファイル、NAT を再作成せず、ディスクをマウント解除しません。元の状態記録を保存し、必要な場合だけ同じ L2 を起動します。接続待ちの経過時間と試行回数は再開時に新しく計測し、過去の診断は保持します。同一コミットのゲスト操作は既存のパッケージロックで排他実行します。接続後の UUID 確認から、既知の応答ファイルの後片付け、ゲスト設定、ハンドオーバー、正規の評価版認証と確認を実行します。

ゲスト側では `New-NestedLabFromIso.ps1 -UseDefaultMedia -ContinueExistingVm` の専用モードを使います。このモードで `UseDefaultMedia` を指定しても、ISO の取得やディスク作成は行いません。`ContinueExistingVm` を指定しない通常の実行は、既存 VM とゲストディレクトリを引き続き拒否します。

PowerShell SDK の停止例外は、エラーストリームに加えて `InvocationStateInfo.Reason.ErrorRecord` も確認します。デモ用環境の初回起動では、起動途中の接続失敗によって構築を止めないよう、接続を確立できるまで期限内で再試行します。

ISO から作成した L2 の初回セッション確立時には `InitialBoot` を指定します。`PSDirectException`、`PSRemotingTransportException`、`PSRemotingDataStructureException` は認証拒否も含めて10秒間隔で再試行します。初回セットアップ中は、同じ資格情報でも起動途中で拒否され、その後受け付けられるためです。英文への一致や内部例外がないことを要求しません。待機期限にはビルダーの `ReadinessTimeoutSeconds` をそのまま使い、既定は30分です。初回専用の短い上限は設けません。各試行と待機の残時間を同じ期限で制限し、接続できなければ期限切れで停止を要求します。SDK の停止処理に時間がかかる場合があるため、プロセスの終了時刻までを保証する期限ではありません。接続成功前にゲスト設定へ進むことはありません。

初回接続失敗からの `CompleteNested` でも、記録と実 VM の識別が一致した後の接続待ちにだけ同じ指定を使います。通常の接続では従来どおり、既知の英語の起動待ち transport エラーだけを全体期限内で再試行します。通常接続の全体の既定上限は30分です。

通常接続の認証・権限拒否は、エラー分類、例外階層の数値コード、明示的な拒否の英文で判定して停止します。初回接続では前述の接続例外を再試行する条件を先に適用します。接続関連以外のプログラム例外は再試行しません。接続成功後の UUID 確認と準備状態の検査、NSG とハンズオンで必要な IMDS 遮断は維持します。追加のゲスト内権限制御は導入しません。

接続待ちの診断は、保護された L2 作成ディレクトリの `direct-readiness.jsonl` に追記します。記録する内容は、再試行・拒否・期限切れ・接続成功の区分、固定した判定理由、試行回数、経過秒数、例外階層の型と数値コード、エラー分類です。資格情報、任意の例外本文、生の ErrorId は記録しません。診断の保存に失敗した場合も処理を停止します。

`VerifyBuild` は、L2 の設定完了後に再確認で停止した場合の検証専用経路です。元の BuildNested / Failed 記録を照合し、ソース再配置後に設定処理を呼ばず、VerifyBuild、Restricted、VerifyRestricted だけを実行します。ゲストの作成記録は Configured で、VM ID、BIOS GUID、ディスクと内部スイッチが一致し、応答ファイル削除・ライセンス確認が済んでいることを要求します。

TCP 遮断試験では、実効規則と未接続の確認を維持します。同期例外と単一の非同期例外のどちらも、SocketException の AccessDenied、ConnectionRefused、TimedOut だけを既知の接続失敗として扱います。DNS の HostNotFound、経路不備、不明な例外、複数の集約例外を遮断成功として扱いません。L2 の確認スクリプトへは、検証済みソースの共通判定をメモリ内で渡し、L2 へ新しいファイルを配置しません。

上記以外の段階からの再開、自動的な対象追加、自動削除はこの復旧経路に含めません。

## 根拠

- [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)
- [Run Command の REST API](https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/create-or-update?view=rest-compute-2024-07-01)
- [GitHub の ZIP アーカイブ API](https://docs.github.com/rest/repos/contents#download-a-repository-archive-zip)
- [Windows Server 2022 評価版](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022)
- [Standard セキュリティを明示する場合の API](https://learn.microsoft.com/azure/virtual-machines/trusted-launch-faq#can-i-disable-trusted-launch-for-a-new-vm-deployment)
- [Hyper-V の VM 設定と BIOS GUID](https://learn.microsoft.com/windows/win32/hyperv_v2/msvm-virtualsystemsettingdata)
