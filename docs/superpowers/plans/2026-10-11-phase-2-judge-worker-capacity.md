# COSMOS v2 2차 보완 Judge Worker Capacity Provider Implementation Plan

> **에이전트 작업자 필수 사항:** 이 계획은 `superpowers:subagent-driven-development`(권장) 또는 `superpowers:executing-plans`를 사용해 작업별로 구현한다. 진행 상태는 체크박스(`- [ ]`)로 추적한다.

**목표:** 평시 On-Demand Worker 1개를 보장하고 추가 Worker를 Spot 0~7개로 수동 확장할 수 있는 전용 ECS Capacity Provider 기반을 구축한다.

**아키텍처:** On-Demand `c7i.large` ASG와 X86_64 2 vCPU/4GiB Spot mixed ASG를 별도 Capacity Provider로 ECS Cluster에 연결한다. Worker Service는 base 1 On-Demand, 추가 weight 1 Spot 전략을 사용하며 Worker Task는 2 vCPU/2GiB, 인터넷 차단, PostgreSQL·Redis Service Connect client로만 동작한다. Queue 지표 기반 Service Auto Scaling은 3차로 남긴다.

**기술 스택:** Terraform >= 1.7, AWS Provider 5.100.0, ECS on EC2, EC2 Auto Scaling, ECS Capacity Provider, Spot, ECR, Secrets Manager, CloudWatch Logs, Terraform native test, Bash

**설계:** `v2/phase-2-worker-architecture.md`

## 전체 제약 조건

- AWS 리전은 `ap-northeast-2`이고 기존 `aws_ecs_cluster.main`, private subnet, Service Connect namespace를 재사용한다.
- Worker Task는 CPU 2048, memory 2048MiB이며 EC2 한 대당 Task 한 개만 배치한다.
- On-Demand ASG는 활성화 시 `min=1`, `desired=1`, `max=1`이다.
- Spot ASG는 활성화 시 `min=0`, `desired=0`, `max=worker_spot_max_size`이며 기본 max는 7, 허용 범위는 4~7이다.
- On-Demand instance type은 `c7i.large`, Spot 후보는 `c7i.large`, `c6i.large`, `c6a.large`다.
- 첫 Worker는 On-Demand, 추가 Worker는 Spot에 배치한다.
- Worker Task에는 public ingress, public IP, ECS Exec, 인터넷 egress를 허용하지 않는다.
- Worker host에는 SSH key와 ingress가 없고 SSM, ECS, ECR, Logs용 HTTPS와 VPC DNS egress만 허용한다.
- Worker image는 private ECR digest만 사용하고 실제 Secret value/version은 Terraform이 생성하지 않는다.
- 기존 RDS, EBS, 상태 저장 EC2와 v1 resource를 이동·import·삭제·교체하지 않는다.
- 커밋은 생성하지 않는다. 사용자가 직접 커밋한다.

## 중점 검토 항목

- `enable_judge_worker=true`, `enable_judge_worker_capacity=false`: validation/precondition으로 Service 생성을 거부해야 한다. Task 1과 Task 5 테스트로 고정한다.
- `judge_worker_desired_count > 1 + worker_spot_max_size`: Service precondition이 plan을 거부해야 한다. Task 5 테스트로 고정한다.
- Spot instance 후보가 비거나 중복됨: 변수 validation이 비어 있지 않은 고유 X86_64 후보 목록만 허용해야 한다. Task 1 테스트로 고정한다.
- managed termination protection과 ASG scale-in protection 불일치: 두 ASG 모두 `protect_from_scale_in=true`이고 두 Capacity Provider 모두 termination protection이 활성화되어야 한다. Task 3·4 테스트로 고정한다.
- privileged Worker의 격리 실패: Worker만 privileged이고 Task SG에 PostgreSQL·Redis·DNS 외 egress가 없으며 다른 서비스와 ASG를 공유하지 않아야 한다. Task 2·5 테스트로 고정한다.

---

## 파일 구성

