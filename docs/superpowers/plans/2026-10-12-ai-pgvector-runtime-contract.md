# COSMOS v2 AI PostgreSQL 및 ECS 런타임 계약 보완 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI 전용 PostgreSQL 17+pgvector를 ECS on EC2로 추가하고 Spring·FastAPI·Judge의 ECS 런타임 계약을 실제 애플리케이션 설정과 일치시킨다.

**Architecture:** 기존 상태 저장 서비스의 전용 EC2·암호화 gp3 EBS·Service Connect 패턴에 `ai-postgres`를 추가한다. Spring/FastAPI/Judge API는 Fargate 1개씩 유지하면서 key 단위 Secret 주입, 내부 Service Connect 주소, 최소 SG/IAM 권한을 사용한다. 모든 활성화 flag의 기본값은 `false`로 유지하고, 기존 리소스의 destroy/replace가 없는 실제 Stage plan만 적용한다.

**Tech Stack:** Terraform 1.16.x, AWS Provider 5.100.0, Amazon ECS, EC2, EBS, AWS Cloud Map/Service Connect, Secrets Manager, IAM, CloudWatch Logs, DLM, Bash

**Spec:** `docs/superpowers/specs/2026-10-12-ai-pgvector-runtime-contract-design.md`

## Global Constraints

- AWS region은 `ap-northeast-2`다.
- Spring, FastAPI, Judge API는 Fargate Task를 각각 1개만 실행한다.
- AI PostgreSQL, Judge PostgreSQL, Judge Redis는 서비스별 전용 EC2 1대와 보존형 암호화 gp3 EBS 1개를 사용한다.
- AI PostgreSQL database와 Spring RDS MySQL database 이름은 모두 `cosmos`다.
- Backend Valkey는 인프라만 보존하고 Spring Task Definition 및 SG에 연결하지 않는다.
- 모든 컨테이너 이미지는 `^[^[:space:]]+@sha256:[0-9a-f]{64}$` 형식으로 고정한다.
- Secret metadata만 Terraform으로 만들고 Secret value/version은 Terraform state에 저장하지 않는다.
- AI PostgreSQL은 ALB, public IP, public DNS를 갖지 않는다.
- 활성화 flag의 기본값은 모두 `false`이고 image digest와 Secret `AWSCURRENT` 준비 후에만 `true`로 변경한다.
- 기존 RDS, Valkey, Judge EBS/EC2의 destroy 또는 replace가 포함된 plan은 적용하지 않는다.
- 코드와 문서는 한국어 운영 문맥을 유지한다.
- Git commit과 push는 수행하지 않는다. 사용자가 직접 커밋한다.

## Review Focus

- `enable_stateful_services=false`일 때 AI/Judge Task Definition과 Service는 0개지만 데이터 기반 EC2/EBS는 보존되어야 한다. Task 2의 비활성 fixture로 고정한다.
- `ai_postgres_image`가 null, tag-only, 대문자 digest이면 상태 저장 활성 plan을 거부해야 한다. Task 1의 validation fixture로 고정한다.
- Secret의 선택 key를 필수 참조해서 Task 시작을 막지 않아야 하며, 필수 key는 개별 환경 변수로만 주입해야 한다. Task 3의 container definition assertion으로 고정한다.
- AI PostgreSQL은 FastAPI SG에서만 5432를 허용하고 Spring은 FastAPI SG에서만 8080을 허용해야 한다. Task 3의 SG source assertion으로 고정한다.
- 기존 Stage 리소스 주소 변경으로 RDS·Valkey·Judge EBS/EC2가 교체되지 않아야 한다. Task 6의 실제 HCP Terraform plan 검토 게이트로 고정한다.

---

### Task 1: AI PostgreSQL 입력·Secret·로컬 계약 추가

**Files:**
- Modify: `v2/modules/environment/variables.tf`
- Modify: `v2/modules/environment/locals.tf`
- Modify: `v2/modules/environment/secrets.tf`
- Modify: `v2/modules/environment/tests/phase-2-data.tftest.hcl`
- Modify: `v2/modules/environment/tests/phase-2-stateful.tftest.hcl`

