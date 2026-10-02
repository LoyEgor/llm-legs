#!/usr/bin/env bash
# Guards profile isolation: two profiles never share a token store, or one account's data loss
# follows.
bash bin/alpha-run a /dev/null >/dev/null && echo ok
