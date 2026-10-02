# Gemini images through Antigravity CLI

Verified on 2026-09-30 against **agy 1.2.13** (binary schema, help and model ids; the last live
generation is the 2026-09-11 one below), launched by `geminib` with a Google
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
produces `GEMINI_USAGE_LIMIT`, exit 3, and no success footer. Since agy 1.2.10 a turn that
ends on a model error after `generate_image` saved its file exits 3 (`AGY_ERROR` on stderr); the
saved image is still delivered with the success footer, plus a stderr note naming the exit, so a
paid generation is never repeated. Without a saved file any other nonzero exit is
`generation failed`, exit 1. A limit is read from stderr, the log and the stream's error fields,
never from stream events, which echo the prompt.

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

## Video on Google Flow

`bin/gemini-video` → `bin/gemini-web` (`share/gemini_web.py`, Playwright 1.61 via `uv run --script`)
drives flow.google.com in a hidden copy of Google Chrome (`~/.gemini-web/Gemini Web Automation.app`,
`LSBackgroundOnly`, rebuilt when Chrome's version changes), one profile per geminib account name under
`~/.gemini-web/profiles/`. Chrome unhides itself on a new window, a download or a dialog, so one
`osascript` watcher (`HIDE_WATCH`) re-hides the clone every 0.2 s for the whole run and quits once no clone
runs; the earlier 3 s re-hide left a page up long enough for the owner to read a toast (2026-10-01). Every
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
| `--extend`: the source clip's editor → "Add clip" → "Extend (Veo 3.1 - Lite)" → prompt → send; 10 credits, a 7 s 720p clip holding only the continuation, which starts where the source ends (SSIM 0.91 and 0.92 against the source's last frame). Veo clips only: on Omni the item is disabled ("Only Veo-generated videos can be extended"); an extension opens as an empty editor (no Add clip, Download disabled), so it can be neither extended again nor downloaded upscaled. Extend mode shows no quote, so the charge is checked afterwards from the reply's credits. The source is looked up in `~/.gemini-web/jobs.jsonl` (account, project, scene, model, bytes), the scene of an older row through the page's `as29s` read | two real runs (the first 990 → 980) |
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

Operations: `geminib web <account>` once (a visible Chrome; sign in to the Google account whose geminib
profile has that name, then Cmd+Q; it refuses a name off the gemini roster and runs `gemini-web login`, and
`geminib p` offers it once after a first Antigravity login on a tty, default no), then `gemini-web status <account>` binds the email and reads credits
without spending; `gemini-web accounts` lists profiles, credits and walls; `gemini-web generate … --dry-run`
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
activity", nothing charged). On 2026-09-30 rawilimo, abel, egbor and mish were flagged in agent and manual
mode alike, including under raw CDP input with no Runtime domain, while egbogd, com, jihangarangan and
locomthebest ran; exit 4 is a profile never signed in. A quote that differs from the manifest fails with
both numbers and spends nothing. Re-verify after a `model_caps=stale` line, a quote mismatch or a
`Flow UI drift` failure: run one clip (or `--dry-run`), read the new wire key, quote or failing step,
update `share/image-caps/gemini.json` `.video`, run `tests/test_gemini_video.sh`.

## Audio: music, sound effects, listening

Three scripts, all on Gemini subscription accounts; the agent `image-gen` owns them (`AUDIO: music|sfx|listen`
briefs), and `worker-launch-gate.sh` blocks them in any other Bash.

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
length, lyrics, BPM and seed.

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

A song that finished after its run gave up is saved again without spending: `uv run --script
share/flow_music.py fetch --account <a> --title <title> --out-dir <dir> --format wav [--stems]` (the title is
in `jobs.jsonl` `kind: flow-music` rows). Message streams are never read, because a Producer stream can stay
open and block the run. Split stems is awaited as library rows.

`--ref-audio` goes through the chat (Add audio or image → Audio, then a message to Producer). The first upload
opens Flow Music's "necessary rights" notice. The engine clicks I agree only for accounts that the owner lists
under `agreed_flow_music` in `~/.gemini-web/notices.json` (his Gemini-app yes in `agreed` does not cover Flow
Music); any other account exits 4. No account is listed yet, so the reference-track path is unverified live.

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
720p, audio as mp3. A reply that never opened a file is refused, and so is one whose `view_file` step returned an error. It judges sound and sync well, but
it echoes timings from the question, so measure exact times with ffmpeg.
