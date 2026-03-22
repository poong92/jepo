#!/bin/bash
# JEPO PostToolUse Hook -- Read/Write ratio monitor
# Warns after 8 consecutive reads with 0 writes (stuck detection)
# Event: PostToolUse (matcher: Read|Glob|Grep|Write|Edit)

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)

STATE_DIR="$HOME/.claude/cache/loop-detect"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/${SESSION_ID}.rw"

# Classify as read or write
case "$TOOL_NAME" in
    Read|Glob|Grep) OP="read" ;;
    Write|Edit|NotebookEdit) OP="write" ;;
    *) exit 0 ;;
esac

# Update counter
PREV_READS=0
if [ -f "$STATE_FILE" ]; then
    PREV_READS=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
fi

if [ "$OP" = "read" ]; then
    NEW_COUNT=$((PREV_READS + 1))
    echo "$NEW_COUNT" > "$STATE_FILE"

    if [ "$NEW_COUNT" -ge 8 ]; then
        echo "{\"additionalContext\":\"[JEPO] ${NEW_COUNT} consecutive reads with no writes. If edits are needed, proceed. If stuck, explain why.\"}"
        echo "0" > "$STATE_FILE"
    fi
elif [ "$OP" = "write" ]; then
    echo "0" > "$STATE_FILE"
fi

exit 0
