# Hand-off: the log audit off the night's critical path

Status: settled harness-doctor-20261029T165009Z-7550: bin/night-run PILOT_RULES starts `log-audit run --detach` beside prep, `harness-doctor --quiet` after it (row log_audit:log-audit-serial-at-night-start); the report and Close waits stay in row log_audit:night-run-serial-waits.
