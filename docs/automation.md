# ① 一括デプロイの実行設計

[①の手順](01-lab.md) / [構成と通信](architecture.md)

## 実行場所と入力

管理端末の PowerShell 7 から `infra\lab\Deploy-Lab.ps1` を実行します。Azure CLI、GitHub CLI、Bicep を事前に用意し、対象の Azure サブスクリプションと Private GitHub リポジトリを利用できるアカウントを使用してください。

対話入力は対象サブスクリプション、ラボ専用 RG、名前の接頭辞、Azure VM の管理者情報、L2 の Administrator パスワードを中心に行います。IP、VM の役割別サフィックス、リージョン、VM サイズには既定値を使用します。作成先、取得コミット、課金対象と最終的な送信制限を表示し、承認後に構築を開始します。

L2 は既定の Microsoft 公式 Windows Server 2022 x64 英語評価版 ISO を使用します。ISO の URL、ハッシュ、利用条件の確認を対話項目には含めません。配布元はコード内の公式 HTTPS URL に限定し、リダイレクト先も検査します。取得後の SHA-256 はキャッシュ照合とファイル識別に使い、公開元の既知ハッシュとの照合とは区別します。Windows の評価条件に従って使用してください。

## 自動実行する順序

1. GitHub の ref を完全なコミット SHA に解決し、同じコミットの ZIP を管理端末に取得します。展開したコミット内の Bicep とゲストスクリプトを使用します。
2. 3 VNet、Firewall、Bastion、Resolver、3台の VM と各 PIP・NIC NSG をデプロイします。構築中の外向き通信を許可します。
3. Managed Run Command の実行経路を確認した後、各 VM に ZIP の短期取得 URL を渡して取得・展開します。各 VM の ZIP ハッシュとコミットを照合します。
4. DNS VM の DNS ロールを構成します。DNS 構成前の onpre VM は Azure DNS で起動し、DNS の準備完了後に onpre の NIC とゲストの DNS を `10.30.1.5` にそろえます。
5. L1 に Hyper-V を導入し、必要な再起動と VM Agent の復帰を待ちます。
6. L1 が公式 ISO から L2 を作成し、応答ファイルで初回セットアップを実施します。PowerShell Direct で IP、DNS、IMDS 遮断、ライセンス状態と本編用ファイルの配置を確認します。
7. 3台のコミット、必要ファイルと役割別の実状態を検証します。すべて成功した場合に NIC NSG を Restricted に切り替え、新規公開接続の失敗と DNS の維持を確認します。
8. CLI に対象 RG、各 VM、コミット、完了結果と Bastion での確認先を表示します。

Azure API の要求成功、Run Command の ProvisioningState、ゲストスクリプトの成否は別に確認します。Managed Run Command は instanceView の実行状態、終了コード、ゲストが返した今回の Run ID・コミット・役割・確認結果を照合して判定します。

## 資格情報と取得ファイル

Private GitHub の長期トークンは管理端末の GitHub CLI 認証から使用します。各 VM にはコミット固定 ZIP の短期取得 URL を Managed Run Command の保護パラメーターで渡します。URL を発行してから直ちに使用し、GitHub トークン自体を各 VM に保存する方式は採用しません。

Azure の管理者パスワードは secure パラメーターとして ARM の要求本文へ渡し、CLI 引数や生成パラメーターファイルへ保存しません。L2 パスワードと短期取得 URL は Run Command の保護パラメーターを使用します。Windows の Run Command ハンドラー内部では保護パラメーターが引数として展開されるため、VM 管理者と Azure の実行権限も適切に制限してください。

初回セットアップ用の応答ファイルは L2 用ディスクで一時的に扱います。成功後に既知の配置先を除去し、削除済みブロックが残り得る VHDX も機密性のあるファイルとして保護します。コンソールと実行状態にはパスワード、トークン、短期 URL、応答 XML を出力しません。

## 失敗時と再実行

失敗した段階、対象 VM、確認済みの結果と残存状態を表示し、完了とは表示しません。構築に失敗した段階では、後続の Restricted 切替を実施しません。制限切替の途中で失敗した場合は、3台それぞれの NSG の状態を照合してください。

自動削除・既存リソースの上書き・未確認の状態を使った継続は行いません。再実行時は保存した今回の状態と Azure・ゲストの実状態を確認して、復旧または別の専用 RG での構築を承認してください。構築失敗時もリソースの課金と、Build 状態の外向き通信が残ることを確認します。

## 根拠

- [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)
- [Run Command の REST API](https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/create-or-update?view=rest-compute-2024-07-01)
- [GitHub の ZIP アーカイブ API](https://docs.github.com/rest/repos/contents#download-a-repository-archive-zip)
- [Windows Server 2022 評価版](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022)
