import base64
import gzip
import json
import logging
import os
import urllib.request
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")

# 알림 분류 규칙
PATTERNS = [
    # 01:00 생성 배치 실패
    {
        "keywords": ["생성 배치 단계 실패", "생성 배치를 시작하지 못함"],
        "title": "🚨 [COSMOS AI] 새벽 01:00 문제 생성 배치 실패",
        "color": 0xE74C3C,  # 빨간색
    },
    # 01:00 생성 배치 경고
    {
        "keywords": ["채우지 못한 조합", "시도했지만 만들지 못함", "Spring 재고를 받지 못해"],
        "title": "⚠️ [COSMOS AI] 새벽 01:00 문제 생성 배치 경고",
        "color": 0xF1C40F,  # 노란색
    },
    # 01:00 생성 배치 성공
    {
        "keywords": ["일반 문제 생성 끝", "모든 조합의 재고가 충분해 일반 문제를 만들지 않음"],
        "title": "✅ [COSMOS AI] 새벽 01:00 문제 생성 배치 완료",
        "color": 0x2ECC71,  # 초록색
    },
    # 03:00 전송 배치 실패
    {
        "keywords": [
            "전송 배치 단계 실패",
            "전송 배치를 시작하지 못함",
            "데일리 전송 실패",
            "배틀 전송 실패",
            "일반 문제 전송을 멈춤",
            "Spring이 거부한 문제",
            "전송 표시에 실패함",
        ],
        "title": "🚨 [COSMOS AI] 새벽 03:00 Spring 문제 전송 배치 실패",
        "color": 0xE74C3C,  # 빨간색
    },
    # 03:00 전송 배치 성공
    {
        "keywords": ["일반 문제 전송 끝"],
        "title": "✅ [COSMOS AI] 새벽 03:00 Spring 문제 전송 배치 완료",
        "color": 0x2ECC71,  # 초록색
    },
]


def send_discord_embed(title: str, message: str, color: int) -> None:
    """디스코드 웹훅으로 서식화된 Embed 알림을 발송한다."""
    if not DISCORD_WEBHOOK_URL:
        logger.warning("DISCORD_WEBHOOK_URL이 설정되지 않아 알림을 건너뜁니다.")
        return

    # 디스코드 메시지 길이 제한(2000자) 대응
    clean_msg = message.strip()
    if len(clean_msg) > 1700:
        clean_msg = clean_msg[:1700] + "\n... (일부 생략)"

    payload = {
        "username": "COSMOS 배치 관제 봇",
        "embeds": [
            {
                "title": title,
                "description": f"```text\n{clean_msg}\n```",
                "color": color,
                "footer": {"text": "COSMOS ECS FastAPI CloudWatch 배치 모니터링"},
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }
        ],
    }

    try:
        req = urllib.request.Request(
            DISCORD_WEBHOOK_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "User-Agent": "COSMOS-CloudWatch-Lambda-Notifier",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            logger.info("디스코드 알림 발송 성공: HTTP %d", response.status)
    except Exception as e:
        logger.error("디스코드 웹훅 발송 실패: %s", e)


def handler(event, context):
    """CloudWatch Logs Subscription Filter 이벤트 수신 핸들러."""
    if "awslogs" not in event or "data" not in event["awslogs"]:
        logger.warning("CloudWatch Logs 페이로드가 없습니다: %s", event)
        return {"statusCode": 400, "body": "Invalid event"}

    # Base64 디코딩 및 Gzip 압축 해제
    try:
        compressed_payload = base64.b64decode(event["awslogs"]["data"])
        uncompressed_payload = gzip.decompress(compressed_payload)
        log_data = json.loads(uncompressed_payload)
    except Exception as e:
        logger.error("로그 데이터 압축 해제 실패: %s", e)
        return {"statusCode": 500, "body": "Decompression error"}

    log_events = log_data.get("logEvents", [])
    logger.info("수신된 로그 이벤트 수: %d", len(log_events))

    for log_event in log_events:
        message = log_event.get("message", "")
        for rule in PATTERNS:
            if any(keyword in message for keyword in rule["keywords"]):
                logger.info("규칙 매칭됨: %s", rule["title"])
                send_discord_embed(rule["title"], message, rule["color"])
                break  # 중복 알림 방지

    return {"statusCode": 200, "body": "Success"}
