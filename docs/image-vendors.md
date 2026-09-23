# Image vendors

Index for the subscription image/video legs. Each vendor's evidence and knobs live
under [`docs/image-vendors/`](image-vendors/):

| Vendor | Wrapper | Notes |
| --- | --- | --- |
| [Codex](image-vendors/codex.md) | `bin/codex-image` | Built-in `image_gen`; no aspect argument; `--size` is prose; no video |
| [Gemini](image-vendors/gemini.md) | `bin/gemini-image` | agy `generate_image`; 3 refs; seven aspect ratios; no video |
| [Grok](image-vendors/grok.md) | `bin/grok-image`, `bin/grok-video` | Imagine image + video; chroma transparency; the only video vendor |

Runtime limits are the JSON manifests in [`share/image-caps/`](../share/image-caps/README.md),
not these pages. Re-verify a manifest when a run prints `caps=stale` or `model_caps=stale`.

## Capability matrix

Route a request by this table; every cell follows from the vendor's manifest (`api_only` names what the
vendor API has and its CLI does not carry). No vendor has a mask, a fidelity flag or a seed.

| Capability | codex | gemini | grok |
| --- | --- | --- | --- |
| Extend / outpaint the frame | ref + "extend the scene"; ratio as prose only | ref + a wider `--aspect` (7 ratios) | `--ref` ×2+ with a wider `--aspect`; a single-ref edit keeps the source ratio |
| Edit a region | prompt only | prompt only | prompt only (`image_edit`) |
| Keep identity across edits | ref + "preserve identity", `--resume` | ref, `--resume` needs `--account` | first choice: `image_edit` + `--resume` |
| References max | 5 (unverified) | 3 | 3 (API: 5) |
| Transparency | native alpha, chroma fallback | chroma | chroma (API background removal: `api_only`) |
| Quality control | none | none | none (API `low\|medium\|auto`: `api_only`) |
| Exact size | no (size as prose) | no | no |
| 1K / 2K | no | no | no (`api_only`) |
| Video | no | no | `grok-video`: 1 ref → 6/10 s, up to 14 refs → 1–15 s, pinned first/last frames and up to 4 keyframes, 480p/720p (API 1080p: `api_only`) |

## Soft vs hard fan-out adaptations

`bin/image-fanout` takes one request and runs every selected vendor × account in parallel,
adapting each call from that vendor's manifest.

- **Hard** — skip the vendor. `video: null` against `--video` is the one hard skip.
- **Soft** — still run, and report the change in the row's reason:
  - too many `--ref` → truncate to `refs.max` (or `video.refs_max` on `--video`)
  - unsupported `--aspect` → nearest value in `aspects.generate` / `aspects.edit` (edit when any `--ref` is kept); when `aspects` is `null` (Codex), append ` (aspect ratio W:H)` to the prompt
  - `--size WxH` → passed only if `exact_size` is true; otherwise treated as an aspect and mapped as above
  - `--transparent` → forwarded to every image wrapper; each wrapper applies its own `transparent` mode (`native`, `chroma`, `native+chroma`)

## Fan-out usage

```bash
# Every vendor, every logged-in account (disabled accounts stay in; the wrapper skips them)
mkdir -p /tmp/badge-fanout
bin/image-fanout --dest-dir /tmp/badge-fanout \
  --prompt 'a round blue enamel badge, white background' \
  --aspect 1:1 --transparent

# Video: only vendors with a video block (today: grok). Needs at least one --ref.
bin/image-fanout --dest-dir /tmp/badge-fanout --video --duration 6 \
  --prompt 'slow gentle push-in' --ref /tmp/badge-fanout/grok-notcom.png
```

`--accounts pick` launches one job per vendor **without** `--account`: each wrapper
routes through `worker-pick --account <vendor> --role image` and records a claim.
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
`tests/test_grok_image.sh` / `tests/test_grok_video.sh`). Details:
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
