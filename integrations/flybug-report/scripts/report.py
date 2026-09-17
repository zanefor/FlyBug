#!/usr/bin/env python3
"""Self-contained local FlyBug reporter for Codex and Claude Code skills."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import sys


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("line must be 1-based")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["report", "clear", "status"])
    parser.add_argument("--file")
    parser.add_argument("--line", type=positive)
    parser.add_argument("--message")
    parser.add_argument("--text")
    parser.add_argument("--severity", choices=["error", "warning"], default="error")
    parser.add_argument("--source", default="flybug-skill")
    args = parser.parse_args()
    if args.action == "report" and (not args.file or not args.line or not args.message):
        parser.error("report requires --file, --line and --message")
    try:
        path = Path(os.environ.get("FLYBUG_BRIDGE_FILE", str(Path.home() / "Library/Application Support/FlyBug/bridge.json")))
        config = json.loads(path.read_text())
        port, token = config["port"], config["token"]
        if type(port) is not int or not 0 < port < 65536 or not isinstance(token, str) or not token or "\n" in token or "\r" in token:
            raise ValueError("Invalid local discovery file")
        items = []
        if args.action == "report":
            file = Path(args.file).expanduser().resolve()
            line_text = args.text
            if line_text is None and file.is_file() and file.stat().st_size <= 2_000_000:
                with file.open(encoding="utf-8", errors="replace") as stream:
                    line_text = next((line.rstrip("\r\n")[:2000] for i, line in enumerate(stream, 1) if i == args.line), None)
            diagnostic = {"id": hashlib.sha256(f"{file}:{args.line}:{args.message}".encode()).hexdigest()[:24],
                          "source": args.source, "severity": args.severity, "message": args.message[:2000],
                          "file": str(file), "line": args.line, "column": 1}
            if line_text is not None:
                diagnostic["lineText"] = line_text[:2000]
            items.append(diagnostic)
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        try:
            body = json.dumps({"source": args.source, "replace": True, "diagnostics": items}).encode()
            conn.request("GET" if args.action == "status" else "POST", "/health" if args.action == "status" else "/diagnostics",
                         body=None if args.action == "status" else body,
                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            response = conn.getresponse()
            response.read(65536)
            if response.status != 200:
                raise ValueError(f"HTTP {response.status}")
        finally:
            conn.close()
        print("FlyBug: local report accepted" if args.action == "report" else "FlyBug: OK")
        return 0
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
        print("FlyBug unavailable; continue the coding task.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
