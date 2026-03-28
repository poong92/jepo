#!/bin/bash
# e2e-autofix — E2E 실패 로컬 재현 → Claude 수정 → 로컬 검증 → PR
# Flow: e2e-fix 이슈 감지 → 로컬 build+test 재현 → Claude 수정 → 재테스트 통과 확인 → PR
# Schedule: 10분 주기 LaunchAgent (com.pruviq.claude-e2e-autofix)
#
# 핵심 원칙: Claude가 추측으로 수정하지 않음.
#   1. 먼저 로컬에서 실패 재현 (npm build + playwright test)
#   2. 어떤 테스트가 어떤 에러로 실패하는지 확인
#   3. Claude가 실제 에러 메시지 기반으로 수정
#   4. 수정 후 같은 테스트를 다시 돌려서 pass 확인
#   5. pass 후에만 PR 생성
#
# SAFETY:
#   1. 이슈당 최대 3회 시도
#   2. Max 15 files, 800 lines changed
#   3. Claude: Read, Glob, Grep, Edit, Write만 허용 (Bash 금지)
#   4. 수정 후 로컬 테스트 pass 필수 (fail이면 PR 안 만듦)
#   5. Global circuit breaker: 3 failures in 2h → pause
#   6. Isolated git worktree

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"

acquire_lock "e2e-autofix"

LOGFILE="$LOG_DIR/e2e-autofix.log"
REPO="pruviq/pruviq"
REPO_DIR="$HOME/pruviq"
MAX_FILES=15
MAX_LINES=800
MAX_ATTEMPTS_PER_ISSUE=3
MAX_FIX_ITERATIONS=3          # 한 시도 내에서 수정→재테스트 반복 횟수
CIRCUIT_FILE="$LOG_DIR/.e2e-autofix-circuit"
FAILURE_COUNT_FILE="$LOG_DIR/.e2e-autofix-failures"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

log "e2e-autofix started"

