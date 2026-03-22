#!/bin/bash
# JEPO Continuous Runner
# Runs auto-fix -> auto-test -> auto-deploy pipeline in a loop
# Coexists with individual LaunchAgent schedules (separate lock)

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/cost-tracker.sh"
source "$LIB_DIR/budget-guard.sh"

acquire_lock "continuous"

LOGFILE="$LOG_DIR/continuous-runner.log"
PROGRESS_FILE="$LOG_DIR/progress.json"
EXIT_SIGNAL="$LOG_DIR/.exit-signal"
REPO="${JEPO_REPO:?Set JEPO_REPO env var}"

MAX_CONSECUTIVE="${JEPO_MAX_CONSECUTIVE:-5}"
COOLDOWN_SECONDS="${JEPO_COOLDOWN_SECONDS:-600}"  # 10 min after max consecutive
SESSION_TIMEOUT="${JEPO_SESSION_TIMEOUT:-3600}"    # 1 hour

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

SESSION_START=$(date +%s)
CONSECUTIVE=0

log "Continuous runner started"

[ -f "$EXIT_SIGNAL" ] && { log "Exit signal found, stopping"; rm -f "$EXIT_SIGNAL"; exit 0; }

while true; do
    elapsed=$(( $(date +%s) - SESSION_START ))
    if [ "$elapsed" -ge "$SESSION_TIMEOUT" ]; then
        log "Session timeout (${elapsed}s), stopping"
        break
    fi

    [ -f "$EXIT_SIGNAL" ] && { log "Exit signal, stopping"; rm -f "$EXIT_SIGNAL"; break; }

    if [ "$CONSECUTIVE" -ge "$MAX_CONSECUTIVE" ]; then
        log "Max consecutive ($MAX_CONSECUTIVE) reached, cooling down ${COOLDOWN_SECONDS}s"
        sleep "$COOLDOWN_SECONDS"
        CONSECUTIVE=0
    fi

    # Budget check
    budget_result=$(budget_check "opus" 2>&1)
    budget_rc=$?
    if [ "$budget_rc" -eq 2 ]; then
        log "Emergency budget stop: $budget_result"
        send_telegram "[BUDGET] Emergency stop: $budget_result" 2>/dev/null || true
        break
    fi

    # Stage 1: Issues to fix?
    fix_issue=$(gh issue list --repo "$REPO" --label "claude-auto" --state open \
        --json number --jq '.[0].number' 2>/dev/null)

    if [ -n "$fix_issue" ] && [ "$fix_issue" != "null" ]; then
        log "Running auto-fix for issue #$fix_issue"
        "$(dirname "$0")/auto-fix.sh" 2>/dev/null
        CONSECUTIVE=$((CONSECUTIVE + 1))
        sleep 30
        continue
    fi

    # Stage 2: PRs to test?
    test_pr=$(gh pr list --repo "$REPO" --state open \
        --json number,labels --jq '[.[] | select(.labels | map(.name) | (contains(["tests-passed"]) or contains(["tests-failed"])) | not)] | .[0].number' 2>/dev/null)

    if [ -n "$test_pr" ] && [ "$test_pr" != "null" ]; then
        log "Running auto-test for PR #$test_pr"
        "$(dirname "$0")/auto-test.sh" 2>/dev/null
        CONSECUTIVE=$((CONSECUTIVE + 1))
        sleep 10
        continue
    fi

    # Stage 3: PRs to deploy?
    deploy_pr=$(gh pr list --repo "$REPO" --state open \
        --label "tests-passed" --json number --jq '.[0].number' 2>/dev/null)

    if [ -n "$deploy_pr" ] && [ "$deploy_pr" != "null" ]; then
        log "Running auto-deploy for PR #$deploy_pr"
        "$(dirname "$0")/auto-deploy.sh" 2>/dev/null
        CONSECUTIVE=$((CONSECUTIVE + 1))
        sleep 10
        continue
    fi

    log "No work in queue, stopping"
    break
done

echo "{\"last_run\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"consecutive\":$CONSECUTIVE,\"elapsed\":$elapsed}" > "$PROGRESS_FILE"
log "Continuous runner finished (consecutive=$CONSECUTIVE, elapsed=${elapsed}s)"
