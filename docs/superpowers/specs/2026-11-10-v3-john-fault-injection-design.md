# v3-john 장애 주입과 장애 대응 설계

작성일: 2026-11-10 · 대상: `v3-john` 훈련 클러스터 · 기간: 2~3주

## 1. 목적

운영에서 터질 약점을 장애 주입으로 먼저 찾고, 고친 뒤 같은 실험으로 개선을 수치로 증명한다. 모든 도구 도입은 "실험에서 드러난 문제 → 대안 비교 → 선택 → 같은 실험으로 재측정" 순서를 따른다. 결과물은 이력서와 포트폴리오에 쓸 수 있는 실험 기록, 포스트모템, 전후 비교 수치다.

## 2. 제약

- v3-john은 작업할 때만 `up.sh`로 띄우고 `down.sh`로 내린다. 모든 도구와 실험은 `up.sh` 한 번으로 재현되어야 하고, 실험 결과는 S3와 문서로 남긴다.
- 수정은 인프라와 설정만 한다(Helm 값, 환경 변수, 쿠버네티스 리소스, Istio 정책). 예외는 Judge(Rails)의 OTel gem 추가 하나이며, 사용자가 Judge 저장소 브랜치에서 직접 한다. 앱 코드 수정이 필요한 문제는 개선 제안으로만 기록한다.
- Spot vCPU 한도는 32개다. 현재 노드는 system 1대(2 vCPU), stateful 1대(2), judge 1대(4), application 2대(8)로 16 vCPU다. 1단계 개선 후 최대치는 application 3대, judge 3대로 28 vCPU다.
- 승격 파이프라인(`v3-promote`)이 `v3-john` 값 파일을 자동으로 고치므로, 실험용 변경은 값 파일의 `image`, `sourceRevision` 줄을 건드리지 않는다.

## 3. 현재 구조에서 확인한 사실

- 동기 HTTP 호출: Spring(core, auth, battle) → `ai-llm-service`, `judge-api-service` / AI(ai-llm, ai-make-problem, ai-problem-batch) → `core-service`, `judge-api-service`. core와 AI가 서로 호출한다.
- 비동기: judge-api → `judge-redis-queue` → judge-worker(KEDA 확장), judge-postgres.
- 언어: Java(Spring), Python(FastAPI), Ruby(Rails).
- 모든 앱 Deployment는 HPA 최소 1개다. 차트에 PodDisruptionBudget이 없다. application 노드 그룹은 min=max=2라 여유 노드가 없다.
- 채점 용량은 고정이다. KEDA ScaledObject가 `minReplicaCount: 1`, `maxReplicaCount: 1`이고, judge 노드 그룹은 min=max=1(4 vCPU)이며, worker는 CPU 2개를 요청하고 `COUNT: 2`로 동시에 2건만 채점한다.
- ai-llm은 외부 Gemini API(`generativelanguage.googleapis.com`)를 호출한다(`MOCK_LLM: "false"`).
- prod ApplicationSet은 자동 동기화하지 않는다. 값 파일 변경은 Git 병합 후 운영자가 Sync한다.
- 관측: Prometheus, Alertmanager(Discord), Loki, Alloy, Grafana가 있다. 트레이스와 SLO 알림은 없다. 배포 이벤트가 대시보드에 표시되지 않는다.

## 4. 접근 방식

가설 기반 2단계 비교를 택한다. Istio를 먼저 설치하는 방식은 도입 전 수치가 없어 개선을 증명할 수 없고, AWS FIS만 쓰는 방식은 서비스 구간 장애 표현력이 약해 기각했다.

| 단계 | 내용 | 다음 단계로 가는 조건 |
|---|---|---|
| 0. 기준선 | SLO, k6 사용자 시나리오, RED 대시보드, burn rate 알림, 실험 기록 양식 | 기준선 수치 3회 측정 완료 |
| 1. 현재 구조 실험 | Chaos Mesh, FIS, k6로 E1~E9 실행, 설정으로 고칠 수 있는 약점 수정 | 결과 기록 완료 |
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
| E7 | 대회 시작 제출 폭주(30초 안에 기준선의 10배, 최대 20 rps) | k6 | 채점 처리 p95 30초 이하를 지킨다 | KEDA 최대 1개, judge 노드 최대 1대로 대기열 적체 → KEDA 최대 3, judge 노드 최대 3대 |
| E8 | ai-llm → Gemini API 지연 10초 | NetworkChaos(externalTargets) | AI 기능만 시간 초과로 실패하고 로그인과 제출은 SLO를 지킨다 | 외부 의존성 대기로 core까지 연쇄 장애 → E4와 함께 2b 근거 |
| E9 | 잘못된 설정 배포(core `AI_SERVER_BASE_URL` 포트 오류) | Git PR, Argo CD Sync | 10분 안에 탐지하고 되돌림 PR과 Sync로 10분 안에 복구한다 | 준비 상태 검사는 통과하고 기능만 깨져 탐지가 늦음 → 배포 이벤트를 Grafana 주석으로 표시 |

E4는 judge-api 구간에도 같은 방식으로 반복할 수 있으나 범위에서 제외한다.

E7은 Chaos 리소스 없이 k6 부하 형태만 바꾼다. Spot 용량이 부족해 노드가 늘지 않는 경우도 결과로 기록한다.

E8은 실제 Gemini 호출이 생기므로 k6의 AI 시나리오는 0.2 rps로 제한한다.

E9는 실제 운영과 같은 경로로 진행한다. `v3-john` 값 파일을 바꾸는 PR을 병합하고 Sync한 뒤, 되돌림 PR로 복구한다. 커밋 메시지는 `chaos(E9):`로 시작해 이력에서 실험임을 구분한다. 자동 롤백과 카나리 배포가 없어 생기는 복구 시간은 Argo Rollouts 도입 제안의 근거로 기록한다.

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

- 런북: 장애 유형(파드, 노드, 네트워크 지연, 의존성 차단, 트래픽 급증, 잘못된 배포)별로 탐지 신호, 확인 쿼리, 조치, 복구 확인을 적는다. `v3-john/chaos/runbooks/`에 둔다.
- 포스트모템: 비난 없는 형식. 타임라인, 영향, 근본 원인, 잘된 점, 개선 과제.
- 최종 보고서: `v3-john/chaos/REPORT.md`에 실험별 전후 비교표와 도구 도입 근거(대안 비교 포함)를 정리한다.

## 10. 범위 밖

- v3-wade 게임 데이, Argo Rollouts 카나리 배포
- 앱 코드 수정(Judge OTel gem 제외)
- 운영 서버(오레곤) 대상 실험
