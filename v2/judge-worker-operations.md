# Judge Worker 운영 절차

이 문서는 `cosmos-v2-prod`의 Judge Worker 전용 ECS Capacity Provider를 안전하게 활성화하고 수동 확장·복구하는 절차를 정의한다. Queue 지표 기반 자동 확장과 CI/CD 자동 rollback은 3차 범위다.

## 1. 운영 원칙

- Worker capacity와 Worker Service는 분리해서 배포한다.
- 첫 Worker 한 개는 On-Demand ASG에서 실행한다.
- 두 번째 Worker부터는 Spot ASG에서 실행한다.
- 운영 기본 desired count는 1이고 Spot 검증 뒤에도 1로 복원한다.
- Worker는 public IP, ALB, ECS Exec을 사용하지 않는다.
- Terraform은 Secret metadata만 관리한다. 실제 Secret 값과 version은 운영자가 별도로 등록한다.
- image는 tag가 아니라 ECR digest로만 배포한다.
- Worker 작업은 submission ID 기준 멱등성을 보장하고, 결과 저장이 끝난 뒤에만 Queue 메시지를 ack해야 한다.

## 2. capacity 선행 활성화

먼저 다음 변수만 적용한다.

```hcl
enable_judge_worker_capacity = true
enable_judge_worker          = false
```

plan에서 다음 항목만 추가되는지 확인한다.

- Worker instance role/profile와 Launch Template
- On-Demand ASG `min/desired/max = 1/1/1`
- Spot ASG `min/desired/max = 0/0/7`
- 두 ECS Capacity Provider
- Judge 공용 ECR, Security Group, Log Group, IAM role

기존 RDS, EBS, 상태 저장 EC2에 destroy 또는 replacement가 표시되면 적용하지 않는다. 적용 후 ECS Cluster에서 On-Demand container instance와 두 Capacity Provider가 `ACTIVE`인지 확인한다.

## 3. image와 Secret 준비

Worker image에는 다음 계약이 구현되어 있어야 한다.

- Worker Task Definition은 존재하지 않는 `/app/healthcheck.sh`를 호출하지 않는다. essential process와 ECS Service 상태, 실제 Queue smoke test로 동작을 판단한다.
- `SIGTERM`을 받으면 새 작업 수신을 중단하고 진행 중 작업을 120초 안에 완료하거나 재처리 가능 상태로 돌린다.
- privileged 실행이 필요한 sandbox 범위를 애플리케이션 수준에서 제한한다.
- submission ID를 멱등성 key로 사용한다.

Judge API와 Worker가 공유하는 image를 `cosmos-v2/judge`에 push하고 확정된 `sha256:` digest를 기록한다. Worker는 `/cosmos-v2/prod/judge-api`의 `secret_key_base`를 `SECRET_KEY_BASE`로 공유한다. Judge PostgreSQL Secret에는 `username`, `password`, `database`, Judge Redis Secret에는 `password` key와 `AWSCURRENT` version이 있어야 한다.

Secret 값은 Terraform 변수, tfvars, plan 파일, 로그에 기록하지 않는다.

## 4. Worker preflight

기존 애플리케이션 preflight 환경 변수에 다음 값을 추가하고 `CHECK_JUDGE_WORKER=true`로 실행한다.

```bash
export CHECK_JUDGE_WORKER=true
export ECS_CLUSTER_NAME=cosmos-v2-prod-cluster
export WORKER_ON_DEMAND_CAPACITY_PROVIDER=cosmos-v2-prod-judge-worker-on-demand
export WORKER_SPOT_CAPACITY_PROVIDER=cosmos-v2-prod-judge-worker-spot
export WORKER_IMAGE_CONTRACT_VERIFIED=true
export WORKER_SIGTERM_VERIFIED=true
export WORKER_SANDBOX_VERIFIED=true
bash v2/scripts/preflight.sh
```

preflight는 공용 Judge ECR digest, Judge API/DB/Redis `AWSCURRENT`, 운영 확인 세 항목, On-Demand container instance, Capacity Provider, Terraform state를 검사한다. Secret 값은 조회하지 않는다.

## 5. Worker 한 개 배포

preflight 통과 후 다음 변수로 plan을 검토한다.

