# OpenCode Go review-rater map (campaign 2026-08, snapshot 2026-08-13)

Which OpenCode Go model and effort rung to put in a review-bench leg, and which ones to stop
paying for. Every cell below was hand-scored against adjudicated defect lists on the reference
commits named in Method; nothing was ever recorded into the bench corpus. Per-run detail — walls,
token counts, individual finding ids, the waves that produced each row — lives in
`research/opencode-raters-2026-08.md`. This file is the conclusion; that one is the evidence.

## Method

- 5 reference commits, hand-scored against the adjudicated defect lists in
  `~/.claude-profiles/.claudeb/worker-stats/defects/llm-legs__<sha>.jsonl`:
  C1 `8553616` (Python/bash, 59 defects), C2 `8448a35` (Lua + PyObjC, 29), C3 `36dcb4f`
  (Python/bash, 17), M1 `fabcae4` (43), M2 `2ecc0bd` (32, barely used); plus mid 19.3k /
  mid+ 35.3k / big `143fc2f` (69.5k prompt, 44) for size curves. `review-bench record` was never
  run, so none of this reached the corpus.
- Symmetric gate (owner rule, 2026-08-13): a cell is promoted OR retired only at >=3 commits,
  >=2 languages, n>=3. The only exceptions are mechanical blocks (vendor removal, HTTP block, CLI
  vocabulary) and explicit owner closures. Always state coverage before a verdict.
- C2 (Lua + PyObjC) is a mandatory gate commit forever: it is the only commit that exposed
  vendor-specific domain failures — glm-5.2's instant collapse and ds-pro's heavy-rung
  hallucinations both surfaced there and nowhere else.
- Empty answers ("NO FINDINGS") are yield statistics, not defects: on these same commits sol
  (74 runs) and opus (52 runs) never return empty, while thin-thinking cells (sonnet low,
  agy-pro low, haiku) do so routinely; zero-CONFIRMED runs are normal for everyone
  (source: `worker-stats/reviews.jsonl` analysis, 2026-08-13 — not in the research log).
  "Breakdowns" in the tables below means mechanical failures only.

## Effort mechanics (hard-won facts)

- The `opencode-go` CLI vocabulary is `low|medium|high`. "max" is reachable only through the raw
  chat-completions API (`reasoning_effort` in the JSON body); the CLI answers rc=64.
- Judge the effective effort by `usage.completion_tokens_details.reasoning_tokens`, never by the
  flag you passed: the gateway silently drops the knob for `kimi-k2.7-code`, so all its rungs are
  one cell (verified by A/B and by reasoning-token counts).
- `gpt-5.6-luna`'s knob is dead ONLY on `/chat/completions`, and the root cause is in the
  gateway's source: the chat->Responses conversion hardcodes `reasoning: {effort: "medium"}` and
  drops the incoming `reasoning_effort` (so every chat-path "rung" is one effort=medium cell).
  The separate `/zen/go/v1/responses` route passes `reasoning: {effort}` through verbatim and the
  ladder works there — low 10 s / high ~3 min with 8-21k reasoning tokens exposed in
  `usage.output_tokens_details.reasoning_tokens` (research log §24-25). `opencode-go` speaks only
  `/chat/completions` today; the `/responses` path is a client feature to add at retune.
- k2.7-code's knob absence is exhaustively closed (research log §21): six request forms tried
  (`reasoning_effort`, `enable_thinking:false`, `</think>` prefill, `thinking_budget`,
  `reasoning.max_tokens`) — none moved reasoning_tokens — and Moonshot documents the model as
  thinking-only with `reasoning_effort` unsupported. Do not reopen without a vendor change.
- kimi reasoning-off ("off") rides a prefill-ladder hack that the vendor has already broken for
  k2.7-code — fragile by construction, not a stable configuration.
- Effort is one scale per model with a silent fallback to the priciest tier; qwen3.7-max's ladder
  is flat (low = medium = high = exactly 1 catch).

## Failure taxonomy

- **Wall-clock walls.** ds-flash `high` never returns (no answer in 1200 s, twice).
  kimi-k2.5/k2.6 run 11-20 min. k2.7-code runs 7-15 min with a fat tail past 20.
- **Own token ceilings.** glm-5.2 stops at 32,768 completion tokens regardless of what is
  requested (`finish_reason: length`), so its heaviest rungs often emit nothing.
