# v3-john 장애 주입과 장애 대응 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** v3-john에 장애 주입 실험 체계를 만들고, 실험으로 찾은 약점을 고친 뒤 같은 실험으로 전후 수치를 비교한다.

**Architecture:** 0단계에서 SLO, k6, 실험 실행기로 기준선을 만들고, 1단계에서 Chaos Mesh와 FIS로 현재 구조를 실험해 설정으로 고칠 수 있는 약점을 고친다. 2단계는 실험 결과가 조건을 넘을 때만 트레이스(OTel + Tempo)와 Istio를 도입하고 같은 실험을 다시 돌린다. 모든 구성은 `up.sh` 한 번으로 재현되고 결과는 S3와 문서로 남는다.

**Tech Stack:** EKS, Terraform, Helm, Argo CD, Chaos Mesh, AWS FIS, k6, Prometheus(PrometheusRule, remote write), Grafana, OpenTelemetry Operator, Grafana Tempo, Istio(sidecar)

**Spec:** `docs/superpowers/specs/2026-11-10-v3-john-fault-injection-design.md`

## Global Constraints

- 대상은 `v3-john` 폴더만이다. `v3-wade`, `v3`, 오레곤 운영 서버는 바꾸지 않는다.
- 수정은 인프라와 설정만 한다. 예외는 Judge 저장소의 OTel gem(Task 9, 사용자 수행)뿐이다.
- 값 파일의 `image:`, `sourceRevision:` 줄은 건드리지 않는다(`v3-promote`가 자동 수정).
- 새 도구는 모두 `v3-john/scripts/up.sh`에서 설치하고 `down.sh`에서 정리한다. Helm 차트는 정확한 버전을 고정한다. 버전은 작업 시점 `helm search repo <차트> --versions | head -2`의 최신 안정 버전으로 정하고 `up.sh`에 적는다.
- Spot vCPU 합계는 32를 넘지 않는다(현재 16).
- 실험 결과 저장 위치: `s3://cosmos-db-backup-352635536602/chaos/john/<실험ID>/<UTC 시각>/`
- 모든 Chaos 리소스는 `duration`을 갖고 최대 10분이다.
- 문서는 서술체(~다)로 쓰고, 한글 뒤에 영어 괄호 병기를 하지 않는다.

## Review Focus

- 실험 도중 실행기가 중단(Ctrl-C, 네트워크 끊김)되면 Chaos 리소스가 남아 장애가 계속된다. 실행기는 `trap`으로 모든 Chaos 리소스를 지워야 한다(Task 3 테스트).
- `down.sh` 때 Chaos 리소스의 finalizer가 남으면 네임스페이스 삭제가 멈춘다. 제거 순서는 Chaos 리소스 → Chaos Mesh 차트다(Task 4 테스트).
- default-deny NetworkPolicy가 새 구성 요소의 통신(k6 → core 픽스처, istio sidecar → istiod, Alloy OTLP 수신)을 막는다. 각 Task가 필요한 정책을 함께 추가한다(Task 1, 9, 10 검증 단계).
- core 이미지가 부하 테스트 픽스처를 포함하지 않으면 k6가 토큰을 얻지 못한다. 현재 `cosmos-core` 이미지(소스 `441acef`)에는 `LoadTestFixtureController`가 없다(Task 1 사전 조건).
- Istio sidecar가 Job(ai-migrate)과 CronJob의 종료를 막는다. 해당 워크로드는 sidecar 주입에서 제외한다(Task 10 테스트).

---

## 파일 구조

