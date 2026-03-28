#!/bin/bash
# deploy-verify — Post-deployment E2E verification + auto-rollback
# Schedule: Triggered by cron (every 5min poll for new deployments)
#
# Flow:
#   1. Check if new deployment detected (Cloudflare Pages)
#   2. Run E2E tests (API health, web performance, security headers)
#   3. Score weighted average
#   4. PASS (>=85) / WARN (70-84) / FAIL (<70 → rollback)

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "deploy-verify"

LOGFILE="$LOG_DIR/deploy-verify.log"
DEPLOY_STATE="$LOG_DIR/deploy-verify-state.json"
rotate_log "$LOGFILE"

REPO="pruviq/pruviq"
PRUVIQ_API="https://api.pruviq.com"
PRUVIQ_WEB="https://pruviq.com"
ROLLBACK_LOCK="/tmp/claude-auto-code-loop-locked"

echo "$(date): deploy-verify check started" >> "$LOGFILE"

# ─── Phase 0: Check for new deployment ───
latest_sha=$(gh api repos/$REPO/commits/main --jq '.sha' 2>/dev/null | head -c 7)
if [[ -z "$latest_sha" ]]; then
    echo "$(date): Could not fetch latest commit SHA" >> "$LOGFILE"
    exit 0
fi

# Validate SHA format (hex only)
if [[ ! "$latest_sha" =~ ^[0-9a-f]{7}$ ]]; then
    echo "$(date): Invalid SHA format: $latest_sha" >> "$LOGFILE"
    exit 1
fi

# Check if we already verified this SHA
last_verified=""
if [[ -f "$DEPLOY_STATE" ]]; then
    last_verified=$(DSTATE="$DEPLOY_STATE" python3 -c '
import json, os
try:
    with open(os.environ["DSTATE"]) as f:
        print(json.load(f).get("last_verified_sha", ""))
except:
    print("")
' 2>/dev/null)
fi

if [[ "$latest_sha" == "$last_verified" ]]; then
    echo "$(date): SHA $latest_sha already verified, skipping" >> "$LOGFILE"
    exit 0
fi

# Check if code loop is locked (previous rollback failed)
# Auto-expire lock after 6 hours to prevent permanent blockage
if [[ -f "$ROLLBACK_LOCK" ]]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$ROLLBACK_LOCK" 2>/dev/null || echo "0") ))
    if [[ $lock_age -gt 21600 ]]; then
        echo "$(date): Lock expired (${lock_age}s > 6h) — auto-clearing" >> "$LOGFILE"
        rm -f "$ROLLBACK_LOCK"
        alert_send "INFO" "deploy-verify" "Rollback lock auto-expired after ${lock_age}s" "deploy" 2>/dev/null
    else
        echo "$(date): Code loop LOCKED (${lock_age}s ago) — manual intervention or wait for 6h expiry" >> "$LOGFILE"
        alert_send "CRITICAL" "deploy-verify" "Code loop locked (${lock_age}s ago) — expires in $((21600 - lock_age))s" "deploy" 2>/dev/null
        exit 1
    fi
fi

echo "$(date): New deployment detected — SHA: $latest_sha" >> "$LOGFILE"

# ─── Phase 1: Wait for deployment propagation + API readiness ───
echo "$(date): Waiting for deployment propagation..." >> "$LOGFILE"
sleep 15  # Cloudflare Pages typically propagates in 10-20s

# Wait for API to become healthy (uvicorn restart can take ~90s for data loading)
api_ready=false
for retry in 1 2 3 4; do
    check_out=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${PRUVIQ_API}/health" 2>/dev/null || echo "000")
    if [[ "$check_out" == "200" ]]; then
        api_ready=true
        echo "$(date): API ready after retry $retry" >> "$LOGFILE"
        break
    fi
    echo "$(date): API not ready (status=$check_out), waiting 30s (retry $retry/4)..." >> "$LOGFILE"
    sleep 30
done

if [[ "$api_ready" != "true" ]]; then
    echo "$(date): API not ready after 120s+ — proceeding with tests (may score low)" >> "$LOGFILE"
fi

# ─── Phase 2: E2E Tests ───
declare -a test_names=()
declare -a test_scores=()
declare -a test_weights=()

# Test 1: API Health (weight 40%)
echo "$(date): Running Test 1: API Health" >> "$LOGFILE"
api_curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 10 "${PRUVIQ_API}/health" 2>/dev/null || echo "000 0")
api_status=$(echo "$api_curl_out" | awk '{print $1}')
api_time=$(echo "$api_curl_out" | awk '{printf "%.0f", $2 * 1000}')

# HTTP 200 = pass. 502/503 = transient gateway issue (Mac Mini behind Cloudflare Tunnel) = 50 (WARN, not FAIL).
if [[ "$api_status" == "200" ]]; then
    api_score=100
elif [[ "$api_status" == "502" || "$api_status" == "503" ]]; then
    api_score=50  # Transient — Cloudflare Tunnel / Mac Mini restart. Web still up = deployment OK.
