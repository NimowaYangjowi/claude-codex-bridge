# Claude-Codex Bridge

Claude Code의 훅 시스템(PostToolUse, Stop, UserPromptSubmit)을 Codex 환경에서도 동일하게 실행할 수 있게 해주는 브릿지.

## 문제

Claude Code는 `settings.json`에 정의된 훅을 자동으로 트리거하지만, Codex는 이 훅 시스템을 네이티브로 지원하지 않습니다. 이 브릿지는 Codex 세션에서 동일한 훅 파이프라인을 수동/자동으로 실행할 수 있게 합니다.

## 구성 요소

### 브릿지 코어

| 파일 | 역할 |
|------|------|
| `run-in-codex.sh` | 메인 오케스트레이터. 훅 디스패치, JSON 파싱, 세션 관리 |
| `track-modified-file.sh` | PostToolUse — Edit/Write 후 수정된 파일 경로를 세션별로 추적 |
| `auto-commit.sh` | 세션에서 추적된 파일만 자동 커밋 (finalize 시 사용) |

### 게이트 훅

| 파일 | 역할 |
|------|------|
| `remind-uncommitted.sh` | Stop — 미커밋 변경사항 감지 시 block, 커밋 유도 |
| `codex-verify.sh` | Stop — 수정된 src/ 파일에 대해 Codex 리뷰 게이트 |
| `stop/cleanup-verify-state.sh` | Stop — 세션 종료 시 /tmp 상태 파일 정리 |

## 설치

프로젝트의 `.claude/` 디렉토리에 복사:

```bash
# hooks 디렉토리 복사
cp -r .claude/hooks <대상 프로젝트>/.claude/hooks

# settings.json 병합 (기존 settings.json이 있으면 hooks 섹션만 병합)
cp .claude/settings.json <대상 프로젝트>/.claude/settings.json
```

## 사용법

### Claude Code에서 (자동)

`settings.json`의 훅 설정에 의해 자동 트리거됩니다.

### Codex에서 (수동)

```bash
# 파일 수정 후 PostToolUse 훅 실행
bash .claude/hooks/run-in-codex.sh post src/lib/foo.ts

# 스테이징된 모든 변경 파일에 대해 PostToolUse 실행
bash .claude/hooks/run-in-codex.sh changed

# UserPromptSubmit 훅 수동 실행
bash .claude/hooks/run-in-codex.sh prompt "프롬프트 텍스트"

# Stop 훅 실행 (세션 종료 전)
bash .claude/hooks/run-in-codex.sh stop

# changed + stop 한 번에 실행
bash .claude/hooks/run-in-codex.sh all

# changed + auto-commit + stop 한 번에 실행
bash .claude/hooks/run-in-codex.sh finalize

# 세션 상태 파일 초기화
bash .claude/hooks/run-in-codex.sh reset
```

## 커스터마이징

### 프로젝트별 훅 추가

`run-in-codex.sh` 상단의 훅 리스트를 수정하세요:

```bash
# PostToolUse hooks
POST_HOOKS=(
  "track-modified-file.sh"
  "my-custom-post-hook.sh"       # 추가
)

# UserPromptSubmit hooks
PROMPT_HOOKS=(
  "my-prompt-detector.sh"        # 추가
)

# Stop hooks
STOP_HOOKS=(
  "remind-uncommitted.sh"
  "my-quality-gate.sh"           # 추가
  "codex-verify.sh"
  "stop/cleanup-verify-state.sh"
)
```

### 훅 작성 규칙

모든 훅은 stdin으로 JSON을 받고 stdout으로 JSON을 반환합니다:

```bash
# 입력 (stdin)
{"session_id":"abc123","tool_input":{"file_path":"/path/to/file"}}

# 출력 (stdout)
{"decision": "approve"}              # 통과
{"decision": "warn", "reason": "..."} # 경고 표시 후 계속
{"decision": "block", "reason": "..."} # 중단, Claude가 reason에 따라 조치
```

## 세션 관리

브릿지는 `CLAUDE_SESSION_ID` 또는 `CODEX_THREAD_ID` 환경변수로 세션을 구분합니다. 세션별 상태 파일은 `/tmp/claude-*-{SESSION_ID}*`에 저장되며, `reset` 또는 `stop/cleanup-verify-state.sh`에 의해 정리됩니다.

## 의존성

- bash, python3 (JSON 파싱용)
- git (커밋 추적/상태 확인)
- jq (선택사항 — 없으면 python3/grep으로 폴백)

## 라이선스

MIT
# claude-codex-bridge
