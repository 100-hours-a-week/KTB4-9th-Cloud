# v3-john 장애 주입과 장애 대응 설계

작성일: 2026-11-10 · 대상: `v3-john` 훈련 클러스터 · 기간: 2~3주

## 1. 목적

운영에서 터질 약점을 장애 주입으로 먼저 찾고, 고친 뒤 같은 실험으로 개선을 수치로 증명한다. 모든 도구 도입은 "실험에서 드러난 문제 → 대안 비교 → 선택 → 같은 실험으로 재측정" 순서를 따른다. 결과물은 이력서와 포트폴리오에 쓸 수 있는 실험 기록, 포스트모템, 전후 비교 수치다.

## 2. 제약

- v3-john은 작업할 때만 `up.sh`로 띄우고 `down.sh`로 내린다. 모든 도구와 실험은 `up.sh` 한 번으로 재현되어야 하고, 실험 결과는 S3와 문서로 남긴다.
- 수정은 인프라와 설정만 한다(Helm 값, 환경 변수, 쿠버네티스 리소스, Istio 정책). 예외는 Judge(Rails)의 OTel gem 추가 하나이며, 사용자가 Judge 저장소 브랜치에서 직접 한다. 앱 코드 수정이 필요한 문제는 개선 제안으로만 기록한다.
- Spot vCPU 한도는 32개다. 현재 노드는 system 1대(2 vCPU), stateful 1대(2), judge 1대(4), application 2대(8)로 16 vCPU다.
- 승격 파이프라인(`v3-promote`)이 `v3-john` 값 파일을 자동으로 고치므로, 실험용 변경은 값 파일의 `image`, `sourceRevision` 줄을 건드리지 않는다.

## 3. 현재 구조에서 확인한 사실

- 동기 HTTP 호출: Spring(core, auth, battle) → `ai-llm-service`, `judge-api-service` / AI(ai-llm, ai-make-problem, ai-problem-batch) → `core-service`, `judge-api-service`. core와 AI가 서로 호출한다.
- 비동기: judge-api → `judge-redis-queue` → judge-worker(KEDA 확장), judge-postgres.
- 언어: Java(Spring), Python(FastAPI), Ruby(Rails).
- 모든 앱 Deployment는 HPA 최소 1개다. 차트에 PodDisruptionBudget이 없다. application 노드 그룹은 min=max=2라 여유 노드가 없다.
- 관측: Prometheus, Alertmanager(Discord), Loki, Alloy, Grafana가 있다. 트레이스와 SLO 알림은 없다.

## 4. 접근 방식

가설 기반 2단계 비교를 택한다. Istio를 먼저 설치하는 방식은 도입 전 수치가 없어 개선을 증명할 수 없고, AWS FIS만 쓰는 방식은 서비스 구간 장애 표현력이 약해 기각했다.

| 단계 | 내용 | 다음 단계로 가는 조건 |
|---|---|---|
| 0. 기준선 | SLO, k6 사용자 시나리오, RED 대시보드, burn rate 알림, 실험 기록 양식 | 기준선 수치 3회 측정 완료 |
| 1. 현재 구조 실험 | Chaos Mesh와 FIS로 E1~E6 실행, 설정으로 고칠 수 있는 약점 수정 | 결과 기록 완료 |
| 2a. 트레이스 | E5의 원인 파악 시간이 근거가 되면 OTel + Tempo 도입 후 E5 재실행 | E5 원인 파악 시간 10분 초과 |
| 2b. Istio | E4의 연쇄 장애가 근거가 되면 Istio 도입 후 E4, E5 재실행 | E4에서 직접 장애가 아닌 서비스의 SLO 위반 |

조건을 넘지 못하면 해당 도구는 도입하지 않고 "검토 후 미도입" 결과로 기록한다.

## 5. 구성 요소

| 구성 요소 | 역할 | 설치 위치 |
|---|---|---|
| Chaos Mesh | 파드, 네트워크 장애 주입. 실험을 YAML로 저장한다 | `chaos-mesh` 네임스페이스, `up.sh` |
| AWS FIS | Spot 회수 장애 주입 | Terraform `environments/eks`, 실험 템플릿과 IAM 역할 |
| k6 | 실험 중 사용자 흐름 생성. 결과는 Prometheus remote write로 보낸다 | `chaos` 네임스페이스 Job |
| SLO 규칙 | 기록 규칙과 다중 창 burn rate 알림 | PrometheusRule |
| 실험 실행기 | Grafana 주석 기록, k6와 장애 주입 실행, 결과 S3 저장 | `v3-john/chaos/run-experiment.sh` |
| OTel Operator + Tempo | Java, Python은 Operator 자동 계측(init container로 에이전트 주입), Ruby는 gem. Alloy가 OTLP를 받아 Tempo로 보낸다. Tempo는 S3에 저장한다 | 2a 단계 |
| Istio | sidecar 모드. `prod`의 HTTP 서비스만 메시에 넣고 judge-worker, 상태 저장 서비스는 제외한다 | 2b 단계 |

