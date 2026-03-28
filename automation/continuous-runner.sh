#!/bin/bash
# JEPO Continuous Runner v1.0
# auto-fix → auto-test → auto-deploy 파이프라인을 연속 실행
# 기존 LaunchAgent 배치와 공존 (별도 lock)

source "$(dirname "$0")/claude-runner.sh"
# cost-tracker.sh, budget-guard.sh는 claude-runner.sh에서 이미 source됨

acquire_lock "continuous"

LOGFILE="$LOG_DIR/continuous-runner.log"
QUEUE_DIR="$LOG_DIR/queue"
PROGRESS_FILE="$LOG_DIR/progress.json"
EXIT_SIGNAL="$LOG_DIR/.exit-signal"
REPO="${JEPO_REPO:-pruviq/pruviq}"

MAX_CONSECUTIVE=5
COOLDOWN_SECONDS=600  # 5회 연속 후 10분 쿨다운
SESSION_TIMEOUT=3600  # 1시간 후 강제 종료

mkdir -p "$QUEUE_DIR"
rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

SESSION_START=$(date +%s)
CONSECUTIVE=0
SKIP_FILE="$LOG_DIR/continuous-skip-issues.txt"  # 스킵할 이슈 번호 목록
MAX_FAIL_PER_ISSUE=3  # 동일 이슈 N회 실패 시 스킵

log "Continuous runner started"

# EXIT_SIGNAL로 수동 중지 가능
[ -f "$EXIT_SIGNAL" ] && { log "Exit signal found, stopping"; rm -f "$EXIT_SIGNAL"; exit 0; }

while true; do
    # 세션 타임아웃
    elapsed=$(( $(date +%s) - SESSION_START ))
    if [ "$elapsed" -ge "$SESSION_TIMEOUT" ]; then
        log "Session timeout (${elapsed}s), stopping"
        break
    fi

    # EXIT_SIGNAL 체크
    [ -f "$EXIT_SIGNAL" ] && { log "Exit signal, stopping"; rm -f "$EXIT_SIGNAL"; break; }

    # 연속 실행 한도
    if [ "$CONSECUTIVE" -ge "$MAX_CONSECUTIVE" ]; then
        log "Max consecutive ($MAX_CONSECUTIVE) reached, cooling down ${COOLDOWN_SECONDS}s"
        sleep "$COOLDOWN_SECONDS"
        CONSECUTIVE=0
    fi

    # 예산 체크
    budget_result=$(budget_check "opus" 2>&1)
    budget_rc=$?
    if [ "$budget_rc" -eq 2 ]; then
        log "Emergency budget stop: $budget_result"
        send_telegram "🚨 [BUDGET] Emergency stop: $budget_result" 2>/dev/null || true
        break
    fi

    # 1단계: fix할 이슈 있는지 확인
    fix_issue=$(gh issue list --repo "$REPO" --label "claude-auto" --state open \
        --json number --jq '.[0].number' 2>/dev/null)

    if [ -n "$fix_issue" ] && [ "$fix_issue" != "null" ]; then
        # 스킵 목록에 있는 이슈인지 확인
        if grep -qx "$fix_issue" "$SKIP_FILE" 2>/dev/null; then
            log "Issue #$fix_issue skipped (exceeded $MAX_FAIL_PER_ISSUE attempts)"
        else
            log "Running auto-fix for issue #$fix_issue"
            fix_output=$("$(dirname "$0")/auto-fix.sh" 2>&1) || true

            # 실패 카운트 추적
            _fail_count_file="/tmp/claude-auto-fix-fail-${fix_issue}.count"
            if echo "$fix_output" | grep -qi "no fixable\|no fix\|not found\|failed"; then
                _prev_count=$(cat "$_fail_count_file" 2>/dev/null || echo "0")
                _new_count=$((_prev_count + 1))
                echo "$_new_count" > "$_fail_count_file"
                log "Issue #$fix_issue: no-fix attempt $_new_count/$MAX_FAIL_PER_ISSUE"

                if [ "$_new_count" -ge "$MAX_FAIL_PER_ISSUE" ]; then
                    echo "$fix_issue" >> "$SKIP_FILE"
                    log "Issue #$fix_issue added to skip list after $MAX_FAIL_PER_ISSUE failed attempts"
                    send_telegram "⏭️ <b>[continuous]</b> Issue #$fix_issue 스킵 — ${MAX_FAIL_PER_ISSUE}회 연속 수정 실패. 수동 확인 필요." 2>/dev/null || true
                    rm -f "$_fail_count_file"
                fi
            else
                # 성공 시 카운터 리셋
                rm -f "$_fail_count_file"
            fi

            CONSECUTIVE=$((CONSECUTIVE + 1))
            sleep 30
            continue
        fi
    fi

    # 2단계: test할 PR 있는지 확인
    test_pr=$(gh pr list --repo "$REPO" --state open \
        --json number,labels --jq '[.[] | select(.labels | map(.name) | (contains(["tests-passed"]) or contains(["tests-failed"])) | not)] | .[0].number' 2>/dev/null)

    if [ -n "$test_pr" ] && [ "$test_pr" != "null" ]; then
        log "Running auto-test for PR #$test_pr"
        "$(dirname "$0")/auto-test.sh" 2>/dev/null
        CONSECUTIVE=$((CONSECUTIVE + 1))
        sleep 10
        continue
    fi

    # 3단계: deploy할 PR 있는지 확인
    deploy_pr=$(gh pr list --repo "$REPO" --state open \
        --label "tests-passed" --json number --jq '.[0].number' 2>/dev/null)

    if [ -n "$deploy_pr" ] && [ "$deploy_pr" != "null" ]; then
        log "Running auto-deploy for PR #$deploy_pr"
        "$(dirname "$0")/auto-deploy.sh" 2>/dev/null
        CONSECUTIVE=$((CONSECUTIVE + 1))
        sleep 10
        continue
    fi

    # 큐 비어있음 — 종료
    log "No work in queue, stopping"
    break
done

# progress 기록
echo "{\"last_run\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"consecutive\":$CONSECUTIVE,\"elapsed\":$elapsed}" > "$PROGRESS_FILE"

log "Continuous runner finished (consecutive=$CONSECUTIVE, elapsed=${elapsed}s)"
