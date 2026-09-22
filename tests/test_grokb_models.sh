#!/usr/bin/env bash
# `grokb models` (shared-invariants row `cu`): the one Grok model list, fetched from a fake `grok`
# inside a fake signed-in profile, cached in a temp GROKB_CACHE_DIR, never ~/.cache/grokb.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/grokb"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; [ ! -f "$WORK/err" ] || cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts: expected [$2], got [$1]"
}

export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/bin"
export GROKB_PROFILES_DIR="$HOME/.grok-profiles"
export GROKB_CACHE_DIR="$WORK/cache"
export GROKB_GROK_BIN="$WORK/bin/grok"
export GROK_MODELS_OUT="$WORK/grok-models.txt" GROK_CALLS="$WORK/grok-calls" GROK_RC=0
cp "$ROOT/tests/fixtures/grok-models.txt" "$GROK_MODELS_OUT"
cat >"$GROKB_GROK_BIN" <<'GROK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GROK_CALLS"
printf '%s\n' "$GROK_HOME" >>"$GROK_CALLS.home"
[ "$1" = models ] || exit 9
cat "$GROK_MODELS_OUT"
exit "$GROK_RC"
GROK
chmod +x "$GROKB_GROK_BIN"
# One signed-in profile and one that is not: the list is account-independent, but only a signed-in
# profile is asked, so the unauthenticated one may never be the one picked.
mkdir -p "$GROKB_PROFILES_DIR/signedout" "$GROKB_PROFILES_DIR/supergrok"
printf '{"key":"k","email":"worker@example.com","refresh_token":"r","expires_at":"2099-01-01T00:00:00Z"}\n' \
  >"$GROKB_PROFILES_DIR/supergrok/auth.json"
printf '{}\n' >"$GROKB_PROFILES_DIR/signedout/auth.json"

CACHE="$GROKB_CACHE_DIR/models.json"
TAB=$(printf '\t')
calls() { if [ -f "$GROK_CALLS" ]; then wc -l <"$GROK_CALLS" | tr -d ' '; else printf 0; fi; }
models() { bash "$SCRIPT" models "$@" 2>"$WORK/err"; }
age_cache() { # seconds
  local stamp=$(($(date +%s) - $1))
  jq --argjson s "$stamp" '.fetched_at = $s | .attempted_at = $s' "$CACHE" >"$CACHE.new" && mv "$CACHE.new" "$CACHE"
}

expected="grok-4.7${TAB}yes${TAB}grok-4.7
grok-4.7-build-fast${TAB}no${TAB}grok-4.7-build-fast
grok-4.6${TAB}no${TAB}grok-4.6
grok-4.5${TAB}no${TAB}grok-4.5"

# --- Fresh fetch: no cache, grok lists the models, the prose around the block is dropped ---
assert_eq "$(models)" "$expected"
assert_eq "$(calls)" 1
assert_eq "$(head -n1 "$GROK_CALLS")" models
assert_eq "$(head -n1 "$GROK_CALLS.home")" "$GROKB_PROFILES_DIR/supergrok"
assert test -s "$CACHE"
assert jq -e '(.fetched_at | type) == "number" and (.models | length) == 4' "$CACHE" >/dev/null
assert_eq "$(jq -r '.default' "$CACHE")" grok-4.7
assert_eq "$(jq -r '.models[1] | [.slug, .default, .label] | join("|")' "$CACHE")" \
  'grok-4.7-build-fast|false|grok-4.7-build-fast'
assert_eq "$(cat "$WORK/err")" ''

# --- A fresh cache answers without asking grok ---
assert_eq "$(models)" "$expected"
assert_eq "$(calls)" 1

# --- --json: the same rows as a list of objects ---
assert_eq "$(models --json | jq -r '.[] | [.slug, (if .default then "yes" else "no" end), .label] | @tsv')" "$expected"
assert_eq "$(models --json | jq -r '.[3] | keys | join(",")')" 'default,label,slug'

