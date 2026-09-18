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


class ChatLaunchTests(unittest.TestCase):
    def test_gateway_prompt_allows_direct_or_relay_and_forbids_native_agents(self):
        text = source.read_text()
        compact = "".join(line.strip().strip('"') for line in text.splitlines()
                           if "implementation tasks" in line or "worker-run relay" in line
                           or "is never a refusal" in line or "existing worker-pool" in line)
        self.assertIn("implement directly or delegate through the selected worker-run relay from worker-pick", compact)
        self.assertIn("Never use native implementation agents", compact)
        self.assertIn("Task size is never a refusal condition: delegate larger tasks and verify the result", compact)

    def test_launch_commands(self):
        cases = [
            (["--account", "com"], "claudeb profile com"),
            (["--account", "com", "--gateway"], "claudegpt p com --model astra"),
            (["--account", "com", "--gateway", "--model", "sol"], "claudegpt p com --model sol"),
            (["--account", "com", "--gateway", "--model", "astra"], "claudegpt p com --model astra"),
        ]
        for args, expected in cases:
            with self.subTest(args=args), patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(app.chat_resume.main(["launch", *args]), 0)
                self.assertEqual(output.getvalue().strip(), expected)

    def test_claude_launch_rejects_gateway_model(self):
        with self.assertRaises(SystemExit), patch("sys.stderr", new_callable=io.StringIO):
            app.chat_resume.main(["launch", "--account", "com", "--model", "sol"])

    def test_switch_cli_target_is_explicit(self):
        with patch.object(app.chat_resume, "is_gateway_account", return_value=True), \
             patch.object(app.chat_resume, "is_claudeb_profile", return_value=False), \
             patch("sys.stdout", new_callable=io.StringIO) as output:
            app.chat_resume.main(["switch", "fixture", "--account", "com"])
            self.assertEqual(output.getvalue().strip(), "claudeb profile com --resume fixture")

    def test_gateway_switch_pins_astra_but_a_reopen_keeps_sol(self):
        """"Switch chat to this" names the strong alias; reopening the same chat does not.

        `bin/chats` reopens through the library call, so a pin living in `switch_argv`
        itself would silently move a saved Sol conversation onto the other model.
        """
        session = "cccccccc-dddd-eeee-ffff-000000000000"
        with tempfile.TemporaryDirectory() as home:
            with patch.dict(os.environ, {"CLAUDEGPT_HOME": home}):
                app.chat_resume.write_stamp(session, "work4", "sol", home=home)
                reopens = [
                    (None, f"claudegpt p work4 --model sol --resume {session}"),
                    ("anthropic.ccr.sol", f"claudegpt p work4 --model sol --resume {session}"),
                    ("anthropic.ccr.astra", f"claudegpt p work4 --model astra --resume {session}"),
                ]
                for model_id, expected in reopens:
                    with self.subTest(reopen=model_id):
                        self.assertEqual(
                            " ".join(app.chat_resume.switch_argv(session, "work4", model_id,
                                                                 gateway=True)),
                            expected)
                self.assertEqual(
                    " ".join(app.chat_resume.resume_argv(session)),
                    f"claudegpt p work4 --model sol --resume {session}")
                switches = [
                    (["switch", session, "--account", "work4", "--gateway"],
                     f"claudegpt p work4 --model astra --resume {session}"),
                    (["switch", session, "--account", "work4", "--gateway", "--model", "sol"],
                     f"claudegpt p work4 --model sol --resume {session}"),
                    (["launch", "--account", "work4", "--gateway"],
                     "claudegpt p work4 --model astra"),
                    (["switch", session, "--account", "olx"],
                     f"claudeb profile olx --resume {session}"),
                ]
                for argv, expected in switches:
                    with self.subTest(switch=argv), \
                         patch.object(app.chat_resume, "is_claudeb_profile",
                                      side_effect=lambda name: name == "olx"), \
                         patch.object(app.chat_resume, "is_gateway_account",
                                      side_effect=lambda name: name == "work4"), \
                         patch("sys.stdout", new_callable=io.StringIO) as output:
                        app.chat_resume.main(argv)
                        self.assertEqual(output.getvalue().strip(), expected)


SIX_ACCOUNTS = ("borodatch", "burkhartor", "com", "locomthebest", "notcom", "work4")
WITH_GATEWAY_LOGIN = ("com", "notcom", "work4")


