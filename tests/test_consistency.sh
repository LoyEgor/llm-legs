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

CONSISTENCY_CACHE=$(mktemp -d)
trap 'rm -rf "$CONSISTENCY_CACHE"' EXIT
export WORKER_PICK_CACHE_DIR="$CONSISTENCY_CACHE"

asserts=0
fail() { printf 'FAIL: %s\n  (canonical values live in %s)\n' "$*" "$DOC" >&2; exit 1; }
assert() {
  asserts=$((asserts + 1))
  "$@" || fail "assert $asserts: $*"
}
eq() { [ "$1" = "$2" ] || return 1; }

REVIEW_ROOT="${REVIEW_ROOT:-$ROOT/../review-bench}"
[ -r "$REVIEW_ROOT/bin/review-bench" ] || fail "review-bench root $REVIEW_ROOT is unreadable (set REVIEW_ROOT)"
export RBENCH_SHARE="$REVIEW_ROOT/share"

# Value the doc declares canonical, extracted from its own table so a drifted
# doc is caught too.
doc_has() { grep -Fq -- "$1" "$ROOT/$DOC"; }

# Every row is `| id | invariant | canonical value | implementation sites |`, and a row that lost
# a separator renders its sites as part of the value — invisible to a reader looking for the file.
short_rows=$(awk '/^\| [0-9a-z]+ \|/ { line = $0; gsub(/\\\|/, "", line)
  n = gsub(/\|/, "|", line); if (n < 5) print substr($0, 1, 30) }' "$ROOT/$DOC")
assert test -z "$short_rows"

# --- Row a: staleness/dim thresholds -----------------------------------------
FIVE=1800; WEEK=21600; FABLE=21600; ROUTING=7200
LIMITSVIEW="$ROOT/share/limits-view.sh"

# doc prose carries all three
assert doc_has '`1800`s'
assert doc_has '`21600`s'
assert doc_has '`7200`s'

# the numbers live once, in the shared view module
lv_five=$(grep -oE '^LIMITS_STALE_FIVE_HOUR=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
lv_week=$(grep -oE '^LIMITS_STALE_WEEKLY=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
lv_fable=$(grep -oE '^LIMITS_STALE_FABLE=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
lv_routing=$(grep -oE '^LIMITS_STALE_ROUTING=[0-9]+' "$LIMITSVIEW" | grep -oE '[0-9]+')
assert eq "$lv_five" "$FIVE"
assert eq "$lv_week" "$WEEK"
assert eq "$lv_fable" "$FABLE"
assert eq "$lv_routing" "$ROUTING"

# the router names the rows behind its own answer with that same threshold and carries no literal:
# a second number here would call rows stale the surfaces beside it call fresh.
assert grep -Fq -- '--argjson stale_thr "$LIMITS_STALE_ROUTING"' "$WORKERPICK"
assert eq "$(grep -cE '\$stale_thr|LIMITS_STALE_ROUTING' "$WORKERPICK")" 3
assert eq "$(grep -cE -- '(> |-gt )7200\b' "$WORKERPICK")" 0

# claudeb and the collector consume the shared variables, never a local literal
assert grep -Fq -- '--argjson thr5 "$LIMITS_STALE_FIVE_HOUR"' "$CLAUDEB"
assert grep -Fq -- '--argjson thr5 "$LIMITS_STALE_FIVE_HOUR"' "$LLMLIMITS"
assert eq "$(grep -c 'is_stale(' "$CLAUDEB")" 0
assert eq "$(grep -cE '\$stale > (1800|21600)' "$LLMLIMITS")" 0

# the statusline consumes the shared variables too, and carries no dim literal of its own
assert grep -Fq -- '--argjson thr5 "$LIMITS_STALE_FIVE_HOUR" --argjson thrw "$LIMITS_STALE_WEEKLY"' "$STATUSLINE"
assert grep -Fq -- '-gt "$LIMITS_STALE_FABLE"' "$STATUSLINE"
assert eq "$(grep -cE -- '-gt (1800|21600)\b' "$STATUSLINE")" 0

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
# Per-field producer printfs and cb prefixes.
assert grep -Fq "'cx%s%s·%s·%s'" "$WORKERPICK"
assert grep -Fq "'gx%s%s·%s·%s'" "$WORKERPICK"
assert grep -Fq "'gr%s%s·%s·%s'" "$WORKERPICK"
assert grep -Eq 'cb_cache="cb~\$' "$WORKERPICK"
assert grep -Eq 'cb_cache="cb@\$' "$WORKERPICK"
assert grep -Fq 'cb_cache="cb~?"' "$WORKERPICK"
# Producer and consumer must name the same cache file.
assert grep -q 'worker-pick.line' "$WORKERPICK"
assert grep -q 'worker-pick.line' "$STATUSLINE"
# Every field is optional, and only the vendors the store carries contribute one: an absent vendor
# is absent from the line rather than rendered as a failed lookup.
for cache_tag in cx cb gm gr; do
  assert grep -Eq "^\[ \"\\\$${cache_tag}_known\" = (false|true) \]" "$WORKERPICK"
done
assert grep -Fq 'gr_mark="⏸"; gr_acct=off' "$WORKERPICK"
# The consumer finds a vendor by scanning for its tag, which is what makes a missing field legible
# as "no prediction" rather than shifting every field after it onto the wrong vendor.
assert grep -Fq 'for field in "$@"; do' "$STATUSLINE"
assert grep -Fq 'case "$field" in "$tag"*) ;; *) continue ;; esac' "$STATUSLINE"
# Doc records the format.
assert doc_has 'cx%s%s·%s·%s'
assert doc_has 'gr%s%s·%s·%s'
assert doc_has 'EVERY field is optional and the order never moves'
# Prose that respells the order is prose that can respell it wrong: the contract names the tags in
# the order the line writes them.
assert grep -Fq '`cx`/`cb`/`gx`' "$ROOT/docs/routing-contract.md"

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

# --- Row f: robot curl refresh is off, permanently ---------------------------
# The user signal is the whole predicate: one reader in each implementation, no
# marker file and no second condition that could hand the endpoint back to robots.
cb_pred=$(sed -n '/^user_refresh_explicit()/,/^}/p' "$CLAUDEB")
[ -n "$cb_pred" ] || fail "row f: user_refresh_explicit not found in $CLAUDEB"
assert grep -Fq -- 'CLAUDEB_WARM_USER_EXPLICIT:-false' <<<"$cb_pred"
assert grep -Fq -- 'if ! user_refresh_explicit; then' "$CLAUDEB"
assert grep -Fq -- 'token_journal "$name" curl-refresh robot-skip' "$CLAUDEB"
assert grep -Fq -- 'return 76' "$CLAUDEB"
assert eq "$(grep -c 'CLAUDEB_WARM_USER_EXPLICIT' "$LLMLIMITS")" 3
assert grep -Fq 'claudeb_child=(env LLM_LIMITS_ANNOUNCE_SUPPRESS=1 CLAUDEB_WARM_USER_EXPLICIT=true "$claudeb_cmd")' "$LLMLIMITS"
assert grep -Fq -- 'robot curl refresh off (manual refresh only) — revive path active' "$LLMLIMITS"
retired_marker_re='token[-_]'"freeze"
for site in "$CLAUDEB" "$LLMLIMITS"; do
  assert eq "$(grep -cE "$retired_marker_re" "$site")" 0
done
assert doc_has 'Robot curl refresh is off, permanently and unconditionally'
assert doc_has '`robot-skip`'

# --- Row g: worker rank contract and display priority -------------------------
CODEXB="$ROOT/bin/codexb"
POLICY="$ROOT/share/worker-policy.md"
CONTRACT="$ROOT/docs/routing-contract.md"
# `auth_late` ranks a grok account whose access token expired behind every signed-in one without
# walling it — the CLI refreshes it silently — and reads as false on every other vendor's rows.
assert test "$(grep -Fc 'def rank_keys: [(if .defer5h then 1 else 0 end), (if .claimed then 1 else 0 end), (if .auth_late then 1 else 0 end), (0 - (.budget // 0)), .name];' "$WORKERPICK")" -eq 1
assert test "$(grep -Fc 'def rank: sort_by(rank_keys);' "$WORKERPICK")" -eq 1
assert grep -Fq '`[five-hour deferral, fresh claim, late auth, −budget, name]`' "$CONTRACT"
# The five-hour deferral that heads the vector is one number, and the contract quotes it.
assert eq "$(grep -oE '^FIVE_HOUR_DEFER_PCT=[0-9]+' "$WORKERPICK" | grep -oE '[0-9]+')" 80
assert grep -Fq 'is 80% or more ranks behind every candidate below 80%' "$CONTRACT"
assert grep -Fq 'def display_band($selected): if .name == $selected then 0 elif .eligible then 1 elif .in_pool then 2 else 3 end;' "$WORKERPICK"
# The render sorts on the band plus the selection keys, so within a band the order is the
# selection order rather than the limits file's.
assert grep -Fq 'def display_sort($selected): sort_by([display_band($selected)] + rank_keys);' "$WORKERPICK"
assert test "$(grep -Fc 'sort_by(display_band(' "$WORKERPICK")" -eq 0
assert test "$(grep -Fc 'display_sort($sel)' "$WORKERPICK")" -eq 4
# `main` is not a ranking key on any vendor any more — the budget decides and the shield
# (row bn) is what holds a base account back — so no site may reintroduce one.
for no_main_last in "$WORKERPICK" "$CODEXB" "$POLICY" "$CONTRACT"; do
  assert test "$(grep -Fc 'main_last' "$no_main_last")" -eq 0
done
assert grep -Fq '`main` is no longer a ranking key on any vendor' "$CONTRACT"
# codexb ranks its own profiles by the same budget, largest first, name breaking the tie.
assert grep -Fq 'sort -t $'\''\t'\'' -k2,2nr -k1,1' "$CODEXB"
assert grep -Fq 'a usable workers pin leads, then `[five-hour deferral, fresh claim, late auth, −budget, name]` across all vendors' "$POLICY"
assert grep -Fq 'usable pin first, then `[five-hour deferral, fresh claim, late auth, −budget, name]`' "$CONTRACT"
assert grep -Fq 'NEXT_MAX_ROWS=5' "$WORKERPICK"
assert doc_has 'Worker rank contract'

RB_PKG="$REVIEW_ROOT/share/rbench"
RB_STORE="$RB_PKG/store.py"
RB_CATALOG="$RB_PKG/catalog.py"
RB_RATERS="$RB_PKG/raters.py"
RB_ACCOUNTS="$RB_PKG/accounts.py"
RB_SCOPE="$RB_PKG/scope.py"
RB_PANEL="$RB_PKG/panel.py"
RB_PROMPTS="$RB_PKG/prompts.py"
RB_LAUNCH="$RB_PKG/launch.py"
RB_ROUND="$RB_PKG/round.py"
RB_DEBT="$RB_PKG/debt.py"
RB_REPORT="$RB_PKG/report.py"
RB_STATS="$RB_PKG/stats.py"
RB_CLI="$RB_PKG/cli.py"

# A pin over a package needs both of these. `grep -Fq a.py b.py` is OR — it exits at the first
# match — so a value spelled in two modules keeps passing after one of them drops it; and a count
# taken in one module says nothing about the copy the split made possible in a sibling.
rb_all_have() {
  local rb_pattern="$1" rb_file
  shift
  for rb_file; do grep -Fq -- "$rb_pattern" "$rb_file" || return 1; done
}
# <pattern> <lines package-wide> <the one module they may live in>
rb_pkg_only() {
  eq "$(grep -rhF --include='*.py' -- "$1" "$RB_PKG" | grep -c '')" "$2" \
    && eq "$(grep -rlF --include='*.py' -- "$1" "$RB_PKG")" "$3"
}

# A suite patch has to name the module that owns the name. Inside the package a module reads its
# siblings through the module object, so a patch written on the package instead lands on the
# __init__ re-export nobody reads: the assertions keep passing and stop testing anything. The
# prover emits the ownership map beside the modules; this check is what ties the patches to it.
# Both suites import the package under two aliases, so both regexes below cover both — and are
# spelled so this file's own text cannot match them.
assert test -r "$RB_PKG/name-to-module.json"
rb_patch_audit=$(python3 - "$RB_PKG/name-to-module.json" \
  "$REVIEW_ROOT/tests/test_review_bench.sh" "$ROOT/tests/test_consistency.sh" <<'PATCHPY'
import json
import re
import sys

owner = json.load(open(sys.argv[1], encoding="utf-8"))
QUALIFIED = re.compile(r"\b(rb|module)\.([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")
BARE = re.compile(r"\b(rb|module)\.([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")
bad = []
for path in sys.argv[2:]:
    text = open(path, encoding="utf-8").read()
    for alias, module, name in QUALIFIED.findall(text):
        if owner.get(name) != module:
            bad.append("%s: %s.%s.%s, but %s lives in %s"
                       % (path, alias, module, name, name, owner.get(name)))
    for alias, name in BARE.findall(text):
        bad.append("%s: %s.%s is patched on the package, not on the module that owns it"
                   % (path, alias, name))
print("\n".join(bad) if bad else "ok")
PATCHPY
)
assert eq "$rb_patch_audit" ok
for mapping in \
  '"agy-pro": "gemini-3.1-pro"' \
  '"agy-flash38": "gemini-3.8-flash"' \
  '"agy-flash37": "gemini-3.7-flash"' \
  '"agy-flash36": "gemini-3.6-flash"'; do
  assert grep -Fq -- "$mapping" "$RB_CATALOG"
done
assert grep -Fq '"agy-pro": ("low", "high")' "$RB_CATALOG"
assert grep -Fq '"agy-flash38": ("low", "medium", "high")' "$RB_CATALOG"
assert grep -Fq '"agy-flash37": ("low", "medium", "high")' "$RB_CATALOG"
assert grep -Fq '"agy-flash36": ("low", "medium", "high")' "$RB_CATALOG"
# The retired 3.5 Flash family, pinned as ABSENT: the server answers a dropped id
# `invalid model selection`, so a spelling that creeps back into the roster, the raters' grammar
# or the tiers is a panel of cells that cannot answer. Prose about the retirement is allowed to
# name it; a mapping key, a cell spelling and a rater alternative are not.
assert test "$(grep -Fc '"agy-flash35"' "$RB_CATALOG")" -eq 0
assert test "$(grep -Fc 'agy-flash35-' "$RB_CATALOG")" -eq 0
# The two lines of the legacy normalizer below spell the family on purpose, split so this pin
# stays a flat grep; a rater alternative reintroduced the same way is what it must still catch.
assert test "$(grep -v 'retired_flash' "$RB_RATERS" | grep -Fc 'flash35')" -eq 0
assert test "$(grep -Fc 'agy-flash35' "$REVIEW_ROOT/docs/DIAGNOSTICS.md")" -eq 0
assert grep -Fq 'agy-pro-<low|high>' "$REVIEW_ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash38-<low|medium|high>' "$REVIEW_ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash37-<low|medium|high>' "$REVIEW_ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'agy-flash36-<low|medium|high>' "$REVIEW_ROOT/docs/DIAGNOSTICS.md"
assert grep -Fq 'return f"{model}-{rater['\''effort'\'']}"' "$RB_LAUNCH"
assert grep -Fq 'if rater["model"] == "agy-pro" and rater["effort"] == "high":' "$RB_LAUNCH"
assert doc_has '`agy-pro-low` → `--model gemini-3.1-pro-low`'
assert doc_has '`agy-pro-high` → `--model "Gemini 3.1 Pro (High)"`'
assert doc_has '`agy-flash38-<effort>` → `--model gemini-3.8-flash-<effort>`'
assert doc_has '`agy-flash37-<effort>` → `--model gemini-3.7-flash-<effort>`'
assert doc_has '`agy-flash36-<effort>` → `--model gemini-3.6-flash-<effort>`'
assert doc_has 'retired from the roster whole rather than repointed'
assert doc_has '`agy-flash35`/`gemini-3.5-flash` went that way'
assert doc_has 'historical rows are keyed `flash35-<effort>`'
assert grep -Fq 'retired_flash = "agy-" + "flash35-"' "$RB_RATERS"
assert grep -Fq 'return "flash35-" + rater[len(retired_flash):]' "$RB_RATERS"
assert grep -Fq 'if cell.startswith("flash35-"):' "$REVIEW_ROOT/share/rbench/stats.py"
# Every live Flash family the bench can launch has a tag arm: a family the statusline cannot name
# shows the configured default instead of the model the run is actually spending.
for agy_family in 3.8-flash:flash38 3.7-flash:flash37 3.6-flash:flash36; do
  assert grep -Fq "*gemini-${agy_family%%:*}*) model=${agy_family##*:}" "$ROOT/bin/worker-tag-hook.sh"
done
assert doc_has 'Every cell omits `--effort`'
assert test "$(sed -n '/^def run_agy(/,/^def /p' "$RB_LAUNCH" | grep -Fc '"--effort"')" -eq 0
assert doc_has 'Antigravity review cell invocation mapping'

# --- Row i: Gemini worker knobs ----------------------------------------------
GEMINI_AGENT="${GEMINI_WORKER_AGENT:-$HOME/.claude/agents/gemini-worker.md}"
CODEX_AGENT="${CODEX_WORKER_AGENT:-$HOME/.claude/agents/codex-worker.md}"
CLAUDEB_AGENT="${CLAUDEB_WORKER_AGENT:-$HOME/.claude/agents/claudeb-worker.md}"
GROK_AGENT="${GROK_WORKER_AGENT:-$HOME/.claude/agents/grok-worker.md}"
WORKER_COMMAND="${WORKER_COMMAND_FILE:-$HOME/.claude/commands/worker.md}"
assert test -r "$GEMINI_AGENT"
assert test -r "$CODEX_AGENT"
assert test -r "$CLAUDEB_AGENT"
assert test -r "$WORKER_COMMAND"
WORKER_RUN="${WORKER_RUN_BIN:-$ROOT/bin/worker-run}"
assert test -x "$WORKER_RUN"
assert test "$(grep -Fc -- "flash38:high | flash38:medium | flash38:low) agy_model=\"gemini-3.8-flash-\$effort\" ;;" "$WORKER_RUN")" -eq 1
# No `pro` arm survives on the WORKER leg: since 2026-09-04 Pro is a model no worker may run
# (row bq), and an arm nothing can reach is an arm the next reader takes for a supported pair.
# The `Gemini 3.1 Pro (High)` label workaround belongs to the review cells alone.
assert test "$(grep -Ec 'pro:(high|medium|low)|Gemini 3\.1 Pro' "$WORKER_RUN")" -eq 0
# Nor any OTHER flash family: `agy models` serves 3.6 and 3.7 too, and an arm for one of them
# would launch a model the allowed list refuses upstream of this case.
assert test "$(grep -Ec 'flash3[0-79]:(high|medium|low)' "$WORKER_RUN")" -eq 0
assert grep -Fq '`gemini_model=flash38`, and `gemini_effort=high`' "$WORKER_COMMAND"
assert grep -Fq 'The only valid combinations are flash38 low/medium/high' "$WORKER_COMMAND"
assert grep -Fq 'gm_model=$(conf gemini_model); gm_model=${gm_model:-flash38}' "$WORKERPICK"
assert grep -Fq 'gm_effort=$(conf gemini_effort); gm_effort=${gm_effort:-high}' "$WORKERPICK"
assert grep -Fq 'canonical knob-to-agy mapping lives in `worker-run`' "$POLICY"
assert doc_has 'Gemini worker knobs'

