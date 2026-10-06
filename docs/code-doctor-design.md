# Code doctor — design

## Why (Egor, 2026-10-02)

The sweep repos only grow: models write a new copy instead of finding the existing one, code for
retired situations stays, tests outgrow the edits they guard. This doctor finds that and lets the
night fix it, its cost falling to near zero once the repos are in order.

## Pipeline: index → candidates → judge → problems → fixer

1. **Index** (`bin/code-doctor index`, no LLM). Content-addressed per file and per symbol (function /
   cohesive block): digest, language, symbols, outgoing references, external touchpoints. Only files
   whose digest changed are re-parsed. A persistent cursor per repo records the last indexed snapshot
   (working tree included: main carries days of uncommitted work), so a skipped night loses nothing.
   Runs at night start and on the menu's Refresh, never on the 5-minute cadence. Declared languages:
   bash, python, lua, js, jq programs and scripts embedded in heredocs; Swift/C/others are listed as
   a blind spot, never silently "clean".
2. **Candidates** (`~/.cache/code-doctor/candidates.jsonl`, own schema, NOT problems). Each has a
   stable cause id; signals pointing at the same code (dead + heavy + duplicate, or N files of one
   copied mechanism) cluster into ONE cause, never N² pairs. Candidates bind to the index snapshot.
3. **Judge** (LLM, night only, enforced token AND wall-clock budget per night — counts do not bound
   cost). Reads a candidate with its context (callers, entry points, git history of why it was added,
   retirement records, runtime rollups) and returns one verdict per candidate id. One worker session
   judges a batch of candidates of one repository (`JUDGE_BATCH`), since the worker's fixed base
   context dominates a session's cost; its tokens are accounted evenly across the batch, and a
   missing or malformed verdict leaves that candidate waiting. A launch stops the night when the
   tokens spent plus the mean recorded session cost (the brief plus a base-context constant before
   any history) would cross the cap; a failed launch records worker-run's return code and output.
   The brief asks the reuse question of every candidate: does an existing mechanism (helper,
   renderer, shared invariant) already do this? If yes, the plan calls it and names it.
   Each verdict is:
   - `problem` with a concrete fix plan and its proof obligations, or
   - `not-now` with the reason and re-open triggers (caller, registration, purpose record or detector
     version change) and an expiry (90 days). This is a candidate verdict, never a problem dismissal:
     a filed problem is dismissed only by Egor, as for every doctor.
   Verdicts are cached by an evidence digest built from STRUCTURAL inputs only (code digests, the
   reference set, registrations, purpose records, detector version) — rolling counts and timestamps
   never invalidate it.
4. **Problems** go into the doctor document (`~/.cache/code-doctor/latest.json`, the shared envelope
   of `docs/doctors-contract.md`) and the ledger `share/code-ledger.json`.
5. **Fixer** (the existing night fixer through `bin/doctor-fix`, area `code`). Exception to the
   contract, written into it: the code area snapshots only the top-K problems by value for one night
   (value = net benefit, see Efficiency), so `close` waits on those K, never on the whole backlog.

## Groups (each confirmed problem counts once; groups sum to the header)

### dead — nothing reaches it
- liveness is a typed reachability graph from REAL entry points, not text matches: settings.json
  hooks, the stop dispatcher's directory globs, tests/run-all discovery, launchd plists and their
  `~/.local/libexec` wrappers, PATH links (`~/.local/bin`), Hammerspoon `init.lua` requires and menu
  actions, skills/commands/agents by name, night-run/doctor-fix job tables, and any repository's
  manifests, build/CI files, tests, tool configs and route directories (`generic_roots`). Edges from
  tests, comments and docs do not keep production code alive; unreachable cycles are dead together;
- protected roots: user-facing CLIs in `bin/` that Egor runs by hand (a list in the ledger), public
  Hammerspoon globals, anything a retirement record keeps as an exception;
