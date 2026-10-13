# COSMOS v2 Shared VPC Stage·Prod 환경 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 하나의 VPC·NAT·ECR을 공유하면서 독립 state를 사용하는 `stage`와 `prod` 환경을 만들고, 환경별 S3·CloudFront·ALB·ECS·데이터 계층 및 애플리케이션 승격 절차를 구축한다.

**Architecture:** `modules/shared`가 VPC·subnet·NAT·Endpoint·ECR을 소유하고 `modules/environment`가 환경별 런타임 전체를 소유한다. `environments/shared`, `environments/stage`, `environments/prod`는 각각 HCP Terraform Workspace에 연결하며 stage/prod는 shared root output만 소비한다. 외부 요청은 환경별 CloudFront에서 S3 또는 `/api/*`, `/auth/*`용 ALB로 분기한다.

**Tech Stack:** Terraform >= 1.7, AWS Provider 5.x, HCP Terraform, AWS VPC, S3, CloudFront, Route 53, ACM, ALB, ECS Fargate/ECS on EC2, RDS MySQL, ElastiCache Serverless Valkey, Terraform native test, Bash

**Spec:** `docs/superpowers/specs/2026-10-11-stage-prod-shared-vpc-design.md`

## 전체 제약 조건

- AWS 기본 리전은 `ap-northeast-2`, CloudFront 인증서 조회 리전은 `us-east-1`이다.
- Workspace 이름은 `KTB4-9th-Cloud-v2-shared`, `KTB4-9th-Cloud-v2-stage`, `KTB4-9th-Cloud-v2-prod`로 고정한다.
- 환경 이름은 `stage`, `prod`만 허용하며 `staging`, `stag`는 허용하지 않는다.
- VPC `10.20.0.0/16`, Public/Private/Data subnet 2개씩, NAT Gateway 1개를 공유한다.
- ECR `spring`, `fastapi`, `judge` 3개는 shared state에서 한 번만 생성한다.
- stage/prod는 같은 `modules/environment`를 사용하고 별도 resource 사본을 갖지 않는다.
- stage의 유일한 외부 주소는 `stage.cosmoscode.site`다. 별도 stage API DNS는 만들지 않는다.
- `/api/*`, `/auth/*`는 CloudFront에서 같은 환경 ALB로 전달한다.
- ALB ingress는 CloudFront origin-facing managed prefix list만 허용한다.
- prod apex/`www` 레코드는 `enable_public_dns_cutover=false` 기본값에서는 생성하지 않는다.
- Secret metadata만 Terraform으로 관리하고 `aws_secretsmanager_secret_version`과 실제 Secret 값을 만들지 않는다.
- 기존 Route 53 Hosted Zone과 `us-east-1` ACM 인증서는 data source로 조회하고 중복 생성하지 않는다.
- 기존 v1, RDS, EBS, EC2를 import 확인 없이 이동·삭제·교체하지 않는다.
- 실제 Workspace 생성, state 이동, plan/apply, Secret 등록, artifact upload와 DNS cutover는 별도 승인 전 수행하지 않는다.
- 커밋은 사용자가 직접 수행한다. 구현 과정에서 commit, push, PR을 만들지 않는다.

## 중점 검토 항목

- shared output 누락 또는 2AZ subnet map 불완전: stage/prod root가 잘못된 네트워크로 plan되지 않고 즉시 실패해야 한다. Task 3 root 계약 테스트로 고정한다.
- 환경 경계 누수: stage IAM/SG/Secret/DNS가 prod ARN·이름·SG를 참조하지 않아야 한다. Task 2와 Task 4 테스트로 고정한다.
- 기존 DNS 중복 생성: Hosted Zone·ACM은 data source만 사용하고 resource 생성은 금지한다. Task 3 정적 테스트로 고정한다.
- CloudFront 우회: ALB의 `0.0.0.0/0` ingress와 stage API Route 53 record를 금지한다. Task 4 테스트로 고정한다.
- prod 조기 전환: `enable_public_dns_cutover=false`에서 apex/`www` 레코드가 0개여야 한다. Task 4 테스트로 고정한다.

---

## 파일 구성

