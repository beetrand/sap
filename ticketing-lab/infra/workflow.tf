# 決済以降の非同期処理に使うSSM Parameter、Lambda、Step Functions、SQS、Scheduler。
# 初回ApplyではSchedulerをDISABLEDにし、Schema Migration後に明示的に有効化する。

# Public APIへ障害注入機能を公開せず、認証済みOperatorだけが変更できるMode。
resource "aws_ssm_parameter" "simulation_mode" {
  name        = "/${local.name}/simulation-mode"
  description = "Failure simulation mode for the ticketing learning workflow"
  type        = "String"
  value       = "success"

  # Operatorが実験中にAWS CLIで変更した値を、次のplanでsuccessへ戻さない。
  lifecycle {
    ignore_changes = [value]
  }
}

# Mail失敗を3回後に隔離するDead Letter Queue。
resource "aws_sqs_queue" "mail_dlq" {
  name                      = "${local.name}-mail-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

# Step FunctionsがMail依頼を非同期で投入するQueue。
resource "aws_sqs_queue" "mail" {
  name                       = "${local.name}-mail"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 10
  sqs_managed_sse_enabled    = true

  # 同じMessageが3回失敗したら通常QueueからDLQへ移す。
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.mail_dlq.arn
    maxReceiveCount     = 3
  })
}

# Lambda Serviceだけが引き受けられるOutbox Publisher用Role。
resource "aws_iam_role" "publisher" {
  name = "${local.name}-publisher"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 決済・返金Lambdaと予約状態Lambdaが共用するRole。
resource "aws_iam_role" "workflow" {
  name = "${local.name}-workflow"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# SQSをPollするMail Worker専用Role。
resource "aws_iam_role" "mail" {
  name = "${local.name}-mail"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 3種類のLambda RoleへCloudWatch Logs書込のAWS管理Policyを付ける。
resource "aws_iam_role_policy_attachment" "workflow_logs" {
  for_each = {
    publisher = aws_iam_role.publisher.name
    workflow  = aws_iam_role.workflow.name
    mail      = aws_iam_role.mail.name
  }

  role       = each.value
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# PublisherはOutboxを読み書きし、今回のState Machineだけを開始できる。
resource "aws_iam_role_policy" "publisher" {
  name = "publish-outbox"
  role = aws_iam_role.publisher.id
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
      },
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.reservation.arn
      }
    ]
  })
}

# 決済・返金・予約状態LambdaはDBとSimulation Parameterだけを操作する。
resource "aws_iam_role_policy" "workflow" {
  name = "workflow-database-and-simulation"
  role = aws_iam_role.workflow.id
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
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.simulation_mode.arn
      }
    ]
  })
}

# Mail WorkerはQueueをPollし、送信結果をDBへ記録し、Simulation Modeを読む。
resource "aws_iam_role_policy" "mail" {
  name = "mail-queue-database-and-simulation"
  role = aws_iam_role.mail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.mail.arn
      },
      {
        Effect   = "Allow"
        Action   = "rds-data:ExecuteStatement"
        Resource = aws_rds_cluster.main.arn
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_rds_cluster.main.master_user_secret[0].secret_arn
      },
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.simulation_mode.arn
      }
    ]
  })
}

# 各LambdaのLogを学習用に7日だけ保持する。
resource "aws_cloudwatch_log_group" "workflow_lambda" {
  for_each = toset(["publisher", "payment", "reservation-state", "mail-worker"])

  name              = "/aws/lambda/${local.name}-${each.value}"
  retention_in_days = 7
}

# 未配信OutboxをClaimしてStep Functionsを開始するLambda。
resource "aws_lambda_function" "publisher" {
  function_name    = "${local.name}-publisher"
  role             = aws_iam_role.publisher.arn
  runtime          = "nodejs22.x"
  handler          = "publisher.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      DB_CLUSTER_ARN    = aws_rds_cluster.main.arn
      DB_SECRET_ARN     = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_NAME           = var.database_name
      STATE_MACHINE_ARN = aws_sfn_state_machine.reservation.arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.workflow_lambda,
    aws_iam_role_policy_attachment.workflow_logs,
    aws_iam_role_policy.publisher
  ]
}

# charge / refundを冪等なDB Operationとして記録するMock Payment Lambda。
resource "aws_lambda_function" "payment" {
  function_name    = "${local.name}-payment"
  role             = aws_iam_role.workflow.arn
  runtime          = "nodejs22.x"
  handler          = "payment.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      DB_CLUSTER_ARN            = aws_rds_cluster.main.arn
      DB_SECRET_ARN             = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_NAME                   = var.database_name
      SIMULATION_PARAMETER_NAME = aws_ssm_parameter.simulation_mode.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.workflow_lambda,
    aws_iam_role_policy_attachment.workflow_logs,
    aws_iam_role_policy.workflow
  ]
}

# Seat確定、失敗、返金中、返金済みをTransactionで変更するLambda。
resource "aws_lambda_function" "reservation_state" {
  function_name    = "${local.name}-reservation-state"
  role             = aws_iam_role.workflow.arn
  runtime          = "nodejs22.x"
  handler          = "reservation-state.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      DB_CLUSTER_ARN            = aws_rds_cluster.main.arn
      DB_SECRET_ARN             = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_NAME                   = var.database_name
      SIMULATION_PARAMETER_NAME = aws_ssm_parameter.simulation_mode.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.workflow_lambda,
    aws_iam_role_policy_attachment.workflow_logs,
    aws_iam_role_policy.workflow
  ]
}

