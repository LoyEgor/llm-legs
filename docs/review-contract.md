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

1. **Commit journal** — `<journal-dir>/claude-commit-journal`, written by the
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
   that chat's work. A run whose transcript cannot name every mutating target
   carries an `UNKNOWN:` line instead of paths and its files stay outside
   coverage. The gate names
   those runs once each in its commit notice — with the record's own reason, and
   alongside the runs that recorded editor calls only, the runs still going, and
   the runs whose supervisor is gone (abandoned, never "still running") — and the
   session that delegated to them owns the gap.
   **One ledger per git FAMILY.** `<journal-dir>` is the COMMON git dir —
   `git rev-parse --path-format=absolute --git-common-dir`, resolved by
   `store.journal_dir` in llm-legs and `rj_journal_dir` in claude-setup — so a main
   checkout and every linked worktree of it read and write ONE commit journal and ONE
   debt journal. Per-worktree git dirs held a ledger each, and coverage has always been
   family-keyed: a waiver from the main checkout cleared 33 paths while 12 stayed owed
   in a worktree of the same project, and the statusline and `review-bench debt`
   answered from different files (2026-08-26). A worktree's own ledger from before this
   is folded into the family's — records appended unless already there, then the file
   unlinked — by whoever asks for the directory next, reader or writer alike. Every
   `debt --list` and `debt --split` answer prints `ledger: <journal-dir>/claude-review-debt`
   on STDERR, so the file behind an answer is nameable while stdout stays exactly what
   the commit gate parses.
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
| `review-bench fork --choice --why` record | the gates, then Egor as one line | fix / simplify / cut / redesign; no fixing pass past the fix band before it is on disk |
| watchdog `timed-out` | the report flow and `review-bench doctor` (untriaged) | a review hung past its cap |

A line nobody acts on is deleted, not kept for safety.

## Debt

One concept, and it is content: a path is **in debt** when its working-tree
content differs from what the newest artifact holding it recorded. Three artifacts
hold paths — a triaged run's `reviewed{path: blob-sha}` snapshot, a **waiver**, and
the fix bytes a **closed round's own done receipt** covers.
A path no artifact ever held is in debt
while it exists — a run that never read it has no content to compare, so a
repo-wide review cannot blanket files born after it — and it is PRICED by where its
unreviewed work stands: DIRTY in the working tree, against the content HEAD holds
(whole where HEAD holds no such path, since the edit is what it owes and not the
history under it); CLEAN, against the parent of the oldest commit reaching HEAD at or
after the earliest epoch the journals stamped for the path, less the width of the
post-commit hook that writes that stamp (`JOURNAL_STAMP_GRACE_S`), because with the
tree clean HEAD IS the unreviewed work rather than the base for it; and with no epoch
stamped or no commit under one, against HEAD, which owes no lines at all — nothing on
record then says which commits went unreviewed, and the path count is what still names
it. The same left side answers wherever a recorded blob is no longer readable. A path gone
from the working tree is nobody's debt at all (below); a deletion the run READ is settled
by it either way (the snapshot records that path against the empty string).

**The artifacts are the checkout FAMILY's.** Every artifact recorded against ANY
checkout of the repository — the main one and every worktree of it, present or
since removed, which is one resolved `git rev-parse --git-common-dir` — answers for
every checkout of it, and a merged panel's members are matched one at a time. The
paths are repository-relative on both sides, so they match 1:1. Read per checkout,
main compared files a worktree's panel had read against its own older run and
reported 11k ghost debt lines after the merge, one file of them 7453 (2026-08-23).

**Content, not the path it was read under.** A path whose current sha any family
artifact recorded is current, whatever path it read it under: a file that moved carries
its review with it, and a family holds one NAME per path at as many contents as it has
checkouts — a worktree on a feature branch and its main checkout each stand at their
own bytes, and priced against the newest artifact alone each re-opened the other the
moment either recorded a waiver, the whole cross-branch delta coming back as fresh debt
in both directions (2026-08-24). A path that IS in debt is still priced against the
newest artifact holding it.

**Three candidates are nobody's debt here.** One GONE from the working tree, whatever
HEAD still holds, since nothing is left for a review to read — priced whole against what
it used to hold, three deletions in one worktree stood as 1952 lines of debt no panel
could ever be shown (audit, 2026-08-26). One spelled under another checkout of the
family (`.claude/worktrees/<name>/…`), which is that checkout's own question — a removed
worktree leaves both in the journals for ever, with no command able to answer them. And
one whose base content IS the content standing there: the diff every price and every
panel is built from is empty, so `debt` counted it and a panel scoped to it would be
handed nothing — 131 of them across four checkouts, which is why the count never reached
zero even where every line had been answered. That last one is told by the two SHAS and
never by a line count, or a binary and a path this repository marks `-diff` would leave
review by being unreadable. All three drop silently out of `debt`, `--list`, `--split`
and the `--debt` scope.

