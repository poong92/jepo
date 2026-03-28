#!/bin/bash
# JEPO Cost Tracker v1.0
# Claude CLI 실행 후 토큰 사용량 파싱 + JSONL 기록

TOKEN_LOG="$HOME/logs/claude-auto/token-usage.jsonl"

# 모델별 비용 ($/1M tokens, 2026-03 기준)
_model_cost_input() {
    case "$1" in
        *opus*)   echo "15.0" ;;
        *sonnet*) echo "3.0" ;;
        *haiku*)  echo "0.25" ;;
        *)        echo "3.0" ;;  # 기본값 sonnet
    esac
}

_model_cost_output() {
    case "$1" in
        *opus*)   echo "75.0" ;;
        *sonnet*) echo "15.0" ;;
        *haiku*)  echo "1.25" ;;
        *)        echo "15.0" ;;
    esac
}

# 토큰 사용량 기록
# Usage: log_usage <agent_name> <model> <input_tokens> <output_tokens>
log_usage() {
    local agent="${1:-unknown}"
    local model="${2:-unknown}"
    local input_tokens="${3:-0}"
    local output_tokens="${4:-0}"
    local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local cost_in=$(_model_cost_input "$model")
    local cost_out=$(_model_cost_output "$model")
    local cost_usd=$(python3 -c "print(f'{($input_tokens * $cost_in + $output_tokens * $cost_out) / 1000000:.4f}')" 2>/dev/null || echo "0")

    echo "{\"ts\":\"$ts\",\"agent\":\"$agent\",\"model\":\"$model\",\"input\":$input_tokens,\"output\":$output_tokens,\"cost_usd\":$cost_usd}" >> "$TOKEN_LOG"
}

# stderr에서 토큰 파싱 (Claude CLI 출력 형식)
# Usage: parse_usage <stderr_file> <agent_name> <model>
parse_usage() {
    local stderr_file="$1"
    local agent="$2"
    local model="$3"

    [ -f "$stderr_file" ] || return 0

    # Claude CLI는 "Total tokens: input=X output=Y" 또는 비슷한 형식
    local input_tokens=$(grep -oE 'input[_= ]*([0-9]+)' "$stderr_file" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || echo "0")
    local output_tokens=$(grep -oE 'output[_= ]*([0-9]+)' "$stderr_file" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || echo "0")

    # 파싱 실패 시 추정치 (프롬프트 길이 기반)
    if [ "$input_tokens" = "0" ] && [ "$output_tokens" = "0" ]; then
        local prompt_chars=$(wc -c < "$stderr_file" 2>/dev/null || echo "0")
        input_tokens=$((prompt_chars / 4))  # 대략 4자 = 1토큰
        output_tokens=$((input_tokens / 5)) # 출력은 입력의 ~20%
    fi

    log_usage "$agent" "$model" "$input_tokens" "$output_tokens"
}

# 오늘 총 비용 조회
today_cost() {
    python3 -c "
import json
from datetime import date
total = 0
try:
    with open('$TOKEN_LOG') as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
                if entry.get('ts','')[:10] == str(date.today()):
                    total += float(entry.get('cost_usd', 0))
            except: pass
except FileNotFoundError: pass
print(f'{total:.2f}')
" 2>/dev/null || echo "0.00"
}

# 로테이션 (30일 이상 삭제)
rotate_token_log() {
    [ -f "$TOKEN_LOG" ] || return 0
    local lines=$(wc -l < "$TOKEN_LOG")
    if [ "$lines" -gt 10000 ]; then
        tail -n 5000 "$TOKEN_LOG" > "${TOKEN_LOG}.tmp"
        mv "${TOKEN_LOG}.tmp" "$TOKEN_LOG"
    fi
}
