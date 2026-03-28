#!/bin/bash
# JEPO Regression Test Generator v1.0
# auto-fix PR 성공 후 해당 수정에 대한 E2E 테스트 자동 생성

BRANCH="$1"
REPO_DIR="$2"

if [ -z "$BRANCH" ] || [ -z "$REPO_DIR" ]; then
    exit 0
fi

cd "$REPO_DIR" 2>/dev/null || exit 0

# 변경된 파일 목록
CHANGED_FILES=$(git diff --name-only origin/main 2>/dev/null | grep -E '\.(tsx?|astro)$' | head -5)
if [ -z "$CHANGED_FILES" ]; then
    exit 0
fi

# 이미 테스트가 있는 파일은 스킵
NEEDS_TEST=""
for file in $CHANGED_FILES; do
    base=$(basename "$file" | sed 's/\.\(tsx\?\|astro\)$//')
    existing=$(find tests/ -name "*${base}*" -name "*.spec.ts" 2>/dev/null | head -1)
    if [ -z "$existing" ]; then
        NEEDS_TEST="$NEEDS_TEST $file"
    fi
done

if [ -z "$NEEDS_TEST" ]; then
    exit 0
fi

# 최대 2개 파일에 대해서만 테스트 생성
NEEDS_TEST=$(echo "$NEEDS_TEST" | tr ' ' '\n' | head -2 | tr '\n' ' ')

# Claude(Haiku)로 간단한 regression 테스트 생성
for file in $NEEDS_TEST; do
    base=$(basename "$file" | sed 's/\.\(tsx\?\|astro\)$//')
    test_file="tests/e2e/regression-${base}.spec.ts"

    # 이미 존재하면 스킵
    [ -f "$test_file" ] && continue

    timeout 60 claude --model "claude-haiku-4-5-20251001" -p "Generate a minimal Playwright E2E regression test for this changed file.

File: $file
Changes: $(git diff origin/main -- "$file" 2>/dev/null | head -80)

Requirements:
- Output ONLY the test file content (no explanation)
- Use @playwright/test imports
- Test that the fix doesn't regress (basic smoke test)
- Keep it under 30 lines
- Base URL: https://pruviq.com" \
        --allowedTools "Read" \
        --max-turns 5 \
        --output-file "$test_file" 2>/dev/null || true

    # 테스트 파일 검증: 생성 → 실행 → 실패 시 수정 → 재실행 (최대 2회)
    if [ -f "$test_file" ] && [ -s "$test_file" ] && grep -q "import.*playwright" "$test_file" 2>/dev/null; then
        test_passed=false
        for attempt in 1 2 3; do
            if timeout 60 npx playwright test "$test_file" --reporter=line 2>/dev/null; then
                test_passed=true
                break
            fi
            # 마지막 시도가 아니면 Claude로 수정
            if [ "$attempt" -lt 3 ]; then
                error_msg=$(timeout 60 npx playwright test "$test_file" --reporter=line 2>&1 | tail -20)
                timeout 60 claude --model "claude-haiku-4-5-20251001" -p "Fix this failing Playwright test.

Error: $error_msg

Current test:
$(cat "$test_file")

Output ONLY the corrected test file content. No explanation." \
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

# 테스트가 추가됐으면 커밋
added=$(git diff --cached --name-only 2>/dev/null | grep "regression-" | wc -l | tr -d ' ')
if [ "$added" -gt 0 ]; then
    git commit -m "test: add regression tests for auto-fix changes" 2>/dev/null
    git push origin "$BRANCH" 2>/dev/null
fi

exit 0