**`.claude/review-debt-ignore` is the project's own answer, once.** A checkout may
commit this file to say which of its paths a review is not owed over — gitignore's
grammar (`!` negates, a trailing `/` means the directory's contents, a `/` anywhere else
anchors at the root, `*` stops at a separator and `**` crosses them), last matching line
winning. What it names is never priced, never scoped and never split, and `debt --list`
prints what it dropped — `ignored: N path(s) by .claude/review-debt-ignore` — on stderr, so an
ignore file is a visible decision and not a silently shrinking count, while `--list`'s stdout
stays one path per line for the flow gate that reads it that way. Read from the
checkout on every call, never memoized: it ships with the tree, and a reader holding
yesterday's copy prices what the project has since stopped reviewing. This repository
commits one line, `*.md`; claude-setup commits no such file, its instruction files being
the product. Whether a round holds its paths turns on ONE fact — a
triage receipt exists — and never on HOW its incomplete cells died. A rater error, a
watchdog kill, a stall kill, any kill condition added later: all of them leave the
same round, sealed with the whole scope and answered for by whoever judged what came
back. A kill that degraded coverage made two identical rounds settle differently for
no reason a reader could act on, and every new kill condition silently took paths
back out of every artifact. The kill markings stay as diagnostics — `debt`'s own
`timed-out` line, the report flow, `review-bench doctor` — and settle nothing on
their own. The receipt itself may only ever attest what was READ, which is the one
place a dead cell still costs coverage: where the diff was chunked and no cell of some
chunk came back, that chunk's paths are dropped from the run's snapshot and stay in
debt, while every path a chunk that did come back held is covered as always. Cause of
death is not asked there either — only whether anybody opened the content.

`review-bench debt --repo <top> [--session <sid>] [--paths <p>...] [--list|--split]`
prints exactly one line and exits 0:

- `none` — nothing asked about is in debt.
- `debt <n> [mine|other|unknown] [<owned>] [(+<f> foreign)]` — `n` paths in debt
  (restricted to `--paths` when given), always the whole count and never a share of
  it, since `n` is the field every reader prices the repository by. The owner word is
  the third field and the only one a reader switches on: `mine` when `<sid>` authored
  at least one debt path or a run of its own holds one, `other` when it owns none,
  `unknown` when no `--session` was
  given at all — nobody asked whose this is, so nothing here knows, and `other`
  would be an ownership no reader computed. With no `--session` and EVERY debt path
  recorded to some chat, the word is dropped entirely — `debt 2` — since
  `unknown` over debt whose owner is on record states the one thing the records
  contradict; a reader parsing positionally must therefore accept a line whose third
  field is not an ownership word. `<owned>` stands after the word only
  where the chat owns SOME but not all of them: the word keeps its meaning for every
  reader switching on it, and the count beside it is the new fact. `(+<f> foreign)`
  follows where a `--debt` review of `n` will leave another chat's debt out — the scope
  is the asking chat's own, and a reader who cannot see what it excluded reads it as the
  repository's whole open question. It is withheld where the owner word already says
  it — `other` IS the chat owning none of this debt, so `(+<n> foreign)` over all of it
  repeats the line's own third field — and with no `--session` there is no asking chat,
  nothing is left out, and no share rides the line at all. No state word ever follows it:
  what a round owes is the round's own question (`fork`), never the repository's count.
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

**Authors.** Uncommitted debt is attributed through `<journal-dir>/claude-commit-journal`;
debt a commit carried away is attributed through `<journal-dir>/claude-review-debt`,
which the gate appends to at the commit that lands it, in the same
`session TAB epoch TAB path` NUL-separated records, pruning on every write the
entries of paths no longer in debt.

**Ownership never guesses.** A chat answers for a path only through a record that
NAMES the path for it: its own journal entries still standing above the artifact
covering that path, or the file listing of a run it launched. Nothing is inferred from
a workdir, a window, a retired run's heir or the dirt a shared checkout gained while a
run went on — that dirt is evidence of CONTENT, never of authorship (invariant rows am
and ao), and a vendor worker that listed no files leaves nobody holding anything. A
debt-journal record standing AT OR BELOW its path's covering artifact is a settled
episode's leftover and answers for nothing; a path whose every record is spent that way
has no author, and the reader says so — `orphaned`, never the asking chat's. A wrong
`own` is worse than nobody's: read the other way round, one chat's statusline priced
three co-tenants' commits as its own debt (2026-08-25), and a listless run went on
taking every commit made in its checkout for three days after it ended (2026-08-24).

**Waivers.** `review-bench waive --repo <top> --reason "..." [--paths <p>...]`
records that this work is going unreviewed and why, into this checkout's own file
beside the receipts (`<state-dir>/waivers/`, read across the family like every
other artifact): the debt paths, their current blob
shas, the reason, the session, the epoch. A waiver covers exactly those shas —
the next edit is debt again — and the objects behind them are WRITTEN into the
repository as it is recorded, which a command may do and a render may not: a sha
whose blob is in no store reads back as an absence, and the next edit is priced
against the tree's own history instead of against the waiver — live, the whole file
(16251 lines of one test file, 2026-08-24). A done receipt's
coverage is recorded the same way. An empty reason is refused.

