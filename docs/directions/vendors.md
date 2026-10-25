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
- Health, not activity: per change, so more releases do not move it, nor more work unless every change closes
  sooner. Its floor is the gap to the next night (Egor launches nights; fixer chats open only on his own act,
  Decisions 09-29): with a night a day, ≈1 d or less, as the first window shows.
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

- Lag, local days UTC+3. W1 `a=2026-10-05T21:00:00Z` `b=2026-10-12T21:00:00Z`; W2 `a=2026-10-12T21:00:00Z` `b=2026-10-19T21:00:00Z`.:
  `q='[.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z") | ((([.closed_at // $b, $b] | min) | fromdateiso8601) - (.created_at | fromdateiso8601)) / 86400] | {n: length, mean: (add / length), max: max, days: add}'`
  then `jq -s --arg a "$a" --arg b "$b" "$q" ~/.cache/vendor-cli-update/events/*.json` once per window.
- Open at the window's end (created in the window, `closed_at` null or ≥ `$b`): W1 is 1, W2 is 9.
  `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z" and (.closed_at == null or .closed_at >= $b))] | length' ~/.cache/vendor-cli-update/events/*.json`
- Auto-closed, and vendor-watch among the lag set: `jq -s --arg a "$a" --arg b "$b" '{auto: [.[] | select(.created_at >= $a and .created_at < $b and .status == "auto-closed")] | length, watch: [.[] | select(.created_at >= $a and .created_at < $b and .status != "auto-closed" and (.reason | tostring | startswith("vendor-watch")))] | length}' ~/.cache/vendor-cli-update/events/*.json` → W1 8 and 0, W2 2 and 5.
- Guard, on `closed_at` in the window (12 and 3 events closed; 09-28T21:00Z…10-05T21:00Z: 65 of 129, 50 %):
  `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.closed_at != null and .closed_at >= $a and .closed_at < $b and .status != "auto-closed" and .id != "grok-20261008T234948Z") | .decisions[]?.decision] | {rows: length, not_integrated: map(select(. != "integrated")) | length}' ~/.cache/vendor-cli-update/events/*.json`
- Spend (token-map; the orchestrator's own turns and the other vendors' pools are not counted). Raw 0.356 over 11 cwds, 0.128 over 3; W1 swaps the timestamps:
  `sqlite3 ~/.local/share/tokenmap/tokenmap.sqlite3 "SELECT round(100.0*sum(CASE WHEN (cwd LIKE '%/worktrees/vendor-%' OR cwd GLOB '*/worktrees/night-*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx][a-z]*') AND NOT cwd GLOB '*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx]*-*-*' THEN cost_in+cost_out END)/sum(cost_in+cost_out),3), count(DISTINCT CASE WHEN (cwd LIKE '%/worktrees/vendor-%' OR cwd GLOB '*/worktrees/night-*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx][a-z]*') AND NOT cwd GLOB '*Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[cgx]*-*-*' THEN cwd END) FROM requests WHERE vendor='claude' AND ts>='2026-10-12T21:00:00' AND ts<'2026-10-19T21:00:00'"`
- Runs, same windows on `launched_at`:
  `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.launched_at >= $a and .launched_at < $b and .closed_at) | ((.closed_at | fromdateiso8601) - (.launched_at | fromdateiso8601)) / 60]' ~/.cache/doctors/runs/updater-release-*.json`
- Nights started, `started_at` in the same windows: `jq -s --arg a "$a" --arg b "$b" '[.[] | select(.started_at >= $a and .started_at < $b)] | length' ~/.cache/doctors/nights/*.json` → 6 and 3.
- Changes noticed outside the fingerprint, by hand: Egor's messages 10-05…19 (new model or version, bought,
  subscription, appeared, gone) against event times; a floor. 10-08 19:54Z: Claude Code 2.1.295
  (native claude 2.1.288 under `DISABLE_AUTOUPDATER`), its event 20:12Z after the fix; 10-19 14:13Z: Gemini Pro
  bought on notcom (Argon), no event.

## Sources

