#!/usr/bin/env python3
"""Observe real external input behavior through FlyBug's read-only health endpoint.

Example, after focusing a test field in Chrome:
    python3 tests/observe_external.py --expect found --app "Google Chrome"

No UI activation, text entry, diagnostics injection or app modification occurs.
Only whitelisted structural metadata is printed. The local bridge token and field
contents are never printed. Exit codes: 0 passed, 1 timed out, 2 invalid arguments,
130 interrupted. Two distinct, fresh health samples must satisfy the expectation.
"""
from __future__ import annotations

import argparse
import http.client
import json
import math
import os
from pathlib import Path
import time


DEFAULT_BRIDGE_FILE = Path.home() / "Library/Application Support/FlyBug/bridge.json"
CLEAR_SUFFIX = " · 当前输入未发现语法或拼写问题"
PROTECTED_STATUS = "密码或受保护的输入框已跳过"
MAX_SAMPLE_AGE = 3.0
POLL_INTERVAL = 0.5


class ObservationError(Exception):
    """Carries only a fixed error code, never HTTP headers or response text."""


def read_health(timeout: float) -> dict:
    path = Path(os.environ.get("FLYBUG_BRIDGE_FILE", str(DEFAULT_BRIDGE_FILE))).expanduser()
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
        port, token = config["port"], config["token"]
        if (type(port) is not int or not 1 <= port <= 65535
                or not isinstance(token, str) or not token or "\r" in token or "\n" in token):
            raise ValueError
    except (OSError, ValueError, KeyError, TypeError):
        raise ObservationError("bridge_discovery_unavailable") from None
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("GET", "/health", headers={"Authorization": "Bearer " + token})
        response = connection.getresponse()
        if response.status != 200:
            raise ObservationError(f"bridge_http_{response.status}")
        data = response.read(65_537)
        if len(data) > 65_536:
            raise ObservationError("bridge_response_too_large")
        result = json.loads(data)
        if not isinstance(result, dict):
            raise ValueError
        return result
    except ObservationError:
        raise
    except (OSError, http.client.HTTPException, ValueError):
        raise ObservationError("bridge_unavailable") from None
    finally:
        connection.close()


def finite_number(value) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def point(value) -> dict | None:
    if (isinstance(value, dict) and finite_number(value.get("x"))
            and finite_number(value.get("y"))):
        return {"x": value["x"], "y": value["y"]}
    return None


def app_name(health: dict) -> str | None:
    metadata = health.get("inputMetadata")
    if isinstance(metadata, dict):
        name = metadata.get("appName")
        if isinstance(name, str) and name:
            return name[:120]
    # Older builds include the application only in their completed status.
    status = health.get("textStatus")
    if isinstance(status, str) and not status.startswith("最近输入状态："):
        for marker in (CLEAR_SUFFIX, " · 发现 ", " · 等待停笔，"):
            if marker in status:
                return status.split(marker, 1)[0][:120]
    return None


