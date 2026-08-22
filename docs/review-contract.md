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
   (invariant row `am`). A worker that edited through the SHELL lists no file at
   all, so `worker-run` records that run's own claudeb session ids in
   `<run-dir>/worker-session` beside the listing: those ids journaled every such
   edit under themselves, and no chat in the repository answers for them. The gate
   folds the commit-journal entries they own into the launching chat's pending set,
   and `debt --session <launcher>` counts those paths as the launcher's — the
   launcher joins the record's authors and the worker id stays beside it. Nothing
   here depends on the chat reading a report: ownership taken off printed output
   belongs to whoever printed it. The gate reads the same records, so a run that
   finishes between the chat's last tool call and its commit is still priced as
   that chat's work. Codex and Gemini
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
| `review:` row in the commit frame | Egor | sees, at the commit itself, whether what just landed is unreviewed |
| statusline review segment | Egor | spot-checks that disk truth matches the chat's claims |
| `review-bench debt` | the gate (and through it the model) | what this repository owes a review, and whose |
| commit-time notify (once) | the model | reminded before an unreviewed commit; decides |
| `escalation-verdict` fork | the model; Egor when present | fix / simplify / re-review after a bad round |
| watchdog `timed-out` | the report flow and `review-bench doctor` (untriaged) | a review hung past its cap |

A line nobody acts on is deleted, not kept for safety.

## Debt

One concept, and it is content: a path is **in debt** when its working-tree
content differs from what the newest artifact holding it recorded. Three artifacts
hold paths — a triaged run's `reviewed{path: blob-sha}` snapshot, a **waiver**, and
the fix bytes a **closed round's own done receipt** covers. Debt is commit-agnostic:
committing neither creates nor settles it, because nothing here reads git history.
A path no artifact ever held is in debt
whole while it exists — a run that never read it has no content to compare, so a
repo-wide review cannot blanket files born after it. A held path that is gone is
in debt; a deletion the run READ is settled by it (the snapshot records that path
against the empty string). A killed run holds no path at all: triaging it settles
the chat's round — the `timed-out` verdict goes quiet and the report the Stop gate
waits for is discharged — but its snapshot is never read as an artifact, because
the panel was sealed with the whole scope and reached only part of it, and counting
it would settle the paths its dead cells never read for every chat at once.

`review-bench debt --repo <top> [--session <sid>] [--paths <p>...] [--list|--split]`
prints exactly one line and exits 0:

- `none` — nothing asked about is in debt.
- `debt <n> mine|other|unknown [<owned>] [locked]` — `n` paths in debt (restricted
  to `--paths` when given). The owner word is the third field and the only one a
  reader switches on: `mine` when `<sid>` authored at least one debt path or a run
  of its own holds one, `other` when it owns none, `unknown` when no `--session` was
  given at all — nobody asked whose this is, so nothing here knows, and `other`
  would be an ownership no reader computed. `<owned>` stands after the word only
  where the chat owns SOME but not all of them: the word keeps its meaning for every
  reader switching on it, and the count beside it is the new fact.
- `timed-out <run-id>` — the session's most recent run was killed by the watchdog
  and nothing of its own has spoken since. A later triaged run of that session takes
  the answer back, and so does the killed run's OWN triage: a kill whose findings
  were judged left nothing to wait on.

`--split`, which answers `split <own> <foreign> <orphaned>`, is the same question in
DIFF LINES for a machine: per path, the lines between the content its covering artifact recorded and
the content standing there now — counted by the differ the review target header
prints — added up over the paths `<sid>` answers for, the paths another chat does,
and the paths NO journal entry names and no run record claims, which belong to
nobody and must not be read as the asking chat's. The counts are cached under
`<state dir>/debt-lines.json`, keyed by the two contents that decide each one — a
recorded blob this store cannot read keyed as the absence it is compared as, and a
path this repository's attributes take out of line counting (`-diff`) never cached
at all, since both belong to a checkout while the file is shared by all of them.

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

