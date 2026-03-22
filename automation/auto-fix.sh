#!/bin/bash
# JEPO auto-fix -- Automatically fixes GitHub Issues labeled "claude-auto"
# Flow: Pick issue -> worktree -> Claude analyzes -> fixes -> scope check -> commit -> PR
# Schedule: every 30 minutes via LaunchAgent/cron
#
# SAFETY:
#   1. Configurable PR limit per day (rate-limiter)
#   2. Max files/lines changed per PR (configurable)
#   3. Claude restricted to: Read, Glob, Grep, Edit, Write (NO Bash)
#   4. Circuit breaker: 3 failures in 2h -> pause
#   5. All work in isolated git worktree (never touches main repo)

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "auto-fix"

LOGFILE="$LOG_DIR/auto-fix.log"
REPO="${JEPO_REPO:?Set JEPO_REPO env var (e.g. owner/repo)}"
REPO_DIR="${JEPO_REPO_DIR:?Set JEPO_REPO_DIR env var (local clone path)}"
MAX_PRS_PER_DAY="${JEPO_MAX_PRS_PER_DAY:-30}"
MAX_FILES="${JEPO_MAX_FILES:-20}"
MAX_LINES="${JEPO_MAX_LINES:-1500}"
CIRCUIT_FILE="$LOG_DIR/.auto-fix-circuit"
FAILURE_COUNT_FILE="$LOG_DIR/.auto-fix-failures"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

log "auto-fix started"

