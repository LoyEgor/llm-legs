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
  codex-worker|claudeb-worker|gemini-worker|grok-worker|image-gen|gemini-research) ;;
  *) exit 0 ;;
esac

description=$(field '.tool_input.description')
prompt=$(field '.tool_input.prompt')

worker_conf() { sed -n "s/^$1=//p" "$HOME/.claude/worker-model" 2>/dev/null | head -n1; }
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

# Derive codex model short label: from ~/.codex/config.toml model id last dash-segment, fallback 'astra'.
codex_model_short_label() {
  local toml="${1:-$HOME/.codex/config.toml}" label=""
  [ -r "$toml" ] && label=$(grep -m1 '^model[[:space:]]*=' "$toml" 2>/dev/null \
    | sed 's/.*"\([^"]*\)".*/\1/; s/.*-//')
  [[ "$label" =~ ^[A-Za-z0-9]+$ ]] || label=astra
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
elif [ "$subagent" = grok-worker ]; then
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account grok)
  [ -n "$acct" ] || acct=$(worker_conf grok_profile)
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf grok_model)
  [ -n "$model" ] || model=auto
  # `auto` is the knob's word for "CLI default", meaningless on a menu row beside a claudeb twin
  # of the same account name — the vendor word is what tells them apart.
  case "$model" in auto|grok-4.6) model=grok ;; esac
  effort=$(brief_line EFFORT)
  [ -n "$effort" ] || effort=$(worker_conf grok_effort)
  [ -n "$effort" ] || effort=high
  if [ -n "$acct" ]; then prefix="$acct · $model · $effort"; else prefix="$model · $effort"; fi
elif [ "$subagent" = image-gen ]; then
  # An image run has no model or effort knob, so the middle segment is the word `image` and the
  # third is the vendor whose quota it spends — the same shape the renderer already reads.
  vendor=$(printf '%s' "$prompt" | grep -m1 -oE '^VENDOR:[[:space:]]*(codex|gemini|grok)' |
    grep -oE '(codex|gemini|grok)$')
  [ -n "$vendor" ] || vendor=codex
  # The scripts route themselves, so only a PIN is a prediction: an `ACCOUNT:` line or an
  # `--account` on the launch line names the account the run must spend, and anything else — a
  # worker-pick answer, the toggle's profile — is this hook's guess about a choice the script makes
  # a second later on its own state. A row naming an account the run never touched is worse than
  # one that says nobody knows yet.
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(flag_account)
  [ -n "$acct" ] || acct='?'
  prefix="$acct · image · $vendor"
elif [ "$subagent" = gemini-research ]; then
  # The launcher hardcodes `--model gemini-3.8-flash-high`: model and effort are fixed words here,
  # never the worker-model knobs. A pin answers first, then the router — with `--role research`,
  # which is the role this leg spends under: the plain query reads the workers switch and would
  # answer `off` for a vendor parked for workers alone, and a row saying nobody knows tells Egor
  # less than the account the run is about to land on.
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(flag_account)
  [ -n "$acct" ] || acct=$(route_account gemini --role research)
  [ -n "$acct" ] || acct='?'
  prefix="$acct · flash38 · high"
else
  acct=$(brief_line ACCOUNT)
  [ -n "$acct" ] || acct=$(route_account gemini)
  [ -n "$acct" ] || acct=$(worker_conf gemini_profile)
  [ -n "$acct" ] || acct=main
  model=$(brief_line MODEL)
  [ -n "$model" ] || model=$(worker_conf gemini_model)
  [ -n "$model" ] || model=flash38
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
unlock_asked=0
unlock_done=0
printf '%s' "$prompt" | grep -qE '^GIT-CLEANUP:[[:space:]]*allowed' && unlock_asked=1
if mkdir -p "$pending_dir" 2>/dev/null; then
  umask 077
  tmp_pending="$pending_dir/pending-$subagent.tmp.$$"
  printf '%s\n' "$prefix" > "$tmp_pending" 2>/dev/null && mv -f "$tmp_pending" "$pending_dir/pending-$subagent" 2>/dev/null
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
if [ "$subagent" != image-gen ] &&
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
