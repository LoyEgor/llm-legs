# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93", "scipy==1.18.1"]
# ///
"""See-through glass from a keyer or a second cut-out into a generative cut-out, cut along the window frames.

ChatGPT's Remove BG (laid back by image_matte.py) gives the best outline and hair, but draws glass solid: the
screen seen through a windscreen stays in the picture. A see-through source does better there: a keyer on a coloured
screen (CorridorKey), or on any backdrop ChatGPT asked in words for see-through glass, laid back the same way (pass
its RGBA as both --key-alpha and --key-fg). Both deliveries are in the input's frame, so a pane moves from that
source into the cut-out pixel for pixel, alpha and colour, no blur. The cut is placed only where the two
deliveries already show the same pixel (the frame round a window), so the seam cannot be seen; a pane with no such
frame round it (a bottle, a sheer dress: the glass reaches the outline) is refused, never cut across the glass.

Candidates: inside the cut-out's solid body, where the source sees through (alpha < 0.9). Each is drawn numbered
on --overlay; by default every pane with a closed frame is taken, --take picks numbers (a green reflection on
paint is not glass: leave its number out) or none.
One stdout line: `fuse=glass taken=<n,...> candidates=<n:px:closed|open,...> step=<max seam step 0..255>
overlay=<path>`, or `fuse=skipped reason=no-glass|no-frame|none-taken candidates=…` (nothing written: deliver
the cut-out as is). Exit 0 done or skipped, 1 unreadable input, 2 usage.
"""
from __future__ import annotations

import argparse
import os
import sys

import cv2
import numpy as np
from PIL import Image, ImageOps
from scipy import ndimage as ndi

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from image_matte import save  # noqa: E402

SOLID = 0.95  # the cut-out's body: ChatGPT keeps a car's body near 0.98, not 1
KEY_SOLID = 0.999  # the keyer's opaque pixels are the input's own bytes
SEE = 0.9  # the keyer sees through below this
MIN_AREA = 1e-5  # of the frame (20 px at 1920x1080): smaller patches are keyer noise
STEPS = (4, 6, 10)  # 0..255: the largest difference the seam may run over, tried smallest first
COLOURS = [(255, 0, 255), (0, 200, 255), (255, 200, 0), (0, 255, 120), (255, 120, 60), (120, 120, 255)]


def load_alpha(path: str) -> np.ndarray:
    image = Image.open(path)
    if image.mode in ("1", "P"):  # a two-tone matte saved as bits or a palette
        image = image.convert("L")
    alpha = np.asarray(image.getchannel("A") if image.mode in ("RGBA", "LA") else image).astype(np.float32)
    if alpha.ndim == 3:  # a grey matte saved as RGB: its channels are equal
        alpha = alpha[..., 0]
    return alpha / (65535 if image.mode.startswith("I") or alpha.max() > 255 else 255)


