#!/bin/bash
# PRUVIQ Social Content Scheduler
# Part of JEPO Autopilot Phase 3 — intelligent posting time + analytics.
#
# Features:
#   - Optimal posting time by platform (X: UTC 13-15, Threads: UTC 1-3 = KST 10-12)
#   - Queue management: pending → scheduled → posted
#   - Daily/weekly analytics digest
#   - Content variety enforcement (no same category twice in a row WITHIN SAME RUN)
#   - Stale content cleanup (>24h old unposted = archive)
#
# Works WITH existing social-generate.sh (creates content) and post-content.sh (posts).
# This script adds the scheduling intelligence layer.
#
# Schedule: every 2 hours via LaunchAgent

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "social-scheduler"

LOGFILE="$LOG_DIR/social-scheduler.log"
QUEUE_DIR="$HOME/scripts/social/queue"
POSTED_DIR="$HOME/scripts/social/posted"
ANALYTICS_DIR="$HOME/scripts/social/analytics"
SCHEDULE_DIR="$HOME/scripts/social/schedule"

rotate_log "$LOGFILE"
mkdir -p "$QUEUE_DIR" "$POSTED_DIR" "$ANALYTICS_DIR" "$SCHEDULE_DIR"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ): $1" >> "$LOGFILE"
}

log "=== Social Scheduler started ==="

# ─────────────────────────────────────────────────────────────
# 1. Optimal Time Windows (based on crypto community patterns)
# ─────────────────────────────────────────────────────────────
# X (English audience): UTC 13:00-15:00 (US morning), 21:00-23:00 (Asia morning)
# Threads (Korean audience): UTC 00:00-02:00 (KST 09:00-11:00), UTC 06:00-08:00 (KST 15:00-17:00)

