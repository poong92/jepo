# Getting Started with JEPO

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- `jq` (JSON processor)
- `python3` (3.8+)
- `gh` (GitHub CLI, authenticated)
- A GitHub repository

## Quick Install (5 minutes)

```bash
git clone https://github.com/your-org/jepo.git /tmp/jepo
cd /tmp/jepo
./install.sh
```

The installer will:
1. Check dependencies
2. Copy hooks to `~/.claude/hooks/`
3. Copy automation scripts to `~/scripts/claude-auto/`
4. Merge settings.json (preserving your existing config)
5. Create config.json interactively
6. Optionally set up LaunchAgent (macOS) or cron

## Manual Setup

### Step 1: Install Hooks

```bash
mkdir -p ~/.claude/hooks
cp hooks/* ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/*.py
```

### Step 2: Configure settings.json

Copy the template or merge with your existing settings:

```bash
# If you don't have settings.json yet:
cp templates/settings.json.template ~/.claude/settings.json

# If you already have one, manually merge the "hooks" section
```

### Step 3: Create config.json

```bash
cp templates/config.json.template ~/.claude/config.json
# Edit with your values:
# - prod_server: your production server IP (optional)
# - budget: daily spending limits
```

### Step 4: Install Automation Scripts (Optional)

```bash
mkdir -p ~/scripts/claude-auto/lib
cp automation/*.sh ~/scripts/claude-auto/
cp automation/lib/*.sh ~/scripts/claude-auto/lib/
chmod +x ~/scripts/claude-auto/*.sh
```

### Step 5: Set Environment Variables

```bash
# Required for automation scripts:
export JEPO_REPO="your-org/your-repo"
export JEPO_REPO_DIR="$HOME/your-repo"

# Optional:
export JEPO_DEPLOY_CMD="npx wrangler deploy"
export JEPO_DEPLOY_WEB_URL="https://your-site.com"
export JEPO_DEPLOY_API_URL="https://api.your-site.com"
export TELEGRAM_BOT_TOKEN="your-token"
export TELEGRAM_CHAT_ID="your-chat-id"
```

### Step 6: Schedule Automation (Optional)

#### macOS (LaunchAgent)

The installer can create LaunchAgent plists. Manual example:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jepo.auto-fix</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>source ~/.zshrc 2>/dev/null; ~/scripts/claude-auto/auto-fix.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>StandardOutPath</key>
    <string>/tmp/jepo-auto-fix.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/jepo-auto-fix.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>JEPO_REPO</key>
        <string>your-org/your-repo</string>
        <key>JEPO_REPO_DIR</key>
        <string>/Users/you/your-repo</string>
    </dict>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.jepo.auto-fix.plist
```

#### Linux (cron)

```cron
# Auto-fix: every 30 minutes
*/30 * * * * JEPO_REPO=your-org/repo JEPO_REPO_DIR=$HOME/repo $HOME/scripts/claude-auto/auto-fix.sh >> /tmp/jepo-auto-fix.log 2>&1

# Auto-test: every 10 minutes
*/10 * * * * JEPO_REPO=your-org/repo JEPO_REPO_DIR=$HOME/repo $HOME/scripts/claude-auto/auto-test.sh >> /tmp/jepo-auto-test.log 2>&1

# Auto-deploy: every 15 minutes (safe hours 06-22)
*/15 6-21 * * * JEPO_REPO=your-org/repo JEPO_REPO_DIR=$HOME/repo $HOME/scripts/claude-auto/auto-deploy.sh >> /tmp/jepo-auto-deploy.log 2>&1

# Deploy verify: every 5 minutes
*/5 * * * * JEPO_REPO=your-org/repo JEPO_REPO_DIR=$HOME/repo $HOME/scripts/claude-auto/deploy-verify.sh >> /tmp/jepo-deploy-verify.log 2>&1

# Cost report: daily at 23:55
55 23 * * * $HOME/scripts/claude-auto/cost-daily-report.sh >> /tmp/jepo-cost-report.log 2>&1

# Weekly audit: Mon/Wed/Fri at 09:00
0 9 * * 1,3,5 JEPO_REPO=your-org/repo JEPO_REPO_DIR=$HOME/repo $HOME/scripts/claude-auto/weekly-audit.sh >> /tmp/jepo-weekly-audit.log 2>&1
```

## Verify Installation

After installing, start a new Claude Code session:

```bash
claude
```

You should see JEPO environment variables set (check with `echo $JEPO_VERSION` in a Bash tool call). The hooks will automatically:

- Validate prompts for sensitive data
- Guard dangerous Bash commands
- Auto-format edited files
- Detect stuck loops (8+ reads, 0 writes)
- Block repeated identical errors
- Save session state on exit
- Protect context during compaction

## Using the Automation Pipeline

1. Create a GitHub issue with the `claude-auto` label
2. `auto-fix.sh` picks it up, analyzes root cause, creates a fix PR
3. `auto-test.sh` runs tests on the PR
4. `auto-deploy.sh` merges and deploys if tests pass
5. `deploy-verify.sh` validates the deployment
6. If verification fails, auto-rollback is triggered

## Customization

- Add project-specific rules to your project's `CLAUDE.md`
- Adjust budget limits in `~/.claude/config.json`
- Add custom test stages in `auto-test.sh`
- Configure deploy command via `JEPO_DEPLOY_CMD`
- Add notification integrations beyond Telegram
