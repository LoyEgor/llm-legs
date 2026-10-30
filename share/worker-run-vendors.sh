# worker-run, claudeb, codex and gemini launches: models, sessions, resumes and served models; sourced by
# bin/worker-run in place, so an edit here runs its own suites rather than every suite of worker-run (Egor
# 2026-10-23, 2026-10-28).

# A resume past the cache TTL writes the session's whole context again at full price, and one into
# a context near compaction compacts twice as often as a fresh worker: 7 days to 2026-10-13, cold
# claudeb resumes cost 2.2 % of Claude spend, re-writing a median 199k where a fresh worker's first
# request is 31k. Both are refused; the orchestrator writes a fresh brief from what the session left.
RESUME_IDLE_CLAUDEB=3300
RESUME_IDLE_CODEX=1500
RESUME_CONTEXT_CAP=150000

# This run's claudeb session, resolved off the profile's transcript tree while the run is still
# alive. Claude names the file after the session and fills it from the first turn, so the id exists
# long before `out` does; matched on the token of the attempt now running, since a co-tenant run on
# the same account writes into the same tree. Called once per watchdog tick until it answers.
claudeb_discover_session() { # directory
  local directory="$1" account resume root candidate launched first_line text token started fallback='' _wd_now
  [ ! -s "$directory/session-file" ] || return 0
  # A transcript that has not appeared within ten minutes never will — Claude names the file on the
  # first turn — and searching on would walk a profile tree of thousands of files every tick for the
  # rest of a six-hour run.
  # The watchdog reads meta once per attempt; those fields do not move until the next one.
  if [ -n "${WD_META_READY:-}" ]; then
    started=$WD_STARTED
    account=$WD_ACCOUNT
  else
    started=$(jq -r '([.started_at, .slot_at] | map(numbers) | max // 0)' "$directory/meta.json" 2>/dev/null)
    account=$(jq -r '.account // empty' "$directory/meta.json" 2>/dev/null)
  fi
  [[ "$started" =~ ^[0-9]+$ ]] || started=0
  printf -v _wd_now '%(%s)T' -1
  [ "$started" -eq 0 ] || [ $((_wd_now - started)) -le 600 ] || return 1
  [ -n "$account" ] || return 1
  # PHYSICALLY, because every real profile reaches the shared transcript tree through a SYMLINK
  # (`~/.claude-profiles/<account>/projects` -> `~/.claude/projects`) and `find` handed a symlinked
  # directory as its own argument walks nothing at all: discovery answered for no live claudeb run
  # on this machine until 2026-09-04, and `test -d` cannot see the difference.
  root=$(cd "${CLAUDEB_PROFILES_ROOT:-$HOME/.claude-profiles}/$account/projects" 2>/dev/null && pwd -P) ||
    return 1
  if [ -n "${WD_META_READY:-}" ]; then
    resume=$WD_RESUME
  else
    resume=$(jq -r '.resume // empty' "$directory/meta.json" 2>/dev/null)
  fi
  if [ -n "$resume" ]; then
    # A resumed session keeps the id it already had and APPENDS to a transcript whose first user
    # record is the original brief, so nothing here is matched: the id is known, only its file is
    # being located.
    case "$resume" in .|..|*/*) return 1 ;; esac
    for candidate in "$root"/*/"$resume.jsonl"; do
      [ -f "$candidate" ] || continue
      record_session_file "$directory" "$resume" "$candidate"
      return 0
    done
    return 1
  fi
  token=''
  [ ! -r "$directory/launch-token" ] || IFS= read -r token <"$directory/launch-token" || true
  launched=$(<"$directory/brief.launch")
  first_line=${launched%%$'\n'*}
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    text=$(first_user_text "$candidate")
    if [ -n "$token" ]; then
      case "$text" in *"RUN-TOKEN: $token"*) record_session_file "$directory" "$(basename "${candidate%.jsonl}")" "$candidate"; return 0 ;; esac
      continue
    fi
    # A run launched before the token existed has nothing but its brief text to be found by.
    case "$text" in
      "$launched") record_session_file "$directory" "$(basename "${candidate%.jsonl}")" "$candidate"; return 0 ;;
    esac
    # Newest-first, so the first prefix match is the freshest: the CLI may reflow or annotate the
    # prompt it stores, and an exact match is then unreachable while the run is still this run. An
    # EMPTY first line makes that prefix `*`, which adopts the newest transcript of any run at all.
    if [ -z "$fallback" ] && [ -n "$first_line" ]; then
      case "$text" in "$first_line"*) fallback=$candidate ;; esac
    fi
  # -H, because every claudeb profile reaches the transcripts through a SYMLINK
  # (`<profile>/projects` -> `~/.claude/projects`): handed one as its starting point, find without
  # it walks nothing at all and answers an empty tree, so discovery never once succeeded for a live
  # claudeb run — which left the watchdog blind and the launcher-to-worker pairing unwritten
  # (live 2026-09-04: 0 candidates over a tree of 6239 transcripts).
  # -newer brief.launch, which this ATTEMPT wrote: a transcript predating the launch cannot be its
  # own, and after a reroute the abandoned attempt's transcript is exactly that.
  done < <(find -H "$root" -type f -name '*.jsonl' -newer "$directory/brief.launch" -print0 2>/dev/null |
    xargs -0 ls -t 2>/dev/null)
  [ -n "$fallback" ] || return 1
  record_session_file "$directory" "$(basename "${fallback%.jsonl}")" "$fallback"
}

