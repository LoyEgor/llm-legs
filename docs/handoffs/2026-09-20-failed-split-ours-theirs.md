# Hand-off: `failed` legs now say whose failure they are — `ours` or `theirs`

Author: a worker chat on the failure-origin split, 2026-09-20. For whoever next touches the LLM
doctor menu (`hammerspoon/llm-limits.lua`). No Hammerspoon file is touched here: the data is in
place, the menu change is the proposal below.

## The two words

- `ours` — review-bench's own mechanics: a parser that found no finding, a gate, a sandbox, a
  budget, a crash, an auth or pool-of-accounts problem. Something in this house to fix.
- `theirs` — the provider's weather: `walled`, `throttled`, `bare 429`, `capacity`, `server error`.
  Nothing to fix; wait, or route elsewhere.

`cap` carries no origin word: our watchdog cutting a leg short answers whether the leg fits the
tier's time, not whose fault it was. The origin rides on `failed` alone.

The table lives once, in review-bench `share/rbench/panel.py` `FAILURE_ORIGIN` beside
`FAILURE_REASONS`, copied word for word into `bin/llm-weather`; both copies are pinned by
`tests/test_consistency.sh` (row `cq` of `docs/shared-invariants.md`).

## What `bin/llm-weather` now emits

Additively — no class renamed, no count moved:
- every leg carries `origin`: `ours` or `theirs` on a `failed` leg, `""` on every other class and on
  every worker-run leg;
- `models[].origins` counts those words per model, e.g. `{"ours": 1, "theirs": 1}`, and is `{}` for
  a model with no failed legs — beside `classes`, never instead of it;
- `incidents[].origin` carries the same word for its row.

Guarded by `tests/test_llm_weather.sh`: the key list, both words on one model, the empty origin
elsewhere.

## The proposal for the menu

The doctor's weather section prints one `failed ×N` row per model. Split it into `failed · ours ×N`
and `failed · theirs ×N` from `models[].origins`, `cap` untouched — one line is a bug list, the
other a forecast. A model with an empty `origins` keeps the single `failed ×N` row.

review-bench's report already prints the word: its `failed:` block appends it after the cause,
`gem-flash37 ×4  bad output · ours`, before the chronic-streak clause.

## Caveat: the origin word is a first cut, and the other columns hide `theirs` too

Egor's concern, 2026-09-20, after reading the first 48 h of the split: the provider's fault does
not sit only in `failed · theirs`. Keep this in mind before the menu treats one row as the whole
forecast.

- `bad output` is a mixed bag. The 18 `flash37` fails of these 48 h were all `ours` and are all
  fixed (6 + 10 refused by the old read-coverage floor, review-bench 4ec6d38; 2 refused as
  "0 model rounds" by a wrong stream field, 89a14e0). But a model that answers garbage, truncates,
  or ignores the answer form after reading everything lands in the same word and is `theirs`. The
  table cannot tell the two apart; only the stderr cause can, and only some causes name a gate.
- `slow` is relative, not absolute: `mark_slow` takes the median duration per (surface, model)
  over the 7-day trend window, needs at least `SLOW_MIN_LEGS = 5` legs, and marks a leg whose
  duration exceeds `SLOW_FACTOR = 2` × that median and has no other class. A provider capacity
  wobble shows up here as `slow`, origin `""`, never as `theirs`. The `sol` rows of
  `20260920T021015Z-6e4c657` (32–34 min against a 3 min median) are the current example: whether
  the cause is the provider or our own bigger `--task` prompts is not something the number says.
- `cap` (our watchdog cut) and `stalled` (`ours` in the table) can both be the provider's slowness
  arriving before our limit; `timeout` likewise.

So: the `ours` row is a reliable bug list only while each `ours` reason has a gate behind it; the
`theirs` row is a floor, not the whole weather. A finer cut (per-cause origin from the stderr
text, or a `mixed` word for `bad output`) is the doctor chat's call, not review-bench's; review-bench
will keep the table byte-equal with whatever the doctor settles on.
