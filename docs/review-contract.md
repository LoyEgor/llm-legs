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
against the empty string). Whether a round holds its paths turns on ONE fact — a
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
- `debt <n> [mine|other|unknown] [<owned>] [(+<f> foreign)] [locked|decreed]` — `n` paths in debt
  (restricted to `--paths` when given), always the whole count and never a share of
  it, since `n` is the field every reader prices the repository by. The owner word is
  the third field and the only one a reader switches on: `mine` when `<sid>` authored
  at least one debt path or a run of its own holds one, `other` when it owns none,
  `unknown` when no `--session` was
  given at all — nobody asked whose this is, so nothing here knows, and `other`
  would be an ownership no reader computed. With no `--session` and EVERY debt path
  recorded to some chat, the word is dropped entirely — `debt 2 locked` — since
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
  nothing is left out, and no share rides the line at all. It stands BEFORE the last
  word, which every reader matches at the end of the line: `locked`, or `decreed`
  where Egor's own unlock stands in the lock's place.
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
this chat's own debt plus the debt nobody owns — another chat's live work is a
moving target, and the round would answer for content its author never saw —
WIDENED with every surviving path of any locked round
standing over that debt: a lock is discharged only by a run that holds all of
them, and a path sitting at exactly the sha the locked round recorded is by
definition not in debt — so a debt-only scope could never answer the round it
exists for. Widened the same way, and for the same reason, by every round the fork
says is OWED a second one, locked or not: that round's own receipt is not read at
all, so its whole scope re-enters the diff at whatever answered for those paths
before it. A second round re-reads the full scope of the round that owed it plus
the fixes, never the fixes alone (Egor, standing since the 11-round loop) — scoped
off the newest artifact instead, which is that very round, a live second round read
the 258 lines its own fixing pass had written and nothing else while the handoff
promised the whole of it (2026-08-22). A round below both thresholds owes nothing
and keeps its receipt, or every review would inherit its predecessor's scope
forever; so does a round whose own round budget is spent, since the second pass
over a scope owes no third. Two answers never turn on the gate answering at all: a
round LOCKED by its P1 count is reopened whatever can be asked of the gate — else
the one round no waiver may settle is also the one whose review cannot be scoped,
a lock nothing can open — and a round whose tally cannot be READ fail-closes into
the same reopening. The reopening is looked for among every artifact standing over
the repository and not among the ones some path is in debt against: a threshold
stop fixes nothing by construction, so its round leaves no path in debt at all and
read off the debt its mandatory pass could never be scoped (2026-08-22). Per path, the comparison base is the content the newest artifact
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
choice this mode removes. What the scope left out is NAMED beside the target —
`skipped foreign: <n> path(s), <m> line(s) (chat <labels>) — include with --all` —
and `--all`, which only this mode accepts, reads it: a review that silently read
part of the debt reported a repository clean over files no rater ever opened. A
locked round's held paths are never skipped, whoever wrote them: the lock is
discharged only by a run holding all of them. Where nothing is left, the refusal
carries the same sentence rather than reading as a tree that owes nothing. With several `--repo` it behaves like any merged panel —
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
bytes. A codex or gemini worker has no Claude session, runs none of the journal hooks and
lists no files, so a pass delegated to one leaves NO entry either way; there its own run
record stands in — the launching chat, the repository, a listing that says it cannot be
complete, and the workdir dirt it gained inside the window. Where a co-tenant ran a blind
run over the same path too, nothing can tell the two apart and the path stays in debt. The path must be one the run's snapshot holds, because a fix that touched a file no
cell was shown is new work. A pass that fixed nothing wrote no fix bytes to cover. And a
round recorded `blocked` and a round the gate escalated cover nothing at all — their
fixes ride the round they owe. How the round's incomplete cells died is not asked here
either: a kill is a diagnostic, never a second-class round. Like a waiver's, the coverage
is exactly those shas: the next edit is debt again, and a re-adjudication that leaves the
receipt answering another triage takes the coverage back with it.

**The lock IS the mechanical second round.** When the newest run holding a debt
path came back with `SECOND_REVIEW_P1S` confirmed P1s, the debt reads `locked`:
`waive` refuses it and the commit notice withholds the waiver option, saying why.
The way out is the follow-up review over the full original scope plus the
fixes, which is what `review --debt` computes with no path named by hand — there
is no other mechanically-forced round. A round that earned its second review on
the tally alone (`SECOND_REVIEW_FINDINGS` confirmed findings
under the P1 count) locks nothing: the fork says the round is owed, and `waive`
may still answer it on the model's own judgment, which a waiver records with its
reason.

