# Video jitter and halos: Flow's 1080p upscale

Flow's free "1080p Upscaled" download moves each frame up to ~1 px, alternating direction almost every frame, and
redraws fine detail (leaves, grass, stone grain, lettering edges) per frame. The 720p of the same media id is steady.
It hits first/last-frame shots since Omni 1.1 Flash (2026-08; Google AI forum report of 2026-08-27, no fix), but not
every upscale: measure each one. Research, evidence and Egor's verdicts: `docs/handoffs/2026-10-19-flow-upscale-jitter.md`.

Every upscale is also oversharp: a light or dark halo rings each contrast edge, worst as white-ringed specks on flat
light stone or plaster, and it invents texture (worms on bark, a hatch in haze). It reads 1.14-1.49x its 720p on a
fine-over-mid measure (13 pairs), and a take started from its frame carries the halos even at 720p (20 chained takes).
Evidence and Egor's verdicts: `docs/handoffs/2026-10-21-flow-upscale-oversharp.md`.

## What the harness does

- `gemini-video --resolution 1080p` and `gemini-web fetch … --resolution 1080p` also save the 720p of the same media
  beside the file as `<stem>.720p.mp4` (`share/gemini_web.py` `save_ref720`). After the account's lock is released,
  `fix_upscales` runs `video-jitter fix` on each upscale, one decode and one encode (crf 18, its sound and colour tags):
  - it trembles (its rise over the 720p passes the gate): anchored, settled, then clamped on the 720p;
  - it does not: clamped against the 720p warped onto it, so it keeps its own pixels;
  - the steadied film reads no steadier: clamped only;
  - the two differ by one frame: paired by content (`lead`, 160 px thumbs), the ends held; by more: the upscale is kept;
  - its mean colour moved over 1.5 of 255: the upscale is kept.
  The download moves to `<stem>.raw.mp4` beside the result; the result is registered for the door (below).
- gemini-video prints `jitter=<global>/<local> ref720=<global>/<local> steadied=anchor+settle|none
  [fixed=<global>/<local>] cleaned=true|false [reason=…] dest=… ref720_file=… [raw_file=…]` per clip, or
  `jitter=unmeasured` with the reason.
- Each run leaves an `"event": "steady"` row in `~/.gemini-web/jobs.jsonl` (raw, ref, fixed, steadied, cleaned,
  clamped, colour_shift, sharpness, bytes, secs). When the raw readings fall under the gate for good, Flow has fixed
  its tremble; when `clamped` (the share of the picture the clamp moved 2+ grey levels, 4-31 % on 10 pairs) falls near
  zero, its halos.
- Each fix and door appends `{ts, command, secs, load, frames|images}` to
  `${VIDEO_JITTER_DIR:-~/.cache/video-jitter}/runs.jsonl`: the Speed doctor's `media post-process` line under
  Delegation, judged per frame and per image against its 28-day median in each load band
  (`docs/speed-doctor-design.md` C9).
- Keep the 720p: a film later cut from the clip can be re-anchored to it, and the door hands out its frames. Anchor
  the raw download, then cut: a second lossy encode cost the anchored fleet film half its softness.

## The clamp (Egor's k3 m4)

