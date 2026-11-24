# S2' B 상태 저장 스팟 노드 회수

상태 저장 노드(`stateful-ng`: ai-postgres, judge-postgres, judge-redis-queue, rabbitmq, 모두 레플리카 1과 EBS 볼륨)에 FIS로 회수 2분 전 알림을 보낸다. 2026-11-24 08:51 실제 회수(`instance-terminated-no-capacity`)를 재현한다.

```bash
v3-john/loadtest/prepare.sh
RATE=30 v3-john/chaos/run-experiment.sh s2b <step>
```

- 위험의 핵심: `stateful-ng` 서브넷이 a·c 둘 다인데 네 볼륨은 한 존(2026-11-24 기준 ap-northeast-2a)에 있다. 대체 노드가 다른 존에 뜨면 볼륨을 붙이지 못해 네 파드가 사람 손이 닿을 때까지 뜨지 못한다
- 주입 유지 600초. `s2b-timeline`에 5초마다 Ready 파드 수와 상태 저장 노드(이름, 존, Ready)를 남긴다
- 원복(`stop.sh`)은 FIS를 정리하고, 대체 노드가 다른 존이면 런북 `runbooks/stateful-node-loss.md`의 수동 복구(노드 교체)를 최대 3번 한 뒤 네 파드 Ready를 최대 1200초 기다린다. 시각은 `s2b-events`
- FIS 역할은 `environments/eks/fis.tf`에서 application-ng와 stateful-ng 인스턴스에만 회수 알림을 보낼 수 있다

테스트: `bash v3-john/chaos/tests/test-s2b.sh`
