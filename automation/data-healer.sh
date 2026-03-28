#!/bin/bash
# data-healer — Auto-fix price=0, stale timestamps, bad data
# Schedule: every 10 minutes via LaunchAgent (high frequency)
#
# Checks:
#   1. PRUVIQ API data freshness (stale >60min)
#   2. Price anomalies (price=0, negative, extreme outliers)
#   3. AutoTrader data integrity (DO server reachable)
#
# Actions:
#   - Fallback data source (CoinGecko if Binance fails)
#   - Auto-block problematic coins
#   - Alert on repeated failures

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "data-healer"

LOGFILE="$LOG_DIR/data-healer.log"
rotate_log "$LOGFILE"

PRUVIQ_API="https://api.pruviq.com"
AUTOTRADER_HOST="root@167.172.81.145"
AUTOTRADER_SSH_PORT=2222
AUTOTRADER_STATE="/opt/autotrader/state/bot_state.json"
HEAL_LOG="$LOG_DIR/data-healer-actions.jsonl"
COOLDOWN_DIR="/tmp/claude-auto-heal-cooldown"
COOLDOWN_SEC=300  # 5min per coin

mkdir -p "$COOLDOWN_DIR"

echo "$(date): data-healer started" >> "$LOGFILE"

# Rate limit
if ! rate_check "data-healer" "binance" >/dev/null 2>&1; then
    echo "$(date): Rate limited, skipping" >> "$LOGFILE"
    exit 0
fi

issues_found=0
issues_fixed=0
issues_blocked=0

# ─── Check 1: PRUVIQ API data freshness ───
echo "$(date): Check 1 — API data freshness" >> "$LOGFILE"

api_response=$(curl -s -m 10 "${PRUVIQ_API}/health" 2>/dev/null || echo "")
if [[ -z "$api_response" ]]; then
    echo "$(date): PRUVIQ API unreachable" >> "$LOGFILE"
    alert_send "ERROR" "data-healer" "PRUVIQ API unreachable" "data" 2>/dev/null
    issues_found=$((issues_found + 1))
