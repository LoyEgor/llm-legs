# Harness index: Spend's headline and a chart of its own

Status: open — To: Harness Doctor (collector), Updater doctor (the Doctors menu chart)

From «Token spending tracking and optimization», 2026-10-07, token-map 3e3b078. Egor asked for this number to be integrated like the other harness metrics and charted in Doctor.

## What exists now
- `tracking.json` has a top-level `harness_index`:
  - `value` is a ratio. 1.00 means the harness costs the same per unit of use as in the previous 7 days, and 0.46 means it costs 54% less. `null` means too little use to price.
  - `change` holds the Δ cell (`-54%`) and `tone` holds `worse`, `better` or empty, following row db.
  - `coverage` is the share of Claude spend the index prices.
  - `effect` is the change in limit tokens at this window's use; `effect_share` is that change as a share of Claude spend.
  - `parts` is the breakdown: `[{part, zone, units, price, cost, points}]`, where the points add up to the Δ.
  - `weeks` is `[{week, value}]`, each week against the week before it.
- The same number is the first row of `rows` (`key: "harness_index"`, group `harness`), so the Token tracking submenu already shows it.
- Units are what Egor's load drives: contexts for startup, requests for the rest. Prices are what the harness charges per unit, per zone: startup, harness text, hook blocks with forced re-answers, cache re-writes, and hidden calls.
- Thinking, model, effort, the work itself and review-bench are left out. The method is in token-map `FINDINGS.md` § Harness index.
- First reading, 7 days to 2026-10-07: 0.46. The subagent 1h TTL accounts for -44 points.

## Wanted
1. **Spend head.** Lead with the index before the component shares. For example, `harness ×0.46 (-54%) · 11.3 % of spend priced · N audits due`. A `null` value reads `harness index: too little use`.
2. **History.** Keep `{YYYY-MM-DD: value}` per local day, the way `spend_by_day` is kept (`share/spend.py`). A day whose value is `null` gets no point.
   - The value compares 7 rolling days with the 7 before, so consecutive days overlap. That is intended: the series is a trend, not daily spend.
3. **Chart.**
   - Whitelist the key in `bin/harness-doctor` `menu_text`.
   - Add a `summaryTitle` series in `hammerspoon/doctors.lua`.
   - The sparkline formats with `%d`, so a ratio needs a decimal format, or the value ×100 with 100 as its baseline.
4. **Item 9 of `2026-10-07-tokenmap-waste-detectors.md` is done.** Each `rewrites` → `By cause` row now carries `avoidable` (bool), so `share/spend.py` `UNAVOIDABLE` can read the flag instead of keeping a copy.

## Done when
- The Harness doctor's Spend head shows the index.
- The Doctors chart draws its daily history.
- Each is covered by a test.
- `docs/shared-invariants.md` row db still agrees: the index row's Δ and tone come from tokenmap's `delta`.
