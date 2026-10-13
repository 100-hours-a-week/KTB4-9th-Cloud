# COSMOS v2 2차 보완 — Judge Worker ECS Capacity Provider 설계

> 최신 Stage/Prod 배치와 활성화 순서는 [Stage 운영 절차](stage-operations.md), 승격·rollback 기준은 [애플리케이션 마이그레이션 전략](application-migration.md)을 함께 따른다.

## 1. 문서 목적

이 문서는 COSMOS v2의 2차 보완 범위인 Judge Worker 실행 기반을 정의한다. Judge Worker를 전용 ECS on EC2 환경에 배치하고, 평시 On-Demand 1대를 유지하면서 추가 Worker는 Spot 0~7대로 확장할 수 있는 Capacity Provider 구조를 구축한다.

이번 단계의 목표는 자동 확장 정책 자체가 아니라 안전한 실행 기반과 수동 확장 가능한 용량 구조를 만드는 것이다. Redis Queue 지표 기반 자동 확장, CI/CD, 통합 rollback 자동화와 중앙 모니터링은 3차에서 연결한다.

## 2. 선행 구성

다음 v2 리소스가 이미 존재한다.

- 서울 리전 `ap-northeast-2` VPC
- Public subnet 2개, Private subnet 2개, Data subnet 2개
- 단일 NAT Gateway
- ECS Cluster와 Fargate Capacity Provider
- Spring Boot, FastAPI, Judge API Fargate 설계
- Judge PostgreSQL과 Judge Redis ECS on EC2 Service
- 서비스별 ECR, IAM, Security Group, Secrets Manager metadata, CloudWatch Logs
- Service Connect HTTP namespace `prod.cosmos-v2.local`

Judge Worker는 기존 상태 저장 EC2를 공유하지 않고 별도 Auto Scaling Group에서 실행한다.

## 3. 범위

### 3.1 포함 범위

- Judge API와 Worker가 공유하는 `cosmos-v2/judge` private ECR repository
- Worker 전용 Secret metadata, IAM role, Security Group, Log Group
- Worker용 ECS-optimized Amazon Linux 2023 Launch Template
- On-Demand Auto Scaling Group 1개
- Spot Mixed Instances Auto Scaling Group 1개
- On-Demand 및 Spot ECS Capacity Provider
- 기존 ECS Cluster의 Capacity Provider 연결 확장
- Judge Worker Task Definition과 ECS Service
- Worker image digest 및 배포 선행 조건
- Spot interruption draining과 capacity rebalance
- 수동 확장, 중단, 재처리, 장애 복구 절차
- Terraform native test와 preflight 확장

### 3.2 제외 범위

- Redis Queue 길이 기반 ECS Service Auto Scaling
- CloudWatch metric math 및 alarm 기반 자동 증감
- Spot 외 추가 On-Demand 자동 확장
- 애플리케이션 및 Terraform CI/CD
- 배포 파이프라인 수준의 자동 rollback
- Prometheus, Grafana와 중앙 관측성 스택
- ACM, HTTPS listener, Route 53 전환
- 부하 테스트에 따른 최종 Worker 용량 산정

## 4. 전체 구조

```text
Judge API
  └─ Judge Redis에 작업 enqueue

ECS Cluster
  ├─ FARGATE Capacity Provider
  │   ├─ Spring Boot
  │   ├─ FastAPI
  │   └─ Judge API
  │
  ├─ judge-worker-on-demand Capacity Provider
  │   └─ On-Demand ASG: min 1 / desired 1 / max 1
  │       └─ Worker Task 1개
  │
  └─ judge-worker-spot Capacity Provider
      └─ Spot ASG: min 0 / desired 0 / max 7
          └─ 추가 Worker Task 0~7개

Worker
  ├─ Service Connect → judge-postgres:5432
  └─ Service Connect → judge-redis:6379
```

초기 Worker Service desired count는 1이다. 첫 Task는 On-Demand Capacity Provider에 배치하고 두 번째 Task부터 Spot Capacity Provider에 배치한다.

## 5. 용량과 인스턴스

### 5.1 Worker Task

