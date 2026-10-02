# Codex image leg

`bin/codex-image` drives the Codex CLI's **built-in** `image_gen.imagegen` tool on a ChatGPT
subscription — never the API-key fallback (`~/.codex/skills/.system/imagegen/scripts/image_gen.py`,
which needs `OPENAI_API_KEY` and is a different model surface with different knobs). The limits the
script enforces come from `share/image-caps/codex.json` at runtime; this file says where every value
in that manifest came from and how to check it again.

Verified against `codex-cli 0.160.0` on 2026-10-02, unchanged from 0.159.3 (first pass: 0.156.1, 2026-09-23).

## Capabilities

| Capability | Value | Source |
| --- | --- | --- |
| Tool | `image_gen.imagegen` (built-in, no API key) | binary tool description, `ext/image-generation/src/tool.rs`; skill `SKILL.md` "Default built-in tool mode (preferred)" |
| Arguments | `prompt`, `transparent_background` (bool, since 0.157–0.159), `referenced_image_paths`, `num_last_images_to_include` — and nothing else | binary 0.159.0: `struct ImagegenArgs with 4 elements` over `prompttransparent_backgroundreferenced_image_pathsnum_last_images_to_include` (0.156.1: 3 elements, no `transparent_background`), `properties`/`additionalProperties` schema strings |
| Image model | `gpt-image-2` | binary: the literal sits inside `ext/image-generation/src/tool.rs`, beside the ImagegenArgs errors |
| Reference images | local paths, at most 5 | binary: `` `referenced_image_paths` must contain at most `` (the number is formatted at runtime, so the 5 is the tool description's own "up to 5" for the sibling argument — hence `refs.verified_max: false`) |
| Conversation images | `num_last_images_to_include` 1–5, never together with `referenced_image_paths` | binary: `` `num_last_images_to_include` must be between 1 and ``; "Never provide both" |
| Local-file edits | `view_image` the file first, then pass it in `referenced_image_paths` | binary tool description: "If you have not seen a local image yet, use `view_image` to inspect it before editing"; `SKILL.md` "Built-in edit semantics" |
| Transparency | native alpha through the tool's `transparent_background` argument, which the instruction names (the model fills tool arguments, so a sentence is the only way to set it); keyed as a fallback | binary 0.159.0 `ImagegenArgs` above and `ImageGenerationItem.transparentBackground`; `SKILL.md` "For transparent images, ask built-in `image_gen` for a transparent background and preserve the generated alpha" |
| Failure | `ImageGenerationFailure` is `usageLimitExceeded` (`limitId`, `resetsAt`) or other; a failed item may end a turn with exit 0, so a missing image with that tag in the JSONL is `CODEX_USAGE_LIMIT` (exit 3) | binary 0.159.0: `internally tagged enum ImageGenerationFailure`, `usageLimitExceeded limitId resetsAt`; whether `codex exec` JSONL carries the item is unproven (`docs/vendor-release-open.md`) |
| Output location | `$CODEX_HOME/generated_images/<thread_id>/<name>.png` | `SKILL.md` save-path policy; live store: `~/.codex/generated_images/019f3d39-…/exec-<uuid>.png` |
| Session id | `thread.started` → `thread_id`, on `codex exec --experimental-json` | binary: the exec event enum `thread.started turn.started turn.completed turn.failed item.*`; [vendor docs](https://developers.openai.com/codex/noninteractive) |
| Resume | `codex exec [OPTIONS] resume <SESSION_ID> [PROMPT]`, `--last` for the newest | binary `ResumeArgs`: "Conversation/session id (UUID) or thread name … If omitted, use `--last`"; vendor docs |
| Exact size | no — prose only | `SKILL.md`: "Do not treat `Quality:`, size … as built-in `image_gen` tool arguments"; size/quality exist on the API fallback (`gpt-image-2`: edges multiple of 16, max edge 3840) and nowhere on the built-in tool |

## Not supported

- **Aspect ratio** — no argument at all; the manifest's `aspects` is `null`. `--aspect W:H` is worded by
  the script's one sentence builder (see "Aspect, size, transparency, region: one sentence builder").
- **Exact size, quality, `n`, masks, `input_fidelity`, `background=transparent`** — every one of them is
  a fallback-CLI/API parameter. `--size` is passed to the model as a sentence and is a request, not a
  guarantee; with no `--size` the prompt asks for low quality, which is likewise only prose.
- **Video** — no video tool in this CLI; the manifest's `video` is `null`, which is the fan-out's hard
  skip signal for this vendor.
- **Naming the image model per run** — `codex exec` output never names the image model (no image item
  in the exec JSONL). The only witness is the PNG's C2PA `softwareAgent`, which `c2pa_model` reads. Live
  on cli 0.156.1 (2026-09-23) it is `{name: ChatGPT, version: gpt-image}` — the family without its
  version — so a run prints `model=gpt-image model_caps=unknown verified=gpt-image-2`; a versioned
  name that differs from the manifest prints `stale`. The source sends `IMAGE_MODEL = "gpt-image-2"`
  (`codex-rs/ext/image-generation/src/tool.rs`), which is what `model.image` records. Never feed the
  check the manifest's own value — it would report `fresh` forever while measuring nothing. The CLI
  version in `caps=` is the guard that fires when the extension changes.
- **`-i/--image` on `codex exec`** — it exists ("Optional image(s) to attach to the initial prompt") and
  would put a reference in conversation context, but the built-in tool edits local files through
  `referenced_image_paths`, so the script does not spend the extra image tokens on it.

## Transparency: how `--transparent` behaves

The manifest says `native+chroma`, so the script:

1. keeps the caller's prompt **verbatim** — the chroma-only vendors strip the word `transparent`
   because it would poison a green-screen generation; here it names the very thing being asked for;
2. adds one instruction asking `image_gen` for a genuinely transparent background — its
   `transparent_background` argument set to true — with its alpha preserved, and a second, explicitly subordinate one: only if real transparency is impossible,
   fill the background with flat `#00FF00`. Without that ordered fallback an opaque answer would be
   keyed on whatever colour the model happened to choose, which eats the subject;
3. accepts the native alpha only when it is real — `magick identify -format '%A'` says the channel
   exists **and** `-alpha extract` has a minimum below 0.99. A PNG32 whose alpha is uniformly opaque
   passes the first test and would otherwise be delivered as a "transparent" flat image;
4. otherwise runs `share/image-chroma.sh` `chroma_key_to_png`, the same keyer the other legs use.

`--transparent` requires a `.png` destination in either branch.

## Resume

```bash
# first turn — note the session line
bin/codex-image --dest /tmp/badge.png --prompt 'a round blue enamel badge, white background'
# dest=/tmp/badge.png
# size=1024x1024
# format=png
# account=notcom
# session=01a09ccc-3333-7000-8000-00000000000c
# model=gpt-image model_caps=unknown verified=gpt-image-2
# caps=fresh

# second turn, same thread: the model edits the image it already made
bin/codex-image --dest /tmp/badge-bluer.png --prompt 'now make it bluer' \
  --resume 01a09ccc-3333-7000-8000-00000000000c
```

- `--resume` takes the **UUID** the first run printed, not a thread name: a name resumes fine in the
  CLI but cannot be traced back to the account that holds it.
- The account is **recovered, not routed for**. Each account has its own `CODEX_HOME`, so a session
  lives in exactly one of them; the script looks for `<home>/sessions/**/*<id>*` and
  `<home>/generated_images/<id>` across `~/.codex` and `$CODEX_PROFILES_DIR/*`. No candidate, or more
  than one, is an error asking for `--account` — never a guess, because `codex exec resume` answers an
  id it cannot find by silently starting a NEW thread ([openai/codex#15538](https://github.com/openai/codex/issues/15538)).
  `worker-pick` is not consulted on a resume at all.
- If the harvested `thread.started` id differs from the requested one anyway, the run says so on
  stderr and reports the id it actually got; the image is still delivered, since it is already paid for.
- With no `--ref`, a resume tells the model to edit the thread's own last image via
  `num_last_images_to_include: 1` — `referenced_image_paths` would need a local path per target.

## Text model and tier

A new thread runs `-m` = the worker table's codex family at its newest slug listed on that account
(`worker_model_codex_slug`), never the model an account's `config.toml` still names; a resumed thread
keeps its own. Every launch pins the standard tier (`--disable fast_mode -c 'service_tier="default"'`):
Fast is workers-only, and `config.toml`'s tier is Egor's interactive pick.

## Re-verifying (what to do when `caps=stale` shows up)

`caps=stale cli=<live> verified=<manifest>` means the CLI moved and the tool schema may have moved
with it. The whole check is two commands and a suite:

```bash
CB=$(dirname "$(dirname "$(readlink -f "$(command -v codex)")")")   # or the npm vendor path below
CB=~/.nvm/versions/node/*/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex
strings -n 8 $CB | LC_ALL=C grep -nE 'referenced_image_paths|num_last_images_to_include|imagegen|gpt-image|ImagegenArgs'
strings -n 4 $CB | LC_ALL=C grep -oE 'thread\.[a-z_]+|item\.[a-z_]+'      # exec JSONL event names
cat ~/.codex/skills/.system/imagegen/SKILL.md                              # the bundled skill ships with the binary
```

Then update `share/image-caps/codex.json`, bump its `verified` and `cli.version`, and run
`bash tests/test_codex_image.sh`. The suite never calls Codex: `tests/fixtures/fake-codex-image.sh`
impersonates it (argv and prompt recorded, JSONL emitted, images written into
`$CODEX_HOME/generated_images/<thread>/`), which is also how the launch flags are pinned — the
assertions read the argv the fixture recorded, not the script's own text. Flipping
`FAKE_CODEX_VERSION` is what exercises `caps=stale` itself.

`codex --version` is safe to run from a chat shell; `codex exec` and `codex help exec` are not (the
launch gate refuses a bare headless launch), which is why the flags above are read out of the binary
and the vendor docs instead of from `--help`.

One branch is deliberately untested: `transparent: "chroma"` (strip the word, generate on green).
The shipped manifest never selects it — it exists so a manifest that ever says `chroma` is honoured
rather than ignored.

## Aspect, size, transparency, region: one sentence builder

The tool takes none of these as arguments, so `request_sentences` in `bin/codex-image` turns `--aspect`,
`--size`, `--transparent` and `--region` into prompt sentences, and both routes append the very same text
(`tests/test_chatgpt_web.sh` asserts every web sentence appears verbatim in the CLI prompt; the fan-out passes
`--aspect` instead of its own wording):

- `--aspect 16:9` → `Make the image a 16:9 landscape frame: its width to height ratio exactly 16:9.`
  (portrait/square by the ratio; decimals like `2.39:1` allowed; `--aspect` and `--size` are exclusive)
- `--size 640x480` → `Make the image exactly 640x480 pixels.`
- `--transparent` → `Give it a genuinely transparent background: a PNG with an alpha channel.` + the chroma fallback
- `--region` → `Change only the area outlined in red; keep everything outside it exactly as it is, and leave no red outline in the result.`

Every run with `--aspect` or `--size` prints a last line `aspect=<W:H> achieved=<w/h> fit=ok|miss` (2%
tolerance). A miss is reported on stderr and the image is kept as generated — never cropped.

Verified live 2026-10-02 (`aspects_by_prompt` in the manifest): web 16:9 → 1672×941, web 9:16 → 941×1672,
cli 16:9 → 1664×936, all `fit=ok`; `--transparent` gave real alpha on both routes (web 1278×1230, cli
1313×1198, the page's own blob already carrying alpha). Unverified: cli 9:16.

**Web-only** (`web_only` in the manifest; the CLI refuses both with exit 2, never as prose):

- `--region x,y,w,h` (fractions of the image) with `--resume <chat>` (the chat's last image) or exactly one
  `--ref`: the viewer's Markup draws a red outline (clamped 16 px inside the canvas — its left edge is the
  panel resizer), the stroke must enable Undo or the run fails unsent, then the prompt goes with it. Live
  2026-10-02: the cube chat's front band became walnut (24% change inside, 0.6% outside, no red left).
  `--region` with `--ref` is unverified end to end.
- Re-aspect: `--resume <chat> --aspect W:H` with no `--prompt` runs `chatgpt-web resize`, the viewer's
  Resize menu (1:1, 3:4, 9:16, 4:3, 16:9 seen live); a ratio it does not offer exits 2 listing the offered
  ones (verified live). The pick-and-deliver path itself is unverified.

## Web route (fallback, explicit only)

`codex-image --route web …` drives chatgpt.com itself, in the same hidden Chrome clone as Google Flow
(`share/gemini_web.py`: one clone app, one hide watcher, one toast log, one failure-snapshot path), through
`bin/chatgpt-web` → `share/chatgpt_web.py`. The default stays `--route cli`; nothing ever falls back to
the web on its own.

- **Accounts** are the codex profile names (`main` = `~/.codex`, the rest `$CODEX_PROFILES_DIR/*`), each with
  its own Chrome profile under `${CHATGPT_WEB_DIR:-~/.chatgpt-web}/profiles/<name>`. The owner signs one in
  once: `codexb web <name>` (a visible Chrome; it refuses a name off the codex roster and runs
  `chatgpt-web login`, and a first `codexb p <name>` on a tty offers it, default no), then `chatgpt-web status <name>` binds the login's
  email to it (stored in `accounts/<name>.json`, printed masked). `chatgpt-web accounts` lists them.
- **Flags** are the CLI route's: `--dest --prompt --ref… --resume --account`; `--aspect`, `--size` and
  `--transparent` become the builder's sentences (the page has no knobs), `--region` and re-aspect are web-only, and delivery (alpha check, chroma fallback, format conversion)
  is the CLI route's own. Output is the same block with `session=` = the ChatGPT chat id, plus `route=web`
  and no `caps=` line (no CLI to version).
- **New chat vs resume**: no `--resume` opens a new chat; `--resume <chat id>` opens `chatgpt.com/c/<id>` on
  the account the job ledger (`jobs.jsonl`) names for it, else `--account` is required.
- **References** are uploaded through the composer's file input one at a time, in the order given, before
  the prompt is typed; a draft attachment a crashed run left in the chat is removed first.
- **Chat mode**: chatgpt.com can open in Work mode, whose composer makes no images; the run presses the
  `Chat` toggle when it is off.
- **Rotation** without `--account`: signed-in, bound, unwalled accounts inside the codex worker pool, least
  recently started first (`generation_started_at` in `accounts/<name>.json`, stamped when a new chat starts;
  a `--resume` stamps nothing), accounts busy with another run last.
- **Exit codes**: 3 (`CODEX_USAGE_LIMIT`) when the page shows its image limit — the stated reset time
  becomes the account's wall in `walls.json`, else `gw.WALL_SECONDS` — and 4 when the profile is signed out
  or was never signed in.
- **Never**: a call of a ChatGPT backend endpoint or a replayed request. The page's own `/backend-api/me`
  reply is read passively for the email and its `accounts/check` replies for the plan; the image is the
  page's own `blob:` src of the generated-image gallery, read inside the page (full size, e.g. 1374×1145).

Verified live 2026-10-01 (burkhartor, Plus): the session read, Chat mode, composer, file input, attachment
chip, send, the gallery image and its blob download, new chat and resume with a ref. Still unseen: the
stop button's label (streaming also counts the idle composer button being absent) and the limit wording
(`LIMIT`, `LIMIT_CUE`, `LIMIT_WHEN`).
