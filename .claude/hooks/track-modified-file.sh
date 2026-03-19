#!/bin/bash
#
# Claude Code File Modification Tracking Hook (PostToolUse)
# Records file paths to a temporary file after Edit/Write tool usage.
# v2.0 - Uses session_id from stdin JSON for per-session tracking
#

# Read JSON input from stdin
input=$(cat)

# Extract session_id from stdin JSON
if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)
  file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
  SESSION_ID=$(echo "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
  file_path=$(echo "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

# No session ID = can't track reliably
if [ -z "$SESSION_ID" ]; then
  echo '{"decision": "approve"}'
  exit 0
fi

# One tracking file per Claude session
TRACK_FILE="/tmp/claude-modified-files-${SESSION_ID}.txt"

# If file path exists, append to tracking file
if [ -n "$file_path" ]; then
  echo "$file_path" >> "$TRACK_FILE"
  sort -u "$TRACK_FILE" -o "$TRACK_FILE" 2>/dev/null || true
fi

echo '{"decision": "approve"}'
exit 0
