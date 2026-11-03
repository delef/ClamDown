#!/bin/bash
# Throwaway spike helper: append a Unix timestamp to a log file every 2 seconds.
# A gap larger than ~5 seconds in the log means the Mac slept.
set -euo pipefail

log="${1:?usage: heartbeat.sh <logfile>}"
mkdir -p "$(dirname "$log")"

while true; do
  date +%s >> "$log"
  sleep 2
done
