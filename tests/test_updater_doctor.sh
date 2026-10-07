#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}
jqe() { jq -e "$@" >/dev/null; }

HOME="$WORK/home"
STATE="$WORK/state"
OUT="$WORK/out"
export HOME
export VENDOR_CLI_UPDATE_STATE_DIR="$STATE" UPDATER_DOCTOR_DIR="$OUT" CODEXB_PROFILES_DIR="$WORK/profiles" \
  GROKB_CACHE_DIR="$WORK/grokb"
unset UPDATER_DOCTOR_LEDGER
DOCTOR="$ROOT/bin/updater-doctor"
DOC="$OUT/latest.json"
mkdir -p "$STATE/fingerprints" "$STATE/events" "$HOME/.codex" "$WORK/profiles/a" "$WORK/grokb"

ago() { date -u -r $((${2:-$(date +%s)} - $1)) +%Y-%m-%dT%H:%M:%SZ; } # seconds [base-epoch]
H=3600
D=86400

state() { # grok-checked-seconds-ago
  jq -n --arg c "$(ago 3600)" --arg g "$(ago "$1")" '{
    codex: {result: "updated", installed: "0.159.0", latest: "0.159.0", checked_at: $c},
    grok: {result: "busy", installed: "1.0.40", latest: "1.0.44", checked_at: $g},
    claude: {result: "install-failed", installed: "2.1.283", latest: "2.1.284", checked_at: $c}}' >"$STATE/state.json"
}
state 3600
logged=$(date +%s)
{
  printf '%s grok busy 1.0.40 -> 1.0.44\n' "$(ago $((60 * H)) "$logged")"
  printf '%s grok busy 1.0.40 -> 1.0.44\n' "$(ago $((36 * H)))"
  printf '%s grok busy 1.0.40 -> 1.0.44\n' "$(ago $((12 * H)))"
  printf '%s claude install-failed 2.1.283 -> 2.1.284\n' "$(ago $H "$logged")"
  printf '%s fingerprint gemini event gemini-x open: catalog\n' "$(ago $H)"
} >"$STATE/update.log"
fingerprint() { # vendor facets-json remote-failures-json
  jq -n --arg v "$1" --arg t "$(ago $H)" --argjson f "$2" --argjson r "$3" \
    '{vendor: $v, version: "1", checked_at: $t, facets: $f, remote_failures: $r}' >"$STATE/fingerprints/$1.json"
}
fingerprint codex '{"catalog": {"gpt-6-sol": {}}, "probe_failures": [], "foreign_clients": {"/Applications/ChatGPT.app/codex": "0.158.0"}}' '[]'
fingerprint grok '{"catalog": {"grok-4.7": {}}, "probe_failures": ["ids"]}' '[]'
fingerprint gemini '{"catalog": ["gemini-3.8-flash\tGemini 3.8 Flash", "gemini-3.8-pro\tPro", "gemini-3.7-flash\tOld",
  "gemini-4-a\tA", "gemini-4-b\tB"], "probe_failures": []}' '["catalog"]'
