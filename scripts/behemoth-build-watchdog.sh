#!/bin/bash
# Polls behemoth for the build chain PID. When the chain exits, reads the
# status file written by the chain's EXIT trap and fires a clean telegram.
set -uo pipefail

CHAIN_PID="$1"   # passed from caller — eliminates stale-PID risk
BEHEMOTH=tommaso@100.103.234.2
LOG=/tmp/behemoth-build.log
STATUS=/tmp/behemoth-build.status
TG=~/projects/claude_telegram/bin/claude-tg

while ssh -o ConnectTimeout=10 "$BEHEMOTH" "kill -0 $CHAIN_PID 2>/dev/null"; do
  sleep 60
done

# Read the status file the chain wrote on exit.
STAT=$(ssh -o ConnectTimeout=10 "$BEHEMOTH" "cat $STATUS 2>/dev/null || echo 'NO-STATUS'")
TAIL=$(ssh -o ConnectTimeout=10 "$BEHEMOTH" "tail -8 $LOG")
HELP=$(ssh -o ConnectTimeout=10 "$BEHEMOTH" "timeout 8 ~/orca-belt-local/bin/orca-slicer --help 2>&1 | head -1 || echo MISSING")

if [[ "$STAT" == OK* ]]; then
  "$TG" notify "OrcaBelt behemoth build SUCCESS. Help-test: $HELP. Binary: ~/orca-belt-local/bin/orca-slicer (behemoth). Tail: $TAIL" -l done -t "OrcaBelt Ready"
else
  ERR=$(echo "$TAIL" | grep -E 'error:|CMake Error|FAILED:|undefined' | head -3 | tr '\n' '|')
  "$TG" notify "OrcaBelt behemoth build FAIL ($STAT). Errors: ${ERR:-none-greppable}. ssh tommaso@100.103.234.2 tail -50 $LOG" -l error -t "OrcaBelt Build FAIL"
fi
echo "$(date) — status=$STAT" >> /tmp/behemoth-watchdog.log
