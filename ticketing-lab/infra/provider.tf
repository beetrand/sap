# すべてのAWS ResourceをどのRegion・Accountへ作るか決める。
provider "aws" {
  region = var.aws_region
  # Login先を間違えた場合、plan/applyを失敗させるSafety Guard。
  allowed_account_ids = [var.allowed_account_id]

  # このProviderから作る全Resourceへ共通Tagを自動付与する。
  default_tags {
    tags = local.common_tags
  }
}

# 東京Regionで現在利用可能なAZ名をAWSから読み取る。
data "aws_availability_zones" "available" {
  state = "available"
}

# 現在LoginしているAccount IDを確認用Outputへ渡す。
data "aws_caller_identity" "current" {}
