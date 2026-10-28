# worker-run, `worker-run claim`; sourced by bin/worker-run in place, so an edit here runs its own suites
# rather than every suite of worker-run (Egor 2026-10-23, 2026-10-28).

# What the run's own listing is spelled against. The record's first line where it has one, since that
# is what every reader of `files` resolves its rows with; the metadata otherwise, so a run whose
# listing could not be established at all still has an anchor to check a claim against.
claim_workdir() { # directory
  local workdir
  workdir=$(sed -n 's/^WORKDIR: //p' "$1/files" 2>/dev/null | head -n1)
  [ -n "$workdir" ] || workdir=$(jq -r '.workdir // empty' "$1/meta.json" 2>/dev/null)
  [ "$workdir" != null ] || workdir=''
  printf '%s' "$workdir"
}

# Lexical, like every other path answer here: a claimed target need not still exist, and a symlink
# resolved would answer about a path the run never named. Globbing off for the split, or a `*` in a
# claimed path is answered by whatever the filesystem happens to hold beside it.
normalize_path() { # path
  local part out='' IFS=/ globbing=on
  case $- in *f*) globbing=off ;; esac
  set -f
  for part in $1; do
    case "$part" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  [ "$globbing" = off ] || set +f
  printf '%s' "${out:-/}"
}

# Claimed paths of one family, top-relative: folded as fixes only in a round.
claim_family_anchors() { # directory snap repo top launcher path...
  local directory="$1" snap="$2" repo="$3" top="$4" launcher="$5" round
  shift 5
  round=$(jq -r '.review_round // empty' "$directory/meta.json" 2>/dev/null) || round=''
  [ -z "$round" ] || fold_family_anchors "$directory" "$snap" "$repo" "$top" "$launcher" "$round" "$@"
}

# The diff is the same for every path of one snapshot. Computed in this shell: a cache set
# inside the grep pipeline would die with that subshell and the next path would rebuild it.
claim_snap() { # directory top; sets CLAIM_SNAP. Caller owns snap_dirs/snap_blobs.
  local i
  if [ "${#snap_dirs[@]}" -gt 0 ]; then
    for i in "${!snap_dirs[@]}"; do
      if [ "${snap_dirs[$i]}" = "$1" ]; then
        CLAIM_SNAP=${snap_blobs[$i]}
        return 0
      fi
    done
  fi
  CLAIM_SNAP=$(snapshot_changed_paths "$1" "$2" || true)
  snap_dirs+=("$1")
  snap_blobs+=("$CLAIM_SNAP")
}

