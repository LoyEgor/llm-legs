# The statusline's background work: the machine-wide snapshots every chat's probes share and the
# journal each background run appends to (docs/statusline-contract.md, "Probe snapshots" and "Probe
# journal"). Sourced by bin/statusline.sh and both probes; needs suite_journal_cpu_ms
# (tests/lib/suite-journal.sh --lib) and, for snapshot_take, cache_dir.

# Header `<epoch>\t<meta>\t<key>`, then the body. A stale or differently keyed snapshot is rebuilt by
# whichever probe asks first; two asking at once both build and the last rename wins.
snapshot_take() { # var name ttl key builder -> var = the snapshot's path, snapshot_at/snapshot_meta its header
  local out=$1 file="$cache_dir/$2" ttl=$3 key=$4 builder=$5 have="" tmp now=${STATUSLINE_NOW:-$EPOCHSECONDS}
  snapshot_at="" snapshot_meta=""
  { IFS=$'\t' read -r snapshot_at snapshot_meta have < "$file"; } 2>/dev/null
  if [[ "$snapshot_at" =~ ^[0-9]+$ ]] && [ "$have" = "$key" ] && [ "$snapshot_at" -le "$now" ] &&
    [ "$((now - snapshot_at))" -le "$ttl" ]; then
    printf -v "$out" '%s' "$file"
    return 0
  fi
  tmp="$file.tmp.$BASHPID"
  if "$builder" "$key" > "$tmp" 2>/dev/null &&
    { IFS=$'\t' read -r snapshot_at snapshot_meta have < "$tmp"; } 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
    printf -v "$out" '%s' "$file"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  snapshot_at="" snapshot_meta=""
  printf -v "$out" ''
  return 1
}

# An empty listing is a failed ps, never an empty machine: it is not published.
snapshot_ps() { # key
  local body
  body=$("${STATUSLINE_PS:-ps}" -axo pid=,ppid=,etime=,command= 2>/dev/null)
  [ -n "$body" ] || return 1
  printf '%s\t-\t%s\n%s\n' "${STATUSLINE_NOW:-$EPOCHSECONDS}" "$1" "$body"
}

# `<start_us>\t<wall_ms>\t<cpu_ms>\t<kind>`: the merge-kick journal's columns plus the kind; cpu_ms is
# this process's own and its waited children's, `-` where bash cannot say.
probe_journal() { # kind start_us
  local end_us=${EPOCHREALTIME//[!0-9]/} dir="${SPEED_DOCTOR_DIR:-$HOME/.cache/speed-doctor}/statusline-probes" day cpu
  suite_journal_cpu_ms cpu ''
  printf -v day '%(%Y-%m-%d)T' -1
  printf '%s\t%s\t%s\t%s\n' "$2" "$(( (end_us - $2) / 1000 ))" "${cpu:--}" "$1" 2>/dev/null >> "$dir/$day.tsv" ||
    { mkdir -p "$dir" 2>/dev/null &&
      printf '%s\t%s\t%s\t%s\n' "$2" "$(( (end_us - $2) / 1000 ))" "${cpu:--}" "$1" 2>/dev/null >> "$dir/$day.tsv"; }
  return 0
}
