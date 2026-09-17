"""Opt-in integration test against a running native app; no token is printed."""
import http.client
import json
import math
from pathlib import Path
import stat
import time
import unittest
import uuid


class NativeLiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.file = Path.home() / "Library/Application Support/FlyBug/bridge.json"
        if not cls.file.exists():
            raise unittest.SkipTest("Start FlyBug.app for native live tests")
        cls.config = json.loads(cls.file.read_text())
        cls.source = "native-test-" + uuid.uuid4().hex

    def request(self, path, body=None, token=None, extra=None, raw=False):
        conn = http.client.HTTPConnection("127.0.0.1", self.config["port"], timeout=3)
        headers = {"Authorization": "Bearer " + (self.config["token"] if token is None else token), "Content-Type": "application/json"}
        headers.update(extra or {})
        encoded = (body if raw else json.dumps(body)).encode() if body is not None else None
        try:
            conn.request("POST" if body is not None else "GET", path, encoded, headers)
            response = conn.getresponse()
            code, result = response.status, json.loads(response.read())
            return code, result
        finally:
            conn.close()

    def test_health_auth_and_private_discovery(self):
        self.assertEqual(stat.S_IMODE(self.file.stat().st_mode), 0o600)
        self.assertEqual(self.request("/health")[0], 200)
        self.assertEqual(self.request("/health", token="wrong")[0], 401)
        self.assertEqual(self.request("/health", extra={"Origin": "https://example.com"})[0], 401)

    def test_health_exposes_fresh_counts_and_coordinates_without_input_text(self):
        code, health = self.request("/health")
        self.assertEqual(code, 200)
        self.assertEqual(set(health), {
            "ok", "app", "version", "running", "accessibility", "screen", "textChecking",
            "checkSpelling", "textStatus", "inputMetadata", "writingIssueCount", "writingTargetCount",
            "currentSource", "flyTarget", "flyPosition", "sampledAt",
        })
        self.assertIs(health["ok"], True)
        self.assertEqual(health["app"], "FlyBug")
        self.assertIsInstance(health["version"], str)
        for key in ("running", "accessibility", "screen", "textChecking", "checkSpelling"):
            self.assertIsInstance(health[key], bool)
        self.assertIsInstance(health["textStatus"], str)
        self.assertGreater(len(health["textStatus"]), 0)
        self.assertIsInstance(health["inputMetadata"], dict)
        for key, value in health["inputMetadata"].items():
            self.assertIsInstance(key, str)
            self.assertIsInstance(value, str)
        for key in ("writingIssueCount", "writingTargetCount"):
            self.assertIs(type(health[key]), int)
            self.assertGreaterEqual(health[key], 0)
        self.assertLessEqual(health["writingTargetCount"], health["writingIssueCount"])
        self.assertIn(health["currentSource"], (None, "writing", "writing-demo", "demo", "screen", "accessibility", "bridge"))
        self.assertIsNotNone(health["flyPosition"])
        for key in ("flyTarget", "flyPosition"):
            point = health[key]
            if point is not None:
                self.assertEqual(set(point), {"x", "y"})
                self.assertTrue(all(isinstance(value, (int, float)) and math.isfinite(value) for value in point.values()))
        # A cached server response must still prove that the main-loop monitor is alive.
        self.assertLess(abs(time.time() - health["sampledAt"]), 5)

    def test_diagnostic_and_source_clear(self):
        body = {"source": self.source, "replace": True, "diagnostics": [
            {"id": "live-test", "source": self.source, "message": "FlyBug integration check", "severity": "error", "line": 3, "file": "/tmp/flybug-test.py"}]}
        try:
            self.assertEqual(self.request("/diagnostics", body), (200, {"ok": True}))
            body["diagnostics"][0]["line"] = -1
            self.assertEqual(self.request("/diagnostics", body)[0], 400)
        finally:
            self.assertEqual(self.request("/diagnostics", {"source": self.source, "replace": True, "diagnostics": []})[0], 200)

    def test_invalid_routes_and_json(self):
        self.assertEqual(self.request("/missing")[0], 404)
        self.assertEqual(self.request("/diagnostics", "{broken", raw=True)[0], 400)


if __name__ == "__main__":
    unittest.main()
