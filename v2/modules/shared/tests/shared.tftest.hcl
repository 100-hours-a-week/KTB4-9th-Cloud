mock_provider "aws" {
  override_resource {
    target = aws_acm_certificate.regional_wildcard
    values = {
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/regional-test"
      domain_validation_options = [
        {
          domain_name           = "*.cosmoscode.site"
          resource_record_name  = "_validation.cosmoscode.site."
          resource_record_type  = "CNAME"
          resource_record_value = "_validation.acm-validations.aws."
        }
      ]
    }
  }
}

run "공유_네트워크는_서울_2AZ와_단일_NAT를_사용한다" {
  command = apply

  assert {
    condition     = var.aws_region == "ap-northeast-2" && var.vpc_cidr == "10.20.0.0/16"
    error_message = "공유 VPC는 서울 리전의 10.20.0.0/16을 사용해야 합니다."
  }

  assert {
    condition     = var.availability_zones == tolist(["ap-northeast-2a", "ap-northeast-2c"])
    error_message = "공유 네트워크는 ap-northeast-2a/c 두 AZ를 사용해야 합니다."
  }

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2 && length(aws_subnet.data) == 2
    error_message = "Public, Private, Data subnet은 각각 2개여야 합니다."
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 1
    error_message = "NAT Gateway는 정확히 1개여야 합니다."
  }

  assert {
    condition     = length(aws_route.private_default) == 2 && alltrue([for route in aws_route.private_default : route.nat_gateway_id == aws_nat_gateway.main[0].id])
    error_message = "두 Private 기본 route는 같은 NAT Gateway를 사용해야 합니다."
  }

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && length(aws_vpc_endpoint.s3.route_table_ids) == 2
    error_message = "S3 Gateway Endpoint는 두 Private route table에 연결되어야 합니다."
  }
}

run "공유_ECR은_환경명_없이_세_개를_보호한다" {
  command = plan

  assert {
    condition = toset([for repository in aws_ecr_repository.service : repository.name]) == toset([
      "cosmos-v2/spring",
      "cosmos-v2/fastapi",
      "cosmos-v2/judge",
    ])
    error_message = "공유 ECR repository 3개가 설계된 이름으로 생성되어야 합니다."
  }

  assert {
    condition = alltrue([
      for repository in aws_ecr_repository.service :
      repository.image_tag_mutability == "IMMUTABLE" &&
      repository.image_scanning_configuration[0].scan_on_push &&
      repository.encryption_configuration[0].encryption_type == "AES256" &&
      !strcontains(repository.name, "stage") &&
      !strcontains(repository.name, "prod")
    ])
    error_message = "ECR은 immutable/scan/AES256을 사용하고 환경명을 포함하지 않아야 합니다."
  }
}

