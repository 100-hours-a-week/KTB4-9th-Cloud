# v3-john 장애 주입과 장애 대응 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설계서의 S1(잘못된 배포), S2(스팟 노드 회수), S3(RDS 장애)를 v3-john에서 재현 가능하게 실행하고, 개선 단계마다 같은 실험으로 다시 재서 비교표, 포스트모템, 런북, 최종 보고서를 남긴다.

**Architecture:** 부하(k6)는 클러스터 안 Job으로 돌려 결과를 Prometheus에 원격 쓰기한다. 실험 실행기(`v3-john/chaos/run-experiment.sh`)가 정상 상태 확인 → 부하 → 시나리오별 `inject.sh` → 중단 조건 감시 → `stop.sh` → 집계와 기록을 한 번에 한다. 개선은 Helm 값, 차트 템플릿, Terraform, 애드온으로만 하고 각 단계는 PR 하나로 들어간다.

**Tech Stack:** EKS 1.37, Argo CD, Helm, Terraform(AWS provider 5.100), kube-prometheus-stack 92.18.0, Envoy Gateway 1.9.3, k6, WireMock, OpenTelemetry Collector, Grafana Tempo, Argo Rollouts, Chaos Mesh, AWS FIS.

**Spec:** `docs/superpowers/specs/2026-11-10-v3-john-fault-injection-design.md` (2026-11-19 수정본, 커밋 `223675f`)

## 이미 끝난 것 (이 계획에서 하지 않는다)

main 기준 2026-11-19까지 들어간 것:

- Argo CD Image Updater 경로, Argo CD Discord 배포 알림, 대시보드 배포 주석(#30)
- 기능 묶음 HTTPRoute 6개와 SLO 기록 규칙, 증상·원인 알림(#30)
- RabbitMQ(#31), 네임스페이스 쿼터 축소, application 노드 최대 3대(#30)
- 시드 스키마 패치, `v3-john/loadtest/`, 기준선 2회 결과(#33)

## Global Constraints

- 수정은 인프라, 설정, 운영 도구만 한다. 앱 코드 수정이 필요한 문제는 보고서에 개선 제안으로만 적는다.
- Spot vCPU 한도는 32개이고 한도 증가는 요청하지 않는다. 실험 중 vCPU 합계가 24를 넘으면 중단한다.
- v3-john은 실제 Gemini API를 호출하지 않는다. AI 경로는 가짜 Gemini 서버를 통과할 때만 부하에 넣는다.
- 실험용 변경은 값 파일의 `image` 줄을 건드리지 않는다(Image Updater가 고친다).
- 모든 도구와 실험은 `up.sh` 한 번으로 재현돼야 한다. 실험 결과는 `v3-john/chaos/records/`와 S3 `s3://cosmos-db-backup-352635536602/chaos/`에 남긴다.
- 시크릿 값은 화면, 로그, 커밋에 남기지 않는다. 파드 안이나 Secrets Manager에서만 읽는다.
- 한 번에 시나리오 하나만 실행한다. 장애 주입은 10분을 넘기지 않는다.
- 이미지와 차트는 버전과 digest를 고정한다(GitOps CI 이미지 고정 검사).
- 문서는 서술체(~다)로 쓰고, 한글 뒤에 괄호로 영단어를 붙이지 않는다.
- **실험 순서:** S1 단계 3과 S2 단계 1은 같은 변경이다. S2 개선 전 실험은 S1 단계 3을 적용하기 전에 한다. 순서는 Task 9 → 10(S1 개선 전) → 11(S2 개선 전) → 12 이후다.

## Review Focus

1. **실험 도중 토큰 만료**: 테스트 토큰은 3시간 유효하다. 남은 시간이 실험 길이보다 짧으면 401이 쏟아져 흐름이 끊긴다. 실행기는 시작 전에 토큰 만료를 확인하고, 모자라면 시작하지 않는다(Task 5).
2. **트래픽 없는 정상 상태 확인**: 요청이 0이면 오류율이 NaN이 되어 "정상"으로 통과할 수 있다. 정상 상태 확인은 요청 수가 있어야만 통과한다(Task 5).
3. **실행기가 중간에 끊김**: Ctrl+C나 노트북 잠자기로 끊겨도 주입이 남으면 안 된다. 실행기는 종료할 때 항상 `stop.sh`를 부르고, 다음 실행 전에 남은 Chaos 리소스와 FIS 실험을 확인한다(Task 5).
4. **실험 중 끼어드는 배포**: 실험 도중 Image Updater나 다른 PR이 배포되면 결과가 섞인다. 실행기는 시작과 끝의 Argo CD 리비전을 기록하고, 다르면 기록에 "판정 불가"를 단다(Task 5).
5. **가짜 Gemini 응답 형식 불일치**: 가짜 응답이 ai-llm의 구조화 응답 형식과 다르면 정상 상태에서도 AI 5xx가 난다. AI 기준선 오류율이 0이 아니면 AI 경로를 부하에 넣지 않는다(Task 4).

---

## 파일 구조

| 경로 | 책임 |
|---|---|
| `v3-john/scripts/check-rules.sh` | kube-prometheus-stack 값을 렌더링해 cosmos 규칙을 뽑고 promtool로 검사, 단위 테스트를 돌린다 |
| `v3-john/helm/addons-values/monitoring/tests/*.yaml` | 알림 규칙 단위 테스트(promtool test rules) |
| `v3-john/loadtest/k8s/` | k6 Job, 네임스페이스, 실행 스크립트 `run-k6.sh` |
| `v3-john/gitops/environments/prod/platform/fake-gemini.yaml` | 가짜 Gemini(WireMock) Deployment, Service, 응답 ConfigMap |
| `v3-john/chaos/run-experiment.sh` | 실험 실행기 |
| `v3-john/chaos/lib/*.sh` | 실행기 공통 함수(Prometheus 질의, 주석, 중단 조건) |
| `v3-john/chaos/scenarios/<id>/{inject.sh,stop.sh,README.md}` | 시나리오별 주입과 원복 |
| `v3-john/chaos/incident/` | 심각도, 역할 체크리스트, 포스트모템 양식 |
| `v3-john/chaos/records/` | 실험 기록(`<시나리오>-<단계>-<날짜>.md`, `.json`) |
| `v3-john/chaos/runbooks/` | 런북 4종 |
| `v3-john/chaos/REPORT.md` | 최종 보고서 |
| `v3-john/gitops/charts/cosmos-app/templates/{pdb.yaml,rollout.yaml}` | 차트 확장(PDB, Rollout) |
| `v3-john/environments/eks/{observability.tf,fis.tf}` | Tempo 버킷·권한, FIS 역할·알람 |

---

## 0단계: 공통 구성 요소

### Task 1: 알림 규칙 테스트 도구

**Files:**
- Create: `v3-john/scripts/check-rules.sh`
- Create: `v3-john/helm/addons-values/monitoring/tests/symptoms.yaml`, `causes.yaml`

**Interfaces:**
- Produces: `check-rules.sh` (인자 없음, 실패 시 0이 아닌 종료). 뒤 작업이 규칙을 바꿀 때마다 이 스크립트로 검증한다.

- [ ] **Step 1: 테스트 작성** — `symptoms.yaml`에 promtool 단위 테스트를 쓴다. 입력은 `envoy_cluster_upstream_rq_total`, `envoy_cluster_upstream_rq_xx`, `envoy_cluster_upstream_cx_none_healthy` 시계열이다.
  - `CoreUnavailable`: `journey-core-problem`에서 5분 동안 요청의 60%가 5xx면 2분 시점에 firing, 40%면 firing 없음
  - `CoreErrorBudgetBurnFast`: 1시간 동안 10% 5xx면 firing, 5%면 없음
  - `ReadLatencyHigh`: 조회 p95가 80ms로 6분 지속하면 firing, 30ms면 없음(Task 2의 50ms 기준)
  - 정상 엔드포인트 없음: `upstream_cx_none_healthy`만 늘어도 `CoreUnavailable` firing
  - `causes.yaml`: `PodCrashLooping`이 OOMKilled 재시작 1회에 firing, 일반 재시작 2회에는 없음
- [ ] **Step 2: 실패 확인** — `bash v3-john/scripts/check-rules.sh`. 기대: `ReadLatencyHigh` 80ms 케이스 실패(현재 1000ms)
- [ ] **Step 3: `check-rules.sh` 구현** — `helm template`로 kube-prometheus-stack을 렌더링하고, 이름이 `cosmos-`로 시작하는 PrometheusRule의 `groups`를 파일로 뽑아 `docker run prom/prometheus:v3.5.0`로 `promtool check rules`와 `promtool test rules`를 실행한다.
- [ ] **Step 4: 커밋** — `ReadLatencyHigh` 80ms 케이스만 실패하는 상태로 커밋하지 않는다. Task 2와 같은 PR로 묶는다.

### Task 2: 알림 보완과 Envoy 이중화

**Files:**
- Modify: `v3-john/helm/addons-values/monitoring/kube-prometheus-stack.yaml`
- Modify: `v3-john/gitops/environments/prod/platform/gateway.yaml` (EnvoyProxy `replicas: 2`)

**Interfaces:**
- Consumes: Task 1 `check-rules.sh`
- Produces: Prometheus 원격 쓰기 수신(`/api/v1/write`), 알림 `JudgeTurnaroundHigh`, `JudgeJobLost`

- [ ] **Step 1: 테스트 추가** — `symptoms.yaml`에 `JudgeTurnaroundHigh`(`k6_submit_latency_p95` 31초가 6분 지속하면 firing), `JudgeJobLost`(`k6_judge_lost_total` 증가 시 firing, `k6_submit_rejected_total` 증가만으로는 없음)를 추가한다.
- [ ] **Step 2: 값 변경**
  - `ReadLatencyHigh` 임계값 1000 → 50(ms). 근거: 2026-11-19 기준선 Envoy p95 24~25ms의 2배
  - `prometheus.prometheusSpec.enableRemoteWriteReceiver: true`
  - `JudgeTurnaroundHigh`: `max(k6_submit_latency_p95) > 30000`, `for: 5m`, `severity: critical`, `sev: SEV2`
  - `JudgeJobLost`: `increase(k6_judge_lost_total[5m]) > 0`, `severity: critical`, `sev: SEV1`
  - Alertmanager: `Watchdog`를 `null` 경로에서 빼고 Discord로 보낸다. `repeat_interval: 1h`
- [ ] **Step 3: 검증** — `bash v3-john/scripts/check-rules.sh` 전부 통과. `helm template ... -f gateway` 렌더링에서 EnvoyProxy replicas 2
- [ ] **Step 4: 커밋, PR** — `feat(v3-john): 채점 알림, Watchdog 전달, 조회 지연 기준 확정, Envoy 2개`

### Task 3: k6를 클러스터 안에서 실행

**Files:**
- Create: `v3-john/loadtest/k8s/job.yaml`, `v3-john/loadtest/k8s/run-k6.sh`
- Modify: `v3-john/loadtest/baseline.js`, `v3-john/loadtest/prepare.sh`, `v3-john/loadtest/README.md`

**Interfaces:**
- Consumes: Task 2 원격 쓰기 수신
- Produces:
  - `run-k6.sh <testid> <duration> [vus]`: `loadtest` 네임스페이스에 Job `k6-<testid>`를 만들고 끝날 때까지 기다린 뒤 요약 JSON을 `$OUT/<testid>.json`에 둔다. 0이 아닌 종료는 k6 실패를 뜻한다.
  - Prometheus 지표(`testid` 라벨): `k6_read_latency_p95`, `k6_submit_latency_p95`, `k6_judge_lost_total`, `k6_submit_rejected_total`, `k6_http_reqs_total`

- [ ] **Step 1: `baseline.js` 변경**
  - `BASE` 기본값을 Envoy 내부 주소 `http://envoy-prod-prod.envoy-gateway-system.svc/api`로 둔다(Service 이름은 Step 4에서 실제 값으로 확인)
  - 제출 결과를 셋으로 나눈다: `judge_lost`(5xx, 시간 초과, 2xx인데 `COMPLETED`가 아님), `submit_rejected`(4xx, `status` 태그), 성공
  - 4xx 응답 본문을 처음 5건만 `console.warn`으로 남긴다(2026-11-19 2회차 4xx 18건 원인 확인용)
- [ ] **Step 2: `job.yaml`** — 이미지 `grafana/k6`를 digest로 고정한다. 스크립트는 ConfigMap, 토큰과 문제 ID는 Secret으로 넣는다. 환경 변수: `K6_PROMETHEUS_RW_SERVER_URL=http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write`, `K6_PROMETHEUS_RW_TREND_STATS=p(95),p(99),max`. 실행 인자: `-o experimental-prometheus-rw --tag testid=<testid>`. 노드는 `workload-class: application`, 요청 CPU 250m·메모리 256Mi
- [ ] **Step 3: `prepare.sh`** — 토큰과 문제 ID를 `loadtest` 네임스페이스 Secret `k6-inputs`로도 만든다. 토큰 만료 시각(Unix 초)을 Secret 키 `expires_at`에 둔다.
- [ ] **Step 4: 검증** — `run-k6.sh smoke 1m 2`
  - 기대: 종료 0, `k6_http_reqs_total{testid="smoke"}`가 Prometheus에 있음
  - Envoy `journey-*` 요청 수가 k6 요청 수와 ±5% 안
- [ ] **Step 5: 커밋, PR**

### Task 4: 가짜 Gemini 서버와 AI 경로

**Files:**
- Create: `v3-john/gitops/environments/prod/platform/fake-gemini.yaml`
- Modify: `v3-john/gitops/environments/prod/ai-llm.yaml`(환경 변수), `v3-john/gitops/environments/prod/platform/network-policies.yaml`, `v3-john/loadtest/baseline.js`

**Interfaces:**
- Produces: Service `fake-gemini.prod.svc:8080`, k6 AI 흐름(힌트 5%), `-e AI=1`일 때만 켜짐

- [ ] **Step 1: 응답 형식 조사** — AI 저장소 main에서 힌트와 풀이 평가가 쓰는 구조화 응답 스키마(`call_llm_structured`의 `schema`)를 찾아 필드 목록을 `fake-gemini.yaml` 주석에 적는다.
- [ ] **Step 2: WireMock 구성** — `wiremock/wiremock` 3.x를 digest로 고정한다.
  - 경로 `POST /v1beta/models/.*:generateContent`
  - 요청 본문에 스키마 필드명이 있는지로 응답 두 종류를 고른다
  - 지연은 `uniform 800~1500ms`
- [ ] **Step 3: ai-llm 설정**
  - `GOOGLE_GEMINI_BASE_URL: http://fake-gemini.prod.svc:8080`
  - NetworkPolicy: ai-llm 송신에서 `0.0.0.0/0:443`을 빼고 `fake-gemini:8080`을 연다. 실제 API 호출을 네트워크에서 막는다
- [ ] **Step 4: 검증**
  - 테스트 토큰으로 힌트 요청 → 200
  - WireMock 요청 기록이 1 늘어남
  - ai-llm 파드에서 `generativelanguage.googleapis.com:443` 연결 시도 → 시간 초과
  - SDK가 `GOOGLE_GEMINI_BASE_URL`을 따르지 않으면 이 단계에서 멈추고 보고서에 "AI 경로 제외"로 적는다(앱 코드는 바꾸지 않는다)
- [ ] **Step 5: k6** — `AI=1`이면 반복의 5%에서 힌트를 요청한다. AI 기준선 5xx가 0일 때만 `AI=1`을 쓴다(Review Focus 5).
- [ ] **Step 6: 커밋, PR**

### Task 5: 실험 실행기

**Files:**
- Create: `v3-john/chaos/run-experiment.sh`, `v3-john/chaos/lib/prom.sh`, `v3-john/chaos/lib/guard.sh`, `v3-john/chaos/lib/annotate.sh`
- Create: `v3-john/chaos/scenarios/noop/{inject.sh,stop.sh}`, `v3-john/chaos/scenarios/pod-kill/{inject.sh,stop.sh}`

**Interfaces:**
- Consumes: Task 3 `run-k6.sh`, `k6-inputs` Secret
- Produces:
  - `run-experiment.sh <scenario> <step> [--inject-after 3m] [--recover 10m] [--vus 10]`
  - 시나리오 계약: `scenarios/<id>/inject.sh`는 주입하고 즉시 반환, `stop.sh`는 여러 번 불려도 안전해야 함. 둘 다 `$RECORD_DIR` 환경 변수를 받는다
  - 결과: `v3-john/chaos/records/<scenario>-<step>-<YYYYMMDD-HHMM>.json`(8.3 지표의 기계 측정분)과 S3 업로드
  - `prom_query <promql> [time]`(값 하나 출력), `guard_check`(중단 조건 위반 시 이유 출력, 1 반환), `annotate <text> <tags>`(Grafana 주석 id 출력)

- [ ] **Step 1: 테스트 시나리오 `noop`** — 아무것도 하지 않는 주입이다. 기대 결과:
  - 기록 JSON 생성
  - Grafana 주석 2개(주입 시작, 종료)
  - 핵심 오류율 0
- [ ] **Step 2: 실행 흐름 구현** (순서 고정)
  1. 사전 검사: 토큰 만료가 실행 길이 + 10분 이후인지 확인. 남은 Chaos Mesh 리소스와 실행 중 FIS 실험이 있으면 중단
  2. Argo CD 앱 리비전 기록
  3. k6 시작(`--inject-after` + 주입 + `--recover`만큼)
  4. 2분 정상 상태 확인: 핵심 요청 수 > 0이고 `cosmos:journey_error_ratio:rate5m{journey="core"} < 0.005`, 조회 p95 ≤ 50ms. 실패하면 주입하지 않고 종료
  5. 주석 남기고 `inject.sh`
  6. 15초마다 `guard_check`: Prometheus 응답 없음, vCPU 합계 > 24, 주입 경과 > 10분이면 `stop.sh`
  7. `--recover` 동안 관찰, `stop.sh`, 주석
  8. 집계: 탐지 시간(주입 → 첫 증상 알림 firing, Alertmanager API), 복구 시간(6.4 정의), 기능 묶음별 실패율·p95, 예산 소진량(6.2 공식), 판정 구간 핵심 요청 수(1,000 미만이면 "판정 불가")
  9. 리비전 비교(다르면 "판정 불가")
  10. 기록 저장, S3 업로드
  - `trap`으로 EXIT, INT, TERM에서 `stop.sh`를 부른다(Review Focus 3).
- [ ] **Step 3: 중단 조건 테스트** — `GUARD_FAKE_VCPU=30` 환경 변수로 vCPU 위반을 흉내 낸다. 기대: `stop.sh` 호출, 기록에 `aborted: vcpu`
- [ ] **Step 4: `pod-kill` 시나리오** — core 파드 하나를 지운다(설계서 2일차 "시험용 파드 종료"). 실행해서 7장 대응 순서가 끝까지 이어지는지 확인한다.
- [ ] **Step 5: 커밋, PR**

### Task 6: 장애 대응 문서

**Files:**
- Create: `v3-john/chaos/incident/severity.md`, `roles.md`, `postmortem-template.md`
- Create: `v3-john/chaos/records/TEMPLATE.md`

- [ ] **Step 1** — `severity.md`: 설계서 7.1~7.3을 그대로 옮기고, 알림 이름과 등급의 대응표를 붙인다(6.3).
- [ ] **Step 2** — `roles.md`: 지휘, 기록, 전파 체크리스트(7.4). 각 항목에 시각을 적는 칸을 둔다.
- [ ] **Step 3** — `postmortem-template.md`: 7.6 항목 순서 그대로. 연쇄 경로 칸에 "트레이스 링크" 칸을 둔다.
- [ ] **Step 4** — `records/TEMPLATE.md`: 8.3 지표 표. 실행기가 채운 값과 사람이 채울 값(선언 시간, 원인 파악 시간과 근거)을 구분한다.
- [ ] **Step 5: 커밋, PR**

### Task 7: 사전 확인

**Files:**
- Create: `v3-john/chaos/prechecks.md`

- [ ] 다섯 항목을 확인하고 근거(파일과 줄, 명령 출력)를 적는다.
  - core가 Judge 콜백을 쓰는지, AI 호출이 비동기인지: BE main 코드
  - `/actuator/health`에 DB가 포함되는지: 파드 안에서 `curl localhost:9091/actuator/health`
  - EKS 관리형 노드 그룹이 스팟 회수 알림에 노드를 비우는지: AWS 문서와 노드 그룹 설정
  - 승격 이미지에 OpenTelemetry 계측이 들어 있는지: 이미지 안 `/opt/opentelemetry-javaagent.jar` 존재 여부
  - 2026-11-19 2회차 제출 4xx 18건의 원인: Task 3 k6 경고 로그
- [ ] **커밋**

### Task 8: 기준선 3회

- [ ] `up.sh` → `prepare.sh` → `run-k6.sh baseline-1 10m 10`을 3회 실행한다(사이에 2분 휴식).
- [ ] `loadtest/results/<날짜>-baseline.md`를 만든다. 2026-11-19 결과와 같은 표 형식으로 쓰고, 셋째 표에 AI 기준선(Task 4가 통과한 경우)을 더한다.
- [ ] 판정 기준:
  - 3회 모두 핵심 요청 1,000건 이상
  - 핵심 5xx 0
  - 조회 p95가 3회 평균 ±30% 안
  - 벗어나면 원인을 적고 다시 잰다
- [ ] 조회 p95가 2026-11-19 값(25ms)과 다르면 `ReadLatencyHigh`를 새 기준선의 2배로 고치는 PR을 낸다.

---

## 1단계: S1 잘못된 배포

### Task 9: S1 주입값 찾기

**Files:**
- Create: `v3-john/chaos/scenarios/s1/{inject.sh,stop.sh,README.md}`

**Interfaces:**
- Produces:
  - `inject.sh`: `chaos/s1-<날짜>` 브랜치에 core 메모리 제한 변경 커밋(`chaos(S1): ...`)을 만들어 푸시하고, PR을 열고, 병합한다. 그다음 Argo CD `prod-core`가 새 리비전으로 동기화될 때까지 기다린다.
  - `stop.sh`: 같은 방식으로 되돌리는 PR을 만들어 병합한다.
  - 변경할 값은 `S1_MEMORY_LIMIT` 환경 변수로 받는다.

- [ ] **Step 1** — 후보 1.5Gi, 1.25Gi, 1Gi를 차례로 시험한다. 조건: 기동과 준비 상태 검사는 통과하고, k6 10 VU 10분 안에 OOMKilled가 난다.
- [ ] **Step 2** — 3회 중 3회 OOMKilled가 재현되는 가장 큰 값을 고르고 `README.md`에 적는다(위험표 "매번 다르게 동작").
- [ ] **Step 3: 커밋**

### Task 10: S1 개선 전 실험

- [ ] **Step 1** — 단계 1(배포 주석, `PodCrashLooping`)은 이미 적용돼 있다. 개선 전 조건을 맞추기 위해 실행 동안 Alertmanager silence로 `PodCrashLooping`을 끄고, 대시보드 배포 주석을 끈 상태로 실험한다. 이 조치를 기록에 적는다.
- [ ] **Step 2** — 실험 전에 연쇄 관찰표의 예측 결과를 기록 파일에 먼저 적는다(위험표 "원인을 미리 안다").
- [ ] **Step 3** — `run-experiment.sh s1 before`를 실행하고, 7장 순서대로 대응한다.
- [ ] **Step 4** — 포스트모템을 쓴다(`postmortem-template.md`).
- [ ] **Step 5** — `run-experiment.sh s1 step1`(silence 없이)을 실행해 단계 1의 효과를 잰다.
- [ ] **Step 6** — 연쇄 관찰표 4번(Judge 콜백 유실)이 확인되면 `judge-api`, `judge-worker` 값에 `CALLBACKS_MAX_TRIES: "10"`, `CALLBACKS_TIMEOUT: "10"`을 넣는 PR을 단계 3과 함께 낸다. 콜백 실패 시 조회로 보완하는 개선은 보고서의 앱 코드 제안에 적는다(설계서 9.1). 확인되지 않으면 기록에 "해당 없음"으로 남긴다.

### Task 11: S2 개선 전 실험 (S1 단계 3보다 먼저)

**Files:**
- Create: `v3-john/environments/eks/fis.tf`, `v3-john/chaos/scenarios/s2/{inject.sh,stop.sh,README.md}`

**Interfaces:**
- Produces:
  - Terraform 출력 `fis_role_arn`, `fis_stop_alarm_arn`
  - `inject.sh`: core 파드가 있는 노드의 인스턴스 ID로 FIS 실험 템플릿을 만들고 시작한다. 액션 `aws:ec2:send-spot-instance-interruptions`, `durationBeforeInterruption: PT2M`
  - `stop.sh`: `aws fis stop-experiment`, 임시 템플릿 삭제

- [ ] **Step 1: `fis.tf`**
  - FIS 역할(`ec2:SendSpotInstanceInterruptions`, 대상은 이 클러스터 노드 태그로 제한)
  - CloudWatch 알람: application 노드 그룹 ASG의 `GroupInServiceInstances < 1`이 1분 지속. 중단 조건으로 쓴다
- [ ] **Step 2** — `terraform plan`에 새 자원만 있는지 확인하고 적용한다.
- [ ] **Step 3** — `run-experiment.sh s2 before`, 대응, 포스트모템.

### Task 12: S1 단계 2 분산 트레이싱

**Files:**
- Create: `v3-john/environments/eks/observability.tf`(v3-wade 같은 파일을 옮김), `v3-john/helm/addons-values/monitoring/{tempo.yaml,otel-collector.yaml}`, `v3-john/helm/addons-values/monitoring/network-policies.yaml`
- Modify: `v3-john/scripts/up.sh`, `v3-john/helm/addons-values/monitoring/kube-prometheus-stack.yaml`(Tempo 데이터 소스, 트레이스 ↔ 로그 연결), `v3-john/gitops/charts/cosmos-app/templates/_pod.tpl`, `values.yaml`, `v3-john/gitops/environments/prod/{auth,core,battle,ai-llm,judge-api,judge-worker}.yaml`

**Interfaces:**
- Consumes: Task 2 원격 쓰기 수신(metrics-generator)
- Produces:
  - 차트 값 `otel: { enabled: false, agent: false, serviceName: "" }`
  - `enabled`면 `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc.cluster.local:4317`, `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`, `OTEL_TRACES_EXPORTER=otlp`, `OTEL_METRICS_EXPORTER=none`, `OTEL_LOGS_EXPORTER=none`, `OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=john,service.namespace=cosmos,k8s.cluster.name=cosmos-v3-john,service.version=<이미지 SHA>`를 넣는다
  - `agent`가 참이면 init 컨테이너가 `autoinstrumentation-java` 이미지(digest 고정)의 `/javaagent.jar`를 emptyDir로 복사하고, `JAVA_TOOL_OPTIONS`에 `-javaagent:/otel/javaagent.jar`를 더한다
  - 차트 값 `jvmOptions: ""`는 `JAVA_TOOL_OPTIONS`에 이어 붙인다. Task 13이 쓴다

- [ ] **Step 1: 렌더링 테스트**
  - `helm template ... -f core.yaml --set otel.enabled=true,otel.agent=true`에 init 컨테이너와 `JAVA_TOOL_OPTIONS`가 있음
  - `otel.enabled=false`면 `OTEL_` 변수가 하나도 없음
- [ ] **Step 2** — 차트 구현과 값 파일 적용. `agent`는 Task 7 결과에 따라 정한다. 이미지에 에이전트가 있으면 `false`다.
- [ ] **Step 3: Tempo, Collector 이식**
  - v3-wade 값 파일에서 `wade`를 `john`으로 바꾼다. 보존 14일, 표본 100%
  - `up.sh`에 설치 순서를 넣는다: kube-prometheus-stack 다음, Argo CD 앞
- [ ] **Step 4: 오버헤드 측정** — Task 8과 같은 조건으로 `run-k6.sh otel-1 10m 10`을 2회 실행한다.
  - 기준: 조회 p95가 기준선의 120% 이하, core 기동 180초 이내
  - 넘으면 원인을 고치기 전까지 다음 단계로 가지 않는다
- [ ] **Step 5: 동작 확인**
  - Grafana Explore → Tempo에서 `service.name=cosmos-core` 트레이스 조회
  - `traces_service_graph_request_total{client="cosmos-ai-llm",server="cosmos-core"}`가 존재
- [ ] **Step 6** — `run-experiment.sh s1 step2`. 원인 파악 근거에 트레이스를 썼는지 기록하고, 서비스 호출 지도를 캡처한다.
- [ ] **Step 7: 커밋, PR**(인프라와 값 파일은 실험 전에 병합)

### Task 13: S1 단계 3 이중화와 JVM 힙

**Files:**
- Create: `v3-john/gitops/charts/cosmos-app/templates/pdb.yaml`
- Modify: `_pod.tpl`(`topologySpreadConstraints`), `values.yaml`, `auth.yaml`, `core.yaml`, `battle.yaml`

**Interfaces:**
- Produces:
  - 차트 값 `pdb: { minAvailable: null }`
  - `spread: false`: 참이면 `topologyKey: kubernetes.io/hostname`, `maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`
  - S2 단계 1이 같은 값을 쓴다

- [ ] **Step 1: 렌더링 테스트**
  - core에 PDB `minAvailable: 1`
  - 분산 제약
  - HPA `minReplicas: 2`
  - `JAVA_TOOL_OPTIONS`에 `-XX:MaxRAMPercentage=75`
- [ ] **Step 2** — 값 적용: auth, core, battle `hpa.min: 2`, `pdb.minAvailable: 1`, `spread: true`, `jvmOptions: -XX:MaxRAMPercentage=75`
- [ ] **Step 3** — 쿼터와 노드 확인: prod 요청 합계가 쿼터(18 CPU, 24Gi) 안이고 Pending이 없는지 본다.
- [ ] **Step 4** — `run-experiment.sh s1 step3`
- [ ] **Step 5** — `run-experiment.sh s2 step1`(같은 변경의 S2 측정)
- [ ] **Step 6: 커밋, PR**

### Task 14: S1 단계 4 카나리와 자동 롤백

**Files:**
- Create: `v3-john/gitops/charts/cosmos-app/templates/rollout.yaml`, `v3-john/helm/addons-values/argo-rollouts/values.yaml`
- Modify: `v3-john/scripts/up.sh`, `core.yaml`, `hpa.yaml`

**Interfaces:**
- Produces: 차트 값 `rollout: { enabled: false }`. 켜면 다음이 생긴다
  - `Rollout`(`workloadRef`로 기존 Deployment 참조, `scaleDown: progressively`)
  - `AnalysisTemplate` `core-health`
  - HPA의 `scaleTargetRef`를 Rollout으로 바꿈

- [ ] **Step 1: 렌더링 테스트**
  - `rollout.enabled=true`면 Rollout 단계가 `setWeight: 50` → `analysis`(5분) → `setWeight: 100`
  - 분석 조건: `cosmos:journey_error_ratio:rate5m{journey="core"} < 0.072`, `sum(increase(kube_pod_container_status_restarts_total{pod=~"cosmos-core-.*"}[5m])) == 0`
- [ ] **Step 2** — Argo Rollouts 차트를 고정 버전으로 `up.sh`에 넣고, core만 켠다.
- [ ] **Step 3** — `run-experiment.sh s1 step4`. 기대: 분석 실패로 자동 중단, 사람 개입 전 복구. 아니면 원인을 기록한다.
- [ ] **Step 4: 커밋, PR**

### Task 15 (선택): S1 단계 5 CI 값 검증

**Files:**
- Create: `.github/scripts/check-v3-john-values.py`, `.github/scripts/tests/fixtures/{ok,bad-limit,bad-heap}.yaml`
- Modify: `.github/workflows/gitops-ci.yml`

- [ ] **Step 1: 테스트** — `ok`는 통과. `bad-limit`(제한 < 요청)과 `bad-heap`(Spring 이미지인데 `jvmOptions`에 `MaxRAMPercentage` 없음)은 실패하고 파일 이름과 이유를 출력한다.
- [ ] **Step 2** — 구현하고 GitOps CI 단계로 추가한다.
- [ ] **Step 3** — S1 주입 PR이 CI에서 막히는지 확인한다(설계서: 우회 병합 결과는 단계 4와 같게 본다).
- [ ] **Step 4: 커밋, PR**

### Task 16: S1 런북과 비교표

- [ ] `v3-john/chaos/runbooks/bad-deploy.md`: 탐지 신호(알림 이름), 확인 쿼리(PromQL, kubectl, Tempo 검색), 완화(되돌리는 PR, Argo CD 롤백, Rollout 중단), 복구 확인.
- [ ] `v3-john/chaos/records/s1-summary.md`: 개선 전, 단계 1~4(5)의 8.3 지표 비교표.

---

## 2단계: S2 스팟 노드 회수 (개선 단계)

### Task 17: S2 단계 2~4

**Files:**
- Modify: `v3-john/helm/platform/cosmos-foundation/values.yaml`(우선순위 클래스), `auth.yaml`, `core.yaml`, `battle.yaml`, `v3-john/modules/eks/nodegroups.tf`, `variables.tf`

- [ ] **Step 1: 단계 2**
  - 우선순위 클래스 `cosmos-core-journey: 200000`을 추가하고 auth, core에 쓴다. battle은 `cosmos-api` 그대로
  - `run-experiment.sh s2 step2`
- [ ] **Step 2: 단계 3**
  - 노드 그룹 서브넷을 `aws_subnet.eks["a"]`에서 a, c 두 곳으로 바꾼다
  - application 인스턴스 유형에 `m6i.xlarge`, `m5a.xlarge`를 더한다
  - `terraform plan`이 노드 그룹 교체를 예고하면 실험 없는 시간에 적용한다
  - `run-experiment.sh s2 step3`. RDS와 다른 AZ 사이의 조회 p95 변화를 기록한다
- [ ] **Step 3 (선택): 단계 4**
  - EventBridge 규칙(`EC2 Spot Instance Interruption Warning`)에서 API Destination으로 Discord 웹훅에 보낸다
  - Spring `terminationGracePeriodSeconds: 60`과 `preStop` `sleep 10`
- [ ] **Step 4** — 런북 `spot-node-loss.md`, `records/s2-summary.md`
- [ ] **Step 5: 커밋, PR** (단계마다 하나)

---

## 3단계: S3 RDS 장애

### Task 18: Chaos Mesh와 S3a

**Files:**
- Create: `v3-john/helm/addons-values/chaos-mesh/values.yaml`, `v3-john/chaos/scenarios/s3a/{networkchaos.yaml,inject.sh,stop.sh}`
- Modify: `v3-john/scripts/up.sh`

**Interfaces:**
- Produces:
  - NetworkChaos `s3a-rds-partition`: `action: partition`, `direction: to`, 대상은 `app.kubernetes.io/name in (cosmos-auth, cosmos-core, cosmos-battle)`, `externalTargets: [10.30.20.0/23]`, `duration: 5m`
  - `stop.sh`는 리소스를 지운다

- [ ] **Step 1** — Chaos Mesh 차트를 고정 버전으로 설치한다. containerd 소켓 `/run/containerd/containerd.sock`, 대시보드 끔, `chaos-mesh` 네임스페이스.
- [ ] **Step 2: 동작 확인** — 주입 중 core 파드에서 RDS 3306 연결이 시간 초과되고, `ai-postgres`(클러스터 안 PostgreSQL) 연결은 성공해야 한다.
- [ ] **Step 3** — `run-experiment.sh s3a before`, 대응, 포스트모템.
- [ ] **Step 4: 단계 1**
  - auth, core, battle 준비 상태 검사를 `/actuator/health/readiness`로 바꾼다
  - `MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED: "true"`, `MANAGEMENT_ENDPOINT_HEALTH_GROUP_READINESS_INCLUDE: readinessState`
  - `run-experiment.sh s3a step1`
- [ ] **Step 5: 단계 2**
  - `SPRING_DATASOURCE_HIKARI_CONNECTION_TIMEOUT: "3000"`
  - Grafana CloudWatch 데이터 소스: Terraform으로 Grafana 서비스 계정에 Pod Identity, `cloudwatch:GetMetricData`, `ListMetrics` 읽기 권한
  - RDS 대시보드: 연결 수, CPU, 읽기·쓰기 지연
  - `run-experiment.sh s3a step2`
- [ ] **Step 6** — 런북 `rds-outage.md`
- [ ] **Step 7: 커밋, PR** (단계마다 하나)

### Task 19: S3b 삭제와 복원

**Files:**
- Create: `v3-john/chaos/scenarios/s3b/{snapshot.sh,inject.sh,recover-recreate.sh,recover-pitr.sh}`
- Modify: `v3-john/modules/data/main.tf`, `v3-john/scripts/down.sh`

**Interfaces:**
- Produces:
  - `snapshot.sh`: 수동 스냅샷 `cosmos-v3-john-safety-<날짜시각>`을 만들고 available까지 기다린다
  - `inject.sh`: `delete-db-instance`. 개선 전에는 `--skip-final-snapshot`, 단계 3 후에는 `--no-delete-automated-backups`
  - `recover-recreate.sh`: `terraform apply`(같은 식별자로 새로 생성) → `restore-mysql.sh` → `prepare.sh`
  - `recover-pitr.sh <UTC 시각>`: 남은 자동 백업에서 같은 식별자로 특정 시점 복원 → `terraform state rm`과 `import` → `terraform plan` 변경 없음 확인
  - 두 복구 스크립트 모두 끝에 Spring 3개를 재시작하고 시작·종료 시각을 출력한다

- [ ] **Step 1** — 개선 전: `snapshot.sh` → `run-experiment.sh s3b before`(주입 후 `recover-recreate.sh`). 복구 시간과 데이터 손실("시드 이후 전부")을 기록한다. 이 값을 보고 복구 목표를 정해 기록에 적는다(설계서: 측정 후 목표).
- [ ] **Step 2: 단계 3 Terraform**
  - `backup_retention_period = 1`, `deletion_protection = true`
  - `skip_final_snapshot = false`, `final_snapshot_identifier = "${var.name}-final"`
- [ ] **Step 3: `down.sh` 수정** — destroy 전에 순서대로 처리한다.
  1. 삭제 보호를 끈다(`modify-db-instance --no-deletion-protection --apply-immediately`)
  2. 이전 `${name}-final` 스냅샷이 있으면 지운다
- [ ] **Step 4: 검증**
  - 삭제 보호가 `delete-db-instance`를 막는지 확인
  - 보호를 풀고 `inject.sh`(자동 백업 유지) → `recover-pitr.sh`
  - 복구 시간과 손실 범위를 개선 전과 비교
- [ ] **Step 5 (선택): 단계 4** — Multi-AZ를 켜고 장애 조치 재부팅 시간을 잰다. 켜지 않기로 하면 비용과 수치를 기록한다.
- [ ] **Step 6** — 런북 `rds-restore.md`, `records/s3-summary.md`
- [ ] **Step 7: 커밋, PR**

---

## 4단계: 마무리

### Task 20: 최종 보고서

- [ ] `v3-john/chaos/REPORT.md`에 설계서 10장 항목을 모두 넣는다.
  - 시나리오별 비교표
  - 연쇄 경로(S1 서비스 호출 지도 캡처)
  - 도입한 도구와 대안
  - 도입하지 않은 결정
  - 앱 코드 개선 제안
  - 대응자 한 명의 한계
  - 실험 순서 변경 이유(S2 개선 전을 S1 단계 3보다 먼저 한 것, 노드 최대 3대 선적용)
- [ ] 보고서의 모든 수치가 `records/*.json`, S3 결과와 같은지 대조하는 스크립트 `v3-john/chaos/lib/verify-report.py`를 돌려 통과시킨다.
- [ ] 커밋, PR
