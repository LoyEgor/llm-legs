# Web search is ONE capability with ONE table. Per vendor: the argv that turns live web search ON,
# and the argv that turns it OFF. Two cells are not argument lists:
#   `-`  the vendor's CLI already stands in that state and needs no argument
#   `!`  the vendor has no switch for that state at all — an unreachable state is refused at launch
#        when the caller asked for it, and a default nobody asked for is recorded as what it got
# An empty ON cell is a measured fact, not a gap waiting to be filled: claudeb, gemini and grok
# search by default (live probes, 2026-09-21), and codex is the only CLI that has to be asked.
# A cell is split into argv words on whitespace, so a flag taking a LIST takes it comma-joined the
# way ask_claude.sh spells it: `--disallowedTools A,B` is one word, while `A B` would reach the CLI
# as a second, positional argument — which for `claude -p` is the prompt itself.
web_search_table() {
  cat <<'TABLE'
claudeb	-	--disallowedTools WebSearch,WebFetch
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

web_search_vendors() { # [on|off] — the vendors that can reach that state, for a refusal to name
  local field=2
  [ "${1:-on}" = on ] || field=3
  web_search_table | awk -F'\t' -v field="$field" \
    '$field != "!" { printf "%s%s", separator, $1; separator = ", " } END { print "" }'
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
  local recorded vendor
  recorded=$(jq -r 'if has("web_search") then (.web_search | tostring) else "absent" end' "$1")
  case "$recorded" in
    true) printf 'on\n'; return 0 ;;
    false) printf 'off\n'; return 0 ;;
  esac
  # A run recorded before the table existed carries no state at all, and its CLI launched in the one
  # it stands in by itself: an ON cell of `-` is search already on, and reporting `off` there would
  # hand a supervisor or an --attach a capability record the answer contradicts.
  vendor=$(jq -r '.vendor // empty' "$1")
  if [ "$(web_search_column "$vendor" on 2>/dev/null)" = '-' ]; then printf 'on\n'; else printf 'off\n'; fi
}

# `WEB:` is a header line of the contiguous block at the top of a brief, the way ROUND: is — key and
# state case-insensitive. A WEB: line the header parse cannot reach (below the block, after a blank
# line, spelled `WEB : on`, or a second one) is REFUSED and never dropped: a dropped ask launches
# the run in the state nobody asked for and no reader can tell.
web_search_brief_state() { # brief — prints on|off, or nothing when the brief asks nothing;
                           # rc 2 prints the one-line refusal instead
  local brief=$1 line number=0 header=true value='' value_line=0 stray=0 state
  local loose='^[[:space:]]*[Ww][Ee][Bb][[:space:]]*:[[:space:]]*([Oo][Nn]|[Oo][Ff][Ff]|[Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[Yy][Ee][Ss]|[Nn][Oo])[[:space:]]*$'
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    if [ "$header" = true ] && [[ "$line" =~ ^[Ww][Ee][Bb]:(.*)$ ]]; then
      if [ "$value_line" -eq 0 ]; then
        value=${BASH_REMATCH[1]}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        value_line=$number
        continue
      fi
      [ "$stray" -ne 0 ] || stray=$number
      continue
    fi
    if [[ "$line" =~ $loose ]]; then
      [ "$stray" -ne 0 ] || stray=$number
    fi
    [ "$header" = true ] || continue
    case "$line" in
      RESUME\ *:* | ATTACH\ *:*) continue ;;
    esac
    [[ "$line" =~ ^[A-Z][A-Z-]*: ]] || header=false
  done <"$brief"
  if [ "$stray" -ne 0 ]; then
    printf "brief line %s spells a WEB: state worker-run does not read: the search state is one header line, 'WEB: on' or 'WEB: off', among the header lines at the very top of the brief (no blank line above it, no space before the colon, one only) — or pass --web-search / --no-web-search instead. Nothing was launched and no account was spent.\n" "$stray"
    return 2
  fi
  [ "$value_line" -ne 0 ] || return 0
  state=$(tr '[:upper:]' '[:lower:]' <<<"$value")
  case "$state" in
    on | off) printf '%s\n' "$state" ;;
    *) printf "brief header 'WEB: %s' names no state: the shape is 'WEB: on' or 'WEB: off'\n" "$value"; return 2 ;;
  esac
}

# A launcher that composes a brief out of a caller's prompt resolves the state ONCE with
# web_search_brief_state and passes it as a flag: re-embedded into a composed brief, the same header
# lands under a prefix line or a blank one, where worker-run refuses it. The leading blank lines go
# with the stripped header — a brief may not start with one.
web_search_brief_body() { # brief — its text without the WEB: header line the state was read from
  awk 'stripped != 1 && tolower($0) ~ /^web:[ \t]*(on|off)[ \t]*$/ { stripped = 1; next }
       started != 1 && $0 ~ /^[ \t]*$/ { next }
       { started = 1; print }' "$1"
}
