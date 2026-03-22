#!/bin/bash
# JEPO Cost Daily Report
# Summarizes daily token usage + cost -> notification

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/cost-tracker.sh"

TOKEN_LOG="$HOME/logs/claude-auto/token-usage.jsonl"
LOGFILE="$LOG_DIR/cost-report.log"

log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

[ -f "$TOKEN_LOG" ] || { log "No token log"; exit 0; }

report=$(python3 -c "
import json
from datetime import date, timedelta

today = str(date.today())
week_ago = str(date.today() - timedelta(days=7))

by_agent = {}
by_model = {}
total_cost = 0
total_input = 0
total_output = 0
week_total = 0

with open('$TOKEN_LOG') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            ts_date = e.get('ts','')[:10]
            cost = float(e.get('cost_usd', 0))

            if ts_date >= week_ago:
                week_total += cost

            if ts_date != today:
                continue

            total_cost += cost
            total_input += int(e.get('input', 0))
            total_output += int(e.get('output', 0))

            agent = e.get('agent', 'unknown')
            by_agent[agent] = by_agent.get(agent, 0) + cost

            model = e.get('model', 'unknown')
            by_model[model] = by_model.get(model, 0) + cost
        except:
            pass

week_avg = week_total / 7 if week_total > 0 else 0

print(f'JEPO Cost Report {today}')
print(f'Total: \${total_cost:.2f} (in:{total_input//1000}K out:{total_output//1000}K)')
print()
if by_agent:
    print('By agent:')
    for a, c in sorted(by_agent.items(), key=lambda x: -x[1])[:5]:
        print(f'  {a}: \${c:.2f}')
    print()
if by_model:
    print('By model:')
    for m, c in sorted(by_model.items(), key=lambda x: -x[1]):
        print(f'  {m.split(\"-\")[-1] if \"-\" in m else m}: \${c:.2f}')
print(f'7-day avg: \${week_avg:.2f}/day')
" 2>/dev/null)

if [ -n "$report" ]; then
    send_telegram "$report" 2>/dev/null || echo "$report"
    log "$report"
fi

rotate_token_log
