#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# Every doctor's measuring run over a checkout whose ledgers are tracked leaves those files byte for byte
# (shared-invariants row ej): what a run settles lives in its overlay, every read merges it, and only
# `doctor-fix ledger-sync` writes it into a linked worktree's ledgers for a commit.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }

PROJECTS=$(dirname "$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")")
unrooted=$(jq -r '.rows[].fixes[]?.files[]?' "$ROOT/share/code-ledger.json" | while IFS= read -r f; do
  [ -d "$PROJECTS/${f%%/*}/.git" ] || printf '%s ' "$f"; done)
assert test -z "$unrooted"

export HOME="$WORK/home" DOCTORS_DIR="$WORK/doctors" CLAUDEB_DIR="$WORK/claudeb" DOCTOR_TRIGGER=fixture
L="$WORK/legs"
REPOS="$WORK/repos"
mkdir -p "$HOME/.claude/projects" "$CLAUDEB_DIR" "$L/share" "$REPOS/fixrepo"
printf 'x\n' >"$REPOS/fixrepo/f.sh"
git -C "$REPOS/fixrepo" init -q && git -C "$REPOS/fixrepo" add f.sh && commit "$REPOS/fixrepo" fix

AT=$(date -u -r $(($(date +%s) - 3600)) +%Y-%m-%dT%H:%M:%S+00:00)
for name in doctor harness updater code system; do cp "$ROOT/share/$name-ledger.json" "$L/share/"; done
cp "$ROOT/share/canonical-mechanisms.json" "$L/share/"
FIX='{at: $at, by: "fixture", files: ["fixrepo/f.sh"], in: null, regressed_at: null}'
jq --arg at "$AT" ".rows += [{id: \"fixture-settle\", title: \"t\", match: {rule: \"floor\", ident: \"bash:fixture-settle\"},
  status: \"fixed-pending\", fixes: [$FIX], same_cause: [], last_reviewed: null, reviewed_by: null, note: null,
  handoff: null}]" "$ROOT/share/harness-ledger.json" >"$L/share/harness-ledger.json"
