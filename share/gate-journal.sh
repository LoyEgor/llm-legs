# What the instruction guards decided, and where one of them could not run: one JSON line per event
# in `<watch state>/gates.jsonl`, read by harness-doctor. It needs nothing but bash and printf, because
# the event it exists for most is the one where jq or the big library is missing.
#
# A decision the doctor matches a watched change against: a change no gate priced or passed is a
# write that went around them all. So the record has to outlive the retry stamp it came with.

_gate_journal_str() { # out-var value: no subshell per field
  local _v=${2-}
  _v=${_v//\\/\\\\}
  _v=${_v//\"/\\\"}
  _v=${_v//[[:cntrl:]]/ }
  printf -v "$1" '"%s"' "$_v"
}

gate_journal() { # gate decision session file [delta] [detail]
  local dir journal delta=${5:-} real='' rows oldest j_gate j_decision j_sid j_file j_real j_detail
  [ -n "${HOME:-}" ] || return 0
  dir=${INSTRUCTION_WATCH_STATE:-$HOME/.cache/claude-instruction-watch}
  journal=$dir/gates.jsonl
  mkdir -p "$dir" 2>/dev/null || return 0
  case "$delta" in ''|*[!0-9-]*|-) delta=null ;; esac
  [ -z "${4:-}" ] || real=$(realpath "$4" 2>/dev/null) || real=''
  _gate_journal_str j_gate "$1"; _gate_journal_str j_decision "$2"; _gate_journal_str j_sid "${3:-}"
  _gate_journal_str j_file "${4:-}"; _gate_journal_str j_real "$real"; _gate_journal_str j_detail "${6:-}"
  printf '{"at":%s,"gate":%s,"decision":%s,"sid":%s,"file":%s,"real":%s,"delta":%s,"detail":%s}\n' \
    "$(date +%s)" "$j_gate" "$j_decision" "$j_sid" "$j_file" "$j_real" "$delta" \
    "$j_detail" >>"$journal" 2>/dev/null || return 0
  [ $((RANDOM % 64)) -eq 0 ] || return 0
  rows=$(wc -l <"$journal" 2>/dev/null) || rows=0
  if [ "${rows// /}" -gt 4000 ] 2>/dev/null; then
    oldest=$(head -c 24 "$journal" 2>/dev/null) && oldest=${oldest#*\"at\":} && oldest=${oldest%%,*}
    tail -n 2000 "$journal" >"$journal.$$" 2>/dev/null && mv "$journal.$$" "$journal" 2>/dev/null &&
      { . "${BASH_SOURCE[0]%/*}/limit-hit.sh" 2>/dev/null &&
        limit_hit gate-journal.trim 4000 rows trim "$((${rows// /} - 2000)) gate decisions, the oldest from ${oldest:-?}" \
          'share/gate-journal.sh:-gt 4000' "${rows// /}"; }
    rm -f "$journal.$$" 2>/dev/null
  fi
  return 0
}
