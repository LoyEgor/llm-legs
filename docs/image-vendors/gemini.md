# Gemini images through Antigravity CLI

Verified on 2026-09-11 against **agy 1.2.1**, launched by `geminib` with a Google
subscription. The runtime contract is [gemini.json](../../share/image-caps/gemini.json);
its `field_sources` maps each capability to evidence. This page concerns the subscription
CLI, not the Gemini Developer API, Vertex API, or the Python SDK's configurable models.

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
| Video / audio generation | No exposed generation tool found; video is unsupported | Binary tools implementation inventory; Google tool inventory |

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
bin/gemini-image --dest /tmp/gemini-image-example/first.png \
  --prompt 'A blue ceramic bird on a wooden table' > /tmp/gemini-image-example/first.result
image_account=$(sed -n 's/^account=//p' /tmp/gemini-image-example/first.result)
image_session=$(sed -n 's/^session=//p' /tmp/gemini-image-example/first.result)
if [ -n "$image_session" ] && [ "$image_session" != none ]; then
  bin/gemini-image --dest /tmp/gemini-image-example/edited.png \
    --account "$image_account" --resume "$image_session" --prompt 'Now make it bluer'
fi
```

No `--ref` is needed on the second call: the instruction asks the agent to reuse the last
generated image from its conversation. Context reuse is native conversation functionality;
image continuity still depends on the agent following that instruction. An explicit ref
on a resumed call takes precedence. The script requires the original account and an
existing conversation DB there. `main` uses the original HOME; named accounts use
`$GEMINIB_PROFILES_DIR/<account>`, normally `~/.gemini-profiles/<account>`.

Success prints exactly seven lines: `dest`, `size`, `format`, `account`, `session`,
`model=... model_caps=...`, `caps=...`. `QUOTA`, vendor exhaustion, or selector exit 3
produces `GEMINI_USAGE_LIMIT`, exit 3, and no success footer.

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
