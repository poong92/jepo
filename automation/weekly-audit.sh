#!/bin/bash
# JEPO Weekly Audit
# Day-based rotation: Mon(Lighthouse), Wed(Screenshot QA), Fri(Code Quality)
# Customize URLs and checks per project

source "$(dirname "$0")/claude-runner.sh"

acquire_lock "weekly-audit"

LOGFILE="$LOG_DIR/weekly-audit.log"
RESULTS_DIR="$LOG_DIR/results"
REPO="${JEPO_REPO:?Set JEPO_REPO env var}"
REPO_DIR="${JEPO_REPO_DIR:?Set JEPO_REPO_DIR env var}"
PROJECT_URL="${JEPO_PROJECT_URL:-http://localhost:3000}"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

DAY_OF_WEEK=$(date +%u)  # 1=Mon, 3=Wed, 5=Fri

log "Weekly audit started (day=$DAY_OF_WEEK)"

# --- Monday: Lighthouse Performance Audit ---
if [ "$DAY_OF_WEEK" = "1" ]; then
    log "Running Lighthouse audit"
    mkdir -p "$RESULTS_DIR"
    RESULT_FILE="$RESULTS_DIR/lighthouse-$(date +%Y-%m-%d).json"
    PREV_FILE=$(ls -t "$RESULTS_DIR"/lighthouse-*.json 2>/dev/null | head -1)

    if command -v npx &>/dev/null; then
        timeout 120 npx lighthouse "$PROJECT_URL" \
            --output=json --output-path="$RESULT_FILE" \
            --chrome-flags="--headless --no-sandbox" \
            --only-categories=performance,accessibility,seo 2>&1 || true
    fi

    if [ -f "$RESULT_FILE" ]; then
        perf=$(python3 -c "import json; d=json.load(open('$RESULT_FILE')); print(int(d['categories']['performance']['score']*100))" 2>/dev/null || echo "?")
        a11y=$(python3 -c "import json; d=json.load(open('$RESULT_FILE')); print(int(d['categories']['accessibility']['score']*100))" 2>/dev/null || echo "?")
        seo=$(python3 -c "import json; d=json.load(open('$RESULT_FILE')); print(int(d['categories']['seo']['score']*100))" 2>/dev/null || echo "?")

        log "Lighthouse: perf=$perf a11y=$a11y seo=$seo"

        if [ -n "$PREV_FILE" ] && [ -f "$PREV_FILE" ]; then
            prev_perf=$(python3 -c "import json; d=json.load(open('$PREV_FILE')); print(int(d['categories']['performance']['score']*100))" 2>/dev/null || echo "0")
            diff_perf=$((perf - prev_perf))
            if [ "$diff_perf" -lt -5 ]; then
                create_issue_safe "$REPO" \
                    "[weekly-audit] Lighthouse performance drop: ${prev_perf}->${perf}" \
                    "Performance: $prev_perf -> $perf\nAccessibility: $a11y, SEO: $seo" \
                    "claude-auto,performance" 2>/dev/null || true
            fi
        fi

        send_telegram "[Weekly Audit] Lighthouse
Perf: $perf | A11y: $a11y | SEO: $seo" 2>/dev/null || true
    fi

# --- Wednesday: Screenshot QA ---
elif [ "$DAY_OF_WEEK" = "3" ]; then
    log "Running screenshot QA"
    SCREENSHOT_DIR="$RESULTS_DIR/screenshots/$(date +%Y-W%V)"
    mkdir -p "$SCREENSHOT_DIR"

    # Customize pages per project
    PAGES="${JEPO_AUDIT_PAGES:-/ /about /login}"
    for page in $PAGES; do
        name=$(echo "$page" | tr '/' '-' | sed 's/^-//;s/-$//' | sed 's/^$/home/')
        timeout 30 npx playwright screenshot --full-page \
            --wait-for-timeout=3000 \
            "${PROJECT_URL}${page}" \
            "$SCREENSHOT_DIR/${name}.png" 2>/dev/null || true
    done

    captured=$(ls "$SCREENSHOT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
    log "Captured $captured screenshots"
    send_telegram "[Weekly Audit] Screenshot QA: ${captured} pages captured" 2>/dev/null || true

# --- Friday: Code Quality ---
elif [ "$DAY_OF_WEEK" = "5" ]; then
    log "Running code quality audit"
    cd "$REPO_DIR" 2>/dev/null || exit 1

    tsc_errors=0
    if [ -f "tsconfig.json" ]; then
        tsc_errors=$(timeout 60 npx tsc --noEmit 2>&1 | grep -c "error TS" || echo "0")
    fi

    bundle_size=$(du -sh dist/ 2>/dev/null | cut -f1 || echo "?")
    page_count=$(find dist/ -name "*.html" 2>/dev/null | wc -l | tr -d ' ')

    log "Quality: tsc_errors=$tsc_errors bundle=$bundle_size pages=$page_count"

    QUALITY_FILE="$RESULTS_DIR/quality-$(date +%Y-%m-%d).json"
    echo "{\"tsc_errors\":$tsc_errors,\"bundle_size\":\"$bundle_size\",\"pages\":$page_count,\"date\":\"$(date +%Y-%m-%d)\"}" > "$QUALITY_FILE"

    send_telegram "[Weekly Audit] Code Quality
TSC errors: $tsc_errors | Bundle: $bundle_size | Pages: $page_count" 2>/dev/null || true
fi

log "Weekly audit complete"