# --- --refresh asks grok inside the TTL, and a new release reaches every reader ---
printf 'Default model: grok-5\n\nAvailable models:\n  * grok-5 (default)\n  - grok-4.7\n' >"$GROK_MODELS_OUT"
rolled="$(models --refresh)"
assert_eq "$(calls)" 2
assert_eq "$(printf '%s\n' "$rolled" | cut -f1 | tr '\n' ,)" 'grok-5,grok-4.7,'
assert_eq "$(printf '%s\n' "$rolled" | head -n1)" "grok-5${TAB}yes${TAB}grok-5"
# The CLI's order is the list's order, and `Default model:` alone marks the default when the block
# carries no `(default)` — the two ways one release states the same fact.
printf 'Available models:\n  - grok-4.6\n  - grok-4.7\n\nDefault model: grok-4.7\n' >"$GROK_MODELS_OUT"
assert_eq "$(models --refresh | tr '\n\t' ',:')" 'grok-4.6:no:grok-4.6,grok-4.7:yes:grok-4.7,'
# When the two disagree the block's own marker is the answer: the `Default model:` line is what a
# profile that is not signed in also answers with, and it goes stale a release before the block does.
printf 'Default model: grok-4.6\n\nAvailable models:\n  - grok-4.6\n  * grok-4.7 (default)\n' >"$GROK_MODELS_OUT"
assert_eq "$(models --refresh | tr '\n\t' ',:')" 'grok-4.6:no:grok-4.6,grok-4.7:yes:grok-4.7,'
cp "$ROOT/tests/fixtures/grok-models.txt" "$GROK_MODELS_OUT"
models --refresh >/dev/null

# --- 24 h: a cache just under the TTL is read, one just over it is refreshed ---
age_cache 86000
models >/dev/null
assert_eq "$(calls)" 5
age_cache 86500
assert_eq "$(models)" "$expected"
assert_eq "$(calls)" 6
assert test "$(($(date +%s) - $(jq '.fetched_at' "$CACHE")))" -lt 60

# --- Stale fallback: grok fails, the old cache answers and stderr says so ---
age_cache 90000
GROK_RC=1 models >"$WORK/out"
assert_eq "$(cat "$WORK/out")" "$expected"
assert_eq "$(calls)" 7
assert grep -q '^grokb: grok models failed; using the models cached at ' "$WORK/err"
# The failed attempt is stamped, so the next reader inside the TTL does not ask grok again.
GROK_RC=1 models >"$WORK/out"
assert_eq "$(cat "$WORK/out")" "$expected"
assert_eq "$(calls)" 7
assert grep -q '^grokb: grok models failed' "$WORK/err"
printf 'You are not authenticated.\n' >"$GROK_MODELS_OUT"
assert_eq "$(models --refresh)" "$expected"
assert_eq "$(calls)" 8

# --- No cache at all: the built-in list, with or without a grok ---
rm -rf "$GROKB_CACHE_DIR"
assert_eq "$(models)" "$expected"
assert_eq "$(calls)" 9
assert grep -qx 'grokb: grok models failed; no cache; using the built-in list' "$WORK/err"
assert_eq "$(jq -c '.models' "$CACHE")" '[]'
assert_eq "$(models)" "$expected"
assert_eq "$(calls)" 9
rm -rf "$GROKB_CACHE_DIR"
assert_eq "$(GROKB_GROK_BIN="$WORK/bin/missing" models)" "$expected"
printf '{not json' >"$CACHE"
assert_eq "$(GROKB_GROK_BIN="$WORK/bin/missing" models)" "$expected"
# No signed-in profile is the same answer: nothing is asked and the built-in list stands.
rm -rf "$GROKB_CACHE_DIR"
cp "$ROOT/tests/fixtures/grok-models.txt" "$GROK_MODELS_OUT"
before=$(calls)
assert_eq "$(GROKB_PROFILES_DIR="$WORK/none" models)" "$expected"
assert_eq "$(calls)" "$before"

