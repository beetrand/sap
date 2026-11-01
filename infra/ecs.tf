# FargateタスクとServiceをまとめて管理するECS Cluster。
# Cluster自体がEC2インスタンスを表すわけではない。
resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    # Phase 1は追加のContainer Insights料金を避け、標準メトリクスで観察する。
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Name = local.name }
}

# コンテナの標準出力・標準エラーを保管するCloudWatch LogsのLog Group。
resource "aws_cloudwatch_log_group" "app" {
  name = "/aws/ecs/${local.name}"
  # 学習環境なので7日後に自動削除し、ログ保管費用を抑える。
  retention_in_days = 7
}

# ECS Agentが「タスクを起動するため」に使うExecution Role。
# ECR取得、CloudWatch Logs送信、Secrets Manager読取などに利用される。
resource "aws_iam_role" "ecs_execution" {
  name = "${local.name}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # 人やEC2ではなくECSタスクサービスだけがこのRoleを引き受けられる。
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# AWS管理ポリシーをExecution Roleへ付ける。
# ECRからのイメージ取得とawslogsへの書き込みに必要な標準権限を含む。
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# RDSが管理するSecretだけを読める最小権限をExecution Roleへ追加する。
resource "aws_iam_role_policy" "ecs_execution_secret" {
  name = "read-rds-managed-secret"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      # 全Secretではなく、このRDSのマスターユーザーSecretだけに限定する。
      Resource = [aws_db_instance.main.master_user_secret[0].secret_arn]
    }]
  })
}

# 起動後のアプリケーションコードがAWS APIを呼ぶときに使うTask Role。
# 現在はAWS APIを直接呼ばないため、信頼ポリシーだけで権限は付けていない。
resource "aws_iam_role" "ecs_task" {
  name = "${local.name}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# 1つのFargateタスクをどのCPU・メモリ・イメージ・環境変数で動かすかを定義する。
# 更新するとrevisionが増え、ECS Serviceが新revisionへローリング更新する。
resource "aws_ecs_task_definition" "app" {
  # 同じアプリのTask Definition revisionをまとめる名前。
  family = local.name
  # EC2起動タイプではなく、AWS管理基盤のFargateを使用する。
  requires_compatibilities = ["FARGATE"]
  # タスクごとにENIとPrivate IPを持つFargate必須のネットワークモード。
  network_mode = "awsvpc"
  # Phase 1の最小構成: 0.25 vCPU、512 MiB。
  cpu                = "256"
  memory             = "512"
  execution_role_arn = aws_iam_role.ecs_execution.arn
  task_role_arn      = aws_iam_role.ecs_task.arn

  runtime_platform {
    # Dockerイメージと合わせてLinux/x86_64を明示する。
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    # Serviceのload_balancer.container_nameから参照されるコンテナ名。
    name = "app"
    # ECR上の不変タグ付きイメージ。image_tag変更で新revisionを作る。
    image = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    # 停止するとタスク全体を停止すべき主要コンテナ。
    essential = true
    cpu       = 256
    memory    = 512

    # コンテナからルートファイルシステムを書き換えさせない防御設定。
    readonlyRootFilesystem = true

    portMappings = [{
      # ALBがタスクの3000/TCPへ転送するためのポート定義。
      name          = "http"
      containerPort = 3000
      hostPort      = 3000
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    # 機密ではない実行設定は通常の環境変数として渡す。
    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3000" },
      { name = "DATABASE_HOST", value = aws_db_instance.main.address },
      { name = "DATABASE_PORT", value = tostring(aws_db_instance.main.port) },
      { name = "DATABASE_NAME", value = var.database_name },
      # RDS接続はTLSを有効化し、イメージへ同梱したAWS RDS CAで検証する。
      { name = "DATABASE_SSL", value = "true" },
      { name = "DATABASE_CA_FILE", value = "/app/certs/aws-rds-global-bundle.pem" },
      # 1タスクあたりのDB接続プール上限。タスク数増加時はRDS接続上限との積で考える。
      { name = "DATABASE_POOL_SIZE", value = "5" }
    ]

    # ユーザー名とパスワードは平文のTerraform変数にせず、起動時にSecretから注入する。
    secrets = [
      {
        name      = "DATABASE_USER"
        valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:username::"
      },
      {
        name      = "DATABASE_PASSWORD"
        valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::"
      }
    ]

    # ECSがコンテナ内部からアプリとDB接続の健全性を確認する。
    # ALB health checkとは観測主体が異なる二段階のチェック。
    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:3000/healthz').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    # console.log / console.errorをCloudWatch Logsへ送る設定。
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group  = aws_cloudwatch_log_group.app.name
        awslogs-region = var.aws_region
        # 1タスク・1コンテナごとにapp/以下のLog Streamが作成される。
        awslogs-stream-prefix = "app"
      }
    }

    linuxParameters = {
      # PID 1として軽量initを有効にし、子プロセスやシグナルを適切に扱う。
      initProcessEnabled = true
    }
  }])

  tags = { Name = local.name }
}

# Task Definitionを希望数だけ継続稼働させ、ALBへ登録するECS Service。
resource "aws_ecs_service" "app" {
  # Foundationだけ先に作れるよう、deploy_service=falseならServiceを作成しない。
  count = var.deploy_service ? 1 : 0

  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  # Phase 1は1タスク。停止時にサービス断となるため、Phase 2で複数化する。
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "LATEST"
  # 更新中も旧タスクを100%残し、最大200%まで新旧を同時起動できる。
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  # 起動直後の初期化中にALBの失敗判定で落とされないよう90秒待つ。
  health_check_grace_period_seconds = 90
  # terraform applyがServiceの安定状態まで待つ。失敗をapply時に検知しやすい。
  wait_for_steady_state = true
  # Phase 1ではECS Execを無効化し、不要な管理経路を持たせない。
  enable_execute_command = false

  network_configuration {
    # 2AZのApp Private Subnetからタスク配置先が選ばれる。
    subnets         = [for subnet in aws_subnet.app : subnet.id]
    security_groups = [aws_security_group.app.id]
    # Public IPを持たず、受信はALB、外向き通信はNAT経由にする。
    assign_public_ip = false
  }

  load_balancer {
    # 起動したタスクのPrivate IP:3000をTarget Groupへ自動登録する。
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 3000
  }

  # Listener、IAM権限、NAT経路が準備できてからタスク起動を始める。
  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy_attachment.ecs_execution,
    aws_iam_role_policy.ecs_execution_secret,
    aws_route.app_internet
  ]

  tags = { Name = local.name }
}
