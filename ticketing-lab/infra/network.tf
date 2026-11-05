resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "database" {
  for_each = {
    a = { cidr = "10.30.20.0/24", az_index = 0 }
    c = { cidr = "10.30.21.0/24", az_index = 1 }
  }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = data.aws_availability_zones.available.names[each.value.az_index]

  tags = { Name = "${local.name}-db-${each.key}" }
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-db" }
}

resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "No network ingress; access is through the RDS Data API"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-database" }
}
