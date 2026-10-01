#!/usr/bin/env bash
set -euo pipefail

{
  printf 'LEG_LOG=%s\n' "${IMAGE_LEG_LOG:-}"
  for arg in "$@"; do printf 'ARG=%s\n' "$arg"; done
} >>"$FAKE_VIDEO_CALLS"

dest='' count=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --count) count=$2; shift 2 ;;
    *) shift ;;
  esac
done

case "${FAKE_VIDEO_MODE:-ok}" in
  limit) printf 'GEMINI_USAGE_LIMIT\ngemini-video: Flow credits are spent on fakeacct\n' >&2; exit 3 ;;
  login) printf 'gemini-video: fakeacct is not signed in to Flow\n' >&2; exit 4 ;;
  usage) printf 'gemini-video: bad request\n' >&2; exit 2 ;;
  crash) printf 'gemini-video: Flow UI drift: no composer\n' >&2; exit 7 ;;
esac

source=$FAKE_VIDEO_SOURCE
case "${FAKE_VIDEO_MODE:-ok}" in
  noaudio) source=$FAKE_VIDEO_NOAUDIO ;;
  mute) source=$FAKE_VIDEO_MUTE ;;
  faint) source=$FAKE_VIDEO_FAINT ;;
esac
cp "$source" "$dest"
printf 'dest=%s\nsize=640x360\nformat=mp4\nduration=4\naccount=fakeacct\nmedia=MEDIA1\nmodel=abra_t2v_4s_360p model_caps=fresh\n' "$dest"
index=2
[ "${FAKE_VIDEO_MODE:-ok}" != first-mute ] || cp "$FAKE_VIDEO_MUTE" "$dest"
while [ "$index" -le "$count" ]; do
  cp "$source" "${dest%.*}-$index.mp4"
  printf 'variant=%s size=640x360 duration=4 media=MEDIA%s\n' "${dest%.*}-$index.mp4" "$index"
  index=$((index + 1))
done
