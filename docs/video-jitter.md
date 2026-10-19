# Video jitter: Flow's 1080p upscale

Flow's free "1080p Upscaled" download moves each frame up to ~1 px, alternating direction almost every frame, and
redraws fine detail (leaves, grass, stone grain, lettering edges) per frame. The 720p of the same media id is steady.
It hits first/last-frame shots since Omni 1.1 Flash (2026-08; Google AI forum report of 2026-08-27, no fix), but not
every upscale: measure each one. Research, evidence and Egor's verdicts: `docs/handoffs/2026-10-19-flow-upscale-jitter.md`.

## What the harness does

- `gemini-video --resolution 1080p` and `gemini-web fetch … --resolution 1080p` also save the 720p of the same media
  beside the file as `<stem>.720p.mp4` (`share/gemini_web.py` `save_ref720`). After the account's lock is released,
  `steady_upscales` runs `video-jitter steady` on each upscale:
  - it does not tremble (its rise over the 720p is under the gate): the upscale is delivered as downloaded, so a
    fixed Flow costs nothing;
  - it trembles: it is replaced in place by the anchored and settled film, one encode at crf 18 with its sound and
    colour tags;
  - the anchor refuses (frame counts differ): the 720p + Lanczos instead;
  - the result reads no steadier, or its mean colour moved over 1.5 of 255: the upscale is kept.
- gemini-video prints `jitter=<global>/<local> ref720=<global>/<local> steadied=anchor+settle|lanczos|none
  [fixed=<global>/<local>] dest=… ref720_file=…` per clip, or `jitter=unmeasured` with the reason.
- Each run leaves an `"event": "steady"` row in `~/.gemini-web/jobs.jsonl` (raw, ref, fixed, steadied, secs): when the
  raw readings fall under the gate for good, Flow has fixed its upscale and the 720p and the minute can go.
- Keep the 720p: a film later cut from the clip can be re-anchored to it. Anchor the raw download, then cut: a second
  lossy encode cost the anchored fleet film half its softness.

## The tool: `bin/video-jitter` (`share/video_jitter.py`)

| command | does |
|---|---|
| `measure <video>... [--map <dir>]` | one JSON line each: `global.corner_rms`, `local.median_cell`, px of a 1920-wide frame; `--map` writes a heat map |
| `check <film> [--ref720 <720p>] [--steadied]` | exit 1 when it trembles, stderr naming the fix; exit 0 steady |
| `anchor <720p> <1080p> <out>` | a raw download pair: each 1080p frame warped by dense flow onto its Lanczos 720p frame |
| `reanchor <film> <720p> <out>` | a film already cut from the 1080p (crop, scale, trim, ping-pong, reversal, dissolve loop) |
| `settle <anchored> <out>` | the second pass: a 1-2-1 average with the neighbours wherever the picture stands |
| `steady <1080p> --ref720 <720p>` | what gemini-web runs: measure, fix in place when it trembles, one JSON line |

A 10 s 1080p clip takes about a minute (crown hero: 0.601 → 0.017, 68 s).

## The gate, set by Egor's eye

- Blind check of 17 clips (2026-10-19): he sees nothing up to a global 0.065 and sees it from ~0.095; the gate is
  **0.08 global corner**. The global number follows his eye on unsteadied films (Spearman 0.93; local 0.66).
- A quarter of the tremble left still shows, so a fix has to take out ~80 %.
- With a 720p the gate is the rise over it: global over 0.08 or local over 0.1. Real motion and soft moving shadows
  read high at 720p too (a walking man 2.36 local, dappled shade 1.19), which the rise cancels.
- After any stabiliser only the local rise counts: vidstab took the oak's global from 0.439 to 0.145 with "no visible
  change at all".
- Without a 720p only the global number is read, and real motion reads the same as tremble.

## Quality (measured 2026-10-19 on the crown hero, the turning wall, the sprout oak)

- Colour: every frame is decoded and encoded by ffmpeg with accurate rounding and full chroma. cv2.VideoCapture read
  the hero 1.8/1.2/1.5 of 255 darker (R/G/B) per decode, and the research's cv2-anchored hero ended 6.3/2.2/5.6 darker
  in the file: the shift Egor saw was real. Flow tags its files BT.601; an untagged encode is read as BT.709 by
  players (Chrome: red +1 to +2, blue −1), so the encode writes the source's tags. chrome-headless-shell reads
  untagged as BT.601, so a headless capture hides the shift: check `ffprobe -show_entries stream=color_space`. A round
  trip stays within 0.12 of 255.
- Sharpness (Laplacian variance against the download): the steadied films keep 85-91 %, 720p + Lanczos 8-13 %. On
  the hero the anchor's sub-pixel warp costs 6 %, the settle 8 % (the per-frame redraw it takes out), the crf 18
  encode nothing: crf 14 doubles the size and keeps the same. At 2x crops the hero and the wall look the same as
  the download; the oak's moss is a little smoother.
- `steady` reports `colour_shift` (of 255) and `sharpness` (fixed / download).

## What does not work

- Camera stabilisers (ffmpeg vidstab, After Effects' Warp Stabilizer): the wobble is per patch, not a camera path.
- Temporal denoisers (hqdn3d, atadenoise): they leave a change that alternates frame to frame.
- A plain 1-2-1 average without the anchor (averages misplaced frames) or without the motion mask (triples a walker).
- Asking a model: Gemini samples about 1 fps with coarse tokens and cannot see a 1 px tremble.
