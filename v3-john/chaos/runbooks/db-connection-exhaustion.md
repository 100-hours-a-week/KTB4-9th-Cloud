# 런북: DB 연결 고갈(S1')

여러 서비스의 Hikari 풀 합이 RDS 최대 연결에 가까워져, 풀 값을 올리지 않은 서비스까지 연결을 못 얻을 때 쓴다. 증상이 나는 서비스(예: auth 로그인 실패)와 원인 서비스(예: 풀을 키운 core)가 다를 수 있다.

## 1. 탐지 신호

| 알림 | 의미 | 비고 |
|---|---|---|
| `RdsConnectionBudgetHigh`(SEV2) | 앱 전체 DB 연결 합이 RDS 최대 연결의 80%를 1분 넘게 유지 | 원인 신호. 가장 먼저 본다 |
| `DbConnectionAcquireFailed`(SEV2) | 어떤 파드가 2분 동안 풀에서 연결을 얻지 못함 | 알림에 나온 파드는 피해자일 수 있다 |
| `ServiceErrorHigh`(SEV2) | 서비스 경로 오류율 상승 | 증상 신호. 원인 서비스를 알려 주지 않는다 |

## 2. 확인

연결을 가장 많이 쥔 서비스를 찾는다. 증상이 난 서비스를 먼저 보지 않는다.

PromQL(Grafana Explore → Prometheus v2):

```promql
cosmos:db_connections:sum
sum by (app) (hikaricp_connections{namespace="prod"})
sum by (pod) (increase(hikaricp_connections_timeout_total{namespace="prod"}[5m]))
```

- `cosmos:db_connections:sum`이 RDS 최대 연결에 얼마나 가까운지 본다
- `sum by (app)` 결과에서 가장 큰 서비스가 완화 대상 후보다
- 풀 대기 시간 초과가 나는 서비스는 피해 서비스일 수 있으므로 연결 수와 비교한다

최근에 연결 값을 바꾼 PR을 찾는다.

```bash
git log --since="3 days ago" --oneline -- v3-john/helm/apps | head -20
git log -S"maximum-pool-size" --since="3 days ago" --oneline -- v3-john/helm
# 최근 동기화 이력(리비전, 시각)
kubectl get application prod-core -n argocd -o jsonpath='{range .status.history[-3:]}{.revision} {.deployedAt}{"\n"}{end}'
```

RDS 쪽 전체 연결은 CloudWatch `DatabaseConnections`(RDS 인스턴스, 1분 주기)로 확인한다. 앱 합과 크게 다르면 앱이 아닌 클라이언트가 연결을 쥐고 있는 것이다.

## 3. 완화

연결을 늘린 PR을 되돌린다. 터진 서비스가 아니라 연결을 가장 많이 쥔 서비스부터 되돌린다.

1. 2번의 `sum by (app)`에서 가장 큰 서비스를 정한다
2. 그 서비스의 풀 값을 올린 PR을 되돌리는 PR로 main에 병합한다. Argo CD 자동 동기화가 배포한다
   ```bash
   git revert <풀 값을 올린 커밋> && git push origin HEAD:revert/<이름>   # PR 생성 후 병합
   ```
3. 배포 직후 `sum by (app)` 합이 줄어드는지 본다. 줄지 않으면 다음으로 큰 서비스를 같은 방식으로 확인한다
4. Git을 바로 고칠 수 없으면 `argocd app rollback prod-<서비스> <이력 ID>`로 임시 조치한다. 자동 동기화가 켜져 있으면 곧 Git 상태로 돌아간다

## 4. 복구 확인

- `cosmos:db_connections:sum`이 RDS 최대 연결의 80% 아래로 내려가고 `RdsConnectionBudgetHigh`가 해소된다
- `DbConnectionAcquireFailed`가 더 늘지 않고 해소된다
- `ServiceErrorHigh`가 해소되고 로그인 같은 증상 경로가 정상 응답한다
- CloudWatch `DatabaseConnections`도 같은 방향으로 내려갔다
