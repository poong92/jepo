---
name: deploy
description: AutoTrader 서버 배포 안전 절차. 코드 검증, 배포, 사후 검증까지 체계적으로 수행합니다. Use when user asks "배포", "deploy", or "서버 업데이트".
context: fork
agent: devops-engineer
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Agent
---

# Deploy Workflow v0.11.0

## 배포 절차

### 1. 사전 검증
```bash
# Git 상태 확인
cd ~/Desktop/autotrader && git status && git log -3 --oneline

# 서버 현재 상태 확인
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && git log -1 --oneline && docker-compose ps"
```

### 2. 배포 실행
```bash
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && git pull && docker-compose down && docker-compose build --no-cache && docker-compose up -d"
```

### 3. 사후 검증 (5분 대기)
```bash
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && docker-compose logs --tail=30"
```

검증 항목:
- [ ] 버전 로그 정상 출력
- [ ] 에러 0건
- [ ] 포지션 동기화 완료
- [ ] SL/TP 보호 확인
- [ ] 텔레그램 heartbeat 수신

### 4. 롤백 기준
- Docker 크래시 3회 연속
- 에러 로그 지속 발생
- 포지션 동기화 실패

### 5. 롤백 절차
```bash
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && git log -5 --oneline"
# 이전 커밋 확인 후
ssh -p 2222 root@167.172.81.145 "cd /opt/autotrader && git checkout {previous_commit} && docker-compose down && docker-compose build --no-cache && docker-compose up -d"
```