| 경로 | 책임 |
|---|---|
| `v3-john/chaos/k6/user-journey.js` | 로그인 토큰 확보 → 문제 조회 → 코드 제출 → 결과 조회 |
| `v3-john/chaos/k6/job.yaml` | k6를 `chaos` 네임스페이스 Job으로 실행 |
| `v3-john/chaos/experiments/E1..E6-*.yaml` | Chaos Mesh 실험 정의(E3은 FIS 래퍼 스크립트) |
| `v3-john/chaos/run-experiment.sh` | 주석 기록, k6, 주입, 정리, 결과 S3 업로드 |
| `v3-john/chaos/records/TEMPLATE.md` | 실험 기록 양식 |
| `v3-john/chaos/runbooks/*.md`, `REPORT.md` | 런북, 최종 보고서 |
| `v3-john/gitops/environments/prod/platform/slo-rules.yaml` | 기록 규칙과 burn rate 알림 |
| `v3-john/helm/addons-values/chaos-mesh/values.yaml` 등 | 새 도구 Helm 값 |
| `v3-john/environments/eks/fis.tf`, `tempo.tf` | FIS 템플릿과 IAM, Tempo S3와 IAM |
| `v3-john/tests/*.sh` | 오프라인 검사(렌더링, 규칙 단위 테스트, 실행기 스텁 테스트) |

---

### Task 1: 실험 트래픽 기반 (k6, 픽스처, remote write)

**Files:**
- Create: `v3-john/chaos/k6/user-journey.js`, `v3-john/chaos/k6/job.yaml`, `v3-john/tests/k6_test.sh`
- Modify: `v3-john/helm/addons-values/monitoring/kube-prometheus-stack.yaml` (`prometheus.prometheusSpec.enableRemoteWriteReceiver: true`)
- Modify: `v3-john/gitops/environments/prod/core.yaml` (env `LOADTEST_FIXTURES_ENABLED: "true"`, secret `cosmos/john/loadtest` → `LOADTEST_FIXTURES_SECRET`)
- Modify: `v3-john/environments/eks/main.tf` (`random_password.loadtest`, Secrets Manager `cosmos/john/loadtest`, core-sa 읽기 권한)
- Modify: `v3-john/gitops/environments/prod/platform/network-policies.yaml` (`chaos` 네임스페이스 → core 8080 허용)
- Modify: `v3-john/helm/platform/cosmos-foundation/values.yaml` (`chaos` 네임스페이스 추가)

**Interfaces:**
- Produces: k6 Job 이름 `k6-<실험ID>`, 환경 변수 `EXPERIMENT_ID`, `DURATION`(기본 `12m`), `VUS`(기본 `10`). 지표는 `k6_*`로 Prometheus에 들어가고 `testid=<실험ID>` 태그를 갖는다.
- Produces: 시나리오 태그 `step`(login, problem, submit, result). 채점 처리 시간은 `k6_judge_turnaround_seconds` 추세 지표로 낸다.

- [ ] **Step 1: 사전 조건 확인.** `v3-john/gitops/environments/prod/core.yaml`의 이미지 소스가 BE `main`의 `LoadTestFixtureController` 포함 커밋 이후인지 확인한다. 아니면 `v3-promote`로 승격하거나 사용자에게 승격을 요청하고 이 Task를 멈춘다.
- [ ] **Step 2: 실패하는 테스트 작성.** `tests/k6_test.sh`: `k6 inspect chaos/k6/user-journey.js`가 성공하고, 출력에 `"step"` 태그 네 종류와 `k6_judge_turnaround_seconds`가 있어야 한다. `helm template`으로 core를 렌더링했을 때 `LOADTEST_FIXTURES_ENABLED`가 있어야 한다.
- [ ] **Step 3: 테스트 실패 확인.** `bash v3-john/tests/k6_test.sh` → 파일 없음으로 실패.
- [ ] **Step 4: 구현.** 토큰은 `setup()`에서 `POST http://core-service.prod/api/internal/load-test/battle/users`(헤더 `X-Load-Test-Secret`)로 받고, 사용자 요청은 `https://john.cosmoscode.site/api`로 보낸다(쿠키 `accessToken`). 문제 ID와 제출 코드는 `__ENV.PROBLEM_ID`(기본 `1`)와 파일 상단 상수로 둔다. Job은 `grafana/k6` 이미지에 `--out experimental-prometheus-rw`, `K6_PROMETHEUS_RW_SERVER_URL=http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/write`, `K6_PROMETHEUS_RW_TREND_STATS=p(95),p(99)`를 쓴다.
- [ ] **Step 5: 테스트 통과 확인.** `bash v3-john/tests/k6_test.sh` → PASS.
- [ ] **Step 6: 클러스터 검증.** `up.sh` 후 `kubectl apply -f chaos/k6/job.yaml`(EXPERIMENT_ID=smoke, DURATION=2m) → Job 성공, Prometheus에서 `k6_http_reqs_total{testid="smoke"}` 값이 0보다 크다.
- [ ] **Step 7: 커밋.** `feat(v3-john): 실험용 k6 사용자 시나리오와 remote write 수신`