# SQS Messageを受け、Mock Mail結果をDBへ記録するLambda。
resource "aws_lambda_function" "mail_worker" {
  function_name    = "${local.name}-mail-worker"
  role             = aws_iam_role.mail.arn
  runtime          = "nodejs22.x"
  handler          = "mail-worker.handler"
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      DB_CLUSTER_ARN            = aws_rds_cluster.main.arn
      DB_SECRET_ARN             = aws_rds_cluster.main.master_user_secret[0].secret_arn
      DB_NAME                   = var.database_name
      SIMULATION_PARAMETER_NAME = aws_ssm_parameter.simulation_mode.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.workflow_lambda,
    aws_iam_role_policy_attachment.workflow_logs,
    aws_iam_role_policy.mail
  ]
}

# SQSがMail Workerを起動するEvent Source Mapping。Batch 1で失敗Messageを個別Retryする。
resource "aws_lambda_event_source_mapping" "mail" {
  event_source_arn = aws_sqs_queue.mail.arn
  function_name    = aws_lambda_function.mail_worker.arn
  batch_size       = 1
  enabled          = true
}

# Step Functions Serviceだけが引き受けられるState Machine Role。
resource "aws_iam_role" "step_functions" {
  name = "${local.name}-step-functions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# State Machineは指定LambdaとMail Queueだけを呼び出せる。
resource "aws_iam_role_policy" "step_functions" {
  name = "invoke-workflow-tasks"
  role = aws_iam_role.step_functions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "lambda:InvokeFunction"
        Resource = [
          aws_lambda_function.payment.arn,
          aws_lambda_function.reservation_state.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.mail.arn
      }
    ]
  })
}

# 決済、Seat確定、補償返金、Mail分離を可視化するStandard Workflow。
resource "aws_sfn_state_machine" "reservation" {
  name     = "${local.name}-reservation"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  definition = jsonencode({
    Comment = "Ticket reservation payment and compensation workflow"
    StartAt = "ChargePayment"
    States = {
      ChargePayment = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.payment.arn
          Payload = {
            action            = "charge"
            "reservationId.$" = "$.reservationId"
            "outboxId.$"      = "$.outboxId"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "TransientPaymentError",
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["PaymentDeclinedError"]
          ResultPath  = "$.workflowError"
          Next        = "MarkPaymentFailed"
        }]
        Next = "ConfirmReservation"
      }
      MarkPaymentFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.reservation_state.arn
          Payload = {
            action            = "payment-failed"
            "reservationId.$" = "$.reservationId"
            "workflowError.$" = "$.workflowError"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        End = true
      }
      ConfirmReservation = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.reservation_state.arn
          Payload = {
            action            = "confirm"
            "reservationId.$" = "$.reservationId"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["ConfirmationFailedError"]
          ResultPath  = "$.workflowError"
          Next        = "MarkRefunding"
        }]
        Next = "QueueMail"
      }
      MarkRefunding = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.reservation_state.arn
          Payload = {
            action            = "mark-refunding"
            "reservationId.$" = "$.reservationId"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Next = "RefundPayment"
      }
      RefundPayment = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.payment.arn
          Payload = {
            action            = "refund"
            "reservationId.$" = "$.reservationId"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "TransientPaymentError",
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Next = "MarkRefunded"
      }
      MarkRefunded = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.reservation_state.arn
          Payload = {
            action            = "mark-refunded"
            "reservationId.$" = "$.reservationId"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        End = true
      }
      QueueMail = {
        Type     = "Task"
        Resource = "arn:aws:states:::sqs:sendMessage"
        Parameters = {
          QueueUrl        = aws_sqs_queue.mail.id
          "MessageBody.$" = "States.JsonToString($)"
        }
        ResultPath = "$.mailQueue"
        Retry = [{
          ErrorEquals     = ["States.TaskFailed"]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.mailError"
          Next        = "RecordEmailQueueFailure"
        }]
        Next = "WorkflowSucceeded"
      }
      RecordEmailQueueFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.reservation_state.arn
          Payload = {
            action            = "email-queue-failed"
            "reservationId.$" = "$.reservationId"
          }
        }
        OutputPath = "$.Payload"
        Retry = [{
          ErrorEquals = [
            "DatabaseResumingException",
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2
        }]
        End = true
      }
      WorkflowSucceeded = {
        Type = "Succeed"
      }
    }
  })
}

# Scheduler Serviceだけが引き受け、PublisherだけをInvokeできるRole。
resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "invoke-outbox-publisher"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.publisher.arn
    }]
  })
}

# 最小精度1分でOutboxを確認する。既定DISABLEDでSchema更新前の起動を防ぐ。
resource "aws_scheduler_schedule" "outbox" {
  name                = "${local.name}-outbox"
  state               = var.outbox_schedule_state
  schedule_expression = "rate(1 minute)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.publisher.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ source = "scheduler" })
  }

  depends_on = [aws_iam_role_policy.scheduler]
}
