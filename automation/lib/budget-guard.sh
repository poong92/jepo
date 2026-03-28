#!/bin/bash
# JEPO Budget Guard v1.0
# 일일/주간 비용 한도 체크 + 자동 throttle

source "$(dirname "${BASH_SOURCE[0]}")/cost-tracker.sh"

CONFIG_FILE="$HOME/.claude/config.json"

# 예산 설정 읽기
_budget_daily() { python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('budget',{}).get('daily_limit_usd', 50))" 2>/dev/null || echo "50"; }
_budget_throttle_pct() { python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('budget',{}).get('throttle_at_pct', 80))" 2>/dev/null || echo "80"; }
_budget_emergency() { python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('budget',{}).get('emergency_stop_usd', 100))" 2>/dev/null || echo "100"; }

# 예산 체크 — 호출 전에 실행
# Returns: 0=OK, 1=throttled(haiku only), 2=stopped
# Usage: budget_check <model>
budget_check() {
    local model="${1:-sonnet}"
    local today=$(today_cost)
    local daily_limit=$(_budget_daily)
    local throttle_pct=$(_budget_throttle_pct)
    local emergency=$(_budget_emergency)

    # Emergency stop
    if python3 -c "exit(0 if float('$today') >= float('$emergency') else 1)" 2>/dev/null; then
        echo "BUDGET_EMERGENCY: \$$today >= \$$emergency"
        return 2
    fi

    # Throttle (80% 도달 시 haiku만 허용)
    local throttle_at=$(python3 -c "print(f'{float($daily_limit) * float($throttle_pct) / 100:.2f}')" 2>/dev/null || echo "40")
    if python3 -c "exit(0 if float('$today') >= float('$throttle_at') else 1)" 2>/dev/null; then
        case "$model" in
            *haiku*) return 0 ;;  # haiku는 허용
            *)
                echo "BUDGET_THROTTLE: \$$today >= \$$throttle_at (${throttle_pct}% of \$$daily_limit). Haiku only."
                return 1
                ;;
        esac
    fi

    return 0
}
