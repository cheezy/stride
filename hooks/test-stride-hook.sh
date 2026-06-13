#!/usr/bin/env bash
# test-stride-hook.sh — Tests for stride-hook.sh pure bash replacements
#
# Tests all code paths without requiring awk, sed, or seq.
# Simulates jq-absent environments to exercise fallback paths.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stride-hook.sh"

# Colors (if terminal supports them)
RED=""
GREEN=""
RESET=""
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  RESET='\033[0m'
fi

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected: $(echo "$expected" | head -5)"
    echo "    actual:   $(echo "$actual" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $(echo "$haystack" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    echo -e "  ${GREEN}PASS${RESET}: $label (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected exit: $expected"
    echo "    actual exit:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================
# Setup: create temp directory with test fixtures
# ============================================================
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Test .stride.md files ---

cat > "$TMPDIR_TEST/basic.stride.md" << 'STRIDE'
## before_doing
```bash
echo "pulling latest"
echo "getting deps"
```

## after_doing
```bash
echo "running tests"
echo "running credo"
```

## before_review
```bash
echo "creating pr"
```

## after_review
```bash
echo "deploying"
```
STRIDE

cat > "$TMPDIR_TEST/with-comments.stride.md" << 'STRIDE'
## before_doing
```bash
# This is a comment
echo "step one"
   echo "indented step"
echo "step three"
# Another comment
```
STRIDE

cat > "$TMPDIR_TEST/no-hook.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing here"
```
STRIDE

cat > "$TMPDIR_TEST/empty-block.stride.md" << 'STRIDE'
## after_doing
```bash
```
STRIDE

cat > "$TMPDIR_TEST/trailing-whitespace.stride.md" << 'STRIDE'
## before_doing
```bash
echo "found despite trailing whitespace"
```
STRIDE

cat > "$TMPDIR_TEST/multiple-code-blocks.stride.md" << 'STRIDE'
## before_doing

Some documentation text here.

```bash
echo "first command"
echo "second command"
```

More text and another block that should be ignored:

```bash
echo "should not appear"
```
STRIDE

cat > "$TMPDIR_TEST/no-bash-block.stride.md" << 'STRIDE'
## before_doing

Just some text, no code block.

## after_doing
```bash
echo "after_doing works"
```
STRIDE

cat > "$TMPDIR_TEST/adjacent-sections.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before"
```
## after_doing
```bash
echo "after"
```
STRIDE

cat > "$TMPDIR_TEST/after-goal-present.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing"
```

## after_goal
```bash
echo "goal $GOAL_IDENTIFIER finished"
./scripts/notify-team.sh "$GOAL_TITLE"
```
STRIDE

cat > "$TMPDIR_TEST/after-goal-missing.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing only — no after_goal"
```

## after_doing
```bash
echo "after_doing only"
```
STRIDE

cat > "$TMPDIR_TEST/after-goal-duplicate.stride.md" << 'STRIDE'
## after_goal
```bash
echo "first wins"
```

## after_goal
```bash
echo "second loses"
```
STRIDE

# ============================================================
# Test Group 1: Pure bash JSON extraction (no-jq fallback)
# ============================================================
echo ""
echo "=== Test Group 1: JSON command extraction (no-jq fallback) ==="

# We test the extraction logic in isolation by inlining the same bash
# parameter expansion used in the script.

extract_command_bash() {
  local INPUT="$1"
  local _tmp COMMAND
  _tmp="${INPUT#*\"command\"}"
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
  echo "$COMMAND"
}

# 1a: Standard claim command
INPUT='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "standard claim URL" \
  "curl -X POST https://stridelikeaboss.com/api/tasks/claim" \
  "$RESULT"

# 1b: Complete command with task ID
INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "complete URL with ID" \
  "curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete" \
  "$RESULT"

# 1c: mark_reviewed command
INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/456/mark_reviewed"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "mark_reviewed URL" \
  "curl -X PATCH https://stridelikeaboss.com/api/tasks/456/mark_reviewed" \
  "$RESULT"

# 1d: No command key present
INPUT='{"tool_input":{"other_key":"some value"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "no command key returns empty" "" "$RESULT"

# 1e: Empty command value
INPUT='{"tool_input":{"command":""}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "empty command value" "" "$RESULT"

# 1f: Command with spaces in URL params
INPUT='{"tool_input":{"command":"curl -H Authorization: Bearer token123 https://example.com/api/tasks/claim"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "command with spaces" \
  "curl -H Authorization: Bearer token123 https://example.com/api/tasks/claim" \
  "$RESULT"

# 1g: JSON with whitespace around colon
INPUT='{"tool_input":{ "command" : "curl https://example.com/api/tasks/claim" }}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "whitespace around colon" \
  "curl https://example.com/api/tasks/claim" \
  "$RESULT"

# 1h: Completely unrelated JSON
INPUT='{"foo":"bar","baz":42}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "unrelated JSON returns empty" "" "$RESULT"

# ============================================================
# Test Group 2: .stride.md parser (pure bash while-read loop)
# ============================================================
echo ""
echo "=== Test Group 2: .stride.md section parser ==="

# Inline the parser logic as a function for isolated testing
parse_stride_md() {
  local STRIDE_MD="$1" HOOK_NAME="$2"
  local COMMANDS="" _found=0 _capture=0 _line _section

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _section="${_line#\#\# }"
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

  printf '%s' "$COMMANDS"
}

# 2a: Parse before_doing from basic file
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_doing")
assert_contains "basic: before_doing line 1" 'echo "pulling latest"' "$RESULT"
assert_contains "basic: before_doing line 2" 'echo "getting deps"' "$RESULT"

# 2b: Parse after_doing from basic file
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "after_doing")
assert_contains "basic: after_doing line 1" 'echo "running tests"' "$RESULT"
assert_contains "basic: after_doing line 2" 'echo "running credo"' "$RESULT"

# 2c: Parse before_review
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_review")
assert_contains "basic: before_review" 'echo "creating pr"' "$RESULT"

# 2d: Parse after_review
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "after_review")
assert_contains "basic: after_review" 'echo "deploying"' "$RESULT"

# 2e: Doesn't bleed between sections
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_doing")
if echo "$RESULT" | grep -qF "running tests"; then
  echo -e "  ${RED}FAIL${RESET}: sections should not bleed into each other"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: sections do not bleed into each other"
  PASS=$((PASS + 1))
fi

# 2f: Hook not present in file
RESULT=$(parse_stride_md "$TMPDIR_TEST/no-hook.stride.md" "after_doing")
assert_eq "missing hook returns empty" "" "$RESULT"

# 2g: Empty code block
RESULT=$(parse_stride_md "$TMPDIR_TEST/empty-block.stride.md" "after_doing")
assert_eq "empty code block returns empty" "" "$RESULT"

# 2h: Comments and indentation are preserved (filtered later by CMD_LIST loop)
RESULT=$(parse_stride_md "$TMPDIR_TEST/with-comments.stride.md" "before_doing")
assert_contains "comments preserved in raw output" "# This is a comment" "$RESULT"
assert_contains "indented line preserved" 'echo "indented step"' "$RESULT"

# 2i: Trailing whitespace on section name
RESULT=$(parse_stride_md "$TMPDIR_TEST/trailing-whitespace.stride.md" "before_doing")
assert_contains "trailing whitespace trimmed from heading" 'echo "found despite trailing whitespace"' "$RESULT"

# 2j: Only first code block is captured
RESULT=$(parse_stride_md "$TMPDIR_TEST/multiple-code-blocks.stride.md" "before_doing")
assert_contains "first block captured" 'echo "first command"' "$RESULT"
if echo "$RESULT" | grep -qF "should not appear"; then
  echo -e "  ${RED}FAIL${RESET}: second code block should not be captured"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: second code block is ignored"
  PASS=$((PASS + 1))
fi

# 2k: Section with no bash block
RESULT=$(parse_stride_md "$TMPDIR_TEST/no-bash-block.stride.md" "before_doing")
assert_eq "no bash block returns empty" "" "$RESULT"

# 2l: Adjacent sections (no blank line between)
RESULT=$(parse_stride_md "$TMPDIR_TEST/adjacent-sections.stride.md" "before_doing")
assert_contains "adjacent: before_doing correct" 'echo "before"' "$RESULT"
if echo "$RESULT" | grep -qF 'echo "after"'; then
  echo -e "  ${RED}FAIL${RESET}: adjacent sections should not bleed"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: adjacent sections do not bleed"
  PASS=$((PASS + 1))
fi

RESULT=$(parse_stride_md "$TMPDIR_TEST/adjacent-sections.stride.md" "after_doing")
assert_contains "adjacent: after_doing correct" 'echo "after"' "$RESULT"

# 2m: after_goal section is recognized like the other hooks
RESULT=$(parse_stride_md "$TMPDIR_TEST/after-goal-present.stride.md" "after_goal")
assert_contains "after_goal: line 1 captured" 'echo "goal $GOAL_IDENTIFIER finished"' "$RESULT"
assert_contains "after_goal: line 2 captured" './scripts/notify-team.sh "$GOAL_TITLE"' "$RESULT"
if echo "$RESULT" | grep -qF 'echo "before_doing"'; then
  echo -e "  ${RED}FAIL${RESET}: after_goal should not bleed from before_doing"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: after_goal does not bleed from before_doing"
  PASS=$((PASS + 1))
fi

# 2n: Missing after_goal returns empty (back-compat — older .stride.md files)
RESULT=$(parse_stride_md "$TMPDIR_TEST/after-goal-missing.stride.md" "after_goal")
assert_eq "missing after_goal returns empty (back-compat)" "" "$RESULT"

# 2o: Duplicate after_goal sections — only the first is used
RESULT=$(parse_stride_md "$TMPDIR_TEST/after-goal-duplicate.stride.md" "after_goal")
assert_contains "duplicate after_goal: first wins" 'echo "first wins"' "$RESULT"
if echo "$RESULT" | grep -qF "second loses"; then
  echo -e "  ${RED}FAIL${RESET}: duplicate after_goal should not include second section"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: duplicate after_goal — second section ignored"
  PASS=$((PASS + 1))
fi

# ============================================================
# Test Group 3: Whitespace trimming (pure bash)
# ============================================================
echo ""
echo "=== Test Group 3: Whitespace trimming ==="

trim_leading() {
  local cmd="$1"
  local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
  echo "$trimmed"
}

# 3a: Leading spaces
RESULT=$(trim_leading "   echo hello")
assert_eq "trim leading spaces" "echo hello" "$RESULT"

# 3b: Leading tabs
RESULT=$(trim_leading "		echo hello")
assert_eq "trim leading tabs" "echo hello" "$RESULT"

# 3c: Mixed spaces and tabs
RESULT=$(trim_leading "	  	echo hello")
assert_eq "trim mixed whitespace" "echo hello" "$RESULT"

# 3d: No leading whitespace
RESULT=$(trim_leading "echo hello")
assert_eq "no trim needed" "echo hello" "$RESULT"

# 3e: All whitespace
RESULT=$(trim_leading "   ")
assert_eq "all whitespace becomes empty" "" "$RESULT"

# 3f: Empty string
RESULT=$(trim_leading "")
assert_eq "empty string stays empty" "" "$RESULT"

# ============================================================
# Test Group 4: Command list building (comments/blanks filtered)
# ============================================================
echo ""
echo "=== Test Group 4: Command list building ==="

