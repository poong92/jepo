#!/bin/bash
# perf-monitor — Track AutoTrader PnL + PRUVIQ uptime/performance
# Schedule: every 30 minutes via LaunchAgent
#
# Collects:
#   1. AutoTrader: balance, PnL, win rate, MDD, trades
#   2. PRUVIQ API: health, latency, uptime
#   3. PRUVIQ Web: response time, status
# Stores in metrics.json (rolling 14-day window)
# Generates weekly digest on Monday 00:00 UTC
# Generates monthly digest on 1st of month 00:00 UTC

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "perf-monitor"

LOGFILE="$LOG_DIR/perf-monitor.log"
METRICS_DIR="$HOME/logs/perf-monitor"
METRICS_FILE="$METRICS_DIR/metrics.json"
rotate_log "$LOGFILE"
mkdir -p "$METRICS_DIR"

AUTOTRADER_HOST="root@167.172.81.145"
AUTOTRADER_SSH_PORT=2222
AUTOTRADER_STATE="/opt/autotrader/state/bot_state.json"
PRUVIQ_API="https://api.pruviq.com"
PRUVIQ_WEB="https://pruviq.com"

# Alert thresholds
BALANCE_DROP_PCT=10
MDD_THRESHOLD=25
API_LATENCY_WARN=2000
API_LATENCY_CRIT=5000
MAX_SNAPSHOTS=672  # 14 days at 30min intervals

echo "$(date): perf-monitor started" >> "$LOGFILE"

# Rate limit
if ! rate_check "perf-monitor" "claude" >/dev/null 2>&1; then
    echo "$(date): Rate limited, skipping" >> "$LOGFILE"
    exit 0
fi

# ─── Collect: AutoTrader metrics ───
echo "$(date): Collecting AutoTrader metrics" >> "$LOGFILE"

at_status="error"
at_balance=0
at_pnl=0
at_wr=0
at_pf=0
at_mdd=0
at_trades=0

# Read bot state via SSH (no web API on DO server)
# bot_state.json has: {positions: {...}, peak_balance: float, updated_at: str}
bot_state=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$AUTOTRADER_SSH_PORT" "$AUTOTRADER_HOST" \
    "cat $AUTOTRADER_STATE 2>/dev/null" 2>/dev/null || echo "")

if [[ -n "$bot_state" ]]; then
    read at_balance at_trades at_status < <(BOT_JSON="$bot_state" python3 -c '
import os, json
try:
    d = json.loads(os.environ["BOT_JSON"])
    positions = d.get("positions", {})
    peak = d.get("peak_balance", 0)
    print(f"{peak} {len(positions)} healthy")
except Exception:
    print("0 0 error")
' 2>/dev/null || echo "0 0 error")
    echo "$(date): AutoTrader — peak_balance=$at_balance, positions=$at_trades, status=$at_status" >> "$LOGFILE"
else
    at_status="error"
    at_balance=0
    at_trades=0
    echo "$(date): AutoTrader SSH unreachable" >> "$LOGFILE"
fi

# ─── Collect: PRUVIQ API metrics ───
echo "$(date): Collecting PRUVIQ API metrics" >> "$LOGFILE"

api_status_code="000"
api_time=0

api_curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 10 "${PRUVIQ_API}/health" 2>/dev/null || echo "000 0")
api_status_code=$(echo "$api_curl_out" | awk '{print $1}')
api_time_sec=$(echo "$api_curl_out" | awk '{print $2}')
api_time=$(echo "$api_time_sec" | awk '{printf "%.0f", $1 * 1000}')

echo "$(date): PRUVIQ API — status=$api_status_code, time=${api_time}ms" >> "$LOGFILE"

# ─── Collect: PRUVIQ Web metrics ───
echo "$(date): Collecting PRUVIQ Web metrics" >> "$LOGFILE"

web_status_code="000"
web_time=0

web_curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 15 "$PRUVIQ_WEB" 2>/dev/null || echo "000 0")
web_status_code=$(echo "$web_curl_out" | awk '{print $1}')
web_time_sec=$(echo "$web_curl_out" | awk '{print $2}')
web_time=$(echo "$web_time_sec" | awk '{printf "%.0f", $1 * 1000}')

echo "$(date): PRUVIQ Web — status=$web_status_code, time=${web_time}ms" >> "$LOGFILE"

rate_increment "perf-monitor" "claude"

