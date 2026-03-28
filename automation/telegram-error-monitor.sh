#!/bin/bash
# telegram-error-monitor.sh
# Polls Telegram Alert bot for new error messages, triggers Claude auto-diagnosis,
# and replies to Telegram with the investigation result.
#
# How it works:
#   1. getUpdates on PRUVIQ Alert bot (8057086954) for messages since last_update_id
#   2. Filter messages matching error patterns (🚨 ❌ ERROR FAIL CRITICAL)
#   3. For each new error: run `claude -p "diagnose: <message>"` in /Users/jepo/pruviq
#   4. Post diagnosis result back to Telegram
#   5. Save last_update_id to state file to avoid re-processing
#
# Cron: every 5 minutes via LaunchAgent
#   Label: com.jepo.telegram-error-monitor
#   ProgramArguments: ["/bin/bash", "/path/to/telegram-error-monitor.sh"]
#   StartInterval: 300

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/claude-runner.sh"

# --- Config ---
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
STATE_FILE="$LOG_DIR/telegram-monitor-state.json"
LOG_FILE="$LOG_DIR/telegram-error-monitor.log"
MAX_ERRORS_PER_RUN=3       # Cap Claude calls per run to avoid cost blowup
CLAUDE_TIMEOUT=120         # seconds per diagnosis

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set" >> "$LOG_FILE"
    exit 0
fi

acquire_lock "telegram-error-monitor"

# --- Error patterns to trigger diagnosis ---
# Must match strings that indicate a system problem (not routine info messages)
ERROR_PATTERNS=(
    "🚨"
    "❌"
    "CRITICAL"
    "FAIL"
    " ERROR"
    "Cannot fetch"
    "API DOWN"
    "OFFLINE"
    "exception"
    "Traceback"
)

# --- Load state (last processed update_id) ---
LAST_UPDATE_ID=0
if [[ -f "$STATE_FILE" ]]; then
    LAST_UPDATE_ID=$(python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('last_update_id', 0))
except:
    print(0)
" 2>/dev/null || echo 0)
fi

# --- Fetch new updates ---
UPDATES_JSON=$(curl -sf \
    "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=$((LAST_UPDATE_ID + 1))&limit=50&timeout=5" \
    2>/dev/null || echo '{"ok":false}')

OK=$(echo "$UPDATES_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok','false'))" 2>/dev/null || echo "false")
if [[ "$OK" != "True" && "$OK" != "true" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) WARN: getUpdates failed" >> "$LOG_FILE"
    exit 0
fi

# --- Parse messages and filter errors ---
NEW_LAST_ID=$LAST_UPDATE_ID
ERRORS_FOUND=0

# Extract message list as JSON lines
# Note: env var avoids heredoc+pipe stdin conflict (<<'PYEOF' overrides pipe stdin)
MESSAGES=$(_TG_JSON="$UPDATES_JSON" python3 <<'PYEOF'
import json, os, sys

raw = os.environ.get("_TG_JSON", "")
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    data = {}
results = data.get("result", [])
for item in results:
    update_id = item.get("update_id", 0)
    msg = item.get("message") or item.get("channel_post") or {}
    text = msg.get("text", "")
    date = msg.get("date", 0)
    if text:
        print(json.dumps({"update_id": update_id, "text": text, "date": date}))
PYEOF
)

if [[ -z "$MESSAGES" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) OK: No new messages (last_id=$LAST_UPDATE_ID)" >> "$LOG_FILE"
    exit 0
fi

# --- Process each message ---
while IFS= read -r MSG_LINE; do
    [[ -z "$MSG_LINE" ]] && continue

    UPDATE_ID=$(echo "$MSG_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('update_id',0))" 2>/dev/null || echo 0)
    TEXT=$(echo "$MSG_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('text',''))" 2>/dev/null || echo "")

    # Track highest update_id seen
    if [[ "$UPDATE_ID" -gt "$NEW_LAST_ID" ]]; then
        NEW_LAST_ID=$UPDATE_ID
    fi

    # Check if this message matches any error pattern
    IS_ERROR=false
    for pattern in "${ERROR_PATTERNS[@]}"; do
        if echo "$TEXT" | grep -q "$pattern"; then
            IS_ERROR=true
            break
        fi
    done

    [[ "$IS_ERROR" == "false" ]] && continue
    [[ "$ERRORS_FOUND" -ge "$MAX_ERRORS_PER_RUN" ]] && continue

    ERRORS_FOUND=$((ERRORS_FOUND + 1))
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR_DETECTED [update=$UPDATE_ID]: ${TEXT:0:100}" >> "$LOG_FILE"

    # --- Run Claude diagnosis ---
    DIAGNOSIS=""
    PROMPT="당신은 PRUVIQ 시스템 모니터링 AI입니다.
다음 텔레그램 에러 알림을 분석하고, 가능한 원인과 즉시 확인해야 할 조치를 3줄 이내로 한국어로 답하세요.
실제 파일/API를 읽어서 현재 상태를 확인하세요.

에러 메시지:
${TEXT}

작업 디렉토리: /Users/jepo/pruviq
답변 형식:
1. 원인 (1줄)
2. 현재 상태 확인 결과
3. 권장 조치"

    if DIAGNOSIS=$(timeout "$CLAUDE_TIMEOUT" claude --model "$MODEL_OPUS" -p "$PROMPT" \
        --allowedTools "Bash,Read,Grep,Glob" \
        --output-format text \
        2>/dev/null); then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DIAGNOSED [update=$UPDATE_ID]" >> "$LOG_FILE"
    else
        DIAGNOSIS="진단 실패: Claude 타임아웃 또는 실행 오류"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DIAGNOSIS_FAILED [update=$UPDATE_ID]" >> "$LOG_FILE"
    fi

    # --- Reply to Telegram ---
    REPLY_TEXT="🤖 <b>자동 진단 결과</b>

<b>원본 에러:</b>
<code>${TEXT:0:200}</code>

<b>진단:</b>
${DIAGNOSIS:0:800}

<i>자동 진단 by JEPO | $(date -u +%Y-%m-%d\ %H:%M)\ UTC</i>"

    curl -sf -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${REPLY_TEXT}" \
        2>/dev/null >> "$LOG_FILE" || true

done <<< "$MESSAGES"

# --- Save updated state ---
python3 -c "
import json
data = {'last_update_id': $NEW_LAST_ID, 'updated_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'}
with open('$STATE_FILE', 'w') as f:
    json.dump(data, f)
" 2>/dev/null || true

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) DONE: processed errors=$ERRORS_FOUND, new_last_id=$NEW_LAST_ID" >> "$LOG_FILE"

