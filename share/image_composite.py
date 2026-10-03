# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "scipy==1.18.1"]
# ///
"""Paste only the changed part of an edited image back onto its untouched input.

Every image model re-renders the whole picture on an edit, so a chain of local edits drifts the
parts nobody asked to change. The mask comes from a rectangle (x,y,w,h fractions, the shape of
`codex-image --region`), from points (fractions; the changed areas touching them) or from the
difference map (`auto`). One stdout line: `composite=<auto|region|points> changed=<percent>`; a mask
over GLOBAL_LIMIT of the image means the edit was global (`composite=refused reason=global`) and an
edited image of another aspect is no edit of this input (`composite=skipped reason=aspect-changed`):
both deliver the edited image as is. Exit 0 delivered (composited or not), 1 unreadable input, 2 usage.
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile

import numpy as np
from PIL import Image
from scipy import ndimage

GLOBAL_LIMIT = 0.60
ASPECT_TOLERANCE = 0.01
FLOOR = 6.0
WORK_SIDE = 640
SRGB_TO_XYZ = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
D65 = np.array([0.9505, 1.0, 1.089])


def parse_region(text: str) -> tuple[float, float, float, float]:
    values = [float(part) for part in text.split(",")]
    if len(values) != 4:
        raise ValueError(text)
    x, y, w, h = values
    if not (x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 1 and y + h <= 1):
        raise ValueError(text)
    return x, y, w, h


def parse_point(text: str) -> tuple[float, float]:
    x, y = (float(part) for part in text.partition("=")[0].split(","))
    if not (0 <= x <= 1 and 0 <= y <= 1):
        raise ValueError(text)
    return x, y


def disk(radius: int) -> np.ndarray:
    radius = max(1, int(round(radius)))
    grid = np.arange(-radius, radius + 1)
    return grid[:, None] ** 2 + grid[None, :] ** 2 <= radius * radius


def lab(rgb: np.ndarray) -> np.ndarray:
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    xyz = linear @ SRGB_TO_XYZ.T / D65
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], axis=2)


def difference(base: np.ndarray, edited: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(change above the model's whole-picture tint, raw change), both in Lab ΔE."""
    sigma = max(1.0, min(base.shape[:2]) / 400)
    delta = ndimage.gaussian_filter(lab(edited) - lab(base), sigma=(sigma, sigma, 0))
    tint = np.median(delta.reshape(-1, delta.shape[2]), axis=0)
    return np.sqrt(((delta - tint) ** 2).sum(axis=2)), np.sqrt((delta**2).sum(axis=2))


def thresholds(magnitude: np.ndarray) -> tuple[float, float]:
    median = float(np.median(magnitude))
    spread = 1.4826 * float(np.median(np.abs(magnitude - median)))
    low = max(median + 6 * spread, 3 * median, FLOOR)
    return low, max(2 * low, 15.0)


def changed_regions(base: np.ndarray, edited: np.ndarray) -> np.ndarray | None:
    """None when the edit is global."""
    side = min(base.shape[:2])
    magnitude, raw = difference(base, edited)
    if (raw > FLOOR).mean() > GLOBAL_LIMIT:
        return None
    low, high = thresholds(magnitude)
    weak = magnitude > low
    labels, count = ndimage.label(weak)
    if not count:
        return weak
    seeded = np.zeros(count + 1, bool)
    seeded[np.unique(labels[magnitude > high])] = True
    sizes = np.bincount(labels.ravel(), minlength=count + 1)
    seeded &= sizes >= max(4, side * side * 1e-4)
    seeded[0] = False
    return seeded[labels]


def near_points(regions: np.ndarray, points: list[tuple[float, float]]) -> np.ndarray:
    height, width = regions.shape
    labels, count = ndimage.label(ndimage.binary_closing(regions, disk(min(height, width) / 100)))
    keep = np.zeros(count + 1, bool)
    reach = min(height, width) * 0.06
    for x, y in points:
        row = min(height - 1, int(y * height))
        col = min(width - 1, int(x * width))
        if labels[row, col]:
            keep[labels[row, col]] = True
            continue
        top, left = max(0, int(row - reach)), max(0, int(col - reach))
        window = labels[top : int(row + reach) + 1, left : int(col + reach) + 1]
        rows, cols = np.nonzero(window)
        if rows.size:
            nearest = np.argmin((rows + top - row) ** 2 + (cols + left - col) ** 2)
            keep[window[rows[nearest], cols[nearest]]] = True
    keep[0] = False
    return keep[labels]


def tidy(regions: np.ndarray) -> np.ndarray:
    side = min(regions.shape)
    closed = ndimage.binary_closing(regions, disk(side / 60), border_value=0)
    filled = ndimage.binary_fill_holes(closed | regions)
    return ndimage.binary_dilation(filled, disk(side / 120))


def rectangle(shape: tuple[int, int], region: tuple[float, float, float, float]) -> np.ndarray:
    height, width = shape
    x, y, w, h = region
    mask = np.zeros(shape, bool)
    mask[round(y * height) : round((y + h) * height), round(x * width) : round((x + w) * width)] = True
    return mask


def feather(hard: np.ndarray) -> np.ndarray:
    sigma = max(0.5, min(hard.shape) / 250)
    return ndimage.gaussian_filter(hard.astype(np.float32), sigma)


