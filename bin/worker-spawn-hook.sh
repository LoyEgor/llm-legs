#!/usr/bin/env bash
# PreToolUse(Agent) for relay-worker spawns: rewrite the call's
# description to the canonical `<account> · [<model> · ]<effort>: <title>`
# form deterministically — account from the brief/router fallback, model+effort
# from the brief's MODEL:/EFFORT: lines with worker-model defaults — instead
# of trusting the orchestrating model to compose it. Fail-open: on any doubt
# leave the call untouched.
set -u

input=$(cat) || exit 0
WORKER_PICK="${WORKER_SPAWN_WORKER_PICK:-$HOME/.local/bin/worker-pick}"

field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }
hook_session=$(field '.session_id')
[ -z "$hook_session" ] || export CLAUDE_CODE_SESSION_ID="$hook_session"

[ "$(field '.hook_event_name')" = PreToolUse ] || exit 0
[ "$(field '.tool_name')" != Workflow ] || exit 0
RELAY_TYPES='claudeb-worker codex-worker gemini-worker grok-worker'
NATIVE_ALLOWLIST='fork review-waiter gemini-research image-gen'
subagent=$(field '.tool_input.subagent_type')
case " $RELAY_TYPES $NATIVE_ALLOWLIST " in
  *" ${subagent:-general-purpose} "*) ;;
  *)
    jq -cn --arg r "native ${subagent:-general-purpose} is not spawned: use a relay worker (worker-run) instead; fork and Workflow run only on Egor's word" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0 ;;
esac

description=$(field '.tool_input.description')
prompt=$(field '.tool_input.prompt')

worker_conf() { sed -n "s/^$1=//p" "$HOME/.claude/worker-model" 2>/dev/null | head -n1; }

self_dir() {
  local path=${BASH_SOURCE[0]} dir
  while [ -L "$path" ]; do
    dir=$(cd -P "$(dirname "$path")" && pwd) || return 1
    path=$(readlink "$path")
    [[ "$path" = /* ]] || path="$dir/$path"
  done
  cd -P "$(dirname "$path")" && pwd
}
SELF_DIR=$(self_dir) || SELF_DIR=''
_load_worker_model() {
  command -v worker_model_pin_first >/dev/null 2>&1 && return 0
  [ -n "$SELF_DIR" ] || return 1
  . "$SELF_DIR/../share/worker-model.sh" 2>/dev/null
}
_load_worker_model || true
image_model() { # vendor
  local model
  model=$(jq -r '.model.image // empty' "$SELF_DIR/../share/image-caps/$1.json" 2>/dev/null)
  printf '%s' "${model:-image}"
}
session_account() {
  local acct=${CLAUDE_LIMITS_ACCOUNT:-}
  if [ -z "$acct" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "$HOME/.claude" ]; then
    acct=$(basename "$CLAUDE_CONFIG_DIR")
  fi
  printf '%s' "${acct:-main}"
}
# flash38 / gemini-3.8-flash-high → 3.8-flash: the row names the model, not the table's key.
gemini_label() {
  printf '%s' "$1" | sed -E 's/^flash([0-9])([0-9])$/\1.\2-flash/; s/^gemini-([0-9.]+)-(flash|pro)(-(high|medium|low))?$/\1-\2/'
}
model_short() { # model id
  local model=${1#claude-}
  printf '%s' "${model%%-*}"
}
brief_line() { printf '%s' "$prompt" | grep -m1 -oE "^$1:[[:space:]]*[A-Za-z0-9_.-]+" | sed -E "s/^$1:[[:space:]]*//"; }
flag_account() {
  local token pattern
  pattern="--account[= ]+(\"[a-z0-9][a-z0-9-]*\"|'[a-z0-9][a-z0-9-]*'|[a-z0-9][a-z0-9-]*)"
  token=$(printf '%s' "$prompt" | grep -m1 -oE -- "$pattern" | sed -E 's/^--account[= ]+//')
  case "$token" in
    \"*\") token=${token#\"}; token=${token%\"} ;;
    \'*\') token=${token#\'}; token=${token%\'} ;;
  esac
  printf '%s' "$token"
}
route_account() {
  [ -x "$WORKER_PICK" ] || return 0
  "$WORKER_PICK" --account "$@" 2>/dev/null || true
}

codex_model_short_label() {
  local model
  model=$(worker_model_allowed_models codex | head -n1)
  printf '%s' "${model##*-}"
}

if [ "$subagent" = claudeb-worker ]; then
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account claudeb)
  [ -n "$acct" ] || acct=$(worker_model_pin_first claudeb 2>/dev/null || true)
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf claudeb_model)
  [ -n "$model" ] || model=opus
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf claudeb_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort claudeb "$(worker_model_default_model claudeb)")
  prefix="${acct:-?} · $model · $effort"
