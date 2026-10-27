# Azure Monitor Private Link と Azure Arc Private Link ハンズオン

既存の Azure Windows VM とオンプレミスの Windows Server から、Private Link 経由で同じ Log Analytics Workspace にログを収集します。Azure Portal を中心に操作し、Windows 内の設定と Portal だけでは設定できない項目に PowerShell / Azure CLI を使用します。

本編は②と③です。お客様が既存環境を使用する場合、①のネットワークや VM のデプロイは不要です。

## 資料を取得する

Private リポジトリを使用する場合、閲覧権限のある GitHub アカウントで取得してください。Git を使わない場合は「Code → Download ZIP」で取得して展開できます。管理端末の PowerShell では次を使用します。

```powershell
git clone https://github.com/uedait/ampls-arcpls-handson.git
Set-Location .\ampls-arcpls-handson
```

以降の管理端末用コマンドは、このフォルダーを基準とします。Windows サーバー内の操作は各章で実行場所を分けて示します。

## 進め方

| 章 | 内容 | 対象 |
|---|---|---|
| [事前確認](docs/prerequisites.md) | 権限、入力値、費用、既存 DNS / AMPLS への影響と変更承認 | 全員 |
| [構成と通信](docs/architecture.md) | 直接接続と Proxy の使い分け、必要な変更 | 全員 |
| [① 任意の検証環境準備](docs/01-lab.md) | 3 VNet、AzFW、Resolver、VM、Nested Hyper-V の構築 | 講師・検証者 |
| [② Azure VM の登録](docs/02-azure.md) | LAW、DCE、AMPLS、PE、Private DNS、DCR、AMA | 既存 Azure 環境の担当者 |
| [③ オンプレミスの登録](docs/03-onpremises.md) | Arc PLS、条件付きフォワーダー、Proxy、Arc、AMA | オンプレミスと Azure の担当者 |
| [結果の確認](docs/validation.md) | ログ、接続先、否定試験、結果記録 | 全員 |
| [障害調査](docs/troubleshooting.md) | DNS、Agent、Proxy、ログ到着の切り分け | 必要な場合 |
| [後片付け・切り戻し](docs/cleanup.md) | 今回の変更だけを戻す手順 | 全員 |

![サンプル全体構成](docs/images/01-architecture.png)

[DNS・Agent 設定と確認項目](docs/images/02-network-details.png)も参照してください。図の編集用正本は [Excalidraw](docs/images/01-architecture.excalidraw) です。[全体構成の SVG](docs/images/01-architecture.svg) と[詳細の Excalidraw](docs/images/02-network-details.excalidraw)・[SVG](docs/images/02-network-details.svg)も用意しています。

## このハンズオンで確かめること

1. Azure VM の AMA が AMPLS の Private Endpoint に直接接続し、Windows イベントを収集すること。
2. オンプレミスの Windows DNS が、指定した7ドメインを Azure DNS Private Resolver に転送すること。
3. Arc の管理通信が Arc PLS の専用 Private Endpoint に直接接続すること。
4. Arc の Entra ID・ARM 等への必要な公開通信が、Agent 固有の設定で AzFW Explicit Proxy を使用すること。
5. オンプレミスの AMA が Proxy を使用せず、AMPLS に直接接続すること。

## 始める前に

- 実施者は、既存ネットワーク全体の変更許可とは別に、検証対象 VM、DNS、Firewall の変更許可を取得してください。まず業務負荷のない対象で実施します。
- 既存 AMPLS、Private DNS zone、条件付きフォワーダーがある場合は、その設定を確認してから進めます。同じ DNS 解決範囲に AMPLS を追加すると、既存の監視に影響することがあります。
- 本編では Azure リソースの作成・変更と課金が発生します。予算、通貨、有効期限、削除担当を決めてください。価格の見積もりや本番環境の変更承認をこの資料で代替しません。
- 初回導入ファイルの取得、稼働中の Agent 通信、更新時の通信を別々に確認します。Agent の Proxy 設定だけで、すべてのソフトウェアのダウンロードが可能になるわけではありません。

## 動作確認の状態

この資料は作成時点で**Azure 実環境での通し実行が未実施**です。ローカルでは PowerShell 7 の構文と合成 CLI 試験、Windows PowerShell 5.1 用8スクリプトの構文・文字コード、Bicep と例示パラメーターのコンパイル、相対リンク・JSON・図の表示を確認しています。

①のデプロイ、Nested ゲストの起動、②③の Portal 操作、閉域通信、Proxy、更新の成否は、実施環境で記録してください。画面名は Portal の言語や更新によって変わる場合があります。Portal の実画面キャプチャも未採取です。構成図はサンプルであり、実機での成功証跡ではありません。

本編の根拠は各章の Microsoft Learn へのリンクです。ローカル確認には PowerShell 7 から次を使用します。Azure に接続しません。

```powershell
.\scripts\Test-Handson.ps1
```

任意ラボの Bicep コンパイル等は `.\infra\lab\Test-LabStatic.ps1` で確認します。ローカルに Azure CLI と Bicep が必要です。`Test-Handson.ps1` の合成 CLI 試験は Windows 向けです。ほかの OS で静的確認だけを行う場合は `-SkipMockTests` を指定し、合成試験は未実施として扱います。

`.env`、認証用証明書、秘密鍵、パスワード、認証キャッシュ、実際の環境値、採取ログはリポジトリに保存しません。作業記録はアクセスを制限した保管先を使用し、ローカルで保存する場合は Git 対象外の `.local` 配下に置きます。
