# src DirectoryのJavaScriptをZIPにまとめ、LambdaへUploadできる形にする。
data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/ticketing-api.zip"
}

# Lambda FunctionがAWS上で名乗るIAM Role。
resource "aws_iam_role" "api" {
  name = "${local.name}-api"

  # Trust Policyは「誰がRoleを引き受けてよいか」を定義する。
  # ここではLambda Serviceだけにsts:AssumeRoleを許可する。
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logsへ書き込むAWS管理PolicyをRoleへAttachする。
resource "aws_iam_role_policy_attachment" "api_logs" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permission Policyは、Roleを引き受けたLambdaが何をしてよいかを定義する。
# Data APIのTransaction操作と、このAuroraのSecret読取だけに限定する。
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
        # 全Auroraではなく、今回作るClusterだけを操作対象にする。
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

# LambdaのApplication Log保存先。学習用なので7日で自動削除する。
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.name}-api"
  retention_in_days = 7
}

# API Gatewayから呼ばれ、予約SQLをData APIへ送るLambda Function。
resource "aws_lambda_function" "api" {
  function_name = "${local.name}-api"
  role          = aws_iam_role.api.arn
  runtime       = "nodejs22.x"
  handler       = "handler.handler"

  # Source CodeのHashが変わるとTerraformがCode更新を検知する。
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  timeout     = 30
  memory_size = 256

  # Reserved Concurrencyは設定しない。
  # このSandbox Accountでは、関数へ10枠を予約するとAccount共通の未予約枠を
  # AWSが要求する最低10枠以上残せず、PutFunctionConcurrencyが失敗するためである。
  # 想定外の大量AccessはAPI Gatewayの10 RPS / Burst 20で入口から抑え、
  # Database側はAurora Serverless v2の最大2 ACUで費用上限を設ける。

  environment {
    # Terraformで作ったResource情報をCodeへ環境変数として渡す。
    variables = {
      DB_CLUSTER_ARN = aws_rds_cluster.main.arn
      DB_SECRET_ARN  = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_NAME        = var.database_name
    }
  }

  # Role、権限、Log Groupの準備後にFunctionを作る順序を明示する。
  depends_on = [
    aws_cloudwatch_log_group.api,
    aws_iam_role_policy_attachment.api_logs,
    aws_iam_role_policy.api_database
  ]
}
