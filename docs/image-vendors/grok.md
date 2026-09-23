# Grok images and video through the Grok Build CLI

Verified on 2026-09-11 against **grok 1.0.13 (5e9a58528b76)** and re-verified on 2026-09-17
against **grok 1.0.34 (3736acbc8658)** (image tool schemas unchanged; `grok-imagine-image-2.0`
pinned through `features.image_gen_model_override` and `features.image_edit_model_override`),
launched by `grokb` on a SuperGrok subscription. The runtime contract is [grok.json](../../share/image-caps/grok.json);
its `field_sources` maps each capability to the evidence below. This page concerns the
subscription CLI's Imagine tools, not the xAI Imagine REST API, whose parameter surface is
strictly wider.

Two wrappers read that one manifest: [`bin/grok-image`](../../bin/grok-image) for
`image_gen`/`image_edit` and [`bin/grok-video`](../../bin/grok-video) for
`image_to_video`/`reference_to_video`. Shared routing, harvesting and locking live in
[`share/grok-media.sh`](../../share/grok-media.sh).

## Image capabilities and evidence

| Capability | Result | Source |
| --- | --- | --- |
| Text to image | `image_gen`, fields `prompt` and `aspect_ratio` only | B1 |
| Edit and references | `image_edit`, fields `image` (array), `prompt`, `aspect_ratio` | B2 |
| Reference count | **3** in practice: with 4 refs the agent answered in text and never called `image_edit` (live, 2026-09-11, `notcom`); 3 refs generated `1248x832`. The endpoint documents 5, the CLI schema states no cap | live bisect, D2, B2 — manifest `refs.verified_max: true` |
| Aspect, generate | `1:1`, `16:9`, `9:16`, `3:2`, `2:3`, `auto` | B1 |
| Aspect, edit | `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`, `2:1`, `1:2`, `19.5:9`, `9:19.5`, `20:9`, `9:20`, `auto` | B2 |
| Default aspect | `auto` on both tools; the wrapper's default too | B1, B2 |
| Single-image edit ratio | The parameter is ignored; the source ratio is kept | B2 |
| Exact dimensions / resolution / quality | No such parameter on either tool | B1, B2 |
| Multiple outputs | No `n`: “To produce multiple images, emit multiple tool calls with distinct prompts.” | B1 |
| Transparency | Wrapper chroma key onto a `.png`; no alpha or background parameter, the client writes `jpg` | B2, B5, [chroma implementation](../../share/image-chroma.sh) |
| Image model | `grok-imagine-image-quality` compiled in; `grok-image` pins the manifest's `grok-imagine-image-2.0` in `features.image_gen_model_override` AND `image_edit_model_override`, so generation and editing run on the same model. A deliberate pin: the remote settings leave both keys null, so unpinned runs would fall back to the retiring compiled-in model | B5, B8 |
| Parallelism | `tools.media_gen.max_parallel_image_gen_calls` (default 8, also `GROK_MAX_PARALLEL_IMAGE_GEN_CALLS`) caps image calls per model step; the wrapper asks for one image | B8 |
| Resume | `--resume <UUID>` → `grok -r`; the id is the terminal event's `sessionId` | B6, D1 |
| Generated file | `tool_call_update` with `rawOutput.type` `ImageGen` or `ImageEdit`, absolute `.path` | B5 |

The wrapper refuses an out-of-enum aspect **before** launching: the CLI forwards the string
to the images endpoint unvalidated and the generation is billed the moment it goes out. An
edit-only ratio passed without `--ref`/`--resume` gets its own message naming the two enums.

`--resume` takes a UUID only. A non-UUID value is not an id to Grok — it is a session
**title** matched against the current working directory (B6), and the wrapper's cwd is a
fresh temp dir that owns no sessions, so such a value resolves to nothing or to a stranger's
same-titled session. A resumed run always reaches `image_edit`, with or without a new `--ref`.

## Video capabilities and evidence

