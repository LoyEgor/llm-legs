#!/usr/bin/env bash
# token_journal: the append-only OAuth evidence journal (token-attempts.jsonl) every Claude token verdict reaches;
# sourced by bin/claudeb and bin/claude-relogin. The caller may set base_dir and token_attempts_file; both default
# to the claudeb store (CLAUDEB_DIR). limit_hit (share/limit-hit.sh) reports a dropped generation when loaded.

# Append-only evidence of every token-endpoint-relevant event (real attempts and
# their outcomes, warm outcomes, adoptions, robot skips, relogins). Single-line O_APPEND
# writes stay atomic under PIPE_BUF, so no lock; a failed write never breaks a
# refresh path. `user` is bin/claudeb's user_refresh_explicit (shared-invariants f), asked
# only where that predicate exists: no other caller runs an invocation the user asked for.
token_journal() {
  local account="$1" kind="$2" outcome="$3" http="${4:-}" ts line sz max_bytes user=false
  local dir="${base_dir:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}}" file
  file="${token_attempts_file:-$dir/token-attempts.jsonl}"
  if declare -F user_refresh_explicit >/dev/null && user_refresh_explicit; then user=true; fi
  ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) || ts=''
  line=$(jq -cn --arg ts "$ts" --arg account "$account" --arg kind "$kind" \
    --arg outcome "$outcome" --arg http "$http" --argjson pid "$$" --argjson user "$user" '
    {ts:$ts, account:$account, kind:$kind, outcome:$outcome}
    + (if $http == "" then {} else {http:$http} end)
    + (if $user then {user:true} else {} end)
    + {pid:$pid}') || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  # Permanent but bounded: roll to one .1 generation past the cap so the journal
  # can never grow without limit (~16k events/generation at the default cap).
  max_bytes="${CLAUDEB_TOKEN_JOURNAL_MAX_BYTES:-2000000}"
  if [[ "$max_bytes" =~ ^[0-9]+$ ]] && [ -f "$file" ]; then
    sz=$(wc -c < "$file" 2>/dev/null) || sz=0
    if [[ "$sz" =~ ^[0-9]+$ ]] && [ "$sz" -ge "$max_bytes" ]; then
      [ ! -f "$file.1" ] || ! declare -F limit_hit >/dev/null || limit_hit claudeb.token-journal-rotate "$max_bytes" bytes drop \
        "$(wc -c <"$file.1" | tr -d ' ') bytes of the older OAuth token-attempt history (.1) deleted" \
        'share/token-journal.sh:CLAUDEB_TOKEN_JOURNAL_MAX_BYTES:-2000000' "$sz"
      mv -f "$file" "$file.1" 2>/dev/null || true
    fi
  fi
  printf '%s\n' "$line" >>"$file" 2>/dev/null || true
  return 0
}