config_value() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" != "$1="* ]] || { printf '%s\n' "${line#"$1="}"; return 0; }
  done 2>/dev/null <"$CONFIG_FILE"
  return 0
}

vendor_name() {
  case "$1" in
    claudeb) printf 'CLAUDEB' ;;
    codex) printf 'CODEX' ;;
    gemini) printf 'GEMINI' ;;
    grok) printf 'GROK' ;;
  esac
}

# The worker model is the allow-list's, never ~/.codex/config.toml's: that file is symlinked into
# every codexb profile and rewritten by Egor's interactive Codex picks, which must neither switch
# nor refuse a worker launch.
codex_config_model() {
  worker_model_allowed_models codex | head -n1
}

# Refused BEFORE the account is resolved and long before a CLI is launched, because the run is what
# would be wasted, and the name reaches here by three roads that all end at the same list: the
# brief's `MODEL:` line (a chat may forward it as `--model`), `--model` itself, and the vendor's own
# `*_model=` key in the toggle file — including the default a missing key falls back to.
refuse_unlisted_model() { # vendor offered-model [resume-id] [class]
  local vendor="$1" offered="$2" resume="${3:-}" class="${4:-}" effective
  case "$vendor" in
    claudeb) effective=${offered:-$(config_value claudeb_model)}; effective=${effective:-$(worker_model_default_model "$vendor")} ;;
    codex)
      # `exec resume` re-runs the session's own model and config.toml's never travels with it
      # (start_run sends `-m` only for an explicit one), so a Terra sitting in that file refuses
      # nothing here — the resumed session is not the run it names.
      [ -z "$resume" ] || [ -n "$offered" ] || return 0
      # `default` names the worker model rather than a model.
      effective=$offered
      [ -n "$effective" ] && [ "$effective" != default ] || effective=$(codex_config_model)
      ;;
    gemini) worker_model_gemini_stored_r "$(config_value gemini_model)"; effective=${offered:-$WORKER_MODEL_R} ;;
    grok) effective=${offered:-$(config_value grok_model)}; effective=${effective:-$(worker_model_default_model "$vendor")} ;;
  esac
  worker_model_allows "$vendor" "$effective" "$class" && return 0
  outcome_line MODEL_REFUSED
  fail "$vendor models are $(worker_model_allowed_list "$vendor" "$class"); offered model $effective is not among them. Nothing was launched and no account was spent — drop the MODEL: line, or ask Egor."
}

