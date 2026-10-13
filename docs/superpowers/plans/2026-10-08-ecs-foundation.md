# COSMOS v2 ECS 공통 기반 구현 계획

> **에이전트 작업자 필수 사항:** 이 계획을 작업 단위로 구현할 때 `superpowers:subagent-driven-development` 또는 `superpowers:executing-plans` 스킬을 반드시 사용한다. 진행 상태는 체크박스(`- [ ]`)로 추적한다.

**목표:** 애플리케이션 서비스를 배포하지 않은 상태에서 네트워크, NAT Gateway 1개, ECR, ECS Cluster, ALB, IAM, CloudWatch Logs로 구성된 서울 리전 COSMOS v2 Terraform 공통 기반을 구축하고 검증한다.

**아키텍처:** 기존 v1 root module과 state는 `v1/`에 유지하고, v2는 `v2/`의 독립적인 root module과 Terraform Cloud workspace `cosmoscode/KTB4-9th-Cloud-v2-prod`를 사용한다. v2 VPC는 두 가용 영역에 Public/Private subnet을 각각 2개 배치하고, 단일 NAT Gateway로 Private subnet의 outbound를 제공한다. 인터넷-facing ALB와 서비스별 ECR repository를 준비해 후속 ECS Service가 사용할 수 있게 한다.

**기술 스택:** Terraform >= 1.7, HashiCorp AWS Provider ~> 5.0, AWS VPC/ECR/ECS/ELBv2/IAM/CloudWatch, HCP Terraform(Terraform Cloud), AWS Provider mock을 사용하는 Terraform native test.

**설계 문서:** `v2/architecture.md`

## 전체 제약 조건

- v2는 `ap-northeast-2`에만 배포하며 기존 v1 AWS 리소스를 변경하거나 import하지 않는다.
- Terraform Cloud workspace `cosmoscode/KTB4-9th-Cloud-v2-prod`를 사용하며 최초 plan 전 state가 비어 있어야 한다.
- VPC CIDR은 `10.20.0.0/16`, Public CIDR은 `10.20.0.0/24`와 `10.20.1.0/24`, Private CIDR은 `10.20.10.0/24`와 `10.20.11.0/24`를 사용한다.
- 가용 영역은 `ap-northeast-2a`, `ap-northeast-2c`를 사용한다.
- 첫 번째 Public subnet에 NAT Gateway를 정확히 1개 생성하고 Private subnet마다 별도 route table을 둔다.
- ECS Task Definition, ECS Service, Target Group, RDS, ElastiCache, Route 53, ACM, 애플리케이션 secret, Auto Scaling은 생성하지 않는다.
- 자격 증명이나 secret 값을 Terraform 코드, 변수, output, 테스트 fixture, state에 저장하지 않는다.
- 커밋은 생성하지 않는다. 사용자가 직접 커밋한다.

## 중점 검토 항목

- 잘못되었거나 비어 있지 않은 Terraform Cloud workspace: v1 주소가 변경 또는 삭제되기 전에 초기화와 plan을 중단해야 한다. 작업 7에서 state와 plan 격리를 검증한다.
- AZ/subnet 목록 길이 불일치: 세 목록 중 하나라도 정확히 2개가 아니면 validation이 거부해야 한다. 작업 2에서 각 실패 조건을 테스트한다.
- NAT Gateway 추가 생성: Private route table은 2개를 유지하면서 NAT Gateway는 정확히 1개여야 한다. 작업 3에서 개수와 route target을 테스트한다.
- 위험한 이미지 정리: ECR tag는 immutable이어야 하며 tagged 이미지 20개를 유지하고 7일이 지난 untagged 이미지만 삭제해야 한다. 작업 4에서 lifecycle JSON을 검증한다.
- 노출되거나 사용할 수 없는 ALB: ALB는 public이어야 하고 두 Public subnet에 걸쳐야 하며 deletion protection을 사용하고 Target Group 없이 HTTP 404를 반환해야 한다. 작업 6에서 검증한다.

