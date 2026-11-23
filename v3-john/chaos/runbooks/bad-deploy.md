# 런북: 잘못된 배포(S1)

core, auth, battle 같은 앱의 값 파일 변경이나 이미지 변경 뒤 서비스가 나빠질 때 쓴다. S1 실험(2026-11-20, 11-23)에서 확인한 순서다.

## 1. 탐지 신호

| 알림 | 의미 | S1에서 본 시점 |
|---|---|---|
| `JudgeJobLost`(SEV1) | 제출이 채점 결과 없이 끝남. core가 죽으면 가장 먼저 울린다 | 주입 후 90~360초 |
| `PodCrashLooping` | 컨테이너가 반복 재시작 | OOMKilled 뒤 약 75초. 증상 알림보다 늦을 수 있다 |
| `CoreErrorBudgetBurnFast` | 핵심 기능 오류율이 14.4배로 소진 | 전면 장애일 때만 |
| `CoreUnavailable` | 5분 평균 성공률 50% 미만 | S1에서는 한 번도 울리지 않았다(재시작이 짧아 평균에 묻힘) |
| Argo Rollouts `RolloutAborted` | 카나리 분석 실패로 자동 중단(단계 4 이후) | 주입 후 93초 |

## 2. 확인

먼저 최근 배포를 본다. 배포 직후의 장애는 대부분 그 배포가 원인이다.

```bash
# 최근 동기화 이력(리비전, 시각)
kubectl get application prod-core -n argocd -o jsonpath='{range .status.history[-3:]}{.revision} {.deployedAt}{"\n"}{end}'
# 파드 상태: 재시작 수와 마지막 종료 이유(OOMKilled 여부)
kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-core -o jsonpath='{range .items[*]}{.metadata.name} {.spec.containers[0].resources.limits.memory} r={.status.containerStatuses[0].restartCount} {.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
# 카나리 상태(단계 4 이후)
kubectl get rollout cosmos-core -n prod -o jsonpath='{.status.phase} {.status.message}{"\n"}'
```

PromQL(Grafana Explore → Prometheus v2):

```promql
cosmos:journey_error_ratio:rate5m{journey="core"}
sum(increase(kube_pod_container_status_restarts_total{namespace="prod",pod=~"cosmos-core-.*"}[5m]))
max by (pod) (container_memory_working_set_bytes{namespace="prod",pod=~"cosmos-core-.*",container="cosmos-core"})
```

Tempo(Explore → Tempo John):

- Search에서 Service Name `cosmos-core`, Status `error`로 실패한 요청을 본다
- 메모리로 죽는 파드는 스팬을 보내기 전에 강제 종료되어 트레이스에 나오지 않는다. "새 버전 파드 스팬이 없다"는 것도 신호다
- 트레이스로는 영향 범위(어느 경로가 실패하는지)를 보고, 원인은 파드 상태와 배포 이력으로 정한다

## 3. 완화

원인을 끝까지 찾기 전에 되돌린다. S1에서 되돌림은 30초 안에 시작할 수 있었다.

1. **되돌리는 PR**(기본): 문제 커밋을 되돌리는 PR을 main에 병합한다. Argo CD 자동 동기화가 배포한다
   ```bash
   git revert <문제 커밋> && git push origin HEAD:revert/<이름>   # PR 생성 후 병합
   ```
2. **Rollout 중단**(단계 4 이후): 분석이 아직 끝나지 않았다면 바로 중단해 안정 버전만 남긴다
   ```bash
   kubectl argo rollouts abort cosmos-core -n prod   # 플러그인이 없으면: kubectl patch rollout cosmos-core -n prod --type merge -p '{"status":{"abort":true}}' --subresource status
   ```
   중단한 뒤에도 Git의 값은 문제 버전이다. 1번 되돌리는 PR을 함께 병합해야 다음 동기화 때 다시 시도하지 않는다
3. **Argo CD 롤백**(Git을 바로 고칠 수 없을 때): `argocd app rollback prod-core <이력 ID>`. 자동 동기화가 켜져 있으면 곧 Git 상태로 돌아가므로 임시 조치다

## 4. 복구 확인

- 모든 core 파드가 이전 메모리 한도로 Ready이고 재시작이 늘지 않는다
- `cosmos:journey_error_ratio:rate5m{journey="core"}`가 0.005 아래로 1분 이상 유지된다
- `JudgeJobLost`가 해소된다(k6나 실제 제출로 채점 완료가 다시 생긴다)
- Rollout을 쓰면 `Healthy`, AnalysisRun이 남아 있으면 원인 기록 뒤 지운다

## 5. 예방

- CI 값 검사(`.github/scripts/check-v3-john-values.py`): 한도 < 요청, Spring 힙 비율 누락, 힙 밖 메모리 256Mi 미만을 막는다
- 레플리카 2와 `maxUnavailable: 0`: 새 파드가 준비되지 않으면 옛 파드가 남는다
- 카나리 분석: 재시작 1회나 핵심 오류율 0.072 초과면 자동 중단, 준비 못 하는 카나리는 300초 뒤 자동 중단