HOUR_UTC=$(date -u +%H)
HOUR_NUM=$((10#$HOUR_UTC))

is_optimal_x() {
    [[ ($HOUR_NUM -ge 13 && $HOUR_NUM -le 15) || ($HOUR_NUM -ge 21 && $HOUR_NUM -le 23) ]]
}

is_optimal_threads() {
    [[ ($HOUR_NUM -ge 0 && $HOUR_NUM -le 2) || ($HOUR_NUM -ge 6 && $HOUR_NUM -le 8) ]]
}

# ─────────────────────────────────────────────────────────────
# 2. Queue Management — schedule pending content
# ─────────────────────────────────────────────────────────────
PENDING_COUNT=0
SCHEDULED_COUNT=0
STALE_COUNT=0

# Track which platforms posted what category IN THIS RUN (bash 3.2 compatible)
# Store as files: schedule_dir/posted_category_x, posted_category_threads
POSTED_CATEGORY_X=""
POSTED_CATEGORY_THREADS=""

for qfile in "$QUEUE_DIR"/*.json; do
    [[ -f "$qfile" ]] || continue
    PENDING_COUNT=$((PENDING_COUNT + 1))

    # Parse queue item
    STATUS=$(python3 -c "import json; d=json.load(open('$qfile')); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")
    PLATFORM=$(python3 -c "import json; d=json.load(open('$qfile')); print(d.get('platform','unknown'))" 2>/dev/null || echo "unknown")
    CREATED=$(python3 -c "import json; d=json.load(open('$qfile')); print(d.get('created',''))" 2>/dev/null || echo "")
    CATEGORY=$(python3 -c "import json; d=json.load(open('$qfile')); print(d.get('category','general'))" 2>/dev/null || echo "general")

    # Skip already posted or scheduled
    if [[ "$STATUS" == "posted" || "$STATUS" == "scheduled" ]]; then
        continue
    fi

    # Stale content cleanup (>24h old unposted)
    if [[ -n "$CREATED" ]]; then
        CREATED_TS=$(python3 -c "
from datetime import datetime
try:
    dt = datetime.fromisoformat('$CREATED'.replace('Z','+00:00'))
    print(int(dt.timestamp()))
except:
    print(0)
" 2>/dev/null || echo "0")
        NOW_TS=$(date +%s)
        AGE=$(( NOW_TS - CREATED_TS ))
        if [[ "$AGE" -gt 86400 && "$CREATED_TS" -gt 0 ]]; then
            # Archive stale content
            mv "$qfile" "$POSTED_DIR/stale_$(basename "$qfile")" 2>/dev/null
            STALE_COUNT=$((STALE_COUNT + 1))
            log "Archived stale content: $(basename "$qfile") (age: ${AGE}s)"
            continue
        fi
    fi

    # Check optimal posting time
    SHOULD_POST=false
    if [[ "$PLATFORM" == "x" || "$PLATFORM" == "twitter" ]]; then
        is_optimal_x && SHOULD_POST=true
    elif [[ "$PLATFORM" == "threads" ]]; then
        is_optimal_threads && SHOULD_POST=true
    else
        SHOULD_POST=true  # Unknown platform = post anytime
    fi

    # Check category variety WITHIN THIS RUN ONLY
    # Only prevent same category from being posted twice in the same execution
    if [[ "$SHOULD_POST" == "true" ]]; then
        if [[ "$PLATFORM" == "x" || "$PLATFORM" == "twitter" ]]; then
            if [[ "$POSTED_CATEGORY_X" == "$CATEGORY" ]]; then
                log "Skip: same category '$CATEGORY' as another X post in this run"
                SHOULD_POST=false
            fi
        elif [[ "$PLATFORM" == "threads" ]]; then
            if [[ "$POSTED_CATEGORY_THREADS" == "$CATEGORY" ]]; then
                log "Skip: same category '$CATEGORY' as another Threads post in this run"
                SHOULD_POST=false
            fi
        fi
    fi

    # Mark as ready for posting
    if [[ "$SHOULD_POST" == "true" ]]; then
        python3 -c "
import json
with open('$qfile') as f:
    d = json.load(f)
d['status'] = 'approved'
d['scheduled_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
with open('$qfile', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null
        SCHEDULED_COUNT=$((SCHEDULED_COUNT + 1))

        # Update in-run category tracking
        if [[ "$PLATFORM" == "x" || "$PLATFORM" == "twitter" ]]; then
            POSTED_CATEGORY_X="$CATEGORY"
        elif [[ "$PLATFORM" == "threads" ]]; then
            POSTED_CATEGORY_THREADS="$CATEGORY"
        fi
        log "Scheduled: $(basename "$qfile") on $PLATFORM (category: $CATEGORY)"
    fi
done

log "Queue: $PENDING_COUNT pending, $SCHEDULED_COUNT scheduled, $STALE_COUNT stale archived"

# ─────────────────────────────────────────────────────────────
# 3. Daily Analytics Digest
# ─────────────────────────────────────────────────────────────
TODAY=$(date +%Y-%m-%d)
ANALYTICS_FILE="$ANALYTICS_DIR/daily-$TODAY.json"

# Count today's posts
POSTED_TODAY=0
FAILED_TODAY=0
for pfile in "$POSTED_DIR"/*.json; do
    [[ -f "$pfile" ]] || continue
    POST_DATE=$(python3 -c "import json; d=json.load(open('$pfile')); print(d.get('posted_at','')[:10])" 2>/dev/null || echo "")
    if [[ "$POST_DATE" == "$TODAY" ]]; then
        POSTED_TODAY=$((POSTED_TODAY + 1))
    fi
done

# Count queue items by platform
QUEUE_X=0
QUEUE_THREADS=0
for qfile in "$QUEUE_DIR"/*.json; do
    [[ -f "$qfile" ]] || continue
    QP=$(python3 -c "import json; d=json.load(open('$qfile')); print(d.get('platform',''))" 2>/dev/null || echo "")
    case "$QP" in
        x|twitter) QUEUE_X=$((QUEUE_X + 1)) ;;
        threads) QUEUE_THREADS=$((QUEUE_THREADS + 1)) ;;
    esac
done

# Write daily analytics
python3 -c "
import json
analytics = {
    'date': '$TODAY',
    'posted_today': $POSTED_TODAY,
    'queue_x': $QUEUE_X,
    'queue_threads': $QUEUE_THREADS,
    'stale_archived': $STALE_COUNT,
    'scheduled_this_run': $SCHEDULED_COUNT,
}
with open('$ANALYTICS_FILE', 'w') as f:
    json.dump(analytics, f, indent=2)
" 2>/dev/null

log "Analytics: posted=$POSTED_TODAY, queue_x=$QUEUE_X, queue_threads=$QUEUE_THREADS"

# ─────────────────────────────────────────────────────────────
# 4. Weekly Digest (Monday UTC 09:00 only)
# ─────────────────────────────────────────────────────────────
DOW=$(date -u +%u)  # 1=Monday
if [[ "$DOW" == "1" && "$HOUR_NUM" -ge 9 && "$HOUR_NUM" -le 10 ]]; then
    DIGEST_FILE="$SCHEDULE_DIR/.digest-week-$(date +%Y-W%V)"
    if [[ ! -f "$DIGEST_FILE" ]]; then
        # Calculate weekly totals
        WEEKLY_POSTED=0
        for day_file in "$ANALYTICS_DIR"/daily-*.json; do
            [[ -f "$day_file" ]] || continue
            DAY_DATE=$(python3 -c "import json; print(json.load(open('$day_file')).get('date',''))" 2>/dev/null || echo "")
            # Check if within last 7 days
            DAY_AGE=$(python3 -c "
from datetime import datetime
try:
    d = datetime.strptime('$DAY_DATE', '%Y-%m-%d')
    age = (datetime.now() - d).days
    print(age)
except:
    print(999)
" 2>/dev/null || echo "999")
            if [[ "$DAY_AGE" -le 7 ]]; then
                DAY_POSTS=$(python3 -c "import json; print(json.load(open('$day_file')).get('posted_today', 0))" 2>/dev/null || echo "0")
                WEEKLY_POSTED=$((WEEKLY_POSTED + DAY_POSTS))
            fi
        done

        send_telegram_structured "INFO" "social-scheduler" \
            "Weekly Social Digest: $WEEKLY_POSTED posts this week" \
            "Queue: X=$QUEUE_X, Threads=$QUEUE_THREADS"
        touch "$DIGEST_FILE"
        log "Weekly digest sent: $WEEKLY_POSTED posts"
    fi
fi

log "=== Social Scheduler completed ==="