- **Gateway stream cuts.** qwen3.8-max `xhigh` dies mid-reasoning at ~440 s / ~21k reasoning
  tokens (2 of 2, after the China-hosting opt-in).
- **Size blindness.** qwen3.8-max is blind at any budget on >=35k-token inputs; cured by
  splitting the diff (see below).
- **Domain collapse.** glm-5.2 on C2 answers in 2-3 s with no thinking at all (reproduced 4/4).
  The trigger is the FILE COMBINATION, not either language: each half answers fine alone in
  5-25 s.
- **Content pollution.** minimax-m3 (thinking on) and qwen3.8-max at its internal 16,384
  reasoning cap leak deliberation into `content`; a naive parser triple-counts findings.
- **The hallucination shape to fear:** a real nearby artifact cited as evidence for a wrong claim.
  ds-pro medium: "NSImage not imported" — it is, `overlay_app.py:47`. ds-pro high: the launchd
  label `com.apple.AssistiveControl` presented as the bundle id — the real `CFBundleIdentifier`
  is `com.apple.inputmethod.AssistiveControl`. mimo-v2.5 medium: an invented `show()` lambda
  "supported" by the real comment on `hide()`.

## The lesson that outranks the tables

Every "best single run" of this campaign failed to repeat: kimi-k3 max 5/5, ds-pro max 5/5,
hy3 high 4/4, qwen3.8-max xhigh 4/4, glm-5.2 max 6/6 — five spectacular results, five failures to
reproduce on the next commit. The whole cheap band did the same: every n=1 star (mimo-v2.5-pro,
minimax-m3 off, kimi-k3 low, hy3 low) fell on confirmation. Treat any single-round result as
noise until the gate closes, and never promote a cell on its jackpot.

## Tier 1 — production candidates

All rows here cleared the gate: >=3 commits, >=2 languages, n>=3.

| cell | catches/run | FP/run | breakdowns | wall | note |
|---|---|---|---|---|---|
| kimi-k2.7-code | 4.5 | 0.25 | 1 of 5 runs hit the 20-min cap (retry fit) | 7-15 min | top yield of the series; effort knob dead (23-44k thinking regardless of flag) |
| gpt-5.6-luna high (/responses only) | 2 | 0 (3 rounds) | none | 1.5-3 min | doubles the chat-medium cell's yield; M1 4/4/0; needs the /responses client path |
| kimi-k3 high | 2.4 | 0 (5 rounds) | none | ~4 min (6.5 at 35k input) | workhorse; zero noisy claims ever |
| kimi-k3 medium | 3.0 | 0.25 | none | ~4 min | half the thinking of high (5-11k); first noise on M1 (a hedged "function never defined" that is defined) |
| ds-pro low | 2.0 | 0 (4 rounds) | none | 2-5 min | quiet, cheap (11-22k), vendor diversity |
| ds-flash medium | 2.4 | ~0.2 | 1 transport drop (not the model) | 7-8 min | heavy thinker (43-67k); caught the C3 P1 security defect |
| qwen3.8-max medium | 2.3 | 0.33 | none | 1.5-8 min | blind on >=35k inputs — small/mid diffs, or split; mid-size M1 sees but yields thin (168 s · 1/1/0) |

## Tier 2 — second echelon (voices with caveats)

| cell | catches/run | FP/run | wall | note |
|---|---|---|---|---|
| kimi-k3 off (current leg) | 1-8 lottery | ~1 | 7-25 s | best union coverage per token; rides the fragile prefill hack |
| ds-flash off (current leg) | 3.3 | 5.3 | ~9 s | best raw yield in seconds; pays with 5+ noise per run (corpus) |
| ds-pro max | 3.0 | 0.33 | ~7 min | strongest ds-pro rung; one C2 noise round; 32-58k thinking |
| gpt-5.6-luna chat path (= hardcoded medium) | 1.5 | 0 (4 rounds) | 19-36 s | instant quiet small voice; M1 25 s 2/2/0; the ladder lives on /responses (Tier 1) |
| ds-flash low | ~1 | 0.2 | ~65 s | quiet small voice; no yield over its own free off |
| qwen3.7-max (any effort) | exactly 1 | 0 | 50-190 s | flat ladder; a voice, never a workhorse |
| minimax-m2.7 low | ~2.3 | ~2 | 19-88 s | C1 jackpot (6 catches / 1 noise @ 23 s), scattershot elsewhere; verifier-backed lottery |
| glm-5 high | ~2 | ~2 | 4-67 s | C3 3/3/0 @ 19 s but sprays noise on C2 (2 canon / 5 noise @ 4 s) |
| kimi-k3 max / ds-flash max | 2.67 / 1.7 | 0.33 / 0 | 6-11 min | both dominated by their own high/medium |
| glm-5.2 high + diff splitting | 1-2 | 0 | 1-3 min (5-25 s per split half) | C2 collapse cured by per-file split — bench-side feature required |