def fixture_token(expires_in=86400, email="fixture@example.test"):
    """A JWT-shaped access token: only its `exp`/`email` claims are ever read."""
    import base64
    def segment(payload):
        return base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    return f"{segment({'alg': 'none'})}.{segment({'exp': int(time.time()) + expires_in, 'email': email})}.sig"


def write_codex_profile(root, name, expires_in=86400, account_id=None, tokens=None):
    directory = Path(root) / name
    directory.mkdir(parents=True, exist_ok=True)
    payload = {"OPENAI_API_KEY": None, "auth_mode": "chatgpt",
               "last_refresh": "2026-09-11T15:32:38Z",
               "tokens": {"access_token": fixture_token(expires_in),
                          "id_token": fixture_token(expires_in, f"{name}@example.test"),
                          "refresh_token": f"refresh-{name}",
                          "account_id": account_id or f"acct-{name}"}}
    if tokens is not None:
        payload["tokens"] = tokens
    (directory / "auth.json").write_text(json.dumps(payload))
    return directory / "auth.json"


def write_gateway_login(home, name, account_id=None):
    directory = Path(home) / "accounts" / name / "auth"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"codex-{name}-plus.json"
    path.write_text(json.dumps({"type": "codex", "access_token": "gateway-access",
                                "refresh_token": f"gateway-refresh-{name}",
                                "account_id": account_id or f"acct-{name}"}))
    return path


