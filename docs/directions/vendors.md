# Vendors (block 6)

A vendor change (a CLI version, a model added or removed, a plan or quota change on an account, a new flag or
feature) studied and integrated into the harness. Block 0's prep notices and installs it (`vendor-cli-update now
--night`, the Updater doctor); this block takes the event `bin/vendor-fingerprint` opened to its close
(`docs/vendor-release.md`). Vendor news no CLI shows is block 9's (`vendor-watch`); the events it opens are this
block's to integrate.

## Metric

Integration lag: mean days from a vendor event's creation to its close, an event still open aged to the window's
end, 7 days against the 7 before.
- Events: `~/.cache/vendor-cli-update/events/<vendor>-<stamp>.json` created in the window (local days, UTC+3).
  `auto-closed` events are out: only informational facets changed. Events that are our own change, not a vendor's,
  are out too (in these windows one: `grok-20261008T234948Z`, an ids rule change). A close needs every diff line
  decided (`close --decisions`, vendor-release §4), so closing an event without integrating it does not lower the lag.
- Health, not activity: it is per change, so more vendor releases do not move it, and more integration work moves it
  only if every change closes sooner. Its floor is the gap to the next night, since Egor launches nights and fixer
  chats open only on his button (Decisions 09-29). With a night every day the lag tends to ≈1 d or less; the first
  window shows that floor.
- Second number, target 0: vendor changes noticed outside the fingerprint, where Egor, a chat or a breakage found
  the change before any event did.

### Baseline (computed 2026-10-20)

| | 10-06…12 | 10-13…19 |
|---|---:|---:|
| events (not auto-closed) | 13 | 11 (5 vendor-watch) |
| **mean lag, days** | **0.14** | **4.32** |
| max lag, days | 0.63 | 5.67 |
| open at the window's end | 0 | 9 |
| event-days waiting | 1.8 | 47.6 |
| auto-closed (out) | 8 | 2 |
| **changes noticed outside the fingerprint** | **1** | **1** |
| integration sessions' share of Claude spend | 0.36 % (11 sessions) | 0.13 % (3) |
| integration runs, launch → close, wall clock | 11, median 32 min | 2: 169, 384 min |
| nights started | 6 | 3 (the last one 10-14 01:37Z) |

- Lag (prior window: `a=2026-10-05T21:00:00Z b=2026-10-12T21:00:00Z`):
  `q='[.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z") | (((.closed_at // $b) | fromdateiso8601) - (.created_at | fromdateiso8601)) / 86400] | {n: length, mean: (add / length), max: max, days: add}'; jq -s --arg a 2026-10-12T21:00:00Z --arg b 2026-10-19T21:00:00Z "$q" ~/.cache/vendor-cli-update/events/*.json`
- Open now: `jq -s '[.[] | select(.status == "open")] | length' ~/.cache/vendor-cli-update/events/*.json` (9: watch
  ×5 10-14 04:51Z, codex 0.162.1→0.163.0, agy 1.3.4→1.4.2, claude 2.1.296→2.1.303, grok 1.0.52→1.0.62 with grok-4.7).
- Spend (token-map; the orchestrator's own turns and the other vendors' pools are not counted):
  `sqlite3 ~/.local/share/tokenmap/tokenmap.sqlite3 "SELECT round(100.0*sum(CASE WHEN (cwd LIKE '%/worktrees/vendor-%' OR cwd GLOB '*/worktrees/night-*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx][a-z]*') AND NOT cwd GLOB '*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx]*-*-*' THEN cost_in+cost_out END)/sum(cost_in+cost_out),3) FROM requests WHERE vendor='claude' AND ts>='2026-10-12T21:00:00' AND ts<'2026-10-19T21:00:00'"`
- Runs: `jq -s --arg a … --arg b … '[.[] | select(.launched_at >= $a and .launched_at < $b and .closed_at) | ((.closed_at | fromdateiso8601) - (.launched_at | fromdateiso8601)) / 60]' ~/.cache/doctors/runs/updater-release-*.json`
- Changes noticed outside the fingerprint, read by hand (Egor's messages 10-05…19 searched for new model or version,
  bought, subscription, appeared, gone, then checked against the event times; a miss he never mentioned is not
  counted, so this is a floor). 10-08 19:54Z, «Updater doctor»: Claude Code 2.1.295 was out and the Updater did not
  show it, because the native claude sat at 2.1.288 under `DISABLE_AUTOUPDATER` and the check ran once a day. The
  event opened at 20:12Z, after the fix. 10-19 14:13Z, «Workers и review bench унификация отображения»: Egor bought
  Gemini Pro on notcom that day (Plus before), and Gemini 4 Argon appeared there, with no event and no Updater row.

## Sources

- Event store above (`.diff`, `.base` of a waiting event, `.decisions.tsv`). Events are written by `vendor-fingerprint
  check` at the end of `bin/vendor-cli-update`'s full pass: launchd runs `run --if-due` every 30 min, a full pass is
  due every 24 h and the version check every 2 h (64f8354e). Fingerprints: `fingerprints/<vendor>.json`; info
  facets (version, catalog_text, catalog_order, foreign_clients) never open an event; `update.log`, `state.json`.
