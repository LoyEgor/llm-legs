#!/usr/bin/env bash
# The account pin is Egor's own override above the pool, and a session that moves it silently
# redirects every later worker. Three modes, deliberately with no cleverness between them: `prompt`
# (UserPromptSubmit) touches a grant when HIS message names the pin, and `write` / `bash`
# (PreToolUse) deny a session moving the pin inside ~/.claude/worker-model — through Edit/Write and
# through a shell redirect alike, since a door on one of them is a door around the other. The
# command path — `claudeb|codexb|geminib use` — is refused inside worker_model_pin_account itself,
# the one chokepoint every spelling of that command reaches.
#
# What is denied is the PIN, not the file: the same file carries `worker=`, `*_model=` and
# `*_effort=`, which `/worker` rewrites directly, so a write that leaves every `*_profile=` line as
# it found it passes ungated. Reading is never gated at all.
#
# A grant only UNBLOCKS. It buys no action on its own, so none of the bookkeeping a one-shot
# permission would need has to exist. Fail-open on any error: a broken gate must never block work.
set -u

MODE="${1:-}"
GRANT_TTL_MIN="${WORKER_MODEL_PIN_TTL_MIN:-30}"
PIN_KEY_RE='^(claudeb|codex|gemini)_profile='

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

deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' \
    2>/dev/null
  exit 0
}

DENY_REASON="Blocked: the account pin (claudeb_profile / codex_profile / gemini_profile) in ~/.claude/worker-model is Egor's to move, and he has not named it here. This gate is the rule, not a suggestion — do not reach the file another way; \`claudeb|codexb|geminib use\` is refused at the same door. A per-task account belongs in the brief's ACCOUNT: line, which needs no pin. Everything else in this file — worker=, *_model=, *_effort= — is ungated, so leave the *_profile= lines exactly as they are and this same write passes. If the pin itself should move, ask him in one line and wait."

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
    fresh && exit 0
    tool=$(printf '%s' "$input" | jq -r '.tool_name') || exit 0
    if [ "$tool" = Write ]; then
      # The pin lines this write would leave behind, against the ones there now.
      pending=$(printf '%s' "$input" | jq -r '.tool_input.content // ""' | grep -E "$PIN_KEY_RE" | sort)
      [ "$pending" = "$(current_pins)" ] && exit 0
    else
      printf '%s' "$input" | jq -r '(.tool_input.old_string // "") + "\n" + (.tool_input.new_string // "")' \
        | grep -Eq '(claudeb|codex|gemini)_profile' || exit 0
    fi
    deny "$DENY_REASON"
    ;;
  bash)
    printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and .tool_name == "Bash"' \
      >/dev/null 2>&1 || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || exit 0
    # The pin file, not every name starting with it: `share/worker-model.sh` is a source file, and
    # gating commands that merely name it made ordinary work argue with this door.
    grep -Eq 'worker-model([^.[:alnum:]]|$)' <<<"$cmd" || exit 0
    # Reading it is never gated, so the deny needs the command to actually write: ANY output
    # redirection in a command that names the file, or an in-place editor / copier. The redirect is
    # matched wherever it stands rather than beside the name, because the target is routinely a
    # variable — `f=~/.claude/worker-model; printf 'codex_profile=x\n' >"$f"` names the file and
    # redirects at a word this gate cannot resolve, and matching only the literal target let it
    # straight through. The cost is a read whose OUTPUT is redirected being refused too; that is the
    # side to err on, and the reader can drop the redirect. Two things are not writes and must not
    # read as any: input redirection (`< file`, `<(...)`) feeds a reader, and `2>&1` duplicates a
    # descriptor — matching it refused every ordinary command that keeps its stderr.
    grep -Eq '>[[:space:]]*[^&[:space:]]|(^|[[:space:]|;&(])(tee|sed|perl|awk|python3?|cp|mv|rm|ln|install|truncate|dd)([[:space:]]|$)' \
      <<<"$cmd" || exit 0
    fresh && exit 0
    deny "$DENY_REASON"
    ;;
esac
exit 0
