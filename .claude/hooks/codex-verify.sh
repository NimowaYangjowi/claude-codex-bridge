#!/bin/bash
#
# Stop Hook: Codex 자동 검증
# 세션에서 수정한 src/ 파일이 있으면 Claude에게 Codex 리뷰를 위임하도록 블록
#
# Flow:
#   1. 세션 트래킹 파일에서 src/**/*.{ts,tsx} 변경 필터링
#   2. 이미 검증 완료(dedup 플래그)면 스킵
#   3. 변경 있으면 block + [CODEX-VERIFY] 키워드 출력
#   4. Claude가 키워드 감지 → mcp__codex__codex 호출 → 검증 완료 시 dedup 플래그 생성
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_DIR" || exit 0

# stdin JSON 파싱
input=$(cat)

if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
  stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)
else
  SESSION_ID=$(echo "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
  stop_hook_active=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
fi

# 재귀 방지: stop_hook_active이면 통과
if [ "$stop_hook_active" = "True" ] || [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

# 세션 ID 없으면 통과
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Dedup: 이미 검증 완료면 통과
VERIFIED_FLAG="/tmp/claude-codex-verified-${SESSION_ID}"
if [ -f "$VERIFIED_FLAG" ]; then
  exit 0
fi

# Baseline: 첫 Codex 검증 요구 시점의 HEAD를 저장해 두고,
# 이후 "fix: address Codex review findings" 커밋이 생기면 자동 통과 처리.
BASELINE_FILE="/tmp/claude-codex-verify-base-${SESSION_ID}"

# 세션 트래킹 파일에서 변경된 src/ 파일 수집
TRACK_SOURCE="/tmp/claude-modified-files-${SESSION_ID}.txt"
if [ ! -f "$TRACK_SOURCE" ]; then
  exit 0
fi

# src/ 하위 .ts/.tsx 파일만 필터 (테스트/스토리/타입 선언 제외)
src_files=$(grep -E "src/.*\.(ts|tsx)$" "$TRACK_SOURCE" 2>/dev/null \
  | grep -vE "\.(test|spec|stories)\.(ts|tsx)$" \
  | grep -vE "__tests__/" \
  | grep -vE "\.d\.ts$" \
  | sed "s|^${PROJECT_DIR}/||" \
  | sort -u)

if [ -z "$src_files" ]; then
  exit 0
fi

current_head=$(git rev-parse HEAD 2>/dev/null || true)

# If we already have a baseline and review-fix commit exists after it, mark verified.
if [ -f "$BASELINE_FILE" ]; then
  baseline_head=$(cat "$BASELINE_FILE" 2>/dev/null || true)
  if [ -n "$baseline_head" ] && [ -n "$current_head" ] && [ "$baseline_head" != "$current_head" ]; then
    if git log --format=%s "${baseline_head}..${current_head}" 2>/dev/null | grep -qiE '^fix: address codex review findings$'; then
      touch "$VERIFIED_FLAG"
      exit 0
    fi
  fi
elif [ -n "$current_head" ]; then
  echo "$current_head" > "$BASELINE_FILE"
fi

file_count=$(echo "$src_files" | wc -l | tr -d ' ')
file_list=$(echo "$src_files" | head -20)

# Block + [CODEX-VERIFY] 키워드 출력
reason=$(printf "[CODEX-VERIFY]
이 세션에서 수정한 src/ 파일 %d개에 대해 Codex 자동 검증이 필요합니다.

변경된 파일:
%s

Codex에게 변경 사항을 리뷰 위임하세요.
리뷰 수정 반영 후 커밋 메시지는 다음 형식을 사용하세요:
fix: address Codex review findings" "$file_count" "$file_list")

python3 -c "
import json, sys
reason = sys.stdin.read()
print(json.dumps({'decision': 'block', 'reason': reason}))
" <<< "$reason"

exit 0
