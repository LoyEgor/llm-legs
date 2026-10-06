#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# flow_image.refusal names every refusal code and picks the quota exit code, from a list or a one-shot generator.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts: $*"; }
export HOME="$WORK/home" GEMINI_WEB_DIR="$WORK/home/.gemini-web" PYTHONDONTWRITEBYTECODE=1
mkdir -p "$GEMINI_WEB_DIR"

assert python3 - "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "share"))
import flow_image as fi

refused = [{"error": "PUBLIC_ERROR_UNSAFE_GENERATION"}, {"error": "PUBLIC_ERROR_USER_QUOTA_REACHED"}]
failure = fi.refusal(r["error"] for r in refused)
assert failure.code == 3, failure.code
assert failure.reason == "Flow refused the image: PUBLIC_ERROR_UNSAFE_GENERATION, PUBLIC_ERROR_USER_QUOTA_REACHED", \
    failure.reason
failure = fi.refusal(r["error"] for r in refused[:1])
assert failure.code == 1 and failure.reason.endswith(": PUBLIC_ERROR_UNSAFE_GENERATION"), (failure.code, failure.reason)
PY

printf 'PASS: %s asserts; flow_image.refusal keeps every refusal code from a generator and exits 3 on a quota code\n' "$asserts"