run "GitHub_Stage_CI는_저장소별_ECR만_push한다" {
  command = plan

  assert {
    condition = (
      aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" &&
      toset(aws_iam_openid_connect_provider.github.client_id_list) == toset(["sts.amazonaws.com"])
    )
    error_message = "GitHub Actions OIDC provider는 공식 issuer와 STS audience만 신뢰해야 합니다."
  }

  assert {
    condition = (
      toset(keys(aws_iam_role.github_stage_ci)) == toset(["spring", "fastapi", "judge"]) &&
      toset(keys(aws_iam_role_policy.github_stage_ecr)) == toset(["spring", "fastapi", "judge"])
    )
    error_message = "Stage CI role과 policy는 Spring, FastAPI, Judge에 각각 하나씩 필요합니다."
  }

  assert {
    condition = (
      strcontains(aws_iam_role.github_stage_ci["spring"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-BE@1344700709:environment:staging-ci") &&
      strcontains(aws_iam_role.github_stage_ci["fastapi"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-AI@1344703221:environment:staging-ci") &&
      strcontains(aws_iam_role.github_stage_ci["judge"].assume_role_policy, "repo:100-hours-a-week@167328634/KTB4-9th-Judge@1374079744:environment:staging-ci")
    )
    error_message = "각 CI role은 immutable 조직/저장소 ID와 staging-ci environment가 포함된 GitHub OIDC subject만 신뢰해야 합니다."
  }

  assert {
    condition = alltrue([
      for service, policy in aws_iam_role_policy.github_stage_ecr :
      strcontains(policy.policy, aws_ecr_repository.service[service].arn) &&
      strcontains(policy.policy, "ecr:GetAuthorizationToken") &&
      strcontains(policy.policy, "ecr:PutImage")
    ])
    error_message = "각 CI policy는 인증과 대응 ECR image push 권한을 제공해야 합니다."
  }

  assert {
    condition     = toset(keys(output.github_stage_ci_role_arns)) == toset(["spring", "fastapi", "judge"])
    error_message = "Shared output은 세 GitHub Stage CI role ARN을 제공해야 합니다."
  }

  assert {
    condition     = output.github_oidc_provider_arn == aws_iam_openid_connect_provider.github.arn
    error_message = "Shared output은 stage CD role trust에 사용할 GitHub OIDC provider ARN을 제공해야 합니다."
  }
}

run "Terraform_plan_role은_관리_리소스만_읽는다" {
  command = plan

  assert {
    condition = (
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformLambda"
        ]).Action, []) == [
        "lambda:GetFunction",
        "lambda:GetPolicy",
        "lambda:ListTags",
        "lambda:ListVersionsByFunction",
      ] &&
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformLambda"
      ]).Resource, null) == "arn:aws:lambda:ap-northeast-2:*:function:cosmos-v2-stage-*"
    )
    error_message = "Terraform plan role은 stage Lambda의 상태만 읽어야 합니다."
  }

  assert {
    condition = (
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformStateMachine"
        ]).Action, []) == [
        "states:DescribeStateMachine",
        "states:ListTagsForResource",
      ] &&
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformStateMachine"
      ]).Resource, null) == "arn:aws:states:ap-northeast-2:*:stateMachine:cosmos-v2-stage-*"
    )
    error_message = "Terraform plan role은 stage Step Functions 상태만 읽어야 합니다."
  }

  assert {
    condition = (
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformScheduler"
      ]).Action, []) == ["scheduler:GetSchedule"] &&
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformScheduler"
      ]).Resource, null) == "arn:aws:scheduler:ap-northeast-2:*:schedule/default/cosmos-v2-stage-*"
    )
    error_message = "Terraform plan role은 stage office-hours schedule만 읽어야 합니다."
  }

  assert {
    condition = (
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformMonitoringSecret"
      ]).Action, []) == ["secretsmanager:GetSecretValue"] &&
      try(one([
        for statement in jsondecode(aws_iam_role_policy.github_terraform_plan.policy).Statement : statement
        if statement.Sid == "ReadTerraformMonitoringSecret"
      ]).Resource, null) == "arn:aws:secretsmanager:ap-northeast-2:*:secret:/cosmos-v2/monitoring/grafana-admin-*"
    )
    error_message = "Terraform plan role은 Grafana 관리자 Secret 값만 읽어야 합니다."
  }
}

run "가용_영역이_두_개가_아니면_거부한다" {
  command = plan

  variables {
    availability_zones = ["ap-northeast-2a"]
  }

  expect_failures = [var.availability_zones]
}

run "subnet_CIDR_개수가_두_개가_아니면_거부한다" {
  command = plan

  variables {
    data_subnet_cidrs = ["10.20.20.0/24"]
  }

  expect_failures = [var.data_subnet_cidrs]
}

run "공유_output은_환경_계층에_필요한_식별자를_제공한다" {
  command = plan

  assert {
    condition = (
      length(output.public_subnet_ids) == 2 &&
      length(output.private_subnet_ids) == 2 &&
      length(output.data_subnet_ids) == 2 &&
      length(output.ecr_repository_urls) == 3 &&
      length(output.ecr_repository_arns) == 3
    )
    error_message = "공유 output은 2AZ subnet map과 ECR 3개 map을 제공해야 합니다."
  }
}

run "서울_wildcard_인증서는_기존_DNS_검증값을_재사용한다" {
  command = plan

  assert {
    condition = (
      var.domain_name == "cosmoscode.site" &&
      aws_acm_certificate.regional_wildcard.domain_name == "*.cosmoscode.site" &&
      aws_acm_certificate.regional_wildcard.validation_method == "DNS" &&
      aws_acm_certificate_validation.regional_wildcard.certificate_arn == aws_acm_certificate.regional_wildcard.arn &&
      output.regional_wildcard_certificate_arn == aws_acm_certificate.regional_wildcard.arn
    )
    error_message = "Shared 모듈은 서울 리전 wildcard ACM 인증서와 validation waiter ARN을 제공해야 합니다."
  }
}

run "잘못된_domain_name은_거부한다" {
  command = plan

  variables {
    domain_name = "cosmoscode.site."
  }

  expect_failures = [var.domain_name]
}
