# Blender — local 3D stills, loops and web models

`blender-render` (`bin/blender-render`, scene code in `share/blender/`) drives Blender 5.2 LTS
(`brew install --cask blender`, `/opt/homebrew/bin/blender`) headless: Cycles on the M4's Metal GPU,
OpenImageDenoise, Khronos PBR Neutral view transform, 16-bit PNG. Local and free — no account, no consent step, no
`media-run`. Use it whenever the picture is a real 3D object that must stay exact (a logo, a product
mark, an icon in material); AI generation (`media` skill) stays the route for photos, scenes and
anything that need not be geometrically exact.

`blender-render doctor` checks the whole chain (Blender, GPU, HDRIs, ffmpeg, a probe render) — run it
first when anything looks off.

## Jobs

| Ask | Command |
|---|---|
| Logo/mark in material, still | `blender-render logo --svg <abs> --out <abs .png> [--material gold] [--color '#169148']` |
| Same on a transparent background | add `--transparent --backdrop none` (PNG with alpha, no background removal needed) |
| Loop for a page or a promo | `--out <abs .mp4>` (H.264), `.mov` (ProRes 4444, alpha), `.webm` (VP9, alpha, for the web); `--motion swing\|turntable --seconds 6 --fps 30` |
| three.js / model-viewer asset | `--out <abs .glb>` — Draco-compressed mesh with PBR materials (clearcoat and transmission export as KHR extensions) |
| Anything else in 3D | a bpy script: `blender-render run <script.py> [-- args]`, `import kit` works inside it |
| Hand-tune in the Blender UI | add `--save <abs .blend>` to any `logo` call, open it with `open <file>` |

Materials (`--material`): `gloss` (painted, clear-coated — default), `matte`, `satin`, `metal`
(tinted anodized), `brushed`, `gold`, `chrome`, `copper`, `glass`, `frosted`, `clay` (form review),
`emissive`. Without `--color` every SVG fill keeps its own color under the chosen finish.

Framing: `--angle front|hero|three-quarter|low|top|side` or `'azimuth,elevation'` in degrees;
`--lens 70`, `--margin 1.3` (air around the subject), `--dof <f-stop>`. Depth `--depth 0.14` and
`--bevel 0.012` are in metres on a logo normalized to 2 m wide.

Light: an HDRI from `~/.local/share/blender-assets/hdri` (`--hdri studio_small_09`; `blender-render
assets` lists them, `assets fetch <polyhaven-id>` adds one) plus a key/fill/rim area rig (`--key`
watts, `--no-lights` for HDRI only). The defaults (`--key 250 --hdri-strength 0.35`) are calibrated so a
backdrop reads as its own hex and a brand color as itself; brighten with `--exposure`, not the lights.
`--backdrop '#hex'` is a seamless studio sweep, `hdri` shows the
environment, `none` a plain white world (or nothing, with `--transparent`). Metals need the HDRI —
they mirror it.

Quality: default 2048×1152 at 384 samples. `--preview` halves the size and caps samples at 48 for
quick iteration; `--samples 1024` for a hero shot; `--engine eevee` for fast drafts (rasterized,
less exact light). `--view neutral` (default) keeps brand colors; `--view agx` is filmic but turns
saturated greens mint — with it, `--look` takes any AgX look (`AgX - Punchy`, …).

## Timing (Apple M4, 10-core GPU)

The first Cycles render after an install or a Blender update compiles the Metal kernels: ~11 min
once (run `doctor` right after updating), cached afterwards. Then a `--preview` still takes ~10-25 s and a
full 2048×1152 still at 384 samples ~110 s. Video renders every frame — run long ones with
`run_in_background: true`; 6 s at 30 fps is 180 frames, ~3 s a frame at `--preview`.

## One Blender at a time, unless memory holds two

A render holds ~9.3 GB phys_footprint, mostly wired Metal memory that cannot swap: two at once took the
24 GB Mac to 22.4 GB used and 5.5 GB swap (2026-10-14). Every Blender launch (`doctor`'s probe, `logo`, `run`)
first takes a slot of the machine-wide `blender` pool (`share/slots.sh`, `~/.cache/blender-render/slots`,
`BLENDER_RENDER_DIR`). One always runs; another only while
`available MB ≥ GUARD_AVAIL_MB + footprint + Σ (footprint − current footprint) over running Blenders` (the sum
covers a Blender just launched that has not allocated yet), and at most RAM ÷ footprint. The footprint is the median
peak phys_footprint of the last 9 successful runs (`peaks.jsonl`, sampled each second), 9.5 GB until measured.
A waiter prints `blender: waiting for a slot (N running, room R)` once, raises the `blender` limiter hold and
journals its wait (`docs/harness-doctor-design.md` §12). So queue renders freely: they run one after another.

## With the rest of the media chain

- A transparent PNG goes straight into a layout, a page or `magick` composites; `image-cutout` is
  not needed.
- A render can seed AI work: `media-run image -- --edit <render>` keeping every shape, position and
  the camera while the model replaces material and light (Blender's exact geometry, the model's finish;
  the media skill's Editing section), or a still as `--first-frame` for `media-run video` when the
  motion is too organic for Blender.
- Web: `.glb` loads in three.js (`GLTFLoader` + `DRACOLoader`) or `<model-viewer>`; `.webm` with
  alpha plays over any page background in Chromium and Firefox; Safari's WebM alpha is unreliable, so
  for it render the `.mp4` over the page's own background color (`--backdrop '#<page bg>'`).

## kit (share/blender/kit.py)

`clear()`, `render_settings(scene, size, samples, engine, transparent, view, look, exposure, fps)`,
`gpu(scene)`, `material(name, preset, color)`, `world_hdri(scene, name, strength, rotation,
background)`, `world_color`, `backdrop(color)`, `studio_lights(center)`, `area_light`, `aim`,
`import_svg(path, width, depth, bevel)`, `apply_material(obj, preset, color)`, `bounds(objects)`,
`camera(scene, objects, angle, lens, margin, fstop)`, `spin(obj, frames, motion)`,
`render_still`, `render_frames`, `export_glb`, `save_blend`. A script prints `RESULT key=value`
lines; `run` echoes them and `Saved:` lines, and the log path.
