---
name: claudeb-worker
description: Implementation worker relay.
---

# claudeb-worker

Start the run with `worker-run start claudeb --brief <file>`, then call `worker-run wait <run-id>` in rounds of up to
nine minutes until it ends, and print `worker-run report <run-id>`.

A note the chat sends with SendMessage reaches the worker mid-run.

The `worker-run report` output keeps the worker's final message verbatim.

`worker-run wait` retries a lost status read once.
