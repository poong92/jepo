# 문서 동기화 룰 (CRITICAL)

> CLAUDE.md의 숫자는 항상 실체와 일치해야 한다.

| 변경 | 갱신 대상 | 검증 |
|------|---------|------|
| 에이전트 추가/삭제 | CLAUDE.md + project_jepo_system.md | `find agents/ -name "*.md" \| wc -l` |
| 스킬 추가/삭제 | CLAUDE.md + 목록 | `ls ~/.claude/skills/` |
| 훅 추가/삭제 | CLAUDE.md + settings.json | `ls ~/.claude/hooks/` |
| LaunchAgent 추가/삭제 | project_jepo_system.md + system_ecosystem | `launchctl list \| grep pruviq` |
| 크론 추가/삭제 | 위 2개 + crontab 실측 | `crontab -l` |
| 서버 IP/포트 변경 | `~/.claude/config.json` 1곳만 | 하드코딩 금지 |
| 갱신 후 | MEMORY.md 인덱스 description도 갱신 | |
