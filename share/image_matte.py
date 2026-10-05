# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93"]
# ///
"""Keep the input's own pixels under a generative cutout's matte.

ChatGPT's Remove BG cuts hair and fine edges better than any local matte, but it re-renders the
whole image: reframed (~0.92 scale and a shift), brighter, redrawn detail. This registers the cutout
back onto the input (SIFT, RANSAC similarity) and builds the delivery in the input's frame: the
cutout's alpha, the input's pixels inside the subject, and in an edge band the cutout's own pixels
with their tone corrected locally to the input (clean background-free strands, no colour seam).
One stdout line: `composite=matte changed=<percent of the subject from the cutout>`, or
`composite=skipped reason=unregistered|redrawn` when the cutout cannot be laid back onto the input
(nothing written: the cutout is delivered as is). Exit 0 delivered, 1 unreadable input, 2 usage.
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile

import cv2
import numpy as np
from PIL import Image, ImageOps

WORK_SIDE = 1600
MIN_INLIERS = 40
MIN_INLIER_SHARE = 0.25
REDRAWN_LIMIT = 45.0
BAND = 0.012
TONE_SIGMA = 0.04


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
    rendered = premultiplied / np.maximum(warped_a, 1e-3)[..., None]
    covered = warp(np.ones_like(a), cv2.BORDER_CONSTANT) > 0.999
    core = (warped_a > 0.98) & covered
    if core.mean() < 0.005:
        return "composite=skipped reason=unregistered"

    # Local tone match in Lab, estimated on the core and spread into the edge band by normalised blur.
    short = min(height, width)
    scale = min(1.0, 400 / short)
    small = lambda x: cv2.resize(x, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    lab = lambda rgb: cv2.cvtColor(np.clip(rgb / 255, 0, 1).astype(np.float32), cv2.COLOR_RGB2LAB)
    base_lab, rendered_lab = lab(base.astype(np.float32)), lab(rendered)
    weight = small(core.astype(np.float32))
    sigma = TONE_SIGMA * short * scale
    spread = lambda x: cv2.GaussianBlur(x, (0, 0), sigma)
    norm = spread(weight)
    shift = (spread(small(base_lab - rendered_lab) * weight[..., None]) / np.maximum(norm, 1e-6)[..., None])
    fallback = (base_lab - rendered_lab)[core].mean(0)
    shift = np.where((norm > 0.05)[..., None], shift, fallback).astype(np.float32)
    shift = cv2.resize(shift, (width, height), interpolation=cv2.INTER_LINEAR)
    toned = cv2.cvtColor(rendered_lab + shift, cv2.COLOR_LAB2RGB) * 255

    radius = max(3, round(BAND * short))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * radius + 1, 2 * radius + 1))
    inner = cv2.GaussianBlur(cv2.erode(core.astype(np.float32), kernel), (0, 0), radius / 3)
    inner = np.maximum(inner, ~covered)
    band = core & (inner < 0.5)
    if band.any() and np.abs(toned - base)[band].mean() > REDRAWN_LIMIT:
        return "composite=skipped reason=redrawn"

    rgb = base * inner[..., None] + toned * (1 - inner[..., None])
    rgba = np.dstack([rgb, warped_a * 255])
    subject = warped_a > 0.5
    changed = 100 * ((1 - inner) > 0.5)[subject].mean() if subject.any() else 0.0
    save(Image.fromarray(np.clip(np.rint(rgba), 0, 255).astype(np.uint8), "RGBA"), out, icc)
    return f"composite=matte changed={changed:.1f}%"


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
