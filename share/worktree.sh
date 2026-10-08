#!/usr/bin/env bash
# landed_keep needs share/processes.sh from the sourcing script.

worktree_main() { # repo -> its main checkout, as given when repo is one
  local common
  [ ! -d "$1/.git" ] || { printf '%s\n' "${1%/}"; return 0; }
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$common"
}

worktree_path() { # repo branch -> <main checkout>/.claude/worktrees/<branch, / -> ->
  local top
  top=$(worktree_main "$1") && printf '%s/.claude/worktrees/%s\n' "$top" "${2//\//-}"
}

# repo branch -> its worktree path: an existing branch reused, a new one started from refs/night/<night>/base
# for night/<night>/*, else from main, never HEAD; .claude/worktrees/ git-excluded first; git's words on stderr.
worktree_new() {
  local repo=$1 branch=$2 common path top night start=refs/heads/main
  git check-ref-format --branch "$branch" >/dev/null 2>&1 && [ "$branch" != main ] ||
    { printf 'no worktree branch %s: name a branch other than main\n' "$branch" >&2; return 1; }
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    { printf 'not a git repository: %s\n' "$repo" >&2; return 1; }
  top=$(worktree_main "$repo") path=$(worktree_path "$repo" "$branch")
  if [ -e "$path/.git" ]; then
    [ "$(git -C "$path" symbolic-ref -q --short HEAD)" = "$branch" ] ||
      { printf '%s exists and is not on %s\n' "$path" "$branch" >&2; return 1; }
    printf '%s\n' "$path"
    return 0
  fi
  if git -C "$top" show-ref --verify --quiet "refs/heads/$branch"; then start=''
  elif [[ $branch == night/*/* ]]; then
    night=${branch#night/} night=${night%%/*} start="refs/night/$night/base"
    git -C "$top" rev-parse -q --verify "$start^{commit}" >/dev/null ||
      { printf 'no refs/night/%s/base in %s: run night-run base %s first\n' "$night" "$top" "$night" >&2; return 1; }
  fi
  git -C "$top" check-ignore -q "${path#"$top"/}" ||
    { mkdir -p "$common/info" && printf '.claude/worktrees/\n' >>"$common/info/exclude"; } || return 1
  mkdir -p "$top/.claude/worktrees" || return 1
  if [ -z "$start" ]; then
    git -C "$top" worktree add --quiet "$path" "$branch" >&2
  else
    git -C "$top" worktree add --quiet -b "$branch" "$path" "$start" >&2
  fi || return 1
  printf '%s\n' "$path"
}

worktree_siblings() { # branch repo... -> each repository's worktree on branch, one path per line; one it cannot make is named on stderr and skipped
  local branch=$1 repo err
  shift
  for repo in "$@"; do
    if err=$(worktree_new "$repo" "$branch" 2>&1 >/dev/null); then
      worktree_path "$repo" "$branch"
    else
      printf 'no worktree in %s: %s\n' "$repo" "${err:-git worktree add failed}" >&2
    fi
  done
}

origin_refusal() { # dir hash -> why hash is not on origin main, empty when it is
  local main
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null || { printf 'commit %s is not in %s\n' "$2" "$1"; return; }
  main=$(git -C "$1" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  [ -z "$main" ] || git -C "$1" cat-file -e "$main^{commit}" 2>/dev/null || git -C "$1" fetch -q origin refs/heads/main 2>/dev/null
  [ -n "$main" ] && git -C "$1" merge-base --is-ancestor "$2" "$main" 2>/dev/null ||
    printf 'commit %s is not on origin main of %s: push it first\n' "$2" "$1"
}

push_refusal() { # dir hash night -> why hash is no pushed night commit, empty when it is one
  local why
  why=$(origin_refusal "$1" "$2")
  [ -z "$why" ] || { printf '%s\n' "$why"; return; }
  git -C "$1" rev-parse -q --verify "refs/night/$3/base^{commit}" >/dev/null ||
    { printf '%s has no refs/night/%s/base to tell a night commit by\n' "$1" "$3"; return; }
  ! git -C "$1" merge-base --is-ancestor "$2" "refs/night/$3/base" ||
    printf 'commit %s is already in refs/night/%s/base of %s: no commit of this night\n' "$2" "$3" "$1"
}

landed_keep() { # worktree -> why a landed worktree stays, status 1 when it may go
  local held
  held=$(cwd_held "$1") && { printf '%s\n' "$held"; return 0; }
  held=$(git -C "$1" ls-files -o -i --exclude-standard --directory |
    grep -vE '(^|/)(__pycache__|\.pytest_cache|node_modules|\.venv|\.DS_Store)(/|$)' | head -3 | paste -sd ' ' -)
  [ -n "$held" ] && printf 'it holds ignored files (%s)\n' "$held"
}
