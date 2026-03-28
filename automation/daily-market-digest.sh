#!/bin/bash
# PRUVIQ Daily Market Digest — Content Type A
# Runs daily at UTC 00:30, summarizes the day's most important crypto events
#
# Flow: collect data → Claude summary → quality check → Telegram approval → 3-platform post
# Schedule: LaunchAgent daily

source "$(dirname "$0")/claude-runner.sh"
[[ -f "$HOME/scripts/pruviq-lib.sh" ]] && source "$HOME/scripts/pruviq-lib.sh"
acquire_lock "daily-market-digest"

LOGFILE="$LOG_DIR/daily-market-digest.log"
QUEUE_DIR="$HOME/scripts/social/queue"
DATA_DIR="$HOME/scripts/social/data"
CHART_DIR="$HOME/scripts/social/charts"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON3="${HOME}/pruviq/backend/.venv/bin/python3"

rotate_log "$LOGFILE"
mkdir -p "$QUEUE_DIR" "$DATA_DIR" "$CHART_DIR"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ): $1" >> "$LOGFILE"; }
log "=== Daily Market Digest started ==="

if ! check_auth; then
    log "Auth failed, aborting"
    exit 1
fi

# ── 1. Collect Market Data ──
log "Collecting market data..."
MARKET_DATA=$($PYTHON3 "$SCRIPT_DIR/collect-market-data.py" 2>/dev/null)

if [[ -z "$MARKET_DATA" || "$MARKET_DATA" == "null" ]]; then
    log "Market data collection failed"
    send_telegram_structured "ERROR" "daily-digest" "Market data collection failed"
    exit 1
fi

echo "$MARKET_DATA" > "$DATA_DIR/daily_digest_$(date -u +%Y%m%d).json"

