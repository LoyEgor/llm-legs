# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93"]
# ///
"""Enhance, restore or upscale a picture with ChatGPT web edits (free route), at any output size.

ChatGPT returns at most ~1672 px, so a picture is worked on at its OUTPUT size in overlapping tiles: the base
is resized (Lanczos) to the output size, every tile is one edit, each render is registered back onto its tile
and the tiles are cross-faded over their overlap. A tile has the shape of one of ChatGPT's own renders
(1254x1254, 1672x941, 941x1672), the one that needs the fewest tiles, so a render comes back 1:1. The tiles go out
at once over every free ChatGPT account, up to 4 per account as tabs of its one browser (chatgpt-web --each), and
a tile that failed goes straight to the next account that is done: a 2752x1536 picture is 4 tiles, 24 tiles are one
round of 6 accounts.
Modes (the 2026-10-20 enhancer test, arbostar-logo renders/upscale):
  restore  redraw nothing, bring back detail lost to blur, compression or a resize: soft video frames, small or
           smeared pictures; with --size/--scale this is the upscaler
  photo    every surface re-created as true-to-life photographic texture, objects, light and colours kept
  strong   the whole picture as the layout for a new photograph (one edit of the whole frame, --takes N of it),
           then brought to the output size by restore tiles; time of day, season and weather kept unless
           --change says otherwise
Every edit goes through `media-run image`: a pinned pack per account for the tiles, one fan-out for the strong
whole-frame takes. The work folder <dest stem>.enhance/ beside the dest keeps the base, tiles, prompts, renders and
logs/ (one per pack). Final lines:
`dest=<abs> size=<WxH> mode=<mode> tiles=<n> work=<abs dir>`, one per take.
Exit 0 delivered, 1 failed (missing renders named), 2 usage, 3 every account usage-limited.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import threading
import time
from collections import deque
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

# ChatGPT web's render sizes per aspect (2026-10): a tile of that shape comes back without resampling
SHAPES = [((1254, 1254), "1:1"), ((1672, 941), "16:9"), ((941, 1672), "9:16")]
OVERLAP = 0.2  # of the tile, per axis
SNUG = 1.02  # a side up to 2% longer than the tile is one tile, stretched
MAX_TILES = 48
TABS = 4  # tabs one ChatGPT browser takes at once (the codex manifest's web.counts)
# A pack's Chrome, each tab past its first, and the floor chat-load's memory guard keeps free
BROWSER_MB, TAB_MB, GUARD_MB = 1200, 400, 2048
ATTEMPTS = 2  # renders asked per tile; a pack its account never sent (walled, busy, signed out) costs none
ASPECTS = ["1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16"]
RESTORE = ("Clean up this photograph without redrawing it: remove compression noise, blur, motion smear and painterly "
           "smudges and restore fine natural detail where it is soft. Keep every object, edge, texture pattern, colour "
           "and the light exactly as they are.")
PHOTO = ("Enhance this photograph so it looks like a real high-resolution photo taken with a good full-frame camera: "
         "give every surface true-to-life detail, foliage with crisp individual leaves and natural bark, real material "
         "grain and pores, natural skin and fabric. Keep every object exactly where it is with the same shape, size and "
         "colour: the same framing, light and colours. Add nothing, remove nothing, move nothing.")
STRONG = ("Treat this picture as the layout for a new photograph. Produce a real photograph, as if shot on location with a "
          "professional full-frame camera, of exactly this composition: every object at the same position with the same "
          "outline, size and colour, the same light direction. Everything inside the outlines is re-created as real "
          "photographic material with true-to-life textures. Small true-to-life details a real place would have and "
          "natural light effects such as sun rays are welcome. {keep} Nothing may look painted, rendered or "
          "AI-generated. Render it like a real camera file, not a processed one: no sharpening, no HDR look, no crunchy "
          "micro-contrast or halos; soft, true-to-life lens rendering with fine natural grain.")
KEEP = "Keep the same time of day, season and weather as in the picture."
CHANGE = "Also make this change: {change}. Apart from it, keep the same time of day, season and weather as in the picture."
FOCUS = " Give the strongest treatment to {focus}; change everything else as little as possible."


def fail(code: int, message: str) -> None:
    print(f"image-enhance: {message}", file=sys.stderr)
    sys.exit(code)


def spans(length: int, tile: int, overlap: int) -> list[tuple[int, int]]:
    if length <= tile * SNUG:
        return [(0, length)]
    n = -(-(length - tile) // (tile - overlap)) + 1
    return [(s, s + tile) for s in (round(i * (length - tile) / (n - 1)) for i in range(n))]


def layout(w: int, h: int) -> tuple[list[tuple[int, int, int, int]], tuple[int, int], str]:
    """The tile boxes, the per-axis overlap and the aspect to ask for: the render shape needing the fewest tiles
    (scaled down to fit a picture smaller than it), the square on a tie."""
    best = None
    for (tw, th), aspect in SHAPES:
        s = min(1.0, w / tw, h / th)
        tw, th = round(tw * s), round(th * s)
        ov = (round(tw * OVERLAP), round(th * OVERLAP))
        b = [(x0, y0, x1, y1) for y0, y1 in spans(h, th, ov[1]) for x0, x1 in spans(w, tw, ov[0])]
        if best is None or len(b) < len(best[0]):
            best = (b, ov, aspect)
    return best


def ramp(n: int, overlap: int, first: bool, last: bool) -> np.ndarray:
    r = np.ones(n, np.float32)
    edge = (np.arange(overlap, dtype=np.float32) + 0.5) / overlap
    if not first:
        r[:overlap] = edge
    if not last:
        r[n - overlap:] = edge[::-1]
    return r


def register(tile: np.ndarray, render: np.ndarray) -> np.ndarray:
    """The render laid onto its tile's frame: a similarity fit when the edit shifted or rescaled the content,
    a plain resize when it did not or no fit holds."""
    th, tw = tile.shape[:2]
    side = max(tw, th)
    plain = cv2.resize(render, (tw, th), interpolation=cv2.INTER_LANCZOS4)
    sift = cv2.SIFT_create(3000)
    kt, dt = sift.detectAndCompute(cv2.cvtColor(tile, cv2.COLOR_RGB2GRAY), None)
    kr, dr = sift.detectAndCompute(cv2.cvtColor(plain, cv2.COLOR_RGB2GRAY), None)
    if dt is None or dr is None or len(kt) < 40 or len(kr) < 40:
        return plain
    good = [m for m, n in (p for p in cv2.BFMatcher(cv2.NORM_L2).knnMatch(dr, dt, k=2) if len(p) == 2)
            if m.distance < 0.75 * n.distance]
    if len(good) < 40:
        return plain
    src = np.float32([kr[m.queryIdx].pt for m in good])
    dst = np.float32([kt[m.trainIdx].pt for m in good])
    matrix, inliers = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=3)
    if matrix is None or inliers.sum() < 40:
        return plain
    scale = float(np.hypot(*matrix[0, :2]))
    if abs(scale - 1) > 0.15 or np.abs(matrix[:, 2]).max() > side * 0.1:
        return plain
    return cv2.warpAffine(plain, matrix, (tw, th), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)


def merge(w: int, h: int, overlap: tuple[int, int], parts: list[tuple[tuple[int, int, int, int], np.ndarray]]) -> Image.Image:
    acc = np.zeros((h, w, 3), np.float32)
    wsum = np.zeros((h, w, 1), np.float32)
    for (x0, y0, x1, y1), rgb in parts:
        weight = (ramp(y1 - y0, overlap[1], y0 == 0, y1 == h)[:, None]
                  * ramp(x1 - x0, overlap[0], x0 == 0, x1 == w)[None, :])
        acc[y0:y1, x0:x1] += rgb.astype(np.float32) * weight[..., None]
        wsum[y0:y1, x0:x1] += weight[..., None]
    return Image.fromarray((acc / np.maximum(wsum, 1e-6) + 0.5).clip(0, 255).astype(np.uint8))


def rendered(dest: Path) -> Path | None:
    """The vendor's own render of an edit (no composite), else the delivered file."""
    for p in (dest.with_name(dest.stem + ".rendered.png"), dest):
        if p.is_file():
            return p
    return None


