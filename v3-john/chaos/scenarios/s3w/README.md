# S3w 채점 워커 정지(살아 있지만 일을 못 하는 상태)

2026-11-24 19:44 실제 사례: DB·큐 노드 교체 뒤 채점 워커가 Running인 채 처리 속도가 떨어져 대기열을 따라잡지 못했고, 사람이 재시작한 20:31까지 제출이 실패했다. 쿠버네티스는 컨테이너가 Running이라 아무것도 하지 않았다. 계획 교체 재현 3회(s3r)에서는 이 상태가 다시 나오지 않아, 그 상태 자체를 주입해 대응 장치(채점 워커 생존 검사)를 검증한다.

```bash
v3-john/loadtest/prepare.sh
RATE=30 v3-john/chaos/run-experiment.sh s3w <step>
```

- 주입: 모든 채점 워커 파드에서 `pkill -STOP -f "^resque-"`. 대기열은 쌓이고 컨테이너는 Running
- 유지 600초. 대응 전(생존 검사 없음)에는 600초 동안 회복되지 않는지, 대응 후에는 생존 검사가 몇 초 만에 재시작해 회복하는지 본다
- 원복: `pkill -CONT`(사람 개입에 해당). 기록: `s3w-events`, `s3w-restarts-before/after`
