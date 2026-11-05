# Hand-off: CorridorKey as the harness's keyer (evaluate first, then integrate)

Status: open

To: the chat Egor opens for it. He drives the tests and talks to you directly, in Russian, plain words.
From: the Rentiva Sunlit chat (scroll camera and parallax), 2026-11-05. Facts below come from the repos' READMEs and
code read on GitHub. Nothing has been installed or run yet.

## Why

Rentiva's Sunlit home shows car sprites. These are glossy dark SUVs that reflect palms in the paint, for example
`/Volumes/Work/tmp/sunlit2/art8/cars/nissan-rogue-car.png`. The scroll camera changes the view of a car from about
16° above to about 7°, so a flat sprite reads as flat. The plan has three steps:

1. GPT key frames of the approved sprite, one from higher and one from lower.
2. A Flow video between them on a plain backdrop.
3. 12–16 frames, cut out and scrubbed by scroll on the web.

The cut-out decides the quality. Each existing option falls short:

- **Generative cut-outs** (ChatGPT Remove BG and similar) re-render the image: colour, tone, framing.
  `share/image_matte.py` exists only to undo that.
- **Plain tools** (chroma key, macOS Vision in `image-cutout`) keep the source's pixels, but their edges are weaker:
  - glass;
  - tyre-to-ground contact;
  - roof rails and antennas;
  - spill on black paint.

Egor wants a keyer of CorridorKey's class in the harness, reused by every project. He also wants to know where it is
better, where worse, and whether it works on a grey backdrop at all.

## What exists in llm-legs

- **`bin/image-cutout` + `share/image-cutout.swift`.** macOS Vision, exact pixels, instance picking, soft or hard
  edge. Stills only.
- **`share/image_matte.py`.** Keeps the input's own pixels under a generative cut-out's matte.
- **Reuse rule:** run `tools <words>` first, and extend a shared tool in place, never as a parallel copy. A stills
  engine plausibly fits under `image-cutout` (for example `--engine`). Clips and frame folders need their own entry
  point. The shape is yours to propose and Egor's to agree.

## What I found

- **CorridorKey 2.0** (`nikopueringer/CorridorKey2.0`, PyTorch):
  - **CUDA only as shipped.** `infer.py` raises without CUDA. `runtime.py` uses `torch.cuda.mem_get_info`,
    `autocast("cuda", bfloat16)` and `.cuda()`.
  - **Weights about 5 GB:** its own, plus three frozen models (C-RADIOv4-SO400M, MoGe-2 ViT-B, RVM small).
  - **Inputs:** a video or a frame folder (PNG, JPG, EXR).
  - **Hints:**
    - none;
    - a first-frame matte;
    - a full hint video, with `--hint_quality`.
  - **Temporal Hann windows**, sized from free GPU memory.
  - **Outputs:**
    - `alpha`;
    - `fg` (unmixed straight colour);
    - `checker`;
    - `cutout` (ProRes 4444, or RGBA EXR with `--output_format exr`).
  - `--despill_strength` (default 0.5) applies to `checker` and `cutout` only.
  - Trained for green and blue screens.
- **Licence:** a CC BY-NC-SA 4.0 variant.
  - Outputs may be used commercially.
  - No selling the tool and no paid API.
  - Anything released must stay free, keep the licence and keep the name.
  - Private harness use is fine. Flag it if llm-legs is ever published.
- **2.0 on a Mac:**
  - **`MarcelineVPQ/corridorkey-desktop`** is the strongest lead for headless use here. It runs CK 2.0 on Rust and
    ONNX Runtime and supports Apple Silicon (macOS 14+, "16 GB keys 4K"). It has a `corridorkey` command line and EXR
    or lossless outputs. It claims mattes within 9.5/255 of CUDA on 0.2 % of pixels. Check the wrapper's own licence.
  - **The fallback** is patching 2.0 for MPS: the device argument, the autocast device and the memory budget. A v1
    ComfyUI port reports NaNs with float16 autocast on Metal and runs float32. bfloat16 on MPS is unverified.
- **CorridorKey v1** (`nikopueringer/CorridorKey`, Hiera, 2048 native):
  - Official Mac support through MPS and MLX.
  - It needs a coarse alpha hint per frame. A Vision cut-out, eroded, could serve as that hint.
  - Green and blue checkpoints; MLX has green only.
  - `nikopueringer/corridorkey-mlx` is an MLX port with about 400 MB of weights.
  - The torch MPS GUI asks for 22–30 GB.
- **`alexandremendoncaalvaro/CorridorKey-Runtime`** is a native C++ runtime with an MLX path and a `corridorkey` CLI.
  Which model version it runs is unchecked.
- **This Mac:** Apple M4, 24 GB unified memory, no NVIDIA.

## What a Rentiva car cut-out must contain (Egor, 2026-11-05)

Today's sprite is two files (`/Volumes/Work/tmp/sunlit2/art8/cars/`):

- **`<slug>-car.png`:**
  - RGBA;
  - opaque glass (the windows show the interior and palm reflections; only a small gap by the mirror is see-through);
  - a soft contact shadow under the body as partial alpha.
