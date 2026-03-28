#!/bin/bash
# JEPO PostCompact Hook v1.1
# Compaction 후: 핵심 컨텍스트 재주입
# MEMORY.md가 자동 로드되므로 Mem0 검색 불필요

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$HOME/logs/jepo"
mkdir -p "$LOG_DIR"

# compact summary 추출
SUMMARY=$(echo "$INPUT" | jq -r '.compact_summary // "없음"' 2>/dev/null | head -c 500)

# 로그 기록
echo "[$TIMESTAMP] POST-COMPACT | summary_len=$(echo "$SUMMARY" | wc -c | tr -d ' ')" >> "$LOG_DIR/compact-events.log"

# Claude에게 핵심 리마인더 주입
CONFIG_FILE="$HOME/.claude/config.json"
PROD_SERVER=$(jq -r '.prod_server // "167.172.81.145"' "$CONFIG_FILE" 2>/dev/null)

echo "{"additionalContext":"[JEPO POST-COMPACT] 컨텍스트가 압축되었습니다. 핵심 리마인더: (1) CLAUDE.md 원칙을 따르세요 (2) 서버 IP는 config.json 참조 ($PROD_SERVER) (3) MEMORY.md가 자동 로드됩니다 — 별도 메모리 검색 불필요 (4) 현재 프로젝트의 CLAUDE.md를 다시 확인하세요."}"

exit 0