# Fast asked for but not in the account's catalog for this model: the CLI would drop it silently, so
# the run says so and goes standard; it comes back by itself once OpenAI lists the tier again.
refuse_codex_model() { # model
  outcome_line MODEL_REFUSED
  fail "codex model $1 names no model \`codexb models\` lists. Nothing was launched and no account was spent."
}

codex_tier_args() { # account slug requested(true|false)
  local want=$3 rc=0
  if [ "$want" = true ]; then
    codex_fast_offered "$(codex_home "$1")" "$2" || rc=$?
    if [ "$rc" -eq 1 ]; then
      printf 'worker-run: OpenAI offers no Fast for %s on %s now; running standard\n' "$2" "$1" >&2
      want=false
    fi
  fi
  if [ "$want" = true ]; then printf '%s\n' --enable fast_mode -c 'service_tier="priority"'
  else printf '%s\n' --disable fast_mode -c 'service_tier="default"'; fi
}

codex_home() {
  if [ "$1" = main ]; then
    printf '%s/.codex' "$HOME"
  else
    printf '%s/%s' "${CODEX_PROFILES_DIR:-$HOME/.codex-profiles}" "$1"
  fi
}

codex_unsupported_model() {
  # tail-scoped for the same reason has_limit_signature is: codex streams the
  # echoed brief to stderr, and the phrase can appear there as prose.
  if [ -n "${2:-}" ]; then tail -c "$2" "$1/err" 2>/dev/null; else cat "$1/err" 2>/dev/null; fi |
    tail -n 40 | grep -Fqi 'model is not supported'
}

session_transcript() {
  local vendor="$1" account="$2" session="$3" workdir="${4:-}" transcript='' candidate=''
  [ -n "$session" ] && [ "$session" != - ] || return 1
  # A relative step in an id read out of a log would resolve the path somewhere else entirely.
  case "$session" in .|..|*/*) return 1 ;; esac
  case "$vendor" in
    claudeb)
      for transcript in "${CLAUDEB_PROFILES_ROOT:-$HOME/.claude-profiles}/$account/projects/"*/"$session.jsonl"; do
        [ -f "$transcript" ] && break
        transcript=''
      done
      ;;
    codex) transcript=$(find "$(codex_home "$account")/sessions" -type f -name "*$session*.jsonl" 2>/dev/null | head -n1) ;;
    gemini)
      transcript="$(gemini_account_home "$account")/.gemini/antigravity-cli/brain/$session/.system_generated/logs/transcript_full.jsonl"
      ;;
    grok)
      for candidate in "$(grok_home "$account")/sessions/"*/"$session/updates.jsonl"; do
        [ -f "$candidate" ] || continue
        grok_session_dir_matches "${candidate%/updates.jsonl}" "$workdir" || continue
        transcript="$candidate"
        break
      done
      ;;
  esac
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  printf '%s' "$transcript"
}

# The model the session's last turn asked for, which a resume must ask for again.
codex_session_model() { # account session
  local transcript model
  transcript=$(session_transcript codex "$1" "$2") || return 1
  model=$(jq -rR 'fromjson? | select(type == "object" and .type == "turn_context") | .payload.model? | strings' \
    "$transcript" 2>/dev/null | tail -n 1)
  [ -n "$model" ] || return 1
  printf '%s' "$model"
}

