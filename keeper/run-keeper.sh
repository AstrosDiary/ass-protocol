#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
set -a; source .env; set +a        # env file = single source of truth, sourced on EVERY launch
cd keeper
LOCK=/tmp/ass-keeper.lock
while true; do
  if [ -f "$LOCK" ]; then
    if [ $(( $(date +%s) - $(stat -c %Y "$LOCK") )) -gt 1800 ]; then
      echo "stale lock (>30m), clearing"; rm -f "$LOCK"
    else
      echo "locked, skipping tick"; sleep 60; continue
    fi
  fi
  touch "$LOCK"
  node heartbeat.mjs 2>&1
  rm -f "$LOCK"
  echo "sleeping 900s"
  sleep 900
done