| 항목 | 값 |
| --- | --- |
| CPU | 2048 units, 2 vCPU |
| Memory | 2048MiB |
| Network mode | `awsvpc` |
| Launch type | ECS EC2 Capacity Provider |
| Architecture | Linux X86_64 |
| 기본 desired count | 1 |
| 최대 수동 desired count | On-Demand 1 + Spot 최대치 |

EC2 호스트는 Worker Task보다 큰 2 vCPU, 4GiB 규격을 사용한다. Task에 2GiB를 할당하고 나머지 메모리는 운영체제와 ECS agent에 남긴다. CPU 예약으로 EC2 한 대에는 Worker Task 하나만 배치되며 `distinctInstance` 제약도 함께 적용한다.

### 5.2 On-Demand ASG

- Instance type: `c7i.large`
- min size: 1
- desired capacity: 1
- max size: 1
- 두 Private subnet 사용
- public IP 및 SSH key 없음
- Capacity Rebalance는 사용하지 않음
- ECS Capacity Provider managed scaling 활성화
- managed termination protection 활성화
- ASG scale-in protection 활성화

On-Demand ASG는 평시 Worker 한 개를 보장하는 기준 용량이다.

### 5.3 Spot ASG

- Instance candidates: `c7i.large`, `c6i.large`, `c6a.large`
- 모두 X86_64, 2 vCPU, 4GiB 규격
- min size: 0
- desired capacity: 0
- max size: 기본 7
- `worker_spot_max_size` 허용 범위: 4~7
- On-Demand percentage: 0%
- Spot allocation strategy: `capacity-optimized-prioritized`
- Capacity Rebalance 활성화
- ECS Capacity Provider managed scaling 활성화
- managed termination protection 활성화
- ASG scale-in protection 활성화

Spot ASG는 초기 비용을 발생시키지 않는다. Worker desired count가 1보다 커질 때 Capacity Provider managed scaling이 필요한 Spot 인스턴스를 추가한다. Redis Queue 기반으로 desired count를 자동 변경하는 정책은 3차에서 추가한다.

## 6. Capacity Provider 전략

Worker ECS Service는 다음 전략만 사용한다.

| Capacity Provider | Base | Weight |
| --- | ---: | ---: |
| `judge-worker-on-demand` | 1 | 0 |
| `judge-worker-spot` | 0 | 1 |

- 첫 Task는 On-Demand에 배치한다.
- 추가 Task는 Spot에 배치한다.
- Worker 이외 ECS Service는 두 Worker Capacity Provider를 사용하지 않는다.
- Cluster 기본 Capacity Provider는 계속 `FARGATE`다.
- `FARGATE_SPOT`은 연결하지 않는다.

Cluster에 연결하는 Capacity Provider는 다음 세 개다.

```text
FARGATE
judge-worker-on-demand
judge-worker-spot
```

## 7. 안전한 활성화 단계

두 enable flag를 분리한다.

### 7.1 `enable_judge_worker_capacity`

기본값은 `false`다. `true`로 변경하면 다음 리소스를 만든다.

- Launch Template
- On-Demand 및 Spot ASG
- 두 ECS Capacity Provider
- ECS Cluster Capacity Provider 연결

On-Demand ASG는 1대를 시작하고 Spot ASG는 0대를 유지한다.

### 7.2 `enable_judge_worker`

기본값은 `false`다. 다음 조건이 충족된 뒤에만 `true`로 변경한다.

- `enable_judge_worker_capacity = true`
- Judge 공용 ECR image digest 준비
- 필요한 Secret에 `AWSCURRENT` version 존재
- image healthcheck 계약 확인
- `SIGTERM` 처리와 작업 재처리 계약 확인
- On-Demand container instance가 ECS Cluster에 `ACTIVE` 등록
- 두 Capacity Provider 상태가 `ACTIVE`

활성화하면 Worker Task Definition과 ECS Service를 생성한다. Terraform validation 또는 resource precondition으로 Worker 활성화가 Capacity 기반보다 먼저 진행되지 않게 한다.

## 8. Launch Template와 호스트 설정

### 8.1 공통 설정

