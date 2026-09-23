#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export GEMINIB_CACHE_DIR="$WORK/geminib-cache"
. "$ROOT/tests/fixtures/geminib-families.sh"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

STUB_BIN="$WORK/stubs"
BARE_BIN="$WORK/bare"
PICK_BARE_BIN="$WORK/picker-bare"
CALL_LOG="$WORK/calls"
PICK_LOG="$WORK/picks"
SYSTEM_PATH="$(dirname "$(command -v jq)"):/usr/bin:/bin"
export CALL_LOG PICK_LOG
mkdir -p "$STUB_BIN" "$BARE_BIN" "$PICK_BARE_BIN"

cat >"$STUB_BIN/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >>"$PICK_LOG"
case "${STUB_PICK_RC:-0}" in
  0) printf '%s\n' "${STUB_PICK_ACCOUNT:-main}" ;;
  2) exit 2 ;;
  3) exit 3 ;;
  *) exit "${STUB_PICK_RC}" ;;
esac
EOF

cat >"$STUB_BIN/codexb" <<'EOF'
#!/usr/bin/env bash
printf 'codexb' >>"$CALL_LOG"
printf '\t%s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
printf 'model: gpt-6-astra\n' >&2
printf 'codex answer\n'
EOF

cat >"$STUB_BIN/geminib" <<'EOF'
#!/usr/bin/env bash
printf 'geminib' >>"$CALL_LOG"
printf '\t%s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
case " $* " in
  *" models "*) printf 'Gemini 3.1 Pro (High)\nGemini 3.1 Pro (Low)\n' ;;
  *" --version "*) printf 'agy fixture 1.0\n' ;;
  *) printf 'gemini answer\n' ;;
esac
EOF

cat >"$STUB_BIN/claudeb" <<'EOF'
#!/usr/bin/env bash
printf 'claudeb' >>"$CALL_LOG"
printf '\t%s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
if [ "${1:-}" = profile ]; then
  printf '{"result":"claude answer","modelUsage":{"claude-opus-fixture":{"outputTokens":2}}}\n'
  exit 0
fi
rc=0
account="$(worker-pick --account claudeb)" || rc=$?
if [ "$rc" -eq 3 ]; then
  printf 'claudeb: worker-pick selected no account; use `claudeb profile <name>`\n' >&2
  exit 3
fi
if [ "$rc" -ne 0 ]; then
  printf 'claudeb: worker-pick failed (exit %s); use `claudeb profile <name>`\n' "$rc" >&2
  exit 2
fi
printf 'claudeb: worker-pick selected %s\n' "$account" >&2
printf '{"result":"claude answer","modelUsage":{"claude-opus-fixture":{"outputTokens":2}}}\n'
EOF

cat >"$BARE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex' >>"$CALL_LOG"
printf '\t%s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
printf 'model: gpt-6-astra\n' >&2
printf 'codex answer\n'
EOF

cat >"$BARE_BIN/agy" <<'EOF'
#!/usr/bin/env bash
printf 'agy' >>"$CALL_LOG"
printf '\t%s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
case " $* " in
  *" models "*) printf 'Gemini 3.1 Pro (High)\nGemini 3.1 Pro (Low)\n' ;;
  *" --version "*) printf 'agy fixture 1.0\n' ;;
  *) printf 'gemini answer\n' ;;
esac
EOF

cat >"$BARE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude' >>"$CALL_LOG"
printf '\t%s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
printf '{"result":"claude answer","modelUsage":{"claude-opus-fixture":{"outputTokens":2}}}\n'
EOF

