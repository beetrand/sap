# すべてのAWSリソース作成・読取に使うProvider設定。
provider "aws" {
  # Phase 1は東京リージョンに固定する。
  region = var.aws_region
  # 認証先が想定アカウントと違う場合、plan/applyをProvider自身が拒否する。
  allowed_account_ids = [var.allowed_account_id]

  default_tags {
    # 個別リソースへ明示しなくても、共通タグを原則すべてに付与する。
    tags = local.common_tags
  }
}

# 東京リージョンで現在availableなAZ名をAWS APIから読み取る。
data "aws_availability_zones" "available" {
  state = "available"
}

# 現在の認証情報が指すAWSアカウントIDを読み取り、outputや確認に使用する。
data "aws_caller_identity" "current" {}
