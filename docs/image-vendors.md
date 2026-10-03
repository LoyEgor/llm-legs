# Image vendors

Index for the subscription image/video legs. Each vendor's evidence and knobs live
under [`docs/image-vendors/`](image-vendors/):

| Vendor | Wrapper | Notes |
| --- | --- | --- |
| [Codex](image-vendors/codex.md) | `bin/codex-image` | Built-in `image_gen`; no aspect argument — `--aspect`/`--size` are one builder's prose on both routes, checked by `aspect=`; `--region`, `--point`, `--remove-bg` web-only; no video |
| [Gemini](image-vendors/gemini.md) | `bin/gemini-image`, `bin/gemini-video` | Default: Nano Banana Pro/2/2 Lite on Google Flow (0 credits, 1-4 takes, 10 refs, five aspects, 2K); `--route cli`: agy `generate_image` (3 refs, seven aspects); video on Google Flow (Veo 3.1 / Omni) through a hidden Chrome |
| [Grok](image-vendors/grok.md) | `bin/grok-image`, `bin/grok-video` | Imagine image + video; chroma transparency |

Runtime limits are the JSON manifests in [`share/image-caps/`](../share/image-caps/README.md),
not these pages. Re-verify a manifest when a run prints `caps=stale` or `model_caps=stale`.

## Capability matrix

Route a request by this table; every cell follows from the vendor's manifest (`api_only` names what the
vendor API has and its CLI does not carry). No vendor has a mask, a fidelity flag or a seed.

