# JEPO Workflows

## Daily Start
**Trigger**: 세션 시작 시 또는 /jepo 호출 시
**Output**: 현재 상태 + 진행 중인 작업 + TODO

1. 오늘 날짜/시간 확인
2. MEMORY.md 자동 로드 확인 (별도 검색 불필요)
3. 필요 시 memory/ 폴더의 프로젝트별 파일 Read

## Memory Save Workflow
**Trigger**: "기억해줘", "저장해", "나중에 참고" 등의 요청
**Output**: 저장 확인 메시지

```
1. 정보 중요도 판단
2. 적절한 파일명 결정 (memory/[project]_[type].md)
3. Write tool로 memory/ 폴더에 .md 파일 저장
```

## Project Context Loading
**Trigger**: 프로젝트 작업 시작 시 또는 "프로젝트 로드" 요청
**Output**: 프로젝트 컨텍스트 + 최근 진행 상황

```
1. Grep으로 memory/ 폴더에서 project 관련 파일 검색
2. Read tool로 해당 파일들 읽기
3. 최근 변경사항 확인
4. TODO 상태 점검
```

## Decision Recording
**Trigger**: 중요한 결정이 내려졌을 때 (시스템 설계, 기술 선택, 방향 결정 등)
**Output**: 결정 저장 확인

중요한 결정을 할 때:
```
Write tool로 memory/[project]_decision_[YYYY-MM-DD].md 저장:
- 결정 내용
- 카테고리: system|work|personal
- 중요도: critical|high|medium|low
- 결정 배경/근거
```

## Learning Recording
**Trigger**: 새로운 패턴/기술/방법 발견 시 (3회 이상 반복된 패턴)
**Output**: 학습 저장 확인

새로운 학습/발견:
```
Write tool로 memory/[project]_learning_[YYYY-MM-DD].md 저장:
- 학습 내용
- 카테고리: tech|process|preference
- 출처
```

## Sync Workflow (v0.12.0 업데이트)
**Trigger**: 중요한 변경/체크포인트 발생 시
**Output**: 동기화 완료 확인

정보 변경 시 반드시 수행:
```
1. memory/ 폴더에 체크포인트 저장 (Write)
   - 변경된 항목 반영
   - 버전 업데이트

2. 레거시 Mem0 정보 필요 시 조회 (읽기 전용)
   - 과거 기억이 필요한 경우만 mcp__mem0__search_memories 사용
```

### 동기화 체크리스트
- [ ] MEMORY.md와 memory/ 폴더 정보 일치 확인
- [ ] 레거시 정보 없는지 확인
- [ ] 다음 세션을 위한 체크리스트 초기화