| 경로 | 책임 |
| --- | --- |
| `v2/modules/shared/*` | 공유 VPC, subnet, NAT, route, endpoint, ECR |
| `v2/modules/environment/*` | 환경별 frontend, ALB, ECS, DB/cache, Judge, Worker, IAM, Secret, Logs |
| `v2/environments/shared/*` | Shared Workspace 연결, Route 53/ACM 조회, shared output |
| `v2/environments/stage/*` | Stage Workspace 연결과 environment module 호출 |
| `v2/environments/prod/*` | Prod Workspace 연결과 environment module 호출 |
| `v2/modules/shared/tests/*` | 공유 인프라 Terraform 계약 테스트 |
| `v2/modules/environment/tests/*` | stage/prod topology·격리·frontend 계약 테스트 |
| `v2/tests/layout_test.sh` | Workspace, 디렉터리, 하드코딩, 금지 리소스 정적 검사 |
| `v2/scripts/preflight.sh` | 대상 환경과 frontend/runtime 준비 상태 검사 |
| `v2/tests/preflight_test.sh` | 환경별 preflight 정상·실패 fixture |
| `v2/stage-operations.md` | Shared·Stage 적용 및 운영 절차 |
| `v2/application-migration.md` | stage 검증, prod 승격, 트래픽·ECS rollback 절차 |

### Task 1: Shared 네트워크와 ECR module

**Files:**

- 생성: `v2/modules/shared/versions.tf`
- 생성: `v2/modules/shared/variables.tf`
- 생성: `v2/modules/shared/locals.tf`
- 생성: `v2/modules/shared/network.tf`
- 생성: `v2/modules/shared/ecr.tf`
- 생성: `v2/modules/shared/outputs.tf`
- 생성: `v2/modules/shared/tests/shared.tftest.hcl`
- 참조 후 제거 대상: 기존 `v2/network.tf`, `v2/data-subnets.tf`, `v2/ecr.tf`

**Interfaces:**

- 입력: `aws_region`, `project_name`, `vpc_cidr`, 2개 AZ, Public/Private/Data CIDR, ECR repository 이름과 lifecycle 보존 수
- 출력: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `data_subnet_ids`, `ecr_repository_urls`, `ecr_repository_arns`, `nat_gateway_id`, `s3_gateway_endpoint_id`
- 후속 소비자: Task 3의 shared root 및 Task 2의 environment module 입력

- [ ] **1단계: Shared module 실패 테스트 작성**

`shared.tftest.hcl`에 다음 run을 작성한다.

- 서울 리전, VPC `10.20.0.0/16`, AZ `a/c`, subnet 2개씩
- NAT Gateway 정확히 1개
- private route 2개가 같은 NAT를 참조
- S3 Gateway Endpoint가 private route table 2개를 사용
- ECR 이름이 `cosmos-v2/{spring,fastapi,judge}`이고 immutable/scan/AES256
- ECR 이름에 `stage` 또는 `prod`가 포함되지 않음
- 잘못된 AZ 수와 CIDR 수 거부

- [ ] **2단계: RED 확인**

실행: `terraform -chdir=v2/modules/shared test`

기대 결과: module 파일과 shared resource가 없어 실패한다.

- [ ] **3단계: Shared module 구현**

현재 `network.tf`, `data-subnets.tf`, `ecr.tf`의 리소스를 이동하고 root 전용 `cloud` block을 제거한다. ECR application/stateful/worker의 세 resource 패턴은 module 내부에서 동일 보안 계약을 유지하되 output은 하나의 URL/ARN map으로 합친다.

- [ ] **4단계: Shared output 구현**

subnet output key는 기존과 동일한 문자열 index `"0"`, `"1"`을 유지한다. Secret, digest 또는 환경별 식별자를 output하지 않는다.

- [ ] **5단계: GREEN 검증**

실행: `terraform -chdir=v2/modules/shared fmt -check -recursive && terraform -chdir=v2/modules/shared validate && terraform -chdir=v2/modules/shared test`

기대 결과: Shared 네트워크·ECR 계약이 모두 통과한다.

### Task 2: 기존 v2 런타임을 environment module로 전환

