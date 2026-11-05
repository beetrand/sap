output "aws_account_id" {
  description = "Providerが接続したAWSアカウント。apply前の確認用。"
  value       = data.aws_caller_identity.current.account_id
}

output "frontend_url" {
  description = "予約画面のURL。"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "api_url" {
  description = "HTTP APIのベースURL。"
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "database_cluster_arn" {
  description = "Data APIと初期化スクリプトで使うAurora Cluster ARN。"
  value       = aws_rds_cluster.main.arn
}

output "database_secret_arn" {
  description = "RDS管理のMaster User Secret ARN。"
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
  sensitive   = true
}

output "database_name" {
  value = var.database_name
}

output "cloudwatch_dashboard" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "cost_controls" {
  value = {
    aurora_min_acu           = 0
    aurora_max_acu           = var.aurora_max_acu
    auto_pause_after_seconds = 300
    nat_gateway_created      = false
    alb_created              = false
    rds_proxy_created        = false
    api_rate_limit_per_sec   = 10
    lambda_concurrency_limit = 10
  }
}