## Tier 3 — retired, with the honest reason

Retirement criteria: a mechanical block; domination (another cell gives >= the catches with <= the
noise and <= the wall — paying for a worse copy buys nothing); yield ~0; owner closure.
Hallucinations are NOT a retirement criterion — noisy voices run behind the verifier.

| cell | catches/run | FP/run | wall | reason |
|---|---|---|---|---|
| ds-pro medium | 2.0 | 0.2 | 6-17 min (unstable) | dominated by ds-pro max on every column |
| ds-pro high | 1.67 | 0.67 | 3-10 min | dominated by ds-pro max |
| minimax-m3 | ~2 | ~1.5 | 3-6 min | owner trim; as a lottery dominated by m2.7 low; thinking-on parser hazard |
| minimax-m2.5 low | ~1.5 | ~3 | 19-574 s | dominated by m2.7 low in-family |
| mimo-v2.5 low/medium/pro | ~1-1.2 | ~1-1.5 | 14-265 s | dominated both ways: as lottery by m2.7 low, as quiet voice by qwen3.7-max |
| glm-5.1 high | 1.0 | 0.75 | 34-63 s | dominated by qwen3.7-max (same 1 catch, zero noise) |
| qwen3.5 / 3.6 / 3.7-plus | 0-1 | ~0 | 2-143 s | yield ~0: blind at every paid rung |
| glm-5.2 off | ~3 | 4-7 | 2-21 s | noise fountain; splitting cures the collapse, not the noise |
| glm-5.2 max | — | — | — | dominated by glm-5.2 high on split inputs (123 s vs 5 s, same catch) |
| hy3 (all rungs) | 1-5 erratic | 0-3 | 2-17 min | owner closure: unpredictable walls up to 17 min on the smallest commit |
| kimi-k2.5 / k2.6 | 2.0 | 0 | 11-20 min | owner closure; half the runs never return |
| ds-flash high | — | — | >20 min | never returns (2/2) |
| grok-4.5 family | — | — | — | vendor 503 (two voices of the CURRENT production leg are dead) |
| qwen3.8-max xhigh | — | — | — | gateway stream cut 2/2 |
| hy3-preview, mimo-v2-pro / -omni | — | — | — | 400 unavailable / deprecated upstream |

## Diff-splitting workaround (proven 2026-08-13)

Splitting a diff at file boundaries into ~10-17k-token chunks:

1. cures glm-5.2's C2 domain collapse — each half answers in 5-25 s with real catches;
2. cures qwen3.8-max's >=35k size blindness — on big commit `143fc2f` the whole bundle is blind at
   any budget, while 4 chunks yield 2 canonical catches + 2 noise, walls 106-756 s (one chunk hit
   the internal 16,384 reasoning cap and leaked thinking into content);
3. does NOT cure noise — glm-5.2 off stays a noise fountain on splits.

This is a review-bench-side feature, not yet implemented.

## Version caveat

DeepSeek released V4 Pro 0813 (GA) on 2026-08-12 and points the bare `deepseek-v4-pro` endpoint
alias at it; OpenCode routes to the latest snapshot (its China opt-in page says "latest version").
The version seam runs straight through this campaign's ds-pro rows: the July figures are the
preview, and the 2026-08-12/13 figures — including all gate-closing waves — are almost certainly
0813. The gateway envelope exposes no snapshot id (`model` is the bare alias,
`system_fingerprint` is null), so the two cannot be told apart after the fact.

## Production state to reconcile at retune (`bin/review-bench:112-114`)

`OPENCODE_REVIEW_LEG` = kimi-k3 off x2, grok-4.5 low x2 (vendor-dead), ds-flash off x2; verifier
ds-flash. `WORTHLESS_CELLS` still condemns `oc-kimik27code` ("21 claims over 2 commits, 3 true")
and `oc-qwen37max` ("18 claims over 2 commits, 4 true") on July data that this campaign overturned
— lift both at retune. The retune is its own commit (owner rule).