### Task 2: SLO 규칙, burn rate 알림, 대시보드

**Files:**
- Create: `v3-john/gitops/environments/prod/platform/slo-rules.yaml`, `v3-john/tests/slo-rules.test.yaml`, `v3-john/tests/slo_test.sh`
- Create: `v3-john/helm/addons-values/monitoring/dashboards/slo-red.json`

**Interfaces:**
- Produces: 기록 규칙 `slo:api_errors:ratio_rate5m`, `..._rate1h`, `..._rate6h`, `slo:submission_latency:p95_5m`.
- Produces: 알림 `ApiErrorBudgetBurnFast`(5m 그리고 1h 비율 > 14.4 × 0.005), `ApiErrorBudgetBurnPage`(1h, 14.4배), `ApiErrorBudgetBurnTicket`(6h, 6배), `SubmissionLatencyHigh`(p95 > 1s, 5분). 레이블 `slo="api-availability"` 등.

- [ ] **Step 1: 실패하는 테스트 작성.** `slo-rules.test.yaml`(promtool 단위 테스트): Envoy 지표 `envoy_cluster_upstream_rq_xx{envoy_response_code_class="5"}`가 전체의 10%인 시계열을 10분 주면 `ApiErrorBudgetBurnFast`가 발생하고, 0.1%면 발생하지 않는다. 지연 히스토그램 p95 1.5초면 `SubmissionLatencyHigh`가 발생한다.
- [ ] **Step 2: 테스트 실패 확인.** `bash v3-john/tests/slo_test.sh`(PrometheusRule에서 `spec`만 추출해 `promtool test rules`) → 규칙 없음으로 실패.
- [ ] **Step 3: 구현.** 분모와 분자는 Envoy Gateway가 내보내는 `/api` 라우트 지표로 계산한다. 실제 지표 이름과 레이블은 Step 1 전에 `up.sh` 클러스터에서 `envoy_cluster_upstream_rq` 계열을 조회해 확정하고 테스트와 규칙에 같은 이름을 쓴다. 대시보드는 서비스별 RED 패널, SLO 남은 예산, `k6_*` 사용자 지표, 실험 주석(Grafana annotation 태그 `chaos`)을 포함한다.
- [ ] **Step 4: 테스트 통과 확인.** `bash v3-john/tests/slo_test.sh` → `SUCCESS`.
- [ ] **Step 5: 클러스터 검증.** Argo CD `prod-platform` Sync 후 `kubectl get prometheusrule -n prod slo-rules`가 있고 Prometheus Rules 화면에 오류가 없다.
- [ ] **Step 6: 커밋.** `feat(v3-john): API 가용성과 제출 지연 SLO, burn rate 알림`

### Task 3: 실험 실행기와 기록 양식

**Files:**
- Create: `v3-john/chaos/run-experiment.sh`, `v3-john/chaos/records/TEMPLATE.md`, `v3-john/tests/run_experiment_test.sh`

