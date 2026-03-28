#!/bin/bash
# JEPO Operations Dashboard v1.0
# 에이전트 상태, 크론 성공률, 에러 추이를 한 화면에
# Usage: bash dashboard.sh [--json]

set -euo pipefail

JSON_MODE=false
[[ "${1:-}" == "--json" ]] && JSON_MODE=true

NOW=$(date +%s)
NOW_FMT=$(date "+%Y-%m-%d %H:%M KST")

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ─── 1. LaunchAgent 상태 ───
echo -e "\n${BLUE}══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  JEPO Operations Dashboard — $NOW_FMT${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════${NC}\n"

echo -e "${BLUE}▶ LaunchAgents${NC}"
printf "  %-35s %-8s %-12s %s\n" "AGENT" "EXIT" "AGE" "STATUS"
echo "  ──────────────────────────────────────────────────────────"

AGENT_OK=0; AGENT_FAIL=0; AGENT_STALE=0

for plist in ~/Library/LaunchAgents/com.pruviq.*.plist ~/Library/LaunchAgents/com.jepo.*.plist; do
    [ -f "$plist" ] || continue
    label=$(basename "$plist" .plist)
    short=$(echo "$label" | sed 's/com\.pruviq\.//;s/com\.jepo\.//')

    info=$(launchctl list "$label" 2>/dev/null || echo "")
    exit_code=$(echo "$info" | grep LastExitStatus | awk '{print $NF}' | tr -d ';"' || echo "?")
    pid=$(echo "$info" | grep '"PID"' | awk '{print $NF}' | tr -d ';"' || echo "-")

    # Log freshness - read actual stdout path from plist, then fallbacks
    logfile=""
    plist_stdout=$(plutil -extract StandardOutPath raw "$plist" 2>/dev/null || echo "")
    bare=$(echo "$short" | sed 's/^claude-//')
    for candidate in \
        "$plist_stdout" \
        "$HOME/logs/claude-auto/${bare}.log" \
        "$HOME/logs/claude-auto/${short}.log" \
        "$HOME/logs/claude-auto/${bare}-stdout.log" \
        "$HOME/logs/claude-auto/${short}-stdout.log" \
        "$HOME/logs/pruviq/${short}.log" \
        "$HOME/${short}.log"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -s "$candidate" ]; then
            logfile="$candidate"
            break
        fi
    done
    logfile="${logfile:-/dev/null}"
    if [ -f "$logfile" ]; then
        log_mod=$(stat -f%m "$logfile" 2>/dev/null || echo "0")
        age_min=$(( (NOW - log_mod) / 60 ))
        if [ "$age_min" -lt 60 ]; then
            age="${age_min}m"
        elif [ "$age_min" -lt 1440 ]; then
            age="$(( age_min / 60 ))h"
        else
            age="$(( age_min / 1440 ))d"
        fi
    else
        age="no-log"
    fi

    # Status
    if [ "$exit_code" = "0" ] || [ "$exit_code" = "" ] || [ "$exit_code" = "?" ]; then
        status="${GREEN}OK${NC}"
        AGENT_OK=$((AGENT_OK + 1))
    elif [ "$exit_code" = "-9" ]; then
        status="${RED}OOM${NC}"
        AGENT_FAIL=$((AGENT_FAIL + 1))
    else
        status="${RED}FAIL(${exit_code})${NC}"
        AGENT_FAIL=$((AGENT_FAIL + 1))
    fi

    printf "  %-35s %-8s %-12s " "$short" "${exit_code:-0}" "$age"
    echo -e "$status"
done

echo ""
echo -e "  ${GREEN}OK: $AGENT_OK${NC}  ${RED}FAIL: $AGENT_FAIL${NC}"

# ─── 2. 크론 상태 ───
echo -e "\n${BLUE}▶ Cron Jobs ($(crontab -l 2>/dev/null | grep -cv "^#\|^$\|^PATH" || echo 0)개)${NC}"
echo "  최근 크론 로그:"

for logfile in ~/logs/pruviq/monitor.log ~/logs/health.log ~/logs/healthcheck.log ~/logs/pruviq/ohlcv.log ~/logs/pruviq/pipeline.log; do
    [ -f "$logfile" ] || continue
    name=$(basename "$logfile" .log)
    mod=$(stat -f%m "$logfile" 2>/dev/null || echo "0")
    age_min=$(( (NOW - mod) / 60 ))
    size=$(stat -f%z "$logfile" 2>/dev/null || echo "0")
    size_kb=$((size / 1024))
    if [ "$age_min" -lt 30 ]; then
        echo -e "  ${GREEN}●${NC} $name — ${age_min}m ago (${size_kb}KB)"
    elif [ "$age_min" -lt 120 ]; then
        echo -e "  ${YELLOW}●${NC} $name — ${age_min}m ago (${size_kb}KB)"
    else
        echo -e "  ${RED}●${NC} $name — ${age_min}m ago (${size_kb}KB)"
    fi
done

# ─── 3. 에러 추이 (최근 1시간) ───
echo -e "\n${BLUE}▶ Errors (최근 1시간)${NC}"
ERROR_LOG="$HOME/logs/claude-auto/log-error-responder.log"
if [ -f "$ERROR_LOG" ]; then
    one_hour_ago=$(date -v-1H "+%Y-%m-%d %H:%M" 2>/dev/null || date -d "1 hour ago" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "")
    total_errors=$(grep -c "ERROR_DETECTED" "$ERROR_LOG" 2>/dev/null || echo "0")
    recent_errors=$(grep "ERROR_DETECTED" "$ERROR_LOG" 2>/dev/null | tail -20 | wc -l | tr -d ' ')
    suppressed=$(grep -c "P2 suppressed" "$ERROR_LOG" 2>/dev/null || echo "0")
    echo "  총 에러: $total_errors | 최근 20: $recent_errors | 억제(P2): $suppressed"
    echo "  최근 에러:"
    grep "ERROR_DETECTED" "$ERROR_LOG" 2>/dev/null | tail -5 | while read -r line; do
        echo "    $(echo "$line" | sed 's/.*ERROR_DETECTED in //' | cut -c1-80)"
    done
else
    echo "  (로그 없음)"
fi

# ─── 4. 인프라 ───
echo -e "\n${BLUE}▶ Infrastructure${NC}"
API_PID=$(pgrep -f "uvicorn api.main:app" 2>/dev/null | head -1 || echo "")
if [ -n "$API_PID" ]; then
    API_MEM=$(ps -p "$API_PID" -o rss= 2>/dev/null | tr -d ' ')
    API_MEM_GB=$(python3 -c "print(f'{${API_MEM:-0}/1024/1024:.1f}GB')" 2>/dev/null || echo "?")
    echo -e "  API: ${GREEN}running${NC} (PID $API_PID, $API_MEM_GB)"
else
    echo -e "  API: ${RED}DOWN${NC}"
fi

TUNNEL_PID=$(pgrep -f cloudflared 2>/dev/null | head -1 || echo "")
if [ -n "$TUNNEL_PID" ]; then
    echo -e "  Tunnel: ${GREEN}running${NC} (PID $TUNNEL_PID)"
else
    echo -e "  Tunnel: ${RED}DOWN${NC}"
fi

DISK=$(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')
echo "  Disk: $DISK"

echo -e "\n${BLUE}══════════════════════════════════════════════════${NC}\n"
