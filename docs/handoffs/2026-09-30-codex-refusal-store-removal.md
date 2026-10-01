# Codex model refusal store: remove it whole

Status: open

Found 2026-09-30 while cutting codex model resolution down to one rule: a codex account is offered
only a model in its OWN catalog (`codexb models --account <n> --own`), never a pool-wide guess.

## State
- Done:
  - `bin/codexb` lost its one-day window and `cache_epoch`, and `--account` now requires `--own`.
  - `share/worker-model.sh` merged `worker_model_codex_account_slug` into `worker_model_codex_slug`.
  - `bin/worker-run` lost `PICKED_SLUG`.
- Still standing: the refusal store and its pool-wide refusal. They are redundant under the
  own-catalog rule, because the one live "refusal" (`gpt-6.1-sol`, refused 01:36 UTC and served at
  09:13 UTC the same day on locomthebest) was rollout lag, not a lasting refusal.
- A refused model is still recorded and still shapes routing until the pieces below go.

## To remove, together
- review-bench `share/rbench/launch.py`: the `catalog.codex_refuse` call (around lines 1012-1014).
- review-bench `share/rbench/catalog.py`: `CODEX_MODEL_REFUSED`, `codex_refuse`.
- review-bench `tests/fixtures/fake-codexb.sh`: the refuse branch, and the `test_review_bench.sh` block
  near line 6722 that pins it.
- llm-legs `bin/codexb`: `refuse-model`, `refused_slugs`.
- llm-legs `share/worker-model.sh`: `worker_model_codex_refuse`.
- llm-legs `bin/worker-run`: the refusal recording in `supervise_codex`.
- Their tests, and the `cv` row in `docs/shared-invariants.md`.

## Seen by the LLM doctor (2026-10-01, ledger R15)
The store's pool-wide skip is the most likely reason `codexb models --family sol` printed nothing at
02:11 UTC on 2026-09-30, about 35 minutes after the rollout-lag refusal: both sol-high cells of
round `20260930T021101Z-8810740` crashed on `no codex model for cell sol`. Night fixer
`llm-reviewers-20261001T020642Z-32c1` made such a cell end `pool empty` instead of crashing
(review-bench `launch.py` `codex_account_serves`). The removal above is still open: it touches
worker-run and codexb as well, which is outside a reviewers fixer's scope.

## Keep
The longest-list heuristic in `codexb`. review-bench still resolves `-m` machine-wide through
`codex_model_id(word)`, which has no account to ask.

## Done when
- `grep -rn 'codex_refuse\|refuse-model\|refused_slugs\|worker_model_codex_refuse'` over both
  repositories finds nothing.
- `bash tests/run-all` is green in both repositories.
- A live `worker-run` on MODEL sol still serves the newest sol slug on an account that lists it, and
  an account without it (work4 today) is skipped before launch.
