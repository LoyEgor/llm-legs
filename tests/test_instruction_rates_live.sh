#!/usr/bin/env bash
# Every file the instruction gates guard must get a price from the LIVE export on this machine.
#
# test_instruction_gate.sh builds its own $HOME and its own read-rates.json, so it proves the code
# does what the fixtures describe. It passed 372 assertions while the gate was answering "cheap,
# not gated" for every project CLAUDE.md on this disk: the fixture happened to list the files it
# then asked about, and the real export does not — most instruction files are auto-loaded rather
# than opened, so no Read operation ever records them. Nothing in a synthetic $HOME can catch that.
# This walks the real guarded set against the real export instead, and it is the check that would
# have caught it in one second.
#
# A gate that stops gating is SILENT — it denies nothing and says nothing — so the failure this
# guards against cannot be noticed by using the machine. It has to be asserted.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# What this asks is the PRICE a growing file meets, and the gate answers a relay worker something
# else entirely — a refusal with no decision and no rate in it, because an instruction file is the
# orchestrator's to edit. Run by a worker, which is how these suites usually run, every priced row
# below would read as a gate that found no price at all: the one failure this file exists to catch.
unset CLAUDEB_WORKER GROK_WORKER CLAUDE_LAUNCHER_SESSION
. "$ROOT/share/instruction-files.sh"

RATES=${TOKENMAP_RATES:-$HOME/.local/share/tokenmap/read-rates.json}
if [ ! -f "$RATES" ]; then
  printf 'SKIP: no live export at %s (run: tokenmap scan)\n' "$RATES"
  exit 0
fi
if ! jq -e '.paths.entries | type == "object" and length > 0' "$RATES" >/dev/null 2>&1; then
  printf 'SKIP: live export carries no path entries yet\n'
  exit 0
fi

BLOAT="$ROOT/bin/instruction-bloat-gate.sh"
STAMPS=$(mktemp -d "${TMPDIR:-/tmp}/instruction-live.XXXXXX") || exit 1
trap 'rm -rf "$STAMPS" 2>/dev/null' EXIT
export INSTRUCTION_BLOAT_GATE_STAMPS="$STAMPS"

# The library answers with a rate; the GATE answers with a decision, and only the decision is what
# a growing file meets. They are not the same question — the class constants that price a skill or
# an agent brief live in the gate's own symlink walk, so a library that has never heard of them can
# be right and the gate still wrong. This drives the real hook with a real payload, reads nothing
# from the filesystem it would not read anyway, and keeps its stamps in a temporary directory so a
# check never spends a retry the next real edit is owed.
# Past the top of the byte ladder, so a priced file is denied whatever its rate and the only ways
# through are the two this exists to catch: the export calling the file cheap, or the gate finding
# no price for it at all and leaving without a word. A smaller payload proves nothing — an agent
# brief measured at 8 re-reads a week earns a 25,000-byte threshold and passes 4,000 correctly.
BIG_BYTES=120000
BIG=$(python3 -c "print('y' * $BIG_BYTES)") || exit 1
# The global file answers to a hard byte ceiling that is checked BEFORE any rate, so a payload past
# it proves only that the ceiling works. This one clears the 120-byte gate that file always has and
# still lands far below the ceiling, so the denial it earns is a priced one.
SMALL_BYTES=400
SMALL=$(python3 -c "print('y' * $SMALL_BYTES)") || exit 1
verdict() {
  jq -cn --arg p "$1" --arg n "$2" --arg s "live-corpus-$3" \
    '{tool_name:"Edit",cwd:"/tmp",session_id:$s,
      tool_input:{file_path:$p,old_string:"x",new_string:$n}}' \
    | bash "$BLOAT" 2>/dev/null
}

# A denial alone does not prove the LIVE export reached the gate: the frozen class constants in
# share/instruction-files.sh deny just as loudly, so an export that lost every entry would sail
# through a check that only looks at the decision. Only the measured and legacy branches name the
# index, and that phrase is the difference between "this machine measured it" and "a July constant
# guessed it". Classes the index cannot cover — a skill never recorded, an agent brief nobody Read —
# are asked for the denial alone.
LIVE='local read index'

asserts=0
failures=0
n=0
report() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n  %s\n  %s\n' "$1" "$2" "$3" >&2
}
# priced <path> <why> <payload-bytes> <payload> [live]
priced() {
  local path=$1 why=$2 bytes=$3 payload=$4 need_live=${5:-} out='' decision='' reason=''
  asserts=$((asserts + 1))
  n=$((n + 1))
  out=$(verdict "$path" "$payload" "$n")
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  if [ "$decision" != deny ]; then
    report "$path" "$why" "$bytes bytes of growth met: $(printf '%s' "$out" \
      | jq -r '.hookSpecificOutput.additionalContext // "no decision at all"' 2>/dev/null)"
    return 0
  fi
  [ -z "$need_live" ] && return 0
  case "$reason" in
    *"$LIVE"*) return 0 ;;
  esac
  report "$path" "$why" "denied, but on a frozen constant rather than the live index: $reason"
}
silent() {
  local path=$1 why=$2 out=''
  asserts=$((asserts + 1))
  n=$((n + 1))
  out=$(verdict "$path" "$BIG" "$n")
  [ -z "$out" ] && return 0
  report "$path" "$why" "gate answered: $out"
}

