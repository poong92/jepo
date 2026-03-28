#!/bin/bash
# JEPO Rule Suggestion v1.0
# fix-patterns.jsonl에서 반복 카테고리 감지 → CLAUDE.md 룰 제안 (Telegram 승인)

source "$(dirname "$0")/claude-runner.sh"

PATTERNS_FILE="$LOG_DIR/fix-patterns.jsonl"
GUARD_FILE="$LOG_DIR/.suggest-rule-guard"
PR_NUMBER="$1"
REPO="${2:-pruviq/pruviq}"

# 패턴 파일 없거나 비어있으면 종료
[ -f "$PATTERNS_FILE" ] && [ -s "$PATTERNS_FILE" ] || exit 0

# 하루 1번만 제안 (과다 알림 방지)
if [ -f "$GUARD_FILE" ]; then
    guard_date=$(cat "$GUARD_FILE" 2>/dev/null)
    today=$(date +%Y-%m-%d)
    [ "$guard_date" = "$today" ] && exit 0
fi

# 같은 카테고리가 2회 이상 반복되는지 확인
repeated_category=$(python3 -c "
import json, collections
cats = []
with open('$PATTERNS_FILE') as f:
    for line in f:
        try:
            p = json.loads(line.strip())
            cats.append(p.get('category','other'))
        except: pass
counts = collections.Counter(cats)
for cat, n in counts.most_common():
    if n >= 2 and cat != 'other':
        print(f'{cat}:{n}')
        break
" 2>/dev/null)

[ -z "$repeated_category" ] && exit 0

category=$(echo "$repeated_category" | cut -d: -f1)
count=$(echo "$repeated_category" | cut -d: -f2)

# 이 카테고리에 대해 이미 제안했으면 스킵
if grep -q "$category" "$GUARD_FILE" 2>/dev/null; then
    exit 0
fi

# 해당 카테고리 패턴들 수집
patterns=$(grep "\"$category\"" "$PATTERNS_FILE" 2>/dev/null | tail -3)
pattern_titles=$(echo "$patterns" | jq -r '.title' 2>/dev/null | tr '\n' '; ')
pattern_files=$(echo "$patterns" | jq -r '.files' 2>/dev/null | sort -u | tr '\n' ', ')

# 룰 초안 생성 (Claude 없이, 템플릿 기반 — 비용 0)
case "$category" in
    hydration-mismatch)
        rule_text="client:visible/client:load 컴포넌트 변경 시 SSR 초기값과 hydration props 일치 확인 필수" ;;
    i18n-missing)
        rule_text="새 텍스트 추가 시 en.ts + ko.ts 동시 업데이트. 하드코딩 문자열 금지" ;;
    css-layout)
        rule_text="레이아웃 변경 시 모바일(390px) + 데스크톱(1280px) 모두 확인. 터치타겟 44px 이상" ;;
    build-config)
        rule_text="빌드 설정 변경 시 npm run build 0 errors 확인 후 커밋" ;;
    type-error)
        rule_text="any 타입 사용 금지. 구체적 타입 또는 unknown + 타입 가드 사용" ;;
    api-contract)
        rule_text="API 응답 필드명 변경 시 프론트엔드 타입 동시 업데이트 (1글자 차이도 silent fail)" ;;
    data-format)
        rule_text="CSV/JSON 데이터 파싱 시 에러 핸들링 필수. bare except: pass 금지" ;;
    *)
        rule_text="$category 유형 이슈 반복 발생 (${count}회). 관련 파일: $pattern_files" ;;
esac

# Telegram으로 승인 요청
send_telegram "📋 <b>[룰 제안]</b> '$category' 이슈 ${count}회 반복 감지

<b>제안 룰:</b>
$rule_text

<b>관련 PR:</b> $pattern_titles

👍 승인하려면 '룰승인'으로 답장
❌ 거부하려면 무시" 2>/dev/null || true

# 가드 파일 업데이트 (오늘 날짜 + 카테고리)
echo "$(date +%Y-%m-%d) $category" > "$GUARD_FILE"

log "Rule suggestion sent: $category ($count occurrences)"

exit 0
