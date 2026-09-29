#!/usr/bin/env bash
# The test journal bin/harness-doctor's Tests section reads: the work probe writes one line per test
# it saw end, chat or worker.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" STATUSLINE_CACHE_DIR="$WORK/cache" WORKER_RUN_DIR="$WORK/runs" TZ=UTC
mkdir -p "$HOME" "$STATUSLINE_CACHE_DIR" "$WORKER_RUN_DIR/codex-5-5-live" "$HOME/.cache/claude-worker-tags/th"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { asserts=$((asserts + 1)); [ "$1" = "$2" ] || fail "assert $asserts: expected '$1', got '$2'"; }

printf '{"pid":700,"workdir":"/w/find-truth"}\n' > "$WORKER_RUN_DIR/codex-5-5-live/meta.json"
printf 'acc · astra · high\nrun=codex-5-5-live\n' > "$HOME/.cache/claude-worker-tags/th/t1"
mkdir -p "$WORK/repo"
git -C "$WORK/repo" init -q
printf '#!/usr/bin/env bash\ncat "%s/snap"\n' "$WORK" > "$WORK/ps"
printf '#!/usr/bin/env bash\nprintf "p11\\nfcwd\\nn%s\\np12\\nfcwd\\nn%s\\n"\n' "$WORK/repo" "$WORK/repo" > "$WORK/lsof"
chmod +x "$WORK/ps" "$WORK/lsof"
probe() { STATUSLINE_PS="$WORK/ps" STATUSLINE_LSOF="$WORK/lsof" "$ROOT/bin/statusline-work-probe.sh" th 5; }
shell_line() { printf '%s 5 %s /bin/zsh -c source /h/shell-snapshots/snapshot-zsh-1.sh && eval x\n' "$1" "$2"; }

{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'
  shell_line 10 01:01; printf '11 10 01:00 bash tests/test_a.sh\n'
  shell_line 13 00:31; printf '12 13 00:30 bash tests/test_long.sh\n'
  printf '700 1 03:00 bash -c supervisor\n701 700 01:30 pytest -q\n'; } > "$WORK/snap"
probe
assert_eq "" "$(cat "$STATUSLINE_CACHE_DIR/test-history.jsonl" 2>/dev/null)"
# test_a and the worker's pytest end; test_long runs on with a start one second off.
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'
  shell_line 13 00:32; printf '12 13 00:31 bash tests/test_long.sh\n'
  printf '700 1 03:00 bash -c supervisor\n'; } > "$WORK/snap"
probe
assert_eq "$(printf '%s\n' '{"who":"chat","repo":"repo","label":"test_a"}' '{"who":"worker","repo":"find-truth","label":"pytest"}')" \
  "$(jq -c '{who, repo, label}' "$STATUSLINE_CACHE_DIR/test-history.jsonl" | sort)"
secs=$(jq -s 'map(.secs) | sort | join(" ")' -r "$STATUSLINE_CACHE_DIR/test-history.jsonl")
case "$secs" in "6"[0-3]" 9"[0-3]) ;; *) fail "journaled durations off: $secs" ;; esac
asserts=$((asserts + 1))
# A cache the probe stopped refreshing says nothing about what ended since.
touch -t 202001010000 "$STATUSLINE_CACHE_DIR/work-th"
: > "$WORK/snap"; printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n' > "$WORK/snap"
probe
assert_eq 2 "$(wc -l < "$STATUSLINE_CACHE_DIR/test-history.jsonl" | tr -d ' ')"
# Two runs of one test in one repository a second apart: the one still running keeps only one of
# them alive, so the other's end is journaled.
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'
  shell_line 10 01:01; printf '11 10 01:00 bash tests/test_twin.sh\n'
  shell_line 13 01:02; printf '12 13 01:01 bash tests/test_twin.sh\n'; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'
  shell_line 13 01:03; printf '12 13 01:02 bash tests/test_twin.sh\n'; } > "$WORK/snap"
probe
assert_eq test_twin "$(sed -n 3p "$STATUSLINE_CACHE_DIR/test-history.jsonl" | jq -r .label)"
printf 'PASS: %s asserts; the probe journals every test it saw end, chat or worker\n' "$asserts"
