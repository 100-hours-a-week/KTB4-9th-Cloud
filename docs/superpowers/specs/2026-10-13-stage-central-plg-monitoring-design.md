# Stage 중앙 PLG 모니터링 설계

## 1. 목적

서울 리전의 COSMOS V2 Stage 환경을 중앙에서 관측할 수 있도록 Prometheus, Loki, Grafana(PLG) 기반 모니터링을 구성한다. 초기 검증에서는 오레곤 리전의 기존 `COSMOS-test-monitoring-server`를 재사용하고, Grafana에서 Stage 전용 대시보드와 로그를 실제로 확인할 수 있어야 한다.

장기 목표는 같은 구성을 서울 리전의 전용 ECS on EC2 모니터링 클러스터로 이전하는 것이다. 현재 운영하지 않는 Prod 환경의 수집기, 대시보드와 알림은 이번 범위에서 제외한다.

## 2. 현재 상태

### 2.1 Stage

- 리전: `ap-northeast-2`
- ECS Cluster: `cosmos-v2-stage-cluster`
- Spring, FastAPI, Judge API: ECS on Fargate
- Judge Worker: ECS on EC2 Capacity Provider
- MySQL: Amazon RDS
- 애플리케이션 및 상태 저장 서비스 로그: 서비스별 CloudWatch Log Group
- 외부 요청 진입점: ALB와 CloudFront

### 2.2 기존 모니터링 서버

- 리전: `us-west-2`
- EC2: `COSMOS-test-monitoring-server`
- Instance ID: `i-0021b7626e459a03f`
- Instance type: `t3.small`
- 운영체제: Ubuntu 22.04
- EBS: gp3 30GiB
- 실행 중인 컨테이너:
  - Prometheus
  - Loki
  - Grafana
  - Promtail
  - Nginx
- Grafana 주소: `https://grafana.cosmoscode.site`
- 현재 EC2는 ECS Cluster에 등록되어 있지 않으며 IAM Instance Profile과 SSM 연결이 없다.

## 3. 범위

### 3.1 포함

- 기존 Grafana에 `COSMOS / Stage` 폴더 생성
- Stage ECS, ALB, RDS, EC2 지표 조회
- Stage CloudWatch Logs 조회
- Prometheus와 Loki 직접 수집 경로의 기반 구성
- Stage 대시보드 생성 및 실제 데이터 검증
- 오레곤 모니터링 EC2에 최소 권한 IAM Instance Profile 연결
- 기존 PLG 설정 및 데이터 백업
- 기존 Dev 및 부하 테스트 대시보드 보존

### 3.2 제외

- Prod 수집기, 대시보드와 알림
- 기존 오레곤 EC2의 즉시 ECS 전환
- 서울 리전 전용 모니터링 ECS Cluster의 실제 생성
- 다중 인스턴스 고가용성
- 장기 보존 스토리지
- 애플리케이션 비즈니스 지표의 전면 계측

## 4. 단계적 아키텍처

### 4.1 1단계: 기존 오레곤 PLG를 이용한 Stage 검증

```text
서울 Stage AWS 리소스
├── ECS / ALB / RDS / EC2
│       └── CloudWatch Metrics ─────────────────────┐
├── 서비스별 CloudWatch Log Group ─────────────────┤
├── 애플리케이션 /metrics ── Alloy ── remote_write ┤
└── 컨테이너 stdout ── FireLens ── HTTPS push ─────┤
                                                    ▼
오레곤 COSMOS-test-monitoring-server
├── Nginx: TLS 및 수집 인증 경계
├── Prometheus: 메트릭 저장과 조회
├── Loki: 로그 저장과 조회
└── Grafana
    └── COSMOS / Stage
```

CloudWatch 데이터소스를 우선 연결하여 애플리케이션 변경 없이 AWS 인프라 지표와 기존 로그를 가시화한다. Alloy와 FireLens 직접 수집은 다음 순서로 추가하며, 기존 CloudWatch 전송은 제거하지 않는다.

### 4.2 2단계: 서울 ECS on EC2로 이전

Stage 검증을 완료한 후 `shared` 영역에 다음 모니터링 전용 기반을 만든다.

