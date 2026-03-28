---
name: pruviq-qa
description: PRUVIQ QA 자동 검증. Playwright MCP로 OHLCV 신선도, 렌더링, 시뮬레이터, i18n, 성능 데이터를 검증합니다. Use when user asks "pruviq-qa", "사이트 검증", "QA", or "프루빅 테스트".
context: fork
allowed-tools: mcp__playwright__*, Bash, Read, WebFetch
---

# PRUVIQ QA 자동 검증

Playwright MCP를 사용하여 PRUVIQ 사이트를 자동 검증합니다.

## 테스트 항목

1. **OHLCV 신선도**: api.pruviq.com/ohlcv/BTCUSDT → 마지막 타임스탬프 24시간 이내
2. **홈페이지 렌더링**: pruviq.com → H1 텍스트 + 차트 canvas 확인
3. **시뮬레이터**: POST /simulate 기본값 → 결과 통계 존재
4. **i18n**: /ko/ 한국어 텍스트 확인
5. **성능 데이터**: /data/performance.json → 최신 날짜

## 실행 방법

Playwright MCP 도구 사용 (browser_ 접두사):
- `browser_navigate` → 페이지 이동
- `browser_take_screenshot` → 스크린샷 촬영
- `browser_evaluate` → JS 실행으로 데이터 추출
- `browser_snapshot` → 페이지 접근성 스냅샷 (텍스트 확인용)
- `browser_click` → 요소 클릭

## 검증 플로우

```
1. browser_navigate("https://api.pruviq.com/ohlcv/BTCUSDT")
   → browser_evaluate로 JSON 파싱 → 마지막 타임스탬프 확인

2. browser_navigate("https://pruviq.com")
   → browser_evaluate("document.querySelector(h1)?.textContent")
   → browser_evaluate("document.querySelector(canvas) !== null")
   → browser_take_screenshot

3. browser_navigate("https://pruviq.com/simulator")
   → 기본값으로 시뮬레이션 실행
   → 결과 통계 테이블 확인

4. browser_navigate("https://pruviq.com/ko/")
   → browser_snapshot으로 한국어 텍스트 존재 확인

5. browser_navigate("https://pruviq.com/data/performance.json")
   → browser_evaluate로 JSON 파싱 → 최신 날짜 확인
```

## 결과 보고

각 항목별 PASS/FAIL + 상세 내용:
- PASS: 기대값과 일치
- FAIL: 기대값 불일치 + 실제값 + 스크린샷

## 트리거

- `/pruviq-qa` 명령으로 수동 실행
- OpenClaw strategic-review 크론에서 참조 가능
