#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/gemini-research"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ ! -f "$WORK/stdout" ] || sed -n '1,80p' "$WORK/stdout" >&2
  [ ! -f "$WORK/stderr" ] || sed -n '1,80p' "$WORK/stderr" >&2
  exit 1
}
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_not_grep() { asserts=$((asserts + 1)); ! grep -q "$1" "$2" || fail "assert $asserts found $1 in $2"; }

HOME_FIXTURE="$WORK/home"
BIN="$WORK/bin"
REPO="$WORK/repo"
mkdir -p "$HOME_FIXTURE/.gemini-profiles/researcher" "$HOME_FIXTURE/.gemini-profiles/explicit" \
  "$BIN" "$REPO/subdir" "$REPO/.research-cache"
printf 'original\n' >"$REPO/tracked.txt"
printf '.research-cache/\n' >"$REPO/.gitignore"
printf 'ignored-before\n' >"$REPO/.research-cache/ignored.txt"
git -C "$REPO" init -q
git -C "$REPO" add tracked.txt .gitignore
git -C "$REPO" -c user.name=Fixture -c user.email=fixture@example.test commit -qm fixture
REPO_REAL=$(cd "$REPO" && pwd -P)
printf 'Research this repository.\n' >"$WORK/prompt"

cat >"$BIN/worker-pick" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_PICK_LOG:?}"
if [ "${FAKE_PICK_MODE:-}" = rotate-exhaust ]; then
  case " $* " in
    *' --exclude researcher '*)
      printf 'worker-pick: every gemini account is out of the worker pool (excluded)\n' >&2
      exit 3
      ;;
    *) printf 'researcher\n' ;;
  esac
  exit 0
fi
if [ "${FAKE_PICK_MODE:-}" = rotate ]; then
  case " $* " in
    *' --exclude researcher '*) printf 'explicit\n' ;;
    *) printf 'researcher\n' ;;
  esac
  exit 0
fi
if [ "${FAKE_PICK_RC:-0}" -ne 0 ]; then
  printf '%s\n' "${FAKE_PICK_ERROR:-worker-pick: no selectable gemini account}" >&2
  exit "$FAKE_PICK_RC"
fi
printf '%s\n' "${FAKE_PICK_ACCOUNT:-researcher}"
EOF
cat >"$BIN/geminib" <<'EOF'
#!/usr/bin/env bash
account=$2
log=''
printf 'CWD=%s\n' "$PWD" >>"${FAKE_GEMINI_LOG:?}"
printf 'ACCOUNT=%s\n' "$account" >>"$FAKE_GEMINI_LOG"
printf 'ARG=%s\n' "$@" >>"$FAKE_GEMINI_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --log-file ]; then log=$2; shift 2; else shift; fi
done
[ -z "${FAKE_GEMINI_EDIT:-}" ] || printf '%s\n' "${FAKE_GEMINI_EDIT_VALUE:-mutated}" >"$FAKE_GEMINI_EDIT"
case "${FAKE_GEMINI_MODE:-answer}" in
  quota)
    printf 'RESOURCE_EXHAUSTED: rateLimiter HTTP 429\n' >"$log"
    exit "${FAKE_GEMINI_RC:-0}"
    ;;
  timestamp)
    printf '2026-09-04T19:30:04.429Z ordinary failure\n' >"$log"
    printf 'geminib fixture failure\n' >&2
    exit 7
    ;;
  rotate)
    if [ "$account" = researcher ]; then
      printf 'RESOURCE_EXHAUSTED: usage limit reached\n' >"$log"
      exit 0
    fi
    ;;
esac
if [ "${FAKE_GEMINI_RC:-0}" -ne 0 ]; then
  printf '%s\n' "${FAKE_GEMINI_ERROR:-geminib fixture failure}" >&2
  exit "$FAKE_GEMINI_RC"
fi
printf 'researched answer\n'
EOF
chmod +x "$BIN/worker-pick" "$BIN/geminib"

RESEARCH_RUNS="$WORK/research-runs"
WORKER_RUNS="$WORK/worker-runs"
run_research() {
  rc=0
  : >"$WORK/stdout"
  : >"$WORK/stderr"
  env HOME="$HOME_FIXTURE" PATH="$BIN:/usr/bin:/bin" FAKE_PICK_LOG="$WORK/pick.log" \
    FAKE_GEMINI_LOG="$WORK/gemini.log" RESEARCH_RUN_DIR="$RESEARCH_RUNS" \
    WORKER_RUN_DIR="$WORKER_RUNS" CLAUDE_CODE_SESSION_ID= \
    "$@" >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
}

