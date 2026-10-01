# Debt health follow-up: fresh evidence supersedes the September 30 triage

Status: open

For the owner in `share/doctor-ledger.json`, routing recording-side work to Debt hardening handoff,
Harness Doctor, Review-bench improvements phase 4, and the round owners named below.
Run: llm-health-20261001T020632Z-3671. No ADD-DIR worktrees were authorized.

Purpose: `bin/llm-doctor:2193` (`debt_health`) exposes work that recording failed to capture or
that a store dropped before review; `docs/shared-invariants.md` rows cq/cw define the contract.
The detector reads real gaps correctly. Their existence is not a reason to suppress them.
This is an evidence and ownership handoff, not a new procedural rule; the recording hook and
worker snapshot machinery are the mechanisms that must preserve the missing evidence.

## Decisions in packet order

| Problem | Verdict | Evidence and next action |
| --- | --- | --- |
| H1 | handoff | Four visible gaps include two new September 30 runs for Updater doctor round `20260930T002018Z-a9fe8ce`. Both worker meta files retain `review_round`; lost ROUND propagation does not explain these. Inspect fixer rows in review-bench and let the round owner close or rerun. The earlier claim of no recurrence since September 27 is obsolete. |
| H2 | ruled-out | Open gaps still name the 500-dirty-path bound and actual capped-path changes on October 1. The cap is recording its known coverage gap. Project owner must address research output or the ledger owner decide dismissal; do not raise the cap. |
| H3 | handoff | Same September 25 sparse-clone call, `toolu_019LXUXzq7R1DrdhbN49RLPN`. The proposed created-by-call explanation needs a claude-setup fixture for a sparse clone inside a subshell. Current hook behavior is unconfirmed here. |
| H4 | ruled-out | Exactly the same two probe IDs, `toolu_probe_timing` and `toolu_perf_big`. The September 30 handoff identifies their live-store timing probes. Propose owner dismissal of those incidents only; no live store was edited. |
| H5 | handoff | Raw gap groups contain twelve calls, not one initialization: two on September 25 and ten on September 28 UTC, ending at epoch 1790635543. The doctor combines the first detail with the latest timestamp. Hook owner must investigate those later calls too; creation cannot explain the whole row. |
| debt-gap:run-fold:snapshots unreadable | handoff | Run `claudeb-1790808567-98231-124d` has exit 0, a 1,080,670-byte before listing and head-before, but neither after file. The failure is real, its cause ambiguous; see below. Ledger H11 now preserves it, keyed to this why only (other run-fold whys stay new). |
| H6 | handoff | Six distinct stopped calls from `/Users/egorloy`, latest epoch 1790653046. The prior read-only wait explanation proves neither the other five calls nor a current fix. Hook owner must distinguish timeout from teardown and verify applicability of claude-setup 48bfc77. |
| H7 | handoff | Same stopped-call incident `toolu_01GVuJcSDXUxgTUmy7TqNhZD`. TERM 102 seconds after start is prior evidence; a 60-second timeout and lstat cost are hypotheses, not confirmed causes. Measure a large-tree fixture in claude-setup. |
| debt-loss:run-fold-skip | handoff | Fresh window contains 83 co-tenant path rows AND 49 committed-since path rows. These are not 132 independent runs. Review-bench must decide loss semantics and separate reasons before any selective dismissal; B5 records the missing distinction. |

## Missing after snapshot

Read-only inspection of the worker cache found `dirty-before-shas`, `head-before`, `exit_code` 0,
and an empty `files-note`; `dirty-after-shas` and `head-after` are absent. The retained error log
contains no matching snapshot/hash/fatal diagnostic. `bin/worker-run` `persist_run_files` attempts
`snapshot_workdir` after each vendor attempt. `snapshot_changed_paths` correctly refuses absent
after files, and `fold_family_anchors` correctly emits the gap instead of claiming nothing changed.

`workdir_dirty_shas` can fail repository/path enumeration; hash failures have a per-path fallback.
An interrupted capture or a path-shape rejection cannot be established retrospectively. A current
snapshot of the shared project would attribute later edits to this run and cannot repair its
historical evidence. Handoff to the worker recording owner: reproduce capture failure in a fixture
and retain its actual error at the existing snapshot boundary. Do not retry writes on the live tree.
No clear local code defect was established and no fallback was deleted speculatively.

## Evidence limits and remaining work

The fresh full `bin/llm-doctor --dry-run --json` document had status `problems`, no collector error,
and all nine packet causes. `--block debt` is unsupported; health is in the full document.
`review-anchors gaps --days 7 --json` supplied the raw groups; losses were grouped read-only from
`~/.cache/claude/review-debt/losses.jsonl` using that document's `as_of_s` minus 86400.
The loss count fell from 40 at launch to 39 in the fresh read as the window advanced.
No additional quiet rows were in the packet.

B6 records two presentation/evidence limits: representative details can hide later distinct calls,
and the title says 24 hours for seven-day open gaps. Those are detector-owner work, not permission
to change the judge in this run. Current creation-hook behavior, the six stopped calls' individual
causes, large-tree hook timing, and whether every skipped path retains another owner's anchor were
not confirmed. The older September 30 handoff remains open for its unresolved ownership actions;
this follow-up supersedes its H1, H5, H6 and co-tenant-only scope assumptions.