**Interfaces:**
- Consumes: Task 1 k6 Job, Task 2 대시보드 주석 태그 `chaos`.
- Produces: `run-experiment.sh <실험ID> [--baseline]`. 순서: Grafana 주석(start) → k6 Job 시작 → 2분 대기(정상 구간) → 주입(`chaos/experiments/<ID>-*.yaml` 적용 또는 `<ID>-*.sh` 실행) → 주입 `duration` 대기 → 정리 → 3분 회복 구간 → 주석(end) → 결과 수집. `--baseline`은 주입을 건너뛴다.
- Produces: 결과 파일 `summary.json`(시작·주입·종료 시각, k6 실패율, p95, 알림 발생 시각 목록)과 Grafana 패널 PNG를 S3 경로에 올린다.

- [ ] **Step 1: 실패하는 테스트 작성.** `run_experiment_test.sh`는 PATH 앞에 `kubectl`, `curl`, `aws` 스텁을 두고 실행한다. 확인할 것: (a) 정상 실행 시 `kubectl apply`가 실험 파일로 한 번, `kubectl delete`가 같은 파일로 한 번 호출된다. (b) 주입 대기 중 SIGINT를 보내면 종료 코드가 0이 아니고 `kubectl delete`가 호출된다. (c) `--baseline`이면 apply가 호출되지 않는다. (d) `aws s3 cp`의 목적지가 `s3://cosmos-db-backup-352635536602/chaos/john/E1/`로 시작한다.
- [ ] **Step 2: 테스트 실패 확인.** `bash v3-john/tests/run_experiment_test.sh` → 실패.
- [ ] **Step 3: 구현.** Grafana 주소와 계정은 `kubectl port-forward`와 Secret `grafana-admin`으로 얻는다. 알림 발생 시각은 Alertmanager API(`/api/v2/alerts`)에서 실험 구간에 시작된 알림을 모은다. 정리는 `trap cleanup EXIT INT TERM`으로 보장한다.
- [ ] **Step 4: 테스트 통과 확인.** → PASS.
- [ ] **Step 5: 기록 양식 작성.** `TEMPLATE.md` 항목: 가설, 주입, 영향 범위, 중단 조건, 탐지 시간, 원인 파악 시간, 복구 시간, 사용자 영향, 대응 타임라인, 발견한 약점, 조치, 재실험 결과, 근거 화면.
- [ ] **Step 6: 커밋.** `feat(v3-john): 장애 주입 실험 실행기와 기록 양식`

### Task 4: Chaos Mesh 설치와 정리

**Files:**
- Create: `v3-john/helm/addons-values/chaos-mesh/values.yaml`, `v3-john/tests/chaos_mesh_test.sh`
- Modify: `v3-john/scripts/up.sh`, `v3-john/scripts/down.sh`

**Interfaces:**
- Produces: 네임스페이스 `chaos-mesh`. 실험 리소스는 `prod` 네임스페이스에 만들고, Chaos Mesh는 `prod`만 대상으로 한다(`controllerManager.enableFilterNamespace: true`, `prod`에 `chaos-mesh.org/inject=enabled`).

- [ ] **Step 1: 실패하는 테스트 작성.** `chaos_mesh_test.sh`: `helm template chaos-mesh/chaos-mesh --version <고정 버전> -f values.yaml` 결과에 `/run/containerd/containerd.sock`이 있고, chaos-daemon에 `nodeSelector`가 없다(모든 노드 대상). `down.sh`에서 Chaos 리소스 삭제(`kubectl delete podchaos,networkchaos,stresschaos --all -A`) 줄이 `helm uninstall chaos-mesh`보다 앞에 있다.
- [ ] **Step 2: 테스트 실패 확인.** → 실패.
- [ ] **Step 3: 구현.** 값: `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath: /run/containerd/containerd.sock`, controller와 dashboard는 `workload-class: system` 노드. dashboard는 외부 노출 없이 port-forward로만 쓴다. `up.sh`에서 kube-prometheus-stack 설치 뒤, Argo CD 앱 Sync 전에 설치한다.
- [ ] **Step 4: 테스트 통과 확인.** → PASS.
- [ ] **Step 5: 클러스터 검증.** `up.sh` 후 `kubectl get crd podchaos.chaos-mesh.org`가 있고, chaos-daemon 파드 수가 노드 수와 같다. `down.sh`가 멈추지 않고 끝난다.
- [ ] **Step 6: 커밋.** `feat(v3-john): Chaos Mesh 설치와 정리 순서`

