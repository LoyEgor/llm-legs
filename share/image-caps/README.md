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
  "short": {"image": "…", "video": "…"},
  "refs": {"max": 7, "verified_max": false},
  "aspects": {"generate": ["1:1", "16:9"], "edit": ["1:1", "4:3"], "default": "auto"},
  "exact_size": false,
  "transparent": "chroma",
  "resume": {"flag": "--resume", "id_source": "streaming-json session id"},
  "video": {"refs_max": 7, "durations": [6, 10], "resolutions": ["480p"], "voices_max": 3, "keyframes_max": 4},
  "unsupported": ["mask", "quality", "resolution", "n"]
}
```

- `short`: the task-row name of each `model` kind; a kind with a model and no short is `model_caps=stale`.
- `refs.max`: null when the CLI states no cap; `verified_max` false when the number is a
  safe working cap rather than a documented limit.
- `aspects`: null when the CLI has no aspect parameter (Codex takes size only as prose).
- `transparent`: `native` (the tool returns alpha), `chroma` (green background + key), `native+chroma`
  (try native, key when the result carries no alpha).
- `video`: null when the vendor has no video tool. `keyframes_max`: mid-clip anchors a pinned-frame
  tool takes (grok `reference_to_video`).
- `api_only`: what the vendor's REST API offers and the CLI tools do not carry — recorded so a
  release that wires one is noticed, never sent.
- Soft vs hard for the fan-out: `video: null` is hard (skip the vendor); `refs.max`, `aspects`,
  `exact_size`, `transparent` are soft (truncate, map to the nearest, emulate).
