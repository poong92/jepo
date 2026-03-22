#!/bin/bash
# JEPO Subagent Lifecycle Logger
# Tracks agent start/stop, duration, and run count
# Uses mkdir-based locking (macOS compatible, no flock needed)
# Event: SubagentStart / SubagentStop

if ! command -v jq &>/dev/null; then
    exit 0
fi

EVENT="$1"
INPUT=$(cat)
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"' 2>/dev/null)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
EPOCH=$(date +%s)
LOG_DIR="$HOME/logs/jepo"
METRICS_FILE="$LOG_DIR/agent-metrics.jsonl"
mkdir -p "$LOG_DIR"

STATE_DIR="$HOME/.claude/agent-state"
mkdir -p "$STATE_DIR"

# mkdir-based atomic lock (macOS + Linux compatible)
LOCK_DIR="$METRICS_FILE.lockdir"
acquire_lock() {
    local retries=10
    while [ $retries -gt 0 ]; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            return 0
        fi
        retries=$((retries - 1))
        sleep 0.1
    done
    return 1
}
release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
}

if [ "$EVENT" = "start" ]; then
    echo "$EPOCH" > "$STATE_DIR/${AGENT_TYPE}.start"
    echo "[$TIMESTAMP] START: $AGENT_TYPE" >> "$LOG_DIR/subagent-events.log"

    ENTRY=$(jq -cn \
        --arg ts "$TIMESTAMP" \
        --arg event "start" \
        --arg agent "$AGENT_TYPE" \
        --arg epoch "$EPOCH" \
        '{ts: $ts, event: $event, agent: $agent, epoch: ($epoch | tonumber)}')
    if acquire_lock; then
        echo "$ENTRY" >> "$METRICS_FILE"
        release_lock
    else
        echo "$ENTRY" >> "$METRICS_FILE"
    fi

elif [ "$EVENT" = "stop" ]; then
    START_FILE="$STATE_DIR/${AGENT_TYPE}.start"
    DURATION=0
    if [ -f "$START_FILE" ]; then
        START_EPOCH=$(cat "$START_FILE")
        DURATION=$((EPOCH - START_EPOCH))
        rm -f "$START_FILE"
    fi

    SUCCESS="true"
    if [ "$DURATION" -gt 600 ]; then
        SUCCESS="timeout_risk"
    fi

    echo "[$TIMESTAMP] STOP:  $AGENT_TYPE | ${DURATION}s" >> "$LOG_DIR/subagent-events.log"

    ENTRY=$(jq -cn \
        --arg ts "$TIMESTAMP" \
        --arg event "stop" \
        --arg agent "$AGENT_TYPE" \
        --arg epoch "$EPOCH" \
        --arg duration "$DURATION" \
        --arg success "$SUCCESS" \
        '{ts: $ts, event: $event, agent: $agent, epoch: ($epoch | tonumber), duration_sec: ($duration | tonumber), success: $success}')
    if acquire_lock; then
        echo "$ENTRY" >> "$METRICS_FILE"
        release_lock
    else
        echo "$ENTRY" >> "$METRICS_FILE"
    fi

    if [ -f "$METRICS_FILE" ]; then
        COUNT=$(grep -c "\"agent\":\"$AGENT_TYPE\".*\"event\":\"stop\"" "$METRICS_FILE" 2>/dev/null || echo "0")
        echo "[JEPO METRICS] $AGENT_TYPE: ${COUNT} runs, latest ${DURATION}s" >> "$LOG_DIR/subagent-events.log"
    fi
fi

# Clean up stale start files (>1 hour old)
find "$STATE_DIR" -name "*.start" -mmin +60 -delete 2>/dev/null || true

exit 0
