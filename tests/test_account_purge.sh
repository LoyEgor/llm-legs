#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# The menu's Remove (`<vendor>b remove <name>`) empties every per-account store share/account_stores.py
# lists for that vendor (shared-invariants row di), and an account still on the roster keeps its data.
# The stores are filled from the table itself, so a store added there is covered here unasked.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

unset XDG_CACHE_HOME WORKER_CLAIMS_DIR WORKER_WALLS_DIR GEMINI_WEB_DIR CHATGPT_WEB_DIR CLAUDEGPT_HOME \
  CODEXB_PROFILES_DIR GEMINIB_PROFILES_DIR GROKB_PROFILES_DIR LLM_LIMITS_GEMINI_ACCOUNTS_DIR \
  LLM_LIMITS_CODEX_CACHE LLM_LIMITS_CODEX_REMOVED LLM_LIMITS_GROK_CACHE GROKB_MAIN_GROK_HOME OPENCODE_GO_PROFILES \
  STATUSLINE_CACHE_DIR
export HOME="$WORK/home" CLAUDEB_DIR="$WORK/home/.claude-profiles/.claudeb"
export LLM_LIMITS_ANNOUNCE_CMD="$WORK/no-announce" PATH="$WORK/bin:$PATH"
mkdir -p "$HOME" "$WORK/bin" "$CLAUDEB_DIR/tokens"
printf '#!/usr/bin/env bash\nexit 0\n' >"$LLM_LIMITS_ANNOUNCE_CMD"
printf '#!/usr/bin/env bash\n[ "$1" = find-generic-password ] && exit 44\nexit 0\n' >"$WORK/bin/security"
chmod +x "$LLM_LIMITS_ANNOUNCE_CMD" "$WORK/bin/security"

# fill <vendor> <name>...: one entry per store and name; held <vendor> <name>: the stores still holding it.
stores() {
  PYTHONPATH="$ROOT/share" python3 - "$@" <<'PY'
import json, re, sys
import account_stores as a
command, vendor, names = sys.argv[1], sys.argv[2], sys.argv[3:]
for store in a.stores(vendor):
    if command == "held":
        print("\n".join(f"{store.label}: {name}" for name in names if name in store.held()))
        continue
    for name in names:
        if isinstance(store, a.Entries):
            path = store.folder() / re.sub(r"\(.*\)\?$", "", store.regex.pattern[1:-1].replace(
                f"(?P<name>{a.NAME})", name)).replace("\\", "")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.mkdir() if store.label.endswith("profile") or store.label == "gateway login" else path.touch()
        elif isinstance(store, a.JsonNames):
            path = store.folder() / store.file
            path.parent.mkdir(parents=True, exist_ok=True)
            data = json.loads(path.read_text()) if path.exists() else {}
            if store.lists:
                data.setdefault("agreed", []).append(name)
            else:
                data[name] = 1
            path.write_text(json.dumps(data))
        else:
            store.file().parent.mkdir(parents=True, exist_ok=True)
            with store.file().open("a") as handle:
                handle.write(name + "\n")
PY
}

check_vendor() { # vendor tool profile-dir remove-args...
  local vendor="$1" tool="$2" profile="$3" held out
  shift 3
  mkdir -p "$profile/gone" "$profile/kept"
  [ "$vendor" != claude ] || printf 'tok' >"$CLAUDEB_DIR/tokens/gone"
  stores fill "$vendor" gone kept
  assert test "$(stores held "$vendor" gone | grep -c .)" -ge 4
  out=$(bash "$ROOT/bin/$tool" remove gone "$@" 2>&1) || fail "$tool remove gone: $out"
  held=$(stores held "$vendor" gone)
  assert test -z "$held"
  assert test "$(grep -c "^$tool: purged /" <<<"$out")" -ge 4
  assert test "$(grep -c "purged" <<<"$out")" -eq "$(grep -c "^$tool: purged /" <<<"$out")"
  assert test "$(stores held "$vendor" kept | grep -c .)" -eq "$(PYTHONPATH="$ROOT/share" python3 -c \
    'import account_stores, sys; print(len(account_stores.stores(sys.argv[1])))' "$vendor")"
}

check_vendor codex codexb "$HOME/.codex-profiles" --force
check_vendor gemini geminib "$HOME/.gemini-profiles"
check_vendor grok grokb "$HOME/.grok-profiles" --force
check_vendor claude claudeb "$HOME/.claude-profiles" --force

# Off-roster data the doctor names is purged by the same table; a roster account is refused.
assert env PYTHONPATH="$ROOT/share" python3 "$ROOT/share/account_stores.py" purge codex gone --dry-run
assert test "$(python3 "$ROOT/share/account_stores.py" purge codex kept 2>&1; echo "rc=$?")" = \
  "account_stores: kept is still on the codex roster the menubar lists; remove it first
