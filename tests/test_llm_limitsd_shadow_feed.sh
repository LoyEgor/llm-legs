#!/usr/bin/env bash
# Hermetic tests for bin/llm-limitsd-shadow-feed (read-only cache -> shadow-ledger bridge).
# A fixture cache + a child daemon on an ephemeral port + a temp state file. Nothing here touches
# the live daemon (45789/45791), the real ~/.llm-limits.json, or the real .claudeb store.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$ROOT/bin/llm-limitsd"
FEED="$ROOT/bin/llm-limitsd-shadow-feed"
WORK="$(mktemp -d)"
PORT=""
DPID=""
B=""

asserts=0
fail() { echo "FAIL: $*" >&2; stop_daemon; rm -rf "$WORK"; exit 1; }
ok() { asserts=$((asserts + 1)); }

stop_daemon() {
  [ -z "$DPID" ] || kill "$DPID" 2>/dev/null || true
  DPID=""
}
cleanup() { stop_daemon; rm -rf "$WORK"; }
trap cleanup EXIT

start_daemon() {
  local db="$1" proj="$2"
  local errlog="$WORK/err.$$.$RANDOM.log"
  env LLM_LIMITSD_PORT=0 LLM_LIMITSD_DB="$db" LLM_LIMITSD_PROJECTION="$proj" \
    "$DAEMON" 2>"$errlog" &
  DPID=$!
  local i
  for i in $(seq 1 200); do
    PORT="$(sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' "$errlog" 2>/dev/null | head -1)"
    [ -n "$PORT" ] && break
    kill -0 "$DPID" 2>/dev/null || { echo "daemon died on boot:" >&2; cat "$errlog" >&2; return 1; }
    perl -e 'select(undef,undef,undef,0.02)'
  done
  [ -n "$PORT" ] || { echo "daemon never announced a port" >&2; cat "$errlog" >&2; return 1; }
  [ "$PORT" = "45789" ] && { echo "refusing data-plane port 45789" >&2; return 1; }
  B="127.0.0.1:$PORT"
}

GET() { curl -s "$B$1"; }

obs_count() { python3 - "$1" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM observations").fetchone()[0])
PY
}
obs_acct_scope() { python3 - "$1" "$2" "$3" <<'PY'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute(
    "SELECT COUNT(*) FROM observations WHERE account=? AND scope=?",
    (sys.argv[2], sys.argv[3])).fetchone()[0])
PY
}

DB="$WORK/feed.sqlite"; PROJ="$WORK/feed.proj.json"
CACHE="$WORK/cache.json"; STATE="$WORK/feed.state"

now=$(date +%s)
r5=$(date -u -r $((now + 3600)) +%Y-%m-%dT%H:%M:%SZ)
rw=$(date -u -r $((now + 7200)) +%Y-%m-%dT%H:%M:%SZ)
fetched="$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)"

cat >"$CACHE" <<JSON
{
  "fetched_at": "$fetched",
  "schema": 1,
  "vendors": {
    "claude": {
      "accounts": [
        {"account": "alona", "is_current": true, "enabled": true,
         "as_of": "$fetched", "auth": {"status": "ok", "checked_at": $now},
         "five_hour": {"used_pct": 12, "resets_at": "$r5", "as_of": $now, "origin": "usage"},
         "weekly": {"used_pct": 40, "resets_at": "$rw", "as_of": $now, "origin": "usage"}},
        {"account": "old", "is_current": false, "enabled": false,
         "as_of": "$fetched", "auth": {"status": "expired", "checked_at": $now},
         "five_hour": {"used_pct": 88, "resets_at": "$r5", "as_of": $now, "origin": "cached"}},
        {"account": "broke", "is_current": false, "enabled": true,
         "as_of": "$fetched", "auth": {"status": "failed", "checked_at": $now},
         "five_hour": {"used_pct": 5, "resets_at": "$r5", "as_of": $now, "origin": "usage"}},
        {"account": "weird", "is_current": false, "enabled": true,
         "as_of": "$fetched", "auth": {"status": "zombie", "checked_at": $now},
         "five_hour": {"used_pct": 7, "resets_at": "$r5", "as_of": $now, "origin": "usage"}}
      ]
    },
    "codex": {
      "accounts": [
        {"account": "main", "is_current": true, "enabled": true, "as_of": "$fetched",
         "five_hour": {"used_pct": null, "resets_at": null, "as_of": $now, "origin": "usage"},
         "weekly": {"used_pct": 78, "resets_at": "$rw", "as_of": $now, "origin": "usage"}},
        {"account": "work", "is_current": false, "enabled": true, "as_of": "$fetched",
         "auth_needed": true, "error": "authentication required"}
      ]
    },
    "gemini": {
      "available": true, "source": "agy-local-rpc", "as_of": "$fetched",
      "five_hour": {"used_pct": 0, "resets_at": "$r5", "as_of": $now, "origin": "usage"},
      "weekly": {"used_pct": 75, "resets_at": "$rw", "as_of": $now, "origin": "usage"}
    }
  }
}
JSON

