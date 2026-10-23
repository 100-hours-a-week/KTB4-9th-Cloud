locals {
  stage_office_hours_enabled = var.environment == "stage" && var.enable_stage_office_hours
  stage_office_hours_cluster = "${local.name_prefix}-cluster"
  stage_office_hours_mysql   = "${local.name_prefix}-mysql"
  stage_office_hours_asg     = "${local.name_prefix}-judge-worker-spot"

  stage_office_hours_application_services = [
    "${local.name_prefix}-spring",
    "${local.name_prefix}-fastapi",
    "${local.name_prefix}-mlflow",
    "${local.name_prefix}-judge-api",
    "${local.name_prefix}-judge-worker",
  ]

  stage_office_hours_data_services = [
    "${local.name_prefix}-ai-postgres",
    "${local.name_prefix}-judge-postgres",
  ]
}

data "aws_instances" "stage_office_hours_stateful" {
  count = local.stage_office_hours_enabled ? 1 : 0

  filter {
    name   = "tag:Name"
    values = ["${local.name_prefix}-stateful"]
  }

  filter {
    name   = "instance-state-name"
    values = ["pending", "running", "stopping", "stopped"]
  }
}

data "aws_iam_policy_document" "stage_office_hours_sfn_assume" {
  count = local.stage_office_hours_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "stage_office_hours_sfn" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name               = "${local.name_prefix}-office-hours-sfn"
  assume_role_policy = data.aws_iam_policy_document.stage_office_hours_sfn_assume[0].json

  tags = { Name = "${local.name_prefix}-office-hours-sfn" }
}

