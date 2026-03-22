#!/bin/bash
# JEPO PostToolUse Hook (Write|Edit)
# Auto-formatting and validation after file edits
# Event: PostToolUse (matcher: Write|Edit)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Protect system paths
case "$FILE_PATH" in
    /etc/*|/usr/*|/bin/*|/sbin/*|/System/*) exit 0 ;;
esac

EXT="${FILE_PATH##*.}"

# TypeScript/JavaScript: prettier formatting
if [[ "$EXT" == "ts" || "$EXT" == "tsx" || "$EXT" == "js" || "$EXT" == "jsx" ]]; then
    if command -v prettier &> /dev/null; then
        prettier --write "$FILE_PATH" 2>/dev/null || true
    fi
fi

# Python: black formatting
if [[ "$EXT" == "py" ]]; then
    if command -v black &> /dev/null; then
        black --quiet "$FILE_PATH" 2>/dev/null || true
    fi
fi

# JSON: syntax validation
if [[ "$EXT" == "json" ]]; then
    if command -v jq &> /dev/null; then
        if ! jq empty "$FILE_PATH" 2>/dev/null; then
            echo "[JEPO] JSON syntax error detected: $FILE_PATH" >&2
        fi
    fi
fi

exit 0
