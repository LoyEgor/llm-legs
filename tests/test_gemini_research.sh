#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/gemini-research"
WORK="$(mktemp -d "$HOME/.gemini-research-test.XXXXXX")"
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
mkdir -p "$HOME_FIXTURE/.gemini-profiles/researcher" \
  "$BIN" "$REPO/subdir" "$REPO/.research-cache" "$WORK/tmp" "$HOME_FIXTURE/.gemini" "$HOME_FIXTURE/.claude"
PROFILE_REAL="$WORK/profile \"quoted\""
mkdir -p "$PROFILE_REAL"
ln -s "$PROFILE_REAL" "$HOME_FIXTURE/.gemini-profiles/explicit"
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
if [ "${FAKE_GEMINI_MODE:-}" = peer ]; then
  touch "$TMPDIR/ready"
  for ((i=0; i<200; i++)); do
    [ ! -e "$TMPDIR/release" ] || break
    sleep 0.05
  done
  [ -e "$TMPDIR/release" ] || exit 8
fi
case "${FAKE_GEMINI_MODE:-answer}" in
  housekeeping)
    printf 'profile-ok\n' >"$HOME/.gemini-profiles/$account/housekeeping" || exit 9
    printf 'temp-ok\n' >"$TMPDIR/housekeeping" || exit 9
    printf 'base-ok\n' >"$HOME/.gemini/housekeeping" || exit 9
    ;;
  conversation)
    printf 'Operation not permitted: sandbox deny discussed in research\n' >"$log"
    printf 'Operation not permitted\n'
    ;;
  denial-log)
    printf 'Sandbox: agy(123) deny(1) file-write-create %s\n' "$FAKE_DENIED_PATH" >&2
    ;;
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
    FAKE_GEMINI_LOG="$WORK/tmp/gemini.log" TMPDIR="$WORK/tmp" \
    GEMINIB_PROFILES_DIR="$HOME_FIXTURE/.gemini-profiles" WORKER_RUN_IDLE_S=0 RESEARCH_RUN_DIR="$RESEARCH_RUNS" \
    WORKER_RUN_DIR="$WORKER_RUNS" CLAUDE_CODE_SESSION_ID= \
    "$@" >"$WORK/stdout" 2>"$WORK/stderr" || rc=$?
}

: >"$WORK/pick.log"
: >"$WORK/tmp/gemini.log"
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
assert grep -q '^ARG=gemini-3.8-flash-high$' "$WORK/tmp/gemini.log"
assert grep -q '^ARG=--add-dir$' "$WORK/tmp/gemini.log"
assert grep -q "^ARG=$REPO_REAL$" "$WORK/tmp/gemini.log"
assert grep -q '^ARG=--print-timeout$' "$WORK/tmp/gemini.log"
assert grep -q '^ARG=40m$' "$WORK/tmp/gemini.log"
assert test "$(grep -c "^CWD=$REPO_REAL$" "$WORK/tmp/gemini.log")" -eq 0

: >"$WORK/tmp/gemini.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-dedupe" \
  --repo "$REPO/subdir" --repo "$REPO"
assert test "$rc" -eq 0
assert test "$(grep -c '^ARG=--add-dir$' "$WORK/tmp/gemini.log")" -eq 1
assert grep -q "^ARG=$REPO_REAL$" "$WORK/tmp/gemini.log"

run_research env FAKE_GEMINI_EDIT="$REPO/new.txt" "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-new" --repo "$REPO" --account explicit
assert test ! -e "$REPO/new.txt"
assert test "$rc" -eq 5
assert grep -q '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
assert test "$(<"$WORK/answer-new")" = 'researched answer'

run_research env FAKE_GEMINI_EDIT="$REPO/tracked.txt" "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-subdir" --repo "$REPO/subdir" --account researcher
assert test "$rc" -eq 5
assert grep -q '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
assert grep -q "$REPO_REAL/tracked.txt" "$WORK/stdout"
assert test "$(<"$REPO/tracked.txt")" = original
assert test "$(<"$WORK/answer-subdir")" = 'researched answer'

