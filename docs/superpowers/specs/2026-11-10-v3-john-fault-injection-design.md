# v3-john 장애 주입과 장애 대응 설계

작성일: 2026-11-10 · 대상: `v3-john` 훈련 클러스터 · 기간: 2~3주

## 1. 목적

운영에서 터질 약점을 장애 주입으로 먼저 찾고, 고친 뒤 같은 실험으로 개선을 수치로 증명한다. 모든 도구 도입은 "실험에서 드러난 문제 → 대안 비교 → 선택 → 같은 실험으로 재측정" 순서를 따른다. 결과물은 이력서와 포트폴리오에 쓸 수 있는 실험 기록, 포스트모템, 전후 비교 수치다.

## 2. 제약

- v3-john은 작업할 때만 `up.sh`로 띄우고 `down.sh`로 내린다. 모든 도구와 실험은 `up.sh` 한 번으로 재현되어야 하고, 실험 결과는 S3와 문서로 남긴다.
- 수정은 인프라와 설정만 한다(Helm 값, 환경 변수, 쿠버네티스 리소스, Istio 정책). 예외는 Judge(Rails)의 OTel gem 추가 하나이며, 사용자가 Judge 저장소 브랜치에서 직접 한다. 앱 코드 수정이 필요한 문제는 개선 제안으로만 기록한다.
- Spot vCPU 한도는 32개다. 현재 노드는 system 1대(2 vCPU), stateful 1대(2), judge 1대(4), application 2대(8)로 16 vCPU다. 1단계 개선 후 최대치는 application 3대, judge 3대로 28 vCPU다.
- v3-john은 실제 Gemini API를 호출하지 않는다. ai-llm은 환경 변수 `GOOGLE_GEMINI_BASE_URL`로 클러스터 안의 가짜 Gemini 서버를 본다. Gemini SDK(`google-genai`)가 이 변수를 기본 접속 주소로 쓰므로 앱 코드는 바꾸지 않는다.
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
| 2b. Istio | E4의 연쇄 장애가 근거가 되면 Istio 도입 후 E4, E5 재실행 | E4 또는 E8에서 핵심 기능 가용성이나 조회 지연 목표 위반 |

조건을 넘지 못하면 해당 도구는 도입하지 않고 "검토 후 미도입" 결과로 기록한다.

## 5. 구성 요소

| 구성 요소 | 역할 | 설치 위치 |
|---|---|---|
| Chaos Mesh | 파드, 네트워크 장애 주입. 실험을 YAML로 저장한다 | `chaos-mesh` 네임스페이스, `up.sh` |
| AWS FIS | Spot 회수 장애 주입 | Terraform `environments/eks`, 실험 템플릿과 IAM 역할 |
| k6 | 실험 중 사용자 흐름 생성. 결과는 Prometheus remote write로 보낸다 | `chaos` 네임스페이스 Job |
| 가짜 Gemini 서버 | WireMock. ai-llm의 Gemini 호출을 받아 고정 응답을 준다. 실제 API 비용을 없앤다 | `chaos` 네임스페이스, Argo CD platform |
| SLO 규칙 | 기록 규칙과 다중 창 burn rate 알림 | PrometheusRule |
| 실험 실행기 | Grafana 주석 기록, k6와 장애 주입 실행, 결과 S3 저장 | `v3-john/chaos/run-experiment.sh` |
| OTel Operator + Tempo | Java, Python은 Operator 자동 계측(init container로 에이전트 주입), Ruby는 gem. Alloy가 OTLP를 받아 Tempo로 보낸다. Tempo는 S3에 저장한다 | 2a 단계 |
| Istio | sidecar 모드. `prod`의 HTTP 서비스만 메시에 넣고 judge-worker, 상태 저장 서비스는 제외한다 | 2b 단계 |

Istio는 ambient 대신 sidecar 모드를 쓴다. 기존 NetworkPolicy가 앱 포트 기준으로 작성되어 있어 sidecar 모드가 정책 변경이 적고, L7 정책(타임아웃, 재시도, 서킷 브레이커)을 waypoint 없이 바로 쓸 수 있다.

## 6. SLO

v3-john은 작업할 때만 켜고 트래픽은 k6가 만든다. 따라서 30일 목표와 에러 예산은 "운영이라면 이렇게 둔다"는 가정이고, 실험의 합격 여부는 실험 구간 안의 수치로 판정한다.

### 6.1 지표와 목표

