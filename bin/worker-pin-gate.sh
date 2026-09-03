#!/usr/bin/env bash
# The account pin is Egor's own override above the pool, and a session that moves it silently
# redirects every later worker. Three modes, deliberately with no cleverness between them: `prompt`
# (UserPromptSubmit) touches a grant when HIS message names the pin, and `write` / `bash`
# (PreToolUse) deny a session moving the pin inside ~/.claude/worker-model — through Edit/Write and
# through a shell redirect alike, since a door on one of them is a door around the other. The
# command path — `claudeb use|codexb use|geminib use|grokb use` — is refused inside worker_model_pin_account itself,
# the one chokepoint every spelling of that command reaches.
#
# Two things are denied, not the file: the PIN, and a `*_model=` value no implementation worker may
# run (shared-invariants row `bq`) — that second one takes NO grant, since a cheap default here
# downgrades every worker after it. `worker=` and `*_effort=`, which `/worker` rewrites directly,
# are ungated, so a write leaving every `*_profile=` line as it found it and naming an allowed model
# passes. Reading is never gated at all.
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
# The `_wall` companion is part of the pin, not a separate knob: writing one by hand extends a pin
# the same way moving it does.
PIN_KEY_RE='^(claudeb|codex|gemini|grok)_profile(_wall)?='

# `~/.claude/hooks/worker-pin-gate.sh` is a symlink into the repository, so a shared module — the
# ONE allowed-model list (`share/worker-model.sh`), the ONE command splitter
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

# Unlike the pin, this one takes no grant: a cheap default here silently downgrades every worker
# after it, and no wording in a chat message makes an implementation run on a cheap model right.
deny_model() { # offending pairs
  # The list was loaded inside a command substitution, whose functions did not survive it.
  load_model_list || :
  deny "Blocked: $(tr '\n' ' ' <<<"$1" | sed 's/ $//') in ~/.claude/worker-model. Implementation workers never run a cheap model — the allowed models are $(worker_model_allowed_summary) — and \`worker-run\` refuses anything else with \`OUTCOME: MODEL_REFUSED\` before an account is spent, so storing one here only breaks the next delegation. No grant unlocks this: leave the \`*_model=\` lines as they are, and if a task really wants another model, ask Egor in one line. Effort (\`*_effort=\`) is ungated."
}

grant_path() {
  local state="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}"
  printf '%s/pin-grants/pin' "$state"
}

fresh() { [ -n "$(find "$(grant_path)" -mmin "-$GRANT_TTL_MIN" 2>/dev/null)" ]; }

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
# does not model — it reports where bytes LAND, and these leave none.
DELETE_RE='(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(rm|unlink|shred)([[:space:]]|$)'

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

DENY_REASON="Blocked: the account pin (claudeb_profile / codex_profile / gemini_profile / grok_profile) in ~/.claude/worker-model is Egor's to move, and he has not named it here. This gate is the rule, not a suggestion — do not reach the file another way; \`claudeb use|codexb use|geminib use|grokb use\` is refused at the same door. A per-task account belongs in the brief's ACCOUNT: line, which needs no pin. Everything else in this file — worker=, *_model=, *_effort= — is ungated, so leave the *_profile= lines exactly as they are and this same write passes. If the pin itself should move, ask him in one line and wait."

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0

case "$MODE" in
  prompt)
    printf '%s' "$input" | jq -e '.hook_event_name == "UserPromptSubmit"' >/dev/null 2>&1 || exit 0
    prompt=$(printf '%s' "$input" | jq -r '.prompt // empty') || exit 0
    # Both directions grant: asking for a pin and asking to drop one are the same hand on the same
    # switch. The bare noun «пин» needs a verb beside it, because it also arrives inside pasted
    # logs and diffs, and a grant handed out by quoted text is the door standing open by itself.
    # Endings are enumerated rather than swallowed by a trailing [а-яё]*, which reads «пингани» and
    # «пинать» as the pin, and the English side takes no `pinned`/`pinning`: those describe rather
    # than ask, and «в логе pinned workers to alpha» is a paste, not an instruction. Both alphabets
    # share the boundary classes — a rule that fires on pin but not on "pin" is a rule with a hole.
    open='(^|[[:space:]«"'\''(,])'
    close='([[:space:]»"'\'').,:;!?]|$)'
    verb='(сними|снять|убери|убрать|поставь|ставь|сделай|нужен|нужн[оа]|поменяй|смени)'
    grep -Eiq \
      "$open((за|от|рас)пин(ь|и|ил[аи]?|ить|им|ите|ишь)|открепи(те|ть)?|закрепи(те|ть)?)$close|$open$verb[[:space:]]+(этот[[:space:]]+)?пин(а|у|ом|е|ы|ов|ам|ами)?$close|${open}пин(а|у|ом|е|ы|ов|ам|ами)?[[:space:]]+(на|с|со|для|у)[[:space:]]|$open(un)?pins?$close|(закрепи|зафиксируй)[а-яё]*[[:space:]]+(аккаунт|акк|профил)" \
      <<<"$prompt" || exit 0
    mkdir -p "$(dirname "$(grant_path)")" 2>/dev/null || exit 0
    touch "$(grant_path)" 2>/dev/null || exit 0
    jq -cn --arg c "Egor named the account pin: moving it is unblocked for the next $GRANT_TTL_MIN minutes. Move it only if he actually asked — the pin is his override, not a routing convenience, and worker-pick already answers which account to use without one." \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
    exit 0
    ;;
  write)
    printf '%s' "$input" \
      | jq -e '.hook_event_name == "PreToolUse" and (.tool_name == "Write" or .tool_name == "Edit")' \
        >/dev/null 2>&1 || exit 0
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty') || exit 0
    [ -n "$path" ] || exit 0
    is_pin_file "$path" || exit 0
    tool=$(printf '%s' "$input" | jq -r '.tool_name') || exit 0
    # The model keys before the pin, and before the grant: an Edit is judged on what it would
    # LEAVE behind, so `old_string` naming the cheap model being removed is not the offence.
    if [ "$tool" = Write ]; then
      offending=$(disallowed_models "$(printf '%s' "$input" | jq -r '.tool_input.content // ""')")
    else
      offending=$(disallowed_models "$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""')")
    fi
    [ -z "$offending" ] || deny_model "$offending"
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
        [ -n "$name" ] && return 0
      done < <(instruction_write_targets "$1" "$PIN_NAME_RE")
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

    if targeted "$scan" || deletes "$scan"; then :
    elif { [ -n "$ambiguous" ] || travels "$scan"; } && any_write "$scan"; then :
    else exit 0
    fi
    offending=$(disallowed_models "$cmd")
    [ -z "$offending" ] || deny_model "$offending"
    fresh && exit 0
    deny "$DENY_REASON"
    ;;
esac
exit 0
