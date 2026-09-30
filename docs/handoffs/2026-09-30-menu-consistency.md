# Handoff: one visual and wording convention across the Hammerspoon menus

Status: open. Two workers are applying the convention right now; their outcome is appended below.

## Why
Egor reads account, cost and health state only from the Automation menubar (LLM Limits, Better
Terminal, Token tracking, Doctors, Reports). Five Lua modules written by different chats grew
different styles, and Egor kept catching the differences himself: two reds, red titles drawn in a
smaller font, a jargon row at the top of LLM Limits. On 2026-09-29 a T2 task hunt (run
`20260929T220510Z-5838bea`) listed 36 inconsistencies. Only the opus-high cell ran, because the codex,
gemini and grok legs were off. The judge confirmed 17 of the 36.
- Findings: `menu-consistency/hunt-findings.txt`.
- The live menu before the changes: `menu-consistency/menu-before.txt`.
- Re-render the live tree read-only with
  `hs -c "return dofile('/Volumes/Work/Projects/llm-legs/docs/handoffs/menu-consistency/dump-menu.lua')"`.
  Each row prints its font, colour and flags.

## Done (by the orchestrating chat)
- **One red:** `{0.9, 0.25, 0.2}` in every module.
- **Fonts on red titles:** top-level red titles take `hs.styledtext.defaultFonts.menu`. Before, they
  had no font and rendered smaller.
- **Guard:** `docs/shared-invariants.md` row dd, checked by `tests/test_consistency.sh`. A second
  red-dominant literal, or `hs.styledtext.new` without a font, fails the suite. Mutation-proven.
- **Shared module** `hammerspoon/menu-style.lua` (pure Lua, no `hs`): `RED`, `DIM_RED`, `GREEN`,
  `DIM`, `MONO`, `age`, `ago`, `clock`, `day`, `mono`.
- **token-map** `tokenmap/tracking.py` `scale_for`:
  - a unit is taken only from ten of it, with no decimals from a thousand of it. So a top table led
    by 1.5B reads `1,500M` / `20M` instead of `1.5B` / `<0.1B`;
  - the total row `Claude spend` no longer shows a `100.0%` share;
  - tests updated, and the new case is mutation-proven. The menu picks this up at the next Token
    tracking Refresh.
- **Updater doctor facts** read `codex 0.156.1 → 0.159.0: new gpt-6.1-sol · waiting 4d for
  integration`, or `changed help text` when no model is new.

## The convention
1. **Name and state.** Write `Name: state`, and join the parts of a state with ` · `. Top-level
   titles too: `Doctors: 41 problems`, `Token tracking: stale · watcher down`.
2. **State words lowercase:** `ok`, `stale`, `down`, `blind`, `failed`.
3. **Ages and times only through menu-style.**
   - Past events: `scanned 32h ago`, `ran 2d ago`.
   - Ongoing: `running for 3h`, `longest 16m`.
   - Clock: `16:04` today, `Sep 28 16:04` otherwise.
   - Dates: `Sep 28`.
4. **Empty state** `no data yet`, with no hint naming a script.
5. **Nothing internal in a row:** no script names, file names, CLI hints, ledger ids or session ids.
   File paths that are the data stay.
6. **Actions.**
   - Sentence case. One verb, `Refresh` (`Hard refresh` per account stays).
   - Actions sit at the bottom of their submenu after one separator.
   - In a doctor submenu the order is: content, separator, `Refresh`, `Fix — …`, the dim `fixer:` row.
7. **Font.**
   - Inside LLM Limits, Token tracking and Doctors, every row is Menlo 13 (`menu-style.mono` over the
     finished tree).
   - Top-level entries and Reports use the system menu font.
   - Every `hs.styledtext.new` names a font.
8. **Colour meaning.**
   - Red means a problem needing action: any doctor with `problem_count > 0`, the LLM doctor included.
   - Dim means informational.
   - Column headers are dim, disabled and lowercase, the worker-pick routing header included.
