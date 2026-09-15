import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class FastModeTests(unittest.TestCase):
    def test_hammerspoon_preserves_profiles_store_for_toggle(self):
        source = (ROOT / "hammerspoon/llm-limits.lua").read_text()
        self.assertIn('"CODEXB_PROFILES_DIR"', source)

    def test_account_isolation_and_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            base = home / ".codex"
            base.mkdir()
            original = 'model = "fixture"\nservice_tier = "priority"\n'
            (base / "config.toml").write_text(original)
            profiles = home / ".codex-profiles"
            profiles.mkdir()
            (profiles / "alpha").symlink_to(base)
            (profiles / "other").mkdir()
            (profiles / "other/config.toml").symlink_to(base / "config.toml")
            marker = home / ".llm-limits-codex.json.removed"
            marker.write_text("removed\n")
            fake_bin = home / "bin"
            fake_bin.mkdir()
            fake = fake_bin / "codex"
            fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                            'print(json.dumps([os.environ.get("CODEX_HOME"),sys.argv[1:]]))\n')
            fake.chmod(0o755)
            env = dict(os.environ, HOME=str(home), CODEXB_PROFILES_DIR=str(profiles),
                       PATH=str(fake_bin) + os.pathsep + os.environ["PATH"])

            def run(*args, success=True):
                result = subprocess.run([str(ROOT / "bin/codexb"), *args], env=env,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                return result.stdout.strip()

            self.assertEqual(run("fast-mode", "alpha"), "off")
            self.assertEqual(run("fast-mode", "alpha", "off"), "off")
            self.assertEqual(run("fast-mode", "alpha"), "off")
            launched_home, args = json.loads(run("profile", "alpha", "--help"))
            self.assertEqual(Path(launched_home).resolve(), base.resolve())
            self.assertEqual(args, ["--help"])
            self.assertEqual(run("fast-mode", "other"), "off")
            self.assertEqual(json.loads(run("profile", "other", "--help"))[1],
                             ["--help"])
            self.assertEqual(run("fast-mode", "alpha", "on"), "on")
            self.assertEqual(run("fast-mode", "alpha"), "on")
            self.assertEqual(json.loads(run("profile", "alpha", "--help"))[1],
                             ["--help"])
            self.assertEqual((profiles / ".codexb/fast-mode/alpha").read_text(), "fast\n")
            for name in ("main", "unknown", "../escape"):
                run("fast-mode", name, "on", success=False)
            run("fast-mode", "other", "invalid", success=False)
            self.assertEqual((base / "config.toml").read_text(), original)
            self.assertTrue((profiles / "other/config.toml").is_symlink())
            self.assertEqual(marker.read_text(), "removed\n")
            self.assertFalse((profiles / ".codexb/disabled").exists())
            self.assertFalse((home / ".claude/worker-model").exists())
            self.assertEqual(list((profiles / ".codexb/fast-mode").iterdir()),
                             [profiles / ".codexb/fast-mode/alpha"])

            nested = profiles / "nested"
            nested.mkdir()
            (nested / "config.toml").write_text(
                '[features]\nservice_tier = "priority"\n# keep this comment\n'
            )
            self.assertEqual(run("fast-mode", "nested"), "off")
            self.assertEqual(json.loads(subprocess.check_output(
                ["/usr/bin/python3", str(ROOT / "share/codex_fast_mode.py"),
                 str(profiles), "nested", "state"], env=env, text=True)),
                {"requested": "off", "configured": "default", "backend": "unknown"})
            fallback = subprocess.run(
                ["/usr/bin/python3", str(ROOT / "share/codex_fast_mode.py"),
                 str(profiles), "nested", "status"],
                env=env, text=True, capture_output=True,
            )
            self.assertEqual(fallback.returncode, 0, fallback.stderr)
            self.assertEqual(fallback.stdout.strip(), "off")

            (profiles / ".codexb/fast-mode/nested").write_text("garbage\n")
            invalid = subprocess.run(
                ["/usr/bin/python3", str(ROOT / "share/codex_fast_mode.py"),
                 str(profiles), "nested", "state"],
                env=env, text=True, capture_output=True,
            )
            self.assertNotEqual(invalid.returncode, 0)

            disabled = profiles / "disabled"
            disabled.mkdir()
            (disabled / "config.toml").write_text(
                'service_tier = "fast"\n[features]\nfast_mode = false\n'
            )
            self.assertEqual(run("fast-mode", "disabled"), "off")
            self.assertEqual(run("fast-mode", "disabled", "on"), "on")
            self.assertEqual(json.loads(run("profile", "disabled", "--help"))[1],
                             ["--help"])

            override = json.loads(run("profile", "alpha", "-c", 'service_tier="default"',
                                      "--disable", "fast_mode", "--help"))
            self.assertEqual(override[1],
                             ["-c", 'service_tier="default"', "--disable", "fast_mode", "--help"])


if __name__ == "__main__":
    unittest.main()
