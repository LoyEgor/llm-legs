#!/usr/bin/env bash
set -u

input=$(cat) || exit 0

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -e . >/dev/null 2>&1 || exit 0

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

[ "$(field '.hook_event_name')" = PreToolUse ] || exit 0
agent_type=$(field '.agent_type')
case "$agent_type" in
  codex-worker|claudeb-worker|gemini-worker|grok-worker) ;;
  # A headless claudeb run is a worker session itself, not a subagent of one, so its
  # agent_type is empty; claudeb marks it so the guard still covers it, and grokb marks a
  # headless grok run the same way.
  *) if [ "${CLAUDEB_WORKER:-}" = 1 ]; then agent_type=claudeb-headless
     elif [ "${GROK_WORKER:-}" = 1 ]; then agent_type=grok-headless
     else exit 0; fi ;;
esac

session_id=$(field '.session_id')
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
[ -n "${HOME:-}" ] || exit 0
[ -e "$HOME/.cache/claude-worker-tags/$session_id/git-unlock-$agent_type" ] && exit 0

command_text=$(field '.tool_input.command')
[ -n "$command_text" ] || exit 0

is_revert_segment() {
  local segment=$1 subcommand arg dry_run=0 other_mode=0
  local -a words

  read -r -a words <<< "$segment"
  [ "${#words[@]}" -gt 0 ] || return 1
  set -- "${words[@]}"
  if [ "$1" = command ]; then
    shift
    [ "$#" -gt 0 ] || return 1
  fi
  [ "$1" = git ] || return 1
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env)
        [ "$#" -ge 2 ] || return 1
        shift 2
        ;;
      --git-dir=*|--work-tree=*|--namespace=*|--config-env=*|-p|--paginate|-P|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
        shift
        ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || return 1
  subcommand=$1
  shift

  case "$subcommand" in
    checkout)
      local skip_next=0 saw_separator=0 remaining=0
      for arg in "$@"; do
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
        case "$arg" in
          --) saw_separator=1; continue ;;
          -b|-B|-t|--track|--orphan|--conflict) skip_next=1; continue ;;
          --track=*|--orphan=*|--conflict=*|-b?*|-B?*|-t?*) continue ;;
          -*) continue ;;
          .|HEAD|./*|../*|*.*) return 0 ;;
          *) remaining=$((remaining + 1)) ;;
        esac
      done
      [ "$saw_separator" -eq 1 ] && return 0
      [ "$remaining" -ge 2 ] && return 0
      ;;
    restore) return 0 ;;
    reset)
      for arg in "$@"; do
        [ "$arg" = --hard ] && return 0
      done
      ;;
    clean)
      for arg in "$@"; do
        case "$arg" in
          -n|--dry-run) dry_run=1 ;;
          -i|--interactive|-f|--force) other_mode=1 ;;
          -[!-]*)
            [[ "$arg" == *n* ]] && dry_run=1
            [[ "$arg" == *f* || "$arg" == *i* ]] && other_mode=1
            ;;
        esac
      done
      [ "$dry_run" -eq 1 ] && [ "$other_mode" -eq 0 ] || return 0
      ;;
    stash)
      case "${1:-}" in list|show) ;; *) return 0 ;; esac
      ;;
  esac
  return 1
}

blocked=0
while IFS= read -r segment; do
  segment=${segment#"${segment%%[![:space:]]*}"}
  if is_revert_segment "$segment"; then
    blocked=1
    break
  fi
done < <(printf '%s\n' "$command_text" | tr ';&|()' '\n')

[ "$blocked" -eq 1 ] || exit 0

jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Shared checkout: uncommitted/untracked changes you did not make this run are other agents'\'' live work, and revert-class git commands (checkout --/restore/reset --hard/clean/stash) are blocked for workers. Do not retry or work around this through other tools. Report the unexpected tree state in your OUTCOME instead — the orchestrator arbitrates. Only a '\''GIT-CLEANUP: allowed'\'' line in the brief unlocks these commands."}}' 2>/dev/null
exit 0
