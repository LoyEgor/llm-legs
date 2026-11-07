#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# An organization that blocks Claude Code (2026-11-06: com and notcom, one paused Team org) is
# account state: the CLI's error freezes the account and its organization, the collector and the
# picker read the freeze, and only a served re-check clears it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/claudeb"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
# A chat's own pin file would lead the pins the picker reads below.
unset CLAUDE_CODE_SESSION_ID WORKER_PICK_CONFIG_FILE

HOME="$WORK/home"
CLAUDEB_DIR="$WORK/store"
LLM_LIMITS_ANNOUNCE_CMD="$WORK/no-announce"
export HOME CLAUDEB_DIR LLM_LIMITS_ANNOUNCE_CMD
mkdir -p "$HOME" "$CLAUDEB_DIR/limits" "$CLAUDEB_DIR/tokens" "$WORK/bin"
for command in curl security; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$WORK/bin/$command"
  chmod +x "$WORK/bin/$command"
done
# The CLI as the 2026-11-06 legs met it (claudeb-1794007435-22582-2bcb): a 403 refusal before any
# model work; `served` is the answer of an org whose access came back.
cat >"$WORK/bin/claude" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' --version '*) echo '2.1.999 (Claude Code)'; exit 0 ;; esac
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
if [ "$(cat "$CLAUDE_MODE")" = served ]; then
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.001}\n'
  exit 0
fi
printf '{"type":"result","subtype":"success","is_error":true,"api_error_status":403,"api_error_code":"oauth_not_allowed_for_organization","duration_api_ms":0,"total_cost_usd":0,"result":"Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"}\n'
exit 1
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$LLM_LIMITS_ANNOUNCE_CMD"
chmod +x "$WORK/bin/claude" "$LLM_LIMITS_ANNOUNCE_CMD"
PATH="$WORK/bin:$PATH"
CLAUDE_CALLS="$WORK/claude-calls"
CLAUDE_MODE="$WORK/claude-mode"
export PATH CLAUDE_CALLS CLAUDE_MODE
printf 'blocked\n' >"$CLAUDE_MODE"
"$WORK/bin/claude" -p hi >"$WORK/blocked.out" 2>&1
: >"$CLAUDE_CALLS"

now=$(date +%s)
# com and notcom share one organization, solo has its own; all three measured fresh and signed in.
for spec in com:org-a:10 notcom:org-a:5 solo:org-b:40; do
  IFS=: read -r name org pct <<<"$spec"
  mkdir -p "$HOME/.claude-profiles/$name"
  printf '{"oauthAccount":{"organizationUuid":"%s"}}\n' "$org" >"$HOME/.claude-profiles/$name/.claude.json"
  : >"$CLAUDEB_DIR/tokens/$name"
  jq -n --argjson now "$now" --argjson pct "$pct" '{
    five_hour: {used_percentage: $pct, resets_at: ($now + 3600), as_of: $now, origin: "usage"},
    seven_day: {used_percentage: $pct, resets_at: ($now + 86400 * 3), as_of: $now, origin: "usage"},
    auth: {status: "ok", checked_at: $now}}' >"$CLAUDEB_DIR/limits/$name.json"
done
status_of() { jq -r '.auth.status' "$CLAUDEB_DIR/limits/$1.json"; }

# Detection: a worker leg's envelope that names the block freezes the account and its organization.
printf '{"type":"result","is_error":false,"result":"the org said oauth_org_not_allowed earlier"}\n' >"$WORK/answer.out"
rc=0; bash "$SCRIPT" org-blocked solo "$WORK/answer.out" >"$WORK/answer.names" 2>&1 || rc=$?
assert test "$rc" = 1
assert test "$(status_of solo)" = ok
assert bash "$SCRIPT" org-blocked com "$WORK/blocked.out" >"$WORK/frozen.names"
assert test "$(sort "$WORK/frozen.names" | paste -sd, -)" = com,notcom
assert test "$(status_of com)" = org-blocked
assert test "$(status_of notcom)" = org-blocked
assert test "$(status_of solo)" = ok

# State: a free usage read (it answers while the org is blocked) and a logged-out verdict keep it.
printf '{"five_hour":{"utilization":12,"resets_at":null},"seven_day":{"utilization":11,"resets_at":null}}\n' >"$WORK/usage.json"
assert bash -c '. "$1"; merge_usage com "$2"; mark_auth com ok; mark_auth com expired' _ "$SCRIPT" "$WORK/usage.json"
assert test "$(status_of com)" = org-blocked
assert jq -e '.five_hour.used_percentage == 12' "$CLAUDEB_DIR/limits/com.json" >/dev/null

