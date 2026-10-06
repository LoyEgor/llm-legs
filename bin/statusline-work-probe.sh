#!/usr/bin/env bash
# Shell work of one session, for the statusline's work lines and the `tests` field of its worker
# rows — docs/statusline-contract.md, "Work lines". Fired from the render; writes the cache the
# render and bin/subagent-statusline.sh read.
# `env bash` resolves to macOS bash 3.2 when PATH lists /bin before Homebrew; this script needs bash 5.
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  for modern_bash in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$modern_bash" ] && "$modern_bash" -c '[ "${BASH_VERSINFO[0]}" -ge 5 ]' && exec "$modern_bash" "$0" "$@"
  done
  echo "statusline-work-probe: bash 5 required (found $BASH_VERSION)" >&2
  exit 1
fi
{
set -u

session_id="${1:-}"
start_pid="${2:-$PPID}"
session_id=${session_id//[^A-Za-z0-9_-]/}
[ -n "$session_id" ] || exit 0
probe_start_us=${EPOCHREALTIME//[!0-9]/}

cache_dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/claude-statusline}"
cache_file="$cache_dir/work-$session_id"
lock="$cache_file.lock"
runs_root="${WORKER_RUN_DIR:-$HOME/.cache/claude-worker-runs}"
tags_dir="$HOME/.cache/claude-worker-tags/$session_id"
PS_CMD="${STATUSLINE_PS:-ps}"
LSOF_CMD="${STATUSLINE_LSOF:-lsof}"

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
enable -f "${BASH%/bin/*}/lib/bash/rmdir" rmdir 2>/dev/null
if ! { enable -f "${BASH%/bin/*}/lib/bash/realpath" realpath 2>/dev/null &&
  realpath -a probe_self "${BASH_SOURCE[0]}" >/dev/null 2>&1; }; then
  probe_self=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null) || probe_self="${BASH_SOURCE[0]}"
fi
. "${probe_self%/*}/../share/test-scope.sh"
. "${probe_self%/*}/../tests/lib/suite-journal.sh" --lib
. "${probe_self%/*}/../share/statusline-probe.sh"

[ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null || exit 0
if ! mkdir "$lock" 2>/dev/null; then
  now=$EPOCHSECONDS; m=$(file_mtime "$lock" 2>/dev/null)
  # Under the render's 15s cut, so a probe killed holding the lock blanks no line; one runs in well under 1s.
  if [[ "${now:-}" =~ ^[0-9]+$ ]] && [[ "${m:-}" =~ ^[0-9]+$ ]] && [ "$((now - m))" -gt 12 ]; then
    rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$lock" 2>/dev/null; probe_journal work "$probe_start_us"' EXIT

write_cache() {
  local tmp="$cache_file.tmp.$$"
  printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

snapshot_take ps_snap ps-snapshot 3 "$PS_CMD" snapshot_ps || { write_cache ""; exit 0; }
# Every start is the snapshot's moment minus an etime, so the clock is the snapshot's too.
now=$snapshot_at

# This session's live worker runs, from the rows its task-row cache names: their supervisors are
# setsid'd away from the chat, so ancestry from the chat never reaches their tests.
runs=""
for tag_file in "$tags_dir"/*; do
  [ -f "$tag_file" ] || continue
  run=""
  while IFS= read -r tag_line || [ -n "$tag_line" ]; do
    case "$tag_line" in run=*) run=${tag_line#run=} ;; esac
  done < "$tag_file"
  run=${run//[^a-z0-9-]/}
  [ -n "$run" ] && [ -f "$runs_root/$run/meta.json" ] && [ ! -f "$runs_root/$run/exit_code" ] || continue
  pid=$(jq -r '.pid // 0' "$runs_root/$run/meta.json" 2>/dev/null)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && runs="$runs $run:$pid"
done

found=$(awk -v start="$start_pid" -v runs="$runs" '
  function secs(e,   d, n, p) {
    d = 0
    if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1) + 0; e = substr(e, index(e, "-") + 1) }
    n = split(e, p, ":")
    if (n == 3) return d * 86400 + p[1] * 3600 + p[2] * 60 + p[3]
    if (n == 2) return d * 86400 + p[1] * 60 + p[2]
    return 0
  }
  function base(s,   m, b) { m = split(s, b, "/"); return b[m] }
  # The program a process runs: argv[0], or for an interpreter or launcher the script it was handed
  # (`python3 -m pytest` is pytest). Sets w/nw and pi, the index of the program word. A wrapper
  # option that takes a value skips it too, or `timeout -s KILL 60 x` would run KILL.
  function prog(pid,   b, i) {
    nw = split(cmd[pid], w, /[ \t]+/); pi = 1; b = base(w[1])
    while (b ~ /^(env|nohup|time|timeout|nice|sudo|caffeinate|setsid|uv|poetry|npx|bash|sh|zsh|dash|python[0-9.]*|node|perl|ruby|lua|luajit)$/ && pi < nw) {
      for (i = pi + 1; i <= nw && (w[i] ~ /^-/ || (b == "env" && w[i] ~ /=/)); i++) {
        if (w[i] == "-c" && b ~ /^(bash|sh|zsh|dash|python[0-9.]*|perl|ruby|lua|luajit)$/) return b
        if (w[i] == "-m" && b ~ /^python/ && i < nw) { pi = i + 1; return base(w[pi]) }
        if (w[i] == "--test" && b == "node") return "node --test"
        if ((b == "timeout" && w[i] ~ /^-[sk]$/) || (b == "nice" && w[i] == "-n") || (b == "caffeinate" && w[i] ~ /^-[tw]$/) ||
            (b == "sudo" && w[i] ~ /^-[ugCDhpt]$/) || (b ~ /^(uv|npx)$/ && w[i] ~ /^(--with|--python|-p|--package|--project|--directory|--from)$/)) i++
      }
      if (i <= nw && b == "timeout" && w[i] ~ /^[0-9.]+[smhd]?$/) i++
      if (i <= nw && b ~ /^(uv|poetry)$/ && w[i] == "run") { pi = i; continue }
      if (i > nw) return b
      pi = i; b = base(w[pi])
    }
    return b
  }
  function arg(k,   i, c) {
    c = 0
    for (i = pi + 1; i <= nw; i++) {
      if (w[i] ~ /^(-C|--dir|--prefix|--filter|-F|--workspace|-w|--cwd)$/) { i++; continue }
      if (w[i] ~ /^-/) continue; if (++c == k) return w[i]
    }
    return ""
  }
  function has(x,   i) { for (i = pi + 1; i <= nw; i++) if (w[i] == x) return 1; return 0 }
  # Anchored at the program, never at the command text: `sed -n 1,9p tests/test_x.sh` is no test.
  # Sets tpath to the script a script-run test names, which says its repository better than any cwd.
  function test_label(pid,   p, a1, a2) {
    p = prog(pid); tpath = ""
    if (p ~ /^(run-suites\.sh|run-all)$/) return "suites"
    if (p ~ /^test_[A-Za-z0-9_.-]*\.(sh|bash|py|lua)$/) { tpath = w[pi]; sub(/\.(sh|bash|py|lua)$/, "", p); return p }
    if (p ~ /^(pytest|py\.test|vitest|jest|busted|bats|rspec|phpunit|ctest|unittest|node --test)$/) return p
    a1 = arg(1); a2 = arg(2)
    if (p ~ /^(npm|pnpm|yarn|bun)$/ && (a1 == "test" || a1 == "t" || (a1 == "run" && a2 ~ /^test/))) return p " test"
    if (p ~ /^(go|cargo|swift|mix|dotnet|deno)$/ && (a1 == "test" || a1 == "nextest")) return p " test"
    if (p == "playwright" && a1 == "test") return "playwright"
    if (p ~ /^g?make$/ && has("test")) return "make test"
    if (p ~ /^g?make$/ && has("check")) return "make check"
    if (p == "xcodebuild" && has("test")) return "xcodebuild test"
    return ""
  }
  # The top-most test under pid; 1 when the subtree holds a test or a program that has a row of its own.
  function visit(pid, tag, depth,   lbl, n, a, i, hit) {
    if (depth > 30 || (pid in seen)) return 0
    seen[pid] = 1
    if (tag != "R" && prog(pid) ~ owned) {
      if (tag == "M" && prog(pid) ~ media) print "MEDIA\t" pid "\t" secs(et[pid])
      return 1
    }
    lbl = test_label(pid)
    if (lbl != "") {
      if (tag == "R") print "R\t" run_of_visit "\t" secs(et[pid]) "\t" lbl "\t" pid
      else print tag "\ttests\t" pid "\t" secs(et[pid]) "\t" lbl "\t" tpath
      return 1
    }
    hit = 0
    n = split(kids[pid], a, " ")
    for (i = 1; i <= n; i++) if (visit(a[i], tag, depth + 1)) hit = 1
    return hit
  }
  function orphans(pid, depth,   n, a, i) {
    # A detached panel or worker hands its tests the environment of the chat; its row carries them.
    if (depth > 30 || pid == root || (pid in runpid) || base_of(pid) == "claude" || prog(pid) ~ owned) return
    if (test_label(pid) != "") { visit(pid, "O", 0); return }
    n = split(kids[pid], a, " ")
    for (i = 1; i <= n; i++) orphans(a[i], depth + 1)
  }
  function base_of(pid,   s) { split(cmd[pid], s, /[ \t]+/); return base(s[1]) }
  FNR == 1 { next }
  {
    et[$1] = $3; ppid[$1] = $2
    line = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]+/, "", line); cmd[$1] = line
    kids[$2] = kids[$2] " " $1
  }
  END {
    media = "^(media-run|image-fanout|codex-image|gemini-image|grok-image|grok-video|gemini-video|gemini-music|gemini-sfx|gemini-listen|gemini-speech|elevenlabs-(sfx|music|stems|speech|revoice|isolate|transcribe|align|dub|voice))$"
    owned = "^(worker-run|review-bench|" substr(media, 3)
    pid = start; depth = 0; root = ""
    while (pid != "" && pid + 0 > 1 && depth < 30) {
      if (base_of(pid) == "claude") { root = pid; break }
      pid = ppid[pid]; depth++
    }
    print "ROOT\t" root
    nr = split(runs, rr, " ")
    for (i = 1; i <= nr; i++) { split(rr[i], kv, ":"); runpid[kv[2]] = kv[1] }
    if (root != "") {
      n = split(kids[root], a, " ")
      for (i = 1; i <= n; i++) {
        c = a[i]
        # A Bash tool call, foreground or background: the harness runs each one through its shell
        # snapshot, which a command that execs its program replaces. A hook runs outside one, and
        # one still going at 5s holds the chat the way a tool call does.
        if (cmd[c] !~ /\/shell-snapshots\/snapshot-/) {
          if ((lbl = test_label(c)) != "") { print "M\ttests\t" c "\t" secs(et[c]) "\t" lbl "\t" tpath; continue }
          if (prog(c) ~ media) { print "MEDIA\t" c "\t" secs(et[c]); continue }
          if (w[pi] ~ /\/hooks\/[^\/]+$/ && secs(et[c]) >= 5) {
            lbl = base(w[pi]); sub(/\.[a-z]+$/, "", lbl); print "M\tshell\t" c "\t" secs(et[c]) "\thook " lbl
          }
          continue
        }
        if (visit(c, "M", 0) || secs(et[c]) < 10) continue
        oldest = ""; m = split(kids[c], ka, " ")
        for (j = 1; j <= m; j++) if (oldest == "" || secs(et[ka[j]]) > secs(et[oldest])) oldest = ka[j]
        lbl = ""
        # The word after the program only, and only a plain one: an option operand can be a password.
        if (oldest != "") {
          lbl = prog(oldest)
          if (pi < nw && w[pi + 1] ~ /^[a-z][a-z-]*$/ && length(w[pi + 1]) <= 14) lbl = lbl " " w[pi + 1]
        }
        print "M\tshell\t" c "\t" secs(et[c]) "\t" lbl
      }
    }
    for (p in runpid) if (p in cmd) { run_of_visit = runpid[p]; delete seen; visit(p, "R", 0) }
    delete seen
    n = split(kids[1], a, " ")
    for (i = 1; i <= n; i++) orphans(a[i], 0)
  }' "$ps_snap")

# An orphan test is this session's when the environment it inherited says so: a test backgrounded
# with `&` or nohup is reparented to launchd the moment its shell returns.
orphans=""; root_pid=""
while IFS=$'\t' read -r kind a pid rest; do
  case "$kind" in
    ROOT) root_pid=$a ;;
    O) orphans="${orphans:+$orphans,}$pid" ;;
  esac
done <<< "$found"
mine=""
if [ -n "$orphans" ]; then
  mine=$("$PS_CMD" -E -ww -o pid=,command= -p "$orphans" 2>/dev/null | awk -v sid="$session_id" -v root="${root_pid:-x}" '
    index($0 " ", " CLAUDE_CODE_SESSION_ID=" sid " ") || index($0 " ", " CLAUDE_PID=" root " ") { print $1 }' | paste -sd' ' -)
fi

# pid of the cwd to read, class, elapsed, label, test script — one per main-line work item. Split on
# \037, never on tab: tab is IFS whitespace, so `read` would fold an empty field into the next one.
items=""; pids=""; runs_out=""; media_records=""
while IFS= read -r found_line; do
  IFS=$'\037' read -r kind a b c d e _ <<< "${found_line//$'\t'/$'\037'}"
  case "$kind" in
    MEDIA)
      # media-run's pointer for its own pid, stamped as it started: an older one belongs to a reused pid.
      [ -f "$cache_dir/media-$a" ] || continue
      IFS=$'\037' read -r m_stamp m_tag m_label m_state _ < <(tr '\t' '\037' < "$cache_dir/media-$a")
      [[ "$m_stamp" =~ ^[0-9]+$ ]] && [ "$m_stamp" -ge "$((now - b - 3))" ] && [ -n "$m_tag" ] || continue
      m_counts=$'\t\t'
      [ -z "$m_state" ] || m_counts=$(jq -r '[(.cells // [])[] | .status // "" | select(. != "spare-cancelled")] | "\(map(select(. == "done" or . == "failed")) | length)\t\(map(select(. == "failed")) | length)\t\(length)"' \
        "$m_state" 2>/dev/null) || m_counts=$'\t\t'
      media_records+="main"$'\t'"media"$'\t'"$m_stamp"$'\t'"$m_tag"$'\t'"$m_label"$'\t'"$m_counts"$'\t\t'$'\n' ;;
    M|O)
      [ "$kind" = M ] || [[ " $mine " = *" $b "* ]] || continue
      items+="$b"$'\037'"$a"$'\037'"$c"$'\037'"$d"$'\037'"$e"$'\n'
      pids="${pids:+$pids,}$b" ;;
    R)
      logdir="" srepo="" stamp=""
      [ "$c" != suites ] || [ ! -f "$cache_dir/suites-$d" ] || IFS=$'\t' read -r logdir _ srepo stamp < "$cache_dir/suites-$d" || :
      [ -n "$logdir" ] && [ -d "$logdir" ] && [[ "$stamp" =~ ^[0-9]+$ ]] && [ "$stamp" -ge "$((now - b - 3))" ] || logdir=""
      # A suite run counts from the progress file it writes once it holds a slot; before that it is queued.
      [ "$c" != suites ] || { [ -n "$logdir" ] && b=$((now - stamp)); } || c='suites queued'
      if [ "$c" = suites ] || [ "$c" = 'suites queued' ]; then
        runs_out+="run"$'\t'"$a"$'\t'"$((now - b))"$'\t'"$c"$'\t\t\t\t\t'"$logdir"$'\t'"$srepo"$'\t'"$d"$'\n'
      else
        runs_out+="run"$'\t'"$a"$'\t'"$((now - b))"$'\t'"$c"$'\n'
      fi ;;
  esac
done <<< "$found"
runs_out=${runs_out%$'\n'}

declare -A cwd_by_pid=()
if [ -n "$pids" ]; then
  cwd_pid=""
  while IFS= read -r cwd_line; do
    case "$cwd_line" in
      p*) cwd_pid=${cwd_line#p} ;;
      n*)
        [ -z "$cwd_pid" ] || [ -n "${cwd_by_pid[$cwd_pid]+set}" ] ||
          { cwd_line=${cwd_line#n}; cwd_by_pid[$cwd_pid]=${cwd_line%%$'\t'*}; }
        cwd_pid="" ;;
    esac
  done < <("$LSOF_CMD" -a -d cwd -Fn -p "$pids" 2>/dev/null)
fi

records=""
while IFS=$'\037' read -r pid class elapsed label tpath; do
  [ -n "$pid" ] || continue
  cwd=${cwd_by_pid[$pid]:-}
  done_n=$'\t' total="" srepo="" logdir="" stamp="" outcome_dir=""
  if [ "$label" = suites ] && [ -f "$cache_dir/suites-$pid" ] && IFS=$'\t' read -r logdir total srepo stamp < "$cache_dir/suites-$pid" \
      && [ -d "$logdir" ] && [[ "$total" =~ ^[0-9]+$ ]]; then
    done_n=$(cat "$logdir"/*.status 2>/dev/null | awk -F'\t' '{ n++; if ($1 != 0) f++ } END { print n + 0 "\t" f + 0 }')
    # A runner killed past its EXIT trap leaves its file for the next process to get its pid.
    [[ "$stamp" =~ ^[0-9]+$ ]] && [ "$stamp" -ge "$((now - elapsed - 3))" ] && outcome_dir=$logdir
  else
    total="" srepo=""
  fi
  if [ "$label" = suites ]; then
    if [ -n "$outcome_dir" ]; then elapsed=$((now - stamp)); else label='suites queued' done_n=$'\t' total="" srepo=""; fi
  fi
  # A run started from another repository's directory is that repository's: the script it runs or
  # the one run-suites was handed names it, the cwd only when neither does.
  top="" root=""
  case "$tpath" in
    /*) git_top "${tpath%/*}" ;;
    */*) [ -z "$cwd" ] || git_top "$cwd/${tpath%/*}" ;;
  esac
  [ -n "$top" ] || [ -z "$srepo" ] || git_top "$srepo" || top=$srepo
  [ -n "$top" ] || [ -z "$cwd" ] || git_top "$cwd" || top=$cwd
  repo=""
  case "$top" in
    '') ;;
    */.claude/worktrees/*) repo="⧉ ${top##*/}" ;;
    *) repo=${top##*/} ;;
  esac
  spid=""
  case "$label" in suites*) spid=$'\t'"$pid" ;; esac
  records="${records}main"$'\t'"$class"$'\t'"$((now - elapsed))"$'\t'"$repo"$'\t'"$label"$'\t'"$done_n"$'\t'"$total"$'\t'"$outcome_dir"$'\t'"$root$spid"$'\n'
