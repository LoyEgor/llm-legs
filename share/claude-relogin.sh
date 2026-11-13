#!/usr/bin/env bash
# claude-relogin state: its lock, its cool-down stamps and the logged-out accounts it may take; sourced by
# bin/claude-relogin (writes) and bin/llm-refresh (asks before starting one). Builtins and one jq, no here-strings:
# this sits on the heartbeat path.

# The paths and the cool-down, each from its env override; the claudeb store is CLAUDEB_DIR's.
claude_relogin_dir=${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}
claude_relogin_lock=${CLAUDE_RELOGIN_LOCK:-$claude_relogin_dir/claude-relogin.lock}
claude_relogin_state=${CLAUDE_RELOGIN_STATE:-$claude_relogin_dir/claude-relogin.json}
claude_relogin_cooldown=${CLAUDE_RELOGIN_COOLDOWN_S:-21600}
[[ "$claude_relogin_cooldown" =~ ^[0-9]+$ ]] || claude_relogin_cooldown=21600

# Status 0 while a relogin holds the lock: one runs at a time, whatever its account (it owns a Chrome window and a
# Computer Use run). A lock whose pid is gone is no relogin; claude-relogin breaks it on its next start.
claude_relogin_live() {
  local pid=''
  { read -r pid <"$claude_relogin_lock/pid"; } 2>/dev/null || return 1
  [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

# Status 0 while the account's last stamp is younger than the cool-down. `attempt` counts only a real login attempt
# (what claude-relogin refuses on); `any` also counts a refusal the heartbeat must not repeat every tick
# (no-profile), so a logged-out account without a Chrome profile is asked once per cool-down, not per tick.
claude_relogin_cooling() { # account now attempt|any
  local at
  [ -r "$claude_relogin_state" ] || return 1
  at=$(jq -r --arg a "$1" --arg kind "${3:-attempt}" '
    .[$a] // {} | select($kind == "any" or (.verdict // "") != "no-profile") | .at // 0 | numbers' \
    "$claude_relogin_state" 2>/dev/null) || return 1
  [[ $at =~ ^[0-9]+$ ]] && [ $(($2 - at)) -lt "$claude_relogin_cooldown" ]
}

# The logged-out accounts, one a line: auth_needed in the account's own claudeb limits file, the flag revive and
# the keychain checks write (bin/claudeb mark_auth_needed). main and - are reserved names, never an account.
claude_relogin_wanted() {
  local file files=()
  for file in "$claude_relogin_dir"/limits/*.json; do
    [ -f "$file" ] && files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -r 'select(type == "object" and .auth_needed == true) | input_filename' "${files[@]}" 2>/dev/null |
    while IFS= read -r file; do
      file=${file##*/}
      file=${file%.json}
      case "$file" in main|-|'') ;; *) printf '%s\n' "$file" ;; esac
    done
}
