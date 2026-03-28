#!/bin/bash
# JEPO Autopilot v0.2.0 — Alert Manager
# 4-level structured alerting with dedup + throttle
#
# Usage: source lib/alert-manager.sh
#        alert_send "ERROR" "deploy-verify" "Rollback failed" "deploy"
#
# Levels: CRITICAL > ERROR > WARNING > INFO
# Channels: telegram, log, github-issue (CRITICAL only)

# Note: no set -euo pipefail — library inherits caller's options

ALERT_LOG="${LOG_DIR:-$HOME/logs/claude-auto}/alerts.jsonl"
ALERT_THROTTLE_DIR="/tmp/claude-auto-alert-throttle"
mkdir -p "$ALERT_THROTTLE_DIR"

# Throttle intervals (seconds) per level
# Note: Using function instead of associative array for bash 3.2 (macOS) compat
_alert_throttle_sec() {
    case "$1" in
        CRITICAL) echo 60   ;;  # 1 min
        ERROR)    echo 300  ;;  # 5 min
        WARNING)  echo 1800 ;;  # 30 min
        INFO)     echo 3600 ;;  # 1 hour
        *)        echo 3600 ;;
    esac
}

# ---------------------------------------------------------------------------
# alert_send() — Main entry point for structured alerts
#   $1 - level: CRITICAL, ERROR, WARNING, INFO
#   $2 - agent: agent name
#   $3 - message: alert body
#   $4 - category: deploy, data, perf, meta, security (for dedup)
# ---------------------------------------------------------------------------
alert_send() {
    local level="$1"
    local agent="$2"
    local message="$3"
    local category="${4:-general}"

    # Throttle check (prevent spam for same agent+category+level)
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
        local elapsed=$(( now - last_sent ))
        if [[ $elapsed -lt $throttle_sec ]]; then
            # Throttled — log silently but don't send
            _alert_log "$level" "$agent" "$message" "THROTTLED"
            return 0
        fi
    fi

    # Send alert
    _alert_telegram "$level" "$agent" "$message"
    _alert_log "$level" "$agent" "$message" "SENT"

    # CRITICAL → also create GitHub Issue
    if [[ "$level" == "CRITICAL" ]]; then
        _alert_github_issue "$agent" "$message" "$category"
    fi

    # Update throttle timestamp
    date +%s > "$throttle_file"
}

# ---------------------------------------------------------------------------
# Internal: Send Telegram alert
# ---------------------------------------------------------------------------
_alert_telegram() {
    local level="$1"
    local agent="$2"
    local message="$3"

    # Use send_telegram_structured if available (from claude-runner.sh)
    if declare -f send_telegram_structured &>/dev/null; then
        send_telegram_structured "$level" "$agent" "$message"
    elif declare -f send_telegram &>/dev/null; then
        local icon=""
        case "$level" in
            CRITICAL) icon="🚨" ;; ERROR) icon="❌" ;;
            WARNING)  icon="⚠️" ;; INFO)  icon="ℹ️" ;;
        esac
        send_telegram "${icon} [${level}] ${agent}: ${message}"
    fi
}

# ---------------------------------------------------------------------------
# Internal: Log alert to JSONL
# ---------------------------------------------------------------------------
_alert_log() {
    local level="$1"
    local agent="$2"
    local message="$3"
    local status="${4:-SENT}"

    # Use Python for safe JSON serialization (no printf format string injection)
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

# ---------------------------------------------------------------------------
# Internal: Create GitHub Issue for CRITICAL alerts
# ---------------------------------------------------------------------------
_alert_github_issue() {
    local agent="$1"
    local message="$2"
    local category="$3"

    if declare -f create_issue_safe &>/dev/null; then
        create_issue_safe "pruviq/pruviq" \
            "🚨 CRITICAL: ${agent} — ${message:0:80}" \
            "## Alert\n\n**Agent**: ${agent}\n**Category**: ${category}\n**Time**: $(date -u)\n\n${message}" \
            "claude-auto,P0,${category}" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# alert_clear_throttle() — Reset throttle for an agent
#   Usage: alert_clear_throttle "deploy-verify"
# ---------------------------------------------------------------------------
alert_clear_throttle() {
    local agent="$1"
    rm -f "$ALERT_THROTTLE_DIR/${agent}-"* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# alert_summary() — Get alert counts for last N hours
#   Usage: alert_summary 24  → counts by level for last 24h
# ---------------------------------------------------------------------------
alert_summary() {
    local hours="${1:-24}"
    local since
    since=$(date -u -v-"${hours}H" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
            date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

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
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            ts = datetime.fromisoformat(entry["ts"].replace("Z", "+00:00"))
            if ts >= cutoff and entry.get("status") == "SENT":
                level = entry.get("level", "INFO")
                if level in counts:
                    counts[level] += 1
        except (json.JSONDecodeError, KeyError, ValueError):
            continue

print(json.dumps(counts))
' 2>/dev/null || echo '{"CRITICAL":0,"ERROR":0,"WARNING":0,"INFO":0}'
}