fingerprint claude '{"installs": {}, "probe_failures": [], "ids": ["claude-a", "claude-b"]}' '[]'
event() { # id vendor status created-ago launched-ago|- closed-ago|-
  jq -n --arg id "$1" --arg v "$2" --arg s "$3" --arg c "$(ago "$4")" \
    --arg l "$([ "$5" = - ] || ago "$5")" --arg x "$([ "$6" = - ] || ago "$6")" \
    '{id: $id, vendor: $v, status: $s, created_at: $c, from: "0.158.0", to: "0.159.0", reason: "fingerprint changed",
      changed: ["ids", "version"], substantive: ["ids"],
      launched_at: (if $l == "" then null else $l end), closed_at: (if $x == "" then null else $x end)}' >"$STATE/events/$1.json"
}
event codex-waiting codex open $((3 * D)) - -
printf '### ids\n+gpt-7\n' >"$STATE/events/codex-waiting.diff"
jq --arg d "$STATE/events/codex-waiting.diff" '.diff = $d' "$STATE/events/codex-waiting.json" >"$WORK/e" && mv "$WORK/e" "$STATE/events/codex-waiting.json"
event claude-stuck claude open $((4 * D)) $((3 * D)) -
event gemini-waiting gemini open $((3 * D)) - -
based() { # event-id base-facets-json
  : >"$STATE/events/$1.diff"
  jq -n --argjson f "$2" '{facets: $f}' >"$STATE/events/$1.base"
  jq --arg d "$STATE/events/$1.diff" '.diff = $d' "$STATE/events/$1.json" >"$WORK/e" && mv "$WORK/e" "$STATE/events/$1.json"
}
based claude-stuck '{"ids": ["claude-a"]}'
based gemini-waiting '{"catalog": ["gemini-3.7-flash\tOld"], "ids": []}'
event grok-fresh grok open $((2 * D)) $D -
event gemini-closed gemini closed $((5 * D)) $((5 * D)) $((4 * D))
for n in 1 2 3 4 5 6; do event "codex-old$n" codex closed $(((20 + n) * D)) $(((20 + n) * D)) $(((19 + n) * D)); done
cache() { # home client models-json
  jq -n --arg c "$2" --arg t "$(ago $H)" --argjson m "$3" '{client_version: $c, fetched_at: $t, models: $m}' >"$1/models_cache.json"
}
cache "$HOME/.codex" 0.159.0 '[{"slug":"gpt-6-sol","priority":3},{"slug":"gpt-reserve","priority":4,"visibility":"hide"},
  {"slug":"gpt-6.1-sol","priority":0},{"slug":"gpt-7","priority":1,"minimal_client_version":"0.160.0"},
  {"slug":"gpt-5.5","priority":8,"minimal_client_version":"0.150.0"}]'
cache "$WORK/profiles/a" 0.159.0 '[{"slug":"gpt-6-astra","priority":2}]'
mkdir -p "$WORK/profiles/old"
cache "$WORK/profiles/old" 0.150.0 '[{"slug":"gpt-4-old","priority":0}]'
printf '{"models":[{"slug":"grok-4.7"},{"slug":"grok-5"}]}\n' >"$WORK/grokb/models.json"

run() { "$DOCTOR" --quiet || fail "updater-doctor exited non-zero"; }
problem() { jq -c --arg id "$1" '.problems[] | select(.id == $id)' "$DOC"; }
has() { [ -n "$(problem "$1")" ]; }
state_of() { problem "$1" | jq -r .state; }

start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
run
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
assert test -s "$DOC"
assert [ -z "$(find "$OUT" -name '*.tmp')" ]
assert perl -e 'exit !($ARGV[1] - $ARGV[0] < 1)' "$start" "$end"
assert jqe '.self.collector_s < 1 and .self.error == null' "$DOC"

# The envelope of docs/doctors-contract.md §1, plus the doctor's own keys.
assert jqe '(keys - ["blind", "vendors"]) == (["contract", "doctor", "as_of", "as_of_s", "judge", "status", "problem_count", "problems", "blind_spots", "self"] | sort)' "$DOC"
assert jqe '.contract == 1 and .doctor == "updater" and (.judge | test("^[0-9a-f]{64}$"))' "$DOC"
assert jqe '.as_of | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$")' "$DOC"
assert jqe '(now - .as_of_s) < 60' "$DOC"
assert jqe '.problems | all(keys == (["id", "rule", "state", "fact", "value", "limit", "unit", "window_h", "exposure", "count", "first_seen", "last_seen", "evidence", "ledger"] | sort))' "$DOC"
assert jqe '.problems | all(.evidence | length <= 3 and all(keys == ["account", "at", "excerpt", "ref"] and (.excerpt | length) <= 300))' "$DOC"
assert jqe '.problem_count == ([.problems[] | select(.state == "new" or .state == "open" or .state == "regressed")] | length)' "$DOC"
assert jqe '.status == "problems" and .blind == []' "$DOC"
assert jqe '[.blind_spots[].id] == ["announced-not-served", "claude-catalog", "per-account-rollout"]' "$DOC"

# One problem per rule, identity-only ids.
assert jqe '.state == "new" and .fact == "codex 0.158.0 → 0.159.0: changed model ids · waiting 3d for integration" and .value >= 3 and .limit == 0 and .exposure == 4
  and .evidence[0].ref == "codex-waiting" and (.evidence[0].excerpt | test("\\+gpt-7"))' <<<"$(problem event-waiting:codex-waiting)"
assert jqe '.state == "new" and .value >= 3 and .limit == 2
  and .fact == "claude 0.158.0 → 0.159.0: new claude-b · integration chat open 3d, not closed"' <<<"$(problem event-stuck:claude-stuck)"
