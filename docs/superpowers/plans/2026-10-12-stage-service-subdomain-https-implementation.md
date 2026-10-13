# Stage 서비스 서브도메인 HTTPS 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage의 Spring Boot, FastAPI, Judge API를 각각 `stage-be`, `stage-ai`, `stage-judge` HTTPS 서브도메인으로 공개하되 Prod의 외부 공개 구조는 변경하지 않는다.

**Architecture:** Shared 모듈이 서울 리전 wildcard ACM 인증서를 발급하고 ARN을 remote state로 전달한다. Environment 모듈은 Stage에만 ALB HTTPS Listener, Host 기반 Rule, 서비스별 Target Group, Route 53 Alias와 SG 규칙을 만들며 기존 Spring HTTP Target Group/Rule의 Terraform 주소는 유지해 상태 교체 위험을 줄인다.

**Tech Stack:** Terraform 1.16.x, AWS Provider 5.100.0, ACM, ALB, ECS Fargate, Route 53, HCP Terraform remote state

**Spec:** `docs/superpowers/specs/2026-10-12-stage-service-subdomain-https-design.md`

## Global Constraints

- 리전은 `ap-northeast-2`, Public Hosted Zone은 `cosmoscode.site`/`Z09263573OIZVBLYL9OX7`를 사용한다.
- Stage 서비스 주소는 `stage-be.cosmoscode.site`, `stage-ai.cosmoscode.site`, `stage-judge.cosmoscode.site`다.
- Stage ALB `443/tcp`는 테스트 기간에 한해 `0.0.0.0/0`에 공개하고 IPv6 `::/0`는 추가하지 않는다.
- TLS 정책은 `ELBSecurityPolicy-TLS13-1-2-2021-06`, Listener 기본 동작은 fixed `404`다.
- 기존 ALB HTTP `80` Listener와 CloudFront origin 전용 접근은 유지하며 HTTP redirect는 추가하지 않는다.
- Host Rule priority는 Spring `100`, FastAPI `110`, Judge API `120`이다.
- 포트/health path는 Spring `8080`/`/actuator/health`, FastAPI `8000`/`/health`, Judge API `2358`/`/`다.
- Prod에는 Stage Host Rule과 Stage 서비스 DNS를 생성하지 않고, Prod FastAPI/Judge API는 ALB에 연결하지 않는다.
- 기존 ACM DNS validation CNAME은 Terraform 소유로 가져오거나 삭제하지 않는다.
- ECS 애플리케이션 container-level `curl` health check는 제거하고 ALB health와 deployment circuit breaker를 사용한다.
- 기존 `aws_lb_target_group.spring`, `aws_lb_listener_rule.spring`, `aws_vpc_security_group_ingress_rule.spring_from_alb` 주소를 유지한다.
- 사용자가 직접 커밋하므로 이 계획을 실행하는 동안 commit/push/PR 생성은 하지 않는다.

## Review Focus

- Shared 인증서 ARN이 서울 리전 ARN이 아니면 Environment 입력 검증이 실패해야 한다.
- `enable_phase2_services = false`에서도 Stage HTTPS Listener와 DNS는 존재할 수 있지만 ECS Service와 Host forwarding Rule은 생성되지 않아 기본 `404`를 반환해야 한다.
- Stage에서만 세 ECS Service가 각각 정확히 하나의 Target Group에 연결되고, Prod에서는 Spring만 연결되어야 한다.
- 알 수 없는 Host header는 HTTPS Listener의 fixed `404`로 종료되어 다른 서비스로 잘못 전달되지 않아야 한다.
- Judge API 포트 `2358`과 health path `/`가 변수, SG, Target Group, ECS Service 전 구간에서 일치해야 한다.

---

### Task 1: 서울 리전 wildcard ACM 인증서와 Shared output

**Files:**
- Create: `v2/modules/shared/acm.tf`
- Modify: `v2/modules/shared/variables.tf`
- Modify: `v2/modules/shared/outputs.tf`
- Modify: `v2/modules/shared/tests/shared.tftest.hcl`
- Modify: `v2/environments/shared/outputs.tf`

**Interfaces:**
- Consumes: Shared 모듈 기본 AWS provider(`ap-northeast-2`)와 새 변수 `domain_name`(기본값 `cosmoscode.site`).
- Produces: `module.shared.regional_wildcard_certificate_arn` 및 Shared root output `regional_wildcard_certificate_arn` (`string`).

- [ ] **Step 1: Shared 모듈 테스트에 인증서 계약을 추가한다**

  `shared.tftest.hcl`에서 인증서 domain이 `*.cosmoscode.site`, validation method가 `DNS`, validation 리소스가 존재하며 output ARN이 인증서 ARN과 같은지 검증한다. Route 53 validation record 리소스를 추가하지 않는 것은 구현 diff 검토에서 확인한다.

