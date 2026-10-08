#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The test journal bin/harness-doctor's Tests section reads: the work probe writes one line per test
# it saw end, chat or worker.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" STATUSLINE_CACHE_DIR="$WORK/cache" WORKER_RUN_DIR="$WORK/runs" TZ=UTC
unset XDG_CACHE_HOME SPEED_DOCTOR_DIR
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
# Each probe here reads a process table the case just wrote, never the shared snapshot of the last one.
probe() { rm -f "$STATUSLINE_CACHE_DIR/ps-snapshot"; STATUSLINE_PS="$WORK/ps" STATUSLINE_LSOF="$WORK/lsof" "$ROOT/bin/statusline-work-probe.sh" th 5; }
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
assert_eq '[]' "$(jq -sc 'map(select(has("ok")))' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# A run-suites run's outcome is its suites' .status codes once it is gone: every one 0 is ok, any
# plain failure is not, and a run short of its total, killed or with its logs gone has none. One whose
# pointer predates the process (still queued for a slot, or a killed runner's pid reused) is no run.
suite_run() { # pid repo total stamp codes...
  local pid=$1 repo=$2 total=$3 stamp=$4 rc i=0; shift 4
  mkdir -p "$WORK/$repo" "$WORK/logs-$pid"; git -C "$WORK/$repo" init -q
  printf '%s\t%s\t%s\t%s\n' "$WORK/logs-$pid" "$total" "$WORK/$repo" "$stamp" > "$STATUSLINE_CACHE_DIR/suites-$pid"
  for rc in "$@"; do i=$((i + 1)); printf '%s\t3\n' "$rc" > "$WORK/logs-$pid/test_$i.sh.status"; done
  shell_line "$((pid + 100))" 02:01; printf '%s %s 02:00 bash tests/run-all -j 5\n' "$pid" "$((pid + 100))"
}
fresh=$(($(date +%s) - 110))
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'
  suite_run 21 r-pass 2 "$fresh" 0; suite_run 22 r-fail 3 "$fresh" 0 0; suite_run 23 r-short 3 "$fresh" 0 0
  suite_run 24 r-killed 2 "$fresh" 0 137; suite_run 25 r-gone 1 "$fresh" 0; suite_run 26 r-stale 1 1000 0
  suite_run 27 r-twin 1 "$fresh" 0; suite_run 28 r-twin 1 "$fresh" 1; } > "$WORK/snap"
probe
# The last suites end between two probes; only their .status files hold them. Of two runs of one
# repository started together, the one still running is never journaled for the other.
printf '0\t1\n' > "$WORK/logs-21/test_2.sh.status"; printf '1\t1\n' > "$WORK/logs-22/test_3.sh.status"
rm -rf "$WORK/logs-25"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; shell_line 128 02:01; printf '28 128 02:00 bash tests/run-all -j 5\n'; } > "$WORK/snap"
probe
assert_eq '{"repo":"r-fail","total":3,"failed":1,"ok":false} {"repo":"r-gone","total":1,"failed":0,"ok":null} {"repo":"r-killed","total":2,"failed":1,"ok":null} {"repo":"r-pass","total":2,"failed":0,"ok":true} {"repo":"r-short","total":3,"failed":0,"ok":null} {"repo":"r-twin","total":1,"failed":0,"ok":true}' \
  "$(jq -c 'select(.label == "suites") | {repo, total, failed, ok}' "$STATUSLINE_CACHE_DIR/test-history.jsonl" | sort | paste -sd' ' -)"
assert_eq 3 "$(jq -s 'map(select(has("ok"))) | length' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# Every row names the repository it ran in by its main checkout, so a worktree's runs fold into it;
# a workdir outside git names none.
assert_eq "$(printf '"%s"\nnull\n' "$WORK/repo")" \
  "$(head -2 "$STATUSLINE_CACHE_DIR/test-history.jsonl" | jq -c .repo_root | sort)"
git -C "$WORK/repo" worktree add -q --orphan -b wt-one "$WORK/repo/.claude/worktrees/wt-one"
mkdir -p "$WORK/repo/.claude/worktrees/wt-one/tests"
still_28() { shell_line 128 02:01; printf '28 128 02:00 bash tests/run-all -j 5\n'; }
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  shell_line 30 00:41; printf '31 30 00:40 bash %s/tests/test_wt.sh\n' "$WORK/repo/.claude/worktrees/wt-one"; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe
assert_eq "$(jq -cn --arg root "$WORK/repo" '{repo: "⧉ wt-one", repo_root: $root}')" \
  "$(jq -c 'select(.label == "test_wt") | {repo, repo_root}' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# Exit 255 is a failure; only 129-192 is a kill by signal.
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; suite_run 40 r-255 2 "$fresh" 0 255; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe
assert_eq '{"total":2,"failed":1,"ok":false}' \
  "$(jq -c 'select(.repo == "r-255") | {total, failed, ok}' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# A run seen only queued that took its slot and ended before the next probe is journaled off the