**Files:**

- 생성: `v2/modules/environment/versions.tf`
- 생성: `v2/modules/environment/variables.tf`
- 생성: `v2/modules/environment/locals.tf`
- 이동·수정: 기존 네트워크/ECR 제외 `v2/*.tf` → `v2/modules/environment/*.tf`
- 이동·수정: `v2/templates/*` → `v2/modules/environment/templates/*`
- 이동·수정: 기존 Terraform test 5개 → `v2/modules/environment/tests/*`

**Interfaces:**

- 입력: `environment`, `vpc_id`, 세 subnet ID map, ECR URL/ARN map, 기존 runtime 변수 전체
- 출력: 환경별 ALB/ECS/RDS/Valkey/Judge/Worker/Secret/Log 식별자
- 보존 계약: 기존 Fargate, 상태 저장 EC2/EBS, Worker Capacity Provider, IAM, SG, precondition과 output 동작

- [ ] **1단계: Environment module 실패 테스트 작성**

기존 45개 Terraform test를 module 입력 방식으로 옮기고 다음 신규 run을 먼저 추가한다.

- `environment="stage"` 허용, `staging`·`dev` 거부
- stage 이름 접두사 `cosmos-v2-stage`
- Secret `/cosmos-v2/stage/{service}`
- Log `/ecs/cosmos-v2-stage/{service}`
- namespace `stage.cosmos-v2.local`
- Valkey user/group에 `stage` 포함
- module 내부 ECR resource 0개, 전달된 ECR URL 사용
- stage resource가 문자열 `prod` ARN·이름·SG를 참조하지 않음

- [ ] **2단계: RED 확인**

실행: `terraform -chdir=v2/modules/environment test`

기대 결과: environment module이 없어 실패한다.

- [ ] **3단계: 런타임 파일 이동과 외부 입력 전환**

기존 resource 이름은 state 주소 대응을 위해 module 내부에서 유지한다. `aws_vpc.main`, subnet resource와 ECR resource 참조를 각각 module 입력으로 교체한다. `templatefile` 경로는 module의 `templates`를 기준으로 변경한다.

- [ ] **4단계: prod 하드코딩 제거**

`local.secret_names`, Service Connect namespace, Valkey user/group, 설명·로그 이름을 `var.environment` 또는 `local.name_prefix`에서 계산한다. `environment` validation은 `stage`, `prod`만 허용한다.

- [ ] **5단계: 기존 output 보존**

기존 runtime output 이름을 module output에 유지한다. 공유 계층으로 이동한 VPC/subnet/NAT/ECR output은 제거하고 environment module은 입력 ECR map을 필요한 output에 그대로 노출한다.

- [ ] **6단계: GREEN 및 회귀 검증**

실행: `terraform -chdir=v2/modules/environment fmt -check -recursive && terraform -chdir=v2/modules/environment validate && terraform -chdir=v2/modules/environment test`

기대 결과: 기존 계약과 stage/prod 환경화 계약이 함께 통과한다.

### Task 3: Shared·Stage·Prod HCP Terraform root 구성

**Files:**

- 생성: `v2/environments/shared/{versions.tf,providers.tf,main.tf,outputs.tf}`
- 생성: `v2/environments/stage/{versions.tf,providers.tf,main.tf,outputs.tf}`
- 생성: `v2/environments/prod/{versions.tf,providers.tf,main.tf,outputs.tf}`
- 생성: `v2/tests/layout_test.sh`
- 수정: `v2/.gitignore` 또는 repository `.gitignore` — root별 plan/cache 제외가 필요할 때만
- 제거 대상: 기존 `v2/versions.tf`, `v2/providers.tf`와 root resource 파일

**Interfaces:**

- Shared root output: Shared module output + `route53_zone_id`, `cloudfront_certificate_arn`
- Stage/Prod 입력: `data.terraform_remote_state.shared.outputs`의 비민감 output만 사용
- Workspace: shared/stage/prod별 고정 `cloud.workspaces.name`

- [ ] **1단계: Root layout 실패 테스트 작성**

`layout_test.sh`에 다음 assertion을 작성한다.

