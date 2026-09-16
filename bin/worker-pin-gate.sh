#!/usr/bin/env bash
# The account pin is Egor's own override above the pool, and a session that moves it silently
# redirects every later worker. Two modes, `write` / `bash` (PreToolUse), deny a session moving the
# pin inside ~/.claude/worker-model — through Edit/Write and through a shell redirect alike, since a
# door on one of them is a door around the other — unless HIS words granted the pin: claude-setup
# hooks/word-intake.sh writes `grant.pin`, read here through words.sh (word_gate_allow). The
# command path — `claudeb use|codexb use|geminib use|grokb use` — is refused inside worker_model_pin_account itself,
# the one chokepoint every spelling of that command reaches.
#
# A grant only UNBLOCKS. It buys no action on its own, so none of the bookkeeping a one-shot
# permission would need has to exist. Fail-open on any error: a broken gate must never block work.
#
# Threat model — and the boundary for every review of this file: the gate stops a well-meaning
# session from moving the pin by accident, never an adversary. A session trying to evade it can
# trivially succeed and that is fine — the classifier is regex-grade and stays that way. Findings
# that need an adversarial spelling to demonstrate (obfuscated paths, quoting tricks, encodings a
# regex cannot close over) are out of scope by design and are not defects, let alone P1s; the
# spellings worth closing are the ones an honest session plausibly types. False-deny is the
# acceptable side throughout.
set -u

MODE="${1:-}"
GRANT_TTL_MIN="${WORKER_MODEL_PIN_TTL_MIN:-30}"
PIN_KEY_RE='^(claudeb|codex|gemini|grok)_profile='

