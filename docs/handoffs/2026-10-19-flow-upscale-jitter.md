# Hand-off: Flow's "1080p Upscaled" download makes still shots tremble

Status: open
To: whoever Egor gives the video stabilisation / post-processing integration (research only so far, nothing in the harness changed)

## Symptom

Egor (2026-10-19): deck films tremble back and forth by 1-2 px. Examples: turning2's entrance wall (the man walks in)
and sprout's cover oak. It is there from the first file on disk. On turning2 the middle of the wall trembles less and
the edges (bushes) more.

## Cause, measured

The generation is steady. The tremble is added when `gemini-video --resolution 1080p` downloads Flow's free
"1080p Upscaled" (`gemini-web fetch … --resolution 1080p`). The same media id fetched at 720p (free,
`gemini-web fetch <account> <media_id> --resolution 720p --dest …`) is steady.

Each frame of the upscale sits up to ~1 px off its neighbours, alternating direction almost every frame, with no chunk
period. Fine detail (leaves, bushes) is also redrawn per frame. A Lanczos upscale of the 720p stays at 0.003, so this is
not a scale artefact of the meter.

Units below: RMS of a frame's offset from the midpoint of the frames before and after it, in px of a 1920-wide frame.
The meter is `renders/research/jitter/bin/jitter.py` in `~/Arbostar/arbostar-logo`:
- global: tracked corners, RANSAC similarity, measured at the frame corners;
- local: dense flow minus the global motion, median cell of a 6x10 grid.

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

- **Raw generations.** 93 of them, all models (`all.jsonl`, `vlist.txt` there).
  - Native outputs are mostly steady: Veo 720p 0.006-0.095, Omni 720p 0.003-0.031, Grok Imagine 0.006-0.26.
    Two exceptions are unchecked and may be real motion: original r13 `rai-flow.mp4` (Veo portrait 720p, 1.36) and
    crown2 r5 `hero-grok.mp4` (Grok, 0.30).
  - Flow 1080p:
    - Veo first+last: 12 of 22 above 0.2;
    - Veo first-frame only: 0 of 6;
    - Omni/abra i2v: 17 of 30.
  - That matches the one public report: [Google AI forum, 2026-08-27](https://discuss.ai.google.dev/t/flow-sudio-fails-to-upscale-videos-to-1080p/179881),
    "the 1080p upscale is jerky, the 720p plays perfectly; it happens when you set the start frame, end frame or both".
    It started with the Omni 1.1 Flash release; there is no fix or workaround.
- **abra_edit is separate.** It trembles at 720p too (four-sides oak edit, 3.3), so its source or the edit model moves.
  Look at it alone.

## Why our gates missed it

- **`deckkit.shaky_video`** (`tools/deckkit.py`) passed the deck's turning2 wall and sprout cover oak. It reads only
  the whole picture's horizontal phase correlation at 480 px and counts direction flips. The walking man biases the
  shift one way, so the flips stay low (0.39). The trembling corners and the local redraw are not measured at all.
- **`renders/night/turning2/r16/bin/stabilise.py`**:
  - **What it does.** It measured one sub-pixel shift per frame on the lettering, the door head and the wall, and moved
    the frame back. It then trimmed the edges by the largest offset + 2 px and scaled to 1600x900. 1600x900 is just its
    output size, a clean 16:9 after the trim; no other reason is recorded.
  - **What it fixed.** The middle steadied: 0.46 → 0.24 at the centre.
  - **What it left.** The zoom/roll breathing and the local redraw stayed: corners 0.35, local 0.35.
    That is exactly Egor's "centre steadier, bushes worse".
- **An LLM cannot see it.** Gemini samples video at about 1 fps, and its tokens are far coarser than 0.5 px, so a
  listen or vision verdict will not catch it. Use the meter. A heat map (`maps/`) is the only form a model could read.

## Fixes, measured on the oak (global / local)

| treatment | result |
|---|---|
| Flow 1080p as downloaded | 0.439 / 0.192 |
| ffmpeg vidstab `tripod=1` on the 1080p | 0.145 / 0.187: global gone, the leaves still redraw; on the turning2 wall only 0.368 / 0.387, the walking man pulls it |
| ffmpeg `atadenoise` temporal denoise | 0.432 / 0.194: no effect |
| our old oak-stab | 0.300 / 0.189 |
| **720p + Lanczos to 1080** | **0.052 / 0.033**: steady, softer |
| **anchored** (`bin/anchor.py`: each 1080p frame warped by blurred dense flow onto the Lanczos 720p frame, so the upscale's detail on the original's geometry) | **0.097 / 0.058**; turning2 wall 0.108 / 0.200 (the walking man is real motion) |

- **After Effects.** Warp Stabilizer (subspace warp) works on the same principle as vidstab plus local warps. It does
  not undo a per-frame redraw of detail, and forums report it adds flicker in trees and sky. The source of truth (the 720p) is
  free, so no stabiliser is needed.
- **Untested.** A temporally consistent video upscaler (RealBasicVSR, SeedVR, FlashVSR, Topaz) for a sharp 1080p. A
  per-frame image upscaler (Real-ESRGAN) would bring the same tremble back.

## Egor's verdict (2026-10-19, on `see/*-4ways.mp4`)

- **vidstab (the After Effects way): no visible change at all.** It trembles the same, in the same places, though
  its whole-frame number fell 0.44 → 0.15. The eye follows the local measure (the redraw of detail), not the
  whole-frame shift. Gate on the local median cell and the corners; a whole-frame shift alone is not the defect.
- **Anchored: "helped very much", no loss of quality.** On the turning2 wall a mild tremble is left, "not irritating
  like the original". Accepted as the fix.
- **Integration is yours.** Add your own fixer if you find a better one, then test it with him on real films.
- **Applied to the deck films already.** `bin/reanchor.py <finished film> <720p> <out>` puts a finished film on the 720p
  geometry whatever its chain was:
  - it finds the crop/scale by SIFT;
  - it finds the frame path through trims, ping-pong and dissolve loops (Viterbi over thumbnail likeness);
  - its flow is texture-weighted, because raw DIS flow is noise in dark glass and flat paving.
  It refuses a film that is not that original.
  The decks point at `*-anchored.mp4` next to each source (arbostar-logo `tools/deck_*.py`). Films the decks copy as
  they are were then re-encoded at their source's crf and keyframe spacing (the turning2 inlay is seeked by the cursor:
  `-g 12`), so the pages weigh what they did.
