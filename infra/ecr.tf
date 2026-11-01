# アプリケーションのDockerイメージを保存するElastic Container Registry。
resource "aws_ecr_repository" "app" {
  name = local.name
  # 同じタグの上書きを禁止し、どのTask Definitionがどのイメージか追跡可能にする。
  image_tag_mutability = "IMMUTABLE"
  # 学習後のdestroy時にイメージが残っていてもRepositoryを削除できるようにする。
  force_delete = true

  image_scanning_configuration {
    # pushごとにOS・パッケージの既知脆弱性を自動スキャンする。
    scan_on_push = true
  }

  encryption_configuration {
    # ECR保存時暗号化。Phase 1はAWS管理のAES-256を使用する。
    encryption_type = "AES256"
  }
}

# 古いイメージを無制限に蓄積しないためのLifecycle Policy。
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the five most recent images in this disposable lab"
      # 新しい5世代だけを残し、それより古いイメージをECRが期限切れにする。
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
