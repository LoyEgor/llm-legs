# Hand-off: what the harness doctor did not see on 2026-09-29, and the classes it should cover

Status: done 2026-09-29 — hook-every-call-context-nudge, floor-trivial-bash-readonly-fastpath (class K `--bench` left out, recorded in docs/harness-doctor-design.md §8)

For the chat that owns `bin/harness-doctor` (design: `docs/harness-doctor-design.md`). Written
2026-09-29 by the chat that cut hook latency the same day in claude-setup and llm-legs hooks. That
chat changed nothing in `bin/harness-doctor` for this; every item below is the doctor's to decide.

## 0. The ask

Egor's goal is coverage: every case like the ones below should be caught, including cases nobody
has named yet. So treat each class in §2 as an idea to develop, not a single bug to patch:

- find every current instance of the class in the system, not only the one named here;
- build the signal;
- or record in the design's §8 why it stays a blind spot.

He does not want to pick the items himself. Judge what matters, and say what you left out and why.

## 1. What happened today, and what saw it

| problem | who noticed | what the doctor showed | why it stayed quiet |
|---|---|---|---|
| Every Bash call waited ~0.6 s on hooks. The Pre floor was ~260 ms (`review-flow-gate` snapshots every repository in the session's registry). The Post floor was p50 353 / p95 677 ms (`instruction-watch.sh check`). | a chat investigating on Egor's word | dim hook rows | the hook limit is p50 > 1 s; the trivial Bash wait limit is 3 s / 5 s. Both are calibrated to the 10 s incident, not to a sub-second cost per call. |
| `context-nudge.sh` cost 89 ms p50 on every call of every tool (a 1 MiB transcript tail through jq) | the 09-28 speed investigation (H7), from `hook_success` rows | a dim row, largest daily Total | nothing weighs a hook that runs on every call |
| `worker-launch-gate.sh` cost 185 ms p50, and ~20 other Bash gates each start bash and source libraries before deciding `true` is harmless (H9) | the investigation | dim rows | same as above; hooks on one event run in parallel and the slowest sets the wait, yet no row shows that wait |
| ~47% of Bash calls provably write nothing, yet got the full snapshot and tripwire (measured over 59 166 real commands) | this chat | nothing | the doctor cannot tell work a hook needs from work it wastes |
| The Hammerspoon Automation menu was slow to open (fixed earlier today in `config_reload.lua`) | Egor himself | nothing | design §8 blind spot 5 (Hammerspoon's own tasks) |
| The Harness doctor's own Tests row stayed red after the suite passed | Egor | a false red | a rule without a tested clearing path (fixed earlier today) |
| Failures under load, 17:38–18:04 local, three `tests/run-all` at once (claude-setup, llm-legs, review-bench, each `-j 5`). llm-legs `test_claudeb.sh` and `test_worker_run.sh` failed and passed alone at 18:04–18:15. review-bench `test_review_anchors.sh` failed once in an earlier concurrent run and passed alone. | this chat | nothing: `test-history.jsonl` rows are `{end, secs, who, repo, label}`, with no pass/fail | the writer records no outcome |
| This chat's own semantic mistakes: the tripwire read command text, against invariant `br`; review-journal tests broke on read-only placeholders | `tests/test_consistency.sh`, the suites | – | this side works; do not duplicate it in the doctor |

Per-call numbers, read-only Bash (p50, ms, before → after):

| hook | before | after |
|---|---|---|
| review-flow-gate | 264 | 36 |
| worker-launch-gate | 222 | 29 |
| commit-journal | 246 | 36 |
| instruction-watch check (live p50 was 353) | 201 | 39 |
| context-nudge (every call of every tool) | ~92 | ~54 |

Writing calls:
- review-flow-gate ~220 ms, unchanged: the snapshot is needed.
- instruction-watch check went from ~190 to ~140 ms.

What changed, for reference:
- the classifier `claude-setup/hooks/lib/readonly-command.sh`;
- its skips in `review-flow-gate.sh`, `commit-journal.sh`, `instruction-write-gate.sh` and `worker-launch-gate.sh`;
- the tripwire now skips only on the gate's note `~/.cache/claude-instruction-watch/readonly/<sid>@<tool_use_id>`;
- context-nudge reads a 64 KiB tail first;
- in instruction-watch, `load_baseline` and the batched `realpath`.

**Calibration data.** The hook journal keeps 3 days, so a copy sits in
`~/.cache/harness-hook-calibration-2026-09-29/`. It covers 09-29 from 00:05 to 18:26 local:
- before 16:00: clean before-data;
- 16:30–17:50: the changes going live;
- from 18:00: clean after-data.

## 2. Classes to cover

The design's rule stands: limits are absolute, never a self-adjusting baseline. When a step crosses
a limit, the cause line and the change log name it.

**A. What a call waits on hooks: the floor.**
- Per tool call and per event, take the max over the hooks that ran together. Pre floor plus Post floor is the wait the chat pays.
- Batch reconstruction, used today: journal lines with the same ppid whose starts lie within ~30 ms are one event.
- Report per tool, with Bash split trivial/non-trivial as the Waits area already classifies it. Name the hook that set the floor most often.
- Evidence: ~600 ms per trivial Bash call before, ~110 after.
- Suggested bands, to calibrate on the preserved journal: trivial Bash note > 150 ms, red > 300 ms.
- Cover every event group, not only Bash: UserPromptSubmit, Stop, SessionStart, and Edit/Write/Read.

**B. Hooks that run on every call.** A hook matching `*`, or every write tool, multiplies its median
by the whole call count. context-nudge is today's case.
- Rank by p50 × calls/day.
- Add a note band, e.g. > 50 ms, for a hook on every call.

**C. Full work on calls that cannot need it.**
- Compare a hook's time on trivial or read-only calls with its time on the rest. Equal times mean it does the full work for nothing.
- A journal line carries no call identity. Either join batches to the transcript's tool_use timestamps (the collector already parses them), or add the tool_use_id to hook-time's line (contract row `da`).

**D. Silent fallbacks that cost speed.**
- Four hooks skip work only when `readonly-command.sh` loads. They source it with `2>/dev/null`, so a broken or missing lib silently puts every call back on the full path.
- Probe it in the collector: after sourcing the lib, `rc_readonly_command ls` must return 0 and `rc_readonly_command 'rm x'` must return 1; red otherwise.
- Then look for the same shape in other hooks: an optional fast path behind a quiet `source … 2>/dev/null &&`.
- context-size.jq's own `libdown` notice in context-nudge is the good example.

**E. Creep under the 1 s limit.**
- The 1 s limit is for hangs. Add a lower absolute band for synchronous tool hooks, e.g. note > 150 ms, and let the change log attribute the step.
- The `<W> vs prev <W>` Δ already tones a slower hook from 10 %, but it needs 20 runs, and it is a view, not an alarm.

**F. Cost that grows with history.**
- Candidates:
  - review-flow-gate walks the session's never-pruned `.repos` registry (H3);
  - context-nudge's sidecar reads the whole transcript on its first scan (this session's transcript was 21 MB);
  - Stop hooks over transcripts (the speed investigation's P3 list).
- Signal: a hook's p50 split by session age or transcript size (ppid → session through the chat registry), or by registry size.

**G. State left by skipped or aborted calls.** Add these to Growth:
- `~/.cache/claude-instruction-watch/readonly/` (new today). A read-only call that exits non-zero gets no PostToolUse, so its empty note stays until the session-start sweep after 24 h.
- `inflight/` and `closed/` there.
- `~/.cache/claude/review-journal/*.hashes` and `*.ref`.
- `~/.cache/claude-context-nudge/`.
- `~/.cache/harness-doctor/hooks/spool` (bash 3.2 lines): 152 files this evening. Check that this is expected and drains.

**H. Failures that depend on load.**
- Record pass/fail in the test history; the writer is `bin/statusline-work-probe.sh`.
- Flag a test that failed while ≥ N suites ran and passed alone within the hour. Today's rows in §1 are the fixture.
- Also check whether "suite runs at once" went red for 17:38–18:04, when up to 15 suites ran at once.

**I. Surfaces Egor reads directly.** The Hammerspoon menus (open/build time) are his single source of
truth, and today he found the slow one himself. Close blind spot 5 for at least the menu.

**J. Every red needs a tested way back.** A fixture per rule in which the condition clears and the
row returns to normal. Today's stale Tests red is the case.

**K. Optional, for the next investigation: a drill-down.**
- Today needed ad-hoc tools:
  - replay a captured payload through one hook N times (p50/p95);
  - a paired Pre→Post replay with one tool_use_id;
  - per-phase timing with timestamped `PS4`.
- A `--bench <hook>` mode would make that minutes of work, not hours.
- Hooks never execute the command, but they write state under the session id. Use a throwaway id and clean the dirs in G afterwards.

## 3. Keep as it is

- The hook journal (row `da`): every number above came from it.
- The "outside the journal" list.
- The cut attribution (§3.1).
- The absolute-limit rule.

## 4. Done means

- Replaying the new rules over `~/.cache/harness-hook-calibration-2026-09-29/`:
  - A goes red on the data before 16:00, naming review-flow-gate (Pre Bash) and instruction-watch check (Post Bash);
  - A is quiet on the data from 18:00;
  - B names context-nudge before and not after.
- Each class A–J has a rule with a test, or a line in the design's §8 saying why not.
- `docs/harness-doctor-design.md` §3, §4 (with the evidence above) and §8 are updated.

Ground rules:
- `CLAUDEB_DIR` fixtures only, never the real `.claudeb` store.
- Hooks run live from the shared checkouts: edit by atomic replace, never under a running suite.
- Any hook change gets a worker's adversarial edge-case critique before it counts as done (Egor's standing rule).
- No commits: that is the sweep's job.
