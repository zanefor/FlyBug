"""Installer tests only use temporary home directories; never edit real settings."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("flybug_installer", ROOT / "integrations/install.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "test home"
        self.home.mkdir()
        self.config = self.home / ".claude/settings.json"

    def run_install(self, *args):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = installer.main(["--home", str(self.home), *args])
        return code, stdout.getvalue(), stderr.getvalue()

    def write_config(self, value):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
        return self.config.read_bytes()

    def test_default_is_read_only_preview(self):
        code, output, _ = self.run_install()
        self.assertEqual(code, 0)
        self.assertIn("仅预览", output)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_installs_self_contained_skills_and_stable_runtime(self):
        self.assertEqual(self.run_install("--apply")[0], 0)
        for tool in ("codex", "claude"):
            skill = self.home / f".{tool}/skills/flybug-report"
            self.assertTrue((skill / "SKILL.md").is_file())
            self.assertTrue((skill / "scripts/report.py").is_file())
        runtime = self.home / ".local/share/FlyBug"
        self.assertEqual((runtime / "bridge/flybug.py").read_bytes(), (ROOT / "bridge/flybug.py").read_bytes())
        self.assertTrue((runtime / "integrations/claude-hook.py").is_file())
        settings = json.loads(self.config.read_text())
        for event in installer.EVENTS:
            entry = settings["hooks"][event][0]["hooks"][0]
            self.assertTrue(entry["async"])
            self.assertIn(str(runtime / "integrations/claude-hook.py"), entry["command"])

    def test_merge_preserves_unrelated_settings_hooks_and_exact_backup(self):
        unrelated = {"matcher": "Bash", "custom": "retained", "hooks": [{"type": "command", "command": "echo other"}]}
        original = {"model": "example", "env": {"KEEP": "你好"}, "permissions": {"allow": ["Read"]},
                    "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo done"}]}],
                              "PostToolUse": [unrelated]}}
        before = self.write_config(original)
        self.assertEqual(self.run_install("--apply")[0], 0)
        after = json.loads(self.config.read_text())
        for key in ("model", "env", "permissions"):
            self.assertEqual(after[key], original[key])
        self.assertEqual(after["hooks"]["Stop"], original["hooks"]["Stop"])
        self.assertEqual(after["hooks"]["PostToolUse"][0], unrelated)
        backups = list(self.config.parent.glob("settings.json.backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)

    def test_repeat_install_has_no_duplicate_hooks_or_extra_backups(self):
        self.write_config({"custom": True})
        self.assertEqual(self.run_install("--apply")[0], 0)
        before = self.config.read_bytes()
        backup_count = len(list(self.home.rglob("*.backup-*")))
        code, output, _ = self.run_install("--apply")
        self.assertEqual(code, 0)
        self.assertIn("无需修改", output)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(len(list(self.home.rglob("*.backup-*"))), backup_count)
        for event in installer.EVENTS:
            self.assertEqual(len(json.loads(before)["hooks"][event]), 1)

    def test_replaces_old_flybug_hook_but_retains_same_rule_other_hooks(self):
        keep = {"type": "command", "command": "echo keep", "timeout": 7}
        old = {"type": "command", "command": 'python3 "/old folder/FlyBug/integrations/claude-hook.py"'}
        self.write_config({"hooks": {"PostToolUseFailure": [{"matcher": ".*", "hooks": [old, keep]}]}})
        self.assertEqual(self.run_install("--apply")[0], 0)
        rules = json.loads(self.config.read_text())["hooks"]["PostToolUseFailure"]
        self.assertEqual(rules[0]["hooks"], [keep])
        entries = [entry for rule in rules for entry in rule["hooks"]]
        self.assertEqual(sum(installer.is_flybug_hook(entry) for entry in entries), 1)

    def test_existing_skill_is_backed_up_before_replacement(self):
        skill = self.home / ".codex/skills/flybug-report"
        skill.mkdir(parents=True)
        (skill / "custom.txt").write_text("user changes")
        self.assertEqual(self.run_install("--apply", "--tool", "codex")[0], 0)
        backups = list((self.home / ".codex/flybug-backups").glob("flybug-report.backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "custom.txt").read_text(), "user changes")
        self.assertEqual(list(skill.parent.glob("*.backup-*")), [])
        self.assertFalse(self.config.exists())
        self.assertFalse((self.home / ".local").exists())

    def test_malformed_json_stops_before_any_install_and_keeps_original(self):
        self.config.parent.mkdir()
        self.config.write_text('{"hooks": broken')
        before = self.config.read_bytes()
        self.assertEqual(self.run_install("--apply")[0], 1)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse((self.home / ".codex").exists())
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual(list(self.config.parent.glob("*.backup-*")), [])

    def test_invalid_hooks_schema_is_not_overwritten(self):
        before = self.write_config({"hooks": {"PostToolUse": "wrong type"}})
        self.assertEqual(self.run_install("--apply")[0], 1)
        self.assertEqual(self.config.read_bytes(), before)
        self.assertFalse((self.home / ".codex").exists())

    def test_symlink_config_skill_and_parent_are_rejected(self):
        elsewhere = Path(self.temp.name) / "elsewhere"
        elsewhere.mkdir()
        external_config = elsewhere / "settings.json"
        external_config.write_text('{"keep":true}')
        self.config.parent.mkdir()
        self.config.symlink_to(external_config)
        self.assertEqual(self.run_install("--apply")[0], 1)
        self.assertEqual(external_config.read_text(), '{"keep":true}')
        self.config.unlink()
        skill = self.home / ".codex/skills/flybug-report"
        skill.parent.mkdir(parents=True)
        skill.symlink_to(elsewhere, target_is_directory=True)
        self.assertEqual(self.run_install("--apply")[0], 1)
        skill.unlink()
        skill.parent.rmdir()
        skill.parent.symlink_to(elsewhere, target_is_directory=True)
        self.assertEqual(self.run_install("--apply")[0], 1)

    def test_failed_atomic_replacement_restores_original_skill(self):
        target = self.home / "existing-skill"
        target.mkdir()
        (target / "original.txt").write_text("keep original")
        real_replace = os.replace

        def fail_install(source, destination):
            if Path(source).name == "value":
                raise OSError("simulated destination failure")
            return real_replace(source, destination)

        with patch.object(installer.os, "replace", side_effect=fail_install):
            with self.assertRaises(OSError):
                installer.apply_operation(target, ROOT / "integrations/flybug-report", None)
        self.assertEqual((target / "original.txt").read_text(), "keep original")
        self.assertEqual(list(self.home.glob(".existing-skill.pending-*")), [])


if __name__ == "__main__":
    unittest.main()
