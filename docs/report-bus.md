# Report bus

`bin/report-bus` owns delivery of user-facing reports. Producers supply text; the bus owns
queueing, rendering, replay and diagnostics. `~/.local/bin/report-bus` is a symlink to the script.
Requires Bash, jq and shasum.

## CLI

```text
report-bus post --kind <kind> [--id <id>] [--session <uuid>] [--repo <path-or-name>] [--title <text>] [FILE]
report-bus emit --kind <kind> [--id <id>] [--repo <path-or-name>] [--title <text>] [--context <text>] [--event <event>] [FILE]
report-bus flush --event <PostToolUse|SubagentStop|Stop|UserPromptSubmit> [--session <uuid>]
report-bus list [--session <uuid>] [--last N]
report-bus doctor
```

Kinds are `review`, `commit`, `push`, `pool-run`, `worker`, `notice`. Other kinds and bad
arguments exit 2. Session IDs contain only letters, digits, `.`, `_`, `-`; empty sessions, `.` and `..`
are invalid. Report IDs replace other characters with `-`; `.` and `..` gain a `report-` prefix. The default ID is the first 12 hex digits of the body's
SHA256. The dedup key is `<kind>/<id>` within a session, checked against pending, delivered
and history, including orphan records adopted by another chat. A duplicate writes no second file and prints nothing: `post` exits 0, `emit` exits 3 so its producer can tell a suppressed report from a broken bus.

`post` reads FILE or stdin and atomically writes one queue file, using a temporary file and
rename. Directories are created on demand. Delivery errors exit 0 with `report-bus: <reason>`
on stderr and the body appended to `lost.log`. If the filesystem also refuses that append,
stderr carries the body; an unwritable filesystem cannot retain a log.

Session resolution: explicit `--session`; `$WORKER_RUN_DIR/launcher` when that variable names
a run, otherwise `CLAUDE_LAUNCHER_SESSION`; `CLAUDE_CODE_SESSION_ID`; `_orphan`.
The environment fallback also uses review-bench's launching-session registry walk: up to
15 process ancestors in `${REVIEW_BENCH_SESSION_DIR:-$HOME/.claude/sessions}/<pid>.json`,
field `sessionId`. Inferred sessions follow `worker-session` → `launcher` records under
`${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}` to the launching chat, stopping on cycles
or ambiguous ownership. Explicit sessions win unchanged.

`emit` is the hook producer path: the same renderer prints one `{"systemMessage":"…"}`
(the message opens with a newline, as the producer fallbacks do) and appends its text to
history, with no pending file. Optional `--context` adds
`hookSpecificOutput.additionalContext` with `hookEventName` from `--event` (default
`PostToolUse`), preserving model directives alongside the user-facing report. `flush` reads hook JSON from stdin
when `--session` is absent: `session_id`, `agent_id`, `transcript_path`, `agent_type`.
It skips `CLAUDEB_WORKER=1`, nonempty `agent_id`, `/subagents/` in the transcript path, and
the worker-tag agent types `codex-worker`, `claudeb-worker`, `gemini-worker`, `grok-worker`,
`image-gen`, `gemini-research`. Skipped queues stay pending.

## Rendering and storage

```text
▌ <kind> · <repo or account> · HH:MM[ · <title>]
<body verbatim, trailing whitespace trimmed>
```

The repo is the basename of `--repo`; without it the entire repo segment is omitted.
The clock is local posting time. Orphan reports include `chat: unknown` below the header.
Bodies retain internal whitespace and line breaks. Blocks are separated by one blank line.

Root: `${XDG_CACHE_HOME:-$HOME/.cache}/claude-reports`.

```text
<root>/<session>/pending/<epoch-ns>__<kind>__<id>.txt
<root>/<session>/delivered/<epoch-ns>__<kind>__<id>.txt
<root>/_orphan/pending/
<root>/history.log
<root>/lost.log
```

Queue files contain JSON metadata and the original body. History is JSONL: one line per
delivery with `epoch`, `session`, `kind`, `id`, `bytes`, `event`, plus `source_session` and
rendered `text` for replay and orphan dedup. `list` reprints the last 10 deliveries for the
resolved chat by default. `--last 0` prints nothing. History survives delivered-file pruning.

A store lock serializes posting and draining, including orphan adoption. It records its owner
PID and is recovered when that process is dead or the lock is older than 60 seconds. Flush visits this
session's pending files and the orphan queue in mtime order. Any session can drain orphans;
the first successful drain moves them into its own delivered directory. One hook JSON contains
all selected blocks. The rendered payload is capped at 16000 bytes; whole remaining blocks
stay pending. A single oversized block is delivered alone, exceeding the cap without truncation;
the next flush continues with the following report. Stop reserves space for its undelivered count. Delivered files are pruned to
the newest 200 per session at flush. No undelivered file is pruned.

`doctor` prints pending counts older than 10 minutes per session, `lost.log` size and orphan
count. A Stop with files still pending includes this line in the same systemMessage:

```text
report-bus: N report(s) undelivered — <root>/<session>/pending
```

## Delivery guarantees

The claude-setup `report-flush.sh` hook supplies the four event entry points. The bus suite
pins event draining; hook registration is verified in that repository.

1. A report posted during a tool call is shown at that call's PostToolUse, in the same turn.
2. A report posted inside a worker or subagent is shown when the Agent tool returns, through
   PostToolUse Agent or SubagentStop of the launcher. Worker transcripts receive no flush.
3. A background report is shown at the chat's next hook event. Stop drains the queue within
   the payload cap and names any remainder; UserPromptSubmit drains reports posted while idle.
4. Render failures keep the file pending; Stop reports the count. Failed hook-JSON encoding
   also keeps the selected files pending. `lost.log` retains posting failures when writable.
5. The same kind/id is shown once per chat; history preserves dedup after delivered pruning.

No hook fires while a chat is idle with no turn in progress. A background report produced
then waits for the next prompt. A broken renderer or unavailable filesystem remains visible as undelivered rather than
causing a report to be truncated.

`worker-run` posts on every terminal outcome through `outcome_line`, including detached
completion, killed runs, unknown exits and launch refusals. The body has three lines:
OUTCOME, vendor/account/model/effort and wall-clock, files count. Missing `report-bus` is a
silent no-op. A per-run receipt prevents repeated wait/report calls from posting again. The posting marker
records its PID, is removed on exit, and is recovered after 60 seconds or when its owner dies.
A refused launch reports under a run ID of its own and never the id of the run it names, so its
report cannot dedup away that run's own completion; the id stays internal, because a printed `RUN:`
line means a run directory exists.