- SSM 공개 Parameter의 최신 ECS-optimized Amazon Linux 2023 X86_64 AMI 사용
- encrypted gp3 root volume 50GiB
- IMDSv2 required
- 상세 monitoring 활성화
- public IP 비활성화
- SSH key pair 미사용
- Worker 전용 instance profile 사용
- AmazonEC2ContainerServiceforEC2Role
- AmazonSSMManagedInstanceCore

영구 데이터 EBS는 만들지 않는다. 컴파일 결과, 제출 코드와 실행 산출물은 Task 수명 임시 저장소만 사용하고 Task 종료 시 제거한다.

### 8.2 ECS bootstrap

User data는 다음 값을 `/etc/ecs/ecs.config`에 기록한다.

```text
ECS_CLUSTER=<v2 cluster name>
ECS_ENABLE_SPOT_INSTANCE_DRAINING=true
ECS_ENABLE_CONTAINER_METADATA=true
```

Spot interruption notice를 받으면 ECS agent가 container instance를 `DRAINING`으로 전환해 새 작업 배치를 중단한다.

## 9. 네트워크와 Security Group

### 9.1 Worker Task SG

Ingress rule은 만들지 않는다. Egress는 다음만 허용한다.

| 대상 | Protocol/port | 목적 |
| --- | --- | --- |
| Judge PostgreSQL SG | TCP 5432 | 결과 및 상태 저장 |
| Judge Redis SG | TCP 6379 | Queue consume 및 상태 갱신 |
| VPC DNS resolver | TCP/UDP 53 | Service Connect 이름 해석 |

`0.0.0.0/0` 인터넷 egress는 허용하지 않는다. Worker image는 compiler와 runtime을 포함해야 하며 실행 중 package download를 하지 않는다.

Judge PostgreSQL과 Redis SG에는 Worker SG를 source로 하는 ingress를 추가한다.

### 9.2 Worker EC2 SG

Ingress rule, SSH와 key pair를 만들지 않는다. 호스트는 ECS agent, ECR, CloudWatch Logs, SSM과 운영체제 bootstrap을 위해 다음 egress를 사용한다.

- VPC DNS resolver TCP/UDP 53
- NAT를 통한 HTTPS TCP 443

호스트 점검은 Systems Manager Session Manager만 사용한다.

## 10. Service Connect와 데이터 흐름

Worker Service는 기존 HTTP namespace의 client로만 동작하며 외부 또는 내부 server alias를 만들지 않는다.

```text
Judge API
  → judge-redis:6379 enqueue

Judge Worker
  → judge-redis:6379 consume/status update
  → judge-postgres:5432 result persistence
```

Worker는 HTTP Target Group이나 ALB listener rule을 갖지 않는다.

## 11. ECR와 image 계약

Judge API와 Worker는 다음 repository를 공유한다.

```text
cosmos-v2/judge
```

공통 ECR 정책을 적용한다.

- immutable tag
- push scan
- AES-256 encryption
- `force_delete = false`
- tagged image 20개 유지
- untagged image 7일 후 정리
- Task Definition은 repository URL과 `sha256:` digest를 결합해 사용

Worker image는 다음 계약을 충족해야 한다.

- X86_64 Linux
- compiler와 지원 runtime 사전 포함
- `/app/healthcheck.sh` 제공
- `SIGTERM` 수신 시 새 작업 consume 중단
- 진행 중인 작업 완료 또는 재처리 가능 상태 전환
- Task 종료 시 제출 코드와 실행 산출물 제거
- 인터넷 연결 없이 실행 가능
- 실행 시간, process 수, memory, output file 크기 제한 지원

## 12. 사용자 코드 격리

Judge Worker는 신뢰할 수 없는 사용자 코드를 실행하므로 다른 서비스와 호스트를 공유하지 않는다.

- Worker 전용 ASG와 EC2 사용
- Worker 컨테이너에만 `privileged = true` 허용
- root filesystem read-only
- `/tmp` writable ephemeral volume
- CPU hard limit 2 vCPU
- memory hard limit 2GiB
- 외부 네트워크 차단
- 실행 시간 제한
- process 및 file size 제한
- 영구 host bind volume 미사용
- Worker ECS Exec 비활성화
- 호스트 접근은 SSM과 승인된 운영 절차로 제한