build_cmd_list() {
  local COMMANDS="$1"
  local CMD_LIST=()
  while IFS= read -r cmd; do
    local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in \#*) continue ;; esac
    CMD_LIST+=("$trimmed")
  done <<< "$COMMANDS"
  [ ${#CMD_LIST[@]} -gt 0 ] && printf '%s\n' "${CMD_LIST[@]}" || true
}

# 4a: Filters comments and blank lines
COMMANDS='# comment
echo "step one"
   echo "indented step"

echo "step three"
# trailing comment'
RESULT=$(build_cmd_list "$COMMANDS")
LINES=$(echo "$RESULT" | wc -l | tr -d ' ')
assert_eq "filtered to 3 commands" "3" "$LINES"
assert_contains "keeps step one" 'echo "step one"' "$RESULT"
assert_contains "trims indented step" 'echo "indented step"' "$RESULT"
assert_contains "keeps step three" 'echo "step three"' "$RESULT"

# 4b: All comments/blanks
COMMANDS='# only comments

# more comments
'
RESULT=$(build_cmd_list "$COMMANDS")
# When all filtered, we get one empty line from printf of empty array
TRIMMED_RESULT="${RESULT#"${RESULT%%[![:space:]]*}"}"
assert_eq "all comments filtered to empty" "" "$TRIMMED_RESULT"

# ============================================================
# Test Group 5: Full integration (end-to-end via the script)
# ============================================================
echo ""
echo "=== Test Group 5: Full integration ==="

# Create a project directory with .stride.md
PROJ="$TMPDIR_TEST/project"
mkdir -p "$PROJ"
cat > "$PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_executed"
```

## after_doing
```bash
echo "after_doing_executed"
```

## before_review
```bash
echo "before_review_executed"
```

## after_review
```bash
echo "after_review_executed"
```
STRIDE

# 5a: Claim triggers before_doing (post phase)
CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "claim exits 0" 0 "$EXIT_CODE"
assert_contains "claim runs before_doing" "before_doing_executed" "$OUTPUT"

# 5b: Pre-complete triggers after_doing (pre phase)
COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "pre-complete exits 0" 0 "$EXIT_CODE"
assert_contains "pre-complete runs after_doing" "after_doing_executed" "$OUTPUT"

# 5c: Post-complete triggers before_review (post phase)
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "post-complete exits 0" 0 "$EXIT_CODE"
assert_contains "post-complete runs before_review" "before_review_executed" "$OUTPUT"

# 5d: Mark-reviewed triggers after_review (post phase)
REVIEW_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}'
OUTPUT=$(echo "$REVIEW_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "mark-reviewed exits 0" 0 "$EXIT_CODE"
assert_contains "mark-reviewed runs after_review" "after_review_executed" "$OUTPUT"

# 5e: Non-stride command exits cleanly
OTHER_JSON='{"tool_input":{"command":"ls -la"}}'
OUTPUT=$(echo "$OTHER_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "non-stride exits 0" 0 "$EXIT_CODE"
assert_eq "non-stride produces no output" "" "$OUTPUT"

# 5f: No .stride.md exits cleanly
EMPTY_PROJ="$TMPDIR_TEST/empty-project"
mkdir -p "$EMPTY_PROJ"
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$EMPTY_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "no .stride.md exits 0" 0 "$EXIT_CODE"

# 5g: No phase argument exits cleanly
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" 2>&1)
EXIT_CODE=$?
assert_exit "no phase exits 0" 0 "$EXIT_CODE"

# 5h: Hook with failing command exits 2
FAIL_PROJ="$TMPDIR_TEST/fail-project"
mkdir -p "$FAIL_PROJ"
cat > "$FAIL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "step one passes"
false
echo "step three should not run"
```
STRIDE
# Capture stderr (execution output) separately from stdout (JSON diagnostics)
FAIL_STDERR_FILE=$(mktemp)
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$FAIL_PROJ" bash "$HOOK_SCRIPT" post 2>"$FAIL_STDERR_FILE")
EXIT_CODE=$?
FAIL_STDERR=$(cat "$FAIL_STDERR_FILE")
rm -f "$FAIL_STDERR_FILE"
assert_exit "failing hook exits 2" 2 "$EXIT_CODE"
# The failure message stays on stderr — load-bearing for the PreToolUse
# blocking semantic (exit 2 + stderr message).
assert_contains "failing hook reports failure on stderr" "hook failed on command 2/3" "$FAIL_STDERR"
# D65: the earlier PASSING command's output must NOT leak to stderr. Before the
# fix, a successful command's stdout/stderr was catted to fd 2, which Claude
# Code rendered under a false "PreToolUse:Bash hook error" label.
if echo "$FAIL_STDERR" | grep -qF "step one passes"; then
  echo -e "  ${RED}FAIL${RESET}: passing command output must not appear on stderr"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: passing command output kept off stderr"
  PASS=$((PASS + 1))
fi
if echo "$FAIL_STDERR" | grep -qF "step three should not run"; then
  echo -e "  ${RED}FAIL${RESET}: should not run commands after failure"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: stops execution after failure"
  PASS=$((PASS + 1))
fi

# 5i: Hook with multiple successful commands
MULTI_PROJ="$TMPDIR_TEST/multi-project"
mkdir -p "$MULTI_PROJ"
cat > "$MULTI_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "test_one"
echo "test_two"
echo "test_three"
```
STRIDE
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$MULTI_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "multi-command exits 0" 0 "$EXIT_CODE"
assert_contains "multi-command: step 1" "test_one" "$OUTPUT"
assert_contains "multi-command: step 2" "test_two" "$OUTPUT"
assert_contains "multi-command: step 3" "test_three" "$OUTPUT"

# 5j: Hook section not defined for this phase
PARTIAL_PROJ="$TMPDIR_TEST/partial-project"
mkdir -p "$PARTIAL_PROJ"
cat > "$PARTIAL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing"
```
STRIDE
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PARTIAL_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "missing section exits 0" 0 "$EXIT_CODE"
assert_eq "missing section no output" "" "$OUTPUT"

# 5k: D65 — a fully PASSING gate writes nothing to stderr; per-command output
# is folded into the success JSON's commands_output on stdout instead. Capture
# stdout and stderr separately to assert the new contract.
OK_PROJ="$TMPDIR_TEST/ok-stderr-project"
mkdir -p "$OK_PROJ"
cat > "$OK_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "gate_line_one"
echo "gate_line_two"
```
STRIDE
OK_STDOUT_FILE=$(mktemp)
OK_STDERR_FILE=$(mktemp)
echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$OK_PROJ" bash "$HOOK_SCRIPT" pre >"$OK_STDOUT_FILE" 2>"$OK_STDERR_FILE"
EXIT_CODE=$?
OK_STDOUT=$(cat "$OK_STDOUT_FILE")
OK_STDERR=$(cat "$OK_STDERR_FILE")
rm -f "$OK_STDOUT_FILE" "$OK_STDERR_FILE"
assert_exit "passing gate exits 0" 0 "$EXIT_CODE"
assert_eq "passing gate writes nothing to stderr" "" "$OK_STDERR"
if command -v jq > /dev/null 2>&1; then
  assert_contains "passing gate emits commands_output" "commands_output" "$OK_STDOUT"
  assert_contains "passing gate output folded into JSON (1)" "gate_line_one" "$OK_STDOUT"
  assert_contains "passing gate output folded into JSON (2)" "gate_line_two" "$OK_STDOUT"
  # stdout must be a single parseable JSON object with status success
  if echo "$OK_STDOUT" | jq -e '.status == "success" and (.commands_output | type == "array")' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: success stdout is a single JSON object with commands_output array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: success stdout not a valid JSON object: $OK_STDOUT"
    FAIL=$((FAIL + 1))
  fi
else
  # No-jq degraded path: success emits no JSON at all and still writes nothing
  # to stderr.
  assert_eq "no-jq passing gate emits no stdout" "" "$OK_STDOUT"
fi

# 5l: D65 — a PASSING command that writes to STDERR (exit 0) is the exact
# production trigger ("All checks passed!" was a passing gate's output). Its
# stderr must NOT reach fd 2 (where Claude Code mislabels it); it must land in
# the success JSON's commands_output[].stderr instead.
STDERR_OK_PROJ="$TMPDIR_TEST/stderr-ok-project"
mkdir -p "$STDERR_OK_PROJ"
cat > "$STDERR_OK_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "compiling to stderr" >&2
```
STRIDE
SO_STDOUT_FILE=$(mktemp)
SO_STDERR_FILE=$(mktemp)
echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$STDERR_OK_PROJ" bash "$HOOK_SCRIPT" pre >"$SO_STDOUT_FILE" 2>"$SO_STDERR_FILE"
EXIT_CODE=$?
SO_STDOUT=$(cat "$SO_STDOUT_FILE")
SO_STDERR=$(cat "$SO_STDERR_FILE")
rm -f "$SO_STDOUT_FILE" "$SO_STDERR_FILE"
assert_exit "stderr-writing passing gate exits 0" 0 "$EXIT_CODE"
assert_eq "stderr-writing passing gate writes nothing to fd 2" "" "$SO_STDERR"
if command -v jq > /dev/null 2>&1; then
  if echo "$SO_STDOUT" | jq -e '.commands_output[0].stderr | contains("compiling to stderr")' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: passing command's stderr folded into commands_output[].stderr"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: passing command's stderr not in commands_output: $SO_STDOUT"
    FAIL=$((FAIL + 1))
  fi
fi

# ============================================================
# Test Group 6: Edge cases
# ============================================================
echo ""
echo "=== Test Group 6: Edge cases ==="

# 6a: .stride.md with no trailing newline
NO_NEWLINE_PROJ="$TMPDIR_TEST/no-newline-project"
mkdir -p "$NO_NEWLINE_PROJ"
printf '## before_doing\n```bash\necho "no trailing newline"\n```' > "$NO_NEWLINE_PROJ/.stride.md"
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$NO_NEWLINE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "no trailing newline exits 0" 0 "$EXIT_CODE"
assert_contains "no trailing newline runs command" "no trailing newline" "$OUTPUT"

# 6b: Command with environment variable references
ENV_PROJ="$TMPDIR_TEST/env-project"
mkdir -p "$ENV_PROJ"
cat > "$ENV_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "home=$HOME"
```
STRIDE
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$ENV_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "env var expansion exits 0" 0 "$EXIT_CODE"
assert_contains "env var expanded" "home=$HOME" "$OUTPUT"

# 6c: .stride.md with CRLF line endings (Windows)
CRLF_PROJ="$TMPDIR_TEST/crlf-project"
mkdir -p "$CRLF_PROJ"
printf '## before_doing\r\n```bash\r\necho "crlf test"\r\n```\r\n' > "$CRLF_PROJ/.stride.md"
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$CRLF_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "CRLF line endings exits 0" 0 "$EXIT_CODE"
assert_contains "CRLF runs command" "crlf test" "$OUTPUT"

# 6d: JSON with tool_response (env caching path, requires jq)
if command -v jq > /dev/null 2>&1; then
  CACHE_PROJ="$TMPDIR_TEST/cache-project"
  mkdir -p "$CACHE_PROJ"
  cat > "$CACHE_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "id=$TASK_IDENTIFIER title=$TASK_TITLE"
```
STRIDE
  CLAIM_WITH_RESPONSE='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W99\",\"title\":\"Test Task\",\"status\":\"doing\",\"complexity\":\"small\",\"priority\":\"high\"}}"}'
  OUTPUT=$(echo "$CLAIM_WITH_RESPONSE" | CLAUDE_PROJECT_DIR="$CACHE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "env caching exits 0" 0 "$EXIT_CODE"
  assert_contains "env cache: identifier" "id=W99" "$OUTPUT"
  assert_contains "env cache: title" "title=Test Task" "$OUTPUT"
  # Clean up env cache
  rm -f "$CACHE_PROJ/.stride-env-cache"

  # 6e: Claude Code Bash tool wraps API JSON inside tool_response.stdout
  # (the wrapper that broke env caching before 1.7.4)
  CC_CLAIM='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":1526,\"identifier\":\"W217\",\"title\":\"Wrapped Task\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}'
  OUTPUT=$(echo "$CC_CLAIM" | CLAUDE_PROJECT_DIR="$CACHE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "env caching (Claude Code stdout wrapper) exits 0" 0 "$EXIT_CODE"
  assert_contains "env cache (wrapped): identifier" "id=W217" "$OUTPUT"
  assert_contains "env cache (wrapped): title" "title=Wrapped Task" "$OUTPUT"
  rm -f "$CACHE_PROJ/.stride-env-cache"
else
  echo "  SKIP: env caching tests (jq not available)"
fi

# ============================================================
# Test Group 7: Per-file diff capture (G148/W719 contract)
# ============================================================
echo ""
echo "=== Test Group 7: Per-file diff capture ==="

# Source the capture function from the hook script. The script's main flow
# only runs when stdin is provided and a hook name is matched, so sourcing it
# without those preconditions safely defines the function without executing
# anything.
if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: diff-capture tests (jq not available)"
elif ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: diff-capture tests (git not available)"
else
  # Mirror of the inline truncation logic for isolated unit testing.
  trunc_diff_inline() {
    local diff_text="$1"
    local max_lines="$2"
    local marker="$3"

    local line_count=0
    if [ -n "$diff_text" ]; then
      local _no_nl="${diff_text//$'\n'/}"
      line_count=$(( ${#diff_text} - ${#_no_nl} + 1 ))
    fi
    if [ "$line_count" -gt "$max_lines" ]; then
      local truncated
      truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
      printf '%s\n%s' "$truncated" "$marker"
    else
      printf '%s' "$diff_text"
    fi
  }

  # Mirror of the inline binary-detection logic for isolated unit testing.
  is_binary_in_numstat() {
    local numstat="$1" target="$2"
    local nl added rest deleted path
    while IFS= read -r nl; do
      added="${nl%%	*}"
      rest="${nl#*	}"
      deleted="${rest%%	*}"
      path="${rest#*	}"
      if [ "$added" = "-" ] && [ "$deleted" = "-" ] && [ "$path" = "$target" ]; then
        return 0
      fi
    done <<< "$numstat"
    return 1
  }

  # 7a: Truncation — diff at exactly 500 lines is not truncated
  EXACT_500=$(for i in $(seq 1 500); do echo "line $i"; done)
  RESULT=$(trunc_diff_inline "$EXACT_500" 500 "[diff truncated at 500 lines]")
  RESULT_LINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
  assert_eq "500-line diff: line count preserved" "500" "$RESULT_LINES"
  if echo "$RESULT" | grep -qF "[diff truncated at 500 lines]"; then
    echo -e "  ${RED}FAIL${RESET}: 500-line diff should not contain truncation marker"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 500-line diff is not truncated"
    PASS=$((PASS + 1))
  fi

  # 7b: Truncation — diff over 500 lines is truncated with the contract marker
  OVER_500=$(for i in $(seq 1 750); do echo "line $i"; done)
  RESULT=$(trunc_diff_inline "$OVER_500" 500 "[diff truncated at 500 lines]")
  RESULT_LINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
  assert_eq "750-line diff: truncated to 500 lines total" "500" "$RESULT_LINES"
  assert_contains "750-line diff: marker appended" \
    "[diff truncated at 500 lines]" \
    "$RESULT"
  # Last line should be the marker
  LAST_LINE=$(printf '%s\n' "$RESULT" | tail -n 1)
  assert_eq "750-line diff: marker is last line" \
    "[diff truncated at 500 lines]" \
    "$LAST_LINE"

  # 7c: Truncation — empty input stays empty
  RESULT=$(trunc_diff_inline "" 500 "[diff truncated at 500 lines]")
  assert_eq "empty diff stays empty" "" "$RESULT"

  # 7d: Binary detection — numstat with "- - <file>" returns true
  NUMSTAT='10	2	lib/foo.ex
-	-	assets/logo.png
3	0	test/foo_test.exs'
  if is_binary_in_numstat "$NUMSTAT" "assets/logo.png"; then
    echo -e "  ${GREEN}PASS${RESET}: binary file detected from numstat"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: binary file not detected"
    FAIL=$((FAIL + 1))
  fi

  # 7e: Binary detection — text file does not match
  if is_binary_in_numstat "$NUMSTAT" "lib/foo.ex"; then
    echo -e "  ${RED}FAIL${RESET}: text file misidentified as binary"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: text file correctly not flagged binary"
    PASS=$((PASS + 1))
  fi

  # 7f: Binary detection — file not in numstat
  if is_binary_in_numstat "$NUMSTAT" "nonexistent.txt"; then
    echo -e "  ${RED}FAIL${RESET}: missing file misidentified as binary"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: missing file correctly not flagged binary"
    PASS=$((PASS + 1))
  fi

  # 7g: Integration — capture_changed_files in a real temp git repo
  # Source the function from the hook script. Set arg empty to skip script main.
  CAPTURE_DIR=$(mktemp -d)
  (
    cd "$CAPTURE_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "original" > a.txt
    echo "original" > b.txt
    # Create a small binary file (PNG signature + nulls)
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x00\x00\x00\x00\x00' > logo.png
    git add . > /dev/null
    git commit -q -m "initial"

    # Capture the base
    BASE=$(git rev-parse HEAD)

    # Modify text + binary
    echo "modified" > a.txt
    printf '\x89PNG\r\n\x1a\n\xff\xff\xff\xff\xff\xff\xff\xff' > logo.png
    rm b.txt
    git add -A > /dev/null
    git commit -q -m "changes"

    # Source the capture function from the hook script.
    # The early-exit checks (no phase, no .stride.md) keep main from running.
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true

    capture_changed_files "$BASE"
  ) > "$CAPTURE_DIR/capture.json" 2> "$CAPTURE_DIR/capture.err"

  CAPTURE_OUTPUT=$(cat "$CAPTURE_DIR/capture.json")

  # Verify the output is a JSON array of length 3
  if echo "$CAPTURE_OUTPUT" | jq -e 'type == "array" and length == 3' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: integration: emits 3-entry JSON array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: integration: expected 3-entry array, got: $(echo "$CAPTURE_OUTPUT" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi

  # Text file should have a unified-patch diff
  TEXT_DIFF=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "a.txt") | .diff')
  # `grep -F` still treats a leading "--" as an option; pick a needle that
  # avoids that without weakening the assertion.
  assert_contains "integration: text file has unified-patch header" \
    "diff --git a/a.txt" \
    "$TEXT_DIFF"
  assert_contains "integration: text file has +/- lines" "+modified" "$TEXT_DIFF"

  # Binary file should have the exact placeholder
  BIN_DIFF=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "logo.png") | .diff')
  assert_eq "integration: binary file emits exact placeholder" \
    "[binary file — no diff captured]" \
    "$BIN_DIFF"

  # Deleted file (b.txt) still appears in the changed-files list
  DELETED_PRESENT=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "b.txt") | .path')
  assert_eq "integration: deleted file present in array" "b.txt" "$DELETED_PRESENT"

  rm -rf "$CAPTURE_DIR"

  # 7h: Fallback — non-repo directory returns empty array
  NONREPO_DIR=$(mktemp -d)
  (
    cd "$NONREPO_DIR" || exit 1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files ""
  ) > "$NONREPO_DIR/out.json" 2>/dev/null
  NONREPO_OUTPUT=$(cat "$NONREPO_DIR/out.json")
  if echo "$NONREPO_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: non-repo directory returns empty array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: non-repo expected [], got: $NONREPO_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NONREPO_DIR"

  # 7i: Fallback — empty base ref with a valid HEAD~1 still captures
  FALLBACK_DIR=$(mktemp -d)
  FALLBACK_OUT=$(mktemp)
  (
    cd "$FALLBACK_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "first" > c.txt
    git add c.txt > /dev/null
    git commit -q -m "first"
    echo "second" > c.txt
    git add c.txt > /dev/null
    git commit -q -m "second"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files ""
  ) > "$FALLBACK_OUT" 2>/dev/null
  FALLBACK_OUTPUT=$(cat "$FALLBACK_OUT")
  rm -f "$FALLBACK_OUT"
  if echo "$FALLBACK_OUTPUT" | jq -e 'type == "array" and length == 1 and .[0].path == "c.txt"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: empty base falls back to HEAD~1 successfully"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: empty-base fallback expected single c.txt entry, got: $FALLBACK_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$FALLBACK_DIR"

  # 7j: End-to-end — after_doing hook writes .stride-changed-files.json
  E2E_DIR=$(mktemp -d)
  (
    cd "$E2E_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    # Gitignore the hook's runtime artifacts so they don't leak into the
    # snapshot via the Option D untracked-file capture.
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1 + gitignore"
    BASE=$(git rev-parse HEAD)
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v2"

    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran after_doing"
```
STRIDE

    # Pre-populate the env cache with the base ref the hook would have set
    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$E2E_DIR/.stride-changed-files.json" ]; then
    E2E_JSON=$(cat "$E2E_DIR/.stride-changed-files.json")
    if echo "$E2E_JSON" | jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: e2e: after_doing wrote correct .stride-changed-files.json"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: e2e: unexpected JSON contents: $E2E_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: e2e: .stride-changed-files.json was not written"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$E2E_DIR"

  # 7k: All-commented after_doing still triggers capture
  NOCMD_DIR=$(mktemp -d)
  (
    cd "$NOCMD_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > f.txt
    git add f.txt > /dev/null
    # Gitignore stride runtime artifacts (Option D would otherwise capture
    # the test-fixture .stride.md / .stride-env-cache as untracked files).
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    git add .gitignore > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "v2" > f.txt
    git add f.txt > /dev/null
    git commit -q -m "v2"

    cat > .stride.md << 'STRIDE'
## after_doing
```bash
# every command commented out
# echo "this never runs"
```
STRIDE

    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$NOCMD_DIR/.stride-changed-files.json" ]; then
    NOCMD_JSON=$(cat "$NOCMD_DIR/.stride-changed-files.json")
    if echo "$NOCMD_JSON" | jq -e 'type == "array" and length == 1 and .[0].path == "f.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: all-commented after_doing still triggers capture"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: all-commented after_doing: unexpected JSON: $NOCMD_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: all-commented after_doing did not write the JSON snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOCMD_DIR"

  # 7l: Legacy bypass — non-after_doing hooks must NOT touch the snapshot file
  # If a stale snapshot exists from a prior after_doing, before_review (or any
  # other phase) must leave it untouched. This preserves the backward-compat
  # guarantee: legacy code paths that don't run the capture continue to work.
  BYPASS_DIR=$(mktemp -d)
  (
    cd "$BYPASS_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > x.txt
    git add x.txt > /dev/null
    git commit -q -m "v1"

    cat > .stride.md << 'STRIDE'
## before_review
```bash
echo "ran before_review"
```
STRIDE

    # Pre-seed the snapshot file with a marker we can detect.
    echo '[{"path":"stale.txt","diff":"stale"}]' > .stride-changed-files.json

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    # `post` phase + complete URL → before_review (not after_doing)
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$BYPASS_DIR/.stride-changed-files.json" ]; then
    BYPASS_JSON=$(cat "$BYPASS_DIR/.stride-changed-files.json")
    if echo "$BYPASS_JSON" | jq -e '.[0].path == "stale.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: legacy bypass — before_review preserves snapshot file"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: legacy bypass — before_review overwrote the snapshot: $BYPASS_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: legacy bypass — before_review deleted the snapshot unexpectedly"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BYPASS_DIR"

  # 7m: Empty changed-files list — base ref resolves but no files differ
  EMPTY_DIFF_DIR=$(mktemp -d)
  EMPTY_DIFF_OUT=$(mktemp)
  (
    cd "$EMPTY_DIFF_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > y.txt
    git add y.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Make a second commit with no real changes (use --allow-empty)
    git commit -q --allow-empty -m "empty"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$EMPTY_DIFF_OUT" 2>/dev/null
  EMPTY_DIFF_OUTPUT=$(cat "$EMPTY_DIFF_OUT")
  rm -f "$EMPTY_DIFF_OUT"
  if echo "$EMPTY_DIFF_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: empty changed-files list returns []"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: empty changed-files expected [], got: $EMPTY_DIFF_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EMPTY_DIFF_DIR"

  # 7n: File with embedded null bytes — git --numstat reports as binary, so the
  # placeholder must be emitted (no patch attempt)
  NULL_DIR=$(mktemp -d)
  (
    cd "$NULL_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'plain text\n' > nullfile.dat
    git add nullfile.dat > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Replace contents with bytes that include nulls
    printf 'text\x00with\x00nulls\n' > nullfile.dat
    git add nullfile.dat > /dev/null
    git commit -q -m "v2"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$NULL_DIR/out.json" 2>/dev/null
  NULL_OUTPUT=$(cat "$NULL_DIR/out.json")
  NULL_DIFF=$(echo "$NULL_OUTPUT" | jq -r '.[0].diff // ""')
  assert_eq "null-byte file emits binary placeholder" \
    "[binary file — no diff captured]" \
    "$NULL_DIFF"
  rm -rf "$NULL_DIR"

  # ---------------------------------------------------------------------------
  # Test Group 7 (Option D semantic) — cases 7o-7s
  # The snapshot must reflect the agent's working state at completion time:
  # modified-uncommitted tracked files, staged-uncommitted changes, untracked
  # new files (synthesized new-file patches), untracked binaries (placeholder),
  # and dedupe when a path is both committed-since-base AND further modified
  # in the working tree.
  # ---------------------------------------------------------------------------

  # 7o: Modified-uncommitted tracked file appears in the snapshot
  UNCOMMITTED_DIR=$(mktemp -d)
  (
    cd "$UNCOMMITTED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Modify the tracked file WITHOUT committing or staging
    echo "v2-uncommitted" > tracked.txt

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNCOMMITTED_DIR/out.json" 2>/dev/null
  UNCOMMITTED_OUTPUT=$(cat "$UNCOMMITTED_DIR/out.json")
  UNCOMMITTED_DIFF=$(echo "$UNCOMMITTED_OUTPUT" | jq -r '.[] | select(.path == "tracked.txt") | .diff')
  if [ -n "$UNCOMMITTED_DIFF" ]; then
    assert_contains "Option D: modified-uncommitted tracked file has unified-patch header" \
      "diff --git a/tracked.txt" \
      "$UNCOMMITTED_DIFF"
    assert_contains "Option D: modified-uncommitted tracked file diff body present" \
      "+v2-uncommitted" \
      "$UNCOMMITTED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: modified-uncommitted tracked file missing from snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UNCOMMITTED_DIR"

  # 7p: Staged-uncommitted change appears in the snapshot
  STAGED_DIR=$(mktemp -d)
  (
    cd "$STAGED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > staged.txt
    git add staged.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Modify and stage WITHOUT committing
    echo "v2-staged" > staged.txt
    git add staged.txt > /dev/null

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$STAGED_DIR/out.json" 2>/dev/null
  STAGED_OUTPUT=$(cat "$STAGED_DIR/out.json")
  STAGED_DIFF=$(echo "$STAGED_OUTPUT" | jq -r '.[] | select(.path == "staged.txt") | .diff')
  if [ -n "$STAGED_DIFF" ]; then
    assert_contains "Option D: staged-uncommitted file has unified-patch header" \
      "diff --git a/staged.txt" \
      "$STAGED_DIFF"
    assert_contains "Option D: staged-uncommitted file diff body present" \
      "+v2-staged" \
      "$STAGED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: staged-uncommitted file missing from snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$STAGED_DIR"

  # 7q: Untracked new file appears as synthesized new-file patch
  UNTRACKED_DIR=$(mktemp -d)
  (
    cd "$UNTRACKED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > existing.txt
    git add existing.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Create a NEW untracked file
    cat > new_file.txt << 'NEW'
line one
line two
line three
NEW

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNTRACKED_DIR/out.json" 2>/dev/null
  UNTRACKED_OUTPUT=$(cat "$UNTRACKED_DIR/out.json")
  UNTRACKED_DIFF=$(echo "$UNTRACKED_OUTPUT" | jq -r '.[] | select(.path == "new_file.txt") | .diff')
  if [ -n "$UNTRACKED_DIFF" ]; then
    # Synthesized new-file patch should have the +++ b/<path> header and at
    # least one `+<content>` body line.
    assert_contains "Option D: untracked new file has +++ b/<path> header" \
      "+++ b/new_file.txt" \
      "$UNTRACKED_DIFF"
    assert_contains "Option D: untracked new file has +<content> body lines" \
      "+line one" \
      "$UNTRACKED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: untracked new file missing from snapshot (output: $UNTRACKED_OUTPUT)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UNTRACKED_DIR"

  # 7r: Untracked binary uses the binary placeholder
  UNTRACKED_BIN_DIR=$(mktemp -d)
  (
    cd "$UNTRACKED_BIN_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > a.txt
    git add a.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Create an untracked file with NUL bytes (binary)
    printf 'binary\x00data\x00here\n' > new.bin

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNTRACKED_BIN_DIR/out.json" 2>/dev/null
  UNTRACKED_BIN_OUTPUT=$(cat "$UNTRACKED_BIN_DIR/out.json")
  UNTRACKED_BIN_DIFF=$(echo "$UNTRACKED_BIN_OUTPUT" | jq -r '.[] | select(.path == "new.bin") | .diff')
  assert_eq "Option D: untracked binary file emits exact binary placeholder" \
    "[binary file — no diff captured]" \
    "$UNTRACKED_BIN_DIFF"
  rm -rf "$UNTRACKED_BIN_DIR"

  # 7s: Dedupe — committed-and-further-modified path appears exactly once
  DEDUPE_DIR=$(mktemp -d)
  (
    cd "$DEDUPE_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > dual.txt
    git add dual.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Commit a change…
    echo "v2-committed" > dual.txt
    git add dual.txt > /dev/null
    git commit -q -m "v2"

    # …then modify the same path further WITHOUT committing
    echo "v3-uncommitted-on-top" > dual.txt

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$DEDUPE_DIR/out.json" 2>/dev/null
  DEDUPE_OUTPUT=$(cat "$DEDUPE_DIR/out.json")
  DEDUPE_COUNT=$(echo "$DEDUPE_OUTPUT" | jq -r '[.[] | select(.path == "dual.txt")] | length')
  assert_eq "Option D: dedupe — committed + further-modified path appears exactly once" \
    "1" \
    "$DEDUPE_COUNT"
  # And the diff should reflect the FINAL working-tree state (not the
  # intermediate committed value).
  DEDUPE_DIFF=$(echo "$DEDUPE_OUTPUT" | jq -r '.[] | select(.path == "dual.txt") | .diff')
  assert_contains "Option D: dedupe — diff reflects final working-tree content" \
    "+v3-uncommitted-on-top" \
    "$DEDUPE_DIFF"
  rm -rf "$DEDUPE_DIR"

  # 7t (D67): the hook's OWN root artifacts (.stride-diff-upload-state and
  # .stride-changed-files.json) are excluded from the snapshot when untracked,
  # while a legitimate changed file is still captured. Output is captured via
  # command substitution (not a redirect into the repo dir) so the output file
  # itself never appears as an untracked entry in the snapshot.
  EXCL_DIR=$(mktemp -d)
  EXCL_OUTPUT=$(
    cd "$EXCL_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > real.txt
    git add real.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "changed" > real.txt
    # The hook's own untracked bookkeeping artifacts at the repo root.
    printf 'task_id=42\nhttp_code=200\n' > .stride-diff-upload-state
    printf '[]\n' > .stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  EXCL_STATE=$(echo "$EXCL_OUTPUT" | jq -r '[.[] | select(.path == ".stride-diff-upload-state")] | length')
  assert_eq "D67: untracked upload-state file excluded from snapshot" "0" "$EXCL_STATE"
  EXCL_SNAP=$(echo "$EXCL_OUTPUT" | jq -r '[.[] | select(.path == ".stride-changed-files.json")] | length')
  assert_eq "D67: snapshot file itself excluded from snapshot" "0" "$EXCL_SNAP"
  EXCL_REAL=$(echo "$EXCL_OUTPUT" | jq -r '.[] | select(.path == "real.txt") | .path')
  assert_eq "D67: legitimate changed file still captured" "real.txt" "$EXCL_REAL"
  rm -rf "$EXCL_DIR"

  # 7u (D67): a COMMITTED upload-state file that differs from base is still
  # excluded — this is the after_doing auto-commit case that polluted W1098.
  EXCL2_DIR=$(mktemp -d)
  EXCL2_OUTPUT=$(
    cd "$EXCL2_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'task_id=1\nhttp_code=200\n' > .stride-diff-upload-state
    echo "v1" > real.txt
    git add -A > /dev/null
    git commit -q -m "v1 (state file committed)"
    BASE=$(git rev-parse HEAD)
    # Auto-commit case: both the state file and a real file change, then commit.
    printf 'task_id=2\nhttp_code=200\n' > .stride-diff-upload-state
    echo "v2" > real.txt
    git add -A > /dev/null
    git commit -q -m "v2"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  EXCL2_STATE=$(echo "$EXCL2_OUTPUT" | jq -r '[.[] | select(.path == ".stride-diff-upload-state")] | length')
  assert_eq "D67: committed+modified upload-state file excluded" "0" "$EXCL2_STATE"
  EXCL2_REAL=$(echo "$EXCL2_OUTPUT" | jq -r '.[] | select(.path == "real.txt") | .path')
  assert_eq "D67: real file still captured alongside excluded state file" "real.txt" "$EXCL2_REAL"
  rm -rf "$EXCL2_DIR"

  # 7v (D67): the exclusion is anchored to the repo ROOT — same-named files in a
  # subdirectory belong to the user's project and must still be captured.
  EXCL3_DIR=$(mktemp -d)
  EXCL3_OUTPUT=$(
    cd "$EXCL3_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > root.txt
    git add root.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    mkdir -p sub
    printf 'user data\n' > sub/.stride-diff-upload-state
    printf 'user snapshot\n' > sub/.stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  EXCL3_SUB1=$(echo "$EXCL3_OUTPUT" | jq -r '.[] | select(.path == "sub/.stride-diff-upload-state") | .path')
  assert_eq "D67: same-named file in a subdirectory is still captured (state)" \
    "sub/.stride-diff-upload-state" "$EXCL3_SUB1"
  EXCL3_SUB2=$(echo "$EXCL3_OUTPUT" | jq -r '.[] | select(.path == "sub/.stride-changed-files.json") | .path')
  assert_eq "D67: same-named file in a subdirectory is still captured (snapshot)" \
    "sub/.stride-changed-files.json" "$EXCL3_SUB2"
  rm -rf "$EXCL3_DIR"

  # 7w (D67): when the hook artifacts are the ONLY changed paths, the snapshot
  # is still a valid empty JSON array.
  EXCL4_DIR=$(mktemp -d)
  EXCL4_OUTPUT=$(
    cd "$EXCL4_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > real.txt
    git add real.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # real.txt is unchanged; only the hook's own untracked artifacts appear.
    printf 'task_id=9\nhttp_code=200\n' > .stride-diff-upload-state
    printf '[]\n' > .stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  if echo "$EXCL4_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: D67: artifacts-only working tree yields a valid empty array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D67: expected empty array, got: $EXCL4_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EXCL4_DIR"
fi

# ============================================================
# Test Group 8: PUT snapshot upload (W780)
# ============================================================
# finalize_after_doing PUTs the snapshot to {URL}/api/tasks/{TASK_ID}/changed_files
# after writing it to disk. URL+token are extracted from the intercepted
# agent completion request ($COMMAND). Failures must be silent.
echo ""
echo "=== Test Group 8: PUT snapshot upload (W780) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 8 requires both"
else
  # Helper to build the curl stub. Writes args + stdin into $1 and exits $2.
  # Optional 4th arg mocks the HTTP code real `curl -w '%{http_code}'` would
  # print to stdout (W1094 state-file tests); empty default prints nothing,
  # keeping all pre-existing call sites byte-identical in behavior.
  make_curl_stub() {
    local stub_dir="$1" fixture="$2" exit_code="${3:-0}" http_code="${4:-}"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/curl" << CURLSTUB
#!/usr/bin/env bash
{
  printf 'ARGS:'
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >> "$fixture"
# Record body for assertions. Two forms are recognized:
#   1. --data-binary @<file>   (legacy bare-array shape)
#   2. -d <inline-body>        (current wrapped-object shape)
prev=""
for a in "\$@"; do
  case "\$prev" in
    -d|--data|--data-raw)
      printf 'BODY:\n%s\n' "\$a" >> "$fixture"
      ;;
  esac
  case "\$a" in
    @*)
      printf 'BODY:\n' >> "$fixture"
      cat "\${a#@}" >> "$fixture" 2>/dev/null || true
      printf '\n' >> "$fixture"
      ;;
  esac
  prev="\$a"
done
printf '%s' '$http_code'
exit $exit_code
CURLSTUB
    chmod +x "$stub_dir/curl"
  }

  # Extract the BODY section emitted by make_curl_stub from a fixture file.
  # (W1093) after_doing now PUTs twice — an early pre-commands capture plus
  # the post-commands refresh — so the fixture can hold two ARGS/BODY records.
  # Capture stops at the next ARGS line and the LAST body wins: the refresh is
  # the authoritative final upload that must match the on-disk snapshot.
  extract_body() {
    awk '/^BODY:$/{flag=1; body=""; next} /^ARGS:/{flag=0} flag && /^$/{flag=0} flag{body = body $0 ORS} END{printf "%s", body}' "$1"
  }

  # Shared fixture: a git repo with one tracked change since BASE.
  setup_put_repo() {
    local dir="$1"
    cd "$dir" || return 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    # curl-call.txt is the stub recorder; it must be gitignored or the (W1093)
    # post-commands refresh capture would pick it up as an untracked file and
    # skew the snapshot the round-trip assertions compare against. The W1094
    # upload-state file needs the same treatment.
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
    PUT_BASE=$(git rev-parse HEAD)
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v2"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran after_doing"
```
STRIDE
    printf "TASK_ID='42'\nTASK_BASE_REF='%s'\n" "$PUT_BASE" > .stride-env-cache
  }

  # 8a: PUT-success — token+URL in $COMMAND triggers a PUT with the snapshot body
  PUT_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  PUT_FIXTURE="$PUT_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$PUT_FIXTURE" 0
  (
    setup_put_repo "$PUT_DIR" || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer test_token_abc123\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$PUT_FIXTURE" ]; then
    PUT_CONTENTS=$(cat "$PUT_FIXTURE")
    assert_contains "8a: PUT call targets /api/tasks/42/changed_files" \
      "https://stride.example.com/api/tasks/42/changed_files" "$PUT_CONTENTS"
    assert_contains "8a: PUT call sends Bearer token from \$COMMAND" \
      "Bearer test_token_abc123" "$PUT_CONTENTS"
    # The stub's ARGS line includes "X PUT" (the "-" is recorded but assert_contains
    # via `grep -qF` treats a leading "-" as an option; use the un-dashed substring).
    assert_contains "8a: PUT call uses PUT method" "X PUT " "$PUT_CONTENTS"

    # (W1093) after_doing PUTs twice: the early pre-commands capture plus the
    # post-commands refresh. Exactly two recorded calls proves the early PUT
    # was attempted before the section commands ran.
    PUT_CALL_COUNT=$(grep -c '^ARGS:' "$PUT_FIXTURE")
    assert_eq "8a: early capture + refresh make exactly two PUT calls" 2 "$PUT_CALL_COUNT"

    # D61: body must be a wrapped JSON object whose "changed_files" value is the
    # transport-encoded envelope {encoding: "base64", data: <string>} — NOT a
    # bare array (which lands at params['_json'] and persists as NULL) and NOT
    # raw diff text (which an edge filter could reject).
    PUT_BODY=$(extract_body "$PUT_FIXTURE")
    if [ -n "$PUT_BODY" ] && printf '%s' "$PUT_BODY" | jq -e '.changed_files.encoding == "base64" and (.changed_files.data | type) == "string"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: 8a: PUT body is the base64-encoded changed_files envelope"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 8a: PUT body is not the encoded envelope: $PUT_BODY"
      FAIL=$((FAIL + 1))
    fi

    # D61: the raw diff/path text MUST NOT appear in the wire body (it is
    # base64-encoded so an edge filter cannot misread it as an attack).
    if printf '%s' "$PUT_BODY" | grep -qF "tracked.txt"; then
      echo -e "  ${RED}FAIL${RESET}: 8a: raw path leaked into the wire body (should be base64-encoded)"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${RESET}: 8a: raw diff text is absent from the wire body (encoded)"
      PASS=$((PASS + 1))
    fi

    # D61: round-trip — re-encoding the snapshot the same way the hook does
    # reproduces the envelope's data field (portable: encode-only, no decode flag).
    EXPECTED_DATA=$(base64 < "$PUT_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
    ACTUAL_DATA=$(printf '%s' "$PUT_BODY" | jq -r '.changed_files.data' 2>/dev/null)
    if [ -n "$EXPECTED_DATA" ] && [ "$ACTUAL_DATA" = "$EXPECTED_DATA" ]; then
      echo -e "  ${GREEN}PASS${RESET}: 8a: encoded data round-trips to the snapshot file content"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 8a: round-trip mismatch — data: $ACTUAL_DATA vs expected: $EXPECTED_DATA"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 8a: PUT call was not made (no fixture written)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$PUT_DIR" "$STUB_DIR"

  # 8b: No Authorization header in $COMMAND → no PUT call
  NOTOK_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  NOTOK_FIXTURE="$NOTOK_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$NOTOK_FIXTURE" 0
  (
    setup_put_repo "$NOTOK_DIR" || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete"}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ ! -f "$NOTOK_FIXTURE" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8b: no Bearer token in \$COMMAND → PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8b: PUT was made despite missing token: $(cat "$NOTOK_FIXTURE")"
    FAIL=$((FAIL + 1))
  fi
  # Snapshot file must still be written for legacy --argjson cf consumers.
  if [ -f "$NOTOK_DIR/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8b: snapshot still written when PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8b: snapshot was not written when PUT skipped"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOTOK_DIR" "$STUB_DIR"

  # 8c: No TASK_ID in env cache → no PUT call
  NOID_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  NOID_FIXTURE="$NOID_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$NOID_FIXTURE" 0
  (
    cd "$NOID_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
GITIGNORE
    echo "v1" > x.txt
    git add .gitignore x.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "v2" > x.txt
    git add x.txt > /dev/null
    git commit -q -m "v2"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran"
```
STRIDE
    # No TASK_ID line — only TASK_BASE_REF.
    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer test_token\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ ! -f "$NOID_FIXTURE" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8c: missing TASK_ID → PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8c: PUT was made despite missing TASK_ID: $(cat "$NOID_FIXTURE")"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOID_DIR" "$STUB_DIR"

  # 8d: Empty snapshot ([]) still triggers a PUT (legitimate clear)
  EMPTY_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  EMPTY_FIXTURE="$EMPTY_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$EMPTY_FIXTURE" 0
  (
    cd "$EMPTY_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    # curl-call.txt gitignored for the same W1093 reason as setup_put_repo;
    # the W1094 upload-state file likewise.
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
GITIGNORE
    echo "v1" > y.txt
    git add .gitignore y.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Empty commit so capture_changed_files returns [].
    git commit -q --allow-empty -m "empty"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran"
```
STRIDE
    printf "TASK_ID='42'\nTASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$EMPTY_FIXTURE" ]; then
    EMPTY_CONTENTS=$(cat "$EMPTY_FIXTURE")
    assert_contains "8d: empty snapshot still triggers PUT" "X PUT " "$EMPTY_CONTENTS"
    # D61: an empty snapshot must still wrap as the transport-encoded envelope
    # whose data decodes back to an empty array (a legitimate clear), NOT a bare
    # empty array. Verified portably by re-encoding the snapshot file.
    EMPTY_BODY=$(extract_body "$EMPTY_FIXTURE")
    EMPTY_EXPECTED_DATA=$(base64 < "$EMPTY_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
    EMPTY_ACTUAL_DATA=$(printf '%s' "$EMPTY_BODY" | jq -r '.changed_files.data' 2>/dev/null)
    if [ -n "$EMPTY_BODY" ] &&
       printf '%s' "$EMPTY_BODY" | jq -e '.changed_files.encoding == "base64"' > /dev/null 2>&1 &&
       [ -n "$EMPTY_EXPECTED_DATA" ] && [ "$EMPTY_ACTUAL_DATA" = "$EMPTY_EXPECTED_DATA" ]; then
      echo -e "  ${GREEN}PASS${RESET}: 8d: empty snapshot wraps as the base64-encoded envelope"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 8d: PUT body was not the encoded empty form: $EMPTY_BODY"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 8d: PUT call was not made for empty snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EMPTY_DIR" "$STUB_DIR"

  # 8e: PUT failure (stub curl exits 1) does not propagate — hook still exits 0
  FAIL_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  FAIL_FIXTURE="$FAIL_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$FAIL_FIXTURE" 1
  (
    setup_put_repo "$FAIL_DIR" || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  FAIL_EXIT=$?
  # Run again outside the subshell to capture the actual exit code.
  (
    cd "$FAIL_DIR" || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  FAIL_EXIT=$?
  assert_exit "8e: PUT failure does not propagate (hook exits 0)" 0 "$FAIL_EXIT"
  # And the snapshot file is still on disk.
  if [ -f "$FAIL_DIR/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8e: snapshot file persists across failed PUT"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8e: snapshot file missing after failed PUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$FAIL_DIR" "$STUB_DIR"

  # 8f: HAS_JQ=false → PUT skipped (sourced unit test). Sourcing the hook
  # script with no PHASE arg short-circuits before the main flow runs, leaving
  # the function definitions in scope so we can call finalize_after_doing
  # directly with a forced HAS_JQ=false.
  NOJQ_DIR=$(mktemp -d)
  NOJQ_STUB=$(mktemp -d)
  NOJQ_FIXTURE="$NOJQ_DIR/curl-call.txt"
  make_curl_stub "$NOJQ_STUB" "$NOJQ_FIXTURE" 0
  (
    cd "$NOJQ_DIR" || exit 1
    printf '[]\n' > .stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    HAS_JQ=false
    HOOK_NAME=after_doing
    TASK_ID=42
    COMMAND='curl -X PATCH https://stride.example.com/api/tasks/42/complete -H "Authorization: Bearer tok"'
    PROJECT_DIR="$NOJQ_DIR"
    PATH="$NOJQ_STUB:$PATH"
    finalize_after_doing
  )
  if [ ! -f "$NOJQ_FIXTURE" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8f: HAS_JQ=false → PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8f: PUT made with HAS_JQ=false: $(cat "$NOJQ_FIXTURE")"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOJQ_DIR" "$NOJQ_STUB"

  # 8g (D54): the documented completion curl uses shell VARIABLES
  # ($STRIDE_API_URL / $STRIDE_API_TOKEN), so $COMMAND has no literal URL/token.
  # finalize_after_doing must resolve them from .stride_auth.md and still PUT —
  # using the production "**API Token:**" line, NOT "**Local API Token:**".
  VAR_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  VAR_FIXTURE="$VAR_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$VAR_FIXTURE" 0
  (
    setup_put_repo "$VAR_DIR" || exit 1
    cat > .stride_auth.md << 'AUTH'
- **API URL:** `https://auth-file.example.com`
- **Local API Token:** `LOCAL_should_not_be_used`
- **API Token:** `PROD_token_from_auth_file`
AUTH
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH \"$STRIDE_API_URL/api/tasks/42/complete\" -H \"Authorization: Bearer $STRIDE_API_TOKEN\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$VAR_FIXTURE" ]; then
    VAR_CONTENTS=$(cat "$VAR_FIXTURE")
    assert_contains "8g: variable-command PUT targets the auth-file URL" \
      "https://auth-file.example.com/api/tasks/42/changed_files" "$VAR_CONTENTS"
    assert_contains "8g: variable-command PUT sends the production API Token" \
      "Bearer PROD_token_from_auth_file" "$VAR_CONTENTS"
    # Check the Authorization header specifically (the snapshot body may echo
    # the test's .stride_auth.md content, so scan for the Bearer use precisely).
    if echo "$VAR_CONTENTS" | grep -qF "Bearer LOCAL_should_not_be_used"; then
      echo -e "  ${RED}FAIL${RESET}: 8g: Authorization used the Local API Token (must use the production one)"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${RESET}: 8g: Authorization did NOT use the Local API Token"
      PASS=$((PASS + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 8g: no PUT made for a variable-based command with .stride_auth.md"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$VAR_DIR" "$STUB_DIR"

  # 8h (D54): sourced unit test — resolvers prefer .stride_auth.md and pick the
  # production "**API Token:**" line over "**Local API Token:**".
  RESOLVE_DIR=$(mktemp -d)
  (
    cd "$RESOLVE_DIR" || exit 1
    cat > .stride_auth.md << 'AUTH'
- **API URL:** `https://auth-file.example.com`
- **Local API Token:** `LOCAL_tok`
- **API Token:** `PROD_tok`
AUTH
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    PROJECT_DIR="$RESOLVE_DIR"
    COMMAND=''
    printf 'URL=%s TOKEN=%s\n' "$(resolve_stride_api_url)" "$(resolve_stride_api_token)"
  ) > "$RESOLVE_DIR/out.txt" 2>/dev/null
  RESOLVE_OUT=$(grep '^URL=' "$RESOLVE_DIR/out.txt" || true)
  assert_eq "8h: resolvers read .stride_auth.md (production token, not Local)" \
    "URL=https://auth-file.example.com TOKEN=PROD_tok" "$RESOLVE_OUT"
  rm -rf "$RESOLVE_DIR"

  # 8i (D54): fallback — no .stride_auth.md → resolvers use the $COMMAND literals.
  RESOLVE2_DIR=$(mktemp -d)
  (
    cd "$RESOLVE2_DIR" || exit 1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    PROJECT_DIR="$RESOLVE2_DIR"
    COMMAND='curl -X PATCH https://literal.example.com/api/tasks/9/complete -H "Authorization: Bearer LITERAL_tok"'
    printf 'URL=%s TOKEN=%s\n' "$(resolve_stride_api_url)" "$(resolve_stride_api_token)"
  ) > "$RESOLVE2_DIR/out.txt" 2>/dev/null
  RESOLVE2_OUT=$(grep '^URL=' "$RESOLVE2_DIR/out.txt" || true)
  assert_eq "8i: resolvers fall back to \$COMMAND literals when no auth file" \
    "URL=https://literal.example.com TOKEN=LITERAL_tok" "$RESOLVE2_OUT"
  rm -rf "$RESOLVE2_DIR"
fi

# ============================================================
# Test Group 9: after_goal routing (W504)
# ============================================================
# Covers the new run_stride_section helper and the response_has_after_goal
# detector. Verifies the four W504 integration cases:
#   - after_goal present in response → run_stride_section executes ## after_goal
#   - after_goal absent → no after_goal execution
#   - ## after_goal missing from .stride.md → no-op (back-compat)
#   - ## after_goal failure → structured failed-JSON surfaced, return 2
echo ""
echo "=== Test Group 9: after_goal routing (W504) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 9 requires jq for response parsing"
else
  # 9a: response_has_after_goal detects after_goal in Claude Code wrapped shape.
  AG_INPUT_CC='{"tool_input":{"command":"curl"},"tool_response":{"stdout":"{\"data\":{},\"hooks\":[{\"name\":\"after_review\"},{\"name\":\"after_goal\"}]}"}}'
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    response_has_after_goal "$AG_INPUT_CC"
  )
  assert_eq "9a: response_has_after_goal detects after_goal in wrapped stdout shape" "0" "$?"

  # 9b: response_has_after_goal detects after_goal in raw response shape.
  AG_INPUT_RAW='{"tool_input":{"command":"curl"},"tool_response":{"data":{},"hooks":[{"name":"before_review"},{"name":"after_goal"}]}}'
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    response_has_after_goal "$AG_INPUT_RAW"
  )
  assert_eq "9b: response_has_after_goal detects after_goal in raw shape" "0" "$?"

  # 9c: response_has_after_goal returns non-zero when no after_goal entry.
  AG_INPUT_NONE='{"tool_input":{"command":"curl"},"tool_response":{"stdout":"{\"data\":{},\"hooks\":[{\"name\":\"after_review\"}]}"}}'
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    response_has_after_goal "$AG_INPUT_NONE"
  )
  AG_RC_NONE=$?
  if [ "$AG_RC_NONE" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9c: response_has_after_goal returns non-zero when after_goal absent"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9c: response_has_after_goal should return non-zero (got 0)"
    FAIL=$((FAIL + 1))
  fi

  # 9d: response_has_after_goal returns non-zero with HAS_JQ=false (pitfall —
  # gate on $HAS_JQ; environments without jq degrade cleanly).
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=false
    response_has_after_goal "$AG_INPUT_CC"
  )
  AG_RC_NOJQ=$?
  if [ "$AG_RC_NOJQ" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9d: response_has_after_goal returns non-zero with HAS_JQ=false"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9d: response_has_after_goal should return non-zero with HAS_JQ=false"
    FAIL=$((FAIL + 1))
  fi

  # 9e: response_has_after_goal returns non-zero when hooks array is missing.
  AG_INPUT_NO_HOOKS='{"tool_input":{"command":"curl"},"tool_response":{"stdout":"{\"data\":{}}"}}'
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    response_has_after_goal "$AG_INPUT_NO_HOOKS"
  )
  AG_RC_NO_HOOKS=$?
  if [ "$AG_RC_NO_HOOKS" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9e: response_has_after_goal returns non-zero when hooks key missing"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9e: response_has_after_goal should return non-zero when hooks key missing"
    FAIL=$((FAIL + 1))
  fi

  # 9f: run_stride_section executes ## after_goal when section is present.
  AG_DIR_PRESENT=$(mktemp -d)
  cat > "$AG_DIR_PRESENT/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal ran"
```
STRIDE
  AG_OUTPUT_PRESENT=$(
    cd "$AG_DIR_PRESENT" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$AG_DIR_PRESENT/.stride.md"
    PROJECT_DIR="$AG_DIR_PRESENT"
    HAS_JQ=true
    HOOK_NAME=""  # avoid finalize_after_doing side effects
    run_stride_section "after_goal" 2>&1
  )
  AG_RC_PRESENT=$?
  rm -rf "$AG_DIR_PRESENT"
  assert_exit "9f: run_stride_section 'after_goal' succeeds when section present" 0 "$AG_RC_PRESENT"
  # jq pretty-prints with a space after the colon. The substring assertions
  # below intentionally include that space so they match the rendered shape.
  assert_contains "9f: structured success JSON references after_goal" '"hook": "after_goal"' "$AG_OUTPUT_PRESENT"
  assert_contains "9f: structured success JSON has status:success" '"status": "success"' "$AG_OUTPUT_PRESENT"
  # D65: the passing command's output is folded into commands_output on stdout
  # rather than written to fd 2.
  assert_contains "9f: success JSON carries commands_output" '"commands_output"' "$AG_OUTPUT_PRESENT"
  assert_contains "9f: commands_output holds the passing command's stdout" 'after_goal ran' "$AG_OUTPUT_PRESENT"

  # 9f2 (D65): a passing section writes NOTHING to fd 2 — capture stdout and
  # stderr separately to prove command output no longer leaks to stderr.
  AG_DIR_OK=$(mktemp -d)
  cat > "$AG_DIR_OK/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "stderr_should_stay_empty"
```
STRIDE
  AG_OK_STDERR_FILE=$(mktemp)
  AG_OK_STDOUT=$(
    cd "$AG_DIR_OK" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$AG_DIR_OK/.stride.md"
    PROJECT_DIR="$AG_DIR_OK"
    HAS_JQ=true
    HOOK_NAME=""
    run_stride_section "after_goal" 2>"$AG_OK_STDERR_FILE"
  )
  AG_OK_STDERR=$(cat "$AG_OK_STDERR_FILE")
  rm -f "$AG_OK_STDERR_FILE"
  rm -rf "$AG_DIR_OK"
  assert_eq "9f2: passing section writes nothing to stderr" "" "$AG_OK_STDERR"
  assert_contains "9f2: passing command output captured in stdout JSON" "stderr_should_stay_empty" "$AG_OK_STDOUT"

  # 9g: run_stride_section is a clean no-op when ## after_goal section is
  # missing (back-compat — older .stride.md files keep working). Returns 0
  # with no structured JSON.
  AG_DIR_MISSING=$(mktemp -d)
  cat > "$AG_DIR_MISSING/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing here"
```
STRIDE
  AG_OUTPUT_MISSING=$(
    cd "$AG_DIR_MISSING" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$AG_DIR_MISSING/.stride.md"
    PROJECT_DIR="$AG_DIR_MISSING"
    HAS_JQ=true
    HOOK_NAME=""
    run_stride_section "after_goal" 2>&1
  )
  AG_RC_MISSING=$?
  rm -rf "$AG_DIR_MISSING"
  assert_exit "9g: run_stride_section 'after_goal' is a no-op when section missing" 0 "$AG_RC_MISSING"
  if [ -z "$AG_OUTPUT_MISSING" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9g: missing ## after_goal emits no structured JSON (back-compat)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9g: missing ## after_goal should emit no JSON, got: $AG_OUTPUT_MISSING"
    FAIL=$((FAIL + 1))
  fi

  # 9h: run_stride_section surfaces a non-zero exit via structured JSON
  # (pitfall — failures must be surfaced the same way after_doing surfaces them).
  AG_DIR_FAIL=$(mktemp -d)
  # Use `bash -c 'exit 7'` rather than bare `exit 7`: the latter would exit
  # the subshell BEFORE the parent function captures $?. The wrapper isolates
  # the failure to a child process whose exit status the parent observes.
  cat > "$AG_DIR_FAIL/.stride.md" << 'STRIDE'
## after_goal
```bash
bash -c 'exit 7'
```
STRIDE
  AG_OUTPUT_FAIL=$(
    cd "$AG_DIR_FAIL" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$AG_DIR_FAIL/.stride.md"
    PROJECT_DIR="$AG_DIR_FAIL"
    HAS_JQ=true
    HOOK_NAME=""
    run_stride_section "after_goal" 2>/dev/null
  )
  AG_RC_FAIL=$?
  rm -rf "$AG_DIR_FAIL"
  assert_exit "9h: run_stride_section 'after_goal' returns 2 on non-zero command" 2 "$AG_RC_FAIL"
  assert_contains "9h: structured failed JSON references after_goal" '"hook": "after_goal"' "$AG_OUTPUT_FAIL"
  assert_contains "9h: structured failed JSON has status:failed" '"status": "failed"' "$AG_OUTPUT_FAIL"
  assert_contains "9h: structured failed JSON carries non-zero exit_code" '"exit_code": 7' "$AG_OUTPUT_FAIL"
fi

# ============================================================
# Test Group 10: after_goal end-to-end routing (W506)
# ============================================================
# Covers the four after_goal scenarios end-to-end (full script run as a
# subprocess), not at the function level (Group 9 covers that). These
# tests construct realistic tool_input + tool_response JSON payloads
# that the Claude Code hooks system would deliver and assert against
# the script's actual stdout / stderr / exit code.
#
# Fixtures use generic URLs (stridelikeaboss.com) and task IDs (99/100)
# to keep the suite portable per the W506 pitfall.
echo ""
echo "=== Test Group 10: after_goal end-to-end routing (W506) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 10 requires jq for response parsing"
else
  # Shared project with all five hook sections.
  AG_E2E_PROJ="$TMPDIR_TEST/after-goal-e2e"
  mkdir -p "$AG_E2E_PROJ"
  cat > "$AG_E2E_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran for $GOAL_IDENTIFIER"
```
STRIDE

  # Helper: a tool_response payload whose hooks array contains the listed
  # entries. The wrap mirrors Claude Code's Bash-tool shape: tool_response
  # is an object with a `stdout` field holding the API JSON as a string.
  ag_e2e_input() {
    local primary_command="$1"
    local hooks_json="$2"
    local inner_json
    inner_json=$(jq -nc --argjson hooks "$hooks_json" '{data: {id: 99}, hooks: $hooks}')
    jq -nc \
      --arg cmd "$primary_command" \
      --arg inner "$inner_json" \
      '{tool_input: {command: $cmd}, tool_response: {stdout: $inner}}'
  }

  # 10a: after_goal entry in response + ## after_goal section present ->
  # section runs end-to-end alongside the primary before_review.
  AG_E2E_INPUT_PRESENT=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"after_doing"},{"name":"before_review"},{"name":"after_review"},{"name":"after_goal"}]')
  AG_E2E_OUT_PRESENT=$(echo "$AG_E2E_INPUT_PRESENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_PRESENT=$?
  assert_exit "10a: end-to-end after_goal present exits 0" 0 "$AG_E2E_RC_PRESENT"
  assert_contains "10a: primary before_review ran" "before_review_ran" "$AG_E2E_OUT_PRESENT"
  assert_contains "10a: after_goal section ran" "after_goal_ran" "$AG_E2E_OUT_PRESENT"
  assert_contains "10a: structured success JSON for after_goal on stdout" \
    '"hook": "after_goal"' "$AG_E2E_OUT_PRESENT"

  # 10b: after_goal entry in response + ## after_goal section ABSENT ->
  # back-compat no-op. The primary hook still runs; after_goal silently
  # produces no JSON and the script exits 0.
  AG_E2E_PROJ_MISSING="$TMPDIR_TEST/after-goal-e2e-missing"
  mkdir -p "$AG_E2E_PROJ_MISSING"
  cat > "$AG_E2E_PROJ_MISSING/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```
STRIDE
  AG_E2E_OUT_MISSING=$(echo "$AG_E2E_INPUT_PRESENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ_MISSING" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_MISSING=$?
  assert_exit "10b: end-to-end after_goal-missing-section exits 0 (back-compat)" 0 \
    "$AG_E2E_RC_MISSING"
  assert_contains "10b: primary before_review still ran" "before_review_ran" "$AG_E2E_OUT_MISSING"
  if echo "$AG_E2E_OUT_MISSING" | grep -qF '"hook": "after_goal"'; then
    echo -e "  ${RED}FAIL${RESET}: 10b: missing ## after_goal should emit no after_goal JSON"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10b: missing ## after_goal emits no after_goal JSON"
    PASS=$((PASS + 1))
  fi

  # 10c: after_goal NOT in response -> behavior unchanged. The primary
  # before_review runs; no after_goal execution; the script exits 0.
  AG_E2E_INPUT_ABSENT=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"after_doing"},{"name":"before_review"},{"name":"after_review"}]')
  AG_E2E_OUT_ABSENT=$(echo "$AG_E2E_INPUT_ABSENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_ABSENT=$?
  assert_exit "10c: end-to-end after_goal-absent exits 0" 0 "$AG_E2E_RC_ABSENT"
  assert_contains "10c: primary before_review ran" "before_review_ran" "$AG_E2E_OUT_ABSENT"
  if echo "$AG_E2E_OUT_ABSENT" | grep -qF "after_goal_ran"; then
    echo -e "  ${RED}FAIL${RESET}: 10c: after_goal absent should NOT execute the section"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10c: after_goal absent does not execute the section"
    PASS=$((PASS + 1))
  fi

  # 10d: after_goal section command exits non-zero -> structured failure
  # JSON surfaces on stdout. The script exit code is 0 (the primary curl
  # already succeeded; the agent reads the failure from stdout to forward
  # the result via PATCH /api/tasks/:goal_id/after_goal).
  AG_E2E_PROJ_FAIL="$TMPDIR_TEST/after-goal-e2e-fail"
  mkdir -p "$AG_E2E_PROJ_FAIL"
  cat > "$AG_E2E_PROJ_FAIL/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
bash -c 'exit 11'
```
STRIDE
  AG_E2E_OUT_FAIL=$(echo "$AG_E2E_INPUT_PRESENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ_FAIL" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_FAIL=$?
  assert_exit "10d: end-to-end after_goal-failure does not propagate as script exit" 0 \
    "$AG_E2E_RC_FAIL"
  assert_contains "10d: structured failed JSON references after_goal on stdout" \
    '"hook": "after_goal"' "$AG_E2E_OUT_FAIL"
  assert_contains "10d: structured failed JSON has status:failed" \
    '"status": "failed"' "$AG_E2E_OUT_FAIL"
  assert_contains "10d: structured failed JSON carries non-zero exit_code" \
    '"exit_code": 11' "$AG_E2E_OUT_FAIL"

  # 10e: mark_reviewed URL also routes after_goal (parity with /complete).
  AG_E2E_INPUT_MR=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed" \
    '[{"name":"after_review"},{"name":"after_goal"}]')
  AG_E2E_OUT_MR=$(echo "$AG_E2E_INPUT_MR" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_MR=$?
  assert_exit "10e: end-to-end after_goal on mark_reviewed exits 0" 0 "$AG_E2E_RC_MR"
  assert_contains "10e: mark_reviewed runs after_review" "after_review_ran" "$AG_E2E_OUT_MR"
  assert_contains "10e: mark_reviewed runs after_goal" "after_goal_ran" "$AG_E2E_OUT_MR"
fi

# ============================================================
# Test Group 11: End-to-end PUT round-trip (W835)
# ============================================================
# Gated on STRIDE_TEST_E2E_URL, STRIDE_TEST_E2E_TOKEN, and
# STRIDE_TEST_E2E_TASK_ID. The stub-only tests in Group 8 missed a body-shape
# regression (D35) because they never crossed the wire. This group drives
# finalize_after_doing against a real kanban server, GETs the task back, and
# asserts the persisted changed_files equals the snapshot — catching
# wire-shape mismatches at the integration boundary.
#
# Required env vars (group skips cleanly when any unset):
#   STRIDE_TEST_E2E_URL     — base URL of the local kanban server (must be
#                             http://localhost*, http://127.0.0.1*, or end in
#                             .dev / .local / .test to prevent production
#                             pollution)
#   STRIDE_TEST_E2E_TOKEN   — API bearer token for that server
#   STRIDE_TEST_E2E_TASK_ID — id of a sacrificial test task whose
#                             changed_files this group is allowed to overwrite
echo ""
echo "=== Test Group 11: End-to-end PUT round-trip (W835) ==="

if [ -z "${STRIDE_TEST_E2E_URL:-}" ] || [ -z "${STRIDE_TEST_E2E_TOKEN:-}" ] || [ -z "${STRIDE_TEST_E2E_TASK_ID:-}" ]; then
  echo "  SKIP: STRIDE_TEST_E2E_URL / STRIDE_TEST_E2E_TOKEN / STRIDE_TEST_E2E_TASK_ID unset — set all three to run the E2E round-trip"
elif ! command -v jq > /dev/null 2>&1 || ! command -v curl > /dev/null 2>&1; then
  echo "  SKIP: jq or curl missing — Group 11 requires both"
else
  # Safety: refuse to hit anything that doesn't look like a local/dev URL.
  # Production hostnames are a hard fail — this group mutates task state and
  # must never run there.
  E2E_URL="${STRIDE_TEST_E2E_URL%/}"
  E2E_URL_OK=0
  case "$E2E_URL" in
    http://localhost*|http://127.0.0.1*|http://[::1]*|https://*.dev|https://*.dev/*|https://*.local|https://*.local/*|https://*.test|https://*.test/*)
      E2E_URL_OK=1
      ;;
    *)
      echo -e "  ${RED}FAIL${RESET}: 11: refusing to run E2E against non-local URL: $E2E_URL"
      FAIL=$((FAIL + 1))
      ;;
  esac

  if [ "$E2E_URL_OK" -eq 1 ]; then
    E2E_DIR=$(mktemp -d)
    E2E_HEADERS=(-H "Authorization: Bearer $STRIDE_TEST_E2E_TOKEN" -H "Content-Type: application/json")
    E2E_TASK_ID="$STRIDE_TEST_E2E_TASK_ID"

    # Sanity-check the task exists and is reachable before mutating it.
    E2E_PRECHECK=$(curl -sS -o /dev/null -w '%{http_code}' "${E2E_HEADERS[@]}" "$E2E_URL/api/tasks/$E2E_TASK_ID" 2>/dev/null || echo '000')
    if [ "$E2E_PRECHECK" != "200" ]; then
      echo -e "  ${RED}FAIL${RESET}: 11: GET /api/tasks/$E2E_TASK_ID returned $E2E_PRECHECK — verify STRIDE_TEST_E2E_TASK_ID"
      FAIL=$((FAIL + 1))
    else
      # 11a: Round-trip with a populated snapshot. Body wrapped as
      # {"changed_files": [...]} must land at task.changed_files (not NULL).
      E2E_SNAPSHOT='[{"path":"e2e-w835.txt","diff":"diff --git a/e2e-w835.txt b/e2e-w835.txt\n+content"}]'
      echo "$E2E_SNAPSHOT" > "$E2E_DIR/.stride-changed-files.json"

      (
        cd "$E2E_DIR" || exit 1
        # shellcheck disable=SC1090
        source "$HOOK_SCRIPT" 2>/dev/null || true
        HOOK_NAME="after_doing" \
          PROJECT_DIR="$E2E_DIR" \
          TASK_ID="$E2E_TASK_ID" \
          HAS_JQ="true" \
          COMMAND="curl -X PATCH $E2E_URL/api/tasks/$E2E_TASK_ID/complete -H 'Authorization: Bearer $STRIDE_TEST_E2E_TOKEN'" \
          finalize_after_doing
      )

      E2E_GET=$(curl -sS "${E2E_HEADERS[@]}" "$E2E_URL/api/tasks/$E2E_TASK_ID" 2>/dev/null || echo '{}')
      E2E_PERSISTED=$(printf '%s' "$E2E_GET" | jq -c '.data.changed_files // null')
      E2E_EXPECTED=$(printf '%s' "$E2E_SNAPSHOT" | jq -c '.')

      if [ "$E2E_PERSISTED" = "null" ]; then
        echo -e "  ${RED}FAIL${RESET}: 11a: task.changed_files is NULL (bare-array regression?)"
        FAIL=$((FAIL + 1))
      elif [ "$E2E_PERSISTED" = "[]" ]; then
        echo -e "  ${RED}FAIL${RESET}: 11a: task.changed_files is [] after non-empty PUT"
        FAIL=$((FAIL + 1))
      elif [ "$E2E_PERSISTED" = "$E2E_EXPECTED" ]; then
        echo -e "  ${GREEN}PASS${RESET}: 11a: round-trip — task.changed_files equals snapshot"
        PASS=$((PASS + 1))
      else
        echo -e "  ${RED}FAIL${RESET}: 11a: round-trip mismatch — got: $E2E_PERSISTED expected: $E2E_EXPECTED"
        FAIL=$((FAIL + 1))
      fi

      # 11b: Empty-snapshot round-trip — {"changed_files": []} is a
      # legitimate clear and must persist as [] (not NULL).
      echo '[]' > "$E2E_DIR/.stride-changed-files.json"
      (
        cd "$E2E_DIR" || exit 1
        # shellcheck disable=SC1090
        source "$HOOK_SCRIPT" 2>/dev/null || true
        HOOK_NAME="after_doing" \
          PROJECT_DIR="$E2E_DIR" \
          TASK_ID="$E2E_TASK_ID" \
          HAS_JQ="true" \
          COMMAND="curl -X PATCH $E2E_URL/api/tasks/$E2E_TASK_ID/complete -H 'Authorization: Bearer $STRIDE_TEST_E2E_TOKEN'" \
          finalize_after_doing
      )

      E2E_GET_EMPTY=$(curl -sS "${E2E_HEADERS[@]}" "$E2E_URL/api/tasks/$E2E_TASK_ID" 2>/dev/null || echo '{}')
      E2E_EMPTY_PERSISTED=$(printf '%s' "$E2E_GET_EMPTY" | jq -c '.data.changed_files // null')
      if [ "$E2E_EMPTY_PERSISTED" = "[]" ]; then
        echo -e "  ${GREEN}PASS${RESET}: 11b: empty-snapshot round-trip persists as []"
        PASS=$((PASS + 1))
      else
        echo -e "  ${RED}FAIL${RESET}: 11b: empty-snapshot did not persist as []: got $E2E_EMPTY_PERSISTED"
        FAIL=$((FAIL + 1))
      fi

      # 11c: Fail-soft — missing Bearer token in $COMMAND must NOT crash the
      # hook (finalize swallows the no-op silently and exits 0).
      echo "$E2E_SNAPSHOT" > "$E2E_DIR/.stride-changed-files.json"
      E2E_FAILSOFT_RC=0
      (
        cd "$E2E_DIR" || exit 1
        # shellcheck disable=SC1090
        source "$HOOK_SCRIPT" 2>/dev/null || true
        HOOK_NAME="after_doing" \
          PROJECT_DIR="$E2E_DIR" \
          TASK_ID="$E2E_TASK_ID" \
          HAS_JQ="true" \
          COMMAND="curl -X PATCH $E2E_URL/api/tasks/$E2E_TASK_ID/complete" \
          finalize_after_doing
      ) || E2E_FAILSOFT_RC=$?
      if [ "$E2E_FAILSOFT_RC" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${RESET}: 11c: missing-token finalize_after_doing exits 0 (fail-soft)"
        PASS=$((PASS + 1))
      else
        echo -e "  ${RED}FAIL${RESET}: 11c: missing-token finalize_after_doing exited $E2E_FAILSOFT_RC (fail-soft broken)"
        FAIL=$((FAIL + 1))
      fi
    fi

    rm -rf "$E2E_DIR"
  fi
fi

# ============================================================
# Test Group 12: after_doing early snapshot capture (W1093)
# ============================================================
# run_stride_section must call finalize_after_doing BEFORE the command loop
# when the GLOBAL HOOK_NAME is after_doing, so the 120s hook timeout cannot
# kill the process before the diff snapshot is written. The post-loop call is
# kept as a refresh. Network safety: TASK_ID is never set and no
# .stride_auth.md exists in these fixtures, so finalize_after_doing skips the
# curl PUT entirely (it requires TASK_ID plus a resolvable URL and token
# before touching the network).
echo ""
echo "=== Test Group 12: after_doing early snapshot capture (W1093) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 12 requires jq for snapshot inspection"
else
  # Helper: seed a git repo whose working tree differs from the printed base
  # ref by one tracked file (tracked.txt v1 -> v2). Prints the base ref.
  w1093_seed_repo() {
    local _dir="$1"
    (
      cd "$_dir" || exit 1
      git init -q
      git config user.email "test@test.local"
      git config user.name "Test"
      cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
early-snapshot.json
GITIGNORE
      echo "v1" > tracked.txt
      git add .gitignore tracked.txt > /dev/null
      git commit -q -m "v1"
      git rev-parse HEAD
      echo "v2" > tracked.txt
      git add tracked.txt > /dev/null
      git commit -q -m "v2"
    )
  }

  # 12a: early-capture ordering — the FIRST section command finds
  # .stride-changed-files.json already on disk and copies it aside.
  W1093_DIR_A=$(mktemp -d)
  W1093_BASE_A=$(w1093_seed_repo "$W1093_DIR_A")
  cat > "$W1093_DIR_A/.stride.md" << 'STRIDE'
## after_doing
```bash
cp .stride-changed-files.json early-snapshot.json
```
STRIDE
  W1093_OUT_A=$(
    cd "$W1093_DIR_A" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_A/.stride.md"
    PROJECT_DIR="$W1093_DIR_A"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    TASK_BASE_REF="$W1093_BASE_A"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_A=$?
  assert_exit "12a: after_doing section succeeds with early capture" 0 "$W1093_RC_A"
  assert_contains "12a: structured success JSON emitted" '"status": "success"' "$W1093_OUT_A"
  if jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' \
    "$W1093_DIR_A/early-snapshot.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 12a: snapshot existed (populated) BEFORE first section command ran"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12a: first section command did not find a populated snapshot"
    FAIL=$((FAIL + 1))
  fi
  # stdout contract: the early capture must leak nothing onto stdout — the
  # captured output must be exactly one JSON document (the success JSON).
  if printf '%s' "$W1093_OUT_A" | jq -es 'length == 1 and .[0].hook == "after_doing"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 12a: stdout is exactly the structured success JSON (early capture is silent)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12a: stdout contains more than the success JSON: $W1093_OUT_A"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_A"

  # 12b: post-commands refresh — a section command modifies a tracked file;
  # the final snapshot must include that change while the early copy must not.
  W1093_DIR_B=$(mktemp -d)
  W1093_BASE_B=$(w1093_seed_repo "$W1093_DIR_B")
  cat > "$W1093_DIR_B/.stride.md" << 'STRIDE'
## after_doing
```bash
cp .stride-changed-files.json early-snapshot.json
echo "v3" > tracked.txt
```
STRIDE
  W1093_OUT_B=$(
    cd "$W1093_DIR_B" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_B/.stride.md"
    PROJECT_DIR="$W1093_DIR_B"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    TASK_BASE_REF="$W1093_BASE_B"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_B=$?
  assert_exit "12b: after_doing section with file-modifying command succeeds" 0 "$W1093_RC_B"
  W1093_EARLY_DIFF=$(jq -r '.[] | select(.path == "tracked.txt") | .diff' \
    "$W1093_DIR_B/early-snapshot.json" 2>/dev/null)
  W1093_FINAL_DIFF=$(jq -r '.[] | select(.path == "tracked.txt") | .diff' \
    "$W1093_DIR_B/.stride-changed-files.json" 2>/dev/null)
  if printf '%s' "$W1093_EARLY_DIFF" | grep -qF '+v3'; then
    echo -e "  ${RED}FAIL${RESET}: 12b: early snapshot already contains +v3 (capture not early)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 12b: early snapshot predates the section command's change"
    PASS=$((PASS + 1))
  fi
  if printf '%s' "$W1093_FINAL_DIFF" | grep -qF '+v3'; then
    echo -e "  ${GREEN}PASS${RESET}: 12b: post-commands refresh re-captured the section command's change"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12b: final snapshot missing +v3 (refresh removed or skipped)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_B"

  # 12c: GLOBAL HOOK_NAME gate — running the after_goal SECTION while the
  # global HOOK_NAME is after_review must leave no snapshot (pitfall: the
  # gate is $HOOK_NAME, not the _section argument). A real repo with a real
  # base ref is seeded so the test can actually fail if the gate breaks.
  W1093_DIR_C=$(mktemp -d)
  W1093_BASE_C=$(w1093_seed_repo "$W1093_DIR_C")
  cat > "$W1093_DIR_C/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal ran"
```
STRIDE
  W1093_OUT_C=$(
    cd "$W1093_DIR_C" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_C/.stride.md"
    PROJECT_DIR="$W1093_DIR_C"
    HAS_JQ=true
    HOOK_NAME="after_review"
    TASK_BASE_REF="$W1093_BASE_C"
    run_stride_section "after_goal" 2>/dev/null
  )
  W1093_RC_C=$?
  assert_exit "12c: after_goal section under HOOK_NAME=after_review succeeds" 0 "$W1093_RC_C"
  assert_contains "12c: structured success JSON references after_goal" '"hook": "after_goal"' "$W1093_OUT_C"
  if [ ! -f "$W1093_DIR_C/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 12c: no snapshot written when HOOK_NAME is not after_doing"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12c: snapshot written despite HOOK_NAME=after_review (gate broken)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_C"

  # 12d: failing section command — structured failed JSON and return 2 are
  # preserved, with the early snapshot already on disk (the whole point of
  # W1093: the snapshot survives a gate failure or timeout).
  W1093_DIR_D=$(mktemp -d)
  W1093_BASE_D=$(w1093_seed_repo "$W1093_DIR_D")
  cat > "$W1093_DIR_D/.stride.md" << 'STRIDE'
## after_doing
```bash
bash -c 'exit 7'
```
STRIDE
  W1093_OUT_D=$(
    cd "$W1093_DIR_D" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_D/.stride.md"
    PROJECT_DIR="$W1093_DIR_D"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    TASK_BASE_REF="$W1093_BASE_D"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_D=$?
  assert_exit "12d: failing after_doing command still returns 2" 2 "$W1093_RC_D"
  assert_contains "12d: structured failed JSON emitted" '"status": "failed"' "$W1093_OUT_D"
  assert_contains "12d: failed JSON carries exit_code 7" '"exit_code": 7' "$W1093_OUT_D"
  if jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' \
    "$W1093_DIR_D/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 12d: early snapshot survives a failed quality gate"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12d: snapshot missing or wrong after failed gate"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_D"

  # 12e: best-effort — non-repo dir with TASK_BASE_REF unset must still write
  # a [] snapshot and must NOT block the gate (early capture is never fatal).
  W1093_DIR_E=$(mktemp -d)
  cat > "$W1093_DIR_E/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "gate ran"
```
STRIDE
  W1093_OUT_E=$(
    cd "$W1093_DIR_E" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_E/.stride.md"
    PROJECT_DIR="$W1093_DIR_E"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_E=$?
  assert_exit "12e: non-repo early capture does not block the gate" 0 "$W1093_RC_E"
  assert_contains "12e: structured success JSON emitted" '"status": "success"' "$W1093_OUT_E"
  if jq -e 'type == "array" and length == 0' \
    "$W1093_DIR_E/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 12e: degraded capture wrote best-effort [] snapshot"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12e: expected [] snapshot in non-repo dir"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_E"
fi

# ============================================================
# Test Group 13: changed_files upload self-heal (W1094)
# ============================================================
# finalize_after_doing records each PUT outcome in .stride-diff-upload-state
# (task id + HTTP code only); the before_review path verifies that state on a
# fresh PostToolUse budget and re-captures + re-PUTs when the state is
# missing, names a different task, or recorded a non-2xx. The state file is
# cleaned at the before_doing claim refresh and the after_review cleanup.
# Network safety: every test stubs curl on PATH (or supplies no TASK_ID), so
# no real network is reachable.
echo ""
echo "=== Test Group 13: changed_files upload self-heal (W1094) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 13 requires both (reuses Group 8 helpers)"
else
  W1094_COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""}}'

  # 13a: finalize_after_doing records task id + mocked 2xx in the state file
  # after the pre-path PUTs, and the state file carries no credentials.
  SH_DIR_A=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_A="$SH_DIR_A/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_A" 0 200
  (
    setup_put_repo "$SH_DIR_A" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$SH_DIR_A/.stride-diff-upload-state" ]; then
    SH_STATE_A=$(cat "$SH_DIR_A/.stride-diff-upload-state")
    assert_contains "13a: state file records the task id" "task_id=42" "$SH_STATE_A"
    assert_contains "13a: state file records the mocked 2xx" "http_code=200" "$SH_STATE_A"
    if echo "$SH_STATE_A" | grep -qE 'Bearer|https?://'; then
      echo -e "  ${RED}FAIL${RESET}: 13a: state file leaked a credential or URL: $SH_STATE_A"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${RESET}: 13a: state file carries no token or URL"
      PASS=$((PASS + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 13a: state file was not written after the PUT attempt"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_A" "$STUB_DIR"

  # 13b: a non-2xx PUT outcome is recorded verbatim.
  SH_DIR_B=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  make_curl_stub "$STUB_DIR" "$SH_DIR_B/curl-call.txt" 0 500
  (
    setup_put_repo "$SH_DIR_B" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  SH_STATE_B=$(cat "$SH_DIR_B/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "13b: state file records the non-2xx code" "http_code=500" "$SH_STATE_B"
  rm -rf "$SH_DIR_B" "$STUB_DIR"

  # 13c: before_review retries when NO state file exists — re-captures the
  # snapshot against TASK_BASE_REF and PUTs it.
  SH_DIR_C=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_C="$SH_DIR_C/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_C" 0 200
  (
    setup_put_repo "$SH_DIR_C" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  SH_RC_C=$?
  assert_exit "13c: before_review with missing state exits 0" 0 "$SH_RC_C"
  if [ -f "$SH_FIXTURE_C" ]; then
    SH_CALLS_C=$(grep -c '^ARGS:' "$SH_FIXTURE_C")
    assert_eq "13c: missing state triggers exactly one retry PUT" 1 "$SH_CALLS_C"
    assert_contains "13c: retry PUT targets the changed_files route" \
      "https://stride.example.com/api/tasks/42/changed_files" "$(cat "$SH_FIXTURE_C")"
    assert_contains "13c: retry uses PUT method" "X PUT " "$(cat "$SH_FIXTURE_C")"
  else
    echo -e "  ${RED}FAIL${RESET}: 13c: no retry PUT was made for missing state"
    FAIL=$((FAIL + 1))
  fi
  if jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' \
    "$SH_DIR_C/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 13c: retry re-captured the snapshot against TASK_BASE_REF"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13c: retry did not re-capture the snapshot"
    FAIL=$((FAIL + 1))
  fi
  SH_STATE_C=$(cat "$SH_DIR_C/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "13c: retry outcome recorded for the current task" "task_id=42" "$SH_STATE_C"
  assert_contains "13c: retry outcome records the 2xx" "http_code=200" "$SH_STATE_C"
  rm -rf "$SH_DIR_C" "$STUB_DIR"

  # 13d: before_review does NOT re-upload when a 2xx is recorded for the
  # current task — and leaves the on-disk snapshot untouched.
  SH_DIR_D=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_D="$SH_DIR_D/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_D" 0 200
  (
    setup_put_repo "$SH_DIR_D" || exit 1
    printf 'task_id=42\nhttp_code=200\n' > .stride-diff-upload-state
    printf '[{"path":"stale.txt","diff":"marker"}]\n' > .stride-changed-files.json
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  SH_RC_D=$?
  assert_exit "13d: healthy-state before_review exits 0" 0 "$SH_RC_D"
  if [ ! -f "$SH_FIXTURE_D" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13d: no re-upload on a recorded 2xx for the current task"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13d: re-uploaded despite healthy state: $(cat "$SH_FIXTURE_D")"
    FAIL=$((FAIL + 1))
  fi
  if jq -e '.[0].path == "stale.txt"' "$SH_DIR_D/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 13d: on-disk snapshot left untouched on healthy state"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13d: snapshot was overwritten despite healthy state"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_D" "$STUB_DIR"

  # 13e: a state file naming a DIFFERENT task id triggers the retry.
  SH_DIR_E=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_E="$SH_DIR_E/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_E" 0 200
  (
    setup_put_repo "$SH_DIR_E" || exit 1
    printf 'task_id=41\nhttp_code=200\n' > .stride-diff-upload-state
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$SH_FIXTURE_E" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13e: stale task id in state triggers the retry PUT"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13e: no retry despite state naming a different task"
    FAIL=$((FAIL + 1))
  fi
  SH_STATE_E=$(cat "$SH_DIR_E/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "13e: state rewritten for the current task" "task_id=42" "$SH_STATE_E"
  rm -rf "$SH_DIR_E" "$STUB_DIR"

  # 13f: a recorded non-2xx for the current task triggers the retry.
  SH_DIR_F=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_F="$SH_DIR_F/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_F" 0 200
  (
    setup_put_repo "$SH_DIR_F" || exit 1
    printf 'task_id=42\nhttp_code=503\n' > .stride-diff-upload-state
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$SH_FIXTURE_F" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13f: recorded non-2xx triggers the retry PUT"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13f: no retry despite recorded non-2xx"
    FAIL=$((FAIL + 1))
  fi
  SH_STATE_F=$(cat "$SH_DIR_F/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "13f: state updated to the retry's 2xx" "http_code=200" "$SH_STATE_F"
  rm -rf "$SH_DIR_F" "$STUB_DIR"

  # 13g: a FAILING retry warns on stderr in finalize_after_doing's existing
  # style and never fails the before_review hook.
  SH_DIR_G=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_ERR_G="$SH_DIR_G/stderr.txt"
  make_curl_stub "$STUB_DIR" "$SH_DIR_G/curl-call.txt" 0 500
  (
    setup_put_repo "$SH_DIR_G" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2> "$SH_ERR_G"
  )
  SH_RC_G=$?
  assert_exit "13g: failed retry never fails the before_review hook" 0 "$SH_RC_G"
  assert_contains "13g: failed retry warns in the existing stderr style" \
    "changed_files upload failed (HTTP 500) for task 42" "$(cat "$SH_ERR_G" 2>/dev/null)"
  SH_STATE_G=$(cat "$SH_DIR_G/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "13g: failed retry outcome recorded" "http_code=500" "$SH_STATE_G"
  rm -rf "$SH_DIR_G" "$STUB_DIR"

  # 13h: the before_doing claim refresh removes a stale state file.
  SH_DIR_H=$(mktemp -d)
  cat > "$SH_DIR_H/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  printf 'task_id=41\nhttp_code=200\n' > "$SH_DIR_H/.stride-diff-upload-state"
  SH_CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W42\",\"title\":\"T\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}"}'
  (
    cd "$SH_DIR_H" || exit 1
    echo "$SH_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ ! -f "$SH_DIR_H/.stride-diff-upload-state" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13h: claim refresh removes the previous task's upload state"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13h: stale upload state survived the claim refresh"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_H"

  # 13i: the after_review cleanup removes the state file.
  SH_DIR_I=$(mktemp -d)
  cat > "$SH_DIR_I/.stride.md" << 'STRIDE'
## after_review
```bash
echo "reviewed"
```
STRIDE
  printf 'task_id=42\nhttp_code=200\n' > "$SH_DIR_I/.stride-diff-upload-state"
  SH_REVIEW_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/mark_reviewed"}}'
  (
    cd "$SH_DIR_I" || exit 1
    echo "$SH_REVIEW_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ ! -f "$SH_DIR_I/.stride-diff-upload-state" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13i: after_review cleanup removes the upload state"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13i: upload state survived the after_review cleanup"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_I"

  # 13j: end-to-end pre then post — a healthy after_doing upload (early +
  # refresh = exactly 2 PUTs) is NOT repeated by the before_review pass.
  SH_DIR_J=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_J="$SH_DIR_J/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_J" 0 200
  (
    setup_put_repo "$SH_DIR_J" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  SH_CALLS_J=$(grep -c '^ARGS:' "$SH_FIXTURE_J" 2>/dev/null)
  assert_eq "13j: healthy pre-path upload is not repeated by before_review" 2 "$SH_CALLS_J"
  rm -rf "$SH_DIR_J" "$STUB_DIR"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
