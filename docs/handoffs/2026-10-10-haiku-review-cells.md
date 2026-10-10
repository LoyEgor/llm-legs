# Haiku review cells: chunked, judged by Opus; the legacy round is a production trial

Status: open — To: night 20261010T031219Z-4c4e

From chat «Updater doctor», on Egor's word 2026-10-10: Haiku reviews only chunked and only with the
Opus check. Changed on review-bench main while this night was paused:
- 16dcb55: the legacy lens staffs `haiku-high` (was `sonnet-high`); fit has staffed it since b7b7dd2.
- 1fbc22d: any launch staffing a Haiku cell chunks itself (`cli.chunk_launch`), `--chunk` or not.
- 22c0acd: the speed lens staffs `haiku-high x2` (doctor-fix's speed lens, once its launch door is fixed).
- bugs stays `opus-high x2`.
- 7fd71ca: a chunked cell left running alone starts passes for the panel cap times its waves. Before, the one-pass cap was the whole cell's budget, and it cut this night's Haiku debt cells at 11-18 of 41-44 chunks (failed as `chunks unread`, judge skipped). Rounds launched before it may rerun on it.

Chunked Haiku bench, 2026-10-10, key hits against the baseline:

| lens | Haiku chunked | baseline |
|---|---|---|
| speed S1 | 7/17 | Opus 3.75/17 |
| speed S2 | 4/6 | Opus 4.5/6 |
| legacy rb | 4/9, extras 24/24 | Sonnet chunked 3–6/9 at 3.7x the cost |
| bugs B1 | 2/9, 3 FP | Opus 5/9 |
| bugs B2 | 2/7 | Opus 6/7 |

The Opus check is the blind judge every tier review runs (`judge.py`, `JUDGE_MODEL = "opus"`); the
lens `verify:` key is the agy-only verifier, off everywhere under `verifier-off`, and is not it. So:
- launch fit and legacy rounds as the skill spells them, never with `--only` or anything else that
  skips the judge; a round whose `meta.judge.state` is not `ran` hands no Haiku finding to a fixer
  until a judge rules on it;
- the night report carries one Haiku-trial line per fit, legacy and speed round: panel findings, judge-confirmed, confirmed per
  cell (haiku against sol, Flash, grok), and how many of its fixes were reverted or dropped.

Done when: the night report carries those lines; Updater doctor reads them to keep or revert 16dcb55 and 22c0acd.