`privileged` 권한은 Judge sandbox 구현에 필요한 host-level namespace/cgroup 제어를 위해 Worker에만 허용한다. 이미지가 제공하는 sandbox 설정과 제한이 검증되지 않으면 운영 Service를 활성화하지 않는다.

## 13. Secret과 IAM

### 13.1 Secret metadata

다음 Secret metadata를 추가한다.

```text
/cosmos-v2/prod/judge-worker
```

Terraform은 `aws_secretsmanager_secret_version`과 실제 Secret 값을 만들지 않는다.

Worker execution role은 다음 Secret만 읽는다.

- Judge Worker 자체 Secret 전체 JSON: `JUDGE_WORKER_SECRET_JSON`
- Judge PostgreSQL: `username`, `password`, `database`
- Judge Redis: `password`

### 13.2 IAM

Worker execution role:

- AmazonECSTaskExecutionRolePolicy
- 위 Secret ARN에 대한 `secretsmanager:GetSecretValue`

Worker task role:

- 기본 AWS API 권한 없음
- ECS Exec 권한 없음
- 향후 S3 또는 다른 AWS API 접근이 필요하면 별도 설계와 테스트 후 추가

Worker instance role:

- AmazonEC2ContainerServiceforEC2Role
- AmazonSSMManagedInstanceCore

권한은 wildcard Secret ARN을 사용하지 않고 구체적인 리소스로 제한한다.

## 14. Task Definition

- family: `cosmos-v2-prod-judge-worker`
- compatibility: EC2
- network mode: `awsvpc`
- CPU: `2048`
- memory: `2048`
- image: private ECR URL + digest
- essential: true
- privileged: true
- readonly root filesystem: true
- writable `/tmp` ephemeral volume
- CloudWatch `awslogs`
- health check: `/app/healthcheck.sh`
- health interval: 30초
- health timeout: 5초
- health retries: 3회
- health start period: 60초
- stop timeout: 120초

환경 변수:

```text
POSTGRES_HOST=judge-postgres
POSTGRES_PORT=5432
REDIS_HOST=judge-redis
REDIS_PORT=6379
```

Secret 주입:

```text
JUDGE_WORKER_SECRET_JSON
POSTGRES_USER
POSTGRES_PASSWORD
POSTGRES_DB
REDIS_PASSWORD
```

## 15. ECS Service와 배포

- desired count 기본값: 1
- 허용 범위: 1~8
- 실제 상한: `1 + worker_spot_max_size`
- deployment minimum healthy percent: 0%
- deployment maximum percent: 100%
- deployment circuit breaker: enable
- rollback: enable
- assign public IP: false
- private subnet 2개
- Worker Task SG만 연결
- Service Connect client 활성화
- ECS Exec 비활성화
- placement constraint: `distinctInstance`

Worker 하나가 EC2 CPU 전체를 예약하므로 새 revision을 동시에 같은 호스트에 실행할 수 없다. 배포는 stop-before-start 방식으로 짧은 Worker 공백을 허용한다. Queue는 보존되며 새 Worker가 시작된 뒤 처리를 재개한다.

Deployment circuit breaker는 새 Task가 정상 상태가 되지 못하면 이전 Task Definition revision으로 rollback한다. CI/CD에서 안정 revision을 판별하고 자동 배포를 제어하는 기능은 3차 범위다.

## 16. 작업 멱등성과 종료 계약

Worker는 중단을 정상 운영 사건으로 처리해야 한다.

- submission ID를 멱등성 key로 사용
- 처리 시작과 완료 상태를 PostgreSQL에 기록
- Queue 메시지는 결과 저장 성공 후 ack
- visibility timeout 또는 lease 만료 시 재처리 가능
- 동일 submission 재수신 시 완료 상태를 확인하고 중복 결과 생성 방지
- `SIGTERM` 수신 시 새 작업 수신 중단
- 현재 작업이 120초 이내 완료되지 않으면 재처리 가능한 상태로 반환

