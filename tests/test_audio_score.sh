#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/out" "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
# The stub uv runs the engine on the system python with both models stubbed: no download, no torch.
cat >"$WORK/uv" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$WORK/uv-args"
[ "\$1 \$2 \$3" = 'run -q --script' ] || exit 9
shift 3
exec python3 "\$@"
STUB
chmod +x "$WORK/uv"
score() { AUDIO_SCORE_UV="$WORK/uv" AUDIO_SCORE_FAKE=1 "$ROOT/bin/audio-score" "$@" >"$WORK/out" 2>"$WORK/err"; }
exits() { local want=$1; shift; score "$@"; [ $? -eq "$want" ]; }

: >"$WORK/a.wav"
cd "$WORK" || exit 1
: >"$WORK/bb.wav"
assert exits 2
assert exits 2 --json
assert exits 2 a.wav
assert grep -q 'a.wav is not an absolute path' "$WORK/err"
assert exits 2 "$WORK/missing.wav"
assert exits 2 "$WORK/a.wav" --mos
assert grep -q 'unknown argument --mos' "$WORK/err"
assert test ! -e "$WORK/uv-args"

assert exits 0 "$WORK/a.wav" "$WORK/bb.wav"
assert grep -qx "run -q --script $ROOT/share/audio_score.py $WORK/a.wav $WORK/bb.wav" "$WORK/uv-args"
assert test "$(wc -l <"$WORK/out")" -eq 2
assert grep -qxE "utmos=[1-5]\.[0-9]+ aes_pq=5\.0 aes_pc=5\.0 aes_ce=5\.0 aes_cu=5\.0 file=$WORK/a\.wav" "$WORK/out"
assert test "$(sed -n 2p "$WORK/out" | sed 's/.* file=//')" = "$WORK/bb.wav"

assert exits 0 "$WORK/a.wav" --json "$WORK/bb.wav"
assert test "$(jq -c 'keys' "$WORK/out")" = "[\"$WORK/a.wav\",\"$WORK/bb.wav\"]"
assert test "$(jq -c '[.[] | keys_unsorted] | unique' "$WORK/out")" = '[["utmos","aes_pq","aes_pc","aes_ce","aes_cu"]]'
assert test "$(jq '[.[][] | numbers] | length' "$WORK/out")" -eq 10

printf 'PASS: audio-score (%s asserts)\n' "$asserts"
