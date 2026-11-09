# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93", "scipy==1.18.1"]
# ///
"""ck-key: background removal with CorridorKey 2.0, local and free, the picture's own pixels kept.

usage: ck-key --in <abs image> [--in <abs image>]... --out <abs dir> [--shadow grey|colour|gpt] [--gpt-rgba <abs png>]
       ck-key --in <abs clip .mp4/.mov | frames dir> --out <abs dir> [--edge hard] [--glass ck|screen]
              [--glass-min A] [--despill off|glass|all] [--frames A-B] [--reuse]

Fits a subject on a flat or smooth backdrop: a studio sweep, a green/blue screen, a white, grey or plain wall
(people and hair, cars, glass, fur, products, sprites). It keeps CorridorKey's alpha and colour as they are (Egor
picked them over every repaint), so nothing of the subject is redrawn. A busy photo background is not its job: take
the GPT cut-out (media skill, background removal).

Stills: our MLX build (≈3 s a 1080p still, 15 s 4K, plus ≈4 s start), several images per call share the start.
  An image of a size never seen builds its graph once (≈1.5 min small to 5 min 4K): Bash timeout 600000.
  One image: <out>/alpha.png (16-bit grey), fg.png (8-bit straight colour), rgba.png (8-bit, ready to use);
  several: <out>/<name>/ each. On a green/blue screen the screen's colour is taken out of fg everywhere.
  --shadow adds <out>/shadow.png, a multiply layer (white = no effect) to put under the subject
  (CSS mix-blend-mode: multiply; in an editor a Multiply layer below the cut-out):
    grey    the shadow measured from the frame, neutral; the default choice
    colour  the same with the colour the scene put into it (a car's coloured bounce, light through glass); only
            when the shadow's colour matters, and never over a dark page (it cannot lighten)
    gpt     the shadow GPT drew, from --gpt-rgba (a GPT cut-out asked to keep the shadow, laid on this input's
            frame); an alternative when the frame's own reads poorly, e.g. on dark backdrops
One line per image: ck=done screen=green|blue|red|none alpha=<path> fg=<path> rgba=<path> [shadow=<path>]
  graph=<HxW> s=<seconds> wait_s=<seconds> (screen=none: a neutral backdrop, CK still keyed it).
Clips and frame folders run on the original CorridorKey 2.0: on the Windows PC's RTX 3090 when it answers (`machines`
wakes it; 143 frames 1080p: ≈3 min with the transfer against ≈14 on this Mac), else this Mac's corridorkey-desktop
engine (Core ML, ≈2.8 s a 1080p frame plus ≈37 s load); CK_ENGINE=mac|pc forces one. Our MLX build is not yet measured
on video. Per frame <out>/rgba/N.png and <out>/shadow/N.png (grey multiply layer), made on this Mac either way; a car
from AI video on green: --edge hard --glass screen --despill all.
One CorridorKey run at a time on each machine: a second call waits (wait_s). Exit 0 done, 1 failed, 2 usage.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import ck_shadow  # noqa: E402

CK_HOME = Path(os.environ.get("CK_HOME", Path.home() / ".local/share/corridorkey"))
BENCH = Path(os.environ.get("CK_BUILD", "/Volumes/Work/tmp/corridorkey"))  # the clip engine and the graph exporter
VIDEO = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"}
ENGINE = Path(__file__).resolve().with_name("ck_mlx.py")


def fail(msg, code=1):
    print(f"ck-key: {msg}", file=sys.stderr)
    sys.exit(code)


class Lock:
    """CK_HOME/heavy.lock, held for the engine only; the wait is reported"""

    def __enter__(self):
        CK_HOME.mkdir(parents=True, exist_ok=True)
        self.f = open(CK_HOME / "heavy.lock", "w")
        t = time.perf_counter()
        try:
            fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("ck-key: another CorridorKey run holds the engine, waiting", file=sys.stderr, flush=True)
            fcntl.flock(self.f, fcntl.LOCK_EX)
        self.wait = round(time.perf_counter() - t, 1)
        return self

    def __exit__(self, *exc):
        self.f.close()


def names(paths):
    """each path's stem, prefixed with as many parent dirs as it takes to tell it from the others"""
    parts = {p: p.with_suffix("").parts for p in paths}
    if len(set(parts.values())) != len(parts):
        fail("the same image twice", 2)
    out = {}
    for p, v in parts.items():
        k = next(k for k in range(1, len(v) + 1) if all(o[-k:] != v[-k:] for q, o in parts.items() if q != p))
        out[p] = "-".join(v[-k:])
    return out


def load_rgb(p):
    """the input as the caller's tools see it: EXIF-transposed, RGB float32 0..1 and its 8-bit bytes"""
    with Image.open(p) as im:
        rgb = ImageOps.exif_transpose(im).convert("RGB")
    a = np.asarray(rgb)
    return a, a.astype(np.float32) / 255


