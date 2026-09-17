"""Behavioral checks for local bridge authentication, real diagnostics and output."""
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
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bridge/flybug.py"
spec = importlib.util.spec_from_file_location("flybug_bridge", SCRIPT)
flybug = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flybug)


class ParsingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.cwd = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def test_python_traceback_finds_actual_statement(self):
        file = self.cwd / "space here.py"
        file.write_text("def bad():\n    return 1 / 0\nbad()\n")
        output = f'Traceback (most recent call last):\n  File "{file}", line 3, in <module>\n    bad()\n  File "{file}", line 2, in bad\n    return 1 / 0\nZeroDivisionError: division by zero\n'
        items = flybug.parse_diagnostics(output, self.cwd)
        self.assertEqual(items[0]["line"], 2)
        self.assertEqual(items[0]["lineText"], "    return 1 / 0")
        self.assertEqual(items[0]["message"], "ZeroDivisionError: division by zero")
        self.assertEqual(items[0]["file"], str(file.resolve()))

    def test_typescript_compiler_and_deduplication(self):
        output = '\x1b[31msrc/app.ts(12,4): error TS2322: Type mismatch\x1b[0m\nsrc/app.ts(12,4): error TS2322: Type mismatch'
        items = flybug.parse_diagnostics(output, self.cwd)
        self.assertEqual(len(items), 1)
        self.assertEqual((items[0]["line"], items[0]["column"]), (12, 4))
        self.assertNotIn("\x1b", items[0]["message"])

    def test_javascript_file_url_and_spaces(self):
        output = 'TypeError: cannot read property\n    at handler (file:///tmp/my%20code/index.js:9:2)'
        item = flybug.parse_diagnostics(output, self.cwd)[0]
        self.assertEqual(item["file"], str(Path("/tmp/my code/index.js").resolve()))
        self.assertEqual(item["line"], 9)
        output = 'Error: test\n    at handler (/tmp/my code/index.js:8:3)'
        self.assertEqual(flybug.parse_diagnostics(output, self.cwd)[0]["file"], str(Path("/tmp/my code/index.js").resolve()))

    def test_rust_arrow_location(self):
        output = 'error[E0308]: mismatched types\n --> src/main.rs:4:13\n  |\n4 | let x: i32 = "hello";'
        item = flybug.parse_diagnostics(output, self.cwd)[0]
        self.assertEqual(item["line"], 4)
        self.assertEqual(item["column"], 13)
        self.assertIn("mismatched types", item["message"])

    def test_success_text_is_not_invented_as_diagnostic(self):
        self.assertEqual(flybug.parse_diagnostics("Build completed in 3.2s", self.cwd), [])

    def test_long_unstructured_noise_has_bounded_parse_time(self):
        code = (
            "import sys,random,string; from pathlib import Path; "
            f"sys.path.insert(0, {str(ROOT / 'bridge')!r}); import flybug; "
            "noise=''.join(random.Random(12).choices(string.ascii_letters+string.digits+'./_', k=96000)); "
            "assert flybug.parse_diagnostics(noise, Path.cwd()) == []; "
            "assert flybug.parse_live_diagnostics(noise+'\\n', Path.cwd(), 'terminal') == []"
        )
        # Previously a 64 KB single line took about 20 seconds of regex backtracking.
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, timeout=2.5)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def test_stable_identity(self):
        first = flybug.make_diagnostic("cli", "bad", file="file.py", line=1)
        second = flybug.make_diagnostic("cli", "bad", file="file.py", line=1)
        self.assertEqual(first["id"], second["id"])


