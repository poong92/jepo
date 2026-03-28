#!/bin/bash
# PRUVIQ SEO Monitor
# Part of JEPO Autopilot Phase 3 — automated SEO health monitoring.
#
# Checks:
#   - Page response codes and load times
#   - Meta tags (title, description, OG tags)
#   - Sitemap.xml freshness and validity
#   - robots.txt accessibility
#   - Structured data (Schema.org)
#   - hreflang tags (i18n)
#   - Favicon compliance (>= 48x48)
#   - www redirect (301)
#   - Canonical URLs
#
# No Claude needed — pure programmatic checks (zero token cost).
#
# Schedule: every 12 hours via LaunchAgent
# Output: ~/logs/claude-auto/results/seo-report-YYYY-MM-DD.json

source "$(dirname "$0")/claude-runner.sh"
acquire_lock "seo-monitor"

LOGFILE="$LOG_DIR/seo-monitor.log"
REPORT_DIR="$RESULTS_DIR"
SITE="https://pruviq.com"
API="https://api.pruviq.com"

rotate_log "$LOGFILE"

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ): $1" >> "$LOGFILE"
}

log "=== SEO Monitor started ==="

# ─────────────────────────────────────────────────────────────
# Core SEO check via Python (comprehensive, no external deps)
# ─────────────────────────────────────────────────────────────

REPORT_FILE="$REPORT_DIR/seo-report-$(date +%Y-%m-%d).json"
export REPORT_FILE

python3 << 'PYEOF'
import json, urllib.request, urllib.error, time, re, sys, os

SITE = "https://pruviq.com"
API = "https://api.pruviq.com"
REPORT_FILE = os.environ.get("REPORT_FILE", "/tmp/seo-report.json")

results = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "checks": [], "score": 0, "issues": []}
total = 0
passed = 0

def check(name, ok, detail=""):
    global total, passed
    total += 1
    if ok:
        passed += 1
    results["checks"].append({"name": name, "pass": ok, "detail": detail})
    if not ok:
        results["issues"].append({"name": name, "detail": detail})

def fetch(url, timeout=10):
    """Fetch URL and return (status_code, body, response_time_ms, headers)."""
    try:
        start = time.time()
        req = urllib.request.Request(url, headers={"User-Agent": "PRUVIQ-SEO-Monitor/1.0"})
        resp = urllib.request.urlopen(req, timeout=timeout)
        body = resp.read().decode("utf-8", errors="replace")
        elapsed = int((time.time() - start) * 1000)
        return resp.status, body, elapsed, dict(resp.headers)
    except urllib.error.HTTPError as e:
        elapsed = int((time.time() - start) * 1000)
        return e.code, "", elapsed, {}
    except Exception as e:
        return 0, "", 0, {}

# ── 1. Key Pages — response codes + load time ──
PAGES = [
    "/", "/ko/", "/simulate", "/ko/simulate",
    "/strategies", "/ko/strategies", "/performance", "/ko/performance",
    "/market", "/coins", "/fees", "/learn",
]

slow_pages = []
for path in PAGES:
    url = f"{SITE}{path}"
    code, body, ms, headers = fetch(url)
    check(f"page:{path} status", code == 200, f"HTTP {code}, {ms}ms")
    if ms > 3000:
        slow_pages.append(f"{path} ({ms}ms)")

if slow_pages:
    check("page:load_time", False, f"Slow pages: {', '.join(slow_pages)}")
else:
    check("page:load_time", True, "All pages < 3s")

# ── 2. Meta tags on homepage ──
code, body, ms, headers = fetch(f"{SITE}/")
if code == 200:
    # Title
    title_match = re.search(r"<title>(.+?)</title>", body)
    title = title_match.group(1) if title_match else ""
    check("meta:title_exists", len(title) > 0, title[:80])
    check("meta:title_length", 30 <= len(title) <= 70, f"{len(title)} chars")

    # Description
    desc_match = re.search(r'<meta\s+name="description"\s+content="(.+?)"', body)
    desc = desc_match.group(1) if desc_match else ""
    check("meta:description_exists", len(desc) > 0, desc[:100])
    check("meta:description_length", 50 <= len(desc) <= 160, f"{len(desc)} chars")

    # OG tags
    og_title = re.search(r'property="og:title"', body)
    og_desc = re.search(r'property="og:description"', body)
    og_image = re.search(r'property="og:image"', body)
    check("meta:og_title", og_title is not None)
    check("meta:og_description", og_desc is not None)
    check("meta:og_image", og_image is not None)

    # Viewport
    viewport = re.search(r'<meta\s+name="viewport"', body)
    check("meta:viewport", viewport is not None)

    # Canonical
    canonical = re.search(r'<link\s+rel="canonical"', body)
    check("meta:canonical", canonical is not None)

    # H1
    h1 = re.search(r"<h1[^>]*>", body)
    check("meta:h1_exists", h1 is not None)

    # hreflang
    hreflang_en = re.search(r'hreflang="en"', body)
    hreflang_ko = re.search(r'hreflang="ko"', body)
    check("i18n:hreflang_en", hreflang_en is not None)
    check("i18n:hreflang_ko", hreflang_ko is not None)

    # Favicon >= 48x48
    favicon_48 = re.search(r'sizes="48x48"', body) or re.search(r'sizes="96x96"', body)
    check("favicon:size_48plus", favicon_48 is not None, ">= 48x48 for Google")

    # Schema.org structured data
    schema = re.search(r'"@type"\s*:\s*"(Organization|WebApplication|FAQPage)', body)
    check("structured:schema_org", schema is not None, schema.group(1) if schema else "not found")