**The review that scopes itself.** `review-bench review --debt --tier Tn` is the
one review nobody hands a scope, and the one the commit gate prints. Its scope is
this chat's own debt plus the debt nobody owns — another chat's live work is a
moving target, and the round would answer for content its author never saw —
WIDENED with every surviving path of any round a recorded decision reopened: that
round's own receipt is not read at all, so its whole scope re-enters the diff at
whatever answered for those paths before it, and a path sitting at exactly the sha
that round recorded — which is where a decision that fixed nothing leaves every one
of them — is by definition not in debt, so a debt-only scope could never answer the
round it exists for. A second round re-reads the full scope of the round that owed it plus
the fixes, never the fixes alone (Egor, standing since the 11-round loop) — scoped
off the newest artifact instead, which is that very round, a live second round read
the 258 lines its own fixing pass had written and nothing else while the handoff
promised the whole of it (2026-08-22). A round the fix band closed owes nothing
and keeps its receipt, or every review would inherit its predecessor's scope
forever; so does a round whose own round budget is spent, since the second pass
over a scope owes no third. The reopening is looked for among every artifact standing
over the repository and not among the ones some path is in debt against: a round whose
decision fixed nothing leaves no path in debt at all, and read off the debt its
mandatory pass could never be scoped (2026-08-22). Per path, the comparison base is the content the newest artifact
holding it recorded; where no artifact holds it, or its recorded blob is no longer
readable, the base is the one the STATUSLINE prices that path against — HEAD while
the working tree is dirty, the parent of the oldest commit under the earliest
journal stamp while it is clean — so the panel reads exactly the lines the debt
count names. One helper answers both (`debt_base_blobs`). Only a path HEAD does not
hold is dropped from the base and seen whole, and only a reopened round's paths
carry an empty side of their own, because that pass is owed the full original scope
plus the fixes. Spelled twice, the two drifted: an 84-line edit reached the raters
as 11.9k lines of untouched code and twenty of the findings were about the old
lines (2026-08-24).
Those bases live in no commit of the repository — one path was last read three
commits ago, its neighbour is still uncommitted — so the left end is BUILT: a
parentless synthetic commit carrying the current tree with each scope path's blob
replaced, sealed as the parent of the working-tree snapshot. The panel reads one
diff, from what was last answered for to what is there now, and the commits in
between are invisible, which is the point — committing neither creates debt nor
settles it, so the shape the work was committed in is not what is under review.

The run records shas for EVERY path of that scope, including paths whose diff is
empty: a reopened round's survivor that no run HOLDS closes nothing. It marks
the repository reviewed the way an unscoped worktree run does — this is the
repository's whole open question, not a corner of it — and its scope never reaches
the round key, so a second `--debt` run over the same work is that scope's second
round and not a scope of its own. It takes no target: a commitish, `--range`,
`--worktree` and `--paths` are each refused, because choosing the scope is the
choice this mode removes.

Because nobody spells that scope, nobody sees its SIZE either, so the run prices it
before anything is sealed or launched and prints `scope: <n> file(s) · <m>
line(s)`. Above `DEBT_SCOPE_LINES_MAX` diff lines it launches nothing: it lists the
largest paths, counts the ones it did not list, and prints the same command plus
`--scope-lines <m>`, whose number must equal the one printed. A flag that merely
lifted the ceiling would be a bare override; a number that has to match is a size
somebody read, which is the waive pattern — a decision on record. Nothing is ever
narrowed by it: either the whole computed scope is reviewed or nothing runs.

And the panel is one per CHAT, not one per repository. Before a single-repository
round launches, the repositories this chat currently owes debt in are enumerated
from the flow gate's own per-call HEAD snapshots; if more than one owes and the
command's `--repo` set does not cover them all, nothing launches and the merged
command naming every one of them is printed instead. A round settles only what it
read, so the rest would stand unreviewed behind a panel that came back clean — and
paying for one panel and one triage instead of three is the reason the merged mode
exists. `--this-repo-only --reason '...'` is the way past it, the reason recorded
with the run the way a waiver's is. A `--reason` with no such decision behind it
costs a stderr warning and not the launch: it is kept on the run's meta as `reason`,
answering for nothing, since a refusal there spent a whole launch over a word the run
can simply carry. Every surface that hands a chat this command —
the commit notice, the settle ask, the adjudication handoff, the waiver's refusal —
prints that same merged form, or the gate would arrange the very split round the
tool refuses. What the scope left out is NAMED beside the target —
`skipped foreign: <n> path(s), <m> line(s) (chat <labels>) — include with --all` —
and `--all`, which only this mode accepts, reads it: a review that silently read
part of the debt reported a repository clean over files no rater ever opened.
Where nothing is left, the refusal
carries the same sentence rather than reading as a tree that owes nothing. With several `--repo` it behaves like any merged panel —
one debt scope per member, one receipt per member.

**The COMMIT closes the fixing pass.** A review was done and its fixes landed: those two
are ONE thing (Egor, 2026-08-25). The commit hook asks `review-bench fixes --cover --commit
<sha>` for every repository a Bash call landed a commit in, and every round of the committing
chat over that repository that is triaged, holds a confirmed finding, is not `blocked` and is
coverable — a round 1 inside the fix band or one whose decision named `fix`, and any round 2,
which closes its round 1 with it — is closed BY that commit and covers what it carried, at the shas
the commit itself holds — bounded, like every coverage, by the paths that round's own snapshot
holds. A round with NOTHING confirmed is closed by no commit: it has no fixing pass for one to be
the evidence of (`fix_status` already calls it done), and covered anyway it retired that commit's
own bytes as reviewed work no panel had read (audit, 2026-08-26). One commit may
close several rounds; a round is closed once, and a later commit over a path it already
answers for re-stamps that path rather than adding a second answer. The receipt keeps the
commits in `closed_by`, which nothing reads back — the coverage is in the shas — and which
is the only place a reader can see why a round nobody typed a receipt for is closed. There is no second
command to remember, which is the point: the debt-journal row the window below waits for is
stamped at COMMIT time, AFTER a receipt, so 51 of 71 done receipts in a three-week window
covered nothing at all and their own fix bytes read back as fresh debt (audit, 2026-08-26).
`fixes --done --fixed <N> --fp <M>` stays as the tally the report prints and gates coverage
no longer; both numbers default to the triage's own confirmed count.

