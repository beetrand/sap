# apply前後に、認証先アカウントが想定どおりか人が確認するための値。
output "aws_account_id" {
  description = "AWS account selected by the active credentials. Verify this before apply."
  value       = data.aws_caller_identity.current.account_id
}

# 実際に選択されたAWSリージョン。
output "aws_region" {
  description = "Deployment region."
  value       = var.aws_region
}

# サブネット作成に使用した2つのAZ。
output "availability_zones" {
  description = "The two Availability Zones used by the lab."
  value       = local.azs
}

# build-and-push.ps1へ渡すECR Repository URL。
output "ecr_repository_url" {
  description = "Push the application image to this ECR repository before enabling deploy_service."
  value       = aws_ecr_repository.app.repository_url
}

# ブラウザで開くALBの一時HTTP URL。
output "application_url" {
  description = "Temporary HTTP URL for the non-sensitive Phase 3 lab."
  value       = "http://${aws_lb.main.dns_name}"
}

# ECS Service作成スイッチの現在値。
output "ecs_service_deployed" {
  description = "Whether the ECS service is part of this apply."
  value       = var.deploy_service
}

# 固定CapacityとAuto Scalingのどちらを現在deployしているか確認する。
output "autoscaling_enabled" {
  description = "Whether ECS Service Auto Scaling resources are enabled."
  value       = var.deploy_service && var.enable_autoscaling
}

# 実験前にTask数のHard Limitを確認するための値。
output "ecs_capacity_range" {
  description = "Minimum and maximum ECS task counts allowed by the Phase 3 experiment."
  value = {
    min = var.ecs_min_capacity
    max = var.ecs_max_capacity
  }
}

# Service作成時だけ存在するCloudWatch Dashboard名。
output "scaling_dashboard_name" {
  description = "CloudWatch dashboard used during the scaling experiment, or null before service deployment."
  value       = var.deploy_service ? aws_cloudwatch_dashboard.scaling[0].dashboard_name : null
}

# ECSからだけ到達できるRDSのPrivate endpointとport。
output "rds_endpoint" {
  description = "Private RDS endpoint; it is reachable only from the ECS security group."
  value       = aws_db_instance.main.endpoint
}

# destroy後に課金リソースが残っていないか確認するためのチェックリスト。
output "cost_cleanup_checklist" {
  description = "Resources that must be absent after destroy."
  value = [
    "RDS instances and manual snapshots",
    "NAT gateways and unassociated Elastic IP addresses",
    "Application Load Balancers and target groups",
    "ECS services and running tasks",
    "ECR repositories and images",
    "CloudWatch log groups",
    "RDS-managed Secrets Manager secrets"
  ]
}