- Event store above (`.diff`, a waiting event's `.base`, `.decisions.tsv`), written by `vendor-fingerprint check`
  after `bin/vendor-cli-update`'s full pass; `fingerprints/<vendor>.json`, `update.log`, `state.json`.
- Runs: `~/.cache/doctors/runs/updater-release-*.json`; nights' `jobs[]` of kind `vendor` / `vendor-watch`.
- Updater doctor `~/.cache/updater-doctor/latest.json`: `event-waiting` (from 0 d), `event-stuck` (2 d),
  `plan-changed`, `family-partial`, `family-gone`. `share/updater-ledger.json` is empty.
- `docs/vendor-release-open.md`: 21 claims (10-23) a closed event left unproven or blocked, the oldest from 09-23.
- agy's live tool calls: `~/.gemini-profiles/*/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript_full.jsonl`
  (720 files from 10-09), `tool_calls[].name` and `.args`.

## Recurring classes

Ranked 10-20 by what they cost, over 10-06…19.

| class | 10-06…12 | 10-13…19 | cost | instances fixed |
|---|---:|---:|---|---|
| events wait for a night that does not take them | 0 open | 9 open | 47.6 event-days | 998dd4be, proof pending |
| a vendor change no facet reads: Egor finds it | 1 | 1 | his notice and a hand-run chat (Argon 10-19: 13707749 and 4 more commits) | installs 09-23, native claude 64f8354e, plans 56a766ed |
| a false event: an id string nothing serves, our own change | 4 + 1 own | 0 | one strong-model run each (W1 0.36 % ÷ 13 ≈ 0.03 % per event) | fe3841b9, 52ec96b0 |
| a closed event's change breaks a surface the run missed | 0 | 1 | review-bench T2 rater crashed 10-13 13:10+0300, 3.8 h after agy 1.3.3's close | review-bench@4288f13 |
| a claim closed unproven waits on Egor's toggles or word | 14 lines | | live proofs not run | (decisions) |

Why they come back:
- **One trigger.** Only a full night's dispatch step 3 (`vendor-fingerprint request --night`, `docs/night-run.md`;
  prep requests nothing) integrates an event by itself; else it waits for Egor's «сделай апдейт» (the Fix buttons went 10-20, 4f742b19). Pilot nights forbade it
  (6a5f1c46) until goal night-events; no night ran 10-14…24 (cef6 a breakages pilot), and «сделай апдейт» (10-20)
  was the one path used. A waiting event
  absorbs later releases (claude's 10-14 one covered 2.1.299–304).
- **A facet per miss.** The fingerprint sees only what a facet reads, each added after Egor found a miss:
  ChatGPT.app's bundled codex (09-23), the native claude (10-08), per-account Gemini catalogs and plans (10-19).
  Unread: a grok account's plan (none stored), Claude's per-account `fable`, Gemini's plan name (only quota groups
  and `families`). A new facet only baselines. Argon joined the open gemini event at the first pass after 56a766ed
  (`update.log` 10-19T23:05:44Z), 9 h after Egor's notice, so 10-19 still counts outside.
- **False events** came from packed string tables gluing ids (agy 1.3.0–1.3.2, a grok cargo hash); none from
  52ec96b0 (10-09) until a line undoing a ruled-out one reopened claude 10-22: goal decided-reversal.
- **Missed surfaces.** A run decides each diff line, not each surface the change reaches; the resolver rule
  (vendor-release §3 step 7, row `cr`) removed the static pin that broke 10-13. A rename no diff line
  carried broke 10-20: goal served-tools.

## Block 1 and this block

The rule: a breakage goes to block 1, and an unintegrated change goes to block 6. One change is counted once.
- Block 1 (Breakages): something we run failed: a leg after a release (log audit, LLM doctor), or the update
  machinery (Updater `pass-failed`, `install-failed`, `probe-broken`, `cli-behind`, `client-too-old`,
  `caps-stale`). Block 1 fixes the leg.
