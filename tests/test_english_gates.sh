#!/usr/bin/env bash
# Model-to-model text is English in both directions: the brief a worker is handed, and the result
# it hands back. The measurement itself is `bin/cyrillic-share`.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/worker-run"
SHARE="$ROOT/bin/cyrillic-share"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
asserts=0
fail() { printf 'FAIL(line %s): %s\n' "${BASH_LINENO[1]-${BASH_LINENO[0]-?}}" "$*" >&2; exit 1; }
a() { asserts=$((asserts + 1)); }
eq() { a; [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
has() { a; grep -Fq "$2" <<<"$1" || fail "expected [$2] in [$1]"; }
hasnt() { a; grep -Fq "$2" <<<"$1" && fail "did not expect [$2] in [$1]"; return 0; }

RUSSIAN='Почини гейт: добавь проверку языка и прогони тесты, отчитайся кратко.'
ENGLISH='Fix the gate: add the language check, run the suite, report briefly.'
QUOTING='Egor asked for «максимально автономно», so review, commit and push it yourself.'

# --- 1. the tool -------------------------------------------------------------
a; [ -x "$SHARE" ] || fail "bin/cyrillic-share is not executable"
eq "$(printf '%s' "$RUSSIAN" | "$SHARE" | cut -d' ' -f1)" "100"
eq "$(printf '%s' "$ENGLISH" | "$SHARE" | cut -d' ' -f1)" "0"
eq "$(printf '%s' "$QUOTING" | "$SHARE" | cut -d' ' -f1)" "0"

# --- 2. the brief worker-run is handed --------------------------------------
# The preamble tells the worker who reads it, and it is the FIRST thing said: the rule the reports
# were failing is the one a model must not have to infer from the task.
has "$(sed -n 's/^BRIEF_PREAMBLE=.//p' "$RUNNER")" 'AUDIENCE: your reader is another model'

# Every road to a vendor is closed: an English brief must reach the refusal AFTER this gate without
# any chance of spending a real account on the suite.
start() { # brief-file
  WORKER_RUN_DIR="$WORK/runs" WORKER_RUN_CONFIG_FILE=/dev/null WORKER_PICK_CONFIG_FILE=/dev/null \
    WORKER_RUN_WORKER_PICK=/nonexistent WORKER_RUN_CODEX=/nonexistent \
    "$RUNNER" start codex --brief "$1" --workdir "$WORK" 2>&1
}
printf '%s\n' "$RUSSIAN" >"$WORK/brief-ru"
printf '%s\n' "$ENGLISH" >"$WORK/brief-en"
printf '%s\n' "$QUOTING" >"$WORK/brief-quoting"

out=$(start "$WORK/brief-ru")
has "$out" 'brief is in Russian (100% Cyrillic outside «…»/code)'
has "$out" 'the reader is a model'
start "$WORK/brief-ru" >/dev/null 2>&1
eq "$?" "4"
# Nothing was launched: the refusal comes before a run directory exists.
eq "$(find "$WORK" -name 'meta.json' | wc -l | tr -d ' ')" "0"

# A brief that only QUOTES him passes, or the one legitimate reason to write Cyrillic would be
# gated away.
hasnt "$(start "$WORK/brief-quoting")" 'brief is in Russian'
hasnt "$(start "$WORK/brief-en")" 'brief is in Russian'

# A measurement that cannot run never refuses a launch.
hasnt "$(WORKER_RUN_CYRILLIC_SHARE=/nonexistent start "$WORK/brief-ru")" 'brief is in Russian'

# --- 4. the result a non-Claude vendor hands back ---------------------------
# No Stop hook runs inside a codex or gemini CLI, so the report is stamped where it lands and the
# stamp is read back by `worker-run report` a week later.
stamped_run() { # id result-text
  local directory="$WORK/runs/$1"
  mkdir -p "$directory"
  jq -nc '{vendor:"codex",account:"main",model:"gpt-6-astra",effort:"high",workdir:"'"$WORK"'"}' \
    >"$directory/meta.json"
  printf '%s\n' "$2" >"$directory/result"
  printf '%s' "$directory"
}

directory=$(stamped_run russian 'Готово: гейт добавлен, тесты зелёные.')
WORKER_RUN_DIR="$WORK/runs" "$RUNNER" _deliver "$directory" 0 >"$WORK/deliver.out" 2>&1
eq "$(cat "$directory/lang" 2>/dev/null)" "cyrillic 100"
has "$(cat "$WORK/deliver.out")" 'LANG: cyrillic 100%'

printf '0\n' >"$directory/exit_code"
has "$(WORKER_RUN_DIR="$WORK/runs" "$RUNNER" report russian 2>&1)" 'LANG: cyrillic 100%'

directory=$(stamped_run english 'Done: the gate is in, the suite is green.')
WORKER_RUN_DIR="$WORK/runs" "$RUNNER" _deliver "$directory" 0 >"$WORK/deliver-en.out" 2>&1
a; [ ! -e "$directory/lang" ] || fail "an English result was stamped: $(cat "$directory/lang")"
hasnt "$(cat "$WORK/deliver-en.out")" 'LANG:'
printf '0\n' >"$directory/exit_code"
hasnt "$(WORKER_RUN_DIR="$WORK/runs" "$RUNNER" report english 2>&1)" 'LANG:'

# --- 5. the message a resume timer types into another chat ------------------
TIMER="$ROOT/bin/claude-resume-timer"
# No `hs` on PATH: an English message must reach the Hammerspoon call and die there, or this suite
# would arm a real timer that types into the terminal running it.
timer() { PATH=/usr/bin:/bin RESUME_TIMER_CYRILLIC_SHARE="$SHARE" "$TIMER" terminal 10 -m "$1" 2>&1; }
a; [ -x "$TIMER" ] || fail "bin/claude-resume-timer is not executable"
out=$(timer 'продолжай работу')
has "$out" 'text is in Russian (100% Cyrillic outside «…»/code)'
has "$out" 'its reader is a model'
# The refusal comes before Hammerspoon is reached, so nothing was armed.
timer 'продолжай работу' >/dev/null 2>&1
eq "$?" "2"
hasnt "$(timer 'continue')" 'text is in Russian'
hasnt "$(timer 'Egor asked for «максимально автономно» — keep going')" 'text is in Russian'
hasnt "$(PATH=/usr/bin:/bin RESUME_TIMER_CYRILLIC_SHARE=/nonexistent "$TIMER" terminal 10 -m 'продолжай' 2>&1)" 'text is in Russian'

# Without the environment override the helper is the one in the timer's OWN checkout: an absolute
# path to one particular clone left the gate silently skipped in every other one.
mkdir -p "$WORK/elsewhere/bin"
cp "$TIMER" "$WORK/elsewhere/bin/claude-resume-timer"
printf '#!/bin/sh\nprintf "99 10\\n"\n' >"$WORK/elsewhere/bin/cyrillic-share"
chmod +x "$WORK/elsewhere/bin/cyrillic-share"
has "$(PATH=/usr/bin:/bin "$WORK/elsewhere/bin/claude-resume-timer" terminal 10 -m 'продолжай работу' 2>&1)" '(99% Cyrillic'

echo "PASS: $asserts asserts; cyrillic-share reading a quoted «...» phrase as English — worker-run's preamble opening with who the reader is, its start refusing a Russian brief by name before a run directory exists and passing one that only quotes Egor, an unmeasurable brief never refused — and a non-Claude run's Russian result stamped \`LANG: cyrillic 100%\` where it lands, the stamp surviving into \`worker-run report\`, with an English result stamped not at all — and claude-resume-timer refusing a Russian -m message before Hammerspoon is reached, since whatever it types is read by the model sitting in that chat"