class GatewayAuthResolverTests(unittest.TestCase):
    """One resolver decides which OpenAI accounts a gateway chat can open."""

    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        base = Path(self.root.name)
        self.profiles = base / "codex-profiles"
        self.home = base / "claudegpt"
        for name in SIX_ACCOUNTS:
            write_codex_profile(self.profiles, name)
        for name in WITH_GATEWAY_LOGIN:
            write_gateway_login(self.home, name)
        self.env = patch.dict(os.environ, {
            "CODEXB_PROFILES_DIR": str(self.profiles),
            "CLAUDEGPT_HOME": str(self.home),
            "CODEX_HOME": str(base / "no-such-codex-home"),
            "LLM_LIMITS_CODEX_CACHE": str(base / "codex-cache.json"),
            "LLM_LIMITS_CODEX_REMOVED": str(base / "codex-cache.json.removed"),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.addCleanup(self.root.cleanup)

    def test_every_codex_profile_is_a_usable_target(self):
        roster = {entry.name: entry for entry in app.gateway_auth.roster(home=str(self.home))}
        self.assertEqual(sorted(roster), sorted(SIX_ACCOUNTS))
        for name in SIX_ACCOUNTS:
            with self.subTest(account=name):
                self.assertTrue(roster[name].ready, roster[name].detail)
                self.assertEqual(roster[name].source, "codex")

    def test_gateway_only_account_keeps_working(self):
        write_gateway_login(self.home, "legacy", account_id="acct-legacy")
        entry = app.gateway_auth.resolve("legacy", home=str(self.home))
        self.assertTrue(entry.ready)
        self.assertEqual(entry.source, "gateway")

    def test_expired_access_token_is_reported_not_relogged(self):
        write_codex_profile(self.profiles, "stale", expires_in=-60)
        entry = app.gateway_auth.resolve("stale", home=str(self.home))
        self.assertTrue(entry.ready)
        self.assertEqual(entry.status, app.gateway_auth.REFRESH)
        self.assertIn("Codex", entry.detail)
        self.assertNotIn("browser", entry.detail)

    def test_identity_mismatch_keeps_the_existing_gateway_login(self):
        write_codex_profile(self.profiles, "collide", account_id="acct-codex-side")
        write_gateway_login(self.home, "collide", account_id="acct-gateway-side")
        entry = app.gateway_auth.resolve("collide", home=str(self.home))
        self.assertFalse(entry.ready)
        self.assertIn("identities differ", entry.detail)

    def test_malformed_auth_is_never_ready(self):
        directory = self.profiles / "broken"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "auth.json").write_text("{not json")
        self.assertEqual(app.gateway_auth.resolve("broken", home=str(self.home)).status,
                         app.gateway_auth.MALFORMED)
        write_codex_profile(self.profiles, "anonymous", tokens={"access_token": fixture_token()})
        self.assertEqual(app.gateway_auth.resolve("anonymous", home=str(self.home)).status,
                         app.gateway_auth.MALFORMED)

    def test_removed_main_leaves_the_roster(self):
        Path(os.environ["CODEX_HOME"]).mkdir(parents=True, exist_ok=True)
        write_codex_profile(Path(os.environ["CODEX_HOME"]).parent,
                            Path(os.environ["CODEX_HOME"]).name)
        self.assertIn("main", [e.name for e in app.gateway_auth.roster(home=str(self.home))])
        Path(os.environ["LLM_LIMITS_CODEX_REMOVED"]).write_text("")
        self.assertNotIn("main", [e.name for e in app.gateway_auth.roster(home=str(self.home))])

    def test_projection_leaves_the_rotating_secret_with_codex(self):
        canonical = self.profiles / "burkhartor" / "auth.json"
        before = canonical.read_bytes()
        destination = Path(self.root.name) / "run-auth"
        path = Path(app.gateway_auth.project("burkhartor", destination, home=str(self.home)))
        projected = json.loads(path.read_text())
        self.assertEqual(projected["type"], "codex")
        self.assertTrue(projected["access_token"])
        self.assertNotIn("refresh_token", projected)
        self.assertNotIn("id_token", projected)
        self.assertEqual(projected["account_id"], "acct-burkhartor")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        self.assertEqual(canonical.read_bytes(), before)

    def test_projection_follows_a_codex_side_rotation(self):
        destination = Path(self.root.name) / "run-auth"
        path = Path(app.gateway_auth.project("com", destination, home=str(self.home)))
        self.assertTrue(app.gateway_auth.projection_is_current("com", str(path), home=str(self.home)))
        write_codex_profile(self.profiles, "com", expires_in=90000)
        self.assertFalse(app.gateway_auth.projection_is_current("com", str(path), home=str(self.home)))
        app.gateway_auth.project("com", destination, home=str(self.home))
        self.assertTrue(app.gateway_auth.projection_is_current("com", str(path), home=str(self.home)))

    def test_a_gateway_login_is_never_projected_over(self):
        write_codex_profile(self.profiles, "collide", account_id="acct-codex-side")
        write_gateway_login(self.home, "collide", account_id="acct-gateway-side")
        with self.assertRaises(ValueError):
            app.gateway_auth.project("collide", Path(self.root.name) / "run-auth",
                                     home=str(self.home))

    def test_listing_needs_no_second_login(self):
        result = subprocess.run([sys.executable, str(source), "list"],
                                capture_output=True, text=True, env=dict(os.environ))
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in SIX_ACCOUNTS:
            self.assertIn(f"{name}: ready via codex login", result.stdout)
        self.assertNotIn("login needed", result.stdout)

    def test_all_six_launcher_paths_project_without_login(self):
        originals = {p: p.read_bytes() for p in self.profiles.glob("*/auth.json")}
        for name in SIX_ACCOUNTS:
            with self.subTest(account=name):
                inspected = []
                def proxy(command, **_kwargs):
                    config = json.loads(Path(command[command.index("-config") + 1]).read_text())
                    files = list(Path(config["auth-dir"]).glob("*.json"))
                    self.assertEqual(len(files), 1)
                    payload = json.loads(files[0].read_text())
                    self.assertEqual(payload["account_id"], f"acct-{name}")
                    self.assertNotIn("refresh_token", payload)
                    self.assertNotIn("id_token", payload)
                    inspected.append(True)
                    process = MagicMock()
                    process.poll.return_value = None
                    return process
                with patch.object(app, "STATE", self.home), \
                     patch.object(sys, "argv", [str(source), "p", name, "--model", "astra"]), \
                     patch.object(app.os, "access", return_value=True), \
                     patch.object(app, "run_setup"), \
                     patch.object(app, "relay_agents", return_value={}), \
                     patch.object(app.subprocess, "Popen", side_effect=proxy), \
                     patch.object(app.subprocess, "call", return_value=0) as launch, \
                     patch.object(app.urllib.request, "urlopen", side_effect=lambda *_a, **_k:
                                  io.BytesIO(b'{"data":[{"id":"gpt-6-astra"}]}')), \
                     patch.object(sys, "stderr", io.StringIO()):
                    self.assertEqual(app.main(), 0)
                    self.assertEqual(len(inspected), 1)
                    self.assertEqual(launch.call_count, 1)
                    self.assertNotIn("-codex-login", launch.call_args.args[0])
        self.assertEqual({p: p.read_bytes() for p in originals}, originals)

    def test_expired_token_renews_only_through_codex(self):
        write_codex_profile(self.profiles, "burkhartor", expires_in=-60)
        def renew(home, method, params, timeout):
            self.assertEqual(home, str(self.profiles / "burkhartor"))
            self.assertEqual((method, params), ("account/read", {"refreshToken": True}))
            write_codex_profile(self.profiles, "burkhartor")
            return {}
        with patch.object(app.gateway_auth.codex_appserver, "call", side_effect=renew) as rpc:
            self.assertEqual(app.gateway_auth.prepare("burkhartor").status, "ready")
            app.gateway_auth.prepare("burkhartor")
            rpc.assert_called_once()

    def test_refresh_failure_never_enters_login_path(self):
        write_codex_profile(self.profiles, "burkhartor", expires_in=-60)
        with patch.object(app.gateway_auth.codex_appserver, "call", side_effect=RuntimeError("fixture secret")), \
             patch.object(app, "STATE", self.home), \
             patch.object(sys, "argv", [str(source), "p", "burkhartor"]), \
             patch.object(app.subprocess, "Popen") as launch:
            with self.assertRaises(SystemExit) as failure:
                app.main()
            self.assertIn("no browser login", str(failure.exception))
            self.assertNotIn("fixture secret", str(failure.exception))
            launch.assert_not_called()
        self.assertFalse((self.home / "accounts/burkhartor").exists())

    def test_gateway_login_refused_on_a_name_that_has_a_codex_login(self):
        write_codex_profile(self.profiles, "taken", account_id="acct-codex-side")
        with patch.object(app, "STATE", self.home), \
             patch.object(sys, "argv", [str(source), "login", "taken"]), \
             patch.object(app.subprocess, "call") as login, \
             patch.object(app.subprocess, "Popen") as launch:
            with self.assertRaises(SystemExit) as failure:
                app.main()
            self.assertIn("already has a Codex login", str(failure.exception))
            login.assert_not_called()
            launch.assert_not_called()
        self.assertFalse(list((self.home / "accounts/taken/auth").glob("*.json"))
                         if (self.home / "accounts/taken/auth").exists() else [])

    def test_unknown_account_requires_explicit_login(self):
        with patch.object(app, "STATE", self.home), \
             patch.object(sys, "argv", [str(source), "p", "unknown"]), \
             patch.object(app.subprocess, "Popen") as launch:
            with self.assertRaises(SystemExit):
                app.main()
            launch.assert_not_called()
        self.assertFalse((self.home / "accounts/unknown").exists())

    def test_two_renewals_share_one_canonical_refresh(self):
        from concurrent.futures import ThreadPoolExecutor
        write_codex_profile(self.profiles, "burkhartor", expires_in=-60)
        def renew(*_args):
            time.sleep(0.05)
            write_codex_profile(self.profiles, "burkhartor")
            return {}
        with patch.object(app.gateway_auth.codex_appserver, "call", side_effect=renew) as rpc:
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: app.gateway_auth.prepare("burkhartor"), range(2)))
            self.assertTrue(all(a.ready for a in results))
            rpc.assert_called_once()

    def test_keeper_renews_without_an_independent_worker(self):
        path = app.gateway_auth.project("burkhartor", Path(self.root.name) / "projection")
        write_codex_profile(self.profiles, "burkhartor", expires_in=-60)
        stopped = MagicMock()
        stopped.wait.side_effect = [False, True]
        def renew(*_args):
            write_codex_profile(self.profiles, "burkhartor", expires_in=90000)
        with patch.object(app.gateway_auth.codex_appserver, "call", side_effect=renew) as rpc:
            app.keep_projection("burkhartor", Path(path).parent, path, str(self.home),
                                "acct-burkhartor", stopped)
            rpc.assert_called_once()
        self.assertTrue(app.gateway_auth.projection_is_current("burkhartor", path))
        self.assertNotIn("refresh_token", json.loads(Path(path).read_text()))

    def test_projection_does_not_follow_identity_change(self):
        path = app.gateway_auth.project("burkhartor", Path(self.root.name) / "projection")
        original = Path(path).read_bytes()
        write_codex_profile(self.profiles, "burkhartor", account_id="another-account")
        with self.assertRaises(ValueError):
            app.gateway_auth.prepare("burkhartor", expected_id="acct-burkhartor")
        with self.assertRaises(ValueError):
            app.gateway_auth.project("burkhartor", Path(path).parent, expected_id="acct-burkhartor")
        self.assertEqual(Path(path).read_bytes(), original)

    def test_removed_main_gateway_only_and_invalid_gateway(self):
        Path(os.environ["LLM_LIMITS_CODEX_REMOVED"]).write_text("")
        write_gateway_login(self.home, "main")
        self.assertTrue(app.gateway_auth.resolve("main").ready)
        p = write_gateway_login(self.home, "broken")
        p.write_text("{}")
        self.assertFalse(app.gateway_auth.resolve("broken").ready)



class LauncherTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        environment = patch.dict(os.environ, {"CODEXB_PROFILES_DIR": temporary.name,
                                              "CODEX_HOME": temporary.name})
        environment.start()
        self.addCleanup(environment.stop)

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

    def test_every_agent_is_relayed_not_only_the_worker_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "agents").mkdir()
            (root / "agents/light-research.md").write_text(
                "---\nname: light-research\ndescription: Research relay\n"
                "tools: Read, Bash\nmodel: sonnet\n---\nRelay contract.\n")
            (root / "agents/image-gen.md").write_text(
                "---\nname: image-gen\ndescription: Image relay\n"
                "tools: Read, Write, Bash\nmodel: sonnet\n---\nRelay contract.\n")
            agents = app.relay_agents(root)
            self.assertEqual(sorted(agents), ["image-gen", "light-research"])
            for agent in agents.values():
                self.assertEqual(agent["model"], "inherit")

    def test_optional_tools_and_stray_files_do_not_abort_the_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "agents").mkdir()
            (root / "agents/inherit-all.md").write_text(
                "---\nname: inherit-all\ndescription: No tools line\nmodel: sonnet\n---\nRelay contract.\n")
            (root / "agents/README.md").write_text("Notes about the agents directory.\n")
            (root / "agents/nameless.md").write_text("---\nname: nameless\n---\nNo description.\n")
            agents = app.relay_agents(root)
            self.assertEqual(sorted(agents), ["inherit-all"])
            self.assertNotIn("tools", agents["inherit-all"])
            self.assertEqual(agents["inherit-all"]["model"], "inherit")

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
            for name in ("first", "second", "new-account"):
                auth = state / "accounts" / name / "auth"
                auth.mkdir(parents=True)
                (auth / "fixture.json").write_text(json.dumps({"type": "codex", "access_token": "fixture", "account_id": f"acct-{name}"}))
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
            (state / "accounts/work4/auth/fixture.json").write_text(json.dumps({"type": "codex", "access_token": "fixture", "account_id": "acct-work4"}))
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

    def test_a_reopen_pins_its_permission_mode_on_the_router(self):
        # `ccr launch --help`: CCR owns --permission-mode and every CCR-owned option must
        # precede `--`, so forwarding the mode `bin/chats` appends as a Claude Code option
        # ends the launch instead of reopening the chat.
        owned = ("--model", "--auth-mode", "--claude-account", "--permission-mode", "--db", "-p", "--print")
        rejected = []

        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "store"
            (state / "accounts/work4/auth").mkdir(parents=True)
            (state / "accounts/work4/auth/fixture.json").write_text(
                json.dumps({"type": "codex", "access_token": "fixture", "account_id": "acct-work4"}))
            session = "11111111-2222-3333-4444-555555555555"
            argv = app.chat_resume.switch_argv(session, "work4", model_id="anthropic.ccr.sol",
                                               gateway=True) + ["--permission-mode", "bypassPermissions"]
            captured = []

            def call(command, **kwargs):
                captured.append(command)
                forwarded = command[command.index("--") + 1:] if "--" in command else []
                for argument in forwarded:
                    if argument.split("=")[0] in owned:
                        rejected.append(argument)
                        return 2
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
                 patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(Path(temporary) / "claude")}), \
                 patch.object(app.sys, "argv", argv):
                self.assertEqual(app.main(), 0)
            command = captured[-1]
            self.assertEqual(rejected, [])
            boundary = command.index("--")
            self.assertLess(command.index("--permission-mode"), boundary)
            self.assertEqual(command[command.index("--permission-mode") + 1], "bypassPermissions")
            self.assertNotIn("--permission-mode", command[boundary:])
            self.assertNotIn("bypassPermissions", command[boundary:])
            self.assertEqual(command[command.index("--model") + 1], "sol")
            self.assertEqual(command[-2:], ["--resume", session])

    def test_failed_first_login_does_not_start_chat(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(app, "STATE", Path(temporary)), \
             patch.object(app.os, "access", return_value=True), \
             patch.object(app.subprocess, "call", return_value=1) as login, \
             patch.object(app.subprocess, "Popen") as proxy, \
             patch.object(app.sys, "stderr", io.StringIO()), \
             patch.object(app.sys, "argv", ["claudegpt", "login", "new-account"]):
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
            (auth / "login.json").write_text(json.dumps({"type": "codex",
                "access_token": "fixture-access", "account_id": f"acct-{name}"}))
        self.env = os.environ.copy()
        self.env["CODEXB_PROFILES_DIR"] = str(self.root / "codex-profiles")
        self.env["CODEX_HOME"] = str(self.root / "codex-main")
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

    def capture_effort_launch(self, argv, expected="high", environment=None):
        capture = self.root / "argv.json"
        router_capture = self.root / "router-argv.json"
        self.env.pop("CLAUDE_CODE_EFFORT_LEVEL", None)
        self.env.update(environment or {})
        self.env["TEST_CLAUDE_ARGV"] = str(capture)
        self.env["TEST_ROUTER_ARGV"] = str(router_capture)
        (self.bin_dir / "ccr").write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "if 'launch' not in sys.argv: sys.exit(0)\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['TEST_ROUTER_ARGV'], 'w') as f: json.dump(args, f)\n"
            "forwarded = args[args.index('--') + 1:]\n"
            "owned = {'--model', '--auth-mode', '--permission-mode', '--db', '-p', '--print', "
            "'--no-history', '--no-lifecycle', '--no-statusline'}\n"
            "options = forwarded[:forwarded.index('--')] if '--' in forwarded else forwarded\n"
            "assert not any(arg.split('=')[0] in owned for arg in options)\n"
            "os.execvp('claude', ['claude', *forwarded])\n")
        (self.bin_dir / "claude").write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "with open(os.environ['TEST_CLAUDE_ARGV'], 'w') as f: json.dump(sys.argv[1:], f)\n")
        proxy = self.bin_dir / "cli-proxy-api"
        proxy.write_text(proxy.read_text().replace(
            "[{'id': 'gpt-5.6-sol'}]", "[{'id': 'gpt-5.6-sol'}, {'id': 'gpt-6-astra'}]"))
        proc = self.launch(argv[2], extra=argv[3:])
        stdout, stderr = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0, stderr.decode())
        actual = json.loads(capture.read_text())
        router = json.loads(router_capture.read_text())
        boundary = router.index("--")
        self.assertEqual(actual, router[boundary + 1:])
        self.assertFalse(any(arg.startswith("--effort") for arg in router[:boundary]))
        options = actual[:actual.index("--")] if "--" in actual else actual
        self.assertEqual(app.forwarded_value(options, "--effort"), expected)
        self.assertEqual(sum(arg == "--effort" or arg.startswith("--effort=")
                             for arg in options), 1)
        return actual

    def test_direct_gateway_effort_reaches_claude_stub(self):
        for model in ("sol", "astra"):
            for extra, expected in (([], "high"), (["--effort", "low"], "low"),
                                    (["--effort=medium"], "medium"),
                                    (["--", "--effort", "max"], "max")):
                with self.subTest(model=model, extra=extra):
                    self.capture_effort_launch(
                        ["claudegpt", "p", "first", "--model", model, *extra], expected)
        self.capture_effort_launch(["claudegpt", "p", "first"], "low",
                                   {"CLAUDE_CODE_EFFORT_LEVEL": "low"})

    def test_chats_resume_effort_reaches_claude_stub(self):
        command = app.chat_resume.switch_argv("fixture-session", "first",
                                              model_id="anthropic.ccr.astra", gateway=True)
        actual = self.capture_effort_launch(command)
        self.assertEqual(app.forwarded_value(actual, "--resume"), "fixture-session")

    def test_switch_resolver_effort_reaches_claude_stub(self):
        for mode in (["launch"], ["switch", "fixture-session"]):
            result = subprocess.run(
                [sys.executable, str(source.parent.parent / "share/chat_resume.py"),
                 *mode, "--account", "first", "--gateway"],
                env=self.env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            actual = self.capture_effort_launch(result.stdout.strip().split())
            if mode[0] == "switch":
                self.assertEqual(app.forwarded_value(actual, "--resume"), "fixture-session")

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
            self.assertIn("no saved OpenAI authorization", launch.stderr.decode())
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
