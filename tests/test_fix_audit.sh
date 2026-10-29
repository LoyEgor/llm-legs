#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/fix-audit (goal fix-audit, docs/directions/doctors.md) off a fixture night: every fixer commit naming its round
# and positions maps to its finding, a round-only commit to all of the round's fixed findings; the weekly read packs
# blind packets, picks a reader outside the judge's family and is not repeated within the week; apply records the
# verdicts; a false verdict raises a Harness fix_audit row until a commit naming its revert lands. Fixture directories only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
asserts=0
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_not() { asserts=$((asserts + 1)); ! "$@" || fail "assert $asserts unexpectedly held: $*"; }

export HOME="$WORK/home" FIX_AUDIT_DIR="$WORK/audit" FIX_AUDIT_REPOS="$WORK/repos" DOCTORS_DIR="$WORK/doctors"
export NIGHT_RUN_SWEEP_REPOS="$WORK/sweep" WORKER_STATS_DIR="$WORK/stats" WORKER_RUN_DIR="$WORK/runs"
export HARNESS_LEDGER="$WORK/ledgers/harness-ledger.json" TOKENMAP_ROOT="$WORK/no-tokenmap"
export FIX_AUDIT_WORKER_RUN="$WORK/worker-run" FIX_AUDIT_WORKER_PICK="$WORK/worker-pick"
LEDGER="$WORK/ledgers/fix-ledger.json"
mkdir -p "$HOME" "$WORK/ledgers" "$WORK/repos/llm-legs" "$WORK/doctors"
printf '%s\n' "$WORK/repos/llm-legs" >"$NIGHT_RUN_SWEEP_REPOS"
printf 'claudeb\tmain\t50\tok\ncodex\tmain\t20\tok\n' >"$WORK/picks"
cat >"$FIX_AUDIT_WORKER_PICK" <<EOF
#!/bin/sh
cat "$WORK/picks"
EOF
# The reader stand-in: item 01 false, every other needed, into the path its brief names.
cat >"$FIX_AUDIT_WORKER_RUN" <<'EOF'
#!/usr/bin/env bash
case $1 in
  start)
    printf '%s\n' "$*" >>"$FIX_AUDIT_DIR/../starts"
    while [ $# -gt 0 ] && [ "$1" != --brief ]; do shift; done
    out=$(sed -n 's/^Write \(.*\), tab-separated.*/\1/p' "$2")
    items=$(sed -n 's/^Your items are .* for NN in \(.*\)\. Each packet gives:$/\1/p' "$2")
    printf 'item\tverdict\tconfidence\treason\tevidence\n' >"$out"
    for item in $items; do
      verdict=needed
      [ "$item" = 01 ] && verdict=false
      printf '%s\t%s\thigh\treason %s\tapp.py:1\n' "$item" "$verdict" "$item" >>"$out"
    done
    printf 'RUN: reader-%s\n' "$RANDOM" ;;
  wait) printf 'STATUS: done\n' ;;
esac
EOF
chmod +x "$FIX_AUDIT_WORKER_PICK" "$FIX_AUDIT_WORKER_RUN"

R1=20261020T100000Z-abc1234 R2=20261021T100000Z-def5678
repo="$WORK/repos/llm-legs"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
for i in $(seq 1 60); do printf 'line_%d = %d\n' "$i" "$i"; done >"$repo/app.py"
then=$(( $(date +%s) - 8 * 86400 ))
commit() { # message -> the new commit, dated a week and a day ago
  git -C "$repo" add -A
  GIT_AUTHOR_DATE="@$then" GIT_COMMITTER_DATE="@$then" git -C "$repo" commit -qm "$1"
  git -C "$repo" rev-parse HEAD
}
base=$(commit "base")
sed -i '' -e 's/^line_10 = 10$/line_10 = 1/' -e 's/^line_40 = 40$/line_40 = 4/' "$repo/app.py"
c1=$(commit "fit: two copies made one (round $R1 F0,2)")
sed -i '' -e 's/^line_25 = 25$/line_25 = 2/' "$repo/app.py"
c2=$(commit "$R1 F3: one owner")
printf 'extra = 1\n' >>"$repo/app.py"
c3=$(commit "legacy cut, review round $R2")
printf 'other = 1\n' >"$repo/other.py"
commit "unrelated work" >/dev/null

