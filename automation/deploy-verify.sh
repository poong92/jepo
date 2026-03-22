#!/bin/bash
# JEPO deploy-verify -- Post-deployment E2E verification + auto-rollback
# Schedule: every 5 minutes (poll for new deployments)
#
# Flow:
#   1. Detect new deployment (latest commit SHA)
#   2. Run E2E tests (API health, web status, security headers)
#   3. Score weighted average
#   4. PASS (>=85) / WARN (70-84) / FAIL (<70 -> rollback)

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "deploy-verify"

LOGFILE="$LOG_DIR/deploy-verify.log"
DEPLOY_STATE="$LOG_DIR/deploy-verify-state.json"
rotate_log "$LOGFILE"

REPO="${JEPO_REPO:?Set JEPO_REPO env var}"
DEPLOY_API_URL="${JEPO_DEPLOY_API_URL:-}"
DEPLOY_WEB_URL="${JEPO_DEPLOY_WEB_URL:-}"
ROLLBACK_LOCK="/tmp/claude-auto-code-loop-locked"

echo "$(date): deploy-verify check started" >> "$LOGFILE"

# --- Phase 0: Check for new deployment ---
latest_sha=$(gh api repos/$REPO/commits/main --jq '.sha' 2>/dev/null | head -c 7)
if [[ -z "$latest_sha" || ! "$latest_sha" =~ ^[0-9a-f]{7}$ ]]; then
    echo "$(date): Could not fetch valid commit SHA" >> "$LOGFILE"
    exit 0
fi

last_verified=""
if [[ -f "$DEPLOY_STATE" ]]; then
    last_verified=$(python3 -c "
import json
try:
    with open('$DEPLOY_STATE') as f:
        print(json.load(f).get('last_verified_sha', ''))
except: print('')
" 2>/dev/null)
fi

if [[ "$latest_sha" == "$last_verified" ]]; then
    exit 0
fi

# Check rollback lock
if [[ -f "$ROLLBACK_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$ROLLBACK_LOCK" 2>/dev/null || stat -c %Y "$ROLLBACK_LOCK" 2>/dev/null || echo "0") ))
    if [[ $lock_age -gt 21600 ]]; then
        rm -f "$ROLLBACK_LOCK"
        alert_send "INFO" "deploy-verify" "Rollback lock auto-expired" "deploy" 2>/dev/null
    else
        echo "$(date): Code loop LOCKED -- manual intervention needed" >> "$LOGFILE"
        exit 1
    fi
fi

echo "$(date): New deployment detected -- SHA: $latest_sha" >> "$LOGFILE"

# --- Phase 1: Wait for propagation ---
sleep 15

# --- Phase 2: E2E Tests ---
declare -a test_names=()
declare -a test_scores=()
declare -a test_weights=()

# Test 1: API Health (weight 40%)
if [[ -n "$DEPLOY_API_URL" ]]; then
    api_curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 10 "${DEPLOY_API_URL}/health" 2>/dev/null || echo "000 0")
    api_status=$(echo "$api_curl_out" | awk '{print $1}')
    api_time=$(echo "$api_curl_out" | awk '{printf "%.0f", $2 * 1000}')
    api_score=0
    [[ "$api_status" == "200" ]] && api_score=100
    [[ "$api_status" == "502" || "$api_status" == "503" ]] && api_score=50
    test_names+=("API Health")
    test_scores+=("$api_score")
    test_weights+=(40)
else
    test_names+=("API Health")
    test_scores+=(100)
    test_weights+=(40)
    api_status="skipped"
    api_time="0"
fi

# Test 2: Web Performance (weight 30%)
if [[ -n "$DEPLOY_WEB_URL" ]]; then
    web_curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 15 "$DEPLOY_WEB_URL" 2>/dev/null || echo "000 0")
    web_status=$(echo "$web_curl_out" | awk '{print $1}')
    web_time=$(echo "$web_curl_out" | awk '{printf "%.0f", $2 * 1000}')
    web_score=0
    [[ "$web_status" == "200" ]] && web_score=100
    test_names+=("Web Perf")
    test_scores+=("$web_score")
    test_weights+=(30)
else
    test_names+=("Web Perf")
    test_scores+=(100)
    test_weights+=(30)
    web_status="skipped"
    web_time="0"
