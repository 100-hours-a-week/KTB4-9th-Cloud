# S1' 풀 크기 편집기 테스트. 실행: python3 -m unittest v3-john/chaos/tests/test_set_pool.py
import os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scenarios", "s1p", "set_pool.py")
POOL = '  SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: "10"\n'
TIMEOUT = '  SPRING_DATASOURCE_HIKARI_CONNECTION_TIMEOUT: "3000"\n'


def run(text, n):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "core.yaml")
        open(p, "w").write(text)
        r = subprocess.run([sys.executable, SCRIPT, p, str(n)], capture_output=True, text=True)
        return r.returncode, open(p).read()


class SetPool(unittest.TestCase):
    def test_replaces_only_the_pool_line_and_keeps_quotes(self):
        rc, out = run("a: 1\n" + POOL + TIMEOUT + "b: 2\n", 40)
        self.assertEqual(rc, 0)
        self.assertEqual(out, "a: 1\n" + '  SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: "40"\n' + TIMEOUT + "b: 2\n")

    def test_other_hikari_line_unchanged(self):
        rc, out = run(POOL + TIMEOUT, 5)
        self.assertEqual(rc, 0)
        self.assertIn(TIMEOUT, out)

    def test_missing_line_exits_2(self):
        rc, out = run(TIMEOUT, 40)
        self.assertEqual(rc, 2)
        self.assertEqual(out, TIMEOUT)

    def test_duplicate_line_exits_2(self):
        rc, out = run(POOL + TIMEOUT + POOL, 40)
        self.assertEqual(rc, 2)
        self.assertEqual(out, POOL + TIMEOUT + POOL)


if __name__ == "__main__":
    unittest.main()