**The review that scopes itself.** `review-bench review --debt --tier Tn` is the
one review nobody hands a scope, and the one the commit gate prints. Its scope is
every path `debt` names, WIDENED with every surviving path of any locked round
standing over that debt: a lock is discharged only by a run that holds all of
them, and a path sitting at exactly the sha the locked round recorded is by
definition not in debt — so a debt-only scope could never answer the round it
exists for. Per path, the comparison base is the content the newest artifact
holding it recorded; where no artifact holds it, or its recorded blob is no longer
readable, the path is dropped from the base and the panel sees the file whole.
Those bases live in no commit of the repository — one path was last read three
commits ago, its neighbour is still uncommitted — so the left end is BUILT: a
parentless synthetic commit carrying the current tree with each scope path's blob
replaced, sealed as the parent of the working-tree snapshot. The panel reads one
diff, from what was last answered for to what is there now, and the commits in
between are invisible, which is the point — committing neither creates debt nor
settles it, so the shape the work was committed in is not what is under review.

The run records shas for EVERY path of that scope, including paths whose diff is
empty: a locked round's survivor that no run HOLDS discharges no lock. It marks
the repository reviewed the way an unscoped worktree run does — this is the
repository's whole open question, not a corner of it — and its scope never reaches
the round key, so a second `--debt` run over the same work is that scope's second
round and not a scope of its own. It takes no target: a commitish, `--range`,
`--worktree` and `--paths` are each refused, because choosing the scope is the
choice this mode removes. With several `--repo` it behaves like any merged panel —
one debt scope per member, one receipt per member.

**A closed round's own fixes.** A `fixes --done` receipt recorded for a round the
gate's `escalation-verdict` closed — neither `SECOND_REVIEW_P1S` nor
`SECOND_REVIEW_FINDINGS` reached in any repository of the run — also covers the bytes
that round's own fixing pass wrote, at the shas they stand at when it is recorded.
Nothing will ever read those bytes: no second pass is owed, so left in debt they are a
waiver every later chat has to know to write over work the receipt already answers for.
Five guards, evaluated per repository, and each one leaves the path in debt instead. The
bytes must be journaled between the run's SEAL instant — the one already on record,
which a rerun by sha inherits, and never a launch stamp standing in for it — and the
receipt. Every journal entry on that path inside that window must be the fixing session's
own, the workers it launched folded in as they are everywhere else, with an undatable
legacy entry, an entry stamped past the window's end, or a co-tenant's unswept worker run
disqualifying it: a parallel edit stays debt whether or not this chat wrote the file too.
An entry OLDER than the seal disqualifies nothing, whoever left it — the panel read those
bytes. The path must be one the run's snapshot holds, because a fix that touched a file no
cell was shown is new work. A pass that fixed nothing wrote no fix bytes to cover. And a
round recorded `blocked`, a round the gate escalated, and a round the watchdog killed
cover nothing at all — their fixes ride the round they owe. Like a waiver's, the coverage
is exactly those shas: the next edit is debt again, and a re-adjudication that leaves the
receipt answering another triage takes the coverage back with it.

**The lock IS the mechanical second round.** When the newest run holding a debt
path came back with `SECOND_REVIEW_P1S` confirmed P1s, the debt reads `locked`:
`waive` refuses it and the commit notice withholds the waiver option, saying why.
The only way out is the follow-up review over the full original scope plus the
fixes, which is what `review --debt` computes with no path named by hand — there
is no other mechanically-forced round. A round that earned its second review on
the tally alone (`SECOND_REVIEW_FINDINGS` confirmed findings
under the P1 count) locks nothing: the fork says the round is owed, and `waive`
may still answer it on the model's own judgment, which a waiver records with its
reason.

## The gate (claude-setup `hooks/review-flow-gate.sh`)

- `verdict <repo> [session]` — the statusline's single voice (invariant row ah).
  Asks `debt --split` about the whole repository, with no paths: debt outlives the
  commit that landed it. The unit is DIFF LINES, and debt owned by nobody counts
  with the foreign side. Prints one line: `off` (no debt, nothing it can read),
  `bright rev <own>`, `dim rev <foreign>`, or `split rev <own>/<foreign>` when both
  stand — rendered as one segment, own bright and foreign dim. Nothing here is red,
  and a watchdog kill is not shown at all: a killed run settles nothing, so its
  paths are already in the numbers.