| 파일 | 책임 |
| --- | --- |
| `v2/variables.tf` | Worker enable flag, digest, capacity, instance, task 변수와 validation |
| `v2/locals.tf` | Worker service/capacity map과 조건부 enabled map |
| `v2/ecr.tf` | Judge Worker 전용 ECR와 lifecycle |
| `v2/secrets.tf` | Judge Worker Secret metadata |
| `v2/logging.tf` | Judge Worker Log Group |
| `v2/application-security.tf` | Worker Task/host SG 및 PostgreSQL·Redis ingress |
| `v2/application-iam.tf` | Worker execution/task role |
| `v2/worker-capacity.tf` | Worker EC2 role/profile, Launch Template, ASG, Capacity Provider |
| `v2/templates/ecs-worker-user-data.sh.tftpl` | ECS 등록과 Spot draining bootstrap |
| `v2/ecs.tf` | Cluster Capacity Provider 연결 확장 |
| `v2/judge-worker.tf` | Worker Task Definition과 ECS Service |
| `v2/outputs.tf` | Worker ECR/Secret/SG/ASG/Capacity Provider/Task/Service output |
| `v2/scripts/preflight.sh` | Worker image·Secret·운영 확인·AWS 활성 상태 검사 확장 |
| `v2/tests/phase-2-worker.tftest.hcl` | Worker Terraform 계약 테스트 |
| `v2/tests/preflight_test.sh` | Worker preflight 성공·실패 fixture |
| `v2/judge-worker-operations.md` | 한국어 수동 확장·Spot interruption·복구 runbook |

### Task 1: Worker 변수, local, ECR, Secret, Log Group

**파일:**

- 수정: `v2/variables.tf`
- 수정: `v2/locals.tf`
- 수정: `v2/ecr.tf`
- 수정: `v2/secrets.tf`
- 수정: `v2/logging.tf`
- 생성: `v2/tests/phase-2-worker.tftest.hcl`

**인터페이스:**

- 입력: `enable_judge_worker_capacity`, `enable_judge_worker`, `judge_worker_image_digest`, Worker task/capacity 변수
- 출력: `local.worker_service`, `local.enabled_worker_capacity`, `local.enabled_judge_worker`, `check.judge_worker_capacity_enabled`, `check.judge_worker_digest_ready`, `aws_ecr_repository.worker`, `aws_secretsmanager_secret.service["judge-worker"]`, `aws_cloudwatch_log_group.worker`

- [x] **1단계: 실패 테스트 작성**

`phase-2-worker.tftest.hcl`에 다음 run을 작성한다.

- 기본 enable flag 둘 다 false
- CPU/memory `2048/2048`, desired count 1
- On-Demand `c7i.large`, Spot 후보 세 개, Spot max 7, root volume 50GiB
- Spot max 3과 8 거부
- 빈·중복 Spot 후보 거부
- Worker 활성화 시 capacity false를 `check.judge_worker_capacity_enabled`가 거부
- Worker 활성화 시 digest가 `sha256:` + lowercase hex 64자가 아니면 `check.judge_worker_digest_ready`가 거부
- Worker ECR이 immutable, scan-on-push, AES256, `force_delete=false`, 기존 lifecycle과 동일
- `/cosmos-v2/prod/judge-worker` Secret metadata와 Worker Log Group 존재

- [x] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker 변수 또는 리소스가 선언되지 않아 실패한다.

- [x] **3단계: 변수와 local 구현**

설계의 변수명과 기본값을 그대로 추가한다. `worker_spot_instance_types`는 비어 있지 않고 `length(distinct(...)) == length(...)`여야 한다. Terraform 최소 버전 1.7과 호환되도록 다른 변수 값을 참조하는 variable validation은 사용하지 않는다. 대신 `check.judge_worker_capacity_enabled`와 `check.judge_worker_digest_ready`를 정의한다. `local.enabled_worker_capacity`와 `local.enabled_judge_worker`는 조건부 `for_each`가 안정적으로 빈 map을 반환하게 정의하고 capacity가 false일 때 Worker resource가 잘못된 index를 참조하지 않게 한다.

- [x] **4단계: ECR, Secret metadata, Log Group 구현**