### Task 5: FIS Spot 회수 실험 템플릿

**Files:**
- Create: `v3-john/environments/eks/fis.tf`
- Modify: `v3-john/environments/eks/outputs.tf` (`fis_spot_template_id`)

**Interfaces:**
- Produces: FIS 실험 템플릿 1개. 액션 `aws:ec2:send-spot-instance-interruptions`, `durationBeforeInterruption = "PT2M"`, 대상은 태그 `eks:nodegroup-name`이 application 노드 그룹 이름인 실행 중 인스턴스 1대(`COUNT(1)`), 중단 조건 `none`. IAM 역할 `cosmos-v3-john-fis`(대상 인스턴스에 `ec2:SendSpotInstanceInterruptions`, `ec2:DescribeInstances`).

- [ ] **Step 1: 검증 기준 작성.** `terraform -chdir=v3-john/environments/eks validate`가 통과하고, `plan`에 `aws_fis_experiment_template`, `aws_iam_role` 각 1개 추가만 있어야 한다(기존 리소스 변경 0).
- [ ] **Step 2: 구현.** 노드 그룹 이름은 `module.eks`의 출력을 쓴다. 출력이 없으면 `modules/eks/outputs.tf`에 `node_group_names` 맵을 추가한다.
- [ ] **Step 3: 검증.** validate 통과, plan 결과가 Step 1 기준과 같다.
- [ ] **Step 4: 커밋.** `feat(v3-john): FIS Spot 회수 실험 템플릿`

### Task 6: 실험 정의 E1~E6

**Files:**
- Create: `v3-john/chaos/experiments/E1-core-pod-kill.yaml`, `E2-judge-worker-kill.yaml`, `E3-spot-interruption.sh`, `E4-core-to-ai-delay.yaml`, `E5-judge-postgres-delay.yaml`, `E6-core-to-rds-partition.yaml`
- Create: `v3-john/tests/experiments_test.sh`

**Interfaces:**
- Consumes: Task 3 실행기 규칙(파일명 `<ID>-*.yaml|sh`), Task 5 출력 `fis_spot_template_id`.

| 파일 | 종류와 주요 값 |
|---|---|
| E1 | PodChaos `pod-kill`, `app.kubernetes.io/name: cosmos-core`, mode `all`, duration `30s` |
| E2 | PodChaos `pod-kill`, `cosmos-judge-worker`, mode `all`, duration `60s` |
| E3 | `aws fis start-experiment --experiment-template-id $(terraform output -raw fis_spot_template_id)`, 완료까지 대기 |
| E4 | NetworkChaos `delay` 3s, 출발 `cosmos-core`, 목적지 `cosmos-ai-llm` 파드, direction `to`, duration `5m` |
| E5 | NetworkChaos `delay` 500ms, jitter 50ms, 출발 `cosmos-judge-api`·`cosmos-judge-worker`, 목적지 `judge-postgres` 파드, duration `5m` |
| E6 | NetworkChaos `partition`, 출발 `cosmos-core`, externalTargets RDS 엔드포인트(실행기가 `terraform output -raw mysql_address`로 치환), duration `60s` |

