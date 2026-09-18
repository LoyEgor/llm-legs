#!/usr/bin/env bash
# `geminib families` (shared-invariants row `cr`): the one Gemini family list, fetched from a fake
# `agy models`, cached in a temp GEMINIB_CACHE_DIR, never the real ~/.cache/geminib.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/geminib"
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
export GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles"
export GEMINIB_CACHE_DIR="$WORK/cache"
export AGY_BIN="$WORK/bin/agy"
export AGY_MODELS_OUT="$WORK/agy-models.txt" AGY_CALLS="$WORK/agy-calls" AGY_RC=0
cp "$ROOT/tests/fixtures/agy-models.txt" "$AGY_MODELS_OUT"
cat >"$AGY_BIN" <<'AGY'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AGY_CALLS"
[ "$1" = models ] || exit 9
printf 'Fetching available models...\n' >&2
cat "$AGY_MODELS_OUT"
exit "$AGY_RC"
AGY
chmod +x "$AGY_BIN"
CACHE="$GEMINIB_CACHE_DIR/models.json"
TAB=$(printf '\t')
calls() { if [ -f "$AGY_CALLS" ]; then wc -l <"$AGY_CALLS" | tr -d ' '; else printf 0; fi; }
families() { bash "$SCRIPT" families "$@" 2>"$WORK/err"; }
age_cache() { # seconds
  local stamp=$(($(date +%s) - $1))
  jq --argjson s "$stamp" '.fetched_at = $s | .attempted_at = $s' "$CACHE" >"$CACHE.new" && mv "$CACHE.new" "$CACHE"
}

expected="gemini-3.8-flash${TAB}flash38${TAB}gemini-3.8-flash${TAB}Gemini 3.8 Flash
gemini-3.7-flash${TAB}flash37${TAB}gemini-3.7-flash${TAB}Gemini 3.7 Flash
gemini-3.6-flash${TAB}flash36${TAB}gemini-3.6-flash${TAB}Gemini 3.6 Flash
gemini-3.1-pro${TAB}pro${TAB}gemini-3.1-pro${TAB}Gemini 3.1 Pro"

# --- Fresh fetch: no cache, agy lists the families; effort rows fold, non-Gemini rows drop ---
assert_eq "$(families)" "$expected"
assert_eq "$(calls)" 1
assert_eq "$(head -n1 "$AGY_CALLS")" models
assert test -s "$CACHE"
assert jq -e '(.fetched_at | type) == "number" and (.families | length) == 4' "$CACHE" >/dev/null
assert_eq "$(jq -r '.families[1] | [.family, .slug, .agy_prefix, .label] | join("|")' "$CACHE")" \
  'gemini-3.7-flash|flash37|gemini-3.7-flash|Gemini 3.7 Flash'
assert_eq "$(cat "$WORK/err")" ''

# --- A fresh cache answers without asking agy ---
assert_eq "$(families)" "$expected"
assert_eq "$(calls)" 1

# --- --json: the same rows as a list of objects ---
assert_eq "$(families --json | jq -r '.[] | [.family, .slug, .agy_prefix, .label] | @tsv')" "$expected"
assert_eq "$(families --json | jq -r '.[3] | keys | join(",")')" 'agy_prefix,family,label,slug'

# --- --refresh asks agy even inside the TTL, and a rollout reaches every reader ---
{
  printf 'gemini-3.9-flash-high\tGemini 3.9 Flash (High)\n'
  grep -v '^gemini-3\.6-flash' "$ROOT/tests/fixtures/agy-models.txt"
} >"$AGY_MODELS_OUT"
rolled="$(families --refresh)"
assert_eq "$(calls)" 2
assert_eq "$(printf '%s\n' "$rolled" | cut -f2 | tr '\n' ,)" 'flash39,flash38,flash37,pro,'
assert_eq "$(printf '%s\n' "$rolled" | head -n1)" "gemini-3.9-flash${TAB}flash39${TAB}gemini-3.9-flash${TAB}Gemini 3.9 Flash"

# --- Newest first by version whatever agy's order; the newest pro owns `pro` ---
printf 'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\ngemini-3.7-flash-low\tGemini 3.7 Flash (Low)\ngemini-3.9-pro-low\tGemini 3.9 Pro (Low)\ngemini-3.8-flash\tGemini 3.8 Flash\ngemini-3.1-flash-image\tNano\n' >"$AGY_MODELS_OUT"
assert_eq "$(families --refresh | cut -f1,2 | tr '\n\t' ',:')" 'gemini-3.9-pro:pro,gemini-3.8-flash:flash38,gemini-3.7-flash:flash37,'
cp "$ROOT/tests/fixtures/agy-models.txt" "$AGY_MODELS_OUT"
families --refresh >/dev/null

# --- 24 h: a cache just under the TTL is read, one just over it is refreshed ---
age_cache 86000
families >/dev/null
assert_eq "$(calls)" 4
age_cache 86500
assert_eq "$(families)" "$expected"
assert_eq "$(calls)" 5
assert test "$(($(date +%s) - $(jq '.fetched_at' "$CACHE")))" -lt 60

