#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
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
printf 'cache=%s args=%s\n' "${WORKER_PICK_CACHE_DIR:-unset}" "$*" >>"$PICK_LOG"
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
printf 'model: gpt-5.6-sol\n' >&2
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
printf 'model: gpt-5.6-sol\n' >&2
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
  env PATH="$path" LLM_LEGS_DATA_DIR="$data" \
    STUB_PICK_ACCOUNT="${STUB_PICK_ACCOUNT:-}" STUB_PICK_RC="${STUB_PICK_RC:-0}" \
    bash "$@"
}

ROUTED_PATH="$STUB_BIN:$SYSTEM_PATH"
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
    claude) assert grep -q $'^claudeb\t-p\troute claude\t' "$CALL_LOG" ;;
  esac
  assert grep -q "cache=/dev/null args=--account $leg" "$PICK_LOG"
  assert jq -e --arg account "$account" '.account == $account' \
    "$data/served-models.jsonl" >/dev/null
done

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
  if [ "$vendor" = claudeb ]; then
    assert test -z "$(grep $'^claude\t' "$CALL_LOG")"
  else
    assert test ! -s "$CALL_LOG"
  fi
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
    claude) assert grep -q $'^claudeb\t-p\tReply with exactly: ok\t' "$CALL_LOG" ;;
  esac
  assert grep -Eq 'served:|leg alive:' "$WORK/probe-$leg.out"
done

echo "PASS: $asserts asserts; all legs route selected accounts through vendor profile launchers, refuse an unselectable pool without a vendor call, degrade to bare main-account CLIs when worker-pick is absent, audit the answering account, and keep probes on the routed path"
