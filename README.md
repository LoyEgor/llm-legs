# llm-legs

Battle-tested **subscription-only vendor legs** for local multi-model orchestration: call
OpenAI GPT, Google Gemini, and Anthropic Claude headlessly through their subscription CLIs —
no API keys, no per-call billing — with tier guards, quota signaling, and an audit trail.

Shared by local "model-symbiosis" projects (e.g. multi-model offer research, portfolio
decision-support) as a git submodule. One fix here propagates to every consumer via a pin bump.

## The legs

| Script | Vendor | Transport | Default model |
|--------|--------|-----------|---------------|
| `ask_codex.sh` | OpenAI | `codex exec` (read-only sandbox) | CLI flagship (auto-tracked, no pin) |
| `ask_gemini.sh` | Google | Antigravity `agy --print` | `Gemini 3.1 Pro (High)` → in-family fallback `(Low)` |
| `ask_claude.sh` | Anthropic | `claude -p --output-format json` | `opus` alias (cost ceiling: Opus — Mythos-class refused) |

## Contract (what consumers may rely on)

- **Input:** prompt as `$1` or stdin. **Output:** the model's text answer on stdout.
- **Exit codes:** `0` ok · `1` transport/leg failure · `3` weak-tier model refused (a weak model
  must never sit in a judgment seat) · `5` subscription quota exhausted (callers should drop the
  leg for the rest of the run instead of retrying after exhaustion).
- **Audit:** every call appends `{ts, leg, requested, served, weak_tier}` to
  `$LLM_LEGS_DATA_DIR/served-models.jsonl` (default: `$PWD/data` — orchestrators invoke legs
  with cwd = project root; set `LLM_LEGS_DATA_DIR` explicitly for cron/launchd).
- **Probes:** every leg supports `--probe` (health check; gemini's spends no quota).

## Guard rails baked in

- **Tier guard, not version pin:** served models are extracted and classified; weak tiers
  (mini/nano/lite/flash/haiku/...) fail the call rather than silently degrade judgment.
  Overrides: `CODEX_ALLOW_WEAK=1`, `GEMINI_ALLOW_WEAK=1`, `CLAUDE_ALLOW_WEAK=1`.
- **Billing traps disarmed:** stray `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` env vars are unset so
  calls never silently flip from subscription to API billing.
- **Quota → exit 5:** "you've hit your usage limit" (codex) and quota signals (gemini) are
  mapped to a distinct exit code; agy's silent-quota behavior (rc 0 with empty output, the real
  RESOURCE_EXHAUSTED only in its log) is documented in the wrapper headers.
- **Read-only:** codex runs in a read-only sandbox; claude disallows mutating tools; gemini
  (agy) is print-mode only.
- **Receipts where possible:** claude's served model is verified from `.modelUsage` (auxiliary
  haiku entries do not poison the guard); codex's from the CLI banner. agy does NOT report the
  served model — its audit rows record the pin, marked unverified.

## Knobs

`CODEX_MODEL`, `CODEX_EFFORT` (minimal..xhigh) · `AGY_MODEL`, `AGY_MODEL_FALLBACK`,
`AGY_PRINT_TIMEOUT` · `CLAUDE_MODEL` (sonnet/opus tiers) · `LLM_LEGS_DATA_DIR`.

## Consuming as a submodule

```bash
git submodule add https://github.com/LoyEgor/llm-legs lib/legs
# call: lib/legs/ask_codex.sh "prompt"   (invoke with cwd = your project root)
# update later: git -C lib/legs pull && git add lib/legs && git commit -m "bump llm-legs"
```

Tests: `python3 -m unittest discover tests`.

## Daily self-check
`llm-selfcheck` runs the live zero-spend menubar refresh check, then the hermetic limits, claudeb, codexb, and geminib suites every day at 10:30 local time.
Each run is recorded in `~/.claude-profiles/.claudeb/selfcheck.log`; failures also raise a Hammerspoon alert and a macOS notification.

## Subscription limit collector

