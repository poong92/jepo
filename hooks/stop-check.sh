#!/bin/bash
# JEPO Stop Hook
# Checks for uncommitted changes and pending sync on task completion
# Event: Stop

INPUT=$(cat)
CWD=$(pwd)
WARNINGS=""

# Check uncommitted changes in git repos
if [ -d "$CWD/.git" ]; then
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$UNCOMMITTED" -gt 0 ]; then
        WARNINGS="${WARNINGS}$UNCOMMITTED uncommitted changes. "
    fi
fi

# Check pending sync (cross-session sync)
SYNC_FILE="$HOME/.claude/session-sync/pending.json"
if [ -f "$SYNC_FILE" ]; then
    if command -v jq &>/dev/null; then
        SYNCED=$(jq -r 'if .synced == false then "false" else "true" end' "$SYNC_FILE" 2>/dev/null)
        if [ "$SYNCED" = "false" ]; then
            WARNINGS="${WARNINGS}Pending session sync not completed. "
        fi
    fi
fi

if [ -n "$WARNINGS" ]; then
    echo "{\"stopReason\": \"[JEPO] ${WARNINGS}\"}"
fi

exit 0
