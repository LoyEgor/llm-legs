# Review contract

The unit of accountability is the session — one chat. The truth about "was this
reviewed" lives on disk, never in the model's memory and never in the shared
worktree's diff: a shared checkout is a noisy channel written by many chats, and
every past attempt to judge it (cycles, tickets, receipts, content coverage)
produced unpayable debts and review loops. This page is the policy; code bends to
it, and anything an implementation does beyond it is deleted, not preserved.

Reviews are never a wall. A missing review is made visible — in the statusline and
once at commit time — and the model or Egor decides. There is no class of problem
called "a commit without review": a review can always run after the commit. The
intolerable failure is a commit landing unreviewed with nobody noticing; the cure
is visibility, not blocking.

## Truth sources

1. **Commit journal** — `<git-dir>/claude-commit-journal`, written by the
   PostToolUse hook (`commit-journal.sh`, claude-setup). Entry format:
   `<session-id>\t<epoch>\t<repo-relative-path>`, NUL-terminated, deduped per
   (session, path). Entries with no TAB are legacy (unowned, no timestamp) and are
   tolerated by every reader. `commit-report.sh` clears entries whose paths are no
   longer dirty.
2. **Run records** — `review-bench` stores per run: `session`, `scope`, `started`/
   `finished`, per-panel `(model, effort, duration_ms)`, triage state, and
   `reviewed{path: blob-sha}` — every path of the sealed snapshot commit, read out
   of that commit and never off the checkout under it, the anchor for drift. A path
   the snapshot deleted is keyed to the empty string: the panel read that deletion,
   and no blob can stand for it.

## Signals — one consumer each

| signal | consumer | what it changes |
|---|---|---|
| framed `record` block in chat | Egor | sees the review happened and what it found |
| statusline review segment | Egor | spot-checks that disk truth matches the chat's claims |
| `review-bench session-review` | the gate (and through it the model) | whether this session's paths are covered |
| commit-time notify (once) | the model | reminded before an unreviewed commit; decides |
| `escalation-verdict` fork | the model; Egor when present | fix / simplify / re-review after a bad round |
| watchdog `timed-out` | Egor (loud) | a review hung past its cap |

A line nobody acts on is deleted, not kept for safety.

## Coverage

`review-bench session-review --repo <top> --session <sid> [--paths <p>...]`
prints exactly one line and exits 0:

- `none` — no triaged run by this session covers the paths.
- `covered <run-id> <drift-pct>` — a triaged run by this session covers every
  path and drift is ≤ 25%.
- `stale <run-id> <drift-pct>` — a covering run exists but drift exceeds 25%.
- `timed-out <run-id>` — the session's most recent run was killed by the watchdog
  and no later triaged run covers.

A run covers a path when the run's `session` matches, the path is inside the
run's `scope` (directory-prefix containment; empty scope = repo-wide), and the
run is triaged. Drift is content, not history: per covered path, diff lines
between the `reviewed` blob and the current file (binaries count 0), summed and
divided by the reviewed line total. A path deleted since a run that never held it
is 100% — there is no content left to price the change in, and every line count
over an absent file is zero. **Staleness IS the mechanical second round**:
fixes that outgrow 25% of the reviewed size return the paths to unreviewed, and
the next review runs the full original scope plus the fixes — there is no other
mechanically-forced round.

## The gate (claude-setup `hooks/review-flow-gate.sh`)

- `verdict <repo> [session]` — the statusline's single voice (invariant row ah).
  Reads the session's journal entries still dirty, asks `session-review`, prints
  one line: `off` (nothing pending), `dim rev ok`, `dim rev none <n>`,
  `dim rev stale <pct>%`, or `loud rev timeout`. `loud` exists for the watchdog
  alone — red in the statusline always means a hung review, nothing else.
- Commit hook — **notify-once, never a wall**. A `git commit` while the session's
  pending paths are `none`/`stale` exits 2 once with the state spelled out and
  stamps a marker; the retry passes and consumes the marker. A new unreviewed
  state re-arms the notice. `covered` commits pass silently. Foreign dirty or
  untracked paths are never priced, never mentioned, never block.
- `escalation-verdict <p1> <total>` — the one voice for round outcomes (invariant
  row af). Below thresholds: exits 1, prints nothing. At `SECOND_REVIEW_P1S=2`
  P1s or `SECOND_REVIEW_FINDINGS=8` findings: exits 0 and prints the fork — fix
  and commit / simplify or redesign the weak block / re-review, and a re-review
  must rerun the full original scope plus fixes, never the fixes alone (a fresh
  pass over old code finds new defects; a fix-only pass only certifies the
  fixes). At `WEAK_LINK_P1S=5` P1s the fork leads with simplify/cut/redesign
  first, review after. The model judges; Egor decides when he is present.

## Watchdog

Per (model, effort): cap = the longest recorded duration for that pair + 3
minutes, floor 15 minutes. On breach the panel is killed, the run is marked
`timed_out` in its record, and the statusline goes loud until a later triaged
run covers the session's paths.

## Launches and reports

`REVIEW_ASKED=1` marks a review Egor asked for by name; `REVIEW_GATE_OK=1` marks
his explicit skip — both on the model's honour (2026-08-10). The framed block
from `record --no-corpus` is the only review output Egor reads, delivered
verbatim; the corpus rules (sealed judges, `--bench` opt-in) are unchanged.

## Non-goals — deleted by this contract

Cross-session policing of any kind; pricing the shared tree (cycles, tickets,
receipts, vouches, drift budgets, content coverage of commit forms); blocking a
commit for longer than one notice; repo-history coverage answers (`same_commit`
and kin stay dead); tier advisories (the chat picks the tier itself). Reviewing
another chat's leftovers is not a gate concern — it is an explicit ask from Egor,
run as an ordinary scoped review by the session he asked.
