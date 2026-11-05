# Terraform本体とProviderのVersion条件を宣言するFile。
# terraform init時にこの条件を読み、実際に使うVersionを.terraform.lock.hclへ固定する。
terraform {
  # 古いTerraformで未対応の構文を実行しないための下限。
  required_version = ">= 1.9.0"

  required_providers {
    # Lambdaへ渡すSource CodeをZIPにまとめるProvider。
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    # Aurora、Lambda、API Gatewayなどを操作するProvider。
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
