# Handoff: restore worker-driven browser automation (Dia) for every GPT and Claude account

Written 2026-09-10 by the "search" chat (OpenAI-discount research). Egor's ask: workers must be able to drive his browser (Dia) again, on any account, because both documented paths are broken today. Both failures were reproduced in this session; quotes below are from the live runs.

## Goal

A headless worker (codex-worker first, claudeb-worker fallback) can open Dia, click through a site and stop where the brief says, launched through `worker-run` so the run is owned, tagged and limit-tracked. Acceptance test at the end.

## What broke, with evidence

### 1. Codex headless runs no longer expose Computer Use

`worker-run start codex` (account burkhartor, EFFORT medium, codex-cli 0.153.4) ran the brief twice; Codex reported no computer-use or browser-control tools. Exact tool list the session had, as reported by the relay:

```
functions.exec, functions.wait, functions.request_user_input(_async), clock.sleep,
collaboration.* (followup_task, interrupt_agent, list_agents, send_message, spawn_agent, wait_agent),
apply_patch, clock__curr_time, create_goal/get_goal/update_goal, exec_command, image_gen__imagegen,
list_mcp_resource_templates, list_mcp_resources, read_mcp_resource, request_plugin_install,
view_image, web__run, write_stdin, mcp__codex_apps__* (document_control, hotline, plugin_management,
safety_settings, sites_*), mcp__node_repl__js*
```

Relevant state in `~/.codex/config.toml` (read this session):

```
[plugins."computer-use@openai-bundled"]          enabled = true      (line ~222)
[plugins."unified-computer-use@openai-bundled"]  enabled = true      (line ~240)
[plugins."chrome@openai-bundled"]                enabled = true
[plugins."browser@openai-bundled"]               enabled = true
[mcp_servers.computer-use]                                           (line ~7663)
command = "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
args = ["mcp"]   cwd = "."   enabled = false
[shell_environment_policy.set]
NODE_REPL_TRUSTED_SERVICES = '{"browser": ".../plugins/cache/openai-bundled/browser/26.901.51231/scripts/browser-service.mjs", "sky": "@oai/sky/service"}'
SKY_CUA_SERVICE_PATH = "/Users/egorloy/.codex/computer-use/Codex Computer Use.app"
CODEX_CLI_PATH = "/Applications/ChatGPT.app/Contents/Resources/codex"
```

The helper app was not running at first; `open "~/.codex/computer-use/Codex Computer Use.app"` started `SkyComputerUseService` (pgrep confirmed) but the second run still had no tools. `~/.claude/docs/browser-ui-work.md` says Computer Use was "verified in headless exec, 2026-07-19", so something changed since: candidates are the plugin now being served through `node_repl` + `NODE_REPL_TRUSTED_SERVICES` (tool names changed, brief/agent doc out of date), `mcp_servers.computer-use enabled = false`, the codex CLI binary used by `worker-run` differing from `CODEX_CLI_PATH` (ChatGPT.app's bundled codex), or flags `worker-run` passes to `codex exec` (see `bin/worker-run` around line 736, `--skip-git-repo-check`) dropping plugins. Unverified: whether an interactive `codex` in a terminal shows the tools today; check that first, it splits "plugin broken" from "headless launch drops it".

### 2. The claude-in-chrome fallback is blocked by the launch gate

`~/.claude/docs/browser-ui-work.md` and `agents/claudeb-worker.md` (claude-setup repo) prescribe:

```
claudeb profile $(cat ~/.claude-profiles/.claudeb/chrome-account) -p --chrome ...
```

`bin/worker-launch-gate.sh` (this repo) denies every `claudeb profile <x> -p` from Bash, both in the chat and inside the claudeb-worker relay:

```
Blocked: `claudeb profile com -p` is a bare headless vendor launch — it leaves no worker-run record,
no statusline tag, no journal ownership, no pool refusal, no limit signature and no stall watch.
Launch it through `worker-run start <claudeb|codex|gemini|grok> --brief <file> --workdir <dir>` ...
```

and `worker-run start` has no `--chrome`:

```
worker-run start <claudeb|codex|gemini|grok> --brief <file> [--workdir <dir>] [--account <n>] [--model <m>]
  [--effort <e>] [--resume <id>] [--add-dir <d>]... [--image <p>]... [--web-search]
```

So the documented fallback cannot be executed anywhere. `~/.claude-profiles/.claudeb/chrome-account` = `com` (the only account the Dia extension is paired with).

## Suggested fix shape (design is the next chat's call)

1. Add `--chrome` to `worker-run start claudeb`: pass `--chrome` through to `claude`, force the account from `chrome-account` (refuse `--account` that differs, since the extension pairs with one account), keep the headless hard rule from the doc (use `list_connected_browsers` only; never `switch_browser` or pairing). This removes the gate conflict without loosening the gate.
2. Diagnose and restore Codex Computer Use in `worker-run start codex`; update `agents/codex-worker.md` and `global/docs/browser-ui-work.md` in claude-setup with the actual tool names and any required flag.
3. Egor's constraint: browser work must be usable from every GPT and Claude account, so document per-vendor what is account-bound (claude extension = one account) and what is not (Codex Computer Use drives the app directly).
4. Update `browser-ui-work.md`: the "verified 2026-07-19" claims are stale for both paths.

## Acceptance test

Dia running. Through `worker-run` only, from a chat:
- codex-worker brief "open https://httpbin.org/anything/cu-test in Dia, read the JSON `url` field back, close the tab" returns the URL and a screenshot, driving the no-profile-name instance (extension id `b99c85f0-35bc-4bc9-a750-627802c47fcc`), never the "Egor work" Chrome instance.
- claudeb-worker brief with the same task through the new `--chrome` path returns the URL without opening any login window.
- `bin/worker-launch-gate.sh` still denies a bare `claudeb profile com -p --chrome` from chat Bash (tests in `tests/`).

## Pending user task this unblocks

Register a ~$3 first-year .com at Namecheap in Dia and stop at card entry; brief saved at
`/private/tmp/claude-501/-Volumes-Work-Projects-search/8165299c-c2fc-49af-a6ec-92eb8ed8fcb1/scratchpad/chrome-brief.md`
(scratchpad of the search chat; may be gone later, the brief is reproducible from this file's goal line). Egor may have done it by hand already; ask before re-running.

## Shared checkout note

llm-legs and claude-setup both have uncommitted changes from other chats (`git status` showed modified `bin/worker-run`, `bin/report-bus`, `docs/*` here; `hooks/*`, `global/CLAUDE.md` in claude-setup). Those are someone's live work: never revert, stash or clean them.