def fanout(media_run: str, jobs: list[dict], work: Path, name: str, takes: int = 1) -> int:
    """One `media-run image` fan-out over the jobs; the jobs whose render is still missing go once more."""
    code = 0
    for attempt in (1, 2):
        todo = [j for j in jobs if rendered(Path(j["dest"])) is None]
        if not todo:
            return 0
        path = work / f"{name}-jobs{'' if attempt == 1 else '-retry'}.jsonl"
        path.write_text("".join(json.dumps(j) + "\n" for j in todo))
        cmd = [media_run, "image", "--jobs", str(path)] + (["--takes", str(takes)] if takes > 1 else []) + [
            "--", "--dest-dir", str(work / "out"), "--no-composite"]
        print(f"image-enhance: {name}: {len(todo)} edit(s), attempt {attempt}", file=sys.stderr)
        code = subprocess.run(cmd, stdout=sys.stderr).returncode
        if code == 3:
            fail(3, "every account is usage-limited (media-run exit 3)")
    return code


def held(lock: str | None) -> bool:
    if not lock or not Path(lock).is_file():
        return False
    with open(lock, "a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def chatgpt_accounts(lister: str) -> tuple[list[str], list[str]]:
    """(free, busy) ChatGPT accounts, least recently used first: signed in, in the pool, not walled; busy = its lock
    held by another job. Exits 4 with none signed in, 3 with every one walled."""
    lines = subprocess.run([lister, "accounts"], capture_output=True, text=True).stdout.strip().splitlines()
    try:
        rows = json.loads(lines[-1])["accounts"]
    except (IndexError, ValueError, KeyError, TypeError):
        rows = []
    rows = sorted((r for r in rows if r.get("login") and r.get("roster") is not False),
                  key=lambda r: r.get("last_used") or 0)
    if not rows:
        fail(4, "no ChatGPT account is signed in and in the pool (chatgpt-web accounts)")
    rows = [r for r in rows if (r.get("walled_until") or 0) <= time.time()]
    if not rows:
        fail(3, "every ChatGPT account is walled by its image limit (chatgpt-web accounts)")
    busy = [r["account"] for r in rows if held(r.get("lock"))]
    return [r["account"] for r in rows if r["account"] not in busy], busy


def room_mb() -> int | None:
    """Memory a pack may take: bin/memlogd's available reading (free, inactive, speculative pages) over the guard's
    floor; none under critical pressure."""
    if os.environ.get("IMAGE_ENHANCE_ROOM_MB"):
        return int(os.environ["IMAGE_ENHANCE_ROOM_MB"])
    level = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True)
    if level.stdout.strip().isdigit() and int(level.stdout) >= 4:
        return 0
    text = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = re.search(r"page size of (\d+)", text)
    pages = sum(int(m[1]) for m in re.finditer(r"^Pages (?:free|inactive|speculative):\s+(\d+)", text, re.M))
    return pages * int(page[1]) // 2**20 - GUARD_MB if page and pages else None


