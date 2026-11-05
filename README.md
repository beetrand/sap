# AWS SAP Architecture Labs

実際に動くWebシステムを作り、AWSリソース、ログ、メトリクス、DB、障害時の挙動を観察しながら設計判断を学ぶリポジトリです。

## Lab構成

```text
sap/
├─ AGENTS.md             共通の学習・運用ルール
├─ commerce-lab/         ECS / ALB / RDSを使った従来のECサイト
└─ ticketing-lab/        Lambda / API Gateway / Auroraを使う座席予約サイト
```

### [Commerce Lab](./commerce-lab/README.md)

Phase 1からPhase 3で利用したECサイトです。ECS Fargate、ALB、RDS PostgreSQL、Auto Scaling、k6負荷試験を扱います。AWSリソースは削除済みです。

### [Ticketing Lab](./ticketing-lab/README.md)

現在取り組んでいる指定席予約サイトです。Aurora Serverless v2、RDS Data API、Lambda、API Gateway、CloudFrontを基準構成とし、同時予約、冪等性、Outbox、非同期処理へ発展させます。現在はローカル実装済み、AWS未デプロイです。

## 共通ルール

- AWSの変更操作は対象Account、Region、planを確認してから行う。
- `terraform apply`、`terraform destroy`は明示的な承認なしに実行しない。
- 学習ノートの正本はObsidianの`study/aws/AWS-SAP-ECサイト実践`とする。
- 各Labの実行・検証方法は、それぞれのREADMEを参照する。
