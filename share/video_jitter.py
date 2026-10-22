# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "opencv-python-headless==5.0.0.93"]
# ///
"""The tremble and the halos Flow's "1080p Upscaled" download adds to a clip, measured and taken out
(docs/video-jitter.md).

    measure <video>... [--map <dir>]          one JSON line per video
    check <film> [--ref720 <720p>] [--steadied]   exit 0 steady, 1 trembles (stderr names the fix), 2 usage
    anchor <720p> <1080p> <out>               the raw upscale warped onto its 720p frame by frame
    reanchor <film> <720p> <out> [--sigma S]  the same for a film already cut from the upscale
    settle <anchored> <out>                   the still parts averaged 1-2-1 with their neighbours
    fix <1080p> --ref720 <720p> [--register [<jsonl>]]   the upscale replaced in place, the download kept as
                                              <stem>.raw.mp4: anchored and settled when it trembles, its halos clamped
                                              to the 720p always (kept whole when the two differ by over a frame); then
                                              registered for the door; one JSON line
    register <1080p> --ref720 <720p> [--raw <download>] [--register <jsonl>]   the same register row alone (films
                                              fetched before it)
    door <image>... [--clean] [--register <jsonl>] [--out <dir>]   one JSON line per image cut from a registered
                                              upscale: swap (the 720p's frame, or with --clean the frame cleaned at its
                                              size, written to <dir>) or edited

Units are px of a 1920-wide frame. Global: tracked corners give a similarity per frame pair; a frame's jerk is its
offset from the midpoint of its neighbours, read at the frame corners (corner_rms). Local: dense flow minus the global
motion, the same jerk per pixel, the median cell of a 6x10 grid (median_cell).
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np

# Egor's blind eye check (2026-10-19, 17 clips): nothing seen up to a global 0.065, seen from about 0.095.
GATE_GLOBAL = 0.08
# Real motion and soft moving shadows raise the local number on the 720p too, so only the rise over it counts.
GATE_LOCAL_RISE = 0.1
MEASURE_W = 960
FLOW_W = 640


class Refused(Exception):
    pass


# cv2.VideoCapture's fast YUV->RGB is biased (R -1.7, G -1.3, B -1.4 of 255 on the turning2 entrance) and each
# decode-encode generation adds it again: Egor saw "the colours merged" (2026-10-19). ffmpeg with accurate rounding and
# full chroma interpolation round-trips a film to 0.1 of 255. Flow tags its files BT.601 (smpte170m); an untagged
# re-encode is read as BT.709 by players and shifts red by +2 of 255, so the encode carries its source's tags.
SWS = "accurate_rnd+full_chroma_int+full_chroma_inp"
TAGS = {"color_space": "colorspace", "color_primaries": "color_primaries", "color_transfer": "color_trc",
        "color_range": "range"}
# A fixer's film may differ from its input by this much mean colour per channel, of 255.
GATE_RGB = 1.5
# The upscale also overshoots every contrast edge: a light halo, dark pores on a flat light wall ringed white (Egor
# 2026-10-21: «как будто бы мусор»), on every take, the 720p of the same media has none. The clean holds its luma inside
# the 720p's range over CLAMP_K px widened by CLAMP_M grey levels and takes the 720p's chroma where it moved the luma
# (fully at CLAMP_MIX). arbostar-logo tools/oversharp.py clamp() and oversharp_rank/clean.py, checked by Egor's eye on
# every deck film with a 720p (2026-10-22): nothing worse, so it runs on every upscale with no detector in front.
CLAMP_K, CLAMP_M, CLAMP_MIX = 3, 4, 8
# The 720p warped onto an upscale that does not tremble: the flow's smoothing, px (reanchor's 6 smears a walking man).
ALIGN_SIGMA = 4.0


def probe(path) -> tuple[int, int, float, int]:
    run = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries",
                          "stream=width,height,r_frame_rate,nb_read_packets", "-of", "json", str(path)],
                         capture_output=True, text=True)
    streams = json.loads(run.stdout or "{}").get("streams") or [{}]
    stream = streams[0]
    if run.returncode or not stream.get("width") or not int(stream.get("nb_read_packets") or 0):
        raise Refused(f"{path} holds no readable video")
    num, den = stream["r_frame_rate"].split("/")
    return stream["width"], stream["height"], float(num) / float(den or 1), int(stream["nb_read_packets"])


def colour_filter(path) -> str:
    """The RGB->YUV filter that writes `path`'s matrix and colour tags (libx264 drops -color_trc on piped frames)."""
    run = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=" + ",".join(TAGS), "-of", "json", str(path)], capture_output=True, text=True)
    stream = (json.loads(run.stdout or "{}").get("streams") or [{}])[0]
    found = {TAGS[k]: v for k, v in stream.items() if k in TAGS and v not in ("unknown", "reserved")}
    matrix = "bt709" if found.get("colorspace") == "bt709" else "bt601"
    # a tag the source lacks stays unknown: scale would stamp bt470bg, which players read unlike the untagged source
    tags = ":".join(f"{k}={found.get(k, 'unknown')}" for k in TAGS.values())
    return f"scale=out_color_matrix={matrix}:out_range=tv:flags={SWS},format=yuv420p,setparams={tags}"


def frames(path):
    w, h, _, _ = probe(path)
    decoder = subprocess.Popen(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-vf", f"scale=flags={SWS}",
                                "-f", "rawvideo", "-pix_fmt", "bgr24", "-"], stdout=subprocess.PIPE)
    size = w * h * 3
    try:
        while True:
            buffer = decoder.stdout.read(size)
            if len(buffer) < size:
                return
            yield np.frombuffer(buffer, np.uint8).reshape(h, w, 3)
    finally:
        decoder.stdout.close()
        decoder.kill()
        decoder.wait()


