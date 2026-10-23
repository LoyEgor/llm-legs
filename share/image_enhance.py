# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93"]
# ///
"""Enhance, restore or upscale a picture with ChatGPT web edits (free route), at any output size.

ChatGPT returns at most ~1672 px, so a picture is worked on at its OUTPUT size in overlapping square tiles:
the base is resized (Lanczos) to the output size, every tile is one edit, each render is registered back onto
its tile and the tiles are cross-faded over their overlap. Modes (the 2026-10-20 enhancer test, arbostar-logo
renders/upscale):
  restore  redraw nothing, bring back detail lost to blur, compression or a resize: soft video frames, small or
           smeared pictures; with --size/--scale this is the upscaler
  photo    every surface re-created as true-to-life photographic texture, objects, light and colours kept
  strong   the whole picture as the layout for a new photograph (one edit of the whole frame, --takes N of it),
           then brought to the output size by restore tiles; time of day, season and weather kept unless
           --change says otherwise
Every edit goes through `media-run image` (one fan-out per pass, accounts in parallel). The work folder
<dest stem>.enhance/ beside the dest keeps the base, tiles, prompts and renders. Final lines:
`dest=<abs> size=<WxH> mode=<mode> tiles=<n> work=<abs dir>`, one per take.
Exit 0 delivered, 1 failed (missing renders named), 2 usage, 3 every account usage-limited.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

TILE = 1024
MAX_TILES = 48
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


def starts(length: int, tile: int, overlap: int) -> list[int]:
    if length <= tile:
        return [0]
    n = -(-(length - tile) // (tile - overlap)) + 1
    return [round(i * (length - tile) / (n - 1)) for i in range(n)]


def boxes(w: int, h: int, tile: int, overlap: int) -> list[tuple[int, int, int, int]]:
    return [(x, y, x + tile, y + tile) for y in starts(h, tile, overlap) for x in starts(w, tile, overlap)]


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
    side = tile.shape[0]
    plain = cv2.resize(render, (side, side), interpolation=cv2.INTER_LANCZOS4)
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
    return cv2.warpAffine(plain, matrix, (side, side), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)


def merge(w: int, h: int, overlap: int, parts: list[tuple[tuple[int, int, int, int], np.ndarray]]) -> Image.Image:
    acc = np.zeros((h, w, 3), np.float32)
    wsum = np.zeros((h, w, 1), np.float32)
    for (x0, y0, x1, y1), rgb in parts:
        weight = (ramp(y1 - y0, overlap, y0 == 0, y1 == h)[:, None] * ramp(x1 - x0, overlap, x0 == 0, x1 == w)[None, :])
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


def tiled(media_run: str, base: Image.Image, size: tuple[int, int], prompt: str, work: Path, tag: str) -> Image.Image:
    w, h = size
    big = np.asarray(base.convert("RGB").resize(size, Image.Resampling.LANCZOS))
    Image.fromarray(big).save(work / f"{tag}-base.png")
    side = min(TILE, w, h)
    overlap = side // 4
    jobs, parts = [], []
    for i, (x0, y0, x1, y1) in enumerate(boxes(w, h, side, overlap)):
        tile = work / "tiles" / f"{tag}-t{i:02d}.png"
        Image.fromarray(big[y0:y1, x0:x1]).save(tile)
        jobs.append({"prompt": prompt, "edit": str(tile), "aspect": "1:1", "vendor": "codex",
                     "dest": str(work / "out" / f"{tag}-t{i:02d}.png")})
        parts.append((x0, y0, x1, y1))
    code = fanout(media_run, jobs, work, tag)
    missing = [j["dest"] for j in jobs if rendered(Path(j["dest"])) is None]
    if missing:
        fail(1, f"{len(missing)} of {len(jobs)} tile edits failed (media-run exit {code}): " + " ".join(missing))
    return merge(w, h, overlap, [(b, register(big[b[1]:b[3], b[0]:b[2]],
                                              np.asarray(Image.open(rendered(Path(j["dest"]))).convert("RGB"))))
                                 for b, j in zip(parts, jobs)])


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
    side = min(TILE, *size)
    n = len(boxes(size[0], size[1], side, side // 4))
    if n > MAX_TILES:
        fail(2, f"{size[0]}x{size[1]} needs {n} tiles, over {MAX_TILES}; ask for a smaller --size")

    focus = FOCUS.format(focus=a.focus) if a.focus else ""
    tile_prompt = (RESTORE if a.mode in ("restore", "strong") else PHOTO) + (focus if a.mode == "photo" else "")
    strong = STRONG.format(keep=CHANGE.format(change=a.change.rstrip(".")) if a.change else KEEP) + focus
    if a.dry_run:
        print(f"mode={a.mode} size={size[0]}x{size[1]} tiles={n} tile={side} takes={a.takes}")
        if a.mode == "strong":
            print(f"whole-frame prompt: {strong}")
        print(f"tile prompt: {tile_prompt}")
        return

    media_run = os.environ.get("IMAGE_ENHANCE_MEDIA_RUN") or str(Path(__file__).resolve().parent.parent / "bin/media-run")
    work = dest.with_name(dest.stem + ".enhance")
    (work / "tiles").mkdir(parents=True, exist_ok=True)
    (work / "out").mkdir(exist_ok=True)
    (work / "prompts.txt").write_text(f"mode={a.mode}\n" + (f"whole-frame: {strong}\n" if a.mode == "strong" else "")
                                      + f"tiles: {tile_prompt}\n")
    if a.mode != "strong":
        tiled(media_run, img, size, tile_prompt, work, "x").save(dest)
        print(f"dest={dest} size={size[0]}x{size[1]} mode={a.mode} tiles={n} work={work}")
        return

    whole = work / "out" / "whole.png"
    code = fanout(media_run, [{"prompt": strong, "edit": str(src), "aspect": nearest_aspect(*img.size),
                               "vendor": "codex", "dest": str(whole)}], work, "whole", a.takes)
    takes = [p for p in (whole if k == 1 else whole.with_name(f"whole-{k}.png") for k in range(1, a.takes + 1))
             if rendered(p) is not None]
    if not takes:
        fail(1, f"the whole-frame edit failed (media-run exit {code})")
    for k, take in enumerate(takes, 1):
        out = dest if k == 1 else dest.with_name(f"{dest.stem}-{k}.png")
        tiled(media_run, Image.open(rendered(take)), size, tile_prompt, work, f"take{k}").save(out)
        print(f"dest={out} size={size[0]}x{size[1]} mode=strong tiles={n} work={work}")
    if len(takes) < a.takes:
        print(f"image-enhance: {a.takes - len(takes)} of {a.takes} takes failed", file=sys.stderr)


if __name__ == "__main__":
    main()
