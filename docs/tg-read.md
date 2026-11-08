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
    tg-read transcribe /tmp/voice/voice-20261022-1200-123.ogg [--dest /tmp/t.txt] [--language ru] [--engine auto|elevenlabs|groq]
    tg-read send me --text "test"            # or --file /abs/message.txt
    tg-read wait "Гапоненко" --after 223868  # [--hours 6] [--every 15] [--settle 20]

- `chats`, `read`, `voice` and `photo` are read-only: they never send, mark read or delete.
- `send` posts exactly the given text as Egor, once, plain text (no Markdown), and prints
  `sent #<id> to <name> at <time>`. Before sending, `ё`/`Ё` become `е`/`Е` and em/en dashes a plain
  `-` (Egor cannot type those); `normalized: yo=<n> dashes=<n>` is printed when anything changed.
  It refuses (exit 2) an empty text, more than 4000 chars, or a channel. Nothing edits or deletes.
- `send` also writes as Egor does (claude-setup `hooks/lib/owner_text.py` `as_egor`): an opening
  greeting goes when the chat already talked today (a person: any message, a group: his own), and the
  person's name used as an address (`Славо, …` / `…, Слава!`) and the message's final period (not an
  ellipsis or `т.д.`) always; `dropped: …` says what went, a
  text that was only a greeting is refused (exit 2). `--as-written` keeps both, only when his own words
  for that message carry them.
- `wait` runs as a background Bash right after `send` (which prints its line), so the answer wakes the
  chat: exit 0 with the answer printed (a person: any message; a group: a reply to that message or a
  mention of Egor), exit 1 after --hours.
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
