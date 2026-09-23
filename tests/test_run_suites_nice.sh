#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*"; exit 1; }; }

mkdir -p "$WORK/repo/tests"
for name in a b; do
  printf '#!/usr/bin/env bash\necho "PASS: nice=$(ps -o nice= -p $$ | tr -d " ")"\n' >"$WORK/repo/tests/test_$name.sh"
done

# Every suite runs below interactive priority, in parallel as before.
out=$(bash "$ROOT/share/run-suites.sh" --repo "$WORK/repo" 2>&1)
assert test "$(grep -c 'PASS: nice=10' <<<"$out")" = 2
assert grep -q '2 PASS' <<<"$out"

printf 'PASS: %s asserts; run-suites runs every suite at nice 10, in parallel\n' "$asserts"
