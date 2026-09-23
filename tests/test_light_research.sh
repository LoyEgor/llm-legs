#!/usr/bin/env bash
set -u
unset WORKER_PICK_CONFIG_FILE WORKER_RUN_CONFIG_FILE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# Every `worker_model_*` call shells `grokb models`: the fixture list answers it, and the
# `grok` CLI behind it can never be reached (row `cu`).
export GROKB_CACHE_DIR="$WORK/grokb-cache"
. "$ROOT/tests/fixtures/grokb-models.sh"
. "$ROOT/tests/fixtures/codexb-models.sh"
fail(){ echo "FAIL: $*" >&2; [ ! -f "$WORK/out" ] || cat "$WORK/out" >&2; [ ! -f "$WORK/err" ] || cat "$WORK/err" >&2; exit 1; }
asserts=0
assert(){ asserts=$((asserts + 1)); "$@" || fail "$*"; }
HOME="$WORK/home"; BIN="$WORK/bin"; REPO="$WORK/repo"; RUNS="$WORK/runs"
mkdir -p "$HOME/.gemini-profiles/researcher" "$HOME/.gemini" "$HOME/.claude" "$BIN" "$REPO" "$RUNS"
git -C "$REPO" init -q; printf 'x\n' >"$REPO/file"; git -C "$REPO" add file; git -C "$REPO" -c user.name=x -c user.email=x@y commit -qm init
TOGGLE="$HOME/.claude/worker-model"

# The toggle rows: absent means the gemini default, a vendor alone means its default model, and a
# light-only model is valid on a light row without reaching the worker table.
toggle(){ WORKER_PICK_CONFIG_FILE="$TOGGLE" bash -c '. "$1/share/worker-model.sh"; shift; "$@"' _ "$ROOT" "$@"; }
assert test "$(toggle worker_light_vendor research)" = gemini
assert test "$(toggle worker_light_model edit)" = "$(toggle worker_model_default_model gemini)"
assert test "$(toggle worker_light_effort research)" = high
printf 'worker=auto\nlight_research=claudeb:sonnet\nlight_edit=codex\n' >"$TOGGLE"
assert test "$(toggle worker_light_vendor research) $(toggle worker_light_model research) $(toggle worker_light_effort research)" = 'claudeb sonnet medium'
assert test "$(toggle worker_light_vendor edit) $(toggle worker_light_model edit)" = 'codex astra'
assert test "$(toggle eval 'worker_model_allows claudeb sonnet; echo $?')" = 1
printf 'light_research=mistral\nlight_edit=grok:opus\n' >"$TOGGLE"
assert test "$(toggle eval 'worker_light_vendor research 2>/dev/null; echo $?')" = 2
assert test "$(toggle eval 'worker_light_model edit 2>/dev/null; echo $?')" = 2
rm -f "$TOGGLE"

cat >"$BIN/worker-pick" <<'PICK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PICK_LOG"
if [ -s "${PICK_QUEUE:-/dev/null}" ]; then
  head -n1 "$PICK_QUEUE"
  sed -i '' 1d "$PICK_QUEUE"
  exit 0
fi
printf 'researcher\n'
PICK
cat >"$BIN/geminib" <<'GEMINI'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\nrescuer: ready\n'; exit 0; fi
account=$2
printf 'profile=%s\n' "$account" >>"$GEMINI_LOG"
log=''; brief=''
while [ "$#" -gt 1 ]; do
  case $1 in --log-file) log=$2 ;; --print) brief=$2 ;; esac
  shift
done
if [ -n "${FAKE_EDIT:-}" ]; then printf 'Operation not permitted: %s\n' "$FAKE_EDIT" >&2; exit 5; fi
case $brief in
  *QUOTA-Q*) [ -z "$log" ] || printf 'RESOURCE_EXHAUSTED\n' >"$log"; exit 1 ;;
  *UNAVAIL-Q*) exit 1 ;;
  *APIERR-Q*) printf 'AGY_ERROR: {"short_error":"INTERNAL (code 500): backend error"}
