#!/bin/bash
# auto-deploy — Merges tested PRs and deploys to Cloudflare Workers
# Flow: Find tested PR → merge → worktree → build → deploy → verify
# Schedule: every 15 minutes via LaunchAgent
#
# SAFETY:
#   1. Only merges PRs with "tests-passed" label (any PR, not just auto-fix)
#   2. Safe hours only: 06:00-22:00 KST
#   3. Circuit breaker: 2 failed deploys → stop for 4 hours
#   4. Post-deploy verification (web + API health check)
#   5. Build + deploy in isolated worktree

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "auto-deploy"

LOGFILE="$LOG_DIR/auto-deploy.log"
REPO="pruviq/pruviq"
REPO_DIR="$HOME/pruviq"
CIRCUIT_FILE="$LOG_DIR/.auto-deploy-circuit"
FAILURE_COUNT_FILE="$LOG_DIR/.auto-deploy-failures"
DEPLOY_HISTORY="$LOG_DIR/auto-deploy-history.json"
PRUVIQ_WEB="https://pruviq.com"
PRUVIQ_API="https://api.pruviq.com"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

log "auto-deploy started"

# ─── Circuit breaker check ───
if [[ -f "$CIRCUIT_FILE" ]]; then
    circuit_ts=$(cat "$CIRCUIT_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)
    if (( now - circuit_ts < 14400 )); then
        remaining=$(( (14400 - (now - circuit_ts)) / 60 ))
        log "Circuit breaker active (${remaining}min remaining), skipping"
        exit 0
    else
        rm -f "$CIRCUIT_FILE" "$FAILURE_COUNT_FILE"
        log "Circuit breaker expired, resuming"
    fi
fi

record_deploy_failure() {
    local count=0
    if [[ -f "$FAILURE_COUNT_FILE" ]]; then
        count=$(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo "0")
    fi
    count=$((count + 1))
    echo "$count" > "$FAILURE_COUNT_FILE"
    if (( count >= 2 )); then
        date +%s > "$CIRCUIT_FILE"
        log "Deploy circuit breaker TRIPPED after $count failures"
        alert_send "CRITICAL" "auto-deploy" "Deploy circuit breaker tripped (${count} failures)" "deploy"
    fi
}

# ─── Safe hours check (06:00-22:00 KST) ───
hour_kst=$(TZ=Asia/Seoul date +%H)
if (( 10#$hour_kst < 6 || 10#$hour_kst >= 22 )); then
    log "Outside safe deploy hours (${hour_kst} KST), skipping"
    exit 0
fi

# ─── Find PR ready to deploy ───
# Check both open PRs AND recently merged PRs that haven't been deployed
# CRITICAL: fetch mergeStateStatus to skip CONFLICTING/DIRTY PRs — root cause of deploy loop
pr_json=$(gh pr list --repo "$REPO" --label "tests-passed" --state open \
    --json number,headRefName,title,labels,mergeStateStatus \
    --jq '[.[] | select(
        (.labels | map(.name) | contains(["deployed"]) | not) and
        (.mergeStateStatus == "CLEAN" or .mergeStateStatus == "UNKNOWN")
    )] | sort_by(.number) | .[0]' 2>/dev/null)

# Also check merged PRs with tests-passed but not deployed (automerge race)
if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
    pr_json=$(gh pr list --repo "$REPO" --label "tests-passed" --state merged \
        --json number,headRefName,title,labels,mergedAt -L 5 \
        --jq '[.[] | select(.labels | map(.name) | contains(["deployed"]) | not)] | sort_by(.number) | .[0]' 2>/dev/null)
fi

if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
    # Check if there are CONFLICTING PRs that need alerting (once per PR, not every run)
    conflicting=$(gh pr list --repo "$REPO" --label "tests-passed" --state open \
        --json number,title,mergeStateStatus \
        --jq '[.[] | select(.mergeStateStatus == "DIRTY" or .mergeStateStatus == "CONFLICTING")] | .[0]' 2>/dev/null)
    if [[ -n "$conflicting" && "$conflicting" != "null" ]]; then
        conflict_num=$(echo "$conflicting" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])" 2>/dev/null)
        conflict_title=$(echo "$conflicting" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'][:60])" 2>/dev/null)
        # Add conflict label to prevent repeated alerts
        has_conflict_label=$(gh pr view --repo "$REPO" "$conflict_num" --json labels \
            --jq '.labels | map(.name) | contains(["conflict"])' 2>/dev/null)
        if [[ "$has_conflict_label" != "true" ]]; then
            gh pr edit --repo "$REPO" "$conflict_num" --add-label "conflict" 2>/dev/null || true
            alert_send "WARNING" "auto-deploy" "PR #${conflict_num} has merge conflict — manual rebase needed: ${conflict_title}" "deploy"
            log "CONFLICT: PR #${conflict_num} skipped (DIRTY/CONFLICTING) — labeled and alerted"
        else
            log "CONFLICT: PR #${conflict_num} still conflicting (already alerted)"
        fi
    else
        log "No PRs ready to deploy"
    fi
    exit 0
fi

pr_number=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
pr_title=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'][:100])")
pr_branch=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['headRefName'])")

# Guard: skip if PR data is invalid (empty number/branch from race or stale label)
if [[ -z "$pr_number" || "$pr_number" == "null" || -z "$pr_branch" || "$pr_branch" == "null" ]]; then
    log "Skipping: invalid PR data (number='$pr_number' branch='$pr_branch')"
    exit 0
fi

log "Deploying PR #$pr_number: $pr_title"

# ─── Pre-deploy snapshot (for rollback reference) ───
pre_deploy_sha=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null | head -c 7)
log "Pre-deploy SHA: $pre_deploy_sha"