**A closed round's own fixes, journaled.** A `fixes --done` receipt recorded for a coverable
round — the fix band, a decision naming `fix`, or a round 2 — also covers the bytes
that round's own fixing pass wrote, at the shas they stand at when it is recorded, for the
pass whose fixes are not committed yet.
Five guards, evaluated per repository, and each one leaves the path in debt instead. The
bytes must be journaled between the run's SEAL instant — the one already on record,
which a rerun by sha inherits, and never a launch stamp standing in for it — and the
receipt. Every journal entry on that path inside that window must be the fixing session's
own, the workers it launched folded in as they are everywhere else, with an undatable
legacy entry, an entry stamped past the window's end, or a co-tenant's unswept worker run
disqualifying it: a parallel edit stays debt whether or not this chat wrote the file too.
An entry OLDER than the seal disqualifies nothing, whoever left it — the panel read those
bytes. A codex or gemini worker has no Claude session, runs none of the journal hooks and
lists no files, so a pass delegated to one leaves NO entry either way; there its own run
record stands in — the launching chat, the repository, a listing that says it cannot be
complete, and the workdir dirt it gained inside the window. Where a co-tenant ran a blind
run over the same path too, nothing can tell the two apart and the path stays in debt. The path must be one the run's snapshot holds, because a fix that touched a file no
cell was shown is new work. A pass that fixed nothing wrote no fix bytes to cover. And a
round recorded `blocked` and a round whose decision reopened it cover nothing at all — their
fixes ride the round they owe. With one exception, which closes a hole and moves no dial:
a round 2 covers its fixes like any closed one, because nothing can reopen it — reopened
and last at once, it covered nothing and owed nothing, and its fix bytes could be answered by
no review that exists (audit, 2026-08-26). How the round's incomplete cells died is not asked here
either: a kill is a diagnostic, never a second-class round. Like a waiver's, the coverage
is exactly those shas: the next edit is debt again, and a re-adjudication that leaves the
receipt answering another triage takes the coverage back with it.

**The DECISION is the mechanical second round, and the only one there is.** A round
the fix band did not close owes one of the four words before anything is fixed, and
`fix` is the word that hands it back to the fixing pass the commit closes. The other
three run round 2 over the full original scope plus the fixes, which is what
`review --debt` computes with no path named by hand. Nothing else forces a round, and
nothing forgives one: `waive` answers for work no review is owed over, never for a
round that owes a decision.

## The gate (claude-setup `hooks/review-flow-gate.sh`)

- `verdict <repo> [session]` — the statusline's single voice (invariant row ah).
  Asks `debt --split` about the whole repository, with no paths: debt outlives the
  commit that landed it. The unit is DIFF LINES, and debt owned by nobody counts
  with the foreign side. Prints one line: `off` (no debt, nothing it can read),
  `bright rev <own>`, `dim rev <foreign>`, or `split rev <own>/<foreign>` when both
  stand — rendered as one segment, own bright and foreign dim. Nothing here is red,
  and a watchdog kill is not shown at all: a kill settles nothing of its own, so the
  paths of the round it hit stand in these numbers exactly as any others.
- Commit hook — **notify-once, never a wall**. A `git commit` whose pending paths
  carry debt exits 2 once, listing those paths and both ways to answer them — the
  `review --debt` command, which carries no path list because the mode reads the
  debt itself and widens to whatever a reopened round still owes, and the `waive`
  command over exactly those paths — and stamps a marker; the retry passes, consumes the
  marker and writes this chat's name into the debt journal. A new state re-arms
  the notice. A commit with nothing in debt passes silently. A commit target the
  command NAMES but neither hook can resolve — a token carrying an unexpanded
  shell variable, a path that is no directory, or more than one directory — is
  priced over every journal home, the call's own cwd and every directory the
  command itself named, one notice per repository, never over that cwd alone
  (invariant row ao). Foreign dirty or untracked paths are never priced, never
  mentioned, never block.
## Rounds are finite by construction

Two rounds exist and no third. Every count here is the WHOLE round's, never one
repository's: a merged panel is priced exactly as a solo one, and the dials live
in `share/rbench/round.py` alone (`ROUND_FIX_MAX = 8`, `ROUND_HARD_MIN = 20`,
`HANDOFF_P1_STOP = 3`).

- **≤ 8 confirmed** — `fix`. The commit that carries the fixes closes the round,
  and no round 2 ever follows.
- **9–19 confirmed with fewer than 3 P1** — a decision is required before any
  fixing pass. `fix` is legitimate here; round 2 runs only if the decision names
  it.
- **≥ 20 confirmed, or ≥ 3 P1** — a decision is required, and `fix` has to say
  why the code is worth keeping as it stands; `simplify`, `cut` and `redesign`
  each mean round 2.

