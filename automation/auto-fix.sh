#!/bin/bash
# auto-fix — Automatically fixes GitHub Issues labeled "claude-auto"
# Flow: Pick issue → worktree → Claude fixes → scope check → commit → PR
# Schedule: every 30 minutes via LaunchAgent
#
# SAFETY:
#   1. Max 3 PRs per day (rate-limiter)
#   2. Max 10 files, 500 lines changed per PR
#   3. Claude allowed: Read, Glob, Grep, Edit, Write (NO Bash)
#   4. Circuit breaker: 3 failures in 2h → pause
#   5. All work in isolated git worktree (never touches main repo)

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "auto-fix"

LOGFILE="$LOG_DIR/auto-fix.log"
REPO="pruviq/pruviq"
REPO_DIR="$HOME/pruviq"
MAX_PRS_PER_DAY=30
MAX_FILES=20
MAX_LINES=1500
CIRCUIT_FILE="$LOG_DIR/.auto-fix-circuit"
FAILURE_COUNT_FILE="$LOG_DIR/.auto-fix-failures"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

log "auto-fix started"

# ─── Circuit breaker check ───
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

# ─── Rate limit check ───
if ! current_count=$(rate_check "auto-fix" "github" $MAX_PRS_PER_DAY); then
    log "Daily PR limit ($MAX_PRS_PER_DAY) reached, skipping"
    exit 0
fi

# ─── Auth check ───
if ! check_auth; then
    log "Auth failed, aborting"
    exit 1
fi

# ─── Track failures for circuit breaker ───
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

# ─── Get all fixable issues and batch related ones ───
all_issues_json=$(gh issue list --repo "$REPO" --label "claude-auto" --state open \
    --json number,title,body,labels \
    --jq '[.[] | select(.labels | map(.name) | (contains(["in-progress"]) or contains(["wont-fix"]) or contains(["manual"])) | not)] | sort_by(.number)' 2>/dev/null)

if [[ -z "$all_issues_json" || "$all_issues_json" == "null" || "$all_issues_json" == "[]" ]]; then
    log "No fixable issues found"
    exit 0
fi

