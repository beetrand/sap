# VPC Flow Logsの出力先。アプリログとは分離してネットワーク通信を記録する。
resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/aws/vpc/${local.name}/flow"
  retention_in_days = 7
}

# VPC Flow LogsサービスがCloudWatch Logsへ書き込むためのIAM Role。
resource "aws_iam_role" "vpc_flow" {
  name = "${local.name}-vpc-flow"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # ECSではなくVPC Flow Logsサービスだけが引き受けられるRole。
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Flow Logsが対象Log GroupへStream作成とログ書き込みを行う最小権限。
resource "aws_iam_role_policy" "vpc_flow" {
  name = "write-cloudwatch-logs"
  role = aws_iam_role.vpc_flow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

# VPC内ENIの通信メタデータを収集するFlow Log。
# HTTP本文やSQL本文ではなく、送信元/宛先IP・ポート・ACCEPT/REJECT等を記録する。
resource "aws_flow_log" "main" {
  iam_role_arn         = aws_iam_role.vpc_flow.arn
  log_destination      = aws_cloudwatch_log_group.vpc_flow.arn
  log_destination_type = "cloud-watch-logs"
  # 許可通信と拒否通信の両方を学習・調査できるようALLを選ぶ。
  traffic_type = "ALL"
  vpc_id       = aws_vpc.main.id
  # 1分単位で集約し、学習時の反映待ちを短くする。
  max_aggregation_interval = 60

  tags = { Name = "${local.name}-all-traffic" }
}