The decision is a RECORD and never prose:
`review-bench fork <run-id> --choice fix|simplify|cut|redesign --why '<text>'`
writes `<run-dir>/fork.json` (`choice`, `why`, `session`, `at`). Those four words
are the whole vocabulary (`DECISION_WORDS`), shared by the flag, the `fixes:` and
`decision:` rows and the Russian decision text (фиксим / упрощаем / вырезаем /
редизайн). `--why` is the strategic reason for the choice — never a list of
findings — and is refused under 80 characters (`FORK_WHY_MIN_CHARS`).
`review-bench fork <run-id> --check` is the one verdict the gates relay: exit 3
with the `fork` command while a decision is owed and none stands, exit 0
otherwise. Three gates read it and none composes a threshold of its own: the Bash
PreToolUse gate (`review-flow-gate.sh`) blocks a `review-bench fixes <id>
--done|--blocked` command, the Agent PreToolUse gate (`worker-limit-gate.sh`)
blocks a brief carrying one, and the Stop gate (`stop.d/ask-review-report.sh`)
treats such a run without `fork.json` exactly like an untriaged one, asking for
the `fork` command under the same bounded `--mark` counter. The record reaches
Egor as one line through the delivery channel — `review <run-id> · decision:
<choice> → round 2|no round 2`, ledger key `fork`, once.

Round 2 is the run launched over the same scope after that record —
`REVIEW_ASKED=1 review-bench review --debt` (invariant row at), whose scope is
round 1's whole scope plus the fixes. It is STAMPED at launch, never derived from
what a state directory happens to hold: its meta carries `round: 2` and
`chain: <round 1's id>`, round 1 carries `round: 1`, and the chain id is what the
block's `id:` row prints for both. Those two keys of the FINISHED `meta.json` are
the contract every reader outside this tool has — the claude-setup hooks read
`round` and `chain` off it, and a record carrying neither is round 1 with no
chain. The launcher refuses a third round on a chain
with one line, `review-bench doctor` prints a `rounds_past_two` line if a run ever
carries `round` past two, and the commit that closes round 2 closes round 1 with
it (`fixes --cover`, one receipt per round). `coverable_runs` is therefore: a
round 1 inside the fix band, a round 1 whose decision named `fix`, and any round 2.

### A spent round budget may not sleep on its own debt

Where nothing owes a triage, `pending-report` answers the Stop gate one question more:
a run of THIS chat whose round is done and owes no second one — its budget spent — with
debt still standing on paths its own snapshot holds AND THIS CHAT OWNS. Nothing in the flow
will come back to them: no further round is offered, and no waiver or newer artifact answers
for them. A residual that is entirely a co-tenant's is not asked at all, and neither is an
ORPHANED one: no record names those paths for this chat, and a gate that demanded a waiver
for them would be turning "nobody's" into "yours" by asking whoever happened to stop here.
They stay where an unasked question belongs — the statusline's third number, `doctor`, and
`review --debt --all`. The line count is over the same paths the waiver names — a demand
naming a number no command it prints can settle is a blocked stop nothing can release.
The answer is three lines the hook only words — `<run-id> <diff lines>`, the `waive`
command over exactly those paths with the reason left to be written, and the `--debt`
review — and it is bounded by a `--mark` counter of its own (`settle-nudged`), the same
allowance as the triage ask, so a demand this chat cannot answer costs a fixed number of
blocked stops and never waits for Egor. Settled either way, it is silent.

Both markers hold one `<iso> <state>` line per ask, and the gate is silent while
the state it would ask about equals the state of the LAST line: a question asked
once and answered by nobody is not asked again at the next Stop. A state that has
MOVED is a different question and gets its own ask — another path in the settle
residual (`settle-nudged`: the own paths, sorted, space-joined), or a run that has
since been triaged and now owes a fork rather than a record (`report-nudged`:
`<run-id> record|fork`). The count of lines stays as the loop guard for a state
that flaps, so nothing can spend more than the allowance whatever it does. A line
written before this format carries no state, which no real question equals, so it
costs one ask and no more — there is nothing to migrate.

It is silent, too, while the answer is already being given: a review THIS CHAT has in
flight whose own `reviewed` snapshot holds every path the demand would name takes the ask
away before it is asked, and the `settle-nudged` counter is not touched — the allowance is
for a demand nobody is acting on, and three of its asks burned against a live panel over
those very paths (2026-08-24). Live is the one signal the statusline's review anchor reads
and no heuristic of its own — a progress document of this chat whose process is alive
(`live_progress_run_ids`) — so a run of ANOTHER chat silences nothing, its scope being not
this chat's to wait on, and a run that dies without recording leaves nothing alive, so the
next Stop asks exactly as before. A WORKER RUN this chat launched that is still writing
inside this repository's family silences it the same way and on the same terms
(`live_worker_run`, liveness by the pid rule of shared-invariants row `ar`, no path
matching): while the worker edits there is no settled content to price, and the ask went
out over 18056 lines of half-written files (2026-08-24) — another chat's run, a run
standing in another repository, and an abandoned supervisor silence nothing.

## Watchdog

