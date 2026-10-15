# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==12.3.0", "playwright==1.61.0"]
# ///
"""Validate image inputs and rasterise SVG references before vendor dispatch."""
import base64
import io
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageStat


def rasterise(path):
    from playwright.sync_api import sync_playwright
    from gemini_web import SOURCE_APP, chrome_binary

    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=chrome_binary(SOURCE_APP), headless=True)
        try:
            page = browser.new_page()
            page.route("**/*", lambda route: route.abort())
            svg = path.read_bytes()
            url = "data:image/svg+xml;base64," + base64.b64encode(svg).decode()
            size = page.evaluate("""async url => {
                const img = new Image(); img.src = url; await img.decode();
                return [img.naturalWidth, img.naturalHeight];
            }""", url)
            scale = 1024 / max(size)
            width, height = [max(1, round(n * scale)) for n in size]
            page.set_viewport_size({"width": width, "height": height})
            page.set_content('<style>html,body{margin:0;background:transparent}img{width:100vw;height:100vh}</style><img>')
            page.locator("img").evaluate("async (img, url) => { img.src = url; await img.decode(); }", url)
            return page.screenshot(omit_background=True)
        finally:
            browser.close()


def prepare(path):
    rendered = rasterise(path) if path.suffix.lower() == ".svg" else None
    with Image.open(io.BytesIO(rendered) if rendered else path) as source:
        if source.mode.startswith("I;16") or (source.mode == "I" and source.format == "PNG"):
            source = source.convert("F").point(lambda value: value / 257).convert("L")
        rgba = source.convert("RGBA")
    deviations = [ImageStat.Stat(rgba.getchannel("A")).stddev[0]]
    for color in ("white", "black"):
        flat = Image.alpha_composite(Image.new("RGBA", rgba.size, color), rgba)
        deviations.append(ImageStat.Stat(flat.convert("L")).stddev[0])
    if max(deviations) < 0.5:
        raise ValueError(f"blank reference: {path} (uniform image; an SVG rasterised without its viewBox?)")
    if rendered is None:
        return str(path)
    with tempfile.NamedTemporaryFile(prefix="image-input-", suffix=".png", delete=False) as output:
        output.write(rendered)
        return output.name


if __name__ == "__main__":
    path = Path(sys.argv[1])
    try:
        print(prepare(path))
    except Exception as exc:
        print(str(exc).replace("\n", " ") if str(exc).startswith("blank reference:")
              else f"cannot read image: {path} ({str(exc).splitlines()[0]})", file=sys.stderr)
        sys.exit(2)
