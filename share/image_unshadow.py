# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.5.3", "pillow==12.3.0", "opencv-python-headless==5.0.0.93", "scipy==1.18.1"]
# ///
"""The floor shadow out of a generative cut-out laid in the input's frame: shadows are separate layers.

ChatGPT keeps a shadow it was asked to keep, and Remove BG sometimes keeps one; the object never carries it
(the grey, colour or GPT shadow layer goes under it). The rule is share/ck_shadow.py's strip_shadow: outside the
silhouette, darker than the backdrop's plate, no fine texture (hair strands keep their alpha). The file is
rewritten in place only when something was stripped. One stdout line: `unshadow=<px stripped>`.
Exit 0 done, 1 unreadable input or another frame, 2 usage.
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import ck_shadow  # noqa: E402
from image_matte import save  # noqa: E402


def unshadow(base_path: str, cutout_path: str) -> str:
    base_image = ImageOps.exif_transpose(Image.open(base_path))
    icc = base_image.info.get("icc_profile")
    frame = np.asarray(base_image.convert("RGB"), np.float32) / 255
    cutout = np.asarray(Image.open(cutout_path).convert("RGBA")).copy()
    if cutout.shape[:2] != frame.shape[:2]:
        raise ValueError(f"{cutout_path} is {cutout.shape[1]}x{cutout.shape[0]}, the input "
                         f"{frame.shape[1]}x{frame.shape[0]}: the cut-out must be laid in the input's frame")
    alpha = cutout[..., 3].astype(np.float32) / 255
    stripped = ck_shadow.strip_shadow(frame, alpha)
    lost = int(((alpha - stripped) > 0.02).sum())
    if lost:
        cutout[..., 3] = np.clip(np.round(stripped * 255), 0, 255).astype(np.uint8)
        save(Image.fromarray(cutout, "RGBA"), cutout_path, icc)
    return f"unshadow={lost}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the input the cut-out was laid onto")
    parser.add_argument("--cutout", required=True, help="the laid cut-out (RGBA), rewritten in place")
    args = parser.parse_args()
    try:
        print(unshadow(args.base, args.cutout))
    except (OSError, ValueError) as error:
        print(f"image_unshadow: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
