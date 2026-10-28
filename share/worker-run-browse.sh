# worker-run's browse mode (`worker-run browse`: enrolment, windows, proof, canary), sourced by bin/worker-run in
# place, so an edit here runs its own suites rather than every suite of worker-run (Egor 2026-10-23).

# Chrome is automation's browser: each pool account owns a Chrome profile whose Claude extension is signed
# in as that account (accounts.json, written only by enrollment and live proofs). Dia is Egor's live
# browser: nothing here launches, quits or relaunches it.
BROWSE_UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# A restarted Chrome or a newly opened profile window lists no extension entry for up to ~10 min (live
# 2026-10-07); no device that soon is no sign-in problem.
BROWSE_RECONNECT_S=600 BROWSE_OPENED_AT=''
# Hidden or occluded, a page's timers otherwise slow to one tick a minute by minute 3 (live 2026-10-07).
CHROME_FLAGS=(--disable-renderer-backgrounding --disable-backgrounding-occluded-windows
  --disable-background-timer-throttling --disable-features=IntensiveWakeUpThrottling)

browse_real_home() {
  local home
  home=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
  [ -n "$home" ] || home="/Users/$(id -un)"
  [ -d "$home" ] || home="$HOME"
  printf '%s' "$home"
}

browse_codex_config() { # real-home
  if [ -n "${BROWSE_CODEX_CONFIG:-}" ]; then
    printf '%s' "$BROWSE_CODEX_CONFIG"
  elif [ -f "$HOME/.codex/config.toml" ] || [ ! -f "$1/.codex/config.toml" ]; then
    printf '%s' "$HOME/.codex/config.toml"
  else
    printf '%s' "$1/.codex/config.toml"
  fi
}

chrome_runs() { # [jq-filter] live run ids that may be driving Google Chrome
  find "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}" -mindepth 2 -maxdepth 2 -name meta.json -mtime -2 -print0 2>/dev/null |
    xargs -0 jq -r "select(${1:-.chrome == true or .computer == true or (.browser == true and .browser_target != \"dia\")})
      | input_filename" 2>/dev/null |
    while IFS= read -r meta; do
      ! run_live "${meta%/meta.json}" || printf '%s\n' "$(basename "${meta%/meta.json}")"
    done
}

# The last run that may drive Chrome quits it once idle, a Computer Use run's included (they left the canary's
# windows on screen, 2026-10-25); the last Computer Use run hides what it kept on screen unless Egor shows Chrome.
# The menu's Show Chrome reads the running Chrome itself, and Egor's choice to show it outlives every run.
chrome_run_end() { # run-directory
  local run=${1##*/}
  jq -e '.chrome == true or .computer == true or (.browser == true and .browser_target != "dia")' "$1/meta.json" >/dev/null 2>&1 ||
    return 0
  ! jq -e '.computer == true' "$1/meta.json" >/dev/null 2>&1 || [ -e "$(browse_dir)/shown" ] ||
    [ -n "$(chrome_runs '.computer == true' | grep -vxF -- "$run")" ] || ! browse_chrome_app_running || browse_chrome_visible false
  browse_quit_idle "$run"
}

# The brief header `BROWSER: chrome|yes|dia` sets the run's target as `ACCOUNT:` sets its account.
browse_header() { # brief; sets the caller's browser and browser_target
  local value target
  value=$(brief_line_value "$1" BROWSER)
  case "$value" in
    '') ;;
    chrome | yes | dia)
      target=chrome
      [ "$value" = chrome ] || target=dia
      [ -z "$browser_target" ] || [ "$browser_target" = "$target" ] ||
        fail "--target $browser_target contradicts the brief header 'BROWSER: $value': drop the flag, worker-run reads the header itself. Nothing was launched and no account was spent."
      browser=true browser_target=$target
      ;;
    *) fail "the brief header 'BROWSER: $value' names no target: chrome, or yes/dia for Egor's Dia. Nothing was launched and no account was spent." ;;
  esac
}

browse_vendor() { # vendor; sets the caller's chrome, or a REASON and 1
  case "$1" in
    claudeb) [ "${browser_target:-chrome}" = dia ] || chrome=true ;;
    codex) ;;
    *) printf 'REASON: %s does not support --browser\n' "$1"; return 1 ;;
  esac
}

browse_unready() { # the pool accounts whose Chrome profile is not enrolled ok, comma-joined
  browse_pool | jq -Rrn --argjson r "$(browse_registry)" '[inputs | select($r[.].status != "ok")] | join(",")'
}

browse_dir() { printf '%s/browse\n' "${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"; }

browse_chrome_data() { printf '%s\n' "${BROWSE_CHROME_USER_DATA:-$(browse_real_home)/Library/Application Support/Google/Chrome}"; }

browse_registry() {
  local registry
  registry=$(jq -c 'objects' "$(browse_dir)/accounts.json" 2>/dev/null) || registry=''
  [ -n "$registry" ] || registry='{}'
  printf '%s\n' "$registry"
}

browse_registry_set() { # account jq-update [jq-args...]
  local file account=$1 update=$2 rc=0
  shift 2
  file="$(browse_dir)/accounts.json"
  mkdir -p "${file%/*}" || return 1
  LLM_STORE_LOCK_RETRIES=40 store_lock_acquire "$file.lock" || {
    limit_hit worker-run.journal-lock 40 count retry-exhausted "browse accounts.json update of $account: $update" \
      'bin/worker-run:LLM_STORE_LOCK_RETRIES=40 store_lock_acquire "$file.lock"'
    return 1
  }
  browse_registry | jq --arg account "$account" "$@" '.[$account] = (.[$account] // {} | '"$update"')' \
    >"$file.tmp.$$" && mv -f "$file.tmp.$$" "$file" || rc=1
  rm -f "$file.tmp.$$"
  store_lock_release "$file.lock"
  return "$rc"
}

browse_email() { # account
  jq -r '.oauthAccount.emailAddress // empty' "${CLAUDEB_PROFILES_ROOT:-$HOME/.claude-profiles}/$1/.claude.json" 2>/dev/null
}

browse_pool() {
  local json
  for json in "${CLAUDEB_PROFILES_ROOT:-$HOME/.claude-profiles}"/*/.claude.json; do
    json=${json%/.claude.json}
    [ -z "$(browse_email "${json##*/}")" ] || printf '%s\n' "${json##*/}"
  done
}

