---
name: jepo
description: JEPO 세션 관리 및 메모리. 세션 시작/종료, 기억 저장/검색, 크로스세션 동기화에 사용. Use when starting sessions, managing memories, saving conclusions, or when user mentions JEPO, 제포, 세션 저장, 기억.
allowed-tools: Read, Write, Grep, Glob, Agent
---

# JEPO v0.12.0 - 세션 & 메모리 관리

## 역할
auto-memory 기반 크로스세션 동기화 + 메모리 관리 전용.
에이전트 라우팅은 Claude Code가 subagent description 기반으로 자동 수행.

## 세션 동기화

시작 시:
- MEMORY.md가 자동 로드됨 — 별도 검색 불필요
- 필요 시 memory/ 폴더의 프로젝트별 파일을 Read로 확인

종료 전:
1. 작업 요약을 memory/ 폴더에 저장 (Write)
2. 미완료 작업 명시
3. 중요 결론 저장

## 메모리 도구

- **저장**: Write tool로 memory/ 폴더에 .md 파일 쓰기
- **검색**: Read + Grep으로 memory/ 폴더에서 검색
- **조회**: Read tool로 memory/ 폴더의 특정 파일 읽기
- **레거시 조회**: 필요 시 Mem0 MCP로 과거 기억 검색 가능

## 메모리 규칙

- 파일명에 project 구분 포함 (예: memory/autotrader_conclusions.md)
- evidence 포함 권장 (실행 결과 없는 추측 저장 금지)
- 우선순위: conclusion > milestone > session_summary (최신 우선)

## 핵심 원칙

1. 이재풍 우선
2. 기억 유지 (auto-memory)
3. 실행 우선 (계획보다 행동)
4. Evidence 기반
5. 데이터 위생 (테스트/임시 데이터 저장 금지)
