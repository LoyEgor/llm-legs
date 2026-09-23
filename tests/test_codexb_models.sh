#!/usr/bin/env bash
# `codexb models` (shared-invariants row `cv`): the one Codex model list, read from the newest
# models_cache.json of fixture homes, never ~/.codex or a real codexb profile.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/codexb"
FIXTURE="$ROOT/tests/fixtures/codexb-models.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; [ ! -f "$WORK/err" ] || cat "$WORK/err" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
assert_eq() {
  asserts=$((asserts + 1))
  [ "$1" = "$2" ] || fail "assert $asserts: expected [$2], got [$1]"
}

unset CODEXB_MODELS_CACHE CODEX_HOME
export HOME="$WORK/home"
export CODEXB_PROFILES_DIR="$HOME/.codex-profiles"
mkdir -p "$HOME/.codex" "$CODEXB_PROFILES_DIR/alpha" "$CODEXB_PROFILES_DIR/beta"
TAB=$(printf '\t')
models() { bash "$SCRIPT" models "$@" 2>"$WORK/err"; }
slug_of() { bash -c '. "$1/share/worker-model.sh"; worker_model_codex_slug "$2"' _ "$ROOT" "$1" 2>/dev/null; }
allows() { bash -c '. "$1/share/worker-model.sh"; worker_model_allows codex "$2"' _ "$ROOT" "$1" 2>/dev/null; }
stamp() { # file fetched-at
  jq --arg at "$2" '.fetched_at = $at' "$FIXTURE" >"$1"
}

# --- No cache anywhere: the builtin list, said so on stderr and in --json ---
assert_eq "$(models | cut -f1,2,3,5)" "gpt-6-astra${TAB}astra${TAB}6${TAB}y
gpt-5.6-sol${TAB}sol${TAB}5.6${TAB}n
gpt-5.6-terra${TAB}terra${TAB}5.6${TAB}n
gpt-5.6-luna${TAB}luna${TAB}5.6${TAB}n
gpt-5.5${TAB}gpt-5.5${TAB}5.5${TAB}n"
assert grep -q 'built-in list' "$WORK/err"
assert_eq "$(models --json | jq -r '[.[].source] | unique | join(",")')" builtin
assert_eq "$(models --family astra)" gpt-6-astra
# The read never touches a profile: ensure_profiles would link ~/.codex items into each one.
touch "$HOME/.codex/config.toml"
models >/dev/null
assert_eq "$(ls -A "$CODEXB_PROFILES_DIR/alpha")" ''

# --- The newest cache by fetched_at wins, whichever home holds it ---
jq '.fetched_at = "2026-09-20T00:00:00.000000Z" | .models |= map(select(.slug != "gpt-6.1-astra"))' \
  "$FIXTURE" >"$HOME/.codex/models_cache.json"
stamp "$CODEXB_PROFILES_DIR/beta/models_cache.json" 2026-09-23T08:00:00.000000Z
printf 'not json\n' >"$CODEXB_PROFILES_DIR/alpha/models_cache.json"
expected="gpt-6.1-astra${TAB}astra${TAB}6.1${TAB}GPT-6.1-Astra${TAB}y${TAB}low,medium,high,xhigh,max
gpt-6-astra${TAB}astra${TAB}6${TAB}GPT-6-Astra${TAB}n${TAB}low,medium,high,xhigh
gpt-5.6-sol${TAB}sol${TAB}5.6${TAB}GPT-5.6-Sol${TAB}n${TAB}low,medium,high,xhigh
gpt-5.6-terra${TAB}terra${TAB}5.6${TAB}GPT-5.6-Terra${TAB}n${TAB}low,medium,high
gpt-5.5${TAB}gpt-5.5${TAB}5.5${TAB}GPT-5.5${TAB}n${TAB}low,medium,high,xhigh"
assert_eq "$(models)" "$expected"
assert_eq "$(cat "$WORK/err")" ''
assert_eq "$(models --family astra)" gpt-6.1-astra
assert_eq "$(slug_of astra)" gpt-6.1-astra
# An older home stays behind a newer one even when it is the main ~/.codex.
jq '.fetched_at = "2026-09-24T00:00:00.000000Z"' "$HOME/.codex/models_cache.json" >"$WORK/newer" &&
  mv "$WORK/newer" "$HOME/.codex/models_cache.json"
