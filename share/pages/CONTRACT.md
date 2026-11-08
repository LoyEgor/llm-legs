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
Egor's live Mac chats on the iPad, every account in one list, and his past ones to read and reopen. A live
chat is never resumed: text goes into the Terminal tab the chat already runs in (same process, same account,
warm cache); a past one opens as `chats` opens it, in a new Terminal window. Same host check and POST rules as
above; `page lan --app` prints the link. Terminal is touched only through Hammerspoon's
`ChatGate.terminalScript` (`hs -c`), the menubar only through llm-limits' read-only `menuItems()`.
The client keeps one draft for every chat; Send goes to the chat on screen at the tap (a dictation running
then delivers its transcript there, wherever he goes next). A long press on a chat in the list (a secondary click
with a pointer) opens its menu: Rename, Branch (both with a name), Pin, End chat (live only), Trash (Undo in its
toast); the info panel holds none of them. End, and Trash of a chat that works or holds processes, ask in the menu
first, listing what stops. A live row shows how many processes its chat runs; the info panel lists them (Running),
each stopped by a second tap on its ×. Pinned chats lead Earlier, which lists newest first or by project
(folders ordered by their newest chat, a tap opens one). Its look is the UI kit `kit/ui.css`, linked before
`app.css` and shared with the pages.

