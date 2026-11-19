# 부하 테스트용 사용자(loadtest-001~050, id 92~141)의 accessToken JWT를 만든다.
# 서명 키는 Secrets Manager에서 읽어 메모리에서만 쓰고 출력하지 않는다.
import base64, hashlib, hmac, json, subprocess, sys, time
out, first, last, ttl = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
raw = subprocess.check_output(["aws", "secretsmanager", "get-secret-value", "--region", "ap-northeast-2",
    "--secret-id", "/cosmos-v2/stage/spring", "--query", "SecretString", "--output", "text"])
key = base64.b64decode(json.loads(raw)["jwt_secret"])
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time()); toks = []
for i, uid in enumerate(range(first, last + 1), 1):
    h = b64(json.dumps({"alg": "HS256"}, separators=(",", ":")).encode())
    p = b64(json.dumps({"sub": str(uid), "username": f"loadtest-{i:03d}", "iat": now, "exp": now + ttl}, separators=(",", ":")).encode())
    s = b64(hmac.new(key, f"{h}.{p}".encode(), hashlib.sha256).digest())
    toks.append(f"{h}.{p}.{s}")
json.dump(toks, open(out, "w")); print(f"{len(toks)}개 토큰 생성, 유효 {ttl // 60}분")
