# Hand-off: why every tool call took 10 s, and what else slows the machine

For whichever chat fixes the hooks, the statusline and the doctor. Written 2026-09-28 by the chat that
investigated the Opus 5.5 slowdown and changed nothing: no hook, setting or state was
edited here. Every number below was measured on 2026-09-28 unless it says otherwise, and every
claim carries the command that reproduces it. Review rounds behind it: T2 double
`20260928T172315Z-7cc945f` (hot path, judged: 62 confirmed), T2 frontier `20260928T172337Z-7cc945f`
(hot path, classified by this chat), T2 frontier `20260928T172357Z-0aa0f24` (workers, review,
daemons; see its section). `review-bench findings <run-id>` lists each round's claims.

Scratch scripts used below live in this chat's scratchpad and are not part of the repository; each
is short enough to rewrite from its description.

## 0. Verdict in one paragraph

Opus 5.5 did get slower on Anthropic's side, by 10-15 % of decode speed, and no local priority
changes that. That is not what Egor felt. What he felt is local: from 2026-09-22 18:10Z to
2026-09-28 16:50Z a trivial tool call (Edit, Write, `ls`, `git status`) took a median 10.3-11.7 s
instead of 2-3 s, and 63-97 % of those calls ended with a PostToolUse `hook_cancelled`. The hook
was `instruction-watch.sh check`, whose 10 s timeout it exceeded after a live worker edit widened
its watched set. The LLM-doctor menu refactoring chat raised that timeout to 60 s at
16:50:27Z; cancellations dropped to 0 % at once. The underlying cost is still there. In
`logo-vectorizer-bench` a trivial call now takes a median 40 s (p90 98 s), because the check walks
that repository's 569 507 ignored files on every call. Behind it all sits a machine that is 80-100 %
busy, 38-44 % of it in the kernel, with 1 300-1 800 new processes per second. The statusline alone
takes about three of the ten cores.

## 1. Opus 5.5 API speed (Anthropic's side, not fixable here)

Per-call decode speed from transcripts: output tokens over the time from the parent entry to the
message's last block, split by content type so thinking-heavy calls are not compared with
tool-only ones.

| content | 09-23/24 median | 09-26..28 median |
|---|---|---|
| hidden thinking | 100-101 tok/s | 89.6-92.6 |
| write/edit tool input | 124-139 | 110-121 |
| other tool input | 122-124 | 106-114 |
| text | 98-99 | 87-95 |

- The drop is the same on all three Claude accounts. review-bench Opus cells fell from 90-92 to
  64-69 output tok per API-second. Sonnet 5 fell from 107-119 to 81-88.
- A/B on the live API: `nice 20` against `nice 0`, at load 94-140, `claude -p` streaming 150 facts.
  Decode speed was identical. Under load only the client's start-up grew, from 6-8 s to 31 s.
- Nothing here tracks API speed per model per day (see §7).

## 2. Root cause of the 10 s calls: `instruction-watch.sh check` (P1, confirmed, reproduced)

### 2.1 Timeline

