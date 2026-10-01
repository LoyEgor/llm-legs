#!/usr/bin/env bash
. "$(dirname "$0")/worker_run_harness.sh"

browse_tests() {
  local BT_WORK="$WORK/browse_tests"
  mkdir -p "$BT_WORK"
  local BT_DIA="$BT_WORK/dia_user_data"
  local BT_CHROME="$BT_WORK/chrome_user_data"
  local BT_CODEX_CONF="$BT_WORK/codex_config.toml"
  local BT_WP="$BT_WORK/bin/worker-pick"
  local BT_RUNS="$BT_WORK/runs"
  mkdir -p "$BT_DIA" "$BT_CHROME" "$BT_WORK/bin" "$BT_RUNS"

  local BROWSE_CUA_SYNC="$BT_WORK/bin/cua-sync"
  local BROWSE_CHROME_MANIFEST="$BT_WORK/native-hosts/manifest.json"
  local BROWSE_NATIVE_HOST="$BT_WORK/native-hosts/shared-host"
  local BT_SYNC_MODE=auto BT_SYNC_LOG="$BT_WORK/sync-calls"
  export BROWSE_CUA_SYNC BROWSE_CHROME_MANIFEST BROWSE_NATIVE_HOST BT_SYNC_MODE BT_SYNC_LOG
  mkdir -p "${BROWSE_CHROME_MANIFEST%/*}"
  printf '#!/bin/sh\nexit 0\n' >"$BROWSE_NATIVE_HOST"
  chmod +x "$BROWSE_NATIVE_HOST"
  jq -n --arg path "$BROWSE_NATIVE_HOST" '{path:$path, name:"kept", allowed_origins:["extension://kept"]}' >"$BROWSE_CHROME_MANIFEST"
  cat >"$BROWSE_CUA_SYNC" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-repair}" >>"$BT_SYNC_LOG"
case "$BT_SYNC_MODE:${1:-repair}" in
  registered:*) exit 0 ;;
  repaired:--check) exit 1 ;;
  repaired:repair) exit 0 ;;
  broken:* ) printf 'fake registration failure\nsecond diagnostic\n' >&2; exit 1 ;;
esac
if grep -q '^\[mcp_servers.cua_repl\]' "$BROWSE_CODEX_CONFIG"; then exit 0; fi
printf 'fake registration failure\n' >&2
exit 1
EOF
  chmod +x "$BROWSE_CUA_SYNC"

  cat >"$BT_DIA/Local State" <<'EOF'
{
  "profile": {
    "info_cache": {
      "Profile 8": {
        "name": "work dia"
      }
    },
    "last_used": "Profile 8"
  }
}
EOF

  local BT_DIA_EXT="$BT_DIA/Profile 8/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  mkdir -p "$BT_DIA_EXT"
  printf 'bridgeDeviceId\x01\x0c\x0d\x3f\xd06ada21d4-ae66-4990-9040-97e18bb7b529"\x07\x12\x0ddisplayName\x01\x2b\x01\x05<<\"Dia browser\"\x02\x26\x04\x05\x09hControl' >"$BT_DIA_EXT/000001.log"

  cat >"$BT_CHROME/Local State" <<'EOF'
{
  "profile": {
    "info_cache": {
      "Profile 1": {
        "name": "Egor work"
      }
    },
    "last_used": "Profile 1"
  }
}
EOF

  local BT_CHROME_EXT="$BT_CHROME/Profile 1/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  mkdir -p "$BT_CHROME_EXT"
  printf 'bridgeDeviceId\x01\x0c\x0d\x3f\xd0b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d"\x07\x12\x0ddisplayName\x01\x2b\x01\x05<<\"Chrome browser\"\x02\x26' >"$BT_CHROME_EXT/000001.log"

  cat >"$BT_CODEX_CONF" <<'EOF'
[mcp_servers.cua_repl]
startup_timeout_sec = 120
command = "/path/to/node"
args = ["/path/to/launch.mjs"]
EOF

  cat >"$BT_WP" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
codex:    7.4%/d ×7.0d   48%   48%   main                 astra·high
          5.0%/d ×7.0d   90%   100%  wall                 astra·high   ↺ Thu 02:51  WALLED
claude:  11.4%/d ×7.0d   20%   20%   com                  opus·high
          8.6%/d ×7.0d   40%   30%   extra                opus·high    off
         * = this session account
OUTPUT
EOF
  chmod +x "$BT_WP"

  # The transport a vendor drives the browser through is a process tree plus a socket, and both
  # belong to Egor's real machine: every case here reads a fixture listing instead, so no assertion
  # depends on which browser happens to be open while the suite runs.
  local BT_PS="$BT_WORK/bin/ps-fixture" BT_LSOF="$BT_WORK/bin/lsof-fixture"
  local BT_PS_LISTING="$BT_WORK/ps-listing"
  local BT_SOCK_CLAUDE="$BT_WORK/sockets/claude" BT_SOCK_CODEX="$BT_WORK/sockets/codex"
  mkdir -p "$BT_SOCK_CLAUDE" "$BT_SOCK_CODEX"
  : >"$BT_SOCK_CLAUDE/101.sock"
  : >"$BT_SOCK_CLAUDE/201.sock"
  : >"$BT_SOCK_CODEX/1f0c9d3a.sock"
  cat >"$BT_WORK/ps-connected" <<'EOF'
  100     1 /Applications/Dia.app/Contents/MacOS/Dia
  101   100 /Users/egorloy/.local/bin/claude --chrome-native-host
  102   100 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  201   200 /Users/egorloy/.local/bin/claude --chrome-native-host
  202   200 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
  300   100 /Applications/Dia.app/Contents/MacOS/Dia --type=renderer
EOF
  # Chrome is up with no transport of its own, spelled through every near miss: the extension hosts
  # under it belong to Dia (101 even holds a socket), the one child Chrome does have is an ordinary
  # renderer whose flags are not a host command, and the host that IS Chrome's (205) has no socket.
  # Each line fails a different one of the three tests — command, parentage, its own socket.
  cat >"$BT_WORK/ps-chrome-bare" <<'EOF'
  100     1 /Applications/Dia.app/Contents/MacOS/Dia
  101   100 /Users/egorloy/.local/bin/claude --chrome-native-host
  102   100 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  201   200 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=utility --utility-sub-type=network.mojom.NetworkService
  205   200 /Users/egorloy/.local/bin/claude --chrome-native-host
