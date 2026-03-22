#!/bin/bash
# JEPO Session Start Hook
# Sets up environment variables, detects project, checks pending sync
# Event: SessionStart

if ! command -v jq &>/dev/null; then
    echo "OK"
    exit 0
fi

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null)

# Source allowlist (injection prevention)
case "$SOURCE" in
    startup|resume) ;;
    *) SOURCE="unknown" ;;
esac

# Read server config from single source (config.json)
CONFIG_FILE="$HOME/.claude/config.json"
PROD_SERVER=$(jq -r '.prod_server // ""' "$CONFIG_FILE" 2>/dev/null)
PROD_SSH_PORT=$(jq -r '.prod_ssh_port // "22"' "$CONFIG_FILE" 2>/dev/null)

SYNC_FILE="$HOME/.claude/session-sync/pending.json"

if [ -n "$CLAUDE_ENV_FILE" ]; then
    echo "export JEPO_SESSION_TYPE='$SOURCE'" >> "$CLAUDE_ENV_FILE"
    echo 'export JEPO_VERSION="1.0.0"' >> "$CLAUDE_ENV_FILE"

    if [ -n "$PROD_SERVER" ]; then
        echo "export JEPO_PROD_SERVER='$PROD_SERVER'" >> "$CLAUDE_ENV_FILE"
        echo "export JEPO_PROD_SSH_PORT='$PROD_SSH_PORT'" >> "$CLAUDE_ENV_FILE"
    fi

    # Pending sync check -- notify Claude via additionalContext
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

    # Project detection
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
    [ -z "$CWD" ] && CWD=$(pwd)
    PROJECT_NAME="${CWD##*/}"
    echo "export JEPO_PROJECT='$PROJECT_NAME'" >> "$CLAUDE_ENV_FILE"

    # Agent folder detection
    AGENTS_DIR="$CWD/.claude/agents"
    if [ -d "$AGENTS_DIR" ]; then
        AGENT_COUNT=$(ls -1 "$AGENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
        echo "export JEPO_HAS_AGENTS=\"true\"" >> "$CLAUDE_ENV_FILE"
        echo "export JEPO_AGENT_COUNT=\"$AGENT_COUNT\"" >> "$CLAUDE_ENV_FILE"
        echo "export JEPO_AGENTS_DIR=\"$AGENTS_DIR\"" >> "$CLAUDE_ENV_FILE"
        AGENT_LIST=$(ls -1 "$AGENTS_DIR"/*.md 2>/dev/null | xargs -I {} basename {} .md | tr '\n' ',' | sed 's/,$//')
        echo "export JEPO_AGENT_LIST=\"$AGENT_LIST\"" >> "$CLAUDE_ENV_FILE"
    fi

    # Optional: server health check (customize per project)
    # if [ "$PROJECT_NAME" = "myproject" ]; then
    #     STATUS=$(ssh -o ConnectTimeout=3 -p "$PROD_SSH_PORT" "user@$PROD_SERVER" "docker ps --format '{{.Status}}'" 2>/dev/null | head -1)
    #     [ -n "$STATUS" ] && echo "export JEPO_SERVER_STATUS=\"$STATUS\"" >> "$CLAUDE_ENV_FILE"
    # fi
fi

exit 0
