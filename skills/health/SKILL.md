---
name: health
description: System health diagnostics. Checks memory state, Git sync, server status. Use when user asks about system status, health check, or diagnostics.
context: fork
allowed-tools: Bash, Read, Grep, Glob
---

# JEPO Health Check

## Purpose
Self-diagnostic for system state -- memory/ folder, Git status, server connectivity.

## Diagnostic Items

### 1. Memory State (auto-memory)
```bash
# Check memory/ folder
ls -la ~/.claude/memory/ 2>/dev/null && echo "OK" || echo "MISSING"
# Check MEMORY.md
ls -la ~/.claude/MEMORY.md 2>/dev/null && echo "OK" || echo "MISSING"
```

### 2. Git Sync Status
```bash
git status --porcelain
git log -1 --format="%h %s (%cr)"
```

### 3. Server Status (if configured)
```bash
# Read server from config.json
PROD_SERVER=$(jq -r '.prod_server // ""' ~/.claude/config.json 2>/dev/null)
if [ -n "$PROD_SERVER" ]; then
    PROD_SSH_PORT=$(jq -r '.prod_ssh_port // "22"' ~/.claude/config.json 2>/dev/null)
    ssh -o ConnectTimeout=3 -p "$PROD_SSH_PORT" "root@$PROD_SERVER" "uptime" 2>&1
fi
```

### 4. API Status (if configured)
```bash
DEPLOY_API=$(jq -r '.deploy_api_url // ""' ~/.claude/config.json 2>/dev/null)
[ -n "$DEPLOY_API" ] && curl -s "$DEPLOY_API/health" | head -1
```

## Output Format

```
=== JEPO Health Check ===

[Memory] auto-memory: OK | memory/ folder: N files
[Git]    branch: main | uncommitted: 0 | last: xxxxx (N hours ago)
[Server] status: OK / UNREACHABLE
[API]    status: 200 / ERROR

Status: OK / NEEDS ATTENTION
```
