# Hand-off: make the Harness doctor ready for a fixer on Egor's button

Status: done 2026-09-29 — floor-trivial-bash-readonly-fastpath, hook-every-call-context-nudge, floor-edit-hooks, unjournaled-sessionstart-branch-check
Still open under it:
- A test's identity is `<repo>:<label>`: history rows carry `repo_root` (the main checkout) and a
  worktree's runs fold into their repository. Only rows written before 2026-09-29 lack it and keep
  `worktree:<label>`; they age out of the 28-day window by 2026-10-28.
- The Hooks and guards rows of `bin/llm-doctor` are ported here as the Stop hooks and Guards areas
  (design §11, same rule names and limits); `bin/llm-doctor` keeps its rows until its owner chat
  removes them.

For the chat that owns `bin/harness-doctor` (design: `docs/harness-doctor-design.md`). Written
2026-09-29 by the chat «Updater doctor». Egor asked for it after a T2 hunt over the doctor, in which
all 21 findings were confirmed. His words: fix it and add everything the system needs to work.

That chat changed nothing in the doctor; every item below is yours. It does not repeat
`2026-09-29-harness-doctor-detection-gaps.md`: that handoff is about WHAT to detect, this one about
the shape a fixer needs to act on what was detected.

## 0. The ask

Read `docs/doctors-contract.md` first. It is the shape shared with the LLM doctor, and the coming
Doctors menu, Fix button and fixer procedure read nothing else. A fixer chat will start from this
doctor's `latest.json` and must know four things:
- what exactly is broken, and by which rule;
- where the cause lives;
- whether the doctor could see at all;
- whether a past fix held.

Today the document holds display text, and its history lasts one hour.

Egor's standing goal for this doctor: detect every measurable harness cost as precisely as
possible. The limits aim at endless improvement, not at today's numbers.

Not yours: the Doctors menu entry, the Fix button, the launcher, the run record and the common part
of `docs/doctor-fix.md`. The chat «Updater doctor» builds those against the contract.
`menu.txt` stays until the Doctors entry reads the envelope; that chat then removes the pre-render
path. Yours is this doctor's section of `docs/doctor-fix.md`.

## 1. What makes the answers wrong today (P1)

Line numbers are as of the hunt.

1. **Rows are display text.**
   - Rows are `cells` strings plus indices in `red`, and a `say` sentence with the numbers baked in
     (`bin/harness-doctor:1435`).
   - No row carries a rule id, value, limit or exposure. Emit the contract's `problems`.
   - Build keys from identity, not from the label. Today:
     - `wait:` + a 22-character `clip()` of the project can collide (`:1529`);
     - test keys embed transient worktree names;
     - growth keys take whatever the label says.
2. **No history.** `firstred`/`firstwatch` are deleted an hour after a row was last red, and a
   flapping row restarts its "since" (`:2645`).
   - Start `share/harness-ledger.json` in the contract's shape: `owner` set to your chat name, rows
     with `fixes[]`, and `blind_spots`.
   - Compute `first_seen` from data.
3. **"Cannot see" reads as OK** (`:2092`). Hook waits reports `ok` with "no hook batch joined to a
   call yet" when the journal or the join is empty, and Load does the same. Report `blind`, or a
   fixer can "fix" a row by breaking its input.
4. **The judge sits in the file the fixer edits.** `LIMITS` (`:24`) is not pinned to the calibrated
   table in design §4 by any test. Pin it (contract §2), emit `judge`, and route any loosening
   through a handoff.
5. **A hook can escape judgment.** Removing a hook's `hook-time.sh` line drops it out of rules
   E/B/C/F; it only lengthens a blind-spot text (`:2852`). A settings hook with no journal line
   should be a problem of its own.

## 2. What hides or blurs a cause (P2/P3)

- **Limits fit the 10 s incident.**
  - `call_s` is 5 s while healthy calls take 1.5–3.5 s. `hook_p50_s` is 1 s.
  - `cut_min` is 3 an hour, so two 60 s cuts an hour stay dim; `test_slow_min_s` has the same
    problem (`:25`).
  - Emit `value`, `limit` and `near` (p50/p95) for every rule, so a sub-limit cost is visible and
    can be ranked.
- **The cause line is weak evidence** (`:2618`).
  - It lists every watched-file change in the 6 h before a red, unranked.
  - Its impact columns are always "short Bash s" and "new proc/s", whatever rule went red. Rank the
    changes, and show the impact of the rule that went red.
- **The change log is blind to whole classes** (`:749`).
  - Its roots are `~/.claude/hooks` and llm-legs `bin`/`share` only, and it snapshots only the hooks
    from `settings.json`.
  - It misses `statusLine.refreshInterval` (the H1 cost), the other settings keys and
    `hammerspoon/*.lua`.
- **Blind spots are three strings in code** (`:141`). Design §2 says 4, and §8 lists 5 plus prose.
  - Move them to the ledger's `blind_spots`.
  - Add the calls left out of every wait and floor because they come from sessions outside
    bypassPermissions (who `h`) (`:1573`).
- **The before/after proof uses unmanaged data.** The detection-gaps "Done means" replays
  `~/.cache/harness-hook-calibration-2026-09-29/`. Commit a trimmed fixture and make
  `tests/test_harness_doctor.sh` replay it with `HARNESS_DOCTOR_NOW`.
- **A quiet row is not proof** (`:2556`).
  - Rows clear an hour after the cause stops, for example when load drops.
  - Proof means the rule's value is under its limit around the fix's `at`, at comparable load, with
    exposure (contract §2).
- **There is no self-health row** (`:2864`).
  - `collector_s` is written but never judged.
  - An exception in `collect()` leaves the old `menu.txt`, whose colour stays under a "stale"
    suffix. Use status `error` with the line.
- **"N problems" counts areas** (`:2849`). "(+N more)" hides rows, and Slow periods can never be a
  problem. Emit `problem_count` over problems.
- **`docs/DIAGNOSTICS.md` never mentions this doctor.** It is the fixer's first read (CLAUDE.md).
  Add its rows: `latest.json`, `--json`, `local_slow`.
- **Handoffs have no state.** Put the contract's `Status:` line on the 09-28 and 09-29 handoffs.
- **The `local_slow` link to the LLM doctor** covers red Waits call rows only (`:1595`). Red
  hook-wait floors and red Load (busy/kernel) never mark a period local. Say in the contract which
  rules feed it.
- **Design §4 says "best 28 d"** where the code and §7.1 show "wait s 7 d" (`:221` of the design).
  Fix the design.
- **Hooks and guards rows in the LLM doctor** (`bin/llm-doctor:1642`) overlap your domain. You hold
  the hook journal, so they belong here. Agree the move with the LLM doctor's owner chat (the same
  item is in its handoff).

## 3. Constraints

- Tests use fixtures only. Never mutate the live Hammerspoon singleton; read-only `menuItems()`
  only.
- Show every new assertion red on the old code, and diff test changes against HEAD.
- Every hook or gate change gets a worker's adversarial edge-case critique before it counts as done.
- Other chats' uncommitted work is edited on top of, never reverted.
- Comments near zero, no commits (the sweep does them), and no scheduled fixer.

## 4. Done means

- `jq` on `~/.cache/harness-doctor/latest.json` shows every contract key.
- Emptying the hook journal reads `blind`, not `ok`.
- Raising a `LIMITS` value fails a test.
- The committed fixture replays with the same problem ids twice.
- A problem red an hour ago still has its `first_seen`.
- `bash tests/run-all` is green.
- Your section of `docs/doctor-fix.md` exists. Create the file if the common part is not there yet.
- This file's `Status:` line is updated.
