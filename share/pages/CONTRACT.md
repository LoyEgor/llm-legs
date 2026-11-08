# Pages contract (schema 1)

The one interface between `bin/page` (+ `share/pages/store.py`) and the kit (`share/pages/kit/`).
Plan: `docs/handoffs/2026-10-28-pages-plan.md`. A change here changes both sides; `schema` bumps only
on an incompatible change.

## Server
- **Address:** `http://127.0.0.1:${PAGES_PORT:-4791}`, store root `${PAGES_DIR:-~/Pages}`. The one
  socket listens on every interface (`PAGES_LAN=0`: loopback only) so another device on the home
  network can open a page.
- **Host check:** a loopback client whose `Host` is `127.0.0.1:<port>` or `localhost:<port>` passes;
  any other request needs the cookie `pages_k` equal to `<store root>/.lan-token` (made once, mode
  600), else 403. A GET with `?k=<token>` sets that cookie and 303s to the same path without the
  query; `page lan [ref]` prints that link (`http://<LocalHostName>.local:<port>/…`), copies it and
  draws a QR code.
- **POST** also requires `Content-Type: application/json` (the upload route also takes `image/*` and
  `application/octet-stream`, a mic chunk only the latter) and, when an `Origin` header is present, an
  origin equal to the page's own, `http://` or `https://` + `Host`; else 403.
- **HTTPS:** `page tailscale` runs tailscaled in userspace mode (LaunchAgent `com.llm-legs.tailscaled`,
  socket `~/.local/state/tailscale/tailscaled.sock`) and `tailscale serve` 443 → `127.0.0.1:<port>`;
  the proxied request keeps the tailnet `Host`, so it still needs the cookie. Safari gives a page the
  microphone only over https.

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
| `POST /p/<pid>/error` | `{msg, src, line}`, a kit error the loader reports (≤ 3 per load) → `.events.jsonl`; 204 |
| `POST /p/<pid>/upload?item=&field=[&at=&about=]` | a pasted or dropped picture's bytes, or `{"url"}` the server fetches → `{name, url, mark}`; 415 for anything not a picture (below). With `at` (the browser's `Date.now()` of a «Метка») the server hands `[name]` to transcriptions-gpt (its MARKS.md: `ref` = the file, `note` = the page URL - `about`); `mark` is the daemon's reply, `ok …` = a running dictation takes the name, else `null`/`ignored …` |
| `POST /p/<pid>/drop` | `{name, item, field}`: × on a field's picture; the field stops owning it (the file stays). A mark a running dictation took gets `unmark {"tag": name}` to transcriptions-gpt → `{unmark}`: its reply, `ok …` = taken out of the dictation, else `null`/`ignored …`/`err …` |
| `GET /p/<pid>/files` | `[{name, item, field}]`: the page's pictures and the text field each was pasted into |
| `GET /p/<pid>/f/<name>` | one picture, `name` = `img<N>.(png\|jpg\|gif\|webp)`, else 404 |
| `GET /p/<pid>/m/<n>?v=<mtime_ns>` | media `n` from `meta.media`; Range/206 streamed in 1 MB chunks, an open-ended range capped at 8 MB; `ETag`, `Cache-Control: private, max-age=31536000, immutable` |

`pid` matches `^[a-z0-9][a-z0-9-]{0,63}$`; anything else is 404 before any path join.

## App (`share/pages/app.py`, client `share/pages/app/`)
Egor's live Mac chats on the iPad, every account in one list. A chat is never resumed: text goes into the
Terminal tab the chat already runs in (same process, same account, warm cache). Same host check and POST
rules as above; `page lan --app` prints the link. Terminal is touched only through Hammerspoon's
`ChatGate.terminalScript` (`hs -c`), the menubar only through llm-limits' read-only `menuItems()`.

