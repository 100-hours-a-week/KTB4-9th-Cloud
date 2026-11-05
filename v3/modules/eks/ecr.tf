# 이미지는 1번 빌드하고 같은 digest를 서비스별 저장소에 복사한다.
resource "aws_ecr_repository" "service" {
  for_each = toset(var.ecr_repositories)

  name                 = each.key
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        # 먼저 일치한 규칙의 이미지는 하위 규칙으로 만료되지 않으므로 Prod 승격 이미지를 보호한다.
        rulePriority = 1
        description  = "Prod 승격 이미지 보호"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["prod-"]
          countType     = "imageCountMoreThan"
          countNumber   = 9999
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "최근 이미지 30개만 유지"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}
