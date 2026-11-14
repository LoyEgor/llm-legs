"""Read Egor's own Telegram chats through the official API (Telethon).

Credentials: ~/.config/telegram/api.txt (line 1 api_id, line 2 api_hash, mode 600) — written by
the chat from my.telegram.org, never printed. Session: ~/.config/telegram/session.session, created
by `tg-read login`, where Egor himself types the phone, the code and the 2FA password: no agent
types a code, ever.

    tg-read login                              interactive, once
    tg-read login --qr                         scan a QR code from the phone instead of a code
    tg-read chats [--limit N]                  dialogs: id, unread, name
    tg-read read <chat> [--limit N] [--since YYYY-MM-DD] [--json]
    tg-read voice <chat> [--last N] --dest-dir <abs> [--transcribe]   download voice messages (.ogg) and video notes (.mp4)
    tg-read photo <chat> [--last N] --dest-dir <abs>                   download photos as .jpg
    tg-read file <chat> [--last N] [--name S] --dest-dir <abs>          download sent files under their own names
    tg-read transcribe <abs audio> [--dest <abs .txt>] [--language ru] [--engine auto|elevenlabs|groq]
    tg-read send <chat> (--text <text> | --file <abs>) [--as-written]   post ONE plain-text message as Egor
    tg-read edit <chat> <msg id> (--text <text> | --file <abs>) [--as-written]   replace the text of ONE own message
    tg-read delete <chat> <msg id> --yes                       delete ONE own message for both sides
    tg-read wait <chat> --after <msg id> [--hours N | --until HH:MM]   print answers as they come (a background Bash)

<chat> is a dialog name (substring, case-insensitive), a @username, a numeric id or `me` (Saved
Messages). Output is plain text, one message per line; a voice or media message prints a tag instead
of text. chats/read/voice are read-only: they never send, mark read or delete. `send` posts exactly
the given text (yo -> ye, em/en dash -> hyphen), once, never to a channel; `edit` and `delete` act on one own message by id
(delete only on Egor's explicit word; an edit notifies nobody, the other side sees an "edited" mark). Egor greets a person once a day and rarely uses names: `send` drops an opening greeting when
the chat (a group: his own messages) already talked today and the person's name used as an address,
printing what went; --as-written keeps both, only when his own words for the message carry them.

Transcription (auto): ElevenLabs through `media-run transcribe`, then Groq Whisper when ElevenLabs is
out of usage/credits. Groq keys: transcriptions-gpt/settings/groq_keys.txt, never printed.

`wait` is how an answer reaches a chat without Egor asking: run in the background right after `send`,
it exits when the other side writes after that message (a person: any message; a group: a reply to it
or a mention of Egor), printing what came, and the exit wakes the chat. It holds one connection on an
in-memory copy of the session (no lock on the session file), polls every 15 s and prints once the chat
has been quiet 20 s. It ends with the chat that started it, or at the span Egor named (--hours/--until; a
re-arm keeps it): claude-setup hooks/lib/chat_watch.py.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("TG_READ_CONFIG", Path.home() / ".config/telegram"))
API_FILE = CONFIG_DIR / "api.txt"
SESSION = CONFIG_DIR / "session"
LOGIN_NEEDED = CONFIG_DIR / "login-needed"  # the menubar's Telegram "login needed" row, until a login or a good run
GROQ_KEYS = Path("/Volumes/Work/Projects/transcriptions-gpt/settings/groq_keys.txt")
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
MAX_SEND = 4000
MAX_CAPTION = 1024  # Telegram's limit for the text under photos
MAX_PHOTOS = 10  # one album
FALL_BACK = re.compile(r"USAGE_LIMIT|credits|quota|\b402\b|\b429\b", re.IGNORECASE)


def credentials() -> tuple[int, str]:
    try:
        lines = API_FILE.read_text().split()
    except OSError:
        sys.exit(f"tg-read: no credentials at {API_FILE} (api_id on line 1, api_hash on line 2)")
    if len(lines) < 2 or not lines[0].isdigit():
        sys.exit(f"tg-read: {API_FILE} must hold api_id on line 1 and api_hash on line 2")
    return int(lines[0]), lines[1]


def client(session=None, **options):
    from telethon import TelegramClient

    api_id, api_hash = credentials()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    # A stable, honest device identity: Telegram keeps sessions of a named app on the owner's own
    # api keys; borrowed Telegram Desktop keys got the session revoked within half an hour (2026-10-22).
    return TelegramClient(
        session or str(SESSION), api_id, api_hash,
        device_model="tg-read on Egor's Mac", system_version="macOS", app_version="1.0", **options,
    )


async def ensure_authorized(tg) -> None:
    await tg.connect()
    if not await tg.is_user_authorized():
        LOGIN_NEEDED.touch()
        sys.exit("tg-read: not logged in; run `tg-read login` in your own terminal")
    LOGIN_NEEDED.unlink(missing_ok=True)


async def resolve(tg, chat: str):
    if chat == "me":
        return await tg.get_me()
    if chat.lstrip("-").isdigit():
        return await tg.get_entity(int(chat))
    if chat.startswith("@"):
        return await tg.get_entity(chat)
    needle = chat.casefold()
    matches = []
    async for dialog in tg.iter_dialogs():
        if needle in (dialog.name or "").casefold():
            matches.append(dialog)
    if not matches:
        sys.exit(f"tg-read: no dialog matching {chat!r}; `tg-read chats` lists them")
    if len(matches) > 1:
        # Never guess a person: a name that fits several dialogs is refused, use the id or @username.
        names = "; ".join(f"{d.id} {d.name}" for d in matches[:6])
        sys.exit(f"tg-read: {chat!r} matches {len(matches)} dialogs ({names}); name one by id or @username")
    return matches[0].entity


def sender_name(message) -> str:
    sender = message.sender
    if sender is None:
        return "?"
    parts = [getattr(sender, "first_name", None), getattr(sender, "last_name", None)]
    name = " ".join(p for p in parts if p) or getattr(sender, "title", None) or getattr(sender, "username", None)
    return name or str(message.sender_id)


def media_tag(message) -> str:
    call = getattr(message, "action", None)
    if type(call).__name__ == "MessageActionPhoneCall":  # a call is a service message: no text, no media
        return f"[call {max(1, round(call.duration / 60))} min]" if call.duration else "[missed call]"
    if not message.media:
        return ""
    if message.voice:
        return f"[voice {int(message.voice.attributes[0].duration)}s]"
    if message.video_note:
        return "[video note]"
    if message.photo:
        return "[photo]"
    if message.document:
        name = next((a.file_name for a in message.document.attributes if hasattr(a, "file_name")), "")
        return f"[file {name}]".strip()
    if message.sticker:
        return "[sticker]"
    return "[media]"


def local_time(dt: datetime) -> str:
    return dt.astimezone().strftime("%Y-%m-%d %H:%M")


async def cmd_login(args) -> int:
    from getpass import getpass

    from telethon.errors import SessionPasswordNeededError

    tg = client()
    await tg.connect()
    if await tg.is_user_authorized():
        me = await tg.get_me()
        print(f"already logged in as {me.first_name or ''} (id {me.id})")
        await tg.disconnect()
        return 0
    if args.qr:
        return await qr_login(tg)
    phone = args.phone or input("Phone with the country code (+380...): ").strip()
    from telethon.errors import SendCodeUnavailableError

    sent = await tg.send_code_request(phone)
    how = type(sent.type).__name__.replace("SentCodeType", "")
    if args.sms:
        try:
            sent = await tg.send_code_request(phone)  # a second request asks for the next channel (SMS or call)
            how = type(sent.type).__name__.replace("SentCodeType", "")
        except SendCodeUnavailableError:
            print(f"Telegram offers no other channel for this number; the code already went via {how}")
    print(f"code sent via {how}: App = the 'Telegram' service chat on every signed-in device, Sms = a text, Call = a phone call")
    if args.code_file:
        # Unattended login: the code is read from a file the chat writes after reading it off the
        # Telegram app's screen; the file is removed once consumed.
        import time

        code_file = Path(args.code_file)
        print(f"waiting up to {args.wait}s for the code in {code_file}", flush=True)
        deadline = time.time() + args.wait
        while not code_file.exists() and time.time() < deadline:
            time.sleep(2)
        if not code_file.exists():
            await tg.disconnect()
            sys.exit("tg-read: no code arrived in time")
        code = code_file.read_text().strip()
        code_file.unlink()
    else:
        code = input("Code: ").strip()
    try:
        await tg.sign_in(phone, code=code)
    except SessionPasswordNeededError:
        await tg.sign_in(password=getpass("Two-step verification password: "))
    me = await tg.get_me()
    os.chmod(SESSION.with_suffix(".session"), 0o600)
    print(f"logged in as {me.first_name or ''} (id {me.id}); session kept at {SESSION}.session")
    await tg.disconnect()
    return 0


async def qr_login(tg) -> int:
    """Log in by scanning a QR code from the phone (Telegram > Settings > Devices > Link Desktop Device).
    No code and no password are typed unless the account has two-step verification."""
    import asyncio
    import subprocess
    import tempfile

    import qrcode
    from telethon.errors import SessionPasswordNeededError

    from datetime import datetime, timezone

    qr = await tg.qr_login()
    folder = Path(tempfile.mkdtemp())
    n = 0
    while True:
        n += 1
        png = folder / f"tg-read-qr-{n}.png"  # a new file each time: Preview does not reload a rewritten one
        qrcode.make(qr.url).save(png)
        subprocess.run(["open", str(png)], check=False)
        ttl = max(5, int((qr.expires - datetime.now(timezone.utc)).total_seconds()) - 2)
        print(f"scan QR #{n} within {ttl}s (Telegram on the phone: Settings > Devices > Link Desktop Device)", flush=True)
        try:
            await qr.wait(timeout=ttl)
            break
        except asyncio.TimeoutError:
            await qr.recreate()
            png.unlink(missing_ok=True)
            print("QR expired, a fresh one is open", flush=True)
        except SessionPasswordNeededError:
            from getpass import getpass

            await tg.sign_in(password=getpass("Two-step verification password: "))
            break
    png.unlink(missing_ok=True)
    folder.rmdir()
    me = await tg.get_me()
    os.chmod(SESSION.with_suffix(".session"), 0o600)
    print(f"logged in as {me.first_name or ''} (id {me.id}); session kept at {SESSION}.session")
    await tg.disconnect()
    return 0


async def cmd_chats(args) -> int:
    tg = client()
    await ensure_authorized(tg)
    async for dialog in tg.iter_dialogs(limit=args.limit):
        print(f"{dialog.id}\t{dialog.unread_count}\t{dialog.name}")
    await tg.disconnect()
    return 0


async def cmd_read(args) -> int:
    tg = client()
    await ensure_authorized(tg)
    entity = await resolve(tg, args.chat)
    since = None
    if args.since:
        since = datetime.strptime(args.since, "%Y-%m-%d").astimezone()
    rows = []
    async for message in tg.iter_messages(entity, limit=args.limit):
        if since and message.date.astimezone() < since:
            break
        text = message.text or ""
        tag = media_tag(message)
        rows.append({
            "id": message.id,
            "time": local_time(message.date),
            "from": sender_name(message),
            "text": text,
            "media": tag,
        })
    rows.reverse()
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
    else:
        for row in rows:
            body = " ".join(part for part in (row["media"], row["text"].replace("\n", " ⏎ ")) if part)
            print(f"{row['time']}  {row['from']}:  {body}  #{row['id']}")
    await tg.disconnect()
    return 0


async def cmd_voice(args) -> int:
    tg = client()
    await ensure_authorized(tg)
    entity = await resolve(tg, args.chat)
    dest_dir = Path(args.dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    found = 0
    async for message in tg.iter_messages(entity, limit=args.scan):
        if not (message.voice or message.video_note):
            continue
        stamp = message.date.astimezone().strftime("%Y%m%d-%H%M")
        kind, suffix = ("voice", ".ogg") if message.voice else ("videonote", ".mp4")
        dest = dest_dir / f"{kind}-{stamp}-{message.id}{suffix}"
        if not dest.exists():
            await message.download_media(file=str(dest))
        duration = int(message.file.duration or 0)
        line = f"{dest}\t{duration}s\t{sender_name(message)}\t{local_time(message.date)}"
        if args.transcribe:
            code, text_dest, engine = transcribe(dest, dest.with_suffix(".txt"), "ru", "auto")
            line += f"\t{text_dest}" if code == 0 else "\ttranscript failed"
        print(line, flush=True)
        found += 1
        if found >= args.last:
            break
    if not found:
        print("no voice or video notes in the last", args.scan, "messages", file=sys.stderr)
        await tg.disconnect()
        return 1
    await tg.disconnect()
    return 0


def document_name(message) -> str | None:
    """A sent file's own name (a document that is not a voice, a video note or a sticker), else None."""
    if not message.document or message.voice or message.video_note or message.sticker:
        return None
    return next((a.file_name for a in message.document.attributes if getattr(a, "file_name", None)),
                f"file-{message.id}")