EOF
  cat >"$BT_WORK/ps-dia-bare" <<'EOF'
  100     1 /Applications/Dia.app/Contents/MacOS/Dia
  200     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  202   200 /Users/egorloy/.codex/plugins/cache/openai-bundled/chrome/latest/extension-host/macos/arm64/ChatGPT for Chrome chrome-extension://hehggadaopoacecdllhhajmbjkdcmajg/
EOF
  cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
  cat >"$BT_PS" <<EOF
#!/bin/sh
cat "$BT_PS_LISTING"
EOF
  cat >"$BT_LSOF" <<EOF
#!/bin/sh
printf 'ChatGPT %s egorloy 3u unix 0x0 0t0 %s/1f0c9d3a.sock\n' "\$2" "$BT_SOCK_CODEX"
EOF
  chmod +x "$BT_PS" "$BT_LSOF"
  local BROWSE_PS="$BT_PS" BROWSE_LSOF="$BT_LSOF"
  local BROWSE_CLAUDE_SOCKET_DIR="$BT_SOCK_CLAUDE" BROWSE_CODEX_SOCKET_DIR="$BT_SOCK_CODEX"
  export BROWSE_PS BROWSE_LSOF BROWSE_CLAUDE_SOCKET_DIR BROWSE_CODEX_SOCKET_DIR

  local out rc=0 preamble_path
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'DIA: running' <<<"$out"
  assert grep -qx 'DIA-PROFILE: work dia (Profile 8)' <<<"$out"
  assert grep -qx 'DIA-DEVICE: 6ada21d4-ae66-4990-9040-97e18bb7b529 "Dia browser"' <<<"$out"
  assert grep -qx 'TARGET: dia' <<<"$out"
  assert grep -qx 'CHROME-DEVICE: b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d "Chrome browser"' <<<"$out"
  assert grep -qx 'CHROME-PROFILE: Egor work (Profile 1)' <<<"$out"
  assert test "$(grep -c '^BANNED-DEVICES:' <<<"$out")" -eq 0
  assert test "$(grep -c '^LAUNCHED:' <<<"$out")" -eq 0
  assert grep -qx 'CHROME: absent' <<<"$out"
  assert grep -qx 'CUA-REPL: registered' <<<"$out"
  assert grep -qx 'SKY: running' <<<"$out"
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: com' <<<"$out"
  assert grep -qx 'NEXT-CODEX-ACCOUNT: main' <<<"$out"
  assert grep -qx 'REASON: claudeb/extra skipped — out of pool' <<<"$out"
  assert grep -qx 'REASON: codex/wall skipped — walled' <<<"$out"
  assert test "$(grep -c 'this session account' <<<"$out")" -eq 0
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  assert grep -q '^PREAMBLE-FILE: ' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test -f "$preamble_path"
  assert grep -q 'await cua.getState()' "$preamble_path"
  assert grep -q 'https://example.com' "$preamble_path"
  assert grep -q 'work dia' "$preamble_path"
  assert grep -q 'irrelevant to `cua`' "$preamble_path"
  assert grep -q 'agent.browsers.list()' "$preamble_path"
  assert grep -q 'WITHOUT a `profileName`' "$preamble_path"
  assert grep -q 'Egor work.*is Google Chrome' "$preamble_path"
  assert grep -q 'Never drive Google Chrome' "$preamble_path"
  assert test "$(grep -c '6ada21d4-ae66-4990-9040-97e18bb7b529' "$preamble_path")" -eq 0
  assert test "$(grep -c 'b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d' "$preamble_path")" -eq 0
  # Claude in Chrome leads the browser plan; Codex is its fallback.
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" BROWSE_CHROME_USER_DATA="$BT_CHROME" BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP" WORKER_RUN_DIR="$BT_RUNS" BROWSE_SKIP_PROCESSES=1 "$RUNNER" browse)
  assert grep -qx 'PLAN: claudeb account=com device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=probe' <<<"$out"

  cat >"$BT_CODEX_CONF.nocua" <<'EOF'
[model]
name = "gpt-6-astra"
EOF
  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua" \
        BROWSE_WORKER_PICK="$BT_WP" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'CUA-REPL: broken' <<<"$out"
  assert grep -qx 'REASON: codex skipped — cua_repl registration failed: fake registration failure' <<<"$out"
  assert grep -qx 'PLAN: claudeb account=com device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=probe' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test -f "$preamble_path"
  assert grep -q 'list_connected_browsers' "$preamble_path"
  assert grep -qF 'Target Dia device ID: 6ada21d4-ae66-4990-9040-97e18bb7b529' "$preamble_path"
  assert grep -qF 'Off-target extension device IDs (Google Chrome — never drive one, never `switch_browser` to it): b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d' "$preamble_path"

  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: claudeb account=com device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=probe' <<<"$out"

  cat >"$BT_WP.multi" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
claude:  11.4%/d ×7.0d   20%   20%   com                  opus·high
          8.6%/d ×7.0d   40%   30%   spare                opus·high
OUTPUT
EOF
  chmod +x "$BT_WP.multi"

  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua" \
        BROWSE_WORKER_PICK="$BT_WP.multi" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse --record 6ada21d4-ae66-4990-9040-97e18bb7b529 spare) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'RECORDED: 6ada21d4-ae66-4990-9040-97e18bb7b529 spare' <<<"$out"
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: spare,com' <<<"$out"
  assert grep -qx 'PLAN: claudeb account=spare device=6ada21d4-ae66-4990-9040-97e18bb7b529 source=cached' <<<"$out"

  cat >"$BT_WP.empty" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
