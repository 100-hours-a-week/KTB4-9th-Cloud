-- 시드 덤프(2026-11-06 오레곤) 이후 BE에 추가된 스키마. stage는 ddl-auto: validate라 테이블이 없으면 앱이 기동하지 못한다.
-- restore-mysql.sh가 덤프 복원 직후 실행한다. 여러 번 실행해도 되게 IF NOT EXISTS로 둔다.
-- 시드 덤프를 새로 뜨면 이 파일의 내용은 덤프에 포함되므로 비워도 된다.

-- BE 186a758 (2026-11-09) 회원 탈퇴와 Daily battle 채점 이벤트 outbox
CREATE TABLE IF NOT EXISTS `outbox_events` (
  `outbox_event_id` bigint NOT NULL AUTO_INCREMENT,
  `battle_answer_payload` json NOT NULL,
  `battle_event_type` enum('GRADING_REQUESTED') NOT NULL,
  `battle_submission_event_status` enum('PENDING','PUBLISHING','PUBLISH_FAILED','SENT') NOT NULL,
  `created_at` datetime(6) NOT NULL,
  `participation_id` bigint NOT NULL,
  `published_at` datetime(6) DEFAULT NULL,
  `published_attempt_count` int NOT NULL,
  `publisher_lease_expires_at` timestamp(3) NULL DEFAULT NULL,
  `publisher_lease_token` binary(16) DEFAULT NULL,
  PRIMARY KEY (`outbox_event_id`),
  UNIQUE KEY `UKffgi16dms3tgnaioqrikteme0` (`participation_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
