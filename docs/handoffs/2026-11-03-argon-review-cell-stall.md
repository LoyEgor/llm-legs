# Hand-off: the Gemini Argon review cell stalls and ends empty

Status: stall fixed in review-bench (`launch.py`: an agy cell's heartbeat is its conversation db, not its
log); Q5 open. Taken by «Workers и review bench унификация отображения».
To: the chat Egor assigns to fix Argon review cells (Egor 2026-11-03: «Я хочу Argon починить»)

## Answers (2026-11-03)

1. The silent-gap stall cap (353 s) ended it, restarted by one housekeeping log line at 18:28:53: kill at
   18:34:47, 353 s later. Housekeeping lines also mean a really hung turn could outlive any cap.
2. A long thinking phase, not a hung stream: the kept db's step 45 (ResponseID `CQvqauTyMLj9vdIP2ryDwA4`)
   generated from 18:25:52 until the kill, 37 772 thinking tokens (~70/s) and a 61 KB thinking summary.
   agy prints nothing on stdout while its model thinks and its log only gets one line per request; the
   conversation db (`<state>/antigravity-cli/conversations/<id>.db` + `-wal`) takes the streamed thinking
   every ~6 s. Probes on Flash: the WAL grew every ~6 s while stdout and log stayed flat; while a tool
   ran, nothing was written (no timer writes). The cell now watches that db (size + mtime) as life.
3. `ours` stays: this stall was ours (the wrong heartbeat). With the db heartbeat a stall is a turn that
   wrote nothing for the whole cap.
4. agy has no per-request deadline; `--print-timeout` bounds the whole turn. The stall cap on the db is
   that deadline now. Resuming a cut turn (`agy --conversation <id>`) is possible, not built: no real hung
   stream on record.
5. Open. `20261101T141622Z-f0ac00d` (the `cap` row) was no stall either: 136 requests, longest gap 46 s,
   working until agy's 30-minute print timeout returned nothing.

Written by the chat that ran the review, from what it saw; nothing here was fixed or rerun. Goal: Argon
(`agy-argon-high`) review cells finish with findings instead of ending as `stall` or `cap`.

## The incident

Run `20261103T162248Z-1407284`: a `review-bench review --files bin/chat-load docs/memory-guard.md --tier T2
--panel frontier --task @/tmp/attribution-hunt.md` (an ideas hunt, web allowed, 1 113 lines, 2 files) in
llm-legs. Fable, Astra and Grok cells found 15, 24 and 6 proposals in 7.5-8.1 min. The panel's own lines:

    T2 · front:   12m / 12m gem-argon-high stall
                  gem-argon-high  1.1M   12m  stall
    failed:       gem-argon-high  stall · ours  12m

Cell: spec `agy-argon-high`, model `gemini-4-argon-high` («Gemini 4 Argon (High)»), account `notcom`, agy
1.4.12, cwd a temporary review worktree under `$TMPDIR/review-bench--claude-worktrees-90816-*`.

Timeline (EET, 2026-11-03), from `agy-agy-argon-high.log` and `raw-events-agy-argon-high.jsonl`:

- 18:22:56 first `streamGenerateContent`; then 44 `read_file` tool steps, several unrelated to the task
  (`share/worker-run-watchdog.sh`, `bin/statusline-ports-probe.sh`); 17 `streamGenerateContent` calls in all.
- 18:25:45 last tool step done (step 44, `read_file`, 0.15 s).
- 18:25:52 last model request: `streamGenerateContent`, Trace `0xb8559567dc052d16`, ResponseID
  `CQvqauTyMLj9vdIP2ryDwA4`. No step, chunk or error after it.
- 18:28:53 only `fetchAvailableModels` + `loadCodeAssist` (agy housekeeping).
- 18:34:47 `Got signal terminated, shutting down`: the panel cut the cell. 8 min 55 s of silence before it.
- Final event: `status ERROR, error "interrupted", duration_seconds 711.6, num_turns 1`; usage input 372 732,
  output 42 425, thinking 40 137, cache_read 1 598 871 tokens; `usage-agy-argon-high.jsonl`:
  `stream_generate_requests 17, stream_completions 1`.