# ── 3. Korean homepage meta ──
code_ko, body_ko, ms_ko, _ = fetch(f"{SITE}/ko/")
if code_ko == 200:
    title_ko = re.search(r"<title>(.+?)</title>", body_ko)
    title_ko_text = title_ko.group(1) if title_ko else ""
    has_korean = bool(re.search(r"[\uac00-\ud7af]", title_ko_text))
    check("i18n:ko_title_korean", has_korean, title_ko_text[:60])

# ── 4. Sitemap ──
code_sm, body_sm, ms_sm, _ = fetch(f"{SITE}/sitemap-index.xml")
if code_sm != 200:
    code_sm, body_sm, ms_sm, _ = fetch(f"{SITE}/sitemap.xml")
check("sitemap:accessible", code_sm == 200, f"HTTP {code_sm}")
if code_sm == 200:
    url_count = body_sm.count("<loc>")
    check("sitemap:has_urls", url_count >= 1, f"{url_count} URLs/sitemaps")
    lastmod = re.findall(r"<lastmod>(.+?)</lastmod>", body_sm)
    if lastmod:
        latest = max(lastmod)
        check("sitemap:fresh", latest >= time.strftime("%Y-%m", time.gmtime()), f"Last: {latest}")

# ── 5. robots.txt ──
code_rb, body_rb, ms_rb, _ = fetch(f"{SITE}/robots.txt")
check("robots:accessible", code_rb == 200, f"HTTP {code_rb}")
if code_rb == 200:
    has_sitemap = "Sitemap:" in body_rb
    check("robots:has_sitemap_ref", has_sitemap)

# ── 6. www redirect ──
try:
    req = urllib.request.Request(f"https://www.pruviq.com/", headers={"User-Agent": "PRUVIQ-SEO-Monitor/1.0"})
    resp = urllib.request.urlopen(req, timeout=10)
    final_url = resp.url
    check("redirect:www_to_apex", "www." not in final_url, f"Final: {final_url}")
except Exception as e:
    check("redirect:www_to_apex", False, str(e)[:100])

# ── 7. API health ──
code_api, body_api, ms_api, _ = fetch(f"{API}/health")
check("api:health", code_api == 200, f"HTTP {code_api}, {ms_api}ms")

# ── 8. Favicon.ico ──
try:
    req = urllib.request.Request(f"{SITE}/favicon.ico", headers={"User-Agent": "PRUVIQ-SEO-Monitor/1.0"})
    resp = urllib.request.urlopen(req, timeout=10)
    favicon_data = resp.read()
    check("favicon:ico_accessible", len(favicon_data) > 100, f"{len(favicon_data)} bytes")
except Exception:
    check("favicon:ico_accessible", False)

# ── Score ──
results["score"] = round((passed / total * 100)) if total > 0 else 0
results["total_checks"] = total
results["passed"] = passed
results["failed"] = total - passed

# ── Write report ──
with open(REPORT_FILE, "w") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)

print(json.dumps({"score": results["score"], "passed": passed, "total": total, "issues": len(results["issues"])}))
PYEOF

SCORE=$(python3 -c "import json; r=json.load(open('$REPORT_FILE')); print(r['score'])" 2>/dev/null || echo "0")
ISSUES=$(python3 -c "import json; r=json.load(open('$REPORT_FILE')); print(len(r.get('issues',[])))" 2>/dev/null || echo "0")

log "SEO Score: $SCORE/100, Issues: $ISSUES"
log "Report: $REPORT_FILE"

# ── Alert if score drops below threshold ──
if [[ "$SCORE" -lt 80 ]]; then
    send_telegram_structured "WARNING" "seo-monitor" "SEO Score: $SCORE/100 ($ISSUES issues)" \
        "Report: $REPORT_FILE"
    log "WARNING: SEO score below threshold ($SCORE < 80)"
elif [[ "$SCORE" -lt 95 ]]; then
    log "INFO: SEO score $SCORE/100 — minor issues detected"
else
    log "OK: SEO score $SCORE/100 — all checks passed"
fi

log "=== SEO Monitor completed ==="