def border_offset(base: np.ndarray, edited: np.ndarray, hard: np.ndarray) -> np.ndarray:
    side = min(hard.shape)
    # A drawn rectangle can cut through the edit itself; only drift-sized differences are colour to match.
    drifted = difference(base, edited)[1] <= 2 * FLOOR
    ring = ndimage.binary_dilation(hard, disk(side / 50)) & ~hard & drifted
    if not ring.any():
        return np.zeros(base.shape, np.float32)
    residual = ndimage.gaussian_filter(base - edited, sigma=(side / 300, side / 300, 0))
    sigma = side / 12
    weight = ndimage.gaussian_filter(ring.astype(np.float32), sigma)
    fallback = np.median(residual[ring], axis=0)
    offset = np.empty_like(base)
    for channel in range(base.shape[2]):
        spread = ndimage.gaussian_filter(residual[..., channel] * ring, sigma)
        offset[..., channel] = np.where(weight > 1e-3, spread / np.maximum(weight, 1e-3), fallback[channel])
    return offset


def resized(plane: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    image = Image.fromarray(plane.astype(np.float32))
    return np.asarray(image.resize((shape[1], shape[0]), Image.Resampling.BILINEAR), np.float32)


def working(image: Image.Image) -> Image.Image:
    scale = WORK_SIDE / max(image.size)
    if scale >= 1:
        return image
    return image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.BOX)


def as_float(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("RGB"), np.float32) / 255


def opened(path: str, size: tuple[int, int] | None = None) -> Image.Image:
    image = Image.open(path)
    image.load()
    if size and image.size != size:
        image = image.resize(size, Image.Resampling.LANCZOS)
    return image


def composite(base: str, edited: str, out: str, mask_source, mask_out: str | None = None, target: str | None = None) -> str:
    """mask_source: "auto", an (x, y, w, h) fraction tuple, or a list of (x, y) fraction points.
    target: the image the patch is pasted onto when it is not `base` itself."""
    base_image = opened(base)
    edited_image = opened(edited)
    if abs(edited_image.width * base_image.height / (edited_image.height * base_image.width) - 1) > ASPECT_TOLERANCE:
        deliver(edited, out)
        return (f"composite=skipped reason=aspect-changed from={base_image.width}x{base_image.height}"
                f" to={edited_image.width}x{edited_image.height}")
    edited_image = opened(edited, base_image.size)
    small_base, small_edited = as_float(working(base_image)), as_float(working(edited_image))
    if isinstance(mask_source, tuple):
        kind, hard = "region", rectangle(small_base.shape[:2], mask_source)
    else:
        kind = "auto" if mask_source == "auto" else "points"
        hard = changed_regions(small_base, small_edited)
        if hard is not None:
            hard = tidy(hard if kind == "auto" else near_points(hard, list(mask_source)))
    refusal = ""
    if hard is None or hard.mean() > GLOBAL_LIMIT:
        refusal = "global"
    elif not hard.any():
        refusal = "no-local-change"
    if refusal:
        deliver(edited, out)
        share = (difference(small_base, small_edited)[1] > FLOOR).mean() if hard is None else hard.mean()
        return f"composite=refused reason={refusal} changed={float(share) * 100:.1f}% kind={kind}"
    alpha = np.clip(resized(feather(hard), base_image.size[::-1]), 0, 1)
    if mask_out:
        Image.fromarray(np.round(alpha * 255).astype(np.uint8)).save(mask_out)
    if target:
        base_image = opened(target, base_image.size)
        small_base = as_float(working(base_image))
    offset = border_offset(small_base, small_edited, hard)
    offset_full = np.stack([resized(offset[..., c], base_image.size[::-1]) for c in range(3)], axis=2)
    patch = np.clip(as_float(edited_image) + offset_full, 0, 1)
    blended = as_float(base_image) * (1 - alpha[..., None]) + patch * alpha[..., None]
    result = Image.fromarray(np.round(blended * 255).astype(np.uint8))
    if base_image.has_transparency_data and not out.lower().endswith((".jpg", ".jpeg")):
        result.putalpha(base_image.convert("RGBA").getchannel("A"))
    save(result, out)
    return f"composite={kind} changed={float(alpha.mean()) * 100:.1f}%"


def deliver(edited: str, out: str) -> None:
    if os.path.abspath(edited) != os.path.abspath(out):
        shutil.copyfile(edited, out)


def save(image: Image.Image, out: str) -> None:
    directory, name = os.path.split(os.path.abspath(out))
    handle, temporary = tempfile.mkstemp(prefix=f".{name}.", suffix=os.path.splitext(name)[1], dir=directory)
    os.close(handle)
    try:
        options = {"quality": 95} if name.lower().endswith((".jpg", ".jpeg", ".webp")) else {}
        image.save(temporary, **options)
        os.replace(temporary, out)
    except BaseException:
        os.unlink(temporary)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--edited", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--mask", default="auto", help="auto or x,y,w,h fractions")
    parser.add_argument("--point", action="append", default=[], help="x,y fractions (=text ignored)")
    parser.add_argument("--mask-out")
    args = parser.parse_args()
    try:
        if args.point:
            if args.mask != "auto":
                parser.error("--point and a --mask rectangle exclude each other")
            source = [parse_point(point) for point in args.point]
        else:
            source = "auto" if args.mask == "auto" else parse_region(args.mask)
    except ValueError as error:
        parser.error(f"bad fraction: {error}")
    try:
        print(composite(args.base, args.edited, args.out, source, args.mask_out))
    except (OSError, ValueError) as error:
        print(f"image_composite: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