codex:   unavailable
claude:  no accounts
OUTPUT
EOF
  chmod +x "$BT_WP.empty"

  rc=0
  out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
        BROWSE_CHROME_USER_DATA="$BT_CHROME" \
        BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
        BROWSE_WORKER_PICK="$BT_WP.empty" \
        WORKER_RUN_DIR="$BT_RUNS" \
        BROWSE_SKIP_PROCESSES=1 \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'PLAN: none' <<<"$out"

  local json_out
  rc=0
  json_out=$(BROWSE_DIA_USER_DATA="$BT_DIA" \
             BROWSE_CHROME_USER_DATA="$BT_CHROME" \
             BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" \
             BROWSE_WORKER_PICK="$BT_WP" \
             WORKER_RUN_DIR="$BT_RUNS" \
             BROWSE_SKIP_PROCESSES=1 \
             "$RUNNER" browse --json) || rc=$?
  assert test "$rc" -eq 0
  assert jq -e . <<<"$json_out" >/dev/null
  assert test "$(jq -r .dia <<<"$json_out")" = 'running'
  assert test "$(jq -r .dia_profile.dir <<<"$json_out")" = 'Profile 8'
  assert test "$(jq -r .dia_profile.name <<<"$json_out")" = 'work dia'
  assert test "$(jq -r .dia_device.id <<<"$json_out")" = '6ada21d4-ae66-4990-9040-97e18bb7b529'
  assert test "$(jq -r .target <<<"$json_out")" = 'dia'
  assert test "$(jq -r .chrome_device.id <<<"$json_out")" = 'b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d'
  assert test "$(jq -r .chrome_profile.name <<<"$json_out")" = 'Egor work'
  assert test "$(jq -r .chrome_profile.dir <<<"$json_out")" = 'Profile 1'
  assert test "$(jq -r .launched <<<"$json_out")" = 'null'
  assert test "$(jq -r 'has("banned_devices")' <<<"$json_out")" = 'false'
  assert test "$(jq -r .cua_repl <<<"$json_out")" = 'registered'
  # The device is cached to `spare`, which this pool lacks: claudeb cannot run, so Codex falls back.
  assert test "$(jq -r .plan.vendor <<<"$json_out")" = 'codex'
  assert test "$(jq -r .plan.account <<<"$json_out")" = 'main'

  local BROWSE_DIA_USER_DATA="$BT_DIA" BROWSE_CHROME_USER_DATA="$BT_CHROME"
  local BROWSE_CODEX_CONFIG="$BT_CODEX_CONF" BROWSE_WORKER_PICK="$BT_WP.multi" BROWSE_SKIP_PROCESSES=1
  local WORKER_RUN_DIR="$BT_RUNS"
  export BROWSE_DIA_USER_DATA BROWSE_CHROME_USER_DATA BROWSE_CODEX_CONFIG BROWSE_WORKER_PICK BROWSE_SKIP_PROCESSES WORKER_RUN_DIR
  local dev=6ada21d4-ae66-4990-9040-97e18bb7b529 other_dev=8e70ec10-fa25-45a9-8e57-2ecae0629d12
  local chrome_dev=b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d
  local cache="$BT_RUNS/browse/devices.json" fixture="$BT_RUNS/codex-browser-fixture"
  mkdir -p "$fixture"
  printf '{"vendor":"codex","account":"spare","workdir":"%s","started_at":0,"pid":0,"browser":true}\n' "$WORK/workdir" >"$fixture/meta.json"
  : >"$fixture/err"
  printf 'BROWSER-DEVICE-ACCOUNT: %s spare\n' "$dev" >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "spare" and (.[$dev].seen | test("Z$"))' "$cache" >/dev/null
  jq --arg dev "$dev" '.[$dev].seen = "old"' "$cache" >"$cache.fixture"
  mv "$cache.fixture" "$cache"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].seen == "old"' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-refresh"
  fixture="$fixture-refresh"
  rm "$fixture/result"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].seen != "old"' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-other-account"
  fixture="$fixture-other-account"
  rm "$fixture/result"
  printf 'OUTCOME: BROWSER_DEVICE_NOT_IN_ACCOUNT device=%s account=com\n' "$dev" >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "spare"' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-drop"
  fixture="$fixture-drop"
  rm "$fixture/result"
  printf 'OUTCOME: BROWSER_DEVICE_NOT_IN_ACCOUNT device=%s account=spare\n' "$dev" >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "spare" and .[$dev].denied == true' "$cache" >/dev/null
  cp -R "$fixture" "$fixture-claudeb"
  fixture="$fixture-claudeb"
  rm "$fixture/result"
  jq '.vendor = "claudeb"' "$fixture/meta.json" >"$fixture/meta.next"
  mv "$fixture/meta.next" "$fixture/meta.json"
  jq -n --arg result "BROWSER-DEVICE-ACCOUNT: $dev com" '{result:$result}' >"$fixture/out"
  assert "$RUNNER" _deliver "$fixture" 0 >/dev/null
  assert jq -e --arg dev "$dev" '.[$dev].account == "com"' "$cache" >/dev/null

  BROWSE_WORKER_PICK="$BT_WP"
  for BT_SYNC_MODE in registered repaired broken; do
    : >"$BT_SYNC_LOG"
    rc=0
    out=$("$RUNNER" browse --vendor codex) || rc=$?
    assert grep -qx "CUA-REPL: $BT_SYNC_MODE" <<<"$out"
    if [ "$BT_SYNC_MODE" = broken ]; then
      assert test "$rc" -eq 2
      assert grep -qx 'PLAN: none' <<<"$out"
      assert grep -qx 'REASON: codex skipped — cua_repl registration failed: fake registration failure' <<<"$out"
      assert test "$(grep -c 'second diagnostic' <<<"$out")" -eq 0
    else
      assert test "$rc" -eq 0
      assert grep -qx 'PLAN: codex account=main' <<<"$out"
    fi
    assert grep -qx -- '--check' "$BT_SYNC_LOG"
    if [ "$BT_SYNC_MODE" = registered ]; then
      assert test "$(wc -l <"$BT_SYNC_LOG" | tr -d ' ')" -eq 1
    else
      assert grep -qx repair "$BT_SYNC_LOG"
    fi
  done
  BT_SYNC_MODE=registered

  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'MANIFEST: ok' <<<"$out"
  jq '.path = "/dead/profile/chrome-native-host"' "$BROWSE_CHROME_MANIFEST" >"$BT_WORK/dead-manifest"
  cp "$BT_WORK/dead-manifest" "$BROWSE_CHROME_MANIFEST"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'MANIFEST: repaired' <<<"$out"
  assert grep -qxF "REASON: manifest path repaired: /dead/profile/chrome-native-host -> $BROWSE_NATIVE_HOST" <<<"$out"
  assert jq -e --arg path "$BROWSE_NATIVE_HOST" '.path == $path and .name == "kept" and .allowed_origins == ["extension://kept"]' "$BROWSE_CHROME_MANIFEST" >/dev/null
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'MANIFEST: ok' <<<"$out"
  rc=0
  out=$(BROWSE_CHROME_MANIFEST="$BT_WORK/absent.json" "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'MANIFEST: missing' <<<"$out"
  assert grep -qx 'REASON: claudeb skipped — native messaging manifest missing' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  rc=0
  out=$(BROWSE_CHROME_MANIFEST="$BT_WORK/dead-manifest" BROWSE_NATIVE_HOST="$BT_WORK/absent-host" "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'MANIFEST: broken' <<<"$out"
  assert grep -qx 'REASON: claudeb skipped — native host missing at /dead/profile/chrome-native-host' <<<"$out"
  chmod -x "$BROWSE_NATIVE_HOST"
  rc=0
  out=$("$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'MANIFEST: broken' <<<"$out"
  chmod +x "$BROWSE_NATIVE_HOST"

  jq '.profile.last_active_profiles = ["Profile 8", "Profile 7", "Profile 8"] | .profile.info_cache["Profile 7"].name = "home dia"' \
    "$BT_DIA/Local State" >"$BT_WORK/two-profiles"
  cp "$BT_WORK/two-profiles" "$BT_DIA/Local State"
  mkdir -p "$BT_DIA/Profile 7/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn"
  printf 'bridgeDeviceId "%s" displayName "Home browser"\n' "$other_dev" >"$BT_DIA/Profile 7/Local Extension Settings/fcoeoabgfenejglbffodgkkbkcdhcgfn/000001.log"
  out=$("$RUNNER" browse --record "$other_dev" notcom)
  cat >"$BT_WP.profiles" <<'EOF'
#!/bin/sh
printf 'claude: com WALLED\n        notcom\n'
EOF
  chmod +x "$BT_WP.profiles"
  BROWSE_WORKER_PICK="$BT_WP.profiles"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'DIA-PROFILE: home dia (Profile 7)' <<<"$out"
  assert grep -qx "PLAN: claudeb account=notcom device=$other_dev source=cached" <<<"$out"
  assert grep -qx "DIA-OTHER: work dia (Profile 8) $dev account=com" <<<"$out"
  assert grep -qx 'REASON: dia/work dia skipped — account com walled' <<<"$out"
  assert test "$(grep -c '^DIA-OTHER:' <<<"$out")" -eq 1
  json_out=$("$RUNNER" browse --vendor claudeb --json)
  assert jq -e '.dia_profile.dir == "Profile 7" and .dia_other[0].account == "com" and .manifest == "ok"' <<<"$json_out" >/dev/null
  assert jq -e '.reasons | index("dia/work dia skipped — account com walled") != null' <<<"$json_out" >/dev/null
  rc=0
  out=$("$RUNNER" browse --vendor claudeb --dia-profile 'Profile 8') || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'DIA-PROFILE: work dia (Profile 8)' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  assert test "$(grep -c '^DIA-OTHER:' <<<"$out")" -eq 0
  BROWSE_WORKER_PICK="$BT_WP.multi"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx 'DIA-PROFILE: work dia (Profile 8)' <<<"$out"
  assert grep -qx "DIA-OTHER: home dia (Profile 7) $other_dev account=notcom" <<<"$out"
  printf '{}\n' >"$cache"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx "PLAN: claudeb account=com device=$dev source=probe" <<<"$out"
  assert grep -qx "DIA-OTHER: home dia (Profile 7) $other_dev unknown" <<<"$out"

  local vendor original_brief
  original_brief=$(cat "$WORK/brief")
  for vendor in codex claudeb; do
    clear_stub
    rc=0
    out=$(BROWSE_WORKER_PICK="$BT_WP.empty" "$RUNNER" start "$vendor" --browser --brief "$WORK/brief") || rc=$?
    assert test "$rc" -eq 2
    assert grep -qx 'REASON: claudeb skipped — no accounts' <<<"$out"
    assert grep -qx 'REASON: codex skipped — unavailable' <<<"$out"
    assert test ! -s "$CALL_LOG"
    assert test "$(grep -c '^RUN:' <<<"$out")" -eq 0
  done
  printf '#!/usr/bin/env bash\nprintf "codex:   off for workers\\nclaude:  no accounts\\n"\n' >"$BT_WP.off"
  chmod +x "$BT_WP.off"
  out=$(BROWSE_WORKER_PICK="$BT_WP.off" "$RUNNER" browse) || :
  assert grep -qx 'REASON: codex skipped — off for workers' <<<"$out"
  clear_stub
  out=$("$RUNNER" browse --record "$dev" com)
  rc=0
  out=$("$RUNNER" start claudeb --browser --account spare --brief "$WORK/brief") || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx "REASON: claudeb/spare cannot see device $dev; plan says com" <<<"$out"
  assert test ! -s "$CALL_LOG"

  clear_stub
  BROWSE_WORKER_PICK="$BT_WP"
  start_ok claudeb --browser
  assert await_done
  assert meta_account_is com
  assert test ! -s "$PICK_LOG"
  assert grep -qx 'ARG=--chrome' "$CALL_LOG"
  assert jq -e --arg dev "$dev" '.browser == true and .chrome == true and .browser_device == $dev and .browser_account == "com"' "$RUN_DIR/meta.json" >/dev/null
  assert test "$(head -n1 "$RUN_DIR/brief.launch")" = '# Browser Automation Preamble (Claudeb / Dia)'
  assert grep -q 'list_connected_browsers' "$STUB_DIR/claudeb.stdin"
  assert grep -qx 'test brief' "$STUB_DIR/claudeb.stdin"
  assert cmp -s "$WORK/brief" "$RUN_DIR/brief"
  assert test "$(cat "$WORK/brief")" = "$original_brief"

  clear_stub
  start_ok claudeb --browser --account com
  assert await_done
  assert meta_account_is com

  clear_stub
  start_ok codex --browser --account alternate
  assert await_done
  assert meta_account_is alternate
  assert jq -e '.browser == true and .chrome == false and .browser_account == "alternate"' "$RUN_DIR/meta.json" >/dev/null
  assert grep -q 'await cua.getState()' "$STUB_DIR/codex.stdin"
  assert grep -qx 'test brief' "$STUB_DIR/codex.stdin"
  assert test "$(cat "$WORK/brief")" = "$original_brief"

  # A codex plan names no device, and what the run then records is the TARGET's browser: the other
  # browser's uuid in meta.json points every later reader at a device the run never touched.
  clear_stub
  start_ok codex --browser --target chrome --account alternate
  assert await_done
  assert jq -e --arg dev "$chrome_dev" '.browser_device == $dev' "$RUN_DIR/meta.json" >/dev/null
  clear_stub
  start_ok codex --browser --target dia --account alternate
  assert await_done
  assert jq -e --arg dev "$dev" '.browser_device == $dev' "$RUN_DIR/meta.json" >/dev/null

  clear_stub
  BT_SYNC_MODE=broken
  rc=0
  out=$("$RUNNER" start codex --browser --brief "$WORK/brief") || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: codex skipped — cua_repl registration failed: fake registration failure' <<<"$out"
  assert test ! -s "$CALL_LOG"
  BT_SYNC_MODE=registered

  clear_stub
  export STUB_CODE=1 STUB_ERROR='hit your usage limit'
  start_ok claudeb --browser
  assert await_done
  assert meta_account_is com
  assert test ! -s "$PICK_LOG"
  assert test "$(grep -c '^CLAUDEB_CALL$' "$CALL_LOG")" -eq 1
  assert grep -qx 'WALL: browser device stays on com' "$WORK/wait.out"
  clear_stub

  unset BROWSE_CODEX_CONFIG
  local SYNC_TEST_HOME="$BT_WORK/codex_sync_home"
  local SYNC_MANIFEST_DIR="$SYNC_TEST_HOME/plugins/cache/openai-bundled/unified-computer-use/26.901.51231"
  mkdir -p "$SYNC_MANIFEST_DIR" "$SYNC_TEST_HOME" "$BT_WORK/bin"

  cat >"$SYNC_MANIFEST_DIR/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "cua_repl": {
      "command": "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node",
      "args": ["/path/to/launch.mjs"],
      "env": {
        "NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER": "Browser instructions from manifest",
        "NODE_REPL_NODE_PATH": "/path/to/node"
      }
    }
  }
}
EOF

  cat >"$SYNC_TEST_HOME/config.toml" <<'EOF'
