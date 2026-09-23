#!/usr/bin/env bash
# Sourced by bin/grok-image and bin/grok-video. Limits belong in share/image-caps/grok.json, not
# here: a value hardcoded in this file is one no manifest re-verification can correct.

# grokb's own resolution, minus the exotic candidates: this is only ever asked for a `--version`
# banner, and an unfound binary degrades to `caps=stale cli=unknown` rather than failing a run.
grok_media_grok_bin() {
  if [ -n "${GROKB_GROK_BIN:-}" ]; then printf '%s\n' "$GROKB_GROK_BIN"; return 0; fi
  command -v grok 2>/dev/null
}

grok_media_valid_account() { [[ "${1-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

# Sets grok_media_account. Returns 3 on a wall (the caller exits 3 with GROK_USAGE_LIMIT already
# on stderr), 1 on anything else. A wall must never be reported as a plain failure and a plain
# failure must never be reported as a wall: callers reroute off 3 as if the quota were spent.
grok_media_select_account() { # tool root worker-pick-cmd profiles-dir requested-account
  local tool=$1 root=$2 worker_pick_cmd=$3 profiles_dir=$4 requested=${5-}
  local picked=false pick_rc=0
  grok_media_account=$requested
  if [ -z "$grok_media_account" ]; then
    grok_media_account=$("$worker_pick_cmd" --account grok --role image 2>/dev/null) || pick_rc=$?
    if [ "$pick_rc" -eq 3 ]; then
      printf 'GROK_USAGE_LIMIT\n' >&2
      return 3
    fi
    if [ "$pick_rc" -ne 0 ] || ! grok_media_valid_account "$grok_media_account"; then
      . "$root/share/worker-model.sh"
      grok_media_account=$(worker_model_pin_first grok 2>/dev/null || true)
      if ! grok_media_valid_account "$grok_media_account"; then
        printf '%s: worker-pick failed\n' "$tool" >&2
        return 1
      fi
      printf '%s: worker-pick unavailable; falling back to account %s\n' "$tool" "$grok_media_account" >&2
    else
      picked=true
    fi
  fi
  # `grokb profile` creates what it cannot find, so an unchecked typo here does not fail: it mkdirs
  # a ghost account that then stands in grokb list, the quota scan and the limits menu asking for a
  # login.
  if [ "$grok_media_account" != main ] && [ ! -d "$profiles_dir/$grok_media_account" ]; then
    printf '%s: account directory does not exist: %s\n' "$tool" "$profiles_dir/$grok_media_account" >&2
    return 1
  fi
  # The claim is recorded once the account is known to be usable, which is why the pick above does
  # not take it: a claim spent on a profile this run cannot launch de-prioritises that account for
  # the next ten minutes and buys nothing. Same recorder worker-pick uses, so there is one format.
  if [ "$picked" = true ] && ! worker_claims_record grok "$grok_media_account"; then
    printf '%s: could not record the claim on %s\n' "$tool" "$grok_media_account" >&2
  fi
  return 0
}

# The media tools all answer with the same MediaGenOutput under a per-tool `type` tag: image_gen
# reports ImageGen, image_edit ImageEdit, image_to_video ImageToVideo and reference_to_video
# ReferenceToVideo (ImageToVideo before 1.0.41). Reading the tag list
# rather than one name is what keeps an edit or a reference_to_video run from looking like a
# generation that produced nothing.
grok_media_stream_path() { # stream-file type[,type...]
  local stream=$1 types=$2 path
  path=$(jq -Rr --arg types "$types" '
    ($types | split(",")) as $wanted |
    fromjson? |
    select(.type == "tool_call_update") |
    .rawOutput // empty |
    (.type // "") as $tag |
    select($wanted | index($tag)) |
    .path // empty
  ' "$stream" 2>/dev/null | tail -n 1) || path=''
  [[ "$path" = /* ]] && [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

grok_media_session_id() { # stream-file
  local stream=$1 id
  id=$(jq -Rr 'fromjson? | .sessionId // empty' "$stream" 2>/dev/null | tail -n 1) || id=''
  printf '%s\n' "${id:-none}"
}

# Only a persistent wall is a wall. A transient "rate limited, retrying" is weather and must stay
# an ordinary failure, or every hiccup reroutes the pool.
grok_media_failure_class() { # stream-file stderr-file -> limit|pool|unknown
  local stream=$1 errors=$2
  if grep -Eqi 'hit the rate limit for your plan|hit the credit limit for your plan|subscription:free-usage-exhausted|run out of credits|(status|http)[^0-9]{0,12}402([^0-9]|$)|402 payment required' \
      "$stream" "$errors" 2>/dev/null; then
    printf 'limit\n'
    return 0
  fi
  if grep -Eqi 'out of the worker pool|treating every account as out of the pool' \
      "$stream" "$errors" 2>/dev/null; then
    printf 'pool\n'
    return 0
  fi
  printf 'unknown\n'
}

# `features.image_gen_model_override` / `image_edit_model_override` are the only per-account say
# over which Imagine model answers; empty (the normal case) defers to a remotely configured
# default the CLI never reports back, which is why an absent override yields no observation here.
grok_media_model_override() { # grok-home key
  local home=$1 key=$2 file="$1/config.toml" value
  [ -n "$home" ] && [ -f "$file" ] || return 0
  value=$(LC_ALL=C sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*[\"']\\([^\"']*\\)[\"'].*/\\1/p" "$file" | tail -n 1)
  [ -n "$value" ] || return 0
  printf '%s\n' "$value"
}

grok_media_sync_model_override() { # grok-home key model
  [ -n "$1" ] && [ -d "$1" ] && [ -n "$3" ] || return 1
  python3 - "$1/config.toml" "$2" "$3" <<'PY'
import os, re, sys, tempfile
path, key, model = sys.argv[1:4]
want = f'{key} = "{model}"\n'
lines = open(path).read().splitlines(True) if os.path.exists(path) else []
table, header, found = None, None, None
for i, line in enumerate(lines):
    m = re.match(r'\s*\[([^\[\]]+)\]\s*(#.*)?$', line)
    if m:
        table = m.group(1).strip()
        if table == "features":
            header = i
        continue
    m = re.match(r'\s*(features\.)?' + re.escape(key) + r'\s*=\s*["\']([^"\']*)["\']', line)
    if m and ((table == "features" and not m.group(1)) or (table is None and m.group(1))):
        found = (i, m.group(2), bool(m.group(1)))
if found:
    if found[1] == model:
        sys.exit(0)
    lines[found[0]] = ("features." if found[2] else "") + want
elif header is not None:
    lines.insert(header + 1, want)
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines += (["\n"] if lines else []) + ["[features]\n", want]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.toml.")
with os.fdopen(fd, "w") as out:
    out.writelines(lines)
if os.path.exists(path):
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
PY
}

# One long generation per account at a time. Grok itself tolerates concurrent sessions in one
# GROK_HOME, but two media runs stacked on one account race the same quota and the same parallel
# media-call cap, and the loser pays for a refusal.
grok_media_lock_acquire() { # tool account
  local tool=$1 account=$2 waited=0 mtime now candidate
  candidate="${TMPDIR:-/tmp}/$tool.$account.lock"
  while ! mkdir "$candidate" 2>/dev/null; do
    mtime=$(stat -f %m "$candidate" 2>/dev/null || printf '0')
    now=$(date +%s)
    if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt "${GROK_MEDIA_LOCK_STALE:-1800}" ]; then
      rmdir "$candidate" 2>/dev/null || true
      continue
    fi
    if [ "$waited" -ge "${GROK_MEDIA_LOCK_WAIT:-900}" ]; then
      printf '%s: timed out waiting for account lock: %s\n' "$tool" "$account" >&2
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  grok_media_lock_dir=$candidate
  return 0
}

grok_media_lock_release() {
  [ -n "${grok_media_lock_dir:-}" ] || return 0
  rmdir "$grok_media_lock_dir" 2>/dev/null || true
  grok_media_lock_dir=''
}

# Sessions live under <profile>/sessions/<url-encoded cwd>/<session-id>/, so the account that owns
# a session id is the profile whose tree holds that directory. Recovering it is what lets a resume
# carry only the id: the wrong account cannot see the session at all.
grok_media_account_for_session() { # profiles-dir main-grok-home session-id
  local profiles_dir=$1 main_home=$2 session=$3 candidate
  case "$session" in ''|*/*|.|..) return 1 ;; esac
  candidate=$(find "$profiles_dir" -mindepth 4 -maxdepth 4 -type d -name "$session" -print 2>/dev/null | sort | head -n 1)
  if [ -n "$candidate" ]; then
    # <profiles-dir>/<account>/sessions/<url-encoded cwd>/<session-id>
    candidate=${candidate%/*}; candidate=${candidate%/*}; candidate=${candidate%/*}
    printf '%s\n' "${candidate##*/}"
    return 0
  fi
  candidate=$(find "$main_home/sessions" -mindepth 2 -maxdepth 2 -type d -name "$session" -print 2>/dev/null | head -n 1)
  [ -n "$candidate" ] || return 1
  printf 'main\n'
}