- Runs: `~/.cache/doctors/runs/updater-release-*.json`; nights' `jobs[]` of kind `vendor` / `vendor-watch`.
- Updater doctor `~/.cache/updater-doctor/latest.json`: `event-waiting` (from 0 d), `event-stuck` (2 d),
  `plan-changed`, `family-partial`, `family-gone`. `share/updater-ledger.json` is empty; the night snapshots'
  `updater` rows 10-06…14 are 8 `event-waiting` ids plus `foreign-client` watch rows.
- `docs/vendor-release-open.md`: 14 claims a closed event left unproven or blocked, the oldest from 09-23.

## Recurring classes

Ranked 10-20 by what they cost, over 10-06…19.

| class | 10-06…12 | 10-13…19 | cost | instances fixed |
|---|---:|---:|---|---|
| events wait for a night that does not take them | 0 open | 9 open | 47.6 event-days; grok-4.7, codex 0.163.0, Claude Code 2.1.297–303 unread | 0 |
| a vendor change no facet reads: Egor finds it | 1 | 1 | his notice and a hand-run chat (Argon 10-19: 13707749 and 4 more commits) | installs 09-23, native claude 64f8354e, plans 56a766ed |
| a false event: an id string nothing serves, our own change | 4 + 1 own | 0 | one strong-model run each (W1 0.36 % ÷ 13 ≈ 0.03 % per event) | fe3841b9, 52ec96b0 |
| a closed event's change breaks a surface the run missed | 0 | 1 | review-bench T2 rater crashed 10-13 13:10, 7 h after agy 1.3.3's close | review-bench@4288f13 |
| a claim closed unproven waits on Egor's toggles or word | 14 lines | | live proofs not run | (decisions) |

Why they come back:
- **One trigger.** A full night's prep (`vendor-fingerprint request --night`) is the only automatic way an event
  gets integrated; otherwise it waits for Egor's Fix button or «сделай апдейт». Since 10-15 every new night is a
  pilot, and its rules forbid `vendor-fingerprint` (6a5f1c46, 47eb5afc). No night has run since 10-14, Egor did not
  know the button (ef00e2ba), and his last «сделай апдейт» was 09-24. Only the Updater rows showed the wait. A
  waiting event absorbs later releases, so claude's single event now covers 7 versions.
- **A facet per miss.** The fingerprint sees only what a facet reads, and each facet was added after Egor found a miss:
  ChatGPT.app's bundled codex (09-23), the native claude (10-08), per-account Gemini catalogs and plans (10-19).
  Still unread: a grok account's plan (the store records none) and Claude's per-account `fable`. Gemini's plan name
  is recorded nowhere, only its quota groups and `families`. A facet new to a fingerprint is a baseline, not a change,
  so `plans` will only baseline. notcom's Argon should reach the open gemini event through the new catalog shape
  (its accounts column) at the first full pass after 56a766ed, due 10-20 ≈03:00Z; this is unconfirmed until that
  pass runs.
- **False events** came from packed string tables gluing ids (agy 1.3.0–1.3.2, a grok cargo hash). There have been
  none since 52ec96b0 (10-09), so the class is watched, with no goal.
- **Missed surfaces.** A run decides each diff line, not each surface the change reaches; the resolver rule
  (vendor-release §3 step 7, `test_consistency.sh` row `cr`) removed the static pin that broke. One row; watched.

## Block 1 and this block

The rule: a breakage goes to block 1, and an unintegrated change goes to block 6. One change is counted once.
- Block 1 (Breakages): something we run failed. That covers a leg that fails after a release (log audit, LLM
  doctor), and the update machinery itself failing (Updater `pass-failed`, `install-failed`, `probe-broken`,
  `cli-behind`, `client-too-old`, `caps-stale`). Block 1 fixes the leg.
