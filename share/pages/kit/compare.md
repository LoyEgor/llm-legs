# compare: pictures side by side — an original + variants, or a pair; vote, tags, note, or a view grid
Synced loupes: drag pans all, wheel zooms at the pointer. From four frames up one checkbox, top right on each
preview and on its loupe, hides or shows that loupe, for every item of the visit. Right click a picture:
«Save image as…» under its file's name (none on a blind page).
«Метка» (Q, ⌥ held, or a pen such as an Apple Pencil): on any loupe a click marks one pixel, a drag a box. The page
draws a sheet (the whole picture with the context framed, that context cut from every frame with the grid if it was
on, the mark in magenta, an English caption naming Egor's zoom) and stores it as a pasted picture: its [imgN.png]
goes into the note at the caret, or, while Egor dictates in transcriptions-gpt, into the dictation at the word he
was saying. A reading model opens it. «Скрыть метки» (H) hides the marks on the loupes for the visit. The same
«Метка» works on any picture opened full screen, on every page (a button in its bar).

## Spec (CONTRACT.md, schema 1)
- **mode:** `vote` (default) or `view`, a numbered grid with no vote widget.
- **Without `original`:** two variants form a plain pairwise page.
- **blind:** variants are served as slots `A`, `B`, … without `id`/`label`; `choice` is the slot.
- **pixelated:** `true` (pixel art), `false`, or `auto` (pixelated at ≥3× zoom; the default).
- **zoom_levels:** e.g. `[1, 2, 4]`, the original's magnifications as buttons; digits pick them, the
  first one again fits; no hotspot row or fit button then. Default none.
- **options:** default one letter per variant of the shown item (`A`, `B`, …) and `tie` (`=`); `label` is
  what the button shows. A letter an item has no variant for is not shown on it, so one list (say
  `A`–`D`, `=`, «все плохи») serves items of 2–4 variants. Leave it out unless a choice beyond these is needed.
- **tags:** per-variant tag buttons. Only on Egor's ask: he seldom tags, and the rows push the loupes down.
- **Keys:**
  - `options[].key` is an `event.code`; defaults A→`KeyA`, B→`KeyB`, tie→`KeyT`;
  - ←/→ move between items, 0 fits, 1..9 jump to hotspots, +/− zoom.
- **Computed when absent:** `hotspots` (block-diff, `[x, y]` in the original's pixels), image sizes.
- **Per item:** `id` (immutable), `title`, `q` (a context line), `original`, `variants[]` (`id`,
  `label`, `src`, `meta` badge, `box`: `[x0, y0, x1, y1]` where it lies over the original, in its px;
  default the whole original), `grid`, `hotspots`, `n` (shown number), `suggest`
  (`{"choice": "A"}`, shown apart, never counted).
- **pixel_grid:** `true` adds «Сетка» (G): each variant's own pixel grid in its loupe. An item's
  `grid` (`{"x": [...], "y": [...]}`, cell bounds in the original's px, e.g. a detected lattice)
  adds it too, drawn over the original. Cells under 5 screen px stay undrawn. A bent lattice is
  `{"paths": [[[x, y], …], …], "cell": px}`; a list holds several, each with an optional `color`.
  A variant's own `grid` (cell bounds in its own px) replaces its pixel grid: a lattice laid on a big picture.
- **marks:** per item, `[[x0, y0, x1, y1], …]` in the original's px: framed on every loupe and preview,
  with «Рамка» (M) to hide them; on by default. `mark_width` (top level or per item): the frame's thickness in
  the original's px, so it zooms like a pixel (e.g. one art cell); default 2 screen px.
- **Common:** `title`, `intro`, `sitting_cap`; any `_` key is hidden, shown in `page state`.
- **Fields written:** `choice` (an option id; the slot when blind), `tags` (`{"A": [...]}`), `note`, `pins`
  (`{"imgN.png": {"on": "B", "at": [x, y] | [x0, y0, x1, y1], "z": zoom}}` in the original's px; not an answer).

## Example
```json
{"module": "compare", "schema": 1, "title": "Pixel judges calibration", "blind": true,
 "items": [{"id": "p01", "title": "frog", "original": "/abs/frog.png",
            "variants": [{"id": "v77", "label": "champ77", "src": "/abs/77/frog.png", "meta": "64 px"},
                         {"id": "v78", "label": "champ78", "src": "/abs/78/frog.png"}]}]}
```
