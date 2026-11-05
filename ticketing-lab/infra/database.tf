resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-database"
  subnet_ids = values(aws_subnet.database)[*].id

  tags = { Name = "${local.name}-database" }
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = local.name
  engine             = "aurora-postgresql"
  engine_version     = var.aurora_engine_version
  database_name      = var.database_name
  master_username    = "labadmin"

  manage_master_user_password = true
  storage_encrypted           = true
  enable_http_endpoint        = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = var.aurora_max_acu
    seconds_until_auto_pause = 300
  }

  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true
}

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