claim_run() {
  [ "$#" -ge 1 ] || usage
  local run_id="$1" directory workdir top complete=false session launcher path absolute relative
  local sub family physical under CLAIM_SNAP=''
  local -a paths=() resolved=() elsewhere=() snap_dirs=() snap_blobs=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --complete) complete=true; shift ;;
      --paths)
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in --*) break ;; esac
          paths+=("$1"); shift
        done
        ;;
      *) usage ;;
    esac
  done
  [ "${#paths[@]}" -gt 0 ] || usage
  directory=$(run_path "$run_id")
  [ -d "$directory" ] && [ -r "$directory/meta.json" ] || fail "unknown run: $run_id"
  # A live run is still writing its own record: a claim landing mid-flight is overwritten by the next
  # `persist_run_files`, and the paths it named read back as nobody's again.
  ! run_live "$directory" ||
    fail "run $run_id is still running; claim its files once it has ended"
  session="${CLAUDE_LAUNCHER_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  launcher=$(tr -d '[:space:]' <"$directory/launcher" 2>/dev/null)
  [ -n "$launcher" ] ||
    fail "run $run_id records no launching chat, so nobody may claim its files"
  [ -n "$session" ] ||
    fail "this shell names no chat (CLAUDE_CODE_SESSION_ID), and run $run_id answers to $launcher"
  [ "$session" = "$launcher" ] ||
    fail "run $run_id was launched by $launcher, not by this chat; the launching chat is the only one that may claim its files"
  workdir=$(claim_workdir "$directory")
  [ -n "$workdir" ] || fail "run $run_id records no workdir to resolve a claim against"
  top=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null) || top=''
  # Every path is checked before any is written: a claim half applied leaves the caller unable to
  # tell which of its paths are named and which are still nobody's.
  #
  # Under the workdir, or anywhere in the REPOSITORY that workdir sits in: the dirt record this
  # claim answers is spelled against the repository top whatever directory the run was launched in,
  # so a run launched in a subdirectory has the very line `wait` prints refused whole (and the
  # listing already spells a path outside the workdir absolutely). Anything outside that
  # repository is nothing this run's records ever named.
  for path in "${paths[@]}"; do
    case "$path" in
      /*) absolute=$(normalize_path "$path") ;;
      *) absolute=$(normalize_path "$workdir/$path") ;;
    esac
    # The anchors store holds files only: a claimed directory reached `files` and was then refused
    # by the touch, leaving everything under it nobody's (live 2026-10-01, a claim-touch gap).
    [ ! -d "$absolute" ] || [ -L "$absolute" ] ||
      fail "$path is a directory; claim the files under it, one path each"
    case "$absolute" in
      "$workdir"/*) under=true ;;
      *) under=false ;;
    esac
    if [ "$under" = false ] || [ -z "$top" ]; then
      physical=$(physical_path "$absolute") || physical=$absolute
      if [ "$under" = false ] && [ -n "$top" ] && [ "$physical" != "${physical#"$top"/}" ]; then
        absolute=$physical
      else
        # A repository the run snapshotted beside its workdir (an --add-dir), or under a workdir
        # that is no repository itself: a fix it made there is claimed and folded in that family.
        family=''
        for sub in "$directory"/families/*; do
          [ -f "$sub/top" ] && [ -f "$sub/head-after" ] || continue
          IFS= read -r family 2>/dev/null <"$sub/top" || continue
          family=$(cd "$family" 2>/dev/null && pwd -P) || { family=''; continue; }
          [ "$physical" != "${physical#"$family"/}" ] && break
          family=''
        done
        if [ -n "$family" ]; then
          claim_snap "$sub" "$family"
          printf '%s\n' "$CLAIM_SNAP" | grep -qxF -- "${physical#"$family"/}" ||
            fail "$path is not in this run's snapshot diff"
          elsewhere+=("$sub"$'\t'"$family"$'\t'"$physical")
          continue
        fi
        [ "$under" = true ] ||
          fail "$path is not under this run's workdir ($workdir)${top:+, its repository ($top)} or a repository it snapshotted"
      fi
    fi
    if [ -f "$directory/head-after" ]; then
      if [ -n "$top" ]; then
        claim_snap "$directory" "$top"
        printf '%s\n' "$CLAIM_SNAP" | grep -qxF -- "${absolute#"$top"/}" ||
          fail "$path is not in this run's snapshot diff"
      else
        fail "$path is not in this run's snapshot diff"
      fi
    elif [ "$complete" != true ] &&
         ! grep -q '^PARTIAL: ' "$directory/files" 2>/dev/null; then
      fail "run $run_id has no after-snapshot; its files cannot be claimed"
    fi
    resolved+=("$absolute")
  done
  {
    if [ "$complete" = true ]; then
      grep '^WORKDIR: ' "$directory/files" 2>/dev/null
    else
      grep '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$directory/files" 2>/dev/null
    fi
    { grep -v '^WORKDIR: \|^UNKNOWN: \|^PARTIAL: ' "$directory/files" 2>/dev/null
      for absolute in ${resolved[@]+"${resolved[@]}"}; do
        relative=${absolute#"$workdir"/}
        printf '%s\n' "$relative"
      done; } | sed '/^$/d' | sort -u
  } >"$directory/files.tmp.$$" 2>/dev/null &&
    mv -f "$directory/files.tmp.$$" "$directory/files" 2>/dev/null ||
    { rm -f "$directory/files.tmp.$$" 2>/dev/null; fail "could not rewrite the listing of $run_id"; }
  # A claimed path carries an owner now, and the dirt record is exactly the set that carries none.
  if [ -n "$top" ] && [ -f "$directory/dirty" ]; then
    local remaining
    # A difference, never a symmetric one: a claimed path the dirt record never held must not be
    # ADDED to it by the very call that names it.
    remaining=$(comm -23 \
      <(grep -v '^WORKDIR: ' "$directory/dirty" 2>/dev/null | sed '/^$/d' | sort -u) \
      <(for absolute in ${resolved[@]+"${resolved[@]}"}; do
          case "$absolute" in ("$top"/*) printf '%s\n' "${absolute#"$top"/}" ;; esac
        done | sort -u))
    if [ -n "$remaining" ]; then
      { printf 'WORKDIR: %s\n' "$top"; printf '%s\n' "$remaining"; } >"$directory/dirty.tmp.$$" &&
        mv -f "$directory/dirty.tmp.$$" "$directory/dirty" 2>/dev/null ||
        rm -f "$directory/dirty.tmp.$$" 2>/dev/null
    else
      rm -f "$directory/dirty" 2>/dev/null
    fi
  fi
  if [ -n "$top" ]; then
    local -a touched=()
    for absolute in ${resolved[@]+"${resolved[@]}"}; do
      case "$absolute" in ("$top"/*) touched+=("./${absolute#"$top"/}") ;; esac
    done
    [ "${#touched[@]}" -eq 0 ] ||
      claim_family_anchors "$directory" "$directory" "$workdir" "$top" "$launcher" "${touched[@]#./}"
  fi
  if [ "${#elsewhere[@]}" -ne 0 ]; then
    local entry
    { cat "$directory/files-external" 2>/dev/null; printf '%s\n' "${elsewhere[@]##*$'\t'}"; } |
      sed '/^$/d' | sort -u >"$directory/files-external.tmp.$$" &&
      mv -f "$directory/files-external.tmp.$$" "$directory/files-external"
    for sub in "$directory"/families/*; do
      family=''
      paths=()
      for entry in "${elsewhere[@]}"; do
        [ "${entry%%$'\t'*}" = "$sub" ] || continue
        entry=${entry#*$'\t'}
        family=${entry%%$'\t'*}
        physical=${entry#*$'\t'}
        paths+=("${physical#"$family"/}")
      done
      [ -z "$family" ] || claim_family_anchors "$directory" "$sub" "$family" "$family" "$launcher" "${paths[@]}"
    done
  fi
  printf 'CLAIMED: %s path(s) for %s\nFILES:\n' "$((${#resolved[@]} + ${#elsewhere[@]}))" "$run_id"
  head -n 20 "$directory/files" 2>/dev/null
}

# Only the directories are resolved, never the last component: a claimed symlink names itself, and a
# deleted path still resolves through its deepest surviving ancestor.
physical_path() { # absolute-path
  local head="${1%/*}" tail="/${1##*/}" resolved
  while [ -n "$head" ] && [ ! -d "$head" ]; do
    tail="/${head##*/}$tail"
    head=${head%/*}
  done
  resolved=$(cd "${head:-/}" 2>/dev/null && pwd -P) || return 1
  printf '%s%s\n' "${resolved%/}" "$tail"
}
