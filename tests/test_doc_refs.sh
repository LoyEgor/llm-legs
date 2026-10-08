#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat >"$WORK/fixture.md" <<'MD'
`bin/no-such-tool` and `share/worker-pick` and `docs/<topic>.md`, `tests/test_*.sh`, `tests/x.sh`,
`~/.claude/docs/no-such-doc.md`, `bin/worker-pick:12`, `gone-helper.py`, `share/doc_refs.py`.
```
bin/inside-a-fence
```
MD
out=$(python3 "$ROOT/share/doc_refs.py" --repo "$ROOT" "$WORK/fixture.md" </dev/null)
[ "$(printf '%s\n' "$out" | grep -o '`[^`]*`' | tr '\n' ' ')" = \
  '`bin/no-such-tool` `share/worker-pick` `~/.claude/docs/no-such-doc.md` `gone-helper.py` ' ] ||
  fail "fixture flags: $out"
asserts=$((asserts + 1))

files=$(cd "$ROOT" && { find docs -name '*.md' -not -path 'docs/handoffs/*'; ls CLAUDE.md share/*.md; })
out=$(cd "$ROOT" && python3 share/doc_refs.py --repo . $files <<'ALLOW'
docs/image-vendors.md likeness.py untracked
docs/harness-doctor-design.md test_worker_run.sh history
docs/harness-doctor-design.md hooks/folded runtime
docs/harness-doctor-design.md bin/test-history removed
docs/harness-doctor-design.md throttle.py untracked
docs/statusline-contract.md ~/.claude/statusline-cache-ttl ignored
docs/vendor-release.md skills/.system codex
docs/DIAGNOSTICS.md skills/.system codex
ALLOW
) || fail "dead references in md (update, delete, or allowlist with a one-word reason):
$out"
asserts=$((asserts + 1))

printf 'PASS: %s asserts; every backticked path in docs/, CLAUDE.md and share/*.md resolves\n' "$asserts"
