# OpenCode review roster: literal model ids go stale unseen

Found 2026-09-30 by the new `tests/test_no_hardcoded_models.sh`. Recorded there as `[KNOWN_DEBT]`
in `tests/hardcode-allowlist.txt`.

## State
- review-bench `share/rbench/catalog.py` `OPENCODE_MODEL_IDS` maps 12 `oc-*` cells to literal
  OpenCode Go model ids, such as `oc-glm52` → `glm-5.2`.
- No tier panel staffs these cells (`review-bench tiers` names none). They are parked roster entries.
  Their measured stats (`off_s`, `low_s`, claim counts, notes such as minimax-m3's token ceiling)
  are bound to one model version. They serve `--verify oc-*` candidates.
- `bin/vendor-fingerprint` does not watch OpenCode Go, so a new OpenCode model never raises an
  updater event.

## Why this is not a find-and-replace
Resolving "the newest per family" at run time would pin old measurements onto a model nobody has
measured. The ids here behave like `share/image-caps` proven pins. What is missing is the updater
that notices a newer model and measures it.

## Proposed shape
1. Add OpenCode Go's live `/models` list as a `vendor-fingerprint` facet. A new id in a family the
   roster holds raises a release event.
2. The updater run measures the new model, the way the roster rows were measured, and replaces the
   cell or adds it. Old cells move to a legacy-name map like `LEGACY_GROK_CELLS`, so stored runs
   still resolve.
3. Then reclassify the allowlist entry from `[KNOWN_DEBT]` to a measured-pin exemption, citing the
   facet.

Owner: whoever next works on the vendor-release updater. It is not urgent while no tier uses the
roster.
