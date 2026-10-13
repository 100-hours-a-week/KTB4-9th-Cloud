# COSMOS v2 Stage 서비스 서브도메인 HTTPS 공개 설계

## 1. 배경

기존 v2 Stage 설계는 `https://stage.cosmoscode.site` 하나만 외부에 공개하고, CloudFront의 `/api/*`, `/auth/*` 요청만 ALB를 통해 Spring으로 전달한다. FastAPI와 Judge API는 Service Connect 내부 통신만 허용한다.

Stage 마이그레이션 및 통합 테스트를 위해 Spring Boot, FastAPI, Judge API의 문서와 실제 API를 각각 독립된 HTTPS 서브도메인으로 접근할 수 있어야 한다. 이번 설계는 기존 Route 53 명명 규칙을 유지하면서 Stage에서만 세 서비스를 인터넷에 공개한다.

이 문서는 기존 `2026-10-11-stage-prod-shared-vpc-design.md`의 “Stage 외부 주소는 프론트엔드 하나만 사용한다”는 제약을 Stage 테스트 기간에 한해 대체한다. Prod의 외부 공개 정책은 변경하지 않는다.

## 2. 목표

- 기존 Route 53의 `{환경}-{서비스}.cosmoscode.site` 명명 규칙을 유지한다.
- Stage ALB 하나에서 TLS를 종료하고 Host 기반으로 세 ECS Service에 요청을 전달한다.
- 테스트 기간에는 Stage ALB의 `443/tcp`를 인터넷 전체에 공개한다.
- 기존 CloudFront와 Stage 프론트엔드 경로를 그대로 유지한다.
- Spring, FastAPI, Judge API 이미지는 digest로 고정한다.
- Terraform plan에서 Stage 리소스만 변경되고 Prod 공개 DNS는 생성되지 않도록 한다.
- Swagger/OpenAPI 문서뿐 아니라 문서 화면에서 실행하는 실제 API 요청도 동작하게 한다.

## 3. 확인된 현재 상태

### 3.1 Route 53

Public Hosted Zone은 `cosmoscode.site.`이며 ID는 `Z09263573OIZVBLYL9OX7`이다. 기존 개발 서버는 다음 형식을 사용한다.

```text
dev-be.cosmoscode.site
dev-ai.cosmoscode.site
dev-judge.cosmoscode.site
```

Stage도 같은 규칙으로 구성한다.

```text
stage.cosmoscode.site         프론트엔드
stage-be.cosmoscode.site      Spring Boot
stage-ai.cosmoscode.site      FastAPI
stage-judge.cosmoscode.site   Judge API
```

### 3.2 인증서

`us-east-1`에는 `cosmoscode.site`, `*.cosmoscode.site`를 포함하는 발급 완료 인증서가 있다. 이 인증서는 CloudFront에는 사용할 수 있지만 리전 리소스인 서울 ALB에는 연결할 수 없다.

`ap-northeast-2`에는 현재 발급된 ACM 인증서가 없다. Shared Workspace가 서울 리전에 `*.cosmoscode.site` 인증서를 요청하고 ARN을 Stage/Prod remote state output으로 제공한다.

기존 Route 53에는 다음 ACM DNS 검증 CNAME이 유지되고 있다.

```text
_2b74e0a553b1cd45059ebfc3b928b794.cosmoscode.site
```

ACM DNS 검증 토큰은 같은 AWS 계정의 다른 리전에서도 재사용할 수 있으므로 Shared Terraform은 기존 CNAME을 새로 소유하거나 덮어쓰지 않는다. `aws_acm_certificate`와 `aws_acm_certificate_validation`만 관리하고, 기존 영구 CNAME을 이용해 발급 완료를 기다린다. 이렇게 하면 Shared destroy가 CloudFront 인증서 갱신에 필요한 기존 CNAME을 삭제하지 않는다.

### 3.3 ALB와 ECS

현재 Stage ALB는 다음 상태다.

- Internet-facing ALB
- HTTP `80` Listener만 존재
- `80/tcp`는 CloudFront origin-facing managed prefix list에서만 허용
- Spring Target Group만 존재
- Spring ECS Service만 ALB Target Group에 연결
- FastAPI와 Judge API는 Service Connect 내부 통신만 허용

애플리케이션 점검 결과 Terraform 기본값에도 다음 보완이 필요하다.

