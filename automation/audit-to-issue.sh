#!/bin/bash
# audit-to-issue — Convert audit/QA findings → GitHub Issues
# Schedule: 1h after daily-audit (04:00 UTC)
#
# Phases:
#   1. Parse audit/QA reports for findings
#   2. Deduplicate against existing GitHub Issues
#   3. Create new issues (max 5/run)
#   4. Update recurring issues (escalate if 3+ occurrences)
#   5. Summary report + Telegram

source "$(dirname "$0")/claude-runner.sh"
source "$LIB_DIR/alert-manager.sh"
source "$LIB_DIR/rate-limiter.sh"

acquire_lock "audit-to-issue"

LOGFILE="$LOG_DIR/audit-to-issue.log"
rotate_log "$LOGFILE"

REPO="pruviq/pruviq"
MAX_NEW_ISSUES=5
MAX_COMMENTS=10
TODAY=$(date +%Y%m%d)

echo "$(date): audit-to-issue started" >> "$LOGFILE"

# Rate limit check
if ! rate_check "audit-to-issue" "github" >/dev/null 2>&1; then
    echo "$(date): Rate limited, skipping" >> "$LOGFILE"
    exit 0
fi

# ─── Phase 1: Find latest audit/QA reports ───
AUDIT_FILE="$RESULTS_DIR/daily-audit-${TODAY}.md"
QA_FILE="$RESULTS_DIR/deep-qa-${TODAY}.md"

# Try yesterday if today's not ready yet
if [[ ! -f "$AUDIT_FILE" ]]; then
    YESTERDAY=$(date -v-1d +%Y%m%d 2>/dev/null || date -d "yesterday" +%Y%m%d 2>/dev/null)
    AUDIT_FILE="$RESULTS_DIR/daily-audit-${YESTERDAY}.md"
fi
if [[ ! -f "$QA_FILE" ]]; then
    YESTERDAY=$(date -v-1d +%Y%m%d 2>/dev/null || date -d "yesterday" +%Y%m%d 2>/dev/null)
    QA_FILE="$RESULTS_DIR/deep-qa-${YESTERDAY}.md"
fi

if [[ ! -f "$AUDIT_FILE" && ! -f "$QA_FILE" ]]; then
    echo "$(date): No audit/QA reports found, skipping" >> "$LOGFILE"
    exit 0
fi

echo "$(date): Processing: audit=${AUDIT_FILE##*/} qa=${QA_FILE##*/}" >> "$LOGFILE"

# ─── Phase 1: Extract findings using Python ───
FINDINGS_FILE=$(mktemp -t claude-auto-findings.XXXXXX)
chmod 600 "$FINDINGS_FILE"
# MUST preserve lock cleanup from acquire_lock
LOCKDIR="$LOCK_DIR/audit-to-issue.lockdir"
trap "rm -f '$FINDINGS_FILE' '${FINDINGS_FILE}.deduped'; rm -rf '$LOCKDIR'" EXIT

# Parse reports into structured findings
AUDIT_PATH="$AUDIT_FILE" QA_PATH="$QA_FILE" python3 << 'PYEOF' > "$FINDINGS_FILE"
import json, re, os

findings = []

# ─── HALLUCINATION GUARD ───
# These patterns are NOT actionable findings. They are:
# 1. Summary/conclusion text from the audit report
# 2. WebFetch limitations (can't see HTTP headers, SSL, etc.)
# 3. Informational notes that don't require action

SKIP_LINE_PATTERNS = [
    r"^(Status:|The site demonstrates|Overall|Rationale:)",
    r"^(Note:|Recommend|Consider|Summary|Rating|Grade|Health)",
    r"^(No \w+ found|Cannot verify|Not confirmed|Not detected)",
    r"^(WebFetch|This method|Headers may exist)",
    r"^\*\*(Rationale|Note|Summary|Overall|Grade)",
    r"^The (main|primary|site|API|overall)",
    r"^(Addressing|These are|Given the|Everything is)",
    r"^(Result:|All .+ pages|All .+ load)",
]
SKIP_RE = re.compile("|".join(SKIP_LINE_PATTERNS), re.IGNORECASE)

FALSE_POSITIVE_PHRASES = [
    "not detected", "not confirmed", "cannot verify", "not visible",
    "mime-sniffing", "clickjacking", "legacy but still", "rationale:",
    "coming soon", "fully permissive", "/simulator", "/market-overview",
    "http 404", "no critical", "no high-severity", "no issues found",
    "everything is operational", "all pages are healthy",
    "overall health:", "suggests a recent restart",
    "borderline acceptable", "worth monitoring",
    "managed at cloudflare", "managed by cloudflare",
    "unverifiable via webfetch",
    "failures",  # "We don't hide failures" is not a finding
]

