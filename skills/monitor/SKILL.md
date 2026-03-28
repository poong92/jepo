---
name: monitor
description: AutoTrader 실시간 모니터링. 서버 상태, 포지션, PnL, 로그를 빠르게 확인합니다. Use when user asks "모니터", "monitor", "서버 상태", "포지션 확인", or "로그".
context: fork
agent: infrastructure-monitor
allowed-tools: Bash, Read
---

# Monitor v0.11.0

## 빠른 확인 (단일 명령)

```bash
# 서버 상태 + 최근 로그
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && docker-compose ps && echo '---' && docker-compose logs --tail=20"
```

## 상세 확인

### 1. 봇 상태
```bash
ssh -p 2222 root@167.172.81.145 "docker-compose -f /opt/autotrader/docker-compose.yml ps"
```

### 2. 현재 포지션
```bash
ssh -p 2222 root@167.172.81.145 "docker-compose -f /opt/autotrader/docker-compose.yml logs --tail=50" | grep -E "POSITION|포지션|position"
```

### 3. 최근 거래
```bash
ssh -p 2222 root@167.172.81.145 "docker-compose -f /opt/autotrader/docker-compose.yml logs --tail=100" | grep -E "ENTRY|EXIT|TP|SL|TIMEOUT"
```

### 4. 에러 확인
```bash
ssh -p 2222 root@167.172.81.145 "docker-compose -f /opt/autotrader/docker-compose.yml logs --tail=200" | grep -iE "error|exception|traceback|critical"
```

## 출력 형식

```
=== AutoTrader Monitor ===
서버: 167.172.81.145 (SSH:2222)
봇: Up/Down (uptime) — 현재 STOPPED (2026-03-09)
포지션: N/100 (잔여 수동 청산 필요)
최근 거래: [TP/SL/TIMEOUT] 시간
에러: 0건 / N건
```