feed() { env LLM_LIMITS_CACHE="$CACHE" LLM_LIMITSD_URL="http://$B" LLM_SHADOW_FEED_STATE="$STATE" "$FEED"; }

echo "== feeder file is executable =="
[ -x "$FEED" ] || fail "bin/llm-limitsd-shadow-feed lost its executable bit"
ok

echo "== first feed posts fixture buckets, lands in /state with used_pct/resets_at =="
start_daemon "$DB" "$PROJ" || fail "daemon boot"
feed 2>"$WORK/feed1.err" || fail "first feed exit nonzero"
GET /state | jq -e --arg r "$r5" \
  '.accounts[] | select(.account=="alona" and .vendor=="claude")
   | .buckets.five_hour.used_pct == 12 and .buckets.five_hour.resets_at == $r' >/dev/null \
  || fail "alona five_hour used_pct/resets_at not mirrored"
GET /state | jq -e '.accounts[] | select(.account=="alona" and .vendor=="claude")
   | .buckets.weekly.used_pct == 40' >/dev/null || fail "alona weekly not mirrored"
GET /state | jq -e '.accounts[] | select(.account=="main" and .vendor=="codex")
   | .buckets.five_hour.used_pct == null' >/dev/null || fail "codex null used_pct not posted as null"
ok

echo "== auth: evidenced ok and expired both mirrored; absent auth object posts nothing =="
[ "$(obs_acct_scope "$DB" alona auth)" = "1" ] || fail "auth-ok account missing its auth observation"
[ "$(obs_acct_scope "$DB" old auth)" = "1" ] || fail "auth-expired account missing its auth observation"
[ "$(obs_acct_scope "$DB" main auth)" = "0" ] || fail "codex account (no auth object) got an auth observation"
GET /state | jq -e '.accounts[] | select(.account=="old" and .vendor=="claude") | .auth == "expired"' >/dev/null \
  || fail "expired verdict not reflected in /state"
ok

echo "== auth status: failed maps to expired; unknown status default-denied and counted =="
[ "$(obs_acct_scope "$DB" broke auth)" = "1" ] || fail "failed status did not post an auth observation"
GET /state | jq -e '.accounts[] | select(.account=="broke" and .vendor=="claude") | .auth == "expired"' >/dev/null \
  || fail "failed status not mapped to expired verdict"
[ "$(obs_acct_scope "$DB" weird auth)" = "0" ] || fail "unknown auth status was posted instead of default-denied"
grep -qi 'unknown auth status' "$WORK/feed1.err" || fail "unknown auth status not reported on stderr"
grep -q 'claude/weird=zombie' "$WORK/feed1.err" || fail "unknown auth status not itemized on stderr"
ok

echo "== codex auth_needed reads as login-needed, never healthy =="
[ "$(obs_acct_scope "$DB" work auth)" = "1" ] || fail "auth_needed account posted no auth observation"
jq -e '.vendors.codex.accounts[] | select(.account=="work") | .auth_needed == true and .auth.status == "expired"' "$PROJ" >/dev/null \
  || fail "auth_needed not surfaced in projection"
jq -e '.vendors.codex.accounts[] | select(.account=="work") | .rotation.usable.general == false' "$PROJ" >/dev/null \
  || fail "auth_needed account still usable in projection"
GET /state | jq -e '.accounts[] | select(.account=="work" and .vendor=="codex") | .auth != "ok"' >/dev/null \
  || fail "auth_needed account reads healthy in /state"
ok