' >&2; exit 3 ;;
esac
if [ -n "${FAKE_LOG_QUOTA:-}" ] && [ "$account" = researcher ]; then
  [ -z "$log" ] || printf 'RESOURCE_EXHAUSTED\n' >"$log"
  exit 1
fi
answer=$(sed -n 's/^ANSWER-FILE: //p' <<<"$brief" | head -n1)
if [ -n "$answer" ] && [ -r "$answer" ]; then cat "$answer"; else printf 'tracked Gemini answer\n'; fi
GEMINI
cat >"$BIN/sandbox-exec" <<'SANDBOX'
#!/usr/bin/env bash
shift 2
exec "$@"
SANDBOX
cat >"$BIN/claudeb" <<'CLAUDEB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VENDOR_LOG"
cat >/dev/null
printf '{"type":"result","result":"claude research answer"}\n'
CLAUDEB
cat >"$BIN/codex" <<'CODEX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VENDOR_LOG"
cat >/dev/null
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'codex research answer\n' >"$2"; fi
  shift
done
CODEX
cat >"$BIN/grokb" <<'GROKB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VENDOR_LOG"
[ -z "${FAKE_GROK_EDIT:-}" ] || printf 'written\n' >>"$FAKE_GROK_EDIT"
if [ -n "${FAKE_GROK_CITATION:-}" ]; then
  jq -cn --arg text "$FAKE_GROK_CITATION" '{type:"text",data:$text}'
  printf '{"type":"end","modelUsage":{"grok-4.7-build":{}}}\n'
  exit 0
