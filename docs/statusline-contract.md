# Statusline freshness contract

The iron rule: **every** statusline element declares (a) its source of truth,
(b) what triggers an update, (c) its staleness/dim policy, and (d) when it is
removed. "Render once and forget" is forbidden — a segment must always reflect
current reality or dim/disappear.

Any change to the statusline (`bin/statusline.sh` or a `statusline-*` hook/probe)
MUST keep this table exhaustive and update `tests/test_statusline_hooks.sh` to
match. The `statusline-freshness-gate.sh` PostToolUse hook reminds you of this
whenever you edit a `statusline*` file.

Render budget: warm p95 ≤150ms. Anything slower than that lives in a background
refresher (a hook, or the fire-and-forget probe pattern), never the render path.

## Line 1 — identity / work

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| model + effort + `⚡`fast | statusline JSON stdin (`.model.display_name`, `.effort.level`, `.fast_mode`) | Every render (harness re-sends JSON, 5s) | Live each render; never dimmed | model always shown; effort suffix only if present; `⚡` only if `fast_mode` |
| `cb:<account>` | `CLAUDE_LIMITS_ACCOUNT` / `CLAUDE_CONFIG_DIR` basename; for a rotating session (`-`) the daemon pick from `.claudeb-state` (`.claudeb-state-fable` for fable models) | Every render (re-reads state file) | `~` prefix marks a rotating pick that can change; not dimmed | Absent when `acct=main` (plain non-claudeb session) |
| `dir » worktree` | JSON `.workspace.project_dir`/`.current_dir` + `workdir-<sid>` state file (written by `statusline-workdir-hook`) + `git rev-parse` | Every render; state file updated by the workdir hook on cd/pushd/edit/EnterWorktree | Dangling state file (top gone) deleted on render, falls back to project dir | `»` only when active worktree top ≠ project top |
| branch `⎇` + `✚`N + `↓`behind `↑`ahead, or `@sha` | `git` in the active dir (`GIT_OPTIONAL_LOCKS=0`) | Every render | Live git each render | No branch → nothing; detached HEAD → `@sha`; counts hidden at 0 |
| lines `+N/-M` | JSON `.cost.total_lines_added`/`removed` | Every render | Live each render | Hidden while `added+removed < 50` |
| live ports `⇢ :PORT` | `ports-<sid>` cache written by `statusline-ports-probe.sh` (fired from render) | Render fires the probe in the background when the cache is >15s stale | Cache mtime >60s → hidden (probe presumed dead) | Cache absent → hidden; cache empty (probed, no servers) → hidden; server death shows within ~15–20s as the next probe writes an empty cache; max 3 ports |
| worker `w:<name>` + prediction/pin/tier | `~/.claude/worker-model`; for `auto` the `worker-pick.line.<acct>` cache (now includes codex model `sol`); for codex model label: `~/.codex/config.toml` line `model = "gpt-X-<label>"` (last dash-segment, fallback "sol"); for codex accounts the local mirror of `~/.llm-limits.json`; for claudeb `.claudeb-state` | Every render; the `auto` prediction cache is refreshed in the background when >90s stale | `auto` line served from a ≤90s cache (background refresh); pin/sel shown only if resolvable; codex model label derives from `~/.codex/config.toml` every render | `w:<name>` always shown; `?` when the worker key is unknown |
| live worker tag `▶<tag>` | newest file in `claude-worker-tags/<sid>/` (written by `worker-tag-hook`) | Render reads the newest tag file | Ignored when its mtime >600s (falls back to the static config prediction) | No fresh tag → segment falls back to the config prediction |
| chat topic (dim, Russian) | `topic-<sid>` cache written by `statusline-topic-hook` generator (headless haiku via claudeb, `--no-session-persistence` so generator runs leave no transcripts in `projects/`) | UserPromptSubmit debounce: first substantive prompt, or ≥5 prompts since last gen, or ≥600s + ≥2 prompts | Always dim — a human hint, not live data; not dim-escalated | File absent/empty → no segment; deleted on `SessionStart` `source=clear`; pruned after 7 days; truncated to 44 chars with `…` |

## Line 2 — usage