class MockHandler(http.server.BaseHTTPRequestHandler):
    records = []
    def log_message(self, *args):
        pass
    def do_GET(self):
        self._reply(None)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self._reply(body)
    def _reply(self, body):
        self.records.append((self.command, self.path, dict(self.headers), body))
        data = b'{"ok":true}'
        self.send_response(200 if self.headers.get("Authorization") == "Bearer local-test-secret" else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.file = Path(self.temp.name) / "bridge.json"
        MockHandler.records = []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.file.write_text(json.dumps({"port": self.server.server_port, "token": "local-test-secret", "pid": 1,
                                        "host": "untrusted.invalid"}))
        self.env = {**os.environ, "FLYBUG_BRIDGE_FILE": str(self.file)}
        self.patch = patch.dict(os.environ, {"FLYBUG_BRIDGE_FILE": str(self.file)})
        self.patch.start()
    def tearDown(self):
        self.patch.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_auth_envelope_and_health(self):
        self.assertEqual(flybug.request("GET", "/health"), {"ok": True})
        issue = flybug.make_diagnostic("unit-test", "测试错误", line=2)
        flybug.publish([issue], "unit-test")
        method, endpoint, headers, body = MockHandler.records[-1]
        self.assertEqual((method, endpoint), ("POST", "/diagnostics"))
        self.assertEqual(headers["Authorization"], "Bearer local-test-secret")
        self.assertEqual(body, {"source": "unit-test", "replace": True, "diagnostics": [issue]})
        flybug.publish([], "unit-test")
        self.assertEqual(MockHandler.records[-1][3]["diagnostics"], [])

    def test_discovery_is_reread_and_rejects_bad_auth(self):
        flybug.request("GET", "/health")
        self.file.write_text(json.dumps({"port": self.server.server_port, "token": "wrong"}))
        with self.assertRaises(flybug.BridgeError):
            flybug.request("GET", "/health")

    def test_run_preserves_streams_exit_and_diagnostic(self):
        program = Path(self.temp.name) / "fails.py"
        program.write_text('import sys\nprint("OUT", flush=True)\nprint("ERR", file=sys.stderr, flush=True)\nraise ValueError("actual failure")\n')
        result = subprocess.run([sys.executable, str(SCRIPT), "run", "--", sys.executable, str(program)],
                                capture_output=True, env=self.env, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"OUT\n")
        self.assertIn(b"ERR\nTraceback", result.stderr)
        self.assertIn(b"ValueError: actual failure", result.stderr)
        body = MockHandler.records[-1][3]
        self.assertEqual(body["diagnostics"][0]["line"], 4)
        self.assertEqual(body["diagnostics"][0]["lineText"], 'raise ValueError("actual failure")')

    def test_success_clears_source_and_does_not_block_for_stdin(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "run", "--source", "my-tests", "--",
                                 sys.executable, "-c", "import sys; print(repr(sys.stdin.read()))"],
                                capture_output=True, env=self.env, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"''\n")
        self.assertEqual(MockHandler.records[-1][3], {"source": "my-tests", "replace": True, "diagnostics": []})

    def test_offline_never_hides_original_exit_or_output(self):
        env = {**self.env, "FLYBUG_BRIDGE_FILE": str(self.file) + ".missing"}
        result = subprocess.run([sys.executable, str(SCRIPT), "run", "--", sys.executable, "-c",
                                 "import sys; print('still visible'); sys.exit(7)"],
                                capture_output=True, env=env, timeout=10)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, b"still visible\n")
        self.assertIn("原命令退出码仍为 7".encode(), result.stderr)

    def test_output_larger_than_capture_limit_is_not_truncated(self):
        length = flybug.MAX_CAPTURE + 1000
        result = subprocess.run([sys.executable, str(SCRIPT), "run", "--", sys.executable, "-c",
                                 f"import sys; sys.stdout.write('x' * {length})"],
                                capture_output=True, env=self.env, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout), length)




class LiveParsingTests(unittest.TestCase):
    def test_ai_prose_and_fenced_examples_do_not_create_diagnostics(self):
        text = "There might be an error in src/main.ts:4:2.\n```\nsrc/main.ts(4,2): error TS2322: example\n```\n"
        self.assertEqual(flybug.parse_live_diagnostics(text, Path.cwd(), "codex"), [])

    def test_real_compiler_error_and_stack_trace_are_reported(self):
        text = "src/main.ts(4,2): error TS2322: Type mismatch\n"
        items = flybug.parse_live_diagnostics(text, Path.cwd(), "codex")
        self.assertEqual(items[0]["line"], 4)
        self.assertEqual(items[0]["source"], "codex")
        self.assertEqual(flybug.parse_live_diagnostics(text.rstrip(), Path.cwd(), "codex"), [])
        text = 'Traceback (most recent call last):\n  File "example.py", line 3, in run\nValueError: invalid value\n'
        self.assertEqual(flybug.parse_live_diagnostics(text, Path.cwd(), "claude")[0]["line"], 3)

    def test_explicit_test_runner_failure_is_reported_without_location(self):
        # Persistent shells do not exit after a failed command, so the live
        # parser must publish clear test-runner status lines before exit.
        items = flybug.parse_live_diagnostics("FAIL tests/api.test.ts\n", Path.cwd(), "terminal")
        self.assertEqual(len(items), 1)
        self.assertIn("FAIL", items[0]["message"])
        self.assertEqual(items[0]["source"], "terminal")


