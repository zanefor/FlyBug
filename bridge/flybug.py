#!/usr/bin/env python3
"""Send local editor/test diagnostics to FlyBug. Python 3 standard library only."""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import queue
import time
from urllib.parse import unquote, urlparse

DEFAULT_BRIDGE_FILE = Path.home() / "Library/Application Support/FlyBug/bridge.json"
MAX_CAPTURE = 200_000
MAX_PARSE_LINE = 2000
ANSI = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")
PYTHON_FRAME = re.compile(r'File ["\'](?P<path>.+?)["\'], line (?P<line>\d+)')
TS_LOCATION = re.compile(r"^\s*(?P<path>.+?\.[cm]?[jt]sx?)\((?P<line>\d+),(?P<column>\d+)\)")
EXTENSIONS = r"py|pyi|js|jsx|ts|tsx|mjs|cjs|rs|c|cpp|cc|cxx|h|hpp|java|kt|go|swift|php|rb|lua|cs|vue|svelte"
COLON_LOCATION = re.compile(
    r"(?P<path>(?:file://)?(?:[A-Za-z]:)?[^\s():<>]+?\.(?:" + EXTENSIONS + r")):(?P<line>\d+)(?::(?P<column>\d+))?"
)
# A stack frame wrapped in parentheses can safely contain spaces in its path.
PAREN_LOCATION = re.compile(r"\((?P<path>[^()]+?\.(?:" + EXTENSIONS + r")):(?P<line>\d+):(?P<column>\d+)\)")
ERROR_LINE = re.compile(r"(?:\b(?:[A-Za-z]*Error|Exception|panic|FAILED|error|fatal)\b|^E\s+)", re.I)


class BridgeError(RuntimeError):
    pass


def discovery_path() -> Path:
    return Path(os.environ.get("FLYBUG_BRIDGE_FILE", str(DEFAULT_BRIDGE_FILE))).expanduser()


def request(method: str, endpoint: str, payload: dict | None = None) -> dict:
    """Discover on each request, and never connect anywhere except IPv4 loopback."""
    try:
        config = json.loads(discovery_path().read_text(encoding="utf-8"))
        port, token = config["port"], config["token"]
        if type(port) is not int or not 1 <= port <= 65535 or not isinstance(token, str) or not token:
            raise ValueError("invalid port or token")
        if "\r" in token or "\n" in token:
            raise ValueError("invalid token")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise BridgeError("找不到 FlyBug 本地连接信息，请先启动 FlyBug。") from exc
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8") if payload is not None else None
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2.0)
    try:
        conn.request(method, endpoint, body=body, headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json; charset=utf-8",
        })
        response = conn.getresponse()
        data = response.read(65_537)
        if response.status != 200:
            raise BridgeError(f"FlyBug 拒绝连接（HTTP {response.status}），请重新启动 FlyBug 后重试。")
        if len(data) > 65_536:
            raise BridgeError("FlyBug 响应过大。")
        parsed = json.loads(data)
        if not isinstance(parsed, dict):
            raise ValueError("response must be an object")
        return parsed
    except BridgeError:
        raise
    except (OSError, http.client.HTTPException, ValueError) as exc:
        raise BridgeError("无法连接 FlyBug，请确认它仍在运行。") from exc
    finally:
        conn.close()


def read_line(path: Path, line: int) -> str | None:
    try:
        if not path.is_file() or path.stat().st_size > 2_000_000:
            return None
        with path.open(encoding="utf-8", errors="replace") as stream:
            for number, text in enumerate(stream, 1):
                if number == line:
                    return text.rstrip("\r\n")[:1000]
    except OSError:
        pass
    return None


def normalize_path(raw: str, cwd: Path) -> Path:
    if raw.startswith("file://"):
        raw = unquote(urlparse(raw).path)
    path = Path(raw).expanduser()
    return (path if path.is_absolute() else cwd / path).resolve()


