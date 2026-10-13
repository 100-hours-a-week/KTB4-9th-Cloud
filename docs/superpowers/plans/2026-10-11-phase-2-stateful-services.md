# COSMOS v2 2차 상태 저장 ECS on EC2 Implementation Plan

> **에이전트 작업자 필수 사항:** 이 계획은 `superpowers:subagent-driven-development`(권장) 또는 `superpowers:executing-plans`를 사용해 작업별로 구현한다. 진행 상태는 체크박스(`- [ ]`)로 추적한다.

**목표:** Judge PostgreSQL과 Redis Queue를 각각 전용 ECS-optimized EC2 한 대와 보존 EBS에서 ECS Service로 실행하고 snapshot·복구 기반을 제공한다.

**아키텍처:** 고정 EC2 두 대를 기존 ECS Cluster에 서로 다른 instance attribute로 등록하고, Service placement constraint로 상태 저장 Task를 지정된 호스트에 고정한다. 독립 EBS는 ECS agent 시작 전에 마운트하고 host bind volume으로 사용한다. Service Connect가 동적 Task ENI를 `judge-postgres`, `judge-redis` 이름으로 제공한다.

**기술 스택:** Terraform, ECS EC2 launch type, ECS-optimized AL2023, EC2, EBS gp3, Systems Manager, Service Connect, DLM, Secrets Manager, CloudWatch Logs

**설계:** `v2/phase-2-architecture.md`

**선행 계획:** `docs/superpowers/plans/2026-10-11-phase-2-data-foundation.md`

**구현 상태 (2026-10-11):** Task 1~5 소스 구현 및 native test 완료. 이미지/Secret 준비 전이므로 상태 저장 ECS Service 기본값은 비활성.

## 전체 제약 조건

- PostgreSQL과 Redis는 각각 On-Demand EC2 1대에서 실행하며 서로 다른 AZ를 사용한다.
- 기본 인스턴스는 `t3.small`, 데이터 EBS는 암호화 gp3 30GiB다.
- Public IP, SSH key pair, SSH ingress를 만들지 않는다.
- EBS에는 `prevent_destroy`를 적용하고 EC2 종료 시 삭제하지 않는다.
- PostgreSQL 16과 Valkey 8 이미지는 private ECR digest만 사용한다.
- Service 배포는 stop-before-start(`minimum=0`, `maximum=100`)다.
- `enable_stateful_services=false`를 안전한 기본값으로 사용하고 digest와 Secret이 준비된 후에만 true로 변경한다.
- EC2 자동 교체, Auto Scaling, Judge Worker는 만들지 않는다.
- 커밋은 생성하지 않는다.

## 중점 검토 항목

- EBS attachment race: ECS agent는 올바른 volume을 확인·마운트하기 전 Cluster에 등록되면 안 된다.
- 잘못된 호스트 배치: PostgreSQL/Redis Task는 각각 자신의 `role` attribute가 아니면 실행되면 안 된다.
- Task 재배포 데이터 삭제: host bind mount와 `prevent_destroy`가 없으면 검증이 실패해야 한다.
- 비밀값 노출: container definition은 Secret ARN/key reference만 포함하고 실제 값은 없어야 한다.
- 복구 불가능한 자동 교체: EC2 lifecycle replacement는 EBS 재연결 runbook 검토 없이는 실행하지 않는다.

---

## 파일 구성

| 파일 | 책임 |
| --- | --- |
| `v2/ecs-container-instances.tf` | AMI, EC2/EBS/attachment, instance IAM |
| `v2/templates/ecs-stateful-user-data.sh.tftpl` | 안전한 EBS 탐색·포맷·마운트와 ECS 등록 |
| `v2/application-iam.tf` | 상태 저장 execution/task role |
| `v2/judge-stateful-services.tf` | Task Definition과 ECS Service |
| `v2/backups.tf` | DLM role, policy, snapshot 일정 |
| `v2/logging.tf` | 상태 저장 Log Group 추가 |
| `v2/variables.tf`, `v2/locals.tf` | instance, EBS, digest, stateful map |
| `v2/outputs.tf` | EC2/EBS/Service output |
| `v2/stateful-recovery.md` | 한국어 장애 복구 runbook |
| `v2/tests/phase-2-stateful.tftest.hcl` | Mocked 상태 저장 계약 테스트 |

