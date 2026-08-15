Raw working log of the 2026-08 OpenCode Go rater campaign. Distilled map: ../opencode-model-map.md.

# OpenCode Go as review raters — master table

Everything measured in this series, on profile `evyoxqy` only, hand-scored against the adjudicated
defect lists. Nothing was ever written to the corpus (`review-bench record` was never run).

Commits (all "small" by this series' standards — the big-diff work lives in the earlier sections of
(session-local artifact, not preserved)):

| key | commit | shape | prompt tok | canonical defects |
|---|---|---|---|---|
| **C1** | `8553616` | 7 files, 396 lines, Python/bash | ~11.9k | 59 |
| **C2** | `8448a35` | 4 files, 379+/171−, Lua + PyObjC | ~9.0k | 29 |
| **C3** | `36dcb4f` | 2 files, 185+/14−, Python/bash | ~3.6k | 17 |

Cell format: **wall s · findings/canonical/noise**. `n` counts *rounds* (distinct commits), not
repeats on one commit. "blind" = a bare `NO FINDINGS` answer, which on these commits is a miss, not
precision.

**C3 was never run at all**: every one of the twelve queued cells came back HTTP 429
`GoUsageLimitError` (`limitName: weekly`, resets in 4 days) — the Go plan's weekly wall on `evyoxqy`.
So no cell in this table is confirmed at three rounds; the best is `n=2`.

---

## 1. The full grid

### gpt-5.6-luna — ceiling 128 000, exposes no reasoning tokens at all

| effort | C1 | C2 | C3 |
|---|---|---|---|
| `none` | **35 · 3/3/0** | **36 · 1/1/0** | 429 |
| `low` | 29 · 2/2/0 | never run — not seeded in phase 2 | 429 |
| `medium` | 26 · 2/2/0 | never run — not seeded | never run |
| `high` | **22 · 3/3/0** | **31 · 1/1/0** | 429 |
| `xhigh` | 30 · 1/1/0 | never run — not seeded | never run |
| `max` | 29 · 3/3/0 | 35 · **blind** | 429 |

### kimi-k3 — ceiling 131 072

| effort | C1 | C2 | C3 |
|---|---|---|---|
| off | *incumbent* — corpus baseline 30 s, ~1.0 canonical / 5.0 noise per run | not tested — incumbent, not a candidate | not tested |
| `low` | 69 · 3/2/1 | never run — dominated by `medium` on C1 | never run |
| `medium` | **158 · 3/3/0** | **269 · 2/2/0** | 429 |
| `high` | **223 · 3/3/0** | **506 · 3/3/0** | 429 |
| `max` | **604 · 5/5/0** | 653 · 2/1/1 | not queued — round-2 noise disqualified it |

### kimi-k2.5 / k2.6 / k2.7-code — ceiling 65 536 / 65 536 / 262 144

| cell | C1 | C2 | C3 |
|---|---|---|---|
| k2.5 off | **1183 · 2/2/0** (3rd attempt; 1st = 503, 2nd = >1200) | never run — 20-minute cell | never run |
| k2.6 off | 683 · 2/2/0 | **>1200 killed** | not queued |
| k2.7-code off→ladder | 738 · 2/2/0 | never run — not seeded | never run |

### deepseek-v4-flash / -pro — ceiling 384 000 each

| cell | C1 | C2 | C3 |
|---|---|---|---|
| flash off | *incumbent* — 9 s, 3.33 canonical / 5.33 noise per run | not tested — incumbent | not tested |
| flash `low` | 70 · 1/1/0 | never run — loses to its own free baseline | never run |
| flash `high` | **>1200 twice** (n=2, both killed) | never run — no verdict to seed | never run |
| flash `max` | **483 · 2/2/0** | **557 · 2/2/0** | 429 |
| pro `high` | 187 · 2/1/1 | never run — `max` superseded it | never run |
| pro `max` | **438 · 5/5/0** | 323 · 2/1/1 | not queued — round-2 noise |

### glm family — glm-5.2 ceiling *nominally* 131 072, **actually 32 768**

| cell | C1 | C2 | C3 |
|---|---|---|---|
| glm-5.2 off | 13 s (corpus, July) | never run | never run |
| glm-5.2 `low` | 167 · 1/1/0 — *`low` and `high` are the same tier on this model* | never run | never run |
| glm-5.2 `high` | 132 · 2/2/0 · 199 · 1/1/0 · 207 · 1/1/0 (n=3 on C1) | never run | never run |
| glm-5.2 `max` | 242 · **6/6/0** once, then **empty** at ceilings 16 384 / 32 000 / 131 072 | never run — cell closed | never run |
| glm-5.1 off | 13 · 5/4/1 | never run — retired-cell canary only | never run |
| glm-5 off | 68 · 3/2/1 (one claim is a confident hallucination) | never run | never run |

### hy3 — ceiling 64 000 (`hy3-preview`: HTTP 400 `Model is unavailable`, unservable)

