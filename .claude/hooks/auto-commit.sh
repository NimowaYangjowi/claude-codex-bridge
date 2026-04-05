#!/bin/bash
#
# Codex auto-commit hook (Finalize)
# Commits only files tracked for the current Codex/Claude session.
#

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_PATH="$PROJECT_DIR/scripts/hooks/session_delta.py"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "[warn] session_delta.py not found. Skipping auto-commit."
  exit 0
fi

if ! CLAUDE_PROJECT_DIR="$PROJECT_DIR" python3 "$SCRIPT_PATH" commit-session-delta; then
  echo "[warn] Auto-commit failed for this session."
  exit 1
fi

exit 0
