# Review contract

Reviews exist for one moment: the commit. `git commit` on an unreviewed delta is the
only trigger that opens a review round, and the framed block `record --no-corpus`
prints is the only review output Egor reads. This page is the policy; code bends to
it, and anything the old implementation did beyond it is deleted, not preserved.
Enforcement lives in `hooks/review-flow-gate.sh` (claude-setup) and `bin/review-bench`;
prose never re-states what those already say at the moment they fire.

## The cycle

1. **One coin per commit.** The first blocked `git commit` opens a per-session cycle
   and arms exactly one panel. The panel's triaged receipt buys the cycle's ticket.
   The ticket is content-anchored: fixes, tree drift, and co-tenant commits moving
   HEAD cannot take it away. The commit that carries the reviewed content spends it.
2. **The P1 escalation is the only second coin.** A review confirming ≥ 2 P1 earns
   exactly one further enforced round; at ≥ 5 P1 the block message leads with
   simplify/cut/redesign of the weak component instead of re-review. A third enforced
   block is impossible by construction.
3. **Everything past the ticket is advice.** Drift beyond the reviewed snapshot is
   reported at the next commit as a recommendation line — never a block, never a
   printed launch command.

## Launches

`review-bench review --worktree` runs only when the commit gate armed the current
cycle (stages `armed1`/`armed2`), or under `REVIEW_ASKED=1` — the transcript-verified
token for a review Egor asked for by name. There is no other door: no mid-work
panels, no self-chained rounds, no "one more look". A gate block that contradicts an
already-bought ticket is a bug to report to Egor, not a reason to run another panel.

## Reports

Report blocks are framed: the block word centered in `=` at 50 characters, a bare
50-character rule closing it. The review block names its panel on the first line and
counts every completed cell, zero-finding cells included. Delivery to Egor verbatim
is hook-enforced (nudge + delivery gate, both keyed on the worded header). Cell names
render through one derivation over the launchable pool — a component appears only
where two cells would otherwise collide; machine specs in commands never change.

## The corpus is a different instrument

The benchmark corpus records durable commits judged by two sealed judges. A
commit-point (worktree) review never enters it: plain `record` refuses, reporting
goes through `--no-corpus`, and `--bench` — rejected outside worktree runs — is the
one opt-in that stores a run's verdicts for benchmark work Egor asked for by name.
Judges exist only for corpus rows; on a routine review the fixer triages alone.

## Escapes and fuses

`REVIEW_GATE_OK=1` passes a commit only on Egor's explicit skip, transcript-verified.
The pending-report Stop hook still nags an untriaged run to its report, with the
bounded ask allowance as the fuse. Severity tallies ride the receipt
(`confirmed_by_severity`), and the gate prices the next round on them — scoped to the
member repository in merged runs.

## Deleted by this contract

Fix-delta tier tolerance in `suggest` (the ticket owns post-review work), launch
commands inside advisory lines, judge invocations outside the corpus, and every
review path not named on this page.