def info(path) -> tuple[float, int]:
    return probe(path)[2:]


def gray(frame):
    return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)


def similarity(a, b):
    p = cv2.goodFeaturesToTrack(a, 1500, 0.005, 6)
    if p is None or len(p) < 30:
        return None
    q, st, _ = cv2.calcOpticalFlowPyrLK(a, b, p, None, winSize=(21, 21), maxLevel=3)
    r, st2, _ = cv2.calcOpticalFlowPyrLK(b, a, q, None, winSize=(21, 21), maxLevel=3)
    ok = (st[:, 0] == 1) & (st2[:, 0] == 1) & (np.linalg.norm((r - p)[:, 0], axis=1) < 0.25)
    if ok.sum() < 30:
        return None
    m, _ = cv2.estimateAffinePartial2D(p[ok], q[ok], method=cv2.RANSAC, ransacReprojThreshold=0.5)
    return m


def measure(path, mapdir=None) -> dict:
    fps, _ = info(path)
    size, small = None, []
    for frame in frames(path):
        g = gray(frame)
        size = size or f"{g.shape[1]}x{g.shape[0]}"
        small.append(cv2.resize(g, (MEASURE_W, round(g.shape[0] * MEASURE_W / g.shape[1])),
                                interpolation=cv2.INTER_AREA))
    if len(small) < 8:
        raise Refused(f"{path} is too short to measure ({len(small)} frames)")
    h, w = small[0].shape
    px = 1920 / MEASURE_W
    pts = np.array([[w / 2, h / 2], [0, 0], [w, 0], [0, h], [w, h]], np.float32)
    mats = [similarity(small[i], small[i + 1]) for i in range(len(small) - 1)]
    tracked = float(np.mean([m is not None for m in mats]))
    identity = np.float32([[1, 0, 0], [0, 1, 0]])
    mats = [m if m is not None else identity for m in mats]
    steps = np.stack([pts @ m[:, :2].T + m[:, 2] - pts for m in mats])
    jerk = np.linalg.norm(steps[:-1] - steps[1:], axis=2) / 2 * px

    def rms(a):
        return round(float(np.sqrt(np.mean(np.square(a)))), 3)

    out = {"file": str(path), "size": size, "fps": round(fps, 2), "frames": len(small), "tracked": round(tracked, 2),
           "global": {"centre_rms": rms(jerk[:, 0]), "corner_rms": rms(jerk[:, 1:]),
                      "frames_over_0.5": round(float(np.mean(jerk[:, 1:].max(1) > 0.5)), 2),
                      "pan_px_s": round(float(np.linalg.norm(steps[:, 0].mean(0))) * px * fps, 1)}}
    scale = FLOW_W / MEASURE_W
    flow_frames = [cv2.resize(f, (FLOW_W, round(f.shape[0] * scale)), interpolation=cv2.INTER_AREA) for f in small]
    lh, lw = flow_frames[0].shape
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    yy, xx = np.mgrid[0:lh, 0:lw].astype(np.float32)
    residual = []
    for i, m in enumerate(mats):
        f = dis.calc(flow_frames[i], flow_frames[i + 1], None)
        gx = m[0, 0] * xx + m[0, 1] * yy + m[0, 2] * scale - xx
        gy = m[1, 0] * xx + m[1, 1] * yy + m[1, 2] * scale - yy
        residual.append(np.dstack([f[..., 0] - gx, f[..., 1] - gy]))
    acc = np.zeros((lh, lw), np.float64)
    for i in range(len(residual) - 1):
        acc += np.sum(((residual[i] - residual[i + 1]) / 2 * (1920 / FLOW_W)) ** 2, axis=2)
    jm = np.sqrt(acc / (len(residual) - 1))
    gh, gw = 6, 10
    cells = np.array([[np.median(jm[r * lh // gh:(r + 1) * lh // gh, c * lw // gw:(c + 1) * lw // gw])
                       for c in range(gw)] for r in range(gh)])
    inner = np.zeros_like(cells, bool)
    inner[gh // 4:gh - gh // 4, gw // 4:gw - gw // 4] = True
    out["local"] = {"median_cell": round(float(np.median(cells)), 3),
                    "p90_cell": round(float(np.percentile(cells, 90)), 3),
                    "centre": round(float(np.median(cells[inner])), 3),
                    "border": round(float(np.median(cells[~inner])), 3)}
    if mapdir:
        heat = cv2.applyColorMap(np.clip(jm / 1.5 * 255, 0, 255).astype(np.uint8), cv2.COLORMAP_INFERNO)
        base = cv2.cvtColor(flow_frames[len(flow_frames) // 2], cv2.COLOR_GRAY2BGR)
        name = Path(path).parent.name + "-" + Path(path).stem
        cv2.imwrite(str(Path(mapdir) / f"{name}.jpg"), cv2.addWeighted(base, 0.4, heat, 0.6, 0))
    return out


def reading(m: dict) -> list[float]:
    return [m["global"]["corner_rms"], m["local"]["median_cell"]]


def trembles(m: dict, ref: dict | None, steadied: bool = False) -> bool | None:
    """None when it cannot be told: a stabiliser cuts exactly what the global number reads (vidstab took the oak to
    0.145 with no visible change), so a steadied film is judged by its local rise over the 720p alone."""
    g, local = reading(m)
    if ref is None:
        return None if steadied else g > GATE_GLOBAL
    rg, rl = reading(ref)
    return local - rl > GATE_LOCAL_RISE or (not steadied and g - rg > GATE_GLOBAL)


def encode(stream, dst: Path, fps: float, sound_from: Path) -> None:
    """One encode, the source's sound copied; a second lossy encode cost the fleet film half its softness."""
    part = dst.with_name(f".{dst.name}.part.mp4")
    encoder = None
    to_yuv = colour_filter(sound_from)
    try:
        for frame in stream:
            if encoder is None:
                h, w = frame.shape[:2]
                encoder = subprocess.Popen(
                    ["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}",
                     "-r", f"{fps}", "-i", "-", "-an", "-vf", to_yuv, "-c:v", "libx264", "-preset", "slow", "-crf", "18",
                     "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(part)],
                    stdin=subprocess.PIPE)
            encoder.stdin.write(frame.tobytes())
        if encoder is None:
            raise Refused("no frames to write")
        encoder.stdin.close()
        if encoder.wait() != 0:
            raise Refused(f"ffmpeg could not encode {dst}")
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(part), "-i", str(sound_from), "-map", "0:v",
                        "-map", "1:a?", "-c", "copy", "-movflags", "+faststart", str(dst)], check=True)
    finally:
        if encoder is not None and encoder.poll() is None:
            encoder.kill()
        part.unlink(missing_ok=True)


def lead(ref720: Path, upscale: Path) -> int:
    """How many frames the 720p runs ahead of its upscale (-1, 0 or 1): a pair can differ by a frame, and pairing the
    frames by index from the wrong end would hold every frame against its neighbour."""
    na, nb = info(ref720)[1], info(upscale)[1]
    if abs(na - nb) > 1:
        raise Refused(f"{ref720} has {na} frames, {upscale} {nb}: not the same media")
    if na == nb:
        return 0
    a, b = thumbs(ref720, 160, na), thumbs(upscale, 160, nb)

    def miss(ahead):
        i = np.arange(max(0, -ahead), min(len(b), len(a) - ahead))
        return float(np.mean(np.abs(a[i + ahead] - b[i])))
    return min((0, -1, 1), key=miss)


def matched(ref720: Path, ahead: int):
    """The 720p frame for each upscale frame in turn, `ahead` frames on (lead()), its first and last frames held where
    the upscale has more."""
    f = None
    for j, f in enumerate(frames(ref720)):
        if j == 0 and ahead < 0:
            yield f
        if j >= ahead:
            yield f
    while f is not None:
        yield f


def anchored(ref720: Path, upscale: Path, ahead: int | None = None):
    """Each upscaled frame warped by dense flow onto the Lanczos upscale of its 720p frame. The flow runs on frames
    blurred σ1.2 and is blurred again σ3, so it carries geometry and never texture: the picture takes the original's
    place and keeps the upscale's detail."""
    ahead = lead(ref720, upscale) if ahead is None else ahead
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    grid = None
    for fb, fa in zip(frames(upscale), matched(ref720, ahead)):
        h, w = fb.shape[:2]
        base = cv2.resize(fa, (w, h), interpolation=cv2.INTER_LANCZOS4)
        ga, gb = (gray(cv2.GaussianBlur(x, (0, 0), 1.2)) for x in (base, fb))
        flow = cv2.GaussianBlur(dis.calc(ga, gb, None), (0, 0), 3)
        if grid is None:
            grid = np.mgrid[0:h, 0:w].astype(np.float32)
        yield cv2.remap(fb, grid[1] + flow[..., 0], grid[0] + flow[..., 1], cv2.INTER_LANCZOS4,
                        borderMode=cv2.BORDER_REFLECT)


def geometry(dis, base, f, sigma: float):
    """Where each pixel of `base` sits in `f`. Raw DIS flow is noise in dark glass, shade and flat paving, so it is a
    normalized convolution weighted by the base's edge energy, falling back to the frame's median shift where no texture
    is near."""
    a, b = (gray(cv2.GaussianBlur(x, (0, 0), 1.2)) for x in (base, f))
    flow = dis.calc(a, b, None)
    sx, sy = cv2.Sobel(a, cv2.CV_32F, 1, 0), cv2.Sobel(a, cv2.CV_32F, 0, 1)
    weight = cv2.GaussianBlur(sx * sx + sy * sy, (0, 0), 2)
    weight = np.clip(weight / (np.percentile(weight, 90) + 1e-6), 0, 1) ** 2
    median = np.median(flow.reshape(-1, 2), axis=0)
    eps = 0.02
    num = cv2.GaussianBlur(flow * weight[..., None], (0, 0), sigma)
    den = cv2.GaussianBlur(weight, (0, 0), sigma)[..., None]
    return (num + eps * median) / (den + eps)


def toned(ref, f, sigma: float):
    """The 720p frame in the upscale's grade: per channel, the upscale's mean blurred level at each blurred 720p level
    (monotone), the same offset past the levels the blur leaves (a glint or a deep shadow keeps its height). Flow's
    upscale sits up to 3 of 255 off its 720p, and the clamp would pull the edges it holds that way; a halo is fine-scale
    and gone in the blur."""
    a, c = (cv2.GaussianBlur(x, (0, 0), sigma)[8:-8:3, 8:-8:3] for x in (ref, f))
    out = np.empty_like(ref)
    for ch in range(3):
        x, y = a[..., ch].ravel(), c[..., ch].ravel().astype(np.float64)
        count = np.bincount(x, minlength=256)
        ok = np.nonzero(count > 30)[0]
        if len(ok) < 2:
            out[..., ch] = ref[..., ch]
            continue
        mean = np.bincount(x, weights=y, minlength=256)[ok] / count[ok]
        lut = np.arange(256) + np.interp(np.arange(256), ok, mean - ok)
        out[..., ch] = np.clip(np.maximum.accumulate(lut) + 0.5, 0, 255).astype(np.uint8)[ref[..., ch]]
    return out


def clamp(up, ref, cut: list):
    """An upscaled frame (BGR) with its luma held inside the range its 720p frame `ref` (same size and place) has over
    CLAMP_K px, widened by CLAMP_M: the halo is lighter or darker than anything there in the 720p, while an edge's place
    and steepness and the detail inside the range stay. The chroma turns to the 720p's where the luma moved (a dark mark
    lifted with its own chroma read grey-violet). `cut` gets the share of the picture moved 2 grey levels or more."""
    a = cv2.cvtColor(up.astype(np.float32) / 255, cv2.COLOR_BGR2YCrCb) * 255
    r = cv2.cvtColor(ref.astype(np.float32) / 255, cv2.COLOR_BGR2YCrCb) * 255
    y, low = a[..., 0], r[..., 0]
    box = np.ones((CLAMP_K, CLAMP_K), np.uint8)
    shift = np.clip(y, cv2.erode(low, box) - CLAMP_M, cv2.dilate(low, box) + CLAMP_M) - y
    cut.append(float(np.mean(np.abs(shift) >= 2)))
    t = np.minimum(np.abs(shift) / CLAMP_MIX, 1)[..., None]
    a[..., 1:] += t * (r[..., 1:] - a[..., 1:])
    a[..., 0] = y + shift
    return np.clip(cv2.cvtColor(a / 255, cv2.COLOR_YCrCb2BGR) * 255 + 0.5, 0, 255).astype(np.uint8)


def onto(dis, low, up):
    """The 720p frame `low` warped onto the upscale frame `up` and put in its grade: resampled once, Lanczos through
    the scale and a dense flow."""
    (h, w), (lh, lw) = up.shape[:2], low.shape[:2]
    gy, gx = np.mgrid[0:h, 0:w].astype(np.float32)
    flow = geometry(dis, up, cv2.resize(low, (w, h), interpolation=cv2.INTER_LINEAR), ALIGN_SIGMA)
    ref = cv2.remap(low, (gx + flow[..., 0] + 0.5) * lw / w - 0.5, (gy + flow[..., 1] + 0.5) * lh / h - 0.5,
                    cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)
    return toned(ref, up, 2 * w / lw)


def aligned(ref720: Path, upscale: Path, ahead: int):
    """(upscale frame, its 720p frame warped onto it): anchored() turned round for an upscale that does not tremble, so
    the upscale keeps its own pixels (the anchor's resample costs 6 % of the sharpness)."""
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    for fb, fa in zip(frames(upscale), matched(ref720, ahead)):
        yield fb, onto(dis, fa, fb)


def placed(stream, ref720: Path, ahead: int):
    """(anchored frame, its 720p frame Lanczos to the same size, in its grade): an anchored film sits on the 720p."""
    for f, low in zip(stream, matched(ref720, ahead)):
        h, w = f.shape[:2]
        yield f, toned(cv2.resize(low, (w, h), interpolation=cv2.INTER_LANCZOS4), f, 2 * w / low.shape[1])


def cleaned(pairs, cut: list):
    for f, ref in pairs:
        yield clamp(f, ref, cut)


def settled(stream, still: list):
    """Flow also redraws fine texture (grass, moss, fog) every frame, which the anchor keeps. A 1-2-1 average with the
    neighbours cancels a change that alternates frame to frame but triples a walking man, so it is taken only where
    the picture stands: motion to either neighbour under 0.5 px a frame is averaged, over 1.5 px left as it is."""
    lo, hi = 0.5, 1.5
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)

    def small(frame):
        h, w = frame.shape[:2]
        return frame, gray(cv2.resize(frame, (FLOW_W, round(FLOW_W * h / w)), interpolation=cv2.INTER_AREA))

    def motion(a, b):
        flow = dis.calc(a[1], b[1], None)
        return cv2.GaussianBlur(np.hypot(flow[..., 0], flow[..., 1]), (0, 0), 4) * 1920 / FLOW_W

    source = iter(stream)
    before, current = None, next(source, None)
    after = next(source, None) if current is not None else None
    current, after = (small(f) if f is not None else None for f in (current, after))
    while current is not None:
        p, q = before or current, after or current
        m = np.maximum(motion(current, p) if p is not current else 0, motion(current, q) if q is not current else 0)
        weight = np.clip((hi - m) / (hi - lo), 0, 1)
        still.append(float(np.mean(weight)))
        h, w = current[0].shape[:2]
        weight = cv2.resize(np.asarray(weight, np.float32), (w, h), interpolation=cv2.INTER_LINEAR)[..., None]
        f = current[0].astype(np.float32)
        average = (p[0].astype(np.float32) + 2 * f + q[0].astype(np.float32)) / 4
        yield np.clip(weight * average + (1 - weight) * f + 0.5, 0, 255).astype(np.uint8)
        nxt = next(source, None) if after is not None else None
        before, current, after = current, after, small(nxt) if nxt is not None else None


def measure_size(path: Path) -> tuple[int, int]:
    return probe(path)[:2]


def look(path, every: int = 6) -> tuple[list[float], float]:
    """Mean colour (R, G, B of 255) and sharpness (Laplacian variance of the luma) over every `every`-th frame."""
    colour, sharp = [], []
    for index, frame in enumerate(frames(path)):
        if index % every:
            continue
        colour.append(frame.reshape(-1, 3).mean(axis=0)[::-1])
        sharp.append(cv2.Laplacian(gray(frame), cv2.CV_64F).var())
    return [round(float(c), 2) for c in np.mean(colour, axis=0)], round(float(np.mean(sharp)), 1)


def reanchor(film: Path, orig: Path, dst: Path, sigma: float) -> None:
    """A finished film cut from the upscale put back on the 720p's geometry, whatever was done to it after the download
    (crop, scale, trim, a ping-pong or dissolve loop, a reversal, a per-frame steadying shift)."""
    originals = list(frames(orig))
    fps, n = info(film)
    picks = set(np.linspace(0, n - 1, 7).astype(int).tolist())
    sample, small_film = {}, []
    sw = 240
    for i, f in enumerate(frames(film)):
        h, w = f.shape[:2]
        if i in picks:
            sample[i] = gray(f)
        small_film.append(cv2.resize(gray(f), (sw, round(h * sw / w)), interpolation=cv2.INTER_AREA).astype(np.float32))

    def thumb(f):
        return cv2.resize(gray(f), (96, 54), interpolation=cv2.INTER_AREA).astype(np.float32)

    thumbs = np.stack([thumb(f) for f in originals])
    sift = cv2.SIFT_create(4000)
    keypoints, mats = {}, []
    for g in sample.values():
        small = cv2.resize(g, (96, 54), interpolation=cv2.INTER_AREA).astype(np.float32)
        j = int(np.argmin([cv2.matchTemplate(small, t, cv2.TM_SQDIFF_NORMED)[0, 0] for t in thumbs]))
        if j not in keypoints:
            keypoints[j] = sift.detectAndCompute(gray(originals[j]), None)
        ka, da = keypoints[j]
        kb, db = sift.detectAndCompute(g, None)
        if da is None or db is None:
            continue
        pairs = cv2.BFMatcher(cv2.NORM_L2).knnMatch(da, db, k=2)
        good = [p[0] for p in pairs if len(p) == 2 and p[0].distance < 0.75 * p[1].distance]
        if len(good) < 40:
            continue
        pa = np.float32([ka[m.queryIdx].pt for m in good])
        pb = np.float32([kb[m.trainIdx].pt for m in good])
        m, inliers = cv2.estimateAffinePartial2D(pa, pb, method=cv2.RANSAC, ransacReprojThreshold=1.0)
        if m is not None and inliers.sum() > 30:
            mats.append(m)
    if len(mats) < 3:
        raise Refused(f"{film} does not match {orig} (too few SIFT matches)")
    mapping = np.median(np.stack(mats), axis=0)
    spread = np.max(np.abs(np.stack(mats) - mapping)[:, :, 2])
    print(f"mapping: scale {np.hypot(mapping[0, 0], mapping[1, 0]):.4f}, offset {mapping[0, 2]:+.1f},"
          f"{mapping[1, 2]:+.1f} (spread {spread:.2f} px)", file=sys.stderr)

    sh = round(h * sw / w)
    to_small = np.vstack([np.float32([[sw / w, 0, 0], [0, sw / w, 0]]), [0, 0, 1]]) @ np.vstack([mapping, [0, 0, 1]])
    small_orig = np.stack([cv2.warpAffine(gray(f), to_small[:2], (sw, sh), flags=cv2.INTER_AREA).astype(np.float32)
                           for f in originals])
    errors = np.stack([((small_orig[:, 8:-8, 8:-8] - d[8:-8, 8:-8]) ** 2).mean(axis=(1, 2)) for d in small_film])
    errors = errors / np.median(errors, axis=1, keepdims=True)
    # Straight runs, one original frame per film frame, forward or back; a break (a loop's seam, a ping-pong's turn)
    # costs BREAK. In a near-still stretch neighbouring frames differ less than the upscale's own noise, so a path
    # free to hold or skip wanders.
    brk_cost, count = 3.0, len(originals)
    cost = [errors[0].copy(), errors[0].copy()]
    back = []
    for e in errors[1:]:
        best = min(range(2), key=lambda d: cost[d].min())
        brk = cost[best].min() + brk_cost
        new, bk = [], []
        for d, sd in ((0, 1), (1, -1)):
            cont = np.full(count, np.inf)
            if sd == 1:
                cont[1:] = cost[d][:-1]
            else:
                cont[:-1] = cost[d][1:]
            take = cont <= brk
            new.append(np.where(take, cont, brk) + e)
            bk.append(np.where(take, -1, best * count + int(np.argmin(cost[best]))))
        cost, back = new, back + [bk]
    d = int(np.argmin([c.min() for c in cost]))
    j = int(np.argmin(cost[d]))
    match = [j]
    for bk in reversed(back):
        i = int(bk[d][j])
        if i < 0:
            j -= 1 if d == 0 else -1
        else:
            d, j = divmod(i, count)
        match.append(j)
    match = match[::-1]
    steps = np.diff(match)
    print(f"frames: film {len(small_film)}, original {count}; matched {match[0]}..{match[-1]}, steps "
          f"{dict(zip(*np.unique(steps, return_counts=True)))}", file=sys.stderr)

    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    gy, gx = np.mgrid[0:h, 0:w].astype(np.float32)
    flows, kept = [], [0]

    def warped():
        for f, j in zip(frames(film), match):
            base = cv2.warpAffine(originals[j], mapping, (w, h), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)
            flow = geometry(dis, base, f, sigma)
            mag = np.hypot(flow[..., 0], flow[..., 1])[16:-16, 16:-16]
            flows.append((float(np.median(mag)), float(np.percentile(mag, 99))))
            # No original frame is this one (a loop's dissolve): left as it is.
            if flows[-1][0] > 2.5:
                kept[0] += 1
                yield f
                continue
            yield cv2.remap(f, gx + flow[..., 0], gy + flow[..., 1], cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)

    probe = dst.with_name(f".{dst.name}.reanchor.mp4")
    try:
        encode(warped(), probe, fps, film)
        fm = np.array(flows)
        print(f"flow: median per frame {np.median(fm[:, 0]):.2f} px (max {fm[:, 0].max():.2f}), 99th pct max "
              f"{fm[:, 1].max():.2f} px; {kept[0]} frames left as they were", file=sys.stderr)
        # A wrong 720p (the turning2 inlay was first given another media's) pushed the flow to 32 px.
        if kept[0] > 0.15 * len(fm):
            raise Refused(f"{kept[0]} of {len(fm)} frames match no frame of {orig}: the film is not this original, "
                          "nothing written")
        probe.replace(dst)
    finally:
        probe.unlink(missing_ok=True)


def raw_path(path: Path) -> Path:
    return path.with_name(f"{path.stem}.raw{path.suffix}")


def fix(upscale: Path, ref720: Path) -> dict:
    """Both fixes in one decode and one encode, since each lossy generation costs: a trembling upscale is anchored and
    settled, then clamped on its 720p; a steady one is clamped against the 720p warped onto it and keeps its own pixels.
    The result replaces the upscale, which moves to <stem>.raw.mp4; nothing is replaced when the colour moves or the
    720p is not the same media."""
    raw, ref = measure(upscale), measure(ref720)
    out = {"file": str(upscale), "ref720": str(ref720), "raw": reading(raw), "ref": reading(ref), "steadied": "none",
           "cleaned": False}
    try:
        ahead = lead(ref720, upscale)
    except Refused as refusal:
        out["reason"] = f"{refusal}; the upscale is kept"
        return out
    fps = info(upscale)[0]
    fixed = upscale.with_name(f".{upscale.name}.fix.mp4")
    try:
        cut: list = []
        if trembles(raw, ref):
            still: list = []
            encode(cleaned(placed(settled(anchored(ref720, upscale, ahead), still), ref720, ahead), cut), fixed, fps,
                   upscale)
            out["steadied"], out["still"] = "anchor+settle", round(float(np.mean(still)), 2)
            after = measure(fixed)
            out["fixed"] = reading(after)
            if after["global"]["corner_rms"] >= raw["global"]["corner_rms"]:
                out["reason"] = "the anchor+settle film read no steadier; only cleaned"
                out["steadied"], cut = "none", []
        if out["steadied"] == "none":
            encode(cleaned(aligned(ref720, upscale, ahead), cut), fixed, fps, upscale)
        out["cleaned"] = bool(cut)
        if cut:
            out["clamped"] = round(float(np.mean(cut)), 3)
        (colour, sharp), (fixed_colour, fixed_sharp) = look(upscale), look(fixed)
        out["colour_shift"] = round(max(abs(a - b) for a, b in zip(colour, fixed_colour)), 2)
        out["sharpness"] = round(fixed_sharp / sharp, 3) if sharp else None
        if out["colour_shift"] > GATE_RGB:
            out["reason"] = f"the film's colour moved {out['colour_shift']} of 255 (gate {GATE_RGB}); the upscale is kept"
            out["steadied"], out["cleaned"] = "none", False
            return out
        upscale.replace(raw_path(upscale))
        fixed.replace(upscale)
        out["raw_file"] = str(raw_path(upscale))
    finally:
        fixed.unlink(missing_ok=True)
    return out


# A take started from a frame of the upscale carries its halos and invented texture even at 720p (20 chained takes,
# arbostar 2026-10-21); the same frame of its 720p is clean, and a seam needs that exact frame. The register keeps one
# 64-bit dHash per frame of each Flow 1080p's 720p, so media-run's door knows such a frame by its content however it
# was saved (PNG, JPEG, resized), then tells by the pixels whether it came from the upscale or from the 720p.
# Calibrated 2026-10-22 on four Flow pairs: a cut of the upscale (PNG, JPEG, a plain ffmpeg decode, 720p) sits 0-1.3
# grey levels from its frame and 0.29-0.51 of its distance to the 720p's; frame 0 of another take from the same start
# frames 4.8-5.7 (so the still a take started from passes); a painted logo or a blurred patch lifts the blurred
# difference to 31-242, an untouched cut to 3 (8 with plain ffmpeg's decode).
NEAR_BITS = 10      # dHash bits of 64 within which a registered film is a candidate
FROM_UPSCALE = 0.6  # an image is the upscale's frame when it sits this much closer to it than to the 720p's
EXACT = 3.0         # grey levels (trimmed mean): a saved frame, its encode and decode rounding included
EDIT = 12.0         # grey levels a 4 px blur of the difference reaches where the frame was painted over
BATCH = 6           # registered films read at once (ffmpeg decodes)
REGISTER = Path(os.environ.get("VIDEO_JITTER_REGISTER") or Path.home() / ".cache" / "video-jitter" / "upscales.jsonl")


def dhash(frame) -> int:
    small = cv2.resize(gray(frame), (9, 8), interpolation=cv2.INTER_AREA).astype(np.int16)
    return int(np.packbits(small[:, 1:] > small[:, :-1]).view(">u8")[0])


def register(film: Path, twin: Path, store: Path, **extra) -> None:
    row = {"film": str(Path(film).absolute()), "twin": str(Path(twin).absolute()), **extra,
           "hashes": [f"{dhash(f):016x}" for f in frames(twin)]}
    Path(store).parent.mkdir(parents=True, exist_ok=True)
    with open(store, "a") as out:
        out.write(json.dumps(row) + "\n")


def frames_at(path, picks) -> dict:
    """{index: frame} for the frames `picks` of `path`, decoded in one pass."""
    w, h, _, _ = probe(path)
    picks = sorted(set(picks))
    run = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-vf",
                          "select=" + "+".join(f"eq(n\\,{i})" for i in picks) + f",scale=flags={SWS}",
                          "-fps_mode", "passthrough", "-frames:v", str(len(picks)), "-f", "rawvideo", "-pix_fmt", "bgr24",
                          "-"], capture_output=True)
    got = np.frombuffer(run.stdout, np.uint8)
    if len(got) < len(picks) * w * h * 3:
        raise Refused(f"{path} lacks some of the frames {picks}")
    return dict(zip(picks, got[:len(picks) * w * h * 3].reshape(len(picks), h, w, 3)))


def thumbs(path, width: int, count: int):
    """The first `count` frames' luma at `width` px, as float32 (frames, h, w)."""
    w, h, _, _ = probe(path)
    height = round(width * h / w)
    run = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-vf",
                          f"scale={width}:{height}:flags=area,format=gray", "-frames:v", str(count), "-f", "rawvideo",
                          "-"], capture_output=True)
    return np.frombuffer(run.stdout, np.uint8).reshape(-1, height, width).astype(np.float32)


