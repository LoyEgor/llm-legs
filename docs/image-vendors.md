# Image vendors

Index for the subscription image/video legs. Each vendor's evidence and knobs live
under [`docs/image-vendors/`](image-vendors/):

| Vendor | Wrapper | Notes |
| --- | --- | --- |
| [Codex](image-vendors/codex.md) | `bin/codex-image` | Default: ChatGPT in the hidden Chrome (`--route web`), falling back to the codex CLI's built-in `image_gen`; no aspect argument — `--aspect`/`--size` are one builder's prose on both routes, checked by `aspect=`; `--region`, `--point`, `--remove-bg` web-only; no video |
| [Gemini](image-vendors/gemini.md) | `bin/gemini-image`, `bin/gemini-video` | Default: Nano Banana Pro/2/2 Lite on Google Flow (0 credits, 1-4 takes, 10 refs, five aspects, 2K); `--route cli`: agy `generate_image` (3 refs, seven aspects); video on Google Flow (Veo 3.1 / Omni) through a hidden Chrome |
| [Grok](image-vendors/grok.md) | `bin/grok-image`, `bin/grok-video` | Imagine image + video; chroma transparency |
| [ElevenLabs](image-vendors/elevenlabs.md) | `bin/elevenlabs-<kind>` | Paid API, audio only: exact-length sfx and music, stems, speech and dialogue, voice change and design, noise isolation, transcription, forced alignment, dubbing; `media-run <kind> --vendor elevenlabs` (gemini stays the default for music and sfx) |

Runtime limits are the JSON manifests in [`share/image-caps/`](../share/image-caps/README.md),
not these pages. Re-verify a manifest when a run prints `caps=stale` or `model_caps=stale`.

## Capability matrix

Route a request by this table; every cell follows from the vendor's manifest (`api_only` names what the
vendor API has and its CLI does not carry). No vendor has a mask, a fidelity flag or a seed.

