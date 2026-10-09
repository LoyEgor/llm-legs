#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
. "$(dirname "$0")/worker_run_harness.sh" || exit 1

browse_tests() {
  local BT_WORK="$WORK/browse_tests" out rc
  local bt="$BT_WORK" dev_com=aaaaaaaa-1111-4111-8111-111111111111 dev_extra=bbbbbbbb-2222-4222-8222-222222222222
  mkdir -p "$bt/stub" "$bt/chrome" "$bt/up"
  local account email
  for account in com:COM@x.test extra:extra@x.test lost:lost@x.test; do
    mkdir -p "$CLAUDEB_PROFILES_ROOT/${account%%:*}"
    jq -n --arg e "${account#*:}" '{oauthAccount:{emailAddress:$e}}' >"$CLAUDEB_PROFILES_ROOT/${account%%:*}/.claude.json"
  done
  printf '%s\n' '{"profile":{"info_cache":{"Profile 1":{"name":"Work","user_name":"com@x.test"},
    "Profile 2":{"name":"Extra","user_name":"extra@x.test"},"Profile 3":{"name":"Spare","user_name":"other@x.test"}}}}' \
    >"$bt/chrome/Local State"
  : >"$bt/tabs"
  : >"$bt/dia-tabs"
  cat >"$bt/stub/pgrep" <<EOF
#!/bin/sh
for a; do last=\$a; done
[ -e "$bt/up/\$last" ]
EOF
  cat >"$bt/stub/osascript" <<EOF
#!/bin/sh
[ "\$#" -eq 0 ] || printf '%s\n' "\$*" >>"$bt/osa.log"
case "\$*" in *frontmost*com.apple.Terminal*) echo com.apple.Terminal >"$bt/front" ;; *"get visible"*) cat "$bt/visible"; exit 0 ;; esac
cat "$bt/tabs"
EOF
  printf '#!/bin/sh\n[ "$1" = front ] && echo ASN:0x0-0x1: || printf "    bundleID=\\"%%s\\"\\n" "$(cat "%s/front")"\n' "$bt" >"$bt/stub/lsappinfo"
  echo com.apple.Terminal >"$bt/front"
  printf '#!/bin/sh\ncat "%s/dia-tabs"\n' "$bt" >"$bt/stub/dia-js"
  cat >"$bt/stub/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$bt/open.log"
for a; do last=\$a; done
printf '\n%s\n' "\$last" >>"$bt/tabs"
: >"$bt/up/Google Chrome"
echo com.google.Chrome >"$bt/front"
EOF
  cat >"$bt/stub/claudeb" <<EOF
#!/usr/bin/env bash
account=\$2
prompt=\$(cat)
printf '%s\n' "\$*" >>"$bt/claudeb.log"
printf '%s\n' "\$prompt" >"$bt/prompt-\$account"
mode=\$(cat "$bt/mode-\$account" 2>/dev/null || echo ok)
url=\$(grep -o 'http://127.0.0.1:[0-9]*/form?case=[^ ]*' <<<"\$prompt" | head -n 1)
[ -z "\$url" ] || [ "\$mode" != ok ] || curl -s "\${url%/form*}/submit?case=\${url##*=}&v=\${url##*=}" >/dev/null
case "\$mode" in
  ok | nosubmit) device=\$(cat "$bt/device-\$account"); result="BROWSER-PROVEN: \$device \$account"$'\n'"OUTCOME: BROWSER_OK" ;;
  unproven) result="OUTCOME: BROWSER_OK" ;;
  nodevice) result="OUTCOME: BROWSER_NO_DEVICE account=\$account" ;;
  *) result=done ;;
