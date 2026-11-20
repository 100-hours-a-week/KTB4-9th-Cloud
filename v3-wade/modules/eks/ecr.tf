# ECR은 클러스터 teardown과 독립된 environments/ecr state에서 관리한다.
data "aws_ecr_repository" "service" {
  for_each = toset(var.ecr_repositories)

  name = each.key
}
