data "aws_ssm_parameter" "ecs_optimized_al2023" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_container_instance" {
  name               = "${local.name_prefix}-ecs-container-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_container_instance" {
  for_each = {
    ecs = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  role       = aws_iam_role.ecs_container_instance.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "ecs_container_instance" {
  name = "${local.name_prefix}-ecs-container-instance"
  role = aws_iam_role.ecs_container_instance.name
}

resource "aws_ebs_volume" "stateful" {
  for_each = local.stateful_services

  availability_zone = data.aws_subnet.private[each.value.index].availability_zone
  size              = var.stateful_ebs_size
  type              = "gp3"
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name         = "${local.name_prefix}-${each.key}-data"
    Service      = each.key
    BackupPolicy = each.key
  }
}

resource "aws_instance" "stateful" {
  for_each = local.stateful_services

  ami                         = data.aws_ssm_parameter.ecs_optimized_al2023.value
  instance_type               = var.stateful_instance_type
  subnet_id                   = var.private_subnet_ids[each.value.index]
  vpc_security_group_ids      = [aws_security_group.data[each.key].id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ecs_container_instance.name
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/ecs-stateful-user-data.sh.tftpl", {
    cluster_name = aws_ecs_cluster.main.name
    service_name = each.key
    volume_id    = aws_ebs_volume.stateful[each.key].id
    mount_path   = each.value.mount_path
  })

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data]
  }

  tags = {
    Name    = "${local.name_prefix}-${each.key}"
    Service = each.key
  }
}

resource "aws_volume_attachment" "stateful" {
  for_each = local.stateful_services

  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.stateful[each.key].id
  instance_id  = aws_instance.stateful[each.key].id
  skip_destroy = true
}

