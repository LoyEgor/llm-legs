# Tuning the finding verifier

The record of the 2026-07-27 offline experiment on the `--verify` stage, and the protocol for
repeating it. Everything here was measured on history — no review was re-run to get a number.
The stage began as OpenCode-only and now also filters the agy leg; the sections below are
per side, and the OpenCode ones predate the agy leg entirely.

## Why the verifier exists

Raw OpenCode raters are noisy: adjudicated history shows `oc-kimik3` at 83% false positives
without verification and `oc-grok45-low` at 41%. With the windowed verifier (`oc-kimik3`,
no reasoning, ±120 lines) the same cells drop to 27% and 18%. The verifier is what makes the
leg usable; its own error rate is what this file measures.

## Ground truth and method

Every adjudicated finding of the two leg cells is a labeled item: judge verdict
confirmed/duplicate = real, false_positive = false. The verifier's past drops were judged
separately (they never reached adjudication). Replay = rebuild `verify_prompt` for a variant,
send each historical item through `opencode-go` exactly as `verify_one` does, compare the
keep/kill decision against the label. Items whose failure categories informed a variant's
rules are reported separately (held-out discipline); single replays are one stochastic
sample per item, so differences of one or two items are noise.

Dataset at the time of the experiment: 199 items (174 adjudicated + 25 judged drops) over
17 commits and two repos, plus 24 late-adjudicated raw-kimi findings held for validation.

## Measured 2026-07-27

- **False drops are rare and covered.** Of 25 historical drops, 3 were real (kimik3 1,
  grok45-low 2) — and each of the three was independently caught by another cell, so the
  two-cell leg lost nothing.
- **Surviving false positives have a shape.** kimik3: misread behavior 4, intended design 2,
  handled elsewhere 2, speculative environment 1, style 1. grok45-low: intended design 4,
  handled elsewhere 2. "Handled elsewhere" (6 of 16) is invisible to any windowed verifier
  by construction — the guard lives outside the ±120-line window. That is the current
  architecture's ceiling, accepted deliberately.
- **Variants.** V0 = shipped prompt. V1 = V0 + a "known failure modes" block: treat
  commented/documented behavior as intended design; re-check boolean/ordering logic against
  what the code computes; trace state through short-circuit branches before believing a
  failure; reject speculative environment states. V2 = V1 + "cannot decide → false".
- **Per-item vs per-defect tell opposite stories.** Per item, V1 looks like a bad trade
  (real findings lost 10.5% → 18.9%, false killed 54.5% → 66.3%). Per canonical defect —
  what a review actually surfaces — V1 is better on both axes: of the 42 defects the leg
  alone would catch, V0's kills cost 6 (including a P1), V1's cost 3 (P2 1, P3 2). V1's
  extra per-item kills land on redundant copies of defects whose other catch survives.
- **A two-prompt ensemble is not worth it.** "Kill only if V0 and V1 both kill" matches
  V1's defect-level retention (3/42) while killing fewer false positives (49.5%) at twice
  the calls. V2's strict-uncertainty default beat nothing anywhere and hit the OpenCode
  wall at 159/199.

Verdict: ship V1 for both leg cells. Its rules subsume grok45-low's dominant fp category
(intended design), so no grok-specific prompt is warranted on current data.

## Cross-vendor shootout, same day

Could a different model verify better than kimi? Measured on the second OpenCode key with
the identical V1 prompt:

- **Hold-out first**: V1-kimi on the 24 late-adjudicated raw findings it had never seen —
  17/23 false killed, the 1 real kept. The rules generalize; they were not fitted to history.
- **grok-4.5 as verifier**: per item slightly better than kimi (15.8% real lost, 69.3%
  false killed), per defect much worse — 8/42 leg defects lost including a P1. Its kills
  cluster on all copies of the same defect instead of spreading over redundant ones.
- **Cross-model ensemble** (kill only when kimi and grok both kill): defect losses match
  V1-kimi (3/42) but false-kill drops to 57.4% at twice the calls. No axis where it wins.
- **sol-low per claim**: 7.8s median but one call of twelve hung to the 300s timeout, and
  9/11 correct. Disqualified — tail latency, not the median, is what a 40-second leg feels.
- **gemini flash low per claim** (via geminib): 8.4s median, 10/12 correct — qualified on
  latency, not clearly better on the tiny probe, and it would drag a second vendor's
  account routing into the OpenCode leg. Not adopted; the probe result is here so nobody
  re-runs it from scratch.

