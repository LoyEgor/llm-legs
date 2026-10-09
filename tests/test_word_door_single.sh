#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# Egor's words are read by one module and permitted by one door: a program in bin/ or share/ that
# decides whether a step may run asks words.sh word_gate_allow, never the grant store directly.
# Only the readers listed below may touch a grant, each for its stated reason.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }

GRANT_READ='words_grant_(target|fresh)|(^|[/"'\''])grant\.([$]|[{]|[a-z])'

# path<TAB>door|exempt<TAB>reason. `door`: the reader asks word_gate_allow first and reads the
# grant only to hold his word to its own target or scope; `exempt`: decides without the door.
ALLOWED=$(cat <<'EOF'
bin/chat-pin	door	after word_gate_allow opened on his word, the grant's target must be the one asked
bin/worker-pin-gate.sh	door	after word_gate_allow opened on his word, the grant's scope must be the account pin
share/worker-model.sh	door	worker_model_pin_allowed: as worker-pin-gate.sh, for the account pin's command path
bin/night-run	exempt	cmd_hold decides on grant.night-hold directly; owed: route it through word_gate_allow (handoff, another chat's live edits)
EOF
)

readers() { # root -> repo-relative files in bin/ and share/ reading a grant outside a comment
  (cd "$1" && grep -rlE -- "$GRANT_READ" bin share 2>/dev/null | sort | while IFS= read -r file; do
    grep -vE '^[[:space:]]*#' "$file" | grep -qE -- "$GRANT_READ" && printf '%s\n' "$file"
  done)
}

check() { # root -> 0 when every grant reader is listed and every door reader asks the door
  local root=$1 file kind bad=0
  while IFS= read -r file; do
    kind=$(awk -F '\t' -v f="$file" '$1 == f { print $2 }' <<<"$ALLOWED")
    case "$kind" in
      door) grep -qE 'word_gate_allow[[:space:]]+"' "$root/$file" || { printf 'door reader without the door: %s\n' "$file"; bad=1; } ;;
      exempt) ;;
      *) printf 'reads a grant outside word_gate_allow: %s\n' "$file"; bad=1 ;;
    esac
  done < <(readers "$root")
  return "$bad"
}

listed_still_read() { # every allowlist entry still reads a grant, so no stale exemption outlives its reader
  local file
  while IFS=$'\t' read -r file _ _; do
    [ -n "$file" ] || continue
    readers "$ROOT" | grep -qxF -- "$file" || { printf 'stale allowlist entry: %s\n' "$file"; return 1; }
  done <<<"$ALLOWED"
}

quiet_check() { check "$1" >/dev/null; }

assert check "$ROOT"
assert listed_still_read

mkdir -p "$WORK/plant/bin" "$WORK/plant/share"
printf '#!/usr/bin/env bash\n# words_grant_fresh in a comment reads nothing\n' >"$WORK/plant/bin/quiet"
assert quiet_check "$WORK/plant"
printf 'ok=$(words_grant_target "$sid" pin)\n' >"$WORK/plant/bin/planted"
assert_fails quiet_check "$WORK/plant"
rm -f "$WORK/plant/bin/planted"
printf 'jq .target "$dir/grant.$family"\n' >"$WORK/plant/share/planted.sh"
assert_fails quiet_check "$WORK/plant"
rm -f "$WORK/plant/share/planted.sh"
printf 'g=$(words_grant_fresh "$sid" pin)\n' >"$WORK/plant/bin/chat-pin"
assert_fails quiet_check "$WORK/plant"

printf 'PASS: %s asserts; no program in bin/ or share/ decides on a grant of his words except through word_gate_allow, bar the listed readers\n' "$asserts"
