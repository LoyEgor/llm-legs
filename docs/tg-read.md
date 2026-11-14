# tg-read

Egor's own Telegram account through the official API (Telethon): read chats, fetch and transcribe
voice messages, post one plain-text message. Code: `share/tg_read.py`, wrapper `bin/tg-read`, venv
`~/.local/share/tg-read/.venv`.

## Login

`tg-read login --qr` once, in Egor's own terminal: scan the QR from the phone (Settings > Devices >
Link Desktop Device). The phone-code path exists but Telegram never delivers the code. A session
revoked server-side shows as `not logged in`: run `login --qr` again.

## Commands

<chat> = a dialog name substring (case-insensitive), a @username, a numeric id, or `me` (Saved Messages).

    tg-read chats --limit 20
    tg-read read "Гапоненко" --limit 5 [--since 2026-10-01] [--json]
    tg-read voice "Гапоненко" --last 1 --dest-dir /tmp/voice [--transcribe]
    tg-read photo "Гапоненко" --last 2 --dest-dir /tmp/photos
    tg-read file me --name FOR-MAC --dest-dir /tmp/files     # sent documents, saved as <msg id>-<their name>
    tg-read transcribe /tmp/voice/voice-20261022-1200-123.ogg [--dest /tmp/t.txt] [--language ru] [--engine auto|elevenlabs|groq]
    tg-read send me --text "test"            # or --file /abs/message.txt
    tg-read send "Гапоненко" --file /abs/msg.txt --photo /abs/a.png --photo /abs/b.png   # an album, the text as its caption
    tg-read send me --text "Сертификат" --doc /abs/mac-chats-ca.crt      # one file as a document, the text as its caption
    tg-read edit me 224440 --text "fixed text"   # [--file /abs] [--as-written]: ONE own message, same checks as send
    tg-read delete me 224440 --yes               # ONE own message, both sides; without --yes shows it and refuses
    tg-read wait 5136327405 --after 223868   # [--hours N | --until 23:00] [--every 15] [--settle 20]

- `chats`, `read`, `voice`, `photo` and `file` are read-only: they never send, mark read or delete.
- `send` posts exactly the given text as Egor, once, plain text (no Markdown), and prints
  `sent #<id> to <name> at <time>`. Before sending, `ё`/`Ё` become `е`/`Е` and em/en dashes a plain
  `-` (Egor cannot type those); `normalized: yo=<n> dashes=<n>` is printed when anything changed.
  It refuses (exit 2) an empty text, more than 4000 chars, or a channel. `edit` and `delete` act on one own
  message by id, never in a channel (exit 2 otherwise); delete only on Egor's explicit word in the
  chat. An edit notifies nobody; the other side sees an "edited" mark.
  With `--photo` (absolute paths, up to 10) the pictures go as one album with the text as its
  caption: at most 1024 chars, and every file is checked before connecting. `--doc` (one absolute path, not with
  `--photo`) posts a file as a document (saved on the phone as it is), the text as its caption, the same limit.
- `send` also writes as Egor does (claude-setup `hooks/lib/owner_text.py` `as_egor`): an opening
  greeting goes when the chat already talked today (a person: any message, a group: his own), and the
  person's name used as an address (`Славо, …` / `…, Слава!`) and the message's final period (not an
  ellipsis or `т.д.`) always; `dropped: …` says what went, a
  text that was only a greeting is refused (exit 2). `--as-written` keeps both, only when his own words
  for that message carry them.
- `wait` runs as a background Bash right after `send` (which prints its line), so the answer wakes the
  chat: exit 0 once the chat has been quiet for --settle seconds after an answer (a person: any message,
  and the whole exchange is printed, Egor's phone replies too; a group: a reply to that message or a
  mention of Egor). Its last line re-arms the watch from the newest message: run it. No deadline by
  default: it follows answers while the chat that started it lives; a span Egor named (`--hours N`,
  `--until HH:MM`) is a hard end the re-arm carries. Only a span or the idle limit (off) prints `watch
  ended`; it stops silently when its chat closes (claude-setup `hooks/lib/chat_watch.py`).
- `voice` takes voice messages (`.ogg`) and video notes (round videos, `.mp4`) alike; `--transcribe` writes
  `<file>.txt` next to each download and appends its path to the line.
- `transcribe` prints `transcript=<dest> engine=<elevenlabs|groq> chars=<n>`; default dest `<audio>.txt`.

## Transcription order

`auto`: ElevenLabs through the media door (`IMAGE_LEG_CLI_OK=1 media-run transcribe --vendor
elevenlabs`), then Groq Whisper (`whisper-large-v3`) only when ElevenLabs fails for usage: exit 3 or
`USAGE_LIMIT`/`credits`/`quota`/`402`/`429` in its output (`should_fall_back`). Any other failure is
printed verbatim, exit 1. Telegram's Ogg/Opus goes to both as is.

## Key files (contents never printed)

- `~/.config/telegram/api.txt` — api_id, api_hash
- `~/.config/telegram/session.session` — the logged-in session
- `/Volumes/Work/Projects/transcriptions-gpt/settings/groq_keys.txt` — Groq keys, one a line; the next
  is tried on 401/429
- ElevenLabs credentials: whatever `media-run` uses

Tests: `tests/test_tg_read.py` (parsing, normalization, fallback decision; no network).
