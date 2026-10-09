#!/usr/bin/env bash
# `env bash` resolves to macOS bash 3.2 when PATH lists /bin before Homebrew; this script needs
# `wait -n`, which is 4.3 and not 4.0 — and under 4.2 the failure is silent, because the `|| :`
# guarding that wait turns "unknown option" into "one job finished" and the -j ceiling stops
# holding at all.
have_wait_n='(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))'
if ! eval "$have_wait_n"; then
  for modern_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$modern_bash" ] && "$modern_bash" -c "$have_wait_n" && exec "$modern_bash" "$0" "$@"
  done
  echo "run-suites: bash 4.3+ required for wait -n (found $BASH_VERSION)" >&2
  exit 1
fi
{
set -u
# Every suite's watcher polls for its whole life: a forked `sleep` per poll, and a killed watcher's
# in-flight sleep kept the run's output pipe open past its end.
enable -f "${BASH%/bin/*}/lib/bash/sleep" sleep 2>/dev/null || :
# Inherited from a git hook or `git bisect run`, these aim every fixture's `git init` at the real
# repository (it was left core.bare=true on 2026-10-08).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
printf -v run_suites_start '%(%s)T' -1
run_suites_queued=${EPOCHREALTIME:-$run_suites_start} run_suites_began=${EPOCHREALTIME:-$run_suites_start}
run_worker=${WORKER_RUN_ID:-} run_session=${CLAUDE_CODE_SESSION_ID:-${CLAUDE_LAUNCHER_SESSION:-}}

usage() {
  cat >&2 <<'USAGE'
usage: run-suites.sh [--repo <dir>] [--run-all] [--full] [-j <n>] [--changed] [--all] [--profile] [suite ...]

Runs a repository's test suites in parallel, one log per suite, and prints one table.
Exit 1 if any suite failed, with the last 30 lines of each failure.

  --repo <dir>  repository root (default: the git root of the current directory)
  --run-all     set by every tests/run-all: inside a worker or a chat (CLAUDE_CODE_SESSION_ID) a run
                naming no suite and no --changed is refused (exit 3); the full run is the night's
  --full        a chat's full run anyway, only on Egor's explicit word; never inside a worker
  -j <n>        parallel jobs (default: cores / 2, minimum 2)
  --changed     only suites whose text, or a tests/ helper file they name, mentions the basename
                of a path in `git diff --name-only HEAD`, an untracked file or a commit of this branch
                since main. A HEURISTIC: a suite that exercises a file it never names by basename is
                missed; the day lands on it and the night's full run is the final gate.
  --all         also run the suites skipped by default because they read live machine state
                (llm-legs e2e_surfaces.sh, test_instruction_rates_live.sh)
  --profile     each suite's calls of jq python3 lua git sleep date sed grep awk mktemp bash go through
                PATH shims into its journal entry: `execs` {binary: count} and `sleep_s`, the seconds
                its sleeps asked for. A fork per call, so never on by default; a suite that sets its
                own PATH or calls absolute binaries shows fewer counts
  suite ...     explicit suite names or paths; skips discovery

Machine-wide at most RUN_SUITES_SLOTS runs at once (default cores / 3 clamped 2 to 4 always, up to 4
while the machine has room); a run waits for a free slot under RUN_SUITES_SLOTS_DIR, its wait a
limiter hold, and frees it once only its last suite runs. Inside a worker (WORKER_RUN_ID set) --changed skips the slow layer, tests/slow-suites,
except a suite the worker edited; the landing and the night full run run them.

A suite whose first 5 lines hold `# shards: N` runs as N jobs, each with SUITE_SHARD=i/N and only
the sections `suite_shard_owns i <name>` (tests/lib/suite-journal.sh) gives it; one verdict, one
journal entry (max shard wall, summed CPU). RUN_SUITES_SHARDS=on|off, default only while slot_room
finds room.

A suite running past its bound is killed with its whole process tree and reads FAIL 124, TIMEOUT:
5 x the p90 of its last 50 passes in the journal, never under RUN_SUITES_SUITE_FLOOR (default 1800 s,
doubled for tests/slow-suites), twice that floor before it has 3 passes.
USAGE
  exit 2
}

fail() { printf 'run-suites: %s\n' "$*" >&2; exit 4; }

repo=''
jobs=0
changed=false
include_live=false
profile=false
from_run_all=false
full=false
declare -a explicit=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
    -j) [ "$#" -ge 2 ] || usage; jobs="$2"; shift 2 ;;
    --run-all) from_run_all=true; shift ;;
    --full) full=true; shift ;;
    --changed) changed=true; shift ;;
    --all) include_live=true; shift ;;
    --profile) profile=true; shift ;;
    -h|--help) usage ;;
    --) shift; while [ "$#" -gt 0 ]; do explicit+=("$1"); shift; done ;;
    -*) usage ;;
    *) explicit+=("$1"); shift ;;
  esac
