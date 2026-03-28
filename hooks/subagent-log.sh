#!/bin/bash
# JEPO Subagent Harness Log v2.2
# 에이전트 lifecycle 관찰가능성: 소요시간, 성공여부, 턴수 기록
# v2.2: mkdir 기반 락 (macOS 호환, flock 불필요)

# jq 의존성 체크
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

# 에이전트별 시작 시간 추적 (임시 파일)
STATE_DIR="$HOME/.claude/agent-state"
mkdir -p "$STATE_DIR"

# mkdir 기반 atomic lock (macOS + Linux 호환)
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
    return 1  # lock 실패 시 그냥 진행
}
release_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null
}

if [ "$EVENT" = "start" ]; then
    # 시작 시간 기록
    echo "$EPOCH" > "$STATE_DIR/${AGENT_TYPE}.start"
    echo "[$TIMESTAMP] START: $AGENT_TYPE" >> "$LOG_DIR/subagent-events.log"

    # metrics jsonl (atomic append with mkdir lock)
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
    # 소요 시간 계산
    START_FILE="$STATE_DIR/${AGENT_TYPE}.start"
    DURATION=0
    if [ -f "$START_FILE" ]; then
        START_EPOCH=$(cat "$START_FILE")
        DURATION=$((EPOCH - START_EPOCH))
        rm -f "$START_FILE"
    fi

    # 성공 여부 추론
    SUCCESS="true"
    if [ "$DURATION" -gt 600 ]; then
        SUCCESS="timeout_risk"
    fi

    echo "[$TIMESTAMP] STOP:  $AGENT_TYPE | ${DURATION}s" >> "$LOG_DIR/subagent-events.log"

    # metrics jsonl (atomic append with mkdir lock)
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

    # 주간 통계 (간단 로그)
    if [ -f "$METRICS_FILE" ]; then
        COUNT=$(grep -c "\"agent\":\"$AGENT_TYPE\".*\"event\":\"stop\"" "$METRICS_FILE" 2>/dev/null || echo "0")
        echo "[JEPO METRICS] $AGENT_TYPE: ${COUNT}회 실행, 최근 ${DURATION}s" >> "$LOG_DIR/subagent-events.log"
    fi
fi

# 오래된 시작 상태 파일 정리 (1시간 이상 된 .start 파일)
find "$STATE_DIR" -name "*.start" -mmin +60 -delete 2>/dev/null || true

exit 0