- [ ] **Step 1: 실패하는 테스트 작성.** `experiments_test.sh`: 모든 yaml이 파싱되고 `metadata.namespace: prod`, `spec.duration`이 10분 이하이며, E1~E6 파일이 모두 있다.
- [ ] **Step 2: 테스트 실패 확인.** → 실패.
- [ ] **Step 3: 구현.**
- [ ] **Step 4: 테스트 통과 확인.** → PASS.
- [ ] **Step 5: 클러스터 검증.** 각 yaml에 `kubectl apply --dry-run=server`가 성공한다.
- [ ] **Step 6: 커밋.** `feat(v3-john): 장애 주입 실험 E1~E6 정의`

### Task 7: 기준선 측정과 1단계 실험 실행

이 Task는 코드가 아니라 실험 실행과 기록이다. 결과가 Task 8~10의 진행 여부를 정한다.

**Files:**
- Create: `v3-john/chaos/records/BASELINE-<날짜>.md`, `v3-john/chaos/records/E1..E6-<날짜>.md`

- [ ] **Step 1: 기준선.** `run-experiment.sh BASELINE --baseline`을 3회 실행하고 가용성, 제출 p95, 채점 처리 p95, 서비스 구간별 p99(core → ai-llm, core → judge-api)의 평균을 기록한다.
- [ ] **Step 2: E1~E6 실행.** 실험마다 대응자가 알림을 받은 순간부터 원인을 확정할 때까지 지표와 로그만으로 진단하고, 원인 파악 시간과 막힌 지점을 기록한다.
- [ ] **Step 3: 결정 기록.** 각 기록 끝에 설계 문서 4절 조건 판정을 적는다. E5 원인 파악 시간 10분 초과 → Task 9 진행. E4에서 직접 장애가 아닌 서비스(로그인, 제출)의 SLO 위반 → Task 10 진행. 넘지 못한 조건은 해당 Task를 "미도입"으로 기록하고 건너뛴다.
- [ ] **Step 4: 커밋.** `docs(v3-john): 기준선과 1단계 실험 기록`

### Task 8: 1단계 개선 (가용성 설정)

**Files:**
- Create: `v3-john/gitops/charts/cosmos-app/templates/pdb.yaml`, `v3-john/tests/chart_test.sh`
- Modify: `v3-john/gitops/charts/cosmos-app/values.yaml` (`pdb: { enabled: false, minAvailable: 1 }`, `topologySpread: false`)
- Modify: `v3-john/gitops/charts/cosmos-app/templates/_pod.tpl` (`topologySpread`가 true면 `kubernetes.io/hostname`, `topology.kubernetes.io/zone` 기준 `maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`)
- Modify: `core.yaml`, `auth.yaml`, `battle.yaml`, `judge-api.yaml` (`hpa.min: 2`, `pdb.enabled: true`, `topologySpread: true`)
- Modify: `v3-john/modules/eks/variables.tf` (application 노드 그룹 `max_size = 3`)

E1, E3 결과가 가설대로였다면(약점 없음) 이 Task는 해당 항목만 건너뛰고 근거를 기록에 남긴다.

- [ ] **Step 1: 실패하는 테스트 작성.** `chart_test.sh`: core 값으로 렌더링하면 `PodDisruptionBudget`(`minAvailable: 1`)과 `topologySpreadConstraints` 두 개가 나오고, 기본 값(mlflow)으로는 둘 다 없다.
- [ ] **Step 2: 테스트 실패 확인.** → 실패.
- [ ] **Step 3: 구현.**
- [ ] **Step 4: 테스트 통과 확인.** → PASS. `.github/workflows/gitops-ci.yml`과 같은 명령(`helm lint`, `helm template`)으로 모든 값 파일이 통과한다.
- [ ] **Step 5: 재실험.** E1, E3을 다시 실행하고 기록에 전후 비교(가용성, 복구 시간, k6 실패율)를 적는다. application 노드 3대 기준 Spot vCPU 합계가 20인지 확인한다.
- [ ] **Step 6: 커밋.** `feat(v3-john): 주요 API 최소 2개, PDB, topology spread 적용`