def make_diagnostic(source: str, message: str, *, severity: str = "error", file: str | None = None,
                    line: int | None = None, column: int | None = None, line_text: str | None = None) -> dict:
    message = message[:2000]
    line_text = line_text[:1000] if line_text is not None else None
    identity = json.dumps([source, file, line, column, message], ensure_ascii=False)
    item = {"id": hashlib.sha256(identity.encode()).hexdigest()[:24], "source": source,
            "message": message, "severity": severity}
    for key, value in (("file", file), ("line", line), ("column", column), ("lineText", line_text)):
        if value is not None:
            item[key] = value
    return item


def parse_diagnostics(output: str, cwd: Path, source: str = "cli") -> list[dict]:
    """Extract locations from actual failed-command output; never infer logic errors."""
    # Bound each regex input; minified/noise lines must not stall a live terminal.
    lines = [line[:MAX_PARSE_LINE] for line in ANSI.sub("", output).splitlines()]
    summaries = [line.strip() for line in lines if ERROR_LINE.search(line) and line.strip()]
    fallback = summaries[-1] if summaries else "命令运行失败"
    found = []
    seen = set()
    for text in lines:
        if not ("File " in text or ("." in text and (":" in text or "(" in text))):
            continue
        match = PYTHON_FRAME.search(text) or TS_LOCATION.search(text) or PAREN_LOCATION.search(text) or COLON_LOCATION.search(text)
        if not match:
            continue
        number = int(match.group("line"))
        if number < 1:
            continue
        raw_column = match.groupdict().get("column")
        column = max(1, int(raw_column)) if raw_column else 1
        path = normalize_path(match.group("path"), cwd)
        key = (str(path), number, column)
        if key in seen:
            continue
        seen.add(key)
        message = text.strip() if ERROR_LINE.search(text) else fallback
        found.append(make_diagnostic(source, message, file=str(path), line=number, column=column,
                                     line_text=read_line(path, number)))
    # The last Python/JS frames usually identify the actual failing user statement.
    return found[-20:][::-1]


def publish(diagnostics: list[dict], source: str) -> dict:
    return request("POST", "/diagnostics", {"source": source, "replace": True, "diagnostics": diagnostics})


def _write_bytes(destination, data: bytes) -> None:
    binary = getattr(destination, "buffer", None)
    if binary is not None:
        binary.write(data)
        binary.flush()
    else:
        destination.write(data.decode("utf-8", errors="replace"))
        destination.flush()


def run_command(command: list[str], source: str) -> int:
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("run 后需要命令，例如：run -- python3 test.py")
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        print(f"flybug: 无法运行命令：{exc}", file=sys.stderr)
        return 127
    captures = [bytearray(), bytearray()]
    def pump(pipe, destination, captured):
        try:
            while True:
                data = os.read(pipe.fileno(), 8192)
                if not data:
                    break
                _write_bytes(destination, data)
                captured.extend(data)
                if len(captured) > MAX_CAPTURE:
                    del captured[:-MAX_CAPTURE]
        finally:
            pipe.close()
    threads = [threading.Thread(target=pump, args=(process.stdout, sys.stdout, captures[0]), daemon=True),
               threading.Thread(target=pump, args=(process.stderr, sys.stderr, captures[1]), daemon=True)]
    for thread in threads:
        thread.start()
    interrupted = False
    try:
        code = process.wait()
    except KeyboardInterrupt:
        interrupted = True
        process.terminate()
        try:
            code = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            code = process.wait()
    # Child/grandchild programs may leave pipes open; a completed command must still return.
    for thread in threads:
        thread.join(timeout=1)
    exit_code = 130 if interrupted else (code if code >= 0 else 128 - code)
    output = b"\n".join(bytes(capture) for capture in captures).decode("utf-8", errors="replace")
    diagnostics = parse_diagnostics(output, Path.cwd(), source) if exit_code else []
    if exit_code and not diagnostics:
        tail = [line.strip() for line in ANSI.sub("", output).splitlines() if line.strip()]
        message = f"命令退出码 {exit_code}：{tail[-1] if tail else command[0]}"
        diagnostics = [make_diagnostic(source, message)]
    try:
        publish(diagnostics, source)
    except BridgeError as exc:
        print(f"flybug: {exc}（原命令退出码仍为 {exit_code}）", file=sys.stderr)
    return exit_code