echo "== the global instruction file is priced under every name it answers to"
priced "$HOME/.claude/CLAUDE.md" "the one file in every session of every project" \
  "$SMALL_BYTES" "$SMALL" live
for profile in "$HOME"/.claude-profiles/*/CLAUDE.md; do
  [ -f "$profile" ] || continue
  priced "$profile" "a profile symlink to the global file is the global file" \
    "$SMALL_BYTES" "$SMALL" live
done

echo "== every project instruction file the export knows a rate for"
# The export names the working directories sessions actually ran in. A CLAUDE.md sitting in one of
# them rides in every session of that project, so an unpriced one is a file growing for free — and
# the price has to come from the index, because these are exactly the files a fixture cannot cover.
global_real=$(realpath "$HOME/.claude/CLAUDE.md" 2>/dev/null) || global_real=''
while IFS= read -r project; do
  for name in CLAUDE.md CLAUDE.local.md; do
    [ -f "$project/$name" ] || continue
    # ~/.claude is itself a cwd sessions run in, so the global file turns up here too. It answers
    # to a byte ceiling checked before any rate, and it is asserted above under a payload that
    # clears its gate without reaching that ceiling.
    [ "$project/$name" = "$HOME/.claude/CLAUDE.md" ] && continue
    [ -n "$global_real" ] && [ "$(realpath "$project/$name" 2>/dev/null)" = "$global_real" ] && continue
    priced "$project/$name" "auto-loaded in every session under $project" \
      "$BIG_BYTES" "$BIG" live
  done
done < <(jq -r '.projects // {} | keys[]' "$RATES" 2>/dev/null)

echo "== every memory index"
# They live at projects/<encoded-cwd>/memory/MEMORY.md — three levels down, not two. At maxdepth 2
# this loop matched nothing at all and reported a whole class as checked while asserting zero.
# The live index is demanded only where it can answer: the export names the projects that ran
# sessions in the window, and an index belonging to one of those must be priced from it. A project
# that has been idle for a month is asked for the denial alone — its class constant is a guess, and
# the check says so here rather than pretending the guess is a measurement.
measured_slugs=$(jq -r '.projects // {} | keys[] | gsub("[^A-Za-z0-9]"; "-")' "$RATES" 2>/dev/null)
while IFS= read -r memory; do
  [ -f "$memory" ] || continue
  slug=${memory%/memory/MEMORY.md}
  slug=${slug##*/}
  need=''
  case "$_instruction_nl$measured_slugs$_instruction_nl" in
    *"$_instruction_nl$slug$_instruction_nl"*) need=live ;;
  esac
  priced "$memory" "read in every session of its project" "$BIG_BYTES" "$BIG" "$need"
done < <(find "$HOME/.claude/projects" "$HOME"/.claude-profiles/*/projects \
           -maxdepth 3 -name MEMORY.md 2>/dev/null)

echo "== every memory file beside an index"
# The one class no measurement can reach: a recall hands over the memory's text and never its path,
# so the index holds an entry only for the files somebody happened to open by hand. Those entries
# are real but tiny, and letting one price the file gates a memory nobody opened all month as free
# — which is why the class constant wins here and the check refuses the live index.
while IFS= read -r memory; do
  [ -f "$memory" ] || continue
  case "$memory" in */MEMORY.md) continue ;; esac
  asserts=$((asserts + 1))
  n=$((n + 1))
  reason=$(verdict "$memory" "$BIG" "$n" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  case "$reason" in
    '') report "$memory" "recalled into its project's sessions, so growth is priced" \
          "$BIG_BYTES bytes of growth met no decision at all" ;;
    *"$LIVE"*) report "$memory" "a hand-opened copy is not how a memory file is loaded" \
          "priced from the index, which cannot see a recall: $reason" ;;
  esac
done < <(find "$HOME/.claude/projects" "$HOME"/.claude-profiles/*/projects \
           -maxdepth 3 -path '*/memory/*.md' 2>/dev/null)

echo "== every guarded document, agent brief and skill"
# No `live` here: an on-demand document the index has genuinely never recorded is priced by its
# class constant, and that is the correct answer, not a hole.
while IFS= read -r doc; do
  priced "$doc" "the write gate refuses shell writes to it, so the bloat gate must price it" \
    "$BIG_BYTES" "$BIG"
done < <(instruction_visible_paths "$HOME" | grep '\.md$')

echo "== a neighbour of an instruction file is not charged its rate"
# A settings.json beside a measured CLAUDE.md is not re-read into any prefix. Quoting it the
# project's rate states a cost that was never paid, which is the same lie in the other direction.
silent "$HOME/.claude/settings.json" "not markdown and not always-on content"
while IFS= read -r project; do
  [ -f "$project/CLAUDE.md" ] || continue
  silent "$project/package.json" "an ordinary file beside an instruction file"
  break
done < <(jq -r '.projects // {} | keys[]' "$RATES" 2>/dev/null)

if [ "$failures" -gt 0 ]; then
  printf '\nFAILED: %d of %d live-corpus checks\n' "$failures" "$asserts" >&2
  exit 1
fi
printf 'OK (%d live-corpus assertions against %s)\n' "$asserts" "$RATES"
