#!/bin/bash
# JEPO PostCompact Hook
# Re-injects essential context after compaction
# Event: PostCompact

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$HOME/logs/jepo"
mkdir -p "$LOG_DIR"

SUMMARY=$(echo "$INPUT" | jq -r '.compact_summary // "none"' 2>/dev/null | head -c 500)

echo "[$TIMESTAMP] POST-COMPACT | summary_len=$(echo "$SUMMARY" | wc -c | tr -d ' ')" >> "$LOG_DIR/compact-events.log"

# Re-inject key reminders after compaction
CONFIG_FILE="$HOME/.claude/config.json"
PROD_SERVER=$(jq -r '.prod_server // ""' "$CONFIG_FILE" 2>/dev/null)

SERVER_NOTE=""
if [ -n "$PROD_SERVER" ]; then
    SERVER_NOTE=" Server IP from config.json: $PROD_SERVER."
fi

echo "{\"additionalContext\":\"[JEPO POST-COMPACT] Context compressed. Reminders: (1) Follow CLAUDE.md principles (2)${SERVER_NOTE} (3) MEMORY.md auto-loads -- no separate memory search needed (4) Re-check project CLAUDE.md.\"}"

exit 0