### Task 9: 2a 트레이스 (OTel + Tempo) — Task 7 조건 충족 시

**Files:**
- Create: `v3-john/environments/eks/tempo.tf` (S3 버킷 `cosmos-v3-john-tempo-352635536602`, 수명 주기 14일, Pod Identity로 `monitoring/tempo` 쓰기 권한, `down.sh`에서 버킷 비움)
- Create: `v3-john/helm/addons-values/monitoring/tempo.yaml`, `v3-john/helm/addons-values/otel-operator/values.yaml`, `v3-john/gitops/environments/prod/platform/instrumentation.yaml`
- Modify: `v3-john/helm/addons-values/monitoring/alloy.yaml` (`otelcol.receiver.otlp` gRPC 4317 → `otelcol.exporter.otlp` Tempo), `kube-prometheus-stack.yaml` (Tempo 데이터소스, traces-to-logs Loki 연결, exemplar 활성화)
- Modify: `v3-john/gitops/charts/cosmos-app/values.yaml`·`_pod.tpl` (`podAnnotations: {}` 추가)
- Modify: `core.yaml`, `auth.yaml`, `battle.yaml`(`instrumentation.opentelemetry.io/inject-java: "prod/cosmos"`), `ai-llm.yaml`, `ai-make-problem.yaml`, `ai-problem-batch.yaml`(`inject-python`), `judge-api.yaml`, `judge-worker.yaml`(env `OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy.monitoring:4318`, `OTEL_SERVICE_NAME`, worker만 `OTEL_JUDGE_SPAN_PROCESSOR=simple`. Ruby 내보내기는 OTLP/HTTP만 지원한다)
- Modify: `network-policies.yaml` (prod → `monitoring` Alloy 4317, 4318 허용)
- Modify: `up.sh`, `down.sh`

**Interfaces:**
- Produces: Instrumentation 리소스 `prod/cosmos`(샘플링 `parentbased_traceidratio` 0.1, 에러 요청은 Alloy tail sampling으로 100% 보존).
- Judge 저장소 브랜치 `feat/opentelemetry`: Ruby 2.7 호환 버전(sdk 1.2.1)의 Rails, PG, Redis, Resque 계측과 `config/initializers/opentelemetry.rb`. 엔드포인트가 없으면 꺼진다. Alloy는 OTLP HTTP 4318 수신을 켜야 한다.

- [ ] **Step 1: 실패하는 테스트 작성.** `chart_test.sh`에 추가: core 렌더링 결과 파드에 `inject-java` 주석이 있다. OTel Operator 값 렌더링에 `admissionWebhooks.certManager.enabled: false`, `autoGenerateCert.enabled: true`가 있다(cert-manager 없이 동작).
- [ ] **Step 2: 테스트 실패 확인.** → 실패.
- [ ] **Step 3: 구현.** 설치 순서는 Tempo → OTel Operator → Instrumentation(Argo CD platform) → 앱 Sync다. 주석이 있는 파드는 재시작해야 주입된다.
- [ ] **Step 4: 테스트 통과 확인.** → PASS.
- [ ] **Step 5: 클러스터 검증.** k6 smoke 실행 후 Grafana Tempo에서 `{ resource.service.name = "cosmos-core" }` 트레이스가 조회되고, core → judge-api span이 한 트레이스로 이어진다. Judge gem이 아직 없으면 judge 구간이 끊긴 것을 기록한다.
- [ ] **Step 6: 재실험.** E5를 다시 실행해 원인 파악 시간을 비교하고, 설계 대안 비교표(요청 ID 로그, Istio 지표만, X-Ray, Jaeger, OTel + Tempo)를 기록에 붙인다.
- [ ] **Step 7: 커밋.** `feat(v3-john): OTel 자동 계측과 Tempo 트레이스`

