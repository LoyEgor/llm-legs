#!/usr/bin/env bash
# Every block Egor reads is drawn by share/report_frame.py alone. Fails on a frame drawn, a frame
# constant defined or the module copied anywhere else in llm-legs, review-bench or claude-setup,
# and on a known producer that stopped reaching the module. Text posted to report-bus is refused at
# runtime (tests/test_report_bus.sh); this closes the path around the bus.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REVIEW_BENCH=${REVIEW_BENCH_ROOT:-$ROOT/../review-bench}
CLAUDE_SETUP=${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || { printf 'FAIL: assert %s: %s\n' "$asserts" "$*" >&2; exit 1; }; }
for repo in "$REVIEW_BENCH" "$CLAUDE_SETUP"; do
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] ||
    { printf 'FAIL: %s is not a checkout (set REVIEW_BENCH_ROOT / CLAUDE_SETUP_ROOT)\n' "$repo" >&2; exit 1; }
done

DRAWING="['\"]=['\"] *\\*|\\* *['\"]=['\"]|={10,}|tr ' ' '='|tr \" \" \"=\"|=%\\.0s|// /=\\}"
CONSTANT='(^|[^.A-Za-z_])(FRAME_WIDTH|REPORT_WIDTH[A-Z_]*|REPORT_FRAME_WIDTH|REPORT_LABEL_WIDTH|LABEL_WIDTH|REPORT_END)\b'
# A table the model reads is not a chat block; base64 padding is not a rule.
ALLOWED='^llm-legs:bin/worker-corpus:[0-9]+:    print\("=" \* 80\)$|% 4\)'

sources() {
  git -C "$1" ls-files --cached --others --exclude-standard |
    grep -vE '^(tests|docs)/|(^|/)fixtures/|\.(md|json|jsonl|txt|plist)$|^share/report_frame\.py$'
}
hits=''
for pair in "llm-legs:$ROOT" "review-bench:$REVIEW_BENCH" "claude-setup:$CLAUDE_SETUP"; do
  name=${pair%%:*} repo=${pair#*:}
  found=$(cd "$repo" && sources "$repo" | while IFS= read -r file; do
    [ -f "$file" ] && grep -nE -e "$DRAWING" -e "$CONSTANT" "$file" /dev/null
  done | sed "s|^|$name:|" | grep -vE "$ALLOWED")
  hits+=${found:+$found$'\n'}
  copies=$(cd "$repo" && sources "$repo" | grep -E '(^|/)report_frame\.py$')
  hits+=${copies:+$name: a copy of the module: $copies$'\n'}
done
[ -z "$hits" ] || printf 'a frame drawn outside share/report_frame.py:\n%s' "$hits" >&2
assert test -z "$hits"

assert grep -Fq 'share/report_frame.py}' "$ROOT/bin/report-bus"
assert grep -Fq 'python3 "$FRAME" block' "$ROOT/bin/report-bus"
assert grep -Fq 'import report_frame as _frame' "$REVIEW_BENCH/share/rbench/report.py"
assert grep -Fq 'import report_frame as _frame' "$REVIEW_BENCH/share/rbench/panel.py"
assert grep -Fq 'input=json.dumps(document, ensure_ascii=False)' "$REVIEW_BENCH/share/rbench/report.py"
assert grep -Fq '/report_frame.py" block' "$CLAUDE_SETUP/hooks/lib/report-emit.sh"
assert grep -Fq 'rb_emit --kind "${BLOCK_KIND[$i]}"' "$CLAUDE_SETUP/hooks/commit-report.sh"

# The scan above must see a drawn frame, or its silence proves nothing.
probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
git -C "$probe" init -q
printf 'print("=" * 56)\n' >"$probe/a.py"
printf 'printf "%%s\\n" "========== commit =========="\n' >"$probe/b.sh"
printf 'LABEL_WIDTH=14\n' >"$probe/c.sh"
printf 'x = _frame.LABEL_WIDTH\n' >"$probe/d.py"
seen=$(cd "$probe" && sources "$probe" | while IFS= read -r file; do
  grep -lE -e "$DRAWING" -e "$CONSTANT" "$file"
done | sort | tr '\n' ' ')
assert test "$seen" = "a.py b.sh c.sh "

printf 'PASS: %s asserts; one report renderer across llm-legs, review-bench and claude-setup\n' "$asserts"
