#!/bin/bash
# Social content generator - creates tweets for PRUVIQ social media
# Schedule: every 6 hours via LaunchAgent
#
# SECURITY FIXES (vs original):
#   1. Claude restricted to --allowedTools "Read" only.
#      No Bash, no Write, no network - Claude generates text only.
#   2. JSON file creation uses Python json.dump() instead of f-string interpolation.
#      This eliminates JSON code injection via crafted Claude output.
#   3. Output is sanitized: control chars stripped, length capped at 280 chars.
#   4. Content status is "pending_approval" - requires human review before posting.
#   5. flock prevents concurrent execution.

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "social-generate"

LOGFILE="$LOG_DIR/social-generate.log"
QUEUE_DIR="$HOME/scripts/social/queue"
rotate_log "$LOGFILE"
mkdir -p "$QUEUE_DIR"

echo "$(date): Social content generation started" >> "$LOGFILE"

if ! check_auth; then
    echo "$(date): Auth failed, aborting" >> "$LOGFILE"
    exit 1
fi

# Fetch market data safely (these are public API calls, not user-controlled)
BTC_PRICE=$(curl -s --max-time 10 "https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('price','N/A'))" 2>/dev/null || echo "N/A")
ETH_PRICE=$(curl -s --max-time 10 "https://api.binance.com/api/v3/ticker/price?symbol=ETHUSDT" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('price','N/A'))" 2>/dev/null || echo "N/A")

# SECURITY: Only allow Read - no Bash, no Write, no network tools
# Claude generates text only; we handle JSON serialization ourselves.
content=$(claude --model "$MODEL_SONNET" -p "You are PRUVIQ's social media manager.
Generate 1 tweet about crypto markets.

Current prices: BTC \$$BTC_PRICE, ETH \$$ETH_PRICE

Rules:
- Max 280 characters
- Include 1-2 relevant hashtags
- Professional, data-driven tone
- No financial advice

Output ONLY the tweet text, nothing else." \
    --allowedTools "Read" \
    --max-turns 1 2>&1)

# Detect Claude errors (auth failures, rate limits, etc.)
if echo "$content" | grep -qiE "error|exception|unauthorized|rate.limit|ECONNREFUSED|timed.out|APIError"; then
    echo "$(date): Claude returned error, not queuing: ${content:0:200}" >> "$LOGFILE"
    exit 0
fi

if [[ -n "$content" && ${#content} -gt 10 && ${#content} -lt 500 ]]; then
    # Sanitize: strip control characters, cap at 280 chars
    clean_content=$(echo "$content" | tr -d '\000-\010\013\014\016-\037' | head -c 280)

    # SECURITY: Use Python json.dump for safe JSON serialization.
    # The content is piped via stdin - NEVER interpolated into a string.
    QUEUE_FILE="$QUEUE_DIR/$(date +%Y%m%d-%H%M%S)-x.json"
    GENERATED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    QUEUE_PATH="$QUEUE_FILE" GEN_TS="$GENERATED_TS" python3 -c "
import json, sys, os

content = sys.stdin.read().strip()
data = {
    'platform': 'x',
    'content': content,
    'generated': os.environ['GEN_TS'],
    'status': 'pending_approval'
}
with open(os.environ['QUEUE_PATH'], 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
" <<< "$clean_content"

    echo "$(date): Content queued -> $QUEUE_FILE" >> "$LOGFILE"
    send_telegram "<b>Social content queued</b> for approval"
else
    echo "$(date): Content generation failed or invalid length (${#content} chars)" >> "$LOGFILE"
fi