elif [ "$subagent" = codex-worker ]; then
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account codex)
  [ -n "$acct" ] || acct=$(worker_model_pin_first codex 2>/dev/null || true)
  [ -n "$acct" ] || acct=main
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf codex_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort codex "$(worker_model_default_model codex)")
  codex_model=$(brief_line MODEL)
  codex_model=${codex_model##*-}
  [ -n "$codex_model" ] || codex_model=$(codex_model_short_label)
  prefix="$acct · $codex_model · $effort"
elif [ "$subagent" = grok-worker ]; then
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account grok)
  [ -n "$acct" ] || acct=$(worker_model_pin_first grok 2>/dev/null || true)
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf grok_model)
  [ -n "$model" ] || model=auto
  # `auto` is the knob's word for "CLI default", meaningless on a menu row beside a claudeb twin
  # of the same account name — the vendor word is what tells them apart.
  case "$model" in auto|grok-4.6) model=grok ;; esac
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf grok_effort)
  [ -n "$effort" ] || effort=$(worker_model_default_effort grok "$(worker_model_default_model grok)")
  prefix="${acct:-?} · $model · $effort"
elif [ "$subagent" = image-gen ]; then
  # An image run has no effort knob: the middle segment is the vendor's image model from its
  # capability manifest and the third the vendor whose quota it spends; a `FANOUT:` brief spends
  # every vendor at once and keeps the word `image`.
  fanout=$(printf '%s' "$prompt" | grep -m1 -oE '^FANOUT:[[:space:]]*[A-Za-z,|]+' || true)
  if [ -n "$fanout" ]; then
    vendor=fanout
    acct=$(printf '%s' "$prompt" | grep -m1 -oE '^ACCOUNTS:[[:space:]]*(all|pick)' | grep -oE '(all|pick)$')
    [ "$acct" = pick ] && acct=pool
    [ -n "$acct" ] || acct=all
    media=image
  else
    vendor=$(printf '%s' "$prompt" | grep -m1 -oE '^VENDOR:[[:space:]]*(codex|gemini|grok)' |
      grep -oE '(codex|gemini|grok)$')
    [ -n "$vendor" ] || vendor=codex
    # A pin — an `ACCOUNT:` line or `--account` on the launch line — is the account for sure. Without
    # one the row predicts the router's `--role image` answer, as the research row does: the script
    # asks the same router a second later, so the two differ only under a race, and a row that
    # says `?` tells Egor nothing (2026-09-11).
    acct=$(brief_line ACCOUNT)
    [ -n "$acct" ] || acct=$(flag_account)
    [ -n "$acct" ] || acct=$(route_account "$vendor" --role image)
    [ -n "$acct" ] || acct=pool
    media=$(image_model "$vendor")
  fi
  prefix="$acct · $media · $vendor"
elif [ "$subagent" = fork ]; then
  model=$(field '.tool_input.model')
  if [ -z "$model" ]; then
    transcript=$(field '.transcript_path')
    [ ! -r "$transcript" ] || model=$(tail -n 200 "$transcript" 2>/dev/null |
      jq -rR 'fromjson? | select(type == "object" and .type == "assistant") | .message | objects | .model // empty' 2>/dev/null |
      tail -n1)
  fi
  model=$(model_short "$model")
  prefix="fork · ${model:-inherit} · $(session_account)"
