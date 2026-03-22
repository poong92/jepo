# JEPO Architecture

## Overview

JEPO is a production automation framework for Claude Code. It turns Claude from an interactive assistant into an autonomous development pipeline with safety guardrails.

## System Layers

```
~/.claude/                          Global Layer
├── CLAUDE.md                       Core principles & rules
├── settings.json                   Permissions + hooks config
├── config.json                     Server IPs, budget (single source)
├── hooks/                          11 event hooks
│   ├── session-start.sh            SessionStart: env setup + project detection
│   ├── session-end.sh              SessionEnd: save session state
│   ├── prompt-validator.py         UserPromptSubmit: block sensitive data
│   ├── pre-bash-guard.py           PreToolUse(Bash): command validation
│   ├── post-edit.sh                PostToolUse(Write|Edit): auto-format
│   ├── post-tool-counter.sh        PostToolUse(Read|Write): stuck detection
│   ├── tool-failure.sh             PostToolUseFailure: error loop prevention
│   ├── pre-compact.sh              PreCompact: save state reminder
│   ├── post-compact.sh             PostCompact: context re-injection
│   ├── stop-check.sh               Stop: uncommitted changes warning
│   └── subagent-log.sh             SubagentStart/Stop: lifecycle tracking
├── skills/
│   ├── jepo/SKILL.md               Session & memory management
│   └── health/SKILL.md             System diagnostics
└── session-sync/                   Cross-session state
    └── pending.json                Last session summary

~/scripts/claude-auto/              Automation Layer
├── claude-runner.sh                Base wrapper (lock, log, auth, notify)
├── auto-fix.sh                     Issue -> Fix -> PR
├── auto-test.sh                    PR -> Test -> Label
├── auto-deploy.sh                  PR -> Merge -> Deploy -> Verify
├── continuous-runner.sh            Pipeline loop
├── deploy-verify.sh                Post-deploy E2E + rollback
├── extract-pattern.sh              Fix pattern learning
├── regression-gen.sh               Auto E2E test generation
├── suggest-rule.sh                 Repeated pattern -> rule suggestion
├── cost-daily-report.sh            Daily cost summary
├── weekly-audit.sh                 Mon/Wed/Fri rotating audits
└── lib/
    ├── alert-manager.sh            4-level structured alerts
    ├── rate-limiter.sh             Per-agent daily quotas
    ├── cost-tracker.sh             Token usage tracking
    └── budget-guard.sh             Budget enforcement
```

## 8-Stage Autonomous Loop

```
[1] DETECT     GitHub Issues labeled "claude-auto"
       |
[2] ANALYZE    Root cause analysis (Haiku, low cost)
       |
[3] FIX        Code fix in isolated worktree (Opus)
       |
[4] TEST       Build + lint + type check
       |
[5] DEPLOY     Merge PR -> build -> deploy
       |
[6] VERIFY     E2E health checks (API, web, security headers)
       |
[7] LEARN      Extract fix patterns to fix-patterns.jsonl
       |
[8] IMPROVE    Suggest new CLAUDE.md rules for repeated patterns
       └──────> back to [1]
```

## Safety Mechanisms

### Circuit Breakers
- **auto-fix**: 3 failures in 2 hours -> pause
- **auto-deploy**: 2 failures -> 4 hour cooldown
- **deploy-verify**: FAIL score -> auto-rollback PR

### Scope Limits
- Max files per PR (default: 20)
- Max lines per PR (default: 1500)
- Daily PR limit (default: 30)
- Per-agent rate limits

### Budget Guard
- Daily spending limit (default: $50)
- Throttle at 80%: only Haiku allowed
- Emergency stop at $100

### Hook Safety
- **pre-bash-guard.py**: Blocks `mkfs`, `dd`, `shutdown`; warns on `rm -rf`, force push
- **prompt-validator.py**: Blocks API keys, tokens, passwords in prompts
- **tool-failure.sh**: Blocks after 3 identical consecutive errors
- **post-tool-counter.sh**: Warns after 8 reads with no writes (stuck detection)

## Data Flow

```
GitHub Issue -> auto-fix -> PR -> auto-test -> label
                                      |
                              tests-passed -> auto-deploy -> merge + deploy
                                                                |
                                                        deploy-verify -> E2E score
                                                                |
                                                    >=85: PASS    <70: ROLLBACK
                                                                |
                                                        extract-pattern -> suggest-rule
```

## Configuration

All project-specific values are in environment variables or `~/.claude/config.json`:

| Variable | Description | Default |
|----------|-------------|---------|
| `JEPO_REPO` | GitHub repo (owner/repo) | required |
| `JEPO_REPO_DIR` | Local clone path | required |
| `JEPO_DEPLOY_CMD` | Deploy command | (none) |
| `JEPO_DEPLOY_WEB_URL` | Web URL for verification | (none) |
| `JEPO_DEPLOY_API_URL` | API URL for verification | (none) |
| `JEPO_MAX_PRS_PER_DAY` | Daily PR limit | 30 |
| `JEPO_MAX_FILES` | Max files per PR | 20 |
| `JEPO_MAX_LINES` | Max lines per PR | 1500 |
| `JEPO_SAFE_HOUR_START` | Deploy start hour | 6 |
| `JEPO_SAFE_HOUR_END` | Deploy end hour | 22 |
| `TELEGRAM_BOT_TOKEN` | Telegram notifications | (optional) |
| `TELEGRAM_CHAT_ID` | Telegram chat ID | (optional) |
