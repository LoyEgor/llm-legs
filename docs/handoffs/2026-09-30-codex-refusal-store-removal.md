# Codex model refusal store: remove it whole

Status: done 2026-10-04 (ledger R15 fixed-pending)

A codex account is offered only a model in its OWN catalog (`codexb models --account <n> --own`), so
the refusal store and its pool-wide skip were redundant: the one live "refusal" (`gpt-6.1-sol`,
2026-09-30) was rollout lag.

## Settled 2026-10-04 (night sweep 20261004T003925Z-4646)

Removed together: llm-legs `bin/codexb` `refuse-model`/`refused_slugs` (now usage exit 2),
`share/worker-model.sh` `worker_model_codex_refuse`, the recording in `bin/worker-run`
`supervise_codex`, row `cv`; review-bench `catalog.py` `CODEX_MODEL_REFUSED`/`codex_refuse`, the
`launch.py` call, the fixture's refuse branch. The unsupported-model retry gives up instead of rerunning
the refused slug (`test_worker_run_outcomes.sh`, red without the guard). Open: the live sol check waits
for a sol launch.