| Capability | codex | gemini | grok |
| --- | --- | --- | --- |
| Extend / outpaint the frame | ref + "extend the scene" + `--aspect` (prose, `fit=` checked); web: viewer Resize via `--resume --aspect` | ref + a wider `--aspect` (Flow's 5 ratios, nearest one taken; `--route cli`: 7); without `--prompt`: Flow's Image Editor Outpaint (16:9, 4:3, 1:1, 3:4, 9:16; an unfilled black side exits 1) | `--ref` ×2+ with a wider `--aspect`; a single-ref edit keeps the source ratio |
| Edit a region | web route only: `--region x,y,w,h` (Markup outline), `--point x,y=<text>` (Comment pins) feed the mask; CLI exit 2. Every edit composited by default | Flow's Image Editor Inpaint: `--region x,y,w,h` + `--prompt`, or `--point x,y=<text>` (brush mask, composited onto it; `pro` recommended); otherwise prompt only, every edit composited by default, `--composite=x,y,w,h` pastes only that rectangle | prompt only (`image_edit`); every edit composited by default |
| Keep identity across edits | ref + "preserve identity", `--resume` | ref, `--resume` needs `--account` and stays on the route that made the session; Flow keeps the face sharper over chained edits | first choice: `image_edit` + `--resume` |
| References max | 5 (unverified) | 10; `--route cli` 3 | 3 (API: 5) |
| Transparency | native alpha, chroma fallback; web: `--remove-bg` (Remove BG, a regeneration) | chroma (both routes); `--remove-bg` = Flow's on-device Cutout (MODNet, poor on both test images — prefer `image-cutout`) | chroma (API background removal: `api_only`) |
| Quality control | none | none | none (API `low\|medium\|auto`: `api_only`) |
| Exact size | no (size as prose) | no | no |
| 1K / 2K | no | 1K, `--upscale 2k` (`--route cli`: no) | no (`api_only`) |
| Video | no | `gemini-video`: text, first/last frame, up to 3 (Veo) or 4 (Omni) image refs, or `--edit` of any video up to 30 s (Omni, `--ref` puts a character or object into it), `--extend` of a Flow Veo clip (+7 s, 720p), `--count 2–4` takes → 8 s Veo 3.1 Lite/Fast/Quality or 4–10 s Omni Flash; 16:9 or 9:16; 360p/720p, 1080p via Flow's free upscale; audio; Flow credits | `grok-video`: 1 ref → 6/10 s, up to 14 refs → 1–15 s, pinned first/last frames and up to 4 keyframes, 480p/720p (API 1080p: `api_only`) |
| Audio | no | `gemini-music` (Lyria 3.5 in the Gemini app: ≈60 s or 2–3 min, mp3/wav, sections from a brief, `--video` to watch the cut, `--ref-image`), `gemini-sfx` (a Flow Omni soundtrack, trimmed and normalised; `--for-video` ≤ 10 s), `gemini-listen` (agy watches and hears files) | no |

## Soft vs hard fan-out adaptations

`bin/image-fanout` takes one request and runs every selected vendor × account in parallel,
adapting each call from that vendor's manifest.

- **Hard** — skip the vendor. `video: null` against `--video` is the one hard skip.
- **Soft** — still run, and report the change in the row's reason:
  - too many `--ref` → truncate to `refs.max` (or `video.refs_max` on `--video`; `flow_image.refs_max` for a vendor whose `default_route` is `flow`)
  - unsupported `--aspect` → nearest value in `aspects.generate` / `aspects.edit` (edit when any `--ref` is kept; `flow_image.aspects` under `default_route: flow`); when `aspects` is `null` (Codex), pass `--aspect W:H` and the script's own sentence builder words it
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

`--takes N` (with `--accounts all` only) runs N independent takes per vendor at once,
round-robin over its logged-in accounts: `<vendor>-<account>.<ext>`, then
`<vendor>-<account>-2.<ext>` when there are fewer accounts than takes. Edits of a delivered
take resume that take's session instead.
An explicit `--account` (including `--accounts all`) is a pin and is not claimed.
`--dry-run` prints the per-row command and adaptations, spends nothing, and writes
nothing under `--dest-dir`. `--video` requires at least one `--ref` (usage error,
exit 2) before any planning. `--aspect auto` is passed through when the vendor lists
it, otherwise the flag is dropped (vendor default) and the adaptation is reported.
Roster rows whose lister status is `login needed` / `Not logged in` are `skipped`
with reason `login needed`. Wrapper exit 4 (pool disabled) is `skipped`, not `failed`.
Outputs land at `<dest-dir>/<vendor>-<account>.png` (`.mp4` for video; pick mode uses
`<vendor>-pick.<ext>`). The table is `<dest-dir>/fanout.tsv` (live runs only). Exit 0
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
  DEFAULT for every edit of an existing image on every wrapper and route — one input (a single `--ref`
  or the `--resume` session's last delivered image) and the input's aspect; otherwise
  `composite=skipped reason=...`. It refuses a global edit (over 60% changed:
  `composite=refused reason=global changed=N%`, the model's image delivered), keeps the model's image as
  `<dest stem>.rendered.<ext>` (`rendered=`) whenever it changed the delivered pixels, and runs on each
  Flow `--count` take. `--no-composite` opts out; never with `--remove-bg`/`--transparent`;
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

- **Default — exact pixels: `bin/image-cutout`** (local macOS Vision subject lift, free, no network,
  0.3–0.9 s; the first run compiles `share/image-cutout.swift` into
  `~/.cache/image-cutout/<source hash>/`, ~8 s). Kept RGB is byte-identical to the input's decode and
  the input's colour profile is kept; only alpha is added. Use it for photos, people, products and
  anything private.

  ```bash
  image-cutout --in /abs/photo.jpg --dest /abs/cut.png --dry-run      # lists instance=<n> center= box= area=
  image-cutout --in /abs/photo.jpg --dest /abs/cut.png --keep 0.3,0.6 # only the instance under that point
  image-cutout --in /abs/logo.jpg --dest /abs/cut.png --holes         # also clear see-through holes
  ```

  Points are `x,y` fractions of the image (0,0 top left); a point off every subject picks the
  nearest instance; default keeps every instance. `--edge soft` (default) re-estimates alpha in a
  band around Vision's edge from local subject/background colour (hair: background-coloured
  pixels' mean alpha 0.30 → 0.26, subject-coloured 0.70 → 0.76); `--edge hard` is a binary mask.
  `--holes` removes kept pixels close to the removed background's colour clusters — on the pink
  decal it cleared the window showing through (40 % of the kept area) with no pink pixel lost;
  on photos it eats the subject (64–84 % of the kept area), so logos/decals/flat graphics only, and
  check the `holes=` share it prints. Exit 1: no subject, or the points leave nothing.
- **Generative** (`codex-image --route web --remove-bg`, `--transparent`) when looking the same
  is enough and pixels need not match: the finest hair edges, a logo or illustration to be cleaned
  up anyway, or a new asset. `image-cutout` keeps the old background visible between loose hair
  strands (seen by eye; `--edge soft` only refines the outer edge).
- **Flow's Cutout** (`gemini-image --remove-bg`, MODNet on-device in Flow's Image Editor; the input's
  own pixels under Flow's matte) exists for parity only. On 2026-10-03 it ate half the hair of a
  portrait, kept background fragments, and melted a flat teapot scene, where `image-cutout` was
  clean on both; Flow's BEN2 option fails in the page. Don't pick it.
- Never hand-roll thresholding or chroma keys on a real image; `image-cutout` is the tool.