: >"$WORK/pick.log"
: >"$WORK/gemini.log"
before=$(git -C "$REPO" status --porcelain)
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer" --repo "$REPO"
assert test "$rc" -eq 0
assert test "$(<"$WORK/answer")" = 'researched answer'
assert test "$(git -C "$REPO" status --porcelain)" = "$before"
assert test "$(sed -n '1p' "$WORK/stdout")" = 'ACCOUNT: researcher (gemini)'
assert grep -q '^ANSWER: .*/answer$' "$WORK/stdout"
assert grep -q '^LOG: .*researcher\.log$' "$WORK/stdout"
assert grep -q '^ELAPSED: [0-9][0-9]*$' "$WORK/stdout"
assert grep -q '^--account gemini --role research --claim$' "$WORK/pick.log"
assert grep -q '^ARG=gemini-3.8-flash-high$' "$WORK/gemini.log"
assert grep -q '^ARG=--add-dir$' "$WORK/gemini.log"
assert grep -q "^ARG=$REPO_REAL$" "$WORK/gemini.log"
assert grep -q '^ARG=--print-timeout$' "$WORK/gemini.log"
assert grep -q '^ARG=40m$' "$WORK/gemini.log"
assert test "$(grep -c "^CWD=$REPO_REAL$" "$WORK/gemini.log")" -eq 0

: >"$WORK/gemini.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-dedupe" \
  --repo "$REPO/subdir" --repo "$REPO"
assert test "$rc" -eq 0
assert test "$(grep -c '^ARG=--add-dir$' "$WORK/gemini.log")" -eq 1
assert grep -q "^ARG=$REPO_REAL$" "$WORK/gemini.log"

run_research env FAKE_GEMINI_EDIT="$REPO/tracked.txt" "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-subdir" --repo "$REPO/subdir" --account researcher
assert test "$rc" -eq 5
assert grep -q '^READ-ONLY VIOLATION:' "$WORK/stdout"
assert grep -q "$REPO_REAL/tracked.txt" "$WORK/stdout"
assert test "$(<"$REPO/tracked.txt")" = mutated
printf 'original\n' >"$REPO/tracked.txt"

: >"$WORK/gemini.log"
mkdir "$WORK/not-repo"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-not-repo" --repo "$WORK/not-repo"
assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert grep -q 'not a git repository' "$WORK/stdout"
assert test ! -s "$WORK/gemini.log"

picker_cases=(
  '3|worker-pick: no selectable gemini account (100% main f38·high WALLED)|3|GEMINI_USAGE_LIMIT'
  '3|worker-pick: gemini is switched off for research|4|GEMINI_UNAVAILABLE'
  '3|worker-pick: every gemini account is out of the worker pool (pool empty)|4|GEMINI_UNAVAILABLE'
  '3|worker-pick: gemini is paused (gemini_paused=on in ~/.claude/worker-model)|4|GEMINI_UNAVAILABLE'
)
for picker_case in "${picker_cases[@]}"; do
  IFS='|' read -r picker_rc picker_error expected_rc expected_outcome <<<"$picker_case"
  run_research env FAKE_PICK_RC="$picker_rc" FAKE_PICK_ERROR="$picker_error" "$SCRIPT" \
    --prompt-file "$WORK/prompt" --out "$WORK/answer-picker" --repo "$REPO"
  assert test "$rc" -eq "$expected_rc"
  assert grep -q "^OUTCOME: $expected_outcome$" "$WORK/stdout"
  assert grep -Fqx "$picker_error" "$WORK/stdout"
done

run_research env FAKE_GEMINI_MODE=quota "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-silent-quota" --repo "$REPO" --account explicit
assert test "$rc" -eq 3
assert grep -q '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/stdout"
assert grep -q 'RESOURCE_EXHAUSTED' "$WORK/stdout"

run_research env FAKE_GEMINI_MODE=timestamp "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-timestamp" --repo "$REPO" --account explicit
assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert_not_grep '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/stdout"

: >"$WORK/pick.log"
: >"$WORK/gemini.log"
run_research env FAKE_PICK_MODE=rotate FAKE_GEMINI_MODE=rotate "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-rotate" --repo "$REPO"
assert test "$rc" -eq 0
assert test "$(<"$WORK/answer-rotate")" = 'researched answer'
assert grep -q '^ACCOUNT: explicit (gemini)$' "$WORK/stdout"
assert grep -q '^--account gemini --role research --exclude researcher --claim$' "$WORK/pick.log"
assert test "$(grep -c '^ACCOUNT=' "$WORK/gemini.log")" -eq 2

run_research env FAKE_PICK_MODE=rotate-exhaust FAKE_GEMINI_MODE=quota "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-pool-wall" --repo "$REPO"
assert test "$rc" -eq 3
assert grep -q '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/stdout"
assert grep -q 'out of the worker pool' "$WORK/stdout"

: >"$WORK/pick.log"
: >"$WORK/gemini.log"
run_research env FAKE_GEMINI_MODE=quota "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-explicit-quota" --repo "$REPO" --account explicit
assert test "$rc" -eq 3
assert test ! -s "$WORK/pick.log"
assert test "$(grep -c '^ACCOUNT=' "$WORK/gemini.log")" -eq 1