: >"$WORK/tmp/gemini.log"
mkdir "$WORK/not-repo"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-not-repo" --repo "$WORK/not-repo"
assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert grep -q 'not a git repository' "$WORK/stdout"
assert test ! -s "$WORK/tmp/gemini.log"

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
: >"$WORK/tmp/gemini.log"
run_research env FAKE_PICK_MODE=rotate FAKE_GEMINI_MODE=rotate "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-rotate" --repo "$REPO"
assert test "$rc" -eq 0
assert test "$(<"$WORK/answer-rotate")" = 'researched answer'
assert grep -q '^ACCOUNT: explicit (gemini)$' "$WORK/stdout"
assert grep -q '^--account gemini --role research --exclude researcher --claim$' "$WORK/pick.log"
assert test "$(grep -c '^ACCOUNT=' "$WORK/tmp/gemini.log")" -eq 2

run_research env FAKE_PICK_MODE=rotate-exhaust FAKE_GEMINI_MODE=quota "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-pool-wall" --repo "$REPO"
assert test "$rc" -eq 3
assert grep -q '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/stdout"
assert grep -q 'out of the worker pool' "$WORK/stdout"

: >"$WORK/pick.log"
: >"$WORK/tmp/gemini.log"
run_research env FAKE_GEMINI_MODE=quota "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-explicit-quota" --repo "$REPO" --account explicit
assert test "$rc" -eq 3
assert test ! -s "$WORK/pick.log"
assert test "$(grep -c '^ACCOUNT=' "$WORK/tmp/gemini.log")" -eq 1

UNBORN="$WORK/unborn"
mkdir "$UNBORN"
git -C "$UNBORN" init -q
printf 'uncommitted\n' >"$UNBORN/only.txt"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-unborn" \
  --repo "$UNBORN" --account explicit
assert test "$rc" -eq 0
assert test "$(<"$WORK/answer-unborn")" = 'researched answer'
assert test "$(<"$UNBORN/only.txt")" = uncommitted

run_research env FAKE_GEMINI_EDIT="$REPO/.research-cache/ignored.txt" "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-ignored" --repo "$REPO" --account explicit
assert test "$rc" -eq 5
assert grep -q '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
assert grep -q "$REPO_REAL/.research-cache/ignored.txt" "$WORK/stdout"

assert test "$(<"$REPO/.research-cache/ignored.txt")" = ignored-before
assert test "$(<"$WORK/answer-ignored")" = 'researched answer'

TEMP_REPO="$WORK/tmp/repo"
mkdir "$TEMP_REPO"
git -C "$TEMP_REPO" init -q
run_research env FAKE_GEMINI_EDIT="$TEMP_REPO/new.txt" "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-temp-repo" --repo "$TEMP_REPO" --account explicit
assert test ! -e "$TEMP_REPO/new.txt"
assert test "$rc" -eq 5
assert grep -q '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
assert test "$(<"$WORK/answer-temp-repo")" = 'researched answer'

for denied in "$HOME_FIXTURE/.claude/new.txt" "$HOME_FIXTURE/.gemini-profiles/researcher/other-account.txt"; do
  run_research env FAKE_GEMINI_EDIT="$denied" "$SCRIPT" --prompt-file "$WORK/prompt" \
    --out "$WORK/answer-denied" --repo "$REPO" --account explicit
  assert test "$rc" -eq 5
  assert grep -q '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
  assert grep -Fq "$denied" "$WORK/stdout"
  assert test ! -e "$denied"
  assert test "$(<"$WORK/answer-denied")" = 'researched answer'
done