# Live terminal output needs stronger evidence than the failed-command parser:
# source excerpts and ordinary AI prose containing the word "error" are ignored.
LIVE_EXCEPTION = re.compile(r"^\s*(?:[A-Za-z_][\w.]*(?:Error|Exception)|Error|Exception):\s*\S")
LIVE_COMPILER = re.compile(
    r"^\s*[^\n]+\.(?:" + EXTENSIONS + r")(?:\(\d+,\d+\)|:\d+(?::\d+)?):\s*(?:fatal\s+)?(?:error\b|[\w.]*(?:Error|Exception):)", re.I
)
LIVE_RUST = re.compile(r"^\s*error\[E\d+\]:\s*\S")
LIVE_PANIC = re.compile(r"^\s*(?:panic:\s*\S|thread ['\"].+['\"] panicked at\b)")
# Test runners and build tools often report a failure without a source
# location (for example ``FAIL tests/api.test.ts``).  These prefixes are
# explicit command-status markers, unlike ordinary prose that merely mentions
# the word "error"; reporting them lets the desktop bridge acknowledge a
# failing command and use its visible-window fallback when no line is known.
LIVE_TEST_FAILURE = re.compile(
    r"^\s*(?:FAIL(?:ED)?\b|FAILED\b|(?:npm|yarn|pnpm|cargo|go|make)\s+(?:ERR!|error|failed)\b)\s*\S*",
    re.I,
)


def parse_live_diagnostics(output: str, cwd: Path, source: str) -> list[dict]:
    """Recognize traceback/compiler structures, not arbitrary mentions in AI prose."""
    clean = ANSI.sub("", output).replace("\r\n", "\n").replace("\r", "\n")
    # Cap regex work independently of the bounded full capture.
    lines = [line[:MAX_PARSE_LINE] for line in clean.split("\n")[:-1]]  # Complete lines only.
    visible = []
    fenced = False
    for line in lines:
        if line.strip().startswith("```"):
            fenced = not fenced
            visible.append("")
        else:
            visible.append("" if fenced else line)
    blocks = []
    for i, line in enumerate(visible):
        if LIVE_COMPILER.match(line):
            blocks.append(line)
        elif line.strip() == "Traceback (most recent call last):":
            end = next((j for j in range(i + 1, min(i + 100, len(visible))) if LIVE_EXCEPTION.match(visible[j])), None)
            if end is not None and any(PYTHON_FRAME.search(row) for row in visible[i:end]):
                blocks.append("\n".join(visible[i:end + 1]))
        elif LIVE_EXCEPTION.match(line):
            frames = []
            for row in visible[i + 1:i + 30]:
                if not re.match(r"^\s+at\s+", row):
                    break
                frames.append(row)
            if any(PAREN_LOCATION.search(row) or COLON_LOCATION.search(row) for row in frames):
                blocks.append("\n".join([line] + frames))
        elif LIVE_RUST.match(line):
            context = visible[i:min(i + 9, len(visible))]
            if any(re.match(r"^\s*-->\s+", row) and COLON_LOCATION.search(row) for row in context):
                blocks.append("\n".join(context))
        elif LIVE_PANIC.match(line):
            blocks.append("\n".join(visible[i:min(i + 8, len(visible))]))
        elif LIVE_TEST_FAILURE.match(line):
            blocks.append(line)
    found = []
    seen = set()
    for block in blocks:
        items = parse_diagnostics(block, cwd, source)
        if not items:
            items = [make_diagnostic(source, block.splitlines()[0].strip())]
        for item in items:
            if item["id"] not in seen:
                found.append(item)
                seen.add(item["id"])
    return found[-20:]