# `~/.claude/hooks/worker-pin-gate.sh` is a symlink into the repository, so a shared module — the
# per-model table (`share/worker-model.sh`), the ONE command splitter
# (`share/instruction-files.sh`) — is reached through the link rather than from beside the caller.
# Loaded only once a write to the pin file is already established: sourcing on every tool call
# would cost every Bash call file reads for a check almost none of them need. Unreadable → the
# check that needed it simply does not run, the same fail-open side the rest of this door takes.
load_share() { # module-file probe-function
  command -v "$2" >/dev/null 2>&1 && return 0
  local path=${BASH_SOURCE[0]} dir
  while [ -L "$path" ]; do
    dir=$(cd -P "$(dirname "$path")" && pwd) || return 1
    path=$(readlink "$path")
    [[ "$path" = /* ]] || path="$dir/$path"
  done
  dir=$(cd -P "$(dirname "$path")" && pwd) || return 1
  . "$dir/../share/$1" 2>/dev/null || return 1
  command -v "$2" >/dev/null 2>&1
}

load_model_list() { load_share worker-model.sh worker_model_allows; }

# The `*_model=` spellings in a text that name a model no implementation worker may run, one
# `<vendor>=<model>` per line. One reader for both doors: a Write's content carries them a line at
# a time and a shell command carries them inside quotes, so the pairs are matched wherever they
# stand instead of anchored to a line.
disallowed_models() { # text
  local pair vendor value
  load_model_list || return 0
  while IFS= read -r pair; do
    vendor=${pair%%_model=*}
    value=${pair#*_model=}
    worker_model_allows "$vendor" "$value" || printf '%s=%s\n' "$vendor" "$value"
  done < <(grep -Eo '(claudeb|codex|gemini|grok)_model=[A-Za-z0-9._-]+' <<<"$1" | sort -u)
}

# The SEARCH side of a substitution names the value being REPLACED, so the pairs left after this
# are the ones a command would STORE: `sed -i s/gemini_model=pro/gemini_model=flash38/` writes the
# allowed model and was refused for spelling the cheap one it removes (live 2026-09-04). The same
# reading the Edit door already takes on `old_string` — a write is judged by what it leaves behind.
# Only the `/` delimiter, which is the one a substitution over this file is typed with and the only
# one that reaches here: with the quotes already resolved, a `|` delimiter cuts the command into
# simple commands before any door reads it, and the pin's name lands in a segment with no verb.
drop_replaced() { # text → the text with each substitution's pattern emptied
  sed -E 's#(^|[^[:alnum:]_])s/[^/]*/#\1s//#g' <<<"$1"
}

disallowed_efforts() {
  local pair vendor value model model_text
  load_model_list || return 0
  model_text=${2-$(cat "$(pin_file)" 2>/dev/null)}
  while IFS= read -r pair; do
    vendor=${pair%%_effort=*}
    value=${pair#*_effort=}
    model=$(grep -Eo "${vendor}_model=[A-Za-z0-9._-]+" <<<"$model_text" | head -n1)
    model=${model#*=}
    model=${model:-$(worker_model_default_model "$vendor")}
    worker_model_effort_allowed "$vendor" "$model" "$value" ||
      printf '%s %s %s\n' "$vendor" "$model" "$value"
  done < <(grep -Eo '(claudeb|codex|gemini|grok)_effort=[A-Za-z0-9._-]+' <<<"$1" | sort -u)
}

deny_model() {
  load_model_list || :
  deny "Blocked: $(tr '\n' ' ' <<<"$1" | sed 's/ $//') in ~/.claude/worker-model. The table models are $(worker_model_allowed_summary). No grant unlocks an unlisted model; worker-run refuses it with OUTCOME: MODEL_REFUSED before an account is spent."
}

deny_effort() {
  local vendor model effort detail=''
  load_model_list || :
  while read -r vendor model effort; do
    detail="${detail}${vendor} model ${model}: effort ${effort}; allowed efforts: $(worker_model_effort_list "$vendor" "$model"). "
  done <<<"$1"
  deny "Blocked: ${detail}Effort defaults belong to the table in share/worker-model.sh; stored overrides must use its allowed efforts. No grant unlocks an unlisted effort."
}

grant_path() {
  local state="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}"
  printf '%s/pin-grants/pin' "$state"
}

# Without the words library this door keeps its older grant, the file the intake still touches for
# worker_model_pin_allowed; with it, the words store decides and an unreadable store waves it on.
fresh() { # call
  local lib=${WORDS_LIB:-$HOME/.claude/hooks/lib/words.sh} sid grant
  if [ -r "$lib" ] && . "$lib" 2>/dev/null && command -v word_gate_allow >/dev/null 2>&1; then
    sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
    word_gate_allow "$sid" pin "$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)" \
      "${1:-}" "$(pin_file)" "$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)" || return 1
    grant=$(words_grant_fresh "$sid" pin)
    case $? in
      # An unreadable store waves this door on; a door opened by a WORD= quote has no grant file to
      # read, and «воркеры на codex» — a CHAT pin — must not move the account pin through it.
      3) return 0 ;;
      0) [ "$(jq -r '.scope // empty' <<<"$grant" 2>/dev/null)" = account ]; return ;;
      1) [ "$(words_attested_scope "$sid" "${1:-}" "$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)" \
           2>/dev/null)" = account ]; return ;;
      *) return 1 ;;
    esac
  fi
  [ -n "$(find "$(grant_path)" -mmin "-$GRANT_TTL_MIN" 2>/dev/null)" ]
}

chat_pins_dir() { printf '%s' "${CHAT_PINS_DIR:-$HOME/.cache/claude-chat-pins}"; }

