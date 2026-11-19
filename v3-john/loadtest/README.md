# v3-john 부하 테스트

SLO 기준선과 장애 주입 실험에 쓰는 k6 시나리오와 준비 스크립트다.

## 구성

| 파일 | 역할 |
|---|---|
| `seed.sql` | 테스트 전용 사용자 50명(`loadtest-001~050`), 랭킹 점수 행, 저장 문제 20개, 오늘의 데일리 문제 3개를 만든다. 여러 번 실행해도 된다 |
| `mint_tokens.py` | 테스트 사용자의 `accessToken` JWT(HS256)를 만든다. 서명 키는 Secrets Manager `/cosmos-v2/stage/spring`에서 읽고 출력하지 않는다 |
| `prepare.sh` | 임시 MySQL 파드로 `seed.sql`을 실행하고 토큰과 문제 ID 파일을 `$OUT`(기본 `$TMPDIR/cosmos-loadtest`)에 만든다 |
| `baseline.js` | 정상 상태 사용자 흐름. 핵심(내 정보, 데일리 문제, 문제 상세, 코드 제출 10%)과 주요(랭킹, 배틀 현황, 알림) |

AI 기능(힌트, 풀이 평가)은 실제 Gemini API 비용이 나가므로 제외한다. 가짜 Gemini 서버를 둔 뒤 추가한다.

## 실행

`up.sh`로 클러스터를 띄운 뒤 실행한다. 토큰은 3시간 유효하다.

```bash
v3-john/loadtest/prepare.sh
```

```bash
OUT=${TMPDIR:-/tmp}/cosmos-loadtest
k6 run -e TOKENS=$OUT/tokens.json -e PROBLEMS=$OUT/problems.json -e VUS=10 -e DURATION=10m \
  --summary-export=$OUT/run1.json v3-john/loadtest/baseline.js
```

판정은 k6 요약(클라이언트 측)과 Prometheus 기록 규칙(서버 측, Envoy 기준)을 함께 본다.

| 지표 | 출처 |
|---|---|
| 기능 묶음별 오류율 | `cosmos:journey_error_ratio:rate5m` |
| 조회 p95 | `cosmos:read_latency_p95_ms:rate5m`, k6 `read_latency` |
| 채점 처리 시간 | k6 `submit_latency` (제출부터 채점 결과까지 동기 응답) |
| 채점 누락 | k6 `judge_incomplete` |

## 주의

- 토큰 파일은 테스트 사용자 인증 정보다. 저장소에 올리지 않는다.
- 클러스터를 내리면 시드 데이터도 사라진다. 다시 띄우면 `prepare.sh`부터 다시 실행한다.