chmod +x "$STUB_BIN"/* "$BARE_BIN"/*
ln -s "$BARE_BIN/codex" "$STUB_BIN/codex"
ln -s "$BARE_BIN/agy" "$STUB_BIN/agy"
ln -s "$BARE_BIN/claude" "$STUB_BIN/claude"
ln -s "$STUB_BIN/worker-pick" "$PICK_BARE_BIN/worker-pick"
ln -s "$BARE_BIN/codex" "$PICK_BARE_BIN/codex"
ln -s "$BARE_BIN/agy" "$PICK_BARE_BIN/agy"
ln -s "$BARE_BIN/claude" "$PICK_BARE_BIN/claude"

run_leg() {
  local path="$1" data="$2"
  shift 2
  env -u CODEXB_MODELS_CACHE -u CODEX_HOME -u CODEX_MODEL -u LEGS_ROLE \
    PATH="$path" LLM_LEGS_DATA_DIR="$data" HOME="$WORK/home" \
    CODEXB_PROFILES_DIR="$WORK/home/.codex-profiles" \
    ${LEG_ENV[@]+"${LEG_ENV[@]}"} \
    STUB_PICK_ACCOUNT="${STUB_PICK_ACCOUNT:-}" STUB_PICK_RC="${STUB_PICK_RC:-0}" \
    bash "$@"
}

ROUTED_PATH="$STUB_BIN:$SYSTEM_PATH"
LEG_ENV=()
mkdir -p "$WORK/home/.codex-profiles"
# The slug the roster names for the codex leg under this hermetic HOME; never a literal here, so a
# roster release does not edit this test.
ROSTER_CODEX="$(env HOME="$WORK/home" CODEXB_PROFILES_DIR="$WORK/home/.codex-profiles" \
  bash -c '. "$1/share/worker-model.sh" && worker_model_codex_slug "$(worker_model_default_model codex)" codex-worker' \
  _ "$ROOT" 2>/dev/null | head -1)"
assert test -n "$ROSTER_CODEX"
BARE_PATH="$BARE_BIN:$SYSTEM_PATH"
PICK_BARE_PATH="$PICK_BARE_BIN:$SYSTEM_PATH"

for spec in \
  "codex:codex-worker:$ROOT/ask_codex.sh" \
  "gemini:gemini-worker:$ROOT/ask_gemini.sh" \
  "claude:claude-worker:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg account script <<<"$spec"
  data="$WORK/data-$leg"
  : >"$CALL_LOG"
  : >"$PICK_LOG"
  STUB_PICK_ACCOUNT="$account"
  STUB_PICK_RC=0
  assert run_leg "$ROUTED_PATH" "$data" "$script" "route $leg" >/dev/null
  case "$leg" in
    codex) assert grep -q $'^codexb\tprofile\tcodex-worker\texec\t' "$CALL_LOG" ;;
    gemini) assert grep -q $'^geminib\tprofile\tgemini-worker\t--print\t' "$CALL_LOG" ;;
    claude) assert grep -q $'^claudeb\tprofile\tclaude-worker\t-p\troute claude\t' "$CALL_LOG" ;;
  esac
  assert grep -q "args=--account $leg" "$PICK_LOG"
  assert grep -q -- "--role reviewers$" "$PICK_LOG"
  assert jq -e --arg account "$account" '.account == $account' \
    "$data/served-models.jsonl" >/dev/null
  # A routed leg never reaches the bare CLI: for Gemini that CLI runs under the real HOME, the
  # base profile the router no longer has to have.
  case "$leg" in
    gemini) assert test "$(grep -c $'^agy\t' "$CALL_LOG")" -eq 0 ;;
    codex)
      assert grep -q $'\t-m\t'"$ROSTER_CODEX"$'\t' "$CALL_LOG"
      assert jq -e --arg slug "$ROSTER_CODEX" '.requested == $slug' "$data/served-models.jsonl" >/dev/null ;;
  esac
done

# LEGS_ROLE names another role for every leg.
for spec in \
  "codex:$ROOT/ask_codex.sh" \
  "gemini:$ROOT/ask_gemini.sh" \
  "claude:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg script <<<"$spec"
  : >"$PICK_LOG"
  LEG_ENV=(LEGS_ROLE=workers)
  assert run_leg "$ROUTED_PATH" "$WORK/role-$leg" "$script" "role $leg" >/dev/null 2>&1
  LEG_ENV=()
  assert grep -q -- "--role workers$" "$PICK_LOG"
done

# An explicit CODEX_MODEL wins over the roster and is what the audit row records.
: >"$CALL_LOG"
LEG_ENV=(CODEX_MODEL=gpt-explicit-fixture)
assert run_leg "$ROUTED_PATH" "$WORK/explicit-codex" "$ROOT/ask_codex.sh" "explicit codex" >/dev/null 2>&1
LEG_ENV=()
assert grep -q $'\t-m\tgpt-explicit-fixture\t' "$CALL_LOG"
assert jq -e '.requested == "gpt-explicit-fixture"' "$WORK/explicit-codex/served-models.jsonl" >/dev/null

# A family word runs that family's newest roster slug; a word the roster does not know passes through.
ROSTER_FAMILY="$(bash -c '. "$1/share/worker-model.sh" && worker_model_codex_family "$2"' _ "$ROOT" "$ROSTER_CODEX")"
for spec in "$ROSTER_FAMILY:$ROSTER_CODEX" "nofamily-fixture:nofamily-fixture"; do
  IFS=: read -r word slug <<<"$spec"
  : >"$CALL_LOG"
  LEG_ENV=(CODEX_MODEL="$word")
  assert run_leg "$ROUTED_PATH" "$WORK/family-$word" "$ROOT/ask_codex.sh" "family codex" >/dev/null 2>&1
  LEG_ENV=()
  assert grep -q $'\t-m\t'"$slug"$'\t' "$CALL_LOG"
  assert jq -e --arg slug "$slug" '.requested == $slug' "$WORK/family-$word/served-models.jsonl" >/dev/null
done

# A gemini family word with a tier becomes that row's agy label.
PRO_LABEL="$("$ROOT/bin/geminib" families 2>/dev/null | awk -F'\t' '$2 == "pro" { print $4; exit }')"
assert test -n "$PRO_LABEL"
: >"$CALL_LOG"
LEG_ENV=("AGY_MODEL=pro (Low)")
assert run_leg "$ROUTED_PATH" "$WORK/family-gemini" "$ROOT/ask_gemini.sh" "family gemini" >/dev/null 2>&1
LEG_ENV=()
assert jq -e --arg label "$PRO_LABEL (Low)" '.requested == $label' "$WORK/family-gemini/served-models.jsonl" >/dev/null

# Every audit row carries the caller's LLM_LEGS_RUN_ID; a value unsafe for the JSON row is dropped.
for spec in "codex:$ROOT/ask_codex.sh" "gemini:$ROOT/ask_gemini.sh" "claude:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg script <<<"$spec"
  LEG_ENV=(LLM_LEGS_RUN_ID=run-fixture.1)
  assert run_leg "$ROUTED_PATH" "$WORK/run-$leg" "$script" "run $leg" >/dev/null 2>&1
  LEG_ENV=('LLM_LEGS_RUN_ID=bad"id')
  assert run_leg "$ROUTED_PATH" "$WORK/run-$leg" "$script" "run $leg" >/dev/null 2>&1
  LEG_ENV=()
  assert jq -se '[.[].run] == ["run-fixture.1", ""]' "$WORK/run-$leg/served-models.jsonl" >/dev/null
done

# A roster that cannot answer (no share/ beside the script) never fails the leg: the CLI default
# runs with no -m and the audit row says `cli-default`.
mkdir -p "$WORK/lone"
cp "$ROOT/ask_codex.sh" "$WORK/lone/ask_codex.sh"
: >"$CALL_LOG"
assert run_leg "$ROUTED_PATH" "$WORK/lone-data" "$WORK/lone/ask_codex.sh" "lone codex" \
  >"$WORK/lone.out" 2>"$WORK/lone.err"
assert grep -q 'codex answer' "$WORK/lone.out"
assert grep -q 'roster named no codex model' "$WORK/lone.err"
assert test "$(grep -c $'\t-m\t' "$CALL_LOG")" -eq 0
assert jq -e '.requested == "cli-default"' "$WORK/lone-data/served-models.jsonl" >/dev/null

for spec in \
  "codex:$ROOT/ask_codex.sh" \
  "gemini:$ROOT/ask_gemini.sh" \
  "claudeb:$ROOT/ask_claude.sh"; do
  IFS=: read -r vendor script <<<"$spec"
  : >"$CALL_LOG"
  STUB_PICK_ACCOUNT=unused
  STUB_PICK_RC=3
  rc=0
  run_leg "$ROUTED_PATH" "$WORK/refuse-$vendor" "$script" "refuse $vendor" \
    >"$WORK/refuse-$vendor.out" 2>"$WORK/refuse-$vendor.err" || rc=$?
  assert test "$rc" -eq 6
  assert grep -q 'leg unavailable' "$WORK/refuse-$vendor.err"
  assert test ! -s "$CALL_LOG"
done

for spec in \
  "codex:codex:$ROOT/ask_codex.sh" \
  "gemini:agy:$ROOT/ask_gemini.sh" \
  "claude:claude:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg cli script <<<"$spec"
  data="$WORK/fallback-$leg"
  : >"$CALL_LOG"
  assert run_leg "$BARE_PATH" "$data" "$script" "fallback $leg" \
    >"$WORK/fallback-$leg.out" 2>"$WORK/fallback-$leg.err"
  assert grep -q 'worker-pick not installed; falling back' "$WORK/fallback-$leg.err"
  assert grep -q "^$cli"$'\t' "$CALL_LOG"
  assert jq -e '.account == "main"' "$data/served-models.jsonl" >/dev/null
done

for spec in \
  "codex:codex:$ROOT/ask_codex.sh" \
  "gemini:agy:$ROOT/ask_gemini.sh" \
  "claude:claude:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg cli script <<<"$spec"
  data="$WORK/unusable-$leg"
  : >"$CALL_LOG"
  STUB_PICK_ACCOUNT=unused
  STUB_PICK_RC=2
  assert run_leg "$ROUTED_PATH" "$data" "$script" "unusable $leg" \
    >"$WORK/unusable-$leg.out" 2>"$WORK/unusable-$leg.err"
  assert grep -q 'worker-pick unusable (exit 2); falling back' "$WORK/unusable-$leg.err"
  assert grep -q "^$cli"$'\t' "$CALL_LOG"
  assert jq -e '.account == "main"' "$data/served-models.jsonl" >/dev/null
done

for spec in \
  "codex:codexb:codex:$ROOT/ask_codex.sh" \
  "gemini:geminib:agy:$ROOT/ask_gemini.sh" \
  "claude:claudeb:claude:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg launcher cli script <<<"$spec"
  data="$WORK/no-launcher-$leg"
  : >"$CALL_LOG"
  STUB_PICK_ACCOUNT="$leg-worker"
  STUB_PICK_RC=0
  assert run_leg "$PICK_BARE_PATH" "$data" "$script" "no launcher $leg" \
    >"$WORK/no-launcher-$leg.out" 2>"$WORK/no-launcher-$leg.err"
  assert grep -q "$launcher not installed; falling back" "$WORK/no-launcher-$leg.err"
  assert grep -q "^$cli"$'\t' "$CALL_LOG"
  assert jq -e '.account == "main"' "$data/served-models.jsonl" >/dev/null
done

for spec in \
  "codex:codex-worker:$ROOT/ask_codex.sh" \
  "gemini:gemini-worker:$ROOT/ask_gemini.sh" \
  "claude:claude-worker:$ROOT/ask_claude.sh"; do
  IFS=: read -r leg account script <<<"$spec"
  : >"$CALL_LOG"
  STUB_PICK_ACCOUNT="$account"
  STUB_PICK_RC=0
  assert run_leg "$ROUTED_PATH" "$WORK/probe-$leg" "$script" --probe \
    >"$WORK/probe-$leg.out" 2>"$WORK/probe-$leg.err"
  case "$leg" in
    codex) assert grep -q $'^codexb\tprofile\tcodex-worker\texec\t' "$CALL_LOG" ;;
    gemini) assert grep -q $'^geminib\tprofile\tgemini-worker\tmodels$' "$CALL_LOG" ;;
    claude) assert grep -q $'^claudeb\tprofile\tclaude-worker\t-p\tReply with exactly: ok\t' "$CALL_LOG" ;;
  esac
  assert grep -Eq 'served:|leg alive:' "$WORK/probe-$leg.out"
done

# Listing model labels spends no quota, so it must answer even when nothing is selectable
# and without spending a routing query.
: >"$CALL_LOG"
: >"$PICK_LOG"
STUB_PICK_ACCOUNT=unused
STUB_PICK_RC=3
rc=0
run_leg "$ROUTED_PATH" "$WORK/list-models" "$ROOT/ask_gemini.sh" --list-models \
  >"$WORK/list-models.out" 2>"$WORK/list-models.err" || rc=$?
assert test "$rc" -eq 0
assert grep -q 'Gemini 3.1 Pro (High)' "$WORK/list-models.out"
assert test ! -s "$PICK_LOG"

echo "PASS: $asserts asserts; all legs route reviewers-role accounts (LEGS_ROLE overrides) through vendor profile launchers, codex runs the roster's newest slug (explicit CODEX_MODEL wins, a silent roster falls back to cli-default), refuse an unselectable pool without a vendor call, degrade to bare main-account CLIs when worker-pick is absent, audit the answering account, keep probes on the routed path, and answer --list-models without a selectable account"