- Block 6: a vendor change the harness has not integrated yet. That covers `event-waiting` (already outside block
  1's sum), `event-stuck`, `plan-changed`, `family-partial`, `family-gone`, and the second number. Block 6 fixes the
  procedure or the detection: when a breakage traces to a closed event that missed the surface, the fix to
  `docs/vendor-release.md` or `vendor-fingerprint` is this block's, and the broken leg stays block 1's.

## Goals

Worked in order, one at a time, after blocks 1–5 (PILOT). A landed goal moves to Done with its commit and proof.

### goal night-events: from this block's turn, every pilot night integrates the vendor events waiting at its start

Class: events wait for a night that does not take them. 9 events are open, 3.8–5.7 d old on 10-19; no instance has
been fixed.
- Change in `bin/night-run`: PILOT_RULES drops `vendor-fingerprint` from its no-list. Once `pilot_goal` has reached
  `vendors` in PILOT, `carry` prints one `vendor` line per ref that `vendor-fingerprint request --night R` prints
  (the full night's Vendors step, `docs/night-run.md`). It prints them only after the night's goal job has landed,
  so a goal is still judged alone on its spend and load. Each line is landed per branch like any job, and every
  later pilot night keeps the step. No new hook or suite: the pilot case in `tests/test_night_run.sh` changes.
  Net lines shown.
- Proof, fixed now. Old: under today's PILOT_RULES a pilot night leaves every event open at its start still open
  (9). New: the first pilot night after landing closes every event open at its start (0 left open): integrated,
  not-applicable, or blocked with a line in `vendor-release-open.md`. Its goal job's spend and minutes in the night
  header are unchanged, because the vendor jobs start after the goal lands.
- Read after landing: mean lag over the next 7 days at or under the mean gap between nights, target ≈1 d or less
  with a night every day (10-06…12: 0.14 d over 6 nights). Events open at a night's start and still open at its
  close: 0. Not worse: the integration sessions' spend share per event against 10-06…12 (≈0.03 %), and the second
  number.

## At night

- Section 6, Vendor events (README "The whole night"), plus the vendor-watch events block 9 opens. The Updater
  doctor and the CLI installs stay in block 0's prep.
- Goal `night-events` above is the pilot change, made in `bin/night-run`'s PILOT_RULES and `carry`.
- The first night is judged on these points:
  - Every event waiting at its start is closed by Close.
  - Each run starts with "purpose before change" (vendor-release §1).
  - Each run decides every diff line.
  - A blocked line names what Egor's word unlocks.
  - The night header shows each vendor job's spend.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 09-23/24 | fingerprint and events; daily checks; a flap that reverted closes itself | | `vendor-fingerprint`, `update.log` |
| 10-04 | an install ahead of the primary is no event | | 2a30c530 |
| 10-07, 10-09 | ids facet holds only served ids; cheap events go to Sonnet | false events 4 → 0 per week | fe3841b9, 52ec96b0 |
| 10-08 | releases seen within 2 h; the updater owns the native claude | | 64f8354e |
| 10-19 | per-account catalogs and plans become events; Argon serves only on accounts that list it | first live check pending | 56a766ed, 13707749 |

## Decisions

- 2026-10-20: blocks 0–10 numbered; every block is judged by a converging metric, never by work done.
  («Updater doctor», README)
- 2026-10-19: block 0 notices and installs; block 6 studies and integrates (new model into routing, gone model out,
  a plan change into limits, new flags used); a browser path that broke is block 1; vendor news no CLI shows is
  block 9, postponed. («Updater doctor») The metric above was proposed there; Egor has not replied yet.
- 2026-10-19: a pilot night is test mode, incomplete by design; its sections return one at a time, each tested.
  (47eb5afc, «Updater doctor»)
- 2026-10-19: Gemini 4 Argon is integrated fully (worker, its own weekly quota in the menu, Frontier in review) with
  the least hardcode, and the night must notice and integrate such changes by itself. Accounts differ (only notcom
  is Pro and serves Argon): the system knows which account serves what and never forces all of them alike.
  («Workers и review bench унификация отображения»)
- 2026-10-19: a model change is never Egor's decision: a run proves and records the defaults, and asks him nothing
  (vendor-release §1, 56a766ed).
- 2026-09-30: workers and reviewers use only what his toggles allow; a live proof that needs a vendor he switched
  off is not run, it goes into the report's ask. («Updater doctor»)
- 2026-09-29: fixer chats start only on his button, never on a timer; data collection may run on its own cadence.
  Integrators learn a surface's purpose before changing it. («Updater doctor»)
- 2026-09-24: checks run daily; a flap that reverted closes itself; waiting events go to one chat at most once a week;
  never shorten that or open a chat per event without his word; «сделай апдейт» is the immediate path.
  («Updater doctor»)
- 2026-09-23: newest model everywhere, no hardcoded ids; a release is an integration task, not a version bump;
  accounts are a dynamic set, resolved per account, with divergence detected mechanically. The release history stays
  prose cleaned by resolution, never by age, and a little imprecision is accepted for simplicity. A generation is
  bought by the claim it proves, as one ask per release. A capability goes where the other vendors expose theirs,
  with the same names and look. («Updater doctor»)

## Open

- Section 6 before its turn: a trade. 14 goals are queued ahead in blocks 1–5.
  - Cost: vendor jobs in every pilot night from now, ≈0.03 % of a week's Claude spend per event and a 32 min median
    per run, started after the goal lands; it goes against 10-19's "sections return in their turn".
  - Loss if they wait: about 10 events a week pile up, the lag grows a day per day, and new models and flags stay
    unused.
  - Recommendation: keep the queue and press the Updater's Fix button once now. That path already exists and
    changes no decision.
- Changes no facet reads: no provable goal yet.
  - Both past misses are caught by today's code (64f8354e, 56a766ed), so a replay shows no difference between old
    and new.
  - What is still unread (grok plan, Claude `fable`, Gemini's plan name) has no recorded miss.
  - What settles it: the first full pass after 56a766ed, checking that notcom's Argon joins the gemini event.
  - A generic per-account projection stays a proposal until a miss shows a field it would have caught.
- Detection delay (change → event) is outside the metric: ≤2 h for a CLI release, ≤24 h for a server catalog or
  plan, weeks for vendor-watch rows (10-14's are dated 09-05…10-06). Those are blocks 0 and 9.
- Ready: not yet checked by a fresh model that did not write this file.
