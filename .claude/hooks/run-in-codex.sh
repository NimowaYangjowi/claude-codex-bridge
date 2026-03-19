#!/bin/bash
#
# Codex hook bridge for projects configured with .claude/hooks.
# Supports PostToolUse/Stop equivalents, plus manual bridges for
# UserPromptSubmit hooks that Codex doesn't trigger natively.
#
# Usage:
#   bash .claude/hooks/run-in-codex.sh post <file>
#   bash .claude/hooks/run-in-codex.sh changed
#   bash .claude/hooks/run-in-codex.sh prompt "<user prompt>"
#   bash .claude/hooks/run-in-codex.sh todo '[{"content":"task","status":"completed"}]'
#   bash .claude/hooks/run-in-codex.sh stop
#   bash .claude/hooks/run-in-codex.sh all
#   bash .claude/hooks/run-in-codex.sh finalize
#   bash .claude/hooks/run-in-codex.sh reset
#

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

resolve_session_id() {
  local raw="${CLAUDE_SESSION_ID:-${CODEX_THREAD_ID:-codex-default}}"
  raw="$(printf '%s' "$raw" | tr -cd '[:alnum:]_-')"
  if [ -z "$raw" ]; then
    raw="codex-default"
  fi
  printf '%s' "${raw:0:64}"
}

SESSION_ID="$(resolve_session_id)"

# ============================================================
# Hook Lists — customize these for your project
# ============================================================

# PostToolUse hooks (run after Edit/Write/MultiEdit)
POST_HOOKS=(
  "track-modified-file.sh"
  # Add your project-specific PostToolUse hooks here, e.g.:
  # "post-check.sh"
)

# UserPromptSubmit hooks (not auto-triggered in Codex)
# Run manually via: run-in-codex.sh prompt '<prompt text>'
PROMPT_HOOKS=(
  # Add your project-specific prompt hooks here, e.g.:
  # "detect-upload-flow-prompt.sh"
)

# Stop hooks (run at session end)
STOP_HOOKS=(
  "remind-uncommitted.sh"
  "codex-verify.sh"
  "stop/cleanup-verify-state.sh"
  # Add your project-specific stop hooks here, e.g.:
  # "stop-check.sh"
)

# ============================================================
# Core utilities
# ============================================================

print_usage() {
  cat <<'EOF'
Usage:
  bash .claude/hooks/run-in-codex.sh post <file>
  bash .claude/hooks/run-in-codex.sh changed
  bash .claude/hooks/run-in-codex.sh prompt "<user prompt>"  # or pipe via stdin
  bash .claude/hooks/run-in-codex.sh todo '[{"content":"task","status":"completed"}]'
  bash .claude/hooks/run-in-codex.sh stop
  bash .claude/hooks/run-in-codex.sh all
  bash .claude/hooks/run-in-codex.sh finalize
  bash .claude/hooks/run-in-codex.sh reset
EOF
}

