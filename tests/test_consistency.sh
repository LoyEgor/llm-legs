#!/usr/bin/env bash
# Guards docs/shared-invariants.md: values duplicated across independent
# implementations (bash/jq/Lua/prose) must not drift apart. Each check
# re-extracts the live value from every site and asserts they agree with each
# other and with the doc's canonical value. No network, no daemon, no writes.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="docs/shared-invariants.md"
CLAUDEB="$ROOT/bin/claudeb"
STATUSLINE="$ROOT/bin/statusline.sh"
WORKERPICK="$ROOT/bin/worker-pick"
LLMLIMITS="$ROOT/llm-limits.sh"
DRIVER="$ROOT/bin/claude-session-driver"

HAMMER="$ROOT/hammerspoon/llm-limits.lua"
WORKER_GATE="${WORKER_LIMIT_GATE:-$HOME/.claude/hooks/worker-limit-gate.sh}"
WORKER_GATE_SETTINGS="${WORKER_GATE_SETTINGS:-$HOME/.claude/settings.json}"

asserts=0
fail() { printf 'FAIL: %s\n  (canonical values live in %s)\n' "$*" "$DOC" >&2; exit 1; }
assert() {
  asserts=$((asserts + 1))
  "$@" || fail "assert $asserts: $*"
}
eq() { [ "$1" = "$2" ] || return 1; }

# Value the doc declares canonical, extracted from its own table so a drifted
# doc is caught too.
doc_has() { grep -Fq -- "$1" "$ROOT/$DOC"; }

# --- Row a: staleness/dim thresholds -----------------------------------------
FIVE=1800; WEEK=21600; FABLE=21600
LIMITSVIEW="$ROOT/share/limits-view.sh"

# doc prose carries all three
assert doc_has '`1800`s'
assert doc_has '`21600`s'

