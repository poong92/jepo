#!/bin/bash
# review-responder — Auto-fix PRs that received REQUEST_CHANGES
# Schedule: every 30 minutes via LaunchAgent
#
# Flow:
#   1. Find open PRs with REQUEST_CHANGES from claude-auto-review
#   2. Extract review feedback
#   3. Checkout PR branch, ask Claude to fix
#   4. Push fixes → pr-review.sh re-reviews on next cycle
#
# SECURITY:
#   - Claude restricted to Read, Glob, Grep, Edit, Write (no Bash)
#   - Max 1 PR per run
#   - Only processes reviews older than 30 minutes (avoid race with OpenClaw)
#   - Temp workdir cleaned on exit

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"
acquire_lock "review-responder"

LOGFILE="$LOG_DIR/review-responder.log"
rotate_log "$LOGFILE"

REPO="pruviq/pruviq"
REPO_URL="https://github.com/$REPO.git"
REVIEW_MARKER="<!-- claude-auto-review -->"
WORK_DIR="/tmp/claude-review-responder-$$"
MAX_PER_RUN=1
MIN_AGE_MINUTES=30

# Cleanup workdir on exit
LOCKDIR="$LOCK_DIR/review-responder.lockdir"
trap "rm -rf '$WORK_DIR' '$LOCKDIR'" EXIT

echo "$(date): review-responder started" >> "$LOGFILE"

if ! check_auth; then
    echo "$(date): Auth failed, aborting" >> "$LOGFILE"
    exit 1
fi

# Rate limit check
if ! rate_check "review-responder" "claude" >/dev/null 2>&1; then
    echo "$(date): Rate limited, skipping" >> "$LOGFILE"
    exit 0
fi

# Get open PRs
prs=$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null)
if [[ -z "$prs" ]]; then
    echo "$(date): No open PRs" >> "$LOGFILE"
    exit 0
fi

