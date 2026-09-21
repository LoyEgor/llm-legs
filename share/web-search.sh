# Web search is ONE capability with ONE table. Per vendor: the argv that turns live web search ON,
# and the argv that turns it OFF. Two cells are not argument lists:
#   `-`  the vendor's CLI already stands in that state and needs no argument
#   `!`  the vendor has no switch for that state at all — an unreachable ON refuses the launch, an
#        unreachable OFF means the run searches anyway and meta.json records what it really got
# An empty ON cell is a measured fact, not a gap waiting to be filled: claudeb, gemini and grok
# search by default (live probes, 2026-09-21), and codex is the only CLI that has to be asked.
web_search_table() {
  cat <<'TABLE'
claudeb	-	--disallowedTools WebSearch WebFetch
codex	-c web_search=live	-c web_search=disabled
gemini	-	!
grok	-	--disable-web-search
TABLE
}

web_search_column() { # vendor on|off — the table cell; rc 1 when the vendor has no row
  local field=2
  [ "$2" = on ] || field=3
  web_search_table | awk -F'\t' -v vendor="$1" -v field="$field" \
    '$1 == vendor { print $field; found = 1 } END { exit found ? 0 : 1 }'
}

web_search_vendors() { # the vendors that can search at all, for a refusal to name
  web_search_table | awk -F'\t' '$2 != "!" { printf "%s%s", separator, $1; separator = ", " } END { print "" }'
}

web_search_state() { # vendor requested(true|false) — the state the run really launches in
  local state=off
  [ "$2" != true ] || state=on
  [ "$state" = on ] || [ "$(web_search_column "$1" off)" != '!' ] || state=on
  printf '%s\n' "$state"
}

web_search_args() { # vendor on|off — the argv words, one per line
  local cell
  cell=$(web_search_column "$1" "$2") || return 1
  case "$cell" in - | '!') return 0 ;; esac
  # shellcheck disable=SC2086
  printf '%s\n' $cell
}

web_search_meta_state() { # meta.json — the state a supervisor must relaunch in
  [ "$(jq -r '.web_search // false' "$1")" = true ] && printf 'on\n' || printf 'off\n'
}
