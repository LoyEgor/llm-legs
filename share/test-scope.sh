# Sourced by a test script that runs only part of itself, so bin/harness-doctor compares its time
# with its own kind of run: the statusline probe sees the script, not the env that narrowed it.
# The probe sources it too, for git_top: a marker and the probe's history row must name one repo_root.

# dir -> top (its toplevel) and root (the main checkout a linked worktree folds into), one git call.
git_top() {
  local out gitdir common
  out=$(git -C "$1" rev-parse --show-toplevel --path-format=absolute --git-dir --git-common-dir 2>/dev/null) || return 1
  top=${out%%$'\n'*} out=${out#*$'\n'}
  gitdir=${out%%$'\n'*} common=${out#*$'\n'}
  if [ "$gitdir" = "$common" ]; then root=$top; else root=${common%/*}; fi
}

# dir -> the directory its main checkout sits in, holding the sibling repositories; dir/.. outside git.
git_projects() {
  local top root
  if git_top "$1"; then printf '%s\n' "${root%/*}"; else (cd "$1/.." && pwd); fi
}

# scope [label] [dir] [start epoch]: full | all | changed | named | partial.
test_scope_mark() {
  local cache="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}" scope=$1 label="${2:-$0}" where="${3:-}" top root
  local start="${4:-${EPOCHSECONDS:-$(date +%s)}}"
  label="${label##*/}"
  label="${label%.*}"
  [ -d "$cache" ] || return 0
  [ -n "$where" ] || where=$(cd "$(dirname "${2:-$0}")" 2>/dev/null && pwd -P) || where=$PWD
  git_top "$where" || root=""
  jq -cn --argjson start "$start" --arg label "$label" --arg scope "$scope" --argjson pid "$$" \
    --arg root "$root" '{start: $start, label: $label, scope: $scope, pid: $pid}
      + (if $root == "" then {} else {repo_root: $root} end)' >> "$cache/test-scope.jsonl" 2>/dev/null || :
}

test_scope_partial() { test_scope_mark partial "${1:-$0}"; }

# file prefix: whether any <prefix>*CASE / *ONLY selector the file reads is set, 0 and empty meaning unset.
test_scope_narrowed() {
  local selector
  for selector in $(grep -Eo "$2([A-Z_]*_)?(CASE|ONLY)" "$1" | sort -u); do
    case "${!selector:-}" in ""|0) ;; *) return 0 ;; esac
  done
  return 1
}
