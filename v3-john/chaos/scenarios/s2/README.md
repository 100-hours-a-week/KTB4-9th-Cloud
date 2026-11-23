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