**A decree is Egor's own unlock, and the only other way out a chat can take.**
(A lock also ends by itself where the locked round's own round budget is spent —
that round's report offers no third pass, and a lock demanding one is a gate
nothing can open.) `review-bench decree
<run-id> --reason TEXT` records `decree.json` on a LOCKED round; from then on the
round's withheld waiver is grantable, and the reason prints loud — a `decree:` row in
that round's report, and a `decree: <run-id> — <reason>` line under every waiver riding
it; the one-line `debt` answer, which has no room for a sentence, reads `decreed` where it
would have read `locked` rather than reading like a round nothing ever withheld. It is refused on a round that is not locked (nothing to discharge), without a
reason, and on a round that already carries one.

**Only Egor's explicit word authorises a decree, the same discipline a commit is
under.** A model never runs it on its own judgment, never as a way past a round it
would rather not re-review, and never because the second panel looks expensive — a
locked round forgiving itself is the one thing the lock exists to prevent, and every
other route to that outcome is mechanically closed. What this command cannot enforce,
it makes loud instead: the reason stands in the block Egor reads, so a decree nobody
authorised is visible as one.

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

**A round is two dispatches, and the panel briefs only the first.** The panel's
ADJUDICATION HANDOFF is STEP 1 of 2: a fresh worker session, blind triage, `record` — and
it says to fix nothing, because the fixing pass is dispatched separately. `record` writes
STEP 2 itself when the verdicts land: how many findings survived and at which severities,
the fixing constraints (suites, mutation-verified asserts, neither commit nor stage), the
`fixes --done --fixed <N> --fp <M>` line that closes the round, and one plain recommendation
of the shape of worker the severities call for — mechanical findings a fast one, a confirmed
P1 a strong one. The panel cannot write that brief: it does not know what survived, and a
fixing brief handed out beside raw findings names a count nobody has judged. A round with
nothing confirmed prints no step 2 at all, and neither does one over a snapshot the checkout
has moved past. At the P1 threshold step 2 is the stop itself: record it `blocked`, fix
nothing, report the P1 list.

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

**Five frame words, two delivered states** (invariant `as`). The word is the only
place a block states its state. `review` — the fixes are done, or there was
nothing to fix. `review · NOT FINISHED` — and ONLY this — is a round whose fix
status is `blocked`: the pass stopped at the P1 threshold and fixed nothing.
`review · NO PANEL` names a run no cell completed. `review · STALE · <D Mon>`
names a block that is not about the tree in front of the reader, on either of two
counts and never on a clock: the report was not handed over at `record` time —
`settle-delivery` had to queue it, or wrote it off as lapsed — or the content it
priced has moved, its `reviewed` snapshot priced by the same `repo_debt` a
`--debt` review is scoped with. Its date is the run's own finish, in the reader's
zone, and is the frame's only timestamp: a current block is about now by
construction, so the header carries no time at all. `bench` is an untiered
explicit-`--raters` panel, which is no review round and settles no debt. A
watchdog kill has NO word of its own: the cell it killed says so on its `failed:`
row (`killed · cap`, `killed · stalled`) and how much of the diff the survivors
covered is the triage receipt's to answer, not the frame's. The fork (fix as it
stands / rewrite the weak block / cut the scope) is NOT in the block:
`review-bench fork <run-id>` prints it for the report hook to hand the model,
which is who acts on it, while Egor reads the block. A round whose
fixing pass has not answered wears the PLAIN word and says so in its `fixes:`
row, at any age, and no hook ever delivers it — a loud word derived from "no
fixes recorded" reports failure while the fixes are still landing, and promoting
pending rounds to a deliverable state floods the Stop gate with every
pre-receipt run the chat ever held. The finished report follows on its own, from
the Stop net's `pending-delivery` source, one per state per round.

**Who may close a round.** `record` and `fixes` key on the session the RUN RECORD
names, never on the shell they were typed in: a claudeb worker carries a session of
its own and a codex worker inherits the launching chat's environment, and keyed on
the caller the same round's receipt, report and fix coverage moved to a different
chat depending on who ran the command.

**Nothing is dropped.** `pending-delivery` asks inside the triage window, which is a
bound on reports nobody has looked at and not a verdict that an older one is not
owed. `review-bench settle-delivery [--dry-run]` settles every round `doctor` counts
as undelivered, one of two ways and never a third: **queued**, so the launching
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
review system. It names six classes — `untriaged`, `undelivered`, `stuck_fixes`, `eternal_lock`,
`orphan_debt`, `kill_asymmetry` — each a silence rather than an error: a record some mechanism
above should have moved on and did not. `kill_asymmetry` keeps its name and counts every panel
that completed nothing, however it died; it is a diagnostic and nothing more, since coverage no
longer turns on the kill marking that once split those rounds in two. Their ages live in one dict in the tool and are spelled
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