echo "== gemini accountless: vendor-level buckets, no fake accounts array =="
jq -e --arg r "$r5" '.vendors.gemini.five_hour.used_pct == 0 and .vendors.gemini.five_hour.resets_at == $r' "$PROJ" >/dev/null \
  || fail "gemini five_hour not projected at vendor level"
jq -e '.vendors.gemini.weekly.used_pct == 75' "$PROJ" >/dev/null || fail "gemini weekly not projected at vendor level"
jq -e '.vendors.gemini | has("accounts") | not' "$PROJ" >/dev/null || fail "gemini projection carries a fake accounts array"
jq -e '.vendors.gemini.available == true' "$PROJ" >/dev/null || fail "gemini not available"
ok

echo "== healed account flips ledger back to ok (expired must not stick) =="
later=$((now + 60)); fetched2="$(date -u -r "$later" +%Y-%m-%dT%H:%M:%SZ)"
sed -i '' -e "s/\"status\": \"expired\"/\"status\": \"ok\"/" -e "s/$fetched/$fetched2/g" \
  -e "s/\"checked_at\": $now/\"checked_at\": $later/g" "$CACHE"
feed || fail "heal feed exit nonzero"
GET /state | jq -e '.accounts[] | select(.account=="old" and .vendor=="claude") | .auth == "ok"' >/dev/null \
  || fail "healed account still expired in ledger"
ok

echo "== rotation enabled/is_current mirrored in projection =="
jq -e '.vendors.claude.accounts[] | select(.account=="alona") | .is_current == true and .enabled == true' "$PROJ" >/dev/null || fail "alona rotation not mirrored"
jq -e '.vendors.claude.accounts[] | select(.account=="old") | .is_current == false and .enabled == false' "$PROJ" >/dev/null || fail "old rotation (disabled) not mirrored"
jq -e '.vendors.claude.current_account == "alona"' "$PROJ" >/dev/null || fail "current_account not alona"
ok

echo "== second feed with unchanged fetched_at posts nothing =="
count_before="$(obs_count "$DB")"
feed || fail "second feed exit nonzero"
count_after="$(obs_count "$DB")"
[ "$count_before" = "$count_after" ] || fail "unchanged fetched_at re-posted ($count_before -> $count_after)"
ok

echo "== daemon unreachable -> nonzero exit, stderr cause =="
errf="$WORK/unreach.err"
env LLM_LIMITS_CACHE="$CACHE" LLM_LIMITSD_URL="http://127.0.0.1:45999" LLM_SHADOW_FEED_STATE="$WORK/u.state" "$FEED" 2>"$errf"
rc=$?
[ "$rc" != "0" ] || fail "unreachable daemon returned exit 0"
grep -qi 'unreachable' "$errf" || fail "unreachable cause not on stderr"
ok

echo "== malformed cache -> nonzero, no partial posts, no state write =="
BADCACHE="$WORK/bad.json"; BADSTATE="$WORK/bad.state"
printf 'this is not json {[' >"$BADCACHE"
before="$(obs_count "$DB")"
env LLM_LIMITS_CACHE="$BADCACHE" LLM_LIMITSD_URL="http://$B" LLM_SHADOW_FEED_STATE="$BADSTATE" "$FEED" 2>"$WORK/bad.err"
rc=$?
[ "$rc" != "0" ] || fail "malformed cache returned exit 0"
grep -qi 'malformed' "$WORK/bad.err" || fail "malformed cause not on stderr"
[ ! -e "$BADSTATE" ] || fail "state file written on malformed-cache failure"
[ "$(obs_count "$DB")" = "$before" ] || fail "malformed-cache run still posted observations"
ok

echo "== state file holds the posted cache fetched_at =="
[ -f "$STATE" ] || fail "state not written after successful feed"
[ "$(cat "$STATE")" = "$fetched2" ] || fail "state does not hold cache fetched_at"
ok

echo "== a fresh fetched_at re-feeds (state gate is by fetched_at) =="
sed -i.bak "s/\"fetched_at\": \"$fetched2\"/\"fetched_at\": \"$(date -u -r $((now + 120)) +%Y-%m-%dT%H:%M:%SZ)\"/" "$CACHE"
before="$(obs_count "$DB")"
feed || fail "feed after fetched_at change exit nonzero"
[ "$(obs_count "$DB")" -gt "$before" ] || fail "changed fetched_at did not re-post"
ok

stop_daemon
echo "PASS: $asserts assertions"
