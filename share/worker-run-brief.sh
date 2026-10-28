# worker-run, brief parsing: header lines, rounds, add-dirs, titles and language; sourced by bin/worker-run in
# place, so an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23,
# 2026-10-28).

# The header line a flag must agree with: the first `KEY: value` of the brief.
brief_line_value() { # brief key
  local line count=0 pattern="^$2:[[:space:]]*([A-Za-z0-9_.-]+)"
  while [ "$count" -lt 400 ] && { IFS= read -r line || [ -n "$line" ]; }; do
    count=$((count + 1))
    [[ $line =~ $pattern ]] || continue
    printf '%s\n' "${BASH_REMATCH[1]}"
    break
  done 2>/dev/null <"$1"
  return 0
}

brief_review_round() {
  local brief="$1" line='' round=''
  # The header is every KEY: line the brief opens with (a RESUME handle among them), and
  # ROUND: may stand after ACCOUNT:/EFFORT: there; a ROUND: past the first body line is prose.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ROUND:*) break ;;
      RESUME\ *:*) continue ;;
    esac
    [[ "$line" =~ ^[A-Z][A-Z-]*: ]] || return 0
  done <"$brief"
  case "$line" in
    ROUND:*) ;;
    *) return 0 ;;
  esac
  round=${line#ROUND:}
  round=${round#"${round%%[![:space:]]*}"}
  round=${round%"${round##*[![:space:]]}"}
  [ "$round" != none ] || { printf 'none\n'; return 0; }
  review_round_ok "$round" ||
    fail "brief names no review round on record: '$line' — the shape is 'ROUND: <review-bench run id YYYYMMDDTHHMMSSZ-<7 hex>>'"
  printf '%s\n' "$round"
}

# The run's name on its work line: the first body line past the header block, cut to 100 characters.
brief_title() { # brief
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    if [[ "${line#"${line%%[![:space:]]*}"}" =~ ^RESUME[[:space:]]+[^[:space:]]+:[[:space:]]*(.*)$ ]]; then
      line=${BASH_REMATCH[1]}
    elif [[ "$line" =~ ^[A-Z][A-Z-]*: ]]; then
      continue
    fi
    [[ "$line" =~ [^[:space:]] ]] || continue
    printf '%s\n' "$line" | perl -CSD -ne 's/^\s+|\s+$//g; print substr($_, 0, 100), "\n"'
    return 0
  done <"$1"
}

# Header-only, as ROUND: is: a brief's prose names other repositories to read far more often than to
# write, and a grant is also what exempts a write there from the doctor's escape count. The prose
# exceptions: brief_worktree_roots, as a task worktree exists to be written, and brief_checkout_roots.
brief_add_dirs() { # brief
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ADD-DIR:*)
        line=${line#ADD-DIR:}
        line=${line#"${line%%[![:space:]]*}"}
        printf '%s\n' "${line%"${line##*[![:space:]]}"}"
        continue
        ;;
      RESUME\ *:*) continue ;;
    esac
    [[ "$line" =~ ^[A-Z][A-Z-]*: ]] || return 0
  done <"$1"
}

# A named *.md is read as part of the brief (chats hand over to brief files), and
# `<repo>/.claude/worktrees/<name>` resolves in every repository the text names.
brief_text() { # brief
  local value
  cat "$1" 2>/dev/null
  grep -oE '/[A-Za-z0-9._~+/-]+\.md' "$1" 2>/dev/null | sort -u |
    while IFS= read -r value; do [ -f "$value" ] && cat "$value" 2>/dev/null; done
}

brief_worktree_roots() { # brief
  local text value name root roots='' roots_read=''
  text=$(brief_text "$1")
  {
    grep -oE '/[A-Za-z0-9._~+/-]+/\.claude/worktrees/[A-Za-z0-9._-]+' <<<"$text" | sed 's/\.*$//'
    grep -oE '(^|[^A-Za-z0-9._~+/-])[^[:space:]/]*/\.claude/worktrees/[A-Za-z0-9._-]+' <<<"$text" |
      sed 's/\.*$//' | sed 's#.*/##' | sort -u | while IFS= read -r name; do
        if [ -z "$roots_read" ]; then
          roots=$(grep -oE '/[A-Za-z0-9._~+-][A-Za-z0-9._~+/-]*' <<<"$text" | sed 's#[./]*$##' | sort -u; printf x)
          roots=${roots%x} roots_read=1
        fi
        [ -z "$roots" ] ||
          while IFS= read -r root; do
            [ -e "$root/.git" ] && printf '%s/.claude/worktrees/%s\n' "$root" "$name"
          done <<<"${roots%$'\n'}"
      done
  } | sort -u |
    while IFS= read -r value; do
      [ -e "$value/.git" ] && printf '%s\n' "$value"
    done
}

# A run working in a main checkout writes main checkouts (Egor's own-repo rule), so one its brief names
# by root, `~/` included, is granted (the W7 escapes of 2026-10-09: `Repos: <a> and <b> (main
# checkouts; commit on main in each)`). Night and fixer runs work in task worktrees: a main checkout
# their prose names, often to forbid it, stays ungranted.
brief_checkout_roots() { # brief
  local value
  brief_text "$1" | grep -oE '(^|[^A-Za-z0-9._~+/-])~?/[A-Za-z0-9._~+/-]+' | sed -E 's#^[^~/]##; s#[./]*$##' |
    sort -u | while IFS= read -r value; do
      [[ "$value" != '~/'* ]] || value=$HOME/${value#\~/}
      [[ "$value" = /?* ]] && [ -d "$value/.git" ] && (cd "$value" && pwd -P)
    done
}

# A resumed session keeps every grant its earlier runs had, workdirs included: a RESUME brief rarely
# repeats them, and its chat may pick another workdir.
resumed_add_dirs() { # resume [jq filter]
  local entry
  [ -n "$1" ] || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] && jq -r "${2:-.add_dirs[]?, .worktrees_made[]?} // empty" "${entry%/worker-session}/meta.json" 2>/dev/null
  done < <(refuse_live_matches "$1" "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}" worker-session)
}

# Every round-shaped WHOLE token of the brief, deduplicated: a longer token that merely contains a
# round id names no round, and one id repeated in the prose must not read as two rounds.
brief_text_rounds() { # brief
  # The validator's own shape, unanchored for grep -x: a second copy here drifts, which is how the
  # scan came to miss the member suffix the header and the flag both accept.
  local shape=${REVIEW_ROUND_RE#^}
  tr -c '0-9A-Za-z-' '\n' <"$1" | grep -xE "${shape%'$'}" | awk '!seen[$0]++'
}

CYRILLIC_MAX=${WORKER_RUN_CYRILLIC_MAX:-}
CYRILLIC_SHARE=${WORKER_RUN_CYRILLIC_SHARE:-$SCRIPT_DIRECTORY/cyrillic-share}

# The share alone, or nothing where the tool cannot answer: a report is never stamped on a failed
# measurement, and a brief is refused on one.
cyrillic_share() { # <stdin
  local answer
  [ -x "$CYRILLIC_SHARE" ] || return 1
  answer=$("$CYRILLIC_SHARE" 2>/dev/null) || return 1
  answer=${answer%% *}
  [[ "$answer" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$answer"
}

cyrillic_over() { # share
  [ "$1" -gt 0 ] || return 1
  [ -n "$CYRILLIC_MAX" ] || CYRILLIC_MAX=$("$CYRILLIC_SHARE" --max 2>/dev/null)
  [[ "$CYRILLIC_MAX" =~ ^[0-9]+$ ]] || CYRILLIC_MAX=0
  [ "$1" -gt "$CYRILLIC_MAX" ]
}

# The first user message of a Claude transcript, whole. Read with `first(inputs)` rather than
# `head -n1`, which would cut a multi-line brief down to its first line and match any run of the
# same task.
first_user_text() { # transcript
  jq -nRr 'first(inputs | fromjson? | select(type == "object" and .type == "user")
           | .message | objects | .content
           | if type == "string" then . else ([.[]? | select(.type? == "text") | .text] | join("")) end
           | select(. != ""))' "$1" 2>/dev/null
}
