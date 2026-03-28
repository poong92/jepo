#!/bin/bash
# log-error-responder.sh
# 로그 파일에서 새 ERROR/CRITICAL을 감지 → 알려진 패턴은 즉시 자동 수정 → 나머지는 Claude 진단 → Telegram 알림
#
# [이전 telegram-error-monitor.sh 대체]
# 구조적 문제: Bot이 자신이 보낸 메시지를 getUpdates로 읽을 수 없음 → 항상 0건
# 해결: Telegram API polling 제거, 로그 파일 직접 감시로 전환
#
# Schedule: 5분마다 (com.jepo.log-error-responder LaunchAgent)
# State: $LOG_DIR/log-error-responder-state.json (파일별 마지막 읽은 줄 수 기록)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-runner.sh"

STATE_FILE="$LOG_DIR/log-error-responder-state.json"
SELF_LOG="$LOG_DIR/log-error-responder.log"
MAX_CLAUDE_CALLS=3     # 실행당 Claude 호출 최대 횟수 (비용 제한)
CLAUDE_TIMEOUT=120     # Opus는 Sonnet보다 느림, 120초 필요

rotate_log "$SELF_LOG"
acquire_lock "log-error-responder"

echo "$(date): log-error-responder started" >> "$SELF_LOG"

# ─── 감시할 로그 파일 목록 ─────────────────────────────────────────────────
WATCH_LOGS=(
    "$LOG_DIR/deploy-verify.log"
    "$LOG_DIR/agent-health.log"
    "$LOG_DIR/auto-fix.log"
    "$LOG_DIR/auto-deploy.log"
    "$LOG_DIR/daily-strategy-recap.log"
    "$LOG_DIR/agent-health-stdout.log"
    "$HOME/logs/social-health.log"
    "$HOME/logs/claude-auto/telegram-approval-poller.log"
    "$HOME/logs/staleness-watch.log"
)

# ─── 감지할 에러 패턴 ─────────────────────────────────────────────────────
ERROR_PATTERNS=(
    "CRITICAL"
    "❌"
    "🚨"
    " ERROR"
    "[ERROR]"
    "[ALERT]"
    "FAIL"
    "Code loop LOCKED"
    "Traceback"
    "Exception"
    "API DOWN"
    "OFFLINE"
    "Cannot fetch"
)

# ─── 알려진 자동 수정 룰 (패턴 → 수정 명령) ──────────────────────────────
# 형식: "감지패턴|||수정명령|||설명"
UID_VAL=$(id -u)
AUTO_FIX_RULES=(
    # ── 기존 룰 ───────────────────────────────────────────────────────────
    "Code loop LOCKED|||rm -f /tmp/claude-auto-code-loop-locked|||deploy-verify 롤백 lock 해제"
    "deploy-verify.*FAIL.*58|deploy-verify.*FAIL.*[3-6][0-9]/100|||echo 'Low score: latency spike, not a real failure'|||레이턴시 오판 — 수동 확인 불필요"

    # ── Telegram 파이프라인 ───────────────────────────────────────────────
    "Telegram approval poller NOT loaded|||launchctl kickstart -k gui/${UID_VAL}/com.pruviq.telegram-approval-poller 2>&1 || true|||Telegram 승인 폴러 LaunchAgent 재시작"
    "Telegram approval poller loaded but log stale|||launchctl kickstart -k gui/${UID_VAL}/com.pruviq.telegram-approval-poller 2>&1 || true|||Telegram 폴러 stale → 재시작"

    # ── Claude Auth ───────────────────────────────────────────────────────
    "Claude auth STALE|Claude auth EXPIRED|no AUTH_OK|||launchctl kickstart -k gui/${UID_VAL}/com.pruviq.auth-keepalive 2>&1 || true|||Claude auth keepalive LaunchAgent 재시작"

    # ── PRUVIQ API ────────────────────────────────────────────────────────
    "com.pruviq.api.*DOWN|API.*not reachable|pruviq.api.*OFFLINE|||launchctl kickstart -k gui/${UID_VAL}/com.pruviq.api 2>&1 || true|||PRUVIQ API LaunchAgent 재시작"
    "Cannot fetch data from.*api.pruviq.com|market/live.*502|market/live.*000|||launchctl kickstart -k gui/${UID_VAL}/com.pruviq.api 2>&1 || true|||API 응답 없음 → com.pruviq.api 자동 재시작"

    # ── deploy-verify false positive ──────────────────────────────────────
    "deploy-verify.*check started|||true|||deploy-verify 정상 동작 로그 — 오탐 무시"

    # ── 오탐 억제 (v1.1 — 반복 에러 분석 기반 추가) ────────────────────────
    "Data age:.*threshold|||true|||staleness 정상 데이터 나이 로그 — 오탐 무시"
    "Phase [0-9].*Log freshness|Phase [0-9].*Lock cleanup|||true|||agent-health 정상 동작 로그 — 오탐 무시"
    "Ollama.*not responding|||true|||Ollama 의도적 비활성 — 오탐 무시"
    "Outside safe deploy hours|||true|||배포 시간 외 정상 스킵 — 오탐 무시"
    "CF Workers deploy succeeded|||true|||배포 성공 로그 — 오탐 무시"
    "already running, skipping|||true|||중복 실행 방지 정상 동작 — 오탐 무시"

    # ── 자동 수정: weekly-audit 실패 시 lock 정리 ──────────────────────────
    "weekly-audit.*FAIL|weekly-audit.*exit.*1|||rm -rf /tmp/claude-auto-locks/weekly-audit.lockdir 2>/dev/null; true|||weekly-audit lock 정리"
)

