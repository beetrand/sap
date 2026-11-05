# Auroraを置く専用VPC。LambdaはData APIを使うため、このVPCには入れない。
resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# Auroraは異なる2 AZのSubnetを要求するため、DB用Subnetを2つ作る。
resource "aws_subnet" "database" {
  # 1つの定義からa/cの2 Subnetを作る。az_indexは利用可能AZ一覧の位置。
  for_each = {
    a = { cidr = "10.30.20.0/24", az_index = 0 }
    c = { cidr = "10.30.21.0/24", az_index = 1 }
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]

  tags = { Name = "${local.name}-db-${each.key}" }
}

# DB Subnet共通のRoute Table。
# Internet向けRouteを追加しないので、DB Subnetは外部から隔離される。
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-db" }
}

# 上のRoute Tableを2つのDB Subnetへそれぞれ関連付ける。
resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}

# AuroraのNetwork Interfaceへ付けるFirewall。
# Data APIはDB Portへ直接接続しないため、Inbound Ruleを作らない。
resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "No network ingress; access is through the RDS Data API"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-database" }
}