---

## 파일 구성

| 파일 | 책임 |
| --- | --- |
| `v2/architecture.md` | 승인된 아키텍처 설계 |
| `v2/versions.tf` | Terraform/AWS Provider 버전과 Terraform Cloud workspace |
| `v2/providers.tf` | 서울 리전 AWS Provider와 provider 기본 태그 |
| `v2/variables.tf` | 입력 타입, 기본값, validation |
| `v2/locals.tf` | 공통 이름, subnet map, ECR set, 공통 태그 |
| `v2/network.tf` | VPC, subnet, gateway, route table, association, S3 Endpoint |
| `v2/security.tf` | ALB Security Group과 ingress/egress rule |
| `v2/ecr.tf` | ECR repository 3개와 lifecycle policy |
| `v2/ecs.tf` | ECS Cluster와 Fargate Capacity Provider 연결 |
| `v2/iam.tf` | ECS task execution role과 policy attachment |
| `v2/logging.tf` | 서비스별 CloudWatch Log Group |
| `v2/alb.tf` | 인터넷-facing ALB와 HTTP fixed-response listener |
| `v2/outputs.tf` | 민감하지 않은 ID, ARN, 이름, URL, DNS output |
| `v2/tests/foundation.tftest.hcl` | 모든 v2 리소스와 안전 조건을 검증하는 mocked plan 테스트 |
| `.github/workflows/cicd.yml` | 기존 v1 workflow의 실행 경로 수정 |
| `v1/.terraform.lock.hcl` | 기존 v1 Provider 선택을 새 root 경로에 보존 |

### Task 1: v1 Workflow와 Provider Lock 격리 보존

**파일:**

- 수정: `.github/workflows/cicd.yml`
- 생성: 기존 root lock 파일과 내용이 동일한 `v1/.terraform.lock.hcl`
- 삭제: `.terraform.lock.hcl`

**인터페이스:**

- 입력: `v1/`의 기존 root module과 Terraform Cloud workspace `KTB4-9th-Cloud`
- 출력: 모든 Terraform 명령과 PR plan 파일 조회가 `v1/`을 사용하는 workflow

- [ ] **1단계: 현재 실패 조건 기록**

실행: `test ! -f provider.tf && test -f v1/provider.tf && rg -n "run: terraform|readFileSync\('plan.txt'" .github/workflows/cicd.yml`

기대 결과: root에는 `provider.tf`가 없지만 workflow 명령에는 `v1/` 경로가 없고 PR script는 root의 `plan.txt`를 조회한다.

- [ ] **2단계: Provider lock 파일을 v1 root module로 이동**

`.terraform.lock.hcl`의 추적 중인 내용을 그대로 `v1/.terraform.lock.hcl`에 생성한 후 root 사본을 제거한다. Provider 버전은 갱신하지 않는다.

- [ ] **3단계: Workflow 작업 경로 지정**

`plan`, `apply` job 모두에 `defaults.run.working-directory: v1`을 추가한다. PR 댓글 script는 Action step이므로 `v1/plan.txt`를 직접 읽도록 수정한다.

- [ ] **4단계: v1 경로 일관성 검증**

실행: `test -f v1/.terraform.lock.hcl && test ! -f .terraform.lock.hcl && rg -n "working-directory: v1|readFileSync\('v1/plan.txt'" .github/workflows/cicd.yml`

기대 결과: job working-directory 2건과 `v1/plan.txt` 1건이 검색된다.

- [ ] **5단계: 작업 검토**

실행: `git diff --check && git diff -- .github/workflows/cicd.yml .terraform.lock.hcl v1/.terraform.lock.hcl`

기대 결과: 공백 오류가 없고 lock 파일 이동과 v1 경로 수정만 나타난다. 커밋하지 않는다.

