# Hand-off: CorridorKey as the harness's keyer (evaluate first, then integrate)

Status: answered (evaluation done; integration waits for Egor's word)

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

## Egor's wider scope (2026-11-05, the evaluating chat)

The car sprite is one case. The question is how universal a cut-out CorridorKey is.

1. **Omnivorous cut-out.** Beyond green and blue: logos on a flat field, people on white, objects on a near-uniform
   tone. The bar is exact antialiased edges, with optional feathering where the edge should be soft.
2. **Against what a purpose-written tool does.** The baseline is a harness tool written for flat backdrops: backdrop
   estimate, exact unmix, subject identity from Vision or a matting net. Also compare:
   - ChatGPT Remove BG (with and without `image_matte.py`);
   - `logo-dark-adapt`'s classic remover (`core/src/bg-removal-lab.ts:removeBackgroundClassic`, flat-field logos,
     fail-closed);
   - Vision, chroma key, and one matting net, as above.
3. **A usage map.** Per job, which engine wins: logos, people and objects on stills, video clips, the car sprites.
4. **Forks and ports.** Survey Mac-optimised builds (Core ML, MLX, ONNX, native runtimes) for speed, disk and startup.
5. **Stage two, only after the verdict "we need it".** Decide the install form, the best build for this Mac
   (M4, 24 GB), its settings, its disk footprint and its startup time.

## Limits

- Never touch the Rentiva repo, `/Volumes/Work/tmp/rentiva-*` or ports 3200–3205.
- Paid generation needs Egor's word per launch.
- Respect the CorridorKey licence: no selling it and no serving it as a paid API.

## Answers

From the evaluating chat, 2026-11-06. The bench lives in `/Volumes/Work/tmp/corridorkey/` (outside llm-legs, not a
repo): `testset/`, `runs/`, `runs_real/`, `results/` (sheets, `metrics.jsonl`, `fork-survey.md`), `scripts/`.
"Page error" = mean |composite − truth composite| over a light and a dark page, /255, best of the two; lower is better.

### What runs on this Mac

- **CK 2.0 through `corridorkey-desktop` dev.9** (Rust, ONNX Runtime 1.31, Core ML), driven over its JSON-lines engine
  protocol by `scripts/ck_key.py`. 1080p: ≈2.7–2.8 s/frame, ≈37 s model load once per run, peak 3–4.1 GB. Needs ≥4
  frames: a still is keyed as 6 copies, a clip gets 3 mirrored pre-roll frames.
- **Footprint:** 16 MB binaries + 90 MB runtime + 4.4 GB models. The MLX 2.0 port is as fast at a lower fixed
  resolution and weighs 7.3 GB (fp16). CK v1 MLX needs a per-frame hint and 2.5 GB at `--tile 512`, ≈6 s/frame. The
  other ports were surveyed, not run (`results/fork-survey.md`).
- **One engine option matters:** the engine's default `carry_hint` feeds each chunk's alpha to the next chunk as its
  hint. On a push-in the carried mask lags the growing subject, and CK obeys its zeros: a straight vertical cut and
  hard blocks under the tyres on the Omni clip. `carry_hint: false` takes dropped pixels from 1580 mean / 12169 max
  per frame to ≈0, at the cost of flicker 1.9 → 2.1 /255.

### The hint

- **Grey values do not steer partial alpha** at the useful settings. At `hint_quality` 0.95 CK copies the hint's grey
  values. At 0.6 and 0.3 it ignores grey but follows zeros.
- **A zero in the hint is obeyed.** Never let the hint be smaller than the subject (see `carry_hint`).
- **The shadow never goes into the hint.** A shadow painted into the hint became alpha ≈0.23 in the car file.
- **A Vision cut-out as the hint at 0.6** fixes grey-backdrop holes in a dark body. With no hint, CK keys grey and
  white anyway (below).
- **So the recipe is "CK for the body edge, exact math for the rest"**, as the hand-off's fallback describes:
  - **Plate B:** estimated from the frame (rows plus a smooth fit).
  - **Shadow:** a multiply layer M = I/B along the plate colour, outside CK's silhouette, above the plate's noise
    floor (a ramp, no step). It reaches ≤6 px under the edge from broad shadows only, so there is no white rim.
  - **Fg:** an exact unmix against B·M in the edge band, source bytes where α ≥ 0.999.
  - **Edge rim on chroma screens:** alpha clamped between the gamut bound and the colour-difference bound, which kills
    the green line at tyre contacts. An anti-pink clamp catches over-subtraction.

### Glass

- **Screen mode** (window alpha = 1 − screen share) shows the backdrop through glass on real clips. It cannot tell
  the screen seen through glass from green bounce light on an opaque interior.
- **On Blender truth** it punched the roof and cabin: glass error 94, holes 64, against 21 / 0.5 with CK's own alpha
  in the windows. `ck_key.py` therefore defaults to `--glass ck`; `--glass screen` is opt-in for shots where the
  windows must show through.
- **Window polygons as hints** were not needed for the sprites (their glass is opaque) and were not built.

### Numbers

**Stills, page error.** Composited sprites and logos with known alpha; Blender renders with real glass and a shadow
catcher.