| when (UTC) | what |
|---|---|
| 09-22 18:08-18:52 | A worker (round `20260922T173322Z-1e2f504`, fixing instruction-hook bypasses) edits `share/instruction-files.sh` in the shared checkout. The hooks run that working copy through the `~/.claude/hooks` symlinks, so the edit is live for every session at once. `instruction_visible_paths` gains `instruction_repo_files` (a `find` over the session's repository), and `instruction_guarded_dirs` makes every markdown file under `~/.claude` guarded. The watched set grows to about 396 files. Committed 09-23 as `3d21a1f`/`fe45614`. |
| 09-22 18:10 | Step change. Trivial-call median goes 2.9 s → 10.1 s, and cancellation goes 0 % → 52-86 %. It hits Claude Code 2.1.278 sessions as well as 2.1.280 ones, so the CC version is not the cause. The 2.1.280 sessions were at 2-4 s from 17:10 to 18:00. |
| 09-22..09-28 | 26 471 PostToolUse `hook_cancelled` in the transcripts. SessionStart `instruction-watch.sh baseline` timed out at 10 000 ms 469 times, on every start. |
| 09-23..09-26 | 159 511 revert copies (1.3 GB) pile up in `~/.cache/claude-instruction-watch/reverts`: 39 k on 09-23, 70 k on 09-24, 35 k on 09-25, 15 k on 09-26. The per-report copy name was fixed on 09-27 (`0b9f4f2`), but the directory still holds them all. |
| 09-28 16:50:27 | The LLM-doctor menu refactoring chat raises both instruction-watch timeouts 10 → 60 in `~/.claude/settings.json`. `settings.json` is not versioned; its copy from before the change is `/private/tmp/claude-501/-Volumes-Work-Projects-hammerspoon/4f5701f9-0bcd-402c-8fac-1be8a0677d56/scratchpad/settings.before.json`. |
| after | PostToolUse cancellations 0 %. Trivial-call median by project: llm-legs 2.6 s, review-bench 4.6 s, logo-vectorizer-bench **39.8 s (p90 97.6 s, several over 60 s)**. |

The cancelled hook is not named in the PostToolUse attachment; Claude Code's wrapper re-yields it
without `command`. It was pinned three ways:
1. The step and the recovery line up to the minute with the two edits above.
2. `settings.before.json` shows `timeout: 10` on `check`, and the only other 10 s PostToolUse hooks
   (`word-spend.sh`, `report-flush.sh`) time at ≤ 1.1 s.
3. No other change happened at 16:50Z.

### 2.2 Mechanism

- **Per-call cost.** `cmd_check` loops over every watched file in bash: 21 118 trace lines and about
  0.5 s of CPU per call, even when nothing changed. It also runs `visible_paths`: a `find -L
  ~/.claude` (0.05 s, cheap) plus `instruction_repo_files` over the session's repository. That
  `find` prunes only `.git`, `node_modules` and `worktrees` and ignores `.gitignore`.
  Reproduce: `bash -c 'source /Volumes/Work/Projects/llm-legs/share/instruction-files.sh; time instruction_repo_files /Volumes/Work/Projects/logo-vectorizer-bench'`
  gives 17.3 s at load 27 (21 s for the bare `find`). The same call is 0.02-0.07 s for llm-legs,
  claude-setup, review-bench and hammerspoon. logo-vectorizer-bench holds `tracers/` 348 k,
  `sets/` 88 k, `out/` 70 k and `report/` 49 k entries, all ignored.
- **Self-sustaining loop.** `cmd_check` reports and calls `keep_revert` while it scans, and writes
  the new baseline only at the end (`bin/instruction-watch.sh:887` and `:919`). A check killed by
  the timeout never advances its baseline, so the next call redoes the whole change handling:
  reports, hashes, copies. That is how one changed agent file (e.g. `codex-worker.md`) became 12 801
  copies.
- **Baseline never written.** `cmd_baseline` runs `visible_paths` at least three times plus stat,
  shasum and cp of every file. It hit the 10 s cap on 100 % of starts. The check then takes
  `mode=missing` with a key unique per call (`missing@$$.$(date +%s)`, `:713`), so every call is a
  fresh alert. llm-doctor's Guards row shows 12 «tripwire baseline missing» today.
- **Now, with 60 s.** Checks finish, so the loop is broken wherever the check fits in 60 s. In
  logo-vectorizer-bench, though, every tool call waits 17-60 s for the `find`. Every session start
  there waits for three of them, up to the 60 s cap.

### 2.3 What a fix must cover (for the fixer, not done here)

- Keep the per-call path O(changed files): stat-compare against the baseline, and list the
  repository's instruction files with `git ls-files` (tracked plus untracked-not-ignored) or a cache
  keyed on the index mtime. Never an unpruned `find`.
- Write the baseline before the slow reporting, or per file, so a killed check still makes progress.
- The 159 k-entry `reverts` directory stays until its week expires. Its hourly prune `find` stats
  every entry; `python3 -c "import os;print(sum(1 for _ in os.scandir('$HOME/.cache/claude-instruction-watch/reverts')))"`
  takes 8.5 s. Deleting it is Egor's decision; it is recovery data.

## 3. Other confirmed costs on the hot path

Severity is by effect on the agent loop's wall time or the machine's load. «Measured» means this
chat ran it; «panel» means a judged review claim that was not re-measured.

| # | where | mechanism | trigger / cost | status |
|---|---|---|---|---|
| H1 | `bin/statusline.sh`, statusLine `refreshInterval: 3` | Each session re-renders every 3 s whether or not anything changed. A render forks git (status, diff --numstat, ls-files --others twice, `xargs grep -cI` over every untracked file), jq over the transcript tail, and detaches `statusline-work-probe.sh` (cache TTL 4 s, so almost every render: full `ps -axo`, lsof, git, jq) and `statusline-ports-probe.sh` (15 s: `ps`, user-wide `lsof -iTCP`). | Measured: 114 top-level renders in 30 s with 12 claude processes, i.e. 3.8/s. One render is 0.74-0.79 s CPU (0.24 user + 0.52 sys), probes not included. That is **about 2.9 of 10 cores, continuously**. In logo-vectorizer-bench the untracked-line count alone is 0.5 s per render (5 325 files). | P1 measured |
| H2 | `claude-setup/hooks/commit-journal.sh:5` | `renice -n 15 -p $$` on a synchronous PostToolUse hook that has **no timeout** in settings. Claude Code waits out a hook with no timeout for at least 75 s (synthetic test: `sleep 75`, no `timeout` field, calls took 75.7 s and 75.4 s), and the binary's default looks like 600 000 ms. At load 50+ a nice-15 process waits behind everything else. | Measured 3.1 s on one call at load 25; one instance seen alive 9 min; 107 distinct PIDs (subshells included) in 20 s. | P1 measured |
| H3 | `claude-setup/hooks/review-flow-gate.sh:402` → `hooks/lib/review-journal.sh` `rj_snapshot_content` | Every Bash PreToolUse, `true` included, runs for every repository in the session's never-pruned `.repos` registry: `git status --porcelain -uall`, stat of every dirty path, and `git hash-object -w` of up to 500 dirty files. `commit-journal.sh` repeats it after the call. | Measured side effect: logo-vectorizer-bench `.git/objects` holds 16 408 loose objects (1.09 GiB, 0 packs) for a repository with 12 tracked files, all written by these hooks since 09-25; llm-legs has 8 059 loose objects (208 MiB) against 23 MiB packed. `git -C <repo> count-objects -vH`. llm-doctor Debt: «hash-cap in logo-vectorizer-bench seen 1409×». | P1 measured |
| H4 | process creation, machine-wide | 1 278-1 785 new processes per second. Every exec also costs syspolicyd (~9 % CPU), trustd (~4.5 %), tccd (~3.7 %) and kernel_task (23 %). CPU split 45-57 % user, 38-44 % sys. | Measured: `a=$(sh -c 'echo $$'); sleep 10; b=$(sh -c 'echo $$'); echo $(( (b-a)/10 ))/s`. Fork attribution over 25 s (nearest script ancestor): worker-pick 822, statusline.sh 815, worker-run 553, bare bash 346, launchd 304, review-debt 252, statusline probes ~170. | P1 measured |
| H5 | `bin/worker-pick` in test suites | One call is 2.2-2.4 s wall and 1.7 s CPU (0.66 user + 1.06 sys). `tests/test_worker_pick.sh` called it 50 times in 60 s, from two concurrent suite runs of other chats. | Measured | P2 |
| H6 | `share/run-suites.sh:74` | Each invocation runs hw.ncpu/2 = 5 suites in parallel, and nothing caps the total across chats and workers. It renices to 10, but the chat waits on the result. | Panel; three suites seen live at once | P2 |
| H7 | `hooks/context-nudge.sh:176` | A 1 MiB transcript tail goes through `jq -f context-size.jq` on every top-level PostToolUse; no timeout is set. | Panel; context-nudge timed at 256-316 ms in this chat's own hook_success rows | P2 |
| H8 | `bin/review-debt` via `review-flow-gate.sh verdict` from the statusline | The per-session verdict cache has a 15 s TTL and is invalidated by any review-anchors touch in the family. review-debt writes its cache only after a full compute, and the verdict path kills it at 8 s, so under load it recomputes without ever caching. The repo pass (`--repo`) runs under `timeout 60`. | Measured: `review-debt --repo` processes seen at 59 s of age; a cache hit is 0.08 s. Recompute-without-cache is panel-plausible, not reproduced. | P2 |
| H9 | `bin/worker-launch-gate.sh`, `bin/review-owner-gate.sh`, `hooks/english-gate.sh`, `hooks/dia-not-chrome.sh`, `bin/instruction-bloat-gate.sh` | About 20 PreToolUse Bash gates each start bash, source large libraries (the 2 333-line `review-journal.sh`) and fork jq, awk and grep before deciding that `true` is harmless. | Measured: the PreToolUse phase is ~1.0 s per call at load 25. Timeouts seen: English gate at 10 s (91 times since 09-18), dia-not-chrome at 5 s (71 times). | P2 |
| H10 | `bin/instruction-write-gate.sh:99` | Any Bash command mentioning `.md` or `.claude/` runs `instruction_all_paths`, which includes the same repository `find`, synchronously in PreToolUse. In logo-vectorizer-bench that is 17+ s. | Inferred from §2; not timed separately | P2 |

Further confirmed claims, mostly O(history) growth that is cheap today (P3): Stop hooks that
walk every worker-run directory (`worker-run-backstop.sh:72`, `stop-dispatch.sh:123`,
`ask-run-unfinished.sh`); `chat_names.py` parsing whole transcripts on every Stop; the
`words_journal.py` full-journal reads; `review-anchors` store growth (runs never removed, gaps files
never rotated, slow git work under the family lock); `benches_mark` stat of ~2 740 files on every
review-debt call; `session-trash.sh` sweeps after every session end; `memory-prune.sh` making up to
ten serial `gh pr view` calls. The full list is in the two hot-path rounds.

### Claims tested and not reproduced

- **«A cancelled hook leaves its children running»** (panel F62 and variants). Claude Code 2.1.283
  kills the hook's process tree at the timeout. Synthetic hook `bash -c '(sleep 40) & sleep 40'`
  with timeout 3: both processes were gone at 3 s. Only a hook that detaches on purpose
  (`nohup`, `( … & )` with redirected stdio, `setsid`) outlives it, e.g. `session-trash.sh`
  `__purge-delayed` and the statusline probes.
- **«Hooks run sequentially» / «a global 10 s cap»**: disproved. Two 3 s hooks cost 3 s; a 15 s
  hook with timeout 60 costs 15 s; a hook with no timeout is waited out for 75 s.
- **«The rg fallback starts a node runtime»** (`share/chat_names.py:124`): false. The claude binary
  answers `rg --version` in 0.01 s.
- **«`find -L ~/.claude` is the expensive part»**: it visits 5 380 entries in 0.05 s. The repository
  `find` and the bash loop are the cost.

## 4. Load that is not hooks

Snapshot during the investigation (load 34-140; 18-32 at the end):
- `logo-vectorizer-bench` `holdout.py --jobs 8` (another project, nice 5, 27+ min).
- 6-16 `worker-run _supervise` loops, each forking about once per second (213 worker-run PIDs in
  30 s for 6 loops).
- 2-3 concurrent test suites (test_worker_pick, test_worker_run, review-bench's suite).
- 5-18 review-bench cells per panel (3 panels ran during this investigation).
- An orphaned `statusline.sh` lived up to 58 s.
- Reported by a peer chat and not re-measured here: the 16:39 reboot on 09-28 was a machine freeze
  caused by six parallel test suites from one chat. The worker runs llm-doctor shows as «crashed ·
  supervisor gone» (V7) are those reboots and the one at 00:10.
- The grok47 review cells of this investigation's three panels failed on «auth». The cause is the
  `--uncapped` 6 h ceiling, which outlived a grok token. review-bench now caps it at 2 h and by the
  token's lifetime (uncommitted in review-bench, `cell_runtime.uncapped_timeout_s`).

## 5. Workers, review system and daemons

Measured from `raw-<cell>.json` (`duration_ms − duration_api_ms`) and the transcripts:

- **Review cells hardly feel the hooks.** A cell's local overhead has a median of 1-15 s per cell
  and 0.1-0.8 s per turn on every day from 09-15 to 09-28, with no step on 09-22. A cell's wall
  time is its API time, so the cells slowed down only by §1.
- **Headless workers (`sdk-cli`) paid the full §2 cost.** Their trivial-call median was 2.5-3.2 s
  from 09-16 to 09-22 and 10.3-11.2 s from 09-23 to 09-28, over 250-1 250 such calls a day.
- **The slowdown before §2.** The trivial-call median grew from 0.1-0.3 s in early August to
  0.8-2.2 s by 09-02 and 3-4 s by 09-10, as hooks were added. One earlier episode is
  unexplained: 09-14 and 09-15 medians of 17-19 s (interactive) and 7.6-11.4 s (headless) with
  almost no cancellations, back to 1.5 s on 09-16. It does not match §2 and was not investigated.
- **That episode was per repository and lasted 09-04..09-15.** The Harness doctor's 28-day backfill
  (`~/.cache/harness-doctor/days/*.json`, unattended trivial Bash only, days with ≥ 20 calls)
  shows llm-legs at 5.3 s on 09-04, 8.4 on 09-05, 10.5-12.7 on 09-07..08, 14.6-15.1 on 09-10..11
  and 52.9 s on 09-15. review-bench was at 13.4-13.9 s and claude-setup at 6.7-9.7 s on
  09-12..15. Meanwhile scratch directories (`tmp`) stayed at 1.5-3.8 s. Every project dropped to
  1.4-1.7 s on 09-16 and settled at 3-3.8 s from 09-17. A cost that grows inside a few
  repositories while scratch paths stay fast has the shape of today's logo-vectorizer-bench case: a
  per-call hook that walks the repository. Suspects to check against the claude-setup and llm-legs
  history of 09-04 and 09-16: `instruction-watch.sh check` and `commit-journal`.

### 5.1 Speed hunt over workers, review panels and daemons (T2 frontier `20260928T172357Z-0aa0f24`)

Classified by a worker on the chat's behalf and recorded with `review-bench record`. Both cells
found both P1s: fable-high chunked (33 chunks, 108 min) and astra-high unchunked (51 min). fable
alone added 2 P2 and 49 P3, and astra alone added 1 P2 and 10 P3. The grok cell failed on auth.
341 verdicts: 122 confirmed (P1 2, P2 18, P3 102), 124 false_positive, 95 duplicate. Judged against the reviewed blobs; measured at load ≈7.

### Menubar (llm-limits.lua / instruction-watch.lua)
- **P1** `hammerspoon/llm-limits.lua:2815` — store pathwatcher runs a full `worker-pick` (0.6–1.4 s, 6× worker_model_table → geminib/grokb) on every store write: 2386 routing launches today, in triplicates within the same second (3 module instances). Fix: coalesce to one in-flight run, dedupe module instances, nice the task.
- **P2** `hammerspoon/instruction-watch.lua:935` — refreshInflight rescans closed/+inflight/ on every FSEvents callback. Fix: gate on events under the journal dirs only.
- P3: unthrottled model-toggle watcher (:2820), un-niced menu tasks (:837), blocking io.popen scans (instruction-watch.lua:486).

### review-bench panels
- **P1** `share/rbench/integrity.py:104` — the inventory lists ignored files (no `--exclude-standard`) and hashes them: 87k paths / 835 MB, 35 s + 19 s per frontend panel. Fix: exclude-standard plus prune worktree trees.
- **P2** `launch.py:2371` — every cell seals its own full clone (8 git forks + fetch). Fix: one sealed clone per panel, per-cell overlay.
- **P2** `cli.py:1384` — all 5–18 cells start at once at normal priority. Fix: nice/taskpolicy the cells, keep them parallel.
- **P2** `judge.py:414` — each judge pass seals and destroys its own clone. Fix: reuse the panel clone.
- **P2** `accounts.py:1432`, `:637` — side_roster/affordability run up to 8 serial `worker-pick` calls per side. Fix: one table read per launch, parsed in-process.
- P3: per-pass `_prepare_runtime` (launch.py:743), per-file git forks in chunking (scope.py:1494), agy keychain forks (cell_runtime.py:181), verify cold starts and a geminib orphaned on timeout (verify.py:436/452).

### worker-run launch/claim
- **P2** `bin/worker-run:2006` — refuse_live_run forks one grep per launcher: 413 runs, 2.9 s on every start. Fix: one `grep -l` over all launchers, or a live-run index.
- **P2** `bin/worker-run:1299` — a `git hash-object -w` fork per dirty path. Fix: batch with `--stdin-paths`.
- **P2** `bin/worker-run:4432` — snapshot_other_families hashes every family in `.repos`/`--add-dir` (14–17 repos) at launch. Fix: only the touched families, batched.
- **P2** `bin/worker-run:4158` — claim_run recomputes snapshot_changed_paths per claimed path. Fix: compute once per claim.
- P3: watchdog re-parse/find (:335, :455), un-niced Light VERIFY that kills only the wrapper (:1884), wait-loop forks (:3783).

### worker-pick
- **P2** `bin/worker-pick:165` — every model/effort lookup re-runs worker_model_table (geminib+grokb), 6× per query. Fix: compute the table once per process.
- **P2** `bin/worker-pick:129` — no `GROKB_MODELS_NO_FETCH=1`, so grokb may fetch live. Fix: export it as the hooks do.
- P3: all four vendors computed for a single-vendor query (:251).

### review-debt (statusline background)
- **P2** `share/rbench/debt.py:747` — an uncached `review-debt --repo` takes 1.34 s (570 anchors); **P2** `:859` forks one `review-anchors anchor` per blob. Fix: batch anchoring in-process; widen the cache.
- P3: numstat fork per pair (:712), serial doctor rows (:1191), double hashing (store.py:1580).

### memlogd / chat-load
- **P2** `bin/memlogd:116` — sync(2) after every append (every 15 s, 2–4 Hz under pressure). Fix: drop the sync, or fsync the log fd only.
- **P2** `bin/chat-load:295` — chat-name subprocess inside the tick (**already fixed in live WIP: in-process namer**).
- **P2** `bin/chat-load:260` — relief waits on every report-bus notice before the first SIGKILL. Fix: kill first, notify async.
- P3: Interactive ProcessType (`launchd/com.egor.memlogd.plist:18`); 5–8 forks + python + full ps per tick.

### chat-find / chats
- **P2** `bin/chat-find:225` — search tail-scans every matched file (6.2 s even with --days 1). Fix: cap the rescan and reuse the 512 KB window.
- P3: `chats --open-command` takes 1.2 s; chat-find children are orphaned.

### claudeb / llm-doctor / llm-refresh (all P3)
- claudeb: rc=255 retried as weather (:1329), per-launch ledger harvest, double keychain lookup.
- llm-doctor (3.4 s): open_gaps 0.94 s, worker_legs 0.7 s, bench_legs 0.6 s; launched un-niced from the menu (:1941).
- llm-refresh: serial collectors (:270); the OpenCode wall check holds the heartbeat (:337).

Not realistic (fp): the vendor-CLI fallback on catalog import (both caches present and usable), the eager rbench import (54 ms), the progress reaper (dir empty), and test-history (deleted in WIP).


## 6. What is tracked today

| source | what it measures | blind to |
|---|---|---|
| llm-doctor legs (`mark_slow`) | a leg slower than 2× the median of the last 20 comparable legs in 7 days, and ≥ 30 s over | Relative and self-absorbing: a step change becomes the new baseline after ~10 legs. Shown as «weather», never a bug; today it says «weather slow [opus] 13» for workers and 5 for reviewers. |
| llm-doctor Hooks | Stop-hook errors and asks, word-journal notices | Hook latency, hook timeouts, PreToolUse/PostToolUse entirely |
| llm-doctor Guards | «tripwire baseline missing», instruction growth | Shows the symptom of §2 (12 rows today) as a guard problem, not as a speed one |
| llm-doctor Debt | review gaps, hash-cap | none relevant |
| worker-stats / bench `raw-<cell>.json` | per-cell `duration_ms`, `duration_api_ms`, `modelUsage` | Local overhead is only derivable (duration − API); never surfaced |
| test journal (`test-history.jsonl`, now read by the Harness doctor's Tests section) | per-test wall time, fed by `statusline-work-probe.sh` | Machine state during the test |
| Harness doctor (built 2026-09-28, `docs/harness-doctor-design.md`) | §7 items 1, 4 (sampled by the collector, not memlogd) and 5: loop latency per project, cuts with PostToolUse attribution, printed hook times, CPU/kernel/fork rate, memory, test wall time, growth, steps against a change log | Hooks that print nothing, statusline cost, MCP and worker spawn (its `not measured yet` row) |
| memlogd | available memory, swap, node count and RSS; 3-day retention | CPU, load, sys %, fork rate, disk |
| chat-load | per-chat CPU from `ps time` deltas of processes alive across ticks | Short-lived forks, i.e. almost all hook and statusline cost: it showed 2.6 of 10 cores while the machine was at 0.4 % idle |
| gate journals (`share/gate-journal.sh`, stop journal) | decisions | Duration, timeout, cancel |
| Claude Code transcripts | `hook_cancelled` (PostToolUse without the command name; other events with command and `durationMs`), tool_use/tool_result timestamps, `usage`, `turn_duration` | Nothing reads them for speed |

## 7. What to track (each would have caught 09-22 18:10Z within the hour)

1. **Loop latency from transcripts.** No new instrumentation is needed. Every hour, per project:
   the median time from tool_use to tool_result of trivial calls (Edit, Write, Bash `ls|cat|true|git
   status`), the share with a PostToolUse `hook_cancelled`, and the SessionStart hook timeouts by
   command. A doctor row turns red when the median exceeds 3 s or the cancel share exceeds 5 %. The
   scan over 3 days of transcripts takes about 60 s with 6 processes, so run it incrementally by file
   offset.
2. **Per-hook wall time.** One line per hook run (`hook, event, session, start, ms, exit`) from a
   thin wrapper in settings.json, or from each hook's `EXIT` trap. It is the only way to name the
   PostToolUse hook Claude Code cancels.
3. **API speed per model per day.** Output tokens per streaming second, split by content type, from
   the same transcript pass. It separates «Anthropic got slower» (§1) from «we got slower» (§2) in a
   single glance.
4. **Machine pressure in memlogd.** Load average, CPU user/sys/idle (`top -l 1 -n 0`), and process
   creations per second (the PID delta of a fresh `sh -c 'echo $$'` per tick, allowing for
   wrap-around). Keep 14 days, not 3.
5. **State growth.** File counts and bytes of `~/.cache/claude-instruction-watch/reverts`,
   `~/.cache/claude/review-debt/gaps`, `worker-stats/benches`, the claude-worker-runs root, and
   loose git objects per repository, with a threshold alarm. A daily cron-free check in llm-doctor
   is enough.
6. **Statusline cost.** Renders per minute machine-wide and CPU per render; the work probe already
   exists and could journal both.