fixed=0
for pr_num in $prs; do
    [[ $fixed -ge $MAX_PER_RUN ]] && break

    # Check if this PR has a REQUEST_CHANGES review from claude-auto
    review_comment=$(gh pr view "$pr_num" --repo "$REPO" --json comments \
        --jq '[.comments[] | select(.body | contains("claude-auto-review")) | select(.body | contains("REQUEST_CHANGES"))] | last | .body' 2>/dev/null)

    if [[ -z "$review_comment" || "$review_comment" == "null" ]]; then
        continue
    fi

    # Check review age (skip if too recent — let OpenClaw handle first)
    review_ts=$(gh pr view "$pr_num" --repo "$REPO" --json comments \
        --jq '[.comments[] | select(.body | contains("claude-auto-review")) | .createdAt] | last' 2>/dev/null)
    last_commit_ts=$(gh pr view "$pr_num" --repo "$REPO" --json commits \
        --jq '.commits[-1].committedDate' 2>/dev/null)

    # Skip if there are already newer commits (OpenClaw or someone is fixing)
    if [[ -n "$review_ts" && -n "$last_commit_ts" && "$last_commit_ts" > "$review_ts" ]]; then
        echo "$(date): PR #$pr_num has commits after review, skipping (someone fixing)" >> "$LOGFILE"
        continue
    fi

    # Check if review is old enough
    age_min=0
    if [[ -n "$review_ts" ]]; then
        review_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$review_ts" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        age_min=$(( (now_epoch - review_epoch) / 60 ))
        if [[ $age_min -lt $MIN_AGE_MINUTES ]]; then
            echo "$(date): PR #$pr_num review too recent (${age_min}min < ${MIN_AGE_MINUTES}min), skipping" >> "$LOGFILE"
            continue
        fi
    fi

    echo "$(date): Fixing PR #$pr_num (review age: ${age_min}min)" >> "$LOGFILE"

    # Get PR metadata
    pr_title=$(gh pr view "$pr_num" --repo "$REPO" --json title --jq '.title' 2>/dev/null)
    pr_branch=$(gh pr view "$pr_num" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null)
    pr_files=$(gh pr view "$pr_num" --repo "$REPO" --json files --jq '.files[].path' 2>/dev/null)

    if [[ -z "$pr_branch" ]]; then
        echo "$(date): PR #$pr_num no branch found, skipping" >> "$LOGFILE"
        continue
    fi

    # Clone repo and checkout PR branch
    mkdir -p "$WORK_DIR"
    if ! gh repo clone "$REPO" "$WORK_DIR/repo" -- --depth 10 2>> "$LOGFILE"; then
        echo "$(date): Clone failed for PR #$pr_num" >> "$LOGFILE"
        continue
    fi

    cd "$WORK_DIR/repo"
    # Set remote URL with gh token for push auth (LaunchAgent has no interactive credential helper)
    GH_TOKEN=$(gh auth token 2>/dev/null)
    if [[ -n "$GH_TOKEN" ]]; then
        git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
    fi
    # Shallow clone only has default branch — fetch the PR branch as local ref
    if ! git fetch origin "${pr_branch}:${pr_branch}" --depth 10 2>> "$LOGFILE"; then
        echo "$(date): Fetch branch $pr_branch failed" >> "$LOGFILE"
        cd /
        continue
    fi
    if ! git checkout "$pr_branch" 2>> "$LOGFILE"; then
        echo "$(date): Checkout $pr_branch failed" >> "$LOGFILE"
        cd /
        continue
    fi

    # Get the diff for context
    DIFF_FILE="$WORK_DIR/pr-diff.txt"
    gh pr diff "$pr_num" --repo "$REPO" > "$DIFF_FILE" 2>/dev/null
    # Truncate diff to 4000 chars
    if [[ $(wc -c < "$DIFF_FILE") -gt 4000 ]]; then
        head -c 4000 "$DIFF_FILE" > "${DIFF_FILE}.tmp"
        printf '\n[TRUNCATED]\n' >> "${DIFF_FILE}.tmp"
        mv "${DIFF_FILE}.tmp" "$DIFF_FILE"
    fi

    # Extract review summary (clean markdown — single backslash for octal ranges)
    review_summary=$(echo "$review_comment" | head -c 1000 | tr -d '\000-\010\013\014\016-\037')

    # Run Claude to fix the issues
    # SECURITY: Only file-manipulation tools, no Bash execution
    fix_result=$(claude --model "$MODEL_OPUS" -p "You are fixing a PR that received REQUEST_CHANGES review.

PR #$pr_num: $pr_title
Branch: $pr_branch
Changed files: $pr_files

Review feedback:
$review_summary

The PR diff is at: $DIFF_FILE
The repository is at: $WORK_DIR/repo

Instructions:
1. Read the review feedback carefully
2. Read the changed files
3. Fix the issues identified in the review
4. Make minimal, focused fixes — do not add unrelated changes
5. Do NOT create new files unless absolutely necessary
6. Do NOT modify test files or add tests" \
        --allowedTools "Read,Glob,Grep,Edit,Write" \
        --max-turns 10 2>&1)

    rate_increment "review-responder" "claude"

    # Check if files were actually changed
    changes=$(git diff --stat 2>/dev/null)
    if [[ -z "$changes" ]]; then
        echo "$(date): PR #$pr_num no changes made by Claude" >> "$LOGFILE"
        cd /
        rm -rf "$WORK_DIR"
        mkdir -p "$WORK_DIR"
        continue
    fi

    echo "$(date): PR #$pr_num changes: $changes" >> "$LOGFILE"

    # Commit and push — with error handling to avoid set -e killing the loop
    if ! git -c user.email="claude-auto@pruviq.com" -c user.name="Claude Auto" \
        add -A 2>> "$LOGFILE"; then
        echo "$(date): PR #$pr_num git add failed" >> "$LOGFILE"
        cd /; rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
        continue
    fi
    if ! git -c user.email="claude-auto@pruviq.com" -c user.name="Claude Auto" \
        commit -m "fix: address review feedback for PR #$pr_num

Auto-fix by review-responder based on claude-auto-review feedback.

Co-Authored-By: Claude Code <noreply@anthropic.com>" 2>> "$LOGFILE"; then
        echo "$(date): PR #$pr_num git commit failed (no changes or hook error)" >> "$LOGFILE"
        cd /; rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
        continue
    fi

    if git push origin "$pr_branch" 2>> "$LOGFILE"; then
        echo "$(date): PR #$pr_num fix pushed successfully" >> "$LOGFILE"
        fixed=$((fixed + 1))

        # Add comment noting the auto-fix
        gh pr comment "$pr_num" --repo "$REPO" --body "<!-- review-responder -->
**Auto-fix applied** based on review feedback. pr-review will re-evaluate on next cycle.

---
*Automated fix by review-responder (PRUVIQ CI)*" 2>> "$LOGFILE" || true

        alert_send "INFO" "review-responder" "PR #$pr_num auto-fixed and pushed" "code" 2>/dev/null
    else
        echo "$(date): PR #$pr_num push failed" >> "$LOGFILE"
        alert_send "WARNING" "review-responder" "PR #$pr_num fix push failed" "code" 2>/dev/null
    fi

    cd /
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
done

echo "$(date): review-responder complete — $fixed PRs fixed" >> "$LOGFILE"