rc=2"
stores fill codex ghost
dry=$(python3 "$ROOT/share/account_stores.py" purge codex ghost --dry-run)
assert test -n "$(stores held codex ghost)"
assert test "$(grep -c . <<<"$dry")" -eq "$(stores held codex ghost | grep -c .)"
assert python3 "$ROOT/share/account_stores.py" purge codex ghost >/dev/null
assert test -z "$(stores held codex ghost)"
assert test -z "$(python3 "$ROOT/share/account_stores.py" remnants)"

# A wall writer killed before its mv and a running quota probe's lock belong to their account.
walls=$(PYTHONPATH="$ROOT/share" python3 -c 'import account_stores; print(account_stores._paths("codex")["walls"])')
kicks="$HOME/.cache/claude-statusline"
mkdir -p "$walls" "$kicks/codex-quota-kick-ghost.lock"
touch "$walls/codex-ghost.tmp.4242" "$kicks/codex-quota-kick-ghost"
assert test "$(python3 "$ROOT/share/account_stores.py" remnants)" = \
  "$(printf 'codex\tghost\trun-observed wall, statusline quota kick')"
assert python3 "$ROOT/share/account_stores.py" purge codex ghost >/dev/null
assert test ! -e "$walls/codex-ghost.tmp.4242" -a ! -e "$kicks/codex-quota-kick-ghost.lock"

# A failed pool path read or pool rewrite is an error line and exit 1, never a traceback.
fail_bash() { printf 'case "$BASH_EXECUTION_STRING" in *%s*) exit 3 ;; esac\n' "$1" >"$WORK/bash-env"; }
fail_bash worker_walls_path
out=$(BASH_ENV="$WORK/bash-env" python3 "$ROOT/share/account_stores.py" remnants 2>&1; echo "rc=$?")
assert grep -q '^account_stores: cannot read the claudeb pool paths' <<<"$out"
assert grep -qx 'rc=1' <<<"$out"
stores fill codex ghost
fail_bash worker_pool_set_disabled
out=$(BASH_ENV="$WORK/bash-env" python3 "$ROOT/share/account_stores.py" purge codex ghost 2>&1; echo "rc=$?")
assert grep -q '^account_stores: cannot rewrite .*/disabled without ghost$' <<<"$out"
assert grep -qx 'rc=1' <<<"$out"
assert python3 "$ROOT/share/account_stores.py" purge codex ghost >/dev/null
assert test -z "$(stores held codex ghost)"

# pipefail callers: an empty profiles directory, or one whose last entry is a file, still lists main.
mkdir -p "$WORK/codex-empty" "$WORK/codex-file"; touch "$WORK/codex-file/zz"
for dir in "$WORK/codex-empty" "$WORK/codex-file"; do
  assert env CODEXB_PROFILES_DIR="$dir" bash -c 'set -o pipefail; . "$1/share/account-roster.sh"
    account_roster_refuse t codex main' _ "$ROOT"
done

# Every worker-run start walks each roster: a basename fork per account was seconds a start under load.
roster_home="$WORK/roster-home"
mkdir -p "$roster_home/.claude-profiles/.claudeb/tokens" "$roster_home/.claude-profiles/.claudeb/limits" \
  "$roster_home/.claude-profiles/p1" "$roster_home/.codex-profiles/x1" "$roster_home/.gemini-profiles/g1" \
  "$roster_home/.grok-profiles/k1" "$WORK/fork-shim"
: >"$roster_home/.claude-profiles/.claudeb/tokens/t1"
: >"$roster_home/.claude-profiles/.claudeb/limits/l1.json"
printf '#!/bin/sh\necho "$*" >>"%s"\nexit 1\n' "$WORK/basename.log" >"$WORK/fork-shim/basename"
chmod +x "$WORK/fork-shim/basename"
out=$(env -u CLAUDEB_DIR HOME="$roster_home" PATH="$WORK/fork-shim:$PATH" bash -c '. "$1/share/account-roster.sh"
  gemini_base_home=$HOME gemini_profiles_dir=$HOME/.gemini-profiles
  claude_account_names; codex_account_names; gemini_account_names; grok_account_names' _ "$ROOT")
assert test "$(tr '\n' ' ' <<<"$out")" = 'l1 p1 t1 main x1 main g1 k1 '
assert test ! -e "$WORK/basename.log"

echo "PASS: $asserts asserts; every vendor's remove empties every per-account store of its table, a roster account keeps its data and is refused a purge, a dry run lists exactly what goes, and nothing is left for the doctor's remnant check"
