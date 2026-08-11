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
for vendor in claudeb codex gemini; do
  for role in workers reviewers; do
    assert worker_model_set_role "$vendor" "$role" off
  done
done
assert_file $'claudeb_workers=off\nclaudeb_reviewers=off\ncodex_workers=off\ncodex_reviewers=off\ngemini_workers=off\ngemini_reviewers=off'

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

# --- The four implementations of the role keys agree ---------------------------------------------
# `<vendor>_<role>=off`, absent key = on, is spoken by four independent readers/writers. The vendor
# and role tokens are spelled once here and every implementation is asked whether it means the
# same thing; a drifted one leaves the menu showing a switch the routers do not read.
VENDORS="claudeb codex gemini"
ROLES="workers reviewers"
PICK="$ROOT/bin/worker-pick"
RUN="$ROOT/bin/worker-run"
HAMMER="$ROOT/hammerspoon/llm-limits.lua"
BENCH="$ROOT/bin/review-bench"

# The writer, asked for every pair the readers know.
for vendor in $VENDORS; do
  for role in $ROLES; do
    rm -f "$MODEL"
    worker_model_set_role "$vendor" "$role" off ||
      fail "share/worker-model.sh refuses ${vendor} ${role}, a pair bin/worker-pick and hammerspoon/llm-limits.lua read"
    assert_file "${vendor}_${role}=off"
  done
done

# The reader in bin/worker-pick, asked through the binary: an empty limits file is enough, because
# a closed role is refused before any account is looked at.
printf '{}\n' >"$WORK/limits.json"
pick() {
  env LLM_LIMITS_FILE="$WORK/limits.json" WORKER_PICK_CONFIG_FILE="$MODEL" \
    WORKER_PICK_TIERS_FILE="$WORK/tiers" WORKER_PICK_CACHE_DIR="$WORK/cache" \
    WORKER_PICK_NOW=1000000 CLAUDEB_DIR="$WORK/claudeb" \
    "$PICK" --account "$1" --role "$2" 2>&1 >/dev/null
}
for vendor in $VENDORS; do
  for role in $ROLES; do
    printf '%s_%s=off\n' "$vendor" "$role" >"$MODEL"
    pick_out=$(pick "$vendor" "$role") &&
      fail "bin/worker-pick answered $vendor for $role while share/worker-model.sh had written ${vendor}_${role}=off: reader and writer disagree on the key"
    grep -Fq "$vendor is switched off for $role" <<<"$pick_out" ||
      fail "bin/worker-pick's refusal for ${vendor}_${role} names neither the vendor nor the role share/worker-model.sh wrote: $pick_out"
    # Only the literal "off" is a veto, which is what hammerspoon/llm-limits.lua and
    # bin/review-bench read; anything else is the open state the absent key means.
    printf '%s_%s=on\n' "$vendor" "$role" >"$MODEL"
    grep -Fq 'is switched off' <<<"$(pick "$vendor" "$role")" &&
      fail "bin/worker-pick vetoes ${vendor}_${role}=on, while share/worker-model.sh and hammerspoon/llm-limits.lua treat only \"off\" as closed"
  done
done
# The two role tokens are two switches, not one.
printf 'claudeb_workers=off\n' >"$MODEL"
grep -Fq 'switched off' <<<"$(pick claudeb reviewers)" &&
  fail "bin/worker-pick refused a reviewers query on a claudeb_workers=off line: its role_off() drops the role token hammerspoon/llm-limits.lua and bin/review-bench key on"

# The stderr contract: bin/worker-run reroutes on a line bin/worker-pick prints, so the consumer's
# own grep pattern is run against the producer's live output.
run_grep=$(sed -n "s/.*grep -q '\([^']*switched off[^']*\)'.*/\1/p" "$RUN" | head -n1)
[ -n "$run_grep" ] ||
  fail "bin/worker-run no longer greps a 'switched off' line out of bin/worker-pick's stderr: the workers wall it reroutes on became unreadable"
printf 'claudeb_workers=off\n' >"$MODEL"
pick_out=$(pick claudeb workers)
grep -q -- "$run_grep" <<<"$pick_out" ||
  fail "bin/worker-run greps '$run_grep' but bin/worker-pick prints '$pick_out': the workers-wall stderr contract between them drifted"

# The reader in hammerspoon/llm-limits.lua, at the two tables the menu builds keys from.
lua_prefixes=$(grep -E '^local WORKER_MODEL_PREFIX = ' "$HAMMER" | head -n1)
[ -n "$lua_prefixes" ] ||
  fail "hammerspoon/llm-limits.lua has no WORKER_MODEL_PREFIX table, so the keys share/worker-model.sh writes are built somewhere else now"
for vendor in $VENDORS; do
  grep -Fq "\"$vendor\"" <<<"$lua_prefixes" ||
    fail "hammerspoon/llm-limits.lua's WORKER_MODEL_PREFIX lacks the $vendor prefix that share/worker-model.sh writes ${vendor}_ keys with"
done
lua_roles=$(grep -E '^local WORKER_ROLES = ' "$HAMMER" | head -n1)
[ -n "$lua_roles" ] ||
  fail "hammerspoon/llm-limits.lua has no WORKER_ROLES table, so the menu no longer enumerates the roles share/worker-model.sh accepts"
for role in $ROLES; do
  grep -Fq "\"$role\"" <<<"$lua_roles" ||
    fail "hammerspoon/llm-limits.lua's WORKER_ROLES lacks the $role token that share/worker-model.sh writes and bin/worker-pick reads"
done
assert_hammer() {
  asserts=$((asserts + 1))
  grep -Fq "$1" "$HAMMER" || fail "hammerspoon/llm-limits.lua no longer $2, so its menu and share/worker-model.sh's keys drifted"
}
assert_hammer 'key == prefix .. "_" .. role' 'builds keys as <vendor>_<role>'
assert_hammer 'value ~= "off"' 'reads "off" as the only veto'

# The reader in bin/review-bench, asked through its own functions: it reads the reviewers half.
bench_out=$(python3 - "$BENCH" "$MODEL" "$VENDORS" 2>&1 <<'PY'
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
) || fail "$bench_out"
asserts=$((asserts + 1))

printf 'PASS: %s asserts; worker_model_set_role writes the per-role vetoes under the pin'\''s own lock — "off" to close a role, the line deleted to open it, unrelated lines and their order preserved, a missing file created, an unknown vendor/role/state refused, a Claude session refused outright, and a lock it cannot take answered by writing nothing; and the vendor/role/off literals mean the same thing in share/worker-model.sh, bin/worker-pick, hammerspoon/llm-limits.lua and bin/review-bench, with bin/worker-run'\''s own grep run against worker-pick'\''s live stderr\n' "$asserts"