9. **No row twice.**
   - `watcher down` appears only in the Token tracking and `Instruction file changes` titles.
   - The watcher liveness row shows only when the watcher is down.

## Running when this was written
- **Worker A**, `llm-limits.lua` and `tests/llm_limits_renderer_harness.lua`:
  - the convention;
  - the limiter hold row becomes `<limiter>: holding N job(s), longest 16m`, with a submenu of held
    jobs, `why` and `until`;
  - it exports `M.title()` (`LLM Limits`, or red `LLM Limits: <state>`);
  - doctor entries turn red when `problems > 0`, and their menus end with a separator and `Refresh`.
- **Worker B**:
  - `doctors.lua`, `token-tracking.lua`, `instruction-watch.lua` and the hammerspoon repo's
    `automation_menu.lua`, with their harnesses;
  - the doctor submenu order, the fixer-row wordings, token-tracking and watcher wording, dates;
  - the LLM Limits title taken from `llmLimits.title()`;
  - the Reports font.

## What the next chat does
1. **Read each worker's outcome below and verify it; do not trust green.**
   - Diff every changed test against HEAD: a changed expected string must match a wording change, and
     no assert may be dropped.
   - Run `bash tests/test_llm_limits.sh`, `tests/test_doctors_menu.sh`,
     `tests/test_token_tracking_menu.sh`, `tests/test_consistency.sh`.
   - In the hammerspoon repo, run `tests/test_doctors_menu.sh`, `test_tracking_menu.sh`,
     `test_reports_menu.sh`.
   - Re-render the live tree and compare it against the convention.
2. **Findings the workers were not asked to cover:**
   - Harness doctor rows read as jargon (`Hook waits problem a non-trivial Bash ca…`). The text comes
     from `bin/harness-doctor`'s `menu.txt`, which the Harness doctor chat owns; hand it over there.
   - Informational rows are clickable in some menus and disabled in others. The chat rows switch chats
     and the machinery rows copy a command. Decide one rule and state it.
   - LLM Limits account rows show only an age (`↻1 7m`); check that they read the same as other ages
     under the convention.
   - Worker cold-resume rows in Token tracking show full worktree paths (`tokenmap` renders them).
3. **Make the convention mechanical where it can be:**
   - extend row dd and `tests/test_consistency.sh`, e.g. no local age or date formatter outside
     menu-style, no `bin/` inside a title literal, no upper-case state words;
   - prose here is only for what a test cannot judge.
4. **Ground rules:**
   - Work on the main checkouts, uncommitted. Never revert, stash or clean foreign work.
   - Hammerspoon auto-reloads 10 s after a saved `.lua` compiles.
   - Never mutate `package.loaded["llm-limits"]`.
   - A hook or gate change needs a worker's edge-case critique.

## Worker outcomes
### W-A: llm-limits.lua (done; RESUME 748c72b3-33d7-4893-bd71-02e104ea9d95, account locomthebest)
- Changed: `hammerspoon/llm-limits.lua`, `tests/llm_limits_renderer_harness.lua`, `tests/test_consistency.sh`.
- `test_llm_limits.sh` and `test_consistency.sh` pass; asserts 602 → 613, none dropped; 8 mutations red.
- Colours, fonts and times come from `menu-style`; empty states read `no data yet`; the `bin/harness-doctor`
  and `review-bench doctor --json` hints and ledger ids are gone; `Refresh blocks` / `Rescan now` → `Refresh`
  at the bottom after a separator (dim `refreshing…` while a run is going); `LLM doctor` is red on
  problems > 0 or a failed collector; the routing header is dim and disabled.