async def cmd_file(args) -> int:
    tg = client()
    await ensure_authorized(tg)
    entity = await resolve(tg, args.chat)
    dest_dir = Path(args.dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    found = 0
    async for message in tg.iter_messages(entity, limit=args.scan):
        name = document_name(message)
        if name is None or (args.name and args.name.lower() not in name.lower()):
            continue
        dest = dest_dir / f"{message.id}-{Path(name).name}"
        if not dest.exists():
            await message.download_media(file=str(dest))
        caption = (message.text or "").replace("\n", " ")
        print(f"{dest}\t{sender_name(message)}\t{local_time(message.date)}\t{caption}", flush=True)
        found += 1
        if found >= args.last:
            break
    if not found:
        print("no files in the last", args.scan, "messages", file=sys.stderr)
        await tg.disconnect()
        return 1
    await tg.disconnect()
    return 0


async def cmd_photo(args) -> int:
    tg = client()
    await ensure_authorized(tg)
    entity = await resolve(tg, args.chat)
    dest_dir = Path(args.dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    found = 0
    async for message in tg.iter_messages(entity, limit=args.scan):
        if not message.photo:
            continue
        stamp = message.date.astimezone().strftime("%Y%m%d-%H%M")
        dest = dest_dir / f"photo-{stamp}-{message.id}.jpg"
        if not dest.exists():
            await message.download_media(file=str(dest))
        caption = (message.text or "").replace("\n", " ")
        print(f"{dest}\t{sender_name(message)}\t{local_time(message.date)}\t{caption}", flush=True)
        found += 1
        if found >= args.last:
            break
    if not found:
        print("no photos in the last", args.scan, "messages", file=sys.stderr)
        await tg.disconnect()
        return 1
    await tg.disconnect()
    return 0


def should_fall_back(exit_code: int, output: str) -> bool:
    """ElevenLabs failed for lack of usage/credits (exit 3 or a limit word in its output): try Groq."""
    return exit_code != 0 and (exit_code == 3 or bool(FALL_BACK.search(output or "")))


def groq_keys() -> list[str]:
    try:
        lines = GROQ_KEYS.read_text().splitlines()
    except OSError:
        return []
    return [line.strip() for line in lines if line.strip() and not line.strip().startswith("#")]


def groq_transcribe(audio: Path, language: str) -> str:
    boundary = uuid.uuid4().hex
    fields = {"model": "whisper-large-v3", "language": language, "response_format": "text"}
    body = b"".join(
        f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields.items()
    )
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{audio.name}"\r\n'
             f"Content-Type: application/octet-stream\r\n\r\n").encode() + audio.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    keys = groq_keys()
    if not keys:
        raise RuntimeError(f"no Groq key in {GROQ_KEYS.name}")
    last = ""
    for key in keys:
        request = urllib.request.Request(GROQ_URL, data=body, method="POST", headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "tg-read",
        })
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return response.read().decode("utf-8").strip() + "\n"
        except urllib.error.HTTPError as error:
            last = f"HTTP {error.code}: {error.read().decode('utf-8', 'replace')[:300]}"
            if error.code not in (401, 429):
                break
    raise RuntimeError(f"groq failed: {last}")