# --- Row bq: allowed worker models -------------------------------------------
# The list has ONE home in code; every other site is prose, and prose that drifts sends a worker
# after a model `worker-run` will refuse.
WORKER_MODEL_SH="$ROOT/share/worker-model.sh"
PIN_GATE="$ROOT/bin/worker-pin-gate.sh"
assert test -r "$WORKER_MODEL_SH"
for arm in \
  "claudeb) printf 'opus\\n' ;;" \
  "codex) printf 'gpt-6-astra\\n' ;;" \
  "gemini) printf 'flash38\\n' ;;" \
  "grok) printf 'auto\\ngrok-4.6\\n' ;;"; do
  assert test "$(grep -Fc -- "$arm" "$WORKER_MODEL_SH")" -eq 1
done
# Neither refusal spells a model of its own: both read the list through these functions.
assert grep -Fq 'worker_model_allows "$vendor" "$effective"' "$WORKER_RUN"
assert grep -Fq 'worker_model_allowed_list "$vendor"' "$WORKER_RUN"
assert grep -Fq 'OUTCOME: MODEL_REFUSED' "$WORKER_RUN"
assert grep -Fq 'worker_model_allows "$vendor" "$value"' "$PIN_GATE"
assert grep -Fq 'worker_model_allowed_summary' "$PIN_GATE"
# `flash3[0-79]` and not `flash3[0-9]`: 38 is the one flash family a worker may run, so a site
# naming it is naming the allowed model, not smuggling a cheap one past the list.
assert test "$(grep -Ec '(sonnet|haiku|fable|flash3[0-79]|gpt-5\.6-(terra|luna))' "$PIN_GATE")" -eq 0
# Refused BEFORE the account is resolved: a pick already made is quota already claimed.
assert test "$(grep -n 'refuse_cheap_model "$vendor" "$model"' "$WORKER_RUN" | cut -d: -f1)" \
  -lt "$(grep -n 'warn_cold_resume "$vendor" "$account" "$resume"' "$WORKER_RUN" | cut -d: -f1)"
# Prose sites, each naming the same four allowed models and the refusal by name.
for site in "$ROOT/share/worker-policy.md" "$ROOT/docs/routing-contract.md" \
  "$ROOT/docs/DIAGNOSTICS.md" "$WORKER_COMMAND"; do
  assert grep -Fq 'gpt-6-astra' "$site"
  assert grep -Fq 'MODEL_REFUSED' "$site"
done
# grok is the one vendor with two spellings, and a site naming only `auto` reads as a shorter list.
for site in "$ROOT/share/worker-policy.md" "$ROOT/docs/routing-contract.md" \
  "$ROOT/docs/DIAGNOSTICS.md"; do
  assert grep -Fq 'grok-4.6' "$site"
done
# The relay briefs may not offer a cheap model as a per-task MODEL: option.
for agent in "$CLAUDEB_AGENT" "$CODEX_AGENT" "$GEMINI_AGENT" "$GROK_AGENT"; do
  assert test -r "$agent"
  # The frontmatter `model:` is the RELAY's own model, not a model it may ask a worker to run.
  assert test "$(grep -Ev '^model: ' "$agent" | grep -Eic '(sonnet|haiku|fable|flash3[0-79]|gpt-5\.6-(terra|luna))')" -eq 0
done
assert doc_has 'Allowed worker models'
assert doc_has 'claudeb `opus`, codex `gpt-6-astra`, gemini `flash38`, grok `auto`'

SPAWN_HOOK="$ROOT/bin/worker-spawn-hook.sh"
assert grep -Fq 'gm_pin=$(conf gemini_profile)' "$WORKERPICK"
assert grep -Fq 'WORKER_PICK="${WORKER_SPAWN_WORKER_PICK:-$HOME/.local/bin/worker-pick}"' "$SPAWN_HOOK"
assert grep -Fq 'acct=$(brief_line ACCOUNT)' "$SPAWN_HOOK"
for vendor in claudeb codex gemini grok; do
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
# A hit turn cap is the vendor serving, so it may never share a name with the outcomes the routers
# read as "no capacity here": folded back into GROK_UNAVAILABLE the relay hunts a pool problem that
# does not exist and reroutes a brief that outruns the same cap wherever it lands.
assert grep -Fq "printf 'OUTCOME: GROK_MAX_TURNS\\n'" "$WORKER_RUN"
assert grep -Fq 'grok_turns=${WORKER_RUN_GROK_MAX_TURNS:-}' "$WORKER_RUN"
assert grep -Fq -- '[ -z "$grok_turns" ] || command_meta+=(--max-turns "$grok_turns")' "$WORKER_RUN"
assert grep -Fq -- '[ -z "$turns" ] || command+=(--max-turns "$turns")' "$WORKER_RUN"
assert doc_has '`OUTCOME: GROK_MAX_TURNS`, never `_UNAVAILABLE` and never `_USAGE_LIMIT`'
assert doc_has 'only when `WORKER_RUN_GROK_MAX_TURNS` sets one'

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

# Review keeps Sol; implementation runs Astra independently (Egor, 2026-09-05).
assert grep -Fq '"-m", "gpt-5.6-sol"' "$ROOT/../review-bench/share/rbench/launch.py"
assert eq "$(bash -c ' . "$1"; worker_model_allowed_models codex' _ "$WORKER_MODEL_SH")" 'gpt-6-astra'
assert eq "$(grep -c worker_model_allowed_models "$ROOT/../review-bench/share/rbench/launch.py")" 0

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
assert grep -Fq 'if .vendors.claude then .vendors.claude |=' "$WORKERPICK"
assert eq "$(sed -n '/^select_codex_event()/,/^codex_refresh_target=/p' "$LLMLIMITS" | grep -c headers)" 0
assert test "$(sed -n '/^select_codex_event()/,/^codex_refresh_target=/p' "$LLMLIMITS" | grep -c 'origin:"usage"')" -eq 4
assert doc_has 'Weekly bucket provenance'
assert doc_has 'no writer may stamp `origin: "headers"` on `seven_day`'

assert doc_has 'always emits boolean `rotation.usable.general`, `rotation.usable.fable`, and `blocked == ((enabled and rotation.usable.general) \| not)`'
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
    .blocked == (((.enabled == true) and .rotation.usable.general) | not)) and
  # Pool membership is consent, not capability, and it keeps its own field: a disabled account is
  # `blocked`, while the usable flags still say what it could do — which is what lets the pin
  # override the toggle instead of being refused by a flag that swallowed it.
  (any(.vendors.claude.accounts[]; .account == "disabled" and .enabled == false and
    .blocked == true and .rotation.usable.general == true and .rotation.usable.fable == true)) and
  (any(.vendors.claude.accounts[]; .account == "nonnumeric-fable" and
    .rotation.usable.fable == false)) and
  # worker-pick reads a missing key as true, so the fail-open direction needs its
  # value asserted, not just its type: no auth object, a non-ok verdict, and an
  # unreadable snapshot must all come out false.
  (all(.vendors.claude.accounts[] | select(.account == "missing-auth" or
       .account == "bad-auth" or .account == "empty");
    .rotation.usable.general == false and .rotation.usable.fable == false))
' <<<"$EDGE_JSON" >/dev/null
# End to end over that same snapshot: the pin is the one override above the pool (routing-contract
# rules 2 and 4), so an out-of-pool account is refused to every ordinary query and answered when it
# is the pin.
EDGE_PICK="$EDGE_WORK/limits.json"
EDGE_MODEL="$EDGE_WORK/worker-model"
printf '%s' "$EDGE_JSON" >"$EDGE_PICK"
printf 'worker=auto\n' >"$EDGE_MODEL"
edge_pick() {
  env HOME="$EDGE_HOME" CLAUDEB_DIR="$EDGE_STORE" LLM_LIMITS_FILE="$EDGE_PICK" WORKER_PICK_CONFIG_FILE="$EDGE_MODEL" \
    WORKER_PICK_CACHE_DIR="$EDGE_WORK/cache" WORKER_CLAIMS_DIR="$EDGE_WORK/claims" \
    CLAUDE_LIMITS_ACCOUNT=missing-five "$WORKERPICK" --account claudeb 2>/dev/null
}
assert test "$(edge_pick)" != disabled
printf 'worker=auto\nclaudeb_profile=disabled\n' >"$EDGE_MODEL"
assert eq "$(edge_pick)" disabled
rm -rf "$EDGE_WORK"

GATE_WARN=85; GATE_DENY=95
assert test -x "$WORKER_GATE"
assert eq "$(grep -E '^WARN_AT=[0-9]+$' "$WORKER_GATE" | cut -d= -f2)" "$GATE_WARN"
assert eq "$(grep -E '^DENY_AT=[0-9]+$' "$WORKER_GATE" | cut -d= -f2)" "$GATE_DENY"
assert test "$(grep -Ec '^WARN_AT=' "$WORKER_GATE")" -eq 1
assert test "$(grep -Ec '^DENY_AT=' "$WORKER_GATE")" -eq 1
for worker in claudeb-worker codex-worker gemini-worker grok-worker; do
  assert grep -Fq "$worker" "$WORKER_GATE"
done
for vendor in claudeb codex gemini grok; do
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

# --- Row bt: native agent types on a Fable session ---------------------------
# The two lists live once in the gate; the doc and routing-contract prose repeat them in words,
# and a list that grows in one place and not the others is a rule nobody can read off any of them.
ROUTING_DOC="$ROOT/docs/routing-contract.md"
native_list() { sed -nE "s/^$1='([^']*)'\$/\1/p" "$WORKER_GATE" | head -n1; }
assert eq "$(native_list NATIVE_ALLOWLIST)" 'Explore Plan claude-code-guide statusline-setup gemini-research'
assert eq "$(native_list NATIVE_CHEAP)" 'Explore claude-code-guide gemini-research'
for native in $(native_list NATIVE_ALLOWLIST); do
  assert grep -Fq "\`$native\`" "$ROOT/$DOC"
  assert grep -Fq "\`$native\`" "$ROUTING_DOC"
done
for cheap in $(native_list NATIVE_CHEAP); do
  assert grep -Fq "\`$cheap\`" "$ROOT/$DOC"
done
# The rewrite target and the refusal are the row's other two halves.
assert grep -Fq '.model = "sonnet"' "$WORKER_GATE"
assert grep -Fq "native \$native runs on Fable's quota" "$WORKER_GATE"
assert grep -Fq 'model: sonnet' "$ROUTING_DOC"
assert doc_has 'Native agent types on a Fable session'

# --- Rows bu/bv: worker-run deadlines and the launched brief -----------------
WORKER_RUN="$ROOT/bin/worker-run"
assert eq "$(sed -nE 's/^IDLE=\$\{WORKER_RUN_IDLE_S:-([0-9]+)\}$/\1/p' "$WORKER_RUN")" 1800
assert eq "$(sed -nE 's/^DEADLINE=\$\{WORKER_RUN_DEADLINE:-([0-9]+)\}$/\1/p' "$WORKER_RUN")" 21600
assert grep -Fq '`1800`s' "$ROOT/$DOC"
assert grep -Fq '`21600`s' "$ROOT/$DOC"
# gemini's own timeout follows the ceiling instead of standing on a number of its own.
assert eq "$(grep -c -- '--print-timeout 360m' "$WORKER_RUN")" 2
assert grep -Fq -- '--print-timeout 360m' "$ROOT/$DOC"
# The liveness reading is ONE definition: the status row and the watchdog disagreeing about whether
# a run has touched anything is a healthy worker killed while its own LAST-EDIT reads seconds.
assert eq "$(grep -c 'workdir_activity_stamp' "$WORKER_RUN")" 3
assert grep -Fq 'workdir_activity_stamp' "$ROOT/$DOC"
# An idle kill needs positive evidence, and either watchdog names itself.
assert grep -Fq '= y ] && [ $(($(date +%s) - idle_since))' "$WORKER_RUN"
assert grep -Fq 'KILLED: idle watchdog' "$WORKER_RUN"
assert grep -Fq 'KILLED: deadline' "$WORKER_RUN"
assert grep -Fq 'KILLED: idle watchdog' "$ROOT/$DOC"
assert doc_has 'Worker run deadlines'
# The launched brief is a second file; the record stays the input.
assert eq "$(grep -c "^BRIEF_PREAMBLE='" "$WORKER_RUN")" 1
assert eq "$(grep -c '"\$directory/brief" >/dev/null 2>"\$directory/err"' "$WORKER_RUN")" 0
assert grep -Fq 'brief.launch' "$ROOT/$DOC"
assert doc_has 'Launched brief vs recorded brief'

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
for pool_tool in claudeb codexb geminib grokb; do
  assert grep -Fq 'share/worker-pool.sh"' "$ROOT/bin/$pool_tool"
  assert grep -Fq 'worker_pool_is_disabled "$pool' "$ROOT/bin/$pool_tool"
  assert grep -Fq 'worker_pool_set_disabled "$pool' "$ROOT/bin/$pool_tool"
  # The wall and the directory formula come from the helper too: a vendor that walled headless
  # runs on its own, or spelled its own pool path, is how the three drift apart.
  assert grep -Fq 'worker_pool_refuse_headless ' "$ROOT/bin/$pool_tool"
  assert grep -Eq 'pool_dir=\$\(worker_pool_dir (claudeb|codex|gemini|grok)\)' "$ROOT/bin/$pool_tool"
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
assert grep -Fq 'title = "In pool"' "$HAMMER"
for pool_toggle in toggleAccount toggleCodexAccount toggleGeminiAccount toggleGrokAccount; do
  assert grep -Fq "function M.$pool_toggle(" "$HAMMER"
  assert test "$(grep -cF "M.$pool_toggle(" "$HAMMER")" -ge 2
done
assert doc_has 'Worker-pool membership'
assert doc_has '.claudeb`, `.codexb`, `.geminib`, `.grokb'
assert doc_has 'the vendor pin (`claudeb_profile`, `codex_profile`, `gemini_profile`, `grok_profile`) is the one override'
assert doc_has 'Exclusion IS unreachability for every headless run'
assert grep -Fq 'cb_pin=$(conf claudeb_profile)' "$WORKERPICK"
assert grep -Fq 'cx_pin=$(conf codex_profile)' "$WORKERPICK"
assert grep -Fq 'gm_pin=$(conf gemini_profile)' "$WORKERPICK"
assert grep -Fq 'gr_pin=$(conf grok_profile)' "$WORKERPICK"
# `unavailable`, not `walled`: the wall is the usage verdict alone and dead auth is its own state
# on the rows, so a pin test spelled against the wall would accept an account nobody can log into.
assert grep -Fq '.unavailable = ((.auth_ok | not) or .walled)' "$WORKERPICK"
assert grep -Fq '.name == $cx_pin and (.unavailable | not)' "$WORKERPICK"
assert grep -Fq '.name == $gm_pin and (.unavailable | not)' "$WORKERPICK"
assert grep -Fq '.name == $gr_pin and (.unavailable | not)' "$WORKERPICK"
assert doc_has 'a state that is dead auth OR a usage wall'
assert grep -Fq '(if $pin_account != null and $pin_account.auth_ok and' "$WORKERPICK"
# The pin is the override ABOVE the pool (routing-contract rules 2 and 4), so its acceptance may
# read neither the toggle nor the collector verdict that carries the toggle inside it.
assert test "$(grep -cE 'pin_account\.(enabled|blocked|general_usable)' "$WORKERPICK")" -eq 0
# The pin's wall companion: written by every vendor CLI under its own store vendor key, read back
# by the picker under the pin key, and stripped wherever the pin itself is.
assert grep -Fq 'worker_model_pin_wall_until claude ' "$ROOT/bin/claudeb"
assert grep -Fq 'worker_model_pin_wall_until codex ' "$ROOT/bin/codexb"
assert grep -Fq 'worker_model_pin_wall_until gemini ' "$ROOT/bin/geminib"
assert grep -Fq 'worker_model_pin_wall_until grok ' "$ROOT/bin/grokb"
for pin_key in claudeb codex gemini grok; do
  assert grep -Fq "_pin_wall=\$(conf ${pin_key}_profile_wall)" "$WORKERPICK"
done
assert test "$(grep -Fc 'grep -Ev "^${key}(_wall)?="' "$ROOT/share/worker-model.sh")" -eq 2
# The session account is no longer a reserve of any kind (docs/routing-contract.md rule 1): it is
# ranked by its budget like every other account, so neither the gate may regain an `.own` test nor
# any surface the marker that used to announce the reserve.
assert test "$(grep -cF 'pin_account.own' "$WORKERPICK")" -eq 0
assert grep -Fq 'There is **no session reserve**' "$CONTRACT"
for no_reserve in "$WORKERPICK" "$STATUSLINE" "$RB_ACCOUNTS"; do
  assert test "$(grep -cF 'SESSION RESERVE' "$no_reserve")" -eq 0
done

assert grep -Fq 'needs_user_entry:true' "$LLMLIMITS"
assert grep -Fq 'needs_user_entry == true' "$HAMMER"
assert grep -Fq 'split("; ")' "$LLMLIMITS"
assert grep -Fq 'join("; "))}' "$LLMLIMITS"
assert grep -Fq 'def classify_cause:' "$LLMLIMITS"
assert grep -Fq 'deactivated_workspace' "$LLMLIMITS"
assert grep -Fq '"workspace deactivated"' "$LLMLIMITS"
assert doc_has 'workspace deactivated'
for codex_wall_wording in 'Payment Required' 'deactivated_workspace'; do
  assert grep -Fq "$codex_wall_wording" "$WORKER_RUN"
  assert grep -Fq "$codex_wall_wording" "$LLMLIMITS"
  assert doc_has "$codex_wall_wording"
done

# --- Rows bx/by: grok persistent wall and Codex out-of-credits agree with the bench
assert grep -Fq "you['’]ve reached your free Grok Build usage limit for now" "$WORKER_RUN"
assert grep -Fq "you['’]ve reached your free Grok Build usage limit for now" "$RB_ACCOUNTS"
assert doc_has "you['’]ve reached your free Grok Build usage limit for now"
for grok_wall_wording in \
  'hit the rate limit for your plan' \
  'hit the credit limit for your plan' \
  'subscription:free-usage-exhausted' \
  'run out of credits'; do
  assert grep -Fq "$grok_wall_wording" "$WORKER_RUN"
  assert grep -Fq "$grok_wall_wording" "$RB_ACCOUNTS"
  assert doc_has "$grok_wall_wording"
done
assert grep -E 'codex\) pattern=.*out of credits' "$WORKER_RUN"
assert grep -Fqi 'out of credits' <<<"$(sed -n '/^def codex_usage_wall(/,/^def is_429_error(/p' "$RB_ACCOUNTS")"
assert doc_has 'out of credits'
assert doc_has 'A spent SuperGrok plan is one wording in both repositories'
assert doc_has 'Codex out-of-credits wall wording agrees across relay and bench'

assert grep -Fq 'def apply_vendor_errors' "$LLMLIMITS"
assert grep -Fq '.refresh_errors =' "$LLMLIMITS"
assert grep -Fq 'appendRefreshErrorRows' "$HAMMER"
assert eq "$(grep -c 'splitCauseEntries' "$HAMMER")" 0
assert doc_has 'User-entry refresh classification'
assert doc_has 'Refresh error list'
assert doc_has '`refresh_errors`'
assert doc_has '`classify_cause`'

rb_late_multiplier=$(grep -E '^REVIEW_LATE_MULTIPLIER = [0-9]+$' "$RB_REPORT" | awk '{print $3}')
rb_late_floor_s=$(grep -E '^REVIEW_LATE_FLOOR_S = [0-9]+$' "$RB_REPORT" | awk '{print $3}')
sl_late_pair=$(grep -oE '\[[0-9]+ \* \$expected_ms, [0-9]+\]' "$STATUSLINE")
sl_late_multiplier=$(grep -oE '[0-9]+' <<<"$sl_late_pair" | head -n1)
sl_late_floor_ms=$(grep -oE '[0-9]+' <<<"$sl_late_pair" | tail -n1)
assert test "$(grep -Ec '^REVIEW_LATE_MULTIPLIER = ' "$RB_REPORT")" -eq 1
assert test "$(grep -Ec '^REVIEW_LATE_FLOOR_S = ' "$RB_REPORT")" -eq 1
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
# the statusline judges its raw account snapshots with the same defs and renders the fable row
# off the collector's fields, like the menu; no private expiry/stale/pct copy survives
assert grep -Fq 'share/limits-view.sh' "$STATUSLINE"
for view_def in limits_bucket_expired limits_bucket_stale limits_effective_pct \
    limits_reset_epoch_floor limits_reset_ancient; do
  assert grep -Fq "$view_def" "$STATUSLINE"
done
assert grep -Fq '.effective_pct | round | tostring' "$STATUSLINE"
assert eq "$(grep -c 'used_pct' "$STATUSLINE")" 0
assert eq "$(grep -cE '"\$(h5|wk)_reset" -lt "\$now"' "$STATUSLINE")" 0
# the menu stays flag-driven off the collector's fields (never re-derives pct semantics)
assert grep -Fq 'tonumber(bucket.effective_pct)' "$HAMMER"
assert eq "$(grep -c 'used_percentage' "$HAMMER")" 0
# probes/warms fold fresh snapshots into the merged cache; the collector's own
# child invocations are suppressed so a refresh never recurses or double-writes
assert grep -Fq 'announce_limits_probed' "$CLAUDEB"
assert grep -Fq 'announce_suppressed' "$ROOT/share/account-announce.sh"
assert grep -Fq 'LLM_LIMITS_ANNOUNCE_SUPPRESS=1' "$LLMLIMITS"
# a pressed r in the status TUI is a user-explicit refresh — the robot-refresh
# guard (row f) must not silently eat it
assert grep -Fq 'export CLAUDEB_WARM_USER_EXPLICIT=true' "$CLAUDEB"
assert doc_has 'One limits view'

# --- Row aa: Hammerspoon launchd agent identity -------------------------------
HS_LABEL="com.egor.hammerspoon"
HS_ROOT="${HS_ROOT:-$HOME/.hammerspoon}"
HS_PLIST="$HS_ROOT/launchd/$HS_LABEL.plist"
HS_GUARD="$ROOT/hammerspoon/config/env_guard.lua"
test -r "$HS_PLIST" || fail "row aa: $HS_PLIST is unreadable (set HS_ROOT)"
HS_LOG="/Users/egorloy/Library/Logs/$HS_LABEL.log"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$HS_PLIST")" "$HS_LABEL"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$HS_PLIST")" "/Users/egorloy/.local/libexec/hammerspoon"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$HS_PLIST")" "$HS_LOG"
assert eq "$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$HS_PLIST")" "$HS_LOG"
assert grep -Fq -- "gui/\$(/usr/bin/id -u)/$HS_LABEL" "$HS_GUARD"
assert grep -Fq -- "/Library/Logs/$HS_LABEL.log" "$HS_GUARD"
assert grep -Fq -- "$HS_LABEL" "$ROOT/docs/DIAGNOSTICS.md"
assert doc_has 'Hammerspoon launchd agent identity'