- 전용 ECS Cluster
- 전용 On-Demand `t3.small` Auto Scaling Group
- ASG 설정: min 1, desired 1, max 1
- 전용 ECS Capacity Provider
- Private subnet, Public IP 및 SSH 미사용
- SSM 기반 운영
- Prometheus, Loki, Grafana, Alloy ECS Service
- 서비스별 암호화 gp3 EBS
- ALB와 ACM을 통한 Grafana HTTPS 공개

Stage에서 검증한 대시보드 JSON, Prometheus rule, Loki 설정과 Grafana provisioning 파일을 그대로 이전할 수 있게 관리한다.

## 5. 데이터 수집 설계

### 5.1 우선 수집: CloudWatch

Grafana CloudWatch 데이터소스는 오레곤 EC2의 IAM Role을 사용한다. 장기 Access Key는 서버나 Grafana 데이터베이스에 저장하지 않는다.

조회 대상은 다음과 같다.

- `AWS/ECS`: 서비스 CPU 및 메모리 사용률
- `ECS/ContainerInsights`: 활성화된 경우 task 및 container 지표
- `AWS/ApplicationELB`: 요청 수, target response time, HTTP 4xx/5xx, healthy/unhealthy host
- `AWS/RDS`: CPU, 연결 수, free storage, latency
- `AWS/EC2`: Judge Worker와 상태 저장 호스트의 CPU 및 status check
- CloudWatch Logs: Spring, FastAPI, Judge API, Judge Worker와 상태 저장 서비스 로그

### 5.2 Prometheus 직접 수집

서울 Stage 내부의 Grafana Alloy가 private endpoint를 수집하고 오레곤 Prometheus로 `remote_write`한다. 오레곤 Prometheus가 서울 private IP를 직접 scrape하지 않는다.

초기 수집 후보는 다음과 같다.

- Spring Actuator `/api/actuator/prometheus`
- FastAPI Prometheus endpoint
- Judge API metrics endpoint
- Judge Worker metrics endpoint
- EC2 node exporter
- 필요 시 cAdvisor 또는 ECS/CloudWatch exporter

각 endpoint의 실제 존재 여부를 구현 전 점검하고, 없는 endpoint는 이번 단계에서 억지로 추가하지 않는다. 해당 서비스는 우선 CloudWatch 지표로 관측한다.

### 5.3 Loki 직접 수집

신규 task revision에는 FireLens를 사용해 로그를 이중 전송한다.

- 1차 출력: 기존 CloudWatch Logs
- 2차 출력: Nginx HTTPS를 통한 오레곤 Loki

Loki endpoint는 외부 3100 포트를 직접 공개하지 않고 `443`의 전용 경로로만 제공한다.

## 6. 공통 라벨

모든 직접 수집 데이터에는 다음 저카디널리티 라벨을 적용한다.

```text
environment=stage
region=ap-northeast-2
cluster=cosmos-v2-stage-cluster
service=spring|fastapi|judge-api|judge-worker
```

`user_id`, `request_id`, 전체 URL, 오류 메시지와 같이 값의 종류가 계속 증가하는 항목은 Loki나 Prometheus 라벨로 사용하지 않는다. 이러한 값은 로그 본문에만 둔다.

## 7. 보안 설계

- Grafana 사용자 접근은 `https://grafana.cosmoscode.site`의 443으로 제한한다.
- Prometheus 9090과 Loki 3100은 인터넷에 직접 공개하지 않는다.
- Nginx에 Prometheus remote-write와 Loki push 전용 경로를 만든다.
- 수집 endpoint는 TLS와 별도 인증정보로 보호한다.
- Stage 수집 인증정보는 AWS Secrets Manager에서 ECS task에 주입한다.
- EC2 IAM Role은 CloudWatch, CloudWatch Logs 및 리소스 조회에 필요한 읽기 권한만 가진다.
- 기존 `0.0.0.0/0` 대상 SSH 22와 Grafana 3000 규칙은 원격 운영 경로를 대체한 뒤 제거한다.
- IMDSv2를 필수로 전환한다.
- 설정 파일이나 Terraform state에 비밀번호를 평문으로 저장하지 않는다.

## 8. 보존 및 자원 제한

기존 서버는 `t3.small`과 30GiB EBS이므로 검증 기간에는 다음 값을 사용한다.

