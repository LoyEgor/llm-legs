import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock


source = Path(__file__).resolve().parents[1] / "bin/claudegpt"
loader = importlib.machinery.SourceFileLoader("claudegpt", str(source))
spec = importlib.util.spec_from_loader(loader.name, loader)
app = importlib.util.module_from_spec(spec)
loader.exec_module(app)


class LauncherTests(unittest.TestCase):
    def test_picker_labels_do_not_change_routes(self):
        picker = app.menu_settings()["modelPicker"]
        self.assertTrue(picker["replaceBuiltInOptions"])
        self.assertEqual([(r["model"], r["label"]) for r in picker["options"]],
                         [("anthropic.ccr.sol", "Sol"), ("anthropic.ccr.astra", "Astra")])

    def test_account_cannot_escape_store(self):
        for name in ("../main", "/tmp/main", "", "main/other", "-main"):
            with self.subTest(name=name), self.assertRaises(SystemExit):
                app.account_dir(name)

    def test_accounts_have_separate_authorization(self):
        self.assertNotEqual(app.account_dir("main"), app.account_dir("notcom"))

    def test_parent_gateway_credentials_are_not_inherited(self):
        values = {key: "fixture" for key in (
            "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY",
            "CLAUDE_CODE_OAUTH_TOKEN", "CCR_SESSION_ID", "CLAUDE_LIMITS_ACCOUNT")}
        values["CLAUDE_CONFIG_DIR"] = "/fixture/shared-claude"
        with patch.dict(os.environ, values, clear=True):
            self.assertEqual(app.clean_env(), {"CLAUDE_CONFIG_DIR": "/fixture/shared-claude"})

    def test_existing_relay_prompt_and_tools_survive_model_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "agents").mkdir()
            path = root / "agents/grok-worker.md"
            original = "---\nname: grok-worker\ndescription: Relay\ntools: Bash, Read\nmodel: sonnet\n---\nExisting relay contract.\n"
            path.write_text(original)
            agent = app.relay_agents(root)["grok-worker"]
            self.assertEqual(agent["model"], "inherit")
            self.assertEqual(agent["prompt"], "Existing relay contract.")
            self.assertEqual(agent["tools"], ["Bash", "Read"])
            self.assertEqual(path.read_text(), original)

    def test_proxy_has_no_cross_account_or_model_failover(self):
        configuration = app.config(Path("/fixture/account/auth"), 12345)
        self.assertEqual(configuration["host"], "127.0.0.1")
        self.assertEqual(configuration["auth-dir"], "/fixture/account/auth")
        self.assertFalse(configuration["quota-exceeded"]["switch-project"])
        self.assertFalse(configuration["quota-exceeded"]["switch-preview-model"])
        self.assertEqual(configuration["request-retry"], 0)

    def test_switch_account_keeps_resume_and_shared_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            for name in ("first", "second"):
                auth = state / "accounts" / name / "auth"
                auth.mkdir(parents=True)
                (auth / "fixture.json").write_text("{}")
            launches = []
            selected_auth = []
            launch_envs = []

            def proxy(command, **kwargs):
                settings = json.loads(Path(command[command.index("-config") + 1]).read_text())
                selected_auth.append(settings["auth-dir"])
                process = MagicMock()
                process.poll.return_value = None
                return process

            def launch(command, **kwargs):
                if "-codex-login" in command:
                    settings = json.loads(Path(command[command.index("-config") + 1]).read_text())
                    (Path(settings["auth-dir"]) / "fixture.json").write_text("{}")
                    return 0
                launch_envs.append(kwargs["env"])
                wrapper = Path(kwargs["env"]["PATH"].split(os.pathsep)[0]) / "worker-run"
                if wrapper.exists():
                    for key in (*app.CONTEXT_ENV, "CLAUDEGPT_ACCOUNT"):
                        self.assertIn("-u " + key, wrapper.read_text())
                launches.append((command, kwargs["env"]["CLAUDE_CONFIG_DIR"]))
                return 0

            with patch.object(app, "STATE", state), \
                 patch.object(app.os, "access", return_value=True), \
                 patch.object(app, "run_setup") as setup, \
                 patch.object(app, "relay_agents", return_value={}), \
                 patch.object(app.subprocess, "Popen", side_effect=proxy), \
                 patch.object(app.subprocess, "call", side_effect=launch), \
                 patch.object(app.urllib.request, "urlopen", side_effect=lambda *a, **k: io.BytesIO(b'{"data":[{"id":"gpt-5.6-sol"}]}')), \
                 patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(state / "shared")}), \
                 patch.object(app.sys, "stderr", io.StringIO()):
                for name in ("first", "second", "new-account"):
                    with patch.object(app.sys, "argv", ["claudegpt", "p", name, "--resume", "fixture-conversation"]):
                        self.assertEqual(app.main(), 0)
            self.assertNotEqual(selected_auth[0], selected_auth[1])
            self.assertEqual(launches[0][1], launches[1][1])
            self.assertEqual(len(launches), 3)
            self.assertEqual(Path(selected_auth[2]).parent.name, "new-account")
            updates = [call.args[1] for call in setup.call_args_list if call.args[1][:2] == ["model", "update"]]
            self.assertEqual(len(updates), 6)
            for update in updates:
                self.assertEqual(update[update.index("--context-window") + 1], "872000")
            for environment in launch_envs:
                self.assertEqual(environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "872000")
                self.assertEqual(environment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "872000")
            for command, _ in launches:
                self.assertEqual(command[-2:], ["--resume", "fixture-conversation"])

    def launch(self, state, argv, corpus=None, writes=None):
        """One `claudegpt p` run against fake bridge processes; returns the claude argv."""
        captured = []

        def call(command, **kwargs):
            captured.append(command)
            for name in (writes or ()):
                target = Path(corpus) / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("{}\n")
            return 0

        process = MagicMock()
        process.poll.return_value = None
        with patch.object(app, "STATE", state), \
             patch.object(app.os, "access", return_value=True), \
             patch.object(app, "run_setup"), \
             patch.object(app, "relay_agents", return_value={}), \
             patch.object(app.subprocess, "Popen", return_value=process), \
             patch.object(app.subprocess, "call", side_effect=call), \
             patch.object(app.urllib.request, "urlopen",
                          side_effect=lambda *a, **k: io.BytesIO(
                              b'{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-6-astra"}]}')), \
             patch.object(app.sys, "stderr", io.StringIO()), \
             patch.object(app.sys, "argv", argv):
            self.assertEqual(app.main(), 0)
        return captured[-1]

    def test_every_launch_records_the_account_its_conversation_runs_on(self):
        # A transcript names the model and never the account, so without this stamp the
        # only way back into a gateway chat is a claudeb line that opens it on Claude.
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "store"
            configuration = Path(temporary) / "claude"
            corpus = configuration / "projects"
            (state / "accounts/work4/auth").mkdir(parents=True)
            (state / "accounts/work4/auth/fixture.json").write_text("{}")
            stamps = state / "sessions"
            slug = app.project_transcripts(corpus, os.getcwd())
            environment = {"CLAUDE_CONFIG_DIR": str(configuration)}

            with patch.dict(os.environ, environment):
                fresh = self.launch(state, ["claudegpt", "p", "work4", "--model", "astra"])
            named = fresh[fresh.index("--session-id") + 1]
            self.assertEqual((stamps / named).read_text().split(), ["v1", "work4", "astra"])

            # An id the launch was handed is the conversation it writes to; naming a second
            # one would make Claude Code refuse the launch outright.
            with patch.dict(os.environ, environment):
                resumed = self.launch(state, ["claudegpt", "p", "work4", "--resume", "kept-0001"])
            self.assertNotIn("--session-id", resumed)
            self.assertEqual((stamps / "kept-0001").read_text().split(), ["v1", "work4", "sol"])

            # --continue picks the conversation itself, so the stamp is written from the
            # transcript that turned out to be touched, and only inside this directory.
            with patch.dict(os.environ, environment):
                continued = self.launch(state, ["claudegpt", "p", "work4", "--continue"],
                                        corpus=corpus,
                                        writes=[slug.name + "/picked-0002.jsonl",
                                                "-other-project/elsewhere-0003.jsonl"])
            self.assertNotIn("--session-id", continued)
            self.assertTrue((stamps / "picked-0002").exists())
            self.assertFalse((stamps / "elsewhere-0003").exists())

            # A chat nothing can resume cannot be reopened, so its stamp goes with it —
            # and every stamp whose transcript is still there stays.
            (slug / "kept-0001.jsonl").write_text("{}\n")
            with patch.dict(os.environ, environment):
                self.launch(state, ["claudegpt", "p", "work4", "--resume", "kept-0001"])
            self.assertTrue((stamps / "kept-0001").exists())
            self.assertFalse((stamps / named).exists())

    def test_failed_first_login_does_not_start_chat(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(app, "STATE", Path(temporary)), \
             patch.object(app.os, "access", return_value=True), \
             patch.object(app.subprocess, "call", return_value=1) as login, \
             patch.object(app.subprocess, "Popen") as proxy, \
             patch.object(app.sys, "stderr", io.StringIO()), \
             patch.object(app.sys, "argv", ["claudegpt", "p", "new-account"]):
            self.assertEqual(app.main(), 1)
            self.assertIn("-codex-login", login.call_args.args[0])
            proxy.assert_not_called()


class ConcurrentLauncherSubprocessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.bin_dir = self.root / "bin"
        self.claude_config = self.root / "claude"
        self.project = self.root / "project"
        self.ready_dir = self.root / "ready"
        for directory in (self.home, self.bin_dir, self.claude_config, self.project, self.ready_dir):
            directory.mkdir()
        ccr = self.bin_dir / "ccr"
        ccr.write_text("#!/usr/bin/env python3\nimport os, sys, time\n"
                       "if 'launch' in sys.argv[1:]:\n"
                       "    ready = os.environ.get('TEST_READY_DIR')\n"
                       "    if ready:\n"
                       "        with open(os.path.join(ready, f'ready_{os.getpid()}'), 'w') as f:\n"
                       "            f.write(str(os.getpid()))\n"
                       "    try:\n"
                       "        while os.getppid() > 1:\n"
                       "            time.sleep(0.05)\n"
                       "    except (KeyboardInterrupt, SystemExit):\n"
                       "        pass\n"
                       "sys.exit(0)\n")
        ccr.chmod(0o755)
        proxy = self.bin_dir / "cli-proxy-api"
        proxy.write_text("#!/usr/bin/env python3\nimport http.server, json, os, sys\n"
                         "args = sys.argv[1:]\n"
                         "port = 8080\n"
                         "if '-config' in args:\n"
                         "    with open(args[args.index('-config') + 1]) as f:\n"
                         "        port = json.load(f)['port']\n"
                         "class H(http.server.BaseHTTPRequestHandler):\n"
                         "    def do_GET(self):\n"
                         "        if self.path == '/v1/models':\n"
                         "            body = json.dumps({'data': [{'id': 'gpt-5.6-sol'}]}).encode()\n"
                         "            self.send_response(200)\n"
                         "            self.send_header('Content-Type', 'application/json')\n"
                         "            self.send_header('Content-Length', str(len(body)))\n"
                         "            self.end_headers()\n"
                         "            self.wfile.write(body)\n"
                         "        else:\n"
                         "            self.send_response(404)\n"
                         "            self.end_headers()\n"
                         "    def log_message(self, *a):\n"
                         "        pass\n"
                         "server = http.server.HTTPServer(('127.0.0.1', port), H)\n"
                         "server.timeout = 0.5\n"
                         "while os.getppid() > 1:\n"
                         "    server.handle_request()\n")
        proxy.chmod(0o755)
        for name in ("claude", "worker-run"):
            wrapper = self.bin_dir / name
            wrapper.write_text("#!/bin/sh\nexit 0\n")
            wrapper.chmod(0o755)
        for name in ("first", "second"):
            auth = self.home / "accounts" / name / "auth"
            auth.mkdir(parents=True)
            (auth / "login.json").write_text("{}")
        self.env = os.environ.copy()
        self.env["CLAUDEGPT_HOME"] = str(self.home)
        self.env["CLAUDEGPT_BIN"] = str(self.bin_dir)
        self.env["CLAUDE_CONFIG_DIR"] = str(self.claude_config)
        self.env["PATH"] = f"{self.bin_dir}:{self.env.get('PATH', '')}"
        self.env["TEST_READY_DIR"] = str(self.ready_dir)
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()
        self.tmp.cleanup()

    def wait_ready(self, count, timeout=5.0):
        start = time.time()
        while time.time() - start < timeout:
            if len(list(self.ready_dir.glob("ready_*"))) >= count:
                return True
            time.sleep(0.02)
        return False

    def launch(self, account, cwd=None, extra=None):
        proc = subprocess.Popen([sys.executable, str(source), "p", account, *(extra or [])],
                                env=self.env, cwd=str(cwd or self.project),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.procs.append(proc)
        return proc

    def test_two_launches_same_account_and_cwd_both_run_and_cleanup_first(self):
        p1 = self.launch("first")
        self.assertTrue(self.wait_ready(1))
        p2 = self.launch("first")
        self.assertTrue(self.wait_ready(2))
        self.assertIsNone(p1.poll())
        self.assertIsNone(p2.poll())
        p1.terminate()
        p1.wait(timeout=5)
        time.sleep(0.05)
        self.assertIsNone(p2.poll())
        p2.terminate()
        p2.wait(timeout=5)

    def test_reverse_exit_order_leaves_first_healthy(self):
        p1 = self.launch("first")
        self.assertTrue(self.wait_ready(1))
        p2 = self.launch("first")
        self.assertTrue(self.wait_ready(2))
        self.assertIsNone(p1.poll())
        self.assertIsNone(p2.poll())
        p2.terminate()
        p2.wait(timeout=5)
        time.sleep(0.05)
        self.assertIsNone(p1.poll())
        p1.terminate()
        p1.wait(timeout=5)

    def test_separate_accounts_unaffected(self):
        p1 = self.launch("first")
        self.assertTrue(self.wait_ready(1))
        p2 = self.launch("second")
        self.assertTrue(self.wait_ready(2))
        self.assertIsNone(p1.poll())
        self.assertIsNone(p2.poll())
        p1.terminate()
        p1.wait(timeout=5)
        time.sleep(0.05)
        self.assertIsNone(p2.poll())
        p2.terminate()
        p2.wait(timeout=5)

    def test_startup_failure_and_signal_cleanup_leaves_no_stale_guard(self):
        p1 = self.launch("first")
        self.assertTrue(self.wait_ready(1))
        failing = subprocess.Popen([sys.executable, str(source), "p", "first", "--model", "nonexistent"],
                                   env=self.env, cwd=str(self.project),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(failing.wait(timeout=5), 0)
        failing.stdout.close()
        failing.stderr.close()
        self.assertIsNone(p1.poll())
        p1.kill()
        p1.wait(timeout=5)
        p3 = self.launch("first")
        self.assertTrue(self.wait_ready(2))
        self.assertIsNone(p3.poll())
        p3.terminate()
        p3.wait(timeout=5)

    def test_exclusive_lock_blocks_conflicting_operations(self):
        import fcntl
        fresh = self.home / "accounts" / "fresh"
        (fresh / "auth").mkdir(parents=True)
        lock_file = (fresh / "active.lock").open("a")
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            login = subprocess.run([sys.executable, str(source), "login", "fresh"],
                                   env=self.env, cwd=str(self.project),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(login.returncode, 0)
            self.assertIn("active claudegpt launch", login.stderr.decode())

            launch = subprocess.run([sys.executable, str(source), "p", "fresh"],
                                    env=self.env, cwd=str(self.project),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(launch.returncode, 0)
            self.assertIn("active claudegpt launch", launch.stderr.decode())
        finally:
            lock_file.close()

    def test_simulated_prefix_exclusive_lock_permits_new_authenticated_launch(self):
        import fcntl
        first = self.home / "accounts" / "first"
        lock_path = first / "active.lock"
        auth_file = first / "auth/login.json"
        auth_stat_before = auth_file.stat()
        auth_content_before = auth_file.read_text()
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl, sys, time\n"
             "f = open(sys.argv[1], 'a')\n"
             "fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
             "sys.stdout.write('LOCKED\\n')\n"
             "sys.stdout.flush()\n"
             "while True:\n"
             "    time.sleep(0.05)\n",
             str(lock_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            line = holder.stdout.readline().decode().strip()
            self.assertEqual(line, "LOCKED")
            p = self.launch("first")
            self.assertTrue(self.wait_ready(1))
            self.assertIsNone(p.poll())
            self.assertIsNone(holder.poll())
            with lock_path.open("a") as probe:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(auth_file.read_text(), auth_content_before)
            self.assertEqual(auth_file.stat().st_mtime, auth_stat_before.st_mtime)
            p.terminate()
            p.wait(timeout=5)
            self.assertIsNone(holder.poll())
            with lock_path.open("a") as probe:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            holder.terminate()
            holder.wait(timeout=5)
            if holder.stdout:
                holder.stdout.close()
            if holder.stderr:
                holder.stderr.close()


if __name__ == "__main__":
    unittest.main()
