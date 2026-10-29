"""Read Egor's own Telegram chats through the official API (Telethon).

Credentials: ~/.config/telegram/api.txt (line 1 api_id, line 2 api_hash, mode 600) — written by
the chat from my.telegram.org, never printed. Session: ~/.config/telegram/session.session, created
by `tg-read login`, where Egor himself types the phone, the code and the 2FA password: no agent
types a code, ever.

    tg-read login                              interactive, once
    tg-read login --qr                         scan a QR code from the phone instead of a code
    tg-read chats [--limit N]                  dialogs: id, unread, name
    tg-read read <chat> [--limit N] [--since YYYY-MM-DD] [--json]
    tg-read voice <chat> [--last N] --dest-dir <abs> [--transcribe]   download voice messages as .ogg
    tg-read photo <chat> [--last N] --dest-dir <abs>                   download photos as .jpg
    tg-read transcribe <abs audio> [--dest <abs .txt>] [--language ru] [--engine auto|elevenlabs|groq]
    tg-read send <chat> (--text <text> | --file <abs>) [--as-written]   post ONE plain-text message as Egor

<chat> is a dialog name (substring, case-insensitive), a @username, a numeric id or `me` (Saved
Messages). Output is plain text, one message per line; a voice or media message prints a tag instead
of text. chats/read/voice are read-only: they never send, mark read or delete. `send` posts exactly
the given text (yo -> ye, em/en dash -> hyphen), once, never to a channel; nothing here edits or
deletes. Egor greets a person once a day and rarely uses names: `send` drops an opening greeting when
the chat (a group: his own messages) already talked today and the person's name used as an address,
printing what went; --as-written keeps both, only when his own words for the message carry them.

Transcription (auto): ElevenLabs through `media-run transcribe`, then Groq Whisper when ElevenLabs is
out of usage/credits. Groq keys: transcriptions-gpt/settings/groq_keys.txt, never printed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
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
FALL_BACK = re.compile(r"USAGE_LIMIT|credits|quota|\b402\b|\b429\b", re.IGNORECASE)


def credentials() -> tuple[int, str]:
    try:
        lines = API_FILE.read_text().split()
    except OSError:
        sys.exit(f"tg-read: no credentials at {API_FILE} (api_id on line 1, api_hash on line 2)")
    if len(lines) < 2 or not lines[0].isdigit():
        sys.exit(f"tg-read: {API_FILE} must hold api_id on line 1 and api_hash on line 2")
    return int(lines[0]), lines[1]


def client():
    from telethon import TelegramClient

    api_id, api_hash = credentials()
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    # A stable, honest device identity: Telegram keeps sessions of a named app on the owner's own
    # api keys; borrowed Telegram Desktop keys got the session revoked within half an hour (2026-10-22).
    return TelegramClient(
        str(SESSION), api_id, api_hash,
        device_model="tg-read on Egor's Mac", system_version="macOS", app_version="1.0",
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
        tag = media_tag(message) if message.media else ""
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
        if not message.voice:
            continue
        stamp = message.date.astimezone().strftime("%Y%m%d-%H%M")
        dest = dest_dir / f"voice-{stamp}-{message.id}.ogg"
        if not dest.exists():
            await message.download_media(file=str(dest))
        duration = int(message.voice.attributes[0].duration)
        line = f"{dest}\t{duration}s\t{sender_name(message)}\t{local_time(message.date)}"
        if args.transcribe:
            code, text_dest, engine = transcribe(dest, dest.with_suffix(".txt"), "ru", "auto")
            line += f"\t{text_dest}" if code == 0 else "\ttranscript failed"
        print(line, flush=True)
        found += 1
        if found >= args.last:
            break
    if not found:
        print("no voice messages in the last", args.scan, "messages", file=sys.stderr)
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
    if len(text) > MAX_SEND:
        print(f"tg-read: refusing to send {len(text)} chars (over {MAX_SEND})", file=sys.stderr)
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
    message = await tg.send_message(entity, text, parse_mode=None, link_preview=False)
    name = "Saved Messages" if args.chat == "me" else (getattr(entity, "title", None) or " ".join(
        p for p in (getattr(entity, "first_name", None), getattr(entity, "last_name", None)) if p) or str(entity.id))
    print(f"sent #{message.id} to {name} at {local_time(message.date)}")
    await tg.disconnect()
    return 0


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
    voice = sub.add_parser("voice", help="download the last voice messages of a chat")
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
    transcribe_ = sub.add_parser("transcribe", help="audio file to text: ElevenLabs, then Groq Whisper")
    transcribe_.add_argument("audio")
    transcribe_.add_argument("--dest", help="the .txt to write (default: <audio>.txt)")
    transcribe_.add_argument("--language", default="ru")
    transcribe_.add_argument("--engine", choices=("auto", "elevenlabs", "groq"), default="auto")
    send = sub.add_parser("send", help="post ONE plain-text message to a chat as Egor")
    send.add_argument("chat")
    body = send.add_mutually_exclusive_group(required=True)
    body.add_argument("--text")
    body.add_argument("--file", help="absolute path of a text file to post")
    send.add_argument("--as-written", action="store_true",
                      help="keep an opening greeting and the addressee's name: only when Egor's own words carry them")
    args = parser.parse_args(argv)
    if args.command == "send":
        send_text(args)  # refuse an empty or oversized text before connecting
    handler = {"login": cmd_login, "chats": cmd_chats, "read": cmd_read, "voice": cmd_voice, "photo": cmd_photo,
               "transcribe": cmd_transcribe, "send": cmd_send}[args.command]
    code = asyncio.run(handler(args))
    if args.command == "login" and code == 0:
        LOGIN_NEEDED.unlink(missing_ok=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