- root 3개와 module 2개 존재
- 세 `versions.tf`의 Workspace 이름이 정확함
- stage/prod `main.tf`가 동일한 `../../modules/environment` source 사용
- stage는 `environment = "stage"`, prod는 `environment = "prod"`
- environment root가 shared output을 통해서만 VPC/subnet/ECR을 전달
- `aws_route53_zone`과 `aws_acm_certificate` resource가 v2에 없음
- Shared root에 `data.aws_route53_zone`과 `data.aws_acm_certificate`가 존재

- [ ] **2단계: RED 확인**

실행: `bash v2/tests/layout_test.sh`

기대 결과: 환경 root가 없어 실패한다.

- [ ] **3단계: Shared root 구현**

Workspace `KTB4-9th-Cloud-v2-shared`, 기본 AWS provider `ap-northeast-2`, alias `aws.us_east_1`을 선언한다. Shared module을 호출하고 기존 `cosmoscode.site` Hosted Zone 및 `cosmoscode.site`+`*.cosmoscode.site`를 포함하는 ISSUED 인증서를 data source로 조회해 output한다.

- [ ] **4단계: Stage/Prod root 구현**

각 root는 `terraform_remote_state`의 remote backend로 organization `cosmoscode`, workspace `KTB4-9th-Cloud-v2-shared`를 읽는다. 정확히 2개씩의 subnet ID와 필수 ECR key 3개가 없으면 `check`가 plan을 거부한다. environment module enable flag는 기존처럼 기본 false를 유지한다.

- [ ] **5단계: Workspace 운영 설정 문서화 주석**

Shared Workspace state sharing consumer를 stage/prod 두 Workspace로만 제한해야 함을 root 파일 주석과 운영 문서에 기록한다. run trigger 자동 apply는 구성하지 않는다.

- [ ] **6단계: Root 검증**

실행: `bash v2/tests/layout_test.sh` 및 각 root에서 `terraform init -backend=false && terraform validate`

기대 결과: layout 계약과 세 root validation이 통과한다. 실제 remote state 조회나 plan은 실행하지 않는다.

### Task 4: 환경별 S3·CloudFront·ALB·Route 53 진입 계층

**Files:**

- 생성: `v2/modules/environment/frontend.tf`
- 생성: `v2/modules/environment/route53.tf`
- 수정: `v2/modules/environment/alb.tf`
- 수정: `v2/modules/environment/security.tf`
- 수정: `v2/modules/environment/variables.tf`
- 수정: `v2/modules/environment/outputs.tf`
- 수정: `v2/modules/environment/tests/frontend.tftest.hcl`

**Interfaces:**

- 입력: `route53_zone_id`, `cloudfront_certificate_arn`, `domain_name="cosmoscode.site"`, `enable_public_dns_cutover=false`
- Stage output: frontend bucket, CloudFront ID/domain/ARN, `https://stage.cosmoscode.site`, ALB ID/DNS
- Prod output: CloudFront 기본 domain, cutover 활성 시 apex/`www`

- [ ] **1단계: Frontend 실패 테스트 작성**

다음 run을 작성한다.

- stage bucket 이름 `cosmos-v2-stage-frontend-{account}` 및 Public Access Block 4개 true
- OAC S3/SigV4/always와 자신의 distribution만 허용하는 bucket policy
- CloudFront 기본 origin S3, ordered behavior `/api/*`, `/auth/*`는 같은 환경 ALB
- API behavior cache disabled, 모든 method, query/cookie/auth 전달
- viewer HTTPS redirect, TLS `TLSv1.2_2021`, stage alias 1개
- S3 기본 behavior의 CloudFront Function만 SPA route를 `/index.html`로 rewrite하고 API/Auth 403/404는 보존
- stage Route 53 alias는 `stage.cosmoscode.site` 1개, stage API record 0개
- ALB ingress가 CloudFront managed prefix list TCP 80만 허용하고 `0.0.0.0/0` 미허용
- prod cutover false에서 apex/`www` record 0개, true에서 2개
- 인증서 ARN이 `us-east-1`이 아니면 check 실패

- [ ] **2단계: RED 확인**

실행: `terraform -chdir=v2/modules/environment test -filter=tests/frontend.tftest.hcl`

