# Hand-off: make the LLM doctor ready for a fixer on Egor's button

Status: done 2026-09-29 — every §1 item and §2 except two deferred: moving the hooks and guards rows to the Harness doctor (waits for its live rows) and per-problem p50/p95 `near` (top-level `near` and block speed ratios instead); contract notes in `docs/doctors-contract.md` §6.

For the chat that owns `bin/llm-doctor` and `share/doctor-ledger.json`. Written 2026-09-29 by the
chat «Updater doctor». Egor asked for this after a T2 hunt over the doctor, in which 24 of 25
findings were confirmed. His words: fix it and add everything the system needs to work. That chat
changed nothing in the doctor; every item below is yours.

## 0. The ask

Read `docs/doctors-contract.md` first. It is the shape shared with the Harness doctor, and the
coming Doctors menu, Fix button and fixer procedure read nothing else. A fixer chat will start from
this doctor's `latest.json` and must know three things:
- what exactly is broken;
- whether it is new;
- whether a past fix held.

Today the document cannot answer any of the three reliably.

Not yours: the Doctors menu entry, the Fix button, the launcher, the run record and the common part
of `docs/doctor-fix.md`. The chat «Updater doctor» builds those against the contract. Yours is this
doctor's section of `docs/doctor-fix.md`.

## 1. What makes the answers wrong today (P1)

Line numbers are as of the hunt.

1. **No cause ever reads `new`.** `tests/test_consistency.sh:551-553` requires an `any` catch-all row
   for every bug word, and rows V1–V15 give every word one with status `open`. An unseen crash, auth
   refusal or bad-output mechanism therefore lands under V7/V8/V11 as `open`.
   - Drop the catch-alls and the test rule that requires them.
   - `relabel_frozen` (`bin/llm-doctor:1349`) hands frozen empty-id counts to the first row that
     needs no detail. Move that history to where the split puts it, or the sparkline lies.
2. **No stable identity.**
   - `build_block` (`:1472`) groups by (kind, class/reason/origin, ledger id) and writes no id.
   - Unledgered bugs are counted by `cause_of`, a different identity, so the header `bugs` can differ
     from the number of rows.
   - Fix: emit the contract's `id` and count by it everywhere.
3. **Regression is judged by wall time.** `:1326` compares a leg's END with a hand-typed
   `fixed_at`, so a leg that started before the fix reads `regressed`. Judge by start time, or by a
   code revision recorded per leg in bench meta and worker-run meta.
4. **`fixed_in` cannot be met while fixers never commit.** R14 already holds prose there. Use
   `fixed-pending` and `fixes[]` (contract §2), and let the doctor fill `in` itself once the sweep
   has committed. Also validate `repo@hash`.
5. **No fix history.** One `fixed_at` per row is overwritten on a re-fix. One cause is split across
   rows (R12 and R14 are both export refusals, and R1 folds R1/R3/R4). Use `fixes[]` and
   `same_cause`.
6. **"Fixed" cannot be falsified.** `fixed Nd · 0 since` (`:1495`) shows no exposure. Add the
   contract's `exposure`, and read `unproven` below your minimum.
7. **Nothing protects the judge.** A fixer can zero a problem in any of these ways, and no test
   stops it:
   - a broad `not-a-bug`/`weather` row;
   - an `until`;
   - a word moved to `theirs` (both copies);
   - a widened scratch/profile exemption or `PRELAUNCH_SKIP`.

   Pin those in the tests (contract §2) and emit `judge`. Optionally, report the legs whose verdict
   changed because the judge changed as their own set.
8. **Blind spots are two bare strings.** `NOT_MEASURABLE` (`:66`) has no reason, date or
   would-catch. Move them to the ledger's `blind_spots`.
9. **Handoffs have no addressee for three blocks.** `owners` is null for workers, light and image,
   and `reviewed_by: "LLM doctor"` sits on rows the doctor judged itself. Fill `owners`, add
   `owner` (your chat name), and put a chat's name in `reviewed_by`.

## 2. What hides or blurs a cause (P2/P3)

- **Rows that never match.** `judge_leg_state` consults the ledger for bugs only. So R10 `cap`, R9
  `capacity`, R8 `refused`, N3 `cancelled` and N2 `slow` never match, yet they read as settled.
  Either delete them or make weather consult the ledger.
- **Whole-word fixed rows.** R5 (every reviewer `timeout`) and R1 (every `bad output`) turn any new
  mechanism into "regressed R5/R1". Narrow them.
- **Evidence.**
  - `incident_of` (`:1439`) drops the stderr text, the account and the absolute time, and cuts
    `detail` to 40 characters.
  - Image legs use `ref=tool`, and prelaunch legs use `ref='prelaunch'` (`:1175`).
  - Fix: one event per `ref` and the contract's `evidence`.
- **Counts differ between the document and the menu.** `machinery.issues` counts new+open+regressed;
  the menu, DIAGNOSTICS and the M1–M4 notes count new+regressed. The Lua also recomputes class states
  and adds health counts (`hammerspoon/llm-limits.lua:1493`).
  - Emit `problem_count`, and keep the Lua change to reading it.
  - The Doctors entry will replace this block, so don't redesign it.
- **Recovered bugs of our own vanish.** Superseded attempts are always weather (`:1234`). Keep the
  header as it is, but count ours-origin causes and lost seconds per problem, so a crash that a retry
  hides still shows when it repeats.
- **Thresholds sit at single incidents.** They are: no exit after 6 h (`:1016`), `DEFERRED_S` 2 h,
  `SILENT_S` 6 h, instruction growth 120 B, `TREND_MIN` 3. Name each one as a constant, emit the
  measured value beside it, and show near misses as `near`.
- **Hooks, guards and debt rows have no ledger link** (`:1642`).
  - The Harness doctor holds the hook journal, so hook and guard timing and failures belong to it.
    Agree the move with its owner chat (the same item is in its handoff).
  - Debt stays here and gets ids and ledger rows like everything else.
- **`first_seen` is missing** (`:1519`). The 09-24 handoff asked for it.
- **Docs contradict the code.**
  - `docs/DIAGNOSTICS.md:176` describes the old slow rule and says daily files freeze.
  - Shared-invariants row `cq` still says debt = `gaps/*` lines.
  - Fix the docs to match the code; do not change the code to match the docs.
- **Settled handoffs look open.** The 09-24 one still names `bin/llm-weather`. Mark 09-24 and 09-27
  with the contract's `Status:` line.

## 3. Constraints

- Tests use `CLAUDEB_DIR` fixtures only, never the real `.claudeb` store.
- Never mutate the live Hammerspoon singleton; read-only `menuItems()` only.
- Show every new assertion red on the old code. Diff every test change against HEAD: a weakened
  assertion is a regression.
- `bin/llm-doctor` carries another chat's uncommitted run-liveness work. Edit on top of it and never
  revert it. `tests/test_consistency.sh` assert 879 fails because of it today.
- A hook or gate change gets a worker's adversarial edge-case critique before it counts as done.
- Comments near zero, no commits (the sweep does them), and no scheduled fixer.

## 4. Done means

- `jq` on `~/.cache/llm-doctor/latest.json` shows every contract key.
- A fixture with an unseen cause reads `new`.
- A fixture with a re-fixed row keeps both fixes.
- A fixture where a leg started before the fix and ended after it does not read `regressed`.
- A broad dismissal row fails the tests.
- `bash tests/run-all` is green except for the foreign assert above.
- Your section of `docs/doctor-fix.md` exists. Create the file if the common part is not there
  yet.
- This file's `Status:` line is updated.
