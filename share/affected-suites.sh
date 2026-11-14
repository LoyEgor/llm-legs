#!/usr/bin/env bash
# Suites covering changed files, chosen by share/suite_select.py: a file's own suites (the suite itself, a suite
# whose name holds its stem, a suite or tests/ helper it names that holds its repo path, imports or requires it or
# the package whose __init__ names it, or
# does so for a repo file importing or sourcing it) plus the suites test_catches credits with a whole catch on it over
# 90 days, or with any credit when they also name it; a file with neither keeps the name rule (a suite or helper
# naming its basename). A suite only naming a file, or with no catch in 90 days but for its own file, leaves
# targeted runs: the night's full run keeps it.
# test_consistency.sh too when docs/shared-invariants.md names one. Then the slow layer (in a worker) and the
# scheduled layer (tests/scheduled-suites, below) leave their suites out; tests/hot-paths' questions print first.
# Sourced by
# run-suites.sh (--changed); run, it is tests/affected:
#   affected-suites.sh --repo <dir> [file...]   (no file: every file changed against HEAD, untracked or
#                                                committed on this branch since main, and in its sibling worktrees)
#   affected-suites.sh --repo <dir> --slow-refresh   the slow layer recomputed from the run-suites journal

{
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/worktree-branch.sh"
# Suites that read live machine state (the real limits store, the real instruction-file export) and so
# answer about this Mac rather than the code: out of every run unless asked for by name or --all.
live_suite() {
  case "$1" in
    e2e_surfaces.sh|test_instruction_rates_live.sh) return 0 ;;
    *) return 1 ;;
  esac
}

affected_names() { # repo [file...] -> paths, one a line
  local repo=$1 file base
  shift
  if [ "$#" -eq 0 ]; then
    { git -C "$repo" diff --name-only HEAD 2>/dev/null
      git -C "$repo" ls-files --others --exclude-standard 2>/dev/null
      base=$(git -C "$repo" merge-base main HEAD 2>/dev/null) && git -C "$repo" diff --name-only "$base" HEAD 2>/dev/null
      sibling_names "$repo"
    } | sort -u | grep -v '^$'
    return
  fi
  for file in "$@"; do [ -n "$file" ] && printf '%s\n' "$file"; done
}

# The branch's worktrees in the other sweep repositories: absolute paths of the files it changed there (its commits
# past main and every night's base, uncommitted, untracked), or with main, of those main changed since it forked.
sibling_names() { # repo [main]
  local branch sweep wt file
  branch=$(linked_worktree_branch "$1")
  [ -n "$branch" ] || return 0
  while IFS= read -r sweep; do
    [ -n "$sweep" ] && wt=$(same_branch_worktree "$sweep" "$branch") && [ "$wt" != "$1" ] || continue
    if [ "${2:-}" = main ]; then
      git -C "$wt" log --format= --name-only --no-renames main --not HEAD
    else
      git -C "$wt" log --format= --name-only --no-renames HEAD --not main --glob='refs/night/*/base'
      git -C "$wt" diff --name-only HEAD
      git -C "$wt" ls-files --others --exclude-standard
    fi 2>/dev/null | while IFS= read -r file; do [ -z "$file" ] || printf '%s/%s\n' "$wt" "$file"; done
  done < <(cat "${NIGHT_RUN_SWEEP_REPOS:-$HOME/.claude/sweep-repos}" 2>/dev/null)
}

affected_filter() { # repo paths-file <suite paths -> the suites covering one of the paths
  local repo=$1 names=$2 share select invariants consistency suites
  share=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  select=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/suite_select.py
  suites=$(cat)
  printf '%s\n' "$suites" | python3 -B "$select" "$repo" "$names" ||
    { printf 'affected: suite_select.py failed, every suite selected\n' >&2; printf '%s\n' "$suites"; }
  invariants="${share%/*}/docs/shared-invariants.md"
  consistency="${share%/*}/tests/test_consistency.sh"
  [ -r "$invariants" ] && [ -r "$consistency" ] && sed 's,.*/,,' "$names" | grep -qwF -f - -- "$invariants" &&
    printf '%s\n' "$consistency"
  return 0
}