CLAUDE_SETUP="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}"
RJOURNAL="$CLAUDE_SETUP/hooks/lib/review-journal.sh"
FLOW_GATE="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}/hooks/review-flow-gate.sh"

# --- Row ah: the statusline speaks the gate's verdict --------------------------
# Three implementations, one sentence: review-bench prints the debt word, the gate translates it
# into a style plus a label, and the statusline removes only a duplicate `rev` already carried by a
# live counter over the same repository. Renaming a word on any one side is silent, and each of the
# three now has to say so out loud: `unknown` where nobody could answer, never `none`/`0`/`off`, or a
# review that hung reaches Egor as nothing owed.
assert doc_has 'The statusline speaks the gate'
assert grep -Fq '"$gate" verdict "$1" "$2"' "$STATUSLINE"
assert grep -Fq "''|off) answer=off ;;" "$STATUSLINE"
assert grep -Fq '"dim "*|"bright "*|"split "*) ;;' "$STATUSLINE"
# The gate's own `unknown` is a classified answer, not a word this build cannot read: shown loud it
# is red over an outage, and `off` would be a clean bill over a tree nobody managed to read.
assert grep -Fq 'unknown) ;;' "$STATUSLINE"
assert grep -Fq 'split'"'"' '"'"'unknown*)' "$FLOW_GATE"
# Two tones in one segment, cut on the first slash and nowhere else: the numbers are the gate's
# and the weights are this line's, so a render that split them differently would say whose the
# debt is with the gate disagreeing.
assert grep -Fq '${text%%/*}${DIM}/${text#*/}${RESET}' "$STATUSLINE"
assert grep -Fq 'review_text=${review_text#rev }' "$STATUSLINE"
# The three words the gate switches on, printed nowhere else.
assert grep -Fq 'print("none")' "$RB_DEBT"
assert grep -Fq 'print(f"timed-out {hung}")' "$RB_DEBT"
assert grep -Fq 'print(f"debt {len(owed)} {owner}{share}{left_out}")' "$RB_DEBT"
assert grep -Fq 'print("split %d %d %d" % debt_split(repo, paths, session, closing_round))' \
  "$RB_DEBT"
assert doc_has '`debt <n> mine|other|unknown [<owned>] [(+<s> skipped)]`'
# The share is the debt a `--debt` review leaves out, priced by the one reader that leaves it out:
# a line quoting a number the scope never skipped is the mismatch the segment exists to end.
assert grep -Fq 'others = len(debt_scope(repo, session, links=links, closing_round=closing_round)[1])' \
  "$RB_DEBT"
assert grep -Fq 'return sorted(scope.items()), sorted(left_out - set(scope))' "$RB_DEBT"
assert doc_has '`split <own> <foreign> <orphaned>`'
# One number: every reader of this tool prices a tree through ONE helper and with the same session,
# or a round hides paths from one surface and not the other and the two disagree about the same
# repository. What an OPEN round has read is subtracted by exactly one FLAG — the commit door's
# `--closing-round`, so that round's own fixing bytes do not wall the commit that closes it — and
# by no other reader: the statusline, `--list` and the scope a `--debt` review computes all answer
# what the tree owes, and given that flag they reported a clean repository over three hours of
# worker output nothing had read (live, 2026-09-02).
assert grep -Fq 'def tree_links(repo, tree, session="", paths=None, blobs=None, ranges=None, rows=None,' "$RB_DEBT"
assert grep -Fq 'ranges = reviewed_ranges(repo, session, closing_round=closing_round) \' "$RB_DEBT"
assert grep -Fq 'if session and closing_round else ()' "$RB_DEBT"
assert grep -Fq -- '--closing-round' "$FLOW_GATE"
assert grep -Fq 'if range_holds(link, ranges, reach):' "$RB_DEBT"
assert test "$(grep -c 'tree_links(repo, tree, session' "$RB_DEBT")" -ge 3
# An unresolvable repository is not a clean one. Both spellings, because the gate reads the machine
# line and a human reads the other, and a `none`/`split 0 0 0` here is a clean bill nobody gave.
assert grep -Fq 'print("split unknown")' "$RB_DEBT"
assert grep -Fq 'print("unknown")' "$RB_DEBT"
# `--total` is the family answer, one integer over every tree the chat owes a link in, and the gate
# sums it across repositories. Pinned on both sides plus the doc: a total that came back as a
# per-tree count, or as a number where a member went unread, is a smaller number saying nothing.
assert doc_has '`--total` prints ONE integer'
assert grep -Fq 'total = bool(getattr(args, "total", False))' "$RB_DEBT"
assert grep -Fq 'print(debt_total(repo, session, closing_round))' "$RB_DEBT"
assert grep -Fq 'def debt_total(repo, session, closing_round=False):' "$RB_DEBT"
# The counter is the review target header's, not a second differ: one edit priced two ways is two
# numbers for one question, and the label is then arguing with the panel's own target line.
assert grep -Fq 'changes, _ = _scope.diff_numstat(' "$RB_DEBT"
assert grep -Fq 'repo, [str(left_file), str(right_file)], no_index=True)' "$RB_DEBT"
assert grep -Fq 'DEBT_LINE_CACHE_FILE = "debt-lines.json"' "$RB_DEBT"
assert doc_has '`<state dir>/debt-lines.json`'
# The owner word is what the gate switches on, so every word review-bench can print is named in
# the row that promises the gate reads them all — and so is the one line that carries no such word:
# debt whose owner is entirely on record must not be read back as `unknown`, and a gate parsing the
# third field positionally would take `(+1` for an ownership word.
assert grep -Fq 'owner = "mine" if owned else "other"' "$RB_DEBT"
assert grep -Fq 'word = " unknown" if unowned or not foreign else ""' "$RB_DEBT"
assert grep -Fq 'print(f"debt {len(owed)}{word}")' "$RB_DEBT"
assert doc_has '`debt 2`'
assert doc_has 'Nothing may parse positionally past the owner word'
# The count is the whole debt on BOTH branches: the gate reads field two as the number of files it
# names in its notice, and a line answering `0` over work nobody read is a clean bill nobody gave.
assert test "$(grep -c 'print(f"debt {len(owed)}' "$RB_DEBT")" -eq 2
# The line ends on the count and the ownership fields, and nothing may append a state word to it:
# what a ROUND owes is asked of the round (`fork --check`), never read off the repository's count,
# and a trailing word here is a second answer to that question for every reader of this line.
assert test "$(grep -Ec 'print\(f"debt \{len\(owed\)\}[^"]*\{(standing|locked|decreed)' "$RB_DEBT")" -eq 0
assert doc_has 'No state word ever follows it'
if test -r "$FLOW_GATE"; then
  assert grep -Fq 'if [ "${1:-}" = verdict ]; then' "$FLOW_GATE"
  assert grep -Fq 'echo "split rev $own/$foreign"' "$FLOW_GATE"
  assert grep -Fq 'echo "bright rev $own"' "$FLOW_GATE"
  assert grep -Fq 'echo "dim rev $foreign"' "$FLOW_GATE"
  # Debt nobody recorded is folded into the foreign side HERE and nowhere else: read as the asking
  # chat's it reports work that chat never did as its own to answer for.
  assert grep -Fq 'foreign=$((foreign + orphaned))' "$FLOW_GATE"
  # Nothing the gate says is red, and the watchdog has no statusline consumer at all: a killed run
  # settles nothing, so its paths are already in the numbers.
  assert test "$(grep -Ec '^[^#]*echo "loud ' "$FLOW_GATE")" -eq 0
  assert test "$(grep -Fc 'rev timeout' "$FLOW_GATE")" -eq 0
  # The verdict asks about the repository, never about the pending paths: debt outlives the commit
  # that landed it, and a question narrowed to one chat's dirty files cannot see the rest.
  assert grep -Fq 'review-bench debt --repo "$top_dir" --session "$session" "$@"' "$FLOW_GATE"
  assert grep -Fq 'answer=$(review_debt --split) || { echo off; exit 0; }' "$FLOW_GATE"
  # The total is `unknown` wherever a share of it went unread — the journal library down, no reader
  # on PATH, a member repository that failed or answered outside the grammar — because a total short
  # by one repository is a smaller number with nothing in it saying so, and `0` is a clean bill.
  assert grep -Fq 'debt-total) echo unknown; exit 0 ;;' "$FLOW_GATE"
  assert grep -Fq 'review-bench debt --repo "$dt_repo" --session "$2" --total' "$FLOW_GATE"
  assert test "$(grep -c 'dt_unknown=1' "$FLOW_GATE")" -ge 3
  assert grep -Fq '[ -n "$dt_unknown" ] && { echo unknown; exit 0; }' "$FLOW_GATE"
  # And no cap on the repositories it sums: a cap is that same silent shortfall written into the
  # code, and what bounds the render is the caller's own timeout, which answers `unknown` too.
  assert test "$(grep -c 'DEBT_TOTAL_REPOS' "$FLOW_GATE")" -eq 0
else
  fail "statusline verdict grammar across claude-setup: $FLOW_GATE is unreadable (set CLAUDE_SETUP_ROOT)"
fi
# The render's own half of that answer: anything but a bare integer becomes the sentinel `?`, and a
# cached answer past the 120s sweep becomes it too. `off` is the gate saying nothing is owed and `?`
# is nobody having answered — collapsed into one, an outage reaches Egor as a clean bill.
assert grep -Fq "[[ \"\$total\" =~ ^[0-9]+\$ ]] || total='?'" "$STATUSLINE"
assert grep -Fq "printf '%s' 'no|?'" "$STATUSLINE"
assert grep -Fq "printf '%s' unknown" "$STATUSLINE"
assert grep -Fq '[ "${review_style:-}" = unknown ] ||' "$STATUSLINE"
assert grep -Fq 'verdict_part=" ${sep} ${dot}${DIM}${body}?${RESET}"' "$STATUSLINE"
assert grep -Fq "if [ \"\$review_total\" = '?' ]; then" "$STATUSLINE"
assert doc_has 'a dim `rev ?`'

# --- Row ao: the review debt journal -------------------------------------------
# One record format for both journals in the git dir, one writer for the debt one, and a reader
# that asks nothing else about authorship: a format that drifts on either side leaves debt owned by
# nobody, which reads exactly like a co-tenant's.
assert doc_has 'Review debt journal'
assert grep -Fq 'DEBT_JOURNAL = "claude-review-debt"' "$RB_STORE"
assert grep -Fq 'COMMIT_JOURNAL = "claude-commit-journal"' "$RB_STORE"
if test -r "$FLOW_GATE"; then
  # Through the family resolver (row `bd`) and never a path of its own. The ASSIGNMENT is what is
  # pinned, and the hand-rolled spelling forbidden outright: a bare mention of the name matches a
  # comment, and a gate that went back to `gitdir=$(git rev-parse --git-dir)` with the ledger name
  # appended to it kept a per-worktree ledger while reading green here.
  gate_gitdirs=$(grep -Ec '^[[:space:]]*gitdir=\$\(' "$FLOW_GATE")
  assert test "$gate_gitdirs" -ge 1
  assert eq "$(grep -Ec '^[[:space:]]*gitdir=\$\(rj_journal_dir "' "$FLOW_GATE")" "$gate_gitdirs"
  # The gate is NOT a writer of this ledger and not a pruner of it: the door that refuses a commit
  # appending a fresh row for whatever its notice named recorded a second owner for content some row
  # already names, and a rewriter here is a row leaving a ledger where rows are facts.
  assert eq "$(grep -c 'rj_append_owned' "$FLOW_GATE")" 0
  assert eq "$(grep -cE '^(record_debt|prune_debt)\(\)' "$FLOW_GATE")" 0
  assert eq "$(grep -c 'rj_rename_map' "$FLOW_GATE")" 0
fi
# `rj_append_owned` is the ONE debt-ledger writer, and it is what puts the launcher's own row in at
# WRITE time: folded at read time instead, `worker-run`'s 7-day prune of run records makes the
# number change by itself and two chats resuming one worker session make the row nobody's.
assert grep -Fq 'rj_append_owned() { # file session epoch prev cur path' "$RJOURNAL"
assert grep -Fq 'rj_launch_chain_of "$2"' "$RJOURNAL"
assert grep -Fq 'rj_append "$1" "$launcher" "$3" "$4" "$5" "$6"' "$RJOURNAL"
# Resolved OUTSIDE a command substitution, or the memo dies with the subshell and every row
# rescans every run record; and the WHOLE chain, or a nested worker leaves the top chat on no row.
assert eq "$(grep -c 'rj_launch_chain_of "$2"' "$RJOURNAL")" 1
assert test -z "$(grep -n '\$(rj_launcher_of' "$RJOURNAL")"
assert grep -Fq 'rj_launch_chain_of() { # session -> RJ_LAUNCH_CHAIN' "$RJOURNAL"
# The chain's FIRST hop is the environment `worker-run` stamps at launch, and only then the run
# record: a fresh relay's own session id is not printed until its CLI exits, so the record's
# pairing lands after every row the worker journaled while it ran (live run
# claudeb-1788388059-13078-3ffd, 2026-09-03). One stamping point for every relay, since each
# inherits the export — an image script, a pool-run cell and a nested worker-run included.
assert grep -Fq 'export CLAUDE_LAUNCHER_SESSION="$CLAUDE_CODE_SESSION_ID"' "$WORKER_RUN"
assert grep -Fq 'rj_env_launcher() { # session' "$RJOURNAL"
assert grep -Fq 'hop=$(rj_env_launcher "$id") || {' "$RJOURNAL"
# Read for the session this process IS and for no other: pointed at another run's launcher by the
# worker sweep, the same environment names the SWEEPER's chat.
assert grep -Fq '[ -n "$RJ_SELF_SESSION" ] && [ "$1" = "$RJ_SELF_SESSION" ] || return 1' "$RJOURNAL"
assert grep -Fq 'RJ_SELF_SESSION=$chat_session' "$CLAUDE_SETUP/hooks/commit-journal.sh"
# And a relay worker's own row that names no chat is LOUD rather than an orphan: stderr under a
# non-zero exit, which is the one channel a PostToolUse reaches a model through.
assert grep -Fq 'RJ_UNATTRIBUTED=$6' "$RJOURNAL"
assert grep -Fq 'rj_in_relay() {' "$RJOURNAL"
assert grep -Fq 'if [ -n "$RJ_UNATTRIBUTED" ]; then' "$CLAUDE_SETUP/hooks/commit-journal.sh"
assert eq "$(sed -n '/^if \[ -n "\$RJ_UNATTRIBUTED" \]; then/,/^fi/p' \
  "$CLAUDE_SETUP/hooks/commit-journal.sh" | grep -c 'exit 2')" 1
# And the READER answers off those rows rather than off the run records alone, or a chat's own
# live worker reads as a stranger for the whole window the work is being done in: the record
# pairing the two ids lands when the run ends.
assert grep -Fq 'def content_coowners(repo, rows=None, launchers=None):' "$REVIEW_ROOT/share/rbench/debt.py"
assert grep -Fq 'together = content_coowners(repo, launchers=launchers) if together is None else together' "$REVIEW_ROOT/share/rbench/debt.py"
assert grep -Fq 'named = {producer} | together.get((path, link["cur"]), set())' \
  "$REVIEW_ROOT/share/rbench/debt.py"
# Each of those chats is written into the per-session repository index too, or `debt-total`
# enumerates the worker's repositories and drops the tree the chat only reached through it.
assert grep -Fq 'rj_register_repo "$launcher"' "$RJOURNAL"
assert eq "$(grep -o 'rj_append "\$debt"\|rj_append "\$journal"\|rj_append "\$dir' \
  "$CLAUDE_SETUP/hooks/commit-journal.sh" "$CLAUDE_SETUP/hooks/commit-report.sh" "$FLOW_GATE" |
  wc -l | tr -d ' ')" 0