@unittest.skipUnless(os.name == "posix", "requires POSIX PTYs")
class PtyTests(unittest.TestCase):
    setUp = ConnectionTests.setUp
    tearDown = ConnectionTests.tearDown

    def start_pty(self, code=None, *, offline=False, command=None):
        import pty
        import termios
        master, slave = pty.openpty()
        self.master, self.slave = master, slave
        self.before_attributes = termios.tcgetattr(slave)
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        env = {**self.env}
        if offline:
            env["FLYBUG_BRIDGE_FILE"] += ".missing"
        child_command = command or [sys.executable, "-u", "-c", code]
        self.process = subprocess.Popen([sys.executable, str(SCRIPT), "pty", "--source", "codex", "--",
                                         *child_command], stdin=slave, stdout=slave, stderr=slave, env=env)
        self.addCleanup(self.stop_process)
        self.output = bytearray()

    def stop_process(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()

    def read_until(self, predicate, timeout=7):
        import errno
        import select
        import time
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("PTY timed out: " + self.output.decode(errors="replace"))
            readable, _, _ = select.select([self.master], [], [], 0.05)
            if readable:
                try:
                    data = os.read(self.master, 8192)
                except OSError as exc:
                    if exc.errno != errno.EIO:
                        raise
                    data = b""
                self.output.extend(data)

    def finish(self):
        self.read_until(lambda: self.process.poll() is not None)
        # Drain bytes already emitted before exit while the test retains the slave.
        import select
        while select.select([self.master], [], [], 0.05)[0]:
            self.output.extend(os.read(self.master, 8192))
        import termios
        after = termios.tcgetattr(self.slave)
        # macOS sets PENDIN while re-enabling canonical input; it is runtime state.
        after[3] &= ~getattr(termios, "PENDIN", 0)
        expected = list(self.before_attributes)
        expected[3] &= ~getattr(termios, "PENDIN", 0)
        self.assertEqual(after, expected, "outer terminal settings must be restored")
        return self.process.returncode

    def test_real_tty_input_and_default_size(self):
        self.start_pty("import os,sys; print('TTY',sys.stdin.isatty(),sys.stdout.isatty()); print('SIZE',tuple(os.get_terminal_size(0))); print('READY'); print('GOT',input())")
        self.read_until(lambda: b"READY" in self.output)
        os.write(self.master, b"hello fly\n")
        self.assertEqual(self.finish(), 0)
        self.assertIn(b"TTY True True", self.output)
        self.assertIn(b"SIZE (80, 24)", self.output)
        self.assertIn(b"GOT hello fly", self.output)
        self.assertEqual(MockHandler.records[-1][3]["diagnostics"], [])

    def test_resize_is_forwarded(self):
        import fcntl
        import signal
        import struct
        import termios
        self.start_pty("import os,signal; signal.signal(signal.SIGWINCH, lambda *_: print('RESIZE',tuple(os.get_terminal_size(0)),flush=True)); print('READY'); input()")
        self.read_until(lambda: b"READY" in self.output)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 120, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)
        self.read_until(lambda: b"RESIZE (120, 50)" in self.output)
        os.write(self.master, b"\n")
        self.assertEqual(self.finish(), 0)

    def test_ctrl_c_reaches_child_and_restores_terminal(self):
        self.start_pty("import time; print('WAIT'); time.sleep(20)")
        self.read_until(lambda: b"WAIT" in self.output)
        os.write(self.master, b"\x03")
        self.assertEqual(self.finish(), 130)
        self.assertIn(b"KeyboardInterrupt", self.output)

    def test_offline_preserves_exit_seven(self):
        self.start_pty("import sys; print('STILL VISIBLE'); sys.exit(7)", offline=True)
        self.assertEqual(self.finish(), 7)
        self.assertIn(b"STILL VISIBLE", self.output)
        self.assertIn("原命令退出码仍为 7".encode(), self.output)

    def test_live_error_is_sent_before_exit_then_cleared(self):
        self.start_pty("print('src/example.ts(12,3): error TS2322: Type mismatch'); print('READY'); input()")
        self.read_until(lambda: any(record[3] and record[3].get("diagnostics") for record in MockHandler.records))
        diagnostic = next(record[3]["diagnostics"][0] for record in MockHandler.records if record[3].get("diagnostics"))
        self.assertEqual(diagnostic["line"], 12)
        self.assertEqual(diagnostic["source"], "codex")
        self.assertIsNone(self.process.poll())
        os.write(self.master, b"done\n")
        self.assertEqual(self.finish(), 0)
        self.assertEqual(MockHandler.records[-1][3]["diagnostics"], [])

    @unittest.skipUnless(Path("/bin/zsh").exists(), "zsh unavailable")
    def test_shell_reports_inner_failure_while_alive_then_exits_zero(self):
        import shlex
        program = Path(self.temp.name) / "shell_failure.py"
        program.write_text('raise ValueError("real shell command failed")\n')
        self.start_pty(command=["/bin/zsh", "-f"])
        command = f"{shlex.quote(sys.executable)} {shlex.quote(str(program))}\necho SHELL_STILL_ALIVE\n"
        os.write(self.master, command.encode())
        self.read_until(lambda: any(record[3] and record[3].get("diagnostics") for record in MockHandler.records))
        item = next(record[3]["diagnostics"][0] for record in MockHandler.records if record[3].get("diagnostics"))
        self.assertEqual(item["file"], str(program.resolve()))
        self.assertEqual(item["line"], 1)
        self.assertIsNone(self.process.poll(), "the login shell must remain interactive after the inner failure")
        os.write(self.master, b"true\nexit 0\n")
        self.assertEqual(self.finish(), 0)
        self.assertEqual(MockHandler.records[-1][3]["diagnostics"], [])

    def test_piped_input_is_rejected_with_actionable_message(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "pty", "--", sys.executable, "-c", "input()"],
                                input=b"hello\n", capture_output=True, env=self.env, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("pty 需要交互式终端".encode(), result.stderr)


if __name__ == "__main__":
    unittest.main()