[mcp_servers.node_repl.env]
NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = ""
EOF

  local SYNC_LOG="$BT_WORK/codex_cli.log"
  : >"$SYNC_LOG"
  cat >"$BT_WORK/bin/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYNC_LOG"
EOF
  chmod +x "$BT_WORK/bin/codex"

  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 1

  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/sync.out" || rc=$?
  assert test "$rc" -eq 0
  assert test "$(grep -c 'mcp remove cua_repl' "$SYNC_LOG")" -eq 0
  assert grep -q 'mcp add cua_repl' "$SYNC_LOG"
  assert grep -q 'startup_timeout_sec = 120' "$SYNC_TEST_HOME/config.toml"
  assert grep -q 'NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "Browser instructions from manifest"' "$SYNC_TEST_HOME/config.toml"

  rc=0
  out=$(CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check) || rc=$?
  assert test "$rc" -eq 0
  assert test "$out" = 'unchanged'
  local newer_manifest="$SYNC_TEST_HOME/plugins/cache/openai-bundled/unified-computer-use/26.901.100000/.mcp.json"
  mkdir -p "${newer_manifest%/*}"
  jq '.mcpServers.cua_repl.args = ["/new-version/launch.mjs"]' "$SYNC_MANIFEST_DIR/.mcp.json" >"$newer_manifest"
  touch -t 202001010000 "$newer_manifest"
  printf '\n[mcp_servers.decoy]\nargs = ["/new-version/launch.mjs"]\n' >>"$SYNC_TEST_HOME/config.toml"
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null || rc=$?
  assert test "$rc" -eq 1
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/sync-update.out"
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null
  assert grep -qx 'args = ["/new-version/launch.mjs"]' "$SYNC_TEST_HOME/config.toml" -F
  assert grep -qx '[mcp_servers.decoy]' "$SYNC_TEST_HOME/config.toml" -F

  cp "$SYNC_TEST_HOME/config.toml" "$BT_WORK/override.toml"
  jq '.mcpServers.cua_repl.args = ["/third-version/launch.mjs"]' "$newer_manifest" >"$BT_WORK/updated-manifest"
  mv "$BT_WORK/updated-manifest" "$newer_manifest"
  assert env CODEX_HOME="$SYNC_TEST_HOME" BROWSE_CODEX_CONFIG="$BT_WORK/override.toml" PATH="$BT_WORK/bin:$PATH" \
    "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/override-sync.out"
  assert grep -qxF 'args = ["/third-version/launch.mjs"]' "$BT_WORK/override.toml"
  assert test "$(grep -c '/third-version/' "$SYNC_TEST_HOME/config.toml")" -eq 0

  # 1: multiline/quoted instruction values survive TOML fill
  jq '.mcpServers.cua_repl.env.NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "line1\nquote \"here\" and \\slash"' \
    "$newer_manifest" >"$BT_WORK/nl-manifest" && mv "$BT_WORK/nl-manifest" "$newer_manifest"
  cat >"$BT_WORK/nl.toml" <<'EOF'