elif [ "$subagent" = review-waiter ]; then
  review_run=$(printf '%s' "$prompt" | grep -m1 -oE '^(WAIT|ATTACH) [0-9]{8}T[0-9]{6}Z-[0-9a-f]+(-[0-9]+)?' |
    sed -E 's/^[A-Z]+ //')
  progress_dir="${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/progress"
  review_doc=''
  [ -z "$review_run" ] || review_doc=$(cat "$progress_dir"/*.json 2>/dev/null |
    jq -c --arg run "$review_run" 'select(.run_id? == $run)' 2>/dev/null | tail -n1)
  prefix=''
  if [ -n "$review_doc" ]; then
    prefix=$(printf '%s' "$review_doc" | jq -r 'def word(d): (if . == null then "" else tostring | gsub("[^A-Za-z0-9_.-]"; "") end) | if . == "" then d else . end;
      (if (.kind // "") == "task" or (.hunt // false) then "task" else "review" end) as $kind
      | [(.tier | word("T?")), (.composition | word("standard")), (.lens | word($kind))] | join(" · ")' 2>/dev/null)
  fi
  [ -n "$prefix" ] || prefix="review · ${review_run: -7}"
  [ -n "$review_run" ] || prefix="review · ?"
elif [ "$subagent" = gemini-research ]; then
  # The launcher takes the research model from the table's gemini default and always high effort:
  # neither is a worker-model knob. A pin answers first, then the router — with `--role research`,
  # which is the role this leg spends under: the plain query reads the workers switch and would
  # answer `off` for a vendor parked for workers alone, and a row saying nobody knows tells Egor
  # less than the account the run is about to land on.
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(flag_account)
  [ -n "$acct" ] || acct=$(route_account gemini --role research)
  [ -n "$acct" ] || acct='?'
  prefix="light research · $(gemini_label "$(worker_model_default_model gemini)") · $acct"
  seed_extra=light=research
else
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account gemini)
  [ -n "$acct" ] || acct=$(worker_model_pin_first gemini 2>/dev/null || true)
  [ -n "$acct" ] || acct=main
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf gemini_model)
  [ -n "$model" ] || model=$(worker_model_default_model gemini)
  [ "$model" = flash ] && model=flash36
  # `worker-run` raises every Gemini run to high, so the row names what will be spent rather than
  # what the brief or the knob asked for.
  effort=high
  prefix="light edit · $(gemini_label "$model") · $acct"
  seed_extra=light=edit
fi

title=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( [a-z]+)?( · [A-Za-z0-9_.?-]+){1,3}(: | — )//')
[ -n "$title" ] || title=task

session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_
pending_dir="$HOME/.cache/claude-worker-tags/$session_id"
unlock_asked=0
unlock_done=0
printf '%s' "$prompt" | grep -qE '^GIT-CLEANUP:[[:space:]]*allowed' && unlock_asked=1
# One seed per spawn: two agents of one type spawned in the same turn each claim their own, oldest
# first, instead of the second overwriting the first one's tag.
spawn_key=$(field '.tool_use_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$spawn_key" ] || spawn_key="$(date +%s)-$$-$RANDOM"
if mkdir -p "$pending_dir" 2>/dev/null; then
  umask 077
  tmp_pending="$pending_dir/.pending-$subagent.tmp.$$"
  first_line=${prompt%%$'\n'*}
  { printf '%s\n' "$prefix"; [ -z "$first_line" ] || printf 'spawn=%s\n' "$(printf '%s\n' "$first_line" | shasum -a 256 2>/dev/null | cut -c1-16)"
    [ -z "${review_run:-}" ] || printf 'review=%s\n' "$review_run"
    [ -z "${seed_extra:-}" ] || printf '%s\n' "$seed_extra"; } > "$tmp_pending" 2>/dev/null &&
    mv -f "$tmp_pending" "$pending_dir/pending-$subagent-$spawn_key" 2>/dev/null
  rm -f "$tmp_pending" 2>/dev/null
  if [ "$unlock_asked" = 1 ]; then
    git_unlock="$pending_dir/git-unlock-$subagent"
    tmp_unlock="$git_unlock.tmp.$$"
    : > "$tmp_unlock" 2>/dev/null && mv -f "$tmp_unlock" "$git_unlock" 2>/dev/null
    rm -f "$tmp_unlock" 2>/dev/null
    [ -e "$git_unlock" ] && unlock_done=1
  fi
fi
# The unlock the guard reads is a file, and a cache directory it cannot write silently voids a
# `GIT-CLEANUP: allowed` the brief demonstrably carries: the worker is then refused with "only a
# 'GIT-CLEANUP: allowed' line in the brief unlocks these commands", cannot resolve the
# contradiction, and reports a blocked task. Said in the brief instead — the one channel that
# cannot fail — so the worker knows which of the two is true before it spends the run on it.
cleanup_note=''
if [ "$unlock_asked" = 1 ] && [ "$unlock_done" = 0 ]; then
  cleanup_note="GIT-CLEANUP NOTE (hook-injected): this brief allows git cleanup, but the unlock marker under $pending_dir could not be written, so worker-git-guard.sh will still refuse revert/restore/reset/clean/stash. Do not fight it: do the rest of the task, and report in your OUTCOME that the cleanup was blocked by an unwritable ~/.cache/claude-worker-tags rather than by the brief."
fi

updated="$prefix: $title"

# Workers produce code; instruction/context .md files are curated by the orchestrator.
# Inject the guard unless the brief explicitly unlocks editing; briefs carrying their own
# MD-GUARD (a re-injection on RESUME) are left alone too.
md_guard=''
if [ "$subagent" != image-gen ] && [ "$subagent" != fork ] && [ "$subagent" != review-waiter ] &&
   ! printf '%s' "$prompt" | grep -qE '^(MD-EDIT:[[:space:]]*allowed|MD-GUARD)'; then
  md_guard="MD-GUARD (hook-injected): CLAUDE.md / CLAUDE.local.md / MEMORY.md / files in memory/ dirs / anything under ~/.claude are READ-ONLY for this task. If your change makes one of them stale, return a DOCS IMPACT note proposing the edit instead of applying it. Only an explicit 'MD-EDIT: allowed' line in the brief unlocks them. The checkout is SHARED: uncommitted or untracked changes you did not make this run are other agents' live work — never git checkout/restore/reset/clean/stash over them, whatever git status suggests about authorship; report unexpected tree state in your OUTCOME and leave it in place."
fi

[ "$updated" = "$description" ] && [ -z "$md_guard" ] && [ -z "$cleanup_note" ] && exit 0

printf '%s' "$input" | jq -c --arg description "$updated" --arg guard "$md_guard" \
  --arg cleanup "$cleanup_note" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input
      | .description = $description
      | if $guard != "" then .prompt = (.prompt + "\n\n" + $guard) else . end
      | if $cleanup != "" then .prompt = (.prompt + "\n\n" + $cleanup) else . end)
  }}
' 2>/dev/null
exit 0
