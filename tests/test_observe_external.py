"""Guard against a false external-input acceptance result; no live/UI access."""
import json
import unittest

import observe_external as observer


def healthy(**changes):
    result = {
        "ok": True, "running": True, "accessibility": True, "textChecking": True,
        "sampledAt": 100.0,
        "inputMetadata": {"stage": "ready", "appName": "Google Chrome", "focusRole": "AXTextField"},
        "textStatus": "Google Chrome · 当前输入未发现语法或拼写问题",
        "writingIssueCount": 0, "writingTargetCount": 0, "currentSource": None,
        "flyTarget": None, "flyPosition": {"x": 40, "y": 50},
    }
    result.update(changes)
    return result


class ExternalObservationTests(unittest.TestCase):
    def evaluate(self, health, expectation, app="Google Chrome", now=100.5):
        return observer.evaluate(health, expectation, app, now)

    def test_external_arrival_passes_with_actual_nearby_fly(self):
        sample = healthy(writingIssueCount=1, writingTargetCount=1, currentSource="writing",
                         flyTarget={"x": 41, "y": 51})
        self.assertTrue(self.evaluate(sample, "found")[0])

    def test_demo_arrival_never_proves_external_support(self):
        for source in ("writing-demo", "demo", "bridge"):
            sample = healthy(writingIssueCount=1, writingTargetCount=1, currentSource=source,
                             flyTarget={"x": 40, "y": 50})
            self.assertFalse(self.evaluate(sample, "found")[0], source)

    def test_fly_still_travelling_or_at_two_pixel_boundary_fails(self):
        for target in ({"x": 42, "y": 50}, {"x": 300, "y": 50}, None):
            sample = healthy(writingIssueCount=1, writingTargetCount=1, currentSource="writing", flyTarget=target)
            self.assertFalse(self.evaluate(sample, "found")[0])

    def test_clear_requires_completed_check_not_merely_zero_counts(self):
        self.assertTrue(self.evaluate(healthy(), "clear")[0])
        for status in ("正在检查 Google Chrome 的输入文字 · 停笔后检查",
                       "Google Chrome · 等待停笔，随后检查光标所在单词",
                       "系统文字检查服务暂未响应，稍后会自动重试",
                       "最近输入状态：Google Chrome · 当前输入未发现语法或拼写问题"):
            self.assertFalse(self.evaluate(healthy(textStatus=status), "clear")[0], status)

    def test_clear_rejects_existing_target_and_wrong_app(self):
        self.assertFalse(self.evaluate(healthy(flyTarget={"x": 40, "y": 50}), "clear")[0])
        self.assertFalse(self.evaluate(healthy(), "clear", app="TextEdit")[0])

    def test_protected_requires_actual_protected_state_and_zero_targets(self):
        sample = healthy(inputMetadata={"stage": "editable", "appName": "Google Chrome", "protected": "true"},
                         textStatus=observer.PROTECTED_STATUS)
        self.assertTrue(self.evaluate(sample, "protected")[0])
        sample["flyTarget"] = {"x": 40, "y": 50}
        self.assertFalse(self.evaluate(sample, "protected")[0])
        self.assertFalse(self.evaluate(healthy(), "protected")[0])

    def test_paused_untrusted_disabled_or_stale_state_cannot_pass(self):
        for change in ({"running": False}, {"accessibility": False}, {"textChecking": False},
                       {"sampledAt": 96}, {"sampledAt": float("nan")}):
            self.assertFalse(self.evaluate(healthy(**change), "clear")[0], change)

    def test_duplicate_cached_samples_do_not_meet_two_sample_requirement(self):
        tracker = observer.ConsecutiveMatches()
        sample = healthy()
        matched, _, summary = self.evaluate(sample, "clear")
        self.assertFalse(tracker.add(sample, matched, summary))
        self.assertFalse(tracker.add(sample, matched, summary))
        self.assertEqual(tracker.count, 1)
        sample["sampledAt"] = 100.1
        self.assertTrue(tracker.add(sample, matched, summary))

    def test_a_failure_resets_consecutive_successes(self):
        tracker = observer.ConsecutiveMatches()
        sample = healthy()
        matched, _, summary = self.evaluate(sample, "clear")
        self.assertFalse(tracker.add(sample, matched, summary))
        sample["sampledAt"] = 100.1
        self.assertFalse(tracker.add(sample, False, summary))
        sample["sampledAt"] = 100.2
        self.assertFalse(tracker.add(sample, matched, summary))
        self.assertEqual(tracker.count, 1)

    def test_output_whitelist_excludes_input_text_token_and_raw_status(self):
        sample = healthy(token="private-token", inputText="private-draft", diagnostic={"message": "private-draft"})
        sample["inputMetadata"]["value"] = "private-draft"
        _, _, summary = self.evaluate(sample, "clear")
        text = json.dumps(summary)
        self.assertNotIn("private-token", text)
        self.assertNotIn("private-draft", text)
        self.assertNotIn("textStatus", summary)

    def test_old_health_app_name_fallback_rejects_remembered_status(self):
        sample = healthy(inputMetadata={"stage": "ready"})
        self.assertEqual(observer.app_name(sample), "Google Chrome")
        sample["textStatus"] = "最近输入状态：" + sample["textStatus"]
        self.assertIsNone(observer.app_name(sample))

    def test_boolean_counts_are_not_valid_diagnostic_counts(self):
        self.assertFalse(self.evaluate(healthy(writingIssueCount=False), "clear")[0])


if __name__ == "__main__":
    unittest.main()
