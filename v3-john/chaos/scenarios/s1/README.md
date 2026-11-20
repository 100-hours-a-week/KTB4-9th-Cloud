# S1 잘못된 배포로 core 연쇄 장애

설계서 9.1의 주입이다. "노드 비용 절감" 명목으로 core 메모리를 낮추는 PR을 main에 병합하고, Argo CD 자동 동기화로 배포한다. 원복도 같은 방식의 PR이다. 주입·원복 PR의 main 자동 병합은 2026-11-20 사용자 승인을 받았다.

```bash
S1_MEMORY=448Mi v3-john/chaos/run-experiment.sh s1 before --inject-after 3m --recover 10m
```

- `S1_MEMORY`: requests와 limits를 모두 이 값으로 둔다(원래 1Gi/2Gi. 요청이 제한보다 클 수 없어 함께 낮춘다).
- 주입은 새 파드가 준비 상태 검사를 통과해 롤아웃이 끝나야 성공이다. 기동이 실패하는 값은 S1에 쓰지 않는다.
- 대응자가 원인을 찾아 되돌리기로 하면 `touch v3-john/chaos/records/<실험 이름>/mitigate`로 바로 원복한다(완화 시간 측정).
- 시나리오가 병합한 SHA는 `own-revisions`에 남고, 실행기는 이 리비전을 외부 배포로 보지 않는다.

## 주입값: 448Mi

조건: 기동과 준비 상태 검사는 통과하고 k6 10 VU 부하에서 OOMKilled가 3회 중 3회 난다.

| 값 | 회차 | 기동·준비 | OOMKilled | 첫 증상 알림 | 핵심 5xx | 채점 유실 |
|---|---|---|---|---|---|---|
| 640Mi | 1 | 통과 | 없음(작업 메모리 최대 474Mi) | `JudgeJobLost` 75초 | 35 | 35 |
| 512Mi | 1 | 통과 | 없음(최대 460~507Mi) | 없음 | 8 | 0 |
| 448Mi | 1 | 통과 | 1회 | `JudgeJobLost` 240초 | 156 | 10 |
| 448Mi | 2 | 통과 | 1회 | `JudgeJobLost` 360초 | 169 | 6 |
| 448Mi | 3 | 통과 | 1회 | `JudgeJobLost` 255초 | 217 | 44 |

- 계획의 후보(1.5Gi, 1.25Gi, 1Gi)는 쓰지 않았다. 기준선 부하에서 core 작업 메모리 최대가 560Mi이고, JVM이 힙을 제한의 25%로 잡아 제한을 낮추면 힙도 같이 줄기 때문이다. 640Mi와 512Mi도 같은 이유로 버텼다.
- 640Mi의 채점 유실 35건은 OOMKilled가 아니라 core 롤링 재시작(주입·원복 배포) 중 처리 중이던 제출이 끊긴 것이다. 레플리카가 1개라 평소 배포만으로도 채점이 유실된다.
- 448Mi 3회 모두 첫 증상 알림은 `JudgeJobLost`였다. `CoreUnavailable`(5분 성공률 50% 미만)과 `CoreErrorBudgetBurnFast`(1시간·5분 7.2% 초과)는 울리지 않았다. OOMKilled 뒤 재시작이 빨라(복구 90~300초) 5분 평균 오류율이 기준에 못 미쳤다.
- 기록: `records/s1-search-*-20261120-*.json`
