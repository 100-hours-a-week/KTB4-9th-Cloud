# 런북: 상태 저장 노드 회수·장애(S2' B)

상태 저장 노드(`workload-class=stateful`)가 사라지면 ai-postgres, judge-postgres, judge-redis-queue, rabbitmq가 함께 멈춘다. 모두 레플리카 1이고 EBS 볼륨을 쓴다.

## 1. 탐지

- `JudgeJobLost`, 제출 경로 `ServiceErrorHigh`(채점 대기열·채점 DB), AI 경로 오류
- `kube_pod_status_ready{namespace="prod", pod=~"(ai-postgres|judge-postgres|judge-redis-queue|rabbitmq)-0"} == 0`
- ASG 활동에 "Spot Instance interruption notice"

## 2. 확인

```bash
kubectl get nodes -l workload-class=stateful -L topology.kubernetes.io/zone
kubectl get pods -n prod -o wide | grep -E "postgres|redis|rabbit"
# 볼륨 존
kubectl get pv $(kubectl get pvc data-judge-postgres-0 -n prod -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values}'
kubectl describe pod judge-postgres-0 -n prod | grep -A3 Events   # "volume node affinity conflict"면 존 불일치
```

## 3. 완화

- 대체 노드가 뜨는 중이면 기다린다(보통 3~5분)
- 대체 노드가 볼륨과 다른 존이면 파드는 영영 뜨지 못한다. 그 노드를 원하는 용량을 줄이지 않고 교체해 ASG가 다시 띄우게 한다(다른 존이 다시 나올 수 있어 반복이 필요할 수 있다)

```bash
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id <다른 존 노드 인스턴스> --no-should-decrement-desired-capacity
```

- 근본 대책(2차 S2' B 단계): 노드 그룹 서브넷을 볼륨 존 하나로 고정하고(Terraform `subnet_keys`), 상태 저장 StorageClass에 같은 존을 `allowedTopologies`로 고정한다. 회수 자체를 없애려면 온디맨드로 바꾼다(결정 기록 `decisions/s2b-step*.md`)

## 4. 복구 확인

- 네 파드 Ready, 제출·채점 정상, `JudgeJobLost` 해소
- RabbitMQ 큐와 Redis 대기열 길이가 줄어드는지(밀린 작업 처리)
