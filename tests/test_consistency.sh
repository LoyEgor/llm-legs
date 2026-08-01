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
LIMITSD="$ROOT/bin/llm-limitsd"
SHADOW_FEED="$ROOT/bin/llm-limitsd-shadow-feed"
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

# doc prose carries all three
assert doc_has '`1800`s'
assert doc_has '`21600`s'

# claudeb account_data jq
cb_five=$(grep -oE 'is_stale\(\.five_hour; [0-9]+\)' "$CLAUDEB" | grep -oE '[0-9]+')
cb_week=$(grep -oE 'is_stale\(\.seven_day; [0-9]+\)' "$CLAUDEB" | grep -oE '[0-9]+')
cb_fable=$(grep -oE 'is_stale\(\.fable; [0-9]+\)' "$CLAUDEB" | grep -oE '[0-9]+')
assert eq "$cb_five" "$FIVE"
assert eq "$cb_week" "$WEEK"
assert eq "$cb_fable" "$FABLE"

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
assert test "$(grep -Fc 'sort_by(.main_last, -.score, .name)' "$WORKERPICK")" -eq 2
assert grep -Fq 'def display_band($selected; $eligible; $soft_skipped): if .name == $selected then 0 elif $eligible then 1 elif $soft_skipped then 2 else 3 end;' "$WORKERPICK"
assert test "$(grep -Fc 'sort_by(display_band(' "$WORKERPICK")" -eq 5
assert grep -Fq 'main_last:(if $entry.account == "main" then 1 else 0 end)' "$CODEXB"
assert grep -Fq 'sort -t $'\''\t'\'' -k2,2n -k3,3n -k4,4n -k1,1' "$CODEXB"
assert grep -Fq 'Codex and Gemini `main` profiles as last-resort' "$POLICY"
assert doc_has 'Codex/Gemini base-profile priority'

REVIEWBENCH="$ROOT/bin/review-bench"
for mapping in \
  '"agy-pro": "Gemini 3.1 Pro"' \
  '"agy-flash36": "gemini-3.6-flash"' \
  '"agy-flash35": "gemini-3.5-flash"'; do
  assert grep -Fq -- "$mapping" "$REVIEWBENCH"
done
assert grep -Fq '"agy-pro": ("low", "high")' "$REVIEWBENCH"
assert grep -Fq '"agy-flash36": ("low", "medium", "high")' "$REVIEWBENCH"
assert grep -Fq '"agy-flash35": ("low", "medium", "high")' "$REVIEWBENCH"
assert grep -Fq 'agy-pro-<low|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash36-<low|medium|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash35-<low|medium|high>' "$ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'if rater["model"] == "agy-flash35":' "$REVIEWBENCH"
assert grep -Fq 'return f"{model}-{rater['\''effort'\'']}"' "$REVIEWBENCH"
assert grep -Fq 'if rater["model"] not in ("agy-flash35", "agy-pro"):' "$REVIEWBENCH"
assert doc_has '`agy-pro-<effort>` → `--model "Gemini 3.1 Pro (<Effort>)"` with no `--effort` flag'
assert grep -Fq 'if rater["model"] == "agy-pro":' "$REVIEWBENCH"
assert doc_has '`agy-flash36-<effort>` → `--model gemini-3.6-flash --effort <effort>`'
assert doc_has '`agy-flash35-<effort>` → `--model gemini-3.5-flash-<effort>` with no `--effort` flag'
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
for row in \
  '| `pro` | `high` | `Gemini 3.1 Pro (High)` | *(omit — see below)* |' \
  '| `pro` | `low` | `Gemini 3.1 Pro (Low)` | *(omit — see below)* |' \
  '| `flash36` | `high` | `gemini-3.6-flash` | `high` |' \
  '| `flash36` | `medium` | `gemini-3.6-flash` | `medium` |' \
  '| `flash36` | `low` | `gemini-3.6-flash` | `low` |' \
  '| `flash35` | `high` | `gemini-3.5-flash-high` | *(omit — see below)* |' \
  '| `flash35` | `medium` | `gemini-3.5-flash-medium` | *(omit — see below)* |' \
  '| `flash35` | `low` | `gemini-3.5-flash-low` | *(omit — see below)* |'; do
  assert test "$(grep -Fc -- "$row" "$GEMINI_AGENT")" -eq 1
