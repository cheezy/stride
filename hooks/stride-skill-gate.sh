#!/usr/bin/env bash
# stride-skill-gate.sh — PreToolUse(Skill) gate for Stride sub-skills.
#
# Blocks direct invocations of internal Stride sub-skills unless the
# stride-workflow orchestrator wrote an activation marker at
# $CLAUDE_PROJECT_DIR/.stride/.orchestrator_active
#
# Marker shape: {"session_id":"<id>","started_at":"<ISO8601-Z>","pid":<int>}
# Marker is "fresh" if `started_at` is within the last 4 hours.
#
# Allow-pass conditions (exit 0 silent):
#   - STRIDE_ALLOW_DIRECT=1 set in the environment
#   - skill is empty / missing in tool_input
#   - skill is stride-workflow itself (the orchestrator)
#   - skill is not in the protected sub-skill list (non-Stride or unrelated)
#   - marker exists, is parseable, and started_at is within 4h of now
#
# Block conditions (exit 2 + structured JSON on stdout, human msg on stderr):
#   - skill is in the protected list AND marker is missing/stale/unparseable
#
# Exit codes:
#   0 — allowed
#   2 — blocked (Claude Code interprets exit 2 from PreToolUse as block)

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# --- Platform detection: delegate to PowerShell on native Windows ---
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-skill-gate.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-skill-gate.sh: Windows detected but stride-skill-gate.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-skill-gate.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT"
fi

# --- Override: bypass entirely for plugin debugging / scripted CI ---
if [ "${STRIDE_ALLOW_DIRECT:-}" = "1" ]; then
  exit 0
fi

# --- Read Claude Code hook input from stdin ---
INPUT=$(cat)

# --- Detect jq once ---
HAS_JQ=false
command -v jq > /dev/null 2>&1 && HAS_JQ=true

# --- Extract tool_input.skill ---
if [ "$HAS_JQ" = "true" ]; then
  SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // ""' 2>/dev/null || echo "")
else
  # Pure-bash fallback: find "skill" : "value"
  _tmp="${INPUT#*\"skill\"}"
  if [ "$_tmp" = "$INPUT" ]; then
    SKILL=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    SKILL="${_tmp%%\"*}"
  fi
fi

# Not a Skill invocation, or skill name unparseable — not our concern.
if [ -z "$SKILL" ]; then
  exit 0
fi

# --- Normalize: strip optional plugin prefix for matching ---
BASE_NAME="${SKILL#stride:}"

# --- Allow-list short circuit ---
# Orchestrator itself: always allowed.
if [ "$BASE_NAME" = "stride-workflow" ]; then
  exit 0
fi

# Protected sub-skills — anything else exits 0 silently.
case "$BASE_NAME" in
  stride-claiming-tasks|stride-completing-tasks|stride-creating-tasks|stride-creating-goals|stride-enriching-tasks|stride-subagent-workflow)
    : # fall through to marker check
    ;;
  *)
    exit 0
    ;;
esac

# --- Block helper ---
emit_block() {
  reason="$1"
  if [ "$HAS_JQ" = "true" ]; then
    jq -nc --arg r "$reason" '{decision:"block",reason:$r}'
  else
    # Hand-rolled JSON. Reason is a static format string from below — no
    # caller-controlled data is interpolated, so escape rules are simple.
    printf '{"decision":"block","reason":"%s"}\n' "$reason"
  fi
  printf 'stride-skill-gate: %s\n' "$reason" >&2
  exit 2
}

MARKER="$PROJECT_DIR/.stride/.orchestrator_active"

# --- Marker missing → block ---
if [ ! -f "$MARKER" ]; then
  emit_block "Stride sub-skill '$SKILL' can only be invoked from inside stride:stride-workflow. Invoke stride:stride-workflow first; the orchestrator will dispatch this skill at the appropriate phase. (Set STRIDE_ALLOW_DIRECT=1 to bypass.)"
fi

# --- Read started_at from marker ---
MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null || echo "")
if [ "$HAS_JQ" = "true" ]; then
  STARTED=$(printf '%s' "$MARKER_CONTENT" | jq -r '.started_at // ""' 2>/dev/null || echo "")
else
  _tmp="${MARKER_CONTENT#*\"started_at\"}"
  if [ "$_tmp" = "$MARKER_CONTENT" ]; then
    STARTED=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    STARTED="${_tmp%%\"*}"
  fi
fi

if [ -z "$STARTED" ]; then
  emit_block "Stride orchestrator marker is invalid (missing or empty started_at). Re-invoke stride:stride-workflow to refresh."
fi

# --- Freshness check (portable across GNU date and BSD/macOS date) ---
NOW=$(date -u +%s)
STARTED_SEC=$(date -u -d "$STARTED" +%s 2>/dev/null) \
  || STARTED_SEC=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED" +%s 2>/dev/null) \
  || STARTED_SEC=""

if [ -z "$STARTED_SEC" ]; then
  emit_block "Stride orchestrator marker has unparseable started_at ('$STARTED'). Re-invoke stride:stride-workflow to refresh."
fi

AGE=$(( NOW - STARTED_SEC ))
if [ "$AGE" -lt 0 ] || [ "$AGE" -gt 14400 ]; then
  emit_block "Stride orchestrator marker is stale or in the future (age ${AGE}s; max 14400s). Re-invoke stride:stride-workflow to refresh."
fi

# --- Allowed ---
exit 0