# ─── Check PR state — may already be merged by automerge ───
pr_state=$(gh pr view --repo "$REPO" "$pr_number" --json state --jq '.state' 2>/dev/null)
if [[ "$pr_state" == "MERGED" ]]; then
    log "PR #$pr_number already merged (automerge), proceeding to deploy"
else
    # Merge PR (squash)
    merge_output=$(gh pr merge --repo "$REPO" "$pr_number" --squash --delete-branch 2>&1)
    if ! echo "$merge_output" | grep -qiE "merged|successfully|already"; then
        # Re-check state — automerge may have completed during our attempt
        pr_state_retry=$(gh pr view --repo "$REPO" "$pr_number" --json state --jq '.state' 2>/dev/null)
        if [[ "$pr_state_retry" == "MERGED" ]]; then
            log "PR #$pr_number merged by automerge (race resolved), proceeding to deploy"
        else
            # Try enabling auto-merge if branch protections exist
            auto_output=$(gh pr merge --repo "$REPO" "$pr_number" --squash --auto 2>&1)
            if echo "$auto_output" | grep -qiE "enabled|Enabled"; then
                log "Auto-merge enabled for PR #$pr_number (waiting for CI)"
                alert_send "INFO" "auto-deploy" "Auto-merge enabled for PR #$pr_number (waiting for CI)" "deploy"
                exit 0
            fi
            log "Merge failed: $merge_output / $auto_output"
            alert_send "ERROR" "auto-deploy" "PR #$pr_number merge failed" "deploy"
            record_deploy_failure
            exit 1
        fi
    fi
fi

log "PR #$pr_number merged successfully"

# ─── Build + Deploy in isolated worktree ───
WORKTREE="/tmp/pruviq-autodeploy-$(date +%s)"
cleanup() {
    cd "$HOME" 2>/dev/null
    if [[ -d "$WORKTREE" ]]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
    fi
}
trap 'cleanup; rm -rf "/tmp/claude-auto-locks/auto-deploy.lockdir"' EXIT

cd "$REPO_DIR"
git fetch origin main 2>/dev/null

git worktree add "$WORKTREE" origin/main --detach 2>/dev/null || {
    log "Failed to create deploy worktree"
    record_deploy_failure
    exit 1
}

cd "$WORKTREE"

# Install dependencies in worktree (--prefer-offline uses cache, ~10s)
# NOTE: symlink was replaced because it caused stale JS bundle hashes
# when components changed (e.g. FeeCalculator hash mismatch, 2026-03-22)
if npm ci --prefer-offline 2>/dev/null; then
    log "npm ci succeeded (prefer-offline)"
