data "aws_ssm_parameter" "ecs_optimized_al2" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

resource "aws_iam_role" "worker_instance" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name               = "${local.name_prefix}-judge-worker-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "worker_instance" {
  for_each = var.enable_judge_worker_capacity ? {
    ecs = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  } : {}

  role       = aws_iam_role.worker_instance[0].name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "worker" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name = "${local.name_prefix}-judge-worker-instance"
  role = aws_iam_role.worker_instance[0].name
}

resource "aws_launch_template" "worker" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name_prefix = "${local.name_prefix}-judge-worker-"
  # Judge0 1.13.1 bundles isolate 1.8.1, whose --cg mode requires cgroup v1.
  # Keep the worker on ECS-optimized AL2 until the Judge runtime supports cgroup v2.
  image_id               = data.aws_ssm_parameter.ecs_optimized_al2.value
  update_default_version = true
  user_data = base64encode(templatefile("${path.module}/templates/ecs-worker-user-data.sh.tftpl", {
    cluster_name = aws_ecs_cluster.main.name
  }))

  iam_instance_profile {
    name = aws_iam_instance_profile.worker[0].name
  }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    device_index                = 0
    security_groups             = [aws_security_group.worker_host.id]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  monitoring { enabled = true }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      encrypted             = true
      volume_size           = var.worker_root_volume_size
      volume_type           = "gp3"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.name_prefix}-judge-worker"
      Service = "judge-worker"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${local.name_prefix}-judge-worker-root"
      Service = "judge-worker"
    }
  }

  tags = { Name = "${local.name_prefix}-judge-worker" }
}

resource "aws_autoscaling_group" "worker_on_demand" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name                  = "${local.name_prefix}-judge-worker-on-demand"
  min_size              = 0
  desired_capacity      = 0
  max_size              = 1
  vpc_zone_identifier   = values(var.private_subnet_ids)
  protect_from_scale_in = true
  health_check_type     = "EC2"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 100
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker[0].id
        version            = "$Latest"
      }

      override { instance_type = var.worker_on_demand_instance_type }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-judge-worker-on-demand"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "judge-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  depends_on = [aws_iam_role_policy_attachment.worker_instance]
}

resource "aws_autoscaling_group" "worker_spot" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name                  = "${local.name_prefix}-judge-worker-spot"
  min_size              = 0
  desired_capacity      = 0
  max_size              = var.worker_spot_max_size
  vpc_zone_identifier   = values(var.private_subnet_ids)
  protect_from_scale_in = true
  capacity_rebalance    = true
  health_check_type     = "EC2"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized-prioritized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.worker[0].id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = var.worker_spot_instance_types
        content { instance_type = override.value }
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-judge-worker-spot"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "judge-worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  depends_on = [aws_iam_role_policy_attachment.worker_instance]

  lifecycle {
    # ECS managed scaling owns the live desired capacity.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "worker_on_demand" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name = "${local.name_prefix}-judge-worker-on-demand"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.worker_on_demand[0].arn
    managed_draining               = "ENABLED"
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
      instance_warmup_period    = 300
    }
  }

  tags = { Name = "${local.name_prefix}-judge-worker-on-demand" }
}

resource "aws_ecs_capacity_provider" "worker_spot" {
  count = var.enable_judge_worker_capacity ? 1 : 0

  name = "${local.name_prefix}-judge-worker-spot"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.worker_spot[0].arn
    managed_draining               = "ENABLED"
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = var.worker_spot_max_size
      instance_warmup_period    = 300
    }
  }

  tags = { Name = "${local.name_prefix}-judge-worker-spot" }
}
