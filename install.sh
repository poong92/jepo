#!/bin/bash
# JEPO Installer
# Installs hooks, automation scripts, and configuration templates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$SCRIPT_DIR/hooks"
AUTO_SRC="$SCRIPT_DIR/automation"

HOOKS_DST="$HOME/.claude/hooks"
AUTO_DST="$HOME/scripts/claude-auto"
CONFIG_DST="$HOME/.claude"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=============================="
echo "  JEPO Installer"
echo "=============================="
echo ""

# --- Dependency check ---
echo "Checking dependencies..."
MISSING=0

for cmd in jq python3 gh; do
    if command -v "$cmd" &>/dev/null; then
        info "$cmd found: $(command -v "$cmd")"
    else
        error "$cmd not found"
        MISSING=1
    fi
done

# Check Claude CLI
if command -v claude &>/dev/null; then
    info "claude CLI found"
else
    error "claude CLI not found. Install from https://docs.anthropic.com/en/docs/claude-code"
    MISSING=1
fi

if [ "$MISSING" -eq 1 ]; then
    echo ""
    error "Missing dependencies. Install them and re-run."
    exit 1
fi

echo ""

# --- Install hooks ---
echo "Installing hooks..."
mkdir -p "$HOOKS_DST"

for f in "$HOOKS_SRC"/*; do
    fname=$(basename "$f")
    dst="$HOOKS_DST/$fname"
    if [ -f "$dst" ]; then
        if diff -q "$f" "$dst" &>/dev/null; then
            info "$fname (already up to date)"
        else
            cp "$f" "${dst}.jepo-new"
            warn "$fname exists, saved new version as ${fname}.jepo-new"
        fi
    else
        cp "$f" "$dst"
        info "$fname installed"
    fi
done

chmod +x "$HOOKS_DST"/*.sh "$HOOKS_DST"/*.py 2>/dev/null || true
echo ""

# --- Install automation scripts ---
echo "Installing automation scripts..."
mkdir -p "$AUTO_DST/lib"

for f in "$AUTO_SRC"/*.sh; do
    fname=$(basename "$f")
    cp "$f" "$AUTO_DST/$fname"
    info "$fname"
done

for f in "$AUTO_SRC"/lib/*.sh; do
    fname=$(basename "$f")
    cp "$f" "$AUTO_DST/lib/$fname"
    info "lib/$fname"
done

chmod +x "$AUTO_DST"/*.sh 2>/dev/null || true
echo ""

# --- config.json ---
echo "Configuring..."
if [ -f "$CONFIG_DST/config.json" ]; then
    info "config.json already exists (keeping)"
else
    echo ""
    echo "Creating config.json..."
    read -p "Production server IP (leave empty to skip): " PROD_SERVER
    read -p "SSH port (default: 22): " PROD_PORT
    PROD_PORT="${PROD_PORT:-22}"
    read -p "Daily budget limit USD (default: 50): " DAILY_LIMIT
    DAILY_LIMIT="${DAILY_LIMIT:-50}"
    read -p "Emergency stop USD (default: 100): " EMERGENCY
    EMERGENCY="${EMERGENCY:-100}"

    cat > "$CONFIG_DST/config.json" << CONFIGEOF
{
  "prod_server": "$PROD_SERVER",
  "prod_ssh_port": "$PROD_PORT",
  "budget": {
    "daily_limit_usd": $DAILY_LIMIT,
    "weekly_limit_usd": $(( DAILY_LIMIT * 5 )),
    "throttle_at_pct": 80,
    "emergency_stop_usd": $EMERGENCY
  }
}
CONFIGEOF
    info "config.json created"
fi

# --- settings.json ---
if [ -f "$CONFIG_DST/settings.json" ]; then
    warn "settings.json already exists"
    echo "  To enable JEPO hooks, merge the 'hooks' section from:"
    echo "  $SCRIPT_DIR/templates/settings.json.template"
    echo "  into your existing $CONFIG_DST/settings.json"
else
    cp "$SCRIPT_DIR/templates/settings.json.template" "$CONFIG_DST/settings.json"
    info "settings.json created with hook configuration"
fi

# --- Skills ---
echo ""
echo "Installing skills..."
mkdir -p "$CONFIG_DST/skills/jepo" "$CONFIG_DST/skills/health"
cp "$SCRIPT_DIR/skills/jepo/SKILL.md" "$CONFIG_DST/skills/jepo/"
cp "$SCRIPT_DIR/skills/health/SKILL.md" "$CONFIG_DST/skills/health/"
info "Skills installed (jepo, health)"

# --- Create log directories ---
mkdir -p "$HOME/logs/jepo" "$HOME/logs/claude-auto" "$HOME/.claude/session-sync" "$HOME/.claude/cache/loop-detect"
info "Log directories created"

echo ""

# --- Optional: LaunchAgent setup (macOS) ---
if [[ "$(uname)" == "Darwin" ]]; then
    echo ""
    read -p "Set up macOS LaunchAgents for automation? (y/N): " SETUP_LA
    if [[ "$SETUP_LA" =~ ^[Yy] ]]; then
        read -p "GitHub repo (e.g. owner/repo): " LA_REPO
        read -p "Local repo path: " LA_REPO_DIR

        LA_DIR="$HOME/Library/LaunchAgents"
        mkdir -p "$LA_DIR"

        # auto-fix (every 30 min)
        cat > "$LA_DIR/com.jepo.auto-fix.plist" << PLISTEOF
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
        <string>$LA_REPO</string>
        <key>JEPO_REPO_DIR</key>
        <string>$LA_REPO_DIR</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

        # auto-test (every 10 min)
        cat > "$LA_DIR/com.jepo.auto-test.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jepo.auto-test</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>source ~/.zshrc 2>/dev/null; ~/scripts/claude-auto/auto-test.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
    <key>StandardOutPath</key>
    <string>/tmp/jepo-auto-test.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/jepo-auto-test.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>JEPO_REPO</key>
        <string>$LA_REPO</string>
        <key>JEPO_REPO_DIR</key>
        <string>$LA_REPO_DIR</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

        # auto-deploy (every 15 min)
        cat > "$LA_DIR/com.jepo.auto-deploy.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jepo.auto-deploy</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>source ~/.zshrc 2>/dev/null; ~/scripts/claude-auto/auto-deploy.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>StandardOutPath</key>
    <string>/tmp/jepo-auto-deploy.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/jepo-auto-deploy.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>JEPO_REPO</key>
        <string>$LA_REPO</string>
        <key>JEPO_REPO_DIR</key>
        <string>$LA_REPO_DIR</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

        # deploy-verify (every 5 min)
        cat > "$LA_DIR/com.jepo.deploy-verify.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jepo.deploy-verify</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>source ~/.zshrc 2>/dev/null; ~/scripts/claude-auto/deploy-verify.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>/tmp/jepo-deploy-verify.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/jepo-deploy-verify.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>JEPO_REPO</key>
        <string>$LA_REPO</string>
        <key>JEPO_REPO_DIR</key>
        <string>$LA_REPO_DIR</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLISTEOF

        # Load agents
        for plist in com.jepo.auto-fix com.jepo.auto-test com.jepo.auto-deploy com.jepo.deploy-verify; do
            launchctl load "$LA_DIR/${plist}.plist" 2>/dev/null || true
        done

        info "LaunchAgents created and loaded"
        echo "  - com.jepo.auto-fix (every 30 min)"
        echo "  - com.jepo.auto-test (every 10 min)"
        echo "  - com.jepo.auto-deploy (every 15 min)"
        echo "  - com.jepo.deploy-verify (every 5 min)"
    fi
fi

echo ""
echo "=============================="
echo "  JEPO installed successfully"
echo "=============================="
echo ""
echo "Next steps:"
echo "  1. Review ~/.claude/config.json"
echo "  2. If settings.json was pre-existing, merge hooks from templates/settings.json.template"
echo "  3. Start a new Claude Code session: claude"
echo "  4. For automation, set JEPO_REPO and JEPO_REPO_DIR env vars"
echo ""
echo "Documentation: docs/getting-started.md"
echo ""
