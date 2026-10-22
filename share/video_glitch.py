# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Generation glitches in video: the labelled clip set, Egor's labelling page and the judges' flags
(docs/video-glitch.md).

    add <video>... --set known-bad|control|pool [--project P] [--prompt-file F] [--id ID] [--note N]
                                     register clips (copied under data/video-glitch/clips)
    flags <clip> <judge> <reply.txt> import a judge's `t=` lines as flags for Egor to confirm
    label [--port N] [--no-open]     the labelling page on 127.0.0.1; every change appends to labels.jsonl
    list                             one line per clip: id, set, latest verdict, defect count
    check <video> [--model sol] [--effort E]
                                     judge one clip: `glitch=ok|defects`, then one `t=` line per defect
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import webbrowser
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SET_DIR = Path(os.environ.get("VIDEO_GLITCH_SET", ROOT / "share" / "video-glitch"))
DATA_DIR = Path(os.environ.get("VIDEO_GLITCH_DATA", ROOT / "data" / "video-glitch"))
CLIPS = SET_DIR / "clips.jsonl"
LABELS = SET_DIR / "labels.jsonl"
FLAGS = SET_DIR / "flags.jsonl"
SETS = ("known-bad", "control", "pool")
VERDICTS = ("ok", "minor", "reject")
KINDS = ("body", "object", "text", "causality", "speed", "physics", "popping", "other")
SITTING = 20  # Egor's own cap on clips a sitting (2026-10-22): the page shows only that many open questions
ACCEPTED_NOTE = "used in the R7-A film"  # a pool take that went into a finished film counts as accepted
MAX_FRAMES = 24  # 12 s at 2 fps; a longer clip is sampled sparser, so one check stays one image budget
FLAG_LINE = re.compile(
    r"^t=(?P<t0>\d+(?:\.\d+)?)(?:\s*-\s*(?P<t1>\d+(?:\.\d+)?))?\s*\|\s*(?P<object>[^|]*)\|\s*(?P<what>[^|]*)"
    r"(?:\|\s*noticeable:\s*(?P<noticeable>yes|no))?\s*(?:\|\s*confidence:\s*(?P<confidence>\w+))?",
    re.IGNORECASE)


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def latest_labels() -> dict[str, dict]:
    """The last label row per clip: every save appends, so the newest line is Egor's current answer."""
    return {row["clip"]: row for row in read_jsonl(LABELS)}


def probe(video: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate:format=duration", "-of", "json", str(video)],
        check=True, capture_output=True, text=True).stdout
    info = json.loads(out)
    stream = info["streams"][0]
    num, den = stream["r_frame_rate"].split("/")
    return {"w": stream["width"], "h": stream["height"], "fps": round(int(num) / int(den), 3),
            "dur": round(float(info["format"]["duration"]), 3)}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def default_id(video: Path) -> str:
    """Readable and stable: the two folders above the file and its stem, `.720p` dropped."""
    stem = video.name.removesuffix(".mp4").removesuffix(".720p")
    parts = [p for p in video.parent.parts[-2:] if p not in ("img", "wall", "films", "film")] + [stem]
    return re.sub(r"[^a-z0-9]+", "-", "-".join(parts).lower()).strip("-")


def find_prompt(video: Path) -> str | None:
    stem = video.name.removesuffix(".mp4").removesuffix(".720p")
    for name in (f"{stem}-prompt.txt", f"{stem}.prompt.txt", "prompt.txt"):
        candidate = video.parent / name
        if candidate.is_file():
            return candidate.read_text().strip()
    return None


