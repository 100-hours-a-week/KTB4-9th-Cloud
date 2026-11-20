# baseline.js 분류 테스트용 가짜 API. 제출은 문제 ID로 결과를 고른다.
#   1 → 200 COMPLETED(성공), 2 → 400(업무 거절), 3 → 500(유실), 4 → 200 PENDING(유실)
# 풀이 제출은 202와 평가 작업 ID(=문제 ID)를 주고, 평가 조회는 1이면 SUCCEEDED, 2면 FAILED, 그 밖은 계속 PENDING이다.
import json, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        m = re.search(r"/solution-evaluations/(\d+)", self.path)
        if m:
            st = {1: "SUCCEEDED", 2: "FAILED"}.get(int(m.group(1)), "PENDING")
            return self.send(200, {"data": {"status": st}})
        self.send(200, {"data": {}})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        s = re.search(r"/problems/(\d+)/solution-submissions", self.path)
        if s:
            return self.send(202, {"data": {"evaluationTaskId": int(s.group(1)), "status": "PENDING"}})
        m = re.search(r"/problems/(\d+)/code-submissions", self.path)
        pid = int(m.group(1)) if m else 0
        if pid == 1: self.send(200, {"data": {"judging_status": "COMPLETED"}})
        elif pid == 2: self.send(400, {"code": "ALREADY_SUBMITTED", "message": "mock reject"})
        elif pid == 3: self.send(500, {"message": "mock error"})
        else: self.send(200, {"data": {"judging_status": "PENDING"}})

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