- retired situations: only an explicit record (EXIT-PLAN, memory, the doctors' ledgers) matched to
  the exact behavior and its surviving exceptions (robot curl refresh is gone, the user-explicit
  refresh stays);
- runtime silence: only from a durable daily rollup of hits per component (hook rules, gate branches,
  menu actions, CLI invocations through the PATH shims) that this doctor adds; silence is claimed
  only over the rollup's observed coverage window, never past its start;
- docs and tests that point at removed code.

### heavy — cost out of proportion to purpose
- slow tests and hot hooks of the sweep repositories are the Harness doctor's Speed opportunities
  since 2026-10-03 (`docs/speed-doctor-design.md` §4); this doctor judges slow tests only in a
  `--repo` scope outside them. Both keep the same rules: a suite's `test_requirement`
  (keep row or head words) marks it `protected` and its lever speeds it up, never drops it; a hook is
  charged only for days after its script's last commit;
- token cost: always-loaded instructions (CLAUDE.md files, skill descriptions, hook-injected text)
  and docs read every session (DIAGNOSTICS.md), sized and weighed by how often they are read;
  mechanisms whose purpose costs more than it saves (a gate forcing rewrites that cost more tokens
  than they save);
- complexity: size/branch outliers, pass-through layers, flags no caller sets, one-user abstractions
  are candidates only; a problem needs a demonstrated simpler version with the same responsibilities;
- superseded machinery: custom code a platform or vendor capability now covers (Updater capability
  changes re-open it).

### duplicate — one mechanism written twice
- symbol/block level, not whole files: two browser drivers share lifecycle code while their route
  APIs differ;
- touchpoint fingerprints weighted by rarity (jq, git, osascript alone mean nothing), with a minimum
  informative overlap; near-clone shingles within one language; the judge confirms semantic
  duplicates across languages;
- `concept`: one rare output literal in 2–6 code files, any language or length: a glyph joining two
  computed parts (`{} ⧉ {}`) or a format/label template with a placeholder whose rarest word or glyph
  has idf ≥ 3.5 over the code files, so common words and punctuation never qualify. All sites of one
  literal are ONE cause (symbol units; top-level sites named in the detail); places that build the
  same concept without the literal are the judge's to find;
- new vs. old (`reuse`): a symbol whose digest is new since the repo's cursor (carried 7 days) is
  matched against existing helpers on relaxed thresholds (a clone from 4 lines at 0.5, two shared rare
  touchpoints, a shared rare literal over up to 12 files) and judged before anything else;
- `prose-layout`: an instruction file (CLAUDE.md, skills*/agents/commands md, READMEs out) whose
  section tells the model to write a user-facing layout by hand (row templates with `<placeholders>`,
  three or more enumerated parts, a prose fence of headings or rows, "one line per") while
  `report_frame.py`/`report-bus` exist: render via the shared frame, the model writes only the
  meaning. A section that only mentions a report is none;
- `concept`, `reuse` and `prose-layout` signals join another signal only on the identical unit, never
  through a containing span, so a big function does not chain unrelated literals into one cause;
- a pair of test cases (`test*` symbols, fixture blocks embedded in another language) weighs a quarter
  of its lines; a pair of helpers the suites could source keeps its full value;
- a symlink and its target are one file (resolved by realpath), never a duplicate pair;
- a merge needs a net-benefit and dependency decision; intentional copies (the LLM doctor copies
  review-bench tables because review-bench is not importable there, guarded by test_consistency)
  are recorded in `docs/shared-invariants.md` and never re-flagged.

### promise — a statement of what a mechanism does that no code path keeps
Why (Egor, 2026-10-06): for weeks chats said they had "passed a note to the worker" while no worker had an input
channel; the agent files implied it, nothing checked it. The night finds such claims the way that chat did: take the
stated capability and trace the code path.
- `claim` (index stage, no LLM): a sentence of a file models read (CLAUDE.md, skills/agents/commands markdown, the docs an
  instruction tells the model to read — `told_to_read`, the heavy group's own resolution — a bin CLI's usage/help text,
  a hook's injected literals) that names a resolvable mechanism (a bin script or subcommand, a hook, a tool such as
  SendMessage, a journal file through its writers) BEFORE an effect verb of the closed list (deliver, pass, send, reach,
  notify; block, refuse, deny, kill, guarantee, always/never + verb; record, journal, keep, restore, clean; retry, rotate,
  fall back, wait). A sentence opening on the verb is an instruction, never a claim. Each claim binds to at most 4 code
  files its names resolve to (a tool alone: the CLIs its file references). Cause `cause:<file>#promise:<sha of the
  normalized sentence>`; evidence digest = the claim plus the bound code digests, nothing else, so a claim is re-judged
  only when one side changes;
- `overclaim`: the Harness doctor's incremental transcript reader (`read_transcript`) emits `["o", t, mechanism,
  transcript, "line N", reason]` when an assistant text states a finished effect (delivered, passed … to the worker,
  sent, fixed, landed, «передал», «отправил», «доставлено», «починил», not negated) right after a tool result that said
  queued/pending/next round, running in background, timeout or a non-zero exit in its first 3 lines (deeper words are
  echoed prose: a `worker-run report` quoting its brief). A system program (`/usr`, `/bin`, Homebrew), an interpreter or a
  builtin tool is never a mechanism. The cause is the MECHANISM (`cause:overclaim:<bin subcommand | tool>`), never the chat; `rollup` keeps counts, reasons and the last 3 pointers per day; no words persist;
- order: claims new since the cursor first (the reuse group's `fresh` rule), then tokenmap monthly loads of the file
  (log2 bucket), then risk class delivery > safety > data > other; an overclaim outranks every claim;
- verdicts: `kept` (cites `kept_by` file:line and `test`; refused without `kept_by`), `problem` with `kind: broken`
  (`fix: code | claim`) or `kind: untested` (risk classes only; an untested `other` claim is stored `not-now`), or
  `not-now`. A broken overclaim's fix is a receipt the mechanism prints, as `worker-run say` does. Every promise problem
  carries the proof obligation: a test red without the fix, or the rewritten claim with its reason;
- budget: the doctor's one judge budget; cached verdicts make an unchanged tree free; `coverage.judge` shows the
  per-night capacity and the nights to cover the waiting queue.

### deep pass
One initial coverage pass over all four repos, slice by slice on successive nights; afterwards only
slices whose digest changed are re-read. A clean, unchanged tree costs no LLM read.

## Any repository: `--repo PATH`
Every subcommand but `record-fix`/`account` takes `--repo PATH` (repeatable): that scope instead of
sweep-repos, its state in `scopes/<names>-<hash>/`, the menu's document untouched. A repository outside
sweep-repos makes it report-only (`scope.report_only`): no snapshot, `check` and `launch code` refuse.
No harness journal covers it, so no hot or silent signal; its blind spots say so.

## Recurrence prevention
Every landed cleanup records its canonical module in `share/canonical-mechanisms.json` (mechanism,
canonical path, what it replaced). The sweep's `fit` lens reads that registry, so a new copy of a
merged mechanism is flagged at review time; a deleted mechanism's identity stays in the ledger, so
the same cause re-appearing under another name is a `regressed` problem, not a new one.

## Efficiency
- per-night token and wall-clock budgets for judge and fixer, enforced, with the stop recorded;
- the doctor accounts its own cost per cause (judge, fix, review, tests, retries, collector CPU) and
  its yield (lines removed, suite minutes saved under comparable baselines, always-loaded tokens cut,
  causes closed); the fixer's queue ranks by net value; low yield shortens the queue but never
  changes a detector — detector changes are Egor's;
- the menu shows problems; candidates waiting and the doctor's own cost/yield sit one level down, dim.

## Safety (unattended every night)
- a deletion needs a proof: no live entry point in the reachability graph, no rollup hits over a
  covered window, a purpose/retirement reason the judge quotes, not in active work (paths with
  uncommitted changes, live branches and worktrees, open review claims), and green suites; untested
  code is never deleted on green suites alone;
- judgments and fix plans bind to the index snapshot and are revalidated against the night base and
  again before landing; a changed input sends the cause back to the judge;
- edit targets are resolved to their owning repo; an edit through a cross-repo symlink is refused;
- what research settles the machine does; `needs Egor` only carries a trade (cost, loss,
  recommendation), never set by rule. A dangling registration's proofs are the commit that deleted or
  renamed its target and the tracked non-markdown files outside `docs/` still naming it; the night
  judge (sweep scope) removes or relinks such a `~/.local/bin` link and boots out a LaunchAgent whose
  program is gone (plist into the state dir), journaled in `accounting.jsonl`; an in-repo settings
  file is the fixer's edit. A silent hook goes to the judge, which researches before any trade;
- cross-repo merges land in safe order: shared module and migrated callers first, the old copy is
  deleted on a later night after the new path is proven;
- every fix stays under review-bench's scope limit and goes through a review round whose lens reads
  removals as well as additions;
- never other projects; never foreign uncommitted work.

## Calibration before thresholds
The corpus `tests/fixtures/code-doctor/` (five labelled cases, a healthy repository with no
problems, and `promise/`: the worker-message case and its kept sibling) is the acceptance test; its heavy test that must be kept is the protected case of
`tests/test_speed_doctor.sh`.