assert_eq "$(models --family astra)" gpt-6-astra
jq '.fetched_at = "2026-09-20T00:00:00.000000Z"' "$HOME/.codex/models_cache.json" >"$WORK/older" &&
  mv "$WORK/older" "$HOME/.codex/models_cache.json"

# --- Hidden models only under --all; --json carries every column and the cache path ---
assert_eq "$(models --all | cut -f1 | tr '\n' ' ')" \
  'gpt-6.1-astra gpt-6-astra gpt-reserve gpt-5.6-sol gpt-5.6-terra gpt-5.5 codex-auto-review '
assert_eq "$(models --json | jq -c '.[0]')" \
  "{\"slug\":\"gpt-6.1-astra\",\"family\":\"astra\",\"version\":\"6.1\",\"label\":\"GPT-6.1-Astra\",\"default\":true,\"efforts\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\"],\"priority\":1,\"visibility\":\"list\",\"source\":\"cache\",\"cache\":\"$CODEXB_PROFILES_DIR/beta/models_cache.json\"}"
assert_eq "$(models --json | jq -r '.[] | select(.slug == "gpt-5.5") | .version')" 5.5

# --- Families by the priority of their newest member, not of their best-ranked one ---
jq '.models |= map(if .slug == "gpt-6.1-astra" then .priority = 6 elif .slug == "gpt-6-astra" then .priority = 1 else . end)' \
  "$CODEXB_PROFILES_DIR/beta/models_cache.json" >"$WORK/reranked"
assert_eq "$(CODEXB_MODELS_CACHE="$WORK/reranked" bash "$SCRIPT" models | cut -f1,5 | tr '\n' ' ')" \
  "gpt-5.6-sol${TAB}n gpt-6.1-astra${TAB}n gpt-6-astra${TAB}y gpt-5.6-terra${TAB}n gpt-5.5${TAB}n "

# --- --family: a word, a slug given back, and a refusal naming what is known ---
assert_eq "$(models --family sol)" gpt-5.6-sol
assert_eq "$(models --family gpt-5.5)" gpt-5.5
assert_eq "$(models --family gpt-5.6-sol)" gpt-5.6-sol
assert_eq "$(models --family gpt-reserve)" gpt-reserve
out=$(models --family luna); rc=$?
assert_eq "$rc" 1
assert_eq "$out" ''
assert_eq "$(cat "$WORK/err")" 'codexb: no listed codex model of family luna; families: astra, sol, terra, gpt-5.5'
assert_eq "$(models --family reserve 2>/dev/null; printf %s $?)" 1
models --bogus >/dev/null; assert_eq "$?" 2

# --- The table keys on the family word; a slug is allowed through its family ---
assert_eq "$(bash -c '. "$1/share/worker-model.sh"; worker_model_allowed_list codex' _ "$ROOT")" 'astra|sol'
for model in astra sol gpt-6.1-astra gpt-6-astra gpt-5.6-sol; do assert allows "$model"; done
for model in terra gpt-5.6-terra gpt-5.5 luna ''; do assert_eq "$(allows "$model"; printf %s $?)" 1; done
assert_eq "$(bash -c '. "$1/share/worker-model.sh"; worker_model_default_effort codex gpt-6.1-astra; worker_model_effort_list codex gpt-5.6-sol' _ "$ROOT")" \
  'low
medium|high|low|xhigh'
assert_eq "$(slug_of gpt-5.6-sol)" gpt-5.6-sol
assert_eq "$(slug_of luna; printf %s $?)" 1
assert_eq "$(bash -c '. "$1/share/worker-model.sh"; worker_model_codex_split gpt-6.1-astra; worker_model_codex_split gpt-5.5; worker_model_codex_split codex-auto-review' _ "$ROOT")" \
  "astra${TAB}6.1
gpt-5.5${TAB}5.5
codex-auto-review${TAB}-"

# --- codexb's own chat launch opens on the resolved default ---
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nfor a in "$@"; do printf "ARG=%%s\\n" "$a"; done >"%s"\n' "$WORK/calls" >"$WORK/bin/codex"
chmod +x "$WORK/bin/codex"
PATH="$WORK/bin:$PATH" bash "$SCRIPT" profile alpha >/dev/null 2>&1
assert grep -qx 'ARG=gpt-6.1-astra' "$WORK/calls"

printf 'PASS: %s assertions\n' "$asserts"
