#!/usr/bin/env bash
# Hermetic tests for bin/chat-find against a fixture corpus. The point of the tool
# is that it answers with the LAST REAL MESSAGE and a verbatim quote, so those are
# what the assertions pin — plus every way a match can be a lie: tool output that
# merely mentions the word, a subagent that said it, machinery text, and a file
# whose mtime says today while nothing was said for weeks.
#
# TZ is fixed: the fixture timestamps are UTC and the tool prints local time, so a
# floating zone would move the dates the assertions match. Dates sit far in the
# past so --days comparisons do not depend on when the suite runs.
set -u
export TZ=UTC

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/bin/chat-find"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

asserts=0
fail() { echo "FAIL: $*" >&2; exit 1; }
assert() { asserts=$((asserts + 1)); "$@" || fail "assert $asserts failed: $*"; }

CORPUS="$WORK/projects/-tmp-proj"
mkdir -p "$CORPUS"

# emit <file> <python-dict-literal> [compact|spaced] — appends one transcript line.
# Claude Code writes compact JSON; "spaced" proves the byte prefilter does not
# depend on that, since a transcript is only ever as regular as its writer.
emit() {
  local file=$1 expr=$2 style=${3:-compact}
  python3 -c "
import json, sys
sep = (',', ':') if sys.argv[2] == 'compact' else None
print(json.dumps(eval(sys.argv[1]), ensure_ascii=False, separators=sep))
" "$expr" "$style" >> "$file"
}

said() {  # said <file> <ts> <role> <text> [style]
  local file=$1 ts=$2 role=$3 text=$4 style=${5:-compact}
  if [ "$role" = user ]; then
    emit "$file" "{'type':'user','cwd':'/tmp/proj','timestamp':'$ts','message':{'role':'user','content':'''$text'''}}" "$style"
  else
    emit "$file" "{'type':'assistant','cwd':'/tmp/proj','timestamp':'$ts','message':{'role':'assistant','content':[{'type':'text','text':'''$text'''}]}}" "$style"
  fi
}

# The chat he is looking for. It went quiet on Jan 20 and ends with a huge tool
# result — the shape that used to hide the last spoken line from the tail scan.
REAL="$CORPUS/11111111-1111-1111-1111-111111111111.jsonl"
said "$REAL" 2026-01-20T09:00:00.000Z user 'почему оверлей моргает при подключении'
said "$REAL" 2026-01-20T09:01:00.000Z assistant 'смотрю логи оверлея'
said "$REAL" 2026-01-20T09:02:00.000Z user 'ок, оставим так'
python3 -c "
import json
print(json.dumps({'type':'user','cwd':'/tmp/proj','timestamp':'2026-01-20T09:03:00.000Z',
                  'message':{'role':'user','content':[{'type':'tool_result','content':'x' * 900000}]}},
                 separators=(',', ':')))" >> "$REAL"
# ...and it was opened again today without a word being said: the false visit that
# makes file mtime useless as an indicator.
touch "$REAL"

# A prompt with a screenshot attached: the text arrives as blocks, and it is speech.
BLOCKS="$CORPUS/44444444-4444-4444-4444-444444444444.jsonl"
emit "$BLOCKS" "{'type':'user','cwd':'/tmp/proj','timestamp':'2026-01-18T08:00:00.000Z','message':{'role':'user','content':[{'type':'image','source':{'type':'base64','data':'AAAA'}},{'type':'text','text':'вот скриншот, оверлей съезжает'}]}}"

# Only tool output ever saw the word — a file the chat happened to read.
TOOL="$CORPUS/22222222-2222-2222-2222-222222222222.jsonl"
emit "$TOOL" "{'type':'user','cwd':'/tmp/proj','timestamp':'2026-01-25T10:00:00.000Z','message':{'role':'user','content':[{'type':'tool_result','content':'local x = require(\"оверлей\")'}]}}"
said "$TOOL" 2026-01-25T10:01:00.000Z user 'спасибо'