| Capability | Result | Source |
| --- | --- | --- |
| One source image | `image_to_video` — fields `image`, `prompt`, `duration`, `resolution_name` | B3 |
| Two or more images, or voices | `reference_to_video` — `images`, `prompt` (required), `voices`, `duration`, `resolution_name`, `aspect_ratio` | B3 |
| Reference images | up to **7**; runtime guard “`images` must contain at most N image references.” | B3 |
| Voices | up to **3** preset ids; the roster is not enumerable offline, examples `ara`, `eve`, `leo`, `rex` | B3 — manifest `video.voices: null` |
| Duration, `image_to_video` | `6` or `10` seconds, default `6`; guard “`duration` must be either 6 or 10 seconds.” | B3 |
| Duration, `reference_to_video` | `1`–`15` seconds, default `6` | B3, B7 |
| Resolution | `480p` or `720p`, default `480p`, on both tools | B3 |
| Aspect | `reference_to_video` only: `1:1`, `16:9`, `9:16`, `4:3`, `3:4`, `3:2`, `2:3`. `ImageToVideoInput` has no aspect field at all | B3 |
| Text to video | **Unsupported:** “Video starts from an image — there is no text-to-video tool.” | B7 |
| Video model | `grok-imagine-video-1.5`; no `video_gen_model_override`, so the CLI version pins it | B4 |
| Output | `videos/1.mp4` in the session folder; the client sends `video/mp4` | B3, B5 |
| Generated file | `tool_call_update` with `rawOutput.type == "ImageToVideo"` — both tools answer under that one tag | B3, B5 |

`grok-video --aspect` with a single `--ref` and no `--voice` is refused rather than silently
dropped: the shape selects `image_to_video`, which takes no ratio. The message points at
`grok-image --aspect` on the source image, or at adding a second `--ref`/a `--voice`.

Because `mdls` only answers on Spotlight-indexed volumes and a video with no readable
duration cannot be reported honestly, `grok-video` requires `ffprobe` or `mdls` **before**
spending, and on an unmeasurable result keeps the file and exits 1 rather than printing a
guessed `size=`/`duration=`.

Unsupported across both wrappers: **`n`/output count, resolution or exact pixel size for
images, quality, seed, mask, native transparency, `response_format`, per-call model
selection, text-to-video, and an aspect ratio for `image_to_video`.** D3 shows the Imagine
REST API does expose `n`, resolution and quality — their absence is a CLI limit, not a model
one.

## Binary and local evidence

Dumps are `strings -n 8` over `~/.grok/bin/grok-1.0.13` (~133 MB), plus the offsets pass that
recovers each schema's field order.

**B0 — version.** `grok --version` prints `grok 1.0.13 (5e9a58528b76)`; the same
`1.0.13 (5e9a58528b76)` string is compiled in. `image_caps_check` compares it and reports
`caps=fresh` or `caps=stale cli=X verified=Y`.

**B1 — `ImageGenInput`.** Two fields, `prompt` and `aspect_ratio`:

> Aspect ratio of the generated image, decide it based on the user's request. Defaults to
> 'auto'. 1:1 for square (icons, profiles), 16:9 for wide (landscapes, cinematic), 9:16 for
> tall (phone wallpapers, stories), 3:2 for horizontal photos, 2:3 for vertical (portraits,
> posters).

The tool description adds “To produce multiple images, emit multiple tool calls with distinct
prompts.” There is no size, resolution, count, seed, model or transparency field.

**B2 — `ImageEditInput`.** Three fields: `image` (array of sources), `prompt`, `aspect_ratio`.
The ratio string enumerates the fourteen values in the table and records that a single-image
edit ignores the parameter and keeps the source ratio. The `image` field's own description
carries **no** maximum — no “at most”, no “up to”, no array-length guard in the binary, unlike
the video tools which have both. Five therefore comes from D2, and the manifest marks it
`verified_max: false`.

**B3 — video tool schemas.** `image_to_video`: “Generate a video from a single source image;
returns the saved video's absolute path. When telling the user where it was saved, refer to it
by its short session-relative path (e.g. `videos/1.mp4`)…”. `ImageToVideoInput` has four
elements — `image`, `prompt`, `duration`, `resolution_name` — and no aspect ratio.
`reference_to_video`: “Generate a video from reference images and/or preset voices, guided by a
required text prompt”, with “Reference images, up to 7 entries… Each entry may be an absolute
filesystem path, HTTPS URL, or `data:image/...;base64,...`”, voices “up to 3 entries… a voice
identifier from the built-in roster (e.g. "ara", "eve", "leo", "rex"; same voices as the xAI
text-to-speech API; an unknown identifier fails with the list of available voices)”, and
“Duration of the video in seconds, between 1 and 15. Defaults to 6.” The runtime guards
`` `images` must contain at most N image references. ``,
`` `voices` must contain at most N preset voices. `` and
`` `duration` must be either 6 or 10 seconds. `` confirm the caps are enforced server-side too.

