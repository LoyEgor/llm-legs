# Relay-free worker rows: a `worker` work line instead of the Sonnet relay subagents

Status: open; design approved by Egor 2026-10-08 (§ Approved design), implementation not started. To: «Light помощник и унификация workers». From: «Token spending tracking and optimization», 2026-10-08.

## Why
Every delegation spawns a relay subagent on Sonnet: claudeb-, codex-, gemini- and grok-worker, light-worker, light-research, and review-waiter for review-bench. The relay only launches `worker-run`, waits in 9-minute rounds, and relays the report.

- **Cost.** In the week to 2026-10-08 relays cost about 4.6% of Claude spend. The claudeb-worker relay alone was 41.4M limit tokens: 1,029 spawns, about 10 requests and 40k each.
- **Already cut.** `omitClaudeMd: true` (claude-setup 1bd5689, 2026-10-08 03:38) brought relay startup down from 12.5k to 3.4k per spawn.
- **Egor's goal.** Spend zero tokens on holding a worker.

## Egor's requirements
- **What the row must keep.** Today's relay row shows account, model, effort, task title, state and elapsed time. A replacement must keep all of it.
- **Visual mock first, implementation later.** Before any implementation, show him a visual mock in his own chat:
  - what a worker line looks like and how it is coloured;
  - where it sits;
  - what happens when a shell line and a worker line run at once;
  - what two workers look like, and what overflow (more than 3 lines) looks like.
- **He decides strategically on the mock.** Today's panel design suits him, so a new design has to prove it can carry the same information.

## Findings
1. **Background Bash cannot draw a panel row.** Claude Code 2.1.288 hands `subagentStatusLine` only `local_agent` tasks.
   - A probe on 2026-10-08 ran a 75 s background Bash. The renderer was called 31 times and never received it.
   - `docs/statusline-contract.md` § Task rows says the same.
2. **Work lines already exist.**
   - The pipeline: `bin/statusline-work-probe.sh` writes the `work-<sid>` cache, and `bin/statusline.sh` draws it under line 2.
   - Look: magenta `<class> · <repo>`, then a dim label and elapsed time. At most 3 lines, then `+N`.
   - Precedent: the `media` line (`bin/media-run` writes `$STATUSLINE_CACHE_DIR/media-<pid>`) replaced the image-gen agent row on 2026-10-04.
   - Egor saw a `shell · token-map · sleep` line live and confirmed the placement works. He said a shell line is not a worker line.
3. **The data for a worker line is already there.**
   - The run dir holds `tag` (`acct · model · effort`), `meta.json`, and `state.json` (`phase`, `started_epoch`). Elapsed can therefore count from the run start, not from each wait round.
   - Title: take it from the hook-rewritten Agent description (`~/.cache/claude-worker-tags/<sid>/<agent-id>`; `bin/subagent-statusline.sh` strips the tag from it around line 264), else from the brief's first line after its header lines.
   - The relay's `worker-run wait <run-id>` process sits in the chat's process tree today. So the line can be drawn before the relays are retired.
   - The probe already skips a Bash call whose subtree runs `worker-run` or `review-bench`, so a worker will not also show up as a `shell` line.
4. **Fallback: a Haiku relay.**
   - A Haiku 4.5 relay was tried from 2026-07-20 to 2026-07-22 (claude-setup 21dc75f → 1a520e5). It implemented tasks itself in 6 proven runs and was reverted.
   - Haiku 5.5 was released on 2026-10-07. CLI 2.1.288 doesn't know it; the latest CLI is 2.1.295.
   - This is the option if the mock fails: the panel row stays and the relay gets cheaper, though not free.

## Approved design
Egor saw a live mock in his status line on 2026-10-08 and approved it. The exact rendering code is in `2026-10-08-relay-free-worker-rows.mock.sh` beside this file. It is demo-only, so rebuild it properly. It changes every work line, not only workers.

Preview at 80 columns (ANSI stripped):
```
locomthebest · opus · high — Speed up tracking r…  tests      12m 36s  ↓ 184k
com · sonnet · medium — Split merged reviews per…  working     8m 29s   ↓ 37k
codex · gpt-6 · high — Review menu cache           reviewing  16m 34s   ↓ 92k
gemini · 3.5-pro — Audit relay hooks               working    10m 24s   ↓ 51k
image · logo — generate icon                                   6m 54s
+2 workers, 4 commands
```
With commands visible (70 columns):
```
locomthebest · opus · high — Speed up tr…  tests     6m 12s  ↓ 184k
shell · token-map — pytest -q tests/test…            40s
tests · llm-legs — test_statusline_hooks…  12/41 ✗1  1m 35s
```

**Order and cap.**
- Agent rows come first: workers of every vendor (light included), review runs and images. Command rows follow: shell, tests and the other probe classes.
- At most 5 rows. The rest becomes one dim line, `+3 workers, 1 image, 4 commands`: hidden counts by kind, with no "more" word and no total.
- This replaces today's 3-row cap and its `· +N` suffix on row 3.

**Row.** Each row reads `<head> — <title>`, then a right block.
- The head is magenta on agent rows and cyan on command rows.
  - A worker's head is `account · model · effort`, the same tag as today's panel, with no "worker" word.
  - An image's head is `image · <repo>`.
  - A command's head is `<class> · <repo>`.
- The title starts right where the head ends, so titles are not aligned under each other. It is bright on agent rows and dim on command rows.
- The right block is three columns shared by the visible rows:
  - **state:** left-aligned within its column, dim. A test counter like `12/41 ✗1` goes here, with `✗N` in red.
  - **elapsed:** right-aligned, dim.
  - **tokens:** right-aligned, dim.

  A column that no visible row fills takes no space.
- The block sits at `min(COLUMNS − STATUSLINE_FIT_MARGIN, widest natural row)`. That keeps a wide window from opening a gap after short titles.

**Width.** As the window narrows, only the title shrinks, ending in `…`. Head, state, elapsed and tokens never shrink.

**Values.**
- **Elapsed** counts from the run's start (`state.json` `started_epoch`), not from a wait round. Seconds are padded to two digits so the width does not jump: `4m 05s`, `1h 02m`.
- **Tokens** are the worker's own, read from its live session log: the run dir's `session-file` for claudeb, vendor logs for the others. Today's panel shows the relay's `tokenCount`, which is the Sonnet relay's spend, not the worker's. If the count is unknown, the cell is blank.

**Going inside.** A status line row cannot be clicked; Egor asked about this and accepted the substitute below.
- CLI 2.1.295 has `/tasks` → "Shell details", which shows the last 8 KiB a background shell wrote.
- So a directly launched `worker-run` must print the worker's progress (tool calls, short messages) to its stdout. That way `/tasks` shows what the worker is doing.

**Contract.** The real line must pass the checklist in `docs/statusline-contract.md` and its tests in `tests/test_statusline_hooks.sh`. Update the § Work lines section (cap, order, colours, overflow line) in the same change.

## Wanted
1. ~~A temporary visual mock in Egor's own status line.~~ Done and approved on 2026-10-08 (§ Approved design). The mock was removed from `bin/statusline.sh`.
2. **Next:**
   - the real `worker` work line;
   - direct launches, where the chat runs `worker-run` as a background Bash call. `worker-launch-gate.sh` refuses chat-run launches today;
   - retire the relays, review-waiter included;
   - the CLAUDE.md delegation rules;
   - the relay-audit hooks;
   - token-map's relay detector (`tracking.py` `RELAYS`).

   Rough size: about 300 lines across about 10 files in llm-legs and claude-setup.