run_research env FAKE_GEMINI_MODE=housekeeping "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-housekeeping" --repo "$REPO" --account explicit
assert test "$rc" -eq 0
assert test "$(<"$HOME_FIXTURE/.gemini-profiles/explicit/housekeeping")" = profile-ok
assert test "$(<"$WORK/tmp/housekeeping")" = temp-ok
assert test "$(<"$HOME_FIXTURE/.gemini/housekeeping")" = base-ok
assert_not_grep '^OUTCOME:' "$WORK/stdout"
log=$(sed -n 's/^LOG: //p' "$WORK/stdout")
assert grep -q '^SANDBOX PROFILE:$' "$log"
assert grep -Fq '(deny file-write*)' "$log"
profile_escaped=${PROFILE_REAL//\"/\\\"}
assert grep -Fq "$profile_escaped" "$log"

run_research env FAKE_GEMINI_MODE=denial-log FAKE_DENIED_PATH="$REPO/denied-in-log" "$SCRIPT" \
  --prompt-file "$WORK/prompt" --out "$WORK/answer-log-denial" --repo "$REPO" --account explicit
assert test "$rc" -eq 5
assert grep -q '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
assert grep -Fq "$REPO/denied-in-log" "$WORK/stdout"
assert test "$(<"$WORK/answer-log-denial")" = 'researched answer'

head_before=$(git -C "$REPO" rev-parse HEAD)
(
  run_research env FAKE_GEMINI_MODE=peer "$SCRIPT" --prompt-file "$WORK/prompt" \
    --out "$WORK/answer-peer" --repo "$REPO" --account explicit
  printf '%s\n' "$rc" >"$WORK/peer.rc"
) &
peer_pid=$!
for ((i=0; i<200; i++)); do
  [ ! -e "$WORK/tmp/ready" ] || break
  sleep 0.05
done
assert test -e "$WORK/tmp/ready"
printf 'peer-commit\n' >"$REPO/peer-committed.txt"
git -C "$REPO" add peer-committed.txt
git -C "$REPO" -c user.name=Fixture -c user.email=fixture@example.test commit -qm peer
printf 'peer-edit\n' >"$REPO/tracked.txt"
touch "$WORK/tmp/release"
wait "$peer_pid"
assert test "$(<"$WORK/peer.rc")" -eq 0
assert test "$head_before" != "$(git -C "$REPO" rev-parse HEAD)"
assert test "$(<"$REPO/tracked.txt")" = peer-edit
assert test "$(<"$WORK/answer-peer")" = 'researched answer'
assert_not_grep 'VIOLATION\|^NOTE:\|^OUTCOME:' "$WORK/stdout"

for sandbox in /nonexistent "$BIN/refuse-sandbox"; do
  printf '#!/bin/sh\necho "sandbox-exec: invalid profile" >&2\nexit 65\n' >"$BIN/refuse-sandbox"
  chmod +x "$BIN/refuse-sandbox"
  : >"$WORK/tmp/gemini.log"
  run_research env GEMINI_RESEARCH_SANDBOX_EXEC="$sandbox" "$SCRIPT" --prompt-file "$WORK/prompt" \
    --out "$WORK/answer-no-sandbox" --repo "$REPO" --account explicit
  assert test "$rc" -eq 4
  assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
  assert grep -q 'sandbox-exec' "$WORK/stdout"
  assert test ! -s "$WORK/tmp/gemini.log"
done

: >"$WORK/tmp/gemini.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$REPO/research-answer" \
  --repo "$REPO" --account explicit
assert test "$rc" -eq 2
assert grep -q '^usage: gemini-research ' "$WORK/stderr"
assert test ! -s "$WORK/tmp/gemini.log"

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
assert grep -q '/module/module.txt' "$WORK/stdout"
assert test "$(<"$SUBPARENT/module/module.txt")" = dirty-before

: >"$WORK/pick.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-explicit" \
  --repo "$REPO" --account explicit
assert test "$rc" -eq 0
assert test ! -s "$WORK/pick.log"

: >"$WORK/tmp/gemini.log"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-unknown" \
  --repo "$REPO" --account unknown
assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/stdout"
assert grep -q '^gemini-research: unknown account: unknown$' "$WORK/stdout"
assert test ! -s "$WORK/tmp/gemini.log"

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


run_research env FAKE_GEMINI_MODE=conversation "$SCRIPT" --prompt-file "$WORK/prompt" \
  --out "$WORK/answer-conversation" --repo "$REPO" --account explicit
assert test "$rc" -eq 0
assert_not_grep '^OUTCOME: GEMINI_RESEARCH_WRITE_DENIED$' "$WORK/stdout"
mv "$HOME_FIXTURE/.gemini" "$HOME_FIXTURE/.gemini.saved"
mv "$HOME_FIXTURE/.claude" "$HOME_FIXTURE/.claude.saved"
cat >"$BIN/readlink" <<'READLINK'
#!/bin/sh
[ -e "$2" ] || exit 1
exec /usr/bin/readlink "$@"
READLINK
chmod +x "$BIN/readlink"
run_research "$SCRIPT" --prompt-file "$WORK/prompt" --out "$WORK/answer-missing-home" \
  --repo "$REPO" --account explicit
assert test "$rc" -eq 0

printf 'PASS: %s assertions; OS write denial with intact answers, allowed housekeeping, peer commit and edit, sandbox unavailable/refused, repository normalization, quota rotation, unborn HEAD, ignored files, output refusal, dirty submodules, picker semantics, explicit accounts, no liveness records\n' "$asserts"
