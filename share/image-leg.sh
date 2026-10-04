# Sourced by the image and video wrappers: one JSON line per run in the image-leg log, which
# llm-doctor reads for its Image block. Recording never changes a wrapper's status or output.

image_leg_start() { # tool kind [served-model-variable]
  IMAGE_LEG_TOOL=$1 IMAGE_LEG_KIND=$2 IMAGE_LEG_MODEL_VAR=${3:-} IMAGE_LEG_STARTED=$(date +%s)
  IMAGE_LEG_ERR='' IMAGE_LEG_TEE='' IMAGE_LEG_QUEUED=0 IMAGE_LEG_SIZE='' IMAGE_LEG_ROUTE='' IMAGE_LEG_SKIP=''
  IMAGE_LEG_COMPOSITE_ASK='' IMAGE_LEG_COMPOSITE_OFF='' IMAGE_LEG_COMPOSITE_BASE='' IMAGE_LEG_COMPOSITE_LINES=''
  IMAGE_LEG_FALLBACK_FROM='' IMAGE_LEG_FALLBACK_REASON='' IMAGE_LEG_PHASES='' IMAGE_LEG_REQUESTED='' IMAGE_LEG_DELIVERED=''
  IMAGE_LEG_FIT='' IMAGE_LEG_LOCK_WAIT='' IMAGE_LEG_EDIT=''
  IMAGE_JOB_ID=${IMAGE_JOB_ID:-$1-$(date -u +%Y%m%dT%H%M%SZ)-$$}
  export IMAGE_JOB_ID
  trap image_leg_exit EXIT
  # Untrapped, a SIGTERM still runs the EXIT trap but with the interrupted command's `$?`: two runs
  # killed by a 600 s timeout were logged rc=0 (2026-10-02).
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  IMAGE_LEG_ERR=$(mktemp "${TMPDIR:-/tmp}/image-leg.XXXXXX" 2>/dev/null) || { IMAGE_LEG_ERR=''; return 0; }
  # A process substitution that cannot open /dev/fd complains on the live stderr; probe it silenced.
  if ! (exec 8> >(cat >/dev/null)) 2>/dev/null; then
    rm -f "$IMAGE_LEG_ERR" || true
    IMAGE_LEG_ERR=''
    return 0
  fi
  exec 9>&2
  if ! exec 2> >(tee -a "$IMAGE_LEG_ERR" >&9); then
    exec 9>&- || true
    rm -f "$IMAGE_LEG_ERR" || true
    IMAGE_LEG_ERR=''
    return 0
  fi
  IMAGE_LEG_TEE=${!:-}
}

image_leg_log_path() {
  printf '%s' "${IMAGE_LEG_LOG:-$HOME/.cache/image-legs/legs.jsonl}"
}

# Called right before the vendor runs: the wait before it is queueing, not the model's time. The
# argument is the leg's input size (images: 1 + reference images, video: requested seconds).
image_leg_mark() { # [size]
  local now
  [ -n "${IMAGE_LEG_TOOL:-}" ] || return 0
  now=$(date +%s)
  IMAGE_LEG_QUEUED=$((now - IMAGE_LEG_STARTED)) IMAGE_LEG_STARTED=$now IMAGE_LEG_SIZE=${1:-}
}

# --help is not a leg: callers probe it before a real call, and a refusal it recorded read as a bad command.
image_leg_help() { # usage-function
  IMAGE_LEG_SKIP=1
  ("$1") 2>&1 || true
  exit 0
}

# Every wrapper's usage() calls this first: a refusal names its cause on one `<tool>: <cause>` line
# ahead of the usage text, so the leg log's err tail tells the doctor which argument was wrong.
image_leg_cause() { # [cause...]
  [ "$#" -eq 0 ] || printf '%s: %s\n' "${IMAGE_LEG_TOOL:-${0##*/}}" "$*" >&2
}