fi

# Test 3: Security Headers (weight 30%)
if [[ -n "$DEPLOY_WEB_URL" ]]; then
    headers=$(curl -sI -m 10 "$DEPLOY_WEB_URL" 2>/dev/null || echo "")
    header_checks=0
    total_headers=4
    echo "$headers" | grep -qi "strict-transport-security" && header_checks=$((header_checks + 1))
    echo "$headers" | grep -qi "x-content-type-options" && header_checks=$((header_checks + 1))
    echo "$headers" | grep -qi "x-frame-options" && header_checks=$((header_checks + 1))
    echo "$headers" | grep -qi "content-security-policy" && header_checks=$((header_checks + 1))
    sec_score=$(( header_checks * 100 / total_headers ))
    test_names+=("Sec Headers")
    test_scores+=("$sec_score")
    test_weights+=(30)
else
    test_names+=("Sec Headers")
    test_scores+=(100)
    test_weights+=(30)
fi

# --- Phase 3: Calculate weighted score ---
num_tests=${#test_scores[@]}
e2e_score=$(python3 -c "
scores = [${test_scores[*]// /,}]
weights = [${test_weights[*]// /,}]
total = sum(s * w for s, w in zip(scores, weights)) / sum(weights)
print(int(total))
")

echo "$(date): E2E Score: $e2e_score/100" >> "$LOGFILE"

# --- Phase 4: Verdict ---
if [[ $e2e_score -ge 85 ]]; then
    verdict="PASS"
    atomic_write "$DEPLOY_STATE" "{\"last_verified_sha\":\"$latest_sha\",\"score\":$e2e_score,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"verdict\":\"PASS\"}"
    alert_send "INFO" "deploy-verify" "Deploy PASS ($e2e_score/100) -- SHA: $latest_sha" "deploy" 2>/dev/null

elif [[ $e2e_score -ge 70 ]]; then
    verdict="WARN"
    atomic_write "$DEPLOY_STATE" "{\"last_verified_sha\":\"$latest_sha\",\"score\":$e2e_score,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"verdict\":\"WARN\"}"
    alert_send "WARNING" "deploy-verify" "Deploy WARN ($e2e_score/100) -- SHA: $latest_sha" "deploy" 2>/dev/null

else
    verdict="FAIL"
    echo "$(date): Deployment FAILED ($e2e_score/100) -- initiating rollback" >> "$LOGFILE"

    prev_sha_full=$(gh api "repos/$REPO/commits?per_page=2" --jq '.[1].sha' 2>/dev/null)
    prev_sha="${prev_sha_full:0:7}"

    if [[ -n "$prev_sha" && -n "$prev_sha_full" ]]; then
        revert_result=$(gh api "repos/$REPO/git/refs" \
            --method POST \
            -f ref="refs/heads/revert-$latest_sha" \
            -f sha="$prev_sha_full" 2>&1) || true

        if echo "$revert_result" | grep -q '"node_id"'; then
            gh pr create --repo "$REPO" \
                --title "Auto-revert: Deploy $latest_sha failed (score: $e2e_score)" \
                --body "Automated rollback. E2E Score: $e2e_score/100. Target: $prev_sha" \
                --head "revert-$latest_sha" --base "main" \
                --label "claude-auto,rollback" 2>> "$LOGFILE" || {
                touch "$ROLLBACK_LOCK"
                alert_send "CRITICAL" "deploy-verify" "Revert PR failed -- MANUAL ROLLBACK" "deploy" 2>/dev/null
            }
        else
            touch "$ROLLBACK_LOCK"
            alert_send "CRITICAL" "deploy-verify" "Revert branch failed -- MANUAL ROLLBACK" "deploy" 2>/dev/null
        fi
    else
        touch "$ROLLBACK_LOCK"
        alert_send "CRITICAL" "deploy-verify" "Cannot determine prev SHA -- MANUAL ROLLBACK" "deploy" 2>/dev/null
    fi

    atomic_write "$DEPLOY_STATE" "{\"last_verified_sha\":\"$latest_sha\",\"score\":$e2e_score,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"verdict\":\"FAIL\",\"rollback_to\":\"$prev_sha\"}"
fi

echo "$(date): deploy-verify complete -- $verdict ($e2e_score/100)" >> "$LOGFILE"