- Prometheus retention: 7일
- Loki retention: 7일
- 기본 scrape interval: 30초
- 핵심 상태 지표: 필요 시 15초
- 로그 및 메트릭 저장소 사용률: 70% 경고
- 메모리 사용률: 80% 경고

설정 변경 전 `/opt/monitoring`과 Grafana 데이터를 백업한다. 기존 Dev와 부하 테스트 데이터는 삭제하지 않는다.

## 9. Grafana 구성

다음 폴더와 대시보드를 생성한다.

```text
COSMOS
└── Stage
    ├── 01 - Stage Overview
    ├── 02 - ECS Services
    ├── 03 - ALB and HTTP
    ├── 04 - Databases
    ├── 05 - Judge Worker
    ├── 06 - Application Logs
    └── 07 - PLG Self Monitoring
```

### 9.1 Stage Overview

- ECS 실행/대기 task
- 서비스별 CPU 및 메모리
- ALB 요청량과 5xx 비율
- Target Group health
- RDS CPU 및 연결 수
- 최근 오류 로그

### 9.2 ECS Services

- Spring, FastAPI, Judge API, Judge Worker별 desired/running/pending
- CPU 및 메모리
- task 시작/중단 추이
- 배포 revision과 서비스 이벤트 확인 링크

### 9.3 ALB and HTTP

- 요청 수
- 평균 및 p95 응답시간
- ALB 4xx/5xx와 target 4xx/5xx
- healthy/unhealthy target
- host별 필터

### 9.4 Databases

- RDS CPU, 연결 수, free storage, read/write latency
- Valkey 및 PostgreSQL은 노출 가능한 CloudWatch 또는 exporter 지표만 표시

### 9.5 Judge Worker

- ECS desired/running/pending
- On-Demand 및 Spot ASG 상태
- EC2 CPU와 status check
- Worker 로그와 오류 건수
- Queue backlog 지표가 제공되면 추가하고, 제공되지 않으면 패널에 임의 값을 만들지 않는다.

### 9.6 Application Logs

- 서비스, 로그 레벨 및 검색어 변수
- 오류 로그 집계
- 선택한 로그 스트림 원문
- CloudWatch와 Loki가 모두 연결된 동안 데이터소스를 선택할 수 있게 구성

### 9.7 PLG Self Monitoring

- Prometheus target 및 remote-write 상태
- Loki ingestion 오류
- Grafana 상태
- EC2 메모리와 디스크

## 10. 장애와 복구

- 직접 수집 경로 실패 시 CloudWatch Logs와 AWS 기본 지표를 보조 관측 경로로 사용한다.
- 오레곤 EC2 장애는 Stage 애플리케이션 트래픽에 영향을 주지 않는다.
- FireLens의 원격 Loki 출력 장애가 애플리케이션 task를 종료시키지 않도록 버퍼와 재시도 한도를 둔다.
- 대시보드와 데이터소스는 provisioning 파일로 재생성할 수 있어야 한다.
- 기존 PLG 데이터 변경 전 EBS snapshot 또는 파일 백업을 수행한다.

## 11. 검증 기준

다음 조건을 모두 충족하면 1단계 구축이 완료된 것으로 본다.

1. Grafana에 `COSMOS / Stage` 폴더와 일곱 개 대시보드가 보인다.
2. Stage ECS 서비스 CPU 또는 task 지표가 실제 값으로 표시된다.
3. ALB 요청을 발생시키면 요청량과 응답 코드 패널이 갱신된다.
4. RDS 지표가 표시된다.
5. Spring 오류 로그를 Grafana에서 검색할 수 있다.
6. 기존 Dev 및 부하 테스트 대시보드와 데이터가 유지된다.
7. Grafana datasource에 장기 AWS Access Key가 저장되지 않는다.
8. Prometheus 9090과 Loki 3100이 인터넷에 직접 공개되지 않는다.

## 12. 이후 확장

- Prod 운영 시작 시 동일한 템플릿으로 `COSMOS / Prod` 폴더 추가
- 서울 리전의 전용 ECS on EC2 모니터링 Cluster 구축
- `t3.small`의 메모리와 디스크 사용량을 근거로 instance 및 EBS 크기 조정
- Alertmanager 또는 Grafana Alerting 알림 채널 연결
- Judge Queue backlog 기반 자동 확장 지표 연결
- 애플리케이션 SLI/SLO와 분산 추적 추가
