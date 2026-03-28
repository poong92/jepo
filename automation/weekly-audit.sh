#!/bin/bash
# JEPO Weekly Audit v1.0
# 요일별 감사 로테이션: 월(Lighthouse), 수(스크린샷 QA), 금(코드 품질)

source "$(dirname "$0")/claude-runner.sh"

acquire_lock "weekly-audit"

LOGFILE="$LOG_DIR/weekly-audit.log"
RESULTS_DIR="$LOG_DIR/results"
REPO="pruviq/pruviq"
REPO_DIR="$HOME/pruviq"
PRUVIQ_URL="https://pruviq.com"

rotate_log "$LOGFILE"
log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOGFILE"; }

DAY_OF_WEEK=$(date +%u)  # 1=월, 3=수, 5=금

log "Weekly audit started (day=$DAY_OF_WEEK)"

# ─── 월요일: Lighthouse 성능 감사 ───
if [ "$DAY_OF_WEEK" = "1" ]; then
    log "Running Lighthouse audit"
    mkdir -p "$RESULTS_DIR"
    RESULT_FILE="$RESULTS_DIR/lighthouse-$(date +%Y-%m-%d).json"
    PREV_FILE=$(ls -t "$RESULTS_DIR"/lighthouse-*.json 2>/dev/null | head -1)

    # Lighthouse 실행
    lighthouse_output=$(timeout 120 npx lighthouse "$PRUVIQ_URL" \
        --output=json --output-path="$RESULT_FILE" \
        --chrome-flags="--headless --no-sandbox" \
        --only-categories=performance,accessibility,seo 2>&1) || true

    if [ -f "$RESULT_FILE" ]; then
        # 점수 추출
        perf=$(python3 -c "import json; d=json.load(open('$RESULT_FILE')); print(int(d['categories']['performance']['score']*100))" 2>/dev/null || echo "?")
        a11y=$(python3 -c "import json; d=json.load(open('$RESULT_FILE')); print(int(d['categories']['accessibility']['score']*100))" 2>/dev/null || echo "?")
        seo=$(python3 -c "import json; d=json.load(open('$RESULT_FILE')); print(int(d['categories']['seo']['score']*100))" 2>/dev/null || echo "?")

        log "Lighthouse: perf=$perf a11y=$a11y seo=$seo"

        # 이전 대비 비교
        if [ -n "$PREV_FILE" ] && [ -f "$PREV_FILE" ]; then
            prev_perf=$(python3 -c "import json; d=json.load(open('$PREV_FILE')); print(int(d['categories']['performance']['score']*100))" 2>/dev/null || echo "0")
            diff_perf=$((perf - prev_perf))

            if [ "$diff_perf" -lt -5 ]; then
                log "Performance dropped: $prev_perf → $perf (-$((diff_perf * -1)))"
                gh issue create --repo "$REPO" \
                    --title "[weekly-audit] Lighthouse performance drop: ${prev_perf}→${perf}" \
                    --label "claude-auto,performance" \
                    --body "Lighthouse performance score dropped from $prev_perf to $perf.

Accessibility: $a11y, SEO: $seo

Previous: $PREV_FILE
Current: $RESULT_FILE" 2>/dev/null || true
            fi
        fi

        send_telegram "📊 [Weekly Audit] Lighthouse
Perf: $perf | A11y: $a11y | SEO: $seo" 2>/dev/null || true
    else
        log "Lighthouse failed"
    fi