- Judge API 실제 포트는 `2358`이지만 Terraform 기본값은 `3000`이다.
- Judge에는 `/health` 라우트가 없고 `/`는 Rails 프로세스 liveness 확인에 사용할 수 있다.
- 공통 ECS container health check가 `curl`을 요구하지만 Spring과 FastAPI 이미지에는 `curl` 설치가 보장되지 않는다.

## 4. 선택한 방식

Stage ALB에 HTTPS Listener 하나와 서비스별 Host 기반 Listener Rule을 추가한다.

```text
Internet
   │ HTTPS 443
   ▼
Route 53 Public Hosted Zone
   ├─ stage-be.cosmoscode.site ─────┐
   ├─ stage-ai.cosmoscode.site ─────┼─ A Alias
   └─ stage-judge.cosmoscode.site ──┘
                                     ▼
                            cosmos-v2-stage-alb
                                     │
                 ┌───────────────────┼────────────────────┐
                 ▼                   ▼                    ▼
          Spring TG :8080     FastAPI TG :8000      Judge TG :2358
                 │                   │                    │
          Spring Fargate      FastAPI Fargate      Judge API Fargate
```

세 Route 53 레코드는 같은 Stage ALB에 대한 `A Alias`다. 정적 IP와 TTL 기반 `A` 레코드는 사용하지 않는다.

## 5. 대안과 선택 이유

### 5.1 선택: 단일 ALB HTTPS + Host 라우팅

- 기존 Stage ALB를 재사용한다.
- 인증서, Listener, Rule, Target Group만 추가한다.
- 테스트 환경에서 가장 단순하고 비용 증가가 작다.
- 서비스별 URL이 명확하고 Swagger의 실제 API 호출이 가능하다.

### 5.2 제외: 서비스별 CloudFront Distribution

ALB 직접 공개를 막을 수 있지만 Distribution 세 개, origin 정책, 캐시 정책과 인증서 alias 관리가 추가된다. 일시적인 Stage 테스트 목적에 비해 복잡성이 크므로 제외한다.

### 5.3 제외: 경로 기반 단일 도메인

`stage.cosmoscode.site/be`, `/ai`, `/judge`는 추가 DNS가 필요 없지만 애플리케이션 root path와 문서 asset 경로를 수정해야 한다. 기존 `{환경}-{서비스}` DNS 규칙과도 맞지 않으므로 제외한다.

## 6. TLS와 Listener

### 6.1 Shared Workspace

Shared root가 다음 리소스를 소유한다.

- `aws_acm_certificate.regional_wildcard`
  - Region: `ap-northeast-2`
  - Domain: `*.cosmoscode.site`
  - Validation: DNS
  - `create_before_destroy = true`
- `aws_acm_certificate_validation.regional_wildcard`
  - 기존 Route 53 ACM 검증 CNAME을 이용해 발급을 기다림
- Output: `regional_wildcard_certificate_arn`

기존 `us-east-1` CloudFront 인증서와 그 validation CNAME의 소유권은 변경하지 않는다.

### 6.2 Environment module

Environment module은 `regional_wildcard_certificate_arn`을 입력받는다. ARN은 반드시 `ap-northeast-2` ACM 인증서여야 한다.

Stage에는 다음 Listener를 추가한다.

```text
HTTPS :443
TLS policy: ELBSecurityPolicy-TLS13-1-2-2021-06
default action: fixed 404
certificate: regional_wildcard_certificate_arn
```

기존 HTTP `80` Listener는 CloudFront origin 전용으로 유지한다. 인터넷 전체에 `80/tcp`를 열지 않으며 HTTP→HTTPS 리다이렉트도 추가하지 않는다. Stage 서비스 주소는 반드시 `https://`로 접근한다.

## 7. Host 기반 라우팅

HTTPS Listener에는 Stage일 때만 다음 Rule을 만든다.

| Priority | Host | Target Group |
| ---: | --- | --- |
| 100 | `stage-be.cosmoscode.site` | Spring `:8080` |
| 110 | `stage-ai.cosmoscode.site` | FastAPI `:8000` |
| 120 | `stage-judge.cosmoscode.site` | Judge API `:2358` |

Host가 일치하지 않으면 HTTPS Listener는 `404 Not Found`를 반환한다. HTTP Listener의 기존 CloudFront→Spring path forwarding은 유지해 `stage.cosmoscode.site/api/*`, `/auth/*` 동작을 보존한다.

Prod에는 위 Stage Host Rule과 Route 53 레코드를 생성하지 않는다. Prod 공개 DNS 전환은 기존 `enable_public_dns_cutover` 절차를 유지한다.

