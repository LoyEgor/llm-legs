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

   A worker a chat spawned IS that chat: `worker-run` stamps the launching
   `CLAUDE_CODE_SESSION_ID` into `<run-dir>/launcher` at start and the run's own
   files into `<run-dir>/files` after every attempt, and the hook sweeps the runs
   stamped with its session on every tool call, journalling their paths under it
   (invariant row `am`). Nothing here depends on the chat reading a report:
   ownership taken off printed output belongs to whoever printed it. The gate
   reads the same records, so a run that finishes between the chat's last tool
   call and its commit is still priced as that chat's work. Codex and Gemini
   workers keep no per-file transcript, so their record carries an `UNKNOWN:`
   line instead of paths and their files stay outside coverage — a named
   limitation of those vendors, not an accident of the plumbing. The gate names
   those runs once each in its commit notice — with the record's own reason, and
   alongside the runs that recorded editor calls only, the runs still going, and
   the runs whose supervisor is gone (abandoned, never "still running") — and the
   session that delegated to them owns the gap.
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
| `review-bench debt` | the gate (and through it the model) | what this repository owes a review, and whose |
| commit-time notify (once) | the model | reminded before an unreviewed commit; decides |
| `escalation-verdict` fork | the model; Egor when present | fix / simplify / re-review after a bad round |
| watchdog `timed-out` | Egor (loud) | a review hung past its cap |

A line nobody acts on is deleted, not kept for safety.

## Debt

One concept, and it is content: a path is **in debt** when its working-tree
content differs from what the newest artifact holding it recorded. Two artifacts
hold paths — a triaged run's `reviewed{path: blob-sha}` snapshot, and a
**waiver**. Debt is commit-agnostic: committing neither creates nor settles it,
because nothing here reads git history. A path no artifact ever held is in debt
whole while it exists — a run that never read it has no content to compare, so a
repo-wide review cannot blanket files born after it. A held path that is gone is
in debt; a deletion the run READ is settled by it (the snapshot records that path
against the empty string).

`review-bench debt --repo <top> [--session <sid>] [--paths <p>...] [--list]`
prints exactly one line and exits 0:

- `none` — nothing asked about is in debt.
- `debt <n> mine|other [locked]` — `n` paths in debt (restricted to `--paths`
  when given). `mine` when `<sid>` is among the debt's authors.
- `timed-out <run-id>` — the session's most recent run was killed by the watchdog
  and no later triaged run of its own has spoken since.

`--list` prints the debt paths themselves, one per line, instead of the verdict.
With no `--paths` the question is the repository's, and its universe is what the
artifacts hold plus what the journals name — never every file in the tree.

**Authors.** Uncommitted debt is attributed through `<git-dir>/claude-commit-journal`;
debt a commit carried away is attributed through `<git-dir>/claude-review-debt`,
which the gate appends to at the commit that lands it, in the same
`session TAB epoch TAB path` NUL-separated records, pruning on every write the
entries of paths no longer in debt.

**Waivers.** `review-bench waive --repo <top> --reason "..." [--paths <p>...]`
records that this work is going unreviewed and why, into a per-repository store
beside the receipts (`<state-dir>/waivers/`): the debt paths, their current blob
shas, the reason, the session, the epoch. A waiver covers exactly those shas —
the next edit is debt again. An empty reason is refused.

**The lock IS the mechanical second round.** When the newest run holding a debt
path came back with `SECOND_REVIEW_P1S` confirmed P1s or `SECOND_REVIEW_FINDINGS`
confirmed findings, the debt reads `locked`: `waive` refuses it and the commit
notice withholds the waiver option, saying why. The only way out is the
follow-up review over the full original scope plus the fixes — there is no other
mechanically-forced round.

## The gate (claude-setup `hooks/review-flow-gate.sh`)

- `verdict <repo> [session]` — the statusline's single voice (invariant row ah).
  Asks `debt` about the whole repository, with no paths: debt outlives the commit
  that landed it. Prints one line: `off` (no debt, nothing it can read),
  `bright rev ● <n>` (this chat's own debt), `dim rev ● <n>` (a co-tenant's), or
  `loud rev timeout`. `loud` exists for the watchdog alone — red in the
  statusline always means a hung review, nothing else.
- Commit hook — **notify-once, never a wall**. A `git commit` whose pending paths
  carry debt exits 2 once, listing those paths and both ways to answer them — the
  review command and the `waive` command, the latter withheld with its reason
  when the debt is `locked` — and stamps a marker; the retry passes, consumes the
  marker and writes this chat's name into the debt journal. A new state re-arms
  the notice. A commit with nothing in debt passes silently. Foreign dirty or
  untracked paths are never priced, never mentioned, never block.
