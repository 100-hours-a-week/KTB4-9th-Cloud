# 실험 집계 계산 단위 테스트. 실행: python3 -m unittest discover -s v3-john/chaos/tests
import os, sys, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import aggregate as ag

T0 = 1_000_000  # 주입 시작

def series(pairs):
    return [(T0 + dt, v) for dt, v in pairs]

class Recovery(unittest.TestCase):
    def test_breach_then_recover_and_hold_one_minute(self):
        # 30초부터 오류율 50%, 240초부터 0 → 240초가 복구 시각(1분 유지 확인)
        s = series([(0, 0), (15, 0), (30, .5), (60, .5), (120, .5), (225, .5), (240, 0), (255, 0), (270, 0), (285, 0), (300, 0), (315, 0)])
        self.assertEqual(ag.recovery_seconds(s, T0, target=0.005), 240)

    def test_short_dip_inside_hold_window_does_not_count(self):
        # 240초에 내려갔다가 270초에 다시 넘음 → 300초부터 다시 1분 유지
        s = series([(30, .5), (240, 0), (255, 0), (270, .2), (300, 0), (315, 0), (330, 0), (345, 0), (360, 0), (375, 0)])
        self.assertEqual(ag.recovery_seconds(s, T0, target=0.005), 300)

    def test_never_breached_is_zero(self):
        self.assertEqual(ag.recovery_seconds(series([(0, 0), (60, 0.001), (120, 0)]), T0, target=0.005), 0)

    def test_not_recovered_by_end_is_none(self):
        self.assertIsNone(ag.recovery_seconds(series([(30, .5), (60, .5), (90, 0), (105, 0)]), T0, target=0.005))

    def test_nan_samples_are_ignored_not_treated_as_good(self):
        # 요청이 없어 NaN이면 복구로 보지 않는다
        s = series([(30, .5), (60, float("nan")), (75, float("nan")), (90, float("nan")), (105, float("nan")), (120, float("nan")), (135, float("nan"))])
        self.assertIsNone(ag.recovery_seconds(s, T0, target=0.005))

class Detection(unittest.TestCase):
    def test_first_symptom_alert_after_injection(self):
        alerts = {"CoreUnavailable": [T0 + 150, T0 + 165], "CoreErrorBudgetBurnFast": [T0 + 210], "PodCrashLooping": [T0 + 60]}
        self.assertEqual(ag.first_alert(alerts, T0, ag.SYMPTOM_ALERTS), ("CoreUnavailable", 150))

    def test_alert_already_firing_before_injection_is_ignored(self):
        alerts = {"CoreUnavailable": [T0 - 30, T0, T0 + 15]}
        self.assertIsNone(ag.first_alert(alerts, T0, ag.SYMPTOM_ALERTS))

    def test_no_alert(self):
        self.assertIsNone(ag.first_alert({}, T0, ag.SYMPTOM_ALERTS))

class Budget(unittest.TestCase):
    def test_spec_example_30min_full_outage_is_about_15_percent(self):
        self.assertAlmostEqual(ag.budget_percent(1.0, 30, slo=0.995), 14.88, places=2)

    def test_zero_failures(self):
        self.assertEqual(ag.budget_percent(0.0, 30, slo=0.995), 0.0)

class Verdict(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(ag.verdict(1500, {"a": "r1"}, {"a": "r1"}, aborted=None), [])

    def test_too_few_requests(self):
        self.assertIn("핵심 요청 999건(1,000건 미만)", ag.verdict(999, {}, {}, aborted=None))

    def test_revision_changed(self):
        r = ag.verdict(2000, {"prod-core": "r1", "prod-auth": "a"}, {"prod-core": "r2", "prod-auth": "a"}, aborted=None)
        self.assertEqual(r, ["실험 중 배포 변경: prod-core"])

    def test_scenario_own_merge_is_not_a_foreign_deploy(self):
        # S1은 주입 자체가 main 병합이라 모든 앱 리비전이 바뀐다. 시나리오가 남긴 병합 SHA는 제외한다.
        r = ag.verdict(2000, {"prod-core": "r1", "prod-auth": "r1"}, {"prod-core": "s1rev", "prod-auth": "s1rev"},
                       aborted=None, own=["s1rev"])
        self.assertEqual(r, [])

    def test_foreign_merge_after_scenario_is_flagged(self):
        r = ag.verdict(2000, {"prod-core": "r1"}, {"prod-core": "teammate"}, aborted=None, own=["s1rev"])
        self.assertEqual(r, ["실험 중 배포 변경: prod-core"])

    def test_aborted(self):
        self.assertEqual(ag.verdict(2000, {}, {}, aborted="vcpu"), ["중단: vcpu"])

class Clean(unittest.TestCase):
    def test_nan_becomes_null_and_counts_are_rounded(self):
        # 2026-11-20 noop: AI 요청이 없어 p95가 NaN으로 JSON에 들어가고, increase() 외삽으로 건수가 82.72였다
        out = ag.clean({"ai": {"p95_ms": float("nan")}, "judge": {"judge_completed": 82.72, "submit_p95_s": 1.17}})
        self.assertIsNone(out["ai"]["p95_ms"])
        self.assertEqual(out["judge"]["judge_completed"], 83)
        self.assertEqual(out["judge"]["submit_p95_s"], 1.17)

if __name__ == "__main__":
    unittest.main()
