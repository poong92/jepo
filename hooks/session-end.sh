#!/bin/bash
# JEPO SessionEnd Hook
# Saves session summary locally for cross-session sync
# Event: SessionEnd

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null | tr '\n' ' ')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_ONLY=$(date '+%Y-%m-%d')

PROJECT_NAME=$(echo "${CWD##*/}" | tr -cd '[:alnum:]-_.')

# Collect git info
GIT_INFO="{}"
if [ -d "$CWD/.git" ]; then
    cd "$CWD" 2>/dev/null

    BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
    COMMITS_TODAY=$(git log --since="midnight" --oneline 2>/dev/null | wc -l | tr -d ' ')
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    LAST_COMMIT=$(git log -1 --pretty=format:"%s" 2>/dev/null | head -c 100)

    GIT_INFO=$(jq -n \
        --arg branch "$BRANCH" \
        --arg commits "$COMMITS_TODAY" \
        --arg uncommitted "$UNCOMMITTED" \
        --arg last "$LAST_COMMIT" \
        '{branch: $branch, commits_today: $commits, uncommitted: $uncommitted, last_commit: $last}')
fi

# Save session sync data
SYNC_DIR="$HOME/.claude/session-sync"
mkdir -p "$SYNC_DIR"
SYNC_FILE="$SYNC_DIR/pending.json"

jq -n \
    --arg session_id "$SESSION_ID" \
    --arg project "$PROJECT_NAME" \
    --arg cwd "$CWD" \
    --arg reason "$REASON" \
    --arg timestamp "$TIMESTAMP" \
    --arg date "$DATE_ONLY" \
    --arg transcript "$TRANSCRIPT_PATH" \
    --argjson git "$GIT_INFO" \
    '{
        session_id: $session_id,
        project: $project,
        cwd: $cwd,
        end_reason: $reason,
        ended_at: $timestamp,
        date: $date,
        transcript_path: $transcript,
        git: $git,
        synced: false
    }' > "$SYNC_FILE.tmp" && mv "$SYNC_FILE.tmp" "$SYNC_FILE"

# Daily log (history)
LOG_DIR="$HOME/.claude/session-logs"
mkdir -p "$LOG_DIR"
BRANCH_NAME=$(echo "$GIT_INFO" | jq -r '.branch // "unknown"')
echo "[$TIMESTAMP] $SESSION_ID | $PROJECT_NAME | $REASON | branch:$BRANCH_NAME" >> "$LOG_DIR/$DATE_ONLY.log"

# Log rotation (30+ days auto-cleanup)
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

# Clean up loop detection state
rm -f "$HOME/.claude/cache/loop-detect/${SESSION_ID}."* 2>/dev/null || true

exit 0