def transcribe(audio: Path, dest: Path, language: str, engine: str) -> tuple[int, Path, str]:
    """Write the transcript of `audio` to `dest`; returns (exit code, dest, engine used)."""
    if engine in ("auto", "elevenlabs"):
        run = subprocess.run(
            ["media-run", "transcribe", "--vendor", "elevenlabs", "--", "--in", str(audio), "--dest", str(dest),
             "--language", language, "--no-events"],
            env={**os.environ, "IMAGE_LEG_CLI_OK": "1"}, capture_output=True, text=True,
        )
        if run.returncode == 0:
            return 0, dest, "elevenlabs"
        output = (run.stdout or "") + (run.stderr or "")
        if engine == "elevenlabs" or not should_fall_back(run.returncode, output):
            sys.stderr.write(output)
            print(f"tg-read: elevenlabs transcription failed (exit {run.returncode})", file=sys.stderr)
            return 1, dest, "elevenlabs"
    try:
        text = groq_transcribe(audio, language)
    except (RuntimeError, OSError) as error:
        print(f"tg-read: {error}", file=sys.stderr)
        return 1, dest, "groq"
    dest.write_text(text)
    return 0, dest, "groq"


async def cmd_transcribe(args) -> int:
    audio = Path(args.audio)
    if not audio.is_file():
        sys.exit(f"tg-read: no audio file at {audio}")
    dest = Path(args.dest) if args.dest else Path(f"{audio}.txt")
    code, dest, engine = transcribe(audio, dest, args.language, args.engine)
    if code == 0:
        print(f"transcript={dest} engine={engine} chars={len(dest.read_text())}")
    return code


