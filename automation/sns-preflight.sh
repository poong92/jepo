#!/bin/bash
# sns-preflight.sh — SNS 파이프라인 사전 점검
# KST 08:30 실행 (ranking 09:00, recap 10:00 전)
#
# 점검 항목:
#   1. Python 패키지 (requests, requests-oauthlib)
#   2. X/Twitter API 연결
#   3. Threads API 연결
#   4. Telegram 봇 3개 발송
#   5. PRUVIQ API /rankings/daily 응답
#   6. 스크립트 파일 존재 + 실행권한
#   7. 큐 디렉토리 쓰기 가능
#   8. quality-checker.py 문법 정상

source "$(dirname "$0")/claude-runner.sh"
set +e  # preflight는 개별 점검 실패해도 전체 스크립트 계속 실행

LOGFILE="$LOG_DIR/sns-preflight.log"
rotate_log "$LOGFILE"

PYTHON3="${HOME}/pruviq/backend/.venv/bin/python3"
QUEUE_DIR="$HOME/scripts/social/queue"
SOCIAL_DIR="$HOME/scripts/social"

pass=0
fail=0
issues=()

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ): $1" >> "$LOGFILE"; }
check_pass() { log "✅ $1"; pass=$((pass+1)); }
check_fail() { log "❌ $1"; fail=$((fail+1)); issues+=("$1"); }

log "=== SNS Preflight started ==="

# ── 1. Python 패키지 ──────────────────────────────────────────
$PYTHON3 -c "import requests" 2>/dev/null \
    && check_pass "python: requests OK" \
    || check_fail "python: requests 없음 → pip install requests"

$PYTHON3 -c "from requests_oauthlib import OAuth1Session" 2>/dev/null \
    && check_pass "python: requests-oauthlib OK" \
    || check_fail "python: requests-oauthlib 없음 → pip install requests-oauthlib"

# ── 2. X/Twitter API ──────────────────────────────────────────
X_API_KEY=$(security find-generic-password -a "pruviq" -s "x-api-key" -w 2>/dev/null) || true
X_API_SECRET=$(security find-generic-password -a "pruviq" -s "x-api-secret" -w 2>/dev/null) || true
X_ACCESS_TOKEN=$(security find-generic-password -a "pruviq" -s "x-access-token" -w 2>/dev/null) || true
X_ACCESS_SECRET=$(security find-generic-password -a "pruviq" -s "x-access-secret" -w 2>/dev/null) || true

if [[ -z "$X_API_KEY" || -z "$X_API_SECRET" || -z "$X_ACCESS_TOKEN" || -z "$X_ACCESS_SECRET" ]]; then
    check_fail "X: Keychain 크리덴셜 누락"
