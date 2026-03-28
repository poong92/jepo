---
name: sim-audit
description: "/sim-audit — PRUVIQ 시뮬레이터 전체 검증. 4개 레이어(완전성/도메인/수치/UX) 순차 검증 후 리포트 생성. Use when user asks \"sim-audit\", \"시뮬레이터 검증\", or \"시뮬레이터 감사\"."
context: fork
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Agent, WebFetch
---

# /sim-audit — PRUVIQ 시뮬레이터 전체 검증

## 용도
PRUVIQ 시뮬레이터의 전체 무결성을 검증하는 원클릭 스킬.
4개 레이어(완전성/도메인/수치/UX)를 순차적으로 검증하고 리포트를 생성합니다.

## 실행 흐름

### 1단계: 환경 확인
- PRUVIQ API 서버 상태 확인 (localhost:8080 또는 api.pruviq.com)
- Ground Truth 데이터셋 존재 확인

### 2단계: Layer 0 — 완전성 검증
- simulator-qa 에이전트 호출
- 업계 표준 대비 빠진 기능 탐지
- 결과: COMPLETENESS_REPORT

### 3단계: Layer 1 — 도메인 정합성
- 금융 공식 코드 vs 학술 표준 대조
- 파라미터 조합 논리 검증
- 비용 모델 현실성 검증
- 결과: DOMAIN_REPORT

### 4단계: Layer 2 — 수치 정합성
- Ground Truth 대비 API 결과 비교
- Cross-engine 일관성 테스트
- Edge case 테스트
- 결과: NUMERICAL_REPORT

### 5단계: Layer 3 — UX 정합성
- 프론트엔드 라벨 ↔ 백엔드 계산 대조
- i18n 키 정확성
- 결과: UX_REPORT

### 6단계: 종합 리포트
- 4개 레이어 결과 통합
- PASS/FAIL/WARN 집계
- 수정 우선순위 제안
- 파일 출력: ~/Desktop/pruviq/SIM_AUDIT_REPORT_{date}.md

## 인수 (Arguments)

- `full` (기본): 4개 레이어 전체 검증
- `layer0`: 완전성만
- `layer1`: 도메인만
- `layer2`: 수치만
- `layer3`: UX만
- `quick`: Layer 1 + 2 핵심만 (빠른 검증)

## 관련 에이전트
- simulator-qa: 전체 검증 수행
- research-agent: 업계 표준 조사
- validation-analyst: 통계 검증
- strategy-analyst: 전략 논리

## 주의사항
- Ground Truth는 수작업 검증된 데이터만 사용
- 자동 생성된 정답은 사용 금지
- 오차 허용범위: 0.01% (부동소수점 차이)
