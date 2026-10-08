#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
HOLDER=""
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd)"
asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }
assert_fails() {
  asserts=$((asserts + 1))
  "$@" && fail "assert $asserts unexpectedly succeeded: $*"
  return 0
}

HOME="$WORK/home"
FAKE_BIN="$WORK/node/bin"
NPM_ROOT="$WORK/node/lib/node_modules"
CALLS="$WORK/calls"
VIEWS="$WORK/views"
BUSY="$WORK/busy"
export HOME CALLS VIEWS BUSY FAKE_BIN
export AGY_BIN="$WORK/agy" VENDOR_CLI_UPDATE_AGY_MANIFEST="file://$WORK/agy-manifest.json"
unset CODEXB_PROFILES_DIR VENDOR_CLI_UPDATE_STATE_DIR VENDOR_CLI_UPDATE_LOCKED
export VENDOR_CLI_UPDATE_BIN_DIR="$FAKE_BIN" VENDOR_CLI_UPDATE_GROKB="$FAKE_BIN/grokb"
CODEX_NATIVE="$NPM_ROOT/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
GROK_NATIVE="$NPM_ROOT/@xai-official/grok/bin/grok-native"
CLAUDE_NATIVE="$NPM_ROOT/@anthropic-ai/claude-code/bin/claude.exe"
mkdir -p "$FAKE_BIN" "$(dirname "$CODEX_NATIVE")" "$(dirname "$GROK_NATIVE")" "$(dirname "$CLAUDE_NATIVE")" "$HOME/.grok/bin" \
  "$HOME/.codex" "$HOME/.codex-profiles/a" "$HOME/.codex-profiles/b"
: >"$CODEX_NATIVE"
: >"$GROK_NATIVE"
: >"$CLAUDE_NATIVE"
: >"$HOME/.grok/bin/grok-1.0.40"
: >"$HOME/.grok/bin/grok-1.0.41"
: >"$HOME/.codex/auth.json"
: >"$HOME/.codex-profiles/a/auth.json"
: >"$CALLS"
: >"$BUSY"

cat >"$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then printf 'codex-cli %s\n' "$(cat "$FAKE_BIN/ver-codex")"; exit 0; fi
[ "$1 $2" = "debug models" ] && printf 'codex-refresh %s\n' "$CODEX_HOME" >>"$CALLS"
EOF
cat >"$FAKE_BIN/grok" <<'EOF'
#!/usr/bin/env bash
printf 'grok %s (eb1a2256660d) [alpha]\n' "$(cat "$FAKE_BIN/ver-grok")"
EOF
cat >"$FAKE_BIN/grokb" <<'EOF'
#!/usr/bin/env bash
printf 'grokb %s\n' "$*" >>"$CALLS"
EOF
cat >"$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s (Claude Code)\n' "$(cat "$FAKE_BIN/ver-claude")"
EOF
cat >"$FAKE_BIN/fingerprint" <<'EOF'
#!/usr/bin/env bash
printf 'fingerprint %s HOLD=%s PATH=%s\n' "$*" "${VENDOR_FINGERPRINT_HOLD:-}" "$PATH" >>"$CALLS"
EOF
printf '2.1.280\n' >"$FAKE_BIN/ver-claude"
printf '2.1.280\n' >"$FAKE_BIN/latest-claude"
export VENDOR_CLI_UPDATE_FINGERPRINT="$FAKE_BIN/fingerprint"
cat >"$FAKE_BIN/doctor" <<'EOF'
#!/usr/bin/env bash
printf 'doctor %s\n' "$*" >>"$CALLS"
[ ! -e "$FAKE_BIN/doctor-fails" ]
EOF
chmod +x "$FAKE_BIN/doctor"
export VENDOR_CLI_UPDATE_DOCTOR="$FAKE_BIN/doctor"
cat >"$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
name() { case $1 in @openai/codex*) printf codex ;; @xai-official/grok*) printf grok ;; @anthropic-ai/claude-code*) printf claude ;; esac; }
case $1 in
  view)
    printf 'npm view %s\n' "$2" >>"$VIEWS"
    case $2 in
      *@[0-9]*) grep -xF "${2##*@}" "$FAKE_BIN/published-$(name "$2")" 2>/dev/null ;;
      *) cat "$FAKE_BIN/latest-$(name "$2")" 2>/dev/null ;;
    esac
    ;;
  install)
    printf 'npm install %s\n' "$3" >>"$CALLS"
    [ -z "${NPM_INSTALL_FAIL:-}" ] || exit 1
    [ -z "${NPM_INSTALL_NOOP:-}" ] || exit 0
    [ -z "${NPM_LATEST_MOVES:-}" ] || printf '%s\n' "$NPM_LATEST_MOVES" >"$FAKE_BIN/latest-$(name "$3")"
    case $3 in
      *@latest) cp "$FAKE_BIN/latest-$(name "$3")" "$FAKE_BIN/ver-$(name "$3")" ;;
      *) printf '%s\n' "${3##*@}" >"$FAKE_BIN/ver-$(name "$3")" ;;
    esac
    ;;
