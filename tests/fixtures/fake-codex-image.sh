#!/usr/bin/env bash
set -euo pipefail

: "${FAKE_CODEX_CALLS:?}"
: "${FAKE_CODEX_PROMPT:?}"
: "${REAL_MAGICK:?}"

if [ "${1-}" = --version ]; then
  printf 'codex-cli %s\n' "${FAKE_CODEX_VERSION:?}"
  exit 0
fi

printf 'CODEX_HOME=%s\n' "${CODEX_HOME-<unset>}" >>"$FAKE_CODEX_CALLS"
# The launching chat's stamp, which an image relay only ever passes THROUGH: whatever it writes
# is journaled by the agent that ran it, and a scrubbed environment there is an edit no chat owns.
printf 'CLAUDE_LAUNCHER_SESSION=%s\n' "${CLAUDE_LAUNCHER_SESSION-<unset>}" >>"$FAKE_CODEX_CALLS"
last_message_file=''
resume_id=''
previous=''
for argument in "$@"; do
  printf 'ARG=%s\n' "$argument" >>"$FAKE_CODEX_CALLS"
  case "$previous" in
    -o|--output-last-message) last_message_file=$argument ;;
    resume) resume_id=$argument ;;
  esac
  previous=$argument
done
cat >"$FAKE_CODEX_PROMPT"

case "${FAKE_CODEX_MODE:-image}" in
  limit)
    printf "You've hit your usage limit. Try again later.\n" >&2
    exit 1
    ;;
  fail)
    printf 'stream disconnected before completion\n' >&2
    exit 1
    ;;
esac

thread=${FAKE_CODEX_THREAD:-01a09aaa-1111-7000-8000-00000000000a}
if [ -n "$resume_id" ] && [ "${FAKE_CODEX_MODE:-image}" != newthread ]; then
  thread=$resume_id
fi
printf '%s\n' "{\"type\":\"thread.started\",\"thread_id\":\"$thread\"}"
printf '%s\n' '{"type":"turn.started"}'

if [ "${FAKE_CODEX_MODE:-image}" = no-image ]; then
  printf '%s\n' '{"type":"turn.completed"}'
  [ -z "$last_message_file" ] || printf 'no image was produced\n' >"$last_message_file"
  exit 0
fi

home=${CODEX_HOME:-$HOME/.codex}
image_dir="$home/generated_images/$thread"
mkdir -p "$image_dir"
case "${FAKE_CODEX_IMAGE_FORMAT:-png}" in
  jpg)
    image_path="$image_dir/exec-fixture.jpg"
    "$REAL_MAGICK" -size 64x64 'xc:#00FF00' -fill blue -draw 'circle 32,32 32,14' "JPEG:$image_path"
    ;;
  rgba)
    image_path="$image_dir/exec-fixture.png"
    "$REAL_MAGICK" -size 64x64 xc:none -fill blue -draw 'circle 32,32 32,14' "PNG32:$image_path"
    ;;
  opaque)
    # An image asked for alpha and answered without it: the flat key colour is what the prompt
    # orders as the fallback, so the chroma path has something to key.
    image_path="$image_dir/exec-fixture.png"
    "$REAL_MAGICK" -size 64x64 'xc:#00FF00' -fill blue -draw 'circle 32,32 32,14' "PNG24:$image_path"
    ;;
  alpha-opaque)
    image_path="$image_dir/exec-fixture.png"
    "$REAL_MAGICK" -size 64x64 'xc:#00FF00' -fill blue -draw 'circle 32,32 32,14' \
      -alpha set "PNG32:$image_path"
    ;;
  *)
    image_path="$image_dir/exec-fixture.png"
    "$REAL_MAGICK" -size 64x64 'xc:#00FF00' -fill blue -draw 'circle 32,32 32,14' "PNG24:$image_path"
    ;;
esac
if [ -n "${FAKE_CODEX_AGENT_VERSION:-}" ]; then
  python3 - "$image_path" "$FAKE_CODEX_AGENT_VERSION" "${FAKE_CODEX_AGENT_NAME:-gpt-image}" <<'PY'
import struct, sys, zlib
path, version, name = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
cbor = (b"\x78\x0ddigitalSourceType\x61x" + b"softwareAgent\xa2\x64name" + bytes([0x60 + len(name)]) + name
        + b"\x67version" + bytes([0x60 + len(version)]) + version)
data = open(path, "rb").read()
end = data.rindex(b"IEND") - 4
chunk = struct.pack(">I", len(cbor)) + b"caBX" + cbor + struct.pack(">I", zlib.crc32(b"caBX" + cbor))
open(path, "wb").write(data[:end] + chunk + data[end:])
PY
fi
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'

if [ -n "$last_message_file" ] && [ "${FAKE_CODEX_MODE:-image}" != nopath ]; then
  printf 'Saved the image.\n%s\n' "$image_path" >"$last_message_file"
elif [ -n "$last_message_file" ]; then
  printf 'Saved the image somewhere under the codex home.\n' >"$last_message_file"
fi
