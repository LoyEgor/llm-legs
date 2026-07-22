# Statusline freshness contract

The iron rule: **every** statusline element declares (a) its source of truth,
(b) what triggers an update, (c) its staleness/dim policy, and (d) when it is
removed. "Render once and forget" is forbidden — a segment must always reflect
current reality or dim/disappear.

Any change to the statusline (`bin/statusline.sh` or a `statusline-*` hook/probe)
MUST keep this table exhaustive and update `tests/test_statusline_hooks.sh` to
match. The `statusline-freshness-gate.sh` PostToolUse hook reminds you of this
whenever you edit a `statusline*` file.

## Before adding ANY new segment (mandatory checklist)

1. **Enumerate every event that can change the value.** Walk the full list, not
   just the happy path: user slash-commands (`/rename`, `/branch`, `/clear`,
   `/compact`, `/model`, `/resume`), account/profile switches, `cd`/worktree
   moves, OTHER sessions/agents/humans mutating the same repo or shared state,
   background daemons, and plain passage of time.
2. **For each event, name the mechanism** by which the segment learns about it:
   per-render recompute from the source of truth (preferred), a hook that
   writes per-session state, a background probe with a declared cache TTL.
   "The cache will probably still be right" is not a mechanism.
3. **If even one event cannot be detected**, the segment must visibly dim/hide
   in that situation — or must not ship at all. Segments that froze in practice
   get REMOVED, not patched around (see Removed segments below).
4. **Prove each mechanism with a test** in `tests/test_statusline_hooks.sh` and
   add the row to the table here in the same change.

Render budget: warm p95 ≤150ms. Anything slower than that lives in a background
refresher (a hook, or the fire-and-forget probe pattern), never the render path.

