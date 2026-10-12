# Hand-off: the word journal's 1.5 s wait still loses a reading written before the stop

Status: open — To: next night (claude-setup)

words:1791756162/233cceb1 (Updater doctor, turn 312): `⚡ нет: review` has transcript timestamp
22:02:40.828Z; notice-word-journal.sh ran 40.950-42.769 (hook-time spool), polled the full
WORDS_FLUSH_WAIT and journaled `model: []`. The final file answers it (replayed `readings()` finds
the line in 1 ms), so the line landed on disk after the stop. No later stop of that turn ran
`settle()`, so the row stays a miss. claude-setup@7942406b's wait is too short and costs the stop
1.5 s on every unanswered notice.

Fix in claude-setup `hooks/lib/words_journal.py`: a row written with `model: []` hands the row to a
detached re-check that calls `settle()` on the transcript tail for up to ~30 s. Then drop the
synchronous wait. Test in `tests/test_words_log.sh`, red on the old code: a reading appended 3 s
after the stop gets the `late reading` ok mark. Ledger row `word-miss-reading-flushed-after-stop`.
