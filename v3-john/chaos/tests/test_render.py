# 실험 기록 md 생성 테스트.
import json, os, subprocess, sys, tempfile, unittest
LIB = os.path.join(os.path.dirname(__file__), "..", "lib")

SAMPLE = {
    "scenario": "s1", "step": "before", "testid": "s1-before-11201030",
    "times": {"k6_start": 1763600000, "inject": 1763600180, "stop": 1763600480, "end": 1763601080},
    "detection": {"alert": "CoreUnavailable", "seconds": 150},
    "recovery_seconds_core": 420,
    "journeys": {"core": {"requests": 5400, "errors_5xx": 900, "failure_ratio": 0.1667, "p95_ms": 31.0},
                 "major": {"requests": 2700, "errors_5xx": 0, "failure_ratio": 0.0, "p95_ms": 20.0}},
    "read_p95_ms": 48.0, "budget_percent_core": 49.6,
    "judge": {"submit_p95_s": 1.3, "judge_lost": 2, "judge_completed": 80, "submit_rejected": 1, "completion_ratio": 0.9756},
    "symptom_alerts_fired": ["CoreUnavailable"], "aborted": None, "verdict_blockers": [],
    "manual": {"declared_at": None, "severity": None, "mitigated_at": None, "cause_identified_at": None, "cause_evidence": None},
}

class Render(unittest.TestCase):
    def render(self, rec):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(rec, f)
        return subprocess.check_output([sys.executable, os.path.join(LIB, "render_record.py"), f.name], text=True)

    def test_machine_values_filled(self):
        md = self.render(SAMPLE)
        self.assertIn("| 탐지 시간 | 2분 30초 (CoreUnavailable) |", md)
        self.assertIn("| 복구 시간 | 7분 0초 |", md)
        self.assertIn("| 예산 소진량(핵심) | 49.6% |", md)
        self.assertIn("| core | 5400 | 16.67% | 31 |", md)
        self.assertIn("| 채점 완료율 | 97.56% (유실 2, 업무 거절 1) |", md)
        self.assertIn("판정 가능", md)

    def test_manual_fields_left_blank_for_human(self):
        md = self.render(SAMPLE)
        self.assertIn("| 선언 시간 | (사람이 적는다) |", md)
        self.assertIn("| 원인 파악 시간과 근거 | (사람이 적는다: 시각, 메트릭·로그·트레이스 중 무엇으로) |", md)

    def test_not_detected_and_not_recovered(self):
        rec = dict(SAMPLE, detection=None, recovery_seconds_core=None, verdict_blockers=["핵심 요청 900건(1,000건 미만)"])
        md = self.render(rec)
        self.assertIn("| 탐지 시간 | 탐지되지 않음 |", md)
        self.assertIn("| 복구 시간 | 관찰 구간 안에 회복하지 못함 |", md)
        self.assertIn("판정 불가: 핵심 요청 900건(1,000건 미만)", md)

if __name__ == "__main__":
    unittest.main()
