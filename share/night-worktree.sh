#!/usr/bin/env bash

# top night branch path: the worktree at path (under top/.claude/worktrees/) on branch, an existing
# branch reused, a new one started from refs/night/<night>/base and never HEAD; git's words on stderr.
night_worktree_add() {
  local top=$1 night=$2 branch=$3 path=$4 common reuse=false
  [ ! -e "$path/.git" ] || return 0
  common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  if git -C "$top" show-ref --verify --quiet "refs/heads/$branch"; then
    reuse=true
  elif ! git -C "$top" rev-parse -q --verify "refs/night/$night/base^{commit}" >/dev/null; then
    printf 'no refs/night/%s/base in %s: run night-run base %s first\n' "$night" "$top" "$night" >&2
    return 1
  fi
  git -C "$top" check-ignore -q "${path#"$top"/}" ||
    { mkdir -p "$common/info" && printf '.claude/worktrees/\n' >>"$common/info/exclude"; } || return 1
  mkdir -p "$top/.claude/worktrees" || return 1
  if $reuse; then
    git -C "$top" worktree add --quiet "$path" "$branch" >&2
  else
    git -C "$top" worktree add --quiet -b "$branch" "$path" "refs/night/$night/base" >&2
  fi
}

# night branch name repo...: each other repository's worktree <repo>/.claude/worktrees/night-<night>-<name>
# on branch, one path per line; a repository it cannot make one in is named on stderr and skipped.
night_sibling_worktrees() {
  local night=$1 branch=$2 name=$3 repo path err
  shift 3
  for repo in "$@"; do
    path="$repo/.claude/worktrees/night-$night-$name"
    if err=$(night_worktree_add "$repo" "$night" "$branch" "$path" 2>&1 >/dev/null); then
      printf '%s\n' "$path"
    else
      printf 'no night worktree in %s: %s\n' "$repo" "${err:-git worktree add failed}" >&2
    fi
  done
}
