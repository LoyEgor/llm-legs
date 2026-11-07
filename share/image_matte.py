# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93"]
# ///
"""Keep the input's own pixels under a generative cutout's matte.

ChatGPT's Remove BG cuts hair and fine edges better than any local matte, but it re-renders the
whole image: reframed (~0.92 scale and a shift), brighter, redrawn detail, parts slightly displaced.
This registers the cutout back onto the input (SIFT, RANSAC similarity, then a local flow that moves
displaced parts onto the input) and builds the delivery in the input's frame: the cutout's alpha, the
input's pixels inside the subject, and in an edge band the cutout's own pixels with their tone
corrected locally to the input (clean background-free strands, no colour seam). Tone is learnt only
where both show the same surface, and input pixels a coloured screen leaks into come from the cutout.
One stdout line: `composite=matte changed=<percent of the subject from the cutout> moved=<px> ghost=<px>
residue=<percent>`, or `composite=skipped reason=unregistered|redrawn|ghost|residue` when the cutout
cannot be laid back cleanly (nothing written: the cutout is delivered as is). Exit 0 delivered,
1 unreadable input, 2 usage.
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile

import cv2
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import limit_hit  # noqa: E402

WORK_SIDE = 1600
MIN_INLIERS = 40
MIN_INLIER_SHARE = 0.25
REDRAWN_LIMIT = 45.0
BAND = 0.012
TONE_SIGMA = 0.04
FLOW_SIGMA = 0.02  # smoothing of the local alignment, share of the short side: parts move, strands do not
FLOW_LIMIT = 0.04  # the largest local correction, share of the short side
AGREE_DE = 25.0  # Lab distance below which the input and the cutout show the same surface (floor)
SCREEN_CHROMA = 25.0  # Lab chroma from which a backdrop is a coloured screen (green, blue) whose colour can leak
SCREEN_PULL = 15.0  # Lab a*b* shift toward the screen's hue, beyond the cutout's own colour, that reads as the screen
GHOST_LIMIT = 0.6  # displacement (% of the short side) left across edges where the cutout meets the input
RESIDUE_LIMIT = 5.0  # densest local share (%) of screen-coloured subject pixels the delivery may keep


def register(base: np.ndarray, cut: np.ndarray, alpha: np.ndarray) -> np.ndarray | None:
    def gray(rgb: np.ndarray, scale: float) -> np.ndarray:
        small = cv2.resize(rgb, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else rgb
        return cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)

    sb = min(1.0, WORK_SIDE / max(base.shape[:2]))
    sc = min(1.0, WORK_SIDE / max(cut.shape[:2]))
    mask = (cv2.resize(alpha, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA) if sc < 1 else alpha) > 128
    sift = cv2.SIFT_create(4000)
    kc, dc = sift.detectAndCompute(gray(cut, sc), mask.astype(np.uint8))
    kb, db = sift.detectAndCompute(gray(base, sb), None)
    if dc is None or db is None or len(kc) < MIN_INLIERS or len(kb) < MIN_INLIERS:
        return None
    good = [m for m, n in (p for p in cv2.BFMatcher(cv2.NORM_L2).knnMatch(dc, db, k=2) if len(p) == 2)
            if m.distance < 0.75 * n.distance]
    if len(good) < MIN_INLIERS:
        return None
    src = np.float32([kc[m.queryIdx].pt for m in good]) / sc
    dst = np.float32([kb[m.trainIdx].pt for m in good]) / sb
    matrix, inliers = cv2.estimateAffinePartial2D(src, dst, method=cv2.RANSAC, ransacReprojThreshold=3 / sb)
    if matrix is None or inliers.sum() < MIN_INLIERS or inliers.sum() < MIN_INLIER_SHARE * len(good):
        return None
    return matrix


def local_flow(base: np.ndarray, premultiplied: np.ndarray, alpha: np.ndarray, covered: np.ndarray) -> np.ndarray:
    """Where each input pixel's content sits in the cutout laid over the input, as a smooth part-scale offset field:
    dense flow from the input to the laid cutout (the input itself wherever the cutout is transparent or has no
    pixels, so nothing outside the subject pulls)."""
    height, width = alpha.shape
    short = min(height, width)
    s = min(1.0, WORK_SIDE / max(height, width))

    def gray(rgb: np.ndarray) -> np.ndarray:
        rgb = cv2.resize(rgb, None, fx=s, fy=s, interpolation=cv2.INTER_AREA) if s < 1 else rgb
        return cv2.cvtColor(np.clip(rgb, 0, 255).astype(np.uint8), cv2.COLOR_RGB2GRAY)

    # Past the cutout's frame its pixels are only replicated edge streaks: the input stands in, nothing pulls there.
    laid = np.where(covered[..., None], premultiplied + base * (1 - alpha[..., None]), base)
    still, moving = gray(base).astype(np.float32), gray(laid).astype(np.float32)
    flow = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM).calc(
        still.astype(np.uint8), moving.astype(np.uint8), None)
    # Learnt on the solid body only and carried out from it: a soft shadow has no features, and flow of its own
    # stretched it over the input's shadow.
    solid = cv2.resize(alpha * covered, (flow.shape[1], flow.shape[0]), interpolation=cv2.INTER_AREA) > 0.9
    blur = lambda x: cv2.GaussianBlur(x, (0, 0), FLOW_SIGMA * short * s)
    weight = blur(solid.astype(np.float32))
    flow = blur(flow * solid[..., None]) / np.maximum(weight, 0.05)[..., None]
    # Kept only where it brings the cutout closer to the input: on a glossy body ChatGPT redraws the reflections,
    # and flow matched one reflection to another, 40 px of nothing.
    grid_x, grid_y = np.meshgrid(np.arange(flow.shape[1], dtype=np.float32), np.arange(flow.shape[0], dtype=np.float32))
    shifted = cv2.remap(moving, grid_x + flow[..., 0], grid_y + flow[..., 1], cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_REPLICATE)
    before, after = blur(np.abs(still - moving)), blur(np.abs(still - shifted))
    # A third less mismatch takes the whole shift: half a shift is a ghost of its own.
    flow *= np.clip(3 * (before - after) / np.maximum(before, 4), 0, 1)[..., None]
    if s < 1:
        flow = cv2.resize(flow, (width, height), interpolation=cv2.INTER_LINEAR) / s
    magnitude = np.hypot(flow[..., 0], flow[..., 1])
    return flow * np.minimum(1, FLOW_LIMIT * short / np.maximum(magnitude, 1e-6))[..., None]


def align(base: np.ndarray, premultiplied: np.ndarray, alpha: np.ndarray, covered: np.ndarray):
    """Local correction after the global similarity: ChatGPT redraws parts slightly displaced (a pickup's rear 20 px
    off while its body sits exact), and a band of its pixels next to the input's own then shows the part twice. The
    local flow moves the cutout's pixels and alpha onto the input."""
    height, width = alpha.shape
    flow = local_flow(base, premultiplied, alpha, covered)
    grid_x, grid_y = np.meshgrid(np.arange(width, dtype=np.float32), np.arange(height, dtype=np.float32))
    map_x, map_y = grid_x + flow[..., 0], grid_y + flow[..., 1]
    move = lambda x, border: cv2.remap(x, map_x, map_y, cv2.INTER_LINEAR, borderMode=border)
    subject = alpha > 0.5
    moved = float(np.percentile(np.hypot(flow[..., 0], flow[..., 1])[subject], 99)) if subject.any() else 0.0
    return (move(premultiplied, cv2.BORDER_REPLICATE), move(alpha, cv2.BORDER_REPLICATE),
            move(covered.astype(np.float32), cv2.BORDER_CONSTANT) > 0.999, moved)