refuse_stale_resume() {
  local vendor="$1" account="$2" resume="$3" transcript threshold ttl now mtime idle tokens token_k idle_text why='' usage
  [ -n "$resume" ] || return 0
  case "$vendor" in
    claudeb) threshold=$RESUME_IDLE_CLAUDEB; ttl=1h ;;
    codex) threshold=$RESUME_IDLE_CODEX; ttl=30m ;;
    *) return 0 ;;
  esac
  transcript=$(session_transcript "$vendor" "$account" "$resume") || return 0
  mtime=$(stat -f %m "$transcript" 2>/dev/null) || return 0
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 0
  now=$(date +%s)
  idle=$((now - mtime))
  tokens=''
  if [ "$vendor" = claudeb ]; then
    usage='select(.message.usage) | (.message.usage | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)))'
    tokens=$(tail -c 262144 "$transcript" 2>/dev/null | sed 1d | jq -r "$usage" 2>/dev/null | tail -n1)
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=$(jq -r "$usage" "$transcript" 2>/dev/null | tail -n1)
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=''
  fi
  [ -n "$tokens" ] || tokens=$(($(stat -f %z "$transcript" 2>/dev/null || echo 0) / 4))
  token_k=$(((tokens + 500) / 1000))
  if [ "$idle" -ge 3600 ]; then
    idle_text="$((idle / 3600))h$(((idle % 3600) / 60))m"
  else
    idle_text="$((idle / 60))m"
  fi
  if [ "$idle" -gt "$threshold" ]; then
    why="idle $idle_text, past its ~$ttl cache: resuming writes its ~${token_k}k context again at full price"
  elif [ "$vendor" = claudeb ] && [ "$tokens" -ge "$RESUME_CONTEXT_CAP" ]; then
    why="its context is ~${token_k}k, near compaction: a resume there compacts twice as often as a fresh worker"
  else
    return 0
  fi
  RESUME_REFUSED_TOKENS=$tokens outcome_line RESUME_REFUSED
  fail "RESUME $resume refused: $why. Start a fresh worker instead: read what the session left (\`worker-run report <its run>\`: the result and any queued messages) and write a brief with what it found, what is left and the same --workdir. Nothing was launched and no account was spent."
}

supervise_claudeb() {
  local directory="$1" meta="$1/meta.json" account model effort resume cli rc chrome value
  local -a command retry access
  account=$(jq -r '.account' "$meta")
  model=$(jq -r '.model' "$meta")
  effort=$(jq -r '.effort' "$meta")
  resume=$(jq -r '.resume' "$meta")
  cli=$(jq -r '.cli' "$meta")
  chrome=$(jq -r '.chrome // false' "$meta")
  access=(--dangerously-skip-permissions)
  [ "$(jq -r '.role // "workers"' "$meta")" != research ] || access=(--permission-mode plan)
  REPLY_ARRAY=()
  read_json_array '.add_dirs[]' "$meta"
  for value in "${REPLY_ARRAY[@]}"; do access+=(--add-dir "$value"); done
  # Into `access` and not into `command`: the effort-drop retry below rebuilds the command from it,
  # and a web-search state left behind there relaunches the run with a capability it was denied.
  # A wake-up scheduled in a -p session ends the turn and nothing ever fires it: the run exits 0
  # "waiting on" suites it never reads, its work uncommitted. Workflow, ListAgents and Agent are a
  # chat's fan-out, never a headless worker's: worker-spawn-hook.sh refuses every Agent type it can
  # name (95 attempts, no spawn, in 7 days), so the tool is withheld and no turn is spent on the refusal.
  while IFS= read -r value; do access+=("$value"); done < <(web_search_claudeb_args "$(web_search_meta_state "$meta")" "$CLAUDEB_DENIED_TOOLS")
  value=$(jq -r '.inbox_settings // empty' "$meta")
  [ -z "$value" ] || access+=(--settings "$value")
  ! browse_dia_run "$meta" || access+=(--mcp-config "$(browse_dia_claude_config)")
  command=("$cli" profile "$account" -p --model "$model" --effort "$effort" --output-format json "${access[@]}")
  [ -z "$resume" ] || command+=(--resume "$resume")
  [ "$chrome" = false ] || command+=(--chrome)
  # Claude Code's own bundled skills (update-config, code-review, claude-api, workflow-authoring,
  # run) were three quarters of a worker's skill listing, and no claudeb worker invoked one in the
  # 805 runs since 2026-10-14; Egor's skills (media, Jira and the rest) stay listed and loadable.
  local -x CLAUDE_CODE_DISABLE_BUNDLED_SKILLS=1
  # So a covering suite run stays in the foreground, where Claude Code's own 10-minute Bash cap (and
  # the 2-minute default for a call naming no timeout) killed it (exit 143) and the worker reran it
  # detached, polling with sleeps; the idle watchdog is what bounds one tool call.
  local -x BASH_MAX_TIMEOUT_MS=$((IDLE > 900 ? (IDLE - 300) * 1000 : 600000))
  local -x BASH_DEFAULT_TIMEOUT_MS=$BASH_MAX_TIMEOUT_MS
  run_with_deadline "${command[@]}" <"$directory/brief.launch" >"$directory/out" 2>"$directory/err"
  rc=$?
  if [ "$rc" -ne 0 ] && grep -Eiq -- '((unknown|unrecognized|invalid|unexpected|unsupported|not supported).{0,80}--effort|--effort.{0,80}(unknown|unrecognized|invalid|unexpected|unsupported|not supported))' "$directory/err"; then
    retry=("$cli" profile "$account" -p --model "$model" --output-format json "${access[@]}")
    [ -z "$resume" ] || retry+=(--resume "$resume")
    [ "$chrome" = false ] || retry+=(--chrome)
    meta_update "$directory" '.effort_flag_dropped = true' || return 4
    : >"$directory/out"
    : >"$directory/err"
    # A second launch is a second session: without a token of its own this attempt adopts the
    # transcript the first one left in the tree, and reports a session that holds none of its work.
    launch_attempt "$directory" || return 4
    run_with_deadline "${retry[@]}" <"$directory/brief.launch" >"$directory/out" 2>"$directory/err"
    rc=$?
  fi
  value=$(served_model_from_envelope "$directory/out" "$model")
  [ -z "$value" ] || meta_update "$directory" '.served_model = $model' --arg model "$value" || :
  return "$rc"
}