**Interfaces:**
- Consumes: 기존 `enable_stateful_services`, `local.secret_names`, `local.stateful_services` 패턴
- Produces: nullable string 변수 `var.ai_postgres_image`, secret key `ai-postgres`, stateful service key `ai-postgres`(port 5432, volume `/var/lib/postgresql/data`, database `cosmos`)

- [ ] **Step 1: AI PostgreSQL 입력 및 Secret 실패 테스트 작성**

`phase-2-data.tftest.hcl`에서 Secret 수가 7개이고 `/cosmos-v2/test/ai-postgres`가 포함되는지 단언한다. `phase-2-stateful.tftest.hcl`에 상태 저장 활성화 시 `ai_postgres_image=null`, `pgvector/pgvector:pg17`, 대문자 digest가 각각 validation 실패하는 command=`plan` run을 추가한다.

- [ ] **Step 2: 신규 테스트의 실패 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-data.tftest.hcl -filter=tests/phase-2-stateful.tftest.hcl -no-color`

Expected: `ai_postgres_image`, `ai-postgres` Secret 또는 세 번째 상태 저장 서비스가 없어 FAIL.

- [ ] **Step 3: 변수와 로컬 계약 구현**

`variables.tf`에 `ai_postgres_image`를 추가하고 상태 저장 활성화 시에만 lowercase sha256 digest를 요구한다. `locals.tf`의 secret 목록과 stateful map에 `ai-postgres`를 추가하며 Service Connect 이름은 `ai-postgres`, container port는 `5432`, EBS mount는 `/var/lib/postgresql/data`, health command는 `pg_isready -U "$POSTGRES_USER" -d cosmos`로 고정한다. `secrets.tf`는 기존 map 기반 metadata 생성 방식을 그대로 사용한다.

- [ ] **Step 4: Task 1 테스트 통과 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-data.tftest.hcl -filter=tests/phase-2-stateful.tftest.hcl -no-color`

Expected: PASS. Secret value/version resource는 여전히 0개다.

### Task 2: AI PostgreSQL 전용 EC2·EBS·Task·Service 구현

**Files:**
- Modify: `v2/modules/environment/ecs-container-instances.tf`
- Modify: `v2/modules/environment/judge-stateful-services.tf`
- Modify: `v2/modules/environment/application-iam.tf`
- Modify: `v2/modules/environment/logging.tf`
- Modify: `v2/modules/environment/backups.tf`
- Modify: `v2/modules/environment/tests/phase-2-stateful.tftest.hcl`

**Interfaces:**
- Consumes: Task 1의 `local.stateful_services["ai-postgres"]`, `var.ai_postgres_image`, `aws_secretsmanager_secret.service["ai-postgres"]`
- Produces: `aws_instance.stateful["ai-postgres"]`, `aws_ebs_volume.stateful["ai-postgres"]`, AI Task Definition/Service, 전용 execution role, log group, 7일 DLM 대상

- [ ] **Step 1: 세 번째 상태 저장 서비스 테스트 작성**

활성 fixture에 digest-pinned `ai_postgres_image`를 전달하고 EC2/EBS/Task Definition/Service가 각각 3개인지 단언한다. AI container에는 `POSTGRES_DB=cosmos`, Secret key `username→POSTGRES_USER`, `password→POSTGRES_PASSWORD`, mount path `/var/lib/postgresql/data`가 존재하고 public/ALB 리소스가 없는지 확인한다. 비활성 fixture에서는 Task Definition/Service가 0개인지 확인한다.

- [ ] **Step 2: 신규 상태 저장 테스트 실패 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-stateful.tftest.hcl -no-color`

Expected: AI image/secret/container 분기가 구현되지 않아 FAIL.

- [ ] **Step 3: generic stateful 리소스에 AI 분기 구현**

기존 `for_each=local.stateful_services` EC2/EBS/IAM/log/DLM 생성을 확장하되 Judge 주소 키는 변경하지 않는다. `judge-stateful-services.tf`의 container definition을 서비스별 계약으로 분리해 AI는 pgvector image, `POSTGRES_DB=cosmos`, 두 Secret key와 health check를 사용한다. placement constraint는 `attribute:cosmos.stateful-service == ai-postgres`를 사용하고 Service Connect alias `ai-postgres:5432`를 제공한다.

- [ ] **Step 4: 상태 저장 테스트 통과 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-stateful.tftest.hcl -no-color`

