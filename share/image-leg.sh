# Sourced by the image and video wrappers: one JSON line per run in the image-leg log, which
# llm-doctor reads for its Image block. Recording never changes a wrapper's status or output.

image_leg_start() { # tool kind [served-model-variable]
  IMAGE_LEG_TOOL=$1 IMAGE_LEG_KIND=$2 IMAGE_LEG_MODEL_VAR=${3:-} IMAGE_LEG_STARTED=$(date +%s)
  IMAGE_LEG_ERR='' IMAGE_LEG_TEE=''
  trap image_leg_exit EXIT
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

# A wrapper that sets its own EXIT trap calls this first in it: `$?` must still be the wrapper's
# status, and it returns 0 because errexit inside the trap would skip the wrapper's own cleanup.
image_leg_exit() {
  local rc=$? log err='' model='' index
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
  [ -z "$IMAGE_LEG_MODEL_VAR" ] || model=${!IMAGE_LEG_MODEL_VAR:-}
  log=${IMAGE_LEG_LOG:-$HOME/.cache/image-legs/legs.jsonl}
  mkdir -p "${log%/*}" 2>/dev/null || return 0
  jq -cn --arg tool "$IMAGE_LEG_TOOL" --arg kind "$IMAGE_LEG_KIND" --argjson rc "$rc" \
    --argjson started "$IMAGE_LEG_STARTED" --arg account "${account:-}" --arg served "$model" --arg err "$err" \
    '{ts: (now | floor), tool: $tool, kind: $kind, rc: $rc, seconds: ((now | floor) - $started),
      account: $account, served: $served, err: $err}' 2>/dev/null >>"$log" || true
  IMAGE_LEG_TOOL=''
  return 0
}