def cmd_add(args: argparse.Namespace) -> int:
    known = {row["id"]: row for row in read_jsonl(CLIPS)}
    by_sha = {row["sha256"]: row["id"] for row in known.values()}
    if args.id and len(args.videos) > 1:
        sys.exit("video-glitch: --id names one video only")
    prompt_override = Path(args.prompt_file).read_text().strip() if args.prompt_file else None
    for raw in args.videos:
        video = Path(raw).expanduser().resolve()
        if not video.is_file():
            sys.exit(f"video-glitch: not a file: {video}")
        digest = sha256(video)
        if digest in by_sha:
            print(f"known {by_sha[digest]} {video}")
            continue
        clip_id = args.id or default_id(video)
        if clip_id in known:
            sys.exit(f"video-glitch: id {clip_id} is taken by {known[clip_id]['src']}; pass --id")
        copy = DATA_DIR / "clips" / f"{clip_id}.mp4"
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(video, copy)
        row = {"id": clip_id, "set": args.set, "src": str(video), "sha256": digest, **probe(video),
               "project": args.project, "prompt": prompt_override or find_prompt(video), "note": args.note,
               "added": now()}
        append_jsonl(CLIPS, {k: v for k, v in row.items() if v is not None})
        known[clip_id], by_sha[digest] = row, clip_id
        print(f"added {clip_id} {row['w']}x{row['h']} {row['dur']}s {video}")
    return 0


def cmd_flags(args: argparse.Namespace) -> int:
    clips = {row["id"] for row in read_jsonl(CLIPS)}
    if args.clip not in clips:
        sys.exit(f"video-glitch: unknown clip {args.clip}")
    text = Path(args.reply).read_text()
    count = 0
    for line in text.splitlines():
        match = FLAG_LINE.match(line.strip().strip("`"))
        if not match:
            continue
        t0 = float(match["t0"])
        flag = {"clip": args.clip, "judge": args.judge, "t0": t0, "t1": float(match["t1"] or t0),
                "object": match["object"].strip(), "what": match["what"].strip(),
                "noticeable": (match["noticeable"] or "").lower() or None,
                "confidence": (match["confidence"] or "").lower() or None}
        flag["id"] = hashlib.sha1(json.dumps(flag, sort_keys=True).encode()).hexdigest()[:10]
        append_jsonl(FLAGS, {k: v for k, v in flag.items() if v is not None})
        count += 1
    print(f"flags={count} clip={args.clip} judge={args.judge}")
    return 0


def cut_frames(video: Path, out: Path, duration: float) -> list[Path]:
    """The frames a judge reads: 2 per second (fewer past MAX_FRAMES), the longer side at most 1280 px, each
    stamped `t=<s>` top left, so a judge names times. Full size on purpose: a twisted arm is gone at 420 px."""
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("f*.jpg"):
        old.unlink()
    stamp = out / "stamp.txt"
    stamp.write_text("t=%{eif:trunc(t+0.001):d}.%{eif:mod(round(t*10),10):d}s")
    rate = min(2.0, MAX_FRAMES / max(duration, 0.1))
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(video), "-an", "-vf",
         f"setpts=PTS-STARTPTS,fps={rate:.4f},scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))',"
         f"drawtext=textfile={stamp}:x=8:y=8:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.6:boxborderw=4",
         "-q:v", "3", str(out / "f%02d.jpg")], check=True)
    return sorted(out.glob("f*.jpg"))


