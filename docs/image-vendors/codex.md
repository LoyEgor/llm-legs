# Codex image leg

`bin/codex-image` drives the Codex CLI's **built-in** `image_gen.imagegen` tool on a ChatGPT
subscription — never the API-key fallback (`~/.codex/skills/.system/imagegen/scripts/image_gen.py`,
which needs `OPENAI_API_KEY` and is a different model surface with different knobs). The limits the
script enforces come from `share/image-caps/codex.json` at runtime; this file says where every value
in that manifest came from and how to check it again.

Verified against `codex-cli 0.153.4` on 2026-09-11.

## Capabilities

| Capability | Value | Source |
| --- | --- | --- |
| Tool | `image_gen.imagegen` (built-in, no API key) | binary tool description, `ext/image-generation/src/tool.rs`; skill `SKILL.md` "Default built-in tool mode (preferred)" |
| Arguments | `prompt`, `referenced_image_paths`, `num_last_images_to_include` — and nothing else | binary: `struct ImagegenArgs with 3 elements`, `properties`/`additionalProperties` schema strings |
| Image model | `gpt-image-2` | binary: the literal sits inside `ext/image-generation/src/tool.rs`, beside the ImagegenArgs errors |
| Reference images | local paths, at most 5 | binary: `` `referenced_image_paths` must contain at most `` (the number is formatted at runtime, so the 5 is the tool description's own "up to 5" for the sibling argument — hence `refs.verified_max: false`) |
| Conversation images | `num_last_images_to_include` 1–5, never together with `referenced_image_paths` | binary: `` `num_last_images_to_include` must be between 1 and ``; "Never provide both" |
| Local-file edits | `view_image` the file first, then pass it in `referenced_image_paths` | binary tool description: "If you have not seen a local image yet, use `view_image` to inspect it before editing"; `SKILL.md` "Built-in edit semantics" |
| Transparency | native alpha, asked for in prose; keyed as a fallback | `SKILL.md` "For transparent images, ask built-in `image_gen` for a transparent background and preserve the generated alpha"; telemetry field `transparent_background` beside `saved_path` in the binary |
| Output location | `$CODEX_HOME/generated_images/<thread_id>/<name>.png` | `SKILL.md` save-path policy; live store: `~/.codex/generated_images/019f3d39-…/exec-<uuid>.png` |
| Session id | `thread.started` → `thread_id`, on `codex exec --experimental-json` | binary: the exec event enum `thread.started turn.started turn.completed turn.failed item.*`; [vendor docs](https://developers.openai.com/codex/noninteractive) |
| Resume | `codex exec [OPTIONS] resume <SESSION_ID> [PROMPT]`, `--last` for the newest | binary `ResumeArgs`: "Conversation/session id (UUID) or thread name … If omitted, use `--last`"; vendor docs |
| Exact size | no — prose only | `SKILL.md`: "Do not treat `Quality:`, size … as built-in `image_gen` tool arguments"; size/quality exist on the API fallback (`gpt-image-2`: edges multiple of 16, max edge 3840) and nowhere on the built-in tool |

## Not supported

- **Aspect ratio** — no argument at all; the manifest's `aspects` is `null`. Orientation is prose.
- **Exact size, quality, `n`, masks, `input_fidelity`, `background=transparent`** — every one of them is
  a fallback-CLI/API parameter. `--size` is passed to the model as a sentence and is a request, not a
  guarantee; with no `--size` the prompt asks for low quality, which is likewise only prose.
- **Video** — no video tool in this CLI; the manifest's `video` is `null`, which is the fan-out's hard
  skip signal for this vendor.
- **Naming the image model per run** — `codex exec` output never mentions `gpt-image-2`: the exec JSONL
  item vocabulary is `agent_message`, `reasoning`, `command_execution`, `file_change`,
  `mcp_tool_call`, `web_search`, `todo_list`, with no image item, and the saved PNG carries no
  metadata beyond `png:IHDR`. So `image_caps_model_check` is called with an EMPTY observation and every
  run prints `model=unknown model_caps=unknown`. Do not "fix" that by feeding it the manifest's own
  value — it would report `model_caps=fresh` forever while measuring nothing. The CLI version in
  `caps=` is the guard that actually fires when the extension changes.
- **`-i/--image` on `codex exec`** — it exists ("Optional image(s) to attach to the initial prompt") and
  would put a reference in conversation context, but the built-in tool edits local files through
  `referenced_image_paths`, so the script does not spend the extra image tokens on it.

## Transparency: how `--transparent` behaves

The manifest says `native+chroma`, so the script:

1. keeps the caller's prompt **verbatim** — the chroma-only vendors strip the word `transparent`
   because it would poison a green-screen generation; here it names the very thing being asked for;
2. adds one instruction asking `image_gen` for a genuinely transparent background with its alpha
   preserved, and a second, explicitly subordinate one: only if real transparency is impossible,
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
# model=unknown model_caps=unknown
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
