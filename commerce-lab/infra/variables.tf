# 配置リージョン。validationで東京以外を拒否する。
variable "aws_region" {
  description = "AWS region for the disposable learning environment."
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition     = var.aws_region == "ap-northeast-1"
    error_message = "This lab is intentionally limited to the Tokyo region (ap-northeast-1)."
  }
}

# 誤アカウント操作を防ぐため、実行時に必ず渡す期待AWSアカウントID。
# terraform.tfvarsへ固定保存せず、TF_VAR_allowed_account_id環境変数で渡す。
variable "allowed_account_id" {
  description = "Expected AWS account ID. Terraform refuses to operate against any other account. Supply it through TF_VAR_allowed_account_id."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "allowed_account_id must be a 12-digit AWS account ID."
  }
}

# AWSリソース名とタグへ使うプロジェクト識別子。
variable "project_name" {
  description = "Short name used in resource names and tags."
  type        = string
  default     = "sap-commerce-lab"
}

# 同じプロジェクト内の学習段階を識別する環境名。
variable "environment" {
  description = "Environment name used in resource names and tags."
  type        = string
  default     = "phase3"
}

# ECRへ最初のイメージをpushする前にECS Serviceが起動失敗しないよう、
# Foundation作成とService作成を二段階に分けるスイッチ。
variable "deploy_service" {
  description = "Create the ECS service after the first container image has been pushed to ECR."
  type        = bool
  default     = false
}

# ECS Task DefinitionがpullするECRイメージタグ。
variable "image_tag" {
  description = "Immutable ECR image tag deployed by the ECS service."
  type        = string
  default     = "phase3-v1"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid Docker tag."
  }
}

# 固定CapacityとAuto Scalingを同じCodeで比較するための切替。
# falseで2 Task固定のBaselineを測定し、同じ負荷Profileのままtrueへ変更する。
variable "enable_autoscaling" {
  description = "Create ECS Service Auto Scaling resources after the fixed-capacity baseline test."
  type        = bool
  default     = false
}

# 平常時とScale-in後に維持するTask数。2 AZへ最低1 Taskずつ置ける2を既定値にする。
variable "ecs_min_capacity" {
  description = "Minimum ECS task count and the initial desired count."
  type        = number
  default     = 2

  validation {
    condition     = var.ecs_min_capacity >= 2 && var.ecs_min_capacity <= 6 && floor(var.ecs_min_capacity) == var.ecs_min_capacity
    error_message = "ecs_min_capacity must be an integer between 2 and 6."
  }
}

# 負荷試験の費用と暴走を抑えるHard Limit。Application Auto Scalingはこの値を超えない。
variable "ecs_max_capacity" {
  description = "Maximum ECS task count allowed during the controlled scaling experiment."
  type        = number
  default     = 6

  validation {
    condition     = var.ecs_max_capacity >= 2 && var.ecs_max_capacity <= 6 && floor(var.ecs_max_capacity) == var.ecs_max_capacity
    error_message = "ecs_max_capacity must be an integer between 2 and 6."
  }
}

# 1 Taskが1分間に処理するRequest数のTarget。
# 300は5 RPS相当で、本番Capacityではなく短時間のLabでScalingを観察する初期値。
variable "alb_requests_per_target" {
  description = "Target ALB requests per ECS task per minute for target tracking."
  type        = number
  default     = 300

  validation {
    condition     = var.alb_requests_per_target >= 60 && var.alb_requests_per_target <= 6000
    error_message = "alb_requests_per_target must be between 60 and 6000 requests per minute."
  }
}

# Scale-out後に追加Taskの効果がMetricへ現れるまで待つ時間。
variable "scale_out_cooldown_seconds" {
  description = "Seconds to wait for a scale-out action to affect the target metric."
  type        = number
  default     = 60

  validation {
    condition     = var.scale_out_cooldown_seconds >= 0 && var.scale_out_cooldown_seconds <= 900 && floor(var.scale_out_cooldown_seconds) == var.scale_out_cooldown_seconds
    error_message = "scale_out_cooldown_seconds must be an integer between 0 and 900."
  }
}

# Scale-inはAvailabilityを優先してゆっくり行い、負荷停止後の挙動も観察する。
variable "scale_in_cooldown_seconds" {
  description = "Seconds to wait before another scale-in action."
  type        = number
  default     = 300

  validation {
    condition     = var.scale_in_cooldown_seconds >= 0 && var.scale_in_cooldown_seconds <= 1800 && floor(var.scale_in_cooldown_seconds) == var.scale_in_cooldown_seconds
    error_message = "scale_in_cooldown_seconds must be an integer between 0 and 1800."
  }
}

# PostgreSQL内部に最初から作成するアプリ用データベース名。
variable "database_name" {
  description = "Initial PostgreSQL database name."
  type        = string
  default     = "sapcommerce"
}

# RDS管理ユーザー名。パスワードはRDSが生成してSecrets Managerへ保存する。
variable "database_username" {
  description = "RDS master username. The password is generated and managed by RDS in Secrets Manager."
  type        = string
  default     = "sapadmin"
}

# RDSのCPU・メモリクラス。Phase 3でも小さいburstable classを使い、
# ECSを増やしたときに下流DBがBottleneckになり得ることを観察する。
variable "database_instance_class" {
  description = "Small burstable instance for the short-lived Phase 3 scaling lab."
  type        = string
  default     = "db.t4g.micro"
}

# PostgreSQLのメジャーバージョン。
variable "database_engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}
