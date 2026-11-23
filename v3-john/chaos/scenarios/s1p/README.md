# S1' 연결 풀 변경과 auth 재시작

1차 S1의 잘못된 배포 시나리오를 DB 연결 관점으로 다시 짠 주입이다. core의 HIKARI 최대 풀 크기를 바꾸는 PR을 main에 병합하고, core 롤아웃이 끝나 안정된 뒤 지연을 두고 auth를 재시작한다. 주입·원복 PR은 main에 자동 병합한다(사용자 승인 2026-11-24).

```bash
S1P_POOL=<N> S1P_TRIGGER_DELAY=180 RATE=<r> v3-john/chaos/run-experiment.sh s1p <step>
```

- `S1P_POOL`: 주입할 `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` 값이다. 필수이며 core 값 파일의 해당 한 줄만 바뀐다.
- `S1P_TRIGGER_DELAY`: core Rollout이 Healthy가 된 뒤 auth 재시작까지의 대기 초이다. 기본 180이다.
- `RATE`: 실행기에 넘기는 부하 값이다.

## 흐름

1. 원래 풀 크기를 `s1p-original`에, `cosmos:db_connections:sum` 값을 `s1p-db-before`에 기록한다.
2. 풀 크기를 바꾸는 PR을 만들어 main에 병합하고 Argo CD 동기화를 기다린다. 병합 SHA는 `own-revisions`에 남아 실행기가 외부 배포로 보지 않는다.
3. core Rollout `cosmos-core`가 Healthy가 될 때까지 최대 600초 기다린다. 카나리 5분 분석을 포함한다.
4. `S1P_TRIGGER_DELAY`초 뒤 `kubectl rollout restart deployment/cosmos-auth`를 실행하고 반환한다. auth 롤아웃 완료는 기다리지 않는다.
5. 이벤트 시각은 `s1p-events`에 남는다.

## 원복

`stop.sh`는 여러 번 불려도 안전하다. 풀 크기가 이미 원래 값이면 PR을 만들지 않는다.

1. 풀 크기를 원래 값으로 되돌리는 PR을 병합하고 core Rollout이 Healthy가 될 때까지 기다린다.
2. auth가 모두 Ready가 아니면 재시작한다.
3. `cosmos:db_connections:sum`이 실험 전 값 +20 이하가 될 때까지 최대 300초 기다린다. Prometheus에 닿지 않으면 기록만 하고 실패시키지 않는다.

## 테스트

```bash
python3 -m unittest v3-john/chaos/tests/test_set_pool.py
```
