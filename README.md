# JEPO - Autonomous Development Pipeline for Claude Code

**JEPO** turns [Claude Code](https://docs.anthropic.com/en/docs/claude-code) into a fully autonomous development pipeline. It detects issues, analyzes root causes, writes fixes, tests them, deploys, verifies, and learns from patterns -- all with production-grade safety guardrails.

Born from 24/7 production use managing 30+ PRs/day across multiple projects.

```
Issue Created -> Root Cause Analysis -> Fix -> Test -> Deploy -> Verify -> Learn -> Improve
     [1]              [2]              [3]    [4]      [5]       [6]       [7]       [8]
```

## What Makes JEPO Different

### 1. Root Cause Resolution, Not Patches
Every fix follows: **Symptom -> Root Cause -> Structural Fix -> Rule**. After fixing a bug, a rule is added to prevent recurrence. The system gets smarter over time.

### 2. Document-Reality Sync
CLAUDE.md is the source of truth. Numbers (agent count, hook count, etc.) must always match the actual state. Automated hooks enforce this discipline.

### 3. Production-Proven
Built for and tested in 24/7 autonomous operation: 30+ PRs merged per day, circuit breakers preventing cascading failures, budget guards preventing cost overruns.

### 4. 8-Stage Autonomous Loop
Detect -> Analyze -> Fix -> Test -> Deploy -> Verify -> Learn -> Improve. Each stage has safety limits, timeout guards, and rollback capability.

### 5. Cost Monitoring + Budget Guard
Real-time token tracking, daily cost reports, automatic throttling (Haiku-only mode at 80% budget), emergency stop at configurable limit.

### 6. 11 Event Hooks
Full lifecycle coverage: session management, prompt validation, command guards, auto-formatting, loop detection, error prevention, compaction protection, subagent tracking.

## Architecture

```
~/.claude/                              Hooks & Config
├── hooks/           (11 scripts)       Event-driven safety & productivity
├── skills/          (2 skills)         Session management + health diagnostics
├── config.json                         Single source for server/budget config
└── settings.json                       Permissions + hook wiring

~/scripts/claude-auto/                  Automation Pipeline
├── claude-runner.sh                    Base wrapper (lock, log, auth, notify)
├── auto-fix.sh                         Issue -> Fix -> PR
├── auto-test.sh                        PR -> Build -> Test -> Label
├── auto-deploy.sh                      PR -> Merge -> Deploy -> Verify
├── continuous-runner.sh                Pipeline orchestrator
├── deploy-verify.sh                    E2E verification + auto-rollback
├── extract-pattern.sh                  Fix pattern learning
├── regression-gen.sh                   Auto E2E test generation
├── suggest-rule.sh                     Pattern -> Rule suggestion
├── cost-daily-report.sh                Daily cost summary
├── weekly-audit.sh                     Lighthouse / Screenshots / Code quality
└── lib/
    ├── alert-manager.sh                4-level structured alerts + throttle
    ├── rate-limiter.sh                 Per-agent daily quotas
    ├── cost-tracker.sh                 Token usage tracking
    └── budget-guard.sh                 Budget enforcement + auto-throttle
```

## Quick Start (5 minutes)

```bash
# 1. Clone
git clone https://github.com/your-org/jepo.git
cd jepo

# 2. Install
./install.sh

# 3. Configure
vim ~/.claude/config.json   # Set server IP, budget limits

# 4. Set repo (for automation)
export JEPO_REPO="your-org/your-repo"
export JEPO_REPO_DIR="$HOME/your-repo"

# 5. Start Claude Code -- hooks are now active
claude
```

## Features

### Hooks (works immediately after install)

| Hook | Event | What It Does |
|------|-------|-------------|
| `session-start.sh` | SessionStart | Environment setup, project detection, pending sync check |
| `session-end.sh` | SessionEnd | Save session state for cross-session continuity |
| `prompt-validator.py` | UserPromptSubmit | Block API keys, tokens, passwords in prompts |
| `pre-bash-guard.py` | PreToolUse(Bash) | Block dangerous commands, warn on risky operations |
| `post-edit.sh` | PostToolUse(Write/Edit) | Auto-format (prettier, black), JSON validation |
| `post-tool-counter.sh` | PostToolUse | Detect stuck loops (8+ reads, 0 writes) |
| `tool-failure.sh` | PostToolUseFailure | Block after 3 identical consecutive errors |
| `pre-compact.sh` | PreCompact | Remind to save state before context compression |
| `post-compact.sh` | PostCompact | Re-inject essential context after compression |
| `stop-check.sh` | Stop | Warn about uncommitted changes |
| `subagent-log.sh` | SubagentStart/Stop | Track agent lifecycle, duration, metrics |

### Automation Pipeline (requires scheduling)

| Script | Schedule | What It Does |
|--------|----------|-------------|
| `auto-fix.sh` | Every 30 min | Pick issue -> analyze root cause -> fix in worktree -> PR |
| `auto-test.sh` | Every 10 min | Find untested PR -> build + lint -> label pass/fail |
| `auto-deploy.sh` | Every 15 min | Merge tested PR -> build -> deploy -> verify |
| `deploy-verify.sh` | Every 5 min | E2E checks -> score -> PASS/WARN/FAIL + auto-rollback |
| `continuous-runner.sh` | On demand | Run full pipeline loop with budget guard |
| `cost-daily-report.sh` | Daily | Token usage + cost summary |
| `weekly-audit.sh` | Mon/Wed/Fri | Lighthouse, screenshots, code quality |

### Safety Mechanisms

- **Circuit Breakers**: auto-fix pauses after 3 failures, deploy pauses after 2
- **Scope Limits**: Max 20 files, 1500 lines per PR (configurable)
- **Rate Limits**: Per-agent daily quotas
- **Budget Guard**: Throttle at 80%, emergency stop at configurable limit
- **Isolated Worktrees**: All changes in temporary worktrees, never touching main repo
- **Safe Hours**: Deploy only during configurable hours
- **Auto-Rollback**: Failed deploy verification triggers automatic revert PR

## Configuration

### Environment Variables

```bash
# Required for automation
JEPO_REPO="owner/repo"           # GitHub repository
JEPO_REPO_DIR="$HOME/repo"       # Local clone path

# Optional
JEPO_DEPLOY_CMD="npx wrangler deploy"  # Deploy command
JEPO_DEPLOY_WEB_URL="https://..."      # Web URL for verification
JEPO_DEPLOY_API_URL="https://..."      # API URL for verification
TELEGRAM_BOT_TOKEN="..."               # Notifications
TELEGRAM_CHAT_ID="..."                 # Notification target
```

### config.json

```json
{
  "prod_server": "your.server.ip",
  "prod_ssh_port": "22",
  "budget": {
    "daily_limit_usd": 50,
    "weekly_limit_usd": 250,
    "throttle_at_pct": 80,
    "emergency_stop_usd": 100
  }
}
```

## Documentation

- [Architecture](docs/architecture.md) -- detailed system design
- [Getting Started](docs/getting-started.md) -- step-by-step setup guide

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (authenticated)
- `jq` (JSON processor)
- `python3` (3.8+)
- `gh` (GitHub CLI, authenticated)
- macOS or Linux

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test hooks locally: install to `~/.claude/hooks/` and verify in a Claude session
5. Submit a PR

Key areas for contribution:
- New hook scripts for additional safety checks
- Support for additional notification channels (Slack, Discord)
- Support for additional deployment targets
- Linux systemd service files (alongside macOS LaunchAgent)
- Test framework for hooks

## License

MIT License. See [LICENSE](LICENSE).

---

*Built for production. Battle-tested at 30+ PRs/day.*