`llm-limits.sh` normally reads cached local CLI state without invoking a vendor CLI, making an
external network request, or spending tokens. It prints schema-1 JSON and atomically refreshes
`~/.llm-limits.json` by default. When no output flag is given and stdout is a terminal, it
renders the `--table` view instead; piped or redirected output keeps the JSON default, and an
explicit `--json`, `--plain`, or `--table` always wins. The stable top level is
`{schema, fetched_at, vendors}`. Claude includes
`current_account`, an ordered `accounts` array, and the current account's `five_hour`, optional
`weekly`, `as_of`, and `stale_seconds` hoisted at vendor level for compatibility. Each account has
its own windows and freshness; account and vendor age use the oldest `as_of` among windows with a
numeric `used_pct`, ignoring absent and null-valued windows. Each account also has an `enabled`
flag reflecting worker-selection membership
(absent means enabled). Use `--plain` for a human-readable line per account or `--no-write` to
leave the cache untouched. `--table` renders the same model as aligned columns: 5h, weekly, and
Fable percentages and local reset times; account age; Claude worker-pool state; Codex reset credits;
and vendor status. Fable is `-` for rows without that bucket. `~` and `!` suffix percentage values
whose snapshots are stale or whose reset has passed, without rewriting the last known `used_pct`.
`ROT` is `off` for a disabled Claude account, `limit-5h`/`limit-weekly`/`fb:limit-fable`
when a local effective percentage reaches 100, or `-` otherwise. Transient upstream 429s
are handled by the Claude CLI's own retry behavior.
`CR` renders Codex reset credits as `↻N`. The current account is marked `*`; plan tags and Gemini
quota-group labels are omitted. Percent columns are colorized only when stdout is a TTY; piped
output stays plain text. `--sort
5h|weekly|reset` reorders the table by that column (descending for percentages, ascending by the
nearest of the 5h, weekly, and Fable resets). For a PATH entry point, symlink the script — it resolves its
own symlink, so helper
discovery keeps working:

```bash
ln -s /Volumes/Work/Projects/llm-legs/llm-limits.sh ~/.local/bin/llm-limits
llm-limits --table --sort 5h
llm-limits --plain
```

`--refresh` is reserved for the manual Get Data & Refresh action. It always performs Claude's
free usage-endpoint poll through `claudeb accounts --no-spend` and fetches each Gemini profile's
quota through agy's authenticated localhost Connect RPC.
The Codex leg is a zero-spend usage query too: `codex-quota.py` asks the local
`codex app-server` for `account/rateLimits/read` and the response is cached in
`~/.llm-limits-codex.json`; rollout session files remain the passive fallback when they are
newer or the helper is unavailable. `--refresh --start-windows` is the only paid path: for each
vendor whose five-hour window has already reset it issues one minimal model call (claudeb's own
`--refresh --start-windows`, a one-word `codex exec`, a one-word `agy --print`) to start a fresh
window, then re-reads the free usage endpoints. Vendors that cannot be started are reported on
stderr, never skipped silently.
The Gemini request is the machine-readable equivalent of `/usage`; it consumes no model tokens.
The `main` profile keeps the legacy cache `~/.llm-limits-gemini.json`; named profiles use
`~/.llm-limits-gemini/<name>.json`. `--refresh-account gemini/<name>` refreshes only that
profile. Without `--refresh`, collection remains token-free and external-network-free.

### Machine contract