Expected: PASS. 활성 시 AI 포함 3개, 비활성 시 Task/Service 0개다.

### Task 3: Spring·FastAPI·Judge API 런타임 계약 및 네트워크 보정

**Files:**
- Modify: `v2/modules/environment/locals.tf`
- Modify: `v2/modules/environment/ecs-task-definitions.tf`
- Modify: `v2/modules/environment/ecs-services.tf`
- Modify: `v2/modules/environment/application-security.tf`
- Modify: `v2/modules/environment/application-iam.tf`
- Modify: `v2/modules/environment/alb.tf`
- Modify: `v2/modules/environment/tests/phase-2-fargate.tftest.hcl`
- Modify: `v2/modules/environment/tests/phase-2-data.tftest.hcl`

**Interfaces:**
- Consumes: AI Secret ARN, RDS address, Service Connect aliases `spring`, `fastapi`, `judge-api`, `ai-postgres`, `judge-postgres`, `judge-redis`
- Produces: 실제 앱이 읽는 environment/secrets JSON, Spring Service Connect server `spring:8080`, FastAPI→AI 5432 및 FastAPI→Spring 8080 SG, Spring health path `/api/actuator/health`

- [ ] **Step 1: 런타임 계약 실패 테스트 작성**

Spring의 JDBC URL·`AI_SERVER_BASE_URL`·`JUDGE0_BASE_URL`과 6개 Secret mapping, FastAPI의 `DB_HOST=ai-postgres`·`DB_NAME=cosmos`·`BACKEND_URL=http://spring:8080/api`·`JUDGE0_URL`, AI DB/Gemini Secret mapping을 단언한다. Judge API의 `SECRET_KEY_BASE` key 주입과 writable root를 단언한다. legacy `FASTAPI_SECRET_JSON`, `JUDGE_API_SECRET_JSON`, `DATABASE_URL`, `JUDGE_API_URL`, Spring Valkey 변수가 모두 없는지 확인한다.

- [ ] **Step 2: Service Connect·SG·health 실패 테스트 작성**

Spring server port name/alias가 `spring:8080`, ALB health path가 `/api/actuator/health`인지 단언한다. AI DB SG ingress source가 FastAPI SG 하나이고, Spring 8080 ingress source가 FastAPI SG인지, Backend Valkey에 Spring ingress가 없는지 확인한다. FastAPI execution role Secret ARN 목록은 `fastapi`, `ai-postgres`만 포함해야 한다.

- [ ] **Step 3: Fargate 계약 테스트 실패 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-fargate.tftest.hcl -filter=tests/phase-2-data.tftest.hcl -no-color`

Expected: 기존 legacy 변수·Secret, health path, SG/IAM 계약 때문에 FAIL.

- [ ] **Step 4: Fargate container definition과 Service Connect 구현**

`ecs-task-definitions.tf`에서 서비스별 비민감 environment와 JSON-key Secret 배열을 설계 문서 값 그대로 구성한다. Spring/FastAPI는 read-only root를 유지하고 Judge API만 `readonlyRootFilesystem=false`로 둔다. `locals.tf`에서 Spring server를 활성화하고 health path를 변경한다.

- [ ] **Step 5: 최소 SG/IAM 구현**

`application-security.tf`에 `ai-postgres` SG와 FastAPI source 5432 ingress, Spring SG의 FastAPI source 8080 ingress를 추가하고 Spring→Valkey ingress를 제거한다. `application-iam.tf`에서 FastAPI execution role은 `fastapi`와 `ai-postgres`, AI DB execution role은 `ai-postgres` Secret만 읽게 한다.

- [ ] **Step 6: Task 3 테스트 통과 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-fargate.tftest.hcl -filter=tests/phase-2-data.tftest.hcl -no-color`

Expected: PASS. legacy 환경 변수/Secret 이름은 생성된 container JSON에 존재하지 않는다.