def watch():
    """The shared chat_watch module (claude-setup hooks/lib): when an answer watch ends."""
    sys.path.insert(0, os.path.expanduser("~/.claude/hooks/lib"))
    import chat_watch

    return chat_watch


def owner():
    """The shared owner_text module (claude-setup hooks/lib): how a text sent as Egor must look."""
    sys.path.insert(0, os.path.expanduser("~/.claude/hooks/lib"))
    import owner_text

    return owner_text


def normalize(text: str) -> tuple[str, int, int]:
    """Egor cannot type yo or long dashes: the shared owner_text normalizer maps them. Returns (text, yo, dashes)."""
    return owner().owner_text(text)


async def as_egor(tg, entity, text: str) -> tuple[str, list[str]]:
    """No greeting when the chat already talked today (a person: any message, a group: his own), no
    person's name as an address (the name as Telegram gives it). Returns (text, what was dropped)."""
    person = hasattr(entity, "first_name")
    last = await tg.get_messages(entity, limit=1, from_user=None if person else "me")
    talked = bool(last) and last[0].date.astimezone().date() == datetime.now().astimezone().date()
    return owner().as_egor(text, talked, [entity.first_name] if person else [])


def send_text(args) -> str:
    text = Path(args.file).read_text() if args.file else args.text
    if not text.strip():
        print("tg-read: refusing to send an empty text", file=sys.stderr)
        sys.exit(2)
    photo, doc = getattr(args, "photo", []), getattr(args, "doc", None)
    limit = MAX_CAPTION if photo or doc else MAX_SEND
    if len(text) > limit:
        print(f"tg-read: refusing to send {len(text)} chars (over {limit})", file=sys.stderr)
        sys.exit(2)
    for one in photo:
        if not Path(one).is_absolute() or not Path(one).is_file():
            print(f"tg-read: no photo file at {one!r} (give an absolute path)", file=sys.stderr)
            sys.exit(2)
    if doc and (photo or not Path(doc).is_absolute() or not Path(doc).is_file()):
        print(f"tg-read: --doc takes one existing file by absolute path, without --photo (got {doc!r})", file=sys.stderr)
        sys.exit(2)
    if len(photo) > MAX_PHOTOS:
        print(f"tg-read: refusing {len(photo)} photos (one album holds {MAX_PHOTOS})", file=sys.stderr)
        sys.exit(2)
    return text