- [ ] **Step 2: 테스트를 실행해 실패를 확인한다**

  Run: `terraform -chdir=v2/modules/shared test -filter=tests/shared.tftest.hcl`

  Expected: FAIL because `aws_acm_certificate.regional_wildcard`, validation resource, output이 아직 없다.

- [ ] **Step 3: Shared domain 변수를 추가한다**

  `domain_name`을 string 변수로 추가하고 기본값을 `cosmoscode.site`로 고정하며 공백이나 trailing dot이 있는 값은 validation으로 거부한다.

- [ ] **Step 4: Shared 모듈에 인증서와 validation waiter를 구현한다**

  `aws_acm_certificate.regional_wildcard`는 `domain_name = "*.${var.domain_name}"`, `validation_method = "DNS"`, `create_before_destroy = true`를 사용한다. `aws_acm_certificate_validation.regional_wildcard`는 인증서 ARN과 `domain_validation_options`의 validation record FQDN을 소비하되 `aws_route53_record`는 만들지 않는다.

- [ ] **Step 5: Shared root output으로 ARN을 전달한다**

  모듈 output과 `v2/environments/shared/outputs.tf`의 동명 output을 연결한다.

- [ ] **Step 6: Shared 모듈 테스트를 다시 실행한다**

  Run: `terraform -chdir=v2/modules/shared test -filter=tests/shared.tftest.hcl`

  Expected: PASS, 기존 네트워크/ECR assertions도 함께 통과.

### Task 2: Shared remote-state 계약과 인증서 입력 검증

**Files:**
- Modify: `v2/environments/stage/main.tf`
- Modify: `v2/environments/prod/main.tf`
- Modify: `v2/modules/environment/variables.tf`
- Modify: `v2/modules/environment/tests/environment.tftest.hcl`
- Modify: `v2/modules/environment/tests/foundation.tftest.hcl`
- Modify: `v2/modules/environment/tests/frontend.tftest.hcl`
- Modify: `v2/modules/environment/tests/phase-2-data.tftest.hcl`
- Modify: `v2/modules/environment/tests/phase-2-fargate.tftest.hcl`
- Modify: `v2/modules/environment/tests/phase-2-stateful.tftest.hcl`
- Modify: `v2/modules/environment/tests/phase-2-worker.tftest.hcl`

**Interfaces:**
- Consumes: Task 1의 Shared output `regional_wildcard_certificate_arn`.
- Produces: Environment module required variable `regional_wildcard_certificate_arn` with `ap-northeast-2` ACM ARN validation.

- [ ] **Step 1: Environment 변수 검증 테스트를 추가한다**

  모든 기존 module test fixture에 유효한 서울 리전 ACM ARN을 추가하고, `environment.tftest.hcl`에는 `us-east-1` ARN이 `var.regional_wildcard_certificate_arn`에서 거부되는 실패 테스트를 추가한다.

- [ ] **Step 2: 테스트를 실행해 실패를 확인한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/environment.tftest.hcl`

  Expected: FAIL because 입력 변수가 아직 정의되지 않았다.

- [ ] **Step 3: Environment 인증서 변수를 구현한다**

  `regional_wildcard_certificate_arn`을 required string으로 추가하고 `^arn:aws:acm:ap-northeast-2:[0-9]{12}:certificate/` 정규식으로 검증한다.

- [ ] **Step 4: Stage/Prod remote-state 계약과 module 인자를 연결한다**

  두 root의 `shared_output_contract`에 서울 리전 인증서 ARN 형식 검사를 추가하고 `module.environment.regional_wildcard_certificate_arn`으로 전달한다.

- [ ] **Step 5: Environment 기본 계약 테스트를 실행한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/environment.tftest.hcl`

  Expected: PASS, 서울 리전 ARN은 허용되고 타 리전 ARN은 validation failure로 처리.

### Task 3: Stage HTTPS Listener와 Host 기반 Target Group 라우팅

**Files:**
- Modify: `v2/modules/environment/locals.tf`
- Modify: `v2/modules/environment/alb.tf`
- Modify: `v2/modules/environment/tests/phase-2-fargate.tftest.hcl`

**Interfaces:**
- Consumes: `var.environment`, `var.enable_phase2_services`, `var.regional_wildcard_certificate_arn`, `local.application_services`.
- Produces: `aws_lb_listener.https`(Stage count 1), `aws_lb_target_group.stage_service`(Stage FastAPI/Judge map), `aws_lb_listener_rule.stage_service`(활성화된 Stage 세 서비스 map).

