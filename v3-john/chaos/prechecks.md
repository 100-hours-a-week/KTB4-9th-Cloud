# 실험 전 사전 확인

설계서 9장 연쇄 관찰표의 전제를 실험 전에 확인한 결과다. 기준 이미지는 v3-john에 승격된 BE `approved-6bb76d7ccde9a513ba6f79fcc2497dd0c415461b`(BE dev), AI `approved-76f850ab691c3d8bafbca7b8aa4d51e285eaf9db`(AI main)다.

| 항목 | 결과 | 근거 |
|---|---|---|
| core가 Judge 콜백을 쓰는가 | 쓰지 않는다. core는 `/submissions/batch`로 제출한 뒤 토큰으로 결과를 조회한다(폴링) | BE `codesubmission/client/Judge0Client.java`의 `submitBatch`, `waitForResults`. 저장소 전체에 `callback_url`이 없다 |
| AI 호출이 비동기인가 | 그렇다. 풀이 제출은 202로 접수되고 평가 워커가 ai-llm `/api/llm/evaluation`을 부른다. 힌트는 저장된 값을 돌려주며 LLM을 부르지 않는다 | BE `approach/controller/ApproachSubmissionController.java`(202, `SolutionEvaluationTaskService.accept`), `EvaluationTaskStatus`(PENDING, PROCESSING, RETRY_WAIT, SUCCEEDED, FAILED). AI `src/router/evaluation.py` |
| `/actuator/health`에 DB가 포함되는가 | 포함된다(설정상). 준비 상태 검사가 `/actuator/health`(9091)를 보므로 RDS가 끊기면 Spring 파드 전부가 준비 안 됨이 된다 | BE `application.yaml` `management.endpoint.health.show-details: always`, DB 지표를 끄는 설정 없음. `core.yaml` `readinessProbe: /actuator/health:9091`. 클러스터에서 `curl localhost:9091/actuator/health`로 `db` 구성 요소를 한 번 더 확인한다 |
| EKS 관리형 노드 그룹이 스팟 회수 알림에 노드를 비우는가 | 비운다. 다만 최선 노력이다. 재조정 권고가 오면 교체 노드를 먼저 띄우고, 교체 노드가 준비되기 전에 2분 회수 알림이 오면 바로 비우기 시작한다. 파드가 2분을 다 받지 못할 수 있다 | AWS EKS 사용 설명서 "Simplify node lifecycle with managed node groups"의 Spot 절(Capacity Rebalancing 활성, "drains the node on a best-effort basis", 종료 유예 30초 이하 권장) |
| 승격 이미지에 OpenTelemetry 계측이 있는가 | 없다. BE 이미지는 `JarLauncher`로만 실행하고 Java 에이전트가 없다. Task 12에서 `otel.agent: true`(init 컨테이너로 에이전트 주입)를 쓴다 | BE `dockerfile`(eclipse-temurin:25-jre-noble, `ENTRYPOINT ["java", "org.springframework.boot.loader.launch.JarLauncher"]`), `build.gradle`에 opentelemetry 없음 |
| 2026-11-19 2회차 제출 4xx 18건의 원인 | 제출 횟수 제한이다. 사용자·문제마다 평생 5회이고 넘으면 429 `submission_limit_exceeded`다. k6는 VU마다 토큰 하나를 쓰므로 10 VU면 테스트 사용자 10명 × 저장 문제 20개 안에서 제출이 쌓이고, 2회차에 일부 조합이 5회를 넘었다. `seed.sql`이 매번 테스트 사용자 제출을 지우게 고쳤다 | 2026-11-20 pod-kill 실험 k6 로그: `status=429 body={"message":"submission_limit_exceeded","data":{"submitted_count":5,"submission_limit":5}}`. BE `CodeSubmission.MAX_SUBMISSION_COUNT = 5`, `code_submissions`에 (user_id, problem_id) 고유 제약 |

## 실험 설계에 미치는 영향

- 4xx 업무 거절은 실험 결과가 아니라 시드 상태에서 온다. 실험 전에는 `prepare.sh`를 다시 실행해 제출 기록을 지운다. 풀이 제출(AI)에도 같은 5회 제한(`solution_submission_limit_exceeded`)이 있으므로 `AI=1` 실험을 반복하면 같은 문제가 생긴다.

- S1 연쇄 관찰표 4번(Judge 콜백 유실)은 해당 없음이다. Task 10의 Judge 콜백 설정 변경은 하지 않는다. 대신 core의 Judge 조회 대기(`maxWait`) 동안 core 스레드가 묶이는지를 본다.
- S2에서 파드 종료 유예가 2분보다 짧아질 수 있으므로 단계 4의 `terminationGracePeriodSeconds`는 60이 아니라 30 이하로 둔다(AWS 권장).
- S3a 개선 전 예측: RDS 차단 → 준비 상태 검사 실패 → 모든 Spring 엔드포인트 제외 → Envoy가 직접 503(`upstream_cx_none_healthy`) → `CoreUnavailable`.
