#!/bin/bash
# JEPO PreCompact Hook v1.1
# Compaction 전: 현재 작업 상태를 로컬에 백업
# auto-memory가 자동 보존하지만, 핵심 결론은 memory/ 폴더에 명시적으로 저장 권장

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$HOME/logs/jepo"
mkdir -p "$LOG_DIR"

# Compaction 로그 기록
echo "[$TIMESTAMP] PRE-COMPACT triggered" >> "$LOG_DIR/compact-events.log"

# Claude에게 memory/ 폴더 저장을 리마인드
echo '{"additionalContext":"[JEPO] Compaction 임박. 현재 작업의 핵심 결론/진행상황이 있다면 memory/ 폴더에 .md 파일로 저장하세요. compaction 후 컨텍스트가 축소됩니다."}' 

exit 0