| Route | Answer |
|---|---|
| `GET /app/` | the client (`index.html`, `app.js`, `app.css`, `icon.png`; `/kit/ui.css` counts in its fingerprint); `manifest.webmanifest` starts at `/app/?k=<token>`, so a home-screen app gets its own cookie |
| `GET /api/chats` | `{machine, chats, workers, runs, client}` (`client`: the client files' fingerprint; a running client that sees it change reloads itself, draft and open chat kept, once no dictation or message is on its way, a thin tap-to-reload line meanwhile): live registry records (`~/.claude*/sessions`, pid + `procStart` checked) with tty, account (the process env, `chat-account.sh` order), chat-find's name/ctx/model, warm cache `until`, memlogd load, last line, latest recap, page count. Workers = no tty or `entrypoint` ≠ `cli`, read-only, minus those `runs` names |
| ↳ `runs` | worker-run's live runs of every vendor, newest first: `{id, vendor, account, model, effort, title, started, launcher, phase, round, queued, sid, tokens, status}` from run dirs launched within 2 days with no `exit_code`, alive by shared-invariants row `ar` (one `ps` for all); `sid` only for a claude run whose transcript exists (then `/api/chat/<sid>/log` reads it) |
| `GET /api/chat/<sid>/log[?after=N\|?before=N]` | `{items, start, end, size, pages}`: transcript items (`user`, `asst`, `tool`, `result`, `event`, `away`, `queued`, `unqueued`) of the tail, after byte N, or the block ending at N (the tail and a block: 768 KB windows joined until six things were said in them, `user`/`asst`/`away` with text, or 32 MB were read; the client asks for one block per scroll of his near the top, and on its own while the thread is shorter than the screen). A message typed while the chat works is `queued` (its `enqueue`; the `<pasted_content>` wrapper of the app's bracketed paste removed), then `unqueued` (`op`: `remove`, `dequeue`, `popAll`; a `dequeue` names no text: it takes the queue's head). `hide: true` (with `t: ""`) is a queued notification, not his message; one absorbed mid-turn comes back as `user` with `mid: true` and its own time |
| `GET /api/chat/<sid>/info` | `{status, files, root}`: `status` the chat's statusline lines 1-2 as `[[text, colour], ...]` runs (`colour` a SGR name: `cyan`, `magenta`, `blue`, `green`, `red`, `yellow`, `dim`, or `''`) from `render-full-<sid>` in `STATUSLINE_CACHE_DIR` (the lines before any fit step, docs/statusline-contract.md "Full render"), else the fitted `render-<sid>`; `files` `[{p, add, del, at}]` newest first, what the chat's own Edit/Write calls that went through changed (their `toolUseResult.structuredPatch`), the transcript read once and then only what it grew by; `root` the chat's cwd |
| `GET /api/chat/<sid>/screen[?history=1]` | `{ok, res}`: the tab's visible text, or its scrollback (Terminal's `history`, the last 400 KB from a line start: the Terminal sheet scrolled past the screen); a failure or `no-tab` is an `.events.jsonl` line, one per chat per minute with the count it swallowed |
| `POST /api/chat/<sid>/send` | `{text}` → one bracketed paste + Return in the tab → `{ok, err}` |
| `POST /api/chat/<sid>/unqueue` | `{text}` → a queued message taken back before the chat reads it, only from an empty input showing Claude Code's queue hint: Up pulls the queue into the input, Ctrl+U/Backspace and a backslash leave nothing to submit, the others are pasted back in order → `{ok}` or `{ok: false, err, back}` (`back`: the texts the input lost) |
| `POST /api/chat/<sid>/key` | `{key: esc\|enter\|up\|down}` or `{choose: N}` (arrows from the `❯` option, then Return) |
| `GET /api/history[?h=]` | `{chats, h}`: chat-find `--recent --json` (cached 3 s) as `{sid, name, cwd, project, branch, model, spoke, role, text}`, newest first; live chats are in it too (the client marks them open); `project` the folder `chats` shows (a worktree's main checkout); `h` the list's hash, `{same: true, h}` when it equals the one sent (the client asks every 15 s, on coming back and after a chat's action) |
| `GET /api/search?q=` | `{chats}`: `chat-find --json --limit 40 -- <words>` (≤ 8; seconds: it reads every transcript) as `{sid, name, cwd, spoke, title, text}`, cached 120 s per query; a failure is a 502 `{err}`, not cached |
| `POST /api/chat/<sid>/open` | `{}` → a live chat only `{ok, live: true}` (a second resume would fork it); else `chats --open-command <sid>`'s line in a new Terminal window (`do script`) → `{ok, account, source}`; 502 with `chats`' or Terminal's error, 400 on a bad id |
| `POST /api/chat/<sid>/close` | `{force?}` → an idle live terminal chat gets `/exit` typed; once its pid is gone (8 s) its window closes if the chat was its only tab → `{ok, window: closed\|tabs\|left}`; 404 not a live terminal chat, 409 `{status, procs}` while it works (`busy`/`shell`) or holds processes, unless `force: true`: then a working turn gets Esc (≤ 5 s) and its processes are stopped first; 504 when it did not exit (the window stays) |
| `GET /api/chat/<sid>/procs` | `{procs}`: what a live chat runs, its children minus Claude Code's own (caffeinate, its config dirs' event helpers), longest running first: `{pid, cmd, up, cpu, mem, n, ports}` (`cmd` the Bash tool's eval'd line, `up` seconds, `cpu`/`mem` (MB)/`n` its whole tree, `ports` TCP it listens on, one `lsof`); 404 not live. `/api/chats` rows carry their count as `procs`, `/info` the list as `procs` |
| `POST /api/chat/<sid>/stop` | `{pid}` → one of the chat's `procs` and its tree: TERM, KILL after 3 s → `{ok, stopped}`; 404 for any other pid |
| `POST /api/chat/<sid>/pin` | `{on}` → chat_pins' pin or unpin → `{ok, pins}` |
| `POST /api/chat/<sid>/rename` | `{name}` (one line, whitespace collapsed, ≤ 100 chars; 400 when empty) → a live terminal chat gets `/rename <name>` typed, a closed one the `custom-title` transcript line `/rename` writes → `{ok, live}`; 404 with no transcript |
| `POST /api/chat/<sid>/branch` | `{name}` (may be empty) → open's `chats --open-command` line plus `--fork-session --name <name>`, the chat live or not, in a new Terminal window → open's answer; until the branch writes its own transcript (its first message) its log is the parent's up to the last line stamped before the branch began (its `startedAt`), `file` in the log's answer tells the client which |
| `POST /api/chat/<sid>/trash` | `{force?}` → into the trash `/trash` uses (claude-setup's `session-trash.sh`: out of every history, restorable): marked, then a live terminal chat ended as close ends it (its session end moves it; 409 while it works or holds processes unless forced, close's failure unmarks it), a closed one swept from its own config root → `{ok, live, window}`; unpinned |
| `POST /api/chat/<sid>/untrash` | `{}` → `session-trash.sh restore` → `{ok}`, 502 with nothing to restore |
| `POST /api/mic/start` | `{}` → a remote take on transcriptions-gpt (its ipad-mic/PROTOCOL.md "Remote take") → `{ok, id, via}` once it records; `{"via": "macmic"}` records MacMic's own stream instead (no chunks), MacMic asleep woken first (the daemon's `ipad-wake`, its stream awaited 12 s; 409 when it does not come); a start ends a stale take still recording (its chunks then get 404), 409 only while the last one is being transcribed, 503 with no daemon |
| `POST /api/mic/<id>/chunk` | `application/octet-stream`, ≤ 256 KB of 16 kHz mono int16, in order: relayed as 20 ms receiver packets to `127.0.0.1:47654`, silence between bursts; 10 s with no chunk cancels the take |
| `POST /api/mic/<id>/alive` | `{}`, a MacMic take's beat in place of chunks (10 s without one cancels it) → `{ok, level, macmic}`: the receiver's RMS of the last 0.25 s, MacMic `streaming`/`asleep` |
| `POST /api/mic/<id>/stop` | one `stop` to the daemon, then its transcript from the deliver file → `{ok, text}` (never pasted on the Mac) |
| `POST /api/mic/<id>/cancel` | the daemon's `cancel`, sent only while it records or transcribes (the client's × stops the take instead: its text goes into the draft) |
| `GET /api/mic/bubble` | the daemon's `bubble`: what the Mac's voice pill shows and offers → `{ok, state, remote, pill, polish_since, alt, degraded, restore, macmic}` (`streaming`/`asleep`/`""`); each look sends `ipad-want 7200`, keeping MacMic streaming 2 h past the app's last look; `{ok: false, err}` from a daemon without it |
| `POST /api/mic/usealt` | `{}` → the daemon's `usealt` (the pill's click on a ready other result, or paste-now in the polish seconds) → `{ok, err}` |
| `POST /api/mic/restore` | `{name?}` → the daemon's `restore {"deliver"}`: the cut take (named, else offered, else newest) transcribed again into a file, not pasted on the Mac, also over a take of ours still recording (the daemon discards it; it is closed here without a cancel) → `{ok, text}` within 240 s; 409 while a take is being transcribed |
| `GET /api/load` | `{title, rows, as_of}`: bin/chat-load's `chats.json` rows as they are (the menubar's Chats/other, a row's `sub` included) |
| `GET /api/menu` | `{items}`: the menubar as `{r: [{t, c, a, b}], ck, dis, sub}`, cached 4 s |
| `GET /api/pages` | every page's `{pid, title, chat, owner, module, updated}`, newest first |
| `POST /api/client-log` | `{kind, msg, path, ms, count, hidden, sid, ua}` → `.events.jsonl` (`op: client`), 20 a minute: what failed on the iPad (a lost connection once it is back, a script error, a `tap-lost`: a tap on something that acts with no click in 0.7 s, `path` the target, `msg` its node replaced / mutations / scroll / focus / sheet / mic) |

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
