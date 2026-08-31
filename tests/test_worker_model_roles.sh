#!/usr/bin/env bash
# worker_model_set_role — the one writer of the per-role vetoes in ~/.claude/worker-model, shelled
# out to by the menubar so the write happens under the same lock as the pin. Every file here is a
# fixture named through WORKER_PICK_CONFIG_FILE; the real worker-model is never opened.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }
assert_file() {
  asserts=$((asserts + 1))
  local expected="$1" actual
  actual=$(cat "$MODEL" 2>&1) || fail "assert $asserts: $MODEL unreadable"
  [ "$actual" = "$expected" ] || fail "assert $asserts: expected
$expected
got
$actual"
}

. "$ROOT/share/worker-model.sh"

# The suite plays Egor's own shell; the session gate has its own cases below.
unset CLAUDECODE

MODEL="$WORK/worker-model"
export WORKER_PICK_CONFIG_FILE="$MODEL"

# --- Disabling writes the veto, enabling deletes the line ---------------------------------------
# An absent key is what worker-pick and review-bench read as "open", so "on" must not be written.
BASE=$'worker=auto\nclaudeb_profile=alpha\neffort=high'
printf '%s\n' "$BASE" >"$MODEL"
assert worker_model_set_role claudeb workers off
assert_file "$BASE"$'\nclaudeb_workers=off'
assert worker_model_set_role claudeb workers off
assert_file "$BASE"$'\nclaudeb_workers=off'
assert worker_model_set_role gemini reviewers off
assert_file "$BASE"$'\nclaudeb_workers=off\ngemini_reviewers=off'
assert worker_model_set_role claudeb workers on
assert_file "$BASE"$'\ngemini_reviewers=off'
assert worker_model_set_role gemini reviewers on
assert_file "$BASE"
# Enabling a role nobody vetoed changes nothing and is not an error.
assert worker_model_set_role codex reviewers on
assert_file "$BASE"

# A hand-edited file with the key twice collapses to one line, and the rest keeps its order.
printf 'claudeb_workers=off\nworker=auto\nclaudeb_workers=off\n' >"$MODEL"
assert worker_model_set_role claudeb workers off
assert_file $'worker=auto\nclaudeb_workers=off'

# --- A missing file is created, not a failure to report -----------------------------------------
rm -f "$MODEL"
assert worker_model_set_role codex workers off
assert_file 'codex_workers=off'

# --- Every vendor × role pair the routers know ---------------------------------------------------
rm -f "$MODEL"
for vendor in claudeb codex gemini grok; do
  for role in workers reviewers; do
    assert worker_model_set_role "$vendor" "$role" off
  done
done
assert_file $'claudeb_workers=off\nclaudeb_reviewers=off\ncodex_workers=off\ncodex_reviewers=off\ngemini_workers=off\ngemini_reviewers=off\ngrok_workers=off\ngrok_reviewers=off'

# --- An unknown vendor, role or state never touches the file ------------------------------------
before=$(cat "$MODEL")
quiet_set_role() { worker_model_set_role "$@" 2>/dev/null; }
for bad in "claude workers off" "claudeb raters off" "claudeb workers yes" \
           "claudeb workers" "  " ; do
  # shellcheck disable=SC2086
  assert_fails quiet_set_role $bad
done
assert [ "$before" = "$(cat "$MODEL")" ]

# --- The lock is taken, and it is the same lock the pin writer takes ----------------------------
# A menu toggle racing worker-pick's pin clear must not resurrect the pin line, which is what an
# unlocked read-modify-write from Hammerspoon used to do.
rm -f "$MODEL" "$MODEL.lock"
LOCK_LOG="$WORK/lockf.log"
cat >"$WORK/fake-lockf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOCK_LOG"
exit 0
SH
chmod +x "$WORK/fake-lockf"
LOCK_LOG="$LOCK_LOG" WORKER_MODEL_LOCKF="$WORK/fake-lockf" \
  worker_model_set_role claudeb workers off || fail "the locked write failed"