# Only a subagent said it.
SIDE="$CORPUS/33333333-3333-3333-3333-333333333333.jsonl"
emit "$SIDE" "{'type':'user','isSidechain':True,'cwd':'/tmp/proj','timestamp':'2026-01-26T10:00:00.000Z','message':{'role':'user','content':'проверь оверлей и вернись с отчётом'}}"
said "$SIDE" 2026-01-26T10:01:00.000Z user 'готово?'

# Machinery, not speech: a slash command echoed into the transcript. Written with
# spaces after the colons, which also exercises the encoder-agnostic prefilter.
MACH="$CORPUS/55555555-5555-5555-5555-555555555555.jsonl"
said "$MACH" 2026-01-27T10:00:00.000Z user '<command-name>/оверлей</command-name>' spaced
said "$MACH" 2026-01-27T10:01:00.000Z user 'дальше' spaced

# Said it three times, but weeks earlier: relevance must not lift it above a
# newer chat now that the list reads as a timeline.
OLDLOUD="$CORPUS/66666666-6666-6666-6666-666666666666.jsonl"
said "$OLDLOUD" 2026-01-05T10:00:00.000Z user 'оверлей падает'
said "$OLDLOUD" 2026-01-05T10:01:00.000Z user 'оверлей всё ещё падает'
said "$OLDLOUD" 2026-01-05T10:02:00.000Z user 'оверлей починили'

# A chat he named himself, after the model had guessed a name and after an
# earlier name of his own: the last custom name is the one he sees.
NAMED="$CORPUS/77777777-7777-7777-7777-777777777777.jsonl"
said "$NAMED" 2026-01-19T10:00:00.000Z user 'оверлей и тени хедера'
emit "$NAMED" "{'type':'ai-title','aiTitle':'Guessed overlay name','sessionId':'77777777-7777-7777-7777-777777777777'}"
emit "$NAMED" "{'type':'custom-title','customTitle':'Оверлей: черновое имя','sessionId':'77777777-7777-7777-7777-777777777777'}"
emit "$NAMED" "{'type':'custom-title','customTitle':'Оверлей: финальное имя','sessionId':'77777777-7777-7777-7777-777777777777'}"

# Only the model ever named this one.
AINAMED="$CORPUS/88888888-8888-8888-8888-888888888888.jsonl"
said "$AINAMED" 2026-01-17T10:00:00.000Z user 'оверлей мигает на старте'
emit "$AINAMED" "{'type':'ai-title','aiTitle':'Machine guess about гадание','sessionId':'88888888-8888-8888-8888-888888888888'}"

# Speech whose line carries the name-event marker in a sibling field: the byte
# prefilter cannot tell it from a name event, but the entry is a message. Text
# quoting the marker would not do — a JSON encoder escapes those quotes away.
QUOTED="$CORPUS/99999999-9999-9999-9999-999999999999.jsonl"
emit "$QUOTED" "{'type':'user','cwd':'/tmp/proj','timestamp':'2026-01-16T10:00:00.000Z','toolUseResult':{'type':'custom-title'},'message':{'role':'user','content':'событие должно парситься как речь'}}"

run() { OUT=$("$SCRIPT" --account acct --root "$WORK/projects" "$@" 2>&1); RC=$?; }

# --- the spoken match wins and carries its real date ------------------------
run оверлей
assert test "$RC" -eq 0
assert grep -q 'LAST 2026-01-20 09:02' <<<"$OUT"
assert grep -q "resume:      cd '/tmp/proj' && claudeb profile acct --resume 11111111-1111-1111-1111-111111111111" <<<"$OUT"
# his own words, quoted back, not a paraphrase
assert grep -q 'почему оверлей моргает' <<<"$OUT"
assert grep -q 'opened with: почему оверлей моргает' <<<"$OUT"

# --- a false visit must not pass for a fresh conversation -------------------
assert test -z "$(grep -o "LAST $(date +%Y-%m-%d)" <<<"$OUT")"

