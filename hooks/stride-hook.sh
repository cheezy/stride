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
ENV_CACHE="$PROJECT_DIR/.stride-env-cache"

# --- Debug logging (enabled unless STRIDE_HOOK_DEBUG=0) ---
# Writes one line per event to $PROJECT_DIR/.stride-hook.log so operators can
# verify whether Claude Code is invoking the hook at all and trace which
# branch causes a silent exit. Log file is safe to delete; add to .gitignore.
_stride_debug_log_file="$PROJECT_DIR/.stride-hook.log"
_stride_debug() {
  [ "${STRIDE_HOOK_DEBUG:-1}" = "0" ] && return 0
  local _ts
  _ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
  printf '[%s pid=%d phase=%s] %s\n' "$_ts" "$$" "${PHASE:-?}" "$*" \
    >> "$_stride_debug_log_file" 2>/dev/null || true
}
_stride_debug "FIRED argv='${*:-<empty>}' cwd=$(pwd) CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>}"

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-hook.sh: Windows detected but stride-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# Exit early if no phase argument or no .stride.md
if [ -z "$PHASE" ]; then
  _stride_debug "EXIT early: no PHASE argument"
  exit 0
fi
if [ ! -f "$STRIDE_MD" ]; then
  _stride_debug "EXIT early: no .stride.md at $STRIDE_MD"
  exit 0
fi

# Read Claude Code hook input from stdin
INPUT=$(cat)
_stride_debug "INPUT bytes=${#INPUT} head='$(printf '%s' "$INPUT" | head -c 300 | tr '\n' ' ')'"

# Detect jq availability once
HAS_JQ=false
command -v jq > /dev/null 2>&1 && HAS_JQ=true

# Extract the Bash command from hook JSON
# Try jq first, fall back to pure bash for environments without jq
if [ "$HAS_JQ" = "true" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
else
  # Pure bash JSON extraction: find "command" : "value"
  _tmp="${INPUT#*\"command\"}"
  # If the expansion didn't change, the key wasn't found
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
fi

_stride_debug "COMMAND has_jq=$HAS_JQ len=${#COMMAND} value='$(printf '%s' "$COMMAND" | head -c 300 | tr '\n' ' ')'"

if [ -z "$COMMAND" ]; then
  _stride_debug "EXIT early: COMMAND extraction returned empty (tool_input shape may have changed)"
  exit 0
fi

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

_stride_debug "ROUTE phase=$PHASE → HOOK_NAME='${HOOK_NAME:-<none>}'"

# Not a Stride API call — exit cleanly
if [ -z "$HOOK_NAME" ]; then
  _stride_debug "EXIT: command did not match any Stride API URL pattern"
  exit 0
fi

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if [ "$HOOK_NAME" = "before_doing" ] && [ "$HAS_JQ" = "true" ]; then
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
  _stride_debug "ENV_CACHE attempt: RESPONSE len=${#RESPONSE} head='$(printf '%s' "$RESPONSE" | head -c 200 | tr '\n' ' ')'"
  if [ -n "$RESPONSE" ]; then
    # Claude Code wraps Bash tool output as {"stdout":"<json>","stderr":"...",...}
    # so the API JSON we want lives inside .tool_response.stdout as a string.
    # Other harnesses may pass the API JSON directly. Try both shapes.
    TASK_JSON=""
    INNER=""

    # Shape 1: {"stdout":"<json>"} — Claude Code Bash tool
    if echo "$RESPONSE" | jq -e 'type == "object" and has("stdout")' > /dev/null 2>&1; then
      INNER=$(echo "$RESPONSE" | jq -r '.stdout // ""' 2>/dev/null)
      if [ -n "$INNER" ] && echo "$INNER" | jq -e '.data.id' > /dev/null 2>&1; then
        TASK_JSON=$(echo "$INNER" | jq -c '.data' 2>/dev/null)
        _stride_debug "ENV_CACHE: parsed tool_response.stdout as {data:{id:...}}"
      elif [ -n "$INNER" ] && echo "$INNER" | jq -e '.id' > /dev/null 2>&1; then
        TASK_JSON="$INNER"
        _stride_debug "ENV_CACHE: parsed tool_response.stdout as flat {id:...}"
      fi
    fi

    # Shape 2: raw API JSON directly in tool_response (other harnesses)
    if [ -z "$TASK_JSON" ] && echo "$RESPONSE" | jq -e '.data.id' > /dev/null 2>&1; then
      TASK_JSON=$(echo "$RESPONSE" | jq -c '.data' 2>/dev/null)
      _stride_debug "ENV_CACHE: parsed tool_response as {data:{id:...}}"
    elif [ -z "$TASK_JSON" ] && echo "$RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
      TASK_JSON="$RESPONSE"
      _stride_debug "ENV_CACHE: parsed tool_response as flat {id:...}"
    fi

    if [ -z "$TASK_JSON" ]; then
      _stride_debug "ENV_CACHE: tool_response did not contain .data.id or .id (checked .stdout and root) — cache not written"
    fi

    if [ -n "$TASK_JSON" ]; then
      # Values are single-quoted to handle spaces in titles/descriptions
      {
        echo "TASK_ID='$(echo "$TASK_JSON" | jq -r '.id // empty')'"
        echo "TASK_IDENTIFIER='$(echo "$TASK_JSON" | jq -r '.identifier // empty')'"
        echo "TASK_TITLE='$(echo "$TASK_JSON" | jq -r '.title // empty')'"
        echo "TASK_STATUS='$(echo "$TASK_JSON" | jq -r '.status // empty')'"
        echo "TASK_COMPLEXITY='$(echo "$TASK_JSON" | jq -r '.complexity // empty')'"
        echo "TASK_PRIORITY='$(echo "$TASK_JSON" | jq -r '.priority // empty')'"
      } > "$ENV_CACHE" 2>/dev/null || true
      _stride_debug "ENV_CACHE written to $ENV_CACHE"
    fi
  else
    _stride_debug "ENV_CACHE skipped: empty tool_response (Claude Code may not expose it on this call path)"
  fi
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  set -a
  . "$ENV_CACHE" 2>/dev/null || true
  set +a
fi

# --- Parse .stride.md for the hook section ---
# Extracts lines from the first ```bash code block under ## <hook_name>
# Uses pure bash to avoid awk/sed dependency (not available on all platforms)
COMMANDS=""
_found=0
_capture=0
while IFS= read -r _line || [ -n "$_line" ]; do
  # Check for ## heading
  case "$_line" in
    "## "*)
      [ "$_found" -eq 1 ] && break
      _section="${_line#\#\# }"
      # Trim trailing whitespace
      _section="${_section%"${_section##*[![:space:]]}"}"
      [ "$_section" = "$HOOK_NAME" ] && _found=1
      continue
      ;;
  esac
  if [ "$_found" -eq 1 ]; then
    case "$_line" in
      '```bash'*) _capture=1; continue ;;
      '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
    esac
    [ "$_capture" -eq 1 ] && COMMANDS="${COMMANDS}${_line}
