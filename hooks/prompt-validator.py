#!/usr/bin/env python3
"""
JEPO UserPromptSubmit Hook
Blocks prompts containing sensitive information (API keys, tokens, passwords).

To add new patterns: append a (regex, description) tuple to SENSITIVE_PATTERNS.

Event: UserPromptSubmit
"""
import json
import sys
import re

SENSITIVE_PATTERNS = [
    # Generic keys/passwords
    (r"(?i)(password|secret|api[_\s-]?key|token)\s*[:=]\s*['\"]?[a-zA-Z0-9_/+=-]{10,}",
     "API key or password detected"),

    # Card numbers
    (r"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b",
     "Card number pattern detected"),

    # GitHub Personal Access Token
    (r"(?i)ghp_[a-zA-Z0-9]{36}",
     "GitHub PAT detected"),

    # OpenAI API Key
    (r"(?i)sk-[a-zA-Z0-9]{32,}",
     "OpenAI API key detected"),

    # AWS Access Key ID
    (r"AKIA[A-Z0-9]{16}",
     "AWS Access Key detected"),

    # AWS Secret Access Key
    (r"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*['\"]?[A-Za-z0-9/+=]{40}",
     "AWS Secret Key detected"),

    # Generic 64-char hex key
    (r"(?i)(?:api_key|api_secret|secret_key)\s*[:=]\s*['\"]?[a-f0-9]{64}",
     "64-char hex API key detected"),

    # JWT token
    (r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
     "JWT token detected"),

    # Private Key
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
     "Private key detected"),
]


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    prompt = input_data.get("prompt", "")

    for pattern, message in SENSITIVE_PATTERNS:
        if re.search(pattern, prompt):
            output = {
                "decision": "block",
                "reason": f"[JEPO Security] {message}. Remove sensitive data and try again."
            }
            print(json.dumps(output, ensure_ascii=False))
            sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
