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
  leg for the rest of the run instead of retrying into the wall).
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
  mapped to a distinct exit code; gemini's CLI-era hang-on-quota lesson is documented in the
  wrapper headers.
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

## Subscription limit collector

`llm-limits.sh` normally reads cached local CLI state without invoking a vendor CLI, making an
external network request, or spending tokens. It prints schema-1 JSON and atomically refreshes
`~/.llm-limits.json` by default. When no output flag is given and stdout is a terminal, it
renders the `--table` view instead; piped or redirected output keeps the JSON default, and an
explicit `--json`, `--plain`, or `--table` always wins. The stable top level is
`{schema, fetched_at, vendors}`. Claude includes
`current_account`, an ordered `accounts` array, and the current account's `five_hour`, optional
`weekly`, `as_of`, and `stale_seconds` hoisted at vendor level for compatibility. Each account has
its own windows and freshness, plus an `enabled` flag reflecting its claudeb rotation membership
(absent means enabled). Use `--plain` for a
human-readable summary or `--no-write` to leave the cache untouched. `--table` renders an aligned
terminal table with one row per entity — every Claude account (the current one is marked `*`),
then codex
and gemini — with 5h/weekly used% and local reset times, plus a NOTE column (Claude fable %, codex
plan, gemini quota group, and a `stale Nh` marker when a snapshot is over an hour old). Percent
columns are colorized only when stdout is a TTY; piped output stays plain ASCII. `--sort
5h|weekly|reset` reorders the table by that column (descending for percentages, ascending by the
nearest of the 5h and weekly resets). For a PATH entry point, symlink the script — it resolves its
own symlink, so helper
discovery keeps working:

```bash
ln -s /Volumes/Work/Projects/llm-legs/llm-limits.sh ~/.local/bin/llm-limits
llm-limits --table --sort 5h
```

`--refresh` is reserved for the manual Get Data & Refresh action. It always performs Claude's
free usage-endpoint poll through `claudeb accounts --no-spend` and fetches Gemini quota through
agy's authenticated localhost Connect RPC.
The Codex leg is a zero-spend usage query too: `codex-quota.py` asks the local
`codex app-server` for `account/rateLimits/read` and the response is cached in
`~/.llm-limits-codex.json`; rollout session files remain the passive fallback when they are
newer or the helper is unavailable. `--refresh --start-windows` is the only paid path: for each
vendor whose five-hour window has already reset it issues one minimal model call (claudeb's own
`--refresh --start-windows`, a one-word `codex exec`, a one-word `agy --print`) to start a fresh
window, then re-reads the free usage endpoints. Vendors that cannot be started are reported on
stderr, never skipped silently.
The Gemini request is the machine-readable equivalent of `/usage`; it consumes no model tokens
and its last valid response is cached in `~/.llm-limits-gemini.json`. Without `--refresh`,
collection remains token-free and external-network-free; it also reads the optional claudebd
localhost status endpoint.

### Machine contract

Consumers read `~/.llm-limits.json`.
A bare `llm-limits` run is a passive read with zero external network access.
`llm-limits --refresh` performs a free live refresh.
Scripts must never invoke `--start-windows`; it spends money.
Read each bucket's `effective_pct` and each vendor's `usable_now`.
Never make availability decisions from raw `used_pct`.
Raw usage values persist for provenance after a window expires, while `effective_pct` becomes 0.
Claude `usable_now` considers enabled, authenticated accounts and their general 5h/weekly limits;
the model-specific fable bucket does not block other Claude work.
Codex and Gemini additionally require `available == true`.
Respect bucket and vendor `stale` flags when freshness matters.
`vendors.claude.daemon.walls` reports active account/scope walls with their known deadline and
reason. `all_walled_until.general` and `.fable` are non-null only when every known daemon account
is walled for that scope; `reachable == false` means local daemon status was unavailable.

Claude reads the `$CLAUDEB_DIR/limits/*.json` accounts (`CLAUDEB_DIR` defaults to
`~/.claude-profiles/.claudeb`) and uses `.claudeb-state` to select the current account. `main`
(the default plain-`claude` login, not a real claudeb token account) is excluded from every
output — JSON, cache, `--plain`, and `--table` — so only real claudeb token accounts are
reported. If the store is
absent, it falls back to the freshest Claude status-line snapshot as a single `main` account.

`claudeb disable <name>` takes an account out of auto-rotation and `claudeb enable <name>` puts
it back; the set lives in `$CLAUDEB_DIR/disabled` (one name per line, missing file = all
enabled). Disabled accounts are never auto-picked, but `claudeb use` (and the menu's Make
Current) is independent of membership: a disabled account made current sticks until it hits a
limit, then auto-rotation resumes among enabled accounts. The last enabled account cannot be
disabled, and each JSON account carries the resulting `enabled` flag.

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
| Gemini | Last successful manual Get Data & Refresh through agy's localhost quota RPC |

Gemini refresh launches `agy` under a bounded PTY, waits for normal authenticated startup, finds
its localhost listener, and calls
`LanguageServerService/RetrieveUserQuotaSummary`. Set `AGY_WORKDIR` to an already trusted folder
if the repository itself has not been opened in agy. Overrides for tests or alternate installs:
`AGY_BIN`, `LLM_LIMITS_GEMINI_CMD`, and `LLM_LIMITS_GEMINI_CACHE`.

## claudeb multi-account suite (`bin/`)

Canonical sources for the multi-account Claude Code tooling; installed via symlinks:

- `bin/claudeb` → `~/.local/bin/claudeb` — account prober/launcher (OAuth auto-refresh, `--start-windows`, headless passthrough for worker agents).
- `bin/claudebd` → `~/.local/bin/claudebd` — rotating proxy daemon on 127.0.0.1:45789 (launchd label `com.claudeb.daemon`; `claudeb daemon install`).
- `bin/statusline.sh` → `~/.claude/statusline.sh` — Claude Code statusline; also writes per-account limit snapshots on real usage.

Snapshot store and schema live in `~/.claude-profiles/` (documented in its README). If this volume is not mounted at login, the daemon start is retried by the next `claudeb` invocation.
