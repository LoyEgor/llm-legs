#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# bin/page + share/pages/store.py against share/pages/CONTRACT.md: a temp PAGES_DIR and port 0 only, never ~/Pages.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(cd -P "$(mktemp -d)" && pwd)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT
asserts=0
PAGE="$ROOT/bin/page"
matches() { [[ $1 =~ $2 ]]; }
like() { [[ $1 == $2 ]]; }
mkdir -p "$WORK/bin" "$WORK/kit"
printf '#!/bin/sh\necho "{\\"name\\": \\"pixel chat\\"}"\n' >"$WORK/bin/chat-name"
chmod +x "$WORK/bin/chat-name"
echo loader >"$WORK/kit/loader.html"
printf '# compare: variants side by side\n' >"$WORK/kit/compare.md"
printf '# cards: numbered cards\n' >"$WORK/kit/cards.md"
echo secret >"$WORK/secret.txt"
printf '{"media": [{"path": "%s/secret.txt"}]}' "$WORK" >"$WORK/meta.json"
export PATH="$WORK/bin:$PATH" PAGES_DIR="$WORK/pages" PAGES_KIT_DIR="$WORK/kit" CLAUDE_CODE_SESSION_ID=chat-own
unset CLAUDE_LAUNCHER_SESSION
head -c 9500000 /dev/urandom >"$WORK/big.png"
head -c 1000 /dev/urandom >"$WORK/a.png"
head -c 2000 /dev/urandom >"$WORK/b.png"
head -c 3000 /dev/urandom >"$WORK/c.png"
spec() { # second-variant-file [extra item json]
  printf '{"blind": true, "_note": "top", "items": [{"id": "p01", "original": "%s/big.png", "_expected": "v78",
    "suggest": {"choice": "B"}, "variants": [{"id": "v77", "label": "champ77", "src": "%s/big.png", "_why": "x"},
    {"id": "v78", "label": "champ78", "src": "%s/%s"}]}, {"id": "p02", "variants": [{"id": "w1", "src": "%s/b.png"}]}%s]}' \
    "$WORK" "$WORK" "$WORK" "$1" "$WORK" "${2:-}"
}

# The store refuses a test run without its own PAGES_DIR, or one pointed at ~/Pages.
assert_fails env -u PAGES_DIR "$PAGE" list --all 2>/dev/null
assert test "$(env -u PAGES_DIR "$PAGE" list --all 2>&1)" = "page: PAGES_DIR must be a temp dir under a test run, never unset or ~/Pages"
assert_fails env PAGES_DIR="$HOME/Pages" "$PAGE" list --all 2>/dev/null

# Owner: the launcher wins, then the session, then --chat; none refuses in one line.
spec a.png | "$PAGE" new compare --slug calib --title Calib --no-open >"$WORK/new.out" || fail "page new: $(cat "$WORK/new.out")"
pid=$(awk '{print $2}' "$WORK/new.out")
assert matches "$pid" "^calib-[a-z0-9]{6}$"
assert test "$(readlink "$PAGES_DIR/.by-session/chat-own/$pid")" = "../../$pid"
assert test "$(jq -r .chat_name "$PAGES_DIR/$pid/meta.json")" = "pixel chat"
spec b.png | CLAUDE_LAUNCHER_SESSION=chat-boss "$PAGE" new compare --slug calib --no-open >"$WORK/boss.out"
boss=$(awk '{print $2}' "$WORK/boss.out")
assert test "$boss" != "$pid"
assert test -L "$PAGES_DIR/.by-session/chat-boss/$boss"
spec b.png | env -u CLAUDE_CODE_SESSION_ID "$PAGE" new compare --slug other --chat chat-flag --no-open >/dev/null
assert test -n "$(ls "$PAGES_DIR/.by-session/chat-flag")"
assert_fails env -u CLAUDE_CODE_SESSION_ID "$PAGE" list --chat ../../x 2>/dev/null
out=$(spec b.png | env -u CLAUDE_CODE_SESSION_ID "$PAGE" new compare --slug orphan --no-open 2>&1)
assert test "$?" = 1
assert test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1
assert like "$out" "page: no owner chat*"
assert_fails sh -c "printf '{\"items\": [{\"id\": \"bad id\"}]}' | '$PAGE' new compare --slug x --no-open 2>/dev/null"
assert_fails sh -c "printf '{\"items\": [{\"id\": \"a\", \"src\": \"/nope.png\"}]}' | '$PAGE' new compare --slug x --no-open 2>/dev/null"
assert_fails sh -c "printf '{\"items\": [{\"id\": \"a\"}]}' | '$PAGE' new gallery --slug x --no-open 2>/dev/null"

