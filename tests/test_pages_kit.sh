#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/pages/kit in headless Chromium over an in-memory mock of the CONTRACT.md routes
# (tests/pages-kit/run.mjs): compare votes, loupes, outbox, freshness, view and blind pages, cards.
# Skipped without node or an installed playwright-core whose Chromium is in the Playwright cache.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "SKIP: pages kit — no node"; exit 0; }
main=$(cd "$(git -C "$ROOT" rev-parse --git-common-dir)/.." 2>/dev/null && pwd) || main=$ROOT
cands=()
[ -n "${PAGES_KIT_PLAYWRIGHT:-}" ] && cands+=("$PAGES_KIT_PLAYWRIGHT")
for d in "$(npm root -g 2>/dev/null)"/playwright-core "$HOME"/.npm/_npx/*/node_modules/playwright-core \
  "$(dirname "$main")"/*/node_modules/playwright-core; do
  [ -f "$d/package.json" ] && cands+=("$d")
done
[ "${#cands[@]}" -gt 0 ] || { echo "SKIP: pages kit — no playwright-core installed (set PAGES_KIT_PLAYWRIGHT)"; exit 0; }

out=$(cd "$ROOT" && node tests/pages-kit/run.mjs "${cands[@]}" 2>&1)
rc=$?
case $rc in
  0) printf '%s\n' "$out" | tail -1 ;;
  3) printf '%s\n' "$out" | grep '^SKIP' ; exit 0 ;;
  *) printf '%s\n' "$out" >&2; fail "pages kit browser checks (exit $rc)" ;;
esac