# ─── 수요일: 스크린샷 QA ───
elif [ "$DAY_OF_WEEK" = "3" ]; then
    log "Running screenshot QA"
    SCREENSHOT_DIR="$RESULTS_DIR/screenshots/$(date +%Y-W%V)"
    PREV_DIR=$(ls -td "$RESULTS_DIR"/screenshots/20* 2>/dev/null | head -1)
    mkdir -p "$SCREENSHOT_DIR"

    # 주요 페이지 캡처
    pages="/ /ko/ /simulate /strategies /coins /fees /market"
    for page in $pages; do
        name=$(echo "$page" | tr '/' '-' | sed 's/^-//;s/-$//' | sed 's/^$/home/')
        timeout 30 npx playwright screenshot --full-page \
            --wait-for-timeout=3000 \
            "${PRUVIQ_URL}${page}" \
            "$SCREENSHOT_DIR/${name}.png" 2>/dev/null || true
    done

    captured=$(ls "$SCREENSHOT_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')
    log "Captured $captured screenshots"

    # 이전 주 대비 diff (pixelmatch 대신 파일 크기 비교 — 간단 버전)
    if [ -n "$PREV_DIR" ] && [ -d "$PREV_DIR" ]; then
        significant_changes=0
        for img in "$SCREENSHOT_DIR"/*.png; do
            name=$(basename "$img")
            prev="$PREV_DIR/$name"
            if [ -f "$prev" ]; then
                size_new=$(wc -c < "$img")
                size_old=$(wc -c < "$prev")
                diff_pct=$(python3 -c "print(abs($size_new - $size_old) * 100 // max($size_old, 1))" 2>/dev/null || echo "0")
                if [ "$diff_pct" -gt 10 ]; then
                    significant_changes=$((significant_changes + 1))
                    log "Visual change: $name (${diff_pct}% size diff)"
                fi
            fi
        done

        if [ "$significant_changes" -gt 0 ]; then
            send_telegram "📸 [Weekly Audit] Screenshot QA
${significant_changes}개 페이지에 시각적 변화 감지
$SCREENSHOT_DIR" 2>/dev/null || true
        fi
    fi

    send_telegram "📸 [Weekly Audit] Screenshot QA: ${captured}장 캡처 완료" 2>/dev/null || true

# ─── 금요일: 코드 품질 ───
elif [ "$DAY_OF_WEEK" = "5" ]; then
    log "Running code quality audit"
    cd "$REPO_DIR" 2>/dev/null || exit 1

    # TypeScript 에러 수
    tsc_errors=$(timeout 60 npx tsc --noEmit 2>&1 | grep -c "error TS" || true)
    tsc_errors=${tsc_errors:-0}

    # 번들 크기
    bundle_size=$(du -sh dist/ 2>/dev/null | cut -f1 || echo "?")

    # 빌드 페이지 수
    page_count=$(find dist/ -name "*.html" 2>/dev/null | wc -l | tr -d ' ')

    log "Quality: tsc_errors=$tsc_errors bundle=$bundle_size pages=$page_count"

    # 이전 결과와 비교
    QUALITY_FILE="$RESULTS_DIR/quality-$(date +%Y-%m-%d).json"
    PREV_QUALITY=$(ls -t "$RESULTS_DIR"/quality-*.json 2>/dev/null | head -1)

    echo "{\"tsc_errors\":$tsc_errors,\"bundle_size\":\"$bundle_size\",\"pages\":$page_count,\"date\":\"$(date +%Y-%m-%d)\"}" > "$QUALITY_FILE"

    if [ -n "$PREV_QUALITY" ] && [ -f "$PREV_QUALITY" ]; then
        prev_errors=$(python3 -c "import json; print(json.load(open('$PREV_QUALITY')).get('tsc_errors',0))" 2>/dev/null || echo "0")
        if [ "$tsc_errors" -gt "$prev_errors" ] && [ "$tsc_errors" -gt 0 ]; then
            gh issue create --repo "$REPO" \
                --title "[weekly-audit] TypeScript errors increased: ${prev_errors}→${tsc_errors}" \
                --label "claude-auto,quality" \
                --body "TypeScript errors increased from $prev_errors to $tsc_errors.
Bundle size: $bundle_size, Pages: $page_count" 2>/dev/null || true
        fi
    fi

    send_telegram "🔍 [Weekly Audit] Code Quality
TSC errors: $tsc_errors | Bundle: $bundle_size | Pages: $page_count" 2>/dev/null || true
fi

log "Weekly audit complete"