가용성은 `/api` 전체가 아니라 기능 묶음별로 나눈다. 묶음은 Envoy Gateway 라우트 경로로 구분한다. 하나로 합치면 AI 실패가 섞여 "AI만 실패하고 핵심 기능은 멀쩡하다"는 가설(E4, E8)을 판정할 수 없다.

| SLO | 지표 | 목표 | 판정에 쓰는 실험 |
|---|---|---|---|
| 핵심 기능 가용성 | 로그인, 문제 조회, 제출 경로 요청 중 5xx가 아닌 비율 | 99.5% | E1, E3, E4, E5, E6, E8, E9 |
| AI 기능 가용성 | AI 기능 경로 요청 중 5xx가 아닌 비율 | 95% | E4, E8, E9 |
| 조회 지연 | 로그인, 문제 조회 p95 | 기준선 p95의 2배 이하 | E4, E5 |
| 제출 지연 | `POST /api/submissions` p95 | 1초 이하 | E5, E7 |
| 채점 처리 | 제출부터 결과 조회 성공까지 p95 (k6 측정) | 30초 이하 | E2, E5, E7 |
| 채점 완료율 | k6가 보낸 제출 중 결과를 받은 비율 | 100% | E2, E7 |

- AI 기능은 외부 LLM에 의존하므로 목표를 낮게 둔다. 대신 AI 실패가 핵심 기능으로 번지면 안 된다.
- 지연 목표는 기준선 3회를 잰 뒤 확정한다. 조회 지연은 기준선 p95의 2배로 정하고, 제출 지연 1초와 채점 처리 30초는 기준선 p95가 이를 넘으면 기준선 p95의 1.5배로 바꾸고 이유를 기록에 남긴다.
- 채점 완료율은 제출 후 5분 안에 결과를 받지 못하면 유실로 센다.

### 6.2 알림

알림은 탐지 시간을 재는 용도다. 핵심 기능 가용성은 에러 비율 자체가 아니라 **에러 예산을 쓰는 속도**로 건다.

- 에러 예산: 목표가 99.5%이므로 요청의 0.5%까지는 실패해도 된다.
- 소진 속도(burn rate): 지금 에러 비율이 0.5%의 몇 배인지다. 1배면 30일에 예산을 딱 다 쓰고, 14.4배면 약 2일 만에 다 쓴다.

| 알림 | 조건 | 같은 뜻의 에러 비율 | 용도 |
|---|---|---|---|
| `CoreErrorBudgetBurnFast` | 최근 5분과 최근 1시간 모두 14.4배 초과 | 5분 동안 7.2% 넘게 실패 | 실험 탐지 시간 측정 |
| `CoreErrorBudgetBurnPage` | 최근 1시간 14.4배 초과 | 1시간 동안 7.2% 넘게 실패 | 운영 구성. 실험 중에는 큰 장애에서만 울린다 |
| `CoreErrorBudgetBurnTicket` | 최근 6시간 6배 초과 | 6시간 동안 3% 넘게 실패 | 운영 구성. 실험 중에는 울리지 않는다 |
| `AiErrorRateHigh` | 최근 5분 AI 기능 에러 비율 5% 초과 | 같음 | 실험 탐지 시간 측정 |
| `SubmissionLatencyHigh` | 최근 5분 제출 p95가 목표 초과 | - | 실험 탐지 시간 측정 |
| `JudgeTurnaroundHigh` | 최근 5분 채점 처리 p95가 목표 초과 | - | 실험 탐지 시간 측정 |

에러 비율 하나로 알림을 걸면 잠깐 튄 오류에도 울리고, 조금씩 오래 새는 오류는 놓친다. 소진 속도와 시간 창을 함께 쓰면 큰 장애는 짧은 창으로, 천천히 새는 장애는 긴 창으로 구분해 잡는다. 1시간과 6시간 알림은 실험에는 거의 쓰이지 않지만 운영에 그대로 옮길 구성으로 남긴다.

### 6.3 실험 판정

- 판정 구간은 주입 시작부터 회복 구간 끝까지다. 이 구간의 SLO 지표를 6.1 목표와 비교해 가설 성립 여부를 적는다.
- 트래픽이 적으면 실패 몇 건에 비율이 크게 흔들린다. 판정 구간의 핵심 기능 요청이 1,000건 미만이면 "판정 불가"로 기록하고 부하를 늘려 다시 한다.
- 복구 시간은 주입 시작부터 해당 SLO 지표가 목표 안으로 돌아와 1분 동안 유지된 시점까지다.

