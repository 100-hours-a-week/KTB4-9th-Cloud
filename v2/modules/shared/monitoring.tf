data "aws_ami" "monitoring_ubuntu" {
  count = var.enable_monitoring ? 1 : 0

  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  monitoring_config_files = var.enable_monitoring ? fileset("${path.module}/../../monitoring", "**") : toset([])
}

resource "aws_security_group" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name        = "${var.project_name}-monitoring"
  description = "Public HTTPS entry for the regional Grafana host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Caddy HTTP redirect and ACME challenge"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Caddy HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Package, AWS API, and private metrics access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  revoke_rules_on_delete = true

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring-sg" })
}

resource "aws_s3_bucket" "monitoring_config" {
  count = var.enable_monitoring ? 1 : 0

  bucket_prefix = "${var.project_name}-monitoring-config-"

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring-config" })
}

resource "aws_s3_bucket_ownership_controls" "monitoring_config" {
  count = var.enable_monitoring ? 1 : 0

  bucket = aws_s3_bucket.monitoring_config[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "monitoring_config" {
  count = var.enable_monitoring ? 1 : 0

  bucket                  = aws_s3_bucket.monitoring_config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "monitoring_config" {
  count = var.enable_monitoring ? 1 : 0

  bucket = aws_s3_bucket.monitoring_config[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "monitoring_config" {
  count = var.enable_monitoring ? 1 : 0

  bucket = aws_s3_bucket.monitoring_config[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "monitoring_config_tls" {
  count = var.enable_monitoring ? 1 : 0

  bucket = aws_s3_bucket.monitoring_config[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.monitoring_config[0].arn,
        "${aws_s3_bucket.monitoring_config[0].arn}/*",
      ]
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.monitoring_config]
}

resource "aws_s3_object" "monitoring_config" {
  for_each = local.monitoring_config_files

  bucket = aws_s3_bucket.monitoring_config[0].id
  key    = each.value
  source = "${path.module}/../../monitoring/${each.value}"
  etag   = filemd5("${path.module}/../../monitoring/${each.value}")

  depends_on = [
    aws_s3_bucket_ownership_controls.monitoring_config,
    aws_s3_bucket_server_side_encryption_configuration.monitoring_config,
  ]
}

resource "aws_secretsmanager_secret" "monitoring_grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  name                    = "/${var.project_name}/monitoring/grafana-admin"
  recovery_window_in_days = 7

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring-grafana-admin" })
}

resource "random_password" "grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  length           = 32
  special          = true
  override_special = "_%@-"
}

resource "aws_secretsmanager_secret_version" "monitoring_grafana_admin" {
  count = var.enable_monitoring ? 1 : 0

  secret_id     = aws_secretsmanager_secret.monitoring_grafana_admin[0].id
  secret_string = random_password.grafana_admin[0].result
}

resource "aws_iam_role" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name = "${var.project_name}-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring-role" })
}

resource "aws_iam_role_policy_attachment" "monitoring_ssm" {
  count = var.enable_monitoring ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "monitoring_read" {
  count = var.enable_monitoring ? 1 : 0

  name = "${var.project_name}-monitoring-read"
  role = aws_iam_role.monitoring[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadMonitoringConfigBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.monitoring_config[0].arn]
      },
      {
        Sid      = "ReadMonitoringConfigObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = ["${aws_s3_bucket.monitoring_config[0].arn}/*"]
      },
      {
        Sid      = "ReadGrafanaAdminSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.monitoring_grafana_admin[0].arn]
      },
      {
        Sid    = "DiscoverEcsTargets"
        Effect = "Allow"
        Action = [
          "ecs:DescribeClusters",
          "ecs:DescribeContainerInstances",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListClusters",
          "ecs:ListServices",
          "ecs:ListTagsForResource",
          "ecs:ListTasks",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "tag:GetResources",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "ReadCloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "QueryCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
          "logs:GetQueryResults",
          "logs:StartQuery",
          "logs:StopQuery",
        ]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  name = "${var.project_name}-monitoring"
  role = aws_iam_role.monitoring[0].name
}

resource "aws_instance" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  depends_on = [
    aws_iam_role_policy.monitoring_read,
    aws_iam_role_policy_attachment.monitoring_ssm,
    aws_s3_object.monitoring_config,
    aws_secretsmanager_secret_version.monitoring_grafana_admin,
  ]

  ami                         = data.aws_ami.monitoring_ubuntu[0].id
  instance_type               = var.monitoring_instance_type
  subnet_id                   = aws_subnet.public["0"].id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.monitoring[0].name
  vpc_security_group_ids      = [aws_security_group.monitoring[0].id]
  monitoring                  = true
  user_data = templatefile("${path.module}/templates/monitoring-user-data.sh.tftpl", {
    config_bucket_name  = aws_s3_bucket.monitoring_config[0].id
    monitoring_hostname = var.monitoring_hostname
    aws_region          = var.aws_region
    admin_secret_arn    = aws_secretsmanager_secret.monitoring_grafana_admin[0].arn
    data_device_path    = "/dev/sdf"
  })
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = var.monitoring_root_volume_size
    delete_on_termination = true
  }

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring" })
}

resource "aws_eip" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.monitoring[0].id

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring-eip" })
}

resource "aws_ebs_volume" "monitoring_data" {
  count = var.enable_monitoring ? 1 : 0

  availability_zone = aws_subnet.public["0"].availability_zone
  encrypted         = true
  type              = "gp3"
  size              = var.monitoring_data_volume_size

  tags = merge(local.common_tags, { Name = "${var.project_name}-monitoring-data" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "monitoring_data" {
  count = var.enable_monitoring ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.monitoring_data[0].id
  instance_id = aws_instance.monitoring[0].id
}
