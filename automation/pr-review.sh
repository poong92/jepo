#!/bin/bash
# PR auto-review - reviews open PRs on pruviq/pruviq
# Schedule: every 5 minutes via LaunchAgent
#
# v0.3.0: Full-context review
#   - Gathers project context (tech stack, conventions, QA rules)
#   - Reads PR body/description for intent understanding
#   - Fetches linked issues for background
#   - Provides PRUVIQ-specific coding guidelines
#   - Allows Read + Glob + Grep for codebase exploration
#
# SECURITY:
#   1. Diff + context written to temp files, NOT injected inline.
#   2. Claude restricted to --allowedTools "Read,Glob,Grep" (no Bash/Write).
#   3. Review output sanitized (control chars stripped, length capped).
#   4. flock prevents concurrent execution.

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"
acquire_lock "pr-review"

LOGFILE="$LOG_DIR/pr-review.log"
rotate_log "$LOGFILE"

REPO="pruviq/pruviq"
REPO_LOCAL="$HOME/pruviq"
REVIEW_MARKER="<!-- claude-auto-review -->"
DIFF_FILE="/tmp/claude-pr-diff-$$.txt"
CONTEXT_FILE="/tmp/claude-pr-context-$$.txt"

# Cleanup temp files on exit — MUST preserve lock cleanup from acquire_lock
LOCKDIR="$LOCK_DIR/pr-review.lockdir"
trap "rm -f '$DIFF_FILE' '$CONTEXT_FILE'; rm -rf '$LOCKDIR'" EXIT

echo "$(date): PR review check started" >> "$LOGFILE"

# ─── Ensure local repo is up-to-date for file reads ───
if [[ -d "$REPO_LOCAL/.git" ]]; then
    git -C "$REPO_LOCAL" pull --ff-only --quiet 2>/dev/null || true
fi

# Get open PRs
prs=$(gh pr list --repo "$REPO" --state open --json number,title --jq '.[].number' 2>/dev/null)
if [[ -z "$prs" ]]; then
    echo "$(date): No open PRs" >> "$LOGFILE"
    exit 0
fi