# ─── 상태 로드 (파일별 마지막 읽은 줄 수) ────────────────────────────────
load_state() {
    local logfile="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo 0
        return
    fi
    python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    print(d.get('$logfile', 0))
except:
    print(0)
" 2>/dev/null || echo 0
}

save_state() {
    local logfile="$1"
    local linecount="$2"
    python3 -c "
import json, os
state_file = '$STATE_FILE'
try:
    d = json.load(open(state_file)) if os.path.exists(state_file) else {}
except:
    d = {}
d['$logfile'] = $linecount
d['_updated'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open(state_file + '.tmp', 'w') as f:
    json.dump(d, f, indent=2)
os.rename(state_file + '.tmp', state_file)
" 2>/dev/null || true
}

# ─── 에러 해시 (중복 처리 방지) ──────────────────────────────────────────
error_hash() {
    echo "$1" | md5 2>/dev/null || echo "$1" | /sbin/md5 2>/dev/null || echo "$1" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "${#1}"
}

PROCESSED_HASHES_FILE="/tmp/log-error-responder-seen-$(date +%Y%m%d)"
touch "$PROCESSED_HASHES_FILE" 2>/dev/null || true

already_seen() {
    local hash="$1"
    grep -qx "$hash" "$PROCESSED_HASHES_FILE" 2>/dev/null
}

mark_seen() {
    local hash="$1"
    echo "$hash" >> "$PROCESSED_HASHES_FILE"
    # 파일이 1000줄 초과 시 정리
    local lines
    lines=$(wc -l < "$PROCESSED_HASHES_FILE" 2>/dev/null || echo 0)
    if [[ $lines -gt 1000 ]]; then
        tail -500 "$PROCESSED_HASHES_FILE" > "$PROCESSED_HASHES_FILE.tmp" && mv "$PROCESSED_HASHES_FILE.tmp" "$PROCESSED_HASHES_FILE"
    fi
}

# ─── 자동 수정 시도 ───────────────────────────────────────────────────────
# 룰 형식: "패턴|||명령|||설명" (|||가 구분자, 패턴 내부의 |는 grep OR)
try_auto_fix() {
    local error_line="$1"
    for rule in "${AUTO_FIX_RULES[@]}"; do
        local pattern cmd description remainder
        # ||| 구분자 파싱 (cut -d'|'는 패턴 내 | 때문에 오파싱 — bash expansion 사용)
        pattern="${rule%%|||*}"
        remainder="${rule#*|||}"
        cmd="${remainder%%|||*}"
        description="${remainder#*|||}"

        if echo "$error_line" | grep -qE "$pattern"; then
            echo "$(date): AUTO_FIX matched [$description]" >> "$SELF_LOG"
            local result
            result=$(eval "$cmd" 2>&1) || result="fix command failed"
            echo "$(date): AUTO_FIX result: $result" >> "$SELF_LOG"
            send_telegram "🔧 <b>자동 수정 완료</b>

패턴: <code>$description</code>
에러: <code>${error_line:0:150}</code>
조치: <code>$result</code>

<i>log-error-responder | $(date +%Y-%m-%d\ %H:%M)</i>" || true
            return 0
        fi
    done
    return 1  # 매칭되는 룰 없음
}

# ─── Claude 진단 ─────────────────────────────────────────────────────────
run_claude_diagnosis() {
    local error_line="$1"
    local source_log="$2"

    # 에러 전후 맥락 추출 (±5줄)
    local context=""
    if [[ -f "$source_log" ]]; then
        local line_num
        line_num=$(grep -n -F "${error_line:0:80}" "$source_log" 2>/dev/null | tail -1 | cut -d: -f1)
        if [[ -n "$line_num" ]]; then
            local start=$((line_num > 5 ? line_num - 5 : 1))
            context=$(sed -n "${start},$((line_num + 5))p" "$source_log" 2>/dev/null)
        fi
    fi
    [[ -z "$context" ]] && context="(맥락 추출 실패)"

    # 시스템 컨텍스트 로딩 (아키텍처, 서비스맵, 알려진 패턴)
    local sys_context=""
    local ctx_file="$SCRIPT_DIR/lib/system-context.txt"
    [[ -f "$ctx_file" ]] && sys_context=$(cat "$ctx_file")

    local prompt="JEPO 시스템 에러 진단 AI.
너는 JEPO 시스템(Mac Mini M4)의 24/7 자동화 인프라를 관리하는 진단 전문가다.
아래 시스템 지식을 바탕으로 에러를 진단해라. 도구 사용 없이 주어진 정보만으로 판단.

=== 시스템 지식 ===
${sys_context}

=== 진단 대상 에러 ===
${error_line}

=== 소스 로그 파일 ===
${source_log}

=== 전후 맥락 (±5줄) ===
${context}

=== 판단 기준 ===
1. 알려진 패턴(시스템 지식의 '오탐 아닌 것')에 해당하면 P2 처리
2. 서비스 다운(API 응답 불가, 터널 끊김, 프로세스 사망)은 무조건 P0
3. 데이터 미갱신, 배포 실패, 기능 저하는 P1
4. 로그 노이즈, 일시적 타임아웃, 재시도로 해결되는 건 P2
5. '알려진 실제 에러 패턴'과 매칭되면 해당 조치를 제안

=== 응답 형식 (정확히 지켜라, 추가 설명 금지) ===
원인: [구체적 원인 1줄 — 어떤 서비스의 어떤 문제인지]
심각도: [P0/P1/P2]
조치: [구체적 명령 1줄 또는 '자동 복구됨' 또는 '수동 확인 필요: [이유]']"

    local diagnosis
    if diagnosis=$(bash_timeout "$CLAUDE_TIMEOUT" claude \
        --model "$MODEL_OPUS" \
        -p "$prompt" \
        --output-format text \
        2>/dev/null); then
        echo "$diagnosis"
    else
        echo "원인: Claude 진단 타임아웃 (${CLAUDE_TIMEOUT}s)
심각도: P2
조치: 다음 실행에서 재시도됨"
    fi
}

# ─── 메인 루프: 각 로그 파일 처리 ───────────────────────────────────────
CLAUDE_CALLS=0
ERRORS_FOUND=0

for logfile in "${WATCH_LOGS[@]}"; do
    [[ ! -f "$logfile" ]] && continue

    current_lines=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    last_lines=$(load_state "$logfile")

    # 로그가 줄어들었으면 (로테이션) 리셋
    if [[ $current_lines -lt $last_lines ]]; then
        last_lines=0
    fi

    # 새 줄이 없으면 스킵
    if [[ $current_lines -le $last_lines ]]; then
        save_state "$logfile" "$current_lines"
        continue
    fi

    # 새로 추가된 줄만 추출
    new_lines=$(tail -n "+$((last_lines + 1))" "$logfile" 2>/dev/null || true)
    save_state "$logfile" "$current_lines"

    [[ -z "$new_lines" ]] && continue

    # 에러 패턴 필터링
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # 에러 패턴 매칭
        is_error=false
        for pattern in "${ERROR_PATTERNS[@]}"; do
            if echo "$line" | grep -q "$pattern"; then
                is_error=true
                break
            fi
        done
        [[ "$is_error" == "false" ]] && continue

        # 정상 로그 필터 — Opus 호출 전에 알려진 노이즈 제거
        skip=false
        case "$line" in
            *"check started"*) skip=true ;;
            *"already verified, skipping"*) skip=true ;;
            *"No fixable issues"*) skip=true ;;
            *"auto-fix started"*) skip=true ;;
            *"auto-deploy started"*) skip=true ;;
            *"auto-test started"*) skip=true ;;
            *"agent-health check started"*) skip=true ;;
            *"all healthy"*) skip=true ;;
            *"complete —"*[0-9]*"healthy"*) skip=true ;;
            *"[OK]"*) skip=true ;;
            *"[INFO]"*) skip=true ;;
            *"polling offset="*) skip=true ;;
            *"No PRs ready"*) skip=true ;;
            *"New deployment detected"*) skip=true ;;
            *"Batch:"*"issues"*) skip=true ;;
            *"CONFLICT:"*"skipped"*) skip=true ;;
        esac
        if [[ "$skip" == "true" ]]; then
            continue
        fi

        # 중복 체크
        hash=$(error_hash "${logfile}:${line}")
        if already_seen "$hash"; then
            continue
        fi
        mark_seen "$hash"

        ERRORS_FOUND=$((ERRORS_FOUND + 1))
        echo "$(date): ERROR_DETECTED in $(basename "$logfile"): ${line:0:120}" >> "$SELF_LOG"

        # 자동 수정 시도
        if try_auto_fix "$line"; then
            continue  # 자동 수정 성공 → Claude 진단 불필요
        fi

        # Claude 진단 (횟수 제한)
        if [[ $CLAUDE_CALLS -ge $MAX_CLAUDE_CALLS ]]; then
            echo "$(date): Claude call limit reached, queuing for next run" >> "$SELF_LOG"
            # 아직 처리 못한 에러는 다음 실행에서 처리되도록 seen에서 제거
            sed -i '' "/$hash/d" "$PROCESSED_HASHES_FILE" 2>/dev/null || true
            continue
        fi

        CLAUDE_CALLS=$((CLAUDE_CALLS + 1))
        diagnosis=$(run_claude_diagnosis "$line" "$logfile")

        # 심각도에 따라 이모지 결정
        severity_icon="🔍"
        echo "$diagnosis" | grep -q "P0" && severity_icon="🚨"
        echo "$diagnosis" | grep -q "P1" && severity_icon="⚠️"

        # P0/P1만 Telegram 발송, P2(노이즈)는 로그에만 기록
        if echo "$diagnosis" | grep -qE "P0|P1"; then
            send_telegram "${severity_icon} <b>에러 진단</b>

<b>소스:</b> $(basename "$logfile")
<code>${line:0:150}</code>

${diagnosis:0:500}

<i>$(date +%H:%M)</i>" || true
        else
            echo "$(date): P2 suppressed (log only): $(basename "$logfile"): ${line:0:80}" >> "$SELF_LOG"
        fi

    done <<< "$new_lines"
done

echo "$(date): log-error-responder done — errors_found=$ERRORS_FOUND, claude_calls=$CLAUDE_CALLS" >> "$SELF_LOG"
