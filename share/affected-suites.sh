#!/usr/bin/env bash
# Suites covering changed files: a suite whose text, or a tests/ helper it names, mentions a file's
# basename; test_consistency.sh too when docs/shared-invariants.md names one. A heuristic: a suite
# that never names the file is missed. Sourced by run-suites.sh (--changed); run, it is tests/affected:
#   affected-suites.sh --repo <dir> [file...]   (no file: every file changed against HEAD or untracked)
#   affected-suites.sh --repo <dir> --slow-refresh   the slow layer recomputed from the run-suites journal

# Suites that read live machine state (the real limits store, the real instruction-file export) and so
# answer about this Mac rather than the code: out of every run unless asked for by name or --all.
live_suite() {
  case "$1" in
    e2e_surfaces.sh|test_instruction_rates_live.sh) return 0 ;;
    *) return 1 ;;
  esac
}

affected_names() { # repo [file...] -> basenames, one a line
  local repo=$1 file
  shift
  if [ "$#" -eq 0 ]; then
    { git -C "$repo" diff --name-only HEAD 2>/dev/null
      git -C "$repo" ls-files --others --exclude-standard 2>/dev/null; } | sort -u | while IFS= read -r file; do
      [ -n "$file" ] && printf '%s\n' "${file##*/}"
    done
    return
  fi
  for file in "$@"; do [ -n "$file" ] && printf '%s\n' "${file##*/}"; done
}

affected_filter() { # repo names-file <suite paths -> the suites naming one of the names
  local repo=$1 names=$2 entry helper helpers name invariants consistency
  helpers=$(cd "$repo/tests" 2>/dev/null && for helper in *; do
    [ -f "$helper" ] || continue
    case "$helper" in test_*|e2e_*) ;; *) printf '%s\n' "$helper" ;; esac
  done)
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if grep -qxF -- "${entry##*/}" "$names"; then printf '%s\n' "$entry"; continue; fi
    local -a texts=("$entry")
    if [ -n "$helpers" ]; then
      while IFS= read -r helper; do texts+=("$repo/tests/$helper"); done < <(grep -oF -- "$helpers" "$entry" 2>/dev/null | sort -u)
    fi
    grep -qwF -f "$names" -- "${texts[@]}" 2>/dev/null && printf '%s\n' "$entry"
  done
  invariants="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/docs/shared-invariants.md"
  consistency="${invariants%/docs/*}/tests/test_consistency.sh"
  [ -r "$invariants" ] && [ -r "$consistency" ] && grep -qwF -f "$names" -- "$invariants" && printf '%s\n' "$consistency"
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
  slow=$'\n'$(<"$repo/tests/slow-suites")$'\n' edited=$'\n'$(<"$names")$'\n'
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

affected_suites() { # repo [file...] -> suite paths covering the files, sorted and unique
  local repo=$1 names suite
  local -a found=()
  shift
  names=$(mktemp "${TMPDIR:-/tmp}/affected.XXXXXX") || return 1
  affected_names "$repo" "$@" | grep -v '^$' >"$names"
  if [ -s "$names" ]; then
    while IFS= read -r suite; do found+=("$suite"); done < <(
      ls "$repo"/tests/test_*.sh "$repo"/tests/test_*.py "$repo"/tests/e2e_*.sh 2>/dev/null |
        while IFS= read -r suite; do live_suite "${suite##*/}" || printf '%s\n' "$suite"; done |
        affected_filter "$repo" "$names" | sort -u)
  fi
  slow_layer_split "$repo" "$names" ${found[@]+"${found[@]}"}
  rm -f "$names"
  [ "${#slow_kept[@]}" -eq 0 ] || printf '%s\n' "${slow_kept[@]}"
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
  affected_suites "$repo" "$@"
fi