# ── 2. Build comprehensive market context ──
MARKET_CONTEXT=$($PYTHON3 -c "
import json, sys

data = json.loads(sys.stdin.read())
lines = []

p = data.get('prices', {})
btc = p.get('BTCUSDT', {})
eth = p.get('ETHUSDT', {})
sol = p.get('SOLUSDT', {})

lines.append('=== PRICES ===')
lines.append(f\"BTC: \${btc.get('price',0):,.0f} ({btc.get('change_24h',0):+.1f}% 24h) | H: \${btc.get('high_24h',0):,.0f} L: \${btc.get('low_24h',0):,.0f}\")
lines.append(f\"ETH: \${eth.get('price',0):,.0f} ({eth.get('change_24h',0):+.1f}%)\")
if sol.get('price'):
    lines.append(f\"SOL: \${sol.get('price',0):,.1f} ({sol.get('change_24h',0):+.1f}%)\")

f = data.get('funding', {})
if '_error' not in f:
    lines.append('')
    lines.append('=== DERIVATIVES ===')
    lines.append(f\"Funding Avg: {f.get('average',0):+.4f}%\")
    lines.append(f\"Extreme Long: {f.get('extreme_long_count',0)} | Extreme Short: {f.get('extreme_short_count',0)}\")
    top_p = f.get('top_positive', [])[:3]
    top_n = f.get('top_negative', [])[:3]
    if top_p:
        lines.append('Highest Funding: ' + ', '.join(f\"{t['symbol'].replace('USDT','')}: {t['rate']:+.3f}%\" for t in top_p))
    if top_n:
        lines.append('Lowest Funding: ' + ', '.join(f\"{t['symbol'].replace('USDT','')}: {t['rate']:+.3f}%\" for t in top_n))

oi = data.get('open_interest', {})
if 'BTCUSDT_oi_usd' in oi:
    lines.append(f\"BTC OI: \${oi['BTCUSDT_oi_usd']/1e9:.1f}B ({oi.get('BTCUSDT_oi_change_24h',0):+.1f}%)\")

fg = data.get('fear_greed', {})
if '_error' not in fg:
    lines.append('')
    lines.append('=== SENTIMENT ===')
    lines.append(f\"Fear & Greed: {fg.get('value',50)} ({fg.get('label','?')}) | Yesterday: {fg.get('previous',50)} ({fg.get('change',0):+d})\")

dom = data.get('dominance', {})
if '_error' not in dom:
    lines.append(f\"BTC Dom: {dom.get('btc_dominance',0):.1f}% | MCap: \${dom.get('total_market_cap_usd',0):.0f}B ({dom.get('market_cap_change_24h',0):+.1f}%)\")

liq = data.get('liquidations', {})
if '_error' not in liq:
    lines.append('')
    lines.append('=== LIQUIDATIONS ===')
    lines.append(f\"Total: \${liq.get('total_usd',0)/1e6:.1f}M (Long: \${liq.get('long_liquidated_usd',0)/1e6:.1f}M / Short: \${liq.get('short_liquidated_usd',0)/1e6:.1f}M)\")

news = data.get('news', [])
if news:
    lines.append('')
    lines.append('=== HEADLINES ===')
    for n in news[:5]:
        lines.append(f\"  - {n.get('title','')}\")

tr = data.get('trending', [])
if tr:
    lines.append(f\"Trending: {', '.join(t.get('symbol','') for t in tr[:5])}\")

print('\\n'.join(lines))
" <<< "$MARKET_DATA" 2>/dev/null)

log "Market context built (${#MARKET_CONTEXT} chars)"

# ── 3. Generate Instagram image ──
IG_IMAGE="$CHART_DIR/daily_digest_$(date -u +%Y%m%d).png"
echo "$MARKET_DATA" | $PYTHON3 "$SCRIPT_DIR/instagram-image-generator.py" \
    "$IG_IMAGE" --type feed --category "market_analysis" 2>/dev/null

if [[ ! -f "$IG_IMAGE" ]]; then
    log "Image generation via pipeline failed, trying social_poster"
    $PYTHON3 -c "
import sys
sys.path.insert(0, '$HOME/scripts/social')
from social_poster import generate_instagram_image
path = generate_instagram_image('''$MARKET_CONTEXT''', '$IG_IMAGE')
print(f'Generated: {path}')
" 2>/dev/null
fi

[[ -f "$IG_IMAGE" ]] && log "Daily image generated: $IG_IMAGE" || log "Image generation failed"

# ── 4. Generate X content (English) ──
DATE_STR=$(date -u +"%b %d")

x_content=$(claude --model "$MODEL_SONNET" -p "You are a sharp crypto analyst writing a DAILY RECAP for X (Twitter).
Today is $DATE_STR UTC.

Your job: find the ONE most interesting data point in today's crypto market and make it the tweet.
Could be: a price move, unusual funding rate, liquidation spike, Fear & Greed extreme, BTC dominance shift.

$MARKET_CONTEXT

RULES:
- Max 275 chars (leave room for URL). Single tweet, not a thread.
- First 60 chars must be a hook — a surprising number or contrast
- Use exact numbers only — no vague terms like 'surged' without a %
- Sound like a trader who tracks data, not a journalist
- End with: pruviq.com/simulate
- 1 hashtag max (\$BTC or \$ETH or \$SOL)
- Allowed emojis: 📊 📉 📈 🔴 🟢 (max 2)
- Never mention PRUVIQ, bots, automated trading
- NO 'NFA', 'DYOR', 'not financial advice'
- NO 'Let's dive in', 'Here's the thing', 'Interesting', 'Just'
- English only

Output ONLY the tweet. Nothing else." \
    --allowedTools "Read" \
    --max-turns 1 2>&1)

# ── 5. Generate Threads content (Korean) ──
threads_content=$(claude --model "$MODEL_SONNET" -p "오늘 크립토 시장 데일리 리캡. Threads에 올릴 글.
날짜: $DATE_STR UTC

$MARKET_CONTEXT

형식:
📊 [날짜] 크립토 데일리

오늘의 핵심 한 줄 (숫자 포함, 가장 임팩트 있는 데이터)

BTC \$XX,XXX (±X%) | ETH \$X,XXX (±X%)
[주요 움직임 1-2줄]

파생상품: 펀딩 X% | 청산 \$XM (롱/숏 비율)
센티먼트: 공포탐욕 XX (라벨)

[마감: pruviq.com/simulate]

규칙:
- 400자 이내 (짧을수록 좋음)
- 줄바꿈으로 가독성 확보
- 이모지 최소 (📊 📉 📈 만, 최대 2개)
- 자연스러운 한국어 — AI 느낌, 번역 느낌 금지
- 막연한 표현 금지 (예: '급등', '급락' — 반드시 % 수치 첨부)
- PRUVIQ/봇/자동매매 언급 금지
- 정확한 숫자만 인용
- 한국어만

텍스트만 출력." \
    --allowedTools "Read" \
    --max-turns 1 2>&1)

# ── 6. Generate Instagram caption ──
ig_content=""
if [[ -f "$IG_IMAGE" ]]; then
    ig_content=$(claude --model "$MODEL_SONNET" -p "Write a daily recap Instagram caption. Date: $DATE_STR UTC.
The image already shows the key data visually.

$MARKET_CONTEXT

RULES:
- First line max 125 chars (feed preview)
- Total max 500 chars
- Don't describe the image
- End with a question for engagement
- 3-5 hashtags at end: #CryptoDaily #BTC + relevant
- NO PRUVIQ, bots, automated trading mentions
- English only
- Use exact numbers

Output ONLY caption." \
        --allowedTools "Read" \
        --max-turns 1 2>&1)
fi

# ── 7. Quality check + queue all 3 platforms ──
quality_check_and_post() {
    local platform="$1"
    local content="$2"
    local image="$3"

    if [[ -z "$content" || ${#content} -lt 10 ]]; then
        log "$platform: Content empty or too short, skipping"
        return 1
    fi

    # Check for Claude errors
    if echo "$content" | grep -qiE "^error|exception|unauthorized|rate.limit|APIError"; then
        log "$platform: Claude returned error"
        return 1
    fi

    # Quality check
    local qc_input qc_result score action issues
    qc_input=$($PYTHON3 -c "
import json, sys, os
data = {'platform': '$platform', 'content': sys.stdin.read().strip(), 'chart': '${image:-}'}
try:
    md = json.loads(open('$DATA_DIR/daily_digest_$(date -u +%Y%m%d).json').read())
    data['market_data'] = md
except: pass
print(json.dumps(data, ensure_ascii=False))
" <<< "$content" 2>/dev/null)

    qc_result=$(echo "$qc_input" | $PYTHON3 "$SCRIPT_DIR/quality-checker.py" 2>/dev/null)
    score=$(echo "$qc_result" | $PYTHON3 -c "import sys,json; print(json.load(sys.stdin).get('score',0))" 2>/dev/null || echo "0")
    action=$(echo "$qc_result" | $PYTHON3 -c "import sys,json; print(json.load(sys.stdin).get('action','discard'))" 2>/dev/null || echo "discard")
    issues=$(echo "$qc_result" | $PYTHON3 -c "import sys,json; print(', '.join(json.load(sys.stdin).get('issues',[])))" 2>/dev/null || echo "")

    log "$platform: score=$score action=$action"

    if [[ "$action" == "needs_approval" ]]; then
        # Queue for approval
        local queue_file="$QUEUE_DIR/$(date +%Y%m%d)-daily-digest-${platform}.json"
        $PYTHON3 -c "
import json, sys, os
data = {'platform': '$platform', 'content': sys.stdin.read().strip(),
        'category': 'daily_digest', 'generated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
        'status': 'pending_approval'}
if '$image':
    data['chart'] = '$image'
with open('$queue_file', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
" <<< "$content"

        local preview=$(echo "$content" | head -c 300 | tr '\n' ' ')
        local tg_msg="<b>[📋 Daily Digest]</b> ${platform^^} (score=${score})

<b>Content:</b>
${preview}"

        if [[ -n "$image" && -f "$image" ]]; then
            send_telegram_approval_photo "$image" "$tg_msg"
        else
            send_telegram_approval "$tg_msg"
        fi
        return 0
    else
        send_telegram_approval "🗑 <b>[Daily Digest 품질미달]</b> ${platform^^} (${score}/100): $issues"
        return 1
    fi
}

quality_check_and_post "x" "$x_content" "$IG_IMAGE"
quality_check_and_post "threads" "$threads_content" "$IG_IMAGE"
[[ -n "$ig_content" ]] && quality_check_and_post "instagram" "$ig_content" "$IG_IMAGE"

log "=== Daily Market Digest complete ==="
