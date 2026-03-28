#!/bin/bash
# Workflow optimizer - reviews automation infrastructure for improvements
# Schedule: weekly (Sunday 04:00 UTC) via LaunchAgent
#
# SECURITY:
#   - Claude restricted to Read, Glob, Grep only.
#   - No Bash, no Write, no network tools.
#   - Read-only analysis; results written to a file for human review.
#   - flock prevents concurrent execution.

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "workflow-optimize"

LOGFILE="$LOG_DIR/workflow-optimize.log"
RESULT_DIR="$HOME/logs/claude-auto/results"
rotate_log "$LOGFILE"
mkdir -p "$RESULT_DIR"

echo "$(date): Workflow optimization started" >> "$LOGFILE"

if ! check_auth; then
    echo "$(date): Auth failed, aborting" >> "$LOGFILE"
    exit 1
fi

RESULT_FILE="$RESULT_DIR/workflow-opt-$(date +%Y%m%d).md"
SNAPSHOT_DIR="$HOME/logs/claude-auto/snapshots"
mkdir -p "$SNAPSHOT_DIR"

# Pre-dump system info into readable files (script runs these, Claude just reads them)
crontab -l > "$SNAPSHOT_DIR/crontab.txt" 2>/dev/null || echo "No crontab" > "$SNAPSHOT_DIR/crontab.txt"
launchctl list 2>/dev/null | grep pruviq > "$SNAPSHOT_DIR/launchagents.txt" || true
ps aux | grep -E 'claude|n8n|social|openclaw' | grep -v grep > "$SNAPSHOT_DIR/processes.txt" || true

# SECURITY: Read-only analysis - no Bash, no Write
analysis=$(claude --model "$MODEL_SONNET" -p "You are a DevOps engineer reviewing automation infrastructure.
Review these locations for optimization:
1. ~/scripts/claude-auto/ (Claude automation scripts)
2. ~/scripts/social/ (Social media pipeline)
3. ~/scripts/pruviq-*.sh (PRUVIQ maintenance)
4. LaunchAgents in ~/Library/LaunchAgents/com.pruviq.*
5. Crontab: ~/logs/claude-auto/snapshots/crontab.txt
6. Running processes: ~/logs/claude-auto/snapshots/processes.txt
7. LaunchAgent status: ~/logs/claude-auto/snapshots/launchagents.txt
8. Previous optimization reports: ~/logs/claude-auto/results/workflow-opt-*.md

For each area:
- Identify redundancies or conflicts
- Check for error handling gaps
- Suggest efficiency improvements
- Verify schedules do not overlap harmfully

Output a structured report with specific recommendations.
Do NOT modify any files or execute any commands." \
    --allowedTools "Read,Glob,Grep" \
    --max-turns 20 2>&1)

echo "$analysis" > "$RESULT_FILE"
echo "$(date): Workflow optimization complete -> $RESULT_FILE" >> "$LOGFILE"
send_telegram "<b>Weekly workflow review</b> -> $RESULT_FILE"
