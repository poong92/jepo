#!/bin/bash
# JEPO Regression Test Generator
# After auto-fix PR, generates E2E tests for changed files

BRANCH="$1"
REPO_DIR="$2"
BASE_URL="${JEPO_BASE_URL:-http://localhost:3000}"

if [ -z "$BRANCH" ] || [ -z "$REPO_DIR" ]; then
    exit 0
fi

cd "$REPO_DIR" 2>/dev/null || exit 0

CHANGED_FILES=$(git diff --name-only origin/main 2>/dev/null | grep -E '\.(tsx?|astro|jsx?)$' | head -5)
if [ -z "$CHANGED_FILES" ]; then
    exit 0
fi

# Skip files that already have tests
NEEDS_TEST=""
for file in $CHANGED_FILES; do
    base=$(basename "$file" | sed 's/\.\(tsx\?\|jsx\?\|astro\)$//')
    existing=$(find tests/ -name "*${base}*" -name "*.spec.ts" 2>/dev/null | head -1)
    if [ -z "$existing" ]; then
        NEEDS_TEST="$NEEDS_TEST $file"
    fi
done

if [ -z "$NEEDS_TEST" ]; then
    exit 0
fi

NEEDS_TEST=$(echo "$NEEDS_TEST" | tr ' ' '\n' | head -2 | tr '\n' ' ')

for file in $NEEDS_TEST; do
    base=$(basename "$file" | sed 's/\.\(tsx\?\|jsx\?\|astro\)$//')
    test_file="tests/e2e/regression-${base}.spec.ts"

    [ -f "$test_file" ] && continue

    timeout 60 claude --model "claude-haiku-4-5-20251001" -p "Generate a minimal Playwright E2E regression test for this changed file.

File: $file
Changes: $(git diff origin/main -- "$file" 2>/dev/null | head -80)

Requirements:
- Output ONLY the test file content (no explanation)
- Use @playwright/test imports
- Test that the fix doesn't regress (basic smoke test)
- Keep it under 30 lines
- Base URL: $BASE_URL" \
        --allowedTools "Read" \
        --max-turns 5 \
        --output-file "$test_file" 2>/dev/null || true

    # Validate and run test
    if [ -f "$test_file" ] && [ -s "$test_file" ] && grep -q "import.*playwright" "$test_file" 2>/dev/null; then
        test_passed=false
        for attempt in 1 2 3; do
            if timeout 60 npx playwright test "$test_file" --reporter=line 2>/dev/null; then
                test_passed=true
                break
            fi
            if [ "$attempt" -lt 3 ]; then
                error_msg=$(timeout 60 npx playwright test "$test_file" --reporter=line 2>&1 | tail -20)
                timeout 60 claude --model "claude-haiku-4-5-20251001" -p "Fix this failing Playwright test.

Error: $error_msg

Current test:
$(cat "$test_file")

Output ONLY the corrected test file content." \
                    --allowedTools "Read" \
                    --max-turns 3 \
                    --output-file "$test_file" 2>/dev/null || true
            fi
        done

        if $test_passed; then
            git add "$test_file" 2>/dev/null
        else
            rm -f "$test_file"
        fi
    else
        rm -f "$test_file" 2>/dev/null
    fi
done

added=$(git diff --cached --name-only 2>/dev/null | grep "regression-" | wc -l | tr -d ' ')
if [ "$added" -gt 0 ]; then
    git commit -m "test: add regression tests for auto-fix changes" 2>/dev/null
    git push origin "$BRANCH" 2>/dev/null
fi

exit 0