- Commit hook — **notify-once, never a wall**. A `git commit` whose pending paths
  carry debt exits 2 once, listing those paths and both ways to answer them — the
  `review --debt` command, which carries no path list because the mode reads the
  debt itself and widens to whatever a locked round still owes, and the `waive`
  command over exactly those paths, the latter withheld with its reason when the
  debt is `locked` — and stamps a marker; the retry passes, consumes the
  marker and writes this chat's name into the debt journal. A new state re-arms
  the notice. A commit with nothing in debt passes silently. A commit target the
  command NAMES but neither hook can resolve — a token carrying an unexpanded
  shell variable, a path that is no directory, or more than one directory — is
  priced over every journal home, the call's own cwd and every directory the
  command itself named, one notice per repository, never over that cwd alone
  (invariant row ao). Foreign dirty or untracked paths are never priced, never
  mentioned, never block.
- `escalation-verdict <p1> <total>` — the one voice for round outcomes (invariant
  row af). Below thresholds: exits 1, prints nothing. Above either of the two —
  `SECOND_REVIEW_P1S=3` P1s or `SECOND_REVIEW_FINDINGS=8` findings — it exits 0
  and prints the same three options: fix and commit / simplify, cut or redesign
  the weak block / re-review, and a re-review must rerun the full original scope
  plus fixes, never the fixes alone (a fresh pass over old code finds new
  defects; a fix-only pass only certifies the fixes), named as the same `--debt`
  command the commit notice prints (invariant row at). What differs is the line
  above them: at the P1 count the second review is mandatory and the waiver is
  withheld until it runs; on the tally alone it is owed by default and `waive`
  is still open. The model judges; Egor decides when he is present. When
  the fork rides a delivered report, the report hook's context turns advisory
  into demand: the model's next message must OPEN with its written analysis —
  the weak block, why the findings cluster there, the option chosen and why —
  because choosing silently leaves Egor unable to judge whether the block
  should exist at all.

## Watchdog

Per (model, effort): cap = the longest recorded duration for that pair + 3
minutes, floor 15 minutes. On breach the panel is killed, the run is marked
`timed_out` in its record, which the report flow and `review-bench doctor` read;
the statusline shows nothing for it, since a killed run settles nothing and its
paths stand in the debt like any others. A breached cap grows by one grace on the next
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
prints it: one copy, from review-bench's own rendering, costing no tokens. What the
model owes after the block is judgment the block cannot hold, never its contents
restated. The corpus rules (sealed judges, `--bench` opt-in) are unchanged.

**Two frame words, two delivered states** (invariant `as`). `review` — the fixes
are done, or there was nothing to fix. `review · NOT FINISHED` — and ONLY this —
is a round whose fix status is `blocked`: the pass stopped at the P1 threshold
and fixed nothing, and the block carries the fork (fix as it stands / rewrite the
weak block / cut the scope) as Egor's decision, not the fixer's. A round whose
fixing pass has not answered wears the PLAIN word and says so in its `fixes:`
row, at any age, and no hook ever delivers it — a loud word derived from "no
fixes recorded" reports failure while the fixes are still landing, and promoting
pending rounds to a deliverable state floods the Stop gate with every
pre-receipt run the chat ever held. The finished report follows on its own, from
the Stop net's `pending-delivery` source, one per state per round.

## Doctor

`review-bench doctor` is pull-only diagnostics over the stores this page describes, and never a
gate: it exits 0 whatever it finds, because a review system with an anomaly in it is still a
review system. It names six classes — `untriaged`, `undelivered`, `stuck_fixes`, `eternal_lock`,
`orphan_debt`, `kill_asymmetry` — each a silence rather than an error: a record some mechanism
above should have moved on and did not. Their ages live in one dict in the tool and are spelled
nowhere else, here included. The run-level classes look back only so far, because nobody triages
last month's panel and a count that only grows says the same thing every time it is read; the two
about the tree as it stands — a lock over live paths, debt in front of the reader — are unbounded.

The periodic snapshot (`--snapshot`, its launchd collector and the menubar row that reads it) is a
registered experiment, `review-doctor-collector` in `EXPERIMENTS.json`; the command itself is not.

## Non-goals — deleted by this contract

Cross-session policing of any kind; pricing the shared tree (cycles, tickets,
receipts, vouches, drift budgets, content coverage of commit forms); blocking a
commit for longer than one notice; repo-history coverage answers (`same_commit`
and kin stay dead); tier advisories (the chat picks the tier itself). Reviewing
another chat's leftovers is not a gate concern — it is an explicit ask from Egor,
run as an ordinary scoped review by the session he asked.