[mcp_servers.node_repl.env]
NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = ""
EOF
  assert env CODEX_HOME="$SYNC_TEST_HOME" BROWSE_CODEX_CONFIG="$BT_WORK/nl.toml" PATH="$BT_WORK/bin:$PATH" \
    "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/nl-sync.out"
  python3 -c '
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
needle = "NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER = "
idx = text.find(needle)
assert idx >= 0, text
rest = text[idx + len(needle):].splitlines()[0]
got = json.loads(rest)
assert got == "line1\nquote \"here\" and \\slash", got
' "$BT_WORK/nl.toml"
  rc=0
  out=$(CODEX_HOME="$SYNC_TEST_HOME" BROWSE_CODEX_CONFIG="$BT_WORK/nl.toml" PATH="$BT_WORK/bin:$PATH" \
    "$ROOT/bin/codex-cua-repl-sync" --check) || rc=$?
  assert test "$rc" -eq 0
  assert test "$out" = 'unchanged'

  # 3: extra args/env keys are out of sync
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >/dev/null
  python3 -c '
from pathlib import Path
p = Path("'"$SYNC_TEST_HOME"'/config.toml")
text = p.read_text()
sec = text.find("[mcp_servers.cua_repl]")
assert sec >= 0, text
idx = text.find("args = ", sec)
nxt = text.find("\n[", idx + 1)
if nxt < 0: nxt = len(text)
assert idx >= 0 and idx < nxt, text
end = text.find("]", idx)
text = text[:end] + ", \"stale-extra\"" + text[end:]
p.write_text(text)
'
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null || rc=$?
  assert test "$rc" -eq 1
  assert env CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >/dev/null
  awk '
    /^[[:space:]]*\[mcp_servers\.cua_repl\.env\]/ { print; print "STALE_ENV_KEY = \"nope\""; next }
    { print }
  ' "$SYNC_TEST_HOME/config.toml" >"$BT_WORK/stale-env.toml"
  mv "$BT_WORK/stale-env.toml" "$SYNC_TEST_HOME/config.toml"
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null || rc=$?
  assert test "$rc" -eq 1

  # 4: empty-array --check under bash 3.2 + set -u
  if [ -x /bin/bash ]; then
    rc=0
    CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" \
      /bin/bash "$ROOT/bin/codex-cua-repl-sync" --check >/dev/null 2>"$BT_WORK/bash32.err" || rc=$?
    assert test "$rc" -ne 127
    assert test "$(grep -c 'unbound variable' "$BT_WORK/bash32.err")" -eq 0
  fi

  # 5: mcp add failure still writes TOML and does not remove first
  : >"$SYNC_LOG"
  cat >"$BT_WORK/bin/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SYNC_LOG"
