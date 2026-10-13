# COSMOS v2 2차 데이터 기반 Implementation Plan

> **에이전트 작업자 필수 사항:** 이 계획은 `superpowers:subagent-driven-development`(권장) 또는 `superpowers:executing-plans`를 사용해 작업별로 구현한다. 진행 상태는 체크박스(`- [ ]`)로 추적한다.

**목표:** 애플리케이션과 상태 저장 ECS 서비스가 사용할 격리 Data subnet, Security Group, Secret 컨테이너, RDS MySQL, Valkey Serverless, Service Connect namespace와 추가 ECR repository를 구축한다.

**아키텍처:** 기존 v2 VPC의 예약 CIDR에 인터넷 경로 없는 Data subnet 2개를 만들고 RDS와 Valkey를 배치한다. 서비스별 Security Group reference로 통신 경계를 고정하며, 비밀값은 생성하지 않고 Secret metadata만 관리한다. 이후 두 계획은 이 계획의 namespace, Security Group, Secret ARN, 데이터 endpoint를 사용한다.

**기술 스택:** Terraform >= 1.7, AWS Provider 5.100.0, VPC, RDS MySQL, ElastiCache Valkey Serverless, Secrets Manager, Cloud Map, ECR, Terraform native test

**설계:** `v2/phase-2-architecture.md`

**구현 상태 (2026-10-11):** Task 1~6 소스 구현 및 native test 완료. 실제 Terraform Cloud plan/apply는 수행하지 않음.

## 전체 제약 조건

- 리전은 `ap-northeast-2`, VPC는 기존 `aws_vpc.main`을 사용한다.
- Data subnet CIDR은 `10.20.20.0/24`, `10.20.21.0/24`이며 인터넷 기본 경로를 만들지 않는다.
- RDS는 MySQL 8.0, `db.t4g.medium`, Single-AZ, 암호화 gp3 30GiB, 상한 100GiB, 백업 7일, deletion protection을 사용한다.
- Valkey는 Serverless, Data subnet 2개, snapshot 7일, IAM 인증을 사용한다.
- 실제 Secret 값과 `aws_secretsmanager_secret_version`을 만들지 않는다.
- 상태 저장 데이터용 관리형 서비스는 RDS MySQL과 Backend Valkey만 허용한다.
- 기존 v1 및 1차 v2 리소스를 import, 이동, 삭제하거나 의도하지 않게 교체하지 않는다.
- 커밋은 생성하지 않는다. 사용자가 직접 커밋한다.

## 중점 검토 항목

- Data subnet 목록 길이 또는 AZ 매핑 오류: 정확히 두 CIDR과 두 AZ가 아니면 validation이 실패해야 한다.
- Data subnet 인터넷 노출: Data route table에는 `0.0.0.0/0` route가 없어야 한다.
- Security Group 과다 허용: 애플리케이션·데이터 port에는 CIDR ingress가 없어야 하고 지정된 SG source만 허용해야 한다.
- Secret state 노출: Secret version, password 변수, secret value output이 없어야 한다.
- RDS·Valkey 삭제 위험: RDS deletion protection/final snapshot과 Valkey snapshot retention이 plan test로 고정되어야 한다.

---

## 파일 구성

| 파일 | 책임 |
| --- | --- |
| `v2/variables.tf` | Data, RDS, Valkey, phase2 bootstrap 변수와 validation |
| `v2/locals.tf` | Data subnet 및 서비스/Secret map |
| `v2/data-subnets.tf` | Data subnet, 격리 route table, association |
| `v2/application-security.tf` | Spring, FastAPI, Judge API, RDS, Valkey, Judge DB/Queue SG와 rule |
| `v2/service-connect.tf` | Cloud Map HTTP namespace |
| `v2/secrets.tf` | 서비스별 Secret metadata |
| `v2/rds.tf` | DB subnet group과 RDS MySQL |
| `v2/mysql-bootstrap.md` | 최소 권한 Spring DB 계정·schema 준비 절차 |
| `v2/valkey.tf` | IAM 인증 사용자·그룹과 Serverless cache |
| `v2/ecr.tf` | Judge PostgreSQL·Redis 전용 repository resource 추가 |
| `v2/outputs.tf` | 후속 계획이 사용하는 비민감 output |
| `v2/tests/phase-2-data.tftest.hcl` | Mocked 데이터 기반 계약 테스트 |

### Task 1: 2차 변수와 Data subnet

**파일:**

- 수정: `v2/variables.tf`, `v2/locals.tf`
- 생성: `v2/data-subnets.tf`
- 생성: `v2/tests/phase-2-data.tftest.hcl`