else
    x_status=$(TWITTER_API_KEY="$X_API_KEY" \
        TWITTER_API_SECRET="$X_API_SECRET" \
        TWITTER_ACCESS_TOKEN="$X_ACCESS_TOKEN" \
        TWITTER_ACCESS_SECRET="$X_ACCESS_SECRET" \
        $PYTHON3 -c "
import os
from requests_oauthlib import OAuth1Session
try:
    oauth = OAuth1Session(os.environ['TWITTER_API_KEY'], os.environ['TWITTER_API_SECRET'],
                          os.environ['TWITTER_ACCESS_TOKEN'], os.environ['TWITTER_ACCESS_SECRET'])
    r = oauth.get('https://api.twitter.com/2/users/me', timeout=10)
    print(r.status_code)
except Exception as e:
    print('error')
" 2>/dev/null)
    [[ "$x_status" == "200" ]] \
        && check_pass "X API 연결 OK (@pruviq)" \
        || check_fail "X API 연결 실패 (status=$x_status) — 토큰 만료?"
fi

# ── 3. Threads API ────────────────────────────────────────────
THREADS_TOKEN=$(security find-generic-password -a "pruviq" -s "threads-access-token" -w 2>/dev/null) || true
if [[ -z "$THREADS_TOKEN" ]]; then
    source "${HOME}/.secrets.env" 2>/dev/null || true
    THREADS_TOKEN="${THREADS_ACCESS_TOKEN:-}"
fi

if [[ -z "$THREADS_TOKEN" ]]; then
    check_fail "Threads: 토큰 없음"
else
    threads_status=$(ACCESS_TOKEN="$THREADS_TOKEN" $PYTHON3 -c "
import os, urllib.request
try:
    token = os.environ['ACCESS_TOKEN']
    url = f'https://graph.threads.net/v1.0/me?fields=id,username&access_token={token}'
    r = urllib.request.urlopen(url, timeout=10)
    print(r.status)
except Exception as e:
    print('error')
" 2>/dev/null)
    [[ "$threads_status" == "200" ]] \
        && check_pass "Threads API 연결 OK" \
        || check_fail "Threads API 연결 실패 (status=$threads_status) — 토큰 만료?"
fi

# ── 4. Telegram 봇 3개 ────────────────────────────────────────
source ~/.secrets.env 2>/dev/null || true

for bot_info in \
    "SNS승인봇|${TELEGRAM_APPROVAL_BOT_TOKEN:-}" \
    "Alert봇|${TELEGRAM_ALERT_BOT_TOKEN:-}" \
    "AI봇|${TELEGRAM_TOKEN:-}"; do
    bot_name="${bot_info%%|*}"
    bot_token="${bot_info#*|}"
    if [[ -z "$bot_token" ]]; then
        check_fail "Telegram $bot_name: 토큰 없음"
        continue
    fi
    tg_ok=$(curl -sf --max-time 5 "https://api.telegram.org/bot${bot_token}/getMe" 2>/dev/null | $PYTHON3 -c "import json,sys; print('ok' if json.load(sys.stdin).get('ok') else 'fail')" 2>/dev/null)
    [[ "$tg_ok" == "ok" ]] \
        && check_pass "Telegram $bot_name OK" \
        || check_fail "Telegram $bot_name 연결 실패"
done

# ── 5. PRUVIQ API ─────────────────────────────────────────────
api_status=$(curl -sf --max-time 10 "https://api.pruviq.com/rankings/daily" 2>/dev/null | $PYTHON3 -c "
import json, sys
d = json.load(sys.stdin)
top3 = d.get('top3', [])
print('ok' if top3 else 'empty')
" 2>/dev/null)
[[ "$api_status" == "ok" ]] \
    && check_pass "PRUVIQ API /rankings/daily OK" \
    || check_fail "PRUVIQ API 응답 이상 (status=$api_status)"

# ── 6. 스크립트 파일 존재 + 실행권한 ─────────────────────────
for script in \
    "$HOME/scripts/run_daily_ranking.sh" \
    "$HOME/scripts/claude-auto/daily-strategy-recap.sh" \
    "$HOME/scripts/claude-auto/quality-checker.py" \
    "$HOME/scripts/claude-auto/telegram-approval-poller.sh"; do
    if [[ ! -f "$script" ]]; then
        check_fail "파일 없음: $(basename $script)"
    elif [[ ! -x "$script" ]] && [[ "$script" == *.sh ]]; then
        check_fail "실행권한 없음: $(basename $script)"
    else
        check_pass "파일 OK: $(basename $script)"
    fi
done

# ── 7. 큐 디렉토리 쓰기 가능 ─────────────────────────────────
mkdir -p "$QUEUE_DIR" 2>/dev/null || true
touch "$QUEUE_DIR/.preflight_test" 2>/dev/null \
    && { rm -f "$QUEUE_DIR/.preflight_test"; check_pass "queue 디렉토리 쓰기 OK"; } \
    || check_fail "queue 디렉토리 쓰기 불가: $QUEUE_DIR"

# ── 8. quality-checker.py 문법 ────────────────────────────────
$PYTHON3 -m py_compile "$HOME/scripts/claude-auto/quality-checker.py" 2>/dev/null \
    && check_pass "quality-checker.py 문법 OK" \
    || check_fail "quality-checker.py 문법 오류"

# ── 결과 보고 ─────────────────────────────────────────────────
log "=== 결과: ${pass}개 통과 / ${fail}개 실패 ==="

if [[ $fail -eq 0 ]]; then
    send_telegram_structured "INFO" "sns-preflight" "✅ SNS 파이프라인 점검 완료 — 전항목 통과 (${pass}개). ranking 09:00 / recap 10:00 예정." 2>/dev/null
else
    issue_list=$(printf '%s\n' "${issues[@]}" | head -5 | sed 's/^/• /')
    send_telegram_structured "ERROR" "sns-preflight" "❌ SNS Preflight ${fail}개 실패\n${issue_list}\n\n→ 10:00 recap 실행 전 수동 확인 필요" 2>/dev/null
fi

log "=== SNS Preflight complete ==="
