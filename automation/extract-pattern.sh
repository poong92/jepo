#!/bin/bash
# JEPO Pattern Extractor
# After successful deploy, saves fix patterns to fix-patterns.jsonl for learning

PR_NUMBER="$1"
REPO="${2:-${JEPO_REPO:-}}"
PATTERNS_FILE="$HOME/logs/claude-auto/fix-patterns.jsonl"
MAX_PATTERNS=1000

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
    echo "Usage: extract-pattern.sh <pr_number> [repo]"
    exit 1
fi

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

# Only extract patterns from auto-generated PRs
if ! echo "$labels" | grep -q "claude-auto"; then
    exit 0
fi

changed_files=$(gh pr diff --repo "$REPO" "$PR_NUMBER" --name-only 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')
issue_numbers=$(echo "$title" | grep -oE '#[0-9]+' | tr -d '#' | tr '\n' ',' | sed 's/,$//')

# Auto-classify category
category="other"
case "$title" in
    *type*|*TypeScript*|*tsx*) category="type-error" ;;
    *API*|*endpoint*|*fetch*) category="api-contract" ;;
    *build*|*config*) category="build-config" ;;
    *css*|*layout*|*style*|*tailwind*) category="css-layout" ;;
    *i18n*|*translation*) category="i18n-missing" ;;
    *data*|*json*|*csv*) category="data-format" ;;
    *import*|*path*|*module*) category="import-path" ;;
    *fix*|*bug*|*error*) category="logic-error" ;;
esac

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

# Rotation
line_count=$(wc -l < "$PATTERNS_FILE")
if [ "$line_count" -gt "$MAX_PATTERNS" ]; then
    tail -n "$MAX_PATTERNS" "$PATTERNS_FILE" > "${PATTERNS_FILE}.tmp"
    mv "${PATTERNS_FILE}.tmp" "$PATTERNS_FILE"
fi

echo "Pattern extracted: $title (category: $category)"

# Trigger rule suggestion
"$(dirname "$0")/suggest-rule.sh" "$PR_NUMBER" "$REPO" 2>/dev/null || true