### Task 1: 상태 저장 변수와 EC2 IAM

**파일:**

- 수정: `v2/variables.tf`, `v2/locals.tf`
- 생성: `v2/ecs-container-instances.tf`, `v2/tests/phase-2-stateful.tftest.hcl`

**인터페이스:**

- 입력: `stateful_instance_type`, `stateful_ebs_size`, `enable_stateful_services`, existing cluster name
- 출력: `local.stateful_services` keyed by `judge-postgres`/`judge-redis`, EC2 instance profile

- [ ] **1단계: 실패 테스트 작성**

두 서비스의 AZ/subnet/mount path/container port/backup retention map, `t3.small`, EBS 30GiB, enable flag false를 검증한다. 20GiB 미만 EBS와 빈 instance type은 거부한다. enable=true이면 두 stateful digest가 `sha256:` + 64 lowercase hex여야 한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: 변수/local 또는 instance IAM이 없어 실패한다.

- [ ] **3단계: 변수/local과 IAM 구현**

EC2 trust role에 `AmazonEC2ContainerServiceforEC2Role`과 `AmazonSSMManagedInstanceCore`만 연결하고 instance profile을 만든다. 상태 저장 서비스 map에 고정된 두 AZ, mount path, port, retention을 정의한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: 변수와 IAM 검증이 통과한다.

### Task 2: EBS mount bootstrap과 전용 EC2

**파일:**

- 생성: `v2/templates/ecs-stateful-user-data.sh.tftpl`
- 수정: `v2/ecs-container-instances.tf`, `v2/tests/phase-2-stateful.tftest.hcl`

**인터페이스:**

- 입력: cluster name, service role attribute, EBS volume ID, mount path
- 출력: `aws_ebs_volume.stateful`, `aws_instance.stateful`, `aws_volume_attachment.stateful`

- [ ] **1단계: bootstrap 단위 테스트 작성**

Template 렌더 결과에 `ECS_CLUSTER`, JSON `ECS_INSTANCE_ATTRIBUTES`, IMDSv2, volume ID 기반 Nitro device 탐색, `blkid` 기반 최초 1회 포맷, systemd mount-before-ECS 의존성과 mount path가 포함되는지 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: EBS/EC2/template이 없어 실패한다.

- [ ] **3단계: template 구현**

`ebsnvme-id`로 volume ID와 일치하는 device를 제한 시간 동안 찾고, filesystem이 없을 때만 ext4로 포맷한다. `/etc/fstab`은 UUID로 기록하며 mount 성공 전 ECS agent를 시작하지 않는다. 민감값을 user data에 넣지 않는다.

- [ ] **4단계: EC2/EBS 구현**

공개 SSM Parameter에서 최신 ECS-optimized AL2023 X86_64 AMI를 조회한다. EBS와 EC2를 같은 AZ에 만들고 `aws_volume_attachment`로 연결한다. EC2는 public IP/key name 없이 IMDSv2 required, encrypted root disk, `prevent_destroy`를 사용한다.

