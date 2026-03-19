#!/bin/bash
#
# Codex auto-commit hook (Finalize)
# Commits only files tracked for the current Codex/Claude session.
#

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SESSION_ID="${CLAUDE_SESSION_ID:-}"

cd "$PROJECT_DIR"

if ! git rev-parse --git-dir &>/dev/null; then
  exit 0
fi

if [ -z "$SESSION_ID" ]; then
  echo "[warn] CLAUDE_SESSION_ID is empty. Skipping auto-commit."
  exit 0
fi

TRACK_FILE="/tmp/claude-modified-files-${SESSION_ID}.txt"
if [ ! -s "$TRACK_FILE" ]; then
  exit 0
fi

TMP_FILE="/tmp/claude-commit-files-${SESSION_ID}-$$.txt"
sort -u "$TRACK_FILE" > "$TMP_FILE" 2>/dev/null || true

if [ ! -s "$TMP_FILE" ]; then
  rm -f "$TMP_FILE" 2>/dev/null || true
  exit 0
fi

should_skip_path() {
  local path="$1"
  case "$path" in
    .env|.env.*|*.log|node_modules/*|.next/*|dist/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_path() {
  local path="$1"
  if [[ "$path" == "$PROJECT_DIR/"* ]]; then
    path="${path#"$PROJECT_DIR"/}"
  fi
  printf '%s' "$path"
}

files_to_stage=()
while IFS= read -r raw_file; do
  [ -z "$raw_file" ] && continue

  rel_file="$(normalize_path "$raw_file")"
  [ -z "$rel_file" ] && continue

  if should_skip_path "$rel_file"; then
    continue
  fi

  if [ -e "$rel_file" ] || git ls-files --error-unmatch -- "$rel_file" &>/dev/null; then
    files_to_stage+=("$rel_file")
  fi
done < "$TMP_FILE"

rm -f "$TMP_FILE" 2>/dev/null || true

if [ "${#files_to_stage[@]}" -eq 0 ]; then
  exit 0
fi

for file in "${files_to_stage[@]}"; do
  if [ -e "$file" ]; then
    git add -- "$file" 2>/dev/null || true
  else
    git add -u -- "$file" 2>/dev/null || true
  fi
done

if git diff --cached --quiet; then
  exit 0
fi

file_count="${#files_to_stage[@]}"
if [ "$file_count" -eq 1 ]; then
  commit_message="refactor: update $(basename "${files_to_stage[0]}") via Codex hooks"
else
  commit_message="refactor: update ${file_count} files via Codex hooks"
fi

if ! SKIP_CODEX_PRE_COMMIT=1 git commit -m "$commit_message" 2>/dev/null; then
  echo "[warn] Auto-commit failed for ${file_count} file(s)."
  exit 1
fi
echo "Auto-commit attempted for ${file_count} file(s)."

exit 0
