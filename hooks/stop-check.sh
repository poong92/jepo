#!/bin/bash
# JEPO Stop Hook v0.8.0
# 작업 완료 시 품질 체크 및 알림

# stdin에서 JSON 입력 읽기
INPUT=$(cat)

# 현재 디렉토리
CWD=$(pwd)

WARNINGS=""

# Git 레포인 경우 uncommitted 변경사항 확인
if [ -d "$CWD/.git" ]; then
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$UNCOMMITTED" -gt 0 ]; then
        WARNINGS="${WARNINGS}$UNCOMMITTED uncommitted changes. "
    fi
fi

# pending sync 확인 (세션 간 동기화 누락 방지)
SYNC_FILE="$HOME/.claude/session-sync/pending.json"
if [ -f "$SYNC_FILE" ]; then
    if command -v jq &>/dev/null; then
        SYNCED=$(jq -r 'if .synced == false then "false" else "true" end' "$SYNC_FILE" 2>/dev/null)
        if [ "$SYNCED" = "false" ]; then
            WARNINGS="${WARNINGS}Pending session sync not completed. "
        fi
    fi
fi

# 경고 출력
if [ -n "$WARNINGS" ]; then
    echo "{\"stopReason\": \"[JEPO] ${WARNINGS}\"}"
fi

exit 0
