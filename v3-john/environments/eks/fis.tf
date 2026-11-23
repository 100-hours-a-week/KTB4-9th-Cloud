# S2 스팟 노드 회수 실험(설계서 9.2)용 AWS FIS 역할과 중단 조건 알람.
# 실험 템플릿은 실험마다 대상 인스턴스가 달라서 chaos/scenarios/s2/inject.sh가 만들고 stop.sh가 지운다.
locals {
  fis_target_node_group = "application-ng"
}

data "aws_iam_policy_document" "fis_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "fis" {
  name               = "${local.name}-fis"
  assume_role_policy = data.aws_iam_policy_document.fis_assume.json
}

# 회수 알림은 이 클러스터의 application 노드 그룹 인스턴스에만 보낼 수 있다.
data "aws_iam_policy_document" "fis" {
  statement {
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/eks:cluster-name"
      values   = [local.name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/eks:nodegroup-name"
      values   = [local.fis_target_node_group]
    }
  }
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fis" {
  name   = "spot-interruption"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis.json
}

# 관리형 노드 그룹의 ASG는 그룹 지표를 기본으로 내지 않는다. 지표가 없으면 아래 알람이 영영 울리지 않으므로 켠다.
resource "terraform_data" "application_asg_metrics" {
  input = module.eks.node_group_asg_names[local.fis_target_node_group]

  provisioner "local-exec" {
    command = "aws autoscaling enable-metrics-collection --region ${var.aws_region} --auto-scaling-group-name ${self.input} --granularity 1Minute --metrics GroupInServiceInstances"
  }
}

# 중단 조건: application 노드가 1분 동안 한 대도 없다. 실험이 노드 1대가 아니라 노드 그룹 전체를 잃게 만들면 FIS가 실험을 멈춘다.
resource "aws_cloudwatch_metric_alarm" "fis_stop_application" {
  alarm_name          = "${local.name}-fis-stop-application"
  alarm_description   = "S2 FIS 중단 조건: application 노드 그룹 InService 0대"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = module.eks.node_group_asg_names[local.fis_target_node_group] }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "missing"

  depends_on = [terraform_data.application_asg_metrics]
}