Per (model, effort), from the last `CAP_WINDOW_DAYS = 21` days of runs: cap = the longest of
the pair's completions a triage confirmed a finding of + `DURATION_CAP_GRACE_S = 180`; under
`DURATION_CAP_THIN_SAMPLES = 5` such completions, the longest of all its completions + the same
grace; no completion in the window, `DURATION_CAP_DEFAULT_S = 900`. A kill raises nothing — a
killed row, a chunked cell's included, is never a sample. An agy cell is then held under
`AGY_DURATION_CEILING_S` for the tier (480s at T0/T1, 600s at T2/T3); Claude and codex have no
ceiling. On breach the cell is killed, the run is marked `timed_out` in its record, which the
report flow and `review-bench doctor` read; the statusline shows nothing for it, since a killed
run settles nothing and its paths stand in the debt like any others.

Under the duration cap sits the stall watch: activity is any byte on the cell's pipes or growth
of its declared stream file — geminib's `--log-file` for agy, the `--json` event file for codex,
the `--output-format stream-json` event file for Claude; OpenCode declares none and is watched
through its pipes alone — and the cap is
the longest silent gap the pair's completions showed in the same window +
`STALL_CAP_GRACE_S = 120`, floor `STALL_CAP_FLOOR_S = 240`; a pair with no gap on record has none, and a stall cap at or
above the duration cap is not handed to the cell. A kill takes the whole process group, records
`stalled_s` on the cell and reads as `stalled` in the report.

A kill of ours — cap or stall — ENDS the cell: no retry, no further chunk pass, and nothing of
its partial output is read; the cell stands killed with its reason. The only answers asked for
again are unusable output — a Claude stream that never reached its `result` event included —
and a provider's own server error, and one pass LAUNCHES at most `CELL_ATTEMPTS_MAX = 2` times,
transient waits and retry causes together: a chunked cell reads every chunk it has, each pass
under a budget of its own, while a kill on any pass still ends the whole cell. A usage wall
rotates the account and spends nothing of it, and a killed attempt whose partial output carries
the wall wording retires the account without asking the next one. Past the budget the pass's
answer stands.

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

One `failed:` row per family AND cause — name, cause, duration — and no panel cell
is unaccounted for: every one of them stands in `found:`, `noise:`, `quiet:`,
`echoed:`, `untriaged:` or `failed:`, because the cell that broke silently is the
one nobody goes looking for. Not a partition — a cell is listed in `found:` per
confirmed finding and in `noise:` per rejected one, so a cell with both appears in
two rows. `quiet:`, `echoed:` and `untriaged:` name cells by a count alone and are
three different facts: a
cell that claimed nothing is `quiet`, one whose every claim another cell had
already made is `echoed`, and one whose findings nobody judged — the whole panel
of an untriaged `--raters` run — is `untriaged`. Read as one word they all said a
cell had found nothing. The cause is one
word of a closed vocabulary — the status words `not run`, `killed · cap`,
`killed · stalled` and `mismatch`, and whatever the failure's own text names:
`pool empty`, `walled`, `throttled`, `bare 429`, `bad output`, `capacity`,
`server error`, `root commit`, `permission`, `bad command`, `stalled`, `timeout`,
`crashed`, `auth`, plus `no output` for a silent failure and `unclassified` for
text that matches nothing (`FAILURE_REASONS` and `STATUS_REASONS` are the two
lists; nothing narrows them on the way to the row, so a reader switching on a
shorter list misses real causes) — and the two `killed` ones name OUR cap and OUR
silence watch alone: a
provider that timed out on its own is not the panel stopping a cell. At
`CHRONIC_FAILURE_STREAK` consecutive failing runs the cause carries
`3 runs in a row` — below that a cell is merely unlucky. The streak is counted
over the runs that held that cell; a panel it was never part of is passed over
rather than read as a recovery. A whole side no cell was launched on collapses
into one CAPS row naming what the run recorded about that side — `CLAUDE LEG
WALLED`, `COOLING`, `OFF`, and `NOT RUN` where nothing was recorded at all, since
`off` is a switch Egor closed and not a default — and a `not_run` instance whose sibling
failed inherits the sibling's cause. The header prices the run instead of listing
it: the wall clock, the longest CHAIN inside it (a cell plus the retry and
verification that ran after it), the `LOST` minutes nothing in the block accounts
for — the chain plus every other cell's verification, which runs serially after
the panel — and then the members and chunks a merged or chunked round read. The
header carries NO time of its own: a current block is about now by construction,
and the one timestamp a report ever prints is the finish date the STALE frame word
carries, for the block that is not about the tree in front of the reader.

## Launches and reports

`REVIEW_ASKED=1` marks a review Egor asked for by name; `REVIEW_GATE_OK=1` marks
his explicit skip — both on the model's honour (2026-08-10). The framed block from
`record --no-corpus` is the only review output Egor reads, and the report hook
prints it: one copy, from review-bench's own rendering, costing no tokens. What the
model owes after the block is judgment the block cannot hold, never its contents
restated. The corpus rules (sealed judges, `--bench` opt-in) are unchanged.

