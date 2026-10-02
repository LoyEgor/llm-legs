# Code doctor — design (2026-10-02, v2 after the frontier and T2 design reviews)

## Why (Egor, 2026-10-02)

The four sweep repos (llm-legs, claude-setup, review-bench, hammerspoon) only grow. Models rarely
search what exists and write a new copy (the hidden-Chrome driver for video generation and another
for images; a hook re-implementing a hook class that lives elsewhere). Code for situations that no
longer exist stays. Tests grew into monsters: a 7-minute edit, 20 minutes of tests. He wants a
fourth doctor beside LLM, Harness and Updater that finds this and lets the night fix it — and that
stays efficient: once the repos are in order its cost falls to near zero.

Today the sweep's `fit` lens sees only NEW lines against the codebase (never two old mechanisms),
the Harness Tests area only speeds suites up, and nothing looks for dead code, retired situations,
needless complexity or token waste.

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
   retirement records, runtime rollups) and returns:
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
  actions, skills/commands/agents by name, night-run/doctor-fix job tables. Edges from tests,
  comments and docs do not keep production code alive; unreachable cycles are dead together;
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
- tests: a suite's retention is decided by the requirement it protects and the failure impact, never
  by "caught nothing lately" (account isolation, data loss and recovery tests are kept). Preferred
  fixes: make it faster while keeping the behavior it verifies (real processes stay where races,
  process groups, locks or shell compatibility are the point), split, or dedupe at the assertion /
  requirement level with a witness showing which remaining test covers it; timing claims need
  comparable baselines (same scope, population, concurrency, recorded load);
- hot code: time per call × calls per day from the hook, statusline, menu and worker journals;
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
- new vs. old: everything indexed since the repo's cursor is matched against the rest;
- a merge needs a net-benefit and dependency decision; intentional copies (the LLM doctor copies
  review-bench tables because review-bench is not importable there, guarded by test_consistency)
  are recorded in `docs/shared-invariants.md` and never re-flagged.

### deep pass
One initial coverage pass over all four repos, slice by slice on successive nights; afterwards only
slices whose digest changed are re-read. A clean, unchanged tree costs no LLM read.

## Recurrence prevention
Every landed cleanup records its canonical module in `share/canonical-mechanisms.json` (mechanism,
canonical path, what it replaced). The sweep's `fit` lens reads that registry, so a new copy of a
merged mechanism is flagged at review time; a deleted mechanism's identity stays in the ledger, so
the same cause re-appearing under another name is a `regressed` problem, not a new one.

## Efficiency
- the LLM reads only candidates and changed slices; verdicts are cached structurally;
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
- registrations outside the repos (settings.json, LaunchAgents, libexec wrappers) are never edited by
  the fixer: removing one is a `needs Egor` problem with the exact step;
- cross-repo merges land in safe order: shared module and migrated callers first, the old copy is
  deleted on a later night after the new path is proven;
- every fix stays under review-bench's scope limit and goes through a review round whose lens reads
  removals as well as additions;
- never other projects; never foreign uncommitted work.

## Calibration before thresholds
A versioned corpus (`tests/fixtures/code-doctor/`) of known cases — a partial duplicate pair, a dead
script with a dead cycle, a protected manual CLI, an intentional copy, a heavy test that must be
kept, a retired-situation branch with a surviving exception — is the acceptance test: each is found
or protected as labelled, and a healthy fixture repo yields no problems.
