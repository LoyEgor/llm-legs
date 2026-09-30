#!/usr/bin/env bash

# top night branch path: the worktree at path (under top/.claude/worktrees/) on branch, an existing
# branch reused, a new one started from refs/night/<night>/base or else HEAD; git's words on stderr.
night_worktree_add() {
  local top=$1 night=$2 branch=$3 path=$4 common start=HEAD
  [ ! -e "$path/.git" ] || return 0
  common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  git -C "$top" check-ignore -q "${path#"$top"/}" ||
    { mkdir -p "$common/info" && printf '.claude/worktrees/\n' >>"$common/info/exclude"; } || return 1
  mkdir -p "$top/.claude/worktrees" || return 1
  if git -C "$top" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$top" worktree add --quiet "$path" "$branch" >&2
  else
    git -C "$top" rev-parse -q --verify "refs/night/$night/base^{commit}" >/dev/null && start="refs/night/$night/base"
    git -C "$top" worktree add --quiet -b "$branch" "$path" "$start" >&2
  fi
}