reviewed=$(git -C "$repo" rev-parse "$base:app.py")
bench() { # round lens [reviewed blob of app.py] -> its bench directory
  mkdir -p "$WORKER_STATS_DIR/benches/$1"
  printf '{"lens": "%s", "judge": {"model": "opus"}, "workdir": "/Volumes/Work/Projects/llm-legs", "reviewed": {"llm-legs/app.py": "%s"}}\n' \
    "$2" "${3:-$reviewed}" >"$WORKER_STATS_DIR/benches/$1/meta.json"
  printf '%s\n' "$WORKER_STATS_DIR/benches/$1"
}
b1=$(bench "$R1" fit)
cat >"$b1/verdicts.jsonl" <<'EOF'
{"rater": "haiku-high", "idx": 0, "verdict": "confirmed", "by": "judge"}
{"rater": "haiku-high", "idx": 1, "verdict": "false_positive", "by": "judge"}
{"rater": "haiku-high", "idx": 2, "verdict": "confirmed", "by": "judge"}
{"rater": "opus-medium", "idx": 0, "verdict": "confirmed", "by": "judge"}
{"kind": "fixer", "finding": 0, "outcome": "fixed"}
{"kind": "fixer", "finding": 2, "outcome": "fixed"}
{"kind": "fixer", "finding": 3, "outcome": "fixed"}
EOF
cat >"$b1/findings-haiku-high.jsonl" <<'EOF'
{"file": "llm-legs/app.py", "line": 10, "summary": "line_10 repeats what line_11 says"}
{"file": "llm-legs/app.py", "line": 30, "summary": "not a finding"}
{"file": "llm-legs/app.py", "line": 40, "summary": "line_40 repeats line_41"}
EOF
printf '{"file": "app.py", "line": 25, "summary": "line_25 has two owners"}\n' >"$b1/findings-opus-medium.jsonl"
b2=$(bench "$R2" legacy-dead)
printf '{"rater": "haiku-high", "idx": 0, "verdict": "confirmed", "by": "judge"}\n{"kind": "fixer", "finding": 0, "outcome": "fixed"}\n' \
  >"$b2/verdicts.jsonl"
printf '{"file": "llm-legs/app.py", "line": 60, "summary": "the tail is dead"}\n' >"$b2/findings-haiku-high.jsonl"
mkdir -p "$WORKER_RUN_DIR/claudeb-1-1-aaaa"
printf '{"review_round": "%s", "model": "sonnet", "vendor": "claudeb"}\n' "$R1" >"$WORKER_RUN_DIR/claudeb-1-1-aaaa/meta.json"
printf '{"kind": "fixer", "finding": %d, "outcome": "fixed"}\n' 0 2 3 >"$WORKER_RUN_DIR/claudeb-1-1-aaaa/verdicts.jsonl"

fa() { "$ROOT/bin/fix-audit" "$@"; }
row() { jq -c --arg id "$1" '.rows[] | select(.id == $id) | '"$2" "$LEDGER"; }

# A fixture night's fixer commits all map to their findings: positions named, then the round alone.
out=$(fa apply) || fail "apply: $out"
assert grep -q '^collected 4 fixed finding(s)$' <<<"$out"
assert test "$(row "$R1/F0" '[.commits, .mapping, .fixer, .lens, .cell, .judge]')" = "[[\"$c1\"],\"named\",\"sonnet\",\"fit\",\"haiku-high\",\"opus\"]"
assert test "$(row "$R1/F2" '.commits')" = "[\"$c1\"]"
assert test "$(row "$R1/F3" '[.commits, .file, .line]')" = "[[\"$c2\"],\"app.py\",25]"
assert test "$(row "$R2/F0" '[.commits, .mapping, .lens, .fixer]')" = "[[\"$c3\"],\"round\",\"legacy\",\"unknown\"]"
assert test "$(jq '[.rows[] | select(.id == "'"$R1"'/F1")] | length' "$LEDGER")" = 0
assert jq -e '[.rows[].verdict] == [null, null, null, null]' "$LEDGER" >/dev/null
assert test "$(jq -r '."'"$R1"'/F0"[0]' "$FIX_AUDIT_DIR/fixers.json")" = sonnet
# Who fixed what outlives the run record (pruned after about 9 days): the nightly read kept it.
rm -rf "$WORKER_RUN_DIR/claudeb-1-1-aaaa"
jq --arg id "$R1/F2" 'del(.rows[] | select(.id == $id))' "$LEDGER" >"$WORK/l" && mv "$WORK/l" "$LEDGER"
out=$(fa apply) || fail "apply again: $out"
assert grep -q '^collected 1 fixed finding(s)$' <<<"$out"
assert test "$(row "$R1/F2" '[.commits, .fixer]')" = "[[\"$c1\"],\"sonnet\"]"
assert_not fa pending