# pointer run-suites leaves on exit, timed from its slot; one still queued, or now slotted, is not.
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  suite_run 60 r-late 1 1000 0; suite_run 61 r-wait 1 1000 0; suite_run 62 r-slot 1 1000 0; } > "$WORK/snap"
probe
slotted=$(($(date +%s) - 50))
printf '%s\t1\t%s\t%s\n' "$WORK/logs-60" "$WORK/r-late" "$slotted" > "$STATUSLINE_CACHE_DIR/suites-60.done"
rm -f "$STATUSLINE_CACHE_DIR/suites-60"
printf '%s\t1\t%s\t%s\n' "$WORK/logs-62" "$WORK/r-slot" "$slotted" > "$STATUSLINE_CACHE_DIR/suites-62"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  shell_line 161 02:01; printf '61 161 02:00 bash tests/run-all -j 5\n'
  shell_line 162 02:01; printf '62 162 02:00 bash tests/run-all -j 5\n'; } > "$WORK/snap"
probe
assert_eq '{"repo":"r-late","total":1,"ok":true}' \
  "$(jq -c 'select(.repo == "r-late" or .repo == "r-wait" or .repo == "r-slot" or .repo == "") | {repo, total, ok}' \
    "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
late_secs=$(jq -r 'select(.repo == "r-late") | .secs' "$STATUSLINE_CACHE_DIR/test-history.jsonl")
[ "$late_secs" -ge 49 ] && [ "$late_secs" -le 53 ] || fail "a late run is timed from its slot: $late_secs"
asserts=$((asserts + 1))
# A run-suites run, chat or worker, carries each suite's seconds from its .status files.
assert_eq 'r-gone null r-pass {"test_1.sh":3,"test_2.sh":1}' \
  "$(jq -r 'select(.repo == "r-pass" or .repo == "r-gone") | "\(.repo) \(.suite_secs | tojson)"' \
    "$STATUSLINE_CACHE_DIR/test-history.jsonl" | sort | paste -sd' ' -)"
mkdir -p "$WORK/logs-702"
printf '0\t7\n' > "$WORK/logs-702/test_w.sh.status"
printf '%s\t1\t%s\t%s\n' "$WORK/logs-702" "$WORK/repo" "$(date +%s)" > "$STATUSLINE_CACHE_DIR/suites-702"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  printf '700 1 03:00 bash -c supervisor\n702 700 01:50 bash tests/run-all -j 5\n'; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; printf '700 1 03:00 bash -c supervisor\n'; } > "$WORK/snap"
probe
assert_eq '{"test_w.sh":7}' \
  "$(jq -c 'select(.label == "suites" and .who == "worker") | .suite_secs' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# A run one probe loses from the session's tree while ps still lists it is journaled once, at its end.
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; suite_run 80 r-lost 1 "$fresh" 0; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; printf '80 1 02:00 bash tests/run-all -j 5\n'; } > "$WORK/snap"
probe
assert_eq 0 "$(jq -s 'map(select(.repo == "r-lost")) | length' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; suite_run 80 r-lost 1 "$fresh" 0; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe
assert_eq 1 "$(jq -s 'map(select(.repo == "r-lost")) | length' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# The worker's workdir is find-truth; the row names the repository its run-all tested.
assert_eq "repo $WORK/repo" \
  "$(jq -r 'select(.label == "suites" and .who == "worker") | "\(.repo) \(.repo_root)"' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"

# repo_root is the main checkout for every layout: a submodule's and a separate git dir's own
# toplevel, a .bare layout's project directory, a linked worktree's main checkout.
. "$ROOT/share/test-scope.sh"
layouts="$WORK/layouts"
mkdir -p "$layouts/super/.git/modules" "$layouts/proj"
git init -q --separate-git-dir="$layouts/super/.git/modules/sub" "$layouts/super/sub"
git init -q --separate-git-dir="$layouts/sep.git" "$layouts/sep"
git init -q --bare "$layouts/proj/.bare"
printf 'gitdir: ./.bare\n' > "$layouts/proj/.git"
git -C "$layouts/proj" worktree add -q --orphan -b main "$layouts/proj/main"
roots=""
for dir in "$layouts/super/sub" "$layouts/sep" "$layouts/proj/main" "$WORK/repo/.claude/worktrees/wt-one"; do
  top="" root=""
  git_top "$dir"
  roots="$roots ${root#"$WORK/"}"