### Task 2: v2 Root Module 계약 구성

**파일:**

- 생성: `v2/versions.tf`, `v2/providers.tf`, `v2/variables.tf`, `v2/locals.tf`
- 생성: `v2/tests/foundation.tftest.hcl`

**인터페이스:**

- 입력: `v2/architecture.md`의 이름, CIDR, AZ, 태그, workspace
- 출력: `aws_region`, `project_name`, `environment`, `vpc_cidr`, `availability_zones`, `public_subnet_cidrs`, `private_subnet_cidrs`, `ecr_repository_names`, `ecr_tagged_image_count`, `ecr_untagged_max_age_days`, `cloudwatch_log_retention_days`, `enable_container_insights` 변수와 `name_prefix`, `common_tags`, `public_subnets`, `private_subnets`, `ecr_repositories` local

- [ ] **1단계: Mock 기반 기본 설정 테스트 작성**

`mock_provider "aws" {}`와 plan run을 작성해 기본 리전, AZ 2개, Public CIDR 2개, Private CIDR 2개, ECR 이름 `spring`, `fastapi`, `judge-api`를 검증한다.

- [ ] **2단계: 잘못된 입력 테스트 작성**

AZ 1개, Public CIDR 1개, Private CIDR 1개, 유효하지 않은 VPC CIDR, 지원하지 않는 로그 retention을 각각 `expect_failures`로 검증한다.

- [ ] **3단계: 구현 전 테스트 실패 확인**

