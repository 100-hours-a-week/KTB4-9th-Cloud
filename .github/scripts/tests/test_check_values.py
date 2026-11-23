# check-v3-john-values.py 단위 테스트: python3 -m unittest discover -s .github/scripts/tests
import os, subprocess, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "check-v3-john-values.py")
FX = os.path.join(HERE, "fixtures")

def run(*names):
    return subprocess.run([sys.executable, SCRIPT, *[os.path.join(FX, n) for n in names]], capture_output=True, text=True)

class CheckValues(unittest.TestCase):
    def test_ok(self):
        r = run("ok.yaml", "ok-fastapi.yaml")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_limit_below_request(self):
        r = run("bad-limit.yaml")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("bad-limit.yaml", r.stdout)
        self.assertIn("메모리 한도", r.stdout)

    def test_spring_without_heap_ratio(self):
        r = run("bad-heap.yaml")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("bad-heap.yaml", r.stdout)
        self.assertIn("MaxRAMPercentage", r.stdout)

    def test_heap_leaves_too_little_headroom(self):
        # S1 주입값: 448Mi에 힙 75%면 힙 밖이 112Mi다(메타스페이스, 스레드, OTel 에이전트에 모자라 기동 중 OOMKilled, 2026-11-23)
        r = run("bad-headroom.yaml")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("bad-headroom.yaml", r.stdout)
        self.assertIn("힙 밖", r.stdout)

    def test_reports_every_file(self):
        r = run("bad-limit.yaml", "bad-heap.yaml", "ok.yaml")
        self.assertIn("bad-limit.yaml", r.stdout)
        self.assertIn("bad-heap.yaml", r.stdout)
        self.assertNotIn("ok.yaml:", r.stdout)

if __name__ == "__main__":
    unittest.main()