def cmd_check(args: argparse.Namespace) -> int:
    video = Path(args.video).expanduser().resolve()
    if not video.is_file():
        sys.exit(f"video-glitch: not a file: {video}")
    digest = sha256(video)
    work = DATA_DIR / "checks" / digest[:16]
    frames = cut_frames(video, work / "frames", probe(video)["dur"])
    # worker-run refuses a brief it has already run, so the handle carries the time: a re-check is a new run.
    brief = (SET_DIR / "judge.md").read_text().replace("__HANDLE__", f"{video.name} {digest[:8]} {now()}") \
        .replace("__N__", str(len(frames))).replace("__FRAMES__", "\n".join(f"- {f}" for f in frames))
    (work / "brief.md").write_text(brief)
    command = ["worker-run", "run", "codex", "--model", args.model, "--brief", str(work / "brief.md"),
               "--workdir", str(work)]
    if args.effort:
        command += ["--effort", args.effort]
    run = subprocess.run(command, capture_output=True, text=True)
    reply = run.stdout.split("\nRESULT:", 1)[-1]
    verdict = re.search(r"^VERDICT:\s*(ok|defects)\b", reply, re.M)
    if run.returncode != 0 or not verdict:
        tail = (run.stdout + run.stderr).strip().splitlines()[-5:]
        print("video-glitch: the judge gave no verdict:\n" + "\n".join(tail), file=sys.stderr)
        return 1
    defects = []
    for line in reply.splitlines():
        match = FLAG_LINE.match(line.strip().strip("`"))
        if match:
            defects.append({"t0": float(match["t0"]), "t1": float(match["t1"] or match["t0"]),
                            "object": match["object"].strip(), "what": match["what"].strip(),
                            "noticeable": (match["noticeable"] or "no").lower() == "yes"})
    append_jsonl(DATA_DIR / "checks.jsonl", {"at": now(), "video": str(video), "sha256": digest,
                                             "judge": f"codex {args.model} {args.effort or '-'}",
                                             "frames": len(frames), "defects": defects})
    noticeable = [d for d in defects if d["noticeable"]]
    print(f"glitch={'defects' if noticeable else 'ok'} video={video}")
    for d in defects:
        span = f"{d['t0']:g}" if d["t1"] == d["t0"] else f"{d['t0']:g}-{d['t1']:g}"
        print(f"t={span} {d['object']}: {d['what']} noticeable={'yes' if d['noticeable'] else 'no'}")
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    labels = latest_labels()
    for row in read_jsonl(CLIPS):
        label = labels.get(row["id"], {})
        print(f"{row['id']:<36} {row['set']:<9} {label.get('verdict') or '-':<6} "
              f"{len(label.get('defects', []))} {row['src']}")
    return 0


def flag_groups(flags: list[dict]) -> list[dict]:
    """One row per defect: flags of different judges whose spans overlap are the same finding, so Egor answers
    it once. Two flags of one judge never merge (one reply can name two defects at the same time)."""
    groups: list[dict] = []
    for flag in sorted(flags, key=lambda f: f["t0"]):
        group = next((g for g in groups if flag["judge"] not in g["judges"]
                      and flag["t0"] <= g["t1"] + 0.5 and g["t0"] <= flag["t1"] + 0.5), None)
        if group is None:
            group = {"ids": [], "judges": [], "t0": flag["t0"], "t1": flag["t1"],
                     "text": flag.get("ru") or f"{flag['object']}: {flag['what']}"}
            groups.append(group)
        group["ids"].append(flag["id"])
        group["judges"].append(flag["judge"])
        group["t0"], group["t1"] = min(group["t0"], flag["t0"]), max(group["t1"], flag["t1"])
    return groups


def ask_for(row: dict, groups: list[dict]) -> dict | None:
    """Egor labels about 20 clips a sitting, so a clip is asked only when his answer settles something:
    1. a judge's flag on a take he accepted (a deck film, or a take that went into a film): a false alarm,
       and the module's first rule is never to fail a good take;
    2. a known-bad take that no Sol judge flagged: a miss only if the defect shows at all;
    3. a flag on a take nobody has judged.
    A flagged known-bad take, an unflagged accepted film, and the defects only a mechanical check catches
    (speed, reversal) ask nothing."""
    if row["set"] == "known-bad":
        if row.get("mechanical") or any(j.startswith("sol") for g in groups for j in g["judges"]):
            return None
        return {"prio": 2, "type": "clip"}
    if not groups:
        return None
    accepted = row["set"] == "control" or ACCEPTED_NOTE in (row.get("note") or "")
    return {"prio": 1 if accepted else 3, "type": "flags"}


