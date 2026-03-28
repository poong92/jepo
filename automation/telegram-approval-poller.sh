#!/bin/bash
# Telegram Poller — SNS 승인 + Alert bot 명령 채널
# 2분마다 실행:
#   Bot 1 (SNS/Approval): callback_query 처리 (승인/거절 버튼)
#   Bot 2 (Alert):        text message 처리 (사용자 명령 → 자동 수정)
set -euo pipefail

export HOME="/Users/jepo"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
source "$HOME/.secrets.env" 2>/dev/null || true

# 종료 시 임시파일 정리 (잔여 파일로 mktemp 충돌 방지)
cleanup() { rm -f /tmp/tg-updates-*.json /tmp/tg-alert-* 2>/dev/null; }
trap cleanup EXIT

QUEUE_DIR="$HOME/scripts/social/queue"
FAILED_DIR="$HOME/scripts/social/failed"
OFFSET_FILE="$HOME/scripts/social/.tg-approval-offset"
ALERT_OFFSET_FILE="$HOME/scripts/social/.tg-alert-offset"
LOG="$HOME/logs/claude-auto/telegram-approval-poller.log"

mkdir -p "$(dirname "$LOG")" "$FAILED_DIR"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }

# ── Bot 1: SNS 승인 (callback_query) ────────────────────────────────────────
SNS_TOKEN="${TELEGRAM_APPROVAL_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [[ -n "$SNS_TOKEN" && -n "$CHAT_ID" ]]; then
    OFFSET=0
    [[ -f "$OFFSET_FILE" ]] && OFFSET=$(cat "$OFFSET_FILE")

    UPDATES_FILE=$(mktemp /tmp/tg-updates-XXXXXXXXXX)
    trap "rm -f '$UPDATES_FILE'" EXIT

    curl -sf --max-time 15 \
        "https://api.telegram.org/bot${SNS_TOKEN}/getUpdates?offset=${OFFSET}&timeout=5&allowed_updates=callback_query" \
        -o "$UPDATES_FILE" 2>/dev/null || true

    log "polling offset=$OFFSET"

    if [[ -s "$UPDATES_FILE" ]]; then
        /opt/homebrew/bin/python3 - "$UPDATES_FILE" "$QUEUE_DIR" "$FAILED_DIR" "$OFFSET_FILE" "$SNS_TOKEN" "$CHAT_ID" << 'PYEOF'
import json, os, sys
updates_file, queue_dir, failed_dir, offset_file, token, chat_id = sys.argv[1:]
try:
    data = json.load(open(updates_file))
except Exception as e:
    print(f"ERROR parsing updates: {e}", file=sys.stderr)
    sys.exit(0)

results = data.get("result", [])
if not results:
    sys.exit(0)

import urllib.request, urllib.parse

def answer_callback(callback_id, text):
    params = urllib.parse.urlencode({"callback_query_id": callback_id, "text": text})
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{token}/answerCallbackQuery?{params}", timeout=10)
    except Exception as e:
        print(f"answer_callback error: {e}", file=sys.stderr)

def send_msg(text):
    params = urllib.parse.urlencode({"chat_id": chat_id, "text": text})
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage?{params}", timeout=10)
    except Exception as e:
        print(f"send_msg error: {e}", file=sys.stderr)

max_update_id = 0
for update in results:
    uid = update.get("update_id", 0)
    if uid > max_update_id:
        max_update_id = uid
    cb = update.get("callback_query")
    if not cb:
        continue
    callback_id = cb.get("id", "")
    cb_data = cb.get("data", "")
    if ":" not in cb_data:
        continue
    action, filename = cb_data.split(":", 1)
    queue_file = os.path.join(queue_dir, filename)
    if not os.path.exists(queue_file):
        answer_callback(callback_id, "⚠️ 파일 없음 (이미 처리됨)")
        continue
    d = json.load(open(queue_file))
    platform = d.get("platform", "")
    if action == "approve":
        d["status"] = "approved"
        json.dump(d, open(queue_file, "w"), ensure_ascii=False, indent=2)

        # If sns-daily type, post immediately via social_poster --from-file
        # Uses the approved content directly instead of regenerating from ranking data
        if d.get("type") == "sns_daily" and (d.get("x") or d.get("x_text")):
            try:
                import subprocess
                result = subprocess.run(
                    ["/opt/homebrew/bin/python3", os.path.expanduser("~/scripts/social/social_poster.py"), "--from-file", queue_file, "--platforms", "x,threads"],
                    capture_output=True, text=True, timeout=60
                )
                if result.returncode == 0:
                    answer_callback(callback_id, "✅ X + Threads 발행 완료!")
                    send_msg(f"✅ SNS Daily ({d.get('day','').upper()}) — X + Threads 발행 완료")
                    import shutil
                    posted_dir = os.path.join(os.path.dirname(queue_dir), "posted")
                    os.makedirs(posted_dir, exist_ok=True)
                    shutil.move(queue_file, os.path.join(posted_dir, filename))
                else:
                    answer_callback(callback_id, f"⚠️ 발행 실패: {result.stderr[:100]}")
                    send_msg(f"⚠️ SNS 발행 실패:\n{result.stderr[:200]}")
            except Exception as e:
                answer_callback(callback_id, f"⚠️ 발행 오류: {str(e)[:80]}")
        else:
            answer_callback(callback_id, f"✅ {platform.upper()} 포스팅 승인됨")
            send_msg(f"✅ [{platform.upper()}] 승인 — 다음 post-content 실행 시 포스팅됩니다.")
        print(f"APPROVED: {filename}")
    elif action == "reject":
        d["status"] = "rejected"
        json.dump(d, open(queue_file, "w"), ensure_ascii=False, indent=2)
        import shutil
        shutil.move(queue_file, os.path.join(failed_dir, filename))
        answer_callback(callback_id, f"❌ 삭제됨")
        day_label = d.get("day", platform).upper()
        send_msg(f"❌ SNS ({day_label}) — 거절됨. 오늘 포스팅 건너뜁니다.")
        print(f"REJECTED: {filename}")

