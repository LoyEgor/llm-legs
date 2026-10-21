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

## Fixes that work, and what does not

- The 720p of the same media, re-cut like the deck film: same content, no halos, softer on a large screen.
- A fresh take from a clean (720p) start frame.
- An image model redrawing an oversharp start frame (Egor's idea, untested): plausible; the lockup and lettering must be
  composited back.
- A blur or anti-sharpen filter: unlikely; the upscaler invents texture, and a blur turns it to mush.
