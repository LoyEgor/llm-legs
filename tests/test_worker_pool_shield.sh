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
  if "$@"; then fail "assert $asserts unexpectedly succeeded: $*"; fi
}

HOME="$WORK/home"
CLAUDEB_DIR="$WORK/claudeb"
CODEXB_PROFILES_DIR="$WORK/codex"
GEMINIB_PROFILES_DIR="$WORK/gemini"
GROKB_PROFILES_DIR="$WORK/grok"
export HOME CLAUDEB_DIR CODEXB_PROFILES_DIR GEMINIB_PROFILES_DIR GROKB_PROFILES_DIR
mkdir -p "$HOME" "$CLAUDEB_DIR/tokens"
. "$ROOT/share/worker-pool.sh"

epoch=1900000000
assert worker_pool_shield_set claudeb alpha "$epoch"
assert worker_pool_shield_active claudeb alpha
assert test "$(worker_pool_marker_epoch claudeb shielded alpha)" = "$epoch"
assert worker_pool_is_disabled "$CLAUDEB_DIR" alpha
assert jq -e 'index("alpha") != null' <<<"$(worker_pool_disabled_json "$CLAUDEB_DIR")" >/dev/null
assert jq -e 'index("alpha") != null' <<<"$(worker_pool_shielded_json "$CLAUDEB_DIR")" >/dev/null
assert worker_pool_shield_clear claudeb alpha
assert_fails worker_pool_shield_active claudeb alpha

touch "$CLAUDEB_DIR/tokens/burn"
assert worker_pool_shield_set claudeb burn "$epoch"
enable_out=$(bash "$ROOT/bin/claudeb" enable burn) || fail "claudeb enable failed for a shielded account"
assert grep -q '^claudeb: enabled burn$' <<<"$enable_out"
assert_fails worker_pool_shield_active claudeb burn
assert test "$(worker_pool_marker_epoch claudeb shield-override burn)" = "$epoch"
assert worker_pool_override_current claudeb burn "$epoch"
assert_fails worker_pool_override_current claudeb burn "$((epoch + 1))"
assert_fails worker_pool_is_disabled "$CLAUDEB_DIR" burn
assert worker_pool_override_clear claudeb burn

assert worker_pool_shield_override claudeb absent
assert_fails worker_pool_shield_set claudeb ../escape "$epoch"
assert_fails worker_pool_shield_set claudeb bad/name "$epoch"
assert_fails worker_pool_shield_clear claudeb ../escape
assert_fails worker_pool_shield_active claudeb ../escape
assert_fails worker_pool_shield_override claudeb ../escape
assert_fails worker_pool_override_current claudeb ../escape "$epoch"
assert worker_pool_is_disabled "$CLAUDEB_DIR" ../escape
assert test ! -e "$WORK/escape"

echo "PASS: $asserts asserts; shield marker roundtrips, pool exclusion, enable override, epoch matching, and name rejection"
