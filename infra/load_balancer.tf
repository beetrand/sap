# 利用者からのHTTPリクエストを受けるインターネット向けApplication Load Balancer。
# ECSタスクを直接公開せず、ALBを唯一のWeb入口にする。
resource "aws_lb" "main" {
  # ALB名は最大32文字なので切り詰める。
  name = substr(local.name, 0, 32)
  # falseはinternet-facingを意味する。trueなら内部ALBになる。
  internal           = false
  load_balancer_type = "application"
  # インターネットから80/TCPを受け、ECSへ3000/TCPを送れるSGを付ける。
  security_groups = [aws_security_group.alb.id]
  # 2AZのPublic SubnetにALBノードを配置する。
  subnets = [for subnet in aws_subnet.public : subnet.id]
  # 学習後にdestroyできるよう削除保護は無効。本番では有効化を検討する。
  enable_deletion_protection = false
  # 不正なHTTPヘッダーをバックエンドへ転送しない。
  drop_invalid_header_fields = true

  tags = { Name = local.name }
}

# ALBがリクエストを転送するECSタスクの論理グループ。
resource "aws_lb_target_group" "app" {
  name = substr("${local.name}-app", 0, 32)
  # Fargateタスク内のNode.jsアプリが待ち受けるポート。
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  # Fargate awsvpcモードでは各タスクがENIとIPを持つため、ターゲット種別はip。
  target_type = "ip"

  # デプロイや停止時に既存接続を処理する猶予。学習環境では30秒に短縮する。
  deregistration_delay = 30

  health_check {
    # ALBが定期的にアプリとDBの生存確認を行うエンドポイント。
    enabled  = true
    path     = "/healthz"
    protocol = "HTTP"
    port     = "traffic-port"
    # HTTP 200だけを正常と判定する。
    matcher = "200"
    # 30秒ごとに最大5秒待ち、連続2回でhealthy/unhealthyを切り替える。
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${local.name}-app" }
}

# ALBの80/TCPで待ち受け、受信した全リクエストをECSターゲットへ送るListener。
# Phase 1はHTTPのみ。将来はACM証明書を使うHTTPS Listenerへ変更する。
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    # パス別ルーティングをまだ使わず、全リクエストを1つのTarget Groupへ転送する。
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = { Name = "${local.name}-http" }
}