**인터페이스:**

- 입력: `data_subnet_cidrs`, 기존 `availability_zones`, `aws_vpc.main`
- 출력: `local.data_subnets`, `aws_subnet.data`, `aws_route_table.data`, `aws_route_table_association.data`

- [ ] **1단계: 실패 테스트 작성**

`phase-2-data.tftest.hcl`에 Data subnet 2개, CIDR/AZ 조합, `map_public_ip_on_launch=false`, route table 2개와 인터넷 default route 부재를 검증한다. CIDR 목록이 1개인 run은 `expect_failures = [var.data_subnet_cidrs]`로 거부한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: `data_subnet_cidrs` 또는 `aws_subnet.data`가 선언되지 않아 실패한다.

- [ ] **3단계: 변수·local 구현**

`data_subnet_cidrs` 기본값을 두 예약 CIDR로 정의하고 정확히 2개이며 모두 유효한 IPv4 CIDR인지 검증한다. `local.data_subnets`는 기존 subnet map과 같은 index key 및 `try` 패턴을 사용한다.

- [ ] **4단계: 격리 subnet 구현**

`aws_subnet.data`, AZ별 `aws_route_table.data`, association을 `for_each`로 만든다. NAT/IGW 기본 route와 public IP 자동 할당은 만들지 않는다.

- [ ] **5단계: 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: Data subnet 관련 run이 모두 통과한다.

### Task 2: 서비스별 Security Group 경계

**파일:**

- 생성: `v2/application-security.tf`
- 수정: `v2/tests/phase-2-data.tftest.hcl`

**인터페이스:**

- 입력: `aws_vpc.main.id`, `aws_security_group.alb.id`, 서비스 port 변수
- 출력: `aws_security_group.{spring,fastapi,judge_api,rds_mysql,backend_valkey,judge_postgres,judge_redis}`와 별도 ingress/egress rule

- [ ] **1단계: 실패 테스트 작성**

Spring은 ALB SG의 8080, FastAPI는 Spring SG의 8000, Judge API는 Spring/FastAPI SG의 3000, RDS는 Spring SG의 3306, Valkey는 Spring SG의 6379/6380, Judge PostgreSQL/Redis는 Judge API SG의 5432/6379만 허용하는지 검증한다. 애플리케이션 및 데이터 SG에 SSH와 `0.0.0.0/0` ingress가 없는지도 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: 신규 Security Group 리소스가 없어 실패한다.

- [ ] **3단계: SG와 rule 구현**

Inline rule 없이 SG를 만들고 모든 ingress를 `aws_vpc_security_group_ingress_rule`로 정의한다. 서비스 outbound는 초기 운영에 필요한 외부 API/AWS API 접근을 위해 전체 허용하되 ingress 경계는 SG source로 고정한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: 포트/source matrix 검증이 통과한다.

### Task 3: Service Connect namespace와 Secret metadata

**파일:**

- 생성: `v2/service-connect.tf`, `v2/secrets.tf`
- 수정: `v2/variables.tf`, `v2/locals.tf`, `v2/tests/phase-2-data.tftest.hcl`

**인터페이스:**

- 입력: `service_connect_namespace = "prod.cosmos-v2.local"`, `local.secret_names`
- 출력: `aws_service_discovery_http_namespace.main`, `aws_secretsmanager_secret.service` keyed map

- [ ] **1단계: 실패 테스트 작성**

HTTP namespace 이름과 `/cosmos-v2/prod/{spring,fastapi,judge-api,judge-postgres,judge-redis}` Secret 5개를 검증한다. 테스트와 정적 검사에서 `aws_secretsmanager_secret_version`이 없음을 확인한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: namespace와 Secret 리소스가 없어 실패한다.

- [ ] **3단계: namespace와 Secret 구현**