Istio는 ambient 대신 sidecar 모드를 쓴다. 기존 NetworkPolicy가 앱 포트 기준으로 작성되어 있어 sidecar 모드가 정책 변경이 적고, L7 정책(타임아웃, 재시도, 서킷 브레이커)을 waypoint 없이 바로 쓸 수 있다.

## 6. SLO

| SLO | 지표 | 목표 |
|---|---|---|
| 가용성 | Envoy Gateway 기준 `/api` 요청 중 5xx가 아닌 비율 | 99.5% (30일) |
| 제출 지연 | `POST /api/submissions` p95 | 1초 이하 |
| 채점 처리 | 제출 후 결과 조회 성공까지 k6 측정값 p95 | 30초 이하 |

burn rate 알림은 1시간 창 14.4배(긴급), 6시간 창 6배(경고)로 둔다. 실험 시간이 짧아 탐지 시간 측정에는 5분 창 14.4배 알림을 추가한다.

## 7. 실험 목록

| ID | 장애 | 도구 | 가설 | 예상 약점과 1단계 대응 |
|---|---|---|---|---|
| E1 | core 파드 강제 종료 | PodChaos | 30초 안에 복구되고 가용성 SLO를 지킨다 | 최소 1개라 재시작 동안 전면 중단 → 최소 2개, PDB |
| E2 | 부하 중 judge-worker 전부 종료 | PodChaos | 대기열 작업이 유실 없이 재처리된다 | 처리 중 작업 유실 여부 확인 → 유실 시 개선 제안 |
| E3 | application Spot 노드 회수 | FIS | 2분 안에 다른 노드로 옮기고 에러율 1% 미만 | 여유 노드 없음, PDB 없음 → max_size 3, PDB, topology spread |
| E4 | core → ai-llm 구간 지연 3초 | NetworkChaos | AI 기능만 느려지고 로그인과 제출은 SLO를 지킨다 | 스레드, 커넥션 고갈로 연쇄 장애 → 2b Istio 근거 |
| E5 | judge-postgres 구간 지연 500ms | NetworkChaos | 지표와 로그만으로 10분 안에 원인을 찾는다 | 원인 파악 지연 → 2a 트레이스 근거 |
| E6 | core → RDS 연결 차단 60초 | NetworkChaos | 차단 해제 후 1분 안에 자동 복구된다 | 커넥션 풀 복구 실패 여부 확인 |

E4는 judge-api 구간에도 같은 방식으로 반복할 수 있으나 범위에서 제외한다.

## 8. 측정과 기록

실험마다 같은 양식으로 `v3-john/chaos/records/<ID>-<날짜>.md`에 남긴다. 실험 정의는 `v3-john/chaos/experiments/`에 둔다.

- 가설, 주입 내용, 영향 범위, 중단 조건
- 탐지 시간: 주입 시작 주석 → 첫 알림
- 원인 파악 시간: 첫 알림 → 원인 확정(대응자가 기록)
- 복구 시간: 주입 시작 → SLO 지표 정상화
- 사용자 영향: k6 실패율, 지연 p95
- 발견한 약점, 조치, 재실험 결과

중단 조건은 모든 실험에 공통으로 둔다. 실험 시간은 최대 10분이고, Chaos Mesh 실험은 `duration`으로 자동 종료한다. 실행기는 중단 시그널을 받으면 모든 Chaos 리소스를 지운다.

## 9. 대응 절차

- 런북: 장애 유형(파드, 노드, 네트워크 지연, 의존성 차단)별로 탐지 신호, 확인 쿼리, 조치, 복구 확인을 적는다. `v3-john/chaos/runbooks/`에 둔다.
- 포스트모템: 비난 없는 형식. 타임라인, 영향, 근본 원인, 잘된 점, 개선 과제.
- 최종 보고서: `v3-john/chaos/REPORT.md`에 실험별 전후 비교표와 도구 도입 근거(대안 비교 포함)를 정리한다.

## 10. 범위 밖

- v3-wade 게임 데이, Argo Rollouts 카나리 배포
- 앱 코드 수정(Judge OTel gem 제외)
- 운영 서버(오레곤) 대상 실험