기대 결과: frontend/Route 53 resource가 없어 실패한다.

- [ ] **3단계: Private S3와 OAC 구현**

account ID data source로 globally unique bucket 이름을 계산한다. Bucket ownership, Public Access Block, versioning, server-side AES256, lifecycle와 CloudFront SourceArn 조건 bucket policy를 구성한다. Terraform은 object를 업로드하지 않는다.

- [ ] **4단계: CloudFront 구현**

S3 REST origin과 ALB custom origin을 정의한다. default behavior는 S3, `/api/*`, `/auth/*`는 ALB를 사용한다. AWS managed cache/origin request policy를 data source로 조회해 정적 캐시와 API no-cache를 구분한다. SPA fallback과 환경별 alias/certificate를 적용한다.

- [ ] **5단계: ALB 접근 제한 구현**

기존 `0.0.0.0/0` ALB ingress를 제거하고 `data.aws_ec2_managed_prefix_list.cloudfront_origin_facing` source rule로 교체한다. ALB는 public subnet의 internet-facing을 유지하고 Spring Target Group health check 계약은 변경하지 않는다.

- [ ] **6단계: Route 53 보호 구현**

stage는 `stage.cosmoscode.site` Alias를 항상 자신의 CloudFront에 연결한다. prod apex와 `www` resource는 `enable_public_dns_cutover`가 true일 때만 생성하며 기본 false다. 다른 public service record는 선언하지 않는다.

- [ ] **7단계: GREEN 검증**

실행: `terraform -chdir=v2/modules/environment validate && terraform -chdir=v2/modules/environment test`

기대 결과: frontend, ALB 우회 차단, DNS cutover 보호와 기존 runtime 계약이 통과한다.

### Task 5: 환경별 preflight와 운영 문서

**Files:**

- 수정: `v2/scripts/preflight.sh`
- 수정: `v2/tests/preflight_test.sh`
- 생성: `v2/stage-operations.md`
- 생성: `v2/application-migration.md`
- 수정: `v2/architecture.md`, `v2/phase-2-architecture.md`, `v2/phase-2-worker-architecture.md` — 기존 단일 prod 경로 설명을 새 설계 문서로 연결

**Interfaces:**

- 신규 preflight 입력: `TARGET_ENVIRONMENT`, `EXPECTED_WORKSPACE`, `FRONTEND_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID`, `FRONTEND_URL`, 기존 application/Worker 변수
- 허용 환경: `stage`, `prod`
- 출력: 성공 시 환경명이 포함된 단일 통과 메시지, 실패 시 Secret 값을 포함하지 않는 원인 메시지

- [ ] **1단계: Preflight 실패 fixture 작성**

기존 fixture에 다음 사례를 추가한다.

- `TARGET_ENVIRONMENT=staging` 거부
- stage 실행에 prod Workspace/Secret/Cluster 입력 거부
- frontend S3 bucket 조회 실패
- CloudFront distribution 비활성 또는 잘못된 alias
- ALB target health 비정상
- stage frontend URL이 `https://stage.cosmoscode.site`가 아님
- 정상 stage fixture와 정상 prod fixture exit 0

- [ ] **2단계: RED 확인**

실행: `bash v2/tests/preflight_test.sh`

기대 결과: 환경/frontend 검사가 없어 신규 실패 fixture가 잘못 통과한다.

- [ ] **3단계: Preflight 환경화 구현**

`aws s3api head-bucket`, `aws cloudfront get-distribution`, `aws elbv2 describe-target-health`, 기존 ECR/Secrets/ECS 조회와 `terraform state list`만 사용한다. `TARGET_ENVIRONMENT`이 resource 이름·Secret 경로·Cluster 이름에 포함되는지 검사하고 apply, Secret value 조회, S3 object 변경은 금지한다.

- [ ] **4단계: Stage 운영 문서 작성**

`stage-operations.md`에 Workspace working directory 설정, Shared state sharing, 순차 plan/apply, Secret 등록, DB schema, frontend artifact upload, CloudFront 검증, Fargate/Worker 단계 활성화, 비용 중지 경계를 한국어로 기록한다.