실행: `terraform -chdir=v2 init -backend=false && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: v2 Terraform 파일과 변수가 아직 없어 실패한다.

- [ ] **4단계: Terraform 및 Provider 제약 구현**

`v2/versions.tf`에서 Terraform `>= 1.7.0, < 2.0.0`, `hashicorp/aws ~> 5.0`을 요구하고 `cosmoscode/KTB4-9th-Cloud-v2-prod` workspace를 지정한다.

- [ ] **5단계: Provider와 공통 태그 구현**

`var.aws_region`으로 AWS Provider를 구성하고 `default_tags`에 `local.common_tags`를 적용한다. 자격 증명은 코드에 넣지 않는다.

- [ ] **6단계: 변수 및 validation 구현**

설계 문서의 기본값으로 변수를 생성한다. 유효한 CIDR, 각 AZ/subnet 목록이 정확히 2개인지, `environment`가 `dev|staging|prod`인지, ECR 보존 값이 양수인지, 로그 retention 값이 지원되는지 검증한다.

- [ ] **7단계: Local 구현**

`name_prefix`를 `${var.project_name}-${var.environment}`로 설정한다. index 기반 AZ-keyed subnet map, ECR set, `Project=cosmos`, `Version=v2`, `Environment=var.environment`, `ManagedBy=Terraform` 태그를 정의한다.

- [ ] **8단계: Root module 계약 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: 기본 run과 잘못된 입력 validation 테스트가 모두 통과한다.

- [ ] **9단계: 작업 검토**

실행: `git diff --check && git diff -- v2/versions.tf v2/providers.tf v2/variables.tf v2/locals.tf v2/tests/foundation.tftest.hcl`

기대 결과: Root module 계약과 테스트만 나타난다. 커밋하지 않는다.

### Task 3: NAT Gateway 1개를 사용하는 2AZ 네트워크 구현

**파일:**

- 생성: `v2/network.tf`
- 수정: `v2/tests/foundation.tftest.hcl`

**인터페이스:**

- 입력: 작업 2의 subnet map, 공통 이름/태그, VPC CIDR, 리전
- 출력: VPC, Internet Gateway, Public/Private subnet, Elastic IP, NAT Gateway, route table/association, S3 Gateway Endpoint

- [ ] **1단계: 네트워크 plan 검증 작성**

DNS가 활성화된 VPC 1개, Public/Private subnet 각 2개, Internet Gateway 1개, NAT Gateway 1개, Public route table 1개, Private route table 2개, S3 Endpoint 1개를 검증한다. Public subnet만 public IP 자동 할당을 사용해야 한다.

- [ ] **2단계: Routing 안전 조건 검증 작성**

Public 기본 route는 Internet Gateway, 두 Private 기본 route는 동일 NAT Gateway를 가리켜야 한다. NAT는 첫 Public subnet에 있고 AZ/CIDR 조합은 설계와 일치해야 한다.

- [ ] **3단계: 구현 전 테스트 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: 네트워크 리소스가 없어 실패한다.

- [ ] **4단계: VPC, Gateway, Subnet 구현**

VPC, Internet Gateway, Public/Private subnet 각 2개, VPC용 Elastic IP 1개, 첫 Public subnet의 NAT Gateway 1개를 생성한다. NAT의 Internet Gateway 의존성을 명시한다.

- [ ] **5단계: Route table과 association 구현**

Public route table 1개와 Private route table 2개를 만든다. 두 Public subnet은 Public table에, 각 Private subnet은 자신의 AZ-keyed table에 연결한다. 두 Private 기본 route는 단일 NAT를 사용한다.

- [ ] **6단계: S3 Gateway Endpoint 구현**

`com.amazonaws.${var.aws_region}.s3` Endpoint를 생성하고 Private route table ID 2개만 연결한다.

- [ ] **7단계: 네트워크 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: NAT 1개와 Private route table 2개를 포함한 모든 검증이 통과한다.

- [ ] **8단계: 작업 검토**

실행: `git diff --check && git diff -- v2/network.tf v2/tests/foundation.tftest.hcl`

기대 결과: 설계 문서 5장과 일치하며 데이터 subnet은 없다. 커밋하지 않는다.

### Task 4: 서비스별 ECR Repository 구현

**파일:**

- 생성: `v2/ecr.tf`
- 수정: `v2/tests/foundation.tftest.hcl`

**인터페이스:**

- 입력: ECR 이름 set과 보존 변수
- 출력: `aws_ecr_repository.service`, `aws_ecr_lifecycle_policy.service`

- [ ] **1단계: ECR plan 검증 작성**

`cosmos-v2/spring`, `cosmos-v2/fastapi`, `cosmos-v2/judge-api`를 검증한다. 각 repository는 immutable tag, push scan, AES-256, `force_delete=false`여야 한다.

- [ ] **2단계: Lifecycle policy 검증 작성**

Lifecycle JSON을 decode해 tagged 이미지 20개 제한과 7일이 지난 untagged 이미지 정리를 확인한다.

- [ ] **3단계: 구현 전 테스트 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: ECR 리소스가 없어 실패한다.

- [ ] **4단계: Repository와 policy 구현**

두 리소스 모두 `for_each`를 사용한다. 이름에는 `cosmos-v2/`를 붙이고 lifecycle JSON은 `jsonencode`로 생성한다.

- [ ] **5단계: ECR 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: Repository 3개의 검증이 모두 통과한다.

- [ ] **6단계: 작업 검토**

실행: `git diff --check && git diff -- v2/ecr.tf v2/tests/foundation.tftest.hcl`

기대 결과: 설계 문서 7장과 일치한다. 커밋하지 않는다.

### Task 5: ECS, Execution IAM, Log Group 구현

**파일:**

- 생성: `v2/ecs.tf`, `v2/iam.tf`, `v2/logging.tf`
- 수정: `v2/tests/foundation.tftest.hcl`

**인터페이스:**

- 입력: 공통 이름, ECR set, Container Insights 설정, 로그 retention
- 출력: ECS Cluster/Capacity Provider, Task Execution Role/policy attachment, 서비스별 Log Group

- [ ] **1단계: ECS plan 검증 작성**

Cluster 이름 `cosmos-v2-prod-cluster`, Container Insights, `FARGATE`와 `FARGATE_SPOT`, 기본 `FARGATE` strategy를 검증한다.

- [ ] **2단계: IAM 검증 작성**

Trust policy를 decode해 `ecs-tasks.amazonaws.com`만 assume할 수 있는지 확인한다. `AmazonECSTaskExecutionRolePolicy` attachment는 1개이며 Secrets Manager wildcard 권한은 없어야 한다.

- [ ] **3단계: Log Group 검증 작성**

`/ecs/cosmos-v2-prod/{spring,fastapi,judge-api}` Log Group 3개와 30일 retention을 검증한다.

- [ ] **4단계: 구현 전 테스트 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: ECS, IAM, 로그 리소스가 없어 실패한다.

- [ ] **5단계: ECS Cluster와 Capacity Provider 구현**

Cluster와 `FARGATE`, `FARGATE_SPOT` 연결을 생성하고 기본 strategy는 `FARGATE`로 둔다. Service, Task Definition, Auto Scaling은 만들지 않는다.

- [ ] **6단계: Task Execution Role 구현**

`aws_iam_policy_document`로 trust policy를 만들고 `arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy`만 연결한다.

- [ ] **7단계: Log Group 구현**

`for_each = local.ecr_repositories`로 3개 Log Group과 retention을 생성한다.

- [ ] **8단계: ECS/IAM/로그 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: 모든 검증이 통과하고 Service와 Task Definition은 없다.

- [ ] **9단계: 작업 검토**

실행: `git diff --check && git diff -- v2/ecs.tf v2/iam.tf v2/logging.tf v2/tests/foundation.tftest.hcl`

기대 결과: ECS 공통 기반만 나타난다. 커밋하지 않는다.

### Task 6: Public ALB 공통 기반 구현

**파일:**

- 생성: `v2/security.tf`, `v2/alb.tf`
- 수정: `v2/tests/foundation.tftest.hcl`

**인터페이스:**

- 입력: VPC ID, Public subnet ID 2개, 공통 이름
- 출력: ALB SG/rule, `aws_lb.main`, `aws_lb_listener.http`

- [ ] **1단계: Security Group 검증 작성**

`0.0.0.0/0`에서 TCP 80/443만 들어오고 SSH rule이 없으며 초기 전체 outbound가 1개인지 검증한다.

- [ ] **2단계: ALB와 Listener 검증 작성**

Application type, `internal=false`, Public subnet 2개, ALB SG, deletion protection, HTTP 80의 404 fixed response를 검증한다.

- [ ] **3단계: 구현 전 테스트 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: SG, ALB, Listener가 없어 실패한다.

- [ ] **4단계: ALB Security Group 구현**

Inline rule 없는 SG와 port 80/443 ingress rule, 초기 outbound rule을 별도 리소스로 만든다. ECS Service SG는 만들지 않는다.

- [ ] **5단계: ALB와 Listener 구현**

두 Public subnet에 `cosmos-v2-prod-alb`를 만들고 deletion protection을 켠다. HTTP 404 listener만 만들고 Target Group, 인증서, HTTPS listener는 만들지 않는다.

- [ ] **6단계: ALB 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: 모든 검증이 통과하고 Target Group이 없다.

- [ ] **7단계: 작업 검토**

실행: `git diff --check && git diff -- v2/security.tf v2/alb.tf v2/tests/foundation.tftest.hcl`

기대 결과: ALB가 유일한 인터넷-facing 애플리케이션 리소스다. 커밋하지 않는다.

### Task 7: Output 추가 및 State 격리 입증

**파일:**

- 생성: `v2/outputs.tf`
- 수정: `v2/tests/foundation.tftest.hcl`

**인터페이스:**

- 입력: 작업 3~6의 리소스
- 출력: 설계 문서 16장의 비민감 output 전체

- [ ] **1단계: Output 테스트 작성**

VPC, subnet, route table, NAT, S3 Endpoint, Cluster, ECR, ALB, Execution Role, Log Group output의 존재와 collection 개수를 검증한다.

- [ ] **2단계: 구현 전 테스트 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/foundation.tftest.hcl`