else
    api_score=0
fi

test_names+=("API Health")
test_scores+=("$api_score")
test_weights+=(40)
echo "$(date): API Health — status=$api_status, time=${api_time}ms, score=$api_score" >> "$LOGFILE"

# Test 2: Web Performance (weight 30%)
echo "$(date): Running Test 2: Web Performance" >> "$LOGFILE"
web_curl_out=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 15 "$PRUVIQ_WEB" 2>/dev/null || echo "000 0")
web_status=$(echo "$web_curl_out" | awk '{print $1}')
web_time=$(echo "$web_curl_out" | awk '{printf "%.0f", $2 * 1000}')

# HTTP 200 = pass (latency is info-only)
if [[ "$web_status" == "200" ]]; then
    web_score=100
else
    web_score=0
fi

test_names+=("Web Perf")
test_scores+=("$web_score")
test_weights+=(30)
echo "$(date): Web Perf — status=$web_status, time=${web_time}ms, score=$web_score" >> "$LOGFILE"

# Test 3: Market Live API endpoint (weight 15%)
echo "$(date): Running Test 3: Market Live API" >> "$LOGFILE"
bt_status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "${PRUVIQ_API}/market/live" 2>/dev/null || echo "000")

bt_score=0
if [[ "$bt_status" == "200" ]]; then
    bt_score=100
elif [[ "$bt_status" == "502" || "$bt_status" == "503" ]]; then
    bt_score=50  # Temporarily unavailable (Binance upstream / Cloudflare Tunnel)
else
    bt_score=0
fi

test_names+=("Backtest API")
test_scores+=("$bt_score")
test_weights+=(15)
echo "$(date): Market Live API — status=$bt_status, score=$bt_score" >> "$LOGFILE"

# Test 4: Security Headers (weight 15%)
echo "$(date): Running Test 4: Security Headers" >> "$LOGFILE"
headers=$(curl -sI -m 10 "$PRUVIQ_WEB" 2>/dev/null || echo "")

sec_score=0
header_checks=0
total_headers=4

if echo "$headers" | grep -qi "strict-transport-security"; then
    header_checks=$((header_checks + 1))
fi
if echo "$headers" | grep -qi "x-content-type-options"; then
    header_checks=$((header_checks + 1))
fi
if echo "$headers" | grep -qi "x-frame-options"; then
    header_checks=$((header_checks + 1))
fi
if echo "$headers" | grep -qi "content-security-policy"; then
    header_checks=$((header_checks + 1))
fi

sec_score=$(( header_checks * 100 / total_headers ))

test_names+=("Sec Headers")
test_scores+=("$sec_score")
test_weights+=(15)
echo "$(date): Sec Headers — $header_checks/$total_headers present, score=$sec_score" >> "$LOGFILE"

