# Hand-off: Flow's "1080p Upscaled" download makes still shots tremble

Status: open. The research is done and the deck films were fixed by hand; nothing in the harness has changed.
To: whoever Egor gives the video stabilisation / post-processing integration.
From: the arbostar-logo chat, 2026-10-19. Its tools and evidence live in `~/Arbostar/arbostar-logo/renders/research/jitter/`
(gitignored, kept on disk); `bin/` there is the code to start from.

## What Egor wants from you

- **The harness knows and acts.** A model that fetches or uses a Flow 1080p must not find the tremble by review
  rounds. It must know the upscale adds it; the detector and the fixer must run on their own.
- **A detector he has verified by eye.** The meter below reads the defect well; its thresholds still need his eye.
  See § Egor's eye check.
- **A better fixer if there is one.** The anchor works; he wants to try combinations with you:
  - the anchor plus a stabiliser;
  - a temporally consistent upscaler;
  - double or triple passes;
  - why the After Effects way did nothing.
  He verifies each result visually.

## In short

1. **Cause.** Flow's free "1080p Upscaled" moves each frame up to ~1 px, alternating direction almost every frame, and
   redraws fine detail per frame. The 720p of the same media id (also free) is steady. Since Omni 1.1 Flash it hits
   first/last-frame shots; there is a public report and no fix from Google.
2. **What works: the anchor.** Warp each 1080p frame by dense flow onto the Lanczos upscale of its 720p frame. The
   picture takes the original's geometry and keeps the upscale's detail. Egor: "helped very much", no loss of quality.
3. **What does not work: stabilisers.** ffmpeg vidstab (the After Effects way) cut the whole-frame number threefold;
   Egor saw no change at all. The eye follows the local wobble of detail, not the camera.
4. **Measure, do not ask a model.** An LLM cannot see a 1 px tremble: Gemini samples about 1 fps with coarse tokens.
   `bin/jitter.py` measures it.

## Cause, measured

The meter is `bin/jitter.py`. Units: RMS of a frame's offset from the midpoint of its neighbours, in px of a
1920-wide frame. Global = tracked corners, RANSAC similarity, read at the frame corners. Local = dense flow minus the
global motion, median cell of a 6x10 grid.

| clip (media) | model | 720p global / local | Flow 1080p global / local |
|---|---|---|---|
| turning2 r16 wall `omni.mp4` (f3460349), the deck's take | omni first+last 8 s | 0.007 / 0.127 | 0.518 / 0.384 |
| turning2 r16 wall `omni-2.mp4` (522b4b2a) | omni first+last 8 s | 0.008 / 0.148 | 0.500 / 0.384 |
| sprout r16 cover oak (3745c596) | omni first+last 10 s | 0.044 / 0.034 | 0.439 / 0.192 |
| sprout r16 park (e1ae5a1e) | omni first+last 10 s | 0.015 / 0.033 | 0.730 / 0.380 |
| turning2 r15 film5 (2166d71d) | veo fast first+last | 0.009 / 0.147 | 0.736 / 0.409 |
| sprout v2 gem (2c3309f7) | veo fast first+last | 0.006 / 0.022 | 0.676 / 0.380 |
| crown2 free F1-hero (17b5d653) | abra i2v 10 s | 0.003 / 0.032 | 0.440 / 0.266 |
| turning2 r16 hero (649a1026) | omni first+last 8 s | 0.014 / 0.069 | 0.065 / 0.088 |
| crown2 r15 wall (bc86b50e) | omni first+last 10 s | 0.031 / 0.110 | 0.022 / 0.132 |
| four-sides omni oak edit (43144a8a) | abra_edit | 3.343 / 1.372 | 3.779 / 2.658 |

- **93 raw generations, all models** (`all.jsonl`, `vlist.txt`).
  - Native outputs are mostly steady: Veo 720p 0.006-0.095, Omni 720p 0.003-0.031, Grok Imagine 0.006-0.26.
    Two are unchecked and may be real motion: original r13 `rai-flow.mp4` (Veo portrait 720p, 1.36) and crown2 r5
    `hero-grok.mp4` (Grok, 0.30).
  - Flow 1080p: Veo first+last 12 of 22 above 0.2; Veo first-frame only 0 of 6; Omni/abra i2v 17 of 30. Not every
    upscale trembles (turning2 r16 hero, crown2 r15 wall), so measure each one.
