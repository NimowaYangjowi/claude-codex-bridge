#!/bin/bash
# Cleanup verification state files on session end
# Updated: 2026-02-21 - session_id based tracking

# Extract session_id from stdin JSON
input=$(cat)
if command -v jq &>/dev/null; then
  SESSION_ID_RAW=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
else
  SESSION_ID_RAW=$(echo "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
fi

SESSION_ID="$(printf '%s' "$SESSION_ID_RAW" | tr -cd '[:alnum:]_-')"
[ -z "$SESSION_ID" ] && SESSION_ID="default"
SESSION_ID="${SESSION_ID:0:64}"

# Session-scoped state
# NOTE: Do NOT delete claude-modified-files here!
# Codex bridge(run-in-codex.sh)가 최종 통과 시점에 정리합니다.
# 여기서 지우면 block 재시도 플로우에서 tracking을 잃을 수 있습니다.
rm -f "/tmp/claude_verify_implementation_triggered-${SESSION_ID}" 2>/dev/null || true
rm -f "/tmp/claude-test-warned-${SESSION_ID_RAW}.txt" 2>/dev/null || true
rm -f "/tmp/claude-codex-verified-${SESSION_ID}" 2>/dev/null || true
rm -f "/tmp/claude-codex-verify-base-${SESSION_ID}" 2>/dev/null || true
# Legacy global state (backward compatibility)
rm -f /tmp/claude_verify_implementation_triggered 2>/dev/null || true

exit 0