exit 1
EOF
  chmod +x "$BT_WORK/bin/codex"
  jq '.mcpServers.cua_repl.args = ["/after-failed-add/launch.mjs"]' "$newer_manifest" >"$BT_WORK/fail-add-manifest"
  mv "$BT_WORK/fail-add-manifest" "$newer_manifest"
  rc=0
  CODEX_HOME="$SYNC_TEST_HOME" PATH="$BT_WORK/bin:$PATH" "$ROOT/bin/codex-cua-repl-sync" >"$BT_WORK/fail-add.out" || rc=$?
  assert test "$rc" -eq 0
  assert test "$(grep -c 'mcp remove cua_repl' "$SYNC_LOG")" -eq 0
  assert grep -q 'mcp add cua_repl' "$SYNC_LOG"
  assert grep -qxF 'args = ["/after-failed-add/launch.mjs"]' "$SYNC_TEST_HOME/config.toml"

  # 6: missing Sky app → SKY: absent without polling; --vendor claudeb does not launch Sky
  cat >"$BT_WORK/bin/pgrep-dia" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PGREP_LOG:-/dev/null}"
for a in "$@"; do
  case "$a" in *Dia*) exit 0 ;; esac
done
exit 1
EOF
  chmod +x "$BT_WORK/bin/pgrep-dia"
  : >"$BT_WORK/open.log"
  cat >"$BT_WORK/bin/open-log" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BT_WORK/open.log"
