# Image capability manifests

One JSON per vendor, `share/image-caps/<vendor>.json`, the single source of truth for what that
vendor's subscription CLI accepts. The image scripts read their limits from it at runtime (jq), the
fan-out adapts a request per vendor from it, and `image_caps_check` (share/image-caps.sh) compares the
live CLI version against `cli.version` so a changed binary announces itself as `caps=stale`.

Every value must be traceable to the CLI itself (bundled skill, tool schema strings in the binary,
vendor CLI docs). Re-verify when `caps=stale` or `model_caps=stale` shows up; then bump `verified`.

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
  fan-out packs that many takes of a request into one launch.
- `flow_image` (gemini): the `--route flow` contract — model labels and their observed `wire` keys, the
  five aspects, counts, `refs_max`, `upscale` menu items, `price` (a different composer quote stops the run).
  `flow_image.tools`: the Image Editor Tool behind `--region`/`--point`/`--remove-bg`/prompt-less `--aspect` —
  its `models` and outpaint `aspects`, `bg_models` (our name → the applet's label), `bg_models_broken` (name →
  why it is refused), `default_bg_model`, `brush_px`, `cutout_max_side`, `unsupported`, `timeout_s`.
- `scripts`: the vendor's media scripts in `bin/` by kind (`image`, `video`, `music`, `sfx`, `listen`); a kind
  the vendor lacks is absent. The vendor list itself is the set of manifests in this directory.
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
- Soft vs hard for the fan-out: `video: null` is hard (skip the vendor); `refs.max`, `aspects`,
  `exact_size`, `transparent` are soft (truncate, map to the nearest, emulate).
