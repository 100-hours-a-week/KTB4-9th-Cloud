# AI/Judge 상태 저장 서비스 복구 절차

AI PostgreSQL, Judge PostgreSQL, Judge Redis EBS는 Terraform 자동 교체 대상이 아닙니다. 장애 시 다음 순서로 사람의 검토를 거쳐 복구합니다.

상태 저장 EC2의 user-data 변경은 보존형 EBS와 인스턴스의 예기치 않은 교체를 막기 위해 기존 인스턴스에 자동 반영하지 않는다. 템플릿 수정이 필요한 경우 신규 복구 EC2에는 수정본을 사용하고, 기존 인스턴스에는 검토된 SSM 절차로 동일 변경을 적용한다.

1. CloudWatch와 ECS에서 장애 범위, 마지막 정상 시각, 대상 서비스와 AZ를 확인합니다.
2. 대상 ECS Service의 desired count를 0으로 낮춰 손상 가능성이 있는 volume에 더 이상 쓰지 않게 합니다.
3. 기존 EC2를 격리하고 EBS가 detach 가능한 상태인지 확인합니다. 장애 volume을 삭제하거나 Terraform으로 교체하지 않습니다.
4. DLM snapshot 목록에서 복구 시점과 보존 상태를 검토하고, 원본과 동일 AZ에 새 암호화 gp3 volume을 만듭니다.
5. 동일 AZ의 복구 EC2를 준비한 뒤 volume을 attach합니다. volume ID, filesystem, mount path를 확인하고 읽기 전용 검사를 먼저 수행합니다.
6. ECS instance attribute가 AI DB는 `role=ai-postgres`, Judge DB는 `role=judge-postgres`, Redis는 `role=judge-redis`인지 확인합니다.
7. mount와 소유권을 확인한 후 ECS agent를 시작하고 container instance가 `ACTIVE`인지 확인합니다.
8. ECS Service desired count를 1로 복원합니다. 동시에 두 Task가 같은 volume을 사용하지 않는지 확인합니다.
9. container health와 Service Connect 이름을 확인합니다. AI DB는 `ai-postgres:5432`와 FastAPI `/db-check`, Judge DB/Redis는 Judge API와 Worker 연결 및 데이터 정합성을 검증합니다.
10. 복구 결과와 선택한 snapshot을 기록한 뒤에만 기존 instance/volume의 후속 처리를 승인합니다.

`terraform apply`로 장애 volume이나 EC2를 자동 교체하지 않습니다. `prevent_destroy` 변경, state 제거, 강제 detach는 별도 변경 승인과 백업 확인이 필요합니다.

AI PostgreSQL snapshot을 복구한 뒤에는 현재 Alembic revision을 확인한다. `alembic upgrade head`가 실패하면 FastAPI Service를 활성화하거나 신규 배포를 정상으로 선언하지 않고 migration log와 revision을 먼저 수정한다. 복구 중 Backend Valkey는 Spring과 연결되어 있지 않으므로 Spring 장애 원인으로 간주하지 않는다.
