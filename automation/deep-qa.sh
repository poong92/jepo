#!/bin/bash
# Deep QA - comprehensive site quality check for pruviq.com
# Schedule: daily at KST 15:00 (UTC 06:00) via LaunchAgent
#
# SECURITY:
#   - Claude restricted to Read, WebFetch, Glob, Grep only.
#   - No Bash, no Write, no file modification capability.
#   - Results written to a local file for human review.
#   - flock prevents concurrent execution.

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "deep-qa"

LOGFILE="$LOG_DIR/deep-qa.log"
RESULT_DIR="$HOME/logs/claude-auto/results"
rotate_log "$LOGFILE"
mkdir -p "$RESULT_DIR"

echo "$(date): Deep QA started" >> "$LOGFILE"

if ! check_auth; then
    echo "$(date): Auth failed, aborting" >> "$LOGFILE"
    exit 1
fi

RESULT_FILE="$RESULT_DIR/deep-qa-$(date +%Y%m%d).md"

# SECURITY: Only allow Read, WebFetch, Glob, Grep - no Bash, no Write
review=$(claude --model "$MODEL_OPUS" -p "You are a QA engineer for PRUVIQ (https://pruviq.com).

IMPORTANT URL MAPPING:
- Website pages: https://pruviq.com/ (homepage), /simulate, /strategies, /performance, /market, /coins, /fees, /learn
- API base: https://api.pruviq.com (NOT pruviq.com/api/)
- API endpoints: /health, /market, /news, /macro, /coins/stats

Run a comprehensive check:
1. Verify homepage loads correctly (https://pruviq.com)
2. Check API health: https://api.pruviq.com/health
3. Check API market data: https://api.pruviq.com/market (verify coins count > 0)
4. Verify key pages: /simulate, /strategies, /performance
5. Check data freshness via https://pruviq.com/data/market.json (btc_price should exist)
6. Report any real errors or anomalies

CRITICAL RULES:
- Do NOT test URLs that don't exist (e.g., /api/*, /simulator, /backtest)
- Only report ACTIONABLE findings — skip informational notes
- Use PASS/FAIL/WARN consistently
- Do NOT mark WebFetch limitations as failures

Output a structured report in markdown format.
Do NOT execute any system commands or modify any files." \
    --allowedTools "Read,WebFetch,Glob,Grep" \
    --max-turns 15 2>&1)

echo "$review" > "$RESULT_FILE"
echo "$(date): Deep QA complete -> $RESULT_FILE" >> "$LOGFILE"

# Extract pass/fail summary for Telegram notification
pass_count=$(echo "$review" | grep -ci "pass\|ok" || echo 0)
fail_count=$(echo "$review" | grep -ci "fail\|error" || echo 0)
send_telegram "<b>Deep QA:</b> ${pass_count} pass, ${fail_count} issues -> $RESULT_FILE"
