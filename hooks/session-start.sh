#!/bin/bash
# JEPO Session Start Hook v0.12.0
# 세션 시작 시: 환경 설정 + 프로젝트 감지 + pending sync 알림

# jq 의존성 체크
if ! command -v jq &>/dev/null; then
    echo "OK"
    exit 0
fi

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null)

# source 허용 목록 검증 (injection 방지)
case "$SOURCE" in
    startup|resume) ;;
    *) SOURCE="unknown" ;;
esac

# config.json에서 서버 IP 읽기 (단일 소스)
CONFIG_FILE="$HOME/.claude/config.json"
PROD_SERVER=$(jq -r '.prod_server // "167.172.81.145"' "$CONFIG_FILE" 2>/dev/null)
PROD_SSH_PORT=$(jq -r '.prod_ssh_port // "2222"' "$CONFIG_FILE" 2>/dev/null)

SYNC_FILE="$HOME/.claude/session-sync/pending.json"

if [ -n "$CLAUDE_ENV_FILE" ]; then
    echo "export JEPO_SESSION_TYPE='$SOURCE'" >> "$CLAUDE_ENV_FILE"
    echo 'export JEPO_VERSION="0.12.0"' >> "$CLAUDE_ENV_FILE"
    echo 'export JEPO_USER="jplee"' >> "$CLAUDE_ENV_FILE"
    echo "export JEPO_PROD_SERVER='$PROD_SERVER'" >> "$CLAUDE_ENV_FILE"
    echo "export JEPO_PROD_SSH_PORT='$PROD_SSH_PORT'" >> "$CLAUDE_ENV_FILE"

    # Pending sync 체크 — additionalContext로 Claude에 알림
    if [ -f "$SYNC_FILE" ]; then
        SYNCED=$(jq -r '.synced // false' "$SYNC_FILE" 2>/dev/null)
        if [ "$SYNCED" = "false" ]; then
            PREV_PROJECT=$(jq -r '.project // "unknown"' "$SYNC_FILE" 2>/dev/null)
            PREV_TIME=$(jq -r '.ended_at // "unknown"' "$SYNC_FILE" 2>/dev/null)

            echo 'export JEPO_PENDING_SYNC="true"' >> "$CLAUDE_ENV_FILE"
            echo "export JEPO_SYNC_FILE=\"$SYNC_FILE\"" >> "$CLAUDE_ENV_FILE"
            echo "export JEPO_PREV_PROJECT=\"$PREV_PROJECT\"" >> "$CLAUDE_ENV_FILE"
            echo "export JEPO_PREV_ENDED=\"$PREV_TIME\"" >> "$CLAUDE_ENV_FILE"
        fi
    fi

    # 프로젝트 감지
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
    [ -z "$CWD" ] && CWD=$(pwd)
    PROJECT_NAME="${CWD##*/}"
    echo "export JEPO_PROJECT='$PROJECT_NAME'" >> "$CLAUDE_ENV_FILE"

    # 에이전트 폴더 확인
    AGENTS_DIR="$CWD/.claude/agents"
    if [ -d "$AGENTS_DIR" ]; then
        AGENT_COUNT=$(ls -1 "$AGENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
        echo "export JEPO_HAS_AGENTS=\"true\"" >> "$CLAUDE_ENV_FILE"
        echo "export JEPO_AGENT_COUNT=\"$AGENT_COUNT\"" >> "$CLAUDE_ENV_FILE"
        echo "export JEPO_AGENTS_DIR=\"$AGENTS_DIR\"" >> "$CLAUDE_ENV_FILE"
        AGENT_LIST=$(ls -1 "$AGENTS_DIR"/*.md 2>/dev/null | xargs -I {} basename {} .md | tr '\n' ',' | sed 's/,$//')
        echo "export JEPO_AGENT_LIST=\"$AGENT_LIST\"" >> "$CLAUDE_ENV_FILE"
    fi

    # autotrader: Docker 상태 체크 (빠르게)
    if [ "$PROJECT_NAME" = "autotrader" ]; then
        BOT_STATUS=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -p "$PROD_SSH_PORT" "root@$PROD_SERVER" "docker ps --format '{{.Status}}' -f name=autotrader_bot" 2>/dev/null | head -1)
        if [ -n "$BOT_STATUS" ]; then
            echo "export JEPO_BOT_STATUS=\"$BOT_STATUS\"" >> "$CLAUDE_ENV_FILE"
        fi
    fi
fi

exit 0