browse_profile() { # account -> its Chrome profile directory, or nothing
  local dir email
  dir=$(browse_registry | jq -r --arg a "$1" '.[$a] | select(.pin == true) | .chrome_profile // empty')
  email=$(browse_email "$1")
  [ -n "$dir" ] || [ -z "$email" ] || dir=$(jq -r --arg e "$email" '.profile.info_cache // {} | to_entries
    | map(select((.value.user_name // "" | ascii_downcase) == ($e | ascii_downcase))) | .[0].key // empty' \
    "$(browse_chrome_data)/Local State" 2>/dev/null) || dir=$(browse_registry | jq -r --arg a "$1" '.[$a].chrome_profile // empty')
  printf '%s\n' "$dir"
}

browse_profile_label() { # directory
  local name
  name=$(jq -r --arg d "$1" '.profile.info_cache[$d].name // $d' "$(browse_chrome_data)/Local State" 2>/dev/null) || name=$1
  printf '"%s" (%s)\n' "$name" "$1"
}

# macOS App Data protection denies Chrome's data to a LaunchAgent's process tree (the Harness doctor's canary):
# profiles then come from the registry, and the Codex browser list names none.
browse_chrome_unreadable() { # -> why Chrome's Local State cannot be read, or nothing
  local why
  why=$(head -c 1 "$(browse_chrome_data)/Local State" 2>&1 >/dev/null) || printf "Chrome's Local State is unreadable: %s\n" "${why##*: }"
}

# By bundle id: the clones' processes (media, transcriptions) are named Google Chrome too, and AppleScript sent
# to com.google.Chrome while only a clone runs launches the real one.
browse_chrome_app_running() {
  "${BROWSE_OSASCRIPT:-osascript}" -e 'application id "com.google.Chrome" is running' 2>/dev/null | grep -qx true
}

browse_chrome_age() { # seconds since Chrome started or this process opened a profile window, whichever is later
  local age now
  now=$(date +%s)
  age=$(etime_seconds "$("${BROWSE_PS:-ps}" -Ao etime=,comm= | awk '/\/MacOS\/Google Chrome$/ { print $1; exit }')")
  age=${age:-0}
  [ -z "$BROWSE_OPENED_AT" ] || [ "$((now - BROWSE_OPENED_AT))" -ge "$age" ] || age=$((now - BROWSE_OPENED_AT))
  printf '%s\n' "$age"
}

# AppleScript addressed to a closed app launches it.
browse_chrome_urls() {
  browse_chrome_app_running || return 0
  "${BROWSE_OSASCRIPT:-osascript}" 2>/dev/null <<'APPLESCRIPT'
set out to ""
tell application id "com.google.Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      set out to out & (URL of t) & linefeed
    end repeat
    set out to out & linefeed
  end repeat
end tell
return out
APPLESCRIPT
}

# Chrome opens a URL handed to it in a window the profile already has, so the marker tab is both the
# proof the profile is open and the reason asking again never piles up windows. A running Chrome drops
# `open --args` without -n, and replaces an about: URL with the new-tab page. The extension of a window
# opened here connects ~25 s after it shows (live 2026-10-07): a proof listing sooner misses its device.
browse_marker() { printf 'https://example.com/#worker-run=%s\n' "${1// /-}"; }

# Chrome is automation's browser: once no run drives it and every tab is a marker, probe or canary page, it
# quits, or the windows a canary or run opened stay on Egor's screen for good (three, 2026-10-18).
browse_quit_idle() { # [run id that is ending]
  local urls
  [ -z "$(chrome_runs | grep -vxF -- "${1:-}")" ] || return 0
  browse_chrome_app_running || return 0
  urls=$(browse_chrome_urls) && grep -q . <<<"$urls" || return 0
  ! grep -v -e '^$' -e '^https://example\.com/' -e '^http://127\.0\.0\.1:' -e '^chrome://newtab/' <<<"$urls" | grep -q . || return 0
  "${BROWSE_OSASCRIPT:-osascript}" -e 'tell application id "com.google.Chrome" to quit' >/dev/null 2>&1 || :
}

browse_chrome_visible() { # true|false; System Events, since AppleScript to Chrome itself unhides and activates it
  "${BROWSE_OSASCRIPT:-osascript}" -e "tell application \"System Events\" to set visible of process \"Google Chrome\" to $1" >/dev/null 2>&1
}

browse_front() {
  "${BROWSE_LSAPPINFO:-lsappinfo}" info -only bundleid "$("${BROWSE_LSAPPINFO:-lsappinfo}" front 2>/dev/null)" 2>/dev/null |
    sed -n 's/.*bundleID="\(.*\)".*/\1/p'
}

# `open -g` still unhides Chrome and makes it frontmost when it opens a profile window (live 2026-10-07).
# Chrome stays hidden unless Egor turned Show Chrome on (browse/shown) or a Computer Use run needs it on
# screen: an automation Chrome nobody asked to see is never shown (Egor 2026-10-23).
browse_refocus() { # bundle id frontmost before; keep_shown set by browse_window
  local now
  now=$(browse_front)
  [ -n "$keep_shown" ] || browse_chrome_visible false
  [ -z "$1" ] || [ "$1" = com.google.Chrome ] || [ "$now" != com.google.Chrome ] || "${BROWSE_OSASCRIPT:-osascript}" \
    -e "tell application \"System Events\" to set frontmost of first application process whose bundle identifier is \"$1\" to true" >/dev/null 2>&1 || :
}

browse_window() { # profile-directory
  local marker i front keep_shown=''
  marker=$(browse_marker "$1")
  front=$(browse_front)
  # Show Chrome holds for the Chrome it was clicked for, never past it (Egor 2026-10-24: «По умолчанию он должен
  # быть выключен и не должен запоминаться»): a Chrome launched here starts hidden.
  browse_chrome_app_running || rm -f "$(browse_dir)/shown"
  [ ! -e "$(browse_dir)/shown" ] && [ -z "$(chrome_runs '.computer == true')" ] || keep_shown=1
  for ((i = 0; i < ${BROWSE_WINDOW_WAIT:-40}; i++)); do
    [ "$i" -eq 0 ] || browse_refocus "$front"
    browse_chrome_urls | grep -qxF -- "$marker" &&
      { [ "$i" -eq 0 ] || { sleep "${BROWSE_SETTLE_S:-30}"; browse_refocus "$front"; }; return 0; }
    [ "$i" -ne 0 ] || BROWSE_OPENED_AT=$(date +%s)
    [ "$i" -ne 0 ] || "${BROWSE_OPEN:-open}" -n -g -b com.google.Chrome --args --profile-directory="$1" "${CHROME_FLAGS[@]}" "$marker" >/dev/null 2>&1 || :
    sleep 0.5
  done
  limit_hit worker-run.browse-wait "${BROWSE_WINDOW_WAIT:-40}" count skip "the Chrome window of profile $1 never showed its marker tab: no browser run" \
    'bin/worker-run:BROWSE_WINDOW_WAIT:-40'
  return 1
}

# A Chrome window holds tabs of one profile only, so the token beside the profile's marker tab proves the
# device is that profile's extension; Chrome alone would accept another profile signed in as the account.
browse_seen() { # token target [account]
  local i marker=''
  [ -z "${3:-}" ] || marker=$(browse_marker "$(browse_profile "$3")")
  for ((i = 0; i < ${BROWSE_SEEN_WAIT:-20}; i++)); do
    if [ "$2" = dia ]; then "${BROWSE_DIA_JS:-$SCRIPT_DIRECTORY/dia-js}" --list 2>/dev/null; else browse_chrome_urls; fi |
      awk -v RS= -v t="$1" -v m="$marker" 'index($0, t) && (m == "" || index("\n" $0 "\n", "\n" m "\n")) { f = 1 } END { exit !f }' &&
      { printf 'SEEN: %s\n' "$2"; return 0; }
    [ "$((i + 1))" -ge "${BROWSE_SEEN_WAIT:-20}" ] || sleep 0.5
  done
  printf 'SEEN: none\n'
  limit_hit worker-run.browse-wait "${BROWSE_SEEN_WAIT:-20}" count skip "the $2 extension never showed token $1${3:+ for $3}: the device is unproven" \
    'bin/worker-run:BROWSE_SEEN_WAIT:-20'
  return 1
}

# A BROWSER: yes run drives Egor's Dia only through the `dia` MCP server (bin/dia-mcp): real input in his open
# tabs, no extension, no Computer Use. Each vendor gets the server for that run alone, never from its config.
browse_dia_mcp() { printf '%s\n' "${WORKER_RUN_DIA_MCP:-$SCRIPT_DIRECTORY/dia-mcp}"; }
browse_dia_run() { jq -e '.browser == true and .browser_target == "dia"' "$1" >/dev/null 2>&1; } # meta-file
browse_dia_claude_config() { jq -cn --arg c "$(browse_dia_mcp)" '{mcpServers: {dia: {type: "stdio", command: $c, args: []}}}'; }
# The first tool call waits on Egor's "Allow debugging connection?", so the tool timeout outlasts his answer.
browse_dia_codex_args() {
  printf '%s\n' -c "mcp_servers.dia.command=\"$(browse_dia_mcp)\"" -c mcp_servers.dia.startup_timeout_sec=120 \
    -c mcp_servers.dia.tool_timeout_sec=300
}

browse_dia_preamble() {
  cat <<'EOF'
# Browser preamble (Egor's Dia over DevTools)
- Your browser is Egor's running Dia, both profiles, through the tools of the `dia` MCP server (`list_pages`, `select_page`, `take_snapshot`, `click`, `fill`, `type_text`, `take_screenshot`, network, console, performance): real input in his open tabs. Claude in Chrome, the Codex extension, Computer Use and `dia-js` are not yours here.
- The first tool call makes Dia ask "Allow debugging connection?", which the server answers itself; a connection that still fails ends `OUTCOME: BROWSER_OWNER_LOGIN site=dia-debugging`.
- `list_pages`, then `select_page` the tab the task names (title or URL); none or several match: end `OUTCOME: BROWSER_NO_TAB` naming the candidates. Act only in that tab and in tabs you open with `new_page`; never close, reload or navigate away a tab of Egor's unless the task says so.
- After each submit read the effect back (`take_snapshot` or `evaluate_script`) and check every value you set; an unconfirmed submit ends `OUTCOME: BROWSER_CLICK_UNVERIFIED`.
- Never log in, or launch, quit or script a browser yourself. A site that needs Egor himself to sign in or authorize ends `OUTCOME: BROWSER_OWNER_LOGIN site=<site>`; anything else the task needs that this forbids ends `OUTCOME: HARNESS_NEEDS_REPAIR reason=<what>`.
- Close the tabs you opened once the task is done (leave the work tab open when you stop for Egor) and end `OUTCOME: BROWSER_OK`.
EOF
}

browse_preamble() { # vendor target account device-hint profiles token
  local run="$SCRIPT_DIRECTORY/worker-run browse" first='every' gone
  [ "$2" != dia ] || { browse_dia_preamble; return 0; }
  [ -z "$4" ] || first="\`$4\` first when listed, then every other"
  gone="run \`$run --window $3\`, repeat the proof for up to 60 s, and only then end \`OUTCOME: BROWSER_INTERRUPTED\`"
  if [ "$1" = codex ]; then
    cat <<EOF
# Browser preamble (Codex / Google Chrome)
- First js call: \`await cua.getState()\`, then \`await agent.browsers.list()\`; entry ids rotate, never reuse one.
- Target: the \`extension\` entry with \`family\` \`chrome\` whose \`profileName\` is one of $5, first listed wins. Never drive any other entry or browser; never log in.
EOF
  else
    cat <<EOF
# Browser preamble (Claude in Chrome / Google Chrome / $3)
Prove the device before the task:
1. \`list_connected_browsers\`. Candidates: $first \`isLocal: true\` entry; no other id, ever.
2. Per candidate: \`select_browser\`, \`navigate\` (no tabId) to \`https://example.com/?wr=$6-<candidate number>\`, then run \`$run --seen $6-<candidate number> --account $3\`. Only \`SEEN: $2\` proves it. An error, a timeout or \`SEEN: none\`: close any tab it opened, take the next candidate; never retry one, never call \`tabs_context_mcp\` on one.
3. Proven: print \`BROWSER-PROVEN: <deviceId> $3\` and work in that tab; your final answer repeats that line. None: end \`OUTCOME: BROWSER_NO_DEVICE account=$3 profile=$5\`.
Then:
- After a reconnect or a tool error \`select_browser\` the proven device again. Browser or tab gone: $gone.
- Never put \`tabs_close_mcp\` in a \`browser_batch\` with any other action: the batch fails with "not in the same group as the current tab" and the tab group is lost.
EOF
  fi
  cat <<EOF
- Fill and submit forms through JavaScript (\`form.elements[...]\`), then read the effect back and check every value you set. A control the page ignores from JavaScript (login, recovery and 2FA buttons often accept only real user events) gets one real click through your own click tool, read back the same way; an unconfirmed submit ends \`OUTCOME: BROWSER_CLICK_UNVERIFIED\`.
- Never \`switch_browser\`, log in, or launch, quit or script a browser yourself. A site that needs Egor himself to sign in or authorize ends \`OUTCOME: BROWSER_OWNER_LOGIN site=<site>\` (leave its tab open; a consent button that stays disabled is his: never force or poll it); anything else the task needs that this forbids ends \`OUTCOME: HARNESS_NEEDS_REPAIR reason=<what>\`.
- Close your tabs once the task is done (leave the work tab open when you stop for Egor) and end \`OUTCOME: BROWSER_OK\`.
EOF
}

browse_prepare() { # vendor target account preamble-file; REASON lines and 2 when no browser can serve
  local vendor=$1 target=$2 account=$3 dir='' names=''
  BROWSE_PROFILE='' BROWSE_DEVICE=''
  if [ "$target" = dia ]; then
    names=$("$(browse_dia_mcp)" --check 2>&1) || { grep '^REASON: ' <<<"$names" || printf 'REASON: %s\n' "$names"; return 2; }
    # Two runs clicking in Egor's tabs at once undo each other's work.
    names=$(chrome_runs '.browser == true and .browser_target == "dia"' | head -n 1)
    [ -z "$names" ] || { printf "REASON: %s already works in Egor's Dia, one run at a time: worker-run wait %s\n" "$names" "$names"; return 2; }
  elif [ "$vendor" = codex ]; then
    while IFS= read -r dir; do
      browse_window "$dir" && names+="${names:+, }$(browse_profile_label "$dir")"
    done < <(browse_registry | jq -r '[.[] | select(.status == "ok") | .chrome_profile // empty] | unique[]')
    [ -n "$names" ] || { printf 'REASON: no enrolled Chrome profile is open: worker-run browse --enroll all\n'; return 2; }
  else
    dir=$(browse_profile "$account")
    [ -n "$dir" ] || {
      printf 'REASON: claudeb/%s has no Chrome profile signed in as %s: worker-run browse --enroll %s (--pin <dir>)\n' \
        "$account" "$(browse_email "$account")" "$account"
      return 2
    }
    browse_window "$dir" || { printf 'REASON: the Chrome window of %s (%s) did not open\n' "$account" "$dir"; return 2; }
    BROWSE_PROFILE=$dir names=$(browse_profile_label "$dir")
    BROWSE_DEVICE=$(browse_registry | jq -r --arg a "$account" '.[$a].device_id // empty')
  fi
  browse_preamble "$vendor" "$target" "$account" "$BROWSE_DEVICE" "$names" "$(date +%s)$RANDOM" >"$4"
}

browse_session_wait() { # pid what -> once the session has ended, or was killed after BROWSE_SESSION_S
  local watchdog
  ( sleep "${BROWSE_SESSION_S:-300}"
    kill -0 "$1" 2>/dev/null || exit 0
    limit_hit worker-run.browse-session "${BROWSE_SESSION_S:-300}" s kill "$2" \
      'bin/worker-run:BROWSE_SESSION_S:-300' "${BROWSE_SESSION_S:-300}"
    kill "$1" 2>/dev/null ) >/dev/null &
  watchdog=$!
  wait "$1" 2>/dev/null
  process_tree_end "$watchdog" 0
  wait "$watchdog" 2>/dev/null
}

browse_session() { # account prompt-file -> the session's answer
  local out pid
  out=$(mktemp "$(browse_dir)/session.XXXXXX") || return 1
  ( cd "$(browse_dir)" && exec env -u WORKER_RUN_ID -u WORKER_RUN_RECORD "${WORKER_RUN_CLAUDEB:-$HOME/.local/bin/claudeb}" \
      profile "$1" -p --model "${BROWSE_PROOF_MODEL:-sonnet}" --effort low --chrome --output-format json \
      --dangerously-skip-permissions ) <"$2" >"$out" 2>"$(browse_dir)/last-session-$1.err" &
  pid=$!
  browse_session_wait "$pid" "the claudeb/$1 browser session and its proof verdict"
  jq -r '.result // empty' "$out" 2>/dev/null || cat "$out"
  mv -f "$out" "$(browse_dir)/last-session-$1.json"
}

# A proof refreshes the device and a run that found none makes the account a login; an enrollment that
# ends any other way is a failed proof, BROWSER_OK without a proven device included. Sets BROWSE_PROVEN
# and BROWSE_OUTCOME.
browse_absorb() { # account profile answer [enrolling|log-only]
  BROWSE_PROVEN=$(sed -nE "s/^\`?BROWSER-PROVEN:[[:blank:]]+($BROWSE_UUID)[[:blank:]]+$1\`?[[:space:]]*\$/\1/p" <<<"$3" | tail -n 1)
  BROWSE_OUTCOME=$(sed -nE 's/^`?OUTCOME:[[:blank:]]+([A-Z_]+).*/\1/p' <<<"$3" | tail -n 1)
  BROWSE_OUTCOME=${BROWSE_OUTCOME:-missing}
  [ "${4:-}" = log-only ] || [ -n "$BROWSE_PROVEN" ] || [ "$BROWSE_OUTCOME" != BROWSER_OK ] || BROWSE_OUTCOME=BROWSER_UNPROVEN
  if [ "${4:-}" = log-only ]; then
    :
  elif [ -n "$BROWSE_PROVEN" ]; then
    browse_registry_set "$1" '. + {email:$e, chrome_profile:$p, pin:(.pin // false), device_id:$d, proven_at:(now | todate),
      status:"ok", last_error:""}' --arg d "$BROWSE_PROVEN" --arg e "$(browse_email "$1")" --arg p "$2"
  elif [ "$BROWSE_OUTCOME" = BROWSER_NO_DEVICE ] && [ "$(browse_chrome_age)" -lt "$BROWSE_RECONNECT_S" ]; then
    browse_registry_set "$1" '. + {status:"proof-failed", last_error:"its extension has not reconnected yet: Chrome or its window up \($s) s"}' \
      --argjson s "$(browse_chrome_age)"
  elif [ "$BROWSE_OUTCOME" = BROWSER_NO_DEVICE ]; then
    browse_registry_set "$1" '. + {status:"needs-login", last_error:"no listed browser proved to be its Chrome profile"}'
  elif [ -n "${4:-}" ]; then
    browse_registry_set "$1" '. + {status:"proof-failed", last_error:$e}' --arg e "$BROWSE_OUTCOME"
  fi
}

browse_log() { # run vendor account profile target device outcome workaround [error]
  mkdir -p "$(browse_dir)" && jq -cn --arg run "$1" --arg vendor "$2" --arg account "$3" --arg profile "$4" --arg target "$5" \
    --arg device "$6" --arg outcome "$7" --argjson workaround "$8" --arg error "${9:-}" \
    '{ts:(now | todate), run:$run, vendor:$vendor, account:$account, profile:$profile, target:$target, device:$device,
      outcome:$outcome, workaround:$workaround} + (if $error == "" then {} else {error:$error} end)' >>"$(browse_dir)/log.jsonl"
}

# A way around the preamble since the run started (a resumed session holds earlier runs): a device no
# list printed, a Chrome launch of its own, --chrome without --browser, or a script aimed at the browser
# the run does not target. Only a command's own executable counts; `pgrep -f '...Google Chrome'` drives nothing.
browse_workaround() { # transcript target since
  local at='(^|[;&|(`])[[:space:]]*' other lines
  other="${at}osascript.*(Dia|company\.thebrowser\.dia)|${at}[^[:space:]]*dia-js"
  [ "$2" != dia ] || other="${at}osascript.*(Google Chrome|com\.google\.Chrome)"
  [ -r "$1" ] || return 1
  lines=$(jq -rn --arg uuid "$BROWSE_UUID" --argjson since "${3:-0}" '[inputs
      | select(((.timestamp? // "") | tostring | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) >= $since)] as $all
    | [$all[] | .message.content[]? | objects] as $parts
    | [$parts[] | select(.type == "tool_use" and (.name | endswith("list_connected_browsers"))) | .id] as $lists
    | [$parts[] | select(.type == "tool_result" and (.tool_use_id as $id | $lists | index($id)))
       | .content | tostring | scan($uuid)] as $listed
    | ($parts[] | select(.type == "tool_use" and (.name | endswith("select_browser"))) | .input.deviceId
       | select(. as $d | $listed | index($d) | not) | "UNLISTED-DEVICE " + .),
      ($parts[] | select(.type == "tool_use" and .name == "Bash") | .input.command // empty),
      ($all[] | .payload? | objects | select(.type == "function_call") | .arguments | fromjson? | .cmd // .command // empty
       | if type == "array" then .[-1] else . end | strings)' "$1" 2>/dev/null) || return 1
  grep -Eq -- "^UNLISTED-DEVICE |${at}open[[:space:]][^|;&]*(Google Chrome|com\.google\.Chrome)|${at}['\"]?[^[:space:]'\"]*Google(\\\\ | )Chrome\.app/Contents/MacOS|$other" <<<"$lines" ||
    grep -E -- '(^|[[:space:]])--chrome([[:space:]]|$)' <<<"$lines" | grep -vq -- '--browser'
}

browse_record() { # directory exit-code
  local meta="$1/meta.json" vendor account target profile transcript workaround=false
  jq -e '.browser == true' "$meta" >/dev/null 2>&1 || return 0
  vendor=$(jq -r '.vendor' "$meta") account=$(jq -r '.account' "$meta") target=$(jq -r '.browser_target // "chrome"' "$meta")
  profile=$(jq -r '.browser_profile // empty' "$meta")
  browse_absorb "$account" "$profile" "$(cat "$1/result" 2>/dev/null)" "$([ "$vendor:$target" = claudeb:chrome ] || echo log-only)"
  [ "$BROWSE_OUTCOME" != missing ] || [ "$2" = 0 ] || BROWSE_OUTCOME=BROWSER_INTERRUPTED
  transcript=$(session_transcript "$vendor" "$account" "$(session_id "$1")" "$(jq -r '.workdir // empty' "$meta")" 2>/dev/null) ||
    transcript=''
  ! browse_workaround "$transcript" "$target" "$(jq -r '.started_at // 0 | floor' "$meta")" || workaround=true
  browse_log "${1##*/}" "$vendor" "$account" "$profile" "$target" "$BROWSE_PROVEN" "$BROWSE_OUTCOME" "$workaround"
}

browse_proof_session() { # account profile task -> the answer; the account's registry entry updated
  local prompt answer
  prompt=$(mktemp "$(browse_dir)/prompt.XXXXXX") || return 1
  { browse_preamble claudeb chrome "$1" "$(browse_registry | jq -r --arg a "$1" '.[$a].device_id // empty')" \
      "$(browse_profile_label "$2")" "$(date +%s)$RANDOM"
    printf '\nTask: %s\n' "$3"; } >"$prompt"
  answer=$(browse_session "$1" "$prompt")
  rm -f "$prompt"
  grep -Eq '^`?OUTCOME:' <<<"$answer" || answer+=$'\nOUTCOME: BROWSER_INTERRUPTED'
  printf '%s\n' "$answer"
}

browse_enroll() { # account [pin-directory]
  local account=$1 email dir status
  email=$(browse_email "$account")
  [ -n "$email" ] || { printf 'ENROLL: %s unknown — its profile holds no claude.ai login\n' "$account"; return 1; }
  [ -z "${2:-}" ] || browse_registry_set "$account" '. + {chrome_profile:$d, pin:true}' --arg d "$2" || return 1
  dir=$(browse_profile "$account")
  browse_registry_set "$account" '. + {email:$e, chrome_profile:$d, pin:(.pin // false)}' --arg e "$email" --arg d "$dir" || return 1
  if [ -z "$dir" ]; then
    browse_registry_set "$account" '. + {status:"no-profile", last_error:"no Chrome profile is signed in as \($e)"}' --arg e "$email"
    printf 'ENROLL: %s no-profile\nREASON: no Chrome profile is signed in as %s: sign one into Chrome, or worker-run browse --enroll %s --pin <dir>\n' \
      "$account" "$email" "$account"
    return 1
  fi
  if browse_window "$dir"; then
    browse_absorb "$account" "$dir" "$(browse_proof_session "$account" "$dir" 'the proof alone: close your tab and end `OUTCOME: BROWSER_OK`.')" enrolling
  else
    BROWSE_OUTCOME=BROWSER_INTERRUPTED BROWSE_PROVEN=''
    browse_registry_set "$account" '. + {status:"proof-failed", last_error:"its Chrome window did not open"}'
  fi
  browse_log "enroll-$account-$(date +%s)" claudeb "$account" "$dir" chrome "$BROWSE_PROVEN" "$BROWSE_OUTCOME" false
  status=$(browse_registry | jq -r --arg a "$account" '.[$a].status')
  printf 'ENROLL: %s %s %s %s\n' "$account" "$status" "$dir" "${BROWSE_PROVEN:-no-device}"
  [ "$status" != needs-login ] || printf 'REASON: the Claude extension in Chrome %s is not signed in as %s (%s): dispatch share/briefs/claude-ext-login.md with ACCOUNT %s, EMAIL %s, PROFILE %s\n' \
    "$dir" "$account" "$email" "$account" "$email" "$dir"
  [ "$status" = ok ]
}

browse_unstarted() { # account -> the first error line of a proof session that never reached the model
  local json err
  json="$(browse_dir)/last-session-$1.json" err="$(browse_dir)/last-session-$1.err"
  if [ -s "$json" ]; then
    jq -r 'select(.is_error == true and (.duration_api_ms // 0) == 0) | .result // "an error result"' "$json" 2>/dev/null
  else
    cat "$err" 2>/dev/null
  fi | grep -m 1 . | cut -c 1-300 | grep .
}

browse_walled() { # account scratch-directory -> 0 when its last proof session ended on a usage wall
  mkdir -p "$2" || return 1
  jq -r 'select(.is_error == true) | (.result // empty), (.api_error_status // empty)' "$(browse_dir)/last-session-$1.json" >"$2/out" 2>/dev/null
  cat "$(browse_dir)/last-session-$1.err" >"$2/err" 2>/dev/null
  has_limit_signature "$2" claudeb
}

browse_codex_session() { # account profile-label task scratch-directory -> scratch/out, or BROWSE_CODEX_ERROR
  local home model slug pid
  BROWSE_CODEX_ERROR=''
  mkdir -p "$4" && : >"$4/out" && : >"$4/err" || return 1
  home=$(browse_real_home)
  cua_repl_sync "$(browse_codex_config "$home")"
  [ "$CUA_REPL_STATUS" != broken ] || { BROWSE_CODEX_ERROR="cua_repl registration failed: $CUA_REPL_ERROR"; return 1; }
  [ "$(sky_ensure "$home")" != absent ] ||
    { BROWSE_CODEX_ERROR='SkyComputerUseService is not running and Codex Computer Use.app did not start it'; return 1; }
  model=$(codex_config_model)
  slug=$(worker_model_codex_slug "$model" "$1") && [ -n "$slug" ] || slug=$(worker_model_codex_slug "$model") || slug=''
  [ -n "$slug" ] || { BROWSE_CODEX_ERROR="codex/$1 lists no model of $model"; return 1; }
  { browse_preamble codex chrome "$1" '' "$2" "$(date +%s)$RANDOM"; printf '\nTask: %s\n' "$3"; } >"$4/prompt"
  ( cd "$(browse_dir)" || exit 1
    if [ "$1" = main ]; then unset CODEX_HOME; else CODEX_HOME=$(codex_home "$1"); export CODEX_HOME; fi
    # npm installs codex (and the node it runs on) under nvm, which a LaunchAgent's PATH lacks.
    command -v "${WORKER_RUN_CODEX:-codex}" >/dev/null 2>&1 ||
      while IFS= read -r home; do PATH="$PATH:$home"; done < <(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -rV)
    exec env -u WORKER_RUN_ID -u WORKER_RUN_RECORD "${WORKER_RUN_CODEX:-codex}" exec -C "$(browse_dir)" --skip-git-repo-check \
      -m "$slug" -c model_reasoning_effort=low --color never -o "$4/out" - ) <"$4/prompt" >/dev/null 2>"$4/err" &
  pid=$!
  browse_session_wait "$pid" "the codex/$1 browser canary session and its verdict"
  cp -f "$4/out" "$(browse_dir)/last-session-codex-$1.out" 2>/dev/null
  cp -f "$4/err" "$(browse_dir)/last-session-codex-$1.err" 2>/dev/null
  return 0
}

# One codex leg per canary: the first account the browser list ranks `ok` drives the first enrolled `ok` profile
# whose window opens through the Codex extension, judged by the same receipt. Run after the claudeb legs, so no
# profile carries both extensions' sessions at once.
browse_canary_codex() { # work-directory port listing [unreadable-reason]
  local work=$1 port=$2 account outcome reason dir='' label='' tag error=''
  account=$(awk -F'\t' '$1 == "codex" && $4 == "ok" { print $2; exit }' <<<"$3")
  if [ -z "$account" ]; then
    outcome=CANARY_WALLED reason=walled
    account=$(awk -F'\t' '$1 == "codex" && $4 == "walled" { print $2; exit }' <<<"$3")
    [ -n "$account" ] || { outcome=CANARY_OUT_OF_POOL reason='out of the worker pool'
      account=$(awk -F'\t' '$1 == "codex" && ($4 == "off" || $4 == "paused") { print $2; exit }' <<<"$3"); }
    if [ -n "$account" ]; then
      browse_log "canary-codex-$account-$(date +%s)" codex "$account" '' chrome '' "$outcome" false
      printf 'CANARY: codex/%s skipped — %s\n' "$account" "$reason"
      return 0
    fi
    account=$(awk -F'\t' '$1 == "codex" { print $2; exit }' <<<"$3")
    [ -n "$account" ] || { printf 'CANARY: codex skipped — no codex account\n'; return 0; }
    error="no codex account can serve: $(awk -F'\t' '$1 == "codex" { printf "%s%s %s", sep, $2, $4; sep = ", " }' <<<"$3")"
  elif [ -n "${4:-}" ]; then
    browse_log "canary-codex-$account-$(date +%s)" codex "$account" '' chrome '' CANARY_OWNER_GRANT false "$4"
    printf "CANARY: codex/%s skipped — waits for Egor's macOS grant: %s\n" "$account" "$4"
    return 0
  else
    while IFS= read -r dir; do
      browse_window "$dir" && { label=$(browse_profile_label "$dir"); break; }
    done < <(browse_registry | jq -r '[.[] | select(.status == "ok") | .chrome_profile // empty] | unique[]')
    [ -n "$label" ] || { dir='' error='no enrolled Chrome profile is open'; }
  fi
  tag="canary-codex-$account-$(date +%s)"
  BROWSE_OUTCOME=CANARY_NOT_STARTED BROWSE_PROVEN=''
  if [ -n "$error" ]; then
    :
  elif ! browse_codex_session "$account" "$label" "open http://127.0.0.1:$port/form?case=$tag in a new tab of that browser, set the field \`v\` to \`$tag\` and submit the form through JavaScript, then read the page back: it must say \`received $tag\`." "$work/codex"; then
    error=${BROWSE_CODEX_ERROR:-its scratch directory could not be written}
  elif grep -qF "\"v\": \"$tag\"" "$work/receipts" 2>/dev/null; then
    browse_absorb "$account" "$dir" "$(cat "$work/codex/out")" log-only
  elif has_limit_signature "$work/codex" codex; then
    BROWSE_OUTCOME=CANARY_WALLED
  elif [ ! -s "$work/codex/out" ] && [ -s "$work/codex/err" ]; then
    error=$({ grep -m 1 '^ERROR: ' "$work/codex/err" || grep . "$work/codex/err" | tail -n 1; } | cut -c 1-300)
  else
    browse_absorb "$account" "$dir" "$(cat "$work/codex/out")" log-only
    BROWSE_OUTCOME=CANARY_NO_RECEIPT
  fi
  browse_log "$tag" codex "$account" "$dir" chrome "$BROWSE_PROVEN" "$BROWSE_OUTCOME" false "$error"
  printf 'CANARY: codex/%s %s%s\n' "$account" "$BROWSE_OUTCOME" "${error:+ — $error}"
  [ "$BROWSE_OUTCOME" = BROWSER_OK ] || [ "$BROWSE_OUTCOME" = CANARY_WALLED ]
}

# Each enrolled account in the claudeb worker pool fills and submits a form on a listener only this canary
# runs; the server's own receipt is the verdict, never the worker's word.
browse_canary() {
  local work port account dir rc=0 tag child answer walled listing unreadable
  local -a children=()
  [ -z "$(chrome_runs)" ] || { printf 'CANARY: skipped — a browser run is live\n'; return 0; }
  mkdir -p "$(browse_dir)" && touch "$(browse_dir)/canary.stamp"
  work=$(mktemp -d "$(browse_dir)/canary.XXXXXX") || return 1
  python3 - "$work" <<'PY' &
import http.server, json, os, sys, urllib.parse
work = sys.argv[1]
class Form(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/submit":
            with open(os.path.join(work, "receipts"), "a") as handle:
                handle.write(json.dumps(query) + "\n")
            self.reply("<p id=done>received %s</p>" % query.get("v", ""))
        else:
            self.reply('<form action=/submit><input type=hidden name=case value="%s"><input name=v>'
                       '<button>Send</button></form>' % query.get("case", ""))
server = http.server.HTTPServer(("127.0.0.1", 0), Form)
with open(os.path.join(work, "port.tmp"), "w") as handle:
    handle.write(str(server.server_port))
os.rename(os.path.join(work, "port.tmp"), os.path.join(work, "port"))
server.serve_forever()
PY
  trap "kill $! 2>/dev/null; rm -rf $(printf %q "$work")" EXIT
  trap 'exit 1' INT TERM HUP
  for ((tag = 0; tag < 50; tag++)); do [ -s "$work/port" ] && break; sleep 0.1; done
  port=$(cat "$work/port" 2>/dev/null) || { printf 'CANARY: failed — its form server did not start\n'; return 1; }
  listing=$("${WORKER_RUN_WORKER_PICK:-$SCRIPT_DIRECTORY/worker-pick}" --list --role browser 2>/dev/null)
  walled=$(awk -F'\t' '$1 == "claudeb" && $4 == "walled" { print $2 }' <<<"$listing")
  unreadable=$(browse_chrome_unreadable)
  while IFS=$'\t' read -r account dir; do
    tag="canary-$account-$(date +%s)"
    if ! worker_pool_refuse_headless claudeb "$account" "$(worker_model_pin_csv < <(worker_model_pins claudeb))" 2>/dev/null; then
      browse_log "$tag" claudeb "$account" "$dir" chrome '' CANARY_OUT_OF_POOL false
      printf 'CANARY: %s skipped — out of the worker pool\n' "$account"
      continue
    fi
    if grep -qxF -- "$account" <<<"$walled"; then
      browse_log "$tag" claudeb "$account" "$dir" chrome '' CANARY_WALLED false
      printf 'CANARY: %s skipped — walled\n' "$account"
      continue
    fi
    (
      BROWSE_OUTCOME=BROWSER_INTERRUPTED BROWSE_PROVEN='' error=''
      if browse_window "$dir"; then
        answer=$(browse_proof_session "$account" "$dir" "open http://127.0.0.1:$port/form?case=$tag in your proven tab, set the field \`v\` to \`$tag\` and submit the form through JavaScript, then read the page back: it must say \`received $tag\`.")
        if grep -qF "\"v\": \"$tag\"" "$work/receipts" 2>/dev/null; then
          browse_absorb "$account" "$dir" "$answer"
        elif browse_walled "$account" "$work/wall-$account"; then
          BROWSE_OUTCOME=CANARY_WALLED
        elif error=$(browse_unstarted "$account"); then
          BROWSE_OUTCOME=CANARY_NOT_STARTED
        else
          browse_absorb "$account" "$dir" "$answer" log-only
          BROWSE_OUTCOME=CANARY_NO_RECEIPT
        fi
      fi
      browse_log "$tag" claudeb "$account" "$dir" chrome "$BROWSE_PROVEN" "$BROWSE_OUTCOME" false "$error"
      printf 'CANARY: %s %s%s\n' "$account" "$BROWSE_OUTCOME" "${error:+ — $error}"
      [ "$BROWSE_OUTCOME" = BROWSER_OK ] || [ "$BROWSE_OUTCOME" = CANARY_WALLED ]
    ) &
    children+=("$!")
  done < <(browse_registry | jq -r 'to_entries[] | select((.value.chrome_profile // "") != "") | [.key, .value.chrome_profile] | @tsv')
  for child in "${children[@]}"; do wait "$child" || rc=1; done
  browse_canary_codex "$work" "$port" "$listing" "$unreadable" || rc=1
  browse_quit_idle
  return "$rc"
}

browse_run() {
  local mode=status arg='' pin='' target=chrome account='' rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --enroll | --window | --seen) [ "$#" -ge 2 ] || usage; mode=${1#--} arg=$2; shift 2 ;;
      --pin) [ "$#" -ge 2 ] || usage; pin=$2; shift 2 ;;
      --account) [ "$#" -ge 2 ] || usage; account=$2; shift 2 ;;
      --target) [ "$#" -ge 2 ] || usage; target=$2; shift 2 ;;
      --canary | --json | --hide | --show | --toggle) mode=${1#--}; shift ;;
      *) usage ;;
    esac
  done
  if [ "$mode" = toggle ]; then
    [ "$("${BROWSE_OSASCRIPT:-osascript}" -e 'tell application "System Events" to get visible of process "Google Chrome"' 2>/dev/null)" = false ] &&
      mode=show || mode=hide
  fi
  case "$mode" in
    seen) browse_seen "$arg" "$target" "$account" ;;
    window)
      account=$(browse_profile "$arg")
      [ -n "$account" ] && browse_window "$account" && printf 'WINDOW: %s %s\n' "$arg" "$account" ||
        { printf 'WINDOW: %s failed\n' "$arg"; return 1; } ;;
    enroll)
      [ "$arg" != all ] || [ -z "$pin" ] || fail '--pin names one account'
      if [ "$arg" = all ]; then set -- $(browse_pool); else set -- "$arg"; fi
      mkdir -p "$(browse_dir)" || return 1
      for account in "$@"; do browse_enroll "$account" "$pin" >"$(browse_dir)/enroll-$account.$$" & done
      for account in "$@"; do wait -n || rc=1; done
      for account in "$@"; do cat "$(browse_dir)/enroll-$account.$$"; rm -f "$(browse_dir)/enroll-$account.$$"; done
      browse_quit_idle
      return "$rc" ;;
    canary) browse_canary ;;
    json) browse_registry | jq . ;;
    hide)
      [ -z "$(chrome_runs '.computer == true')" ] || fail 'a Computer Use run is live and needs Chrome on screen'
      rm -f "$(browse_dir)/shown"
      ! browse_chrome_app_running || browse_chrome_visible false
      "${BROWSE_PS:-ps}" -Ao command= | awk '/\/MacOS\/Google Chrome( |$)/ { print; exit }' | grep -q -- "${CHROME_FLAGS[2]}" ||
        printf 'WARNING: this Chrome runs without the anti-throttling flags: hidden page timers slow to ~1/min\n'
      printf 'CHROME: hidden\n' ;;
    show)
      mkdir -p "$(browse_dir)" && : >"$(browse_dir)/shown" || return 1
      ! browse_chrome_app_running || browse_chrome_visible true
      printf 'CHROME: shown\n' ;;
    *)
      for account in $(browse_pool); do
        browse_registry | jq -r --arg a "$account" --arg e "$(browse_email "$account")" '.[$a] // {status:"not-enrolled"}
          | "ACCOUNT: \($a) \(.status) \(.chrome_profile // "-") \(.device_id // "-") \(.proven_at // "-") \($e)"'
      done
      local dia last
      dia=$("$(browse_dia_mcp)" --check 2>&1) && dia='debugging on' || dia=${dia#REASON: }
      last=$(jq -rs 'map(select(.target == "dia")) | last // empty | "\(.outcome) \(.ts[0:10])"' \
        "$(browse_dir)/log.jsonl" 2>/dev/null)
      printf "DIA: %s — BROWSER: yes runs the dia MCP (real input in Egor's open tabs, Dia's connection prompt answered by the server; last %s); dia-js is the lite path (read, quick fill, synthetic clicks)\n" \
        "$dia" "${last:-none}" ;;
  esac
}

