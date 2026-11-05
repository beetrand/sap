# Auroraへ「どのSubnet群へ配置するか」を教えるSubnet Group。
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-database"
  subnet_ids = values(aws_subnet.database)[*].id

  tags = { Name = "${local.name}-database" }
}

# Dataと設定を管理するAurora Cluster本体。
# ClusterとInstanceは別物で、下のaws_rds_cluster_instanceがComputeを担当する。
resource "aws_rds_cluster" "main" {
  cluster_identifier = local.name
  engine             = "aurora-postgresql"
  engine_version     = var.aurora_engine_version
  database_name      = var.database_name
  master_username    = "labadmin"

  # PasswordをTerraformへ書かず、RDSに生成させてSecrets Managerで管理する。
  manage_master_user_password = true
  # 保存Dataを暗号化し、HTTPSのData APIからSQLを実行できるようにする。
  storage_encrypted    = true
  enable_http_endpoint = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]

  serverlessv2_scaling_configuration {
    # 0 ACUを許可すると、接続がない時にDB Computeを完全Pauseできる。
    min_capacity = 0
    # 学習環境の費用暴走を防ぐ最大値。
    max_capacity = var.aurora_max_acu
    # 最後の接続から5分後にAuto-pauseを試みる。
    seconds_until_auto_pause = 300
  }

  # Backupは最短の1日。destroy時はFinal Snapshotを作らず学習Dataを削除する。
  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true
}

# Cluster内でSQLを実行するWriter Instance。
# db.serverlessなので、上のACU範囲に合わせて自動拡縮・Pauseする。
resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name}-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  publicly_accessible        = false
  db_subnet_group_name       = aws_db_subnet_group.main.name
  auto_minor_version_upgrade = true
}
