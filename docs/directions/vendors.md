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
  decided (`close --decisions`, vendor-release §4), but a not-applicable or blocked line closes as fast as an
  integrated one, so the lag alone would reward closing without integrating: the guard below reads that.
- Health, not activity: it is per change, so more vendor releases do not move it, and more integration work moves it
  only if every change closes sooner. Its floor is the gap to the next night, since Egor launches nights and fixer
  chats open only on his button (Decisions 09-29). With a night every day the lag tends to ≈1 d or less; the first
  window shows that floor.
- Second number, target 0: vendor changes noticed outside the fingerprint, where Egor, a chat or a breakage found
  the change before any event did.
- Guard, read with the lag: the share of decided lines (`.decisions[]` rows, a `*` row covering its prefix) that are
  not-applicable or blocked, over events closed in the window. A lag drop while it rises above its range (50–69 %,
  three windows) does not count.

### Baseline (computed 2026-10-20)

| | 10-06…12 | 10-13…19 |
|---|---:|---:|
| events (not auto-closed) | 13 | 11 (5 vendor-watch) |
| **mean lag, days** | **0.12** | **4.32** |
| max lag, days | 0.63 | 5.67 |
| open at the window's end | 1 | 9 |
| event-days waiting | 1.5 | 47.6 |
| auto-closed (out) | 8 | 2 |
| **changes noticed outside the fingerprint** | **1** | **1** |
| **guard: decided lines not-applicable or blocked** | **69 % (75 of 108)** | **55 % (6 of 11)** |
| integration sessions' share of Claude spend | 0.36 % (11 sessions) | 0.13 % (3) |
| integration runs, launch → close, wall clock | 11, median 32 min | 2: 169, 384 min |
| nights started | 6 | 3 (the last one 10-14 01:37Z) |

- Lag, local days UTC+3. W1 `a=2026-10-05T21:00:00Z` `b=2026-10-12T21:00:00Z`; W2 `a=2026-10-12T21:00:00Z` `b=2026-10-19T21:00:00Z`. The table rounds mean and max to 2 decimals and event-days to 1 (W1 raw 0.119, 0.630, 1.542; W2 raw 4.325, 5.672, 47.574):
  `q='[.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z") | ((([.closed_at // $b, $b] | min) | fromdateiso8601) - (.created_at | fromdateiso8601)) / 86400] | {n: length, mean: (add / length), max: max, days: add}'`
  then `jq -s --arg a "$a" --arg b "$b" "$q" ~/.cache/vendor-cli-update/events/*.json` once per window.
- Open at the window's end (created in the window, `closed_at` null or ≥ `$b`): W1 is 1 (`grok-20261012T191955Z`, closed 2026-10-13T02:45:07Z), W2 is 9.
  `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z" and (.closed_at == null or .closed_at >= $b))] | length' ~/.cache/vendor-cli-update/events/*.json`
- Auto-closed, and vendor-watch among the lag set: `jq -s --arg a "$a" --arg b "$b" '{auto: [.[] | select(.created_at >= $a and .created_at < $b and .status == "auto-closed")] | length, watch: [.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and (.reason | tostring | startswith("vendor-watch")))] | length}' ~/.cache/vendor-cli-update/events/*.json` → W1 8 and 0, W2 2 and 5.
- Guard, on `closed_at` in the window (12 and 3 events closed; 09-28T21:00Z…10-05T21:00Z: 65 of 129, 50 %):
  `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.closed_at != null and .closed_at >= $a and .closed_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z") | .decisions[]?.decision] | {rows: length, not_integrated: map(select(. != "integrated")) | length}' ~/.cache/vendor-cli-update/events/*.json`
- Open now: `jq -s '[.[] | select(.status == "open")] | length' ~/.cache/vendor-cli-update/events/*.json` (9: watch
  ×5 10-14 04:51Z, codex 0.162.1→0.163.0, agy 1.3.4→1.4.2, claude 2.1.296→2.1.304, grok 1.0.52→1.0.62 with grok-4.7).
- Spend (token-map; the orchestrator's own turns and the other vendors' pools are not counted). The table is `round(pct, 2)` of this query (raw 0.356 over 11 cwds, 0.128 over 3); swap the two timestamps for W1:
  `sqlite3 ~/.local/share/tokenmap/tokenmap.sqlite3 "SELECT round(100.0*sum(CASE WHEN (cwd LIKE '%/worktrees/vendor-%' OR cwd GLOB '*/worktrees/night-*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx][a-z]*') AND NOT cwd GLOB '*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx]*-*-*' THEN cost_in+cost_out END)/sum(cost_in+cost_out),3), count(DISTINCT CASE WHEN (cwd LIKE '%/worktrees/vendor-%' OR cwd GLOB '*/worktrees/night-*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx][a-z]*') AND NOT cwd GLOB '*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx]*-*-*' THEN cwd END) FROM requests WHERE vendor='claude' AND ts>='2026-10-12T21:00:00' AND ts<'2026-10-19T21:00:00'"`