# Sets CUA_REPL_STATUS (registered|repaired|broken) and, when broken, CUA_REPL_ERROR.
cua_repl_sync() { # codex-config
  local sync_cmd="${BROWSE_CUA_SYNC:-$SCRIPT_DIRECTORY/codex-cua-repl-sync}" sync_rc=0 sync_stderr
  CUA_REPL_STATUS=broken CUA_REPL_ERROR=''
  sync_stderr=$(mktemp "${TMPDIR:-/tmp}/worker-run-cua.XXXXXX") || fail 'could not capture cua_repl diagnostics'
  BROWSE_CODEX_CONFIG="$1" "$sync_cmd" --check >/dev/null 2>"$sync_stderr" || sync_rc=$?
  if [ "$sync_rc" -eq 0 ]; then
    CUA_REPL_STATUS=registered
  elif [ "$sync_rc" -eq 1 ] && BROWSE_CODEX_CONFIG="$1" "$sync_cmd" >/dev/null 2>"$sync_stderr"; then
    CUA_REPL_STATUS=repaired
  fi
  if [ "$CUA_REPL_STATUS" = broken ]; then
    IFS= read -r CUA_REPL_ERROR <"$sync_stderr" || :
    CUA_REPL_ERROR=${CUA_REPL_ERROR:-sync exited without diagnostics}
  fi
  rm -f "$sync_stderr"
}

sky_running() {
  local pgrep_cmd="${BROWSE_PGREP:-pgrep}"
  [ "${BROWSE_SKIP_PROCESSES:-0}" = 1 ] ||
    $pgrep_cmd -x SkyComputerUseService >/dev/null 2>&1 || $pgrep_cmd -f SkyComputerUseService >/dev/null 2>&1
}

sky_ensure() { # real-home -> running|started|absent
  local sky_app="${BROWSE_SKY_APP:-}" deadline
  if sky_running; then printf running; return 0; fi
  if [ -z "$sky_app" ]; then
    sky_app="$HOME/.codex/computer-use/Codex Computer Use.app"
    [ -d "$sky_app" ] || sky_app="$1/.codex/computer-use/Codex Computer Use.app"
  fi
  if [ -d "$sky_app" ]; then
    ${BROWSE_OPEN:-open} "$sky_app" >/dev/null 2>&1 || true
    deadline=$(( $(date +%s) + 15 ))
    while [ "$(date +%s)" -le "$deadline" ]; do
      if sky_running; then printf started; return 0; fi
      sleep 0.25
    done
  fi
  printf absent
}