async def cmd_send(args) -> int:
    text, yo, dashes = normalize(send_text(args))
    if yo or dashes:
        print(f"normalized: yo={yo} dashes={dashes}")
    tg = client()
    await ensure_authorized(tg)
    entity = await resolve(tg, args.chat)
    if getattr(entity, "broadcast", False):
        await tg.disconnect()
        print(f"tg-read: {args.chat!r} is a channel; refusing to post", file=sys.stderr)
        return 2
    if not args.as_written and not getattr(entity, "is_self", False):
        text, dropped = await as_egor(tg, entity, text)
        if not text.strip():
            await tg.disconnect()
            print(f"tg-read: nothing left to send after dropping the {', '.join(dropped)}", file=sys.stderr)
            return 2
        if dropped:
            print(f"dropped: {', '.join(dropped)}")
    if args.photo:
        # The photos as one album with the text under it, as Egor posts pictures himself.
        sent = await tg.send_file(entity, args.photo if len(args.photo) > 1 else args.photo[0], caption=text,
                                  parse_mode=None)
        message = sent[-1] if isinstance(sent, list) else sent
        print(f"photos: {len(args.photo)}")
    elif args.doc:
        # A file as a file (a certificate, an archive): saved on the phone as it is, the text under it.
        message = await tg.send_file(entity, args.doc, caption=text, parse_mode=None, force_document=True)
        print(f"document: {Path(args.doc).name}")
    else:
        message = await tg.send_message(entity, text, parse_mode=None, link_preview=False)
    name = "Saved Messages" if args.chat == "me" else chat_name(entity)
    print(f"sent #{message.id} to {name} at {local_time(message.date)}")
    if not getattr(entity, "is_self", False):
        from telethon.utils import get_peer_id  # marked id (-100… for a group), so `wait` resolves it as one

        print(f"answer watch: run `tg-read wait {get_peer_id(entity)} --after {message.id}` {watch().SEND_HINT}")
    await tg.disconnect()
    return 0


