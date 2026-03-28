#!/bin/bash
# JEPO PostToolUseFailure Hook v1.1
# 연속 에러 감지 + 강제 중단 지시 + Telegram 알림

if ! command -v jq &>/dev/null; then exit 0; fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)
ERROR=$(echo "$INPUT" | jq -r '.tool_response.stderr // .tool_response.error // "unknown"' 2>/dev/null | head -c 200)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

LOG_DIR="$HOME/logs/jepo"
STATE_DIR="$HOME/.claude/cache/loop-detect"
mkdir -p "$LOG_DIR" "$STATE_DIR"

# 실패 로그 기록
echo "[$TIMESTAMP] FAIL: $TOOL_NAME | $ERROR" >> "$LOG_DIR/tool-failures.log"

# 세션별 연속 에러 카운트 (파일 기반)
STATE_FILE="$STATE_DIR/${SESSION_ID}.fail"
ERROR_HASH=$(echo "$TOOL_NAME:${ERROR:0:100}" | md5 2>/dev/null || echo "$TOOL_NAME")

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

# 5회 연속 같은 에러 → block + Telegram (3→5: API 대기 등 정상 재시도 허용)
if [ "$CONSECUTIVE" -ge 5 ]; then
    # Telegram 알림 (비동기, 실패해도 무시)
    TG_TOKEN=$(grep TELEGRAM_BOT_TOKEN "$HOME/Library/LaunchAgents/com.pruviq.api.plist" 2>/dev/null | grep -o '>.*<' | tr -d '<>' || true)
    TG_CHAT=$(grep TELEGRAM_CHAT_ID "$HOME/Library/LaunchAgents/com.pruviq.api.plist" 2>/dev/null | grep -o '>.*<' | tr -d '<>' || true)
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT}" \
            -d text="[LOOP] ${TOOL_NAME} ${CONSECUTIVE}x fail: ${ERROR:0:80}" &>/dev/null &
    fi

    echo "{\"decision\":\"block\",\"reason\":\"[JEPO] ${TOOL_NAME} ${CONSECUTIVE}회 연속 동일 에러. 같은 방법 반복 금지. 다른 접근법을 사용하세요.\"}"
    exit 0
fi

# 3회 연속 → 경고만 (이전: 2회)
if [ "$CONSECUTIVE" -ge 3 ]; then
    echo "{\"additionalContext\":\"[JEPO] ${TOOL_NAME} ${CONSECUTIVE}회 연속 실패. 같은 방법 반복하지 마세요.\"}"
fi

exit 0