Consumers read `~/.llm-limits.json`.
A bare `llm-limits` run is a passive read with zero external network access.
`llm-limits --refresh` performs a free live refresh.
Scripts must never invoke `--start-windows`; it spends money.
Read each bucket's `effective_pct` and each vendor's `usable_now`.
Never make availability decisions from raw `used_pct`.
`vendors.codex.accounts` is always a non-empty array when Codex is available; legacy snapshots synthesize `main`.
`vendors.codex.current_account` names the account whose buckets remain hoisted at vendor level.
Each `vendors.codex.accounts[]` may expose `reset_credits` and `auth_needed`; auth-needed accounts have no usage buckets and are never usable.
With only `main`, Gemini retains its legacy single-vendor shape. Once a named profile exists,
`vendors.gemini.accounts` contains per-profile buckets, auth-needed state, refresh causes, and
removed markers; `main` remains hoisted for compatibility.
Raw usage values persist for provenance after a window expires, while `effective_pct` becomes 0.
Claude `usable_now` considers enabled, authenticated accounts and their general 5h/weekly limits;
the model-specific fable bucket does not block other Claude work.
Codex and Gemini additionally require `available == true`.
Respect bucket and vendor `stale` flags when freshness matters.
Claude reads the `$CLAUDEB_DIR/limits/*.json` accounts (`CLAUDEB_DIR` defaults to
`~/.claude-profiles/.claudeb`) and uses `.claudeb-state` to select the current account. `main`
(the default plain-`claude` login, not a real claudeb token account) is excluded from every
output — JSON, cache, `--plain`, and `--table` — so only real claudeb token accounts are
reported. The terminal formats expose the same per-account windows, age, rotation, credits, and
status fields. If the store is
absent, it falls back to the freshest Claude status-line snapshot as a single `main` account.

`claudeb disable <name>` removes an account from worker selection and `claudeb enable <name>`
puts it back; the set lives in `$CLAUDEB_DIR/disabled` (one name per line, missing file = all
enabled). An explicit `claudeb profile <name>` launch bypasses membership. The last enabled
account cannot be disabled, and each JSON account carries the resulting `enabled` flag.

Set `LLM_LIMITS_WALLS_LOG` to a `served-models.jsonl` audit log to include the most recent
exit-5 wall timestamp for each vendor. `LLM_LIMITS_CACHE` overrides the cache path.

For Hammerspoon, copy or symlink `hammerspoon/llm-limits.lua` into `~/.hammerspoon`. Requiring
the module has no side effects. Use its menu items inside an existing menu:

```lua
local limits = require("llm-limits")
local submenu = { title = "LLM Limits", menu = limits.menuItems() }
```

| Vendor | Limit freshness |
|--------|-----------------|
| Claude | Per-account claudeb file mtime; status-line snapshot fallback |
| Codex | Live app-server rate-limits RPC on refresh; last rollout event otherwise |
| Gemini | Per-profile last successful manual Get Data & Refresh through agy's localhost quota RPC |

Gemini refresh launches `agy` under each profile's `HOME`, waits for normal authenticated startup,
finds its localhost listener, and calls
`LanguageServerService/RetrieveUserQuotaSummary`. Set `AGY_WORKDIR` to an already trusted folder
if the repository itself has not been opened in agy. Overrides for tests or alternate installs:
`AGY_BIN`, `LLM_LIMITS_GEMINI_CMD`, `LLM_LIMITS_GEMINI_CACHE`,
`GEMINIB_PROFILES_DIR`, and `LLM_LIMITS_GEMINI_ACCOUNTS_DIR`.

## claudeb multi-account suite (`bin/`)

Canonical sources for the multi-account Claude Code tooling; installed via symlinks:

- `bin/claudeb` → `~/.local/bin/claudeb` — account prober/launcher (OAuth auto-refresh, `--start-windows`, headless passthrough for worker agents).
- `bin/statusline.sh` → `~/.claude/statusline.sh` — Claude Code statusline; also writes per-account limit snapshots on real usage.

Snapshot store and schema live in `~/.claude-profiles/` (documented in its README).

- `bin/claude-resume-timer` → `~/.local/bin/claude-resume-timer` — `[app|terminal|auto] [extra-minutes]`
  reads the given (or auto-detected) account's 5h window from `~/.llm-limits.json` and arms the
  Hammerspoon `ClaudeContinue.startTimerFor` per-destination resume timer for that reset + extra
  minutes (default +10), falling back to +15 minutes if the window is expired or unknown.

## codexb multi-account suite