esac
jq -cn --arg r "\$result" '{result:\$r}'
EOF
  printf '#!/bin/sh\nprintf "%%s /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\\n" "$(cat "%s/chrome-etime")"\n' \
    "$bt" >"$bt/stub/ps"
  printf '1-00:00:00\n' >"$bt/chrome-etime"
  chmod +x "$bt/stub/"*
  printf '%s\n' "$dev_com" >"$bt/device-com"
  printf '%s\n' "$dev_extra" >"$bt/device-extra"
  printf 'cccccccc-3333-4333-8333-333333333333\n' >"$bt/device-lost"
  local BROWSE_PGREP="$bt/stub/pgrep" BROWSE_OSASCRIPT="$bt/stub/osascript" BROWSE_OPEN="$bt/stub/open" BROWSE_PS="$bt/stub/ps"
  local BROWSE_DIA_JS="$bt/stub/dia-js" BROWSE_CHROME_USER_DATA="$bt/chrome" BROWSE_SEEN_WAIT=2 BROWSE_WINDOW_WAIT=6 BROWSE_SETTLE_S=0
  local BROWSE_LSAPPINFO="$bt/stub/lsappinfo"
  export BROWSE_PGREP BROWSE_OSASCRIPT BROWSE_OPEN BROWSE_PS BROWSE_DIA_JS BROWSE_CHROME_USER_DATA BROWSE_SEEN_WAIT BROWSE_WINDOW_WAIT BROWSE_SETTLE_S
  export BROWSE_LSAPPINFO
  local front='-e tell application "System Events" to set frontmost of first application process whose bundle identifier is "com.apple.Terminal" to true'
  local registry="$WORKER_RUN_DIR/browse/accounts.json" log="$WORKER_RUN_DIR/browse/log.jsonl"
  browse() { WORKER_RUN_CLAUDEB="$bt/stub/claudeb" "$RUNNER" browse "$@"; }

  # 1: a window per profile, matched by email case-insensitively, opened once however often it is asked for
  assert grep -qx 'WINDOW: com Profile 1' <<<"$(browse --window com)"
  assert grep -qx 'WINDOW: com Profile 1' <<<"$(browse --window com)"
  assert test "$(cat "$bt/open.log")" = '-n -g -b com.google.Chrome --args --profile-directory=Profile 1 --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --disable-background-timer-throttling --disable-features=IntensiveWakeUpThrottling https://example.com/#worker-run=Profile-1'
  # the app frontmost before gets focus back from Chrome, once: Chrome stays visible unless hidden mode is on
  assert test "$(grep -cxF -- "$front" "$bt/osa.log")" -eq 1
  assert test "$(grep -c 'visible' "$bt/osa.log")" -eq 0
  rc=0; out=$(browse --window lost) || rc=$?
  assert test "$rc" -eq 1
  assert grep -qx 'WINDOW: lost failed' <<<"$out"

  # 1b: --hide hides Chrome and is remembered, re-hiding every window opened later; --show undoes both
  : >"$bt/osa.log"
  out=$(browse --hide)
  assert test -e "$WORKER_RUN_DIR/browse/hidden"
  assert grep -qx 'CHROME: hidden' <<<"$out"
  assert grep -q '^WARNING: this Chrome runs without the anti-throttling flags' <<<"$out"
  assert grep -qxF -- '-e tell application "System Events" to set visible of process "Google Chrome" to false' "$bt/osa.log"
  : >"$bt/osa.log"
  cp "$bt/tabs" "$bt/tabs.1"; cp "$bt/open.log" "$bt/open.1"
  browse --window extra >/dev/null
  mv -f "$bt/tabs.1" "$bt/tabs"; mv -f "$bt/open.1" "$bt/open.log"
  assert test "$(grep -c 'to false' "$bt/osa.log")" -eq 2
  assert test "$(grep -cxF -- "$front" "$bt/osa.log")" -eq 1
  assert test "$(grep -n 'to false' "$bt/osa.log" | head -n 1 | cut -d: -f1)" -lt "$(grep -nF -- "$front" "$bt/osa.log" | head -n 1 | cut -d: -f1)"
  : >"$bt/osa.log"
  assert grep -qx 'CHROME: shown' <<<"$(browse --show)"
  assert test ! -e "$WORKER_RUN_DIR/browse/hidden"
  assert grep -qxF -- '-e tell application "System Events" to set visible of process "Google Chrome" to true' "$bt/osa.log"
  # 1c: --toggle (the menu checkbox) shows a hidden Chrome and hides a visible one
  echo false >"$bt/visible"
  assert grep -qx 'CHROME: shown' <<<"$(browse --toggle)"
  echo true >"$bt/visible"
  assert grep -qx 'CHROME: hidden' <<<"$(browse --toggle)"
  assert test -e "$WORKER_RUN_DIR/browse/hidden"
  rm -f "$WORKER_RUN_DIR/browse/hidden"

  # 2: --seen reads the target browser's own tab list
  printf 'https://example.com/?wr=tok-1\n' >>"$bt/tabs"
  assert grep -qx 'SEEN: chrome' <<<"$(browse --seen tok-1)"
  # beside its profile's marker tab only: another profile signed in as the account proves nothing
  assert grep -qx 'SEEN: chrome' <<<"$(browse --seen tok-1 --account com)"
  printf '\nhttps://example.com/#worker-run=Profile-9\nhttps://example.com/?wr=tok-3\n' >>"$bt/tabs"
  rc=0; out=$(browse --seen tok-3 --account com) || rc=$?
  assert test "$rc" -eq 1
  assert grep -qx 'SEEN: none' <<<"$out"
  rc=0; out=$(browse --seen tok-1 --target dia) || rc=$?
  assert test "$rc" -eq 1
  assert grep -qx 'SEEN: none' <<<"$out"
  printf 'https://example.com/?wr=tok-2\n' >"$bt/dia-tabs"
  assert grep -qx 'SEEN: dia' <<<"$(browse --seen tok-2 --target dia)"

  # 3: enrolment proves each account in its own profile; no device is a login, no profile says so
  # (but a window this enrolment opened, or a young Chrome, has not reconnected its extension yet)
  printf 'nodevice\n' >"$bt/mode-extra"
  rc=0; out=$(browse --enroll extra) || rc=$?
  assert grep -qx 'ENROLL: extra proof-failed Profile 2 no-device' <<<"$out"
  assert jq -e '.extra.last_error | test("^its extension has not reconnected yet: Chrome or its window up [0-9] s$")' "$registry" >/dev/null
  printf '05:00\n' >"$bt/chrome-etime"
  assert grep -qx 'ENROLL: extra proof-failed Profile 2 no-device' <<<"$(browse --enroll extra)"
  assert jq -e '.extra.last_error | endswith("up 300 s")' "$registry" >/dev/null
  printf '10:00\n' >"$bt/chrome-etime"
  : >"$log"
  rc=0; out=$(browse --enroll all) || rc=$?
  assert test "$rc" -eq 1
  assert grep -qx "ENROLL: com ok Profile 1 $dev_com" <<<"$out"
  assert grep -qx 'ENROLL: extra needs-login Profile 2 no-device' <<<"$out"
  assert grep -q '^REASON: .*Profile 2.*dispatch share/briefs/claude-ext-login.md with ACCOUNT extra, EMAIL extra@x.test, PROFILE Profile 2$' <<<"$out"
  assert grep -qx 'ENROLL: lost no-profile' <<<"$out"
  assert grep -q -- '--pin <dir>' <<<"$out"
  assert jq -e --arg d "$dev_com" '.com.status == "ok" and .com.device_id == $d and (.com.proven_at | test("Z$"))
    and .com.email == "COM@x.test" and .com.chrome_profile == "Profile 1" and .extra.status == "needs-login"
    and .lost.status == "no-profile"' "$registry" >/dev/null
  assert grep -q 'profile com -p --model sonnet --effort low --chrome --output-format json' "$bt/claudeb.log"
  assert test "$(head -n 1 "$bt/prompt-com")" = '# Browser preamble (Claude in Chrome / Google Chrome / com)'
  assert grep -q -- "worker-run browse --seen [0-9]*-<candidate number> --account com\`" "$bt/prompt-com"
  assert test "$(grep -c '"outcome":"BROWSER_NO_DEVICE"' "$log")" -eq 1
  assert test "$(grep -c '"outcome":"BROWSER_OK"' "$log")" -eq 1
  assert test "$(grep -c -- '--profile-directory=Profile 2' "$bt/open.log")" -eq 1
  # A re-proof names the registry device first.
  browse --enroll com >/dev/null
  assert grep -q "\`$dev_com\` first when listed" "$bt/prompt-com"

  # 4: a pin wins over the email match, and names one account
  assert grep -qx 'ENROLL: lost ok Profile 3 cccccccc-3333-4333-8333-333333333333' <<<"$(browse --enroll lost --pin 'Profile 3')"
  assert jq -e '.lost.pin == true and .lost.status == "ok"' "$registry" >/dev/null
  assert_fails browse --enroll all --pin 'Profile 3'
  assert grep -q "^ACCOUNT: com ok Profile 1 $dev_com 20" <<<"$(browse)"
  # a BROWSER_OK with no proven device is no proof; a session that ends without an outcome is interrupted
  printf 'unproven\n' >"$bt/mode-lost"
  assert_fails browse --enroll lost
  assert jq -e '.lost.status == "proof-failed" and .lost.last_error == "BROWSER_UNPROVEN"' "$registry" >/dev/null
  assert jq -se '.[-1] | .outcome == "BROWSER_UNPROVEN" and .device == ""' "$log" >/dev/null
  printf 'mute\n' >"$bt/mode-lost"
  assert_fails browse --enroll lost
  assert jq -se '.[-1].outcome == "BROWSER_INTERRUPTED"' "$log" >/dev/null
  rm -f "$bt/mode-lost"
  browse --enroll lost >/dev/null

  # 5: BROWSER: chrome in the brief is a Chrome run on the account's own profile
  printf 'BROWSER: chrome\nACCOUNT: com\nfill the form\n' >"$WORK/brief"
  clear_stub
  STUB_SLEEP=2 start_ok claudeb
  # the menu's Show Chrome checkbox reads browse/chrome-live: written at a Chrome run's start, gone after the last ends
  assert test "$(cat "$WORKER_RUN_DIR/browse/chrome-live")" = "$RUN_ID"
  assert await_done
  assert test ! -e "$WORKER_RUN_DIR/browse/chrome-live"
  assert test "$(head -n 1 "$RUN_DIR/browser-preamble")" = '# Browser preamble (Claude in Chrome / Google Chrome / com)'
  assert grep -q "\`$dev_com\` first when listed" "$RUN_DIR/browser-preamble"
  assert grep -qF -- '- Never put `tabs_close_mcp` in a `browser_batch` with any other action' "$RUN_DIR/browser-preamble"
  assert grep -qx 'ARG=--chrome' "$CALL_LOG"
  assert jq -e '.browser == true and .browser_target == "chrome" and .browser_profile == "Profile 1"' "$RUN_DIR/meta.json" >/dev/null
  assert jq -se --arg run "$RUN_ID" '.[-1] | .run == $run and .outcome == "missing" and .workaround == false
    and .profile == "Profile 1" and .target == "chrome"' "$log" >/dev/null
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir" --browser --target dia >"$WORK/start.out" 2>&1 || rc=$?
  assert test "$rc" -ne 0
  assert grep -q "contradicts the brief header 'BROWSER: chrome'" "$WORK/start.out"
  printf 'BROWSER: maybe\nACCOUNT: com\nx\n' >"$WORK/brief"
  assert_fails "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir"
  printf 'ACCOUNT: com\nfill the form\n' >"$WORK/brief"
  clear_stub
  start_ok claudeb --browser
  assert await_done
  assert jq -e '.browser_target == "chrome"' "$RUN_DIR/meta.json" >/dev/null
  # with no account named, the picker is steered off accounts not enrolled ok
  printf 'BROWSER: chrome\nfill the form\n' >"$WORK/brief"
  clear_stub
  PICK_ACCOUNT=com start_ok claudeb
  assert await_done
  assert grep -q -- '--exclude .*extra' "$PICK_LOG"
  assert test "$(jq -r '.account' "$RUN_DIR/meta.json")" = com

  # 6: the Dia path never launches Dia
  printf 'BROWSER: yes\nACCOUNT: com\nlook\n' >"$WORK/brief"
  : >"$bt/open.log"
  rc=0
  "$RUNNER" start claudeb --brief "$WORK/brief" --workdir "$WORK/workdir" >"$WORK/start.out" 2>&1 || rc=$?
  assert test "$rc" -eq 2
  assert grep -q '^REASON: Dia is not running' "$WORK/start.out"
  : >"$bt/up/Dia"
  clear_stub
  start_ok claudeb
  assert await_done
  assert test "$(head -n 1 "$RUN_DIR/browser-preamble")" = '# Browser preamble (Claude in Chrome / Dia / com)'
  assert grep -q -- '--target dia`' "$RUN_DIR/browser-preamble"
  assert jq -e '.browser_target == "dia"' "$RUN_DIR/meta.json" >/dev/null
  assert test ! -s "$bt/open.log"
  rm -f "$bt/up/Dia"

  # 7: the supervisor's own record: a proof refreshes the device, a dead run is interrupted, a way around is flagged
  local fixture="$WORKER_RUN_DIR/browser-fixture" transcript="$CLAUDEB_PROFILES_ROOT/com/projects/fx/s1.jsonl" listed
  deliver() { # result-text exit-code [started-at]
    rm -rf "$fixture"
    mkdir -p "$fixture"
    printf '{"vendor":"claudeb","account":"com","workdir":"%s","started_at":%s,"pid":0,"browser":true,"browser_target":"chrome","browser_profile":"Profile 1"}\n' \
      "$WORK/workdir" "${3:-0}" >"$fixture/meta.json"
    : >"$fixture/err"
    jq -cn --arg r "$1" '{result:$r, session_id:"s1"}' >"$fixture/out"
    "$RUNNER" _deliver "$fixture" "$2" >/dev/null 2>&1 || :
    jq -sc '.[-1]' "$log"
  }
  mkdir -p "${transcript%/*}"
  listed=$(jq -cn --arg d "$dev_com" '[{deviceId:$d, isLocal:true}] | tostring')
  {
    jq -cn '{message:{content:[{type:"tool_use",id:"t1",name:"mcp__claude-in-chrome__list_connected_browsers",input:{}}]}}'
    jq -cn --arg t "$listed" '{message:{content:[{type:"tool_result",tool_use_id:"t1",content:[{type:"text",text:$t}]}]}}'
    jq -cn --arg d "$dev_com" '{message:{content:[{type:"tool_use",id:"t2",name:"mcp__claude-in-chrome__select_browser",input:{deviceId:$d}}]}}'
  } >"$transcript"
  out=$(deliver "$(printf 'BROWSER-PROVEN: dddddddd-4444-4444-8444-444444444444 com\nOUTCOME: BROWSER_OK')" 0)
  assert jq -e '.outcome == "BROWSER_OK" and .device == "dddddddd-4444-4444-8444-444444444444" and .workaround == false' <<<"$out" >/dev/null
  assert jq -e '.com.device_id == "dddddddd-4444-4444-8444-444444444444"' "$registry" >/dev/null
  assert jq -e '.outcome == "BROWSER_INTERRUPTED"' <<<"$(deliver 'half way' 1)" >/dev/null
  assert jq -e '.outcome == "missing"' <<<"$(deliver 'half way' 0)" >/dev/null
  jq -cn '{message:{content:[{type:"tool_use",id:"t3",name:"mcp__claude-in-chrome__select_browser",input:{deviceId:"eeeeeeee-5555-4555-8555-555555555555"}}]}}' >>"$transcript"
  assert jq -e '.workaround == true' <<<"$(deliver 'OUTCOME: BROWSER_OK' 0)" >/dev/null
  head -n 3 "$transcript" >"$transcript.tmp" && mv "$transcript.tmp" "$transcript"
  jq -cn '{message:{content:[{type:"tool_use",id:"t4",name:"Bash",input:{command:"osascript -e '\''tell application \"Dia\" to activate'\''"}}]}}' >>"$transcript"
  assert jq -e '.workaround == true' <<<"$(deliver 'OUTCOME: BROWSER_OK' 0)" >/dev/null
  head -n 3 "$transcript" >"$transcript.tmp" && mv "$transcript.tmp" "$transcript"
  jq -cn '{message:{content:[{type:"tool_use",id:"t5",name:"Bash",input:{command:"worker-run start claudeb --chrome --brief b"}}]}}' >>"$transcript"
  assert jq -e '.workaround == true' <<<"$(deliver 'OUTCOME: BROWSER_OK' 0)" >/dev/null
  head -n 3 "$transcript" >"$transcript.tmp" && mv "$transcript.tmp" "$transcript"
  jq -cn '{message:{content:[{type:"tool_use",id:"t6",name:"Bash",input:{command:"pgrep -f '\''Google Chrome.app/Contents/MacOS/Google Chrome'\''"}}]}}' >>"$transcript"
  assert jq -e '.workaround == false' <<<"$(deliver 'OUTCOME: BROWSER_OK' 0)" >/dev/null
  jq -cn '{message:{content:[{type:"tool_use",id:"t7",name:"Bash",input:{command:"cd /tmp && \"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\" --profile-directory=x"}}]}}' >>"$transcript"
  assert jq -e '.workaround == true' <<<"$(deliver 'OUTCOME: BROWSER_OK' 0)" >/dev/null
  # a resumed session's earlier runs are not this run's
  jq -c '. + {timestamp:"2026-01-01T00:00:00.123Z"}' "$transcript" >"$transcript.tmp" && mv "$transcript.tmp" "$transcript"
  assert jq -e '.workaround == false' <<<"$(deliver 'OUTCOME: BROWSER_OK' 0 "$(date +%s)")" >/dev/null
  rm -f "$transcript"

  # 8: a codex browser run needs its cua_repl registration and binds to the enrolled, open profiles
  local BROWSE_CUA_SYNC="$bt/stub/cua-sync" BROWSE_SKIP_PROCESSES=1 BROWSE_CODEX_CONFIG="$bt/codex.toml" BT_SYNC_MODE=broken
  export BROWSE_CUA_SYNC BROWSE_SKIP_PROCESSES BROWSE_CODEX_CONFIG BT_SYNC_MODE
  printf '#!/bin/sh\n[ "$BT_SYNC_MODE" = ok ] || { echo "fake registration failure" >&2; exit 2; }\n' >"$BROWSE_CUA_SYNC"
  chmod +x "$BROWSE_CUA_SYNC"
  printf 'BROWSER: chrome\nACCOUNT: main\nlook\n' >"$WORK/brief"
  rc=0
  "$RUNNER" start codex --brief "$WORK/brief" --workdir "$WORK/workdir" >"$WORK/start.out" 2>&1 || rc=$?
  assert test "$rc" -eq 2
  assert grep -q 'cua_repl registration failed: fake registration failure' "$WORK/start.out"
  BT_SYNC_MODE=ok
  # --enroll all enrols in parallel, so the registry's key order is whichever enrolment finished first.
  jq '{lost: .lost} + .' "$registry" >"$registry.tmp" && mv "$registry.tmp" "$registry"
  clear_stub
  start_ok codex
  assert await_done
  assert test "$(head -n 1 "$RUN_DIR/browser-preamble")" = '# Browser preamble (Codex / Google Chrome)'
  assert grep -q '"Work" (Profile 1), "Spare" (Profile 3)' "$RUN_DIR/browser-preamble"
  unset BROWSE_CUA_SYNC BROWSE_SKIP_PROCESSES BT_SYNC_MODE

  # 9: the canary's verdict is its own listener's receipt, and a live browser run holds it
  printf 'nosubmit\n' >"$bt/mode-lost"
  jq '.lost.proven_at = "2020-01-01T00:00:00Z"' "$registry" >"$registry.tmp" && mv "$registry.tmp" "$registry"
  rc=0; out=$(browse --canary) || rc=$?
  assert test "$rc" -eq 1
  assert grep -qx 'CANARY: com BROWSER_OK' <<<"$out"
  assert grep -qx 'CANARY: extra CANARY_NO_RECEIPT' <<<"$out"
  assert grep -qx 'CANARY: lost CANARY_NO_RECEIPT' <<<"$out"
  assert jq -e '.lost.proven_at == "2020-01-01T00:00:00Z"' "$registry" >/dev/null
  assert test -z "$(find "$WORKER_RUN_DIR/browse" -name 'canary.*' -type d)"
  assert test -e "$WORKER_RUN_DIR/browse/canary.stamp"
  assert jq -se 'map(select(.run | startswith("canary-com-"))) | length == 1' "$log" >/dev/null
  assert grep -q 'http://127.0.0.1:[0-9]*/form?case=canary-com-' "$bt/prompt-com"
  local holder
  sleep 300 &
  holder=$!
  mkdir -p "$WORKER_RUN_DIR/live-browser"
  printf '{"pid":%s,"started_at":%s,"browser":true}\n' "$holder" "$(date +%s)" >"$WORKER_RUN_DIR/live-browser/meta.json"
  : >"$bt/claudeb.log"
  assert grep -qx 'CANARY: skipped — a browser run is live' <<<"$(browse --canary)"
  assert test ! -s "$bt/claudeb.log"
  # hidden mode outlives a Chrome run while another is live, never the last one
  assert test "$("$RUNNER" _chrome-runs --browser)" = live-browser
  : >"$WORKER_RUN_DIR/browse/hidden"
  deliver 'OUTCOME: BROWSER_OK' 0 >/dev/null
  assert test -e "$WORKER_RUN_DIR/browse/hidden"
  assert test "$(cat "$WORKER_RUN_DIR/browse/chrome-live")" = live-browser
  mkdir -p "$WORKER_RUN_DIR/live-computer"
  printf '{"pid":%s,"started_at":%s,"computer":true}\n' "$holder" "$(date +%s)" >"$WORKER_RUN_DIR/live-computer/meta.json"
  assert test "$("$RUNNER" _chrome-runs --browser)" = live-browser
  assert_fails "$RUNNER" browse --hide
  rm -rf "$WORKER_RUN_DIR/live-computer"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  deliver 'OUTCOME: BROWSER_OK' 0 >/dev/null
  assert test ! -e "$WORKER_RUN_DIR/browse/hidden"
  assert test ! -e "$WORKER_RUN_DIR/browse/chrome-live"
  rm -rf "$WORKER_RUN_DIR/live-browser"
  unset -f browse deliver

  # cua_repl sync
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

  # 10: chrome-applescript-js edits Preferences only with Chrome quit and no worker run on Chrome
  local cj="$BT_WORK/cj" holder
  mkdir -p "$cj/data/Profile 1" "$cj/runs/browse" "$cj/runs/on-chrome" "$cj/runs/on-dia" "$cj/bin"
  printf '{"browser":{"other":1},"profile":{"name":"Egor work"}}\n' >"$cj/data/Profile 1/Preferences"
  printf '  700     1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n  701   700 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=renderer\n' >"$cj/ps.chrome"
  cp "$cj/ps.chrome" "$cj/ps.listing"
  printf '#!/bin/sh\nsed "s/^ *\\([0-9]*\\) *[0-9]* /\\1 /" "%s"\n' "$cj/ps.listing" >"$cj/bin/ps"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/osa.log"\n: >"%s"\n' "$cj" "$cj/ps.listing" >"$cj/bin/osascript"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/open.log"\ncp "%s" "%s"\n' "$cj" "$cj/ps.chrome" "$cj/ps.listing" >"$cj/bin/open"
  chmod +x "$cj/bin/"*
  sleep 300 &
  holder=$!
  printf '{"pid":%s,"started_at":%s,"browser":true,"browser_device":"chrome-dev"}\n' "$holder" "$(date +%s)" >"$cj/runs/on-chrome/meta.json"
  printf '{"pid":%s,"started_at":%s,"browser":true,"browser_device":"dia-dev","browser_target":"dia"}\n' "$holder" "$(date +%s)" >"$cj/runs/on-dia/meta.json"
  cj_run() {
    BROWSE_CHROME_USER_DATA="$cj/data" BROWSE_PS="$cj/bin/ps" BROWSE_OPEN="$cj/bin/open" CHROME_JS_OSASCRIPT="$cj/bin/osascript" \
      WORKER_RUN_DIR="$cj/runs" CHROME_JS_WAIT_S=3 CHROME_JS_SETTLE_S=0 "$ROOT/bin/chrome-applescript-js" "$@"
  }
  assert test "$(WORKER_RUN_DIR="$cj/runs" "$RUNNER" _chrome-runs)" = on-chrome
  assert grep -qx 'APPLESCRIPT-JS: off (Profile 1)' <<<"$(cj_run status)"
  rc=0
  out=$(cj_run enable) || rc=$?
  assert test "$rc" -eq 1
  assert grep -qx 'OUTCOME: CHROME_BUSY' <<<"$out"
  assert grep -qx 'RUN: on-chrome' <<<"$out"
  assert test ! -e "$cj/osa.log"
  : >"$cj/runs/on-chrome/exit_code"
  out=$(cj_run enable)
  assert grep -qx 'OUTCOME: ENABLED relaunched' <<<"$out"
  assert grep -q 'quit' "$cj/osa.log"
  assert grep -qx -- '-g -a Google Chrome --args --profile-directory=Profile 1 --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --disable-background-timer-throttling --disable-features=IntensiveWakeUpThrottling' "$cj/open.log"
  assert jq -e '.browser == {other:1, allow_javascript_apple_events:true} and .profile.name == "Egor work"' "$cj/data/Profile 1/Preferences" >/dev/null
  assert grep -qx 'OUTCOME: ALREADY_ON' <<<"$(cj_run enable)"
  mkdir -p "$cj/sib" "$cj/home"
  cp "$ROOT/bin/chrome-applescript-js" "$cj/sib/"
  printf '#!/bin/sh\n[ "$1" = _chrome-data ] && printf "%%s\\n" "%s"\n' "$cj/data" >"$cj/sib/worker-run"
  chmod +x "$cj/sib/worker-run"
  assert grep -qx 'APPLESCRIPT-JS: on (Profile 1)' <<<"$(env -u BROWSE_CHROME_USER_DATA HOME="$cj/home" "$cj/sib/chrome-applescript-js" status)"
  assert test "$(env -u BROWSE_CHROME_USER_DATA HOME="$cj/home" "$RUNNER" _chrome-data)" != "$cj/home/Library/Application Support/Google/Chrome"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

}
browse_tests

echo "PASS: $asserts asserts; browse mode: enrolment, window, proof, Chrome and Dia runs, the supervisor's outcome log, canary, cua_repl sync"