- [ ] **Step 1: Stage/Prod ALB 행위 테스트를 추가한다**

  Stage run은 HTTPS `443`, TLS policy, 인증서, fixed `404`, 세 Host/priority, 세 Target Group health 계약을 검증한다. 비활성 Stage run은 Host Rule이 0개임을, Prod run은 HTTPS Listener·Stage TG·Stage Rule이 0개이고 기존 Spring TG만 유지됨을 검증한다.

- [ ] **Step 2: Fargate 테스트를 실행해 실패를 확인한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-fargate.tftest.hcl`

  Expected: FAIL because Stage HTTPS/TG/Rule 리소스가 아직 없다.

- [ ] **Step 3: Stage 공개 서비스 locals를 정의한다**

  Host, priority, health path를 포함한 Stage 전용 service map을 만들고 Judge `health_path`를 `/`로 고친다. 기존 Spring TG 주소는 이 map으로 이동하지 않는다.

- [ ] **Step 4: Stage HTTPS Listener와 추가 Target Group을 구현한다**

  Stage에만 HTTPS Listener를 만들고 FastAPI/Judge Target Group만 `aws_lb_target_group.stage_service`로 추가한다. 기존 `aws_lb_target_group.spring`의 설정과 주소는 유지한다.

- [ ] **Step 5: 활성 Stage Host Rule을 구현한다**

  `enable_phase2_services`가 true인 Stage에서만 세 Rule을 생성하며 Spring은 기존 TG, 나머지는 Stage TG로 전달한다. Host 불일치는 Listener default fixed `404`로 남긴다.

- [ ] **Step 6: Fargate 테스트를 다시 실행한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-fargate.tftest.hcl`

  Expected: PASS for Stage enabled/disabled and Prod isolation assertions.

### Task 4: 443/서비스 SG와 ECS Target Group 연결

**Files:**
- Modify: `v2/modules/environment/security.tf`
- Modify: `v2/modules/environment/application-security.tf`
- Modify: `v2/modules/environment/ecs-services.tf`
- Modify: `v2/modules/environment/ecs-task-definitions.tf`
- Modify: `v2/modules/environment/variables.tf`
- Modify: `v2/modules/environment/tests/phase-2-fargate.tftest.hcl`

**Interfaces:**
- Consumes: Task 3의 Stage Target Group map과 Listener Rule, `local.application_services`.
- Produces: Stage public `443` ingress, ALB→FastAPI/Judge ingress, Stage의 서비스별 ECS `load_balancer` attachment; Judge port default `2358`.

- [ ] **Step 1: 네트워크와 ECS 연결 테스트를 추가한다**

  Stage는 ALB `443` IPv4 public ingress를 정확히 하나 갖고 세 ECS Service가 각각 하나의 올바른 TG/port에 연결되는지 검증한다. Prod는 public `443` ingress가 없고 Spring만 TG에 연결되는지, Judge 관련 SG/ECS port가 모두 `2358`인지 검증한다.

- [ ] **Step 2: container health check 제거 테스트를 추가한다**

  세 application task definition의 decoded `container_definitions`에 `healthCheck` key가 없음을 검증한다.

- [ ] **Step 3: 테스트를 실행해 실패를 확인한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-fargate.tftest.hcl`

  Expected: FAIL on public 443, FastAPI/Judge attachment, Judge port, container health assertions.

- [ ] **Step 4: Security Group 규칙을 구현한다**

  Stage ALB에만 `0.0.0.0/0:443`을 허용한다. 기존 `spring_from_alb`는 보존하고 Stage에서만 ALB→FastAPI `8000`, ALB→Judge `2358`을 추가하며 내부 서비스 간 ingress는 유지한다.

- [ ] **Step 5: ECS 서비스별 Target Group 연결을 구현한다**

  Stage에서는 세 Service, Prod에서는 Spring만 `load_balancer` block을 갖게 한다. dependency에는 각 TG가 Listener Rule과 연결된 이후 ECS Service가 생성되도록 HTTP/HTTPS Rule을 포함한다.

- [ ] **Step 6: Judge 포트와 task health 계약을 수정한다**

  `judge_api_container_port` 기본값을 `2358`로 바꾸고 애플리케이션 공통 `curl` 기반 `healthCheck` block을 제거한다.

- [ ] **Step 7: Fargate 테스트를 다시 실행한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-fargate.tftest.hcl`

  Expected: PASS, Stage 세 서비스와 Prod Spring-only 계약이 모두 유지.

### Task 5: Stage Route 53 Alias와 공개 URL output

**Files:**
- Modify: `v2/modules/environment/locals.tf`
- Modify: `v2/modules/environment/route53.tf`
- Modify: `v2/modules/environment/outputs.tf`
- Modify: `v2/modules/environment/tests/frontend.tftest.hcl`
- Modify: `v2/environments/stage/outputs.tf`
- Modify: `v2/environments/prod/outputs.tf`

