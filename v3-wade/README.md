# v3-wade

장애 주입 훈련용 EKS 클러스터. VPC, RDS, Valkey, 도메인, MLflow 버킷을 운영과 분리한다. ECR 이미지는 digest로 공유한다.

| 항목 | 값 |
| --- | --- |
| 클러스터 | `cosmos-v3-wade` |
| VPC | `10.40.0.0/16` |
| 서비스 | `https://wade.cosmoscode.site` |
| Argo CD | `https://argocd-wade.cosmoscode.site` |
| Grafana | `https://grafana-wade.cosmoscode.site` |
| 노드 | Spot 5대, 16 vCPU |

## 사용

1. `environments/eks/terraform.tfvars`에 `public_access_cidrs`, `edge_allowed_cidrs`를 지정한다.
2. 시드가 없으면 `scripts/seed.sh`를 실행한다. RDS 스냅샷과 PostgreSQL 덤프를 고정한다.
3. `scripts/up.sh`로 띄운다.
4. 끝나면 `scripts/down.sh --yes`로 전부 지운다.

## 제약

- Argo CD는 `main`의 `v3-wade/gitops`를 읽으므로 이 폴더가 `main`에 있어야 한다.
- 복원한 데이터는 `down.sh`로 사라지고 다음 `up.sh`에서 시드로 초기화된다.
- 프런트엔드는 `scripts/build-frontend.sh`가 FE 저장소 `stage`를 이 주소로 빌드한다. FE 저장소가 Cloud 저장소 옆에 있어야 한다.
- Kakao 로그인은 Kakao 콘솔에 `https://wade.cosmoscode.site/api/auth/oauth/kakao/callback`을 등록해야 동작한다.
- Secret 일부는 `/cosmos-v2/stage/*`, `cosmos/prod/spring-config`를 읽으므로 이 값들을 지우면 안 된다.
- Spot 한도 32 vCPU 안에 맞추려고 Worker는 1개로 고정한다.
