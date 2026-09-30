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

usage() {
  cat >&2 <<'USAGE'
usage: run-suites.sh [--repo <dir>] [-j <n>] [--changed] [--all] [suite ...]

Runs a repository's test suites in parallel, one log per suite, and prints one table.
Exit 1 if any suite failed, with the last 30 lines of each failure.

  --repo <dir>  repository root (default: the git root of the current directory)
  -j <n>        parallel jobs (default: cores / 2, minimum 2)
  --changed     only suites whose text mentions the basename of a path in
                `git diff --name-only HEAD` or an untracked file. A HEURISTIC: a suite that
                exercises a file it never names by basename is missed, so --changed is for
                iterating, never for the final gate.
  --all         also run the suites skipped by default because they read live machine state
                (llm-legs e2e_surfaces.sh, test_instruction_rates_live.sh)
  suite ...     explicit suite names or paths; skips discovery
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

# Branch of a linked worktree, empty otherwise. Detached is empty: there is no branch to share.
run_suites_linked_branch() {
  local git_dir='' common='' branch=''
  git_dir=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ "$git_dir" != "$common" ] || return 0
  branch=$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  printf '%s\n' "$branch"
}

# A sibling checkout whose porcelain branch is refs/heads/<branch>. The main checkout counts
# when it is the one on that branch; a missing directory does not.
run_suites_same_branch() {
  local branch="$2" line='' path=''
  [ -n "$branch" ] && [ -d "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *) path=${line#worktree } ;;
      branch\ *)
        if [ "${line#branch }" = "refs/heads/$branch" ] && [ -n "$path" ] && [ -d "$path" ]; then
          printf '%s\n' "$path"
          return 0
        fi
        path=''
        ;;
      '') path='' ;;
    esac
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
  return 1
}

# A linked worktree has no sibling checkout beside it. Another repo's worktree on this same
# branch is the set under test; otherwise the main checkout. An exported variable wins either way.
if common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  projects=$(dirname "$(dirname "$common")")
  own_branch=$(run_suites_linked_branch "$repo")
  for sibling in CLAUDE_SETUP_ROOT=claude-setup REVIEW_BENCH_ROOT=review-bench REVIEW_ROOT=review-bench LLM_LEGS_ROOT=llm-legs; do
    var=${sibling%%=*} name=${sibling#*=}
    [ -n "${!var:-}" ] && continue
    if [ -n "$own_branch" ] && sibling_wt=$(run_suites_same_branch "$projects/$name" "$own_branch"); then
      export "$var=$sibling_wt"
      continue
    fi
    if [ ! -d "$repo/../$name" ] && [ -d "$projects/$name" ]; then export "$var=$projects/$name"; fi
  done
  # review-bench's rbench_paths finds llm-legs/share beside ITS root, which a worktree has not.
  [ -n "${LLM_LEGS_SHARE:-}" ] || [ -z "${LLM_LEGS_ROOT:-}" ] || export LLM_LEGS_SHARE="$LLM_LEGS_ROOT/share"
fi

[[ "$jobs" =~ ^[0-9]+$ ]] || usage
if [ "$jobs" -eq 0 ]; then
  jobs=$(( $(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) / 2 ))
  [ "$jobs" -ge 2 ] || jobs=2
fi

# Each suite's last passing duration, keyed by the main checkout so a worktree shares it: the wave
# starts the longest first, since alphabetical order left the slowest suite starting last.
times_file=${RUN_SUITES_TIMES:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/times.tsv}
times_key=$repo
[ "${common:-}" = "${common%/.git}/.git" ] && times_key=${common%/.git}
declare -A last_secs=()
if [ -r "$times_file" ]; then
  while IFS=$'\t' read -r key name secs; do
    [ "$key" = "$times_key" ] && [[ "$secs" =~ ^[0-9]+$ ]] && last_secs[$name]=$secs
  done <"$times_file"
fi

# Suites that read live machine state — the real limits store, the real instruction-file export —
# and so answer about this Mac rather than about the code. They are honest checks and they are not
# repeatable beside twenty other processes, so they stay out of the wave unless asked for.
live_suite() {
  case "$1" in
    e2e_surfaces.sh|test_instruction_rates_live.sh) return 0 ;;
    *) return 1 ;;
  esac
}

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
  declare -a names=()
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    names+=("$(basename "$entry")")
  done < <({ git -C "$repo" diff --name-only HEAD 2>/dev/null
             git -C "$repo" ls-files --others --exclude-standard 2>/dev/null; } | sort -u)
  declare -a kept=()
  for entry in "${suites[@]}"; do
    for name in ${names[@]+"${names[@]}"}; do
      # A changed suite always runs; otherwise the suite has to name the changed file.
      if [ "$name" = "$(basename "$entry")" ] || grep -qF -- "$name" "$entry" 2>/dev/null; then
        kept+=("$entry")
        break
      fi
    done
  done
  suites=(${kept[@]+"${kept[@]}"})
  [ "${#suites[@]}" -gt 0 ] || { printf 'run-suites: nothing changed that any suite names\n'; exit 0; }