# The longest existing ancestor resolved, the rest kept as typed: the chat-pins dir usually does
# not exist yet, and `/var` → `/private/var` must not separate a file from its own directory.
deep_canonical() {
  local path="$1" rest=''
  case "$path" in '~') path="$HOME" ;; '~/'*) path="$HOME/${path#\~/}" ;; esac
  [[ "$path" = /* ]] || path="$PWD/$path"
  path=$(sed -E 's#/+#/#g; s#/$##' <<<"$path")
  while [ -n "$path" ] && [ ! -d "$path" ]; do
    rest="/${path##*/}$rest"
    path=${path%/*}
  done
  printf '%s%s' "$(cd -- "${path:-/}" 2>/dev/null && pwd -P)" "$rest"
}

under_chat_pins() {
  local dir
  case "$1" in *"$(basename -- "$(chat_pins_dir)")"*) ;; *) return 1 ;; esac
  dir=$(deep_canonical "$(chat_pins_dir)")
  case "$(deep_canonical "$1")" in "$dir" | "$dir"/*) return 0 ;; esac
  return 1
}

CHAT_DENY_REASON="Blocked: the chat pin under $(chat_pins_dir) is Egor's to move, and only through \`chat-pin <vendor|account|auto>\`, which checks the grant his own words wrote. Do not write, copy over or delete that file another way. If he asked for workers on a vendor or an account in this chat, run \`chat-pin\`; otherwise ask him in one line."

# The copy verbs deny on the name alone: a backup of a chat pin is a thing no session needs, and
# false-deny is this door's side.
CHAT_VERB_RE='(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(rm|unlink|shred|chmod|chown|cp|mv|ln|install|touch|truncate|tee|dd)([[:space:]]|$)'

chat_pins_written() { # command → 0 when it writes, copies over or deletes under the chat-pins dir
  local names scan segment
  names='claude-chat-pins'
  [ -z "${CHAT_PINS_DIR:-}" ] ||
    names="$names|$(basename -- "$CHAT_PINS_DIR" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  grep -Eq "$names" <<<"$1" || return 1
  load_share instruction-files.sh instruction_write_targets || return 1
  scan=$(printf '%s' "$1" | instruction_shell_scan 2>/dev/null) || scan=''
  [ -n "$scan" ] || scan=$1
  grep -Eq "$INSTRUCTION_INTERPRETER_RE|$INSTRUCTION_CMD_POSITION_RE|$PIN_LANG_RE" <<<"$scan" &&
    scan=$1
  [ -z "$(instruction_write_targets "$scan" "[^[:space:]]*($names)(/[^[:space:]]*)?")" ] || return 0
  while IFS= read -r -d '' segment; do
    grep -Eq "$names" <<<"$segment" || continue
    grep -Eq "$CHAT_VERB_RE|-i([[:space:]]|$)" <<<"$segment" && return 0
  done < <(instruction_split_commands "$scan")
  grep -Eq "[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*($names)" <<<"$scan" || return 1
  instruction_write_targets "$scan" '[^[:space:]]+' |
    awk -F '\t' '$2 != "unknown" && $4 != "" && $4 != "/dev/null" { found = 1 } END { exit !found }'
}

# `$HOME/.claude//worker-model`, a `..` hop and a tilde all name the one file; comparing the
# spelling instead of the file is a gate a session opens by typing the path differently.
canonical_path() {
  local path="$1" dir base
  case "$path" in '~') path="$HOME" ;; '~/'*) path="$HOME/${path#\~/}" ;; esac
  dir=$(dirname -- "$path") || { printf '%s' "$path"; return; }
  base=$(basename -- "$path") || { printf '%s' "$path"; return; }
  if dir=$(cd -- "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s' "$dir" "$base"
  else
    printf '%s' "$path"
  fi
}

pin_file() { canonical_path "$HOME/.claude/worker-model"; }

is_pin_file() { [ "$(canonical_path "$1")" = "$(pin_file)" ]; }

current_pins() { grep -E "$PIN_KEY_RE" "$(pin_file)" 2>/dev/null | sort; }

# The pin file as the shared write parse names it: any word whose last component is the config
# file. Coarse on purpose, as this door has always been — a session has no reason to write a
# `worker-model` anywhere, and the alternative is resolving a destination that is routinely a
# variable. A word merely ENDING in it is not it: the parse matches a destination WHOLE, which is
# what keeps `worker-model.bak` and `share/worker-model.sh` out.
PIN_NAME_RE='[^[:space:]]*worker-model'

# Deleting the file removes the pin, and deletion is the one write shape `instruction_write_targets`
# does not model — it reports where bytes LAND, and these leave none. `chmod` and `chown` are here
# for the same reason: a pin `worker-pick` can no longer read is a pin gone, whatever its bytes say.
DELETE_RE='(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(rm|unlink|shred|chmod|chown)([[:space:]]|$)'

# A language runtime hands its payload to a parser of its own, exactly as a shell does, so with the
# quoted runs resolved the payload is gone and its names go with it. The shell names are the shared
# module's (`INSTRUCTION_INTERPRETER_RE`), which stops short of these on purpose — the write gate
# reads a runtime through the interpreter SHAPES instead. This door finds its file by name and has
# to see the text, so a runtime standing in the command sends it back to the raw command too.
PIN_LANG_RE='(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(python[0-9.]*|perl|ruby|node|bun|deno|php)([[:space:]]|$)'

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' \
    2>/dev/null
  exit 0
}

DENY_REASON="Blocked: the account pin (claudeb_profile / codex_profile / gemini_profile / grok_profile) in ~/.claude/worker-model is Egor's to move, and he has not named it here. This gate is the rule, not a suggestion — do not reach the file another way; \`claudeb use|codexb use|geminib use|grokb use\` is refused at the same door. A per-task account belongs in the brief's ACCOUNT: line, which needs no pin. Edit/Write may change non-pin fields while preserving every pin line. Bash permits only the two literal worker/effort substitutions documented in shared-invariants row ae; other shell writes, including model replacements, require a pin grant. If the pin itself should move, ask him in one line and wait."

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0

case "$MODE" in
  write)
    printf '%s' "$input" \
      | jq -e '.hook_event_name == "PreToolUse" and (.tool_name == "Write" or .tool_name == "Edit")' \
        >/dev/null 2>&1 || exit 0
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty') || exit 0
    [ -n "$path" ] || exit 0
    ! under_chat_pins "$path" || deny "$CHAT_DENY_REASON"
    is_pin_file "$path" || exit 0
    tool=$(printf '%s' "$input" | jq -r '.tool_name') || exit 0
    if [ "$tool" = Write ]; then
      pending=$(printf '%s' "$input" | jq -r '.tool_input.content // ""')
      model_text=$pending
    else
      pending=$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')
      model_text=$(printf '%s' "$input" | jq -r --arg current "$(cat "$(pin_file)" 2>/dev/null)" '
        .tool_input as $edit | ($edit.old_string // "") as $old |
        if $old == "" then $current + "\n" + ($edit.new_string // "")
        elif $edit.replace_all then $current | split($old) | join($edit.new_string // "")
        else ($current | index($old)) as $at |
          if $at == null then $current + "\n" + ($edit.new_string // "")
          else $current[:$at] + ($edit.new_string // "") + $current[$at + ($old | length):] end
        end')
    fi
    offending=$(disallowed_models "$pending")
    [ -z "$offending" ] || deny_model "$offending"
    offending=$(disallowed_efforts "$pending" "$model_text")
    [ -z "$offending" ] || deny_effort "$offending"
    fresh && exit 0
    if [ "$tool" = Write ]; then
      # The pin lines this write would leave behind, against the ones there now.
      pending=$(printf '%s' "$input" | jq -r '.tool_input.content // ""' | grep -E "$PIN_KEY_RE" | sort)
      [ "$pending" = "$(current_pins)" ] && exit 0
    else
      printf '%s' "$input" | jq -r '(.tool_input.old_string // "") + "\n" + (.tool_input.new_string // "")' \
        | grep -Eq '(claudeb|codex|gemini|grok)_profile' || exit 0
    fi
    deny "$DENY_REASON"
    ;;
  bash)
    printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and .tool_name == "Bash"' \
      >/dev/null 2>&1 || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || exit 0
    ! chat_pins_written "$cmd" || deny "$CHAT_DENY_REASON"
    # The pin file, not every name starting with it: `share/worker-model.sh` is a source file, and
    # gating commands that merely name it made ordinary work argue with this door. Cheap and on the
    # raw text, so the shared module is read only for a command that could be about the pin at all;
    # unreadable, the check that needed it does not run and the two tool doors still stand.
    grep -Eq 'worker-model([^.[:alnum:]]|$)' <<<"$cmd" || exit 0
    load_share instruction-files.sh instruction_write_targets || exit 0
    row_sep=$(printf '\t')

    # WHAT THE COMMAND IS, with its data taken out: heredoc bodies dropped and quoted runs resolved
    # by the shared parse (`instruction_shell_scan`), the one the instruction write gate reads a
    # command with. A brief written into a scratch file names the pin, quotes `*_profile=` and
    # spells Egor's rules with apostrophes and Russian, and every one of those was refused as a pin
    # move (live 2026-09-02/03) by a door that read carried text as syntax.
    #
    # It goes back to being syntax where something would EXECUTE it: a shell interpreter, a language
    # runtime, or a command-position word this parse cannot resolve (`$SHELL -c`, `"bash" -c`).
    # There the raw command decides, which is this door's conservative side.
    scan=$(printf '%s' "$cmd" | instruction_shell_scan 2>/dev/null) || scan=''
    [ -n "$scan" ] || scan="$cmd"
    ambiguous=''
    if grep -Eq "$INSTRUCTION_INTERPRETER_RE|$INSTRUCTION_CMD_POSITION_RE|$PIN_LANG_RE" <<<"$scan"; then
      scan="$cmd"
      ambiguous=1
    fi

    # A write whose destination the shared parse can NAME, judged against the pin alone: `cat pin >
    # /tmp/out` and `worker-pick > /tmp/pick.txt` leave their bytes elsewhere, and refusing them
    # gated the read CLAUDE.md prescribes before every delegation. Every row kind counts, unlike the
    # instruction gate's redirect-and-tee subset — a copy over the pin and a runtime that opens it
    # are pin moves too.
    targeted() { # text → 0 when a write in it lands in the pin file
      local kind mode verb name
      while IFS="$row_sep" read -r kind mode verb name; do
        [ -n "$name" ] || continue
        # A copy row is a guess about the destination, decided below instead.
        [ "$kind" = copy ] && continue
        return 0
      done < <(instruction_write_targets "$1" "$PIN_NAME_RE")
      copies_onto_pin "$1"
    }
    # `cp/mv/ln/install` name their DESTINATION last, and the shared parse cannot say which operand
    # it read: for `cp <pin> /tmp/backup` it also emits `/tmp/backup/worker-model`, where a copy
    # INTO a directory would land, and this door read a BACKUP of the pin as a write over it. So the
    # copy verbs are decided from the last operand, resolved the way the shell would resolve it: a
    # `~` expanded, a destination that IS a directory taking each source's own name. A destination
    # this cannot name — a variable, a substitution — falls back to the by-name rule above, which is
    # the conservative side and the one `cp x $(dirname …)/worker-model` is caught by. `-t DIR` /
    # `--target-directory=DIR` is that destination when present; trailing options and redirections
    # are not.
    copies_onto_pin() { # text → 0 when a copy verb in it writes over or removes the pin
      local segment words nw vi i verb dest src nops tdest w skip saw_dd
      local -a operands srcs
      while IFS= read -r -d '' segment; do
        [ -n "${segment//[[:space:]]/}" ] || continue
        words=()
        read -ra words <<<"$segment"
        nw=${#words[@]}
        [ "$nw" -ge 3 ] || continue
        verb='' vi=0
        for ((i = 0; i < nw; i++)); do
          case "${words[i]##*/}" in
            cp|mv|ln|install) verb=${words[i]##*/} vi=$i; break ;;
          esac
        done
        [ -n "$verb" ] || continue
        operands=()
        tdest=''
        saw_dd=0
        for ((i = vi + 1; i < nw; i++)); do
          w=${words[i]}
          skip=0
          case "$w" in
            '>'|'>>'|'>|'|'<'|'<<'|'<<-'|'<<<'|'<>'|'>&'|'<&'|'&>'|'&>>') skip=2 ;;
          esac
          if [ "$skip" -eq 0 ] && [[ "$w" =~ ^[0-9]+(>>?|>\||<<-?|<>|&[<>]|[<>]&|[<>])$ ]]; then
            skip=2
          fi
          if [ "$skip" -eq 0 ] && [[ "$w" =~ ^([0-9]+|&)?(>>?|>\||<<-?|<>|&[<>]|[<>]&|[<>]).+ ]]; then
            skip=1
          fi
          if [ "$skip" -gt 0 ]; then
            [ "$skip" -eq 2 ] && [ $((i + 1)) -lt "$nw" ] && i=$((i + 1))
            continue
          fi
          if [ "$saw_dd" -eq 1 ]; then
            operands+=("$w")
            continue
          fi
          case "$w" in
            --) saw_dd=1; continue ;;
            -) operands+=("$w"); continue ;;
            -t|--target-directory)
              [ $((i + 1)) -lt "$nw" ] || continue
              i=$((i + 1))
              tdest=${words[i]}
              continue
              ;;
            --target-directory=*)
              tdest=${w#--target-directory=}
              continue
              ;;
            -m|--mode|-g|--group|-o|--owner|-S|--suffix)
              [ $((i + 1)) -lt "$nw" ] && i=$((i + 1))
              continue
              ;;
            --mode=*|--group=*|--owner=*|--suffix=*) continue ;;
            -*) continue ;;
          esac
          operands+=("$w")
        done
        nops=${#operands[@]}
        srcs=()
        if [ -n "$tdest" ]; then
          [ "$nops" -ge 1 ] || continue
          dest=$tdest
          srcs=("${operands[@]}")
        else
          [ "$nops" -ge 2 ] || continue
          # Last operand, not last word: `>/dev/null` or `-f` as dest lets the copy through.
          dest=${operands[nops - 1]}
          for ((i = 0; i < nops - 1; i++)); do
            srcs+=("${operands[i]}")
          done
        fi
        case "$dest" in
          *'$'* | *'`'*) [[ "$dest" =~ ^${PIN_NAME_RE}$ ]] && return 0; continue ;;
        esac
        if [ "${dest%/}" != "$dest" ] || [ -d "$(canonical_path "${dest%/}")" ]; then
          for ((i = 0; i < ${#srcs[@]}; i++)); do
            src=${srcs[i]##*/}
            [ -n "$src" ] && is_pin_file "${dest%/}/$src" && return 0
          done
        else
          is_pin_file "$dest" && return 0
        fi
        # A `mv` takes the pin AWAY, and a pin that left the file is a pin removed.
        if [ "$verb" = mv ]; then
          for ((i = 0; i < ${#srcs[@]}; i++)); do
            is_pin_file "${srcs[i]}" && return 0
          done
        fi
      done < <(instruction_split_commands "$1")
      return 1
    }
    # Deletion, per simple command: the verb has to stand in the same command as the name, or
    # `cat pin; rm -rf "$tmp"` reads one file and removes another.
    deletes() { # text → 0 when a simple command in it removes the pin file
      local segment
      while IFS= read -r -d '' segment; do
        grep -Eq "(^|[[:space:]])$PIN_NAME_RE([[:space:]]|\$)" <<<"$segment" || continue
        grep -Eq "$DELETE_RE" <<<"$segment" && return 0
      done < <(instruction_split_commands "$1")
      return 1
    }
    # ANY write at all, wherever it lands: the answer for a command whose destination cannot be
    # named — the pin's path captured into a variable, or a raw command something in it executes.
    # A `/dev/null` row writes nothing anywhere, least of all the pin, and it rides the exact
    # command this gate must wave through (`cat worker-model >/dev/null; worker-pick`). A loose
    # runtime row is not a destination at all — the shared parse emits one for every name standing
    # near a `python3 -c`, and reading those as writes refused a pin read with a one-liner beside it.
    any_write() { # text → 0 when it carries a write of its own
      local kind mode verb name
      while IFS="$row_sep" read -r kind mode verb name; do
        [ "$mode" = unknown ] && continue
        case "$name" in ''|/dev/null) continue ;; esac
        return 0
      done < <(instruction_write_targets "$1" '[^[:space:]]+')
      grep -Eq "$DELETE_RE" <<<"$1"
    }
    # The name travels out of its own command in three shapes and only these: captured into a
    # variable (`f=~/.claude/worker-model`), computed in a substitution
    # (`p="$(readlink -f …worker-model)"`, `cp x $(dirname …worker-model)/worker-model`), or bound
    # by a loop or a `read`. A loop naming something ELSE is not one of them: a `for` anywhere in
    # the command used to send the whole thing to the raw scan, and a walk over two repositories
    # beside the pin read was refused for a redirect of its own (live 2026-09-03).
    travels() { # text → 0 when the pin's name may reach a write in another command
      grep -Eq "[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*worker-model|\\\$\\([^)]*worker-model|(^|[;&|(])[[:space:]]*(for|while|read)[[:space:]][^;&|]*worker-model" <<<"$1"
    }

    pin_untouched_write() {
      local home_re path_re key_re inplace_re temporary_re
      home_re=$(printf '%s' "$HOME" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
      path_re="(~|\\\$HOME|$home_re)/\\.claude/worker-model"
      key_re='(worker|codex_effort|claudeb_effort|gemini_effort|grok_effort)'
      inplace_re="^sed -i '' 's/\^${key_re}=\.\*/${key_re}=[a-z0-9]+/' ${path_re}$"
      temporary_re="^([A-Za-z_][A-Za-z0-9_]*)=${path_re}; sed 's/\^${key_re}=\.\*/${key_re}=[a-z0-9]+/' \"\\\$([A-Za-z_][A-Za-z0-9_]*)\" > \"\\\$([A-Za-z_][A-Za-z0-9_]*)\.tmp\.\\\$\\\$\" && mv -f \"\\\$([A-Za-z_][A-Za-z0-9_]*)\.tmp\.\\\$\\\$\" \"\\\$([A-Za-z_][A-Za-z0-9_]*)\"$"
      if [[ "$1" =~ $inplace_re ]]; then
        [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
      elif [[ "$1" =~ $temporary_re ]]; then
        [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[4]}" ] &&
          [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[5]}" ] &&
          [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[6]}" ] &&
          [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[7]}" ] &&
          [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[8]}" ]
      else
        return 1
      fi
    }

    if targeted "$scan" || deletes "$scan"; then :
    elif { [ -n "$ambiguous" ] || travels "$scan"; } && any_write "$scan"; then :
    else exit 0
    fi
    # The scan, not the raw command: a `*_model=` pair the command CARRIES — quoted in a brief, or
    # standing on the search side of a substitution — is not one it stores.
    pending=$(drop_replaced "$scan")
    offending=$(disallowed_models "$pending")
    [ -z "$offending" ] || deny_model "$offending"
    offending=$(disallowed_efforts "$pending" "$pending
$(cat "$(pin_file)" 2>/dev/null)")
    [ -z "$offending" ] || deny_effort "$offending"
    # The raw command, and only while nothing in it is a runtime: matched around one, the shape is
    # a guess, and a guess is exactly what may not open this door.
    if [ -z "$ambiguous" ] && pin_untouched_write "$cmd"; then exit 0; fi
    fresh "$(jq -r '.tool_use_id // empty' <<<"$input" 2>/dev/null)" && exit 0
    deny "$DENY_REASON"
    ;;
esac
exit 0
