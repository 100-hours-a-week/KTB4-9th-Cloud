# Stage Central PLG Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 오레곤의 기존 PLG 서버에 서울 COSMOS V2 Stage의 AWS 지표와 로그를 연결하고, Grafana에서 실제 데이터가 표시되는 Stage 전용 대시보드를 제공한다.

**Architecture:** 기존 Docker Compose 기반 Prometheus, Loki, Grafana, Nginx는 유지한다. 오레곤 EC2에는 장기 Access Key 대신 최소 권한 IAM Instance Profile을 연결하고 Grafana CloudWatch datasource를 추가하여 Stage ECS, ALB, RDS, EC2 지표와 CloudWatch Logs를 우선 가시화한다. Alloy와 FireLens 직접 수집은 애플리케이션 task revision을 변경하는 독립 후속 작업으로 분리하며, 이번 계획에서는 안전한 HTTPS 수집 endpoint와 provisioning 기반만 준비한다.

**Tech Stack:** Terraform >= 1.7, AWS Provider 5.100.0, Amazon EC2/IAM/CloudWatch/ECS/ALB/RDS, Docker Compose, Grafana 11.1, Prometheus 3.15, Loki 3.1, Nginx 1.27, Bash, jq

**Spec:** `docs/superpowers/specs/2026-10-13-stage-central-plg-monitoring-design.md`

## Global Constraints

- 이번 구현 대상은 Stage뿐이며 Prod 수집기, 대시보드와 알림을 만들지 않는다.
- 기존 Dev 및 부하 테스트 대시보드, Prometheus 데이터와 Loki 데이터를 삭제하거나 덮어쓰지 않는다.
- `COSMOS-test-monitoring-server`의 기존 Docker Compose 운영 방식을 유지하고 이번 단계에서 ECS로 전환하지 않는다.
- Grafana datasource에 AWS Access Key와 Secret Key를 저장하지 않고 EC2 IAM Role의 default credential chain을 사용한다.
- Prometheus 9090과 Loki 3100을 인터넷에 직접 공개하지 않는다.
- Stage 애플리케이션의 CloudWatch Logs 전송은 유지한다.
- `t3.small` 검증 환경의 Prometheus 및 Loki 보존 기간은 7일로 제한한다.
- 사용자 요청에 따라 git commit과 push는 수행하지 않는다.
- 라이브 설정을 변경하기 전에 `/opt/monitoring` 설정, Grafana DB와 EBS 복구 지점을 확보한다.

## Review Focus

- EC2 IAM Role credential이 Grafana 컨테이너까지 전달되지 않는 경우 datasource health check가 실패해야 하며 장기 Access Key로 우회하지 않는다.
- 서울 `ap-northeast-2`와 오레곤 `us-west-2`의 리전 혼동이 없어야 하고 모든 Stage AWS query의 기본 리전은 서울이어야 한다.
- 기존 Grafana provider와 신규 Stage provider의 UID 및 폴더가 충돌하지 않아야 하고 기존 dashboard 수가 감소하지 않아야 한다.
- CloudWatch metric dimension에 실제 ClusterName, ServiceName, LoadBalancer, TargetGroup 값이 없을 때 패널은 가짜 0이 아니라 No data를 표시해야 한다.
- Nginx 설정 오류 또는 Grafana provisioning 오류가 있으면 reload/restart 전에 정적 검증에서 중단되어야 한다.

---

### Task 1: 기존 PLG 백업 및 배포 자산 구조 생성