# A wrapper that sets its own EXIT trap calls this first in it: `$?` must still be the wrapper's
# status, and it returns 0 because errexit inside the trap would skip the wrapper's own cleanup.
image_leg_exit() {
  local rc=$? log err='' model='' index composite
  [ -z "${IMAGE_LEG_COMPOSITE_BASE:-}" ] || rm -rf "${IMAGE_LEG_COMPOSITE_BASE%/*}" || true
  [ -n "${IMAGE_LEG_TOOL:-}" ] || return 0
  if [ -n "${IMAGE_LEG_ERR:-}" ]; then
    exec 2>&9 9>&- || true
    for index in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -n "$IMAGE_LEG_TEE" ] || { sleep 0.1; break; }
      kill -0 "$IMAGE_LEG_TEE" 2>/dev/null || break
      sleep 0.05
    done
    err=$(tail -c 2000 "$IMAGE_LEG_ERR" 2>/dev/null) || err=''
    rm -f "$IMAGE_LEG_ERR" || true
  fi
  [ -z "${IMAGE_LEG_SKIP:-}" ] || { IMAGE_LEG_TOOL=''; return 0; }
  [ -z "$IMAGE_LEG_MODEL_VAR" ] || model=${!IMAGE_LEG_MODEL_VAR:-}
  composite=null
  [ "$rc" -ne 0 ] || composite=$(image_leg_composite_record 2>/dev/null) || composite=null
  log=$(image_leg_log_path)
  case $log in */*) mkdir -p "${log%/*}" 2>/dev/null || return 0 ;; esac
  jq -cn --arg tool "$IMAGE_LEG_TOOL" --arg kind "$IMAGE_LEG_KIND" --argjson rc "$rc" \
    --argjson started "$IMAGE_LEG_STARTED" --argjson queued "${IMAGE_LEG_QUEUED:-0}" --arg size "${IMAGE_LEG_SIZE:-}" --arg account "${account:-}" --arg served "$model" --arg err "$err" \
    --arg route "${IMAGE_LEG_ROUTE:-}" --arg job "${IMAGE_JOB_ID:-}" --arg phases "${IMAGE_LEG_PHASES:-}" \
    --arg from "${IMAGE_LEG_FALLBACK_FROM:-}" --arg why "${IMAGE_LEG_FALLBACK_REASON:-}" \
    --arg requested "${IMAGE_LEG_REQUESTED:-}" --arg delivered "${IMAGE_LEG_DELIVERED:-}" --arg fit "${IMAGE_LEG_FIT:-}" \
    --argjson composite "$composite" \
    '{ts: (now | floor), tool: $tool, kind: $kind, rc: $rc, seconds: ((now | floor) - $started),
      queued: $queued, size: ($size | tonumber? // null), account: $account, served: $served, err: $err, job: $job}
     + (if $route == "" then {} else {route: $route} end)
     + (if $from == "" then {} else {fallback_from: $from, fallback_reason: $why} end)
     + (if $phases == "" then {} else {phases: ($phases | fromjson? // null)} end)
     + (if $requested == "" then {} else {requested: ($requested | tonumber), delivered: ($delivered | tonumber? // 0)} end)
     + (if $fit == "" then {} else ($fit | split(" ") | {aspect: {asked: .[0], achieved: (.[1] | tonumber), fit: .[2]}}) end)
     + (if $composite == null then {} else {composite: $composite} end)' 2>/dev/null >>"$log" || true
  IMAGE_LEG_TOOL=''
  return 0
}

image_leg_region_ok() { # x,y,w,h
  python3 -c 'import sys; v = [float(n) for n in sys.argv[1].split(",")]; x, y, w, h = v; sys.exit(not (len(v) == 4 and x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 1 and y + h <= 1))' \
    "$1" 2>/dev/null
}

# The one fit= line and its 2% tolerance; returns 1 on a miss, the ratio left in IMAGE_LEG_ACHIEVED.
image_leg_aspect_fit() { # want(w:h) width height [suffix]
  local fit
  fit=$(awk -v w="$2" -v h="$3" -v want="$1" 'BEGIN {
    split(want, r, ":"); got = w / h; asked = r[1] / r[2]; d = got / asked - 1; if (d < 0) d = -d
    printf "%.3f %s", got, (d <= 0.02 ? "ok" : "miss") }')
  IMAGE_LEG_ACHIEVED=${fit% *} IMAGE_LEG_FIT="$1 $fit"
  printf 'aspect=%s achieved=%s fit=%s%s\n' "$1" "$IMAGE_LEG_ACHIEVED" "${fit#* }" "${4:-}"
  [ "${fit#* }" = ok ]
}

# --composite[=auto|x,y,w,h] and --no-composite: the same flags on every image wrapper.
image_leg_composite_arg() { # flag
  case $1 in
    --composite) IMAGE_LEG_COMPOSITE_ASK=auto ;;
    --composite=?*) IMAGE_LEG_COMPOSITE_ASK=${1#--composite=} ;;
    --no-composite) IMAGE_LEG_COMPOSITE_OFF=true ;;
    *) return 1 ;;
  esac
}

# Every vendor re-renders the whole image on an edit, so every edit of an existing image is
# composited onto it by default. An edit has exactly one input: the single --ref, else the resumed
# session's last delivered image. An explicit --composite insists (the first --ref among several);
# a contradiction exits 2 before anything is spent. The input is copied now: dest may overwrite it.
# Mask arguments a wrapper set in IMAGE_LEG_COMPOSITE_ARGS (--region, --point) stand unless
# --composite names its own.
image_leg_composite_plan() { # vendor resume repaint(true|false) [ref...]
  local vendor=$1 resume=$2 repaint=$3 tool=${IMAGE_LEG_TOOL:-image} ask=${IMAGE_LEG_COMPOSITE_ASK:-} inputs input='' dir=''
  shift 3
  inputs=$#
  if [ "$#" -gt 0 ]; then
    input=$1
  elif [ -n "$resume" ]; then
    inputs=1
    input=$(image_leg_session_input "$vendor" "$resume") || input=''
  fi
  IMAGE_LEG_COMPOSITE_INPUT=$input IMAGE_LEG_COMPOSITE_SKIP='' IMAGE_LEG_COMPOSITE_QUIET=''
  if [ -n "$ask" ]; then
    if [ -n "${IMAGE_LEG_COMPOSITE_OFF:-}" ]; then
      printf '%s: pass --composite or --no-composite, not both\n' "$tool" >&2
      exit 2
    fi
    [ "$ask" = auto ] || image_leg_region_ok "$ask" || {
      printf '%s: --composite takes auto or x,y,w,h as fractions of the image (0..1, inside it), not %s\n' "$tool" "$ask" >&2
      exit 2
    }
    if [ "$repaint" = true ]; then
      printf '%s: --composite never runs with --remove-bg or --transparent: both repaint the whole background\n' "$tool" >&2
      exit 2
    fi
    if [ -z "$input" ]; then
      printf '%s: --composite needs the image being edited: a --ref, or --resume of a session whose last image this machine delivered\n' "$tool" >&2
      exit 2
    fi
    IMAGE_LEG_COMPOSITE_ARGS=()
    [ "$ask" = auto ] || IMAGE_LEG_COMPOSITE_ARGS=(--mask "$ask")
  elif [ -n "${IMAGE_LEG_COMPOSITE_OFF:-}" ]; then
    IMAGE_LEG_COMPOSITE_SKIP=opted-out IMAGE_LEG_COMPOSITE_QUIET=true
  elif [ "$repaint" = true ]; then
    IMAGE_LEG_COMPOSITE_SKIP=transparent IMAGE_LEG_COMPOSITE_QUIET=true
  elif [ "$inputs" -eq 0 ]; then
    IMAGE_LEG_COMPOSITE_SKIP=new-generation
  elif [ "$inputs" -gt 1 ]; then
    IMAGE_LEG_COMPOSITE_SKIP=several-inputs
  elif [ -z "$input" ]; then
    IMAGE_LEG_COMPOSITE_SKIP=input-unknown
    printf '%s: this machine delivered no image for session %s; the edit is not composited\n' "$tool" "$resume" >&2
  fi
  [ -z "$IMAGE_LEG_COMPOSITE_SKIP" ] || return 0
  if dir=$(mktemp -d "${TMPDIR:-/tmp}/image-leg-composite.XXXXXX") && cp "$input" "$dir/base"; then
    IMAGE_LEG_COMPOSITE_BASE=$dir/base
  else
    [ -z "$dir" ] || rm -rf "$dir"
    IMAGE_LEG_COMPOSITE_SKIP=input-unreadable
  fi
}

# One delivered take: dest holds the vendor's render and becomes the composite, the render kept
# beside it as <stem>.rendered.<ext> whenever the composite changed what dest delivers. A take of
# several (Flow --count) passes `variant`: the run-wide skip reason was said once already.
image_leg_composite_take() { # root dest [variant]
  local root=$1 dest=$2 rendered line uv
  rendered="${dest%.*}.rendered.${dest##*.}"
  rm -f "$rendered"
  if [ -n "${IMAGE_LEG_COMPOSITE_SKIP:-}" ]; then
    [ -n "${IMAGE_LEG_COMPOSITE_QUIET:-}" ] || [ -n "${3:-}" ] ||
      printf 'composite=skipped reason=%s\n' "$IMAGE_LEG_COMPOSITE_SKIP"
    return 0
  fi
  [ -n "${IMAGE_LEG_COMPOSITE_BASE:-}" ] || return 0
  uv=$(command -v uv || printf /opt/homebrew/bin/uv)
  # uv leaves its script lock in TMPDIR; the run's own composite directory takes it away at exit.
  if cp "$dest" "$rendered" && line=$(TMPDIR=${IMAGE_LEG_COMPOSITE_BASE%/*} "$uv" run -q --script "$root/share/image_composite.py" \
      --base "$IMAGE_LEG_COMPOSITE_BASE" --edited "$rendered" --out "$dest" \
      ${IMAGE_LEG_COMPOSITE_ARGS[@]+"${IMAGE_LEG_COMPOSITE_ARGS[@]}"}); then
    printf '%s\n' "$line"
    case $line in
      composite=auto\ * | composite=region\ * | composite=points\ *)
        printf 'rendered=%s\n' "$rendered"
        return 0
        ;;
    esac
  else
    printf 'composite=failed\n'
    printf '%s: composite failed; the edited image is delivered as generated\n' "${IMAGE_LEG_TOOL:-image}" >&2
  fi
  rm -f "$rendered"
}

image_leg_composite_record() {
  jq -cn --arg composite "${IMAGE_LEG_COMPOSITE_LINES:-}" \
    --arg quiet "${IMAGE_LEG_COMPOSITE_QUIET:+${IMAGE_LEG_COMPOSITE_SKIP:-}}" '
    ($composite | (split("\n")[0] // "")
        | capture("^composite=(?<kind>[a-z]+)(?: reason=(?<reason>[^ ]+))?(?: changed=(?<changed>[0-9.]+)%)?"))
      // (if $quiet == "" then null else {kind: "skipped", reason: $quiet} end)
      | if . == null then null
        else {kind, changed: (.changed // "" | tonumber? // null), reason: (.reason // null)} end'
}

image_leg_edit_arg() { # image resume
  local tool=${IMAGE_LEG_TOOL:-image}
  [[ "$1" = /* ]] && [ -f "$1" ] || {
    printf '%s: --edit takes an absolute image path, not %s\n' "$tool" "$1" >&2
    exit 2
  }
  [ -z "$2" ] || {
    printf '%s: --edit names the image to edit and --resume continues a session'"'"'s last one: pass one of them\n' "$tool" >&2
    exit 2
  }
  IMAGE_LEG_EDIT=$1
}

image_leg_edit_sentence() { # reference count, the edited image included
  [ -z "${IMAGE_LEG_EDIT:-}" ] || [ "$1" -le 1 ] ||
    printf 'The first image is the one to edit; the other images are references only.\n'
}

image_leg_lock_wait_arg() { # seconds
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  IMAGE_LEG_LOCK_WAIT=$1
}

image_leg_fallback_route() { # root vendor route-given resume expressible(true|false)
  [ -z "$3" ] && [ -z "$4" ] && [ "$5" = true ] || return 0
  jq -r --arg route "${IMAGE_LEG_ROUTE:-}" '.routes as $all | ($all | index($route)) as $at
    | if $at == null then empty else ($all[$at + 1] // empty) end' "$(image_caps_file "$1" "$2")" 2>/dev/null || true
}

# Only a failure that reached no vendor moves the request: anything sent may still bill or deliver.
# Under bin/image-fanout (IMAGE_LEG_SCHEDULER) busy and limit exit as themselves: the scheduler moves
# the take to another account and relaunches it with --route itself once none is left.
image_leg_fallback() { # rc engine-json next-route
  local rc=$1 result reason
  [ -n "$3" ] && [ -z "${IMAGE_LEG_FALLBACK_FROM:-}" ] || return 1
  case "$rc:${IMAGE_LEG_SCHEDULER:-}" in 3:?* | 5:?*) return 1 ;; esac
  result=$(jq -c 'select(type == "object")' <<<"$2" 2>/dev/null) || result=''
  [ -n "$result" ] || result='{}'
  jq -e '.sent != true and ((.refused // []) | length) == 0 and ((.reason // "") | test("refus|polic"; "i") | not)' \
    <<<"$result" >/dev/null || return 1
  case $rc in
    3) reason=limit; ! jq -e '.flagged == true' <<<"$result" >/dev/null || reason=flagged ;;
    4) reason=sign-in ;;
    5) reason=busy ;;
    1) jq -e '.sent == false' <<<"$result" >/dev/null || return 1; reason=not-sent ;;
    *) return 1 ;;
  esac
  printf '%s: --route %s failed (%s); the same request goes to --route %s\n' \
    "${IMAGE_LEG_TOOL:-image}" "$IMAGE_LEG_ROUTE" "$reason" "$3" >&2
  IMAGE_LEG_FALLBACK_FROM=$IMAGE_LEG_ROUTE IMAGE_LEG_FALLBACK_REASON=$reason IMAGE_LEG_ROUTE=$3 IMAGE_LEG_PHASES=''
}

# Exit 3 names its cause from the engine's own result: a flagged account (a 24 h wall) is no usage limit.
image_leg_limit() { # LABEL engine-json
  if jq -e '.flagged == true' <<<"${2:-}" >/dev/null 2>&1; then
    printf '%s_ACCOUNT_FLAGGED\n' "$1" >&2
  else
    printf '%s_USAGE_LIMIT\n' "$1" >&2
  fi
  exit 3
}

image_leg_busy() { # account
  printf 'ACCOUNT_BUSY account=%s\n' "${1:-unknown}" >&2
  exit 5
}

image_leg_engine_phases() { # engine-json
  IMAGE_LEG_PHASES=$(jq -c '.phases | select(type == "object")' <<<"$1" 2>/dev/null) || IMAGE_LEG_PHASES=''
}

image_leg_route_lines() { # [rest of the route= line]
  printf 'job=%s\nroute=%s%s\n' "${IMAGE_JOB_ID:-}" "${IMAGE_LEG_ROUTE:-}" "${1:-}"
  [ -z "${IMAGE_LEG_FALLBACK_FROM:-}" ] ||
    printf 'fallback_from=%s\nfallback_reason=%s\n' "$IMAGE_LEG_FALLBACK_FROM" "$IMAGE_LEG_FALLBACK_REASON"
  [ -z "${IMAGE_LEG_PHASES:-}" ] || printf 'phases=%s\n' "$IMAGE_LEG_PHASES"
}

image_leg_session_file() { # vendor session
  local log
  log=$(image_leg_log_path)
  case $log in */*) log=${log%/*} ;; *) log=. ;; esac
  printf '%s/sessions/%s/%s' "$log" "$1" "$2"
}

# The image a resumed session continues from: the last one delivered in it, while it is still on disk.
image_leg_session_input() { # vendor session
  local file dest
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || return 1
  file=$(image_leg_session_file "$1" "$2")
  [ -f "$file" ] && dest=$(head -n 1 "$file") && [ -f "$dest" ] || return 1
  printf '%s\n' "$dest"
}

# The route that made a session; records from before routes were kept have none.
image_leg_session_route() { # vendor session
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || return 1
  sed -n 2p "$(image_leg_session_file "$1" "$2")" 2>/dev/null | grep -E '^[a-z]+$'
}

# Parent = the first input with a sidecar; with none the first input is a root at depth 0, and no
# input makes dest itself the root. Prints the main take's composite lines before edit_depth=.
image_leg_lineage() { # vendor route dest session prompt region points(newline-separated) [input...]
  local vendor=$1 route=$2 dest=$3 session=$4 prompt=$5 region=$6 points=$7 parent='' previous=null input sidecar file made
  shift 7
  for input in "$@"; do
    if jq -e '(.root | type) == "string" and (.depth | type) == "number" and (.edits | type) == "array"' \
        "$input.edit.json" >/dev/null 2>&1; then
      parent=$input previous=$(cat "$input.edit.json")
      break
    fi
  done
  [ -n "$parent" ] || parent=${1:-}
  made=$(image_leg_composite_record) || made=null
  sidecar=$(jq -n --arg dest "$dest" --arg parent "$parent" --argjson previous "$previous" \
    --arg vendor "$vendor" --arg route "$route" --arg account "${account:-}" --arg prompt "$prompt" \
    --arg region "$region" --arg points "$points" --argjson made "$made" '
    if $parent == "" then {root: $dest, depth: 0, edits: []}
    else ($previous // {root: $parent, depth: 0, edits: []}) as $from
      | {root: $from.root, depth: ($from.depth + 1), edits: ($from.edits + [{prompt: $prompt,
          region: (if $region == "" then null else $region end),
          points: ($points | split("\n") | map(select(. != ""))),
          route: $route, vendor: $vendor, account: $account}
          + (if $made == null then {} else {composite: $made} end)])}
    end') || return 0
  if ! printf '%s\n' "$sidecar" >"$dest.edit.json.$$" || ! mv -f "$dest.edit.json.$$" "$dest.edit.json"; then
    rm -f "$dest.edit.json.$$"
    printf '%s: could not write %s.edit.json\n' "${IMAGE_LEG_TOOL:-image}" "$dest" >&2
  fi
  if [ "$session" != none ] && [[ "$session" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    file=$(image_leg_session_file "$vendor" "$session")
    mkdir -p "${file%/*}" 2>/dev/null && printf '%s\n%s\n' "$dest" "$route" >"$file" 2>/dev/null || true
  fi
  [ -z "${IMAGE_LEG_COMPOSITE_LINES:-}" ] || printf '%s\n' "$IMAGE_LEG_COMPOSITE_LINES"
  jq -r '"edit_depth=\(.depth) root=\(.root)"' <<<"$sidecar"
}
