#!/bin/bash
# JEPO Automation Runner - Secured base wrapper
# All automation scripts source this file for common functionality.
#
# Features:
#   - mkdir-based mutual exclusion (macOS compatible, no flock)
#   - Log rotation (10MB max per log)
#   - Notification support (Telegram or custom)
#   - Claude auth verification
#   - Restricted tool execution via --allowedTools
#
# Usage: source "$(dirname "$0")/claude-runner.sh"

set -euo pipefail

LOCK_DIR="/tmp/claude-auto-locks"
LOG_DIR="$HOME/logs/claude-auto"
RESULTS_DIR="$LOG_DIR/results"
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB

# ---------------------------------------------------------------------------
# Model tier constants -- use these in all scripts
# ---------------------------------------------------------------------------
MODEL_OPUS="claude-opus-4-6"        # Complex code writing, security decisions
MODEL_SONNET="claude-sonnet-4-6"    # Analysis, content generation, PR responses
MODEL_HAIKU="claude-haiku-4-5-20251001"  # Simple checks, monitoring, health

mkdir -p "$LOCK_DIR" "$LOG_DIR" "$RESULTS_DIR"

# Resolve LIB_DIR (works in both repo and deployed structure)
_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$_RUNNER_DIR/../lib" ]]; then
    LIB_DIR="$_RUNNER_DIR/../lib"
elif [[ -d "$_RUNNER_DIR/lib" ]]; then
    LIB_DIR="$_RUNNER_DIR/lib"
else
    LIB_DIR="$_RUNNER_DIR"
fi

# Load notification tokens from environment files
for envfile in "$HOME/.env" "$HOME/.telegram_env"; do
    if [[ -f "$envfile" ]]; then
        set +u
        source "$envfile" 2>/dev/null || true
        set -u
        break
    fi
done

# ---------------------------------------------------------------------------
# Lock via mkdir (atomic, works on macOS without flock)
# ---------------------------------------------------------------------------
acquire_lock() {
    local name="$1"
    local lockdir="$LOCK_DIR/${name}.lockdir"
    if ! mkdir "$lockdir" 2>/dev/null; then
        # Stale lock check (>1 hour old = stale)
        local lock_mtime
        lock_mtime=$(stat -f%m "$lockdir" 2>/dev/null || stat -c%Y "$lockdir" 2>/dev/null || echo "")
        if [[ -z "$lock_mtime" ]]; then
            echo "$(date): $name lock stat failed, skipping" >> "$LOG_DIR/${name}.log"
            exit 0
        fi
        local lock_age=$(( $(date +%s) - lock_mtime ))
        if [[ $lock_age -gt 3600 ]]; then
            rm -rf "$lockdir"
            mkdir "$lockdir" 2>/dev/null || { echo "$(date): $name locked, skip" >> "$LOG_DIR/${name}.log"; exit 0; }
        else
            echo "$(date): $name already running, skipping" >> "$LOG_DIR/${name}.log"
            exit 0
        fi
    fi
    trap "rm -rf '$lockdir'" EXIT
}

# ---------------------------------------------------------------------------
# Log rotation - moves log to .old when it exceeds MAX_LOG_SIZE
# ---------------------------------------------------------------------------
rotate_log() {
    local logfile="$1"
    if [[ -f "$logfile" ]]; then
        local size
        size=$(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null || echo 0)
        if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
            mv "$logfile" "${logfile}.old"
        fi
    fi
}

# ---------------------------------------------------------------------------
# bash_timeout -- pure bash timeout (avoids macOS TCC popups with coreutils)
# Usage: bash_timeout <seconds> <command> [args...]
# ---------------------------------------------------------------------------
bash_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    ( sleep "$secs" 2>/dev/null && kill "$pid" 2>/dev/null ) &
    local watcher=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null || true
    return $rc
}

