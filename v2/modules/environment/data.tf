data "aws_subnet" "private" {
  for_each = var.private_subnet_ids
  id       = each.value
}