## 7. 실험 목록

| ID | 장애 | 도구 | 가설 | 예상 약점과 1단계 대응 |
|---|---|---|---|---|
| E1 | core 파드 강제 종료 | PodChaos | 30초 안에 복구되고 핵심 기능 가용성 목표를 지킨다 | 최소 1개라 재시작 동안 전면 중단 → 최소 2개, PDB |
| E2 | 부하 중 judge-worker 전부 종료 | PodChaos | 채점 완료율 100%를 지킨다 | 처리 중 작업 유실 여부 확인 → 유실 시 개선 제안 |
| E3 | application Spot 노드 회수 | FIS | 2분 안에 다른 노드로 옮기고 에러율 1% 미만 | 여유 노드 없음, PDB 없음 → max_size 3, PDB, topology spread |
| E4 | core → ai-llm 구간 지연 3초 | NetworkChaos | AI 기능만 느려지고 핵심 기능 가용성과 조회 지연은 목표를 지킨다 | 스레드, 커넥션 고갈로 연쇄 장애 → 2b Istio 근거 |
| E5 | judge-postgres 구간 지연 500ms | NetworkChaos | 지표와 로그만으로 10분 안에 원인을 찾는다 | 원인 파악 지연 → 2a 트레이스 근거 |
| E6 | core → RDS 연결 차단 60초 | NetworkChaos | 차단 해제 후 1분 안에 자동 복구된다 | 커넥션 풀 복구 실패 여부 확인 |
| E7 | 대회 시작 제출 폭주(30초 안에 기준선의 10배, 최대 20 rps) | k6 | 채점 처리 p95와 채점 완료율 목표를 지킨다 | KEDA 최대 1개, judge 노드 최대 1대로 대기열 적체 → KEDA 최대 3, judge 노드 최대 3대 |
| E8 | ai-llm → 가짜 Gemini 서버 구간 지연 10초 | NetworkChaos | AI 기능만 시간 초과로 실패하고 핵심 기능 가용성은 목표를 지킨다 | 외부 의존성 대기로 core까지 연쇄 장애 → E4와 함께 2b 근거 |
| E9 | 잘못된 설정 배포(core `AI_SERVER_BASE_URL` 포트 오류) | Git PR, Argo CD Sync | 10분 안에 탐지하고 되돌림 PR과 Sync로 10분 안에 복구한다 | 준비 상태 검사는 통과하고 기능만 깨져 탐지가 늦음 → 배포 이벤트를 Grafana 주석으로 표시 |

E4는 judge-api 구간에도 같은 방식으로 반복할 수 있으나 범위에서 제외한다.

E7은 Chaos 리소스 없이 k6 부하 형태만 바꾼다. Spot 용량이 부족해 노드가 늘지 않는 경우도 결과로 기록한다.

E8은 비용을 막기 위해 실제 Gemini 대신 가짜 Gemini 서버(WireMock)에 지연을 넣는다. 가짜 서버는 `generateContent`와 임베딩 요청에 고정된 정상 응답을 돌려주므로 기준선에서도 AI 기능이 성공한다. 실제 외부 호출과 다른 점(HTTPS가 아닌 HTTP, 응답 내용 고정)은 결과 해석에 함께 적는다. 실행기는 시작 전에 ai-llm 파드의 `GOOGLE_GEMINI_BASE_URL`이 가짜 서버를 가리키는지 확인하고, 아니면 실험을 시작하지 않는다.

E9는 실제 운영과 같은 경로로 진행한다. `v3-john` 값 파일을 바꾸는 PR을 병합하고 Sync한 뒤, 되돌림 PR로 복구한다. 커밋 메시지는 `chaos(E9):`로 시작해 이력에서 실험임을 구분한다. 자동 롤백과 카나리 배포가 없어 생기는 복구 시간은 Argo Rollouts 도입 제안의 근거로 기록한다.

## 8. 측정과 기록

실험마다 같은 양식으로 `v3-john/chaos/records/<ID>-<날짜>.md`에 남긴다. 실험 정의는 `v3-john/chaos/experiments/`에 둔다.

- 가설, 주입 내용, 영향 범위, 중단 조건
- 탐지 시간: 주입 시작 주석 → 첫 알림
- 원인 파악 시간: 첫 알림 → 원인 확정(대응자가 기록)
- 복구 시간: 6.3 정의를 따른다
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
