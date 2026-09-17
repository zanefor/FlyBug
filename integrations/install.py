#!/usr/bin/env python3
"""Preview or install the bundled FlyBug integrations; never overwrite settings blindly."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EVENTS = ("PostToolUseFailure", "PostToolUse")


class InstallError(ValueError):
    pass


def check_destination(path: Path, home: Path, *, directory: bool = False):
    for candidate in (path, *path.parents):
        if candidate == home.parent:
            break
        if candidate.is_symlink():
            raise InstallError(f"目标或父目录是符号链接，未修改：{candidate}")
        if candidate != path and candidate.exists() and not candidate.is_dir():
            raise InstallError(f"目标父路径不是目录：{candidate}")
    if path.exists() and (path.is_dir() != directory or (not directory and not path.is_file())):
        raise InstallError(f"目标类型不符合预期，未修改：{path}")


def is_flybug_hook(entry) -> bool:
    if not isinstance(entry, dict) or entry.get("type") != "command" or not isinstance(entry.get("command"), str):
        return False
    try:
        return any(arg.endswith("/FlyBug/integrations/claude-hook.py") for arg in shlex.split(entry["command"]))
    except ValueError:
        return False


def merge_hooks(settings: dict, template: dict, hook_path: Path) -> dict:
    merged = copy.deepcopy(settings)
    hooks = merged.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise InstallError("已有 settings.json 的 hooks 不是对象，未修改。")
    for event in EVENTS:
        rules = hooks.get(event, [])
        if not isinstance(rules, list):
            raise InstallError(f"已有 {event} 不是数组，未修改。")
        retained = []
        for rule in rules:
            if not isinstance(rule, dict) or not isinstance(rule.get("hooks"), list):
                raise InstallError(f"已有 {event} 条目结构无效，未修改。")
            entries = rule["hooks"]
            remaining = [entry for entry in entries if not is_flybug_hook(entry)]
            if remaining == entries:
                retained.append(rule)
            elif remaining:
                retained.append({**rule, "hooks": remaining})
        incoming = copy.deepcopy(template["hooks"][event])
        for rule in incoming:
            for entry in rule["hooks"]:
                entry["command"] = shlex.quote(sys.executable) + " " + shlex.quote(str(hook_path))
        hooks[event] = retained + incoming
    return merged


def tree_fingerprint(root: Path):
    if not root.is_dir() or root.is_symlink():
        return None
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            return None
        relative = str(path.relative_to(root))
        if path.is_dir():
            result[relative] = None
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    digest.update(chunk)
            result[relative] = digest.digest()
        else:
            return None
    return result


def plan_install(home: Path, tool: str):
    home = home.expanduser().absolute()
    if home.is_symlink() or (home.exists() and not home.is_dir()):
        raise InstallError(f"安装主目录无效或是符号链接：{home}")
    skill = ROOT / "integrations" / "flybug-report"
    fingerprint = tree_fingerprint(skill)
    if fingerprint is None or not (skill / "SKILL.md").is_file() or not (skill / "scripts/report.py").is_file():
        raise InstallError("随附的 flybug-report skill 不完整或包含符号链接。")
    operations = []
    for name in ("codex", "claude"):
        if tool not in (name, "all"):
            continue
        target = home / f".{name}" / "skills" / "flybug-report"
        check_destination(target, home, directory=True)
        check_destination(target.parent.parent / "flybug-backups", home, directory=True)
        if tree_fingerprint(target) != fingerprint:
            operations.append((target, skill, None))
    if tool in ("claude", "all"):
        runtime = home / ".local" / "share" / "FlyBug"
        for relative in ("integrations/claude-hook.py", "bridge/flybug.py"):
            source, target = ROOT / relative, runtime / relative
            if source.is_symlink() or not source.is_file():
                raise InstallError(f"随附运行文件缺失或是符号链接：{source}")
            check_destination(target, home)
            content = source.read_bytes()
            if not target.exists() or target.read_bytes() != content:
                operations.append((target, None, content))
        config = home / ".claude" / "settings.json"
        check_destination(config, home)
        try:
            original = json.loads(config.read_text(encoding="utf-8")) if config.exists() else {}
            if not isinstance(original, dict):
                raise InstallError("已有 settings.json 必须是 JSON 对象，未修改。")
            template = json.loads((ROOT / "integrations/claude-hooks.example.json").read_text(encoding="utf-8"))
            merged = merge_hooks(original, template, runtime / "integrations/claude-hook.py")
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise InstallError("settings.json 或随附示例不是有效 JSON，所有目标保持原样。") from exc
        if merged != original:
            content = (json.dumps(merged, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
            operations.append((config, None, content))
    return operations


def apply_operation(target: Path, directory: Path | None, content: bytes | None):
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.pending-", dir=target.parent))
    prepared = staging / "value"
    backup = None
    try:
        if directory is not None:
            shutil.copytree(directory, prepared)
        else:
            prepared.write_bytes(content)
            prepared.chmod(target.stat().st_mode & 0o777 if target.exists() else 0o600)
        if target.exists():
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            # Keep old SKILL.md files outside the scanned skills directory.
            backup_parent = target.parent.parent / "flybug-backups" if directory is not None and target.parent.name == "skills" else target.parent
            backup_parent.mkdir(parents=True, exist_ok=True)
            backup = backup_parent / (target.name + ".backup-" + stamp)
            os.replace(target, backup)
        try:
            os.replace(prepared, target)
        except OSError:
            if backup is not None:
                os.replace(backup, target)
            raise
        return backup
    finally:
        shutil.rmtree(staging)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="安装 FlyBug 的本机编码工具集成；默认仅预览。")
    parser.add_argument("--tool", choices=("codex", "claude", "all"), default="all")
    parser.add_argument("--apply", action="store_true", help="执行已预览的安装及配置合并")
    parser.add_argument("--home", type=Path, default=Path.home(), help="安装主目录；默认当前用户主目录")
    args = parser.parse_args(argv)
    try:
        operations = plan_install(args.home, args.tool)
        if not operations:
            print("FlyBug 集成已是当前版本，无需修改。")
            return 0
        print("将安装以下内容：" if not args.apply else "正在安装 FlyBug 集成：")
        for target, directory, content in operations:
            print(f"  {target}")
            if args.apply:
                backup = apply_operation(target, directory, content)
                if backup is not None:
                    print(f"  原内容已备份：{backup}")
        print("安装完成。请重新开启 Codex / Claude Code 会话。" if args.apply else "仅预览，未写入文件。添加 --apply 才会安装；已有内容会先备份。")
        return 0
    except (OSError, InstallError, KeyError, TypeError) as exc:
        print(f"FlyBug 安装未完成：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