- **`<slug>-shadow.png`:** the sand shadow. It is a multiply layer (white = no effect, darker = shadow), drawn with
  `mix-blend-mode: multiply`.

From video, the cut-out must deliver three things:

1. **The car**, opaque where solid.
2. **Glass that is really transparent.** Where the backdrop shows through the windows, alpha < 1 and the page
   behind shows through. Reflections are kept as colour.
3. **The shadow under and around the car as its own semi-transparent layer** (multiply, as now). The backdrop's
   colour must not ride along.

Our sprites therefore test edges and the contact shadow only: their glass is opaque.

## Telling it what is transparent and what is not

Find out, then write it down as a recipe:

- **What CorridorKey's hint means.** It takes a first-frame matte or a matte per frame, plus `--hint_quality`. Do
  grey values in the hint steer partial alpha in the glass and the shadow, or does the hint only say "this is the
  subject"? Does it keep shadows at all, and how?
- **Where the hints come from:**
  - the subject from `image-cutout` (Vision);
  - the windows as polygons on the key frames, tracked or interpolated;
  - the shadow as a floor region.
- **If hints cannot set partial alpha:**
  - CorridorKey gives only the body edge;
  - glass and shadow come from exact per-region math against the clean backdrop plate B;
  - shadow multiply = I / B inside the floor region (no ML, no recolour);
  - glass alpha from the colour distance to B, with a stated tint assumption.

## Tests (Egor drives; show him sheets and numbers, not logs)

1. **Install candidates side by side.** Each goes into its own new folder under `/Volumes/Work/tmp/corridorkey/`
   (downloads are untrusted; run their Python with `-I`). Weights stay outside llm-legs. Load one engine at a time.
2. **Test set:**
   - **Ground truth for glass and shadow.** Render it in Blender (local and free: `blender-render`,
     `docs/blender.md`). Use a car model with real glass on a shadow-catcher floor (CC0 or CC-BY; note its
     licence). Render it twice: with a transparent film, and over flat green, blue and a light-grey sweep. That gives
     the exact alpha of the glass and of the shadow.
   - **Edges and contact shadow.** Composite our sprites (alpha known) onto the same backdrops.
   - **Real case.** A short AI clip of a glossy black SUV on green and on grey. Stills via the GPT browser route are
     free. Flow, Omni or any paid run needs Egor's word for each launch, with the cost named.
   - **Hard spots:**
     - see-through glass;
     - tyre contact, and the shadow (its own layer, not part of the car);
     - roof rails and antennas;
     - green reflections on black paint;
     - motion blur.
3. **Compare against:**
   - `image-cutout` (Vision);
   - a plain chroma key with despill (ffmpeg or OpenCV);
   - one local matting net (BiRefNet or RMBG-2);
   - ChatGPT Remove BG + `image_matte.py`.
4. **Measure:**
   - matte error against the truth, in four places: overall, in the edge band, in the glass and in the shadow;
   - colour change where alpha > 0.98 (must be about 0, which answers "does it colour-correct");
   - alpha flicker across frames on still edges;
   - seconds per 1080p frame, peak memory and disk.
5. **Grey backdrop:** does any engine key it, with no hint and with a Vision first-frame hint? Recommend a backdrop
   for a glossy dark car: green keys best but spills into the paint; grey spills little but may not key.

## Pixel fidelity

Never ship a model's `fg` where the subject is opaque. Build the delivery from the source pixels where alpha ≈ 1. In
the edge band, take either:

- CorridorKey's unmixed `fg`; or
- an exact unmix against the known backdrop, F = (I − (1 − α)·B)/α, where B is a clean backdrop plate (per-pixel
  median over frames, or filled).

Compare both. Keep despill to the edge band, or off, because despill recolours. Report the share of subject pixels
whose colour differs from the source.

## Web semi-transparency

- **Stills and frame sequences:** straight (un-premultiplied) sRGB RGBA. PNG for masters; lossless or near-lossless
  WebP or AVIF with alpha for the web.
- **Halo check:** composite every result over a light and a dark page and look at the edges.
- **Video with alpha:** WebM VP9 alpha covers Chrome, Firefox and Edge; Safari needs HEVC-with-alpha `.mov`. A
  colour-plus-alpha stacked H.264 drawn in canvas or WebGL works everywhere. List the trade-offs.
- **The Rentiva car pass needs only RGBA frames.** Its chat packs them into the page.

## Deliverables

1. **A findings note for Egor.** Which engine runs on this Mac, and how fast. Where it beats or loses to
   Vision, chroma key and the matting net. The grey verdict and the backdrop recommendation.
2. **On his word, the integration.** A harness tool following llm-legs conventions (wrapper in `bin/`, docs, tests,
   findable by `tools cut out` and `tools key video`). It reads stills, clips or frame folders and writes three
   things:
   - RGBA subject frames with transparent glass;
   - a shadow multiply layer per frame;
   - one report line.

   It also takes the region hints described above.
3. **Answers back to the Rentiva chat.** Write them into this file under `## Answers`.

## Limits

- Never touch the Rentiva repo, `/Volumes/Work/tmp/rentiva-*` or ports 3200–3205.
- Paid generation needs Egor's word per launch.
- Respect the CorridorKey licence: no selling it and no serving it as a paid API.