기존 애플리케이션·상태 저장 ECR map은 변경하지 않고 `aws_ecr_repository.worker`와 lifecycle을 별도 단일 resource로 추가한다. `local.secret_names`에 `judge-worker`를 추가하고 기존 metadata resource를 재사용한다. Worker Log Group은 기존 retention 변수를 사용한다.

- [x] **5단계: 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Task 1 계약과 기존 Secret map 크기 변경을 반영한 회귀 테스트가 통과한다.

### Task 2: Worker 네트워크 경계와 IAM

**파일:**

- 수정: `v2/application-security.tf`
- 수정: `v2/application-iam.tf`
- 수정: `v2/tests/phase-2-worker.tftest.hcl`

**인터페이스:**

- 입력: `aws_vpc.main`, Judge PostgreSQL/Redis SG, 기존 Secret ARN, `cidrhost(var.vpc_cidr, 2)`
- 출력: `aws_security_group.worker_task`, `aws_security_group.worker_host`, Worker ingress/egress rule, `aws_iam_role.worker_execution`, `aws_iam_role.worker_task`

- [x] **1단계: 실패 테스트 작성**

다음을 검증한다.

- Worker Task SG와 host SG에 ingress rule 0개
- Worker Task egress는 PostgreSQL TCP 5432, Redis TCP 6379, VPC resolver TCP/UDP 53만 존재
- Worker Task SG에 `0.0.0.0/0` egress와 TCP 443 egress가 없음
- Worker host egress는 VPC resolver TCP/UDP 53과 `0.0.0.0/0` TCP 443만 존재
- PostgreSQL·Redis ingress에 Worker Task SG source 추가
- execution role은 Worker, PostgreSQL, Redis Secret ARN만 읽음
- task role에는 inline/attached AWS API 권한과 `ssmmessages` 권한이 없음

- [x] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker SG/IAM resource가 없어 실패한다.

- [x] **3단계: Worker Security Group 구현**

Task SG와 host SG를 inline rule 없이 생성한다. Task DNS egress는 `cidrhost(var.vpc_cidr, 2)/32`를 사용한다. PostgreSQL·Redis rule은 기존 data SG에 Worker Task SG를 source로 추가한다. host SG에는 ingress를 만들지 않는다.

- [x] **4단계: Worker IAM 구현**

execution role은 ECS task trust, AWS task execution managed policy와 세 Secret의 `GetSecretValue`만 갖는다. task role은 ECS task trust만 갖고 별도 policy를 연결하지 않는다. Worker instance role/profile은 Task 3에서 생성한다.

- [x] **5단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker의 데이터 경로와 AWS 권한 격리 계약이 통과한다.

### Task 3: Launch Template와 On-Demand/Spot ASG

**파일:**

- 생성: `v2/worker-capacity.tf`
- 생성: `v2/templates/ecs-worker-user-data.sh.tftpl`
- 수정: `v2/tests/phase-2-worker.tftest.hcl`

**인터페이스:**

- 입력: 기존 ECS optimized AL2023 SSM Parameter, cluster name, private subnet ID, host SG, Worker capacity 변수
- 출력: `aws_iam_instance_profile.worker`, `aws_launch_template.worker`, `aws_autoscaling_group.worker_on_demand`, `aws_autoscaling_group.worker_spot`

- [x] **1단계: 실패 테스트 작성**

다음을 검증한다.

- capacity false이면 Launch Template와 ASG가 0개
- capacity true이면 공통 Launch Template 1개, On-Demand/Spot ASG 각 1개
- Launch Template public IP false, key name null, IMDSv2 required, detailed monitoring true
- encrypted gp3 root 50GiB, `delete_on_termination=true`
- user data에 ECS cluster, `ECS_ENABLE_SPOT_INSTANCE_DRAINING=true`, container metadata 설정 포함
- instance role에는 ECS container instance와 SSM managed policy만 연결
- On-Demand ASG `1/1/1`, `c7i.large`, private subnet 2개, `protect_from_scale_in=true`
- Spot ASG `0/0/7`, 세 instance override, On-Demand 0%, `capacity-optimized-prioritized`, capacity rebalance와 scale-in protection 활성화

