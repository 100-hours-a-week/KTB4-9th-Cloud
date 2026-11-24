# S3r 상태 저장 노드 계획 교체(점검·업그레이드 재현)

2차 최종 시나리오(2026-11-24 사용자 결정). DB·큐(ai-postgres, judge-postgres, judge-redis-queue, rabbitmq)가 있는 온디맨드 노드를 계획 교체한다: 새 노드를 하나 더 띄우고 옛 노드를 drain해 네 파드를 한꺼번에 옮긴다. AMI 패치, EKS 버전 업그레이드, EC2 예정 점검 때 실제로 일어나는 이동이다.

발견 배경: 스팟 회수 실험(s2b-r2-before-20261124-1939)에서 DB·큐는 45초 만에 새 노드에서 떴지만, 채점 경로가 재연결하지 못해 사람이 채점 파드를 재시작할 때까지 약 47분 동안 제출이 실패했다. 파드는 Running이라 쿠버네티스가 아무것도 하지 않았다. DB·큐를 하나씩 재시작하면 재현되지 않았다.

```bash
v3-john/loadtest/prepare.sh
RATE=30 v3-john/chaos/run-experiment.sh s3r <step>
```

- 주입(`inject.sh`): 노드 그룹 1/2/2 → 새 노드 Ready → 옛 노드 drain. 5초마다 Ready 파드 수를 `s3r-timeline`에, 사건 시각을 `s3r-events`에 남긴다
- 원복(`stop.sh`): 네 파드 Ready 대기 → 옛 노드를 원하는 용량을 줄이며 종료 → 노드 그룹 1/1/1. 채점 파드는 건드리지 않는다(대응 전 실험에서 사람 개입 전까지 지속되는지 재기 위해)