- No `429`, `RESOURCE_EXHAUSTED`, quota or auth line anywhere in the agy log.

All files: `~/.claude-profiles/.claudeb/worker-stats/benches/20261103T162248Z-1407284/` (`agy-agy-argon-high.log`,
`raw-events-agy-argon-high.jsonl`, `result-agy-argon-high.json`, `usage-agy-argon-high.jsonl`,
`transcript-agy-argon-high`, `panel.log`, `meta.json`). The exact rerun command is line 1 of the panel's report
(`review-bench run 1407284374b6a58683fdeecfeb326118c2e2180f --raters agy-argon-high --repo
/Volumes/Work/Projects/llm-legs --task '…'`); `/tmp/attribution-hunt.md` holds the task text while /tmp lasts.

## Argon cells over two weeks (from each bench's panel.log)

    20261103T162248Z-1407284  1.1M  12m   stall      (this one)
    20261101T141622Z-f0ac00d  2.9M  30m   cap
    20261101T070950Z-6a1f687    8K  4.5m  16 found
    20261030T225116Z-a472922  1.6M  10m   13 found
    20261030T220314Z-7a09612  974K  17m    8 found
    20261030T100615Z-b54760c   21K  7.8m  16 found
    20261029T224842Z-c800e99   13K  12m    7 found
    20261029T162726Z-251f284  1.7M  8.0m   9 found
    20261028T144144Z-68d13d8  4.1M  8.9m   6 found
    20261026T151219Z-8bb7de4  476K  8.3m   9 found
    20261025T150923Z-43f722e   24K  4.7m  12 found   (gem-argon-med)
    20261023T134935Z-f419df8    7K  0s    failed
    20261019T195156Z-dd15414  444K  27m    1 found

Two of the last three high cells ended with nothing. Token use swings 7K → 4.1M on comparable targets; the
heavy ones read widely before answering.

## Where the stall verdict comes from (review-bench)

- `share/rbench/panel.py:225` `stall_cap_seconds`: a model/effort pair's stall cap = max(`STALL_CAP_FLOOR_S`
  240, its longest recorded silent gap + `STALL_CAP_GRACE_S` 120); None while no completion recorded a gap.
  Constants in `share/rbench/catalog.py:417-437` (`UNCAPPED_STALL_S` 900, `STALL_POLL_S` 0.25).
- `panel.py:539` `FAILURE_ORIGIN` files `stalled` (and `timeout`) as `ours`; `server error`, `capacity`,
  `throttled` as `theirs`. The report printed `stall · ours`.

## Open questions (not checked)

1. Which watch ended it: the silent-gap stall cap or the T2 wall (711.6 s ≈ the 12 m shown as `12m / 12m`)?
   What cap did the pair `agy-argon/high` hold at launch?
2. Was the last request a hung server stream, or a long thinking phase that streams nothing until it ends?
   The usage reports 42K output and 40K thinking tokens, yet the response came back empty with one turn; find
   where those tokens went (earlier streams, or the request that never returned).
3. If the server simply never answered, `ours` is the wrong origin for that row: a silent provider stream
   reads as the tool's own fault in every report and doctor.
4. Does the cell ask agy for any per-request deadline (`ask_gemini.sh` passes `--print-timeout`; does the
   review cell's agy call?) so one silent request fails fast and retries instead of eating the whole cell?
5. The wide reads (44 files, 1.6M cache read) on a 2-file `--files` target: does the Argon cell prompt or
   tool set invite them where other vendors' cells stay on target?

## Doctrine that applies (memories of the llm-legs chats)

- 429s and capacity are weather, never an auth verdict; never re-diagnose the Antigravity catalog split
  (Argon/Claude 5.5 only on notcom and rawilimo) or the family-pooled Gemini quota.
- agy leg cost is wall-clock minutes, not hit rates; speed work never lowers model, effort or thinking.
- Argon is a word-gated model: running it outside a panel needs Egor's word; a rerun of a review cell is a
  review launch on his grant.
- Before debugging, grep `docs/DIAGNOSTICS.md` (llm-legs) for the symptom; `review-bench doctor` is the
  system-level check.
