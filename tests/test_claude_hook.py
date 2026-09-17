"""Verify explicit-failure gating and that hooks never alter the agent outcome."""
import contextlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "integrations" / "claude-hook.py"
spec = importlib.util.spec_from_file_location("flybug_claude_hook", SCRIPT)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
bridge = hook.load_bridge()


class ClaudeHookTests(unittest.TestCase):
    def payload(self, **changes):
        return {"hook_event_name": "PostToolUseFailure", "session_id": "abc123", "cwd": "/tmp/project",
                "tool_name": "Bash", "tool_input": {"command": "npm test"},
                "error": "Exit code 1\nError: actual test failure", "is_interrupt": False, **changes}

    def test_official_failure_shape_extracts_actual_source_line(self):
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder) / "example.py"
            file.write_text("def bad():\n    return 1 / 0\n")
            data = self.payload(cwd=folder, error=f'Exit code 1\n  File "{file}", line 2\nZeroDivisionError: division by zero')
            source, diagnostics = hook.diagnostics_for(data, bridge)
            self.assertEqual(source, "claude-code:abc123")
            self.assertEqual(diagnostics[0]["file"], str(file.resolve()))
            self.assertEqual(diagnostics[0]["line"], 2)
            self.assertEqual(diagnostics[0]["lineText"], "    return 1 / 0")

    def test_success_and_arbitrary_error_words_never_report(self):
        for response in ({"stdout": "error handling added", "stderr": "", "interrupted": False, "isImage": False},
                         {"stdout": "src/index.ts:4:2 error sample", "exit_code": 0},
                         {"stderr": "Error: text", "exit_code": "1"},
                         {"stderr": "Error: text", "exit_code": True}):
            with self.subTest(response=response):
                self.assertIsNone(hook.diagnostics_for(self.payload(hook_event_name="PostToolUse", tool_response=response), bridge))
        self.assertIsNone(hook.failure_text(self.payload(hook_event_name="Stop")))

    def test_post_tool_compatibility_requires_explicit_bash_exit(self):
        for key in ("exit_code", "exitCode"):
            data = self.payload(hook_event_name="PostToolUse", tool_response={key: 2, "stdout": "", "stderr": "src/index.ts(4,2): error TS2322: wrong type"})
            _, diagnostics = hook.diagnostics_for(data, bridge)
            self.assertEqual(diagnostics[0]["line"], 4)
            self.assertEqual(diagnostics[0]["column"], 2)
            data["tool_name"] = "Read"
            self.assertIsNone(hook.failure_text(data))

    def test_interruptions_never_report(self):
        self.assertIsNone(hook.failure_text(self.payload(is_interrupt=True)))
        self.assertIsNone(hook.failure_text(self.payload(hook_event_name="PostToolUse", tool_response={"exit_code": 130, "interrupted": True})))

    def test_failed_file_operation_preserves_file_without_inventing_line(self):
        data = self.payload(tool_name="Edit", error="Could not find old_string", tool_input={"file_path": "/tmp/example.py", "old_string": "wrong()"})
        _, items = hook.diagnostics_for(data, bridge)
        self.assertEqual(items[0]["file"], str(Path("/tmp/example.py").resolve()))
        self.assertNotIn("line", items[0])
        self.assertNotIn("lineText", items[0])

    def test_session_and_diagnostics_are_bounded(self):
        source = hook.source_for("a\n" * 10000)
        self.assertLessEqual(len(source), 80)
        self.assertNotIn("\n", source)
        self.assertEqual(source, hook.source_for("a\n" * 10000))
        data = self.payload(error="\n".join(f"src/file.ts:{line}:1 error: failure" for line in range(1, 100)))
        _, items = hook.diagnostics_for(data, bridge)
        self.assertEqual(len(items), 10)
        _, fallback = hook.diagnostics_for(self.payload(error="x" * 100000), bridge)
        self.assertLessEqual(len(fallback[0]["message"]), 2000)

    def test_main_is_silent_and_successful_for_offline_and_invalid_input(self):
        for raw in ("not JSON", "[]", "x" * (hook.MAX_INPUT + 1), json.dumps(self.payload())):
            with self.subTest(raw=raw[:60]), patch.dict(os.environ, {"FLYBUG_BRIDGE_FILE": "/tmp/flybug-no-such-claude-config.json"}):
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(hook.main(io.StringIO(raw)), 0)
                self.assertEqual(stdout.getvalue(), "")
                self.assertEqual(stderr.getvalue(), "")

    def test_stdin_has_own_deadline_even_without_eof(self):
        process = subprocess.Popen([sys.executable, str(SCRIPT)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            started = time.monotonic()
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertLess(time.monotonic() - started, 4.5)
            stdout, stderr = process.communicate()
            self.assertEqual((stdout, stderr), (b"", b""))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    def test_example_is_async_and_does_not_replace_tool_results(self):
        example = json.loads((ROOT / "integrations" / "claude-hooks.example.json").read_text())
        self.assertEqual(set(example["hooks"]), {"PostToolUseFailure", "PostToolUse"})
        for rules in example["hooks"].values():
            for rule in rules:
                for entry in rule["hooks"]:
                    self.assertIs(entry["async"], True)
                    self.assertIn('/ABSOLUTE/PATH/FlyBug/integrations/claude-hook.py', entry["command"])


class LocalHookHandler(http.server.BaseHTTPRequestHandler):
    records = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.records.append((self.path, self.headers.get("Authorization"), body))
        reply = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


class HookDeliveryTest(unittest.TestCase):
    def test_process_publishes_authenticated_failure_and_no_stdout(self):
        with tempfile.TemporaryDirectory() as folder:
            LocalHookHandler.records = []
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), LocalHookHandler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                config = Path(folder) / "bridge.json"
                config.write_text(json.dumps({"port": server.server_port, "token": "claude-hook-test-token"}))
                data = {"hook_event_name": "PostToolUseFailure", "session_id": "test-session", "cwd": folder,
                        "tool_name": "Bash", "tool_input": {"command": "npm test"},
                        "error": "Exit code 1\nsrc/main.ts:12:4 error: actual failed test"}
                result = subprocess.run([sys.executable, str(SCRIPT)], input=json.dumps(data), text=True, capture_output=True,
                                        env={**os.environ, "FLYBUG_BRIDGE_FILE": str(config)}, timeout=5)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
                path, authorization, body = LocalHookHandler.records[0]
                self.assertEqual(path, "/diagnostics")
                self.assertEqual(authorization, "Bearer claude-hook-test-token")
                self.assertEqual(body["source"], "claude-code:test-session")
                self.assertEqual(body["diagnostics"][0]["line"], 12)
                self.assertIs(body["replace"], True)
            finally:
                server.shutdown()
                server.server_close()
                worker.join()


if __name__ == "__main__":
    unittest.main()
