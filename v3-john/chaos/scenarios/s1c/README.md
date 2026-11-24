# S1' 채점 장애의 연결 풀 연쇄

부하 중 채점 워커를 5분 멈춘다. 제출 요청이 채점 결과를 기다리며 core DB 연결을 쥐어 core 풀이 바닥나고, 같은 풀을 쓰는 문제 조회·major-core 경로까지 5xx가 나는 연쇄를 재현한다(설계서 6.1, 2026-11-24 재설계). 실제 근거는 `records/round2-baseline.md` 4절의 실제 회수다.

```bash
v3-john/loadtest/prepare.sh
RATE=30 v3-john/chaos/run-experiment.sh s1c <step>
```

- 주입(`inject.sh`): `ScaledObject` `prod/cosmos-judge-worker`에 `autoscaling.keda.sh/paused-replicas: "0"`을 붙이고 워커가 0이 될 때까지 최대 120초 기다린다.
- 유지: `INJECT_DURATION=300`(실제 회수에서 워커가 없던 약 5분).
- 원복(`stop.sh`, 멱등): 주석을 지우고 워커 Ready까지 최대 300초 기다린다.
- 이벤트 시각은 `s1c-events`에 남는다.
- 노드 cordon 방식은 클러스터 오토스케일러가 새 채점 노드를 띄워 중단 시간이 회차마다 달라 쓰지 않는다(사전 측정에서 확인).

## 테스트

```bash
bash v3-john/chaos/tests/test-s1c.sh
```
