#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u
# The texts every launched brief carries (share/worker-run-texts.sh), checked without launching anything. The
# suites that launch read them back out of brief.launch by their opening words and by line position
# (test_worker_run_rounds, _files, _websearch), so an edit of a text keeps those shapes or fails here, in
# seconds, rather than in a run of every worker-run suite (Egor 2026-10-28).

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL(line %s): %s\n' "${BASH_LINENO[1]-${BASH_LINENO[0]-?}}" "$*" >&2; exit 1; }
a() { asserts=$((asserts + 1)); }
eq() { a; [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
starts() { a; [ "${1:0:${#2}}" = "$2" ] || fail "expected [${1:0:80}] to start with [$2]"; }
lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

SCRIPT_DIRECTORY="$ROOT/bin"
. "$ROOT/share/worker-run-texts.sh" || fail 'share/worker-run-texts.sh does not source'
guard=$(md_guard_text) || fail 'md_guard_text failed'

# One line each, opening with the words the launching suites look for: rounds counts lines down to AUDIENCE,
# files and rounds find the guard by its opening, websearch finds the fences by theirs.
eq "$(lines "$guard")" 1
starts "$guard" 'MD-GUARD (worker-run-injected): '
starts "$BRIEF_PREAMBLE" 'AUDIENCE: '
eq "$(lines "$CLAUDEB_EDIT_FENCE")" 1
starts "$CLAUDEB_EDIT_FENCE" 'EDITS: change repository files only through the Edit and Write tools'
eq "$(lines "$GROK_RESEARCH_FENCE")" 1
starts "$GROK_RESEARCH_FENCE" 'READ-ONLY TREE'
# A Computer Use run ends on one of the two outcomes worker-run reads back.
eq "$(printf '%s\n' "$COMPUTER_PREAMBLE" | tail -n1)" \
  '- Return the evidence the brief asks for and end with: `OUTCOME: COMPUTER_OK` or `OUTCOME: COMPUTER_UNAVAILABLE reason=<text>`'
a; [[ "$CLAUDEB_DENIED_TOOLS" =~ ^[A-Za-z]+(,[A-Za-z]+)*$ ]] || fail "CLAUDEB_DENIED_TOOLS is no comma list: $CLAUDEB_DENIED_TOOLS"

# The worker reads them, so they are English: worker-run refuses a Russian brief, and its own texts may not
# carry what it refuses (the Computer Use rule quotes two Cyrillic letters, under the same bar).
max=$("$ROOT/bin/cyrillic-share" --max)
for text in "$guard" "$BRIEF_PREAMBLE" "$CLAUDEB_EDIT_FENCE" "$GROK_RESEARCH_FENCE" "$COMPUTER_PREAMBLE"; do
  share=$(printf '%s' "$text" | "$ROOT/bin/cyrillic-share" | cut -d' ' -f1)
  a; [ "$share" -le "$max" ] || fail "${text:0:60}: cyrillic $share% over worker-run's $max%"
done

# Defined once, here: a second definition in bin/worker-run or another module would win or lose by source order.
for name in BRIEF_PREAMBLE COMPUTER_PREAMBLE CLAUDEB_DENIED_TOOLS CLAUDEB_EDIT_FENCE GROK_RESEARCH_FENCE 'md_guard_text()'; do
  eq "$(cat "$ROOT/bin/worker-run" "$ROOT/share/"worker-run-*.sh | grep -c "^$name")" 1
done

echo "PASS: $asserts asserts; the guard and the fences one line each with the openings the launching suites read, the preamble opening with AUDIENCE, the Computer Use outcome line, all English, each defined once"