- `escalation-verdict <p1> <total>` — the one voice for round outcomes (invariant
  row af). Below thresholds: exits 1, prints nothing. At `SECOND_REVIEW_P1S=2`
  P1s or `SECOND_REVIEW_FINDINGS=8` findings: exits 0 and prints the fork — fix
  and commit / simplify or redesign the weak block / re-review, and a re-review
  must rerun the full original scope plus fixes, never the fixes alone (a fresh
  pass over old code finds new defects; a fix-only pass only certifies the
  fixes). At `WEAK_LINK_P1S=5` P1s the fork leads with simplify/cut/redesign
  first, review after. The model judges; Egor decides when he is present. When
  the fork rides a delivered report, the report hook's context turns advisory
  into demand: the model's next message must OPEN with its written analysis —
  the weak block, why the findings cluster there, the option chosen and why —
  because choosing silently leaves Egor unable to judge whether the block
  should exist at all.

## Watchdog

Per (model, effort): cap = the longest recorded duration for that pair + 3
minutes, floor 15 minutes. On breach the panel is killed, the run is marked
`timed_out` in its record, and the statusline goes loud until a later triaged
run covers the session's paths. A breached cap grows by one grace on the next
run so a wrong kill corrects itself — but the growth is a probe with three
strikes, not a right: only runs killed since the pair's last completion count,
and the third in a row drops the kill record, returning the pair to the cap
its completions earn and opening a fresh episode — the next kill probes again,
so a pair with no completion on file is re-probed every third run instead of
being pinned at the floor for ever. Left unbounded, one genuinely dead cell
walked every panel's wall from 15 toward 30 minutes in a night; episodes bound
it to one grace per run on average. A completion clears the kill record, so a
recovered pair is judged on its completions alone.

Under the duration cap sits the stall watch, earned per pair the same way:
activity is any byte on the cell's pipes or growth of its declared log files,
and the cap is the longest silent gap the pair's COMPLETIONS ever showed + 2
minutes, floor 4 minutes — armed only where those gaps stay under half the
pair's runtimes, the evidence it streams at all, so a buffered side and a pair
with no gap history can never be stall-killed. A kill takes the whole process
group (the hang lives in the launcher's descendant), records `stalled_s` on the
cell, is retried once inside the same run, and reads as `stalled` in the
report. A stall kill is not a duration breach: it never raises the pair's
duration cap, while the stall cap it was killed at grows by one grace on the
next run so a wrong kill corrects itself — unbounded, unlike the duration
cap's probe, because a stall kill costs the run one in-cell retry rather than
its wall, and the duration cap still bounds the cell either way.

Every kill writes down which budget fired: `killed` (`watchdog` or `stall`) and
`killed_cap_s` on the cell's meta row, beside `max_quiet_ms`. A cell that ended
itself — a side's own client timeout — records neither, and that absence is how
the report tells the two apart. The agy side delegates its cap to geminib
(`--print-timeout`), so our budget fires there as the client's own nonzero
exit: a failure at or past the cap is labelled `watchdog` at the source. Both
keys are additive: a run recorded before them renders unchanged, a stall kill
marked only by `stalled_s` included; a legacy watchdog kill (exit 124) shows
the `timeout_s` cap it ran under, while a legacy agy kill keeps its bare
duration — its wording is also the client's own timeout, and a row must not
claim a cap that may never have operated.

## Report rows for cells that died

`errored:` and `timeout:` carry each dead cell's own numbers — its duration, then
in parentheses the budget that killed it (`watchdog cap 17 min`,
`stalled, quiet 6 min`), a short reason tag on `errored:` entries (a timeout IS
its row's reason), and, at three or more consecutive failing runs,
`3 fails in a row`. The streak is counted over the runs that held
that cell; a panel it was never part of is passed over rather than read as a
recovery. `wall gated by:` appears whenever the slowest cell of the run is not a
completed one — the hang held every later cell back and appears in neither the
wall nor `slowest completed`. `cells:` is ordered by usefulness: confirmed
findings first, then raw findings, then name — and once a triage holds
verdicts each cell reads confirmed/found, so the order is visible.

## Launches and reports

`REVIEW_ASKED=1` marks a review Egor asked for by name; `REVIEW_GATE_OK=1` marks
his explicit skip — both on the model's honour (2026-08-10). The framed block from
`record --no-corpus` is the only review output Egor reads, and the report hook
prints it: one copy, from review-bench's own rendering, costing no tokens. A model
that retypes it can mistype it, and a gate comparing the retyping against the
reference then buys a second identical block — which is what happened. What the
model owes after the block is judgment the block cannot hold, never its contents
restated. The corpus rules (sealed judges, `--bench` opt-in) are unchanged.

## Non-goals — deleted by this contract

Cross-session policing of any kind; pricing the shared tree (cycles, tickets,
receipts, vouches, drift budgets, content coverage of commit forms); blocking a
commit for longer than one notice; repo-history coverage answers (`same_commit`
and kin stay dead); tier advisories (the chat picks the tier itself). Reviewing
another chat's leftovers is not a gate concern — it is an explicit ask from Egor,
run as an ordinary scoped review by the session he asked.