# Server on port 0; a second server on that port sees it is ours and exits 0.
"$PAGE" serve --port 0 >"$WORK/serve.out" 2>&1 &
"$ROOT/bin/wait-until" --max 10 log "$WORK/serve.out" 'page serve: http' >/dev/null || fail "serve: $(cat "$WORK/serve.out")"
port=$(sed -n 's|^page serve: http://127.0.0.1:\([0-9]*\) .*|\1|p' "$WORK/serve.out")
base="http://127.0.0.1:$port"
assert "$PAGE" serve --port "$port" 2>/dev/null
get() { curl -s --path-as-is -o "$WORK/body" -w '%{http_code}' "$@"; }
post() { # body [curl args] -> status
  curl -s -o "$WORK/body" -w '%{http_code}' -H 'Content-Type: application/json' -d "$1" "${@:2}" "$base/p/$pid/patch"
}

# Served spec: no key fields, blind slots without id/label, stable across calls.
assert test "$(get "$base/p/$pid/spec")" = 200
cp "$WORK/body" "$WORK/spec1"
assert test "$(get "$base/p/$pid/spec")" = 200
assert cmp -s "$WORK/spec1" "$WORK/body"
assert test "$(grep -c '"_\|v77\|champ\|'"$WORK" "$WORK/spec1")" = 0
assert test "$(jq -r '[.items[0].variants[].slot] | join(",")' "$WORK/spec1")" = "A,B"
assert test "$(jq -r '.pid, .rev' "$WORK/spec1" | paste -sd' ' -)" = "$pid 1"
assert test "$(jq -r '._note, .items.p01._expected, .items.p01.variants.v77._why' "$PAGES_DIR/$pid/key.json" | paste -sd' ' -)" = "top v78 x"

# Per-field merge, op dedup, 409 on an unknown item, torn trailing line skipped.
assert test "$(post '{"op": "o1", "item": "p01", "fields": {"note": "old"}, "spec_rev": 1}')" = 200
assert test "$(post '{"op": "o2", "item": "p01", "fields": {"choice": "A"}, "spec_rev": 1}')" = 200
assert test "$(post '{"op": "o3", "item": "p01", "fields": {"note": "stale tab"}, "spec_rev": 1}')" = 200
assert test "$(jq -c . "$WORK/body")" = '{"rev":3,"spec_rev":1,"dup":false}'
assert test "$(post '{"op": "o3", "item": "p01", "fields": {"note": "again"}}')" = 200
assert test "$(jq -c . "$WORK/body")" = '{"rev":3,"spec_rev":1,"dup":true}'
assert test "$(post '{"op": "o4", "item": "p99", "fields": {"choice": "A"}}')" = 409
get "$base/p/$pid/state" >/dev/null
assert test "$(jq -c '[.rev, .items.p01.choice.v, .items.p01.note.v, .items.p01.note.by]' "$WORK/body")" = '[3,"A","stale tab","egor"]'
printf '{"op": "torn", "item": "p01", "fie' >>"$PAGES_DIR/$pid/log.jsonl"
get "$base/p/$pid/state" >/dev/null
assert test "$(jq .rev "$WORK/body")" = 3
assert test "$(post '{"op": "o5", "item": "p02", "fields": {"choice": "A"}}')" = 200
get "$base/p/$pid/state" >/dev/null
assert test "$(jq -c '[.rev, .items.p02.choice.v]' "$WORK/body")" = '[4,"A"]'
assert test "$(post '{"op": "o6", "item": "p02", "fields": {"choice": null}}')" = 200
get "$base/p/$pid/state" >/dev/null
assert test "$(jq -c '.items.p02' "$WORK/body")" = null

# Host, Origin and Content-Type refusals.
assert test "$(get -H 'Host: evil.example:80' "$base/p/$pid/state")" = 403
assert test "$(get -H "Host: localhost:$port" "$base/p/$pid/state")" = 200
assert test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: text/plain' -d '{}' "$base/p/$pid/patch")" = 403
assert test "$(post '{"op": "x1", "item": "p01", "fields": {"note": "n"}}' -H 'Origin: http://evil.example')" = 403
assert test "$(post '{"op": "x2", "item": "p01", "fields": {"note": "n"}}' -H "Origin: http://127.0.0.1:$port")" = 200

# Path confinement: bad pids 404 before any join, the kit never serves outside itself.
for bad in "/p/..%2F..%2Fetc/spec" "/p/../m/0" "/p/%2e%2e/m/0""/p/CALIB/spec" "/kit/../secret.txt" "/kit/%2e%2e/secret.txt" \
  "/p/$pid/m/3" "/p/$pid/m/-1" "/p/$pid/m/x"; do
  assert test "$(get "$base$bad")$bad" = "404$bad"
done
assert test "$(get "$base/p/$pid/")$(cat "$WORK/body")" = 200loader
assert test "$(get "$base/healthz")$(jq -r .pages "$WORK/body")" = 2001

