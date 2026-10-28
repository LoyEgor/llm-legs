# Local pages: implementation plan v1 (2026-10-28)

Status: PLAN under review, nothing built. Research, requirements and the evidence behind every choice:
`docs/handoffs/2026-10-28-pages-research.md` (same directory). Settled with Egor and NOT up for
re-deciding: local HTML pages replace claude.ai artifacts; reusable modules a chat fills with data;
live per-click state the chat pulls any time (no Submit); per-chat page registry surviving compaction;
zero context cost for chats that make no pages.

## Constraints
- Egor's Mac runs many Claude Code chats at once; the service must cost ~0 CPU idle and little RAM,
  survive reboots, and never be "dead when he comes back".
- Pages are opened in Dia on the Mac and in Safari on his iPad (same home network).
- Every chat (three Claude accounts, plus codex/grok workers) must use the same system.
- Code stays small and boring: stdlib Python, plain ES modules, no build step, no frameworks.

## Components

### 1. Server — `share/pages/server.py` (~200 lines)
- `ThreadingHTTPServer`, HTTP/1.1, one fixed port, launchd agent with `KeepAlive` and `RunAtLoad`.
- Stateless: everything lives on disk, so a restart loses nothing.
- Routes:
  - `/` — index of all pages grouped by chat name (resolved through `chat-name`), newest first.
  - `/p/<id>/` — the fixed loader page; `/kit/*` — module files; `/p/<id>/spec.json`.
  - `/p/<id>/m/<n>` — media by index from the page's allowlist (absolute paths recorded at
    `page new`), with Range/206 support, `Cache-Control: no-cache`, connection resets ignored.
  - `GET /p/<id>/state` — current state (fold of the log) + revision.
  - `POST /p/<id>/patch` — one item's change `{item, field values, client_rev}`; appended to the log
    under `flock`; the response carries the new revision and the spec revision.
- Binding: loopback by default; LAN for the iPad behind a per-install secret (cookie set from a
  `?k=` link) if Egor picks LAN.

### 2. Store — per page folder under `~/Pages/<id>/`
- `meta.json` — id, title, module, chat session id, project cwd, created, media allowlist.
- `spec.json` — what the page shows and asks (module-specific), with a `rev`.
- `log.jsonl` — append-only, one line per change `{at, rev, by: egor|chat, item, values}`.
  State = last value per (item, field). Per-item patches, never whole-object POSTs, so a stale tab
  cannot overwrite the chat's or another tab's marks.
- No separate registry file: the registry is a scan of `~/Pages/*/meta.json`.

### 3. Kit — `share/pages/kit/` (plain ES modules)
- `shell.js` (~200): loads spec + state, `save(item, values)` debounced per item, "saved hh:mm ·
  N of M" status, stable ids, keyboard dispatcher on `event.code` (layout-independent, so A works as
  ф without alias maps), keys ignored in text fields, re-fetch on `visibilitychange`/focus and when a
  save response shows a newer spec/state revision (no SSE, no polling).
- `compare.js` (~350): port of logo-vectorizer-bench `results/lanes/coord/tools/vote.tpl.html`
  (116 lines, gitignored — rescue it into the kit): N synced loupes (original + variants), pointer-
  anchored zoom, preview with clipped view boxes, hotspots, fit/1:1, pointer-capture fixes; options
  and tags from spec (A/B/tie/both_bad/unsure + per-side tags), always-pixelated flag, blind mode.
- Phase 2, ported when a chat needs them: `cards.js` (listen-bench `defects.py` page: numbered cards,
  fields choice/multi/scale/text/time), `media.js` (audio minute excerpts, A/B same position, sample-
  exact Web Audio loop, video frame-step/timeline marks — listen-bench + `share/video_glitch.py`),
  `pairs.js` (likeness `rate`).
- A module declares its spec contract in `kit/<module>.md` (fields, example) — what `page help` prints.

### 4. CLI — `bin/page` (~250 lines, stdlib Python)
- `page new <module> --id <slug> --title T --spec FILE` — validates required spec keys and that every
  media path exists, writes the folder, prints the URL. Same id in the same chat = update the spec
  (bumps spec rev, keeps the log) — the reuse path.
- `page list [--all]` — this chat's pages (session from `CLAUDE_CODE_SESSION_ID`, as `chat-pin` does).
- `page state <id> [--since REV]` — a compact per-item summary; `--since` = only what changed since the
  chat last read (the chat sees changed choices).
- `page set <id> <item> k=v` — the chat marks something for Egor (logged as `by: chat`).
- `page open <id>` — opens it in Dia; `page help [module]` — the modules and their spec contracts.
- Reads go straight to disk (work with the server down); writes append under the same `flock`.

### 5. Discovery (no context cost for page-less chats)
- Artifacts off: `CLAUDE_CODE_DISABLE_ARTIFACT=1` exported by the claudeb launcher (one place, every
  profile and worker) or `enableArtifact: false` per profile settings — the Artifact tool and its long
  description leave the context.
- One global CLAUDE.md line: "A page for Egor to vote/compare/review → `page help`; never hand-written
  HTML or artifacts."
- SessionStart hook on `compact`/`resume`: if this chat owns pages, one line listing them.
- Optional backstop: a PreToolUse notice when a Write creates an `*.html` with vote-like code outside
  the kit (risk: false positives on real websites Egor builds).

### 6. Migration
- pixel-forge's calibration page (claude.ai artifact, 0 votes) moves to `compare` first.
- Existing project pages (listen-bench, video_glitch, oversharp) keep working; they move only when
  their chat next needs a change.

## Budget
Phase 1 (server, store, shell, compare, CLI, hooks, launchd, tests): ~1000–1200 lines, ~10 files.
Phase 2 (cards, media, pairs): ~600 lines.

## Alternatives considered
- Pushing pages to Egor's site (loyegor.com = GitHub Pages, static): reachable anywhere, but no
  backend for votes, a push + Pages build per iteration, media made public. Rejected for votes; maybe
  later for sharing a read-only snapshot.
- Server started on demand by `page`: zero RAM idle, but dead when Egor opens a bookmark first.
- Reading votes from the browser's localStorage files (what the Vector Magic chat did): no server,
  but Mac-only, Dia-profile-specific, and its reader script got lost.

## Open with Egor
LAN access for the iPad (secret link) vs Mac only; artifacts fully off.
