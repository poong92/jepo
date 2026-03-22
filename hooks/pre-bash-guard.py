#!/usr/bin/env python3
"""
JEPO PreToolUse Hook -- Bash command pre-validation
Uses shlex parser to prevent command obfuscation bypass.
Server IP read from ~/.claude/config.json (single source of truth).

Exit codes: 0=allow (may add context), 2=block
Event: PreToolUse (matcher: Bash)
"""
import json
import sys
import shlex
import os

CONFIG_FILE = os.path.expanduser("~/.claude/config.json")

def load_config():
    """Load server config. Returns empty dict on failure."""
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

config = load_config()
PROD_SERVER = config.get("prod_server", "")
SENSITIVE_EXTS = {".env", ".key", ".pem", ".credentials", ".secret", ".p12", ".pfx"}
DANGEROUS_CMDS = {"mkfs", "dd", "shutdown", "reboot", "init"}
FILE_READ_CMDS = {"cat", "less", "more", "head", "tail", "bat"}


def get_base_cmd(token):
    """Extract command name from path: /usr/bin/cat -> cat"""
    return os.path.basename(token)


def check_command(cmd_str):
    """Analyze command. Returns (action, message) or None if allowed."""
    try:
        tokens = shlex.split(cmd_str)
    except ValueError:
        return None
    if not tokens:
        return None

    base = get_base_cmd(tokens[0])

    # Block dangerous commands (including subcommands like mkfs.ext4)
    if base in DANGEROUS_CMDS or base.split(".")[0] in DANGEROUS_CMDS:
        return ("block", f"Dangerous command blocked: {base}")

    # Detect rm -rf
    if base == "rm":
        flags = [t for t in tokens[1:] if t.startswith("-")]
        flag_str = " ".join(flags)
        if "r" in flag_str and ("f" in flag_str or len(tokens) > 2):
            return ("warn", "Recursive delete detected. Double-check the path.")

    # Detect sensitive file reads
    if base in FILE_READ_CMDS:
        for token in tokens[1:]:
            if not token.startswith("-"):
                basename_token = os.path.basename(token)
                _, ext = os.path.splitext(token)
                if ext.lower() in SENSITIVE_EXTS or basename_token.lower() in {
                    ".env", ".env.local", ".env.production", ".env.development"
                }:
                    return ("warn", f"Sensitive file read detected: {token}")

    # Block force push to production server
    if base == "git" and "push" in tokens:
        if ("--force" in tokens or "-f" in tokens) and PROD_SERVER and PROD_SERVER in cmd_str:
            return ("block", "Force push to production server blocked")
        if "--force" in tokens or "-f" in tokens:
            return ("warn", "git force push detected. Verify target branch.")

    # Warn on production Docker operations
    if base == "ssh" and PROD_SERVER and PROD_SERVER in cmd_str:
        docker_cmds = ["docker-compose down", "docker rm", "docker stop"]
        if any(dc in cmd_str for dc in docker_cmds):
            return ("warn", "Production server Docker operation detected. May cause downtime.")

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    cmd = data.get("tool_input", {}).get("command", "")
    if not cmd:
        sys.exit(0)

    # Check each part of piped/chained commands
    for part in cmd.replace("&&", ";").replace("||", ";").split(";"):
        part = part.strip()
        if not part:
            continue
        for sub in part.split("|"):
            sub = sub.strip()
            if not sub:
                continue
            result = check_command(sub)
            if result:
                action, msg = result
                if action == "block":
                    print(json.dumps({"decision": "block",
                                      "reason": f"[JEPO] {msg}"}))
                    sys.exit(2)
                else:
                    print(json.dumps(
                        {"additionalContext": f"[JEPO WARNING] {msg}"}))
                    sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
