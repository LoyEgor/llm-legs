# Pages contract (schema 1)

The one interface between `bin/page` (+ `share/pages/store.py`) and the kit (`share/pages/kit/`).
Plan: `docs/handoffs/2026-10-28-pages-plan.md`. A change here changes both sides; `schema` bumps only
on an incompatible change.

## Server
- **Address:** `http://127.0.0.1:${PAGES_PORT:-4791}`. Loopback only; store root
  `${PAGES_DIR:-~/Pages}`.
- **Host check:** the `Host` header must be `127.0.0.1:<port>` or `localhost:<port>`, else 403.
- **POST** also requires `Content-Type: application/json` and, when an `Origin` header is present, an
  origin equal to the page's own; else 403.

## Routes
| Route | Answer |
|---|---|
| `GET /` | HTML index: pages grouped by `meta.chat_name`, newest first, each linking `/p/<pid>/` |
| `GET /healthz` | `{"pages": 1, "schema": 1, "pid", "dir"}`: proves the port is ours |
| `GET /p/<pid>/` | `kit/loader.html` (same file for every page) |
| `GET /kit/<file>` | a kit file, realpath-confined to the kit dir |
| `GET /p/<pid>/spec` | the served spec (below), `Cache-Control: no-cache` |
| `GET /p/<pid>/state` | the state (below), `Cache-Control: no-cache` |
| `POST /p/<pid>/patch` | applies one patch (below) |
| `GET /p/<pid>/m/<n>?v=<mtime_ns>` | media `n` from `meta.media`; Range/206 streamed in 1 MB chunks, an open-ended range capped at 8 MB; `ETag`, `Cache-Control: private, max-age=31536000, immutable` |

`pid` matches `^[a-z0-9][a-z0-9-]{0,63}$`; anything else is 404 before any path join.

## Served spec
This is `spec.json` with three changes:
- every media path is replaced by its `/p/<pid>/m/<n>?v=…` URL;
- every key starting with `_` is gone (those live in `key.json`, never served);
- blind compare variants are served as `"slot": "A"`, `"B"`, … in a sha256(pid + item id) shuffle,
  `id` and `label` removed.

The page also gets `pid` and `rev` (the spec revision, an integer bumped by every `page new` update).

## State
```json
{"rev": 17, "spec_rev": 3,
 "items": {"p01": {"choice": {"v": "A", "at": "2026-10-28T15:01:02Z", "by": "egor"},
                   "note":   {"v": "halo on the left", "at": "…", "by": "egor"}}}}
```
- `rev` = applied log lines: the page's cheap change check, polled every ~4 s while visible.
- A field whose last value is `null` is absent.

## Patch
```json
POST /p/<pid>/patch
{"op": "<uuid from the page>", "item": "p01", "fields": {"choice": "A"}, "spec_rev": 3}
→ 200 {"rev": 18, "spec_rev": 3, "dup": false}
```
- `fields` holds ONLY what this gesture changed; `null` clears a field.
- There is no client-rev rejection. The server merges per field, appends one log line under flock,
  and an `op` seen before answers `dup: true` without appending.
- An item id that is not in the current spec gets 409.

## Log line (`log.jsonl`)
`{"op","at","by":"egor"|"chat","item","fields","spec_rev"}`. State is the last value per
(item, field) in file order; a torn trailing line is skipped.

## Modules
Every item has an immutable `id` (`^[A-Za-z0-9_-]{1,64}$`), and every compare variant has an
immutable `id`. Common optional spec keys:
- `title`;
- `intro` (one short line);
- `sitting_cap` (stop asking after N answered this sitting);
- `suggest` per item: a machine suggestion, shown apart, never an answer (compare: `{"choice": "A"}`
  or `"A"`).

### compare
```json
{"module": "compare", "schema": 1, "title": "Pixel judges calibration",
 "mode": "vote", "blind": true, "pixelated": "auto",
 "options": [{"id": "A"}, {"id": "B"}, {"id": "tie", "label": "="},
             {"id": "both_bad", "label": "оба плохи"}, {"id": "unsure", "label": "не понять"}],
 "tags": ["halo", "jaggies", "lost detail"],
 "items": [{"id": "p01", "title": "frog", "q": "optional context line",
            "original": "/abs/frog.png",
            "variants": [{"id": "v77", "label": "champ77", "src": "/abs/77/frog.png", "meta": "64 px"},
                         {"id": "v78", "label": "champ78", "src": "/abs/78/frog.png"}],
            "hotspots": [[120, 40]]}]}
```
- **mode:** `vote` (default) or `view`, a numbered grid with no vote widget.
- **Without `original`:** two variants form a plain pairwise page.
- **Keys:**
  - `options[].key` is an `event.code`; the defaults are A→`KeyA`, B→`KeyB`, tie→`KeyT`, the rest
    unbound;
  - ←/→ move between items, 0 fits, 1..9 jump to hotspots.
- **Computed by the page when absent:** `hotspots` (block-diff) and the image geometry.
- **Fields written:**
  - `choice`: an option id, or a slot letter on blind pages;
  - `tags`: `{"A": [...], "B": [...]}`;
  - `note`: a string.

### cards
```json
{"module": "cards", "schema": 1, "title": "Loop seams, round 3",
 "fields": [{"key": "heard", "kind": "choice",
             "options": [{"id": "0", "label": "не слышу", "key": "Digit1"}, {"id": "1", "label": "слышу"}]},
            {"key": "kind", "kind": "multi", "options": [{"id": "click"}, {"id": "gap"}]},
            {"key": "score", "kind": "scale", "min": 1, "max": 10}],
 "items": [{"id": "c11", "n": 11, "title": "track 3 wrap", "text": "optional context",
            "media": [{"kind": "audio", "src": "/abs/c11.m4a"}], "suggest": {"heard": "1"}}]}
```
- **Field kinds:** `choice`, `multi`, `scale`, `text`; optional `label`. Every card has a `note`.
- **Media:** `media[].kind` is `image`, `audio` or `video`, shown with the native element; only one
  clip plays at a time.
- **Numbering:** `n` is the shown number. It is stable and never renumbered when items are added.
- **Fields written:** each field's `key`, plus `note`.

## CLI (the chat's whole interface)
| Command | Does |
|---|---|
| `page help [module]` | one line per module, or that module's example spec |
| `page new <module> --slug S --title T [--replace ITEM]... [--no-open] < spec.json` | creates the page, or updates the caller's own page with that slug; prints URL and pid |
| `page state <slug\|pid> [--all]` | items changed since this session last read, one line each: `id field=value … by=…`; then totals `answered/total`, `rev` |
| `page set <slug\|pid> <item> field=value…` | writes a field as `by: chat` |
| `page list [--all]` | this chat's pages, or every page |
| `page open <slug\|pid>` | opens the page in Dia |
| `page doctor` | server up? port owner, deployed copy current, PAGES_DIR |
| `page serve` | the daemon (launchd runs `~/.local/libexec/pagesd`) |
| `page install-agent` | deploys the copy and loads the LaunchAgent |
