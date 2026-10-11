#!/bin/bash
# Wait up to $1 seconds (default 60) while the app runs, then print interesting log lines.
L=$(find "$(xcrun simctl get_app_container booted org.angelauramc.amethyst data)" -name latestlog.txt)
for i in $(seq 1 ${1:-60}); do
  xcrun simctl spawn booted launchctl list 2>/dev/null | grep -q amethyst || { echo "== APP EXITED after ${i}s"; break; }
  sleep 1
done
grep -nE "INFO|WARN|ERROR|Exception|Caused by|Error|SIG|fatal" "$L" | grep -v ParseJSON | tail -${2:-40}