## 8. Target Group과 Health Check

Environment module은 환경별 외부 진입 계약에 따라 Target Group을 관리한다. Stage는 세 애플리케이션 Target Group을 생성하고, Prod는 이번 변경의 영향을 받지 않도록 기존 Spring Target Group만 유지한다.

| 서비스 | 포트 | Health path | Matcher |
| --- | ---: | --- | --- |
| Spring | 8080 | `/actuator/health` | `200` |
| FastAPI | 8000 | `/health` | `200` |
| Judge API | 2358 | `/` | `200` |

공통 설정은 다음과 같다.

- Protocol: HTTP
- Target type: `ip`
- Deregistration delay: 30초
- Stickiness: 비활성화
- Interval: 30초
- Timeout: 5초
- Healthy threshold: 2
- Unhealthy threshold: 3

Stage의 세 ECS Service는 모두 자신의 Target Group에 연결한다. Prod는 기존처럼 Spring ECS Service만 ALB Target Group에 연결하고 FastAPI와 Judge API는 내부 서비스로 유지한다. `enable_phase2_services = false`일 때 Task, Service와 Listener Rule은 생성하지 않고 Target Group과 기반 ALB만 안전한 상태로 유지한다.

ECS container-level health check는 이미지 내부의 `curl` 존재를 가정하므로 제거한다. 서비스 배포 상태와 트래픽 수용 여부는 ALB Target Group health check 및 ECS deployment circuit breaker로 판단한다.

## 9. Security Group

Stage ALB Security Group에 다음 규칙을 추가한다.

```text
source: 0.0.0.0/0
protocol: TCP
port: 443
description: Temporary public HTTPS access for stage service testing
```

ALB는 현재 IPv4로 동작하므로 `::/0` 규칙은 추가하지 않는다. 기존 CloudFront managed prefix list→`80/tcp` 규칙은 유지한다.

애플리케이션 Security Group에는 ALB Security Group을 source로 한 다음 ingress를 추가한다.

| 대상 SG | Source SG | Port |
| --- | --- | ---: |
| Spring | Stage ALB SG | 8080 |
| FastAPI | Stage ALB SG | 8000 |
| Judge API | Stage ALB SG | 2358 |

FastAPI의 Spring ingress와 Judge API의 Spring/FastAPI ingress는 내부 호출을 위해 그대로 유지한다. 데이터베이스, Valkey, Judge PostgreSQL/Redis와 Worker는 외부에 공개하지 않는다.

인터넷 전체 공개는 Stage 테스트를 위한 임시 결정이다. 운영 전에는 IP allowlist, WAF 또는 CloudFront 보호 계층 중 하나로 교체해야 한다.

## 10. Route 53

Environment module은 Stage일 때만 다음 `A Alias`를 생성한다.

```text
stage-be.cosmoscode.site
stage-ai.cosmoscode.site
stage-judge.cosmoscode.site
```

각 레코드는 다음 값을 사용한다.

```text
alias.name                   = Stage ALB DNS name
alias.zone_id                = Stage ALB canonical hosted zone ID
alias.evaluate_target_health = true
```

기존 `stage.cosmoscode.site` CloudFront Alias는 변경하지 않는다.

## 11. 공개 URL과 Terraform output

Stage 적용 후 다음 URL을 제공한다.

```text
Spring Swagger: https://stage-be.cosmoscode.site/swagger-ui/index.html
FastAPI Swagger: https://stage-ai.cosmoscode.site/docs
Judge 문서:     https://stage-judge.cosmoscode.site/swagger.html
```

Environment module은 서비스 URL map을 output한다.

```hcl
stage_service_urls = {
  spring    = "https://stage-be.cosmoscode.site"
  fastapi   = "https://stage-ai.cosmoscode.site"
  judge_api = "https://stage-judge.cosmoscode.site"
}
```

Stage root도 같은 output을 노출한다. Prod에서는 빈 map을 반환한다.

## 12. 이미지와 런타임 계약

Stage Fargate 서비스는 다음 ECR index digest를 사용한다. 각 index는 `linux/amd64` 실행 manifest를 포함한다.

```text
spring_image_digest  = sha256:d2e85f1fb9eeaa8f367dd79fd78f0731cba3618b0d09e1573eaa5f913a2575f9
fastapi_image_digest = sha256:6f763b65c0e0ae84eeb36572ded74a9e39a97ee3ce535f41c9b7bcdf5dcaa861
judge_image_digest   = sha256:e44c0adc000802b40bffc82043d922b934294e5d147fb86dc220ef195e99416b
```