`aws_service_discovery_http_namespace.main`과 recovery window가 적용된 Secret metadata를 `for_each`로 만든다. Secret value, password, token은 변수와 output에 추가하지 않는다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl && ! rg -n 'aws_secretsmanager_secret_version|secret_string|password\s*=' v2 --glob '*.tf'`

기대 결과: namespace/Secret 테스트와 평문 비밀값 검사가 통과한다.

### Task 4: RDS MySQL

**파일:**

- 생성: `v2/rds.tf`
- 수정: `v2/variables.tf`, `v2/tests/phase-2-data.tftest.hcl`

**인터페이스:**

- 입력: Data subnet ID, RDS SG, `rds_instance_class`, storage 변수
- 출력: `aws_db_subnet_group.mysql`, `aws_db_instance.mysql`, RDS-managed master Secret ARN

- [ ] **1단계: 실패 테스트 작성**

MySQL 8.0, `db.t4g.medium`, gp3 30/100GiB, storage encryption, Single-AZ, public access false, backup 7일, deletion protection, final snapshot, RDS-managed master password와 Data subnet 2개를 검증한다. 30보다 작은 max storage는 validation으로 거부한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: RDS 리소스가 없어 실패한다.

- [ ] **3단계: RDS 구현**

DB identifier는 `cosmos-v2-prod-mysql`, database name은 `cosmos`, username은 `cosmos_admin`으로 고정한다. `manage_master_user_password=true`, `skip_final_snapshot=false`, 고정된 `final_snapshot_identifier` 접두사, maintenance 즉시 적용 비활성화를 사용한다.

- [ ] **4단계: MySQL bootstrap runbook 작성**

`v2/mysql-bootstrap.md`에 RDS-managed master Secret을 운영자 세션에서만 조회하고, `cosmos_app` 계정과 schema 권한을 생성한 뒤 `/cosmos-v2/prod/spring` Secret의 `db_username`/`db_password`를 입력하는 순서를 한국어로 기록한다. 실제 SQL password와 Secret 값은 문서나 Terraform에 넣지 않는다.

- [ ] **5단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: RDS 안전 조건이 모두 통과한다.

### Task 5: Backend Valkey Serverless IAM 인증

**파일:**

- 생성: `v2/valkey.tf`
- 수정: `v2/variables.tf`, `v2/tests/phase-2-data.tftest.hcl`

**인터페이스:**

- 입력: Data subnet ID, Valkey SG
- 출력: `aws_elasticache_user.spring`, `aws_elasticache_user_group.backend`, `aws_elasticache_serverless_cache.backend`

- [ ] **1단계: 실패 테스트 작성**

Valkey engine, IAM authentication mode, user group 연결, Data subnet 2개, Spring 전용 SG, snapshot 7일과 KMS 암호화를 검증한다. Password/no-password 인증 속성을 사용하지 않는지 확인한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: Valkey 리소스가 없어 실패한다.

- [ ] **3단계: IAM user와 cache 구현**

`aws_elasticache_user.spring.authentication_mode.type = "iam"`, `engine = "VALKEY"`, 최소 필요 access string을 사용한다. Serverless cache 이름은 `cosmos-v2-prod-backend`, snapshot retention은 7일로 설정한다.

- [ ] **4단계: 검증**

실행: `terraform -chdir=v2 validate && terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: Valkey IAM 인증과 network 조건이 통과한다.

### Task 6: 상태 저장 ECR 확장과 데이터 output

**파일:**

- 수정: `v2/variables.tf`, `v2/ecr.tf`, `v2/outputs.tf`, `v2/tests/phase-2-data.tftest.hcl`

**인터페이스:**

- 입력: 기존 애플리케이션 ECR 구조와 `local.stateful_ecr_repositories`
- 출력: 별도 `aws_ecr_repository.stateful` 및 lifecycle map, Data/RDS/Valkey/namespace/Secret output

- [ ] **1단계: 실패 테스트 작성**

애플리케이션 ECR 3개를 유지하면서 상태 저장 ECR 2개가 별도 resource map으로 생성되고 immutable, scan-on-push, AES256, lifecycle을 공유하는지 검증한다. 비민감 output의 존재와 map 크기를 검증한다.

- [ ] **2단계: 구현 전 실패 확인**

실행: `terraform -chdir=v2 test -filter=tests/phase-2-data.tftest.hcl`

기대 결과: 신규 repository와 output이 없어 실패한다.

- [ ] **3단계: ECR 기본값과 output 구현**

기존 `ecr_repository_names` 기본값과 `local.ecr_repositories`는 1차 호환을 위해 변경하지 않는다. `local.stateful_ecr_repositories = toset(["judge-postgres", "judge-redis"])`와 별도 repository/lifecycle resource를 추가한다. Data subnet ID, namespace ARN, RDS endpoint/port/master Secret ARN, Valkey endpoint/port/ARN, 서비스별 Secret ARN을 출력한다.

- [ ] **4단계: 전체 검증**

실행: `terraform -chdir=v2 fmt -check -recursive && terraform -chdir=v2 validate && terraform -chdir=v2 test && git diff --check`

기대 결과: 기존 1차 테스트와 데이터 기반 테스트가 모두 통과한다. 커밋하지 않는다.
