# Gemini images through Antigravity CLI

Verified on 2026-10-08 against **agy 1.3.1** (help and the binary's `generate_image` schema; the last
live `--route cli` generation ran on 1.2.16), launched by `geminib` with a Google
subscription. The runtime contract is [gemini.json](../../share/image-caps/gemini.json);
its `field_sources` maps each capability to evidence. This page concerns the subscription
CLI, not the Gemini Developer API, Vertex API, or the Python SDK's configurable models.

Since 2026-10-03 `gemini-image` runs [Google Flow](#images-on-google-flow-the-default-route) by default
(`routes[0]` in the manifest); the agy path on this page is `--route cli`.

## Capabilities and evidence

| Capability | Result | Source |
| --- | --- | --- |
| Text to image | `generate_image`, required `Prompt` and `ImageName` | B1; Google [tool inventory](https://antigravity.google/docs/sdk/tools/) |
| Edit, combine, references | Optional absolute `ImagePaths`; schema `maxItems=3` | B1, B2 |
| Aspect ratios, generate and edit | `1:1`, `2:3`, `3:2`, `3:4`, `4:3`, `9:16`, `16:9`; default `1:1` | B1, B2 |
| Outpainting | **Soft-supported:** reference + wider aspect + instructions to extend the scene | Inference from B1/B2's editing and aspect inputs; not live-verified |
| Exact dimensions / resolution | No exposed control | B1, B3; `agy --help` |
| Transparency | Wrapper chroma key; PNG destination required. Native alpha unproven | H1 JPEG output; B1 has no alpha/background parameter; [chroma implementation](../../share/image-chroma.sh) |
| Multiple outputs | One tool call per wrapper invocation; no `n` or `NumberOfImages` parameter | B1; [wrapper](../../bin/gemini-image) |
| Image model | Historical observed `gemini-3.1-flash-image`; server selection can change independently of the CLI | H1's saved `CortexStepGenerateImage.model_name`; B4 |
| Resume | `--resume ID --account NAME` maps to `agy --conversation ID` in that profile | `agy --help`; Google [headless conversation documentation](https://antigravity.google/docs/cli/headless/) |
| Session id | Terminal `.result.conversation_id`, fallback `.conversation_id` on `init` | Google headless documentation |
| Generated file | `generate_image` tool output text, final response, then invocation-specific brain rescue | H1; B5 |
| Video / audio generation | Not in agy or Gemini CLI (agy 1.2.14: `generate_image` only, no Veo/Omni model; [antigravity-cli#734](https://github.com/google-antigravity/antigravity-cli/issues/734)); served instead by `bin/gemini-video` on Google Flow, see [Video on Google Flow](#video-on-google-flow) | Binary tools implementation inventory; Google tool inventory; live Flow runs 2026-09-30 |

“Make this image wider” can be expressed with `--ref image.jpg --aspect 16:9` and a
prompt such as “Extend the scene left and right; preserve the subject and composition.”
This is a generative edit, with no mask, crop box, canvas offset, or guarantee of unchanged
source pixels. The requested aspect can be passed to the tool; the returned dimensions
must still be inspected. The wrapper reports them and does not resize an image to pretend
that the model respected the request.

Unsupported CLI controls: **resolution, exact pixel size, mask, video, audio generation,
output count (`n`), quality, native transparency, seed, and image-model selection**. A
model might respond to descriptive prose about some of these, but that is not a tool knob.
Output file conversion uses ImageMagick, not a vendor output-format parameter. The saved
artifact's actual format is inspected before copying or converting it.

## Binary and local evidence

**B1 — native tool schema.** `strings -n 8 /Users/egorloy/.local/bin/agy` exposes
`tools.generateImageArgs` and these schema tags. The reconstructed image-specific schema
is recorded in the manifest; `toolAction` and `toolSummary` in historical requests are
framework metadata, not additional media controls.

| Field | Type / schema | Complete native field description |
| --- | --- | --- |
| `Prompt` | string, required, minLength=1 | What the image should depict, or how to edit the given images. |
| `ImageName` | string, required, minLength=1 | Short descriptive name for the saved file. |
| `ImagePaths` | array of strings, maxItems=3 | Images to edit, combine, or use as references. |
| `AspectRatio` | string, enum listed above | Defaults to 1:1. |

The native tool description is: “Generate an image, or edit existing images, from a text
prompt.” There is no resolution, mask, count, model, transparency, or video field.

**B2 — bundled legacy description.** The same binary also retains a longer tool description:

> Generate an image or edit existing images based on a text prompt. The resulting image will be saved as an artifact for use. You can use this tool to generate user interfaces and iterate on a design with the USER for an application or website that you are building. When creating UI designs, generate only the interface itself without surrounding device frames (laptops, phones, tablets, etc.) unless the user explicitly requests them. You can also use this tool to generate assets for use in an application or website.

Its field descriptions call `Prompt` the text prompt or edit instructions, require an
`ImageName` in lowercase with underscores and at most three words, and allow absolute
artifact/filesystem paths in `ImagePaths` with at most three images. `AspectRatio` repeats
the same seven values and default. The wrapper uses an invocation-specific underscore name:
H1 proves the CLI replaces hyphens with underscores in the saved filename. This also keeps
brain rescue working when the final response omits the path.

**B3 — protobuf is not the tool interface.** A wider dump finds
`IMAGE_SIZE_FIVE_TWELVE`, **`IMAGE_SIZE_ONE_K`, `IMAGE_SIZE_TWO_K`, and
`IMAGE_SIZE_FOUR_K`** in `genai.ImageResponseFormat` and the bundled aiplatform response
protos. It also contains extra aspect enums, video response formats, mask fields and
Veo client machinery. These belong to embedded service libraries; none is a parameter
of `generateImageArgs` or a flag in `agy --help`. `GenerateImageToolConfig` exposes only
`force_disable` and `output_directory`. No callable video/audio generator implementation
was found alongside `cortex/core/tools/generate_image.go` and
`cortex/handlers/imagegen/generate_image_handler.go`.

**B4 — model identifiers.** Image-related binary strings include
`gemini-2.5-flash-image-preview`, `gemini-3-pro-image`, `gemini-3.1-flash-image`, and
`gemini-3.1-flash-image-preview`; there is also an `image_generation_model_ids` field and
“no image generation models available” diagnostic. Their presence does not establish
which model a particular subscription will receive. H1 supplies the manifest baseline.
The `--model gemini-3.6-flash-low` argument selects the orchestration/chat model; the
wrapper never reports that as the image model.

**H1 — historical successful image run (read-only inspection).** On 2026-08-21,
`~/.gemini/antigravity-cli/conversations/0683acd9-1b31-4bae-9613-e7ec63574ff0.db`,
`steps.idx=3`, recorded `generate_image` with `Prompt`, `ImageName`, `AspectRatio`, and
framework tool metadata. The response reported a saved `.jpg` under that conversation's
brain directory, MIME `image/jpeg`, and image model `gemini-3.1-flash-image`.
Its `.system_generated/logs/transcript{,_full}.jsonl` repeats the saved-path response but
omits the image model. The matching artifact still exists.

The default `~/.gemini/antigravity-cli/docs` directory was absent during inspection.
Default/profile `log/*.log` searches yielded no matching image-generation entries; the
conversation DB and brain transcripts provided the historical request and response.
The supplied scratch `imgtools/agy/strings-image.txt` and `strings-resume.txt` were checked
alongside a fresh full binary dump.

**B5 — stream and file harvesting.** `--print` normally returns only text; the wrapper
requests `--output-format stream-json`. The stream has `init`, `step_update`, and `result`
events. A completed tool step carries `.step_update.tool_name`,
`.step_update.tool_info.parameters`, `.step_update.tool_info.output`, and possibly
`.step_update.tool_info.error`. The image output's saved-path sentence is confirmed by H1
and the binary format string `Generated image is saved at %s.`. No dedicated image-path
field is documented in the CLI stream. The wrapper reads that sentence before falling
back to `.result.response` and then recent files matching this invocation's ImageName.

It never guesses the session from the newest DB in a shared profile. A missing event id
is `session=none`. For model provenance, an optional Python 3 read opens only that session's
SQLite DB in read-only mode and finds a tool payload whose generated-media URI matches
the returned file. In H1 the nested protobuf path is `140/2/6/2/104`, where
`CortexStep.generate_image` is field 104, model name is field 5, and generated media is
field 6 with URI field 5. Missing/unreadable/changed provenance yields
`model=unknown model_caps=unknown`; a different observed image model yields `stale`.
The CLI version check uses the same `AGY_BIN` override/default as `geminib`.

## Resume example

From the repository, with ImageMagick, jq, sips, agy and an authenticated `geminib` profile
available, save the first invocation's result in an existing output directory:

```bash
cd /Volumes/Work/Projects/llm-legs
mkdir -p /tmp/gemini-image-example
bin/gemini-image --route cli --dest /tmp/gemini-image-example/first.png \
  --prompt 'A blue ceramic bird on a wooden table' > /tmp/gemini-image-example/first.result
image_account=$(sed -n 's/^account=//p' /tmp/gemini-image-example/first.result)
image_session=$(sed -n 's/^session=//p' /tmp/gemini-image-example/first.result)
if [ -n "$image_session" ] && [ "$image_session" != none ]; then
  bin/gemini-image --dest /tmp/gemini-image-example/edited.png \
    --account "$image_account" --resume "$image_session" --prompt 'Now make it bluer'
fi
```

The second call needs no `--route`: a `--resume` continues on the route that made the session. No `--ref` is
needed on it either: the instruction asks the agent to reuse the last
generated image from its conversation. Context reuse is native conversation functionality;
image continuity still depends on the agent following that instruction. An explicit ref
on a resumed call takes precedence. The script requires the original account and an
existing conversation DB there. `main` uses the original HOME; named accounts use
`$GEMINIB_PROFILES_DIR/<account>`, normally `~/.gemini-profiles/<account>`.

Success prints `dest`, `size`, `format`, `account`, `session`, `model=... model_caps=...`,
`caps=...` and, last, `edit_depth=<n> root=<path>` (see [Local composite and edit
lineage](#local-composite-and-edit-lineage)), right after the `composite=` (and `rendered=`) lines of
an edit. `QUOTA`, vendor exhaustion, or selector exit 3
produces `GEMINI_USAGE_LIMIT`, exit 3, and no success footer. Since agy 1.2.10 a turn that
ends on a model error after `generate_image` saved its file exits 3 (`AGY_ERROR` on stderr); the
saved image is still delivered with the success footer, plus a stderr note naming the exit, so a
paid generation is never repeated. Without a saved file any other nonzero exit is
`generation failed`, exit 1. A limit is read from stderr, the log and the stream's error fields,
never from stream events, which echo the prompt.

## Local composite and edit lineage

Every vendor's edit repaints the whole picture: over three chained edits the face loses detail and
the skin drifts warm, even where nothing was asked to change (measured 2026-10-02). So every edit of
an existing image is composited by default, on every image wrapper and route (`gemini-image` Flow and
agy, `codex-image` CLI and web, `grok-image`): `share/image_composite.py` pastes only the changed part
of the delivered image back onto the input it was edited from, so everything else stays
pixel-identical. One decision serves them all (`image_leg_composite_plan` and
`image_leg_composite_take` in [`share/image-leg.sh`](../../share/image-leg.sh), guarded by
`tests/test_image_composite.sh`):

- An edit has exactly one input — the single `--ref`, else on `--resume` the last image this machine
  delivered in that session — and an output of the input's aspect (±1%). Anything else prints
  `composite=skipped reason=new-generation|several-inputs|input-unknown|aspect-changed` (a re-aspect or
  outpaint is `aspect-changed`) and delivers the model's image.
- `--no-composite` opts out; `--transparent` and `--remove-bg` never composite (they repaint the whole
  background); neither prints a composite line. `--composite[=auto|x,y,w,h]` forces it (the first of
  several `--ref`s) and picks the mask; it is refused before spending (exit 2) without an input image,
  with `--transparent`/`--remove-bg` or with `--no-composite`. `codex-image --region`/`--point` feed the
  mask unless `--composite` names one.

- `auto` masks the difference map: the median Lab tint the model adds everywhere is subtracted,
  the threshold adapts above the image-wide median, specks without a strong core are dropped, holes
  closed, the mask dilated and feathered; the patch is colour-matched to the input along the mask
  border. `x,y,w,h` (fractions, the shape of `codex-image --region`) pastes that rectangle.
- Lines, right before `edit_depth=`: `composite=<auto|region|points> changed=<percent of pixels taken
  from the edited image>` and `rendered=<dest stem>.rendered.<ext>`, the model's own image kept beside
  the dest. An edit that is global (more than 60% of the picture changed) prints
  `composite=refused reason=global changed=<percent> kind=<mask>`, one with no local change
  `reason=no-local-change`; both deliver the model's image and keep no `rendered=` file. A failing
  composite prints `composite=failed` and keeps the model's image, with a stderr note. Each Flow
  `--count` take is composited, its lines after its `variant=` line.

Every edited image gets a lineage `edit.json` in the work store ([image-vendors](../image-vendors.md), never
beside the image):
`{"root": <path>, "depth": <n>, "edits": [{"prompt", "region", "points", "route", "vendor", "account", "composite"}]}`,
`composite` = `{kind: auto|region|points|refused|skipped|failed, changed, reason}`.
The first input (the `--ref`s, the resumed conversation's last image) that has a sidecar is the
parent: same root, depth + 1, its edits plus this one. An input without one is a root at depth 0,
and a plain generation is its own root. The resume lookup lives next to the image-leg log
(`<dirname of IMAGE_LEG_LOG>/sessions/<vendor>/<session>`). A composited chain keeps the untouched
parts pixel-identical, so small edits keep chaining on the last result. Only after a refused (global)
composite or with `--no-composite` — an `edits[].composite.kind` of `refused` or `skipped` — does the
drift rule hold: from depth 2 on, go back to `root` and apply every `edits[].prompt` in one edit
instead of a third chained one. The engine is [`share/image_composite.py`](../../share/image_composite.py)
behind `image_leg_composite_take` and `image_leg_lineage` in [`share/image-leg.sh`](../../share/image-leg.sh),
shared by every image wrapper.

## Re-verification and live-call status

On `caps=stale` or `model_caps=stale`, inspect `agy --help`, `agy --version`, the vendor
headless/tool documentation, and a fresh `strings -n 8` dump. Search for
`generateImageArgs`, `ImagePaths`, `AspectRatio`, `jsonschema`, `GenerateImageToolConfig`,
`IMAGE_SIZE_`, image model identifiers, and image/video/audio tool implementation paths.
Read only image-related records from the selected profile's logs, conversation DB, and
brain transcripts; do not dump authentication files or unrelated conversation content.
Update the manifest evidence and verification date, then run:

```bash
cd /Volumes/Work/Projects/llm-legs
bash tests/run-all -j 2 test_gemini_image.sh test_consistency.sh
```

The test runner discovers `test_*.sh`, so this suite needs no runner registration. Tests
use a temporary HOME, profile store, fake geminib/agy/worker-pick, and generated SQLite
fixtures; no test opens a real account store.

**Live status (2026-09-11, agy 1.2.1).** The night's verification used zero real generations:
`worker-pick --account gemini` answered `switched off for workers`, which the `image` role now
bypasses. The day's live calls, all on `com` first try: a 768x768 reference with `--aspect 16:9`
and an extend-the-scene prompt came back `1376x768` (outpainting works, no crop applied);
`--resume <conversation> ` with no `--ref` repainted the sun in the SAME conversation id, but with
the manifest default `AspectRatio: 1:1` still sent the result came back `1024x1024` — so a resumed
turn now sends no AspectRatio unless `--aspect` is given. `image-fanout --accounts all` then
generated on all eight pool accounts (`1264x848` for `--aspect 3:2`, refs truncated 4→3): no
account is structurally unable to generate images today. Every call reported
`caps=stale cli=1.2.1 verified=1.2.0` — the version check works; the manifest is re-verified
against 1.2.1 below.

## Images on Google Flow (the default route)

`gemini-image` (`--route flow`, the default since 2026-10-03) draws with Nano Banana in Google Flow
(flow.google.com), driven like a person in the hidden Chrome of `gemini-web`: the same profiles, account lock,
walls (`~/.gemini-web/walls.json`), least-recently-started rotation (`generation_started_at`) and job ledger as
the video route. `--route cli` is the agy path above. A `--resume` continues on the route that made the session:
the session record (`sessions/gemini/<id>` beside the image-leg log: dest, then route), else an agy conversation
of that id on `--account` (cli), else the default; a `--route` that contradicts the record exits 2. Flow and agy ids are both UUIDs, so the id's shape decides nothing.
Without `--route`, a route-level Flow failure — exit 4 (sign-in), 5 (every account busy past `--lock-wait <s>`,
which is forwarded to the engine), 3 (walled) or exit 1 with `"sent": false` — reruns the same request once on
`--route cli` (`fallback_from=flow fallback_reason=…`, the asked `--aspect` unmapped), but only when agy can
express it: no `--count` >1, `--model`, `--upscale` or Image Editor tool, at most 3 refs, an aspect of agy's
seven; a refusal, anything sent, an explicit `--route` and `--resume` never fall back. Exit 5 without a fallback
prints `ACCOUNT_BUSY account=<name>`. `--edit <image>` is the first `--ref` (ingredient) or the Image Editor input
and the composite base; rules and the run log: [image-vendors.md](../image-vendors.md#routes-fallback-and-the-run-log). Engine: [`share/flow_image.py`](../../share/flow_image.py); wrapper half:
[`share/flow-image.sh`](../../share/flow-image.sh); contract: `flow_image` in
[gemini.json](../../share/image-caps/gemini.json).

```bash
bin/gemini-image --dest /abs/out.png --prompt '...' [--model pro|nb2|lite] [--count 1-4] \
  [--aspect W:H] [--ref /abs/img.png]... [--upscale 2k] [--transparent] [--composite[=auto|x,y,w,h] | --no-composite] [--account <p>]
bin/gemini-image --dest /abs/edit.png --prompt 'make it red' --resume <session> --account <p>
```

| Capability | Result (live 2026-10-02) |
| --- | --- |
| Models | `pro` = Nano Banana Pro (wire `GEM_PIX_2`), `nb2` = Nano Banana 2.1 (`BELUGA`), `lite` = Nano Banana 2 Lite (`HARBOR_SEAL`); `model=` reads the wire key from the page's own generation request |
| Price | 0 credits on every model and count (the composer quote is checked before the send; a non-zero quote stops the run, nothing spent) |
| Aspects | 16:9, 4:3, 1:1, 3:4, 9:16; any other W:H goes as the nearest of them, named on the `aspect=` line (`aspect=3:4 achieved=… fit=… asked=2:3`); a value that is not W:H exits 2 |
| Count | x1-x4 per send; take N lands as `<dest-stem>-N.<ext>` with a `variant=` line |
| References | up to 10 ingredients on all three models (an 11th chip greys out); exit 2 above |
| Delivery | 1K = the reply's signed image URL, byte-identical to Download > 1K Original size (1024x1024 at 1:1, 1376x768 at 16:9, 1200x896 at 4:3); `--upscale 2k` = the editor's Download > 2K Upscaled (1792x2400 at 3:4); 4K Upscaled needs a higher plan |
| Resume | `--resume <session> --account <p>`: the image's editor (`/project/<p>/edit/<id>`, "What do you want to change?") takes the new prompt; aspect and model only, no count or refs; never stamps the rotation |
| Transparency | Flow delivers no alpha: `--transparent` (PNG destination) asks for a flat #00FF00 background and keys it locally with the CLI route's [chroma key](../../share/image-chroma.sh), every take included |
| Failed card | Flow's own "Failed — Sorry, this image failed to generate. You have not been charged" card is read from the page; the engine presses its Retry once (a `retried` ledger row) and a second failure exits 1 at once with `flow_generation_failed (not charged)`; with `--count` >1 the takes that came back are delivered and a `failed=<n>` line counts the rest. Video reads the same card without a Retry (the card names no clip, and a retried clip's id is unverified): n fresh cards are the n clips still rendering once the rest are done, each a `refused=<media> flow_generation_failed (not charged)` line, all of them exit 1 with that reason (a failed clip sat out the 900 s `--timeout` before, 2026-10-05) |
| Timing | render 6-21 s after the send; 18-62 s end to end (the 2K download adds ~40 s) |

The new images are read from the page's own `ogiZ0b` reply (media id, workflow id, signed URL, `[W,H]`); the
engine issues no request of its own. A fresh image's editor opens black with Download disabled until Flow
settles it, so the engine reloads it until the prompt box shows. The project composer stays in Image mode after
a run; the video engine's settings pick Video first (a dry run on the same account read `Video · 720p · 8s`).
Exit codes: 2 usage, 3 walled/flagged (the account gets a wall, the next one runs; a pinned `--account` is
walled too, and a pinned account already walled is refused unsent with the wall's end), 4 signed out,
5 account busy (its lock was not taken within `--lock-wait SECONDS`, default 900; rotation try-locks the
candidates in order, with all busy takes whichever frees first, and moves past 3, 4 and 5; after a timed-out
wait every candidate is refused at once), 1 other. A `PUBLIC_ERROR_*` refusal after the send is 1 unless the code
is quota-shaped (`QUOTA`, `LIMIT`, `EXHAUSTED`; none seen live by 2026-10-04), which is 3. With
`--count` >1 a take still missing at the deadline does not fail the run: the finished takes are saved and
`failed` counts the rest, exit 0. The JSON result carries `job` (`IMAGE_JOB_ID`), `phases` (`lock`, `browser`,
`page`, `sent`, `media`, `saved`, seconds since engine start), `lock_wait_s` and on failure `sent`; ledger rows
carry the same, plus a `teardown` row with the browser's `close_s`.
Guard: `tests/test_flow_image.sh`.

Why Flow is the default (chain test, 2026-10-03, measured and checked by eye): over three chained small edits
of one portrait, Flow (Nano Banana Pro) kept the face sharp (Laplacian sharpness +4…+7% vs the CLI's −8…−12%),
drifted less (face diff from the pre-edit image 4.8–7.6 vs 12–13) and recoloured nothing it was not asked to
(the CLI dyed the eyebrows orange on a hair-colour edit).

### Image Editor tools on Flow

Flow's "Image Editor" Tool (Tools > Templates; a React applet in a sandboxed `*.usercontent.goog` frame on the
flow-sdk) runs on an account's own copy in My Tools. Opening the template saves a remix, so the engine opens
only My Tools: an account without a copy exits 4 and gets `image_editor: false` in its meta, and the first
success sets it to `true`. Without `--account` the run picks among accounts marked `true` (today: `com`). The
input is the image this machine holds (`--ref`, or `--resume` of a session it delivered, on any account), so no
`--account` is needed. These flags pick the tool; each one exits 2 on `--route cli`:

```bash
bin/gemini-image --dest /abs/out.png --ref /abs/in.jpg --region x,y,w,h --prompt 'a gold pendant' [--model pro|nb2]
bin/gemini-image --dest /abs/out.png --ref /abs/in.jpg --point 'x,y=copper red hair'... [--model pro|nb2]
bin/gemini-image --dest /abs/out.png --ref /abs/in.jpg --aspect 16:9|4:3|1:1|3:4|9:16 [--model pro|nb2]   # no --prompt
bin/gemini-image --dest /abs/cut.png --ref /abs/in.jpg --remove-bg [--bg-model modnet]
```

| Tool | What the applet does, and what we drive (live 2026-10-03, account `com`) |
| --- | --- |
| Inpaint | brush strokes on the layer (44 px brush; `--region` is a serpentine fill, `--point` two rings round each point). The textbox "What should appear in the painted area?" takes the prompt (several `--point` texts are joined with `; `). The applet sends the canvas plus the mask (strokes on black) as refs with `Use mask to inpaint: <prompt>` to Nano Banana, and the whole image comes back re-rendered (1024x1024 at 1:1). The local composite then keeps every pixel outside the mask (`composite=region\|points`) |
| Outpaint | the canvas is set to the asked aspect around the image at its own size, and the applet sends the canvas on black plus an uncovered-area mask. The 1K result is 1376x768 (16:9) or 768x1376 (9:16). It triggers only without `--prompt`; with a prompt the same flags stay a ref-guided generation. 3:2 is refused: the applet's 3:2 preset renders at 4:3. Nothing is composited (the canvas changed) |
| Cutout | on-device transformers.js in the frame, 0 credits, no Nano Banana. Input capped at 768 px. The engine reads the layer's PNG data URL, because Save to gallery flattens it onto black. The wrapper lays that matte over the full-size input (opaque pixels are the input's own) and exits 1 without real alpha |
| Refine | `Refine this image: <p>` with no mask: the same as a prompt edit (`--resume`/`--ref` + `--prompt`), so not wired |
| Crop | local geometry; out of scope |
| Mask Magic (separate Tool) | SAM click segmentation (`Xenova/slimsam-77-uniform`) builds a mask for the same Nano Banana mask edit (also a "move object" mode). Nothing new on the backend, so not wired |

| Evidence | Result |
| --- | --- |
| Price | 0 credits for every tool: the balance read 819 before every one of 21 runs |
| Models | `pro` (GEM_PIX_2) and `nb2` (NARWHAL) from the applet's "Image Model" picker; no Lite; render 38-46 s, 57-103 s end to end |
| Inpaint `--region` (pendant, 8% box) | pro 1/1 and nb2 1/1 ok: a clean gold crescent, every pixel outside the box plus its feather identical to the input after the composite (0 differing) |
| Inpaint `--point` (hair colour) | pro 1/1 ok: only the hair recoloured (diff mask = hair; face, background and pendant unchanged). nb2 1/2: once it pasted hair-texture discs over the forehead and eyes. The painted mask sat exactly on the points (screenshot check), so the error is the model's. Use pro |
| Outpaint 16:9 | pro 2/2, nb2 1/1 plus an engine-level run ok: a plausible wider room, no seams |
| Outpaint 9:16 | nb2 1/1 filled, with visible seams at the original's top and bottom edges. pro 1/3: twice it left the added top/bottom black (whole or in part). The wrapper now exits 1 on that ("left the bottom band unfilled"): the outer 16 px of an added side ≥90% black |
| Cutout `modnet` | 8/8 runs, byte-identical across runs; ~25 s. Poor on both test images: on the portrait it ate half the hair and kept background fragments; on a flat teapot scene it melted the object. `image-cutout` was clean on both, so prefer it for people and objects alike |
| Cutout `ben2` | Flow's BEN2 fails for anyone in this Chrome. With WebGPU (the default) onnxruntime-web reports `Invalid ShaderModule "LayerNorm"`; the wasm path asks for a `model_quantized.onnx` that BEN2-ONNX does not publish. Refused with exit 2 (`bg_models_broken` in the caps) |
| Layout flake | the frame sometimes keeps the window's old size (a squashed canvas); every drag missed once. The engine now checks the frame width and reopens once |

## Video on Google Flow

`bin/gemini-video` → `bin/gemini-web` (`share/gemini_web.py`, Playwright 1.61 via `uv run --script`)
drives flow.google.com in a hidden copy of Google Chrome (`~/.gemini-web/Gemini Web Automation.app`,
`LSBackgroundOnly`, rebuilt when Chrome's version changes), one profile per geminib account name under
`~/.gemini-web/profiles/`. macOS never hides an `LSBackgroundOnly` app (System Events reads `visible` false
while its window is on screen), and Playwright opens the window at the screen's top left whatever
`--window-position` says, so `park_window` moves every page's window off screen over CDP
(`Browser.setWindowBounds`; Chrome keeps a 40 px strip on screen, the window shows for ~0.2 s before it
moves), and `reset_exit_type` marks the profile's last exit clean so no "Restore pages?" bubble opens beside
it. The earlier System Events re-hide every 0.2 s never hid anything: whole runs sat in plain sight at the
screen's top left (measured 2026-10-03 from the window server's on-screen list), and each watcher cost
System Events about a quarter of a core. Every
toast a page showed (`[role=alert]`, `[role=status]`, snackbars) is kept in its sessionStorage and written
at the run's end as one `event: toasts` row (`account`, `route`, `texts`) in `jobs.jsonl`, the record of a
message that came and went during a run that still succeeded. It uses Flow's manual composer (the Agent toggle off): the settings popover
picks Video, the model family, Frames or Ingredients, aspect, resolution, duration and x1; frames go into
the Start/End slots, refs and an `--edit` video into the ingredient picker, each uploaded under a unique
name. Before sending, the popover's own "Generating will use N credits" quote and chip must match the
manifest, so a misread setup spends nothing. Watermark: none on PRO.

| Fact (2026-10-01, build `boq_labs-ai-sandbox-frontend_20260929.10_p0`, PRO) | Evidence |
| --- | --- |
| Credits: 1000 a month per PRO account; Veo 3.1 Lite/Fast/Quality 8 s 720p = 10/20/100; Omni 1.1 Flash 4/6/8/10 s = 7/10/12/15 at 720p, 4/5/6/7 at 360p; x2–x4 linear; aspect and frames cost nothing extra | popover quotes for every model; real runs matched their quotes |
| Veo: 8 s 720p only, up to 3 image refs, no video ref; Omni: 360p/720p, 4–10 s, 4 image refs seen (true maximum unknown) plus 1 video | settings popover; ingredient warnings |
| `--edit`: Omni reworks an uploaded video (any source; uploads over 30 s must be trimmed), the clip keeps the source length; 720p edit of an 8 s upload = 20 credits (Flow help says 40; the charge was 20) | real edit run, 1030 → 1010 |
| `--resolution 1080p`: renders 720p, then the clip editor's "Download media → 1080p Upscaled" gives 1920x1080 at no charge (4K is disabled on PRO) | real runs, credits unchanged |
| `--extend`: the source clip's editor → "Add clip" → "Extend (Veo 3.1 - Lite)" → prompt → send; 10 credits, a 7 s 720p clip holding only the continuation, which starts where the source ends (SSIM 0.91 and 0.92 against the source's last frame). Veo clips only: on Omni the item is disabled ("Only Veo-generated videos can be extended"); an extension opens as an empty editor (no Add clip, Download disabled), so it can be neither extended again nor downloaded upscaled. Extend mode shows no quote, so the charge is checked afterwards from the reply's credits. The source is looked up in `~/.gemini-web/jobs.jsonl` (account, project, scene, model, bytes); an older row without a scene opens the editor from the clip's tile in the project grid, as `fetch` does | two real runs (the first 990 → 980) |
| `--count 2-4`: the x2–x4 setting; the reply names every take, saved as the dest, `<stem>-2.mp4`, …; Omni 360p 4 s x2 = 8 | real run on egbogd |
| `--edit` + `--ref`: puts the ingredient into the uploaded video (a stopwatch onto a water clip's sand), same 20 credits as a plain edit | real run on jihangarangan |
| Output: 1280x720 (640x360 at 360p) h264 with AAC | ffprobe of every run |
| Generation rpcs, one per mode: `YhhmEf` text, `nprQif` frames, `MZZa6b` ingredients, `jIps6` edit, `fZytfe` extend; the reply names the new clips, their scenes and the credits left | page traffic |
| Wire keys: `veo_3_1_t2v_fast`, `veo_3_1_i2v_s_fast`, `abra_t2v_4s_360p`, `abra_i2v_4s`, `omni_flash_i2v_4s_first_last_360p`, `abra_r2v_4s_360p`, `abra_edit`, `veo_3_1_extension_lite` (its media record names `models/veo-3.1-lite-generate-002`) | reply and `jwpduf` media records |
| Send → saved clip ≈ 25–65 s; a whole run ≈ 35–90 s (uploads and the 1080p download add most of it) | `seconds=` footer |

The page's traffic is read passively, never replayed: the generation reply names the clip, batchexecute
`jwpduf` carries media status and remaining credits, `as29s` the signed `flow-content.google` URL. Calling
the generation RPCs from outside the page fails Google's reCAPTCHA check (`PUBLIC_ERROR_UNUSUAL_ACTIVITY`),
which is why the route clicks the UI.

`gemini-web fetch <account> <media_id> --dest <abs .mp4> [--resolution 1080p]` issues no request of its own
either: it opens the clip's project from the ledger's `project` (none there = exit 1), finds the clip's tile in
the grid, clicks it into the editor and saves the editor's Download media → "720p Original size" ("1080p
Upscaled" with `--resolution 1080p`), then writes the `saved` row with the scene from the editor URL. A video
tile carries no media id, only a thumbnail, so the tile is the one showing the thumbnail token that the page's
own project listing (`Zzl0ze`, read passively) gives that media id; the grid is virtualized and scrolled until
the tile renders. The original-size file is byte-identical to the signed URL's (2026-10-03, a 4 s Omni clip,
2276674 bytes both ways). An extension has no tile in the grid (2026-10-03), so it cannot be fetched later.

Operations: `geminib web <account>` once (a visible Chrome; sign in to the Google account whose geminib
profile has that name, then Cmd+Q; it refuses a name off the gemini roster and runs `gemini-web login --wait`, and
`geminib p` offers it once after a first Antigravity login on a tty, default no); it holds until that window is
quit, then runs `gemini-web status <account>` itself, which binds the email and reads credits without spending,
and prints `<account> ready` with the credits (the menu's `fv` row appears, unmeasured until a balance is
read), or the reason and exit 4; `gemini-web accounts` lists profiles, credits and walls; `gemini-web generate … --dry-run`
sets the composer up and prints Flow's quote without sending (with `--extend` it opens extend mode, which adds an empty "Untitled Scene" to the project); a clip that finished after a timeout is
recovered with `gemini-web fetch <account> <media_id> --dest <abs .mp4>`. Rotation (no `--account`) keeps to
the gemini worker pool ("In pool", read through `share/worker-pool.sh`; a pin in `worker-model` overrides it,
and a named account out of the pool exits 4), skips an account whose balance read in the last 6 h is under
the job's price, and moves past an account that needs a sign-in step (exit 4) to the next. Candidates go least recently started
first, never used first (the owner's rule, 2026-10-01): `generation_started_at` in `accounts/<name>.json` is
stamped when a new generation starts on Flow video, Flow Music or Gemini app music, never by an `--extend`, a
fetch or a `--dry-run`; an idle account still goes before one another run holds. A balance short
of one job's price is never walled, so a cheaper job still runs there. Exit 3 otherwise walls an account in
`~/.gemini-web/walls.json` (writes serialised by a lock file): 6 h when it is out of credits, 24 h when Flow flags it
(`PUBLIC_ERROR_UNUSUAL_ACTIVITY` on a whole failed envelope or on the new clip — "We noticed some unusual
activity", nothing charged), 30 days when the account was already flagged within the last 30 days (`flagged_at` in
its `accounts/<name>.json`: a daily re-probe added a strike a day). On 2026-09-30 rawilimo, abel, egbor and mish were flagged in agent and manual
mode alike, including under raw CDP input with no Runtime domain, while egbogd, com, jihangarangan and
locomthebest ran; exit 4 is a profile never signed in. A quote that differs from the manifest fails with
both numbers and spends nothing. Re-verify after a `model_caps=stale` line, a quote mismatch or a
`Flow UI drift` failure: run one clip (or `--dry-run`), read the new wire key, quote or failing step,
update `share/image-caps/gemini.json` `.video`, run `tests/test_gemini_video.sh`.

## Audio: music, sound effects, listening

Three scripts, all on Gemini subscription accounts; `bin/media-run music|sfx|listen` is their one
door, and `worker-launch-gate.sh` blocks them in any other Bash.

**Music** — `bin/gemini-music` → `share/gemini_music.py` drives gemini.google.com/app (Upload & tools → More
tools → Create music, Lyria 3.5) in the same hidden Chrome and profiles as Flow. Rotation skips accounts
with a Flow wall, a 6 h music wall (`~/.gemini-web/music-walls.json`) or out of the gemini worker pool, and
takes the one that least recently started any generation (Flow's rule and stamp). With `--count`, takes that finished before a later take failed
are kept: the rest go to the next account, and if none is left the run delivers what it has with a `short=`
footer line. Images and a video for the tool to watch are attached through Upload files; Playwright's
filechooser event answers the native chooser.

| Fact (2026-10-01) | Evidence |
| --- | --- |
| The clone launches with `--disable-blink-features=AutomationControlled`; with `navigator.webdriver` set, the music tool answers "no track" every time while the same prompt works in the owner's Chrome. Flow works with the flag | 3 runs, a no-track reply each, then tracks once the flag was set; later Flow runs |
| short ≈ 60 s, standard 2–3 min, no exact length; mp3 192 kb/s (a `.wav` dest is decoded from it), and an mp4 with cover art next to it | 3 real tracks: 58.4 s, 61 s, 60.4 s |
| `<dest>.txt` holds the tool's plan: tempo and sections with start times. Timed hit points in the prompt are followed only roughly: in one run, the times 0/7/24/37/42/53 s appeared in the plan, the RMS curve showed changes at 7, 24 and 56 s, and the break at 37 s was weak | timed-A run on com |
| `--video`: the tool watches the cut and names the track (`where_the_pendulum_rests.mp3`); the music changed near cuts (~4–6, 16, 24, 40 s) but ran 14 s past a 46 s picture | r6b run on egbogd |
| The first upload on an account opens a rights notice ("…necessary rights…"), and a send with a video opens "A reminder about creating videos…". Agree persists per account. The script clicks Agree only for accounts in `~/.gemini-web/notices.json` "agreed" (the owner's yes); any other account exits 4 and names the notice | live on com, egbogd, jihangarangan, locomthebest |
| The reply also lists the user's own uploads. The base64 `c=` token of a media URL names its store: `request_data` is an upload, while `temp_data`/`response_data` is output (`uploaded()` skips uploads). The cover mp4 can 404 for a minute after the reply, so it is retried 6× at 10 s; on a final miss, the take keeps the audio and records `video_error` | the HTTP 404 on the first video run |

Exits: 3 = Gemini says the music generations are spent (the account is walled for 6 h) or every account is walled; 4 =
signed out, no Create music tool, or a rights notice still to agree; 1 = UI drift (names the step), "no track"
(Gemini's own words), "the prompt was never sent: no chat opened", an upload that never finished or a refusal
toast. A run that saved nothing locally but shows a track in the chat can be read again from the chat; the
reply parser works on a reloaded chat's batchexecute.

Failures: every failed attempt of either engine, an account the rotation skipped included, prints one
`BROWSER_FAILURE route=<flow|gemini-app|flow-music> account= code= shot= reason=` line on stderr (`BROWSER_WARNING`
when the run still succeeded: the clone could not be hidden, the cover mp4 missed), saved in the image-leg
log; `shot=` is a screenshot in `~/.gemini-web/failures/` beside a `.txt` page dump (dialogs, toasts,
buttons, text), kept 14 days. llm-doctor turns the lines into `browser …` words in its image block.

Promos over the composer (connect YouTube, Drive and other Google apps) are closed by `close_promos`: a
declining button (No thanks, Not now, Maybe later, Dismiss, Skip, Close) or Escape, never an accepting one;
the rights notices are left to the notices.json gate. Each closed dialog is a `kind: dialog` row in
`jobs.jsonl` and a `gemini-web: closed a dialog on <account>: <text>` stderr line. The hidden Chrome
segfaults inside its own download manager while it saves Flow's 1080p upscale (14 crashes on 2026-10-01,
every one in `Download.save_as`, even across relaunches), so `save_upscaled` catches the file from the page's
download link (a `createObjectURL` and anchor-click hook) and reads it out of the page in 4 MB chunks;
Chrome's download is only the fallback, announced by a `the 1080p file went through Chrome's download`
line. A crash there still gets two relaunches, then a `gemini-web fetch … --resolution 1080p` recovery line.
gemini-sfx keeps every rejected take (no soundtrack, silent, loudness not measurable) in the failures folder.

### Flow Music route (`--route flow`)

`bin/gemini-music --route flow` → `share/flow_music.py` drives flowmusic.app's compose panel in the same
hidden Chrome, profiles and account locks. `--model lyria-3-pro` implies the route; the app route stays the
default until the reliability bench says otherwise. Use it for Lyria 3 Pro, WAV masters, stems, an exact
length, lyrics, BPM and seed. Every run compares the Lyria picker and each song menu it opens (⋯, Remix,
Download) with `.flow_music.models` / `.menus` and prints `caps=fresh` or `caps=stale what=…`.

| Fact (2026-10-01) | Evidence |
| --- | --- |
| Models: "Lyria 3.5" (labelled "Top performing, flagship model", the default) and "Lyria 3 Pro" (labelled "Legacy model") | the model menu and `/__api/models` |
| Price: 5 credits a song for either model (a 3 min and a 1 min song alike); Split stems is free | `/settings` balance before and after 2 probe songs, 4 wrapper songs and 5 splits |
| Pool: Flow Music's own credits, separate from Flow video credits: PLUS gives 10000 a month, plus a 500 bonus and 30 free daily; the balance is `music_credits` in the account meta | `/settings` Usage table, `/__api/billing/credits` |
| A song renders in about 30 s; a wrapper run takes about 75 s (WAV), stems add about 60 s | `seconds=` footers |
| Length takes m:ss from 1:00 to 3:00 and is a target, not exact: 75 s asked gave 100.7 s, 60 s gave 57–62 s | ffprobe of the takes |
| Downloads: M4A, MP3 and WAV (48 kHz s16 stereo) come from the song's ⋯ → Download menu as a blob link that the page clicks; the engine catches the link (`gw.CATCH_DOWNLOAD`) and reads the file out of the page | 3 formats on 5 songs, stems included |
| Stems: other, drums, vocals and bass, each listed in the library as "<title> - <stem>" | 5 splits |
| One Generate makes one song (`clip_id_b` was null); the page's `/__api/clips` reply and the library row identify it by the run's unique title | traffic of the probe songs |

Controls (role, name): button "Toggle compose panel"; textbox "Lyrics", switch "Toggle instrumental mode";
textbox "Sound description" (`--genre` is put in front of the prompt); switch "Toggle advanced sound mode",
then the BPM, Length and Seed inputs, which follow their labels, and button "Lyria 3.5" opens the model
menuitems; button "Expand Details section" shows the title field (the dest's name plus 4 hex digits); button
"Generate". Every control is set on each take because the panel keeps the last values. A menu item inside the
Download submenu is chosen by focus and Enter, because a pointer click there lands on `<html>`.

Flags (flow only): `--model lyria-3.5|lyria-3-pro`, `--format` (must match the dest: .mp3 .wav .m4a),
`--duration 60-180`, `--length short` (1:00), `--lyrics`, `--bpm`, `--seed`, `--stems`
(`<dest>-<stem>.<ext>` beside the track, `stem=` footer lines), `--ref-audio <≤ 40 MB audio>`, `--accounts 1-4`.
`--ref-image` and `--video` stay app-only. `--accounts N` starts N engine processes at once, one per account,
idle accounts first. It keeps every take as dest, dest-2, … (`variant= … account=`) and cancels nothing. It
exits 0 when any take saved, and a `short=` line names the accounts that failed.

Rotation: signed-in Gemini profiles in the gemini worker pool, without a Flow wall (Flow's unusual-activity flag
holds here too) or a Flow Music wall (`~/.gemini-web/flow-music-walls.json`, 6 h, set on exit 3). A balance read
in the last 6 h that is under the price of one song skips the account. The account that least recently started any
generation goes first (Flow's rule and stamp). An account Flow Music shows as signed out is marked `music_signed_in: false` and
skipped until a balance read (`uv run --script share/flow_music.py status --account <name>`) finds it signed in.
Signed in on 2026-10-01: com, egbogd, jihangarangan and locomthebest (Continue with Google → the account →
Continue → tick "See your Google One membership…" → Continue → Privacy Notice Agree; PLUS shows after a reload).
loiyehor and tronjhon were onboarded without it and signed in on 2026-10-06. Without the Google One grant an account
reads 30 credits under a "Grant access" banner; the banner's button runs the account chooser → Continue → a consent
page ("3 services") → Continue, after which the balance reads 10530. `geminib web` opens a Flow Music tab beside the
Google sign-in, and its closing `gemini-web status` exits 4 naming the missing step (signed out, the privacy notice's
Agree, or Grant access when no subscription refill is among the grants). The menubar draws the `fm` row only once
`music_signed_in` is true, walled red by either wall.

A song that finished after its run gave up is saved again without spending: `uv run --script
share/flow_music.py fetch --account <a> --title <title> --out-dir <dir> --format wav [--stems]` (the title is
in `jobs.jsonl` `kind: flow-music` rows). Message streams are never read, because a Producer stream can stay
open and block the run. Split stems is awaited as library rows.

`--ref-audio` goes through the chat (Add audio or image → Audio, then a message to Producer). The first upload
opens Flow Music's "necessary rights" notice. The engine clicks I agree only for accounts that the owner lists
under `agreed_flow_music` in `~/.gemini-web/notices.json` (his Gemini-app yes in `agreed` does not cover Flow
Music); any other account exits 4. com, egbogd, jihangarangan and locomthebest are listed (2026-10-01, renewed by
his 2026-10-06 yes to uploading own audio). Uploads are refused in this region (table below), so `--ref-audio`
fails with exit 1 before it spends.

#### Edits (`--edit … --mode …`)

A song's ⋯ → Remix submenu offers Start session, Cover, Replace, Extend, Use prompt, Variation and Trim. Cover,
Extend and Replace open one edit panel: a mode combobox, an Instruction box, Edit Lyrics, a Settings popover with
the window, Advanced (Seed), Details (the title), and Generate. `--edit <title> --account <a>` edits a library song.
`--edit <file>` whose `<file>.txt` holds `Title:` and `Account:` lines edits that Flow take on its own account; every
flow take writes both lines since 2026-10-06. Any other file is uploaded, which the region refuses. The result is
saved like a song: the dest's format, `--stems`, `--count` (not for trim), `variant=` lines and ledger rows with
`mode`. `model=flow-music-<mode>`; `<dest>.txt` keeps the source, the window and the instruction.

| Mode (2026-10-06, com, source a 62.7 s instrumental) | Fact | Evidence |
| --- | --- | --- |
| cover | 5 credits, 47 s wall. Instruction + Edit Lyrics + Strength (slider 0-1, step 0.01, 0.5 default; Home, then ArrowRight) + Seed. A 58.5 s song that keeps the given title (`audio__render_edit`, `source_clip_ids`) | live run with `--lyrics`, `--strength 0.6`, `--seed 7`; Usage −5 |
| extend | 5 credits, 49 s. Settings: "Extend from" (default the song's end, which the engine sets from the duration button) and "Extend until". Flow keeps until−from in 30-150 s by moving the start, so the engine fails with exit 2 when the label ("Extend 1:02-1:35") differs from the ask | `--to 95` gave 95.06 s; the clamp probed with 6 windows |
| replace | 5 credits, 53 s. Settings: start and end anywhere inside the song ("Replace 0:20-0:30"); the panel also has Add region, which the engine does not use | `--from 20 --to 30` gave 60.0 s |
| variation | 5 credits, 32 s. Remix → Variation generates at once (same prompt, lyrics and length, a new random seed, title "<source> (Remix)", `audio__create_song`, no audio conditioning). The engine opens Use prompt instead (the same panel, prefilled, seed Auto), sets its own title and presses Generate | a Variation click charged 5 credits at once; the wrapper run gave 66.6 s |
| trim | free, about 24 s. A Trim Song dialog (Start, End; typing the end while the start reads 0:00 pulls the start to 10 s before it, so the end goes first) saves "<source> (trim 0:40-0:55)" at once | 4 trims, balance unchanged; 15.02 s wav |
| uploads | refused: every upload read `has_vocals: true` (a sine melody, synthetic drums, and Flow's own drum and pad stems), and the site's `is_in_restricted_remix_region` turns that into the toast "Uploading tracks with vocals is not available in your region". So `--ref-audio`, `--edit <non-Flow audio>` and Upload my vocal cannot work from here. The engine's upload branch sends the mode to Producer in words and is unverified | 4 uploads on com, 1 on jihangarangan, 2026-10-06 |
| Start session, Remix a track, Upload my vocal, Make video | Producer chat starters, not edits. Make video asks for a song, subject and style images, a prompt, lyrics on/off, 9:16 or 16:9 and up to 2 min. Its intro says only "Credits are required … They can be expensive"; no price shows before the Producer's final review. Not wired | the home page and Music videos → New music video, nothing spent |

Chain vendors: make the exact-length or spoken part with ElevenLabs, then edit Flow-made songs here. Non-Flow
audio cannot enter Flow Music from this region.

**Route bench 2026-10-01** — 5 instrumental prompts × 2 runs per route, interleaved two at a time over
12:13–12:57 UTC, Lyria 3.5 on both, about 60 s songs (`--length short` on the app, `--duration 60` on flow), no
`--account`. "To saved" is the time from start to the ledger `saved` row.
App: 9/10 ok (90 %); to saved median 68 s, p90 83 s; to file median 76 s; takes 57–70 s, 1.4–1.7 MB mp3.
1 failure: "Gemini answered without running the music tool" (egbogd, after 42 s). No daily wall was hit.
Flow: 7/10 ok (70 %); to saved median 34 s, p90 38 s; to file median 63 s; takes 60–65 s, about 1.0 MB mp3;
5 credits a song. 3 failures: "no track after 600 s" (locomthebest 2, com 1). None was charged and none of
those songs reached the library, so each cost a full 600 s.
Fan-out `--accounts 3`: 2/2 runs ok, 6/6 takes on com, egbogd and locomthebest, 15 credits each.
Flow Music spent 65 credits in total.
Five runs from both routes took 140–746 s to the file although they saved at 34–75 s. The automation Chrome
woke `GoogleUpdater --wake-all`, which inherited Chrome's stdio sockets, so Playwright's context close waited
until the updater exited, about 10 minutes later. Since then `build_clone` strips GoogleUpdater.app and the
privileged helper from the clone (recipe `no-updater` in its Info.plist forces one rebuild of an older clone),
and a flow Generate that starts no song is clicked once more at 90 s and fails 90 s later instead of at 600 s.
Stripping the clone's updater did not reach the user-level one in `~/Library/Application Support/Google/
GoogleUpdater`, and two chatgpt-web runs at once both hung the same way (2026-10-02). Since then Chrome
starts through `<store>/logs/<account>-chrome.sh`, which points its stdio at `<account>-chrome.log`, so no
child Chrome spawns holds Playwright's pipes; a teardown still running after 45 s prints the Python stacks
and kills Chrome's process group and the Playwright driver, and a SIGTERM prints the stacks before dying.
A normal close is cut short too (2026-10-03): Chrome writes cookies, prefs and site storage within its
shutdown's first second, then mostly sat until its own teardown watchdog killed it ~10 s later (median close
11 s in the ledger's `teardown` rows), so `reap_after_flush` kills its process group 1 s after `Cookies` and
`Preferences` are rewritten (close ~1.3 s, cookies and a clean exit type kept in 12 of 12 probes). A killed
Chrome leaves its per-launch code-sign clone of the app under `$(getconf DARWIN_USER_TEMP_DIR)/../X/`;
a launch sweeps, in the background and at most once per 10 min machine-wide (stamp
`~/.gemini-web/.clone-sweep.stamp`), the ones older than 10 min that no running browser maps.
Default: the app route stays the default. It succeeds more often, it fails fast, and it spends no credits.
Use flow when its features are needed, or with `--accounts 2+` when the time to a take matters: one Flow
failure costs 600 s, and in this bench a fan-out never lost a take.

**Sound effects** — `bin/gemini-sfx` runs `bin/gemini-video --model omni --resolution 360p` (4/6/8/10 s =
4/5/6/7 credits) with a prompt that asks for an isolated sound on a close-up of its source. It keeps only the
soundtrack: trims silence at both ends (-50 dB), applies two-pass loudnorm to -16 LUFS / -1.5 dBTP, and
writes 48 kHz stereo pcm_s16le. A clip at -70 LUFS or quieter is refused as silent; with `--count` an
unusable take is dropped, the usable ones become the dest and its variants, and the run fails only when none is. `--for-video <≤ 10 s>` is
an Omni edit at 720p (20 credits) asking for effects synced to the picture; the wav keeps the video's
length. By ear, 1 of 3 text takes was usable (the others had a drone or hiss under the sound), so ask for
`--count 2`. In the edit, whooshes landed on the cuts, but continuous clicks ignored the hand's pauses.

**Listening** — `bin/gemini-listen` asks Gemini (agy, Pro or Flash) to watch and hear files through
`view_file`. Files over `.listen.view_max_bytes` (agy shows at most 20 MB) are sent as a proxy: video at
720p, audio as mp3. Audio otherwise goes as wav, since agy refuses flac, aac, m4a and aiff as unsupported
mime types. A reply that never opened a file is refused, and so is one whose `view_file` step returned an
error. It judges sound and sync well, but it echoes timings from the question, so measure exact times
with ffmpeg.

Sometimes Pro says `view_file` gave it a text transcript and then scores 1 (2026-10-07: 6 of 70 Pro
calls). It is the model's belief, not agy: agy's record of each run
(`brain/<session>/.system_generated/logs/transcript_full.jsonl` in the profile) showed an `audio/*`
media part in all 345 `view_file` opens checked, including the 4 failing calls. The stream-json events do
not carry that part. So every call is checked against the record: each sent file must come back with a
media part of its kind, and a missing record counts as a failure. A reply whose first or last line is
`NO_AUDIO` also fails. With Pro (`.listen.models.pro.beeps`), 2–4 test beeps go at the end of each
audio file, and the reply's first line must count them (`BEEPS 1:3`); the tool removes that line. Pro
miscounted them in 4 of 39 calls, and 2 of 36 runs exited 1. Flash miscounts them under a long question
(9 of 18), though it counts them right alone (24 of 24), so Flash gets no beeps. Any of these failures asks once more, then
exits 1. The footer shows `audio=heard` (beeps counted) or `audio=delivered` (record only) per audio
file, and `calls=`. Refusals of the form "answered without opening" came from macOS's `TMPDIR`, which
ends in `/`: the model opened the path without the `//`.

To pick between two takes, use `--compare <A> <B> -o <.md>`, never one call with both. One Pro verdict
is noise, several takes in one call get mixed up, and the file shown first tends to win. So it makes two
independent calls, A,B then B,A, each with the checks above. Each reply must end with the line
`WINNER: first|second|tie`; any other last line fails that call. The .md holds both replies. The footer
gives `order1=`/`order2=` (each order's verdict, account, session, calls), `winner=A|B|tie votes=<n>/2`
(a tie unless both orders agree), then `a=` and `b=`. For a free number next to the judgement, use
`bin/audio-score <audio>... [--json]` (local, no account, not a media-run route). It gives `utmos=` 1–5
(UTMOS22 strong, tarepan/SpeechMOS v1.2.0) and `aes_pq aes_pc aes_ce aes_cu` 1–10 (Meta Audiobox
Aesthetics) per file. It runs in one uv process on the CPU: about 3 GB of RAM and 24 s for 18 files. The
first run downloads the models into `~/.cache/torch/hub` and `~/.cache/huggingface`. UTMOS is trained on
English and Japanese read speech: it underrates whispers, laughs and shouts, so read it as a cleanliness
score, not as acting quality.

## Speech on AI Studio

`bin/media-run speech --vendor gemini` → `bin/gemini-speech` → `share/aistudio_speech.py` drives Google AI Studio's
Generate speech playground (aistudio.google.com/generate-speech) in the same hidden Chrome, profiles and account
locks as Flow. It is free on the signed-in accounts: no API key, and the page's "Link a paid API key" is never
touched. Plain `media-run speech` runs here (`default_for` in gemini.json since 2026-10-07: a blind bench of three jobs found it level with ElevenLabs v4 on calm Russian narration and English promo and ahead on an emotional Russian story); `--vendor elevenlabs` for its designed voices, more than two speakers or `--timestamps`. Manifest:
`share/image-caps/gemini.json` `.speech` (models, voices with traits, tags, director menus, limits).

| Fact (2026-10-06) | Evidence |
| --- | --- |
| Five TTS models in the model menu's Audio filter: `gemini-3.8-flash-tts` (default), `gemini-3.8-flash-lite-tts`, `gemini-3.1-flash-tts-preview`, `gemini-2.5-pro-preview-tts`, `gemini-2.5-flash-preview-tts`; `?model=<id>` in the URL selects one | the model panel; the run settings card shows the id |
| Two composers. 3.8 models: per-block Style ("Describe the voice style" or the presets Whisper, Friendly, Narration, Promote, Podcast), `<tag>` expression tags, a "Filler words" switch with two speakers, `\|reaction\|` backchannels. Older models: Scene and Sample Context fields, and per speaker an Audio Profile plus Director's note menus (Style, Pace, Accent) — the page writes them into the prompt as `## Scene:` / `# Audio Profile` / `# Director's note` / `## Transcript:` | each family's composer and the prompt each sends |
| Voices: 70 free on the 3.8 models (40 new + the 30 older ones), the 30 older ones on the other models; the search over 2,000+ others asks for a paid key. Picking a voice in the speaker panel sets that speaker everywhere | the speaker panel walked by category with the Gender and Language filters |
| Tags: the composer's 40 `<tag>` chips are exactly the docs' list for 3.8; the older models take 23 `[tag]` words. The tag toolbar collapses on blur, so tags are typed into the text | the Expression toolbar, ai.google.dev speech-generation guide |
| At most two speakers; blocks alternate Speaker 1/2, so the CLI merges consecutive lines of one voice | "Add speech block" |
| Language: no control on the page; the model reads it from the text (130 languages on Flash, 101 on Lite) | the docs' model pages |
| Temperature 0–2, step 0.05, default 1 (Model settings) | the spinbutton's bounds |
| Output: WAV pcm_s16le 24 kHz mono. The reply streams `audio/l16` chunks; the player shows a 0.04–0.08 s WAV after the first chunk and the full one 1–2 s after the request ends. The engine waits for a 44-byte header plus every PCM byte of the reply | three takes saved early at 0.04–0.08 s; player size = 44 + Σ chunks, exact on 2 takes |
| The Download button builds its WAV in a sandboxed frame created at click time and hands it to Chrome's download manager, which crashed the hidden Chrome twice; the player's `data:audio/wav` URL is byte-identical, so the engine reads that | `cmp` of a caught Download and the player |
| The first Run after typing sometimes sends nothing; a Run with neither a `GenerateContent` nor the Stop ("Cancel generation") button in 12 s is clicked again. 2.5 Pro shows Stop well before its first reply, so Stop counts as sent | REPL probes; a 2.5 Pro take misread as a disabled Run (2026-10-07) |
| A short take renders in about 3 s (wrapper run 10–20 s); 2.5 Pro renders 327 chars of Russian in 17.8 s and 407 in 25.5 s (wrapper 34 s), far inside `timeout_s` 300 | `render_s` in the ledger, `seconds=` footers |
| First use shows a terms page or dialog (tick only "I acknowledge that I am at least 18…", never the e-mail opt-in, then Continue) or a "Welcome to AI Studio" plan dialog (Continue). The owner's yes (2026-10-06) covers both; the engine records `aistudio_terms_accepted_at` in the account meta and a `terms-accepted` ledger row. Needed on loiyehor and tronjhon; locomthebest showed the welcome dialog once | runs on all six pool accounts |

Each take, dry runs included, first compares the page with `.speech` (models in the Audio filter, the family's
tag chips, the voice panel, the older models' Director's note menus; about 3-5 s) and prints `caps=fresh` or
`caps=stale what=<part>: +added -gone`.

Live takes (2026-10-06, one short sentence each, ffprobe): single voice Kore 2.64 s; dialogue Puck/Kore 3.32 s and
Algenib (per-line style) / Achernar with filler words 4.24 s — two segments split by a 0.8–1.0 s gap, median F0
139 Hz vs 203 Hz; `--style` whisper 2.88 s; `<sighs>`/`<whispers>` tags 5.36 s; 2.5 Flash with `[whispers]`, Scene,
Audio Profile, Director Style Whisper and Accent British (RP) 2.85 s.

CLI: `--text|--text-file|--line "<voice>: <text>"` (repeat; `"<voice> (<style>): <text>"` styles one line on 3.8),
`--voice`, `--style` (3.8: each block's Style; older: each speaker's Audio Profile), `--model
flash|flash-lite|3.1-flash|2.5-pro|2.5-flash` or an id, `--temperature`, `--filler-words` (3.8, two speakers), `--scene`,
`--context`, `--delivery`, `--pace`, `--accent` (older models), `--list-voices [--model]` (from the manifest, no browser),
`--dest .wav|.mp3`, `--account`, `--lock-wait`, `--dry-run` (sets every control, sends nothing). `--language` is
refused: write the text in the language. A tag in the other family's brackets is refused; one outside the
composer's list is sent with a stderr note.

Rotation: signed-in Gemini profiles in the gemini worker pool, minus accounts resting in
`~/.gemini-web/flow-rest.json` while its `until` is ahead, minus their own walls in
`~/.gemini-web/aistudio-walls.json`, minus meta `aistudio_signed_in: false`; least recently started first. A quota
or rate-limit answer is exit 3 and walls the account until the next Pacific midnight (15 min for a per-minute one);
the free daily limit itself was not reached. Exits: 0 ok, 1 failed or UI drift, 2 usage, 3 limit or wall,
4 signed out, 5 account busy.
