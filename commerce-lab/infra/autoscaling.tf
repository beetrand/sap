# ECS ServiceのDesired CountをApplication Auto Scalingの対象として登録する。
# 固定2 TaskのBaselineを先に測定できるよう、enable_autoscaling=trueの場合だけ作る。
resource "aws_appautoscaling_target" "ecs" {
  count = var.deploy_service && var.enable_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  # Application Auto Scalingが要求するservice/<cluster>/<service>形式。
  resource_id = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app[0].name}"

  min_capacity = var.ecs_min_capacity
  max_capacity = var.ecs_max_capacity
}

# ALBが各Targetへ転送した1分あたりの平均Request数をTarget値へ近づけるPolicy。
# CPU待ちではなくRDS I/O待ちが多い場合でも、利用者からの需要を直接表せる。
resource "aws_appautoscaling_policy" "alb_requests" {
  count = var.deploy_service && var.enable_autoscaling ? 1 : 0

  name               = "${local.name}-alb-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.alb_requests_per_target
    scale_out_cooldown = var.scale_out_cooldown_seconds
    scale_in_cooldown  = var.scale_in_cooldown_seconds

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # ALBとTarget GroupのARN末尾を結合したResource Labelが必要。
      resource_label = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}
