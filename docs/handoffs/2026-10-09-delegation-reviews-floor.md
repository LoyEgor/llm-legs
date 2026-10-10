# Hand-off: dismiss opportunity:delegation/reviews

Status: settled 20261010T031219Z-4c4e: dismissed not-a-bug, the wait is reviewer model time Speed never trades; its non-model parts are ~1 s a review and the relay is cut (ee185fa8); blind spot delegation-model-time keeps the measure gap

Row `speed-delegation-reviews` in `share/harness-ledger.json` holds the measurement. The attended review
wait is the reviewers' model time; its non-model parts are the 2 s panel poll (~1 s/review) and no
slot queue. The review-waiter relay (~3.5 s/review) went in llm-legs@ee185fa8.

Proposed: dismiss the row, or teach the slice to price only non-model time (blind spot
`delegation-model-time`). Until then each night re-picks it on the generic 30 % lever.
