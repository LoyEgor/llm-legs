# Haiku review cells: chunked, judged by Opus; the legacy round is a production trial

Status: open — To: night 20261010T031219Z-4c4e

From chat «Updater doctor», on Egor's word 2026-10-10: Haiku reviews only chunked and only with the
Opus check. Changed on review-bench main while this night was paused:
- 16dcb55: the legacy lens staffs `haiku-high` (was `sonnet-high`); fit has staffed it since b7b7dd2.
- 1fbc22d: any launch staffing a Haiku cell chunks itself (`cli.chunk_launch`), `--chunk` or not.

The Opus check is the blind judge every tier review runs (`judge.py`, `JUDGE_MODEL = "opus"`); the
lens `verify:` key is the agy-only verifier, off everywhere under `verifier-off`, and is not it. So:
- launch fit and legacy rounds as the skill spells them, never with `--only` or anything else that
  skips the judge; a round whose `meta.judge.state` is not `ran` hands no Haiku finding to a fixer
  until a judge rules on it;
- the night report carries one legacy-trial line: panel findings, judge-confirmed, confirmed per
  cell (haiku against sol, Flash, grok), and how many legacy fixes were reverted or dropped.

Done when: the night report carries that line; Updater doctor reads it to keep or revert 16dcb55.
