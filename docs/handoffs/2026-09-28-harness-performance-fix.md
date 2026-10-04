# Hand-off: fix the harness's own performance

Status: done 2026-10-04 — superseded: load-unseen-suites-statusline, load-busy-night-concurrency, loose-objects-logo-vectorizer-bench, test_daily_cost-worker-run, test_long_pole-worker-run, and the hook rows of 2026-10-04-hook-cost-rows.md and 2026-10-04-hook-floors.md

Closed by Harness Doctor 2026-10-04. Each §3 item is fixed or carried by a narrower row: 1 `bin/worker-pick`
exports `GROKB_MODELS_NO_FETCH`; 2 and the load targets are judged by the load rows (live 17:08: 962 forks/s,
6.4 unseen cores, statusline cuts that cost freshness stay Egor's §6 trade); 3 `instruction_repo_files` lists by
`git ls-files` (share/instruction-files.sh:141); 4 `pack_loose_objects` (llm-legs@727ddde) plus claude-setup
`rj_pack_loose`, logo-vectorizer-bench at 6 469 loose (was 16 433); 5, 6 the hook_sync/hook_p50/floor rows;
9 the test_worker_run split (llm-legs@8f113a19); 10 memlogd `sync_writes`. 7 and 8 raise no doctor signal.

For: an autonomous LLM that fixes, tests and verifies the problems below without supervision.
Written 2026-09-28 from the speed investigation
(`docs/handoffs/2026-09-28-speed-investigation.md`, "the investigation" below) and the first day
of the Harness doctor (`docs/harness-doctor-design.md`). The owner cannot tell which slowdowns are
real problems and which are harmless. This document separates the two. Fix what §3 lists, leave
§4 alone, measure §5 before touching it, and bring §6 to the owner.

## 0. Done means

The Harness doctor is the before/after instrument. `python3 bin/harness-doctor --json` prints the
current document and persists nothing, and the LaunchAgent refreshes `~/.cache/harness-doctor/`
every 5 minutes. Record the baseline before the first change, then re-measure after each fix,
under a comparable load (note the number of live `claude` processes each time).

| signal (Harness doctor) | now (2026-09-28 23:15, ~12 sessions) | target |
|---|---|---|
| Load · unaccounted CPU (busy × ncpu − per-process CPU) | 5.3 cores | < 2 cores |
| Load · new processes | 1 421 /s | < 1 000 /s |
| Load · CPU busy / kernel share | 84 % / 40 % | follows from the two above; no own target |
| Waits · short Bash median, every project | 1.6 s llm-legs; best day 12 s in logo-vectorizer-bench (investigation: 40 s median, p90 98 s there) | ≤ 2 s in every project, logo-vectorizer-bench included |
| Waits · cuts per hour | 0, except dia-not-chrome: 7 cuts at its 5 s limit since 16:50Z | 0 |
| Hooks · `N hooks can hold a chat up to 600 s` | 8 | 0 synchronous hooks without a timeout |
| Growth · loose git objects, logo-vectorizer-bench | 16 433 and rising | stops rising |
| statusline CPU (recipe in §2) | ≈ 2.9 of 10 cores | < 0.5 core |

Then run every suite of each repository you touched: `bash tests/run-all` in llm-legs,
claude-setup and review-bench. In llm-legs, also run `bash tests/test_consistency.sh` after
touching anything listed in `docs/shared-invariants.md`.

## 1. Ground rules (hard)

- **Hooks run live from the shared working copies.** `~/.claude/hooks` links to
  `/Volumes/Work/Projects/claude-setup/hooks`, and `~/.claude/statusline.sh` links to
  llm-legs `bin/statusline.sh`, which sources llm-legs `share/` and `bin/`. Saving a file there
  changes every running chat and worker at once. That is exactly how the 09-22 incident happened:
  a worker's edit to `share/instruction-files.sh` added 8 s to every tool call for six days.
  Develop each change in a copy, test it on fixtures, then put it in place with an atomic `mv`, so
  that a half-written file never runs. Right after each swap, check the Harness doctor's Waits and
  cuts for the next 10-15 minutes.
- **`~/.claude/settings.json` is not versioned.** Copy it to your scratch directory before any edit
  and name the copy in your report. The Harness doctor's change log records hook additions,
  removals and timeout changes.
- **No commits and no pushes.** The night sweep commits. Every repository here carries other
  chats' uncommitted work (41 entries in llm-legs, 16 in claude-setup, 25 in review-bench). Never
  revert, restore, stash, clean or delete what you did not write. Targeted edits on top of it are
  fine.
- **`hammerspoon/llm-limits.lua` is also being edited by another chat, «LLM Doctor меню
  refactoring».** Make only targeted edits there. Never touch the live Hammerspoon module
  (`package.loaded["llm-limits"]`): test through `tests/llm_limits_renderer_harness.lua`, and tell
  the owner to use Reload Config.
- **Never point a test at the live `~/.claude-profiles/.claudeb` store**; use `CLAUDEB_DIR` fixtures.
- **The statusline is bound by `docs/statusline-contract.md`**, including its rule that the git
  counters are recomputed from live git on every render ("no cache to go stale"). Update
  `tests/test_statusline_hooks.sh` whenever a segment's behaviour changes. A cache, or a longer
  `refreshInterval`, changes that contract, which is §6 territory.
- **Contention is never answered with queues, locks or waits.** The owner's rule is that parallel
  load beats serial: keep Claude Code responsive by lowering the priority of heavy background
  work. The flip side is that a synchronous hook the chat waits on must never be reniced; that
  makes the chat wait longer. It must be fast instead.
- **Experiments** (temporary switches, probes) are registered in `EXPERIMENTS.json` through the
  `experiment` skill. LaunchAgents use a named wrapper in `~/.local/libexec/<name>` (llm-legs
  `CLAUDE.md`).
- **Code comments near zero**: only the non-obvious "why" at a trap.
- **Verify before you fix.** Every item in §3 was measured on 2026-09-28, but other chats keep
  working. Re-read the code and re-run the measurement first. If the code already changed, record
  the item as already fixed.

## 2. How to measure

- **Harness doctor**: `python3 /Volumes/Work/Projects/llm-legs/bin/harness-doctor --json | jq …`
  (fields `sections[].rows[].cells`, `.state`, `.fact`), or `--menu` for the rendered lines.
- **Fork rate**: `a=$(sh -c 'echo $$'); sleep 10; b=$(sh -c 'echo $$'); echo $(( (b-a)/10 ))/s`.
- **Fork attribution**: sample `ps -axo pid,ppid,command` every 0.2 s for 25 s and count new PIDs
  by nearest script ancestor. On 09-28 the result was worker-pick 822, statusline.sh 815,
  worker-run 553, bare bash 346, launchd 304, review-debt 252, statusline probes ~170.
- **Statusline cost**: count top-level `statusline.sh` starts over 30 s (114 with 12 claude
  processes = 3.8/s), and time one render with `/usr/bin/time -l` on a captured stdin JSON
  (0.74-0.79 s CPU each, probes not included).
- **One hook's cost**: run the hook with a captured stdin payload under `/usr/bin/time`, at the
  current machine load.
- **The PreToolUse phase**: time a Bash `true` from tool_use to tool_result in your own transcript.
  It was ~1.0 s at load 25.

## 3. Fix list, in order

Each item: evidence (the investigation's row), fix direction, and when it is done. The directions
are suggestions; the measurement decides.

### P1 — each costs cores or seconds on every call

1. **Fork storm from `worker-pick`.** Evidence: investigation §5.1 "Menubar" and "worker-pick".
   - `hammerspoon/llm-limits.lua` (the store pathwatcher that logs `routing-launch`) runs a full
     `worker-pick` on every store write: about 2 400 times a day, three times within the same
     second, because three module instances are loaded. Coalesce it to one run in flight, drop the
     duplicate instances, and nice the task.
   - `bin/worker-pick` recomputes `worker_model_table` (geminib and grokb) six times per query.
     Compute it once per process, and export `GROKB_MODELS_NO_FETCH=1` as the hooks do.
   - review-bench `accounts.py` side_roster and affordability make up to 8 serial `worker-pick`
     calls per side. Read the table once per launch.
   - Done when fork attribution shows worker-pick well under 100 per 25 s at rest.
2. **Statusline ≈ 2.9 cores.** Evidence: investigation H1.
   - Each session renders every 3 s. A render forks git status, diff, `ls-files --others` twice
     and `xargs grep -cI` over every untracked file, plus jq over the transcript tail. It also
     starts `statusline-work-probe.sh` almost every time (its TTL is 4 s: full `ps`, `lsof`, git,
     jq).
   - First cut the forks that the contract does not require: fewer git and jq processes per render
     (one `git status --porcelain=v2 --branch` in place of several calls; a counted-lines cache
     keyed on untracked file size and mtime is only a cache of file content, not of git state).
     Also a longer work-probe TTL, and no duplicate passes.
   - Anything that makes a segment staler goes to §6.
   - Done when statusline CPU is < 0.5 core at 12 sessions and `tests/test_statusline_hooks.sh`
     passes.
3. **`instruction-watch.sh check` walks the repository on every tool call.** Evidence:
   investigation §2.2-§2.3 and H10.
   - `share/instruction-files.sh` `instruction_repo_files` still runs an unpruned `find` (only
     `.git`, `node_modules` and `worktrees` are pruned). It takes 17-21 s in logo-vectorizer-bench
     (569 507 ignored files).
   - Switch to `git ls-files --cached --others --exclude-standard`, or cache the list keyed on the
     index mtime. Keep the per-call check O(changed files), and write the baseline before the slow
     reporting so that a killed check still makes progress.
   - `bin/instruction-write-gate.sh` calls the same `find` from PreToolUse.
   - Done when a short Bash call in logo-vectorizer-bench has a median ≤ 2 s.
4. **Per-call git snapshots write loose objects.** Evidence: investigation H3.
   - claude-setup `hooks/review-flow-gate.sh` → `hooks/lib/review-journal.sh` `rj_snapshot_content`
     runs `git status --porcelain -uall` and `git hash-object -w` (up to 500 dirty files) for every
     repository in the session's `.repos` registry, on every Bash PreToolUse, `true` included.
     `commit-journal.sh` repeats this after the call.
   - Limit it to repositories the call can touch, batch with `--stdin-paths`, and skip it when the
     status output is unchanged since the last snapshot.
   - Do not delete the objects already written. The review journal reads those blobs back.
     `git prune` or `gc --prune=now` would break its diffs. Packing that keeps them (a cruft pack)
     is fine once you have confirmed the journal still resolves them.
   - Done when the loose-object count stays flat over a working day.
5. **Synchronous hooks with no timeout, or reniced.** Evidence: investigation H2, and the Harness
   doctor's `8 hooks can hold a chat up to 600 s`.
   - `commit-journal.sh` is a synchronous PostToolUse hook with no timeout that renices itself
     to 15. Claude Code waits out a hook with no timeout (measured: 75 s).
   - Give every synchronous hook a timeout that matches its measured p99, and remove `renice` from
     hooks the chat waits on. Heavy work belongs in a detached child, niced there.
   - `context-nudge.sh` (jq over a 1 MiB transcript tail on every PostToolUse, no timeout) is in
     this group too.
   - Done when the Hooks area lists no hook that can hold a chat.

### P2 — seconds per call or minutes per run

6. **PreToolUse gates, ~1 s per Bash call.** Evidence: investigation H9.
   - About 20 gates each start bash, source large libraries (the 2 333-line `review-journal.sh`)
     and fork jq, awk and grep before deciding that `true` is harmless.
   - Add a cheap early exit per gate, in pure bash builtins, for commands the gate cannot care
     about.
   - `dia-not-chrome.sh` still hits its 5 s limit (7 cuts since 16:50Z).
   - Done when the PreToolUse phase of `true` is < 0.3 s at load 25.
7. **review-bench panel preparation.** Evidence: investigation §5.1 "review-bench panels".
   - `share/rbench/integrity.py:104` runs `ls-files --cached --others` without
     `--exclude-standard` and hashes 87 k paths / 835 MB: 35 s + 19 s per frontend panel.
   - Each cell seals its own clone, and each judge pass seals another. Reuse one sealed clone per
     panel.
   - Nice the cells, but keep them parallel.
8. **worker-run launch and claim.** Evidence: investigation §5.1 "worker-run launch/claim".
   - `refuse_live_run` forks one grep per launcher (2.9 s on every start).
   - There is a `hash-object -w` fork per dirty path.
   - `snapshot_other_families` hashes every family at launch.
   - `claim_run` recomputes per path.
   - The `_supervise` loops fork about once a second each (6-16 loops live).
9. **Tests take about 10 h of wall clock a day** (Harness doctor, Tests).
   - Find the slowest groups there: `suites · llm-legs` usual 14 min, `test_review_bench` 5.8 min,
     `test_instruction_gate` 5.5 min.
   - Known: `tests/test_worker_pick.sh` calls the real `worker-pick` about 50 times at 2.3 s each.
     Item 1 shrinks that.
   - Speed tests up by removing repeated setup and slow fixtures, never by weakening an
     assertion. A test change that makes a regression pass is the worst outcome here. Diff every
     test you change against HEAD and state what it still proves.
10. **memlogd** `sync` after every append (`bin/memlogd`; now gated by `sync_writes`, so check the
    live WIP first). Also **review-debt** recomputes without ever caching under load (investigation
    H8), and **chat-find** tail-scans every matched file.

### P3

These are O(history) walks, harmless today; the list is in investigation §3 ("Further confirmed
claims") and the P3 lines of §5.1. Fix one only if it is on a path you already touch.

## 4. Looks bad, is fine: do not touch

| what you will see | why it is not a problem |
|---|---|
| Opus 5.5 decode 10-15 % slower since 09-23 | Anthropic's side, identical on every account; no local change affects it (investigation §1) |
| Harness doctor `Slow periods`: ~20 h slow in the last 24 h; Waits rows at 11 s over 24 h | the 09-22..09-28 incident, fixed at 16:50Z when the instruction-watch timeouts went 10 → 60 s; it ages out of the 24 h window |
| 4 706 PostToolUse cuts "which hook is unknown", 72 SessionStart `instruction-watch baseline` cuts | the same incident; 0 SessionStart cuts since the fix |
| `commit-report` at 6.6 s (a `watch`) | it runs only on the ~12 Bash calls a day that commit; the doctor keeps it at watch on purpose |
| `peak today: 4 suite runs at once` | `run-suites` runs ncpu/2 = 5 suites by design; do not add a cross-chat queue (§1) |
| kernel share 30-40 % | the cost of process creation (syspolicyd, trustd, tccd, kernel_task); it falls when forks fall, so never tune it directly |
| transcripts 3.2 GB, review benches 2.8 GB | big, but off the hot path; never delete them, they are history other tools read |
| `~/.cache/claude-instruction-watch/reverts`, 159 k entries / 1.3 GB | recovery data that expires on its own weekly schedule; deleting it is the owner's call |
| review cells' local overhead | 1-15 s per cell and flat since 09-15; a cell's wall time is its API time |
| "a cancelled hook leaves its children running", "hooks run sequentially", "a global 10 s cap" | tested and disproved (investigation §3, "Claims tested and not reproduced") |

## 5. Unknown: measure before touching

- **Hooks that print nothing.** Their time is invisible (Harness doctor blind spot 1). If a fix
  needs per-hook numbers, build the per-hook journal first, as `docs/harness-doctor-design.md` §8
  describes, then extend `bin/harness-doctor` to read it.
- **The 09-04..09-15 episode** (investigation §5). It was per repository, and scratch paths stayed
  fast. Suspects: `instruction-watch.sh check` and `commit-journal`. Items 3 and 4 may already
  cover it. Check the claude-setup and llm-legs history of 09-04 and 09-16 before claiming that.
- **Why a worker finishes late.** Nothing measures spawn, relay or supervise time today.

## 6. Bring to the owner, with a cost and a recommendation

- Any change to `docs/statusline-contract.md`: a render cache for git state, a longer
  `refreshInterval`, or dropping a segment.
- Deleting or repacking anything with unreachable objects, the `reverts` directory, or any store
  in §4.
- Changing a trigger phrase or a gate's decision. A speed fix may change how fast a gate decides,
  never what it decides.

Give each one as a trade: one line on what the change costs, one line on what staying as-is
loses, then a recommendation.

## 7. Report

Open with the table from §0, holding before and after values for every row. Then list, per
item: fixed / already fixed / not reproduced / left, with the files changed, the test that covers
it, and the measurement. Then the §6 asks. Nothing is committed; say which repositories hold your
uncommitted changes.