Each pixel's luma is held inside the range its 720p has over 3 px, widened by 4 grey levels; the chroma turns to the
720p's where the luma moved (fully at 8). A halo is lighter or darker than anything near it in the 720p, so it goes,
while an edge's place and steepness and the detail inside that range stay. The 720p is first put in the upscale's
grade (`toned`): Flow's upscale sits up to 3 of 255 off it; past the levels the blur leaves, the offset holds, so a
glint or a deep shadow keeps its height. Egor watched it on 30 deck films and found nothing worse;
it runs on every upscale with no detector in front, since a needless clamp loses nothing visible. Plain clamp of the
Lanczos 720p is byte-identical to arbostar's `tools/oversharp_rank/clean.py`. Not in the default (his word): `guided`
(removes invented texture, but as soft as the 720p on real detail; taste, per film), `calm`, `glint`; no LLM judges.
Costs: foliage glints dimmer, the brightest 1 % of a bright frame up to 16 levels lower where the 720p's sit lower
still (the mean under 0.5), the invented texture stays (it is within the 720p's range).

## The door: an upscale's frame goes on clean

A chat that cuts a frame from a film (a seam, a ping-pong loop, a chain) would hand the halos and the invented texture
to the next take. So:

- `video-jitter fix --register` (and `register [--raw]`, for a film fixed before) appends `{film, twin, raw, hashes}` to
  `~/.cache/video-jitter/upscales.jsonl`: one 64-bit dHash per frame of the 720p, by content, so a PNG, a JPEG or a resize
  still matches.
- `media-run image|video` passes every image after `--edit`, `--ref`, `--first-frame`, `--last-frame`, `--keyframe`
  through `video-jitter door` first. An image whose hash is near a registered film's frames is ranked over those frames
  of the 720p at 320 px, and its best 8 are read at full size from the film, the raw download and the 720p:
  - it sits within 3 grey levels of an upscale's frame and at most 0.6 of its distance to the 720p's: the argument is
    swapped, `swapped=… for=…` on stderr. A video job gets the 720p's frame
    (`~/.cache/video-jitter/frames/<stem>-<hash>.720p-f<n>.png`): Veo and Grok take any input at 720p, so nothing is lost. An
    image job (`--clean`, an image to edit keeps its size) gets that frame cleaned (`….cleaned-f<n>.png`): the fixed
    film's own, else the upscale's clamped on the spot;
  - the difference per channel in YCrCb, blurred 4 px, passes 12 somewhere, or the image has a cutout alpha: it was
    changed after the cut; it goes as given with a warning naming the clean frame to redo the change on;
  - a 720p frame, the still a take started from (4.8-5.7 from the take's frame 0), anything else: passes untouched.
  Calibrated on 4 pairs, 52 cases (recolours and alpha cutouts among them), all right. The nearest films are read
  first, six at once, each only as far as its near frames, and a swap or a 720p match ends the search: 2-7 s an image
  against the 45 films registered on 2026-10-22 (the ledger's and every `<stem>.720p.mp4` pair on disk). A failed
  check lets the images through with a warning.
- `video-chain last-frame` of a `<stem>.mp4` or `<stem>.raw.mp4` takes the frame from `<stem>.720p.mp4`, printed as
  `from=`, when it is there and ends on the same picture: its last half second at 64x36 grey 38 dB or closer (a 720p
  and its upscale read 43-48, another take from the same start frame 15-32).
- No lineage: the handoff's `tainted` row (a take made from an upscaled frame) is not built, since the door swaps every
  exact frame and only an edited one, which it warns about, can still carry the halos. The deckkit gate and the GPT
  start-frame test stay with the arbostar-logo chat.

## The tool: `bin/video-jitter` (`share/video_jitter.py`)

| command | does |
|---|---|
| `measure <video>... [--map <dir>]` | one JSON line each: `global.corner_rms`, `local.median_cell`, px of a 1920-wide frame; `--map` writes a heat map |
| `check <film> [--ref720 <720p>] [--steadied]` | exit 1 when it trembles, stderr naming the fix; exit 0 steady |
| `anchor <720p> <1080p> <out>` | a raw download pair: each 1080p frame warped by dense flow onto its Lanczos 720p frame |
| `reanchor <film> <720p> <out>` | a film already cut from the 1080p (crop, scale, trim, ping-pong, reversal, dissolve loop) |
| `settle <anchored> <out>` | the second pass: a 1-2-1 average with the neighbours wherever the picture stands |
| `fix <1080p> --ref720 <720p> [--register [<jsonl>]]` | what gemini-web runs: measure, steady when it trembles, clamp, replace in place keeping `<stem>.raw.mp4`, one JSON line |
| `register <1080p> --ref720 <720p> [--raw <download>] [--register <jsonl>]` | the door's row for a film fixed before the register |
| `door <image>... [--clean] [--register <jsonl>] [--out <dir>]` | one JSON line per image cut from a registered upscale: `swap` or `edited`, `as` 720p or cleaned; the register defaults to `${VIDEO_JITTER_DIR:-~/.cache/video-jitter}/upscales.jsonl` |

An 8 s 1080p clip on a quiet machine: 56 s when it does not tremble (the measure alone, all the steady did there, 11 s),
75 s when it does; about half is dense flow. Three at once on a loaded machine took 2-4.5 minutes each.

## The gate, set by Egor's eye

- Blind check of 17 clips (2026-10-19): he sees nothing up to a global 0.065 and sees it from ~0.095; the gate is
  **0.08 global corner**. The global number follows his eye on unsteadied films (Spearman 0.93; local 0.66).
- A quarter of the tremble left still shows, so a fix has to take out ~80 %.
- With a 720p the gate is the rise over it: global over 0.08 or local over 0.1. Real motion and soft moving shadows
  read high at 720p too (a walking man 2.36 local, dappled shade 1.19), which the rise cancels.
- After any stabiliser only the local rise counts: vidstab took the oak's global from 0.439 to 0.145 with "no visible
  change at all".
- Without a 720p only the global number is read, and real motion reads the same as tremble.

## Quality

- Colour: every frame is decoded and encoded by ffmpeg with accurate rounding and full chroma. cv2.VideoCapture read
  the hero 1.8/1.2/1.5 of 255 darker (R/G/B) per decode, and the research's cv2-anchored hero ended 6.3/2.2/5.6 darker
  in the file: the shift Egor saw was real. Flow tags its files BT.601; an untagged encode is read as BT.709 by
  players (Chrome: red +1 to +2, blue −1), so the encode writes the source's tags. chrome-headless-shell reads
  untagged as BT.601, so a headless capture hides the shift: check `ffprobe -show_entries stream=color_space`. A round
  trip stays within 0.12 of 255.
- Sharpness (Laplacian variance against the download, measured 2026-10-19 on the crown hero, the turning wall, the
  sprout oak): the steadied films keep 85-91 %, 720p + Lanczos 8-13 %. On the hero the anchor's sub-pixel warp costs
  6 %, the settle 8 % (the per-frame redraw it takes out), the crf 18 encode nothing: crf 14 doubles the size and keeps
  the same. At 2x crops the hero and the wall look the same as the download; the oak's moss is a little smoother.
- With the clamp (2026-10-22, 10 Flow pairs, 7 trembling): the Laplacian falls to 37-67 % of the download, but that is
  mostly the halos: the fixed film keeps 17-82 % of the upscale's extra fine-over-mid texture over the 720p (halos
  included) and reads near the
  720p's level on the halo detector (worst region 0.25-3.58 raw → 0.09-1.71, the 720p 0.03-1.17). Folding the steady
  into the clamp's pass costs 0-5 % against the clamp alone; clamping the upscale's own pixels instead of the anchored
  ones keeps 2-7 % more on a steady clip. Colour moved 0.06-0.85 of 255 (0.06-0.34 on the three re-measured after
  the review below). At 2x crops (travertine, foliage, grass,
  plaster, bark, dapple, an oak canopy) the rings are gone and the detail stays crisper than the 720p.
- `fix` reports `colour_shift` (of 255), `sharpness` (fixed / download) and `clamped`.
- A picture-quality review (2026-10-22, five models, nine findings confirmed) caught the toning flattening glints and
  shadows past the 720p's levels (a bright frame's top 0.1 % now 6 levels under the download, was 12), frames paired
  by index when the counts differ by one, a 720p frame handed to an image edit, and a `last-frame` twin never checked
  to be the same media; each is fixed and tested.

## What does not work

- Camera stabilisers (ffmpeg vidstab, After Effects' Warp Stabilizer): the wobble is per patch, not a camera path.
- Temporal denoisers (hqdn3d, atadenoise): they leave a change that alternates frame to frame.
- A plain 1-2-1 average without the anchor (averages misplaced frames) or without the motion mask (triples a walker).
- Asking a model: Gemini samples about 1 fps with coarse tokens and cannot see a 1 px tremble.
