#!/bin/bash
# JEPO Agent Usage Stats — 주간 요약 생성
# 호출: bash ~/.claude/hooks/agent-stats.sh

METRICS="$HOME/logs/jepo/agent-metrics.jsonl"
STATS_DIR="$HOME/logs/jepo/stats"
mkdir -p "$STATS_DIR"

if [ ! -f "$METRICS" ]; then
  echo "No metrics file found"
  exit 0
fi

DATE=$(date '+%Y-%m-%d')
STATS_FILE="$STATS_DIR/agent-stats-${DATE}.txt"

echo "=== Agent Usage Stats ($DATE) ===" > "$STATS_FILE"
echo "" >> "$STATS_FILE"

grep '"event":"stop"' "$METRICS" | python3 -c "
import json, sys
from collections import Counter, defaultdict

agents = Counter()
durations = defaultdict(list)

for line in sys.stdin:
    try:
        d = json.loads(line)
        agents[d['agent']] += 1
        durations[d['agent']].append(d.get('duration_sec', 0))
    except:
        pass

print(f'Total invocations: {sum(agents.values())}')
print(f'Unique agents: {len(agents)}')
print()
print(f'{\"Agent\":30s} {\"Count\":>6s} {\"Avg(s)\":>7s} {\"Total(s)\":>9s}')
print('-' * 55)
for agent, count in agents.most_common():
    avg = sum(durations[agent]) / len(durations[agent]) if durations[agent] else 0
    total = sum(durations[agent])
    print(f'{agent:30s} {count:>6d} {avg:>7.0f} {total:>9.0f}')
" >> "$STATS_FILE" 2>/dev/null

echo "" >> "$STATS_FILE"
echo "Generated: $(date)" >> "$STATS_FILE"

cat "$STATS_FILE"