done
assert_eq " layouts/super/sub layouts/sep layouts/proj repo" "$roots"
mkdir -p "$layouts/plain/tests"
assert_eq "$WORK $WORK $layouts/plain" \
  "$(git_projects "$WORK/repo/.claude/worktrees/wt-one") $(git_projects "$WORK/repo") $(git_projects "$layouts/plain/tests")"
mkdir -p "$layouts/proj/main/tests"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  shell_line 50 00:41; printf '51 50 00:40 bash %s/tests/test_bare.sh\n' "$layouts/proj/main"; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe
assert_eq "\"$layouts/proj\"" "$(jq -c 'select(.label == "test_bare") | .repo_root' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# A test started by a relative path keeps the repository it was launched from after it cds away.
mkdir -p "$WORK/repo/tests" "$WORK/elsewhere"
printf 'cat "%s/lsof-extra" 2>/dev/null\n' "$WORK" >> "$WORK/lsof"
printf 'p89\nfcwd\nn%s\np90\nfcwd\nn%s\n' "$WORK/repo" "$WORK/elsewhere" > "$WORK/lsof-extra"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  shell_line 89 00:41; printf '90 89 00:40 bash tests/test_cd.sh\n'; } > "$WORK/snap"
probe
assert_eq repo "$(awk -F'\t' '$5 == "test_cd" { print $4 }' "$STATUSLINE_CACHE_DIR/work-th")"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe
assert_eq repo "$(jq -r 'select(.label == "test_cd") | .repo' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# A test that ends between the process snapshot and lsof is journaled once, never again as repo-less.
sleep 0 & dead_pid=$!; wait "$dead_pid"
printf 'p%s\nfcwd\nn%s\n' "$dead_pid" "$WORK/repo" > "$WORK/lsof-extra"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  shell_line 91 00:21; printf '%s 91 00:20 pytest -q\n' "$dead_pid"; } > "$WORK/snap"
probe
: > "$WORK/lsof-extra"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe
assert_eq '["repo"]' "$(jq -sc 'map(select(.label == "pytest" and .who == "chat") | .repo)' "$STATUSLINE_CACHE_DIR/test-history.jsonl")"
# A wrapper option's value is never taken for the program.
printf 'p93\nfcwd\nn%s\n' "$WORK/repo" > "$WORK/lsof-extra"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  shell_line 92 00:21; printf '93 92 00:20 env -u FOO bash -o pipefail tests/test_wrapped.sh\n'; } > "$WORK/snap"
probe
assert_eq test_wrapped "$(awk -F'\t' '$5 == "test_wrapped" { print $5 }' "$STATUSLINE_CACHE_DIR/work-th")"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; } > "$WORK/snap"
probe

# run-suites declares its scope, and a marker names the repo_root its run folds into.
suites_repo="$WORK/suites-repo"
mkdir -p "$suites_repo/tests"
git -C "$suites_repo" init -q
printf '#!/usr/bin/env bash\necho ok\n' > "$suites_repo/tests/test_one.sh"
: > "$STATUSLINE_CACHE_DIR/test-scope.jsonl"
for args in "" "--all" "--changed" "test_one.sh"; do
  RUN_SUITES_TIMES="$WORK/times.tsv" bash "$ROOT/share/run-suites.sh" --repo "$suites_repo" -j 2 $args >/dev/null 2>&1 ||
    fail "run-suites $args failed"
done
assert_eq "$(jq -cn --arg root "$suites_repo" '["full","all","changed","named"] | map({label: "suites", scope: ., repo_root: $root})')" \
  "$(jq -sc 'map({label, scope, repo_root})' "$STATUSLINE_CACHE_DIR/test-scope.jsonl")"
mkdir -p "$WORK/slow-git"
printf '#!/bin/bash\ncase " $* " in *" ls-files "*) sleep 3 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$WORK/slow-git/git"
chmod +x "$WORK/slow-git/git"
: > "$STATUSLINE_CACHE_DIR/test-scope.jsonl"
launched=$(date +%s)
PATH="$WORK/slow-git:$PATH" RUN_SUITES_TIMES="$WORK/times.tsv" bash "$ROOT/share/run-suites.sh" --repo "$suites_repo" -j 2 \
  --changed >/dev/null 2>&1 || fail "run-suites --changed under a slow git failed"
