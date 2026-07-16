# Diagnostics: llm-legs multi-account/limits ecosystem

For LLM sessions asked to fix limits, the menu, or claudeb. Read this before touching code.
Facts below are grounded in the code as of 2026-07-16 (line numbers may drift — re-grep, don't trust blindly).

## System map

- `llm-limits.sh` — read-only collector, writes `~/.llm-limits.json` (schema `{schema, fetched_at, vendors}`). `--refresh` polls free usage endpoints; `--start-windows` is the only paid path (never call from scripts). `--table`/`--plain`/`--json` control rendering; piped output defaults to JSON.
- `bin/claudeb` — account prober/launcher. Snapshots per account in `~/.claude-profiles/.claudeb/limits/<name>.json`:
  ```json
  {"five_hour":{"used_percentage":6,"resets_at":1784044800,"as_of":1784031056,"origin":"usage"},
   "seven_day":{...}, "fable":{...}, "auth":{"status":"ok","checked_at":1784031056}}
  ```
  `origin` ∈ `usage|headers|cached`. `auth.status` is only ever `"ok"` or `"expired"` (never `needs re-login`/`auth_needed` — those are free-text `cause`s or Codex-only concepts, respectively).
  Two independent OAuth-heal paths sharing `oauth-attempts.json`: **warm** (drives the real `claude` CLI's own OAuth rotation, zero-cost, comment at `bin/claudeb:632-635` — a token-endpoint 429/failed record must never gate it) and **direct refresh** (claudeb's own curl POST to the token endpoint, `oauth_refresh()`). `.claudeb-state` = current account name (single line); `disabled` = one disabled-account name per line, absent file = all enabled.
- `bin/claudebd` — rotating reverse proxy on `127.0.0.1:45789` (launchd label `com.claudeb.daemon`, plist `~/Library/LaunchAgents/com.claudeb.daemon.plist`). Routes by scope (`general` vs `fable`, split on the request body's `model` starting with `claude-fable`, `requestScope()` `bin/claudebd:631`), applies per-account/per-scope walls, persists across restarts via `~/.claude-profiles/.claudeb/daemon-state.json` (only future-dated entries are kept). Logs to `~/.claude-profiles/.claudeb/claudebd.log` (self-truncates at 1MB on startup).
- `bin/codexb` + `codex-quota.py` — same idea for Codex CLI, no proxy: per-account `CODEX_HOME` under `~/.codex-profiles/<name>`; quota via zero-spend app-server RPC (`account/rateLimits/read`), cached in `~/.llm-limits-codex.json`. `codexb status` prints one line per account (`main: Logged in ... | 5H ... | WEEKLY ...`); an account needing login shows `auth_needed`/`Not logged in` with no usage buckets.
- `hammerspoon/llm-limits.lua` — menubar menu. Reads only `~/.llm-limits.json`; opening the menu renders the existing cache immediately, then `collectOnOpen()` starts a detached, rate-limited `llm-limits.sh` task and re-renders after completion. The collector owns all action budgets; Lua neither adds a timeout nor queries the daemon status endpoint directly.
- `bin/statusline.sh` — Claude Code statusline; renders the `cb:` segment (`cb:~<name>` = rotating proxy session, current daemon pick from `.claudeb-state`; `cb:<name>` = pinned/profile account; nothing for plain `main` sessions) and writes `~/.claude-profiles/.claudeb/limits/<acct>.json` whenever a live `rate_limits` payload arrives for a real (non-`main`, non-rotating) account, merging only strictly-newer buckets.

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
{"pid":64763,"port":45789,"current":"notcom","current_fable":"com",
 "accounts":{"com":{"h5":6,"wk":3,"walled":false,"auth_failed_until":0,"fable_walled_until":0,
   "usable":{"general":true,"fable":false},"blocked":{"general":null,"fable":"wall"}}},
 "scopes":{"general":"notcom","fable":"com"},
 "walls":[{"account":"com","scope":"fable","until":"2026-07-14T11:55:20.000Z","reason":"transient"}],
 "pins":[], "all_walled_until":{"general":null,"fable":null}}
```

## The 429 taxonomy (do not conflate these)

1. **Capacity 429** — `isCapacityRejection()` (`bin/claudebd:464`): status 429, no `anthropic-ratelimit-unified-*` header, no `retry-after`. Treated as transient overload: one same-account quick retry (`CLAUDEBD_CAPACITY_RETRY_ATTEMPTS`, default 1, `CLAUDEBD_CAPACITY_RETRY_MS` default 2000ms), logged as `retry account=<a> scope=<s> status=429 unified=none ...`. If still rejected, `markRejected()` walls that scope for a **short, transient** window only — 300s (general) or 300s/900s escalating (fable, if within 1h of the last bare reject) — reason=`transient`. **Never** a long wall.
2. **Header 429** — has `anthropic-ratelimit-unified-reset` or `retry-after`. `markRejected()` walls the **request's own scope** (general or fable — never both) until the header-specified time, reason=`header`. This is real quota, not capacity noise.
3. **OAuth token-endpoint 429** — `bin/claudeb`'s `oauth_refresh()` (curl to the Anthropic OAuth token endpoint) hitting 429: backs off only the direct-refresh path (`oauth_backoff_until`); by explicit code comment this must **never** gate the warm/heal path (`oauth_heal_backoff_until` is a separate state/namespace in the same `oauth-attempts.json`).

## How to test

Suites (run from repo root):
- `bash tests/test_llm_limits.sh` — hermetic collector tests: schema, per-vendor normalization, freshness/`stale`, `usable_now`, table/plain/sort formatting.
- `bash tests/test_claudeb.sh` — `bin/claudeb` sourced as a bash library against a fixture `CLAUDEB_DIR` with stubbed `curl`/`security`/`claude`: merge/store/OAuth-attempt logic.
- `bash tests/test_claudebd.sh` — thin wrapper that runs `node tests/claudebd_harness.js` (loads `bin/claudebd` via `vm`, exercises internals directly: wall classification, eligibility, disabled/pin precedence, `all_walled_until`, state persistence — 63 assertions).
- `bash tests/test_claudebd_live.sh` — spawns a **real** `bin/claudebd` child on an ephemeral port against `claudebd_mock_upstream.js` (a scriptable Anthropic-API stand-in). Includes the **chaos scenario**: a seeded mixed general/fable fault storm (`ok`/`abort`/`unified429`/`bare429`) checking: bare 429s wall 250–900s escalating with `reason=transient`; unified-429 walls end exactly at the header reset with `reason=header`; a 401 marks only that account's `auth_failed_until` and clears on token rotation; a fable rejection never walls general (and vice versa); every injected fault produces exactly one matching log line; daemon pid is stable throughout; expired walls are pruned from `daemon-state.json` on scan; a clean daemon restart never resurrects an expired wall.
- `bash tests/e2e_surfaces.sh` — drives the **REAL** running Hammerspoon menubar (via `hs -c`), the real `llm-limits` CLI, and `claudeb status` against the real `~/.llm-limits.json`. Golden rule: every `hs -c` snippet only reads `package.loaded["llm-limits"]` and calls `menuItems()` — never assigns to a module field, or it silently breaks the user's live menubar.
- `bash tests/test_codexb.sh` — `bin/codexb` against a fixture `$HOME/.codex` tree and a fake `codex` binary.

Golden rules:
- Verify the user-visible surface (menu render, `--table` output), not just internal state.
- Never mutate the live Hammerspoon singleton (see e2e_surfaces.sh rule above).
- Never point a test at the real daemon on port 45789 or the real `~/.claude-profiles/.claudeb` — use `CLAUDEB_DIR`, `CLAUDEBD_PORT` (test harness rejects the literal `45789`), and `CLAUDEBD_UPSTREAM` to redirect to fixtures/mocks.
- Restart the real daemon: `launchctl kickstart -k gui/$UID/com.claudeb.daemon` (non-sandboxed shell — `claudeb`'s own restart path does a SIGTERM/`daemon_stop` then a plain `kickstart` without `-k`; `-k` is the safe manual equivalent when you can't run `claudeb` itself).
- Reload the menu after a Lua change: `hs.reload()` (via `hs -c 'hs.reload()'`), then rerun `tests/e2e_surfaces.sh`.

## Reading `~/.llm-limits.json` as an LLM

Treat `stale`, `expired`, `as_of`, and `effective_pct` as the data-honesty contract. Never infer current availability from raw `used_pct` alone: keep it as provenance, check the bucket's `resets_at` against the current time, and refresh before acting on an old or rolled-over frame.

## Display contract (hammerspoon/llm-limits.lua)

- **Gray** = stale bucket only (`.stale == true`) — says nothing about availability. Missing or false `.stale` is not gray; every normalized bucket must carry the collector-owned flag.
- **Reset time** = the collector converts raw zero, empty, absent, and 1970-era reset placeholders to `resets_at: null`; Lua renders null/absent as `–`. Any real reset timestamp, including an expired window awaiting refreshed data, remains visible and `expired` independently controls dimming.
- **Refresh failure** = vendor `refresh_error` comes from the collector. If the process cannot update the cache, Lua reports only the observed `exit N`, never a guessed cause.
- **Red** = rotation-blocked, independent of the checkbox. The daemon is the single source through each account's `rotation.blocked`: `auth`, `wall`, `limit-5h`, or `limit-weekly` blocks the account title plus 5h/weekly rows; the scope-aware `fb` row uses `blocked.fable`, which may additionally be `limit-fable`. A fable-only blockage does not color the account title or general rows. Dim-red when both blocked and stale. If the daemon is unreachable, the collector omits `rotation` and the renderer does not infer blockage.
- **Fable early warning** = when a non-blocked `fb` bucket is at least 80%, only its usage-bar substring is red. The rest of the row retains its normal or stale color, distinguishing warning from rotation blockage.
- **Table age and markers** = every available row has an `AGE` column derived from that row's account/vendor `as_of` (`2m`, `1h48m`, and similar). `NOTE` names each stale or expired bucket explicitly; displayed percentages remain raw `used_pct` values.
- **Plain age and markers** = every available row has an `| age ...` field followed by explicit bucket markers when applicable. Expired values are never rewritten to zero.
- **●** marks the current account from the account block's collector-owned `is_current` flag.
- **Checkbox ("In rotation")** only appears for real `claudeb-store` accounts (`enabled` = not explicitly disabled) — toggling it calls claudeb enable/disable.
- An **explicit/pinned profile entry** is not part of `claudeb-store` and so never gets a checkbox: it's always shown direct, independent of rotation membership.
