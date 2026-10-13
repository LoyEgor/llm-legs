#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# share/merge_ledger.py, the `ledger-rows` merge driver .gitattributes gives share/*-ledger.json: parallel
# branches that append or replace rows rebase clean, a row only one side changed takes that side, two different
# changes conflict around that row, and a file that is no ledger falls back to git's line merge.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$(mktemp -d)
WORK=$(cd -P "$WORK" && pwd)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }

export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global user.name t && git config --global user.email t@t && git config --global init.defaultBranch main
DRIVER=${MERGE_LEDGER_DRIVER:-"$ROOT/share/merge_ledger.py"}
L=share/spend-ledger.json

has_line() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }
attrs=$(git -C "$ROOT" check-attr merge linguist-generated -- share/{spend,harness,doctor,code,system,updater}-ledger.json)
for name in spend harness doctor code system updater; do
  assert has_line "$attrs" "share/$name-ledger.json: merge: ledger-rows"
done
assert has_line "$attrs" "share/harness-ledger.json: linguist-generated: set"

edit() { # file python-statements-over-d: rewrite a ledger in the indent-1 layout
  python3 - "$1" "$2" <<'EOF'
import json, sys
path, code = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    d = json.load(handle)
row = lambda i, v="v1": {"id": i, "title": "ряд " + i, "value": v, "nested": {"list": [1, 2], "on": True}}
exec(code)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(d, ensure_ascii=False, indent=1) + "\n")
EOF
}
facts() { # one interpreter reads the merged ledger; fact <key> picks a line of its answer
  F=$(python3 - "$R/$L" <<'EOF'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
try:
    d = json.loads(text)
except ValueError:
    print("valid=False")
    sys.exit()
print("valid=True")
print("ids=" + " ".join(r["id"] for r in d["rows"]))
print("canon=%s" % (json.dumps(d, ensure_ascii=False, indent=1) + "\n" == text))
print("owner=%s" % d.get("owner"))
print("blind_spots=%s" % d.get("blind_spots"))
print("bs=" + " ".join(b["id"] + "=" + b["what"] for b in d.get("blind_spots") or []))
for r in d["rows"]:
    print("value-%s=%s" % (r["id"], r["value"]))
EOF
)
}
fact() { sed -n "s/^$1=//p" <<<"$F"; }

setup() { # name -> a repository at $R with the base ledger on main and branch feature at the same commit
  R="$WORK/$1"
  if [ ! -d "$WORK/base-repo" ]; then
    mkdir -p "$WORK/base-repo/share"
    git -C "$WORK/base-repo" init -q
    grep 'merge=ledger-rows' "$ROOT/.gitattributes" >"$WORK/base-repo/.gitattributes"
    printf '{\n "owner": "Harness Doctor",\n "rows": []\n}\n' >"$WORK/base-repo/$L"
    edit "$WORK/base-repo/$L" 'd["rows"] = [row("r1"), row("r2"), row("r3")]'
    git -C "$WORK/base-repo" add -A && git -C "$WORK/base-repo" commit -qm base
    git -C "$WORK/base-repo" branch feature
  fi
  cp -R "$WORK/base-repo" "$R"
}
on() { git -C "$R" switch -q "$1"; }
save() { git -C "$R" commit -qam "$1"; }
rebase() { git -C "$R" -c merge.ledger-rows.name=ledger -c merge.ledger-rows.driver="$DRIVER %O %A %B %P" \
  rebase main feature >"$WORK/rebase.out" 2>&1; }
conflicted() { git -C "$R" diff --name-only --diff-filter=U; }

setup append
on main; edit "$R/$L" 'd["rows"].append(row("main-new"))'; save main
on feature; edit "$R/$L" 'd["rows"].append(row("feature-new"))'; save feature
git -C "$R" show main:"$L" >"$WORK/main.json"
assert rebase
facts
assert test "$(fact valid)" = True
assert test "$(fact ids)" = "r1 r2 r3 main-new feature-new"
assert test -z "$(diff "$WORK/main.json" "$R/$L" | grep "^<")"
assert test "$(fact canon)" = True
assert grep -q '"title": "ряд feature-new"' "$R/$L"