기대 결과: Output이 없어 실패한다.

- [ ] **3단계: Output 구현**

설계 문서의 이름을 그대로 사용하고 collection은 keyed map으로 반환한다. Secret output은 만들지 않는다.

- [ ] **4단계: 전체 오프라인 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test`

기대 결과: Formatting, validation, test가 모두 통과한다.

- [ ] **5단계: Workspace 확인**

`cosmoscode/KTB4-9th-Cloud-v2-prod`가 존재하고 Terraform `>= 1.7.0, < 2.0.0` 호환 버전을 사용하며 state가 비어 있는지 확인한다. 리소스가 있으면 중단한다.

- [ ] **6단계: 실제 v2 Backend 초기화**

실행: `terraform -chdir=v2 init`

기대 결과: v2 workspace에 연결되고 `v2/.terraform.lock.hcl`이 생성된다. 기존 v1 workspace에는 연결하지 않는다.

- [ ] **7단계: State 격리 검증**

실행: `terraform -chdir=v2 state list`

최초 apply 전 기대 결과: 주소가 없다. v1 주소가 나타나면 즉시 중단한다.

- [ ] **8단계: 실제 Plan 생성 및 검토**

실행: `terraform -chdir=v2 plan -input=false`

기대 결과: v2 공통 기반만 생성하는 create-only plan이다. v1 변경/삭제와 제외 범위 리소스가 없어야 한다.

- [ ] **9단계: 작업 검토**

실행: `git diff --check && git status --short`

기대 결과: 승인된 v1 경로 수정, v2 코드/테스트/문서, v2 lock, 이 계획만 나타난다. 커밋하지 않는다.

### Task 8: Apply 및 Smoke Test

**파일:** 소스 변경 없음. 실제 Provider 동작에 따른 문서 정정이 필요할 때만 `v2/architecture.md`를 수정한다.

**인터페이스:**

- 입력: 검토 완료된 create-only plan과 v2 workspace의 AWS 인증
- 출력: 서울 리전에 배포된 v2 공통 기반과 검증 결과

- [ ] **1단계: 최종 Plan 저장**

실행: `terraform -chdir=v2 plan -input=false -out=v2-foundation.tfplan`

기대 결과: 작업 7과 동일한 create-only plan이며 파일은 추적하지 않는다.

- [ ] **2단계: 저장한 Plan Apply**

실행: `terraform -chdir=v2 apply v2-foundation.tfplan`

기대 결과: v1 변경 없이 공통 기반이 생성된다.

- [ ] **3단계: State 리소스 종류 확인**

실행: `terraform -chdir=v2 state list`

기대 결과: 설계 범위의 VPC/network, ECR, ECS, IAM, Log Group, ALB, Listener, SG만 나타난다.

- [ ] **4단계: Output 확인**

실행: `terraform -chdir=v2 output`

기대 결과: 설계 문서 16장의 output과 예상 collection 개수가 나타난다.

- [ ] **5단계: ALB Smoke Test**

`alb_dns_name`으로 HTTP 요청을 보내고 `404`를 확인한다. 최초 DNS 조회 실패는 전파 시간을 고려해 재시도한다.

- [ ] **6단계: 멱등성 검증**

실행: `terraform -chdir=v2 plan -input=false -detailed-exitcode`

기대 결과: Exit code `0`과 `No changes. Your infrastructure matches the configuration.`이 출력된다. Exit code `2`는 drift 조사 대상이고 `1`은 plan 실패다.

- [ ] **7단계: 최종 검토**

실행: `git diff --check && git status --short`

기대 결과: Plan 파일이 추적되지 않고 diff에 자격 증명이 없으며 커밋도 생성되지 않았다.