def matte(base_path: str, cut_path: str, out: str) -> str:
    base_image = ImageOps.exif_transpose(Image.open(base_path))
    icc = base_image.info.get("icc_profile")
    base = np.asarray(base_image.convert("RGB"))
    cut_rgba = np.asarray(Image.open(cut_path).convert("RGBA"))
    cut, alpha = np.ascontiguousarray(cut_rgba[..., :3]), np.ascontiguousarray(cut_rgba[..., 3])
    matrix = register(base, cut, alpha)
    if matrix is None:
        return "composite=skipped reason=unregistered"
    height, width = base.shape[:2]

    def warp(image: np.ndarray, border: int) -> np.ndarray:
        return cv2.warpAffine(image, matrix, (width, height), flags=cv2.INTER_LINEAR, borderMode=border)

    # Premultiplied, or the colour hidden under transparent pixels bleeds into every edge pixel.
    a = alpha.astype(np.float32) / 255
    warped_a = warp(a, cv2.BORDER_REPLICATE)
    premultiplied = warp(cut.astype(np.float32) * a[..., None], cv2.BORDER_REPLICATE)
    covered = warp(np.ones_like(a), cv2.BORDER_CONSTANT) > 0.999
    premultiplied, warped_a, covered, moved = align(base.astype(np.float32), premultiplied, warped_a, covered)
    warped_a = np.clip(warped_a, 0, 1)
    rendered = premultiplied / np.maximum(warped_a, 1e-3)[..., None]
    core = (warped_a > 0.98) & covered
    if core.mean() < 0.005:
        return "composite=skipped reason=unregistered"

    # Local tone match in Lab, estimated on the core and spread into the edge band by normalised blur.
    short = min(height, width)
    scale = min(1.0, 400 / short)
    small = lambda x: cv2.resize(x, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    lab = lambda rgb: cv2.cvtColor(np.clip(rgb / 255, 0, 1).astype(np.float32), cv2.COLOR_RGB2LAB)
    base_lab, rendered_lab = lab(base.astype(np.float32)), lab(rendered)
    # Tone is learnt only where both show the same surface: where ChatGPT drew fur over the input's green screen,
    # the difference is the screen, and spread into the band it painted clean strands green.
    distance = np.linalg.norm(base_lab - rendered_lab, axis=-1)
    agree = core & (distance < max(AGREE_DE, 3 * float(np.median(distance[core]))))
    if not agree.any():
        agree = core
    weight = small(agree.astype(np.float32))
    sigma = TONE_SIGMA * short * scale
    spread = lambda x: cv2.GaussianBlur(x, (0, 0), sigma)
    norm = spread(weight)
    shift = (spread(small(base_lab - rendered_lab) * weight[..., None]) / np.maximum(norm, 1e-6)[..., None])
    fallback = (base_lab - rendered_lab)[agree].mean(0)
    shift = np.where((norm > 0.05)[..., None], shift, fallback).astype(np.float32)
    shift = cv2.resize(shift, (width, height), interpolation=cv2.INTER_LINEAR)
    toned = cv2.cvtColor(rendered_lab + shift, cv2.COLOR_LAB2RGB) * 255

    radius = max(3, round(BAND * short))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1))
    inner = cv2.GaussianBlur(cv2.erode(core.astype(np.float32), kernel), (0, 0), radius / 3)
    inner = np.maximum(inner, ~covered)
    # The backdrop's own colour, local (a gradient, a shadow), from what the cutout left transparent.
    clear = small((warped_a < 0.02).astype(np.float32))
    clear_norm = cv2.GaussianBlur(clear, (0, 0), sigma)
    backdrop = cv2.GaussianBlur(small(base.astype(np.float32)) * clear[..., None], (0, 0), sigma)
    backdrop = cv2.resize(backdrop / np.maximum(clear_norm, 1e-6)[..., None], (width, height),
                          interpolation=cv2.INTER_LINEAR)
    known = cv2.resize(clear_norm, (width, height), interpolation=cv2.INTER_LINEAR) > 0.02
    # A coloured screen leaks into the input's pixels (between strands, through glass) where the cutout has subject:
    # their hue pulled toward the screen's beyond the cutout's own colour. Those pixels come from the cutout.
    backdrop_lab = lab(backdrop)
    chroma = np.hypot(backdrop_lab[..., 1], backdrop_lab[..., 2])
    hue = backdrop_lab[..., 1:] / np.maximum(chroma, 1e-6)[..., None]
    screened = known & (chroma > SCREEN_CHROMA)
    pull = lambda rgb: np.where(screened, ((lab(rgb)[..., 1:] - rendered_lab[..., 1:]) * hue).sum(-1), 0)
    screen = np.clip((pull(base.astype(np.float32)) - SCREEN_PULL / 2) / (SCREEN_PULL / 2), 0, 1).astype(np.float32)
    inner = inner * (1 - np.maximum(screen, cv2.GaussianBlur(screen, (0, 0), 1.5)))
    # Past the cutout's own frame (ChatGPT reframes smaller) its edge alpha is only replicated over the input's
    # pixels: what of them shows the screen is cut, or a replicated soft shadow showed the green.
    warped_a = np.where(covered, warped_a, warped_a * (1 - screen))
    band = core & (inner < 0.5) & (screen < 0.5)  # the screen's own pixels differ by design, not a redraw
    if band.any() and (redrawn := float(np.abs(toned - base)[band].mean())) > REDRAWN_LIMIT:
        limit_hit.hit("image-matte.redrawn", REDRAWN_LIMIT, "count", "fallback",
                      f"the matte composite of {os.path.basename(out)}: skipped, the result stays uncomposited",
                      "share/image_matte.py:REDRAWN_LIMIT = ", observed=redrawn)
        return "composite=skipped reason=redrawn"

    rgb = base * inner[..., None] + toned * (1 - inner[..., None])
    subject = warped_a > 0.5
    # Self-check: what the alignment left displaced where the cutout's own pixels meet the input's (a ghost).
    shown = subject & (inner < 0.9) & (inner > 0.1)
    # Across the input's own edges only: along a long straight edge any shift matches, and none of it shows.
    residual = local_flow(base.astype(np.float32), premultiplied, warped_a, covered)
    luma = cv2.GaussianBlur(cv2.cvtColor(base, cv2.COLOR_RGB2GRAY).astype(np.float32), (0, 0), 1.5)
    gx, gy = cv2.Sobel(luma, cv2.CV_32F, 1, 0), cv2.Sobel(luma, cv2.CV_32F, 0, 1)
    edge = np.hypot(gx, gy)
    across = np.abs(residual[..., 0] * gx + residual[..., 1] * gy) / np.maximum(edge, 1e-6)
    shown &= edge > 20
    ghost = float(np.percentile(across[shown], 99)) if shown.any() else 0.0
    # Self-check: screen colour left in the delivered subject, densest place (a fringe is small against the whole).
    leak = (subject & (pull(rgb) > SCREEN_PULL)).astype(np.float32)
    residue = 100 * float(cv2.GaussianBlur(leak, (0, 0), 2 * radius).max())
    if 100 * ghost / short > GHOST_LIMIT:
        limit_hit.hit("image-matte.ghost", GHOST_LIMIT, "pct", "fallback",
                      f"the matte composite of {os.path.basename(out)}: skipped, a part would show twice",
                      "share/image_matte.py:GHOST_LIMIT = ", observed=round(100 * ghost / short, 2))
        return "composite=skipped reason=ghost"
    if residue > RESIDUE_LIMIT:
        limit_hit.hit("image-matte.residue", RESIDUE_LIMIT, "pct", "fallback",
                      f"the matte composite of {os.path.basename(out)}: skipped, the screen's colour would show",
                      "share/image_matte.py:RESIDUE_LIMIT = ", observed=residue)
        return "composite=skipped reason=residue"
    rgba = np.dstack([rgb, warped_a * 255])
    changed = 100 * ((1 - inner) > 0.5)[subject].mean() if subject.any() else 0.0
    save(Image.fromarray(np.clip(np.rint(rgba), 0, 255).astype(np.uint8), "RGBA"), out, icc)
    return f"composite=matte changed={changed:.1f}% moved={moved:.1f}px ghost={ghost:.1f}px residue={residue:.1f}%"


def save(image: Image.Image, out: str, icc: bytes | None) -> None:
    directory, name = os.path.split(os.path.abspath(out))
    handle, temporary = tempfile.mkstemp(prefix=f".{name}.", suffix=".png", dir=directory)
    os.close(handle)
    try:
        image.save(temporary, format="PNG", **({"icc_profile": icc} if icc else {}))
        os.replace(temporary, out)
    except BaseException:
        os.unlink(temporary)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the image the cutout was made from")
    parser.add_argument("--edited", required=True, help="the generative cutout (RGBA)")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        print(matte(args.base, args.edited, args.out))
    except (OSError, ValueError, cv2.error) as error:
        print(f"image_matte: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
