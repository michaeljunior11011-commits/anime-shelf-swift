#!/usr/bin/env bash

set -Eeuo pipefail

SESSION_MINUTES="${SESSION_MINUTES:-120}"

if ! [[ "$SESSION_MINUTES" =~ ^[0-9]+$ ]] || (( SESSION_MINUTES < 10 || SESSION_MINUTES > 340 )); then
  echo "::error::Session length must be between 10 and 340 minutes."
  exit 1
fi

WEBSOCKIFY_PID="$(cat "$RUNNER_TEMP/websockify.pid")"
CLOUDFLARED_PID="$(cat "$RUNNER_TEMP/cloudflared.pid")"
END_TIME=$(( $(date +%s) + SESSION_MINUTES * 60 ))

echo "The remote macOS session will stay available for $SESSION_MINUTES minutes."
echo "Cancel the workflow from GitHub Actions when you finish."

while (( $(date +%s) < END_TIME )); do
  if ! kill -0 "$WEBSOCKIFY_PID" 2>/dev/null; then
    cat "$RUNNER_TEMP/websockify.log" || true
    echo "::error::The browser VNC bridge stopped unexpectedly."
    exit 1
  fi

  if ! kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
    cat "$RUNNER_TEMP/cloudflared.log" || true
    echo "::error::The secure tunnel stopped unexpectedly."
    exit 1
  fi

  echo "Remote macOS session active — $(date '+%H:%M:%S')"
  sleep 60
done

echo "Session time completed. The temporary macOS runner will now be removed."