Judge API와 Judge Worker는 같은 digest를 사용하되 command를 분리한다.

```text
API:    ./scripts/server
Worker: ./scripts/workers
```

## 13. 단계적 적용 순서

### 13.1 Shared

1. 서울 리전 wildcard 인증서 plan
2. 기존 DNS validation CNAME으로 인증서 발급 확인
3. Shared output에 인증서 ARN 노출

### 13.2 Stage 기반 리소스

1. Stage remote state에서 Shared 인증서 ARN 수신
2. HTTPS Listener, Target Group, Security Group rule와 Route 53 Alias 생성
3. `enable_phase2_services = false` 상태에서 기반 plan/apply 확인

### 13.3 Secret 준비

Terraform이 생성한 Secrets Manager metadata에 서비스별 실제 Secret 값을 입력한다. Secret 값이 준비되기 전에는 애플리케이션 서비스를 활성화하지 않는다.

### 13.4 서비스 활성화

다음 값을 적용한다.

```hcl
enable_stateful_services = true
enable_phase2_services   = true

spring_image_digest  = "sha256:d2e85f1fb9eeaa8f367dd79fd78f0731cba3618b0d09e1573eaa5f913a2575f9"
fastapi_image_digest = "sha256:6f763b65c0e0ae84eeb36572ded74a9e39a97ee3ce535f41c9b7bcdf5dcaa861"
judge_image_digest   = "sha256:e44c0adc000802b40bffc82043d922b934294e5d147fb86dc220ef195e99416b"
```

Judge PostgreSQL/Redis 공식 이미지 reference와 Secret 준비가 완료되어야 `enable_stateful_services`를 활성화할 수 있다. Judge Worker capacity와 Worker service는 별도 flag로 후속 활성화할 수 있으며 Swagger 공개를 위해 반드시 필요하지는 않다.

## 14. 검증 계획

### 14.1 정적 검증

- `terraform fmt -check -recursive v2`
- Shared, Stage, Prod `terraform validate`
- module Terraform test
- `git diff --check`

### 14.2 Terraform 계약 테스트

- 서울 리전 인증서 ARN output
- Stage HTTPS Listener의 포트, TLS policy, 인증서
- Stage에서만 443 public ingress 생성
- Prod에는 Stage DNS와 Stage Listener Rule이 없음
- Stage Target Group 세 개의 포트와 health path
- Stage ECS Service 세 개의 Target Group 연결
- Prod는 Spring Target Group과 연결만 유지
- FastAPI/Judge API에 대한 ALB SG ingress
- Stage Route 53 Alias 세 개
- 서비스 URL output 세 개
- Judge 포트 `2358`
- ECS container definition에 `curl` health check가 없음

### 14.3 배포 후 Smoke Test

```text
GET https://stage-be.cosmoscode.site/actuator/health
GET https://stage-be.cosmoscode.site/swagger-ui/index.html
GET https://stage-ai.cosmoscode.site/health
GET https://stage-ai.cosmoscode.site/docs
GET https://stage-judge.cosmoscode.site/
GET https://stage-judge.cosmoscode.site/swagger.html
```

각 요청은 유효한 공개 인증서 체인과 기대한 HTTP 상태를 반환해야 한다. ALB의 세 Target Group은 healthy여야 하고 ECS deployment circuit breaker가 rollback 상태가 아니어야 한다.

## 15. 롤백

서비스 장애 시 다음 순서로 외부 진입점만 먼저 차단한다.

1. Stage Route 53 서비스 Alias 세 개 제거
2. HTTPS Host Listener Rule 비활성화 또는 제거
3. ALB public 443 ingress 제거
4. 필요하면 `enable_phase2_services = false`로 서비스 중지

Regional ACM 인증서는 다른 Stage/Prod ALB에서 재사용할 수 있으므로 즉시 제거하지 않는다. 기존 `stage.cosmoscode.site` CloudFront와 `/api/*`, `/auth/*` 경로는 롤백 대상에 포함하지 않는다.

## 16. 제외 범위

- Prod 서비스 서브도메인 공개
- WAF, Cognito/OIDC, Basic Auth
- HTTP 80 인터넷 공개 및 HTTP→HTTPS 리다이렉트
- CI/CD 자동 배포
- 애플리케이션 저장소 변경
- 프론트엔드 배포
- Judge Worker 자동 확장 활성화
