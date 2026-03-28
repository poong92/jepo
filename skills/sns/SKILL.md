---
name: sns
description: "PRUVIQ SNS 콘텐츠 생성·검증·발행 준비. Use when user asks \"sns\", \"콘텐츠\", \"트윗\", \"포스트\", or SNS-related content creation."
context: fork
allowed-tools: Read, Write, Grep, Glob, WebSearch, WebFetch
---

# PRUVIQ SNS Marketing Skill

## 역할
SNS 콘텐츠 생성, 검증, 발행 준비를 위한 통합 스킬.
X + Threads 동시 관리, 데이터 기반 콘텐츠 생성.

## 트리거
- `/sns` — 일간 콘텐츠 생성 (오늘 요일 기반)
- `/sns week` — 주간 콘텐츠 일괄 생성
- `/sns review [text]` — 콘텐츠 품질 검증
- `/sns bio` — 바이오 최적화
- `/sns pin` — 핀 트윗 생성/갱신

## 타겟 (CRITICAL)

**크립토 초보 친구들** — 전문 트레이더가 아님.
- "승률이 뭐야?" "백테스트가 뭐야?" 수준
- "이 코인 사야 돼 말아야 돼?" 고민하는 사람
- 차트 보는 게 어렵고 무서운 사람
- 돈 잃은 경험 있거나, 처음 시작하려는 사람

## 목표 (CRITICAL)

1. **팔로워 늘리기** — 홍보/링크 아님. 공감과 대화로.
2. **대화 만들기** — 댓글 달고 싶어지는 콘텐츠.
3. **친구 사귀기** — 브랜드가 아니라 사람 대 사람.

## 톤 & 스타일 (CRITICAL — 모든 콘텐츠에 적용)

### 핵심 원칙: "크립토 초보 친구한테 DM 보내는 느낌"
- 회사가 아니라 **한 명의 사람**이 말하는 것
- 큰 분석이 아니라 **작은 발견, 소소한 감상**
- "야 이거 봤어?" "나도 처음에 이랬어" 톤
- **전문용어 없이** 누구나 알아듣게
- 쉬운 비유 (레스토랑, 날씨, 일상)
- 공감 + 질문으로 대화 유도
- 댓글 달고 싶어지는 **가벼운 질문**으로 끝내기

### 절대 금지 (위반 시 알고리즘 패널티 + 팔로워 이탈)
1. **링크 일체** — 본문, 리플, 어디에도 링크 없음. 팔로워 먼저 모으고 나중에.
2. **해시태그 규칙** — 팔로워 0 성장 단계에서는 발견을 위해 2-3개 허용. 단 자연스럽게:
   - ✅ OK: `#crypto #trading` (일반적, 자연스러움)
   - ✅ OK: `#bitcoin #altcoins` (주제 관련)
   - ❌ 금지: `#BacktestResults #PRUVIQ #TradingStrategy` (브랜드/전문 냄새)
   - X: 본문 끝에 2개. Threads: 본문 끝에 2-3개.
   - 팔로워 1000명 이상 되면 해시태그 제거 재검토
3. **"we" 사용** — 회사 톤. 대신 "i" 또는 주어 생략
4. **CTA** — "check out", "see our", "try it", "visit", "sign up" 전부 금지
5. **brochure 문구** — "that's why we...", "we're proud to...", "our platform..."
6. **전문용어** — WR, PF, regime fit, Sharpe ratio, drawdown 등 전부 금지. 풀어서 쉽게.
7. **대문자 강조** — "FREE", "PROVEN", "AMAZING" 등
8. **pruviq.com 직접 언급** — 어디에도 금지. 나중에 팔로워 생기면 재검토.
9. **Don't Believe. Verify.** — 본문에 넣지 않음. 바이오/핀에만.

### 전문용어 → 초보 친화 변환표
| 금지 | 대체 |
|------|------|
| win rate / WR | "33번 중에 26번 이김" |
| "this week" | "last 7 days" (7일 롤링이라 매일 다름, week이라고 하면 혼란) |
| PF (profit factor) | 사용 안 함 |
| backtest | "과거 데이터로 테스트해봤더니" |
| strategy | "방법" 또는 "접근법" |
| regime fit | 사용 안 함 |
| drawdown | "최대로 빠졌을 때" |
| long/short | "오를 거라고 베팅" / "내릴 거라고 베팅" |

### 올바른 패턴
- 데이터를 던지고 → 쉬운 비유 → 질문
- 소문자 캐주얼 (threads 특히)
- "let that sink in" "the thing is" 같은 대화체
- 반전/의외성이 있는 데이터 포인트 선택
- "나도 처음에 이랬어" 공감 포인트

## 7일 캘린더

| 요일 | 타입 | 톤 |
|------|------|-----|
| 월 | Weekly Recap | "이번 주 숫자 좀 봐봐" |
| 화 | Daily Ranking + Discovery | "오늘 돌려봤는데 이거 좀 이상해" |
| 수 | Strategy Autopsy | "이 방법 왜 이번 주 안 됐는지 보면..." |
| 목 | Education Bite | "이거 아는 사람 별로 없는데" |
| 금 | Strategy Spotlight | "조용히 잘 되고 있는 게 하나 있어" |
| 토 | Market Context | "시장 지금 이 상태인데" |
| 일 | 이번 주 한 줄 정리 | "this week in one sentence for me:" 짧은 회고 |

## 품질 체크리스트

- [ ] 링크 없음 (본문, 리플 전부)
- [ ] 해시태그 없음
- [ ] "we" 없음
- [ ] CTA 없음
- [ ] 하이프 단어 없음
- [ ] 전문용어 없음 (WR, PF, regime 등)
- [ ] 질문 또는 감상으로 끝남
- [ ] X <= 280자
- [ ] Threads <= 500자 (늘려도 750자 이내)
- [ ] 숫자는 실제 API 데이터만
- [ ] 초보가 읽어도 이해 가능

## 데이터 소스

- 전략 랭킹: ~/pruviq/public/data/ranking-fallback.json
- 콘텐츠 큐: ~/scripts/social/queue/
- SNS 전략: memory/project_sns_strategy.md

## 에이전트 연동

- `x-twitter-expert` — X 알고리즘 최적화
- `threads-expert` — Threads 롱폼 최적화
- `copywriter` — 카피 개선
- `growth-hacker` — 바이럴 루프

## 브랜드 규칙

1. 숫자는 실제 API 데이터만 (조작/추정 금지)
2. 실패 전략도 자연스럽게 포함 (숨기지 않음)
3. 수익 약속 절대 금지
4. 링크 일체 금지 (성장 단계에서는 팔로워 우선)
