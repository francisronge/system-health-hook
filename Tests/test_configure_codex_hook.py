import importlib.util
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import tomllib
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/configure-codex-hook.py"
SPEC = importlib.util.spec_from_file_location("configure_hook", SCRIPT)
configurator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configurator)


class ConfigureHookTests(unittest.TestCase):
    binary = Path("/tmp/health install/system-health-context")

    def test_fresh_config_registers_both_events(self):
        result = configurator.render_config('model = "example"\n', self.binary)
        configurator.verify(result, self.binary)
        self.assertEqual(tomllib.loads(result)["model"], "example")

    def test_repairs_start_only_and_preserves_other_hooks_and_trust(self):
        source = '''model = "example"
[hooks]
UserPromptSubmit = [{ hooks = [{ type = "command", command = "/old/system-health-codex-hook.zsh turn_start" }, {type = "command", command = "/other/tool"}] }]
SessionStart = [{ hooks = [{ type = "command", command = "/other/start" }] }]
[hooks.state."previous-key"]
trusted_hash = "unchanged"
[other]
value = "keep this"
'''
        before = tomllib.loads(source)
        result = configurator.render_config(source, self.binary)
        configurator.verify(result, self.binary)
        after = tomllib.loads(result)
        self.assertEqual(after["other"], before["other"])
        self.assertEqual(after["hooks"]["state"], before["hooks"]["state"])
        self.assertEqual(after["hooks"]["SessionStart"], before["hooks"]["SessionStart"])
        self.assertEqual(after["hooks"]["UserPromptSubmit"][0]["hooks"][1]["command"], "/other/tool")

    def test_other_hook_positions_and_saved_state_are_preserved(self):
        source = '''[hooks]
Stop = [{ hooks = [{type = "command", command = "/old/system-health-context --codex-hook turn_end"}, {type = "command", command = "/other/first"}] }, { hooks = [{type = "command", command = "/other/second"}] }]
[hooks.state."/tmp/config.toml:stop:0:1"]
trusted_hash = "keep-first"
[hooks.state."/tmp/config.toml:stop:1:0"]
enabled = false
'''
        before = tomllib.loads(source)["hooks"]
        after = tomllib.loads(configurator.render_config(source, self.binary))["hooks"]
        self.assertEqual(after["Stop"][0]["hooks"][1], before["Stop"][0]["hooks"][1])
        self.assertEqual(after["Stop"][1], before["Stop"][1])
        self.assertEqual(after["state"], before["state"])

    def test_duplicates_are_rejected_without_reindexing_other_hooks(self):
        source = '''[hooks]
Stop = [{ hooks = [{command = "/old/system-health-context"}, {command = "/other/system-health-codex-hook.zsh"}] }]
'''
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            configurator.render_config(source, self.binary)

    def test_idempotent(self):
        once = configurator.render_config("", self.binary)
        self.assertEqual(configurator.render_config(once, self.binary), once)

    def test_old_install_location_is_replaced(self):
        old = configurator.render_config("", Path("/old/system-health-context"))
        with self.assertRaises(ValueError):
            configurator.verify(old, self.binary)
        fixed = configurator.render_config(old, self.binary)
        configurator.verify(fixed, self.binary)
        self.assertNotIn("/old/", fixed)

    def test_shell_quotes_and_unicode_round_trip(self):
        binary = Path("/tmp/Fran's hooks/system-health-context")
        source = '[hooks.state."test"]\nnote = "\U0001f680"\n'
        result = configurator.render_config(source, binary)
        command = tomllib.loads(result)["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(shlex.split(command), [str(binary), "--codex-hook", "turn_end"])
        self.assertEqual(tomllib.loads(result)["hooks"]["state"]["test"]["note"], "\U0001f680")

    def test_comment_does_not_count_as_installed_hook(self):
        result = configurator.render_config("# /tmp/system-health-context\n", self.binary)
        configurator.verify(result, self.binary)

    def test_array_tables_are_supported(self):
        source = '''[[hooks.UserPromptSubmit]]
matcher = "restricted"
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "/old/system-health-context --codex-hook turn_start"
'''
        configurator.verify(configurator.render_config(source, self.binary), self.binary)

    def test_header_inside_multiline_string_cannot_corrupt_settings(self):
        source = 'note = """\n[hooks]\nnot a table\n"""\n'
        try:
            result = configurator.render_config(source, self.binary)
        except ValueError:
            return
        self.assertEqual(tomllib.loads(result)["note"], tomllib.loads(source)["note"])

    def test_malformed_config_is_not_written(self):
        with tempfile.TemporaryDirectory(prefix="health-config-test-") as directory:
            path = Path(directory) / "config.toml"
            path.write_text("[broken")
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), str(path), str(self.binary)],
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), "[broken")
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_install_creates_private_backup_and_verifies(self):
        with tempfile.TemporaryDirectory(prefix="health-config-test-") as directory:
            path = Path(directory) / "config.toml"
            original = 'model = "keep"\n'
            path.write_text(original)
            command = [sys.executable, "-B", str(SCRIPT), str(path), str(self.binary)]
            subprocess.run(command, check=True, capture_output=True, timeout=5)
            subprocess.run(command + ["--check"], check=True, capture_output=True, timeout=5)
            backups = list(path.parent.glob("config.toml.before-system-health-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), original)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            subprocess.run(command, check=True, capture_output=True, timeout=5)
            self.assertEqual(len(list(path.parent.glob("config.toml.before-system-health-*"))), 1)


if __name__ == "__main__":
    unittest.main()
