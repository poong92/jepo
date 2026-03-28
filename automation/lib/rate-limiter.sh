#!/bin/bash
# JEPO Autopilot v0.2.0 — Rate Limiter
# Per-agent daily API quota enforcement
#
# Usage: source lib/rate-limiter.sh
#        rate_check "pr-review" "claude" 50  # max 50 Claude calls/day
#        rate_increment "pr-review" "claude"

# Note: no set -euo pipefail — library inherits caller's options

RATE_DIR="${LOG_DIR:-$HOME/logs/claude-auto}/rate-limits"
mkdir -p "$RATE_DIR"

# Default daily quotas per agent (bash 3.2 compatible — function instead of assoc array)
_rate_default() {
    case "$1" in
        auth-keepalive)    echo 48  ;;
        pr-review)         echo 100 ;;
        find-improvements) echo 8   ;;
        daily-audit)       echo 4   ;;
        deep-qa)           echo 4   ;;
        deploy-verify)     echo 20  ;;
        audit-to-issue)    echo 10  ;;
        data-healer)       echo 144 ;;
        perf-monitor)      echo 48  ;;
        agent-health)      echo 48  ;;
        review-responder)  echo 8   ;;
        *)                 echo 100 ;;
    esac
}

# ---------------------------------------------------------------------------
# rate_check() — Check if agent is within quota
#   $1 - agent name
#   $2 - resource type (claude, github, binance, etc.)
#   $3 - max calls (optional, uses default)
#   Returns: 0 if allowed, 1 if rate limited
# ---------------------------------------------------------------------------
rate_check() {
    local agent="$1"
    local resource="${2:-claude}"
    local max_calls="${3:-$(_rate_default "$agent")}"

    local today
    today=$(date +%Y-%m-%d)
    local rate_file="$RATE_DIR/${agent}-${resource}.json"

    if [[ ! -f "$rate_file" ]]; then
        echo "0"
        return 0
    fi

    local current
    current=$(RL_FILE="$rate_file" RL_TODAY="$today" python3 -c '
import json, os
try:
    with open(os.environ["RL_FILE"]) as f:
        data = json.load(f)
    if data.get("date") == os.environ["RL_TODAY"]:
        print(data.get("count", 0))
    else:
        print(0)
except:
    print(0)
' 2>/dev/null || echo "0")

    if [[ "$current" -ge "$max_calls" ]]; then
        echo "$current"
        return 1
    fi

    echo "$current"
    return 0
}

# ---------------------------------------------------------------------------
# rate_increment() — Record an API call
#   $1 - agent name
#   $2 - resource type
# ---------------------------------------------------------------------------
rate_increment() {
    local agent="$1"
    local resource="${2:-claude}"

    local today
    today=$(date +%Y-%m-%d)
    local rate_file="$RATE_DIR/${agent}-${resource}.json"

    RL_FILE="$rate_file" RL_TODAY="$today" python3 -c '
import json, os

filepath = os.environ["RL_FILE"]
today = os.environ["RL_TODAY"]

try:
    with open(filepath) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}

if data.get("date") != today:
    data = {"date": today, "count": 0}

data["count"] = data.get("count", 0) + 1

with open(filepath, "w") as f:
    json.dump(data, f)
' 2>/dev/null
}

# ---------------------------------------------------------------------------
# rate_status() — Get current usage for all agents
#   Returns JSON with agent usage vs limits
# ---------------------------------------------------------------------------
rate_status() {
    RL_DIR="$RATE_DIR" python3 << 'PYEOF'
import json, os, glob
from datetime import date

rate_dir = os.environ["RL_DIR"]
today = str(date.today())
status = {}

for f in glob.glob(os.path.join(rate_dir, "*.json")):
    basename = os.path.basename(f).replace(".json", "")
    try:
        with open(f) as fh:
            data = json.load(fh)
        if data.get("date") == today:
            status[basename] = data.get("count", 0)
        else:
            status[basename] = 0
    except:
        status[basename] = 0

print(json.dumps(status, indent=2))
PYEOF
}

# ---------------------------------------------------------------------------
# rate_reset() — Reset quota for an agent (manual override)
#   $1 - agent name
#   $2 - resource type
# ---------------------------------------------------------------------------
rate_reset() {
    local agent="$1"
    local resource="${2:-claude}"
    rm -f "$RATE_DIR/${agent}-${resource}.json"
}