| effort | C1 | C2 | C3 |
|---|---|---|---|
| off | 21 · 6/5/1 | never run — `low` is strictly quieter | never run |
| `low` | **120 · 3/3/0** | 115 · **blind** | 429 |
| `high` | **675 · 4/4/0** | 631 · 4/1/**3** | not queued — round-2 noise |

### qwen family — plus/max ceiling 65 536, qwen3.8-max 131 072

| cell | C1 | C2 | C3 |
|---|---|---|---|
| 3.8-max off | 11 · 4/2/2 | never run | never run |
| 3.8-max `low` | 85 · 5/4/1 (run A, truncated) · 89 · 2/2/0 (run B) | never run | never run |
| 3.8-max `medium` | 483 · 2/2/0 | never run — `xhigh` superseded it | never run |
| 3.8-max `xhigh` | **513 · 4/4/0** | 721 · 2/1/1 | not queued — round-2 noise |
| 3.7-max off | 14 · 3/2/1 | never run | never run |
| 3.7-max `low` | 191 · 1/1/0 | **50 · 1/1/0** | 429 |
| 3.7-max `medium` | 87 · 1/1/0 | 116 · 1/1/0 | 429 |
| 3.7-plus `none` | 2 · **blind** | never run — blind floor | never run |
| 3.7-plus `low` | 109 · 1/1/0 | 99 · 1/1/0 | 429 |
| 3.7-plus `medium` | 89 · 1/1/0 | 91 · **blind** | 429 |
| 3.6-plus `none` | 3 · **blind** | never run — blind floor | never run |
| 3.6-plus `low` | 143 · 1/1/0 | 142 · **blind** | 429 |
| 3.6-plus `medium` | 116 · **blind** | never run — blind on C1 | never run |
| 3.5-plus `none` | 2 · **blind** | never run | never run |
| 3.5-plus `low` | 141 · **blind** | never run | never run |
| 3.5-plus `medium` | never run — deliberately: blind at two rungs already | never run | never run |

### minimax / mimo

| cell | C1 | C2 | C3 |
|---|---|---|---|
| minimax-m3 off | 340 · 3/3/0 | never run | never run |
| minimax-m3 thinking **on** | 285 · 14 claims → 3 distinct/0 noise | 166 · 12 claims → 1 distinct/**3 distinct noise** | not queued — round-2 noise |
| minimax-m2.5 off | 43 · 7/2/3 | never run | never run |
| minimax-m2.7 off | 20 · 10/4/**6** | never run | never run |
| mimo-v2.5 off | 56 · 1/1/0 · 55 · 1/0/1 (n=2 on C1 — a coin flip) | never run | never run |
| mimo-v2.5-pro | never run — never in a brief | never run | never run |
| mimo-v2-pro, mimo-v2-omni | HTTP 400 `Unsupported model` — unservable | — | — |
| grok-4.5 (any rung) | 503 `Endpoint is unavailable` — vendor-disabled | — | — |

---

## 2. Per-model limits

**Wall-clock walls** (the run does not come back inside 20 minutes):

* `deepseek-v4-flash` **`high`** — >1200 s twice, on the same commit its `max` answers in 483 s. The
  one rung on the whole grid that reliably never terminates.
* `kimi-k2.6` — 683 s on C1, killed at 1200 s on C2. Sits on the boundary; a smaller prompt did not
  make it faster.
* `kimi-k2.5` — 1183 s for its only completed run, after a 503 and a 1200 s kill. The slowest
  completing cell measured.
* `kimi-k2.7-code` — 738 s where the corpus recorded 10 s, because its reasoning-off request is
  rejected upstream and the client's ladder silently escalates it into a thinking run.
* `hy3 high` (631–675 s), `kimi-k3 max` (604–653 s), `qwen3.8-max xhigh` (513–721 s) — all real
  results, all far past T2's 228 s median.

**Own token ceilings** (the model truncates regardless of what we ask for):

* **`glm-5.2` stops at 32 768 completion tokens no matter what.** Asked for 131 072, it returned
  `finish_reason: length` at exactly 32 768 with an empty answer and 117 251 characters of reasoning.
  At `max` effort its thinking always exceeds that, so the cell produced one answer in four attempts.
  The one success (242 s · 6/6/0) is unreproducible and must not be treated as a candidate.
* `kimi-k2.5` / `kimi-k2.6` / `glm-5.2` all burned an entire 16 384 ceiling on thinking in Wave A —
  that was our ceiling, not theirs, and lifting it fixed k2.5 and k2.6.
* `deepseek-v4-flash max` needs 60–68k completion tokens per run. It fits only because its ceiling is
  384 000.

**Silence** (answers `NO FINDINGS` on a commit with adjudicated defects):

* `qwen3.5-plus` — blind at `none` (2 s) and at `low` (141 s, 8 192 reasoning tokens). Paid blindness.
* `qwen3.6-plus` — blind at `none`, 1 catch at `low` on C1, blind at `low` on C2, blind at `medium`.
* `qwen3.7-plus` — blind at `none` and at `medium` on C2; 1 catch at `low` on both commits.
* `gpt-5.6-luna max` — blind on C2 in 35 s while the same model at `none` and `high` answers 1/1/0 on
  that commit. Effort is not monotonic in yield anywhere in this grid.
* `hy3 low` — 3/3/0 on C1, blind on C2.
* `qwen3.8-max` — blind on the big commit (143fc2f) at every budget from 0 to ≥24 000; the collapse
  is driven by input size, not difficulty (see the batch-3 control).

**Structural hazards** (answer arrives but is unusable as-is):

* `minimax-m3` with thinking on writes 85–134k characters of deliberation into `content` and no
  `reasoning_content`; the bench parser harvests 12–14 "findings" that are really 3–4 claims. Any
  consumer counting findings triple-counts it.
* `glm-5` invents deletions — its one unmatched claim on C1 asserts that code present in the file was
  removed and would raise `NameError`.
* `minimax-m2.7` — 6 unmatched claims out of 10, several with no line number at all, and a usage
  object reporting `prompt_tokens: 0`.

**Unservable** (listed by `/models`, rejected at request time): `mimo-v2-pro`, `mimo-v2-omni`
(`Unsupported model`), `hy3-preview` (`Model is unavailable`), and the whole `grok-4.5` family (503).

---

## 3. Ranking — catches vs noise vs wall

Sorted by what a review leg actually buys: *confirmed* zero-noise catches first, then yield per
second. `canon/s` = canonical catches ÷ wall seconds, averaged over the rounds run.

| # | cell | n | C1 | C2 | canon/s | verdict |
|---|---|---|---|---|---|---|
| 1 | **kimi-k3 `high`** | **2** | 223 · 3/3/0 | 506 · 3/3/0 | 0.010 | **Only cell with ≥3 canonical and zero noise on both commits.** The most trustworthy result in the series. |
| 2 | **kimi-k3 `medium`** | **2** | 158 · 3/3/0 | 269 · 2/2/0 | 0.013 | Same shape at ~half the wall, one catch fewer on C2. The best cost/benefit above the incumbents. |
| 3 | **gpt-5.6-luna `high`** | **2** | 22 · 3/3/0 | 31 · 1/1/0 | **0.084** | 8× cheaper than anything else per catch, zero noise twice. Low absolute yield on C2. |
| 4 | **gpt-5.6-luna `none`** | **2** | 35 · 3/3/0 | 36 · 1/1/0 | 0.057 | Same, at the floor rung — no reasoning tokens at all. Effectively free. |
| 5 | **deepseek-v4-flash `max`** | **2** | 483 · 2/2/0 | 557 · 2/2/0 | 0.004 | Perfectly consistent and perfectly quiet; the slowest way to buy 2 catches. 60–68k reasoning tokens per run. |
| 6 | qwen3.7-max `medium` | 2 | 87 · 1/1/0 | 116 · 1/1/0 | 0.010 | Cheap, reliable, one catch per run — a ceiling, not a floor. |
| 7 | qwen3.7-max `low` | 2 | 191 · 1/1/0 | 50 · 1/1/0 | 0.014 | Same yield, wildly variable wall (50–191 s). |
| 8 | qwen3.7-plus `low` | 2 | 109 · 1/1/0 | 99 · 1/1/0 | 0.010 | Same one-catch ceiling. |
| 9 | **kimi-k3 `max`** | 2 | **604 · 5/5/0** | 653 · 2/1/1 | — | Highest single run ever measured (5 distinct defects, incl. the only doc-vs-code catch), then 1 catch + 1 noise on C2. **Do not trust the 5/5 as a cell property.** |
| 10 | **deepseek-v4-pro `max`** | 2 | **438 · 5/5/0** | 323 · 2/1/1 | — | Same story, 27 % faster. Previously written off on a July recording taken on a big diff. |
| 11 | qwen3.8-max `xhigh` | 2 | 513 · 4/4/0 | 721 · 2/1/1 | — | Not blind — under-powered. Its documented default budget is the rung that works. |
| 12 | **hy3 `high`** | 2 | **675 · 4/4/0** | 631 · 4/1/**3** | — | The largest round-to-round swing in the series: 4-for-4 clean, then 1-of-4 with 3 noise. |
| 13 | hy3 `low` | 2 | 120 · 3/3/0 | 115 · blind | — | Quiet both times, but silent on C2. |
| 14 | gpt-5.6-luna `max` | 2 | 29 · 3/3/0 | 35 · blind | — | Paying for the top rung bought blindness. |
| 15 | kimi-k2.6 off | 2 | 683 · 2/2/0 | >1200 killed | 0.003 | "Slower but quieter" in the literal sense; half the time it does not come back. |
| 16 | kimi-k2.5 off | 1 | 1183 · 2/2/0 | — | 0.002 | 19.7 minutes for 2 catches. Recorded, not recommended. |
| 17 | glm-5.2 `high` | 1 (n=3 on C1) | 132 · 2/2/0, 199 · 1/1/0, 207 · 1/1/0 | — | 0.008 | The only cell repeated three times on one commit: always quiet, always thin. |
| 18 | qwen3.7-plus `medium`, qwen3.6-plus `low` | 2 | 89–143 · 1/1/0 | blind | — | One catch on C1, silence on C2. |
| 19 | minimax-m3 thinking-on | 2 | 285 · 3 distinct/0 | 166 · 1/**3** | — | Parser hazard first, rater second. |
| 20 | mimo-v2.5 off | 1 (n=2 on C1) | 56 · 1/1/0, 55 · 1/0/1 | — | — | A coin flip: one canonical, one noise, in two runs. |
| — | qwen3.5-plus, qwen3.6-plus `medium` | 1–2 | blind everywhere | — | 0 | Blind at every rung paid for. |
| — | minimax-m2.7, minimax-m2.5, glm-5, glm-5.1, hy3 off, qwen3.8-max off/`low` | 1 | 20–89 s, 1–6 noise each | — | — | Retired-canary screening only. Noisy. |

### Reading the ranking

* **Rows 1–5 are the shortlist.** They are the only cells that produced canonical catches with zero
  noise on **two different commits in two different languages**. Everything below row 8 has at least
  one round where it went noisy or went silent.
* **Every "best single run" in this series failed to repeat** — `kimi-k3 max` 5/5, `dsv4pro max` 5/5,
  `hy3 high` 4/4, `qwen3.8-max xhigh` 4/4, `glm-5.2 max` 6/6. Five separate spectacular results, five
  failures to reproduce. That is the single most important number in this table.
* **n=2 is the ceiling of confidence available.** C3 was walled, so no cell reached three rounds.
* The incumbents (`kimi-k3` off, `deepseek-v4-flash` off, `grok-4.5 low`) were deliberately not
  re-measured; the comparison figures quoted for them come from the existing corpus.

---

## 4. Luna A/B — same model id through both legs (2026-08-12)

`gpt-5.6-luna` is served by the ChatGPT plan too (`codex exec -m gpt-5.6-luna`, bare mode, same
prompt bundles byte-for-byte, empty cwd, zero tool calls in all four transcripts — verified).

| cell | C1 8553616 | C2 8448a35 | tokens (cx) |
|---|---|---|---|
| oc-luna `none` | 35 s · 3/3/0 | 36 s · 1/1/0 | n/a |
| **cx-luna `none`** | 7 s · 2/2/0 | 9 s · 1/1/0 | 23–27k |
| oc-luna `high` | 22 s · 3/3/0 | 31 s · 1/1/0 | n/a |
| **cx-luna `high`** | **424 s · 6/6/0** | **232 s · 7 canonical + 1 unmatched (drainTick/safe(), not in the adjudicated list)** | 86–211k |

Readings:

1. **Same model, almost certainly.** Identical output discipline, overlapping finding families
   (failed-flag defect 720, zero-exit-429 defect 710 found from both legs), zero noise at `none`.
2. **The effort knob never reaches luna through OpenCode.** oc walls are flat 22–36 s across
   `none`→`max` with flat 1–3 catches; codex spreads 7–9 s (`none`) vs 232–424 s (`high`) with
   6–7 canonical catches. Every oc-luna "rung" is the same cell; the gateway drops
   `reasoning_effort` on the responses-API path. oc-luna `max` "blindness" on C2 is just this cell's
   normal 0–1 yield, not an effort effect.
3. **cx-luna `high` is a new top cell (n=2, two commits, two languages):** 6/6/0 on C1 —
   matching the unreproduced glm-5.2-max star, but confirmed twice — and 7 canonical on C2.
   Compare sol-high on C1: 3.8 confirmed · 1.4 FP · 464 s. Cheaper noise, more catches, same wall.
   Costs ChatGPT-plan quota (86–211k tok/run), not OpenCode quota.
4. Raw artifacts: (session-local artifact, not preserved).

---

## 5. glm-5.2 off/high fill wave (2026-08-12, dioqktn)

Off via raw `opencode-go run --no-reasoning`; high via review-bench `oc-glm52-high` (the bare
`oc-glm52` off spelling is retired in WORTHLESS_CELLS and the gate refuses it — off therefore ran
raw). Hand-scored vs adjudicated lists; nothing recorded, triage handoffs left unanswered on purpose.

| cell | C1 11.9k Py/bash | C2 9.0k Lua/PyObjC | C3 3.6k Py/bash | mid 19.3k bash |
|---|---|---|---|---|
| off | 21s · 4 canon/4 noise; 4s · 3/4 (n=2) | 2s · 0/1 ×2 — collapse | 5s · 2/7 | 16s · ~3/5 |
| high | 132–207s · 1–2/0 (n=3, Aug 11) | **3s · ct=185/65, no thinking — collapse ×2** | 48s · **2/2/0** | 56s · **1/1/0** |

Readings:
1. **The off retirement is justified, not stale**: post-drift off is still a noise fountain
   (4–7 unmatched claims per run on three of four commits). Slightly better than July's 4–17% true
   rate, still far from usable.
2. **high is genuinely quiet where it works**: five clean runs across C1(n=3)/C3/mid, zero noise,
   but thin — 1–2 catches. Usage shows real thinking (ct 6.8–7.7k on C3/mid).
3. **New failure mode: domain collapse.** On C2 both off and high return in 2–3s with one garbled
   claim; high's completion tokens are 185/65 — it did not think at all. C2 is only 9k tokens, so
   this is NOT the ≥35k size blindness: glm-5.2 collapses on the Lua+PyObjC domain regardless of
   effort. C3/mid ran minutes later and thought properly, so not gateway weather.

## 6. Cheap-band confirmation wave (2026-08-12, dioqktn, raw client)

Candidates that looked promising at n=1, re-run on commits they had never seen:

| cell | prior | new | verdict |
|---|---|---|---|
| mimo-v2.5-pro | C1 14s · 3/3/0 (n=1 canary) | C2 70s · 0 canon/1 noise; C3 69s · ~2 canon/4 noise | canary did not confirm — noisy middler, out |
| minimax-m3 off | C1 340s · 3/3/0 (n=1) | C2 175s · 0 canon/3 noise | did not confirm, out |
| kimi-k3 low | C1 69s · 2 canon/1 noise | C2 53s · **3/3/0**; C3 22s · **blind** (610 think tok) | capricious: strong on 2 of 3, silent on the third |
| hy3 low | C1 3/3/0; C2 blind | C3 28s · **blind** | blind 2 of 3 — out |

Every n=1 star of the cheap band fell on confirmation — same lesson as the max/xhigh stars.
C3 note: cheap cells go quiet on it broadly (sol-low/medium corpus rows also 0 confirmed there);
glm-5.2 high's 2/2/0 is the C3 exception, not the rule.

## 7. Shortlist round 3 — C3 36dcb4f (2026-08-12, dioqktn)

| cell | C3 result | shortlist status after |
|---|---|---|
| kimi-k3 medium | 160s · **2/2/0** (iter_usage nulls = def 40, age<=span = def 46) | **n=3, zero noise on all three commits** |
| kimi-k3 high | 107s · **2/2/0** (bare-429 scan = def 18, usage .json-vs-.jsonl = def 662) | **n=3, zero noise on all three commits** |
| oc-luna (single rung, `none`) | 19s · **1/1/0** (def 662) | n=3 zero noise (3/1/1 catches) |
| ds-v4-flash max | **HTTP 403 RegionError** — "latest version China-hosted, requires explicit opt-in" at the dioqktn workspace page | blocked on dioqktn, not a verdict; n stays 2. evyoxqy may differ (walled till ~Aug 16) |

New vendor fact: deepseek-v4-flash now needs a per-workspace China-hosting opt-in (403 with
workspace URL). If production review legs ever run ds cells on a non-opted account they will 403.

## 8. Non-max wave: unlock probes, ds-flash low, kimi-k3 high size curve (2026-08-12, dioqktn)

Probes after the China opt-in: mimo-v2-pro and mimo-v2-omni are **deprecated upstream** (400,
"migrate to xiaomi/mimo-v2.5[-pro]"), hy3-preview still "Model is unavailable" — all three closed
for good, opt-in did not unlock them. grok-4.5 untested per owner (vendor-blocked).

| cell | result | score |
|---|---|---|
| ds-flash low C2 | 57s · 1 finding | 0 canon / 1 noise (CGGetActiveDisplayList claim, not canonical) |
| ds-flash low C3 | 68s · 2 findings | **2/2/0** (defs 40, 28) |
| kimi-k3 high mid 19.3k | 281s | **2/2/0** (defs codexb:129, claudeb:1494) |
| kimi-k3 high mid+ 35.3k | 397s | **2/2/0** (defs 86, 333 — both key-in-argv catches) |

kimi-k3 high wall curve: 107–223s (small) → 281s (19.3k) → 397s (35.3k) → 1719s (69.5k).
Under 600s through 35k prompt tokens = ~88% of real bench traffic; only the p95+ tail is out of
reach. Zero noise in all five scored rounds — the confirmed workhorse of the whole series.
ds-flash low across three commits: 1/0, 0/1, 2/0 — inconsistent, adds silence but not yield over
its own free off baseline; reserve at best.

## 9. kimi-k2.7-code retest (2026-08-12, dioqktn, --no-reasoning ladder)

Upstream still rejects reasoning-off ("reasoning-off strategy rejected, falling back to
enable-thinking"); every run thinks ~23-26k tokens regardless of prompt size.

| commit | wall | score |
|---|---|---|
| C1 11.9k | 421s (was 738s in wave A — gateway drifted again) | **5/5/0** — defs 710, 720/724, 377, 75, 33 |
| C3 3.6k | 469s | **4/4/0** — defs 661, 55, 18, 662 |
| C2 9.0k Lua | **killed at 1200s, rc=137** — never answered | n/a |

Best per-run yields of the whole series (5 and 4 canonical, zero noise), at a flat ~7-8 min
floor — but it does not terminate on the Lua+PyObjC commit at all (same domain where glm-5.2
collapses instantly and the k3-family stars went noisy). A domain-gated candidate only:
Python/bash diffs, T3-style time budget. Wave-A's 2/2/0 was the same cell on a worse gateway day.

### 9a. Correction — the C2 "hang" did not reproduce (owner-prompted rerun)

k2.7-code C2 attempt 2: **870s · 3/3/0** (defs 111, 1003, 704), 42.6k thinking tokens vs 23-26k
on C1/C3. So C2 is not a wall for it — it is ~1.7× more thinking, putting the wall at the
1200s-cap boundary: 1 of 2 runs fits. "Domain collapse" retracted for k2.7-code (it stands for
glm-5.2, whose C2 no-thinking collapse reproduced 4 of 4). Full k2.7-code record: 12/12 canonical,
zero noise, three commits, three languages — the highest-yield clean cell of the series, qualified
by wall-clock only (7-15+ min, fat tail past 20).

## 10. hy3 high tiebreak — C3 (2026-08-12, dioqktn)

1021s · 2 findings: usage .json-vs-.jsonl (def 662 ✓) + one unmatched (probe() lacking
--always-approve — not in the adjudicated list). 30k thinking tokens on a 3.6k prompt.
Final hy3-high record: 675s·4/4/0 → 631s·1/**3** → 1021s·1/1. Inconsistent yield, noise in two of
three rounds, and the wall balloons unpredictably (17 min on the smallest commit). **hy3 closed
entirely** (low blind 2/3, high noisy-erratic, off noisy, preview unservable).

### 6a. kimi-k3 low — C3 blindness rerun

C3 attempt 2: 38s · 1/1/0 (def 662), 1019 thinking tokens vs 610 in the blind attempt. Full low
record: C1 69s·2+1noise, C2 53s·3/0, C3 blind → 1/0. The cell is a lottery: at a ~0.6-1.2k
thinking budget the per-run investment is too small to be stable — draws range from
best-in-class (C2) to silent (C3 r1) to noisy (C1). Its NO FINDINGS carries no information.
Not shortlisted; medium (5-10k thinking) is where kimi-k3 becomes reliable.

## 11. qwen3.8-max xhigh — C3 attempt (2026-08-12, dioqktn, post China opt-in)

Two runs, identical failure: 434s / 441s, ~82-84k chars of streamed reasoning_content (which now
streams — models.dev said it never did; gateway changed), then the stream dies mid-thought.
finish_reason null, content empty, HTTP 200. Last week's xhigh runs on C1 (513s) and C2 (721s)
completed fine, so this ceiling is new. Suspicion (unverified, deliberately): today's China-hosting
opt-in re-routed qwen upstream and the new host cuts reasoning at ~21k tokens. Cell operationally
dead on this account as of today — 0 answers of 2, tokens burnt. Park; recheck after any account
or vendor change.

## 12. kimi-k3 off vs low interleaved A/B — C1 (2026-08-12, dioqktn, same gateway hour)

Order: off1, low1, off2, low2, off3, low3. Scored by hand vs llm-legs__8553616.jsonl (59).

| run  | wall | think tok | findings | catches (canonical) | noise |
|------|------|-----------|----------|---------------------|-------|
| off1 | 25s  | 0         | 9        | ~8: 466, 710, 496/531, 244-null, 377/508, 499, 835, 75 | 0-1 (656-borderline) |
| off2 | 7s   | 0         | 2        | 1: 710              | 1 (KeyError claim off-canon) |
| off3 | 12s  | 0         | 4        | 2-3: 710, 244-tight, (720/724) | 2 (KeyError claims) |
| low1 | 46s  | 1216      | 3        | 3: 707, 710, 656    | 0 |
| low2 | 46s  | 1215      | 3        | 2: 710, 707         | 1 (wp:99 env-validation, off-canon) |
| low3 | 76s  | 2267      | 3        | 3: 724, 710, 232    | 0 |

Union coverage: off ≈ 10 distinct canonicals, low = 5. Per-run noise avg: off 1.0, low 0.33.
Variance: off is a lottery (1..9 findings, one jackpot run); low is metronomic (3 findings every
run, heavy overlap between its own runs — all three hit 710).

Verdict: today's data does NOT support "low = same catches, less noise" (my earlier framing from
historical runs was wrong for this day). Off wins union coverage 2x thanks to jackpot runs; its
noise today was modest and plausible-shaped. Low's real advantages are only (a) run-to-run
stability, (b) not depending on the prefill-ladder hack the vendor already broke for k2.7-code.
Swap decision left to Egor: quality says keep off (or run both as ensemble voices), robustness
says low.

## 13. ds-pro low/medium + qwen3.7-max high (2026-08-12/13, dioqktn)

| cell | C1 (59) | C3 (17) | think tok | note |
|------|---------|---------|-----------|------|
| deepseek-v4-pro low | 142s · 2/2/0 (710, 724) | 130s · 1/1/0 (662) | 8.3k / 11.6k | quiet voice: small, clean, cheap |
| deepseek-v4-pro medium | 352s · 4/4/0 (710, 25, 835, 377) | 395s · 2/2/0 (gu:18, gu:46) | 31.6k / 33.8k | discovery: zero noise, 2 langs, ~6 min |
| qwen3.7-max high | 96s · 1/1/0 (377) | 82s · NO FINDINGS | 5.9k / 4.6k | 1-catch ceiling holds at high; C3 empty |

ds-pro medium is the wave's find: 6/6 canonical, 0 noise, n=2 — same clean profile as kimi-k3
high at a different vendor (ensemble diversity value). Caveat: pro-max July row had 1 noise on
its second commit; n=2, promotion still needs more runs. qwen3.7-max effort ladder confirmed
flat (low=medium=high ≈ 1 catch): cheap silent voice, never a workhorse; its C3 zero-yield run
is uninformative for ensemble use (silence ≠ clean pass).

## 14. Tail wave: ds-flash medium, mimo-v2.5 low/medium, k2.7-code effort probe (2026-08-13, dioqktn)

| cell | C1 (59) | C3 (17) | think tok | note |
|------|---------|---------|-----------|------|
| deepseek-v4-flash medium | 431s · 3/3/0 (710, 724, 550) | 463s · 3/~2-3/0-1 (646 P1, gu:40; rb:650 borderline vs 661) | 53.7k / 54.5k | flash's usable rung; heavy thinker, 7-8 min |
| mimo-v2.5 low | 18s · 6 findings: 4 catches (508, 75, 835, 466) / 2 noise | NO FINDINGS | 0.4k / 3.1k | fast scattershot; C3 silence uninformative |
| mimo-v2.5 medium | 118s · 4/4/0 (75, 377, 466, 835) | 45s · 5 findings: ~1-2 weak catches (646-weak, 668-borderline) / 3 noise | 8.2k / 2.0k | clean on Py C1, noisy on C3 — language-dependent |
| kimi-k2.7-code --effort low | 909s · 6 catches (710, 724, 377, 33, 75, 466) / 1 noise (534-vs-293) | — | 43.7k | **knob ignored**: think size = default (42.6k); wall even longer. No cheap rung exists. |

Notes: ds-flash medium caught the C3 P1 security defect (646, --always-approve on live repo) that
qwen/mimo missed or soft-pedaled. mimo-v2.5 medium's C1 run is deceptively clean — its C3 run and
low's C1 noise show the model is not reliably quiet. k2.7-code effort ladder confirmed dead
through oc (like luna): the cell is take-it-or-leave-it at ~42-44k thinking, 7-15 min.

## 15. Promotion-gate extension wave (2026-08-13, dioqktn)

Gate: ≥3 commits, ≥2 languages, n≥4. M1 = fabcae4 (43 defects).

| cell | C2 (29) | M1 (43) | C1 repeat (59) | verdict |
|------|---------|---------|----------------|---------|
| ds-pro medium | ~1000s · 1 finding, **0 canon / 1 hallucination** (claims NSImage unimported; it is imported, overlay_app.py:47) · 48.2k think | 816s · 2/2/0 (cx:129, lua:697) · 61k | 838s · 2/2/0 (710, 550) · 59k | **fails C2 domain** — soft glm-like blindness on Lua/PyObjC; walls drifted 6→14-17 min |
| ds-pro low | 219s · 2/2/0 (py:123, lua:183) · 11.4k | 303s · 3/3/0 (cx:129, ll:148, cb:1510) · 21.7k | — | **passes gate**: n=4, 4 commits, 2 langs, zero noise, 2-5 min |
| ds-flash medium | curl exit 16 (HTTP/2 framing) at 622s, HTTP 000, no answer — transport, inconclusive, needs rerun | ~388s · 2/2/0 (cx:129, lua:697) · 43.6k | — | n=3, still no C2 reading |
| kimi-k3 medium | 132s · **4/4/0** (py:788, lua:183, py:123, lua:115) · 4.7k | — | 531s · 4/4/0 (710, 724, 377, 25) · 22.2k | **passes gate**: n=3 commits incl. C2, zero noise |

ds-pro medium's C2 failure mirrors glm-5.2's C2 collapse in soft form: full thinking budget spent,
zero canonical yield, one confident hallucination. C2 Lua+PyObjC is now 2-for-2 at exposing
vendor-specific domain failures — keep it as a mandatory gate commit forever.

## 16. glm-5.2 C2 collapse hunt — ablation (2026-08-13, dioqktn)

| probe | wall | compl tok | result |
|-------|------|-----------|--------|
| Lua files only (9.5k chars) | 5s | 866 | answers: 3 findings, 1 canon (lua:111 P1) + 1 weak-183 + 1 test-side noise |
| overlay_app.py only (27k chars) | 25s | 4 815 | answers: 1/1/0 (py:999) |
| full C2 + forced-thinking preamble | 127s | 21 324 | thinks properly (85k chars reasoning), then finish_reason=stop with **empty content** — answer never materializes |
| full C2 at effort max | — | 0 | CLI rc=64: opencode-go vocabulary is low|medium|high; max unreachable (and known broken: 32.7k own ceiling) |

Conclusion: the collapse trigger is the file COMBINATION, not either language alone — both halves
answer fine separately in seconds. Forcing thought via prompt breaks the collapse but hits glm's
other pathology (thinks, then emits nothing). Viable workaround for a production glm cell:
split the diff per file (or per language) and run N cheap sub-reviews — the split runs cost
5-25s each. This is a bench-side code feature, not a measurement gap.

## 17. Second-chance wave — symmetric gate for retirement (2026-08-13, dioqktn)

Principle change (owner): a cell may be RETIRED only by the same gate that promotes one
(>=3 commits, >=2 languages, n>=3); exceptions are mechanics (vendor removal, HTTP block,
CLI vocabulary) and explicit owner closures.

| cell | C1 (59) | C2 (29) | C3 (17) | M1 (43) | verdict |
|------|---------|---------|---------|---------|---------|
| mimo-v2.5 medium | 4/4/0 (§14) | 265s · 1 sophisticated hallucination (show() lambda that does not exist; leans on hide()'s real "Must return None" comment, overlay_app.py:933) | r2: 0/1 noise | NO FINDINGS (85s, 7.5k think) | **fairly retired**: n=5, one good run, blind/noisy/hallucinating elsewhere |
| mimo-v2.5 low | 4/2 (§14) | NO FINDINGS | silent (§14) | 5 findings · 0-1 weak / 4-5 noise (hedge-y non-defects) | **fairly retired**: n=4 |
| mimo-v2.5-pro | r2: 104s · 1/1/1 (522) | 0/1 + ~2/4 (§ earlier) | — | 76s · 0-1 weak/1-2 noise | **fairly retired**: n=5, noise every round but one |
| minimax-m2.7 low | 23s · **~6/1** (75, 377, 466, 710, 232, 244) · 1.4k tok | 88s · 1 weak (106/111-family) / 1 noise (PyObjC pseudo-claim) | — | — | n=2, **gate incomplete** — C1 jackpot at 23s; needs C3+M1 |
| minimax-m2.5 low | 19s · ~4/3 (75, 531, 499, 244) | — | — | — | n=1, gate incomplete |
| glm-5.1 high | 63s · 1/1/0 (710) | 41s · **1/1/0 (788) — NO COLLAPSE** | — | — | n=2, gate incomplete; 5.2's C2 collapse is generation-specific |
| glm-5 high | 67s · 1/1/1 (835; KeyError-claim noise) | — | — | — | n=1, gate incomplete |
| ds-flash medium | (§14: 3/3/0) | r2: **530s · 2/2/0** (999, 123) · 67k think | (§14: ~3/0-1) | (§15: 2/2/0) | **passes gate**: n=4, 4 commits, 2 langs |
| ds-flash low | — | — | — | 66s · 1/1/0 (129) | reserve coverage extended, n=5 |

Wave notes: minimax "--effort low" behaved (1-6k completion tokens — no silent fallback to a fat
tier). Both PyObjC "return None" claims (mimo med C2, mmm27 C2) verified false by reading the
commit; the mimo one cites real code as evidence for a nonexistent lambda — the most dangerous
noise shape seen in the whole campaign.

## 18. Gate-completion wave — final gate closures (2026-08-13, dioqktn)

| cell | C3 (17) | M1 (43) | closure |
|------|---------|---------|---------|
| minimax-m2.7 low | 19s · ~1-1.5 weak (gu:28) / 3-4 noise | 27s · 1/2 (cb:1494) | gate closed n=4: ~9 catches/~8 noise total; C1-only jackpot (6/1 @ 23s), scattershot elsewhere. Not tier; verifier-backed lottery voice at best. |
| minimax-m2.5 low | 574s (!) · 0-1 weak / 2-3 noise | — | gate closed n=3 (C1 4/3, C2 0-1/4-5, C3 noise): **fairly retired** — noisy every round |
| glm-5.1 high | 35s · 1/3 (661) | 34s · 1/1/0 (cx:129) | gate closed n=4: 4 catches/3 noise, 1 catch/run ceiling. Thin; qwen37max-class but noisier. Reserve at best. |
| glm-5 high | 19s · **3/3/0** (661, gu:18, gu:28) | — | gate closed n=3 (C1 1/1/1, C2 2/5 @ 4s spray, C3 3/3/0): mixed scattershot — fast, real catches, C2-noisy. Not tier; curiosity: gen-5 survives C2 (no collapse), 5.1 thin-clean, 5.2 collapses. |

Campaign measurement program COMPLETE at symmetric-gate standard: every non-mechanically-blocked
catalog model now has >=3 commits / >=2 languages or an explicit owner closure (hy3, k2.5/k2.6,
qwen-plus, grok-4.5, mimo-v2-pro/omni, qwen3.8-max xhigh gateway-cut).

## 19. Final tail wave — the last unfairly-open cells (2026-08-13, dioqktn)

Cells whose prior closure violated the symmetric gate (n=1-2, or blocked pre-opt-in):

| cell | result | think tok | gate state after |
|------|--------|-----------|------------------|
| ds-pro high C2 | 606s · 2/1/1 — 123 ✓ + **hallucination**: claims KB_BUNDLE_ID must be com.apple.AssistiveControl; the app's real CFBundleIdentifier IS com.apple.inputmethod.AssistiveControl (verified via Info.plist) — model confused the launchd Label with the bundle id | 48.4k | closed n=3 (C1 2/1/1 Jul, C2 2/1/1, C3 3/3/0): noise 2 of 3 rounds, out |
| ds-pro high C3 | 389s · 3/3/0 (40, 46, 661) | 37.0k | ^ |
| ds-pro max C3 | ~420s · **3/3/0** (646 P1, 18, 662) | 32.3k | closed n=3 (C1 5/5/0, C2 2/1/1, C3 3/3/0): 9 catches/1 noise total — strongest ds-pro rung, but C2 noise stands |
| kimi-k3 max C3 | 521s · 2/2/0 (18, 662) | 12.0k | closed n=3 (C1 5/5/0, C2 2/1/1, C3 2/2/0): one noise round; dominated by high (same yield floor, cheaper, 5/5 clean rounds) |
| qwen3.8-max medium C3 | **93s · 5/4/1** (661, 646 P1, 18, 55; noise: hard-coded grok binary claim) | 4.8k | n=2 — medium SURVIVES the post-opt-in gateway (xhigh dies at ~440s) |
| qwen3.8-max medium C2 | 272s · **1/1/0** (999 P1) | 15.9k | **gate closed n=3** (C1 2/2/0, C2 1/1/0, C3 5/4/1): 7 canon/1 noise, 2 langs — promoted with a scope caveat: the model is blind on >=35k-token inputs (143fc2f control), small/mid diffs only |
| ds-flash max C3 | 356s · 1/1/0 (646 P1) | 43.5k | closed n=3 (C1 2/2/0, C2 2/2/0, C3 1/1/0): 5/5/0 total, perfectly quiet — but dominated by flash medium (same wall band, more catches) |

ds-pro family pattern now confirmed at three rungs: every thinking-heavy rung (medium 48k, high 48k,
max 33-58k) produces exactly one confident C2 hallucination; only low (11k think) stays clean there.
The hallucinations share a shape: a real nearby artifact (launchd label, hide()'s comment) cited as
evidence for a wrong claim.

## 20. Diff-splitting rescue wave (2026-08-13, dioqktn)

Big commit 143fc2f (69.5k prompt, 44 defects) split at file boundaries into 4 chunks of 43-68KB
chars (~10-17k tokens), qwen3.8-max medium per chunk; plus glm-5.2 max (raw) on the C2 Lua-only
half:

| probe | wall | think tok | result |
|-------|------|-----------|--------|
| q38med chunk A | 756s | 13.0k | 2 findings: **970 ✓** (agy ARG_MAX) + 1 noise (reserved-name shadow claim, off-canon) |
| q38med chunk B | 228s | 13.3k | 2 findings: **85 ✓** (fail_safe ignores gemini pin) + 1 noise (verdict-note claim) |
| q38med chunk C | 534s | **16384 exactly** | reasoning hit an internal 16,384 cap, deliberation leaked into content, ends "NO FINDINGS" — blind + m3-style content pollution |
| q38med chunk D | 106s | 6.1k | NO FINDINGS (misses test_geminib:109 in its chunk) |
| glm-5.2 max, C2 Lua half | 123s | ~12.9k ct | ANSWERS: 1/1/0 (**115 ✓**, dropped enabled persistence) + 1 test-side noise |

Readings:
1. Splitting cures qwen3.8-max's size blindness: whole bundle = blind at every budget; chunks =
   2 canonical catches union. Thin and pricey though (106-756s per chunk), and chunk C exposes a
   new hazard: an internal 16,384 reasoning cap with content pollution past it.
2. glm-5.2 max is NOT mechanically dead on small inputs (its 32.7k ceiling only kills runs whose
   thinking exceeds it) — but glm-5.2 high catches the same defect on the same half in 5s.
   Dominated in-family; the glm lane is high + splitting.
3. Splitting does not cure noise (glm-5.2 off remains a noise fountain on split halves — §16).

## 21. kimi-k2.7-code effort knob — exhaustive closure (2026-08-13, dioqktn)

Owner asked for certainty (precedent: a wrongly-spelled knob once faked absence). Every known
form was tried, reasoning judged by usage.completion_tokens_details.reasoning_tokens on C3:

| form | asked | got |
|------|-------|-----|
| reasoning_effort: none / low (CLI ladder + direct) | off / low | 23-44k, unchanged |
| chat_template_kwargs: {enable_thinking: false} | off | rejected upstream |
| assistant prefill "</think>" (kimi-k3's off trick) | off | full thinking anyway |
| thinking_budget: 2048 | 2k | 14,308 (day variance, not the budget) |
| reasoning: {max_tokens: 2048} | 2k | 26,101 (full thinking) |

Vendor documentation agrees: K2.7-Code "does not support non-thinking mode", thinking always on
at full strength, reasoning_effort unsupported (unlike kimi-k3, documented low/high/max, default
max — note "medium" is undocumented there yet measurably distinct through the gateway).
The cell is take-it-or-leave-it by construction. CLOSED.

## 22. Wave 1 of the tier-fitting campaign (2026-08-13, dioqktn)

Purpose: widen the range on the three cells that decide T0 and T2 membership.

| cell | commit | wall | reasoning tok | score |
|------|--------|------|---------------|-------|
| qwen3.8-max low | C3 (17) | 47s | 2 496 | **3/3/0** (646 P1, 661 ARG_MAX, 18 bare-429) — best T0 run of the campaign |
| qwen3.8-max low | C2 (29) | 154s | 4 096 | **FORMAT failure**: content holds raw deliberation prose, no findings emitted |
| qwen3.8-max low | M1 (43) | 134s | 4 096 | NO FINDINGS (yield statistic) |
| glm-5 high | M1 (43) | 87s | n/a | **1/1/0** (cx:129 codexb remove path traversal, P1) |
| glm-5 high | M2 (32, ~30k prompt) | 168s | n/a | **FORMAT failure**: deliberation in content, no parseable findings |
| kimi-k2.7-code | M1 (43) | **1324s (22 min)** | n/a | **EMPTY answer** — 22 minutes, no content at all |
| kimi-k2.7-code | C1 repeat (59) | 907s | 15 729 | 4 findings · 2 canonical (710, claudebd:78) / 2 noise (seal-ref claims, off-canon) |

Readings:
1. **k2.7-code loses T2.** Its wall on a mid-size commit is 22 min AND the answer is empty; the
   C1 repeat needed 15 min and, unlike July's 5/5/0, carried 2 noise. Median wall over 8 rounds is
   now ~900s. It is a T3 cell, and an unreliable one — the "highest yield of the campaign" claim
   rests on its early runs only.
2. **FORMAT pollution is not minimax-only.** qwen3.8-max low (C2) and glm-5 high (M2) both emitted
   deliberation into `content` with zero parseable findings. Both are cheap-thinking cells at
   4k/none reasoning tokens; the failure appears when the prompt is harder than the budget.
   This is the single most common failure mode of the cheap band — it needs the parser guard.
3. qwen3.8-max low is a genuine T0 candidate on Python/bash diffs (3 canonical in 47s) but is
   0-for-2 outside them (C2 format failure, M1 silence). A domain-gated voice, not a workhorse.

## 23. Wave 2 — M1 mid-size points for the T0/T1 roster (2026-08-13, dioqktn)

Three sequential probes on M1 `fabcae4` (64KB prompt, ~19-20k tokens, 43 adjudicated defects),
filling each candidate's missing mid-size reading.

| cell | wall | reasoning tok | score (wall s · findings/canonical/noise) |
|---|---|---|---|
| kimi-k3 medium | 343s | 10,900 | 2 findings · **1/1** — cx:129 traversal P1 canon; "nudge_daemon_rescan never defined" is noise (defined at claudeb:1417 in the commit) |
| gpt-5.6-luna (chat path) | 25s | n/a | **2/2/0** — cx:129 traversal P1 + llm-limits:148 frozen-cause masking P2 (verbatim canon match) |
| qwen3.8-max medium | 168s | 9,124 | **1/1/0** — cx:129 traversal |

Verdicts moved:
- kimi-k3 medium takes its FIRST noise in 4 commits (was zero across C1/C2/C3). Medians over
  n=4: catches 3, FP 0, wall ~4 min — still T1, but the "zero noisy claims ever" epithet is dead.
- luna confirms mid-size sight (no size blindness at ~20k) and stays the best catch-per-second
  cell of the campaign.
- qwen3.8-max medium sees mid-size below its 35k wall but yields thin there.

## 24. Luna effort knob: root cause found, /responses revives the ladder (2026-08-13)

Web+source research (sst/opencode gateway code) found the mechanism behind the flat oc-luna
rungs: the Zen gateway's chat-completions -> Responses conversion (`toOpenaiRequest()`,
`zen/util/provider/openai.ts`) HARDCODES `reasoning: {effort: "medium"}` and the intermediate
`CommonRequest` type carries no effort field — an incoming `reasoning_effort` is dropped before
it reaches OpenAI. `parseOpenAiVariant()` reads the flag only as a billing label. So every
"rung" we measured through `/chat/completions` was one cell: effort=medium, not reasoning-off.

But `/zen/go/v1/responses` exists as a separate route, and for openai->openai the body converter
is identity — `reasoning: {effort}` passes through. Verified live on C3 `36dcb4f` (all HTTP 200):

| form | wall | reasoning tok | score |
|---|---|---|---|
| chat/completions, no flag (= hardcoded medium) | 19s | not exposed | 1/1/0 (662) |
| /responses `reasoning:{effort:"low"}` | 10s | 516 | 1/1/0 (662) |
| /responses `reasoning:{effort:"high"}` | 86s | 7,791 | **2/2/0** (646 P1 + 662) |

The ladder is real: high caught the C3 P1 security defect (646, --always-approve on live repo)
that the medium cell never caught on C3. The Responses schema also exposes reasoning_tokens,
which the chat path never did for this model. Gate wave for "oc-luna resp-high" (C2, M1, plus an
xhigh probe) launched next.

## 25. Luna /responses gate wave — PROMOTED (2026-08-13, dioqktn)

| probe | wall | reasoning tok | score |
|---|---|---|---|
| xhigh C3 | 195s | 20,718 | 2/2/0 (46 P1 unit-mismatch family + 662) — but MISSED 646 P1 that high caught; 2.3x the wall for the same count. Top rung, out of scope per owner rule; not pursued |
| high C2 | 186s | 19,164 | **2/2/0** (lua:183 manual-override overwrite P2, py:123 full-bounds clamping P2) — both languages hit |
| high M1 | 194s | 18,602 | **4/4/0** (cx:129 traversal, claudeb:1487/1510 lock family, claudeb:2511/2521 freeze bypass, llm-limits:1119 marker self-clear) |

Gate CLOSED for `gpt-5.6-luna high via /responses`: n=3, 3 commits (C2/C3/M1), 2 languages,
zero noise across all three. Medians: catches 2, FP 0, wall 186s (~3 min). Doubles the
chat-medium cell's yield (which scored 1/1/0, 1/1/0, 2/2/0 on the same commits) at a wall that
still fits T1 with room. Reasoning band 7.8-20.7k tokens; output otherwise tiny.

Production consequence: `opencode-go` only speaks `/chat/completions`; using this cell in a leg
requires a `/responses` request path for GPT models (client feature, at retune, own commit).

## 26. Verifier decontamination — corpus rebuilt without the silent verifier cut (2026-08-14)

The bench pipeline ran a verifier (kimi-k3, later ds-flash) inside every recorded run until
2026-08-11; findings it rejected never reached adjudication or the corpus, so every "clean"
looking cell was clean partly by censorship. All 3,266 dropped findings were recovered from
`verified-<rater>.jsonl` (`kept:false` rows preserve the full claim), deduplicated to 3,265
claims, and re-adjudicated by Opus (medium) against each commit's diff and canonical defect
list — the weak-model verifier judged nothing this time.

Numbers: 71 auto-confirmed by canonical file+line match; 2,779 Opus-judged in 26 worker batches
(153 confirmed / 2,626 false positive / 0 uncertain); 342 claims still unjudged (belong to
bench-only runs with no corpus row — they cannot move any table number; workers hit the
account's session wall); 73 permanently lost (pruned merged workspaces + one deleted scratchpad
repo, 18 of which touched corpus rows of one 20260730 run).

Applied to the corpus (never mutating `reviews.jsonl` — corrected dataset is derived on the
fly): 3 new canonical defects; the largest cell deltas were oc-kimik3 +26 confirmed / +24 FP
across 29 rows (misses -17) and oc-grok45-low +10 / +6. Incumbent rows gained only small miss
increments from the new canonical defects. Same-run duplicates collapse by canonical defect id
or (commit,file,line-bucket), so a rater re-asserting one defect five times still scores once.

The rebuilt per-cell table (medians over corrected rows, coverage = pooled
confirmed/(confirmed+misses), tier by median wall vs 3/6/10/20 min) is generated by the
scratchpad scripts `restore-extract.py` → `build-batches.py` → `rebuild-stats.py` →
`make-table.py`; headline corrected cells:

| cell | n runs / commits | med catch | med FP | med wall | coverage |
|---|---|---|---|---|---|
| oc-kimik3 off (leg cell, repeats merged) | 58 / 28 | 1.0 | 1.5 | 17s | 35.4% |
| oc-kimik3 low | 3 / 3 | 2 | 1 | 118s | 54.5% |
| oc-kimik3 medium | 4 / 4 | 3.0 | 0.0 | 873s | 75.0% |
| oc-glm52 high | 9 / 6 | 1 | 0 | 87s | 61.5% |
| oc-glm52 low | 4 / 2 | 1.0 | 0.0 | 183s | 66.7% |
| oc-dsv4flash off | 12 / 4 | 2.5 | 4.5 | 10s | 34.7% (long walls live in unadjudicated bench runs, not here) |
| sol-low / sol-medium / sol-high / sol-max | 21/17 · 27/20 · 28/24 · 14/12 | 1 · 1 · 2.0 · 3.5 | 0 | 73s · 168s · 364s · 1127s | 12.0 · 15.8 · 29.3 · 39.5% |
| opus-low-skill / medium-skill / high-skill | 12/8 · 14/8 · 14/8 | 1.0 · 2.0 · 2.0 | 1.0 · 1.5 · 1.0 | 87s · 429s · 571s | 11.3 · 19.1 · 27.0% |
| agy-flash37-medium-skill / agy-pro-high-skill | 28/7 · 36/30 | 0.0 · 0.0 | 0.0 · 0.0 | 89s · 101s | 25.8 · 9.0% |

Key reversal vs the verifier-era picture: the OpenCode FP columns are real now (kimik3 off
carries 1.5 median FP the verifier used to hide), and kimik3's catch side was ALSO being
censored — the verifier threw away real defects (26 of its restored claims were confirmed).
`gpt-5.6-luna` has no corpus rows at all (raw-path probes only, §22-25) — its cells stay
hand-scored and verifier-free by construction.