def evaluate(health: dict, expect: str, expected_app: str | None, now: float) -> tuple[bool, str, dict]:
    """Require completed external results; empty or stale state never passes."""
    metadata = health.get("inputMetadata")
    metadata = metadata if isinstance(metadata, dict) else {}
    stage = metadata.get("stage")
    status = health.get("textStatus")
    name = app_name(health)
    source = health.get("currentSource")
    allowed_sources = {None, "writing", "writing-demo", "demo", "screen", "accessibility", "bridge"}
    source = source if isinstance(source, (str, type(None))) and source in allowed_sources else "unknown"
    issues, targets = health.get("writingIssueCount"), health.get("writingTargetCount")
    target, position = point(health.get("flyTarget")), point(health.get("flyPosition"))
    distance = math.hypot(target["x"] - position["x"], target["y"] - position["y"]) if target and position else None
    sampled_at = health.get("sampledAt")
    age = now - sampled_at if finite_number(sampled_at) else None
    summary = {
        "app": name,
        "stage": stage[:48] if isinstance(stage, str) else None,
        "focusRole": metadata.get("focusRole", "")[:48] if isinstance(metadata.get("focusRole", ""), str) else None,
        "running": health.get("running") is True,
        "accessibility": health.get("accessibility") is True,
        "textChecking": health.get("textChecking") is True,
        "writingIssueCount": issues if type(issues) is int else None,
        "writingTargetCount": targets if type(targets) is int else None,
        "currentSource": source,
        "flyTarget": target,
        "flyPosition": position,
        "distance": round(distance, 3) if distance is not None else None,
        "ageSeconds": round(age, 3) if age is not None else None,
    }
    if health.get("ok") is not True or age is None or not -0.5 <= age <= MAX_SAMPLE_AGE:
        return False, "health_not_fresh", summary
    if not all(summary[key] for key in ("running", "accessibility", "textChecking")):
        return False, "monitor_not_enabled", summary
    if expected_app and (name is None or name.casefold() != expected_app.casefold()):
        return False, "app_mismatch", summary
    if type(issues) is not int or type(targets) is not int or not 0 <= targets <= issues:
        return False, "invalid_counts", summary
    if expect == "found":
        passed = (stage == "ready" and issues > 0 and targets > 0 and source == "writing"
                  and distance is not None and distance < 2)
        return passed, "arrived_at_external_issue" if passed else "waiting_for_external_arrival", summary
    if expect == "clear":
        completed = isinstance(status, str) and status.endswith(CLEAR_SUFFIX) and not status.startswith("最近输入状态：")
        passed = (stage == "ready" and completed and issues == 0 and targets == 0
                  and health.get("flyTarget") is None and source not in ("writing", "writing-demo", "demo"))
        return passed, "external_input_checked_clear" if passed else "waiting_for_completed_clear_check", summary
    protected = metadata.get("protected") in (True, "true") or status == PROTECTED_STATUS
    passed = (protected and stage in ("editable", "protected") and issues == 0 and targets == 0
              and health.get("flyTarget") is None and source not in ("writing", "writing-demo", "demo"))
    return passed, "protected_input_skipped" if passed else "waiting_for_protected_input", summary


class ConsecutiveMatches:
    """Repeated reads of the same cached health snapshot count only once."""
    def __init__(self):
        self.count = 0
        self.last_sample = None
        self.identity = None

    def add(self, health: dict, matched: bool, summary: dict) -> bool:
        timestamp = health.get("sampledAt")
        if not matched:
            self.count = 0
            self.identity = None
            self.last_sample = timestamp
            return False
        if timestamp == self.last_sample:
            return False
        identity = (summary["app"], summary["currentSource"], summary["flyTarget"])
        increasing = finite_number(timestamp) and (not finite_number(self.last_sample) or timestamp > self.last_sample)
        self.count = self.count + 1 if increasing and identity == self.identity else 1
        self.identity = identity
        self.last_sample = timestamp
        return self.count >= 2


def positive_seconds(value: str) -> float:
    try:
        number = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("timeout must be a positive number") from None
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("timeout must be a positive number")
    return number


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--expect", required=True, choices=("found", "clear", "protected"))
    parser.add_argument("--app", help="Exact external application display name, for example Google Chrome")
    parser.add_argument("--timeout", type=positive_seconds, default=15, help="Seconds to observe; default 15")
    args = parser.parse_args(argv)
    deadline = time.monotonic() + args.timeout
    tracker = ConsecutiveMatches()
    samples, summary, reason = 0, {}, "waiting_for_health"
    try:
        while time.monotonic() < deadline:
            try:
                health = read_health(timeout=max(0.05, min(2.0, deadline - time.monotonic())))
                samples += 1
                matched, reason, summary = evaluate(health, args.expect, args.app, time.time())
                if tracker.add(health, matched, summary):
                    print(json.dumps({"result": "passed", "expect": args.expect, "samples": samples,
                                      "consecutiveMatches": tracker.count, "reason": reason, "metadata": summary},
                                     ensure_ascii=False, allow_nan=False))
                    return 0
            except ObservationError as error:
                reason = str(error)
                tracker.count = 0
                tracker.identity = None
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(POLL_INTERVAL, remaining))
    except KeyboardInterrupt:
        print(json.dumps({"result": "interrupted", "expect": args.expect, "samples": samples}))
        return 130
    print(json.dumps({"result": "timed_out", "expect": args.expect, "samples": samples,
                      "consecutiveMatches": tracker.count, "reason": reason, "metadata": summary},
                     ensure_ascii=False, allow_nan=False))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