| Capability | codex | gemini | grok |
| --- | --- | --- | --- |
| Routes, in order (`routes`) | `web` (ChatGPT), then `cli` (codex `image_gen`) | `flow` (Google Flow), then `cli` (agy) | `cli` |
| Edit one image with references | `--edit <image>` + `--ref`s: sent first, composited onto, counts against the cap | same | same |
| Extend / outpaint the frame | ref + "extend the scene" + `--aspect` (prose, `fit=` checked); web: viewer Resize via `--resume --aspect` | ref + a wider `--aspect` (Flow's 5 ratios, nearest one taken; `--route cli`: 7); without `--prompt`: Flow's Image Editor Outpaint (16:9, 4:3, 1:1, 3:4, 9:16; an unfilled black side exits 1) | `--ref` ×2+ with a wider `--aspect`; a single-ref edit keeps the source ratio |
| Edit a region | web route only: `--region x,y,w,h` (Markup outline), `--point x,y=<text>` (Comment pins) feed the mask; CLI exit 2. Every edit composited by default | Flow's Image Editor Inpaint: `--region x,y,w,h` + `--prompt`, or `--point x,y=<text>` (brush mask, composited onto it; `pro` recommended); otherwise prompt only, every edit composited by default, `--composite=x,y,w,h` pastes only that rectangle | prompt only (`image_edit`); every edit composited by default |
| Keep identity across edits | ref + "preserve identity", `--resume` | ref, `--resume` needs `--account` and stays on the route that made the session; Flow keeps the face sharper over chained edits | first choice: `image_edit` + `--resume` |
| References max (`--edit` included) | web 20; `--route cli` 5 (unverified) | 10; `--route cli` 3 | 3 (API: 5) |
| Transparency | native alpha, chroma fallback; web: `--remove-bg` (Remove BG, a regeneration) | chroma (both routes); `--remove-bg` = Flow's on-device Cutout (MODNet, poor on both test images — prefer `image-cutout`) | chroma (API background removal: `api_only`) |
| Quality control | none | none | none (API `low\|medium\|auto`: `api_only`) |
| Exact size | no (size as prose) | no | no |
| 1K / 2K | no | 1K, `--upscale 2k` (`--route cli`: no) | no (`api_only`) |
| Video | no | `gemini-video`: text, first/last frame, up to 3 (Veo) or 4 (Omni) image refs, or `--edit` of any video up to 30 s (Omni, `--ref` puts a character or object into it), `--extend` of a Flow Veo clip (+7 s, 720p), `--count 2–4` takes → 8 s Veo 3.1 Lite/Fast/Quality or 4–10 s Omni Flash; 16:9 or 9:16; 360p/720p, 1080p via Flow's free upscale; audio; Flow credits | `grok-video`: 1 ref → 6/10 s, up to 14 refs → 1–15 s, pinned first/last frames and up to 4 keyframes, 480p/720p (API 1080p: `api_only`) |
| Audio | no | `gemini-music` (Lyria 3.5 in the Gemini app: ≈60 s or 2–3 min, mp3/wav, sections from a brief, `--video` to watch the cut, `--ref-image`), `gemini-sfx` (a Flow Omni soundtrack, trimmed and normalised; `--for-video` ≤ 10 s), `gemini-listen` (agy watches and hears files; `--compare A B` asks in both orders → `winner=A\|B\|tie votes=<n>/2`; local `bin/audio-score` gives UTMOS and Audiobox Aesthetics per file), `gemini-speech` (free Gemini TTS in AI Studio: 70 voices, one or two speakers, style, expression tags; WAV 24 kHz mono) | no |

## Routes, fallback and the run log

Without `--route` a script runs its manifest's `routes[0]`. When that route fails at the route level —
engine exit 4 (sign-in), 5 (every account busy), 3 (limit or wall), or exit 1 with `"sent": false` —
the same request reruns once on the next route in `routes`, printing `fallback_from=<route>` and
`fallback_reason=sign-in|busy|limit|flagged|not-sent` after `route=`. Exit 3 prints
`<VENDOR>_ACCOUNT_FLAGGED` when the engine's result says `flagged` (Flow's unusual-activity flag, a
24 h wall), else `<VENDOR>_USAGE_LIMIT` (`image_leg_limit`). A request the next route cannot express
never falls back (codex web-only `--region`/`--point`/`--remove-bg`/re-aspect; a `--count` >1 on codex web or Flow;
`--model`, `--upscale`, the Image Editor tools; more refs, or an aspect, than the next route takes),
nor does a refusal (`refused`, a policy reason), anything sent (`"sent": true`), an exit 1 without
`sent`, a busy or limit exit under `bin/image-fanout` (`IMAGE_LEG_SCHEDULER`, which moves the take
itself), an explicit `--route` or a `--resume` (the session's own route): those exit with the first
route's code.

- `--edit <abs image>`: the image being edited — the composite base and the vendor's first reference
  (codex web/CLI, the Flow ingredient or Image Editor input, agy, grok); every `--ref` is a reference
  only and the prompt says so. It counts against the route's ref cap, is the lineage input, and is
  refused with `--resume`.
- `--lock-wait <s>` goes to the web/Flow engine (its per-account lock wait, default 900); a CLI route
  ignores it. Exit 5 = account busy, with `ACCOUNT_BUSY account=<name>` on stderr.
- Output lines: `job=<id>` (the caller's `IMAGE_JOB_ID`, else one `share/image-leg.sh` makes and exports
  to the engine), `route=<route used>` (Flow: `route=flow model=… upscale=…`), the fallback pair, and
  `phases=<compact JSON>` when the engine reported its phase timings.

Every run appends one row to `${IMAGE_LEG_LOG:-~/.cache/image-legs/legs.jsonl}` (`image_leg_exit`, read by
`llm-doctor`): `ts tool kind rc seconds queued size account served err job` and, when known, `route`,
`fallback_from` + `fallback_reason`, `phases` (engine seconds per phase: `lock browser page sent media
saved`; video rows too), `load` (the 1-minute load average as each phase was reached: a slow phase under
load 300 is the machine's fair share, the same phase slow at load 5 is ours or the vendor's), `requested` + `delivered` (takes asked and delivered: a Flow `--count`, `failed=` partials, 0 on
a failure), `aspect` `{asked, achieved, fit}` (`fit` `ok|miss`, from the `aspect=` line) and, on success,
`composite` `{kind, changed, reason}` (`auto|region|points|refused|skipped|failed`, skip reasons
included).

## Soft vs hard fan-out adaptations

`bin/image-fanout` takes one request (or a `--jobs` batch) and runs it on every selected vendor,
adapting each call from that vendor's manifest. The vendors ARE the manifests in
`share/image-caps/*.json` — the script names none: `scripts[kind]` is the script it runs,
`rosters[routes[0]]` the argv that lists the accounts (a web engine's `accounts` JSON: `login: false`,
`roster: false` and a future `walled_until` are skipped; a CLI pool's `name: state` lines as before).

- **Hard** — skip the vendor. `video: null` against `--video` is the one hard skip.
- **Soft** — still run, and report the change in the row's reason:
  - too many `--ref` → truncate to `refs.max` (or `video.refs_max` on `--video`; `flow_image.refs_max` when the vendor's `routes[0]` is `flow`, `web.refs_max` when it is `web`); an `--edit` image takes one of those slots
  - unsupported `--aspect` → nearest value in `aspects.generate` / `aspects.edit` (edit when any `--ref` is kept; `flow_image.aspects` when `routes[0]` is `flow`); when `aspects` is `null` (Codex), pass `--aspect W:H` and the script's own sentence builder words it
  - `--size WxH` → passed only if `exact_size` is true; otherwise treated as an aspect and mapped as above
  - `--transparent` → forwarded to every image wrapper; each wrapper applies its own `transparent` mode (`native`, `chroma`, `native+chroma`)

## Fan-out usage

```bash
# Every vendor, every logged-in account (disabled accounts stay in; the wrapper skips them)
mkdir -p /tmp/badge-fanout
bin/image-fanout --dest-dir /tmp/badge-fanout \
  --prompt 'a round blue enamel badge, white background' \
  --aspect 1:1 --transparent

# Video: only vendors with a video block (today: gemini, grok). Needs at least one --ref.
bin/image-fanout --dest-dir /tmp/badge-fanout --video --duration 6 \
  --prompt 'slow gentle push-in' --ref /tmp/badge-fanout/grok-notcom.png
```

`--accounts pick` launches one job per vendor **without** `--account`: each wrapper
routes through `worker-pick --account <vendor> --role image` and records a claim (gemini's default Flow route
rotates its own signed-in gemini-web profiles instead). That role answers
the least recently started eligible account, a never-started one first (shared-invariants row `dh`);
every new generation, picked or pinned, stamps its start, and a `--resume` stamps nothing.

**Scheduling.** At most one live job per vendor account and at most `--max-parallel` (6) jobs; a
waiting job holds no slot. Primary takes launch before spares; a spare launches only when no primary
can. Image and video jobs run with `--lock-wait 5` (video: gemini-video forwards it to the Flow
engine, grok-video waits that long for its account lock; both exit 5 busy) and `IMAGE_LEG_SCHEDULER=1`, which turns off the wrappers'
own busy/limit fallback to the CLI route on the same account (direct wrapper calls keep it): a busy
account (exit 5) cools down 30 s and its take goes to another idle account of that vendor (a pinned
account retries itself; busy for 15 min → `failed`, `exit 5 (account busy)`). In a `--takes` pool a
usage limit (3) or pool-disabled (4) retires the account for the run and moves the take (`moved from
<acct> after a usage limit`, or `after an account flag (unusual activity)` when the wrapper printed
`<VENDOR>_ACCOUNT_FLAGGED`; such a row's reason reads `account flagged (unusual activity)`, its
status stays `usage_limit`). Once a usage limit leaves a take no account on its route (a pinned or
picked take: its own limit) the take relaunches with `--route <next>` from the manifest's `routes`,
if that route's `counts` carry the take's count (`--route cli after a usage limit`; a pool take lets
the wrapper pick there). Free pool accounts go least recently used first (the roster's `last_used`,
else this run's launches), ties in roster order. Before every launch: memory pressure normal and
available memory ≥ the memory guard's kill line (`GUARD_AVAIL_MB` in `bin/chat-load`) + 1200 MB
(memlogd's `available_mb` reader), else launches hold (`image-fanout: holding launches: <why>` on
stderr) — nothing is ever killed for memory. A launch also waits until the previous job's Chrome is
up or 3 s passed; Chrome is found among the job's descendants by parent pid, since Playwright starts
it in a session of its own. Every job runs in its own session (process group) with
`IMAGE_JOB_ID=<run id>-<request>-<take>`.

`--takes N` (with `--accounts all` only) is a pool: N takes per vendor over its logged-in accounts,
plus `spares[image]` from the manifest — `max(min, ceil(N × ratio))` extra takes launched up front
(`--spare <n>` overrides, `--spare 0` opts out; video never gets spares). Once N takes are delivered
(counted from `dest=`/`variant=` lines, not exit codes) the rest are ended by process group and
descendants (TERM, 5 s, KILL; the schedule runs on meanwhile, the account and slot held until the
job is gone) and listed as `spare-cancelled`. A packed request's spare launches only after its pack
ran 90 s without delivering (`IMAGE_FANOUT_LAZY_SPARE_MS`): the pack usually lands first, and a
spare cancelled after sending still spends an image (at 20 s it launched and sent on every run, clean
or loaded). Take k lands at `<vendor>-<account>.<ext>` for k = 1, else
`<vendor>-<account>-<k>.<ext>`. Takes of a pool on a vendor whose first route lists `counts` (gemini
Flow, codex web) launch packed, up to its largest count per `--count` job; each delivered variant is a take.
`--pack N` (1-4) caps a pack, `--pack 1` opts out. Measured 2026-10-03: a Flow `--count 4` renders
in the time of one image (9.4 s per image against 47 s unpacked) and holds one browser, not four; a
ChatGPT `--count 3` is three chats in tabs of one browser on one account (2026-10-04, load ~30: 26-52 s
for all three against 24 s for one).
Without `--takes` every logged-in account gets one pinned take, as before. Edits of a delivered
take resume that take's session instead.
An explicit `--account` (including `--accounts all`) is a pin and is not claimed.

`--jobs <abs jsonl>` replaces `--prompt`/`--ref`/`--edit`/`--aspect`/`--size`/`--transparent`: one JSON
object per line `{prompt, dest, refs[], edit, aspect, size, transparent, vendor, account, takes}`.
`dest` (absolute, required) is take 1's file, `<stem>-<k>.<ext>` the others, `<stem>-<vendor>.<ext>`
per vendor when `vendor` names several; `vendor` defaults to `--vendors`, `takes` to `--takes` or 1,
`account` pins one account (`pick` routes). All jobs share one schedule and one table.
`--dry-run` prints the per-row command and adaptations, spends nothing, and writes
nothing under `--dest-dir`. `--video` requires at least one `--ref` (usage error,
exit 2) before any planning. `--aspect auto` is passed through when the vendor lists
it, otherwise the flag is dropped (vendor default) and the adaptation is reported.
Roster rows whose lister status is `login needed` / `Not logged in` are `skipped`
with reason `login needed`. Wrapper exit 4 (pool disabled) is `skipped`, not `failed`.
Outputs land at `<dest-dir>/<vendor>-<account>.png` (`.mp4` for video; pick mode uses
`<vendor>-pick.<ext>`). The table is `<dest-dir>/fanout.tsv` (live runs only), one row per
delivered file (a packed job's variants each get one) with the vendor's `job`, `route`,
`fallback_from`, `phases` and `composite` appended; `<dest-dir>/fanout.state.json` holds the live cells
(`vendor, account, status, exit, job, dest, take, request`). Exit 0
if any row is `ok`, 3 if every attempted row hit a usage limit, 2 on usage errors,
1 otherwise. A `caps=stale` / `model_caps=stale` token on a row is repeated as
`STALE: <vendor> <account> <token>` under the table.

## Manifest re-verification

`image_caps_check` compares the live CLI version to `cli.version` in the manifest.
`image_caps_model_check` compares the observed image/video model to `model.image` /
`model.video`. Either going stale means the binary (or the served model) moved and the
JSON may be lying about refs, aspects, or tools.

Procedure: follow the vendor page's re-verify section, update
`share/image-caps/<vendor>.json`, bump `verified` and `cli.version`, run that vendor's
image suite (`tests/test_codex_image.sh`, `tests/test_gemini_image.sh`,
`tests/test_grok_image.sh` / `tests/test_grok_video.sh`, `tests/test_gemini_video.sh`). Details:
[`share/image-caps/README.md`](../share/image-caps/README.md).

## Resume (multi-turn)

Each wrapper prints `session=` (and `account=`). A second turn on the same thread:

```bash
# Codex / Grok recover the account from the session store; Gemini requires --account
bin/codex-image --dest /tmp/badge-bluer.png --prompt 'now make it bluer' \
  --resume "$session"
bin/gemini-image --dest /tmp/badge-bluer.png --prompt 'now make it bluer' \
  --resume "$session" --account "$account"
bin/grok-image --dest /tmp/badge-bluer.png --prompt 'now make it bluer' \
  --resume "$session"
```

`--resume` takes the UUID from `session=`, never a thread title. No `--ref` is required:
the wrapper asks the model to edit the last image in that conversation. An explicit
`--ref` overrides that. Fan-out does not resume; pick the row and call the wrapper.

## Local composite and edit lineage

Every vendor's edit re-renders the whole image, so chained edits drift what nobody asked to change.
Two local tools answer it ([gemini page](image-vendors/gemini.md#local-composite-and-edit-lineage)):

- `share/image_composite.py` pastes only the changed part of an edited image back onto its input
  (mask: `auto` difference map, an `x,y,w,h` rectangle, or `--point x,y` areas). Composite is ON BY
  DEFAULT for every edit of an existing image on every wrapper and route — one input (`--edit`, else a
  single `--ref` or the `--resume` session's last delivered image) and the input's aspect; otherwise
  `composite=skipped reason=...`. It refuses a global edit (over 60% changed:
  `composite=refused reason=global changed=N%`, the model's image delivered), keeps the model's image as
  `<dest stem>.rendered.<ext>` (`rendered=`) whenever it changed the delivered pixels, and runs on each
  Flow `--count` take. `--no-composite` opts out; never with `--transparent` or Flow's `--remove-bg`, on codex `--remove-bg`
  only asked ([background removal](#background-removal));
  `--composite[=auto|x,y,w,h]` forces it and picks the mask; `codex-image --region`/`--point` feed it.
- `<dest>.edit.json` `{root, depth, edits:[{prompt, region, points, route, vendor, account, composite}]}`
  beside every `gemini-image`, `codex-image` and `grok-image` output, accumulated through `--ref` /
  `--resume` inputs; the run's last line is `edit_depth=<n> root=<path>`. Composited small edits keep
  chaining on the last result; only after a refused (global) composite or with `--no-composite`, from
  the third edit on, go back to `root` and apply all `edits` in one.

## Background removal

Every generative route RE-RENDERS the image: ChatGPT's Remove BG (`codex-image --route web
--remove-bg`) and every `--transparent` route reframe it, brighten it and redraw fine detail, while
identity holds (checked by eye 2026-10-02: the same face). On that photo, aligned by keypoints, the
face's mean abs RGB difference from the input was Remove BG 22.3, web `--transparent` 21.3, CLI
`--transparent` 14.1, and after matching brightness/contrast 6.6 / 6.4 / 3.4 (about one edit pass).
An unaligned diff is meaningless here: the web routes scale the frame ~0.92 and shift it. Hair edges
are the generative routes' strength; exact pixels are `image-cutout`'s.

- **Default for photos — ChatGPT's Remove BG** (`codex-image --route web --remove-bg`; `--transparent`
  for a new asset): people, hair, fur, glass, foliage (Egor, 2026-10-06). `image-cutout` leaves the old
  background between loose hair strands and fragments of it around a glass (seen by eye; `--edge soft`
  only refines the outer edge); ChatGPT also cleans the edge's colour, so a dark background leaves no dark
  fringe. Its tone shift is small (a little brighter) and a composite is regraded anyway: the cutout is
  delivered as is.
- **`--remove-bg --composite`** when the subject's own pixels must stay exact (a face whose likeness is
  judged, a label): `share/image_matte.py` registers the cutout back onto the input (SIFT, RANSAC
  similarity) and delivers, in the input's frame and size, the cutout's alpha, the input's pixels inside
  the subject and, in a band along the edge (1.2% of the short side), the cutout's own pixels toned locally
  to the input, so the hair edge stays ChatGPT's. On the 2026-10-02 portrait the face came out
  pixel-exact with a clean hair edge. A cutout it cannot lay back (a decal ChatGPT redrew flat:
  `reason=unregistered`; an edge band over 45 mean abs RGB off: `reason=redrawn`) is delivered as is.
  Prints `composite=matte changed=<% of the subject from the cutout>` and `rendered=` (ChatGPT's cutout).
- **Local — exact pixels: `bin/image-cutout`** (local macOS Vision subject lift, free, no network,
  0.3–0.9 s; the first run compiles `share/image-cutout.swift` into
  `~/.cache/image-cutout/<source hash>/`, ~8 s). Kept RGB is byte-identical to the input's decode and
  the input's colour profile is kept; only alpha is added. Use it for logos, decals, flat graphics and
  hard-edged objects, anything private, batches, and whenever ChatGPT is walled.

  ```bash
  image-cutout --in /abs/photo.jpg --dest /abs/cut.png --dry-run      # lists instance=<n> center= box= area=
  image-cutout --in /abs/photo.jpg --dest /abs/cut.png --keep 0.3,0.6 # only the instance under that point
  image-cutout --in /abs/logo.jpg --dest /abs/cut.png --holes         # also clear see-through holes
  ```

  Points are `x,y` fractions of the image (0,0 top left); a point off every subject picks the
  nearest instance; default keeps every instance. Vision's whole-frame pass returns only the
  dominant subjects (a teapot, not the small apple beside it), so the halves and quadrants are
  re-run as regions of interest and each whole object they find outside the known instances becomes
  one more instance (~+0.5 s; single-subject masks are unchanged). `--edge soft` (default) re-estimates alpha in a
  band around Vision's edge from local subject/background colour (hair: background-coloured
  pixels' mean alpha 0.30 → 0.26, subject-coloured 0.70 → 0.76); `--edge hard` is a binary mask.
  `--holes` removes kept pixels close to the removed background's colour clusters — on the pink
  decal it cleared the window showing through (40 % of the kept area) with no pink pixel lost;
  on photos it eats the subject (64–84 % of the kept area), so logos/decals/flat graphics only, and
  check the `holes=` share it prints. Exit 1: no subject, or the points leave nothing.
- **Flow's Cutout** (`gemini-image --remove-bg`, MODNet on-device in Flow's Image Editor; the input's
  own pixels under Flow's matte) exists for parity only. On 2026-10-03 it ate half the hair of a
  portrait, kept background fragments, and melted a flat teapot scene, where `image-cutout` was
  clean on both; Flow's BEN2 option fails in the page. Don't pick it.
- Never hand-roll thresholding, chroma keys or a mask of your own on a real image.

## Likeness of a real person

Takes of a real person are ranked by a face-recognition score, never by a model's eye: Fable, Opus, Sol,
Grok and Gemini picked the closer of two takes at chance on the art director's 126 rated pairs, even on
clearly different faces; Astra refuses. The scorer is the video harness's `likeness.py`, the AdaFace IR101
cosine of a take's face to the person's own photos. ArcFace R50/R100, DINOv2, CLIP, DreamSim, age, 3D
landmarks and their ensembles did no better (`/Volumes/Work/Projects/video/research/likeness/REPORT.md`).

```bash
uv run -q --script /Volumes/Work/Projects/video/harness/skill/scripts/likeness.py <take>... --ref <photo>... [--features]
```

- Score all compared takes against ONE pool: the person's photos minus every photo any of them used as a
  reference. A reference inflates its own takes, and a pool per take flattered the agreement (25 against
  21 of 34 near-tie pairs).
- It shortlists, it does not pick: own photos score 0.63–0.74, strangers ≤ 0.05; a gap under 0.03 is a
  tie, and near-ties go to the eye of someone who knows the face, on the finished frames side by side.
- Photoreal faces of one base frame, closed mouths where possible; profiles are skipped. `--features`
  prints eye tilt, face width, jaw, nose and lips as σ against the photos: what differs, not a ranking.