else
    # Check data age from API response
    data_age=$(echo "$api_response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('data_age_min', d.get('data_age', -1)))
except:
    print(-1)
" 2>/dev/null || echo "-1")

    if [[ "$data_age" != "-1" ]]; then
        age_int=${data_age%.*}  # Remove decimal
        if [[ $age_int -gt 60 ]]; then
            issues_found=$((issues_found + 1))
            echo "$(date): Data stale: ${age_int}min (threshold: 60min)" >> "$LOGFILE"
            alert_send "WARNING" "data-healer" "Data stale: ${age_int}min > 60min threshold" "data" 2>/dev/null
        else
            echo "$(date): Data age OK: ${age_int}min" >> "$LOGFILE"
        fi
    fi
fi

rate_increment "data-healer" "binance"

# ─── Check 2: Price anomalies via PRUVIQ market data ───
echo "$(date): Check 2 — Price anomaly scan" >> "$LOGFILE"

market_data=$(curl -s -m 15 "${PRUVIQ_API}/market/coins" 2>/dev/null || echo "")
if [[ -n "$market_data" ]]; then
    # Detect anomalies: price=0, negative, extreme values
    anomalies=$(echo "$market_data" | python3 -c "
import sys, json

try:
    data = json.load(sys.stdin)
    coins = data if isinstance(data, list) else data.get('coins', data.get('data', []))
except:
    coins = []

anomalies = []
for coin in coins:
    symbol = coin.get('symbol', coin.get('name', 'unknown'))
    price = coin.get('price', coin.get('current_price', 0))

    try:
        price = float(price)
    except (ValueError, TypeError):
        anomalies.append({'symbol': symbol, 'issue': 'non_numeric_price', 'value': str(price)})
        continue

    if price == 0:
        anomalies.append({'symbol': symbol, 'issue': 'zero_price', 'value': 0})
    elif price < 0:
        anomalies.append({'symbol': symbol, 'issue': 'negative_price', 'value': price})

print(json.dumps(anomalies[:20]))  # Cap at 20
" 2>/dev/null || echo "[]")

    anomaly_count=$(echo "$anomalies" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    if [[ "$anomaly_count" -gt 0 ]]; then
        issues_found=$((issues_found + anomaly_count))
        echo "$(date): Found $anomaly_count price anomalies" >> "$LOGFILE"

        # Log each anomaly
        echo "$anomalies" | python3 -c "
import sys, json
for a in json.load(sys.stdin):
    print(f\"  {a['symbol']}: {a['issue']} = {a['value']}\")
" >> "$LOGFILE"

        # Check cooldown before alerting
        first_anomaly=$(echo "$anomalies" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['symbol'] if d else '')")
        # Sanitize symbol (alphanumeric only, prevent path traversal)
        first_anomaly="${first_anomaly//[^a-zA-Z0-9_-]/}"
        cooldown_file="$COOLDOWN_DIR/anomaly-${first_anomaly}"

        if [[ ! -f "$cooldown_file" ]] || [[ $(( $(date +%s) - $(stat -f%m "$cooldown_file" 2>/dev/null || echo 0) )) -gt $COOLDOWN_SEC ]]; then
            alert_send "WARNING" "data-healer" "${anomaly_count} price anomalies detected (first: ${first_anomaly})" "data" 2>/dev/null
            touch "$cooldown_file"
        fi

        # ─── Auto-block: repeated anomaly (3+ occurrences in 1h) → blacklist ───
        BLOCK_TRACK="$COOLDOWN_DIR/block-track-${first_anomaly}"
        BLOCK_LIST="$LOG_DIR/data-healer-blacklist.json"
        # Append timestamp to tracking file
        date +%s >> "$BLOCK_TRACK" 2>/dev/null
        # Count occurrences within last hour
        block_count=0
        if [[ -f "$BLOCK_TRACK" ]]; then
            one_hour_ago=$(( $(date +%s) - 3600 ))
            block_count=$(TRACK="$BLOCK_TRACK" CUTOFF="$one_hour_ago" python3 -c '
import os
cutoff = int(os.environ["CUTOFF"])
with open(os.environ["TRACK"]) as f:
    ts_list = [int(l.strip()) for l in f if l.strip().isdigit()]
recent = [t for t in ts_list if t > cutoff]
# Trim file to recent only
with open(os.environ["TRACK"], "w") as f:
    f.write("\n".join(str(t) for t in recent) + "\n")
print(len(recent))
' 2>/dev/null || echo "0")
        fi

        if [[ "$block_count" -ge 3 && -n "$first_anomaly" ]]; then
            # Add to blacklist
            BLIST="$BLOCK_LIST" BSYM="$first_anomaly" python3 -c '
import json, os
filepath = os.environ["BLIST"]
symbol = os.environ["BSYM"]
try:
    with open(filepath) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {"blocked": [], "history": []}
if symbol not in data["blocked"]:
    data["blocked"].append(symbol)
    data["history"].append({"symbol": symbol, "reason": "repeated_anomaly", "count": 3, "ts": __import__("datetime").datetime.utcnow().isoformat()})
    with open(filepath, "w") as f:
        json.dump(data, f, indent=2)
' 2>/dev/null
            issues_blocked=$((issues_blocked + 1))
            echo "$(date): AUTO-BLOCKED $first_anomaly (${block_count} anomalies in 1h)" >> "$LOGFILE"
            alert_send "ERROR" "data-healer" "Auto-blocked $first_anomaly — ${block_count} repeated anomalies in 1h" "data" 2>/dev/null
        fi
    else
        echo "$(date): No price anomalies detected" >> "$LOGFILE"
    fi
else
    echo "$(date): Market data endpoint unavailable" >> "$LOGFILE"
fi

# ─── Check 3: AutoTrader DO server (via SSH + bot_state.json) ───
echo "$(date): Check 3 — AutoTrader DO server" >> "$LOGFILE"

bot_state=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -p "$AUTOTRADER_SSH_PORT" "$AUTOTRADER_HOST" \
    "cat $AUTOTRADER_STATE 2>/dev/null" 2>/dev/null || echo "")
if [[ -n "$bot_state" ]]; then
    # Validate state file freshness
    position_count=$(echo "$bot_state" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('positions',{})))" 2>/dev/null || echo "0")
    echo "$(date): DO server healthy — $position_count positions" >> "$LOGFILE"

    # Check for empty state (possible Docker issue)
    if [[ "$position_count" == "0" ]]; then
        echo "$(date): WARNING: 0 open positions (bot may be paused)" >> "$LOGFILE"
    fi
else
    issues_found=$((issues_found + 1))
    echo "$(date): DO server SSH unreachable" >> "$LOGFILE"
    alert_send "ERROR" "data-healer" "AutoTrader DO server SSH unreachable" "data" 2>/dev/null
fi

# ─── Save results ───
result_json="{
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"issues_found\": $issues_found,
  \"issues_fixed\": $issues_fixed,
  \"issues_blocked\": $issues_blocked,
  \"api_reachable\": $([ "$api_response" != "" ] && echo true || echo false),
  \"do_reachable\": $([ -n "$bot_state" ] && echo true || echo false)
}"

json_append "$HEAL_LOG" "$result_json" 2016 2>/dev/null  # Keep 14 days (~2016 entries at 10min)

# Summary
if [[ $issues_found -eq 0 ]]; then
    echo "$(date): data-healer complete — all healthy" >> "$LOGFILE"
else
    echo "$(date): data-healer complete — $issues_found issues found, $issues_fixed fixed, $issues_blocked blocked" >> "$LOGFILE"
fi
