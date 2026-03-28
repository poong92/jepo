#!/bin/bash
# Auth keepalive - periodically verifies Claude CLI authentication
# Schedule: every 4 hours via LaunchAgent
#
# Security: No tools invoked beyond a simple auth probe.
# Exit codes: 0 = success, 1 = auth failure (Telegram alert sent)

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "auth-keepalive"

LOGFILE="$LOG_DIR/auth-keepalive.log"
rotate_log "$LOGFILE"

echo "$(date): Auth check started" >> "$LOGFILE"

if check_auth; then
    echo "$(date): AUTH_OK" >> "$LOGFILE"
else
    echo "$(date): AUTH_FAILED" >> "$LOGFILE"
    exit 1
fi