"
  fi
done < "$STRIDE_MD"

# No commands for this hook — exit cleanly
if [ -z "$COMMANDS" ]; then
  _stride_debug "EXIT: no commands parsed from .stride.md '## $HOOK_NAME' section"
  exit 0
fi

# --- Build command list for tracking ---
# Split commands into an array for structured output
CMD_LIST=()
while IFS= read -r cmd; do
  trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
  [ -z "$trimmed" ] && continue
  case "$trimmed" in \#*) continue ;; esac
  CMD_LIST+=("$trimmed")
done <<< "$COMMANDS"

# Nothing to execute after filtering
if [ ${#CMD_LIST[@]} -eq 0 ]; then
  _stride_debug "EXIT: '## $HOOK_NAME' section found but all lines were blank or comments"
  exit 0
fi

_stride_debug "EXECUTE: $HOOK_NAME has ${#CMD_LIST[@]} command(s) queued"

# --- Execute commands with structured output ---
# Use temp files instead of bash arrays to avoid set -u issues with empty arrays
cd "$PROJECT_DIR"
COMPLETED_FILE=$(mktemp)
START_SECS=$(date +%s)
CMD_INDEX=0
CMD_TOTAL=${#CMD_LIST[@]}

for trimmed in "${CMD_LIST[@]}"; do
  _stride_debug "EXEC [$((CMD_INDEX + 1))/$CMD_TOTAL]: $trimmed"
  # Capture stdout and stderr separately
  CMD_STDOUT_FILE=$(mktemp)
  CMD_STDERR_FILE=$(mktemp)

  # Relax `set -u` and `pipefail` for the user's command so that a reference
  # to an unset env var (e.g. $TASK_IDENTIFIER when env-cache failed to write)
  # doesn't silently abort the eval before the actual command runs. The hook
  # script's strictness re-engages immediately after.
  set +uo pipefail
  eval "$trimmed" > "$CMD_STDOUT_FILE" 2> "$CMD_STDERR_FILE"
  CMD_EXIT=$?
  set -uo pipefail

  CMD_STDOUT_LEN=$(wc -c < "$CMD_STDOUT_FILE" 2>/dev/null | tr -d ' ')
  CMD_STDERR_LEN=$(wc -c < "$CMD_STDERR_FILE" 2>/dev/null | tr -d ' ')
  _stride_debug "EXEC RESULT [$((CMD_INDEX + 1))/$CMD_TOTAL] exit=$CMD_EXIT stdout_bytes=${CMD_STDOUT_LEN:-0} stderr_bytes=${CMD_STDERR_LEN:-0}"

  if [ "$CMD_EXIT" -eq 0 ]; then
    echo "$trimmed" >> "$COMPLETED_FILE"
    # Print command output to stderr so Claude sees it as feedback
    cat "$CMD_STDOUT_FILE" >&2
    cat "$CMD_STDERR_FILE" >&2
  else
    _stride_debug "EXEC FAILED [$((CMD_INDEX + 1))/$CMD_TOTAL] exit=$CMD_EXIT: $trimmed"
    CMD_STDOUT=$(tail -50 "$CMD_STDOUT_FILE")
    CMD_STDERR=$(tail -50 "$CMD_STDERR_FILE")
    rm -f "$CMD_STDOUT_FILE" "$CMD_STDERR_FILE"

    # Build remaining commands as a temp file
    REMAINING_FILE=$(mktemp)
    if [ $((CMD_INDEX + 1)) -lt $CMD_TOTAL ]; then
      for ((i = CMD_INDEX + 1; i < CMD_TOTAL; i++)); do
        echo "${CMD_LIST[$i]}" >> "$REMAINING_FILE"
      done
    fi

    # Emit structured JSON on stdout for Claude to parse
    if [ "$HAS_JQ" = "true" ]; then
      COMPLETED_JSON=$(jq -R . < "$COMPLETED_FILE" | jq -s . 2>/dev/null || echo "[]")
      REMAINING_JSON=$(jq -R . < "$REMAINING_FILE" | jq -s . 2>/dev/null || echo "[]")

      jq -n \
        --arg hook "$HOOK_NAME" \
        --arg failed "$trimmed" \
        --argjson index "$CMD_INDEX" \
        --argjson exit_code "$CMD_EXIT" \
        --arg stdout "$CMD_STDOUT" \
        --arg stderr "$CMD_STDERR" \
        --argjson completed "$COMPLETED_JSON" \
        --argjson remaining "$REMAINING_JSON" \
        '{
          hook: $hook,
          status: "failed",
          failed_command: $failed,
          command_index: $index,
          exit_code: $exit_code,
          stdout: $stdout,
          stderr: $stderr,
          commands_completed: $completed,
          commands_remaining: $remaining
        }'
    else
      # Fallback: plain text structured output
      echo "HOOK=$HOOK_NAME STATUS=failed COMMAND=$trimmed EXIT=$CMD_EXIT"
    fi

    # Human-readable error on stderr for Claude's feedback
    echo "Stride $HOOK_NAME hook failed on command $((CMD_INDEX + 1))/$CMD_TOTAL: $trimmed" >&2
    [ -n "$CMD_STDERR" ] && echo "$CMD_STDERR" >&2
    rm -f "$COMPLETED_FILE" "$REMAINING_FILE"
    exit 2
  fi

  rm -f "$CMD_STDOUT_FILE" "$CMD_STDERR_FILE"
  CMD_INDEX=$((CMD_INDEX + 1))
done

# --- Success output ---
END_SECS=$(date +%s)
DURATION=$((END_SECS - START_SECS))
_stride_debug "SUCCESS: $HOOK_NAME completed ${CMD_TOTAL} command(s) in ${DURATION}s"

if [ "$HAS_JQ" = "true" ]; then
  COMPLETED_JSON=$(jq -R . < "$COMPLETED_FILE" | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg hook "$HOOK_NAME" \
    --argjson duration "$DURATION" \
    --argjson completed "$COMPLETED_JSON" \
    '{
      hook: $hook,
      status: "success",
      commands_completed: $completed,
      duration_seconds: $duration
    }'
fi

rm -f "$COMPLETED_FILE"

# Clean up env cache after the final hook in the lifecycle
if [ "$HOOK_NAME" = "after_review" ] && [ -f "$ENV_CACHE" ]; then
  rm -f "$ENV_CACHE"
fi

exit 0