- **The public report**: [Google AI forum, 2026-08-27](https://discuss.ai.google.dev/t/flow-sudio-fails-to-upscale-videos-to-1080p/179881),
  "the 1080p upscale is jerky, the 720p plays perfectly; it happens when you set the start frame, end frame or both".
  It started with the Omni 1.1 Flash release.
- **abra_edit is separate.** It trembles at 720p too (3.3), so its source or the edit model moves. Look at it alone.
- **A Lanczos upscale of the 720p reads 0.003**, so the number is not a scale artefact of the meter.

## Why stabilisers miss it and the anchor does not

- **What the defect is.** Each patch of detail (leaves, bushes, stone grain, lettering edges) is shifted on its own by
  up to ~1 px, a new shift every frame, plus a small whole-frame shift and zoom ("breathing"). The heat maps
  (`maps/cmp-wall.jpg`, `maps/cmp-oak.jpg`) show it everywhere there is texture, strongest at the edges.
- **What a stabiliser does.** vidstab and After Effects' Warp Stabilizer model a camera. vidstab fits one transform
  per frame; Warp Stabilizer's subspace warp fits a smooth mesh from tracked features. Both then smooth the camera
  path. The patch-level wobble is not a camera path, so it stays.
- **Measured on the oak.** vidstab `tripod=1` moved the numbers 0.439 / 0.192 → 0.145 / 0.187: the global part went,
  the local part did not. Egor: "it trembles the same, in the same places".
- **Moving content pulls it.** On the turning2 wall the walking man pulled vidstab's camera estimate: 0.518 / 0.384 →
  0.368 / 0.387.
- **No reference.** Without one, a stabiliser cannot know which geometry is true. It can only low-pass motion, and that
  eats real motion too.
- **Why the anchor works.** The 720p of the same media is the true geometry, frame for frame, and it costs nothing.
- **After Effects itself was not run here** (no AE on this Mac), only reasoned about and read about. Forums report
  Warp Stabilizer adds flicker in trees and sky. If Egor wants it settled, run Warp Stabilizer on `see/oak-4ways.mp4`'s
  source with "Subspace Warp" and "Detailed Analysis" on, then read its local number.

## Fixes, measured on the oak (global / local)

| treatment | result |
|---|---|
| Flow 1080p as downloaded | 0.439 / 0.192 |
| ffmpeg vidstab `tripod=1` | 0.145 / 0.187; Egor: no visible change |
| ffmpeg `atadenoise` temporal denoise | 0.432 / 0.194: no effect |
| our old oak-stab (one shift per frame) | 0.300 / 0.189 |
| 720p + Lanczos to 1080 | 0.052 / 0.033: steady, softer |
| **anchored** (`bin/anchor.py`) | **0.097 / 0.058**; turning2 wall 0.108 / 0.200, the walking man is real motion |

Side by side, zoomed: `see/oak-4ways.mp4`, `see/wall-bushes-4ways.mp4`, `see/wall-door-4ways.mp4`. Each shows
1 Flow 1080p, 2 vidstab, 3 720p + Lanczos, 4 anchored.

## Egor's verdict (2026-10-19, on the 4-way clips)

- **vidstab: "no visible change at all".** Gate on the local median cell and the corners; a whole-frame shift alone is
  not the defect.
- **Anchored: "helped very much", no loss of quality.** On the turning2 wall a mild tremble is left, "not irritating
  like the original". Accepted as the fix.

## The anchor, and what it took

- **`bin/anchor.py <720p> <1080p> <out>`: for a raw download pair.** Each 1080p frame is warped onto the Lanczos 720p
  frame. The flow is DIS medium on frames blurred σ1.2, blurred again σ3, so it carries geometry and never texture.
  It copies the audio and refuses when the frame counts differ by more than 1.
- **`bin/reanchor.py <finished film> <720p> <out>`: for a film already cut from the 1080p.** It undoes any chain: crop,
  scale, trim, reversal, ping-pong or dissolve loop, a per-frame steadying shift. The steps, each one learned on the
  deck films:
  1. **Where the film sits.** One similarity (720p coordinates to the film's) by SIFT, the median over 7 frame pairs,
     its spread printed. The deck films were cropped and scaled; turning2's stabilise.py output is 1600x900.
  2. **Which original frame each film frame is.** Thumbnails at 240 px through that mapping, normalised error per
     film frame, then a Viterbi path over (frame, direction). The path runs straight, one original frame per film
     frame, forward or back; a break costs 3.0.
     - **Ping-pong loops.** The sprout oak is a ping-pong loop: 115 → 217 → 118.
     - **Reversed films.** The four-sides2 fleet film is reversed: 160 → 0.
     - **Why no holds or skips.** In a near-still shot, neighbouring frames differ less than the upscale's own noise.
       A path free to hold or skip wanders (crown-free F1b-hero did). A direction-state path with a reversal cost
       wandered too.
  3. **The flow.** DIS medium on σ1.2-blurred frames. Raw DIS flow is noise in dark glass, shade and flat paving
     (99th percentile 8 px on the turning2 wall). So the flow is a normalised convolution weighted by the frame's edge
     energy (Sobel, blurred σ2, squared, σ6), falling back to the frame's median shift where there is no texture.
     The upscale's texture stays; only its geometry moves.
  4. **Guards.**
     - A frame with a median flow above 2.5 px matches no original frame, like a loop's dissolve; it is written
       unchanged.
     - Above 15% such frames the film is not this original, and nothing is written. This caught a wrong 720p: the
       turning2 inlay was first given another media's 720p, and the flow reached 32 px.
  5. **Output.** crf 18 with the film's own audio. The deck films were then re-encoded at their source's crf and
     keyframe spacing, so the pages weigh what they did. A film the page seeks must keep its keyframes: the turning2
     inlay follows the cursor with `-g 12`.
- **Moving content.** Real motion (a walking man, a press, a hand) is in the 720p as well, so the anchor keeps it. In
  the walking man's area the local number stays ~0.18, the 720p's own floor (0.13-0.15 there). That is the "mild
  tremble" Egor still sees on the wall.
- **Pitfalls.**
  - ffmpeg inside a shell `while read` loop eats the loop's stdin. Use `-nostdin`, or it silently skips files.
  - Hold only the 720p in memory and stream the 1080p; the memory guard killed the first batch.
  - OpenCV has no `DISOPTICAL_FLOW_PRESET_FINE`, use MEDIUM; `remap` needs float32 maps.

## Deck films, before → after (global / local)

All 14 were anchored with reanchor.py (arbostar-logo `49a3e84`); the decks point at `*-anchored.mp4` next to each
source. Raw numbers: `fixed/deck-before-after.jsonl`.

| film | before | after |
|---|---|---|
| turning2 wall | 0.35 / 0.35 | 0.06 / 0.18 |
| turning2 inlay | 0.19 / 0.31 | 0.05 / 0.27 (its 720p: 0.02 / 0.18) |
| sprout cover oak | 0.30 / 0.17 | 0.07 / 0.05 |
| sprout cover oak 9:16 | 0.45 / 0.40 | 0.05 / 0.09 |
| four-sides2 fleet film | 0.20 / 0.18 | 0.05 / 0.09 |
| crown-free hero / match (raw take) | 0.60 / 0.34, 0.45 / 0.26 | 0.11 / 0.09, 0.07 / 0.07 |
| original-free smoke / morning | 0.34 / 0.20, 0.28 / 0.20 | 0.06 / 0.06, 0.05 / 0.06 |
| turning-free expo | 0.13 / 0.14 | 0.04 / 0.09 |
| real motion, about the same | crown-free ascent 0.05 / 0.08, original-free press 0.15 / 0.81, turning-free hero 0.16 / 2.36, sprout leaf 0.15 / 0.14 | 0.04 / 0.08, 0.13 / 0.84, 0.16 / 2.15, 0.14 / 0.13 |

- **Left as they were.**
  - sprout's soft leaf-shadow background (`pick/cover-bg.mp4`): the anchor read worse, see § The meter.
  - four-sides-free: Blender frames.
  - crown2 hero walk: native Grok.
  - crown2 block films: object motion.
  - sprout-free's opening: real NOAA footage.
- **Where each deck film came from.** Film ← media id (720p name in `f720/`):
  - turning2 wall ← f3460349 (turning-wall-f346); turning2 inlay `r15/inlay/fl1.mp4` (inlay-12c7);
  - sprout cover oak ← 3745c596; oak 9:16 ← 7dc1c20f; cover-bg ← 72699232; leaf ← 63c45ec8;
  - four-sides2 fleet ← 2dc97d45;
  - crown-free F1b-hero ← 07f2d702, F3-match ← be3c1452, F2b-ascent ← 137ad589;
  - original-free press2 ← 5eb67f61, smoke3 ← 17d35e3d, morning4 ← f2985b8a;
  - turning-free hero2 ← abdd5b25, expo ← 6224db14.

## The meter (`bin/jitter.py <video>... [--map <dir>]`)

- **Calibration** (`bin/synth.py`, films in `ctrl/`):
  - steady 0.00;
  - smooth pan 0.007;
  - 0.5 px random shake 0.67;
  - 1 px shake 1.16;
  - zoom breathing 1.06 at the corners, 0.02 at the centre;
  - 1 px local wobble 1.18 local.
- **What Egor saw so far.**
  - He complained at 0.30-0.35 (the oak, the wall).
  - Steady sources read ≤ 0.05.
  - He accepted the wall at 0.06 / 0.18 as "mild, not irritating".
  - His perception follows the local number.
- **Where it is blind.**
  - **Soft moving shadows** (sprout cover-bg, Veo dapple) read 1.19 / 1.05 even on the steady 720p. The anchored film
    read worse than the deck's (0.76 / 0.91 against 0.35 / 0.62); its frames barely differ, so the frame match was weak.
  - **Real motion raises the local number.** turning-free hero reads 2.36 local from its own movement.
  - **Rule: gate on the difference to the 720p of the same media, never on an absolute.** A rise of more than about 0.1
    over the 720p means the upscale added it. With no 720p, gate only static shots.
- **Why `deckkit.shaky_video` missed it** (`tools/deckkit.py`). It reads only the whole picture's horizontal phase
  correlation at 480 px and counts direction flips. The walking man biased the shift one way, so the flips stayed low
  (0.39). The corners and the local redraw are not measured at all.
- **Why turning2's `r16/bin/stabilise.py` half-worked.**
  - It moved each frame back by one shift measured on the lettering, door head and wall, trimmed 4 px and output
    1600x900; that trim is why that film was downscaled.
  - The middle steadied: 0.46 → 0.24 at the centre.
  - The breathing and the redraw stayed, 0.35 at the corners and 0.35 local. That is Egor's "centre steadier, bushes
    worse".

## Egor's eye check (pending)

- **The page.** `eye/index.html`: 17 clips, numbered, in a blind order. It has deck films before and after, two
  in-between steps of the oak (`bin/ladder.py`, the anchor applied at 25% and 50%), the shadows and a real-motion film.
- **The key.** `eye/key.json` maps each number to its clip and meter reading.
- **What he gives.** A rating for each number: 0 steady, 1 trembles if you look for it, 2 visible at once,
  3 irritating, and where it trembles.
- **What to read from it.** Set the gate threshold where his 1 starts. Note which measure, global or local, follows
  his eye.
- The ratings go here when he gives them.

## Ideas to try with him

- **A sharp base that never trembled.** Upscale the 720p with a temporally consistent video upscaler: RealBasicVSR,
  FlashVSR, SeedVR2, Topaz. Then the Flow 1080p is not needed at all. A per-frame image upscaler (Real-ESRGAN) would
  bring the redraw back.
- **The anchor plus a residual pass.** What is left after the anchor is the 720p's own floor and the flow's blur
  (σ6). A per-pixel temporal smoothing of the remaining displacement could lower the wall's 0.18, at the risk of
  smearing real motion. Gate it on the motion mask.
- **No 720p at hand** (an old download, another vendor's upscale): a self-anchor. Take dense flow to the neighbouring
  frames, low-pass each pixel's trajectory, warp. This is the per-pixel model that a camera stabiliser lacks.
- **After Effects, to settle it.** See § Why stabilisers miss it.

## Proposed integration

1. **Steady 1080p by default.** In `gemini-video`, `--resolution 1080p` also fetches the 720p of the same media
   (free, `gemini-web fetch <account> <media_id> --resolution 720p`). It measures both and delivers one of:
   - the anchored file;
   - the 720p + Lanczos when anchoring refuses.
   The final line gets `jitter=<global>/<local> ref720=<global>/<local>`. Keep the 720p next to the file: every later
   edit can be re-anchored to it.
2. **One detector, everywhere a film lands.** Replace `deckkit.shaky_video` with the meter's corner and local numbers,
   compared to the 720p when there is one. Its refusal must name the fix (`reanchor <film> <720p>`), so a model fixes
   instead of iterating.
3. **Tools in the harness.** Move `jitter.py`, `anchor.py` and `reanchor.py` into llm-legs `bin/` with tests on the
   `ctrl/` films. The arbostar copies are research code.
4. **Docs.** One line each:
   - `docs/video-prompting.md`: 1080p is Flow's upscale and trembles on first/last-frame shots; the harness anchors it
     to the 720p.
   - the media skill's video section.

## Evidence

Folder: `~/Arbostar/arbostar-logo/renders/research/jitter/`.

| path | what |
|---|---|
| `bin/jitter.py`, `bin/synth.py` | the meter and its calibration films; any Python with OpenCV and numpy |
| `bin/anchor.py`, `bin/reanchor.py`, `bin/ladder.py` | the fixers and the in-between steps for the eye check |
| `bin/eyepage.py`, `eye/` | the blind eye check |
| `see/*-4ways.mp4`, `see/*-720-vs-1080.mp4` | side by side, zoomed |
| `maps/cmp-wall.jpg`, `maps/cmp-oak.jpg` | heat maps: Flow 1080p on top, 720p below |
| `f720/` | the 720p originals of every deck film |
| `all.jsonl`, `pairs720.jsonl`, `fixed/deck-before-after.jsonl`, `fixed/run2.log` | measurements and the batch log |
