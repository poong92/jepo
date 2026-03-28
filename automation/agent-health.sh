#!/bin/bash
# agent-health — Monitor all agents' health + auto-restart stale locks
# Schedule: every 30 minutes via LaunchAgent
#
# Checks:
#   1. Log freshness (has each agent logged recently?)
#   2. Lock files (stale locks blocking execution?)
#   3. LaunchAgent status (loaded and running?)
#   4. Resource usage (log sizes, disk usage)
#
# Actions:
#   - Stale locks: auto-remove (>1h old)
#   - Missing agents: alert
#   - Resource warnings: alert

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "agent-health"

LOGFILE="$LOG_DIR/agent-health.log"
rotate_log "$LOGFILE"

echo "$(date): agent-health check started" >> "$LOGFILE"

# ─── Agent Registry ───
# name:expected_max_age_seconds
AGENTS=(
    "auth-keepalive:3600"
    "pr-review:600"
    "deploy-verify:600"
    "review-responder:3600"
    "telegram-approval-poller:600"
)
# 제거됨 (비활성): daily-audit, deep-qa, daily-strategy-recap (disabled/)
# 제거됨 (미존재): find-improvements (LaunchAgent 없음)
# 제거됨 (독립 cron): daily-strategy-ranking (~/logs/에 로그, claude-auto 아님)

HEALTHY_COUNT=0
STALE_COUNT=0
MISSING_COUNT=0
TOTAL_COUNT=${#AGENTS[@]}

report_lines=()

# ─── Phase 1: Check each agent's log freshness ───
echo "$(date): Phase 1 — Log freshness check" >> "$LOGFILE"

for entry in "${AGENTS[@]}"; do
    agent="${entry%%:*}"
    max_age="${entry##*:}"

    status=$(check_agent_health "$agent" "$max_age" 2>&1) && rc=$? || rc=$?

    case $rc in
        0)
            HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
            report_lines+=("✅ $agent — $status")
            ;;
        1)
            STALE_COUNT=$((STALE_COUNT + 1))
            report_lines+=("⚠️ $agent — $status")
            echo "$(date): STALE: $agent ($status)" >> "$LOGFILE"
            ;;
        2)
            MISSING_COUNT=$((MISSING_COUNT + 1))
            report_lines+=("❌ $agent — NO LOG")
            echo "$(date): MISSING: $agent — no log file found" >> "$LOGFILE"
            ;;
    esac
done

# ─── Phase 2: Stale lock cleanup ───
echo "$(date): Phase 2 — Lock cleanup" >> "$LOGFILE"