# Group related issues by shared labels (excluding meta-labels)
batch_json=$(printf '%s' "$all_issues_json" | python3 -c "
import sys, json
issues = json.load(sys.stdin)
if not issues:
    sys.exit(1)

META_LABELS = {'claude-auto', 'in-progress', 'wont-fix', 'manual', 'auto-fix', 'bug', 'enhancement'}
# Build label groups
groups = {}
for iss in issues:
    tags = sorted(set(l['name'] for l in iss['labels']) - META_LABELS)
    key = ','.join(tags) if tags else '_none_'
    groups.setdefault(key, []).append(iss)

# Pick the largest related group (max 5 issues per batch)
best_key = max(groups, key=lambda k: len(groups[k]))
batch = groups[best_key][:5]
print(json.dumps(batch))
" 2>/dev/null)

if [[ -z "$batch_json" || "$batch_json" == "null" ]]; then
    log "Issue grouping failed, falling back to single issue"
    batch_json=$(printf '%s' "$all_issues_json" | python3 -c "import sys,json; print(json.dumps([json.load(sys.stdin)[0]]))")
fi

batch_count=$(printf '%s' "$batch_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
issue_numbers=$(printf '%s' "$batch_json" | python3 -c "import sys,json; print(' '.join(str(i['number']) for i in json.load(sys.stdin)))")
primary_number=$(echo "$issue_numbers" | awk '{print $1}')
rm -f /tmp/autofix_titles_*.py /tmp/autofix_combined_*.py 2>/dev/null
_py_titles="/tmp/autofix_titles_$$.py"
cat > "$_py_titles" << 'TITLES_PY'
import sys, json
issues = json.load(sys.stdin)
for i in issues:
    print(f"#{i['number']}: {i['title']}")
TITLES_PY
issue_titles=$(printf '%s' "$batch_json" | python3 "$_py_titles")
rm -f "$_py_titles"

log "Batch: $batch_count issues — $issue_numbers"

# Build combined issue context for Claude
_py_combined="/tmp/autofix_combined_$$.py"
cat > "$_py_combined" << 'COMBINED_PY'
import sys, json
NL = chr(10)
issues = json.load(sys.stdin)
parts = []
for iss in issues:
    body = (iss.get("body") or "")[:2000]
    parts.append(f"--- Issue #{iss['number']}: {iss['title']} ---{NL}{body}")
print((NL + NL).join(parts))
COMBINED_PY
combined_issue_text=$(printf '%s' "$batch_json" | python3 "$_py_combined")
rm -f "$_py_combined"

# ─── Label all batch issues as in-progress ───
for num in $issue_numbers; do
    gh issue edit --repo "$REPO" "$num" --add-label "in-progress" 2>/dev/null || true
done

# ─── Cleanup function ───
WORKTREE="/tmp/pruviq-autofix-${primary_number}"
BRANCH="auto-fix/issue-${primary_number}"
cleanup() {
    cd "$HOME" 2>/dev/null
    if [[ -d "$WORKTREE" ]]; then
        git -C "$REPO_DIR" worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
    fi
}
trap 'cleanup; rm -rf "/tmp/claude-auto-locks/auto-fix.lockdir"' EXIT

# ─── Create isolated worktree ───
cleanup  # Remove stale worktree if exists
cd "$REPO_DIR"
git fetch origin main 2>/dev/null

# Delete remote branch if exists from previous failed run
git push origin --delete "$BRANCH" 2>/dev/null || true
git branch -D "$BRANCH" 2>/dev/null || true

git worktree add -b "$BRANCH" "$WORKTREE" origin/main 2>/dev/null || {
    log "Failed to create worktree"
    for num in $issue_numbers; do gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" 2>/dev/null || true; done # 2>/dev/null || true
    record_failure
    exit 1
}

cd "$WORKTREE"
log "Worktree created at $WORKTREE on branch $BRANCH"

# ─── Generate CONTEXT.md for Claude ───
context_file="$WORKTREE/CONTEXT.md"
{
    echo "# Auto-Fix Context ($(date +%Y-%m-%d %H:%M))"
    echo ""
    echo "## Recent Merged PRs (last 10)"
    gh pr list --repo "$REPO" --state merged --limit 10 \
        --json number,title,mergedAt \
        --jq '.[] | "- #\(.number) \(.title) (\(.mergedAt[:10]))"' 2>/dev/null || echo "(fetch failed)"
    echo ""
    echo "## Open Issues"
    gh issue list --repo "$REPO" --state open --limit 30 \
        --json number,title,labels \
        --jq '.[] | "- #\(.number) [\(.labels | map(.name) | join(","))] \(.title)"' 2>/dev/null || echo "(fetch failed)"
    echo ""
    echo "## Recent Error Logs"
    tail -30 "$LOG_DIR/auto-fix.log" 2>/dev/null | grep -i "error\|fail\|abort" | tail -10 || echo "(none)"
    echo ""
    echo "## Previous Attempt Comments (if any)"
    for num in $issue_numbers; do
        comments=$(gh issue view --repo "$REPO" "$num" --json comments \
            --jq '.comments[] | select(.body | test("auto-fix|Auto-fix")) | .body' 2>/dev/null | tail -500)
        if [[ -n "$comments" ]]; then
            echo "### Issue #$num previous attempts:"
            echo "$comments"
        fi
    done
    echo ""
    echo "## Similar Past Fixes (Learning DB)"
    PATTERNS_FILE="$HOME/logs/claude-auto/fix-patterns.jsonl"
    if [ -f "$PATTERNS_FILE" ] && [ -s "$PATTERNS_FILE" ]; then
        # 이슈 라벨과 제목으로 유사 패턴 검색
        for label in $(echo "$combined_issue_text" | grep -oiE 'frontend|backend|css|i18n|build|api|data|type' | head -5); do
            grep -i "$label" "$PATTERNS_FILE" 2>/dev/null
        done | sort -u | tail -5 | while IFS= read -r line; do
            title=$(echo "$line" | jq -r '.title // ""' 2>/dev/null)
            category=$(echo "$line" | jq -r '.category // ""' 2>/dev/null)
            files=$(echo "$line" | jq -r '.files // ""' 2>/dev/null)
            url=$(echo "$line" | jq -r '.url // ""' 2>/dev/null)
            echo "- [$category] $title (files: $files) $url"
        done
    else
        echo "(no patterns yet)"
    fi
    echo ""
    echo "## Previous FAILED PRs (CRITICAL — learn from these)"
    echo "If a previous auto-fix PR was CLOSED (not merged), the fix was WRONG."
    echo "DO NOT repeat the same approach. Try a different strategy."
    echo ""
    for num in $issue_numbers; do
        # Find closed (not merged) PRs that reference this issue
        failed_prs=$(gh pr list --repo "$REPO" --state closed --search "issue-${num}" --json number,title,reviews \
            --jq '.[] | select(.reviews != null) | select(.reviews | length > 0)' 2>/dev/null | head -1000)
        if [[ -n "$failed_prs" ]]; then
            echo "### Issue #$num — previous failed fixes:"
            echo "$failed_prs" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        pr = json.loads(line)
        print(f'  PR #{pr["number"]}: {pr["title"]}')
        for r in pr.get('reviews', []):
            if r.get('body'):
                print(f'    Review: {r["body"][:300]}')
    except: pass
" 2>/dev/null
        fi
    done
} > "$context_file" 2>/dev/null
log "CONTEXT.md generated ($(wc -c < "$context_file") bytes)"

# ─── Stage 1: Root cause analysis (Haiku, low cost) ───
log "Stage 1: Analyzing root cause (Haiku)"
analysis_result=$(timeout 120 claude --model "$MODEL_HAIKU" -p "Analyze these GitHub issue(s) for ROOT CAUSE. Do NOT fix anything.

$combined_issue_text

Read CONTEXT.md for project context (recent PRs, similar past fixes, error history).
Read the relevant source files mentioned in the issues.

Output exactly:
ROOT_CAUSE: [one of: hydration-mismatch, type-error, api-contract, build-config, css-layout, i18n-missing, data-format, import-path, logic-error, other]
ANALYSIS: [1-2 sentences explaining the root cause]
FILES_TO_CHANGE: [comma-separated file paths]
FIX_APPROACH: [1-2 sentences describing the minimal fix]
CONFIDENCE: [high/medium/low]" \
    --allowedTools "Read,Glob,Grep" \
    --max-turns 15 2>&1) || analysis_result="ROOT_CAUSE: unknown\nANALYSIS: Analysis timed out\nCONFIDENCE: low"

log "Analysis result: $(echo "$analysis_result" | tail -5 | head -3)"

# Post analysis as issue comment (evidence)
for num in $issue_numbers; do
    gh issue comment --repo "$REPO" "$num" \
        --body "## Root Cause Analysis (auto-fix)
$(echo "$analysis_result" | grep -E '^(ROOT_CAUSE|ANALYSIS|FILES_TO_CHANGE|FIX_APPROACH|CONFIDENCE):' || echo "$analysis_result" | tail -10)

---
*Proceeding to auto-fix based on this analysis.*" 2>/dev/null || true
done

# ─── Stage 2: Claude fixes the code (Opus) ───
log "Stage 2: Fixing code (Opus)"
fix_result=$(claude --model "$MODEL_OPUS" -p "You are fixing $batch_count GitHub issue(s) in the PRUVIQ project.

$combined_issue_text

## Root Cause Analysis (from Stage 1):
$analysis_result

Repository: $(pwd) (Astro 5 + Preact frontend, FastAPI backend, Cloudflare Workers)

IMPORTANT: Read CONTEXT.md first for project context (recent PRs, open issues, error history).
The root cause analysis above tells you WHERE to look and WHAT to fix.

Instructions:
1. Read CONTEXT.md to understand recent changes and project state
2. Focus on the files identified in the analysis
3. Make the MINIMAL changes needed to fix ALL issues in this batch
4. Related issues may share root causes — look for common fixes
5. DO NOT modify more than $MAX_FILES files or add more than $MAX_LINES lines
6. Focus on correctness, simplicity, and safety
7. Do NOT add unnecessary comments, documentation, or refactoring
8. Do NOT modify package.json, lock files, or .env files
9. If you cannot fix an issue safely, explain why and skip it

Fix all issues now." \
    --allowedTools "Read,Glob,Grep,Edit,Write" \
    --max-turns 30 2>&1)

# Remove CONTEXT.md from changes (not part of the fix)
git checkout -- CONTEXT.md 2>/dev/null || rm -f "$context_file"

log "Claude fix completed (${#fix_result} chars output)"

# ─── Check scope limits ───
changed_files=$(git diff --name-only | wc -l | tr -d ' ')
changed_lines=$(git diff --numstat | awk '{sum += $1 + $2} END {print sum+0}')

log "Changes: $changed_files files, $changed_lines lines"

if (( changed_files == 0 )); then
    log "No changes made — Claude could not fix the issues"
    for num in $issue_numbers; do
        gh issue comment --repo "$REPO" "$num" \
            --body "Auto-fix attempted (batch: $issue_numbers) but no changes were made. May require manual intervention." 2>/dev/null || true
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" --add-label "manual" 2>/dev/null || true
    done
    record_failure
    exit 0
fi

if (( changed_files > MAX_FILES )); then
    log "ABORT — too many files: $changed_files > $MAX_FILES"
    for num in $issue_numbers; do
        gh issue comment --repo "$REPO" "$num" \
            --body "Auto-fix aborted: scope too large ($changed_files files > limit $MAX_FILES). Needs manual fix." 2>/dev/null || true
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" --add-label "manual" 2>/dev/null || true
    done
    exit 0
fi

if (( changed_lines > MAX_LINES )); then
    log "ABORT — too many lines: $changed_lines > $MAX_LINES"
    for num in $issue_numbers; do
        gh issue comment --repo "$REPO" "$num" \
            --body "Auto-fix aborted: scope too large ($changed_lines lines > limit $MAX_LINES). Needs manual fix." 2>/dev/null || true
        gh issue edit --repo "$REPO" "$num" --remove-label "in-progress" --add-label "manual" 2>/dev/null || true
    done
    exit 0
fi

# ─── Commit and push ───
# Build closes line for all issues
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

# ─── Create PR ───
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
*Auto-generated by JEPO auto-fix agent. Requires auto-test pass before merge.*
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