exit 1
EOF
  chmod +x "$BT_WORK/bin/open-log"
  : >"$BT_WORK/pgrep.log"
  rc=0
  out=$(PGREP_LOG="$BT_WORK/pgrep.log" BROWSE_PGREP="$BT_WORK/bin/pgrep-dia" BROWSE_OPEN="$BT_WORK/bin/open-log" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$(grep -c SkyComputerUseService "$BT_WORK/pgrep.log")" -lt 10
  assert grep -qx 'SKY: absent' <<<"$out"
  assert test "$(grep -c 'Computer Use' "$BT_WORK/open.log")" -eq 0
  mkdir -p "$BT_WORK/Codex Computer Use.app"
  : >"$BT_WORK/open.log"
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-dia" BROWSE_OPEN="$BT_WORK/bin/open-log" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/Codex Computer Use.app" \
        "$RUNNER" browse --vendor claudeb) || true
  assert grep -qx 'SKY: absent' <<<"$out"
  assert test "$(grep -c 'Computer Use' "$BT_WORK/open.log")" -eq 0

  # 12: Dia absent + failed launch → PLAN: none
  cat >"$BT_WORK/bin/pgrep-none" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$BT_WORK/bin/pgrep-none"
  SECONDS=0
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-none" BROWSE_OPEN="$BT_WORK/bin/open-log" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse) || rc=$?
  assert test "$rc" -eq 2
  # The 15 s launch deadline plus the 25 s extension wait: only a stacked or unbounded wait reaches it.
  assert test "$SECONDS" -lt 40
  assert grep -qx 'DIA: absent' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  assert grep -qx 'REASON: dia not running' <<<"$out"
  assert test "$(grep -c '^PLAN: codex' <<<"$out")" -eq 0
  assert test "$(grep -c '^PLAN: claudeb' <<<"$out")" -eq 0

  # 7: prune preamble-*.md older than 24h
  mkdir -p "$BT_RUNS/browse"
  printf 'stale\n' >"$BT_RUNS/browse/preamble-old.md"
  touch -t 202001010000 "$BT_RUNS/browse/preamble-old.md"
  out=$("$RUNNER" browse)
  assert test ! -e "$BT_RUNS/browse/preamble-old.md"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test -f "$preamble_path"

  # 9: start prune must not delete browse/
  mkdir -p "$BT_RUNS/codex-ancient-run" "$BT_RUNS/browse"
  printf '{}\n' >"$BT_RUNS/browse/devices.json"
  touch -t 202001010000 "$BT_RUNS/codex-ancient-run" "$BT_RUNS/browse" "$BT_RUNS/browse/devices.json" "$BT_RUNS/.prune"
  clear_stub
  export PICK_ACCOUNT=fast PICK_RC=0
  start_ok codex
  assert test -d "$BT_RUNS/browse"
  assert test -f "$BT_RUNS/browse/devices.json"
  assert test ! -d "$BT_RUNS/codex-ancient-run"

  # 10: dead pid lock is stolen
  mkdir -p "$BT_RUNS/browse/devices.lock.d"
  printf '99999999\n' >"$BT_RUNS/browse/devices.lock.d/pid"
  printf '{}\n' >"$BT_RUNS/browse/devices.json"
  out=$("$RUNNER" browse --record "$dev" com)
  assert grep -qx "RECORDED: $dev com" <<<"$out"
  assert jq -e --arg dev "$dev" '.[$dev].account == "com"' "$BT_RUNS/browse/devices.json" >/dev/null
  assert test ! -e "$BT_RUNS/browse/devices.lock.d"

  # 13: denied mapping orders that account last
  jq -n --arg dev "$dev" --arg seen "2026-09-01T00:00:00Z" \
    '{($dev): {account:"com", seen:$seen, denied:true}}' >"$cache"
  BROWSE_WORKER_PICK="$BT_WP.multi"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  out=$("$RUNNER" browse --vendor claudeb)
  assert grep -qx "REASON: claudeb/com skipped — device $dev not visible (probe failed 2026-09-01T00:00:00Z)" <<<"$out"
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: spare,com' <<<"$out"
  assert grep -qx "PLAN: claudeb account=spare device=$dev source=probe" <<<"$out"
  BROWSE_WORKER_PICK="$BT_WP"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"

  # 14: ordinary runs do not mutate devices.json
  printf '{"com":{"account":"com","seen":"keep"}}\n' >"$cache"
  ordinary="$BT_RUNS/codex-ordinary"
  mkdir -p "$ordinary"
  printf '{"vendor":"codex","account":"main","workdir":"%s","started_at":0,"pid":0,"browser":false,"chrome":false}\n' \
    "$WORK/workdir" >"$ordinary/meta.json"
  : >"$ordinary/err"
  printf 'BROWSER-DEVICE-ACCOUNT: %s poisoned\n' "$dev" >"$ordinary/out"
  assert "$RUNNER" _deliver "$ordinary" 0 >/dev/null
  assert jq -e '.com.account == "com" and .com.seen == "keep"' "$cache" >/dev/null
  assert jq -e --arg dev "$dev" 'has($dev) | not' "$cache" >/dev/null

  # 15: pin-lapse note is not an account named pin; PINNED flag is not an account
  cat >"$BT_WP.pinned" <<'EOF'
#!/usr/bin/env bash
cat <<'OUTPUT'
claude:  pin com walled → extra
          8.6%/d ×7.0d   40%   30%   extra                opus·high
         11.4%/d ×7.0d   20%   20%   com                  opus·high PINNED
OUTPUT
EOF
  chmod +x "$BT_WP.pinned"
  BROWSE_WORKER_PICK="$BT_WP.pinned"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  printf '{}\n' >"$cache"
  out=$("$RUNNER" browse --vendor claudeb)
  assert test "$(grep -c 'claudeb/pin ' <<<"$out")" -eq 0
  assert test "$(grep -c 'account=pin' <<<"$out")" -eq 0
  assert grep -qx 'NEXT-CLAUDE-ACCOUNTS: extra,com' <<<"$out"
  assert grep -qx "PLAN: claudeb account=extra device=$dev source=probe" <<<"$out"
  BROWSE_WORKER_PICK="$BT_WP"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"

  # 16: --target chrome flips which device is drivable and which is off-target
  printf '{}\n' >"$cache"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  out=$("$RUNNER" browse --target chrome --vendor claudeb)
  assert grep -qx 'TARGET: chrome' <<<"$out"
  assert grep -qx 'CHROME-DEVICE: b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d "Chrome browser"' <<<"$out"
  assert grep -qx 'DIA-DEVICE: 6ada21d4-ae66-4990-9040-97e18bb7b529 "Dia browser"' <<<"$out"
  assert grep -qx 'PLAN: claudeb account=com device=b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d source=probe' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert grep -qF 'Target Google Chrome device ID: b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d' "$preamble_path"
  assert grep -qF 'Off-target extension device IDs (Dia — never drive one, never `switch_browser` to it): ' "$preamble_path"
  assert grep -qF '6ada21d4-ae66-4990-9040-97e18bb7b529' "$preamble_path"
  assert grep -qxF -- '- Never drive Dia.' "$preamble_path"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"
  out=$("$RUNNER" browse --target chrome --vendor codex)
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert grep -q 'Codex / Google Chrome' "$preamble_path"
  assert grep -q 'profileName. is "Egor work"' "$preamble_path"
  assert grep -q 'WITHOUT a `profileName` is Dia' "$preamble_path"
  assert grep -q 'Never drive Dia' "$preamble_path"
  json_out=$("$RUNNER" browse --target chrome --vendor codex --json)
  assert test "$(jq -r .target <<<"$json_out")" = 'chrome'

  # 17: the default is a literal, and only dia|chrome are targets
  out=$("$RUNNER" browse --vendor codex)
  assert grep -qx 'TARGET: dia' <<<"$out"
  preamble_path=$(sed -n 's/^PREAMBLE-FILE: //p' <<<"$out")
  assert test "$(grep -c 'Codex / Dia' "$preamble_path")" -eq 1
  for bad in opera '' --json; do
    rc=0
    "$RUNNER" browse --target "$bad" >/dev/null 2>&1 || rc=$?
    assert test "$rc" -eq 2
  done
  rc=0
  "$RUNNER" browse --target >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 2
  clear_stub
  rc=0
  "$RUNNER" start codex --target chrome --brief "$WORK/brief" >/dev/null 2>&1 || rc=$?
  assert test "$rc" -eq 2
  assert test ! -s "$CALL_LOG"

  # 18: a closed target browser launches itself, in the background and without a URL
  : >"$BT_WORK/launch.log"
  cat >"$BT_WORK/bin/open-launch" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BT_WORK/launch.log"
cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
: >"$BT_WORK/launched.marker"
EOF
  chmod +x "$BT_WORK/bin/open-launch"
  cat >"$BT_WORK/bin/pgrep-marker" <<EOF
#!/bin/sh
test -e "$BT_WORK/launched.marker"
EOF
  chmod +x "$BT_WORK/bin/pgrep-marker"
  rm -f "$BT_WORK/launched.marker"
  : >"$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_OPEN="$BT_WORK/bin/open-launch" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_LAUNCH_TIMEOUT=5 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'LAUNCHED: dia' <<<"$out"
  assert grep -qx 'DIA: launched' <<<"$out"
  assert grep -qx -- '-g -a Dia' "$BT_WORK/launch.log"
  assert test "$(grep -c Chrome "$BT_WORK/launch.log")" -eq 0
  assert grep -q '^PLAN: claudeb ' <<<"$out"

  rm -f "$BT_WORK/launched.marker"
  : >"$BT_PS_LISTING"
  : >"$BT_WORK/launch.log"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_OPEN="$BT_WORK/bin/open-launch" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_LAUNCH_TIMEOUT=5 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'LAUNCHED: chrome' <<<"$out"
  assert grep -qx 'CHROME: launched' <<<"$out"
  assert grep -qF -- '--profile-directory=Profile 1' "$BT_WORK/launch.log"
  assert test "$(grep -c ' Dia' "$BT_WORK/launch.log")" -eq 0
  # Chrome's own claude host answers for it, so the wait ends instead of timing out.
  assert test "$(grep -c 'did not connect' <<<"$out")" -eq 0

  # 19: launched but the extension never connects — one instruction, and no plan
  cat >"$BT_WORK/bin/open-launch-mute" <<EOF
#!/bin/sh
cp "$BT_WORK/ps-chrome-bare" "$BT_PS_LISTING"
: >"$BT_WORK/launched.marker"
EOF
  chmod +x "$BT_WORK/bin/open-launch-mute"
  rm -f "$BT_WORK/launched.marker"
  : >"$BT_PS_LISTING"
  SECONDS=0
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_OPEN="$BT_WORK/bin/open-launch-mute" \
        BROWSE_SKIP_PROCESSES=0 BROWSE_LAUNCH_TIMEOUT=1 BROWSE_SKY_APP="$BT_WORK/no-sky-app" \
        "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  # The default extension wait BROWSE_LAUNCH_TIMEOUT=1 replaces.
  assert test "$SECONDS" -lt 25
  assert grep -qx 'LAUNCHED: chrome' <<<"$out"
  assert grep -qx "REASON: Google Chrome launched but the Claude extension did not connect within 1s — open Google Chrome's extensions page and check the extension is enabled in Egor work" <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"

  # 20: a ChatGPT host under the other browser is not this target's transport
  cp "$BT_WORK/ps-chrome-bare" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_SKIP_PROCESSES=0 BROWSE_CHROME_STATUS=running \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --target chrome --vendor codex) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: codex skipped — the ChatGPT extension is not connected in Google Chrome (Egor work); enable it at chrome://extensions and sign in' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-marker" BROWSE_SKIP_PROCESSES=0 BROWSE_CHROME_STATUS=running \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --target chrome --vendor codex) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  assert test "$(grep -c 'ChatGPT extension is not connected' <<<"$out")" -eq 0

  # 20b: the same parentage the other way round — Chrome's ChatGPT host is not Dia's transport
  cat >"$BT_WORK/bin/pgrep-yes" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$BT_WORK/bin/pgrep-yes"
  cp "$BT_WORK/ps-dia-bare" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-yes" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: codex skipped — the ChatGPT extension is not connected in Dia (work dia); enable it at dia://extensions and sign in' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  cp "$BT_WORK/ps-connected" "$BT_PS_LISTING"
  rc=0
  out=$(BROWSE_PGREP="$BT_WORK/bin/pgrep-yes" BROWSE_SKIP_PROCESSES=0 \
        BROWSE_SKY_APP="$BT_WORK/no-sky-app" "$RUNNER" browse --vendor codex) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: codex account=main' <<<"$out"
  assert test "$(grep -c 'ChatGPT extension is not connected' <<<"$out")" -eq 0

  # 21: a device no pool account can see is a sign-in instruction, never a plan
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF.nocua"
  cat >"$BT_WP.single" <<'EOF'
#!/bin/sh
printf 'claude: com\n'
EOF
  chmod +x "$BT_WP.single"
  jq -n --arg dev b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d --arg seen '2026-09-01T00:00:00Z' \
    '{($dev): {account:"com", seen:$seen, denied:true}}' >"$cache"
  rc=0
  out=$(BROWSE_WORKER_PICK="$BT_WP.single" "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 2
  assert grep -qx 'REASON: sign in the Claude extension in Google Chrome (Egor work) as com — device b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d is visible to no pool account' <<<"$out"
  assert grep -qx 'PLAN: none' <<<"$out"
  rc=0
  out=$(BROWSE_WORKER_PICK="$BT_WP.multi" "$RUNNER" browse --target chrome --vendor claudeb) || rc=$?
  assert test "$rc" -eq 0
  assert grep -qx 'PLAN: claudeb account=spare device=b1a2c3d4-e5f6-4a1b-8c2d-3e4f5a6b7c8d source=probe' <<<"$out"
  assert test "$(grep -c 'sign in the Claude extension' <<<"$out")" -eq 0
  printf '{}\n' >"$cache"
  BROWSE_CODEX_CONFIG="$BT_CODEX_CONF"

}
browse_tests

echo "PASS: $asserts asserts; browse mode: Dia and Chrome preflight, launches, computer use sync"