**The launch DETACHES its own panel.** `review-bench review …` starts the panel in a
session of its own with its output going to `<run-dir>/panel.log`, prints the run id the
moment the run has a `meta.json` to be asked about, and returns — so the ten-minute cap a
harness kills a foreground command at can no longer take the panel down with it and orphan
its cells. `review-bench wait <run-id>` is the blocking half: it follows the panel's pid by
the same liveness rule everything else here uses (invariant row `ar`), then prints EXACTLY
what the foreground run printed after its panel — the closing text is teed to
`<run-dir>/panel.handoff` by the run itself, so the two can never drift — and exits on the
run's own code from `<run-dir>/panel.exit`. A `wait` on a panel that died without handing
anything over prints the tail of `panel.log` and points at `review-bench doctor`, and an
unknown run id is a refusal, not a wait. `--foreground` keeps the whole round in one
process; it is how the suites and fixtures drive a panel, and it is never advice to a chat,
which is why no surface prints it.

**A round is two dispatches, and the panel briefs only the first.** The panel's
ADJUDICATION HANDOFF is STEP 1 of 2: a fresh worker session, blind triage, `record` — and
it says to fix nothing, because the fixing pass is dispatched separately. `record` writes
STEP 2 itself when the verdicts land: how many findings survived and at which severities,
the fixing constraints (suites, mutation-verified asserts, neither commit nor stage — the
worker leaves the work in the tree and the CHAT's own commit closes the round), and one
plain recommendation
of the shape of worker the severities call for — mechanical findings a fast one, a confirmed
P1 a strong one. The panel cannot write that brief: it does not know what survived, and a
fixing brief handed out beside raw findings names a count nobody has judged. A round with
nothing confirmed prints no step 2 at all, and neither does one over a snapshot the checkout
has moved past. At the P1 threshold step 2 is the stop itself: record it `blocked`, fix
nothing, report the P1 list.

**A finding in a `.md` file carries no P weight.** It stays confirmed and the fixing pass
fixes it like any other, but every number the round is PRICED on counts CODE findings alone:
the `confirmed:` row's severities and total, the report receipt's `confirmed` and
`confirmed_by_severity` and every band dial. The row names the
rest in a tail of its own — `P1 1 · P2 8 · P3 3 · 12 total · 3 in docs`, absent where there
are none — and the receipt carries a `docs` count beside the others. Documentation is prose
an LLM may never read; code executes on every run, so a round whose loudest findings are
documentation is not a round that owes a second review. The optional `fixes --done` tally still
counts all of them, docs included — both numbers together or neither, and its refusal
says so.

**A diff too big for one cell is split, not the panel.** Past `DIFF_CHUNK_THRESHOLD_LINES`
(1500) the commit's diff is cut at FILE boundaries into chunks packed to
`DIFF_CHUNK_TARGET_LINES` (800), and each cell reads them one after another. Chunking
**never multiplies the panel**: the cell count is the tier's own whatever the diff's size, one
rater is one cell with one findings file and one verdict namespace, and no `#N` suffix is
invented here — that spelling stays the tier's word for a rater it deliberately runs twice. A
cell per (rater, chunk) made a 13-cell tier over a 25-chunk commit 325 concurrent cells and
hundreds of processes (live, 2026-08-22). A failed pass costs that cell that chunk and nothing
else: it keeps the findings of the passes that did come back. Both
numbers are the DIFF's own lines, headers and context included, since what kills a cell is the
size of the text it is handed and not the number of lines a commit changed. A file is NEVER cut
inside: one whose own diff is over the target is a chunk of its own, read whole, and a commit
that IS one such file is handed out unsplit — the target bounds every chunk holding more than
one file and nothing else. Cut into sub-hunks instead, the halves of one rewrite went to cells
that could not see each other's text and the deletion-only pieces were not even valid patches
(2026-08-22). A chunk's paths therefore say the whole of what it holds, which is all the cells
reading the repository instead of the pasted text are told. It is ONE run: one receipt, one
handoff, one set of finding indices; the target line names the chunk count. A chunk NO cell's
pass came back from is the one thing that costs the round coverage — its paths stay in debt,
while a chunk any recorded cell read is covered however many other passes over it died. A pass
counts as read on its ANSWER and not on its exit code: prose, an empty reply or a 429 in the
text is a failed pass, since the cell's answer is its chunks joined and another chunk's clean
marker would carry an unread one. Below the threshold nothing is split and the run is
byte for byte the one it always was. The numbers are measured, not chosen (`diff_chunks`): diff-fed Claude
and Codex cells die on a few percent of their cells under 1500 lines, ~16% between 1500 and
2000, ~29% past 3000, while the cells that read a clone show no such trend.

**The header carries the round, then the state** (invariant `as`). A review block
opens `review · round <N>` and no row below it repeats either fact: which of a chain's
two blocks a reader is holding is the block's own identity, and read off the rows it
takes reaching `before:` to find. The state hangs off that word as a suffix and is the
only place a block states it. The bare `review · round <N>` — the fixes are done, or
there was nothing to fix. `· NOT FINISHED` — and ONLY this — is a round whose fix
status is `blocked`: the pass stopped at the P1 threshold and fixed nothing.
`· NO PANEL` names a run no cell completed. `· STALE · <D Mon>`
names a run that finished older than three hours ago (`REPORT_STALE_HOURS`) — a
clock and nothing else: content and delivery criteria were tried and called a
block stale the moment its own fixing pass moved the tree. Its date is the run's
own finish, in the reader's zone, and is the frame's only timestamp: a current
block carries no time at all. `bench`, which wears no round at all, is an untiered
explicit-`--raters` panel, which is no review round and settles no debt. A
watchdog kill has NO word of its own: the cell it killed says so on its `failed:`
row (`killed · cap`, `killed · stalled`) and how much of the diff the survivors
covered is the triage receipt's to answer, not the frame's. The paragraph asking
for a decision is NOT in the block:
`review-bench fork <run-id>` prints it for the report hook to hand the model,
which is who acts on it, while Egor reads the block. A round whose
fixing pass has not answered wears the PLAIN word until the clock above dates
it STALE, and says so in its `fixes:` row either way. While its triage is
younger than the triage-gate window it is delivered ONCE as `triaged` — ONE
LINE, never the block: `review <run-id> · triaged: P1 a · P2 b · P3 c · N total
[· D in docs] — fixing pass next`, rendered by `review-bench report <id> --line`
off the same tally the `confirmed:` row prints, no fork and no reply expected.
The recorded fork decision follows the same way under `fork` (`--line fork`).
Past that window it is delivered by no
hook at any age — a loud word derived from "no fixes recorded" reports failure
while the fixes are still landing, and promoting aged rounds to a deliverable
state floods the Stop gate with every pre-receipt run the chat ever held. The
finished report follows on its own, from the Stop net's `pending-delivery`
source, one per state per round.

**The rows, in one order.** `tier:` and `confirmed:` open every block. A round 2 adds
`before:` (round 1's own tally) and `decision:` (`<choice> (round 1)`) and a round 1
prints neither — a round with nothing before it has nothing to be read against. `fixes:`
speaks while a fix or a decision is owed; after a non-fix decision it goes quiet rather than
calling simplify, cut or redesign a fix that closes the round. `next:` always speaks on a review
round — the one row that says what the reader does now. An untiered bench prints neither row.
Then the panel's own accounting (`verifier:`, `rejected:`, `found:`,
`noise:`, `quiet:`/`echoed:`/`untriaged:`, `failed:`), and `id:` LAST, carrying the
CHAIN's id rather than the run's: the two rounds are one piece of work, and an id is
what a reader types back into a command — one of them, never two to pick between. Every
value stands in one column, wrapped values included: a continuation that returns to the
left margin reads as a row label nobody can look up.

**Who may close a round.** `record` and `fixes` key on the session the RUN RECORD
names, never on the shell they were typed in: a claudeb worker carries a session of
its own and a codex worker inherits the launching chat's environment, and keyed on
the caller the same round's receipt, report and fix coverage moved to a different
chat depending on who ran the command.

**Nothing is dropped.** `pending-delivery` asks inside the triage window, which is a
bound on reports nobody has looked at and not a verdict that an older one is not
owed. `review-bench settle-delivery [--dry-run]` settles every round `doctor` counts
as undelivered — the two FINAL states alone, never a `triaged` round, whose window
is the whole flood guard — one of two ways and never a third: **queued**, so the launching
chat's next stop hands it over whatever its age, or **lapsed** with the instant,
because the transcript that stop reads is gone. Both are written into the run's own
`delivery.json` against the STATE they answer for, so a re-adjudication puts the
round back in the queue. `doctor` stops counting a lapsed round as undelivered and
marks a queued one `queued`; `doctor --lapsed` lists the written-off ones, unbounded
by the scan window, because the whole point of the class is that nobody will ever
deliver them.

## Doctor

`review-bench doctor` is pull-only diagnostics over the stores this page describes, and never a
gate: it exits 0 whatever it finds, because a review system with an anomaly in it is still a
review system. It names five classes — `untriaged`, `undelivered`, `stuck_fixes`,
`orphan_debt`, `kill_asymmetry` — each a silence rather than an error: a record some mechanism
above should have moved on and did not. `stuck_fixes` counts the two states only a person can
clear: a round whose decision named a second pass nobody ran, and one whose receipt says the
fixing pass STOPPED. A round that closes itself — the fix band's, or a second round with its
budget spent — owes only the commit that carries its fixes, so counting one as stuck reported
as a fault the ordinary state of every round whose fixes were still being written. Beside the
five, and belonging to none of them, `doctor` prints a `rounds_past_two` line for any run
carrying a `round` past the budget: that is the launcher's refusal having failed, which no age
and no count can qualify. `kill_asymmetry` keeps its name and counts every panel
that completed nothing, however it died; it is a diagnostic and nothing more, since coverage no
longer turns on the kill marking that once split those rounds in two. Their ages live in one dict in the tool and are spelled
nowhere else, here included. The run-level classes look back only so far, because nobody triages
last month's panel and a count that only grows says the same thing every time it is read; the two
about the tree as it stands — orphaned debt and the debt in front of the reader — are unbounded.

The periodic snapshot (`--snapshot`, its launchd collector and the menubar row that reads it) is a
registered experiment, `review-doctor-collector` in `EXPERIMENTS.json`; the command itself is not.

## Non-goals — deleted by this contract

Cross-session policing of any kind; pricing the shared tree (cycles, tickets,
receipts, vouches, drift budgets, content coverage of commit forms); blocking a
commit for longer than one notice; repo-history coverage answers (`same_commit`
and kin stay dead); tier advisories (the chat picks the tier itself). Reviewing
another chat's leftovers is not a gate concern — it is an explicit ask from Egor,
run as an ordinary scoped review by the session he asked.