assert jqe '.fact == "gemini 0.158.0 → 0.159.0: new gemini-3.8-flash, gemini-3.8-pro, gemini-4-a +1 more · waiting 3d for integration"' <<<"$(problem event-waiting:gemini-waiting)"
assert_fails has event-stuck:grok-fresh
assert_fails has event-waiting:grok-fresh
assert_fails has event-waiting:gemini-closed
assert jqe '.state == "new" and .value == 1' <<<"$(problem probe-broken:grok/ids)"
# A probe broken across several events was first seen at the oldest of them.
event grok-probe-old grok closed $((10 * D)) $((10 * D)) $((9 * D))
event grok-probe-new grok closed $((2 * D)) $((2 * D)) $D
for e in grok-probe-old grok-probe-new; do
  jq '.changed = ["probe_failures"]' "$STATE/events/$e.json" >"$WORK/e" && mv "$WORK/e" "$STATE/events/$e.json"
done
run
assert [ "$(problem probe-broken:grok/ids | jq -r '.first_seen[:10]')" = "$(date -r $(($(date +%s) - 10 * D)) +%Y-%m-%d)" ]
rm "$STATE/events/grok-probe-old.json" "$STATE/events/grok-probe-new.json"
run
assert [ "$(state_of catalog-missing:gemini)" = watch ]
assert_fails has catalog-missing:claude
assert_fails has catalog-missing:grok
assert [ "$(state_of foreign-client:codex)" = watch ]
assert jqe '(.fact | test("ChatGPT.app/codex 0.158.0")) and .value == 1' <<<"$(problem foreign-client:codex)"
assert jqe '.state == "new" and .value > 24 and .limit == 24 and .count == 3 and .evidence[0].excerpt == "\(.evidence[0].ref) grok busy 1.0.40 -> 1.0.44"' <<<"$(problem cli-behind:grok)"
assert jqe --arg t "$(date -r $((logged - 60 * H)) +%H:%M)" '.fact == "grok 1.0.40 → 1.0.44 waiting: busy since \($t) · 60h"' <<<"$(problem cli-behind:grok)"
assert jqe --arg t "$(date -r $((logged - H)) +%H:%M)" '.state == "watch" and .fact == "claude 2.1.283 → 2.1.284 waiting: install-failed since \($t)"' <<<"$(problem cli-behind:claude)"
assert_fails has cli-behind:codex
assert jqe '.state == "new" and (.fact | test("install-failed")) and (.evidence[0].excerpt | test("claude install-failed"))' <<<"$(problem pass-failed:claude)"
assert_fails has pass-failed:grok
assert jqe '.value == "0.160.0" and .limit == "0.159.0"' <<<"$(problem client-too-old:codex/gpt-7)"
assert_fails has client-too-old:codex/gpt-5.5
assert_fails has pass-stale:state

# The menu's vendors: installed/latest, the catalog newest first, the last five events.
assert jqe '[.vendors[].vendor] == ["codex", "grok", "gemini", "claude"]' "$DOC"
assert jqe '.vendors[0] | keys == (["vendor", "installed", "latest", "checked_at", "result", "models", "events"] | sort)' "$DOC"
assert jqe '.vendors[0].models == ["gpt-6.1-sol", "gpt-7", "gpt-6-astra", "gpt-6-sol", "gpt-5.5"]' "$DOC"
assert jqe '.vendors[1].models == ["grok-4.7", "grok-5"] and .vendors[1].result == "busy" and .vendors[1].latest == "1.0.44"' "$DOC"
assert jqe '.vendors[2].models == ["gemini-3.8-flash", "gemini-3.8-pro", "gemini-3.7-flash", "gemini-4-a", "gemini-4-b"] and .vendors[3].models == []' "$DOC"

# A vendor whose catalog was never fetched has none to keep: that is missing too.
cp "$STATE/fingerprints/grok.json" "$WORK/grok.json"
jq 'del(.facets.catalog)' "$WORK/grok.json" >"$STATE/fingerprints/grok.json"
run
assert jqe '.state == "watch" and .fact == "grok: catalog not fetched on the last check (catalog)"' <<<"$(problem catalog-missing:grok)"
mv "$WORK/grok.json" "$STATE/fingerprints/grok.json"
assert jqe '.vendors[0].events | length == 5 and .[0].id == "codex-waiting" and .[0].changed == ["ids"]
  and (.[0] | keys == (["id", "status", "from", "to", "created_at", "launched_at", "closed_at", "changed"] | sort))' "$DOC"

