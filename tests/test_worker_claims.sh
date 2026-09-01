#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  if "$@"; then
    fail "assert $asserts unexpectedly succeeded: $*"
  else
    status=$?
    [ "$status" -ne 127 ] || fail "assert $asserts command not found: $*"
  fi
}

WORKER_CLAIMS_DIR="$WORK/claims"
export WORKER_CLAIMS_DIR
source "$ROOT/share/worker-claims.sh"

assert worker_claims_record codex work4
assert test "$(worker_claims_fresh codex)" = work4

assert worker_claims_record claude alpha
assert test "$(worker_claims_fresh codex)" = work4
assert test "$(worker_claims_fresh claude)" = alpha

WORKER_CLAIMS_TTL=1
export WORKER_CLAIMS_TTL
touch -t 200001010000 "$WORKER_CLAIMS_DIR/codex/work4"
assert test -z "$(worker_claims_fresh codex)"
assert test "$(worker_claims_fresh claude)" = alpha

assert worker_claims_record codex fresh
assert worker_claims_record codex stale
assert worker_claims_record gemini stale-other
touch -t 200001010000 "$WORKER_CLAIMS_DIR/codex/stale" "$WORKER_CLAIMS_DIR/gemini/stale-other"
# A stale sibling anywhere in the listing — first, last, or both — never makes a live claim
# read as absent: the status is about errors, and the names carry the answer.
assert worker_claims_fresh codex >/dev/null
assert test "$(worker_claims_fresh codex)" = fresh
assert worker_claims_fresh gemini >/dev/null
assert test -z "$(worker_claims_fresh gemini)"
outside="$WORK/outside"
touch "$outside"
touch -t 200001010000 "$outside"
mkdir "$WORK/outside-dir"
touch "$WORK/outside-dir/stale"
touch -t 200001010000 "$WORK/outside-dir/stale"
ln -s "$WORK/outside-dir" "$WORKER_CLAIMS_DIR/escape"
assert worker_claims_prune codex
assert test -e "$WORKER_CLAIMS_DIR/codex/fresh"
assert test ! -e "$WORKER_CLAIMS_DIR/codex/stale"
assert test -e "$WORKER_CLAIMS_DIR/gemini/stale-other"
assert test -e "$outside"
assert worker_claims_prune
assert test ! -e "$WORKER_CLAIMS_DIR/gemini/stale-other"
assert test -e "$outside"
assert test -e "$WORK/outside-dir/stale"

before="$(find "$WORKER_CLAIMS_DIR" -print | sort)"
assert_fails worker_claims_record 'bad/vendor' account
assert_fails worker_claims_record vendor 'bad/account'
assert_fails worker_claims_record '..' account
assert_fails worker_claims_record vendor 'bad..account'
assert_fails worker_claims_fresh 'bad/vendor'
assert_fails worker_claims_prune '..'
assert test "$(find "$WORKER_CLAIMS_DIR" -print | sort)" = "$before"

missing="$WORK/missing"
WORKER_CLAIMS_DIR="$missing"
output="$WORK/missing.out"
assert worker_claims_fresh codex >"$output"
assert test ! -s "$output"
assert test ! -e "$missing"

echo "PASS: $asserts assertions; record and fresh, TTL expiry, stale-sibling independence, vendor isolation, bounded pruning, invalid-name rejection, and missing-directory silence"
