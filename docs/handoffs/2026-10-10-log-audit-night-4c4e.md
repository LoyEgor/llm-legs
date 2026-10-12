# Log audit leftovers, nights 4c4e and e2f7

Status: open — To: next night (Harness Doctor owner); each item is ledger row `log_audit:<id>`, its note the verdict.

1. **Judge, owner's call**: `test_daily_cost` sums suite wall seconds, which night load inflates 2-5x; pricing it by
   the journal's CPU would stop fixers sharding against load. Row `speed-doctor-metrics-misleading`.
2. **Doctrine gap, owner's call**: `share/worker-policy.md` calls Gemini a full implementation worker; Egor says Flash is
   Light only. Inert while the menu keeps Gemini workers and reviewers off. Row `gemini-flash-used-after-rejection`.
3. **Haiku readers (ffdf3b0d), first night**: 3 of e2f7's 15 findings were already fixed in the quoted transcripts
   (one quote is the fix report itself) and none left a harness bug; CHUNK_TASK says to skip those.
4. Ruled out as harness bugs, dismissal proposed:
   - model conduct, no component: `spend-menu-spec-churn`, `foreground-call-hangs-25min`, `biased-bench-answer-key`,
     `walls-worker-burned-accounts-high-effort`, `orchestrator-invented-speed-targets`,
     `metric-explanations-not-followable`, `one-worker-241-images`, `wait-for-vendor-reset-instead-of-available-members`.
   - by design: `parallel-fixers-duplicate-work` (deduped at landing), `bench-default-cap-zero-findings` (new pairs get
     1800 s; `--uncapped` exists).
   - cause gone: `sleep-poll-loops-waiting` (relays retired), `classifier-output-noise`.
   - logo-vectorizer-bench lane: `slot-throttle-foreground-sleeps`, `judge-calibration-oversized`,
     `lane-idle-between-rounds`, `dev-green-new-loss-class-on-unseen-files`, `thin-seam-repair-artefacts`.
   - weather: `suites-timeout-under-night-load`, `launch-into-exhausted-limit`.