# Lines in Summary table that are purely informational, not actionable
INFO_SEVERITY_WORDS = ["info", "pass"]

def is_summary_table_row(line):
    """Detect markdown table rows like '| 1 | WARN | some finding |'"""
    return bool(re.match(r"^\|\s*\d+\s*\|", line.strip()))

def extract_table_finding(line):
    """Extract severity and text from summary table row."""
    parts = [p.strip() for p in line.strip().split("|") if p.strip()]
    if len(parts) >= 3:
        return parts[1].upper(), parts[2]
    return None, None

def parse_report(filepath, source):
    """Extract findings from markdown audit/QA report.

    CRITICAL RULES (anti-hallucination):
    1. Only lines with EXPLICIT severity markers (FAIL/WARN/❌/⚠️) are candidates
    2. "No issues found" is NEVER a finding
    3. Summary/conclusion paragraphs are NEVER findings
    4. INFO/PASS severity = skip (not actionable)
    5. Minimum 3 meaningful words in finding title
    6. Minimum 25 chars in finding title
    """
    if not filepath or not os.path.exists(filepath):
        return []

    with open(filepath) as f:
        content = f.read()

    results = []
    lines = content.split("\n")

    for i, line in enumerate(lines):
        stripped = line.strip()

        # ─── Basic filters ───
        if len(stripped) < 20:
            continue
        if stripped.startswith("|") and stripped.endswith("|") and not is_summary_table_row(stripped):
            continue  # Regular table row (not summary)
        if stripped.startswith("|-") or stripped.startswith("#") or stripped.startswith("---"):
            continue
        if stripped.startswith("*Auto-generated") or stripped.startswith("*If this"):
            continue

        # ─── Skip known non-finding patterns ───
        clean = re.sub(r"^\*\*", "", stripped)
        if SKIP_RE.match(clean):
            continue

        lower = stripped.lower()
        if any(fp in lower for fp in FALSE_POSITIVE_PHRASES):
            continue

        # ─── Determine severity ───
        severity = None
        finding_text = stripped

        # Check if this is a summary table row
        if is_summary_table_row(stripped):
            sev_str, text = extract_table_finding(stripped)
            if sev_str and text:
                if sev_str in ("INFO", "PASS"):
                    continue  # Not actionable
                elif sev_str in ("WARN", "WARNING"):
                    severity = "P2"
                elif sev_str in ("FAIL", "CRITICAL", "ERROR"):
                    severity = "P1"
                else:
                    continue  # Unknown severity — skip (prevents None label)
                finding_text = text
            else:
                continue
        else:
            # Non-table line: check for severity markers
            if "❌" in line or re.search(r"\bFAIL\b", line, re.IGNORECASE):
                # But NOT "Result: PASS" or "PASS — None found"
                if re.search(r"\bPASS\b", line, re.IGNORECASE):
                    continue
                severity = "P1"
            elif "⚠️" in line:
                severity = "P2"
            elif "🚨" in line or "P0" in line:
                severity = "P0"
            elif re.search(r"\bCRITICAL\b", line, re.IGNORECASE) and "no critical" not in lower:
                severity = "P1"
            elif "WARN" in line.upper():
                # STRICT: only if it's a standalone finding, not "Result: WARN"
                if re.match(r"^.*(Result|Status|Check):\s*WARN", stripped, re.IGNORECASE):
                    # This is a status line in a table, extract the actual finding
                    severity = "P2"
                elif "WARN" in line.upper() and "|" in line:
                    severity = "P2"
                else:
                    continue  # "WARN" in prose = skip
            else:
                continue  # No severity marker = not a finding

        # ─── Determine area ───
        area = "general"
        fl = finding_text.lower()
        if any(w in fl for w in ["security", "csp", "hsts", "xss", "injection", "ssl", "credential"]):
            area = "security"
        elif any(w in fl for w in ["performance", "latency", "slow", "timeout", "lcp", "cache"]):
            area = "performance"
        elif any(w in fl for w in ["data", "stale", "missing", "api", "endpoint", "market", "refresh"]):
            area = "data"
        elif any(w in fl for w in ["ux", "ui", "layout", "responsive", "mobile", "a11y"]):
            area = "ux"

        # ─── Clean title ───
        title = re.sub(r"[❌⚠️🚨✅📋🔴🟡🟢]+", "", finding_text).strip()
        title = re.sub(r"^[#\-*\s|0-9.]+", "", title).strip()
        title = re.sub(r"\*\*", "", title).strip()
        title = re.sub(r"^\s*\|\s*", "", title).strip()  # Remove leading pipe
        title = title[:120]

        # ─── STRICT quality gate ───
        # Must have 3+ meaningful words
        meaningful = [w for w in re.findall(r"\b[a-zA-Z]{3,}\b", title) if w.lower() not in
                      {"status", "fail", "pass", "warn", "error", "high", "medium", "low", "info",
                       "the", "and", "for", "not", "are", "was", "has", "but", "with", "this", "that",
                       "result", "check", "value", "field", "found", "none", "detected", "all"}]
        if len(meaningful) < 3:
            continue
        if len(title) < 25:
            continue

        # ─── FINAL anti-hallucination check ───
        # If the title basically says "everything is fine", skip it
        positive_indicators = ["pass", "healthy", "operational", "no issues", "no problems",
                               "working correctly", "all good", "intact", "normal"]
        if any(p in title.lower() for p in positive_indicators):
            continue

        # Get context
        context_lines = []
        for cl in lines[i+1:i+6]:
            cl_stripped = cl.strip()
            if cl_stripped and not cl_stripped.startswith("|") and not cl_stripped.startswith("#"):
                context_lines.append(cl_stripped)
            if len(context_lines) >= 3:
                break
        context = "\n".join(context_lines)[:500]

        results.append({
            "title": title,
            "severity": severity,
            "area": area,
            "context": context,
            "source": source,
        })

    return results