data "aws_iam_policy_document" "stage_office_hours_sfn" {
  count = local.stage_office_hours_enabled ? 1 : 0

  statement {
    sid = "ManageStageEcsServices"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${local.stage_office_hours_cluster}/*",
    ]
  }

  statement {
    sid = "ManageStageStatefulInstance"
    actions = [
      "ec2:DescribeInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
    ]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${data.aws_instances.stage_office_hours_stateful[0].ids[0]}"]
  }

  statement {
    sid       = "DescribeEc2State"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid = "ManageStageMysql"
    actions = [
      "rds:StartDBInstance",
      "rds:StopDBInstance",
    ]
    resources = ["arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:${local.stage_office_hours_mysql}"]
  }

  statement {
    sid       = "DescribeStageMysql"
    actions   = ["rds:DescribeDBInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "ScaleJudgeWorkerToZero"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = ["arn:aws:autoscaling:${var.aws_region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${local.stage_office_hours_asg}"]
  }

  statement {
    sid = "WriteExecutionLogs"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "stage_office_hours_sfn" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name   = "${local.name_prefix}-office-hours-sfn"
  role   = aws_iam_role.stage_office_hours_sfn[0].id
  policy = data.aws_iam_policy_document.stage_office_hours_sfn[0].json
}

resource "aws_cloudwatch_log_group" "stage_office_hours" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name              = "/aws/vendedlogs/states/${local.name_prefix}-office-hours"
  retention_in_days = 14

  tags = { Name = "${local.name_prefix}-office-hours" }
}

resource "aws_sfn_state_machine" "stage_office_hours" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name     = "${local.name_prefix}-office-hours"
  role_arn = aws_iam_role.stage_office_hours_sfn[0].arn
  type     = "STANDARD"

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.stage_office_hours[0].arn}:*"
  }

  definition = jsonencode({
    Comment = "Operate stage from 09:00 to 23:00 Asia/Seoul on weekdays"
    StartAt = "ChooseAction"
    States = {
      ChooseAction = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.action"
            StringEquals = "start"
            Next         = "StartRds"
          },
          {
            Variable     = "$.action"
            StringEquals = "stop"
            Next         = "StopSpring"
          },
        ]
        Default = "InvalidAction"
      }

      InvalidAction = {
        Type  = "Fail"
        Error = "InvalidAction"
        Cause = "action must be start or stop"
      }

      StartRds = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:rds:startDBInstance"
        Parameters = {
          DbInstanceIdentifier = local.stage_office_hours_mysql
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = null
          Next        = "StartStatefulEc2"
        }]
        Next = "StartStatefulEc2"
      }

      StartStatefulEc2 = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ec2:startInstances"
        Parameters = {
          InstanceIds = [data.aws_instances.stage_office_hours_stateful[0].ids[0]]
        }
        ResultPath = null
        Next       = "InitialStartWait"
      }

      InitialStartWait = {
        Type    = "Wait"
        Seconds = 60
        Next    = "DescribeRdsForStart"
      }

      DescribeRdsForStart = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:rds:describeDBInstances"
        Parameters = {
          DbInstanceIdentifier = local.stage_office_hours_mysql
        }
        Next = "IsRdsAvailable"
      }

      IsRdsAvailable = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.DbInstances[0].DbInstanceStatus"
          StringEquals = "available"
          Next         = "DescribeEc2ForStart"
        }]
        Default = "WaitForRds"
      }

      WaitForRds = {
        Type    = "Wait"
        Seconds = 60
        Next    = "DescribeRdsForStart"
      }

      DescribeEc2ForStart = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ec2:describeInstances"
        Parameters = {
          InstanceIds = [data.aws_instances.stage_office_hours_stateful[0].ids[0]]
        }
        Next = "IsEc2Running"
      }

      IsEc2Running = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.Reservations[0].Instances[0].State.Name"
          StringEquals = "running"
          Next         = "StartAiPostgres"
        }]
        Default = "WaitForEc2"
      }

      WaitForEc2 = {
        Type    = "Wait"
        Seconds = 30
        Next    = "DescribeEc2ForStart"
      }

      StartAiPostgres = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = {
          Cluster      = local.stage_office_hours_cluster
          Service      = local.stage_office_hours_data_services[0]
          DesiredCount = 1
        }
        ResultPath = null
        Next       = "StartJudgePostgres"
      }

      StartJudgePostgres = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = {
          Cluster      = local.stage_office_hours_cluster
          Service      = local.stage_office_hours_data_services[1]
          DesiredCount = 1
        }
        ResultPath = null
        Next       = "WaitForDataServices"
      }

      WaitForDataServices = {
        Type    = "Wait"
        Seconds = 60
        Next    = "DescribeDataServices"
      }

      DescribeDataServices = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:describeServices"
        Parameters = {
          Cluster  = local.stage_office_hours_cluster
          Services = local.stage_office_hours_data_services
        }
        Next = "AreDataServicesRunning"
      }

      AreDataServicesRunning = {
        Type = "Choice"
        Choices = [{
          And = [
            {
              Variable                 = "$.Services[0].RunningCount"
              NumericGreaterThanEquals = 1
            },
            {
              Variable                 = "$.Services[1].RunningCount"
              NumericGreaterThanEquals = 1
            },
          ]
          Next = "StartSpring"
        }]
        Default = "WaitForDataServices"
      }

      StartSpring = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[0], DesiredCount = 1 }
        ResultPath = null
        Next       = "StartFastapi"
      }

      StartFastapi = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[1], DesiredCount = 1 }
        ResultPath = null
        Next       = "StartMlflow"
      }

      StartMlflow = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[2], DesiredCount = 1 }
        ResultPath = null
        Next       = "StartJudgeApi"
      }

      StartJudgeApi = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[3], DesiredCount = 1 }
        ResultPath = null
        Next       = "StartJudgeWorker"
      }

      StartJudgeWorker = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[4], DesiredCount = 1 }
        ResultPath = null
        End        = true
      }

      StopSpring = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[0], DesiredCount = 0 }
        ResultPath = null
        Next       = "StopFastapi"
      }

      StopFastapi = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[1], DesiredCount = 0 }
        ResultPath = null
        Next       = "StopMlflow"
      }

      StopMlflow = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[2], DesiredCount = 0 }
        ResultPath = null
        Next       = "StopJudgeApi"
      }

      StopJudgeApi = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[3], DesiredCount = 0 }
        ResultPath = null
        Next       = "StopJudgeWorker"
      }

      StopJudgeWorker = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_application_services[4], DesiredCount = 0 }
        ResultPath = null
        Next       = "WaitForApplicationsToStop"
      }

      WaitForApplicationsToStop = {
        Type    = "Wait"
        Seconds = 60
        Next    = "DescribeApplicationsForStop"
      }

      DescribeApplicationsForStop = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:describeServices"
        Parameters = {
          Cluster  = local.stage_office_hours_cluster
          Services = local.stage_office_hours_application_services
        }
        Next = "AreApplicationsStopped"
      }

      AreApplicationsStopped = {
        Type = "Choice"
        Choices = [{
          And = [for index in range(length(local.stage_office_hours_application_services)) : {
            Variable      = "$.Services[${index}].RunningCount"
            NumericEquals = 0
          }]
          Next = "StopAiPostgres"
        }]
        Default = "WaitForApplicationsToStop"
      }

      StopAiPostgres = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_data_services[0], DesiredCount = 0 }
        ResultPath = null
        Next       = "StopJudgePostgres"
      }

      StopJudgePostgres = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:ecs:updateService"
        Parameters = { Cluster = local.stage_office_hours_cluster, Service = local.stage_office_hours_data_services[1], DesiredCount = 0 }
        ResultPath = null
        Next       = "WaitForDataServicesToStop"
      }

      WaitForDataServicesToStop = {
        Type    = "Wait"
        Seconds = 60
        Next    = "DescribeDataServicesForStop"
      }

      DescribeDataServicesForStop = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ecs:describeServices"
        Parameters = {
          Cluster  = local.stage_office_hours_cluster
          Services = local.stage_office_hours_data_services
        }
        Next = "AreDataServicesStopped"
      }

      AreDataServicesStopped = {
        Type = "Choice"
        Choices = [{
          And = [
            {
              Variable      = "$.Services[0].RunningCount"
              NumericEquals = 0
            },
            {
              Variable      = "$.Services[1].RunningCount"
              NumericEquals = 0
            },
          ]
          Next = "WaitForWorkerScaleIn"
        }]
        Default = "WaitForDataServicesToStop"
      }

      WaitForWorkerScaleIn = {
        Type    = "Wait"
        Seconds = 120
        Next    = "ScaleJudgeWorkerAsgToZero"
      }

      ScaleJudgeWorkerAsgToZero = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:autoscaling:setDesiredCapacity"
        Parameters = {
          AutoScalingGroupName = local.stage_office_hours_asg
          DesiredCapacity      = 0
          HonorCooldown        = false
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = null
          Next        = "StopStatefulEc2"
        }]
        Next = "StopStatefulEc2"
      }

      StopStatefulEc2 = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:ec2:stopInstances"
        Parameters = {
          InstanceIds = [data.aws_instances.stage_office_hours_stateful[0].ids[0]]
        }
        ResultPath = null
        Next       = "StopRds"
      }

      StopRds = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:rds:stopDBInstance"
        Parameters = {
          DbInstanceIdentifier = local.stage_office_hours_mysql
        }
        ResultPath = null
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = null
          Next        = "StopComplete"
        }]
        Next = "StopComplete"
      }

      StopComplete = {
        Type = "Succeed"
      }
    }
  })

  tags = { Name = "${local.name_prefix}-office-hours" }
}

data "aws_iam_policy_document" "stage_office_hours_scheduler_assume" {
  count = local.stage_office_hours_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "stage_office_hours_scheduler" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name               = "${local.name_prefix}-office-hours-scheduler"
  assume_role_policy = data.aws_iam_policy_document.stage_office_hours_scheduler_assume[0].json

  tags = { Name = "${local.name_prefix}-office-hours-scheduler" }
}

data "aws_iam_policy_document" "stage_office_hours_scheduler" {
  count = local.stage_office_hours_enabled ? 1 : 0

  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.stage_office_hours[0].arn]
  }
}

resource "aws_iam_role_policy" "stage_office_hours_scheduler" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name   = "${local.name_prefix}-office-hours-scheduler"
  role   = aws_iam_role.stage_office_hours_scheduler[0].id
  policy = data.aws_iam_policy_document.stage_office_hours_scheduler[0].json
}

resource "aws_scheduler_schedule" "stage_start" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name                         = "${local.name_prefix}-weekday-start"
  schedule_expression          = "cron(0 9 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Seoul"
  state                        = "ENABLED"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_sfn_state_machine.stage_office_hours[0].arn
    role_arn = aws_iam_role.stage_office_hours_scheduler[0].arn
    input    = jsonencode({ action = "start" })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}

resource "aws_scheduler_schedule" "stage_stop" {
  count = local.stage_office_hours_enabled ? 1 : 0

  name                         = "${local.name_prefix}-weekday-stop"
  schedule_expression          = "cron(0 23 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Seoul"
  state                        = "ENABLED"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_sfn_state_machine.stage_office_hours[0].arn
    role_arn = aws_iam_role.stage_office_hours_scheduler[0].arn
    input    = jsonencode({ action = "stop" })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}