def plan(n: int, accounts: int) -> tuple[int, int]:
    """(packs at once, tabs per pack): every tile in one round over the fewest tabs per account, as many browsers as
    the free memory holds."""
    room, browsers = room_mb(), max(1, min(accounts, n))
    while True:
        tabs = min(TABS, -(-n // browsers))
        if browsers == 1 or room is None or browsers * (BROWSER_MB + (tabs - 1) * TAB_MB) <= room:
            return browsers, (1 if room is not None and room < BROWSER_MB else tabs)
        browsers -= 1


def render_tiles(media_run: str, lister: str, tiles: list[tuple[Path, Path]], prompt: str, aspect: str,
                 work: Path) -> tuple[list[Path], bool]:
    """Every (tile, out) edited with no queue behind a pass: packs of up to TABS tabs on as many free accounts as
    plan() allows, each account taking the next pack the moment its last one ends, a failed tile straight to the
    next account that is done (ATTEMPTS renders at most), an account that sent nothing replaced by an unused one.
    Returns the outs still missing and whether every account was walled."""
    free, busy = chatgpt_accounts(lister)
    wait = None if free else 900  # every account busy: their packs queue behind the other jobs
    accounts = free or busy
    browsers, tabs = plan(len(tiles), len(accounts))
    spare, pending, tries, walled = iter(accounts[browsers:]), deque(tiles), {t: 0 for t, _ in tiles}, set()
    running, cond = [0], threading.Condition()
    print(f"image-enhance: {len(tiles)} tile(s): {browsers} account(s) x {tabs} tab(s) in parallel", file=sys.stderr)

    def run_pack(account: str, pack: list[tuple[Path, Path]], seq: int) -> tuple[int, set[Path]]:
        dest = work / "out" / f"pack-{account}-{seq}.png"
        cmd = [media_run, "image", "--vendor", "codex", "--", "--account", account, "--prompt", prompt, "--aspect",
               aspect, "--no-composite", "--dest", str(dest)] + (["--lock-wait", str(wait)] if wait else [])
        cmd += ["--edit", str(pack[0][0])] if len(pack) == 1 else [a for tile, _ in pack for a in ("--each", str(tile))]
        started = time.time()
        with open(work / "logs" / f"{dest.stem}.log", "w") as log:
            code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
        landed = set()
        for k, (tile, out) in enumerate(pack, 1):
            got = dest if k == 1 else dest.with_name(f"{dest.stem}-{k}.png")
            if got.is_file():
                got.replace(out)
                landed.add(tile)
        print(f"image-enhance: {account}: {len(landed)} of {len(pack)} tile(s) in {time.time() - started:.0f} s "
              f"(exit {code})", file=sys.stderr)
        return code, landed

    def worker(account: str) -> None:
        seq = 0
        while True:
            with cond:
                while not pending and running[0]:
                    cond.wait()
                if not pending:
                    return
                pack = [pending.popleft() for _ in range(min(tabs, len(pending)))]
                running[0] += 1
            seq += 1
            code, landed = run_pack(account, pack, seq)
            with cond:
                running[0] -= 1
                gone = code in (3, 4, 5) and not landed
                for item in pack:
                    if item[0] in landed:
                        continue
                    tries[item[0]] += not gone
                    if tries[item[0]] < ATTEMPTS:
                        pending.append(item)
                if gone:
                    walled.update([account] if code == 3 else [])
                    account, seq = next(spare, None), 0
                cond.notify_all()
                if account is None:
                    return

    threads = [threading.Thread(target=worker, args=(a,)) for a in accounts[:browsers]]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    missing = [out for _, out in tiles if not out.is_file()]
    return missing, bool(missing) and walled == set(accounts)


def tiled(media_run: str, lister: str, bases: list[tuple[str, Image.Image]], size: tuple[int, int], prompt: str,
          work: Path) -> list[Image.Image]:
    """Every base at the output size, all their tiles in ONE pass (no account idles between bases), merged."""
    w, h = size
    boxes, overlap, aspect = layout(w, h)
    bigs, tiles = [], []
    for tag, base in bases:
        big = np.asarray(base.convert("RGB").resize(size, Image.Resampling.LANCZOS))
        Image.fromarray(big).save(work / f"{tag}-base.png")
        bigs.append(big)
        for i, (x0, y0, x1, y1) in enumerate(boxes):
            tile, out = work / "tiles" / f"{tag}-t{i:02d}.png", work / "out" / f"{tag}-t{i:02d}.png"
            Image.fromarray(big[y0:y1, x0:x1]).save(tile)
            out.unlink(missing_ok=True)
            tiles.append((tile, out))
    missing, walled = render_tiles(media_run, lister, tiles, prompt, aspect, work)
    if missing:
        fail(3 if walled else 1, f"{len(missing)} of {len(tiles)} tile edits failed (logs in {work / 'logs'}): "
             + " ".join(map(str, missing)))
    renders = iter(np.asarray(Image.open(out).convert("RGB")) for _, out in tiles)
    return [merge(w, h, overlap, [(b, register(big[b[1]:b[3], b[0]:b[2]], next(renders))) for b in boxes])
            for big in bigs]


def nearest_aspect(w: int, h: int) -> str:
    return min(ASPECTS, key=lambda a: abs(np.log((w / h) / (int(a.split(":")[0]) / int(a.split(":")[1])))))


def main() -> None:
    ap = argparse.ArgumentParser(prog="image-enhance")
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--mode", choices=["restore", "photo", "strong"], default="photo")
    ap.add_argument("--size")
    ap.add_argument("--scale", type=float)
    ap.add_argument("--focus")
    ap.add_argument("--change")
    ap.add_argument("--takes", type=int, default=1)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    src, dest = Path(a.src), Path(a.dest)
    if not src.is_absolute() or not dest.is_absolute():
        fail(2, "--in and --dest must be absolute paths")
    if dest.suffix.lower() != ".png":
        fail(2, "--dest must be a .png")
    if not dest.parent.is_dir():
        fail(2, f"no folder {dest.parent}")
    try:
        img = ImageOps.exif_transpose(Image.open(src)).convert("RGB")
    except (OSError, ValueError) as e:
        fail(2, f"cannot read {src}: {e}")
    if a.size and a.scale:
        fail(2, "--size and --scale exclude each other")
    if a.size:
        m = re.fullmatch(r"(\d+)x(\d+)", a.size)
        if not m:
            fail(2, f"--size wants WxH, got {a.size}")
        size = (int(m[1]), int(m[2]))
    elif a.scale:
        if not 0.25 <= a.scale <= 8:
            fail(2, "--scale wants 0.25-8")
        size = (round(img.width * a.scale), round(img.height * a.scale))
    else:
        size = img.size
    if min(size) < 64:
        fail(2, f"output {size[0]}x{size[1]} is too small")
    if not 1 <= a.takes <= 4:
        fail(2, "--takes wants 1-4")
    if a.takes > 1 and a.mode != "strong":
        fail(2, "--takes is for --mode strong (restore and photo tiles are not reimagined)")
    if a.change and a.mode != "strong":
        fail(2, "--change is for --mode strong")
    boxes, _, aspect = layout(*size)
    n = len(boxes)
    if n * a.takes > MAX_TILES:
        fail(2, f"{size[0]}x{size[1]} x {a.takes} take(s) needs {n * a.takes} tiles, over {MAX_TILES}; ask for a smaller --size")

    focus = FOCUS.format(focus=a.focus) if a.focus else ""
    tile_prompt = (RESTORE if a.mode in ("restore", "strong") else PHOTO) + (focus if a.mode == "photo" else "")
    strong = STRONG.format(keep=CHANGE.format(change=a.change.rstrip(".")) if a.change else KEEP) + focus
    if a.dry_run:
        x0, y0, x1, y1 = boxes[0]
        print(f"mode={a.mode} size={size[0]}x{size[1]} tiles={n} tile={x1 - x0}x{y1 - y0} aspect={aspect} takes={a.takes}")
        if a.mode == "strong":
            print(f"whole-frame prompt: {strong}")
        print(f"tile prompt: {tile_prompt}")
        return

    root = Path(__file__).resolve().parent.parent
    media_run = os.environ.get("IMAGE_ENHANCE_MEDIA_RUN") or str(root / "bin/media-run")
    lister = os.environ.get("IMAGE_ENHANCE_CHATGPT_WEB") or str(root / "bin/chatgpt-web")
    work = dest.with_name(dest.stem + ".enhance")
    for sub in ("tiles", "out", "logs"):
        (work / sub).mkdir(parents=True, exist_ok=True)
    (work / "prompts.txt").write_text(f"mode={a.mode}\n" + (f"whole-frame: {strong}\n" if a.mode == "strong" else "")
                                      + f"tiles: {tile_prompt}\n")
    if a.mode != "strong":
        tiled(media_run, lister, [("x", img)], size, tile_prompt, work)[0].save(dest)
        print(f"dest={dest} size={size[0]}x{size[1]} mode={a.mode} tiles={n} work={work}")
        return

    whole = work / "out" / "whole.png"
    for old in work.glob("out/whole*.png"):
        old.unlink()
    code = fanout(media_run, [{"prompt": strong, "edit": str(src), "aspect": nearest_aspect(*img.size),
                               "vendor": "codex", "dest": str(whole)}], work, "whole", a.takes)
    takes = [p for p in (whole if k == 1 else whole.with_name(f"whole-{k}.png") for k in range(1, a.takes + 1))
             if rendered(p) is not None]
    if not takes:
        fail(1, f"the whole-frame edit failed (media-run exit {code})")
    merged = tiled(media_run, lister, [(f"take{k}", Image.open(rendered(t))) for k, t in enumerate(takes, 1)], size,
                   tile_prompt, work)
    for k, picture in enumerate(merged, 1):
        out = dest if k == 1 else dest.with_name(f"{dest.stem}-{k}.png")
        picture.save(out)
        print(f"dest={out} size={size[0]}x{size[1]} mode=strong tiles={n} work={work}")
    if len(takes) < a.takes:
        print(f"image-enhance: {a.takes - len(takes)} of {a.takes} takes failed", file=sys.stderr)


if __name__ == "__main__":
    main()
