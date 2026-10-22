# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "opencv-python-headless==5.0.0.93"]
# ///
"""The tremble Flow's "1080p Upscaled" download adds to a clip, measured and taken out (docs/video-jitter.md).

    measure <video>... [--map <dir>]          one JSON line per video
    check <film> [--ref720 <720p>] [--steadied]   exit 0 steady, 1 trembles (stderr names the fix), 2 usage
    anchor <720p> <1080p> <out>               the raw upscale warped onto its 720p frame by frame
    reanchor <film> <720p> <out> [--sigma S]  the same for a film already cut from the upscale
    settle <anchored> <out>                   the still parts averaged 1-2-1 with their neighbours
    steady <1080p> --ref720 <720p>            measure; a trembling upscale is replaced in place by anchor + settle
                                              (the 720p + Lanczos when the anchor refuses); one JSON line

Units are px of a 1920-wide frame. Global: tracked corners give a similarity per frame pair; a frame's jerk is its
offset from the midpoint of its neighbours, read at the frame corners (corner_rms). Local: dense flow minus the global
motion, the same jerk per pixel, the median cell of a 6x10 grid (median_cell).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
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


def anchored(ref720: Path, upscale: Path):
    """Each upscaled frame warped by dense flow onto the Lanczos upscale of its 720p frame. The flow runs on frames
    blurred σ1.2 and is blurred again σ3, so it carries geometry and never texture: the picture takes the original's
    place and keeps the upscale's detail."""
    na, nb = info(ref720)[1], info(upscale)[1]
    if abs(na - nb) > 1:
        raise Refused(f"{ref720} has {na} frames, {upscale} {nb}: not the same media")
    dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    grid = None
    for fa, fb in zip(frames(ref720), frames(upscale)):
        h, w = fb.shape[:2]
        base = cv2.resize(fa, (w, h), interpolation=cv2.INTER_LANCZOS4)
        ga, gb = (gray(cv2.GaussianBlur(x, (0, 0), 1.2)) for x in (base, fb))
        flow = cv2.GaussianBlur(dis.calc(ga, gb, None), (0, 0), 3)
        if grid is None:
            grid = np.mgrid[0:h, 0:w].astype(np.float32)
        yield cv2.remap(fb, grid[1] + flow[..., 0], grid[0] + flow[..., 1], cv2.INTER_LANCZOS4,
                        borderMode=cv2.BORDER_REFLECT)


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


def lanczos(ref720: Path, upscale: Path, dst: Path) -> None:
    size = measure_size(upscale)
    part = dst.with_name(f".{dst.name}.part.mp4")
    try:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(ref720), "-i", str(upscale), "-map", "0:v",
                        "-map", "1:a?", "-vf", f"scale={size[0]}:{size[1]}:flags=lanczos", "-c:v", "libx264",
                        "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart",
                        str(part)], check=True)
        part.replace(dst)
    finally:
        part.unlink(missing_ok=True)


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

    def geometry(base, f):
        """Raw DIS flow is noise in dark glass, shade and flat paving, so it is a normalized convolution weighted by
        the base's edge energy, falling back to the frame's median shift where no texture is near."""
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

    gy, gx = np.mgrid[0:h, 0:w].astype(np.float32)
    flows, kept = [], [0]

    def warped():
        for f, j in zip(frames(film), match):
            base = cv2.warpAffine(originals[j], mapping, (w, h), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT)
            flow = geometry(base, f)
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


def steady(upscale: Path, ref720: Path) -> dict:
    raw, ref = measure(upscale), measure(ref720)
    out = {"file": str(upscale), "ref720": str(ref720), "raw": reading(raw), "ref": reading(ref), "steadied": "none"}
    if not trembles(raw, ref):
        return out
    fps = info(upscale)[0]
    fixed = upscale.with_name(f".{upscale.name}.steady.mp4")
    try:
        still: list = []
        try:
            encode(settled(anchored(ref720, upscale), still), fixed, fps, upscale)
            out["steadied"], out["still"] = "anchor+settle", round(float(np.mean(still)), 2)
        except Refused as refusal:
            lanczos(ref720, upscale, fixed)
            out["steadied"], out["reason"] = "lanczos", str(refusal)
        after = measure(fixed)
        out["fixed"] = reading(after)
        if after["global"]["corner_rms"] >= raw["global"]["corner_rms"]:
            out["steadied"], out["reason"] = "none", f"the {out['steadied']} film read no steadier; the upscale is kept"
            return out
        (colour, sharp), (fixed_colour, fixed_sharp) = look(upscale), look(fixed)
        out["colour_shift"] = round(max(abs(a - b) for a, b in zip(colour, fixed_colour)), 2)
        out["sharpness"] = round(fixed_sharp / sharp, 3) if sharp else None
        if out["colour_shift"] > GATE_RGB:
            out["steadied"], out["reason"] = "none", (f"the {out['steadied']} film's colour moved {out['colour_shift']} "
                                                      f"of 255 (gate {GATE_RGB}); the upscale is kept")
            return out
        fixed.replace(upscale)
    finally:
        fixed.unlink(missing_ok=True)
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
    p = sub.add_parser("steady")
    p.add_argument("upscale")
    p.add_argument("--ref720", required=True)
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
            fix = (f"video-jitter reanchor {args.film} {args.ref720} <out>, then video-jitter settle <out> <final>"
                   if args.ref720 else
                   "fetch its 720p (gemini-web fetch <account> <media id> --dest <abs> --resolution 720p), then "
                   "video-jitter reanchor <film> <720p> <out> and video-jitter settle <out> <final>; without a 720p "
                   "real motion reads the same, so judge a moving shot against it")
            print(f"video-jitter: {args.film} trembles: {describe(m, ref)}, over the gate (global {GATE_GLOBAL}, "
                  f"local rise {GATE_LOCAL_RISE}); fix: {fix}", file=sys.stderr)
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
        print(json.dumps(steady(Path(args.upscale), Path(args.ref720))), flush=True)
        return 0
    except Refused as refusal:
        print(f"video-jitter: {refusal}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