def stills(a):
    t0 = time.perf_counter()
    py = CK_HOME / "venv/bin/python"
    if not py.exists():
        fail(f"no engine at {CK_HOME} (CK_HOME): its venv, ck2mlx and graphs are installed there")
    ins = [Path(p) for p in a.inputs]
    if a.gpt_rgba and len(ins) != 1:
        fail("--gpt-rgba goes with one --in", 2)
    if a.shadow == "gpt" and not a.gpt_rgba:
        fail("--shadow gpt needs --gpt-rgba <the GPT cut-out that kept the shadow, laid on this input>", 2)
    out = Path(a.out)
    nm = names(ins)
    dirs = {p: out if len(ins) == 1 else out / nm[p] for p in ins}
    with tempfile.TemporaryDirectory(prefix="ck-key-") as tmp:
        job, frames = [], {}
        for p in ins:
            try:
                b8, I = load_rgb(p)
            except OSError as e:
                fail(f"cannot read {p}: {e}")
            frames[p] = I
            src = Path(tmp) / f"{len(job)}.png"
            Image.fromarray(b8).save(src, compress_level=1)
            job.append({"in": str(src), "out": str(dirs[p])})
        (Path(tmp) / "job.json").write_text(json.dumps(job))
        with Lock() as lk:
            r = subprocess.run([str(py), "-I", str(ENGINE), "run", str(Path(tmp) / "job.json")],
                               stdout=subprocess.PIPE, text=True, env={**os.environ, "CK_HOME": str(CK_HOME)})
        if r.returncode != 0:
            fail(f"the engine failed (exit {r.returncode}); its stderr is above")
        res = json.loads(r.stdout.strip().splitlines()[-1])
    for p, row in zip(ins, res["images"]):
        d, I = dirs[p], frames[p]
        A = np.asarray(Image.open(d / "alpha.png"), np.float32) / 65535
        F = np.asarray(Image.open(d / "fg.png").convert("RGB"), np.float32) / 255
        plate = ck_shadow.Plate(I)
        scr = ck_shadow.screen(I, plate)
        if scr is not None:
            F = ck_shadow.despill(I, A, F, plate)
            Image.fromarray((np.clip(F, 0, 1) * 255 + 0.5).astype(np.uint8)).save(d / "fg.png")
        a8 = (A * 255 + 0.5).astype(np.uint8)
        Image.fromarray(np.dstack([(np.clip(F, 0, 1) * 255 + 0.5).astype(np.uint8), a8]), "RGBA").save(d / "rgba.png")
        line = f"ck=done screen={scr or 'none'} alpha={d / 'alpha.png'} fg={d / 'fg.png'} rgba={d / 'rgba.png'}"
        if a.shadow:
            if a.shadow == "colour":
                M = ck_shadow.colour(I, A, F, plate)
            else:
                M = ck_shadow.grey(I, A, F, plate)
                if a.shadow == "gpt":
                    with Image.open(a.gpt_rgba) as g:
                        g = np.asarray(g.convert("RGBA"), np.float32) / 255
                    if g.shape[:2] != A.shape:
                        fail(f"--gpt-rgba is {g.shape[1]}x{g.shape[0]}, the input {A.shape[1]}x{A.shape[0]}: lay it on "
                             "the input first (codex-image --remove-bg --composite)", 2)
                    M = ck_shadow.gpt_shadow(g, A, M)
            ck_shadow.save_layer(M, d / "shadow.png")
            line += f" shadow={d / 'shadow.png'}"
        print(f"{line} graph={row['used']} s={time.perf_counter() - t0:.1f} wait_s={lk.wait}", flush=True)
    return 0


def clip(a):
    py, tool = BENCH / "venv/bin/python", BENCH / "scripts/ck_key.py"
    if not (py.exists() and tool.exists()):
        fail(f"no clip engine at {BENCH} (CK_BUILD)")
    if a.shadow or a.gpt_rgba:
        fail("--shadow/--gpt-rgba are for stills; a clip gets <out>/shadow/N.png (grey) anyway", 2)
    cmd = [str(py), "-I", str(tool), a.inputs[0], "--out", a.out]
    for k in ("glass", "glass_min", "despill", "edge", "frames"):
        v = getattr(a, k)
        if v is not None:
            cmd += ["--" + k.replace("_", "-"), str(v)]
    if a.reuse:
        cmd.append("--reuse")
    return subprocess.run(cmd, env={**os.environ, "CK_LOCK": str(CK_HOME / "heavy.lock")}).returncode


def main():
    if {"-h", "--help"} & set(sys.argv[1:]):
        print(__doc__.strip())
        return 0
    usage = __doc__.split("usage: ", 1)[1].split("\n\n", 1)[0]
    ap = argparse.ArgumentParser(prog="ck-key", usage=usage, add_help=False)
    ap.add_argument("--in", dest="inputs", action="append", required=True, metavar="ABS")
    ap.add_argument("--out", required=True, metavar="ABS_DIR")
    ap.add_argument("--shadow", choices=("grey", "colour", "gpt"))
    ap.add_argument("--gpt-rgba", metavar="ABS_PNG")
    ap.add_argument("--glass", choices=("ck", "screen")); ap.add_argument("--glass-min", type=float)
    ap.add_argument("--despill", choices=("off", "glass", "all")); ap.add_argument("--edge", choices=("soft", "hard"))
    ap.add_argument("--frames", metavar="A-B"); ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args()
    for p in a.inputs + [a.out] + ([a.gpt_rgba] if a.gpt_rgba else []):
        if not os.path.isabs(p):
            fail(f"{p}: paths are absolute", 2)
    for p in a.inputs:
        if not os.path.exists(p):
            fail(f"no such input {p}", 2)
    vid = [p for p in a.inputs if os.path.isdir(p) or Path(p).suffix.lower() in VIDEO]
    if vid:
        if len(a.inputs) != 1:
            fail("a clip or frames folder goes alone, one per call", 2)
        return clip(a)
    if any(getattr(a, k) is not None for k in ("glass", "glass_min", "despill", "edge", "frames")) or a.reuse:
        fail("--glass/--glass-min/--despill/--edge/--frames/--reuse are for clips", 2)
    return stills(a)


if __name__ == "__main__":
    sys.exit(main())
