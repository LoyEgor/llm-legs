#!/usr/bin/env bash
. "${BASH_SOURCE%"${BASH_SOURCE##*/}"}lib/suite-journal.sh"
# Egor's rule: every model is resolved at run time from live catalogs, so no production file of
# llm-legs, review-bench (share/rbench) or claude-setup (agents, commands, hooks) names a model id
# (or a vendor CLI version) outside tests/hardcode-allowlist.txt. The allowlist's KNOWN_DEBT section
# holds true hardcodes still to remove: green today, printed on every run. The guard of
# docs/shared-invariants.md row `cr`: comment lines, the first code line under a `pin: <reason>`
# comment and a registered experiment's TEMP-tagged line are exempt.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REVIEW_ROOT="${REVIEW_ROOT:-$ROOT/../review-bench}"
SETUP_ROOT="${CLAUDE_SETUP_ROOT:-$ROOT/../claude-setup}"
ALLOWLIST="$ROOT/tests/hardcode-allowlist.txt"
asserts=0
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert() { if ! "$@"; then fail "assert $((asserts + 1)): $*"; fi; asserts=$((asserts + 1)); }
eq() { [ "$1" = "$2" ] || { printf 'expected: %s\n  actual: %s\n' "$2" "$1" >&2; return 1; }; }

# awk ERE has no \b: the leading class stands in for it.
MODEL_RE='(^|[^A-Za-z0-9_])(claude-(opus|sonnet|haiku|fable)-[0-9]|claude-[0-9]|gpt-(image-)?[0-9]|gemini-[0-9]|grok-?[0-9]|grok-imagine-|(imagen|veo)-[0-9]|(opus|sonnet|haiku|fable|flash|pro)-?[0-9]+|(deepseek|glm|kimi|qwen|minimax|mimo)-[a-z]?[0-9]|[0-9]+[.][0-9]+[.][0-9]+)'
LEGS_SPEC=(bin share lib hooks hammerspoon '*.lua' '*.py' '*.sh' '*.jq'
  ':!tests' ':!test' ':!docs' ':!*fixture*' ':!*.json' ':!share/image-caps')

list_files() { # <dir> <display-prefix> <pathspec...> -> "<abs path><TAB><display path>"
  local dir=$1 label=$2
  shift 2
  git -C "$dir" ls-files -z --cached --others --exclude-standard -- "$@" |
    while IFS= read -r -d '' path; do
      if [ -f "$dir/$path" ] && [ ! -L "$dir/$path" ]; then printf '%s\t%s%s\n' "$dir/$path" "$label" "$path"; fi
    done
}

experiment_words() { # <EXPERIMENTS.json...> -> one id or tag per line
  local file
  for file in "$@"; do
    [ -r "$file" ] && jq -r '.[]? | .id?, .tag? | strings' "$file" 2>/dev/null || true
  done
}

# scan <allowlist> < files: lines `HIT|DEBT <path>:<line>: <text>`, `STALE <entry>`, `BAD <entry>`.
scan() {
  EXPERIMENT_WORDS=${EXPERIMENT_WORDS:-} awk -F'\t' -v re="$MODEL_RE" -v list="$1" '
    function glob_re(g) {
      gsub(/[.+(){}|^$]/, "\\\\&", g); gsub(/\*/, "[^/]*", g); gsub(/\?/, "[^/]", g)
      return "^" g "$"
    }
    function check(path, number, line,    text, i, at, verdict) {
      text = line
      for (i = 1; i <= words; i++)
        while ((at = index(text, word[i])) > 0) text = substr(text, 1, at - 1) substr(text, at + length(word[i]))
      gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "", text)
      if (text !~ re) return
      verdict = "HIT"
      for (i = 1; i <= n; i++)
        if (path ~ path_re[i] && line ~ line_re[i]) { used[i] = 1; verdict = kind[i] == "debt" ? "DEBT" : "ALLOW"; break }
      if (verdict != "ALLOW") printf "%s %s:%d: %s\n", verdict, path, number, substr(line, 1, 160)
    }
    BEGIN {
      words = split(ENVIRON["EXPERIMENT_WORDS"], word, "\n")
      section = "allow"
      while ((getline row < list) > 0) {
        if (row ~ /^[ \t]*$/ || row ~ /^#/) continue
        if (row ~ /^\[KNOWN_DEBT\]$/) { section = "debt"; continue }
        cut = index(row, " # ")
        body = cut ? substr(row, 1, cut - 1) : row
        split(body, part, " ")
        pattern = substr(body, length(part[1]) + 2)
        if (!cut || part[1] == "" || pattern == "" || substr(row, cut + 3) ~ /^[ \t]*$/) {
          print "BAD " row; continue
        }
        n++; entry[n] = row; kind[n] = section; path_re[n] = glob_re(part[1]); line_re[n] = pattern
      }
    }
    {
      exempt = 0; number = 0
      while ((getline line < $1) > 0) {
        number++
        if (line ~ /(#|--|\/\/) pin: /) { exempt = 1; continue }
        if (line ~ /^[ \t]*(#|--|\/\/)/) continue
        if (exempt || line ~ /TEMP-[A-Z][A-Z0-9_-]*\([a-z0-9_-]+\)/) { exempt = 0; continue }
        check($2, number, line)
      }
      close($1)
    }
    END { for (i = 1; i <= n; i++) if (!used[i]) print "STALE " entry[i] }'
}

# --- Self-test: a fixture tree proves the scanner goes red on a planted id ---
scratch=$(mktemp -d "${TMPDIR:-/tmp}/no-hardcode.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/legs" bench="$scratch/bench"
mkdir -p "$fixture/bin" "$fixture/share" "$fixture/tests" "$fixture/docs" "$bench/share/rbench"
printf '#!/bin/bash\nmodel="claude-opus-5-5"\n' >"$fixture/bin/x"
printf '# gpt-6-sol was newest\nhost=127.0.0.1\n# pin: cheapest probe\n# still the pin comment\nprobe=claude-haiku-4-5\nua="cli/2.1.280"\nkeep=grok-4.7\nlead=flash37 # TEMP-%s(x)\nnext=flash37\nlast=flash37\n' \
  PROBE >"$fixture/share/y.sh"
printf 'model="gpt-6-sol"\n' >"$fixture/tests/test_z.sh"
printf 'gemini-3.8-flash\n' >"$fixture/docs/d.sh"
printf 'use flash38\n' >"$fixture/share/n.md"
printf 'cell = "glm-5.2"\nrename = "old-gpt-5-x"\n' >"$bench/share/rbench/c.py"
for tree in "$fixture" "$bench"; do git -C "$tree" init -q && git -C "$tree" add -A; done
printf 'share/*.sh cli/[0-9] # UA\n[KNOWN_DEBT]\nshare/y.sh ^keep= # debt\n' >"$fixture/allow.txt"
fixture_scan() {
  { list_files "$fixture" '' "${LEGS_SPEC[@]}"; list_files "$bench" 'review-bench/' share/rbench; } |
    EXPERIMENT_WORDS=old-gpt-5-x scan "$fixture/allow.txt"
}
assert eq "$(fixture_scan)" \
  'HIT bin/x:2: model="claude-opus-5-5"
HIT share/n.md:1: use flash38
DEBT share/y.sh:7: keep=grok-4.7
HIT share/y.sh:9: next=flash37
HIT share/y.sh:10: last=flash37
HIT review-bench/share/rbench/c.py:1: cell = "glm-5.2"'
rm "$fixture/bin/x" && git -C "$fixture" add -A
assert eq "$(fixture_scan | grep -c '^HIT bin/')" 0
printf 'bin/* gpt # never matches\nbin/q no-reason\n' >>"$fixture/allow.txt"
assert eq "$(fixture_scan | grep -E '^(STALE|BAD)')" \
  'BAD bin/q no-reason
STALE bin/* gpt # never matches'

# --- The real trees ---
assert test -r "$ALLOWLIST"
assert test -d "$REVIEW_ROOT/share/rbench"
assert test -r "$SETUP_ROOT/commands/worker.md"
report=$({ list_files "$ROOT" '' "${LEGS_SPEC[@]}"
           list_files "$REVIEW_ROOT" 'review-bench/' share/rbench
           list_files "$SETUP_ROOT" 'claude-setup/' agents commands hooks; } |
         EXPERIMENT_WORDS=$(experiment_words "$ROOT/EXPERIMENTS.json" "$REVIEW_ROOT/EXPERIMENTS.json") \
           scan "$ALLOWLIST")
bad=$(printf '%s\n' "$report" | grep -E '^(HIT|STALE|BAD) ' || true)
if [ -n "$bad" ]; then
  printf '%s\n' "$bad" >&2
  fail "model id outside tests/hardcode-allowlist.txt (HIT), or an entry matching nothing (STALE) or without a reason (BAD)"
fi
asserts=$((asserts + 1))
debt=$(printf '%s\n' "$report" | grep -c '^DEBT ' || true)
printf '%s\n' "$report" | grep '^DEBT ' | sed 's/^/KNOWN_DEBT: /' || true

printf 'PASS: %s asserts; no hardcoded model ids (fixture red on a planted id, allowlist live, %s known-debt lines)\n' \
  "$asserts" "$debt"
