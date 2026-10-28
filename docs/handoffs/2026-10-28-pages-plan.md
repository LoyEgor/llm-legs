# Local pages: implementation plan v2 (2026-10-28)

Status: phase 1 BUILT 2026-10-28 (backend 3ae7b86c, kit c702a0fd, end-to-end check 59ef9dcd);
LaunchAgent com.llm-legs.pages up on 4791; compact/resume hook claude-setup 37b6eb2. Discovery line
in global CLAUDE.md (claude-setup 1391169, net −13 B via md-compact); its AGENTS.md/grok mirrors are
dropped (a worker makes a page only when its brief says so). §8 done 2026-10-28: pixel-forge votes
through `page` (pixel-calib, its kit keys integer_zoom/zoom_levels/pixel_grid/grid), and
`"enableArtifact": false` is set again. v1 went through a frontier critique (20261028T144144Z-68d13d8) and a T2
robustness review (20261028T144200Z-68d13d8); v2 folds both in — "Changed from v1" at the end.
Research and evidence: `docs/handoffs/2026-10-28-pages-research.md`.

Settled with Egor, not up for re-deciding: local HTML pages replace claude.ai artifacts; reusable
modules a chat fills with data; live per-click state the chat pulls any time (no Submit); a per-chat
page registry surviving compaction; near-zero context cost for chats that make no pages.

## Constraints
- ~0 CPU idle, ~20 MB RAM, survives reboots, never "dead when he comes back".
- Dia on the Mac only. Egor reaches the Mac from the iPad through Jump Desktop (remote desktop), so
  the server binds loopback and the kit is mouse-only; LAN access is a possible later addition.
- Every chat: three Claude accounts, codex and grok workers.
- Small and boring: stdlib Python, plain ES modules, no build step, no frameworks.

## 1. One program: `bin/page` (+ `share/pages/store.py`)
Server and CLI are one program over one store module, so locking, folding and validation exist once.
- `page serve` — the daemon. launchd runs a deployed copy, `~/.local/libexec/pagesd`, because TCC
  refuses a LaunchAgent that execs off /Volumes/Work (as `bin/memlogd`). The copy is registered in
  `bin/harness-doctor` DEPLOYS so an edit redeploys, with WorkingDirectory=$HOME.
- `KeepAlive` with one fixed, unusual port. If the port is held by our own server, exit 0. If anyone
  else holds it, retry the bind in-process with backoff and log once: no launchd restart storm, and
  the URL never changes. Socket activation (0 MB idle) is deferred until the ~20 MB is measured as a
  problem.

## 2. Store: `~/Pages/<pid>/`, root from `PAGES_DIR`
- `pid` = `<slug>-<6 random chars>`, globally unique. The slug is unique only within its owner chat.
  `page new` with the same slug in the same chat updates that page; another chat's slug never
  touches it. Ids match `^[a-z0-9][a-z0-9-]{0,63}$` before any path join.
- `meta.json` — owner session, chat name (resolved in the chat's shell at creation, refreshed by the
  hook), project cwd, module, title, created, media allowlist.
- `spec.json` — the served part. It carries `module`, `schema` (contract version) and `rev`. Every
  item and every variant has an immutable id.
- `key.json` — never served: the blind mapping, the chat's expected or LLM verdicts, hidden notes.
  `page new` moves any `_`-prefixed spec field here. The server shuffles blind variants
  deterministically per (pid, item).
- `log.jsonl` — append-only and authoritative. Each line is
  `{op, at, by: egor|chat, item, fields, spec_rev}`. State is the last value per (item, field),
  folded with an mtime-keyed cache in the server.
- Write rules:
  - meta and spec are written to a temp file and renamed;
  - a log line is one `write()` under `flock`, deduplicated by op id;
  - a torn trailing line is skipped on read.
- `~/Pages/.by-session/<sid>/<pid>` symlinks hold ownership, so the hook and `page list` never scan.
- Replacing a judged item's media under the same id is refused without `--replace`, which marks its
  old votes stale. A vote can never silently move to a different picture.

