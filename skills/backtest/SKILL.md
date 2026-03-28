---
name: backtest
description: AutoTrader 백테스트 워크플로우. 전략 검증, 백테스트 실행, 결과 분석을 단계별로 수행합니다. Use when user asks "백테스트", "backtest", or "전략 검증".
context: fork
agent: backtester
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Agent
---

# Backtest Workflow v0.11.0

## 사전 검증 (CRITICAL)

실행 전 반드시 확인:
```bash
# 1. 실거래 시그널 로직
grep -A 30 "def check_short_signal" ~/Desktop/autotrader/src/live/indicators_squeeze.py

# 2. 백테스트 시그널 로직 비교
grep -A 30 "def check_signal" ~/Desktop/autotrader/scripts/backtest_matched_live.py

# 3. 설정값 동기화
diff <(grep "sl_pct\|tp_pct\|avoid_hours" ~/Desktop/autotrader/src/live/config_squeeze.py) \
     <(grep "sl_pct\|tp_pct\|avoid_hours" ~/Desktop/autotrader/scripts/backtest_matched_live.py)
```

불일치 발견 시 **즉시 중단** → 사용자 확인.

## 실행 순서

1. **사전 검증** → 로직 일치 확인
2. **백테스트 실행** → `scripts/backtest_matched_live.py` (realistic simulation)
3. **결과 분석** → strategy-analyst subagent 위임
4. **리스크 평가** → risk-manager subagent 위임
5. **최종 보고** → 사용자에게 GO/NO-GO 결론

## 필수 규칙

- Look-ahead bias 금지: prev 캔들만 조건에 사용
- 단순 수익률 합산 금지: 반드시 realistic simulation
- 레버리지 반영 필수: 5x
- 모든 설정은 config_squeeze.py에서 읽기

## 결과 검증 기준

| 항목 | 정상 범위 | 이상 시 |
|------|----------|---------|
| 승률 | 55-65% | 로직 불일치 의심 |
| SL율 | 15-25% | 조건 확인 |
| TP율 | 35-50% | 조건 확인 |
| 시그널수 | 수천~만건 | 필터 확인 |