Terraform은 이 애플리케이션 동작을 구현하지 않는다. 운영 활성화 전 image 계약 확인 항목으로 강제한다.

## 17. Spot interruption 처리

1. EC2가 Spot interruption 또는 rebalance recommendation을 받는다.
2. ECS agent가 container instance를 `DRAINING`으로 전환한다.
3. Worker가 `SIGTERM`을 받고 새 Queue 작업 수신을 중단한다.
4. 현재 작업을 완료하거나 재처리 상태로 반환한다.
5. ECS가 대체 Spot 용량을 요청한다.
6. Spot을 확보하지 못해도 On-Demand Worker 1대는 계속 처리한다.

Spot 손실은 정상적인 가용 용량 감소로 취급하며 데이터 손실로 이어지면 안 된다.

## 18. 수동 확장과 축소

2차 보완에서는 `judge_worker_desired_count` 변수로 수동 조절한다.

- `1`: On-Demand Worker만 실행
- `2~8`: 첫 Worker는 On-Demand, 나머지는 Spot
- 축소 전 Queue 적체와 실행 중 작업 확인
- 급격한 축소보다 단계적 축소 권장
- Spot 공급 부족 시 Task가 `PENDING`일 수 있음

`judge_worker_desired_count`가 `1 + worker_spot_max_size`를 초과하면 Terraform precondition이 실패해야 한다.

## 19. 로그와 관측 연계

이번 단계에서는 `/ecs/cosmos-v2-prod/judge-worker` CloudWatch Log Group만 생성하고 기존 retention 기본값을 사용한다.

다음 지표와 alarm은 3차에서 설계한다.

- Redis Queue 길이와 oldest message age
- Worker 처리 성공/실패/timeout 수
- E2E 처리 시간과 p95
- ECS running/pending task 수
- Capacity Provider reservation
- ASG desired/in-service/pending instance 수
- Spot interruption 및 rebalance 수
- Worker CPU/memory

## 20. 변수

| 변수 | 기본값 | 제약 |
| --- | --- | --- |
| `enable_judge_worker_capacity` | `false` | Worker보다 먼저 활성화 |
| `enable_judge_worker` | `false` | capacity와 digest 준비 필요 |
| `judge_image_digest` | `null` | Judge API·Worker 활성화 시 lowercase SHA-256 |
| `judge_worker_cpu` | `2048` | 초기 운영 고정 |
| `judge_worker_memory` | `2048` | 초기 운영 고정 |
| `judge_worker_desired_count` | `1` | 1~8, Spot 상한 연동 |
| `worker_on_demand_instance_type` | `c7i.large` | 2 vCPU, 4GiB |
| `worker_spot_instance_types` | `c7i.large`, `c6i.large`, `c6a.large` | X86_64 2 vCPU, 4GiB |
| `worker_spot_max_size` | `7` | 4~7 |
| `worker_root_volume_size` | `50` | 최소 30GiB |

## 21. Output

비민감 식별자만 출력한다.

- Judge 공용 ECR repository URL/ARN
- Worker Secret ARN
- On-Demand/Spot ASG 이름과 ARN
- On-Demand/Spot Capacity Provider 이름
- Worker Task Definition ARN
- Worker ECS Service 이름
- Worker Security Group ID
- Worker Log Group 이름

Worker Service가 비활성일 때 Task Definition과 Service output은 빈 map 또는 `null`을 반환한다.

## 22. Preflight

기존 `scripts/preflight.sh`를 Worker 항목까지 확장하거나 Worker 전용 mode를 제공한다. 다음 조건 중 하나라도 충족하지 않으면 Worker 활성화를 중단한다.

- Terraform Cloud workspace/state 조회 실패
- v2 state에서 v1 전용 resource address 발견
- Judge 공용 ECR digest 없음
- Worker, PostgreSQL, Redis Secret의 `AWSCURRENT` version 없음
- `WORKER_IMAGE_CONTRACT_VERIFIED=true` 누락
- `WORKER_SIGTERM_VERIFIED=true` 누락
- `WORKER_SANDBOX_VERIFIED=true` 누락
- On-Demand ECS container instance가 `ACTIVE`가 아님
- Capacity Provider가 `ACTIVE`가 아님

