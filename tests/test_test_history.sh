#!/usr/bin/env bash
# TEMP-TESTTIME(test-history): the temporary Test time journal and its menu summary (EXPERIMENTS.json,
# test-time). Deleted whole with the experiment.
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
assert_eq 1 "$(grep -c 'Test time (temp)' "$STATUSLINE_CACHE_DIR/test-history.txt")"
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
# No test ending after midnight still rebuilds the summary, so yesterday's totals never read as today's.
touch -t 202001010000 "$STATUSLINE_CACHE_DIR/test-history.txt"
probe
assert_eq "$(date +%Y-%m-%d)" "$(date -r "$STATUSLINE_CACHE_DIR/test-history.txt" +%Y-%m-%d)"

now=1790000000
{ printf '{"end":%s,"secs":190,"who":"chat","repo":"llm-legs","label":"suites","total":73,"failed":1}\n' "$((now - 100))"
  printf '{"end":%s,"secs":121,"who":"worker","repo":"find-truth","label":"pnpm test"}\n' "$((now - 50))"
  printf 'torn line\n'
  printf '{"end":%s,"secs":3700,"who":"chat","repo":"llm-legs","label":"suites","total":70}\n' "$((now - 2 * 86400))"
  printf '{"end":%s,"secs":999,"who":"chat","repo":"old","label":"suites"}\n' "$((now - 9 * 86400))"; } > "$STATUSLINE_CACHE_DIR/test-history.jsonl"
TEST_HISTORY_NOW=$now "$ROOT/bin/test-history"
assert_eq "Test time (temp) · today 5m 11s
today: 2 runs · 5m 11s — chat 3m 10s · workers 2m 1s
7 days: 3 runs · 1h 6m — chat 1h 4m · workers 2m 1s
-
14:12 find-truth · pnpm test · 2m 1s · worker
14:11 llm-legs · suites 73 ✗1 · 3m 10s · chat
09-19 14:13 llm-legs · suites 70 · 1h 1m · chat
09-12 14:13 old · suites · 16m 39s · chat
-
slowest over 7 days:
suites · llm-legs · 2× · 1h 4m
pnpm test · find-truth · 1× · 2m 1s
as of 14:13" "$(cat "$STATUSLINE_CACHE_DIR/test-history.txt")"

printf 'PASS: %s asserts; the probe journals every test it saw end, chat or worker, and the Test time summary reads that journal\n' "$asserts"