# The collector and the picker: the frozen rows read `org blocked`, dimmed, and are never chosen.
export LLM_LIMITS_GEMINI_REFRESH=0 LLM_LIMITS_CODEX_REFRESH=0 LLM_LIMITS_GROK_REFRESH=0
export ELEVENLABS_KEYS="$WORK/no-elevenlabs-keys" EXPERIMENTS_REGISTRY="$WORK/no-experiments.json"
printf '[]\n' >"$EXPERIMENTS_REGISTRY"
export LLM_LIMITS_CACHE="$WORK/limits.json" LLM_LIMITS_FILE="$WORK/limits.json"
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
assert bash "$ROOT/llm-limits.sh" --json >/dev/null 2>&1
assert jq -e '[.vendors.claude.accounts[] | select(.account == "com")][0]
  | .blocked == true and .auth.status == "org-blocked" and .five_hour.stale == true and .weekly.stale == true
    and (has("auth_needed") | not)' "$LLM_LIMITS_CACHE" >/dev/null
table=$(bash "$ROOT/llm-limits.sh" --table --no-write 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g')
assert grep -Eq '^claude/com\*? .*org blocked' <<<"$table"
assert grep -Eq '^claude/solo\*? ' <<<"$table"
assert_fails grep -Eq '^claude/solo\*? .*org blocked' <<<"$table"
assert test "$("$ROOT/bin/worker-pick" --account claudeb 2>/dev/null)" = solo
picker=$("$ROOT/bin/worker-pick" --menu 2>/dev/null)
assert grep -Eq ' com .*org blocked$' <<<"$picker"
assert grep -Eq ' notcom .*org blocked$' <<<"$picker"
assert_fails grep -Eq 'login needed| blocked blocked' <<<"$picker"
# claudeb's own status table marks the frozen rows too, and only them.
accounts=$(bash "$SCRIPT" status 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g')
assert grep -Eq '^com .*org blocked$' <<<"$accounts"
assert grep -Eq '^notcom .*org blocked$' <<<"$accounts"
assert grep -Eq '^solo ' <<<"$accounts"
assert_fails grep -Eq '^solo .*org blocked' <<<"$accounts"
# A legacy string `auth` ("ok") in a collector row is no org block and keeps the row in the picker.
jq '.vendors.claude.accounts += [{account:"legacy",enabled:true,auth:"ok",weekly:{used_pct:1}}]' \
  "$LLM_LIMITS_CACHE" >"$WORK/legacy.json"
assert grep -Eq ' legacy ' <<<"$(LLM_LIMITS_FILE="$WORK/legacy.json" LLM_LIMITS_CACHE="$WORK/legacy.json" \
  "$ROOT/bin/worker-pick" --menu 2>/dev/null)"
# A pin is the one override above the pool toggle, never above a dead org.
mkdir -p "$HOME/.claude"
printf 'claudeb_profile=com\n' >"$HOME/.claude/worker-model"
assert test "$("$ROOT/bin/worker-pick" --account claudeb 2>/dev/null)" = solo
rm -f "$HOME/.claude/worker-model"

# Unfreeze: only a due account is re-checked, a refusal re-stamps the freeze, a served answer ends it.
age() { jq --argjson at "$2" '.auth.checked_at = $at' "$CLAUDEB_DIR/limits/$1.json" >"$WORK/aged" &&
  mv "$WORK/aged" "$CLAUDEB_DIR/limits/$1.json"; }
recheck() { bash -c '. "$1"; org_block_recheck' _ "$SCRIPT" 2>/dev/null; }
assert recheck
assert test ! -s "$CLAUDE_CALLS"
age com $((now - 3700))
assert recheck
assert test "$(grep -c . "$CLAUDE_CALLS")" = 1
assert test "$(status_of com)" = org-blocked
assert jq -e --argjson now "$now" '.auth.checked_at >= $now' "$CLAUDEB_DIR/limits/com.json" >/dev/null
printf 'served\n' >"$CLAUDE_MODE"
assert recheck
assert test "$(grep -c . "$CLAUDE_CALLS")" = 1
age com $((now - 3700))
assert recheck
assert test "$(status_of com)" = ok
assert test "$(status_of notcom)" = org-blocked

echo "PASS: $asserts asserts; org block detected from the CLI's own error (an answer discussing it is no block), frozen across the organization, kept by usage reads and other verdicts, shown as org blocked with dimmed numbers in the collector, table and picker, skipped even when pinned, re-checked hourly and cleared only by a served answer"
