#!/usr/bin/env bash

# Branch of a linked worktree, empty otherwise. Detached is empty: there is no branch to share.
linked_worktree_branch() { # dir
  local git_dir='' common='' branch=''
  git_dir=$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 0
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ "$git_dir" != "$common" ] || return 0
  branch=$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 0
  printf '%s\n' "$branch"
}

# A checkout of repo whose porcelain branch is refs/heads/<branch>. The main checkout counts
# when it is the one on that branch; a missing directory does not.
same_branch_worktree() { # repo branch
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
