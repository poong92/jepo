#!/bin/bash
# JEPO Doc Sync Check v1.0
# CLAUDE.md 및 메모리 파일의 수치가 실체와 일치하는지 자동 검증
# 크론: 매일 1회 또는 수동 실행

set -euo pipefail

MEMORY_DIR="$HOME/.claude/projects/-Users-jepo/memory"
LOG="$HOME/logs/claude-auto/doc-sync-check.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date +%Y-%m-%dT%H:%M:%S): $*" >> "$LOG"; }

ERRORS=0
WARNINGS=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        log "MISMATCH: $label — doc=$expected actual=$actual"
        ERRORS=$((ERRORS + 1))
    else
        log "OK: $label = $actual"
    fi
}

log "=== Doc Sync Check started ==="

# 1. LaunchAgents count (active)
ACTUAL_LA=$(ls ~/Library/LaunchAgents/com.jepo.*.plist ~/Library/LaunchAgents/com.pruviq.*.plist 2>/dev/null | grep -v disabled | wc -l | tr -d ' ')
DOC_LA=$(grep -o "[0-9]* 활성" "$MEMORY_DIR/project_jepo_system.md" 2>/dev/null | head -1 | grep -o "[0-9]*" || echo "?")
check "LaunchAgents(활성)" "$DOC_LA" "$ACTUAL_LA"

# 2. Disabled LaunchAgents
ACTUAL_DIS=$(ls ~/Library/LaunchAgents/disabled/ 2>/dev/null | wc -l | tr -d ' ')

# 3. Cron count
ACTUAL_CRON=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" | grep -v "^PATH" | wc -l | tr -d ' ')

# 4. Skills count
ACTUAL_SKILLS=$(ls -d ~/.claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
check "Skills" "9" "$ACTUAL_SKILLS"

# 5. Hooks count
ACTUAL_HOOKS=$(ls ~/.claude/hooks/*.sh ~/.claude/hooks/*.py 2>/dev/null | wc -l | tr -d ' ')
check "Hooks" "11" "$ACTUAL_HOOKS"

# 6. Community agents
ACTUAL_COMMUNITY=$(ls ~/.claude/agents/community/*.md 2>/dev/null | wc -l | tr -d ' ')
check "Community Agents" "15" "$ACTUAL_COMMUNITY"

# 7. PRUVIQ agents
ACTUAL_PRUVIQ_AGENTS=$(ls ~/pruviq/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
check "PRUVIQ Agents" "11" "$ACTUAL_PRUVIQ_AGENTS"

# 8. AutoTrader agents
ACTUAL_AT_AGENTS=$(ls ~/Desktop/autotrader/.claude/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
check "AutoTrader Agents" "17" "$ACTUAL_AT_AGENTS"

# 9. MCP servers
ACTUAL_MCP=$(python3 -c "
import json
with open('$HOME/.claude/.mcp.json') as f:
    d = json.load(f)
print(len(d.get('mcpServers', {})))
" 2>/dev/null || echo "?")
check "MCP Servers" "5" "$ACTUAL_MCP"

# 10. API coins count (if API is up)
API_COINS=$(curl -s --max-time 5 http://127.0.0.1:8080/health 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('coins',0))" 2>/dev/null || echo "skip")
if [ "$API_COINS" != "skip" ]; then
    check "API Coins" "572" "$API_COINS"
fi

log "=== Doc Sync Check done: errors=$ERRORS ==="

if [ "$ERRORS" -gt 0 ]; then
    echo "DOC_SYNC: $ERRORS mismatches found. Check $LOG"
    exit 1
fi

echo "DOC_SYNC: All checks passed"
exit 0