def rpc_error():
    """Telegram's refusal class (edit window passed, ...); a test env without telethon gets one nothing raises."""
    try:
        from telethon.errors import RPCError
    except ImportError:
        return type("RPCError", (Exception,), {})
    return RPCError


async def own_message(tg, args, verb: str):
    """(entity, message) for Egor's own message #id in a non-channel chat, or an exit-2 reason."""
    entity = await resolve(tg, args.chat)
    if getattr(entity, "broadcast", False):
        return entity, f"{args.chat!r} is a channel; refusing to {verb}"
    message = await tg.get_messages(entity, ids=args.id)
    if message is None:
        return entity, f"no message #{args.id} in {chat_name(entity)}"
    if not message.out:
        return entity, f"#{args.id} in {chat_name(entity)} is not Egor's own message; refusing to {verb}"
    return entity, message


async def cmd_edit(args) -> int:
    text, yo, dashes = normalize(send_text(args))
    if yo or dashes:
        print(f"normalized: yo={yo} dashes={dashes}")
    tg = client()
    await ensure_authorized(tg)
    try:
        entity, message = await own_message(tg, args, "edit")
        if isinstance(message, str):
            print(f"tg-read: {message}", file=sys.stderr)
            return 2
        if not args.as_written and not getattr(entity, "is_self", False):
            text, dropped = await as_egor(tg, entity, text)
            if dropped:
                print(f"dropped: {', '.join(dropped)}")
        if not text.strip():
            print("tg-read: refusing an empty text", file=sys.stderr)
            return 2
        if text == (message.message or ""):
            print(f"tg-read: #{args.id} already says that; nothing to change", file=sys.stderr)
            return 2
        try:
            edited = await tg.edit_message(entity, message, text, parse_mode=None, link_preview=False)
        except rpc_error() as error:
            print(f"tg-read: Telegram refused the edit: {error}", file=sys.stderr)
            return 1
        name = "Saved Messages" if args.chat == "me" else chat_name(entity)
        print(f"edited #{args.id} in {name} at {local_time(edited.edit_date or edited.date)}")
        return 0
    finally:
        await tg.disconnect()


async def cmd_delete(args) -> int:
    tg = client()
    await ensure_authorized(tg)
    try:
        entity, message = await own_message(tg, args, "delete")
        if isinstance(message, str):
            print(f"tg-read: {message}", file=sys.stderr)
            return 2
        if not args.yes:
            print(f"#{args.id}: {(message.message or media_tag(message))[:80]}")
            print("add --yes to delete", file=sys.stderr)
            return 2
        try:
            await tg.delete_messages(entity, [args.id], revoke=True)
        except rpc_error() as error:
            print(f"tg-read: Telegram refused the delete: {error}", file=sys.stderr)
            return 1
        name = "Saved Messages" if args.chat == "me" else chat_name(entity)
        print(f"deleted #{args.id} in {name}")
        return 0
    finally:
        await tg.disconnect()


def answers(message, after: int, person: bool) -> bool:
    """An incoming message that answers Egor's #after: from a person anything, in a group a reply or a mention."""
    if message.out:
        return False
    if person:
        return True
    reply_to = getattr(message.reply_to, "reply_to_msg_id", None)
    return reply_to == after or bool(message.mentioned)


