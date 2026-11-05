# RDSがネットワークインターフェースを配置できるDatabase Subnetの集合。
# 2AZを登録することはRDSの要件だが、Phase 3のDB自体はSingle-AZである。
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = [for subnet in aws_subnet.database : subnet.id]

  tags = { Name = local.name }
}

# PostgreSQLのエンジン設定をAWS標準値から変更するためのParameter Group。
resource "aws_db_parameter_group" "main" {
  name   = "${local.name}-postgres17"
  family = "postgres17"

  parameter {
    # アプリからRDSまでのPostgreSQL接続にTLSを強制する。
    name  = "rds.force_ssl"
    value = "1"
    # この設定は再起動時に反映される種類なので、pending-rebootを指定する。
    apply_method = "pending-reboot"
  }

  tags = { Name = "${local.name}-postgres17" }
}

# 注文と商品データを永続化するRDS for PostgreSQL。
resource "aws_db_instance" "main" {
  # コンソール、メトリクス、ログで識別するDBインスタンス名。
  identifier = local.name

  # エンジンの種類とバージョン、計算性能を変数から受け取る。
  engine         = "postgres"
  engine_version = var.database_engine_version
  instance_class = var.database_instance_class

  # 初期DB名と管理ユーザー名。管理パスワードそのものはTerraformへ渡さない。
  db_name  = var.database_name
  username = var.database_username
  # RDSにパスワード生成とSecrets Managerへの保管・ローテーションを任せる。
  manage_master_user_password = true
  port                        = 5432

  # 学習用の最小容量。gp3を使い、保存データは暗号化する。
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # RDSは隔離したDatabase SubnetとDatabase Security Groupの内側だけに置く。
  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  # Public IPを持たせず、インターネットから直接接続できないようにする。
  publicly_accessible = false
  # ECS Scaling時の下流Bottleneckへ焦点を絞るため、今回はSingle-AZのまま比較する。
  multi_az = false

  # 自動バックアップを1日だけ保持する。短期学習環境なので保持期間を抑える。
  backup_retention_period = 1
  copy_tags_to_snapshot   = true

  # 学習後にterraform destroyできるよう削除保護と最終スナップショットを無効化する。
  # 本番環境なら通常は逆の判断になる。
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true
  # 学習中の変更反映を待たせない設定。本番では保守時間帯の利用も検討する。
  apply_immediately = true

  # 短期Labでは追加料金を避けるためPerformance Insightsを無効化する。
  performance_insights_enabled = false
  # パッチレベルの自動更新は有効にして既知脆弱性の放置を避ける。
  auto_minor_version_upgrade = true

  tags = { Name = local.name }
}
