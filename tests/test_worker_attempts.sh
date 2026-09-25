#!/usr/bin/env bash
# The worker-attempts journal tokenmap zones worker sessions by: one line per attempt session, written
# with the account the attempt ran on, never twice for one session of a run, and bounded by rotation.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail(){ printf 'FAIL(line %s): %s\n' "${BASH_LINENO[1]-?}" "$*" >&2
  [ ! -f "$JOURNAL" ] || { printf -- '--- journal ---\n'; cat "$JOURNAL"; } >&2
  exit 1; }
asserts=0
assert(){ asserts=$((asserts + 1)); "$@" || fail "$*"; }

export WORKER_STATS_DIR="$WORK/stats"
JOURNAL="$WORKER_STATS_DIR/worker-attempts.jsonl"
RUN="$WORK/runs/codex-1790000000-1-abcd"
mkdir -p "$RUN"
jq -n '{vendor: "codex", account: "first", role: "research", light: "research", model: "astra",
        workdir: "/repo", resume: ""}' >"$RUN/meta.json"
printf '1\n' >"$RUN/attempt"
printf 'chat-session\n' >"$RUN/launcher"

record() { # session
  FAKE_SESSION="$1" ROTATE_BYTES="${ROTATE_BYTES:-16777216}" bash -c '
    source <(sed -n "/^record_worker_session() {/,/^}/p;/^file_bytes() {/,/^}/p;/^journal_worker_attempt() {/,/^}/p" "$1/bin/worker-run")
    WORKER_ATTEMPTS_ROTATE_BYTES=$ROTATE_BYTES
    session_id() { printf "%s\n" "$FAKE_SESSION"; }
    record_worker_session "$2"
  ' _ "$ROOT" "$RUN"
}

record 01a0-first
record 01a0-first
assert test "$(wc -l <"$JOURNAL" | tr -d ' ')" = 1
line=$(head -n1 "$JOURNAL")
assert test "$(jq -r '[.run, .attempt, .session, .vendor, .account, .role, .light, .launcher, .agent] | map(tostring) | join(" ")' <<<"$line")" \
  = "codex-1790000000-1-abcd 1 01a0-first codex first research research chat-session null"
assert jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <<<"$line" >/dev/null

# A reroute rewrites meta.account before the rescue attempt reports its session: the first line keeps
# the account that attempt ran on.
jq '.account = "second"' "$RUN/meta.json" >"$RUN/meta.tmp" && mv "$RUN/meta.tmp" "$RUN/meta.json"
printf '2\n' >"$RUN/attempt"
record 01a0-second
assert test "$(jq -r '.account' "$JOURNAL" | paste -sd, -)" = "first,second"
assert test "$(jq -r '.attempt' "$JOURNAL" | paste -sd, -)" = "1,2"

# An id nothing named leaves no line.
record -
assert test "$(wc -l <"$JOURNAL" | tr -d ' ')" = 2

# Past the bound the journal moves to one older segment, which replaces the previous one.
ROTATE_BYTES=10 record 01a0-third
assert test -f "$JOURNAL.1"
assert test "$(jq -r '.session' "$JOURNAL.1" | paste -sd, -)" = "01a0-first,01a0-second"
assert test "$(jq -r '.session' "$JOURNAL")" = "01a0-third"
assert test ! -d "$JOURNAL.rotating"

printf 'OK: worker attempts journal (%d assertions)\n' "$asserts"
