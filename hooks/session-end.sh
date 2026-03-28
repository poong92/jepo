#!/bin/bash
# JEPO SessionEnd Hook v0.8.0
# 세션 종료 시 작업 요약을 로컬에 저장 (다음 세션에서 auto-memory 자동 로드)

# jq 의존성 체크
if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat)

# 필요한 정보 추출
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // "unknown"')
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null | tr '\n' ' ')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')

# 현재 시간
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_ONLY=$(date '+%Y-%m-%d')

# 프로젝트명
PROJECT_NAME=$(echo "${CWD##*/}" | tr -cd '[:alnum:]-_.')

# Git 정보 수집
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

# 세션 요약 JSON 생성
SYNC_DIR="$HOME/.claude/session-sync"
mkdir -p "$SYNC_DIR"

SYNC_FILE="$SYNC_DIR/pending.json"

# JSON 저장 (atomic write)
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

# 일별 로그도 유지 (히스토리용)
LOG_DIR="$HOME/.claude/session-logs"
mkdir -p "$LOG_DIR"
BRANCH_NAME=$(echo "$GIT_INFO" | jq -r '.branch // "unknown"')
echo "[$TIMESTAMP] $SESSION_ID | $PROJECT_NAME | $REASON | branch:$BRANCH_NAME" >> "$LOG_DIR/$DATE_ONLY.log"

# 로그 로테이션 (30일 이상 자동 정리)
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

# 루프 감지 상태 파일 정리
rm -f "$HOME/.claude/cache/loop-detect/${SESSION_ID}."* 2>/dev/null || true

exit 0