def page_state() -> dict:
    labels = latest_labels()
    flags: dict[str, dict[str, dict]] = {}
    for flag in read_jsonl(FLAGS):
        flags.setdefault(flag["clip"], {})[flag["id"]] = flag
    clips = []
    for row in read_jsonl(CLIPS):
        groups = flag_groups(list(flags.get(row["id"], {}).values()))
        clips.append({**row, "label": labels.get(row["id"]), "groups": groups, "ask": ask_for(row, groups)})
    # Sibling takes of one shot (`-2`, `-r1-3`) mostly repeat one defect: the first of a shot is asked first.
    asked: set[str] = set()
    for clip in sorted((c for c in clips if c["ask"]), key=lambda c: (c["ask"]["prio"], c["id"])):
        shot = re.sub(r"(-r\d+)?-\d+$", "", clip["id"])
        if shot in asked and clip["ask"]["prio"] == 3:
            clip["ask"]["prio"] = 4
        asked.add(shot)
    return {"clips": clips, "kinds": KINDS, "sitting": SITTING}


def clean_label(body: dict, clip_ids: set[str]) -> dict:
    """Only the fields the page owns, typed, so a stray client cannot write junk into the dataset."""
    if body.get("clip") not in clip_ids:
        raise ValueError("unknown clip")
    verdict = body.get("verdict")
    if verdict is not None and verdict not in VERDICTS:
        raise ValueError("bad verdict")
    defects = []
    for item in body.get("defects", []):
        kind = item.get("kind")
        defects.append({"t0": round(float(item["t0"]), 3),
                        "t1": round(float(item.get("t1", item["t0"])), 3),
                        "kind": kind if kind in KINDS else None,
                        "severity": item.get("severity") if item.get("severity") in ("reject", "minor") else None,
                        "words": str(item.get("words", ""))[:2000]})
    reviews = [{"id": str(item["id"]), "ok": bool(item["ok"])} for item in body.get("flags", [])
               if isinstance(item.get("ok"), bool)]
    return {"clip": body["clip"], "at": now(), "by": "egor", "verdict": verdict, "defects": defects,
            "flags": reviews, "words": str(body.get("words", ""))[:4000]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_: object) -> None:
        pass

    def send(self, status: int, body: bytes, kind: str, extra: dict | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except ConnectionError:  # the browser dropped a video range it no longer wants (clip switched)
            pass

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/index.html"):
            self.send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/api/state":
            self.send(200, json.dumps(page_state(), ensure_ascii=False).encode(), "application/json")
        elif self.path.startswith("/clip/"):
            self.send_clip(self.path.removeprefix("/clip/").removesuffix(".mp4"))
        else:
            self.send(404, b"not found", "text/plain")

    def send_clip(self, clip_id: str) -> None:
        """Byte ranges, since a browser seeks an mp4 only when the server answers them."""
        rows = {row["id"]: row for row in read_jsonl(CLIPS)}
        if clip_id not in rows:
            self.send(404, b"unknown clip", "text/plain")
            return
        copy = DATA_DIR / "clips" / f"{clip_id}.mp4"
        path = copy if copy.is_file() else Path(rows[clip_id]["src"])
        size = path.stat().st_size
        start, end = 0, size - 1
        match = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if match and (match[1] or match[2]):
            if match[1]:
                start = int(match[1])
                end = min(int(match[2]), size - 1) if match[2] else size - 1
            else:
                start = max(size - int(match[2]), 0)
        with path.open("rb") as handle:
            handle.seek(start)
            body = handle.read(end - start + 1)
        status = HTTPStatus.PARTIAL_CONTENT if match and (match[1] or match[2]) else HTTPStatus.OK
        self.send(status, body, "video/mp4",
                  {"Accept-Ranges": "bytes", "Content-Range": f"bytes {start}-{end}/{size}"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/label":
            self.send(404, b"not found", "text/plain")
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            row = clean_label(body, {row["id"] for row in read_jsonl(CLIPS)})
        except (ValueError, KeyError, TypeError) as error:
            self.send(400, str(error).encode(), "text/plain")
            return
        append_jsonl(LABELS, row)
        self.send(200, json.dumps({"saved": row["at"]}).encode(), "application/json")


def cmd_label(args: argparse.Namespace) -> int:
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError:  # the port is taken (another project's dev server): any free one will do
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"url={url} labels={LABELS}", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


PAGE = r"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Glitch labels</title>
<style>
:root{--bg:#111315;--panel:#1b1e21;--line:#2c3136;--text:#e8eaed;--dim:#8b939b;--ok:#3fb06b;--minor:#d9a628;
--bad:#e0524a;--accent:#5b9cf0}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.4 -apple-system,system-ui,sans-serif;display:flex;
height:100vh;overflow:hidden}
nav{width:250px;border-right:1px solid var(--line);overflow-y:auto;flex:none}
nav .set{padding:10px 12px 4px;color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
nav button{display:flex;gap:8px;width:100%;padding:5px 12px;border:0;background:none;color:var(--text);
text-align:left;cursor:pointer;font:inherit;font-variant-numeric:tabular-nums}
nav button.on{background:var(--panel)}
nav .g{width:14px;text-align:center}
main{flex:1;overflow-y:auto;padding:14px 18px;display:flex;flex-direction:column;gap:10px;min-width:0}
main>*{flex:none}
video{width:100%;max-height:62vh;background:#000;border-radius:6px}
.bar{position:relative;height:22px;background:var(--panel);border-radius:4px;cursor:pointer}
.bar .head{position:absolute;top:0;bottom:0;width:2px;background:var(--text)}
.bar .mk{position:absolute;top:3px;bottom:3px;min-width:4px;border-radius:2px;opacity:.85}
.row{display:flex;gap:6px;align-items:center;flex-wrap:wrap}
button.b{background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:6px 10px;
cursor:pointer;font:inherit}
button.b.on{border-color:var(--accent);background:#21324a}
.verdict button{font-size:16px;padding:8px 18px}
.verdict .ok.on{background:var(--ok);border-color:var(--ok);color:#000}
.verdict .minor.on{background:var(--minor);border-color:var(--minor);color:#000}
.verdict .reject.on{background:var(--bad);border-color:var(--bad);color:#000}
.t{font-variant-numeric:tabular-nums;color:var(--dim);min-width:56px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:8px;display:flex;
flex-direction:column;gap:6px}
input[type=text],textarea{width:100%;background:#0c0e10;color:var(--text);border:1px solid var(--line);
border-radius:6px;padding:7px;font:inherit}
textarea{min-height:64px;resize:vertical}
.chip{font-size:12px;padding:3px 8px}
.dim{color:var(--dim)}
.saved{margin-left:auto;color:var(--dim);font-size:12px}
details summary{cursor:pointer;color:var(--dim)}
.help{color:var(--dim);font-size:13px}
.ask{background:#21324a;border:1px solid var(--accent);border-radius:6px;padding:8px 12px;font-size:15px}
.ask:empty{display:none}
nav details>summary{padding:10px 12px 4px;color:var(--dim);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
nav .done{padding:6px 12px;color:var(--ok)}
</style></head><body>
<nav id="list"></nav>
<main>
  <div class="row"><b id="title"></b><span class="dim" id="meta"></span><span class="saved" id="saved"></span></div>
  <div class="ask" id="ask"></div>
  <video id="v" muted loop playsinline></video>
  <div class="bar" id="bar"><div class="head" id="head"></div></div>
  <div class="row">
    <button class="b" id="play">⏯</button><button class="b" id="back">◀ кадр</button><button class="b" id="fwd">кадр ▶</button>
    <button class="b rate" data-r="1">1×</button><button class="b rate" data-r="0.5">½×</button><button class="b rate" data-r="0.25">¼×</button>
    <span class="t" id="now"></span>
  </div>
  <div class="row verdict">
    <button class="b ok" data-v="ok">✓ чисто</button><button class="b minor" data-v="minor">~ терпимо</button>
    <button class="b reject" data-v="reject">✗ брак</button>
  </div>
  <div class="row"><button class="b" id="add">＋ глюк здесь</button>
    <span class="help">пауза на глюке → ＋ → скажи, что не так</span></div>
  <div id="defects"></div>
  <div id="flags"></div>
  <textarea id="words" placeholder="комментарий голосом"></textarea>
  <div class="row"><button class="b" id="next">следующий →</button>
    <span class="help">пробел ⏯ · ←/→ кадр · 1/2/3 оценка · G глюк · N следующий</span></div>
  <details><summary>промпт</summary><p id="prompt" class="dim"></p></details>
</main>
<script>
const KIND_RU={body:"тело",object:"объект",text:"текст",causality:"причина",speed:"скорость",physics:"физика",
popping:"появилось/исчезло",other:"другое"};
const GLYPH={ok:"✓",minor:"~",reject:"✗"}, COLOR={ok:"var(--ok)",minor:"var(--minor)",reject:"var(--bad)"};
const SET_RU={"known-bad":"известный брак",control:"контроль",pool:"остальные"};
const ASK_RU={4:"судья видит глюк — верно? (соседний дубль того же кадра)",1:"принятый фильм, а судья видит глюк — верно?",2:"брак, а Sol ничего не нашёл — что тут видно? оценка, ＋ на глюке",
3:"судья видит глюк — верно?"};
const TODAY=new Date().toLocaleDateString("sv");
let state, cur, label, timer, pendingSeek=null, allOpen=false;
const answered=c=>{const l=c.label;if(!l)return false;if(l.verdict)return true;
  return c.ask.type==="flags"&&c.groups.every(g=>g.ids.every(id=>l.flags.some(x=>x.id===id)));};
const today=()=>state.clips.filter(c=>c.ask&&answered(c)&&(c.label.at||"").slice(0,10)===TODAY).length;
const queue=()=>state.clips.filter(c=>c.ask&&!answered(c))
  .sort((a,b)=>a.ask.prio-b.ask.prio||a.id.localeCompare(b.id)).slice(0,Math.max(0,state.sitting-today()));
const $=id=>document.getElementById(id), v=$("v");
const fps=()=>cur.fps||24;
async function load(){state=await (await fetch("/api/state")).json();renderList();
  const first=queue()[0]||state.clips.find(c=>!c.label)||state.clips[0]; if(first) open(first.id);}
function clipButton(c){const b=document.createElement("button");const vd=c.label&&c.label.verdict;
  b.innerHTML=`<span class="g" style="color:${vd?COLOR[vd]:"var(--dim)"}">${vd?GLYPH[vd]:"●"}</span>${c.id}`;
  b.className=cur&&cur.id===c.id?"on":"";b.onclick=()=>open(c.id);return b;}
function renderList(){const nav=$("list");nav.innerHTML="";
  const h=document.createElement("div");h.className="set";h.textContent=`вопросы · ${today()}/${state.sitting} сегодня`;nav.append(h);
  const q=queue();q.forEach(c=>nav.append(clipButton(c)));
  if(!q.length){const d=document.createElement("div");d.className="done";d.textContent="✓ на сегодня всё";nav.append(d);}
  const all=document.createElement("details");all.open=allOpen;all.ontoggle=()=>{allOpen=all.open;};
  all.innerHTML=`<summary>все клипы · ${state.clips.length}</summary>`;nav.append(all);
  for(const set of ["known-bad","control","pool"]){const clips=state.clips.filter(c=>c.set===set);if(!clips.length)continue;
    const s=document.createElement("div");s.className="set";s.textContent=SET_RU[set];all.append(s);
    clips.forEach(c=>all.append(clipButton(c)));}}
function open(id){cur=state.clips.find(c=>c.id===id);
  label=cur.label?JSON.parse(JSON.stringify(cur.label)):{clip:id,verdict:null,defects:[],flags:[],words:""};
  $("title").textContent=id;$("meta").textContent=`${cur.w}×${cur.h} · ${cur.dur}s${cur.note?" · "+cur.note:""}`;
  $("ask").textContent=cur.ask&&!answered(cur)?ASK_RU[cur.ask.prio]:"";
  pendingSeek=cur.groups.length?Math.max(0,cur.groups[0].t0-0.5):null;
  $("prompt").textContent=cur.prompt||"—";v.src=`/clip/${id}.mp4`;v.playbackRate=1;v.play().catch(()=>{});
  $("words").value=label.words||"";$("saved").textContent=cur.label?"сохранено":"";renderList();render();}
function render(){document.querySelectorAll(".verdict button").forEach(b=>b.classList.toggle("on",b.dataset.v===label.verdict));
  document.querySelectorAll(".rate").forEach(b=>b.classList.toggle("on",+b.dataset.r===v.playbackRate));
  const box=$("defects");box.innerHTML="";
  label.defects.forEach((d,i)=>{const c=document.createElement("div");c.className="card";
    c.innerHTML=`<div class="row"><button class="b chip seek">${d.t0.toFixed(2)}s${d.t1>d.t0?"–"+d.t1.toFixed(2)+"s":""}</button>
      <button class="b chip end">⇥ до сюда</button>
      ${state.kinds.map(k=>`<button class="b chip kind ${d.kind===k?"on":""}" data-k="${k}">${KIND_RU[k]}</button>`).join("")}
      <button class="b chip sev ${d.severity==="reject"?"on":""}" data-s="reject">брак</button>
      <button class="b chip sev ${d.severity==="minor"?"on":""}" data-s="minor">терпимо</button>
      <button class="b chip del">✕</button></div><input type="text" placeholder="что не так" value="">`;
    const input=c.querySelector("input");input.value=d.words||"";input.oninput=()=>{d.words=input.value;save();};
    c.querySelector(".seek").onclick=()=>seek(d.t0);
    c.querySelector(".end").onclick=()=>{d.t1=Math.max(d.t0,v.currentTime);save();render();};
    c.querySelectorAll(".kind").forEach(b=>b.onclick=()=>{d.kind=b.dataset.k;save();render();});
    c.querySelectorAll(".sev").forEach(b=>b.onclick=()=>{d.severity=b.dataset.s;save();render();});
    c.querySelector(".del").onclick=()=>{label.defects.splice(i,1);save();render();};box.append(c);});
  const fl=$("flags");fl.innerHTML="";
  if(cur.groups.length){const h=document.createElement("div");h.className="help";h.textContent="судьи нашли — ✓ глюк · ✗ нормально";fl.append(h);}
  for(const g of cur.groups){const r=label.flags.find(x=>x.id===g.ids[0]);const c=document.createElement("div");c.className="row";
    c.innerHTML=`<button class="b chip seek">${g.t0.toFixed(1)}–${g.t1.toFixed(1)}s</button>
      <button class="b chip yes ${r&&r.ok===true?"on":""}">✓</button><button class="b chip no ${r&&r.ok===false?"on":""}">✗</button>
      <span></span>`;
    c.lastElementChild.textContent=g.text;
    c.querySelector(".seek").onclick=()=>seek(Math.max(0,g.t0-0.5));
    const set=ok=>{label.flags=label.flags.filter(x=>!g.ids.includes(x.id));g.ids.forEach(id=>label.flags.push({id,ok}));save();render();};
    c.querySelector(".yes").onclick=()=>set(true);c.querySelector(".no").onclick=()=>set(false);fl.append(c);}
  drawBar();}
function drawBar(){const bar=$("bar");bar.querySelectorAll(".mk").forEach(m=>m.remove());const dur=v.duration||cur.dur;
  const mark=(t0,t1,color)=>{const m=document.createElement("div");m.className="mk";m.style.left=(t0/dur*100)+"%";
    m.style.width=((t1-t0)/dur*100)+"%";m.style.background=color;bar.append(m);};
  cur.groups.forEach(g=>mark(g.t0,Math.max(g.t1,g.t0+0.1),"var(--accent)"));
  label.defects.forEach(d=>mark(d.t0,d.t1,d.severity==="minor"?"var(--minor)":"var(--bad)"));}
function seek(t){v.pause();v.currentTime=t;}
function save(){clearTimeout(timer);$("saved").textContent="…";timer=setTimeout(async()=>{
  const r=await fetch("/api/label",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(label)});
  if(r.ok){cur.label=JSON.parse(JSON.stringify(label));cur.label.at=TODAY;$("saved").textContent="сохранено ✓";renderList();}
  else $("saved").textContent="не сохранилось: "+await r.text();},500);}
function step(n){v.pause();v.currentTime=Math.max(0,Math.min(v.duration,v.currentTime+n/fps()));}
function next(){const q=queue().filter(c=>c.id!==cur.id);if(q.length){open(q[0].id);return;}
  const i=state.clips.findIndex(c=>c.id===cur.id);const rest=state.clips.slice(i+1).concat(state.clips.slice(0,i));
  const n=rest.find(c=>!c.label)||rest[0];if(n)open(n.id);}
function addDefect(){v.pause();const t=+v.currentTime.toFixed(3);label.defects.push({t0:t,t1:t,kind:null,severity:null,words:""});
  label.defects.sort((a,b)=>a.t0-b.t0);save();render();
  const inputs=[...document.querySelectorAll("#defects input")];const i=label.defects.findIndex(d=>d.t0===t);if(inputs[i])inputs[i].focus();}
v.ontimeupdate=()=>{$("now").textContent=v.currentTime.toFixed(2)+"s";$("head").style.left=(v.currentTime/(v.duration||1)*100)+"%";};
v.onloadedmetadata=()=>{if(pendingSeek!==null){v.currentTime=pendingSeek;pendingSeek=null;}drawBar();};
$("bar").onclick=e=>{const r=$("bar").getBoundingClientRect();seek((e.clientX-r.left)/r.width*v.duration);};
$("play").onclick=()=>v.paused?v.play().catch(()=>{}):v.pause();$("back").onclick=()=>step(-1);$("fwd").onclick=()=>step(1);
document.querySelectorAll(".rate").forEach(b=>b.onclick=()=>{v.playbackRate=+b.dataset.r;render();});
document.querySelectorAll(".verdict button").forEach(b=>b.onclick=()=>{label.verdict=b.dataset.v;save();render();});
$("add").onclick=addDefect;$("next").onclick=next;$("words").oninput=()=>{label.words=$("words").value;save();};
document.onkeydown=e=>{if(["INPUT","TEXTAREA"].includes(document.activeElement.tagName)){if(e.key==="Escape")document.activeElement.blur();return;}
  const k=e.key.toLowerCase();
  if(k===" "){e.preventDefault();v.paused?v.play().catch(()=>{}):v.pause();}else if(k==="arrowleft")step(-1);else if(k==="arrowright")step(1);
  else if(["1","2","3"].includes(k)){label.verdict=VERDICT_KEYS[k];save();render();}
  else if(k==="g"||k==="п")addDefect();else if(k==="n"||k==="т")next();};
const VERDICT_KEYS={"1":"ok","2":"minor","3":"reject"};
load();
</script></body></html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(prog="video-glitch", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    add = sub.add_parser("add")
    add.add_argument("videos", nargs="+")
    add.add_argument("--set", required=True, choices=SETS)
    add.add_argument("--project")
    add.add_argument("--prompt-file")
    add.add_argument("--id")
    add.add_argument("--note")
    flags = sub.add_parser("flags")
    flags.add_argument("clip")
    flags.add_argument("judge")
    flags.add_argument("reply")
    label = sub.add_parser("label")
    label.add_argument("--port", type=int, default=8765)
    label.add_argument("--no-open", action="store_true")
    sub.add_parser("list")
    check = sub.add_parser("check")
    check.add_argument("video")
    check.add_argument("--model", default="sol")
    check.add_argument("--effort")
    args = parser.parse_args()
    return {"add": cmd_add, "flags": cmd_flags, "label": cmd_label, "list": cmd_list,
            "check": cmd_check}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