class _TerminalReporter:
    """One daemon owns network I/O; a busy server can never stall terminal relay."""
    def __init__(self, source: str):
        self.source = source
        self.pending = queue.Queue(maxsize=1)
        self.last_error = None
        self.thread = threading.Thread(target=self._work, daemon=True)
        self.thread.start()

    def submit(self, diagnostics: list[dict], final: bool = False) -> None:
        try:
            self.pending.get_nowait()
        except queue.Empty:
            pass
        self.pending.put_nowait((diagnostics, final))

    def _work(self):
        while True:
            diagnostics, final = self.pending.get()
            try:
                publish(diagnostics, self.source)
                self.last_error = None
            except BridgeError as exc:
                self.last_error = str(exc)
            if final:
                return

    def finish(self, diagnostics: list[dict]) -> None:
        self.submit(diagnostics, final=True)
        # Only after the interactive program has exited. Each HTTP call is bounded.
        self.thread.join(timeout=4.5)


def pty_command(command: list[str], source: str) -> int:
    """Relay a true controlling PTY, retaining raw keys, resize events and exit code."""
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("pty 后需要命令，例如：pty --source codex -- codex")
    if os.name != "posix":
        raise ValueError("交互式 PTY 目前仅支持 macOS/Linux。")
    if not sys.stdin.isatty():
        raise ValueError("pty 需要交互式终端，不能使用管道输入。非交互命令请使用 run。")
    import errno
    import fcntl
    import pty
    import select
    import signal
    import struct
    import termios
    import tty

    input_fd = sys.stdin.fileno()
    saved_attributes = termios.tcgetattr(input_fd)
    def size_bytes():
        try:
            raw = fcntl.ioctl(input_fd, termios.TIOCGWINSZ, b"\0" * 8)
            rows, cols, _, _ = struct.unpack("HHHH", raw)
            if rows and cols:
                return raw
        except OSError:
            pass
        return struct.pack("HHHH", 24, 80, 0, 0)
    initial_size = size_bytes()
    pid, master = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(0, termios.TIOCSWINSZ, initial_size)
            environment = dict(os.environ)
            environment.setdefault("TERM", "xterm-256color")
            os.execvpe(command[0], command, environment)
        except OSError as exc:
            os.write(2, f"flybug: 无法运行命令：{exc}\n".encode())
            os._exit(127)
    # Fork precedes the networking thread: no inherited locks or HTTP sockets.
    reporter = _TerminalReporter(source)
    old_handlers = {}
    captured = bytearray()
    pending_input = bytearray()
    stdin_open = True
    master_open = True
    child_status = None
    exit_time = None
    next_scan = 0.0
    last_signature = None
    dirty = False

    def forward(sig, _frame):
        try:
            if sig == signal.SIGWINCH:
                fcntl.ioctl(master, termios.TIOCSWINSZ, size_bytes())
            else:
                os.killpg(pid, sig)
        except (OSError, ProcessLookupError):
            pass

    try:
        for sig in (signal.SIGWINCH, signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            old_handlers[sig] = signal.getsignal(sig)
            signal.signal(sig, forward)
        # Preserve keystrokes already queued while the wrapper was starting.
        tty.setraw(input_fd, termios.TCSANOW)
        while master_open:
            now = time.monotonic()
            if child_status is None:
                finished, status = os.waitpid(pid, os.WNOHANG)
                if finished:
                    child_status = status
                    exit_time = now
            elif exit_time is not None and now - exit_time > 1.0:
                break  # A descendant retaining the slave must not keep the wrapper alive.
            if dirty and now >= next_scan:
                issues = parse_live_diagnostics(captured.decode("utf-8", errors="replace"), Path.cwd(), source)
                signature = tuple(item["id"] for item in issues)
                if issues and signature != last_signature:
                    reporter.submit(issues)
                    last_signature = signature
                dirty = False
                next_scan = now + 1.0
            readable = [master] + ([input_fd] if stdin_open and len(pending_input) < 65536 else [])
            reads, writes, _ = select.select(readable, [master] if pending_input else [], [], 0.1)
            if input_fd in reads:
                data = os.read(input_fd, 8192)
                if data:
                    pending_input.extend(data)
                else:
                    stdin_open = False
                    pending_input.extend(b"\x04")
            if master in writes:
                try:
                    written = os.write(master, pending_input)
                    del pending_input[:written]
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        master_open = False
                    else:
                        raise
            if master in reads:
                try:
                    data = os.read(master, 8192)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        data = b""
                    else:
                        raise
                if not data:
                    master_open = False
                else:
                    _write_bytes(sys.stdout, data)
                    captured.extend(data)
                    if len(captured) > MAX_CAPTURE:
                        del captured[:-MAX_CAPTURE]
                    dirty = True
    finally:
        termios.tcsetattr(input_fd, termios.TCSADRAIN, saved_attributes)
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)
        os.close(master)
    if child_status is None:
        _, child_status = os.waitpid(pid, 0)
    code = os.WEXITSTATUS(child_status) if os.WIFEXITED(child_status) else 128 + os.WTERMSIG(child_status)
    output = captured.decode("utf-8", errors="replace")
    issues = parse_live_diagnostics(output, Path.cwd(), source) if code else []
    if code and not issues:
        issues = [make_diagnostic(source, f"交互命令退出码 {code}：{command[0]}")]
    reporter.finish(issues)
    if reporter.last_error:
        print(f"flybug: {reporter.last_error}（原命令退出码仍为 {code}）", file=sys.stderr)
    return code