# The weekly read: blind packets, a reader outside the judge's family (codex for an Opus judge).
out=$(fa read) || fail "read: $out"
day=$(date +%Y-%m-%d)
key="$FIX_AUDIT_DIR/$day-key/key.json"
assert test "$(jq '.items | length' "$key")" = 4
assert test "$(jq -r '[.chunks[] | .reader] | join(" ")' "$key")" = "codex:default"
assert grep -q "^start codex --brief $FIX_AUDIT_DIR/$day-key/brief-1 --workdir " "$WORK/starts"
assert_blind() { ! grep -qiE "haiku|sonnet|opus|$R1|$R2" "$1"; }
for packet in "$FIX_AUDIT_DIR/$day/packets/items/"*.md; do
  assert assert_blind "$packet"
  assert grep -q '^@@ ' "$packet"
done
assert grep -q "^Commit $(cut -c1-12 <<<"$c1"): its hunks in \`app.py\` for this finding.$" \
  "$FIX_AUDIT_DIR/$day/packets/items/$(jq -r --arg id "$R1/F0" '.items | to_entries[] | select(.value.id == $id) | .key' "$key").md"
# Read once a week: a second read the same week launches nothing.
out=$(fa read) || fail "second read: $out"
assert grep -q "^read $day; the next read is due " <<<"$out"
assert test "$(wc -l <"$WORK/starts" | tr -d ' ')" = 1
assert test "$(fa pending)" = "$FIX_AUDIT_DIR/$day-key"

# Apply records the verdicts and the read; nothing is pending after.
false_id=$(jq -r '.items["01"].id' "$key")
out=$(fa apply) || fail "apply verdicts: $out"
assert grep -q "^recorded 4 verdict(s) of $FIX_AUDIT_DIR/$day-key$" <<<"$out"
assert test "$(row "$false_id" '[.verdict, .reader, .reason]')" = '["false","codex:default","reason 01"]'
assert test "$(jq -c '[.rows[] | select(.verdict == "needed")] | length' "$LEDGER")" = 3
assert test "$(jq -c '.read' "$LEDGER")" = "[\"$day\"]"
assert_not fa pending
assert grep -q '^fit	haiku	sonnet	' <<<"$out"

# A false verdict raises a Harness row, its fixer told what to revert, until a commit naming the revert lands.
harness_rows() {
  python3 - "$ROOT" <<'EOF'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("harness_doctor", sys.argv[1] + "/bin/harness-doctor")
module = importlib.util.module_from_spec(importlib.util.spec_from_loader("harness_doctor", loader))
loader.exec_module(module)
import fix_audit
for v in module.fix_audit_verdicts():
    print(json.dumps([v["rule"], v["ident"], v["level"], v["group"], fix_audit.revert_what(fix_audit.ledger_row(v["ident"]))]))
EOF
}
rows=$(harness_rows) || fail "harness rows: $rows"
assert test "$(wc -l <<<"$rows" | tr -d ' ')" = 1
assert test "$(jq -c '.[0:4]' <<<"$rows")" = "[\"fix_audit\",\"$false_id\",\"red\",\"Fix audit\"]"
assert grep -q "revert its hunks in app.py of llm-legs@$(row "$false_id" '.commits[0]' | tr -d '"' | cut -c1-8)" <<<"$rows"
assert grep -qF "names \`revert ${false_id%/F*} F${false_id##*/F}\`" <<<"$rows"
sed -i '' -e 's/^line_10 = 1$/line_10 = 10/' "$repo/app.py"
then=$(date +%s)
reverted=$(commit "revert ${false_id%/F*} F${false_id##*/F}: fix-audit read it false")
fa apply >/dev/null || fail "apply after the revert"
assert test "$(row "$false_id" '.reverted')" = "\"$reverted\""
assert test -z "$(harness_rows)"

