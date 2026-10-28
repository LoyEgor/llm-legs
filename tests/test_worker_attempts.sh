#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
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

. "$ROOT/share/store-lock.sh"
source <(sed -n "/^record_worker_session() {/,/^}/p;/^file_bytes() {/,/^}/p;/^journal_worker_attempt() {/,/^}/p" "$ROOT/share/worker-run-lifecycle.sh")
record() { # session
  (
    set +u
    FAKE_SESSION="$1"
    WORKER_ATTEMPTS_ROTATE_BYTES="${ROTATE_BYTES:-16777216}"
    session_id() { printf "%s\n" "$FAKE_SESSION"; }
    record_worker_session "$RUN"
  )
}
lines() { local n=0; while IFS= read -r _; do n=$((n + 1)); done <"$1"; printf '%s' "$n"; }
field() { jq -r "$1" "$2" | paste -sd, -; }

record 01a0-first
record 01a0-first
assert test "$(lines "$JOURNAL")" = 1
read -r line <"$JOURNAL"
assert test "$(jq -r '[.run, .attempt, .session, .vendor, .account, .role, .light, .launcher, .agent] | map(tostring) | join(" ")' <<<"$line")" \
  = "codex-1790000000-1-abcd 1 01a0-first codex first research research chat-session null"
assert jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")' <<<"$line" >/dev/null

# A reroute rewrites meta.account before the rescue attempt reports its session: the first line keeps
# the account that attempt ran on.
jq '.account = "second"' "$RUN/meta.json" >"$RUN/meta.tmp" && mv "$RUN/meta.tmp" "$RUN/meta.json"
printf '2\n' >"$RUN/attempt"
record 01a0-second
assert test "$(field '.account' "$JOURNAL")" = "first,second"
assert test "$(field '.attempt' "$JOURNAL")" = "1,2"

# An id nothing named leaves no line.
record -
assert test "$(lines "$JOURNAL")" = 2

# Past the bound the journal moves to one older segment, which replaces the previous one.
ROTATE_BYTES=10 record 01a0-third
assert test -f "$JOURNAL.1"
assert test "$(field '.session' "$JOURNAL.1")" = "01a0-first,01a0-second"
assert test "$(field '.session' "$JOURNAL")" = "01a0-third"
assert test ! -d "$JOURNAL.rotating"

# A lock a killed rotation left behind does not stop the next one.
mkdir "$JOURNAL.rotating" && touch -t 202001010000 "$JOURNAL.rotating"
ROTATE_BYTES=10 record 01a0-fourth
assert test "$(field '.session' "$JOURNAL.1")" = "01a0-third"
assert test "$(field '.session' "$JOURNAL")" = "01a0-fourth"
assert test ! -d "$JOURNAL.rotating"

# A live holder's lock is neither broken nor released: that attempt appends without rotating.
mkdir "$JOURNAL.rotating" && printf '%s\n' "$$" >"$JOURNAL.rotating/pid"
touch -t "$(date -v-10M +%Y%m%d%H%M)" "$JOURNAL.rotating"
ROTATE_BYTES=10 record 01a0-fifth
assert test "$(field '.session' "$JOURNAL.1")" = "01a0-third"
assert test "$(field '.session' "$JOURNAL")" = "01a0-fourth,01a0-fifth"
read -r holder <"$JOURNAL.rotating/pid"
assert test "$holder" = "$$"
rm -rf "$JOURNAL.rotating"

# GNU stat first on PATH reads `-f` as filesystem mode: the size read still rotates the journal.
mkdir -p "$WORK/gnu-stat"
printf '#!/bin/bash\n[ "$1" = -f ] && { printf "  File: \\"%%s\\"\\n    ID: 0 Namelen: 255\\n" "$3"; exit 1; }\nexec /usr/bin/stat "$@"\n' >"$WORK/gnu-stat/stat"
chmod +x "$WORK/gnu-stat/stat"
(PATH="$WORK/gnu-stat:$PATH"; ROTATE_BYTES=10 record 01a0-sixth)
assert test "$(field '.session' "$JOURNAL.1")" = "01a0-fourth,01a0-fifth"
assert test "$(field '.session' "$JOURNAL")" = "01a0-sixth"

# A run without attempt or launcher files journals nulls and prints nothing: the supervisor's stderr is
# the run's err file, and one stray line there reads as worker output to the silence watchdog.
BARE="$WORK/runs/codex-1790000000-2-bare"
mkdir -p "$BARE"
cp "$RUN/meta.json" "$BARE/meta.json"
bare_err=$( (RUN=$BARE; record 01a0-bare) 2>&1 >/dev/null)
assert test -z "$bare_err"
assert test "$(jq -r 'select(.session == "01a0-bare") | [.attempt, .launcher] | map(tostring) | join(" ")' "$JOURNAL")" = "null null"

printf 'OK: worker attempts journal (%d assertions)\n' "$asserts"
