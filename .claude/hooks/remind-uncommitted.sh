#!/bin/bash
#
# Stop Hook: 커밋되지 않은 변경사항 감지 -> Claude에게 커밋 유도
# v2.0 - Uses session_id from stdin JSON for per-session tracking
#
# 메커니즘: JSON stdout + exit 0 -> 구조화된 decision/reason으로 Claude 자동 계속
#
# 참고: https://code.claude.com/docs/en/hooks
#   Stop 훅 유효 decision 값:
#     {"decision": "block", "reason": "..."} -> Claude가 중지되지 않고 reason에 따라 계속
#     decision 생략 (또는 exit 0만) -> Claude 정상 종료 허용
#   ⚠️ "approve", "warn" 등은 유효하지 않음
#

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Git repo가 아니면 통과 (decision 생략 = 종료 허용)
if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

# stdin에서 session_id와 stop_hook_active 추출
input=$(cat)

if command -v jq &>/dev/null; then
  stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
  SESSION_ID=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
else
  stop_hook_active=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
  SESSION_ID=$(echo "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
fi

if [ "$stop_hook_active" = "True" ] || [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

# No session ID = can't track reliably, let it pass
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Read only THIS session's tracking file
TRACK_SOURCE="/tmp/claude-modified-files-${SESSION_ID}.txt"
TRACK_FILE="/tmp/claude-commit-check-$$.txt"

if [ -f "$TRACK_SOURCE" ]; then
  sort -u "$TRACK_SOURCE" > "$TRACK_FILE" 2>/dev/null || true
else
  exit 0
fi

if [ ! -s "$TRACK_FILE" ]; then
  rm -f "$TRACK_FILE" 2>/dev/null || true
  exit 0
fi

# 커밋되지 않은 파일 필터링
uncommitted_list=""
uncommitted_count=0

while IFS= read -r file; do
  [ -z "$file" ] && continue

  # 절대 경로 -> 상대 경로 변환
  if [[ "$file" == "$PWD/"* ]]; then
    file="${file#"$PWD"/}"
  fi

  # 제외 패턴
  case "$file" in
    .env*|*.log|node_modules/*|.next/*|dist/*) continue ;;
  esac

  # git 상태 확인
  is_uncommitted=false
  if git diff --name-only -- "$file" 2>/dev/null | grep -q .; then
    is_uncommitted=true
  elif git diff --name-only --cached -- "$file" 2>/dev/null | grep -q .; then
    is_uncommitted=true
  elif git ls-files --others --exclude-standard -- "$file" 2>/dev/null | grep -q .; then
    is_uncommitted=true
  fi

  if [ "$is_uncommitted" = true ]; then
    uncommitted_list="$uncommitted_list  - $file\n"
    uncommitted_count=$((uncommitted_count + 1))
  fi
done < "$TRACK_FILE"

rm -f "$TRACK_FILE" 2>/dev/null || true

# 커밋되지 않은 파일이 없으면 종료 허용
# NOTE: Codex flow에서는 이후 stop-check/codex-verify가 같은 세션 트래킹을 계속 사용하므로
# 여기서 TRACK_SOURCE를 지우지 않습니다. 최종 통과 시 run-in-codex.sh가 정리합니다.
if [ "$uncommitted_count" -eq 0 ]; then
  exit 0
fi

# JSON decision:block -> Claude가 중지되지 않고 reason에 따라 자동 계속
reason=$(printf "이 세션에서 수정한 파일 %d개가 아직 커밋되지 않았습니다:\n%b\ngit add와 git commit을 수행하세요. 커밋 메시지는 변경 내용을 요약하여 작성하세요." "$uncommitted_count" "$uncommitted_list")

# JSON 안전하게 출력 (python3으로 이스케이프)
python3 -c "
import json, sys
reason = sys.stdin.read()
print(json.dumps({'decision': 'block', 'reason': reason}))
" <<< "$reason"

exit 0