- **Deck films, before → after** (global corner / local median cell; `fixed/deck-before-after.jsonl`):

  | film | before | after |
  |---|---|---|
  | turning2 wall | 0.35 / 0.35 | 0.06 / 0.18 |
  | turning2 inlay | 0.19 / 0.31 | 0.05 / 0.27 (its 720p: 0.02 / 0.18) |
  | sprout cover oak | 0.30 / 0.17 | 0.07 / 0.05 |
  | sprout cover oak 9:16 | 0.45 / 0.40 | 0.05 / 0.09 |
  | four-sides2 film | 0.20 / 0.18 | 0.05 / 0.09 |
  | crown-free hero / match | 0.60 / 0.34, 0.45 / 0.26 | 0.11 / 0.09, 0.07 / 0.07 |
  | original-free smoke / morning | 0.34 / 0.20, 0.28 / 0.20 | 0.06 / 0.06, 0.05 / 0.06 |
  | turning-free expo | 0.13 / 0.14 | 0.04 / 0.09 |
  | real motion, about the same | crown-free ascent 0.05 / 0.08, original-free press 0.15 / 0.81, turning-free hero 0.16 / 2.36, sprout leaf 0.15 / 0.14 | 0.04 / 0.08, 0.13 / 0.84, 0.16 / 2.15, 0.14 / 0.13 |

- **Where the meter is blind.** Soft moving shadows (sprout `cover-bg`, Veo dapple) read 1.19 / 1.05 even on the
  steady 720p, and the anchored film read worse (0.76 / 0.91 against 0.35 / 0.62): its frames barely differ, so the
  frame match is weak. That film stayed as it was. Blurred, low-texture content needs the 720p difference or an eye,
  never an absolute.

## Proposed integration

1. **Steady 1080p by default.** In `gemini-video`, for `--resolution 1080p`, also fetch the 720p of the same media,
   measure both, and deliver one of:
   - the anchored file;
   - the 720p + Lanczos when anchoring fails.
   The final line gets `jitter=<global>/<local>`. Gate on the difference to the 720p, not on an absolute: a real camera move or
   a walking subject raises both. The 720p is the reference; a rise of more than about 0.1 means the upscale added it.
2. **Replace `deckkit.shaky_video`.** Use the meter's global corner RMS and local median cell.
   - **Calibration** (synthetic films, `bin/synth.py`, `ctrl/`):
     - steady 0.00;
     - smooth pan 0.007;
     - 0.5 px random shake 0.67;
     - 1 px shake 1.16;
     - zoom breathing 1.06 at the corners, 0.02 at the centre;
     - 1 px local wobble 1.18 local.
   - **What Egor sees.** He sees 0.30-0.35 (the deck's oak and wall). Steady sources are ≤ 0.05.
   - **Threshold.** Start the gate near 0.12 and confirm it with him on two or three films.
   - **Moving content.** Shots with a real camera move or big object motion need the 720p difference.
3. **Re-make the deck films that came from a Flow 1080p.** Use the 720p and redo each deck's own post steps on it
   (stabilise.py and loop.py are then unnecessary or simpler).
   - **Above 0.2 now** (check which of them came from a Flow 1080p):
     - turning2 and turning2-alt `wall.mp4`;
     - sprout `cover-oak.mp4`, `cover-oak-916.mp4`, `wall3d-park.mp4`, `cover-bg.mp4`;
     - crown-free `hero.mp4`, `match.mp4`;
     - original-free `morning.mp4`;
     - sprout-free `orbit-*`.
     `all.jsonl` has every deck file; `crown2` block films and `four-sides-free` hero are object motion, check them by eye.
   - **Egor judges the result.**
4. **`docs/video-prompting.md`.** One line: 1080p is Flow's upscale and adds tremble on first/last-frame shots; take the
   720p plus a local upscale.

## Evidence

Folder: `~/Arbostar/arbostar-logo/renders/research/jitter/`. It is gitignored but stays on disk.

| path | what |
|---|---|
| `see/turning-bushes-720-vs-1080.mp4`, `see/oak-720-vs-1080.mp4` | zoomed side by side |
| `see/oak-4ways.mp4`, `see/wall-bushes-4ways.mp4`, `see/wall-door-4ways.mp4` | the four treatments side by side, zoomed: 1 Flow 1080p, 2 vidstab, 3 720p + Lanczos, 4 anchored |
| `maps/cmp-wall.jpg`, `maps/cmp-oak.jpg` | jitter heat maps: Flow 1080p on top, 720p below |
| `f720/` | the 720p originals |
| `see/*-anchored.mp4`, `see/oak-vidstab.mp4` | the fix candidates |
| `bin/jitter.py <video>... [--map <dir>]` | the meter; any Python with OpenCV and numpy, e.g. `python3 -m venv v && v/bin/pip install opencv-python numpy` |
