# 런북: 스팟 노드 회수(S2)

application 노드 그룹의 스팟 인스턴스가 회수될 때 쓴다. S2 실험(2026-11-23)에서 확인한 순서다. 모든 노드 그룹이 스팟이다.

## 1. 탐지 신호

| 신호 | 의미 | S2에서 본 것 |
|---|---|---|
| `JudgeJobLost`(SEV1) | core나 judge-api가 사라져 제출이 결과 없이 끝남 | 개선 전 회수 알림 후 120초. 이중화 뒤에는 울리지 않음 |
| `NodeNotReady` | 노드 NotReady 1분 지속 | 울리지 않았다. 회수된 노드는 NotReady 34초 만에 목록에서 사라진다 |
| `PodsPending` | 파드 Pending 2분 지속 | 울리지 않았다(Pending 최대 9개, 2분 안에 해소) |
| 노드 그룹 이벤트 | 관리형 노드 그룹이 대체 노드를 먼저 띄움 | 회수 알림 후 약 40초에 대체 노드 |

스팟 회수 2분 전 알림 자체를 받는 경로(EventBridge `EC2 Spot Instance Interruption Warning`)는 아직 없다(S2 단계 4, 선택).

## 2. 확인

```bash
# 노드 상태와 AZ, 유형. 새 노드가 떴는지, 옛 노드가 SchedulingDisabled(비우는 중)인지 본다
kubectl get nodes -l workload-class=application -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type,eks.amazonaws.com/capacityType
# 핵심 서비스 파드가 어느 노드에 몇 개 남았는지(한 노드에 몰렸는지)
kubectl get pods -n prod -o wide -l 'app.kubernetes.io/name in (cosmos-core,cosmos-auth,cosmos-battle,cosmos-judge-api)'
# Pending 이유(자리 부족, 노드 그룹 최대 도달)
kubectl get pods -A --field-selector status.phase=Pending
kubectl get events -A --field-selector reason=NotTriggerScaleUp --sort-by=.lastTimestamp | tail
# 노드 그룹 활동(대체 노드 실패, 스팟 용량 부족)
aws autoscaling describe-scaling-activities --region ap-northeast-2 --auto-scaling-group-name <application ASG> --max-items 5
```

## 3. 완화

- **레플리카가 하나뿐인 서비스가 사라졌다**: 노드 그룹이 대체 노드를 띄우고 파드가 다시 뜰 때까지 기다린다. Spring 기동은 에이전트 포함 약 90초다. 수동으로 할 일은 거의 없다
- **대체 노드가 뜨지 않는다(스팟 용량 부족)**: 노드 그룹 이벤트로 확인한다. 한도 증가는 요청하지 않는다. 임시로 노드 그룹 `capacity_type`을 `ON_DEMAND`로 바꾸는 PR을 낸다(variables.tf 주석). 우선순위 클래스(`cosmos-core-journey`)가 핵심 기능을 먼저 앉힌다
- **Pending이 오래간다(노드 그룹 최대 3대 도달)**: 낮은 우선순위 파드(배치, mlflow)를 잠시 줄인다. 노드 최대를 늘리면 Spot vCPU 실험 중단 기준(28)과 계정 한도(32)를 함께 본다

## 4. 복구 확인

- application 노드가 원래 수(평상시 2~3대)로 돌아와 Ready
- core, auth, battle이 각 2개 이상 Ready이고 **서로 다른 노드**에 있다. 한 노드에 몰려 있으면 다음 회수 때 같은 서비스가 함께 사라진다
  ```bash
  kubectl rollout restart deployment/cosmos-auth deployment/cosmos-battle -n prod
  kubectl patch rollout cosmos-core -n prod --type merge -p "{\"spec\":{\"restartAt\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  ```
  노드 분산은 `ScheduleAnyway`라 노드가 늘어도 이미 뜬 파드를 다시 나누지 않는다(노드 그룹 교체 뒤 6개가 한 노드에 몰린 적이 있다)
- Prometheus, Alertmanager가 회수된 노드에 있었다면 다시 떴는지 확인한다(PV가 AZ a에 있어 a 노드에만 뜬다)
- 핵심 오류율 0.005 아래, `JudgeJobLost` 해소

## 5. 남은 위험

- judge-api는 레플리카 1이다. 회수 노드에 있으면 채점이 약 2분 30초 동안 유실된다(개선 전 유실 57건 대부분)
- Prometheus, Alertmanager, Tempo도 application 노드에 있고 하나씩이다. core와 같은 노드에 있으면 탐지 수단도 함께 사라진다
- stateful 노드(클러스터 안 DB 셋)는 1대이고 스팟이다. 이 런북 범위 밖이며 회수되면 해당 DB가 노드 복귀까지 내려간다
