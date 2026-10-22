#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# suno-music / suno-speech on a fake engine: what each flag hands the engine, the refusals before anything is
# spent, a saved song pinning its own account, the footer and notes, and the exit words. Fixture stores only.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$WORK/err" >&2 2>/dev/null; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export HOME="$WORK/home" TMPDIR="$WORK/tmp" GEMINI_WEB_DIR="$WORK/home/.gemini-web"
export IMAGE_LEG_LOG="$WORK/image-legs.jsonl" FAKE_CALLS="$WORK/calls" VENDOR_CLI_UPDATE_STATE_DIR="$WORK/vendor-cli-update"
export SUNO_MUSIC_ENGINE="$WORK/engine" FAKE_AUDIO="$WORK/take.mp3"
mkdir -p "$HOME" "$TMPDIR" "$WORK/out" "$GEMINI_WEB_DIR"
printf 'ID3fake' >"$FAKE_AUDIO"
SONG=11111111-2222-3333-4444-555555555555
OTHER=99999999-2222-3333-4444-555555555555
cat >"$SUNO_MUSIC_ENGINE" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"\$FAKE_CALLS"
if [ -n "\${FAKE_RC:-}" ]; then
  printf '{"ok":false,"account":"com","reason":"fake refusal"}\n'
  exit "\$FAKE_RC"
fi
[ "\$1" != status ] || { printf '{"ok":true,"account":"com","credits":60,"credits_limit":100,"spendable":50,"downloads":6}\n'; exit 0; }
out=''
while [ \$# -gt 0 ]; do [ "\$1" = --out-dir ] && out=\$2; shift; done
cp "\$FAKE_AUDIO" "\$out/take1.mp3"
printf '{"ok":true,"account":"com","takes":[{"audio":"%s/take1.mp3","clip":"$SONG","song":"https://suno.com/song/$SONG","model":"v6-mini","notes":"Clip: $SONG\\\\nAccount: com\\\\n"}],"library":[{"clip":"$SONG","song":"https://suno.com/song/$SONG"},{"clip":"$OTHER","song":"https://suno.com/song/$OTHER"}],"charged":10,"credits":50,"downloads":5,"caps":[]}\n' "\$out"
EOF
chmod +x "$SUNO_MUSIC_ENGINE"

music() { "$ROOT/bin/suno-music" "$@" >"$WORK/out.txt" 2>"$WORK/err"; }
speech() { "$ROOT/bin/suno-speech" "$@" >"$WORK/out.txt" 2>"$WORK/err"; }
refused() { # want-substring command...
  local want=$1 rc=0
  shift
  : >"$FAKE_CALLS"
  "$@" || rc=$?
  [ "$rc" -eq 2 ] && grep -qF -- "$want" "$WORK/err" && [ ! -s "$FAKE_CALLS" ]
}
calls() { cat "$FAKE_CALLS"; }

# A song: the flags reach the engine as its own words, the file and its notes land, the footer names the rest.
assert music --dest "$WORK/out/song.mp3" --prompt "lofi, Rhodes" --instrumental --duration 30 --gender female
assert grep -qF "generate --prompt lofi, Rhodes --lyrics  --duration 30 --title song --gender Female --takes 1 --format mp3" <(calls)
assert test -s "$WORK/out/song.mp3"
assert grep -qx "Clip: $SONG" "$WORK/out/song.mp3.txt"
assert grep -qx "dest=$WORK/out/song.mp3" "$WORK/out.txt"
assert grep -qx "clip=$SONG" "$WORK/out.txt"
assert grep -qx "library=https://suno.com/song/$OTHER" "$WORK/out.txt"
assert grep -qx "credits=10 charged, 50 left" "$WORK/out.txt"
assert grep -qx "downloads=5 unlocks left" "$WORK/out.txt"

# Refused before the engine runs.
assert refused "steps of 5 s" music --dest "$WORK/out/a.mp3" --prompt x --duration 33
assert refused "one choice" music --dest "$WORK/out/a.mp3" --prompt x --lyrics la --instrumental
assert refused "Simple form" music --dest "$WORK/out/a.mp3" --describe idea --prompt x
assert refused "goes with --describe" music --dest "$WORK/out/a.mp3" --prompt x --video "$FAKE_AUDIO"
assert refused "add --source" music --dest "$WORK/out/a.mp3" --prompt x --mode crop
assert refused "--from <s> before --to <s>" music --source "$SONG" --account com --mode crop --from 10 --to 5 --takes 0
assert refused "needs --with" music --source "$SONG" --account com --mode mashup --takes 0
assert refused "cuts the song itself" music --source "$SONG" --account com --mode reverse --prompt x --takes 0
assert refused "add --account" music --source "$SONG" --mode crop --from 1 --to 9 --takes 0
assert refused "--speed 0.25 to 4" music --source "$SONG" --account com --mode speed --speed 5 --takes 0
assert refused "makes one song" music --source "$SONG" --account com --mode reverse --takes 2 --dest "$WORK/out/r.mp3"
assert refused ".mp3 .m4a" music --dest "$WORK/out/a.wav" --prompt x
assert refused "--takes is 0, 1 or 2" music --dest "$WORK/out/a.mp3" --prompt x --takes 3
assert refused "unknown argument --text" music --dest "$WORK/out/a.mp3" --text hi
assert refused "unknown argument --prompt" speech --dest "$WORK/out/a.mp3" --prompt x
assert refused "--mode is one of" music --source "$SONG" --account com --mode fade --takes 0

# A file a suno run saved names its song and account: an edit or a fetch of it runs there, never elsewhere.
mkdir -p "$WORK/cwd"
assert eval '(cd "$WORK/cwd" && music --source "$WORK/out/song.mp3" --mode reverse --takes 0)'
assert test -z "$(ls -A "$WORK/cwd")" # --takes 0 writes no file, even when the engine hands one back
assert grep -qF "generate --source $WORK/out/song.mp3 --mode reverse --takes 0 --format mp3 --account com" <(calls)
assert refused "is a Suno song on com, not notcom" music --source "$WORK/out/song.mp3" --mode reverse --takes 0 --account notcom
assert music --fetch "$WORK/out/song.mp3" --dest "$WORK/out/again.m4a"
assert grep -qF "fetch --clip $SONG --account com --format m4a" <(calls)

# Speech: the script, the tone and the music switch.
assert speech --dest "$WORK/out/voice.mp3" --text "hello there" --tone calm --no-music
assert grep -qF "generate --script hello there --music off --tone calm --title voice --takes 1 --format mp3" <(calls)

# Live status, and the engine's exit words.
assert music --status --account com
assert grep -qx "credits=60 of 100 left, 50 spendable now" "$WORK/out.txt"
rc=0; FAKE_RC=3 music --dest "$WORK/out/b.mp3" --prompt x || rc=$?
assert test "$rc" -eq 3
assert grep -qx SUNO_USAGE_LIMIT "$WORK/err"
rc=0; FAKE_RC=5 music --dest "$WORK/out/b.mp3" --prompt x || rc=$?
assert test "$rc" -eq 5
assert grep -q '^ACCOUNT_BUSY account=com' "$WORK/err"
rc=0; FAKE_RC=4 music --dest "$WORK/out/b.mp3" --prompt x || rc=$?
assert test "$rc" -eq 4

echo "PASS:$asserts asserts; suno-music and suno-speech hand the engine its own flags, refuse a bad call before it runs, pin a saved song's account, write the file, notes and footer, read live status, and map the engine's exits 3, 4 and 5"
