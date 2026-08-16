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

# Quoted text a command carries is DATA, not shell syntax: a `>` or an editor's name inside quotes
# is prose being passed along — a focus prompt reading "ladder pin > roles > pool … worker-model"
# was denied outright, and this door never gates reading. Each quoted run collapses to one
# placeholder character instead of vanishing, so a redirect whose TARGET is quoted
# (`> "$HOME/.claude/worker-model"`) still reads as a redirect. Escaped characters collapse the same
# way: `\>` is a literal, and honouring the backslash also keeps an escaped quote from opening a run
# that swallows the rest of the command.
#
# The whole command is scanned as ONE string, read in by hand rather than record by record: quotes
# span newlines, and a per-record scan reset the quote state at every blank line — prose after one
# read as syntax, and a `bash` after one glued to the previous record's last word.
#
# A DOUBLE-quoted run holding `$(…)` or a backtick is not data at all: the shell runs it. There the
# strip answers with nothing and the caller falls back to the raw command — the same conservative
# side the interpreter names take, and the pre-strip gate's behaviour for it.
strip_quoted() {
  awk -v sq="'" -v dq='"' '
    BEGIN {
      cmd = ""
      while ((getline line) > 0) cmd = cmd (read_any++ ? "\n" : "") line
      quote = ""; out = ""
      for (i = 1; i <= length(cmd); i++) {
        c = substr(cmd, i, 1)
        if (quote != "") {
          if (quote == dq && c == "\\") { i++; continue }
          if (quote == dq && (c == "`" || (c == "$" && substr(cmd, i + 1, 1) == "("))) exit 2
          if (c == quote) quote = ""
          continue
        }
        if (c == "\\") { i++; out = out "Q"; continue }
        if (c == sq || c == dq) { quote = c; out = out "Q"; continue }
        out = out c
      }
      printf "%s", out
    }' <<<"$1"
}

# An interpreter is handed its program as an ARGUMENT, and that argument is quoted: every syntactic
# mark of `bash -c 'printf x > ~/.claude/worker-model'` sits inside quotes, so once one of these
# names stands outside the quotes the whole command reads as syntax again. Ambiguity denies. The
# optional path prefix is the point of the class before the names: `/bin/bash -c` and
# `/usr/bin/env sh -c` are the same interpreter as `bash`, and matching bare names only left that
# hole open. Only names that hand quoted TEXT to a parser belong here — `env`, `nohup`, `setsid`
# execute argv directly and un-quote nothing, and the standalone `.` matched `git commit .` and
# `find .`, forcing the raw scan over ordinary commands whose quoted prose then read as a write.
INTERPRETER_RE='(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(bash|sh|zsh|ksh|dash|eval|xargs|ssh|osascript|ruby|node|php)([[:space:]]|$)'
WRITE_RE='>[[:space:]]*[^&[:space:]]|(^|[[:space:]|;&(])([^[:space:]|;&()<>]*/)?(tee|sed|perl|awk|python[0-9.]*|cp|mv|rm|ln|install|truncate|dd|chmod|patch|ed|ex)([[:space:]]|$)'

# The interpreter names are matched on the STRIPPED command, so a name the quotes hide is a name
# this door cannot read: `"bash" -c '… > pin'` collapses to a placeholder and leaves neither an
# interpreter nor a redirect to match, and a variable standing there (`$SHELL -c`, `${SH} -c`,
# `$(which bash) -c`) names an interpreter this gate cannot resolve at all. A word in COMMAND
# position is an executable rather than text, so an unreadable one there means the raw command
# decides — the same conservative side ambiguity takes everywhere in this door. Command position is
# the start of a line (a newline separates commands too) or just after `;`, `|`, `&`, `(`, which is
# what keeps a placeholder among ARGUMENTS — `arm claude-opus-5 'ladder pin > pool'` — data. A
# variable followed by `/` is a path PREFIX, not the whole name (`$HOME/.claude/hooks/x.sh` is
# ordinary work, and `$HOME/bin/bash -c` already matches INTERPRETER_RE through its `/`). Residual,
# deliberately not chased: an assignment prefix moves the word out of the position matched here
# (`FOO=1 "bash" -c …`).
CMD_POSITION_RE='(^|[;|&(])[[:space:]]*(Q|\$\(|\$\{?[A-Za-z_][A-Za-z_0-9]*\}?([[:space:]]|$))'

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
    # The match runs over the command with its quoted runs collapsed — a `>` the command merely
    # carries as text writes nothing — unless an interpreter stands there to execute that text, and
    # a strip that answers with nothing falls back to the raw command rather than to a pass.
    scan=$(strip_quoted "$cmd") || scan=''
    [ -n "$scan" ] || scan="$cmd"
    ! grep -Eq "$INTERPRETER_RE" <<<"$scan" || scan="$cmd"
    ! grep -Eq "$CMD_POSITION_RE" <<<"$scan" || scan="$cmd"
    # A redirect aimed at /dev/null writes nothing anywhere, least of all the pin — and it rides
    # the exact command this gate must wave through: `cat worker-model && worker-pick 2>/dev/null`.
    # Erased before the write scan; every other redirect target still reads as a write. The target
    # must END at /dev/null — `> /dev/null.txt` is a real file and keeps its redirect — and the
    # `&>`/`>&` both-stream forms are the same discard.
    scan=$(sed -E 's,(&>>?|[0-9]*>>?&?)[[:space:]]*/dev/null([[:space:];&|)]|$),\2,g' <<<"$scan")
    grep -Eq "$WRITE_RE" <<<"$scan" || exit 0
    fresh && exit 0
    deny "$DENY_REASON"
    ;;
esac
exit 0
