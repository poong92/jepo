#!/usr/bin/env python3
"""
JEPO PreToolUse Hook — Bash 명령 사전 검증 v2.1
shlex 파서 기반으로 명령어 난독화 우회 방지
서버 IP는 ~/.claude/config.json에서 읽음 (단일 소스 원칙)

Exit codes: 0=allow (context 추가 가능), 2=block
"""
import json
import sys
import shlex
import os

CONFIG_FILE = os.path.expanduser("~/.claude/config.json")

def load_config():
    """config.json에서 서버 설정 로드. 실패 시 빈 dict 반환."""
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

config = load_config()
PROD_SERVER = config.get("prod_server", "167.172.81.145")
SENSITIVE_EXTS = {".env", ".key", ".pem", ".credentials", ".secret", ".p12", ".pfx"}
DANGEROUS_CMDS = {"mkfs", "dd", "shutdown", "reboot", "init"}
FILE_READ_CMDS = {"cat", "less", "more", "head", "tail", "bat"}


def get_base_cmd(token):
    """경로에서 명령어 이름만 추출: /usr/bin/cat -> cat"""
    return os.path.basename(token)


def check_command(cmd_str):
    """명령어 분석 후 (action, message) 반환. None이면 허용."""
    try:
        tokens = shlex.split(cmd_str)
    except ValueError:
        return None
    if not tokens:
        return None

    base = get_base_cmd(tokens[0])

    # 위험 명령어 차단 (mkfs.ext4 같은 서브커맨드도 포함)
    if base in DANGEROUS_CMDS or base.split(".")[0] in DANGEROUS_CMDS:
        return ("block", f"위험 명령 차단: {base}")

    # rm -rf 계열 감지
    if base == "rm":
        flags = [t for t in tokens[1:] if t.startswith("-")]
        flag_str = " ".join(flags)
        if "r" in flag_str and ("f" in flag_str or len(tokens) > 2):
            return ("warn", "재귀 삭제 명령 감지. 경로를 다시 확인하세요.")

    # 민감 파일 읽기 감지
    if base in FILE_READ_CMDS:
        for token in tokens[1:]:
            if not token.startswith("-"):
                basename_token = os.path.basename(token)
                _, ext = os.path.splitext(token)
                # .env 같은 dotfile은 basename 자체가 확장자
                if ext.lower() in SENSITIVE_EXTS or basename_token.lower() in {
                    ".env", ".env.local", ".env.production", ".env.development"
                }:
                    return ("warn", f"민감 파일 읽기 감지: {token}")

    # 프로덕션 서버 force push 차단
    if base == "git" and "push" in tokens:
        if ("--force" in tokens or "-f" in tokens) and PROD_SERVER in cmd_str:
            return ("block", "AutoTrader 프로덕션 서버에 force push 차단")
        if "--force" in tokens or "-f" in tokens:
            return ("warn", "git force push 감지. 대상 브랜치 확인 필요.")

    # 프로덕션 Docker 조작 경고
    if base == "ssh" and PROD_SERVER in cmd_str:
        docker_cmds = ["docker-compose down", "docker rm", "docker stop"]
        if any(dc in cmd_str for dc in docker_cmds):
            return ("warn", "프로덕션 서버 Docker 조작 감지. 실거래 중단 가능.")

    return None


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    cmd = data.get("tool_input", {}).get("command", "")
    if not cmd:
        sys.exit(0)

    # 파이프/체인 명령은 각각 검사
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