assert [ "$(cat "$LOCK_LOG")" = "-s 9" ]
assert [ -f "$MODEL.lock" ]
# A lock nobody can take is a refusal, not a silent write.
cat >"$WORK/deny-lockf" <<'SH'
#!/usr/bin/env bash
exit 75
SH
chmod +x "$WORK/deny-lockf"
printf 'worker=auto\n' >"$MODEL"
assert_fails env WORKER_MODEL_LOCKF="$WORK/deny-lockf" \
  bash -c '. "$0"; worker_model_set_role claudeb workers off 2>/dev/null' \
  "$ROOT/share/worker-model.sh"
assert_file 'worker=auto'

# --- No temp files left behind ------------------------------------------------------------------
assert worker_model_set_role gemini workers off
assert [ -z "$(find "$WORK" -name 'worker-model.tmp.*' -print -quit)" ]

# --- The menubar's own call, run verbatim --------------------------------------------------------
# The script string and the variable names come out of hammerspoon/llm-limits.lua: a helper that
# only works when a test spells the call itself is a helper the menu cannot use.
SCRIPT=$(awk "/^local WORKER_ROLE_SCRIPT =/ { getline; sub(/^ *'/, \"\"); sub(/'\$/, \"\"); print; exit }" \
  "$ROOT/hammerspoon/llm-limits.lua")
[ -n "$SCRIPT" ] || fail "could not read the menubar's role-write script out of llm-limits.lua"
rm -f "$MODEL"
assert env WORKER_MODEL_SH="$ROOT/share/worker-model.sh" WORKER_PICK_CONFIG_FILE="$MODEL" \
  WM_VENDOR=gemini WM_ROLE=reviewers WM_STATE=off bash -c "$SCRIPT"
assert_file 'gemini_reviewers=off'
assert env WORKER_MODEL_SH="$ROOT/share/worker-model.sh" WORKER_PICK_CONFIG_FILE="$MODEL" \
  WM_VENDOR=gemini WM_ROLE=reviewers WM_STATE=on bash -c "$SCRIPT"
assert [ ! -s "$MODEL" ]

# --- A session may not flip a role --------------------------------------------------------------
# Closing a vendor for a role redirects every worker and rater after it; Hammerspoon carries no
# CLAUDECODE, so the menubar is unaffected while a session in this checkout is refused.
printf 'worker=auto\n' >"$MODEL"
gate_out=$(CLAUDECODE=1 bash -c '. "$0"; worker_model_set_role claudeb workers off' \
  "$ROOT/share/worker-model.sh" 2>&1) && fail "a session closed a role for a vendor"
grep -Fq 'role switches are Egor' <<<"$gate_out" \
  || fail "the session refusal did not name whose the switches are: $gate_out"
grep -Fq 'menubar' <<<"$gate_out" || fail "the session refusal did not point at the menubar: $gate_out"
assert_file 'worker=auto'
# Reopening is gated in the same direction: a role Egor closed is not a session's to reopen.
printf 'worker=auto\nclaudeb_workers=off\n' >"$MODEL"
assert_fails env CLAUDECODE=1 bash -c '. "$0"; worker_model_set_role claudeb workers on 2>/dev/null' \
  "$ROOT/share/worker-model.sh"
assert_file $'worker=auto\nclaudeb_workers=off'
# The gate is the session, not the file: a fixture path does not open it either.
assert_fails env CLAUDECODE=1 WORKER_PICK_CONFIG_FILE="$WORK/other-model" \
  bash -c '. "$0"; worker_model_set_role codex workers off 2>/dev/null' \
  "$ROOT/share/worker-model.sh"
assert [ ! -e "$WORK/other-model" ]

# --- The real file is never a target -------------------------------------------------------------
# The helper writes exactly what WORKER_PICK_CONFIG_FILE names, so a suite pointing it at a fixture
# cannot reach ~/.claude/worker-model by accident.
assert [ "$(worker_model_file)" = "$MODEL" ]

printf 'PASS: %s asserts; worker_model_set_role writes the per-role vetoes under the pin'\''s own lock — "off" to close a role, the line deleted to open it, unrelated lines and their order preserved, a missing file created, an unknown vendor/role/state refused, a Claude session refused outright, and a lock it cannot take answered by writing nothing (the vendor/role/off literals every reader shares are guarded by tests/test_consistency.sh row aj)\n' "$asserts"
