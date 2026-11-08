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

### Tuning on the Omni clip (2026-11-06)

The Rentiva chat reported defects on `omni-hl`. Each came from the decode or the fuse, not from CK:

| defect | cause | fix |
|---|---|---|
| Stair-stepped tyre bottoms, blocky glass | The default ffmpeg decode copies 4:2:0 chroma into 2×2 blocks | Decode with `full_chroma_int` |
| Haze band and red/pink rim | The rim missed CK's outer tail | The rim now covers the whole edge band; its colour is the alpha-weighted unmix, the nearest solid colour making up the rest |

New options on `ck_key.py`:

- `--edge hard`: a 2× steeper ramp, because AI video blurs hard car edges over 8–10 px.
- `--despill all`: the screen's reflection on paint turns neutral at the same luma.
- `--glass-min` (default 0.5): screen-mode glass alpha is smoothed and floored at this tint.

Results:

- **Omni clip, 144 frames:**
  - green on the subject 77 → 0 px per frame;
  - pink edge pixels 153 → 0.3;
  - flicker 1.8 → 1.6.
- **Blender green clip:** edge error 33.1 → 27.2.
- **Stills bench:** unchanged.

The recipe for a car on green from AI video is `--glass screen --despill all --edge hard`.

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

### GPT object + the frame's shadow (page variant «GPT, тень из кадра», 2026-11-07)

`frame_shadow` in bench `scripts/gpt_page.py` composes the GPT object with the colour shadow layer
(`runs/_cks-color`).
- **What failed.** A colour rule picked which GPT pixels counted as shadow (near-black or grey), applied as a binary
  mask. GPT's pale haze and light tail stayed over the real shadow (Egor's pins img4 and img9), and a tyre's dense
  contact came out as a ragged step (img10).
- **The rule now.** Off CK's body, a GPT pixel gives way in proportion to the frame's darkening, whatever its colour
  (full at 3 %). The layer is carried 12 px under CK's opaque edge, because GPT's outline ends a few px sooner.
  - Kept: CK's body (holes filled).
  - Kept: pixels where the frame is brighter than its shadowed plate in some channel, because something is there.
    Without this, a dog's fine strands over a faintly darker screen were cut.
- **Carrying a layer under CK's soft edge** (`carry` in `scripts/run_ckshadow.py`; both layers, `_cks-explain` and
  `_cks-color`, and E). It was a copy of the nearest outside pixel, which drew stripes wherever GPT's thinner object
  leaves the layer bare: under the Rogue's bumper, the Rogue's sill, the Frontier's bumper.
  - Now it is a weighted blur at scales of 1.5 to 96 px, each scale weighted 10× less than the one before.
  - Near the edge the nearest values still rule. One scale alone at 6 px lightened a tyre contact into a light seam.
- **Checked on crops.** All 13 items: the three pins are fixed, and the wine glass's bowl and the hair are unchanged.
- **Rentiva floor glow (Egor's img11–img14).** The glow is part of the sprite's alpha. CK keeps it as object at
  A 0.4–1. GPT drops it and paints its own dark shadow there, often as dense as CK's glow, so «CK sees more than
  GPT» alone missed it. Off GPT's body (α > 0.9, holes filled), where the frame is not the bare plate, E now takes CK's
  subject in two cases: where CK's A is above GPT's, and where GPT's pixel is much darker than CK's (luma 0.10–0.25).
  - The darker test runs only on a GPT object laid on the source's pixels. A re-render that is only warped (Blender
    car on green) sits px off CK, and the test drew a second chrome lip under the bumper.
- **Screen colour out of CK's colours** (`despill` in `scripts/run_ckshadow.py`, `fg.png` of both `_cks-*` runs). On a
  chroma screen the screen channel is clamped to the mean of the other two over the whole subject. Egor 2026-11-07:
  colour lost in a shadow or glow costs little; a screen colour left there is a defect (img19, img22).
  - Sparing CK's opaque body left three defects: a green strip where the glow meets the bumper at α 1, the Blender
    car's green bounce in blotches, and a green cast on the dog's chest.
  - The whole subject despilled read cleaner on all five green items. Yellows (palm reflections) turn a little olive.
- **GPT lays re-laid** with the GPT chat's `image_matte.py` fixes (b534f270, 598e0331), for D, E, F and Remove BG.
  Re-lay again when its hand-off (`2026-11-07-gpt-cutout-quality.md`) closes.

### Shadow policy (Egor 2026-11-07)

