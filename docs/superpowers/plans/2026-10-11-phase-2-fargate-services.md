# COSMOS v2 2차 Fargate 애플리케이션 Implementation Plan

> **에이전트 작업자 필수 사항:** 이 계획은 `superpowers:subagent-driven-development`(권장) 또는 `superpowers:executing-plans`를 사용해 작업별로 구현한다. 진행 상태는 체크박스(`- [ ]`)로 추적한다.

**목표:** Spring Boot, FastAPI, Judge API를 private Fargate Service로 배포하고 Service Connect 내부 통신과 Spring 전용 Public ALB 진입점을 완성한다.

**아키텍처:** 세 서비스는 image digest와 서비스별 IAM/Secret을 사용하는 Fargate Task로 실행된다. Spring만 Target Group에 등록하고 FastAPI/Judge API는 Service Connect에서만 접근한다. 안전한 bootstrap을 위해 기본값에서는 Service 생성을 비활성화하고, 사전 검증 통과 후 명시적으로 활성화한다.

**기술 스택:** Terraform, ECS Fargate, Service Connect, Cloud Map, ALB, ECR, Secrets Manager, IAM, CloudWatch Logs, Bash/AWS CLI preflight

**설계:** `v2/phase-2-architecture.md`

**선행 계획:** 데이터 기반 계획과 상태 저장 ECS on EC2 계획

**구현 상태 (2026-10-11):** Task 1~7 소스 구현 및 native test 완료. Task 8 실제 state/plan/apply/smoke test는 Terraform Cloud/AWS 인증과 image digest, Secret version, 애플리케이션 확인 항목이 필요해 미수행.

## 전체 제약 조건

- Spring만 ALB를 통해 외부에 공개한다.
- FastAPI와 Judge API에는 Target Group, public IP, public CIDR ingress를 만들지 않는다.
- Desired count는 각 1개, FARGATE only, Auto Scaling/Fargate Spot은 제외한다.
- Port/health는 Spring 8080 `/actuator/health`, FastAPI 8000 `/health`, Judge API 3000 `/health`다.
- 모든 이미지는 private ECR digest로 고정한다.
- Secret value는 Terraform에 저장하지 않는다.
- `enable_phase2_services=false`를 안전한 기본값으로 사용하며 preflight 통과 후에만 true로 변경한다.
- Secret JSON key 계약은 Spring `db_username`/`db_password`, PostgreSQL `username`/`password`/`database`, Redis `password`다. FastAPI와 Judge API의 서비스 자체 Secret은 전체 JSON을 각각 `FASTAPI_SECRET_JSON`, `JUDGE_API_SECRET_JSON`으로 주입한다.
- 커밋은 생성하지 않는다.

## 중점 검토 항목

- Bootstrap 미완료: digest 또는 Secret version이 없으면 preflight가 실패하고 Service 활성화가 금지되어야 한다.
- 내부 서비스 외부 노출: FastAPI/Judge API에 ALB 연결 또는 public IP가 생기면 테스트가 실패해야 한다.
- Service Connect 오배선: Spring→FastAPI/Judge, FastAPI→Judge 호출 이름과 port가 정확해야 한다.
- Desired count 1 배포 중단: rolling 설정은 100/200이고 circuit breaker rollback이 활성화되어야 한다.
- ALB 조기 전환: 서비스 비활성 상태에서는 기존 fixed 404가 유지되어야 한다.

---

## 파일 구성

| 파일 | 책임 |
| --- | --- |
| `v2/application-iam.tf` | 서비스별 execution/task role |
| `v2/ecs-task-definitions.tf` | 세 Fargate Task Definition |
| `v2/ecs-services.tf` | 세 Fargate Service와 Service Connect |
| `v2/alb.tf` | Spring Target Group과 조건부 listener rule |
| `v2/variables.tf`, `v2/locals.tf` | port, capacity, digest, enable flag, service map |
| `v2/scripts/preflight.sh` | ECR digest, Secret version, TFC state 선행 검사 |
| `v2/outputs.tf` | Service/Task/IAM/Target Group output |
| `v2/tests/phase-2-fargate.tftest.hcl` | Mocked Fargate 계약 테스트 |
| `v2/tests/preflight_test.sh` | fake AWS/Terraform command를 사용하는 script test |

### Task 1: 애플리케이션 변수와 안전한 bootstrap

**파일:**

- 수정: `v2/variables.tf`, `v2/locals.tf`
- 생성: `v2/tests/phase-2-fargate.tftest.hcl`

**인터페이스:**

- 입력: port/CPU/memory/digest, `application_desired_count`, `enable_phase2_services`
- 출력: `local.application_services`, 활성화 시에만 채워지는 `local.enabled_application_services`

- [ ] **1단계: 실패 테스트 작성**

기본 port와 CPU/memory, desired count 1, enable flag false를 검증한다. enable=true일 때 모든 digest가 `sha256:` + 64 lowercase hex가 아니면 validation 또는 precondition이 실패하는 run을 추가한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: 신규 변수/local이 없어 실패한다.

- [ ] **3단계: 변수/local 구현**

