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
set -u
printf -v run_suites_start '%(%s)T' -1
run_suites_queued=${EPOCHREALTIME:-$run_suites_start} run_suites_began=${EPOCHREALTIME:-$run_suites_start}
run_worker=${WORKER_RUN_ID:-} run_session=${CLAUDE_CODE_SESSION_ID:-${CLAUDE_LAUNCHER_SESSION:-}}

usage() {
  cat >&2 <<'USAGE'
usage: run-suites.sh [--repo <dir>] [-j <n>] [--changed] [--all] [suite ...]

Runs a repository's test suites in parallel, one log per suite, and prints one table.
Exit 1 if any suite failed, with the last 30 lines of each failure.

  --repo <dir>  repository root (default: the git root of the current directory)
  -j <n>        parallel jobs (default: cores / 2, minimum 2)
  --changed     only suites whose text, or a tests/ helper file they name, mentions the basename
                of a path in `git diff --name-only HEAD` or an untracked file. A HEURISTIC: a suite that
                exercises a file it never names by basename is missed, so --changed is for
                iterating, never for the final gate.
  --all         also run the suites skipped by default because they read live machine state
                (llm-legs e2e_surfaces.sh, test_instruction_rates_live.sh)
  suite ...     explicit suite names or paths; skips discovery

Machine-wide at most RUN_SUITES_SLOTS runs at once (default cores / 3, 2 to 4); a run waits for a free
slot under RUN_SUITES_SLOTS_DIR, its wait a limiter hold.
USAGE
  exit 2
}

fail() { printf 'run-suites: %s\n' "$*" >&2; exit 4; }

repo=''
jobs=0
changed=false
include_live=false
declare -a explicit=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
    -j) [ "$#" -ge 2 ] || usage; jobs="$2"; shift 2 ;;
    --changed) changed=true; shift ;;
    --all) include_live=true; shift ;;
    -h|--help) usage ;;
    --) shift; while [ "$#" -gt 0 ]; do explicit+=("$1"); shift; done ;;
    -*) usage ;;
    *) explicit+=("$1"); shift ;;
  esac
done

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
declare -A last_secs=()
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
    test_commit_journal.sh|test_review_flow_gate.sh) return 0 ;;
    test_claude_session_driver.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Machine-wide, at most RUN_SUITES_SLOTS runs at once: each already fans out -j cores/2 suites, so
# cores/3 runs (2 to 4) fill the cores and a third keeps a short named run from queueing behind two
# full ones. A nested run (a suite testing this runner) inherits its parent's slot.
own_slot=''
if [ -z "${RUN_SUITES_SLOT:-}" ]; then
  own_slot=$(slot_wait "${RUN_SUITES_SLOTS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/slots}" \
    "${RUN_SUITES_SLOTS:-$(slots_from_cores 3 2 4)}" $((6 * 3600)) run-suites "suites of $repo") ||
    fail 'could not take a suite slot'
  trap 'slot_release "$own_slot"' EXIT
  export RUN_SUITES_SLOT=$own_slot
  printf -v run_suites_start '%(%s)T' -1
  run_suites_began=${EPOCHREALTIME:-$run_suites_start}
fi
run_slot=${RUN_SUITES_SLOT:-}

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
  mapfile -t suites < <(printf '%s\n' "${suites[@]}" | affected_filter "$repo" "$names_file" | sort -u)
  rm -f "$names_file"
  [ "${#suites[@]}" -gt 0 ] || { printf 'run-suites: nothing changed that any suite names\n'; exit 0; }
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
if printf '%s\n' "${suites[@]}" | grep -q '\.py$'; then
  python=$(pytest_python) ||
    fail "no python with pytest: tried $repo/.venv/bin/python, python3 and python3.X on PATH"
fi

logdir=$(mktemp -d "${TMPDIR:-/tmp}/run-suites.XXXXXX") || fail 'could not create a log directory'
# The statusline's work probe finds this run by its pid, counts its .status files for `n/m` and
# names the repository from here: this process never leaves the caller's directory.
progress_file="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}/suites-$$"
mkdir -p "${progress_file%/*}" 2>/dev/null &&
  printf '%s\t%s\t%s\t%s\n' "$logdir" "${#suites[@]}" "$repo" "$run_suites_start" >"$progress_file" 2>/dev/null
