#!/usr/bin/env bash
# The two heaviest review panels — tier T3 and any tier's --max composition — are Egor's to start.
# Nothing about that may rest on a model reading an instruction, so it is a gate: `prompt` mode
# (UserPromptSubmit) turns HIS OWN words into a short-lived one-shot grant, and `bash` mode
# (PreToolUse on Bash) denies the panel to every caller holding no grant. `bin/review-bench`
# refuses the same two panels from its own side, for the callers this hook never sees.
# Fail-open on any error: a broken gate must never block ordinary reviews.
set -u

MODE="${1:-}"
GRANT_TTL_S=1800
# A spent grant still answers for the very same command, so a run killed by a crash or a wall can
# be relaunched; anything else needs Egor's word again.
GRANT_RETRY_S=1200

state_dir() {
  if [ -n "${WORKER_STATS_DIR:-}" ]; then
    printf '%s' "$WORKER_STATS_DIR"
  else
    printf '%s/worker-stats' "${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}"
  fi
}

grant_dir() { printf '%s/review-grants' "$(state_dir)"; }

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat) || exit 0
now=$(date +%s) || exit 0

case "$MODE" in
  prompt)
    printf '%s' "$input" | jq -e '.hook_event_name == "UserPromptSubmit"' >/dev/null 2>&1 || exit 0
    prompt=$(printf '%s' "$input" | jq -r '.prompt // empty') || exit 0
    [ -n "$prompt" ] || exit 0
    # Mentioning a panel is not asking for one. A message that argues about T3, quotes a refusal,
    # or pastes a diff naming it must open nothing — otherwise `suggest` turns his own question
    # into the heavy command he was questioning. So a grant needs the keyword AND an asking verb
    # on the same line, with no negation in front of it; a bare "T3" as the whole message counts,
    # because that is him asking in the shortest way there is.
    ASK='(^|[^A-Za-z0-9])(запусти|прогони|погоняй|сделай|давай|дай|нужен|нужно|хочу|пожалуйста|плиз|run|launch|start|need|want|please)'
    # grep is line-based, so the span is only bounded by sentence punctuation: the negation has to
    # belong to the same sentence as the keyword.
    NEGATED='(не|нет|без|никогда|not|no|never|without|don'\''t|dont)[^.!?]{0,30}'
    asks() {
      local keyword="$1" line
      while IFS= read -r line; do
        grep -Eiq -- "$keyword" <<<"$line" || continue
        grep -Eiq -- "$NEGATED$keyword" <<<"$line" && continue
        grep -Eiq -- "$ASK" <<<"$line" && return 0
      done <<<"$prompt"
      # The whole message being the keyword and nothing else.
      grep -Eiqx -- "[[:space:]]*$keyword[[:space:]]*[.!?]?" <<<"$prompt"
    }
    scopes=()
    T3_WORDS='((^|[^A-Za-z0-9])(t3|т3)([^A-Za-z0-9]|$)|--tier[= ]+t3)'
    MAX_WORDS='((^|[[:space:]])--max([[:space:]]|$)|max[[:space:]]+review|макс[а-яё]*[[:space:]]+(ревью|review|прогон)|полн[а-яё]+[[:space:]]+ревью|ревью[[:space:]]+на[[:space:]]+макс)'
    asks "$T3_WORDS" && scopes+=(t3)
    asks "$MAX_WORDS" && scopes+=(max)
    [ "${#scopes[@]}" -gt 0 ] || exit 0
    session=$(printf '%s' "$input" | jq -r '.session_id // empty')
    session=$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')
    [ -n "$session" ] || session="default"
    dir=$(grant_dir)
    mkdir -p "$dir" 2>/dev/null || exit 0
    # A grant older than its own retry window can answer for nothing, so it is litter — and so is
    # a claim left behind by a hook that was killed mid-spend.
    find "$dir" -maxdepth 1 \( -name '*.json' -o -name '*.claim.*' \) \
      -mmin +$(((GRANT_TTL_S + GRANT_RETRY_S) / 60)) -delete 2>/dev/null
    payload=$(jq -cn --arg session "$session" --argjson ts "$now" \
      --argjson scopes "$(printf '%s\n' "${scopes[@]}" | jq -Rc . | jq -sc .)" \
      '{session: $session, ts: $ts, scopes: $scopes}' 2>/dev/null) || exit 0
    printf '%s\n' "$payload" >"$dir/$session.json" 2>/dev/null || exit 0
    jq -cn --arg c "Egor asked for an owner-only review panel by name (${scopes[*]}): one such run is authorized now, and \`review-bench suggest\` prints it as its \`command:\` line. Nothing else about the review changes." \
      '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
    exit 0
    ;;
  bash)
    printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and .tool_name == "Bash"' \
      >/dev/null 2>&1 || exit 0
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || exit 0
    [ -n "$cmd" ] || exit 0
    # Only a launch is gated: `suggest`, `tiers`, `report`, and a mention of the command inside
    # another one (a grep over the docs cites it verbatim) are none of this gate's business. Hence
    # the anchor — the tool has to start a command, after a separator or an env assignment, not
    # merely appear somewhere in the line. review-bench refuses the same panels itself, which is
    # what covers a launch buried where no anchor can see it.
    launch=$(grep -Eo '(^|[;&|(`])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(env[[:space:]]+)?[^[:space:]]*review-bench[[:space:]]+(review|run)([[:space:]].*)?$' \
      <<<"$cmd" | head -n1)
    [ -n "$launch" ] || exit 0
    wanted=()
    # Read off the launch itself, not the whole line: quoting one of these flags earlier in a
    # compound command must not deny the ordinary review that follows it.
    grep -Eiq -- '--tier[=[:space:]]+"?'\''?t3([^A-Za-z0-9]|$)' <<<"$launch" && wanted+=(t3)
    # Anchored on both sides so --max-tokens is not read as --max.
    grep -Eq -- '(^|[[:space:]])--max([[:space:]]|$)' <<<"$launch" && wanted+=(max)
    [ "${#wanted[@]}" -gt 0 ] || exit 0
    dir=$(grant_dir)
    cmd_hash=$(printf '%s' "$cmd" | shasum -a 1 2>/dev/null | cut -c1-16)
    granted=""
    claim=""
    for grant in "$dir"/*.json; do
      [ -f "$grant" ] || continue
      # An unspent grant is live until its TTL; a spent one answers for its own retry window,
      # measured from the moment it was spent, so a run that crashed at minute 29 can still be
      # relaunched.
      jq -e --argjson now "$now" --argjson ttl "$GRANT_TTL_S" --argjson retry "$GRANT_RETRY_S" \
        --arg hash "$cmd_hash" --argjson wanted "$(printf '%s\n' "${wanted[@]}" | jq -Rc . | jq -sc .)" \
        '(($wanted - (.scopes // [])) | length) == 0
         and (if (.used_at | type) == "number"
              then .used_cmd == $hash and ($now - .used_at) >= 0 and ($now - .used_at) <= $retry
              else (.ts | type) == "number"
                   and ($now - .ts) >= 0 and ($now - .ts) <= $ttl
              end)' \
        "$grant" >/dev/null 2>&1 || continue
      # Claim it by renaming: two PreToolUse hooks racing for one grant cannot both win a mv, so
      # one word cannot start two heavy panels.
      claim="$grant.claim.$$"
      if mv "$grant" "$claim" 2>/dev/null; then
        granted="$grant"
        break
      fi
      claim=""
    done
    if [ -z "$granted" ]; then
      jq -cn --arg r "Blocked: tier T3 and --max are Egor's to start, and he has not asked for one. This gate is the rule, not a suggestion — do not rebuild the command another way. Run the tier \`review-bench suggest\` prints as its \`command:\` line; if this change looks like it deserves more, ask Egor in one line and wait for his answer." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' 2>/dev/null
      exit 0
    fi
    # Spend it: the same command may still be retried, anything else needs his word again. The
    # claim goes back under its own name either way — a grant that vanished on a failed write
    # would silently refuse the very command it just allowed.
    spent=$(jq -c --argjson now "$now" --arg hash "$cmd_hash" \
      '.used_at = $now | .used_cmd = $hash' "$claim" 2>/dev/null)
    if [ -n "$spent" ]; then
      printf '%s\n' "$spent" >"$claim" 2>/dev/null
    fi
    mv "$claim" "$granted" 2>/dev/null
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
