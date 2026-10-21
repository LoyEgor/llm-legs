# Hand-off: Flow's "1080p Upscaled" download is oversharp

Status: researched and calibrated on Egor's eye in arbostar-logo, not integrated into llm-legs.
To: whoever Egor gives the video post-processing integration (the chat that integrated `video-jitter`).
From: the arbostar-logo chat, 2026-10-21. Code and evidence: `~/Arbostar/arbostar-logo/tools/oversharp.py`,
the review page `site/oversharp/` (served at http://localhost:8765/oversharp/index.html by `tools/serve.py`) and his marks
`site/oversharp/marks.json`.

## What Egor wants

- **The harness knows and acts**, as with the tremble (`docs/video-jitter.md`): a model fetching or using a Flow 1080p
  must not find the oversharpening by review rounds.
- **A detector that matches his eye**, checked on his own marks (below).
- Integration together with `video-jitter`: one cause (Flow's upscale), one place (`gemini_web.steady_upscales`, which
  already holds the 720p of the same media). The anchored film keeps 85-91 % of the upscale's sharpness, so steadying
  removes the tremble but keeps the halos.

## The defect, in his words

- «между одним явным цветом ставит по соседству более светлый цвет... на контрасте двух цветов он делает вот эту вот
  sharpness линии»: a light halo along every contrast edge, the overshoot of an unsharp mask. Not compression.
- Worst: small dark specks on a flat light texture (travertine, concrete, plaster pores), each ringed white: «как будто
  бы мусор, огромное число мусора на экране».
- Also bark redrawn as wavy worms of one size, with no halo.
- Tolerated: halos on foliage or on real detail, weak halos even over most of the frame, and any shot with a large calm
  area (defocus, sky, a flat floor). A shallow-focus shot suffers less than one in focus everywhere.

## Cause, measured

- Every clean Flow pair (1080p upscale vs the 720p of the same media, 13 pairs): the upscale reads 1.14-1.49x the 720p
  on a fine-over-mid texture measure. Whether it shows depends on the content, as above.
- **Frame chains inherit it.** A take started from a frame of a 1080p upscale is crisp at 720p too (20 chained takes:
  their 720p read 1.00-1.21, clean 720p 0.65-0.94). The turning2 entrance was remade three times from such a frame
  before this was found. A clean start frame is a frame of the 720p.

## The detector (`tools/oversharp.py` v3)

- Per 32 px cell on the 720p grid: the halo beside strong edges at the film's own pixels, times fine-over-mid texture.
- A film is oversharp when its worst 5x5-cell region passes **1.94**, or when its in-focus cells carry more than **2.4**
  crisp dark pores each (a speck under 5 px, 60 grey levels below a flat light surround).
- Validation on his marks (53 deck films, 19 bad), leave-one-deck-out: 11 caught / 2 false alarms / 8 missed / 32 agreed
  (the v1 global score: 9 / 9 / 10 / 25). Zone AUC against his paint 0.85.
- Misses: worm bark with no halo (256, 257, 269, 275 on the page; the same bark sits on films he passed, so no tested
  worm term separated them: spectral bump, kurtosis, narrow-band share, stroke coherence), a 1 px rim on a flat CG star
  (274), a canopy at the limit (234). False alarms: foliage halos he tolerates (225, 227).
- About 3.6 s a film, CPU only. `oversharp.py <film>...` exits 1 on any OVERSHARP; `--page` rebuilds the review page.

## To integrate

1. **At fetch** (`steady_upscales`): measure the upscale and its 720p; when the upscale is oversharp and the 720p is not,
   deliver the 720p (or say so on the gemini-video line, e.g. `oversharp=<score> ref720=<score>`), and log a ledger row
   like the `steady` one, so a fixed Flow shows up over time. Whether 720p replaces the download or sits beside it is
   Egor's call.
2. **Frame chains**: a `--first-frame`/`--last-frame` cut from a Flow 1080p must be refused or swapped for the same
   frame of its 720p (video-chain and gemini-video). This is the cheapest win: the inherited halos cannot be fixed later.
3. **Deck builds** (arbostar-logo `tools/deckkit.py`): a gate like `steady_upscale`, after the flagged deck films are
   replaced (in progress 2026-10-21). The same file's tremble gate skips films without a `<stem>.720p.mp4` beside them:
   37 of 55 deck films (cuts, loops, re-encodes) are never checked; the oversharp page maps each deck film to its source
   and 720p (`tools/oversharp.py` page_order), which the gate can reuse.

## State, 2026-10-21 late evening (supersedes the parts above where they differ)

Decided with Egor:
- **The fixer exists and he approves it**: `tools/oversharp.py --fix <1080p> --ref720 <720p> --dest <out>` (arbostar-logo,
  commit 3091bdf). It anchors the upscale on its 720p as `video_jitter.anchored` does, then clamps the luma to the
  720p's local range (3 px window, 4 grey levels margin); chroma moves to the 720p only where the clamp moved the luma.
  Every clean bad pair drops under the detector limit and keeps 50-75 % of the upscale's extra fine detail over the 720p;
  letter edges stay crisp. Egor on the comparison page: the default (k3 m4) is the one he likes. Costs: foliage
  glints dimmer; the upscaler's invented texture ("worms" on bark, wavy lines inside letters) stays, since it is
  within the 720p's range. A take chained from an upscaled frame cannot be fixed (its 720p is crisp too).
- **Run it on every Flow 1080p that has its 720p, no detector in front.** Egor: a false fix loses nothing visible, so
  false alarms at fetch are harmless. One pass with `steady` (both anchor on the same 720p). Keep the raw download
  beside it. The detector then only writes the ledger row (raw and fixed scores).
- **Different takes do not help**: 4+4 takes from identical frames and prompt read within 10 % of each other at 1080p,
  all over the limit, all clean at 720p. The upscaler makes the halos, not the take. A re-download of an upscale is
  byte-identical.
- **No LLM judges for oversharp**: the detector decides (Egor: not worth the tokens if the detector is about right).

Where false alarms DO matter: a gate on start frames before they go to Flow, where a good image could be rejected.
Recommendation: guard by provenance first (a frame cut from a Flow 1080p upscale is refused or swapped for the same
frame of its 720p): zero false alarms, and it is the root cause found here. A pixel check of images of unknown origin
(GPT/Codex stills) stays warn-only until the detector proves near-zero false alarms on stills; whether GPT stills are
oversharp at all is untested.

Still with the arbostar-logo chat (needs Egor's eye and his marks), then handed over:
1. Detector v4: halo intensity x importance (in focus, subject, logo) x coverage, redo limit fitted on his 53 verdicts
   with at most one false alarm, plus a synthetic Unsharp Mask dose-response check (does the score rise with
   amount 0-300 %; each Flow film expressed as "reads like USM N % at R px"). His painted share alone predicts his
   verdict at AUC 0.90 (45 of 53 above 29 % painted).
2. One fixer improvement round: clamp only where an edge overshoots (give back real glints and thin lines), and calm
   the invented fine texture over time (static shots: motion-compensated average of the fine band over 3-5 frames).
3. The decks switch from the 720p fallback to fixed 1080p.

Open, untried, do not lose:
- Frame-chain guard (provenance) in video-chain and gemini-video: not built. The cheapest win.
- deckkit gate: not built; the antishake gate skips 37 of 55 deck films (no `<stem>.720p.mp4` beside them).
- Redrawing an oversharp start frame with an image model (Egor's idea): untested; lockup and lettering must be
  composited back.
- A paid upscaler (Krea, Magnific) compared against the fixer: Egor's later option; never local heavy models, never his
  3090 for this.
- Invented texture ("worms") has no detector: the same bark sits on films he passed.

## Any-chat guard against upscale on upscale (Egor, 2026-10-22)

Egor: a mechanism, not prose, so that ANY chat in any project that makes a video, gets Flow's upscale and later takes
a frame from it is handled automatically: «не наши договорённости в этом чате, а любой чат… автоматически понимал».
Prose alone may not be followed. Design:

1. **Register at fetch** (media-run video). Every delivered film gets a row: path, sha256, vendor, media id, size,
   `upscaled` (Flow 1080p = true), its 720p twin (fetched beside it, free), the input frames it was made from, and
   `tainted` when an input matched an upscaled or tainted film (lineage). Plus one fingerprint per frame (a 32x18 luma
   thumbnail or a 64-bit pHash, a few KB a film): by content, so it survives re-encode, PNG/JPEG save, resize and a lost
   tag. Flow 1080p is cleaned by default with the fixer (k3 m4), the raw download kept beside it. Backfill the
   films fetched before the register from media-run's logs.
2. **Check at every image input** of media-run (`--first-frame`, `--last-frame`, `--keyframe`, `--ref`, `--edit`, video
   and image kinds), by fingerprint lookup:
   - a frame of an upscaled film with a 720p twin → swapped for the same frame of the twin, printed as
     `swapped=<twin>@<frame>`. Nothing is lost: Veo and Grok generate at 720p and resize any input to it;
   - a frame of a tainted film (its 720p carries the halos too) → exit 2 naming the fix: the ancestor's clean frame, or
     a GPT redraw (point 4);
   - no match → passes; the pixel detector may warn, never refuse (Egor: a good picture must not be rejected).
   The check sits in the door every chat already passes (the launch gate refuses other spellings), so no model needs to
   know the rule. A crop or an edit of the frame escapes the whole-frame fingerprint and gets only the warning.
3. **Why models cut frames from films** (Egor did not know they did): seams. The next clip must start exactly where the
   last one ended: the turning2 entrance (first frame = frame 0 of the 720p, last = the same frame emptied), ping-pong
   loops, chains. A redraw there jumps at the cut, so a seam takes the exact frame, from the 720p. The door can tell a
   seam: a `--first-frame` matching a film's last frames, or a `--last-frame` matching its first.
4. **GPT clean redraw for references that are not seams** (Egor's hypothesis). GPT-Image upscaled by parts well, so a
   GPT pass on a frame from a film could drop the halos, AI patterns and defects (an odd stump) and hand the video model
   a clean start, for free. Catches: GPT redraws marks and lettering (the mark goes in only by pure transform, so
   composite it back), and nobody has compared a video from a GPT-cleaned frame with one from the 720p frame. Test before
   it becomes the default: 3-4 deck start frames, 720p frame vs GPT-cleaned, same prompt, Egor compares by number. If
   it wins, the door applies it to non-seam frames from films.

## Fixes that work, and what does not

- The 720p of the same media, re-cut like the deck film: same content, no halos, softer on a large screen.
- A fresh take from a clean (720p) start frame.
- An image model redrawing an oversharp start frame (Egor's idea, untested): plausible; the lockup and lettering must be
  composited back.
- A blur or anti-sharpen filter: unlikely; the upscaler invents texture, and a blur turns it to mush.
