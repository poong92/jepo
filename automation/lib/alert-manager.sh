#!/bin/bash
# JEPO Alert Manager -- 4-level structured alerting with dedup + throttle
#
# Usage: source lib/alert-manager.sh
#        alert_send "ERROR" "deploy-verify" "Rollback failed" "deploy"
#
# Levels: CRITICAL > ERROR > WARNING > INFO
# Channels: telegram, log, github-issue (CRITICAL only)

ALERT_LOG="${LOG_DIR:-$HOME/logs/claude-auto}/alerts.jsonl"
ALERT_THROTTLE_DIR="/tmp/claude-auto-alert-throttle"
mkdir -p "$ALERT_THROTTLE_DIR"

# Throttle intervals (seconds) per level
_alert_throttle_sec() {
    case "$1" in
        CRITICAL) echo 60   ;;
        ERROR)    echo 300  ;;
        WARNING)  echo 1800 ;;
        INFO)     echo 3600 ;;
        *)        echo 3600 ;;
    esac
}

# Main entry point
alert_send() {
    local level="$1"
    local agent="$2"
    local message="$3"
    local category="${4:-general}"

    local throttle_key="${agent}-${category}-${level}"
    local throttle_file="$ALERT_THROTTLE_DIR/${throttle_key}"
    local throttle_sec
    throttle_sec=$(_alert_throttle_sec "$level")

    if [[ -f "$throttle_file" ]]; then
        local last_sent
        last_sent=$(cat "$throttle_file" 2>/dev/null || echo "0")
        [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0
        local now
        now=$(date +%s)
        if [[ $(( now - last_sent )) -lt $throttle_sec ]]; then
            _alert_log "$level" "$agent" "$message" "THROTTLED"
            return 0
        fi
    fi

    _alert_telegram "$level" "$agent" "$message"
    _alert_log "$level" "$agent" "$message" "SENT"

    if [[ "$level" == "CRITICAL" ]]; then
        _alert_github_issue "$agent" "$message" "$category"
    fi

    date +%s > "$throttle_file"
}

_alert_telegram() {
    local level="$1" agent="$2" message="$3"
    if declare -f send_telegram_structured &>/dev/null; then
        send_telegram_structured "$level" "$agent" "$message"
    elif declare -f send_telegram &>/dev/null; then
        send_telegram "[${level}] ${agent}: ${message}"
    fi
}

_alert_log() {
    local level="$1" agent="$2" message="$3" status="${4:-SENT}"
    AL_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)" AL_LEVEL="$level" AL_AGENT="$agent" \
    AL_MSG="$message" AL_STATUS="$status" AL_LOG="$ALERT_LOG" \
    python3 -c '
import json, os
entry = json.dumps({
    "ts": os.environ["AL_TS"],
    "level": os.environ["AL_LEVEL"],
    "agent": os.environ["AL_AGENT"],
    "msg": os.environ["AL_MSG"][:500],
    "status": os.environ["AL_STATUS"],
}, ensure_ascii=False)
with open(os.environ["AL_LOG"], "a") as f:
    f.write(entry + "\n")
' 2>/dev/null || true
}

_alert_github_issue() {
    local agent="$1" message="$2" category="$3"
    local repo="${JEPO_REPO:-}"
    if [[ -n "$repo" ]] && declare -f create_issue_safe &>/dev/null; then
        create_issue_safe "$repo" \
            "CRITICAL: ${agent} -- ${message:0:80}" \
            "## Alert\n\n**Agent**: ${agent}\n**Category**: ${category}\n**Time**: $(date -u)\n\n${message}" \
            "claude-auto,P0,${category}" 2>/dev/null || true
    fi
}

alert_clear_throttle() {
    local agent="$1"
    rm -f "$ALERT_THROTTLE_DIR/${agent}-"* 2>/dev/null || true
}

alert_summary() {
    local hours="${1:-24}"
    if [[ ! -f "$ALERT_LOG" ]]; then
        echo '{"CRITICAL":0,"ERROR":0,"WARNING":0,"INFO":0}'
        return
    fi
    AS_HOURS="$hours" AS_LOG="$ALERT_LOG" python3 -c '
import json, os
from datetime import datetime, timezone, timedelta
hours = int(os.environ["AS_HOURS"])
logfile = os.environ["AS_LOG"]
cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
counts = {"CRITICAL": 0, "ERROR": 0, "WARNING": 0, "INFO": 0}
with open(logfile) as f:
    for line in f:
        try:
            entry = json.loads(line.strip())
            ts = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
            if ts >= cutoff and entry.get("status") == "SENT":
                level = entry.get("level", "INFO")
                if level in counts:
                    counts[level] += 1
        except: continue
print(json.dumps(counts))
' 2>/dev/null || echo '{"CRITICAL":0,"ERROR":0,"WARNING":0,"INFO":0}'
}