## 3. Server routes
- `/` — index grouped by the chat names stored in meta. A directory read, no subprocess.
- `/p/<pid>/` — the fixed loader. `/kit/*` is resolved with realpath and confined to the kit.
- `GET /p/<pid>/spec` — spec.json with media paths rewritten to `/p/<pid>/m/<n>?v=<mtime>`. The
  browser never sees a Mac path or a key field.
- `GET /p/<pid>/state` — the folded state plus `rev`, for the page's poll.
- `POST /p/<pid>/patch` — the fields this gesture changed, merged per field, with no client_rev
  rejection. Returns the new rev.
- `/p/<pid>/m/<n>` — media from the allowlist, which is rebuilt on every spec update; `n` is
  bounds-checked.
  - Range is streamed in 1 MB chunks, and an open-ended range is capped at 8 MB.
  - Media is served as immutable with an ETag. `no-cache` applies to spec and state only.
  - Broken pipes are ignored.
- Security:
  - a `Host` allowlist (loopback names);
  - POST requires `Content-Type: application/json` and a same-origin `Origin`.
  - LAN mode, if ever added: a per-install secret exchanged from `?k=` for an HttpOnly SameSite
    cookie, then stripped with `history.replaceState`; every route off loopback requires it.

## 4. Kit: `share/pages/kit/` (plain ES modules)
- `shell.js` — the module API, fixed before a second module copies the first:
  - **Saving:**
    - a choice is sent at once, text is debounced;
    - every gesture first goes to a localStorage outbox and leaves it only on ack, with retries on
      reconnect and reopen;
    - `pagehide`/`visibilitychange` flush with a keepalive fetch;
    - status is pending / saved hh:mm / failed, plus "N of M".
  - **Freshness:** a state/rev poll every ~4 s while visible, suspended when hidden. A newer spec
    re-renders and keeps pending edits.
  - **Keys:** dispatched on `event.code`, so A works as ф with no alias maps; ignored in text fields.
  - **Simplicity rules built in:** a note on every item, skip/can't-tell, an optional sitting cap,
    open on the first unvoted item, stable numbers, lazy load and unload of off-screen media.
- `compare.js` — ported from logo-vectorizer-bench `results/lanes/coord/tools/vote.tpl.html`, which
  is gitignored and is rescued into the kit first.
  - **View:** N synced loupes, pointer-anchored zoom, a preview with clipped view boxes, fit/1:1,
    always-pixelated option. Mouse only (see Constraints).
  - **Computed by the page:** geometry comes from the images; hotspots (block-diff) and the preview
    are computed in the browser. The spec holds paths and ids only; overrides are optional.
  - **Vote:** options and per-side tags (A/B/tie/both_bad/unsure), blind via the server.
  - **Modes:** two variants with loupes off is pairwise voting (no separate `pairs` module), and
    `view` mode is a numbered grid with no vote (the overview the Vector Magic chat hand-wrote).
- `cards.js` — the most-used proven pattern (listen-bench, video flags, verdict review): numbered
  cards with fields choice/multi/scale/text and native img/audio/video. One clip plays at a time. A
  machine suggestion is shown apart from his answer and is never counted as a vote.
- Phase 2, ported when a chat needs it:
  - **Media:** minute excerpts, A/B from the same position, sample-exact Web Audio loop, video
    frame-step and timeline marks.
  - **Module state from spec + log:** question queue, daily cap, pre-seek.
  - **Later still:** region masks, the transcription diff review.
- A module declares its contract in `kit/<module>.md`. `page help` prints one line per module, and
  `page help <module>` prints one example.

## 5. CLI
- `page new <module> --slug S --title T` reads the spec from stdin, so one Bash call creates,
  validates and opens it.
  - It checks ids and media existence, and copies media under /tmp or a scratchpad into the page.
  - It prints the loopback and LAN URLs and opens the page in Dia (`--no-open`).
- `page state <slug>` prints one line per item changed since this session last read
  (`id choice tags note by`), plus totals and the rev. The cursor is stored per session, so nothing
  is remembered across compaction. `--all` prints the full state.
