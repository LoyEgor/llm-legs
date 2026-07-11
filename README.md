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

`llm-limits.sh` reads local CLI state without invoking a vendor CLI, making a network request,
or spending tokens. It prints schema-1 JSON and atomically refreshes `~/.llm-limits.json` by
default. The stable top level is `{schema, fetched_at, vendors}`. Claude includes
`current_account`, an ordered `accounts` array, and the current account's `five_hour`, optional
`weekly`, `as_of`, and `stale_seconds` hoisted at vendor level for compatibility. Each account has
its own windows and freshness. Use `--plain` for a
human-readable summary or `--no-write` to leave the cache untouched. `--refresh` is reserved for
the manual Get Data action: it live-polls all Claude accounts through `claudeb accounts` before
reading their files. Without that flag, collection remains token-free and file-read-only.

Claude reads every `$CLAUDEB_DIR/.claudeb/limits/*.json` account (`CLAUDEB_DIR` defaults to
`~/.claude-profiles`) and uses `.claudeb-state` to select the current account. If that store is
absent, it falls back to the freshest Claude status-line snapshot as a single `main` account.

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
| Codex | As of the last Codex turn that emitted rate limits |
| Gemini | Not available; only an optional last-wall timestamp is reported |
