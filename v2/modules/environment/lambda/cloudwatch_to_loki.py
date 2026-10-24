"""Forward CloudWatch Logs subscription batches to the private Loki endpoint."""

import base64
import gzip
import json
import os
import urllib.request


USER_AGENT = "CWL_TO_LOKI/1.0"
LOKI_PUSH_PATH = "/loki/api/v1/push"


def _decode(event):
    compressed = base64.b64decode(event["awslogs"]["data"])
    return json.loads(gzip.decompress(compressed))


def _application(log_group):
    return log_group.rstrip("/").rsplit("/", 1)[-1]


def handler(event, _context):
    payload = _decode(event)
    if payload.get("messageType") == "CONTROL_MESSAGE":
        return {"forwarded": 0}

    events = payload.get("logEvents", [])
    if not events:
        return {"forwarded": 0}

    log_group = payload["logGroup"]
    application = _application(log_group)
    environment = os.environ["ENVIRONMENT"]
    stream = payload.get("logStream", "unknown")
    values = [[str(item["timestamp"] * 1_000_000), item["message"]] for item in events]
    body = json.dumps({
        "streams": [{
            "stream": {
                "application": application,
                "environment": environment,
                "log_group": log_group,
                "log_stream": stream,
            },
            "values": values,
        }]
    }, separators=(",", ":")).encode()

    request = urllib.request.Request(
        f"{os.environ['LOKI_BASE_URL'].rstrip('/')}{LOKI_PUSH_PATH}",
        data=body,
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=8) as response:
        if response.status != 204:
            raise RuntimeError(f"Loki returned HTTP {response.status}")

    return {"forwarded": len(values), "application": application}
