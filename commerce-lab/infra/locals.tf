locals {
  # すべてのリソース名に共通で使う接頭辞。プロジェクト名と環境名をそろえ、
  # コンソールや請求明細で「この学習環境のリソース」と判別しやすくする。
  name = "${var.project_name}-${var.environment}"

  # 東京リージョンで利用可能なAZから先頭2つを選ぶ。
  # サブネットを2AZに作り、後のPhaseで冗長化を比較できる土台にする。
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # AWSリソースへ共通付与するタグ。
  # Ephemeral=trueは常設環境ではなく、学習後に削除する前提を明示する。
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "SAP practical learning"
    Ephemeral   = "true"
  }
}
