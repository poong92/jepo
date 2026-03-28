#!/bin/bash
# Find improvements - identifies and auto-files issues for PRUVIQ
# Schedule: every 6 hours via LaunchAgent
#
# SECURITY:
#   1. Claude restricted to Read, Glob, Grep, WebFetch (no code execution)
#   2. GitHub issues created by THIS SCRIPT (not Claude) with rate limit
#   3. Max 2 issues per run, max 10 per day
#   4. All issues labeled "claude-auto" for tracking
#   5. Duplicate detection via existing open issues

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "find-improvements"

LOGFILE="$LOG_DIR/find-improvements.log"
RESULT_DIR="$HOME/logs/claude-auto/results"
rotate_log "$LOGFILE"
mkdir -p "$RESULT_DIR"

echo "$(date): Find improvements started" >> "$LOGFILE"

if ! check_auth; then
    echo "$(date): Auth failed, aborting" >> "$LOGFILE"
    exit 1
fi

# Rotate focus areas throughout the day
AREAS=("frontend" "backend" "seo" "infrastructure" "ux-performance" "accessibility" "api-optimization")
HOUR=$(date +%H)
AREA_IDX=$(( (10#$HOUR / 6) % 4 ))
FOCUS="${AREAS[$AREA_IDX]}"

RESULT_FILE="$RESULT_DIR/improvements-${FOCUS}-$(date +%Y%m%d-%H).md"

# Check for previous findings to avoid duplicates
PREV_FILE=$(ls -t "$RESULT_DIR"/improvements-${FOCUS}-*.md 2>/dev/null | head -1 || true)
PREV_CONTEXT=""
if [[ -n "$PREV_FILE" && -f "$PREV_FILE" ]]; then
    PREV_CONTEXT="Previous findings are at: $PREV_FILE - avoid duplicating those issues."
fi

# SECURITY: Only allow Read, Glob, Grep, WebFetch - NO Bash, NO Write, NO gh
improvements=$(claude --model "$MODEL_SONNET" -p "You are a senior engineer reviewing the PRUVIQ project.
Focus area: $FOCUS
Repository: ~/pruviq (Next.js + Cloudflare Workers)

$PREV_CONTEXT

Find 3-5 concrete improvements:
- Code quality issues
- Performance optimizations
- Security hardening opportunities
- UX improvements

For each improvement, provide:
1. File and line number
2. Current issue
3. Suggested fix (code snippet)
4. Priority (P0/P1/P2)

Output as structured markdown.
Do NOT create GitHub issues. Do NOT execute commands. Do NOT modify files." \
    --allowedTools "Read,Glob,Grep,WebFetch" \
    --max-turns 20 2>&1)

echo "$improvements" > "$RESULT_FILE"
echo "$(date): Improvements ($FOCUS) -> $RESULT_FILE" >> "$LOGFILE"

# ─── Auto-file GitHub Issues (rate-limited, deduplicated) ───
REPO="pruviq/pruviq"
MAX_PER_RUN=2
DAILY_COUNT_FILE="$RESULT_DIR/.issue-count-$(date +%Y%m%d)"
DAILY_MAX=10

# Check daily limit (atomic read via Python to prevent race condition)
daily_count=$(DC_FILE="$DAILY_COUNT_FILE" python3 -c '
import os, fcntl
f = os.environ["DC_FILE"]
try:
    with open(f) as fh:
        fcntl.flock(fh, fcntl.LOCK_SH)
        val = fh.read().strip()
        fcntl.flock(fh, fcntl.LOCK_UN)
    print(int(val) if val.isdigit() else 0)
except FileNotFoundError:
    print(0)
' 2>/dev/null || echo "0")
if [[ $daily_count -ge $DAILY_MAX ]]; then
    echo "$(date): Daily issue limit ($DAILY_MAX) reached, skipping" >> "$LOGFILE"
    send_telegram "<b>Improvements ($FOCUS):</b> found -> $RESULT_FILE (daily issue limit reached)"
    exit 0
fi

# Get existing open issue titles to prevent duplicates
existing_issues=$(gh issue list --repo "$REPO" --label "claude-auto" --state open --json title --jq '.[].title' 2>/dev/null || true)

# Extract P0/P1 items and create issues (max MAX_PER_RUN)
created=0
while IFS= read -r line; do
    [[ $created -ge $MAX_PER_RUN ]] && break
    [[ $daily_count -ge $DAILY_MAX ]] && break

    # Extract title from markdown headers like "## 1. Race Condition in Quick Start Button (P0)"
    title=$(echo "$line" | sed 's/^##* [0-9]*\. //' | sed 's/ (P[0-2].*//' | head -c 80)
    [[ -z "$title" || ${#title} -lt 10 ]] && continue

    # Skip if similar issue already exists
    if echo "$existing_issues" | grep -qiF "$(echo "$title" | cut -c1-30)" 2>/dev/null; then
        echo "$(date): Skipping duplicate: $title" >> "$LOGFILE"
        continue
    fi

    # Extract the section content for issue body
    priority=$(echo "$line" | grep -oE 'P[012]' | head -1 || echo "P2")

    # Create issue with label
    gh issue create --repo "$REPO" \
        --title "[claude-auto][$priority] $title" \
        --label "claude-auto" \
        --body "Auto-detected by Claude find-improvements ($FOCUS scan).

Priority: **$priority**

Details in: \`~/logs/claude-auto/results/$(basename "$RESULT_FILE")\`

---
*This issue was auto-created by Claude Code automation. OpenClaw will auto-fix.*" \
        2>> "$LOGFILE" && {
            created=$((created + 1))
            daily_count=$((daily_count + 1))
            echo "$(date): Created issue: [$priority] $title" >> "$LOGFILE"
        }
done < <(echo "$improvements" | grep -E "^##+ [0-9]+\." || true)

# Atomic write with file lock
DC_FILE="$DAILY_COUNT_FILE" DC_VAL="$daily_count" python3 -c '
import os, fcntl
f = os.environ["DC_FILE"]
val = os.environ["DC_VAL"]
with open(f, "w") as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write(val + "\n")
    fcntl.flock(fh, fcntl.LOCK_UN)
' 2>/dev/null || echo "$daily_count" > "$DAILY_COUNT_FILE"

imp_count=0
if echo "$improvements" | grep -qE "^### |^## [0-9]|^- \*\*P[012]"; then
    imp_count=$(echo "$improvements" | grep -cE "^### |^## [0-9]|^- \*\*P[012]")
fi
send_telegram "<b>Improvements ($FOCUS):</b> ${imp_count} found, ${created} issues created -> $RESULT_FILE"