# --- Circuit breaker check ---
if [[ -f "$CIRCUIT_FILE" ]]; then
    circuit_ts=$(cat "$CIRCUIT_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)
    if (( now - circuit_ts < 7200 )); then
        remaining=$(( (7200 - (now - circuit_ts)) / 60 ))
        log "Circuit breaker active (${remaining}min remaining), skipping"
        exit 0
    else
        rm -f "$CIRCUIT_FILE" "$FAILURE_COUNT_FILE"
        log "Circuit breaker expired, resuming"
    fi
fi

# --- Rate limit check ---
if ! current_count=$(rate_check "auto-fix" "github" $MAX_PRS_PER_DAY); then
    log "Daily PR limit ($MAX_PRS_PER_DAY) reached, skipping"
    exit 0
fi

# --- Auth check ---
if ! check_auth; then
    log "Auth failed, aborting"
    exit 1
fi

# --- Circuit breaker helpers ---
record_failure() {
    local count=0
    if [[ -f "$FAILURE_COUNT_FILE" ]]; then
        count=$(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo "0")
    fi
    count=$((count + 1))
    echo "$count" > "$FAILURE_COUNT_FILE"
    if (( count >= 3 )); then
        date +%s > "$CIRCUIT_FILE"
        log "Circuit breaker TRIPPED after $count consecutive failures"
        alert_send "WARNING" "auto-fix" "Circuit breaker tripped (${count} failures)" "code"
    fi
}

reset_failures() {
    rm -f "$FAILURE_COUNT_FILE"
}

# --- Get fixable issues and batch related ones ---
all_issues_json=$(gh issue list --repo "$REPO" --label "claude-auto" --state open \
    --json number,title,body,labels \
    --jq '[.[] | select(.labels | map(.name) | (contains(["in-progress"]) or contains(["wont-fix"]) or contains(["manual"])) | not)] | sort_by(.number)' 2>/dev/null)

if [[ -z "$all_issues_json" || "$all_issues_json" == "null" || "$all_issues_json" == "[]" ]]; then
    log "No fixable issues found"
    exit 0
fi

# Group related issues by shared labels
batch_json=$(printf '%s' "$all_issues_json" | python3 -c "
import sys, json
issues = json.load(sys.stdin)
if not issues:
    sys.exit(1)
META_LABELS = {'claude-auto', 'in-progress', 'wont-fix', 'manual', 'auto-fix', 'bug', 'enhancement'}
groups = {}
for iss in issues:
    tags = sorted(set(l['name'] for l in iss['labels']) - META_LABELS)
    key = ','.join(tags) if tags else '_none_'
    groups.setdefault(key, []).append(iss)
best_key = max(groups, key=lambda k: len(groups[k]))
batch = groups[best_key][:5]
print(json.dumps(batch))
" 2>/dev/null)

if [[ -z "$batch_json" || "$batch_json" == "null" ]]; then
    batch_json=$(printf '%s' "$all_issues_json" | python3 -c "import sys,json; print(json.dumps([json.load(sys.stdin)[0]]))")
fi

batch_count=$(printf '%s' "$batch_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
issue_numbers=$(printf '%s' "$batch_json" | python3 -c "import sys,json; print(' '.join(str(i['number']) for i in json.load(sys.stdin)))")
primary_number=$(echo "$issue_numbers" | awk '{print $1}')
issue_titles=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
for i in json.load(sys.stdin):
    print(f'#{i[\"number\"]}: {i[\"title\"]}')
")

log "Batch: $batch_count issues -- $issue_numbers"

# Build combined issue context
combined_issue_text=$(printf '%s' "$batch_json" | python3 -c "
import sys, json
NL = chr(10)
issues = json.load(sys.stdin)
parts = []
for iss in issues:
    body = (iss.get('body') or '')[:2000]
    parts.append(f'--- Issue #{iss[\"number\"]}: {iss[\"title\"]} ---{NL}{body}')
print((NL + NL).join(parts))
")

# --- Label issues as in-progress ---
for num in $issue_numbers; do
    gh issue edit --repo "$REPO" "$num" --add-label "in-progress" 2>/dev/null || true
done

# --- Cleanup function ---
WORKTREE="/tmp/jepo-autofix-${primary_number}"
BRANCH="auto-fix/issue-${primary_number}"
cleanup() {
    cd "$HOME" 2>/dev/null
    if [[ -d "$WORKTREE" ]]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
    fi
}
trap 'cleanup; rm -rf "/tmp/claude-auto-locks/auto-fix.lockdir"' EXIT

# --- Create isolated worktree ---
cleanup
cd "$REPO_DIR"
git fetch origin main 2>/dev/null
git push origin --delete "$BRANCH" 2>/dev/null || true
git branch -D "$BRANCH" 2>/dev/null || true

git worktree add -b "$BRANCH" "$WORKTREE" origin/main 2>/dev/null || {
    log "Failed to create worktree"
    for num in $issue_numbers; do gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" 2>/dev/null || true; done
    record_failure
    exit 1
}

cd "$WORKTREE"
log "Worktree created at $WORKTREE on branch $BRANCH"

# --- Stage 1: Root cause analysis (Haiku, low cost) ---
log "Stage 1: Analyzing root cause (Haiku)"
analysis_result=$(timeout 120 claude --model "$MODEL_HAIKU" -p "Analyze these GitHub issue(s) for ROOT CAUSE. Do NOT fix anything.

$combined_issue_text

Read relevant source files mentioned in the issues.

Output exactly:
ROOT_CAUSE: [one of: type-error, api-contract, build-config, css-layout, i18n-missing, data-format, import-path, logic-error, other]
ANALYSIS: [1-2 sentences explaining the root cause]
FILES_TO_CHANGE: [comma-separated file paths]
FIX_APPROACH: [1-2 sentences describing the minimal fix]
CONFIDENCE: [high/medium/low]" \
    --allowedTools "Read,Glob,Grep" \
    --max-turns 15 2>&1) || analysis_result="ROOT_CAUSE: unknown\nANALYSIS: Analysis timed out\nCONFIDENCE: low"

log "Analysis result: $(echo "$analysis_result" | tail -5 | head -3)"

# Post analysis as issue comment
for num in $issue_numbers; do
    gh issue comment --repo "$REPO" "$num" \
        --body "## Root Cause Analysis (auto-fix)
$(echo "$analysis_result" | grep -E '^(ROOT_CAUSE|ANALYSIS|FILES_TO_CHANGE|FIX_APPROACH|CONFIDENCE):' || echo "$analysis_result" | tail -10)

---
*Proceeding to auto-fix based on this analysis.*" 2>/dev/null || true
done

# --- Stage 2: Claude fixes the code (Opus) ---
log "Stage 2: Fixing code (Opus)"
fix_result=$(claude --model "$MODEL_OPUS" -p "You are fixing $batch_count GitHub issue(s).

$combined_issue_text

## Root Cause Analysis (from Stage 1):
$analysis_result

Repository: $(pwd)

Instructions:
1. Focus on the files identified in the analysis
2. Make the MINIMAL changes needed to fix ALL issues in this batch
3. DO NOT modify more than $MAX_FILES files or add more than $MAX_LINES lines
4. Focus on correctness, simplicity, and safety
5. Do NOT add unnecessary comments, documentation, or refactoring
6. Do NOT modify package.json, lock files, or .env files
7. If you cannot fix an issue safely, explain why and skip it

Fix all issues now." \
    --allowedTools "Read,Glob,Grep,Edit,Write" \
    --max-turns 30 2>&1)

log "Claude fix completed (${#fix_result} chars output)"

# --- Check scope limits ---
changed_files=$(git diff --name-only | wc -l | tr -d ' ')
changed_lines=$(git diff --numstat | awk '{sum += $1 + $2} END {print sum+0}')

log "Changes: $changed_files files, $changed_lines lines"

if (( changed_files == 0 )); then
    log "No changes made"
    for num in $issue_numbers; do
        gh issue comment --repo "$REPO" "$num" \
            --body "Auto-fix attempted but no changes were made. May require manual intervention." 2>/dev/null || true
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" --add-label "manual" 2>/dev/null || true
    done
    record_failure
    exit 0
fi

if (( changed_files > MAX_FILES || changed_lines > MAX_LINES )); then
    log "ABORT -- scope too large: $changed_files files, $changed_lines lines"
    for num in $issue_numbers; do
        gh issue comment --repo "$REPO" "$num" \
            --body "Auto-fix aborted: scope too large ($changed_files files, $changed_lines lines). Needs manual fix." 2>/dev/null || true
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" --add-label "manual" 2>/dev/null || true
    done
    exit 0
fi

# --- Commit and push ---
closes_line=$(echo "$issue_numbers" | tr ' ' '\n' | sed 's/^/Closes #/' | tr '\n' ' ')

git add -A
git commit -m "fix: auto-fix issues $issue_numbers

$issue_titles

$closes_line

Co-Authored-By: Claude <noreply@anthropic.com>" --no-verify 2>> "$LOGFILE" || {
    log "Commit failed"
    record_failure
    exit 1
}

git push origin "$BRANCH" 2>> "$LOGFILE" || {
    log "Push failed"
    record_failure
    exit 1
}

# --- Create PR ---
diff_stat=$(git diff --stat origin/main.."$BRANCH" 2>/dev/null | tail -5)
pr_title="fix: auto-fix #$primary_number"
if (( batch_count > 1 )); then
    pr_title="fix: auto-fix #$primary_number (+$((batch_count-1)) related)"
fi

pr_url=$(gh pr create --repo "$REPO" \
    --title "$pr_title" \
    --body "$(cat <<PRBODY
## Auto-fix for $batch_count issue(s)

$issue_titles

### Changes
\`\`\`
$diff_stat
\`\`\`

### Safety Checks
- Files changed: **$changed_files** (limit: $MAX_FILES)
- Lines changed: **$changed_lines** (limit: $MAX_LINES)

---
*Auto-generated by JEPO auto-fix agent.*
PRBODY
)" \
    --head "$BRANCH" \
    --base "main" \
    --label "claude-auto,auto-fix" 2>&1)

if echo "$pr_url" | grep -q "github.com"; then
    log "PR created: $pr_url"
    reset_failures
    rate_increment "auto-fix" "github"
    for num in $issue_numbers; do
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" 2>/dev/null || true
    done
    # Regression test generation (non-blocking)
    "$(dirname "$0")/regression-gen.sh" "$BRANCH" "$WORKTREE" 2>/dev/null || true
    alert_send "INFO" "auto-fix" "PR created for $batch_count issue(s): $issue_numbers" "code"
    send_telegram "<b>[auto-fix]</b> PR created for $batch_count issue(s): $issue_numbers
$pr_url"
else
    log "PR creation failed: $pr_url"
    record_failure
    for num in $issue_numbers; do
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" 2>/dev/null || true
    done
    alert_send "ERROR" "auto-fix" "PR creation failed for $issue_numbers" "code"
fi
