# Image capability manifests

One JSON per vendor, `share/image-caps/<vendor>.json`, the single source of truth for what that
vendor's subscription CLI accepts. The image scripts read their limits from it at runtime (jq), the
fan-out adapts a request per vendor from it, and `image_caps_check` (share/image-caps.sh) compares the
live CLI version against `cli.version` so a changed binary announces itself as `caps=stale`.

Every value must be traceable to the CLI itself (bundled skill, tool schema strings in the binary,
vendor CLI docs). Re-verify when `caps=stale` or `model_caps=stale` shows up; then bump `verified`.

The audio routes check themselves against what each run already sees, so an option the vendor ADDS shows up
too, not only one that disappears: Gemini speech (`aistudio_speech.page_caps`) compares the model panel's
Audio filter (`-tts` ids), the chosen family's Expression tag chips, the speaker panel (3.8: per-use-case
counts and the names shown; older: every name) and the older models' Director's note menus with `.speech`;
Flow Music (`flow_music.page_caps`) compares the Lyria picker and every song menu the run opens
(`flow_music.menus`: ⋯ More options, its Remix and Download submenus) with `.flow_music`. Both print
`caps=fresh` or `caps=stale what=<part>: +added -gone; …` (`unread` when a part did not show). ElevenLabs
reads `GET /v1/models` at most once a day (cache `models-check.json` beside the key file) and prints
`model_caps=fresh|unknown` or `model_caps=stale new=… newer=<id>><default> gone=…` against `served_models`.

```json
{
  "vendor": "grok",
  "verified": "2026-09-11",
  "cli": {"name": "grok", "version": "1.0.13", "version_args": ["--version"]},
  "model": {"image": "…", "video": "…"},
  "refs": {"max": 7, "verified_max": false},
  "aspects": {"generate": ["1:1", "16:9"], "edit": ["1:1", "4:3"], "default": "auto"},
  "exact_size": false,
  "transparent": "chroma",
  "resume": {"flag": "--resume", "id_source": "streaming-json session id"},
  "video": {"refs_max": 7, "durations": [6, 10], "resolutions": ["480p"], "voices_max": 3, "keyframes_max": 4},
  "unsupported": ["mask", "quality", "resolution", "n"]
}
```

- `refs.max`: null when the CLI states no cap; `verified_max` false when the number is a
  safe working cap rather than a documented limit.
- `aspects`: null when the CLI has no aspect parameter (Codex takes size only as prose).
- `aspects_by_prompt` (codex): ratios a live run delivered from the `--aspect` sentence alone, checked by
  the script's `aspect=… fit=` line; `web_only`: features only the ChatGPT web route drives —
  `region` (`--region`, a Markup outline), `reaspect` (the viewer's Resize ratios), `point` (`--point`,
  Comment pins) and `remove_bg` (`--remove-bg`, the viewer's Remove BG: a regeneration delivered with alpha).
- `web` (codex): the `--route web` (ChatGPT) contract — `refs_max` and `counts` (`--count`: takes as new chats in
  tabs of one browser), while the top-level `refs` stay the CLI's.
- `counts` in a route's block (`flow_image`, `web`): the `--count` values that route renders in one launch; the
  fan-out packs that many takes of a request into one launch. `counts_batch: true` (`flow_image`): a launch's
  takes are one generation and land together, so the fan-out may pack a spare with the primaries; without it
  (ChatGPT tabs, each its own generation) spares get their own unit, launched only after the lazy-spare delay.
- `flow_image` (gemini): the `--route flow` contract — model labels and their observed `wire` keys, the
  five aspects, counts, `refs_max`, `upscale` menu items, `price` (a different composer quote stops the run).
  `flow_image.tools`: the Image Editor Tool behind `--region`/`--point`/`--remove-bg`/prompt-less `--aspect` —
  its `models` and outpaint `aspects`, `bg_models` (our name → the applet's label), `bg_models_broken` (name →
  why it is refused), `default_bg_model`, `brush_px`, `cutout_max_side`, `unsupported`, `timeout_s`.
- `scripts`: the vendor's media scripts in `bin/` by kind (`image`, `video`, `music`, `sfx`, `listen`); a kind
  the vendor lacks is absent. The vendor list itself is the set of manifests in this directory.
- `default_for`: kinds this vendor runs when several manifests name one and `media-run` gets no `--vendor`
  (gemini: `music`, `sfx`); two claiming one kind is a usage error.
- `rosters`: per route, the argv (a `bin/` name and its arguments) that lists that route's accounts: the web
  engines print `{"accounts": [{"account", "login", "walled_until", …}]}`, the CLI pools print `name: state` lines.
- `spares`: per media kind, the extra takes a fan-out launches up front for N requested ones,
  `max(min, ceil(N * ratio))`; a kind without an entry gets none (video and audio spend credits per take).
- `routes`: the vendor's image routes in priority order; the script runs `routes[0]` without `--route` and the
  fan-out adapts a request to that route's block (`flow` → `flow_image`, `web` → `web`, `cli` → the top-level
  `refs`/`aspects`, which always stay the `--route cli` contract).
- `transparent`: `native` (the tool returns alpha), `chroma` (green background + key), `native+chroma`
  (try native, key when the result carries no alpha).
- `video`: null when the vendor has no video tool. `keyframes_max`: mid-clip anchors a pinned-frame
  tool takes (grok `reference_to_video`).
- `api_only`: what the vendor's REST API offers and the CLI tools do not carry — recorded so a
  release that wires one is noticed, never sent.
- `accounts` (an API vendor, elevenlabs): the key file, `pool` (kind → accounts tried in order on a spent
  quota, `default` for the rest), `scoped` (a key's permission
  limit). Per-kind blocks (`sfx`, `music`, `speech`, …) hold the models, ranges and the `output_format` per
  dest extension the script reads; `costs` holds the measured credits.
- Soft vs hard for the fan-out: `video: null` is hard (skip the vendor); `refs.max`, `aspects`,
  `exact_size`, `transparent` are soft (truncate, map to the nearest, emulate).