done
assert grep -Fq '`gemini_model=pro`, and `gemini_effort=high`' "$WORKER_COMMAND"
assert grep -Fq 'Valid combinations are pro high/low, flash36 high/medium/low, and flash35 high/medium/low' "$WORKER_COMMAND"
assert grep -Fq 'gm_model=$(conf gemini_model); gm_model=${gm_model:-pro}' "$WORKERPICK"
assert grep -Fq 'gm_effort=$(conf gemini_effort); gm_effort=${gm_effort:-high}' "$WORKERPICK"
assert grep -Fq 'canonical knob-to-agy mapping lives in `~/.claude/agents/gemini-worker.md`' "$POLICY"
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
for spec in \
  "$CLAUDEB_AGENT|claudeb|claudeb_profile" \
  "$CODEX_AGENT|codex|codex_profile" \
  "$GEMINI_AGENT|gemini|gemini_profile"; do
  agent=${spec%%|*}
  rest=${spec#*|}
  vendor=${rest%%|*}
  pin_key=${rest#*|}
  assert grep -Fq "s/^${pin_key}=//p" "$agent"
  assert grep -Fq 'An `ACCOUNT: <name>` line in the brief wins.' "$agent"
  assert grep -Fq "worker-pick --account $vendor" "$agent"
  assert grep -Fq 'Exit 3 means nothing is selectable' "$agent"
  assert grep -Fq 'State in the report that account resolution fell back' "$agent"
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
  assert grep -Fq 'last enabled account' "$ROOT/bin/$pool_tool"
  # No vendor may re-derive the file format locally.
  assert test "$(grep -c 'grep -qxF -- ' "$ROOT/bin/$pool_tool")" -eq 0
done
assert grep -Fq 'share/worker-pool.sh"' "$LLMLIMITS"
assert grep -Fq 'worker_pool_is_disabled' "$LLMLIMITS"
assert grep -Fq 'worker_pool_disabled_json' "$LLMLIMITS"
# Every vendor reaches the toggle through its own action, and each action is both defined and
# wired into a row — a count of menu entries would only measure how many rows happen to exist.
assert grep -Fq 'In worker pool' "$HAMMER"
for pool_toggle in toggleAccount toggleCodexAccount toggleGeminiAccount; do
  assert grep -Fq "function M.$pool_toggle(" "$HAMMER"
  assert test "$(grep -cF "M.$pool_toggle(" "$HAMMER")" -ge 2
done
assert doc_has 'Worker-pool membership'
assert doc_has '.claudeb`, `.codexb`, `.geminib'
assert doc_has 'including a `claudeb_profile`, `codex_profile`, or `gemini_profile` pin'
assert grep -Fq 'cb_pin=$(conf claudeb_profile)' "$WORKERPICK"
assert grep -Fq 'cx_pin=$(conf codex_profile)' "$WORKERPICK"
assert grep -Fq 'gm_pin=$(conf gemini_profile)' "$WORKERPICK"
assert grep -Fq '.name == $cx_pin and (.walled | not)' "$WORKERPICK"
assert grep -Fq '.name == $gm_pin and (.walled | not)' "$WORKERPICK"
assert grep -Fq '$pin_account != null and $pin_account.auth_ok and $pin_account.general_usable' "$WORKERPICK"
# Own-account exclusion is automatic-selection-only (Egor, 2026-07-27): a pin reaches the
# session's own account, so the gate must not regain an `.own` test and the footnote must
# keep saying "automatic".
assert test "$(grep -cF 'pin_account.own' "$WORKERPICK")" -eq 0
assert grep -Fq 'excluded from automatic worker routing' "$WORKERPICK"

assert grep -Fq 'needs_user_entry:true' "$LLMLIMITS"
assert grep -Fq 'needs_user_entry == true' "$HAMMER"
assert grep -Fq 'split("; ")' "$LLMLIMITS"
assert grep -Fq 'end))] | join("; "))}' "$LLMLIMITS"
assert grep -Fq 'local parts, start, sep = {}, 1, "; "' "$HAMMER"
assert doc_has 'User-entry refresh classification'
assert doc_has 'including multiple Claude auth failures, uses `"; "` between entries'

assert grep -Fq 'RECEIPT_DIR = "receipts"' "$REVIEWBENCH"
assert grep -Fq 'RECEIPT_FIELDS = ("repo", "tree", "commit", "run_id", "ts")' "$REVIEWBENCH"
rb_receipt_name=$(sed -n '/^def receipt_file_name(repo):/,/^$/p' "$REVIEWBENCH")
sl_receipt_name=$(sed -n '/^receipt_file_name()/,/^}/p' "$STATUSLINE")
rb_receipt_hash_len=$(grep -E '^RECEIPT_HASH_HEX = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
sl_receipt_hash_len=$(grep -E '^RECEIPT_HASH_HEX=[0-9]+$' "$STATUSLINE" | cut -d= -f2)
assert eq "$rb_receipt_hash_len" 8
assert eq "$sl_receipt_hash_len" "$rb_receipt_hash_len"
assert grep -Fq 'hashlib.sha1(repo_path.encode()).hexdigest()[:RECEIPT_HASH_HEX]' \
  <<<"$rb_receipt_name"
assert grep -Fq 'shasum -a 1' <<<"$sl_receipt_name"
assert grep -Fq 'awk -v n="$RECEIPT_HASH_HEX" '\''{print substr($1, 1, n)}' <<<"$sl_receipt_name"
assert grep -Fq 'return f"{repo_name}__{repo_hash}.json"' <<<"$rb_receipt_name"
assert grep -Fq 'printf '\''%s__%s.json'\'' "$repo_name" "$repo_hash"' <<<"$sl_receipt_name"
assert grep -Fq 'path = state_dir() / RECEIPT_DIR / name' "$REVIEWBENCH"
assert grep -Fq 'receipt_file="$worker_stats_dir/receipts/$receipt_name"' "$STATUSLINE"
assert grep -Fq '[.repo,.tree,.commit,.run_id,.ts,(.errored | tostring),' "$STATUSLINE"
assert grep -Fq '(if (.panel | type) == "number" and (.panel | floor) == .panel and .panel > 0' "$STATUSLINE"
assert grep -Fq '"panel"' "$REVIEWBENCH"
assert grep -Fq '"max": bool(max_panel)' "$REVIEWBENCH"
assert grep -Fq 'and ((.max | type) == "boolean" or .max == null))' "$STATUSLINE"
assert grep -Fq 'status --porcelain' "$STATUSLINE"
assert test "$(grep -Ec 'GIT_INDEX_FILE|git -C "\\$repo" add -A|current_tree_hash' "$STATUSLINE")" -eq 0
assert doc_has '<state_dir>/receipts/<repoName>__<repoHash>.json'
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
assert grep -Fq 'data_times = [b["as_of"] for b in acc["buckets"].values()' "$LIMITSD"
assert grep -Fq 'and not isinstance(b["used_pct"], bool)' "$LIMITSD"
assert grep -Fq 'def _newest_data_at(holder, fallback):' "$SHADOW_FEED"
assert grep -Fq 'obs.append((vendor, name, "rotation", fallback, {' "$SHADOW_FEED"
assert doc_has 'Account data age'
assert doc_has 'Absent and null-valued windows do not participate'

# --- Row w: owner-only review panels -----------------------------------------
OWNER_GATE="$ROOT/bin/review-owner-gate.sh"
assert grep -Fq 'OWNER_TIERS = ("T3",)' "$REVIEWBENCH"
assert grep -Fq 'AUTO_TIER_CEILING = "T2"' "$REVIEWBENCH"
assert grep -Fq 'OWNER_GRANT_DIR = "review-grants"' "$REVIEWBENCH"
rb_grant_ttl=$(grep -E '^OWNER_GRANT_TTL_S = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
rb_grant_retry=$(grep -E '^OWNER_GRANT_RETRY_S = [0-9]+$' "$REVIEWBENCH" | awk '{print $3}')
gate_grant_ttl=$(grep -E '^GRANT_TTL_S=[0-9]+$' "$OWNER_GATE" | cut -d= -f2)
gate_grant_retry=$(grep -E '^GRANT_RETRY_S=[0-9]+$' "$OWNER_GATE" | cut -d= -f2)
assert eq "$rb_grant_ttl" 1800
assert eq "$gate_grant_ttl" "$rb_grant_ttl"
assert eq "$gate_grant_retry" 1200
assert eq "$rb_grant_retry" "$gate_grant_retry"
# One grant at a time on both sides, and the keyboard exemption is his shell, not any terminal.
assert grep -Fq 'any(set(wanted) <= grant for grant in grants)' "$REVIEWBENCH"
assert grep -Fq '(($wanted - (.scopes // [])) | length) == 0' "$OWNER_GATE"
assert grep -Fq 'os.environ.get("CLAUDECODE")' "$REVIEWBENCH"
# One directory, one schema, both sides.
assert grep -Fq "printf '%s/review-grants' \"\$(state_dir)\"" "$OWNER_GATE"
assert grep -Fq 'state_dir() / OWNER_GRANT_DIR' "$REVIEWBENCH"
assert grep -Fq '{session: $session, ts: $ts, scopes: $scopes}' "$OWNER_GATE"
assert grep -Fq 'grant.get("scopes")' "$REVIEWBENCH"
# The same two scope names name the same two panels on both sides.
assert grep -Fq 'wanted = {"t3"} if tier_name in OWNER_TIERS else set()' "$REVIEWBENCH"
assert grep -Fq 'scopes+=(t3)' "$OWNER_GATE"
assert grep -Fq 'scopes+=(max)' "$OWNER_GATE"
assert grep -Fq 'wanted+=(t3)' "$OWNER_GATE"
assert grep -Fq 'wanted+=(max)' "$OWNER_GATE"
# Both hook registrations, or half the gate is silently off.
assert grep -Fq 'review-owner-gate.sh prompt' "$WORKER_GATE_SETTINGS"
assert grep -Fq 'review-owner-gate.sh bash' "$WORKER_GATE_SETTINGS"
assert doc_has 'Owner-only review panels'
assert doc_has '`<state_dir>/review-grants/<session>.json`'

printf 'PASS: %s asserts; shared invariants agree across sites (staleness thresholds, keychain formula, worker-pick cache format, weather HTTP classes, OAuth 429 cooldown, token-freeze semantics, Codex/Gemini main-last priority, Antigravity review cell models, Gemini worker knobs, worker account resolution, quota-group matching, shared profile mapping, weekly bucket provenance, Claude rotation usability presence, reserved profile names, worker spawn pressure gate, worker-pool membership, user-entry refresh classification, review receipt schema, late review thresholds, account data age, and owner-only review panels) and match %s\n' "$asserts" "$DOC"
