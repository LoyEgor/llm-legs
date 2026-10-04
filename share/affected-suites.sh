#!/usr/bin/env bash
# Suites covering changed files: a suite whose text, or a tests/ helper it names, mentions a file's
# basename; test_consistency.sh too when docs/shared-invariants.md names one. A heuristic: a suite
# that never names the file is missed. Sourced by run-suites.sh (--changed); run, it is tests/affected:
#   affected-suites.sh --repo <dir> [file...]   (no file: every file changed against HEAD or untracked)

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
    grep -qF -f "$names" -- "${texts[@]}" 2>/dev/null && printf '%s\n' "$entry"
  done
  invariants="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/docs/shared-invariants.md"
  consistency="${invariants%/docs/*}/tests/test_consistency.sh"
  [ -r "$invariants" ] && [ -r "$consistency" ] && grep -qF -f "$names" -- "$invariants" && printf '%s\n' "$consistency"
  return 0
}

affected_suites() { # repo [file...] -> suite paths covering the files, sorted and unique
  local repo=$1 names suite
  shift
  names=$(mktemp "${TMPDIR:-/tmp}/affected.XXXXXX") || return 1
  affected_names "$repo" "$@" | grep -v '^$' >"$names"
  if [ -s "$names" ]; then
    ls "$repo"/tests/test_*.sh "$repo"/tests/test_*.py "$repo"/tests/e2e_*.sh 2>/dev/null |
      while IFS= read -r suite; do live_suite "${suite##*/}" || printf '%s\n' "$suite"; done | affected_filter "$repo" "$names"
  fi | sort -u
  rm -f "$names"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  repo=''
  [ "${1:-}" != --repo ] || { repo=${2:-}; shift 2; }
  [ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'affected: no --repo and no git root here' >&2; exit 4; }
  repo=$(cd "$repo" && pwd -P) || exit 4
  [ "${1:-}" != -- ] || shift
  affected_suites "$repo" "$@"
fi
