#!/usr/bin/env bash
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
BUSY="$WORK/busy"
export HOME CALLS BUSY FAKE_BIN
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
cat >"$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
name() { case $1 in @openai/codex*) printf codex ;; @xai-official/grok*) printf grok ;; @anthropic-ai/claude-code*) printf claude ;; esac; }
case $1 in
  view)
    case $2 in
      *@[0-9]*) grep -xF "${2##*@}" "$FAKE_BIN/published-$(name "$2")" 2>/dev/null ;;
      *) cat "$FAKE_BIN/latest-$(name "$2")" 2>/dev/null ;;
    esac
    ;;
  install)
    printf 'npm install %s\n' "$3" >>"$CALLS"
    [ -z "${NPM_INSTALL_FAIL:-}" ] || exit 1
    [ -z "${NPM_INSTALL_NOOP:-}" ] || exit 0
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
assert grep -qxF 'npm install @openai/codex@latest' "$CALLS"
assert grep -qxF 'npm install @xai-official/grok@latest' "$CALLS"
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
assert [ "$(tail -n 1 "$CALLS" | cut -d' ' -f1-2)" = "fingerprint check" ]
assert [ "$(tail -n 1 "$CALLS" | sed 's/.*PATH=//')" = "$PATH:$FAKE_BIN:$FAKE_BIN:$FAKE_BIN" ]

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
assert grep -qxF 'npm install @openai/codex@latest' "$CALLS"
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
assert grep -qxF 'npm install @anthropic-ai/claude-code@latest' "$CALLS"
assert [ "$(result claude)" = "updated 2.1.280" ]

# The native claude runs ahead of npm's latest tag: the npm claude follows it to the same version when
# npm publishes that version, and stays on latest when it does not or when the native one is older.
export VENDOR_CLI_UPDATE_NATIVE_CLAUDE="$WORK/native-claude"
printf '#!/usr/bin/env bash\nprintf "%%s (Claude Code)\\n" "$(cat "$FAKE_BIN/ver-native")"\n' >"$VENDOR_CLI_UPDATE_NATIVE_CLAUDE"
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
assert grep -qxF 'npm install @anthropic-ai/claude-code@latest' "$CALLS"
assert [ "$(result claude)" = "updated 2.1.280" ]
printf '2.1.279\n' >"$FAKE_BIN/ver-native"
printf '2.1.201\n' >"$FAKE_BIN/ver-claude"
run
assert grep -qxF 'npm install @anthropic-ai/claude-code@latest' "$CALLS"
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

# «выполни обновление»: the same pass with the fingerprint's own launch held, then one chat for every
# vendor; from a chat it returns at once and runs detached.
: >"$CALLS"
VENDOR_CLI_UPDATE_DETACHED=1 bash "$SCRIPT" now
assert [ "$(grep -c '^fingerprint ' "$CALLS")" = 2 ]
assert grep -qE '^fingerprint check HOLD=1 ' "$CALLS"
assert [ "$(tail -n 1 "$CALLS" | cut -d' ' -f1-4)" = "fingerprint request --all Egor's" ]
: >"$CALLS"
assert grep -qF 'vendor update started' <(bash "$SCRIPT" now)
for _ in $(seq 1 50); do grep -qF 'request --all' "$CALLS" && break; sleep 0.2; done
assert grep -qF 'fingerprint request --all' "$CALLS"

# launchd runs a wrapper named after the job, never a bare interpreter; uninstall removes both.
WRAPPER="$HOME/.local/libexec/vendor-cli-update"
PLIST="$HOME/Library/LaunchAgents/com.llm-legs.vendor-cli-update.plist"
bash "$SCRIPT" install >/dev/null || fail "install failed"
assert test -x "$WRAPPER"
assert grep -qF "exec $SCRIPT" "$WRAPPER"
assert [ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" = "$WRAPPER" ]
assert [ "$(plutil -extract ProgramArguments.1 raw "$PLIST")" = run ]
plist_path=$(plutil -extract EnvironmentVariables.PATH raw "$PLIST")
assert [ "${plist_path%%:*}" = "$HOME/.local/bin" ]
assert grep -qF "launchctl bootstrap gui/$UID $PLIST" "$CALLS"
bash "$SCRIPT" uninstall >/dev/null || fail "uninstall failed"
assert test ! -e "$WRAPPER"
assert test ! -e "$PLIST"

echo "PASS: $asserts asserts; update when the registry is newer (codex, grok and the npm claude, which follows the native claude version when npm has it), model caches re-read every run, divergence (foreign cache writers, foreign clients, per-account catalog gaps) recorded once per change, no reinstall or downgrade, busy clients left alone, registry and install failures recorded, run lock, launchd wrapper, fingerprint check last with npm bin dirs appended, a manual update detached with one chat for every vendor"
