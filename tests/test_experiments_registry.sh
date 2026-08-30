#!/usr/bin/env bash
# Standing reminder for every active experiment in this repo: an entry past its
# review_by fails here, so the owner gets asked for a decision instead of the
# scaffolding quietly becoming architecture. Never bump a date or weaken a check
# to get this green — that is the whole point of the suite.
# Portable to stock macOS bash 3.2 (no mapfile): the suites must run under /bin/bash.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REGISTRY="$ROOT/EXPERIMENTS.json"
asserts=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert() { if ! "$@"; then fail "assert $((asserts + 1)): $*"; fi; asserts=$((asserts + 1)); }
today=${EXPERIMENTS_TODAY_OVERRIDE:-$(date '+%Y-%m-%d')}

[ -r "$REGISTRY" ] || fail "EXPERIMENTS.json is missing: every experiment must be registered"
jq -e 'type == "array"' "$REGISTRY" >/dev/null || fail "EXPERIMENTS.json must be a JSON array"

# An experiment is either code (a TEMP-<NAME>(<scope>) tag on every touched block) or
# state (a marker file that switches behavior); both need an executable exit.
schema_errors=$(jq -r '
  to_entries[] | .key as $i | .value |
  [ (if (.id | type) == "string" and (.id | length) > 0 then empty else "entry \($i): missing id" end),
    (if (.what | type) == "string" and (.what | length) > 10 then empty else "entry \($i): missing what" end),
    (if (.started | type) == "string" then empty else "entry \($i): missing started" end),
    (if (.review_by | type) == "string" then empty else "entry \($i): missing review_by" end),
    (if (.how_to_remove | type) == "string" and (.how_to_remove | length) > 10 then empty else "entry \($i): missing how_to_remove" end),
    (if ((.tag | type) == "string") or ((.state_marker | type) == "string") then empty else "entry \($i): needs a tag (code experiment) or a state_marker (state experiment)" end)
  ] | .[]' "$REGISTRY")
[ -z "$schema_errors" ] || fail "EXPERIMENTS.json schema: $schema_errors"
asserts=$((asserts + 1))

format_errors=$(jq -r '
  to_entries[] | .key as $i | .value |
  [ (if (.started | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then empty else "entry \($i): started is not YYYY-MM-DD" end),
    (if (.review_by | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then empty else "entry \($i): review_by is not YYYY-MM-DD" end),
    (if (.review_by >= .started) then empty else "entry \($i): review_by precedes started" end)
  ] | .[]' "$REGISTRY")
[ -z "$format_errors" ] || fail "EXPERIMENTS.json dates: $format_errors"
asserts=$((asserts + 1))

# A well-formed but impossible date (2026-99-99) would sort past every real today and
# defer the reminder forever, so each date is parsed by the calendar, not just matched.
while IFS=$'\t' read -r entry_id started review; do
  [ -n "$entry_id" ] || continue
  for field_date in "$started" "$review"; do
    date -j -f '%Y-%m-%d' "$field_date" '+%Y-%m-%d' >/dev/null 2>&1 \
      || date -d "$field_date" '+%Y-%m-%d' >/dev/null 2>&1 \
      || fail "EXPERIMENTS.json: $entry_id has a date that is not a real calendar day: $field_date"
    asserts=$((asserts + 1))
  done
done < <(jq -r '.[] | [(.id // ""), (.started // ""), (.review_by // "")] | @tsv' "$REGISTRY")

# A temporary block hides in whatever file the experiment touched, so scan the whole tree.
# The registry is excluded, or its own entries would satisfy the round-trip below.
registered_tags=$(jq -r '.[] | select(.tag) | .tag' "$REGISTRY")
code_tags=$(grep -rhoE 'TEMP-[A-Z][A-Z0-9_-]*\([a-z0-9_-]+\)' "$ROOT" \
  --exclude-dir=.git --exclude=EXPERIMENTS.json 2>/dev/null | sort -u || true)
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  printf '%s\n' "$registered_tags" | grep -qxF "$tag" \
    || fail "unregistered experiment tag in code: $tag — add it to EXPERIMENTS.json with started/review_by/how_to_remove"
  asserts=$((asserts + 1))
done <<EOF
$code_tags
EOF
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  printf '%s\n' "$code_tags" | grep -qxF "$tag" \
    || fail "EXPERIMENTS.json lists $tag but no such tag remains in code: finish the removal and delete the entry"
  asserts=$((asserts + 1))
done <<EOF
$registered_tags
EOF

# Without a declared surface nobody notices the trial is live until they read the repo.
surface_errors=$(jq -r '
  to_entries[] | .key as $i | .value | select(.state_marker) |
  if ((.surfaces | type) == "array") and ((.surfaces | length) > 0) then empty
  else "entry \($i): a state experiment must list surfaces where it is visible" end' "$REGISTRY")
[ -z "$surface_errors" ] || fail "EXPERIMENTS.json surfaces: $surface_errors"
asserts=$((asserts + 1))

for opt_in_file in CLAUDE.md docs/DIAGNOSTICS.md docs/statusline-contract.md; do
  ! grep -Fq 'docs/analysis' "$ROOT/$opt_in_file" \
    || fail "$opt_in_file points always-loaded context at docs/analysis; keep the analysis opt-in"
done
asserts=$((asserts + 1))

overdue=$(jq -r --arg today "$today" '.[] | select(.review_by < $today) | "\(.id) (review_by \(.review_by))"' "$REGISTRY")
if [ -n "$overdue" ]; then
  printf 'FAIL: EXPERIMENT REVIEW OVERDUE: %s\n' "$(printf '%s' "$overdue" | tr '\n' ';')" >&2
  printf 'This failure IS the standing reminder. Ask Egor to decide: remove the experiment\n' >&2
  printf 'completely (follow its how_to_remove — no legacy residue), or extend review_by with\n' >&2
  printf 'a new plan. Never extend the date or weaken this test without his explicit word.\n' >&2
  exit 1
fi
asserts=$((asserts + 1))

printf 'PASS: %s asserts; experiment registry (schema, real calendar dates, code tags round-trip, visible surfaces, opt-in analysis, review deadlines)\n' "$asserts"