세 서비스의 repository key, container name, port, health path, CPU/memory, Service Connect role을 map으로 정의한다. Application digest 기본값은 null이며 enable=false일 때만 허용한다. enable=true이면 Spring/FastAPI/Judge API digest 3개가 모두 유효해야 한다. 상태 저장 digest는 선행 계획의 별도 enable flag가 검증한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: bootstrap과 validation run이 통과한다.

### Task 2: 서비스별 IAM

**파일:**

- 수정: `v2/application-iam.tf`, `v2/tests/phase-2-fargate.tftest.hcl`

**인터페이스:**

- 입력: 서비스별 Secret ARN, Valkey cache/user ARN
- 출력: `aws_iam_role.application_execution`, `aws_iam_role.application_task` keyed maps

- [ ] **1단계: 실패 테스트 작성**

모든 execution role이 AWS task execution policy를 갖는지 검증한다. Spring은 Spring Secret, FastAPI는 FastAPI Secret, Judge API는 Judge API·PostgreSQL·Redis Secret만 읽어야 한다. 모든 task role은 ECS Exec `ssmmessages` 권한을 갖고, Spring만 Valkey cache/user에 `elasticache:Connect`를 갖는지 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: application IAM 리소스가 없어 실패한다.

- [ ] **3단계: IAM 구현**

Trust principal은 `ecs-tasks.amazonaws.com`만 사용한다. Inline policy는 resource ARN을 구체적으로 제한하고 wildcard Secrets Manager 권한을 금지한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: 서비스별 최소 권한 테스트가 통과한다.

### Task 3: Fargate Task Definition

**파일:**

- 생성: `v2/ecs-task-definitions.tf`
- 수정: `v2/tests/phase-2-fargate.tftest.hcl`

**인터페이스:**

- 입력: application service map, ECR URL/digest, IAM ARN, Secret ARN, RDS/Valkey endpoint
- 출력: `aws_ecs_task_definition.application`

- [ ] **1단계: 실패 테스트 작성**

FARGATE/awsvpc/X86_64, CPU/memory, URL@digest, named port, HTTP appProtocol, health command, readonly root, writable `/tmp`, awslogs, service별 role ARN과 environment endpoint를 JSON decode해 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: application Task Definition이 없어 실패한다.

- [ ] **3단계: Task Definition 구현**

Spring 환경에는 FastAPI/Judge Service Connect URL, RDS host/port, Valkey endpoint/port를 제공하고 Spring Secret의 `db_username`/`db_password`를 `SPRING_DATASOURCE_USERNAME`/`SPRING_DATASOURCE_PASSWORD`로 주입한다. FastAPI에는 Judge URL과 `FASTAPI_SECRET_JSON`, Judge API에는 PostgreSQL/Redis Service Connect host/port, `JUDGE_API_SECRET_JSON`, PostgreSQL `username`/`password`/`database`, Redis `password`를 주입한다. Secret은 ARN 또는 ARN의 JSON key reference만 사용한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: 세 container definition 계약이 통과한다.

### Task 4: Fargate Service와 Service Connect

**파일:**

- 생성: `v2/ecs-services.tf`
- 수정: `v2/tests/phase-2-fargate.tftest.hcl`

**인터페이스:**

- 입력: Task Definition, namespace, private subnet, service SG
- 출력: `aws_ecs_service.application`

- [ ] **1단계: 실패 테스트 작성**

Enable=false일 때 Service 0개, enable=true mocked run에서 3개인지 검증한다. FARGATE strategy, desired 1, private subnet 2개, public IP false, 100/200 rolling, circuit breaker rollback, ECS Exec을 검증한다. Spring은 client, FastAPI/Judge는 client-server alias를 갖는지 확인한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: Fargate ECS Service가 없어 실패한다.

- [ ] **3단계: Service 구현**

`local.enabled_application_services`로 조건부 생성한다. FastAPI alias `fastapi:8000`, Judge alias `judge-api:3000`을 정의하고 Spring은 namespace client 설정만 사용한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: 내부 topology와 외부 비노출 검증이 통과한다.

### Task 5: Spring Target Group과 안전한 ALB 전환

**파일:**

- 수정: `v2/alb.tf`, `v2/ecs-services.tf`, `v2/tests/phase-2-fargate.tftest.hcl`

**인터페이스:**

- 입력: Spring ECS Service와 SG, existing HTTP listener
- 출력: `aws_lb_target_group.spring`, 조건부 `aws_lb_listener_rule.spring`, Spring service load_balancer block

- [ ] **1단계: 실패 테스트 작성**

Target type ip, HTTP 8080, `/actuator/health`, matcher 200, deregistration 30초, stickiness off를 검증한다. Spring만 load balancer block을 가지며 enable=false이면 listener rule이 0개이고 기존 fixed 404가 유지되는지 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: Spring Target Group/rule이 없어 실패한다.

- [ ] **3단계: ALB 연결 구현**

Target Group은 항상 만들고 listener 기본 404는 유지한다. enable=true일 때만 우선순위 100, path `/*` listener rule을 생성해 Spring으로 forward한다. Spring ECS Service만 Target Group에 연결한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: 비활성 안전 상태와 활성 Spring-only 노출이 모두 통과한다.

