# Claude-Codex Bridge

Claude는 Claude 훅을 그대로 쓰고, Codex는 Codex 네이티브 훅을 쓰되, 두 환경이 같은 `세션 변경분만 커밋` 규칙을 공유하게 해 주는 레퍼런스 저장소입니다.

쉽게 말해:

- `Claude용 문`은 `.claude/settings.json`이 연다
- `Codex용 문`은 `.codex/hooks.json`이 연다
- 예전 `run-in-codex.sh` 브릿지는 호환성용 수동 도구로만 남겨 둔다

## 무엇이 바뀌었나

이 저장소는 더 이상 `Codex가 Claude 훅을 빌려 쓰는 기본 구조`를 권장하지 않습니다.

- Claude Code:
  `.claude/settings.json`의 `PostToolUse` / `Stop` 훅을 그대로 사용
- Codex:
  `.codex/hooks.json`의 `SessionStart` / `Stop` 네이티브 훅을 사용
- 공통 자동 커밋 규칙:
  `scripts/hooks/session_delta.py`
- 호환성:
  `.claude/hooks/run-in-codex.sh`는 수동 브릿지로 유지

또한 기본 설치 세트에서는 `codex-verify.sh`를 더 이상 강제하지 않습니다.

쉽게 말해:

- `작업 끝날 때 Codex 리뷰까지 꼭 받아야만 멈출 수 있는 문지기`는 기본값에서 뺐다
- 대신 `이번 세션에서 만든 변경만 자동 커밋할 수 있는가`를 더 정확하게 계산하는 쪽으로 바꿨다

## 구성 요소

### Claude 훅

| 파일 | 역할 |
|------|------|
| `.claude/settings.json` | Claude용 훅 등록. 기본값은 `track-modified-file`, `remind-uncommitted`, `cleanup` |
| `.claude/hooks/track-modified-file.sh` | Claude의 Edit/Write 이후 수정 파일 추적 |
| `.claude/hooks/remind-uncommitted.sh` | 커밋되지 않은 세션 변경 감지 |
| `.claude/hooks/auto-commit.sh` | 공통 세션-델타 엔진 호출 |
| `.claude/hooks/run-in-codex.sh` | 레거시 수동 브릿지 |
| `.claude/hooks/codex-verify.sh` | 선택형 레거시 검증 훅, 기본 활성 아님 |

### Codex 네이티브 훅

| 파일 | 역할 |
|------|------|
| `.codex/hooks.json` | Codex 네이티브 훅 등록 |
| `scripts/hooks/session_delta.py` | 세션 시작 baseline 저장, 종료 시 세션 변경분만 커밋 |

## 설치

프로젝트에 아래를 복사하세요.

```bash
cp -r .claude <target>/.claude
cp -r .codex <target>/.codex
mkdir -p <target>/scripts/hooks
cp scripts/hooks/session_delta.py <target>/scripts/hooks/session_delta.py
```

Codex 쪽은 사용자의 `~/.codex/config.toml`에서 훅 기능이 켜져 있어야 합니다.

예:

```toml
[features]
codex_hooks = true
```

## 동작 방식

### Claude

Claude는 `.claude/settings.json`을 읽고 자동으로 훅을 실행합니다.

- 파일을 수정하면 `track-modified-file.sh`가 이번 세션에서 만진 파일을 기록
- 세션 종료 시 `remind-uncommitted.sh`가 미커밋 파일을 검사
- 필요하면 `auto-commit.sh`가 `session_delta.py`를 호출해 세션 변경만 커밋

### Codex

Codex는 `.codex/hooks.json`을 읽고 네이티브 훅을 실행합니다.

- `SessionStart`
  - 현재 작업공간의 dirty 상태를 baseline으로 저장
- `Stop`
  - `HEAD -> baseline -> current`를 비교해서 이번 세션이 만든 변화만 커밋

쉽게 말해:

- 세션이 시작할 때 `현재 책상 사진`을 찍어 둔다
- 세션이 끝날 때 `그 사진 이후 새로 생긴 변화`만 제출한다

## 세션 변경만 커밋하는 규칙

`scripts/hooks/session_delta.py`는 아래 규칙으로 동작합니다.

1. Git에 이미 있던 파일이면:
   기존 HEAD, 세션 시작 시점, 현재 파일을 비교해 이번 세션 변경만 분리 시도
2. 세션 중 처음 생긴 새 파일이면:
   파일 전체를 이번 세션 변경으로 간주
3. 세션 시작 전부터 이미 있던 미추적 파일이면:
   기본적으로 안전하게 분리할 기준점이 없어서 block
4. 세션 시작 전부터 더럽던 파일에서 겹치는 줄을 이번 세션이 또 수정하면:
   충돌 위험 때문에 block

쉽게 말해:

- 이미 등록된 문서는 `오늘 쓴 부분만` 떼어낼 수 있다
- 처음부터 있던 미등록 초안 문서는 `원래 내용`과 `오늘 내용`을 안전하게 가르기 어려워서 멈춘다

## Codex 브릿지 호환 모드

기존 프로젝트가 아직 `run-in-codex.sh`를 직접 쓰고 있다면 그대로 유지할 수 있습니다.

```bash
# 파일 수정 후 PostToolUse 훅 실행
bash .claude/hooks/run-in-codex.sh post src/lib/foo.ts

# 스테이징된 모든 변경 파일에 대해 PostToolUse 실행
bash .claude/hooks/run-in-codex.sh changed

# UserPromptSubmit 훅 수동 실행
bash .claude/hooks/run-in-codex.sh prompt "프롬프트 텍스트"

# Stop 훅 실행
bash .claude/hooks/run-in-codex.sh stop

# changed + auto-commit + stop
bash .claude/hooks/run-in-codex.sh finalize

# 세션 상태 초기화
bash .claude/hooks/run-in-codex.sh reset
```

다만 권장 기본 경로는 `Codex 네이티브 훅`입니다.

## 커스터마이징

### Claude 훅 추가

`run-in-codex.sh`의 훅 리스트 또는 `.claude/settings.json`의 hooks 섹션을 수정하세요.

```bash
POST_HOOKS=(
  "track-modified-file.sh"
  "my-custom-post-hook.sh"
)

PROMPT_HOOKS=(
  "my-prompt-detector.sh"
)

STOP_HOOKS=(
  "remind-uncommitted.sh"
  "my-quality-gate.sh"
  "stop/cleanup-verify-state.sh"
)
```

### Codex 훅 추가

`.codex/hooks.json`에 네이티브 훅을 추가하세요.

예:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ./scripts/my-stop-check.sh"
          }
        ]
      }
    ]
  }
}
```

## 의존성

- bash
- python3
- git
- jq (선택사항, Claude 브릿지 일부에서만 사용)

## 라이선스

MIT
