#!/usr/bin/env python3
"""A logo or icon bitmap to SVG by an OpenAI text model on the API, for `logo-vectorize --engine openai` only (paid,
on Egor's ask; the default engine is the free local tracer).

  openai_svg.py --in <abs image> --dest <abs .svg>

One Responses call and nothing else: the model reads the image itself (its long side scaled to the manifest's
`api_svg.long_side`, 1200 px: fewer pixels lost a boat's outline on a 487 px logo, 2026-11-06) and writes the SVG.
The Images API's own SVG route (`output_format: "svg"` + `svg.model`) first redraws the picture as a raster
reference, which cost about twice as much and pushed the logo's mint greens to lime. Keys come from
$OPENAI_KEYS in file order, each skipped while the key state shared with the dictation daemon holds it; a quota or
auth refusal holds that key there and moves on. Prints `svg= engine=openai model= account= source= sent= seconds=
input_tokens= output_tokens=`; never prints a key. Exit 1 the call or its SVG failed, 2 usage, 3 every key held or
refused."""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from key_state import keystate  # noqa: E402
from openai_api_keys import KEYS, VENDOR  # noqa: E402

MANIFEST = Path(__file__).resolve().parent / "image-caps" / "codex.json"
URL = os.environ.get("OPENAI_SVG_URL") or "https://api.openai.com/v1/responses"
TIMEOUT_S = 900
PROMPT = """Convert this {w}x{h} image into one standalone SVG that reproduces it as closely as possible.
- Root: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">.
- Keep every element, shape, silhouette, line and proportion at the same position and size.
- Take colours exactly from the image as hex; where it has smooth colour ramps use linearGradient or radialGradient with stops taken from the image; flat areas stay flat.
- Leave transparent whatever is transparent in the image: no background behind it.
- Vector shapes only: no <image>, no embedded raster, no script, no external reference.
- Reply with the SVG code only: no prose, no code fence."""


def fail(code: int, message: str):
    print(f"logo-vectorize: {message}", file=sys.stderr)
    sys.exit(code)


def size_of(path: str) -> tuple[int, int]:
    out = subprocess.run(["magick", "identify", "-format", "%w %h\n", path + "[0]"], capture_output=True, text=True)
    if out.returncode or not out.stdout.strip():
        fail(2, f"cannot read {path} as an image")
    w, h = out.stdout.split()[:2]
    return int(w), int(h)


def scaled_png(path: str, long_side: int) -> tuple[bytes, int, int]:
    """The image as PNG with its long side at long_side (up or down), and its new size."""
    out = subprocess.run(["magick", path + "[0]", "-filter", "Lanczos", "-resize", f"{long_side}x{long_side}",
                          "png:-"], capture_output=True)
    if out.returncode:
        fail(2, f"cannot scale {path}: {out.stderr.decode(errors='replace').strip()[:200]}")
    w, h = int.from_bytes(out.stdout[16:20], "big"), int.from_bytes(out.stdout[20:24], "big")
    return out.stdout, w, h


def keys() -> list[tuple[str, str]]:
    """(key, account) of every key line the shared key state does not hold now."""
    try:
        lines = KEYS.read_text().splitlines()
    except OSError as error:
        fail(3, f"no OpenAI keys ({error})")
    found = [(parts[0], parts[1]) for parts in (line.split() for line in lines)
             if len(parts) >= 2 and not parts[0].startswith("#")]
    return [(key, account) for key, account in found if not keystate.held(VENDOR, key)]


def svg_of(text: str, w: int, h: int, width: int, height: int) -> str:
    """The reply's SVG, checked, its root sized to the source while the viewBox stays the sent picture's."""
    found = re.search(r"<svg\b.*</svg>", text, re.S)
    if not found:
        fail(1, "the reply holds no <svg> element")
    svg = found.group(0)
    try:
        root = ET.fromstring(svg)
    except ET.ParseError as error:
        fail(1, f"the reply's SVG does not parse: {error}")
    for node in root.iter():
        tag = node.tag.rsplit("}", 1)[-1]
        refs = [value for name, value in node.attrib.items() if name.rsplit("}", 1)[-1] == "href"]
        if tag in ("image", "script", "foreignObject") or any(not ref.startswith("#") for ref in refs):
            fail(1, f"the reply's SVG carries <{tag}> or an outside reference")
    head = re.match(r"<svg\b[^>]*>", svg).group(0)
    new = re.sub(r'\s(width|height|viewBox)="[^"]*"', "", head)[:-1]
    return svg.replace(head, f'{new} viewBox="0 0 {w} {h}" width="{width}" height="{height}">', 1)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--dry-run", action="store_true", help="print what would be sent, call nothing")
    args = ap.parse_args(argv)
    spec = json.loads(MANIFEST.read_text()).get("api_svg") or fail(1, f"{MANIFEST} has no api_svg")
    width, height = size_of(args.src)
    image, w, h = scaled_png(args.src, int(spec["long_side"]))
    if args.dry_run:
        print(f"engine=openai model={spec['model']} source={width}x{height} sent={w}x{h} keys={len(keys())} (no call)")
        return 0
    body = json.dumps({"model": spec["model"], "max_output_tokens": int(spec["max_output_tokens"]), "input": [
        {"role": "user", "content": [
            {"type": "input_text", "text": PROMPT.format(w=w, h=h)},
            {"type": "input_image", "detail": "high",
             "image_url": "data:image/png;base64," + base64.b64encode(image).decode()}]}]}).encode()
    started = time.time()
    for key, account in keys():
        request = urllib.request.Request(URL, data=body, method="POST", headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
                reply = json.load(response)
        except urllib.error.HTTPError as error:
            text = error.read()
            why, seconds = keystate.classify(error.code, text, dict(error.headers))
            if why:
                keystate.hold(VENDOR, key, why, time.time() + seconds)
                print(f"logo-vectorize: OpenAI key of {account} refused ({why}); next key", file=sys.stderr)
                continue
            fail(1, f"OpenAI answered {error.code}: {text.decode(errors='replace')[:300]}")
        except (urllib.error.URLError, TimeoutError) as error:
            fail(1, f"OpenAI call failed: {error}")
        if reply.get("status") not in (None, "completed"):
            fail(1, f"the reply ended {reply.get('status')}: {json.dumps(reply.get('incomplete_details'))}")
        text = "".join(part.get("text", "") for item in reply.get("output") or [] if item.get("type") == "message"
                       for part in item.get("content") or [])
        Path(args.dest).write_text(svg_of(text, w, h, width, height))
        usage = reply.get("usage") or {}
        print(f"svg={args.dest} engine=openai model={reply.get('model') or spec['model']} account={account} "
              f"source={width}x{height} sent={w}x{h} seconds={round(time.time() - started)} "
              f"input_tokens={usage.get('input_tokens')} output_tokens={usage.get('output_tokens')}")
        return 0
    fail(3, f"every OpenAI key in {KEYS} is held or refused (see `llm-limits` OpenAI rows)")


if __name__ == "__main__":
    sys.exit(main())
