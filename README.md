# SAP Commerce Lab

AWS Solutions Architect Professionalレベルの設計判断を、実際に動くECサイトとAWS環境で学ぶプロジェクトです。

Phase 1では「動くが高可用ではない」基準構成を観察し、AWSリソースをCleanupしました。現在のBranchではPhase 3として、固定2 TaskとECS Service Auto Scalingを同じ負荷Profileで比較する構成を実装しています。

## 現在の状態

| 項目 | 状態 |
|---|---|
| ECアプリ | ローカル実装済み |
| APIテスト | 合格 |
| Dockerイメージ | `phase1-v4`をECRへPush・実行し、Cleanup済み |
| PostgreSQL統合テスト | 合格 |
| Terraform | `fmt`・`validate`合格 |
| Account Guard | 正しいSSO Accountで成功、異なるAccount IDを拒否 |
| AWS実環境検証 | VPC、ALB、ECS、RDS、CloudWatch、Flow Logsを確認済み |
| Task停止実験 | ECS Serviceの自己回復と注文Dataの残存を確認済み |
| AWS Cleanup | 52リソース削除、主要な残存課金リソース0件を確認済み |
| Phase 3 Local実装 | Health Check分離、Auto Scaling、CloudWatch Dashboard、k6を検証済み |
| Phase 3 AWS Deploy | 未実施 |

## 機能

- 商品一覧・商品詳細
- ブラウザ内カートへの追加・削除
- サーバー側の商品価格を使った模擬注文
- 注文履歴
- PostgreSQLへの永続化
- ALB/ECS用livenessとRDS依存readinessの分離
- CloudWatch Logs向けJSON構造化ログ

実決済、個人情報、認証は扱いません。

## ローカル実行

前提：Node.js 24、Docker Desktop

```powershell
npm.cmd install
npm.cmd test
docker compose up --build
```

ブラウザで `http://localhost:3000` を開きます。

停止してローカルDBも削除する場合：

```powershell
docker compose down --volumes
```

## AWS構成

Phase 1を基準に、Phase 3ではECS Task数と観測機能を変更します。

- 東京リージョン、2 AZ
- Public Subnet × 2：ALB、NAT Gateway
- Private App Subnet × 2：ECS Fargate（Minimum 2、Maximum 6）
- Isolated DB Subnet × 2：RDS PostgreSQL（Single-AZ）
- ECR、CloudWatch Logs、VPC Flow Logs、Secrets Manager
- RDS接続はTLS必須。AWS公式RDS CA bundleでサーバー証明書を検証
- Security Group参照により `Internet → ALB → ECS → RDS` だけを許可
- `ALBRequestCountPerTarget`によるTarget Trackingを固定Capacity測定後に有効化
- ALB、ECS、RDSを同じ時間軸で見るCloudWatch Dashboard

## デプロイの大きな流れ

AWSリソースを変更するコマンドは、対象Account、Region、planを確認し、ユーザーから明示的な承認を得た場合だけ実行します。

1. AWSアカウントと東京リージョンを確認
2. `environment = phase3`、`deploy_service = false` で基盤をplan/apply
3. コンテナイメージをECRへpush
4. `deploy_service = true`、`enable_autoscaling = false`で固定2 Taskをdeploy
5. 固定Capacityのk6結果とCloudWatch Metricを保存
6. `enable_autoscaling = true`をplan/applyし、同じk6 Profileで比較
7. Scale-out、Scale-in、Response、Error、RDS負荷を観察
8. `terraform plan -destroy`を確認して削除
9. 残存課金リソースを確認

## 検証コマンド

まとめて実行する場合：

```powershell
.\scripts\validate.ps1
```

個別に実行する場合：

```powershell
npm.cmd test
npm.cmd run build
npm.cmd run lint
docker build --pull -t sap-commerce-lab:phase3-local .

cd infra
terraform fmt -recursive -check
terraform init -backend=false
terraform validate
```

`terraform plan`はAWS認証情報と実アカウントへの読み取りアクセスが必要です。`sap-lab` SSOプロファイルを明示し、Providerの`allowed_account_ids`で意図しないAccountを拒否します。

## 制御された負荷試験

実行対象は、自分たちが作成したPhase 3の東京ALBだけです。Scriptは最大30 RPS、100 VU、15分、ECS最大6 Taskに制限しています。

```powershell
.\scripts\run-load-test.ps1 `
  -BaseUrl (terraform -chdir=infra output -raw application_url) `
  -ConfirmOwnedEnvironment
```

`load-tests/results`へk6 Summaryと実行条件を保存します。結果FileはGit対象外です。負荷実行前にCloudWatch Dashboard、ECS Scaling Activity、停止条件を開いてください。

## 学習資料

教科書、手順書、学習記録、トラブル記録の正本はObsidian Vaultの次のFolderです。

```text
study/aws/AWS-SAP-ECサイト実践
```

RepositoryにはApplication、Terraform、検証Scriptなど、実行可能な成果物を置きます。Phaseごとの差分はGit履歴で保持します。

## 重要な制約

- Phase 3もHTTPのみです。非機密の学習データ以外を入力しません。
- ECSは最低2 Taskですが、RDS Single-AZ、NAT Gateway 1台のため、システム全体の高可用構成ではありません。
- Request Count Target 300は本番Capacityから導いた値ではなく、Scalingを観察するLab初期値です。
- RDS管理ユーザーをアプリが利用する簡略化が残っています。
- Terraform stateはローカル管理です。チーム利用や本番運用を想定していません。
- `terraform apply`、`terraform destroy`、AWS CLIによる変更は、ユーザーから明示的な承認を得た場合だけ実行します。