setup stale
on main; edit "$R/$L" 'd["rows"] = [r for r in d["rows"] if r["id"] != "r1"] + [row("r1", "v2")]; d["owner"] = "main owner"'
save main
on feature; edit "$R/$L" 'd["rows"].append(row("y")); d["rows"] = [r for r in d["rows"] if r["id"] != "r3"]'; save feature
assert rebase
facts
assert test "$(fact value-r1)" = v2
assert test "$(fact ids)" = "r2 r1 y"
assert test "$(fact owner)" = "main owner"

setup newer-on-branch
on main; edit "$R/$L" 'd["rows"].append(row("y")); d["blind_spots"] = []'; save main
on feature; edit "$R/$L" 'd["rows"][0]["value"] = "v2"'; save feature
assert rebase
facts
assert test "$(fact value-r1)" = v2
assert test "$(fact ids)" = "r1 r2 r3 y"
assert test "$(fact blind_spots)" = "[]"

setup blind-spots
on main; edit "$R/$L" 'd["blind_spots"] = [{"id": "b1", "what": "base"}]'; save main
git -C "$R" branch -f feature main
on main; edit "$R/$L" 'd["blind_spots"].append({"id": "b-main", "what": "m"})'; save main
on feature; edit "$R/$L" 'd["blind_spots"][0]["what"] = "feature"; d["blind_spots"].append({"id": "b-feat", "what": "f"})'; save feature
assert rebase
facts
assert test "$(fact valid)" = True
assert test "$(fact bs)" = "b1=feature b-main=m b-feat=f"

setup both-changed
on main; edit "$R/$L" 'd["rows"][1]["value"] = "main"; d["rows"].append(row("m"))'; save main
on feature; edit "$R/$L" 'd["rows"][1]["value"] = "feature"; d["rows"].append(row("f"))'; save feature
assert test "$(rebase; echo $?)" != 0
assert test "$(conflicted)" = "$L"
assert grep -qx '<<<<<<< ours' "$R/$L"
assert grep -qx '>>>>>>> theirs' "$R/$L"
assert test "$(sed -n '/^<<<<<<< ours$/,/^>>>>>>> theirs$/p' "$R/$L" | grep -c '"id": "r2"')" = 2
assert grep -q '"value": "main"' "$R/$L"
assert grep -q '"value": "feature"' "$R/$L"
assert grep -q '"id": "m"' "$R/$L"
assert grep -q '"id": "f"' "$R/$L"
assert test "$(grep -c '"id": "r1"' "$R/$L")" = 1
git -C "$R" rebase --abort

setup delete-vs-change
on main; edit "$R/$L" 'd["rows"] = [r for r in d["rows"] if r["id"] != "r2"]'; save main
on feature; edit "$R/$L" 'd["rows"][1]["value"] = "feature"'; save feature
assert test "$(rebase; echo $?)" != 0
assert test "$(conflicted)" = "$L"
assert test "$(sed -n '/^<<<<<<< ours$/,/^=======$/p' "$R/$L" | grep -c '"id"')" = 0
assert test "$(sed -n '/^=======$/,/^>>>>>>> theirs$/p' "$R/$L" | grep -c '"value": "feature"')" = 1
git -C "$R" rebase --abort

setup malformed-clean
on main; edit "$R/$L" 'd["owner"] = "main owner"'; save main
on feature; sed -i '' 's/^ \]$/ ],/' "$R/$L"; save feature
assert test "$(rebase; echo $?)" != 0
assert test "$(conflicted)" = "$L"
assert grep -q '"owner": "main owner"' "$R/$L"
assert grep -qx ' ],' "$R/$L"
assert test "$(grep -c '"id": "r' "$R/$L")" = 3
assert test "$(grep -c '^<<<<<<<' "$R/$L")" = 0
git -C "$R" rebase --abort

setup malformed-conflict
on main; edit "$R/$L" 'd["rows"].append(row("main-new"))'; save main
on feature; edit "$R/$L" 'd["rows"].append(row("feature-new"))'; printf '{broken\n' >>"$R/$L"; save feature
assert test "$(rebase; echo $?)" != 0
assert test "$(conflicted)" = "$L"
assert grep -q '"id": "main-new"' "$R/$L"
assert grep -q '"id": "feature-new"' "$R/$L"
assert grep -qx '{broken' "$R/$L"
git -C "$R" rebase --abort

printf 'PASS: %d asserts\n' "$asserts"