Preflight는 Secret 값을 출력하지 않고 `terraform apply`를 호출하지 않는다.

## 23. Terraform 테스트

Native mock test로 다음 계약을 검증한다.

1. Worker capacity와 Service 기본 비활성
2. On-Demand ASG `1/1/1`
3. Spot ASG `0/0/7`
4. Spot 최대 크기 4~7 validation
5. Spot mixed instance 후보와 allocation strategy
6. public IP, SSH key, ingress 부재
7. IMDSv2와 encrypted gp3 root volume
8. Spot draining, capacity rebalance, termination protection
9. Cluster Capacity Provider 세 개와 기본 Fargate 유지
10. Worker strategy base On-Demand 1, 추가 Spot
11. Worker Task CPU/memory 2048/2048
12. privileged Worker에만 적용
13. readonly root와 writable `/tmp`
14. private ECR digest
15. Secret ARN/key reference
16. Worker Task SG의 PostgreSQL/Redis/DNS egress만 허용
17. Worker의 ALB, Target Group, public ingress 부재
18. desired count 기본 1과 상한 precondition
19. 배포 0/100과 circuit breaker rollback
20. ECS Exec 비활성
21. 실제 Secret value/version 부재
22. 기존 1·2차 native test 회귀 통과

## 24. 구축 및 활성화 순서

1. Judge 공용 ECR, Worker Secret metadata, IAM, SG, Log Group 확인
2. `enable_judge_worker_capacity=true` plan 검토
3. Launch Template, ASG, Capacity Provider 생성
4. On-Demand container instance `ACTIVE` 확인
5. Worker image build, scan, ECR push와 digest 확정
6. Worker/DB/Redis Secret version 확인
7. image healthcheck, sandbox, `SIGTERM` 계약 검증
8. Worker preflight 실행
9. `enable_judge_worker=true`, desired count 1 plan 검토
10. Worker Service 적용 및 On-Demand 배치 확인
11. Queue consume, DB 저장, health, 재처리 smoke test
12. desired count 2로 일시 변경해 Spot 기동 검증
13. interruption/draining 검증 후 desired count 1로 복원
14. 최종 `terraform plan -detailed-exitcode` 멱등성 확인

실제 plan에 기존 RDS, EBS, 상태 저장 EC2의 delete 또는 replacement가 포함되면 적용하지 않는다.

## 25. 장애 및 복구

### 25.1 On-Demand Worker 장애

- ASG가 대체 EC2를 생성한다.
- 새 container instance가 Cluster에 등록된다.
- ECS Service가 Worker Task를 재배치한다.
- 처리 중이던 작업은 Queue와 DB 상태를 기준으로 재처리한다.

### 25.2 Spot 공급 부족

- 추가 Worker Task는 `PENDING`일 수 있다.
- On-Demand Worker 1대가 처리를 계속한다.
- Queue 적체를 관찰하고 필요하면 desired count를 낮추거나 승인된 instance 후보를 추가한다.
- 임의로 Spot 외 On-Demand 최대치를 늘리지 않는다.

### 25.3 잘못된 Worker revision

- ECS deployment circuit breaker가 이전 Task Definition으로 rollback한다.
- Queue 적체와 실패 submission을 확인한다.
- 실패 revision은 재사용하지 않고 새 digest로 수정 배포한다.

## 26. 3차 연계

2차 보완 완료 후 3차에서 다음을 연결한다.

1. 애플리케이션과 Terraform CI/CD
2. image scan 및 digest 기반 배포 승인
3. 배포 상태 확인과 안정 revision rollback 자동화
4. CloudWatch dashboard와 alarm
5. Redis Queue metric 수집
6. Queue 길이 및 oldest message age 기반 Worker Service Auto Scaling
7. On-Demand/Spot 용량과 비용 경보
8. Spot interruption 및 Worker timeout 경보

3차는 이번 문서의 변수, Capacity Provider, output과 preflight 계약을 변경하지 않고 자동화 계층으로 사용한다.
