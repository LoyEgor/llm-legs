#!/usr/bin/env bash
project_name() {
  local repo=$1 top project common owner gitdir
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)
  project=$(basename "${top:-$repo}")
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$common" ] && [ "$common" != "$gitdir" ]; then
    owner=$(basename "$(dirname "$common")")
    [ -n "$owner" ] && [ "$owner" != "$project" ] && project="$owner ⧉ $project"
  fi
  printf '%s' "$project"
}

project_name "${1:-.}"
