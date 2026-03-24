#!/usr/bin/env bash
# stride-hook.sh — Bridges Claude Code hooks to Stride .stride.md hook execution
#
# Called by Claude Code's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the Bash command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | stride-hook.sh <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in PreToolUse context)

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
STRIDE_MD="$PROJECT_DIR/.stride.md"

# Exit early if no phase argument or no .stride.md
[ -n "$PHASE" ] || exit 0
[ -f "$STRIDE_MD" ] || exit 0

# Read Claude Code hook input from stdin
INPUT=$(cat)

# Extract the Bash command from hook JSON
# Try jq first, fall back to sed for environments without jq
if command -v jq > /dev/null 2>&1; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
else
  COMMAND=$(echo "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi

[ -n "$COMMAND" ] || exit 0

# --- Determine which Stride hook to run ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review

HOOK_NAME=""

case "$PHASE" in
  post)
    case "$COMMAND" in
      */api/tasks/claim*)          HOOK_NAME="before_doing" ;;
      */api/tasks/*/mark_reviewed*) HOOK_NAME="after_review" ;;
      */api/tasks/*/complete*)      HOOK_NAME="before_review" ;;
    esac
    ;;
  pre)
    case "$COMMAND" in
      */api/tasks/*/complete*) HOOK_NAME="after_doing" ;;
    esac
    ;;
esac

# Not a Stride API call — exit cleanly
[ -n "$HOOK_NAME" ] || exit 0

# --- Parse .stride.md for the hook section ---
# Extracts lines from the first ```bash code block under ## <hook_name>
COMMANDS=$(awk -v hook="$HOOK_NAME" '
  /^## / {
    if (found) exit
    line = $0
    gsub(/^## /, "", line)
    gsub(/[[:space:]]*$/, "", line)
    if (line == hook) found = 1
    next
  }
  found && /^```bash/ { capture = 1; next }
  found && capture && /^```/ { exit }
  found && capture { print }
' "$STRIDE_MD")

# No commands for this hook — exit cleanly
[ -n "$COMMANDS" ] || exit 0

# --- Execute commands ---
cd "$PROJECT_DIR"

while IFS= read -r cmd; do
  # Trim leading whitespace
  trimmed=$(echo "$cmd" | sed 's/^[[:space:]]*//')

  # Skip empty lines
  [ -z "$trimmed" ] && continue

  # Skip comments
  case "$trimmed" in
    \#*) continue ;;
  esac

  # Execute the command — eval allows variable expansion ($TASK_IDENTIFIER, etc.)
  if ! eval "$trimmed"; then
    echo "Stride $HOOK_NAME hook failed on: $trimmed" >&2
    exit 2
  fi
done <<< "$COMMANDS"

exit 0