codex_attempt() {
  local directory="$1" account="$2" rc saved_home="${CODEX_HOME-}" had_home="${CODEX_HOME+x}"
  shift 2
  if [ "$account" = main ]; then
    unset CODEX_HOME
    run_with_deadline "$@" <"$directory/brief.launch" >/dev/null 2>"$directory/err"
    rc=$?
    [ -z "$had_home" ] || export CODEX_HOME="$saved_home"
  else
    CODEX_HOME="$(codex_home "$account")" run_with_deadline "$@" <"$directory/brief.launch" >/dev/null 2>"$directory/err"
    rc=$?
  fi
  return "$rc"
}

supervise_codex() {
  local directory="$1" meta="$1/meta.json" account model effort resume cli rc value drop=false dropped=false fast refused=
  local -a command retry add_dirs images
  account=$(jq -r '.account' "$meta")
  model=$(jq -r '.model' "$meta")
  effort=$(jq -r '.effort' "$meta")
  resume=$(jq -r '.resume' "$meta")
  cli=$(jq -r '.cli' "$meta")
  REPLY_ARRAY=()
  read_json_array '.add_dirs[]' "$meta"
  add_dirs=("${REPLY_ARRAY[@]}")
  REPLY_ARRAY=()
  read_json_array '.images[]' "$meta"
  images=("${REPLY_ARRAY[@]}")
  # Resolved again here, on the account this attempt runs on: a reroute lands on another account,
  # and each account's catalog is its own.
  value=$(worker_model_codex_slug "$model" "$account") && [ -n "$value" ] &&
    [ "$value" != "$(jq -r '.model_id // empty' "$meta")" ] &&
    { meta_update "$directory" '.model_id = $id' --arg id "$value" || :; }
  if [ -n "$resume" ]; then
    command=("$cli" exec resume "$resume")
    # Without -m codex falls to config.toml's model (see start_run), so the session's own travels.
    value=$(jq -r 'if (.explicit_model // "") != "" then .model_id // .explicit_model else empty end' "$meta")
    [ -n "$value" ] || value=$(codex_session_model "$account" "$resume") || value=$(jq -r '.model_id // .model' "$meta")
    command+=(-m "$value")
    value=$(jq -r '.explicit_effort // empty' "$meta")
    [ -z "$value" ] || command+=(-c "model_reasoning_effort=$value")
  else
    command=("$cli" exec -C "$(jq -r '.workdir' "$meta")" -m "$(jq -r '.model_id // .model' "$meta")" -c "model_reasoning_effort=$effort" --color never)
  fi
  ! browse_dia_run "$meta" || while IFS= read -r value; do command+=("$value"); done < <(browse_dia_codex_args)
  [ "$(jq -r '.role // "workers"' "$meta")" != research ] || command+=(--sandbox read-only)
  for value in "${add_dirs[@]}"; do command+=(--add-dir "$value"); done
  for value in "${images[@]}"; do command+=(-i "$value"); done
  while IFS= read -r value; do command+=("$value"); done < <(web_search_args codex "$(web_search_meta_state "$meta")")
  # The launching chat's fast word travels in meta.json: the supervisor is detached and the chat
  # pin file it was read from belongs to a session this process cannot name.
  fast=false
  if [ "$(jq -r '.fast // false' "$meta")" = true ] || [ "$(codex_fast_tier "$account")" = fast ]; then fast=true; fi
  while IFS= read -r value; do command+=("$value"); done < <(codex_tier_args "$account" "$(jq -r '.model_id // .model' "$meta")" "$fast")
  command+=(-o "$directory/out" -)
  codex_attempt "$directory" "$account" "${command[@]}"
  rc=$?
  if [ "$rc" -ne 0 ] && grep -Fqi 'Not inside a trusted directory' "$directory/err"; then
    # Appended, not spliced in: a resume command starts `exec resume <id>` and a
    # positional insert would separate the subcommand from its id.
    command+=(--skip-git-repo-check)
    meta_update "$directory" '.trusted_dir_retry = true' || return 4
    : >"$directory/out"
    codex_attempt "$directory" "$account" "${command[@]}"
    rc=$?
  fi
  if [ "$rc" -ne 0 ] && codex_unsupported_model "$directory"; then
    retry=()
    for value in "${command[@]}"; do
      if [ "$drop" = true ]; then drop=false; refused=$value; continue; fi
      if [ "$value" = -m ]; then drop=true; dropped=true; continue; fi
      retry+=("$value")
    done
    if [ "$dropped" = true ]; then
      value=$(worker_model_codex_slug "$model" "$account") || value=''
      if [ -z "$value" ] || [ "$value" = "$refused" ]; then
        value=$(codex_config_model)
        worker_model_allows codex "$value" || return "$rc"
        value=$(worker_model_codex_slug "$value" "$account") && [ -n "$value" ] && [ "$value" != "$refused" ] ||
          return "$rc"
      fi
      retry+=(-c "model=\"$value\"")
      meta_update "$directory" '.model_flag_dropped = true' || return 4
      : >"$directory/out"
      codex_attempt "$directory" "$account" "${retry[@]}"
      rc=$?
    fi
  fi
  codex_record_served "$directory" "$account"
  return "$rc"
}