# A pass that has not run in 36 h makes the document blind; so does a missing state.json.
state $((40 * H))
jq --arg t "$(ago $((40 * H)))" 'map_values(.checked_at = $t)' "$STATE/state.json" >"$WORK/s" && mv "$WORK/s" "$STATE/state.json"
run
assert jqe '.status == "blind" and .blind == ["pass"]' "$DOC"
assert jqe '.value >= 40 and .limit == 36' <<<"$(problem pass-stale:state)"
mv "$STATE/state.json" "$WORK/state.json"
run
assert jqe '.status == "blind" and (.blind | index("state.json"))' "$DOC"
assert jqe '.value == null' <<<"$(problem pass-stale:state)"
mv "$WORK/state.json" "$STATE/state.json"
state 3600

# The judge is stable over reruns and moves with the ledger.
run
judge=$(jq -r .judge "$DOC")
run
assert [ "$(jq -r .judge "$DOC")" = "$judge" ]
ledger() { printf '%s\n' "$1" >"$WORK/ledger.json"; UPDATER_DOCTOR_LEDGER="$WORK/ledger.json" "$DOCTOR" --quiet; }
ledger '{"owner":"t","rows":[{"id":"U1","title":"t","match":{"rule":"event-waiting","key":"codex-waiting"},"status":"open"}],"blind_spots":[]}'
assert [ "$(jq -r .judge "$DOC")" != "$judge" ]
assert jqe '.state == "open" and .ledger == "U1"' <<<"$(problem U1)"
assert_fails has event-waiting:codex-waiting
ledger '{"owner":"t","rows":[{"id":"U2","title":"t","match":{"rule":"pass-failed","key":"claude"},"status":"weather"}],"blind_spots":[]}'
assert_fails has pass-failed:claude
assert_fails has U2
ledger '{"owner":"t","rows":[{"id":"U3","title":"t","match":{"rule":"cli-behind","key":"grok"},"status":"fixed","fixes":[{"at":"2026-01-01T00:00:00Z"}]}],"blind_spots":[]}'
assert [ "$(state_of U3)" = regressed ]
ledger '{"owner":"t","rows":[{"id":"U4","title":"t","match":{"rule":"pass-failed"},"status":"not-a-bug"}],"blind_spots":[]}'
assert has pass-failed:claude
assert [ "$(state_of ledger:U4)" = new ]

# The ledger's shape is pinned: exact matches only, no dismissal row unless listed here.
L="$ROOT/share/updater-ledger.json"
assert jqe '.owner == "Updater doctor" and (keys == ["blind_spots", "owner", "rows"])' "$L"
assert jqe '.rows | all(.match | keys == ["key", "rule"] and (.rule | type == "string" and length > 0)
  and (.key | type == "string" and length > 0 and (test("[*?]") | not)))' "$L"
assert jqe '[.rows[] | select(.status == "not-a-bug" or .status == "weather") | .id] == []' "$L"
assert jqe '.blind_spots | map(keys == (["id", "what", "reason", "since", "would_catch_if"] | sort)) | all' "$L"
assert jqe '[.blind_spots[].id] == ["announced-not-served", "claude-catalog", "per-account-rollout"]' "$L"
assert jqe '(.blind_spots[] | select(.id == "announced-not-served") | .would_catch_if) | test("release-notes feed") and test("research leg")' "$L"

# A pending update is a watch row from its first busy skip, red past a day; with no log line it waits
# since its last check; a fixed ledger row regresses only a stuck one.
jq --arg t "$(ago 600)" '.codex = {result: "busy", installed: "0.159.0", latest: "0.159.2", checked_at: $t}
  | .claude = {result: "busy", installed: "2.1.283", latest: "2.1.284", checked_at: $t}' "$STATE/state.json" >"$WORK/s" && mv "$WORK/s" "$STATE/state.json"