elif npm ci 2>/dev/null; then
    log "npm ci succeeded (full install)"
else
    log "WARNING: npm ci failed, falling back to symlink — builds may use stale deps"
    ln -s "$REPO_DIR/node_modules" "$WORKTREE/node_modules"
fi

# Build
log "Building..."
build_output=$(timeout 180 npm run build 2>&1)
build_rc=$?
if [[ $build_rc -ne 0 ]]; then
    log "Build FAILED (rc=$build_rc): $(echo "$build_output" | tail -5)"
    record_deploy_failure
    alert_send "ERROR" "auto-deploy" "Build failed after merging PR #$pr_number" "deploy"
    exit 1
fi

page_count=$(echo "$build_output" | grep -oE '[0-9,]+ pages' | head -1 || echo "unknown")
log "Build succeeded: $page_count"

# Deploy to Cloudflare Workers
log "Deploying to Cloudflare Workers..."
deploy_output=$(timeout 120 npx wrangler deploy 2>&1)
deploy_rc=$?
if [[ $deploy_rc -ne 0 ]]; then
    log "Wrangler deploy FAILED (rc=$deploy_rc): $(echo "$deploy_output" | tail -5)"
    record_deploy_failure
    alert_send "ERROR" "auto-deploy" "CF deploy failed after PR #$pr_number" "deploy"
    exit 1
fi

log "CF Workers deploy succeeded"

# Post-deploy verification: 빌드 해시로 실제 반영 확인 (2026-03-22 롤백 사건 재발 방지)
DEPLOY_HASH=$(md5 -q dist/index.html 2>/dev/null || md5sum dist/index.html 2>/dev/null | cut -d' ' -f1)
log "Deploy hash (local): $DEPLOY_HASH"
sleep 5  # CF edge propagation
LIVE_HASH=$(curl -sf --compressed --max-time 15 "https://pruviq.com/" | md5 2>/dev/null || echo "fetch_failed")
log "Deploy hash (live): $LIVE_HASH"
if [[ "$DEPLOY_HASH" != "$LIVE_HASH" && "$LIVE_HASH" != "fetch_failed" ]]; then
    log "WARNING: deploy hash mismatch — live site may not reflect latest build"
    alert_send "WARNING" "auto-deploy" "Deploy hash mismatch after PR #$pr_number. Local: $DEPLOY_HASH, Live: $LIVE_HASH" "deploy"
fi

# Label PR as deployed immediately after CF deploy (prevent re-deployment on timeout)
gh pr edit --repo "$REPO" "$pr_number" --add-label "deployed" 2>/dev/null || true
log "PR #$pr_number labeled as deployed"

# ─── Learning: extract fix pattern ───
"$(dirname "$0")/extract-pattern.sh" "$pr_number" "$REPO" 2>/dev/null || true

# ─── Backend API sync (git pull + uvicorn restart) ───
log "Syncing backend API code..."
backend_sync_ok=true

# Ensure main branch and pull latest
cd "$REPO_DIR"
git fetch origin main 2>/dev/null

current_branch=$(git branch --show-current 2>/dev/null)
if [[ "$current_branch" != "main" ]]; then
    log "WARNING: repo on branch $current_branch, switching to main"
    git checkout main -f 2>/dev/null || true
fi

# 미커밋 변경사항 있으면 stash → merge → stash pop, 실패 시 알림
if ! git diff --quiet 2>/dev/null || ! git diff --staged --quiet 2>/dev/null; then
    log "Uncommitted changes detected, using stash to preserve them"
    stash_name="auto-deploy-preserve-$(date +%s)"
    git stash push -m "$stash_name" 2>/dev/null
    git merge --ff-only origin/main 2>/dev/null || git reset --hard origin/main 2>/dev/null
    if ! git stash pop 2>/dev/null; then
        log "Stash pop failed — changes saved in stash '$stash_name'"
        send_telegram "⚠️ auto-deploy: Mac Mini stash conflict. Run 'git stash list' to check. Changes preserved in stash." 2>/dev/null || true
        # Don't block — just reset to clean state for next deploy
        git reset --hard origin/main 2>/dev/null
    else
        log "Stash restored"
    fi
