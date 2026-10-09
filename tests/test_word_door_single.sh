#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# Egor's words are read by one module: a program in bin/ or share/ reads the grant store only
# through words.sh, and only the readers listed below read a grant at all, each for its stated reason.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts should have failed: $*"; }

GRANT_READ='words_grant_(target|fresh)|(^|[/"'\''])grant\.([$]|[{]|[a-z])'

# path<TAB>reason
ALLOWED=$(cat <<'EOF'
bin/night-run	the hold records the grant's excerpt as his words; it decides nothing on it
EOF
)

readers() { # root -> repo-relative files in bin/ and share/ reading a grant outside a comment
  (cd "$1" && grep -rlE -- "$GRANT_READ" bin share 2>/dev/null | sort | while IFS= read -r file; do
    grep -vE '^[[:space:]]*#' "$file" | grep -qE -- "$GRANT_READ" && printf '%s\n' "$file"
  done)
}

check() { # root -> 0 when every grant reader is listed
  local root=$1 file bad=0
  while IFS= read -r file; do
    awk -F '\t' -v f="$file" '$1 == f { found = 1 } END { exit !found }' <<<"$ALLOWED" ||
      { printf 'reads a grant unlisted: %s\n' "$file"; bad=1; }
  done < <(readers "$root")
  return "$bad"
}

listed_still_read() { # every allowlist entry still reads a grant, so no stale exemption outlives its reader
  local file
  while IFS=$'\t' read -r file _; do
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

printf 'PASS: %s asserts; no program in bin/ or share/ reads a grant of his words bar the listed readers\n' "$asserts"