- [x] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Launch Template/ASG/template이 없어 실패한다.

- [x] **3단계: Worker instance IAM과 user data 구현**

Worker 전용 EC2 trust role과 instance profile을 만들고 두 AWS managed policy만 연결한다. template은 `/etc/ecs/ecs.config`를 원자적으로 기록하고 ECS agent를 활성화한다. Secret과 애플리케이션 환경값은 user data에 넣지 않는다.

- [x] **4단계: Launch Template 구현**

기존 `data.aws_ssm_parameter.ecs_optimized_al2023`를 재사용한다. instance type은 ASG에서 결정하고 Launch Template에는 AMI, profile, host SG, IMDSv2, monitoring, encrypted root disk, public IP false와 tag specification을 정의한다.

- [x] **5단계: 두 ASG 구현**

두 resource 모두 `count = var.enable_judge_worker_capacity ? 1 : 0`를 사용한다. On-Demand는 Launch Template override `c7i.large`와 `1/1/1`을 사용한다. Spot은 mixed instances policy의 세 override와 설계된 distribution, `0/0/max`, capacity rebalance를 사용한다. Capacity Provider termination protection 요구를 위해 두 ASG 모두 `protect_from_scale_in=true`로 고정한다.

- [x] **6단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: EC2 bootstrap, 보안, On-Demand/Spot 용량 계약이 통과한다.

### Task 4: ECS Capacity Provider와 Cluster 연결

**파일:**

- 수정: `v2/worker-capacity.tf`
- 수정: `v2/ecs.tf`
- 수정: `v2/tests/foundation.tftest.hcl`
- 수정: `v2/tests/phase-2-worker.tftest.hcl`

**인터페이스:**

- 입력: 두 ASG ARN, 기존 `aws_ecs_cluster.main`
- 출력: `aws_ecs_capacity_provider.worker_on_demand`, `aws_ecs_capacity_provider.worker_spot`, 확장된 `aws_ecs_cluster_capacity_providers.main`

- [x] **1단계: 실패 테스트 작성**

capacity false run에서는 Cluster provider가 `FARGATE` 하나이고 기본 strategy가 Fargate인지 확인한다. capacity true run에서는 다음을 검증한다.

- 두 Worker Capacity Provider 추가, `FARGATE_SPOT` 부재
- managed scaling `ENABLED`, target capacity 100, minimum step 1
- On-Demand maximum step 1, Spot maximum step 7
- instance warmup 300초
- managed draining과 termination protection `ENABLED`
- Cluster 기본 strategy는 계속 FARGATE

- [x] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker Capacity Provider resource가 없어 실패한다.

- [x] **3단계: Capacity Provider 구현**

각 resource를 capacity flag로 조건부 생성하고 자신의 ASG만 참조한다. Provider 5.100.0 schema의 `managed_draining`, `managed_termination_protection`, `managed_scaling` block을 사용한다.

- [x] **4단계: Cluster 연결 구현**

`aws_ecs_cluster_capacity_providers.main.capacity_providers`를 FARGATE와 조건부 Worker provider 이름을 합친 목록으로 변경한다. 기존 default strategy와 Fargate Service 동작은 변경하지 않는다.

- [x] **5단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: 기존 Fargate 계약과 조건부 Worker Capacity Provider 계약이 함께 통과한다.

### Task 5: Judge Worker Task Definition과 ECS Service

**파일:**

- 생성: `v2/judge-worker.tf`
- 수정: `v2/tests/phase-2-worker.tftest.hcl`

**인터페이스:**

- 입력: Worker ECR URL/digest, execution/task role ARN, Secret ARN, Log Group, SG, subnet, namespace, Capacity Provider 이름
- 출력: `aws_ecs_task_definition.judge_worker`, `aws_ecs_service.judge_worker`

- [x] **1단계: 실패 테스트 작성**

