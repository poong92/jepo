---
name: health
description: JEPO 시스템 상태를 진단합니다. 메모리 상태, Git 동기화, MCP 연결, autotrader 서버 상태를 확인합니다. Use when user asks about system status, health check, or "상태 확인".
context: fork
agent: infrastructure-monitor
allowed-tools: Bash, Read, Grep, Glob
---

# JEPO Health Check v2.4

## 목적
시스템 상태 자가진단 - memory/ 폴더 상태, Git 상태, autotrader 동기화, 서버 상태 확인

> **현재 autotrader 버전**: config_squeeze.py의 VERSION 변수에서 동적으로 확인
> ```bash
> grep "^VERSION" ~/Desktop/autotrader/src/live/config_squeeze.py
> ```

## 진단 항목

### 1. 메모리 상태 (auto-memory)
```bash
# memory/ 폴더 존재 및 파일 수 확인
ls -la ~/.claude/memory/ 2>/dev/null && echo "OK" || echo "MISSING"
# MEMORY.md 존재 확인
ls -la ~/.claude/MEMORY.md 2>/dev/null && echo "OK" || echo "MISSING"
```

### 2. Git 동기화 상태
```bash
git status --porcelain
git log -1 --format="%h %s (%cr)"
```

### 3. autotrader 동기화 체크
```bash
python3 ~/Desktop/autotrader/scripts/sync_check.py
```

### 4. autotrader 서버 상태
```bash
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && docker-compose logs --tail=10" 2>&1 | tail -15
```

### 5. PRUVIQ API 상태
```bash
curl -s https://api.pruviq.com/health | head -1
curl -s https://pruviq.com/ | head -1
```

## 출력 형식

```
=== JEPO Health Check v2.4 ===

[Memory] auto-memory: OK | memory/ 폴더: N개 파일
[Git]    브랜치: main | uncommitted: 0 | 마지막: xxxxx (N시간 전)

=== AutoTrader 상태 ===
[동기화] Docker: vX.X.X | CLAUDE.md: vX.X.X
[서버]   봇: STOPPED (2026-03-09) | 잔여 포지션 수동 청산 필요

=== PRUVIQ 상태 ===
[API]    coins_loaded: 549
[Web]    응답: 200

상태: 정상 / 주의 필요
```
