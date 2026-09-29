# What the instruction guards decided, and where one of them could not run: one JSON line per event
# in `<watch state>/gates.jsonl`, read by llm-doctor. It needs nothing but bash and printf, because
# the event it exists for most is the one where jq or the big library is missing.
#
# A decision the doctor matches a watched change against: a change no gate priced or passed is a
# write that went around them all. So the record has to outlive the retry stamp it came with.

_gate_journal_str() {
  local v=${1-}
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//[[:cntrl:]]/ }
  printf '"%s"' "$v"
}

gate_journal() { # gate decision session file [delta] [detail]
  local dir journal delta=${5:-} real=''
  [ -n "${HOME:-}" ] || return 0
  dir=${INSTRUCTION_WATCH_STATE:-$HOME/.cache/claude-instruction-watch}
  journal=$dir/gates.jsonl
  mkdir -p "$dir" 2>/dev/null || return 0
  case "$delta" in ''|*[!0-9-]*|-) delta=null ;; esac
  [ -z "${4:-}" ] || real=$(realpath "$4" 2>/dev/null) || real=''
  printf '{"at":%s,"gate":%s,"decision":%s,"sid":%s,"file":%s,"real":%s,"delta":%s,"detail":%s}\n' \
    "$(date +%s)" "$(_gate_journal_str "$1")" "$(_gate_journal_str "$2")" "$(_gate_journal_str "${3:-}")" \
    "$(_gate_journal_str "${4:-}")" "$(_gate_journal_str "$real")" "$delta" \
    "$(_gate_journal_str "${6:-}")" >>"$journal" 2>/dev/null || return 0
  [ $((RANDOM % 64)) -eq 0 ] || return 0
  if [ "$(wc -l <"$journal" 2>/dev/null)" -gt 4000 ] 2>/dev/null; then
    tail -n 2000 "$journal" >"$journal.$$" 2>/dev/null && mv "$journal.$$" "$journal" 2>/dev/null
    rm -f "$journal.$$" 2>/dev/null
  fi
  return 0
}
