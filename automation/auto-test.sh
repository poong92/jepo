#!/bin/bash
# JEPO auto-test -- Runs tests on auto-fix PRs in isolated worktree
# Flow: Find untested PR -> worktree -> build -> lint -> comment -> label
# Schedule: every 10 minutes via LaunchAgent/cron
#
# SAFETY:
#   1. All tests in isolated git worktree
#   2. Symlinks node_modules from main repo (fast, no npm install)
#   3. Timeout: 5 minutes max per test stage
#   4. Results commented on PR + label applied

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "auto-test"

LOGFILE="$LOG_DIR/auto-test.log"
REPO="${JEPO_REPO:?Set JEPO_REPO env var}"
REPO_DIR="${JEPO_REPO_DIR:?Set JEPO_REPO_DIR env var}"
STAGE_TIMEOUT=300  # 5 minutes per stage

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

log "auto-test started"

# --- Find PR that needs testing ---
pr_json=$(gh pr list --repo "$REPO" --state open \
    --json number,headRefName,title,labels \
    --jq '[.[] | select(.labels | map(.name) | (contains(["tests-passed"]) or contains(["tests-failed"])) | not)] | sort_by(.number) | .[0]' 2>/dev/null)

if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
    log "No PRs to test"
    exit 0
fi

pr_number=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['number'])")
pr_branch=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['headRefName'])")
pr_title=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'][:100])")

log "Testing PR #$pr_number: $pr_title (branch: $pr_branch)"

# --- Create isolated worktree ---
WORKTREE="/tmp/jepo-autotest-${pr_number}"
cleanup() {
    cd "$HOME" 2>/dev/null
    if [[ -d "$WORKTREE" ]]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
    fi
}
trap 'cleanup; rm -rf "/tmp/claude-auto-locks/auto-test.lockdir"' EXIT

cleanup
cd "$REPO_DIR"
git fetch origin 2>/dev/null

git worktree add "$WORKTREE" "origin/$pr_branch" --detach 2>/dev/null || {
    git fetch origin "$pr_branch" 2>/dev/null
    git worktree add "$WORKTREE" "origin/$pr_branch" --detach 2>/dev/null || {
        log "Cannot create worktree for branch $pr_branch"
        exit 1
    }
}

cd "$WORKTREE"

# Symlink node_modules from main repo (avoid npm install)
if [[ -d "$REPO_DIR/node_modules" && ! -e "$WORKTREE/node_modules" ]]; then
    ln -s "$REPO_DIR/node_modules" "$WORKTREE/node_modules"
    log "Symlinked node_modules from main repo"
fi

# --- Test stages ---
set +e
test_results=""
all_passed=true
stages_run=0

# Stage 1: TypeScript check (non-blocking)
if command -v npx &>/dev/null && [[ -f "tsconfig.json" ]]; then
    log "Stage 1: TypeScript check"
    tsc_output=$(timeout $STAGE_TIMEOUT npx tsc --noEmit 2>&1)
    tsc_rc=$?
    if [[ $tsc_rc -eq 0 ]]; then
        test_results+="| TypeScript | PASS | - |\n"
    else
        error_count=$(echo "$tsc_output" | grep -cE "^(src|app)/" || echo "0")
        test_results+="| TypeScript | WARN | ${error_count} errors (non-blocking) |\n"
    fi
    stages_run=$((stages_run + 1))
fi

# Stage 2: Build
if [[ -f "package.json" ]]; then
    log "Stage 2: Build"
    build_output=$(timeout $STAGE_TIMEOUT npm run build 2>&1)
    build_rc=$?
    if [[ $build_rc -eq 0 ]]; then
        test_results+="| Build | PASS | - |\n"
    elif [[ $build_rc -eq 124 ]]; then
        test_results+="| Build | TIMEOUT | Exceeded ${STAGE_TIMEOUT}s |\n"
        all_passed=false
    else
        error_summary=$(echo "$build_output" | grep -iE "error|failed" | tail -3 | tr '\n' ' ')
        test_results+="| Build | FAIL | ${error_summary:0:200} |\n"
        all_passed=false
    fi
    stages_run=$((stages_run + 1))

    # Stage 3: Lint (non-blocking)
    log "Stage 3: Lint"
    lint_output=$(timeout $STAGE_TIMEOUT npm run lint 2>&1)
    lint_rc=$?
    if [[ $lint_rc -eq 0 ]]; then
        test_results+="| Lint | PASS | - |\n"
    else
        test_results+="| Lint | WARN | non-blocking |\n"
    fi
    stages_run=$((stages_run + 1))
fi

log "All stages complete: $stages_run stages, all_passed=$all_passed"

# --- Comment results on PR ---
comment_body="## Auto-Test Results for PR #$pr_number

| Stage | Result | Details |
|-------|--------|---------|
$(echo -e "$test_results")

### Verdict: $(if $all_passed; then echo '**PASS**'; else echo '**FAIL**'; fi)

---
*Auto-tested by JEPO auto-test agent (${stages_run} stages)*"

gh pr comment --repo "$REPO" "$pr_number" --body "$comment_body" 2>/dev/null || {
    log "Failed to comment on PR"
}

# --- Guard: close empty PRs ---
pr_changes=$(gh pr view --repo "$REPO" "$pr_number" --json additions,deletions --jq '.additions + .deletions' 2>/dev/null || echo "1")
if [[ "$pr_changes" == "0" ]]; then
    log "PR #$pr_number has 0 changes -- closing"
    gh pr close --repo "$REPO" "$pr_number" --comment "Auto-closed: PR has no code changes." 2>/dev/null
    exit 0
fi

# --- Label PR ---
if $all_passed; then
    gh pr edit --repo "$REPO" "$pr_number" --add-label "tests-passed" 2>/dev/null
    log "PR #$pr_number PASSED"
    alert_send "INFO" "auto-test" "PR #$pr_number tests PASSED: $pr_title" "code"
else
    gh pr edit --repo "$REPO" "$pr_number" --add-label "tests-failed" 2>/dev/null
    log "PR #$pr_number FAILED"
    alert_send "WARNING" "auto-test" "PR #$pr_number tests FAILED: $pr_title" "code"
fi

rate_increment "auto-test" "github"