# The slow layer, tests/slow-suites: inside a worker an affected suite of it runs only when the worker
# edited that suite; outside one (the landing, a human, the night's full run) every affected suite runs.
slow_layer_split() { # repo names-file suite-path... -> slow_kept (array) and slow_skipped (names), noted on stderr
  local repo=$1 names=$2 slow edited entry name
  shift 2
  slow_kept=() slow_skipped=''
  if [ -z "${WORKER_RUN_ID:-}" ] || [ ! -r "$repo/tests/slow-suites" ]; then
    [ "$#" -eq 0 ] || slow_kept=("$@")
    return 0
  fi
  slow=$'\n'$(<"$repo/tests/slow-suites")$'\n' edited=$'\n'$(sed 's,.*/,,' "$names")$'\n'
  for entry in "$@"; do
    name=${entry##*/}
    if [[ $slow == *$'\n'"$name"$'\n'* && $edited != *$'\n'"$name"$'\n'* ]]; then
      slow_skipped+="${slow_skipped:+ }$name"
    else
      slow_kept+=("$entry")
    fi
  done
  [ -z "$slow_skipped" ] || printf 'slow layer skipped: %s (the landing and the night full run run them)\n' "$slow_skipped" >&2
}

# The scheduled layer, tests/scheduled-suites: `<suite> <period hours> [path...]` a line, # comments. Such a suite
# runs on main every period (bin/scheduled-suites: bisects a failure and hands it off), so a worker's selection and a
# landing's leave it out, unless the change edits the suite or one of its paths (its budgets), RUN_SCHEDULED=1 asks
# for it, or it is named (tests/run-all <suite>); the night's full run names every suite. The list is the policy:
# one line in or out is the whole cost of a change.
scheduled_list() { # repo -> "suite hours [path...]", one a line
  [ -r "$1/tests/scheduled-suites" ] || return 0
  sed 's/#.*//' "$1/tests/scheduled-suites" | awk 'NF >= 2 && $2 ~ /^[0-9]+$/ { $1 = $1; print }'
}

scheduled_state() { # repo -> the scheduler's state dir of its main checkout (out of Caches)
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=$1/.git
  common=${common%/.git}
  printf '%s/%s\n' "${SCHEDULED_SUITES_DIR:-$HOME/Library/Application Support/scheduled-suites}" "${common##*/}"
}

scheduled_layer_split() { # repo names-file suite-path... -> sched_kept (array) and sched_skipped (names), noted on stderr
  local repo=$1 names=$2 list line suite hours path name entry edited state open keep
  shift 2
  sched_kept=() sched_skipped=''
  list=$(scheduled_list "$repo")
  if [ -z "$list" ]; then [ "$#" -eq 0 ] || sched_kept=("$@"); return 0; fi
  state=$(scheduled_state "$repo")
  edited=$'\n'$(cat "$names")$'\n'
  while read -r suite hours line; do
    # An open failure of main is everyone's news in this repository, whatever the change selects.
    [ ! -r "$state/$suite/open" ] || { read -r open <"$state/$suite/open"; printf 'scheduled: %s\n' "$open" >&2; }
  done <<<"$list"
  for entry in "$@"; do
    name=${entry##*/} keep=1
    line=$(awk -v s="$name" '$1 == s' <<<"$list")
    if [ -n "$line" ] && [ "${RUN_SCHEDULED:-}" != 1 ]; then
      read -r suite hours line <<<"$line"
      keep=''
      for path in "tests/$suite" $line; do
        [[ $edited == *$'\n'"$path"$'\n'* || $edited == *"/$path"$'\n'* ]] && keep=1
      done
    fi
    if [ -n "$keep" ]; then sched_kept+=("$entry"); continue; fi
    sched_skipped+="${sched_skipped:+ }$name"
    printf 'scheduled layer left out: %s (runs on main every %s h; run it now when the change is large or touches a hot path: tests/run-all %s, or RUN_SCHEDULED=1 in front of tests/affected, tests/run-all --changed or land)\n' \
      "$name" "$hours" "$name" >&2
  done
}

# tests/hot-paths: path patterns (bash globs from the repository root) and the lines to say, each `> `-led. A change
# touching one gets the project's questions on stderr once, before its suites; any other change, nothing.
hot_path_questions() { # repo names-file
  local repo=$1 names=$2 file=$1/tests/hot-paths rel pat hit='' more=0
  [ -r "$file" ] && [ "${HOT_PATH_QUESTIONS:-}" != off ] || return 0
  while IFS= read -r rel; do
    case $rel in "$repo"/*) rel=${rel#"$repo"/} ;; /*) continue ;; esac
    while IFS= read -r pat; do
      case $pat in ''|'#'*|'>'*) continue ;; esac
      # shellcheck disable=SC2053
      if [[ $rel == $pat ]]; then
        if [ -z "$hit" ]; then hit=$rel; else more=$((more + 1)); fi
        break
      fi
    done <"$file"
  done <"$names"
  [ -n "$hit" ] || return 0
  [ "$more" -eq 0 ] || hit+=" and $more more"
  printf 'hot path (%s): answer from the diff before you design\n' "$hit" >&2
  sed -n 's/^> \{0,1\}/  /p' "$file" >&2
}

affected_suites() { # repo [file...] -> suite paths covering the files, sorted and unique
  local repo=$1 names suite
  local -a found=()
  shift
  names=$(mktemp "${TMPDIR:-/tmp}/affected.XXXXXX") || return 1
  affected_names "$repo" "$@" | grep -v '^$' >"$names"
  # The overlap's two passes ask for neither: it splits its own result once.
  [ -n "${affected_overlap_pass:-}" ] || hot_path_questions "$repo" "$names"
  if [ -s "$names" ]; then
    while IFS= read -r suite; do found+=("$suite"); done < <(
      ls "$repo"/tests/test_*.sh "$repo"/tests/test_*.py "$repo"/tests/e2e_*.sh 2>/dev/null |
        while IFS= read -r suite; do live_suite "${suite##*/}" || printf '%s\n' "$suite"; done |
        affected_filter "$repo" "$names" | sort -u)
  fi
  slow_layer_split "$repo" "$names" ${found[@]+"${found[@]}"}
  if [ -n "${affected_overlap_pass:-}" ]; then sched_kept=(${slow_kept[@]+"${slow_kept[@]}"})
  else scheduled_layer_split "$repo" "$names" ${slow_kept[@]+"${slow_kept[@]}"}; fi
  rm -f "$names"
  [ "${#sched_kept[@]}" -eq 0 ] || printf '%s\n' "${sched_kept[@]}"
}