# ─── Phase 3: Calculate weighted E2E score ───
if [[ ${#test_scores[@]} -ne 4 || ${#test_weights[@]} -ne 4 ]]; then
    echo "$(date): ERROR: only ${#test_scores[@]}/4 test scores collected, aborting" >> "$LOGFILE"
    alert_send "ERROR" "deploy-verify" "Incomplete test scores (${#test_scores[@]}/4)" "deploy" 2>/dev/null
    exit 1
fi
e2e_score=$(python3 -c "
scores = [${test_scores[0]}, ${test_scores[1]}, ${test_scores[2]}, ${test_scores[3]}]
weights = [${test_weights[0]}, ${test_weights[1]}, ${test_weights[2]}, ${test_weights[3]}]
total = sum(s * w for s, w in zip(scores, weights)) / sum(weights)
print(int(total))
")

echo "$(date): E2E Score: $e2e_score/100" >> "$LOGFILE"

# ─── Phase 4: Verdict ───
if [[ $e2e_score -ge 85 ]]; then
    verdict="PASS"
    echo "$(date): ✅ Deployment PASSED ($e2e_score/100)" >> "$LOGFILE"

    # Save verified state
    atomic_write "$DEPLOY_STATE" "{\"last_verified_sha\":\"$latest_sha\",\"score\":$e2e_score,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"verdict\":\"PASS\"}"

    alert_send "INFO" "deploy-verify" "Deploy PASS ($e2e_score/100) — SHA: $latest_sha" "deploy" 2>/dev/null

elif [[ $e2e_score -ge 70 ]]; then
    verdict="WARN"
    echo "$(date): ⚠️ Deployment WARNING ($e2e_score/100)" >> "$LOGFILE"

    # Save state but flag as warning
    atomic_write "$DEPLOY_STATE" "{\"last_verified_sha\":\"$latest_sha\",\"score\":$e2e_score,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"verdict\":\"WARN\"}"

    # Find failing tests
    failing_tests=""
    for i in 0 1 2 3; do
        if [[ ${test_scores[$i]} -lt 70 ]]; then
            failing_tests="${failing_tests}${test_names[$i]}(${test_scores[$i]}), "
        fi
    done

    alert_send "WARNING" "deploy-verify" "Deploy WARN ($e2e_score/100) — Failing: $failing_tests SHA: $latest_sha" "deploy" 2>/dev/null

    # Create GitHub Issue for tracking
    create_issue_safe "$REPO" \
        "⚠️ Deploy quality warning — $failing_tests" \
        "E2E score: $e2e_score/100\nSHA: $latest_sha\nFailing: $failing_tests\nRecommend: Monitor logs" \
        "claude-auto,deploy,P2" 2>/dev/null || true

else
    verdict="FAIL"
    echo "$(date): ❌ Deployment FAILED ($e2e_score/100) — ROLLBACK" >> "$LOGFILE"

    # ─── Rollback Phase ───
    echo "$(date): Starting rollback..." >> "$LOGFILE"

    # Get previous deployment SHA (fetch ONCE, reuse for both display and branch creation)
    prev_sha_full=$(gh api "repos/$REPO/commits?per_page=2" --jq '.[1].sha' 2>/dev/null)
    prev_sha="${prev_sha_full:0:7}"

    if [[ -z "$prev_sha" || -z "$prev_sha_full" ]]; then
        echo "$(date): Cannot determine previous SHA — MANUAL ROLLBACK NEEDED" >> "$LOGFILE"
        touch "$ROLLBACK_LOCK"
        alert_send "CRITICAL" "deploy-verify" "Deploy FAIL ($e2e_score) + cannot rollback (no prev SHA) — MANUAL" "deploy" 2>/dev/null
        exit 1
    fi

    echo "$(date): Rolling back to SHA: $prev_sha" >> "$LOGFILE"
    alert_send "ERROR" "deploy-verify" "Deploy FAIL ($e2e_score/100) — Rolling back to $prev_sha" "deploy" 2>/dev/null

    # Revert: create branch from previous commit and open a PR
    revert_result=$(gh api "repos/$REPO/git/refs" \
        --method POST \
        -f ref="refs/heads/revert-$latest_sha" \
        -f sha="$prev_sha_full" 2>&1) || true

    if echo "$revert_result" | grep -q '"node_id"'; then
        # Create PR for revert
        if gh pr create --repo "$REPO" \
            --title "Auto-revert: Deploy $latest_sha failed (score: $e2e_score)" \
            --body "Automated rollback by deploy-verify.

E2E Score: $e2e_score/100
Target: revert to $prev_sha" \
            --head "revert-$latest_sha" \
            --base "main" \
            --label "claude-auto,rollback" 2>> "$LOGFILE"; then
            echo "$(date): Revert PR created" >> "$LOGFILE"
            alert_send "WARNING" "deploy-verify" "Revert PR created for $latest_sha → $prev_sha" "deploy" 2>/dev/null
        else
            echo "$(date): Revert PR creation FAILED — MANUAL ROLLBACK" >> "$LOGFILE"
            touch "$ROLLBACK_LOCK"
            alert_send "CRITICAL" "deploy-verify" "Deploy FAIL + PR create failed — CODE LOOP LOCKED" "deploy" 2>/dev/null
        fi
    else
        echo "$(date): Revert branch creation failed — MANUAL ROLLBACK" >> "$LOGFILE"
        touch "$ROLLBACK_LOCK"
        alert_send "CRITICAL" "deploy-verify" "Deploy FAIL + revert failed — CODE LOOP LOCKED" "deploy" 2>/dev/null
    fi

    # Save failed state
    atomic_write "$DEPLOY_STATE" "{\"last_verified_sha\":\"$latest_sha\",\"score\":$e2e_score,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"verdict\":\"FAIL\",\"rollback_to\":\"$prev_sha\"}"

    create_issue_safe "$REPO" \
        "🚨 Deploy FAIL — auto-rollback initiated" \
        "E2E score: $e2e_score/100\nSHA: $latest_sha\nRollback to: $prev_sha\nVerdict: FAIL" \
        "claude-auto,deploy,P0" 2>/dev/null || true
fi

# ─── Save results ───
result_file="$RESULTS_DIR/deploy-verify-$(date +%Y%m%d-%H%M).json"
atomic_write "$result_file" "{
  \"sha\": \"$latest_sha\",
  \"verdict\": \"$verdict\",
  \"e2e_score\": $e2e_score,
  \"tests\": {
    \"api_health\": {\"score\": ${test_scores[0]}, \"status\": \"$api_status\", \"time_ms\": $api_time},
    \"web_perf\": {\"score\": ${test_scores[1]}, \"status\": \"$web_status\", \"time_ms\": $web_time},
    \"backtest_api\": {\"score\": ${test_scores[2]}, \"status\": \"$bt_status\"},
    \"sec_headers\": {\"score\": ${test_scores[3]}, \"present\": $header_checks, \"total\": $total_headers}
  },
  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}"

echo "$(date): deploy-verify complete — $verdict ($e2e_score/100)" >> "$LOGFILE"