# ─── Build snapshot ───
snapshot="{
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"autotrader\": {
    \"peak_balance\": $at_balance,
    \"open_positions\": $at_trades,
    \"status\": \"$at_status\"
  },
  \"pruviq_api\": {
    \"status\": $api_status_code,
    \"response_time_ms\": $api_time
  },
  \"pruviq_web\": {
    \"status\": $web_status_code,
    \"response_time_ms\": $web_time
  }
}"

# ─── Append to metrics (rolling window) ───
json_append "$METRICS_FILE" "$snapshot" $MAX_SNAPSHOTS 2>/dev/null

# ─── Anomaly detection ───
anomalies=()

# AutoTrader status check (SSH-based, no MDD in bot_state.json)
if [[ "$at_status" == "error" ]]; then
    anomalies+=("AutoTrader SSH unreachable")
    alert_send "ERROR" "perf-monitor" "AutoTrader SSH unreachable" "perf" 2>/dev/null
fi

# API latency check
if [[ "$api_status_code" == "200" ]]; then
    if [[ $api_time -gt $API_LATENCY_CRIT ]]; then
        anomalies+=("API latency ${api_time}ms > ${API_LATENCY_CRIT}ms CRITICAL")
        alert_send "ERROR" "perf-monitor" "PRUVIQ API latency ${api_time}ms > ${API_LATENCY_CRIT}ms" "perf" 2>/dev/null
    elif [[ $api_time -gt $API_LATENCY_WARN ]]; then
        anomalies+=("API latency ${api_time}ms > ${API_LATENCY_WARN}ms")
        alert_send "WARNING" "perf-monitor" "PRUVIQ API latency ${api_time}ms > ${API_LATENCY_WARN}ms" "perf" 2>/dev/null
    fi
elif [[ "$api_status_code" != "000" ]]; then
    anomalies+=("API returned ${api_status_code}")
    alert_send "ERROR" "perf-monitor" "PRUVIQ API returned HTTP ${api_status_code}" "perf" 2>/dev/null
fi

# Web check
if [[ "$web_status_code" != "200" && "$web_status_code" != "000" ]]; then
    anomalies+=("Web returned ${web_status_code}")
    alert_send "ERROR" "perf-monitor" "PRUVIQ Web returned HTTP ${web_status_code}" "perf" 2>/dev/null
fi

# ─── Weekly digest (Monday 00:xx UTC) ───
day_of_week=$(date -u +%u)  # 1=Monday
hour_utc=$(date -u +%H)

DIGEST_GUARD="$METRICS_DIR/.digest-week-$(date -u +%Y%W)"
if [[ "$day_of_week" == "1" && "$hour_utc" == "00" && ! -f "$DIGEST_GUARD" ]]; then
    touch "$DIGEST_GUARD"
    echo "$(date): Generating weekly digest" >> "$LOGFILE"

    digest=$(METRICS_PATH="$METRICS_FILE" python3 << 'PYEOF'
import json, os
from datetime import datetime, timezone, timedelta

filepath = os.environ["METRICS_PATH"]
try:
    with open(filepath) as f:
        snapshots = json.load(f)
except:
    snapshots = []

# Last 7 days
cutoff = datetime.now(timezone.utc) - timedelta(days=7)
week_data = []
for s in snapshots:
    try:
        ts = datetime.fromisoformat(s["timestamp"].replace("Z", "+00:00"))
        if ts >= cutoff:
            week_data.append(s)
    except:
        continue

if not week_data:
    print("No data for weekly digest")
else:
    # Aggregate
    healthy = [s for s in week_data if s["autotrader"]["status"] == "healthy"]
    positions = [s["autotrader"].get("open_positions", 0) for s in healthy]
    api_times = [s["pruviq_api"]["response_time_ms"] for s in week_data if s["pruviq_api"]["status"] == 200]
    api_up = sum(1 for s in week_data if s["pruviq_api"]["status"] == 200)
    web_up = sum(1 for s in week_data if s["pruviq_web"]["status"] == 200)

    avg_pos = sum(positions) / len(positions) if positions else 0
    avg_api = sum(api_times) / len(api_times) if api_times else 0
    api_uptime = (api_up / len(week_data) * 100) if week_data else 0
    web_uptime = (web_up / len(week_data) * 100) if week_data else 0
    bot_uptime = (len(healthy) / len(week_data) * 100) if week_data else 0

    print(f"""Weekly Digest
Bot Uptime: {bot_uptime:.1f}% (avg {avg_pos:.0f} positions)
API Uptime: {api_uptime:.1f}% (avg {avg_api:.0f}ms)
Web Uptime: {web_uptime:.1f}%
Snapshots: {len(week_data)}""")
PYEOF
    )

    if [[ -n "$digest" && "$digest" != "No data"* ]]; then
        send_telegram_structured "INFO" "perf-monitor" "$digest" 2>/dev/null

        digest_file="$RESULTS_DIR/perf-digest-$(date +%Y%W).md"
        atomic_write "$digest_file" "# Weekly Performance Digest — $(date +%Y-%m-%d)

