# S2 application 스팟 노드 회수

설계서 9.2의 주입이다. AWS FIS `aws:ec2:send-spot-instance-interruptions`로 core 파드가 있는 application 스팟 노드 1대에 회수 2분 전 알림을 보낸다. 2분 뒤 EC2가 인스턴스를 회수하고, 관리형 노드 그룹이 새 노드를 띄운다.

```bash
v3-john/chaos/run-experiment.sh s2 before --inject-after 3m --recover 10m
```

- FIS 역할 `cosmos-v3-john-fis`와 중단 조건 알람 `cosmos-v3-john-fis-stop-application`은 `environments/eks/fis.tf`가 만든다. 역할은 이 클러스터 `application-ng` 태그가 붙은 인스턴스에만 회수 알림을 보낼 수 있다.
- 중단 조건은 application 노드 그룹 InService 0대가 1분 지속되는 것이다. 관리형 노드 그룹 ASG는 그룹 지표를 기본으로 내지 않으므로 Terraform이 `GroupInServiceInstances` 수집을 켠다. `inject.sh`는 알람이 OK가 아니면 시작하지 않는다.
- 실험 템플릿은 실험마다 `inject.sh`가 만들고 `stop.sh`가 지운다. 대상 인스턴스가 실험마다 다르기 때문이다.
- 주입 유지 시간은 420초다(회수 알림 2분 + 설계서 가설의 원래 용량 복귀 5분).
- `stop.sh`는 회수된 노드를 되돌리지 못한다. 남은 실험을 멈추고, application Ready 노드 2대와 core, auth, battle 롤아웃 완료를 최대 10분 기다린다.
- 기록 디렉터리에 대상 노드(`s2-node`, `s2-instance`), 노드 위 파드 목록, 실험 전후 노드 목록, 회수 알림 시각, 새 노드 Ready 시각을 남긴다.
- 대응자가 완화를 마쳤다고 판단하면 `touch v3-john/chaos/records/<실험 이름>/mitigate`로 유지 구간을 끝낸다.

## 배치 재현(S2')

운영 장애 때의 배치를 다시 만들려고 `stage.sh <노드>`로 한 노드에 judge-api, Envoy 하나, Prometheus, Alertmanager, Tempo, core 하나를 모은다. 실행기 앞에서 한 번 부르고, 같은 노드를 `S2_NODE`로 주입 대상에 고정한다.

```bash
RECORD_DIR=v3-john/chaos/records/<실험 이름> v3-john/chaos/scenarios/s2/stage.sh <노드>
S2_NODE=<노드> v3-john/chaos/run-experiment.sh s2 before --inject-after 3m --recover 10m
```

- 다른 application 노드를 cordon하고 대상 파드를 지워 노드에 다시 뜨게 한다. 이미 노드 위에 있는 파드는 지우지 않는다. 성공과 실패 모두 `trap`으로 uncordon한다.
- 모든 배치와 Ready를 최대 `S2_STAGE_WAIT_S`초(기본 300) 기다린다. 하나라도 어긋나면 종료 1이다. core가 노드에 정확히 1개여야 한다.
- 결과는 `$RECORD_DIR/s2-staged.txt`에 남는다.
- Prometheus, Alertmanager, Tempo 볼륨은 ap-northeast-2a에 있으므로 노드가 그 존이 아니면 cordon 전에 종료 1이다. 개선 단계가 모니터링 배치를 바꿨다면 `S2_STAGE_SKIP=monitoring`으로 건너뛰며 존 검사도 함께 빠진다. `judge-api`, `envoy`, `core`도 같은 변수로 건너뛸 수 있다(쉼표 구분).
- S2' 단계 4(모니터링 온디맨드 분리) 이후에는 Prometheus, Alertmanager가 `workload-class=monitoring` 노드에 있으므로 `S2_STAGE_SKIP=monitoring`을 쓴다(Tempo도 함께 건너뜀). 이 값이면 stage.sh가 모니터링 파드를 지우지도 않고 존 검사도 하지 않으며 `s2-staged.txt`에도 적지 않는다.
- 실행기는 `workload-class=application` 노드 중 cordon된 것이 있으면 시작하지 않는다. stage.sh가 중간에 죽어 cordon이 남았을 때를 막는다.
- k6 파드가 대상 노드와 같이 죽지 않도록 `K6_AVOID_NODE=<노드>`를 주면 k6 Job에 해당 노드를 피하는 노드 친화성이 붙는다.

기록 JSON의 `monitoring_gap_seconds`는 판정 구간에서 Prometheus 자기 `up` 표본이 없거나 0인 시간이다. `placement_skew`는 실험 끝 시각에 `kube_pod_info` 기준으로 auth, core, battle, judge-api가 같은 노드에 가장 많이 몰린 레플리카 수다.
