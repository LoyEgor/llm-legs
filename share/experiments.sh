# Active-experiment surfacing (registry: EXPERIMENTS.json; rules: the `experiment` skill).
#
# An experiment inside its review window stays OFF the banner (the owner reads these surfaces
# daily and an "until" line he cannot act on is noise; the affected sites announce themselves) —
# the banner's job is the OVERDUE line that forces a decision. Past its review date an entry is
# OVERDUE whatever its marker says: one that ended by itself still waits for the owner's word, and
# only removing the entry silences it. An experiment with no review date cannot ever become
# overdue, so it keeps announcing while its marker is live.

experiments_registry_path() {
  printf '%s\n' "${EXPERIMENTS_REGISTRY:-$1/EXPERIMENTS.json}"
}

# The banner's lines alone, for text surfaces.
experiments_active_lines() {
  local row
  while IFS= read -r row; do printf '%s\n' "${row#*$'\t'}"; done < <(experiments_active_rows "$1")
}

# One `<chat session id>\t<line>` row per announced experiment: the chat that set it up is where
# its verdict gets decided, so every surface that can open a chat offers it (empty when unknown).
experiments_active_rows() {
  local registry="$1" today="${EXPERIMENTS_TODAY_OVERRIDE:-$(date '+%Y-%m-%d')}" line rest id review marker chat home
  [ -e "$registry" ] || return 0
  # A stray comma must not read as "no experiments running": say the registry is unreadable.
  if ! jq -e 'type == "array"' "$registry" >/dev/null 2>&1; then
    printf '\tEXPERIMENT registry unreadable (%s) — cannot tell whether a trial is live\n' "$registry"
    return 0
  fi
  home="${HOME:-}"
  # Manual tab splitting: `IFS=$'\t' read` collapses adjacent tabs, so an empty
  # review_by would shift the marker path into the review field.
  while IFS= read -r line; do
    id=${line%%$'\t'*}; rest=${line#*$'\t'}
    review=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    marker=${rest%%$'\t'*}; chat=${rest#*$'\t'}
    [ -n "$id" ] || continue
    if [ -n "$review" ]; then
      if [ "$review" \< "$today" ]; then
        printf '%s\tEXPERIMENT %s OVERDUE since %s — decide: remove or extend (EXPERIMENTS.json)\n' "$chat" "$id" "$review"
      fi
      continue
    fi
    if [ -n "$marker" ]; then
      case "$marker" in "~/"*) marker="$home/${marker#\~/}" ;; esac
      experiments_marker_live "$marker" || continue
    fi
    printf '%s\tEXPERIMENT %s — temporary, see EXPERIMENTS.json\n' "$chat" "$id"
  done < <(jq -r '.[]? | [(.id // ""), (.review_by // ""), (.state_marker // ""), (.chat // "")] | @tsv' "$registry" 2>/dev/null)
}

# Liveness is decided by jq, not by a digit pattern: `-1` and `1.5` are numbers too, and a
# bash digit test would treat both as "no deadline" and keep announcing a spent experiment.
# A marker with no numeric `until` at all is live while the file exists.
experiments_marker_live() {
  local marker="$1"
  [ -e "$marker" ] || return 1
  jq -e --argjson now "$(date +%s)" '
    if (.until? | type) == "number" then .until > $now else true end' "$marker" >/dev/null 2>&1 && return 0
  # Unparseable marker: the switch it drives may well be active, so keep announcing.
  jq -e 'type == "object"' "$marker" >/dev/null 2>&1 || return 0
  return 1
}