```hcl
enable_judge_worker_capacity = true
enable_judge_worker          = true
judge_image_digest           = "sha256:..."
judge_worker_desired_count   = 1
```

Task Definition이 EC2/awsvpc, CPU 2048, memory 2048, privileged, writable root, `/tmp` volume으로 생성되는지 확인한다. 시작 스크립트가 `/api/environment`와 `/api/tmp`에 쓸 수 있어야 한다. Service의 첫 Task가 On-Demand Capacity Provider에 배치되고 정상 상태가 된 뒤 Queue consume, PostgreSQL 결과 저장, Redis 상태 갱신을 확인한다.

## 6. Spot 확장 검증

`judge_worker_desired_count = 2`로 plan/apply한다. 두 번째 Task가 Spot Capacity Provider에 배치되고 Spot ASG가 한 대를 기동하는지 확인한다. 동일 submission 재전송 시 중복 결과가 생기지 않는지 검증한다.

검증이 끝나면 `judge_worker_desired_count = 1`로 복원한다. Spot Task가 종료되고 Spot ASG가 0대로 축소되는 동안 On-Demand Task 한 개가 계속 정상인지 확인한다.

수동 확장 시 desired count는 `1 + worker_spot_max_size`를 넘길 수 없다. 기본 상한은 8이다.

## 7. Spot interruption과 Queue 재처리

Spot interruption 또는 rebalance recommendation이 발생하면 ECS managed draining이 instance를 `DRAINING`으로 전환한다. Worker는 `SIGTERM`을 받아 새 작업을 중단해야 한다.

운영자는 다음을 확인한다.

1. 진행 중 메시지가 ack되지 않은 채 visibility timeout 또는 lease 만료 후 다시 보이는지 확인한다.
2. 새 Spot Task 또는 On-Demand Task가 해당 메시지를 다시 처리하는지 확인한다.
3. PostgreSQL 완료 상태를 확인해 중복 결과를 만들지 않는지 확인한다.
4. Redis 임시 상태가 최종 PostgreSQL 상태와 모순되지 않는지 확인한다.

반복 실패 메시지는 애플리케이션의 retry/DLQ 정책에 따라 격리한다. 이 정책은 Terraform Capacity Provider가 대신 보장하지 않는다.

## 8. 잘못된 revision rollback

새 revision이 health check를 통과하지 못하면 ECS deployment circuit breaker가 직전 정상 revision으로 rollback한다. 배포 이벤트와 `/ecs/cosmos-v2-prod/judge-worker` 로그에서 실패 원인을 확인한다.

자동 rollback이 완료되지 않으면 마지막 정상 digest를 `judge_image_digest`에 다시 지정해 plan/apply한다. mutable tag나 임의의 최신 image로 복구하지 않는다.

## 9. 장애 복구

- On-Demand instance 미등록: ASG instance 상태, Launch Template version, instance role, private subnet NAT 경로, host SG의 DNS/HTTPS egress를 확인한다.
- Capacity Provider 비활성: ASG ARN 연결, managed scaling, managed termination protection, ASG `protect_from_scale_in`을 확인한다.
- Task image pull 실패: ECR digest 존재 여부와 execution role을 확인한다.
- Task Secret 주입 실패: Judge API/PostgreSQL/Redis Secret의 `AWSCURRENT`와 execution role의 구체 ARN 권한을 확인한다.
- 데이터 연결 실패: Worker Task SG에서 PostgreSQL 5432, Redis 6379, VPC DNS 53만 허용되는지 확인한다.
- 처리 정체: desired count를 상한 안에서 수동 확장하고 Queue backlog와 실패율을 함께 관찰한다.

capacity를 끄기 전에는 반드시 `enable_judge_worker=false`로 Service를 먼저 제거한다. Worker가 남아 있는 상태에서 capacity만 끄는 구성은 Terraform check가 거부한다.

## 10. 3차 연계 항목

3차에서는 Queue backlog 기반 Service Auto Scaling, 배포 파이프라인의 안정 revision 판별, 자동 rollback 알림, CloudWatch 대시보드와 경보를 추가한다. 최소 관측 항목은 Queue backlog/oldest age, Worker desired/running/pending, ASG desired/in-service/pending, Spot interruption/rebalance, Worker CPU/memory, 처리 성공·실패율이다.
