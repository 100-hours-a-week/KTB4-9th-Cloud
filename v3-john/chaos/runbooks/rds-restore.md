# 런북: RDS 인스턴스 소실과 복원(S3b)

`cosmos-v3-john-mysql` 인스턴스가 없어졌거나(실수 삭제) 데이터를 되돌려야 할 때 쓴다. S3b 실험(2026-11-23)에서 확인한 순서다. 연결만 안 되는 경우는 `rds-outage.md`를 본다.

## 1. 탐지 신호

- 앱 로그 `UnknownHostException` 또는 `Connect timed out`, 핵심 기능 전면 5xx
- `aws rds describe-db-instances`에 인스턴스가 없거나 상태가 `deleting`
- CloudTrail `DeleteDBInstance` 이벤트(누가, 언제)

## 2. 확인

```bash
# 인스턴스 상태
aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier cosmos-v3-john-mysql --query 'DBInstances[0].[DBInstanceStatus,DeletionProtection,BackupRetentionPeriod]' --output text
# 남은 자동 백업과 복원 가능 구간(지울 때 --no-delete-automated-backups였거나 보존 기간 안)
aws rds describe-db-instance-automated-backups --region ap-northeast-2 --db-instance-identifier cosmos-v3-john-mysql --query 'DBInstanceAutomatedBackups[].[Status,RestoreWindow.EarliestTime,RestoreWindow.LatestTime,DBInstanceAutomatedBackupsArn]' --output text
# 수동·최종 스냅샷
aws rds describe-db-snapshots --region ap-northeast-2 --query 'DBSnapshots[?starts_with(DBSnapshotIdentifier,`cosmos-v3-john`)].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' --output table
```

## 3. 복구: 고르는 순서

| 남은 것 | 방법 | 손실 | 실측 시간 |
|---|---|---|---|
| 자동 백업 | 특정 시점 복원 `chaos/scenarios/s3b/recover-pitr.sh <UTC 시각>` | 복원 가능 끝 이후(수 분) | 삭제 후 7분 13초 |
| 최종 스냅샷(`cosmos-v3-john-mysql-final`) 또는 수동 스냅샷 | 스냅샷 복원(같은 식별자) 뒤 Terraform import | 스냅샷 이후 전부 | 측정 안 함(특정 시점 복원과 비슷할 것) |
| 아무것도 없음 | `chaos/scenarios/s3b/recover-recreate.sh`(시드 스냅샷 재생성 + 시드 덤프) | 시드 이후 전부 | 18분 26초 |

특정 시점 복원(권장):

1. 복원 시각을 정한다. 삭제·오염 직전, 단 `RestoreWindow.LatestTime` 이전이어야 한다(로그 업로드가 몇 분 늦다)
2. `recover-pitr.sh "2026-11-23T12:24:56Z"` — 같은 식별자·서브넷 그룹·보안 그룹·파라미터 그룹으로 복원하고, 백업 1일과 삭제 보호를 켜고, Terraform 상태에서 옛 인스턴스를 지운 뒤 import한다
3. `terraform plan`에 `skip_final_snapshot`, 태그, 비밀번호 차이가 남는다. 한 번 적용한다(제자리 변경). 이후 plan이 변경 없음이어야 한다
4. Spring 3개를 재시작한다(새 연결 풀). 스크립트가 한다

## 4. 복구 확인

- `aws rds describe-db-instances` 상태 available, 삭제 보호 True, 백업 보존 1
- 최근 데이터 확인: 복원 시각 직전에 생긴 행이 있는지(실험에서는 테스트 사용자로 `/api/auth/me` 200)
- 핵심 오류율 0.005 아래, `JudgeJobLost` 해소
- `terraform plan` 변경 없음

## 5. 예방과 주의

- 삭제 보호가 켜져 있다. 지우려면 보호를 먼저 꺼야 한다. `down.sh`가 destroy 전에 보호를 끄고 이전 최종 스냅샷을 지운다
- 자동 백업은 1일이다. 그보다 오래된 시점은 복원할 수 없다
- 실험 안전망 스냅샷(`cosmos-v3-john-safety-*`)이 남아 있다. 필요 없으면 사람이 확인 뒤 지운다
