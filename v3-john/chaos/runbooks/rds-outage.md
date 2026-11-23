# 런북: RDS 연결 장애(S3a)

앱이 RDS에 닿지 못할 때 쓴다(네트워크, 보안 그룹, RDS 재시작·장애 조치, 연결 수 초과). S3a 실험(2026-11-23)에서 확인한 순서다. RDS 인스턴스 자체가 없어진 경우는 `rds-restore.md`를 본다.

## 1. 탐지 신호

| 신호 | 의미 |
|---|---|
| `DbConnectionPoolExhausted` | Hikari 풀이 비어 요청이 연결을 기다린다. 이 장애의 첫 알림인 경우가 많다 |
| `JudgeJobLost`, `MajorUnavailable` | 제출·랭킹 등 DB를 쓰는 기능 실패 |
| 처리량 급감 | 대시보드에서 요청 수가 갑자기 줄면 요청이 묶여 있는 것이다. 오류율만 보면 작게 보일 수 있다 |

## 2. 확인

```bash
# RDS 상태(available이면 인스턴스는 살아 있다 → 경로 문제)
aws rds describe-db-instances --region ap-northeast-2 --db-instance-identifier cosmos-v3-john-mysql --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone]' --output text
# 앱 로그에서 연결 오류(Connect timed out, Communications link failure, Too many connections)
kubectl logs -n prod deploy/cosmos-auth --since=5m | grep -iE 'hikari|timed out|link failure|too many'
# 파드에서 직접 연결 시험
kubectl exec -n prod deploy/cosmos-auth -c cosmos-auth -- bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/cosmos-v3-john-mysql.cnukai4cwbww.ap-northeast-2.rds.amazonaws.com/3306" && echo ok || echo fail'
# 남아 있는 장애 주입(실험 중이면)
kubectl get networkchaos -A
```

Grafana의 RDS 대시보드(`RDS (cosmos-v3-john-mysql)`, CloudWatch)에서 연결 수, CPU, 읽기·쓰기 지연을 본다. 연결 수가 0으로 떨어지면 경로 문제, 최대치에 붙어 있으면 연결 수 초과다.

## 3. 완화

- **경로 문제**(보안 그룹, NetworkPolicy, 서브넷 라우팅): 최근 Terraform·GitOps 변경을 되돌린다. 실험 중이면 `kubectl delete networkchaos s3a-rds-partition -n prod`
- **RDS 재시작·장애 조치 중**: 기다린다. 앱이 할 수 있는 것은 없다. 공지로 사용자에게 알린다
- **연결 수 초과**: 레플리카 수 × 풀 크기(10)가 RDS 최대 연결 수를 넘지 않는지 본다. HPA 최대를 잠시 낮춘다

## 4. 복구 확인

- 앱 로그에 연결 오류가 더 이상 없다
- 핵심 오류율 0.005 아래, `DbConnectionPoolExhausted` 해소
- 차단 해제 뒤 회복은 15~30초였다. 길어지면 파드를 재시작한다(풀이 망가진 연결을 들고 있는 경우)

## 5. 현재 설정과 한계

- 헬스 검사는 DB를 보지 않는다(`MANAGEMENT_HEALTH_DB_ENABLED=false`). DB가 끊겨도 파드는 서비스에 남는다
- Hikari 연결 대기 3초. 요청은 3초 안에 실패한다(이전 30초는 Envoy 15초 제한에 먼저 걸렸다)
- 이 서비스는 거의 모든 요청이 DB를 쓰므로 RDS 장애는 곧 핵심 기능 장애다. 읽기 캐시나 읽기 전용 복제본이 없으면 시간을 줄일 방법이 없다(보고서 제안)