Same idea for OpenAI Codex CLI, without a proxy daemon: each extra account lives in its own
`CODEX_HOME` under `~/.codex-profiles/<name>` (auth, sessions, history are per-account; config,
AGENTS.md, skills, plugins, rules are symlinked to `~/.codex`). The default `~/.codex` account is
always available as `main` and is never modified.

- `bin/codexb` → `~/.local/bin/codexb` — `profile <name> [args...]` (create the profile if missing
  and exec codex under it, so a bare launch prompts login; aliases `p`, `run`), `add <name>`
  (create a profile without launching + print the login command), `list`, `status` (per-account
  quota via the zero-spend app-server RPC), `pick` (freest usable account).

Adding an account: `codexb profile work` creates it and launches codex, which prompts login in one
step (mirrors `claudeb profile <name>`); `codexb profile work login` runs the browser OAuth flow the
menu uses. Afterward `codexb status` should show both accounts. Worker agents pick the freest account automatically (`codexb pick`) unless
pinned via `codex_profile=` in the worker toggle file; the menubar shows per-account rows once more
than one account exists.

## geminib multi-account suite

The existing Antigravity login is `main` and continues to use the real home directory unchanged.
Named accounts live under `~/.gemini-profiles/<name>` and launch with
`HOME=~/.gemini-profiles/<name>`; shared non-auth Gemini settings are symlinked from
`~/.gemini`. Antigravity exposes no narrower supported profile flag or environment variable.
Each profile also gets its **own** `Library/Keychains/login.keychain-db`, created on first use
with a random password kept in the profile's `.keychain-password`. agy stores its OAuth token in
the login keychain macOS resolves from `$HOME` and prefers it over the profile's token file, so a
profile sharing the real keychain silently authenticates as the base account — a profile without
any keychain instead raises the modal "A keychain cannot be found to store antigravity" dialog on
every refresh. A profile still holding the old symlink is converted on the next `geminib` run and
has to sign in once more. macOS refuses `security unlock-keychain` on anything named
`login.keychain-db`, so a profile keychain that locks is signed in again rather than unlocked.

- `bin/geminib` → `~/.local/bin/geminib` — `profile|p|run <name> [args...]` creates a missing
  profile and launches agy for its one-time login, `add <name>` creates without launching,
  `remove <name>` forgets any named profile but never `main`, and `list`/`status` report every
  profile.

Adding an account: `geminib profile work` opens an isolated, logged-out Antigravity profile and
prompts for Google login. Then run `geminib status` and
`llm-limits --refresh-account gemini/work --table`. Worker routing uses the same
headroom/runway/staleness rules as before, prints `ACCOUNT: work`, and treats `main` as the
last-resort profile unless `gemini_profile=` pins it.

## OpenCode Go review models

`bin/opencode-go` is a read-only client for the OpenCode Go subscription: an OpenAI-compatible
gateway whose base URL is pinned, so pay-as-you-go Zen models can never be billed. The key comes
from the macOS Keychain and never reaches curl's argv; `OPENCODE_GO_PROFILE=<name>` selects the
service `opencode-go-<name>` when more than one subscription key exists. There is no usage
endpoint — a spent window is only visible as an HTTP 429 naming `limitName`, so a wall means stop
and come back later, never retry.

`review-bench` reads key priority from `~/.config/opencode-go/profiles`, one profile name per
line. A line containing only `-` selects the default unnamed key; blank lines and lines beginning
with `#` are ignored. If the file is missing, only the default key is used.

- `opencode-go key` stores a key, `models` lists the plan, `run <model> …` reviews a prompt file,
  `raw <path>` posts an arbitrary body. `--effort` and `--no-reasoning` are mutually exclusive:
  the reasoning-off knob silently overwrites an effort, and which knob a model accepts varies
  between requests, so the client negotiates per request rather than pinning a strategy.

These models are review raters only, never workers: the client has no agentic loop. Their measured
capability, the composition that survived strict adjudication, and the plan models that failed
screening are printed by `review-bench oc-models`; a review runs as `review-bench run <sha> --leg`.
