#!/usr/bin/env python3
"""Report explicit Claude Code tool failures to the local FlyBug bridge.

Hook schema: https://code.claude.com/docs/en/hooks#posttoolusefailure
This hook never emits a Claude decision, modifies a tool result, or exits nonzero.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import re
import signal
import sys

MAX_INPUT = 262_144
MAX_OUTPUT = 64_000
MAX_DIAGNOSTICS = 10
TOTAL_DEADLINE = 3.0
BRIDGE_PATH = Path(__file__).resolve().parents[1] / "bridge" / "flybug.py"


def load_bridge():
    # Resolve this bundled module directly; never import from the hook's cwd.
    spec = importlib.util.spec_from_file_location("flybug_claude_bridge", BRIDGE_PATH)
    if spec is None or spec.loader is None:
        raise ImportError("FlyBug bridge is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def source_for(session_id) -> str:
    session = session_id if isinstance(session_id, str) and session_id else "unknown"
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session):
        session = hashlib.sha256(session.encode("utf-8", errors="replace")).hexdigest()[:24]
    return "claude-code:" + session


def failure_text(payload: dict) -> str | None:
    """Gate on an explicit failure before looking at any display text."""
    if payload.get("is_interrupt") is True:
        return None
    event = payload.get("hook_event_name")
    if event == "PostToolUseFailure":
        error = payload.get("error")
        return error[-MAX_OUTPUT:] if isinstance(error, str) and error.strip() else "工具调用失败"

    # The documented PostToolUse event denotes success, and its Bash Output
    # does not guarantee an exit code. Only accept an explicit nonzero numeric
    # code supplied by a compatible version/adapter; never grep normal output.
    if event != "PostToolUse" or payload.get("tool_name") != "Bash":
        return None
    response = payload.get("tool_response")
    if not isinstance(response, dict) or response.get("interrupted") is True:
        return None
    exit_code = response.get("exit_code", response.get("exitCode"))
    if type(exit_code) is not int or exit_code == 0:
        return None
    chunks = [f"Exit code {exit_code}"]
    for key in ("stdout", "stderr"):
        value = response.get(key)
        if isinstance(value, str) and value.strip():
            chunks.append(value[-(MAX_OUTPUT // 2):])
    return "\n".join(chunks)


def diagnostics_for(payload: dict, bridge) -> tuple[str, list[dict]] | None:
    output = failure_text(payload)
    if output is None:
        return None
    source = source_for(payload.get("session_id"))
    raw_cwd = payload.get("cwd")
    cwd = Path(raw_cwd) if isinstance(raw_cwd, str) and raw_cwd else Path.cwd()
    # Bound each line as well as the whole payload: location regexes should not
    # spend the hook deadline searching a single huge unstructured output line.
    parse_output = "\n".join(line[:2000] for line in output.splitlines())
    diagnostics = bridge.parse_diagnostics(parse_output, cwd, source)[:MAX_DIAGNOSTICS]
    if not diagnostics:
        name = payload.get("tool_name")
        name = name[:80] if isinstance(name, str) and name else "Claude Code"
        tool_input = payload.get("tool_input")
        file = tool_input.get("file_path") if isinstance(tool_input, dict) else None
        file = str(bridge.normalize_path(file, cwd)) if isinstance(file, str) and 0 < len(file) < 4096 else None
        # file_path identifies the failed file-tool operation. It supplies no
        # verified code line, so do not invent a line from a failed edit's text.
        display = bridge.ANSI.sub("", output).strip()
        diagnostics = [bridge.make_diagnostic(source, f"{name}: {display}", file=file)]
    return source, diagnostics


def _deadline(_signum, _frame):
    raise TimeoutError("FlyBug hook deadline")


def main(stream=None) -> int:
    previous_handler = None
    previous_timer = None
    try:
        # async hooks do not inherit Claude Code's hook timeout. Bound stdin,
        # local parsing and HTTP together; bridge.request also times out at 2s.
        previous_handler = signal.signal(signal.SIGALRM, _deadline)
        previous_timer = signal.setitimer(signal.ITIMER_REAL, TOTAL_DEADLINE)
        stream = stream if stream is not None else sys.stdin.buffer
        raw = stream.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return 0
        payload = json.loads(raw)
        if not isinstance(payload, dict) or failure_text(payload) is None:
            return 0
        bridge = load_bridge()
        result = diagnostics_for(payload, bridge)
        if result is not None:
            source, diagnostics = result
            bridge.publish(diagnostics, source)
    except (Exception, KeyboardInterrupt):
        # FlyBug is an observer. An offline app, malformed hook, missing module,
        # timeout or interruption must never change the coding agent's result.
        pass
    finally:
        if previous_timer is not None:
            signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        if previous_handler is not None:
            signal.signal(signal.SIGALRM, previous_handler)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