# Every vendor of another family off: the reader is Opus.
printf 'claudeb\tmain\t50\tok\ncodex\tmain\t20\toff\n' >"$WORK/picks"
assert test "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fix_audit; print(fix_audit.reader("claude"))' "$ROOT/share")" = "('claudeb', 'opus')"

# Two batches: two readers at once, each in its own workdir off the repo (worker-run refuses a second worker in a
# held workdir), a reader that left items unread is no read for read or apply, and a rerun reads only that batch.
cat >"$WORK/worker-run-held" <<'EOF'
#!/usr/bin/env bash
case $1 in
  start)
    printf '%s\n' "$*" >>"$FIX_AUDIT_DIR/../starts-held"
    while [ $# -gt 0 ]; do case $1 in --brief) brief=$2 ;; --workdir) workdir=$2 ;; esac; shift; done
    if grep -qxF "$workdir" "$FIX_AUDIT_DIR/../held" 2>/dev/null; then
      printf 'run x still works in %s; a second worker there would edit under it\n' "$workdir" >&2; exit 4
    fi
    printf '%s\n' "$workdir" >>"$FIX_AUDIT_DIR/../held"
    out=$(sed -n 's/^Write \(.*\), tab-separated.*/\1/p' "$brief")
    printf 'item\tverdict\tconfidence\treason\tevidence\n' >"$out"
    if ! grep -qxF "$brief" "$FIX_AUDIT_DIR/../fail-briefs"; then
      for item in $(sed -n 's/^Your items are .* for NN in \(.*\)\. Each packet gives:$/\1/p' "$brief"); do
        printf '%s\tneeded\thigh\tr\tapp.py:1\n' "$item" >>"$out"
      done
    fi
    printf 'RUN: reader-%s\n' "$RANDOM" ;;
  wait) printf 'STATUS: done\n' ;;
esac
EOF
chmod +x "$WORK/worker-run-held"
k="$FIX_AUDIT_DIR/2026-01-05-key"
python3 - "$ROOT/share" "$k" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import fix_audit
key_dir, folder = sys.argv[2], sys.argv[2][:-4]
os.makedirs(key_dir)
chunks = []
for n, items in ((1, ["01"]), (2, ["02"])):
    out, path = os.path.join(folder, "verdicts-%d.tsv" % n), os.path.join(key_dir, "brief-%d" % n)
    with open(path, "w") as handle:
        handle.write(fix_audit.brief(items, os.path.join(folder, "packets", "items"), out))
    chunks.append({"judge": "claude", "items": items, "brief": path, "out": out})
fix_audit.write_json(os.path.join(key_dir, "key.json"), {"items": {"01": {"id": "r/F0", "net_lines": 0, "hunks": 1},
                                                                  "02": {"id": "r/F1", "net_lines": 0, "hunks": 1}}, "chunks": chunks})
