# MySQL 애플리케이션 계정 준비 절차

Terraform은 RDS 관리자 비밀번호를 직접 만들거나 state에 저장하지 않습니다. RDS가 관리하는 master Secret은 초기 계정 준비 때만 운영자 세션에서 사용합니다.

1. 변경 창을 열고 AWS SSO 또는 승인된 운영자 역할로 접속합니다.
2. `rds_master_secret_arn` output이 가리키는 Secret을 Secrets Manager에서 조회합니다. 값은 터미널 기록, 문서, Terraform 변수에 남기지 않습니다.
3. Session Manager 포트 포워딩 등 private RDS에 도달 가능한 경로에서 MySQL에 접속합니다.
4. `cosmos` schema가 존재하는지 확인하고 `cosmos_app` 전용 계정을 생성합니다. 비밀번호는 승인된 비밀 생성 절차로 새로 만듭니다.
5. `cosmos_app`에는 `cosmos` schema에 필요한 최소 DML/DDL 권한만 부여합니다. 전역 권한과 관리자 권한은 부여하지 않습니다.
6. `/cosmos-v2/prod/spring` Secret에 `db_username`과 `db_password` JSON key를 입력합니다. Terraform에는 Secret version을 추가하지 않습니다.
7. 애플리케이션 연결을 검증한 뒤 관리자 자격 증명을 세션에서 제거하고 셸 기록에 남지 않았는지 확인합니다.

계정 회전 시 새 비밀번호를 먼저 생성하고 Secret을 갱신한 뒤 Spring task를 재배포합니다. 연결 성공 확인 후 이전 자격 증명을 폐기합니다.
