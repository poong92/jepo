#!/usr/bin/env python3
"""
JEPO UserPromptSubmit Hook
- 민감 정보 차단
- 프롬프트 검증

패턴 추가 방법:
  SENSITIVE_PATTERNS 리스트에 (regex, description) 튜플 추가
"""
import json
import sys
import re

# 민감 정보 패턴 목록 (차단)
# 새 패턴 추가 시 이 리스트에 튜플만 추가하면 됨
SENSITIVE_PATTERNS = [
    # 범용 키/비밀번호
    (r"(?i)(password|secret|api[_\s-]?key|token)\s*[:=]\s*['\"]?[a-zA-Z0-9_/+=-]{10,}",
     "API 키/비밀번호 감지"),

    # 카드 번호
    (r"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b",
     "카드 번호 형식 감지"),

    # GitHub Personal Access Token
    (r"(?i)ghp_[a-zA-Z0-9]{36}",
     "GitHub PAT 감지"),

    # OpenAI API Key
    (r"(?i)sk-[a-zA-Z0-9]{32,}",
     "OpenAI API 키 감지"),

    # AWS Access Key ID
    (r"AKIA[A-Z0-9]{16}",
     "AWS Access Key 감지"),

    # AWS Secret Access Key (40자 base64)
    (r"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*['\"]?[A-Za-z0-9/+=]{40}",
     "AWS Secret Key 감지"),

    # Binance API Key (64자 hex)
    (r"(?i)binance[_-]?api[_-]?key\s*[:=]\s*['\"]?[a-zA-Z0-9]{64}",
     "Binance API 키 감지"),

    # Binance Secret Key
    (r"(?i)binance[_-]?(?:api[_-]?)?secret\s*[:=]\s*['\"]?[a-zA-Z0-9]{64}",
     "Binance Secret 키 감지"),

    # Generic 64-char hex key assigned to common variable names
    (r"(?i)(?:api_key|api_secret|secret_key)\s*[:=]\s*['\"]?[a-f0-9]{64}",
     "64자리 hex API 키 감지"),

    # JWT 토큰
    (r"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
     "JWT 토큰 감지"),

    # Private Key
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
     "Private Key 감지"),
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
                "reason": f"[JEPO 보안] {message}. 민감 정보를 제거하고 다시 입력해주세요."
            }
            print(json.dumps(output, ensure_ascii=False))
            sys.exit(0)

    # 정상 통과
    sys.exit(0)


if __name__ == "__main__":
    main()