# --- Every signed-in profile is tried before a failure is cached (item: models_fetch) ---
# The first profile `grokb list` prints answers with nothing parseable; the list still comes back,
# and the good profile is the one that fetched it.
mkdir -p "$GROKB_PROFILES_DIR/broken"
printf '{"key":"k","email":"broken@example.com","refresh_token":"r","expires_at":"2099-01-01T00:00:00Z"}\n' \
  >"$GROKB_PROFILES_DIR/broken/auth.json"
rm -rf "$GROKB_CACHE_DIR"
: >"$GROK_CALLS"; : >"$GROK_CALLS.home"
cat >"$GROKB_GROK_BIN" <<'GROK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GROK_CALLS"
printf '%s\n' "$GROK_HOME" >>"$GROK_CALLS.home"
[ "$1" = models ] || exit 9
case "$GROK_HOME" in *['/']broken) printf 'You are not authenticated.\n'; exit 0 ;; esac
cat "$GROK_MODELS_OUT"
exit "$GROK_RC"
GROK
chmod +x "$GROKB_GROK_BIN"
assert_eq "$(models)" "$expected"
assert_eq "$(calls)" 2
assert_eq "$(cat "$GROK_CALLS.home")" "$GROKB_PROFILES_DIR/broken
$GROKB_PROFILES_DIR/supergrok"
# A good profile behind a broken one means the failure is NOT cached: the fetch stamp is this run's.
assert test "$(($(date +%s) - $(jq '.fetched_at' "$CACHE")))" -lt 60
rm -rf "$GROKB_PROFILES_DIR/broken"
cat >"$GROKB_GROK_BIN" <<'GROK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GROK_CALLS"
printf '%s\n' "$GROK_HOME" >>"$GROK_CALLS.home"
[ "$1" = models ] || exit 9
cat "$GROK_MODELS_OUT"
exit "$GROK_RC"
GROK
chmod +x "$GROKB_GROK_BIN"
: >"$GROK_CALLS"; : >"$GROK_CALLS.home"

# --- No-fetch: a hook reads the list, it never asks the CLI (item: GROKB_MODELS_NO_FETCH) ---
# An empty cache dir and a grok that would answer: both spellings take the built-in list instead,
# and the CLI is not called at all — an interactive hook may not wait 30 s on it.
rm -rf "$GROKB_CACHE_DIR"
before=$(calls)
assert_eq "$(GROKB_MODELS_NO_FETCH=1 models)" "$expected"
assert_eq "$(calls)" "$before"
assert_eq "$(models --cached)" "$expected"
assert_eq "$(calls)" "$before"
# Not even `--refresh` inside the TTL, and the two words refuse each other.
models >/dev/null
assert_eq "$(calls)" "$((before + 1))"
assert_eq "$(GROKB_MODELS_NO_FETCH=1 models --refresh)" "$expected"
assert_eq "$(calls)" "$((before + 1))"
assert_eq "$(bash "$SCRIPT" models --refresh --cached 2>&1 >/dev/null; printf 'rc=%s' "$?")" \
  "grokb: --refresh and --cached are opposites
rc=2"
# A cache the no-fetch reader finds is the answer, stamps and all: nothing is written behind it.
before=$(calls)
stamp=$(jq '.fetched_at' "$CACHE")
assert_eq "$(models --cached)" "$expected"
assert_eq "$(jq '.fetched_at' "$CACHE")" "$stamp"
assert_eq "$(calls)" "$before"

# --- The quota cache is not this list's file and is never touched ---
assert test ! -e "$HOME/.llm-limits-grok.json"

# --- Usage ---
assert_eq "$(bash "$SCRIPT" models --bogus 2>&1 >/dev/null; printf 'rc=%s' "$?")" "usage: grokb models [--json] [--refresh|--cached]
rc=2"

printf 'PASS: %s asserts; grokb models (fresh fetch from a signed-in profile with the CLI prose dropped, TSV and --json, --refresh, the CLI order kept with either default marker, the 24 h TTL both sides, the stale cache with a stderr note and a stamped attempt, a failing or unauthenticated grok never trusted, every signed-in profile tried before a failure is cached, the built-in list with no cache, an unreadable one or no signed-in profile — saying so on stderr — and the no-fetch mode a hook reads the list through)\n' "$asserts"
