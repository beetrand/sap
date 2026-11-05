# 外部入力ではなく、Terraform内部で何度も使う計算値を定義する。
locals {
  # 例: sap-ticketingとlabからsap-ticketing-labを作る。
  name = "${var.project_name}-${var.environment}"

  # Cost ExplorerやResource一覧で用途を判別する共通Tag。
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "AWS SAP learning"
  }
}
