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
