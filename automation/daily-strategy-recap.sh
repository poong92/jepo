#!/bin/bash
# PRUVIQ Daily Strategy Ranking Post — Content Type B
# Runs daily at UTC 01:00 (KST 10:00)
# Fetches /rankings/daily → Python template → Claude 1-line hook → quality check → queue
#
# Architecture: API data → deterministic template (no hallucination) + minimal Claude hook
# Schedule: LaunchAgent daily at 01:00 UTC

source "$(dirname "$0")/claude-runner.sh"
[[ -f "$HOME/scripts/pruviq-lib.sh" ]] && source "$HOME/scripts/pruviq-lib.sh"
acquire_lock "daily-strategy-recap"

LOGFILE="$LOG_DIR/daily-strategy-recap.log"
QUEUE_DIR="$HOME/scripts/social/queue"
DATA_DIR="$HOME/scripts/social/data"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON3="${HOME}/pruviq/backend/.venv/bin/python3"
API_BASE="https://api.pruviq.com"

rotate_log "$LOGFILE"
mkdir -p "$QUEUE_DIR" "$DATA_DIR"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ): $1" >> "$LOGFILE"; }
log "=== Daily Strategy Recap started ==="

if ! check_auth; then
    log "Auth failed"
    exit 1
fi

# ── 0. Load market context (from daily-market-digest if available) ──
MARKET_SUMMARY=""
MARKET_FILE="$DATA_DIR/daily_digest_$(date -u +%Y%m%d).json"
if [[ -f "$MARKET_FILE" ]]; then
    MARKET_SUMMARY=$($PYTHON3 -c "
import json, sys
try:
    d = json.load(open('$MARKET_FILE'))
    p = d.get('prices', {})
    btc = p.get('BTCUSDT', {})
    change = btc.get('change_24h', 0)
    price = btc.get('price', 0)
    fg = d.get('fear_greed', {}).get('value', 0)
    fg_label = d.get('fear_greed', {}).get('label', '')
    liq = d.get('liquidations', {}).get('total_usd', 0)
    parts = []
    if price:
        parts.append(f'BTC \${price:,.0f} ({change:+.1f}% 24h)')
    if fg_label:
        parts.append(f'F&G {fg} ({fg_label})')
    if liq > 0:
        parts.append(f'Liquidations \${liq/1e6:.0f}M')
    print(', '.join(parts))
except:
    print('')
" 2>/dev/null || echo "")
    [[ -n "$MARKET_SUMMARY" ]] && log "Market context: $MARKET_SUMMARY"
fi

# ── 1. Fetch /rankings/daily ──────────────────────────────────
log "Fetching rankings..."
RANKING_JSON=$(curl -sf --max-time 15 "$API_BASE/rankings/daily?period=30d&group=top30" 2>/dev/null || echo "")

if [[ -z "$RANKING_JSON" ]]; then
    log "ERROR: API call failed"
    send_telegram_structured "ERROR" "daily-strategy-recap" "rankings/daily API failed"
    exit 1
fi

# Validate required fields
API_OK=$(echo "$RANKING_JSON" | $PYTHON3 -c "
import sys, json
d = json.load(sys.stdin)
ok = bool(d.get('date') and isinstance(d.get('top3'), list) and len(d.get('top3', [])) > 0)
print('yes' if ok else 'no')
" 2>/dev/null || echo "no")

if [[ "$API_OK" != "yes" ]]; then
    log "ERROR: API returned invalid structure"
    send_telegram_structured "ERROR" "daily-strategy-recap" "rankings/daily invalid response"
    exit 1
fi

# Freshness check: warn if data is more than 2 days old
DATA_AGE=$(echo "$RANKING_JSON" | $PYTHON3 -c "
import sys, json
from datetime import datetime, timezone
d = json.load(sys.stdin)
date_str = d.get('date', '')
try:
    data_date = datetime.strptime(date_str, '%Y-%m-%d').replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    age_days = (now - data_date).days
    print(age_days)
except:
    print(99)
" 2>/dev/null || echo "99")

if [[ "$DATA_AGE" -gt 2 ]]; then
    log "WARN: Ranking data is ${DATA_AGE} days old — skipping post"
    exit 0
fi

echo "$RANKING_JSON" > "$DATA_DIR/daily_ranking_$(date -u +%Y%m%d).json"
log "Rankings fetched (data age: ${DATA_AGE}d)"

# ── 2. Build structured context for Claude hook ───────────────
RANKING_CONTEXT=$(echo "$RANKING_JSON" | MARKET_SUMMARY="$MARKET_SUMMARY" $PYTHON3 -c "
import json, sys, os

d = json.load(sys.stdin)

def fmt_streak(e):
    streak = e.get('streak')
    if streak and streak >= 2:
        return f' {streak}d streak'
    return ''

def fmt_rank_change(e):
    rc = e.get('rank_change')
    if rc is None:
        return ''
    if rc > 0:
        return f' ↑{rc}'
    if rc < 0:
        return f' ↓{abs(rc)}'
    return ' →'

def fmt_entry(e, lang='en'):
    name = e['name_en'] if lang == 'en' else e['name_ko']
    pf = e['profit_factor']
    wr = e['win_rate']
    trades = e['total_trades']
    low = e.get('low_sample', False)
    sample_note = f' ({trades} trades — low sample)' if low else f' ({trades} trades)'
    streak_note = fmt_streak(e)
    rc_note = fmt_rank_change(e)
    return f'{name}: PF {pf}, WR {wr}%{sample_note}{streak_note}{rc_note}'

top3 = d.get('top3', [])
worst3 = d.get('worst3', [])
summary = d.get('summary', {})
low_count = d.get('low_sample_count', 0)
total = summary.get('total', 0)
wr50 = summary.get('wr_50plus', 0)
date = d.get('date', '')

mkt = os.environ.get('MARKET_SUMMARY', '').strip()
lines = [f'Date: {date}', f'Total strategies: {total} | WR 50%+: {wr50} | Low-sample: {low_count}']
if mkt:
    lines.append(f'Market context: {mkt}')
lines.append('')
lines.append('TOP 3 (by PF):')
for e in top3:
    lines.append('  ' + fmt_entry(e))
lines.append('')
lines.append('WORST 3:')
for e in worst3:
    lines.append('  ' + fmt_entry(e))

# Analysis hints
best_pf = top3[0]['profit_factor'] if top3 else 0
best_trades = top3[0]['total_trades'] if top3 else 0
best_low = top3[0].get('low_sample', True) if top3 else True
best_streak = top3[0].get('streak', 1) if top3 else 1
worst_pf = worst3[0]['profit_factor'] if worst3 else 1

# Find most reliable strategy (>= 30 trades) for hook when top is low-sample
reliable = next((e for e in top3 if not e.get('low_sample', True)), None)

if best_pf >= 3.0 and not best_low:
    streak_hint = f' ({best_streak}d streak)' if best_streak >= 2 else ''
    lines.append(f'Tone: Strong day — top strategy PF {best_pf} with solid sample{streak_hint}')
elif best_pf >= 1.5:
    if best_low:
        if reliable:
            r_name = reliable.get('name_en', '')
            r_pf = reliable.get('profit_factor', 0)
            r_wr = reliable.get('win_rate', 0)
            r_trades = reliable.get('total_trades', 0)
            lines.append(f'Tone: Top is low-sample ({best_trades} trades). Feature reliable strategy: {r_name} PF {r_pf}, WR {r_wr}% ({r_trades} trades)')
            lines.append(f'IMPORTANT: Do NOT lead with the low-sample #1 strategy. Lead with {r_name} instead.')
        else:
            lines.append(f'Tone: Low-sample day (best has {best_trades} trades). Mention data sparsity.')
    else:
        lines.append(f'Tone: Solid day — PF {best_pf}')
elif best_pf < 1.0:
    lines.append('Tone: Tough day — even best strategy PF < 1.0')

print('\n'.join(lines))
" 2>/dev/null)

log "Context built"

# ── 3. Generate 1-line Claude hook (EN + KO) ─────────────────
HOOK_EN=$(claude --model "$MODEL_SONNET" -p "You are a quant analyst writing a hook line for a crypto strategy ranking post.

$RANKING_CONTEXT

Write ONE sentence (max 65 chars) that leads with market context or strategy contrast — NOT the PF number alone.

Priority (highest engagement first):
1. Market context: connect today's market move to strategy performance
2. Contrast: highlight the gap between best and worst strategies
3. Streak: note if top strategy is on a multi-day run
4. Win rate: use WR if more intuitive than PF for the move

Rules:
- Max 65 chars
- Lead with market condition OR stark contrast — not 'PF X.X leads'
- If market data available, prefer market-context angle
- NEVER lead with a strategy that has low_sample / fewer than 30 trades — it misleads readers
- If reliable strategy context is given, feature THAT strategy in the hook
- No 'Today', no 'Let\'s', no fluff
- English only
- Example formats:
  'BTC dipped 2% — this SHORT strategy won 7 of 8 trades.'
  'ADX crushed it: PF 3.5 while BB Squeeze hit 0.18 floor.'
  'Bear day: even the best strategy only managed PF 1.2.'
  'RSI Divergence 4H: 3rd straight day on top. 88% WR.'

Output ONLY the sentence. No quotes." \
    --allowedTools "Read" --max-turns 1 2>/dev/null | head -c 100 | tr -d '\n')

HOOK_KO=$(claude --model "$MODEL_SONNET" -p "퀀트 애널리스트. 오늘 전략 랭킹 데이터의 핵심 한 문장 (최대 40자).

$RANKING_CONTEXT

우선순위 (참여도 높은 순):
1. 시장 맥락 연결 — BTC 움직임과 전략 성과 연결
2. 전략 간 대조 — 1위와 꼴찌의 극명한 차이
3. 연속성 — 연속 N일 1위라면 언급
4. 승률 — PF보다 승률이 더 직관적일 때 사용

규칙:
- 최대 40자
- 'PF X.X가 1위' 식으로 시작하지 말 것 → 맥락/대조로 시작
- 시장 데이터 있으면 시장 맥락 우선
- low_sample이면 간단히 언급
- 자연스러운 한국어 (AI 느낌, 번역 느낌 금지)
- 예시:
  'BTC 하락장에서 SHORT 전략이 88% 적중.'
  'ADX 4H PF 3.5 vs BB Squeeze PF 0.18 — 양극단.'
  'RSI 다이버전스 3일 연속 1위. 단 8건이지만.'
- 텍스트만 출력" \
    --allowedTools "Read" --max-turns 1 2>/dev/null | head -c 120 | tr -d '\n')

# Fallback if Claude fails
[[ -z "$HOOK_EN" || ${#HOOK_EN} -lt 5 ]] && HOOK_EN=""
[[ -z "$HOOK_KO" || ${#HOOK_KO} -lt 5 ]] && HOOK_KO=""

log "Hooks generated (EN: ${#HOOK_EN}c, KO: ${#HOOK_KO}c)"

# ── 4. Build final content via Python template ────────────────
CONTENTS=$(echo "$RANKING_JSON" | HOOK_EN="$HOOK_EN" HOOK_KO="$HOOK_KO" MARKET_SUMMARY="$MARKET_SUMMARY" $PYTHON3 -c "
import json, sys, os

d = json.load(sys.stdin)
hook_en = os.environ.get('HOOK_EN', '').strip()
hook_ko = os.environ.get('HOOK_KO', '').strip()
market_summary = os.environ.get('MARKET_SUMMARY', '').strip()

top3 = d.get('top3', [])
worst3 = d.get('worst3', [])
summary = d.get('summary', {})
low_count = d.get('low_sample_count', 0)
total = summary.get('total', 0)
wr50 = summary.get('wr_50plus', 0)

# date display
date_str = d.get('date', '')
try:
    from datetime import datetime
    dt = datetime.strptime(date_str, '%Y-%m-%d')
    date_en = dt.strftime("%b") + " " + str(dt.day)
    date_ko = str(dt.month) + "/" + str(dt.day)
except:
    date_en = date_str
    date_ko = date_str

def sample_note_en(e):
    t = e['total_trades']
    return f' ⚠{t}t' if e.get('low_sample') else f' {t}t'

def sample_note_ko(e):
    t = e['total_trades']
    return f' ⚠{t}건' if e.get('low_sample') else f' {t}건'

def streak_note_en(e):
    s = e.get('streak')
    return f' 🔥{s}d' if (s and s >= 2) else ''

def streak_note_ko(e):
    s = e.get('streak')
    return f' 🔥{s}일째' if (s and s >= 2) else ''

def rank_change_note_en(e):
    rc = e.get('rank_change')
    if rc is None:
        return ''
    if rc > 0:
        return f' ↑{rc}'
    if rc < 0:
        return f' ↓{abs(rc)}'
    return ''

def rank_change_note_ko(e):
    rc = e.get('rank_change')
    if rc is None:
        return ''
    if rc > 0:
        return f' ↑{rc}'
    if rc < 0:
        return f' ↓{abs(rc)}'
    return ''

def wr_int(e):
    return int(round(e['win_rate']))

# ─── X (English) — strict 280 char limit ─────────────────────
# Top 3 only, no Worst, no trade counts — hook to drive traffic
x_lines = []
if hook_en:
    x_lines.append(hook_en)
x_lines.append(f'📊 {date_en} Rankings')

rank_emojis = ['🥇', '🥈', '🥉']
for i, e in enumerate(top3[:3]):
    em = rank_emojis[i]
    name = e['name_en']
    pf = e['profit_factor']
    wr = wr_int(e)
    streak = streak_note_en(e)
    rc = rank_change_note_en(e)
    x_lines.append(f'{em} {name}  PF {pf} | WR {wr}%{streak}{rc}')

x_lines.append(f'{wr50}/{total} strats WR≥50%')
# CTA rotation: odd day → rankings, even day → simulate (KST)
import datetime as _dt
_kst = _dt.timezone(_dt.timedelta(hours=9))
_day = _dt.datetime.now(_kst).day
x_cta = 'pruviq.com/simulate' if _day % 2 == 0 else 'pruviq.com/rankings'
x_lines.append(x_cta)
x_lines.append('Simulated backtest. Not financial advice.')

# Auto-trim hook if body exceeds 278 chars (excl. disclaimer, 2-char safety buffer)
DISCLAIMER = 'Simulated backtest. Not financial advice.'
X_LIMIT = 235  # body only — disclaimer(~42자) 포함 시 277자 ≤ Twitter 280자 제한
has_hook = bool(hook_en) and x_lines and x_lines[0] == hook_en
while has_hook:
    body_lines = [l for l in x_lines if l.strip() != DISCLAIMER]
    body = '\n'.join(body_lines)
    if len(body) <= X_LIMIT:
        break
    if len(hook_en) <= 10:
        x_lines = x_lines[1:]  # Remove hook entirely
        hook_en = ''
        break
    hook_en = hook_en[:-5].rstrip(' .,—') + '…'
    x_lines[0] = hook_en

x_content = '\n'.join(x_lines)

# ─── Threads (Korean) ────────────────────────────────────────
# Top 3만, Worst 없음, 거래건수 없음 — 유입 훅
th_lines = []
if hook_ko:
    th_lines.append(hook_ko)
th_lines.append(f'📊 {date_ko} 전략 랭킹')
th_lines.append('')
th_lines.append('🏆 오늘의 Top 3')
rank_emojis_ko = ['🥇', '🥈', '🥉']
for i, e in enumerate(top3[:3]):
    em = rank_emojis_ko[i]
    name = e['name_ko']
    pf = e['profit_factor']
    wr = e['win_rate']
    streak = streak_note_ko(e)
    rc = rank_change_note_ko(e)
    th_lines.append(f'{em} {name}  PF {pf} | 승률 {wr}%{streak}{rc}')

th_lines.append('')
th_lines.append(f'승률 50%+ 전략: {wr50}/{total}개')
th_lines.append('시뮬레이션 백테스트 · 과거 성과 ≠ 미래 수익 · 투자 조언 아님')
th_lines.append('pruviq.com/strategies/ranking')

th_content = '\n'.join(th_lines)

import json as _json
print(_json.dumps({'x': x_content, 'threads': th_content}))
" 2>/dev/null)

if [[ -z "$CONTENTS" ]]; then
    log "ERROR: Content generation failed"
    exit 1
fi

X_CONTENT=$(echo "$CONTENTS" | $PYTHON3 -c "import sys,json; print(json.load(sys.stdin).get('x',''))" 2>/dev/null)
THREADS_CONTENT=$(echo "$CONTENTS" | $PYTHON3 -c "import sys,json; print(json.load(sys.stdin).get('threads',''))" 2>/dev/null)

log "X (${#X_CONTENT}c): ${X_CONTENT:0:80}..."
log "Threads (${#THREADS_CONTENT}c)"

# ── 5. Quality check + queue ──────────────────────────────────
queue_content() {
    local platform="$1"
    local content="$2"

    if [[ -z "$content" || ${#content} -lt 15 ]]; then
        log "$platform: Content too short, skipping"
        return 1
    fi

    # Run quality checker
    local qc_input qc_result score action issues
    qc_input=$(echo "$content" | $PYTHON3 -c "
import json, sys
data = {'platform': '$platform', 'content': sys.stdin.read().strip()}
print(json.dumps(data, ensure_ascii=False))
" 2>/dev/null)

    qc_result=$(echo "$qc_input" | $PYTHON3 "$SCRIPT_DIR/quality-checker.py" 2>/dev/null)
    score=$(echo "$qc_result" | $PYTHON3 -c "import sys,json; print(json.load(sys.stdin).get('score',0))" 2>/dev/null || echo "0")
    action=$(echo "$qc_result" | $PYTHON3 -c "import sys,json; print(json.load(sys.stdin).get('action','discard'))" 2>/dev/null || echo "discard")
    issues=$(echo "$qc_result" | $PYTHON3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('issues',[])))" 2>/dev/null || echo "")

    log "$platform: score=$score action=$action${issues:+ issues=[$issues]}"

    if [[ "$action" == "needs_approval" ]]; then
        local ts
        ts=$(date -u +%Y%m%dT%H%M%S)
        local queue_file="$QUEUE_DIR/${ts}-strategy-${platform}.json"

        echo "$content" | $PYTHON3 -c "
import json, sys
content = sys.stdin.read().strip()
data = {
    'platform': '$platform',
    'content': content,
    'category': 'strategy_ranking',
    'generated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'status': 'pending_approval',
    'qc_score': $score,
}
with open('$queue_file', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
"
        # Telegram 승인 요청 — 인라인 버튼 (✅ 포스팅 / ❌ 삭제)
        local preview platform_upper tg_msg queue_basename
        preview=$(echo "$content" | head -c 500)
        platform_upper=$(echo "$platform" | tr '[:lower:]' '[:upper:]')
        queue_basename=$(basename "$queue_file")
        tg_msg="<b>[📊 SNS 승인 요청]</b> ${platform_upper} (score=${score})

${preview}"
        local APPROVAL_TOKEN="${TELEGRAM_APPROVAL_BOT_TOKEN:-$TELEGRAM_BOT_TOKEN}"
        local CHAT_ID="${TELEGRAM_CHAT_ID:-}"
        if [[ -n "$APPROVAL_TOKEN" && -n "$CHAT_ID" ]]; then
            curl -s --max-time 15 -X POST "https://api.telegram.org/bot${APPROVAL_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" \
                -d parse_mode="HTML" \
                --data-urlencode "text=$tg_msg" \
                --data-urlencode "reply_markup={\"inline_keyboard\":[[{\"text\":\"✅ 포스팅\",\"callback_data\":\"approve:${queue_basename}\"},{\"text\":\"❌ 삭제\",\"callback_data\":\"reject:${queue_basename}\"}]]}" \
                >/dev/null 2>&1 || true
        fi
        return 0
    else
        log "$platform: DISCARDED (score=$score): $issues"
        send_telegram_approval "🗑 <b>[Strategy Recap 품질미달]</b> ${platform^^} (${score}): $issues"
        return 1
    fi
}

queue_content "x" "$X_CONTENT" || true
queue_content "threads" "$THREADS_CONTENT" || true

log "=== Daily Strategy Recap complete ==="
