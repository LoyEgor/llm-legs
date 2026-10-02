# Hand-off: a stop hook journalled "not executable" at its own creation

Status: open

For the chat «Harness Doctor» (owner of `share/harness-ledger.json`). Written 2026-10-02 by night
fixer run `harness-stop-hooks-20261002T093037Z-0eb0`.

## Problem

`hook-error:ask-pr-mattermost.sh` — one `not executable` line, `stop:2026-10-01T19:25:41Z/2ddedf36…`.

## Finding

- `~/.claude/hooks/stop.d/` gained `ask-pr-mattermost.sh` at 22:25 local, the minute of the line;
  the file has been `0755` since. It is untracked WIP of another chat in claude-setup main.
- The same shape happened to `notice-word-journal.sh` at its creation (2026-09-17, two lines).
- `stop-dispatch.sh` did what it says: a hook without `+x` is journalled, never skipped in silence.
  The file was written first and chmodded after, and one stop fell in between.

## Proposal

Dismiss row `hook-error-ask-pr-mattermost-creation` (narrowed `open` row, exact ident). A fixer may
not write the dismissal: it is the judge. If creation-time hits recur, the owner might consider
having the rule skip a `not executable` line whose file is younger than a few minutes. That would
be a judge change too.