def fuse(base_path: str, gpt_path: str, key_alpha_path: str, key_fg_path: str, out: str, overlay: str | None,
         take: str) -> str:
    base_image = ImageOps.exif_transpose(Image.open(base_path))
    icc = base_image.info.get("icc_profile")
    base = np.asarray(base_image.convert("RGB")).astype(np.float32)
    gpt = np.asarray(Image.open(gpt_path).convert("RGBA")).astype(np.float32)
    key_alpha = load_alpha(key_alpha_path)
    key_fg = np.asarray(Image.open(key_fg_path).convert("RGB")).astype(np.float32)
    height, width = base.shape[:2]
    for name, array in (("--gpt", gpt), ("--key-alpha", key_alpha), ("--key-fg", key_fg)):
        if array.shape[:2] != (height, width):
            raise ValueError(f"{name} is {array.shape[1]}x{array.shape[0]}, the input {width}x{height}: both "
                             "deliveries must be in the input's frame")
    short = min(height, width)
    # Where the keyer is opaque the pixel is the input's own, whatever colour policy the keyer runs; only its
    # see-through pixels carry its unmixed colour.
    key_fg = np.where((key_alpha >= KEY_SOLID)[..., None], base, key_fg)
    gpt_alpha, gpt_rgb = gpt[..., 3] / 255, gpt[..., :3]
    solid = gpt_alpha > SOLID

    # Where both call a pixel solid it is the input's own pixel; the cut-out's edge band carries its redraw there,
    # and a window frame near the outline would then differ only by that. Colour only, never on the antialiased rim.
    both = solid & (key_alpha >= KEY_SOLID)
    weight = (np.clip((ndi.distance_transform_edt(solid) - 1) / 3, 0, 1) * both)[..., None]
    framed_rgb = gpt_rgb * (1 - weight) + base * weight
    cost = np.maximum(np.abs(gpt_alpha - key_alpha) * 255,
                      np.abs(framed_rgb * gpt_alpha[..., None] - key_fg * key_alpha[..., None]).max(-1))

    interior = ndi.binary_erosion(solid, iterations=max(2, int(0.006 * short)))
    see = ndi.binary_opening(interior & (key_alpha < SEE))
    labels, count = ndi.label(see)
    sizes = ndi.sum(see, labels, range(1, count + 1))
    cores = [labels == index + 1 for index, size in enumerate(sizes) if size > MIN_AREA * height * width]
    if not cores:
        return "fuse=skipped reason=no-glass candidates="

    # Each pane: what differs by more than t around its core, for the smallest t that closes inside the body; the
    # seam then runs over pixels that differ by at most t.
    # A pane may run on through glass the cut-out already left partly see-through, never across its outline.
    ring = max(3, int(0.004 * short))
    inside = ndi.binary_erosion(gpt_alpha > 0.02, iterations=ring)
    above = {step: ndi.label(cost > step)[0] for step in STEPS}
    panes: list[tuple[np.ndarray, bool, int]] = []
    for core in cores:
        for step in STEPS:
            ids = np.unique(above[step][core])
            region = ndi.binary_fill_holes(np.isin(above[step], ids[ids > 0]) | core)
            closed = not (region & ~inside).any()
            if closed:
                break
        else:
            region = core  # refused: drawn as itself, never as the outline it leaked into
        for index, (other, other_closed, other_step) in enumerate(panes):
            if (other & region).any():  # two cores in one pane are one candidate
                panes[index] = (other | region, other_closed and closed, max(other_step, step))
                break
        else:
            panes.append((region, closed, step))
    panes.sort(key=lambda pane: -int(pane[0].sum()))
    listing = ",".join(f"{n}:{int(r.sum())}:{'closed' if c else 'open'}" for n, (r, c, _) in enumerate(panes, 1))

    if overlay:
        drawn = base.copy()
        marks = []
        for number, (region, closed, _) in enumerate(panes, 1):
            colour = np.array(COLOURS[(number - 1) % len(COLOURS)] if closed else (255, 0, 0), np.float32)
            drawn[region] = drawn[region] * 0.4 + colour * 0.6
            ys, xs = np.nonzero(region)
            marks.append((str(number), int(xs.mean()), int(ys.mean())))
        drawn = np.ascontiguousarray(np.clip(drawn, 0, 255).astype(np.uint8))
        scale = max(0.6, short / 900)
        for text, x, y in marks:
            for colour, thickness in (((0, 0, 0), 5), ((255, 255, 255), 2)):
                cv2.putText(drawn, text, (x - int(10 * scale), y + int(10 * scale)), cv2.FONT_HERSHEY_SIMPLEX,
                            1.2 * scale, colour, max(1, int(thickness * scale)))
        save(Image.fromarray(drawn), overlay, icc)
    tail = f" overlay={overlay}" if overlay else ""

    wanted = (set(range(1, len(panes) + 1)) if take == "all" else set() if take == "none"
              else {int(number) for number in take.split(",")})
    chosen = [number for number in sorted(wanted) if number <= len(panes) and panes[number - 1][1]]
    if not chosen:
        reason = "no-frame" if take != "none" and not any(closed for _, closed, _ in panes) else "none-taken"
        return f"fuse=skipped reason={reason} candidates={listing}{tail}"
    taken = np.zeros((height, width), bool)
    for number in chosen:
        taken |= panes[number - 1][0]
    # Only the taken panes and the frame round them change; everything else stays the cut-out's bytes.
    frame = ndi.binary_dilation(taken, iterations=ring) & ~taken
    result = gpt.copy()
    result[frame, :3] = framed_rgb[frame]
    result[taken, :3] = key_fg[taken]
    result[taken, 3] = key_alpha[taken] * 255
    save(Image.fromarray(np.clip(np.round(result), 0, 255).astype(np.uint8), "RGBA"), out, icc)
    step = max(panes[number - 1][2] for number in chosen)
    return (f"fuse=glass taken={','.join(map(str, chosen))} candidates={listing} step={step}{tail}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the input both deliveries were cut from")
    parser.add_argument("--gpt", required=True, help="the generative cut-out laid back in the input's frame (RGBA)")
    parser.add_argument("--key-alpha", required=True, 
                        help="the see-through source's alpha (8- or 16-bit grey, or an RGBA's), input's frame")
    parser.add_argument("--key-fg", required=True, 
                        help="the see-through source's colour (straight, not premultiplied), input's frame")
    parser.add_argument("--out", required=True)
    parser.add_argument("--overlay", help="where to draw the numbered candidates over the input")
    parser.add_argument("--take", default="all", help="all (default), none, or candidate numbers: 1,3")
    args = parser.parse_args()
    if args.take not in ("all", "none") and not all(part.isdigit() for part in args.take.split(",")):
        parser.error(f"--take is all, none or numbers like 1,3, not {args.take}")
    try:
        print(fuse(args.base, args.gpt, args.key_alpha, args.key_fg, args.out, args.overlay, args.take))
    except (OSError, ValueError) as error:
        print(f"image_fuse: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
