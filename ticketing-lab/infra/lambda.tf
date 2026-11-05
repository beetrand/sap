data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/ticketing-api.zip"
}

resource "aws_iam_role" "api" {
  name = "${local.name}-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_logs" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "api_database" {
  name = "data-api-and-secret"
  role = aws_iam_role.api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds-data:BeginTransaction",
          "rds-data:CommitTransaction",
          "rds-data:ExecuteStatement",
          "rds-data:RollbackTransaction"
        ]
        Resource = aws_rds_cluster.main.arn
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_rds_cluster.main.master_user_secret[0].secret_arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.name}-api"
  retention_in_days = 7
}

resource "aws_lambda_function" "api" {
  function_name = "${local.name}-api"
  role          = aws_iam_role.api.arn
  runtime       = "nodejs22.x"
  handler       = "handler.handler"

  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  timeout     = 30
  memory_size = 256

  # 公開学習APIへの想定外の大量アクセスが、DB負荷と費用を押し上げるのを防ぐ。
  reserved_concurrent_executions = 10

  environment {
    variables = {
      DB_CLUSTER_ARN = aws_rds_cluster.main.arn
      DB_SECRET_ARN  = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_NAME        = var.database_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.api,
    aws_iam_role_policy_attachment.api_logs,
    aws_iam_role_policy.api_database
  ]
}