# ---------------------------------------------------------------------------
# Notification - sends a message via Telegram (or override with custom)
# Requires: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID env vars
# ---------------------------------------------------------------------------
send_telegram() {
    local msg="$1"
    local BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    local CHAT_ID="${TELEGRAM_CHAT_ID:-}"
    if [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]]; then
        curl -s --max-time 15 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="$CHAT_ID" \
            --data-urlencode "text=$msg" \
            -d parse_mode="HTML" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Structured notifications with severity levels
# Levels: CRITICAL / ERROR / WARNING / INFO
# ---------------------------------------------------------------------------
send_telegram_structured() {
    local level="$1"
    local agent="$2"
    local message="$3"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%d %H:%M UTC")

    local formatted_msg="[${level}] <b>${agent}</b>
${message}
<i>${timestamp}</i>"

    send_telegram "$formatted_msg"
}

# ---------------------------------------------------------------------------
# Auth check - verifies Claude CLI is authenticated
# ---------------------------------------------------------------------------
check_auth() {
    local result
    result=$(claude --model "$MODEL_HAIKU" -p "Reply with only: AUTH_OK" 2>&1 | tail -1)
    if [[ "$result" != *"AUTH_OK"* ]]; then
        send_telegram "<b>[Claude Auto]</b> Auth FAILED: $result"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Safe Claude execution with restricted tools
#   $1 - prompt text
#   $2 - comma-separated allowed tools (optional, empty = unrestricted)
#   $3 - max turns (optional, default 3)
#   $4 - model (optional, default MODEL_SONNET)
# ---------------------------------------------------------------------------
run_claude() {
    local prompt="$1"
    local allowed_tools="${2:-}"
    local max_turns="${3:-3}"
    local model="${4:-$MODEL_SONNET}"

    local -a cmd_args=()
    cmd_args+=("claude" "--model" "$model" "-p")
    if [[ -n "$allowed_tools" ]]; then
        cmd_args+=("--allowedTools" "$allowed_tools")
    fi
    cmd_args+=("--max-turns" "$max_turns")

    echo "$prompt" | "${cmd_args[@]}" 2>&1
}

# ---------------------------------------------------------------------------
# validate_output() -- Validate Claude output via Python validator
#   Usage: validate_output "json" "pr-review" "$output"
# ---------------------------------------------------------------------------
validate_output() {
    local output_type="$1"
    local schema="$2"
    local content="$3"

    local validator="$LIB_DIR/output-validator.py"
    if [[ ! -f "$validator" ]]; then
        echo "ERROR: output-validator.py not found at $validator" >&2
        return 1
    fi

    local result
    result=$(echo "$content" | python3 "$validator" "$output_type" "$schema" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "$result" >&2
        return 1
    fi

    echo "$result"
    return 0
}

# ---------------------------------------------------------------------------
# get_secret() -- Retrieve secrets from macOS Keychain or env
#   Usage: get_secret "telegram-bot-token"
# ---------------------------------------------------------------------------
get_secret() {
    local key="$1"

    # Try Keychain first (macOS)
    if command -v security &>/dev/null; then
        local val
        val=$(security find-generic-password -a "$USER" -s "claude-auto-${key}" -w 2>/dev/null) || true
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # Fallback: environment variable (uppercase, dashes to underscores)
    local env_key
    env_key=$(echo "$key" | tr '[:lower:]-' '[:upper:]_')
    local env_val="${!env_key:-}"
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return 0
    fi

    echo "ERROR: Secret '$key' not found in Keychain or env" >&2
    return 1
}

# ---------------------------------------------------------------------------
# create_issue_safe() -- Create GitHub Issue with rate limiting & redaction
#   Usage: create_issue_safe "owner/repo" "title" "body" "label1,label2"
# ---------------------------------------------------------------------------
create_issue_safe() {
    local repo="$1"
    local title="$2"
    local body="$3"
    local labels="${4:-claude-auto}"

    # Rate limit: max 10 issues per day per repo
    local rate_file="/tmp/claude-auto-issue-rate-${repo//\//-}.txt"
    local today
    today=$(date +%Y-%m-%d)
    local count=0

    if [[ -f "$rate_file" ]]; then
        local file_date
        file_date=$(head -1 "$rate_file" 2>/dev/null || echo "")
        if [[ "$file_date" == "$today" ]]; then
            count=$(tail -1 "$rate_file" 2>/dev/null || echo "0")
        fi
    fi

    if [[ "$count" -ge 10 ]]; then
        echo "RATE_LIMITED" >&2
        return 1
    fi

    # Redact potential secrets from body
    local safe_body
    safe_body=$(echo "$body" | sed -E \
        -e 's/[A-Za-z0-9_-]{30,}/[REDACTED]/g' \
        -e 's/ghp_[A-Za-z0-9]{36}/[GH_TOKEN]/g' \
        -e 's/sk-[A-Za-z0-9]{32,}/[API_KEY]/g' \
        -e 's/[0-9]{8,}:[A-Za-z0-9_-]{35}/[BOT_TOKEN]/g')

    title="${title:0:100}"
    safe_body="${safe_body:0:65536}"

    local result
    result=$(gh issue create --repo "$repo" \
        --title "$title" \
        --body "$safe_body" \
        --label "$labels" 2>&1) || {
        echo "FAILED: $result" >&2
        return 1
    }

    printf '%s\n%d\n' "$today" "$((count + 1))" > "$rate_file"
    echo "$result"
    return 0
}

# ---------------------------------------------------------------------------
# atomic_write() -- Write file atomically (temp + rename)
# ---------------------------------------------------------------------------
atomic_write() {
    local target="$1"
    local content="$2"
    local dir
    dir=$(dirname "$target")
    mkdir -p "$dir"
    local tmpfile
    tmpfile=$(mktemp "${dir}/.tmp.XXXXXX")
    chmod 600 "$tmpfile"
    if ! printf '%s' "$content" > "$tmpfile"; then
        rm -f "$tmpfile"
        return 1
    fi
    if ! mv "$tmpfile" "$target"; then
        rm -f "$tmpfile"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# json_append() -- Append entry to JSON array file (thread-safe)
# ---------------------------------------------------------------------------
json_append() {
    local filepath="$1"
    local entry="$2"
    local max_entries="${3:-0}"

    if ! echo "$entry" | python3 -m json.tool >/dev/null 2>&1; then
        echo "ERROR: Invalid JSON entry" >&2
        return 1
    fi

    if [[ ! -f "$filepath" ]]; then
        echo "[]" > "$filepath"
    fi

    JA_FILEPATH="$filepath" JA_MAX="$max_entries" JA_ENTRY="$entry" \
    python3 -c '
import json, os
filepath = os.environ["JA_FILEPATH"]
max_entries = int(os.environ.get("JA_MAX", "0"))
entry_raw = os.environ["JA_ENTRY"]
try:
    with open(filepath, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    data = []
entry = json.loads(entry_raw)
data.append(entry)
if max_entries > 0 and len(data) > max_entries:
    data = data[-max_entries:]
with open(filepath, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
' 2>&1 || {
        echo "ERROR: json_append failed" >&2
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# check_agent_health() -- Check if an agent ran recently
#   Usage: check_agent_health "pr-review" 600
# ---------------------------------------------------------------------------
check_agent_health() {
    local agent="$1"
    local max_age_sec="${2:-3600}"
    local logfile="$LOG_DIR/${agent}.log"
    if [[ ! -f "$logfile" ]]; then
        echo "NO_LOG"
        return 2
    fi
    local last_mod
    last_mod=$(stat -f%m "$logfile" 2>/dev/null || stat -c%Y "$logfile" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local age=$(( now - last_mod ))
    if [[ $age -gt $max_age_sec ]]; then
        echo "STALE:${age}s"
        return 1
    fi
    echo "HEALTHY:${age}s"
    return 0
}