def memory_session():
    """An in-memory copy of the login: a long `wait` holds no lock on the sqlite session other commands use."""
    from telethon.sessions import SQLiteSession, StringSession

    disk = SQLiteSession(str(SESSION))
    try:
        return StringSession(StringSession.save(disk))
    finally:
        disk.close()


def chat_name(entity) -> str:
    return getattr(entity, "title", None) or " ".join(
        p for p in (getattr(entity, "first_name", None), getattr(entity, "last_name", None)) if p) or str(entity.id)


async def poll_after(tg, peer, after: int) -> list:
    """Every message after #after, oldest first; reconnects a dropped connection."""
    if not tg.is_connected():
        await tg.connect()
    rows = [m async for m in tg.iter_messages(peer, min_id=after, reverse=True)]
    for message in rows:
        await message.get_sender()
    return rows


async def cmd_wait(args) -> int:
    rules = watch()
    try:
        end = rules.deadline(args.until, args.hours)
    except ValueError:
        print(f"tg-read wait: --until takes HH:MM or YYYY-MM-DDTHH:MM, got {args.until!r}", file=sys.stderr)
        return 2
    chat_pid = rules.owning_chat()
    from telethon.tl.types import User

    disk = client()
    await ensure_authorized(disk)
    try:
        entity = await resolve(disk, args.chat)
        peer = await disk.get_input_entity(entity)  # carries the access hash the memory session lacks
    finally:
        await disk.disconnect()
    from telethon.utils import get_peer_id

    person, name, peer_id = isinstance(entity, User), chat_name(entity), get_peer_id(entity)
    tg = client(memory_session(), receive_updates=False)
    await ensure_authorized(tg)
    failures = 0
    try:
        while rules.alive(chat_pid):
            try:
                rows = await poll_after(tg, peer, args.after)
                failures = 0
            except Exception as error:  # a network blip or a flood wait must not end the watch
                failures += 1
                if failures >= 10:
                    print(f"tg-read wait: gave up after {failures} failed polls: {error}", file=sys.stderr)
                    return 1
                rows = []
            # A person: the whole exchange since #after, his own replies from the phone too; a group: only answers.
            shown = rows if person else [m for m in rows if answers(m, args.after, person)]
            if any(answers(m, args.after, person) for m in rows):
                # People answer in bursts: print once the chat has been quiet for --settle seconds (3 min at most).
                quiet_by = time.monotonic() + 180
                while time.monotonic() < quiet_by:
                    await asyncio.sleep(args.settle)
                    with contextlib.suppress(Exception):
                        latest = await poll_after(tg, peer, args.after)
                        latest = latest if person else [m for m in latest if answers(m, args.after, person)]
                        if latest[-1].id == shown[-1].id:
                            break
                        shown = latest
                print(f"answer in {name} after #{args.after}:")
                for message in shown:
                    body = " ".join(part for part in (media_tag(message),
                                                      (message.text or "").replace("\n", " ⏎ ")) if part)
                    print(f"{local_time(message.date)}  {sender_name(message)}:  {body}  #{message.id}")
                span = args.until is not None or args.hours is not None
                print(rules.answer_line(f"tg-read wait {peer_id} --after {shown[-1].id}", name, end, span))
                return 0
            if rules.over(end):
                print(rules.ended_line(name, end))
                return 0
            await asyncio.sleep(args.every)
        return 0  # the chat that started the watch is closed: nobody to tell
    finally:
        await tg.disconnect()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="tg-read", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    login = sub.add_parser("login", help="log in once, interactively (phone, code, 2FA typed by Egor)")
    login.add_argument("--phone", help="+380... (asked when omitted)")
    login.add_argument("--qr", action="store_true", help="log in by scanning a QR code from the phone; no code typed")
    login.add_argument("--sms", action="store_true", help="ask Telegram for the next delivery channel (SMS or call) right away")
    login.add_argument("--code-file", help="unattended: read the code from this file once it appears")
    login.add_argument("--wait", type=int, default=180, help="seconds to wait for --code-file")
    chats = sub.add_parser("chats", help="list dialogs")
    chats.add_argument("--limit", type=int, default=40)
    read = sub.add_parser("read", help="print a chat's recent messages, oldest first")
    read.add_argument("chat")
    read.add_argument("--limit", type=int, default=50)
    read.add_argument("--since", help="YYYY-MM-DD, local time")
    read.add_argument("--json", action="store_true")
    voice = sub.add_parser("voice", help="download the last voice messages and video notes of a chat")
    voice.add_argument("chat")
    voice.add_argument("--last", type=int, default=1)
    voice.add_argument("--scan", type=int, default=200, help="how many recent messages to look through")
    voice.add_argument("--dest-dir", required=True)
    voice.add_argument("--transcribe", action="store_true", help="transcribe each download (engine auto) next to it")
    photo = sub.add_parser("photo", help="download the last photos of a chat as .jpg")
    photo.add_argument("chat")
    photo.add_argument("--last", type=int, default=1)
    photo.add_argument("--scan", type=int, default=200, help="how many recent messages to look through")
    photo.add_argument("--dest-dir", required=True)
    file_ = sub.add_parser("file", help="download the last sent files (documents) of a chat under their own names")
    file_.add_argument("chat")
    file_.add_argument("--last", type=int, default=1)
    file_.add_argument("--name", default="", help="only files whose name holds this (case-insensitive)")
    file_.add_argument("--scan", type=int, default=200, help="how many recent messages to look through")
    file_.add_argument("--dest-dir", required=True)
    transcribe_ = sub.add_parser("transcribe", help="audio file to text: ElevenLabs, then Groq Whisper")
    transcribe_.add_argument("audio")
    transcribe_.add_argument("--dest", help="the .txt to write (default: <audio>.txt)")
    transcribe_.add_argument("--language", default="ru")
    transcribe_.add_argument("--engine", choices=("auto", "elevenlabs", "groq"), default="auto")
    send = sub.add_parser("send", help="post ONE plain-text message (optionally under photos) to a chat as Egor")
    send.add_argument("chat")
    body = send.add_mutually_exclusive_group(required=True)
    body.add_argument("--text")
    body.add_argument("--file", help="absolute path of a text file to post")
    send.add_argument("--photo", action="append", default=[],
                      help="absolute path of a picture to post with the text as its caption; repeat for an album")
    send.add_argument("--doc", help="absolute path of one file to post as a document, the text as its caption")
    send.add_argument("--as-written", action="store_true",
                      help="keep an opening greeting and the addressee's name: only when Egor's own words carry them")
    edit = sub.add_parser("edit", help="replace the text of ONE of Egor's own messages, by id")
    edit.add_argument("chat")
    edit.add_argument("id", type=int)
    body = edit.add_mutually_exclusive_group(required=True)
    body.add_argument("--text")
    body.add_argument("--file", help="absolute path of a text file with the new text")
    edit.add_argument("--as-written", action="store_true",
                      help="keep an opening greeting and the addressee's name: only when Egor's own words carry them")
    delete = sub.add_parser("delete", help="delete ONE of Egor's own messages for both sides, by id")
    delete.add_argument("chat")
    delete.add_argument("id", type=int)
    delete.add_argument("--yes", action="store_true", help="really delete (only on Egor's explicit word)")
    wait = sub.add_parser("wait", help="block until the chat answers Egor's message; run as a background Bash")
    wait.add_argument("chat")
    wait.add_argument("--after", type=int, required=True, help="id of Egor's message (`send` prints it)")
    wait.add_argument("--hours", type=float, help="follow answers this long (default: while this chat lives)")
    wait.add_argument("--until", help="follow answers until HH:MM or YYYY-MM-DDTHH:MM (a re-arm carries it)")
    wait.add_argument("--every", type=float, default=15.0, help="seconds between polls")
    wait.add_argument("--settle", type=float, default=20.0, help="seconds of quiet after an answer before printing")
    args = parser.parse_args(argv)
    if args.command in ("send", "edit"):
        send_text(args)  # refuse an empty or oversized text before connecting
    handler = {"login": cmd_login, "chats": cmd_chats, "read": cmd_read, "voice": cmd_voice, "photo": cmd_photo,
               "file": cmd_file, "transcribe": cmd_transcribe, "send": cmd_send, "edit": cmd_edit,
               "delete": cmd_delete, "wait": cmd_wait}[args.command]
    code = asyncio.run(handler(args))
    if args.command == "login" and code == 0:
        LOGIN_NEEDED.unlink(missing_ok=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