# the numbers live once, in the shared view module
lv_five=$(grep -oE '^LIMITS_STALE_FIVE_HOUR=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
lv_week=$(grep -oE '^LIMITS_STALE_WEEKLY=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
lv_fable=$(grep -oE '^LIMITS_STALE_FABLE=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
assert eq "$lv_five" "$FIVE"
assert eq "$lv_week" "$WEEK"
assert eq "$lv_fable" "$FABLE"

# claudeb and the collector consume the shared variables, never a local literal
assert grep -Fq -- '--argjson thr5 "$LIMITS_STALE_FIVE_HOUR"' "$CLAUDEB"
assert grep -Fq -- '--argjson thr5 "$LIMITS_STALE_FIVE_HOUR"' "$LLMLIMITS"
assert eq "$(grep -c 'is_stale(' "$CLAUDEB")" 0
assert eq "$(grep -cE '\$stale > (1800|21600)' "$LLMLIMITS")" 0

# statusline dim logic — anchor on the age comparison, not the arrow rounding term
sl_five=$(grep -oE 'now - h5_as_of\)\) -gt [0-9]+' "$STATUSLINE" | grep -oE '[0-9]+$')
sl_week=$(grep -oE 'now - wk_as_of\)\) -gt [0-9]+' "$STATUSLINE" | grep -oE '[0-9]+$')
sl_fable=$(grep -oE 'now - limits_mtime\)\) -gt [0-9]+' "$STATUSLINE" | grep -oE '[0-9]+$')
assert eq "$sl_five" "$FIVE"
assert eq "$sl_week" "$WEEK"
assert eq "$sl_fable" "$FABLE"

# hammerspoon must stay stale-flag-driven, not hardcode one of these thresholds
assert grep -q 'bucket.stale == true' "$HAMMER"

# --- Row b: keychain service formula -----------------------------------------
# Both sites: shasum -a 256, first 8 chars, "Claude Code-credentials-" prefix.
for site in "$CLAUDEB" "$LLMLIMITS"; do
  assert grep -q 'shasum -a 256' "$site"
  assert grep -q 'substr($1, 1, 8)' "$site"
  assert grep -q 'Claude Code-credentials-' "$site"
done
# claudeb owns the single helper the doc names (subtask 1 consolidation)
assert grep -q '^keychain_service()' "$CLAUDEB"
assert doc_has '`keychain_service`'
# Third site, in Python: same prefix, same digest, same 8 hex, same profile path.
assert grep -q '^def keychain_service' "$DRIVER"
assert grep -Fq 'hashlib.sha256(profile.encode("utf-8")).hexdigest()[:8]' "$DRIVER"
assert grep -Fq '"Claude Code-credentials-"' "$DRIVER"
assert grep -Fq '".claude-profiles"' "$DRIVER"
assert doc_has 'bin/claude-session-driver'

# --- Row c: worker-pick cache line format ------------------------------------
# Producer printf and cb prefixes.
assert grep -Fq 'cx%s%s·'\''"$codex_model"'\''·%s %s·%s·%s gx%s%s·%s·%s' "$WORKERPICK"
assert grep -Eq 'cb_cache="cb~\$' "$WORKERPICK"
assert grep -Eq 'cb_cache="cb@\$' "$WORKERPICK"
assert grep -Fq 'cb_cache="cb~?"' "$WORKERPICK"
# Producer and consumer must name the same cache file.
assert grep -q 'worker-pick.line' "$WORKERPICK"
assert grep -q 'worker-pick.line' "$STATUSLINE"
# Doc records the format.
assert doc_has 'cx%s%s·<model>·%s %s·%s·%s gx%s%s·%s·%s'

# --- Row d: weather HTTP classes ---------------------------------------------
# probe_weather_failed's case pattern is the canonical class list.
wf_line=$(grep -E 'case "\$http" in [0-9|[].*return 0' "$CLAUDEB" | head -n1)
[ -n "$wf_line" ] || fail "row d: probe_weather_failed weather case not found"
wf_pat=$(printf '%s' "$wf_line" | sed -E 's/.*case "\$http" in ([^)]*)\).*/\1/')
assert eq "$wf_pat" '000|429|5[0-9][0-9]'

# The oauth_refresh classifier must map every one of those classes to weather
# (never to an auth verdict). 429 has its own weather branch; 5xx/000 share one.
assert grep -Fq 'if [ "$http" = 429 ]; then' "$CLAUDEB"
assert grep -Fq '5[0-9][0-9]$ ]] || [ "$http" = 000 ]; then' "$CLAUDEB"
# and the auth-verdict branch is fenced to 401/403 only.
assert grep -Fq '[ "$http" = 401 ] || [ "$http" = 403 ]; then' "$CLAUDEB"
# None of the three weather tokens may appear on an auth-verdict line.
for tok in '000' '429' '5[0-9][0-9]'; do
  if grep -nE "$tok" "$CLAUDEB" | grep -E 'auth-failed|revoked|mark_auth "\$name" expired' | grep -Fq "$tok"; then
    fail "row d: weather class $tok appears on an auth-verdict line"
  fi
done

OAUTH_BASE=900; OAUTH_CAP=14400
cb_oauth=$(sed -n '/^oauth_backoff_until()/,/^oauth_warm_backoff_until()/p' "$CLAUDEB")
ll_oauth=$(sed -n '/^claude_stale_cause()/,/^}/p' "$LLMLIMITS")
cb_base=$(printf '%s\n' "$cb_oauth" | grep -oE '[0-9]+ \* \(2 \| pow' | grep -oE '^[0-9]+' | head -n1)
ll_base=$(printf '%s\n' "$ll_oauth" | grep -oE '[0-9]+ \* \(2 \| pow' | grep -oE '^[0-9]+' | head -n1)
cb_cap=$(printf '%s\n' "$cb_oauth" | grep -oE 'if \. > [0-9]+ then [0-9]+' | grep -oE '[0-9]+' | sort -u)
ll_cap=$(printf '%s\n' "$ll_oauth" | grep -oE 'if \. > [0-9]+ then [0-9]+' | grep -oE '[0-9]+' | sort -u)
assert eq "$cb_base" "$OAUTH_BASE"
assert eq "$ll_base" "$OAUTH_BASE"
assert eq "$cb_cap" "$OAUTH_CAP"
assert eq "$ll_cap" "$OAUTH_CAP"
assert doc_has '`900 * 2^(max(1, strikes)-1)`'
assert doc_has 'capped at `14400`s'

# --- Row f: token-freeze file semantics --------------------------------------
# Both implementations must gate on file existence, parse `.until // empty`,
# apply the numeric guard, and treat a past `until` as inactive (`-gt now`).
cb_fz=$(sed -n '/^token_freeze_active()/,/^}/p' "$CLAUDEB")
ll_fz=$(sed -n '/^token_freeze_active_at()/,/^}/p' "$LLMLIMITS")
[ -n "$cb_fz" ] || fail "row f: token_freeze_active not found in $CLAUDEB"
[ -n "$ll_fz" ] || fail "row f: token_freeze_active_at not found in $LLMLIMITS"
for probe in '[ -f "$' '.until // empty' '^[0-9]+$' '-gt'; do
  assert grep -Fq -- "$probe" <<<"$cb_fz"
  assert grep -Fq -- "$probe" <<<"$ll_fz"
done
assert grep -Fq -- 'token-freeze' "$CLAUDEB"
assert grep -Fq -- 'token-freeze' "$LLMLIMITS"
assert doc_has 'Token-freeze file semantics'

# --- Row g: Codex/Gemini base-profile and worker display priority -------------
CODEXB="$ROOT/bin/codexb"
POLICY="$ROOT/share/worker-policy.md"
assert grep -Fq 'main_last:(if (.account // "main") == "main" then 1 else 0 end)' "$WORKERPICK"
assert test "$(grep -Fc 'def rank_keys: [.spend, (.h5 // 100), .main_last, .name];' "$WORKERPICK")" -eq 1
assert test "$(grep -Fc 'def rank: sort_by(rank_keys);' "$WORKERPICK")" -eq 1
assert grep -Fq 'def display_band($selected): if .name == $selected then 0 elif .eligible then 1 elif .in_pool then 2 else 3 end;' "$WORKERPICK"
# The render sorts on the band plus the selection keys, so within a band the order is the
# selection order rather than the limits file's.
assert grep -Fq 'def display_sort($selected): sort_by([display_band($selected)] + rank_keys);' "$WORKERPICK"
assert test "$(grep -Fc 'sort_by(display_band(' "$WORKERPICK")" -eq 0
assert test "$(grep -Fc 'display_sort($sel)' "$WORKERPICK")" -eq 3
assert grep -Fq 'main_last:(if $entry.account == "main" then 1 else 0 end)' "$CODEXB"
assert grep -Fq 'sort -t $'\''\t'\'' -k2,2n -k3,3n -k4,4n -k1,1' "$CODEXB"
assert grep -Fq 'Codex and Gemini `main` profiles rank last on a tie' "$POLICY"
assert doc_has 'Codex/Gemini base-profile priority'

REVIEWBENCH="$ROOT/bin/review-bench"
for mapping in \
  '"agy-pro": "gemini-3.1-pro"' \
  '"agy-flash37": "gemini-3.7-flash"' \
  '"agy-flash36": "gemini-3.6-flash"' \
  '"agy-flash35": "gemini-3.5-flash"'; do
  assert grep -Fq -- "$mapping" "$REVIEWBENCH"
done
assert grep -Fq '"agy-pro": ("low", "high")' "$REVIEWBENCH"
assert grep -Fq '"agy-flash37": ("low", "medium", "high")' "$REVIEWBENCH"
assert grep -Fq '"agy-flash36": ("low", "medium", "high")' "$REVIEWBENCH"
assert grep -Fq '"agy-flash35": ("low", "medium", "high")' "$REVIEWBENCH"
assert grep -Fq 'agy-pro-<low|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash37-<low|medium|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash36-<low|medium|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash35-<low|medium|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'return f"{model}-{rater['\''effort'\'']}"' "$REVIEWBENCH"
assert grep -Fq 'if rater["model"] == "agy-pro" and rater["effort"] == "high":' "$REVIEWBENCH"
assert doc_has '`agy-pro-low` → `--model gemini-3.1-pro-low`'
assert doc_has '`agy-pro-high` → `--model "Gemini 3.1 Pro (High)"`'
assert doc_has '`agy-flash37-<effort>` → `--model gemini-3.7-flash-<effort>`'
assert doc_has '`agy-flash36-<effort>` → `--model gemini-3.6-flash-<effort>`'
assert doc_has '`agy-flash35-<effort>` → `--model gemini-3.5-flash-<effort>`'
assert doc_has 'Every cell omits `--effort`'
assert test "$(sed -n '/^def run_agy(/,/^def /p' "$REVIEWBENCH" | grep -Fc '"--effort"')" -eq 0
assert doc_has 'Antigravity review cell invocation mapping'

# --- Row i: Gemini worker knobs ----------------------------------------------
GEMINI_AGENT="${GEMINI_WORKER_AGENT:-$HOME/.claude/agents/gemini-worker.md}"
CODEX_AGENT="${CODEX_WORKER_AGENT:-$HOME/.claude/agents/codex-worker.md}"
CLAUDEB_AGENT="${CLAUDEB_WORKER_AGENT:-$HOME/.claude/agents/claudeb-worker.md}"
WORKER_COMMAND="${WORKER_COMMAND_FILE:-$HOME/.claude/commands/worker.md}"
assert test -r "$GEMINI_AGENT"
assert test -r "$CODEX_AGENT"
assert test -r "$CLAUDEB_AGENT"
assert test -r "$WORKER_COMMAND"
WORKER_RUN="${WORKER_RUN_BIN:-$ROOT/bin/worker-run}"
assert test -x "$WORKER_RUN"
for arm in \
  "pro:high) agy_model='Gemini 3.1 Pro (High)' ;;" \
  "pro:low) agy_model='gemini-3.1-pro-low' ;;" \
  'flash36:high|flash36:medium|flash36:low) agy_model="gemini-3.6-flash-$effort" ;;' \
  'flash35:high|flash35:medium|flash35:low) agy_model="gemini-3.5-flash-$effort" ;;'; do
  assert test "$(grep -Fc -- "$arm" "$WORKER_RUN")" -eq 1
done
assert grep -Fq '`gemini_model=pro`, and `gemini_effort=high`' "$WORKER_COMMAND"
assert grep -Fq 'Valid combinations are pro high/low, flash36 high/medium/low, and flash35 high/medium/low' "$WORKER_COMMAND"
assert grep -Fq 'gm_model=$(conf gemini_model); gm_model=${gm_model:-pro}' "$WORKERPICK"
assert grep -Fq 'gm_effort=$(conf gemini_effort); gm_effort=${gm_effort:-high}' "$WORKERPICK"
assert grep -Fq 'canonical knob-to-agy mapping lives in `worker-run`' "$POLICY"
assert doc_has 'Gemini worker knobs'

SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
assert grep -Fq 'gm_pin=$(conf gemini_profile)' "$WORKERPICK"
assert grep -Fq 'WORKER_PICK="${WORKER_SPAWN_WORKER_PICK:-$HOME/.local/bin/worker-pick}"' "$SPAWN_HOOK"
assert grep -Fq 'acct=$(brief_line ACCOUNT)' "$SPAWN_HOOK"
for vendor in claudeb codex gemini; do
  assert grep -Fq '[ -n "$acct" ] || acct=$(route_account '"$vendor"')' "$SPAWN_HOOK"
done
assert grep -Fq '[ -n "$acct" ] || acct=main' "$SPAWN_HOOK"
assert grep -Fq '`gemini_profile=<name>`' "$WORKER_COMMAND"
assert grep -Fq -- '--account) [ "$#" -ge 2 ] || usage; explicit_account="$2"; shift 2 ;;' "$WORKER_RUN"
assert grep -Fq '"$picker" --account "$vendor"' "$WORKER_RUN"
assert grep -Fq 'OUTCOME: %s_USAGE_LIMIT' "$WORKER_RUN"
assert grep -Fq 'pin=$(config_value "${vendor}_profile")' "$WORKER_RUN"
assert grep -Fq 'claudeb needs an explicit account or claudeb_profile pin when worker-pick is unavailable' "$WORKER_RUN"
assert grep -Fq 'account=main' "$WORKER_RUN"
for agent in "$CLAUDEB_AGENT" "$CODEX_AGENT" "$GEMINI_AGENT"; do
  assert grep -Fq -- '`--account <n>` (an `ACCOUNT:` line' "$agent"
  assert grep -Fq 'worker-run start' "$agent"
done
assert doc_has 'Worker account resolution'

# ask_claude.sh seds this stderr literal into its audit account field, so the wording is a
# three-site contract, not free prose.
assert grep -Fq "printf 'claudeb: worker-pick selected %s\\n'" "$CLAUDEB"
assert grep -Fq 's/^claudeb: worker-pick selected \([^[:space:]]*\)$/\1/p' "$ROOT/ask_claude.sh"
assert grep -Fq "printf 'claudeb: worker-pick selected %s\\n'" "$ROOT/tests/test_legs_routing.sh"
assert doc_has 'claudeb: worker-pick selected'

# --- Row l: Gemini quota group matching --------------------------------------
assert grep -Fq 'def gemini_group: ((.group // "") | ascii_downcase | contains("gemini"));' "$WORKERPICK"
assert test "$(grep -Fc 'ascii_downcase | contains("gemini")' "$LLMLIMITS")" -ge 3
assert doc_has 'case-insensitive group label contains `gemini`'
assert doc_has 'Gemini quota group matching'

# --- Row m: Gemini account discovery and HOME mapping ------------------------
GEMINI_ACCOUNTS="$ROOT/share/gemini-accounts.sh"
GEMINIB="$ROOT/bin/geminib"
assert test -r "$GEMINI_ACCOUNTS"
assert grep -Eq '^\. "\$(\(resolve_root\)|geminib_root)/share/gemini-accounts\.sh"$' "$GEMINIB"
assert grep -Fq '. "$script_dir/share/gemini-accounts.sh"' "$LLMLIMITS"
assert grep -q '^gemini_account_names()' "$GEMINI_ACCOUNTS"
assert grep -q '^gemini_account_home()' "$GEMINI_ACCOUNTS"
assert grep -Fq 'printf '\''%s\n'\'' "$gemini_base_home"' "$GEMINI_ACCOUNTS"
assert grep -Fq 'printf '\''%s\n'\'' "$gemini_profiles_dir/$1"' "$GEMINI_ACCOUNTS"
assert doc_has 'Gemini profile discovery and HOME mapping'

# --- Row n: weekly bucket provenance ----------------------------------------
STATUSLINE="$ROOT/bin/statusline.sh"
# No writer may mint a weekly percentage from headers: the header-learn paths must
# not mention the weekly bucket at all.
assert eq "$(awk '/^merge_headers\(\)/,/^}/' "$ROOT/bin/claudeb" | grep -Ec 'seven_day: \{|used_percentage: 100')" 0
assert grep -Fq 'def stamp: . + {as_of: $now, origin: "session"}' "$STATUSLINE"
assert test "$(grep -Fc '.seven_day.origin? == "headers"' "$ROOT/bin/claudeb")" -eq 2
assert grep -Fq '.seven_day.origin? != "headers"' "$LLMLIMITS"
assert grep -Fq '.seven_day.origin? == "headers"' "$LLMLIMITS"
assert grep -Fq '[ "$wk_origin" = headers ]' "$STATUSLINE"
assert grep -Fq 'if (.seven_day.origin? == "headers") then del(.seven_day) else . end) as $old' "$STATUSLINE"
assert grep -Fq 'walk(if type == "object" and (.weekly.origin? == "headers") then del(.weekly) else . end)' "$WORKERPICK"
assert doc_has 'Weekly bucket provenance'
assert doc_has 'no writer may stamp `origin: "headers"` on `seven_day`'

assert doc_has 'always emits boolean `rotation.usable.general`, `rotation.usable.fable`, and `blocked == (rotation.usable.general \| not)`'
EDGE_WORK=$(mktemp -d)
EDGE_BIN="$EDGE_WORK/bin"
EDGE_HOME="$EDGE_WORK/home"
EDGE_STORE="$EDGE_WORK/store"
mkdir -p "$EDGE_BIN" "$EDGE_HOME/.claude-profiles" "$EDGE_STORE/limits"
cat >"$EDGE_BIN/security" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" -w "*) printf '%s\n' '{"claudeAiOauth":{"subscriptionType":"team"}}' ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$EDGE_BIN/security"
printf '{"five_hour":{"used_percentage":10,"resets_at":4102444800},"fable":{"used_percentage":20,"resets_at":4102444800}}\n' >"$EDGE_STORE/limits/missing-auth.json"
printf '{"five_hour":{"used_percentage":10,"resets_at":4102444800},"fable":{"used_percentage":20,"resets_at":4102444800},"auth":{"status":"pending"}}\n' >"$EDGE_STORE/limits/bad-auth.json"
printf '{"weekly":{"used_percentage":10,"resets_at":4102444800},"auth":{"status":"ok"}}\n' >"$EDGE_STORE/limits/missing-five.json"
printf '{"five_hour":{"used_percentage":10,"resets_at":4102444800},"fable":{"used_percentage":"20","resets_at":4102444800},"auth":{"status":"ok"}}\n' >"$EDGE_STORE/limits/nonnumeric-fable.json"
printf '{"five_hour":{"used_percentage":10,"resets_at":4102444800},"fable":{"used_percentage":20,"resets_at":4102444800},"auth":{"status":"ok"}}\n' >"$EDGE_STORE/limits/disabled.json"
printf '{}\n' >"$EDGE_STORE/limits/empty.json"
printf 'disabled\n' >"$EDGE_STORE/disabled"
printf 'missing-auth\n' >"$EDGE_STORE/.claudeb-state"
EDGE_JSON=$(PATH="$EDGE_BIN:$PATH" HOME="$EDGE_HOME" CLAUDE_PROFILES_DIR="$EDGE_HOME/.claude-profiles" \
  CLAUDEB_DIR="$EDGE_STORE" LLM_LIMITS_CACHE="$EDGE_WORK/cache.json" \
  LLM_LIMITS_CODEX_REFRESH=0 LLM_LIMITS_GEMINI_REFRESH=0 \
  bash "$LLMLIMITS" --json --no-write) || fail "edge snapshot collection failed"
assert jq -e '
  (.vendors.claude.accounts | length) == 6 and
  all(.vendors.claude.accounts[];
    (.rotation.usable.general | type) == "boolean" and
    (.rotation.usable.fable | type) == "boolean" and
    (.blocked | type) == "boolean" and
    .blocked == (.rotation.usable.general | not)) and
  (any(.vendors.claude.accounts[]; .account == "disabled" and
    .rotation.usable.general == false and .rotation.usable.fable == false)) and
  (any(.vendors.claude.accounts[]; .account == "nonnumeric-fable" and
    .rotation.usable.fable == false)) and
  # worker-pick reads a missing key as true, so the fail-open direction needs its
  # value asserted, not just its type: no auth object, a non-ok verdict, and an
  # unreadable snapshot must all come out false.
  (all(.vendors.claude.accounts[] | select(.account == "missing-auth" or
       .account == "bad-auth" or .account == "empty");
    .rotation.usable.general == false and .rotation.usable.fable == false))
' <<<"$EDGE_JSON" >/dev/null
rm -rf "$EDGE_WORK"

GATE_WARN=85; GATE_DENY=95
assert test -x "$WORKER_GATE"
assert eq "$(grep -E '^WARN_AT=[0-9]+$' "$WORKER_GATE" | cut -d= -f2)" "$GATE_WARN"
assert eq "$(grep -E '^DENY_AT=[0-9]+$' "$WORKER_GATE" | cut -d= -f2)" "$GATE_DENY"
assert test "$(grep -Ec '^WARN_AT=' "$WORKER_GATE")" -eq 1
assert test "$(grep -Ec '^DENY_AT=' "$WORKER_GATE")" -eq 1
for worker in claudeb-worker codex-worker gemini-worker; do
  assert grep -Fq "$worker" "$WORKER_GATE"
done
for vendor in claudeb codex gemini; do
  assert grep -Fq "vendor=$vendor" "$WORKER_GATE"
done
assert grep -Fq '"$WORKER_PICK" --account "$vendor"' "$WORKER_GATE"
assert grep -Fq '[ "$router_rc" -eq 3 ]' "$WORKER_GATE"
assert grep -Fq '$pct >= 100' "$WORKER_GATE"
assert grep -Fq '$pct >= $warn' "$WORKER_GATE"
assert grep -Fq 'fell back to local thresholds' "$WORKER_GATE"
assert grep -Fq 'effective_pct' "$WORKER_GATE"
assert grep -Fq '$reset != null and $reset <= $now then 0' "$WORKER_GATE"
assert test -r "$WORKER_GATE_SETTINGS"
assert eq "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[] | select(.command == "~/.claude/hooks/worker-limit-gate.sh")] | length' "$WORKER_GATE_SETTINGS")" 1
assert eq "$(jq '[.hooks.PreToolUse[] | .hooks[]? | select(.command | test("(claudeb|codex)-limit-gate"))] | length' "$WORKER_GATE_SETTINGS")" 0
assert grep -Fq 'warned from `85`%' "$ROOT/$DOC"
assert grep -Fq '`95`% is the protective block only when worker-pick is unavailable or fails' "$ROOT/$DOC"
assert grep -Fq 'hard `100`% wall' "$ROOT/$DOC"
assert doc_has 'Worker spawn pressure gate'

reserved_set() {
  sed -nE 's/^[[:space:]]*(main\|)?(\.\*\|\*\/\*\|)?([a-z|._-]*help[a-z|._-]*)\).*/\3/p' "$1" |
    head -n1 | tr '|' '\n' | grep -vE '^(main|\.\*|\*/\*)$' | sort -u | paste -sd' ' -
}
assert eq "$(reserved_set "$CLAUDEB")" "$(reserved_set "$ROOT/bin/claude-chat-switch")"
# Compared against the code's own set rather than a third hand-maintained copy, so adding a
# subcommand cannot leave the invariant's prose behind.
doc_reserved=$(sed -nE 's/.*`(help[a-z -]*token-upkeep)`.*/\1/p' "$ROOT/$DOC" |
  head -n1 | tr ' ' '\n' | sort -u | paste -sd' ' -)
assert eq "$doc_reserved" "$(reserved_set "$CLAUDEB")"
assert doc_has 'Reserved profile names'

# --- Row q: Worker-pool membership -------------------------------------------
# One mechanism, or the same checkbox means three different things: every vendor must reach the
# state through the shared helper rather than keeping its own copy of the file format.
POOL="$ROOT/share/worker-pool.sh"
assert test -r "$POOL"
assert grep -q '^worker_pool_is_disabled()' "$POOL"
assert grep -q '^worker_pool_set_disabled()' "$POOL"
assert grep -q '^worker_pool_disabled_json()' "$POOL"
assert test "$(grep -c '/disabled"' "$POOL")" -ge 3
for pool_tool in claudeb codexb geminib; do
  assert grep -Fq 'share/worker-pool.sh"' "$ROOT/bin/$pool_tool"
  assert grep -Fq 'worker_pool_is_disabled "$pool' "$ROOT/bin/$pool_tool"
  assert grep -Fq 'worker_pool_set_disabled "$pool' "$ROOT/bin/$pool_tool"
  # The wall and the directory formula come from the helper too: a vendor that walled headless
  # runs on its own, or spelled its own pool path, is how the three drift apart.
  assert grep -Fq 'worker_pool_refuse_headless ' "$ROOT/bin/$pool_tool"
  assert grep -Eq 'pool_dir=\$\(worker_pool_dir (claudeb|codex|gemini)\)' "$ROOT/bin/$pool_tool"
  assert test "$(grep -c 'last enabled account' "$ROOT/bin/$pool_tool")" -eq 0
  # No vendor may re-derive the file format locally.
  assert test "$(grep -c 'grep -qxF -- ' "$ROOT/bin/$pool_tool")" -eq 0
done
# worker-run is the fourth consumer: codex workers never pass through codexb, so the wall has to
# be reachable from the launcher itself.
assert grep -Fq 'share/worker-pool.sh"' "$ROOT/bin/worker-run"
assert grep -Fq 'worker_pool_refuse_headless "$vendor"' "$ROOT/bin/worker-run"
assert grep -Fq 'out of the worker pool' "$ROOT/bin/worker-pick"
# codex-image launches codex directly, past codexb and past worker-run, so it is a launcher of
# its own and needs the same wall.
assert grep -Fq 'share/worker-pool.sh"' "$ROOT/bin/codex-image"
assert grep -Fq 'worker_pool_refuse_headless codex ' "$ROOT/bin/codex-image"
assert grep -Fq 'share/worker-pool.sh"' "$LLMLIMITS"
assert grep -Fq 'worker_pool_is_disabled' "$LLMLIMITS"
assert grep -Fq 'worker_pool_disabled_json' "$LLMLIMITS"
assert test "$(grep -c 'worker_pool_dir ' "$LLMLIMITS")" -ge 2
# Every vendor reaches the toggle through its own action, and each action is both defined and
# wired into a row — a count of menu entries would only measure how many rows happen to exist.
assert grep -Fq 'In worker pool' "$HAMMER"
for pool_toggle in toggleAccount toggleCodexAccount toggleGeminiAccount; do
  assert grep -Fq "function M.$pool_toggle(" "$HAMMER"
  assert test "$(grep -cF "M.$pool_toggle(" "$HAMMER")" -ge 2
done
assert doc_has 'Worker-pool membership'
assert doc_has '.claudeb`, `.codexb`, `.geminib'
assert doc_has 'the vendor pin (`claudeb_profile`, `codex_profile`, `gemini_profile`) is the one override'
assert doc_has 'Exclusion IS unreachability for every headless run'
assert grep -Fq 'cb_pin=$(conf claudeb_profile)' "$WORKERPICK"
assert grep -Fq 'cx_pin=$(conf codex_profile)' "$WORKERPICK"
assert grep -Fq 'gm_pin=$(conf gemini_profile)' "$WORKERPICK"
assert grep -Fq '.name == $cx_pin and (.walled | not)' "$WORKERPICK"
assert grep -Fq '.name == $gm_pin and (.walled | not)' "$WORKERPICK"
assert grep -Fq '$pin_account != null and $pin_account.auth_ok and $pin_account.general_usable' "$WORKERPICK"
# The session account is the reserve, not an exclusion (docs/routing-contract.md rule 1): a pin
# reaches it, so the gate must not regain an `.own` test, and the footnote must keep saying that
# the reserve is routed only when nothing else is selectable.
assert test "$(grep -cF 'pin_account.own' "$WORKERPICK")" -eq 0
assert grep -Fq 'the reserve — routed only when nothing else is selectable' "$WORKERPICK"

assert grep -Fq 'needs_user_entry:true' "$LLMLIMITS"
assert grep -Fq 'needs_user_entry == true' "$HAMMER"
assert grep -Fq 'split("; ")' "$LLMLIMITS"
assert grep -Fq 'end))] | join("; "))}' "$LLMLIMITS"
assert grep -Fq 'local parts, start, sep = {}, 1, "; "' "$HAMMER"
assert doc_has 'User-entry refresh classification'
assert doc_has 'including multiple Claude auth failures, uses `"; "` between entries'

assert grep -Fq 'RECEIPT_DIR = "receipts"' "$REVIEWBENCH"
assert grep -Fq 'RECEIPT_FIELDS = ("repo", "tree", "commit", "run_id", "ts")' "$REVIEWBENCH"
rb_receipt_name=$(sed -n '/^def receipt_file_name(repo, lens=None, scope=None):/,/^$/p' "$REVIEWBENCH")
rb_receipt_hash_len=$(grep -E '^RECEIPT_HASH_HEX = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
assert eq "$rb_receipt_hash_len" 8
assert grep -Fq 'hashlib.sha1(repo_path.encode()).hexdigest()[:RECEIPT_HASH_HEX]' \
  <<<"$rb_receipt_name"
assert grep -Fq 'return f"{repo_name}__{repo_hash}.json"' <<<"$rb_receipt_name"
# A lens receipt is a sibling of that name, never the name itself: a lens run read the tree by a
# methodology the tool did not write, and a scoped one read only part of it, so neither may
# advance the name a full review is sized against.
assert grep -Fq 'return f"{repo_name}__{repo_hash}__lens-{lens}.json"' <<<"$rb_receipt_name"
assert grep -Fq 'return f"{repo_name}__{repo_hash}__scope-{scope_receipt_slug(scope)}.json"' \
  <<<"$rb_receipt_name"
assert grep -Fq 'hashlib.sha1("\0".join(scope).encode()).hexdigest()[:RECEIPT_HASH_HEX]' \
  "$REVIEWBENCH"
# Scope receipts are read per PATH by coverage alone, and the per-path verdict is what keeps a
# partial review from covering the repository.
assert grep -Fq 'path = state_dir() / RECEIPT_DIR / name' "$REVIEWBENCH"
# The receipt is review-bench's own record and nothing renders it: the statusline speaks the
# gate's verdict about THIS chat (row ah) and keeps no tree-keyed reader, or a repository some
# other chat reviewed would carry a label here.
assert doc_has 'no surface outside `bin/review-bench` reads it'
assert test "$(grep -c 'receipts' "$STATUSLINE")" -eq 0
assert test "$(grep -Ec 'RECEIPT|receipt_file_name|worktree_matches_tree' "$STATUSLINE")" -eq 0
assert grep -Fq '"panel"' "$REVIEWBENCH"
assert grep -Fq '"max": bool(max_panel)' "$REVIEWBENCH"
assert grep -Fq 'and ((.max | type) == "boolean" or .max == null))' "$STATUSLINE"
assert grep -Fq 'status --porcelain' "$STATUSLINE"
assert test "$(grep -Ec 'GIT_INDEX_FILE|git -C "\\$repo" add -A|current_tree_hash' "$STATUSLINE")" -eq 0
assert doc_has '<state_dir>/receipts/<repoName>__<repoHash>.json'
assert doc_has '<repoName>__<repoHash>__lens-<slug>.json'
assert doc_has '<repoName>__<repoHash>__scope-<slug>.json'
assert doc_has 'SHA-1 over its normalized paths joined with NUL'
assert doc_has '`repo`, `tree`, `commit`, `run_id`, and `ts`, non-negative integer `errored`'
assert doc_has 'optional positive integer `panel`'
assert doc_has "tree\` is the reviewed commit's Git tree object"

rb_late_multiplier=$(grep -E '^REVIEW_LATE_MULTIPLIER = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
rb_late_floor_s=$(grep -E '^REVIEW_LATE_FLOOR_S = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
sl_late_pair=$(grep -oE '\[[0-9]+ \* \$expected_ms, [0-9]+\]' "$STATUSLINE")
sl_late_multiplier=$(grep -oE '[0-9]+' <<<"$sl_late_pair" | head -n1)
sl_late_floor_ms=$(grep -oE '[0-9]+' <<<"$sl_late_pair" | tail -n1)
assert test "$(grep -Ec '^REVIEW_LATE_MULTIPLIER = ' "$REVIEWBENCH")" -eq 1
assert test "$(grep -Ec '^REVIEW_LATE_FLOOR_S = ' "$REVIEWBENCH")" -eq 1
assert test "$(grep -oE '\[[0-9]+ \* \$expected_ms, [0-9]+\]' "$STATUSLINE" | wc -l | tr -d ' ')" -eq 1
assert eq "$rb_late_multiplier" 3
assert eq "$sl_late_multiplier" "$rb_late_multiplier"
assert eq "$rb_late_floor_s" 120
assert eq "$sl_late_floor_ms" "$((rb_late_floor_s * 1000))"
assert doc_has 'Late review threshold'
assert doc_has '`3` ×'
assert doc_has '`120`s (`120000`ms) floor'

assert grep -Fq 'def data_as_of:' "$LLMLIMITS"
assert grep -Fq 'select(type == "object" and (.used_pct | type) == "number")' "$LLMLIMITS"
assert grep -Fq 'map(set_data_age)' "$LLMLIMITS"
assert grep -Fq 'select(type == "object" and (.used_pct | type) == "number")' "$WORKERPICK"

assert doc_has 'Account data age'
assert doc_has 'Absent and null-valued windows do not participate'

# --- Row w: owner-only review panels -----------------------------------------
OWNER_GATE="$ROOT/bin/review-owner-gate.sh"
assert grep -Fq 'OWNER_TIERS = ("T3",)' "$REVIEWBENCH"
assert grep -Fq 'OWNER_GRANT_DIR = "review-grants"' "$REVIEWBENCH"
rb_grant_ttl=$(grep -E '^OWNER_GRANT_TTL_S = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
gate_grant_min=$(grep -E '^GRANT_TTL_MIN=[0-9]+$' "$OWNER_GATE" | cut -d= -f2)
assert eq "$rb_grant_ttl" 1800
assert eq "$((gate_grant_min * 60))" "$rb_grant_ttl"
# One directory, one marker per panel, mtime the whole state — no payload to agree on.
assert grep -Fq "printf '%s/review-grants' \"\$state\"" "$OWNER_GATE"
assert grep -Fq 'state_dir() / OWNER_GRANT_DIR' "$REVIEWBENCH"
assert grep -Fq '(owner_grant_dir() / panel).stat().st_mtime' "$REVIEWBENCH"
assert grep -Fq 'find "$(grant_dir)/$1" -mmin "-$GRANT_TTL_MIN"' "$OWNER_GATE"
# The same two panel names on both sides, and the keyboard exemption is his shell, not any tty.
assert grep -Fq 'wanted = {"t3"} if tier_name in OWNER_TIERS else set()' "$REVIEWBENCH"
assert grep -Fq 'named+=(t3)' "$OWNER_GATE"
assert grep -Fq 'named+=(max)' "$OWNER_GATE"
assert grep -Fq 'fresh t3' "$OWNER_GATE"
assert grep -Fq 'fresh max' "$OWNER_GATE"
assert grep -Fq 'os.environ.get("CLAUDECODE")' "$REVIEWBENCH"
# Both hook registrations, or half the gate is silently off.
assert grep -Fq 'review-owner-gate.sh prompt' "$WORKER_GATE_SETTINGS"
assert grep -Fq 'review-owner-gate.sh bash' "$WORKER_GATE_SETTINGS"
assert doc_has 'Owner-only review panels'
assert doc_has '`<state_dir>/review-grants/<panel>`'

# --- Row x: claude account existence -----------------------------------------
# One enumerator over every claudeb store, main/- filtered on both surfaces,
# and the announce hooks wired into all three vendors' birth/death moments.
assert grep -Fq 'if [ -d "$tokens_dir" ]; then' "$CLAUDEB"
assert grep -Fq 'for path in "$limits_dir"/*.json; do' "$CLAUDEB"
assert grep -Fq 'for path in "$profiles_root"/*; do' "$CLAUDEB"
assert grep -Fq 'grep -vx -e main -e -' "$CLAUDEB"
assert grep -Fq '[ "$account" != main ] && [ "$account" != - ]' "$LLMLIMITS"
assert grep -Fq 'announce_account_added' "$CLAUDEB"
assert grep -Fq 'announce_account_removed' "$CLAUDEB"
assert grep -Fq 'announce_account_removed' "$ROOT/bin/codexb"
assert grep -Fq 'announce_account_removed' "$ROOT/bin/geminib"
assert doc_has 'Claude account existence'

# --- Row y: one limits view for every surface ---------------------------------
# Bucket semantics (stale/expired/effective) and cell text (pct/markers/reset/age)
# are defined once in share/limits-view.sh; claudeb and the collector prepend
# $LIMITS_VIEW_JQ, the menu renders the collector's precomputed fields, and probes
# announce a passive collect so the merged cache moves with the snapshots.
for view_def in limits_reset_epoch_floor limits_bucket_expired limits_reset_ancient \
    limits_bucket_stale limits_effective_pct limits_reset_text limits_age_text \
    limits_markers limits_pct_text; do
  assert eq "$(grep -c "^def $view_def" "$LIMITSVIEW")" 1
done
# The day an ancient reset is dropped after is spelled in the def, in the live store guard that
# scans for a survivor, and in the doc — a drift in one of the three retires dates the others
# still expect to see.
assert grep -Fq '($now - $reset) > 86400' "$LIMITSVIEW"
assert grep -Fq '86400' "$ROOT/tests/e2e_surfaces.sh"
assert doc_has '`86400`s past is dropped'
assert grep -Fq 'limits_reset_ancient' "$LLMLIMITS"
for view_consumer in "$CLAUDEB" "$LLMLIMITS"; do
  assert grep -Fq 'share/limits-view.sh' "$view_consumer"
  assert grep -Fq 'limits_bucket_stale' "$view_consumer"
  assert grep -Fq 'limits_bucket_expired' "$view_consumer"
  assert grep -Fq 'limits_pct_text' "$view_consumer"
  assert grep -Fq 'limits_reset_text' "$view_consumer"
  assert grep -Fq 'limits_age_text' "$view_consumer"
done
# the menu stays flag-driven off the collector's fields (never re-derives pct semantics)
assert grep -Fq 'tonumber(bucket.effective_pct)' "$HAMMER"
assert eq "$(grep -c 'used_percentage' "$HAMMER")" 0
# probes/warms fold fresh snapshots into the merged cache; the collector's own
# child invocations are suppressed so a refresh never recurses or double-writes
assert grep -Fq 'announce_limits_probed' "$CLAUDEB"
assert grep -Fq 'announce_suppressed' "$ROOT/share/account-announce.sh"
assert grep -Fq 'LLM_LIMITS_ANNOUNCE_SUPPRESS=1' "$LLMLIMITS"
# a pressed r in the status TUI is a user-explicit refresh — the token-freeze
# experiment must not silently eat it
assert grep -Fq 'export CLAUDEB_WARM_USER_EXPLICIT=true' "$CLAUDEB"
assert doc_has 'One limits view'

# --- Row z: lens registry location -------------------------------------------
assert grep -Fq 'LENS_DIR = Path(__file__).resolve().parent.parent / "lenses"' "$REVIEWBENCH"
assert grep -Fq 'os.environ.get("REVIEW_BENCH_LENS_DIR")' "$REVIEWBENCH"
assert doc_has 'Lens registry location'
assert doc_has '`REVIEW_BENCH_LENS_DIR` overrides'

# --- Row aa: Hammerspoon launchd agent identity -------------------------------
HS_LABEL="com.egor.hammerspoon"
HS_PLIST="$ROOT/launchd/com.egor.hammerspoon.plist"
HS_GUARD="$ROOT/hammerspoon/config/env_guard.lua"
HS_LOG="/Users/egorloy/Library/Logs/$HS_LABEL.log"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$HS_PLIST")" "$HS_LABEL"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$HS_PLIST")" "/Users/egorloy/.local/libexec/hammerspoon"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$HS_PLIST")" "$HS_LOG"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$HS_PLIST")" "$HS_LOG"
assert grep -Fq -- "gui/\$(/usr/bin/id -u)/$HS_LABEL" "$HS_GUARD"
assert grep -Fq -- "/Library/Logs/$HS_LABEL.log" "$HS_GUARD"
assert grep -Fq -- "$HS_LABEL" "$ROOT/docs/DIAGNOSTICS.md"
assert doc_has 'Hammerspoon launchd agent identity'

# --- Row ab: review report frame ----------------------------------------------
# Two repositories build the same two lines independently: llm-legs prints them,
# the claude-setup hooks find blocks by their shape. A width that drifts on one
# side still renders, so nothing fails until a report silently stops being found.
FRAME_WIDTH=50
FRAME_WORD=review
FRAME_FOOTER_RE='={10,}'
assert test "$(grep -Ec '^REPORT_FRAME_WIDTH = ' "$REVIEWBENCH")" -eq 1
rb_frame_width=$(grep -E '^REPORT_FRAME_WIDTH = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
assert eq "$rb_frame_width" "$FRAME_WIDTH"
assert grep -Fq "REPORT_FRAME_WORD = \"$FRAME_WORD\"" "$REVIEWBENCH"
assert grep -Fq 'REPORT_END = "=" * REPORT_FRAME_WIDTH' "$REVIEWBENCH"
assert grep -Fq "f\"{'=' * left} {word} {'=' * (fill - left)}\"" "$REVIEWBENCH"
assert doc_has 'Review report frame'
assert doc_has '`^=+ [a-z]+ =+$`'
assert doc_has "\`^=+ $FRAME_WORD =+\$\`"
assert doc_has '`^={10,}$`'

CLAUDE_SETUP="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}"
COMMIT_REPORT="$CLAUDE_SETUP/hooks/commit-report.sh"
REPORT_NUDGE="$CLAUDE_SETUP/hooks/review-report-nudge.sh"
DELIVERY_GATE="$CLAUDE_SETUP/hooks/review-report-delivery-gate.sh"
if test -r "$COMMIT_REPORT" && test -r "$REPORT_NUDGE" && test -r "$DELIVERY_GATE"; then
  assert test "$(grep -Ec '^FRAME_WIDTH=' "$COMMIT_REPORT")" -eq 1
  cs_frame_width=$(grep -E '^FRAME_WIDTH=[0-9]+$' "$COMMIT_REPORT" | cut -d= -f2)
  assert eq "$cs_frame_width" "$rb_frame_width"
  assert grep -Fq 'local fill=$((FRAME_WIDTH - ${#1} - 2))' "$COMMIT_REPORT"
  # The review consumers narrow the header to its own word, so a commit or push report framed
  # identically is never taken for one; the closing rule stays the shared shape. Both of them
  # PRINT what they locate, so a frame either of them misreads is a report Egor never sees.
  cs_header_re='(?m)^=+ '"$FRAME_WORD"' =+\r?(?=\n|$)'
  cs_footer_re='(?m)^'"$FRAME_FOOTER_RE"'\r?(?=\n|$)'
  for cs_hook in "$REPORT_NUDGE" "$DELIVERY_GATE"; do
    assert grep -Fq "HEADER_SPAN_RE = re.compile(r\"$cs_header_re\")" "$cs_hook"
    assert grep -Fq "FOOTER_SPAN_RE = re.compile(r\"$cs_footer_re\")" "$cs_hook"
  done
  # Both hooks must read one command grammar: a run id only one of them keeps whole — the
  # collision `-<pid>` suffix included — or a launch only one recognises, splits one delivery
  # into two behaviours, and the ledger keys they share stop matching.
  cs_run_re=$(grep -F 'COMMAND_RUN_RE = re.compile(' "$REPORT_NUDGE")
  assert test -n "$cs_run_re"
  assert eq "$(grep -F 'COMMAND_RUN_RE = re.compile(' "$DELIVERY_GATE")" "$cs_run_re"
  assert grep -Fq '(?:-\d+)?' "$REPORT_NUDGE"
  # One tail-key derivation on both sides: the nudge writes it at delivery, the net matches a
  # head-cut copy on it — computed differently, the dedup silently stops working.
  cs_tail_line=$(grep -F 'return "tail:" + hashlib.sha256(block[-400:].encode()).hexdigest()' \
    "$REPORT_NUDGE")
  assert test -n "$cs_tail_line"
  assert eq \
    "$(grep -F 'return "tail:" + hashlib.sha256(block[-400:].encode()).hexdigest()' \
      "$DELIVERY_GATE")" "$cs_tail_line"
  cs_launch_re=$(sed -n '/^LAUNCH_RE = re.compile($/,/review-bench\\s")$/p' "$REPORT_NUDGE")
  assert test -n "$cs_launch_re"
  assert eq \
    "$(sed -n '/^LAUNCH_RE = re.compile($/,/review-bench\\s")$/p' "$DELIVERY_GATE")" \
    "$cs_launch_re"
else
  printf 'SKIP: review report frame across claude-setup (%s is unreadable)\n' "$CLAUDE_SETUP"
fi

FLOW_GATE="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/review-flow-gate.sh"

# --- Row ah: the statusline speaks the gate's verdict --------------------------
# Three implementations, one sentence: review-bench prints the debt word, the gate translates it
# into a style plus a label, and the statusline renders that verbatim. Renaming a word on any one
# side is silent — the gate falls through to `off` on an answer it cannot read, so a review that
# hung would render as nothing owed.
assert doc_has 'The statusline speaks the gate'
assert grep -Fq '"$gate" verdict "$1" "$2"' "$STATUSLINE"
assert grep -Fq "''|off) answer=off ;;" "$STATUSLINE"
assert grep -Fq '"dim "*|"bright "*|"loud "*) ;;' "$STATUSLINE"
# The three words the gate switches on, printed nowhere else.
assert grep -Fq 'print("none")' "$REVIEWBENCH"
assert grep -Fq 'print(f"timed-out {hung}")' "$REVIEWBENCH"
assert grep -Fq 'print(f"debt {len(debt)} {owner}{share}{locked}")' "$REVIEWBENCH"
assert doc_has '`debt <n> mine|other|unknown [<owned>] [locked]`'
# The owner word is what the gate switches on, so every word review-bench can print is named in
# the row that promises the gate reads them all.
assert grep -Fq 'owner = "unknown" if not session else ("mine" if owned else "other")' "$REVIEWBENCH"
assert doc_has 'nothing may parse positionally past the owner word'
if test -r "$FLOW_GATE"; then
  assert grep -Fq 'if [ "${1:-}" = verdict ]; then' "$FLOW_GATE"
  assert grep -Fq 'echo "bright rev ● $count" || echo "dim rev ● $count"' "$FLOW_GATE"
  # `loud` is the watchdog's alone, on both sides: red means a hung review and nothing else.
  assert grep -Fq 'timed-out*) echo "loud rev timeout" ;;' "$FLOW_GATE"
  assert test "$(grep -Fc -- 'loud ' "$FLOW_GATE")" -eq 1
  # The verdict asks about the repository, never about the pending paths: debt outlives the commit
  # that landed it, and a question narrowed to one chat's dirty files cannot see the rest.
  assert grep -Fq 'review-bench debt --repo "$top_dir" --session "$session" "$@"' "$FLOW_GATE"
  assert grep -Fq 'answer=$(review_debt) || { echo off; exit 0; }' "$FLOW_GATE"
else
  printf 'SKIP: statusline verdict grammar across claude-setup (%s is unreadable)\n' "$FLOW_GATE"
fi

# --- Row ao: the review debt journal -------------------------------------------
# One record format for both journals in the git dir, one writer for the debt one, and a reader
# that asks nothing else about authorship: a format that drifts on either side leaves debt owned by
# nobody, which reads exactly like a co-tenant's.
assert doc_has 'Review debt journal'
assert grep -Fq 'DEBT_JOURNAL = "claude-review-debt"' "$REVIEWBENCH"
assert grep -Fq 'COMMIT_JOURNAL = "claude-commit-journal"' "$REVIEWBENCH"
if test -r "$FLOW_GATE"; then
  assert grep -Fq 'journal="$gitdir/claude-review-debt"' "$FLOW_GATE"
  assert grep -Fq "printf '%s\\0' \"\$session\$tab\$stamp\$tab\$item\"" "$FLOW_GATE"
fi

# --- Row ap: the second-round thresholds bind the waiver -----------------------
# The fork's dials and the lock over a waiver are the same two numbers: a round that owes a second
# review in the gate's voice must not be waivable in the bench's.
assert doc_has 'Second-round thresholds bind the waiver'
rb_second_p1s=$(sed -n 's/^SECOND_REVIEW_P1S = \([0-9]*\)$/\1/p' "$REVIEWBENCH")
rb_second_findings=$(sed -n 's/^SECOND_REVIEW_FINDINGS = \([0-9]*\)$/\1/p' "$REVIEWBENCH")
assert eq "$rb_second_p1s" 2
assert eq "$rb_second_findings" 8
assert grep -Fq 'p1s >= SECOND_REVIEW_P1S or findings >= SECOND_REVIEW_FINDINGS' "$REVIEWBENCH"
if test -r "$FLOW_GATE"; then
  gate_second_p1s=$(sed -n 's/^SECOND_REVIEW_P1S=\([0-9]*\)$/\1/p' "$FLOW_GATE")
  gate_second_findings=$(sed -n 's/^SECOND_REVIEW_FINDINGS=\([0-9]*\)$/\1/p' "$FLOW_GATE")
  assert eq "$gate_second_p1s" "$rb_second_p1s"
  assert eq "$gate_second_findings" "$rb_second_findings"
fi

# --- Row aq: the waiver's placeholder reason -----------------------------------
# The gate prints a paste-ready waive command carrying a placeholder reason, and the bench refuses
# that one literal. A gate rewording it while the bench still refuses the old one reopens the hole
# with the paste-ready command as the carrier.
assert doc_has "The waiver's placeholder reason"
rb_placeholder=$(sed -n 's/^WAIVE_PLACEHOLDER_REASON = "\(.*\)"$/\1/p' "$REVIEWBENCH")
assert eq "$rb_placeholder" 'WHY THIS GOES UNREVIEWED'
assert grep -Fq 'if reason == WAIVE_PLACEHOLDER_REASON:' "$REVIEWBENCH"
if test -r "$FLOW_GATE"; then
  gate_placeholder=$(sed -n "s/.*review-bench waive --reason '\([^']*\)'.*/\1/p" "$FLOW_GATE" |
    head -1)
  assert eq "$gate_placeholder" "$rb_placeholder"
else
  printf 'SKIP: waiver placeholder reason across claude-setup (%s is unreadable)\n' "$FLOW_GATE"
fi

# --- Row ae: account pin ownership -------------------------------------------
# Three doors, one marker, one TTL. A door silently removed, or two of them disagreeing on where
# the marker lives, is a pin a session can move again — the failure this row exists to prevent.
PIN_GATE="$ROOT/bin/worker-pin-gate.sh"
WORKER_MODEL_SH="$ROOT/share/worker-model.sh"
pin_model_ttl=$(grep -E '^WORKER_MODEL_PIN_TTL_MIN="\$\{WORKER_MODEL_PIN_TTL_MIN:-[0-9]+\}"$' \
  "$WORKER_MODEL_SH" | grep -oE '[0-9]+' | head -1)
pin_gate_ttl=$(grep -E '^GRANT_TTL_MIN="\$\{WORKER_MODEL_PIN_TTL_MIN:-[0-9]+\}"$' \
  "$PIN_GATE" | grep -oE '[0-9]+' | head -1)
assert eq "$pin_model_ttl" 30
assert eq "$pin_gate_ttl" "$pin_model_ttl"
assert eq "$((pin_model_ttl * 60))" 1800
assert grep -Fq "printf '%s/pin-grants/pin' \"\$state\"" "$WORKER_MODEL_SH"
assert grep -Fq "printf '%s/pin-grants/pin' \"\$state\"" "$PIN_GATE"
# The command door: a session, the real file resolved rather than spelled, and both directions
# past one guard.
assert grep -Fq '[ -n "${CLAUDECODE:-}" ] || return 0' "$WORKER_MODEL_SH"
assert grep -Fq 'worker_model_canonical_path "$(worker_model_file)"' "$WORKER_MODEL_SH"
assert grep -Fq 'worker_model_canonical_path "$HOME/.claude/worker-model"' "$WORKER_MODEL_SH"
assert grep -Fq 'if ! worker_model_pin_allowed; then' "$WORKER_MODEL_SH"
# The file doors, all three registrations, and the pin-key rule that keeps `/worker` working —
# half a gate is a gate that is off, and a gate over the whole file is one that gets worked around.
assert grep -Fq 'canonical_path "$HOME/.claude/worker-model"' "$PIN_GATE"
assert grep -Fq "PIN_KEY_RE='^(claudeb|codex|gemini)_profile='" "$PIN_GATE"
assert grep -Fq 'worker-pin-gate.sh prompt' "$WORKER_GATE_SETTINGS"
assert grep -Fq 'worker-pin-gate.sh write' "$WORKER_GATE_SETTINGS"
assert grep -Fq 'worker-pin-gate.sh bash' "$WORKER_GATE_SETTINGS"
assert doc_has 'Account pin ownership'
assert doc_has '`<state_dir>/pin-grants/pin`'
# The account's own wall is the single ungated write, and it stays single: it asks for no grant,
# so a second caller reaching for it would be the way around all three doors.
assert grep -Fq 'worker_model_clear_walled_pin() {' "$WORKER_MODEL_SH"
assert eq "$(grep -rlF 'worker_model_clear_walled_pin' "$ROOT/bin" "$ROOT/share" | wc -l | tr -d ' ')" 2
assert grep -Fq '[ "$3" = exhausted ] || return 0' "$ROOT/bin/worker-pick"
assert doc_has 'the account ending its own pin'

# --- Row af: one voice for what a round earned -------------------------------
# The thresholds and the wording live in the gate; a second copy in a caller is the drift this
# guards. And the mode must sit ABOVE the payload read, or every caller hangs on an open pipe.
REVIEW_BENCH="$ROOT/bin/review-bench"
REPORT_GATE="${REVIEW_REPORT_GATE:-$HOME/.claude/hooks/review-report-gate.sh}"
if [ -r "$FLOW_GATE" ] && [ -r "$REPORT_GATE" ]; then
  assert grep -Fq 'if [ "${1:-}" = escalation-verdict ]; then' "$FLOW_GATE"
  gate_verdict_line=$(grep -n 'escalation-verdict \]; then' "$FLOW_GATE" | head -1 | cut -d: -f1)
  gate_read_line=$(grep -n '^[[:space:]]*input=\$(cat)$' "$FLOW_GATE" | head -1 | cut -d: -f1)
  assert test -n "$gate_verdict_line" -a -n "$gate_read_line"
  assert test "$gate_verdict_line" -lt "$gate_read_line"
  # The whole question is two numbers on argv: a caller passing a repository or a stamp instead
  # would be asking the gate to price a round out of the shared tree again.
  assert grep -Fq 'ev_p1="${2:-}" ev_total="${3:-}"' "$FLOW_GATE"
  assert grep -Fq '[str(ESCALATION_GATE), "escalation-verdict", str(p1), str(total)],' \
    "$REVIEW_BENCH"
  # The three dials, in the gate and only there.
  assert grep -Fq 'SECOND_REVIEW_P1S=2' "$FLOW_GATE"
  assert grep -Fq 'SECOND_REVIEW_FINDINGS=8' "$FLOW_GATE"
  assert grep -Fq 'WEAK_LINK_P1S=5' "$FLOW_GATE"
  for copy in SECOND_REVIEW_P1S SECOND_REVIEW_FINDINGS WEAK_LINK_P1S 'weak block'; do
    assert test "$(grep -Fc -- "$copy" "$REPORT_GATE")" -eq 0
  done
  # review-bench spells the two round-size numbers for the waiver lock alone (row ap holds them
  # equal); the weak-link dial and every word of the fork stay the gate's.
  for copy in WEAK_LINK_P1S 'weak block'; do
    assert test "$(grep -Fc -- "$copy" "$REVIEW_BENCH")" -eq 0
  done
  assert doc_has 'Second-round verdict has one voice'
  assert doc_has '`escalation-verdict <p1> <total>`'
  # The fork's closing words are also the trigger the report nudge keys its escalation demand on:
  # let either spelling drift and the model is never told to open with the weak-block analysis.
  assert grep -Fq 'Pick one and carry it out:' "$FLOW_GATE"
  if [ -r "$REPORT_NUDGE" ]; then
    assert grep -Fq 'ESCALATION_MARKER = "Pick one and carry it out"' "$REPORT_NUDGE"
  fi
else
  printf 'SKIP: review escalation voice across claude-setup (%s or %s is unreadable)\n' \
    "$FLOW_GATE" "$REPORT_GATE"
fi

# --- Row ai: usage wall record ------------------------------------------------
# Two processes write this file in two languages — bin/opencode-go at the 429 it sees, bin/review-bench
# for every side — so the record shape and the one rule they must spell alike, the per-window ceiling
# on a stated horizon, are pinned here. Nothing reads it to decide whether a wall still stands except
# the bench's own pool and llm-limits.sh (row al); the menubar no longer touches it at all.
WALL_FILE=walls.jsonl
OPENCODE_GO="$ROOT/bin/opencode-go"
rb_wall_file=$(grep -E '^WALL_STATE_FILE = ' "$REVIEWBENCH" | sed -E 's/^[^=]+= "([^"]+)"/\1/')
assert eq "$rb_wall_file" "$WALL_FILE"
assert grep -Fq "WALLS_FILE=\$WALL_STATE_DIR/$WALL_FILE" "$OPENCODE_GO"
assert grep -Fq 'override = os.environ.get("WORKER_STATS_DIR")' "$REVIEWBENCH"
assert grep -Fq '"CLAUDEB_DIR", str(Path.home() / ".claude-profiles" / ".claudeb")' "$REVIEWBENCH"
assert grep -Fq 'WALL_STATE_DIR=${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}' \
  "$OPENCODE_GO"
rb_wall_fields=$(grep -E '^WALL_RECORD_FIELDS = ' "$REVIEWBENCH" | grep -oE '"[^"]+"' | tr -d '"' | paste -sd, -)
assert eq "$rb_wall_fields" 'side,account,bucket,detected_at,reset_at,window'
# The second writer is pinned by the row it actually emits, in the same order and with the same
# optional fields dropped rather than written null.
WALL_WRITER=$(mktemp -d)
sed -n '/^wall_row()/,/^}/p' "$OPENCODE_GO" >"$WALL_WRITER/wall_row.sh"
printf 'GoUsageLimitError limitName=weekly. Resets in 2 hours\n' >"$WALL_WRITER/body"
go_wall_fields=$(KEY_SERVICE=opencode-go bash -c '
  . "$1/wall_row.sh"
  wall_row 1000000 "$1/body" | jq -r "keys_unsorted | join(\",\")"' _ "$WALL_WRITER")
assert eq "$go_wall_fields" "$rb_wall_fields"
rm -rf "$WALL_WRITER"

# The ceiling table is the one rule both writers must spell alike: a horizon capped differently on
# the two sides retires the same account for two different lengths of time.
rb_ceilings=$(python3 - "$REVIEWBENCH" <<'CEILINGS'
import re, sys
src = open(sys.argv[1]).read()
ns = {}
exec(re.search(r"^WALL_MAX_TTL_S = .*$", src, re.M).group(0), ns)
exec(re.search(r"^WALL_WINDOW_MAX_TTL_S = \{.*?^\}", src, re.M | re.S).group(0), ns)
print(",".join(f"{k}:{v}" for k, v in ns["WALL_WINDOW_MAX_TTL_S"].items())
      + f",default:{ns['WALL_MAX_TTL_S']}")
CEILINGS
)
assert eq "$rb_ceilings" '5-hour:21600,weekly:691200,monthly:2764800,default:604800'
# The null-safe index matters: a 429 naming a reset but no window must still be recorded, and jq
# aborts on indexing an object with null — taking the whole wall row with it.
assert grep -Fq 'def ceiling($w): {"5-hour":21600,"weekly":691200,"monthly":2764800}[$w // ""] // 604800;' \
  "$OPENCODE_GO"
assert grep -Fq 'WALL_WINDOW_MAX_TTL_S.get(window, WALL_MAX_TTL_S)' "$REVIEWBENCH"
assert doc_has '`5-hour` 21600s, `weekly` 691200s, `monthly` 2764800s, unnamed 604800s'

# The reset-phrase grammar is the second rule, pinned by behaviour rather than by spelling: the
# wordings below are real 429 bodies, and a side that reads only spelled-out units records nothing
# for most of them while the other records a horizon. Every stated horizon here is inside its own
# window's ceiling, so what the two sides are compared on is the grammar alone.
WALL_GRAMMAR=$(mktemp -d)
sed -n '/^wall_row()/,/^}/p' "$OPENCODE_GO" >"$WALL_GRAMMAR/wall_row.sh"
cat >"$WALL_GRAMMAR/corpus" <<'CORPUS'
weekly|34200|Weekly usage limit reached. Resets in 9hr 30min. To continue using this model now, x
5h|12480|5-hour usage limit reached. Resets in 3hr 28min. x
5h|180|5-hour usage limit reached. Resets in 3min. x
weekly|2520|Weekly usage limit reached. Resets in 42min. x
weekly|86400|Weekly usage limit reached. Resets in 1 day. x
weekly|345600|Weekly usage limit reached. Resets in 4 days. x
monthly|1728000|Monthly usage limit reached. Resets in 20 days. x
weekly|3600|Weekly usage limit reached. Resets in 1 hour. x
weekly|none|Weekly usage limit reached. Upgrade to Pro for more usage.
CORPUS
grammar_expected=$(cut -d'|' -f2 "$WALL_GRAMMAR/corpus" | paste -sd, -)
grammar_go=$(while IFS='|' read -r window _ message; do
  printf 'GoUsageLimitError limitName=%s. %s\n' "$window" "$message" >"$WALL_GRAMMAR/body"
  KEY_SERVICE=opencode-go bash -c '
    . "$1/wall_row.sh"
    wall_row 1000000 "$1/body" |
      jq -r "if has(\"reset_at\") then .reset_at - .detected_at else \"none\" end"' _ "$WALL_GRAMMAR"
done <"$WALL_GRAMMAR/corpus" | paste -sd, -)
grammar_rb=$(python3 - "$REVIEWBENCH" "$WALL_GRAMMAR/corpus" <<'GRAMMAR'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
rb = importlib.util.module_from_spec(spec)
loader.exec_module(rb)
# The clock is pinned to the same instant the jq side is handed, or the two sides are compared
# on different nows: reading it again after the parse rounds a horizon down by a second whenever
# the two calls straddle one, and the guard fails on a grammar that never changed.
NOW = 1000000.0
rb.time.time = lambda: NOW
stated = []
with open(sys.argv[2]) as corpus:
    for line in corpus:
        message = line.rstrip("\n").split("|", 2)[2]
        at = rb.wall_reset_at(message)
        stated.append("none" if at is None else str(round(at - NOW)))
print(",".join(stated))
GRAMMAR
)
assert eq "$grammar_go" "$grammar_expected"
assert eq "$grammar_rb" "$grammar_expected"
rm -rf "$WALL_GRAMMAR"

# The account a wall is filed under is the plan's keychain service, spelled in three languages —
# and llm-limits.sh is the one that maps it back to the profile every surface displays.
assert grep -Fq 'KEY_SERVICE="opencode-go${OPENCODE_GO_PROFILE:+-$OPENCODE_GO_PROFILE}"' "$OPENCODE_GO"
assert grep -Fq 'return "opencode-go" if profile == "-" else f"opencode-go-{profile}"' "$REVIEWBENCH"
assert grep -Fq 'opencode_service="opencode-go-$opencode_profile"' "$LLMLIMITS"
assert grep -Fq 'opencode_service=opencode-go' "$LLMLIMITS"
# A served call is the opposite evidence, and the menubar reads neither file any more.
assert grep -Fq 'SEEN_FILE=$WALL_STATE_DIR/opencode-seen/$KEY_SERVICE' "$OPENCODE_GO"
assert grep -Fq 'opencode_state_dir/opencode-seen/$opencode_service' "$LLMLIMITS"
# Only a served completion stamps, and no writer ever takes a row back out: a probe that clears a
# wall by rewriting the record instead of stamping loses every 429 filed beside it.
assert eq "$(grep -c 'mark_served' "$OPENCODE_GO")" 2
assert grep -Fq '[[ $kind == completion ]] || return 0' "$OPENCODE_GO"
assert eq "$(grep -cE "^ *(>|:>|rm -f|mv ).*WALLS_FILE" "$OPENCODE_GO")" 0
assert eq "$(grep -c "$WALL_FILE" "$HAMMER")" 0
assert eq "$(grep -c 'opencode-seen' "$HAMMER")" 0

assert doc_has 'Usage wall record'
assert doc_has 'capped once, by the writer, to the horizon its own window can reach'
assert doc_has '`${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}/walls.jsonl`'
assert doc_has 'The file holds RAW observations and nothing else'
assert doc_has '`opencode-go` for the default profile and `opencode-go-<profile>` otherwise'
assert doc_has 'NO writer ever retires an OpenCode row by the clock'
assert doc_has 'The one counter-evidence is a completion the plan SERVED'
assert doc_has "is not bound by this row's retirement rule"


# --- Row aj: per-vendor role switches -----------------------------------------
# `<vendor>_<role>=off`, absent key = on, is spoken by four independent implementations. The vendor
# and role tokens are spelled once here and every implementation is asked whether it means the same
# thing; a drifted one leaves the menu showing a switch the routers do not read.
ROLE_VENDORS="claudeb codex gemini"
ROLE_ROLES="workers reviewers"
ROLE_WORK=$(mktemp -d)
ROLE_MODEL="$ROLE_WORK/worker-model"
# The writer refuses a session outright, and this suite usually runs inside one.
set_role() {
  env -u CLAUDECODE WORKER_PICK_CONFIG_FILE="$ROLE_MODEL" \
    bash -c '. "$1"; worker_model_set_role "$2" "$3" "$4"' _ "$WORKER_MODEL_SH" "$1" "$2" "$3"
}
# The writer, asked for every pair the readers know.
for vendor in $ROLE_VENDORS; do
  for role in $ROLE_ROLES; do
    rm -f "$ROLE_MODEL"
    set_role "$vendor" "$role" off ||
      fail "row aj: share/worker-model.sh refuses ${vendor} ${role}, a pair bin/worker-pick and hammerspoon/llm-limits.lua read"
    assert eq "$(cat "$ROLE_MODEL")" "${vendor}_${role}=off"
  done
done

# The reader in bin/worker-pick, asked through the binary: an empty limits file is enough, because
# a closed role is refused before any account is looked at.
printf '{}\n' >"$ROLE_WORK/limits.json"
role_pick() {
  env LLM_LIMITS_FILE="$ROLE_WORK/limits.json" WORKER_PICK_CONFIG_FILE="$ROLE_MODEL" \
    WORKER_PICK_TIERS_FILE="$ROLE_WORK/tiers" WORKER_PICK_CACHE_DIR="$ROLE_WORK/cache" \
    WORKER_PICK_NOW=1000000 CLAUDEB_DIR="$ROLE_WORK/claudeb" \
    "$WORKERPICK" --account "$1" --role "$2" 2>&1 >/dev/null
}
for vendor in $ROLE_VENDORS; do
  for role in $ROLE_ROLES; do
    printf '%s_%s=off\n' "$vendor" "$role" >"$ROLE_MODEL"
    role_out=$(role_pick "$vendor" "$role") &&
      fail "row aj: bin/worker-pick answered $vendor for $role while share/worker-model.sh had written ${vendor}_${role}=off: reader and writer disagree on the key"
    grep -Fq "$vendor is switched off for $role" <<<"$role_out" ||
      fail "row aj: bin/worker-pick's refusal for ${vendor}_${role} names neither the vendor nor the role share/worker-model.sh wrote: $role_out"
    # Only the literal "off" is a veto, which is what hammerspoon/llm-limits.lua and
    # bin/review-bench read; anything else is the open state the absent key means.
    printf '%s_%s=on\n' "$vendor" "$role" >"$ROLE_MODEL"
    grep -Fq 'is switched off' <<<"$(role_pick "$vendor" "$role")" &&
      fail "row aj: bin/worker-pick vetoes ${vendor}_${role}=on, while share/worker-model.sh and hammerspoon/llm-limits.lua treat only \"off\" as closed"
  done
done
# The two role tokens are two switches, not one.
printf 'claudeb_workers=off\n' >"$ROLE_MODEL"
grep -Fq 'switched off' <<<"$(role_pick claudeb reviewers)" &&
  fail "row aj: bin/worker-pick refused a reviewers query on a claudeb_workers=off line: its role_off() drops the role token hammerspoon/llm-limits.lua and bin/review-bench key on"

# The stderr contract: bin/worker-run reroutes on a line bin/worker-pick prints, so the consumer's
# own grep pattern is run against the producer's live output.
role_run_grep=$(sed -n "s/.*grep -q '\([^']*switched off[^']*\)'.*/\1/p" "$WORKER_RUN" | head -n1)
[ -n "$role_run_grep" ] ||
  fail "row aj: bin/worker-run no longer greps a 'switched off' line out of bin/worker-pick's stderr: the workers wall it reroutes on became unreadable"
printf 'claudeb_workers=off\n' >"$ROLE_MODEL"
role_out=$(role_pick claudeb workers)
grep -q -- "$role_run_grep" <<<"$role_out" ||
  fail "row aj: bin/worker-run greps '$role_run_grep' but bin/worker-pick prints '$role_out': the workers-wall stderr contract between them drifted"

# The reader in hammerspoon/llm-limits.lua, at the two tables the menu builds keys from.
lua_prefixes=$(grep -E '^local WORKER_MODEL_PREFIX = ' "$HAMMER" | head -n1)
[ -n "$lua_prefixes" ] ||
  fail "row aj: hammerspoon/llm-limits.lua has no WORKER_MODEL_PREFIX table, so the keys share/worker-model.sh writes are built somewhere else now"
for vendor in $ROLE_VENDORS; do
  grep -Fq "\"$vendor\"" <<<"$lua_prefixes" ||
    fail "row aj: hammerspoon/llm-limits.lua's WORKER_MODEL_PREFIX lacks the $vendor prefix that share/worker-model.sh writes ${vendor}_ keys with"
done
lua_roles=$(grep -E '^local WORKER_ROLES = ' "$HAMMER" | head -n1)
[ -n "$lua_roles" ] ||
  fail "row aj: hammerspoon/llm-limits.lua has no WORKER_ROLES table, so the menu no longer enumerates the roles share/worker-model.sh accepts"
for role in $ROLE_ROLES; do
  grep -Fq "\"$role\"" <<<"$lua_roles" ||
    fail "row aj: hammerspoon/llm-limits.lua's WORKER_ROLES lacks the $role token that share/worker-model.sh writes and bin/worker-pick reads"
done
assert_role_hammer() {
  asserts=$((asserts + 1))
  grep -Fq "$1" "$HAMMER" ||
    fail "row aj: hammerspoon/llm-limits.lua no longer $2, so its menu and share/worker-model.sh's keys drifted"
}
assert_role_hammer 'key == prefix .. "_" .. role' 'builds keys as <vendor>_<role>'
assert_role_hammer 'value ~= "off"' 'reads "off" as the only veto'

# The reader in bin/review-bench, asked through its own functions: it reads the reviewers half.
role_bench_out=$(python3 - "$REVIEWBENCH" "$ROLE_MODEL" "$ROLE_VENDORS" 2>&1 <<'PY'
import importlib.machinery
import importlib.util
import os
import sys

bench, config, vendors = sys.argv[1], sys.argv[2], sys.argv[3].split()
os.environ["WORKER_PICK_CONFIG_FILE"] = config
loader = importlib.machinery.SourceFileLoader("review_bench", bench)
spec = importlib.util.spec_from_loader("review_bench", loader)
rb = importlib.util.module_from_spec(spec)
loader.exec_module(rb)

if sorted(set(rb.SIDE_POOL_VENDOR.values())) != sorted(vendors):
    sys.exit("bin/review-bench SIDE_POOL_VENDOR maps to %s, not the vendors share/worker-model.sh "
             "writes keys for (%s)" % (sorted(set(rb.SIDE_POOL_VENDOR.values())), vendors))
for side, vendor in sorted(rb.SIDE_POOL_VENDOR.items()):
    def write(line):
        with open(config, "w", encoding="utf-8") as handle:
            handle.write(line)
    write("%s_reviewers=off\n" % vendor)
    if not rb.reviewers_role_off(side):
        sys.exit("bin/review-bench misses the %s_reviewers=off line share/worker-model.sh writes, "
                 "so side %s staffs a vendor bin/worker-pick refuses" % (vendor, side))
    if "is switched off for reviewers" not in rb.role_closed_note(side):
        sys.exit("bin/review-bench words the closed %s reviewers switch differently from "
                 "bin/worker-pick's stderr: %r" % (vendor, rb.role_closed_note(side)))
    write("%s_workers=off\n" % vendor)
    if rb.reviewers_role_off(side):
        sys.exit("bin/review-bench reads %s_workers=off as a reviewers veto: it drops the role "
                 "token bin/worker-pick and hammerspoon/llm-limits.lua key on" % vendor)
    write("%s_reviewers=on\n" % vendor)
    if rb.reviewers_role_off(side):
        sys.exit("bin/review-bench vetoes %s_reviewers=on, while share/worker-model.sh and "
                 "bin/worker-pick treat only \"off\" as closed" % vendor)
PY
) || fail "row aj: $role_bench_out"
asserts=$((asserts + 1))
rm -rf "$ROLE_WORK"
# The reviewers query asks worker-pick for the role, rather than reading the switch as a decision.
assert grep -Fq '"--account", SIDE_POOL_VENDOR[side], "--role", "reviewers"' "$REVIEWBENCH"
assert doc_has 'Per-vendor role switches'
assert doc_has '`worker-pick: <vendor> is switched off for <role>`'
assert doc_has '`cb⏸off`/`cx⏸off`/`gx⏸off`'

# --- Row ak: auto-refresh vendor roster --------------------------------------
# The roster is spelled three times inside one daemon, and a vendor present in the loop but missing
# from the seed reads as a null rung on every tick while one missing from the validator throws away
# every state file written before it existed. The fourth vendor is the inverted one: it has no usage
# endpoint, so anything that would make it poll on the other three's cadence spends the plan.
LLMREFRESH="$ROOT/bin/llm-refresh"
REFRESH_VENDORS="claude codex gemini opencode"
refresh_seed=$(grep -n '| map(. as $vendor |' "$LLMREFRESH" | head -n1 | cut -d: -f1)
[ -n "$refresh_seed" ] ||
  fail "row ak: bin/llm-refresh's normalized_state no longer seeds a vendor list"
refresh_seed=$(sed -n "${refresh_seed}p" "$LLMREFRESH")
refresh_loop=$(grep -E '^  for vendor in ' "$LLMREFRESH" | head -n1)
refresh_validator=$(grep -F '.claude and .codex and .gemini' "$LLMREFRESH" | head -n1)
[ -n "$refresh_loop" ] && [ -n "$refresh_validator" ] ||
  fail "row ak: bin/llm-refresh's tick loop or state validator no longer spells its vendors"
for vendor in $REFRESH_VENDORS; do
  assert grep -Fq "\"$vendor\"" <<<"$refresh_seed"
  assert grep -Fq " $vendor" <<<"$refresh_loop"
  assert grep -Fq ".$vendor" <<<"$refresh_validator"
done

# The inversion, asked of the daemon rather than of its prose: the wall state comes from the
# collector row (row al), never from the record, and only a standing wall is probed — through the
# one subcommand that answers for free while the window is shut.
assert grep -Fq 'opencode-go' <<<"$(grep -F 'opencode_go=' "$LLMREFRESH")"
assert grep -Fq 'wall-check' "$LLMREFRESH"
assert grep -Fq '.vendors.opencode.accounts[]? | select(.walled == true)' "$LLMREFRESH"
assert eq "$(grep -c "$WALL_FILE" "$LLMREFRESH")" 0
refresh_tighten=$(grep -E '^OPENCODE_TIGHTEN_WITHIN_S=' "$LLMREFRESH" | sed -E 's/^[^=]+=//')
assert eq "$refresh_tighten" 3600
assert doc_has '`OPENCODE_TIGHTEN_WITHIN_S` (`3600`s)'

REFRESH_WORK=$(mktemp -d)
mkdir -p "$REFRESH_WORK/home"
cat >"$REFRESH_WORK/opencode-go" <<'REFRESH_STUB'
#!/usr/bin/env bash
printf 'probed\n' >>"$OC_LOG"
REFRESH_STUB
chmod +x "$REFRESH_WORK/opencode-go"
printf '#!/usr/bin/env bash\nexit 0\n' >"$REFRESH_WORK/collector"
chmod +x "$REFRESH_WORK/collector"
# Every fixture store carries a default Claude row, and a stale one now escalates to
# `claudeb revive`; the real binary announces a collect that would rewrite this store.
printf '#!/usr/bin/env bash\nexit 0\n' >"$REFRESH_WORK/claudeb"
chmod +x "$REFRESH_WORK/claudeb"
refresh_store() { # <walled>
  jq -cn --argjson walled "$1" --arg reset "$2" \
    '{schema:1,vendors:{opencode:{source:"opencode-go",accounts:[
       {account:"-",walled:$walled,
        windows:(if $walled then [{window:"wk",resets_at:$reset}] else [] end)}]}}}' \
    >"$REFRESH_WORK/store.json"
}
run_refresh_tick() {
  env HOME="$REFRESH_WORK/home" \
    LLM_REFRESH_COLLECTOR="$REFRESH_WORK/collector" \
    LLM_LIMITS_CACHE="$REFRESH_WORK/store.json" \
    LLM_REFRESH_STATE="$REFRESH_WORK/state.json" \
    LLM_REFRESH_JOURNAL="$REFRESH_WORK/journal.jsonl" \
    LLM_LIMITS_REFRESH_OPENCODE_GO="$REFRESH_WORK/opencode-go" \
    LLM_LIMITS_REFRESH_CLAUDEB="$REFRESH_WORK/claudeb" \
    OC_LOG="$REFRESH_WORK/probes.log" LLM_REFRESH_NOW="$1" bash "$LLMREFRESH"
}
printf '{"vendors":{}}\n' >"$REFRESH_WORK/state.json"
refresh_now=$(date +%s)
refresh_store false ''
run_refresh_tick "$refresh_now" ||
  fail "row ak: bin/llm-refresh could not run a tick with no wall on record"
[ ! -e "$REFRESH_WORK/probes.log" ] ||
  fail "row ak: bin/llm-refresh sent an OpenCode completion with no wall standing, spending the plan to learn what llm-limits.sh already answered"
asserts=$((asserts + 1))
refresh_store true "$(date -u -r "$((refresh_now + 172800))" '+%Y-%m-%dT%H:%M:%SZ')"
rm -f "$REFRESH_WORK/state.json"
run_refresh_tick "$refresh_now" ||
  fail "row ak: bin/llm-refresh could not run a tick against a standing wall"
assert grep -Fqx probed "$REFRESH_WORK/probes.log"
rm -rf "$REFRESH_WORK"
assert doc_has 'Auto-refresh vendor roster'
assert doc_has 'only a standing wall is probed'
# Three probe answers, never two: folding "nothing was sent" into "served" reports a leg recovered
# on a request nobody made, and holding the tick lock across the probe parks the other three vendors.
refresh_probe_case=$(sed -n '/case "${probe%% \*}" in/,/esac/p' "$LLMREFRESH")
for probe_state in 'walled)' 'served)' 'dormant=$((dormant + 1))'; do
  assert grep -Fq "$probe_state" <<<"$refresh_probe_case"
done
assert grep -Fq 'refresh_lock_release' \
  <<<"$(grep -B2 -F 'opencode_result=$(opencode_tick' "$LLMREFRESH")"
assert doc_has 'read as one of three states and never two'
assert doc_has 'The tick lock is handed back for the duration of the probe'

# --- Row al: OpenCode rows in the limits store --------------------------------
# The Go plan states no usage figure, so whether a wall still stands is the only reading there is
# and llm-limits.sh computes it once. Every other surface renders those rows; a second answer to
# that question is a menubar that disagrees with the daemon spending the plan.
OC_WORK=$(mktemp -d)
mkdir -p "$OC_WORK/state" "$OC_WORK/home"
printf -- '-\nevyoxqy\nlapsed\n' >"$OC_WORK/profiles"
oc_now=$(date +%s)
{
  jq -cn --argjson d "$((oc_now - 600))" --argjson r "$((oc_now + 172800))" \
    '{side:"opencode",account:"opencode-go-evyoxqy",bucket:"general",detected_at:$d,
      reset_at:$r,window:"weekly"}'
  jq -cn --argjson d "$((oc_now - 172800))" --argjson r "$((oc_now - 3600))" \
    '{side:"opencode",account:"opencode-go",bucket:"general",detected_at:$d,
      reset_at:$r,window:"5-hour"}'
  jq -cn --argjson d "$((oc_now - 259200))" --argjson r "$((oc_now - 7200))" \
    '{side:"opencode",account:"opencode-go-lapsed",bucket:"general",detected_at:$d,
      reset_at:$r,window:"weekly"}'
} >"$OC_WORK/state/walls.jsonl"
mkdir -p "$OC_WORK/state/opencode-seen"
printf '%s\n' "$((oc_now - 120))" >"$OC_WORK/state/opencode-seen/opencode-go"
oc_rows=$(HOME="$OC_WORK/home" WORKER_STATS_DIR="$OC_WORK/state" \
  OPENCODE_GO_PROFILES="$OC_WORK/profiles" LLM_LIMITS_CACHE="$OC_WORK/cache.json" \
  bash "$LLMLIMITS" --json 2>/dev/null | jq -c '.vendors.opencode')
[ -n "$oc_rows" ] || fail 'row al: llm-limits.sh emitted no OpenCode vendor'
assert eq "$(jq -r '.accounts | map(.account) | join(",")' <<<"$oc_rows")" '-,evyoxqy,lapsed'
# The rule holds no clock: a completion the plan served since the refusal opens the account, and a
# horizon two hours past keeps the wall standing because the gateway dates its resets to the day.
assert eq "$(jq -r '.accounts[0].walled' <<<"$oc_rows")" false
assert eq "$(jq -r '.accounts[1].walled' <<<"$oc_rows")" true
assert eq "$(jq -r '.accounts[2].walled' <<<"$oc_rows")" true
# The age a row carries is the served stamp alone, so an account that has only ever refused has none.
assert eq "$(jq -r '.accounts[0].as_of | fromdateiso8601' <<<"$oc_rows")" "$((oc_now - 120))"
assert eq "$(jq -r '.accounts[2] | has("as_of")' <<<"$oc_rows")" false
# >= and not >: a refusal and a served call in the same second must keep the wall, because only a
# standing wall is probed by the scheduled refresh — read as served, the account freezes clean forever.
assert grep -Fq '.detected_at >= $served' "$LLMLIMITS"
# The bench pool asks the same question of the same two files, in the same order — rows dropped
# below the stamp, then the standing window. Two readers, one answer, or the menu shows an account
# clean while every review refuses its leg for a day (2026-08-15, opencode-go-dioqktn).
assert grep -Fq 'rows = [row for row in rows if row[0] >= stamp]' "$REVIEWBENCH"
assert grep -Fq 'OPENCODE_SEEN_DIR = "opencode-seen"' "$REVIEWBENCH"
# Digits only on both sides: a garbled stamp is not evidence of a completion, and read as one it
# would open a plan that is still refusing.
assert grep -Fq "tr -dc '0-9'" "$LLMLIMITS"
assert grep -Fq 'char for char in raw if char in "0123456789"' "$REVIEWBENCH"
oc_filter_line=$(grep -n -F 'rows = [row for row in rows if row[0] >= stamp]' "$REVIEWBENCH" | cut -d: -f1)
oc_standing_line=$(grep -n -F 'wall = standing_wall(rows)' "$REVIEWBENCH" | cut -d: -f1)
assert test "$oc_filter_line" -lt "$oc_standing_line"
assert doc_has 'That comparison has TWO implementations and they must stay spelled alike'
assert doc_has 'the served stamp binds BOTH readers'
assert eq "$(jq -r '.accounts[1].windows | map(.window) | join(",")' <<<"$oc_rows")" wk
assert eq "$(jq -r '.accounts[1].windows[0].resets_at | fromdateiso8601' <<<"$oc_rows")" \
  "$((oc_now + 172800))"
# No percentage exists on this plan, so no surface may find one to render.
assert eq "$(jq '[.. | objects | select(has("used_pct") or has("effective_pct"))] | length' <<<"$oc_rows")" 0
rm -rf "$OC_WORK"

# The window marks and the undated ceiling live in the collector and its shared view, and the
# renderers speak the same three names back.
assert grep -Fq 'def marks: {"5-hour":"5h","weekly":"wk","monthly":"mo"};' "$LLMLIMITS"
assert grep -Fq '["5h","wk","mo","?"]' "$LLMLIMITS"
assert eq "$(cat "$ROOT/share/limits-view.sh" "$LLMLIMITS" | grep -c 'limits_opencode_undated_ttl')" 0
# The renderers read the row and derive nothing: the fields they read are pinned to the ones emitted.
for oc_field in account walled windows as_of; do
  assert grep -Fq "account.$oc_field" "$HAMMER"
done
assert grep -Fq 'limits.vendors.opencode' "$HAMMER"
assert grep -Fq '.vendors.opencode.accounts[]?' "$LLMREFRESH"
assert grep -Fq '.vendors.opencode.accounts[]?' "$OPENCODE_GO"
assert doc_has 'OpenCode rows in the limits store'
assert doc_has 'whether a recorded wall (row `ai`) still stands is computed HERE'
assert doc_has 'a horizon already past retires nothing'
assert doc_has 'only a completion the plan served ever ends it'
# The leg's one refresh action, spelled the same in the menu and in the probe it calls. The click
# spends a completion on clear accounts on purpose; anything scheduled must not, so the daemon
# carries no such flag at all.
assert grep -Fq '"wall-check", "--all", "--probe-clear" }' "$HAMMER"
assert grep -Fq 'wall_check_all()' "$OPENCODE_GO"
assert grep -Fq -- '--probe-clear' "$OPENCODE_GO"
assert eq "$(grep -c -- '--probe-clear' "$LLMREFRESH")" 0
assert doc_has 'The daemon never passes `--probe-clear`'
assert doc_has '`wall-check --all --probe-clear`, which walks the roster file instead of the walled rows'
# That flag walks the roster instead of the rows, so every reader of that file must parse it alike:
# a profile one of them drops is an account the menu renders and the refresh never asks — and the
# bench pool is the third, running cells on whatever roster it read.
for oc_site in "$LLMLIMITS" "$OPENCODE_GO"; do
  assert grep -Fq 'OPENCODE_GO_PROFILES:-' "$oc_site"
  assert grep -Fq "grep -v -e '^#' -e '^\$'" "$oc_site"
  assert grep -Fq "printf -- '-\\n'" "$oc_site"
done
assert grep -Fq 'os.environ.get("OPENCODE_GO_PROFILES")' "$REVIEWBENCH"
bench_roster() {
  OPENCODE_GO_PROFILES="$1" python3 - "$REVIEWBENCH" <<'OC_ROSTER_READER'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("review_bench", sys.argv[1])
rb = importlib.util.module_from_spec(importlib.util.spec_from_loader("review_bench", loader))
loader.exec_module(rb)
print(",".join(rb.opencode_profiles()))
OC_ROSTER_READER
}
OC_ROSTER=$(mktemp -d)
mkdir -p "$OC_ROSTER/home" "$OC_ROSTER/state"
# A comment, an indented name and a trailing blank line: the shapes a hand-edited roster actually
# carries, and each one is a whole account if two readers disagree about it.
printf '# primary accounts\n-\n  evyoxqy\n\n' >"$OC_ROSTER/profiles"
oc_menu_roster=$(HOME="$OC_ROSTER/home" WORKER_STATS_DIR="$OC_ROSTER/state" \
  OPENCODE_GO_PROFILES="$OC_ROSTER/profiles" LLM_LIMITS_CACHE="$OC_ROSTER/cache.json" \
  bash "$LLMLIMITS" --json 2>/dev/null | jq -r '[.vendors.opencode.accounts[].account] | join(",")')
assert eq "$oc_menu_roster" '-,evyoxqy'
assert eq "$(bench_roster "$OC_ROSTER/profiles")" "$oc_menu_roster"
# An absent roster is the single default account on every reader, never an empty pool.
assert eq "$(bench_roster "$OC_ROSTER/nothing-here")" '-'
rm -rf "$OC_ROSTER"

# --- Row am: worker files reach the launching chat ----------------------------
# Two repositories on one wire, and it is a record on disk rather than a printed report: worker-run
# stamps the launching chat beside the run and writes the run's files under a WORKDIR line, the
# journal hook sweeps the runs stamped with its own session, and the gate reads the same records for
# the runs whose files no vendor could name. Rename one side and the files a chat's worker authored
# fall silently out of its review coverage — the failure looks like a chat that only ever edited one
# file by hand.
WORKER_RUN="$ROOT/bin/worker-run"
assert grep -Fq '>"$directory/launcher"' "$WORKER_RUN"
assert grep -Fq "printf 'WORKDIR: %s\\n' \"\$workdir\"" "$WORKER_RUN"
assert grep -Fq "printf 'UNKNOWN: %s\\n' \"\$RUN_FILES_REASON\"" "$WORKER_RUN"
assert grep -Fq "printf 'PARTIAL: %s\\n' \"\$RUN_FILES_PARTIAL\"" "$WORKER_RUN"
assert grep -Fq 'mv -f "$directory/files.tmp.$$" "$directory/files"' "$WORKER_RUN"
# The third reader: a waiver naming no path must drop the files a co-tenant's worker run claims,
# which it can only do by looking in the same directory the other two sweep.
REVIEWBENCH_RUNS="$ROOT/bin/review-bench"
rb_run_root=$(sed -n '/^def worker_run_root():/,/^$/p' "$REVIEWBENCH_RUNS" |
  sed -n 's|.*Path.home() / "\(.*\)" / "\(.*\)")$|\1/\2|p' | head -1)
worker_run_root=$(grep -oE 'WORKER_RUN_DIR:-\$HOME/[^}]*' "$WORKER_RUN" | head -1 | sed 's|.*\$HOME/||')
assert eq "$rb_run_root" '.cache/claude-worker-runs'
assert eq "$worker_run_root" "$rb_run_root"
assert grep -Fq 'os.environ.get("WORKER_RUN_DIR")' "$REVIEWBENCH_RUNS"
assert grep -Fq 'if not launcher or (directory / "journaled").exists():' "$REVIEWBENCH_RUNS"
assert doc_has 'Worker files reach the launching chat'
assert doc_has 'whose first line is `WORKDIR: <dir>`'
assert doc_has '`<run-dir>/noticed`'
COMMIT_JOURNAL="$CLAUDE_SETUP/hooks/commit-journal.sh"
if [ -r "$COMMIT_JOURNAL" ]; then
  assert grep -Fq 'grep -l -x -F -- "$session" "$runs"/*/launcher' "$COMMIT_JOURNAL"
  assert grep -Fq "'WORKDIR: '*) run_workdir=\${line#WORKDIR: }" "$COMMIT_JOURNAL"
  assert grep -Fq "'UNKNOWN: '*|'PARTIAL: '*|'') ;;" "$COMMIT_JOURNAL"
  # The two rules that keep a record from being claimed twice or claimed early: a run with no
  # exit_code has no final list yet unless its supervisor is gone, and one already imported is
  # marked as imported.
  assert grep -Fq 'if [ ! -f "$directory/exit_code" ]; then' "$COMMIT_JOURNAL"
  assert grep -Fq 'kill -0 "$pid" 2>/dev/null && continue' "$COMMIT_JOURNAL"
  assert grep -Fq ': >"$directory/journaled"' "$COMMIT_JOURNAL"
else
  printf 'SKIP: worker files reach the launching chat (%s is unreadable)\n' "$COMMIT_JOURNAL"
fi
REVIEW_GATE="$CLAUDE_SETUP/hooks/review-flow-gate.sh"
if [ -r "$REVIEW_GATE" ]; then
  assert grep -Fq "sed -n 's/^UNKNOWN: //p' \"\$listing\"" "$REVIEW_GATE"
  assert grep -Fq "sed -n 's/^PARTIAL: //p' \"\$listing\"" "$REVIEW_GATE"
  assert grep -Fq 'grep -l -x -F -- "$session" "$runs"/*/launcher' "$REVIEW_GATE"
  # A record the journal has not taken over is still this chat's pending work, and a run named once
  # is retired by a marker rather than by a clock over a HEAD any co-tenant moves.
  assert grep -Fq "'WORKDIR: '*|'UNKNOWN: '*|'PARTIAL: '*|'') continue ;;" "$REVIEW_GATE"
  assert grep -Fq '[ -e "$directory/journaled" ] && continue' "$REVIEW_GATE"
  assert grep -Fq ': >"$item/noticed"' "$REVIEW_GATE"
else
  printf 'SKIP: the gate reads the same run records (%s is unreadable)\n' "$REVIEW_GATE"
fi

# --- Row an: launching-chat pid walk ------------------------------------------
# The same walk in bash and in python, and a drift between them is silent: the writer records a
# session the reader would never have resolved the same way, and a run renders in the statusline of
# the wrong chat or of none.
REVIEWBENCH="$ROOT/bin/review-bench"
walk_hops_bash=$(grep -oE '\[ "\$hops" -lt [0-9]+ \]' "$STATUSLINE" | grep -oE '[0-9]+')
walk_hops_py=$(grep -oE '^SESSION_WALK_HOPS = [0-9]+' "$REVIEWBENCH" | grep -oE '[0-9]+')
assert eq "$walk_hops_bash" 15
assert eq "$walk_hops_py" "$walk_hops_bash"
assert doc_has 'at most `15` hops and stopping at pid 1'
assert grep -Fq 'ps -o ppid= -p' "$STATUSLINE"
assert grep -Fq '["ps", "-o", "ppid=", "-p", str(pid)]' "$REVIEWBENCH"
assert grep -Fq '$HOME/.claude/sessions/$pid.json' "$STATUSLINE"
assert grep -Fq 'Path.home() / ".claude" / "sessions"' "$REVIEWBENCH"
assert grep -Fq 'f"{pid}.json"' "$REVIEWBENCH"
for walk_site in "$STATUSLINE" "$REVIEWBENCH"; do
  assert grep -Fq 'sessionId' "$walk_site"
done
assert grep -Fq 'REVIEW_BENCH_SESSION_DIR' "$REVIEWBENCH"
# Precedence, not just the walk: the recorded session answers first on both sides, or the fallback
# becomes the answer and a backgrounded run — whose parents are gone — is attributed to nobody.
assert grep -Fq 'session=progress_session' "$REVIEWBENCH"
assert grep -Fq 'review_run_owner "$progress_run_session" "$progress_pid"' "$STATUSLINE"
assert doc_has 'the recorded `session` first, the walk as the fallback'


printf 'PASS: %s asserts; shared invariants agree across sites (staleness thresholds, keychain formula, worker-pick cache format, weather HTTP classes, OAuth 429 cooldown, token-freeze semantics, Codex/Gemini main-last priority, Antigravity review cell models, Gemini worker knobs, worker account resolution, quota-group matching, shared profile mapping, weekly bucket provenance, Claude rotation usability presence, reserved profile names, worker spawn pressure gate, worker-pool membership, user-entry refresh classification, review receipt schema, late review thresholds, account data age, owner-only review panels, claude account existence, one limits view, lens registry location, the Hammerspoon launchd agent identity, the review report frame both repositories build, the account pin no session may move without Egor naming it, the one voice that says what a review round earned, the debt word the bench prints, the gate translates and the statusline speaks verbatim, the journal that records whose debt a commit landed, the round-size numbers that lock a waiver, the usage wall record both of its writers share, the per-vendor role switches the routers, the menu and the bench all read, the auto-refresh roster whose fourth vendor is polled only where polling is free, the OpenCode rows whose standing wall the collector and the bench pool read off one served stamp, the run record that carries a worker'"'"'s files into the journal of the chat that launched it, and the launching-chat pid walk the progress writer runs once and the statusline only falls back to) and match %s\n' "$asserts" "$DOC"
