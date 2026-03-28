#!/bin/bash
# JEPO PostToolUse Hook (Write|Edit)
# 파일 편집 후 자동 포맷팅 및 검증

# stdin에서 JSON 읽기
INPUT=$(cat)

# file_path 추출
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# 시스템 경로 보호
case "$FILE_PATH" in
    /etc/*|/usr/*|/bin/*|/sbin/*|/System/*) exit 0 ;;
esac

# 파일 확장자 확인
EXT="${FILE_PATH##*.}"

# TypeScript/JavaScript: prettier 포맷팅
# 미설치 시: npm install -g prettier
if [[ "$EXT" == "ts" || "$EXT" == "tsx" || "$EXT" == "js" || "$EXT" == "jsx" ]]; then
    if command -v prettier &> /dev/null; then
        prettier --write "$FILE_PATH" 2>/dev/null || true
    fi
fi

# Python: black 포맷팅
# 미설치 시: pip install black
if [[ "$EXT" == "py" ]]; then
    if command -v black &> /dev/null; then
        black --quiet "$FILE_PATH" 2>/dev/null || true
    fi
fi

# JSON: jq 검증 (구문 오류 감지)
if [[ "$EXT" == "json" ]]; then
    if command -v jq &> /dev/null; then
        if ! jq empty "$FILE_PATH" 2>/dev/null; then
            echo "[JEPO] JSON 문법 오류 감지: $FILE_PATH" >&2
        fi
    fi
fi

exit 0
