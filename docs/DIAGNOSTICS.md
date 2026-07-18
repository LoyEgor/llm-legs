# Diagnostics: llm-legs multi-account/limits ecosystem

For LLM sessions asked to fix limits, the menu, or claudeb. Read this before touching code.
Facts below are grounded in the code as of 2026-07-16 (line numbers may drift — re-grep, don't trust blindly).

## System map

- `llm-limits.sh` — read-only collector, writes `~/.llm-limits.json` (schema `{schema, fetched_at, vendors}`). A failed vendor refresh preserves its last valid buckets and records `vendors.<vendor>.refresh_error` as `{cause,at}`; passive collects preserve that outcome, and the next successful refresh of that vendor clears it. A full refresh with no successful vendor records the same shape at top-level `refresh_error` and exits nonzero; partial and targeted failures exit zero. `--refresh` polls free usage endpoints; `--start-windows` is the only paid path (never call from scripts). `--table`/`--plain`/`--json` control rendering; piped output defaults to JSON.
- `bin/claudeb` — account prober/launcher. Snapshots per account in `~/.claude-profiles/.claudeb/limits/<name>.json`:
  ```json
  {"five_hour":{"used_percentage":6,"resets_at":1784044800,"as_of":1784031056,"origin":"usage"},
   "seven_day":{...}, "fable":{...}, "auth":{"status":"ok","checked_at":1784031056}}
  ```
  `origin` ∈ `usage|headers|cached`. `auth.status` is only ever `"ok"` or `"expired"` (never `needs re-login`/`auth_needed` — those are free-text `cause`s or Codex-only concepts, respectively).
  Two independent OAuth-heal paths sharing `oauth-attempts.json`: **warm** (drives the real `claude` CLI's own OAuth rotation, zero-cost, comment at `bin/claudeb:632-635` — a token-endpoint 429/failed record must never gate it) and **direct refresh** (claudeb's own curl POST to the token endpoint, `oauth_refresh()`). `.claudeb-state` = current account name (single line); `disabled` = one disabled-account name per line, absent file = all enabled.
- `bin/claudebd` — rotating reverse proxy on `127.0.0.1:45789` (launchd label `com.claudeb.daemon`, plist `~/Library/LaunchAgents/com.claudeb.daemon.plist`). Routes by scope (`general` vs `fable`, split on the request body's `model` starting with `claude-fable`, `requestScope()` `bin/claudebd:631`), applies per-account/per-scope walls, persists across restarts via `~/.claude-profiles/.claudeb/daemon-state.json` (only future-dated entries are kept). Logs to `~/.claude-profiles/.claudeb/claudebd.log` (self-truncates at 1MB on startup).
- `bin/codexb` + `codex-quota.py` — same idea for Codex CLI, no proxy: per-account `CODEX_HOME` under `~/.codex-profiles/<name>`; quota via zero-spend app-server RPC (`account/rateLimits/read`), cached in `~/.llm-limits-codex.json`. `codexb status` prints one line per account (`main: Logged in ... | 5H ... | WEEKLY ...`); an account needing login shows `auth_needed`/`Not logged in` with no usage buckets.
- `bin/llm-limitsd` — **SHADOW MODE** (step 2 of the sqlite control-plane migration; runs alongside
  the legacy path and touches none of it). Small Python 3 stdlib daemon (`sqlite3` + `http.server`),
  the sole writer of a durable ledger that replaces the flock'd JSON read-modify-write the bash
  writers use today. HTTP API on `LLM_LIMITSD_PORT` (default 45791, 127.0.0.1 only — never the
  claudebd data-plane port 45789): `POST /runs` (enqueue with a target set fixed at enqueue),
  `POST /runs/<id>/steps` (step transitions with evidence), `POST /observations` (typed observation
  ingest), `GET /runs/<id>`, `GET /state` (reducer-derived per-account auth+window state),
  `GET /healthz`. SQLite db at `LLM_LIMITSD_DB` (default `~/.claude-profiles/.claudeb/limitsd.sqlite`,
  WAL, single-process writer); tables `runs`/`steps`/`observations`. After each mutation it atomically
  rewrites a read-only projection at `LLM_LIMITSD_PROJECTION` (default `~/.llm-limits-shadow.json` —
  **NOT** the real `~/.llm-limits.json`) in the real cache's schema. Invariants: a run reaches
  `succeeded` only when every required target has a proven success terminal, else
  `partial/failed/interrupted` (never silently clean); `start-window` success needs a post-action
  reconcile observation (`observed_at >= step.started_at`, fresh `resets_at`) — HTTP 200 alone is not
  success; a timeout is a recorded step outcome; on restart an orphaned `running` step becomes
  `interrupted` (reason_code 87), never a silent kill; account auth is reducer-derived and only
  affirmative evidence (reason_code 2) can expire it — capacity weather (reason_code 75) never does;
  the projection is a pure, byte-stable function of ledger state. A corrupt/foreign db is never
  silently recreated: the daemon exits `78` (EXIT_DB_UNRECOVERABLE) with the reason on stderr, and
  the plist's `ThrottleInterval` (30s) keeps `KeepAlive` from hot-looping on it. Launchd plist FILE
  at `launchd/com.llm-limitsd.plist` exists but is NOT installed — rollout is a later migration step.
  Suite: `bash tests/test_llm_limitsd.sh` (hermetic: temp db, child daemon on an ephemeral port).
- `bin/llm-limitsd-shadow-feed` — read-only bridge that feeds the shadow daemon from the legacy
  collector cache. It only READS `~/.llm-limits.json` (override `LLM_LIMITS_CACHE`) and POSTs typed
  observations to `LLM_LIMITSD_URL` (default `http://127.0.0.1:45791`): a `window` observation per
  present `five_hour`/`weekly`/`fable` bucket, a `rotation` observation (`enabled`+`is_current`), and
  — claude-only, default-deny — an `auth` `expired`/`affirmative` observation ONLY when
  `auth.status=="expired"` (never manufactures an "ok"). Idempotent: it stores the cache's
  `fetched_at` in `~/.claude-profiles/.claudeb/shadow-feed.state` (override `LLM_SHADOW_FEED_STATE`)
  and no-ops with zero HTTP when unchanged; state advances only on a fully-successful run, so any
  failure (unreachable daemon, non-2xx, malformed cache) exits nonzero and retries the whole batch.
  Collector `refresh_error` objects are run metadata, not usage observations, and are ignored by
  the bridge and shadow projection.
  Log at `~/.claude-profiles/.claudeb/shadow-feed.log`. Launchd plist FILE at
  `launchd/com.llm-limitsd-shadow-feed.plist` (WatchPaths on the cache + 900s poll) exists but is
  NOT installed. Suite: `bash tests/test_llm_limitsd_shadow_feed.sh`.
- `hammerspoon/llm-limits.lua` — menubar menu. Reads only `~/.llm-limits.json`; opening the menu renders the existing cache immediately, then `collectOnOpen()` starts a detached, rate-limited `llm-limits.sh` task and re-renders after completion. The collector owns execution timeouts; Lua's registry budgets only remove verifiably-dead task entries and never kill or forget a live task. Lua does not query the daemon status endpoint directly.
- `bin/statusline.sh` — Claude Code statusline. Per-segment sources: model/effort/`⚡`(fast_mode)/`1m` chip from the stdin payload; location from `~/.cache/claude-statusline/workdir-<session_id>` when it points at a live git dir (dangling record → unlinked + fall back to `workspace.current_dir`), rendered `<project> » <active>` whenever the active toplevel differs from the launch repo, `@<short-sha>` in red on detached HEAD; `w:` from `~/.claude/worker-model` shows the NEXT delegation target, account included: `w:codex @<pin>·<eff>` when `codex_profile` is pinned, else `w:codex ~<acct>·<eff>` where `~<acct>` mirrors `codexb pick` locally with one jq over `$LLM_LIMITS_FILE` `vendors.codex.accounts` (same ordering as pick: expired reset counts as 0 pressure, accounts at effective ≥100 excluded, unknown quota sorts after known, name tiebreak, `main` fallback when nothing qualifies; documented divergence from the real `codexb pick` — auth comes from the snapshot's `auth_needed` flag instead of live `codex login status`, and the account list/quotas are the collector's last refresh, not a live RPC, so an account added or re-authed since then is invisible until the next collect; no `vendors.codex.accounts` array at all → `~?`); `w:cb @<pin>·son·hi` when `claudeb_profile` is pinned, else `w:cb ~<pick>·son·hi` with the rotating pick from the first line of the general-scope `.claudeb-state` (workers run sonnet/opus — never the fable state file) and `son·hi` = claudeb-worker's documented model/effort defaults; `w:son` (+optional `sonnet_effort` tier) with missing file = the documented sonnet default and an unknown `worker=` value = `w:?`. Efforts abbreviate low/med/hi/xh/max/ultra; the account part renders magenta with `@` = pinned, `~` = rotating, matching the `cb:` segment. Rate limits always render from a stamped merged cache, never raw headers: `~/.claude/statusline-cache-rl` for `main` sessions, `~/.claude-profiles/.claudeb/limits/<acct>.json` for pinned claudeb accounts — a live `rate_limits` payload is merged strictly-newer (tmp+mv) and the merge result is what renders, so a partial header backfills from cache. A rotating session (`CLAUDE_LIMITS_ACCOUNT="-"`) resolves the serving account each render from `.claudeb-state` (`.claudeb-state-fable` when the model id starts with `claude-fable` and that file is non-empty), shows `cb:~<pick>`, and renders that account's cache read-only — `-` sessions never write. Uniform dimming on every path: `five_hour` past 1800s of `as_of` age (legacy caches without `as_of` use file mtime), `seven_day` past 21600s, plus origin=`cached`, expired auth, past `resets_at`, and llm-limits per-bucket stale flags; the `fb` segment reads `$LLM_LIMITS_FILE` (default `~/.llm-limits.json`) and also dims when that file itself is older than 21600s.

## Where to look, per symptom

| Symptom | Look here |
|---|---|
| Menu entry gray (stale) or red (rotation-blocked), unsure why | `curl -s 127.0.0.1:45789/claudebd/status \| jq '{current,current_fable,scopes,accounts,walls,all_walled_until}'`; then `jq '.vendors.claude.accounts, .vendors.claude.daemon' ~/.llm-limits.json` for per-account `rotation`, `as_of`/`stale`/`origin`, and wall details |
| "All accounts walled" / proxy returning 503 | `curl -s 127.0.0.1:45789/claudebd/status \| jq '{walls,all_walled_until}'`; cross-check `grep "^.*wall account=" ~/.claude-profiles/.claudeb/claudebd.log \| tail -20` for `reason=transient` (capacity) vs `reason=header` (real quota) |
| Auth expired / re-login loops | `jq '.auth' ~/.claude-profiles/.claudeb/limits/*.json`; `cat ~/.claude-profiles/.claudeb/oauth-attempts.json` — `outcome` values: `attempting/success/success-adopted/failed/429/revoked/warming/warm-failed`; only `revoked` (invalid_grant + unrotated refresh token, 6h/21600s backoff) sets `cause=needs re-login` in claudeb's own logs — `auth.status` itself is only ever `"ok"` or `"expired"` |
| Requests dying mid-stream | `grep "stream-abort" ~/.claude-profiles/.claudeb/claudebd.log \| tail -20` — `cause` is one of `upstream-idle` (proxy's own 600000ms/10min idle timeout), `upstream-close`, `upstream-error`, `client-close` (caller's socket closed before the upstream stream completed — this is the CALLING client's own timeout/cancellation, not something claudebd imposes) |
| Work stalls with 529 Overloaded | `grep "upstream-5xx" ~/.claude-profiles/.claudeb/claudebd.log \| tail -20` — 529 means Anthropic capacity overload, not an account limit |
| One account shows zeroed/phantom buckets | Distinguish a genuinely-disabled/auth-needed account (`~/.claude-profiles/.claudeb/disabled`, or Codex's `auth_needed: true` + no usage buckets in `codexb status` / `codex-quota.py`) from a stale-but-real snapshot (has `as_of`, just old) |
| Daemon seems dead / stuck state | `launchctl list \| grep claudeb`; `curl -s 127.0.0.1:45789/claudebd/status`; restart per **How to test** below |
| Wrong account picked / rotation ignoring a preference | `cat ~/.claude-profiles/.claudeb/.claudeb-state` (current), `~/.claude-profiles/.claudeb/disabled` (out of rotation), `jq '.pins' <status>` (explicit pin — `claudeb use <name>` sticks until that account hits a limit) |
| Codex account shows blank buckets | `codexb status` or `python3 codex-quota.py \| jq '.accounts'` — `auth_needed: true` + an `error` field means the account needs `codex login`, distinct from a real zero-usage account |

`GET /claudebd/status` shape (real example, trimmed):
```json
{"pid":64763,"port":45789,"rotation_size":2,"current":"notcom","current_fable":"com",
 "accounts":{"com":{"h5":6,"wk":3,"walled":false,"auth_failed_until":0,"fable_walled_until":0,
   "usable":{"general":true,"fable":false},"blocked":{"general":null,"fable":"wall"}}},
 "scopes":{"general":"notcom","fable":"com"},
 "walls":[{"account":"com","scope":"fable","until":"2026-07-14T11:55:20.000Z","reason":"transient"}],
 "pins":[], "all_walled_until":{"general":null,"fable":null}}
```

## The 429 taxonomy (do not conflate these)

1. **Capacity 429** — `isCapacityRejection()` (`bin/claudebd:464`): status 429, no `anthropic-ratelimit-unified-*` header, no `retry-after`. Treated as transient overload: one same-account quick retry (`CLAUDEBD_CAPACITY_RETRY_ATTEMPTS`, default 1, `CLAUDEBD_CAPACITY_RETRY_MS` default 2000ms), logged as `retry account=<a> scope=<s> status=429 unified=none ...`. If still rejected, `markRejected()` walls that scope via `bareCapacityWallUntil()`, reason=`transient`, **never** a long wall on the first hit: tier 0 defaults to `CLAUDEBD_CAPACITY_WALL_FIRST_MS` (45000ms), escalating one tier (to 300s, then 900s, capped) only when a repeat bare-capacity rejection for that same account+scope lands within 10 minutes (`capacityWallRepeatWindowS`) of the previous wall's expiry; a quiet period past that window resets to tier 0. State (`capacityEscalation[scope] = {tier, until}`) persists in `daemon-state.json` per account and is pruned once stale, same as the walls themselves. This applies identically to the general and fable scopes.
2. **Header 429** — has `anthropic-ratelimit-unified-reset` or `retry-after`. `markRejected()` walls the **request's own scope** (general or fable — never both) until the header-specified time, reason=`header`. This is real quota, not capacity noise.
3. **OAuth token-endpoint 429** — `bin/claudeb`'s `oauth_refresh()` (curl to the Anthropic OAuth token endpoint) hitting 429: backs off only the direct-refresh path (`oauth_backoff_until`); by explicit code comment this must **never** gate the warm/heal path (`oauth_heal_backoff_until` is a separate state/namespace in the same `oauth-attempts.json`).
4. **Warm-probe failure classification** (`bin/claudeb`'s `heal_one()`/`warm_accounts()`) — a failed zero-cost warm probe is classified into a cause (`timeout`, `warm-429`, `usage-probe-failed`, `warm-failed` = capacity-shaped upstream weather, vs. `needs-relogin`/`profile-setup` = auth-shaped), persisted as `warm_cause` in `oauth-attempts.json` (`oauth_warm_cause()`). On a capacity-shaped cause, `heal_one()` does one same-run retry (`CLAUDEB_WARM_RETRY_DELAY`, default 20s) before concluding. If still capacity-shaped and the account's existing access token is not expired/near-expiry (`token_needs_refresh()`, `CLAUDEB_TOKEN_NEAR_EXPIRY_SECONDS` default 300s), the direct token-endpoint refresh is **skipped entirely** — the snapshot is left untouched (ages keep growing honestly) and no `mark_auth expired` is recorded, so the collector's `auth_failures` never sees it. Only an auth-shaped cause, or a capacity-shaped cause with an actually-expired token, falls through to the existing direct-refresh fallback. This is the fix for conflating "probe failed from upstream overload" with "auth is broken."

**Hold instead of instant 503** — when every enabled account is walled/ineligible for a request's scope, `bin/claudebd` no longer answers 503 immediately: `holdForEligibility()` re-scans eligibility every 300ms (no busy-wait, plain `setTimeout`) up to `CLAUDEBD_HOLD_MAX_MS` (default 90000ms), and retries account selection as soon as one clears. A client disconnect during the hold aborts it via the response's `close` event (no leaked timer). Every hold outcome is logged: `hold account-scope=<scope> waited_ms=<n> outcome=served|503|client-close`. If the cap expires still walled, the existing 503 body is returned with `retry_at` set to now. Control paths (`/claudebd/status`, `/claudebd/use`) return before reaching this logic and are never held. Setting `CLAUDEBD_HOLD_MAX_MS=0` disables holding entirely (instant 503, the old behavior).

## How to test

Suites (run from repo root):
- `bash tests/test_llm_limits.sh` — hermetic collector tests: schema, per-vendor normalization, freshness/`stale`, `usable_now`, table/plain/sort formatting.
- `bash tests/test_claudeb.sh` — `bin/claudeb` sourced as a bash library against a fixture `CLAUDEB_DIR` with stubbed `curl`/`security`/`claude`: merge/store/OAuth-attempt logic.
- `bash tests/test_claudebd.sh` — thin wrapper that runs `node tests/claudebd_harness.js` (loads `bin/claudebd` via `vm`, exercises internals directly: wall classification, capacity-wall tier escalation/reset, eligibility, disabled/pin precedence, `all_walled_until`, state persistence, held-request claim staggering — 99 assertions) plus a real-daemon-boot check of fable-scope state seeding.
- `bash tests/test_claudebd_live.sh` — spawns a **real** `bin/claudebd` child on an ephemeral port against `claudebd_mock_upstream.js` (a scriptable Anthropic-API stand-in). Includes the **chaos scenario**: a seeded mixed general/fable fault storm (`ok`/`abort`/`unified429`/`bare429`) checking: bare 429s wall 250–900s escalating with `reason=transient`; unified-429 walls end exactly at the header reset with `reason=header`; a 401 marks only that account's `auth_failed_until` and clears on token rotation; a fable rejection never walls general (and vice versa); every injected fault produces exactly one matching log line; daemon pid is stable throughout; expired walls are pruned from `daemon-state.json` on scan; a clean daemon restart never resurrects an expired wall. Also covers: the first bare-429 wall staying short (`capacity-first-wall`), a repeat bare-429 escalating past the short tier (`capacity-escalation`), `rotation_size` tracking enabled-account count (`rotation-size`), and the hold-instead-of-503 behavior both served-after-recovery and aborted-on-client-disconnect (`hold-a`/`hold-b`).
- `bash tests/e2e_surfaces.sh` — drives the **REAL** running Hammerspoon menubar (via `hs -c`), the real `llm-limits` CLI, and `claudeb status` against the real `~/.llm-limits.json`. Golden rule: every `hs -c` snippet only reads `package.loaded["llm-limits"]` and calls `menuItems()` — never assigns to a module field, or it silently breaks the user's live menubar.
- `bash tests/test_codexb.sh` — `bin/codexb` against a fixture `$HOME/.codex` tree and a fake `codex` binary.
- `bash tests/test_llm_selfcheck.sh` — `bin/llm-selfcheck` (the daily safety-net job) against a fixture `$HOME`/repo with stubbed suites, `hs`/`osascript`/`launchctl`.

Golden rules:
- Verify the user-visible surface (menu render, `--table` output), not just internal state.
- Never mutate the live Hammerspoon singleton (see e2e_surfaces.sh rule above).
- Never point a test at the real daemon on port 45789 or the real `~/.claude-profiles/.claudeb` — use `CLAUDEB_DIR`, `CLAUDEBD_PORT` (test harness rejects the literal `45789`), and `CLAUDEBD_UPSTREAM` to redirect to fixtures/mocks.
- Restart the real daemon: `launchctl kickstart -k gui/$UID/com.claudeb.daemon` (non-sandboxed shell — `claudeb`'s own restart path does a SIGTERM/`daemon_stop` then a plain `kickstart` without `-k`; `-k` is the safe manual equivalent when you can't run `claudeb` itself).
- Reload the menu after a Lua change: `hs.reload()` (via `hs -c 'hs.reload()'`), then rerun `tests/e2e_surfaces.sh`.

## Reading `~/.llm-limits.json` as an LLM

Treat `stale`, `expired`, `as_of`, and `effective_pct` as the data-honesty contract. Never infer current availability from raw `used_pct` alone: keep it as provenance, check the bucket's `resets_at` against the current time, and refresh before acting on an old or rolled-over frame.

## Display contract (hammerspoon/llm-limits.lua)

- **Gray** = stale bucket (`.stale == true`), or the collector's own `.expired == true`, or the renderer's own render-time check that `resets_at` has already passed (>60s clock-skew tolerance) — this last case covers a window whose reset landed between collects, before the stored `expired` flag catches up. Missing or false `.stale`/`.expired` alone is not gray; a future `resets_at` is never gray.
- **Reset time** = the collector converts raw zero, empty, absent, and 1970-era reset placeholders to `resets_at: null`; Lua renders null/absent as `–`. Any real reset timestamp, including one the renderer now treats as past-due, remains visible as its actual clock time.
- **Refresh failure** = vendor `refresh_error` is `{cause:string,at:epoch}` from the collector. It renders as a dim `refresh failed <cause> · <age>` line inside that vendor section and persists across passive menu-open collects until that vendor refresh succeeds. Partial failures keep valid old buckets, do not raise alerts, and do not fail the collector process. Top-level `refresh_error` has the same shape and renders as a red top row; it is reserved for no available vendor data or a full refresh with zero successful vendors. The menu also renders an observed nonzero collector exit as a red runtime error when no cache-level global error exists; any later successful task, including a passive collect, clears that runtime residue after reading a valid cache without a top-level error.
- **Red** = rotation-blocked, independent of the checkbox. The daemon is the single source through each account's `rotation.blocked`: `auth`, `wall`, `limit-5h`, or `limit-weekly` blocks the account title plus 5h/weekly rows; the scope-aware `fb` row uses `blocked.fable`, which may additionally be `limit-fable`. A fable-only blockage does not color the account title or general rows. Dim-red when both blocked and stale. If the daemon is unreachable, the collector omits `rotation` and the renderer does not infer blockage.
- **Fable early warning** = when a non-blocked `fb` bucket is at least 80%, only its usage-bar substring is red. The rest of the row retains its normal or stale color, distinguishing warning from rotation blockage.
- **Table model and markers** = every row has first-class `5H%`/`WK%`/`FB%` and matching reset columns, plus `AGE`, `ROT`, `CR`, and `STATUS`; there is no `NOTE`. Rows without Fable render `-`. A `~` suffix marks a stale bucket and `!` marks an expired bucket; both may appear, and displayed percentages remain raw `used_pct` values. `AGE` comes from that row's account/vendor `as_of` (`2m`, `1h48m`, and similar).
- **Table rotation and credits** = `ROT` is `off` when disabled, otherwise `rotation.blocked.general` when present, otherwise `fb:<rotation.blocked.fable>` for a Fable-only block, otherwise `-`. Missing `rotation` also renders `-`; the renderer never invents daemon state. `CR` renders a numeric Codex `reset_credits` as `↻N`, including `↻0`.
- **Table status** = `STATUS` is `login needed` for a Codex account with `auth_needed == true` or a Claude account with a present non-`ok` `auth.status`; unavailable vendor rows show their collector-owned status text; all other rows render `-`.
- **Plain model** = each line mirrors the table's labeled 5h/weekly/Fable values and resets, age, rotation, credits, and status. The same `~`/`!` markers apply, expired values are never rewritten to zero, and an unavailable vendor's `last_wall` is appended when present.
- **●** marks the current account from the account block's collector-owned `is_current` flag.
- **In-flight indicator** = passive menu-open collects never render an indicator. Verified-live explicit, hard, and start-window tasks share one registry and prefix the normal menubar title with `⟳ ` immediately; standing vendor or global errors prefix it with `⚠ ` when no explicit task is active. Resume-timer text remains visible. Ordinary entries use a 360s cleanup budget and start-window entries 1200s, but an over-budget task that still reports running remains registered and suppresses duplicates; only a verifiably-dead entry is removed.
- **Checkbox ("In rotation")** only appears for real `claudeb-store` accounts (`enabled` = not explicitly disabled) — toggling it calls claudeb enable/disable.
- An **explicit/pinned profile entry** is not part of `claudeb-store` and so never gets a checkbox: it's always shown direct, independent of rotation membership.

## Claude Code statusline hooks

`statusline-workdir-hook.sh` (PostToolUse matcher `Bash|Edit|Write|NotebookEdit|EnterWorktree|ExitWorktree`)
records the git toplevel a session actually works in; the status line shows it with a magenta `»`
marker when it differs from the launch repo. Rules:
- Events carrying `agent_id`/`agent_type` are ignored — subagent tool calls report the PARENT
  `session_id` and must never retarget the parent's display.
- Bash: the LAST `cd`/`git -C` in the command wins (`;`, `&`, `|`, `&&`, `||`, and
  newline-separated all match). `git -C <dir>` counts only when followed by a mutating
  subcommand (worktree/checkout/switch/commit/merge/rebase/cherry-pick/revert/restore/stash/
  am/reset/pull); read-only `git -C ... status/log/diff` never retargets.
- EnterWorktree records the toplevel of the `worktree at <absolute path>` in `.tool_response`
  (string or object); ExitWorktree deletes the session's state file. tmp/system/`~/.claude*`/
  node_modules paths are excluded; records older than 7 days are pruned.
- Also registered for SessionStart: `source` `startup`/`resume`/`clear` deletes the session's
  workdir state file (a fresh shell starts in the project dir, so surviving state would lie
  until the first cd); `compact` keeps it — the shell and its cwd survive `/compact`. This
  runs before the agent filter on purpose: `agent_type` on SessionStart means a top-level
  `claude --agent` session, not a subagent.
The statusline itself unlinks a state file that no longer points at a git dir.

State files are stored at:
- `~/.cache/claude-statusline/workdir-<session_id>`
- `~/.cache/claude-worker-tags/<agent_id>`

`worker-tag-hook.sh` records the relay worker's `Worker account:` no-op and prefixes the tag
onto later Bash activity descriptions for `codex-worker` and `claudeb-worker` agents. It exits
silently for any `hook_event_name` other than PreToolUse (its rewrite payload hardcodes
`hookEventName: "PreToolUse"`, so a mis-registration must be a no-op).

`limits-triage-nudge.sh` (PostToolUse matcher `Bash`) scans Bash tool output for a limit-shaped
pattern (`no available accounts`, `API Error: 503/529`, `usage limit`, `overloaded`,
`anthropic-ratelimit`, `CLAUDEB_USAGE_LIMIT`, `claudeb ... timed out`) alongside a
claude/claudeb/anthropic/fable context word in the same output, and nudges the session to run
`llm-limits --table --no-write` and the daemon status check instead of theorizing. Dedup: one
nudge per session per 15 minutes, state in `/tmp/claude-limits-triage-nudge-<session_id>`.

To disable any of these hooks, remove its entry from `hooks.PostToolUse` or `hooks.PreToolUse` in
`~/.claude/settings.json`.

Debug workdir tracking (a mutating `git -C` subcommand or a `cd` is required to record):
`jq -cn --arg dir "$PWD" '{hook_event_name:"PostToolUse",tool_name:"Bash",session_id:"debug",cwd:$dir,tool_input:{command:("cd " + ($dir | @sh))}}' | ~/.claude/hooks/statusline-workdir-hook.sh; cat ~/.cache/claude-statusline/workdir-debug`

Debug worker tag capture:
`echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"codex-worker","agent_id":"debug","tool_input":{"command":"true","description":"Worker account: main · high"}}' | ~/.claude/hooks/worker-tag-hook.sh; cat ~/.cache/claude-worker-tags/debug`