| Route | Answer |
|---|---|
| `GET /app/` | the client (`index.html`, `app.js`, `app.css`, `icon.png`); `manifest.webmanifest` starts at `/app/?k=<token>`, so a home-screen app gets its own cookie |
| `GET /api/chats` | `{machine, chats, workers}`: live registry records (`~/.claude*/sessions`, pid + `procStart` checked) with tty, account (the process env, `chat-account.sh` order), chat-find's name/ctx/model, warm cache `until`, memlogd load, last line, latest recap, page count. Workers = no tty or `entrypoint` ≠ `cli`, read-only |
| `GET /api/chat/<sid>/log[?after=N\|?before=N]` | `{items, start, end, size, pages}`: transcript items (`user`, `asst`, `tool`, `result`, `event`, `away`) of the tail, after byte N, or the window ending at N |
| `GET /api/chat/<sid>/screen` | `{ok, res}`: the tab's visible text |
| `POST /api/chat/<sid>/send` | `{text}` → one bracketed paste + Return in the tab → `{ok, err}` |
| `POST /api/chat/<sid>/key` | `{key: esc\|enter\|up\|down}` or `{choose: N}` (arrows from the `❯` option, then Return) |
| `POST /api/mic/start` | `{}` → a remote take on transcriptions-gpt (its ipad-mic/PROTOCOL.md "Remote take") → `{ok, id}` once it records; 409 while another runs, 503 with no daemon |
| `POST /api/mic/<id>/chunk` | `application/octet-stream`, ≤ 256 KB of 16 kHz mono int16, in order: relayed as 20 ms receiver packets to `127.0.0.1:47654`, silence between bursts; 10 s with no chunk cancels the take |
| `POST /api/mic/<id>/stop` | one `stop` to the daemon, then its transcript from the deliver file → `{ok, text}` (never pasted on the Mac) |
| `POST /api/mic/<id>/cancel` | the daemon's `cancel`, sent only while it records or transcribes |
| `GET /api/menu` | `{items}`: the menubar as `{r: [{t, c, a, b}], ck, dis, sub}`, cached 4 s |
| `GET /api/pages` | every page's `{pid, title, chat, owner, module, updated}`, newest first |

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

## Pictures in text
Every text field of every page takes a pasted or dropped picture (the shell's, no module wires it):
the server stores it as `files/img<N>.<ext>`, numbered per page; TIFF, HEIC, BMP and AVIF become PNG
through `sips`, the same bytes again keep their first name, `files/index.json` keeps the item and field.
The field gets the short name `[img<N>.<ext>]` at the caret, so a value's text says which picture a
word is about; `page state` follows such a field with `img<N>.<ext>=<absolute path>`.

## Log line (`log.jsonl`)
`{"op","at","by":"egor"|"chat","item","fields","spec_rev"}`. State is the last value per
(item, field) in file order; a torn trailing line is skipped.

`<root>/.events.jsonl` gets a line only when something went wrong (`where`: cli, browser, server) or a
chat was about to hand-make a page (hint); capped at 1 MB.

## Modules
A module's spec keys, fields written and example live in `kit/<module>.md` (`page help <module>`);
extending one: `EXTEND.md`. The server knows only:
- every item has an immutable `id` (`^[A-Za-z0-9_-]{1,64}$`), and so does every compare variant;
- media paths, `_` keys and blind variants, as in "Served spec" above;
- common optional keys: `title`, `intro` (one short line), `sitting_cap` (stop asking after N answered
  this sitting), and `suggest` per item (a machine suggestion: shown apart, never an answer).

## CLI (the chat's whole interface)
| Command | Does |
|---|---|
| `page help [module]` | one line per module, or that module's example spec |
| `page new <module> --slug S --title T [--replace ITEM]... [--no-open] < spec.json` | creates the page, or updates the caller's own page with that slug; prints URL and pid |
| `page state <slug\|pid> [--all]` | items changed since this session last read, one line each: `id field=value … by=…`, a picture the text names as `img3.png=<path>` to Read; then totals `answered/total`, `rev` |
| `page set <slug\|pid> <item> field=value…` | writes a field as `by: chat` |
| `page list [--all]` | this chat's pages, or every page |
| `page open <slug\|pid>` | opens the page in Dia |
| `page lan [ref] [--app]` | the link to a page, the index, or the chats app; https on the tailnet when `page tailscale` set it up, else the home network; clipboard + QR |
| `page tailscale` | HTTPS on Egor's tailnet: the tailscaled agent, the login URL until he logs in, then `tailscale serve` |
| `page doctor` | server up? port owner, deployed copy current, PAGES_DIR |
| `page report [--days N]` | pages made per chat and module, the `.events.jsonl` problems and hints, kit commits |
| `page serve` | the daemon (launchd runs `~/.local/libexec/pagesd`) |
| `page install-agent` | deploys the copy and loads the LaunchAgent |