- Runs, same windows on `launched_at`, minutes rounded (W1 median of the 11 is 31.9 → 32; W2 168.9 → 169 and 383.6 → 384):
  `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.launched_at >= $a and .launched_at < $b and .closed_at) | ((.closed_at | fromdateiso8601) - (.launched_at | fromdateiso8601)) / 60]' ~/.cache/doctors/runs/updater-release-*.json`
- Nights started, `started_at` in the same windows: `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.started_at >= $a and .started_at < $b)] | length' ~/.cache/doctors/nights/*.json` → 6 and 3; the last is `2026-10-14T01:37:50Z`.
- Changes noticed outside the fingerprint, read by hand (Egor's messages 10-05…19 searched for new model or version,
  bought, subscription, appeared, gone, then checked against the event times; a miss he never mentioned is not
  counted, so this is a floor). 10-08 19:54Z, «Updater doctor»: Claude Code 2.1.295 was out and the Updater did not
  show it, because the native claude sat at 2.1.288 under `DISABLE_AUTOUPDATER` and the check ran once a day. The
  event opened at 20:12Z, after the fix. 10-19 14:13Z, «Workers и review bench унификация отображения»: Egor bought
  Gemini Pro on notcom that day (Plus before), and Gemini 4 Argon appeared there, with no event and no Updater row.

## Sources

- Event store above (`.diff`, `.base` of a waiting event, `.decisions.tsv`). Events are written by `vendor-fingerprint
  check` at the end of `bin/vendor-cli-update`'s full pass. Fingerprints: `fingerprints/<vendor>.json`; `update.log`,
  `state.json`.
- Runs: `~/.cache/doctors/runs/updater-release-*.json`; nights' `jobs[]` of kind `vendor` / `vendor-watch`.
- Updater doctor `~/.cache/updater-doctor/latest.json`: `event-waiting` (from 0 d), `event-stuck` (2 d),
  `plan-changed`, `family-partial`, `family-gone`. `share/updater-ledger.json` is empty; the night snapshots'
  `updater` rows 10-06…14 are 8 `event-waiting` ids plus `foreign-client` watch rows.
- `docs/vendor-release-open.md`: 14 claims a closed event left unproven or blocked, the oldest from 09-23.

## Recurring classes

Ranked 10-20 by what they cost, over 10-06…19.

| class | 10-06…12 | 10-13…19 | cost | instances fixed |
|---|---:|---:|---|---|
| events wait for a night that does not take them | 0 open | 9 open | 47.6 event-days; grok-4.7, codex 0.163.0, Claude Code 2.1.299–304 unread | 0 |
| a vendor change no facet reads: Egor finds it | 1 | 1 | his notice and a hand-run chat (Argon 10-19: 13707749 and 4 more commits) | installs 09-23, native claude 64f8354e, plans 56a766ed |
| a false event: an id string nothing serves, our own change | 4 + 1 own | 0 | one strong-model run each (W1 0.36 % ÷ 13 ≈ 0.03 % per event) | fe3841b9, 52ec96b0 |
| a closed event's change breaks a surface the run missed | 0 | 1 | review-bench T2 rater crashed 10-13 13:10+0300, 3.8 h after agy 1.3.3's close | review-bench@4288f13 |
| a claim closed unproven waits on Egor's toggles or word | 14 lines | | live proofs not run | (decisions) |

Why they come back:
- **One trigger.** A full night's dispatch step 3, Vendors (`vendor-fingerprint request --night`, `docs/night-run.md`;
  prep's `vendor-cli-update now --night` requests nothing), is the only automatic way an event gets integrated;
  otherwise it waits for Egor's Fix button or «сделай апдейт». Since 10-15 every new night is a pilot, and its rules
  forbid `vendor-fingerprint` (6a5f1c46, 47eb5afc). No night has run since 10-14, Egor did not
  know the button (ef00e2ba), and his last «сделай апдейт» was 09-24. Only the Updater rows showed the wait. A
  waiting event absorbs later releases, so claude's single event now covers 6 installed versions (2.1.299–304; `update.log` jumps 2.1.296→2.1.299).
- **A facet per miss.** The fingerprint sees only what a facet reads, and each facet was added after Egor found a miss:
  ChatGPT.app's bundled codex (09-23), the native claude (10-08), per-account Gemini catalogs and plans (10-19).
  Still unread: a grok account's plan (the store records none) and Claude's per-account `fable`. Gemini's plan name
  is recorded nowhere, only its quota groups and `families`. A facet new to a fingerprint is a baseline, not a change,
  so `plans` will only baseline. notcom's Argon reached the open gemini event through the new catalog shape: the
  first full pass after 56a766ed (`update.log` 2026-10-19T23:05:44Z, «gemini-20261014T201301Z open, joined: catalog»)
  wrote `+gemini-4-argon … notcom` into its `.diff` (`grep -n argon …/events/gemini-20261014T201301Z.diff`), 9 h
  after Egor's notice, so 10-19 still counts outside.