- `page set <slug> <item> k=v` — logged `by: chat`.
- `page list [--all]` and `page doctor` (server up, port owner, deploy copy current).
- Owner resolution: `CLAUDE_LAUNCHER_SESSION` (a worker's page belongs to the chat that launched it),
  else `CLAUDE_CODE_SESSION_ID`, else `--chat`. Without any of them it is refused.

## 6. Discovery
- Artifacts off: `enableArtifact: false` in `~/.claude/settings.json`, which every profile symlinks.
  The tool and its long description leave every chat.
- One instruction, phrased by medium, not intent: "Any local browser page for Egor (vote, compare,
  review, overview, gallery, player) → `page help`; never hand-written HTML, `http.server` or
  artifacts."
  - It is folded into an existing global line if the instruction-bloat gate prices a new one.
  - It is mirrored into `~/.codex/AGENTS.md` and the grok worker brief preamble.
  - Its cost is honestly one line per session, not zero.
- SessionStart hook on compact/resume: `[ -d ~/Pages/.by-session/$sid ] || exit 0`, then one line per
  page (slug, module, answered/total, rev).
- No HTML-write backstop: it fires after the work is done, misses generator scripts, and false-positives
  on real sites.

## 7. Tests (`PAGES_DIR` is mandatory)
- Tests set a temp `PAGES_DIR` and use port 0. The CLI refuses a test run whose `PAGES_DIR` is unset
  or is `~/Pages` (a past test POST erased real votes).
- Covered:
  - per-field merge, so a stale tab cannot clobber a field;
  - op-id dedup, and a torn line skipped;
  - the key not served and blind shuffle stable;
  - Range chunking and caps, and path traversal refused;
  - owner resolution with and without the launcher;
  - the media allowlist rebuilt on update.

## 8. Migration
- pixel-forge's calibration page goes first: a claude.ai artifact with 0 votes, nothing to import. Its
  composite sheet becomes separate images, which it already has.
- Artifacts and pages are never both on (Egor 2026-10-28, decided): artifacts were turned off, then
  switched back on (the `enableArtifact` key removed from `~/.claude/settings.json`) only so
  pixel-forge keeps its vote page until `compare` lands. Closing step of this migration: set
  `"enableArtifact": false` in `~/.claude/settings.json` the moment pixel-forge votes through `page`.
- listen-bench, video_glitch and oversharp keep their own servers. A page moves only when its chat
  next changes it, with an explicit import of the items' stable ids.

## Budget
- Phase 1 is ~1250 lines without tests and ~250 of tests, in ~9 files:
  - `bin/page` + `store.py`, ~450;
  - `shell.js`, ~250; `compare.js`, ~350; `cards.js`, ~150;
  - hook, plist and deploy, ~50.
- Phase 2 is ~400 lines, when needed.

## Alternatives decided
- **loyegor.com (GitHub Pages):** it has no vote backend, needs a push plus a Pages build per
  iteration, and makes media public. Out; maybe later as a read-only `page export --static` for
  sharing.
- **Server started on demand:** dead when a bookmark is opened first. Out.
- **launchd socket activation:** deferred (see 1).
- **sqlite store:** considered. JSONL + flock stays: inspectable by hand, one writer function.
- **SSE / long-poll:** a visible-only short poll is stateless and holds no server threads.

## Changed from v1
- **Fixed holes:**
  - the blind key leaked through the served spec;
  - the last clicks were lost on tab close or Wi-Fi drop (now an outbox and a flush);
  - a stale tab could overwrite marks (now changed fields only);
  - a vote could reattach to a different picture (now immutable ids, `--replace`).
- **Server:**
  - deployed copy (TCC), no restart storm on a port clash;
  - streamed Range instead of whole-range reads (RAM), media cacheable;
  - Host/Origin/content-type checks against cross-site writes, path confinement.
- **Ownership:** a worker's page now belongs to the launching chat, slugs are namespaced, and chat
  names are stored so the index is instant.
- **Scope:** `cards` moved into phase 1 (otherwise audio, video and verdict pages have nowhere to
  go); `pairs` became a compare preset; compare gained `view` mode and iPad touch zoom.
- **Less model work:** the spec comes from stdin, the page computes hotspots and preview, `page state`
  prints only what changed, and the read cursor is stored, not remembered.
- **Dropped:**
  - the HTML-write hook;
  - the per-request chat-name lookup;
  - SSE;
  - client_rev negotiation;
  - the separate server/CLI duplicates.
