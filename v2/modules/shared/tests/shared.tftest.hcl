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
