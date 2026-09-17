---
name: flybug-report
description: Send confirmed code errors, failing tests, and evidenced logic defects to the locally running FlyBug desktop companion, with the actual file and line. Use while debugging or reviewing code when FlyBug reporting is requested or available. Do not invent diagnostics or treat ordinary discussion of errors as a failure.
---

# FlyBug diagnostic reporting

FlyBug is a local macOS desktop fly. This skill supplies diagnostic evidence; the app independently locates the visible code. It does not analyze code for you or change the user's files.

When a compiler, test, runtime failure, or your code review establishes a concrete defect, report the actual file, 1-based line and a short explanation. For a logic defect include the failing input or violated condition in the explanation. Prefer the root cause in user code over a framework stack frame.

Run the bundled helper relative to this skill's directory:

```sh
python3 scripts/report.py report --file /absolute/path/example.py --line 12 --message 'NameError: total is not defined'
```

The helper reads only that line (files up to 2 MB) and sends it to authenticated `127.0.0.1`. It reads connection data from `~/Library/Application Support/FlyBug/bridge.json`. Do not display or copy the connection token. Use `--text` when reporting an unsaved editor line. Pass `--severity warning` only for a real warning.

After confirming the reported issue has been fixed, clear your skill's diagnostic:

```sh
python3 scripts/report.py clear
```

Each report replaces the previous report from this skill's source. Reports expire in the app after 45 seconds; report again only if useful and still valid. Different coding sessions may use `--source flybug-skill-SESSION_NAME` on report and clear to avoid replacing one another.

If FlyBug is not running or the connection fails, continue the user's coding task. Do not retry indefinitely, open applications, install dependencies, alter global configuration, or request extra permissions just to report. Never claim that the fly reached the line merely because the report was accepted; the file and code must be visible and the app needs a granted screen/Accessibility permission.
