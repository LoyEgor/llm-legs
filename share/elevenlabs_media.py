#!/usr/bin/env python3
"""ElevenLabs media legs behind media-run: one subcommand per kind, run by bin/elevenlabs-<kind>.

Keys: ~/.config/elevenlabs/keys.txt (`<key> <account> [notes]` per line). Limits and defaults:
share/image-caps/elevenlabs.json. Prose: docs/image-vendors/elevenlabs.md.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import mimetypes
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave
import zipfile
from email.parser import BytesParser
from email.policy import default as email_policy
from pathlib import Path

API = os.environ.get("ELEVENLABS_API_BASE", "https://api.elevenlabs.io")
KEYS = Path(os.environ.get("ELEVENLABS_KEYS", "~/.config/elevenlabs/keys.txt")).expanduser()
ROOT = Path(__file__).resolve().parent.parent
CAPS_PATH = Path(os.environ.get("ELEVENLABS_CAPS", ROOT / "share/image-caps/elevenlabs.json"))
LEG_LOG = Path(os.environ.get("IMAGE_LEG_LOG", "~/.cache/image-legs/legs.jsonl")).expanduser()
VOICE_ID_RE = re.compile(r"^[A-Za-z0-9]{20}$")


class Fail(Exception):
    def __init__(self, rc: int, message: str):
        super().__init__(message)
        self.rc = rc
        self.message = message


class Usage(argparse.ArgumentParser):
    def error(self, message):
        raise Fail(2, message)


def caps() -> dict:
    return json.loads(CAPS_PATH.read_text())


def accounts() -> dict[str, str]:
    if not KEYS.is_file():
        raise Fail(4, f"no key file {KEYS}: put `<key> <account>` lines there (chmod 600)")
    found = {}
    for line in KEYS.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and not parts[0].startswith("#"):
            found[parts[1]] = parts[0]
    return found


def reserves() -> dict[str, int]:
    found = {}
    for line in KEYS.read_text().splitlines():
        parts = line.split()
        match = re.search(r"\breserve=(\d+)\b", line)
        if len(parts) >= 2 and not parts[0].startswith("#") and match:
            found[parts[1]] = int(match.group(1))
    return found


def pool_for(kind: str, pinned: str | None) -> list[str]:
    known = accounts()
    if pinned:
        if pinned not in known:
            raise Fail(2, f"--account {pinned} is not in {KEYS} (have: {' '.join(known)})")
        return [pinned]
    pool = [name for name in caps()["accounts"]["pool"].get(kind) or caps()["accounts"]["pool"]["default"] if name in known]
    if not pool:
        raise Fail(4, f"no {kind} account in {KEYS}")
    return pool


# ---------------------------------------------------------------- HTTP


def multipart(fields: list[tuple[str, str]], files: list[tuple[str, Path]]) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    out = io.BytesIO()
    for name, value in fields:
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        out.write(str(value).encode() + b"\r\n")
    for name, path in files:
        ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{path.name}"\r\n'
                  f"Content-Type: {ctype}\r\n\r\n".encode())
        out.write(path.read_bytes() + b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={boundary}"


def error_of(body: bytes) -> tuple[str, str]:
    try:
        detail = json.loads(body).get("detail", body.decode(errors="replace"))
    except (ValueError, AttributeError):
        return "", body.decode(errors="replace")[:500]
    if isinstance(detail, dict):
        return str(detail.get("status") or detail.get("code") or detail.get("type") or ""), str(detail.get("message") or detail)
    if isinstance(detail, list):
        return "validation", "; ".join(f"{'.'.join(map(str, d.get('loc', [])))}: {d.get('msg')}" for d in detail if isinstance(d, dict))
    return "", str(detail)[:500]


class Client:
    def __init__(self, account: str, key: str):
        self.account = account
        self.key = key

    def call(self, method: str, path: str, *, query=None, body=None, fields=None, files=None, timeout=900):
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        headers = {"xi-api-key": self.key}
        data = None
        if body is not None:
            data, headers["Content-Type"] = json.dumps(body).encode(), "application/json"
        elif fields is not None or files:
            data, headers["Content-Type"] = multipart(fields or [], files or [])
        for attempt in range(4):
            request = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    return response.read(), {k.lower(): v for k, v in response.headers.items()}
            except urllib.error.HTTPError as error:
                status, message = error_of(error.read())
                if error.code == 429 and attempt < 3:
                    time.sleep(3 * (attempt + 1))
                    continue
                raise self.classify(error.code, status, message) from None
            except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
                # A POST that timed out may still be billed and delivered server-side; resending it pays twice.
                if method == "GET" and attempt < 2:
                    time.sleep(2)
                    continue
                raise Fail(1, f"network: {error}") from None
        raise Fail(1, "unreachable")

    def classify(self, code: int, status: str, message: str) -> Fail:
        text = f"HTTP {code} {status}: {message}".strip()
        if status in ("quota_exceeded", "insufficient_credits") or "quota" in status:
            return Fail(3, f"ELEVENLABS_USAGE_LIMIT account={self.account} ({message})")
        if status in ("missing_permissions", "invalid_api_key", "api_key_disabled", "paid_plan_required") or code in (401, 402):
            return Fail(4, f"account {self.account}: {text} — the owner fixes this key in ElevenLabs → Developers → API keys")
        if code == 429:
            return Fail(1, f"account {self.account} busy after retries: {text}")
        return Fail(1, f"account {self.account}: {text}")

    def json(self, method: str, path: str, **kwargs):
        raw, _ = self.call(method, path, **kwargs)
        return json.loads(raw)

    def balance(self) -> tuple[int, int] | None:
        try:
            sub = self.json("GET", "/v1/user/subscription", timeout=20)
            return int(sub["character_count"]), int(sub["character_limit"])
        except (Fail, KeyError, ValueError):
            return None


# ---------------------------------------------------------------- files


def probe(path: Path) -> tuple[str, str]:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_name,sample_rate,channels,width,height",
             "-of", "json", str(path)], capture_output=True, text=True, timeout=30).stdout
        info = json.loads(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return "", ""
    duration = info.get("format", {}).get("duration", "")
    parts = []
    for stream in info.get("streams", []):
        if stream.get("width"):
            parts.append(f"{stream.get('codec_name')} {stream['width']}x{stream.get('height')}")
        else:
            parts.append(f"{stream.get('codec_name')} {stream.get('sample_rate')} Hz {stream.get('channels')}ch")
    return (f"{float(duration):.2f}" if duration else ""), ", ".join(parts)


def save_audio(raw: bytes, dest: Path, fmt: str, channels: int = 1) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    want = dest.suffix.lower().lstrip(".")
    if fmt.startswith("pcm_"):
        with wave.open(str(dest if want == "wav" else dest.with_suffix(".wav")), "wb") as out:
            out.setnchannels(channels)
            out.setsampwidth(2)
            out.setframerate(int(fmt.split("_")[1]))
            out.writeframes(raw)
        if want == "wav":
            return
        raw, fmt = dest.with_suffix(".wav").read_bytes(), "wav"
        dest.with_suffix(".wav").unlink()
    got = fmt.split("_")[0]
    if got == want or (got == "opus" and want == "ogg"):
        dest.write_bytes(raw)
        return
    temp = dest.with_name(dest.stem + ".download." + got)
    temp.write_bytes(raw)
    try:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(temp), str(dest)], check=True, timeout=300)
    except (OSError, subprocess.SubprocessError) as error:
        raise Fail(1, f"ffmpeg could not turn the {got} download into {dest.name}: {error}") from None
    finally:
        temp.unlink(missing_ok=True)


def output_format(dest: Path, kind_caps: dict) -> str:
    ext = dest.suffix.lower().lstrip(".")
    formats = kind_caps.get("formats") or caps()["formats"]
    if ext not in formats:
        raise Fail(2, f"--dest must end in one of: {' '.join('.' + e for e in formats)}")
    return formats[ext]


def absolute_dest(value: str, must_exist_dir=True) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise Fail(2, f"--dest must be an absolute path, not {value}")
    if must_exist_dir and not path.parent.is_dir():
        raise Fail(2, f"--dest folder {path.parent} does not exist")
    return path


def absolute_input(value: str, what="--in") -> Path:
    path = Path(value)
    if not path.is_absolute() or not path.is_file():
        raise Fail(2, f"{what} needs an absolute path to an existing file, not {value}")
    return path


def text_arg(args) -> str:
    if getattr(args, "text_file", None):
        return Path(args.text_file).read_text().strip()
    return (args.text or "").strip()


# ---------------------------------------------------------------- run frame


class Run:
    def __init__(self, kind: str, account_pin: str | None):
        self.kind = kind
        self.pool = pool_for(kind, account_pin)
        self.client: Client | None = None
        self.cost_header = 0
        self.cost_seen = False
        self.model = ""
        self.dry = False
        self.ids: list[str] = []
        self.lines: list[str] = []

    def attempt(self, work):
        last: Fail | None = None
        floors = reserves()
        for account in self.pool:
            self.client = Client(account, accounts()[account])
            if account in floors and not self.dry:
                balance = self.client.balance()
                left = balance[1] - balance[0] if balance else None
                if left is None or left <= floors[account]:
                    last = Fail(3, f"ELEVENLABS_USAGE_LIMIT account={account} is at the key owner's floor: "
                                   f"{left if left is not None else 'unknown'} credits left, reserve {floors[account]}")
                    if account != self.pool[-1]:
                        print(f"elevenlabs-{self.kind}: {last.message}; next account", file=sys.stderr)
                    continue
            try:
                return work(self.client)
            except Fail as error:
                if error.rc != 3:
                    raise
                last = error
                print(f"elevenlabs-{self.kind}: {error.message}; next account", file=sys.stderr)
        raise last or Fail(3, "ELEVENLABS_USAGE_LIMIT")

    def cost(self, headers: dict) -> None:
        for name in ("character-cost", "x-character-count"):
            if headers.get(name, "").strip().isdigit():
                self.cost_header += int(headers[name])
                self.cost_seen = True
                return

    def media_id(self, headers: dict, *keys: str) -> None:
        for key in keys or ("song-id", "history-item-id", "request-id"):
            if headers.get(key):
                self.ids.append(f"{key}={headers[key]}")
                return

    def deliver(self, dest: Path) -> None:
        duration, streams = probe(dest)
        self.lines += [f"dest={dest}", f"size={dest.stat().st_size}", f"format={dest.suffix.lstrip('.').lower()}"]
        if duration:
            self.lines.append(f"duration={duration}")
        if streams:
            self.lines.append(f"probe={streams}")

    def finish(self) -> None:
        assert self.client is not None
        after = self.client.balance()
        if self.cost_seen:
            credits = str(self.cost_header)
        else:
            credits = "unmetered (no cost header; the balance settles about a minute later, rates in the manifest's costs)"
        tail = [f"account={self.client.account}", f"credits={credits}"]
        if after:
            tail.append(f"balance={after[0]}/{after[1]}")
        if self.model:
            tail.append(f"model={self.model}")
        tail.append("route=api")
        tail += self.ids
        print("\n".join(self.lines + tail))


def leg_log(kind: str, rc: int, started: float, account: str, model: str, err: str) -> None:
    try:
        LEG_LOG.parent.mkdir(parents=True, exist_ok=True)
        record = {"ts": int(time.time()), "tool": f"elevenlabs-{kind}", "kind": "audio", "rc": rc,
                  "seconds": int(time.time() - started), "queued": 0, "size": None, "account": account,
                  "served": model, "err": err[-2000:], "job": os.environ.get("IMAGE_JOB_ID", ""), "route": "api"}
        with LEG_LOG.open("a") as log:
            log.write(json.dumps(record) + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- voices


def voices(client: Client) -> list[dict]:
    found, token = [], None
    while True:
        query = {"page_size": 100, **({"next_page_token": token} if token else {})}
        page = client.json("GET", "/v2/voices", query=query, timeout=30)
        found += page.get("voices", [])
        token = page.get("next_page_token")
        if not page.get("has_more") or not token:
            return found


def voice_id(client: Client, wanted: str, cache: dict) -> str:
    if VOICE_ID_RE.match(wanted):
        return wanted
    if "list" not in cache:
        cache["list"] = voices(client)
    low = wanted.lower()
    for voice in cache["list"]:
        if voice["name"].lower() == low or voice["name"].lower().split(" - ")[0].strip() == low:
            return voice["voice_id"]
    for voice in cache["list"]:
        if voice["name"].lower().startswith(low):
            return voice["voice_id"]
    names = ", ".join(v["name"].split(" - ")[0] for v in cache["list"])
    raise Fail(2, f"no voice named {wanted} on account {client.account} (have: {names}); a voice id works too")


# ---------------------------------------------------------------- kinds


def k_sfx(args, run: Run) -> None:
    c = caps()["sfx"]
    dest = absolute_dest(args.dest)
    fmt = output_format(dest, c)
    lo, hi = c["duration_s"]
    if args.duration is not None and not lo <= args.duration <= hi:
        raise Fail(2, f"--duration must be {lo}-{hi} s")
    if not 1 <= args.count <= c["count_max"]:
        raise Fail(2, f"--count must be 1-{c['count_max']}")
    body = {"text": args.prompt, "model_id": c["model"], "loop": bool(args.loop)}
    if args.duration is not None:
        body["duration_seconds"] = args.duration
    if args.influence is not None:
        body["prompt_influence"] = args.influence
    run.model = c["model"]
    if args.dry_run:
        print(json.dumps({"POST": "/v1/sound-generation", "output_format": fmt, "body": body, "count": args.count}))
        return

    def work(client):
        for take in range(1, args.count + 1):
            raw, headers = client.call("POST", "/v1/sound-generation", query={"output_format": fmt}, body=body)
            target = dest if args.count == 1 else dest.with_name(f"{dest.stem}-{take}{dest.suffix}")
            save_audio(raw, target, fmt, c["pcm_channels"])
            run.cost(headers)
            run.media_id(headers, "request-id")
            run.deliver(target)
    run.attempt(work)


def k_music(args, run: Run) -> None:
    c = caps()["music"]
    dest = absolute_dest(args.dest)
    fmt = output_format(dest, c)
    model = args.model or c["model"]
    if model not in c["models"]:
        raise Fail(2, f"--model must be one of: {' '.join(c['models'])}")
    run.model = model
    if args.for_video:
        videos = [absolute_input(v, "--for-video") for v in args.for_video]
        if args.length or args.lyrics or args.instrumental or args.mode:
            raise Fail(2, "--for-video follows the videos' length; drop --length, --lyrics, --instrumental and --mode")
        fields = [("model_id", model)] + ([("description", args.prompt)] if args.prompt else [])
        fields += [("tags", tag) for tag in args.tag[:10]]
        if args.dry_run:
            print(json.dumps({"POST": "/v1/music/video-to-music", "output_format": fmt, "fields": fields,
                              "videos": [str(v) for v in videos]}))
            return

        def work(client):
            raw, headers = client.call("POST", "/v1/music/video-to-music", query={"output_format": fmt}, fields=fields,
                                       files=[("videos", v) for v in videos])
            save_audio(raw, dest, fmt, c.get("pcm_channels", 1))
            run.cost(headers)
            run.media_id(headers, "song-id", "request-id")
            run.deliver(dest)
        run.attempt(work)
        return
    if not args.prompt:
        raise Fail(2, "missing --prompt")
    lo, hi = c["length_s"]
    body = {"prompt": args.prompt, "model_id": model, "force_instrumental": bool(args.instrumental)}
    if args.length is not None:
        if not lo <= args.length <= hi:
            raise Fail(2, f"--length must be {lo}-{hi} s")
        body["music_length_ms"] = int(args.length * 1000)
    if args.lyrics:
        body["lyrics_text"] = args.lyrics
    if args.mode:
        body["generation_mode"] = args.mode
    if args.seed is not None:
        body["seed"] = args.seed
    body["with_timestamps"] = True
    if args.dry_run:
        print(json.dumps({"POST": "/v1/music/detailed", "output_format": fmt, "body": body}))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/music/detailed", query={"output_format": fmt}, body=body)
        message = BytesParser(policy=email_policy).parsebytes(
            f"Content-Type: {headers.get('content-type', '')}\r\n\r\n".encode() + raw)
        audio, meta = None, None
        for part in message.iter_parts():
            payload = part.get_payload(decode=True)
            if part.get_content_type() == "application/json":
                meta = json.loads(payload)
            elif payload:
                audio = payload
        if audio is None:
            raise Fail(1, "the music answer carried no audio part")
        save_audio(audio, dest, fmt, c.get("pcm_channels", 1))
        if meta is not None:
            Path(str(dest) + ".json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
            run.lines.append(f"plan={dest}.json")
        run.cost(headers)
        run.media_id(headers, "song-id", "request-id")
        run.deliver(dest)
    run.attempt(work)


def k_stems(args, run: Run) -> None:
    c = caps()["stems"]
    source = absolute_input(args.input)
    out_dir = Path(args.dest_dir)
    if not out_dir.is_absolute() or not out_dir.is_dir():
        raise Fail(2, "--dest-dir must be an existing absolute folder")
    variation = c["variations"]["two" if args.two else "six"]
    fmt = c["format"]
    if args.dry_run:
        print(json.dumps({"POST": "/v1/music/stem-separation", "output_format": fmt, "stem_variation_id": variation}))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/music/stem-separation", query={"output_format": fmt},
                                   fields=[("stem_variation_id", variation)], files=[("file", source)])
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            names = [n for n in archive.namelist() if not n.endswith("/")]
            for name in names:
                target = out_dir / f"{source.stem}.{Path(name).name}"
                target.write_bytes(archive.read(name))
                run.deliver(target)
        run.cost(headers)
        run.media_id(headers, "request-id")
    run.model = variation
    run.attempt(work)


def k_speech(args, run: Run) -> None:
    c = caps()["speech"]
    if args.list_voices:
        run.dry = True
        client = Client(run.pool[0], accounts()[run.pool[0]])
        for voice in voices(client):
            labels = ",".join(f"{v}" for v in (voice.get("labels") or {}).values() if v)
            print(f"{voice['name']}\t{voice['voice_id']}\t{voice.get('category', '')}\t{labels}")
        return
    if not args.dest:
        raise Fail(2, "missing --dest")
    dest = absolute_dest(args.dest)
    lines = args.line or []
    text = text_arg(args)
    if bool(lines) == bool(text):
        raise Fail(2, "give --text/--text-file for one voice or --line '<voice>: <text>' (repeated) for a dialogue")
    if lines:
        model = args.model or c["dialogue_model"]
        kind_caps = {"formats": c["dialogue_formats"]}
    else:
        model = args.model or c["model"]
        kind_caps = c
    fmt = output_format(dest, kind_caps)
    run.model = model
    settings = {}
    if args.stability is not None:
        settings["stability"] = args.stability
    if args.speed is not None:
        settings["speed"] = args.speed

    def work(client):
        cache: dict = {}
        if lines:
            inputs = []
            for line in lines:
                who, sep, said = line.partition(":")
                if not sep or not said.strip():
                    raise Fail(2, f"--line needs '<voice>: <text>', not {line!r}")
                inputs.append({"text": said.strip(), "voice_id": voice_id(client, who.strip(), cache)})
            body = {"inputs": inputs, "model_id": model}
            path = "/v1/text-to-dialogue"
            if settings.get("stability") is not None:
                body["settings"] = {"stability": settings["stability"]}
        else:
            body = {"text": text, "model_id": model}
            if settings:
                body["voice_settings"] = settings
            path = f"/v1/text-to-speech/{voice_id(client, args.voice or c['voice'], cache)}"
            if args.timestamps:
                path += "/with-timestamps"
        if args.language:
            body["language_code"] = args.language
        if args.seed is not None:
            body["seed"] = args.seed
        if args.dry_run:
            print(json.dumps({"POST": path, "output_format": fmt, "body": body}, ensure_ascii=False))
            return False
        raw, headers = client.call("POST", path, query={"output_format": fmt}, body=body)
        if args.timestamps and not lines:
            answer = json.loads(raw)
            raw = base64.b64decode(answer.pop("audio_base64"))
            Path(str(dest) + ".json").write_text(json.dumps(answer, ensure_ascii=False))
            run.lines.append(f"timestamps={dest}.json")
        save_audio(raw, dest, fmt)
        run.cost(headers)
        run.media_id(headers, "history-item-id", "request-id")
        run.deliver(dest)
        return True
    if run.attempt(work) is False:
        run.dry = True


def k_revoice(args, run: Run) -> None:
    c = caps()["revoice"]
    source = absolute_input(args.input)
    dest = absolute_dest(args.dest)
    fmt = output_format(dest, c)
    model = args.model or c["model"]
    run.model = model
    fields = [("model_id", model)] + ([("remove_background_noise", "true")] if args.denoise else [])
    if args.seed is not None:
        fields.append(("seed", str(args.seed)))

    def work(client):
        path = f"/v1/speech-to-speech/{voice_id(client, args.voice or caps()['speech']['voice'], {})}"
        if args.dry_run:
            print(json.dumps({"POST": path, "output_format": fmt, "fields": fields}))
            return False
        raw, headers = client.call("POST", path, query={"output_format": fmt}, fields=fields, files=[("audio", source)])
        save_audio(raw, dest, fmt)
        run.cost(headers)
        run.media_id(headers, "history-item-id", "request-id")
        run.deliver(dest)
        return True
    if run.attempt(work) is False:
        run.dry = True


def k_isolate(args, run: Run) -> None:
    source = absolute_input(args.input)
    dest = absolute_dest(args.dest)
    output_format(dest, caps()["isolate"])
    seconds = probe(source)[0]
    if seconds and float(seconds) < caps()["isolate"]["min_s"]:
        raise Fail(2, f"--in is {seconds} s; isolation takes at least {caps()['isolate']['min_s']} s (pad it with silence)")
    run.model = "audio-isolation"
    if args.dry_run:
        print(json.dumps({"POST": "/v1/audio-isolation", "in": str(source)}))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/audio-isolation", files=[("audio", source)])
        got = "mp3" if "mpeg" in headers.get("content-type", "mpeg") else headers.get("content-type", "").split("/")[-1]
        save_audio(raw, dest, got)
        run.cost(headers)
        run.media_id(headers, "request-id")
        run.deliver(dest)
    run.attempt(work)


def stt_fields(args, c: dict) -> list[tuple[str, str]]:
    fields = [("model_id", args.model or c["model"]), ("tag_audio_events", "false" if args.no_events else "true"),
              ("timestamps_granularity", args.granularity)]
    if args.diarize or args.speakers:
        fields.append(("diarize", "true"))
    if args.speakers:
        fields.append(("num_speakers", str(args.speakers)))
    if args.language:
        fields.append(("language_code", args.language))
    if args.no_verbatim:
        fields.append(("no_verbatim", "true"))
    fields += [("keyterms", term) for term in args.keyterm]
    if args.url:
        fields.append(("source_url", args.url))
    return fields


def k_transcribe(args, run: Run) -> None:
    c = caps()["transcribe"]
    dest = absolute_dest(args.dest)
    ext = dest.suffix.lower().lstrip(".")
    if ext not in ("json", "txt", "srt"):
        raise Fail(2, "--dest must end in .json, .txt or .srt")
    if bool(args.input) == bool(args.url):
        raise Fail(2, "give exactly one of --in <abs file> or --url <link>")
    source = absolute_input(args.input) if args.input else None
    fields = stt_fields(args, c)
    if ext == "srt":
        if ("diarize", "true") not in fields:
            fields.append(("diarize", "true"))
        fields.append(("additional_formats", json.dumps([{"format": "srt"}])))
    run.model = dict(fields)["model_id"]
    if args.dry_run:
        print(json.dumps({"POST": "/v1/speech-to-text", "fields": fields, "in": str(source) if source else None}))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/speech-to-text", fields=fields,
                                   files=[("file", source)] if source else None)
        answer = json.loads(raw)
        if ext == "json":
            dest.write_text(json.dumps(answer, ensure_ascii=False, indent=1))
        elif ext == "srt":
            extra = [f for f in answer.get("additional_formats") or [] if f and f.get("requested_format") == "srt"]
            if not extra:
                raise Fail(1, "the answer carried no srt")
            dest.write_text(extra[0]["content"])
            Path(str(dest) + ".json").write_text(json.dumps(answer, ensure_ascii=False))
        else:
            dest.write_text(speaker_text(answer))
            Path(str(dest) + ".json").write_text(json.dumps(answer, ensure_ascii=False))
        run.lines += [f"dest={dest}", f"language={answer.get('language_code', '')}",
                      f"words={sum(1 for w in answer.get('words', []) if w.get('type') == 'word')}"]
        speakers = sorted({w.get("speaker_id") for w in answer.get("words", []) if w.get("speaker_id")})
        if speakers:
            run.lines.append(f"speakers={len(speakers)}")
        run.cost(headers)
        run.media_id(headers, "request-id")
        if answer.get("transcription_id"):
            run.ids.append(f"transcription-id={answer['transcription_id']}")
    run.attempt(work)


def speaker_text(answer: dict) -> str:
    words = answer.get("words") or []
    if not any(w.get("speaker_id") for w in words):
        return answer.get("text", "").strip() + "\n"
    out, speaker, line = [], None, ""
    for word in words:
        if word.get("speaker_id") != speaker and word.get("type") == "word":
            if line.strip():
                out.append(f"{speaker}: {line.strip()}")
            speaker, line = word.get("speaker_id"), ""
        line += word.get("text", "")
    if line.strip():
        out.append(f"{speaker}: {line.strip()}")
    return "\n".join(out) + "\n"


def k_align(args, run: Run) -> None:
    source = absolute_input(args.input)
    dest = absolute_dest(args.dest)
    if dest.suffix.lower() != ".json":
        raise Fail(2, "--dest must end in .json")
    text = text_arg(args)
    if not text:
        raise Fail(2, "missing --text or --text-file")
    run.model = "forced-alignment"
    if args.dry_run:
        print(json.dumps({"POST": "/v1/forced-alignment", "in": str(source), "chars": len(text)}))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/forced-alignment", fields=[("text", text)], files=[("file", source)])
        answer = json.loads(raw)
        dest.write_text(json.dumps(answer, ensure_ascii=False, indent=1))
        words = answer.get("words") or []
        run.lines += [f"dest={dest}", f"words={len(words)}", f"loss={answer.get('loss')}"]
        if words:
            run.lines.append(f"span={words[0]['start']:.2f}-{words[-1]['end']:.2f}")
        run.cost(headers)
        run.media_id(headers, "request-id")
    run.attempt(work)


def k_dub(args, run: Run) -> None:
    c = caps()["dub"]
    dest = absolute_dest(args.dest)
    if dest.suffix.lower() not in (".mp4", ".mp3"):
        raise Fail(2, "--dest must end in .mp4 (video source) or .mp3")
    if bool(args.input) == bool(args.url):
        raise Fail(2, "give exactly one of --in <abs file> or --url <link>")
    source = absolute_input(args.input) if args.input else None
    fields = [("target_lang", args.to), ("source_lang", args.source_lang or "auto"),
              ("num_speakers", str(args.speakers or 0)), ("watermark", "true" if args.watermark else "false"),
              ("name", args.name or dest.stem)]
    if args.url:
        fields.append(("source_url", args.url))
    if args.start is not None:
        fields.append(("start_time", str(args.start)))
    if args.end is not None:
        fields.append(("end_time", str(args.end)))
    if args.drop_background:
        fields.append(("drop_background_audio", "true"))
    if args.no_clone:
        fields.append(("disable_voice_cloning", "true"))
    run.model = "dubbing"
    if args.dry_run:
        print(json.dumps({"POST": "/v1/dubbing", "fields": fields, "in": str(source) if source else None}))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/dubbing", fields=fields, files=[("file", source)] if source else None)
        job = json.loads(raw)
        dubbing = job["dubbing_id"]
        run.ids.append(f"dubbing-id={dubbing}")
        print(f"elevenlabs-dub: started {dubbing}, expected {job.get('expected_duration_sec')} s", file=sys.stderr)
        deadline = time.time() + c["timeout_s"]
        while True:
            state = client.json("GET", f"/v1/dubbing/{dubbing}", timeout=30)
            if state.get("status") == "dubbed":
                break
            if state.get("status") == "failed":
                raise Fail(1, f"dubbing {dubbing} failed: {state.get('error')}")
            if time.time() > deadline:
                raise Fail(1, f"dubbing {dubbing} still {state.get('status')} after {c['timeout_s']} s; "
                              f"fetch later: GET /v1/dubbing/{dubbing}/audio/{args.to}")
            time.sleep(c["poll_s"])
        raw, headers2 = client.call("GET", f"/v1/dubbing/{dubbing}/audio/{args.to}")
        got = "mp4" if "mp4" in headers2.get("content-type", "") else "mp3"
        save_audio(raw, dest, got)
        run.deliver(dest)
    run.attempt(work)


def k_voice(args, run: Run) -> None:
    c = caps()["voice"]
    if args.save:
        if not args.generated_id or not args.description:
            raise Fail(2, "--save needs --generated-id (from previews.json) and --description")
        if args.dry_run:
            print(json.dumps({"POST": "/v1/text-to-voice", "voice_name": args.save}))
            return

        def save(client):
            answer = client.json("POST", "/v1/text-to-voice", body={
                "voice_name": args.save, "voice_description": args.description, "generated_voice_id": args.generated_id})
            run.lines += [f"voice_id={answer['voice_id']}", f"voice_name={args.save}"]
        run.attempt(save)
        return
    if not args.description or not args.dest_dir:
        raise Fail(2, "missing --description or --dest-dir")
    out_dir = Path(args.dest_dir)
    if not out_dir.is_absolute() or not out_dir.is_dir():
        raise Fail(2, "--dest-dir must be an existing absolute folder")
    model = args.model or c["model"]
    if model not in c["models"]:
        raise Fail(2, f"--model must be one of: {' '.join(c['models'])}")
    text = text_arg(args)
    body = {"voice_description": args.description, "model_id": model}
    if text:
        lo, hi = c["text_chars"]
        if not lo <= len(text) <= hi:
            raise Fail(2, f"--text must be {lo}-{hi} characters (or leave it out for an auto text)")
        body["text"] = text
    else:
        body["auto_generate_text"] = True
    if args.seed is not None:
        body["seed"] = args.seed
    run.model = model
    if args.dry_run:
        print(json.dumps({"POST": "/v1/text-to-voice/design", "body": body}, ensure_ascii=False))
        return

    def work(client):
        raw, headers = client.call("POST", "/v1/text-to-voice/design", query={"output_format": c["format"]}, body=body)
        answer = json.loads(raw)
        listing = []
        for index, preview in enumerate(answer.get("previews") or [], 1):
            target = out_dir / f"preview-{index}.mp3"
            target.write_bytes(base64.b64decode(preview.pop("audio_base_64")))
            listing.append({"file": target.name, **preview})
            run.deliver(target)
        (out_dir / "previews.json").write_text(json.dumps({"text": answer.get("text"), "description": args.description,
                                                          "previews": listing}, ensure_ascii=False, indent=1))
        run.lines.append(f"previews={out_dir / 'previews.json'}")
        run.cost(headers)
    run.attempt(work)


# ---------------------------------------------------------------- CLI


def parser(kind: str) -> argparse.ArgumentParser:
    p = Usage(prog=f"elevenlabs-{kind}")
    p.add_argument("--account")
    p.add_argument("--dry-run", action="store_true")
    if kind == "sfx":
        p.add_argument("--dest", required=True)
        p.add_argument("--prompt", required=True)
        p.add_argument("--duration", type=float)
        p.add_argument("--loop", action="store_true")
        p.add_argument("--influence", type=float)
        p.add_argument("--count", type=int, default=1)
    elif kind == "music":
        p.add_argument("--dest", required=True)
        p.add_argument("--prompt")
        p.add_argument("--length", type=float)
        p.add_argument("--instrumental", action="store_true")
        p.add_argument("--lyrics")
        p.add_argument("--mode", choices=["track", "loop", "ambience"])
        p.add_argument("--model")
        p.add_argument("--seed", type=int)
        p.add_argument("--for-video", action="append")
        p.add_argument("--tag", action="append", default=[])
    elif kind == "stems":
        p.add_argument("--in", dest="input", required=True)
        p.add_argument("--dest-dir", required=True)
        p.add_argument("--two", action="store_true")
    elif kind == "speech":
        p.add_argument("--dest")
        p.add_argument("--text")
        p.add_argument("--text-file")
        p.add_argument("--line", action="append")
        p.add_argument("--voice")
        p.add_argument("--model")
        p.add_argument("--language")
        p.add_argument("--stability", type=float)
        p.add_argument("--speed", type=float)
        p.add_argument("--seed", type=int)
        p.add_argument("--timestamps", action="store_true")
        p.add_argument("--list-voices", action="store_true")
    elif kind == "revoice":
        p.add_argument("--in", dest="input", required=True)
        p.add_argument("--dest", required=True)
        p.add_argument("--voice")
        p.add_argument("--model")
        p.add_argument("--denoise", action="store_true")
        p.add_argument("--seed", type=int)
    elif kind == "isolate":
        p.add_argument("--in", dest="input", required=True)
        p.add_argument("--dest", required=True)
    elif kind == "transcribe":
        p.add_argument("--in", dest="input")
        p.add_argument("--url")
        p.add_argument("--dest", required=True)
        p.add_argument("--model")
        p.add_argument("--language")
        p.add_argument("--diarize", action="store_true")
        p.add_argument("--speakers", type=int)
        p.add_argument("--keyterm", action="append", default=[])
        p.add_argument("--granularity", choices=["none", "word", "character"], default="word")
        p.add_argument("--no-events", action="store_true")
        p.add_argument("--no-verbatim", action="store_true")
    elif kind == "align":
        p.add_argument("--in", dest="input", required=True)
        p.add_argument("--dest", required=True)
        p.add_argument("--text")
        p.add_argument("--text-file")
    elif kind == "dub":
        p.add_argument("--in", dest="input")
        p.add_argument("--url")
        p.add_argument("--dest", required=True)
        p.add_argument("--to", required=True)
        p.add_argument("--from", dest="source_lang")
        p.add_argument("--speakers", type=int)
        p.add_argument("--start", type=int)
        p.add_argument("--end", type=int)
        p.add_argument("--name")
        p.add_argument("--watermark", action="store_true")
        p.add_argument("--drop-background", action="store_true")
        p.add_argument("--no-clone", action="store_true")
    elif kind == "voice":
        p.add_argument("--description")
        p.add_argument("--dest-dir")
        p.add_argument("--text")
        p.add_argument("--text-file")
        p.add_argument("--model")
        p.add_argument("--seed", type=int)
        p.add_argument("--save")
        p.add_argument("--generated-id")
    return p


KINDS = {"sfx": k_sfx, "music": k_music, "stems": k_stems, "speech": k_speech, "revoice": k_revoice,
         "isolate": k_isolate, "transcribe": k_transcribe, "align": k_align, "dub": k_dub, "voice": k_voice}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in KINDS:
        print(f"usage: elevenlabs_media.py <{'|'.join(KINDS)}> [args]", file=sys.stderr)
        return 2
    kind = argv[0]
    started = time.time()
    run = None
    try:
        args = parser(kind).parse_args(argv[1:])
        run = Run(kind, args.account)
        run.dry = bool(args.dry_run)
        KINDS[kind](args, run)
        if not run.dry and run.client is not None:
            run.finish()
        rc, err = 0, ""
    except Fail as error:
        print(f"elevenlabs-{kind}: {error.message}", file=sys.stderr)
        rc, err = error.rc, error.message
    except KeyboardInterrupt:
        rc, err = 130, "interrupted"
    if run is not None and not run.dry:
        leg_log(kind, rc, started, run.client.account if run.client else "", run.model, err)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
