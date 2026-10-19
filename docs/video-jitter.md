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
  - it trembles: it is replaced in place by the anchored and settled film, one encode at crf 18 with its sound;
  - the anchor refuses (frame counts differ): the 720p + Lanczos instead;
  - the result reads no steadier: the upscale is kept.
- gemini-video prints `jitter=<global>/<local> ref720=<global>/<local> steadied=anchor+settle|lanczos|none
  [fixed=<global>/<local>] dest=… ref720_file=…` per clip, or `jitter=unmeasured` with the reason.
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

## What does not work

- Camera stabilisers (ffmpeg vidstab, After Effects' Warp Stabilizer): the wobble is per patch, not a camera path.
- Temporal denoisers (hqdn3d, atadenoise): they leave a change that alternates frame to frame.
- A plain 1-2-1 average without the anchor (averages misplaced frames) or without the motion mask (triples a walker).
- Asking a model: Gemini samples about 1 fps with coarse tokens and cannot see a 1 px tremble.