locks_cleaned=0
if [[ -d "$LOCK_DIR" ]]; then
    for lockdir in "$LOCK_DIR"/*.lockdir; do
        [[ -d "$lockdir" ]] || continue
        lock_name=$(basename "$lockdir" .lockdir)
        lock_age=$(( $(date +%s) - $(stat -f%m "$lockdir" 2>/dev/null || echo 0) ))

        if [[ $lock_age -gt 3600 ]]; then
            rm -rf "$lockdir"
            locks_cleaned=$((locks_cleaned + 1))
            echo "$(date): Cleaned stale lock: $lock_name (age: ${lock_age}s)" >> "$LOGFILE"
            report_lines+=("🔓 Cleaned stale lock: $lock_name (${lock_age}s)")
        fi
    done
fi

# ─── Phase 3: LaunchAgent status ───
echo "$(date): Phase 3 — LaunchAgent status" >> "$LOGFILE"

la_loaded=0
la_total=0
while IFS= read -r line; do
    la_total=$((la_total + 1))
    # Check PID column (first field): "-" means idle (interval-based), number = currently running
    pid=$(echo "$line" | awk '{print $1}')
    [[ "$pid" != "-" ]] && la_loaded=$((la_loaded + 1))
done < <(launchctl list 2>/dev/null | grep "pruviq" || true)

report_lines+=("📋 LaunchAgents: $la_total loaded ($la_loaded currently running)")
echo "$(date): LaunchAgents: $la_loaded/$la_total loaded" >> "$LOGFILE"

# ─── Phase 4: Resource check ───
echo "$(date): Phase 4 — Resource check" >> "$LOGFILE"

log_size=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')
disk_avail=$(df -h "$HOME" 2>/dev/null | tail -1 | awk '{print $4}')

report_lines+=("💾 Logs: $log_size | Disk available: $disk_avail")

# ─── Phase 5: Rate limiter status ───
echo "$(date): Phase 5 — Rate limiter" >> "$LOGFILE"

rate_json=$(rate_status 2>/dev/null || echo "{}")
report_lines+=("📊 API calls today: $(echo "$rate_json" | python3 -c "
import sys,json
d = json.load(sys.stdin)
total = sum(d.values())
print(f'{total} total across {len(d)} agents')
" 2>/dev/null || echo "unknown")")

# ─── Phase 6: Zombie claude process detection ───
echo "$(date): Phase 6 — Zombie process check" >> "$LOGFILE"

zombies_killed=0
ZOMBIE_MAX_SEC=7200  # 2 hours

while IFS= read -r proc_line; do
    [[ -z "$proc_line" ]] && continue

    proc_pid=$(echo "$proc_line" | awk '{print $1}')
    proc_ppid=$(echo "$proc_line" | awk '{print $2}')
    proc_elapsed=$(echo "$proc_line" | awk '{print $3}')

    # Parse elapsed time (DD-HH:MM:SS or HH:MM:SS or MM:SS)
    elapsed_sec=$(ELAPSED="$proc_elapsed" python3 -c '
import os, re
e = os.environ["ELAPSED"].strip()
parts = re.split(r"[-:]", e)
parts = [int(p) for p in parts]
if len(parts) == 4:
    print(parts[0]*86400 + parts[1]*3600 + parts[2]*60 + parts[3])
elif len(parts) == 3:
    print(parts[0]*3600 + parts[1]*60 + parts[2])
elif len(parts) == 2:
    print(parts[0]*60 + parts[1])
else:
    print(0)
' 2>/dev/null || echo "0")

    if [[ $elapsed_sec -gt $ZOMBIE_MAX_SEC ]]; then
        hours=$(( elapsed_sec / 3600 ))
        # Kill the zombie
        kill "$proc_pid" 2>/dev/null && {
            zombies_killed=$((zombies_killed + 1))
            echo "$(date): KILLED zombie claude PID=$proc_pid PPID=$proc_ppid elapsed=${hours}h" >> "$LOGFILE"
            report_lines+=("💀 Killed zombie: PID=$proc_pid (${hours}h, PPID=$proc_ppid)")
        }
    fi
done < <(ps -eo pid,ppid,etime,command 2>/dev/null | grep "[c]laude -p" | awk '{print $1, $2, $3}')

if [[ $zombies_killed -gt 0 ]]; then
    alert_send "WARNING" "agent-health" "Killed $zombies_killed zombie claude process(es)" "meta" 2>/dev/null
fi

# ─── Generate Report ───
report_date=$(date +%Y%m%d)
report_file="$RESULTS_DIR/agent-health-${report_date}.md"

report_content="# Agent Health Report — $(date -u +%Y-%m-%d\ %H:%M\ UTC)

## Summary
- **Healthy**: $HEALTHY_COUNT / $TOTAL_COUNT
- **Stale**: $STALE_COUNT
- **Missing**: $MISSING_COUNT
- **Locks cleaned**: $locks_cleaned
- **Zombies killed**: $zombies_killed

## Agent Status
"

for line in "${report_lines[@]}"; do
    report_content+="- $line
"
done

atomic_write "$report_file" "$report_content"

# ─── Alerts ───
if [[ $MISSING_COUNT -gt 0 ]]; then
    alert_send "ERROR" "agent-health" "$MISSING_COUNT agents have no log (never ran?)" "meta" 2>/dev/null
fi

if [[ $STALE_COUNT -gt 2 ]]; then
    alert_send "WARNING" "agent-health" "$STALE_COUNT agents stale (out of $TOTAL_COUNT)" "meta" 2>/dev/null
fi

if [[ $locks_cleaned -gt 0 ]]; then
    alert_send "INFO" "agent-health" "Cleaned $locks_cleaned stale lock(s)" "meta" 2>/dev/null
fi

# ─── Phase 7: Critical pipeline check (daily ranking file) ───
echo "$(date): Phase 7 — Critical pipeline check" >> "$LOGFILE"

# 데이터 주기 = 전일 09:00 KST ~ 당일 09:00 KST
# 09:00 이전에는 어제 파일이 유효
CURRENT_HOUR=$(TZ=Asia/Seoul date +%H)
if [[ 10#$CURRENT_HOUR -lt 9 ]]; then
    RANKING_DATE=$(TZ=Asia/Seoul date -v-1d +%Y%m%d)
else
    RANKING_DATE=$(TZ=Asia/Seoul date +%Y%m%d)
fi
RANKING_FILE="/Users/jepo/Desktop/autotrader/data/daily_rankings/ranking_${RANKING_DATE}.json"
pipeline_ok=true

if [[ ! -f "$RANKING_FILE" ]]; then
    report_lines+=("❌ daily-strategy-ranking: ranking_${RANKING_DATE}.json missing — pipeline may have failed")
    echo "$(date): MISSING ranking file for ${RANKING_DATE}: $RANKING_FILE" >> "$LOGFILE"
    alert_send "ERROR" "agent-health" "No ranking file for ${RANKING_DATE}. daily-strategy-ranking may have failed." "meta" 2>/dev/null
    pipeline_ok=false
else
    ranking_age=$(( $(date +%s) - $(stat -f%m "$RANKING_FILE" 2>/dev/null || echo 0) ))
    ranking_hours=$(( ranking_age / 3600 ))

    # API로 랭킹 날짜 검증 (Desktop TCC 권한 우회)
    api_date=$(curl -sf --max-time 5 "https://api.pruviq.com/rankings/daily?period=30d&group=Market%20Cap%20Top%2050" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('date','error'))" 2>/dev/null || echo "error")

    if [[ "$api_date" == "$RANKING_DATE" ]] || [[ "$api_date" == "${RANKING_DATE:0:4}-${RANKING_DATE:4:2}-${RANKING_DATE:6:2}" ]]; then
        report_lines+=("✅ daily-strategy-ranking: ranking_${RANKING_DATE}.json exists (${ranking_hours}h ago) | API date: $api_date")
        echo "$(date): ranking file OK: $RANKING_FILE (${ranking_hours}h ago) api_date=$api_date" >> "$LOGFILE"
    elif [[ "$api_date" == "error" ]]; then
        report_lines+=("⚠️ daily-strategy-ranking: ranking file exists (${ranking_hours}h ago) but API unresponsive")
        echo "$(date): ranking file exists but API check failed: $RANKING_FILE" >> "$LOGFILE"
    else
        report_lines+=("⚠️ daily-strategy-ranking: ranking file date mismatch — file:${RANKING_DATE} api:${api_date}")
        echo "$(date): ranking date mismatch file=${RANKING_DATE} api=${api_date}" >> "$LOGFILE"
    fi
fi

# market.json freshness check (PRUVIQ site data — generated every 20min by refresh_static.sh cron)
MARKET_JSON="/Users/jepo/pruviq/public/data/market.json"
if [[ -f "$MARKET_JSON" ]]; then
    market_age=$(( $(date +%s) - $(stat -f%m "$MARKET_JSON" 2>/dev/null || echo 0) ))
    market_min=$(( market_age / 60 ))
    if [[ $market_age -gt 3600 ]]; then
        report_lines+=("❌ market.json: ${market_min}min old (>60min) — refresh_static.sh cron may have failed")
        alert_send "ERROR" "agent-health" "market.json ${market_min}min old — check refresh_static.sh cron" "meta" 2>/dev/null
    elif [[ $market_age -gt 1800 ]]; then
        report_lines+=("⚠️ market.json: ${market_min}min old (>30min) — refresh may be slow")
    else
        report_lines+=("✅ market.json: ${market_min}min old (OK)")
    fi
else
    report_lines+=("❌ market.json: file not found at $MARKET_JSON")
    alert_send "ERROR" "agent-health" "market.json missing — refresh_static.sh not running" "meta" 2>/dev/null
fi

# ─── Phase 8: Core LaunchAgent exit status audit ───
echo "$(date): Phase 8 — LaunchAgent exit status audit" >> "$LOGFILE"

# Core agents that must be running/runnable
# Format: identifier:expected_to_be_running (true/false)
# PID "-" = not currently running (interval-based agents), but should have exit code 0 if recently ran
CORE_AGENTS=(
    "com.pruviq.api:true"
    "com.pruviq.tunnel:true"
    "com.pruviq.daily-strategy-ranking:true"
    "com.pruviq.telegram-approval-poller:true"
    "com.pruviq.claude-auth-keepalive:true"
    "com.pruviq.claude-agent-health:true"
    "com.jepo.log-error-responder:false"
)
# 제거됨: daily-strategy-recap (disabled/)

la_errors=0
la_report=()

for entry in "${CORE_AGENTS[@]}"; do
    agent_label="${entry%%:*}"
    expected_running="${entry##*:}"

    # Get full line from launchctl list
    la_line=$(launchctl list 2>/dev/null | grep "$agent_label$" || echo "")

    if [[ -z "$la_line" ]]; then
        la_report+=("❌ $agent_label — NOT LOADED (not in launchctl list)")
        echo "$(date): LaunchAgent NOT LOADED: $agent_label" >> "$LOGFILE"
        la_errors=$((la_errors + 1))
    else
        # Parse: "PID  EXITCODE  NAME"
        # Examples:
        #   "887   0   com.pruviq.tunnel"           (running, exit 0)
        #   "-     0   com.pruviq.daily-digest"     (idle, exit 0)
        #   "-     127 com.jepo.log-error-responder" (last run failed)
        #   "18644 -15 com.pruviq.api"              (running, killed with SIGTERM - normal)

        la_pid=$(echo "$la_line" | awk '{print $1}')
        la_exit=$(echo "$la_line" | awk '{print $2}')

        case "$la_exit" in
            0)
                # Success — all good
                if [[ "$la_pid" == "-" ]]; then
                    la_report+=("✅ $agent_label — idle (exit 0)")
                else
                    la_report+=("✅ $agent_label — running (PID $la_pid, exit 0)")
                fi
                ;;
            -15)
                # SIGTERM — normal termination (usually via launchctl stop/restart)
                if [[ "$expected_running" == "true" ]]; then
                    # Daemon killed, likely restarting or was manually stopped — WARNING
                    la_report+=("⚠️ $agent_label — terminated (SIGTERM, PID $la_pid) - should be auto-restarting")
                    echo "$(date): LaunchAgent SIGTERM (expected to run): $agent_label" >> "$LOGFILE"
                else
                    la_report+=("✅ $agent_label — idle (SIGTERM normal)")
                fi
                ;;
            *)
                # Any other exit code = ERROR
                la_errors=$((la_errors + 1))
                la_report+=("❌ $agent_label — exit code $la_exit (PID $la_pid)")
                echo "$(date): LaunchAgent ERROR: $agent_label exit=$la_exit" >> "$LOGFILE"
                ;;
        esac
    fi
done

# Add audit results to report
for line in "${la_report[@]}"; do
    report_lines+=("$line")
done

echo "$(date): LaunchAgent audit: $la_errors errors found" >> "$LOGFILE"

# Alert if core agents have errors
if [[ $la_errors -gt 0 ]]; then
    alert_send "ERROR" "agent-health" "LaunchAgent audit: $la_errors core agents with errors" "meta" 2>/dev/null
fi

# Summary telegram (always)
summary_msg="Agent Health: ${HEALTHY_COUNT}/${TOTAL_COUNT} healthy"
if [[ $STALE_COUNT -gt 0 ]]; then
    summary_msg+=", ${STALE_COUNT} stale"
fi
if [[ $MISSING_COUNT -gt 0 ]]; then
    summary_msg+=", ${MISSING_COUNT} missing"
fi
if [[ $zombies_killed -gt 0 ]]; then
    summary_msg+=", ${zombies_killed} zombies killed"
fi
summary_msg+="\nLogs: $log_size | LA: ${la_total} loaded"

send_telegram_structured "INFO" "agent-health" "$summary_msg" 2>/dev/null

echo "$(date): agent-health complete — $HEALTHY_COUNT healthy, $STALE_COUNT stale, $MISSING_COUNT missing, LA errors: $la_errors" >> "$LOGFILE"

