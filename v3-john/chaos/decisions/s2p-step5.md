# 결정 기록: S2' 단계 5 재분산

## 근거

개선 전 실험(s2p-before)과 s2p-step1~4 실험 뒤 채운다.

채울 항목은 회수나 교체 뒤 `placement_skew` 값, 쏠림이 파드 전체 손실에 미친 정도, 그 기록 경로다.

이미 확인한 1차 증거는 다음과 같다.

- 노드 그룹 교체 뒤 core, auth, battle 6개가 모두 한 노드에 떴고 Envoy 두 개도 한 노드에 몰렸다. `ScheduleAnyway` 분산은 처음 준비된 노드에 몰리면 이후 다시 나누지 않는다. 그 결과 레플리카 1인 judge-api와 Envoy 두 개가 회수 노드에 함께 있어 핵심 5xx 33/9,861, 채점 유실 38이 났다(`v3-john/chaos/records/s2-step3-notes.md`)
- S2 단계 2 실험 뒤 core 두 개가 다시 한 노드에 모였다. `ScheduleAnyway`는 자리가 모자라면 분산을 포기한다(`v3-john/chaos/records/s2-step2-notes.md`)
- 현재는 쏠림을 사람이 알아채 재시작으로 나눈다. 알아채지 못하면 다음 회수에서 같은 손실이 난다

## 대안 비교

| 항목 | A. descheduler(선택) | B. 분산 규칙 `DoNotSchedule` | C. 런북의 수동 재시작 |
|---|---|---|---|
| 효과 | 2분 주기로 `RemovePodsViolatingTopologySpreadConstraint`가 분산 규칙을 어긴 파드를 축출하고 스케줄러가 덜 찬 노드에 다시 놓는다. 쏠림을 만든 뒤 2주기(4분) 안에 `placement_skew`가 1이 될 것으로 본다(추정) | 규칙을 어기는 자리에는 아예 놓지 않아 쏠림이 생기지 않는다. 이미 몰린 파드는 되돌리지 못한다 | 사람이 쏠림을 보고 재시작해 나눈다. 효과는 알아챈 시점과 절차 숙련도에 달린다 |
| 비용 | 시스템 노드에서 파드 1개, 요청 CPU 50m, 메모리 64Mi. 노드를 늘리지 않는다 | 없음 | 없음. 사람 시간만 든다 |
| 운영 부담 | 차트 1개와 값 파일 1개. 버전 고정과 digest 갱신이 필요하다 | 분산 규칙 값 변경만 필요하다. 노드 여유를 계속 점검해야 한다 | 런북 절차와 쏠림 점검 습관이 필요하다. 사람이 빠뜨리기 쉽다 |
| 위험·부작용 | 재분산 중 축출이 짧은 중단을 만들 수 있다. PDB(`minAvailable` 1)가 한 번에 하나씩으로 막고 레플리카 2 이상일 때만 축출된다. 계속 축출해 흔들릴 위험은 노드 적합 검사(`nodeFit`)와 2분 주기로 줄인다 | 노드가 부족하면 파드가 Pending이 된다. 1차에서 HPA 최소 2를 넣자 application 노드 3대(최대)의 CPU 요청이 98~99%가 되어 core, battle 두 번째 파드가 Pending이 됐다(실사용 CPU는 30m 안팎, `v3-john/chaos/REPORT.md`의 이중화 사례, PR #63). 스팟 회수로 노드가 줄어든 시간에 규칙이 엄격하면 Pending이 길어진다 | 재시작 중 짧은 중단이 난다. 새벽 회수처럼 사람이 없을 때는 쓸 수 없다 |
| 앱 코드 필요 여부 | 불필요 | 불필요 | 불필요 |
| 선택 이유 | 선택. 기존 분산 규칙을 바꾸지 않고 쏠림만 사후에 되돌린다. Pending 위험이 없고 자동이다 | 버림. 노드 여유가 없는 이 클러스터에서 Pending 위험이 확인됐고, 이미 몰린 파드를 못 푼다 | 버림. 사람에 의존하고 회수가 잦은 스팟 환경에서 놓치기 쉽다. descheduler가 없을 때의 대비 절차로만 남긴다 |

`DoNotSchedule`을 같이 쓰지 않는 이유는 위 Pending 사례 때문이다. 이 단계는 분산 규칙 자체를 바꾸지 않고 `ScheduleAnyway`와 `DoNotSchedule` 규칙을 모두 점검 대상으로 둔 채 사후 재분산만 한다.

descheduler 설정은 다음과 같다(`v3-john/helm/addons-values/descheduler/values.yaml`).

- 차트 descheduler/descheduler 0.37.0, 이미지는 digest로 고정했다
- 플러그인은 `RemovePodsViolatingTopologySpreadConstraint` 하나만 켠다. 규칙의 `ScheduleAnyway`도 보도록 `constraints`에 두 값을 넣었다
- 대상 네임스페이스는 `prod`와 `envoy-gateway-system`이다
- 축출기는 PDB를 지키고 시스템 핵심 파드, 로컬 저장소 파드, 데몬셋 파드를 건드리지 않는다
- 시스템 노드에서 Deployment로 돌고 주기는 2분이다

## 검증 기준

실험 전에 정하고 바꾸지 않는다.

- 한 노드에 몰아 쏠림을 만든 뒤 2주기(4분) 안에 `placement_skew`가 1이 된다
- 재분산 중 핵심 5xx가 0이다
- 3회 모두 위 두 조건을 만족한다. 한 회라도 못 넘으면 효과 없음으로 판정하고 그대로 기록한다
- 재분산이 끝난 뒤에도 축출이 계속 반복되면(2주기 이상 연속 축출) 흔들림으로 기록하고 판정에서 불합격으로 본다

## 결과

단계 실험 뒤 채운다.
