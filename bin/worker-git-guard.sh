#!/usr/bin/env bash
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

IFS= read -r -d '' input || :
[ "${CLAUDEB_WORKER:-}" = 1 ] || [ "${GROK_WORKER:-}" = 1 ] ||
  case $input in *'"agent_type"'*) ;; *) exit 0 ;; esac

command -v jq >/dev/null 2>&1 || exit 0
parsed=$(jq -r '[.hook_event_name // "", .agent_type // "", .session_id // "", .tool_input.command // "",
  .cwd // ""] | @sh' <<<"$input" 2>/dev/null) || exit 0
fields=()
eval "fields=($parsed)"

[ "${fields[0]-}" = PreToolUse ] || exit 0
agent_type=${fields[1]-}
case "$agent_type" in
  codex-worker|claudeb-worker|gemini-worker|grok-worker|light-worker) ;;
  # A headless claudeb run is a worker session itself, not a subagent of one, so its
  # agent_type is empty; claudeb marks it so the guard still covers it, and grokb marks a
  # headless grok run the same way.
  *) if [ "${CLAUDEB_WORKER:-}" = 1 ]; then agent_type=claudeb-headless
     elif [ "${GROK_WORKER:-}" = 1 ]; then agent_type=grok-headless
     else exit 0; fi ;;
esac

session_id=${fields[2]-}
[[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
[ -n "${HOME:-}" ] || exit 0
[ -e "$HOME/.cache/claude-worker-tags/$session_id/git-unlock-$agent_type" ] && exit 0

command_text=${fields[3]-}
[ -n "$command_text" ] || exit 0

guard_cwd=${fields[4]-}
[ -d "$guard_cwd" ] || guard_cwd=$PWD

# A checkout operand is a path when it names something already on disk — which is exactly the
# clobber case, since only an existing file can carry another agent's uncommitted edits — or when
# it ends in a file extension. A trailing numeric component (`v1.2.3`, `release-1.0`) is a ref.
looks_like_file() {
  local name=${1##*/} extension
  case "$name" in *.*) extension=${name##*.} ;; *) return 1 ;; esac
  [ "${#extension}" -le 5 ] && [[ "$extension" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]
}

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
          # These two need no operand at all: -f re-checks-out HEAD over the whole dirty
          # worktree, -p rewrites hunks in place.
          -f|--force|-p|--patch|--ours|--theirs) return 0 ;;
          -b|-B|-t|--track|--orphan|--conflict) skip_next=1; continue ;;
          # An attached branch name (`-bfeature`) must be read before the cluster arm below, whose
          # letters would otherwise be found inside it.
          -b?*|-B?*|-t?*) continue ;;
          -[!-]*) [[ "$arg" == *f* || "$arg" == *p* ]] && return 0; continue ;;
          -*) continue ;;
          .|HEAD|./*|../*|/*) return 0 ;;
          *)
            if [ -e "$guard_cwd/$arg" ]; then return 0; fi
            # A slashed name that anchors to no local directory is a branch (`release/2.0.x`,
            # `fix/api.v2`), not a file — the dotted last segment alone must not condemn it.
            case "$arg" in
              */*) [ -d "$guard_cwd/${arg%%/*}" ] && looks_like_file "$arg" && return 0 ;;
              *) looks_like_file "$arg" && return 0 ;;
            esac
            remaining=$((remaining + 1))
            ;;
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

# A heredoc body is data unless a shell reads it; an unquoted delimiter still runs the body's
# `$( … )` and backtick spans, so those stay (share/heredoc-mask.sh). Unloadable, bodies stay whole.
heredoc_wrap='([A-Za-z_][A-Za-z0-9_]*=[^ \t]*|env|command|exec|nohup|sudo|timeout|[0-9]+|-[^ \t]*)[ \t]+'
heredoc_shell='(eval[ \t]|([^ \t]*/)?((ba|z|k|da|a)?sh)([ \t]|$))'
heredoc_bodies_cut() {
  heredoc_mask "^[ \t]*(${heredoc_wrap})*${heredoc_shell}" "[|][ \t]*(${heredoc_wrap})*${heredoc_shell}"
}

# A body the same command can later run — a script file handed to a shell, `source`, `eval`, sudo,
# `at`, a file run by its path — is not data, and nothing here can follow which file it lands in: the
# body is judged whole. Only the command's own lines say so; a body's prose saying `source` does not.
body_cut=heredoc_bodies_cut
self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) && . "${self%/*}/../share/heredoc-mask.sh" 2>/dev/null ||
  body_cut=cat
runs_written_file() {
  awk '
    function base(w) { gsub(/["\047]/, "", w); sub(/.*\//, "", w); return w }
    {
      t = $0
      while (match(t, />>?[[:space:]]*[^[:space:];&|()<>]+|(^|[^[:alnum:]_-])tee[[:space:]]+(-a[[:space:]]+)?[^[:space:];&|()<>-][^[:space:];&|()<>]*/)) {
        w = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
        sub(/.*[>[:space:]]/, "", w); wrote[base(w)] = 1
      }
      n = split($0, seg, /[;&|()`]/)
      for (i = 1; i <= n; i++) {
        s = seg[i]; sub(/^[[:space:]]+/, "", s)
        while (s ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/) sub(/^[^[:space:]]*[[:space:]]+/, "", s)
        sub(/[[:space:]].*/, "", s)
        if (s ~ /[\/$]/) run[base(s)] = 1
      }
    }
    END { for (w in run) if (w in wrote) exit 0; exit 1 }'
}
if [ "$body_cut" != cat ]; then
  cut_text=$(printf '%s\n' "$command_text" | heredoc_bodies_cut)
  grep -Eq '(^|[^[:alnum:]_.-])((ba|z|k|da|a|fi|c|tc)?sh|source|eval|xargs|sudo|exec)([^[:alnum:]_.-]|$)|(^|[;&|(`[:space:]])\.[[:space:]]|(^|[;&|(`])[[:space:]]*(at|batch)([[:space:]]|$)|\.git/hooks/' <<<"$cut_text" &&
    body_cut=cat
  [ "$body_cut" = cat ] || ! runs_written_file <<<"$cut_text" || body_cut=cat
fi
blocked=0
while IFS= read -r segment; do
  segment=${segment#"${segment%%[![:space:]]*}"}
  if is_revert_segment "$segment"; then
    blocked=1
    break
  fi
done < <(printf '%s\n' "$command_text" | "$body_cut" | tr ';&|()' '\n')

[ "$blocked" -eq 1 ] || exit 0

jq -cn --arg hook "${0##*/}" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("[" + $hook + "] " + "Shared checkout: uncommitted/untracked changes you did not make this run are other agents'\'' live work, and revert-class git commands (checkout --/restore/reset --hard/clean/stash) are blocked for workers. Do not retry or work around this through other tools. Report the unexpected tree state in your OUTCOME instead — the orchestrator arbitrates. Only a '\''GIT-CLEANUP: allowed'\'' line in the brief unlocks these commands.")}}' 2>/dev/null
exit 0