The `1800`s / `21600`s staleness thresholds below are cross-implementation invariants; their canonical values and every other site live in `docs/shared-invariants.md` (guarded by `tests/test_consistency.sh`).

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| `ctx <pct>` + `<n>k→HH:MM` tokens | `%` computed as `.current_usage` sum / `.context_window_size` when both are present — the harness's `.used_percentage` is denominator-blind on >200k windows (a 1m session at 248k reports 100%); falls back to `.used_percentage` when either field is absent; `<n>k` from `.current_usage`; token color + death time from `.current_usage.cache_creation_input_tokens`+`cache_read_input_tokens`, the `transcript_path` mtime, and the **effective cache TTL** (below) | Every render | Live each render. The `%` carries color: green <40, yellow 40–79, red ≥80. The `<n>k` token count's color now warns about resume cost: **warm cache** (cached creation+read > 0 AND within TTL) shows count and `→HH:MM` **both dim** — time presence signals cache is alive; **cold cache** (not warm) — count **dim** when <90k (cheap), **yellow** when 90–299k (costs real money), **red** when ≥300k (expensive). Warm = transcript mtime within effective TTL. When warm, `→HH:MM` (Europe/Kyiv) marks cache death = mtime + TTL. Any failure degrades to a plain dim count with no time. | token count hidden when 0; `→HH:MM` dropped when not warm |
| `5h <pct>` + reset time | merged rate-limit cache (`statusline-cache-rl` for main, `limits/<acct>.json` for claudeb) — live headers merged under lock each render | Every render merges newer headers; the claudeb daemon writes the caches | Dimmed if reset passed, `auth=expired`, `origin=cached`, `as_of` >1800s, or the `llm-limits.json` `stale` flag is set | Never removed; `?` when unknown |
| `wk <pct>` + reset | same cache (`seven_day`) | Every render | Dimmed if reset passed, expired/cached, `as_of` >21600s, or `stale` flag | Never removed; `?` when unknown |
| `fb <pct>` + reset | `~/.llm-limits.json` `vendors.claude.accounts[].fable` | Every render reads the file; the store is written by the `llm-limits` collector (menu collect-on-open, llm-limitsd) and kept fresh by the statusline **store merge-kick** below | Dimmed if the account's `stale` flag is set or the file mtime >21600s | Only for a non-`main` account that has a `fable` bucket; else absent |
| `$<cost>` | JSON `.cost.total_cost_usd` | Every render | Live each render (`LC_ALL=C` for the decimal point) | Absent when cost is null |

## Store merge-kick (background, not a rendered segment)

`bin/statusline.sh` already merges live `rate_limits` headers into the per-account
caches every render, but it never used to touch the central store
`~/.llm-limits.json` — that only updated on a menu open, so the menubar and other
sessions' store-derived data (`fb`, the `stale` flags) lagged until someone
opened the menu. After a render that captured fresh headers (the write branch),
the statusline now nudges the store so fresh data propagates passively.

| Property | Value |
|---|---|
| Source of truth | the per-account rate-limit caches the render just wrote |
| Update trigger | fires only on a render that captured fresh headers; runs the same zero-network collector the menu's collect-on-open uses (bare `llm-limits.sh`, **never** `--refresh`) |
| Debounce | ≤ once / 60s across **all** sessions via the shared stamp `~/.cache/claude-statusline/store-merge-kick` |
| Single-flight | the `store-merge-kick.lock` mkdir lock (stale-reclaimed at 120s) via the same `snapshot_lock_acquire` helper the cache write uses; the stamp is written in the foreground under the lock so a near-simultaneous second render sees the debounce and skips |
| Non-blocking | the collector runs in a detached background subshell with its own fds; render latency is never affected |
| Failure policy | fully silent — a failed nudge never breaks or slows the render |
| Consumer | the Hammerspoon menubar reacts to the store write via an `hs.pathwatcher` (2s throttle) that re-renders the title without a menu open; overridable/neutralizable in tests via `STATUSLINE_STORE_MERGE_CMD` |

## Effective cache TTL (background state feeding the token-count color)

The prompt-cache warmth color and the `→HH:MM` death time both need the cache
TTL, but **the statusline stdin exposes no TTL or expiry field** — verified
against a captured live payload: `.context_window.current_usage` carries only
`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens` (no `service_tier`, no `ephemeral_*` breakdown, no
expiry). The `ephemeral_1h/5m_input_tokens` split exists only inside the
transcript's `message.usage`, not in the payload, so the TTL is resolved as a
seed corrected by observed bounds — never a hardcoded truth.

| Property | Value |
|---|---|
| Resolution order | `effective = clamp(seed, floor, ceiling)` |
| Seed | `~/.claude/statusline-cache-ttl` (integer seconds) if present and positive, else `3600` (Anthropic's 1h prompt-cache TTL; drops to 300 under overage). Documented as a **seed evidence overrides**, not truth |
| Floor / ceiling source | learned from each **new request** (`prompt_id` change): a large `cache_read` after an inactivity gap G proves the cache survived G → `floor = max(floor, G)`; a full rebuild (near-zero `cache_read`, `cache_creation ≥ 20k`) after gap G proves it died within G → `ceiling = min(ceiling, G)`. Gap G = delta between successive requests' transcript-write times |
| Persistence | `~/.cache/claude-statusline/cache-ttl-learned` = `{observed_floor_s, observed_ceiling_s, updated_at}`, written atomically (tmp+`mv`), global across sessions; per-session `cache-ttl-track-<sid>` holds the previous request's `prompt_id`+write-time for gap measurement |
| Staleness / decay | bounds with `updated_at` older than 7 days are reset (`floor=0`, `ceiling=∞`) on the next render — Anthropic can change the real TTL |
| Cost | reads use the `read` builtin (no `jq`/subprocess); writes fire only when a bound changes; one `date -r` for the death time (same class as the reset-time formatting) |
| Failure policy | any parse/stat/write failure is silent; the color falls back to the seed TTL, then to plain dim |

## Known limitations

- **Ports probe misses disowned servers.** The probe walks the claude session's
  process tree; a server double-forked out of that tree (`setsid`, `disown` into
  a new session, a systemd/launchd unit) is invisible and never shown.
- **Ports filter is command-pattern based.** Infra noise is dropped by matching
  `mcp|figma|codex|chrome-devtools|chrome_crashpad` and the `claude` binary in
  the listener's command line. A user dev server whose command contains one of
  those tokens would be filtered out.
- **Topic label lag.** The topic reflects the theme as of the last generation,
  not the current prompt; it updates on the debounce triggers above.
