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
| model + effort + `⚡`fast + `1m` | statusline JSON stdin (`.model.display_name`, `.effort.level`, `.fast_mode`, `.context_window.context_window_size`) | Every render (harness re-sends JSON, 5s) | Live each render; never dimmed | model always shown; effort suffix only if present; `⚡` only if `fast_mode`; `1m` only if window >200000 |
| `cb:<account>` | `CLAUDE_LIMITS_ACCOUNT` / `CLAUDE_CONFIG_DIR` basename; for a rotating session (`-`) the daemon pick from `.claudeb-state` (`.claudeb-state-fable` for fable models) | Every render (re-reads state file) | `~` prefix marks a rotating pick that can change; not dimmed | Absent when `acct=main` (plain non-claudeb session) |
| `dir » worktree` | JSON `.workspace.project_dir`/`.current_dir` + `workdir-<sid>` state file (written by `statusline-workdir-hook`) + `git rev-parse` | Every render; state file updated by the workdir hook on cd/pushd/edit/EnterWorktree | Dangling state file (top gone) deleted on render, falls back to project dir | `»` only when active worktree top ≠ project top |
| branch `⎇` + `✚`N + `↓`behind `↑`ahead, or `@sha` | `git` in the active dir (`GIT_OPTIONAL_LOCKS=0`) | Every render | Live git each render | No branch → nothing; detached HEAD → `@sha`; counts hidden at 0 |
| lines `+N/-M` | JSON `.cost.total_lines_added`/`removed` | Every render | Live each render | Hidden while `added+removed < 50` |
| live ports `⇢ :PORT` | `ports-<sid>` cache written by `statusline-ports-probe.sh` (fired from render) | Render fires the probe in the background when the cache is >15s stale | Cache mtime >60s → hidden (probe presumed dead) | Cache absent → hidden; cache empty (probed, no servers) → hidden; server death shows within ~15–20s as the next probe writes an empty cache; max 3 ports |
| worker `w:<name>` + prediction/pin/tier | `~/.claude/worker-model`; for `auto` the `worker-pick.line.<acct>` cache; for codex the local mirror of `~/.llm-limits.json`; for claudeb `.claudeb-state` | Every render; the `auto` prediction cache is refreshed in the background when >90s stale | `auto` line served from a ≤90s cache (background refresh); pin/sel shown only if resolvable | `w:<name>` always shown; `?` when the worker key is unknown |
| live worker tag `▶<tag>` | newest file in `claude-worker-tags/<sid>/` (written by `worker-tag-hook`) | Render reads the newest tag file | Ignored when its mtime >600s (falls back to the static config prediction) | No fresh tag → segment falls back to the config prediction |
| chat topic (dim, Russian) | `topic-<sid>` cache written by `statusline-topic-hook` generator (headless haiku via claudeb, `--no-session-persistence` so generator runs leave no transcripts in `projects/`) | UserPromptSubmit debounce: first substantive prompt, or ≥5 prompts since last gen, or ≥600s + ≥2 prompts | Always dim — a human hint, not live data; not dim-escalated | File absent/empty → no segment; deleted on `SessionStart` `source=clear`; pruned after 7 days; truncated to 44 chars with `…` |

## Line 2 — usage

| Segment | Source of truth | Update trigger | Staleness / dim policy | Removal condition |
|---|---|---|---|---|
| `ctx <pct>` + `<n>k` tokens | JSON `.context_window.used_percentage` / `.current_usage` | Every render | Live each render. Only the `%` carries color: green <40, yellow 40–79, red ≥80 — the 40 (vs the standard 50) is an early "/compact" nudge, since a large context re-bills cache reads every turn. The `<n>k` token count is an auxiliary number and is always dim. | token count hidden when 0 |
| `5h <pct>` + reset time | merged rate-limit cache (`statusline-cache-rl` for main, `limits/<acct>.json` for claudeb) — live headers merged under lock each render | Every render merges newer headers; the claudeb daemon writes the caches | Dimmed if reset passed, `auth=expired`, `origin=cached`, `as_of` >1800s, or the `llm-limits.json` `stale` flag is set | Never removed; `?` when unknown |
| `wk <pct>` + reset | same cache (`seven_day`) | Every render | Dimmed if reset passed, expired/cached, `as_of` >21600s, or `stale` flag | Never removed; `?` when unknown |
| `fb <pct>` + reset | `~/.llm-limits.json` `vendors.claude.accounts[].fable` | Every render reads the file (the `llm-limits` collector writes it) | Dimmed if the account's `stale` flag is set or the file mtime >21600s | Only for a non-`main` account that has a `fable` bucket; else absent |
| `$<cost>` | JSON `.cost.total_cost_usd` | Every render | Live each render (`LC_ALL=C` for the decimal point) | Absent when cost is null |

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