기본 run에서 Task Definition과 Service가 0개인지 확인한다. 유효 digest와 두 enable flag가 true인 mocked run에서 다음을 검증한다.

- EC2/awsvpc/Linux X86_64, CPU/memory `2048/2048`
- private ECR URL@digest
- `privileged=true`, readonly root, writable `/tmp`
- `/app/healthcheck.sh`, stop timeout 120초, awslogs
- PostgreSQL/Redis host·port 환경과 Worker/DB/Redis Secret reference
- desired count 1, private subnet 2개, public IP false, Worker Task SG만 사용
- deployment 0/100, circuit breaker rollback, ECS Exec false
- Service Connect client-only, ALB/load balancer 없음
- `distinctInstance` placement constraint
- On-Demand strategy base 1 weight 0, Spot base 0 weight 1
- desired count 8과 Spot max 4 조합 거부

- [x] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker Task/Service resource가 없어 실패한다.

- [x] **3단계: Task Definition 구현**

`local.enabled_judge_worker`를 `for_each` source로 사용한다. `/tmp` empty volume만 mount하고 host path/EBS를 사용하지 않는다. Worker 자체 Secret은 전체 JSON, PostgreSQL/Redis는 설계된 JSON key ARN suffix로 주입한다. Task role에는 ECS Exec policy를 추가하지 않는다.

- [x] **4단계: ECS Service 구현**

두 Capacity Provider가 존재할 때만 생성하고 설계의 strategy, deployment, network, Service Connect client, distinct placement를 적용한다. lifecycle precondition으로 desired count가 `1 + worker_spot_max_size` 이하인지 검사한다. Capacity Provider와 ASG에 명시적으로 의존한다.

- [x] **5단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker image, 격리, 배치, 중단 허용 배포 계약이 통과한다.

### Task 6: Output, preflight, 운영 문서

**파일:**

- 수정: `v2/outputs.tf`
- 수정: `v2/scripts/preflight.sh`
- 수정: `v2/tests/preflight_test.sh`
- 생성: `v2/judge-worker-operations.md`
- 수정: `v2/tests/phase-2-worker.tftest.hcl`

**인터페이스:**

- 입력: Worker resource 식별자, AWS CLI, Terraform CLI, Worker digest/Secret/운영 attestation
- 출력: 비민감 Worker output, 성공 시 preflight exit 0, 한국어 runbook

- [x] **1단계: 실패 테스트 작성**

Terraform test에 ECR/Secret/SG/ASG/Capacity Provider map 또는 nullable Task/Service output을 검증한다. shell fixture에는 다음 실패 사례를 추가한다.

- Worker ECR digest 없음
- Worker/PostgreSQL/Redis Secret `AWSCURRENT` 없음
- `WORKER_IMAGE_CONTRACT_VERIFIED=true` 누락
- `WORKER_SIGTERM_VERIFIED=true` 누락
- `WORKER_SANDBOX_VERIFIED=true` 누락
- capacity 활성 상태 검사 명령 실패

모든 기존 application preflight fixture와 Worker 정상 fixture는 exit 0이어야 한다.

- [x] **2단계: 구현 전 실패 확인**