done
# zsh never word-splits `$suites`, so `tests/run-all $suites` hands over tests/affected's lines as one.
if [ "${#explicit[@]}" -gt 0 ]; then
  joined=$(printf '%s\n' "${explicit[@]}")
  explicit=()
  while IFS= read -r entry; do [ -z "$entry" ] || explicit+=("$entry"); done <<<"$joined"
fi

[ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'no --repo and no git root here'
repo=$(cd "$repo" && pwd -P) || fail "unreadable repo: $repo"
[ -d "$repo/tests" ] || fail "no tests directory under $repo"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/worktree-branch.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/affected-suites.sh"
journal_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/tests/lib/suite-journal.sh"

# A linked worktree has no sibling checkout beside it. Another repo's worktree on this same
# branch is the set under test; otherwise the main checkout. An exported variable wins either way.
if common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  projects=$(dirname "$(dirname "$common")")
  own_branch=$(linked_worktree_branch "$repo")
  for sibling in CLAUDE_SETUP_ROOT=claude-setup REVIEW_BENCH_ROOT=review-bench REVIEW_ROOT=review-bench LLM_LEGS_ROOT=llm-legs; do
    var=${sibling%%=*} name=${sibling#*=}
    [ -n "${!var:-}" ] && continue
    if [ -n "$own_branch" ] && sibling_wt=$(same_branch_worktree "$projects/$name" "$own_branch"); then
      export "$var=$sibling_wt"
      continue
    fi
    if [ ! -d "$repo/../$name" ] && [ -d "$projects/$name" ]; then export "$var=$projects/$name"; fi
  done
  # review-bench's rbench_paths finds llm-legs/share beside ITS root, which a worktree has not.
  [ -n "${LLM_LEGS_SHARE:-}" ] || [ -z "${LLM_LEGS_ROOT:-}" ] || export LLM_LEGS_SHARE="$LLM_LEGS_ROOT/share"
fi

[[ "$jobs" =~ ^[0-9]+$ ]] || usage
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/slots.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/processes.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/run-liveness.sh"
[ "$jobs" -ne 0 ] || jobs=$(slots_from_cores 2 2)

# Each suite's last passing duration, keyed by the main checkout so a worktree shares it: the wave
# starts the longest first, since alphabetical order left the slowest suite starting last.
times_file=${RUN_SUITES_TIMES:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/times.tsv}
# The queue the runner's own chats read: a suite that posts into it files fixtures into live chats.
live_reports=${XDG_CACHE_HOME:-$HOME/.cache}/claude-reports
run_journal=${RUN_SUITES_JOURNAL:-${times_file%/*}/runs.jsonl}
. "$journal_lib" --lib || fail "unreadable $journal_lib"
times_key=$repo
[ "${common:-}" = "${common%/.git}/.git" ] && times_key=${common%/.git}
suite_floor=${RUN_SUITES_SUITE_FLOOR:-1800}
[[ $suite_floor =~ ^[1-9][0-9]*$ ]] || fail "RUN_SUITES_SUITE_FLOOR must be whole seconds: $suite_floor"
slow_listed=$'\n'$(cat "$repo/tests/slow-suites" 2>/dev/null)$'\n'
declare -A pass_p90=()
if [ -r "$run_journal" ] && command -v jq >/dev/null; then
  while IFS=$'\t' read -r name secs; do
    [[ "$secs" =~ ^[0-9]+$ ]] && pass_p90[$name]=$secs
  done < <(tail -n 5000 "$run_journal" | jq -nRr --arg root "$times_key" '
    [inputs | fromjson? | objects | select(.repo_root == $root) | .suites | objects | to_entries[]
      | select(.value.rc == 0 and (.value.secs | type) == "number") | [.key, .value.secs]]
    | group_by(.[0])[] | (.[-50:] | map(.[1]) | sort) as $s | select($s | length >= 3)
    | "\(.[0][0])\t\($s[($s | length) * 0.9 | ceil | . - 1] | ceil)"' 2>/dev/null)
fi
suite_bound() { # var name -> the suite's wall bound in seconds
  local floor=$suite_floor p90=${pass_p90[$2]:-}
  [[ "$slow_listed" != *$'\n'"$2"$'\n'* ]] || floor=$((floor * 2))
  if [ -z "$p90" ]; then printf -v "$1" '%s' $((floor * 2))
  elif [ $((p90 * 5)) -gt "$floor" ]; then printf -v "$1" '%s' $((p90 * 5))
  else printf -v "$1" '%s' "$floor"; fi
}
owner_record=${WORKER_RUN_RECORD:-} owner_pid=''
[ -z "$owner_record" ] || owner_pid=$(jq -r '.pid // empty' "$owner_record/meta.json" 2>/dev/null)
owner_ended() { # -> whether the worker run that asked for this run has ended: its exit code, or its supervisor gone
  [ -n "$owner_record" ] || return 1
  [ ! -e "$owner_record/exit_code" ] || return 0
  [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && ! supervisor_running "$owner_record" "$owner_pid"
}
# A worker's backgrounded run outlives the worker; once it has ended nobody reads the run, which then
# queued for and held a slot anyway (2026-10-05). An owner already ended at launch is a stale export.
if owner_ended; then
  owner_record='' run_worker=''
  unset WORKER_RUN_ID WORKER_RUN_RECORD
fi
if $from_run_all && ! $changed && [ "${#explicit[@]}" -eq 0 ]; then
  if [ -n "$run_worker" ]; then
    printf 'run-all: a worker never runs every suite, the night does: tests/run-all $(tests/affected <file>...) or tests/run-all --changed\n' >&2
    exit 3
  elif [ -n "$run_session" ] && ! $full; then
    printf 'run-all: a chat never runs every suite either, the night does: tests/run-all $(tests/affected <file>...) or tests/run-all --changed; tests/run-all --full only on Egor'"'"'s explicit word\n' >&2
    exit 3
  fi
fi
suite_watch() { # pid bound marker -> ends the suite's tree once it outlives the bound or its owner ended
  local deadline=$((SECONDS + $2))
  while kill -0 "$1" 2>/dev/null; do
    if [ -e "$logdir/owner-ended" ]; then process_tree_end "$1" 10; return; fi
    if [ "$SECONDS" -ge "$deadline" ]; then : >"$3"; process_tree_end "$1" 10; return; fi
    sleep 2
  done
}

declare -A last_secs=() shards=()
if [ -r "$times_file" ]; then
  while IFS=$'\t' read -r key name secs; do
    [ "$key" = "$times_key" ] && [[ "$secs" =~ ^[0-9]+$ ]] && last_secs[$name]=$secs
  done <"$times_file"
fi

# Suites that cannot share a machine with another one; they run after the parallel wave, one at a
# time. Every entry asserts a WALL-CLOCK budget — a lock wait, a pty grace window, a collector
# timeout, all measured in real seconds — so a loaded machine fails them on load alone. Add a name
# here only after measuring it BOTH ways; a guessed entry serialises a suite forever for a failure
# it never had. The driver was measured that way (2026-09-04, -j 5 over 41 suites): it failed in 13s
# under the wave and passed alone in 20s. test_llm_limits is deliberately NOT here — its budget is
# counted from the suite's own start, so once the run needs longer than a minute to reach it no
# scheduling helps (84s in the wave, 62s in the serial tail, 64s alone — all three red).
serial_suite() {
  case "$1" in
    test_review_flow_gate.sh) return 0 ;;
    test_claude_session_driver.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Nice 10 yields to every nice-0 load, not just to chats: with nobody at the keyboard the owner's
# benchmark runs unthrottled at nice 0 and starved the wave 10-60x (2026-10-06), holding slots
# 20-40 min. So the wave drops only while someone is there, the benchmark's own rule
# (logo-vectorizer-bench bench/throttle.py). Unknown counts as present.
user_present() {
  local idle
  idle=$(ioreg -c IOHIDSystem -d 4 -r -k HIDIdleTime 2>/dev/null | awk '/"HIDIdleTime"/ {print int($NF / 1000000000); exit}')
  [[ "$idle" =~ ^[0-9]+$ ]] || return 0
  [ "$idle" -lt 600 ]
}

# A chat's own run is what its owner waits on, so only a worker's run or one with no chat session
# (launchd, the night's detached full run) yields.
unattended() { [ -n "$run_worker" ] || [ -z "$run_session" ]; }

declare -a suites=()
if [ "${#explicit[@]}" -gt 0 ]; then
  for entry in "${explicit[@]}"; do
    case "$entry" in
      */*) [ -r "$entry" ] || fail "no such suite: $entry"
           suites+=("$(cd "$(dirname "$entry")" && pwd -P)/$(basename "$entry")") ;;
      *) [ -r "$repo/tests/$entry" ] || fail "no such suite: $repo/tests/$entry"
         suites+=("$repo/tests/$entry") ;;
    esac
  done
else
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    live_suite "$(basename "$entry")" && [ "$include_live" = false ] && continue
    suites+=("$entry")
  done < <(ls "$repo"/tests/test_*.sh "$repo"/tests/test_*.py "$repo"/tests/e2e_*.sh 2>/dev/null | sort)
fi
[ "${#suites[@]}" -gt 0 ] || fail "no suites found under $repo/tests"

if [ "$changed" = true ]; then
  names_file=$(mktemp "${TMPDIR:-/tmp}/affected.XXXXXX") || fail 'could not create a names file'
  affected_names "$repo" >"$names_file"
  # A worker that committed before asking leaves nothing in `git diff HEAD`: its commits count too.
  if [ -n "$owner_record" ] && read -r base 2>/dev/null <"$owner_record/head-before" &&
      git -C "$repo" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    mapfile -t committed < <(git -C "$repo" diff --name-only "$base" HEAD 2>/dev/null)
    [ "${#committed[@]}" -eq 0 ] || affected_names "$repo" "${committed[@]}" >>"$names_file"
  fi
  mapfile -t suites < <(printf '%s\n' "${suites[@]}" | affected_filter "$repo" "$names_file" | sort -u)
  slow_layer_split "$repo" "$names_file" ${suites[@]+"${suites[@]}"}
  suites=(${slow_kept[@]+"${slow_kept[@]}"})
  rm -f "$names_file"
  [ "${#suites[@]}" -gt 0 ] || [ -n "$slow_skipped" ] || { printf 'run-suites: nothing changed that any suite names\n'; exit 0; }
fi

# Brew relinks `python3` to each new minor release, which arrives without pytest.
pytest_python() {
  local candidate
  for candidate in "$repo/.venv/bin/python" python3 $(
      IFS=:
      for dir in $PATH; do
        for bin in "$dir"/python3.[0-9]*; do
          [[ "${bin##*/}" =~ ^python3\.[0-9]+$ ]] && printf '%s\n' "${bin##*/}"
        done
      done | sort -t. -k2,2nr -u); do
    [ "$candidate" = "$repo/.venv/bin/python" ] && [ ! -x "$candidate" ] && continue
    "$candidate" -c 'import pytest' >/dev/null 2>&1 && { command -v "$candidate"; return 0; }
  done
  return 1
}
python=''
if printf '%s\n' ${suites[@]+"${suites[@]}"} | grep -q '\.py$'; then
  python=$(pytest_python) ||
    fail "no python with pytest: tried $repo/.venv/bin/python, python3 and python3.X on PATH"
fi

# Machine-wide, at most RUN_SUITES_SLOTS runs at once: each already fans out -j cores/2 suites, so
# cores/3 (2 to 4) always run and up to 4, the count measured freeze-safe, while slot_room finds room.
# A nested run (a suite testing this runner) inherits its parent's slot.
own_slot=''
if [ -z "${RUN_SUITES_SLOT:-}" ]; then
  own_slot=$(SLOT_OWNER_ENDED=${owner_record:+owner_ended} slot_wait "${RUN_SUITES_SLOTS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/slots}" \
    "${RUN_SUITES_SLOTS:-$(run_suites_slots)}" $((6 * 3600)) run-suites "suites of $repo") || {
    ! owner_ended || fail "worker ${run_worker:-run} ended while this run waited for a slot"
    fail 'could not take a suite slot'
  }
  trap 'slot_release "$own_slot"' EXIT
  export RUN_SUITES_SLOT=$own_slot
  printf -v run_suites_start '%(%s)T' -1
  run_suites_began=${EPOCHREALTIME:-$run_suites_start}
fi
run_slot=${RUN_SUITES_SLOT:-}

logdir=$(mktemp -d "${TMPDIR:-/tmp}/run-suites.XXXXXX") || fail 'could not create a log directory'
# The statusline's work probe finds this run by its pid, counts its .status files for `n/m` and
# names the repository from here: this process never leaves the caller's directory.
progress_file="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}/suites-$$"
mkdir -p "${progress_file%/*}" 2>/dev/null &&
  printf '%s\t%s\t%s\t%s\n' "$logdir" "${#suites[@]}" "$repo" "$run_suites_start" >"$progress_file" 2>/dev/null
find "${progress_file%/*}" -maxdepth 1 -name 'suites-*.done' -mmin +1 -delete 2>/dev/null
suite_journal_git "$repo"
suite_journal_content "$repo"
journal_run() {
  local entry name rc secs real cpu bound execs complete=true queued began ended reason=''
  local -a names=()
  suite_journal_suites=''
  for entry in ${suites[@]+"${suites[@]}"}; do
    name=${entry##*/}
    names+=("$name")
    rc='' real='' cpu='' bound=''
    [ -r "$logdir/$name.status" ] && IFS=$'\t' read -r rc secs real bound cpu <"$logdir/$name.status"
    [ "$real" != - ] || real=''
    execs=''
    [ ! -e "$logdir/$name.execs" ] || execs=$(LC_ALL=C awk '{ n[$1]++ }
      $1 == "sleep" { for (i = 2; i <= NF; i++) { u = substr($i, length($i)); s += $i * (u == "m" ? 60 : u == "h" ? 3600 : u == "d" ? 86400 : 1) } }
      END { printf "\"execs\":{"; for (b in n) printf "%s\"%s\":%d", c++ ? "," : "", b, n[b]; printf "},\"sleep_s\":%.3f", s }' "$logdir/$name.execs")
    [ -z "${shards[$name]:-}" ] || execs="\"shards\":${shards[$name]}${execs:+,$execs}"
    if [[ "$rc" =~ ^[0-9]+$ ]]; then suite_journal_suite "$name" "$rc" "${real:-$secs}" "$cpu" "$bound" "$execs"; else complete=false; fi
  done
  [ -z "$run_signal" ] || complete=false
  [ ! -e "$logdir/owner-ended" ] || reason=owner-ended
  [ "${#names[@]}" -eq 0 ] || mapfile -t names < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  suite_journal_digest ${names[@]+"${names[@]}"}
  suite_journal_ms queued "$run_suites_queued"; suite_journal_secs queued "$queued"
  suite_journal_ms began "$run_suites_began"; suite_journal_secs began "$began"
  suite_journal_ms ended; [ -n "$ended" ] || suite_journal_ms ended "$(date +%s)"; suite_journal_secs ended "$ended"
  suite_journal_row suites "$$" "$queued" "$began" "$ended" "$repo" "$times_key" "$suite_journal_head" "${scope:-}" \
    "$run_worker" "$run_session" "$jobs" "$run_slot" "$run_signal" "$complete" "${slow_skipped:-}" "$reason"
  suite_journal_append "$run_journal"
}
run_signal='' run_finished='' owner_watch=''
finish_run() {
  [ -z "$run_finished" ] || return 0
  run_finished=1
  [ -z "$owner_watch" ] || kill "$owner_watch" 2>/dev/null
  journal_run
  mv -f "$progress_file" "$progress_file.done" 2>/dev/null
  [ -z "$own_slot" ] || slot_release "$own_slot"
}
on_signal() { # number name
  local job
  run_signal=$1
  # Background suites ignore SIGINT and never see a TERM sent to this pid alone; ended before the slot frees.
  for job in $(jobs -p); do process_tree_end "$job" 10 & done
  wait
  finish_run
  trap - EXIT "$2"
  kill -"$2" "$$"
}
trap finish_run EXIT
trap 'on_signal 1 HUP' HUP
trap 'on_signal 2 INT' INT
trap 'on_signal 15 TERM' TERM
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-scope.sh"
if [ "${#explicit[@]}" -gt 0 ]; then scope=named; elif $changed; then scope=changed; elif $include_live; then scope=all
else scope=full; fi
[ "${#suites[@]}" -gt 0 ] || exit 0
# bin/harness-doctor joins the marker to the process start the probe saw, before any slot wait.
test_scope_mark "$scope" suites "$repo" "${run_suites_queued%%[.,]*}"

shard_merge() { # name shards -> once its last shard has ended, the suite's .status and .log from theirs
  local name=$1 n=$2 i rc secs real bound cpu out_rc=0 out_secs=0 out_real=0 out_cpu=0 ms
  local -a passed=() failed_shards=()
  for ((i = 1; i <= n; i++)); do [ -e "$logdir/$name.shard-$i.st" ] || return 0; done
  mkdir "$logdir/$name.merge" 2>/dev/null || return 0
  for ((i = 1; i <= n; i++)); do
    IFS=$'\t' read -r rc secs real bound cpu <"$logdir/$name.shard-$i.st"
    if [ "$rc" = 0 ]; then passed+=("$i"); else failed_shards+=("$i"); [ "$out_rc" != 0 ] || out_rc=$rc; fi
    [ "$secs" -le "$out_secs" ] || out_secs=$secs
    if [ "$real" = - ] || [ "$out_real" = - ]; then out_real=-
    else ms=$(( ${real%.*} * 1000 + 10#${real#*.} )); [ "$ms" -le "$out_real" ] || out_real=$ms; fi
    if [ -z "$cpu" ] || [ -z "$out_cpu" ]; then out_cpu=''
    else out_cpu=$(( out_cpu + ${cpu%.*} * 1000 + 10#${cpu#*.} )); fi
  done
  [ "$out_real" = - ] || suite_journal_secs out_real "$out_real"
  [ -z "$out_cpu" ] || suite_journal_secs out_cpu "$out_cpu"
  # A failing shard's log last, so the failure tail is its own.
  for i in ${passed[@]+"${passed[@]}"} ${failed_shards[@]+"${failed_shards[@]}"}; do
    IFS=$'\t' read -r rc _ <"$logdir/$name.shard-$i.st"
    printf '== run-suites: shard %s/%s, exit %s\n' "$i" "$n" "$rc"
    cat "$logdir/$name.shard-$i.log" 2>/dev/null
  done >"$logdir/$name.log"
  if [ "$out_rc" = 0 ]; then
    local -a logs=()
    for ((i = 1; i <= n; i++)); do logs+=("$logdir/$name.shard-$i.log"); done
    suite_shard_last_line "${logs[@]}" >>"$logdir/$name.log"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$out_rc" "$out_secs" "$out_real" "$bound" "$out_cpu" >"$logdir/$name.status"
}

run_one() { # suite-path [shard i/N]
  local path="$1" shard=${2:-} name job start finish rc began ended cpu bound suite watch
  name=$(basename "$path")
  job=$name
  [ -z "$shard" ] || job="$name.shard-${shard%/*}"
  if [ -e "$logdir/owner-ended" ]; then printf 'run-suites: cancelled, its worker run ended\n' >"$logdir/$name.log"; return; fi
  suite_bound bound "$name"
  printf -v start '%(%s)T' -1
  suite_journal_ms began
  # Its own TMPDIR, never its own HOME: several suites here read the real ~/.claude on purpose
  # (test_consistency prices the INSTALLED hooks), and a fabricated HOME would make them pass
  # against nothing. TMPDIR is what mktemp fixtures collide on, and it is safe to move.
  (
    export TMPDIR="$logdir/tmp-$job" SUITE_JOURNAL_PID=$$
    export REPORT_BUS_LIVE_ROOT=$live_reports REPORT_BUS_LEAK_LOG="$logdir/$job.bus-leak"
    [ -z "$shard" ] || export SUITE_SHARD=$shard
    # A suite judges hooks the way a chat meets them; run from inside a worker it would inherit the
    # worker's markers and be judged as one, and a fixture HOME would still read the real toggle.
    # The chat's session id would hand every suite that chat's own worker pin; bytecode a suite's
    # SourceFileLoader import leaves in bin/ reads to a review's integrity check as a new file.
    # This run's own journal and times files are the live ones whenever a caller exported them.
    unset CLAUDEB_WORKER GROK_WORKER WORKER_RUN_RECORD WORKER_RUN_ID CLAUDE_LAUNCHER_SESSION WORKER_PICK_CONFIG_FILE CLAUDE_CODE_SESSION_ID \
      RUN_SUITES_JOURNAL RUN_SUITES_TIMES WORKER_SLOT
    export PYTHONDONTWRITEBYTECODE=1
    # A fixture's slot and lock waits would read as the machine's own in the Harness doctor.
    export HARNESS_WAITS_DIR="$TMPDIR/waits" WORKER_SLOTS_DIR="$TMPDIR/worker-slots"
    mkdir -p "$TMPDIR"
    if $profile && mkdir -p "$logdir/$job.shims" && : >>"$logdir/$name.execs"; then
      for bin in jq python3 lua git sleep date sed grep awk mktemp bash; do
        real=$(type -P "$bin") || continue
        args=''; [ "$bin" != sleep ] || args=' $*'
        printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"$bin$args\" >>\"$logdir/$name.execs\"" "exec \"$real\" \"\$@\"" \
          >"$logdir/$job.shims/$bin"
      done
      chmod +x "$logdir/$job.shims"/*
      PATH="$logdir/$job.shims:$PATH"
    fi
    cd "$repo" || exit 4
    # Absolute, not -n: a nested run must stay at 10, not sink further. $BASHPID, not $$:
    # $$ in this subshell is the parent, and nice only rises, so a parent dropped to 10
    # would pin the wall-clock tail behind every other invocation's wave. No lock.
    serial_suite "$name" || ! unattended || ! user_present || renice 10 -p "$BASHPID" >/dev/null 2>&1 || :
    ! serial_suite "$name" || trap - INT QUIT
    case "$path" in
      *.py) exec "$python" -m pytest -q "$path" ;;
      # $BASH and not `bash`: the header verified THIS interpreter, and a sub-suite resolving its
      # own off PATH gets macOS 3.2, where `declare -A` fails while the table still prints PASS.
      *) exec "$BASH" "$path" ;;
    esac
  ) >"$logdir/$job.log" 2>&1 &
  suite=$!
  suite_watch "$suite" "$bound" "$logdir/$job.timeout" &
  watch=$!
  wait "$suite"
  rc=$?
  if [ -e "$logdir/owner-ended" ] || [ -e "$logdir/$job.timeout" ]; then wait "$watch"; else kill "$watch" 2>/dev/null; fi
  if [ -e "$logdir/owner-ended" ] && [ "$rc" -ne 0 ]; then
    printf 'run-suites: cancelled, its worker run ended\n' >>"$logdir/$job.log"
    [ -z "$shard" ] || cat "$logdir/$job.log" >>"$logdir/$name.log"
    return
  fi
  if [ -s "$logdir/$job.bus-leak" ]; then
    cat "$logdir/$job.bus-leak" >>"$logdir/$job.log"
    [ "$rc" -ne 0 ] || rc=1
  fi
  if [ -e "$logdir/$job.timeout" ]; then
    rc=124
    printf 'run-suites: TIMEOUT after %s s, its process tree killed\n' "$bound" >>"$logdir/$job.log"
  fi
  printf -v finish '%(%s)T' -1
  suite_journal_ms ended
  # run_one runs as its own subshell, so the children line of `times` is this one suite's tree.
  suite_journal_cpu cpu "$logdir/$job.time" children
  [ -z "$began" ] || suite_journal_secs began "$(( ended - began ))"
  # `-`, never empty: IFS=$'\t' is whitespace to read, so an empty field collapses and cpu lands in it.
  if [ -z "$shard" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$rc" "$((finish - start))" "${began:--}" "$bound" "$cpu" >"$logdir/$name.status"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$rc" "$((finish - start))" "${began:--}" "$bound" "$cpu" >"$logdir/$job.st"
    shard_merge "$name" "${shard#*/}"
  fi
}

declare -a wave=() tail_wave=()
for entry in "${suites[@]}"; do
  if serial_suite "$(basename "$entry")"; then tail_wave+=("$entry"); else wave+=("$entry"); fi
done

# Unknown suites first: a new one may be the longest.
if [ "${#wave[@]}" -gt 1 ]; then
  mapfile -t wave < <(for i in "${!wave[@]}"; do
    printf '%s\t%s\t%s\n' "${last_secs[${wave[i]##*/}]:-999999}" "$i" "${wave[i]}"
  done | sort -t $'\t' -k1,1nr -k2,2n | cut -f3-)
fi

# Shards are jobs of this run's -j, so a slot still caps the fan-out; with no cores free they would
# add their duplicated setup and save no wall, so auto shards only while slot_room finds room.
if suite_shard_wanted; then
  for entry in "${suites[@]}"; do
    case $entry in *.sh) suite_shard_count "$entry" >/dev/null; [ "$suite_shard_n" -lt 2 ] || shards[${entry##*/}]=$suite_shard_n ;; esac
  done
fi
declare -a wave_jobs=()
for entry in ${wave[@]+"${wave[@]}"}; do
  n=${shards[${entry##*/}]:-1}
  if [ "$n" -lt 2 ]; then wave_jobs+=("$entry"); else for ((i = 1; i <= n; i++)); do wave_jobs+=("$entry"$'\t'"$i/$n"); done; fi
done

tail_jobs=0
for entry in ${tail_wave[@]+"${tail_wave[@]}"}; do tail_jobs=$((tail_jobs + ${shards[${entry##*/}]:-1})); done
printf 'run-suites: %s suites, %s jobs, -j %s, logs under %s\n' "${#suites[@]}" "$(( ${#wave_jobs[@]} + tail_jobs ))" "$jobs" "$logdir"
if [ "${#tail_wave[@]}" -gt 0 ] && unattended; then
  printf 'run-suites: %s wall-clock suite(s) stay at nice %s; the wave is nice 10 while someone is at the keyboard\n' \
    "${#tail_wave[@]}" "$(ps -o nice= -p $$ | tr -d '[:space:]')"
fi
if [ -n "$owner_record" ]; then
  (while sleep 5 && kill -0 "$$" 2>/dev/null; do ! owner_ended || { : >"$logdir/owner-ended"; break; }; done) &
  owner_watch=$!
  disown "$owner_watch"
fi
wall_start=$(date +%s)
running=0
for entry in ${wave_jobs[@]+"${wave_jobs[@]}"}; do
  while [ "$running" -ge "$jobs" ]; do wait -n 2>/dev/null || :; running=$((running - 1)); done
  shard=''
  [[ $entry != *$'\t'* ]] || shard=${entry#*$'\t'}
  run_one "${entry%%$'\t'*}" "$shard" &
  running=$((running + 1))
done
# A slot caps one fan-out: down to its last suite, the run frees it for a queued one. A single-suite
# run keeps it, or such runs would go uncapped; so does a serial tail, the suites that want quiet.
if [ -n "$own_slot" ] && [ "${#wave_jobs[@]}" -gt 1 ] && [ "${#tail_wave[@]}" -eq 0 ]; then
  while [ "$running" -gt 1 ]; do wait -n 2>/dev/null || :; running=$((running - 1)); done
  slot_release "$own_slot"
  own_slot=''
fi
wait
# In the background so a trapped signal ends this wait at once, as it did a foreground suite at HEAD;
# run_one gives the tail suite back the Ctrl-C a background job ignores.
for entry in ${tail_wave[@]+"${tail_wave[@]}"}; do
  n=${shards[${entry##*/}]:-1}
  if [ "$n" -lt 2 ]; then run_one "$entry" & wait "$!"
  else
    running=0
    for ((i = 1; i <= n; i++)); do
      while [ "$running" -ge "$jobs" ]; do wait -n 2>/dev/null || :; running=$((running - 1)); done
      run_one "$entry" "$i/$n" &
      running=$((running + 1))
    done
    wait
  fi
done
wall=$(( $(date +%s) - wall_start ))

declare -a failed=()
declare -A ran=()
serial_total=0
width=0
for entry in "${suites[@]}"; do
  name=$(basename "$entry")
  [ "${#name}" -le "$width" ] || width=${#name}
done
printf '\n%-*s  %-6s  %5s  %s\n' "$width" suite result secs 'last line'
for entry in "${suites[@]}"; do
  name=$(basename "$entry")
  ran[$name]=1
  rc=1
  seconds=0
  IFS=$'\t' read -r rc seconds _ 2>/dev/null <"$logdir/$name.status" || { rc=1; seconds=0; }
  serial_total=$((serial_total + seconds))
  verdict=PASS
  [ "$rc" -eq 0 ] || { verdict="FAIL $rc"; failed+=("$name"); }
  [ "$rc" -ne 0 ] || last_secs[$name]=$seconds
  printf '%-*s  %-6s  %5s  %s\n' "$width" "$name" "$verdict" "$seconds" \
    "$(grep -v '^[[:space:]]*$' "$logdir/$name.log" 2>/dev/null | tail -n1 | cut -c1-100)"
done
printf '\n%s suites · %s PASS · %s FAIL · %ss wall (%ss serial)\n' \
  "${#suites[@]}" "$(( ${#suites[@]} - ${#failed[@]} ))" "${#failed[@]}" "$wall" "$serial_total"

if [ "${#last_secs[@]}" -gt 0 ] && mkdir -p "${times_file%/*}" 2>/dev/null &&
    times_tmp=$(mktemp "$times_file.XXXXXX" 2>/dev/null); then
  { [ -r "$times_file" ] && TIMES_KEY=$times_key awk -F'\t' '$1 != ENVIRON["TIMES_KEY"]' "$times_file"
    for name in "${!last_secs[@]}"; do
      [ -n "${ran[$name]:-}" ] || [ -e "$repo/tests/$name" ] || continue
      printf '%s\t%s\t%s\n' "$times_key" "$name" "${last_secs[$name]}"
    done
  } >"$times_tmp" 2>/dev/null && mv -f "$times_tmp" "$times_file" 2>/dev/null || rm -f "$times_tmp"
fi

[ "${#failed[@]}" -eq 0 ] || {
  for name in "${failed[@]}"; do
    printf '\n=== %s (last 30 lines) ===\n' "$name"
    tail -n 30 "$logdir/$name.log" 2>/dev/null
  done
  exit 1
}
exit 0
exit; }