fi
printf '{"type":"text","data":"grok research answer"}\n{"type":"end","modelUsage":{"grok-4.7-build":{}}}\n'
GROKB
chmod +x "$BIN"/*
printf 'Research the repository.\n' >"$WORK/prompt"
run(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" WORKER_RUN_IDLE_S=0 \
  GEMINIB_PROFILES_DIR="$HOME/.gemini-profiles" WORKER_RUN_WORKER_PICK="$BIN/worker-pick" PICK_LOG="$WORK/picks" \
  GEMINI_RESEARCH_SANDBOX_EXEC="$BIN/sandbox-exec" GEMINI_LOG="$WORK/gemini.log" FAKE_EDIT="${FAKE_EDIT:-}" \
  FAKE_LOG_QUOTA="${FAKE_LOG_QUOTA:-}" PICK_QUEUE="${PICK_QUEUE:-}" VENDOR_LOG="$WORK/vendor.log" \
  WORKER_RUN_CLAUDEB="$BIN/claudeb" WORKER_RUN_CODEX="$BIN/codex" WORKER_RUN_GROKB="$BIN/grokb" \
  FAKE_GROK_EDIT="${FAKE_GROK_EDIT:-}" FAKE_GROK_CITATION="${FAKE_GROK_CITATION:-}" \
  "$ROOT/bin/light-research" --prompt-file "$WORK/prompt" --out "$WORK/answer" --repo "$REPO" "$@" >"$WORK/out" 2>"$WORK/err"; }
run
rc=$?; assert test "$rc" -eq 0
# The answer file is always headed by its citation count, and a body with no citation line is
# passed through whole under `CITATIONS: 0/0` — a closed yes/no answer stays legal.
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 0/0'
assert test "$(sed '1,2d' "$WORK/answer")" = 'tracked Gemini answer'
assert grep -q '^ACCOUNT: researcher (gemini)$' "$WORK/out"; assert grep -q '^RUN: gemini-' "$WORK/out"
assert grep -qx 'WEB: on' "$WORK/out"
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 0'
# The answer stays on disk: stdout carries the header lines and none of the answer.
assert grep -qx 'CITATIONS: 0/0' "$WORK/out"
assert grep -qx "ANSWER: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
assert grep -qx 'LINES: 3' "$WORK/out"
assert test "$(grep -c 'tracked Gemini answer' "$WORK/out")" = 0
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1); assert test -d "$RUNS/$run_id"; assert test -f "$RUNS/$run_id/meta.json"
assert jq -e '.role == "research" and .light == "research" and .account == "researcher" and .agy_model == "gemini-3.8-flash-high"' "$RUNS/$run_id/meta.json"
assert grep -q -- '--role research' "$WORK/picks"; assert grep -q '^profile=researcher$' "$WORK/gemini.log"
# geminib's capacity markers live in the cache every other Gemini launch reads, so research may write there.
assert grep -qxF "(allow file-write* (subpath \"$(readlink -f "$HOME/.cache/geminib")\"))" "$RUNS/$run_id/sandbox.sb"
FAKE_EDIT="$REPO/blocked" run; rc=$?; assert test "$rc" -eq 5; assert grep -q 'OUTCOME: READ_ONLY_VIOLATION' "$WORK/out"; assert test ! -e "$REPO/blocked"
assert jq -e --arg fake "$ROOT/bin/light-research" '.cli != $fake' "$RUNS/$run_id/meta.json"
assert grep -q 'supervise_gemini_research' "$ROOT/bin/worker-run"
# run_with_deadline installs the supervisor's TERM/INT traps in its CALLER's shell, so a subshell
# around the call orphans the sandboxed CLI when the run is signalled.
assert test "$(grep -cE '\(cd .*run_with_deadline' "$ROOT/share/light-research.sh")" = 0

mkdir -p "$HOME/.gemini-profiles/rescuer"
printf '%s\n' researcher rescuer >"$WORK/pick-queue"
FAKE_LOG_QUOTA=1 PICK_QUEUE="$WORK/pick-queue" run
rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'tracked Gemini answer'
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.walled_accounts == ["researcher"] and .account == "rescuer"' "$RUNS/$run_id/meta.json"

# A research brief names a round to read its logs, never to fix it: the prose scan that binds a
# hand-written fix brief to an open round is a workers-role door, and a ROUND: line here is refused.
mkdir -p "$HOME/.claude-profiles/.claudeb/worker-stats/benches/20260801T140000Z-0a1b2c3"
printf '#!/usr/bin/env bash\nprintf "STUB FIX RULE %%s\\nwrite verdicts.jsonl rows\\n" "$*"\n' >"$BIN/review-bench"; chmod +x "$BIN/review-bench"
printf 'Read the cell logs of round 20260801T140000Z-0a1b2c3 and report how many steps each took.\n' >"$WORK/prompt"
run; rc=$?; assert test "$rc" -eq 0
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert test "$(jq 'has("review_round") or has("round_source")' "$RUNS/$run_id/meta.json")" = false
assert test ! -e "$RUNS/$run_id/fix-rule"
if grep -q 'STUB FIX RULE\|taken from the brief text' "$WORK/err" "$WORK/out" "$RUNS/$run_id/brief.launch" 2>/dev/null; then fail "a research run was bound to the round its brief only reads"; fi
printf 'ROUND: 20260801T140000Z-0a1b2c3\nRead the cell logs.\n' >"$WORK/prompt"
run; rc=$?; assert test "$rc" -ne 0
assert grep -q 'a research run fixes nothing' "$WORK/err" "$WORK/out"
printf 'Research the repository.\n' >"$WORK/prompt"

# Light switched off in Egor's menu launches nothing and names why.
printf 'light_paused=on\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 4
assert grep -qx 'OUTCOME: LIGHT_OFF' "$WORK/out"
assert test ! -s "$WORK/vendor.log"

# Every vendor runs the same tracked read-only role, placed by the light_research row alone.
printf 'light_research=claudeb:sonnet\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'claude research answer'
assert grep -q '^ACCOUNT: researcher (claudeb)$' "$WORK/out"
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.vendor == "claudeb" and .role == "research" and .model == "sonnet" and .effort == "medium"' "$RUNS/$run_id/meta.json"
assert grep -q -- '--model sonnet --effort medium --output-format json --permission-mode plan' "$WORK/vendor.log"
assert test "$(grep -c -- '--dangerously-skip-permissions' "$WORK/vendor.log")" = 0

printf 'light_research=codex\n' >"$TOGGLE"
mkdir -p "$HOME/.codex-profiles/researcher"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'codex research answer'
assert grep -q '^ACCOUNT: researcher (codex)$' "$WORK/out"
assert grep -q -- '--sandbox read-only' "$WORK/vendor.log"

printf 'light_research=grok\n' >"$TOGGLE"
: >"$WORK/vendor.log"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'grok research answer'
assert grep -q '^ACCOUNT: researcher (grok)$' "$WORK/out"
# Grok has no read-only mode: a tree that changed under the run fails it, answer withheld.
rm -f "$WORK/answer"
FAKE_GROK_EDIT="$REPO/file" run; rc=$?; assert test "$rc" -eq 5
assert grep -q '^OUTCOME: READ_ONLY_VIOLATION$' "$WORK/out"; assert test ! -e "$WORK/answer"
git -C "$REPO" checkout -q -- file

printf 'light_research=grok:opus\n' >"$TOGGLE"
run; rc=$?; assert test "$rc" -eq 4; assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"

# Light edit: `worker-run start light` takes vendor, model and effort from the light_edit row, and a
# light-only model stays refused on the full worker leg.
wr(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" WORKER_RUN_IDLE_S=0 \
  WORKER_RUN_WORKER_PICK="$BIN/worker-pick" PICK_LOG="$WORK/picks" VENDOR_LOG="$HOME/.claude-profiles/researcher/vendor.log" \
  WORKER_RUN_CLAUDEB="$BIN/claudeb" WORKER_RUN_CODEX="$BIN/codex" WORKER_RUN_GROKB="$BIN/grokb" \
  "$ROOT/bin/worker-run" "$@" >"$WORK/out" 2>"$WORK/err"; }
printf 'light_edit=claudeb:sonnet\n' >"$TOGGLE"
# A Light edit launches under the SCOPE/VERIFY contract (tests/test_light_edit.sh owns it): the
# brief fences the paths the run may touch, and without that line there is no launch at all.
printf 'SCOPE: file\nVERIFY: true\n\nEdit the repository file.\n' >"$WORK/edit-brief"
: >"$WORK/vendor.log"
wr start light --brief "$WORK/edit-brief" --workdir "$REPO"; rc=$?; assert test "$rc" -eq 0
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert jq -e '.vendor == "claudeb" and .role == "workers" and .light == "edit" and .model == "sonnet" and .effort == "medium"' "$RUNS/$run_id/meta.json"
wr wait "$run_id" --max 60; assert grep -q '^STATUS: done$' "$WORK/out"
assert grep -q -- '--dangerously-skip-permissions' "$HOME/.claude-profiles/researcher/vendor.log"
wr start claudeb --model sonnet --brief "$WORK/prompt" --workdir "$REPO"; rc=$?; assert test "$rc" -ne 0
assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"
printf 'light_edit=grok:opus\n' >"$TOGGLE"
wr start light --brief "$WORK/edit-brief" --workdir "$REPO"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"
rm -f "$TOGGLE"

# Every research prompt carries the answer contract, and each `path:line | "quote" | claim` line is
# checked against the file: verified lines stay where they were, failed ones move under UNVERIFIED.
printf 'alpha\nbeta gamma\ndelta\nepsilon\nzeta\neta\ntheta\n' >"$REPO/cited.txt"
git -C "$REPO" add cited.txt; git -C "$REPO" -c user.name=x -c user.email=x@y commit -qm cited
cat >"$WORK/cited-answer" <<'CITED'
Prose that carries no claim needs no citation line.
cited.txt:2 | "beta gamma" | line 2 names beta
cited.txt:5 | "beta    gamma" | three lines late, inside the tolerance and whitespace-normalised
cited.txt:6 | "beta gamma" | four lines late, outside the tolerance
cited.txt:1 | "no such text" | quote absent from the file
gone.txt:1 | "alpha" | no such file
CITED
printf 'ANSWER-FILE: %s\nResearch the repository.\n' "$WORK/cited-answer" >"$WORK/prompt"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 2/5'
run_id=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1)
assert grep -q 'ANSWER CONTRACT' "$RUNS/$run_id/brief.launch"
unverified=$(grep -n '^UNVERIFIED:$' "$WORK/answer" | cut -d: -f1); assert test -n "$unverified"
for kept in 'line 2 names beta' 'inside the tolerance'; do
  assert test "$(grep -n "$kept" "$WORK/answer" | cut -d: -f1)" -lt "$unverified"
done
for moved in 'outside the tolerance' 'quote absent from the file' 'no such file'; do
  assert test "$(grep -n "$moved" "$WORK/answer" | cut -d: -f1)" -gt "$unverified"
done
assert grep -qx 'Prose that carries no claim needs no citation line.' "$WORK/answer"
assert grep -qx 'CITATIONS: 2/5' "$WORK/out"
assert test "$(grep -c 'beta gamma' "$WORK/out")" = 0

# A web page is a source, not an unresolvable path: an `http(s)://` citation is counted as a LINK,
# kept where it stands and never fetched — the trailing digits of a URL are not a line number.
cat >"$WORK/linked-answer" <<'LINKED'
https://example.test/pricing | "4.25% + $0.35" | the published card rate
https://example.test/docs/v2 | "Authorization and Capture" | the API has delayed capture
cited.txt:2 | "beta gamma" | line 2 names beta
gone.txt:1 | "alpha" | no such file
LINKED
printf 'ANSWER-FILE: %s\nResearch the repository.\n' "$WORK/linked-answer" >"$WORK/prompt"
rm -f "$WORK/answer"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 1/2'
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 2'
assert grep -qx 'LINKS: 2' "$WORK/out"
unverified=$(grep -n '^UNVERIFIED:$' "$WORK/answer" | cut -d: -f1); assert test -n "$unverified"
for kept in 'the published card rate' 'the API has delayed capture'; do
  assert test "$(grep -n "$kept" "$WORK/answer" | cut -d: -f1)" -lt "$unverified"
done

# A scheme in capitals names the same page: read as a file path it fails a citation for a path no
# checkout has, and the answer loses the link it rests on.
printf 'HTTPS://Example.Test/Pricing | "4.25%%" | the card rate\n' >"$WORK/upper-answer"
printf 'ANSWER-FILE: %s\nResearch the repository.\n' "$WORK/upper-answer" >"$WORK/prompt"
rm -f "$WORK/answer"
run; rc=$?; assert test "$rc" -eq 0
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 0/0'
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 1'
assert grep -qx 'LINKS: 1' "$WORK/out"

# The search state is the caller's ask, read ONCE from the prompt header here and handed to
# worker-run as a flag. A state the vendor cannot reach is refused before an account is spent.
printf 'web: OFF\nResearch the repository.\n' >"$WORK/prompt"
rm -f "$WORK/answer"; : >"$WORK/gemini.log"
run; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: MODEL_REFUSED$' "$WORK/out"
assert grep -q 'no switch that turns web search off' "$WORK/err"
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 0
assert test ! -e "$WORK/answer"

printf 'WEB: maybe\nResearch the repository.\n' >"$WORK/prompt"
: >"$WORK/gemini.log"
run; rc=$?; assert test "$rc" -eq 2
assert grep -q 'names no state' "$WORK/err"
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 0

printf 'Research the repository.\n' >"$WORK/prompt"

# G6: grok's --cwd is its whole directory grant, so a two-repository question becomes one run per
# repository, each brief naming its own; every other vendor keeps the single run with --add-dir.
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
assert test "$(grep -c . "$WORK/vendor.log")" = 2
assert test "$(grep -c -- '--add-dir' "$WORK/vendor.log")" = 0
first_run=$(sed -n 's/^RUN: //p' "$WORK/out" | head -1); second_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1)
assert test "$first_run" != "$second_run"
assert grep -qx "REPOSITORY: $repo_path" "$RUNS/$first_run/brief.launch"
assert grep -qx "REPOSITORY: $repo2_path" "$RUNS/$second_run/brief.launch"
assert grep -qx "## $repo_path" "$WORK/answer"
assert grep -qx "## $repo2_path" "$WORK/answer"
assert test "$(grep -c 'grok research answer' "$WORK/answer")" = 2

# Every unit of a fan-out launches in the state the prompt asked for: the launcher's own
# `REPOSITORY:` prefix pushes a re-embedded header out of reach of worker-run's header block.
printf 'WEB: off\nResearch the repository.\n' >"$WORK/prompt"
: >"$WORK/vendor.log"
run --repo "$REPO2"; rc=$?; assert test "$rc" -eq 0
assert test "$(grep -c -- '--disable-web-search' "$WORK/vendor.log")" = 2
assert grep -qx 'WEB: off' "$WORK/out"
assert test "$(grep -cx 'WEB: on' "$WORK/out")" = 0
for off_run in $(sed -n 's/^RUN: //p' "$WORK/out"); do
  assert test "$(jq -r '.web_search' "$RUNS/$off_run/meta.json")" = false
  assert test "$(grep -ci '^web *:' "$RUNS/$off_run/brief.launch")" = 0
  assert grep -qx 'Research the repository.' "$RUNS/$off_run/brief.launch"
done
printf 'Research the repository.\n' >"$WORK/prompt"

printf 'repo two only\n' >"$REPO2/unit-only.txt"
FAKE_GROK_CITATION='unit-only.txt:1 | "repo two only" | claim' run --repo "$REPO2"; rc=$?
assert test "$rc" -eq 0
assert test "$(head -n1 "$WORK/answer")" = 'CITATIONS: 1/2'
assert grep -qx 'UNVERIFIED:' "$WORK/answer"

# A launch that fails mid-batch waits out the units already started: abandoned, each keeps running
# on an account of its own with nothing reading its answer.
printf '%s\n' researcher 'BAD!' >"$WORK/pick-queue"
rm -f "$WORK/answer"
PICK_QUEUE="$WORK/pick-queue" run --repo "$REPO2"; rc=$?
assert test "$rc" -eq 4
assert grep -q '^ACCOUNT: researcher (grok)$' "$WORK/out"
assert test ! -e "$WORK/answer"
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

# Batching: several --prompt-file run side by side and land under ONE citation header.
printf 'file:1 | "x" | the tracked file holds x\n' >"$WORK/q1-answer"
printf 'plain second answer\nhttps://example.test/two | "second page" | a link of the second unit\n' >"$WORK/q2-answer"
printf 'ANSWER-FILE: %s\nFirst question.\n' "$WORK/q1-answer" >"$WORK/prompt"
printf 'ANSWER-FILE: %s\nSecond question.\n' "$WORK/q2-answer" >"$WORK/prompt2"
: >"$WORK/gemini.log"
run --prompt-file "$WORK/prompt2"; rc=$?; assert test "$rc" -eq 0
assert test "$(grep -c '^profile=' "$WORK/gemini.log")" = 2
assert test "$(grep -c '^CITATIONS:' "$WORK/answer")" = 1
assert test "$(head -1 "$WORK/answer")" = 'CITATIONS: 1/1'
# Both header lines are counted across the batch and written once: a per-unit `LINKS:` carried into
# the body puts a stray count under every heading and leaves the answer with no aggregate.
assert test "$(grep -c '^LINKS:' "$WORK/answer")" = 1
assert test "$(sed -n 2p "$WORK/answer")" = 'LINKS: 1'
assert grep -qx 'LINKS: 1' "$WORK/out"
assert test "$(grep -n '^## Q1$' "$WORK/answer" | cut -d: -f1)" -lt "$(grep -n '^## Q2$' "$WORK/answer" | cut -d: -f1)"
assert grep -qx 'plain second answer' "$WORK/answer"

# One failed question fails the call: 3 beats 4 beats 0, and no answer file is left behind.
printf 'QUOTA-Q: the leg answers with a quota wall.\n' >"$WORK/prompt-quota"
printf 'UNAVAIL-Q: the leg dies without a quota marker.\n' >"$WORK/prompt-unavail"
printf 'Research the repository.\n' >"$WORK/prompt"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-quota"; rc=$?; assert test "$rc" -eq 3
assert grep -q '^OUTCOME: GEMINI_USAGE_LIMIT$' "$WORK/out"; assert test ! -e "$WORK/answer"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-unavail"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/out"; assert test ! -e "$WORK/answer"
printf 'APIERR-Q: agy >= 1.2.6 exits 3 on a model API failure that is no quota wall.
' >"$WORK/prompt-apierr"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-apierr"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: GEMINI_UNAVAILABLE$' "$WORK/out"; assert test ! -e "$WORK/answer"
rm -f "$WORK/answer"; run --prompt-file "$WORK/prompt-unavail" --prompt-file "$WORK/prompt-quota"; rc=$?; assert test "$rc" -eq 3
assert test ! -e "$WORK/answer"

# One wait round per call: a run still going hands back its id, and --attach waits one more round
# and lands the answer with the run's own exit code.
printf '#!/usr/bin/env bash\nif [ "$1" = list ]; then printf "researcher: ready\\n"; exit 0; fi\nsleep 3\nprintf "slow Gemini answer\\n"\n' >"$BIN/geminib"
rm -f "$WORK/answer"
LIGHT_RESEARCH_WAIT_MAX=0 run; rc=$?; assert test "$rc" -eq 0
assert grep -q '^STATUS: running$' "$WORK/out"; assert test ! -e "$WORK/answer"
# The state is recorded at launch, so the round that hands back a running id already names it.
assert grep -qx 'WEB: on' "$WORK/out"
assert grep -qx "OUT: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
slow_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1); assert test -d "$RUNS/$slow_run"
attach(){ env HOME="$HOME" PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK" WORKER_RUN_DIR="$RUNS" LIGHT_RESEARCH_WAIT_MAX="${LIGHT_RESEARCH_WAIT_MAX:-540}" \
  "$ROOT/bin/light-research" "$@" >"$WORK/out" 2>"$WORK/err"; }
assert test ! -e "$REPO/answer-in-repo"
attach --attach "$slow_run" --out "$REPO/answer-in-repo"; rc=$?; assert test "$rc" -eq 2
assert test ! -e "$REPO/answer-in-repo"
attach --attach "$slow_run" --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 0
assert test "$(sed '1,2d' "$WORK/answer")" = 'slow Gemini answer'; assert grep -q '^ACCOUNT: researcher (gemini)$' "$WORK/out"
# --attach lands the same headed answer file, and its stdout carries the header lines, not the answer.
assert grep -qx 'CITATIONS: 0/0' "$WORK/out"
assert grep -qx "ANSWER: $(cd "$WORK" && pwd -P)/answer" "$WORK/out"
assert test "$(grep -c 'slow Gemini answer' "$WORK/out")" = 0
attach --attach "$slow_run" --out "$WORK/answer" --repo "$REPO"; rc=$?; assert test "$rc" -eq 2
attach --attach codex-1-2-none --out "$WORK/answer"; rc=$?; assert test "$rc" -eq 4
assert grep -q '^OUTCOME: CODEX_UNAVAILABLE$' "$WORK/out"

# A batch whose last unit is still running still exits on the worst rc a finished unit brought
# back — a usage limit is what the caller routes on — and keeps the units it collected on disk.
cat >"$BIN/geminib" <<'QUOTASLOW'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\n'; exit 0; fi
log=''; brief=''
while [ "$#" -gt 1 ]; do
  case $1 in --log-file) log=$2 ;; --print) brief=$2 ;; esac
  shift
done
case $brief in
  *QUOTA-Q*) [ -z "$log" ] || printf 'RESOURCE_EXHAUSTED\n' >"$log"; exit 1 ;;
esac
sleep 8
printf 'slow Gemini answer\n'
QUOTASLOW
chmod +x "$BIN/geminib"
printf 'QUOTA-Q: the leg answers with a quota wall.\n' >"$WORK/prompt"
printf 'Research the repository slowly.\n' >"$WORK/prompt-slow"
rm -f "$WORK/answer"; rm -rf "$WORK/answer.units"
LIGHT_RESEARCH_WAIT_MAX=3 run --prompt-file "$WORK/prompt-slow"; rc=$?
assert test "$rc" -eq 3
assert grep -q '^STATUS: running$' "$WORK/out"
assert test ! -e "$WORK/answer"
assert test "$(grep -c . "$WORK/answer.units/table")" = 2
assert test "$(cat "$WORK/answer.units/rc.0")" = 3
rm -rf "$WORK/answer.units"

# --attach re-assembles the WHOLE batch, not the one run it was handed: the other units' answers
# live beside --out, and the work directory of the launching call is long gone.
cat >"$BIN/geminib" <<'TWOSLOW'
#!/usr/bin/env bash
if [ "$1" = list ]; then printf 'researcher: ready\n'; exit 0; fi
brief=''
while [ "$#" -gt 1 ]; do
  case $1 in --print) brief=$2 ;; esac
  shift
done
sleep 2
case $brief in
  *'Second question'*) printf 'second batched answer\n' ;;
  *) printf 'first batched answer\n' ;;
esac
TWOSLOW
chmod +x "$BIN/geminib"
printf 'First question.\n' >"$WORK/prompt"
printf 'Second question.\n' >"$WORK/prompt2"
rm -f "$WORK/answer"; rm -rf "$WORK/answer.units"
LIGHT_RESEARCH_WAIT_MAX=0 run --prompt-file "$WORK/prompt2"; rc=$?
assert test "$rc" -eq 0
assert test "$(grep -c '^STATUS: running$' "$WORK/out")" = 2
assert test -f "$WORK/answer.units/table"
assert test ! -e "$WORK/answer"
batch_run=$(sed -n 's/^RUN: //p' "$WORK/out" | tail -1)
attach --attach "$batch_run" --out "$WORK/answer"; rc=$?
assert test "$rc" -eq 0
assert grep -qx 'first batched answer' "$WORK/answer"
assert grep -qx 'second batched answer' "$WORK/answer"
assert test "$(grep -n '^## Q1$' "$WORK/answer" | cut -d: -f1)" -lt "$(grep -n '^## Q2$' "$WORK/answer" | cut -d: -f1)"
assert test -f "$WORK/answer.units/table"
cp "$WORK/answer" "$WORK/first-answer"
while IFS=$'\t' read -r attached_run rest; do
  attach --attach "$attached_run" --out "$WORK/answer"; rc=$?
  assert test "$rc" -eq 0
  assert cmp -s "$WORK/first-answer" "$WORK/answer"
done <"$WORK/answer.units/table"
printf 'Research the repository.\n' >"$WORK/prompt"

# The rename leaves no trace of the vendor-bound name outside git history.
old_name="gemini""-research"
assert test -z "$(git -C "$ROOT" grep -l -F "$old_name" -- . 2>/dev/null)"
setup_root=${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}
if [ -d "$setup_root/agents" ]; then
  assert test ! -e "$setup_root/agents/$old_name.md"; assert test -f "$setup_root/agents/light-worker.md"
fi

printf 'PASS: %s asserts; light toggle rows and defaults, `worker-run start light` from the light_edit row, tracked research on gemini/claudeb/codex/grok with each read-only mechanism, a research brief that names a round but never fixes it, a log-only quota walling the account, outcomes mapped to exits, the citation check with its UNVERIFIED block, its `LINKS:` count for web sources and headed on-disk answer, the `WEB:` state beside the account, per-repository fan-out on grok against one --add-dir run elsewhere, batched questions under one header, a citation resolved against every repository, a launch that fails mid-batch collecting what it already started, and one wait round per call with --attach continuing a running run and re-assembling a whole batch\n' "$asserts"