- [ ] **5단계: 애플리케이션 마이그레이션 문서 작성**

`application-migration.md`에 frontend/be/ai/judge artifact 계약, stage 검증 matrix, 동일 digest prod 승격, prod DNS cutover flag, Route 53 rollback, ECS revision rollback, v1 유지/종료 기준을 한국어로 기록한다.

- [ ] **6단계: GREEN 검증**

실행: `bash -n v2/scripts/preflight.sh && bash -n v2/tests/preflight_test.sh && bash v2/tests/preflight_test.sh`

기대 결과: 기존 및 stage/prod/frontend fixture가 모두 통과한다.

### Task 6: 전체 회귀 검증과 실제 구축 경계

**Files:**

- 수정: `docs/superpowers/plans/2026-10-11-stage-prod-shared-vpc-implementation.md` — 검증 상태만 기록
- 수정: 설계 문서 — provider schema 또는 실제 구현 차이가 발견된 경우에만 정정

**Interfaces:**

- 입력: 완성된 module/root/test/preflight/docs
- 출력: 오프라인 검증 결과, 실제 Workspace/state/apply를 위한 차단 조건

- [ ] **1단계: 전체 오프라인 검증**

실행:

```bash
terraform -chdir=v2/modules/shared fmt -check -recursive
terraform -chdir=v2/modules/shared validate
terraform -chdir=v2/modules/shared test
terraform -chdir=v2/modules/environment fmt -check -recursive
terraform -chdir=v2/modules/environment validate
terraform -chdir=v2/modules/environment test
bash v2/tests/layout_test.sh
bash v2/tests/preflight_test.sh
git diff --check
```

추가 정적 검사는 다음 pattern이 발견되면 실패한다.

```text
aws_secretsmanager_secret_version
secret_string
stage-api.cosmoscode.site
aws_route53_zone resource
aws_acm_certificate resource
ALB ingress 0.0.0.0/0
modules/environment 내부 /cosmos-v2/prod 하드코딩
```

- [ ] **2단계: 실제 state 존재 여부 확인 경계**

HCP Terraform 인증이 있을 때만 세 Workspace의 `state list`를 조회한다. 기존 prod state가 비어 있지 않으면 신규 module plan 전에 주소별 moved/import 계획을 별도 제시하고 중단한다. v1 주소가 v2 state에 있으면 즉시 중단한다.

- [ ] **3단계: 실제 Workspace 생성과 공유 설정 경계**

세 Workspace가 존재하지 않으면 사용자 승인 후 생성한다. VCS working directory를 설계값으로 설정하고 shared state consumer를 stage/prod로 제한한다. 이 계획의 소스 구현만으로 Workspace를 자동 생성하지 않는다.

- [ ] **4단계: 실제 plan/apply 경계**

별도 승인 후 `shared → stage → prod` 순서로 저장 plan을 검토한다. Stage는 frontend/data/runtime를 단계적으로 활성화한다. prod의 `enable_public_dns_cutover`는 migration 승인 전 false로 유지한다. destroy/replacement가 기존 RDS/EBS/EC2/Route 53/ACM에 나타나면 apply하지 않는다.

- [ ] **5단계: 실제 smoke/cutover 경계**

frontend artifact, image digest, Secret version, DB schema가 준비된 뒤에만 stage smoke test를 수행한다. prod cutover는 stage 검증 완료와 별도 승인 후 진행하며, 실패 시 v1 CloudFront Route 53 alias와 직전 ECS revision으로 rollback한다.

## 구현 상태 — 2026-10-11

- Task 1~5의 Terraform module/root, 테스트, preflight, 한국어 운영·마이그레이션 문서 구현을 완료했다.
- Task 6의 오프라인 회귀 검증을 완료했다. Shared 5개, Environment 41개 Terraform test와 세 root validation, layout/preflight test가 통과했다.
- 실제 HCP Terraform Workspace 생성·설정, 기존 state 조회·이동, AWS plan/apply, Secret/artifact 등록, smoke test와 DNS cutover는 이 구현에서 실행하지 않았다. 각각 본 Task 6의 승인 경계를 따른다.
