# COSMOS v2 애플리케이션 마이그레이션 전략

## 1. 목표와 원칙

데이터가 없는 Stage 환경에서 애플리케이션 계약을 검증한 뒤, 검증된 동일 산출물을 Prod로 승격한다. v1에서 데이터베이스 데이터를 복사하는 작업은 포함하지 않으며, Prod DNS 전환 전까지 v1을 rollback 경로로 유지한다.

핵심 원칙은 다음과 같다.

- 환경마다 이미지를 다시 빌드하지 않고 동일한 ECR image digest를 사용한다.
- 환경 차이는 Secret과 Terraform 환경 변수로만 주입한다.
- 외부 공개 지점은 CloudFront 하나이며, API는 `/api/*`, `/auth/*`를 통해 ALB로 전달한다.
- AI와 Judge API는 외부에 공개하지 않고 Service Connect 내부 주소로만 호출한다.
- 스키마 변경은 이전 버전과 호환되는 전진형 변경을 우선한다.

## 2. 산출물 계약

| 구성 요소 | 승격 단위 | 필수 확인 |
| --- | --- | --- |
| Frontend | 동일 빌드 디렉터리 또는 산출물 checksum | Stage/Prod API 경로가 상대 경로인지 확인 |
| Spring API | ECR digest | health, DB·Valkey 연결, AI·Judge 내부 호출 |
| AI | ECR digest | health, Judge 내부 호출, 외부 비공개 |
| Judge API | Judge 공용 ECR digest | `./scripts/server`, health, PostgreSQL·Redis 연결, 외부 비공개 |
| Judge Worker | Judge 공용 ECR digest | `./scripts/workers`, Queue 처리, SIGTERM, sandbox, 리소스 제한 |

애플리케이션 이미지는 `spring`, `fastapi`, `judge` ECR repository 3개를 유지한다. Judge API와 Worker는 동일 digest를 사용하며 실행 command만 분리한다. PostgreSQL·Valkey 공식 image도 `@sha256:`으로 고정하고 `latest` 같은 가변 태그를 사용하지 않는다.

## 3. Stage 검증 절차

1. Frontend와 세 애플리케이션 이미지를 빌드하고 digest/checksum을 릴리스 기록에 남긴다.
2. Stage Secret에 데이터베이스와 내부 서비스 설정을 등록한다.
3. stateful 계층과 빈 스키마를 준비한다.
4. Spring API, AI, Judge API를 각각 1개 Task로 배포한다.
5. Worker 용량과 Worker 1개를 순차 배포한다.
6. `https://stage.cosmoscode.site`에서 아래 검증표를 수행한다.

| 영역 | 검증 항목 |
| --- | --- |
| Frontend | 정적 자산, SPA 새로고침, 404 fallback, 캐시 갱신 |
| 공개 API | `/api/*`, `/auth/*`, 인증, CORS, 오류 응답 |
| 내부 통신 | API→AI, API→Judge, AI→Judge Service Connect 호출 |
| 데이터 | MySQL 스키마·권한, Valkey IAM 인증, Judge PostgreSQL·Redis |
| Worker | Queue 입력부터 결과 저장까지, 재시도, SIGTERM 종료 |
| 운영 | CloudWatch 로그, ALB target health, ECS Task 교체 |
| 보안 | S3 비공개, 내부 서비스 비공개, Secret 미노출 |

## 4. Prod 승격

1. Stage에서 검증한 digest와 frontend checksum을 동결한다.
2. Prod Secret과 빈 스키마를 준비한다.
3. Stage와 같은 순서로 Prod 서비스를 활성화하되 동일 digest를 입력한다.
4. CloudFront 기본 도메인과 내부 상태 점검으로 Prod를 검증한다.
5. 모든 검증이 끝난 뒤에만 `enable_public_dns_cutover=true`로 변경해 Prod alias를 연결한다.
6. DNS와 CloudFront 전파 중에는 v1을 유지하고 오류율·응답 시간·로그를 관찰한다.

Prod 공개 DNS 전환은 인프라 생성과 분리된 명시적 변경으로 처리한다. 이를 통해 준비되지 않은 Prod가 사용자 트래픽을 받는 것을 막는다.

## 5. Rollback 전략

### 5.1 DNS 전환 직후

- `enable_public_dns_cutover=false`로 되돌려 새 Prod alias 연결을 제거하고 v1 경로를 복구한다.
- v2 리소스는 즉시 destroy하지 않고 원인 분석을 위해 유지한다.

### 5.2 ECS 애플리케이션

- 직전 정상 digest로 Terraform 변수를 되돌리고 ECS 배포를 실행한다.
- 새 Task가 healthy가 된 뒤 이전 Task를 종료한다.
- AI·Judge처럼 연관된 계약이 바뀐 경우 호환되는 digest 묶음을 함께 되돌린다.

### 5.3 Frontend

- 직전 산출물을 S3에 다시 동기화하고 `/index.html`을 invalidation한다.
- API와 호환되지 않는 frontend만 단독 승격하지 않는다.

### 5.4 데이터베이스

- 파괴적인 down migration에 의존하지 않는다.
- 컬럼·테이블 추가 → 양쪽 버전 호환 → 코드 전환 → 후속 정리 순서로 변경한다.
- 장애 시에는 이전 애플리케이션이 새 스키마에서 동작하도록 유지하고 후속 forward fix를 우선한다.

## 6. v1 종료 기준

다음 조건을 모두 만족할 때 별도 변경으로 v1 종료를 진행한다.

- Prod 공개 경로가 안정화되고 합의한 관찰 기간 동안 치명 오류가 없다.
- v2의 API, 내부 호출, Worker, 로그와 알람이 정상이다.
- rollback용 정상 digest와 frontend 산출물이 보존되어 있다.
- v1로 향하는 DNS, 비동기 작업, 외부 연동이 없음을 확인했다.
- v1 데이터와 리소스의 보존·폐기 책임자가 승인했다.

v1 종료는 이번 Terraform 구현 범위에 포함하지 않는다.