**Interfaces:**
- Consumes: Stage service hostname map, `aws_lb.main.dns_name`, `aws_lb.main.zone_id`.
- Produces: `aws_route53_record.stage_service` and output `stage_service_urls` (`map(string)`; Stage 3개, Prod 빈 map).

- [ ] **Step 1: DNS와 output 테스트를 추가한다**

  Stage run은 세 A Alias 이름, ALB DNS/zone 대상, `evaluate_target_health = true`, 세 HTTPS base URL을 검증한다. Prod run은 Stage service record가 0개이고 output이 빈 map인지 검증한다.

- [ ] **Step 2: Frontend 테스트를 실행해 실패를 확인한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/frontend.tftest.hcl`

  Expected: FAIL because Stage service records/output이 아직 없다.

- [ ] **Step 3: Stage 서비스 Alias를 구현한다**

  Stage에서만 세 `A` Alias를 동일 ALB로 만들고 기존 `aws_route53_record.frontend`는 변경하지 않는다.

- [ ] **Step 4: Module 및 root output을 구현한다**

  Environment output은 Stage URL map, Prod 빈 map을 반환하고 Stage/Prod root가 동명 output을 전달한다.

- [ ] **Step 5: Frontend 테스트를 다시 실행한다**

  Run: `terraform -chdir=v2/modules/environment test -filter=tests/frontend.tftest.hcl`

  Expected: PASS, 기존 CloudFront alias 테스트도 회귀 없이 통과.

### Task 6: Stage 적용 문서와 전체 정적 검증

**Files:**
- Modify: `v2/stage-operations.md`
- Modify: `v2/architecture.md`
- Test: `v2/tests/layout_test.sh`
- Test: `v2/tests/preflight_test.sh`

**Interfaces:**
- Consumes: Tasks 1–5의 리소스 및 output 계약.
- Produces: Shared→Stage 적용 순서, 고정 image digest, Swagger smoke URL과 실패 시 점검 순서를 담은 한국어 운영 절차.

- [ ] **Step 1: 운영 문서를 갱신한다**

  Shared apply로 인증서 발급을 먼저 완료한 뒤 Stage plan/apply하는 순서, 세 digest 변수, `enable_phase2_services`, 세 Swagger URL, ALB target health/CloudWatch Logs 점검 방법을 기록한다. 인터넷 공개 `443`이 임시 정책임을 명시한다.

- [ ] **Step 2: Terraform formatting을 적용한다**

  Run: `terraform fmt -recursive v2`

  Expected: exit 0.

- [ ] **Step 3: 모든 module test를 실행한다**

  Run: `terraform -chdir=v2/modules/shared test`

  Expected: 모든 Shared test PASS.

  Run: `terraform -chdir=v2/modules/environment test`

  Expected: 모든 Environment test PASS.

- [ ] **Step 4: repository shell 검증을 실행한다**

  Run: `bash v2/tests/layout_test.sh`

  Expected: PASS.

  Run: `bash v2/tests/preflight_test.sh`

  Expected: PASS.

- [ ] **Step 5: 변경 범위와 상태 주소를 검토한다**

  Run: `git diff --check && git diff -- v2 docs/superpowers/specs/2026-10-12-stage-service-subdomain-https-design.md docs/superpowers/plans/2026-10-12-stage-service-subdomain-https-implementation.md`

  Expected: whitespace error 없음; 기존 Spring TG/HTTP Rule/SG resource 주소가 유지되고 사용자 소유 변경이 덮어써지지 않음.

- [ ] **Step 6: HCP Terraform plan은 사용자가 자격 증명을 설정한 뒤 실행한다**

  Run: `terraform -chdir=v2/environments/shared plan`

  Expected: 서울 wildcard ACM 인증서/validation 및 output 변경만 포함하고 기존 validation CNAME 삭제가 없음.

  Run: `terraform -chdir=v2/environments/stage plan -var='enable_phase2_services=true' -var='spring_image_digest=sha256:d2e85f1fb9eeaa8f367dd79fd78f0731cba3618b0d09e1573eaa5f913a2575f9' -var='fastapi_image_digest=sha256:6f763b65c0e0ae84eeb36572ded74a9e39a97ee3ce535f41c9b7bcdf5dcaa861' -var='judge_image_digest=sha256:e44c0adc000802b40bffc82043d922b934294e5d147fb86dc220ef195e99416b'`

  Expected: Stage HTTPS Listener, 두 추가 TG, 세 Host Rule, 세 DNS Alias, SG/ECS 연결이 생성되고 Prod 리소스 변경은 없음.
