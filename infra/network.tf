# このVPCがPhase 1環境全体のネットワーク境界となる。
resource "aws_vpc" "main" {
  # /16を確保し、用途別サブネットへ十分に分割できるようにする。
  cidr_block = "10.20.0.0/16"
  # ECSからRDSエンドポイントなどのAWS DNS名を解決するために必要。
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# VPCとインターネットを接続するゲートウェイ。
# Public SubnetのALBとNAT Gatewayが外部通信するために使用する。
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# インターネットから到達可能なALBとNAT Gatewayを置くPublic Subnet。
# 2つのAZそれぞれに1つずつ作成する。
resource "aws_subnet" "public" {
  # local.azsをキーにすることで、AZごとに同じ構造を繰り返し作成する。
  for_each = { for index, az in local.azs : az => index }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  # VPCの10.20.0.0/16を/24へ分割し、0番台と1番台をPublic用に使う。
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, each.value)
  # ALBやNATはAWS側で必要なアドレスを持つため、汎用の自動Public IP付与は無効。
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${each.key}" }
}

# ECS Fargateタスクを置くPrivate Subnet。
# インターネットからタスクへ直接到達できず、ALBだけを入口にする。
resource "aws_subnet" "app" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  # 10番台と11番台の/24をアプリケーション層へ割り当てる。
  cidr_block = cidrsubnet(aws_vpc.main.cidr_block, 8, 10 + each.value)
  # FargateタスクへPublic IPを付与しない設計。
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-app-${each.key}" }
}

# RDSを置くDatabase Subnet。
# 外向きのデフォルトルートも持たせず、アプリ層からのDB接続だけを受ける。
resource "aws_subnet" "database" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  # 20番台と21番台の/24をデータベース層へ割り当てる。
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, 20 + each.value)
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-db-${each.key}" }
}

# Public Subnet専用のルートテーブル。
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public" }
}

# 宛先がVPC内部以外の通信をInternet Gatewayへ送る。
# このルートと後続の関連付けによってPublic Subnetになる。
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# 2つのPublic Subnetへ同じPublicルートテーブルを関連付ける。
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# NAT Gatewayが外部通信で使用する固定Public IPv4アドレス。
# NAT Gatewayの課金とは別に、Public IPv4の時間課金も発生する。
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat" }

  # Internet Gateway作成後にEIPをVPC用途で確保する順序を明示する。
  depends_on = [aws_internet_gateway.main]
}

# PrivateなApp Subnetから外向き通信を行うためのNAT Gateway。
# Phase 1では費用を抑えるため1AZだけに置くので、単一障害点である。
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  # 先頭AZのPublic Subnetへ配置する。Phase 2ではAZごとのNATも比較対象になる。
  subnet_id = aws_subnet.public[local.azs[0]].id

  tags = { Name = "${local.name}-nat-${local.azs[0]}" }

  depends_on = [aws_internet_gateway.main]
}

# App Subnet専用のルートテーブル。
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-app" }
}

# ECSタスクの外向き通信をNAT Gatewayへ送る。
# ECRからのイメージ取得、CloudWatch Logs送信、Secrets Manager参照に使う。
resource "aws_route" "app_internet" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# 2つのApp Subnetへ同じルートテーブルを関連付ける。
resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

# Database Subnet専用のルートテーブル。
# 意図的に0.0.0.0/0のルートを追加せず、外部への経路を持たない隔離層にする。
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-database-isolated" }
}

# 2つのDatabase Subnetへ隔離用ルートテーブルを関連付ける。
resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}