audit_path = os.environ.get("AUDIT_PATH", "")
qa_path = os.environ.get("QA_PATH", "")

findings.extend(parse_report(audit_path, "daily-audit"))
findings.extend(parse_report(qa_path, "deep-qa"))

# Deduplicate within current findings
seen = {}
for f in findings:
    key = f["title"].lower()[:50]
    if key not in seen or f["severity"] < seen[key]["severity"]:
        seen[key] = f

print(json.dumps(list(seen.values()), ensure_ascii=False, indent=2))

PYEOF

if [[ ! -s "$FINDINGS_FILE" ]]; then
    echo "$(date): No findings extracted" >> "$LOGFILE"
    exit 0
fi

finding_count=$(FF="$FINDINGS_FILE" python3 -c 'import json,os; print(len(json.load(open(os.environ["FF"]))))')
echo "$(date): Found $finding_count findings" >> "$LOGFILE"

if [[ "$finding_count" -eq 0 ]]; then
    alert_send "INFO" "audit-to-issue" "Audit clean — 0 findings" "code" 2>/dev/null
    exit 0
fi

# ─── Phase 2: Deduplicate against existing GitHub Issues ───
echo "$(date): Phase 2 — Deduplication" >> "$LOGFILE"

# Fetch existing open issues with claude-auto label
existing_issues=$(gh issue list --repo "$REPO" --label "claude-auto" --state open \
    --json number,title,createdAt --limit 50 2>/dev/null || echo "[]")

# Deduplicate: compare finding titles with existing issue titles
EXISTING_JSON="$existing_issues" FINDINGS_PATH="$FINDINGS_FILE" python3 << 'PYEOF' > "${FINDINGS_FILE}.deduped"
import json, os, re

existing = json.loads(os.environ.get("EXISTING_JSON", "[]"))
findings_path = os.environ["FINDINGS_PATH"]

with open(findings_path) as f:
    findings = json.load(f)

# Build keyword set for existing issues
existing_keywords = {}
for issue in existing:
    title = issue.get("title", "").lower()
    # Extract significant words (>3 chars)
    words = set(re.findall(r"\b\w{4,}\b", title))
    existing_keywords[issue["number"]] = {"title": title, "words": words}

new_findings = []
duplicate_findings = []

for finding in findings:
    title_lower = finding["title"].lower()
    finding_words = set(re.findall(r"\b\w{4,}\b", title_lower))

    is_dup = False
    dup_issue = None

    for issue_num, info in existing_keywords.items():
        if not finding_words or not info["words"]:
            continue
        # Calculate word overlap
        overlap = len(finding_words & info["words"])
        max_possible = min(len(finding_words), len(info["words"]))
        if max_possible > 0 and overlap / max_possible >= 0.6:
            is_dup = True
            dup_issue = issue_num
            break

    if is_dup:
        finding["dup_issue"] = dup_issue
        duplicate_findings.append(finding)
    else:
        new_findings.append(finding)

