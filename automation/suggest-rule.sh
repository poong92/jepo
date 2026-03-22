#!/bin/bash
# JEPO Rule Suggestion
# Detects repeated fix categories in fix-patterns.jsonl -> suggests CLAUDE.md rules

source "$(dirname "$0")/claude-runner.sh"

PATTERNS_FILE="$LOG_DIR/fix-patterns.jsonl"
GUARD_FILE="$LOG_DIR/.suggest-rule-guard"
PR_NUMBER="$1"
REPO="${2:-${JEPO_REPO:-}}"

[ -f "$PATTERNS_FILE" ] && [ -s "$PATTERNS_FILE" ] || exit 0

# Max once per day (prevent notification spam)
if [ -f "$GUARD_FILE" ]; then
    guard_date=$(cat "$GUARD_FILE" 2>/dev/null)
    today=$(date +%Y-%m-%d)
    [ "$guard_date" = "$today" ] && exit 0
fi

# Find categories repeated 2+ times
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

# Skip if already suggested for this category
if grep -q "$category" "$GUARD_FILE" 2>/dev/null; then
    exit 0
fi

# Generate rule draft (template-based, zero cost)
case "$category" in
    type-error)
        rule_text="Avoid 'any' type. Use specific types or 'unknown' + type guards." ;;
    api-contract)
        rule_text="When changing API response fields, update frontend types simultaneously." ;;
    build-config)
        rule_text="After build config changes, verify 'npm run build' has 0 errors before commit." ;;
    css-layout)
        rule_text="After layout changes, verify mobile (390px) + desktop (1280px). Touch targets >= 44px." ;;
    i18n-missing)
        rule_text="New text must be added to all language files simultaneously. No hardcoded strings." ;;
    data-format)
        rule_text="CSV/JSON parsing must include error handling. No bare 'except: pass'." ;;
    *)
        rule_text="$category issues repeated (${count}x). Add a prevention rule to CLAUDE.md." ;;
esac

# Notify (Telegram or stdout)
send_telegram "[Rule Suggestion] '$category' issue repeated ${count}x

Suggested rule:
$rule_text

Reply to approve." 2>/dev/null || echo "[JEPO] Rule suggestion: $rule_text"

echo "$(date +%Y-%m-%d) $category" > "$GUARD_FILE"

log "Rule suggestion sent: $category ($count occurrences)"

exit 0