$digest
"
        echo "$(date): Weekly digest saved to $digest_file" >> "$LOGFILE"
    fi
fi

# ─── Monthly digest (1st of month 00:xx UTC) ───
day_of_month=$(date -u +%d)

MONTHLY_GUARD="$METRICS_DIR/.digest-month-$(date -u +%Y%m)"
if [[ "$day_of_month" == "01" && "$hour_utc" == "00" && ! -f "$MONTHLY_GUARD" ]]; then
    touch "$MONTHLY_GUARD"
    echo "$(date): Generating monthly digest" >> "$LOGFILE"

    monthly_digest=$(METRICS_PATH="$METRICS_FILE" python3 << 'PYEOF'
import json, os
from datetime import datetime, timezone, timedelta

filepath = os.environ["METRICS_PATH"]
try:
    with open(filepath) as f:
        snapshots = json.load(f)
except:
    snapshots = []

# Last 30 days
cutoff = datetime.now(timezone.utc) - timedelta(days=30)
month_data = []
for s in snapshots:
    try:
        ts = datetime.fromisoformat(s["timestamp"].replace("Z", "+00:00"))
        if ts >= cutoff:
            month_data.append(s)
    except:
        continue

if not month_data:
    print("No data for monthly digest")
else:
    # Aggregate
    healthy = [s for s in month_data if s["autotrader"]["status"] == "healthy"]
    positions = [s["autotrader"].get("open_positions", 0) for s in healthy]
    api_times = [s["pruviq_api"]["response_time_ms"] for s in month_data if s["pruviq_api"]["status"] == 200]
    web_times = [s["pruviq_web"]["response_time_ms"] for s in month_data if s["pruviq_web"]["status"] == 200]
    api_up = sum(1 for s in month_data if s["pruviq_api"]["status"] == 200)
    web_up = sum(1 for s in month_data if s["pruviq_web"]["status"] == 200)

    avg_pos = sum(positions) / len(positions) if positions else 0
    avg_api = sum(api_times) / len(api_times) if api_times else 0
    avg_web = sum(web_times) / len(web_times) if web_times else 0
    api_uptime = (api_up / len(month_data) * 100) if month_data else 0
    web_uptime = (web_up / len(month_data) * 100) if month_data else 0
    bot_uptime = (len(healthy) / len(month_data) * 100) if month_data else 0

    # Peak balance range
    balances = [s["autotrader"]["peak_balance"] for s in healthy if s["autotrader"].get("peak_balance", 0) > 0]
    bal_min = min(balances) if balances else 0
    bal_max = max(balances) if balances else 0

    prev_month = (datetime.now(timezone.utc).replace(day=1) - timedelta(days=1)).strftime("%Y-%m")

    print(f"""Monthly Digest ({prev_month})
Bot Uptime: {bot_uptime:.1f}% (avg {avg_pos:.0f} positions)
Peak Balance: ${bal_min:,.0f} ~ ${bal_max:,.0f}
API Uptime: {api_uptime:.1f}% (avg {avg_api:.0f}ms)
Web Uptime: {web_uptime:.1f}% (avg {avg_web:.0f}ms)
Snapshots: {len(month_data)} ({len(month_data)/48:.0f} days)""")
PYEOF
    )

    if [[ -n "$monthly_digest" && "$monthly_digest" != "No data"* ]]; then
        prev_ym=$(date -u -v-1d +%Y%m 2>/dev/null || date -u -d "yesterday" +%Y%m 2>/dev/null || date -u +%Y%m)
        send_telegram_structured "INFO" "perf-monitor" "$monthly_digest" 2>/dev/null

        monthly_file="$RESULTS_DIR/perf-digest-monthly-${prev_ym}.md"
        atomic_write "$monthly_file" "# Monthly Performance Digest — $(date +%Y-%m-%d)

$monthly_digest
"
        echo "$(date): Monthly digest saved to $monthly_file" >> "$LOGFILE"
    fi
fi

# ─── Summary ───
anomaly_str=""
if [[ ${#anomalies[@]} -gt 0 ]]; then
    anomaly_str=" | Anomalies: ${anomalies[*]}"
fi

echo "$(date): perf-monitor complete — AT:${at_status} API:${api_status_code}(${api_time}ms) Web:${web_status_code}(${web_time}ms)${anomaly_str}" >> "$LOGFILE"
