#!/bin/bash
# JEPO Pattern Extractor v1.0
# auto-deploy 성공 후 수정 패턴을 fix-patterns.jsonl에 저장

PR_NUMBER="$1"
REPO="${2:-pruviq/pruviq}"
PATTERNS_FILE="$HOME/logs/claude-auto/fix-patterns.jsonl"
MAX_PATTERNS=1000

if [ -z "$PR_NUMBER" ]; then
    echo "Usage: extract-pattern.sh <pr_number> [repo]"
    exit 1
fi

# PR 정보 가져오기
pr_json=$(gh pr view --repo "$REPO" "$PR_NUMBER" --json title,labels,body,additions,deletions,changedFiles,mergedAt,url 2>/dev/null)
if [ -z "$pr_json" ] || [ "$pr_json" = "null" ]; then
    exit 0
fi

title=$(echo "$pr_json" | jq -r '.title // ""')
labels=$(echo "$pr_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null)
additions=$(echo "$pr_json" | jq -r '.additions // 0')
deletions=$(echo "$pr_json" | jq -r '.deletions // 0')
merged_at=$(echo "$pr_json" | jq -r '.mergedAt // ""')
url=$(echo "$pr_json" | jq -r '.url // ""')

# claude-auto가 만든 PR만 패턴 추출 (수동 PR은 스킵)
if ! echo "$labels" | grep -q "claude-auto"; then
    exit 0
fi

# 변경 파일 목록
changed_files=$(gh pr diff --repo "$REPO" "$PR_NUMBER" --name-only 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')

# 연관 이슈 번호 추출
issue_numbers=$(echo "$title" | grep -oE '#[0-9]+' | tr -d '#' | tr '\n' ',' | sed 's/,$//')

# 카테고리 자동 분류 (단순 키워드 기반)
category="other"
case "$title" in
    *hydration*|*client:*) category="hydration-mismatch" ;;
    *type*|*TypeScript*|*tsx*) category="type-error" ;;
    *API*|*endpoint*|*fetch*) category="api-contract" ;;
    *build*|*config*|*astro*) category="build-config" ;;
    *css*|*layout*|*style*|*tailwind*) category="css-layout" ;;
    *i18n*|*translation*|*ko.ts*|*en.ts*) category="i18n-missing" ;;
    *data*|*json*|*csv*) category="data-format" ;;
    *import*|*path*|*module*) category="import-path" ;;
    *fix*|*bug*|*error*) category="logic-error" ;;
esac

# JSONL에 추가
jq -nc \
    --arg id "fp-$(date +%Y%m%d)-${PR_NUMBER}" \
    --arg title "$title" \
    --arg labels "$labels" \
    --arg category "$category" \
    --arg files "$changed_files" \
    --arg issues "$issue_numbers" \
    --argjson additions "$additions" \
    --argjson deletions "$deletions" \
    --arg merged "$merged_at" \
    --arg url "$url" \
    '{id:$id, title:$title, labels:$labels, category:$category, files:$files, issues:$issues, additions:$additions, deletions:$deletions, merged_at:$merged, url:$url}' \
    >> "$PATTERNS_FILE"

# 로테이션 (1000줄 초과 시 오래된 것 삭제)
line_count=$(wc -l < "$PATTERNS_FILE")
if [ "$line_count" -gt "$MAX_PATTERNS" ]; then
    tail -n "$MAX_PATTERNS" "$PATTERNS_FILE" > "${PATTERNS_FILE}.tmp"
    mv "${PATTERNS_FILE}.tmp" "$PATTERNS_FILE"
fi

echo "Pattern extracted: $title (category: $category)"

# 반복 패턴 감지 → 룰 제안
"$(dirname "$0")/suggest-rule.sh" "$PR_NUMBER" "$REPO" 2>/dev/null || true