# A row the reader cannot price is QUARANTINED, never erased: the file is spelled once, beside the
# ledger, so a rewrite that turns out to have been wrong about a row can still be argued with.
assert grep -Fq 'rj_quarantine() { # file reason record' "$RJOURNAL"
assert eq "$(grep -c '"\$1.rejected"' "$RJOURNAL")" 1
COMMIT_REPORT="$CLAUDE_SETUP/hooks/commit-report.sh"
# A rename needs no carrier now: it is a `-` birth at the new name beside a deletion at the old, both
# of which git prints, and the map existed only to move a row rather than let one leave the ledger.
assert test -z "$(grep -l 'rj_rename_map' "$FLOW_GATE" "$COMMIT_REPORT" \
  "$CLAUDE_SETUP/hooks/commit-journal.sh" 2>/dev/null)"
if test -r "$COMMIT_REPORT"; then
  # The third writer: an edit and the commit carrying it inside ONE Bash call are seen by neither
  # of the other two, and the debt that commit landed is then recorded under no chat at all.
  # The report is no writer of this ledger: a commit's rows are the EDIT hook's, taken off the same
  # Bash call, so the edits inside a commit and the commit itself reach the journal through one door.
  assert eq "$(grep -c 'rj_append_owned' "$COMMIT_REPORT")" 0
  assert grep -Fq 'journal_row() { # journal top owner prev cur relative' \
    "$CLAUDE_SETUP/hooks/commit-journal.sh"
  assert grep -Fq 'journal_commit_row() { # journal_dir top owner prev cur relative' \
    "$CLAUDE_SETUP/hooks/commit-journal.sh"
  # And the blob is what first-row-wins is asked about, never the path.
  assert grep -Fq 'blob_named() { # blob' "$CLAUDE_SETUP/hooks/commit-journal.sh"
  # Every repository the snapshot names, whatever the call's output parsed to: the block this hook
  # renders reads ONE repository, and gated on it a commit in any other took no debt row at all.
  assert grep -Fq '[ -n "$HEAD_SNAPSHOT" ] && snapshot_creates_commits &&' "$COMMIT_REPORT"
  assert grep -Fq 'cover_landed_fixes "$session" "$HEAD_SNAPSHOT"' "$COMMIT_REPORT"
  # Only a call that CREATES commits may have its range stamped, and the gate is what says which
  # kind armed the snapshot: `git pull` moves HEAD over commits other people wrote, and stamped as
  # this call's it puts an upstream author's paths into this chat's review scope.
  assert grep -Fq 'RJ_SNAPSHOT_KIND=KIND' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq "printf '%s%s%s\\n' \"\$RJ_SNAPSHOT_KIND\" \"\$RJ_TAB\" \"\${5:-commit}\"" "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  # And ONE landing list for both doors of a commit: answered by a whitelist of the report's own, a
  # kind the gate armed a snapshot for went unread there, so the commits a rebase or an `am` created
  # closed no round and took no debt row (live 2026-08-29).
  assert grep -Fq 'for kind in $RJ_LANDING_SUBCOMMANDS; do' "$COMMIT_REPORT"
  # A `git merge` that FAST-FORWARDS creates nothing either: it is the same range of other people's
  # commits a pull brings, and only a commit carrying a second parent was made by the call.
  assert grep -Fq 'if [ "${SNAPSHOT_KIND:-commit}" = merge ]; then' "$COMMIT_REPORT"
  assert grep -Fq 'git -C "$1" rev-list --no-walk --merges --stdin' "$COMMIT_REPORT"
  # One filter for every reader of this call's commits — the fix coverage and the commit block the
  # outbox queues — or a commit that closes a round is one the block never named.
  assert grep -Fq 'own_landed_commits() { # top pre' "$COMMIT_REPORT"
  assert eq "$(grep -c 'own_landed_commits "\$top" ' "$COMMIT_REPORT")" 2
  assert grep -Fq '[ "$top" = "$RJ_SNAPSHOT_KIND" ] && continue' "$COMMIT_REPORT"
  # ONE walk for the whole call and not a `git log` per commit, which is what makes the absence of
  # a cap below cost one process. `--raw --no-abbrev` because the row IS the pair of blobs and a
  # name-status walk knows only that something changed; `-m` because a merge answers an unqualified
  # diff with nothing at all, and walked against BOTH parents what it merely took from a parent is
  # already named by the row that produced it while the resolution it wrote is named by no other.
  assert grep -Fq \
    'git -C "$1" log --no-walk --raw -m --no-abbrev --no-renames -z --format=%H --stdin' \
    "$CLAUDE_SETUP/hooks/commit-journal.sh"
  # And the debt walk does not truncate: a cap there is ownership dropped for every commit past it,
  # permanently and silently. The cap survives for `fixes --cover` alone, where the cost is N
  # review-bench subprocesses inside a hook and the loss is a round staying open — the safe way.
  assert eq "$(awk '/^walk_landed\(\) \{/,/^\}/' "$CLAUDE_SETUP/hooks/commit-journal.sh" |
    grep -cE 'head -n|_CAP')" 0
  assert grep -Fq 'fixes_truncation_note() { # top count' "$COMMIT_REPORT"
  assert eq "$(grep -c 'head -n "\$LANDED_CAP"' "$COMMIT_REPORT")" 1
  # One snapshot per CALL: a chat runs Bash calls concurrently, and one name for all of them let the
  # second call's snapshot overwrite the first's. Both hooks key it on the `tool_use_id` their
  # payloads carry — the same id on the PreToolUse that writes the file and the PostToolUse that
  # consumes it — and fall back to the session-only name only where the payload carries none.
  assert grep -Fq "printf '%s/.cache/claude/review-journal/%s.%s.heads' \"\$HOME\" \"\$1\" \"\$2\"" \
    "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  # A call the gate refused takes no PostToolUse and its snapshot stays: aged out under BOTH names,
  # since the session-only fallback matches no per-call glob and the next call carrying no id of its
  # own then consumes another call's tree as its evidence.
  assert grep -Fq '\( -name "$1.*.heads" -o -name "$1.heads" \)' \
    "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq "call=\$(printf '%s' \"\$payload\" | jq -r '.tool_use_id // empty' 2>/dev/null)" \
    "$COMMIT_REPORT"
  assert grep -Fq "call=\$(printf '%s' \"\$input\" | jq -r '.tool_use_id // empty' 2>/dev/null)" \
    "$FLOW_GATE"

  # --- Row bf: the chat repository index ---------------------------------------
  # The pool the one-panel rule enumerates candidates from is the snapshots PLUS this file, because a
  # snapshot answers only for the repositories a Bash call SPELLED and is swept at 120 minutes: debt
  # born through a `git -C "$dir"` nothing expands, through a worker, or three hours ago was in no
  # pool at all, and the chat launched a panel per repository over debt it owed in several.
  assert doc_has 'Chat repository index'
  assert grep -Fq "printf '%s/.cache/claude/review-journal/%s.repos' \"\$HOME\" \"\$1\"" \
    "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'CHAT_REPOS_SUFFIX = ".repos"' "$RB_STORE"
  # And what the sum is made of: one `--total` per repository, never a per-tree count added up here.
  assert doc_has 'What it sums is `review-bench debt --total` per repository'
  assert grep -Fq 'session + CHAT_REPOS_SUFFIX' "$RB_STORE"
  # Only a plain name, the same alphabet the snapshot path is composed under: this writer composes a
  # filename off the id too. Pinned on the line FOLLOWING this composer's own header, so a
  # validation dropped from it cannot read green off the snapshot path's copy of the same case.
  assert grep -Fq "case \$1 in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac" \
    <(grep -A1 -F 'rj_session_repos() { # session' \
      "$CLAUDE_SETUP/hooks/lib/review-journal.sh")
  assert grep -Fq 'rj_register_repo() { # session top' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  # Registered behind the ONE door every row is written through, or debt born at that site reaches
  # no pool: the chat's own edits, the commits a call lands and a run record's imported rows all go
  # through it. Plus the trees a call merely REACHED, which no row of its own may ever name — a
  # snapshot answers for the repositories a call SPELLED, and this index is what outlives them.
  # Neither the gate nor the report registers anything: they write no row (block above), and a
  # reader that indexed a repository would put a chat in the pool over debt it never produced.
  assert grep -Fq 'rj_register_repo "$3" "$2" || :' "$CLAUDE_SETUP/hooks/commit-journal.sh"
  assert grep -Fq 'rj_register_repo "$session" "$row_top" || :' \
    "$CLAUDE_SETUP/hooks/commit-journal.sh"
  assert eq "$(grep -c 'rj_register_repo' "$CLAUDE_SETUP/hooks/commit-journal.sh")" 2
  # Every line but a whole-line comment: a call re-added inside a compound command or a
  # substitution is still a call, and anchoring the name to the start of a line missed it.
  assert eq "$(grep -v '^[[:space:]]*#' "$FLOW_GATE" | grep -c 'rj_register_repo')" 0
  assert eq "$(grep -v '^[[:space:]]*#' "$COMMIT_REPORT" | grep -c 'rj_register_repo')" 0
  assert grep -Fq 'snapshot_file=$(rj_head_snapshot "$session" "$call")' "$COMMIT_REPORT"
  # What the call landed is the range between the HEAD the gate wrote down before it and this one,
  # narrowed by the snapshot's mtime: a checkout inside the call can otherwise add an older branch's
  # whole existing history. Both consumers use the one helper from the shared library.
  assert grep -Fq 'rj_window_start() { # snapshot-file' "$RJOURNAL"
  assert eq "$(grep -c 'rj_window_start' "$CLAUDE_SETUP/hooks/commit-journal.sh")" 2
  assert grep -Fq 'SNAPSHOT_WINDOW_START=$(rj_window_start "$snapshot_file")' "$COMMIT_REPORT"
  assert grep -Fq 'shas=$(landed_commits "$1" "$2" "${3:-}")' "$COMMIT_REPORT"
  assert grep -Fq 'git -C "$1" log --first-parent --format=%H "$range"' "$COMMIT_REPORT"
  # `--amend` and a rebase REPLACE the commit the snapshot named: required to descend from it, the
  # hook enumerated nothing and the amend that landed was answered for by nobody. Shared history is
  # what still separates that from a checkout of an unrelated line.
  assert grep -Fq 'git -C "$1" merge-base "$2" HEAD >/dev/null 2>&1 || return 0' "$COMMIT_REPORT"
  # A repository whose HEAD resolved to nothing when the snapshot was taken is named by the sentinel
  # and read as "everything this tip reaches" — dropped instead, its first commit is the one commit
  # no reader can measure.
  assert grep -Fq 'RJ_UNBORN=unborn' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq '[ -n "$head" ] || head=$RJ_UNBORN' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'if [ "$2" = "$RJ_UNBORN" ]; then' "$COMMIT_REPORT"
  # The cap on one call's landing is read in the caller: a note written inside a command
  # substitution is written into a subshell, and the report carries no trace of what it dropped.
  assert grep -Fq 'fixes_truncation_note "$top" "$landed"' "$COMMIT_REPORT"
  assert grep -Fq 'rm -f "$snapshot_file"' "$COMMIT_REPORT"
  assert test "$(grep -c 'commit-report-last' "$COMMIT_REPORT")" -eq 0
  # The one repository each hook SPEAKS for is derived by both through the same library reader, and
  # by no extractor of their own: a target the command names and neither can resolve — an unexpanded
  # `$R`, a path that is not there — answered off the session's cwd rendered a confident block about
  # a repository where nothing happened, and armed no notice in the one the commit landed in.
  assert grep -Fq 'rj_command_target "$cmd" "$cwd"' "$COMMIT_REPORT"
  assert grep -Fq 'rj_command_target "$cmd" "$here"' "$FLOW_GATE"
  assert test "$(grep -cF 'git[[:space:]]+-C[[:space:]]+' "$COMMIT_REPORT")" -eq 0
  assert test "$(grep -cF 'git[[:space:]]+-C[[:space:]]+' "$FLOW_GATE")" -eq 0
  assert grep -Fq 'RJ_TARGET_UNRESOLVED=1' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'if [ -n "$RJ_TARGET_UNRESOLVED" ]; then' "$COMMIT_REPORT"
  assert grep -Fq 'if [ -n "$RJ_TARGET_UNRESOLVED" ]; then' "$FLOW_GATE"
  # And the set they price it over is one reader too, or the gate arms a notice in a repository the
  # report will never look for a landing in.
  assert grep -Fq 'rj_repo_set < <(rj_journal_homes "$1"; rj_command_dirs "${2-}" "$1"' \
    "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'rj_session_repo_lines "${3-}")' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'rj_target_repos "$cwd" "$cmd" "$session"' "$COMMIT_REPORT"
  assert grep -Fq 'rj_target_repos "$here" "$cmd" "$session"' "$FLOW_GATE"
  # Both hooks scope the snapshot through the same two library readers, or the repository the gate
  # wrote down and the one the report stamps in are not the same set.
  assert grep -Fq 'done < <(rj_repo_set < <(rj_journal_homes "$2"; rj_command_dirs "$3" "$4"' \
    "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'rj_session_repo_lines "$1"))' "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  assert grep -Fq 'rj_snapshot_heads "$session" "$dir" "$cmd" "${payload_cwd:-$PWD}" "$landing" "${call:-}"' \
    "$FLOW_GATE"
  # Except for a --dry-run, which lands nothing: the report exits on that same flag before it
  # consumes anything, and the file left standing under the session-only name is read by the chat's
  # next call carrying no id as its own evidence.
  # Read ONCE into `dry_run`, because the commit door reads the same answer: a flag spelled twice
  # is a commit the snapshot skips and the refusal below still walls, or the other way about. The
  # reader itself is the library's, shared with the report (block below).
  assert grep -Fq 'rj_dry_run commit "$cmd" && dry_run=1' "$FLOW_GATE"
  assert grep -Fq '[ -n "${landing:-}" ] && [ -z "$dry_run" ] &&' "$FLOW_GATE"
  # The SNAPSHOT is armed for every kind that creates commits, from one library reader, or the kind
  # the gate writes down and the kinds the report reads back drift apart. What the gate PRICES is
  # the commit alone (an amend among them): a merge, a cherry-pick, a revert, a rebase and an `am`
  # move content some commit already carried, so the committing chat's unreviewed bytes are not
  # what they land and this door says nothing about them (Egor, 2026-08-29). `update-ref` is the
  # plumbing spelling of the same move and stamps like the rest; `commit-tree` lands nothing.
  assert grep -Fq \
    'RJ_LANDING_SUBCOMMANDS="commit merge cherry-pick revert rebase am update-ref"' \
    "$CLAUDE_SETUP/hooks/lib/review-journal.sh"
  # The one landing that is a commit written by hand rather than one replayed, so the report frames
  # it like a `git commit` where the replaying kinds take their journal lines and no block.
  assert grep -Fq '[ "${SNAPSHOT_KIND:-commit}" = update-ref ] && is_commit=1' "$COMMIT_REPORT"
  assert grep -Fq 'landing=$(rj_git_lands_commit "$cmd") || landing=""' "$FLOW_GATE"
  assert grep -Fq 'git_subcommand commit && kind=commit' "$FLOW_GATE"
  assert grep -Fq 'if [ -z "$verdict_mode" ] && [ "${kind:-}" != commit ]; then' "$FLOW_GATE"
  # And a run record claims nothing beyond what it NAMES: its own `produced` rows, or its listing
  # where it wrote none. Its DIRT is a whole-checkout difference over a shared tree, so every
  # co-tenant's edit stands in it too, and its WORKDIR is normally the whole repository — inherited
  # off either, one listless record took the paths of every commit anybody made in that checkout.
  assert grep -Fq 'if [ -f "$directory/produced" ]; then' "$CLAUDE_SETUP/hooks/commit-journal.sh"
  assert eq "$(grep -cE '"\$(directory|1)/dirty"' \
    "$CLAUDE_SETUP/hooks/commit-journal.sh")" 0
  assert test -z "$(grep -nwE 'heir|HEIR' "$COMMIT_REPORT" \
    "$CLAUDE_SETUP/hooks/commit-journal.sh" 2>/dev/null)"
  # `journaled` says the record has been READ, and nothing outranks it here: the retired record is
  # closed to this scan, and what it never named is nobody's rather than the next committer's.
  assert grep -Fq '[ -e "$directory/journaled" ] && continue' \
    "$CLAUDE_SETUP/hooks/commit-journal.sh"
  # A commit takes a row only for a `cur` NO row names yet: a merge, a cherry-pick and a rebase land
  # blobs their author already produced, and the first row wins. No epoch decides it any more —
  # comparing a stamp against the commit's own `%ct` handed a worker's file to whoever was committing
  # beside it whenever the two landed in one second.
  assert doc_has 'It passes over a transition whose `cur` some row already names'
  assert eq "$(grep -c '\-ge "\$ct"' "$CLAUDE_SETUP/hooks/commit-journal.sh")" 0
fi
JOURNAL_LIB="$CLAUDE_SETUP/hooks/lib/review-journal.sh"
if test -r "$JOURNAL_LIB"; then
  # Five fields, or the reader takes a legacy three-field row — which names a path for the universe
  # and owns nothing — for a link, and the content this chat produced is owned by nobody.
  assert grep -Fq "printf '%s\\0' \"\$2\$RJ_TAB\$3\$RJ_TAB\$4\$RJ_TAB\$5\$RJ_TAB\$6\" >>\"\$1\"" \
    "$JOURNAL_LIB"
  assert doc_has '`<session-id>\t<epoch>\t<prev>\t<cur>\t<repo-relative-path>`'
  assert doc_has 'names the path for the debt universe and owns nothing'
  assert grep -Fq 'DEBT_JOURNAL' "$RB_STORE"
  # Appends participate in the rewriters' lock; a busy lock degrades to a raw append, never a
  # dropped record.
  assert grep -Fq 'rj_lock "$lock" && locked=1' "$JOURNAL_LIB"
  assert grep -Fq 'rj_append_raw "$@"' "$JOURNAL_LIB"
  # A path with ANY surviving record has an owner, and no artifact's epoch retires one: ownership is
  # written into the ledger when the work is recorded and lives there until the row leaves. The
  # epoch floor that discarded settled-looking records returned `orphaned` over debt whose author
  # the ledger names, which is the ledger and the reader contradicting each other about one path.
  assert eq "$(grep -c floor "$RB_DEBT")" 0
  # What keeps an idle chat off another chat's later work is that the later LINK carries the later
  # chat's name: ownership is per blob, the first row naming a `cur` owns it, and no reader re-dates
  # a row against the others standing for the same path.
  assert doc_has 'A LINK belongs to the session of the FIRST row naming its `cur`'
  assert eq "$(grep -c 'newest = max((epoch' "$RB_DEBT")" 0
  # Rewriters may not replace an inode a raw append just landed on: every swap is size-guarded.
  assert grep -Fq 'rj_swap() { # file tmp snap_size' "$JOURNAL_LIB"
  # The report's own sanitizing rewrite is the one rewriter left outside the library — the gate
  # writes no row and prunes none, so it swaps nothing.
  if test -r "$COMMIT_REPORT"; then
    assert grep -Fq 'rj_swap "$journal" "$tmp" "$snap_size"' "$COMMIT_REPORT"
  fi
fi

# --- Row ar: worker run liveness identity --------------------------------------
# The pid's launch instant is stamped once in llm-legs and read in claude-setup; a restamped
# started_at (walled reroute) must never be the clock a live run is judged dead by.
assert doc_has 'Worker run liveness identity'
assert grep -Fq '.pid_started_at = $began' "$ROOT/bin/worker-run"
assert eq "$(grep -c '\.pid_started_at = ' "$ROOT/bin/worker-run")" 1
# The writer is also a reader: wait, report and busy_accounts judge a supervisor through the one
# helper, or worker-run calls a recycled pid running while the hooks have retired the run.
assert grep -Fq 'PID_START_SLACK=30' "$ROOT/bin/worker-run"
assert grep -Fq 'ps -p "$2" -o etime=' "$ROOT/bin/worker-run"
# 0 is the pre-launch placeholder both sides must refuse to probe: `ps -p 0` answers nothing while
# pid 1 answers, so read as a pid it says the supervisor of a run that has not started is gone.
assert grep -Fq '[ "$2" -gt 0 ] || return 1' "$ROOT/bin/worker-run"
# An empty answer from ps means "no such process" and "ps could not answer" at once, and one of the
# two is a live run about to be reported failed or swept. Both sites ask a pid that must be listed
# before they believe the silence — pid 1, because a sandbox hiding every process but our own still
# lists `$$` and a foreign supervisor then still reads gone.
assert grep -Fq 'ps -p 1 -o etime=' "$ROOT/bin/worker-run"
assert eq "$(grep -c 'supervisor_running "\$directory" "\$pid"' "$ROOT/bin/worker-run")" 2
if test -r "$JOURNAL_LIB"; then
  assert grep -Fq 'RJ_PID_SLACK=30' "$JOURNAL_LIB"
  assert grep -Fq '[ "$pid" -gt 0 ] || { printf '"'"'unknown\n'"'"'; return 0; }' "$JOURNAL_LIB"
  assert grep -Fq '"pid_started_at"' "$JOURNAL_LIB"
  assert grep -Fq 'ps -p "$pid" -o etime=' "$JOURNAL_LIB"
  assert grep -Fq 'ps -p 1 -o etime=' "$JOURNAL_LIB"
  # EPERM from a foreign-owned live process must not read as death.
  assert eq "$(grep -c '^[^#]*kill -0' "$JOURNAL_LIB")" 0
fi
# A detached panel is judged by the same rule: `wait` calls a live panel dead and prints a log tail
# where a run is still going, or waits for ever on one that is gone.
assert grep -Fq 'return _round.pid_still_running(*stamp)' "$RB_CLI"
assert eq "$(grep -c 'def pid_still_running(' "$RB_ROUND")" 1


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
assert grep -Fq "PIN_KEY_RE='^(claudeb|codex|gemini|grok)_profile(_wall)?='" "$PIN_GATE"
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

# --- Row ai: usage wall record ------------------------------------------------
# Two processes write this file in two languages — bin/opencode-go at the 429 it sees, bin/review-bench
# for every side — so the record shape and the one rule they must spell alike, the per-window ceiling
# on a stated horizon, are pinned here. Nothing reads it to decide whether a wall still stands except
# the bench's own pool and llm-limits.sh (row al); the menubar no longer touches it at all.
WALL_FILE=walls.jsonl
OPENCODE_GO="$ROOT/bin/opencode-go"
rb_wall_file=$(grep -E '^WALL_STATE_FILE = ' "$RB_ACCOUNTS" | sed -E 's/^[^=]+= "([^"]+)"/\1/')
assert eq "$rb_wall_file" "$WALL_FILE"
assert grep -Fq "WALLS_FILE=\$WALL_STATE_DIR/$WALL_FILE" "$OPENCODE_GO"
assert grep -Fq 'override = os.environ.get("WORKER_STATS_DIR")' "$RB_STORE"
assert grep -Fq '"CLAUDEB_DIR", str(Path.home() / ".claude-profiles" / ".claudeb")' "$RB_STORE"
assert grep -Fq 'WALL_STATE_DIR=${WORKER_STATS_DIR:-${CLAUDEB_DIR:-$HOME/.claude-profiles/.claudeb}/worker-stats}' \
  "$OPENCODE_GO"
rb_wall_fields=$(grep -E '^WALL_RECORD_FIELDS = ' "$RB_ACCOUNTS" | grep -oE '"[^"]+"' | tr -d '"' | paste -sd, -)
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
rb_ceilings=$(python3 - "$RB_ACCOUNTS" <<'CEILINGS'
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
assert grep -Fq 'WALL_WINDOW_MAX_TTL_S.get(window, WALL_MAX_TTL_S)' "$RB_ACCOUNTS"
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
grammar_rb=$(python3 - "$WALL_GRAMMAR/corpus" <<'GRAMMAR'
import os
import sys
import time
sys.path.insert(0, os.environ["RBENCH_SHARE"])
import rbench as rb
# The clock is pinned to the same instant the jq side is handed, or the two sides are compared
# on different nows: reading it again after the parse rounds a horizon down by a second whenever
# the two calls straddle one, and the guard fails on a grammar that never changed.
NOW = 1000000.0
time.time = lambda: NOW
stated = []
with open(sys.argv[1]) as corpus:
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
assert grep -Fq 'return "opencode-go" if profile == "-" else f"opencode-go-{profile}"' "$RB_ACCOUNTS"
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
ROLE_VENDORS="claudeb codex gemini grok"
# review-bench staffs every one of them — SIDE_POOL_VENDOR maps a side to each — so the bench check
# below is asked about the same list the routers are.
ROLE_BENCH_VENDORS="$ROLE_VENDORS"
ROLE_ROLES="workers reviewers"
ROLE_WORK=$(mktemp -d)
ROLE_MODEL="$ROLE_WORK/worker-model"
# The writer refuses a session outright, and this suite usually runs inside one.
set_role() {
  env -u CLAUDECODE WORKER_PICK_CACHE_DIR="$ROLE_WORK/cache" WORKER_PICK_CONFIG_FILE="$ROLE_MODEL" \
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
  env HOME="$ROLE_WORK/home" LLM_LIMITS_FILE="$ROLE_WORK/limits.json" WORKER_PICK_CONFIG_FILE="$ROLE_MODEL" \
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
# The table body, not its opening line: it wraps once the fourth vendor is in it.
lua_prefixes=$(awk '/^local WORKER_MODEL_PREFIX = /{found=1} found{print; if (/\}/) exit}' "$HAMMER")
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
role_bench_out=$(python3 - "$ROLE_MODEL" "$ROLE_BENCH_VENDORS" 2>&1 <<'PY'
import os
import sys

config, vendors = sys.argv[1], sys.argv[2].split()
os.environ["WORKER_PICK_CONFIG_FILE"] = config
sys.path.insert(0, os.environ["RBENCH_SHARE"])
import rbench as rb

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
assert grep -Fq '"--account", SIDE_POOL_VENDOR[side], "--role", "reviewers"' "$RB_ACCOUNTS"
assert doc_has 'Per-vendor role switches'
assert doc_has '`worker-pick: <vendor> is switched off for <role>`'


# --- Row bp: per-vendor pause -------------------------------------------------
# `<vendor>_paused=on` parks a vendor for months, and five independent implementations have to mean
# the same thing by it: the writer, the collector that drops it from the store, the daemon that
# stops ticking it, the router, and the bench. A drifted one leaves a vendor Egor put away still
# spending — or a running vendor invisible.
PAUSE_VENDORS="claudeb codex gemini grok opencode"
PAUSE_WORK=$(mktemp -d)
PAUSE_MODEL="$PAUSE_WORK/worker-model"
# The writer accepts every vendor the readers know, opencode included, and `off` DELETES the line:
# an absent key is the running state on every reader, so an `=off` spelling would be a second one.
for vendor in $PAUSE_VENDORS; do
  rm -f "$PAUSE_MODEL"
  env -u CLAUDECODE "WORKER_PICK_CACHE_DIR=$PAUSE_WORK/cache" "WORKER_PICK_CONFIG_FILE=$PAUSE_MODEL" \
    bash -c '. "$1"; worker_model_set_paused "$2" on' _ "$WORKER_MODEL_SH" "$vendor" ||
    fail "row bp: share/worker-model.sh refuses ${vendor}, a vendor llm-limits.sh and bin/llm-refresh both key on"
  assert eq "$(cat "$PAUSE_MODEL")" "${vendor}_paused=on"
  env -u CLAUDECODE "WORKER_PICK_CACHE_DIR=$PAUSE_WORK/cache" "WORKER_PICK_CONFIG_FILE=$PAUSE_MODEL" \
    bash -c '. "$1"; worker_model_set_paused "$2" off' _ "$WORKER_MODEL_SH" "$vendor"
  assert eq "$(cat "$PAUSE_MODEL")" ""
done
# The router, asked through the binary: an empty limits file is enough, because a parked vendor is
# refused before any account is looked at. The wording is a parsed contract, so it is compared
# against the bench's own note rather than restated here.
printf '{}\n' >"$PAUSE_WORK/limits.json"
pause_pick() {
  env "HOME=$PAUSE_WORK/home" "LLM_LIMITS_FILE=$PAUSE_WORK/limits.json" "WORKER_PICK_CONFIG_FILE=$PAUSE_MODEL" \
    "WORKER_PICK_TIERS_FILE=$PAUSE_WORK/tiers" "WORKER_PICK_CACHE_DIR=$PAUSE_WORK/cache" \
    WORKER_PICK_NOW=1000000 "CLAUDEB_DIR=$PAUSE_WORK/claudeb" \
    "$WORKERPICK" --account "$1" 2>&1 >/dev/null
}
bench_paused_note() {
  python3 -c 'import os, sys
sys.path.insert(0, os.environ["RBENCH_SHARE"])
import rbench as rb
side = next(s for s, v in rb.SIDE_VENDOR.items() if v == sys.argv[1])
print(rb.paused_note(side))' "$1"
}
for vendor in claudeb codex gemini grok; do
  printf '%s_paused=on\n' "$vendor" >"$PAUSE_MODEL"
  pause_out=$(pause_pick "$vendor") &&
    fail "row bp: bin/worker-pick answered $vendor while share/worker-model.sh had written ${vendor}_paused=on: reader and writer disagree on the key"
  assert eq "$pause_out" "worker-pick: $(bench_paused_note "$vendor")"
  # Only the literal `on` parks a vendor, mirroring the literal `off` of the role keys (row `aj`).
  printf '%s_paused=off\n' "$vendor" >"$PAUSE_MODEL"
  grep -Fq 'is paused' <<<"$(pause_pick "$vendor")" &&
    fail "row bp: bin/worker-pick reads ${vendor}_paused=off as parked, while share/worker-model.sh writes that spelling for nothing and the bench vetoes on \"on\" alone"
done
rm -rf "$PAUSE_WORK"
asserts=$((asserts + 1))
# The mechanism is absence from the store: the collector deletes the entry, so every reader that
# renders a vendor off its store row renders a parked one as nothing at all.
assert grep -Fq 'delpaths([$paused[] | ["vendors", .]])' "$LLMLIMITS"
# The store spells claudeb `claude`, and the collector and the daemon must translate the same way,
# or one of them parks a vendor the other keeps polling.
assert grep -Fq "case \"\$1\" in claude) printf 'claudeb' ;;" "$LLMLIMITS"
assert grep -Fq 'case "$1" in claude) key=claudeb_paused ;;' "$ROOT/bin/llm-refresh"
# Both directions are Egor's hand only, so the menu is the one way in.
assert grep -Fq 'M.setWorkerPaused' "$HAMMER"
assert grep -Fq 'M.resumeVendor' "$HAMMER"
# The bench refuses what a caller NAMED and drops what a tier merely expanded to; a parked side
# leaves no skipped record either way.
assert grep -Fq 'def vendor_paused' "$RB_ACCOUNTS"
assert grep -Fq 'def refuse_paused_sides' "$RB_ACCOUNTS"
assert grep -Fq 'def drop_paused_specs' "$RB_ACCOUNTS"
assert doc_has 'Per-vendor pause'
assert doc_has '`<vendor>_paused=on`'
assert doc_has 'worker_model_set_paused'
assert doc_has '`cb⏸off`/`cx⏸off`/`gx⏸off`/`gr⏸off`'

# --- Row ak: auto-refresh vendor roster --------------------------------------
# The roster is spelled ONCE, in `live_vendors`, and the seed, the tick loop and the state validator
# all read it: a vendor present in the loop but missing from the seed would read as a null rung on
# every tick, and one missing from the validator would throw away every state file written before
# it existed. `opencode` is the inverted one: it has no usage endpoint, so anything that would make
# it poll on the other four's cadence spends the plan. A paused vendor (row bp) drops out of that
# one list and so out of all three consumers at once.
LLMREFRESH="$ROOT/bin/llm-refresh"
REFRESH_VENDORS="claude codex gemini grok opencode"
refresh_roster=$(sed -n '/^live_vendors() {/,/^}/p' "$LLMREFRESH" | grep -E '^  for vendor in ' | head -n1)
[ -n "$refresh_roster" ] ||
  fail "row ak: bin/llm-refresh's live_vendors no longer spells the roster"
for vendor in $REFRESH_VENDORS; do
  assert grep -Fq " $vendor" <<<"$refresh_roster"
done
assert grep -Fq '$live | map(. as $vendor |' "$LLMREFRESH"
assert grep -Fq '$live | all(. as $vendor | $state | has($vendor))' "$LLMREFRESH"
[ "$(grep -cE '^  for vendor in claude codex gemini grok opencode' "$LLMREFRESH")" -eq 2 ] ||
  fail "row ak: bin/llm-refresh's tick loop no longer iterates the same roster live_vendors spells"
asserts=$((asserts + 1))

# The inversion, asked of the daemon rather than of its prose: the wall state comes from the
# collector row (row al), never from the record, and only a standing wall is probed — through the
# one subcommand that answers for free while the window is shut.
# Neither Gemini's base profile nor Grok's names an account to revive, so an empty vendor row must
# name none: a `main` invented here is a refresh against a HOME that carries no login.
assert grep -Fq 'elif $vendor == "gemini" or $vendor == "grok" then empty' "$LLMREFRESH"
# Grok's expired access token is work a tick can do and Claude's is not; spelling that split in
# prose alone is what left an expired grok row unrefreshed for hours.
assert grep -Fq '$status == "failed" or ($status == "expired" and $vendor != "grok")' "$LLMREFRESH"
# One touch path: the collector's deliberate refresh runs it, so the heartbeat tick and the menu's
# Hard refresh share it, and the daemon itself never runs the vendor CLI for grok.
assert grep -Fq 'exec models' "$LLMLIMITS"
assert eq "$(grep -c 'exec models' "$LLMREFRESH")" 0
assert grep -Fq 'LLM_LIMITS_GROK_TOUCH_TIMEOUT:-30' "$LLMLIMITS"
assert doc_has 'grokb <account> exec models'
assert doc_has '`LLM_LIMITS_GROK_TOUCH_TIMEOUT` (`30`s)'
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
assert grep -Fq 'rows = [row for row in rows if row[0] >= stamp]' "$RB_ACCOUNTS"
assert grep -Fq 'OPENCODE_SEEN_DIR = "opencode-seen"' "$RB_ACCOUNTS"
# Digits only on both sides: a garbled stamp is not evidence of a completion, and read as one it
# would open a plan that is still refusing.
assert grep -Fq "tr -dc '0-9'" "$LLMLIMITS"
assert grep -Fq 'char for char in raw if char in "0123456789"' "$RB_ACCOUNTS"
oc_filter_line=$(grep -n -F 'rows = [row for row in rows if row[0] >= stamp]' "$RB_ACCOUNTS" | cut -d: -f1)
oc_standing_line=$(grep -n -F 'wall = standing_wall(rows)' "$RB_ACCOUNTS" | cut -d: -f1)
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
assert grep -Fq 'os.environ.get("OPENCODE_GO_PROFILES")' "$RB_ACCOUNTS"
bench_roster() {
  OPENCODE_GO_PROFILES="$1" python3 - <<'OC_ROSTER_READER'
import os
import sys
sys.path.insert(0, os.environ["RBENCH_SHARE"])
import rbench as rb
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
# The other half of the record, and the one that answers for a run which edited through the shell
# alone: the worker's own session, whose hooks journaled those edits under an id no chat in the
# repository answers for. One spelling across the writer and both readers, or the launching chat
# commits its worker's work with no debt on it — which is exactly how it went in live (2026-08-20).
assert grep -Fq '>>"$directory/worker-session"' "$WORKER_RUN"
# EVERY vendor's session, not claudeb's alone: grok loads this machine's hooks out of
# `~/.claude/settings.json` for Claude compatibility and journals under its own id, and gated on
# claudeb those rows read as a chat nothing here answers for (live 2026-09-03).
assert eq "$(sed -n '/^record_worker_session()/,/^}/p' "$WORKER_RUN" |
  grep -c '= claudeb \] || return 0')" 0
assert grep -Fq 'session=$(session_id "$directory")' "$WORKER_RUN"
# The third reader: a waiver naming no path must drop the files a co-tenant's worker run claims,
# which it can only do by looking in the same directory the other two sweep.
CHATNAMES="$ROOT/share/chat_names.py"
rb_run_root=$(sed -n '/^def worker_run_root():/,/^$/p' "$CHATNAMES" |
  sed -n 's|.*Path.home() / "\(.*\)" / "\(.*\)")$|\1/\2|p' | head -1)
worker_run_root=$(grep -oE 'WORKER_RUN_DIR:-\$HOME/[^}]*' "$WORKER_RUN" | head -1 | sed 's|.*\$HOME/||')
assert eq "$rb_run_root" '.cache/claude-worker-runs'
assert eq "$worker_run_root" "$rb_run_root"
assert grep -Fq 'os.environ.get("WORKER_RUN_DIR")' "$CHATNAMES"
assert grep -Fq 'if not launcher or (directory / "journaled").exists():' "$RB_STORE"
# The launcher walk lives once (row `aw`): review-bench imports it rather than keeping a second
# reading of the same records, which is how the two answers stayed reconcilable at all.
assert grep -Fq '(directory / "worker-session").read_text().split()' "$CHATNAMES"
assert test -z "$(grep -rl 'worker-session' --include='*.py' "$RB_PKG")"
assert grep -Fq 'worker_run_root, worker_session_launchers' "$RB_STORE"
assert doc_has 'Worker files reach the launching chat'
assert doc_has 'whose first line is `WORKDIR: <dir>`'
assert doc_has '`<run-dir>/worker-session`'
# The last channel a shell edit can reach a reader through: the run's own workdir dirt, bounded by
# what was already uncommitted at launch and by what the listing already names. One spelling across
# the writer and its reader, and one rule about what it may claim — evidence of content, never of
# authorship — or a snapshot of a shared checkout is read as one chat's work.
assert grep -Fq 'mv -f "$directory/dirty-before.tmp.$$" "$directory/dirty-before"' "$WORKER_RUN"
# The floor exists or nothing is claimed: an empty file is what a clean tree at launch looks like,
# so a git that could not answer must leave none at all.
assert grep -Fq '[ -f "$directory/dirty-before" ] || return 0' "$WORKER_RUN"
assert grep -Fq 'mv -f "$directory/dirty.tmp.$$" "$directory/dirty"' "$WORKER_RUN"
assert rb_all_have 'listing="dirty"' "$RB_STORE" "$RB_ROUND"
# Folded into the debt universe and NEVER into a reading that names an owner: a name attached to a
# path `git status` alone knows about hands one chat a waiver over another's work, and answers for
# a co-tenant's commits on that chat's own statusline (live 2026-08-25).
assert eq "$(sed -n '/^def run_record_claims/,/^def /p' "$RB_STORE" | grep -c 'dirty')" 0
assert eq "$(sed -n '/^def tree_links/,/^def /p' "$RB_DEBT" | grep -c 'dirt')" 0
assert grep -Fq 'named |= set(_store.run_dirty_paths(repo) if dirty is None else dirty)' "$RB_DEBT"
assert grep -Fq 'owner=producer if status == LINK_OWED else "",' "$RB_DEBT"
assert doc_has '`<run-dir>/dirty`'
assert doc_has '`<run-dir>/dirty-before`'
# The CONTENT half of the record: the commit the tree stood on at launch, and one row per link the
# run produced against it. Both grammars are pinned — the edit row and the commit row with its
# fourth field — because a sweep reading a field it did not expect writes a path where a blob goes.
assert grep -Fq 'mv -f "$directory/head-before.tmp.$$" "$directory/head-before"' "$WORKER_RUN"
assert grep -Fq 'mv -f "$directory/produced.tmp.$$" "$directory/produced"' "$WORKER_RUN"
assert grep -Fq "printf '%s\\t%s\\t%s\\n' \"\$prev\" \"\$cur\"" "$WORKER_RUN"
assert grep -Fq 'printf "%s\t%s\t%s\tcommit\n", prev, cur, path' "$WORKER_RUN"
assert grep -Fq 'log --raw -m --no-renames --no-abbrev --reverse -z --format=%H "$head..$after"' \
  "$WORKER_RUN"
# Only for a run some chat answers for, and never rewritten once it stands: a claim APPENDS.
assert grep -Fq '[ -s "$directory/launcher" ] || return 0' "$WORKER_RUN"
assert grep -Fq '>>"$directory/produced"' "$WORKER_RUN"
assert doc_has '`<run-dir>/head-before`'
assert doc_has '`<run-dir>/produced`'
COMMIT_JOURNAL="$CLAUDE_SETUP/hooks/commit-journal.sh"
if [ -r "$COMMIT_JOURNAL" ]; then
  # The launching chat is read off the launcher file, and every record is walked: a dead run whose
  # chat never came back is journaled by whoever is here, under that chat's name and not this one's.
  assert grep -Fq 'owner=$(head -n1 "$launcher" 2>/dev/null)' "$COMMIT_JOURNAL"
  # One predicate for whether a record can still change, shared with the hook that stamps a commit's
  # debt: an exit code (the run's own statement that it is over, whoever launched it), a supervisor
  # read dead, or the age release. Nothing that is not final is swept OR retired.
  assert grep -Fq 'rj_run_final "$directory" || continue' "$COMMIT_JOURNAL"
  assert grep -Fq '[ -f "$1/exit_code" ] && return 0' "$JOURNAL_LIB"
  # What it could NOT record goes to the model too: a PostToolUse stderr on exit 0 reaches nobody
  # who could review, waive or hand on the files it names.
  assert grep -Fq 'emit_terminal_notes' "$COMMIT_JOURNAL"
  # The record's owner is what every row it yields is written UNDER, handed to the importer as an
  # argument: read off the sweeping chat's own session instead, a dead worker's files land in the
  # ledger of whichever chat happened to take the tool call that swept it.
  assert grep -Fq 'journal_produced "$directory" "$owner" "$journal_dir"' "$COMMIT_JOURNAL"
  assert grep -Fq 'journal_listed "$directory" "$owner" "$journal_dir"' "$COMMIT_JOURNAL"
  assert grep -Fq "sed -n 's/^WORKDIR: //p' \"\$listing\"" "$COMMIT_JOURNAL"
  assert grep -Fq "'UNKNOWN: '*|'PARTIAL: '*|'WORKDIR: '*|'') continue ;;" "$COMMIT_JOURNAL"
  # A record about ANOTHER chat's run is that chat's to act on: whoever sweeps it leaves the
  # sentence in the OWNER's spool, since printed here it reaches a reader who can do nothing with
  # it while the chat whose files are named nowhere never hears of them at all.
  assert grep -Fq 'marker=$dir/$owner.commit-journal.$key' "$COMMIT_JOURNAL"
  assert grep -Fq 'printf '"'"'%s\n'"'"' "$2" >>"$dir/$owner.commit-journal.notes"' "$COMMIT_JOURNAL"
  # Moved aside before it is read: a foreign sweep appending between the read and the unlink writes
  # into a file about to be deleted, and that sentence is the only record that some chat's files are
  # named nowhere.
  assert grep -Fq 'if mv -f "$spool" "$taken" 2>/dev/null; then' "$COMMIT_JOURNAL"
  # The run's own content answer is taken where it stands: re-derived from a tree that has moved on
  # since, the sweep prices the same work a second time and can only disagree with the record.
  assert grep -Fq '"$directory/produced"' "$COMMIT_JOURNAL"
  # A row with NO owner is refused at the door: the blank owner field is the legacy rows' spelling
  # for nobody's, and a fresh row wearing it is content the reader prices and can hand to no chat.
  assert grep -Fq '[ -n "$3" ] || return 1' \
    <(grep -A1 -F 'journal_row() { # journal top owner prev cur relative' "$COMMIT_JOURNAL")
  # The record's own fields, and the LEDGER they land in: a transition one of the run's own COMMITS
  # landed is the debt ledger's, everything else the commit journal's, and a debt row stamped into
  # the commit journal is read by nobody pricing debt.
  assert grep -Fq 'journal_row "$1/$RJ_DEBT_JOURNAL" "$2" "$3" "$4" "$5" "$6" || return 1' \
    "$COMMIT_JOURNAL"
  assert grep -Fq 'journal_commit_row "$3" "$RUN_TOP" "$2" "$prev" "$cur" "$relative"' \
    "$COMMIT_JOURNAL"
  # Including the note about a listing no workdir can anchor: keyed and printed under the SWEEPING
  # chat it is spent on a marker the owner never sees and read by a chat that can do nothing about
  # it, while the one whose files are named nowhere never hears of them. Every note a record earns
  # carries it, bar the one whose record names no usable owner to carry.
  assert eq "$(grep -c '^        "\$owner"$' "$COMMIT_JOURNAL")" 2
  assert grep -Fq 'liveness=$(rj_run_liveness "$1")' "$JOURNAL_LIB"
  # ...with one release from that rule: a record whose liveness stays unknown can never be answered
  # for — no launch stamp to compare, or a `ps` that lists no process at all — so past a couple of
  # days its listing is as final as it will ever be. Anything that still reads live or dead never
  # reaches the release.
  assert grep -Fq '[ "$liveness" = unknown ] || return 1' "$JOURNAL_LIB"
  assert grep -Fq 'RJ_RUN_STALE_AFTER=172800' "$JOURNAL_LIB"
  assert grep -Fq ': >"$directory/journaled"' "$COMMIT_JOURNAL"
  # A final record that will never name a file is retired unread: there is nothing left to import,
  # and its readers hold the whole workdir as pending while it sits there. One per terminal ground
  # — no usable owner, no `produced` and no listing, no workdir a repository holds — plus the one
  # after a sweep that recorded everything it read.
  assert eq "$(grep -c ': >"$directory/journaled"' "$COMMIT_JOURNAL")" 4
  # Retired is not resolved, and nothing inherits what the record never named: no heir file is
  # written, and a path the run never listed is nobody's rather than the next committer's or the
  # launcher's (live 2026-08-24, 2026-08-25).
  assert test -z "$(grep -nwE 'heir|HEIR' "$COMMIT_JOURNAL" 2>/dev/null)"
  # The other door of the same writer, and the earlier one: what THIS call produced is recorded off
  # the content snapshot at the call, under the session that ran it, since a commit that arms no
  # notice would otherwise land content owed by nobody. Into the COMMIT journal — a call's own edit
  # becomes debt only where a commit lands it — and through the same one door, which is what puts
  # the launcher's own row in beside a worker's.
  assert grep -Fq \
    'journal_row "$journal_dir/$RJ_COMMIT_JOURNAL" "$top" "$session" "$prev" "$cur" "$path"' \
    "$COMMIT_JOURNAL"
else
  fail "worker files reach the launching chat: $COMMIT_JOURNAL is unreadable (set CLAUDE_SETUP_ROOT)"
fi
REVIEW_GATE="$CLAUDE_SETUP/hooks/review-flow-gate.sh"
if [ -r "$REVIEW_GATE" ]; then
  assert grep -Fq 'grep -l -x -F -- "$1" "$runs"/*/launcher' "$REVIEW_GATE"
  # The chat's own runs first, then the runs its WORKERS launched — one hop and one only, so a
  # worker of a worker is still this chat (row `am`) while a chain deeper than that costs no walk.
  assert grep -Fq 'scan_owner_runs "$session"' "$REVIEW_GATE"
  assert grep -Fq 'scan_owner_runs "$owner"' "$REVIEW_GATE"
  # A record the journal has not taken over is still this chat's pending work.
  assert grep -Fq "'WORKDIR: '*|'UNKNOWN: '*|'PARTIAL: '*|'') continue ;;" "$REVIEW_GATE"
  assert grep -Fq '[ -e "$directory/journaled" ] && continue' "$REVIEW_GATE"
  # Read for every state a run can be in, and ahead of the marker that retires its listing: nothing
  # ever renames what the worker's own session journaled. Definition plus the two branches a record
  # can reach the fold through — unfinished and finished-unswept.
  assert grep -Fq 'done <"$directory/worker-session"' "$REVIEW_GATE"
  assert eq "$(grep -c 'fold_worker_session' "$REVIEW_GATE")" 3
  assert grep -Fq 'fold_worker_journal' "$REVIEW_GATE"
  assert eq "$(grep -c 'fold_listing' "$REVIEW_GATE")" 3
else
  fail "the gate reads the same run records: $REVIEW_GATE is unreadable (set CLAUDE_SETUP_ROOT)"
fi

# --- Row an: launching-chat pid walk ------------------------------------------
# The same walk in bash and in python, and a drift between them is silent: the writer records a
# session the reader would never have resolved the same way, and a run renders in the statusline of
# the wrong chat or of none.
walk_hops_bash=$(grep -oE '\[ "\$hops" -lt [0-9]+ \]' "$STATUSLINE" | grep -oE '[0-9]+')
walk_hops_py=$(grep -oE '^SESSION_WALK_HOPS = [0-9]+' "$RB_STORE" | grep -oE '[0-9]+')
assert eq "$walk_hops_bash" 15
assert eq "$walk_hops_py" "$walk_hops_bash"
assert doc_has 'at most `15` hops and stopping at pid 1'
assert grep -Fq 'ps -o ppid= -p' "$STATUSLINE"
assert grep -Fq '["ps", "-o", "ppid=", "-p", str(pid)]' "$RB_STORE"
assert grep -Fq '$HOME/.claude/sessions/$pid.json' "$STATUSLINE"
assert grep -Fq 'Path.home() / ".claude" / "sessions"' "$RB_STORE"
assert grep -Fq 'f"{pid}.json"' "$RB_STORE"
for walk_site in "$STATUSLINE" "$RB_STORE"; do
  assert grep -Fq 'sessionId' "$walk_site"
done
assert grep -Fq 'REVIEW_BENCH_SESSION_DIR' "$RB_STORE"
# Precedence, not just the walk: the recorded session answers first on both sides, or the fallback
# becomes the answer and a backgrounded run — whose parents are gone — is attributed to nobody.
assert grep -Fq 'session=progress_session' "$RB_CLI"
assert grep -Fq 'review_run_owner "$progress_run_session" "$progress_pid"' "$STATUSLINE"
assert doc_has 'the recorded `session` first, the walk as the fallback'


# --- Row av: the doctor snapshot is the menubar's whole vocabulary -----------
# The renderer scans no store and computes no threshold: a class the writer adds and the Lua list
# does not hold is a count nobody ever sees.
assert doc_has '`<state_dir>/doctor-snapshot.json`'
assert grep -Fq 'DOCTOR_SNAPSHOT = "doctor-snapshot.json"' "$RB_DEBT"
assert grep -Fq 'doctor-snapshot.json' "$HAMMER"
doctor_classes_py=$(python3 - <<'DOCTORPY'
import os
import sys

sys.path.insert(0, os.environ["RBENCH_SHARE"])
import rbench as module
from datetime import datetime, timezone
document = module.doctor_snapshot_document(
    {name: [] for name in module.DOCTOR_CLASSES}, datetime.now(timezone.utc)
)
# The document as it is WRITTEN, not the constant beside it: an extra key here is one the reader
# was never told about, and a missing one is a row rendered off nothing.
print(",".join(sorted(document)))
print(",".join(module.DOCTOR_CLASSES))
print(",".join(sorted(document["anomalies"])))
DOCTORPY
)
assert eq "$(sed -n 1p <<<"$doctor_classes_py")" "anomalies,as_of,total"
doctor_classes=$(sed -n 2p <<<"$doctor_classes_py")
assert eq "$(sed -n 3p <<<"$doctor_classes_py")" \
  "$(tr ',' '\n' <<<"$doctor_classes" | sort | paste -sd, -)"
assert eq "$doctor_classes" \
  "untriaged,undelivered,stuck_fixes,orphan_debt,kill_asymmetry"
# The overflow line rides BESIDE the classes and is none of them: counted as one it would reach the
# menubar as a backlog, and the Lua has no way to learn that this one is the launcher's own failure.
assert grep -Fq 'DOCTOR_ROUND_OVERFLOW = "rounds_past_two"' "$RB_DEBT"
assert test "$(grep -c 'DOCTOR_ROUND_OVERFLOW' "$HAMMER")" -eq 0
assert doc_has '`rounds_past_two`, which `doctor` prints beside the five'
doctor_classes_lua=$(sed -n '/^local DOCTOR_CLASSES = {/,/^}/p' "$HAMMER" \
  | grep -oE '"[a-z_]+"' | tr -d '"' | paste -sd, -)
assert eq "$doctor_classes_lua" "$doctor_classes"
for doctor_class in $(tr ',' ' ' <<<"$doctor_classes"); do
  assert doc_has "\`$doctor_class\`"
done
# One store, spelled the same way on both sides: a menu reading another one reports on records
# nobody is writing.
assert grep -Fq 'os.environ.get("WORKER_STATS_DIR")' "$RB_STORE"
assert grep -Fq 'os.getenv("WORKER_STATS_DIR")' "$HAMMER"
assert grep -Fq 'os.getenv("CLAUDEB_DIR")' "$HAMMER"
assert grep -Fq '"/worker-stats/doctor-snapshot.json"' "$HAMMER"
assert grep -Fq 'home .. "/.claude-profiles/.claudeb"' "$HAMMER"
# The ages are the tool's alone: a threshold spelled on the rendering side is one nobody can move.
# Asked of the doctor block itself and of every spelling one age has — the second count, the hour
# form and the day form — because the Lua carries unrelated week and day literals of its own, and
# the renderer's only number is the snapshot age it computes over `as_of`.
assert eq "$(grep -c 'DOCTOR_AGES_S = {' "$RB_DEBT")" 1
doctor_lua=$(sed -n '/^local DOCTOR_CLASSES = {/,/^local function readLlmLimits/p' "$HAMMER")
assert grep -Fq 'function appendDoctor' <<<"$doctor_lua"
assert grep -Fq 'function doctorStaleSuffix' <<<"$doctor_lua"
doctor_ages=$(python3 - <<'AGEPY'
import os
import sys

sys.path.insert(0, os.environ["RBENCH_SHARE"])
import rbench as module
for seconds in sorted(set(module.DOCTOR_AGES_S.values())):
    print(seconds)
    print(f"{seconds // 3600} * 3600")
    if seconds % 86400 == 0:
        print(f"{seconds // 86400} * 24 * 3600")
AGEPY
)
while IFS= read -r doctor_age; do
  assert eq "$(grep -cF -- "$doctor_age" <<<"$doctor_lua")" 0
done <<<"$doctor_ages"


# --- Row aw: one resolver names every chat -----------------------------------
# A chat is shown under the name Claude Code gave it and under nothing else. Two consumers name
# chats and a third store (the harness session records) holds a name that looks like one and is
# not, so a second reading of any of it is how an invented name reaches Egor.
CHATFIND="$ROOT/bin/chat-find"
assert doc_has 'One resolver names every chat'
assert doc_has 'one implementation, `share/chat_names.py`'
assert test -f "$ROOT/share/chat_names.py"
assert test ! -e "$REVIEW_ROOT/share/chat_names.py"
assert grep -Fq 'from chat_names import' "$CHATFIND"
assert test -n "$(grep -rlF 'from chat_names import' --include='*.py' "$RB_PKG")"
# The transcript ROOTS are part of that one reading: every chat here lives under a claudeb profile,
# so a consumer globbing `~/.claude/projects` for itself reads every one of them as gone.
assert grep -Fq 'def transcript_roots():' "$CHATNAMES"
assert doc_has '`transcript_path`'
assert test -z "$(grep -rl '"\.claude" / "projects"' --include='*.py' "$RB_PKG")"
# The shell surfaces name a chat through the same resolver, over one entry point rather than a
# reading of their own: a hook that scanned a transcript for itself is a second answer to the
# question this row exists to keep single.
CHATNAME="$ROOT/bin/chat-name"
assert test -x "$CHATNAME"
assert grep -Fq 'from chat_names import chat_label, chat_name, resolve_session, short_session' "$CHATNAME"
assert doc_has '`bin/chat-name`'
CHAT_NAME_NOTICE="$CLAUDE_SETUP/hooks/stop.d/notice-chat-names.sh"
if [ -r "$CHAT_NAME_NOTICE" ]; then
  assert eq "$(grep -c 'aiTitle\|customTitle\|nameSource' "$CHAT_NAME_NOTICE")" 0
fi
# The harness placeholder is refused in exactly one place, and neither consumer reads that store
# for itself — a second reader is a name he has never seen, on a surface that swears it is his.
assert grep -Fq 'DERIVED_NAME_SOURCE = "derived"' "$CHATNAMES"
assert eq "$(grep -c 'nameSource' "$CHATFIND")" 0
assert test -z "$(grep -rl 'nameSource' --include='*.py' "$RB_PKG")"
# Same for the title events: one reader of `ai-title`/`custom-title`, or the two consumers can
# disagree about what a chat is called.
assert grep -Fq "NAME_PATTERNS = ('\"custom-title\"', '\"ai-title\"')" "$CHATNAMES"
assert eq "$(grep -c 'aiTitle' "$CHATFIND")" 0
assert test -z "$(grep -rl 'aiTitle' --include='*.py' "$RB_PKG")"
# The id a nameless chat falls back to is one length, or one surface prints a prefix another
# reader cannot match to a session.
chat_short=$(grep -oE '^SHORT_ID = [0-9]+' "$CHATNAMES" | grep -oE '[0-9]+')
assert eq "$chat_short" 8
assert doc_has 'first 8 characters'
# Every review-bench surface that prints a session id prints its NAME beside it, through the two
# spellings `store` owns and never a resolver call of its own: a bare id is a chat Egor cannot find
# in his window list, and a surface reaching past these two is how one id gets two names.
assert doc_has '`chat_display`'
assert doc_has '`chat_suffix`'
assert grep -Fq 'def chat_display(session, launchers=None, store=None):' "$RB_STORE"
assert grep -Fq 'def chat_suffix(session, launchers=None, store=None):' "$RB_STORE"
assert grep -Fq '_store.chat_display(session)' "$RB_DEBT"
# Both foreign-chat refusals name the chat: they exist to send a reader to another conversation.
assert eq "$(grep -c '_store.chat_suffix(' "$RB_REPORT")" 2

# --- Row ay: sanctioned headless launchers ------------------------------------
# The list of tools that own their launches is spelled in the contract and again in the gate's
# regex. Drift either way is silent: a launcher the gate forgot has its every run denied, and a
# spelling the contract forgot is a bare launch nobody can see.
LAUNCH_GATE="${WORKER_LAUNCH_GATE:-$HOME/.claude/hooks/worker-launch-gate.sh}"
assert test -x "$LAUNCH_GATE"
gate_sanctioned=$(grep -m1 '^SANCTIONED_RE=' "$LAUNCH_GATE" |
  grep -oE '[a-z][a-z-]+-(run|bench|limits|driver|image|go|research)' | sort -u | paste -sd' ' -)
for launcher in worker-run review-bench llm-limits claude-session-driver opencode-go gemini-research; do
  assert grep -Fq "\`$launcher\`" "$ROOT/$DOC"
  assert grep -Fq "$launcher" "$LAUNCH_GATE"
done
assert eq "$gate_sanctioned" 'claude-session-driver gemini-research llm-limits opencode-go review-bench worker-run'
# The OWNED launchers are sanctioned only in the hand that owns them, so each has a regex of its
# own and NONE of them may reappear in SANCTIONED_RE — named there, an image would be generated
# from any chat's Bash with nothing rendering the account it spent. The extraction above still
# reads the `-image` shape, so a re-added one breaks that equality rather than passing unseen.
for owned in codex-image gemini-image grok-image; do
  assert grep -Fq "\`$owned\`" "$ROOT/$DOC"
done
assert grep -Eq '^OWNED_IMAGE_RE=.*\(codex\|gemini\|grok\)-image' "$LAUNCH_GATE"
assert grep -Eq '^OWNED_RUN_RE=.*worker-run.*\(start\|wait\)' "$LAUNCH_GATE"
assert doc_has 'sanctioned only in the hand that owns them'
# `claudeb revive` and `claudeb warm` are subcommands, not binaries: the gate must not exempt every
# `claudeb` line, or the bare launch it exists to deny walks straight through.
assert grep -Fq 'claudeb[[:space:]]+(revive|warm)' "$LAUNCH_GATE"
assert doc_has '`claudeb revive`, `claudeb warm`'
# Every bare-launch spelling the contract names has a pattern, and every pattern a spelling.
for launch_spelling in 'claude -p' 'claudeb … -p' 'codex exec' 'codexb … exec' 'gemini -p' 'geminib … --print' 'agy … --print' 'opencode run' 'grok … -p' 'grokb … --prompt-file'; do
  assert grep -Fq "\`$launch_spelling\`" "$ROOT/$DOC"
  assert grep -Fq "\`$launch_spelling\`" "$ROOT/docs/routing-contract.md"
done
# Six vendor launch patterns, counted inside the array alone: the same command-position anchor is
# reused by the worker-run ownership rule, which is not a vendor.
assert eq "$(sed -n '/^LAUNCH_RES=(/,/^)/p' "$LAUNCH_GATE" | grep -Fc '${VENDOR_WORD}')" 6
assert grep -Fq 'OWNED_RUN_RE=' "$LAUNCH_GATE"
assert grep -Fq 'grep -Eq "$SANCTIONED_RE" <<<"$cmd" && exit 0' "$LAUNCH_GATE"
assert grep -Fq 'worker-launch-gate.sh' "$WORKER_GATE_SETTINGS"
assert doc_has 'Sanctioned headless launchers'
assert grep -Fq '## Sanctioned launchers' "$ROOT/docs/routing-contract.md"

# --- Row bc: gemini main's removal marker ------------------------------------
# Two spellings of this path is a removal one tool performs and the other never sees: the menubar
# hides main while `geminib run main` still launches it, or the reverse.
assert doc_has "Gemini main's removal marker"
assert doc_has '`~/.llm-limits-gemini.json.removed`'
gemini_main_marker=$(gemini_base_home=/fixture-home \
  /bin/bash -c '. "'"$GEMINI_ACCOUNTS"'" && gemini_removal_marker main')
assert eq "$gemini_main_marker" '/fixture-home/.llm-limits-gemini.json.removed'
gemini_named_marker=$(gemini_base_home=/fixture-home \
  /bin/bash -c '. "'"$GEMINI_ACCOUNTS"'" && gemini_removal_marker work')
assert eq "$gemini_named_marker" '/fixture-home/.llm-limits-gemini/work.json.removed'
# Both readers reach it through the shared resolver rather than spelling it.
assert grep -Fq 'gemini_legacy_removed=$(gemini_removal_marker main)' "$LLMLIMITS"
assert grep -Fq 'gemini_account_marker() { gemini_removal_marker "$1"; }' "$LLMLIMITS"
assert grep -Fq 'gemini_main_removed() { [ -e "$(gemini_removal_marker main)" ]; }' "$GEMINI_ACCOUNTS"
assert grep -Fq 'marker=$(gemini_removal_marker "$name")' "$GEMINIB"

for gemini_marker_reader in "$LLMLIMITS" "$GEMINIB"; do
  if grep -Fq '.llm-limits-gemini.json.removed' "$gemini_marker_reader"; then
    fail "row bc: $(basename "$gemini_marker_reader") spells main's marker instead of resolving it"
  fi
done

# --- Row bd: one journal ledger per git family ---------------------------------
# Per-worktree git dirs gave one project two ledgers: a waiver from the main checkout cleared 33
# paths while twelve stayed owed in a worktree of it, and each surface answered from whichever file
# it had opened. Both sides resolve the directory with the SAME command, name the two files once
# apiece, and nothing else in either repository's code may spell them.
assert doc_has 'Journal ledger resolver'
JOURNAL_RESOLVE='rev-parse --path-format=absolute --git-common-dir'
assert doc_has "$JOURNAL_RESOLVE"
rb_journal_dir=$(sed -n '/^def journal_dir(/,/^def [a-z_]*(/p' "$RB_STORE")
# review-bench resolves the family once, in the memoized git_common_dir, and journal_dir reads it
# from there: the command is pinned in the resolver, every reader in the call.
assert grep -Fq "$JOURNAL_RESOLVE" <<<"$(sed -n '/^def git_common_dir(/,/^def [a-z_]*(/p' "$RB_STORE")"
assert eq "$(grep -Fc "$JOURNAL_RESOLVE" "$RB_STORE")" 1
assert grep -Fq 'git_common_dir(repo)' <<<"$rb_journal_dir"
# The statusline keys BOTH its journal-watching caches on the family's ledger, so each has to open
# the same file the answer it caches was read out of — resolved once, in one helper, or the two
# keys drift apart exactly as the two ledgers once did.
statusline_journal_dir=$(sed -n '/^journal_dir() {/,/^}/p' "$STATUSLINE")
assert grep -Fq "$JOURNAL_RESOLVE" <<<"$statusline_journal_dir"
assert eq "$(grep -Fc "$JOURNAL_RESOLVE" "$STATUSLINE")" 1
for statusline_journal_reader in review_verdict_line unpushed_marker; do
  assert grep -Fq 'journal_dir "$top"' \
    <<<"$(sed -n "/^$statusline_journal_reader() {/,/^}/p" "$STATUSLINE")"
done
# The workdir hook is heard at BOTH events for Bash: PreToolUse writes the worktree-list snapshot
# the PostToolUse `git worktree add` diff is measured against, and registered for Task|Agent alone
# that whole path is dead code the suites still pass.
WORKDIR_HOOK_MATCHER='select([.hooks[].command] | any(test("statusline-workdir-hook"))) | select(.matcher | test("(^|\\|)Bash(\\||$)"))'
assert eq "$(jq "[.hooks.PreToolUse[] | $WORKDIR_HOOK_MATCHER] | length" "$WORKER_GATE_SETTINGS")" 1
assert eq "$(jq "[.hooks.PostToolUse[] | $WORKDIR_HOOK_MATCHER] | length" "$WORKER_GATE_SETTINGS")" 1
# One lock over one ledger, or the two languages exclude nothing: both folds take `mkdir
# <journal>.lock` beside the file, destination before source, and skip the fold on a busy lock.
assert doc_has 'mkdir "<journal>.lock"'
assert grep -Fq 'lock.mkdir()' "$RB_STORE"
assert grep -Fq 'journal.with_name(journal.name + ".lock")' "$RB_STORE"
rb_fold_journal=$(sed -n '/^def fold_journal(/,/^def _fold_journal_locked(/p' "$RB_STORE")
assert grep -Fq 'journal_lock_taken(target_lock)' <<<"$rb_fold_journal"
assert grep -Fq 'journal_lock_taken(source_lock)' <<<"$rb_fold_journal"
# Every checkout's ledger, not only the caller's: `git worktree remove` takes an unread one whole.
assert eq "$(grep -Fc 'worktrees.iterdir()' <<<"$rb_journal_dir")" 1
JOURNAL_LIB="$CLAUDE_SETUP/hooks/lib/review-journal.sh"
if test -r "$JOURNAL_LIB"; then
  rj_journal_dir=$(sed -n '/^rj_journal_dir()/,/^}/p' "$JOURNAL_LIB")
  assert grep -Fq "$JOURNAL_RESOLVE" <<<"$rj_journal_dir"
  assert grep -Fq 'mkdir "$1" 2>/dev/null' <<<"$(sed -n '/^rj_lock()/,/^}/p' "$JOURNAL_LIB")"
  rj_absorb_journal=$(sed -n '/^rj_absorb_journal()/,/^}/p' "$JOURNAL_LIB")
  assert grep -Fq 'local dst_lock=$2.lock src_lock=$1.lock' <<<"$rj_absorb_journal"
  assert grep -Fq 'rj_lock "$dst_lock" || return 1' <<<"$rj_absorb_journal"
  assert grep -Fq 'rj_lock "$src_lock" ||' <<<"$rj_absorb_journal"
  # The file names themselves, extracted from both sides and compared: two spellings of one ledger
  # is the same split by another route.
  rb_debt_name=$(sed -n 's/^DEBT_JOURNAL = "\(.*\)"$/\1/p' "$RB_STORE")
  rb_commit_name=$(sed -n 's/^COMMIT_JOURNAL = "\(.*\)"$/\1/p' "$RB_STORE")
  rj_debt_name=$(sed -n 's/^RJ_DEBT_JOURNAL=\(.*\)$/\1/p' "$JOURNAL_LIB")
  rj_commit_name=$(sed -n 's/^RJ_COMMIT_JOURNAL=\(.*\)$/\1/p' "$JOURNAL_LIB")
  assert eq "$rb_debt_name" "$rj_debt_name"
  assert eq "$rb_commit_name" "$rj_commit_name"
  assert eq "$rb_debt_name" claude-review-debt
  assert eq "$rb_commit_name" claude-commit-journal
else
  fail "journal ledger resolver across claude-setup: $JOURNAL_LIB is unreadable (set CLAUDE_SETUP_ROOT)"
fi
# The prose that sends a reader to one of them names the family's dir too: pointed at a worktree's
# own git dir, a debugging session opens a file the resolver has already folded away.
for journal_stale_doc in "$ROOT/docs/DIAGNOSTICS.md" "$REVIEW_ROOT/docs/DIAGNOSTICS.md" \
  "$REVIEW_ROOT/docs/review-contract.md" "$ROOT/docs/statusline-contract.md"; do
  assert eq "$(grep -Fc '<git-dir>/claude-' "$journal_stale_doc")" 0
done
# And nowhere else: a hook or script that spells a journal path itself is how a private ledger
# grows back beside the shared one. Tests and docs may name the files; code may not.
journal_scan_dirs=()
for journal_dir_candidate in "$ROOT/bin" "$ROOT/share" "$REVIEW_ROOT/bin" "$REVIEW_ROOT/share" \
  "$CLAUDE_SETUP/bin" "$CLAUDE_SETUP/hooks"; do
  if [ -d "$journal_dir_candidate" ]; then
    journal_scan_dirs+=("$journal_dir_candidate")
  else
    fail "journal-name scan: $journal_dir_candidate is missing (set CLAUDE_SETUP_ROOT)"
  fi
done
journal_strays=$(grep -rlE 'claude-review-debt|claude-commit-journal' \
  --exclude-dir=__pycache__ --exclude='*.pyc' "${journal_scan_dirs[@]}" 2>/dev/null |
  grep -v -x -e "$RB_STORE" -e "$JOURNAL_LIB" -e "$STATUSLINE" |
  sort | tr '\n' ' ')
assert eq "$journal_strays" ""

# --- Rows bh/bi: the Hammerspoon entry points this repository calls ------------
# Read at the INSTALL path — a symlink into this repo today, a real file once the Lua moves to the
# hammerspoon repo — so the pin survives the move and refuses to skip. `cancel` is reached through
# `and` guards at its call site, so its drift degrades silently; that is why it is pinned.
HS_ROOT="${HS_ROOT:-$HOME/.hammerspoon}"
CONTINUE_LUA="$HS_ROOT/claude_continue.lua"
SWITCH_LUA="$HS_ROOT/claude_chat_switch.lua"
test -r "$CONTINUE_LUA" || fail "row bh: $CONTINUE_LUA is unreadable (set HS_ROOT)"
test -r "$SWITCH_LUA" || fail "row bi: $SWITCH_LUA is unreadable (set HS_ROOT)"
assert doc_has '`ClaudeContinue.startTimerFor(id, minutes, customMessage, targetTty)`'
assert doc_has '`ClaudeChatSwitch.cancel()`'
timer_sig=$(sed -n 's/^function ClaudeContinue\.startTimerFor(\(.*\))$/\1/p' "$CONTINUE_LUA")
assert eq "$timer_sig" 'id, minutes, customMessage, targetTty'
timer_calls=$(grep -o 'startTimerFor([^)]*)' "$ROOT/bin/claude-resume-timer" | LC_ALL=C sort -u)
assert eq "$timer_calls" 'startTimerFor(\"$surface\", $minutes)
startTimerFor(\"$surface\", $minutes, nil, \"$target_tty\")'
assert eq "$(grep -c '^function ClaudeChatSwitch\.cancel(' "$SWITCH_LUA")" 1
assert grep -Fq 'function ClaudeChatSwitch.cancel()' "$SWITCH_LUA"
assert eq "$(grep -o '_G\.ClaudeChatSwitch\.cancel([^)]*)' "$HAMMER" | sort -u)" '_G.ClaudeChatSwitch.cancel()'


# --- Row bk: grok worker knobs ------------------------------------------------
# One default pair spelled in six places, and the one rule that is not a default: `auto` is the
# ABSENCE of a model override, so a surface that renders it as a version, or a launcher that
# substitutes one, answers for a choice nobody made.
GROK_TAG_HOOK="$ROOT/bin/worker-tag-hook.sh"
assert grep -Fq 'gr_model=$(conf grok_model); gr_model=${gr_model:-auto}' "$WORKERPICK"
assert grep -Fq 'gr_effort=$(conf grok_effort); gr_effort=${gr_effort:-high}' "$WORKERPICK"
assert grep -Fq 'model=${model:-$(config_value grok_model)}; model=${model:-auto}' "$WORKER_RUN"
assert grep -Fq 'effort=${effort:-$(config_value grok_effort)}; effort=${effort:-high}' "$WORKER_RUN"
assert grep -Fq '[ "$model" = auto ] || command_meta+=(-m "$model")' "$WORKER_RUN"
assert grep -Fq 'low|medium|high|xhigh) ;;' "$WORKER_RUN"
assert grep -Fq 'grok effort must be low, medium, high or xhigh' "$WORKER_RUN"
for grok_knob_hook in "$SPAWN_HOOK" "$GROK_TAG_HOOK"; do
  assert grep -Fq 'worker_conf grok_model' "$grok_knob_hook"
  assert grep -Fq 'worker_conf grok_effort' "$grok_knob_hook"
done
assert grep -Fq 'wv_model=${grok_model:-auto}; [ "$wv_model" != auto ] || wv_model=""' "$STATUSLINE"
assert grep -Fq 'wv_effort=${grok_effort:-high}' "$STATUSLINE"
assert grep -Fq '`grok_model=auto` and `grok_effort=low|medium|high|xhigh`' "$WORKER_COMMAND"
assert doc_has 'Grok worker knobs'
assert doc_has '`grok_model=auto`, `grok_effort=high`'

# --- Row bj: the cache-TTL track line ----------------------------------------
# The picker reads the account off a line the statusline writes positionally, so reordering that
# printf keeps every suite green while the picker silently names the wrong account, or none.
CHATS="$ROOT/bin/chats"
CHATFIND_LEGS="$ROOT/bin/chat-find"
assert doc_has 'Cache-TTL track line'
assert doc_has '`<assist_ts> <acct> <learned_upto> <ttl> <model> <uuid> <scan_bytes> <account_seen_upto> <account_seen>`'
assert grep -Fq "printf 'v2 %s %s %s %s %s %s %s %s %s\\n'" "$STATUSLINE"
assert grep -Fq 'statusline_cache_dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}"' "$STATUSLINE"
assert grep -Fq 'os.environ.get("STATUSLINE_CACHE_DIR") or os.path.expanduser("~/.cache/claude-statusline")' "$CHATS"
assert grep -Fq 'track="$statusline_cache_dir/cache-ttl-track-$session_id"' "$STATUSLINE"
assert grep -Fq '"cache-ttl-track-" + row["session"]' "$CHATS"
# The two field positions the reader counts on, named once, and the `?` that is no account. That
# the positions are the writer's own is pinned printf-to-reader by tests/test_chats.sh.
assert grep -Fq 'TRACK_TS, TRACK_ACCOUNT = 1, 2' "$CHATS"
assert grep -Fq 'if len(fields) <= TRACK_ACCOUNT or fields[0] != "v2" or fields[TRACK_ACCOUNT] == "?":' "$CHATS"
assert grep -Fq 'return fields[TRACK_ACCOUNT]' "$CHATS"
assert doc_has 'field 2 is the account the STAMPED reply went through'
# The listing and the statusline stamp different replies, so the reader compares stamps rather
# than demanding the same uuid — a chat that ended on a tool call has no matching one.
assert grep -Fq 'if seen + 1 < spoke:' "$CHATS"
assert grep -Fq 'row["until"] = max(spoke, seen) + ttl' "$CHATS"
# One spelling of the bucket key per language, and a new bucket must need neither edited.
assert doc_has '`ephemeral_<n><m\|h>_`'
assert eq "$(grep -c 'capture("ephemeral_(?<n>\[0-9\]+)(?<u>\[mh\])_")' "$STATUSLINE")" 2
assert grep -Fq 're.match(r"ephemeral_(\d+)([mh])_", key)' "$CHATFIND_LEGS"

# --- Row bl: the daily budget formula ----------------------------------------
# The metric that ranks accounts and vendors is defined once. A consumer that re-derives either
# number ranks on a second formula nothing else shares.
for view_def in limits_days_remaining limits_daily_budget limits_budget_days; do
  assert eq "$(grep -c "^def $view_def" "$LIMITSVIEW")" 1
done
# The budget divides by the clamped window through that third def rather than inline, because the
# router PRINTS the divisor beside the rate: spelled twice, the row would state a window the
# number it stands next to was never paced over.
assert grep -Fq 'limits_daily_budget($eff_pct; $days):' "$LIMITSVIEW"
assert grep -Fq '(100 - $p) / limits_budget_days($days)' "$LIMITSVIEW"
assert grep -Fq 'limits_budget_days(if (.wk | type) == "number" then limits_days_remaining(.wk_reset; $now)' "$WORKERPICK"
assert grep -Fq '.budget_days = spend_days' "$WORKERPICK"
assert grep -Fq 'else ((.budget | one_dp) | lpad(4)) + "%/d ×" + (.budget_days | one_dp) + "d" end' "$WORKERPICK"
assert doc_has '`<n>%/d ×<d>d`'
# The day floor, and the neutral window a reset this file refuses to print falls back to instead.
assert grep -Fq 'if ($days | type) != "number" then 7 elif $days < 0.25 then 0.25 else $days end' "$LIMITSVIEW"
assert doc_has 'floored at `0.25`'
assert doc_has 'neutral `7`-day window'
# Both defs are called where the ranking happens, never reimplemented beside it.
for budget_consumer in "$WORKERPICK" "$CODEXB" "$LLMLIMITS"; do
  assert grep -Fq 'share/limits-view.sh' "$budget_consumer"
  assert grep -Fq 'limits_daily_budget(' "$budget_consumer"
  assert grep -Fq 'limits_days_remaining(' "$budget_consumer"
done
assert grep -Fq 'limits_daily_budget(effective_pct; limits_days_remaining(resets_at; now))' "$CONTRACT"
assert test -r "$ROOT/tests/test_limits_view_budget.sh"
assert doc_has 'Daily budget formula'

# --- Row bm: the worker claims ledger ----------------------------------------
# One home for the TTL: the picker and every claiming caller source the module rather than
# spelling a window of their own, and the contract quotes the same default.
CLAIMS="$ROOT/share/worker-claims.sh"
claims_ttl=$(grep -oE '\$\{WORKER_CLAIMS_TTL:-[0-9]+\}' "$CLAIMS" | grep -oE '[0-9]+' | sort -u)
assert eq "$claims_ttl" 600
assert grep -Fq '`WORKER_CLAIMS_TTL`' "$CONTRACT"
assert grep -Fq 'seconds (default `600`)' "$CONTRACT"
assert eq "$(grep -c 'WORKER_CLAIMS_TTL' "$WORKERPICK")" 0
assert grep -Fq 'worker-claims.sh' "$WORKERPICK"
assert grep -Fq 'worker_claims_record "$query_vendor" "$query_answer"' "$WORKERPICK"
assert grep -Fq 'worker_claims_fresh' "$WORKERPICK"
# Launchers with a ready-to-run profile claim through the picker's flag. Image launchers pick
# without --claim, validate the profile, then call the same recorder so a ghost account does not burn the TTL.
assert grep -Fq -- '--claim' "$ROOT/bin/worker-run"
assert eq "$(grep -c 'worker-claims.sh' "$ROOT/bin/worker-run")" 0
assert grep -Fq 'command -v worker-pick' "$ROOT/bin/gemini-research"
assert grep -Fq -- 'args=(--account gemini --role research)' "$ROOT/bin/gemini-research"
assert grep -Fq -- 'args+=(--claim)' "$ROOT/bin/gemini-research"
assert grep -Fq 'worker-claims.sh' "$ROOT/bin/grok-image"
assert grep -Fq 'worker_claims_record grok "$account"' "$ROOT/bin/grok-image"
assert grep -Fq 'account=$("$worker_pick_cmd" --account grok 2>/dev/null)' "$ROOT/bin/grok-image"
assert grep -Fq 'worker-claims.sh' "$ROOT/bin/codex-image"
assert grep -Fq 'worker_claims_record codex "$account"' "$ROOT/bin/codex-image"
assert grep -Fq 'account=$(worker-pick --account codex 2>/dev/null)' "$ROOT/bin/codex-image"
assert grep -Fq 'worker-claims.sh' "$ROOT/bin/gemini-image"
assert grep -Fq 'worker_claims_record gemini "$account"' "$ROOT/bin/gemini-image"
assert grep -Fq 'account=$(worker-pick --account gemini 2>/dev/null)' "$ROOT/bin/gemini-image"
assert test -r "$ROOT/tests/test_worker_claims.sh"
assert doc_has 'Worker claims ledger'

# --- Row bo: the reset consumable ---------------------------------------------
# The glyph is the whole vocabulary for this state, so a render that gates it on a vendor name
# tells the owner one leg has no reset when the leg simply is not codex; and the write RPC that
# spends it may have exactly one caller.
RESETS="$ROOT/share/grok_resets.py"
GROKQUOTA="$ROOT/grok-quota.py"
CODEXQUOTA="$ROOT/codex-quota.py"
REDEEM="$ROOT/bin/llm-reset-redeem"
assert doc_has 'Reset consumable'
assert doc_has '`prod_mc_billing.ConsumerUiSvc`'
for credits_site in "$LLMLIMITS" "$HAMMER"; do
  assert grep -Fq '↻' "$credits_site"
  assert eq "$(grep -c '"codex" and (.reset_credits' "$credits_site")" 0
done
# The router prints no count at all: the reset is spent from the menu, and a number beside a row
# nobody ranks on reads as one that ranked it.
assert eq "$(grep -c '↻' "$WORKERPICK")" 0
assert eq "$(grep -c 'if (.reset_credits | type) == "number" then "↻"' "$LLMLIMITS")" 3
assert eq "$(grep -c '\$key == "codex" then credits' "$LLMLIMITS")" 0
for credits_field in "$GROKQUOTA" "$CODEXQUOTA"; do
  assert grep -Fq 'reset_credits' "$credits_field"
  assert grep -Fq 'reset_credits_expires_at' "$credits_field"
done
# One spelling of each vendor's transport, and one caller for each of the two writes.
APPSERVER="$ROOT/share/codex_appserver.py"
assert grep -Fq 'SERVICE_PATH = "/prod_mc_billing.ConsumerUiSvc"' "$RESETS"
assert eq "$(grep -c 'prod_mc_billing.ConsumerUiSvc' "$REDEEM")" 0
assert eq "$(grep -c 'prod_mc_billing.ConsumerUiSvc' "$GROKQUOTA")" 0
assert grep -Fq '_call("GetRemainingResets"' "$RESETS"
assert grep -Fq '_call("RedeemReset"' "$RESETS"
assert eq "$(grep -rl 'grok_resets.redeem_reset' "$ROOT/bin" "$ROOT/share" "$GROKQUOTA" | wc -l | tr -d ' ')" 1
assert grep -Fq 'grok_resets.redeem_reset' "$REDEEM"
assert grep -Fq 'import grok_resets' "$GROKQUOTA"
assert grep -Fq '"app-server"' "$APPSERVER"
assert eq "$(grep -c '"app-server"' "$CODEXQUOTA")" 0
assert eq "$(grep -c '"app-server"' "$REDEEM")" 0
for appserver_caller in "$CODEXQUOTA" "$REDEEM"; do
  assert grep -Fq 'import codex_appserver' "$appserver_caller"
done
assert eq "$(grep -rl 'rateLimitResetCredit/consume' "$ROOT/bin" "$ROOT/share" "$CODEXQUOTA" | wc -l | tr -d ' ')" 1
assert grep -Fq 'rateLimitResetCredit/consume' "$REDEEM"
# One wording for the action, shared by the renderer and the contract that pins it.
assert grep -Fq 'local title = "Redeem usage reset"' "$HAMMER"
assert grep -Fq 'title .. " · " .. formatResetTime(block.reset_credits_expires_at)' "$HAMMER"
assert grep -Fq 'Redeem usage reset · ' "$ROOT/tests/llm_limits_renderer_harness.lua"
assert doc_has 'Redeem usage reset · <when>'
# The menu is the only surface that may fire the write, and only for a vendor with a backend.
assert grep -Fq 'local RESET_REDEEM_VENDORS = { grok = true, codex = true }' "$HAMMER"
assert grep -Fq 'M.resetRedeemCmd or "llm-reset-redeem"' "$HAMMER"
assert grep -Fq 'hs.dialog.blockAlert' "$HAMMER"
assert test -r "$ROOT/tests/test_llm_reset_redeem.sh"
assert grep -Fq 'test_llm_reset_redeem.sh' "$ROOT/bin/llm-selfcheck"

# --- Row bn: the main-account shield ------------------------------------------
# The budget a base account is pulled from the pool at, spelled once in the pool module and
# quoted by the contract; the collector reconciles against that same constant.
POOL="$ROOT/share/worker-pool.sh"
shield_floor=$(sed -nE 's/^WORKER_POOL_SHIELD_PER_DAY=\$\{WORKER_POOL_SHIELD_PER_DAY:-([0-9]+)\}$/\1/p' "$POOL")
assert eq "$shield_floor" 3
assert grep -Fq '`WORKER_POOL_SHIELD_PER_DAY` (3 %/day)' "$CONTRACT"
assert eq "$(grep -c 'WORKER_POOL_SHIELD_PER_DAY' "$LLMLIMITS")" 1
assert grep -Fq -- '--argjson floor "$WORKER_POOL_SHIELD_PER_DAY"' "$LLMLIMITS"
# The two markers, and the reset epoch that is their whole state.
assert grep -Fq 'case "$kind" in shielded|shield-override) ;; *) return 1 ;; esac' "$POOL"
assert grep -Fq 'worker_pool_shield_set "$pool_vendor" "$name" "$reset"' "$LLMLIMITS"
assert grep -Fq 'worker_pool_override_current "$pool_vendor" "$name" "$reset"' "$LLMLIMITS"
# Enabling a shielded account by hand is the only override, and it lives with the vendor CLIs.
for shield_cli in "$CLAUDEB" "$CODEXB"; do
  assert grep -Fq 'worker_pool_shield_override' "$shield_cli"
done
assert test -r "$ROOT/tests/test_worker_pool_shield.sh"
assert doc_has 'Main-account shield'

# --- Row br: instruction-file classes and the one span ------------------------
# Two hooks answer for the same files, so the class table and the span are each spelled once and
# asked for by both. A second copy is a door answering differently from the one beside it.
INSTR_MOD="$ROOT/share/instruction-files.sh"
INSTR_GATE="$ROOT/bin/instruction-write-gate.sh"
INSTR_WATCH="$ROOT/bin/instruction-watch.sh"

assert eq "$(grep -c '^instruction_write_class()' "$INSTR_MOD")" 1
assert eq "$(grep -c '^_instruction_class_dirs()' "$INSTR_MOD")" 1
# The four answers, verbatim: three classes and the deliberate silence about settings.json.
class_arms=$(sed -n '/^instruction_write_class()/,/^}/p' "$INSTR_MOD")
for arm in 'CLAUDE.md|CLAUDE.local.md) printf always' 'review-debt-ignore) printf debt' \
           'settings.json) ;;' 'instruction_is_md "${1##*/}"'; do
  assert grep -Fq -- "$arm" <<<"$class_arms"
done
# The markdown extensions are one list, asked by the class table and by the enumerator alike: a
# second spelling is a file one door speaks for that the other never watches.
assert eq "$(grep -c "^INSTRUCTION_MD_EXTENSIONS='md markdown'\$" "$INSTR_MOD")" 1
assert grep -Fq 'for e in $INSTRUCTION_MD_EXTENSIONS' \
  <<<"$(sed -n '/^_instruction_class_files()/,/^}/p' "$INSTR_MOD")"
assert eq "$(grep -cF "name '*.md'" "$INSTR_MOD")" 0
# Every class directory, `commands` included — the one that used to be priced by the bloat gate
# and ungated by the write gate.
class_dirs=$(sed -n '/^_instruction_class_dirs()/,/^}/p' "$INSTR_MOD")
for class_dir in docs agents instructions skills skills-on-demand rules commands; do
  assert grep -Fq -- "/.claude/$class_dir\"" <<<"$class_dirs"
done

# One parse of where a command leaves its bytes, called by both doors and spelled in neither: the
# gate reading a destination strictly while the tripwire re-derived it from a looser expression of
# its own is what made a `.bak` sibling a write to one half and not the other.
assert eq "$(grep -c '^instruction_write_targets()' "$INSTR_MOD")" 1
# The same parse answers two doors outside this pair, and each reaches it rather than growing a
# matcher of its own: a private copy is what put a heredoc brief and a `--help` in front of a gate
# that refused them (2026-09-03).
PIN_GATE_BR="$ROOT/bin/worker-pin-gate.sh"
assert grep -Fq 'load_share instruction-files.sh instruction_write_targets' "$PIN_GATE_BR"
assert grep -Fq 'instruction_shell_scan' "$PIN_GATE_BR"
assert eq "$(grep -cE '>\[>\|\]|g\?tee|\(cp\|mv\|ln\|install\)|--in-place' "$PIN_GATE_BR")" 0
if [ -r "$FLOW_GATE" ]; then
  assert grep -Fq 'share/instruction-files.sh' "$FLOW_GATE"
  assert grep -Fq 'REVIEW_FLOW_SHELL_PARSE' "$FLOW_GATE"
  assert grep -Fq 'instruction_shell_scan' "$FLOW_GATE"
  # A sibling it cannot read is named in the refusal, never skipped in silence.
  assert grep -Fq 'rf_parse_note' "$FLOW_GATE"
else
  fail "shared command parse across claude-setup: $FLOW_GATE is unreadable (set CLAUDE_SETUP_ROOT)"
fi
for instr_hook in "$INSTR_GATE" "$INSTR_WATCH"; do
  assert grep -Fq 'share/instruction-files.sh' "$instr_hook"
  assert grep -Fq 'instruction_write_class "' "$instr_hook"
  assert grep -Fq 'instruction_write_targets "' "$instr_hook"
  # No redirection, copy-verb or destination-verb matcher of its own.
  assert eq "$(grep -cE '>\[>\|\]|g\?tee|\(cp\|mv\|ln\|install\)|--in-place' "$instr_hook")" 0
  # Nor an interpreter write shape of its own. The parse can only report that an interpreter NAMED
  # a guarded path, so what makes that a write is asked of the module by both doors: a second
  # spelling is a one-liner one of them denies and the other never puts back.
  assert eq "$(grep -cE 'write_text|writeFileSync|python\[0-9' "$instr_hook")" 0
  assert grep -Fq 'instruction_interp_write_re "' "$instr_hook"
  # No class list of its own: neither a class directory literal nor the guarded basename set.
  assert eq "$(grep -cE 'skills-on-demand|\.claude/(instructions|rules)([/ ]|$)' "$instr_hook")" 0
  assert eq "$(grep -c 'CLAUDE\.local\.md' "$instr_hook")" 0
  # The span is asked for through the module and never re-decided here.
  assert grep -Fq 'instruction_autonomous "$sid" "$transcript"' "$instr_hook"
  assert eq "$(grep -cE 'rj_autonomous|RJ_AUTONOMY_PHRASE' "$instr_hook")" 0
done

# One definition of the span, in the journal library, reached from exactly one place in this
# repository — the call and the comment naming it. Nothing here re-spells his phrase.
assert grep -Fq 'rj_autonomous() {' "$RJOURNAL"
assert grep -q '^RJ_AUTONOMY_PHRASE=' "$RJOURNAL"
assert grep -Fq 'rj_autonomous "$sid" "$transcript"' "$INSTR_MOD"
assert eq "$(grep -c 'rj_autonomous' "$INSTR_MOD")" 2
assert eq "$(grep -rlE 'RJ_AUTONOMY_PHRASE' "$ROOT/bin" "$ROOT/share" | wc -l | tr -d '[:space:]')" 0

# Both halves of the door are registered, and the tripwire on both of its events: a class the
# gate denies while the tripwire does not watch it is the one hole neither half can report.
assert eq "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
                  | select(.command | test("instruction-write-gate\\.sh"))] | length' \
                 "$WORKER_GATE_SETTINGS")" 1
assert eq "$(jq '[.hooks.PostToolUse[] | .hooks[]
                  | select(.command | test("instruction-watch\\.sh check"))] | length' \
                 "$WORKER_GATE_SETTINGS")" 1
assert eq "$(jq '[.hooks.SessionStart[] | .hooks[]
                  | select(.command | test("instruction-watch\\.sh baseline"))] | length' \
                 "$WORKER_GATE_SETTINGS")" 1
# settings.json is the tripwire's alone: watched by name, and gone from the gate's fast path.
assert grep -Fq '[ -f "$home/.claude/settings.json" ] && _instruction_emit' "$INSTR_MOD"
assert eq "$(grep -c '\*settings\.json\*' "$INSTR_GATE")" 0
assert test -r "$ROOT/tests/test_instruction_gate.sh"
assert doc_has 'Instruction-file classes and the one span'

printf 'PASS: %s asserts; shared invariants agree across sites (staleness thresholds, keychain formula, worker-pick cache format, weather HTTP classes, OAuth 429 cooldown, the permanently off robot curl refresh, the one rank vector every vendor orders its accounts by, Antigravity review cell models, Gemini worker knobs, the Grok worker knobs whose `auto` is the absence of a model override, worker account resolution, quota-group matching, shared profile mapping, weekly bucket provenance, Claude rotation usability presence, reserved profile names, worker spawn pressure gate, worker-pool membership, user-entry refresh classification, late review thresholds, account data age, claude account existence, one limits view, the Hammerspoon launchd agent identity, the account pin no session may move without Egor naming it, the debt word the bench prints, the gate translates and the statusline deduplicates only a same-repository live `rev` label, the journal that records whose debt a commit landed, the one reader both hooks name a commit target with and the journal homes they fall back on when nothing resolves it, the usage wall record both of its writers share, the per-vendor role switches the routers, the menu and the bench all read, the per-vendor pause whose parked vendor is absent from the store rather than walled anywhere, the auto-refresh roster whose one inverted vendor is polled only where polling is free, the OpenCode rows whose standing wall the collector and the bench pool read off one served stamp, the run record that carries a worker'"'"'s files into the journal of the chat that launched it, the launching-chat pid walk the progress writer runs once and the statusline only falls back to, the doctor snapshot whose five class names are the menubar'"'"'s whole vocabulary, the one resolver every surface names a chat through, the launchers a headless vendor run may reach the machine through, the one journal ledger per git family both languages resolve with the same command and fold under one lock, the one file that says gemini main is removed, the one daily-budget formula every ranking site calls, the claims ledger a caller about to spend an answer takes its account out of, the shield that keeps a base account out of the pool, the reset consumable whose glyph names no vendor and whose spending RPC has exactly one caller, the instruction-file class table both hooks ask rather than copy and the single definition of Egor'"'"'s autonomy span they reach it through, the native agent types a Fable session may still spawn and the two of them a lookup is dropped to sonnet for, the inactivity watchdog that ends a worker run before its six-hour ceiling ever does, the launched brief that carries the test-loop preamble while the recorded one stays the caller'"'"'s input, the persistent grok wall wording both repositories retire a SuperGrok plan on, the Codex out-of-credits wording the relay and the bench share, and the Hammerspoon entry points this repository calls, pinned fail-closed at their install path) and match %s\n' "$asserts" "$DOC"
