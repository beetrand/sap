# 予約画面のHTMLを非公開で保存するS3 Bucket。
resource "aws_s3_bucket" "frontend" {
  bucket_prefix = "${local.name}-frontend-"
  # Labをdestroyする時、HTMLが残っていてもBucketを削除できるようにする。
  force_destroy = true
}

# ACLやPolicyの設定MistakeでS3を直接PublicにしないためのGuard。
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFrontが署名付きでPrivate S3へAccessするためのOAC。
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = local.name
  description                       = "Private S3 access for the ticketing lab"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Edge Locationから予約画面をHTTPS配信するCloudFront Distribution。
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  # 日本を含みつつ、全Edgeを使うより費用を抑えるPrice Class。
  price_class = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    # 静的画面なのでRead系Methodだけ許可する。予約POSTはAPI Gatewayへ送る。
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "frontend"
    # HTTP AccessはHTTPSへRedirectする。
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# S3 Bucket PolicyのJSONをTerraformの構造化Blockから生成する。
data "aws_iam_policy_document" "frontend" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # 今回のDistributionから来たRequestだけを許可する。
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

# 上で生成したPolicyをS3 Bucketへ設定する。
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}

# HTML TemplateへAPI URLを埋め込み、index.htmlとしてS3へUploadする。
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html; charset=utf-8"
  # API URLやTemplate内容が変わるとetagも変わり、Object更新を検知できる。
  content = templatefile("${path.module}/../web/index.html.tftpl", {
    api_url = aws_apigatewayv2_api.main.api_endpoint
  })
  etag = md5(templatefile("${path.module}/../web/index.html.tftpl", {
    api_url = aws_apigatewayv2_api.main.api_endpoint
  }))
}
