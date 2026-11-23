# 2차 기준선, RDS 상한 실측, SLI 검증 (Task 4)

측정일: 2026-11-24 KST(시각은 UTC로 적는다). 클러스터: up.sh 재실행(main 7b5b0ef), Argo 앱 14개 Synced/Healthy. 프런트엔드 빌드만 실패했다(1차와 같은 원인, 부하는 API에 직접 준다).

## 1. RDS 연결 상한

`prepare.sh`와 같은 대기 파드 방식으로 읽기 질의를 했다.

| 항목 | 값 |
|---|---|
| `max_connections` | 303 |
| `Threads_connected` | 63 |
| `Max_used_connections`(기동 이후) | 82 |
| 사용자별 | `cosmos_admin` 61(Spring 파드 6개 x 풀 10 + 측정 파드 1), `rdsadmin` 2 |
| Prometheus `cosmos:db_connections:sum` | 60 |

- Prometheus 합 60이 RDS의 Spring 연결 60과 같다. 지표가 연결을 두 번 세거나 빠뜨리지 않는다
- 상수 300(자리 표시 값)을 303으로 바꿨다. Prometheus `RdsConnectionBudgetHigh` 분모(PR #92, 적용 확인), CI 검사 `RDS_MAX_CONNECTIONS`와 core `connectionGuard.rdsMax`(단계 브랜치, 병합 전)
- 다른 서비스와 관리 연결은 auth 20 + battle 20 + rdsadmin 2 = 42다. S1' 보정은 이 값을 쓴다

## 2. 기준 초당 요청 수

열린 부하 모델로 각 5분. 판정 기준(계획서): 핵심 오류율 0, 조회 p95가 1차 기준선 24ms의 120%(28.8ms) 이하인 가장 큰 값.

| RATE | 반복 수 | 핵심 오류율(5분 최대) | Envoy 조회 p95 | k6 조회 p95 | k6 제출 p95 | 업무 거절(429) |
|---|---|---|---|---|---|---|
| 10 | 2,988 | 0 | 24.8ms | 27.5ms | 1,128ms | 0 |
| 20 | 5,979 | 0 | 24.0ms | 23.9ms | 1,107ms | 2 |
| 30 | 8,968 | 0 | 24.0ms | 23.8ms | 2,085ms | 21 |

**RATE_BASE = 30**. 30에서 제출 p95가 두 배로 오른 점은 채점 처리량이 한계에 가깝다는 신호로 기록해 둔다(판정 기준 밖).

## 3. 기준선(RATE 30, 10분)

| 회차 | 구간(UTC) | 핵심 요청/5xx | major 요청/5xx | 핵심 1분 오류율 최대 | SLO 유지율 | Envoy 조회 p95 | k6 제출 p95 | 채점 유실 | 업무 거절 | 판정 |
|---|---|---|---|---|---|---|---|---|---|---|
| base-1 | 18:26:54~18:37:02 | 49,871 / 3,366 | 48,283 / 5,754 | 30.2% | 67.6% | 3,240ms | 14,995ms | 359 | 202 | 실제 스팟 회수로 오염(4절) |
| base-2 | 18:37:11~18:47:19 | 50,890 / 0 | 49,242 / 0 | 0 | 100% | 24.0ms | 1,103ms | 0 | 749 | 통과 |
| base-3 | 18:47:23~18:57:31 | 50,881 / 0 | 49,267 / 0 | 0 | 100% | 23.8ms | 1,093ms | 0 | 1,251 | 통과 |
| base-4 | 18:59:00~19:09:07 | 50,613 / 12 | 49,022 / 9 | 0.3% | 100% | 24.0ms | 1,349ms | 0 | 12 | 통과 |

- 기준선은 base-2·3·4로 정한다. 세 회차 모두 SLO 유지율 100%, `CoreBurnFastAll` 미발생이다
- base-4의 5xx 21건은 19:01 한 분 동안 core 경로(문제 조회, major-core)에서만 났다. 오류율 0.3%로 목표 0.5% 아래다
- 업무 거절은 사용자·문제당 평생 5회 제출 제한(429) 때문이다. 회차를 거듭하면 거절이 늘고(202 → 749 → 1,251) 그만큼 채점 부하가 준다. base-4 앞에서 `prepare.sh`로 제출 기록을 지우자 12건으로 돌아왔다. 2차 실험은 회차마다 `prepare.sh`를 먼저 실행한다

중앙값(base-2·3·4): 핵심 5xx 0, 조회 p95 24.0ms, 제출 p95 1,103ms, 채점 유실 0.

## 4. 기준선 중 실제 스팟 회수와 연쇄 장애(base-1)

부하 중에 실제 스팟 회수가 일어났다. 주입하지 않은 사건이다.

| 시각(UTC) | 사건 | 근거 |
|---|---|---|
| 17:46:34 | application 노드 m5.xlarge(i-0a0d9b7fa60a2cf56) 회수, 사유 `instance-terminated-no-capacity` | Spot 요청 상태 |
| 18:30:13 | judge-base-ng c6i.xlarge(i-08bec3ee5733f1398) 회수, 같은 사유. 이 노드에는 judge-worker만 있었다 | Spot 요청 상태, ASG 활동 "taken out of service in response to an EC2 Spot Instance interruption notice" |
| 18:30:14 | ASG가 대체 인스턴스 i-0834822a691178b7c 기동(재조정 권고 대응) | ASG 활동 |
| 18:32~18:34 | core Hikari 활성 연결 10/10(두 파드 모두), 대기 74~103. 문제 조회 5xx 최대 23/s, major-core 46/s, 제출 5xx 2.5/s와 Envoy 타임아웃 | Prometheus `hikaricp_connections_active`, `hikaricp_connections_pending`, Envoy 지표 |
| 같은 구간 | 문제 조회 p95 4.5초(평소 24ms), 제출 p95 15.0초, 채점 유실 359 | Envoy, k6 |
| 18:35 | 새 judge-worker 기동 뒤 회복 | 파드 이벤트, 지표 |

해석: 제출 요청이 채점 결과를 기다리는 동안 DB 연결을 쥐고 있어서, 채점 워커가 사라지자 제출 요청이 연결을 오래 쥐었고 core 연결 풀(10)이 바닥났다. 같은 풀을 쓰는 문제 조회와 major-core 경로가 함께 실패했다. 채점 노드 한 대의 회수가 핵심 경로 전체 장애로 번진 것이다. 앱 내부 동작(트랜잭션 범위)은 백엔드 담당 영역이라 확인하지 않았고, 위 해석은 지표에서 끌어낸 추정이다.

이 사건은 S2'(스팟 노드 회수)의 개선 전 근거로 쓴다. 기존 설계서의 손실 표(비우기 중 실패, 채점 유실, 모니터링 공백, 배치 쏠림)에 없던 "채점 경로 장애가 core 연결 풀을 통해 핵심 경로로 번짐"이 실제로 관찰됐다.

## 5. SLI 이중 집계 검증

계획서 Task 4의 검증 항목. 시험 경로(`monitoring/sli-probe-*`)를 만들어 각 20건을 보냈다.

| 경우 | 응답 | `upstream_rq_xx` 5xx | `upstream_rq_timeout` | `upstream_cx_connect_fail` | `upstream_rq_total` |
|---|---|---|---|---|---|
| 요청 제한 시간 1초, 백엔드 3초 지연 | 504 | 20 | 20 | 0 | 20 |
| 듣지 않는 포트 | 503 | 20 | 0 | 20 | 0 |

- Envoy는 타임아웃과 연결 실패를 이미 5xx에 올린다. 설계서의 "업스트림 5xx 밖의 타임아웃과 연결 실패를 더한다"는 가정은 틀렸다. 그대로 두면 두 경우 모두 오류를 두 배로 센다
- 연결 실패 요청은 `upstream_rq_total`에 빠진다. 분모를 `rq_total`로 두면 오류율이 커 보인다
- 수정(PR #93): 오류는 5xx와 정상 엔드포인트 없음만 센다. 분모는 응답 코드별 합(`cosmos:route_requests_all:rate5m`)이다. `aggregate.py`의 1분 오류율과 판정 구간 집계도 같게 맞췄다. promtool 테스트를 실측 모양으로 다시 써서 옛 규칙에서 0.6과 0.857로 실패하고 새 규칙에서 0.3으로 통과하는 것을 확인했다
- 엔드포인트가 0개인 서비스에는 Envoy Gateway가 클러스터를 만들지 않아 `cx_none_healthy`는 이 방법으로 확인하지 못했다. 1차 규칙 그대로 둔다
- 1차 규칙(`cosmos:route_requests:rate5m`, `rq_total` 분모)은 1차 결과와 비교하기 위해 바꾸지 않았다

## 6. 배치 재현 라벨 확인

`scenarios/s2/stage.sh`가 쓰는 선택자가 모두 실제 파드와 맞는다: judge-api 1, Envoy 2, Prometheus·Alertmanager·Tempo 각 1, core 2. application 노드 3대.
