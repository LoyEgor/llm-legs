#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/light_research_harness.sh" || exit 1

# G6: a question over two repositories is one run with --add-dir on every vendor, grok included
# since 1.0.70 took the flag; the per-repository grok fan-out it replaced is gone.
REPO2="$WORK/repo2"; mkdir -p "$REPO2"
git -C "$REPO2" init -q; printf 'y\n' >"$REPO2/file"; git -C "$REPO2" add file
git -C "$REPO2" -c user.name=x -c user.email=x@y commit -qm init
repo_path=$(cd "$REPO" && pwd -P); repo2_path=$(cd "$REPO2" && pwd -P)
printf 'Research the repository.\n' >"$WORK/prompt"
: >"$WORK/gemini.log"
run --repo "$REPO2"; rc=$?; assert test "$rc" -eq 0
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 1
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e --arg d "$repo2_path" '.add_dirs == [$d]' "$RUNS/$run_id/meta.json"
assert test "$(grep -c '^## ' "$WORK/answer")" = 0
printf 'light_research=grok\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run --repo "$REPO2"; rc=$?; assert test "$rc" -eq 0
assert test "$(grep -c . "$WORK/vendor.log")" = 1
assert grep -qF -- "--add-dir $repo2_path" "$WORK/vendor.log"
assert test "$(grep -c '^RUN: ' "$WORK/out")" = 1
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e --arg d "$repo2_path" '.add_dirs == [$d]' "$RUNS/$run_id/meta.json"
assert test "$(jq -r '.workdir' "$RUNS/$run_id/meta.json")" = "$repo_path"
assert test "$(grep -c '^REPOSITORY:' "$RUNS/$run_id/brief.launch")" = 0
assert test "$(grep -c '^## ' "$WORK/answer")" = 0
assert test "$(grep -c 'grok research answer' "$WORK/answer")" = 1

# The run launches in the state the prompt asked for, and its citation is checked against both
# repositories. The grok stub answers alike with or without web, so it carries the WEB: off checks.
printf 'WEB: off\nResearch the repository.\n' >"$WORK/prompt"
: >"$WORK/vendor.log"
printf 'repo two only\n' >"$REPO2/unit-only.txt"
FAKE_GROK_CITATION='unit-only.txt:1 | "repo two only" | claim' run --repo "$REPO2"; rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c -- '--disable-web-search' "$WORK/vendor.log")" = 1
assert grep -qx 'WEB: off' "$WORK/out"
assert test "$(grep -cx 'WEB: on' "$WORK/out")" = 0
off_run=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert test "$(jq -r '.web_search' "$RUNS/$off_run/meta.json")" = false
assert test "$(grep -ci '^web *:' "$RUNS/$off_run/brief.launch")" = 0
assert grep -qx 'Research the repository.' "$RUNS/$off_run/brief.launch"
assert test "$(head -n1 "$WORK/answer")" = 'CITATIONS: 1/1'
printf 'Research the repository.\n' >"$WORK/prompt"
rm -f "$TOGGLE"

# A relative citation path is resolved against EVERY repository of the call: the same name in two
# checkouts made the first one the only file the quote was ever looked for in.
printf 'first copy\nsecond line\n' >"$REPO/shared.txt"
printf 'only in the second repository\n' >"$REPO2/shared.txt"
printf 'shared.txt:1 | "only in the second repository" | the second checkout holds it\n' >"$WORK/shared-answer"
printf 'ANSWER-FILE: %s\nResearch both repositories.\n' "$WORK/shared-answer" >"$WORK/prompt"
rm -f "$WORK/answer"
run --repo "$REPO2"; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 1/1'
rm -f "$REPO/shared.txt" "$REPO2/shared.txt"
printf 'Research the repository.\n' >"$WORK/prompt"

printf 'other repository quote\n' >"$REPO2/cross-only.txt"
printf 'cross-only.txt:1 | "other repository quote" | cross claim\n' >"$WORK/cross-answer"
. "$ROOT/share/light-research.sh"
assert test "$(research_citation_check "$WORK/cross-answer" "$WORK/cross-checked" "$REPO")" = '0 1 0'
assert test "$(research_citation_check "$WORK/cross-answer" "$WORK/cross-checked" "$REPO2")" = '1 1 0'
printf '%s:1 | "other repository quote" | outside claim\n' "$REPO2/cross-only.txt" >"$WORK/cross-answer"
assert test "$(research_citation_check "$WORK/cross-answer" "$WORK/cross-checked" "$REPO")" = '0 1 0'
ln -s "$REPO2/cross-only.txt" "$REPO/cross-link"
printf 'cross-link:1 | "other repository quote" | symlink claim\n' >"$WORK/cross-answer"
assert test "$(research_citation_check "$WORK/cross-answer" "$WORK/cross-checked" "$REPO")" = '0 1 0'

printf 'PASS: %s asserts; one --add-dir run over two repositories on gemini and grok alike, and a citation resolved against every repository\n' "$asserts"