- **False events** came from packed string tables gluing ids (agy 1.3.0–1.3.2, a grok cargo hash). There have been
  none since 52ec96b0 (10-09), so the class is watched, with no goal.
- **Missed surfaces.** A run decides each diff line, not each surface the change reaches; the resolver rule
  (vendor-release §3 step 7, `test_consistency.sh` row `cr`) removed the static pin that broke. One row; watched.
  3.8 h is `gemini-20261012T233139Z` `closed_at` 2026-10-13T06:19:58Z (09:20+0300) to the skeleton line `13:10`
  in `~/.cache/doctors/log-audit/runs/20261014T013750Z-8004/chunk-029.md`; that clock is +0300 (commit `0d285efd`
  is stamped 12:17:25+0300 on the 12:17 line of the same transcript).

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

### goal night-events: from this block's turn, every pilot night integrates the vendor events waiting at its start

Class: events wait for a night that does not take them. 9 events are open, 3.8–5.7 d old on 10-19; no instance has
been fixed.
- Change in `bin/night-run`, only once the pilot reaches this block. Today `cmd_start` puts PILOT_RULES into every
  pilot night's prompt, and its no-list names `vendor-fingerprint`, so prep runs only `vendor-cli-update now --night`
  (which requests nothing) and dispatch step 3's Vendors never runs. New: when `vendors` is in PILOT and no direction
  before it has a `### goal` section left at the start (pilot_goal's own test), the marker drops `vendor-fingerprint`
  from the no-list and adds step 3's Vendors: `vendor-fingerprint request --night R`, which builds per waiting vendor
  its fixer run, worktrees on `night/R/<vendor>` and a brief, printing `<run>\t<brief>\t<worktree>`; it runs after
  the night's goal job lands, so a goal is still judged alone on its spend and load, and each branch lands per
  branch. Pilot nights before that keep today's rules. No new hook or suite: `tests/test_night_run.sh`'s pilot case
  gains a reached-vendors case. Net lines: `git diff --shortstat <landing>^ <landing> -- bin/night-run
  tests/test_night_run.sh`, insertions minus deletions, written into Done.
- Proof, fixed now. Old: a pilot night leaves every event open at its start still open (9; PILOT_RULES forbids
  the request since 10-15, and no night has run since 10-14). New: the first pilot night past this goal closes every event open at its start (0 left
  open): integrated, not-applicable, or blocked with a line in `vendor-release-open.md`. Its goal job's spend and
  minutes in the night header are unchanged, because the vendor jobs start after the goal lands.
- Read after landing: mean lag over the next 7 days at or under the mean gap between nights, target ≈1 d or less
  with a night every day (10-06…12: 0.12 d over 6 nights). Events open at a night's start and still open at its
  close: 0. Not worse: the guard within 50–69 %, the integration sessions' spend share per event against 10-06…12
  (≈0.03 %), and the second number. A night closing with an event still open, or the guard out of range: reverted.

## At night

- Section 6, Vendor events (README "The whole night"), plus the vendor-watch events block 9 opens. The Updater
  doctor and the CLI installs stay in block 0's prep.
- The first night is judged on: every event waiting at its start closed by Close; each run starting with "purpose
  before change" (vendor-release §1) and deciding every diff line; a blocked line naming what Egor's word unlocks;
  the night header showing each vendor job's spend; the guard within its range.

## Done

| date | change | result | evidence |
|---|---|---|---|
| 09-23/24 | fingerprint and events; daily checks; a flap that reverted closes itself | | `vendor-fingerprint`, `update.log` |
| 10-04 | an install ahead of the primary is no event | | 2a30c530 |
| 10-07, 10-09 | ids facet holds only served ids; cheap events go to Sonnet | false events 4 → 0 per week | fe3841b9, 52ec96b0 |
| 10-08 | releases seen within 2 h; the updater owns the native claude | | 64f8354e |
| 10-19 | per-account catalogs and plans become events; Argon serves only on accounts that list it | Argon joined the gemini event 10-19 23:05Z | 56a766ed, 13707749 |

## Decisions

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
- Changes no facet reads: no provable goal. Both past misses are caught by today's code (64f8354e; 56a766ed, live
  since Argon joined `gemini-20261014T201301Z` 10-19 23:05Z), so a replay shows no old/new difference; what is
  still unread (grok plan, Claude `fable`, Gemini's plan name) has no recorded miss. A generic per-account
  projection stays a proposal until a miss shows a field it would have caught.
- Detection delay (change → event) is outside the metric: ≤2 h for a CLI release, ≤24 h for a server catalog or
  plan, weeks for vendor-watch rows (10-14's are dated 09-05…10-06). Those are blocks 0 and 9.
- Ready: checked 2026-10-20 by a fresh grok session (c4f02ce9).