abs_path() {
  local target="$1"
  if [ -z "$target" ]; then
    echo ""
    return 0
  fi

  if [ -f "$target" ] || [ -d "$target" ]; then
    echo "$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    return 0
  fi

  if [ -f "$PROJECT_DIR/$target" ] || [ -d "$PROJECT_DIR/$target" ]; then
    echo "$PROJECT_DIR/$target"
    return 0
  fi

  if [[ "$target" = /* ]]; then
    echo "$target"
  else
    echo "$PROJECT_DIR/$target"
  fi
}

json_field() {
  local content="$1"
  local field="$2"
  JSON_CONTENT="$content" JSON_FIELD="$field" python3 - <<'PY'
import json
import os
import re
import sys

raw = os.environ.get("JSON_CONTENT", "")
field = os.environ.get("JSON_FIELD", "")

if not raw.strip() or not field:
    print("")
    sys.exit(0)

obj = None

try:
    obj = json.loads(raw)
except Exception:
    match = re.search(r"\{.*\}", raw, re.S)
    if match:
        try:
            obj = json.loads(match.group(0))
        except Exception:
            obj = None

if not isinstance(obj, dict):
    if field == "decision":
        m = re.search(r'"decision"\s*:\s*"([^"]+)"', raw, re.S)
        print(m.group(1) if m else "")
        sys.exit(0)

    if field == "reason":
        m = re.search(r'"reason"\s*:\s*"(.+)"\s*}\s*$', raw, re.S)
        print(m.group(1).strip() if m else "")
        sys.exit(0)

    print("")
    sys.exit(0)

value = obj.get(field, "")
if value is None:
    value = ""
print(str(value))
PY
}

json_decision() {
  local content="$1"
  json_field "$content" "decision"
}

json_reason() {
  local content="$1"
  json_field "$content" "reason"
}

run_hook_with_payload() {
  local hook_name="$1"
  local payload="$2"
  local hook_path="$SCRIPT_DIR/$hook_name"
  local output
  local decision
  local reason

  if [ ! -f "$hook_path" ]; then
    return 0
  fi

  if [[ "$hook_name" == *.py ]]; then
    output=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_SESSION_ID="$SESSION_ID" python3 "$hook_path" 2>/dev/null || true)
  else
    output=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_SESSION_ID="$SESSION_ID" bash "$hook_path" 2>/dev/null || true)
  fi

  decision="$(json_decision "$output")"
  reason="$(json_reason "$output")"

  if [ -z "$decision" ]; then
    decision="approve"
  fi

  if [ "$decision" = "warn" ] || [ "$decision" = "block" ]; then
    echo "[$decision] $hook_name"
    if [ -n "$reason" ]; then
      echo "$reason"
      echo
    fi
  fi

  if [ "$decision" = "block" ]; then
    return 2
  fi
  return 0
}

build_prompt_payload() {
  local prompt_text="$1"
  SESSION_ID="$SESSION_ID" PROMPT_TEXT="$prompt_text" python3 - <<'PY'
import json
import os

session_id = os.environ.get("SESSION_ID", "codex-default")
prompt = os.environ.get("PROMPT_TEXT", "")

payload = {
    "session_id": session_id,
    "prompt": prompt,
    "user_input": prompt,
}
print(json.dumps(payload, ensure_ascii=False))
PY
}

run_post_hook_with_file() {
  local hook_name="$1"
  local file_path="$2"
  local payload

  payload=$(cat <<EOF
{"tool_name":"Edit","session_id":"$SESSION_ID","tool_input":{"file_path":"$file_path"}}
EOF
)

  run_hook_with_payload "$hook_name" "$payload"
}

run_stop_hook() {
  local hook_name="$1"
  local payload

  payload=$(cat <<EOF
{"session_id":"$SESSION_ID"}
EOF
)

  run_hook_with_payload "$hook_name" "$payload"
}

run_prompt_hook() {
  local hook_name="$1"
  local prompt_text="$2"
  local payload

  payload="$(build_prompt_payload "$prompt_text")"
  run_hook_with_payload "$hook_name" "$payload"
}

run_post_for_file() {
  local target="$1"
  local file_path
  local hook_name
  local rc
  local blocked=0

  file_path="$(abs_path "$target")"
  if [ -z "$file_path" ]; then
    echo "No file provided."
    return 1
  fi

  for hook_name in "${POST_HOOKS[@]}"; do
    rc=0
    run_post_hook_with_file "$hook_name" "$file_path" || rc=$?
    if [ "$rc" -eq 2 ]; then
      blocked=1
    fi
  done

  if [ "$blocked" -eq 1 ]; then
    return 2
  fi
  return 0
}

run_post_for_changed() {
  local changed
  local rel_file
  local hook_name
  local rc
  local blocked=0

  # Use staged files only (pre-commit context)
  changed=$(
    cd "$PROJECT_DIR" && git diff --name-only --cached 2>/dev/null | sort -u
  )

  if [ -z "$changed" ]; then
    echo "No changed files."
    return 0
  fi

  while IFS= read -r rel_file; do
    [ -z "$rel_file" ] && continue
    for hook_name in "${POST_HOOKS[@]}"; do
      rc=0
      run_post_hook_with_file "$hook_name" "$(abs_path "$rel_file")" || rc=$?
      if [ "$rc" -eq 2 ]; then
        blocked=1
      fi
    done
  done <<< "$changed"

  if [ "$blocked" -eq 1 ]; then
    return 2
  fi
  return 0
}

run_prompt_hooks() {
  local prompt_text="$1"
  local hook_name
  local rc
  local blocked=0

  for hook_name in "${PROMPT_HOOKS[@]}"; do
    rc=0
    run_prompt_hook "$hook_name" "$prompt_text" || rc=$?
    if [ "$rc" -eq 2 ]; then
      blocked=1
    fi
  done

  if [ "$blocked" -eq 1 ]; then
    return 2
  fi
  return 0
}

run_stop_hooks() {
  local hook_name
  local rc
  local blocked=0

  for hook_name in "${STOP_HOOKS[@]}"; do
    rc=0
    run_stop_hook "$hook_name" || rc=$?
    if [ "$rc" -eq 2 ]; then
      blocked=1
    fi
  done

  # Cleanup session artifacts on success
  if [ "$blocked" -eq 0 ]; then
    rm -f "/tmp/claude-modified-files-${SESSION_ID}.txt" 2>/dev/null || true
    rm -f "/tmp/claude-test-warned-${SESSION_ID}.txt" 2>/dev/null || true
  fi

  if [ "$blocked" -eq 1 ]; then
    return 2
  fi
  return 0
}

run_finalize_hooks() {
  local rc=0

  # Session-scoped auto-commit
  if [ -f "$SCRIPT_DIR/auto-commit.sh" ]; then
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" CLAUDE_SESSION_ID="$SESSION_ID" bash "$SCRIPT_DIR/auto-commit.sh" || return $?
  else
    echo "[warn] auto-commit.sh not found. Skipping auto-commit."
  fi

  # Run all stop hooks after commit
  run_stop_hooks || rc=$?

  if [ "$rc" -eq 2 ]; then
    return 2
  fi
  return 0
}

reset_session_artifacts() {
  rm -f "/tmp/claude-modified-files-${SESSION_ID}.txt" 2>/dev/null || true
  rm -f "/tmp/claude-commit-check-"*.txt 2>/dev/null || true
  rm -f "/tmp/claude-test-warned-${SESSION_ID}.txt" 2>/dev/null || true
  rm -f "/tmp/claude-codex-verified-${SESSION_ID}" 2>/dev/null || true
  rm -f "/tmp/claude-codex-verify-base-${SESSION_ID}" 2>/dev/null || true
  rm -f "/tmp/claude_verify_implementation_triggered-${SESSION_ID}" 2>/dev/null || true
  rm -f "/tmp/claude_verify_implementation_triggered" 2>/dev/null || true
  echo "Cleared temporary hook state for session: $SESSION_ID"
}

run_todo_hooks() {
  local todos_json="$1"
  local payload
  local hook_name
  local rc
  local blocked=0

  payload=$(cat <<EOF
{"session_id":"$SESSION_ID","todos":$todos_json}
EOF
)

  for hook_name in "save-task-state.py" "check-task-completion.py"; do
    rc=0
    run_hook_with_payload "$hook_name" "$payload" || rc=$?
    if [ "$rc" -eq 2 ]; then
      blocked=1
    fi
  done

  if [ "$blocked" -eq 1 ]; then
    return 2
  fi
  return 0
}

main() {
  local cmd="${1:-}"
  local target="${2:-}"
  local rc=0
  local stdin_data=""

  cd "$PROJECT_DIR" || exit 1

  case "$cmd" in
    post)
      if [ -z "$target" ]; then
        print_usage
        exit 1
      fi
      run_post_for_file "$target"
      ;;
    changed)
      run_post_for_changed
      ;;
    prompt)
      if [ -z "$target" ]; then
        stdin_data="$(cat)"
        target="$stdin_data"
      fi
      if [ -z "$target" ]; then
        echo "No prompt text provided."
        exit 1
      fi
      run_prompt_hooks "$target" || rc=$?
      if [ "$rc" -eq 2 ]; then
        exit 2
      fi
      ;;
    todo)
      if [ -z "$target" ]; then
        stdin_data="$(cat)"
        target="$stdin_data"
      fi
      if [ -z "$target" ]; then
        target="[]"
      fi
      run_todo_hooks "$target" || rc=$?
      if [ "$rc" -eq 2 ]; then
        exit 2
      fi
      ;;
    stop)
      run_stop_hooks || rc=$?
      if [ "$rc" -eq 2 ]; then
        exit 2
      fi
      ;;
    all)
      run_post_for_changed || rc=$?
      if [ "$rc" -eq 2 ]; then
        exit 2
      fi
      run_stop_hooks
      ;;
    finalize)
      run_post_for_changed || rc=$?
      if [ "$rc" -eq 2 ]; then
        exit 2
      fi
      run_finalize_hooks || rc=$?
      if [ "$rc" -eq 2 ]; then
        exit 2
      fi
      ;;
    reset)
      reset_session_artifacts
      ;;
    *)
      print_usage
      exit 1
      ;;
  esac
}

main "$@"