mv "$STATE/update.log" "$WORK/update.log"
printf '%s codex busy 0.159.0 -> 0.159.2\n' "$(ago $((2 * H)))" "$(ago $H)" >"$STATE/update.log"
run
mv "$WORK/update.log" "$STATE/update.log"
assert jqe --arg t "$(date -r $(($(date +%s) - 2 * H)) +%H:%M)" '.state == "watch" and .count == 2 and .fact == "codex 0.159.0 → 0.159.2 waiting: busy since \($t)"' <<<"$(problem cli-behind:codex)"
assert jqe --arg t "$(date -r $(($(date +%s) - 600)) +%H:%M)" '.state == "watch" and .fact == "claude 2.1.283 → 2.1.284 waiting: busy since \($t)"' <<<"$(problem cli-behind:claude)"
assert jqe '[.problems[] | select(.rule == "cli-behind" and .state == "watch") | .id] == ["cli-behind:claude", "cli-behind:codex", "cli-behind:grok"]' "$DOC"
ledger '{"owner":"t","rows":[{"id":"U5","title":"t","match":{"rule":"cli-behind","key":"codex"},"status":"fixed","fixes":[{"at":"2026-01-01T00:00:00Z"}]}],"blind_spots":[]}'
assert [ "$(state_of U5)" = watch ]
state 3600

# A stale media manifest section is a problem until a later fresh check of it; sections are independent; no file is no problem.
CAPS="$STATE/caps-checks.jsonl"
REC="$ROOT/share/caps_checks.py"
run
assert jqe '[.problems[] | select(.rule == "caps-stale")] == [] and .blind == []' "$DOC"
t=$(date +%s)
caps_line() { jq -nc --argjson at "$1" --arg v "$2" --arg s "$3" --arg st "$4" --arg w "${5:-}" '{at: $at, vendor: $v, section: $s, state: $st, what: $w}'; }
{
  caps_line $((t - 3 * D)) gemini speech stale 'models: +old'
  caps_line $((t - 2 * D)) gemini speech fresh
  caps_line $((t - D)) gemini speech stale 'voices: +Kore'
  printf '{"at": broken\n'
  caps_line $((t - 2 * H)) gemini speech stale 'voices: +Kore; tags: +whisper'
  jq -nc --arg at x '{at: $at, vendor: "gemini", section: "speech", state: "fresh", what: ""}'
  caps_line $((t - 3 * H)) elevenlabs served_models stale 'new=eleven_v4 newer=eleven_v4>eleven_v3'
  caps_line $((t - 2 * H)) elevenlabs served_models fresh
  caps_line $((t - H)) gemini flow_music stale 'models: +Lyria 4'
} >"$CAPS"
run
assert jqe --arg d "$(date -r $((t - D)) +%Y-%m-%d)" '.state == "new" and .count == 2 and .value == 2 and .limit == 0 and (.first_seen | startswith($d))
  and .fact == "gemini manifest .speech stale: voices: +Kore; tags: +whisper · re-verify share/image-caps/gemini.json .speech against the live page/API, bump verified"
  and [.evidence[].excerpt] == ["voices: +Kore; tags: +whisper", "voices: +Kore"]' <<<"$(problem caps-stale:gemini/speech)"
assert jqe '.state == "new" and .count == 1' <<<"$(problem caps-stale:gemini/flow_music)"
assert_fails has caps-stale:elevenlabs/served_models
assert jqe '.problem_count == ([.problems[] | select(.state == "new" or .state == "open" or .state == "regressed")] | length)
  and ([.problems[] | select(.rule == "caps-stale") | .id] == ["caps-stale:gemini/flow_music", "caps-stale:gemini/speech"])' "$DOC"
python3 "$REC" record gemini speech fresh || fail "the recorder failed on a fresh check"
run
assert_fails has caps-stale:gemini/speech
assert has caps-stale:gemini/flow_music
assert jqe 'keys == (["at", "vendor", "section", "state", "what"] | sort) and .state == "fresh" and .what == "" and (now - .at) < 60' <<<"$(tail -n 1 "$CAPS")"
python3 "$REC" record codex cli stale cli=1.2 'verified=1.1' || fail "the recorder failed on a stale check"
assert jqe '.vendor == "codex" and .section == "cli" and .state == "stale" and .what == "cli=1.2 verified=1.1"' <<<"$(tail -n 1 "$CAPS")"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import caps_checks; caps_checks.record("grok", "model", True, "model=grok-imagine-2")' \
  "$ROOT/share" || fail "record() raised"
