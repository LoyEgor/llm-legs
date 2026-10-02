#!/usr/bin/env bash
for round in 1 2 3; do
  bash bin/alpha-run b /dev/null >/dev/null
  sleep 100
done
echo ok