fi

logdir=$(mktemp -d "${TMPDIR:-/tmp}/run-suites.XXXXXX") || fail 'could not create a log directory'
# The statusline's work probe finds this run by its pid, counts its .status files for `n/m` and
# names the repository from here: this process never leaves the caller's directory.
progress_file="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}/suites-$$"
mkdir -p "${progress_file%/*}" 2>/dev/null &&
  printf '%s\t%s\t%s\t%(%s)T\n' "$logdir" "${#suites[@]}" "$repo" -1 >"$progress_file" 2>/dev/null
trap 'rm -f "$progress_file"' EXIT
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-scope.sh"
if [ "${#explicit[@]}" -gt 0 ]; then scope=named; elif $changed; then scope=changed; elif $include_live; then scope=all
else scope=full; fi
test_scope_mark "$scope" suites "$repo"

run_one() { # suite-path
  local path="$1" name start finish rc
  name=$(basename "$path")
  start=$(date +%s)
  # Its own TMPDIR, never its own HOME: several suites here read the real ~/.claude on purpose
  # (test_consistency prices the INSTALLED hooks), and a fabricated HOME would make them pass
  # against nothing. TMPDIR is what mktemp fixtures collide on, and it is safe to move.
  (
    export TMPDIR="$logdir/tmp-$name"
    # A suite judges hooks the way a chat meets them; run from inside a worker it would inherit the
    # worker's markers and be judged as one, and a fixture HOME would still read the real toggle.
    unset CLAUDEB_WORKER WORKER_RUN_RECORD CLAUDE_LAUNCHER_SESSION WORKER_PICK_CONFIG_FILE
    mkdir -p "$TMPDIR"
    cd "$repo" || exit 4
    # Absolute, not -n: a nested run must stay at 10, not sink further. $BASHPID, not $$:
    # $$ in this subshell is the parent, and nice only rises, so a parent dropped to 10
    # would pin the wall-clock tail behind every other invocation's wave. No lock.
    serial_suite "$name" || renice 10 -p "$BASHPID" >/dev/null 2>&1 || :
    case "$path" in
      *.py) exec python3 -m pytest -q "$path" ;;
      # $BASH and not `bash`: the header verified THIS interpreter, and a sub-suite resolving its
      # own off PATH gets macOS 3.2, where `declare -A` fails while the table still prints PASS.
      *) exec "$BASH" "$path" ;;
    esac
  ) >"$logdir/$name.log" 2>&1
  rc=$?
  finish=$(date +%s)
  printf '%s\t%s\n' "$rc" "$((finish - start))" >"$logdir/$name.status"
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
for entry in ${tail_wave[@]+"${tail_wave[@]}"}; do run_one "$entry"; done
wall=$(( $(date +%s) - wall_start ))

declare -a failed=()
serial_total=0
width=0
for entry in "${suites[@]}"; do
  name=$(basename "$entry")
  [ "${#name}" -le "$width" ] || width=${#name}
done
printf '\n%-*s  %-6s  %5s  %s\n' "$width" suite result secs 'last line'
for entry in "${suites[@]}"; do
  name=$(basename "$entry")
  rc=1
  seconds=0
  IFS=$'\t' read -r rc seconds <"$logdir/$name.status" 2>/dev/null || { rc=1; seconds=0; }
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
    for name in "${!last_secs[@]}"; do printf '%s\t%s\t%s\n' "$times_key" "$name" "${last_secs[$name]}"; done
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