# The rollout names the model the client asked for on each turn, and a `model_reroute` event where
# the server answered with another; the last of them is what served the run.
codex_record_served() { # directory account
  local session transcript served
  session=$(session_id "$1")
  transcript=$(session_transcript codex "$2" "$session") || return 0
  served=$(jq -rR 'fromjson? | select(type == "object")
      | if .type == "turn_context" then .payload.model?
        elif .type == "event_msg" and .payload.type? == "model_reroute" then .payload.to_model?
        else empty end | strings' "$transcript" 2>/dev/null | tail -n 1)
  [ -z "$served" ] || meta_update "$1" '.served_model = $model' --arg model "$served" || :
}

# The requested id is no evidence (agy <= 1.1.9 served Flash for the Pro high slug); the log's last
# backend override label is.
gemini_record_served() { # directory
  local served
  served=$(sed -n 's/.*Propagating selected model override to backend: label="\([^"]*\)".*/\1/p' \
    "$1/log" 2>/dev/null | tail -n 1)
  [ -z "$served" ] || meta_update "$1" '.served_model = $model' --arg model "$served" || :
}

supervise_gemini() {
  local directory="$1" meta="$1/meta.json" account agy_model resume cli prompt value rc
  local -a command add_dirs
  account=$(jq -r '.account' "$meta")
  agy_model=$(jq -r '.agy_model' "$meta")
  resume=$(jq -r '.resume' "$meta")
  cli=$(jq -r '.cli' "$meta")
  prompt=$(<"$directory/brief.launch")
  command=("$cli" profile "$account" --model "$agy_model" --add-dir "$HOME/.claude")
  REPLY_ARRAY=()
  read_json_array '.add_dirs[]' "$meta"
  add_dirs=("${REPLY_ARRAY[@]}")
  for value in "${add_dirs[@]}"; do command+=(--add-dir "$value"); done
  command+=(--print-timeout 360m --dangerously-skip-permissions --log-file "$directory/log")
  while IFS= read -r value; do command+=("$value"); done < <(web_search_args gemini "$(web_search_meta_state "$meta")")
  [ -z "$resume" ] || command+=(--conversation "$resume")
  command+=(--print "$prompt")
  run_with_deadline "${command[@]}" >"$directory/out" 2>"$directory/err"
  rc=$?
  ! grep -q 'print timeout after' "$directory/err" 2>/dev/null ||
    limit_hit worker-run.agy-print-timeout 21600 s kill "run ${directory##*/} (gemini/$account): its unfinished work" \
      'bin/worker-run:command+=(--print-timeout' 21600
  return "$rc"
}

served_model_from_envelope() { # envelope-file requested-model
  "$SCRIPT_DIRECTORY/../ask_claude.sh" --extract-served-model "${2:-}" <"$1"
}

CLAUDEB_AUTH_RE='OAuth session expired'

record_claudeb_auth_dead() { # directory
  local account
  jq -Rne --arg re "$CLAUDEB_AUTH_RE" \
    'any(inputs | fromjson? | objects | select(.is_error == true) | .result | strings; test($re; "i"))' \
    >/dev/null 2>&1 <"$1/out" || return 0
  account=$(jq -r '.account // empty' "$1/meta.json" 2>/dev/null)
  [ -n "$account" ] || return 0
  "$(jq -r '.cli' "$1/meta.json")" auth-needed "$account" "$CLAUDEB_AUTH_RE" </dev/null >/dev/null 2>&1 || true
}

session_id() { # directory [vendor]
  local directory="$1" vendor="${2:-}" session
  [ -n "$vendor" ] || vendor=$(jq -r '.vendor' "$directory/meta.json")
  session=''
  case "$vendor" in
    claudeb)
      [ ! -s "$directory/out" ] || session=$(jq -r '.session_id // empty' "$directory/out" 2>/dev/null)
      # `out` exists only once the CLI exits, so a run the watchdog killed has none: without the
      # id the watchdog resolved while the run was alive, hours of work end with no SESSION: line
      # and nothing to RESUME (live: two runs killed on the old ceiling, 2026-09-02 and 09-04).
      [ -n "$session" ] || { { IFS= read -r session || :; } <"$directory/session"; } 2>/dev/null
      ;;
    codex)
      # Live codex exec prints 'session id: <uuid>' to stderr, not stdout.
      { IFS= read -r session || :; } < <(grep -Ehio -m1 'session[_ -]?id[[:space:]:=]+[A-Za-z0-9._-]+' "$directory/err" "$directory/out" 2>/dev/null)
      session=${session##*[[:space:]:=]}
      ;;
    gemini)
      # Live agy v1.1.9 log shapes: 'Created conversation <id>' on a fresh run,
      # 'conversationID="<id>"' (non-empty) when resuming. The LAST one: a geminib capacity
      # relaunch appends a new conversation to the same log after the killed one.
      session=$(grep -Eo 'Created conversation [A-Za-z0-9._-]+|conversationID="[A-Za-z0-9._-]+"' "$directory/log" 2>/dev/null |
        tail -n1 | sed -E 's/^Created conversation //; s/^conversationID="([^"]*)"$/\1/')
      ;;
    grok) session=$(grok_end_field "$directory" '.sessionId // empty') ;;
  esac
  printf '%s' "${session:--}"
}