### Task 4: Judge Worker 실제 런타임 계약 보정

**Files:**
- Modify: `v2/modules/environment/judge-worker.tf`
- Modify: `v2/modules/environment/tests/phase-2-worker.tftest.hcl`

**Interfaces:**
- Consumes: Judge API/PostgreSQL/Redis Secret metadata와 기존 EC2 Capacity Provider
- Produces: writable Judge Worker root, 개별 Secret key, `COUNT=2`, `INTERVAL=0.1`, invalid health check가 없는 Worker Task Definition

- [ ] **Step 1: Worker 실패 테스트 작성**

Worker container JSON에 `SECRET_KEY_BASE`, PostgreSQL username/password/database, Redis password가 key별로 주입되고 `JUDGE_WORKER_SECRET_JSON`은 없는지 단언한다. `readonlyRootFilesystem=false`, healthCheck attribute 없음, privileged=true, `COUNT=2`, `INTERVAL=0.1`도 함께 확인한다.

- [ ] **Step 2: Worker 테스트 실패 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-worker.tftest.hcl -no-color`

Expected: 기존 JSON Secret, read-only root, `/app/healthcheck.sh` 때문에 FAIL.

- [ ] **Step 3: Worker Task Definition 구현**

`judge-worker.tf`에서 개별 JSON key ARN을 실제 환경 변수 이름으로 매핑하고 writable root로 변경한다. 존재하지 않는 container health check를 제거하되 essential process와 ECS Service 상태 검증은 유지한다.

- [ ] **Step 4: Worker 테스트 통과 확인**

Run: `terraform -chdir=v2/modules/environment test -filter=tests/phase-2-worker.tftest.hcl -no-color`

Expected: PASS.

### Task 5: Stage/Prod 입력, preflight, 운영 문서 동기화

**Files:**
- Modify: `v2/environments/stage/main.tf`
- Modify: `v2/environments/stage/variables.tf`
- Modify: `v2/environments/prod/main.tf`
- Modify: `v2/environments/prod/variables.tf`
- Modify: `v2/scripts/preflight.sh`
- Modify: `v2/tests/preflight_test.sh`
- Modify: `v2/tests/layout_test.sh`
- Modify: `v2/architecture.md`
- Modify: `v2/phase-2-architecture.md`
- Modify: `v2/stage-operations.md`
- Modify: `v2/stateful-recovery.md`
- Modify: `v2/judge-worker-operations.md`

**Interfaces:**
- Consumes: module input `ai_postgres_image`, AI Secret ARN output map, Task 1~4의 런타임 계약
- Produces: Stage/Prod root passthrough, AI image·Secret preflight, 한국어 배포/마이그레이션/복구 절차

- [ ] **Step 1: root passthrough와 preflight 실패 테스트 작성**

`layout_test.sh`에 Stage/Prod 모두 `ai_postgres_image = var.ai_postgres_image`인지 검사하고 legacy JSON Secret 이름 금지를 추가한다. `preflight_test.sh` fixture에 `AI_POSTGRES_IMAGE`와 환경별 `AI_POSTGRES_SECRET_ARN`을 추가하며 tag-only image, 다른 환경 ARN, `AWSCURRENT` 누락이 각각 실패하는지 검사한다. 기존 `VALKEY_IAM_AUTH_VERIFIED`는 애플리케이션 미연결 범위이므로 요구하지 않는 성공 fixture를 추가한다.

- [ ] **Step 2: script 테스트 실패 확인**

Run: `bash v2/tests/layout_test.sh && bash v2/tests/preflight_test.sh`

Expected: root 변수와 AI preflight가 없어 FAIL.

- [ ] **Step 3: Stage/Prod 및 preflight 구현**

두 root에 nullable `ai_postgres_image` 변수와 module passthrough를 동일하게 추가한다. `preflight.sh`는 AI image digest, `/cosmos-v2/{environment}/ai-postgres` ARN, `AWSCURRENT`만 검사하고 Secret value를 읽거나 출력하지 않는다. Backend Valkey 애플리케이션 연결 attestation은 제거한다.

- [ ] **Step 4: 한국어 운영 문서 갱신**

아키텍처 문서에 AI PostgreSQL 전용 EC2/EBS와 Fargate 연결을 반영한다. Stage 운영 문서에는 gitignored `stage.auto.tfvars`, Secret key 계약, stateful→Alembic one-off→Judge API→FastAPI→Spring→Worker 순서, Valkey 미연결 상태를 기록한다. 복구 문서에는 AI EBS snapshot 복구와 migration 실패 시 FastAPI 비활성 절차를 추가한다. Judge 문서의 legacy Worker Secret/read-only 설명을 실제 계약으로 교체한다.

- [ ] **Step 5: Task 5 테스트 통과 확인**

Run: `bash -n v2/scripts/preflight.sh && bash -n v2/tests/preflight_test.sh && bash v2/tests/layout_test.sh && bash v2/tests/preflight_test.sh`

Expected: PASS. Secret 값은 어떤 출력에도 나타나지 않는다.

### Task 6: 전체 회귀 검증과 Stage 기반 리소스 적용

**Files:**
- Verify: `v2/**`
- Verify: `docs/superpowers/specs/2026-10-12-ai-pgvector-runtime-contract-design.md`
- Verify: `docs/superpowers/plans/2026-10-12-ai-pgvector-runtime-contract.md`

**Interfaces:**
- Consumes: Task 1~5 전체 결과와 기존 HCP Terraform `KTB4-9th-Cloud-v2-stage` workspace
- Produces: 정적/모듈 테스트 결과, destroy/replace 없는 저장된 Stage plan, 안전한 기반 리소스 apply 결과

- [ ] **Step 1: 포맷과 전체 오프라인 회귀 검증**

Run: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2/modules/environment test -no-color && bash v2/tests/layout_test.sh && bash v2/tests/preflight_test.sh && git diff --check`

Expected: 모든 명령 exit 0. 기존 Stage/Prod 격리, frontend, ALB, Worker 테스트도 회귀 없이 통과한다.

- [ ] **Step 2: 금지 패턴 정적 검사**

Run: `! rg -n 'FASTAPI_SECRET_JSON|JUDGE_API_SECRET_JSON|JUDGE_WORKER_SECRET_JSON|JUDGE_API_URL|DATABASE_URL|VALKEY_HOST|VALKEY_PORT|/app/healthcheck.sh' v2/modules/environment --glob '*.tf'`

Expected: exit 0.

- [ ] **Step 3: 모든 활성화 flag=false로 실제 Stage plan 생성**

Run: `terraform -chdir=v2/environments/stage init && terraform -chdir=v2/environments/stage plan -var='enable_stateful_services=false' -var='enable_phase2_services=false' -var='enable_judge_worker_capacity=false' -var='enable_judge_worker=false' -out=stage-ai-foundation.tfplan`

Expected: AI Secret metadata, SG, IAM, log group, EC2, EBS, DLM 대상 같은 기반 추가만 계획되고 기존 RDS·Valkey·Judge EBS/EC2의 destroy/replace는 0개다.

- [ ] **Step 4: 실제 plan 안전 게이트 검토**

Run: `terraform -chdir=v2/environments/stage show -no-color stage-ai-foundation.tfplan`

Expected: 기존 리소스 destroy 또는 forced replacement가 하나라도 있으면 중단하고 원인을 수정한다. `ai-postgres`가 ALB/public IP/public DNS를 생성하지 않는지 확인한다.

- [ ] **Step 5: 저장된 안전한 기반 plan 적용**

Run: `terraform -chdir=v2/environments/stage apply stage-ai-foundation.tfplan`

Expected: AI 기반 리소스가 생성되고 상태 저장/application/Worker ECS Service는 아직 활성화되지 않는다. 실제 Secret 값과 application image 활성화는 운영 준비 후 별도 단계로 남는다.

- [ ] **Step 6: 최종 상태 및 사용자 커밋 경계 기록**

Run: `git status --short && git diff --stat && git diff --check`

Expected: 변경 파일과 생성 리소스 결과를 보고하되 commit/push는 하지 않는다.