### Task 10: 2b Istio 회복 정책 — Task 7 조건 충족 시

**Files:**
- Create: `v3-john/helm/addons-values/istio/istiod.yaml`, `v3-john/gitops/environments/prod/platform/istio-resilience.yaml`, `v3-john/tests/istio_test.sh`
- Modify: `v3-john/helm/platform/cosmos-foundation/templates/namespaces.yaml` (`prod`에 `istio-injection: enabled`)
- Modify: `judge-worker.yaml`, `judge-postgres.yaml`, `judge-redis.yaml`, `ai-postgres.yaml`, `mlflow.yaml`, `ai-migrate.yaml` (`podAnnotations: { sidecar.istio.io/inject: "false" }`)
- Modify: `network-policies.yaml` (prod → `istio-system` 15012, 15017 허용, Prometheus → 15020 허용)
- Modify: `up.sh` (istio `base`, `istiod` 설치. Argo CD 앱 Sync 전)

**Interfaces:**
- Consumes: Task 7 기준선의 구간별 p99.
- Produces: `istio-resilience.yaml`에 `ai-llm-service`, `judge-api-service`별 VirtualService(타임아웃 = 기준선 p99 × 2를 초 단위로 올림, 재시도 `attempts: 2`, `retryOn: connect-failure,refused-stream,503`)와 DestinationRule(`connectionPool.http.http1MaxPendingRequests: 20`, `outlierDetection: { consecutive5xxErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50 }`).

- [ ] **Step 1: 실패하는 테스트 작성.** `istio_test.sh`: `istio-resilience.yaml`에 두 서비스의 VirtualService와 DestinationRule이 모두 있고 타임아웃 값이 비어 있지 않다. 제외 대상 6개 값 파일 렌더링 결과에 `sidecar.istio.io/inject: "false"`가 있다.
- [ ] **Step 2: 테스트 실패 확인.** → 실패.
- [ ] **Step 3: 구현.** 타임아웃 계산값과 근거(기준선 p99)를 파일 주석에 남긴다.
- [ ] **Step 4: 테스트 통과 확인.** → PASS.
- [ ] **Step 5: 클러스터 검증.** core, auth, battle, ai-llm, judge-api 파드가 `2/2`이고, 제외 대상은 `1/1`이며, ai-migrate Job이 완료된다. `istioctl analyze -n prod` 오류 0건.
- [ ] **Step 6: 재실험.** E4, E5를 다시 실행하고 로그인, 제출 SLO와 k6 실패율을 1단계와 비교한다. Kiali는 설치하지 않고 Tempo 서비스 그래프와 Istio 지표 대시보드로 확인한다.
- [ ] **Step 7: 커밋.** `feat(v3-john): Istio sidecar와 서비스 구간 회복 정책`

### Task 11: 런북, 포스트모템, 최종 보고서

**Files:**
- Create: `v3-john/chaos/runbooks/pod-failure.md`, `node-interruption.md`, `dependency-latency.md`, `dependency-outage.md`
- Create: `v3-john/chaos/REPORT.md`

- [ ] **Step 1: 런북 작성.** 각 런북은 탐지 신호(알림 이름), 확인 쿼리(PromQL, LogQL, TraceQL), 조치, 복구 확인으로 구성하고, Task 7~10 기록에서 실제로 쓴 쿼리만 넣는다.
- [ ] **Step 2: 보고서 작성.** 실험별 전후 비교표(가용성, 탐지·원인 파악·복구 시간, k6 실패율), 도구 도입 근거와 대안 비교, 미도입 결정과 이유, 앱 코드 개선 제안 목록, 근거 화면 링크(S3).
- [ ] **Step 3: 확인.** 보고서의 모든 수치가 `records/`의 기록과 S3 `summary.json`에 있는 값인지 대조한다.
- [ ] **Step 4: 커밋.** `docs(v3-john): 장애 대응 런북과 실험 보고서`