affected_overlap() {
  local repo=$1 base=$2 own fork branch_files main_files branch_suites main_suites file shared names affected_overlap_pass=1
  local -a branch=() upstream=() both=()
  # The branch's files are its own commits' only, from where it leaves main (or a base past that, a night snapshot it
  # holds): an older base (land's mark from before a hand rebase) would count main's commits since it as the branch's,
  # keep a scheduled suite they edit and add suites only they select (chats-app deploy-head, 2026-11-14).
  own=$base
  if fork=$(git -C "$repo" merge-base main HEAD 2>/dev/null) && git -C "$repo" merge-base --is-ancestor "$base" "$fork" 2>/dev/null
  then own=$fork; fi
  branch_files=$(git -C "$repo" diff --no-renames --name-only "$own...HEAD" && sibling_names "$repo") || return 4
  main_files=$(git -C "$repo" diff --no-renames --name-only "$base..main" && sibling_names "$repo" main) || return 4
  [ -n "$branch_files" ] && [ -n "$main_files" ] || return 0
  while IFS= read -r file; do branch+=("$file"); done <<<"$branch_files"
  while IFS= read -r file; do upstream+=("$file"); done <<<"$main_files"
  branch_suites=$(WORKER_RUN_ID= affected_suites "$repo" "${branch[@]}") || return 4
  main_suites=$(WORKER_RUN_ID= affected_suites "$repo" "${upstream[@]}") || return 4
  shared=$(LC_ALL=C comm -12 <(printf '%s\n' "$branch_suites" | LC_ALL=C sort) \
    <(printf '%s\n' "$main_suites" | LC_ALL=C sort) | grep -v '^$')
  [ -n "$shared" ] || return 0
  # The scheduled layer once, on what the branch changed: its own edit of a scheduled suite keeps that suite.
  while IFS= read -r file; do both+=("$file"); done <<<"$shared"
  names=$(mktemp "${TMPDIR:-/tmp}/affected.XXXXXX") || return 4
  printf '%s\n' "$branch_files" >"$names"
  scheduled_layer_split "$repo" "$names" "${both[@]}"
  rm -f "$names"
  [ "${#sched_kept[@]}" -eq 0 ] || printf '%s\n' "${sched_kept[@]}"
  return 0
}

slow_refresh() { # repo -> the suites of its main checkout whose median CPU over 7 days of passing runs passes 45 s
  local top root name journal=${RUN_SUITES_JOURNAL:-${RUN_SUITES_TIMES:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/times.tsv}}
  [ -n "${RUN_SUITES_JOURNAL:-}" ] || journal=${journal%/*}/runs.jsonl
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-scope.sh"
  git_top "$1" || root=$1
  jq -Rrn --arg root "$root" --argjson since "$(( $(date +%s) - 7 * 86400 ))" '
    [inputs | fromjson? | select(type == "object" and .repo_root == $root and (.ended_at | type == "number") and .ended_at >= $since)
      | .suites // {} | to_entries[] | select(.value.rc == 0 and (.value.cpu_s | type == "number"))]
    | group_by(.key)[] | (map(.value.cpu_s) | sort) as $c | ($c | length) as $n
    | select((if $n % 2 == 1 then $c[($n - 1) / 2] else ($c[$n / 2 - 1] + $c[$n / 2]) / 2 end) > 45) | .[0].key' \
    "$journal" | LC_ALL=C sort | while IFS= read -r name; do [ ! -e "$1/tests/$name" ] || printf '%s\n' "$name"; done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  repo=''
  [ "${1:-}" != --repo ] || { repo=${2:-}; shift 2; }
  [ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'affected: no --repo and no git root here' >&2; exit 4; }
  repo=$(cd "$repo" && pwd -P) || exit 4
  [ "${1:-}" != --slow-refresh ] || { slow_refresh "$repo"; exit; }
  [ "${1:-}" != -- ] || shift
  if [ "${1:-}" = --overlap ]; then
    [ "$#" -eq 2 ] || { echo 'usage: tests/affected --overlap <base>' >&2; exit 4; }
    affected_overlap "$repo" "$2"
  else
    affected_suites "$repo" "$@"
  fi
fi
case $0 in "${BASH_SOURCE[0]}") exit; esac; }