**B4 — video model.** `grok-imagine-video-1.5` sits next to the video generation module; the
same id appears in the vendor's reference-to-video documentation. No override key exists for
it.

**B5 — media clients and stream shape.** The image client is compiled against
`grok-imagine-image-quality` and writes `jpg`; the download client sends `video/mp4`. The
headless stream (`--output-format streaming-json`) is NDJSON: a `tool_call` when the tool
starts, a `tool_call_update` with `rawOutput: null` while it runs, then a completed
`tool_call_update` whose `rawOutput` is a `MediaGenOutput` — `type`, `path`, `filename`,
`session_folder`, optionally `uploaded_url`. `type` is `ImageGen`, `ImageEdit` or
`ImageToVideo`. The terminal `end` event carries `sessionId`. Both wrappers harvest the last
matching `rawOutput.path` for their own tag list only; a still frame under an `ImageGen` tag is
never accepted as a video.

**B6 — resume semantics.** `-r, --resume <SESSION_ID_OR_TITLE>`: “Resume a session by ID or
title, or the most recent if omitted. Non-ID values match session titles for the current
directory, ignoring letter case; UUID-shaped values always mean IDs. Among duplicate titles a
sole renamed match wins; otherwise the resume fails as ambiguous.” `-c/--continue` continues
the most recent session **in the current directory** — useless to a wrapper that runs in a
fresh temp cwd. `-s/--session-id` names a **new** session's UUID and no longer upserts; with
`-r`/`-c` it is legal only together with `--fork-session`, which forks history into a new id.
The bundled headless guide repeats: “Headless mode starts a fresh session by default.”

**B7 — bundled Imagine guidance.** The CLI ships prose repeating that `reference_to_video`
accepts 1–15 s and that “Video starts from an image — there is no text-to-video tool. Default
to `image_to_video`; use `reference_to_video` when the user explicitly asks for it, a shot
genuinely needs multiple references…”.

**B8 — configuration keys.** `features.image_gen_model_override` (“Imagine model id for
image_gen. Empty defers to the remotely configured default.”),
`features.image_edit_model_override`, and
`tools.media_gen.max_parallel_image_gen_calls` (“Cap parallel image_gen/image_edit calls in one
model step. Also `GROK_MAX_PARALLEL_IMAGE_GEN_CALLS`.”, sample config shows `8`). Because an
empty override defers to a remote default the CLI never reports back, `grok-image` writes the
manifest id into both keys before every launch and reports the override it finds back, compared
against the manifest; an unverified CLI may no longer read the knob at all, so there the run
prints `model=unknown model_caps=unknown`.

**D1 — headless documentation.** docs.x.ai's headless/output-format pages describe
`--output-format streaming-json` and resuming by the reported session id.

**D2 — multi-image editing.** docs.x.ai: “Use up to five source images for a single image
edit.” This is the only stated reference cap anywhere; a widely repeated “three references”
figure did not survive checking against the vendor's own page.

**D3 — Imagine REST API.** The public API exposes `n`, resolution and quality knobs that no CLI
tool schema has. Present in the vendor's docs, absent from the tools — which is why they are in
`unsupported` rather than silently emulated.

## Account routing, sessions and locking

`worker-pick --account grok` returns a usable account (rc 0) for the image scripts; the
“grok: off for workers” note applies to code workers, not to these wrappers. On a wall,
`worker-pick` exits 3, the wrapper prints `GROK_USAGE_LIMIT` and exits 3 too. A pool refusal is
exit 4.

A session lives in exactly one profile's store,
`<GROK_HOME>/sessions/<url-encoded cwd>/<session-id>/`, so `--resume` may not go through the
selector: any other account simply cannot see the id. Given `--resume` without `--account`,
`grok_media_account_for_session` finds the owning store and uses it; with no owner it exits 1
asking for `--account`. `main` uses `~/.grok`, named accounts `~/.grok-profiles/<account>`.

`grok-video` additionally takes a per-account directory lock
(`$TMPDIR/grok-video.<account>.lock`, wait `GROK_MEDIA_LOCK_WAIT` = 900 s, stale
`GROK_MEDIA_LOCK_STALE` = 1800 s) so two clips never race one account.

