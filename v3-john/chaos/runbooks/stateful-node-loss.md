# 런북: 상태 저장 노드 교체·장애(DB·큐 이동)

상태 저장 노드(`workload-class=stateful`)에는 judge-postgres, judge-redis-queue(채점 대기열), rabbitmq, ai-postgres가 레플리카 1로 떠 있다. 노드가 바뀌면(AMI 패치, EKS 업그레이드, EC2 점검·장애) 네 파드가 새 노드로 옮겨 가며 약 50초 끊긴다(2026-11-24 실측).

이때 채점 워커가 Redis 끊김을 넘기지 못하면 채점이 따라잡지 못해 제출이 실패한다. 실측: 인프라 복구 50초, 제출 실패 2분 30초~2분 45초, 회당 150건 넘게 실패. 한 번은 스스로 회복하지 못해 사람이 채점 파드를 재시작할 때까지 이어졌다(2026-11-24 19:44~20:31).

## 1. 탐지

- `JudgePathDegraded`(SEV2): 제출 경로 실패율 5% 초과 1분. 이 런북으로 온다
- `ServiceErrorHigh`, `JudgeJobLost`
- 대시보드 `COSMOS / 장애 대응 / DB 교체 후 채점`

## 2. 확인(순서대로)

```bash
# 상태 저장 파드 4개가 Ready인가
kubectl get pods -n prod -o wide | grep -E "postgres|redis|rabbit"
# 채점 워커가 살아 있고 재시작이 있었나
kubectl get pods -n prod -l app.kubernetes.io/name=cosmos-judge-worker
# 워커 로그에 Redis 연결 오류와 프로세스 종료가 있나
kubectl logs -n prod deploy/cosmos-judge-worker --since=10m | grep -E "CannotConnectError|rake aborted|Starting workers"
```

- 상태 저장 파드가 아직 뜨는 중이면 기다린다(약 1분)
- 상태 저장 파드는 모두 Ready인데 3분 넘게 제출 실패가 이어지면 채점 쪽 고장이다

## 3. 완화

- 생존 검사(livenessProbe)가 채점 워커를 자동 재시작한다(등록된 채점 프로세스 없음 또는 대기열이 있는데 90초 동안 처리 0)
- 자동 재시작이 일어나지 않고 실패가 이어지면 직접 재시작한다

```bash
kubectl rollout restart deployment/cosmos-judge-worker deployment/cosmos-judge-api -n prod
```

## 4. 계획 교체 절차(점검·업그레이드 때)

1. 부하가 적은 시간을 고른다
2. 채점 워커가 2대 이상 Ready인지 확인한다(KEDA 최소 2)
3. 새 상태 저장 노드를 먼저 띄우고 옛 노드를 drain한다(관리형 노드 그룹 업데이트가 같은 순서로 한다)
4. 네 파드 Ready 뒤 대시보드에서 제출 성공률이 3분 안에 돌아오는지 본다. 아니면 3번 완화

## 5. 복구 확인

- 제출 성공률 정상, `JudgePathDegraded` 해소, 대기열 길이 감소
