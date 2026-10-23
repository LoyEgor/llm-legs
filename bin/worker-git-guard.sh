#!/bin/bash
{
[ -r ~/.claude/hooks/lib/hook-time.sh ] && . ~/.claude/hooks/lib/hook-time.sh
set -u

IFS= read -r -d '' input || :
# A headless worker is a session of its own, so claudeb and grokb mark its environment.
[ "${CLAUDEB_WORKER:-}" = 1 ] || [ "${GROK_WORKER:-}" = 1 ] || exit 0
# Only a `git` segment running one of these subcommands is ever denied below, and both words stand in
# the raw payload from the command on (cwd and transcript paths come before it): a worker's ordinary
# call starts no process.
case $input in
  *'"command"'*)
    tail=${input#*'"command"'}
    [[ $tail == *git* && $tail =~ checkout|restore|reset|clean|stash ]] || exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
parsed=$(jq -r '[.hook_event_name // "", .tool_input.command // "", .cwd // ""] | @sh' <<<"$input" 2>/dev/null) || exit 0
fields=()
eval "fields=($parsed)"

[ "${fields[0]-}" = PreToolUse ] || exit 0
[ -n "${HOME:-}" ] || exit 0
# The permission is one run's: worker-run hands the worker its own run record, whose brief is the
# orchestrator's text byte for byte.
run_record=${WORKER_RUN_RECORD:-}
case "$run_record" in
  "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"/*)
    grep -Eq '^GIT-CLEANUP:[[:blank:]]*allowed' "$run_record/brief" 2>/dev/null && exit 0 ;;
esac

command_text=${fields[1]-}
[ -n "$command_text" ] || exit 0

guard_cwd=${fields[2]-}
[ -d "$guard_cwd" ] || guard_cwd=$PWD

# A checkout operand is a path when it names something already on disk — which is exactly the
# clobber case, since only an existing file can carry another agent's uncommitted edits — or when
# it ends in a file extension. A trailing numeric component (`v1.2.3`, `release-1.0`) is a ref.
looks_like_file() {
  local name=${1##*/} extension
  case "$name" in *.*) extension=${name##*.} ;; *) return 1 ;; esac
  [ "${#extension}" -le 5 ] && [[ "$extension" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]
}

is_worktree_key() {
  case "$1" in [Cc][Oo][Rr][Ee].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]=*|[Cc][Oo][Rr][Ee].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]) return 0 ;; esac
  return 1
}

is_revert_call() { # cwd program args... (one parsed command, its wrappers gone)
  local guard_cwd=$1 subcommand arg dry_run=0 other_mode=0 git_cwd=$1 other_tree=0
  shift
  [ "$#" -gt 0 ] && [ "${1##*/}" = git ] || return 1
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env)
        [ "$#" -ge 2 ] || return 1
        case "$1" in
          -C) case "$2" in /*) git_cwd=$2 ;; *) git_cwd=$git_cwd/$2 ;; esac ;;
          --git-dir|--work-tree) other_tree=1 ;;
          -c|--config-env) is_worktree_key "$2" && other_tree=1 ;;
        esac
        shift 2
        ;;
      --git-dir=*|--work-tree=*) other_tree=1; shift ;;
      --config-env=*) is_worktree_key "${1#*=}" && other_tree=1; shift ;;
      --namespace=*|-p|--paginate|-P|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
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
      local skip_next=0 saw_separator=0 remaining=0 side=0 forced=0
      local -a operands=()
      for arg in "$@"; do
        if [ "$saw_separator" -eq 1 ]; then operands+=("$arg"); continue; fi
        case "$arg" in
          --ours|--theirs) side=1 ;;
          --) saw_separator=1 ;;
          -f|--force|-p|--patch) forced=1 ;;
          -[!-]*) [[ "$arg" == *f* || "$arg" == *p* ]] && forced=1 ;;
          -*) ;;
          *) operands+=("$arg") ;;
        esac
      done
      if [ "$side" -eq 1 ]; then
        [ "$forced" -eq 0 ] && [ "$other_tree" -eq 0 ] && [ "${#operands[@]}" -gt 0 ] || return 0
        for arg in "${operands[@]}"; do
          [ -f "$git_cwd/$arg" ] && [ -n "$(git -C "$git_cwd" ls-files -u -- "$arg" 2>/dev/null)" ] || return 0
        done
        return 1
      fi
      saw_separator=0
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
      case "${1:-}" in list|show|create|-h|--help) ;; *) return 0 ;; esac
      ;;
  esac
  return 1
}

# Decided on the parsed command (claude-setup hooks/lib/argv.sh): every git the shell would run, its
# wrappers gone and its `cd`s followed, in a `-c` string or a body a shell runs too; a heredoc body is
# data. A body the same command writes to a file and then runs — by its path, a shell, `source` or
# `.` — is that file's commands, so it is read as commands too.
. "${ARGV_LIB:-$HOME/.claude/hooks/lib/argv.sh}" 2>/dev/null || exit 0
argv_parse "$command_text" "$guard_cwd"
recs=$ARGV_RECS
while IFS= read -r body; do
  argv_parse "$(jq -r . <<<"$body")" "$guard_cwd"
  recs+=$ARGV_RECS
done < <(ARGV_RECS=$recs argv_all '
  [.[] | select(.feed == null)] as $all
  | [$all[] | .redirs[] | select(.hdoc != null and (.op | test("^<<")))] as $docs
  | [$all[] | (shell_script.file // empty), (cmdv | select(.prog == "source" or .prog == "." ) | .args[0] // empty), (cmdv.path)] as $runs
  | $all[] | select(.redirs | any(.hdoc != null)) | . as $w
  | ((.redirs[] | select(.op | test("^>")) | .to), (cmdv | select(.prog == "tee") | .args[] | select(test("^-") | not))) as $t
  | select([$runs[] | select(. == $t or (. | sub(".*/"; "")) == ($t | sub(".*/"; "")))] | length > 0)
  | $w.redirs[] | select(.hdoc != null) | .hdoc | tojson' 2>/dev/null)
blocked=0
while IFS=$'\t' read -r dir words; do
  [ -n "$words" ] || continue
  printf -v dir %b "$dir"; printf -v words %b "$words" # undo @tsv's escapes, or a quote in an arg breaks the eval open
  eval "set -- $words"
  if is_revert_call "${dir:-$guard_cwd}" "$@"; then
    blocked=1
    break
  fi
done < <(ARGV_RECS=$recs argv_select 'cmdv as $c | select(($c.prog) == "git") | [(.dir // ""), ([$c.path] + $c.args | @sh)] | @tsv')

[ "$blocked" -eq 1 ] || exit 0

jq -cn --arg hook "${0##*/}" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("[" + $hook + "] " + "Shared checkout: uncommitted/untracked changes you did not make this run are other agents'\'' live work, and revert-class git commands (checkout --/restore/reset --hard/clean/stash) are blocked for workers. Do not retry or work around this through other tools. Report the unexpected tree state in your RETURN instead — the orchestrator arbitrates. Only a '\''GIT-CLEANUP: allowed'\'' line in the brief unlocks these commands.")}}' 2>/dev/null
exit 0
exit; }