Standing verdict: `oc-kimik3` with the V1 prompt, single call per finding, for both leg
cells. Beat it on defect-level losses AND false-kill rate before replacing it.

Rejected 2026-07-28 — cross-vendor consensus bypass: findings independently reported by
raters of >=2 vendors auto-keep, the verifier cutting only singletons. Offline replay on
the 199-item labeled set: recovers ~1 of the 3 lost defects but fp-kill collapses to 52.4%
(54.4% for the stricter paid+free-agreement variant), because multi-vendor agreement
clusters on identical false positives — the same wrong claim at the same file and line
from different models. Vendor agreement is not evidence of truth in this corpus. Caveat:
defect exports were missing for 8 of 17 commits, so the defect-loss side is partly
extrapolated (36/42 mapped); the fp side is measured directly and sinks the idea alone.

## The agy side, measured 2026-08-05

The verifier reaches Gemini findings from this date. Corpus: the agy leg's own adjudicated
claims (`agy-flash36*` raters), 6 real defects and 24 false ones, one call per claim.

- **`oc-dsv4flash`, shapes wording** — 6/6 real kept, 11/24 false dropped, 0 unverified. Same
  configured verifier as the OpenCode side, so the leg gained a filter without a second model.
- **`gemini-3.6-flash`, stock wording** — 6/6 real kept, 12/24 false dropped, 0 unverified.
  It is not given the shapes tail: those shapes were written from the OpenCode raters' false
  claims, and stock is what this model was measured best on here.

The second one shipped as a chain link rather than as the configured verifier, and only for
agy-side findings: every OpenCode link answers through one gateway, so a router outage there
retires the whole chain in a single move — twice on 2026-08-04, and every claim of those runs
filed unverified. The agy side has a transport of its own, so its chain became
`oc-dsv4flash → gemini-3.6-flash → the OpenCode rest`. OpenCode findings keep their chain
unchanged: there is no second transport to hand them to.

## The agy side again, measured 2026-08-08 — and the order reversed

The tie above is 30 claims wide. Replayed over 433, on a held-out split of 150 (75 real / 75
false, fixed seed, same items in the same order for every variant, one call each):

| verifier | prompt | real kept | false killed | defects lost |
| --- | --- | --- | --- | --- |
| gemini-3.6-flash medium | stock | 63/75 84% | 40/75 53% | 4/31 13% |
| gemini-3.6-flash medium | persona + do-not-comment list | 60/75 80% | 43/75 57% | 4/31 13% |
| gemini-3.6-flash medium | substance rubric | 61/75 81% | 42/75 56% | 5/31 16% |
| deepseek-v4-flash | shapes (its production wording) | 61/75 81% | 25/75 33% | 4/31 13% |
| deepseek-v4-flash | stock | 63/75 84% | 19/75 25% | 4/31 13% |
| deepseek-v4-flash | dual | 59/75 79% | 23/75 31% | 6/31 19% |

The model is the whole difference. Eleven wordings were screened on a disjoint 40-item split —
the review skill's persona, do-not-comment list and severity rubric, the shapes and dual tails,
and combinations; the three best landed within 4 points of plain stock here. Effort does not
move it either (high 93%/52% against medium's 92%/52% on 120 shared claims, 91% of decisions
identical), and neither does handing the verifier the file's diff beside the window (84%/52%
against 80%/57%, at a much larger prompt). deepseek is shown on its best wording, so this table
is generous to it.

Verdict: for agy findings the order reverses to `gemini-3.6-flash → oc-dsv4flash → the OpenCode
rest`. Against deepseek on the wording it actually runs — shapes, not the stock row it scores
best on — that is two more real kept, the same defect loss and 20 more points of false claims
killed, for about one
extra minute of Gemini per review (median 5 agy claims, ~8s each). The gateway stays behind it,
so a spent Gemini side still gets its findings judged.

OpenCode findings are unchanged, and this does not argue about them: the 33% is deepseek judging
*Gemini's* claims, while on the OpenCode leg's own claims the same stage takes kimik3 from 83%
false positives to 27%. Gemini was probed there on 2026-07-27 and rejected for dragging a second
vendor's account routing into that leg — that reasoning stands.

## Open at the time of writing

- Verifier wall-clock is not recorded anywhere (`duration_ms` is the rater alone); a
  `verify_ms` field must land together with the prompt change or tier timing stays blind.
- Repeating this: rebuild the labeled dataset from `benches/*/verdicts.jsonl`, judge any
  new drops, replay variants item-by-item, and read results per defect (via
  `defects/<repo>__<sha7>.jsonl` catches), never per item alone.