def trimmed(diff) -> float:
    """Mean of the smallest 90 % of a difference: a local edit does not lift it."""
    a = np.sort(np.abs(diff).ravel())
    return float(a[:int(len(a) * 0.9)].mean())


def door(images: list[str], store: Path, out_dir: Path, clean: bool = False) -> list[dict]:
    """Each image that is a frame of a registered upscale: `swap` to the same frame of its 720p (written to out_dir),
    or `edited` when it was painted over after the cut (redo the edit on that frame, also written). With `clean`, for an
    image to edit, where the 720p would cost its detail, that frame is the cleaned one at the image's size instead: the
    fixed film's own, or the upscale's clamped here; a cut of the fixed film passes. A frame of the 720p itself, and
    anything else (the still a take started from among them), gives no row."""
    rows: dict = {}
    for line in store.read_text().splitlines() if store.exists() else []:
        with contextlib.suppress(ValueError, KeyError, TypeError):
            row = json.loads(line)
            rows[row["film"]] = row
    rows = [r for r in rows.values() if Path(r["film"]).exists() and Path(r["twin"]).exists()]
    if not rows:
        return []
    index = np.array([int(h, 16) for r in rows for h in r["hashes"]], np.uint64)
    owner = np.array([k for k, r in enumerate(rows) for _ in r["hashes"]])
    out = []
    for image in images:
        img = cv2.imread(image, cv2.IMREAD_UNCHANGED)
        if img is None:
            continue
        # a cutout is no longer the frame, whatever its pixels
        cutout = img.ndim == 3 and img.shape[2] == 4 and int(img[..., 3].min()) < 255
        img = cv2.imread(image, cv2.IMREAD_COLOR)
        (h, w), g = img.shape[:2], gray(img).astype(np.float32)
        bits = np.bitwise_count(index ^ np.uint64(dhash(img)))
        films = sorted((int(bits[owner == k].min()), k) for k in set(owner[bits <= NEAR_BITS].tolist()))

        def sized(frame):
            return cv2.resize(frame, (w, h), interpolation=cv2.INTER_AREA if frame.shape[1] > w else cv2.INTER_LANCZOS4)

        def check(film) -> list:
            least, k = film
            row = rows[k]
            near = np.nonzero(bits[owner == k] <= least + 2)[0]
            # a still shot holds many frames alike, so its near frames are ranked small, then the best read whole
            small = thumbs(row["twin"], 320, int(near.max()) + 1)
            thumb = cv2.resize(g, small.shape[:0:-1], interpolation=cv2.INTER_AREA)
            picks = sorted(near[np.argsort([float(np.mean(np.abs(small[i] - thumb))) for i in near])[:8]].tolist())
            try:
                sources = {p: frames_at(row[p], picks) for p in ("film", "raw") if row.get(p) and Path(row[p]).exists()}
                twins = frames_at(row["twin"], picks)
            except Refused:
                return []
            got = []
            for i in picks:
                to_up, source = min((trimmed(g - gray(sized(f[i])).astype(np.float32)), p) for p, f in sources.items())
                got.append({"image": image, "film": row["film"], "frame": i, "twin": row["twin"], "source": source,
                            "to_upscale": round(to_up, 2),
                            "to_twin": round(trimmed(g - gray(sized(twins[i])).astype(np.float32)), 2),
                            "frames": (sources, twins[i], row)})
            return got

        def decisive(x):
            up, twin = x["to_upscale"], x["to_twin"]
            return (up <= EXACT and up <= FROM_UPSCALE * twin) or (twin <= EXACT and twin <= FROM_UPSCALE * up)

        best = None
        # the nearest films first, a few at once, each read only as far as its near frames; the film the image was
        # cut from sits within a few grey levels of it, another take from the same start frames 5 away, so a match
        # that tells the upscale from its 720p ends the search
        with ThreadPoolExecutor(BATCH) as pool:
            for at in range(0, len(films), BATCH):
                got = [x for xs in pool.map(check, films[at:at + BATCH]) for x in xs]
                best = min([x for x in (best, *got) if x is not None], key=lambda x: x["to_upscale"], default=None)
                if any(decisive(x) for x in got):
                    break
        if best is None or best["to_upscale"] > EXACT or best["to_upscale"] > FROM_UPSCALE * best["to_twin"]:
            continue
        sources, twin, row = best.pop("frames")
        i, film = best["frame"], Path(best["film"])
        if clean and best["source"] == "film" and row.get("raw"):
            continue
        source = sized(sources[best["source"]][i])
        # the paint is told in colour: a recolour can keep the luma
        diff = cv2.cvtColor(img, cv2.COLOR_BGR2YCrCb).astype(np.float32) - cv2.cvtColor(
            source, cv2.COLOR_BGR2YCrCb).astype(np.float32)
        painted = max(float(np.abs(cv2.GaussianBlur(d - np.median(d), (0, 0), 4 * w / 1920)).max())
                      for d in cv2.split(diff))
        if not clean:
            swapped, kind = twin, "720p"
        elif row.get("raw"):
            swapped, kind = sources["film"][i], "cleaned"
        else:
            up = sources["film"][i]
            swapped = clamp(up, onto(cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM), twin, up), [])
            kind = "cleaned"
        if clean:
            swapped = sized(swapped)
        name = f"{film.stem}-{hashlib.sha1(str(film).encode()).hexdigest()[:8]}.{kind}-f{i}.png"
        out_dir.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(out_dir / name), swapped)
        out.append({**best, "verdict": "edited" if cutout or painted > EDIT else "swap", "painted": round(painted, 1),
                    "as": kind, "swapped": str(out_dir / name)})
    return out


