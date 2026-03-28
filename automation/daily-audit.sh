#!/bin/bash
# Daily audit - security and quality audit for pruviq.com
# Schedule: daily at KST 12:00 (UTC 03:00) via LaunchAgent
#
# SECURITY:
#   - Claude restricted to Read, WebFetch, Glob, Grep only.
#   - No Bash, no Write, no command execution capability.
#   - Results written to a local file for human review.
#   - flock prevents concurrent execution.

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "daily-audit"

LOGFILE="$LOG_DIR/daily-audit.log"
RESULT_DIR="$HOME/logs/claude-auto/results"
rotate_log "$LOGFILE"
mkdir -p "$RESULT_DIR"

echo "$(date): Daily audit started" >> "$LOGFILE"

if ! check_auth; then
    echo "$(date): Auth failed, aborting" >> "$LOGFILE"
    exit 1
fi

RESULT_FILE="$RESULT_DIR/daily-audit-$(date +%Y%m%d).md"

# SECURITY: Only allow Read, WebFetch, Glob, Grep
audit=$(claude --model "$MODEL_OPUS" -p "You are a security and quality auditor for PRUVIQ (https://pruviq.com).

IMPORTANT CONTEXT:
- Website: https://pruviq.com (Cloudflare Workers, Astro SSG)
- API: https://api.pruviq.com (FastAPI on Mac Mini behind CF Tunnel)
- Security headers (CSP, HSTS, X-Frame-Options) are configured at Cloudflare level
- WebFetch cannot read HTTP response headers — do NOT mark headers as missing/FAIL

Perform daily audit:
1. Verify homepage and key pages load (https://pruviq.com, /simulate, /strategies)
2. Check API health: https://api.pruviq.com/health
3. Data freshness: https://pruviq.com/data/market.json (btc_price should exist and be recent)
4. Check for visible vulnerabilities (info leakage, exposed credentials, broken links)
5. Compare with previous audit if available at ~/logs/claude-auto/results/

CRITICAL RULES:
- Do NOT report security headers as missing — WebFetch cannot verify HTTP headers
- Do NOT report SSL details you cannot verify — Cloudflare manages certificates
- Only report ACTIONABLE, VERIFIED findings — not theoretical concerns
- Mark unverifiable items as INFO, not FAIL or WARN

Output a structured audit report in markdown.
Rate overall health: A/B/C/D/F
Do NOT execute any system commands or modify any files." \
    --allowedTools "Read,WebFetch,Glob,Grep" \
    --max-turns 15 2>&1)

echo "$audit" > "$RESULT_FILE"
echo "$(date): Daily audit complete -> $RESULT_FILE" >> "$LOGFILE"

grade=$(echo "$audit" | grep -oE "Grade: [A-F]|Overall: [A-F]|Health: [A-F]" | head -1 || echo "Grade: ?")
send_telegram "<b>Daily Audit:</b> $grade -> $RESULT_FILE"
