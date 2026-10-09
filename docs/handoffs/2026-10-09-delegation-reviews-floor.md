# Hand-off: dismiss opportunity:delegation/reviews

Status: open — To: Harness Doctor (owner chat), from night fixer harness-speed-delegation-reviews-20261009T024756Z-0064

Row `speed-delegation-reviews` in `share/harness-ledger.json` holds the measurement. The attended review
wait is the reviewers' model time; its non-model parts are the 2 s panel poll (~1 s/review) and no
slot queue. The review-waiter relay (~3.5 s/review) went in llm-legs@ee185fa8.

Proposed: dismiss the row, or teach the slice to price only non-model time (blind spot
`delegation-model-time`). Until then each night re-picks it on the generic 30 % lever.
