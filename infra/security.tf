# ALBに付けるSecurity Group。ルール本体は下の独立リソースで定義する。
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTP entry point for the Phase 1 ALB"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb" }
}

# ECSタスクに付けるSecurity Group。
# ALB以外からアプリの3000番ポートへ到達させないための境界となる。
resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "ECS tasks; ingress is accepted only from the ALB"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app" }
}

# RDSに付けるSecurity Group。
# ECSタスク以外からPostgreSQLへ到達させないための境界となる。
resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "RDS PostgreSQL; ingress is accepted only from ECS tasks"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-database" }
}

# 利用者のブラウザからALBへのHTTP通信を許可する入口。
# Phase 1は独自ドメインとACM証明書がないためHTTPだが、機密データは扱わない。
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Temporary public HTTP entry point for non-sensitive Phase 1 data"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# ALBからECSタスクのアプリポート3000への送信だけを許可する。
# CIDRではなくApp Security Groupを宛先にし、対象をECSタスクへ限定する。
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward HTTP traffic to ECS tasks"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# ECSタスク側で、ALB Security Groupを送信元とする3000/TCPだけを受け入れる。
# ALB側のegressと対になるルール。
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Accept application traffic only from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# ECSタスクからRDS Security Groupの5432/TCPだけを許可する。
# アプリがPostgreSQLへSQLを送る経路。
resource "aws_vpc_security_group_egress_rule" "app_to_database" {
  security_group_id            = aws_security_group.app.id
  description                  = "Connect to PostgreSQL"
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ECSタスクがAWS APIへHTTPSで接続するための外向き通信。
# 実際の経路はApp SubnetからNAT Gatewayを通る。Phase 4ではVPC Endpointも比較する。
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "Reach ECR, CloudWatch Logs, and Secrets Manager through the NAT gateway"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# VPC標準DNS Resolver（VPC CIDRの先頭+2）へのUDP/53を許可する。
# RDSやAWS APIのホスト名をIPアドレスへ変換するために必要。
resource "aws_vpc_security_group_egress_rule" "app_dns_udp" {
  security_group_id = aws_security_group.app.id
  description       = "Resolve the private RDS endpoint through the VPC resolver"
  cidr_ipv4         = "10.20.0.2/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

# 大きなDNS応答やUDP失敗時のフォールバック用にTCP/53も許可する。
resource "aws_vpc_security_group_egress_rule" "app_dns_tcp" {
  security_group_id = aws_security_group.app.id
  description       = "DNS fallback over TCP"
  cidr_ipv4         = "10.20.0.2/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
}

# RDS側で、App Security Groupを送信元とするPostgreSQL通信だけを受け入れる。
# App側のegressと対になり、ブラウザやALBからDBへ直接接続することはできない。
resource "aws_vpc_security_group_ingress_rule" "database_from_app" {
  security_group_id            = aws_security_group.database.id
  description                  = "Accept PostgreSQL only from ECS tasks"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