- Block 6: a vendor change not integrated yet: `event-waiting` (outside block 1's sum), `event-stuck`,
  `plan-changed`, `family-partial`, `family-gone`, the second number. It fixes the procedure or the detection: a
  breakage from a closed event that missed the surface is block 1's leg and this block's `docs/vendor-release.md`
  or `vendor-fingerprint` fix.

## Goals

10-23 deep search, by harm.

### goal served-tools: a tool or argument agy's live sessions start calling reaches a vendor event

Class: missed surfaces. agy 1.4.3 renamed `view_file {AbsolutePath}` to `read_file {Path}` silently (no changelog
line; 1.4.6's strings still hold `view_file`). The 10-20 run closed it 11:52Z on "tool names match the stream
parser"; listens failed until e657e599 (19:26Z: gemini-listen, worker-run), and review-bench
`agy_stream_evidence` still dedupes only `view_file`. agy ships near daily, version-only releases auto-close.
- First step: the agy files (Sources) end `view_file` 10-19T19Z and start `read_file` 10-20T18:15Z on all 10
  accounts; then one agy cell stream after 10-20 via review-bench's own commands (never `.claudeb` by hand):
  does `read_file` still answer `N lines, M bytes`, a re-opened file counted twice? If not, drop review-bench.
- Change: a gemini `tools` facet in `vendor-fingerprint`: the stored value plus `name` and `name.<arg key>` called
  in those files since the last check (nothing leaves: only additions diff). vendor-release §3 step 6: a parser's
  tool names are checked on a live session of the new version (this facet or one Flash probe), never strings.
- Proof, a replay at each full pass 10-13…23 (`update.log`), seeded 10-09…12. Old: no tool line in any diff
  (`grep -c 'read_file\|view_file' events/*.diff`: 0). New: 10-14 20:13Z `run_command.IsDaemon`,
  `.RequestedTerminalID` land in gemini-20261014T201301Z; 10-20 21:44Z `read_file`, `read_file.Path` open an event,
  `.EndLine`, `.StartLine` (first called 10-21T12:58Z) join at gemini-20261022T060140Z: 2.3 h after the hand fix (10-20 still counts outside), so the gain is
  its run finding every parser of the old name, and a version-only rename opening an event at all.
- Target, 14 days: breakages from an agy tool rename 0 (10-06…19: 0; 10-20…23: 1). Not worse: events opened by
  `tools` alone ≤ 1 per 14 days (the replay's), else reverted; check time; the guard.

### goal decided-reversal: a line undoing one a run ruled not-applicable opens no event

Class: false events. Open `claude-20261022T233722Z` holds one substantive line, `-claude-platform-on-aws-06w`,
undoing the `+` line `claude-20261014T201317Z` ruled not-applicable 10-20; `ids_unserved` keeps it (no served stem)
and the flap re-check reads only a pending event.
- Change, `changes()` beside `ids_unserved`: an event whose every substantive line exactly reverses (`+`↔`-`, `*`
  rows aside) one that an event closed before its creation ruled `not-applicable` auto-closes, noting that event; a
  mixed event keeps every line and its route.
- Proof, a replay of old and new `changes()` over the 56 events since 09-23 not auto-closed (`events/*.json`,
  `*.diff`), decisions as of each creation. Old: 56 open. New: claude-20261002T021805Z (2.1.287 drops the
  `--client-data-url` block claude-20260926T203455Z ruled out) and claude-20261022T233722Z auto-close, not
  grok-20261008T234948Z (created 23 s before grok-20261008T201239Z closed, its line ruled `integrated`). Of 13
  reversal lines, the 10 in closed events were all ruled not-applicable again (6 only by `*` rows);
  `codex-20261020T214448Z`'s 2 of 28 keep it open.
- Gain: 2 false events in 30 days, ≈1 per 15 days with no run (run time unconfirmed: claude-1002's 3.1 h, 10-20's
  batch 44 min each), up to 0.14 % of a week's Claude spend (10-20's Opus batch, 1.28 % for 9 events; the 1.28 %
  unconfirmed). Not worse: no integrated or blocked line pre-decided (replay 0); net lines.

Dropped 10-23:
- Version-only releases close unread (claude 2.1.305–308, agy 1.4.4–5): no changelog entry names a setting, env or
  flag the repos use (grep 0).
- 2.1.302 fork subagents in `claude -p`: `CLAUDE_CODE_FORK_SUBAGENT=0` everywhere; no requestId repeats across files.
- Codex PARTIAL file lists (28 runs, `exec`/`exec_command`/`run`): worker-run's own "naming no tool" rule.
- 10-20's batch on Opus: a watch event made it non-cheap; Sonnet lowers the model.
- vendor-release-open 09-30 "sonnet-5-5 never served" is stale (14,079 requests 10-09…23): the next claude run.

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
| 10-23 | goal night-events: a pilot night past blocks 1–5's goals runs step 3's Vendors after its goals (`pilot_vendors`) | proof pending, the first such night: events open at its start → 0; then 7-day lag ≤ the gap between nights, guard 50–69 %, else reverted | 998dd4be, +35 net lines |

## Decisions

- 2026-10-19: the split above (0 installs, 6 integrates new models, plans and flags, 1 fixes a broken path, 9 vendor
  news, postponed); the Metric was proposed there, Egor has not replied. («Updater doctor»)
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
  - Cost: vendor jobs in every pilot night from now, ≈0.03 % (Sonnet) to 0.14 % (Opus, 10-20) of a week's Claude
    spend per event and a 32 min median per run, after the goal lands; against 10-19's "sections return in their turn".
  - Loss if they wait: about 10 events a week pile up, the lag grows a day per day, and new models and flags stay
    unused.
  - Recommendation: keep the queue; «сделай апдейт» closed the 9 on 10-20 (11:18–13:33Z); the 4 opened 10-20…22
    are still open 10-25.
- Changes no facet reads: a goal only once a miss shows the field (agy's tool names did: served-tools). The grok
  plan, Claude `fable` and Gemini's plan name have none; a generic per-account projection stays a proposal.
- Detection delay (change → event), outside the metric: ≤2 h a CLI release, ≤24 h a catalog or plan, weeks a
  vendor-watch row; blocks 0 and 9.
- Ready: checked 2026-10-20 by a fresh grok session (c4f02ce9).