- [ ] **5단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl && test "$(rg -c 'prevent_destroy\s*=\s*true' v2/ecs-container-instances.tf)" -ge 2`

기대 결과: 두 EC2/EBS의 AZ, 보존, 보안, bootstrap 테스트와 lifecycle 정적 검사가 통과한다.

### Task 3: 상태 저장 IAM·Log Group·Task Definition

**파일:**

- 수정: `v2/application-iam.tf`, `v2/logging.tf`, `v2/variables.tf`
- 생성: `v2/judge-stateful-services.tf`
- 수정: `v2/tests/phase-2-stateful.tftest.hcl`

**인터페이스:**

- 입력: ECR URL/digest, Secret ARN, host mount path, Log Group
- 출력: `aws_iam_role.stateful_execution`, `aws_iam_role.stateful_task`, `aws_ecs_task_definition.stateful`

- [ ] **1단계: 실패 테스트 작성**

Enable=false일 때 Task Definition이 0개인지 확인한다. Enable=true mocked run에서 이미지가 ECR URL@digest 형식인지 검증한다. EC2/awsvpc, host source path, mount point, 5432/6379 port name, `pg_isready`/`valkey-cli ping`, CloudWatch log와 Secret reference를 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: IAM/Log Group/Task Definition이 없어 실패한다.

- [ ] **3단계: IAM과 로그 구현**

서비스별 execution role에 AWS task execution policy와 자신의 Secret ARN 조회만 허용한다. Task role에는 ECS Exec `ssmmessages` channel 권한만 둔다. 상태 저장 Log Group 2개를 기존 retention 변수로 생성한다.

- [ ] **4단계: Task Definition 구현**

`enable_stateful_services`가 true일 때만 채워지는 map으로 Task Definition을 만들고 `requires_compatibilities=["EC2"]`, `network_mode="awsvpc"`, named port, host volume, Secret JSON key reference, health check, readonly root filesystem과 writable 필요 경로를 정의한다. PostgreSQL Secret key는 `username`, `password`, `database`, Redis key는 `password`로 고정하며 실제 값은 넣지 않는다.

- [ ] **5단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: Task Definition 및 최소 권한 검증이 통과한다.

### Task 4: 상태 저장 ECS Service와 Service Connect

**파일:**

- 수정: `v2/judge-stateful-services.tf`, `v2/tests/phase-2-stateful.tftest.hcl`

**인터페이스:**

- 입력: Task Definition, namespace ARN, Security Group, Private subnet, instance attribute
- 출력: `aws_ecs_service.stateful` keyed services and aliases

- [ ] **1단계: 실패 테스트 작성**

Enable=false일 때 Service 0개, enable=true mocked run에서 desired count 1, EC2 launch type, public IP false, 정확히 지정된 subnet/SG, circuit breaker, `minimum=0`, `maximum=100`, `memberOf attribute:role == ...`, Service Connect alias/port를 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: 상태 저장 ECS Service가 없어 실패한다.

- [ ] **3단계: Service 구현**

EC2와 volume attachment에 명시적으로 의존하고 Service Connect endpoint를 만든다. 새 Task가 같은 volume을 동시에 사용하지 않도록 stop-before-start 배포 설정을 적용한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: 배치 제약과 endpoint 검증이 통과한다.

### Task 5: DLM snapshot과 복구 문서

**파일:**

- 생성: `v2/backups.tf`, `v2/stateful-recovery.md`
- 수정: `v2/outputs.tf`, `v2/tests/phase-2-stateful.tftest.hcl`

**인터페이스:**

- 입력: EBS `BackupPolicy` tag (`judge-postgres`/`judge-redis`)
- 출력: DLM policy 2개, EC2/EBS/Service output, 한국어 recovery runbook

- [ ] **1단계: 실패 테스트 작성**

매일 snapshot, PostgreSQL 7개/Redis 3개 보존, volume target tag, DLM 최소 권한 role을 검증한다. EC2/EBS/Service output map 크기도 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-stateful.tftest.hcl`

기대 결과: DLM과 output이 없어 실패한다.

- [ ] **3단계: DLM과 output 구현**

서비스별 target tag 및 retention count를 사용하는 DLM policy를 만든다. 비밀값 없는 EC2 ID, EBS ID, ECS Service 이름을 map으로 출력한다.

- [ ] **4단계: 복구 runbook 작성**

장애 확인, ECS Service desired count 0, 손상 instance 격리, snapshot/volume 선택, 동일 AZ 복구 EC2 준비, EBS attach/mount, attribute 확인, desired count 1, health 및 데이터 확인 순서를 한국어로 기록한다. 자동 `terraform apply`로 장애 volume을 교체하지 않음을 명시한다.

- [ ] **5단계: 전체 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test && git diff --check`

기대 결과: 기존 테스트와 상태 저장 테스트가 통과한다. 커밋하지 않는다.
