# check-v3-john-values.py 단위 테스트: python3 -m unittest discover -s .github/scripts/tests
import importlib.util, os, subprocess, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "check-v3-john-values.py")
FX = os.path.join(HERE, "fixtures")

def run(*names):
    return subprocess.run([sys.executable, SCRIPT, *[os.path.join(FX, n) for n in names]], capture_output=True, text=True)

def load():
    spec = importlib.util.spec_from_file_location("check_values", SCRIPT)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def fx(*names):
    return [os.path.join(FX, *n.split("/")) for n in names]

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

class ConnectionBudget(unittest.TestCase):
    def test_budget_counts_rollout_surge(self):
        # core: rollout, hpa max 3, 풀 40이면 surge ceil(3 x 0.25)=1이라 (3+1) x 40 = 160
        total, lines = load().connection_budget(fx("budget-ok/core.yaml"))
        self.assertEqual(total, 160)
        self.assertIn("core.yaml", lines[0])

    def test_budget_deployment_surge(self):
        # auth: 롤링 업데이트, 차트 기본 maxSurge 1, hpa max 2, 풀 10이면 (2+1) x 10 = 30
        total, _ = load().connection_budget(fx("budget-ok/auth.yaml"))
        self.assertEqual(total, 30)

    def test_budget_default_pool(self):
        # 풀 줄이 없으면 Hikari 기본 10: (1+1) x 10 = 20
        total, _ = load().connection_budget(fx("ok.yaml"))
        self.assertEqual(total, 20)

    def test_budget_over_fails(self):
        r = run("budget-over/core.yaml", "budget-over/auth.yaml")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("연결 예산", r.stdout)
        self.assertIn("core.yaml", r.stdout)

    def test_budget_ok_passes(self):
        r = run("budget-ok/core.yaml", "budget-ok/auth.yaml")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_current_prod_values_pass(self):
        prod = os.path.join(HERE, "..", "..", "..", "v3-john", "gitops", "environments", "prod")
        files = sorted(os.path.join(prod, f) for f in os.listdir(prod) if f.endswith(".yaml"))
        r = subprocess.run([sys.executable, SCRIPT, *files], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

class MinimumIdle(unittest.TestCase):
    def test_missing_minimum_idle_fails(self):
        r = run("bad-minidle-missing.yaml")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("bad-minidle-missing.yaml", r.stdout)
        self.assertIn("최소 유휴 연결", r.stdout)

    def test_pool40_minimum_idle2_passes(self):
        r = run("ok-minidle-pool40.yaml")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_minimum_idle_above_half_fails(self):
        r = run("bad-minidle-high.yaml")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("최소 유휴 연결", r.stdout)

    def test_fastapi_not_checked(self):
        r = run("ok-fastapi.yaml")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

if __name__ == "__main__":
    unittest.main()
