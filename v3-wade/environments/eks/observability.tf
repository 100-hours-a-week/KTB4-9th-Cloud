resource "aws_s3_bucket" "tempo" {
  bucket        = "${local.name}-tempo-352635536602"
  force_destroy = true

  tags = {
    Name      = "${local.name}-tempo"
    Component = "observability"
  }
}

resource "aws_s3_bucket_public_access_block" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id

  rule {
    id     = "expire-traces-after-retention"
    status = "Enabled"

    filter {}

    # Tempo compactor가 14일 보존을 처리한 뒤 S3가 하루의 안전 여유를 두고 정리한다.
    expiration {
      days = 15
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "tempo_bucket_name" {
  value = aws_s3_bucket.tempo.bucket
}