# ─── Global circuit breaker ───
if [[ -f "$CIRCUIT_FILE" ]]; then
    circuit_ts=$(cat "$CIRCUIT_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)
    if (( now - circuit_ts < 7200 )); then
        remaining=$(( (7200 - (now - circuit_ts)) / 60 ))
        log "Global circuit breaker active (${remaining}min remaining), skipping"
        exit 0
    else
        rm -f "$CIRCUIT_FILE" "$FAILURE_COUNT_FILE"
        log "Global circuit breaker expired, resuming"
    fi
fi

record_failure() {
    local count=0
    [[ -f "$FAILURE_COUNT_FILE" ]] && count=$(cat "$FAILURE_COUNT_FILE" 2>/dev/null || echo 0)
    count=$(( count + 1 ))
    echo "$count" > "$FAILURE_COUNT_FILE"
    if (( count >= 3 )); then
        date +%s > "$CIRCUIT_FILE"
        log "Global circuit breaker TRIPPED after $count failures"
        alert_send "ERROR" "e2e-autofix" "Circuit breaker tripped after $count failures" "code"
    fi
}

reset_failures() { rm -f "$FAILURE_COUNT_FILE"; }

# ─── Auth check ───
if ! check_auth; then
    log "Auth failed, aborting"
    exit 1
fi

# ─── Find open e2e-fix issues ───
issues=$(gh issue list \
    --repo "$REPO" \
    --label "e2e-fix,claude-auto" \
    --state open \
    --limit 5 \
    --json number,title,body,labels,comments \
    2>/dev/null) || {
    log "Failed to fetch issues"
    exit 0
}

issue_count=$(echo "$issues" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
log "Found $issue_count open e2e-fix issue(s)"

if [[ "$issue_count" == "0" ]]; then
    log "No e2e-fix issues — exiting"
    exit 0
fi

# ─── Pick first eligible issue ───
issue_number=""
issue_title=""
issue_body=""
attempt_num=0

while IFS= read -r issue_json; do
    num=$(echo "$issue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['number'])" 2>/dev/null)
    title=$(echo "$issue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['title'])" 2>/dev/null)
    body=$(echo "$issue_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('body',''))" 2>/dev/null)

    attempts=$(gh issue view --repo "$REPO" "$num" --json comments \
        --jq '[.comments[].body | select(contains("[e2e-fix-attempt-"))] | length' 2>/dev/null || echo "0")

    log "Issue #$num: $attempts previous attempt(s)"

    if (( attempts >= MAX_ATTEMPTS_PER_ISSUE )); then
        log "Issue #$num: max attempts reached — labeling manual"
        gh issue edit --repo "$REPO" "$num" \
            --remove-label "claude-auto" \
            --add-label "manual" 2>/dev/null || true
        gh issue comment --repo "$REPO" "$num" \
            --body "🛑 Max auto-fix attempts ($MAX_ATTEMPTS_PER_ISSUE) reached. Requires manual investigation." 2>/dev/null || true
        continue
    fi

    in_progress=$(echo "$issue_json" | python3 -c "
import sys,json; d=json.load(sys.stdin)
labels=[l['name'] for l in d.get('labels',[])]
print('yes' if 'in-progress' in labels else 'no')
" 2>/dev/null)
    if [[ "$in_progress" == "yes" ]]; then
        log "Issue #$num: in-progress, skipping"
        continue
    fi

    issue_number="$num"
    issue_title="$title"
    issue_body="$body"
    attempt_num=$(( attempts + 1 ))
    break
done < <(echo "$issues" | python3 -c "
import sys, json
issues = json.load(sys.stdin)
for issue in issues:
    print(json.dumps(issue))
" 2>/dev/null)

if [[ -z "$issue_number" ]]; then
    log "No eligible issue found"
    exit 0
fi

log "Processing issue #$issue_number (attempt $attempt_num/$MAX_ATTEMPTS_PER_ISSUE): $issue_title"

gh issue edit --repo "$REPO" "$issue_number" --add-label "in-progress" 2>/dev/null || true
gh issue comment --repo "$REPO" "$issue_number" \
    --body "[e2e-fix-attempt-$attempt_num] 🤖 Auto-fix attempt #$attempt_num started at $(date -u +%Y-%m-%dT%H:%M:%SZ) — 로컬 재현 후 수정 접근" \
    2>/dev/null || true

# ─── Extract info from issue ───
branch=$(echo "$issue_body" | grep -oE 'Branch: `[^`]+`' | head -1 | sed "s/Branch: \`//;s/\`//" || true)
pr_number=$(echo "$issue_body" | grep -oE 'PR #[0-9]+' | head -1 | grep -oE '[0-9]+' || true)

log "Branch: ${branch:-unknown}, PR: ${pr_number:-unknown}"

# ─── Prepare worktree ───
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BRANCH_NAME="e2e-fix/issue-${issue_number}-attempt-${attempt_num}-${TIMESTAMP}"
WORKTREE="/tmp/e2e-autofix-${issue_number}-${TIMESTAMP}"
LOCAL_REPORT_DIR="/tmp/e2e-autofix-report-${issue_number}-${TIMESTAMP}"

mkdir -p "$LOCAL_REPORT_DIR"

cd "$REPO_DIR"
git fetch origin main 2>/dev/null || true

if [[ -n "$branch" ]] && git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    BASE_REF="origin/$branch"
else
    BASE_REF="origin/main"
fi

git worktree add "$WORKTREE" -b "$BRANCH_NAME" "$BASE_REF" 2>>"$LOGFILE" || {
    log "Worktree add failed"
    gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
    record_failure
    exit 1
}

cleanup() {
    # Kill any preview server we started
    [[ -n "${PREVIEW_PID:-}" ]] && kill "$PREVIEW_PID" 2>/dev/null || true
    # Wait a moment for port to free
    sleep 1
    cd "$REPO_DIR"
    git worktree remove "$WORKTREE" --force 2>/dev/null || true
    git branch -D "$BRANCH_NAME" 2>/dev/null || true
    rm -rf "$LOCAL_REPORT_DIR"
}
trap cleanup EXIT

cd "$WORKTREE"
log "Worktree at $WORKTREE on branch $BRANCH_NAME"

# ─── Step 1: Build site in worktree ───
log "Building site..."
build_output=$(npm run build 2>&1)
build_exit=$?
log "Build exit: $build_exit ($(echo "$build_output" | wc -l | tr -d ' ') lines)"

if (( build_exit != 0 )); then
    log "Build FAILED — cannot reproduce E2E"
    build_errors=$(echo "$build_output" | grep -E "error|Error|ERROR" | head -20)
    gh issue comment --repo "$REPO" "$issue_number" \
        --body "[e2e-fix-attempt-$attempt_num] ❌ Build failed before E2E could run. Build errors:
\`\`\`
$build_errors
\`\`\`
This is a build error, not an E2E test issue. Please fix the build first." \
        2>/dev/null || true
    gh issue edit --repo "$REPO" "$issue_number" \
        --remove-label "in-progress,e2e-fix,claude-auto" \
        --add-label "manual,build-error" 2>/dev/null || true
    record_failure
    exit 0
fi

# ─── Step 2: Start preview server ───
log "Starting preview server..."
npm run preview -- --host 0.0.0.0 --port 4321 &
PREVIEW_PID=$!
# Wait for server to be ready
for i in {1..15}; do
    sleep 1
    if curl -sf http://localhost:4321 -o /dev/null 2>/dev/null; then
        log "Preview server ready (attempt $i)"
        break
    fi
    if (( i == 15 )); then
        log "Preview server failed to start"
        gh issue comment --repo "$REPO" "$issue_number" \
            --body "[e2e-fix-attempt-$attempt_num] ❌ Preview server failed to start. Manual check needed." \
            2>/dev/null || true
        gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
        record_failure
        exit 1
    fi
done

# ─── Step 3: Run E2E tests to reproduce failure ───
run_tests() {
    local output_dir="$1"
    BASE_URL="http://localhost:4321" \
    npx playwright test tests/e2e/ \
        --timeout 60000 \
        --workers 1 \
        --retries 0 \
        --reporter json \
        --output "$output_dir" \
        2>&1
}

log "Running E2E tests (initial reproduction)..."
initial_output_dir="$LOCAL_REPORT_DIR/initial"
mkdir -p "$initial_output_dir"
initial_test_log=$(run_tests "$initial_output_dir")
initial_exit=$?

log "Initial test exit: $initial_exit"

# Parse failing tests
failing_tests_json=""
if [[ -f "$initial_output_dir/test-results.json" ]]; then
    failing_tests_json=$(cat "$initial_output_dir/test-results.json")
elif [[ -f "playwright-report/results.json" ]]; then
    failing_tests_json=$(cat "playwright-report/results.json")
fi

failing_test_names=$(echo "$initial_test_log" | grep -E "✗|FAILED|×" | sed 's/^[[:space:]]*//' | head -30 || true)
failing_errors=$(echo "$initial_test_log" | grep -E "Error:|Expected|Received|TimeoutError|locator" | head -40 || true)

if (( initial_exit == 0 )); then
    log "All tests PASSED locally — E2E issue may have been flaky/infrastructure. Closing issue."
    gh issue comment --repo "$REPO" "$issue_number" \
        --body "[e2e-fix-attempt-$attempt_num] ✅ All E2E tests passed locally on current code. The original failure was likely flaky/infrastructure (GitHub Actions runner issue, API latency). No code fix needed.

Closing this issue." \
        2>/dev/null || true
    gh issue close --repo "$REPO" "$issue_number" 2>/dev/null || true
    exit 0
fi

log "Reproduced failures: $(echo "$failing_test_names" | wc -l | tr -d ' ') tests"
log "Failing tests: $failing_test_names"

# ─── Step 4: Claude fix → retest loop ───
fix_succeeded=false
final_test_log=""
final_changed_files=0
final_changed_lines=0

for fix_iter in $(seq 1 $MAX_FIX_ITERATIONS); do
    log "Fix iteration $fix_iter/$MAX_FIX_ITERATIONS"

    # Write context for Claude
    context_file="$WORKTREE/E2E_FIX_CONTEXT.md"
    cat > "$context_file" <<CONTEXT_EOF
# E2E Auto-Fix Context
Issue: #$issue_number (attempt $attempt_num, fix iteration $fix_iter)

## Failing Tests (reproduced locally)
\`\`\`
$failing_test_names
\`\`\`

## Actual Error Messages (from local run)
\`\`\`
$failing_errors
\`\`\`

## Full Test Output (last 150 lines)
\`\`\`
$(echo "$initial_test_log" | tail -150)
\`\`\`

## Root Cause Analysis — What to Check
1. Selector/locator not found → check the actual DOM in source files (src/pages/, src/layouts/, src/components/)
   - If test looks for \`#mobile-menu-btn\` → find the element in source and ensure id matches
   - If test looks for \`text=Best 3 Strategies\` → find where that text is rendered
2. i18n key missing → check src/i18n/en.ts and src/i18n/ko.ts
   - If error is about missing key → add to ALL locale files
3. Page returns 404 → check src/pages/ for the route
4. Korean text on EN page → check for hardcoded Korean in src/ files
5. Timing issue → ONLY if error is explicitly "timeout waiting for element":
   - Use waitForFunction() instead of waitForTimeout()
   - Increase specific element timeout, not global

## Fix Strategy
- Read the FAILING test spec file first (tests/e2e/*.spec.ts)
- Find which specific assertion fails and why
- Trace to the SOURCE (pages/components/i18n), NOT the test
- Make MINIMAL change: only touch what's needed for the failing assertion
- Do NOT change working tests or unrelated source files
- Do NOT add arbitrary timeouts

## Scope Limit
- Max $MAX_FILES files, $MAX_LINES lines total

## Previous Fix Iterations This Attempt
$(if (( fix_iter > 1 )); then git diff --stat HEAD~$((fix_iter-1)) 2>/dev/null || echo "(first iteration)"; else echo "(first iteration)"; fi)
CONTEXT_EOF

    fix_result=$(claude --model "$MODEL_OPUS" -p "You are fixing Playwright E2E test failures in the PRUVIQ project (Astro 5 + Preact + Tailwind).

Read E2E_FIX_CONTEXT.md — it contains ACTUAL error messages from a local test run. These are real failures, not guesses.

Your task:
1. Read E2E_FIX_CONTEXT.md to see the exact error messages
2. Read the failing test spec file(s) in tests/e2e/
3. Read the relevant source files (the error message will tell you what selector/text/route is expected)
4. Make the MINIMAL fix — trace the failure to its source:
   - Wrong selector: fix the HTML in source (add/fix id or class), NOT the test
   - Missing i18n key: add to src/i18n/en.ts AND src/i18n/ko.ts
   - Page 404: create the page in src/pages/
   - Korean on EN page: find and remove hardcoded Korean from source
5. Do NOT modify playwright.config.ts, package.json, or lock files
6. Max $MAX_FILES files, $MAX_LINES lines

Fix the failing tests now based on the ACTUAL error messages." \
        --allowedTools "Read,Glob,Grep,Edit,Write" \
        --max-turns 20 2>&1)

    # Remove context file from changes
    git checkout -- E2E_FIX_CONTEXT.md 2>/dev/null || rm -f "$context_file"

    changed_files=$(git diff --name-only | wc -l | tr -d ' ')
    changed_lines=$(git diff --numstat | awk '{sum += $1 + $2} END {print sum+0}')
    log "Iter $fix_iter changes: $changed_files files, $changed_lines lines"

    if (( changed_files == 0 )); then
        log "Iter $fix_iter: no changes made"
        break
    fi

    if (( changed_files > MAX_FILES || changed_lines > MAX_LINES )); then
        log "Iter $fix_iter: scope too large ($changed_files files, $changed_lines lines) — reverting"
        git checkout -- . 2>/dev/null || true
        break
    fi

    # ─── Retest with fix applied ───
    log "Iter $fix_iter: rebuilding and retesting..."
    rebuild_output=$(npm run build 2>&1)
    rebuild_exit=$?

    if (( rebuild_exit != 0 )); then
        log "Iter $fix_iter: rebuild failed — reverting"
        build_error_msg=$(echo "$rebuild_output" | grep -E "error|Error" | head -10)
        # Update error context for next iteration
        failing_errors="BUILD FAILED after fix:
$build_error_msg

Original errors:
$failing_errors"
        git checkout -- . 2>/dev/null || true
        continue
    fi

    # Kill and restart preview server with new build
    kill "$PREVIEW_PID" 2>/dev/null || true
    sleep 2
    npm run preview -- --host 0.0.0.0 --port 4321 &
    PREVIEW_PID=$!
    for i in {1..15}; do
        sleep 1
        curl -sf http://localhost:4321 -o /dev/null 2>/dev/null && break
    done

    retest_output_dir="$LOCAL_REPORT_DIR/iter-$fix_iter"
    mkdir -p "$retest_output_dir"
    retest_log=$(run_tests "$retest_output_dir")
    retest_exit=$?

    log "Iter $fix_iter retest exit: $retest_exit"

    if (( retest_exit == 0 )); then
        log "Iter $fix_iter: ALL TESTS PASS — fix verified!"
        fix_succeeded=true
        final_test_log="$retest_log"
        final_changed_files="$changed_files"
        final_changed_lines="$changed_lines"
        break
    else
        # Some tests still failing — update context and try again
        log "Iter $fix_iter: tests still failing"
        new_failing=$(echo "$retest_log" | grep -E "✗|FAILED|×" | head -30 || true)
        new_errors=$(echo "$retest_log" | grep -E "Error:|Expected|Received|TimeoutError|locator" | head -40 || true)

        if [[ "$new_failing" != "$failing_test_names" ]]; then
            log "Iter $fix_iter: different tests failing now — updating context"
            failing_test_names="$new_failing"
            failing_errors="$new_errors"
            initial_test_log="$retest_log"
        else
            log "Iter $fix_iter: same tests still failing — reverting this iteration's changes"
            git checkout -- . 2>/dev/null || true
        fi
    fi
done

# ─── Step 5: If fix verified, commit and create PR ───
if [[ "$fix_succeeded" != "true" ]]; then
    log "Could not fix all failing tests after $MAX_FIX_ITERATIONS iterations"
    still_failing=$(echo "$final_test_log" | grep -E "✗|FAILED|×" | head -20 || echo "(see log)")
    gh issue comment --repo "$REPO" "$issue_number" \
        --body "[e2e-fix-attempt-$attempt_num] ⚠️ Could not fix all failures after $MAX_FIX_ITERATIONS fix iterations.

Still failing:
\`\`\`
$still_failing
\`\`\`

Root cause may require deeper investigation. $(if (( attempt_num >= MAX_ATTEMPTS_PER_ISSUE )); then echo "Max attempts reached — needs manual fix."; else echo "Will retry next cycle."; fi)" \
        2>/dev/null || true
    gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
    record_failure
    exit 0
fi

# Commit
diff_stat=$(git diff --stat origin/main.."$BRANCH_NAME" 2>/dev/null | tail -5 || git diff --stat | tail -5)

git add -A
git commit -m "fix(e2e): auto-fix test failures — issue #$issue_number attempt $attempt_num

Reproduced locally + verified all tests pass after fix.

Fixes #$issue_number

Co-Authored-By: Claude Opus <noreply@anthropic.com>" --no-verify 2>>"$LOGFILE" || {
    log "Commit failed"
    gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
    record_failure
    exit 1
}

git push origin "$BRANCH_NAME" 2>>"$LOGFILE" || {
    log "Push failed"
    gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
    record_failure
    exit 1
}

# Create PR
pr_body="## E2E Auto-Fix — Issue #$issue_number (Attempt $attempt_num)

### Verified locally ✅
All E2E tests pass after this fix (local Playwright run on same codebase).

### Changes
\`\`\`
$diff_stat
\`\`\`

### Scope
- Files changed: **$final_changed_files** (limit: $MAX_FILES)
- Lines changed: **$final_changed_lines** (limit: $MAX_LINES)

Closes #$issue_number

---
*Auto-generated by JEPO e2e-autofix — reproduced locally → fixed → verified → PR*"

pr_url=$(gh pr create \
    --repo "$REPO" \
    --title "fix(e2e): auto-fix #$issue_number verified locally (attempt $attempt_num)" \
    --body "$pr_body" \
    --head "$BRANCH_NAME" \
    --base "main" \
    --label "claude-auto,e2e-fix,auto-fix" \
    2>&1)

if echo "$pr_url" | grep -q "github.com"; then
    log "PR created: $pr_url"
    reset_failures
    gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
    gh issue comment --repo "$REPO" "$issue_number" \
        --body "[e2e-fix-attempt-$attempt_num] ✅ Fix verified locally — all E2E tests pass. PR: $pr_url" \
        2>/dev/null || true
    alert_send "INFO" "e2e-autofix" "Verified fix PR for issue #$issue_number" "code"
    send_telegram "<b>[e2e-autofix]</b> ✅ 로컬 검증 완료 — PR:
Issue #$issue_number: $issue_title
$pr_url"
    trap - EXIT  # worktree 보존 (브랜치 푸시됨)
else
    log "PR creation failed: $pr_url"
    gh issue edit --repo "$REPO" "$issue_number" --remove-label "in-progress" 2>/dev/null || true
    record_failure
fi