실행: `bash v2/tests/preflight_test.sh && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: Worker preflight/output이 없어 신규 assertion이 실패한다.

- [x] **3단계: Output 구현**

설계 21장의 비민감 식별자를 추가한다. 조건부 resource는 `try(..., null)` 또는 keyed empty map을 사용하고 Secret value를 출력하지 않는다.

- [x] **4단계: Preflight 확장**

기존 application 검사를 깨지 않도록 `CHECK_JUDGE_WORKER=true`일 때만 Worker 검사를 수행한다. `ecr describe-images`, `secretsmanager list-secret-version-ids`, `ecs list-container-instances`, `ecs describe-container-instances`, `ecs describe-capacity-providers`, `terraform state list`만 사용한다. attestation 세 개가 모두 문자열 `true`인지 검사하고 Secret 값을 출력하거나 apply를 호출하지 않는다.

- [x] **5단계: 운영 runbook 작성**

`judge-worker-operations.md`에 capacity 선행 활성화, image/Secret 준비, preflight, desired 1 배포, desired 2 Spot 검증, 1 복원, Spot interruption, Queue 재처리, 잘못된 revision rollback, 장애 복구와 3차 연계 절차를 한국어로 기록한다.

- [x] **6단계: 검증**

실행: `bash -n v2/scripts/preflight.sh && bash -n v2/tests/preflight_test.sh && bash v2/tests/preflight_test.sh && terraform -chdir=v2 test -filter=tests/phase-2-worker.tftest.hcl`

기대 결과: 기존 및 Worker preflight fixture와 output 계약이 통과한다.

### Task 7: 전체 회귀 검증과 실제 활성화 경계

**파일:**

- 수정: `v2/phase-2-worker-architecture.md` — provider 제약 또는 구현 차이가 발견될 때만 정정
- 수정: `docs/superpowers/plans/2026-10-11-phase-2-judge-worker-capacity.md` — 검증 상태만 기록

**인터페이스:**

- 입력: 완성된 Worker Terraform, 기존 1·2차 Terraform, Terraform Cloud/AWS 인증과 운영 image/Secret
- 출력: 오프라인 검증 결과와 실제 배포를 위한 차단 조건

- [x] **1단계: 전체 오프라인 검증**

실행:

```bash
terraform -chdir=v2 fmt -check -recursive
terraform -chdir=v2 validate
terraform -chdir=v2 test
bash v2/tests/preflight_test.sh
! rg -n 'aws_secretsmanager_secret_version|secret_string' v2 --glob '*.tf'
! rg -n 'FARGATE_SPOT|aws_lb_target_group" "judge_worker|assign_public_ip\s*=\s*true' v2 --glob '*.tf'
git diff --check
```

기대 결과: 기존 30개 이상 회귀 테스트와 신규 Worker 테스트가 모두 통과하고 정적 안전 검사가 성공한다.

검증 결과(2026-10-11): `terraform test` 45개 통과, preflight fixture 통과, Secret value resource·Fargate Spot·Worker ALB·public IP 정적 검사와 `git diff --check` 통과.

- [ ] **2단계: 실제 state 사전 확인**

Terraform Cloud 인증이 있을 때만 `terraform -chdir=v2 init`과 `terraform -chdir=v2 state list`를 실행한다. v1 전용 주소, 예상하지 않은 state 또는 인증 실패가 있으면 중단한다.

- [ ] **3단계: Capacity-only plan 경계 확인**

`enable_judge_worker_capacity=true`, `enable_judge_worker=false` plan에서 Worker ECR/Secret/SG/IAM/Log와 Launch Template/ASG/Capacity Provider만 추가되고 Task/Service는 없어야 한다. 기존 RDS, EBS, EC2의 destroy/replacement가 있으면 적용하지 않는다.

- [ ] **4단계: 운영 준비 후 Worker plan 경계 확인**

실제 image digest와 Secret version, 세 attestation, On-Demand container instance/Capacity Provider `ACTIVE`를 확인한 뒤 Worker preflight를 실행한다. `enable_judge_worker=true`, desired count 1 plan에서 Worker가 On-Demand base 전략만 사용하는지 검토한다.

- [ ] **5단계: 실제 apply와 smoke test는 별도 승인 후 실행**

사용자의 명시적 실제 배포 요청과 AWS/Terraform Cloud 인증이 있을 때만 저장 plan을 적용한다. Queue consume, PostgreSQL 결과 저장, Redis 상태 갱신, `SIGTERM` 재처리, desired 2 Spot 기동, desired 1 복원과 최종 `plan -detailed-exitcode=0`을 확인한다. 인증 또는 애플리케이션 계약이 준비되지 않았으면 소스 구현 완료와 실제 배포 미수행을 구분해 보고한다.

> 현재 경계: 실제 Terraform Cloud state 조회, capacity-only plan, Worker plan, apply와 smoke test는 수행하지 않았다. 운영 인증 정보, image digest, Secret version, 애플리케이션 계약 확인 및 사용자의 별도 배포 승인이 필요하다.