esac
EOF
cat >"$FAKE_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
for file in "$@"; do
  case $file in -t|--) continue ;; esac
  grep -qxF -- "$file" "$BUSY" && printf '4242\n'
done
exit 1
EOF
cat >"$FAKE_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
[ "$1" != print ]
EOF
chmod +x "$FAKE_BIN"/*
PATH="$FAKE_BIN:$PATH"

SCRIPT="$ROOT/bin/vendor-cli-update"
STATE="$HOME/.cache/vendor-cli-update/state.json"
LOG="$HOME/.cache/vendor-cli-update/update.log"
set_versions() { # codex-installed codex-latest grok-installed grok-latest ('' = npm view fails)
  printf '%s\n' "$1" >"$FAKE_BIN/ver-codex"
  printf '%s\n' "$3" >"$FAKE_BIN/ver-grok"
  rm -f "$FAKE_BIN/latest-codex" "$FAKE_BIN/latest-grok"
  [ -z "$2" ] || printf '%s\n' "$2" >"$FAKE_BIN/latest-codex"
  [ -z "$4" ] || printf '%s\n' "$4" >"$FAKE_BIN/latest-grok"
}
result() { jq -r --arg v "$1" '.[$v].result + " " + .[$v].installed' "$STATE"; }
run() { : >"$CALLS"; bash "$SCRIPT" run; }

# A client older than the registry is updated, and the model caches are re-read: every codex home
# holding a login (b has none) and the grok list.
set_versions 0.154.0 0.156.1 1.0.40 1.0.41
run || fail "run exited non-zero"
assert grep -qxF 'npm install @openai/codex@0.156.1' "$CALLS"
assert grep -qxF 'npm install @xai-official/grok@1.0.41' "$CALLS"
assert grep -qxF "codex-refresh $HOME/.codex" "$CALLS"
assert grep -qxF "codex-refresh $HOME/.codex-profiles/a" "$CALLS"
assert_fails grep -qF "codex-refresh $HOME/.codex-profiles/b" "$CALLS"
assert grep -qxF 'grokb models --refresh' "$CALLS"
assert [ "$(result codex)" = "updated 0.156.1" ]
assert [ "$(result grok)" = "updated 1.0.41" ]
assert grep -qE ' codex updated 0\.154\.0 -> 0\.156\.1$' "$LOG"
assert [ "$(result claude)" = "current 2.1.280" ]
# The fingerprint runs last, after the lists were re-read, with the npm bin dirs appended to PATH so
# the native claude found first stays the one it fingerprints.
assert [ "$(tail -n 2 "$CALLS" | head -n 1 | cut -d' ' -f1-2)" = "fingerprint check" ]
assert [ "$(tail -n 2 "$CALLS" | head -n 1 | sed 's/.*PATH=//')" = "$PATH:$FAKE_BIN:$FAKE_BIN:$FAKE_BIN" ]
# Then the Updater doctor reads what the pass left; its failure never fails the pass.
assert [ "$(tail -n 1 "$CALLS")" = "doctor --quiet" ]
: >"$FAKE_BIN/doctor-fails"
run || fail "a failing doctor failed the pass"
rm "$FAKE_BIN/doctor-fails"
assert grep -qE '^[0-9TZ:-]+ updater doctor failed$' "$LOG"

# Current clients: nothing is installed and the log does not grow, but the lists are re-read every
# run — a server adds a model for a client already installed.
lines=$(wc -l <"$LOG")
run
assert_fails grep -q 'npm install' "$CALLS"
assert grep -qxF "codex-refresh $HOME/.codex-profiles/a" "$CALLS"
assert grep -qxF 'grokb models --refresh' "$CALLS"
assert [ "$(result codex)" = "current 0.156.1" ]
assert [ "$(wc -l <"$LOG")" -eq "$lines" ]

# A client newer than the registry's latest (an alpha) is never downgraded.
set_versions 0.157.0-alpha.11 0.156.1 1.0.42 1.0.41
run
assert_fails grep -q 'npm install' "$CALLS"
assert [ "$(result grok)" = "current 1.0.42" ]

# A running client is never replaced under itself: codex by its native binary inside the package,
# grok by the package's grok-native or any versioned binary under ~/.grok/bin.
set_versions 0.156.1 0.157.0 1.0.41 1.0.42
printf '%s\n' "$CODEX_NATIVE" "$HOME/.grok/bin/grok-1.0.40" >"$BUSY"
run
assert_fails grep -q 'npm install' "$CALLS"
assert [ "$(result codex)" = "busy 0.156.1" ]
assert [ "$(result grok)" = "busy 1.0.41" ]
printf '%s\n' "$GROK_NATIVE" >"$BUSY"
run
assert grep -qxF 'npm install @openai/codex@0.157.0' "$CALLS"
assert_fails grep -qF 'npm install @xai-official/grok' "$CALLS"
assert [ "$(result grok)" = "busy 1.0.41" ]
: >"$BUSY"

# The npm claude is a second install that PATHs with /usr/local/bin or nvm first run instead of the
# native one: it is kept current like the others, and left alone while it runs.
printf '2.1.201\n' >"$FAKE_BIN/ver-claude"
printf '%s\n' "$CLAUDE_NATIVE" >"$BUSY"
run
assert [ "$(result claude)" = "busy 2.1.201" ]
: >"$BUSY"
run
assert grep -qxF 'npm install @anthropic-ai/claude-code@2.1.280' "$CALLS"
assert [ "$(result claude)" = "updated 2.1.280" ]

# The native claude runs ahead of npm's latest tag: the npm claude follows it to the same version when
# npm publishes that version, and stays on latest when it does not or when the native one is older.
export VENDOR_CLI_UPDATE_NATIVE_CLAUDE="$WORK/native-claude"
cat >"$VENDOR_CLI_UPDATE_NATIVE_CLAUDE" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = install ]; then
  printf 'native install %s\n' "$2" >>"$CALLS"
  [ -n "${NATIVE_INSTALL_FAIL:-}" ] || printf '%s\n' "$2" >"$FAKE_BIN/ver-native"
  exit 0
fi
printf '%s (Claude Code)\n' "$(cat "$FAKE_BIN/ver-native")"
EOF
chmod +x "$VENDOR_CLI_UPDATE_NATIVE_CLAUDE"
printf '2.1.282\n' >"$FAKE_BIN/ver-native"
printf '2.1.282\n' >"$FAKE_BIN/published-claude"
run
assert grep -qxF 'npm install @anthropic-ai/claude-code@2.1.282' "$CALLS"
assert [ "$(result claude)" = "updated 2.1.282" ]
run
assert_fails grep -qF 'npm install @anthropic-ai/claude-code' "$CALLS"
assert [ "$(result claude)" = "current 2.1.282" ]
printf '2.1.283\n' >"$FAKE_BIN/ver-native"
printf '2.1.201\n' >"$FAKE_BIN/ver-claude"
run
assert grep -qxF 'npm install @anthropic-ai/claude-code@2.1.280' "$CALLS"
assert [ "$(result claude)" = "updated 2.1.280" ]
printf '2.1.279\n' >"$FAKE_BIN/ver-native"
printf '2.1.201\n' >"$FAKE_BIN/ver-claude"
run
assert grep -qxF 'npm install @anthropic-ai/claude-code@2.1.280' "$CALLS"
# The native claude's own updater is off: it is installed natively to the npm claude's target, while
# the npm claude runs too (a native version is its own file), and never downgraded.
assert grep -qxF 'native install 2.1.280' "$CALLS"
assert [ "$(result claude-native)" = "updated 2.1.280" ]
assert grep -qE ' claude-native updated 2\.1\.279 -> 2\.1\.280$' "$LOG"
printf '2.1.284\n' >"$FAKE_BIN/latest-claude"
printf '2.1.284\n' >"$FAKE_BIN/ver-claude"
printf '%s\n' "$CLAUDE_NATIVE" >"$BUSY"
run
assert grep -qxF 'native install 2.1.284' "$CALLS"
assert [ "$(result claude-native)" = "updated 2.1.284" ]
: >"$BUSY"
printf '2.1.285\n' >"$FAKE_BIN/latest-claude"
NATIVE_INSTALL_FAIL=1 run
assert [ "$(jq -r '.["claude-native"] | .result + " " + .installed + " " + .latest' "$STATE")" = "install-failed 2.1.284 2.1.285" ]
printf '2.1.286\n' >"$FAKE_BIN/ver-native"
run
assert_fails grep -qF 'native install' "$CALLS"
assert [ "$(result claude-native)" = "current 2.1.286" ]
printf '2.1.280\n' >"$FAKE_BIN/latest-claude"
printf '2.1.280\n' >"$FAKE_BIN/ver-claude"
unset VENDOR_CLI_UPDATE_NATIVE_CLAUDE

# No npm install of a CLI at all is recorded without a log line every run.
lines=$(wc -l <"$LOG")
VENDOR_CLI_UPDATE_BIN_DIR='' run
assert [ "$(result claude)" = "not-installed " ]
assert [ "$(wc -l <"$LOG")" -eq "$lines" ]

# An unreachable registry and a failed install change nothing and refresh nothing.
set_versions 0.157.0 '' 1.0.41 1.0.42
NPM_INSTALL_FAIL=1 run
assert [ "$(result codex)" = "check-failed 0.157.0" ]
assert [ "$(result grok)" = "install-failed 1.0.41" ]
assert [ "$(cat "$FAKE_BIN/ver-grok")" = 1.0.41 ]

# npm reporting success while the client still answers its old version is a failed install too.
set_versions 0.157.0 0.158.0 1.0.41 1.0.41
NPM_INSTALL_NOOP=1 run
assert [ "$(result codex)" = "install-failed 0.157.0" ]
# npm's latest tag moving between the version read and the install gets the version read, an update.
NPM_LATEST_MOVES=0.158.1 run
assert grep -qxF 'npm install @openai/codex@0.158.0' "$CALLS"
assert [ "$(result codex)" = "updated 0.158.0" ]

# A second run while one holds the lock does nothing.
set_versions 0.157.0 0.158.0 1.0.42 1.0.42
lockf -k "$HOME/.cache/vendor-cli-update/run.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lockf -k -t 0 "$HOME/.cache/vendor-cli-update/run.lock" true 2>/dev/null || break
  sleep 0.2
done
assert_fails run 2>/dev/null
assert_fails grep -q 'npm install' "$CALLS"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
HOLDER=""

# Divergence: a cache another client wrote (the ChatGPT app's own codex in ~/.codex), another codex
# executable running outside our npm install, and an account whose list lacks a model others list.
set_versions 0.157.0 0.157.0 1.0.42 1.0.42
mkdir -p "$WORK/app" "$HOME/.codex-profiles/c"
printf '#!/usr/bin/env bash\nprintf "codex-cli 0.154.0-alpha.6.2\\n"\n' >"$WORK/app/codex"
chmod +x "$WORK/app/codex"
printf '%s\n' "$WORK/app/codex" "$CODEX_NATIVE" /usr/bin/true "$WORK/app/codex" >"$WORK/ps-comm"
cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
cat "$PS_COMM"
EOF
chmod +x "$FAKE_BIN/ps" "$CODEX_NATIVE"
export PS_COMM="$WORK/ps-comm"
: >"$HOME/.codex-profiles/c/auth.json"
printf '{"client_version":"0.154.0","models":[{"slug":"x"}]}\n' >"$HOME/.codex/models_cache.json"
printf '{"client_version":"0.157.0","models":[{"slug":"x"},{"slug":"y"}]}\n' >"$HOME/.codex-profiles/a/models_cache.json"
printf '{"client_version":"0.157.0","models":[{"slug":"x"}]}\n' >"$HOME/.codex-profiles/c/models_cache.json"
lines=$(wc -l <"$LOG")
run
divergence=$(jq -r '.codex.divergence | join("|")' "$STATE")
assert [ "$divergence" = "writer	main	0.154.0|client	$WORK/app/codex	0.154.0|catalog	c	missing y" ]
assert [ "$(wc -l <"$LOG")" -eq $((lines + 1)) ]
assert grep -qF 'codex divergence: writer main 0.154.0' "$LOG"
assert [ "$(result codex)" = "current 0.157.0" ]
run
assert [ "$(wc -l <"$LOG")" -eq $((lines + 1)) ]
assert grep -qxF "codex	divergence	catalog	c	missing y" <(bash "$SCRIPT" status)
rm "$HOME/.codex-profiles/c/auth.json" "$HOME/.codex/models_cache.json"
: >"$WORK/ps-comm"
run
assert [ "$(jq -r '.codex.divergence | length' "$STATE")" = 0 ]
assert grep -qF 'codex divergence: none' "$LOG"
# A pass that updates codex reads caches the client it just replaced wrote: no foreign writer.
set_versions 0.157.0 0.158.0 1.0.42 1.0.42
run
assert [ "$(result codex)" = "updated 0.158.0" ]
assert [ "$(jq -r '.codex.divergence | length' "$STATE")" = 0 ]

# «выполни обновление»: the same pass with the fingerprint's own launch held, then one chat for every
# vendor; from a chat it returns at once and runs detached.
: >"$CALLS"
VENDOR_CLI_UPDATE_DETACHED=1 bash "$SCRIPT" now
assert [ "$(grep -c '^fingerprint ' "$CALLS")" = 2 ]
assert grep -qE '^fingerprint check HOLD=1 ' "$CALLS"
assert [ "$(tail -n 2 "$CALLS" | head -n 1 | cut -d' ' -f1-4)" = "fingerprint request --all Egor's" ]
assert [ "$(tail -n 1 "$CALLS")" = "doctor --quiet" ]
# The request probes each CLI's --version, so it gets the npm bin dirs the check got.
assert [ "$(tail -n 2 "$CALLS" | head -n 1 | sed 's/.*PATH=//')" = "$PATH:$FAKE_BIN:$FAKE_BIN:$FAKE_BIN" ]
# A lock held past lockf's 900s means no pass ran: no orchestrator chat for CLIs nobody updated.
: >"$CALLS"
printf '#!/usr/bin/env bash\ncase "$*" in *run.lock*) exit 75 ;; esac\nexec /usr/bin/lockf "$@"\n' >"$FAKE_BIN/lockf"
chmod +x "$FAKE_BIN/lockf"
assert_fails env VENDOR_CLI_UPDATE_DETACHED=1 bash "$SCRIPT" now
rm "$FAKE_BIN/lockf"
assert_fails grep -qF 'request --all' "$CALLS"
assert grep -qF 'another run held the lock' "$LOG"
: >"$CALLS"
assert grep -qF 'vendor update started' <(bash "$SCRIPT" now)
for _ in $(seq 1 50); do grep -qF 'request --all' "$CALLS" && break; sleep 0.2; done
assert grep -qF 'fingerprint request --all' "$CALLS"
# A second click during the detached pass starts no second pass and no second orchestrator chat.
for _ in $(seq 1 50); do lockf -k -t 0 "$HOME/.cache/vendor-cli-update/manual.lock" true 2>/dev/null && break; sleep 0.2; done
lockf -k "$HOME/.cache/vendor-cli-update/manual.lock" sleep 30 &
HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lockf -k -t 0 "$HOME/.cache/vendor-cli-update/manual.lock" true 2>/dev/null || break
  sleep 0.2
done
: >"$CALLS"
assert grep -qF 'vendor update already running' <(bash "$SCRIPT" now)
sleep 1
assert_fails grep -qF 'fingerprint' "$CALLS"
kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
HOLDER=""

# Night prep: the same pass in the foreground, no orchestrator chat, so `request --night` still finds the events.
: >"$CALLS"
bash "$SCRIPT" now --night
assert grep -qE '^fingerprint check HOLD=1 ' "$CALLS"
assert_fails grep -qF 'fingerprint request' "$CALLS"
assert [ "$(tail -n 1 "$CALLS")" = "doctor --quiet" ]
assert grep -qF 'night update: pass done, no orchestrator chat' "$LOG"

# launchd's `run --if-due` every half hour: nothing while every vendor is current and checked within a
# day; a busy or failed vendor alone is retried, and only an update brings the rest of the pass.
due_state() { # codex-result grok-result claude-result checked-at [passed-at]
  jq -n --arg c "$1" --arg g "$2" --arg l "$3" --arg t "$4" --arg p "${5:-$4}" \
    '{codex: {result: $c, checked_at: $t, passed_at: $p}, grok: {result: $g, checked_at: $t, passed_at: $p},
      claude: {result: $l, checked_at: $t, passed_at: $p}, gemini: {result: "current", checked_at: $t}}' >"$STATE"
}
due_run() { : >"$CALLS"; : >"$VIEWS"; bash "$SCRIPT" run --if-due; }
fresh=$(date -u +%Y-%m-%dT%H:%M:%SZ)
set_versions 0.157.0 0.158.0 1.0.41 1.0.42
printf '2.1.280\n' >"$FAKE_BIN/ver-claude"
due_state current current current "$fresh"
due_run || fail "an idle due run exited non-zero"
assert [ ! -s "$CALLS" ]
assert [ ! -s "$VIEWS" ]
assert [ "$(result codex)" = "current " ]
printf '%s\n' "$CODEX_NATIVE" >"$BUSY"
due_state busy current current "$fresh"
due_run
assert_fails grep -q 'npm install' "$CALLS"
assert_fails grep -qF 'codex-refresh' "$CALLS"
assert [ "$(cat "$CALLS")" = "doctor --quiet" ]
assert [ "$(result codex)" = "busy 0.157.0" ]
: >"$BUSY"
set_versions 0.157.0 0.158.0 1.0.41 1.0.42
due_run
assert grep -qxF 'npm install @openai/codex@0.158.0' "$CALLS"
assert_fails grep -qF 'npm install @xai-official/grok' "$CALLS"
assert [ "$(result codex)" = "updated 0.158.0" ]
assert [ "$(result grok)" = "current " ]
assert grep -qxF "codex-refresh $HOME/.codex-profiles/a" "$CALLS"
assert grep -qE '^fingerprint check ' "$CALLS"
assert [ "$(tail -n 1 "$CALLS")" = "doctor --quiet" ]
set_versions 0.158.0 0.158.0 1.0.41 1.0.42
due_state install-failed current current "$fresh"
due_run
assert [ "$(result codex)" = "current 0.158.0" ]
assert [ "$(cat "$CALLS")" = "doctor --quiet" ]
due_state current current current "$(date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"
due_run
assert grep -qxF 'npm install @xai-official/grok@1.0.42' "$CALLS"
assert [ "$(result grok)" = "updated 1.0.42" ]
rm -f "$STATE"
due_run
assert grep -qE '^fingerprint check ' "$CALLS"
# Between daily passes every vendor's version is checked once it is 2 h old: a release found installs
# and brings the rest of the pass, none found only rewrites the Updater doctor; the daily clock is the
# full pass's own, which a version check never moves.
assert jq -e '[.codex, .grok, .claude | .passed_at] | all(. != null)' "$STATE" >/dev/null
set_versions 0.158.0 0.158.0 1.0.42 1.0.42
three_h=$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ)
due_state current current current "$three_h" "$fresh"
due_run
assert [ "$(grep -c '^npm view ' "$VIEWS")" = 3 ]
assert [ "$(cat "$CALLS")" = "doctor --quiet" ]
assert [ "$(jq -r '.codex.passed_at' "$STATE")" = "$fresh" ]
assert [ "$(jq -r '.codex.checked_at' "$STATE")" != "$three_h" ]
due_run
assert [ ! -s "$VIEWS" ]
assert [ ! -s "$CALLS" ]
set_versions 0.158.0 0.159.0 1.0.42 1.0.42
due_state current current current "$three_h" "$fresh"
due_run
assert grep -qxF 'npm install @openai/codex@0.159.0' "$CALLS"
assert [ "$(result codex)" = "updated 0.159.0" ]
assert grep -qE '^fingerprint check ' "$CALLS"
assert [ "$(tail -n 1 "$CALLS")" = "doctor --quiet" ]
due_state current current current "$fresh" "$(date -u -v-25H +%Y-%m-%dT%H:%M:%SZ)"
due_run
assert grep -qE '^fingerprint check ' "$CALLS"
# A failed native claude install is retried like an npm one.
due_state current current current "$fresh"
jq '.["claude-native"] = {result: "install-failed"}' "$STATE" >"$WORK/s" && mv "$WORK/s" "$STATE"
due_run
assert [ "$(cat "$VIEWS")" = "npm view @anthropic-ai/claude-code" ]

# agy updates itself; the version check reads its updater's manifest and records how far behind it is.
cat >"$AGY_BIN" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_BIN/ver-agy"
EOF
chmod +x "$AGY_BIN"
printf '1.3.0\n' >"$FAKE_BIN/ver-agy"
printf '{"version": "1.3.1", "url": "x"}\n' >"$WORK/agy-manifest.json"
due_state current current current "$fresh"
jq --arg t "$three_h" '.gemini.checked_at = $t' "$STATE" >"$WORK/s" && mv "$WORK/s" "$STATE"
due_run
assert [ "$(jq -r '.gemini | .result + " " + .installed + " " + .latest' "$STATE")" = "self-update 1.3.0 1.3.1" ]
assert grep -qE ' gemini self-update 1\.3\.0 -> 1\.3\.1$' "$LOG"
assert [ ! -s "$VIEWS" ]
assert [ "$(cat "$CALLS")" = "doctor --quiet" ]
printf '1.3.1\n' >"$FAKE_BIN/ver-agy"
rm -f "$STATE"
run
assert [ "$(result gemini)" = "current 1.3.1" ]
rm "$WORK/agy-manifest.json"
run
assert [ "$(result gemini)" = "check-failed 1.3.1" ]

# launchd runs a wrapper named after the job, never a bare interpreter; uninstall removes both.
WRAPPER="$HOME/.local/libexec/vendor-cli-update"
PLIST="$HOME/Library/LaunchAgents/com.llm-legs.vendor-cli-update.plist"
bash "$SCRIPT" install >/dev/null || fail "install failed"
assert test -x "$WRAPPER"
assert grep -qF "exec $SCRIPT" "$WRAPPER"
assert [ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" = "$WRAPPER" ]
assert [ "$(plutil -extract ProgramArguments.1 raw "$PLIST")" = run ]
assert [ "$(plutil -extract ProgramArguments.2 raw "$PLIST")" = --if-due ]
assert [ "$(plutil -extract StartInterval raw "$PLIST")" = 1800 ]
plist_path=$(plutil -extract EnvironmentVariables.PATH raw "$PLIST")
assert [ "${plist_path%%:*}" = "$HOME/.local/bin" ]
assert grep -qF "launchctl bootstrap gui/$UID $PLIST" "$CALLS"
bash "$SCRIPT" uninstall >/dev/null || fail "uninstall failed"
assert test ! -e "$WRAPPER"
assert test ! -e "$PLIST"

echo "PASS: $asserts asserts; update when the registry is newer (codex, grok and the npm claude, which follows the native claude version when npm has it), model caches re-read every run, divergence (foreign cache writers, foreign clients, per-account catalog gaps) recorded once per change, no reinstall or downgrade, busy clients left alone and retried within half an hour, every version checked every 2 h with no network on a tick not due while the full pass stays daily, the native claude installed natively to the npm claude's target, agy's lag read off its updater manifest, registry and install failures recorded, run lock, launchd wrapper, fingerprint check last with npm bin dirs appended, then the Updater doctor whose failure fails no pass, a manual update detached with one chat for every vendor"