## Line 1 — identity / work

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| model + effort + `⚡`fast | statusline JSON stdin (`.model.display_name`, `.effort.level`, `.fast_mode`) | Every render (harness re-sends JSON, 5s) | Live each render; never dimmed | model always shown; effort suffix only if present; `⚡` only if `fast_mode` |
| `cb:<account>` | `CLAUDE_LIMITS_ACCOUNT` / `CLAUDE_CONFIG_DIR` basename; for a rotating session (`-`) the daemon pick from `.claudeb-state` (`.claudeb-state-fable` for fable models) | Every render (re-reads state file) | `~` prefix marks a rotating pick that can change; not dimmed | Absent when `acct=main` (plain non-claudeb session) |
| `dir » worktree` | JSON `.workspace.project_dir`/`.current_dir` + `workdir-<sid>` state file (written by `statusline-workdir-hook`) + `git rev-parse` | Every render; state file updated by the workdir hook on cd/pushd/edit/EnterWorktree | Dangling state file (top gone) deleted on render, falls back to project dir | `»` only when active worktree top ≠ project top |
| branch `⎇` + uncommitted `+A/-D` + dim `+N~M-Kf` files + `↓`behind `↑`ahead, or `@sha` | `git` in the active dir (`GIT_OPTIONAL_LOCKS=0`). `+A/-D` = the WHOLE uncommitted volume in the active repo right now, whoever wrote it: `git diff --numstat --summary HEAD` (staged+unstaged; unborn HEAD diffs the worktree against the repo's empty tree instead — no double count of staged intermediates) plus untracked text-file lines (`ls-files --others --exclude-standard` → `grep -cI`, binaries count 0 lines). Dim file split from the same pass: `+` created (`--summary` create + untracked, binaries included), `~` modified (remaining numstat entries — renames and mode changes land here), `-` deleted (`--summary` delete); zero components hidden. NOT the harness's `.cost.total_lines_*` — that was a session-lifetime tool-edit counter across all repos and never matched the actual diff | Every render recomputes from live git — branch switches, commits, edits, or cleanups by ANY session/agent/human show on the next render; the active repo follows the workdir hook (cd/EnterWorktree) | Live git each render; no cache to go stale | No branch → nothing; detached HEAD → `@sha` (diff still shown); `+A/-D` hidden when 0/0 — dirty with zero countable lines (binary/mode/rename-only) shows the dim file counts alone; file suffix hidden when no files; arrows hidden at 0 |
| live ports `⇢ :PORT` | `ports-<sid>` cache written by `statusline-ports-probe.sh` (fired from render) | Render fires the probe in the background when the cache is >15s stale | Cache mtime >60s → hidden (probe presumed dead) | Cache absent → hidden; cache empty (probed, no servers) → hidden; server death shows within ~15–20s as the next probe writes an empty cache; max 3 ports |
| worker `w:<name>` + prediction/pin/tier | `~/.claude/worker-model`; for `auto` the `worker-pick.line.<acct>` cache (now includes codex model `sol`); for codex model label: `~/.codex/config.toml` line `model = "gpt-X-<label>"` (last dash-segment, fallback "sol"); for codex accounts the local mirror of `~/.llm-limits.json`; for claudeb `.claudeb-state` | Every render; the `auto` prediction cache is refreshed in the background when >90s stale | `auto` line served from a ≤90s cache (background refresh); pin/sel shown only if resolvable; codex model label derives from `~/.codex/config.toml` every render | `w:<name>` always shown; `?` when the worker key is unknown |
| live worker tag `▶<tag>` | newest file in `claude-worker-tags/<sid>/` (written by `worker-tag-hook`) | Render reads the newest tag file | Ignored when its mtime >600s (falls back to the static config prediction) | No fresh tag → segment falls back to the config prediction |
| live bench `⚖ <label>` | `claude-review-bench/<sid>/running` marker written by `review-bench-hook` (PreToolUse); marker line is `<label> <epoch>` and the render strips the trailing epoch | Render reads the session's marker each render; removal is event-driven (PostToolUse hook deletes the marker when the bench command ends, success or failure) | Marker mtime >2700s (45 min) → hidden (hook presumed missed/crashed) | Marker absent → nothing; no process probe by design — a global `pgrep` would light up for another session's bench run; label format: "bench <commitish>: <raters>" or "bench <commitish>: auto <N>" |

## Line 2 — usage

The `1800`s / `21600`s staleness thresholds below are cross-implementation invariants; their canonical values and every other site live in `docs/shared-invariants.md` (guarded by `tests/test_consistency.sh`).

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| `ctx <pct>` + `<n>k→HH:MM` tokens | `%` computed as `.current_usage` sum / `.context_window_size` when both are present — the harness's `.used_percentage` is denominator-blind on >200k windows (a 1m session at 248k reports 100%); falls back to `.used_percentage` when either field is absent; `<n>k` from `.current_usage`; token color + death time from the **transcript tail** (one jq pass, below) plus the account stamp in `cache-ttl-track-<sid>` | Every render | Live each render. The `%` carries color: green <40, yellow 40–79, red ≥80. The `<n>k` token count's color warns about resume cost: **warm cache** shows count and `→HH:MM` **both dim** — time presence signals cache is alive; **cold cache** — count **dim** when <90k (cheap), **yellow** when 90–299k (costs real money), **red** when ≥300k (expensive). Warm requires ALL of: (1) a completed response — the newest non-sidechain, non-`<synthetic>` **assistant** entry in the 256KB tail (never the file mtime — `--resume` touches the file before any request; never `user` entries — `/compact`'s unmarked continuation user entry would fake warmth; `isCompactSummary` user entries and sidechain entries excluded throughout); (2) payload cache tokens > 0; (3) that response within the effective TTL (below); (4) no `system`/`compact_boundary` entry at/after it — `/compact` rewrites the prefix, killing the cache until the next response; (5) same model — the response entry's `message.model` equals the payload `.model.id` (Anthropic caches are per-model; `/model` back to the cache's model re-warms); (6) a verified same-account stamp: `cache-ttl-track-<sid>` = `v2 <assist_ts> <acct> <learned_upto>`, re-stamped with the current account only when a NEW response lands within the 120s attribution window of a live render (the account cannot change without a session restart); an unattributable response stamps `?` — never warm — which is what makes a menu/rotation account switch (resume under a new profile) reliably cold until the first new response. Legacy v1 track files are treated as absent (cold). **Branched chats** (`forkedFrom.sessionId` on copied entries): a copied anchor response never self-stamps — it inherits the parent's stamp + learning cursor, but only when the parent's track still points at that exact response (tail fork, parent not moved past it — then the fork provably shares the parent's cached prefix); a fork from an earlier message stays `?`/cold, matching reality (only the static system/tools blocks hit; observed live 2026-07-18: cr 20.7k / cc 242.9k three minutes after such a fork). `→HH:MM` (Europe/Kyiv) = response time + TTL. Any parse failure degrades to cold, never to a false warm. | token count hidden when 0; `→HH:MM` dropped when not warm |
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

The statusline stdin exposes no TTL field, but the transcript does: every
response's `message.usage.cache_creation` names its bucket
(`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`) — **the API's own
TTL declaration**. The bucket is parsed generically from the field name
(`ephemeral_<n><m|h>_`), so a new bucket (e.g. `2h`) would be picked up without
a code change; nothing about the TTL is hardcoded truth.

| Property | Value |
|---|---|
| Resolution order | newest nonzero bucket in the tail wins (reads refresh the same bucket); tails with no bucket fall back to `clamp(seed, floor, ceiling)` |
| Seed | `~/.claude/statusline-cache-ttl` (integer seconds) if present and positive, else `3600`. A **seed evidence overrides**, not truth; ignored when a bucket is visible |
| Floor / ceiling source | learned from transcript evidence: the newest turn's first response after idle gap G (extracted by the same jq pass). A large `cache_read` proves the cache survived G → `floor = max(floor, G)`, and a survival past the believed ceiling clears that ceiling (self-healing); a full rebuild (near-zero `cache_read`, `cache_creation ≥ 20k`) after G ≥ 120s proves it died within G → `ceiling = min(ceiling, G)`. **Non-evidence guards**: sub-120s rebuilds (prefix invalidations — edited CLAUDE.md, new reminders), a model switch across the gap, a compact boundary inside the gap, and an account switch across the gap (track stamp ≠ current) never move a bound |
| Persistence | `~/.cache/claude-statusline/cache-ttl-learned` = `{observed_floor_s, observed_ceiling_s, updated_at}`, written atomically (tmp+`mv`), global across sessions; per-session `cache-ttl-track-<sid>` = `v2 <assist_ts> <acct> <learned_upto>` (account stamp + one-shot evidence consumption) |
| Staleness / decay | bounds with `updated_at` older than 7 days are reset (`floor=0`, `ceiling=∞`) on the next render — Anthropic can change the real TTL |
| Cost | one jq pass over the 256KB tail per render (~10ms, measured); learned-bounds reads use the `read` builtin; writes fire only when a bound or stamp changes |
| Failure policy | any parse/stat/write failure is silent and degrades to cold — never to a false warm |

## Known limitations

- **Ports probe misses disowned servers.** The probe walks the claude session's
  process tree; a server double-forked out of that tree (`setsid`, `disown` into
  a new session, a systemd/launchd unit) is invisible and never shown.
- **Ports filter is command-pattern based.** Infra noise is dropped by matching
  `mcp|figma|codex|chrome-devtools|chrome_crashpad` and the `claude` binary in
  the listener's command line. A user dev server whose command contains one of
  those tokens would be filtered out.
- **Uncommitted diff counts text lines only.** Untracked binaries and binary
  edits contribute 0 lines (`grep -cI` / numstat `-`) but still appear in the
  dim file counts; a tree dirty with ONLY such changes shows the file counts
  alone. A huge untracked text file (an unignored log/dataset) inflates `+A`
  honestly — gitignore it.
- **Cache warmth is deliberately cold-biased.** Warmth needs a completed
  response, so the first request of a turn shows cold until its response
  lands, and a turn so tool-heavy that the last assistant entry scrolls out of
  the 256KB tail renders cold until the next response. False-cold transients
  are accepted; false-warm is the failure mode the design forbids.
- **Fork warmth inheritance is exact-match only.** A tail fork whose parent
  later produced more responses shows cold even though the shared prefix
  blocks may still be cached server-side — proving that cheaply is impossible,
  so the cold bias wins.

## Removed segments (do not re-add without solving the freshness failure)

- **Chat title** (removed 2026-07-21). Rendered the transcript's newest
  `aiTitle` entry, but `/rename` and `/branch` do not write a fresh `aiTitle`
  where the tail scan sees it, so the label froze on stale names — an iron-rule
  violation with no reliable update trigger available. The haiku topic
  summarizer before it died the same way (removed 2026-07-21). Any successor
  needs a harness-provided title field in the render JSON, not transcript
  archaeology. Orphaned `title-*`/`topic-*` caches are still pruned by the
  ports probe.
- **Session lines counter `+N/-M`** (removed 2026-07-21). Showed
  `.cost.total_lines_added/removed` — a session-lifetime counter of every tool
  edit across all repos (rewrites double-count; other agents' work invisible).
  It never answered "how much is uncommitted", which is what the branch
  segment's `+A/-D` now measures from live git.
