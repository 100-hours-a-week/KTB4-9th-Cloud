# 런북: core DB 연결 풀 고갈(S1')

core의 Hikari 풀이 바닥나 채점과 무관한 경로(문제 조회, major-core)까지 5xx가 날 때 쓴다. 2026-11-24 실제 회수와 사전 측정에서 본 연쇄는 이렇다.

채점 워커 중단(노드 회수 등) → 제출 요청이 채점 결과를 기다리며 core DB 연결을 쥠 → core 풀(파드당 10) 가득 → 다른 요청이 연결 획득 제한(3초)에 걸려 5xx

증상이 나는 경로(문제 조회)와 원인(채점 경로)이 다르다. 문제 조회 코드를 먼저 의심하지 않는다.

## 1. 탐지 신호

| 알림 | 의미 | 비고 |
|---|---|---|
| `DbConnectionAcquireFailed`(SEV2) | 어떤 파드가 2분 동안 풀에서 연결을 얻지 못함 | 풀 고갈의 직접 신호. 알림에 나온 파드가 피해 위치다 |
| `RdsConnectionBudgetHigh`(SEV2) | 앱 전체 DB 연결 합이 RDS 최대 연결의 80%를 1분 넘게 유지 | 이 연쇄에서는 보통 울리지 않는다(풀이 작아 RDS까지 가지 않음). 울리면 풀을 키운 변경을 의심한다 |
| `ServiceErrorHigh`, `CoreBurnFastAll` | 경로 오류율, 핵심 예산 소진 | 증상 신호 |
| `JudgeJobLost` | 채점 유실 | 원인 쪽 신호 |

## 2. 확인

순서대로 본다. 1분 안에 원인 쪽(채점)인지 판단하는 것이 목표다.

1. 풀이 바닥났는지

   ```promql
   sum by (pod) (hikaricp_connections_active{namespace="prod"})
   sum by (pod) (hikaricp_connections_pending{namespace="prod"})
   ```

   core 파드의 활성 연결이 최대 풀과 같고 대기가 쌓이면 풀 고갈이다.

2. 무엇이 연결을 쥐고 있는지: 제출 경로 지연

   ```promql
   histogram_quantile(0.95, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/prod/journey-core-submit/.+"}[1m])))
   ```

   제출 p95가 평소(약 2.4초)보다 크게 길면 제출 요청이 연결을 쥐고 있는 것이다.

3. 채점이 멈췄는지

   ```bash
   kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker -o wide
   kubectl get scaledobject cosmos-judge-worker -n prod -o jsonpath='{.metadata.annotations}{"\n"}'
   kubectl get nodes -l eks.amazonaws.com/nodegroup=judge-base-ng
   kubectl get events -A --sort-by=.lastTimestamp | grep -iE "judge|spot|interrupt" | tail
   ```

   워커가 없거나 Pending이면 원인은 채점 경로다. 노드 회수라면 ASG 활동 기록에 "Spot Instance interruption notice"가 남는다.

4. 풀을 키운 변경이 있었는지(`RdsConnectionBudgetHigh`가 울렸을 때)

   ```bash
   git log -S"SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE" --since="3 days ago" --oneline -- v3-john/gitops/environments/prod
   ```

## 3. 완화

채점 워커를 되살리는 것이 근본 완화다. 그 전까지 core 경로를 지키는 조치는 아래 순서로 한다.

1. 채점 워커 복구
   - KEDA 일시 정지 주석이 붙어 있으면 지운다: `kubectl annotate scaledobject cosmos-judge-worker -n prod autoscaling.keda.sh/paused-replicas-`
   - 노드 회수라면 대체 노드가 뜨고 워커가 이미지를 받을 때까지(약 3~5분) 기다린다. Pending 원인이 용량이면 `kubectl describe pod`로 확인한다
2. 워커가 바로 돌아오지 않으면 core 경로를 지킨다
   - 제출 경로 격벽(단계 2 이후 적용된 `BackendTrafficPolicy` 회로 차단기)이 있으면 넘친 제출이 503으로 바로 끝나고 있는지 `envoy_cluster_upstream_rq_pending_overflow`로 본다
   - 격벽이 없는 구성에서 장애가 길어지면, 제출 경로를 막는 것이 문제 조회를 지키는 가장 빠른 방법이다. 이 판단은 사용자 영향(제출 불가)이 크므로 담당자 승인 뒤에 한다
3. core 파드 재시작은 하지 않는다. 연결을 쥔 요청이 사라지는 효과는 잠깐이고, 재시작 중 남은 파드에 부하가 몰린다

## 4. 복구 확인

- core 활성 연결이 최대 풀 아래로 내려오고 대기가 0이 된다
- `DbConnectionAcquireFailed`, `ServiceErrorHigh`가 해소된다
- 채점 워커가 Ready이고 제출 p95가 평소로 돌아온다
- 워커 복귀 직후 밀린 채점이 한꺼번에 풀리며 풀이 다시 차는지 5분 더 본다(사전 측정에서 재발)