# --- Stale fallback: agy fails, the old cache answers and stderr says so ---
age_cache 90000
AGY_RC=1 families >"$WORK/out"
assert_eq "$(cat "$WORK/out")" "$expected"
assert_eq "$(calls)" 6
assert grep -q '^geminib: agy models failed; using the families cached at ' "$WORK/err"
# The failed attempt is stamped, so the next reader inside the TTL does not ask agy again.
AGY_RC=1 families >"$WORK/out"
assert_eq "$(cat "$WORK/out")" "$expected"
assert_eq "$(calls)" 6
assert grep -q '^geminib: agy models failed' "$WORK/err"
printf 'nothing gemini here\n' >"$AGY_MODELS_OUT"
assert_eq "$(families --refresh)" "$expected"
assert_eq "$(calls)" 7

# --- No cache at all: the built-in list, with or without an agy ---
rm -rf "$GEMINIB_CACHE_DIR"
assert_eq "$(families)" "$expected"
assert_eq "$(calls)" 8
assert_eq "$(jq -c '.families' "$CACHE")" '[]'
assert_eq "$(families)" "$expected"
assert_eq "$(calls)" 8
rm -rf "$GEMINIB_CACHE_DIR"
assert_eq "$(AGY_BIN="$WORK/bin/missing" families)" "$expected"
printf '{not json' >"$CACHE"
assert_eq "$(AGY_BIN="$WORK/bin/missing" families)" "$expected"

# --- The capacity chain is the flash families of this list, in its order ---
cp "$ROOT/tests/fixtures/geminib-models.json" "$CACHE"
jq --argjson s "$(date +%s)" '.fetched_at = $s | .attempted_at = $s
  | .families = [{family: "gemini-3.9-flash", slug: "flash39", agy_prefix: "gemini-3.9-flash", label: "Gemini 3.9 Flash"}] + .families' \
  "$CACHE" >"$CACHE.new" && mv "$CACHE.new" "$CACHE"
cat >"$AGY_BIN" <<'AGY'
#!/usr/bin/env bash
model=''; log=''; want=''
for argument in "$@"; do
  case "$want" in model) model=$argument ;; log) log=$argument ;; esac
  want=''
  case "$argument" in --model) want=model ;; --log-file) want=log ;; models) exit 9 ;; esac
done
printf '%s\n' "$model" >>"$AGY_CALLS.launch"
[ "$model" != gemini-3.9-flash-high ] || { printf 'No capacity available for model %s\n' "$model" >>"$log"; exit 1; }
printf 'answer\n'
AGY
chmod +x "$AGY_BIN"
GEMINIB_CAPACITY_FALLBACK=1 \
  bash "$SCRIPT" agy-launch --agy "$AGY_BIN" -- --model gemini-3.9-flash-high --log-file "$WORK/launch.log" \
  --print hi >"$WORK/out" 2>"$WORK/err"
assert_eq "$(tr '\n' , <"$AGY_CALLS.launch")" 'gemini-3.9-flash-high,gemini-3.8-flash-high,'
assert grep -qx 'geminib: capacity fallback gemini-3.9-flash-high -> gemini-3.8-flash-high' "$WORK/err"

# --- The review Flash pin (row `cs`): one file beside the model cache, Flash slugs only ---
jq --argjson s "$(date +%s)" '.fetched_at = $s | .attempted_at = $s' \
  "$ROOT/tests/fixtures/geminib-models.json" >"$CACHE"
PIN="$GEMINIB_CACHE_DIR/review-flash"
pin() { bash "$SCRIPT" review-flash "$@" 2>"$WORK/err"; }
assert test ! -e "$PIN"
assert_eq "$(pin)" "flash38${TAB}default"
assert pin flash37
assert_eq "$(cat "$PIN")" flash37
assert_eq "$(pin)" "flash37${TAB}pinned"
assert_eq "$(bash "$SCRIPT" review-flash flash99 2>&1 >/dev/null; printf 'rc=%s' "$?")" \
  'geminib: not a Flash family slug: flash99 (see `geminib families`)
rc=2'
# A refused slug leaves the running pin where it was.
assert_eq "$(cat "$PIN")" flash37
assert_eq "$(bash "$SCRIPT" review-flash pro 2>/dev/null; printf 'rc=%s' "$?")" 'rc=2'
assert_eq "$(cat "$PIN")" flash37
assert pin --clear
assert test ! -e "$PIN"
assert_eq "$(pin)" "flash38${TAB}default"
assert pin --clear
assert_eq "$(bash "$SCRIPT" review-flash flash37 extra 2>&1 >/dev/null; printf 'rc=%s' "$?")" \
  "usage: geminib review-flash [<slug>|--clear]
rc=2"

# --- Usage ---
assert_eq "$(bash "$SCRIPT" families --bogus 2>&1 >/dev/null; printf 'rc=%s' "$?")" "usage: geminib families [--json] [--refresh]
rc=2"

printf 'PASS: %s asserts; geminib families (fresh fetch from agy models with effort rows folded and non-Gemini rows dropped, TSV and --json, --refresh, newest version first with the newest pro owning `pro`, the 24 h TTL both sides, the stale cache with a stderr note and a stamped attempt, a failing or empty agy never trusted, the built-in list with no cache or an unreadable one, the capacity chain following the list, the review Flash pin set, printed, refused and cleared)\n' "$asserts"
