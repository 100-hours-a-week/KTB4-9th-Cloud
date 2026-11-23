# v3-john 장애 주입 2차 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 이중화가 된 현재 구성에서 S1'(연결 풀 고갈)과 S2'(스팟 노드 한 대 회수 뒤 남는 손실)를 재현하고, 근거와 대안 비교를 갖춘 개선을 단계마다 하나씩 넣어 3회씩 측정해 보고서에 2차 결과로 남긴다.

**Architecture:** 1차 실행기(`chaos/run-experiment.sh`)와 집계·기록·보고서 대조 도구를 그대로 쓰고, 부하를 열린 모델로, 탐지 기준을 실제 요청 SLI로 바꾼다. 시나리오는 `chaos/scenarios/s1p`(새로), `chaos/scenarios/s2`(배치 재현 추가)에 둔다. 개선은 Helm 값, 차트, Terraform, 알림 규칙, CI 스크립트로만 한다.

**Tech Stack:** EKS 1.37, Argo CD, Argo Rollouts 2.43.12, Envoy Gateway 1.9.3(BackendTrafficPolicy), kube-prometheus-stack 92.18.0(promtool), descheduler, AWS FIS, k6 1.3.0, Terraform(AWS provider 5.x), Python 3 unittest, bash.

**Spec:** `docs/superpowers/specs/2026-11-24-v3-john-fault-injection-round2-design.md`(12e762f). 1차 계획 `docs/superpowers/plans/2026-11-10-v3-john-fault-injection.md`의 도구를 이어 쓴다.

## Global Constraints