# --- a prompt whose text came in blocks is findable -------------------------
assert grep -q '4444-4444' <<<"$OUT"
assert grep -q 'вот скриншот, оверлей съезжает' <<<"$OUT"

# --- the list is a strict timeline of last real messages ---------------------
DATES=$(grep -o 'LAST [0-9-]* [0-9:]*' <<<"$OUT")
assert test "$DATES" = "$(sort -r <<<"$DATES")"
assert test "$(grep -c 'LAST ' <<<"$OUT")" -gt 2
# three hits weeks ago rank below one hit yesterday
assert test "$(grep -n '6666-6666' <<<"$OUT" | cut -d: -f1)" \
  -gt "$(grep -n '4444-4444' <<<"$OUT" | cut -d: -f1)"

# --- the name he gave a chat is printed, last custom name winning ------------
assert grep -q 'name:        Оверлей: финальное имя' <<<"$OUT"
assert test -z "$(grep -o 'черновое имя' <<<"$OUT")"
assert test -z "$(grep -o 'name:        Guessed overlay name' <<<"$OUT")"
# with no name of his own, the model's guess is what there is
assert grep -q 'name:        Machine guess about' <<<"$OUT"
# an unnamed chat gets no name line at all
assert test "$(grep -c 'name:        ' <<<"$OUT")" -eq 2

# --- a name he typed is searchable; a machine guess never stands alone -------
run финальное
assert grep -q '7777-7777' <<<"$OUT"
# nothing was said about it, so nothing is quoted and no hit is invented
assert grep -q '· name match ·' <<<"$OUT"
assert test -z "$(grep -o 'said:' <<<"$OUT")"
assert test -z "$(grep -o '1 hit' <<<"$OUT")"
# the rest of the block still identifies the chat
assert grep -q 'name:        Оверлей: финальное имя' <<<"$OUT"
assert grep -q 'opened with: оверлей и тени хедера' <<<"$OUT"
assert grep -q 'resume:      cd ' <<<"$OUT"
run гадание
assert grep -q 'no chat matched' <<<"$OUT"

# --- a message quoting a name-event marker is still conversation -------------
run парситься
assert grep -q '9999-9999' <<<"$OUT"
assert grep -q 'said:        событие' <<<"$OUT"

run оверлей

# --- tool output, subagents and machinery are not conversation --------------
assert test -z "$(grep -o '2222-2222' <<<"$OUT")"
assert test -z "$(grep -o '3333-3333' <<<"$OUT")"
assert test -z "$(grep -o '5555-5555' <<<"$OUT")"

# --all widens to what tools printed
run --all оверлей
assert grep -q '2222-2222' <<<"$OUT"

# --- nothing found says so, and says how to widen ---------------------------
run абракадабра
assert test "$RC" -eq 0
assert grep -q 'no chat matched' <<<"$OUT"
assert grep -q -- '--all' <<<"$OUT"

# --- --days cuts by the last real message, not by mtime ---------------------
run --days 1 оверлей
assert grep -q 'no chat matched' <<<"$OUT"
# 0 is a real bound, not a missing one
run --days 0 оверлей
assert grep -q 'no chat matched' <<<"$OUT"

# --- no usable profile falls back to a runnable command --------------------
# "main" is not a claudeb profile, so `claudeb profile main` would be refused.
OUT=$(env -u CLAUDE_LIMITS_ACCOUNT HOME="$(mktemp -d)" "$SCRIPT" --root "$WORK/projects" оверлей 2>&1)
assert grep -q 'claude --resume 11111111' <<<"$OUT"
assert test -z "$(grep -o 'profile main' <<<"$OUT")"

