# worker-run, review rounds and their anchors; sourced by bin/worker-run in place, so an edit here runs its
# own suites rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

REVIEW_ROUND_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7}(-[0-9]+)?$'
# git's empty blob, which is what a path the run CREATED was before it: the store reads a base to
# anchor a path it has never seen, and no base at all would leave that path's whole content owed.
EMPTY_BLOB=e69de29bb2d1d6434b8b29ae775ad8c2e48c5391

review_bench_dir() { # round
  printf '%s/benches/%s' \
    "${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}" "$1"
}

# A round is an id review-bench holds a bench for, whichever door it arrived through: the flag and
# the brief header are one answer, so no run is bound to a round that never ran.
review_round_ok() { # round
  [[ "$1" =~ $REVIEW_ROUND_RE ]] && [ -d "$(review_bench_dir "$1")" ]
}

git_common_dir() { # dir
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

# Whether repo is already granted: a worktree of it is the same repository, and granting the main
# checkout beside the worktree would hand the worker a second copy to write into.
same_repository() { # repo dir...
  local repo=$1 common dir
  shift
  common=$(git_common_dir "$repo") || common=''
  for dir in "$@"; do
    [ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$(cd "$repo" && pwd -P)" ] && return 0
    [ -n "$common" ] && [ "$(git_common_dir "$dir")" = "$common" ] && return 0
  done
  return 1
}

# The anchors store's CLI, resolved off PATH: a machine without it has no store to write to.
review_anchors() { # subcommand argument...
  local anchors args rc
  anchors=$(command -v review-anchors 2>/dev/null) && [ -x "$anchors" ] || return 127
  # A run over thousands of changed paths outgrows ARG_MAX ("Argument list too long", exit 126).
  if [ "$(printf '%s\n' "$@" | wc -c)" -gt 100000 ]; then
    args=$(mktemp "${TMPDIR:-/tmp}/review-anchors-args.XXXXXX") || return 1
    printf '%s\n' "$@" >"$args"
    "$anchors" "@$args"
    rc=$?
    rm -f "$args"
    return "$rc"
  fi
  "$anchors" "$@"
}

# The families besides the workdir's a round run may write in — its --add-dir trees — each get a
# before-listing under `families/<n>/` and a run-start of their own. Folded from the workdir alone, a
# fix that also edits them never anchors there. Outside a round nothing reads them: only the round
# fold writes their head-after, which claim requires.
snapshot_other_families() { # directory workdir launcher add-dir...
  local directory="$1" workdir="$2" launcher="$3" seen candidate common top sub n=0 branch sibling
  shift 3
  seen=$(git -C "$workdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || seen=''
  branch=$(linked_worktree_branch "$workdir")
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -d "$candidate" ] || continue
    common=$(git -C "$candidate" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
    top=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null) || continue
    [ -n "$common" ] && [ -n "$top" ] || continue
    if [ -n "$branch" ] && sibling=$(same_branch_worktree "$top" "$branch"); then top=$sibling; fi
    grep -qxF -- "$common" <<<"$seen" && continue
    seen="$seen"$'\n'"$common"
    n=$((n + 1))
    sub="$directory/families/$n"
    mkdir -p "$sub" 2>/dev/null && printf '%s\n' "$top" >"$sub/top" 2>/dev/null || continue
    snapshot_workdir "$sub" "$top" before 2>/dev/null || continue
    printf '%s\n' "$common" >"$sub/anchors-common" 2>/dev/null || :
    review_anchors run-start --repo "$top" --run "${directory##*/}" --session "$launcher" >/dev/null 2>&1 || :
  done < <(printf '%s\n' "$@")
}

# The run's transcript-named paths outside its workdir's repository that fall under TOP, top-relative.
external_top_paths() { # directory top
  local top row resolved
  top=$(cd "$2" 2>/dev/null && pwd -P) || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    resolved=$(physical_path "$row") || continue
    case "$resolved" in "$top"/*) printf '%s\n' "${resolved#"$top"/}" ;; esac
  done <"$1/files-external"
} 2>/dev/null

# One family's fold: the changed set and bases from the before/after listings in SNAP, plus what the
# run left at each path, so a fix anchor is never written over content a co-tenant moved since.
# PATHs given narrow the fold to them (a claim); otherwise a round fix owns only what the run's own
# records name, since the snapshot diff also holds every concurrent run's edits in the family.
fold_family_anchors() { # directory snap repo top launcher round [path...]
  local directory="$1" snap="$2" pairs entry base after owned='' i
  local -a fold paths bases afters only=("${@:7}")
  fold=(run-fold --repo "$3" --run "${directory##*/}" --session "$5" --round "$6" --owned)
  paths=()
  if [ "${#only[@]}" -ne 0 ]; then
    owned=$(printf '%s\n' "${only[@]}")
  else
    [ "$snap" != "$directory" ] || owned=$(listing_top_paths "$directory" "$4" "$3")
    owned+=$'\n'$(external_top_paths "$directory" "$4")
  fi
  while IFS= read -r entry; do
    [ -z "$entry" ] || fold+=("./$entry")
  done <<<"$owned"
  if pairs=$(snapshot_changed_paths "$snap" "$4" changed-rows 2>/dev/null); then
    [ "${#only[@]}" -eq 0 ] ||
      pairs=$(LC_ALL=C awk 'FILENAME != "-" { want[$0] = 1; next }
        { path = $0; sub(/^[^\t]*\t[^\t]*\t/, "", path) } path in want' <(printf '%s\n' "${only[@]}") - <<<"$pairs")
    # What each path stood at before this run: its own dirty-before blob, else the content the
    # HEAD it started from held, else nothing at all. Only a path the store has no anchor for
    # reads it, so a wrong base cannot move a path a review already knows.
    while IFS=$'\t' read -r base after entry; do
      [ -n "$entry" ] || continue
      paths+=("$entry")
      bases+=("$base")
      afters+=("$after")
    done <<<"$pairs"
    if [ "${#paths[@]}" -ne 0 ]; then
      fold+=(--changed)
      for entry in "${paths[@]}"; do
        fold+=("./$entry")
      done
      for i in "${!paths[@]}"; do
        entry=${paths[$i]} base=${bases[$i]} after=${afters[$i]}
        [ "$base" = - ] && base=$EMPTY_BLOB
        [ "$after" = - ] && after=$EMPTY_BLOB
        fold+=("--base=./$entry=$base" "--after=./$entry=$after")
      done
    fi
  fi
  review_anchors "${fold[@]}" >/dev/null 2>&1 || :
}

# What a round fixer changed, told to the anchors store from the one path that runs whatever the run's
# end was — a clean exit, a nonzero one, an operator's kill, the launch timeout. The changed set is
# the run's OWN before/after listings and never the transcript's `files`: a heredoc no
# tool call names still moved content.
# A round run's record in a family whose checkout is gone is dropped in its main checkout: left
# open, `review-anchors check` reads it as a dead run forever.
fold_gone_checkout() { # directory anchors-common-file launcher round
  local common workdir=''
  IFS= read -r common 2>/dev/null <"$2" || common=''
  case "$common" in */.git) workdir=$(git -C "${common%/.git}" rev-parse --show-toplevel 2>/dev/null) ;; esac
  [ -z "$workdir" ] ||
    review_anchors run-fold --repo "$workdir" --run "${1##*/}" --session "$3" --round "$4" --owned >/dev/null 2>&1 || :
}

fold_run_anchors() { # directory
  local directory="$1" launcher workdir top round sub
  launcher=''
  [ -f "$directory/launcher" ] && IFS= read -r launcher <"$directory/launcher"
  round=$(jq -r '.review_round // empty' "$directory/meta.json" 2>/dev/null) || round=''
  [ -n "$launcher" ] && [ -n "$round" ] || return 0
  workdir=$(jq -r '.workdir // empty' "$directory/meta.json" 2>/dev/null) || workdir=''
  [ "$workdir" != null ] || workdir=''
  top=''
  [ -z "$workdir" ] || top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || top=''
  if [ -n "$top" ] && [ ! -e "$directory/head-before" ] && [ ! -e "$directory/dirty-before-shas" ] &&
    [ ! -e "$directory/anchors-common" ]; then
    # Born during the run: nothing in it predates the run and no review anchors it.
    :
  elif [ -n "$top" ]; then
    fold_family_anchors "$directory" "$directory" "$workdir" "$top" "$launcher" "$round"
  elif [ -f "$directory/anchors-common" ]; then
    fold_gone_checkout "$directory" "$directory/anchors-common" "$launcher" "$round"
  fi
  for sub in "$directory"/families/*; do
    [ -f "$sub/top" ] || continue
    IFS= read -r top 2>/dev/null <"$sub/top" || continue
    if ! git -C "$top" rev-parse --show-toplevel >/dev/null 2>&1; then
      fold_gone_checkout "$directory" "$sub/anchors-common" "$launcher" "$round"
      continue
    fi
    [ -f "$sub/dirty-after-shas" ] || snapshot_workdir "$sub" "$top" after 2>/dev/null || :
    fold_family_anchors "$directory" "$sub" "$top" "$top" "$launcher" "$round"
  done
}