done <<< "$items"

records+=$media_records
sorted_records=""
[ -z "$records" ] || sorted_records=$(printf '%s' "$records" | sort -t$'\t' -k2,2r -k3,3n)
new_cache="$sorted_records${runs_out:+
$runs_out}"

# A test the last probe saw and this one does not has finished; its time goes to the journal the
# Harness doctor's Tests section reads. A start re-derived from etime drifts by a second, so an item
# still running matches within 3s.
old_cache=""; old_mtime=""
[ ! -r "$cache_file" ] || IFS= read -r -d '' old_cache < "$cache_file" || :
if [[ "$old_cache" = *$'main\ttests\t'* || "$old_cache" = *$'run\t'* ]]; then
  old_mtime=$(file_mtime "$cache_file")
fi
if [[ "$old_mtime" =~ ^[0-9]+$ ]] && [ "$((now - old_mtime))" -le 15 ]; then
  finished=$({ printf 'OLD\n'; printf '%s' "$old_cache"; printf 'NEW\n%s\n' "$new_cache"; } | awk -F'\t' '
    $0 == "OLD" || $0 == "NEW" { side = $0; next }
    side == "NEW" && $11 != "" { npid[$11] = 1 }
    $1 == "main" && $5 == "suites queued" || $1 == "run" && $4 == "suites queued" {
      if (side == "OLD" && $11 != "") { q++; qpid[q] = $11; qline[q] = $0 }
      next
    }
    $1 == "main" && $2 == "tests" { key = "chat\t" $4 "\t" $5 }
    $1 == "run" { key = "worker\t" $2 "\t" $4 }
    $1 != "run" && !($1 == "main" && $2 == "tests") { next }
    side == "OLD" { n++; okey[n] = key; ostart[n] = $3; olog[n] = $9; oline[n] = $0; next }
    { k++; nkey[k] = key; nstart[k] = $3; nlog[k] = $9 }
    END {
      for (i = 1; i <= n; i++) {
        best = 0
        for (j = 1; j <= k; j++) {
          if (used[j] || nkey[j] != okey[i] || (olog[i] != "" && nlog[j] != "" && olog[i] != nlog[j])) continue
          d = nstart[j] - ostart[i]; if (d < 0) d = -d
          if (d <= 3 && (!best || d < bestd)) { best = j; bestd = d }
        }
        if (best) used[best] = 1; else print oline[i]
      }
      for (i = 1; i <= q; i++) if (!(qpid[i] in npid)) print qline[i]
    }')
  if [ -n "$finished" ]; then
    # run-suites and a test sourcing tests/lib/suite-journal.sh journal their own row before they exit.
    declare -A journaled=()
    suite_journal=${RUN_SUITES_JOURNAL:-${XDG_CACHE_HOME:-$HOME/.cache}/run-suites/runs.jsonl}
    if [ -s "$suite_journal" ]; then
      while IFS=$'\t' read -r jkind jid jstart; do journaled[$jkind/$jid]+=" $jstart"; done < <(tail -c 262144 "$suite_journal" 2>/dev/null |
        jq -rR 'fromjson? | select(.started_at | type == "number") | (.started_at | floor) as $t
          | if .kind == "suites" then "suites\t\(.pid)\t\($t)" else .suites | keys[] | "direct\t\(sub("\\.[a-z]+$"; ""))\t\($t)" end' 2>/dev/null)
    fi
    journaled_run() { # kind id start
      local t
      for t in ${journaled[$1/$2]-}; do [ "$((t - $3))" -le 3 ] && [ "$(($3 - t))" -le 3 ] && return 0; done
      return 1
    }
    while IFS=$'\037' read -r kind a start c d e f g h root spid _; do
      # A run seen only queued may have taken its slot and ended between two probes: run-suites leaves
      # its pointer as suites-<pid>.done on exit. A run killed while queued has none and is no run.
      if [ "$d" = 'suites queued' ] || [ "$kind/$c" = 'run/suites queued' ]; then
        h="" srepo="" stamp=""
        [ -f "$cache_dir/suites-$spid.done" ] && IFS=$'\t' read -r h g srepo stamp < "$cache_dir/suites-$spid.done" || :
        [ -n "$h" ] && [[ "$stamp" =~ ^[0-9]+$ ]] && [ "$stamp" -ge "$((start - 3))" ] || continue
        start=$stamp
        if [ "$kind" = run ]; then c=suites root=$srepo
        else
          d=suites
          if [ -z "$c" ] && [ -n "$srepo" ]; then
            top="" root=""
            git_top "$srepo" || top=$srepo
            case "$top" in */.claude/worktrees/*) c="⧉ ${top##*/}" ;; *) c=${top##*/} ;; esac
          fi
        fi
      fi
      if [ "$d" = suites ] || [ "$kind/$c" = run/suites ]; then journaled_run suites "$spid" "$start" && continue
      elif [ "$kind" = run ]; then journaled_run direct "$c" "$start" && continue
      else journaled_run direct "$d" "$start" && continue
      fi
      # A code of 129-192 is a kill by signal (interrupt, memory guard), no verdict on the code under test.
      ok="" times=""
      if { [ "$d" = suites ] || [ "$kind/$c" = run/suites ]; } && [ -n "$h" ] && [ -d "$h" ]; then
        n=0 bad=0 killed=0
        for status in "$h"/*.status; do
          [ -f "$status" ] || continue
          rc="" took=""; IFS=$'\t' read -r rc took _ < "$status" || :
          name=${status##*/}
          [[ ! "$took" =~ ^[0-9]+$ ]] || times+="${name%.status}"$'\t'"$took"$'\n'
          n=$((n + 1))
          if [ "$rc" = 0 ]; then :
          elif [[ "$rc" =~ ^[0-9]{1,3}$ ]] && { [ "$rc" -le 128 ] || [ "$rc" -gt 192 ]; }; then bad=$((bad + 1))
          else killed=$((killed + 1))
          fi
        done
        if [[ "$g" =~ ^[1-9][0-9]*$ ]]; then
          f=$((bad + killed))
          if [ "$bad" -gt 0 ]; then ok=false
          elif [ "$killed" -eq 0 ] && [ "$n" -eq "$g" ]; then ok=true
          fi
        fi
      fi
      suite_secs='if $times == "" then {} else {suite_secs: ($times | rtrimstr("\n") | split("\n")
        | map(split("\t") | {(.[0]): (.[1] | tonumber)}) | add)} end'
      if [ "$kind" = run ]; then
        # A worker's run-all may test another repository than its workdir (ADD-DIR worktrees).
        workdir=$root
        [ -n "$workdir" ] || workdir=$(jq -r '.workdir // empty' "$runs_root/$a/meta.json" 2>/dev/null)
        root=""
        [ -z "$workdir" ] || git_top "$workdir" || :
        jq -cn --argjson end "$now" --argjson start "$start" --arg repo "${workdir##*/}" --arg label "$c" --arg root "$root" \
          --arg times "$times" '{end: $end, secs: ($end - $start), who: "worker", repo: $repo, label: $label}
          + (if $root == "" then {} else {repo_root: $root} end) + ('"$suite_secs"')'
      else
        jq -cn --argjson end "$now" --argjson start "$start" --arg repo "$c" --arg label "$d" --arg done "$e" \
          --arg failed "$f" --arg total "$g" --arg ok "$ok" --arg root "$root" --arg times "$times" '{end: $end, secs: ($end - $start), who: "chat", repo: $repo, label: $label}
          + (if $total == "" then {} else {total: ($total | tonumber), failed: (($failed | tonumber?) // 0)} end)
          + (if $ok == "" then {} else {ok: ($ok == "true")} end)
          + (if $root == "" then {} else {repo_root: $root} end) + ('"$suite_secs"')'
      fi
    done <<< "${finished//$'\t'/$'\037'}" >> "$cache_dir/test-history.jsonl" 2>/dev/null
  fi
fi

write_cache "$new_cache"
exit; }