def describe(m: dict, ref: dict | None) -> str:
    g, local = reading(m)
    text = f"global {g:.3f}, local {local:.3f}"
    if ref is not None:
        rg, rl = reading(ref)
        text += f" (the 720p: {rg:.3f}, {rl:.3f})"
    return text


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="video-jitter", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("measure")
    p.add_argument("videos", nargs="+")
    p.add_argument("--map")
    p = sub.add_parser("check")
    p.add_argument("film")
    p.add_argument("--ref720")
    p.add_argument("--steadied", action="store_true")
    p = sub.add_parser("anchor")
    p.add_argument("ref720")
    p.add_argument("upscale")
    p.add_argument("out")
    p = sub.add_parser("reanchor")
    p.add_argument("film")
    p.add_argument("ref720")
    p.add_argument("out")
    p.add_argument("--sigma", type=float, default=6.0)
    p = sub.add_parser("settle")
    p.add_argument("film")
    p.add_argument("out")
    p = sub.add_parser("fix")
    p.add_argument("upscale")
    p.add_argument("--ref720", required=True)
    p.add_argument("--register", nargs="?", const=str(REGISTER), help="alone: the default register")
    p.set_defaults(raw=None)
    p = sub.add_parser("register")
    p.add_argument("upscale")
    p.add_argument("--ref720", required=True)
    p.add_argument("--register", default=str(REGISTER))
    p.add_argument("--raw", help="the download, when the upscale was fixed")
    p = sub.add_parser("door")
    p.add_argument("images", nargs="+")
    p.add_argument("--register", default=str(REGISTER))
    p.add_argument("--out", help="default: frames/ beside the register")
    p.add_argument("--clean", action="store_true", help="an image to edit: its frame cleaned at its size, not the 720p's")
    args = parser.parse_args(argv)
    try:
        if args.command == "measure":
            if args.map:
                Path(args.map).mkdir(parents=True, exist_ok=True)
            for video in args.videos:
                try:
                    print(json.dumps(measure(video, args.map)), flush=True)
                except Refused as refusal:
                    print(json.dumps({"file": video, "error": str(refusal)}), flush=True)
            return 0
        if args.command == "check":
            m = measure(args.film)
            ref = measure(args.ref720) if args.ref720 else None
            verdict = trembles(m, ref, args.steadied)
            if verdict is None:
                print(f"video-jitter: {args.film}: {describe(m, ref)}; a steadied film is judged only against its 720p "
                      "(--ref720)", file=sys.stderr)
                return 0
            if not verdict:
                print(f"steady: {describe(m, ref)}")
                return 0
            remedy = (f"video-jitter reanchor {args.film} {args.ref720} <out>, then video-jitter settle <out> <final>"
                   if args.ref720 else
                   "fetch its 720p (gemini-web fetch <account> <media id> --dest <abs> --resolution 720p), then "
                   "video-jitter reanchor <film> <720p> <out> and video-jitter settle <out> <final>; without a 720p "
                   "real motion reads the same, so judge a moving shot against it")
            print(f"video-jitter: {args.film} trembles: {describe(m, ref)}, over the gate (global {GATE_GLOBAL}, "
                  f"local rise {GATE_LOCAL_RISE}); fix: {remedy}", file=sys.stderr)
            return 1
        if args.command == "anchor":
            encode(anchored(Path(args.ref720), Path(args.upscale)), Path(args.out), info(args.upscale)[0],
                   Path(args.upscale))
            return 0
        if args.command == "reanchor":
            reanchor(Path(args.film), Path(args.ref720), Path(args.out), args.sigma)
            return 0
        if args.command == "settle":
            still: list = []
            encode(settled(frames(args.film), still), Path(args.out), info(args.film)[0], Path(args.film))
            print(f"settle: {len(still)} frames, {np.mean(still):.0%} of the picture averaged (least on a frame "
                  f"{min(still):.0%})", file=sys.stderr)
            return 0
        if args.command == "door":
            for row in door(args.images, Path(args.register), Path(args.out or Path(args.register).parent / "frames"),
                            args.clean):
                print(json.dumps(row), flush=True)
            return 0
        upscale, ref720 = Path(args.upscale), Path(args.ref720)
        got = fix(upscale, ref720) if args.command == "fix" else {}
        if args.command == "fix":
            print(json.dumps(got), flush=True)
        if args.register:
            raw = got.get("raw_file") or args.raw
            register(upscale, ref720, Path(args.register), **({"raw": str(Path(raw).absolute())} if raw else {}))
        return 0
    except Refused as refusal:
        print(f"video-jitter: {refusal}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