- **Grey by default.** A grey multiply lies right on any backdrop. Grey is black at alpha 1 − M, exact over every
  colour.
- **Colour only on request.** Use it when the object casts colour or the floor is special (sand, reflective), and
  deliver it as a separate layer with `mix-blend-mode: multiply`.
- **Why one RGBA cannot carry colour.** The page's single RGBA (`rgba3`) paints the tint as colour over the backdrop.
  That is exact over white only; on dark backdrops it reads as a bright stain (Egor's img15 vs img16).
- **A colour shadow can never be 100 %.** Even a true multiply cannot show a light caustic on a dark floor, so a
  colour layer is right only on light floors.
- **GPT's drawn shadow is kept as an alternative** (Egor: on dark backdrops it sometimes beats ours). It is not built
  as a pipeline of its own: `gpt_shadow` in bench `scripts/gpt_page.py` turns the «GPT с просьбой» render into a
  grey layer under CK's object (page variant «CK + тень GPT», appended last so the pin letters keep).
  - Outside CK's body (holes filled) the layer is GPT's render over white, GPT's object included where it reaches
    past CK's: that is its drawn tyre contact. Excluding GPT's body and carrying the floor in left a light band under
    the RAV4's tyre.
  - Under CK's body the layer is the frame's own (the grey layer). GPT's strands there doubled CK's, and a gap that
    CK's outline closed came out as a light, hard-edged patch (curls, chiffon).
  - The layer is kept only within 25 px of the frame's own shadow (grey layer below 0.98), so GPT's strands flying
    past CK's outline do not read as shadow.

### Web delivery

- **This pass:** the Rentiva pass takes RGBA PNG frames plus a shadow PNG per frame. The shadow is RGBA: grey = M,
  alpha 255 where M < 1.
- **Video with alpha** (not built or tested here):
  - WebM VP9 alpha covers Chrome, Firefox and Edge, but not Safari.
  - HEVC-with-alpha `.mov` covers Safari only.
  - A stacked colour-plus-alpha H.264 drawn in a canvas works everywhere, at twice the pixels plus a small script.
- **For a scroll scrub of 12–16 frames, per-frame WebP or AVIF stills beat any of these.**

### MLX engine for stills (2026-11-07)

**Choice.** Stills run on ck2mlx (peterteravskis/corridorkey-v2-mlx) with graphs we export from upstream ourselves
(`scripts/mlx_export.py H W OUT`), driven by `scripts/mlx_speed.py`. The PyTorch/Metal fork is closed. The reference
is upstream fp32 (`runs/ref-fp32`). A Fable/Argon/Astra panel agreed.

**Build "mix" (1.8 GB).**
- Foundations and RVM run in fp16; stages 1 and 2 run in q8.
- Stage 1 is pruned to `baton` (`lean_profile`), and weights no graph reads are dropped.
- Egor accepted its loss: alpha mean ≤ 0.27 ‰ against fp32, worst pixel 2.8 %, no visible change (page
  `ck-mlx-versions`).
- Foundations must stay fp16. In q8 they put the car trail up to 15 % off.

**Numbers (M4).**

| case | compute s | peak GB | note |
|---|---|---|---|
| 1080p still | 2.9 | 2.2 | |
| 4K still, native | 13.5 | 4.1 | |
| first start, weights + venv on internal SSD (2.6 GB) | ≈ 4 total | | |
| first start, everything on the USB disk | ≈ 14 total | | |

- Compute is at the hardware floor. The matmuls run at ≈ 80 % of M4 peak. Stage 2 takes 1.64 s, against 1.52 s of matmul + attention alone.

**Not resident.** One process per call, and several images go in one call (phased: one stage's weights at a time).
Keeping the model warm would save ≈ 1 s per call and is not worth holding 2.2 GB.

**Never rescale the image (Egor).** A downscaled model input was rejected: softer hair and a degraded picture. Pixels
come from the source, and the frame is only padded.
- Each side is rounded up to a multiple of 128 (the model's quantum; upstream does the same) and cropped back.
- Padding further, onto a bigger graph, is safe only up to ≈ 2× the exact graph's area. Within that bound it costs
  time and nothing visible: 1672×941 padded by ≈ 250 px moved alpha ≈ 0.5 ‰.
- Beyond the bound the frame is mirrored over a big canvas, and the model reads it as a different scene.
- Padding ladder (glass, car and hair at 200×112, 640×360 and 1080p; `runs/ladder`):
  - up to 2× the area, nothing visible moved;
  - at 4–9×, a car grew translucent patches and a floor smear;
  - at 56× and above, a glass came out opaque.
- The area ratio decides, not the pixel count. +128 px is harmless on 1080p and on 200×112 alike, while the same 4×
  hurts at any size.
- Edge-replicate padding only halves the damage.

**One graph per padded size: the store (built 2026-11-07).** MLX graphs have a fixed shape. Weights are identical
across sizes; only lifted index tables (`c_*`) differ.
- The tool is `scripts/ckgraphs.py` in the bench. Its store, `ckgraphs/`, holds:
  - the mix weights once (1.8 GB);
  - per size, a graph plus its constants (≈ 1 MB);
  - per size, a price.
- A build loads the model once (55 s) and then takes 20 s (128×128) to 200 s (4K) per size. No weight conversion.
- The 1080p graph equals build «mix» node for node, and its output is bit-identical.
- Every size works down to 128×128.
- `run` takes any images in one call. It uses the exact graph, else the cheapest built one within 2× the area, else
  builds the exact one on the spot (≈ 2 min for a small size) and logs `built_s`.
- Built sizes: 128×128, 128×256, 256×256, 256×384, 256×512, 512×512, 768×256, 1024×1792, 1152×1920, 2176×3840.
- Prices in seconds: 128² 0.30, 512² 0.52, 1024×1792 2.6, 1152×1920 3.3, 4K 15.4. They were measured under load 5–8;
  `price.json` keeps the load average.

**Size grid (Egor's plan, 2026-11-07).**
- The grid is dynamic: dense where images usually land, sparse at the extremes (e.g. sides in ≈ 1.3× steps), and
  left open to densify later.
- **Lost seconds are priced, never timed live (Egor, 2026-11-07).** Machine load must not move the number.
  - Each graph carries a price: its compute seconds, measured once on an idle machine right after it is built and
    stored with it.
  - A size with no graph gets its price from a fit over the built graphs (c + a·MP + b·MP²).
  - A call logs the image size, the graph used and lost = price(used) − price(the exact ×128 graph). The same images
    give the same number on a busy machine or an idle one.
- **The night builds what costs most.** The log feeds a Speed doctor opportunity row (`opportunity:ck/graph-sizes`):
  min/day = Σ lost per day, and the lever is to build the missing sizes in order of lost seconds. The night backlog
  already ranks rows by recoverable min/day (docs/speed-doctor-design.md §3). A night job exports the top sizes,
  prices them on an idle machine and the row shrinks.
- Not wired yet: the Speed doctor row and the night job (stage two). The choice lives in the tool, so a calling LLM
  needs no rule of its own, only a Bash timeout long enough for a first-use build.

**Open.**
- Video: MLX has temporal windows too (t2/t4 profiles). Measure it against the reference on a clip before choosing
  an engine for video.
- Images beyond 4096 px.

### Stage two: the harness tool (Egor's word 2026-11-08: needed now, tuned later)

**`ck-key`** (`bin/ck-key` → `share/ck_key.py`, uv script), README entry and PATH link, found by `tools cut out`.
- **Stills** run on our MLX build (`share/ck_mlx.py`, run in the engine venv). The output is CK as is, as Egor
  picked on `ck-ab-edge` (A on every item).
  - Files: `alpha.png` (16-bit), `fg.png` (8-bit straight; despilled over the whole subject on a chroma screen) and
    `rgba.png`.
  - One stdout line per image: `ck=done screen=green|blue|red|none alpha= fg= rgba= [shadow=] graph= s= wait_s=`.
  - The MLX alpha is bit-identical to the bench's `ckgraphs.py run` (three sizes checked).
  - Warm: a 500² image takes 6.5 s and 1080p 8 s, each including ≈4 s of start and 0.8 s of uv.
- **Clips and frame folders** run on the original CK2: the bench's `scripts/ck_key.py` on corridorkey-desktop,
  passed through unchanged. Our MLX build is not measured on video yet.
- **`--shadow grey|colour|gpt`** writes `shadow.png`: 8-bit RGBA, RGB = the multiply layer, alpha 255 where it
  darkens.
  - The layers come from `share/ck_shadow.py`. It is the bench's `run_ckshadow` math, equal to `_cks-explain` and
    `_cks-color` within 16-bit rounding.
  - `gpt` needs `--gpt-rgba`: a GPT cut-out that kept its shadow, laid on the input.
  - Slow: at 1080p, grey ≈ 11 s and colour ≈ 14 s more, measured under load ≈ 28. The large-sigma carry blurs
    dominate; a pyramid would cut them, which needs an equivalence check.
- **Importable for the GPT chat's combination:** `grey`, `colour`, `gpt_shadow`, `strip_shadow`, `despill`, `screen`,
  `Plate`, `save_layer`.
- **Engine home** `~/.local/share/corridorkey` (internal SSD; `CK_HOME`):
  - `venv/` is a copy of the bench's ck2mlx venv, with the editable link removed;
  - `ck2mlx/` holds the runtime package;
  - `graphs/` is the size store (moved from the bench);
  - `heavy.lock` is the one lock for stills and clips (the bench's `ck_key.py` takes it too, via `CK_LOCK`).
- **Still in the bench** (`CK_BUILD`, `/Volumes/Work/tmp/corridorkey`):
  - the graph exporter (`metal/`, `upstream/`, `scripts/ckgraphs.py build`, `mlx_export.py`), which now writes into
    the SSD store;
  - the clip engine (`desktop/`, `venv/`, `scripts/ck_key.py`, `run_fuse.py`, `flatkey.py`).
- **Base grid (2026-11-08)** adds exact graphs for common sizes: squares 768/1024/1536/2048; ChatGPT 1024×1536 both
  ways; 720p and 1080p portrait; Gemini 1344×768 and 1184×864 both ways; QHD, 6 MP 3:2 and 12 MP 4:3 both ways; 4K
  portrait.
  - Built 2026-11-08: 19 sizes in 90 min under load 35–44 (2–10 min each), 35 sizes in the store, 1.8 GB.
  - All 35 priced right after, under load 7–16 (not idle; `price.json` keeps it): 768² 0.9 s, 1024×1536 2.2 s,
    1920×1152 5.0 s, 4096×3072 26 s. Reprice on an idle machine if a lost-seconds number ever looks wrong.

**Next:**
- the GPT chat wires `--remove-bg --composite` to its combination (Remove BG + GPT asked in words + ck-key and
  image_fuse) and rewrites the background-removal text in the media skill;
- measure MLX on a clip against the original, then move the clip engine into `share/`;
- the Speed doctor row and the night build job;
- images beyond 4096 px.

### Bench cleanup (Egor, 2026-11-07): 80 → 20 GB

Deleted (61 GB), each restorable or closed:
- `mlx-export/` (39 GB): every experimental MLX export. The chosen mix lives in the graph store. Re-export any profile
  with `scripts/mlx_export.py H W OUT`.
- `ck2mlx/models/` (12 GB): the release's fp16 and q8 profiles, including t2/t4.
  - Restore: `hf download cdelta/CorridorKey-v2-MLX-fp16` or `cdelta/CorridorKey-v2-MLX-8bit` into
    `ck2mlx/models/{fp16,q8}`.
  - The one file a build read from there, the foundation stats, is now the store's `stats.json` (`mlx_export.STATS`).
- `metal/ck2-bf16-full.safetensors`, `mlx-v1/`, and the PyTorch/Metal runs (`runs/m-* r-* f-* mA1–mD1`, `_x-trash`):
  closed engines.
- `blender-work/` (2.5 GB): the raw EXR renders. `testset/blender` keeps their PNG derivatives (frames, alpha,
  plate, shadow). Re-render: `scripts/blender/run_set.sh` (≈ 44 min for the clip).
- `nets/`: BEN2 and BiRefNet_HR-matting. BiRefNet-matting stays, since the usage map names it.

Kept, because something live reads it:
- `desktop/` and `venv/`: `ck_key.py`, video;
- `metal/src`, `metal/venv`, `upstream/`: the graph exporter. `ck2mlx/src` and `ck2mlx/venv` are the bench's
  engine; the tool's copy is on the SSD. `ckgraphs/` moved to the SSD on 2026-11-08;
- `testset/`, `runs/` (CK, shadow and GPT runs), `runs_real/`;
- the `view*` and `page-mlx-*` folders: live pages read their pictures there.

### Licence

- **CK 2.0's weights are free to use and their outputs may be used commercially.** Selling the tool or serving it as
  a paid API is not allowed. Private harness use is fine.
- **corridorkey-desktop carries the same Corridor Key licence**, so the same terms apply. Its bundled frozen
  models are permissive: the NVIDIA Open Model License for C-RADIO (commercial use, no claim on outputs), MIT for
  MoGe and Apache-2.0 for RVM.
- **Flag it if llm-legs is ever published with CK inside.**