**Files:**
- Create: `v2/monitoring/README.md`
- Create: `v2/monitoring/scripts/backup-remote.sh`
- Create: `v2/monitoring/scripts/validate-assets.sh`
- Create: `v2/monitoring/server/compose.override.yaml`
- Create: `v2/monitoring/server/nginx/stage-ingest.conf`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage-dashboards.yaml`

**Interfaces:**
- Consumes: SSH 접속 대상 `ubuntu@16.148.56.9`, 원격 경로 `/opt/monitoring`
- Produces: 날짜별 `/opt/monitoring-backups/<timestamp>/` 백업과 이후 task가 배포할 검증된 파일 트리

- [ ] **Step 1: 백업 스크립트의 실패 검증 작성**

`validate-assets.sh`가 필수 파일 누락, 잘못된 JSON, 잘못된 Nginx 설정 파일명을 각각 비정상 종료로 처리하는 shell test를 `v2/tests/monitoring_assets_test.sh`에 작성한다.

- [ ] **Step 2: 실패 검증 실행**

Run: `bash v2/tests/monitoring_assets_test.sh`

Expected: 아직 스크립트와 자산이 없어 FAIL.

- [ ] **Step 3: 백업 및 검증 스크립트 구현**

`backup-remote.sh`는 원격에서 다음 항목을 백업하고 원본을 변경하지 않는다.

- `/opt/monitoring/compose.yaml`
- `/opt/monitoring/prometheus/prometheus.yml`
- `/opt/monitoring/loki/loki-config.yaml`
- `/opt/monitoring/nginx/conf.d`
- `/opt/monitoring/grafana/provisioning`
- `/opt/monitoring/grafana/data/grafana.db`

`validate-assets.sh`는 `docker compose config`, `nginx -t`, `jq empty`와 YAML 파일 존재 여부를 검사한다.

- [ ] **Step 4: 자산 검증 통과 확인**

Run: `bash v2/tests/monitoring_assets_test.sh && bash v2/monitoring/scripts/validate-assets.sh`

Expected: PASS, exit code 0.

- [ ] **Step 5: 라이브 백업 생성과 확인**

Run: `bash v2/monitoring/scripts/backup-remote.sh`

Expected: 원격 백업 경로와 백업 파일 목록 출력, 현재 다섯 PLG 컨테이너 상태 유지.

### Task 2: 모니터링 EC2용 최소 권한 IAM 구성

**Files:**
- Create: `v2/modules/legacy-monitoring-access/versions.tf`
- Create: `v2/modules/legacy-monitoring-access/variables.tf`
- Create: `v2/modules/legacy-monitoring-access/main.tf`
- Create: `v2/modules/legacy-monitoring-access/outputs.tf`
- Create: `v2/modules/legacy-monitoring-access/tests/access.tftest.hcl`
- Create: `v2/environments/monitoring/versions.tf`
- Create: `v2/environments/monitoring/providers.tf`
- Create: `v2/environments/monitoring/main.tf`
- Create: `v2/environments/monitoring/variables.tf`
- Create: `v2/environments/monitoring/outputs.tf`
- Create: `v2/environments/monitoring/monitoring.auto.tfvars.example`

**Interfaces:**
- Consumes: Oregon instance ID `i-0021b7626e459a03f`, AWS account `352635536602`
- Produces: `cosmos-test-monitoring` IAM Role, Instance Profile, read-only policy와 EC2 profile association

- [ ] **Step 1: Terraform native test 작성**

다음 조건을 검증한다.

- EC2 trust principal만 허용
- CloudWatch metric read, Logs Insights read, ECS/EC2/ALB/RDS/ASG describe 권한만 허용
- 변경 권한과 `Resource = "*"`인 비조회 action 없음
- 대상 instance ID가 변수로 전달됨
- Instance Profile association이 생성됨

- [ ] **Step 2: 테스트가 구현 부재로 실패하는지 확인**

Run: `terraform -chdir=v2/modules/legacy-monitoring-access test`

Expected: resource가 없어 FAIL.

- [ ] **Step 3: 최소 권한 module 및 monitoring root 구현**

AWS Provider의 기본 리전은 `us-west-2`로 두고 Grafana query 대상 리전은 datasource에서 `ap-northeast-2`로 고정한다. HCP workspace 이름은 `KTB4-9th-Cloud-v2-monitoring`으로 정의한다.

- [ ] **Step 4: Terraform 검증**

Run: `terraform fmt -check -recursive v2/modules/legacy-monitoring-access v2/environments/monitoring`

Run: `terraform -chdir=v2/modules/legacy-monitoring-access test`

Run: `terraform -chdir=v2/environments/monitoring init && terraform -chdir=v2/environments/monitoring validate`

Expected: 모두 PASS.

- [ ] **Step 5: plan 검토 후 apply**

Run: `terraform -chdir=v2/environments/monitoring plan -out=monitoring-access.tfplan`

Expected: IAM Role, policy, Instance Profile과 association만 생성하고 EC2 교체·재부팅은 없음.

Run: `terraform -chdir=v2/environments/monitoring apply monitoring-access.tfplan`

Expected: association 완료.

- [ ] **Step 6: EC2 credential 검증**

원격 EC2에서 `aws sts get-caller-identity`와 서울 리전 CloudWatch `list-metrics`를 실행한다.

Expected: IAM Role session ARN과 서울 리전 metric 결과가 나오며 로컬 credential 파일을 만들지 않음.

### Task 3: Grafana CloudWatch datasource provisioning

**Files:**
- Create: `v2/monitoring/server/grafana/provisioning/datasources/stage-cloudwatch.yaml`
- Modify: `v2/monitoring/server/compose.override.yaml`
- Test: `v2/tests/monitoring_assets_test.sh`

**Interfaces:**
- Consumes: Task 2의 EC2 Instance Profile credential, Grafana provisioning mount
- Produces: UID `stage-cloudwatch`, default region `ap-northeast-2`인 CloudWatch datasource

- [ ] **Step 1: datasource contract test 추가**

YAML에 `type: cloudwatch`, `uid: stage-cloudwatch`, `authType: default`, `defaultRegion: ap-northeast-2`가 있고 access/secret key 필드가 없음을 검증한다.

- [ ] **Step 2: contract test 실패 확인**

Run: `bash v2/tests/monitoring_assets_test.sh`

Expected: datasource 파일 부재로 FAIL.

- [ ] **Step 3: datasource provisioning 구현**

기존 Prometheus와 Loki datasource 파일을 수정하지 않고 별도 datasource 파일을 추가한다.

- [ ] **Step 4: 정적 검증 통과 확인**

Run: `bash v2/tests/monitoring_assets_test.sh`

Expected: PASS.

- [ ] **Step 5: 라이브 서버 배포 및 Grafana 재시작**

신규 파일만 `/opt/monitoring/grafana/provisioning/datasources/`에 배포하고 `docker compose config` 검증 후 Grafana만 재시작한다.

- [ ] **Step 6: datasource health 확인**

Grafana API에서 UID `stage-cloudwatch`의 health endpoint를 조회한다.

Expected: HTTP 200과 성공 상태. 실패 시 Access Key를 추가하지 않고 EC2 IAM credential 전달과 IAM policy를 수정한다.

### Task 4: Stage Grafana 대시보드 생성

**Files:**
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/01-stage-overview.json`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/02-ecs-services.json`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/03-alb-http.json`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/04-databases.json`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/05-judge-worker.json`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/06-application-logs.json`
- Create: `v2/monitoring/server/grafana/provisioning/dashboards/stage/07-plg-self-monitoring.json`
- Test: `v2/tests/monitoring_dashboards_test.sh`

**Interfaces:**
- Consumes: datasource UID `stage-cloudwatch`, 기존 datasource UID `prometheus`와 Loki datasource UID
- Produces: 기존 dashboard UID와 충돌하지 않는 `cosmos-stage-*` UID 일곱 개

- [ ] **Step 1: dashboard contract test 작성**

각 JSON에 다음 조건을 검증한다.

- 고유한 `cosmos-stage-*` UID
- `environment=stage` 식별 정보
- CloudWatch query region `ap-northeast-2`
- 실제 Stage cluster/service/log group 이름
- datasource는 UID로 참조
- refresh 최소 30초
- No data를 0으로 변환하는 expression 없음
- Prod 문자열과 AWS 계정 비밀정보 없음

- [ ] **Step 2: JSON 부재로 test 실패 확인**

Run: `bash v2/tests/monitoring_dashboards_test.sh`

Expected: 일곱 파일 부재로 FAIL.

- [ ] **Step 3: 일곱 dashboard JSON 구현**

설계 문서 9절의 패널을 구현한다. AWS dimension은 구현 시 live AWS CLI로 조회한 실제 ClusterName, ServiceName, LoadBalancer, TargetGroup, DBInstanceIdentifier를 사용한다.

- [ ] **Step 4: dashboard 정적 검증**

Run: `bash v2/tests/monitoring_dashboards_test.sh`

Expected: PASS.

- [ ] **Step 5: 기존 dashboard 보존 검증**

배포 전 Grafana Search API로 기존 dashboard UID 목록과 개수를 저장한다. 신규 Stage provider와 JSON만 배포한 뒤 Grafana를 재시작하고 기존 UID가 모두 남아 있는지 비교한다.

Expected: 기존 dashboard 누락 0개, 신규 Stage dashboard 7개.

### Task 5: 보존 기간과 수집 HTTPS 기반 강화

**Files:**
- Modify: `v2/monitoring/server/compose.override.yaml`
- Modify: `v2/monitoring/server/nginx/stage-ingest.conf`
- Create: `v2/monitoring/server/loki/retention.yaml`
- Test: `v2/tests/monitoring_assets_test.sh`

**Interfaces:**
- Consumes: 기존 TLS 인증서와 Nginx network, Prometheus remote-write receiver, Loki HTTP API
- Produces: 인증된 `/stage/prometheus/api/v1/write`, `/stage/loki/api/v1/push` endpoint와 7일 retention

- [ ] **Step 1: 보안 contract test 추가**

다음을 검증한다.

- 두 수집 경로가 443 server block에만 존재
- 인증 없는 요청 차단
- Prometheus와 Loki container port가 loopback 또는 Docker network에만 노출
- Prometheus retention `7d`
- Loki retention `168h`

- [ ] **Step 2: 현재 자산이 contract를 위반하는지 확인**

Run: `bash v2/tests/monitoring_assets_test.sh`

Expected: 현재 9090/3100 공개 및 Prometheus 15일 retention 때문에 FAIL.

- [ ] **Step 3: override와 Nginx 수집 route 구현**

수집 인증정보는 repository에 저장하지 않고 라이브 서버의 root 소유 파일 또는 htpasswd secret으로 관리한다. Nginx는 request body 제한, timeout, upstream 오류 로깅을 명시한다.

- [ ] **Step 4: 배포 전 구성 검증**

Run: `bash v2/monitoring/scripts/validate-assets.sh`

Expected: Compose, Nginx, JSON/YAML 검증 PASS.

- [ ] **Step 5: 점진 배포 및 endpoint 검증**

Grafana와 기존 Dev 수집을 유지한 상태에서 Nginx, Prometheus, Loki를 한 서비스씩 재생성한다.

Expected:

- 인증 없는 push: 401 또는 403
- 인증된 잘못된 payload: 인증은 통과하되 4xx
- Grafana health: 200
- 기존 Prometheus target 및 Loki query 정상

- [ ] **Step 6: Security Group 직접 포트 제거**

9090과 3100의 직접 ingress를 제거하고, Grafana 3000 및 SSH 22의 전체 공개는 대체 운영 경로가 준비된 경우에만 제거한다.

Expected: 외부에서는 443만 사용하고 기존 Grafana HTTPS 접속 정상.

### Task 6: 실제 Stage 데이터와 대시보드 검증

**Files:**
- Modify: `v2/monitoring/README.md`
- Create: `v2/monitoring/verification/stage-dashboard-checklist.md`

**Interfaces:**
- Consumes: Task 3~5의 datasource, dashboard 및 HTTPS endpoint
- Produces: 실제 AWS/Grafana 결과를 기록한 운영 검증 체크리스트

- [ ] **Step 1: AWS 원본 값 기록**

AWS CLI로 같은 5분 구간의 ECS service, ALB request/5xx, target health, RDS CPU/connection 및 최근 Spring log event를 조회한다.

- [ ] **Step 2: Grafana query API 결과 비교**

각 dashboard 핵심 panel query를 Grafana API로 실행한다.

Expected: AWS 원본과 동일한 dimension 및 시간 구간에서 데이터가 존재하고 리전은 `ap-northeast-2`.

- [ ] **Step 3: 브라우저 시각 검증**

`https://grafana.cosmoscode.site`에서 일곱 대시보드를 열어 panel 오류, 잘린 제목, 잘못된 단위, 변수 오류와 빈 필수 패널을 확인한다.

Expected: Stage Overview, ECS, ALB, RDS, Judge Worker 및 Application Logs에서 적어도 하나 이상의 실제 데이터 확인.

- [ ] **Step 4: 회귀 검증**

기존 Dev/부하 테스트 dashboard UID, Prometheus targets, Loki labels와 다섯 Docker container health를 배포 전 결과와 비교한다.

Expected: 기존 dashboard 누락 0, 기존 target 감소 0, container 비정상 0.

- [ ] **Step 5: 운영 문서 완료**

`README.md`와 체크리스트에 datasource 복구, dashboard 재배포, IAM Role 확인, 백업 복구, direct-ingestion 후속 작업을 한국어로 기록한다.

## 후속 독립 계획

이번 계획 완료 후 별도 계획으로 다음을 수행한다.

1. Stage ECS 내부 Grafana Alloy 서비스와 Prometheus remote-write 연결
2. Spring, FastAPI, Judge API, Judge Worker의 metrics endpoint별 검증 및 scrape 구성
3. FireLens를 통한 CloudWatch + Loki 이중 로그 출력
4. 직접 수집 성공 후 Application Logs dashboard의 Loki 기본 전환
5. 서울 리전 전용 ECS on EC2 PLG Cluster 생성과 오레곤 데이터 이전