- `M.title()`: plain `LLM Limits` when nothing is red, else red in the system menu font,
  `LLM Limits: <parts>` (`N hold(s)` past `HOLD_RED_S`, the warning's short reason).
- Limiter row: `logo-bench-throttle: holding 8 jobs, longest 1m`; submenu one row per job
  (`bench job · bench · for 1m`), `why: …`, `until 01:57`. `<chat>` is the basename of `held.cwd`
  (llm-limits has no session-to-chat resolver). Row dc kept.
- Open:
  - `test_doctors_menu.sh` fails on `LLM doctor: ok: a separator, then Refresh, above Fix`: its harness
    starts a fake llm-doctor run that never finishes, so the slot shows `refreshing…`. Fix the harness
    (finish the fake run) or accept `refreshing…`.
  - `Harness doctor: OK` stays uppercase because `bin/harness-doctor` writes it — owner chat's change.
  - The live `hs -c` check was not confirmed.

### W-B: doctors, token tracking, instruction watch, automation menu (done; RESUME 698794d1-4ff9-4c52-a015-65c1c3bc095c, account notcom)
- The run's listing names `hammerspoon/doctors.lua`, `hammerspoon/token-tracking.lua`,
  `tests/doctors_menu_harness.lua`, `tests/test_consistency.sh` (line 3124 only). The report also
  edited `instruction-watch.lua`, the two menu harnesses, `test_instruction_gate.sh` and hammerspoon-side
  files; the listing does not name them (24 changed paths unclaimed, `worker-run claim` not run).
- Suites: `test_token_tracking_menu` ok, `test_instruction_gate` 936, `test_consistency` 1608,
  hammerspoon doctors 15 / tracking 17 / reports 40. `test_doctors_menu` fails on the same
  `LLM doctor: ok: a separator, then Refresh, above Fix` check as W-A notes above (fake run never finishes).
- Live: `Doctors: 38 problems`, `Token tracking: stale`.
- Deviations: a 24h abandoned fixer reads `abandoned 24h ago` (`age` turns to days at 48h); a missing
  updater file reads `Updater doctor: no data yet` with an inner `no data yet`; token-tracking empty/error
  rows `no data yet` / `data unreadable`, `last rescan failed` → `last refresh failed`; if `menu-style`
  fails to load in `automation_menu.lua`, `ALARM_RED` is nil and report ages show `—`;
  `test_reports_menu.sh` got `</dev/null` and `-t 30` (it hung); `hs -c` suites mix output when run in
  parallel, run them one at a time.
- Left:
  - byte and price formats in `instruction-watch.lua` (hunt finding at line 1034);
  - clickable informational rows at `token-tracking.lua:166`;
  - `docs/shared-invariants.md` rows db and dd still name locals that no longer exist (`GREEN`, `RED`).

### Menu-consistency chat, 2026-09-30

- All three "Left" items are fixed:
  - `shared-invariants.md` rows db and dd name `M.GREEN`/`TONES`/`M.RED` and the `style` binding;
  - `token-tracking.lua` info rows are `disabled = true`, and the harness asserts that every row either acts or is disabled;
  - `instruction-watch.lua` reads `+184 B` and uses one `12.3k tok/wk` token format.
- Step 3 guards are in `test_consistency.sh` row dd, each proven by a mutation:
  - no `bin/` in title literals;
  - no upper-case state words;
  - no age formatter outside `menu-style.lua`.
- The suite now has 1618 asserts.
- Token tracking was smaller than its siblings only in the red `watcher down` state. That styled title named no font. It now uses the menu font, and row dd rejects any font-less styled text in both repos.
- Routing (LLM Limits):
  - `worker-pick --menu` gives every vendor a header: `on`, `workers off · reviewers off`, `workers off`, `reviewers off` or `paused`. Every account stays listed under it.
  - The vendor order is claude, codex, grok, gemini, the same as the vendor sections.
  - The Light switch and review flash T0–T1 moved inside Routing.
  - Chats still read the plain table, so their context did not grow.
- LLM Limits title: a single account's refresh error no longer reddens it or the menubar ⚠. It stays a ⚠ row inside its vendor. Only a red hold or an unreadable store warns at the top.
- Open: nothing surfaces a refresh failure that lasts for hours in Doctors yet.
- Chats: clicking a live chat brings its Terminal tab to the front (`ChatGate.selectTabByTty` by the chat's tty). A closed chat, or a live one whose tab it can't find, falls back to `--open-command`.
- Cold-resume rows in token-map show `<repo> › <worktree dir>` or the repo basename.
