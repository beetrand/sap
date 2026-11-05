# BrowserからHTTPS Requestを受け取るServerlessなHTTP API。
resource "aws_apigatewayv2_api" "main" {
  name          = local.name
  protocol_type = "HTTP"

  # CloudFrontの画面とAPIは別OriginなのでBrowserのCORS許可が必要。
  # 認証追加後はallow_originsをCloudFront Domainへ絞る。
  cors_configuration {
    allow_headers = ["content-type"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_origins = ["*"]
    max_age       = 300
  }
}

# API Gatewayが受けたRequestをLambdaへ渡すIntegration。
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

# 全Pathを同じLambdaへ渡すDefault Route。
# /events等の振り分けはLambda Code内で行う。
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# APIを実際に公開するStage。$defaultならURLへStage名が付かない。
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # 想定外のAccessと費用を抑える。平常10 RPS、短いBurstは20 Requestまで。
  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }

  # RequestごとのStatusやLatencyをCloudWatch LogsへJSONで保存する。
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

# API Gateway Access Log専用の保存先。LambdaのApplication Logとは分ける。
resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 7
}

# API Gateway Serviceに、このLambdaを呼び出す権限を与える。
# Lambda自身のExecution Roleとは逆向きの権限である。
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