jq --indent 1 --arg at "$AT" ".rows += [{id: \"fixture-settle\", block: \"reviewers\", title: \"t\",
  match: {word: \"crashed\", detail: \"fixture settle\"}, status: \"fixed-pending\", fixes: [$FIX], same_cause: [],
  last_reviewed: null, reviewed_by: \"fixture\", note: null, handoff: null}]" "$ROOT/share/doctor-ledger.json" \
  >"$L/share/doctor-ledger.json"
git -C "$L" init -q && git -C "$L" add share && commit "$L" ledgers
tracked() { git -C "$L" status --porcelain --untracked-files=no; }

printf '{}\n' >"$WORK/settings.json"
HARNESS_SETTINGS="$WORK/settings.json" CLAUDE_PROJECTS_DIR="$HOME/.claude/projects" STATUSLINE_CACHE_DIR="$WORK/sl" \
  MEMLOGD_DIR="$WORK/memlogd" INSTRUCTION_WATCH_STATE="$WORK/watch" HARNESS_WATCH_ROOTS="" HARNESS_DOCTOR_BOOTS= \
  HARNESS_DOCTOR_DIR="$WORK/harness" HARNESS_LEDGER="$L/share/harness-ledger.json" HARNESS_REPOS_DIR="$REPOS" \
  HARNESS_DOCTOR_FAKE_SAMPLE="" SPEED_DOCTOR_DIR="$WORK/speed" CODE_LEDGER="$L/share/code-ledger.json" \
  "$ROOT/bin/harness-doctor" --quiet || fail "the harness and speed doctors failed"
assert test -z "$(tracked)"
assert jq -e '.rows["fixture-settle"][$at] == {in: ("fixrepo@" + $head), status: "fixed"}' --arg at "$AT" \
  --arg head "$(git -C "$REPOS/fixrepo" log -1 --format=%h)" "$WORK/harness/ledger-settled.json" >/dev/null

WORKER_STATS_DIR="$WORK/stats" WORKER_RUN_DIR="$WORK/runs" LLM_DOCTOR_DIR="$WORK/llm" \
  IMAGE_LEG_LOG="$WORK/image-legs.jsonl" LLM_DOCTOR_LEDGER="$L/share/doctor-ledger.json" GEMINIB_CACHE_DIR="$WORK/geminib" \
  LLM_DOCTOR_REBOOTS="" LLM_DOCTOR_REPOS="$REPOS" "$ROOT/bin/llm-doctor" --quiet || fail "the llm doctor failed"
assert test -z "$(tracked)"
assert jq -e '.rows["fixture-settle"][$at].status == "fixed"' --arg at "$AT" "$WORK/llm/ledger-settled.json" >/dev/null

VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vcu" UPDATER_DOCTOR_DIR="$WORK/updater" CODEXB_PROFILES_DIR="$WORK/profiles" \
  GROKB_CACHE_DIR="$WORK/grokb" UPDATER_DOCTOR_LEDGER="$L/share/updater-ledger.json" \
  "$ROOT/bin/updater-doctor" --quiet || fail "the updater doctor failed"
assert test -z "$(tracked)"

CODE_DOCTOR_DIR="$WORK/code" CODE_DOCTOR_LEDGER="$L/share/code-ledger.json" CODE_DOCTOR_LAUNCHCTL=true \
  CODE_DOCTOR_MECHANISMS="$L/share/canonical-mechanisms.json" HARNESS_DOCTOR_DIR="$WORK/harness" \
  STATUSLINE_CACHE_DIR="$WORK/sl" CODE_DOCTOR_REPOS="$L:" "$ROOT/bin/code-doctor" refresh --quiet ||
  fail "the code doctor failed"
assert test -z "$(tracked)"

mkdir -p "$WORK/sysfix"
for name in ps vm_stat sysctl ioreg df last diskutil launchctl du; do
  printf '#!/bin/sh\n' >"$WORK/sysfix/$name" && chmod +x "$WORK/sysfix/$name"
  export "SYSTEM_DOCTOR_$(printf %s "$name" | tr '[:lower:]' '[:upper:]')=$WORK/sysfix/$name"
done
printf '%s\n' "$L" >"$WORK/sweep-repos"
for verb in tick ""; do
  SYSTEM_DOCTOR_DIR="$WORK/system" SYSTEM_DOCTOR_LEDGER="$L/share/system-ledger.json" SYSTEM_DOCTOR_FIX="$WORK/sysfix" \
    SYSTEM_DOCTOR_OWN_ROOTS="$WORK/own/" SYSTEM_DOCTOR_DIAG_DIRS="$WORK/diag" SYSTEM_DOCTOR_AGENTS_DIRS="$WORK/agents" \
    SYSTEM_DOCTOR_CACHE_ROOTS="$WORK/caches" SYSTEM_DOCTOR_CACHE_DIRS= SYSTEM_DOCTOR_HOST_TICKS="$WORK/sysfix/host" \
    SYSTEM_DOCTOR_LIBEXEC_DIR="$HOME/.local/libexec" SYSTEM_DOCTOR_AGENT_DIR="$HOME/Library/LaunchAgents" \
    SYSTEM_DOCTOR_RUSAGE="$WORK/sysfix/rusage.json" SYSTEM_DOCTOR_PROCS="$WORK/sysfix/procs.json" WORKER_RUN_DIR="$WORK/runs" \
    NIGHT_RUN_SWEEP_REPOS="$WORK/sweep-repos" SYSTEM_DOCTOR_REPOS_DIR="$WORK" \
    "$ROOT/bin/system-doctor" $verb >/dev/null || fail "system-doctor ${verb:-judge} failed"
done
assert test -z "$(tracked)"

export HARNESS_DOCTOR_DIR="$WORK/harness" LLM_DOCTOR_DIR="$WORK/llm"
assert test "$("$ROOT/bin/doctor-fix" ledger-sync "$L" 2>&1)" = "doctor-fix: ledger-sync writes only a linked worktree, never $L"
assert test -z "$(tracked)"
git -C "$L" worktree add -q "$WORK/wt" -b night/n/ledger-sync
out=$("$ROOT/bin/doctor-fix" ledger-sync "$WORK/wt") || fail "ledger-sync failed: $out"
assert test "$(printf '%s\n' "$out" | cut -f2 | sort -u)" = "1 rows settled"
assert test "$(git -C "$WORK/wt" diff --numstat | sort)" = "$(printf '2\t2\tshare/doctor-ledger.json\n2\t2\tshare/harness-ledger.json')"
for name in doctor harness; do
  assert jq -e '.rows[-1] | .status == "fixed" and (.fixes[-1].in | test("^fixrepo@"))' "$WORK/wt/share/$name-ledger.json" >/dev/null
done
assert test -z "$(tracked)"

echo "PASS: $asserts asserts; harness, speed, llm, updater, code (refresh) and system (tick, judge) runs over tracked ledgers keep their bytes, settled fields land in each doctor's overlay, and doctor-fix ledger-sync writes them only into a linked worktree in the ledger's own layout"
exit
