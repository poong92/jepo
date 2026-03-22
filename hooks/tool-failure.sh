#!/bin/bash
# JEPO PostToolUseFailure Hook
# Detects consecutive identical errors and blocks repetition
# Event: PostToolUseFailure

if ! command -v jq &>/dev/null; then exit 0; fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
ERROR=$(echo "$INPUT" | jq -r '.tool_response.stderr // .tool_response.error // "unknown"' 2>/dev/null | head -c 200)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

LOG_DIR="$HOME/logs/jepo"
STATE_DIR="$HOME/.claude/cache/loop-detect"
mkdir -p "$LOG_DIR" "$STATE_DIR"

# Log failure
echo "[$TIMESTAMP] FAIL: $TOOL_NAME | $ERROR" >> "$LOG_DIR/tool-failures.log"

# Per-session consecutive error counter (file-based)
STATE_FILE="$STATE_DIR/${SESSION_ID}.fail"
ERROR_HASH=$(echo "$TOOL_NAME:${ERROR:0:100}" | md5 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1 || echo "$TOOL_NAME")

PREV_HASH=""
CONSECUTIVE=0
if [ -f "$STATE_FILE" ]; then
    PREV_HASH=$(head -1 "$STATE_FILE" 2>/dev/null)
    CONSECUTIVE=$(tail -1 "$STATE_FILE" 2>/dev/null || echo "0")
fi

if [ "$PREV_HASH" = "$ERROR_HASH" ]; then
    CONSECUTIVE=$((CONSECUTIVE + 1))
else
    CONSECUTIVE=1
fi

echo "$ERROR_HASH" > "$STATE_FILE"
echo "$CONSECUTIVE" >> "$STATE_FILE"

# 3+ consecutive same error -> block
if [ "$CONSECUTIVE" -ge 3 ]; then
    echo "{\"decision\":\"block\",\"reason\":\"[JEPO] ${TOOL_NAME} failed ${CONSECUTIVE}x with same error. Stop repeating. Use a different approach.\"}"
    exit 0
fi

# 2 consecutive -> warn
if [ "$CONSECUTIVE" -ge 2 ]; then
    echo "{\"additionalContext\":\"[JEPO] ${TOOL_NAME} failed ${CONSECUTIVE}x consecutively. Do not repeat the same approach.\"}"
fi

exit 0