find "${progress_file%/*}" -maxdepth 1 -name 'suites-*.done' -mmin +1 -delete 2>/dev/null
journal_run() {
  local entry name rc secs real cpu complete=true queued began ended
  local -a names=()
  suite_journal_suites=''
  for entry in "${suites[@]}"; do
    name=${entry##*/}
    names+=("$name")
    rc='' real='' cpu=''
    [ -r "$logdir/$name.status" ] && IFS=$'\t' read -r rc secs real cpu <"$logdir/$name.status"
    [ "$real" != - ] || real=''
    if [[ "$rc" =~ ^[0-9]+$ ]]; then suite_journal_suite "$name" "$rc" "${real:-$secs}" "$cpu"; else complete=false; fi
  done
  [ -z "$run_signal" ] || complete=false
  mapfile -t names < <(printf '%s\n' "${names[@]}" | LC_ALL=C sort)
  suite_journal_digest "${names[@]}"
  suite_journal_git "$repo"
  suite_journal_ms queued "$run_suites_queued"; suite_journal_secs queued "$queued"
  suite_journal_ms began "$run_suites_began"; suite_journal_secs began "$began"
  suite_journal_ms ended; [ -n "$ended" ] || suite_journal_ms ended "$(date +%s)"; suite_journal_secs ended "$ended"
  suite_journal_row suites "$$" "$queued" "$began" "$ended" "$repo" "$times_key" "$suite_journal_head" "${scope:-}" \
    "$run_worker" "$run_session" "$jobs" "$run_slot" "$run_signal" "$complete"
  suite_journal_append "$run_journal"
}
run_signal='' run_finished=''
finish_run() {
  [ -z "$run_finished" ] || return 0
  run_finished=1
  journal_run
  mv -f "$progress_file" "$progress_file.done" 2>/dev/null
  [ -z "$own_slot" ] || slot_release "$own_slot"
}
on_signal() { # number name
  run_signal=$1
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
test_scope_mark "$scope" suites "$repo" "$run_suites_start"

run_one() { # suite-path
  local path="$1" name start finish rc began ended cpu
  name=$(basename "$path")
  printf -v start '%(%s)T' -1
  suite_journal_ms began
  # Its own TMPDIR, never its own HOME: several suites here read the real ~/.claude on purpose
  # (test_consistency prices the INSTALLED hooks), and a fabricated HOME would make them pass
  # against nothing. TMPDIR is what mktemp fixtures collide on, and it is safe to move.
  (
    export TMPDIR="$logdir/tmp-$name" SUITE_JOURNAL_PID=$$
    export REPORT_BUS_LIVE_ROOT=$live_reports REPORT_BUS_LEAK_LOG="$logdir/$name.bus-leak"
    # A suite judges hooks the way a chat meets them; run from inside a worker it would inherit the
    # worker's markers and be judged as one, and a fixture HOME would still read the real toggle.
    # The chat's session id would hand every suite that chat's own worker pin; bytecode a suite's
    # SourceFileLoader import leaves in bin/ reads to a review's integrity check as a new file.
    unset CLAUDEB_WORKER WORKER_RUN_RECORD WORKER_RUN_ID CLAUDE_LAUNCHER_SESSION WORKER_PICK_CONFIG_FILE CLAUDE_CODE_SESSION_ID
    export PYTHONDONTWRITEBYTECODE=1
    # A fixture's slot and lock waits would read as the machine's own in the Harness doctor's Wait classes.
    export HARNESS_WAITS_DIR="$TMPDIR/waits"
    mkdir -p "$TMPDIR"
    cd "$repo" || exit 4
    # Absolute, not -n: a nested run must stay at 10, not sink further. $BASHPID, not $$:
    # $$ in this subshell is the parent, and nice only rises, so a parent dropped to 10
    # would pin the wall-clock tail behind every other invocation's wave. No lock.
    serial_suite "$name" || renice 10 -p "$BASHPID" >/dev/null 2>&1 || :
    ! serial_suite "$name" || trap - INT QUIT
    case "$path" in
      *.py) exec "$python" -m pytest -q "$path" ;;
      # $BASH and not `bash`: the header verified THIS interpreter, and a sub-suite resolving its
      # own off PATH gets macOS 3.2, where `declare -A` fails while the table still prints PASS.
      *) exec "$BASH" "$path" ;;
    esac
  ) >"$logdir/$name.log" 2>&1
  rc=$?
  if [ -s "$logdir/$name.bus-leak" ]; then
    cat "$logdir/$name.bus-leak" >>"$logdir/$name.log"
    [ "$rc" -ne 0 ] || rc=1
  fi
  printf -v finish '%(%s)T' -1
  suite_journal_ms ended
  # run_one runs as its own subshell, so the children line of `times` is this one suite's tree.
  suite_journal_cpu cpu "$logdir/$name.time" children
  [ -z "$began" ] || suite_journal_secs began "$(( ended - began ))"
  # `-`, never empty: IFS=$'\t' is whitespace to read, so an empty field collapses and cpu lands in it.
  printf '%s\t%s\t%s\t%s\n' "$rc" "$((finish - start))" "${began:--}" "$cpu" >"$logdir/$name.status"
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

printf 'run-suites: %s suites, -j %s, logs under %s\n' "${#suites[@]}" "$jobs" "$logdir"
if [ "${#tail_wave[@]}" -gt 0 ]; then
  printf 'run-suites: %s wall-clock suite(s) stay at nice %s; the wave is nice 10\n' \
    "${#tail_wave[@]}" "$(ps -o nice= -p $$ | tr -d '[:space:]')"
fi
wall_start=$(date +%s)
running=0
for entry in ${wave[@]+"${wave[@]}"}; do
  while [ "$running" -ge "$jobs" ]; do wait -n 2>/dev/null || :; running=$((running - 1)); done
  run_one "$entry" &
  running=$((running + 1))
done
wait
# In the background so a trapped signal ends this wait at once, as it did a foreground suite at HEAD;
# run_one gives the tail suite back the Ctrl-C a background job ignores.
for entry in ${tail_wave[@]+"${tail_wave[@]}"}; do run_one "$entry" & wait "$!"; done
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
  IFS=$'\t' read -r rc seconds _ <"$logdir/$name.status" 2>/dev/null || { rc=1; seconds=0; }
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