fix_audit.write_json(os.path.join(os.path.dirname(key_dir), "ledger-held.json"), {"rows": [{"id": "r/F0"}, {"id": "r/F1"}]})
EOF
applied() { # -> "<recorded> <unread> <read days>" of an apply of $k on the fixture ledger
  python3 - "$ROOT/share" "$k" <<'EOF'
import os, sys
sys.path.insert(0, sys.argv[1])
import fix_audit
path = os.path.join(os.path.dirname(sys.argv[2]), "ledger-held.json")
ledger = fix_audit.read_json(path, {})
count, unread = fix_audit.apply(ledger, sys.argv[2])
fix_audit.write_json(path, ledger)
print(count, unread, ",".join(ledger.get("read") or ["-"]))
EOF
}
printf '%s\n' "$k/brief-2" >"$WORK/fail-briefs"
out=$(FIX_AUDIT_WORKER_RUN="$WORK/worker-run-held" fa read "$k") || fail "held read: $out"
workdirs=$(sed -n 's/.* --workdir \([^ ]*\).*/\1/p' "$WORK/starts-held")
assert test "$(wc -l <<<"$workdirs" | tr -d ' ')" = 2
assert test "$(sort -u <<<"$workdirs" | wc -l | tr -d ' ')" = 2
assert_not grep -qE "^$ROOT(/|$)" <<<"$workdirs"
assert grep -q "^${k%-key}/verdicts-1.tsv: read$" <<<"$out"
assert grep -q "^${k%-key}/verdicts-2.tsv: run reader-[0-9]* left items unread$" <<<"$out"
assert test "$(applied)" = "1 1 -"
: >"$WORK/fail-briefs"; : >"$WORK/held"
out=$(FIX_AUDIT_WORKER_RUN="$WORK/worker-run-held" fa read "$k") || fail "held rerun: $out"
assert test "$(wc -l <"$WORK/starts-held" | tr -d ' ')" = 3
assert grep -q -- "--brief $k/brief-2 " <<<"$(tail -n1 "$WORK/starts-held")"
assert test "$(grep -c ': read$' <<<"$out")" = 2
assert test "$(applied)" = "1 0 2026-01-05"

# A hunk is a finding's only on evidence, never by nearness: a commit naming two findings of one file gives each only
# the change at its own reviewed line, and a round-only commit's change two lines off a finding whose fix changed
# nothing is not that finding's: it is not packed, and read false (by a packet of before) it has nothing to revert.
R3=20261022T100000Z-0123abc
sed -i '' -e 's/^line_50 = 50$/line_50 = 5/' "$repo/app.py"
commit "speed: one pass, review round $R3" >/dev/null
b3=$(bench "$R3" speed "$(git -C "$repo" rev-parse HEAD^:app.py)")
printf '{"rater": "opus-high", "idx": %d, "verdict": "confirmed", "by": "judge"}\n' 0 1 >"$b3/verdicts.jsonl"
printf '{"kind": "fixer", "finding": %d, "outcome": "fixed"}\n' 0 1 >>"$b3/verdicts.jsonl"
printf '{"file": "llm-legs/app.py", "line": %d, "summary": "s"}\n' 50 52 >"$b3/findings-opus-high.jsonl"
fa apply >/dev/null || fail "apply R3"
sizes() {
  python3 - "$ROOT/share" "$@" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import fix_audit
ledger = fix_audit.load()
for ident in sys.argv[2:]:
    row = fix_audit.ledger_row(ident, ledger)
    made = fix_audit.packet(row, 1, fix_audit.peers(row, ledger))
    print(ident, fix_audit.fix_size(row, ledger), made and "+line_10 = 1" in made[0], made and "+line_40 = 4" in made[0])
EOF
}
out=$(sizes "$R1/F0" "$R3/F0" "$R3/F1") || fail "sizes: $out"
assert grep -qxF "$R1/F0 (1, 0) True False" <<<"$out"
assert grep -qxF "$R3/F0 (1, 0) False False" <<<"$out"
assert grep -qxF "$R3/F1 (0, None) None None" <<<"$out"
k3="$FIX_AUDIT_DIR/2026-01-12-key"
mkdir -p "$k3"
printf 'item\tverdict\tconfidence\treason\tevidence\n01\tfalse\thigh\tno such problem\tapp.py:52\n' >"$k3/v.tsv"
jq -n --arg id "$R3/F1" --arg out "$k3/v.tsv" \
  '{items: {"01": {id: $id, net_lines: 0}}, chunks: [{judge: "claude", items: ["01"], out: $out}]}' >"$k3/key.json"
fa apply >/dev/null || fail "apply the read of before"
assert test "$(row "$R3/F1" '[.verdict, .hunks, .net_lines]')" = '["false",0,null]'
assert test -z "$(harness_rows)"

printf 'PASS: %s asserts; fixer commits map to their findings by round and position (a round-only commit to all its fixed findings), the weekly read is blind, outside the judge family or Opus, and once a week, apply records verdicts, a false fix raises a Harness row until its revert lands, a hunk counts for a finding only on evidence (never nearness) and one with none raises no revert, readers run in workdirs of their own and a rerun reads only the unread batches\n' "$asserts"
