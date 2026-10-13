# Hand-off: the word journal's 1.5 s wait still loses a reading written before the stop

Status: settled 20261012T233034Z-3131: claude-setup@7f1eb60c, a detached re-check settles an unanswered row up to 30 s; no sync wait

words:1791756162/233cceb1: `⚡ нет: review` (transcript 22:02:40.828Z); the journal hook ran
40.950-42.769, polled the full WORDS_FLUSH_WAIT, journaled `model: []`; the line landed after the
stop and no later stop ran `settle()`. The wait cost every unanswered notice 1.5 s.

Fix in claude-setup `hooks/lib/words_journal.py`: a row written with `model: []` hands the row to a
detached re-check that calls `settle()` on the transcript tail for up to ~30 s. Then drop the
synchronous wait. Test in `tests/test_words_log.sh`, red on the old code: a reading appended 3 s
after the stop gets the `late reading` ok mark. Ledger row `word-miss-reading-flushed-after-stop`.