for pr_num in $prs; do
    # Skip if already reviewed by Claude — UNLESS new commits exist since last review
    existing=$(gh pr view "$pr_num" --repo "$REPO" --json comments --jq ".comments[].body" 2>/dev/null)
    if echo "$existing" | grep -q "$REVIEW_MARKER"; then
        # Check if PR has new commits after our last review
        last_review_ts=$(gh pr view "$pr_num" --repo "$REPO" --json comments \
            --jq '[.comments[] | select(.body | contains("claude-auto-review")) | .createdAt] | last' 2>/dev/null)
        last_commit_ts=$(gh pr view "$pr_num" --repo "$REPO" --json commits \
            --jq '.commits[-1].committedDate' 2>/dev/null)
        if [[ -n "$last_review_ts" && -n "$last_commit_ts" && "$last_commit_ts" > "$last_review_ts" ]]; then
            echo "$(date): PR #$pr_num has new commits since review, re-reviewing" >> "$LOGFILE"
        else
            echo "$(date): PR #$pr_num already reviewed, skipping" >> "$LOGFILE"
            continue
        fi
    fi

    echo "$(date): Reviewing PR #$pr_num" >> "$LOGFILE"

    # ─── Gather full PR metadata ───
    pr_meta=$(gh pr view "$pr_num" --repo "$REPO" --json title,body,files,labels,baseRefName,headRefName,additions,deletions,commits 2>/dev/null)
    pr_title=$(echo "$pr_meta" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)
    pr_body=$(echo "$pr_meta" | python3 -c "import sys,json; print(json.load(sys.stdin).get('body','')[:1500])" 2>/dev/null)
    pr_files=$(echo "$pr_meta" | python3 -c "import sys,json; print('\n'.join(f['path'] for f in json.load(sys.stdin).get('files',[])))" 2>/dev/null)
    pr_labels=$(echo "$pr_meta" | python3 -c "import sys,json; print(', '.join(l['name'] for l in json.load(sys.stdin).get('labels',[])))" 2>/dev/null)
    pr_stats=$(echo "$pr_meta" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"+{d.get('additions',0)}/-{d.get('deletions',0)}, {len(d.get('commits',[]))} commits, base: {d.get('baseRefName','?')}, head: {d.get('headRefName','?')}\")
" 2>/dev/null)

    # ─── Write diff to temp file ───
    gh pr diff "$pr_num" --repo "$REPO" > "$DIFF_FILE" 2>/dev/null
    if [[ ! -s "$DIFF_FILE" ]]; then
        echo "$(date): PR #$pr_num diff empty or unavailable, skipping" >> "$LOGFILE"
        continue
    fi

    # Truncate diff to 12000 chars (increased for full-context review)
    if [[ $(wc -c < "$DIFF_FILE") -gt 12000 ]]; then
        head -c 12000 "$DIFF_FILE" > "${DIFF_FILE}.tmp"
        printf '\n\n[TRUNCATED - diff too large, review changed files directly]\n' >> "${DIFF_FILE}.tmp"
        mv "${DIFF_FILE}.tmp" "$DIFF_FILE"
    fi

    # ─── Build context file with project info + PR metadata ───
    cat > "$CONTEXT_FILE" << 'CTXEOF'
# PRUVIQ Project Context (for code review)

## Tech Stack
- Frontend: Astro 5 (SSG, Islands Architecture) + Preact + Tailwind CSS 4 + TypeScript
- Backend: Python FastAPI + ccxt + pandas/numpy + uvicorn
- Charts: lightweight-charts v5
- Deploy: Cloudflare Pages (git push → auto-deploy)
- API: api.pruviq.com (Mac Mini FastAPI)

## Coding Conventions
- Preact (NOT React): use `import { useState } from 'preact/hooks'`
- Static-first data: CDN/static JSON first, API fallback
- i18n: EN + KO dual language support (all user-facing text must have both)
- CSS: Tailwind classes + CSS custom properties (--color-*)
- Commits: git push = production (MUST pass `npm run build` with 0 errors)

## Critical QA Rules
- _redirects must not shadow real pages
- BreadcrumbList JSON-LD: exactly 1 per page (no duplicates)
- Navigation: 6 menus (Market, Strategies, Coins, Simulate, Learn, Fees)
- OG images must exist at referenced paths
- Blog posts need both EN (/blog/) and KO (/ko/blog/) versions

## Review Checklist
1. Security: XSS, injection, exposed secrets, unsafe API calls
2. Correctness: logic errors, missing error handling, edge cases
3. Performance: unnecessary re-renders, N+1 queries, large bundles
4. i18n: missing translations, hardcoded strings
5. Accessibility: alt text, aria labels, keyboard navigation
6. SEO: meta tags, structured data, canonical URLs
7. Build safety: will this break `npm run build`?
CTXEOF

    # Append PR-specific metadata
    cat >> "$CONTEXT_FILE" << PREOF

---
# PR #$pr_num Details

**Title**: $pr_title
**Stats**: $pr_stats
**Labels**: $pr_labels

## PR Description
$pr_body

## Changed Files
$pr_files
PREOF

    echo "$(date): Context file built for PR #$pr_num" >> "$LOGFILE"

    # Rate limit check
    if ! rate_check "pr-review" "claude" >/dev/null 2>&1; then
        echo "$(date): PR #$pr_num skipped — rate limited" >> "$LOGFILE"
        continue
    fi

    # v0.3.0: Full-context review with project knowledge
    # SECURITY: --allowedTools "Read,Glob,Grep" for codebase exploration (no Bash/Write)
    review=$(claude --model "$MODEL_OPUS" -p "You are a senior code reviewer for the PRUVIQ project.

STEP 1 — UNDERSTAND CONTEXT:
Read the project context file at $CONTEXT_FILE to understand the tech stack and conventions.

STEP 2 — READ THE DIFF:
Read the PR diff at $DIFF_FILE to see what changed.

STEP 3 — EXPLORE AFFECTED CODE:
The local repo is at $REPO_LOCAL. For each changed file, read the CURRENT version to understand:
- What the file does (purpose)
- How the change fits into the existing code
- Whether the change might break other parts
Use Glob and Grep to check for related usages if needed.

STEP 4 — PRODUCE VERDICT:
RESPOND WITH ONLY VALID JSON (no markdown fences, no explanation):
{
  \"verdict\": \"APPROVE\" or \"REQUEST_CHANGES\",
  \"score\": 0-100,
  \"issues\": [{\"type\": \"security|quality|performance|i18n|seo|a11y\", \"severity\": \"P0|P1|P2\", \"file\": \"path\", \"line\": 0, \"title\": \"\", \"fix\": \"\"}],
  \"summary\": \"max 400 chars comprehensive review summary\"
}

Rules:
- APPROVE if no P0/P1 issues and score >= 80
- REQUEST_CHANGES if any P0 or P1 issue exists, or score < 80
- Always provide specific file paths and line numbers for issues
- Check i18n: if user-facing text added, both EN and KO must exist
- Check build safety: will npm run build still pass?
- Data-only changes (public/data/*.json) are auto-generated and always safe to approve
- Do NOT execute commands, only read/search files" \
        --allowedTools "Read,Glob,Grep" \
        --max-turns 15 2>&1)

    rate_increment "pr-review" "claude"

    if [[ -z "$review" || ${#review} -lt 10 ]]; then
        echo "$(date): Review output empty for PR #$pr_num" >> "$LOGFILE"
        continue
    fi

    # v0.2.0: Validate JSON output via output-validator.py
    parsed=$(validate_output "json" "pr-review" "$review" 2>&1) && parse_rc=$? || parse_rc=$?

    if [[ $parse_rc -ne 0 ]]; then
        # JSON parse failed → fallback to legacy grep (degraded mode)
        echo "$(date): PR #$pr_num JSON parse failed, using legacy mode" >> "$LOGFILE"
        alert_send "WARNING" "pr-review" "JSON parse failed for PR #$pr_num — legacy fallback" "security" 2>/dev/null

        clean_review=$(echo "$review" | head -c 2000 | tr -d '\000-\010\013\014\016-\037')
        verdict="REVIEW"
        if echo "$clean_review" | grep -qi "REQUEST_CHANGES"; then
            verdict="REQUEST_CHANGES"
        elif echo "$clean_review" | grep -qi "APPROVE"; then
            verdict="APPROVE"
        fi
        score=0
        summary="$clean_review"
    else
        # v0.2.2: Extract all fields in ONE python3 call (prevents partial parse failure)
        read verdict score has_p0 summary < <(echo "$parsed" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["content"]
    verdict = d.get("verdict", "REVIEW")
    score = int(d.get("score", 0))
    summary = d.get("summary", "No summary")[:300].replace("\n", " ")
    issues = d.get("issues", [])
    has_p0 = "yes" if any(i.get("severity") == "P0" for i in issues) else "no"
    # Downgrade APPROVE if score < 80 or P0 exists
    if verdict == "APPROVE" and (score < 80 or has_p0 == "yes"):
        verdict = "REQUEST_CHANGES"
    print(f"{verdict} {score} {has_p0} {summary}")
except Exception as e:
    print(f"REVIEW 0 no parse_error:{e}")
' 2>/dev/null || echo "REVIEW 0 no parse_error")

        if [[ "$verdict" == "REQUEST_CHANGES" && "$has_p0" == "yes" ]]; then
            echo "$(date): PR #$pr_num has P0 issues → REQUEST_CHANGES" >> "$LOGFILE"
        elif [[ "$verdict" == "REQUEST_CHANGES" ]]; then
            echo "$(date): PR #$pr_num downgraded (score $score < 80 or P0)" >> "$LOGFILE"
        fi
    fi

    # Build comment with issue details
    issue_detail=""
    if [[ "$parse_rc" -eq 0 ]]; then
        issue_detail=$(echo "$parsed" | python3 -c '
import sys, json
try:
    issues = json.load(sys.stdin)["content"].get("issues", [])
    if not issues:
        print("")
    else:
        lines = ["\n### Issues Found\n"]
        for i in issues:
            sev = i.get("severity", "P2")
            title = i.get("title", "")
            fix = i.get("fix", "")
            fpath = i.get("file", "")
            line = ["| **{}** | {} | `{}` | {} |".format(sev, title, fpath, fix)]
            lines.extend(line)
        if len(lines) > 1:
            lines.insert(1, "| Severity | Issue | File | Fix |")
            lines.insert(2, "|----------|-------|------|-----|")
        print("\n".join(lines))
except:
    print("")
' 2>/dev/null || echo "")
    fi

    comment="${REVIEW_MARKER}
## Claude Auto-Review (v0.3.0)

${summary}
${issue_detail}

**Verdict**: ${verdict} | **Score**: ${score}/100

---
*Full-context review by Claude Code — checked project conventions, read affected files, verified i18n/SEO/a11y (PRUVIQ CI)*"

    gh pr comment "$pr_num" --repo "$REPO" --body "$comment" 2>> "$LOGFILE"

    # On APPROVE: add "jepo-reviewed" + "automerge" labels → triggers GitHub automerge workflow
    if [[ "$verdict" == "APPROVE" ]]; then
        gh pr edit "$pr_num" --repo "$REPO" --add-label "jepo-reviewed,automerge" 2>> "$LOGFILE" || true
        echo "$(date): PR #$pr_num APPROVED (score=$score) + jepo-reviewed+automerge labels" >> "$LOGFILE"
        alert_send "INFO" "pr-review" "PR #$pr_num APPROVED (${score}/100): $pr_title" "code" 2>/dev/null
    else
        echo "$(date): PR #$pr_num $verdict (score=$score)" >> "$LOGFILE"
        alert_send "INFO" "pr-review" "PR #$pr_num $verdict (${score}/100): $pr_title" "code" 2>/dev/null
    fi
done