assert_eq yes "$(jq -r --argjson at "$launched" 'if .start - $at <= 1 then "yes" else "\(.start - $at) s late" end' \
  "$STATUSLINE_CACHE_DIR/test-scope.jsonl")" "run-suites stamps its scope marker with its own start, not after a slow discovery"

# A run with its own row in the run-suites journal gets none here: run-suites by its pid, a test
# sourcing tests/lib/suite-journal.sh by its name, each within 3s of the start this probe saw.
c5_journal="$HOME/.cache/run-suites/runs.jsonl"
mkdir -p "${c5_journal%/*}"
c5_now=$(date +%s)
c5_row() { # kind pid started suite
  printf '{"kind":"%s","pid":%s,"started_at":%s.250,"suites":{"%s":{"rc":0}}}\n' "$1" "$2" "$3" "$4" >>"$c5_journal"
}
c5_row suites 90 "$((c5_now - 112))" test_1.sh
c5_row suites 91 "$((c5_now - 300))" test_1.sh
c5_row direct 93 "$((c5_now - 41))" test_dup.sh
c5_row direct 702 "$((c5_now - 109))" test_wdup.sh
printf 'p95\nfcwd\nn%s\n' "$WORK/repo" > "$WORK/lsof-extra"
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28
  suite_run 90 r-c5 1 "$((c5_now - 110))" 0; suite_run 91 r-c5-reused 1 "$((c5_now - 110))" 0
  shell_line 92 00:41; printf '93 92 00:40 bash tests/test_dup.sh\n'
  shell_line 94 00:41; printf '95 94 00:40 bash tests/test_undup.sh\n'
  printf '700 1 03:00 bash -c supervisor\n703 700 01:50 bash tests/test_wdup.sh\n'; } > "$WORK/snap"
probe
{ printf '1 0 01:00:00 launchd\n5 1 10:00 claude\n'; still_28; printf '700 1 03:00 bash -c supervisor\n'; } > "$WORK/snap"
probe
assert_eq 'r-c5-reused test_undup' "$(jq -r 'select((.repo | startswith("r-c5")) or (.label | test("^test_w?u?n?dup$")))
  | if .label == "suites" then .repo else .label end' "$STATUSLINE_CACHE_DIR/test-history.jsonl" | paste -sd' ' -)"

# A test script that runs part of itself is partial whichever selector it reads narrowed it.
selectors=$(cd "$ROOT/tests" && grep -Eo 'WORKER_RUN_TEST_([A-Z_]*_)?(CASE|ONLY)' test_worker_run_*.sh | sort -u)
case " $(echo $selectors) " in *" test_worker_run_attribution.sh:WORKER_RUN_TEST_ATTRIBUTION_CASE "*"test_worker_run_reliability.sh:WORKER_RUN_TEST_CASE "*) ;;
  *) fail "selectors read by the test_worker_run parts: $selectors" ;; esac
asserts=$((asserts + 1))
narrowed=""
for selector in $selectors; do
  env -i PATH="$PATH" "${selector#*:}=x" bash -c '. "$1"; test_scope_narrowed "$2" WORKER_RUN_TEST_ && echo y || echo n' _ \
    "$ROOT/share/test-scope.sh" "$ROOT/tests/${selector%%:*}" | { read -r v; [ "$v" = y ] || echo "$selector"; }
done > "$WORK/unnarrowed"
assert_eq "" "$(cat "$WORK/unnarrowed")"
assert_eq "n n" "$(for v in "" 0; do env -i PATH="$PATH" WORKER_RUN_TEST_CASE="$v" bash -c \
  '. "$1"; test_scope_narrowed "$2" WORKER_RUN_TEST_ && echo y || echo n' _ "$ROOT/share/test-scope.sh" \
  "$ROOT/tests/test_worker_run_reliability.sh"; done | paste -sd' ' -)"
assert_eq 1 "$(grep -c '^if test_scope_narrowed "$0" WORKER_RUN_TEST_; then$' "$ROOT/tests/worker_run_harness.sh")"
: > "$STATUSLINE_CACHE_DIR/test-scope.jsonl"
(cd "$WORK" && bash -c '. "$1"; test_scope_partial "$2"' _ "$ROOT/share/test-scope.sh" "$ROOT/tests/test_worker_run_reliability.sh")
main_checkout=$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")
assert_eq "$(jq -cn --arg root "$main_checkout" '{label: "test_worker_run_reliability", scope: "partial", repo_root: $root}')" \
  "$(jq -c '{label, scope, repo_root}' "$STATUSLINE_CACHE_DIR/test-scope.jsonl")"
printf 'PASS: %s asserts; the probe journals every test it saw end, chat or worker\n' "$asserts"
