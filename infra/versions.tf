# Terraform CLIとAWS Providerの互換範囲を固定し、PCごとの挙動差を抑える。
terraform {
  # この構成で検証したTerraformの最低バージョン。
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      # HashiCorp公式AWS Providerを使い、6.x系の範囲で更新を許可する。
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
