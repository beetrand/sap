# 環境ごとに変更できる入力値をまとめるFile。
# Default値がないallowed_account_idだけは安全のため必須入力になる。

variable "aws_region" {
  description = "学習環境を作るAWSリージョン。"
  type        = string
  default     = "ap-northeast-1"
}

variable "allowed_account_id" {
  description = "誤ったAWSアカウントへのapplyを防ぐ12桁のAccount ID。"
  type        = string

  validation {
    # AWS Account IDは12桁なので、入力Mistakeをplan前に検出する。
    condition     = can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "allowed_account_idには12桁のAWS Account IDを指定してください。"
  }
}

variable "project_name" {
  description = "リソース名の接頭辞。"
  type        = string
  default     = "sap-ticketing"
}

variable "environment" {
  description = "学習環境名。"
  type        = string
  default     = "lab"
}

variable "database_name" {
  description = "Aurora PostgreSQL内のデータベース名。"
  type        = string
  default     = "ticketing"
}

variable "aurora_engine_version" {
  description = "0 ACU auto-pauseをサポートするAurora PostgreSQLのバージョン。apply前に東京リージョンで確認する。"
  type        = string
  default     = "16.6"
}

variable "aurora_max_acu" {
  description = "実験中の費用暴走を防ぐAurora Serverless v2の上限ACU。"
  type        = number
  default     = 2

  validation {
    # 設定MistakeでAuroraが高Capacityへ拡大しないよう範囲を制限する。
    condition     = var.aurora_max_acu >= 0.5 && var.aurora_max_acu <= 4
    error_message = "ラボではaurora_max_acuを0.5以上4以下に制限します。"
  }
}
