-- 부하 테스트 전용 데이터. 실제 사용자 계정은 쓰지 않는다. 여러 번 실행해도 된다.
-- ID를 직접 넣는 테이블은 Hibernate 시퀀스와 겹치지 않게 900001부터 쓴다.
SET @today = DATE(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', '+09:00'));

-- 사용자 50명: loadtest-001 ~ loadtest-050
INSERT INTO users (username, created_at, updated_at)
SELECT CONCAT('loadtest-', LPAD(n, 3, '0')), NOW(6), NOW(6)
FROM (WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 50) SELECT n FROM s) t
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.username = CONCAT('loadtest-', LPAD(t.n, 3, '0')));

-- 랭킹 조회는 user_points 행이 있어야 200이다.
INSERT INTO user_points (user_point_id, current_correct_streak, last_correct_date, total_correct_problem_count, total_point, updated_at, user_id)
SELECT 900000 + u.id, 0, NULL, 0, 0, @today, u.id FROM users u
WHERE u.username LIKE 'loadtest-%' AND NOT EXISTS (SELECT 1 FROM user_points p WHERE p.user_id = u.id);

-- 문제 상세는 저장했거나 오늘의 데일리 문제여야 열린다. 최신 문제 20개를 저장해 둔다.
INSERT INTO saved_problems (problem_id, saved_at, user_id, category_known)
SELECT p.id, NOW(6), u.id, 0 FROM users u
JOIN (SELECT id FROM problems ORDER BY id DESC LIMIT 20) p
WHERE u.username LIKE 'loadtest-%'
  AND NOT EXISTS (SELECT 1 FROM saved_problems s WHERE s.user_id = u.id AND s.problem_id = p.id);

-- AI 배치(CronJob)가 정지돼 있어 오늘 데일리 문제가 없다. 데일리로 쓰인 적 없는 문제 3개를 오늘 문제로 둔다.
INSERT INTO daily_problems (id, display_order, recommend_date, problem_id)
SELECT 900000 + p.id, ROW_NUMBER() OVER (ORDER BY p.id), @today, p.id
FROM (SELECT id FROM problems WHERE id NOT IN (SELECT problem_id FROM daily_problems) ORDER BY id DESC LIMIT 3) p
WHERE NOT EXISTS (SELECT 1 FROM daily_problems WHERE recommend_date = @today);

-- prepare.sh가 읽는 결과: 사용자 ID 범위와 저장 문제 ID
SELECT CONCAT('USERS ', MIN(id), ' ', MAX(id)) FROM users WHERE username LIKE 'loadtest-%';
SELECT CONCAT('PROBLEMS ', GROUP_CONCAT(id ORDER BY id)) FROM (SELECT id FROM problems ORDER BY id DESC LIMIT 20) x;
