# 심각도와 등급별 대응 규칙

설계서 7.1~7.3을 옮긴 것이다. 등급은 알림 이름으로 먼저 제안받고, 아래 매트릭스로 확정한다.

## 7.1 원칙

| 원칙 | 출처 |
|---|---|
| 사용자 영향과 서비스 영향 중 하나라도 기준을 넘으면 그 등급으로 정한다 | GitLab: "If either the Customer Impact OR the GitLab Impact criteria is met" |
| 등급은 느낌이 아니라 지표로 정의한다 | PagerDuty |
| 애매하면 높은 등급으로 정하고, 등급 논쟁은 포스트모템에서 한다 | PagerDuty: "Always Assume The Worst" |
| 등급은 장애 중 가장 컸던 영향으로 남기고 낮추지 않는다 | GitLab: "reflects the maximum impact the incident had" |
| 원인을 찾기 전에 피해부터 멈춘다 | 우아한형제들: "서비스 정상화는 원인 파악보다 우선". PagerDuty 안정화 우선 |

## 7.2 심각도 매트릭스

| 등급 | 조건 (하나라도 해당하면) | 근거 |
|---|---|---|
| SEV1 | ① 핵심 기능 전면 불가(성공 비율 5분 동안 50% 미만) ② 채점 결과 유실이나 잘못된 채점 ③ 사용자 데이터 손실이나 손상 | ① GitLab S1 "Customer-facing service is down" ②③ GitLab S1 "Customer data loss" |
| SEV2 | ① 핵심 기능 빠른 소진(14.4배) ② 핵심 기능 지연 목표 위반 ③ 주요 기능 전면 불가 ④ 모니터링이나 알림 경로 장애 | ①② GitLab S2 "Core functionality is significantly impacted" ③ GitLab S2 ④ PagerDuty SEV-2 "Monitoring for major incident conditions is impaired" |
| SEV3 | ① 주요 기능 빠른 소진 ② 부가 기능 장애 ③ 이중화 상실: 사용자 영향은 없지만 한 번만 더 실패하면 장애가 나는 상태 | ①② GitLab S3 "Moderate impact" ③ PagerDuty SEV-3 "one more node failure would cause an outage" |

- 전면 불가 50%는 PagerDuty의 "most or all users"를 요청 비율로 바꾼 해석이다.
- 시나리오마다 개선 전과 후의 등급을 비교한다. 예를 들어 S2는 개선 전 SEV1, 개선 후 SEV3(이중화 상실)을 목표로 한다.

## 7.3 등급별 대응 규칙

| 항목 | SEV1 | SEV2 | SEV3 | 근거 |
|---|---|---|---|---|
| 탐지 목표 | 5분 | 5분 | - | 알림 짧은 창 5분. Google SRE 워크북 "짧은 창은 긴 창의 1/12" |
| 등급 확정 | 선언 후 15분 안 | 15분 안 | 15분 안 | Monzo: 15분 안에 등급을 정하도록 반복 알림 |
| 첫 공지 | 즉시, 확인된 최소 정보만 | 즉시 | - | 우아한형제들: 감지 즉시 공지 |
| 이후 공지 | 매 공지에 다음 공지 시각을 적음 | 같음 | - | GitLab은 고정 주기를 두지 않는다 |
| 완화 목표 | 30분 | 30분 | 다음 작업 세션 | GitLab 지표 "30분 안 완화 비율". SEV1 30분은 4주 예산의 15%로, 40분(20%)을 넘지 않게 맞춘 값이다 |
| 포스트모템 | 필수 | 필수 | 선택 | GitLab: "All S1 and S2 incidents require a review". Atlassian: Sev 1, 2 필수 |
| 조치 항목 기한 | 4주 | 8주 | - | Atlassian: 우선 조치 4주, 8주 |

## 알림과 제안 등급

증상 알림의 `sev` 라벨이 제안 등급이다. 원인 알림은 등급이 없고 진단에 쓴다.

| 알림 | 종류 | 제안 등급 | 매트릭스 항목 |
|---|---|---|---|
| `CoreUnavailable` | 증상 | SEV1 | SEV1 ① |
| `JudgeJobLost` | 증상 | SEV1 | SEV1 ② |
| `CoreErrorBudgetBurnFast` | 증상 | SEV2 | SEV2 ① |
| `ReadLatencyHigh` | 증상 | SEV2 | SEV2 ② |
| `JudgeTurnaroundHigh` | 증상 | SEV2 | SEV2 ② |
| `MajorUnavailable` | 증상 | SEV2 | SEV2 ③ |
| `Watchdog`이 1시간 넘게 오지 않음 | 관측 경로 | SEV2 | SEV2 ④ |
| `CoreErrorBudgetBurnSlow` | 증상 | SEV3 | SEV3 ①에 준함 |
| `AiErrorRateHigh` | 증상 | SEV3 | SEV3 ② |
| `PodCrashLooping`, `PodsPending`, `NodeNotReady`, `DbConnectionPoolExhausted`, `DeploymentReplicasUnavailable`, `JvmHeapHigh`, `AppMetricsScrapeDown` | 원인 | - | 사용자 영향이 없고 이중화만 잃었으면 SEV3 ③ |
| `ArgoAppDegraded`, `ArgoSyncFailed`, `ImageUpdaterErrors` | 배포 | - | 최근 변경 확인의 출발점 |

- 증상 알림이 여러 개 울리면 가장 높은 등급을 쓴다.
- 데이터 손실(S3)은 알림이 없다. 확인되면 바로 SEV1 ③이다.
