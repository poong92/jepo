#!/bin/bash
# JEPO auto-deploy -- Merges tested PRs and deploys
# Flow: Find tested PR -> merge -> build -> deploy -> verify
# Schedule: every 15 minutes via LaunchAgent/cron
#
# SAFETY:
#   1. Only merges PRs with "tests-passed" label
#   2. Safe hours only (configurable)
#   3. Circuit breaker: 2 failed deploys -> stop for 4 hours
#   4. Post-deploy verification (health check)

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "auto-deploy"

LOGFILE="$LOG_DIR/auto-deploy.log"
REPO="${JEPO_REPO:?Set JEPO_REPO env var}"
REPO_DIR="${JEPO_REPO_DIR:?Set JEPO_REPO_DIR env var}"
CIRCUIT_FILE="$LOG_DIR/.auto-deploy-circuit"
FAILURE_COUNT_FILE="$LOG_DIR/.auto-deploy-failures"
DEPLOY_HISTORY="$LOG_DIR/auto-deploy-history.json"

# Configurable endpoints for verification
DEPLOY_WEB_URL="${JEPO_DEPLOY_WEB_URL:-}"
DEPLOY_API_URL="${JEPO_DEPLOY_API_URL:-}"

# Safe hours (24h format, local timezone)
SAFE_HOUR_START="${JEPO_SAFE_HOUR_START:-6}"
SAFE_HOUR_END="${JEPO_SAFE_HOUR_END:-22}"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

log "auto-deploy started"

# --- Circuit breaker check ---
if [[ -f "$CIRCUIT_FILE" ]]; then
    circuit_ts=$(cat "$CIRCUIT_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)
    if (( now - circuit_ts < 14400 )); then
        remaining=$(( (14400 - (now - circuit_ts)) / 60 ))
        log "Circuit breaker active (${remaining}min remaining), skipping"
        exit 0
    else
        rm -f "$CIRCUIT_FILE" "$FAILURE_COUNT_FILE"
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

# --- Safe hours check ---
current_hour=$(date +%H)
if (( 10#$current_hour < SAFE_HOUR_START || 10#$current_hour >= SAFE_HOUR_END )); then
    log "Outside safe deploy hours (${current_hour}h), skipping"
    exit 0
fi

# --- Find PR ready to deploy ---
pr_json=$(gh pr list --repo "$REPO" --label "tests-passed" --state open \
    --json number,headRefName,title,labels,mergeStateStatus \
    --jq '[.[] | select(
        (.labels | map(.name) | contains(["deployed"]) | not) and
        (.mergeStateStatus == "CLEAN" or .mergeStateStatus == "UNKNOWN")
    )] | sort_by(.number) | .[0]' 2>/dev/null)

if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
    log "No PRs ready to deploy"
    exit 0
fi

pr_number=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
pr_title=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'][:100])")
pr_branch=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['headRefName'])")

if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
    log "Invalid PR data, skipping"
    exit 0
fi

log "Deploying PR #$pr_number: $pr_title"

pre_deploy_sha=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null | head -c 7)

# --- Merge PR ---
pr_state=$(gh pr view --repo "$REPO" "$pr_number" --json state --jq '.state' 2>/dev/null)
if [[ "$pr_state" != "MERGED" ]]; then
    merge_output=$(gh pr merge --repo "$REPO" "$pr_number" --squash --delete-branch 2>&1)
    if ! echo "$merge_output" | grep -qiE "merged|successfully|already"; then
        log "Merge failed: $merge_output"
        alert_send "ERROR" "auto-deploy" "PR #$pr_number merge failed" "deploy"
        record_deploy_failure
        exit 1
    fi
fi

log "PR #$pr_number merged"

# --- Build + Deploy ---
WORKTREE="/tmp/jepo-autodeploy-$(date +%s)"
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

# Install dependencies
if [[ -f "package.json" ]]; then
    npm ci --prefer-offline 2>/dev/null || npm ci 2>/dev/null || {
        log "npm ci failed, falling back to symlink"
        ln -s "$REPO_DIR/node_modules" "$WORKTREE/node_modules"
    }
fi

# Build
log "Building..."
build_output=$(timeout 180 npm run build 2>&1)
if [[ $? -ne 0 ]]; then
    log "Build FAILED: $(echo "$build_output" | tail -5)"
    record_deploy_failure
    alert_send "ERROR" "auto-deploy" "Build failed after merging PR #$pr_number" "deploy"
    exit 1
fi
log "Build succeeded"

# Deploy command (customize per project)
# Example: npx wrangler deploy, rsync, docker build+push, etc.
DEPLOY_CMD="${JEPO_DEPLOY_CMD:-}"
if [[ -n "$DEPLOY_CMD" ]]; then
    log "Deploying: $DEPLOY_CMD"
    deploy_output=$(timeout 120 bash -c "$DEPLOY_CMD" 2>&1)
    if [[ $? -ne 0 ]]; then
        log "Deploy FAILED: $(echo "$deploy_output" | tail -5)"
        record_deploy_failure
        alert_send "ERROR" "auto-deploy" "Deploy failed for PR #$pr_number" "deploy"
        exit 1
    fi
    log "Deploy succeeded"
fi

# Label PR as deployed
gh pr edit --repo "$REPO" "$pr_number" --add-label "deployed" 2>/dev/null || true

# --- Learning: extract fix pattern ---
"$(dirname "$0")/extract-pattern.sh" "$pr_number" "$REPO" 2>/dev/null || true

# --- Post-deploy verification ---
if [[ -n "$DEPLOY_WEB_URL" ]]; then
    sleep 15
    web_status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$DEPLOY_WEB_URL" 2>/dev/null || echo "000")
    log "Post-deploy: web=$web_status"
    if [[ "$web_status" != "200" ]]; then
        log "Web check FAILED ($web_status)"
        record_deploy_failure
        alert_send "CRITICAL" "auto-deploy" "Post-deploy web FAILED ($web_status) -- PR #$pr_number" "deploy"
        exit 1
    fi
fi

if [[ -n "$DEPLOY_API_URL" ]]; then
    api_status=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$DEPLOY_API_URL/health" 2>/dev/null || echo "000")
    log "Post-deploy: api=$api_status"
fi

# --- Record success ---
rm -f "$FAILURE_COUNT_FILE"
post_sha=$(git -C "$REPO_DIR" rev-parse origin/main 2>/dev/null | head -c 7)

json_append "$DEPLOY_HISTORY" "{
  \"pr\": $pr_number,
  \"title\": \"$(echo "$pr_title" | tr '"' "'")\",
  \"pre_sha\": \"$pre_deploy_sha\",
  \"post_sha\": \"$post_sha\",
  \"web_status\": ${web_status:-0},
  \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}" 100

log "PR #$pr_number deployed successfully"
alert_send "INFO" "auto-deploy" "PR #$pr_number deployed: $pr_title" "deploy"
send_telegram "<b>[auto-deploy]</b> PR #$pr_number deployed: $pr_title"

rate_increment "auto-deploy" "github"
