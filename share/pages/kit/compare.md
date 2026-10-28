# compare: pictures side by side — an original + variants, or a pair; vote, tags, note, or a view grid
Synced loupes: drag pans all, wheel zooms at the pointer; one vote, per-side tags, a note per item.

## Spec (CONTRACT.md, schema 1)
- **mode:** `vote` (default) or `view`, a numbered grid with no vote widget.
- **Without `original`:** two variants form a plain pairwise page.
- **blind:** the server serves each variant with `"slot": "A"`, `"B"`, … and without `id` and
  `label`; a vote's `choice` is that slot letter.
- **pixelated:** `true` (pixel art), `false`, or `auto` (pixelated at ≥3× zoom; the default).
- **integer_zoom:** `true`: a zoomed variant at whole screen px per image px on both axes; the
  fitted view fills the loupe. Default off: variants stretch over the original's box.
- **zoom_levels:** e.g. `[1, 2, 4]`, the original's magnifications as buttons; digits pick them, the
  first one again fits; no hotspot row or fit button then. Default none.
- **options:** default `A`, `B` (one per variant) and `tie` (`=`); `label` is what the button shows.
- **Keys:**
  - `options[].key` is an `event.code`; defaults A→`KeyA`, B→`KeyB`, tie→`KeyT`;
  - ←/→ move between items, 0 fits, 1..9 jump to hotspots, +/− zoom.
- **Computed when absent:** `hotspots` (block-diff, `[x, y]` in the original's pixels), image sizes.
- **Per item:** `id` (immutable), `title`, `q` (a context line), `original`, `variants[]` (`id`,
  `label`, `src`, `meta` badge such as `64 px`, `grid`), `hotspots`, `n` (shown number), `suggest`
  (`{"choice": "A"}`, shown apart, never counted).
- **variants[].grid:** `{"x": [...], "y": [...]}`, cell bounds in the original's pixels; «Сетка» (G)
  draws them over the original, one colour per variant, where cells are ≥ 5 screen px.
- **Common:** `title`, `intro`, `sitting_cap`; any `_` key is never served
  and shows in `page state`.
- **Fields written:**
  - `choice`: an option id, or a slot letter on blind pages;
  - `tags`: `{"A": [...], "B": [...]}`;
  - `note`: a string.

## Example
```json
{"module": "compare", "schema": 1, "title": "Pixel judges calibration",
 "mode": "vote", "blind": true, "pixelated": "auto",
 "options": [{"id": "A"}, {"id": "B"}, {"id": "tie", "label": "="},
             {"id": "both_bad", "label": "оба плохи"}, {"id": "unsure", "label": "не понять"}],
 "tags": ["halo", "jaggies", "lost detail"],
 "items": [{"id": "p01", "title": "frog", "q": "optional context line",
            "original": "/abs/frog.png",
            "variants": [{"id": "v77", "label": "champ77", "src": "/abs/77/frog.png", "meta": "64 px"},
                         {"id": "v78", "label": "champ78", "src": "/abs/78/frog.png"}],
            "hotspots": [[120, 40]]}]}
```