Both wrappers launch with `GROK_MEMORY=0`, `--always-approve`, `--disable-web-search`,
`--no-subagents`, a bounded `--max-turns`, a private `--cwd`, and `--tools` restricted to the
single tool the run needs — `image_gen` **or** `image_edit`, never both, so a reference run
cannot spend the generation on the tool whose ratio enum the gate just refused.

## Final lines

`grok-image` prints exactly seven lines: `dest`, `size`, `format`, `account`, `session`,
`model=... model_caps=...`, `caps=...`. `grok-video` prints eight, inserting `duration=` after
`format=`. `session=none` means the stream carried no `sessionId`.

## Resume example

```bash
cd /Volumes/Work/Projects/llm-legs
mkdir -p /tmp/grok-image-example
bin/grok-image --dest /tmp/grok-image-example/first.png \
  --prompt 'A small red ceramic teapot on a plain wooden table' \
  > /tmp/grok-image-example/first.result
image_account=$(sed -n 's/^account=//p' /tmp/grok-image-example/first.result)
image_session=$(sed -n 's/^session=//p' /tmp/grok-image-example/first.result)
if [ -n "$image_session" ] && [ "$image_session" != none ]; then
  bin/grok-image --dest /tmp/grok-image-example/edited.png \
    --account "$image_account" --resume "$image_session" \
    --prompt 'Repaint the teapot deep blue and keep everything else unchanged'
fi
```

`--account` is optional on the second call — the wrapper recovers it from the store that holds
the session — but passing it skips the search. No `--ref` is needed: a resumed run is told to
edit the image it produced most recently in that session. Continuity depends on the agent
following that instruction; an explicit `--ref` overrides it.

A video from that image, at the cheapest settings:

```bash
bin/grok-video --dest /tmp/grok-image-example/clip.mp4 \
  --prompt 'slow gentle push-in, subtle drifting light' \
  --ref /tmp/grok-image-example/first.png --duration 6 --resolution 480p
```

## Re-verification and live-call status

On `caps=stale` or `model_caps=stale`, run `grok --version`, re-read
`~/.grok/docs/user-guide/` (headless, sessions, output formats) and take a fresh
`strings -n 8` dump of `~/.grok/bin/grok-<version>`. Search it for `ImageGenInput`,
`ImageEditInput`, `ImageToVideoInput`, `ReferenceToVideoInput`, `must contain at most`,
`aspect_ratio`, `resolution_name`, `grok-imagine-`, `image_gen_model_override`,
`max_parallel_image_gen_calls`, and `MediaGenOutput`. Update the manifest's values,
`field_sources` and `verified` date, then run:

```bash
cd /Volumes/Work/Projects/llm-legs
bash tests/run-all -j 3 test_grok_image.sh test_grok_video.sh test_consistency.sh
```

The runner discovers `test_*.sh`, so neither suite needs registration. Tests use a temporary
HOME, a fixture profile store and fake `grokb`/`grok`/`worker-pick` binaries; none opens a real
account store.

**Live verification, 2026-09-11, two generations on `rawilimo`.** A plain `image_gen` run
returned `1024x1024` with `model=grok-imagine-image-quality model_caps=fresh caps=fresh` and
session `01a08db8-…`. Resuming that id with no `--ref` produced the same teapot on the same
table with its glaze repainted blue — so a resumed run does reach `image_edit`, its answer does
arrive under the `ImageEdit` tag, and the `end` event repeats the **original** session id
(`--resume` appends; only `--fork-session` would mint a new one).

**Video needs an account that is not under zero data retention.** `image_to_video` refused
before any generation with `zdr_output_storage_required` while both accounts had the Settings row
"Coding data, retention, and training" (opened by `/privacy`) on *Opt out*: the CLI disables video
tools under ZDR unless `tools.zdr_video_output_s3` names a bucket to write to. That is an account
privacy setting, not a usage limit and not a wrapper bug — the wrapper reports it as exit 1 with its
own message, deliberately not exit 3. With `notcom` switched to *Opt in* (2026-09-11) a live run
`--ref <1280x720 png> --duration 6` returned exit 0 in ~80 s: `size=736x400 format=mp4 duration=6`,
h264 + aac, `model=grok-imagine-video-1.5 model_caps=fresh caps=fresh`, session id printed for
`--resume`. The same day `image-fanout --video --accounts all` delivered 544x544 6 s clips from
both `notcom` and `rawilimo` in 67 s; an account returned to *Opt out* would show up in that table
as the ZDR refusal, not as a limit.