UNBORN="$WORK/unborn"
mkdir "$UNBORN"
git -C "$UNBORN" init -q
printf 'uncommitted\n' >"$UNBORN/only.txt"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-unborn" \
  --repo "$UNBORN" --account explicit
assert test "$rc" -eq 0
assert test "$(<"$WORK/answer-unborn")" = 'researched answer'
assert test "$(<"$UNBORN/only.txt")" = uncommitted

run_research env FAKE_GEMINI_EDIT="$REPO/tracked.txt" FAKE_GEMINI_RC=7 \
  FAKE_GEMINI_ERROR='geminib: account needs login' "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-error-edit" --repo "$REPO" --account explicit
assert test "$rc" -eq 5
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert grep -q '^READ-ONLY VIOLATION:' "$WORK/stdout"
outcome_line=$(grep -n '^OUTCOME:' "$WORK/stdout" | cut -d: -f1)
violation_line=$(grep -n '^READ-ONLY VIOLATION:' "$WORK/stdout" | cut -d: -f1)
assert test "$outcome_line" -lt "$violation_line"
printf 'original\n' >"$REPO/tracked.txt"

run_research env FAKE_GEMINI_EDIT="$REPO/.research-cache/ignored.txt" "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-ignored" --repo "$REPO" --account explicit
assert test "$rc" -eq 5
assert grep -q '^READ-ONLY VIOLATION:' "$WORK/stdout"
assert grep -q "$REPO_REAL/.research-cache/ignored.txt" "$WORK/stdout"

: >"$WORK/gemini.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$REPO/research-answer" \
  --repo "$REPO" --account explicit
assert test "$rc" -eq 2
assert grep -q '^usage: gemini-research ' "$WORK/stderr"
assert test ! -s "$WORK/gemini.log"

SUBSOURCE="$WORK/sub-source"
SUBPARENT="$WORK/sub-parent"
mkdir "$SUBSOURCE" "$SUBPARENT"
git -C "$SUBSOURCE" init -q
printf 'module-before\n' >"$SUBSOURCE/module.txt"
git -C "$SUBSOURCE" add module.txt
git -C "$SUBSOURCE" -c user.name=Fixture -c user.email=fixture@example.test commit -qm module
git -C "$SUBPARENT" init -q
printf 'parent\n' >"$SUBPARENT/parent.txt"
git -C "$SUBPARENT" add parent.txt
git -C "$SUBPARENT" -c user.name=Fixture -c user.email=fixture@example.test commit -qm parent
git -C "$SUBPARENT" -c protocol.file.allow=always submodule add -q "$SUBSOURCE" module
git -C "$SUBPARENT" -c user.name=Fixture -c user.email=fixture@example.test commit -qam submodule
printf 'dirty-before\n' >"$SUBPARENT/module/module.txt"
submodule_status_before=$(git -C "$SUBPARENT" status --porcelain)
run_research env FAKE_GEMINI_EDIT="$SUBPARENT/module/module.txt" FAKE_GEMINI_EDIT_VALUE=dirty-after \
  "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-submodule" \
  --repo "$SUBPARENT" --account explicit
assert test "$rc" -eq 5
assert test "$(git -C "$SUBPARENT" status --porcelain)" = "$submodule_status_before"
assert grep -q '/module$' "$WORK/stdout"
assert test "$(<"$SUBPARENT/module/module.txt")" = dirty-after

: >"$WORK/pick.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-explicit" \
  --repo "$REPO" --account explicit
assert test "$rc" -eq 0
assert test ! -s "$WORK/pick.log"

: >"$WORK/gemini.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-unknown" \
  --repo "$REPO" --account unknown
assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert grep -q '^gemini-research: unknown account: unknown$' "$WORK/stdout"
assert test ! -s "$WORK/gemini.log"

MISSING_BIN="$WORK/missing-bin"
mkdir -p "$MISSING_BIN"
cp "$BIN/worker-pick" "$MISSING_BIN/worker-pick"
rc=0
env HOME="$HOME_FIXTURE" PATH="$MISSING_BIN:/usr/bin:/bin" FAKE_PICK_LOG="$WORK/pick.log" \
  "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-missing" --repo "$REPO" \
  --account explicit >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert grep -q 'geminib is missing' "$WORK/stdout"

run_research env CLAUDE_CODE_SESSION_ID=chat-research "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-no-record" --repo "$REPO" --account explicit
assert test "$rc" -eq 0
assert test ! -e "$RESEARCH_RUNS"
assert test ! -e "$WORKER_RUNS"
assert_not_grep '^RUN: ' "$WORK/stdout"

printf 'PASS: %s assertions; normalized and deduplicated repositories, silent-log quota detection, account rotation, unborn HEAD, classified violations, ignored files, output refusal, dirty submodules, picker refusal semantics, explicit-account bypass, unavailable Gemini, and absence of liveness records\n' "$asserts"