if max_update_id > 0:
    open(offset_file, "w").write(str(max_update_id + 1))
PYEOF
    fi
fi

# ── Bot 2: Alert bot — 사용자 명령 처리 (텍스트 메시지) ─────────────────────
# 사용자가 Alert bot에 메시지를 보내면 시스템 명령으로 처리
# 지원 명령: status, fix, health, diagnose
ALERT_TOKEN="${TELEGRAM_ALERT_BOT_TOKEN:-}"

if [[ -z "$ALERT_TOKEN" || -z "$CHAT_ID" ]]; then
    exit 0
fi

ALERT_OFFSET=0
[[ -f "$ALERT_OFFSET_FILE" ]] && ALERT_OFFSET=$(cat "$ALERT_OFFSET_FILE")

ALERT_UPDATES=$(mktemp /tmp/tg-alert-XXXXXX)
trap "rm -f $ALERT_UPDATES" EXIT

curl -sf --max-time 15 \
    "https://api.telegram.org/bot${ALERT_TOKEN}/getUpdates?offset=${ALERT_OFFSET}&timeout=5&allowed_updates=[\"message\"]" \
    -o "$ALERT_UPDATES" 2>/dev/null || true

[[ ! -s "$ALERT_UPDATES" ]] && exit 0

/opt/homebrew/bin/python3 - \
    "$ALERT_UPDATES" "$ALERT_OFFSET_FILE" "$ALERT_TOKEN" "$CHAT_ID" \
    "$HOME/scripts/social/health_check.sh" \
    "$HOME/scripts/claude-auto/log-error-responder.sh" \
    "$HOME/logs/social-health.log" << 'PYEOF'
import json, os, sys, subprocess, time
updates_file, offset_file, token, chat_id = sys.argv[1:5]
health_script, responder_script, health_log = sys.argv[5:8]

try:
    data = json.load(open(updates_file))
except:
    sys.exit(0)

results = data.get("result", [])
if not results:
    sys.exit(0)

import urllib.request, urllib.parse

def send_alert(text):
    body = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
    try:
        urllib.request.urlopen(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=body, timeout=10
        )
    except Exception as e:
        print(f"send_alert error: {e}", file=sys.stderr)

# 명령 → 동작 맵
COMMANDS = {
    "status":   ("상태 확인 중...", [health_script]),
    "health":   ("헬스체크 실행 중...", [health_script]),
    "fix":      ("자동 수정 시도 중...", [responder_script]),
    "diagnose": ("진단 실행 중...", [responder_script]),
    "상태":     ("상태 확인 중...", [health_script]),
    "수정":     ("자동 수정 시도 중...", [responder_script]),
    "진단":     ("진단 실행 중...", [responder_script]),
}

HELP_TEXT = (
    "📟 PRUVIQ Alert Bot 명령어\n\n"
    "status / 상태 — 헬스체크 실행\n"
    "fix / 수정 — 자동 수정 시도\n"
    "diagnose / 진단 — log-error-responder 실행\n"
    "log — 최근 에러 로그 5줄"
)

max_update_id = 0
for update in results:
    uid = update.get("update_id", 0)
    if uid > max_update_id:
        max_update_id = uid

    msg = update.get("message", {})
    if not msg:
        continue

    # 이 봇의 채팅에서 온 메시지만 처리
    msg_chat_id = str(msg.get("chat", {}).get("id", ""))
    if msg_chat_id != str(chat_id):
        continue

    text = msg.get("text", "").strip().lower().lstrip("/")
    if not text:
        continue

    print(f"CMD: {text!r} from chat {msg_chat_id}")

    if text == "log":
        try:
            lines = open(health_log).readlines()[-5:]
            send_alert("📋 최근 로그:\n" + "".join(lines).strip())
        except:
            send_alert("로그 파일 없음")
        continue

    if text in ("help", "?", "도움"):
        send_alert(HELP_TEXT)
        continue

    if text in COMMANDS:
        ack, scripts = COMMANDS[text]
        send_alert(f"⚙️ {ack}")
        for script in scripts:
            try:
                result = subprocess.run(
                    ["bash", script], capture_output=True, text=True, timeout=60
                )
                out = (result.stdout + result.stderr).strip()[-300:] or "(출력 없음)"
                status = "✅ 완료" if result.returncode == 0 else "⚠️ 에러 발생"
                send_alert(f"{status}\n```\n{out}\n```")
            except subprocess.TimeoutExpired:
                send_alert(f"⏱️ 타임아웃 (60s): {script}")
    else:
        send_alert(f"알 수 없는 명령: {text!r}\n\n" + HELP_TEXT)

if max_update_id > 0:
    open(offset_file, "w").write(str(max_update_id + 1))
PYEOF