# --- listing mode: the same timeline, with no term to search for -------------
# A headless run — a worker or a review bench. Hundreds of these are written for
# every chat he actually sat in, and the listing is useless if they show up.
HEADLESS="$CORPUS/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl"
emit "$HEADLESS" "{'type':'user','cwd':'/tmp/proj','entrypoint':'sdk-cli','timestamp':'2026-01-28T10:00:00.000Z','message':{'role':'user','content':'review this diff'}}"

# A chat that ends the way a live one does: an assistant turn carrying the model
# and its usage, then a client-side notice that nobody said.
RICH="$CORPUS/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl"
emit "$RICH" "{'type':'user','cwd':'/tmp/proj','gitBranch':'main','entrypoint':'cli','timestamp':'2026-01-29T10:00:00.000Z','message':{'role':'user','content':'починим хедер?'}}"
emit "$RICH" "{'type':'assistant','cwd':'/tmp/proj','gitBranch':'main','entrypoint':'cli','timestamp':'2026-01-29T10:01:00.000Z','message':{'role':'assistant','model':'claude-opus-5','usage':{'input_tokens':1000,'cache_read_input_tokens':40000,'cache_creation_input_tokens':1000},'content':[{'type':'text','text':'готово, хедер держится'}]}}"
emit "$RICH" "{'type':'assistant','cwd':'/tmp/proj','entrypoint':'cli','timestamp':'2026-02-10T09:00:00.000Z','message':{'role':'assistant','model':'<synthetic>','usage':{'input_tokens':1},'content':[{'type':'text','text':'Login expired · Please run /login'}]}}"

# What /clear leaves behind: a transcript holding nothing but the command that
# opened it. A third of the corpus looks like this.
STUB="$CORPUS/cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl"
said "$STUB" 2026-01-30T10:00:00.000Z user '<command-name>/clear</command-name>'

recent() { OUT=$("$SCRIPT" --root "$WORK/projects" --cache "$WORK/cache.json" --recent "$@" 2>&1); RC=$?; }

recent
assert test "$RC" -eq 0
# every chat that spoke is listed, ordered by its last real message
assert grep -q 'bbbb-bbbb' <<<"$OUT"
assert grep -q '1111-1111' <<<"$OUT"
DATES=$(grep -o '^2026-[0-9-]* [0-9:]*' <<<"$OUT")
assert test "$DATES" = "$(sort -r <<<"$DATES")"
# the false visit still cannot pass for a fresh conversation
assert test -z "$(grep -o "^$(date +%Y-%m-%d)" <<<"$OUT")"
# a /clear stub never held a message, so it is not a chat
assert test -z "$(grep -o 'cccc-cccc' <<<"$OUT")"
# headless runs stay out until asked for
assert test -z "$(grep -o 'aaaa-aaaa' <<<"$OUT")"
recent --agents
assert grep -q 'aaaa-aaaa' <<<"$OUT"

# --- a client-side notice dates nothing and names no model -------------------
recent --json
assert test "$(python3 -c "
import json, sys
row = [r for r in json.load(sys.stdin) if r['session'].startswith('bbbb')][0]
print(row['model'], row['ctx'], row['branch'], row['cwd'], row['at'] < 1770000000)
" <<<"$OUT")" = "claude-opus-5 42000 main /tmp/proj True"
assert test -z "$(grep -o 'Login expired' <<<"$OUT")"

# --- the cache answers with the same list, and yields to a new message -------
assert test -f "$WORK/cache.json"
FIRST="$OUT"
recent --json
assert test "$OUT" = "$FIRST"
said "$RICH" 2026-02-11T10:00:00.000Z user 'ещё одна правка'
recent
assert grep -q '2026-02-11 10:00' <<<"$OUT"

# --- listing and searching are separate askings ------------------------------
recent оверлей
assert test "$RC" -ne 0
assert grep -q 'takes no search terms' <<<"$OUT"
OUT=$("$SCRIPT" --root "$WORK/projects" 2>&1); RC=$?
assert test "$RC" -ne 0
assert grep -q -- '--recent' <<<"$OUT"

echo "PASS: chat-find ($asserts assertions)"