result = {"new": new_findings, "duplicates": duplicate_findings}
print(json.dumps(result, ensure_ascii=False, indent=2))
PYEOF

new_count=$(FF="${FINDINGS_FILE}.deduped" python3 -c 'import json,os; print(len(json.load(open(os.environ["FF"]))["new"]))')
dup_count=$(FF="${FINDINGS_FILE}.deduped" python3 -c 'import json,os; print(len(json.load(open(os.environ["FF"]))["duplicates"]))')
echo "$(date): New: $new_count, Duplicates: $dup_count" >> "$LOGFILE"

# ─── Phase 3: Create new issues (max 5/run) ───
echo "$(date): Phase 3 — Issue creation" >> "$LOGFILE"

created=0
DEDUPED_FILE="${FINDINGS_FILE}.deduped"

while IFS= read -r finding_json; do
    [[ $created -ge $MAX_NEW_ISSUES ]] && break

    title=$(echo "$finding_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['area']} {d['severity']}: {d['title']}\")")
    body=$(echo "$finding_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'''## Finding
{d['title']}

## Context
{d.get('context', 'No additional context')}

## Metadata
- **Severity**: {d['severity']}
- **Area**: {d['area']}
- **Source**: {d['source']}
- **Date**: $(date +%Y-%m-%d)

---
*Auto-generated by audit-to-issue (JEPO Autopilot v0.2.0)*''')
")
    severity=$(echo "$finding_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['severity'])")
    area=$(echo "$finding_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['area'])")

    # Guard: skip if severity or area is "None" (Python null printed as string)
    if [[ "$severity" == "None" || -z "$severity" || "$area" == "None" ]]; then
        echo "$(date): Skipping finding with null severity/area: $title" >> "$LOGFILE"
        continue
    fi
    result=$(create_issue_safe "$REPO" "$title" "$body" "claude-auto,$severity,$area,needs-review" 2>&1) && rc=$? || rc=$?
    if [[ $rc -eq 0 && "$result" != "RATE_LIMITED" && "$result" != "FAILED"* ]]; then
        created=$((created + 1))
        rate_increment "audit-to-issue" "github"
        echo "$(date): Created issue: $title → $result" >> "$LOGFILE"
    else
        echo "$(date): Failed to create issue: $title ($result)" >> "$LOGFILE"
        break
    fi
done < <(DEDUPED_PATH="$DEDUPED_FILE" python3 -c "
import json, os
with open(os.environ['DEDUPED_PATH']) as f:
    data = json.load(f)
for finding in data['new']:
    print(json.dumps(finding))
")

# ─── Phase 4: Update duplicate issues ───
echo "$(date): Phase 4 — Update duplicates" >> "$LOGFILE"

updated=0
while IFS= read -r dup_json; do
    [[ $updated -ge $MAX_COMMENTS ]] && break

    issue_num=$(echo "$dup_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['dup_issue'])")
    title=$(echo "$dup_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")

    comment="Re-occurrence detected ($(date +%Y-%m-%d))

Finding: $title
Source: audit-to-issue automatic scan

*If this recurs 3+ times, consider escalating priority.*"

    gh issue comment "$issue_num" --repo "$REPO" --body "$comment" 2>> "$LOGFILE" && {
        updated=$((updated + 1))
        echo "$(date): Updated issue #$issue_num with re-occurrence" >> "$LOGFILE"
    } || true
done < <(DEDUPED_PATH="$DEDUPED_FILE" python3 -c "
import json, os
with open(os.environ['DEDUPED_PATH']) as f:
    data = json.load(f)
for dup in data['duplicates']:
    print(json.dumps(dup))
")

# ─── Phase 5: Report ───
echo "$(date): Phase 5 — Report" >> "$LOGFILE"

report_file="$RESULTS_DIR/audit-to-issue-${TODAY}.json"
atomic_write "$report_file" "{
  \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"findings_total\": $finding_count,
  \"new_issues_created\": $created,
  \"duplicates_updated\": $updated,
  \"duplicates_skipped\": $dup_count
}"

summary="📋 Audit→Issues: ${created} new, ${updated} updated, ${dup_count} deduped (of ${finding_count} total)"
if [[ $created -gt 0 ]]; then
    alert_send "INFO" "audit-to-issue" "$summary" "code" 2>/dev/null
else
    send_telegram_structured "INFO" "audit-to-issue" "$summary" 2>/dev/null
fi

echo "$(date): audit-to-issue complete — $created new, $updated updated" >> "$LOGFILE"

rm -f "$FINDINGS_FILE" "${FINDINGS_FILE}.deduped"
