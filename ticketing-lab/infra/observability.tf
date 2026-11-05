# API、Lambda、Aurora、Workflow、Queueを同じ時間軸で比較するCloudWatch Dashboard。
# どこが遅いかを推測せず、各LayerのMetricで切り分ける。
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # 入口のRequest数と、API GatewayからLambda完了までのp95 Latency。
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway requests and latency"
          region = var.aws_region
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id, { stat = "Sum" }],
            [".", "IntegrationLatency", ".", ".", { stat = "p95", yAxis = "right" }]
          ]
        }
      },
      # Application処理時間、Error数、同時実行数を見るWidget。
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda duration, errors and concurrency"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.api.function_name, { stat = "p95" }],
            [".", "Errors", ".", ".", { stat = "Sum", yAxis = "right" }],
            [".", "ConcurrentExecutions", ".", ".", { stat = "Maximum", yAxis = "right" }]
          ]
        }
      },
      # DBの使用ACUとConnection数。Auto-pause時はCapacityが0になる。
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6
        properties = {
          title  = "Aurora Serverless capacity and connections"
          region = var.aws_region
          metrics = [
            ["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", aws_rds_cluster.main.cluster_identifier, { stat = "Average" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Maximum", yAxis = "right" }]
          ]
        }
      },
      # Standard Workflowが成功・失敗した回数を比較し、障害注入結果を確認する。
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions executions"
          region = var.aws_region
          metrics = [
            ["AWS/States", "ExecutionsStarted", "StateMachineArn", aws_sfn_state_machine.reservation.arn, { stat = "Sum" }],
            [".", "ExecutionsSucceeded", ".", ".", { stat = "Sum" }],
            [".", "ExecutionsFailed", ".", ".", { stat = "Sum" }]
          ]
        }
      },
      # Mail Workerが処理できないMessageが通常QueueまたはDLQに残っていないかを見る。
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Mail queue and dead-letter queue"
          region = var.aws_region
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.mail.name, { stat = "Maximum" }],
            [".", ".", ".", aws_sqs_queue.mail_dlq.name, { stat = "Maximum" }],
            [".", "ApproximateAgeOfOldestMessage", ".", aws_sqs_queue.mail_dlq.name, { stat = "Maximum", yAxis = "right" }]
          ]
        }
      }
    ]
  })
}