- 앱 코드 수정 금지. Terraform, Helm 값, GitOps 값, 차트, 애드온, 스크립트만 바꾼다
- Spot vCPU 한도 32, 한도 증가 요청 금지. 실험 중단 기준 Spot vCPU 28 초과 유지. 온디맨드 표준 vCPU 한도 128(별개)
- 시크릿 값은 화면·로그·커밋에 남기지 않는다. IAM·Secrets Manager는 Terraform으로만
- Discord 실제 게시(S2' 단계 4) 전에 사용자 확인
- 한 번에 시나리오 하나, 주입 유지 최대 600초. 기록은 `v3-john/chaos/records/`와 `s3://cosmos-db-backup-352635536602/chaos/`
- 이미지·차트 버전과 digest 고정
- 문서는 서술체(~다), 한글 뒤 괄호 영단어 금지
- 내 PR은 테스트·CI 확인 뒤 직접 main 병합(사용자 허용 2026-11-24)
- 단계당 변경 하나, 단계당 3회. 비교는 중앙값과 최소~최대
- 개선 전 구성은 현재 main(PR #88)이다
- 모든 개선 단계는 실험 전에 결정 기록 `chaos/decisions/<시나리오>-step<N>.md`를 쓴다(근거, 대안 3개 이상 비교, 선택 이유, 실험 전에 정한 검증 기준, 결과). 설계서 6.3
- 최종 보고서는 첫 장에 SLI·SLO·오류 예산을 먼저 쓴다
- 주입값·부하는 개선 전에 정한 값으로 끝까지 고정한다(반목표)

## Review Focus

1. **배치 재현이 중간에 실패해 다른 노드의 cordon이 남음**: 이후 파드가 대상 노드에만 쌓인다. `stage.sh`는 실패해도 uncordon하고, 실행기 사전 검사가 cordon된 application 노드를 발견하면 시작하지 않는다(Task 11 테스트)
2. **RDS 연결이 꽉 찬 상태에서 실험 도구가 DB에 못 붙음**: `prepare.sh`가 실패해 다음 회차가 막힌다. `stop.sh`가 core 풀을 되돌리고 연결 수가 기준 아래로 떨어질 때까지 기다린 뒤 끝난다(Task 5)
3. **카나리 분석의 새 지표가 트래픽·파드 없을 때 비거나 NaN**: 정상 배포가 막힌다(1차 리비전 4 재발). 새 질의는 모두 빈 결과를 통과로 보도록 `or vector(0)`·`len(result)==0` 처리(Task 9 테스트)
4. **연결 예산 계산에서 Rollout 카나리 추가 파드 누락**: CI가 실제 장애 조건을 놓친다. Rollout은 HPA 최대의 25% 올림을 더한다(Task 8 테스트)
5. **게이트웨이 재시도가 제출(POST)을 두 번 보냄**: 채점이 중복된다. 재시도 정책 대상에서 제출·AI 경로를 빼고, 정책 대상 목록을 확인한다(Task 14 Step 1)

---

## 파일 구조

| 경로 | 책임 |
|---|---|
| `v3-john/loadtest/baseline.js`, `loadtest/k8s/{job.yaml,run-k6.sh}` | 열린 부하 모델(`RATE`) |
| `v3-john/helm/addons-values/monitoring/kube-prometheus-stack.yaml`, `monitoring/tests/*.yaml` | 실제 요청 SLI 규칙, 연결 예산 알림, promtool 테스트 |
| `v3-john/chaos/lib/aggregate.py`, `chaos/tests/test_aggregate.py` | 영향 범위, 핵심 SLO 유지율, 서비스별 오류율 |
| `v3-john/chaos/scenarios/s1p/` | S1' 주입(core 풀 PR + auth 재시작), 원복 |
| `.github/scripts/check-v3-john-values.py`, `.github/scripts/tests/` | 연결 예산 CI 검사 |
| `v3-john/gitops/charts/cosmos-app/templates/rollout.yaml`, `values.yaml`, `tests/test-rollout.sh` | 영향 범위 카나리 분석 |
| `v3-john/chaos/scenarios/s2/stage.sh` | 회차별 배치 재현 |
| `v3-john/chaos/decisions/` | 개선 결정 기록(근거, 대안 비교, 검증 기준, 결과) |
| `v3-john/gitops/charts/cosmos-app/templates/_pod.tpl`, `values.yaml` | preStop, 종료 정리 값 |
| `v3-john/gitops/environments/prod/platform/gateway.yaml` | 게이트웨이 재시도 정책 |
| `v3-john/modules/eks/variables.tf`, `helm/addons-values/monitoring/*.yaml` | 모니터링용 온디맨드 노드 그룹 |
| `v3-john/helm/addons-values/descheduler/values.yaml` | 재분산(선택) |
| `v3-john/chaos/runbooks/{db-connection-exhaustion.md,spot-node-loss.md}`, `chaos/records/{s1p,s2p}-*`, `chaos/REPORT.md`, `chaos/lib/verify-report.py` | 런북, 기록, 보고서 |

---

## 0단계: 공통

### Task 1: 열린 부하 모델

**Files:** Modify `v3-john/loadtest/baseline.js`, `loadtest/k8s/job.yaml`, `loadtest/k8s/run-k6.sh`, `loadtest/tests/test-baseline.sh`

**Interfaces:**
- Produces: 환경 변수 `RATE`(초당 반복 수, 정수). 있으면 `steady` 시나리오가 `constant-arrival-rate`(`rate: RATE, timeUnit: '1s', preAllocatedVUs: max(10, RATE*2), maxVUs: RATE*20`)이고, 없으면 1차와 같은 `constant-vus`. `run-k6.sh <testid> <duration> [vus]`는 그대로, `RATE=<n> run-k6.sh ...`로 넘긴다(job.yaml `__RATE__`)

- [ ] **Step 1: 테스트** — `test-baseline.sh`에 경우 추가: 가짜 API(`mock_api.py`)에 `RATE=5 DURATION=20s`로 돌리면 `iterations`가 80~120, `RATE` 없이 `VUS=2`면 기존 결과와 같음
- [ ] **Step 2: 실패 확인** — `bash v3-john/loadtest/tests/test-baseline.sh` → RATE 경우 FAIL
- [ ] **Step 3: 구현** — 위 Interfaces대로. 시나리오 객체만 바꾸고 흐름 함수는 그대로
- [ ] **Step 4: 통과 확인** — 같은 명령 → PASS 전부
- [ ] **Step 5: 커밋**

### Task 2: 실제 요청 SLI와 연결 알림 규칙

**Files:** Modify `helm/addons-values/monitoring/kube-prometheus-stack.yaml`; Create `helm/addons-values/monitoring/tests/round2.yaml`; Modify `v3-john/scripts/check-rules.sh`(새 테스트 파일 포함)

**Interfaces:**
- Produces:
  - 기록 규칙 `cosmos:route_errors_all:rate5m`: 1차 `cosmos:route_errors:rate5m`에 `envoy_cluster_upstream_rq_timeout`, `envoy_cluster_upstream_cx_connect_fail`을 더한 것(라벨 route, journey 동일)
  - 기록 규칙 `cosmos:journey_error_ratio_all:rate5m`, `:rate1h`(위 오류 / `cosmos:route_requests:rate5m` 기준)
  - 알림 `CoreBurnFastAll`(SEV1): `rate1h > 0.072 and rate5m > 0.072`, journey="core", for 2m. 탐지 시간의 기준 알림
  - 알림 `ServiceErrorHigh`(SEV2): route별 `route_errors_all / route_requests > 0.05` 2분 — 어느 경로(auth, battle 등)가 먼저 무너졌는지 보여 준다
  - 기록 규칙 `cosmos:db_connections:sum` = `sum(hikaricp_connections{namespace="prod"})`
  - 알림 `RdsConnectionBudgetHigh`(SEV2): `cosmos:db_connections:sum / RDS_MAX > 0.8` 1분. `RDS_MAX`는 Task 4에서 잰 값을 규칙에 상수로 넣는다(Task 4 전에는 자리 표시 값 300으로 테스트하고 Task 4에서 바꾼다)
  - 알림 `DbConnectionAcquireFailed`(SEV2): `sum by (pod) (increase(hikaricp_connections_timeout_total{namespace="prod"}[2m])) > 0`
  - 단, `RdsConnectionBudgetHigh`, `DbConnectionAcquireFailed`는 S1' 단계 1의 개선이므로 **규칙은 이 작업에서 만들되 `enabled` 라벨이 아니라 별도 그룹 `cosmos-round2-s1p-step1`에 두고**, 단계 1 전까지 Alertmanager 경로에서 `blackhole`로 보낸다(개선 전 조건 유지). 단계 1(Task 7)에서 경로만 연다

- [ ] **Step 1: 테스트** — `round2.yaml` promtool 테스트: (a) upstream 5xx 0이고 timeout만 있는 시계열에서 `CoreBurnFastAll`이 3분에 firing (b) auth 경로만 오류 10%일 때 `ServiceErrorHigh{route="journey-core-auth"}`만 firing (c) hikaricp 합 250, RDS_MAX 300에서 `RdsConnectionBudgetHigh` firing, 230에서 아님 (d) timeout_total 증가 시 `DbConnectionAcquireFailed`
- [ ] **Step 2: 실패 확인** — `bash v3-john/scripts/check-rules.sh` → round2 실패
- [ ] **Step 3: 구현** — 규칙 추가, Alertmanager 경로에 `alertname=~"RdsConnectionBudgetHigh|DbConnectionAcquireFailed"` → blackhole 수신자
- [ ] **Step 4: 통과 확인** — `check-rules.sh` → SUCCESS, 1차 테스트 포함 전부 통과
- [ ] **Step 5: 커밋**

### Task 3: 집계에 영향 범위·핵심 SLO 유지율

**Files:** Modify `v3-john/chaos/lib/aggregate.py`, `chaos/lib/render_record.py`, `chaos/records/TEMPLATE.md`; Test `chaos/tests/test_aggregate.py`

**Interfaces:**
- Produces:
  - `slo_hold_ratio(samples: list[tuple[float,float]], start_t: int, end_t: int, target: float = 0.005) -> float | None` — 구간 안 표본 중 값이 target 이하인 비율. NaN은 분모에서 뺀다. 표본이 없으면 None
  - `blast_radius(route_ratios: dict[str, list[tuple[float,float]]], start_t: int, end_t: int, threshold: float = 0.05) -> list[str]` — 구간 안에서 한 번이라도 threshold를 넘은 route 이름 정렬 목록
  - 기록 필드 `core_slo_hold`(1분 창 핵심 오류율로 계산), `blast_radius`(route별 1분 창 `route_errors_all/route_requests`), `detection_all`(`CoreBurnFastAll`·`ServiceErrorHigh` 중 첫 firing, 1차 `first_alert` 재사용)
  - 1차 필드는 그대로 둔다(1차 기록과 비교 가능)

- [ ] **Step 1: 테스트** — `test_slo_hold_ratio_ignores_nan`(표본 [0.001, NaN, 0.01, 0.002] → 2/3), `test_slo_hold_ratio_empty_is_none`, `test_blast_radius_threshold`(auth 0.06 한 번, core 0.01 → ["journey-core-auth"]), `test_blast_radius_outside_window_ignored`
- [ ] **Step 2: 실패 확인** — `python3 -m unittest discover -s v3-john/chaos/tests` → 새 4개 FAIL
- [ ] **Step 3: 구현** — 두 함수, `main()`에서 질의해 필드 추가, render에 "영향 범위", "핵심 SLO 유지율" 줄 추가
- [ ] **Step 4: 통과 확인** — 같은 명령 → OK
- [ ] **Step 5: 커밋**

### Task 4: 기동, 기준선 재측정, RDS 상한 실측

운영 작업이다. 코드는 Task 2의 상수만 바꾼다.

- [ ] **Step 1** — Task 1~3 PR 병합 뒤 `scripts/up.sh`. 프런트엔드 빌드 실패는 무시(1차와 같음)
- [ ] **Step 2: RDS 상한** — `prepare.sh`가 쓰는 대기 파드 방식으로 `SHOW VARIABLES LIKE 'max_connections'`, `SHOW STATUS LIKE 'Threads_connected'`를 잰다. Expected: 숫자 두 개. `records/round2-baseline.md`에 적는다
- [ ] **Step 3** — `RdsConnectionBudgetHigh`의 `RDS_MAX`를 실측값으로 바꾸고 `check-rules.sh` 통과 뒤 병합·적용
- [ ] **Step 4: 기준 초당 요청 수** — `RATE`를 10, 20, 30으로 각 5분 돌려, 핵심 오류율 0이고 조회 p95가 1차 기준선(24ms)의 120% 이하인 가장 큰 값을 `RATE_BASE`로 정한다. 같은 파일에 적는다
- [ ] **Step 5: 기준선 3회** — `RATE=$RATE_BASE run-k6.sh round2-base-<n> 10m`. 핵심 SLO 유지율 100%, `CoreBurnFastAll` 미발생이 기준이다. 아니면 원인을 고치기 전까지 다음 작업으로 가지 않는다
- [ ] **Step 6: 커밋**(기록, 상수)

## 1단계: S1' 연결 풀 고갈

### Task 5: S1' 시나리오

**Files:** Create `v3-john/chaos/scenarios/s1p/{lib.sh,set_pool.py,inject.sh,stop.sh,scenario.env,README.md}`, `chaos/tests/test_set_pool.py`

**Interfaces:**
- Consumes: 1차 `scenarios/s1/lib.sh`의 `s1_merge` 흐름(작업 트리, PR, 병합, Argo 동기화 대기, `own-revisions` 기록)
- Produces:
  - `set_pool.py <values-file> <n>`: `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: "<n>"` 한 줄만 바꾼다. 줄이 없거나 두 개 이상이면 종료 코드 2
  - `s1p_merge_pool <n> <msg>`: `s1_merge`와 같은 흐름으로 core 값 파일 풀만 바꿔 병합
  - `inject.sh`: 원래 값을 `$RECORD_DIR/s1p-original`에 저장 → `s1p_merge_pool $S1P_POOL` → core Rollout Healthy 대기(최대 600초. 카나리 5분 분석 포함) → `S1P_TRIGGER_DELAY`(기본 180)초 대기 → `kubectl rollout restart deployment/cosmos-auth` → 시각을 `s1p-events`에 기록하고 반환(auth 롤아웃 완료는 기다리지 않음)
  - `stop.sh`(멱등): 풀을 원래 값으로 되돌리는 PR → core Healthy 대기 → auth가 모두 Ready가 아니면 auth 재시작 → `cosmos:db_connections:sum`이 실험 전 값 +20 이하가 될 때까지 최대 300초 대기
  - `scenario.env`: `INJECT_DURATION=600`

- [ ] **Step 1: 테스트** — `test_set_pool.py`: 한 줄 교체, 따옴표 유지, 없는 줄 → 2, 두 줄 → 2, 다른 줄(`SPRING_DATASOURCE_HIKARI_CONNECTION_TIMEOUT`) 불변
- [ ] **Step 2: 실패 확인** — `python3 -m unittest v3-john/chaos/tests/test_set_pool.py` → FAIL
- [ ] **Step 3: 구현** — 위 Interfaces. `bash -n` 통과
- [ ] **Step 4: 통과 확인** — 같은 명령 → OK
- [ ] **Step 5: 커밋**

### Task 6: S1' 주입값 보정과 개선 전 3회

- [ ] **Step 1: N 후보** — Task 4의 상한 M, 평상시 연결 C(실측)로, core 2개 × N + 나머지가 M 아래이고, 여기에 auth 새 파드 1개 × 10이 더해지면 M을 넘는 N을 계산한다(카나리 중 core 파드 3개일 때도 M 아래인지 확인). 계산을 `records/s1p-calibration.md`에 적는다
- [ ] **Step 2: 보정 3회** — `S1P_POOL=<N> RATE=$RATE_BASE run-experiment.sh s1p calib-<k>`. 3회 모두 auth 경로 `ServiceErrorHigh` 또는 auth 새 파드 준비 실패가 나야 확정. 아니면 N을 한 단계 올려 다시. N을 올려도 core 배포 자체가 실패하면(core 카나리 중단) 그 결과를 기록하고 사용자에게 알린 뒤 멈춘다(설계서 6.1 대체 경로 B·C)
- [ ] **Step 3: 개선 전 3회** — 같은 N으로 `s1p before`. 대응자는 원인을 모르는 척하지 않고 `response.log`에 판단 순서를 남긴다(auth 배포를 먼저 의심했는지 포함)
- [ ] **Step 4** — 포스트모템 `records/s1p-before-postmortem.md`(양식 `incident/postmortem-template.md`), 커밋

### Task 7: S1' 단계 1 연결 알림과 런북

**Files:** Modify `kube-prometheus-stack.yaml`(Alertmanager 경로에서 blackhole 제거); Create `chaos/runbooks/db-connection-exhaustion.md`

- [ ] **Step 0: 결정 기록** — `chaos/decisions/s1p-step1.md`(설계서 6.3 형식, 대안은 6.3 예시 표 참고). 검증 기준을 실험 전에 적는다
- [ ] **Step 1** — 경로만 열고 `check-rules.sh` 통과. Expected: 1차·2차 테스트 모두 SUCCESS
- [ ] **Step 2** — 런북: 탐지 신호(`RdsConnectionBudgetHigh`, `DbConnectionAcquireFailed`, `ServiceErrorHigh`), 확인(`cosmos:db_connections:sum` 서비스별 분해 질의, 최근 값 변경 PR, CloudWatch `DatabaseConnections`), 완화(연결을 늘린 PR 되돌림 — 터진 서비스가 아니라 연결을 가장 많이 쥔 서비스부터), 복구 확인
- [ ] **Step 3** — 병합, `s1p step1` 3회, 메모에 탐지 시간과 "원인 서비스를 맞힐 때까지 걸린 시간"

### Task 8: S1' 단계 2 연결 예산 CI

**Files:** Modify `.github/scripts/check-v3-john-values.py`; Create `.github/scripts/tests/fixtures/{budget-ok,budget-over}/*.yaml`; Modify `.github/scripts/tests/test_check_values.py`

**Interfaces:**
- Produces: `connection_budget(paths: list[str]) -> tuple[int, list[str]]` — (최대 연결 합계, 계산 내역). 서비스별 `(hpa.max + surge) × HIKARI_MAXIMUM_POOL_SIZE`. surge: 값 파일에 `rollout: { enabled: true }`면 `ceil(hpa.max × 0.25)`, 아니면 `rollingUpdate.maxSurge`(차트 기본 1). 풀 줄이 없으면 Hikari 기본 10. 규칙 4: 합계 > `RDS_MAX_CONNECTIONS × 0.8`이면 실패. `RDS_MAX_CONNECTIONS`는 스크립트 상수(Task 4 실측값)

- [ ] **Step 0: 결정 기록** — `chaos/decisions/s1p-step2.md`(설계서 6.3 형식, 대안은 6.3 예시 표 참고). 검증 기준을 실험 전에 적는다
- [ ] **Step 1: 테스트** — `test_budget_counts_rollout_surge`(core rollout, hpa max 3, 풀 40 → (3+1)×40=160), `test_budget_deployment_surge`(auth hpa max 2, 풀 10 → 30), `test_budget_over_fails`(fixture 합계가 0.8M 초과 → 종료 1, 출력에 "연결 예산"), `test_budget_ok_passes`, 현재 prod 값 통과
- [ ] **Step 2: 실패 확인** — `python3 -m unittest discover -s .github/scripts/tests` → FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — 같은 명령 → OK, `check-v3-john-values.py v3-john/gitops/environments/prod/*.yaml` → 0
- [ ] **Step 5** — 병합. 사용자에게 main 필수 검사 지정을 요청한다(저장소 관리자 설정). 확인용 draft PR(core 풀 N)이 CI에서 실패하는지 보고 닫는다
- [ ] **Step 6** — `s1p step2` 3회는 CI를 우회해 같은 PR을 병합한다(`s1p_merge_pool`은 CI를 기다리지 않음). 기록에 "CI 실패, 우회 병합"을 남긴다. 필수 검사가 지정되었다면 우회 병합이 거부되는 것 자체를 결과로 기록하고 실험은 1회만

### Task 9: S1' 단계 3 영향 범위 카나리

**Files:** Modify `gitops/charts/cosmos-app/templates/rollout.yaml`, `values.yaml`, `tests/test-rollout.sh`, `gitops/environments/prod/core.yaml`

**Interfaces:**
- Produces: 차트 값 `rollout.connectionGuard: { enabled: false, rdsMax: 0, reserve: 0 }`. 켜면 AnalysisTemplate에 지표 두 개 추가
  - `db-connection-headroom`: `cosmos:db_connections:sum or vector(0)`, 성공 조건 `result[0] <= rdsMax - reserve`. `reserve`는 "다른 서비스가 한 번 재배포할 여유" = 가장 큰 서비스의 (레플리카 최대 × 풀). core.yaml에 Task 4 실측과 함께 값으로 넣는다
  - `other-routes-error`: `max(cosmos:journey_error_ratio_all:rate5m{journey="major"} >= 0) or vector(0)`, 성공 조건 `result[0] < 0.05`, 그리고 auth 경로(`route="journey-core-auth"`) 오류율 같은 조건
  - 분석 간격·횟수는 1차와 같음(1분, 5회, 실패 허용 0)

- [ ] **Step 0: 결정 기록** — `chaos/decisions/s1p-step3.md`(설계서 6.3 형식, 대안은 6.3 예시 표 참고). 검증 기준을 실험 전에 적는다
- [ ] **Step 1: 테스트** — `test-rollout.sh`: connectionGuard 켜면 두 지표 존재, `rdsMax - reserve` 값이 성공 조건에 렌더링, 질의에 `or vector(0)` 포함, 꺼지면 1차와 같은 두 지표만
- [ ] **Step 2: 실패 확인** — `bash v3-john/gitops/charts/cosmos-app/tests/test-rollout.sh` → FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — 같은 명령 → PASS, 다른 차트 테스트도 PASS
- [ ] **Step 5** — 병합, 트래픽 없는 상태에서 무변경 재시작으로 분석이 통과하는지 먼저 확인(Review Focus 3). Expected: Rollout Healthy
- [ ] **Step 6** — `s1p step3` 3회. 기대: core 카나리가 `db-connection-headroom` 실패로 자동 중단, auth 재시작 시점에는 core가 원래 풀로 돌아가 있어 로그인 정상

### Task 10: S1' 단계 4 최소 유휴 연결 축소

설계서가 빌더에게 맡긴 선택(최소 유휴 연결 축소 vs RDS Proxy vs 인스턴스 상향)은 결정 기록에서 비교해 정한다. 계획의 기본안은 **최소 유휴 연결 축소**다(값 파일만, 추가 비용·엔드포인트 변경 없음). 결정 기록이 다른 안을 고르면 이 작업의 Files를 그 안으로 바꾸고 기록에 이유를 남긴다.

**Files:** Modify `gitops/environments/prod/{auth,core,battle}.yaml`(`SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE: "2"`), `.github/scripts/check-v3-john-values.py`(규칙 5: Spring 값에 최소 유휴 연결이 있고 최대 풀의 절반 이하), 테스트 fixture 1개

- [ ] **Step 0: 결정 기록** — `chaos/decisions/s1p-step4.md`(설계서 6.3 형식, 대안은 6.3 예시 표 참고). 검증 기준을 실험 전에 적는다
- [ ] **Step 1~4** — 규칙 5 테스트(없음 → 실패, 최대 40·최소 2 → 통과) RED → GREEN
- [ ] **Step 5** — 병합 뒤 단계 3 카나리 조건은 그대로 두고(연결 여유가 늘어 통과할 수 있음) `s1p step4` 3회. 측정: 같은 N에서 연결 합계 최대값, auth 재시작 결과, 조회 p95 변화(연결을 새로 여는 비용)
- [ ] **Step 6** — `records/s1p-summary.md`(설계서 4.2 지표 전부, 중앙값·범위), 커밋

## 2단계: S2' 스팟 노드 한 대 회수, 손실 원인 제거

### Task 11: 배치 재현과 집계 지표

**Files:** Create `v3-john/chaos/scenarios/s2/stage.sh`; Modify `chaos/scenarios/s2/README.md`, `chaos/run-experiment.sh`(사전 검사), `chaos/lib/aggregate.py`; Test `chaos/tests/test-s2.sh`, `chaos/tests/test_aggregate.py`

**Interfaces:**
- Produces:
  - `stage.sh <node>`: 다른 application 노드를 cordon → judge-api, Envoy 파드 하나, Prometheus·Alertmanager·Tempo, core 파드 하나를 지워 `<node>`에 다시 뜨게 함 → 모두 Ready 대기(최대 300초) → 반드시 uncordon(`trap`) → `$RECORD_DIR/s2-staged.txt`에 실제 배치 기록. `S2_STAGE_SKIP=monitoring,...`로 개선 단계가 바꾼 항목은 건너뜀. 배치가 하나라도 안 맞으면 종료 1
  - 실행기 사전 검사: cordon된 application 노드가 있으면 시작하지 않음
  - 집계 필드: `monitoring_gap_seconds`(Prometheus `up{job=~".*prometheus.*"}` 표본이 비거나 0인 구간 길이, 판정 구간 안), `placement_skew`(실험 끝 시각에 서비스별 "같은 노드의 최대 레플리카 수", kube-state-metrics `kube_pod_info` 기준 auth, core, battle, judge-api)

- [ ] **Step 1: 테스트** — `test-s2.sh`: 가짜 kubectl로 stage가 실패해도 uncordon 호출, `S2_STAGE_SKIP` 존중, 배치 불일치 시 종료 1. `test_aggregate.py`: `monitoring_gap_seconds`(표본 [1,1,빈,빈,1] 15초 간격 → 30), `placement_skew`(core 2개 같은 노드 → 2)
- [ ] **Step 2: 실패 확인** — `bash v3-john/chaos/tests/test-s2.sh; python3 -m unittest discover -s v3-john/chaos/tests` → 새 경우 FAIL
- [ ] **Step 3: 구현**
- [ ] **Step 4: 통과 확인** — 1차 경우 포함 전부 PASS/OK
- [ ] **Step 5: 커밋**

### Task 12: S2' 개선 전 3회

- [ ] **Step 1** — 회차마다 `stage.sh <대상>` 뒤 `S2_NODE=<대상> RATE=$RATE_BASE run-experiment.sh s2p before`. 대상 노드는 cordon하지 않는다(1차의 k6 위치 문제는 k6 Job에 대상 노드 반친화성을 주는 것으로 해결: `job.yaml`에 `K6_AVOID_NODE` 값이 있으면 `nodeAffinity` NotIn)
- [ ] **Step 2** — 측정: 회수 구간 5xx·연결 오류, 채점 유실, 모니터링 공백, 배치 쏠림. 3회 중앙값이 6.2 표의 손실을 재현하는지 확인(재현 안 되는 손실은 그 개선 단계를 기록과 함께 뺀다)
- [ ] **Step 3** — 포스트모템 `records/s2p-before-postmortem.md`, 커밋

### Task 13: S2' 단계 1 종료 정리

**Files:** Create `chaos/decisions/s2p-step1.md`; Modify `gitops/charts/cosmos-app/templates/_pod.tpl`, `values.yaml`(값 `preStopSleepSeconds: 0` → 0보다 크면 `lifecycle.preStop.exec: ["sh","-c","sleep N"]`), `gitops/environments/prod/{auth,core,battle,judge-api}.yaml`(`preStopSleepSeconds`, Spring 3개에 `SERVER_SHUTDOWN: graceful`, `SPRING_LIFECYCLE_TIMEOUT_PER_SHUTDOWN_PHASE`), `tests/test-lifecycle.sh`

- [ ] **Step 0: 결정 기록** — 설계서 6.3 형식. 근거는 Task 12 측정값. 대안: 정상 종료 + preStop / Envoy 능동 헬스 체크 / 재시도만으로 흡수. 검증 기준을 실험 전에 적는다(예: 회수 구간 5xx 중앙값 0)
- [ ] **Step 1~4** — `test-lifecycle.sh`: 값 0이면 `lifecycle` 없음, 10이면 `sleep 10` 렌더링, `terminationGracePeriodSeconds`가 preStop + 종료 단계 제한보다 커야 함(아니면 렌더링 실패 — `fail` 함수) — RED → GREEN
- [ ] **Step 5** — 병합, `s2p step1` 3회, 결정 기록에 결과

### Task 14: S2' 단계 2 게이트웨이 재시도

**Files:** Create `chaos/decisions/s2p-step2.md`; Modify `gitops/environments/prod/platform/gateway.yaml`(Envoy Gateway `BackendTrafficPolicy`, 대상 HTTPRoute: `journey-core-auth`, `journey-core-problem`, `journey-major-battle`, `journey-major-core`. 제출 `journey-core-submit`과 AI는 제외. 재시도 조건: `connect-failure`, `reset`, 상태 503, 최대 2회, 재시도별 제한 시간 2초)

- [ ] **Step 0: 결정 기록** — 대안: 게이트웨이 재시도 / 클라이언트 재시도(프런트 코드) / 이상치 감지. 위험: 비멱등 요청 중복 — 대상 경로가 GET만 받는지 확인한 결과를 적는다
- [ ] **Step 1** — 렌더링 검사: `kubectl apply --dry-run=server`(클러스터) 또는 Envoy Gateway CRD 스키마 검증으로 정책이 대상 경로에만 붙는지 확인. Expected: 정책 대상 목록에 submit 없음
- [ ] **Step 2** — 병합, 적용 확인(`kubectl get backendtrafficpolicy -n prod`의 `Accepted` 조건)
- [ ] **Step 3** — `s2p step2` 3회. 재시도 수는 Envoy `envoy_cluster_upstream_rq_retry` 지표로 기록

### Task 15: S2' 단계 3 judge-api 이중화

**Files:** Create `chaos/decisions/s2p-step3.md`; Modify `gitops/environments/prod/judge-api.yaml`(`hpa.min: 2`, `pdb: { minAvailable: 1 }`, `spread: true`)

- [ ] **Step 0: 결정 기록** — 대안: 이중화 / 채점 결과 비동기 조회(앱 코드, 제안으로) / 온디맨드 노드 고정. judge-api가 상태를 갖지 않는지(채점 큐가 judge-redis에 있는지) 확인한 근거를 적는다
- [ ] **Step 1** — 렌더링 검사: 1차 `test-ha.sh`에 judge-api 경우 추가 — RED → GREEN
- [ ] **Step 2** — 쿼터와 노드 여유 확인(1차 Task 13 Step 3과 같은 방법). Pending이면 원인과 조치를 결정 기록에 적는다
- [ ] **Step 3** — 병합, `s2p step3` 3회(배치 재현은 judge-api 하나를 대상 노드에, 다른 하나는 다른 노드에)

### Task 16: S2' 단계 4 모니터링 분리

**Files:** Create `chaos/decisions/s2p-step4.md`; Modify `v3-john/modules/eks/variables.tf`(노드 그룹 `monitoring-od-ng`: `capacity_type = "ON_DEMAND"`, 유형 `["t3.large"]`, min·desired·max 1, 라벨 `workload-class: monitoring`, 테인트 `workload=monitoring:NoSchedule`), `helm/addons-values/monitoring/{kube-prometheus-stack,tempo,loki}.yaml`(nodeSelector·toleration), `chaos/scenarios/s2/stage.sh` 호출부(`S2_STAGE_SKIP=monitoring`)

- [ ] **Step 0: 결정 기록** — 대안: 온디맨드 분리 / Prometheus·Alertmanager 2중화(스팟 유지) / AMP·AMG. 비용은 AWS 가격 API나 공개 가격표로 시간당·월 금액을 적고 출처를 남긴다. PV가 AZ a에 있으므로 노드 그룹 서브넷은 a
- [ ] **Step 1** — `terraform plan`: 노드 그룹 1개와 launch template 추가, 다른 변경 없음
- [ ] **Step 2** — 적용, helm 업그레이드, 모니터링 파드가 새 노드에 있고 PV가 붙었는지 확인
- [ ] **Step 3** — `s2p step4` 3회. 모니터링 공백 시간 중앙값, 비용 증가율

### Task 17 (선택): S2' 단계 5 재분산

**Files:** Create `chaos/decisions/s2p-step5.md`, `helm/addons-values/descheduler/values.yaml`; Modify `scripts/up.sh`(descheduler 차트 고정 버전, 이미지 digest)

- [ ] **Step 0: 결정 기록** — 대안: descheduler(`RemovePodsViolatingTopologySpreadConstraint`, 주기) / `DoNotSchedule` / 런북 수동 재시작. `DoNotSchedule`의 위험(노드 부족 시 Pending)을 1차 CPU 요청 사례로 적는다
- [ ] **Step 1** — 설치, 실험 없이 쏠림을 만들어(재시작으로 한 노드에 몰기) 주기 안에 다시 나뉘는지 확인. Expected: `placement_skew` 1
- [ ] **Step 2** — `s2p step5` 3회. 측정: 회수·교체 뒤 쏠림, 재분산까지 시간, 재분산 중 5xx

### Task 17b: S2' 정리

- [ ] `records/s2p-summary.md`(설계서 4.2 지표와 손실 4종, 비용 표), `runbooks/spot-node-loss.md` 갱신, 결정 기록 5개 링크. 온디맨드 모니터링 노드 유지 여부를 비용 표와 함께 사용자에게 묻는다. 커밋

## 3단계: 마무리

### Task 18: 보고서 2차 장

**Files:** Modify `v3-john/chaos/REPORT.md`, `chaos/EVALUATION.md`, `chaos/lib/verify-report.py`

- [ ] **Step 1** — `verify-report.py`의 CLAIMS에 2차 기록 추가: 회차별 행 대신 `s1p-*-summary`의 중앙값 행. 중앙값 계산 함수 `median_of(names: list[str], path: str) -> float`를 스크립트에 두고 테스트 `chaos/tests/test_verify_report.py`(값 3개 → 가운데, 2개 → 평균)
- [ ] **Step 2: SLI·SLO·오류 예산을 맨 앞에(사용자 요청 2026-11-24)** — REPORT 첫 장을 "SLI, SLO, 오류 예산"으로 새로 쓴다. 보고서의 모든 수치가 이 정의를 기준으로 읽히도록 다른 장보다 먼저 둔다. 내용: 기능 묶음(핵심·주요·AI·채점)과 경로, 묶음별 SLI 식(1차 `cosmos:journey_error_ratio`, 2차 `cosmos:journey_error_ratio_all`과 차이), SLO 값(핵심 99.5%, 주요 99%, AI 95%, 조회 p95 50ms, 채점 완료), 4주 오류 예산과 계산식, 빠른·느린 소진 알림 기준(14.4배 등), 심각도 매트릭스와의 연결(`incident/severity.md`), 1차에서 찾은 SLI 사각지대와 2차에서 고친 점. 값은 1차 설계서와 `kube-prometheus-stack.yaml` 규칙에서 옮기고, 규칙 파일과 다르면 규칙 파일을 기준으로 적는다
- [ ] **Step 3** — REPORT: "2차 실험" 장(S1', S2' 비교표, 연쇄, 비용 표), 1차 S1·S2는 "1차 실험과 한계"로 옮기고 링크. 이력서·포트폴리오 절을 2차 결과 기준으로 다시 쓴다(수치는 표에서만)
- [ ] **Step 4** — EVALUATION에 2차가 고친 방법 문제와 남은 한계 추가
- [ ] **Step 5** — `python3 chaos/lib/verify-report.py --s3` → OK, 병합
- [ ] **Step 6** — 사용자에게 `down.sh` 여부를 묻는다(온디맨드 노드 그룹, 2차 스냅샷 포함 정리 범위 안내)