else
    git reset --hard origin/main 2>/dev/null
fi

# Check if backend files changed in this PR
backend_changed=$(git diff --name-only "$pre_deploy_sha"..origin/main 2>/dev/null | grep "^backend/" | head -1)
if [[ -n "$backend_changed" ]]; then
    log "Backend files changed, restarting uvicorn..."
    # Install new dependencies if requirements changed
    req_changed=$(git diff --name-only "$pre_deploy_sha"..origin/main 2>/dev/null | grep "requirements.txt" | head -1)
    if [[ -n "$req_changed" ]]; then
        log "requirements.txt changed, installing..."
        cd "$REPO_DIR/backend"
        source .venv/bin/activate 2>/dev/null
        bash_timeout 120 pip install -q -r requirements.txt 2>/dev/null || log "WARNING: pip install timed out or failed, continuing"
    fi
    # Restart uvicorn via LaunchAgent
    launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.pruviq.api.plist 2>/dev/null || true
    pkill -9 -f "uvicorn api.main" 2>/dev/null || true
    sleep 3
    launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.pruviq.api.plist 2>/dev/null || {
        # Fallback: direct start
        cd "$REPO_DIR/backend"
        source .venv/bin/activate 2>/dev/null
        nohup python -m uvicorn api.main:app --host 127.0.0.1 --port 8080 --workers 1 >> ~/logs/pruviq/api.log 2>&1 &
    }
    log "uvicorn restart initiated"
    # Wait for API to be ready (coins loading takes ~90s)
    for i in 1 2 3 4; do
        sleep 30
        api_check=$(curl -s -m 5 http://localhost:8080/health 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('coins_loaded',0))" 2>/dev/null || echo "0")
        if [[ "$api_check" -gt 400 ]]; then
            log "Backend API ready: $api_check coins loaded"
            break
        fi
        log "Waiting for API... attempt $i (coins: $api_check)"
    done
else
    log "No backend changes, skipping uvicorn restart"
fi
cd "$REPO_DIR"

# ─── Post-deploy verification ───
log "Waiting 15s for propagation..."
sleep 15

web_status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$PRUVIQ_WEB" 2>/dev/null || echo "000")
api_status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$PRUVIQ_API/health" 2>/dev/null || echo "000")
api_coins=$(curl -s -m 10 "$PRUVIQ_API/health" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('coins_loaded',0))" 2>/dev/null || echo "0")

log "Post-deploy: web=$web_status api=$api_status coins=$api_coins"

if [[ "$web_status" != "200" ]]; then
    log "Web check FAILED ($web_status)"
    record_deploy_failure
    alert_send "CRITICAL" "auto-deploy" "Post-deploy web FAILED ($web_status) — PR #$pr_number" "deploy"
    exit 1
fi

if [[ "$api_status" != "200" ]]; then
    log "API check FAILED ($api_status)"
    alert_send "WARNING" "auto-deploy" "Post-deploy API WARN ($api_status) — PR #$pr_number (web OK)" "deploy"
    # API might be on Mac Mini, not CF. Don't fail for this.
fi

# ─── Record success ───
rm -f "$FAILURE_COUNT_FILE"
post_sha=$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null | head -c 7)

json_append "$DEPLOY_HISTORY" "{
  \"pr\": $pr_number,
  \"title\": \"$(echo "$pr_title" | tr '"' "'")\",
  \"pre_sha\": \"$pre_deploy_sha\",
  \"post_sha\": \"$post_sha\",
  \"pages\": \"$page_count\",
  \"web_status\": $web_status,
  \"api_status\": $api_status,
  \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}" 100

# Label PR as deployed (prevent re-deployment)
gh pr edit --repo "$REPO" "$pr_number" --add-label "deployed" 2>/dev/null || true

log "PR #$pr_number deployed successfully (web:$web_status api:$api_status coins:$api_coins)"
alert_send "INFO" "auto-deploy" "PR #$pr_number deployed: $pr_title (web:$web_status)" "deploy"
send_telegram "<b>[auto-deploy]</b> PR #$pr_number deployed: $pr_title
web:$web_status api:$api_status coins:$api_coins"

rate_increment "auto-deploy" "github"