| engine | car blue | car green | car grey | car white | logo green | logo grey | logo navy | logo white |
|---|---|---|---|---|---|---|---|---|
| **CK2 + fuse** | 3.7 | 2.1 | 4.0 | 4.1 | 2.1 | 4.7 | 2.7 | 5.4 |
| Vision + fuse | 5.2 | 4.6 | 3.4 | 3.3 | 11.7 | 12.9 | 14.7 | 19.3 |
| BiRefNet + fuse | 3.6 | 4.0 | 3.1 | 3.0 | 14.1 | 11.0 | 13.3 | 8.5 |
| logo-classic | 6.8 | 6.4 | 11.1 | 11.1 | 2.1 | 2.7 | 2.2 | 2.1 |
| GPT + image_matte | – | 6.8 | 3.9 | 10.8 | – | – | – | – |
| Vision alone | 7.3–7.8 | 7.3–7.8 | 7.3–7.8 | 7.3–7.8 | 12–22 | 12–22 | 12–22 | 12–22 |

| Blender car (blue / green / grey / white) | page error | edge | shadow (M error) |
|---|---|---|---|
| **CK2 + fuse** | 12.5 / 12.3 / **1.9** / 8.6 | 39–42 chroma, 31–33 grey/white | 8–11 |
| Vision + fuse | 15.9 / 14.6 / 3.1 / 10.4 | 95–100 | 26–67 |
| Vision alone | 19.4 / 18.7 / 8.2 / 15.3 | 66–76 | 73 (no layer) |

**Clips.** 16 Blender frames:

| clip | edge | glass | holes | shadow M error | error flicker |
|---|---|---|---|---|---|
| green, `--glass ck` | 33.1 | 21.2 | 0.5 | 7.4 | 2.6 |
| grey | 25.6 | 25.7 | 0.3 | 6.9 | 1.9 |

**Omni clip.** 144 real frames, delivered as `runs_real/omni-hl-v3/`, keyed in 585 s (CK 409 s) with a peak of 3.6 GB.
Missed subject pixels average 0.8 per frame (max 7); flicker is 1.8 /255.

**Colour change where α > 0.98** (share of pixels off by more than 3/255):

| engine | median | max |
|---|---|---|
| CK2 + fuse, Vision + fuse, logo-classic | 0 | ≤0.5 % |
| chroma key with despill | 2 % | 34 % |
| GPT + image_matte | 7.5 % | 7.5 % (re-render) |

**Speed per 1080p still:**

| engine | seconds | note |
|---|---|---|
| CK2 | 20 | 6-copy warm-up plus load; ≈2.8 s per frame in a clip |
| Vision, BiRefNet, BEN2 | 1.5–1.7 | |
| logo-classic | 0.5 | |
| fuse step | 0.7 | |
| GPT | 34–89 | unstable |

**People on white** (real photo, hair): CK2 keeps single strands in their own colour. Vision leaves white specks in
the hair. GPT re-renders the person. Sheet: `results/sheet-real-hair-white-all.png`.

### Grey verdict and the backdrop

- **CK 2.0 keys grey and white with no hint.** On the Blender car, grey is its best backdrop of the four: page error
  1.9 against 12.3 on green.
- **Green and blue cost page error on glossy black paint.** The Fresnel reflection of the screen tints the paint, and
  grey avoids it.
- **Recommendation for a glossy dark car:** a light-grey sweep. CK keys it, the shadow is measured exactly against a
  neutral plate and the paint stays clean. Use green only when the windows must show through (`--glass screen`).

### Usage map

| job | engine |
|---|---|
| Car clips and stills on any flat backdrop | CK2 + fuse (`ck_key.py`) |
| Logos on a flat field | logo-classic; CK2 + fuse ties it on green and navy, loses on grey/white (4.7–5.4 vs 2.1–2.7) |
| Hair and people on white | CK2 + fuse |
| Car sprites, sharpest body edge on grey/white | Vision + fuse or BiRefNet + fuse (edge error 34 vs CK's 45–49), no shadow quality loss |
| GPT Remove BG | none: slow, recolours, unstable |
| Plain chroma key | none: recolours the subject |

### Web delivery

- **This pass:** the Rentiva pass takes RGBA PNG frames plus a shadow PNG per frame. The shadow is RGBA: grey = M,
  alpha 255 where M < 1.
- **Video with alpha** (not built or tested here):
  - WebM VP9 alpha covers Chrome, Firefox and Edge, but not Safari.
  - HEVC-with-alpha `.mov` covers Safari only.
  - A stacked colour-plus-alpha H.264 drawn in a canvas works everywhere, at twice the pixels plus a small script.
- **For a scroll scrub of 12–16 frames, per-frame WebP or AVIF stills beat any of these.**

### Stage two (only on Egor's word)

- **Install form:** the corridorkey-desktop binary, its models and the runtime (4.5 GB).
- **Wrapper:** a `bin/` wrapper around `ck_key.py` plus the fuse, findable by `tools cut out` / `tools key video`, and
  a stills engine under `image-cutout --engine ck`.
- **Rest of the bench:** 27 GB of scratch in `/Volumes/Work/tmp/corridorkey/`. It can go once the tool lands.

### Licence

- **CK 2.0's weights are free to use and their outputs may be used commercially.** Selling the tool or serving it as
  a paid API is not allowed. Private harness use is fine.
- **corridorkey-desktop carries the same Corridor Key licence**, so the same terms apply. Its bundled frozen
  models are permissive: the NVIDIA Open Model License for C-RADIO (commercial use, no claim on outputs), MIT for
  MoGe and Apache-2.0 for RVM.
- **Flag it if llm-legs is ever published with CK inside.**
