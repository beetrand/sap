# 配置リージョン。validationで東京以外を拒否する。
variable "aws_region" {
  description = "AWS region for the disposable learning environment."
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition     = var.aws_region == "ap-northeast-1"
    error_message = "Phase 1 is intentionally limited to the Tokyo region (ap-northeast-1)."
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
  default     = "phase1"
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
  default     = "phase1-v1"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.image_tag))
    error_message = "image_tag must be a valid Docker tag."
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

# RDSのCPU・メモリクラス。Phase 1は小さいburstable classを使う。
variable "database_instance_class" {
  description = "Small burstable instance for the short-lived Phase 1 lab."
  type        = string
  default     = "db.t4g.micro"
}

# PostgreSQLのメジャーバージョン。
variable "database_engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "17"
}
