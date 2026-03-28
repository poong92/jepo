#!/bin/bash
# JEPO PostToolUse Hook — Read/Write 비율 감시
# 8 consecutive reads + 0 writes → stuck 경고

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)

STATE_DIR="$HOME/.claude/cache/loop-detect"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/${SESSION_ID}.rw"

# Read/Write 분류
case "$TOOL_NAME" in
    Read|Glob|Grep) OP="read" ;;
    Write|Edit|NotebookEdit) OP="write" ;;
    *) exit 0 ;;
esac

# 카운터 업데이트
PREV_READS=0
if [ -f "$STATE_FILE" ]; then
    PREV_READS=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
fi

if [ "$OP" = "read" ]; then
    NEW_COUNT=$((PREV_READS + 1))
    echo "$NEW_COUNT" > "$STATE_FILE"

    if [ "$NEW_COUNT" -ge 8 ]; then
        echo "{\"additionalContext\":\"[JEPO] ${NEW_COUNT}회 연속 읽기만 진행 중. 수정이 필요하면 실행하세요. 막혔다면 이유를 설명하세요.\"}"
        # 리셋 (경고 후 다시 카운트)
        echo "0" > "$STATE_FILE"
    fi
elif [ "$OP" = "write" ]; then
    echo "0" > "$STATE_FILE"
fi

exit 0
