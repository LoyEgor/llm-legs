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

[ "$(field '.hook_event_name')" = PreToolUse ] || exit 0
subagent=$(field '.tool_input.subagent_type')
case "$subagent" in
  codex-worker|claudeb-worker|gemini-worker) ;;
  *) exit 0 ;;
esac

description=$(field '.tool_input.description')
prompt=$(field '.tool_input.prompt')

worker_conf() { sed -n "s/^$1=//p" "$HOME/.claude/worker-model" 2>/dev/null | head -n1; }
brief_line() { printf '%s' "$prompt" | grep -m1 -oE "^$1:[[:space:]]*[A-Za-z0-9_.-]+" | sed -E "s/^$1:[[:space:]]*//"; }
route_account() {
  [ -x "$WORKER_PICK" ] || return 0
  "$WORKER_PICK" --account "$1" 2>/dev/null || true
}

# Derive codex model short label: from ~/.codex/config.toml model id last dash-segment, fallback 'sol'.
codex_model_short_label() {
  local toml="${1:-$HOME/.codex/config.toml}" label=""
  [ -r "$toml" ] && label=$(grep -m1 '^model[[:space:]]*=' "$toml" 2>/dev/null \
    | sed 's/.*"\([^"]*\)".*/\1/; s/.*-//')
  [[ "$label" =~ ^[A-Za-z0-9]+$ ]] || label=sol
  printf '%s' "$label"
}

if [ "$subagent" = claudeb-worker ]; then
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account claudeb)
  [ -n "$acct" ] || acct=$(worker_conf claudeb_profile)
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf claudeb_model)
  [ -n "$model" ] || model=opus
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf claudeb_effort)
  [ -n "$effort" ] || effort=high
  if [ -n "$acct" ]; then prefix="$acct · $model · $effort"; else prefix="$model · $effort"; fi
elif [ "$subagent" = codex-worker ]; then
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account codex)
  [ -n "$acct" ] || acct=$(worker_conf codex_profile)
  [ -n "$acct" ] || acct=main
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf codex_effort)
  [ -n "$effort" ] || effort=medium
  codex_model=$(codex_model_short_label)
  prefix="$acct · $codex_model · $effort"
else
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account gemini)
  [ -n "$acct" ] || acct=$(worker_conf gemini_profile)
  [ -n "$acct" ] || acct=main
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf gemini_model)
  [ -n "$model" ] || model=pro
  [ "$model" = flash ] && model=flash36
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf gemini_effort)
  [ -n "$effort" ] || effort=high
  prefix="$acct · $model · $effort"
fi

title=$(printf '%s' "$description" | sed -E 's/^[A-Za-z0-9_.?-]+( · [A-Za-z0-9_.-]+){1,3}(: | — )//')
[ -n "$title" ] || title=task

session_id=$(field '.session_id' | tr -cd 'A-Za-z0-9_-')
[ -n "$session_id" ] || session_id=_
pending_dir="$HOME/.cache/claude-worker-tags/$session_id"
if mkdir -p "$pending_dir" 2>/dev/null; then
  umask 077
  tmp_pending="$pending_dir/pending-$subagent.tmp.$$"
  printf '%s\n' "$prefix" > "$tmp_pending" 2>/dev/null && mv -f "$tmp_pending" "$pending_dir/pending-$subagent" 2>/dev/null
  rm -f "$tmp_pending" 2>/dev/null
fi

updated="$prefix: $title"

# Workers produce code; instruction/context .md files are curated by the orchestrator.
# Inject the guard unless the brief explicitly unlocks editing; briefs carrying their own
# MD-GUARD (a re-injection on RESUME) are left alone too.
md_guard=''
if ! printf '%s' "$prompt" | grep -qE '^(MD-EDIT:[[:space:]]*allowed|MD-GUARD)'; then
  md_guard="MD-GUARD (hook-injected): CLAUDE.md / CLAUDE.local.md / MEMORY.md / files in memory/ dirs / anything under ~/.claude are READ-ONLY for this task. If your change makes one of them stale, return a DOCS IMPACT note proposing the edit instead of applying it. Only an explicit 'MD-EDIT: allowed' line in the brief unlocks them. The checkout is SHARED: uncommitted or untracked changes you did not make this run are other agents' live work — never git checkout/restore/reset/clean/stash over them, whatever git status suggests about authorship; report unexpected tree state in your OUTCOME and leave it in place."
fi

[ "$updated" = "$description" ] && [ -z "$md_guard" ] && exit 0

printf '%s' "$input" | jq -c --arg description "$updated" --arg guard "$md_guard" '
  {hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input
      | .description = $description
      | if $guard != "" then .prompt = (.prompt + "\n\n" + $guard) else . end)
  }}
' 2>/dev/null
exit 0