### Task 6: 배포 사전 검증 script

**파일:**

- 생성: `v2/scripts/preflight.sh`, `v2/tests/preflight_test.sh`

**인터페이스:**

- 입력: AWS CLI profile/region, Terraform binary, 다섯 repository/digest, 다섯 Secret ARN, health/Valkey IAM/MySQL bootstrap 검증 attestation
- 출력: 성공 시 exit 0, 누락/잘못된 workspace/state 시 비제로 종료

- [ ] **1단계: shell 실패 테스트 작성**

`AWS_BIN`과 `TERRAFORM_BIN`을 임시 fake executable로 주입해 digest 누락, Secret에 `AWSCURRENT` version 없음, Terraform Cloud 인증 실패, state의 v1 전용 주소 검출, `HEALTH_ENDPOINTS_VERIFIED`/`VALKEY_IAM_AUTH_VERIFIED`/`MYSQL_BOOTSTRAP_VERIFIED` attestation 누락이 각각 비제로 끝나는지 검증한다. v1 전용 금지 pattern은 `aws_instance.main_server`, `aws_instance.judge_server`, `aws_cloudfront_distribution.frontend_cdn`, `aws_route53_zone.main`이다. 모든 조건 정상 fixture는 0이어야 한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `bash v2/tests/preflight_test.sh`

기대 결과: `preflight.sh`가 없어 실패한다.

- [ ] **3단계: preflight 구현**

Strict mode를 사용하고 secret 값을 출력하지 않는다. `ecr describe-images`, `secretsmanager list-secret-version-ids`, `terraform state list`만 사용한다. 세 attestation 환경 변수가 모두 문자열 `true`인지 확인한다. Workspace/state를 읽을 수 없거나 위 v1 전용 주소가 발견되면 실패하며 `terraform apply` 자체는 호출하지 않는다.

- [ ] **4단계: 검증**

실행: `bash -n v2/scripts/preflight.sh && bash v2/tests/preflight_test.sh`

기대 결과: 모든 성공/실패 fixture가 통과한다.

### Task 7: Output과 전체 오프라인 검증

**파일:**

- 수정: `v2/outputs.tf`, `v2/tests/phase-2-fargate.tftest.hcl`

**인터페이스:**

- 입력: Task Definition, Service, IAM, Target Group resources
- 출력: 서비스별 ARN/name map과 Target Group ARN

- [ ] **1단계: 실패 테스트 작성**

Task Definition ARN, ECS Service 이름, task/execution role ARN map 크기 3과 Spring Target Group ARN을 검증한다. Secret 값 output은 정적 검사로 금지한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-fargate.tftest.hcl`

기대 결과: 신규 output이 없어 실패한다.

- [ ] **3단계: Output 구현**

비민감 식별자만 keyed map으로 출력한다. Service가 비활성일 때 Service output은 빈 map이 되게 한다.

- [ ] **4단계: 전체 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test && bash v2/tests/preflight_test.sh && ! rg -n 'aws_ecs_autoscaling|FARGATE_SPOT|aws_lb_target_group.*(fastapi|judge)' v2 --glob '*.tf' && git diff --check`

기대 결과: 모든 1차·2차 테스트와 범위 검사가 통과한다. 커밋하지 않는다.

### Task 8: 실제 state·plan·배포 검증

**파일:** 소스 변경 없음. Provider 제약과 실제 AWS 동작 차이로 문서 정정이 필요한 경우에만 설계 문서를 수정한다.

**인터페이스:**

- 입력: Terraform Cloud 인증, AWS 인증, ECR digest, Secret version, 승인된 create/update-only plan
- 출력: 배포된 2차 기반과 smoke test 결과

- [ ] **1단계: workspace/state 확인**

`terraform -chdir=v2 init`, `terraform -chdir=v2 state list`를 실행한다. 인증 실패, v1 주소, 예상하지 않은 주소가 있으면 중단한다.

- [ ] **2단계: 비활성 bootstrap plan/apply**

두 enable flag가 false인 create/update-only plan을 적용한다. Data/RDS/Valkey/Secret/ECR와 상태 저장 EC2/EBS만 생성되고 ECS Task Definition/Service와 ALB rule은 생성되지 않아야 한다.

- [ ] **3단계: 상태 저장 기반 plan/apply**

EC2 두 대가 ECS `ACTIVE`, EBS mount와 snapshot policy가 정상인지 확인한다. 이미지와 Secret 준비 후 `enable_stateful_services=true` plan을 검토·적용하고 상태 저장 Service health를 확인한다.

- [ ] **4단계: preflight와 Fargate plan/apply**

`preflight.sh` 통과 후 `enable_phase2_services=true` plan을 저장한다. destroy/replacement가 없고 Spring만 ALB에 연결되는지 검토한 후 저장된 plan을 적용한다.

- [ ] **5단계: smoke test와 멱등성**

설계 문서 23.3의 10개 smoke test를 수행하고 `terraform plan -detailed-exitcode`가 0인지 확인한다. 실패하면 자동으로 추가 변경하지 않고 원인을 진단한다.
