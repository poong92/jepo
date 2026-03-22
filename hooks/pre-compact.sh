#!/bin/bash
# JEPO PreCompact Hook
# Reminds Claude to save work state before context compaction
# Event: PreCompact

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$HOME/logs/jepo"
mkdir -p "$LOG_DIR"

echo "[$TIMESTAMP] PRE-COMPACT triggered" >> "$LOG_DIR/compact-events.log"

# Remind Claude to save state before compaction
echo '{"additionalContext":"[JEPO] Compaction imminent. Save key conclusions/progress to memory/ folder as .md files if needed. Context will be compressed after this."}'

exit 0
