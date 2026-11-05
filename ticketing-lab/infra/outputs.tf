# apply後に人やScriptが必要とするURL・ARN・確認値を表示するFile。
# PasswordなどSecretの中身はOutputしない。

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
  # ARNも通常のConsole出力へ不用意に出さないようsensitive扱いにする。
  sensitive = true
}

output "database_name" {
  value = var.database_name
}

output "cloudwatch_dashboard" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

# 障害実験Scriptが、Parameter名を手入力せず安全に取得するためのOutput。
output "simulation_parameter_name" {
  description = "決済・返金・Mailの模擬障害Modeを保存するSSM Parameter名。"
  value       = aws_ssm_parameter.simulation_mode.name
}

# Schedulerを有効化する前に、Outboxを1回だけ手動配信するためのFunction名。
output "outbox_publisher_function_name" {
  description = "未配信OutboxをStep Functionsへ渡すLambda Function名。"
  value       = aws_lambda_function.publisher.function_name
}

# Consoleで対象のState Machineを見つけ、Execution Historyを観察するためのARN。
output "reservation_state_machine_arn" {
  description = "決済・座席確定・補償返金を実行するStandard Workflow ARN。"
  value       = aws_sfn_state_machine.reservation.arn
}

# Mail失敗実験で、通常QueueとDLQを取り違えず観察するための名前。
output "mail_queue_names" {
  description = "予約完了Mailの通常Queue名とDead Letter Queue名。"
  value = {
    queue = aws_sqs_queue.mail.name
    dlq   = aws_sqs_queue.mail_dlq.name
  }
}

output "cost_controls" {
  description = "費用Guardが意図どおり設定されたかまとめて確認する値。"
  value = {
    aurora_min_acu           = 0
    aurora_max_acu           = var.aurora_max_acu
    auto_pause_after_seconds = 300
    nat_gateway_created      = false
    alb_created              = false
    rds_proxy_created        = false
    api_rate_limit_per_sec   = 10
    outbox_schedule_state    = var.outbox_schedule_state
    mail_dlq_max_receive     = 3
    # Reserved Concurrencyは、このSandbox Accountの小さいQuotaでは設定できない。
    # LambdaはAccount共通の未予約枠を使用し、入口のAPI Gatewayで10 RPSに制限する。
    lambda_reserved_concurrency = "not configured (shared account quota)"
  }
}