"$PAGE" help >"$WORK/help.out"
assert test "$(head -2 "$WORK/help.out" | paste -sd'|' -)" = "cards    numbered cards|compare  variants side by side"

# Media: 206 Range, chunked full body, an open-ended range capped at 8 MB, out-of-bounds 416, ETag 304.
size=9500000
assert test "$(get -D "$WORK/h" -H 'Range: bytes=100-199' "$base/p/$pid/m/0")" = 206
assert grep -qi "^content-range: bytes 100-199/$size" "$WORK/h"
assert cmp -s "$WORK/body" <(tail -c +101 "$WORK/big.png" | head -c 100)
assert test "$(get -D "$WORK/h" -H 'Range: bytes=1000-' "$base/p/$pid/m/0")" = 206
assert test "$(wc -c <"$WORK/body" | tr -d ' ')" = 8388608
assert grep -qi "^content-range: bytes 1000-8389607/$size" "$WORK/h"
assert test "$(get -H 'Range: bytes=-500' "$base/p/$pid/m/0")$(wc -c <"$WORK/body" | tr -d ' ')" = 206500
assert test "$(get -H "Range: bytes=$size-" "$base/p/$pid/m/0")" = 416
assert test "$(get -D "$WORK/h" "$base/p/$pid/m/0")" = 200
assert cmp -s "$WORK/body" "$WORK/big.png"
assert grep -qi '^cache-control: private, max-age=31536000, immutable' "$WORK/h"
etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]: //p' "$WORK/h" | tr -d '\r')
assert test "$(get -H "If-None-Match: $etag" "$base/p/$pid/m/0")" = 304

# State: blind slots unblinded for the chat, suggest and _expected beside the answer; the cursor advances.
"$PAGE" state calib >"$WORK/state1"
slot_a=$(jq -r .blind.p01.A "$PAGES_DIR/$pid/key.json")
assert grep -qx "p01 choice=A($slot_a) suggest=B _expected=v78 note=n by=egor" "$WORK/state1"
assert grep -qx 'p02 cleared' "$WORK/state1"
assert test "$(tail -1 "$WORK/state1")" = "answered=1/2 rev=6 spec_rev=1"
assert test "$("$PAGE" state calib)" = "answered=1/2 rev=6 spec_rev=1"
assert test "$("$PAGE" state "$pid" --all | wc -l | tr -d ' ')" = 3
"$PAGE" set calib p02 note=from-chat >/dev/null
assert test "$("$PAGE" state calib)" = "$(printf 'p02 note=from-chat by=chat\nanswered=1/2 rev=7 spec_rev=1')"
assert_fails env CLAUDE_CODE_SESSION_ID=chat-stranger "$PAGE" state calib 2>/dev/null

# Update: same slug, same owner, same pid; allowlist rebuilt; judged media change needs --replace.
old_copy=$(jq -r '.media[1].path' "$PAGES_DIR/$pid/meta.json")
out=$(spec c.png | "$PAGE" new compare --slug calib --no-open 2>&1)
assert test "$?" = 1
assert like "$out" "*item p01 has answers*--replace p01*"
assert test "$(jq .rev "$PAGES_DIR/$pid/spec.json")" = 1
spec c.png ', {"id": "p03", "src": "'"$WORK"'/b.png"}' | "$PAGE" new compare --slug calib --replace p01 --no-open >"$WORK/upd.out"
assert test "$(cat "$WORK/upd.out")" = "updated $pid http://127.0.0.1:4791/p/$pid/"
assert test "$(jq .rev "$PAGES_DIR/$pid/spec.json")" = 2
assert test "$(jq -r '[.media[].src | sub(".*/"; "")] | join(",")' "$PAGES_DIR/$pid/meta.json")" = big.png,c.png,b.png
assert test ! -e "$old_copy"
assert test "$(ls "$PAGES_DIR/$pid/media" | wc -l | tr -d ' ')" = 3
get "$base/p/$pid/state" >/dev/null
assert test "$(jq -c '[.spec_rev, .items.p01, .items.p02.note.v]' "$WORK/body")" = '[2,null,"from-chat"]'
assert test "$(tail -1 "$PAGES_DIR/$pid/log.jsonl" | jq -cS '[.by, .item, .fields]')" = '["chat","p01",{"choice":null,"note":null}]'
assert test "$(get "$base/p/$pid/m/3")" = 404
assert test "$(get "$base/p/$pid/m/2")" = 200

echo "PASS: $asserts asserts; test_pages.sh: test guard, owner resolution, validation, served spec without key fields and with stable blind slots, per-field merge, op dedup, torn line, Host/Origin/Content-Type, path confinement, media Range/cap/ETag, state cursor and unblinding, update allowlist and --replace gate"