assert jqe '.vendor == "grok" and .section == "model" and .state == "stale" and .what == "model=grok-imagine-2"' <<<"$(tail -n 1 "$CAPS")"
# Nothing the recorder is handed fails a media run or writes a line it cannot judge.
lines=$(wc -l <"$CAPS")
for args in "" "record" "record gemini" "record gemini speech maybe" "record ../x speech stale" "record gemini a/b stale"; do
  python3 "$REC" $args >"$WORK/rec-out" 2>&1 || fail "the recorder exited non-zero on: $args"
  assert [ ! -s "$WORK/rec-out" ]
done
assert [ "$(wc -l <"$CAPS")" = "$lines" ]
mkdir -p "$WORK/ro" && chmod 555 "$WORK/ro"
VENDOR_CLI_UPDATE_STATE_DIR="$WORK/ro/sub" python3 "$REC" record gemini speech stale x >"$WORK/rec-out" 2>&1 || fail "an unwritable dir failed the recorder"
assert [ ! -s "$WORK/rec-out" ] && assert [ ! -e "$WORK/ro/sub" ]
chmod 755 "$WORK/ro"
: >"$WORK/plain"
VENDOR_CLI_UPDATE_STATE_DIR="$WORK/plain" python3 "$REC" record gemini speech stale x || fail "a file as the state dir failed the recorder"
# The file stays bounded: past its size it keeps each key's last lines and the first stale line since the last fresh one.
python3 - "$CAPS" <<'EOF'
import json, sys
with open(sys.argv[1], "w") as handle:
    handle.write(json.dumps({"at": 1000, "vendor": "gemini", "section": "speech", "state": "fresh", "what": ""}) + "\n")
    for n in range(3000):
        handle.write(json.dumps({"at": 1001 + n, "vendor": "gemini", "section": "speech", "state": "stale", "what": "x" * 100}) + "\n")
    handle.write(json.dumps({"at": 5000, "vendor": "codex", "section": "cli", "state": "fresh", "what": ""}) + "\n")
EOF
python3 "$REC" record gemini speech stale last || fail "the recorder failed on a full file"
assert [ "$(wc -c <"$CAPS")" -lt 262144 ]
assert jqe -s '[.[] | select(.vendor == "gemini")] | length == 21 and .[0].at == 1001 and .[-1].what == "last"' "$CAPS"
assert jqe -s '[.[] | select(.vendor == "codex")] | length == 1' "$CAPS"
run
assert jqe --arg d "$(date -r 1001 +%Y-%m-%dT%H:%M:%S)" '.first_seen | startswith($d)' <<<"$(problem caps-stale:gemini/speech)"
rm -f "$CAPS"
run
assert jqe '[.problems[] | select(.rule == "caps-stale")] == [] and .blind == []' "$DOC"

# --json prints the document and writes nothing.
rm -f "$DOC"
"$DOCTOR" --json | jqe '.doctor == "updater"'
assert [ ! -e "$DOC" ]

# One collector-runs row per run, keys exactly {doctor, start, wall_s, cpu_s, trigger}.
RUNS="$WORK/doctors-runs"
unset DOCTOR_TRIGGER
DOCTORS_DIR="$RUNS" DOCTOR_TRIGGER=menu "$DOCTOR" --quiet </dev/null || true
assert jqe -s 'length == 1 and (.[0] | (keys == ["cpu_s", "doctor", "start", "trigger", "wall_s"])
  and .doctor == "updater" and .trigger == "menu" and .wall_s >= 0 and .cpu_s > 0 and .start > 1700000000)' \
  "$RUNS/collector-runs.jsonl"
DOCTORS_DIR="$RUNS" "$DOCTOR" --json </dev/null >/dev/null || true
assert jqe -s 'length == 2 and .[1].trigger == "background"' "$RUNS/collector-runs.jsonl"
assert jqe -s --slurpfile doc "$DOC" 'length == 1 and .[0].doctor == "updater" and .[0].count == $doc[0].problem_count
  and .[0].day == (now | strflocaltime("%Y-%m-%d"))' "$RUNS/problem-days.jsonl"

echo "PASS:$asserts asserts; envelope, every rule (event-waiting, event-stuck, probe-broken, catalog-missing, cli-behind as a watch row from the first skip and red past a day, client-too-old, pass-stale, pass-failed, foreign-client, caps-stale cleared by a later fresh check per section) with its negatives, the caps-checks recorder that never fails and stays bounded, vendors for the menu, blind on a stale or missing pass, judge over code and ledger, ledger open/dismissed/regressed/fault, pinned ledger shape, under 1 s"