def positive_int(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("必须为大于 0 的整数")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="将代码诊断发送给本机桌面苍蝇 FlyBug。")
    sub = parser.add_subparsers(dest="action", required=True)
    report = sub.add_parser("report", help="上报人工或工具确认的错误")
    report.add_argument("--file")
    report.add_argument("--line", type=positive_int)
    report.add_argument("--column", type=positive_int, default=1)
    report.add_argument("--message", required=True)
    report.add_argument("--text", help="编辑器当前行的准确文本，用于本机定位")
    report.add_argument("--severity", choices=["error", "warning"], default="error")
    report.add_argument("--source", default="cli")
    clear = sub.add_parser("clear", help="清除同一来源的诊断")
    clear.add_argument("--source", default="cli")
    sub.add_parser("status", help="检查本机 FlyBug 服务")
    run = sub.add_parser("run", help="流式运行非交互命令，失败时解析堆栈/编译错误")
    run.add_argument("--source", default="cli")
    run.add_argument("command", nargs=argparse.REMAINDER)
    interactive = sub.add_parser("pty", help="通过真实终端交互运行 Codex、Claude Code 或 shell")
    interactive.add_argument("--source", default="terminal")
    interactive.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.action == "status":
            print(json.dumps(request("GET", "/health"), ensure_ascii=False))
        elif args.action == "clear":
            publish([], args.source)
            print("已清除该来源的诊断。")
        elif args.action == "report":
            if args.line is not None and args.file is None:
                parser.error("--line 需要同时提供 --file")
            path = normalize_path(args.file, Path.cwd()) if args.file else None
            line_text = args.text
            if line_text is None and path and args.line:
                line_text = read_line(path, args.line)
            item = make_diagnostic(args.source, args.message, severity=args.severity,
                                   file=str(path) if path else None, line=args.line,
                                   column=args.column if args.line else None, line_text=line_text)
            publish([item], args.source)
            print("已发送给 FlyBug。")
        elif args.action == "run":
            return run_command(args.command, args.source)
        elif args.action == "pty":
            return pty_command(args.command, args.source)
    except (BridgeError, ValueError) as exc:
        print(f"flybug: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
