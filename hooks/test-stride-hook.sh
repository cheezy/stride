#!/usr/bin/env bash
# test-stride-hook.sh — Tests for stride-hook.sh pure bash replacements
#
# Tests all code paths without requiring awk, sed, or seq.
# Simulates jq-absent environments to exercise fallback paths.

set -uo pipefail

# (D235) HERMETICITY GATE — neutralise every hook-read variable the developer's
# environment might already hold, and say so out loud.
#
# stride-hook.sh reads each name below from the environment, and several take
# precedence over the value a test is trying to assert: resolve_section_budget
# checks STRIDE_HOOK_TIMEOUT_OVERRIDE FIRST, so with it set every budget
# assertion silently resolved to the developer's value instead of the value
# under test. That produced phantom failures on a machine where it was exported
# — and they sat on exactly the budget behaviour D223, D228, D229 and D230 were
# about, so the tests that should have surfaced those defects were the ones
# being ignored. A suite that reports failures it cannot explain is a suite
# people stop reading.
#
# NAMES ARE REPORTED, VALUES ARE NOT. An earlier version of this gate printed
# `NAME=VALUE`, which would have echoed a developer's bearer token to stdout and
# into any captured CI log — turning a private variable into printed output is
# strictly worse than the silent-override problem this fixes. The name alone
# makes the point.
#
# The list is DERIVED from stride-hook.sh, not guessed: every `${VAR:-}` read of
# a name the script does not itself assign first. Names that appear only in
# comments (STRIDE_API_TOKEN, STRIDE_API_URL) or are assigned unconditionally at
# file scope before any read are deliberately absent — clearing them would be
# harmless but would make this list look authoritative when it is not. A few
# that ARE assigned at file scope are kept anyway — HAS_JQ, RESPONSE_PAYLOAD and
# the SNAP_BASE_* memoisation globals — because the sourced-function subshells
# read them with a `${VAR:-}` default before that assignment runs.
#
# Silently unsetting would have been the smaller fix and the wrong one: the
# developer who exported the variable deserves to know their environment is not
# reaching the code under test. So this reports first, then neutralises.
#
# This does NOT disable deliberate overrides. Every case that tests a variable's
# effect sets it inline on the invocation it belongs to
# (`STRIDE_HOOK_TIMEOUT_OVERRIDE=5 bash "$HOOK_SCRIPT" ...`) or inside its own
# subshell, both of which run after this gate. Set STRIDE_TEST_KEEP_ENV=1 to run
# against your own environment instead — the results are then not hermetic, and
# the gate says so.
STRIDE_HOOK_ENV_VARS="
CLAUDE_PROJECT_DIR
GOAL_ID
GOAL_IDENTIFIER
HAS_JQ
HOOK_NAME
RESPONSE_PAYLOAD
SNAP_BASE_REFUSED
SNAP_BASE_RESOLVED
SNAP_BASE_RESOLVED_DONE
STRIDE_HOOK_TIME_SOURCE
STRIDE_HOOK_TIMEOUT_OVERRIDE
STRIDE_HOOK_TIMEOUT_TOOL
STRIDE_OPEN_WINDOW_MAX_AGE_SECS
TASK_BASE_REF
TASK_BASE_REF_OWNER
TASK_BASE_REF_TRUSTED
TASK_BASE_REF_UNPROVEN
TASK_ID
TASK_IDENTITY_REFRESHED
TASK_OWNER_ID
"

# stride_inherited_hook_vars — the inherited names, one per line, newest first.
# A function so the gate's own test can call it rather than re-implementing the
# detection it is meant to be checking.
stride_inherited_hook_vars() {
  local _v _found=""
  for _v in $STRIDE_HOOK_ENV_VARS; do
    if [ -n "${!_v+x}" ]; then _found="$_found  $_v
"; fi
  done
  # TASK_BASE_REF_<id> is an open-ended family keyed by task id (D226), so a
  # fixed list structurally cannot cover it — sweep the prefix instead.
  for _v in $(compgen -v TASK_BASE_REF_ 2>/dev/null); do
    case "$_v" in
      TASK_BASE_REF_OWNER | TASK_BASE_REF_TRUSTED | TASK_BASE_REF_UNPROVEN) ;;
      *) _found="$_found  $_v
" ;;
    esac
  done
  printf '%s' "$_found"
}

stride_clear_hook_vars() {
  local _v
  for _v in $STRIDE_HOOK_ENV_VARS; do unset "$_v"; done
  for _v in $(compgen -v TASK_BASE_REF_ 2>/dev/null); do unset "$_v"; done
}

STRIDE_INHERITED_ENV="$(stride_inherited_hook_vars)"

if [ -n "$STRIDE_INHERITED_ENV" ]; then
  if [ "${STRIDE_TEST_KEEP_ENV:-}" = "1" ]; then
    echo "WARNING: STRIDE_TEST_KEEP_ENV=1 — running against your environment."
    echo "These hook-read variables are INHERITED and may change what the assertions measure:"
    printf '%s\n' "$STRIDE_INHERITED_ENV"
    echo "Results are NOT hermetic. Unset STRIDE_TEST_KEEP_ENV to neutralise them."
  else
    echo "NOTE: neutralising inherited hook variables so the suite asserts the"
    echo "behaviour under test rather than your environment (D235):"
    printf '%s\n' "$STRIDE_INHERITED_ENV"
    echo "Set STRIDE_TEST_KEEP_ENV=1 to keep them instead."
    stride_clear_hook_vars
  fi
  echo ""
fi

# --gate-probe: run the gate, report what survived, exit. Used by Test Group 26
# so the gate is asserted through its real code path rather than a reimplementation.
if [ "${1:-}" = "--gate-probe" ]; then
  echo "AFTER_GATE:STRIDE_HOOK_TIMEOUT_OVERRIDE=${STRIDE_HOOK_TIMEOUT_OVERRIDE:-<unset>}"
  echo "AFTER_GATE:TASK_BASE_REF_99=${TASK_BASE_REF_99:-<unset>}"
  exit 0
fi

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

# ============================================================
# Load calibration and wall-clock reporting (D241)
# ============================================================
# THE OTHER CLUSTERS, and the verdict on them, recorded here because D241 named
# them and a reader who finds them unchanged deserves to know why. D241's
# description listed 8a/8d/8g/13c (changed_files PUT), 10a/10d/10e (hook chaining
# and after_goal JSON), 17c (command splitting), 23g/23l (D226 base-ref refusals)
# and 9a/9b as the always-failing set. Every one of those 12 was re-read: NONE
# contains a wall-clock assertion. They assert PUT counts, JSON content and exit
# codes, so the mechanism that broke them is not the one the calibration below
# fixes, and widening a bound would not have touched them.
#
# The proposed mechanism is an inherited STRIDE_HOOK_TIMEOUT_OVERRIDE forcing a
# 1s budget onto fixtures that never asked for one — D235's leak, already fixed,
# and its gate still reports neutralising that exact variable on this machine on
# every run, so the leak is live and the gate is what holds it back.
#
# THAT MECHANISM IS DEMONSTRATED, BUT ITS MAPPING ONTO THOSE 12 IS NOT. Running
# `STRIDE_TEST_KEEP_ENV=1 STRIDE_HOOK_TIMEOUT_OVERRIDE=1 ./test-stride-hook.sh`
# — the suite's own escape hatch, which lets the variable through — produces
# 580/8 rather than 588/0, and the 8 are exactly the shape the mechanism
# predicts: trivial fixtures and 1s-sleep fixtures killed by a budget they never
# asked for (the passing-gate cases, 16a, 16b, 27a). So a single inherited
# override provably does make unrelated cases fail together, which is the
# behaviour that produced the 18/21/2/2 swing.
#
# But NONE of those 8 is one of the 12 clusters D241 named. On today's tree the
# named clusters do not fail under the simulated leak, so the honest verdict is
# in two parts: it is DEMONSTRATED that none of the 12 contains a wall-clock
# assertion, and therefore that the calibration below could not have been their
# fix; and it is INFERRED, not shown, that the override leak is what broke them
# on the tree as it stood when D241 was filed. Do not read the second part as
# established. What is certain either way is that the fault was in the harness,
# NOT in stride-hook.sh, which this task leaves untouched on purpose (D241's own
# `why` retracts the regression premise its pitfalls[0] still carries).
# A handful of assertions below check that a hook was killed PROMPTLY — that a
# `sleep 30` under a 1s budget did not run to completion. Those bounds used to be
# fixed constants (`< 20s`, `< 15s`), and a fixed constant is the wrong shape for
# them: what the bound has to absorb is not the budget, which is deterministic,
# but the process-startup and scheduling OVERHEAD around it, which scales with
# whatever else the machine is doing. On a quiet machine the suite reported
# 588/0; run beside another test suite it reported failure counts swinging
# 18/21/2/2 from the identical command, and one observed kill "near 4s" took 21s.
# That cost a full task's worth of misdiagnosis (this defect was originally filed
# as a bash-side regression on that evidence, which was wrong).
#
# So: measure the overhead on THIS machine, right now, and scale the bounds by
# what we find. The deterministic evidence that the kill actually happened —
# exit 2, `"timed_out": true`, `"exit_code": 124`, the budget named in stderr,
# and the post-timeout command's file never appearing — is asserted separately in
# every one of these cases and is NOT load-sensitive. The wall-clock bound is a
# backstop against the kill silently not happening at all, so it needs to sit
# comfortably below the un-killed duration while staying above real overhead.
# Measured on this repo's dev machine: a trivial invocation costs ~130-155ms
# idle, and ~1130ms with 24 fork-heavy background processes — roughly 8x. The
# baseline is set at the idle figure so the scale starts responding as soon as
# the machine is meaningfully busier than idle, rather than only under extreme
# load.
SUITE_LOAD_BASELINE_MS=250   # idle measures 130-175ms; 250 leaves room for jitter
# Observed idle range post-D241: 82-109s across four runs (the budget floor rising
# and the second calibration pass added time; the spread is real machine variance,
# so quote the range rather than one run). Used only for the 2x warning threshold,
# where a mid-range figure is the honest choice — 90 understated it and 110
# overstated a genuinely quiet run.
# (W2107) Raised from 100 to 175. Test Group 30 adds both halves of the
# port-canon self-test: the bash half costs ~8s, the PowerShell half ~55s,
# because it re-execs its own script once per case group and PowerShell
# re-parses the whole file on every invocation. The alternative was cutting
# cases to hit the old number, which is the wrong trade -- the count is the
# coverage. Measured on the machine W2107 was written on: ~100s before, ~165s
# after.
SUITE_WALL_BASELINE_S=175

suite_now_ms() {
  if command -v perl > /dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d", time()*1000'
  else
    printf '%s' $(( $(date +%s) * 1000 ))
  fi
}

# Best of three trivial invocations. BEST, not mean: we want the machine's floor
# for "start bash, parse .stride.md, run one no-op command, exit", so a single
# scheduling hiccup during calibration does not inflate every bound in the suite.
calibrate_suite_overhead_ms() {
  local _p="$TMPDIR_TEST/.load-calibration" _s _e _best=999999 _i
  mkdir -p "$_p"
  printf '## before_doing\n\n```bash\ntrue\n```\n' > "$_p/.stride.md"
  for _i in 1 2 3; do
    _s=$(suite_now_ms)
    echo '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}' \
      | CLAUDE_PROJECT_DIR="$_p" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
    _e=$(( $(suite_now_ms) - _s ))
    [ "$_e" -lt "$_best" ] && _best=$_e
  done
  printf '%s' "$_best"
}

SUITE_START_MS=$(suite_now_ms)
SUITE_OVERHEAD_MS=$(calibrate_suite_overhead_ms)
# Integer scale, floor 1 — a machine faster than the baseline never TIGHTENS a
# bound, because these are backstops rather than performance assertions.
SUITE_LOAD_SCALE=$(( (SUITE_OVERHEAD_MS + SUITE_LOAD_BASELINE_MS - 1) / SUITE_LOAD_BASELINE_MS ))
[ "$SUITE_LOAD_SCALE" -lt 1 ] && SUITE_LOAD_SCALE=1

# A scaled wall-clock backstop, in whole seconds.
#   $1 — the base bound that holds on an idle machine
#   $2 — the UN-KILLED duration of the case: how long the hook body would take
#        if the kill never happened (i.e. its `sleep`)
#
# The cap on $2 is the load-bearing half, and scaling without it would be worse
# than the fixed constant it replaces. These bounds exist to catch one specific
# regression: the timeout silently not firing, so the body runs to completion. A
# bound that scales past the un-killed duration can no longer see that — an 8x
# scale would take 15a's bound from 20s to 160s, and a `sleep 30` that ran in
# full would sail through it. So the scaled value is clamped to stay below the
# un-killed floor, and the guard keeps its meaning at every load level. The
# margin is generous in practice: at the 8x load measured here a genuinely
# killed 1s-budget hook finishes in about 2s against a 27s bound.
wall_budget() {
  local _scaled=$(( $1 * SUITE_LOAD_SCALE )) _cap=$(( $2 - 3 ))
  # If the cap is already below the base bound the case is mis-specified — its
  # un-killed duration does not leave room for the bound it asks for. Say so
  # loudly rather than silently restoring the base, which would reinstate exactly
  # the un-clamped value this function exists to prevent.
  if [ "$_cap" -lt "$1" ]; then
    # Deliberately NOT incrementing FAIL here: this runs inside a command
    # substitution, so the increment would happen in a subshell and be lost —
    # counting it would only look like a guard. Returning the (tighter) cap is
    # what surfaces it, because the calling assertion then fails on its own.
    echo -e "  ${RED}wall_budget: base $1s does not fit under un-killed $2s${RESET}" >&2
    printf %s "$_cap"
    return
  fi
  [ "$_scaled" -gt "$_cap" ] && _scaled=$_cap
  printf %s "$_scaled"
}

# (D241) The timeout tests' own BUDGET scales too, and this is a different fix
# from the wall-clock bounds above — it removes a race rather than widening a
# backstop. Those cases run a section of `echo` / `sleep 30` under a 1s budget
# and then assert that the kill landed on command **2/3**. That holds only while
# command 1 finishes inside the budget, and command 1's cost is a fork, which is
# exactly what load inflates: the calibration above measured a trivial
# invocation at ~936ms under 24 background processes, against that 1s budget. So
# under load the budget expires on command 1 and the assertion fails on the
# index, having found nothing wrong with the code. Scaling the budget keeps
# command 1 comfortably inside it at any load, and `sleep 30` still overruns it
# by a wide margin, so the case tests what it always tested. At scale 1 — an
# idle machine — this is 1s, exactly as before.
# The floor is 2, not 1, and that matters on an IDLE machine rather than a busy
# one. run_stride_section computes its elapsed time with whole-second `date +%s`
# granularity (stride-hook.sh, `_elapsed=$(( $(date +%s) - _start_secs ))`) and
# forks two mktemps between the section start and command 1. A 1s budget is
# therefore exhausted before command 1 runs whenever a second boundary happens to
# fall across those forks — which reports `command_index: 0` and "section budget
# exhausted before this command started" instead of the "command 2/3 timed out"
# these cases assert. Scaling alone never fixed that, because at scale 1 the
# budget stayed 1s. A floor of 2 puts a whole second of slack between the forks
# and the boundary, and `sleep 30` still overruns it by 28s.
TIMEOUT_TEST_BUDGET=$(( 2 * SUITE_LOAD_SCALE ))
# CAPPED, for the same reason SPAN_TEST_BUDGET is, and the review caught that the
# first version of this line was not. These cases have ~30s un-killed bodies
# measured against `wall_budget 20 30`, which clamps at 27s — so an uncapped
# budget grows while its own backstop stands still. Wall-at-kill is roughly
# overhead + budget, which reaches the 27s cap near scale 12 on bash and scale 9
# on pwsh, and the budget itself reaches the 30s body at scale 15, where the kill
# stops firing altogether. That is not hypothetical: this defect's own record has
# a pwsh run at ~17s overhead (11d "took 21s" against a 4s budget), which would
# scale the budget to 34s and break the case the change exists to protect. At 8s
# the budget sits 22s under the body and leaves the 27s wall cap 19s for overhead.
[ "$TIMEOUT_TEST_BUDGET" -gt 8 ] && TIMEOUT_TEST_BUDGET=8

# 15e's section budget, same treatment. Its command 1 is `sleep 2`, so the base
# has to clear 2s of sleep PLUS the per-command fork and the same whole-second
# rounding — a 4s base leaves 2s of absolute margin for costs that are not purely
# wall-clock, which is thinner than it looks, and 11d (this case's mirror) is the
# one that was actually observed failing at 21s. Scaling it keeps `"command_index": 1`
# true at any load; `sleep 30` still overruns even a scaled budget comfortably.
# CAPPED, and the cap is not optional: this budget scales UP toward the very
# duration it must stay below. The section is `sleep 2; sleep 30` = ~32s, so an
# unclamped 4x8=32s budget would expire exactly as the section finished on its
# own and the kill might never fire at all — the same class of self-defeating
# scaling wall_budget is clamped against, in the opposite direction. 12s clears
# command 1 (2s of sleep plus ~1.2s of fork at the 8x load measured here) with
# room to spare, and leaves 24s of margin before the un-killed 32s. Tightened from
# 12 to 8 in review round 3: at 12 the wall-at-kill (overhead + budget) reached the
# 29s bound once overhead hit ~17s, which is the worst figure this defect's own
# record contains. At 8 that breaking point moves to ~21s, and command 1 —
# `sleep 2` plus fork and rounding, ~3-4s — still fits with 4s to spare.
SPAN_TEST_BUDGET=$(( 4 * SUITE_LOAD_SCALE ))
[ "$SPAN_TEST_BUDGET" -gt 8 ] && SPAN_TEST_BUDGET=8

if [ "$SUITE_LOAD_SCALE" -gt 1 ]; then
  echo "NOTE: this machine is loaded — a trivial hook invocation took ${SUITE_OVERHEAD_MS}ms"
  echo "      against a ${SUITE_LOAD_BASELINE_MS}ms idle baseline, so wall-clock backstops are"
  echo "      scaled ${SUITE_LOAD_SCALE}x. Timing results here are not comparable to an idle run."
  echo ""
fi

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

# ------------------------------------------------------------
# 5m-5ad (D220): routing depends on the request being ISSUED, not on the
# command text CONTAINING a lifecycle URL. Before D220 a plain grep, echo or
# doc-writing heredoc ran real commit/checkout/merge sections. Each routed URL
# gets a mention-only negative alongside its existing positive.
# ------------------------------------------------------------

# Negative helper: neither phase may run any section for this command.
assert_no_route() {
  local label="$1" fixture="$2" out code
  for _phase in post pre; do
    out=$(echo "$fixture" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" "$_phase" 2>&1)
    code=$?
    assert_exit "$label ($_phase) exits 0" 0 "$code"
    assert_eq "$label ($_phase) runs no section" "" "$out"
  done
}

# 5m: a grep whose PATTERN names a completion route does not route
assert_no_route "5m: grep for a completion route" \
  '{"tool_input":{"command":"grep -rn PATCH.*api/tasks/:id/complete test/kanban_web/"}}'

# 5n: the observed misfire — an echo of a completion URL with a fake id, which
# previously ran after_doing AND issued a live changed_files PUT to task 999999999
assert_no_route "5n: echo of a completion URL with a fake id" \
  '{"tool_input":{"command":"echo curl -X PATCH https://stridelikeaboss.com/api/tasks/999999999/complete"}}'

# 5o/5p: an exploratory GET probe of a lifecycle URL issues a request, but not
# THAT request — the method guard drops it
assert_no_route "5o: GET probe of a completion URL" \
  '{"tool_input":{"command":"curl -s https://stridelikeaboss.com/api/tasks/12345/complete"}}'
assert_no_route "5p: GET probe of the claim URL" \
  '{"tool_input":{"command":"curl -s https://stridelikeaboss.com/api/tasks/claim"}}'

# 5q/5r: mention-only negatives for the remaining two routed URLs
assert_no_route "5q: grep for a mark_reviewed route" \
  '{"tool_input":{"command":"rg -n api/tasks/[0-9]+/mark_reviewed hooks/"}}'
assert_no_route "5r: grep for the claim URL" \
  '{"tool_input":{"command":"grep -c api/tasks/claim hooks/stride-hook.sh"}}'

if command -v jq > /dev/null 2>&1; then
  # 5s: the python/cat heredoc reproduction — documentation ABOUT the completion
  # curl, at column 0 with clean quote state, satisfies every other requirement.
  # Only heredoc-body stripping stops it.
  HEREDOC_JSON=$(cat <<'JSON'
{"tool_input":{"command":"cat > docs/d220.md <<EOF\nThe completion call looks like:\n\ncurl -X PATCH \"$STRIDE_API_URL/api/tasks/$TASK_ID/complete\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" -d @payload.json\nEOF"}}
JSON
)
  assert_no_route "5s: heredoc writing docs about the completion curl" "$HEREDOC_JSON"

  # 5t: AC 3 — a changed_files PUT whose payload TEXT contains a completion URL.
  # The trigger here is content-controlled (a raw code diff), so this is the
  # security-relevant case.
  CFPUT_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -X PUT \"$STRIDE_API_URL/api/tasks/42/changed_files\" -H \"Authorization: Bearer $STRIDE_API_TOKEN\" -d '{\"changed_files\":[{\"path\":\"SKILL.md\",\"diff\":\"+curl -X PATCH https://h/api/tasks/9/complete\"}]}'"}}
JSON
)
  assert_no_route "5t: changed_files PUT with a completion URL in its payload" "$CFPUT_JSON"

  # 5u: the same, but the diff spans lines and one BEGINS with the completion
  # curl — a command position on its face, defeated by quote-state tracking
  CFPUT_ML_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -X PUT \"$STRIDE_API_URL/api/tasks/42/changed_files\" -d '{\"diff\":\"--- a/SKILL.md\n+++ b/SKILL.md\ncurl -X PATCH \\\"$STRIDE_API_URL/api/tasks/7/complete\\\" \\\n  -H \\\"Authorization: Bearer tok\\\"\n\"}'"}}
JSON
)
  assert_no_route "5u: changed_files PUT whose diff line starts with the completion curl" "$CFPUT_ML_JSON"
fi

# 5v: interpolated claim URL still routes (pitfall: agents rarely write literals)
ICLAIM_JSON='{"tool_input":{"command":"curl -sS -X POST $STRIDE_API_URL/api/tasks/claim -d @payload.json"}}'
OUTPUT=$(echo "$ICLAIM_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "5v: interpolated claim exits 0" 0 "$EXIT_CODE"
assert_contains "5v: interpolated claim still runs before_doing" "before_doing_executed" "$OUTPUT"

if command -v jq > /dev/null 2>&1; then
  # 5w: the DOCUMENTED completion curl — interpolated, backslash-continued over
  # five physical lines, piped into tee. A silent failure here would remove the
  # after_doing quality gate entirely, so both phases are asserted.
  MLCOMPLETE_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -sS -X PATCH \"$STRIDE_API_URL/api/tasks/$TASK_ID/complete\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  -H 'Content-Type: application/json' \\\n  -d @payload.json \\\n  | tee \"$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json\""}}
JSON
)
  OUTPUT=$(echo "$MLCOMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
  assert_contains "5w: documented multi-line completion still runs after_doing" "after_doing_executed" "$OUTPUT"
  OUTPUT=$(echo "$MLCOMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "5w: documented multi-line completion still runs before_review" "before_review_executed" "$OUTPUT"

  # 5x: the URL on its own continuation line, not the curl line
  URLONOWNLINE_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -sS -X PATCH \\\n  \"$STRIDE_API_URL/api/tasks/1234/complete\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  -d @payload.json"}}
JSON
)
  OUTPUT=$(echo "$URLONOWNLINE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
  assert_contains "5x: URL on its own continuation line still runs after_doing" "after_doing_executed" "$OUTPUT"

  # 5y: brace-form interpolation, multi-line mark_reviewed
  MLREVIEW_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -sS -X PATCH \"${STRIDE_API_URL}/api/tasks/77/mark_reviewed\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  -d @review.json"}}
JSON
)
  OUTPUT=$(echo "$MLREVIEW_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "5y: interpolated mark_reviewed still runs after_review" "after_review_executed" "$OUTPUT"

  # 5ad: a REAL completion whose payload text names a mark_reviewed URL routes to
  # before_review, never after_review — payload text must not steer the section
  MIXED_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -X PATCH \"$STRIDE_API_URL/api/tasks/5/complete\" -H \"Authorization: Bearer $T\" -d '{\"completion_notes\":\"then I hit /api/tasks/6/mark_reviewed by hand\"}'"}}
JSON
)
  OUTPUT=$(echo "$MIXED_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "5ad: completion with a mark_reviewed mention runs before_review" "before_review_executed" "$OUTPUT"
  assert_eq "5ad: and does NOT run after_review" "" "$(echo "$OUTPUT" | grep -F after_review_executed || true)"
fi

# 5z: the URL AFTER the flags still routes
URLLAST_JSON='{"tool_input":{"command":"curl -sS -X PATCH -d @payload.json $STRIDE_API_URL/api/tasks/77/complete"}}'
OUTPUT=$(echo "$URLLAST_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
assert_contains "5z: URL after the flags still runs before_review" "before_review_executed" "$OUTPUT"

# 5aa: a compound command whose curl is not the first token
ANDCLAIM_JSON='{"tool_input":{"command":"mkdir -p .stride && curl -X POST $STRIDE_API_URL/api/tasks/claim -d @p.json"}}'
OUTPUT=$(echo "$ANDCLAIM_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
assert_contains "5aa: && before the claim curl still runs before_doing" "before_doing_executed" "$OUTPUT"

# 5ab: timeout/env/absolute-path wrappers still reach the client
PFX_JSON='{"tool_input":{"command":"timeout 60 env FOO=1 /usr/bin/curl -X PATCH https://h/api/tasks/9/complete -d @p.json"}}'
OUTPUT=$(echo "$PFX_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_contains "5ab: timeout/env/abs-path wrappers still run after_doing" "after_doing_executed" "$OUTPUT"

# 5ac: implied POST (curl defaults to POST when -d is present, no -X)
IMPL_JSON='{"tool_input":{"command":"curl -d @payload.json $STRIDE_API_URL/api/tasks/claim"}}'
OUTPUT=$(echo "$IMPL_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
assert_contains "5ac: implied-POST claim still runs before_doing" "before_doing_executed" "$OUTPUT"

if command -v jq > /dev/null 2>&1; then
  # 5ae: the escaped-quote bypass. A -d payload placed BEFORE the URL, whose
  # embedded \" would flip a parity-only quote tracker back OUT of quoting, must
  # not let payload text supply the request URL and method. This is the same
  # PUT-not-a-completion case as 5t, ordered the other way round so _s_urlseen
  # cannot be what saves it.
  ESCQ_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -X PUT -d \"{\\\"diff\\\":\\\"x curl -X PATCH https://h/api/tasks/9/complete y\\\"}\" \"$U/api/tasks/42/changed_files\""}}
JSON
)
  assert_no_route "5ae: escaped-quote payload before the URL" "$ESCQ_JSON"
fi

# 5af: pitfall 2 — the whole URL hoisted into a shell variable still routes.
# This form routed before D220, so failing it would be a silent regression that
# removes the after_doing gate.
HOISTED_JSON='{"tool_input":{"command":"URL=\"$STRIDE_API_URL/api/tasks/$TASK_ID/complete\"; curl -X PATCH \"$URL\" -d @payload.json"}}'
OUTPUT=$(echo "$HOISTED_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_contains "5af: hoisted-URL completion still runs after_doing" "after_doing_executed" "$OUTPUT"
OUTPUT=$(echo "$HOISTED_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
assert_contains "5af: hoisted-URL completion still runs before_review" "before_review_executed" "$OUTPUT"

# 5ag: a hoisted variable that does NOT name the API is not resolved into one
HOISTED_NEG_JSON='{"tool_input":{"command":"URL=\"https://example.com/health\"; curl -X PATCH \"$URL\" -d @payload.json"}}'
OUTPUT=$(echo "$HOISTED_NEG_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_eq "5ag: unrelated hoisted URL runs no section" "" "$OUTPUT"

# 5ah: a CRLF command line still routes. The CR must sit on the URL token — with
# it on a trailing flag the assertion would pass with or without the strip.
CRLF_JSON='{"tool_input":{"command":"curl -X PATCH -d @p.json https://h/api/tasks/55/complete\r"}}'
OUTPUT=$(echo "$CRLF_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_contains "5ah: CRLF command still runs after_doing" "after_doing_executed" "$OUTPUT"

if command -v jq > /dev/null 2>&1; then
  # 5ai-5ak: the heredoc stripper is the only control that stops a command
  # WRITING documentation about the completion curl from being routed as one, so
  # its view of the command must not diverge from bash's.

  # 5ai: a here-string on the opener line must skip only itself, not disable
  # heredoc detection for the whole line
  HD_HERESTRING_JSON=$(cat <<'JSON'
{"tool_input":{"command":"grep -q x <<< \"$s\" && cat > d.md <<EOF\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nEOF"}}
JSON
)
  assert_no_route "5ai: here-string on the opener line" "$HD_HERESTRING_JSON"

  # 5aj: two heredocs on one line — both bodies must be stripped, in order
  HD_TWO_JSON=$(cat <<'JSON'
{"tool_input":{"command":"cat <<DOC > d.md; cat <<JSONP > p.json\ndocs\nDOC\ncurl -X PATCH https://h/api/tasks/9/complete\nJSONP"}}
JSON
)
  assert_no_route "5aj: two heredocs on one line" "$HD_TWO_JSON"

  # 5ak: <<- strips only TABS in bash, so a SPACE-indented lookalike does not end
  # the body and the real curl below it is still inside the heredoc
  HD_DASH_JSON=$(cat <<'JSON'
{"tool_input":{"command":"cat <<-EOF > d.md\ndocs\n  EOF\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nEOF"}}
JSON
)
  assert_no_route "5ak: <<- with a space-indented delimiter lookalike" "$HD_DASH_JSON"

  # 5al: $'...' is ANSI-C quoting — \' does NOT close it, so payload text after
  # an escaped apostrophe must not be scanned as syntax
  ANSIC_JSON=$(cat <<'JSON'
{"tool_input":{"command":"curl -X PUT -d $'a\\'b curl -X PATCH /api/tasks/9/complete x' \"$U/api/tasks/42/changed_files\""}}
JSON
)
  assert_no_route "5al: ANSI-C quoted payload with an escaped apostrophe" "$ANSIC_JSON"
fi

# 5am: a read-only probe with an unresolvable method carries no body, so it must
# NOT be granted the -X "$METHOD" leniency
assert_no_route "5am: methodless probe with an unresolvable -X" \
  '{"tool_input":{"command":"curl -X \"$METHOD\" https://h/api/tasks/9/complete"}}'

# 5an: a redirection target is not a request URL
assert_no_route "5an: redirect target that looks like a completion URL" \
  '{"tool_input":{"command":"curl -X POST https://example.com/x -d @p.json > /tmp/api/tasks/9/complete"}}'

# 5ao: neither is an unrecognised option's value
assert_no_route "5ao: --dump-header value that looks like a completion URL" \
  '{"tool_input":{"command":"curl --dump-header /api/tasks/9/complete -X POST https://example.com/x -d @p.json"}}'

# 5ax: a redirect on a HIGH file descriptor must consume its target too — an
# operator table covering only fds 0-2 leaves the target to be read as the
# request URL, which both picks the section and supplies the task id
REDIR_FD_JSON='{"tool_input":{"command":"curl -X PATCH -d @p.json 3> /tmp/api/tasks/9/complete \"$STRIDE_API_URL/api/tasks/5/complete\""}}'
OUTPUT=$(echo "$REDIR_FD_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
assert_contains "5ax: high-fd redirect does not displace the real URL" "before_review_executed" "$OUTPUT"

if command -v jq > /dev/null 2>&1; then
  # 5ay: `<<''` is a valid heredoc whose body ends at the first EMPTY line.
  # Guarding the queue on the quote-stripped delimiter dropped it entirely and
  # left the body — a completion curl at column 0 — to be scanned as syntax.
  HD_EMPTY_JSON=$(cat <<'JSON'
{"tool_input":{"command":"cat <<'' > d.md\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\n\nx"}}
JSON
)
  assert_no_route "5ay: heredoc with an empty delimiter" "$HD_EMPTY_JSON"

  # 5az: a `<<` inside a QUOTED string is text, not an opener. Read as an opener
  # it swallows lines until one equals the derived word — which here would eat
  # the opening quote of the payload below and let its text be scanned as syntax.
  HD_INQUOTE_JSON=$(cat <<'JSON'
{"tool_input":{"command":"echo \"shift << END\"\ncurl -X PUT \"$U/api/tasks/42/changed_files\" -d '{\"diff\":\"\nEND\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\n\"}'"}}
JSON
)
  assert_no_route "5az: << inside a quoted string is not a heredoc opener" "$HD_INQUOTE_JSON"

  # 5ba: the fail-closed half of the same defect — a stray `<<` in a quoted
  # string must not swallow a REAL completion curl on a later line
  HD_NOSWALLOW_JSON=$(cat <<'JSON'
{"tool_input":{"command":"echo \"a << b\"\ncurl -X PATCH https://h/api/tasks/77/complete -d @p.json"}}
JSON
)
  OUTPUT=$(echo "$HD_NOSWALLOW_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
  assert_contains "5ba: a quoted << does not swallow a real completion" "after_doing_executed" "$OUTPUT"
fi

# 5ap: a subshell-wrapped completion still routes (fail-closed narrowings are
# acceptable, but not for a form this close to the documented one)
SUBSH_JSON='{"tool_input":{"command":"(curl -X PATCH \"$STRIDE_API_URL/api/tasks/321/complete\" -d @payload.json)"}}'
OUTPUT=$(echo "$SUBSH_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_contains "5ap: subshell-wrapped completion still runs after_doing" "after_doing_executed" "$OUTPUT"

# 5aq: the hoisted URL on a SEPARATE line from the curl (the curl line names no
# path of its own, so the per-line fast path must not skip it)
HOIST2_JSON='{"tool_input":{"command":"URL=\"$STRIDE_API_URL/api/tasks/1234/complete\"\ncurl -X PATCH \"$URL\" -d @payload.json"}}'
OUTPUT=$(echo "$HOIST2_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_contains "5aq: two-line hoisted URL still runs after_doing" "after_doing_executed" "$OUTPUT"

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

    # (D279) Kept in lockstep with capture_changed_files' own counter. This
    # helper is a hand-duplicated mirror of that code, so leaving the quadratic
    # substitution here would have meant Group 7 went on testing the old path
    # and proving nothing about the fix.
    local line_count=0
    if [ -n "$diff_text" ]; then
      line_count=$(printf '%s\n' "$diff_text" | wc -l | tr -d ' ')
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

  # ----------------------------------------------------------
  # (D278) Non-ASCII paths. git quotes any path holding a byte >= 0x80 in its
  # non--z output (core.quotePath, default true), so the pre-fix code wrote the
  # octal-escaped display spelling into the snapshot AND fed it back to
  # `git diff -- <path>`, where it matches nothing: fabricated path, EMPTY
  # diff, 100% of that file's content lost. These cases pin the -z contract.
  # They assert a NON-EMPTY diff body, not just the path — an assertion on the
  # path alone passes on a half-fixed implementation.
  # ----------------------------------------------------------

  # 7x: tracked file with a non-ASCII NAME — real path, real diff body
  NA1_DIR=$(mktemp -d)
  NA1_OUTPUT=$(
    cd "$NA1_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'v1\n' > "док.txt"
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    printf 'v2-changed\n' > "док.txt"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  assert_eq "D278: non-ASCII filename appears under its real repo-relative path" \
    "док.txt" \
    "$(echo "$NA1_OUTPUT" | jq -r '.[0].path')"
  assert_contains "D278: non-ASCII filename carries a real diff body" \
    "+v2-changed" \
    "$(echo "$NA1_OUTPUT" | jq -r '.[0].diff')"
  rm -rf "$NA1_DIR"

  # 7y: ASCII file under a non-ASCII DIRECTORY component — one Cyrillic folder
  # otherwise loses every file beneath it
  NA2_DIR=$(mktemp -d)
  NA2_OUTPUT=$(
    cd "$NA2_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    mkdir -p "док"
    printf 'v1\n' > "док/plain.txt"
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    printf 'v2-under-dir\n' > "док/plain.txt"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  assert_eq "D278: ASCII file under a non-ASCII directory keeps its real path" \
    "док/plain.txt" \
    "$(echo "$NA2_OUTPUT" | jq -r '.[0].path')"
  assert_contains "D278: ASCII file under a non-ASCII directory carries a real diff body" \
    "+v2-under-dir" \
    "$(echo "$NA2_OUTPUT" | jq -r '.[0].diff')"
  rm -rf "$NA2_DIR"

  # 7z: UNTRACKED file with a non-ASCII name is captured as a new-file patch
  NA3_DIR=$(mktemp -d)
  NA3_OUTPUT=$(
    cd "$NA3_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'seed\n' > seed.txt
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    printf 'brand-new\n' > "файл.txt"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  assert_eq "D278: untracked non-ASCII file appears under its real path" \
    "файл.txt" \
    "$(echo "$NA3_OUTPUT" | jq -r '.[] | select(.path == "файл.txt") | .path')"
  assert_contains "D278: untracked non-ASCII file carries its new-file patch body" \
    "+brand-new" \
    "$(echo "$NA3_OUTPUT" | jq -r '.[] | select(.path == "файл.txt") | .diff')"
  rm -rf "$NA3_DIR"

  # 7aa: BINARY under a non-ASCII path gets the placeholder, never a raw
  # "Binary files ... differ" body
  NA4_DIR=$(mktemp -d)
  NA4_OUTPUT=$(
    cd "$NA4_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    mkdir -p "док"
    printf 'AAA\000\001\002bin' > "док/bin.dat"
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    printf 'BBB\000\001\002bin-changed\377' > "док/bin.dat"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  NA4_DIFF=$(echo "$NA4_OUTPUT" | jq -r '.[] | select(.path == "док/bin.dat") | .diff')
  assert_eq "D278: binary under a non-ASCII path gets the binary placeholder" \
    "[binary file — no diff captured]" \
    "$NA4_DIFF"
  rm -rf "$NA4_DIR"

  # 7bb: RENAMED binary under a non-ASCII directory. `--numstat -z` emits THREE
  # NUL tokens for a rename ("<a>TAB<d>TAB", old path, new path) where an
  # ordinary entry is one — the pre-fix fixed-three-field TAB scan could never
  # match a renamed file, so a renamed binary escaped the placeholder and
  # leaked a raw "Binary files ... differ" body.
  NA5_DIR=$(mktemp -d)
  NA5_OUTPUT=$(
    cd "$NA5_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    mkdir -p "док"
    printf 'AAA\000\011bin\377' > "док/bin2.dat"
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    git mv "док/bin2.dat" "док/бинарный.dat" > /dev/null 2>&1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  NA5_DIFF=$(echo "$NA5_OUTPUT" | jq -r '.[] | select(.path == "док/бинарный.dat") | .diff')
  assert_eq "D278: renamed binary under a non-ASCII directory gets the placeholder" \
    "[binary file — no diff captured]" \
    "$NA5_DIFF"
  if echo "$NA5_DIFF" | grep -qF "Binary files"; then
    echo -e "  ${RED}FAIL${RESET}: D278: renamed binary leaked a raw Binary-files body"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: D278: renamed binary did not leak a raw Binary-files body"
    PASS=$((PASS + 1))
  fi
  rm -rf "$NA5_DIR"

  # 7cc: core.quotePath=false must keep working. It sidesteps the defect on its
  # own, so this is the non-regression guard for users who already set it —
  # the fix must not depend on the default being in force.
  NA6_DIR=$(mktemp -d)
  NA6_OUTPUT=$(
    cd "$NA6_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git config core.quotePath false
    mkdir -p "док"
    printf 'v1\n' > "док/plain.txt"
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    printf 'v2-quotepath-off\n' > "док/plain.txt"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  assert_eq "D278: core.quotePath=false still yields the real path" \
    "док/plain.txt" \
    "$(echo "$NA6_OUTPUT" | jq -r '.[0].path')"
  assert_contains "D278: core.quotePath=false still yields a real diff body" \
    "+v2-quotepath-off" \
    "$(echo "$NA6_OUTPUT" | jq -r '.[0].diff')"
  rm -rf "$NA6_DIR"

  # 7dd: the baseline <-> capture interaction on a non-ASCII path. This is the
  # reason record_dirty_baseline was converted to -z alongside the capture:
  # capture_changed_files string-compares each baseline path against its own
  # now-RAW $file, so if the baseline still recorded the QUOTED spelling the two
  # could never match and the W1457 pre-existing-edit filter would go silently
  # inert for exactly these paths. Fixing the capture alone would have caused
  # that. Asserting the baseline's spelling AND both filter directions is what
  # stops a future edit re-opening it — Group 18 covers this only for ASCII.
  NA7_DIR=$(mktemp -d)
  (
    cd "$NA7_DIR" || exit 1
    git init -q .
    git config user.email "test@test.local"
    git config user.name "Test"
    mkdir -p "док"
    printf 'one\n' > "док/pre.txt"
    printf 'keep\n' > "док/work.txt"
    git add -A > /dev/null
    git commit -q -m "initial"
    git rev-parse HEAD > base.ref

    # Pre-claim: the non-ASCII path is already dirty.
    printf 'pre-existing edit\n' >> "док/pre.txt"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    PROJECT_DIR="$PWD"
    record_dirty_baseline "$(cat base.ref)"
    cp .stride-dirty-baseline baseline.copy 2>/dev/null || true

    # Task work touches a DIFFERENT non-ASCII path.
    printf 'task edit\n' >> "док/work.txt"
    capture_changed_files "$(cat base.ref)" > snap1.json 2>/dev/null

    # Now the claim-dirty path is touched again during the task.
    printf 'task also touched\n' >> "док/pre.txt"
    capture_changed_files "$(cat base.ref)" > snap2.json 2>/dev/null
  )
  NA7_BASELINE=$(cat "$NA7_DIR/baseline.copy" 2>/dev/null)
  NA7_SNAP1=$(jq -r '.[].path' "$NA7_DIR/snap1.json" 2>/dev/null)
  NA7_SNAP2=$(jq -r '.[].path' "$NA7_DIR/snap2.json" 2>/dev/null)
  assert_contains "D278: baseline records a non-ASCII path in its RAW spelling" \
    "док/pre.txt" "$NA7_BASELINE"
  if echo "$NA7_BASELINE" | grep -qF '\320'; then
    echo -e "  ${RED}FAIL${RESET}: D278: baseline recorded the octal-quoted spelling"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: D278: baseline did not record the octal-quoted spelling"
    PASS=$((PASS + 1))
  fi
  assert_contains "D278: task-modified non-ASCII path appears in the snapshot" \
    "док/work.txt" "$NA7_SNAP1"
  if echo "$NA7_SNAP1" | grep -qx "док/pre.txt"; then
    echo -e "  ${RED}FAIL${RESET}: D278: claim-dirty non-ASCII path must NOT appear (W1457 filter inert)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: D278: claim-dirty non-ASCII path excluded by the W1457 filter"
    PASS=$((PASS + 1))
  fi
  assert_contains "D278: claim-dirty non-ASCII path RE-modified during the task IS included" \
    "док/pre.txt" "$NA7_SNAP2"
  rm -rf "$NA7_DIR"

  # 7ee: TEXT rename under a non-ASCII directory. 7bb covers the binary rename
  # (the placeholder branch); this covers the ordinary shape, which exercises
  # the per-file `git diff <base> -- <file>` body — the call that returned
  # EMPTY for a quoted path and is the defect's second half.
  NA8_DIR=$(mktemp -d)
  NA8_OUTPUT=$(
    cd "$NA8_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    mkdir -p "док"
    printf 'renamed-content\n' > "док/ren.txt"
    git add -A > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    git mv "док/ren.txt" "док/переименован.txt" > /dev/null 2>&1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  NA8_DIFF=$(echo "$NA8_OUTPUT" | jq -r '.[] | select(.path == "док/переименован.txt") | .diff')
  assert_eq "D278: text rename under a non-ASCII directory lands under its new real path" \
    "док/переименован.txt" \
    "$(echo "$NA8_OUTPUT" | jq -r '.[] | select(.path == "док/переименован.txt") | .path')"
  if [ -n "$NA8_DIFF" ]; then
    echo -e "  ${GREEN}PASS${RESET}: D278: text rename under a non-ASCII directory carries a non-empty diff body"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D278: text rename under a non-ASCII directory has an EMPTY diff body"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NA8_DIR"

  # 7ff: bash/PowerShell snapshot parity on a non-ASCII fixture — the task's
  # one integration test, and the criterion the rest of this group cannot
  # reach on its own. The two executors are meant to be semantically
  # interchangeable; D278 existed precisely because they had silently stopped
  # being so, and only a head-to-head run proves they are again.
  #
  # HARNESS: stride-hook.ps1 cannot be dot-sourced — it interleaves function
  # definitions with top-level flow, so a plain `. script` defines nothing
  # useful. The functions are extracted from the real file by AST and
  # dot-sourced individually, exactly as Test Group 22 of the PowerShell suite
  # does (test-stride-hook.ps1:5204-5231). Binding to the shipped text is the
  # point: a re-implementation would prove nothing about the code that ships.
  # Read-DirtyBaseline is in the extraction list because
  # Build-ChangedFilesSnapshot calls it and the function's own try/catch
  # swallows the resulting error into a bare '[]' — a missing extraction here
  # is invisible, which is why the harness hard-fails on an incomplete one.
  if ! command -v pwsh > /dev/null 2>&1; then
    if [ "${STRIDE_PS1_GATE_REQUIRED:-0}" = "1" ]; then
      echo -e "  ${RED}FAIL${RESET}: 7ff: STRIDE_PS1_GATE_REQUIRED=1 but pwsh is not installed"
      FAIL=$((FAIL + 1))
    else
      echo "  SKIP: 7ff: pwsh not installed — the bash/PowerShell parity check needs it"
      echo "        (set STRIDE_PS1_GATE_REQUIRED=1 to make this a failure instead)"
    fi
  else
    PAR_DIR=$(mktemp -d)
    PAR_REF_FILE=$(mktemp)
    export PAR_REF_FILE
    (
      cd "$PAR_DIR" || exit 1
      git init -q .
      git config user.email "test@test.local"
      git config user.name "Test"
      mkdir -p "док"
      printf 'v1\n' > "док/plain.txt"
      printf 'v1\n' > ascii.txt
      printf 'AAA\000\001bin' > "док/bin.dat"
      git add -A > /dev/null
      git commit -q -m "base"
      git rev-parse HEAD > "$PAR_REF_FILE"
      # A second commit so the HEAD~1 fallback inside the ps1 is reachable and
      # the two implementations resolve the same base.
      printf 'seed2\n' > seed2.txt
      git add seed2.txt > /dev/null
      git commit -q -m "second"
      # Divergent working tree: tracked edits, a binary edit, an untracked add,
      # each touching a non-ASCII path or living under one.
      printf 'v2-changed\n' > "док/plain.txt"
      printf 'v2-ascii\n' > ascii.txt
      printf 'BBB\000\001bin-new\377' > "док/bin.dat"
      printf 'brand-new\n' > "файл.txt"
    )
    PAR_BASE=$(cat "$PAR_REF_FILE")
    PAR_BASH=$(
      cd "$PAR_DIR" || exit 1
      # shellcheck disable=SC1090
      source "$HOOK_SCRIPT" 2>/dev/null || true
      capture_changed_files "$PAR_BASE"
    ) 2>/dev/null
    # NOT inside $PAR_DIR: the fixture is a git repo, so a file written there
    # is an untracked path the snapshot would capture — and it would land
    # between the two runs, appearing on one side only.
    PAR_PS1_FILE=$(mktemp)
    cat > "$PAR_PS1_FILE" <<'PARITY_PS1'
param([string]$HookPs1, [string]$Dir, [string]$Base)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HookPs1, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$want = @('Get-GitDiffBody','Split-NulList','Get-NumstatBinarySet','Test-SafeRepoPath',
          'Invoke-GitCapture','Expand-OwnRanges','Build-ChangedFilesSnapshot','Read-DirtyBaseline')
$got = @()
foreach ($f in $fns) { if ($want -contains $f.Name) { $got += $f.Name; . ([scriptblock]::Create($f.Extent.Text)) } }
# A silently-incomplete extraction would make the comparison pass vacuously on
# '[]' == '[]', so refuse to produce output at all.
if ($got.Count -ne $want.Count) {
    [Console]::Error.WriteLine("extraction incomplete: got $($got -join ',')")
    exit 1
}
$ProjectDir = $Dir
$global:ProjectDir = $Dir
Set-Location $Dir
Build-ChangedFilesSnapshot -Base $Base -OwnRanges ''
PARITY_PS1
    PAR_PS1_HOOK="$SCRIPT_DIR/stride-hook.ps1"
    PAR_PS=$(pwsh -NoProfile -File "$PAR_PS1_FILE" "$PAR_PS1_HOOK" "$PAR_DIR" "$PAR_BASE" 2>/dev/null)
    rm -f "$PAR_PS1_FILE"
    # Compare the SEMANTIC shape: which paths, which are binary placeholders,
    # which carry an empty body. Raw diff text legitimately differs (git's own
    # patch headers echo core.quotePath), so comparing it byte-for-byte would
    # fail on a difference the criterion does not care about.
    PAR_NORM='map({path: .path, ph: (.diff | startswith("[binary file")), empty: (.diff == "")}) | sort_by(.path)'
    PAR_BASH_N=$(echo "$PAR_BASH" | jq -S "$PAR_NORM" 2>/dev/null)
    PAR_PS_N=$(echo "$PAR_PS" | jq -S "$PAR_NORM" 2>/dev/null)
    if [ -z "$PAR_PS_N" ] || [ "$PAR_PS_N" = "[]" ]; then
      echo -e "  ${RED}FAIL${RESET}: 7ff: the PowerShell harness produced no snapshot to compare"
      FAIL=$((FAIL + 1))
    else
      assert_eq "D278: bash and PowerShell snapshots agree on a non-ASCII fixture" \
        "$PAR_BASH_N" "$PAR_PS_N"
      # Guard the comparison itself: agreement on a set that never contained a
      # non-ASCII path would be agreement about nothing.
      assert_contains "D278: the parity fixture actually exercised a non-ASCII path" \
        "док/plain.txt" "$PAR_BASH_N"
      assert_contains "D278: the parity fixture actually exercised a binary placeholder" \
        '"ph": true' "$PAR_BASH_N"
    fi
    rm -rf "$PAR_DIR"; rm -f "$PAR_REF_FILE"
  fi

  # 7hh2 (D286): bash/PowerShell parity for the DIRTY BASELINE, which 7ff above
  # does not cover — it extracts Read-DirtyBaseline but never the WRITER, so the
  # one artifact whose two implementations had diverged was the one the parity
  # check could not see. That divergence was D286: Write-DirtyBaseline listed
  # without -z and recorded the octal-escaped display spelling, while its own
  # snapshot capture recorded the raw one, so the W1457 pre-existing-edit filter
  # went silently inert for non-ASCII paths on Windows only.
  #
  # A separate case rather than an extension of 7ff, deliberately: 7ff passes
  # today and compares snapshots, and folding a second artifact into it would
  # put a passing check at risk to test something it was not built for. This
  # compares only the PATH SPELLINGS the two writers record, which is the whole
  # of the property that diverged.
  if ! command -v pwsh > /dev/null 2>&1; then
    if [ "${STRIDE_PS1_GATE_REQUIRED:-}" = "1" ]; then
      echo -e "  ${RED}FAIL${RESET}: 7hh2: STRIDE_PS1_GATE_REQUIRED=1 but pwsh is not installed"
      FAIL=$((FAIL + 1))
    else
      echo "  SKIP: 7hh2: pwsh not installed — the baseline parity check needs it"
    fi
  else
    BL_DIR=$(mktemp -d)
    BL_REF=$(mktemp)
    (
      cd "$BL_DIR" || exit 1
      git init -q .
      git config user.email "test@test.local"
      git config user.name "Test"
      mkdir -p "док"
      printf 'v1\n' > "док/plain.txt"
      printf 'v1\n' > "éclair.txt"
      git add -A > /dev/null
      git commit -q -m base
      git rev-parse HEAD > "$BL_REF"
      # Dirty at claim time: one tracked non-ASCII edit, one tracked edit under a
      # non-ASCII directory, and one untracked non-ASCII add.
      printf 'v2\n' > "док/plain.txt"
      printf 'v2\n' > "éclair.txt"
      printf 'new\n' > "новый.txt"
    )
    BL_BASE=$(cat "$BL_REF")
    BL_BASH_PATHS=$(
      cd "$BL_DIR" || exit 1
      PROJECT_DIR="$BL_DIR"
      # shellcheck disable=SC1090
      source "$HOOK_SCRIPT" 2>/dev/null || true
      PROJECT_DIR="$BL_DIR"
      record_dirty_baseline "$BL_BASE" > /dev/null 2>&1
      # sed, not awk: rebuilding the record with awk's default OFS collapses
      # runs of whitespace INSIDE a path, while the PowerShell side's
      # -replace '^\S+ ' preserves them — the two sides would then disagree
      # spuriously on any path holding two consecutive spaces or a tab. Latent
      # on this fixture, which has none; fixed anyway because a parity check
      # that can report a false divergence is worse than none.
      sed 's/^[^ ]* //' "$BL_DIR/.stride-dirty-baseline" 2>/dev/null | LC_ALL=C sort
    )
    rm -f "$BL_DIR/.stride-dirty-baseline"
    BL_PS1_FILE=$(mktemp)
    cat > "$BL_PS1_FILE" <<'BASELINE_PS1'
param([string]$HookPs1, [string]$Dir, [string]$Base)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HookPs1, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$want = @('Write-DirtyBaseline','Split-NulList','Get-GitDiffBody','Invoke-GitCapture')
$got = @()
foreach ($f in $fns) { if ($want -contains $f.Name) { $got += $f.Name; . ([scriptblock]::Create($f.Extent.Text)) } }
if ($got.Count -ne $want.Count) {
    [Console]::Error.WriteLine("extraction incomplete: got $($got -join ',')")
    exit 1
}
$ProjectDir = $Dir
$global:ProjectDir = $Dir
Set-Location $Dir
Write-DirtyBaseline -BaseRef $Base
$bl = Join-Path $Dir '.stride-dirty-baseline'
if (Test-Path -LiteralPath $bl) {
    Get-Content -LiteralPath $bl -Encoding UTF8 | ForEach-Object { ($_ -replace '^\S+ ', '') }
}
BASELINE_PS1
    BL_PS_PATHS=$(pwsh -NoProfile -File "$BL_PS1_FILE" "$SCRIPT_DIR/stride-hook.ps1" "$BL_DIR" "$BL_BASE" 2>/dev/null | LC_ALL=C sort)
    rm -f "$BL_PS1_FILE"
    if [ -z "$BL_PS_PATHS" ]; then
      echo -e "  ${RED}FAIL${RESET}: 7hh2: the PowerShell harness produced no baseline to compare"
      FAIL=$((FAIL + 1))
    else
      assert_eq "7hh2 (D286): bash and PowerShell record the SAME baseline path spellings on a non-ASCII fixture" \
        "$BL_BASH_PATHS" "$BL_PS_PATHS"
      # Non-vacuity, twice: agreement on a set that never held a non-ASCII path
      # would be agreement about nothing, and agreement on the QUOTED spelling
      # would be both sides being wrong together — which is exactly the state
      # this pair was in before D278 fixed the bash half.
      assert_contains "7hh2 (D286): the fixture really exercised a non-ASCII path" \
        "éclair.txt" "$BL_BASH_PATHS"
      if printf '%s' "$BL_BASH_PATHS" | grep -q '\\3'; then
        echo -e "  ${RED}FAIL${RESET}: 7hh2 (D286): the baseline recorded an octal-escaped path, not the raw spelling"
        FAIL=$((FAIL + 1))
      else
        echo -e "  ${GREEN}PASS${RESET}: 7hh2 (D286): both sides record the RAW spelling, not the octal-escaped one"
        PASS=$((PASS + 1))
      fi
    fi
    rm -rf "$BL_DIR"; rm -f "$BL_REF"
  fi

  # 7gg (D279): a long single-line diff must capture in linear time. The old
  # counter built a second copy of the diff with the newlines substituted out,
  # which bash does quadratically once the line is long: MEASURED at 9,529 ms
  # for 100KB, 37,488 ms for 200KB, and beyond the 120s after_doing budget at
  # 400KB — where the hook is killed and the snapshot is lost SILENTLY, the
  # completion still succeeding with no diffs in Review. After the fix the same
  # three inputs take 116 / 127 / 157 ms.
  #
  # The ceiling below is deliberately loose. This suite already warns that its
  # wall-clock backstops skew when the machine is loaded, so a tight bound
  # would flake; 30s still leaves ~190x headroom over the measured 157 ms while
  # catching any return to quadratic, which blew straight past 120s.
  #
  # The shape matters as much as the size: a 400KB string with NO newline at
  # all runs the old idiom in 112 ms. The blowup needs newlines PRESENT in a
  # long line — a minified bundle, a one-line lockfile, a base64 asset — so the
  # fixture is a single very long line inside a real diff, not a bare string.
  PERF_DIR=$(mktemp -d)
  (
    cd "$PERF_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo seed > seed.txt
    git add -A > /dev/null
    git commit -q -m "base"
    # ~400KB on one line, the shape a minified bundle has. Built with tr from
    # /dev/zero rather than by string concatenation in a loop — appending in a
    # shell or awk loop is itself quadratic, which would make the fixture, not
    # the code under test, the slow part.
    head -c 409600 /dev/zero | tr '\0' 'x' > bundle.min.js
    printf '\n' >> bundle.min.js
  )
  PERF_BASE=$(cd "$PERF_DIR" && git rev-parse HEAD)
  PERF_START=$(date +%s)
  PERF_OUT2=$(
    cd "$PERF_DIR" || exit 1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$PERF_BASE"
  ) 2>/dev/null
  PERF_ELAPSED=$(( $(date +%s) - PERF_START ))
  if [ "$PERF_ELAPSED" -lt 30 ]; then
    echo -e "  ${GREEN}PASS${RESET}: D279: 400KB single-line diff captured in ${PERF_ELAPSED}s (ceiling 30s)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D279: 400KB single-line diff took ${PERF_ELAPSED}s — the line counter has gone superlinear again"
    FAIL=$((FAIL + 1))
  fi
  # Correctness alongside speed: fast because it is linear, not because it
  # silently dropped the file.
  PERF_LEN=$(echo "$PERF_OUT2" | jq -r '.[] | select(.path == "bundle.min.js") | .diff | length' 2>/dev/null)
  if [ -n "$PERF_LEN" ] && [ "$PERF_LEN" -gt 400000 ]; then
    echo -e "  ${GREEN}PASS${RESET}: D279: the large single-line entry still carries its full diff body ($PERF_LEN bytes)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D279: expected a >400000-byte diff body, got '${PERF_LEN:-<absent>}'"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$PERF_DIR"

  # 7hh (D279): the two remaining shapes the task's testing_strategy names —
  # its integration test ("a repository with two 100KB single-line files
  # produces a snapshot well within the after_doing budget") and its edge case
  # ("a diff that is one line of several hundred KB with NO trailing newline").
  # Two files prove the cost is per-file and accumulates, which is how a repo
  # with several vendored bundles hits the budget without any single file
  # looking extreme.
  #
  # The no-trailing-newline file is a weaker check than it looks, and the limit
  # is worth stating rather than leaving for the next reader to discover. Its
  # body is a handful of lines, nowhere near the 500 trigger, so the assertion
  # below can only show that nothing was truncated — an off-by-one in the count
  # would be invisible to it. It is also not the distinguishing input it
  # appears to be: `$(git diff ...)` strips trailing newlines, so diff_text
  # never ends in LF on a real capture whatever the file on disk looks like.
  # The count arithmetic itself is pinned where it can actually fail, at the
  # 499/500/501 boundary, by 7a-7c through trunc_diff_inline.
  PERF2_DIR=$(mktemp -d)
  (
    cd "$PERF2_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo seed > seed.txt
    git add -A > /dev/null
    git commit -q -m "base"
    head -c 102400 /dev/zero | tr '\0' 'a' > one.min.js
    printf '\n' >> one.min.js
    # Deliberately NO trailing newline on the second file.
    head -c 102400 /dev/zero | tr '\0' 'b' > two.min.js
  )
  PERF2_BASE=$(cd "$PERF2_DIR" && git rev-parse HEAD)
  PERF2_START=$(date +%s)
  PERF2_OUT=$(
    cd "$PERF2_DIR" || exit 1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$PERF2_BASE"
  ) 2>/dev/null
  PERF2_ELAPSED=$(( $(date +%s) - PERF2_START ))
  if [ "$PERF2_ELAPSED" -lt 30 ]; then
    echo -e "  ${GREEN}PASS${RESET}: D279: two 100KB single-line files captured in ${PERF2_ELAPSED}s (ceiling 30s)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D279: two 100KB single-line files took ${PERF2_ELAPSED}s — per-file cost is accumulating superlinearly"
    FAIL=$((FAIL + 1))
  fi
  PERF2_A=$(echo "$PERF2_OUT" | jq -r '.[] | select(.path == "one.min.js") | .diff | length' 2>/dev/null)
  PERF2_B=$(echo "$PERF2_OUT" | jq -r '.[] | select(.path == "two.min.js") | .diff | length' 2>/dev/null)
  if [ -n "$PERF2_A" ] && [ "$PERF2_A" -gt 100000 ] && [ -n "$PERF2_B" ] && [ "$PERF2_B" -gt 100000 ]; then
    echo -e "  ${GREEN}PASS${RESET}: D279: both large single-line entries carry full diff bodies ($PERF2_A, $PERF2_B bytes)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D279: expected two >100000-byte bodies, got '${PERF2_A:-<absent>}' and '${PERF2_B:-<absent>}'"
    FAIL=$((FAIL + 1))
  fi
  # The no-trailing-newline file must not be truncated: its body is one long
  # line, so the count is 2 (git's own header lines plus the content line) and
  # nowhere near the 500 trigger. A count that came out short or long here
  # would be the arithmetic drifting, not a performance problem.
  if echo "$PERF2_OUT" | jq -e --arg m "[diff truncated at 500 lines]" \
       '.[] | select(.path == "two.min.js") | select(.diff | contains($m) | not)' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: D279: a long single-line diff with no trailing newline is not truncated"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D279: the no-trailing-newline single-line diff was truncated"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$PERF2_DIR"

  # 7ii (D281): a bash record write must not destroy an invalid byte in an
  # UNRELATED record. D281 made this matter more rather than less. Its ps1 fix
  # PRESERVES bytes that used to be replaced with U+FFFD, so caches carrying
  # invalid bytes now persist instead of being scrubbed on the next ps1 write —
  # and bash's own record writers are `grep -v "^KEY=" "$ENV_CACHE"` piped into
  # write_env_cache, whose behaviour on invalid multibyte input is an
  # implementation and locale question, not a settled one.
  #
  # Measured on this machine: /usr/bin/grep (BSD grep 2.6.0-FreeBSD) keeps every
  # line and preserves the byte under both LC_ALL=C and LC_ALL=en_US.UTF-8. But
  # ugrep, which some contributors have first on PATH, treats the same file as
  # BINARY and emits nothing at all without -a — which through this pipeline
  # would empty the cache. GNU grep on Linux is a third implementation and was
  # not reachable from here.
  #
  # So this asserts the PROPERTY against whatever grep the runner actually has,
  # rather than encoding one implementation's answer. A host whose grep drops
  # or mangles the line fails here instead of silently losing records.
  # (D288) Extended, not duplicated. Three things changed here and the reason
  # for each is worth stating, because the second one is why D288 exists.
  #
  # 1. The driver now calls the idiom that actually SHIPS - drop_cache_key piped
  #    into write_env_cache --preserve-from-cache. It used to inline `grep -v`,
  #    which stopped being what the record writers do when D288 replaced grep
  #    with awk. A property test that drives a pipeline the product no longer
  #    has is testing nothing.
  # 2. The same five assertions are re-run with a grep on PATH that REFUSES
  #    binary input - in BOTH of the refusal shapes measured for D288: emitting
  #    nothing at exit 1 (ugrep -I), and printing "Binary file <path> matches"
  #    on STDOUT at exit 0 (ugrep's default). The second shape is the one that
  #    matters most: it is not empty, so a sink guard that only tested for an
  #    empty stream would commit that notice AS the cache.
  # 3. The assertions live in a function called once per pass instead of being
  #    written out three times.
  #
  # The shim is put on PATH only around the write itself, not around sourcing
  # the hook, so a failure is attributable to the writer path rather than to
  # having booted the script with a hostile grep.
  d281_hex_of() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

  # A grep that declines to read its input, in the two shapes measured for D288.
  make_refusing_grep_stub() {
    local stub_dir="$1" mode="$2"
    mkdir -p "$stub_dir"
    if [ "$mode" = notice ]; then
      cat > "$stub_dir/grep" << 'GREPSTUB'
#!/usr/bin/env bash
# ugrep's DEFAULT shape: a notice on stdout, exit 0.
for a in "$@"; do last="$a"; done
printf 'Binary file %s matches\n' "$last"
exit 0
GREPSTUB
    else
      cat > "$stub_dir/grep" << 'GREPSTUB'
#!/usr/bin/env bash
# ugrep -I's shape: nothing at all, exit 1.
exit 1
GREPSTUB
    fi
    chmod +x "$stub_dir/grep"
  }

  # One pass: build the fixture, drive the real writer, assert the five
  # properties. $2 is a directory to prepend to PATH for the write, or "".
  d281_pass() {
    local label="$1" stub_dir="$2" dir hex
    dir=$(mktemp -d)
    (
      cd "$dir" || exit 1
      git init -q
      git config user.email "test@test.local"
      git config user.name "Test"
      echo seed > seed.txt
      git add -A > /dev/null
      git commit -q -m base
      # A cache holding an invalid byte in one record and a normal record beside it.
      printf "BOARD_NAME=caf\351\n" > .stride-env-cache
      printf "TASK_OWNED_9='keep'\n" >> .stride-env-cache
      # An EXISTING record for the key about to be written, so the writer's
      # filter actually removes a line. Without it the filter is a pure
      # pass-through and the case pins "this filter reproduces the file" rather
      # than what the record writers do: drop the old line for this key from a
      # file that also holds an invalid byte, then re-add it.
      printf "TASK_NARROWED_9='stale'\n" >> .stride-env-cache
      # shellcheck disable=SC1090
      source "$HOOK_SCRIPT" 2>/dev/null || true
      PROJECT_DIR="$dir"
      ENV_CACHE="$dir/.stride-env-cache"
      [ -n "$stub_dir" ] && PATH="$stub_dir:$PATH"
      {
        drop_cache_key "TASK_NARROWED_9"
        printf "TASK_NARROWED_9='fresh'\n"
      } | write_env_cache --preserve-from-cache || true
    ) > /dev/null 2>&1
    hex=$(od -An -tx1 < "$dir/.stride-env-cache" 2>/dev/null | tr -d ' \n')
    # Non-vacuity: an empty cache trivially contains no bad byte AND no good one.
    if [ -n "$hex" ]; then
      echo -e "  ${GREEN}PASS${RESET}: D281/$label: the bash record write produced a non-empty cache"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: D281/$label: the bash record write emptied the cache"
      FAIL=$((FAIL + 1))
    fi
    case "$hex" in
      *e9*) echo -e "  ${GREEN}PASS${RESET}: D281/$label: an invalid byte in an unrelated record survives a bash record write"
            PASS=$((PASS + 1)) ;;
      *)    echo -e "  ${RED}FAIL${RESET}: D281/$label: the invalid byte was destroyed by a bash record write (grep: $(command -v grep))"
            FAIL=$((FAIL + 1)) ;;
    esac
    # The remaining checks search the HEX, not the file, for the same reason the
    # first two do: this case's subject is a filter's behaviour, so that filter
    # must not be the measuring instrument. A `grep -q` here would return
    # non-zero on a host whose grep refuses binary input whether or not the
    # record is present, and the case would print "an untouched record was lost"
    # when the truthful statement is "this grep will not read the cache" —
    # fail-closed, but misattributed, and the diagnostic is the whole value of a
    # property test someone hits on an unfamiliar host.
    case "$hex" in
      *"$(d281_hex_of "TASK_OWNED_9='keep'")"*)
        echo -e "  ${GREEN}PASS${RESET}: D281/$label: and the untouched record beside it survives too"
        PASS=$((PASS + 1)) ;;
      *)
        echo -e "  ${RED}FAIL${RESET}: D281/$label: an untouched record was lost by a bash record write (grep: $(command -v grep))"
        FAIL=$((FAIL + 1)) ;;
    esac
    case "$hex" in
      *"$(d281_hex_of "TASK_NARROWED_9='fresh'")"*)
        echo -e "  ${GREEN}PASS${RESET}: D281/$label: and the record the write was asked to make landed"
        PASS=$((PASS + 1)) ;;
      *)
        echo -e "  ${RED}FAIL${RESET}: D281/$label: the intended record never landed, so the case above proves nothing"
        FAIL=$((FAIL + 1)) ;;
    esac
    # The stale line for that key must be GONE — this is what makes the case
    # exercise the writer idiom rather than a pass-through.
    case "$hex" in
      *"$(d281_hex_of "TASK_NARROWED_9='stale'")"*)
        echo -e "  ${RED}FAIL${RESET}: D281/$label: the superseded record survived, so the filter did not filter"
        FAIL=$((FAIL + 1)) ;;
      *)
        echo -e "  ${GREEN}PASS${RESET}: D281/$label: and the superseded record for that key was removed"
        PASS=$((PASS + 1)) ;;
    esac
    rm -rf "$dir"
  }

  D281_STUBS=$(mktemp -d)
  make_refusing_grep_stub "$D281_STUBS/silent" silent
  make_refusing_grep_stub "$D281_STUBS/notice" notice
  d281_pass "host-grep" ""
  d281_pass "refusing-grep-silent" "$D281_STUBS/silent"
  d281_pass "refusing-grep-notice" "$D281_STUBS/notice"
  rm -rf "$D281_STUBS"
fi

# ------------------------------------------------------------
# 7ij (D288): direct coverage of the two write_env_cache gates and the two
# family filters. 7ii above drives the writers end to end and proves the
# PROPERTY under three greps; this proves the MECHANISMS 7ii relies on, which
# 7ii cannot distinguish between (it would pass if the guards were absent and
# the filters simply worked). The count gate is what acceptance criterion 3
# rests on, and drop_task_window_records is what carries GOAL_*, BOARD_* and
# TASK_DESCRIPTION across a claim — an equivalence bug there is the exact loss
# D288 exists to prevent.
#
# Each probe runs in a subshell that sources the hook, does one thing, and
# echoes a single token; the parent asserts on the token, so no hook side
# effect reaches the suite's own state.
d288_probe() {
  (
    d288_dir=$(mktemp -d) || exit 1
    PROJECT_DIR="$d288_dir"
    ENV_CACHE="$d288_dir/.stride-env-cache"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    PROJECT_DIR="$d288_dir"
    ENV_CACHE="$d288_dir/.stride-env-cache"
    # Three records, one holding an invalid byte, so every probe runs against
    # the input the whole defect is about.
    d288_seed() {
      {
        printf "AGENT_NAME='a'\n"
        printf "BOARD_NAME=caf\351\n"
        printf "TASK_OWNED_9='keep'\n"
      } > "$ENV_CACHE"
    }
    case "$1" in
      shape-gate-notice)
        # ugrep's default refusal shape: a notice line, then the new record.
        d288_seed
        { printf 'Binary file %s matches\n' "$ENV_CACHE"
          printf "TASK_OWNED_9='fresh'\n"; } | write_env_cache --preserve-from-cache 2>/dev/null
        printf 'rc=%s records=%s' "$?" "$(count_cache_records "$ENV_CACHE")"
        ;;
      shape-gate-unguarded)
        # The same notice with NO --preserve-from-cache: the shape gate is
        # unconditional, so a rebuild-site caller is protected from it too.
        d288_seed
        { printf 'Binary file %s matches\n' "$ENV_CACHE"
          printf "GOAL_ID='7'\n"; } | write_env_cache 2>/dev/null
        printf 'rc=%s records=%s' "$?" "$(count_cache_records "$ENV_CACHE")"
        ;;
      count-gate)
        # ugrep -I's shape: the filter emitted nothing, so only the new record
        # arrives and two unrelated records would be dropped.
        d288_seed
        printf "TASK_OWNED_9='fresh'\n" | write_env_cache --preserve-from-cache 2>/dev/null
        printf 'rc=%s records=%s' "$?" "$(count_cache_records "$ENV_CACHE")"
        ;;
      count-gate-allows-one-drop)
        # A record write legitimately removes exactly one record and adds it
        # back; the floor must not fire on that, nor on a write that GROWS.
        d288_seed
        { drop_cache_key "TASK_OWNED_9"
          printf "TASK_OWNED_9='fresh'\nTASK_NARROWED_9='new'\n"; } \
          | write_env_cache --preserve-from-cache 2>/dev/null
        printf 'rc=%s records=%s' "$?" "$(count_cache_records "$ENV_CACHE")"
        ;;
      legit-empty)
        # Pitfall 3: a cache legitimately becomes empty. No floor requested,
        # nothing malformed — this must SUCCEED, or a stale cache is stranded.
        d288_seed
        : | write_env_cache 2>/dev/null
        printf 'rc=%s bytes=%s' "$?" "$(wc -c < "$ENV_CACHE" | tr -d ' ')"
        ;;
      already-empty)
        # An already-empty cache is the fresh-checkout case: the floor is
        # skipped (`[ -s "$ENV_CACHE" ]`) so the first record write lands.
        : > "$ENV_CACHE"
        printf "TASK_OWNED_9='first'\n" | write_env_cache --preserve-from-cache 2>/dev/null
        printf 'rc=%s records=%s' "$?" "$(count_cache_records "$ENV_CACHE")"
        ;;
      multiline-value)
        # The live cache really does carry these (TASK_DESCRIPTION is a
        # paragraph). The shape gate must not read a continuation line as a
        # top-level non-record, and the count must see one record, not four.
        d288_seed
        { printf "AGENT_NAME='a'\n"
          printf "TASK_DESCRIPTION='one\ntwo\nthree'\n"
          printf "TASK_OWNED_9='keep'\n"; } | write_env_cache --preserve-from-cache 2>/dev/null
        printf 'rc=%s records=%s' "$?" "$(count_cache_records "$ENV_CACHE")"
        ;;
      window-filter)
        # drop_task_window_records must drop all five per-task families and
        # keep everything else — over an invalid byte.
        {
          printf "AGENT_NAME='a'\n"
          printf "BOARD_NAME=caf\351\n"
          printf "TASK_DESCRIPTION='d'\n"
          printf "TASK_BASE_REF='shared'\n"
          printf "TASK_BASE_REF_TRUSTED='1'\n"
          printf "TASK_BASE_REF_OWNER='9'\n"
          printf "TASK_BASE_REF_UNPROVEN='1'\n"
          printf "TASK_BASE_REF_9='b'\n"
          printf "TASK_HEAD_REF_9='h'\n"
          printf "TASK_OWNED_9='o'\n"
          printf "TASK_BASE_AT_9='1'\n"
          printf "TASK_NARROWED_9='yes'\n"
        } > "$ENV_CACHE"
        # Key names only, extracted with awk: the fixture holds an invalid
        # byte on purpose, and `sed` refuses it ("RE error: illegal byte
        # sequence") then truncates its output — the same class of refusal
        # this whole case is about, one tool further out.
        printf 'kept=%s' "$(drop_task_window_records | awk '{ p = index($0, "="); if (p > 1) printf "%s,", substr($0, 1, p - 1) }')"
        ;;
      shared-filter)
        # drop_shared_base_records drops only the four shared records and
        # leaves every per-task window record in place.
        {
          printf "AGENT_NAME='a'\n"
          printf "BOARD_NAME=caf\351\n"
          printf "TASK_BASE_REF='shared'\n"
          printf "TASK_BASE_REF_TRUSTED='1'\n"
          printf "TASK_BASE_REF_OWNER='9'\n"
          printf "TASK_BASE_REF_UNPROVEN='1'\n"
          printf "TASK_BASE_REF_9='b'\n"
          printf "TASK_OWNED_9='o'\n"
        } > "$ENV_CACHE"
        printf 'kept=%s' "$(drop_shared_base_records | awk '{ p = index($0, "="); if (p > 1) printf "%s,", substr($0, 1, p - 1) }')"
        ;;
      crafted-description)
        # (D288 r3) Consideration 2, realised. TASK_DESCRIPTION is
        # attacker-authored free-form text and lands multi-line. Its LAST line
        # here begins with the very key the writer drops, so a line-oriented
        # filter deleted the line carrying the value closing quote, handed the
        # sink a torn stream, and got a LEGITIMATE write refused — content
        # suppressing a write. Quote-aware filters must keep the description
        # whole, drop only the real TASK_OWNED_9 record, and let the write land.
        {
          printf "AGENT_NAME='a'\n"
          printf "TASK_DESCRIPTION='harmless first line\n"
          printf "TASK_OWNED_9=x'\n"
          printf "TASK_OWNED_9='stale'\n"
        } > "$ENV_CACHE"
        { drop_cache_key "TASK_OWNED_9"
          printf "TASK_OWNED_9='fresh'\n"; } | write_env_cache --preserve-from-cache 2>/dev/null
        d288_rc=$?
        # The description must survive whole, the stale record must be gone,
        # and the fresh one must have landed.
        d288_desc=no; d288_stale=yes; d288_fresh=no
        awk '/^TASK_DESCRIPTION=/{d=1} END{exit !d}' "$ENV_CACHE" 2>/dev/null && d288_desc=yes
        awk "/^TASK_OWNED_9='stale'/{f=1} END{exit !f}" "$ENV_CACHE" 2>/dev/null || d288_stale=no
        awk "/^TASK_OWNED_9='fresh'/{f=1} END{exit !f}" "$ENV_CACHE" 2>/dev/null && d288_fresh=yes
        printf 'rc=%s desc=%s stale=%s fresh=%s' "$d288_rc" "$d288_desc" "$d288_stale" "$d288_fresh"
        ;;
      writer-source-bail)
        # (D288 r4) Pins the SOURCE-side status check in the record writers,
        # which nothing else covers: unreadable-cache below drives the pipeline
        # by hand and so exercises the sink gates instead. Reverting
        # `_body=$(drop_cache_key ...) || return 0` to a bare call would leave
        # that probe green. record_task_narrowed is used because it has no
        # base-ref precondition to satisfy first.
        d288_seed
        d288_before=$(od -An -tx1 < "$ENV_CACHE" | tr -d ' \n')
        chmod 000 "$ENV_CACHE" 2>/dev/null
        record_task_narrowed 9 yes > /dev/null 2>"$d288_dir/err"
        d288_rc=$?
        chmod 644 "$ENV_CACHE" 2>/dev/null
        d288_after=$(od -An -tx1 < "$ENV_CACHE" | tr -d ' \n')
        if [ "$d288_before" = "$d288_after" ]; then d288_same=same; else d288_same=CHANGED; fi
        d288_warned=no
        [ -s "$d288_dir/err" ] && d288_warned=yes
        printf 'rc=%s cache=%s warned=%s' "$d288_rc" "$d288_same" "$d288_warned"
        ;;
      unreadable-cache)
        # (D288 r2) The cache EXISTS but cannot be read. Both the filter and
        # the count come back empty, `[ -s ]` is satisfied by stat alone, and
        # `mv` would succeed into a writable directory — so an abstaining count
        # gate committed a one-record cache over a populated one, silently, at
        # exit 0. The previous cache must survive byte-for-byte.
        d288_seed
        d288_before=$(od -An -tx1 < "$ENV_CACHE" | tr -d ' \n')
        chmod 000 "$ENV_CACHE" 2>/dev/null
        { drop_cache_key "TASK_OWNED_9"
          printf "TASK_OWNED_9='fresh'\n"; } | write_env_cache --preserve-from-cache 2>/dev/null
        d288_rc=$?
        chmod 644 "$ENV_CACHE" 2>/dev/null
        d288_after=$(od -An -tx1 < "$ENV_CACHE" | tr -d ' \n')
        if [ "$d288_before" = "$d288_after" ]; then d288_same=same; else d288_same=CHANGED; fi
        printf 'rc=%s cache=%s' "$d288_rc" "$d288_same"
        ;;
      filter-status)
        # The filters must PROPAGATE failure rather than returning empty at
        # exit 0 — the distinction the rebuild sites depend on to tell "this
        # cache holds nothing else" from "the filter could not read it". But an
        # ABSENT cache is the fresh-checkout case and must stay a clean empty
        # result, or a claim skips the rebuild it exists to perform.
        rm -f "$ENV_CACHE"
        drop_task_window_records > /dev/null 2>&1
        d288_missing=$?
        d288_seed
        chmod 000 "$ENV_CACHE" 2>/dev/null
        drop_task_window_records > /dev/null 2>&1
        d288_unreadable=$?
        chmod 644 "$ENV_CACHE" 2>/dev/null
        if [ "$d288_unreadable" -ne 0 ]; then d288_unreadable=nonzero; fi
        printf 'missing_rc=%s unreadable_rc=%s' "$d288_missing" "$d288_unreadable"
        ;;
    esac
    rm -rf "$d288_dir"
  )
}

D288_R=$(d288_probe shape-gate-notice)
assert_eq "7ij (D288): the shape gate refuses a Binary-file notice and keeps all 3 records" \
  "rc=1 records=3" "$D288_R"
D288_R=$(d288_probe shape-gate-unguarded)
assert_eq "7ij (D288): the shape gate is unconditional, protecting rebuild callers too" \
  "rc=1 records=3" "$D288_R"
D288_R=$(d288_probe count-gate)
assert_eq "7ij (D288): the count gate refuses a write that would drop 2 of 3 records" \
  "rc=1 records=3" "$D288_R"
D288_R=$(d288_probe count-gate-allows-one-drop)
assert_eq "7ij (D288): the count gate allows a legitimate replace-and-add" \
  "rc=0 records=4" "$D288_R"
D288_R=$(d288_probe legit-empty)
assert_eq "7ij (D288): a cache that legitimately becomes empty still commits (pitfall 3)" \
  "rc=0 bytes=0" "$D288_R"
D288_R=$(d288_probe already-empty)
assert_eq "7ij (D288): the first record write over an already-empty cache lands" \
  "rc=0 records=1" "$D288_R"
D288_R=$(d288_probe multiline-value)
assert_eq "7ij (D288): a multi-line value passes the shape gate and counts once" \
  "rc=0 records=3" "$D288_R"
D288_R=$(d288_probe window-filter)
assert_eq "7ij (D288): drop_task_window_records drops all five per-task families" \
  "kept=AGENT_NAME,BOARD_NAME,TASK_DESCRIPTION," "$D288_R"
D288_R=$(d288_probe shared-filter)
assert_eq "7ij (D288): drop_shared_base_records keeps every per-task window record" \
  "kept=AGENT_NAME,BOARD_NAME,TASK_BASE_REF_9,TASK_OWNED_9," "$D288_R"
D288_R=$(d288_probe writer-source-bail)
assert_eq "7ij (D288): a record writer skips the write and warns when its filter cannot read the cache" \
  "rc=0 cache=same warned=yes" "$D288_R"
D288_R=$(d288_probe crafted-description)
assert_eq "7ij (D288): a crafted description cannot suppress a legitimate record write" \
  "rc=0 desc=yes stale=no fresh=yes" "$D288_R"
D288_R=$(d288_probe unreadable-cache)
assert_eq "7ij (D288): an unreadable cache refuses the write and survives byte-for-byte" \
  "rc=1 cache=same" "$D288_R"
D288_R=$(d288_probe filter-status)
assert_eq "7ij (D288): absent cache is a clean empty result; an unreadable one reports failure" \
  "missing_rc=0 unreadable_rc=nonzero" "$D288_R"


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

  # 8c (D127): No TASK_ID in the env cache, but the /complete URL carries id 42 →
  # the upload targets 42 (env-cache-independent, the D127 fix).
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
    # No TASK_ID line — only TASK_BASE_REF. The /complete URL still carries id 42.
    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer test_token\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  # (D127) With no env-cache TASK_ID but a /complete URL carrying id 42, the
  # upload now targets 42 (env-cache-independent). Before D127 this skipped the
  # PUT; making the upload depend on the env TASK_ID is the empty-changed_files
  # bug this fix removes.
  if grep -qF '/api/tasks/42/changed_files' "$NOID_FIXTURE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${RESET}: 8c (D127): missing env TASK_ID → PUT still made, targeting the URL id (42)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8c (D127): expected PUT to /api/tasks/42/changed_files, fixture: $(cat "$NOID_FIXTURE" 2>/dev/null || echo NONE)"
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

  # 8j (D127): task_id_from_command extracts the id from a /complete or
  # /mark_reviewed URL and returns empty for the claim/next paths (no id) and for
  # a non-numeric segment. This is what lets the after_doing upload target the
  # correct task even when a hidden claim left a stale TASK_ID in the env cache
  # (the G321/D126 empty-changed_files root cause).
  TIDCMD_OUT=$(
    source "$HOOK_SCRIPT" 2>/dev/null || true
    printf '%s|%s|%s|%s|%s' \
      "$(task_id_from_command 'curl -X PATCH https://x/api/tasks/7777/complete -H h')" \
      "$(task_id_from_command 'curl -X PATCH https://x/api/tasks/42/mark_reviewed')" \
      "$(task_id_from_command 'curl -X POST https://x/api/tasks/claim')" \
      "$(task_id_from_command 'curl -s https://x/api/tasks/next')" \
      "$(task_id_from_command 'curl https://x/api/tasks/abc/complete')"
  )
  assert_eq "8j (D127): task_id_from_command reads /complete + /mark_reviewed ids, empty for claim/next/non-numeric" \
    "7777|42|||" "$TIDCMD_OUT"

  # 8k (D127): finalize_after_doing PUTs to the task id in the /complete URL, NOT
  # a stale env-cache TASK_ID. With TASK_ID=111111 (stale, prior task) and the
  # command completing /api/tasks/7777/complete, the changed_files PUT must target
  # 7777 — the fix for the empty-changed_files root cause.
  TGT_DIR=$(mktemp -d); TGT_STUB=$(mktemp -d)
  TGT_FIXTURE="$TGT_DIR/curl-call.txt"
  make_curl_stub "$TGT_STUB" "$TGT_FIXTURE" 0 200
  (
    setup_put_repo "$TGT_DIR" || exit 1
    cat > .stride_auth.md << 'AUTH'
- **API URL:** `https://tgt.example.com`
- **API Token:** `tok`
AUTH
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    HAS_JQ=true
    HOOK_NAME=after_doing
    TASK_ID=111111
    COMMAND='curl -X PATCH https://tgt.example.com/api/tasks/7777/complete -H "Authorization: Bearer tok"'
    PROJECT_DIR="$TGT_DIR"
    PATH="$TGT_STUB:$PATH"
    finalize_after_doing
  ) > /dev/null 2>&1
  if grep -qF '/api/tasks/7777/changed_files' "$TGT_FIXTURE" 2>/dev/null \
     && ! grep -qF '/api/tasks/111111/changed_files' "$TGT_FIXTURE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${RESET}: 8k (D127): finalize PUTs to the /complete URL task id (7777), not the stale env TASK_ID (111111)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8k (D127): PUT did not target 7777. Fixture: $(cat "$TGT_FIXTURE" 2>/dev/null)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$TGT_DIR" "$TGT_STUB"
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

  # 9i (W1453): extract_hook_env prints only the matching hook entry's env as
  # escaped assignment lines, drops non-identifier keys, and honors the
  # singular `.hook` claim-response shape.
  EHE_PAYLOAD='{"data":{"id":99},"hooks":[{"name":"before_review","env":{"NOPE":"x"}},{"name":"after_goal","env":{"GOAL_ID":"7","BAD;KEY":"evil","HOOK_NAME":"after_goal"}}]}'
  EHE_OUT=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    extract_hook_env "$EHE_PAYLOAD" "after_goal"
  )
  assert_contains "9i: extract_hook_env emits the matching entry's env" "GOAL_ID='7'" "$EHE_OUT"
  if printf '%s\n' "$EHE_OUT" | grep -qE "NOPE|BAD|HOOK_NAME"; then
    echo -e "  ${RED}FAIL${RESET}: 9i: extract_hook_env leaked another entry's env or a denied key"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 9i: other entries' env, invalid keys, and HOOK_NAME are dropped"
    PASS=$((PASS + 1))
  fi

  EHE_SINGULAR='{"data":{"id":99},"hook":{"name":"before_doing","env":{"BOARD_NAME":"Stride Development"}}}'
  EHE_OUT_S=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    extract_hook_env "$EHE_SINGULAR" "before_doing"
  )
  assert_contains "9i: singular .hook claim shape is honored" \
    "BOARD_NAME='Stride Development'" "$EHE_OUT_S"

  # ----------------------------------------------------------
  # (D275) The hook-env key filter is an ALLOW-list. What gets past it is
  # eval'd under `set -a` AND written to .stride-env-cache, which is sourced
  # under `set -a` on every later invocation — so a key that slips through is
  # durable, and it arrived in an API response body. The filter used to be a
  # deny-list naming HOOK_NAME and five client-owned families, which let every
  # process-critical name through.
  # ----------------------------------------------------------

  # 9j: the process-critical names never reach the assignment lines. These are
  # the ones that turn a response body into code execution: PATH re-points
  # every later git/curl/jq the hook runs, BASH_ENV and ENV are sourced by the
  # next shell, LD_PRELOAD and DYLD_* inject into it, GIT_SSH_COMMAND and
  # GIT_EXTERNAL_DIFF are run by git itself, IFS and SHELLOPTS and PS4 steer
  # the interpreter.
  D275_HOSTILE='{"hook":{"name":"before_doing","env":{"TASK_ID":"42","PATH":"/evil/bin","BASH_ENV":"/tmp/pwn.sh","ENV":"/tmp/pwn.sh","IFS":"x","SHELLOPTS":"xtrace","LD_PRELOAD":"/tmp/x.so","DYLD_INSERT_LIBRARIES":"/tmp/y.dylib","GIT_SSH_COMMAND":"sh -c id","GIT_EXTERNAL_DIFF":"id","GIT_CONFIG_GLOBAL":"/tmp/g","PS4":"evil","LD_LIBRARY_PATH":"/tmp/l"}}}'
  D275_OUT=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    extract_hook_env "$D275_HOSTILE" "before_doing"
  )
  assert_contains "D275: a documented key alongside the hostile ones still passes" \
    "TASK_ID='42'" "$D275_OUT"
  D275_LEAK=$(printf '%s\n' "$D275_OUT" | grep -cE '^(PATH|BASH_ENV|ENV|IFS|SHELLOPTS|LD_PRELOAD|LD_LIBRARY_PATH|DYLD_INSERT_LIBRARIES|GIT_SSH_COMMAND|GIT_EXTERNAL_DIFF|GIT_CONFIG_GLOBAL|PS4)=' || true)
  assert_eq "D275: no process-critical key reaches the assignment lines" "0" "$D275_LEAK"

  # 9k: and none of them reaches the env cache either — the second sink, and
  # the durable one. apply_env_lines is what writes it, so this drives the real
  # sink rather than re-checking the filter.
  D275_CACHE_DIR=$(mktemp -d)
  (
    cd "$D275_CACHE_DIR" || exit 1
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    PROJECT_DIR="$D275_CACHE_DIR"
    ENV_CACHE="$D275_CACHE_DIR/.stride-env-cache"
    apply_env_lines "$(extract_hook_env "$D275_HOSTILE" "before_doing")"
  ) > /dev/null 2>&1
  D275_CACHE_BODY=$(cat "$D275_CACHE_DIR/.stride-env-cache" 2>/dev/null || printf '')
  # NON-VACUITY GUARD FIRST. Without it this case passes for the wrong reason:
  # an absent or unwritten cache trivially contains no dangerous key, so the
  # assertion below would go green while proving nothing. Verified against the
  # pre-fix deny-list, where this case DID pass vacuously before the guard was
  # added — the allowed key is what shows the write actually happened.
  if printf '%s\n' "$D275_CACHE_BODY" | grep -q "^TASK_ID="; then
    echo -e "  ${GREEN}PASS${RESET}: D275: the env-cache write happened, so the next assertion is not vacuous"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D275: no env cache was written — the leak check below would prove nothing"
    FAIL=$((FAIL + 1))
  fi
  D275_CACHE_LEAK=$(printf '%s\n' "$D275_CACHE_BODY" | grep -cE '^(PATH|BASH_ENV|ENV|IFS|SHELLOPTS|LD_PRELOAD|LD_LIBRARY_PATH|DYLD_INSERT_LIBRARIES|GIT_SSH_COMMAND|GIT_EXTERNAL_DIFF|GIT_CONFIG_GLOBAL|PS4)=' || true)
  assert_eq "D275: no process-critical key reaches the env cache" "0" "$D275_CACHE_LEAK"
  rm -rf "$D275_CACHE_DIR"

  # 9l: every documented key still passes. This is the direction an allow-list
  # gets wrong — omit one and a shipped hook silently loses a variable — so it
  # is asserted per key rather than in aggregate.
  D275_ALL='{"hook":{"name":"before_doing","env":{"TASK_ID":"1","TASK_IDENTIFIER":"D275","TASK_TITLE":"t","TASK_DESCRIPTION":"d","TASK_STATUS":"in_progress","TASK_COMPLEXITY":"medium","TASK_PRIORITY":"high","TASK_NEEDS_REVIEW":"false","BOARD_ID":"55","BOARD_NAME":"b","COLUMN_ID":"128","COLUMN_NAME":"Doing","AGENT_NAME":"a","GOAL_ID":"9","GOAL_IDENTIFIER":"G1","GOAL_TITLE":"g","GOAL_DESCRIPTION":"gd"}}}'
  D275_ALL_OUT=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    extract_hook_env "$D275_ALL" "before_doing"
  )
  D275_MISSING=""
  for _k in TASK_ID TASK_IDENTIFIER TASK_TITLE TASK_DESCRIPTION TASK_STATUS \
            TASK_COMPLEXITY TASK_PRIORITY TASK_NEEDS_REVIEW BOARD_ID BOARD_NAME \
            COLUMN_ID COLUMN_NAME AGENT_NAME GOAL_ID GOAL_IDENTIFIER GOAL_TITLE \
            GOAL_DESCRIPTION; do
    printf '%s\n' "$D275_ALL_OUT" | grep -q "^${_k}=" || D275_MISSING="$D275_MISSING $_k"
  done
  assert_eq "D275: all 17 documented hook-env keys still pass the filter" "" "$D275_MISSING"

  # 9m: the client-owned families stay fenced. They were named one by one in
  # the old deny-list; under the allow-list they are excluded by absence, and
  # that has to keep holding — a forged TASK_BASE_REF steers commit
  # attribution, which is why they were fenced in the first place.
  D275_OWNED='{"hook":{"name":"before_doing","env":{"TASK_BASE_REF":"dead","TASK_BASE_REF_9":"dead","TASK_HEAD_REF":"beef","TASK_OWNED_9":"x","TASK_NARROWED_9":"y","TASK_BASE_AT_9":"z","STRIDE_FOO":"1","HOOK_NAME":"evil"}}}'
  D275_OWNED_OUT=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    extract_hook_env "$D275_OWNED" "before_doing"
  )
  assert_eq "D275: client-owned record families and HOOK_NAME emit nothing at all" "" "$D275_OWNED_OUT"

  # 9n: DRIFT GUARD. The allow-list is a copy of the Variable Inventory in
  # skills/stride-workflow/hook-execution.md, and a copy rots. Adding a
  # variable to the docs without adding it here would silently drop it from
  # every hook; removing one here without the docs would be an undocumented
  # narrowing. HOOK_NAME is the one documented name deliberately absent — the
  # executor owns it and the doc says so — so it is subtracted before compare.
  D275_DOC_KEYS=$(grep -oE '^\| `[A-Z_]+` \|' "$SCRIPT_DIR/../skills/stride-workflow/hook-execution.md" 2>/dev/null \
    | tr -d '|` ' | grep -v '^HOOK_NAME$' | sort -u | tr '\n' ' ' | sed 's/ $//')
  D275_CODE_KEYS=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    printf '%s' "$STRIDE_HOOK_ENV_ALLOW" | tr -d '[]"' | tr ',' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'
  )
  if [ -z "$D275_DOC_KEYS" ]; then
    echo -e "  ${RED}FAIL${RESET}: D275: could not read the documented Variable Inventory — the drift guard proved nothing"
    FAIL=$((FAIL + 1))
  else
    assert_eq "D275: the allow-list matches the documented Variable Inventory" \
      "$D275_DOC_KEYS" "$D275_CODE_KEYS"
  fi

  # ----------------------------------------------------------
  # D118: canonical response-file fast path for after_goal detection
  # ----------------------------------------------------------
  # The harness truncates large /complete tool_response.stdout mid-JSON, so
  # response_has_after_goal / extract_response_payload must prefer a canonical
  # response file ($PROJECT_DIR/.stride/.last-api-response.json) when present
  # and fall back to tool_response.stdout otherwise. Tests override
  # $RESPONSE_FILE in the subshell (the script computes it from $PROJECT_DIR at
  # source time; overriding it post-source is the function-level seam).
  RF_DIR="$TMPDIR_TEST/d118-respfile"
  RF_FILE="$RF_DIR/.stride/.last-api-response.json"
  mkdir -p "$RF_DIR/.stride"

  # Full, valid API response carrying an after_goal entry (what a non-truncated
  # response file holds).
  RF_FULL='{"data":{"id":99},"hooks":[{"name":"after_review"},{"name":"after_goal"}]}'
  # A tool_response.stdout truncated mid-JSON by the harness — invalid JSON.
  RF_TRUNC_STDOUT='{"data":{},"hooks":[{"name":"after_go'
  RF_INPUT_TRUNC=$(jq -nc --arg s "$RF_TRUNC_STDOUT" \
    '{tool_input:{command:"curl"},tool_response:{stdout:$s}}')

  # 9j (D118, regression): truncated tool_response.stdout + present response
  # file with after_goal → detection succeeds via the file fast path.
  printf '%s' "$RF_FULL" > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_TRUNC"
  )
  assert_eq "9j: after_goal detected from response file despite truncated stdout" "0" "$?"

  # 9k (D118): no response file + truncated stdout → detection fails (documents
  # the bug and the fallback; D119's fresh call is the reliability guarantee).
  rm -f "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_TRUNC"
  )
  RF_RC_NOFILE=$?
  if [ "$RF_RC_NOFILE" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9k: no response file + truncated stdout returns non-zero (fallback)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9k: expected non-zero with no file and truncated stdout"
    FAIL=$((FAIL + 1))
  fi

  # 9l (D118, back-compat): no response file + small valid stdout with
  # after_goal → detection still succeeds from tool_response.stdout.
  rm -f "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$AG_INPUT_CC"
  )
  assert_eq "9l: after_goal still detected from stdout when no response file (back-compat)" "0" "$?"

  # 9m (D118, edge): empty response file → ignored, falls through to stdout.
  : > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$AG_INPUT_CC"
  )
  assert_eq "9m: empty response file falls through to stdout parse" "0" "$?"

  # 9n (D118, edge): response file present but not valid JSON → ignored, falls
  # through to stdout (a truncated/garbage file must not shadow the fallback).
  printf '%s' "$RF_TRUNC_STDOUT" > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$AG_INPUT_CC"
  )
  assert_eq "9n: invalid-JSON response file falls through to stdout parse" "0" "$?"

  # 9o (D118, pitfall): HAS_JQ=false degrades cleanly even with a present file.
  printf '%s' "$RF_FULL" > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=false
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_TRUNC"
  )
  RF_RC_NOJQ=$?
  if [ "$RF_RC_NOJQ" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9o: HAS_JQ=false returns non-zero even with present response file"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9o: expected non-zero with HAS_JQ=false"
    FAIL=$((FAIL + 1))
  fi

  # 9p (D118): extract_response_payload prefers the response file over stdout.
  printf '%s' "$RF_FULL" > "$RF_FILE"
  RF_PAYLOAD_FILE=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    extract_response_payload "$RF_INPUT_TRUNC"
  )
  assert_contains "9p: extract_response_payload reads the response file" '"after_goal"' "$RF_PAYLOAD_FILE"

  # 9q (D118, back-compat): extract_response_payload falls back to stdout when
  # no response file is present.
  rm -f "$RF_FILE"
  RF_PAYLOAD_STDOUT=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    extract_response_payload "$AG_INPUT_CC"
  )
  assert_contains "9q: extract_response_payload falls back to stdout payload" '"after_goal"' "$RF_PAYLOAD_STDOUT"

  # 9r (W1609): the shared resolver recovers the W1086 persisted-output file when
  # stdout carries only a "Full output saved to: <path>" notice (no canonical file).
  rm -f "$RF_FILE"
  RF_PERSIST_DIR=$(mktemp -d)
  RF_PERSIST_FILE="$RF_PERSIST_DIR/persisted.json"
  printf '{"data":{"id":88},"hooks":[{"name":"after_goal"}]}' > "$RF_PERSIST_FILE"
  RF_NOTICE_INPUT=$(jq -nc --arg s "Full output saved to: $RF_PERSIST_FILE" \
    '{tool_input:{command:"curl"},tool_response:{stdout:$s}}')
  RF_PAYLOAD_PERSIST=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    extract_response_payload "$RF_NOTICE_INPUT"
  )
  assert_contains "9r: resolver recovers the W1086 persisted-output file via notice" '"after_goal"' "$RF_PAYLOAD_PERSIST"
  rm -rf "$RF_PERSIST_DIR"

  rm -f "$RF_FILE"
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

  # --- W1453: server-supplied hook env forwarding ---

  # Helper: like ag_e2e_input but takes the FULL inner API JSON so fixtures
  # can carry `env` objects on hook entries and `parent_id` in data.
  ag_e2e_input_full() {
    local primary_command="$1"
    local inner_json="$2"
    jq -nc \
      --arg cmd "$primary_command" \
      --arg inner "$inner_json" \
      '{tool_input: {command: $cmd}, tool_response: {stdout: $inner}}'
  }

  # Helper: a fresh project whose ## after_goal section echoes the env vars
  # under test. $1 = directory name suffix.
  ag_env_project() {
    local _dir="$TMPDIR_TEST/after-goal-env-$1"
    mkdir -p "$_dir"
    cat > "$_dir/.stride.md" << 'STRIDE'
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
echo "gid=[$GOAL_ID] gident=[$GOAL_IDENTIFIER] gtitle=[$GOAL_TITLE] tid=[$TASK_ID] hn=[$HOOK_NAME]"
```
STRIDE
    printf '%s' "$_dir"
  }

  # 10f: server-supplied GOAL_* env on the after_goal entry is exported to
  # the section and written to the env cache for the follow-up PATCH (D260:
  # via apply_env_lines' replace-in-place, one record per key).
  AG_ENV_PROJ_F=$(ag_env_project "supplied")
  AG_ENV_INNER_F=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven"}}
  ]}')
  AG_ENV_INPUT_F=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_F")
  AG_ENV_OUT_F=$(echo "$AG_ENV_INPUT_F" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_F" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_ENV_RC_F=$?
  assert_exit "10f: server-supplied GOAL_* env exits 0" 0 "$AG_ENV_RC_F"
  assert_contains "10f: section sees server-supplied GOAL_ID" "gid=[7]" "$AG_ENV_OUT_F"
  assert_contains "10f: section sees server-supplied GOAL_IDENTIFIER" "gident=[G7]" "$AG_ENV_OUT_F"
  AG_ENV_CACHE_F=$(cat "$AG_ENV_PROJ_F/.stride-env-cache" 2>/dev/null || echo "")
  assert_contains "10f: env cache carries GOAL_ID for the follow-up PATCH" \
    "GOAL_ID='7'" "$AG_ENV_CACHE_F"
  assert_contains "10f: env cache carries GOAL_IDENTIFIER" \
    "GOAL_IDENTIFIER='G7'" "$AG_ENV_CACHE_F"

  # 10g: after_goal entry with NO env object — omitted GOAL_* keys export as
  # empty strings (never an error) and GOAL_ID falls back to data.parent_id.
  AG_ENV_PROJ_G=$(ag_env_project "fallback")
  AG_ENV_INNER_G=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal"}
  ]}')
  AG_ENV_INPUT_G=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_G")
  AG_ENV_OUT_G=$(echo "$AG_ENV_INPUT_G" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_G" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_ENV_RC_G=$?
  assert_exit "10g: no-env after_goal entry exits 0" 0 "$AG_ENV_RC_G"
  assert_contains "10g: GOAL_ID falls back to data.parent_id" "gid=[55]" "$AG_ENV_OUT_G"
  assert_contains "10g: omitted GOAL_IDENTIFIER exports as empty string" \
    "gident=[]" "$AG_ENV_OUT_G"
  assert_contains "10g: omitted GOAL_TITLE exports as empty string" \
    "gtitle=[]" "$AG_ENV_OUT_G"

  # 10g-2: env present but GOAL_ID empty — the fallback also fires.
  AG_ENV_PROJ_G2=$(ag_env_project "fallback-empty")
  AG_ENV_INNER_G2=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"","GOAL_IDENTIFIER":"G55"}}
  ]}')
  AG_ENV_INPUT_G2=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_G2")
  AG_ENV_OUT_G2=$(echo "$AG_ENV_INPUT_G2" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_G2" \
    bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "10g-2: empty server GOAL_ID falls back to parent_id" \
    "gid=[55]" "$AG_ENV_OUT_G2"
  assert_contains "10g-2: supplied GOAL_IDENTIFIER survives the fallback" \
    "gident=[G55]" "$AG_ENV_OUT_G2"

  # 10h: precedence — server-supplied keys override stale cached values;
  # keys the server does not supply keep their cached values.
  AG_ENV_PROJ_H=$(ag_env_project "precedence")
  printf "TASK_ID='42'\n" > "$AG_ENV_PROJ_H/.stride-env-cache"
  AG_ENV_INNER_H=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7","TASK_ID":"99"}}
  ]}')
  AG_ENV_INPUT_H=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_H")
  AG_ENV_OUT_H=$(echo "$AG_ENV_INPUT_H" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_H" \
    bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "10h: server-supplied TASK_ID overrides the stale cached value" \
    "tid=[99]" "$AG_ENV_OUT_H"
  assert_contains "10h: GOAL_ID exported alongside" "gid=[7]" "$AG_ENV_OUT_H"

  AG_ENV_PROJ_H2=$(ag_env_project "precedence-keep")
  printf "TASK_ID='42'\n" > "$AG_ENV_PROJ_H2/.stride-env-cache"
  AG_ENV_INNER_H2=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7"}}
  ]}')
  AG_ENV_INPUT_H2=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_H2")
  AG_ENV_OUT_H2=$(echo "$AG_ENV_INPUT_H2" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_H2" \
    bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "10h: unsupplied keys keep their cached values" \
    "tid=[42]" "$AG_ENV_OUT_H2"

  # 10i: injection safety — a crafted value cannot escape the single-quoting
  # and a non-identifier key is dropped, never executed.
  AG_ENV_PROJ_I=$(ag_env_project "injection")
  AG_PWNED="$TMPDIR_TEST/after-goal-env-pwned"
  rm -f "$AG_PWNED"
  AG_ENV_INNER_I=$(jq -nc --arg evil "x'; touch $AG_PWNED; echo 'y" --arg pwned "touch $AG_PWNED" \
    '{data: {id: 99, parent_id: 55}, hooks: [
      {"name":"before_review"},
      {"name":"after_goal","env":{"GOAL_ID":"7","GOAL_TITLE":$evil,"BAD;KEY":$pwned}}
    ]}')
  AG_ENV_INPUT_I=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_I")
  AG_ENV_OUT_I=$(echo "$AG_ENV_INPUT_I" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_I" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_ENV_RC_I=$?
  assert_exit "10i: crafted env values exit 0" 0 "$AG_ENV_RC_I"
  if [ -e "$AG_PWNED" ]; then
    echo -e "  ${RED}FAIL${RESET}: 10i: crafted env value executed a command (pwned file exists)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10i: crafted env value never executes (no pwned file)"
    PASS=$((PASS + 1))
  fi
  assert_contains "10i: crafted value arrives literally in the section" \
    "gtitle=[x'; touch" "$AG_ENV_OUT_I"

  # 10j: cleanup deferral — when after_goal rides the mark_reviewed response,
  # the env cache survives (the agent still needs GOAL_ID for the follow-up
  # PATCH); the diff snapshot artifacts are still removed.
  AG_ENV_PROJ_J=$(ag_env_project "cleanup-defer")
  printf "TASK_ID='42'\n" > "$AG_ENV_PROJ_J/.stride-env-cache"
  echo '[]' > "$AG_ENV_PROJ_J/.stride-changed-files.json"
  AG_ENV_INNER_J=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"after_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7"}}
  ]}')
  AG_ENV_INPUT_J=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed" "$AG_ENV_INNER_J")
  AG_ENV_OUT_J=$(echo "$AG_ENV_INPUT_J" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_J" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_ENV_RC_J=$?
  assert_exit "10j: mark_reviewed with after_goal exits 0" 0 "$AG_ENV_RC_J"
  if [ -f "$AG_ENV_PROJ_J/.stride-env-cache" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 10j: env cache survives mark_reviewed when after_goal rode it"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 10j: env cache should survive for the follow-up after_goal PATCH"
    FAIL=$((FAIL + 1))
  fi
  AG_ENV_CACHE_J=$(cat "$AG_ENV_PROJ_J/.stride-env-cache" 2>/dev/null || echo "")
  assert_contains "10j: surviving cache carries GOAL_ID" "GOAL_ID='7'" "$AG_ENV_CACHE_J"
  if [ -f "$AG_ENV_PROJ_J/.stride-changed-files.json" ]; then
    echo -e "  ${RED}FAIL${RESET}: 10j: diff snapshot should still be removed on mark_reviewed"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10j: diff snapshot still removed on mark_reviewed"
    PASS=$((PASS + 1))
  fi

  # 10j-2: mark_reviewed WITHOUT after_goal keeps the existing cleanup.
  AG_ENV_PROJ_J2=$(ag_env_project "cleanup-normal")
  printf "TASK_ID='42'\n" > "$AG_ENV_PROJ_J2/.stride-env-cache"
  AG_ENV_INNER_J2=$(jq -nc '{data: {id: 99}, hooks: [{"name":"after_review"}]}')
  AG_ENV_INPUT_J2=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed" "$AG_ENV_INNER_J2")
  echo "$AG_ENV_INPUT_J2" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_J2" \
    bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$AG_ENV_PROJ_J2/.stride-env-cache" ]; then
    echo -e "  ${RED}FAIL${RESET}: 10j-2: mark_reviewed without after_goal should still delete the cache"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10j-2: mark_reviewed without after_goal still deletes the cache"
    PASS=$((PASS + 1))
  fi

  # 10k: HOOK_NAME containment — a server-sent HOOK_NAME is never cached (a
  # cached line would misroute later invocations), yet the section observes
  # HOOK_NAME=after_goal from the executor's explicit set/restore.
  AG_ENV_PROJ_K=$(ag_env_project "hookname")
  AG_ENV_INNER_K=$(jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7","HOOK_NAME":"after_goal"}}
  ]}')
  AG_ENV_INPUT_K=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_K")
  AG_ENV_OUT_K=$(echo "$AG_ENV_INPUT_K" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_K" \
    bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "10k: section observes HOOK_NAME=after_goal" "hn=[after_goal]" "$AG_ENV_OUT_K"
  AG_ENV_CACHE_K=$(cat "$AG_ENV_PROJ_K/.stride-env-cache" 2>/dev/null || echo "")
  if printf '%s\n' "$AG_ENV_CACHE_K" | grep -q '^HOOK_NAME='; then
    echo -e "  ${RED}FAIL${RESET}: 10k: HOOK_NAME must never be written to the env cache"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10k: HOOK_NAME never written to the env cache"
    PASS=$((PASS + 1))
  fi

  # 10l: env value with an embedded newline survives quoting end-to-end, the
  # cache still sources cleanly, and omitted-key defaults still apply even
  # when the multi-line value's continuation could look like a KEY= line.
  # ${GOAL_IDENTIFIER?unset} hard-fails the section if the key were deleted
  # instead of defined-but-empty.
  AG_ENV_PROJ_L="$TMPDIR_TEST/after-goal-env-newline"
  mkdir -p "$AG_ENV_PROJ_L"
  cat > "$AG_ENV_PROJ_L/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```

## after_goal
```bash
echo "gtitle=[$GOAL_TITLE] gident=[${GOAL_IDENTIFIER?unset}]"
```
STRIDE
  AG_NL_VALUE="line1
GOAL_IDENTIFIER=sneaky
line3"
  AG_ENV_INNER_L=$(jq -nc --arg title "$AG_NL_VALUE" '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7","GOAL_TITLE":$title}}
  ]}')
  AG_ENV_INPUT_L=$(ag_e2e_input_full \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" "$AG_ENV_INNER_L")
  AG_ENV_OUT_L=$(echo "$AG_ENV_INPUT_L" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_L" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_ENV_RC_L=$?
  assert_exit "10l: embedded-newline env value exits 0" 0 "$AG_ENV_RC_L"
  assert_contains "10l: newline value's first line reaches the section" \
    "gtitle=[line1" "$AG_ENV_OUT_L"
  assert_contains "10l: newline value's last line reaches the section intact" \
    "line3]" "$AG_ENV_OUT_L"
  assert_contains "10l: omitted GOAL_IDENTIFIER is defined-but-empty despite the decoy line" \
    "gident=[]" "$AG_ENV_OUT_L"
  if echo "$AG_ENV_OUT_L" | grep -qF '"status": "failed"'; then
    echo -e "  ${RED}FAIL${RESET}: 10l: after_goal section must not fail on the newline fixture"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 10l: after_goal section succeeds on the newline fixture"
    PASS=$((PASS + 1))
  fi
  AG_TITLE_L=$(
    set -a
    . "$AG_ENV_PROJ_L/.stride-env-cache" 2>/dev/null
    set +a
    printf '%s' "${GOAL_TITLE:-}"
  )
  assert_contains "10l: cache round-trips the embedded newline value" "line3" "$AG_TITLE_L"

  # 10m (W1609): a /complete whose tool_response.stdout is truncated mid-JSON but
  # which has a present canonical response file carrying the after_goal entry
  # still routes into ## after_goal AND exports the server-supplied GOAL_* env
  # from the file — end-to-end proof that after_goal detection and
  # export_after_goal_env both read file-first under a truncated stdout.
  AG_ENV_PROJ_M=$(ag_env_project "w1609-file")
  mkdir -p "$AG_ENV_PROJ_M/.stride"
  jq -nc '{data: {id: 99, parent_id: 55}, hooks: [
    {"name":"before_review"},
    {"name":"after_goal","env":{"GOAL_ID":"7","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven"}}
  ]}' > "$AG_ENV_PROJ_M/.stride/.last-api-response.json"
  # Deliberately truncated stdout (invalid JSON) — the file must be the source.
  AG_ENV_INPUT_M=$(jq -nc --arg s '{"data":{"id":99,"parent' \
    '{tool_input:{command:"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"},tool_response:{stdout:$s}}')
  AG_ENV_OUT_M=$(echo "$AG_ENV_INPUT_M" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ_M" \
    bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "10m: truncated /complete stdout still runs after_goal via the canonical file" \
    "gident=[G7]" "$AG_ENV_OUT_M"
  AG_ENV_CACHE_M=$(cat "$AG_ENV_PROJ_M/.stride-env-cache" 2>/dev/null || echo "")
  assert_contains "10m: env cache carries GOAL_ID from the canonical file for the follow-up PATCH" \
    "GOAL_ID='7'" "$AG_ENV_CACHE_M"
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
# when the GLOBAL HOOK_NAME is after_doing, so the 600s hook timeout cannot
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
  # A parseable /complete response (no after_goal entry) so the D118 fast path in
  # route_after_goal answers "not armed" without a D119 fresh call — isolating
  # these changed_files self-heal assertions from the after_goal curl path.
  W1094_COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""},"tool_response":{"stdout":"{\"data\":{\"id\":42},\"hooks\":[{\"name\":\"before_review\"}]}"}}'

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

  # 13k (W1658): before_review self-heal TERMINAL failure. When the LAST retry
  # PUT returns non-2xx, the hook surfaces a loud UNRESOLVED warning on stderr
  # (distinct from the per-attempt warning) AND marks the state file
  # `unresolved=yes` — so a definitively-lost diff is never silently swallowed.
  SH_DIR_K=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  make_curl_stub "$STUB_DIR" "$SH_DIR_K/curl-call.txt" 0 500
  SH_STDERR_K=$(
    setup_put_repo "$SH_DIR_K" > /dev/null 2>&1 || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post 2>&1 1>/dev/null
  )
  SH_STATE_K=$(cat "$SH_DIR_K/.stride-diff-upload-state" 2>/dev/null)
  if printf '%s' "$SH_STDERR_K" | grep -qF 'CHANGED_FILES UPLOAD UNRESOLVED'; then
    echo -e "  ${GREEN}PASS${RESET}: 13k (W1658): terminal self-heal failure prints a loud UNRESOLVED warning"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13k (W1658): no loud UNRESOLVED warning on stderr: $SH_STDERR_K"
    FAIL=$((FAIL + 1))
  fi
  assert_contains "13k (W1658): state file marked unresolved on terminal failure" "unresolved=yes" "$SH_STATE_K"
  rm -rf "$SH_DIR_K" "$STUB_DIR"

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
# Test Group 14: claim-time TASK_BASE_REF refresh + persisted-output
# fallback (W1086)
# ============================================================
# A claim always opens a new task window. The hook must refresh TASK_BASE_REF
# to current HEAD on every claim: from parseable stdout, from a persisted
# output file when stdout only carries a "saved to" notice, and — when no JSON
# is obtainable at all — by rewriting only the TASK_BASE_REF line while
# preserving the existing TASK_ identity lines. Non-claim hooks never touch it.
echo ""
echo "=== Test Group 14: claim TASK_BASE_REF refresh (W1086) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 14 requires both (reuses Group 8 helpers)"
else
  # 14a: inline stdout JSON (Claude Code wrapper) writes the full cache with
  # TASK_BASE_REF equal to current HEAD.
  BR_DIR_A=$(mktemp -d)
  BR_CLAIM_A='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":42,\"identifier\":\"W42\",\"title\":\"Inline Task\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_A" || exit 1
    echo "$BR_CLAIM_A" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_A=$(git -C "$BR_DIR_A" rev-parse HEAD)
  BR_CACHE_A=$(cat "$BR_DIR_A/.stride-env-cache" 2>/dev/null)
  assert_contains "14a: inline JSON writes the identifier" "TASK_IDENTIFIER='W42'" "$BR_CACHE_A"
  assert_contains "14a: inline JSON sets TASK_BASE_REF to current HEAD" "TASK_BASE_REF='$BR_HEAD_A'" "$BR_CACHE_A"
  rm -rf "$BR_DIR_A"

  # 14b: a persisted-output notice pointing at a readable file containing the
  # API JSON writes the full cache from the file content.
  BR_DIR_B=$(mktemp -d)
  BR_PERSIST_B=$(mktemp -d)
  BR_FILE_B="$BR_PERSIST_B/persisted.json"
  printf '{"data":{"id":77,"identifier":"W77","title":"Persisted Task","status":"in_progress","complexity":"medium","priority":"high"}}' > "$BR_FILE_B"
  BR_CLAIM_B=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s","stderr":"","interrupted":false}}' "$BR_FILE_B")
  (
    setup_put_repo "$BR_DIR_B" || exit 1
    echo "$BR_CLAIM_B" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_B=$(git -C "$BR_DIR_B" rev-parse HEAD)
  BR_CACHE_B=$(cat "$BR_DIR_B/.stride-env-cache" 2>/dev/null)
  assert_contains "14b: persisted file supplies the identifier" "TASK_IDENTIFIER='W77'" "$BR_CACHE_B"
  assert_contains "14b: persisted file path sets TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_B'" "$BR_CACHE_B"
  rm -rf "$BR_DIR_B" "$BR_PERSIST_B"

  # 14c: garbage stdout with no persisted file refreshes only TASK_BASE_REF,
  # preserves the prior TASK_ID line, and removes the stale snapshot.
  BR_DIR_C=$(mktemp -d)
  BR_CLAIM_C='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"this is not json at all","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_C" || exit 1
    printf '[{"path":"stale.txt","diff":"x"}]\n' > .stride-changed-files.json
    echo "$BR_CLAIM_C" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_C=$(git -C "$BR_DIR_C" rev-parse HEAD)
  BR_CACHE_C=$(cat "$BR_DIR_C/.stride-env-cache" 2>/dev/null)
  assert_contains "14c: garbage stdout preserves the prior TASK_ID" "TASK_ID='42'" "$BR_CACHE_C"
  assert_contains "14c: garbage stdout still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_C'" "$BR_CACHE_C"
  if [ ! -f "$BR_DIR_C/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 14c: base-ref-only refresh removes the stale snapshot"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 14c: stale snapshot survived the base-ref-only refresh"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BR_DIR_C"

  # 14d: a persisted-output notice pointing at a missing file falls through to
  # the base-ref-only refresh (prior TASK_ID preserved, TASK_BASE_REF = HEAD).
  BR_DIR_D=$(mktemp -d)
  BR_PERSIST_D=$(mktemp -d)
  BR_CLAIM_D=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s/does-not-exist.json","stderr":"","interrupted":false}}' "$BR_PERSIST_D")
  (
    setup_put_repo "$BR_DIR_D" || exit 1
    echo "$BR_CLAIM_D" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_D=$(git -C "$BR_DIR_D" rev-parse HEAD)
  BR_CACHE_D=$(cat "$BR_DIR_D/.stride-env-cache" 2>/dev/null)
  assert_contains "14d: missing persisted file preserves the prior TASK_ID" "TASK_ID='42'" "$BR_CACHE_D"
  assert_contains "14d: missing persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_D'" "$BR_CACHE_D"
  rm -rf "$BR_DIR_D" "$BR_PERSIST_D"

  # 14e: a non-claim post invocation (complete URL) leaves TASK_BASE_REF
  # untouched at the previously-recorded base ref.
  BR_DIR_E=$(mktemp -d)
  BR_COMPLETE_E='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete"}}'
  (
    setup_put_repo "$BR_DIR_E" || exit 1
    echo "$BR_COMPLETE_E" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_BASE_E=$(grep -oE "TASK_BASE_REF='[^']*'" "$BR_DIR_E/.stride-env-cache" 2>/dev/null)
  BR_PUTBASE_E=$(git -C "$BR_DIR_E" rev-parse HEAD~1)
  assert_eq "14e: complete URL leaves TASK_BASE_REF at the prior base ref" "TASK_BASE_REF='$BR_PUTBASE_E'" "$BR_BASE_E"
  rm -rf "$BR_DIR_E"

  # 14f: garbage stdout in a non-git directory (rev-parse fails) never crashes
  # the hook and writes no cache.
  BR_DIR_F=$(mktemp -d)
  cat > "$BR_DIR_F/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  BR_CLAIM_F='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"not json","stderr":"","interrupted":false}}'
  OUTPUT=$(echo "$BR_CLAIM_F" | CLAUDE_PROJECT_DIR="$BR_DIR_F" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "14f: garbage stdout in a non-git dir exits 0" 0 "$EXIT_CODE"
  if [ ! -f "$BR_DIR_F/.stride-env-cache" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 14f: no cache written when HEAD is unresolvable"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 14f: cache written despite unresolvable HEAD"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BR_DIR_F"

  # 14g: a persisted file whose content is the harness preview text (not JSON)
  # falls through to the base-ref-only refresh.
  BR_DIR_G=$(mktemp -d)
  BR_PERSIST_G=$(mktemp -d)
  BR_FILE_G="$BR_PERSIST_G/preview.txt"
  printf '... (output truncated for preview) ...\nnot valid json\n' > "$BR_FILE_G"
  BR_CLAIM_G=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s","stderr":"","interrupted":false}}' "$BR_FILE_G")
  (
    setup_put_repo "$BR_DIR_G" || exit 1
    echo "$BR_CLAIM_G" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_G=$(git -C "$BR_DIR_G" rev-parse HEAD)
  BR_CACHE_G=$(cat "$BR_DIR_G/.stride-env-cache" 2>/dev/null)
  assert_contains "14g: non-JSON persisted file preserves the prior TASK_ID" "TASK_ID='42'" "$BR_CACHE_G"
  assert_contains "14g: non-JSON persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_G'" "$BR_CACHE_G"
  rm -rf "$BR_DIR_G" "$BR_PERSIST_G"

  # 14h: garbage stdout with NO pre-existing cache creates one containing only
  # TASK_BASE_REF (no TASK_ identity lines to preserve).
  BR_DIR_H=$(mktemp -d)
  BR_CLAIM_H='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"garbage","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_H" || exit 1
    rm -f .stride-env-cache
    echo "$BR_CLAIM_H" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_H=$(git -C "$BR_DIR_H" rev-parse HEAD)
  BR_CACHE_H=$(cat "$BR_DIR_H/.stride-env-cache" 2>/dev/null)
  assert_contains "14h: absent cache is created with TASK_BASE_REF at HEAD" "TASK_BASE_REF='$BR_HEAD_H'" "$BR_CACHE_H"
  if echo "$BR_CACHE_H" | grep -q '^TASK_ID='; then
    echo -e "  ${RED}FAIL${RESET}: 14h: invented a TASK_ID line with no source data"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 14h: no spurious TASK_ identity lines created"
    PASS=$((PASS + 1))
  fi
  rm -rf "$BR_DIR_H"

  # 14i: a persisted-output path containing spaces is recovered intact (the
  # notice may also wrap it in quotes). Guards the bash/ps1 parity contract.
  BR_DIR_I=$(mktemp -d)
  BR_PERSIST_I=$(mktemp -d)/"with space dir"
  mkdir -p "$BR_PERSIST_I"
  BR_FILE_I="$BR_PERSIST_I/persisted.json"
  printf '{"data":{"id":88,"identifier":"W88","title":"Spaced Task","status":"in_progress","complexity":"small","priority":"low"}}' > "$BR_FILE_I"
  BR_CLAIM_I=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s","stderr":"","interrupted":false}}' "$BR_FILE_I")
  (
    setup_put_repo "$BR_DIR_I" || exit 1
    echo "$BR_CLAIM_I" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_CACHE_I=$(cat "$BR_DIR_I/.stride-env-cache" 2>/dev/null)
  assert_contains "14i: persisted path with spaces is recovered" "TASK_IDENTIFIER='W88'" "$BR_CACHE_I"
  rm -rf "$BR_DIR_I" "$BR_PERSIST_I"

  # 14j (W1453): the claim cache writer escapes embedded single quotes and
  # dollar signs so a crafted title round-trips through the set -a sourcing
  # without any shell interpretation.
  BR_DIR_J=$(mktemp -d)
  BR_INNER_J=$(jq -nc '{data: {id: 43, identifier: "W43", title: "It'"'"'s $HOME tricky", status: "in_progress", complexity: "small", priority: "low"}}')
  BR_CLAIM_J=$(jq -nc --arg inner "$BR_INNER_J" \
    '{tool_input: {command: "curl -X POST https://stride.example.com/api/tasks/claim"}, tool_response: {stdout: $inner, stderr: "", interrupted: false}}')
  (
    setup_put_repo "$BR_DIR_J" || exit 1
    echo "$BR_CLAIM_J" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_TITLE_J=$(
    set -a
    . "$BR_DIR_J/.stride-env-cache" 2>/dev/null
    set +a
    printf '%s' "$TASK_TITLE"
  )
  assert_eq "14j: quoted title round-trips through the env cache unexecuted" \
    "It's \$HOME tricky" "$BR_TITLE_J"
  rm -rf "$BR_DIR_J"

  # 14k (W1609): a claim whose stdout is truncated mid-JSON but which has a
  # present canonical response file recovers the FULL task JSON from the file —
  # TASK_IDENTIFIER comes from the file and TASK_BASE_REF is refreshed to HEAD.
  # This is the sibling-truncation fix: without the shared file-first resolver
  # the claim would degrade to a base-ref-only refresh and lose task identity.
  BR_DIR_K=$(mktemp -d)
  BR_CLAIM_K='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":609,\"identif","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_K" || exit 1
    mkdir -p .stride
    printf '{"data":{"id":609,"identifier":"W609","title":"File Task","status":"in_progress","complexity":"medium","priority":"high"}}' > .stride/.last-api-response.json
    echo "$BR_CLAIM_K" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_K=$(git -C "$BR_DIR_K" rev-parse HEAD)
  BR_CACHE_K=$(cat "$BR_DIR_K/.stride-env-cache" 2>/dev/null)
  assert_contains "14k: truncated claim recovers the identifier from the canonical file" "TASK_IDENTIFIER='W609'" "$BR_CACHE_K"
  assert_contains "14k: truncated claim still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_K'" "$BR_CACHE_K"
  rm -rf "$BR_DIR_K"

  # 14l (W1609): a valid claim stdout is captured to the canonical response file
  # so later lifecycle hooks (whose own stdout the harness may truncate) can read it.
  BR_DIR_L=$(mktemp -d)
  BR_CLAIM_L='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":610,\"identifier\":\"W610\",\"title\":\"Cap Task\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_L" || exit 1
    echo "$BR_CLAIM_L" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_RESP_L=$(cat "$BR_DIR_L/.stride/.last-api-response.json" 2>/dev/null)
  assert_contains "14l: valid claim stdout is captured to the canonical response file" '"identifier":"W610"' "$BR_RESP_L"
  rm -rf "$BR_DIR_L"

  # 14m (W1609): a stale canonical file from a prior call does NOT shadow a valid
  # current claim stdout — the capture overwrites it first, so the env cache
  # reflects the CURRENT claim, not the stale file (no staleness regression).
  BR_DIR_M=$(mktemp -d)
  BR_CLAIM_M='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":611,\"identifier\":\"W611\",\"title\":\"Fresh\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_M" || exit 1
    mkdir -p .stride
    printf '{"data":{"id":999,"identifier":"W999","title":"Stale","status":"in_progress","complexity":"large","priority":"high"}}' > .stride/.last-api-response.json
    echo "$BR_CLAIM_M" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_CACHE_M=$(cat "$BR_DIR_M/.stride-env-cache" 2>/dev/null)
  assert_contains "14m: current valid claim overwrites the stale canonical file" "TASK_IDENTIFIER='W611'" "$BR_CACHE_M"
  if echo "$BR_CACHE_M" | grep -q "W999"; then
    echo -e "  ${RED}FAIL${RESET}: 14m: stale file's identifier leaked into the env cache"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 14m: stale identifier did not leak into the env cache"
    PASS=$((PASS + 1))
  fi
  rm -rf "$BR_DIR_M"

  # 14n (W1609): capture_changed_files never includes anything under the root
  # .stride/ state dir (the canonical response file and orchestrator marker live
  # there) even in a repo that forgot to gitignore it — a real change is still captured.
  CF_DIR=$(mktemp -d)
  CF_OUT=$(
    cd "$CF_DIR" || exit 99
    git init -q; git config user.email t@t.local; git config user.name t
    echo base > a.txt; git add a.txt; git commit -qm base > /dev/null 2>&1
    CF_BASE=$(git rev-parse HEAD)
    echo changed > a.txt
    mkdir -p .stride; printf '{"data":{"id":1}}' > .stride/.last-api-response.json
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$CF_DIR"
    HAS_JQ=true
    capture_changed_files "$CF_BASE" 2>/dev/null
  )
  if echo "$CF_OUT" | grep -q 'last-api-response.json'; then
    echo -e "  ${RED}FAIL${RESET}: 14n: .stride/ file leaked into changed_files"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 14n: .stride/ state dir excluded from changed_files"
    PASS=$((PASS + 1))
  fi
  assert_contains "14n: a real changed file is still captured" "a.txt" "$CF_OUT"
  rm -rf "$CF_DIR"

  # 14o (D259): the unparseable-claim branch must give the SAME window hygiene
  # the parseable one does. It was a four-key deny-list while its own comment
  # said "keep the existing TASK_ identity lines", so GOAL_*, BOARD_*, COLUMN_*
  # and AGENT_NAME crossed the window boundary. A fresh task window then opened
  # with the PREVIOUS goal's identity exported to every hook and agent command
  # in it. Nothing pinned either path's cleared set before this.
  #
  # The seeded cache is deliberately hostile: two contradictory GOAL_TITLE
  # lines (so a survivor cannot be explained as "the one true value"), a
  # multi-line TASK_DESCRIPTION that is DROPPED and a multi-line TASK_TITLE
  # that is KEPT — both with continuations that read as cache lines, so the
  # scan is exercised in both directions — and one record from each of the five
  # per-task families that MUST survive: stripping TASK_BASE_AT_ or
  # TASK_NARROWED_ would reopen the D273 defects.
  #
  # The strategy's other edge case, "unparseable claim with NO prior cache at
  # all", is already pinned by 14h above: it removes the cache, drives an
  # unparseable claim, and asserts no spurious TASK_ identity is invented. That
  # geometry never enters this branch (the `elif` requires the file to exist),
  # so it is cited rather than duplicated here.
  D259_DIR=$(mktemp -d)
  cat > "$D259_DIR/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  cat > "$D259_DIR/.stride-env-cache" << 'CACHE'
TASK_ID='41'
TASK_IDENTIFIER='W41'
GOAL_ID='6'
GOAL_TITLE='Alpha Goal'
GOAL_TITLE='Beta Goal'
BOARD_ID='3'
BOARD_NAME='Old Board'
COLUMN_NAME='Doing'
AGENT_NAME='Someone Else'
TASK_DESCRIPTION='line1
GOAL_ID=999
line3'
TASK_TITLE='kept1
GOAL_ID=888
kept3'
TASK_BASE_REF='deadbeef'
TASK_BASE_REF_TRUSTED='1'
TASK_BASE_REF_OWNER='41'
TASK_BASE_REF_UNPROVEN='1'
TASK_BASE_REF_77='aaaa111'
TASK_HEAD_REF_77='bbbb222'
TASK_OWNED_77='cccc333'
TASK_BASE_AT_77='1786846260'
TASK_NARROWED_77='yes'
CACHE
  D259_CLAIM='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Internal Server Error","stderr":"","interrupted":false}}'
  echo "$D259_CLAIM" | CLAUDE_PROJECT_DIR="$D259_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  D259_CACHE=$(cat "$D259_DIR/.stride-env-cache" 2>/dev/null)
  # GOAL_ID needs a different oracle from its siblings, and the reason is the
  # point of the fixture: the KEPT TASK_TITLE value contains a line reading
  # `GOAL_ID=888`, so `grep -c '^GOAL_ID='` legitimately returns 1 — that hit
  # is DATA inside a record, not a record. Counting lines would therefore pin
  # the wrong property and fail for the right behaviour. Sourcing asks the
  # question that actually matters: is there a GOAL_ID *record*? A decoy inside
  # a single-quoted value cannot set one.
  assert_eq "14o (D259): no stale GOAL_ID record survives, and a decoy inside a kept value is not one" \
    "UNSET" \
    "$(set -a; . "$D259_DIR/.stride-env-cache" 2>/dev/null; set +a; printf '%s' "${GOAL_ID:-UNSET}")"
  for _k in GOAL_TITLE BOARD_ID BOARD_NAME COLUMN_NAME AGENT_NAME; do
    assert_eq "14o (D259): no stale $_k survives an unparseable claim" "0" \
      "$(printf '%s\n' "$D259_CACHE" | grep -c "^${_k}=" || true)"
  done
  # The branch's stated purpose — TASK_ID recovery — must still hold.
  assert_contains "14o (D259): TASK_ID still recoverable, the branch's stated purpose" \
    "TASK_ID='41'" "$D259_CACHE"
  # All five per-task record families must survive; two of them are load-bearing
  # for D273 and stripping them would silently stop the D255 narrowing.
  for _k in TASK_BASE_REF_77 TASK_HEAD_REF_77 TASK_OWNED_77 TASK_BASE_AT_77 TASK_NARROWED_77; do
    assert_contains "14o (D259): the $_k attribution record survives the clear" \
      "$_k=" "$D259_CACHE"
  done
  # The shared base keys keep being stripped, exactly as before.
  for _k in TASK_BASE_REF TASK_BASE_REF_TRUSTED TASK_BASE_REF_OWNER TASK_BASE_REF_UNPROVEN; do
    assert_eq "14o (D259): $_k is still stripped" "0" \
      "$(printf '%s\n' "$D259_CACHE" | grep -c "^${_k}=" || true)"
  done
  # The multi-line record is dropped as ONE unit — no orphaned continuation
  # line, which a line-based allow-list would have left behind.
  assert_eq "14o (D259): a dropped multi-line record leaves no orphan continuation" "0" \
    "$(printf '%s\n' "$D259_CACHE" | grep -c 'line3' || true)"
  # The other half of the quote-awareness rationale, and the DANGEROUS one: a
  # KEPT record whose value spans lines must survive whole. A naive line filter
  # keeps the first line and drops the rest, leaving an unbalanced single quote
  # in a file this script sources with `set -a` a few lines later — so the
  # failure mode is not a lost title, it is a cache that will not source.
  assert_eq "14o (D259): a KEPT multi-line record survives whole, and the cache still sources" \
    "kept1|GOAL_ID=888|kept3" \
    "$(set -a; . "$D259_DIR/.stride-env-cache" 2>/dev/null; set +a; printf '%s' "${TASK_TITLE:-UNSET}" | tr '\n' '|')"
  rm -rf "$D259_DIR"

  # 14o2 (D259): the fail-closed path. The scan assumes every line is
  # sq_escape/@sh output with balanced quoting. If that ever stops holding, a
  # desynchronised scanner could drop a record it could not parse — so it exits
  # non-zero on EOF-inside-a-value and the branch falls back to the previous
  # deny-list, which over-preserves (the very bug D259 fixes) rather than
  # losing data. Over-preserving is recoverable; a dropped attribution record
  # is not. The seeded cache carries a deliberately unbalanced line.
  D259_DIR_F=$(mktemp -d)
  cat > "$D259_DIR_F/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  printf "TASK_ID='41'\nGOAL_ID='6'\nTASK_TITLE='unterminated\n" > "$D259_DIR_F/.stride-env-cache"
  echo "$D259_CLAIM" | CLAUDE_PROJECT_DIR="$D259_DIR_F" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  D259_CACHE_F=$(cat "$D259_DIR_F/.stride-env-cache" 2>/dev/null)
  assert_contains "14o2 (D259): an unbalanced cache falls back to the deny-list, keeping TASK_ID" \
    "TASK_ID='41'" "$D259_CACHE_F"
  assert_contains "14o2 (D259): the fallback over-preserves rather than dropping records it could not parse" \
    "GOAL_ID='6'" "$D259_CACHE_F"
  rm -rf "$D259_DIR_F"

  # 14p (D259): the parseable-path control. The two branches are two ways of
  # surviving the same event and owe the same guarantee, so the regression this
  # pins is the pair diverging again — in either direction.
  D259_DIR_P=$(mktemp -d)
  cat > "$D259_DIR_P/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  printf "GOAL_ID='6'\nBOARD_ID='3'\nAGENT_NAME='Someone Else'\n" > "$D259_DIR_P/.stride-env-cache"
  D259_OK=$(jq -nc --arg cmd "curl -X POST https://stride.example.com/api/tasks/claim" \
    --arg out '{"data":{"id":42,"identifier":"W42","title":"t","status":"in_progress","complexity":"small","priority":"high"}}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}')
  echo "$D259_OK" | CLAUDE_PROJECT_DIR="$D259_DIR_P" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  D259_CACHE_P=$(cat "$D259_DIR_P/.stride-env-cache" 2>/dev/null)
  for _k in GOAL_ID BOARD_ID AGENT_NAME; do
    assert_eq "14p (D259): the parseable path also carries no stale $_k" "0" \
      "$(printf '%s\n' "$D259_CACHE_P" | grep -c "^${_k}=" || true)"
  done
  assert_contains "14p (D259): and it writes the new task's identity" "TASK_ID='42'" "$D259_CACHE_P"
  rm -rf "$D259_DIR_P"

  # 14q (D260): one parseable claim used to write every identity key TWICE —
  # once from the identity rewrite reading the data block, then again from the
  # hook-env forwarding append. Under a data-vs-env skew that left grep -m1 and
  # sourcing disagreeing about the current task's own status and title, in ONE
  # run. THE DECIDED WINNER IS THE FORWARDED ENV BLOCK, and this pins it: that
  # is already the value the ## before_doing section receives in its process
  # env (the forwarding eval runs after the cache load), so recording it
  # changes nothing a section can observe — the task's own pitfall forbids
  # changing that value, which is why the alternative fix shape (skip
  # forwarding the duplicated keys) was rejected as inadmissible rather than
  # merely less tidy.
  D260_DIR=$(mktemp -d)
  D260_STUB=$(mktemp -d)
  make_curl_stub "$D260_STUB" "$D260_DIR/curl-call.txt" 0
  (
    cd "$D260_DIR" || exit 1
    git init -q; git config user.email t@t.local; git config user.name t
    printf '.stride.md\n.stride-env-cache\ncurl-call.txt\n' > .gitignore
    printf '## before_doing\n```bash\necho "s=[$TASK_STATUS] t=[$TASK_TITLE]"\n```\n\n## before_review\n```bash\ntrue\n```\n' > .stride.md
    echo v1 > f.txt; git add -A > /dev/null; git commit -q -m v1
    mkdir -p .stride
  )
  D260_CLAIM=$(jq -nc --arg cmd "curl -X POST https://stride.example.com/api/tasks/claim" \
    --arg out '{"data":{"id":42,"identifier":"W42","title":"Task title in data","status":"doing","complexity":"small","priority":"high"},"hook":{"name":"before_doing","env":{"TASK_STATUS":"ready","TASK_TITLE":"Task title in env (stale)","TASK_DESCRIPTION":"only in env"}}}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}')
  D260_OUT=$(echo "$D260_CLAIM" | CLAUDE_PROJECT_DIR="$D260_DIR" bash "$HOOK_SCRIPT" post 2>&1)
  D260_CACHE=$(cat "$D260_DIR/.stride-env-cache" 2>/dev/null)
  for _k in TASK_ID TASK_IDENTIFIER TASK_TITLE TASK_STATUS TASK_COMPLEXITY TASK_PRIORITY; do
    assert_eq "14q (D260): exactly one $_k line after one parseable claim" "1" \
      "$(printf '%s\n' "$D260_CACHE" | grep -c "^${_k}=" || true)"
  done
  assert_eq "14q (D260): the surviving value is the forwarded env block's, and first-match now agrees with sourcing" \
    "TASK_TITLE='Task title in env (stale)'" \
    "$(printf '%s\n' "$D260_CACHE" | grep -m1 '^TASK_TITLE=')"
  # The pitfall: the section's process env must be untouched by this change.
  assert_contains "14q (D260): the section still receives the forwarded env values, unchanged" \
    "s=[ready] t=[Task title in env (stale)]" "$D260_OUT"
  # Edge case (a): a key the rewrite never writes must still be forwarded, once.
  assert_eq "14q (D260): a key only the env supplies is still forwarded, exactly once" "1" \
    "$(printf '%s\n' "$D260_CACHE" | grep -c '^TASK_DESCRIPTION=' || true)"
  # The record families must pass through untouched — collapsing them would
  # reopen D226/D268/D273.
  assert_eq "14q (D260): the per-task base record is untouched" "1" \
    "$(printf '%s\n' "$D260_CACHE" | grep -c '^TASK_BASE_REF_42=' || true)"
  # The broader finding this fix also closes: duplicates ACCUMULATED across
  # every post hook in a claim window, not just the two written at claim.
  # Measured pre-fix at 2 -> 3 -> 4 lines for TASK_TITLE across two
  # before_review invocations, bounded only by the next claim's truncation.
  D260_COMPLETE=$(jq -nc --arg cmd "curl -X PATCH https://stride.example.com/api/tasks/42/complete" \
    --arg out '{"data":{"id":42},"hooks":[{"name":"before_review","env":{"TASK_ID":"42","TASK_TITLE":"Task title in env (stale)"}}]}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}')
  echo "$D260_COMPLETE" | CLAUDE_PROJECT_DIR="$D260_DIR" PATH="$D260_STUB:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  echo "$D260_COMPLETE" | CLAUDE_PROJECT_DIR="$D260_DIR" PATH="$D260_STUB:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  D260_CACHE2=$(cat "$D260_DIR/.stride-env-cache" 2>/dev/null)
  assert_eq "14q (D260): later post hooks in the same window do not accumulate copies" "1" \
    "$(printf '%s\n' "$D260_CACHE2" | grep -c '^TASK_TITLE=' || true)"
  rm -rf "$D260_DIR" "$D260_STUB"

  # 14r (D260): edge case (b) — an env block supplying NO TASK_* keys leaves the
  # rewrite-only path exactly as it was. The collapse must be driven by the
  # keys a call actually writes, never by a blanket TASK_* sweep, or a claim
  # whose env carries only BOARD_*/AGENT_NAME would rewrite identity lines it
  # was never given values for.
  D260_DIR_B=$(mktemp -d)
  (
    cd "$D260_DIR_B" || exit 1
    git init -q; git config user.email t@t.local; git config user.name t
    printf '.stride.md\n.stride-env-cache\n' > .gitignore
    printf '## before_doing\n```bash\ntrue\n```\n' > .stride.md
    echo v1 > f.txt; git add -A > /dev/null; git commit -q -m v1
    mkdir -p .stride
  )
  D260_CLAIM_B=$(jq -nc --arg cmd "curl -X POST https://stride.example.com/api/tasks/claim" \
    --arg out '{"data":{"id":43,"identifier":"W43","title":"Only in data","status":"doing","complexity":"small","priority":"low"},"hook":{"name":"before_doing","env":{"BOARD_NAME":"Stride Development","AGENT_NAME":"Someone"}}}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}')
  echo "$D260_CLAIM_B" | CLAUDE_PROJECT_DIR="$D260_DIR_B" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  D260_CACHE_B=$(cat "$D260_DIR_B/.stride-env-cache" 2>/dev/null)
  assert_eq "14r (D260): rewrite-only path still writes exactly one TASK_TITLE line" "1" \
    "$(printf '%s\n' "$D260_CACHE_B" | grep -c '^TASK_TITLE=' || true)"
  assert_eq "14r (D260): and it keeps the data block's value when the env supplies none" \
    "TASK_TITLE='Only in data'" "$(printf '%s\n' "$D260_CACHE_B" | grep -m1 '^TASK_TITLE=')"
  assert_contains "14r (D260): a non-TASK key the env did supply still lands" \
    "BOARD_NAME=" "$D260_CACHE_B"
  rm -rf "$D260_DIR_B"
fi

# ============================================================
echo ""
echo "=== Test Group 15: per-hook command timeouts (W1454) ==="

# 15a: A command exceeding the budget is killed and reported as a blocking
# failure naming the hook and budget (uses the auto-probed timeout tool).
TO_PROJ="$TMPDIR_TEST/timeout-project"
mkdir -p "$TO_PROJ"
cat > "$TO_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "started"
sleep 30
touch should_not_exist.txt
```
STRIDE
TO_CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
TO_STDERR_FILE=$(mktemp)
TO_START=$(date +%s)
OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$TO_PROJ" STRIDE_HOOK_TIMEOUT_OVERRIDE=$TIMEOUT_TEST_BUDGET bash "$HOOK_SCRIPT" post 2>"$TO_STDERR_FILE")
EXIT_CODE=$?
TO_WALL=$(( $(date +%s) - TO_START ))
TO_STDERR=$(cat "$TO_STDERR_FILE")
rm -f "$TO_STDERR_FILE"
assert_exit "15a: timed-out hook exits 2 (blocking failure)" 2 "$EXIT_CODE"
assert_contains "15a: stderr names the hook and budget" \
  "Stride before_doing hook command 2/3 timed out after ${TIMEOUT_TEST_BUDGET}s budget" "$TO_STDERR"
assert_contains "15a: failure JSON marks timed_out" '"timed_out": true' "$OUTPUT"
assert_contains "15a: failure JSON carries exit 124" '"exit_code": 124' "$OUTPUT"
assert_contains "15a: failure JSON carries the budget" "\"budget_seconds\": $TIMEOUT_TEST_BUDGET" "$OUTPUT"
if [ -f "$TO_PROJ/should_not_exist.txt" ]; then
  echo -e "  ${RED}FAIL${RESET}: 15a: commands after the timeout must not run"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 15a: commands after the timeout do not run"
  PASS=$((PASS + 1))
fi
if [ "$TO_WALL" -lt "$(wall_budget 20 30)" ]; then
  echo -e "  ${GREEN}PASS${RESET}: 15a: killed promptly (${TO_WALL}s wall clock)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 15a: expected prompt kill, took ${TO_WALL}s"
  FAIL=$((FAIL + 1))
fi

# 15b: Commands within the budget are unaffected.
WB_PROJ="$TMPDIR_TEST/within-budget-project"
mkdir -p "$WB_PROJ"
cat > "$WB_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "fast one"
echo "fast two"
```
STRIDE
OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$WB_PROJ" STRIDE_HOOK_TIMEOUT_OVERRIDE=30 bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "15b: within-budget hook exits 0" 0 "$EXIT_CODE"
assert_contains "15b: success JSON emitted" '"status": "success"' "$OUTPUT"
assert_contains "15b: both commands completed" "fast two" "$OUTPUT"

# 15c: The watchdog fallback (no timeout utility) still enforces the budget.
TO_STDERR_FILE=$(mktemp)
TO_START=$(date +%s)
OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$TO_PROJ" STRIDE_HOOK_TIMEOUT_OVERRIDE=$TIMEOUT_TEST_BUDGET STRIDE_HOOK_TIMEOUT_TOOL=none bash "$HOOK_SCRIPT" post 2>"$TO_STDERR_FILE")
EXIT_CODE=$?
TO_WALL=$(( $(date +%s) - TO_START ))
TO_STDERR=$(cat "$TO_STDERR_FILE")
rm -f "$TO_STDERR_FILE"
assert_exit "15c: watchdog fallback kills on budget (exit 2)" 2 "$EXIT_CODE"
assert_contains "15c: watchdog reports timeout naming hook and budget" \
  "timed out after ${TIMEOUT_TEST_BUDGET}s budget" "$TO_STDERR"
assert_contains "15c: watchdog synthesizes exit 124" '"exit_code": 124' "$OUTPUT"
if [ "$TO_WALL" -lt "$(wall_budget 20 30)" ]; then
  echo -e "  ${GREEN}PASS${RESET}: 15c: watchdog killed promptly (${TO_WALL}s wall clock)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 15c: watchdog expected prompt kill, took ${TO_WALL}s"
  FAIL=$((FAIL + 1))
fi

# 15c2: The watchdog fallback does not fail healthy hooks.
OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$WB_PROJ" STRIDE_HOOK_TIMEOUT_TOOL=none bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "15c2: watchdog leaves healthy hooks untouched (exit 0)" 0 "$EXIT_CODE"
assert_contains "15c2: healthy hook succeeds under watchdog" '"status": "success"' "$OUTPUT"

# 15d: Budget resolution unit tests (sourced functions).
if command -v jq > /dev/null 2>&1; then
  BUDGET_SRV=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    unset STRIDE_HOOK_TIMEOUT_OVERRIDE   # (D229/D235) assert the committed default
    HAS_JQ=true
    RESPONSE_PAYLOAD='{"data":{},"hooks":[{"name":"before_review","timeout":90000}]}'
    resolve_section_budget before_review
  )
  assert_eq "15d: server 90000ms overrides the 600s default" "90" "$BUDGET_SRV"

  BUDGET_SINGULAR=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    unset STRIDE_HOOK_TIMEOUT_OVERRIDE   # (D229/D235) the suite must assert the
                                         # committed default, not whatever the
                                         # developer's environment happens to set
    HAS_JQ=true
    RESPONSE_PAYLOAD='{"data":{},"hook":{"name":"before_doing","timeout":30000}}'
    resolve_section_budget before_doing
  )
  assert_eq "15d: singular claim-shape hook entry honored" "30" "$BUDGET_SINGULAR"

  BUDGET_DEFAULT_BR=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    unset STRIDE_HOOK_TIMEOUT_OVERRIDE   # (D229/D235) the suite must assert the
                                         # committed default, not whatever the
                                         # developer's environment happens to set
    HAS_JQ=true
    RESPONSE_PAYLOAD=""
    resolve_section_budget before_review
  )
  assert_eq "15d: empty payload falls back to the 600s default" "600" "$BUDGET_DEFAULT_BR"

  BUDGET_DEFAULT_AD=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    unset STRIDE_HOOK_TIMEOUT_OVERRIDE   # (D229/D235) the suite must assert the
                                         # committed default, not whatever the
                                         # developer's environment happens to set
    HAS_JQ=true
    RESPONSE_PAYLOAD=""
    resolve_section_budget after_doing
  )
  assert_eq "15d: after_doing default is 600s (D229: hang detector, not a perf gate)" "600" "$BUDGET_DEFAULT_AD"

  BUDGET_ENV_WINS=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    HAS_JQ=true
    RESPONSE_PAYLOAD='{"data":{},"hooks":[{"name":"before_review","timeout":90000}]}'
    STRIDE_HOOK_TIMEOUT_OVERRIDE=5
    resolve_section_budget before_review
  )
  assert_eq "15d: env override beats the server value" "5" "$BUDGET_ENV_WINS"

  BUDGET_CLAMPED=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    unset STRIDE_HOOK_TIMEOUT_OVERRIDE   # (D229/D235) the suite must assert the
                                         # committed default, not whatever the
                                         # developer's environment happens to set
    HAS_JQ=true
    RESPONSE_PAYLOAD='{"data":{},"hooks":[{"name":"before_review","timeout":999000000}]}'
    resolve_section_budget before_review
  )
  assert_eq "15d: oversized server value clamps to 890s under the outer ceiling" "890" "$BUDGET_CLAMPED"

  BUDGET_NO_JQ=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    unset STRIDE_HOOK_TIMEOUT_OVERRIDE   # (D229/D235) the suite must assert the
                                         # committed default, not whatever the
                                         # developer's environment happens to set
    HAS_JQ=false
    RESPONSE_PAYLOAD='{"data":{},"hooks":[{"name":"before_review","timeout":90000}]}'
    resolve_section_budget before_review
  )
  assert_eq "15d: no jq degrades to the documented default" "600" "$BUDGET_NO_JQ"
fi

# 15d2: Server-supplied timeout enforced end-to-end (no env override).
if command -v jq > /dev/null 2>&1; then
  SRV_PROJ="$TMPDIR_TEST/server-timeout-project"
  mkdir -p "$SRV_PROJ"
  cat > "$SRV_PROJ/.stride.md" << 'STRIDE'
## before_review
```bash
sleep 30
```
STRIDE
  SRV_INNER='{"data":{"id":99},"hooks":[{"name":"before_review","timeout":1000}]}'
  SRV_JSON=$(jq -nc --arg inner "$SRV_INNER" \
    '{tool_input: {command: "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}, tool_response: {stdout: $inner, stderr: "", interrupted: false}}')
  SRV_STDERR_FILE=$(mktemp)
  SRV_START=$(date +%s)
  OUTPUT=$(echo "$SRV_JSON" | env -u STRIDE_HOOK_TIMEOUT_OVERRIDE CLAUDE_PROJECT_DIR="$SRV_PROJ" bash "$HOOK_SCRIPT" post 2>"$SRV_STDERR_FILE")
  EXIT_CODE=$?
  SRV_WALL=$(( $(date +%s) - SRV_START ))
  SRV_STDERR=$(cat "$SRV_STDERR_FILE")
  rm -f "$SRV_STDERR_FILE"
  assert_exit "15d2: server 1000ms timeout enforced end-to-end (exit 2)" 2 "$EXIT_CODE"
  assert_contains "15d2: stderr names the server-derived 1s budget" \
    "timed out after 1s budget" "$SRV_STDERR"
  if [ "$SRV_WALL" -lt "$(wall_budget 20 30)" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 15d2: killed on the server budget (${SRV_WALL}s wall clock)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 15d2: expected kill near 1s, took ${SRV_WALL}s"
    FAIL=$((FAIL + 1))
  fi
fi

# 15e: The budget spans the whole section — a later command only gets what
# the earlier commands left over.
SPAN_PROJ="$TMPDIR_TEST/span-project"
mkdir -p "$SPAN_PROJ"
cat > "$SPAN_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
sleep 2
sleep 30
```
STRIDE
SPAN_STDERR_FILE=$(mktemp)
SPAN_START=$(date +%s)
OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$SPAN_PROJ" STRIDE_HOOK_TIMEOUT_OVERRIDE=$SPAN_TEST_BUDGET bash "$HOOK_SCRIPT" post 2>"$SPAN_STDERR_FILE")
EXIT_CODE=$?
SPAN_WALL=$(( $(date +%s) - SPAN_START ))
SPAN_STDERR=$(cat "$SPAN_STDERR_FILE")
rm -f "$SPAN_STDERR_FILE"
assert_exit "15e: section-budget overrun exits 2" 2 "$EXIT_CODE"
assert_contains "15e: the SECOND command is the one killed" '"command_index": 1' "$OUTPUT"
assert_contains "15e: failure JSON marks timed_out" '"timed_out": true' "$OUTPUT"
assert_contains "15e: budget reported is the section budget" "\"budget_seconds\": $SPAN_TEST_BUDGET" "$OUTPUT"
if [ "$SPAN_WALL" -lt "$(wall_budget 15 32)" ]; then
  echo -e "  ${GREEN}PASS${RESET}: 15e: section killed near its 4s budget (${SPAN_WALL}s wall clock)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 15e: expected kill near 4s, took ${SPAN_WALL}s"
  FAIL=$((FAIL + 1))
fi

# 15f: The probe degrades to the watchdog when no timeout utility exists.
TOOL_RESOLVED=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PATH="/nonexistent"
  STRIDE_TIMEOUT_TOOL_RESOLVED=""
  unset STRIDE_HOOK_TIMEOUT_TOOL 2>/dev/null || true
  resolve_timeout_tool
)
assert_eq "15f: missing timeout utility resolves to the watchdog" "watchdog" "$TOOL_RESOLVED"

# 15g: Killing a timed-out command terminates its whole process group —
# a child spawned by the hung command must not survive the kill.
for TOOL_MODE in "" "none"; do
  ORPHAN_PROJ="$TMPDIR_TEST/orphan-project-${TOOL_MODE:-auto}"
  mkdir -p "$ORPHAN_PROJ"
  cat > "$ORPHAN_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
sleep 30 & echo $! > orphan.pid; wait
```
STRIDE
  if [ -n "$TOOL_MODE" ]; then
    OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$ORPHAN_PROJ" STRIDE_HOOK_TIMEOUT_OVERRIDE=$TIMEOUT_TEST_BUDGET STRIDE_HOOK_TIMEOUT_TOOL="$TOOL_MODE" bash "$HOOK_SCRIPT" post 2>&1)
  else
    OUTPUT=$(echo "$TO_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$ORPHAN_PROJ" STRIDE_HOOK_TIMEOUT_OVERRIDE=$TIMEOUT_TEST_BUDGET bash "$HOOK_SCRIPT" post 2>&1)
  fi
  EXIT_CODE=$?
  ORPHAN_LABEL="15g(${TOOL_MODE:-auto})"
  assert_exit "$ORPHAN_LABEL: orphan fixture times out (exit 2)" 2 "$EXIT_CODE"
  ORPHAN_PID=$(cat "$ORPHAN_PROJ/orphan.pid" 2>/dev/null || echo "")
  if [ -z "$ORPHAN_PID" ]; then
    echo -e "  ${RED}FAIL${RESET}: $ORPHAN_LABEL: fixture never wrote orphan.pid"
    FAIL=$((FAIL + 1))
  else
    # Give TERM->KILL escalation a moment to settle, then require death.
    ORPHAN_DEAD=false
    for _ in 1 2 3 4 5 6; do
      if ! kill -0 "$ORPHAN_PID" 2>/dev/null; then
        ORPHAN_DEAD=true
        break
      fi
      sleep 1
    done
    if [ "$ORPHAN_DEAD" = "true" ]; then
      echo -e "  ${GREEN}PASS${RESET}: $ORPHAN_LABEL: process group killed — no orphaned child"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: $ORPHAN_LABEL: orphan $ORPHAN_PID survived the kill"
      FAIL=$((FAIL + 1))
      kill -KILL "$ORPHAN_PID" 2>/dev/null || true
    fi
  fi
done

# ============================================================
echo ""
echo "=== Test Group 16: duration_ms reporting (W1455) ==="

# 16a: A hook sleeping ~1s reports duration_ms as an integer of plausible
# magnitude (900..5000), alongside the deprecated duration_seconds.
DUR_PROJ="$TMPDIR_TEST/duration-project"
mkdir -p "$DUR_PROJ"
cat > "$DUR_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
sleep 1
```
STRIDE
DUR_CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
OUTPUT=$(echo "$DUR_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$DUR_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "16a: sleeping hook exits 0" 0 "$EXIT_CODE"
assert_contains "16a: success JSON still carries deprecated duration_seconds" '"duration_seconds"' "$OUTPUT"
DUR_MS=$(echo "$OUTPUT" | grep -o '"duration_ms": [0-9]*' | head -1 | grep -o '[0-9]*$')
# (D241) The LOWER bound is load-independent and stays fixed: a 1s sleep cannot
# report less than ~1s however busy the machine is, so 900 catches a genuinely
# wrong measurement. The UPPER bound is the load-sensitive half — it is absorbing
# process-startup overhead, not measuring the sleep — so it scales.
DUR_MAX=$(( 5000 + SUITE_OVERHEAD_MS * 4 ))
if [ -n "$DUR_MS" ] && [ "$DUR_MS" -ge 900 ] && [ "$DUR_MS" -le "$DUR_MAX" ]; then
  echo -e "  ${GREEN}PASS${RESET}: 16a: duration_ms is a plausible integer (${DUR_MS}ms for a 1s sleep)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 16a: expected duration_ms in 900..${DUR_MAX}, got: '${DUR_MS}'"
  FAIL=$((FAIL + 1))
fi

# 16b: The seconds fallback (BSD date without %N and no perl) still emits
# duration_ms — as a whole-second multiple of 1000.
OUTPUT=$(echo "$DUR_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$DUR_PROJ" STRIDE_HOOK_TIME_SOURCE=seconds bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "16b: fallback time source exits 0" 0 "$EXIT_CODE"
DUR_MS=$(echo "$OUTPUT" | grep -o '"duration_ms": [0-9]*' | head -1 | grep -o '[0-9]*$')
if [ -n "$DUR_MS" ] && [ "$DUR_MS" -ge 1000 ] && [ "$DUR_MS" -le 5000 ] && [ $((DUR_MS % 1000)) -eq 0 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 16b: fallback duration_ms is a multiple of 1000 (${DUR_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 16b: expected a 1000-multiple in 1000..5000, got: '${DUR_MS}'"
  FAIL=$((FAIL + 1))
fi

# 16c: A sub-second hook body reports a small non-negative duration_ms.
FAST_PROJ="$TMPDIR_TEST/duration-fast-project"
mkdir -p "$FAST_PROJ"
cat > "$FAST_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "instant"
```
STRIDE
OUTPUT=$(echo "$DUR_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$FAST_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "16c: instant hook exits 0" 0 "$EXIT_CODE"
DUR_MS=$(echo "$OUTPUT" | grep -o '"duration_ms": [0-9]*' | head -1 | grep -o '[0-9]*$')
if [ -n "$DUR_MS" ] && [ "$DUR_MS" -ge 0 ] && [ "$DUR_MS" -le 5000 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 16c: sub-second hook reports non-negative duration_ms (${DUR_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 16c: expected non-negative duration_ms, got: '${DUR_MS}'"
  FAIL=$((FAIL + 1))
fi

# 16d: now_ms unit checks (sourced) — every source yields a plausible epoch
# value and the seconds source is a multiple of 1000.
NOW_MS_NS=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  now_ms
)
if [ -n "$NOW_MS_NS" ] && [ "$NOW_MS_NS" -gt 1000000000000 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 16d: now_ms yields an epoch-milliseconds value"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 16d: now_ms yielded '$NOW_MS_NS'"
  FAIL=$((FAIL + 1))
fi
NOW_MS_SEC=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  STRIDE_HOOK_TIME_SOURCE=seconds
  STRIDE_TIME_SOURCE_RESOLVED=""
  now_ms
)
if [ -n "$NOW_MS_SEC" ] && [ $((NOW_MS_SEC % 1000)) -eq 0 ] && [ "$NOW_MS_SEC" -gt 1000000000000 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 16d: seconds source yields a 1000-multiple epoch value"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 16d: seconds source yielded '$NOW_MS_SEC'"
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=== Test Group 17: backslash line continuation (W1456) ==="

CONT_CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'

# 17a: The canonical multi-line gh pr create example from the workflow skill
# parses into ONE command and executes as one command.
GH_BIN="$TMPDIR_TEST/fake-bin"
mkdir -p "$GH_BIN"
cat > "$GH_BIN/gh" << 'FAKEGH'
#!/bin/sh
echo "gh-argc:$#"
FAKEGH
chmod +x "$GH_BIN/gh"
CONT_PROJ="$TMPDIR_TEST/continuation-project"
mkdir -p "$CONT_PROJ"
cat > "$CONT_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
gh pr create \
  --title "$TASK_IDENTIFIER: $TASK_TITLE" \
  --body "Implements $TASK_IDENTIFIER."
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$CONT_PROJ" PATH="$GH_BIN:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17a: docs gh example exits 0" 0 "$EXIT_CODE"
assert_contains "17a: gh received all six arguments in one invocation" "gh-argc:6" "$OUTPUT"
CONT_LEN=$(echo "$OUTPUT" | jq '.commands_completed | length' 2>/dev/null)
assert_eq "17a: the three physical lines joined into ONE command" "1" "$CONT_LEN"

# 17b: A trailing backslash on the section's last line neither hangs nor
# drops the command.
TAIL_PROJ="$TMPDIR_TEST/tail-backslash-project"
mkdir -p "$TAIL_PROJ"
cat > "$TAIL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo tail\
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$TAIL_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17b: trailing backslash at section end exits 0" 0 "$EXIT_CODE"
assert_contains "17b: the command still ran" "tail" "$OUTPUT"

# 17c: Escaped and quoted backslashes do not trigger joining.
QUOTE_PROJ="$TMPDIR_TEST/quoted-backslash-project"
mkdir -p "$QUOTE_PROJ"
cat > "$QUOTE_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo x\\
echo second
echo 'lit \'
echo third
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$QUOTE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17c: escaped/quoted backslash fixture exits 0" 0 "$EXIT_CODE"
CONT_LEN=$(echo "$OUTPUT" | jq '.commands_completed | length' 2>/dev/null)
assert_eq "17c: four physical lines stay four separate commands" "4" "$CONT_LEN"
assert_contains "17c: escaped backslash command ran separately" "second" "$OUTPUT"
assert_contains "17c: quoted-literal-backslash command ran separately" "third" "$OUTPUT"

# 17c2: DECIDED behavior — a backslash at end of line INSIDE an unclosed
# single quote is literal (no join), so the malformed one-line command
# fails loudly rather than being silently mangled by a naive join.
UNCLOSED_PROJ="$TMPDIR_TEST/unclosed-quote-project"
mkdir -p "$UNCLOSED_PROJ"
cat > "$UNCLOSED_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo 'one \
two'
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$UNCLOSED_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17c2: backslash inside unclosed single quote does not join (command fails loudly)" 2 "$EXIT_CODE"

# 17d: Continuation across three physical lines joins into one command.
TRIPLE_PROJ="$TMPDIR_TEST/triple-continuation-project"
mkdir -p "$TRIPLE_PROJ"
cat > "$TRIPLE_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo a \
b \
c
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$TRIPLE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17d: three-line continuation exits 0" 0 "$EXIT_CODE"
CONT_LEN=$(echo "$OUTPUT" | jq '.commands_completed | length' 2>/dev/null)
assert_eq "17d: three physical lines joined into ONE command" "1" "$CONT_LEN"
assert_contains "17d: joined command output intact" "a b c" "$OUTPUT"

# 17e: A comment-looking line between continued lines is JOINED (logical-line
# comment semantics), not treated as a comment break.
COMMENT_PROJ="$TMPDIR_TEST/comment-continuation-project"
mkdir -p "$COMMENT_PROJ"
cat > "$COMMENT_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo foo \
# joined trailing comment
echo bar
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$COMMENT_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17e: comment between continued lines exits 0" 0 "$EXIT_CODE"
CONT_LEN=$(echo "$OUTPUT" | jq '.commands_completed | length' 2>/dev/null)
assert_eq "17e: two logical commands (comment joined into the first)" "2" "$CONT_LEN"
assert_contains "17e: first command ran with the shell-comment tail dropped" "foo" "$OUTPUT"
assert_contains "17e: second command ran normally" "bar" "$OUTPUT"

# 17g: A standalone comment line ending in a backslash is inert — comments
# never continue in shell, so the following command must still run.
COMMENT_BS_PROJ="$TMPDIR_TEST/comment-backslash-project"
mkdir -p "$COMMENT_BS_PROJ"
cat > "$COMMENT_BS_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
# reminder about C:\temp\
echo survives
```
STRIDE
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$COMMENT_BS_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17g: comment ending in backslash exits 0" 0 "$EXIT_CODE"
CONT_LEN=$(echo "$OUTPUT" | jq '.commands_completed | length' 2>/dev/null)
assert_eq "17g: the command after the comment still runs (not swallowed)" "1" "$CONT_LEN"
assert_contains "17g: command output present" "survives" "$OUTPUT"

# 17f: CRLF line endings before the backslash are stripped, so continuation
# still joins on Windows-authored .stride.md files.
CRLF_CONT_PROJ="$TMPDIR_TEST/crlf-continuation-project"
mkdir -p "$CRLF_CONT_PROJ"
printf '## before_doing\r\n```bash\r\necho crlf \\\r\njoined\r\n```\r\n' > "$CRLF_CONT_PROJ/.stride.md"
OUTPUT=$(echo "$CONT_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$CRLF_CONT_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "17f: CRLF continuation exits 0" 0 "$EXIT_CODE"
assert_contains "17f: CRLF lines joined into one command" "crlf joined" "$OUTPUT"

# ============================================================
echo ""
echo "=== Test Group 18: claim-time dirty baseline (W1457) ==="

if command -v git > /dev/null 2>&1 && command -v jq > /dev/null 2>&1; then
  BL_DIR=$(mktemp -d)
  (
    cd "$BL_DIR" || exit 1
    git init -q .
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'one\n' > pre.txt
    printf 'keep\n' > work.txt
    printf 'del\n' > gone.txt
    git add . > /dev/null
    git commit -q -m "initial"
    git rev-parse HEAD > base.ref

    # Pre-claim state: pre.txt and gone.txt dirty, auth file untracked.
    printf 'pre-existing edit\n' >> pre.txt
    printf 'gone-dirty\n' >> gone.txt
    printf 'secret token\n' > .stride_auth.md

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    PROJECT_DIR="$PWD"
    record_dirty_baseline "$(cat base.ref)"
    cp .stride-dirty-baseline baseline.copy 2>/dev/null || true

    # Task work: touch work.txt, delete the claim-dirty gone.txt.
    printf 'task edit\n' >> work.txt
    rm -f gone.txt
    capture_changed_files "$(cat base.ref)" > snap1.json 2>/dev/null

    # Re-modify the claim-dirty file during the task.
    printf 'task also touched\n' >> pre.txt
    capture_changed_files "$(cat base.ref)" > snap2.json 2>/dev/null

    # Baseline missing (older claim) falls back to current behavior.
    rm -f .stride-dirty-baseline
    capture_changed_files "$(cat base.ref)" > snap3.json 2>/dev/null
  )
  SNAP1_PATHS=$(jq -r '.[].path' "$BL_DIR/snap1.json" 2>/dev/null)
  SNAP2_PATHS=$(jq -r '.[].path' "$BL_DIR/snap2.json" 2>/dev/null)
  SNAP3_PATHS=$(jq -r '.[].path' "$BL_DIR/snap3.json" 2>/dev/null)
  BASELINE_COPY=$(cat "$BL_DIR/baseline.copy" 2>/dev/null)

  assert_contains "18: baseline records the claim-dirty file" "pre.txt" "$BASELINE_COPY"
  assert_contains "18a: task-modified file appears in the snapshot" "work.txt" "$SNAP1_PATHS"
  if echo "$SNAP1_PATHS" | grep -qx "pre.txt"; then
    echo -e "  ${RED}FAIL${RESET}: 18a: claim-dirty untouched file must NOT appear in the snapshot"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 18a: claim-dirty untouched file excluded from the snapshot"
    PASS=$((PASS + 1))
  fi
  assert_contains "18b: claim-dirty file RE-modified during the task IS included" "pre.txt" "$SNAP2_PATHS"
  for _snap_label in 1 2 3; do
    eval "_paths=\$SNAP${_snap_label}_PATHS"
    if echo "$_paths" | grep -q "stride_auth"; then
      echo -e "  ${RED}FAIL${RESET}: 18c: .stride_auth.md leaked into snapshot $_snap_label"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${RESET}: 18c: .stride_auth.md absent from snapshot $_snap_label"
      PASS=$((PASS + 1))
    fi
  done
  if echo "$SNAP1_PATHS" | grep -q "stride-dirty-baseline"; then
    echo -e "  ${RED}FAIL${RESET}: 18d: the baseline artifact leaked into the snapshot"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 18d: the baseline artifact never appears in the snapshot"
    PASS=$((PASS + 1))
  fi
  assert_contains "18e: baseline missing falls back to including the dirty file" "pre.txt" "$SNAP3_PATHS"
  assert_contains "18f: file dirty at claim then DELETED during task is included" "gone.txt" "$SNAP1_PATHS"
  rm -rf "$BL_DIR"

  # 18g: End-to-end — a claim through the hook script writes the baseline.
  E2E_DIR=$(mktemp -d)
  (
    cd "$E2E_DIR" || exit 1
    git init -q .
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'committed\n' > dirty.txt
    git add . > /dev/null
    git commit -q -m "initial"
    printf 'edited before claim\n' >> dirty.txt
    printf '## before_doing\n```bash\n```\n' > .stride.md
  )
  E2E_CLAIM='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
  OUTPUT=$(echo "$E2E_CLAIM" | CLAUDE_PROJECT_DIR="$E2E_DIR" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "18g: claim with dirty tree exits 0" 0 "$EXIT_CODE"
  E2E_BASELINE=$(cat "$E2E_DIR/.stride-dirty-baseline" 2>/dev/null)
  assert_contains "18g: claim wrote the dirty baseline" "dirty.txt" "$E2E_BASELINE"
  rm -rf "$E2E_DIR"
else
  echo "  SKIP: git or jq not available"
fi

# ============================================================
# Test Group 19: D119 hook-initiated after_goal detection
# ============================================================
# The reliability guarantee: when the agent-handed /complete response is
# truncated/absent, the hook detects after_goal via its OWN fresh
# GET /api/tasks/:id/after_goal_status call (immune to Bash-tool truncation) and
# runs ## after_goal from the endpoint's compact GOAL_* env. The D118 fast path
# short-circuits the fresh call when a full response is already available, and
# the two paths never both run the section (de-dup).
echo ""
echo "=== Test Group 19: D119 hook-initiated after_goal detection ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 19 requires jq"
else
  # Build a project whose ## after_goal echoes the exported GOAL_IDENTIFIER.
  d119_project() {
    local _dir="$TMPDIR_TEST/d119-$1"
    mkdir -p "$_dir"
    cat > "$_dir/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal ran for $GOAL_IDENTIFIER"
```
STRIDE
    printf "TASK_ID='42'\n" > "$_dir/.stride-env-cache"
    printf '%s' "$_dir"
  }

  # A curl stub that answers the after_goal_status GET with a JSON body and logs
  # the hit. $2=armed(true|false), $3=call-log path, $4=exit code (0 ok).
  d119_curl_stub() {
    local _stub="$1" _armed="$2" _log="$3" _exit="${4:-0}"
    mkdir -p "$_stub"
    cat > "$_stub/curl" << CURLSTUB
#!/usr/bin/env bash
_hit=""
for a in "\$@"; do
  case "\$a" in */after_goal_status) _hit=1 ;; esac
done
if [ -n "\$_hit" ]; then
  echo hit >> "$_log"
  [ "$_exit" -ne 0 ] && exit $_exit
  if [ "$_armed" = "true" ]; then
    printf '%s' '{"after_goal_armed":true,"goal_id":55,"goal_identifier":"G7","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven","HOOK_NAME":"after_goal"}}'
  else
    printf '%s' '{"after_goal_armed":false,"goal_id":null,"goal_identifier":null,"env":{}}'
  fi
fi
exit 0
CURLSTUB
    chmod +x "$_stub/curl"
  }

  # A /complete input with a truncated stdout (invalid JSON) and a URL+Bearer in
  # the command so resolve_stride_api_url/token succeed with no .stride_auth.md.
  D119_TRUNC_INPUT='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""},"tool_response":{"stdout":"{\"data\":{\"id\":42},\"hoo"}}'

  # 19a: truncated response + NO response file + armed endpoint → the fresh call
  # detects and runs ## after_goal (the exact condition that broke inline parsing).
  D19A_PROJ=$(d119_project "armed")
  D19A_STUB=$(mktemp -d)
  D19A_LOG="$D19A_PROJ/curl.log"
  d119_curl_stub "$D19A_STUB" "true" "$D19A_LOG"
  D19A_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D19A_PROJ" PATH="$D19A_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  D19A_RC=$?
  assert_exit "19a: hook-initiated after_goal exits 0" 0 "$D19A_RC"
  assert_contains "19a: fresh call ran ## after_goal with the endpoint's GOAL_IDENTIFIER" "after_goal ran for G7" "$D19A_OUT"
  assert_contains "19a: the after_goal_status endpoint was called" "hit" "$(cat "$D19A_LOG" 2>/dev/null)"
  rm -rf "$D19A_STUB"

  # 19b: armed=false → ## after_goal does NOT run (endpoint answered definitively).
  D19B_PROJ=$(d119_project "notarmed")
  D19B_STUB=$(mktemp -d)
  D19B_LOG="$D19B_PROJ/curl.log"
  d119_curl_stub "$D19B_STUB" "false" "$D19B_LOG"
  D19B_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D19B_PROJ" PATH="$D19B_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  if echo "$D19B_OUT" | grep -qF "after_goal ran"; then
    echo -e "  ${RED}FAIL${RESET}: 19b: ## after_goal ran despite armed=false"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 19b: armed=false does not run ## after_goal"
    PASS=$((PASS + 1))
  fi
  assert_contains "19b: the endpoint was still consulted" "hit" "$(cat "$D19B_LOG" 2>/dev/null)"
  rm -rf "$D19B_STUB"

  # 19c (de-dup): a present canonical response file (fast path) runs the section
  # ONCE from the file and the fresh after_goal_status endpoint is NOT called.
  D19C_PROJ=$(d119_project "dedup")
  mkdir -p "$D19C_PROJ/.stride"
  printf '%s' '{"data":{"id":42},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G9"}}]}' \
    > "$D19C_PROJ/.stride/.last-api-response.json"
  D19C_STUB=$(mktemp -d)
  D19C_LOG="$D19C_PROJ/curl.log"
  d119_curl_stub "$D19C_STUB" "true" "$D19C_LOG"
  D19C_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D19C_PROJ" PATH="$D19C_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "19c: fast path runs ## after_goal from the canonical file (G9)" "after_goal ran for G9" "$D19C_OUT"
  # Count only the EXPANDED output line ("ran for G9") — the raw command line
  # carries the literal "$GOAL_IDENTIFIER", so counting the expansion isolates
  # real section runs from the echoed command text.
  D19C_RUNS=$(printf '%s\n' "$D19C_OUT" | grep -cF "ran for G9")
  assert_eq "19c: ## after_goal ran exactly once (de-dup)" "1" "$D19C_RUNS"
  if [ -f "$D19C_LOG" ]; then
    echo -e "  ${RED}FAIL${RESET}: 19c: fast path did not short-circuit — endpoint was called"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 19c: fast path short-circuits the fresh call (endpoint not hit)"
    PASS=$((PASS + 1))
  fi
  rm -rf "$D19C_STUB"

  # 19d: endpoint unreachable (curl fails) → clean no-op, exit 0, section not run
  # (the grace-window worker still completes the goal).
  D19D_PROJ=$(d119_project "unreachable")
  D19D_STUB=$(mktemp -d)
  D19D_LOG="$D19D_PROJ/curl.log"
  d119_curl_stub "$D19D_STUB" "true" "$D19D_LOG" 7
  D19D_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D19D_PROJ" PATH="$D19D_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  D19D_RC=$?
  assert_exit "19d: unreachable endpoint still exits 0" 0 "$D19D_RC"
  if echo "$D19D_OUT" | grep -qF "after_goal ran"; then
    echo -e "  ${RED}FAIL${RESET}: 19d: ran ## after_goal despite an unreachable endpoint"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 19d: unreachable endpoint degrades to a clean no-op"
    PASS=$((PASS + 1))
  fi
  rm -rf "$D19D_STUB"
fi

# ============================================================
# Test Group 20: after_goal reliability under truncation (W1612)
# ============================================================
# End-to-end lock-in of the D118/W1609/D119 fix: under the exact oversized-
# response condition that broke after_goal (the harness truncates
# tool_response.stdout), prove the section is detected, GOAL_* is exported, and
# ## after_goal runs via the canonical response file — plus the parent_id
# fallback and missing-section edge cases, and a no-file no-false-positive
# control, all under truncation. (The truncated-stdout + no-file fresh-call path
# itself is covered by Group 19; Group 10m covers env-cache forwarding.)
# 20e/20f lock in W2087: the same detection path against the slim completion
# acknowledgement body (?response_view=slim), positive and negative control.
echo ""
echo "=== Test Group 20: after_goal reliability under truncation (W1612) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 20 requires jq"
else
  # A /complete input whose stdout is truncated mid-JSON (invalid), so detection
  # MUST come from the canonical response file, not the handed stdout.
  W1612_TRUNC='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":99},\"hoo"}}'

  # 20a: truncated stdout + present canonical file with a full after_goal entry
  # -> the section runs, GOAL_* reaches the section AND the env cache (the
  # end-to-end reliability proof).
  W20A_PROJ="$TMPDIR_TEST/w1612-fastpath"
  mkdir -p "$W20A_PROJ/.stride"
  cat > "$W20A_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER] title=[$GOAL_TITLE]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55","GOAL_TITLE":"Goal 55"}}]}' \
    > "$W20A_PROJ/.stride/.last-api-response.json"
  W20A_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20A_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20A_RC=$?
  assert_exit "20a: truncated /complete with a present file exits 0" 0 "$W20A_RC"
  assert_contains "20a: ## after_goal ran with GOAL_IDENTIFIER from the file" "ident=[G55]" "$W20A_OUT"
  assert_contains "20a: GOAL_TITLE exported to the section" "title=[Goal 55]" "$W20A_OUT"
  W20A_CACHE=$(cat "$W20A_PROJ/.stride-env-cache" 2>/dev/null)
  assert_contains "20a: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID='55'" "$W20A_CACHE"

  # 20b: truncated stdout + present file whose after_goal env OMITS GOAL_ID but
  # data.parent_id is set -> the parent-id fallback exports GOAL_ID under truncation.
  W20B_PROJ="$TMPDIR_TEST/w1612-parentid"
  mkdir -p "$W20B_PROJ/.stride"
  cat > "$W20B_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":77},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G77"}}]}' \
    > "$W20B_PROJ/.stride/.last-api-response.json"
  W20B_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20B_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "20b: GOAL_ID falls back to data.parent_id under truncation" "goal=[77]" "$W20B_OUT"
  assert_contains "20b: GOAL_IDENTIFIER still exported from the file" "ident=[G77]" "$W20B_OUT"

  # 20c: truncated stdout + present file WITH an after_goal entry, but the
  # ## after_goal section is MISSING from .stride.md -> clean no-op (exit 0, no
  # structured after_goal JSON emitted).
  W20C_PROJ="$TMPDIR_TEST/w1612-missing"
  mkdir -p "$W20C_PROJ/.stride"
  cat > "$W20C_PROJ/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```
STRIDE
  printf '%s' '{"data":{"id":99},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G88"}}]}' \
    > "$W20C_PROJ/.stride/.last-api-response.json"
  W20C_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20C_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20C_RC=$?
  assert_exit "20c: missing ## after_goal under truncation exits 0" 0 "$W20C_RC"
  if echo "$W20C_OUT" | grep -qF '"hook": "after_goal"'; then
    echo -e "  ${RED}FAIL${RESET}: 20c: emitted after_goal JSON despite a missing section"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20c: missing ## after_goal is a clean no-op under truncation"
    PASS=$((PASS + 1))
  fi

  # 20d: no-file control — truncated stdout, NO canonical file, and no reachable
  # after_goal_status endpoint -> the section must NOT run (no false positive).
  W20D_PROJ="$TMPDIR_TEST/w1612-nofile"
  mkdir -p "$W20D_PROJ"
  cat > "$W20D_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal_ran"
```
STRIDE
  printf "TASK_ID='99'\n" > "$W20D_PROJ/.stride-env-cache"
  W20D_INPUT='{"tool_input":{"command":"curl -X PATCH http://localhost:19099/api/tasks/99/complete -H \"Authorization: Bearer tok\""},"tool_response":{"stdout":"{\"data\":{\"id\":99},\"hoo"}}'
  W20D_OUT=$(echo "$W20D_INPUT" | CLAUDE_PROJECT_DIR="$W20D_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20D_RC=$?
  assert_exit "20d: no-file + truncated + unreachable exits 0" 0 "$W20D_RC"
  if echo "$W20D_OUT" | grep -qF "after_goal_ran"; then
    echo -e "  ${RED}FAIL${RESET}: 20d: false-positive after_goal run with no file and no endpoint"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20d: no file + no endpoint does not run ## after_goal (no false positive)"
    PASS=$((PASS + 1))
  fi

  # 20e: W2087 — slim completion ack (?response_view=slim): the canonical file
  # holds ONLY the 9-field ack + hooks[] (no workflow_steps/reviewer_result/
  # completion_notes) -> after_goal detection and GOAL_* export still work.
  W20E_PROJ="$TMPDIR_TEST/w2087-slimack"
  mkdir -p "$W20E_PROJ/.stride"
  cat > "$W20E_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER] title=[$GOAL_TITLE]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"identifier":"W99","title":"Slim task","status":"done","parent_id":55,"needs_review":false,"review_status":null,"complexity":"medium","priority":"high"},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55","GOAL_TITLE":"Goal 55"}}]}' \
    > "$W20E_PROJ/.stride/.last-api-response.json"
  W20E_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20E_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20E_RC=$?
  assert_exit "20e: slim ack with after_goal exits 0" 0 "$W20E_RC"
  assert_contains "20e: ## after_goal ran off the slim ack" "ident=[G55]" "$W20E_OUT"
  assert_contains "20e: GOAL_TITLE exported from the slim ack" "title=[Goal 55]" "$W20E_OUT"
  W20E_CACHE=$(cat "$W20E_PROJ/.stride-env-cache" 2>/dev/null)
  assert_contains "20e: env cache carries GOAL_ID off the slim ack" "GOAL_ID='55'" "$W20E_CACHE"

  # 20f: negative control — slim ack whose hooks[] has NO after_goal entry ->
  # the section must NOT run (no false positive off the slimmer body).
  W20F_PROJ="$TMPDIR_TEST/w2087-slimneg"
  mkdir -p "$W20F_PROJ/.stride"
  cat > "$W20F_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "slim_after_goal_ran"
```
STRIDE
  printf '%s' '{"data":{"id":99,"identifier":"W99","title":"Slim task","status":"done","parent_id":55,"needs_review":false,"review_status":null,"complexity":"medium","priority":"high"},"hooks":[{"name":"before_review"}]}' \
    > "$W20F_PROJ/.stride/.last-api-response.json"
  W20F_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20F_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20F_RC=$?
  assert_exit "20f: slim ack without after_goal exits 0" 0 "$W20F_RC"
  if echo "$W20F_OUT" | grep -qF "slim_after_goal_ran"; then
    echo -e "  ${RED}FAIL${RESET}: 20f: ran ## after_goal despite no after_goal entry in the slim ack"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20f: slim ack without after_goal does not run the section"
    PASS=$((PASS + 1))
  fi

  # 20g: D245 — after_goal env OMITS GOAL_ID and data.parent_id is set (exactly
  # the population the fallback exists for): the env cache must carry exactly
  # ONE GOAL_ID line and it must hold the parent_id value. Before the fix the
  # defined-but-empty export loop appended GOAL_ID='' and the fallback appended
  # GOAL_ID='6' — a first-match reader (grep -m1) got '' while a sourcing
  # reader got 6.
  W20G_PROJ="$TMPDIR_TEST/d245-onegoalid"
  mkdir -p "$W20G_PROJ/.stride"
  cat > "$W20G_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"identifier":"W99","title":"Slim task","status":"done","parent_id":6,"needs_review":false,"review_status":null,"complexity":"medium","priority":"high"},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G6"}}]}' \
    > "$W20G_PROJ/.stride/.last-api-response.json"
  W20G_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20G_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20G_RC=$?
  assert_exit "20g: fallback-firing slim ack exits 0" 0 "$W20G_RC"
  assert_contains "20g: ## after_goal still receives the fallback GOAL_ID" "goal=[6]" "$W20G_OUT"
  W20G_COUNT=$(grep -c '^GOAL_ID=' "$W20G_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')
  assert_eq "20g: env cache carries exactly one GOAL_ID line when the fallback fires" "1" "$W20G_COUNT"
  W20G_FIRST=$(grep -m1 '^GOAL_ID=' "$W20G_PROJ/.stride-env-cache" 2>/dev/null)
  assert_eq "20g: a first-match reader gets the parent_id value" "GOAL_ID='6'" "$W20G_FIRST"

  # 20h: normal-path control for D245 — after_goal env WITH GOAL_ID: still
  # exactly one GOAL_ID line, and it holds the server-supplied value (the
  # replace-in-place fallback never fires, no regression on the normal path).
  W20H_PROJ="$TMPDIR_TEST/d245-normalpath"
  mkdir -p "$W20H_PROJ/.stride"
  cat > "$W20H_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55"}}]}' \
    > "$W20H_PROJ/.stride/.last-api-response.json"
  W20H_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20H_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W20H_RC=$?
  assert_exit "20h: supplied-GOAL_ID slim path exits 0" 0 "$W20H_RC"
  assert_contains "20h: ## after_goal receives the supplied GOAL_ID" "goal=[55]" "$W20H_OUT"
  W20H_COUNT=$(grep -c '^GOAL_ID=' "$W20H_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')
  assert_eq "20h: env cache still carries exactly one GOAL_ID line on the normal path" "1" "$W20H_COUNT"
  W20H_FIRST=$(grep -m1 '^GOAL_ID=' "$W20H_PROJ/.stride-env-cache" 2>/dev/null)
  assert_eq "20h: a first-match reader gets the supplied value" "GOAL_ID='55'" "$W20H_FIRST"

  # 20i (D257): D245 fixed ONE geometry. Its replace-in-place lived inside the
  # parent-id fallback, so it ran only when that fallback fired — and
  # apply_env_lines APPENDED on every call (D260 later made it replace in
  # place; this is the geometry as it was). A second after_goal run in the same
  # claim window (no claim between, so nothing truncates the cache) whose
  # response omits BOTH the GOAL_ID env key and data.parent_id therefore had
  # the defaults loop append GOAL_ID='' AFTER run 1's real value, with no
  # fallback to clean it up: grep -m1 read the PREVIOUS goal's id while
  # sourcing read ''. That is the exact D245 symptom, one response shape away
  # from the population D245 fixed.
  #
  # The decided value resolves the drafted check's open product-intent
  # question: a single GOAL_ID='' line, NOT the removal of the key. The
  # contract (hook-execution.md) is that a key the server omits exports
  # defined-but-empty, never absent, so a `set -u` section can reference it —
  # dropping the line would reintroduce the absent state that contract forbids.
  # Keeping run 1's '7' would be worse still: it is the stale-identity bug.
  W20I_PROJ="$TMPDIR_TEST/d257-resurrect"
  mkdir -p "$W20I_PROJ/.stride"
  cat > "$W20I_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
STRIDE
  # Run 1: fallback fires, GOAL_ID='7'
  printf '%s' '{"data":{"id":99,"parent_id":7},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G7"}}]}' \
    > "$W20I_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20I_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "20i: run 1 leaves one GOAL_ID line" "1" \
    "$(grep -c '^GOAL_ID=' "$W20I_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"
  # Run 2 (no claim between): GOAL_ID env omitted AND no parent_id
  printf '%s' '{"data":{"id":100},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G8"}}]}' \
    > "$W20I_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20I_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  W20I_COUNT=$(grep -c '^GOAL_ID=' "$W20I_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')
  assert_eq "20i (D257): exactly one GOAL_ID line after a second in-window after_goal" "1" "$W20I_COUNT"
  W20I_FIRST=$(grep -m1 '^GOAL_ID=' "$W20I_PROJ/.stride-env-cache" 2>/dev/null)
  W20I_SOURCED=$(bash -c ". '$W20I_PROJ/.stride-env-cache' 2>/dev/null; printf 'GOAL_ID=%s' \"\$(printf \"'%s'\" \"\$GOAL_ID\")\"")
  assert_eq "20i (D257): first-match and sourcing readers agree" "$W20I_SOURCED" "$W20I_FIRST"
  assert_eq "20i (D257): the surviving line is the contract's defined-but-empty value, not the previous goal's id" \
    "GOAL_ID=''" "$W20I_FIRST"

  # 20j (D257): the three siblings never had a replace-in-place at all — only
  # GOAL_ID did, and only via the fallback — so two in-window runs accumulated
  # contradictory pairs. A first-match reader then stitched run 2's GOAL_ID to
  # run 1's GOAL_IDENTIFIER: two different goals reconstructed as one identity.
  # That is the harm that matters, because a commit message, PR body or
  # notification built from those fields names the wrong goal. Run 1 supplies a
  # full identity for goal 6; run 2 supplies only GOAL_IDENTIFIER=G7 and
  # parent_id=7, so GOAL_TITLE must NOT keep goal 6's title.
  W20J_PROJ="$TMPDIR_TEST/d257-siblings"
  mkdir -p "$W20J_PROJ/.stride"
  cat > "$W20J_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":6},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"6","GOAL_IDENTIFIER":"G6","GOAL_TITLE":"Alpha Goal"}}]}' \
    > "$W20J_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20J_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  printf '%s' '{"data":{"id":100,"parent_id":7},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G7"}}]}' \
    > "$W20J_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20J_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  for _k in GOAL_ID GOAL_IDENTIFIER GOAL_TITLE GOAL_DESCRIPTION; do
    _c=$(grep -c "^${_k}=" "$W20J_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')
    assert_eq "20j (D257): exactly one ${_k} line after two in-window after_goal runs" "1" "$_c"
  done
  # Identity consistency for first-match readers: id and identifier must belong
  # to the SAME goal (the second run's: 7 / G7).
  assert_eq "20j (D257): first-match GOAL_ID is the current goal's" "GOAL_ID='7'" \
    "$(grep -m1 '^GOAL_ID=' "$W20J_PROJ/.stride-env-cache" 2>/dev/null)"
  assert_eq "20j (D257): first-match GOAL_IDENTIFIER is the current goal's" "GOAL_IDENTIFIER='G7'" \
    "$(grep -m1 '^GOAL_IDENTIFIER=' "$W20J_PROJ/.stride-env-cache" 2>/dev/null)"
  # The sibling run 1 supplied and run 2 did not: it must NOT survive as goal
  # 6's title beside goal 7's id, which is the stitched-identity failure.
  assert_eq "20j (D257): a sibling the current run omitted does not keep the previous goal's value" \
    "GOAL_TITLE=''" "$(grep -m1 '^GOAL_TITLE=' "$W20J_PROJ/.stride-env-cache" 2>/dev/null)"

  # 20k (D257): the goal-switch edge the strategy names — run 2 supplies a
  # DIFFERENT explicit GOAL_ID. The fallback never fires (GOAL_ID is non-empty),
  # so this is the geometry the D245 guard structurally could not reach.
  W20K_PROJ="$TMPDIR_TEST/d257-switch"
  mkdir -p "$W20K_PROJ/.stride"
  cat > "$W20K_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID]"
```
STRIDE
  printf '%s' '{"data":{"id":99},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"6","GOAL_IDENTIFIER":"G6"}}]}' \
    > "$W20K_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20K_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  printf '%s' '{"data":{"id":100},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"7","GOAL_IDENTIFIER":"G7"}}]}' \
    > "$W20K_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20K_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "20k (D257): a mid-window goal switch leaves one GOAL_ID line" "1" \
    "$(grep -c '^GOAL_ID=' "$W20K_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"
  assert_eq "20k (D257): and it holds the SECOND run's goal, preserving last-wins" "GOAL_ID='7'" \
    "$(grep -m1 '^GOAL_ID=' "$W20K_PROJ/.stride-env-cache" 2>/dev/null)"

  # 20l (D257): scope guard. The collapse is for the four GOAL_* keys only —
  # every other key on the same after_goal env is left to apply_env_lines,
  # here and for every other hook. A regression that widened the filter would
  # silently change unrelated hooks' env handling.
  W20L_PROJ="$TMPDIR_TEST/d257-scope"
  mkdir -p "$W20L_PROJ/.stride"
  printf '## after_goal\n```bash\ntrue\n```\n' > "$W20L_PROJ/.stride.md"
  printf '%s' '{"data":{"id":99,"parent_id":9},"hooks":[{"name":"after_goal","env":{"BOARD_NAME":"Stride Development","GOAL_IDENTIFIER":"G9"}}]}' \
    > "$W20L_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20L_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_contains "20l (D257): a non-GOAL key on the same after_goal env still reaches the cache" \
    "BOARD_NAME=" "$(cat "$W20L_PROJ/.stride-env-cache" 2>/dev/null)"
  assert_eq "20l (D257): and the GOAL_* collapse still applied on that same run" "1" \
    "$(grep -c '^GOAL_IDENTIFIER=' "$W20L_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"

  # 20m (D257): the collapse must find record boundaries by QUOTING STATE, not
  # by line shape. 10l pins the single-run case; this is the multi-run one the
  # collapse actually operates on. Run 1 supplies a multi-line GOAL_TITLE whose
  # value contains a line reading `GOAL_ID=999` — a decoy that a plain
  # `grep -v '^GOAL_ID='` would delete from the MIDDLE of the value, corrupting
  # it, which is precisely why apply_env_lines appended rather than rewriting
  # (D260 rewrites now, quote-aware, for exactly this reason) and why D245's
  # line-based idiom could not simply be extended to all four keys.
  # Run 2 then re-supplies a single-line title, so the whole multi-line record
  # must be removed as one unit — not partially, and not left behind.
  W20M_PROJ="$TMPDIR_TEST/d257-multiline"
  mkdir -p "$W20M_PROJ/.stride"
  cat > "$W20M_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "gt=[$GOAL_TITLE]"
```
STRIDE
  W20M_TITLE="first
GOAL_ID=999
last"
  jq -nc --arg t "$W20M_TITLE" '{data:{id:99,parent_id:6},hooks:[{name:"after_goal",env:{GOAL_ID:"6",GOAL_TITLE:$t}}]}' \
    > "$W20M_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20M_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  W20M_T1=$(set -a; . "$W20M_PROJ/.stride-env-cache" 2>/dev/null; set +a; printf '%s' "${GOAL_TITLE:-}")
  assert_contains "20m (D257): run 1's multi-line title round-trips through the collapse" "last" "$W20M_T1"
  # NOTE the oracle here, deliberately: a raw `grep -c '^GOAL_ID='` returns 2 on
  # this fixture and that is CORRECT — the second hit is the decoy line inside
  # GOAL_TITLE's value, which is data, not a record. So the acceptance
  # criterion's "exactly one line per GOAL_* key" cannot be measured by counting
  # lines once any value may contain a decoy; the invariant that actually
  # matters, and the one D245 stated, is that a first-match reader and a
  # sourcing reader AGREE. 20i/20j count lines because their values contain no
  # decoy; this case must not, and asserting a count here would pin the wrong
  # property and fail for the right reason.
  W20M_FIRST=$(grep -m1 '^GOAL_ID=' "$W20M_PROJ/.stride-env-cache" 2>/dev/null)
  W20M_SRC=$(set -a; . "$W20M_PROJ/.stride-env-cache" 2>/dev/null; set +a; printf "GOAL_ID='%s'" "${GOAL_ID:-}")
  assert_eq "20m (D257): first-match and sourcing readers agree despite the decoy line" \
    "$W20M_SRC" "$W20M_FIRST"
  assert_eq "20m (D257): and the record a first-match reader finds is the run's, not the decoy" "GOAL_ID='6'" \
    "$W20M_FIRST"
  # Run 2: single-line title — the whole multi-line record must go, as one unit.
  printf '%s' '{"data":{"id":100,"parent_id":7},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"7","GOAL_TITLE":"Beta"}}]}' \
    > "$W20M_PROJ/.stride/.last-api-response.json"
  echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W20M_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  W20M_T2=$(set -a; . "$W20M_PROJ/.stride-env-cache" 2>/dev/null; set +a; printf '%s' "${GOAL_TITLE:-}")
  assert_eq "20m (D257): run 2 replaces the multi-line record wholesale" "Beta" "$W20M_T2"
  assert_eq "20m (D257): no orphan fragment of run 1's value survives" "0" \
    "$(grep -c '^GOAL_ID=999' "$W20M_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"
  assert_eq "20m (D257): still exactly one GOAL_TITLE line" "1" \
    "$(grep -c '^GOAL_TITLE=' "$W20M_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"
fi

# ============================================================
# Test Group 21: D142 — post-pull TASK_BASE_REF + complete snapshot
# ============================================================
# Two production defects, both silent review corruption:
#   D132: TASK_BASE_REF was captured BEFORE the ## before_doing section ran,
#         so the section's `git pull` moved HEAD past it and the after_doing
#         diff spanned another clone's already-completed task.
#   D137: the claim-time dirty-baseline filter (W1457) excluded files whose
#         content had not changed since claim — even after the after_doing
#         auto-commit committed them as the task's own work — silently
#         dropping 4 tracked edits and an untracked migration.
echo ""
echo "=== Test Group 21: D142 post-pull TASK_BASE_REF + complete snapshot ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 21 requires both (reuses Group 8 helpers)"
else
  # Shared fixture: a bare origin and two clones. Clone A is the task machine;
  # clone B plays the OTHER computer whose completed task arrives via the
  # ## before_doing pull on clone A.
  D142_ROOT=$(mktemp -d)
  git init -q --bare "$D142_ROOT/origin.git"
  # Point the bare HEAD at main so both clones check out the same branch
  # regardless of the host's init.defaultBranch.
  git -C "$D142_ROOT/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$D142_ROOT/origin.git" "$D142_ROOT/cloneA" 2> /dev/null
  (
    cd "$D142_ROOT/cloneA" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git checkout -q -b main 2> /dev/null || git checkout -q main
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
curl-call.txt
*.ref
GITIGNORE
    echo "base" > base.txt
    git add .gitignore base.txt > /dev/null
    git commit -q -m "base"
    git push -q origin main 2> /dev/null
  )
  git clone -q "$D142_ROOT/origin.git" "$D142_ROOT/cloneB" 2> /dev/null
  (
    cd "$D142_ROOT/cloneB" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "w1678" > w1678.txt
    git add w1678.txt > /dev/null
    git commit -q -m "other clone's task"
    git push -q origin main 2> /dev/null
  )

  # 21a: the claim-time refresh must record the POST-pull branch point, even
  # when the cache already holds a stale base from a previous task/session.
  (
    cd "$D142_ROOT/cloneA" || exit 1
    cat > .stride.md << 'STRIDE'
## before_doing
```bash
git pull -q origin main
```

## after_doing
```bash
git add -A
git commit -q -m "task commit"
```
STRIDE
    # Stale cache from a "previous session" — must be fully replaced.
    printf "TASK_ID='OLD1'\nTASK_BASE_REF='1111111111111111111111111111111111111111'\n" > .stride-env-cache
    git rev-parse HEAD > prepull.ref
    D142_CLAIM='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":142,\"identifier\":\"D142\",\"title\":\"Cross clone\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false}}'
    echo "$D142_CLAIM" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  D142_PREPULL=$(cat "$D142_ROOT/cloneA/prepull.ref")
  D142_HEAD=$(git -C "$D142_ROOT/cloneA" rev-parse HEAD)
  D142_CACHE=$(cat "$D142_ROOT/cloneA/.stride-env-cache" 2>/dev/null)
  if [ "$D142_PREPULL" = "$D142_HEAD" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21a fixture vacuous — the before_doing pull did not move HEAD"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21a fixture: the before_doing pull moved HEAD (discriminating power)"
    PASS=$((PASS + 1))
  fi
  assert_contains "21a: claim records the POST-pull branch point as TASK_BASE_REF" \
    "TASK_BASE_REF='$D142_HEAD'" "$D142_CACHE"
  if echo "$D142_CACHE" | grep -q "1111111111111111111111111111111111111111"; then
    echo -e "  ${RED}FAIL${RESET}: 21a: the stale prior-session TASK_BASE_REF survived the claim"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21a: the stale prior-session TASK_BASE_REF was replaced"
    PASS=$((PASS + 1))
  fi

  # 21b: completing the task on clone A captures ONLY the task's own files —
  # never the commit pulled from clone B (the D132/W1678 cross-task scenario).
  D142_STUB=$(mktemp -d)
  D142_FIXTURE="$D142_ROOT/cloneA/curl-call.txt"
  make_curl_stub "$D142_STUB" "$D142_FIXTURE" 0
  (
    cd "$D142_ROOT/cloneA" || exit 1
    echo "task work" > task.txt
    D142_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/142/complete -H \"Authorization: Bearer tok\""}}'
    echo "$D142_COMPLETE" | CLAUDE_PROJECT_DIR="$PWD" PATH="$D142_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  D142_PATHS=$(jq -r '.[].path' "$D142_ROOT/cloneA/.stride-changed-files.json" 2>/dev/null)
  assert_contains "21b: snapshot contains the task's own file" "task.txt" "$D142_PATHS"
  if echo "$D142_PATHS" | grep -qx "w1678.txt"; then
    echo -e "  ${RED}FAIL${RESET}: 21b: the other clone's pulled file leaked into the snapshot"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21b: the other clone's pulled file is NOT in the snapshot"
    PASS=$((PASS + 1))
  fi

  # 21c: resolve_snapshot_base — the staleness guard. cloneA's history is now
  # base → w1678 (pulled) → task commit, with origin/main at w1678: the task
  # branch point (merge-base of HEAD and origin/main) is the w1678 commit.
  D142_BP=$(git -C "$D142_ROOT/cloneA" merge-base HEAD origin/main)
  D142_ERR_FILE=$(mktemp)
  D142_RES=$(
    cd "$D142_ROOT/cloneA" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "$D142_PREPULL" 2> "$D142_ERR_FILE"
  )
  assert_eq "21c: a base older than the branch point recomputes to the branch point" \
    "$D142_BP" "$D142_RES"
  assert_contains "21c: the recompute says so in its output" \
    "recomputed" "$(cat "$D142_ERR_FILE" 2>/dev/null)"
  D142_RES_OK=$(
    cd "$D142_ROOT/cloneA" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "$D142_BP" 2> "$D142_ERR_FILE.trusted"
  )
  assert_eq "21c: a base equal to the branch point is trusted unchanged" \
    "$D142_BP" "$D142_RES_OK"
  assert_eq "21c: a trusted base emits no recompute notice" \
    "" "$(cat "$D142_ERR_FILE.trusted" 2>/dev/null)"
  D142_RES_BAD=$(
    cd "$D142_ROOT/cloneA" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null
  )
  assert_eq "21c: an unresolvable base recomputes to the branch point" \
    "$D142_BP" "$D142_RES_BAD"
  rm -f "$D142_ERR_FILE" "$D142_ERR_FILE.trusted"

  # 21c2: a repo with NO origin has no branch point to recompute from — the
  # guard must pass the base through unchanged (no cross-clone pull is
  # possible without a remote, so the D132 scenario cannot occur there).
  D142_LOCAL=$(mktemp -d)
  (
    cd "$D142_LOCAL" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "x" > x.txt
    git add x.txt > /dev/null
    git commit -q -m x
  )
  D142_RES_LOCAL=$(
    cd "$D142_LOCAL" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null
  )
  assert_eq "21c2: no origin — the base passes through unchanged" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$D142_RES_LOCAL"
  rm -rf "$D142_LOCAL"
  rm -rf "$D142_ROOT" "$D142_STUB"

  # 21d: D137 dropped-files repro — files already dirty/untracked at claim
  # time that the after_doing auto-commit then COMMITS are the task's own
  # work and must survive the dirty-baseline filter.
  D137_DIR=$(mktemp -d)
  (
    cd "$D137_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
base.ref
snap.json
.stride-dirty-baseline
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    printf 'v1\n' > lib_a.txt
    printf 'v1\n' > lib_b.txt
    git add . > /dev/null
    git commit -q -m "base"
    git rev-parse HEAD > base.ref
    # The D137 shape: task work already present when the claim lands.
    printf 'v2\n' > lib_a.txt
    printf 'v2\n' > lib_b.txt
    printf 'defmodule Migration do end\n' > migration.exs
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    HAS_JQ=true
    record_dirty_baseline "$(cat base.ref)"
    # The after_doing auto-commit commits ALL of it as the task's work.
    git add -A > /dev/null
    git commit -q -m "task"
    capture_changed_files "$(cat base.ref)" > snap.json 2>/dev/null
  )
  D137_PATHS=$(jq -r '.[].path' "$D137_DIR/snap.json" 2>/dev/null)
  assert_contains "21d: committed tracked edit survives the baseline filter (a)" "lib_a.txt" "$D137_PATHS"
  assert_contains "21d: committed tracked edit survives the baseline filter (b)" "lib_b.txt" "$D137_PATHS"
  assert_contains "21d: committed formerly-untracked migration is included" "migration.exs" "$D137_PATHS"

  # 21e: snapshot/commit parity — the uploaded file list equals the task
  # commit's file list exactly in the normal flow.
  D137_COMMIT_FILES=$(git -C "$D137_DIR" diff --name-only "$(cat "$D137_DIR/base.ref")" HEAD | sort)
  D137_SNAP_FILES=$(printf '%s\n' "$D137_PATHS" | sort)
  assert_eq "21e: snapshot file list equals the commit file list" \
    "$D137_COMMIT_FILES" "$D137_SNAP_FILES"
  rm -rf "$D137_DIR"

  # 21g: an ## after_doing section that PUSHES the default branch must not
  # trick the refresh capture into recomputing the (correct) base — the push
  # moves origin/main to HEAD before the post-command refresh, which would
  # make the base a strict ancestor of the new branch point and empty the
  # snapshot. The guard's judgment is resolved once at the pre-command early
  # capture and memoized (reviewer regression on the first D142 cut).
  D142_PUSH=$(mktemp -d)
  git init -q --bare "$D142_PUSH/origin.git"
  git -C "$D142_PUSH/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$D142_PUSH/origin.git" "$D142_PUSH/work" 2> /dev/null
  D142_PUSH_STUB=$(mktemp -d)
  D142_PUSH_FIXTURE="$D142_PUSH/work/curl-call.txt"
  make_curl_stub "$D142_PUSH_STUB" "$D142_PUSH_FIXTURE" 0
  (
    cd "$D142_PUSH/work" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git checkout -q -b main 2> /dev/null || git checkout -q main
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
curl-call.txt
*.ref
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
    git push -q origin main 2> /dev/null
    git rev-parse HEAD > base.ref
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "task work"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
git push -q origin main
```
STRIDE
    printf "TASK_ID='55'\nTASK_BASE_REF='%s'\n" "$(cat base.ref)" > .stride-env-cache
    D142_PUSH_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/55/complete -H \"Authorization: Bearer tok\""}}'
    echo "$D142_PUSH_COMPLETE" | CLAUDE_PROJECT_DIR="$PWD" PATH="$D142_PUSH_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  D142_PUSH_BASE=$(cat "$D142_PUSH/work/base.ref")
  D142_PUSH_PATHS=$(jq -r '.[].path' "$D142_PUSH/work/.stride-changed-files.json" 2>/dev/null)
  assert_contains "21g: push-in-after_doing keeps the task's file in the snapshot" \
    "tracked.txt" "$D142_PUSH_PATHS"
  assert_contains "21g: the resolved base is persisted for the self-heal" \
    "base=$D142_PUSH_BASE" "$(cat "$D142_PUSH/work/.stride-diff-upload-state" 2>/dev/null)"
  rm -rf "$D142_PUSH" "$D142_PUSH_STUB"

  # 21h: a workflow that pushes its own task commits BEFORE completing
  # (origin/main == HEAD at capture time) must not have its correct,
  # claim-written base recomputed — the TASK_BASE_REF_TRUSTED marker written
  # by finalize_before_doing exempts the base from the branch-point rule.
  D142_PRE=$(mktemp -d)
  git init -q --bare "$D142_PRE/origin.git"
  git -C "$D142_PRE/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$D142_PRE/origin.git" "$D142_PRE/work" 2> /dev/null
  D142_PRE_STUB=$(mktemp -d)
  D142_PRE_FIXTURE="$D142_PRE/work/curl-call.txt"
  make_curl_stub "$D142_PRE_STUB" "$D142_PRE_FIXTURE" 0
  (
    cd "$D142_PRE/work" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git checkout -q -b main 2> /dev/null || git checkout -q main
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
curl-call.txt
*.ref
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
    git push -q origin main 2> /dev/null
    git rev-parse HEAD > base.ref
    # Task commits made AND pushed before /complete runs.
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "task work"
    git push -q origin main 2> /dev/null
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "gate ran"
```
STRIDE
    printf "TASK_ID='56'\nTASK_BASE_REF='%s'\nTASK_BASE_REF_TRUSTED='1'\n" "$(cat base.ref)" > .stride-env-cache
    D142_PRE_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/56/complete -H \"Authorization: Bearer tok\""}}'
    echo "$D142_PRE_COMPLETE" | CLAUDE_PROJECT_DIR="$PWD" PATH="$D142_PRE_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  D142_PRE_PATHS=$(jq -r '.[].path' "$D142_PRE/work/.stride-changed-files.json" 2>/dev/null)
  assert_contains "21h: pre-pushed task work stays in the snapshot (trusted base not re-judged)" \
    "tracked.txt" "$D142_PRE_PATHS"
  rm -rf "$D142_PRE" "$D142_PRE_STUB"

  # 21f: finalize_before_doing works WITHOUT jq — a stale inherited base is
  # rewritten to HEAD and identity lines survive (the old claim refresh was
  # entirely jq-gated, so a no-jq environment kept the stale base forever).
  D142_NOJQ=$(mktemp -d)
  (
    cd "$D142_NOJQ" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > a.txt
    git add a.txt > /dev/null
    git commit -q -m "v1"
    printf "TASK_ID='7'\nTASK_BASE_REF='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'\n" > .stride-env-cache
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    ENV_CACHE="$PWD/.stride-env-cache"
    HAS_JQ=false
    HOOK_NAME=before_doing
    finalize_before_doing
  )
  D142_NOJQ_HEAD=$(git -C "$D142_NOJQ" rev-parse HEAD)
  D142_NOJQ_CACHE=$(cat "$D142_NOJQ/.stride-env-cache" 2>/dev/null)
  assert_contains "21f: no-jq claim rewrites the stale base to HEAD" \
    "TASK_BASE_REF='$D142_NOJQ_HEAD'" "$D142_NOJQ_CACHE"
  assert_contains "21f: identity lines survive the rewrite" "TASK_ID='7'" "$D142_NOJQ_CACHE"
  if echo "$D142_NOJQ_CACHE" | grep -q "deadbeef"; then
    echo -e "  ${RED}FAIL${RESET}: 21f: the stale base survived the no-jq rewrite"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21f: the stale base did not survive the no-jq rewrite"
    PASS=$((PASS + 1))
  fi
  rm -rf "$D142_NOJQ"
fi

# ============================================================
# D126 reproduction — hidden-stdout claim leaves TASK_ID stale in the env cache
# ============================================================
# Confirmed root cause behind the empty changed_files (goal G321): the diff
# pipeline depends on the hook seeing the API response on stdout. When the claim
# response is hidden (agent used `-o`, a transformer pipe, or an oversized
# response was truncated with no canonical-file fallback), the `post` hook's
# else-branch refreshes TASK_BASE_REF to HEAD but CANNOT recover the new task's
# identity, so TASK_ID/TASK_IDENTIFIER are left stale (the prior task's). A later
# after_doing capture then PUTs the diff to the PREVIOUS task's id, and the
# current task's changed_files never populates. See
# docs/root-cause-changed-files-empty.md.
#
# The fixture MUST contain a .stride.md, or stride-hook.sh exits at the STRIDE_MD
# guard before the before_doing seeding block runs (making the test vacuous).
# Asserted as a CONTRAST so it has discriminating power: a VISIBLE claim refreshes
# TASK_ID; a HIDDEN claim leaves it stale.
#
# NOTE: this documents the claim-time behavior. D127 does NOT change it — instead
# it makes the after_doing/before_review upload target the task id from the
# /complete URL (see tests 8j/8k), so a stale TASK_ID here no longer routes the
# diff to the wrong task. This assertion therefore stays valid after D127.
d126_claim_env() {  # $1 = hidden|visible ; echoes the resulting TASK_ID= line
  local mode="$1" _d
  _d=$(mktemp -d)
  (
    cd "$_d" || exit 1
    git init -q; git config user.email "test@test.local"; git config user.name "Test"
    echo v1 > a.txt; git add a.txt > /dev/null; git commit -q -m v1
    printf '## before_doing\n```bash\ntrue\n```\n' > .stride.md
    printf "TASK_ID='OLD999'\nTASK_IDENTIFIER='W000'\nTASK_BASE_REF='deadbeef'\n" > .stride-env-cache
    if [ "$mode" = hidden ]; then
      _in='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -o out.json"},"tool_response":{"stdout":"HTTP 201"}}'
    else
      _in='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":5555,\"identifier\":\"D999\",\"title\":\"New\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"high\"}}"}}'
    fi
    echo "$_in" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
    grep '^TASK_ID=' .stride-env-cache
  )
  rm -rf "$_d"
}
D126_VISIBLE=$(d126_claim_env visible)
D126_HIDDEN=$(d126_claim_env hidden)
if [ "$D126_VISIBLE" = "TASK_ID='5555'" ]; then
  echo -e "  ${GREEN}PASS${RESET}: D126 repro control — visible-stdout claim refreshes TASK_ID"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: D126 repro control — visible claim should refresh TASK_ID, got: $D126_VISIBLE"
  FAIL=$((FAIL + 1))
fi
if [ "$D126_HIDDEN" = "TASK_ID='OLD999'" ]; then
  echo -e "  ${GREEN}PASS${RESET}: D126 repro — hidden-stdout claim leaves TASK_ID stale (routes the later diff PUT to the previous task)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: D126 repro — hidden claim should leave TASK_ID stale, got: $D126_HIDDEN"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Test Group 22: D220 command routing (sourced, in isolation)
# ============================================================
echo ""
echo "=== Test Group 22: D220 command routing ==="

# Cheap breadth coverage of the single routing entry point. Each cell is
# "<hook-or-none>/<numeric-task-id>", so one assertion pins both the section
# choice and the id the changed_files upload would target.
ROUTE_OUT=$(
  # shellcheck source=/dev/null
  . "$HOOK_SCRIPT" 2>/dev/null || true
  r() { stride_route_command "$1" "$2"; printf '%s/%s|' "${STRIDE_ROUTE_HOOK:-none}" "${STRIDE_ROUTE_TASK_ID:-}"; }
  r post 'curl -X POST https://x/api/tasks/claim -d {}'
  r pre  'curl -X PATCH https://x/api/tasks/99/complete'
  r post 'curl -X PATCH https://x/api/tasks/99/complete'
  r post 'curl -X PATCH https://x/api/tasks/99/mark_reviewed'
  r post 'echo curl -X PATCH https://x/api/tasks/999999999/complete'
  r post 'curl -s https://x/api/tasks/99/complete'
  r post 'curl -X PUT https://x/api/tasks/42/changed_files -d @diff.json'
  r post 'curl -sSX PATCH "$U/api/tasks/88/complete" -d @p.json'
  r post 'curl -X "$METHOD" "$U/api/tasks/88/complete" -d @p.json'
  r post 'cd /tmp;curl -X POST "$U/api/tasks/claim" -d @p.json'
  r post 'curl -X PUT -d "{\"d\":\"curl -X PATCH https://h/api/tasks/9/complete\"}" "$U/api/tasks/42/changed_files"'
  r pre  'URL="$U/api/tasks/1234/complete"; curl -X PATCH "$URL" -d @p.json'
  r post 'curl -x http://proxy:8080 "$U/api/tasks/5/complete" -d @p.json'
  r post 'CURL -X PATCH https://h/api/tasks/5/complete -d @p.json'
  r post 'curl -X PATCH https://h/api/tasks/5/complete/ -d @p.json'
  # two assignments to one name: which value bash used depends on control flow
  # we do not evaluate, so decline to resolve rather than guess a task id
  r post 'URL=https://h/api/tasks/claim; URL=https://h/api/tasks/9/complete; curl -X POST "$URL" -d @p.json'
  # variable names are case-sensitive, as in bash
  r post 'URL=https://h/api/tasks/9/complete; curl -X PATCH "$url" -d @p.json'
  # a redirect on ANY file descriptor consumes its target; the real URL wins
  r post 'curl -X PATCH -d @p.json 3> /tmp/api/tasks/9/complete https://h/api/tasks/5/complete'
  # the sentinel is order-INDEPENDENT: a non-API value FIRST must still block
  r post 'URL=https://example.com/noop; URL=https://h/api/tasks/9/complete; curl -X PATCH "$URL" -d @p.json'
  # a literal URL is unaffected by sentinel-ed assignments elsewhere
  r post 'URL=https://example.com/a; URL=https://example.com/b; curl -X PATCH https://h/api/tasks/333/complete -d @p.json'
  # bash keeps what a backslash escapes, so the delimiter is E'F, not EF — the
  # curl sits INSIDE the body. $'...' so the \n are real newlines: in a
  # double-quoted string they would be two literal characters, which would make
  # this a single line and the assertion vacuous.
  r post $'cat <<E\\\'F > d.md\nEF\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nE\'F'
  # The MULTI-LINE assignment layouts. The one-line rows above cannot fail:
  # their second assignment puts /api/tasks/ on the same line, so the fast path
  # tokenises it anyway. Here the first assignment's line names no API path.
  r pre $'URL="https://e.com/noop"\nURL="$U/api/tasks/9/complete"\ncurl -X PATCH "$URL" -d @p.json'
  r pre $'if $DRY; then\n  URL="https://e.com/noop"\nelse\n  URL="$U/api/tasks/9/complete"\nfi\ncurl -X PATCH "$URL" -d @p.json'
  # CONTROL: a single assignment across two lines must still route, or the
  # guard above has simply disabled resolution instead of narrowing it.
  r pre $'URL="$U/api/tasks/1234/complete"\ncurl -X PATCH "$URL" -d @p.json'
)
assert_eq "22a: D220 routing table" \
  "before_doing/|after_doing/99|before_review/99|after_review/99|none/|none/|none/|before_review/88|before_review/88|before_doing/|none/|after_doing/1234|before_review/5|none/|before_review/5|none/|none/|before_review/5|none/|before_review/333|none/|none/|none/|after_doing/1234|" \
  "$ROUTE_OUT"

# 22c: the delimiter derivation itself, since a wrong delimiter can end a body
# EARLY and expose the rest of it to the scanner. Each expected value is bash's
# own — verified against bash, not against the implementation.
DELIM_OUT=$(
  # shellcheck source=/dev/null
  . "$HOOK_SCRIPT" 2>/dev/null || true
  d() { _stride_hd_delim "$1"; printf '%s/%s|' "$_HD_D" "$_HD_ANY"; }
  d 'EOF'
  d "'EOF'"
  d "E\\'F"
  d "\"'\""
  d "''"
  d "'A B' rest"
  d 'a\ b rest'
  d '$'"'"'xy'"'"''
  d '"a\bc"'
  d ' ;'
)
assert_eq "22c: heredoc delimiter derivation follows bash" \
  "EOF/1|EOF/1|E'F/1|'/1|/1|A B/1|a b/1|xy/1|a\\bc/1|/0|" \
  "$DELIM_OUT"

# 22d: an ANSI-C delimiter carrying an escape we do not interpret is marked
# UNSAFE, so its body is swallowed to EOF rather than dequeuing on a rendering
# that is not bash's. \' \" \\ are identity escapes and stay safe.
UNSAFE_OUT=$(
  # shellcheck source=/dev/null
  . "$HOOK_SCRIPT" 2>/dev/null || true
  u() { _stride_hd_delim "$1"; printf '%s' "$_HD_UNSAFE"; }
  u '$'"'"'a\nb'"'"''
  u '$'"'"'\x41'"'"''
  u '$'"'"'a\\'"'"'b'"'"''
  u '$'"'"'xy'"'"''
  u "'EOF'"
)
assert_eq "22d: uninterpretable ANSI-C escapes mark the delimiter unsafe" "11000" "$UNSAFE_OUT"

# 22e: end to end — the body of an unsafe-delimiter heredoc is NOT scanned, so
# the completion curl inside it routes nowhere
UNSAFE_E2E=$(
  # shellcheck source=/dev/null
  . "$HOOK_SCRIPT" 2>/dev/null || true
  stride_route_command post $'cat <<$\'a\\nb\' > d.md\nanb\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nanb'
  printf '%s' "${STRIDE_ROUTE_HOOK:-none}"
)
assert_eq "22e: unsafe-delimiter body is not scanned" "none" "$UNSAFE_E2E"

# 22b: task_id_from_command shares the parser, so an id can only come from a URL
# the router accepted — this is what stopped the live PUT to task 999999999.
ID_OUT=$(
  # shellcheck source=/dev/null
  . "$HOOK_SCRIPT" 2>/dev/null || true
  printf '%s|' \
    "$(task_id_from_command 'curl -X PATCH https://x/api/tasks/7777/complete')" \
    "$(task_id_from_command 'echo https://x/api/tasks/999999999/complete')" \
    "$(task_id_from_command 'curl -X PATCH https://x/api/tasks/abc/complete')"
)
assert_eq "22b: task ids come only from accepted request URLs" "7777|||" "$ID_OUT"

# ============================================================
# Test Group 23: D226 — per-task snapshot base isolation
# ============================================================
# A nested claim used to overwrite the shared TASK_BASE_REF, so an outer task
# completed with an inner task's diff anchor. W2066 shipped W2073's two files
# with HTTP 200 and no error. Dispatcher mode makes the nesting routine, so
# these cases guard the normal path, not an exotic one.
echo ""
echo "=== Test Group 23: D226 per-task snapshot base isolation ==="

# Drive a real claim through the hook so the identity rewrite AND
# finalize_before_doing both run — the truncating rewrite is itself one of the
# places the per-task record has to survive.
d226_claim() { # $1 = project dir, $2 = numeric task id
  local _resp _in
  _resp=$(printf '{"data":{"id":%s,"identifier":"W%s","title":"t","status":"in_progress","complexity":"small","priority":"high"}}' "$2" "$2")
  _in=$(jq -nc --arg cmd "curl -X POST https://stride.example.com/api/tasks/claim" --arg out "$_resp" \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}')
  echo "$_in" | CLAUDE_PROJECT_DIR="$1" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
}

d226_fixture() { # $1 = dir
  (
    cd "$1" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
curl-call.txt
GITIGNORE
    printf '## before_doing\n```bash\ntrue\n```\n\n## after_doing\n```bash\ntrue\n```\n' > .stride.md
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
  )
}

# 23a/23b: the defect. Outer claims, does its own work, a NESTED claim lands,
# then the outer task completes. It must diff from ITS OWN base — before this
# fix the nested claim's base won and outer.txt vanished from the snapshot.
D226_DIR=$(mktemp -d)
D226_STUB=$(mktemp -d)
make_curl_stub "$D226_STUB" "$D226_DIR/curl-call.txt" 0
d226_fixture "$D226_DIR"
d226_claim "$D226_DIR" 100
(
  cd "$D226_DIR" || exit 1
  echo "outer" > outer.txt
  git add outer.txt > /dev/null
  git commit -q -m "outer task work"
)
d226_claim "$D226_DIR" 200
D226_CACHE=$(cat "$D226_DIR/.stride-env-cache" 2>/dev/null)
assert_contains "23a: a nested claim preserves the outer task's per-task base record" \
  "TASK_BASE_REF_100=" "$D226_CACHE"
(
  cd "$D226_DIR" || exit 1
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
D226_PATHS=$(jq -r '.[].path' "$D226_DIR/.stride-changed-files.json" 2>/dev/null)
assert_contains "23b: the outer task diffs from its own base after a nested claim" \
  "outer.txt" "$D226_PATHS"
rm -rf "$D226_DIR" "$D226_STUB"

# 23c: fail-closed. No per-task record exists (an older cache), and the shared
# base is stamped as another task's. Refuse rather than upload a foreign diff,
# and say so — silence is the actual defect being fixed.
D226_R=$(mktemp -d)
D226_RSTUB=$(mktemp -d)
make_curl_stub "$D226_RSTUB" "$D226_R/curl-call.txt" 0
d226_fixture "$D226_R"
(
  cd "$D226_R" || exit 1
  echo "foreign" > foreign.txt
  git add foreign.txt > /dev/null
  git commit -q -m "another task's work"
)
D226_R_BASE=$(git -C "$D226_R" rev-parse HEAD~1)
D226_R_OUT=$(
  cd "$D226_R" || exit 1
  printf "TASK_ID='999'\nTASK_BASE_REF='%s'\nTASK_BASE_REF_TRUSTED='1'\nTASK_BASE_REF_OWNER='999'\n" \
    "$D226_R_BASE" > .stride-env-cache
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/300/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_RSTUB:$PATH" bash "$HOOK_SCRIPT" pre 2>&1
)
assert_contains "23c: a base owned by another task is refused, and announced" \
  "REFUSING" "$D226_R_OUT"
assert_eq "23c: the refusal uploads an empty snapshot, never the foreign diff" \
  "[]" "$(jq -c '.' "$D226_R/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D226_R" "$D226_RSTUB"

# 23d: upgrade safety. A cache written BEFORE this fix carries no owner stamp,
# so nothing proves the base is foreign — it must still be used. Refusing on
# absence would break diff capture for every task already in flight.
D226_BC=$(mktemp -d)
D226_BCSTUB=$(mktemp -d)
make_curl_stub "$D226_BCSTUB" "$D226_BC/curl-call.txt" 0
d226_fixture "$D226_BC"
D226_BC_BASE=$(git -C "$D226_BC" rev-parse HEAD)
(
  cd "$D226_BC" || exit 1
  echo "work" > work.txt
  git add work.txt > /dev/null
  git commit -q -m "task work"
  printf "TASK_ID='400'\nTASK_BASE_REF='%s'\nTASK_BASE_REF_TRUSTED='1'\n" "$D226_BC_BASE" > .stride-env-cache
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/400/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_BCSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
D226_BC_PATHS=$(jq -r '.[].path' "$D226_BC/.stride-changed-files.json" 2>/dev/null)
assert_contains "23d: an ownerless legacy base is still used, not refused" \
  "work.txt" "$D226_BC_PATHS"
rm -rf "$D226_BC" "$D226_BCSTUB"

# 23e: the records are per-task, so they must not accumulate forever in a
# long-lived checkout. Seed more than the threshold and confirm the bound
# holds.
#
# (D274) This case used to assert the old COUNT cap (20 carried), which D274
# removed: no count cap can tell a live enclosing outer from an abandoned
# claim, so capping open windows by count evicted the outer. The replacement
# bound is LIVENESS — above the sweep threshold an open window is dropped only
# when it is provably dead, meaning its base does not resolve to a commit at
# all. Every base seeded here is a garbage SHA, so every one of them is
# provably dead and the bound is now 0 rather than 20. That is
# strictly tighter than the cap it replaces, and the companion case below is
# the counterweight that keeps it from being satisfiable by "drop everything":
# the same 25 records with REAL bases must all survive.
D226_CAP=$(mktemp -d)
(
  cd "$D226_CAP" || exit 1
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test"
  echo "v1" > a.txt
  git add a.txt > /dev/null
  git commit -q -m "v1"
  {
    echo "TASK_ID='9001'"
    for i in $(seq 1 25); do echo "TASK_BASE_REF_$i='deadbeef$i'"; done
  } > .stride-env-cache
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2> /dev/null
  PROJECT_DIR="$PWD"
  ENV_CACHE="$PWD/.stride-env-cache"
  HAS_JQ=false
  HOOK_NAME=before_doing
  TASK_ID=9001
  finalize_before_doing
)
D226_CAP_N=$(grep -c '^TASK_BASE_REF_[0-9]' "$D226_CAP/.stride-env-cache" 2>/dev/null)
assert_eq "23e (D274): per-task base records stay bounded — 25 unresolvable bases are all swept" \
  "0" "$D226_CAP_N"
rm -rf "$D226_CAP"

# 23e1 (D274): the counterweight. The same shape with REAL bases — every one a
# resolvable ancestor of HEAD — must keep ALL 25 open windows even though that
# is above the sweep threshold. This is the bound D274 chose, stated as a test:
# growth is bounded by concurrent LIVENESS, never by a count that would have to
# guess which live window to erase.
D274_LIVE=$(mktemp -d)
(
  cd "$D274_LIVE" || exit 1
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test"
  echo "v1" > a.txt
  git add a.txt > /dev/null
  git commit -q -m "v1"
  echo "TASK_ID='9001'" > .stride-env-cache
  for i in $(seq 1 25); do
    echo "r$i" > "r$i.txt"
    git add "r$i.txt" > /dev/null 2>&1
    git commit -q -m "r$i" > /dev/null 2>&1
    echo "TASK_BASE_REF_$i='$(git rev-parse HEAD)'" >> .stride-env-cache
  done
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2> /dev/null
  PROJECT_DIR="$PWD"
  ENV_CACHE="$PWD/.stride-env-cache"
  HAS_JQ=false
  HOOK_NAME=before_doing
  TASK_ID=9001
  finalize_before_doing
)
D274_LIVE_N=$(grep -c '^TASK_BASE_REF_[0-9]' "$D274_LIVE/.stride-env-cache" 2>/dev/null)
assert_eq "23e1 (D274): 25 LIVE open windows above the threshold are all kept" \
  "25" "$D274_LIVE_N"
rm -rf "$D274_LIVE"

# 23e1b (D274): ancestry must NOT be a deletion signal. another_open_window_exists
# treats a base that is not an ancestor of HEAD as unusable and SKIPS it, which
# is recoverable the moment HEAD comes back. Deleting the record is not. A
# detached HEAD — a bisect, or a checkout of an older commit — makes every
# later base a non-ancestor at once, so a sweep that acted on ancestry would,
# on the next claim past the threshold, permanently erase the anchors of tasks
# that are perfectly live: D274's own outcome through a different door. Every
# base here resolves and none is an ancestor of the detached HEAD.
D274_DETACH=$(mktemp -d)
(
  cd "$D274_DETACH" || exit 1
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test"
  echo "v1" > a.txt
  git add a.txt > /dev/null 2>&1
  git commit -q -m "v1" > /dev/null 2>&1
  D274_DETACH_ROOT=$(git rev-parse HEAD)
  echo "TASK_ID='9001'" > .stride-env-cache
  for i in $(seq 1 25); do
    echo "r$i" > "r$i.txt"
    git add "r$i.txt" > /dev/null 2>&1
    git commit -q -m "r$i" > /dev/null 2>&1
    echo "TASK_BASE_REF_$i='$(git rev-parse HEAD)'" >> .stride-env-cache
  done
  git checkout -q "$D274_DETACH_ROOT" > /dev/null 2>&1
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2> /dev/null
  PROJECT_DIR="$PWD"
  ENV_CACHE="$PWD/.stride-env-cache"
  HAS_JQ=false
  HOOK_NAME=before_doing
  TASK_ID=9001
  finalize_before_doing
)
D274_DETACH_N=$(grep -c '^TASK_BASE_REF_[0-9]' "$D274_DETACH/.stride-env-cache" 2>/dev/null)
assert_eq "23e1b (D274): a detached HEAD makes live bases non-ancestors — none may be swept" \
  "25" "$D274_DETACH_N"
rm -rf "$D274_DETACH"

# 23f: the path review found, where the first version of this fix was DEFEATED.
# A nested claim whose response does not parse leaves the PREVIOUS task's
# TASK_ID in place. Stamping ownership from it would overwrite the outer
# task's record with the nested claim's HEAD and then vouch for it — a
# matching owner that never refuses, uploading a purely foreign diff. Only a
# claim that actually parsed its own identity may stamp.
D226_TR=$(mktemp -d)
D226_TRSTUB=$(mktemp -d)
make_curl_stub "$D226_TRSTUB" "$D226_TR/curl-call.txt" 0
d226_fixture "$D226_TR"
d226_claim "$D226_TR" 100
(
  cd "$D226_TR" || exit 1
  echo "outer" > outer.txt
  git add outer.txt > /dev/null
  git commit -q -m "outer task work"
  # A nested claim whose stdout is truncated mid-JSON — the documented
  # oversized-response failure mode, likeliest in dispatcher mode.
  echo '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":200,\"identi"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  echo "nested" > nested.txt
  git add nested.txt > /dev/null
  git commit -q -m "nested task work"
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_TRSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
D226_TR_PATHS=$(jq -r '.[].path' "$D226_TR/.stride-changed-files.json" 2>/dev/null)
assert_contains "23f: an unparsed nested claim cannot poison the outer task's record" \
  "outer.txt" "$D226_TR_PATHS"
rm -rf "$D226_TR" "$D226_TRSTUB"

# 23k: the identity-site cache write FAILS while .stride/ stays writable, so
# the gate correctly passes for the nested task but the cache still holds the
# outer task's TASK_ID. Stamping from the sourced TASK_ID would then overwrite
# the outer's record and vouch for it — the original hole, reached through the
# helper added to make writes safe. The stamp must come from the id the gate
# validated, so the outer's record has to survive untouched.
# Driven directly rather than through a partially-failing filesystem: the
# invariant is that the stamp follows the VALIDATED id, so the test sets the
# two apart (cache says task 100, gate validated 200) and asserts which one
# wins. A filesystem-level repro is not reproducible enough to gate on — make
# the project dir unwritable and BOTH writes fail, which hides the bug rather
# than exposing it.
D226_WF=$(mktemp -d)
(
  cd "$D226_WF" || exit 1
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test"
  echo "v1" > a.txt
  git add a.txt > /dev/null
  git commit -q -m "v1"
  printf "TASK_ID='100'\n" > .stride-env-cache
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2> /dev/null
  PROJECT_DIR="$PWD"
  ENV_CACHE="$PWD/.stride-env-cache"
  HAS_JQ=false
  HOOK_NAME=before_doing
  # The cache (and so TASK_ID) still names the OUTER task, because its write
  # failed; the gate validated the NESTED task's id from this call's payload.
  TASK_ID=100
  TASK_IDENTITY_REFRESHED=1
  TASK_OWNER_ID=200
  finalize_before_doing
)
D226_WF_CACHE=$(cat "$D226_WF/.stride-env-cache" 2>/dev/null)
assert_contains "23k: the owner stamp follows the validated id, not the cached TASK_ID" \
  "TASK_BASE_REF_OWNER='200'" "$D226_WF_CACHE"
assert_eq "23k: no record is written under the stale cached id" \
  "" "$(printf '%s' "$D226_WF_CACHE" | grep -c '^TASK_BASE_REF_100=' | tr -d ' ' | sed 's/^0$//')"
rm -rf "$D226_WF"

# 23l: BOTH claims decline the gate. The outer task then has no record, and a
# declining claim also strips any previous owner stamp — so without the
# unproven marker the absence reads exactly like a legacy cache and the
# foreign base is handed out with nothing to contradict it. The two declines
# share one systematic cause (an oversized claim response), so this is the
# same failure repeating rather than two coincidences.
D226_UP=$(mktemp -d)
D226_UPSTUB=$(mktemp -d)
make_curl_stub "$D226_UPSTUB" "$D226_UP/curl-call.txt" 0
d226_fixture "$D226_UP"
D226_UP_OUT=$(
  cd "$D226_UP" || exit 1
  # Outer claim: truncated response, so the gate declines.
  echo '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":100,\"identi"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  echo "outer" > outer.txt
  git add outer.txt > /dev/null
  git commit -q -m "outer task work"
  # Nested claim: truncated too — same cause, same window.
  echo '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":200,\"identi"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  echo "nested" > nested.txt
  git add nested.txt > /dev/null
  git commit -q -m "nested task work"
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_UPSTUB:$PATH" bash "$HOOK_SCRIPT" pre 2>&1
)
assert_contains "23l: an unprovable base is refused rather than handed out" \
  "REFUSING" "$D226_UP_OUT"
assert_eq "23l: the outer task uploads empty, never the nested task's diff" \
  "[]" "$(jq -c '.' "$D226_UP/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D226_UP" "$D226_UPSTUB"

# 23m: the guard's own inputs must not be suppliable through the hook-env
# channel. D142 fenced TASK_BASE_REF as a client-only anchor; D226 added four
# more keys to that family, and each defeats a different precedence rule — a
# per-task key overrides rule 1, a matching owner neutralizes rule 2, an empty
# UNPROVEN neutralizes rule 3. Fenced by PREFIX so the next key added to the
# family is covered without anyone remembering to add it here.
D226_ENV_OUT=$(
  # shellcheck disable=SC1090
  . "$HOOK_SCRIPT" 2> /dev/null || true
  HAS_JQ=true
  extract_hook_env '{"hooks":[{"name":"before_review","env":{"TASK_BASE_REF_OWNER":"999","TASK_BASE_REF_UNPROVEN":"","TASK_BASE_REF_100":"cafebabe","TASK_BASE_REF_TRUSTED":"1","TASK_BASE_REF":"deadbeef","AGENT_NAME":"ok"}}]}' before_review
)
assert_eq "23m: the whole TASK_BASE_REF family is fenced out of hook env" \
  "AGENT_NAME='ok'" "$D226_ENV_OUT"

# 23m2 (D258): every client-owned record family, in one assertion. 23m pinned
# the TASK_BASE_REF family; the other four were added over D255/D273/D258 and
# nothing pinned them together, so a clause could be dropped from the filter
# and only the family whose own case existed would notice. TASK_HEAD_REF was
# the last one missing, and the sharpest: a head ref says where a task's window
# CLOSES, so a forged one steers the D236/D244 attribution walk. Demonstrated
# end to end — a forged TASK_HEAD_REF_<nested_id> made an outer task's uploaded
# snapshot gain a nested task's file — which 23m3 below drives.
D258_ENV_OUT=$(
  # shellcheck disable=SC1090
  . "$HOOK_SCRIPT" 2> /dev/null || true
  HAS_JQ=true
  extract_hook_env '{"hooks":[{"name":"before_review","env":{"TASK_BASE_REF_100":"x","TASK_HEAD_REF_100":"x","TASK_OWNED_100":"x","TASK_BASE_AT_100":"x","TASK_NARROWED_100":"x","STRIDE_OPEN_WINDOW_MAX_AGE_SECS":"9999999999","HOOK_NAME":"evil","AGENT_NAME":"ok"}}]}' before_review
)
assert_eq "23m2 (D258): all five record families plus STRIDE_ and HOOK_NAME are fenced out of hook env" \
  "AGENT_NAME='ok'" "$D258_ENV_OUT"

# 23m3 (D258): the end-to-end consequence, adapted from the staged /harden
# draft. A genuine head record is seeded, then a /complete response carries a
# contradictory TASK_HEAD_REF_77 for that SAME id, with TASK_BASE_REF and
# TASK_BASE_REF_77 alongside as controls that were already fenced — the
# asymmetry those controls expose is what made the defect visible.
#
# Persistence is the reason this matters more than a one-shot bad read:
# apply_env_lines appended when this was found, so a forged line won on a
# last-match read (under D260 it would DELETE the genuine record instead —
# worse, not better, for any family that escapes the fence);
# record_task_head_ref repairs only the COMPLETING task's own id, so a record
# forged for any other id is never repaired; and select_kept_window_records
# emits every surviving head line with no per-key dedup, so both lines would
# outlive the next claim.
W_HR_PROJ="$TMPDIR_TEST/d258-headref"
mkdir -p "$W_HR_PROJ/.stride"
cat > "$W_HR_PROJ/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```
STRIDE
printf "TASK_HEAD_REF_77='aaaa111genuine'\n" > "$W_HR_PROJ/.stride-env-cache"
printf '%s' '{"data":{"id":78},"hooks":[{"name":"before_review","env":{"TASK_HEAD_REF_77":"ffff999bogus","TASK_BASE_REF":"ffff999bogus","TASK_BASE_REF_77":"ffff999bogus"}}]}' \
  > "$W_HR_PROJ/.stride/.last-api-response.json"
W_HR_INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/78/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":78},\"hoo"}}'
echo "$W_HR_INPUT" | CLAUDE_PROJECT_DIR="$W_HR_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
# (D260 INVERTED WHICH OF THESE IS DECISIVE — measured, by removing the
# TASK_HEAD_REF clause from extract_hook_env's fence and re-running this case.)
#
# When D258 shipped, apply_env_lines APPENDED, so an escaped forged key left
# TWO lines: the count assertion below failed (2, not 1) and first-match still
# returned the genuine line, which is why it was labelled a read-semantics note
# rather than coverage. D260 made apply_env_lines replace in place for the keys
# each call writes, and TASK_HEAD_REF_77 is such a key — so an escaped forged
# key now DELETES the genuine record instead of sitting after it.
#
# Measured with the fence clause removed: the count assertion PASSES (one line
# — the forged one) and first-match FAILS. So the count is no longer decisive
# and first-match now is, the exact reverse of the D258-era reasoning. Both are
# kept: between them they pin the shape under either write path, which is what
# a reader needs when the next change moves it again.
assert_eq "23m3 (D258/D260): exactly one TASK_HEAD_REF_77 line survives a poisoned response env (no longer decisive on its own since D260 collapses to one line either way)" "1" \
  "$(grep -c '^TASK_HEAD_REF_77=' "$W_HR_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"
assert_eq "23m3 (D258/D260): a first-match reader sees the genuine record — decisive since D260, because a forged key would now REPLACE it" \
  "TASK_HEAD_REF_77='aaaa111genuine'" \
  "$(grep -m1 '^TASK_HEAD_REF_77=' "$W_HR_PROJ/.stride-env-cache" 2>/dev/null)"
# And the read that the defect actually turned on: last-match must ALSO be the
# genuine record. Pre-fix this returned the injected value.
assert_eq "23m3 (D258): a LAST-match reader also sees the genuine record — the read the defect turned on" \
  "TASK_HEAD_REF_77='aaaa111genuine'" \
  "$(grep '^TASK_HEAD_REF_77=' "$W_HR_PROJ/.stride-env-cache" 2>/dev/null | tail -n 1)"
if grep -q 'ffff999bogus' "$W_HR_PROJ/.stride-env-cache" 2>/dev/null; then
  echo -e "  ${RED}FAIL${RESET}: 23m3 (D258): an injected record-namespace value reached the cache"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 23m3 (D258): no injected record-namespace value reached the cache at all"
  PASS=$((PASS + 1))
fi

# 23m4 (D258): the OWN-ID edge case the task's testing_strategy names. 23m3
# poisons a record for a task OTHER than the one completing, which is the
# durable case — record_task_head_ref only ever repairs the completing task's
# own id, so another id's forged record is never repaired. The own-id case is
# the one where a later repair WOULD overwrite the injection, and the strategy
# asks that the filter block the write anyway: relying on a later write to
# undo an injection means the forged value is live in the window between them,
# and the repair only happens at all if the completion reaches its capture.
# The filter is prefix-based and id-blind, so this cannot regress
# independently — but the declared coverage is delivered rather than assumed.
#
# Also recorded here because nothing else does: extract_hook_env is the SINGLE
# chokepoint for both env paths — export_after_goal_env calls it, and so does
# the routed-hook path — so one clause covers the after_goal case the strategy
# lists as its second edge case. The ps1 8k2 mirror drives after_goal directly.
W_HR2_PROJ="$TMPDIR_TEST/d258-headref-ownid"
mkdir -p "$W_HR2_PROJ/.stride"
cat > "$W_HR2_PROJ/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```
STRIDE
printf "TASK_HEAD_REF_78='aaaa111genuine'\n" > "$W_HR2_PROJ/.stride-env-cache"
printf '%s' '{"data":{"id":78},"hooks":[{"name":"before_review","env":{"TASK_HEAD_REF_78":"ffff999bogus"}}]}' \
  > "$W_HR2_PROJ/.stride/.last-api-response.json"
echo "$W_HR_INPUT" | CLAUDE_PROJECT_DIR="$W_HR2_PROJ" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
assert_eq "23m4 (D258): an injected record for the COMPLETING task's own id is blocked at the filter too" \
  "TASK_HEAD_REF_78='aaaa111genuine'" \
  "$(grep '^TASK_HEAD_REF_78=' "$W_HR2_PROJ/.stride-env-cache" 2>/dev/null | tail -n 1)"
assert_eq "23m4 (D258): and only one record for that id exists" "1" \
  "$(grep -c '^TASK_HEAD_REF_78=' "$W_HR2_PROJ/.stride-env-cache" 2>/dev/null | tr -d ' ')"

# 23g: the self-heal's refusal branch — an entire code path that had no test.
# before_review runs on a fresh budget and would otherwise re-capture against
# the foreign base, undoing the primary refusal after its notice scrolled by.
D226_SH=$(mktemp -d)
D226_SHSTUB=$(mktemp -d)
make_curl_stub "$D226_SHSTUB" "$D226_SH/curl-call.txt" 0
d226_fixture "$D226_SH"
(
  cd "$D226_SH" || exit 1
  echo "foreign" > foreign.txt
  git add foreign.txt > /dev/null
  git commit -q -m "another task's work"
)
D226_SH_BASE=$(git -C "$D226_SH" rev-parse HEAD~1)
D226_SH_OUT=$(
  cd "$D226_SH" || exit 1
  printf '## before_review\n```bash\ntrue\n```\n' > .stride.md
  # The self-heal resolves credentials BEFORE it captures, and returns early
  # without them — so the refusal branch is unreachable unless the fixture
  # supplies an auth file.
  printf '**API URL:** `https://stride.example.com`\n**API Token:** `tok`\n' > .stride_auth.md
  printf "TASK_ID='999'\nTASK_BASE_REF='%s'\nTASK_BASE_REF_TRUSTED='1'\nTASK_BASE_REF_OWNER='999'\n" \
    "$D226_SH_BASE" > .stride-env-cache
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/300/complete"},"tool_response":{"stdout":"ok"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_SHSTUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1
)
assert_contains "23g: the before_review self-heal refuses a foreign base too" \
  "REFUSING" "$D226_SH_OUT"
assert_eq "23g: the self-heal retry uploads empty, not the foreign diff" \
  "[]" "$(jq -c '.' "$D226_SH/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D226_SH" "$D226_SHSTUB"

# 23h: TWO nested claims in sequence — W2066's actual shape, which the task's
# edge_cases names explicitly. 23a/23b only exercise one.
D226_TWO=$(mktemp -d)
D226_TWOSTUB=$(mktemp -d)
make_curl_stub "$D226_TWOSTUB" "$D226_TWO/curl-call.txt" 0
d226_fixture "$D226_TWO"
d226_claim "$D226_TWO" 100
(
  cd "$D226_TWO" || exit 1
  echo "outer" > outerA.txt
  git add outerA.txt > /dev/null
  git commit -q -m "outer work"
)
d226_claim "$D226_TWO" 200
d226_claim "$D226_TWO" 300
(
  cd "$D226_TWO" || exit 1
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_TWOSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
D226_TWO_PATHS=$(jq -r '.[].path' "$D226_TWO/.stride-changed-files.json" 2>/dev/null)
assert_contains "23h: the outer task survives TWO nested claims in sequence" \
  "outerA.txt" "$D226_TWO_PATHS"
rm -rf "$D226_TWO" "$D226_TWOSTUB"

# 23i: no .stride-env-cache at all — the task's third named edge case. Nothing
# to select from and no owner to contradict, so capture must proceed on the
# existing HEAD~1 fallback rather than refusing or erroring.
D226_NC=$(mktemp -d)
D226_NCSTUB=$(mktemp -d)
make_curl_stub "$D226_NCSTUB" "$D226_NC/curl-call.txt" 0
d226_fixture "$D226_NC"
D226_NC_OUT=$(
  cd "$D226_NC" || exit 1
  echo "work" > work.txt
  git add work.txt > /dev/null
  git commit -q -m "task work"
  rm -f .stride-env-cache
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/500/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_NCSTUB:$PATH" bash "$HOOK_SCRIPT" pre 2>&1
)
assert_eq "23i: a missing env cache does not trigger a refusal" \
  "" "$(printf '%s' "$D226_NC_OUT" | grep -c 'REFUSING' | tr -d ' ' | sed 's/^0$//')"
assert_contains "23i: a missing env cache still captures via the HEAD~1 fallback" \
  "work.txt" "$(jq -r '.[].path' "$D226_NC/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D226_NC" "$D226_NCSTUB"

# 23j: the W2066 replay, promoted from a manual run to an assertion. It used to
# pin BOTH the D226 fix (the outer task gets its own work) and the D236 residual
# (it also over-collected its children's commits). D236 removed the residual, so
# the second half of that assertion FLIPS here — the outer task now gets its own
# work and nothing else.
#
# Note the shape this fixture happens to have: the outer task commits BEFORE the
# nested claim, so its own commits are not a suffix of the range. That is the
# interleaved case, and it is the harder one — a single diff anchor cannot
# express it, which is why attribution is computed as commit RANGES.
D226_W=$(mktemp -d)
D226_WSTUB=$(mktemp -d)
make_curl_stub "$D226_WSTUB" "$D226_W/curl-call.txt" 0
d226_fixture "$D226_W"
d226_claim "$D226_W" 100
(
  cd "$D226_W" || exit 1
  echo x > outerA.txt
  git add outerA.txt > /dev/null
  git commit -q -m outerA
)
d226_claim "$D226_W" 200
(
  cd "$D226_W" || exit 1
  echo x > fileB.txt
  git add fileB.txt > /dev/null
  git commit -q -m fileB
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/200/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_WSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
D226_W_B=$(jq -r '[.[].path] | sort | join(",")' "$D226_W/.stride-changed-files.json" 2>/dev/null)
assert_eq "23j: a nested task captures exactly its own file" "fileB.txt" "$D226_W_B"
(
  cd "$D226_W" || exit 1
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D226_WSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
D226_W_A=$(jq -r '[.[].path] | sort | join(",")' "$D226_W/.stride-changed-files.json" 2>/dev/null)
assert_eq "23j (D236): the outer task gets its own work and NOT its child's" \
  "outerA.txt" "$D226_W_A"
rm -rf "$D226_W" "$D226_WSTUB"

# 23n (D236): the three cases the fix has to get right beyond 23j's shape.
# Built as one fixture because they share a repo and differ only in sequence.
D236_F=$(mktemp -d)
D236_FSTUB=$(mktemp -d)
make_curl_stub "$D236_FSTUB" "$D236_F/curl-call.txt" 0
d226_fixture "$D236_F"
(
  cd "$D236_F" || exit 1
  echo "shared-v1" > shared.txt
  git add shared.txt > /dev/null
  git commit -q -m seed
)
d236_complete() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D236_FSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d236_paths() { jq -r '[.[].path] | sort | join(",")' "$1/.stride-changed-files.json" 2>/dev/null; }

# A claims; B claims, touches a file A will ALSO touch, completes; A commits and
# completes. The nested task's work must not reach A, and the file both touched
# must show A's hunk only.
d226_claim "$D236_F" 100
d226_claim "$D236_F" 200
(
  cd "$D236_F" || exit 1
  echo nestedB > fileB.txt
  echo "shared-B" >> shared.txt
  git add -A > /dev/null
  git commit -q -m fileB
)
d236_complete "$D236_F" 200
assert_eq "23n (D236): the nested task still captures exactly its own work" \
  "fileB.txt,shared.txt" "$(d236_paths "$D236_F")"
(
  cd "$D236_F" || exit 1
  echo "shared-A" >> shared.txt
  echo outerA > outerA.txt
  git add -A > /dev/null
  git commit -q -m outerA
  echo wip > wip.txt
)
d236_complete "$D236_F" 100
assert_eq "23n (D236): the outer task gets its own commits AND its uncommitted work" \
  "outerA.txt,shared.txt,wip.txt" "$(d236_paths "$D236_F")"
# The same-file case the task calls out: subtracting the child's RANGE would
# have erased the parent's own change to shared.txt; attributing COMMITS keeps
# it, and keeps the child's hunk out.
D236_SHARED=$(jq -r '.[] | select(.path=="shared.txt") | .diff' "$D236_F/.stride-changed-files.json" 2>/dev/null)
assert_contains "23n (D236): a file BOTH touched shows the outer task's change" \
  "+shared-A" "$D236_SHARED"
assert_eq "23n (D236): ...and not the nested task's change to that same file" \
  "0" "$(printf '%s' "$D236_SHARED" | grep -c '^+shared-B' | tr -d ' ')"

# An outer task whose own deliverable is in a gitignored subrepo has genuinely
# no outer-repo commits. It must come back EMPTY rather than absorbing its
# child's — the case where "no attributed ranges" must not be read as "no
# attribution applies".
(
  cd "$D236_F" || exit 1
  git add -A > /dev/null
  git commit -q -m settle
)
d226_claim "$D236_F" 700
d226_claim "$D236_F" 800
(
  cd "$D236_F" || exit 1
  echo nestedE > fileE.txt
  git add -A > /dev/null
  git commit -q -m fileE
)
d236_complete "$D236_F" 800
d236_complete "$D236_F" 700
assert_eq "23n (D236): an outer task with no commits of its own captures nothing" \
  "" "$(d236_paths "$D236_F")"

# 23o (D236): the records must survive the NEXT claim. The claim rewrites the
# env cache, and carrying TASK_BASE_REF_* across it but not TASK_HEAD_REF_*
# silently reverts attribution to over-collecting — every claim erases the
# record the previous completion just wrote. No other fixture in this group
# claims a task AFTER a completion, so nothing else can catch it: deleting the
# carry-across line left the suite fully green.
D236_R=$(mktemp -d)
D236_RSTUB=$(mktemp -d)
make_curl_stub "$D236_RSTUB" "$D236_R/curl-call.txt" 0
d226_fixture "$D236_R"
d236_complete_in() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D236_RSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d226_claim "$D236_R" 100
d226_claim "$D236_R" 200
( cd "$D236_R" && echo b > fileB.txt && git add -A > /dev/null && git commit -q -m fileB )
d236_complete_in "$D236_R" 200
# The claim that erased the head record in the first version of this fix.
d226_claim "$D236_R" 300
( cd "$D236_R" && echo c > fileC.txt && git add -A > /dev/null && git commit -q -m fileC )
d236_complete_in "$D236_R" 300
( cd "$D236_R" && echo a > outerA.txt && git add -A > /dev/null && git commit -q -m outerA )
d236_complete_in "$D236_R" 100
assert_eq "23o (D236): head records survive a later claim, so attribution holds" \
  "outerA.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D236_R/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D236_R" "$D236_RSTUB"

# 23p (D236): three levels. Pitfall 2 says nesting depth is unbounded, and every
# other fixture here is exactly two levels deep.
D236_D=$(mktemp -d)
D236_DSTUB=$(mktemp -d)
make_curl_stub "$D236_DSTUB" "$D236_D/curl-call.txt" 0
d226_fixture "$D236_D"
d236_complete_d() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D236_DSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d226_claim "$D236_D" 10   # outermost
d226_claim "$D236_D" 20   # middle
d226_claim "$D236_D" 30   # innermost
( cd "$D236_D" && echo c > deepC.txt && git add -A > /dev/null && git commit -q -m deepC )
d236_complete_d "$D236_D" 30
assert_eq "23p (D236): the innermost task captures only its own file" \
  "deepC.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D236_D/.stride-changed-files.json" 2>/dev/null)"
( cd "$D236_D" && echo b > midB.txt && git add -A > /dev/null && git commit -q -m midB )
d236_complete_d "$D236_D" 20
assert_eq "23p (D236): the middle task excludes the level below it" \
  "midB.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D236_D/.stride-changed-files.json" 2>/dev/null)"
( cd "$D236_D" && echo a > topA.txt && git add -A > /dev/null && git commit -q -m topA )
d236_complete_d "$D236_D" 10
assert_eq "23p (D236): the outermost task excludes BOTH levels below it" \
  "topA.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D236_D/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D236_D" "$D236_DSTUB"

# 23q (D236): the before_review self-heal must narrow too. Attribution was first
# wired only into the base-SELECTION branch, missing the persisted-base branch —
# which is the one actually taken when the primary PUT failed, i.e. exactly when
# the self-heal runs. The retry then re-uploaded the over-collected snapshot
# over the narrowed one, and last write wins on the server.
#
# This fixture is built locally rather than with d226_fixture because the
# self-heal needs BOTH a resolvable API url/token (or the upload is skipped and
# no state file is ever written) and a `## before_review` section. Without those
# the retry path is never entered and the test passes vacuously — which it did,
# until a negative control caught it.
D236_H=$(mktemp -d)
(
  cd "$D236_H" || exit 1
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test"
  printf '.stride*\nstub\n' > .gitignore
  printf '## before_doing\n```bash\ntrue\n```\n\n## after_doing\n```bash\ntrue\n```\n\n## before_review\n```bash\ntrue\n```\n' > .stride.md
  printf '**API URL:** `https://stride.example.com`\n**API Token:** `stride_dev_test`\n' > .stride_auth.md
  echo seed > seed.txt
  git add .gitignore seed.txt > /dev/null
  git commit -q -m seed
  mkdir -p stub
  printf '#!/usr/bin/env bash\necho "500"\nexit 0\n' > stub/curl
  chmod +x stub/curl
)
d236_h_run() { # $1 = task id, $2 = phase
  (
    cd "$D236_H" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$1/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D236_H/stub:$PATH" bash "$HOOK_SCRIPT" "$2" > /dev/null 2>&1
  )
}
d236_h_claim() { # $1 = task id
  (
    cd "$D236_H" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X POST https://stride.example.com/api/tasks/claim\"},\"tool_response\":{\"stdout\":\"{\\\"data\\\":{\\\"id\\\":$1,\\\"identifier\\\":\\\"T$1\\\"}}\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D236_H/stub:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
}
d236_h_claim 100
d236_h_claim 200
( cd "$D236_H" && echo b > fileB.txt && git add -A > /dev/null && git commit -q -m fileB )
d236_h_run 200 pre
( cd "$D236_H" && echo a > outerA.txt && git add -A > /dev/null && git commit -q -m outerA )
d236_h_run 100 pre    # after_doing: the PUT fails (stub returns 500) and state is persisted
d236_h_run 100 post   # before_review: the self-heal retry
assert_eq "23q (D236): the before_review self-heal stays narrowed after a failed PUT" \
  "outerA.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D236_H/.stride-changed-files.json" 2>/dev/null)"
# Guard against the fixture going vacuous again: the retry only means anything
# if the primary PUT actually failed and recorded state for this task.
assert_contains "23q (D236): ...and the fixture really did exercise the retry path" \
  "http_code=500" "$(cat "$D236_H/.stride-diff-upload-state" 2>/dev/null)"
rm -rf "$D236_H"


# 23r (D244, flipping the D236 pin): an outer commit made while a nested task
# is in flight is KEPT by the outer task. The nested window {outer_during,
# nested_b} has two residual commits no other window covers, so it is
# AMBIGUOUS: attribution subtracts nothing from it and the whole span falls
# through into the outer snapshot. Over-reporting — nested_b.txt appearing in
# the outer snapshot too — is the accepted cost; the pre-D244 behaviour LOST
# outer_during.txt from every snapshot, which is the losing-work direction
# D244 exists to close. The nested task still absorbing outer_during into ITS
# snapshot is the other half, re-filed as D255 (needs hook-mediated commit
# ownership).
D236_L=$(mktemp -d)
D236_LSTUB=$(mktemp -d)
make_curl_stub "$D236_LSTUB" "$D236_L/curl-call.txt" 0
d226_fixture "$D236_L"
d236_complete_l() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D236_LSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d226_claim "$D236_L" 100
d226_claim "$D236_L" 200
( cd "$D236_L" && echo during > outer_during.txt && git add -A > /dev/null && git commit -q -m outer_during )
( cd "$D236_L" && echo b > nested_b.txt && git add -A > /dev/null && git commit -q -m nested_b )
d236_complete_l "$D236_L" 200
( cd "$D236_L" && echo after > outer_after.txt && git add -A > /dev/null && git commit -q -m outer_after )
d236_complete_l "$D236_L" 100
assert_eq "23r (D244): an outer commit made mid-window stays in the outer task's snapshot" \
  "nested_b.txt,outer_after.txt,outer_during.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D236_L/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D236_L" "$D236_LSTUB"

# 23s (D244/D256): three levels where the MIDDLE task commits while the
# innermost is open. At the middle task's completion the innermost window
# {mid_during, inner_c30} has residual 2 → AMBIGUOUS → nothing subtracted, so
# the middle keeps mid_during (plus inner_c30, the accepted over-report). At
# the outer task's completion, D244's other-union used to let the two windows
# explain each other — innermost covered by the middle (PURE), middle's
# residual just its auto-commit (PURE) — keeping the outer snapshot clean.
# (D256) That same mutual-coverage arithmetic is what let two CONCURRENTLY
# open sibling windows both read PURE and subtract the outer's own mid-window
# commit — this fixture's commit graph is topologically IDENTICAL to the
# sibling repro (shared-base claim chain, nested spans), so no topology-only
# rule can keep the outer clean here while keeping the outer's commit there.
# The purity fixpoint decides that loss-vs-noise trade for never losing an
# author's commit: an AMBIGUOUS window grounds no other window's purity, so
# both windows fall through and the outer OVER-REPORTS all four files — noise,
# where the sibling geometry previously LOST outer_mid from its author's
# snapshot. The middle-level assertion is unchanged; the outer one pins the
# accepted over-report.
D244_S=$(mktemp -d)
D244_SSTUB=$(mktemp -d)
make_curl_stub "$D244_SSTUB" "$D244_S/curl-call.txt" 0
d226_fixture "$D244_S"
d244_complete_s() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D244_SSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d226_claim "$D244_S" 10
d226_claim "$D244_S" 20
d226_claim "$D244_S" 30
( cd "$D244_S" && echo mid > mid_during.txt && git add -A > /dev/null && git commit -q -m mid_during )
( cd "$D244_S" && echo inner > inner_c30.txt && git add -A > /dev/null && git commit -q -m inner_c30 )
d244_complete_s "$D244_S" 30
( cd "$D244_S" && echo after > mid_after.txt && git add -A > /dev/null && git commit -q -m mid_after )
d244_complete_s "$D244_S" 20
assert_eq "23s (D244): the middle task keeps a commit it made while the innermost was open" \
  "inner_c30.txt,mid_after.txt,mid_during.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D244_S/.stride-changed-files.json" 2>/dev/null)"
( cd "$D244_S" && echo outer > outer_own.txt && git add -A > /dev/null && git commit -q -m outer_own )
d244_complete_s "$D244_S" 10
assert_eq "23s (D244/D256): ...and the outer over-reports the ambiguous descendants rather than trusting mutual coverage (the accepted loss-vs-noise trade)" \
  "inner_c30.txt,mid_after.txt,mid_during.txt,outer_own.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D244_S/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D244_S" "$D244_SSTUB"

# 23s2 (D256): TWO nested tasks open concurrently — the sibling geometry. Both
# windows share the outer's base, so each sibling's commits sit inside the
# other's span too; the old other-union let them mutually "cover" each other,
# both classified PURE, and the union subtracted the outer's own mid-window
# commit: outer(100) reported [outer_after.txt] only, its real work lost from
# its author's snapshot (it appeared only in the siblings' records). Under the
# purity fixpoint neither sibling finds a pure sub-window (mutual intersection
# grounds nothing), both read AMBIGUOUS, and the outer keeps outer_mid while
# absorbing the siblings' commits — over-reporting, the documented safer
# failure. Parallel dispatch of subagents while the outer session commits is
# the routine shape that hits this.
D256_S=$(mktemp -d)
D256_SSTUB=$(mktemp -d)
make_curl_stub "$D256_SSTUB" "$D256_S/curl-call.txt" 0
d226_fixture "$D256_S"
d256_complete_s() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D256_SSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d226_claim "$D256_S" 100
d226_claim "$D256_S" 200
d226_claim "$D256_S" 300
( cd "$D256_S" && echo mid > outer_mid.txt && git add -A > /dev/null && git commit -q -m outer_mid )
( cd "$D256_S" && echo w300 > w300.txt && git add -A > /dev/null && git commit -q -m w300 )
d256_complete_s "$D256_S" 300
( cd "$D256_S" && echo w200 > w200.txt && git add -A > /dev/null && git commit -q -m w200 )
d256_complete_s "$D256_S" 200
( cd "$D256_S" && echo after > outer_after.txt && git add -A > /dev/null && git commit -q -m outer_after )
d256_complete_s "$D256_S" 100
assert_contains "23s2 (D256): the outer task keeps the commit it made while two siblings were open" \
  "outer_mid.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D256_S/.stride-changed-files.json" 2>/dev/null)"
assert_eq "23s2 (D256): the siblings' spans fall through as over-report, never as a silent subtraction" \
  "outer_after.txt,outer_mid.txt,w200.txt,w300.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D256_S/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D256_S" "$D256_SSTUB"

# 23t (D244): an outer task whose ONLY commit is made mid-window. Pre-D244 the
# nested window swallowed it and the outer task hit the no-own-commits sentinel
# — an EMPTY snapshot for a task that really committed work, the worst shape of
# the losing-work direction. The ambiguous window now falls through whole.
D244_T=$(mktemp -d)
D244_TSTUB=$(mktemp -d)
make_curl_stub "$D244_TSTUB" "$D244_T/curl-call.txt" 0
d226_fixture "$D244_T"
d244_complete_t() {
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D244_TSTUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d226_claim "$D244_T" 100
d226_claim "$D244_T" 200
( cd "$D244_T" && echo during > only_during.txt && git add -A > /dev/null && git commit -q -m only_during )
( cd "$D244_T" && echo b > nested_b.txt && git add -A > /dev/null && git commit -q -m nested_b )
d244_complete_t "$D244_T" 200
d244_complete_t "$D244_T" 100
assert_eq "23t (D244): an outer task whose only commit is mid-window still reports it" \
  "nested_b.txt,only_during.txt" "$(jq -r '[.[].path] | sort | join(",")' "$D244_T/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D244_T" "$D244_TSTUB"

rm -rf "$D236_F" "$D236_FSTUB"

# --- D255: hook-mediated commit ownership ---------------------------------
# The fixtures ABOVE commit in bare subshells with `true` after_doing bodies —
# they exercise (and keep pinning) the window/purity FALLBACK. The cases below
# commit THROUGH after_doing, which is the only place ownership is observable
# (the pre/post loop delta), so their fixture .stride.md really commits, and
# `.stride/` is gitignored — without that, `git add -A` sweeps the hook's own
# artifacts and the "authored nothing" scenarios would fake a non-empty delta.
d255_fixture() { # $1 = dir — after_doing COMMITS (hook-mediated ownership)
  (
    cd "$1" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
.stride/
curl-call.txt
GITIGNORE
    printf '## before_doing\n```bash\ntrue\n```\n\n## after_doing\n```bash\ngit add -A > /dev/null && git commit -q -m stride-auto || true\n```\n' > .stride.md
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
  )
}
d255_complete() { # $1 = dir, $2 = task id, $3 = stub dir
  (
    cd "$1" || exit 1
    echo "{\"tool_input\":{\"command\":\"curl -X PATCH https://stride.example.com/api/tasks/$2/complete\"}}" \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$3:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d255_paths() { jq -r '[.[].path] | sort | join(",")' "$1/.stride-changed-files.json" 2>/dev/null; }

# 23e2 (D268): the cap must never evict a still-open OUTER task's own anchor.
# 20 nested claim+commit+complete cycles inside the outer's window used to push
# the outer's TASK_BASE_REF_100 off the per-family tail cap (the oldest record
# is structurally the longest-lived task's), so the outer completed with an
# EMPTY snapshot while its deliverable sat in git history — at 19 nested tasks
# the same run passed. Eviction is now per-window and open-window-aware
# (select_kept_window_records): the open outer is pinned, and the closed nested
# windows inside its window are all kept so its attribution stays complete.
# Drive 21 real cycles, checking the anchor at 19/20/21, then complete the
# outer and demand exactly its own deliverable — a missing nested window would
# leak that nested commit into the outer's snapshot, so the exact-match assert
# also guards the wrong-diff direction. Finally pin the family-desync answer:
# eviction is per-window, so no head/owned record survives without its base.
D268_DIR=$(mktemp -d)
D268_STUB=$(mktemp -d)
make_curl_stub "$D268_STUB" "$D268_DIR/curl-call.txt" 0
d255_fixture "$D268_DIR"
d226_claim "$D268_DIR" 100
(
  cd "$D268_DIR" || exit 1
  echo "deliverable" > outer_deliverable.txt
  git add outer_deliverable.txt > /dev/null
  git commit -q -m "outer deliverable"
)
for i in $(seq 1 21); do
  D268_ID=$((200 + i))
  d226_claim "$D268_DIR" "$D268_ID"
  ( cd "$D268_DIR" && echo "n$i" > "nested_$i.txt" )
  d255_complete "$D268_DIR" "$D268_ID" "$D268_STUB"
  case "$i" in
    19)
      assert_contains "23e2 (D268): control — the outer anchor survives 19 nested cycles" \
        "TASK_BASE_REF_100=" "$(cat "$D268_DIR/.stride-env-cache" 2>/dev/null)"
      ;;
    20)
      assert_contains "23e2 (D268): the outer anchor survives the 20th nested cycle (the old eviction threshold)" \
        "TASK_BASE_REF_100=" "$(cat "$D268_DIR/.stride-env-cache" 2>/dev/null)"
      ;;
    21)
      assert_contains "23e2 (D268): the outer anchor survives past the threshold" \
        "TASK_BASE_REF_100=" "$(cat "$D268_DIR/.stride-env-cache" 2>/dev/null)"
      ;;
  esac
done
d255_complete "$D268_DIR" 100 "$D268_STUB"
assert_eq "23e2 (D268): the outer uploads exactly its own deliverable after 21 nested completions" \
  "outer_deliverable.txt" "$(d255_paths "$D268_DIR")"
D268_ORPHANS=$(awk -F= '
  NR == FNR { if ($1 ~ /^TASK_BASE_REF_[0-9]+$/) { id = $1; sub(/^TASK_BASE_REF_/, "", id); base[id] = 1 }; next }
  $1 ~ /^TASK_HEAD_REF_[0-9]+$/ { id = $1; sub(/^TASK_HEAD_REF_/, "", id); if (!(id in base)) printf "head:%s ", id }
  $1 ~ /^TASK_OWNED_[0-9]+$/   { id = $1; sub(/^TASK_OWNED_/, "", id); if (!(id in base)) printf "owned:%s ", id }
' "$D268_DIR/.stride-env-cache" "$D268_DIR/.stride-env-cache" 2>/dev/null)
assert_eq "23e2 (D268): per-window eviction leaves no head/owned record without its base partner" \
  "" "$D268_ORPHANS"
rm -rf "$D268_DIR" "$D268_STUB"

# 23e3 (D268): the no-orphan invariant must hold BETWEEN claims too. A refused
# completion of a task whose base record is gone (evicted, or a foreign-owned
# cache, as here — the cheap way to stage the same shape 23c uses) used to
# still write TASK_HEAD_REF_<id> and TASK_OWNED_<id>, re-creating exactly the
# half-bounded orphan window the per-window selector exists to make
# impossible — transiently, until the next claim dropped it. The record
# writers now skip when no base partner exists, so the shape never appears.
D268_O=$(mktemp -d)
D268_OSTUB=$(mktemp -d)
make_curl_stub "$D268_OSTUB" "$D268_O/curl-call.txt" 0
d255_fixture "$D268_O"
D268_O_BASE=$(git -C "$D268_O" rev-parse HEAD)
D268_O_OUT=$(
  cd "$D268_O" || exit 1
  echo "swept" > swept.txt
  printf "TASK_ID='300'\nTASK_BASE_REF='%s'\nTASK_BASE_REF_TRUSTED='1'\nTASK_BASE_REF_OWNER='999'\n" \
    "$D268_O_BASE" > .stride-env-cache
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/300/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D268_OSTUB:$PATH" bash "$HOOK_SCRIPT" pre 2>&1
)
assert_contains "23e3 (D268): the staged foreign-owner cache still refuses loudly" \
  "REFUSING" "$D268_O_OUT"
D268_O_CACHE=$(cat "$D268_O/.stride-env-cache" 2>/dev/null)
case "$D268_O_CACHE" in
  *TASK_HEAD_REF_300=*|*TASK_OWNED_300=*) D268_O_ORPHAN="orphan-written" ;;
  *) D268_O_ORPHAN="" ;;
esac
assert_eq "23e3 (D268): a refused completion writes no orphan head/owned pair" \
  "" "$D268_O_ORPHAN"
rm -rf "$D268_O" "$D268_OSTUB"

# 23e4 (D274): the OPEN-window cap must not evict a live outer's anchor either.
# 23e2 drives SEQUENTIAL closed cycles (claim, commit, complete), so never more
# than two windows are open at once and the open cap is never reached. D268
# pinned open windows but still capped them BY COUNT and kept the NEWEST 20, so
# the open window actually dropped is the OLDEST — structurally the long-lived
# enclosing OUTER, while the twenty just-claimed children that caused the
# eviction are the ones kept. Measured before D274: 19 concurrently open
# children kept TASK_BASE_REF_100 and the outer's deliverable; 20 lost both,
# silently at claim time (empty stderr), and the outer then completed with an
# EMPTY snapshot while outer_deliverable.txt sat in git history. The cap is 20,
# dropping to 19 when finalize_before_doing reserves a slot, which is why the
# boundary falls at 20 open children rather than 21. Drive both sides of it;
# the 20-child case is the direction that failed.
d274_open_children() { # $1 = dir, $2 = how many children claim and stay OPEN
  local _i
  d255_fixture "$1"
  d226_claim "$1" 100
  (
    cd "$1" || exit 1
    echo "deliverable" > outer_deliverable.txt
    git add outer_deliverable.txt > /dev/null
    git commit -q -m "outer deliverable"
  )
  for _i in $(seq 1 "$2"); do
    d226_claim "$1" $((900 + _i))
  done
}

D274_A=$(mktemp -d)
D274_ASTUB=$(mktemp -d)
make_curl_stub "$D274_ASTUB" "$D274_A/curl-call.txt" 0
d274_open_children "$D274_A" 19
assert_contains "23e4 (D274): control — the outer anchor survives 19 concurrently open children" \
  "TASK_BASE_REF_100=" "$(cat "$D274_A/.stride-env-cache" 2>/dev/null)"
d255_complete "$D274_A" 100 "$D274_ASTUB"
assert_eq "23e4 (D274): control — the outer uploads its deliverable with 19 children open" \
  "outer_deliverable.txt" "$(d255_paths "$D274_A")"
rm -rf "$D274_A" "$D274_ASTUB"

D274_B=$(mktemp -d)
D274_BSTUB=$(mktemp -d)
make_curl_stub "$D274_BSTUB" "$D274_B/curl-call.txt" 0
d274_open_children "$D274_B" 20
assert_contains "23e4 (D274): the outer anchor survives 20 concurrently open children" \
  "TASK_BASE_REF_100=" "$(cat "$D274_B/.stride-env-cache" 2>/dev/null)"
d255_complete "$D274_B" 100 "$D274_BSTUB"
assert_eq "23e4 (D274): the outer uploads its deliverable with 20 children open" \
  "outer_deliverable.txt" "$(d255_paths "$D274_B")"
D274_B_ORPHANS=$(awk -F= '
  NR == FNR { if ($1 ~ /^TASK_BASE_REF_[0-9]+$/) { id = $1; sub(/^TASK_BASE_REF_/, "", id); base[id] = 1 }; next }
  $1 ~ /^TASK_HEAD_REF_[0-9]+$/ { id = $1; sub(/^TASK_HEAD_REF_/, "", id); if (!(id in base)) printf "head:%s ", id }
  $1 ~ /^TASK_OWNED_[0-9]+$/   { id = $1; sub(/^TASK_OWNED_/, "", id); if (!(id in base)) printf "owned:%s ", id }
' "$D274_B/.stride-env-cache" "$D274_B/.stride-env-cache" 2>/dev/null)
assert_eq "23e4 (D274): the no-orphan invariant holds with the open cap exceeded" \
  "" "$D274_B_ORPHANS"
rm -rf "$D274_B" "$D274_BSTUB"

# Two enclosing levels open at once. Worst case observed on the defect: a top
# task and a middle task both open and both holding their own commits, and
# twenty open children evicted BOTH anchors, so both completed with empty
# snapshots. Then, on the same cache, pin the STATED BOUND that replaced the
# count cap: above the sweep threshold a provably dead open window — a base
# that no longer resolves — is dropped, and every live one is kept.
D274_C=$(mktemp -d)
D274_CSTUB=$(mktemp -d)
make_curl_stub "$D274_CSTUB" "$D274_C/curl-call.txt" 0
d255_fixture "$D274_C"
d226_claim "$D274_C" 100
(
  cd "$D274_C" || exit 1
  echo "top" > top_deliverable.txt
  git add top_deliverable.txt > /dev/null
  git commit -q -m "top deliverable"
)
d226_claim "$D274_C" 110
(
  cd "$D274_C" || exit 1
  echo "mid" > mid_deliverable.txt
  git add mid_deliverable.txt > /dev/null
  git commit -q -m "mid deliverable"
)
for i in $(seq 1 20); do
  d226_claim "$D274_C" $((900 + i))
done
D274_C_CACHE=$(cat "$D274_C/.stride-env-cache" 2>/dev/null)
assert_contains "23e4 (D274): two enclosing levels — the TOP anchor is not evicted" \
  "TASK_BASE_REF_100=" "$D274_C_CACHE"
assert_contains "23e4 (D274): two enclosing levels — the MIDDLE anchor is not evicted" \
  "TASK_BASE_REF_110=" "$D274_C_CACHE"
printf "TASK_BASE_REF_777='%s'\n" "0000000000000000000000000000000000000000" >> "$D274_C/.stride-env-cache"
d226_claim "$D274_C" 998
D274_C_SWEPT=$(cat "$D274_C/.stride-env-cache" 2>/dev/null)
case "$D274_C_SWEPT" in
  *TASK_BASE_REF_777=*) D274_C_DEAD="kept" ;;
  *) D274_C_DEAD="" ;;
esac
assert_eq "23e4 (D274): above the threshold a dead open window (unresolvable base) is swept" \
  "" "$D274_C_DEAD"
assert_contains "23e4 (D274): the sweep keeps the live TOP anchor it cannot prove dead" \
  "TASK_BASE_REF_100=" "$D274_C_SWEPT"
assert_contains "23e4 (D274): the sweep keeps the live MIDDLE anchor it cannot prove dead" \
  "TASK_BASE_REF_110=" "$D274_C_SWEPT"
rm -rf "$D274_C" "$D274_CSTUB"

# 23u: the D255 headline. Outer claims, nested claims, the outer commits
# mid-window (manually), the nested's OWN after_doing commits nested_b. The
# nested snapshot must contain ONLY nested_b (before D255: nested_b + the
# outer's mid-window commit), and the outer must keep its commits WITHOUT
# double-reporting nested_b (before D255: the AMBIGUOUS window leaked it in).
D255_U=$(mktemp -d)
D255_USTUB=$(mktemp -d)
make_curl_stub "$D255_USTUB" "$D255_U/curl-call.txt" 0
d255_fixture "$D255_U"
d226_claim "$D255_U" 100
d226_claim "$D255_U" 200
( cd "$D255_U" && echo during > outer_during.txt && git add -A > /dev/null && git commit -q -m outer_during )
( cd "$D255_U" && echo b > nested_b.txt )
d255_complete "$D255_U" 200 "$D255_USTUB"
assert_eq "23u (D255): a nested task committing through after_doing captures ONLY its own commit" \
  "nested_b.txt" "$(d255_paths "$D255_U")"
assert_contains "23u (D255): the completion records its owned set" \
  "TASK_OWNED_200=" "$(cat "$D255_U/.stride-env-cache" 2>/dev/null)"
( cd "$D255_U" && echo after > outer_after.txt && git add -A > /dev/null && git commit -q -m outer_after )
d255_complete "$D255_U" 100 "$D255_USTUB"
assert_eq "23u (D255): the outer keeps its mid-window commit and does NOT double-report the nested commit" \
  "outer_after.txt,outer_during.txt" "$(d255_paths "$D255_U")"
rm -rf "$D255_U" "$D255_USTUB"

# 23v: the zero-commit window (D244's P2 probe). The nested after_doing RUNS
# and authors nothing → TASK_OWNED_200='' is recorded as a FACT — but it is
# deliberately consumed as fallback (see attributed_commit_ranges): with
# manual commits possible, "the loop authored nothing" does not mean "the
# task authored nothing" (23n's exact geometry), so ''-as-subtract-nothing
# would re-open W2066. The known zero-commit steal therefore deliberately
# remains: purity reads the one-commit window as PURE and subtracts it.
# (D272) This is the k=1 instance of a cascade — 23v2 pins what k of these
# windows do, and carries the measurement that declined the fix for both.
D255_V=$(mktemp -d)
D255_VSTUB=$(mktemp -d)
make_curl_stub "$D255_VSTUB" "$D255_V/curl-call.txt" 0
d255_fixture "$D255_V"
d226_claim "$D255_V" 100
d226_claim "$D255_V" 200
( cd "$D255_V" && echo during > outer_during.txt && git add -A > /dev/null && git commit -q -m outer_during )
d255_complete "$D255_V" 200 "$D255_VSTUB"
assert_contains "23v (D255): a loop that authors nothing records the EMPTY owned set (distinct from absence)" \
  "TASK_OWNED_200=''" "$(cat "$D255_V/.stride-env-cache" 2>/dev/null)"
assert_eq "23v (D255): the fallback nested snapshot still absorbs the outer's commit (the documented open steal)" \
  "outer_during.txt" "$(d255_paths "$D255_V")"
d255_complete "$D255_V" 100 "$D255_VSTUB"
assert_eq "23v (D255): the outer's only commit stays stolen under '' fallback (flips only if '' becomes subtract-nothing, which 23n forbids)" \
  "" "$(d255_paths "$D255_V")"
rm -rf "$D255_V" "$D255_VSTUB"

# 23w: manual-mid-work + hook-commit mix. The nested task commits nested_a
# MANUALLY, then its after_doing commits nested_b. Ownership is authoritative
# when non-empty: the nested snapshot is exactly the hook-authored delta (the
# pre-hook manual commit falls out — the accepted trade), and the manual
# commit falls back INTO the outer snapshot (over-report, the safer failure)
# while the hook-authored one stays out. Strictly better than D244, where the
# outer also carried nested_b.
D255_W=$(mktemp -d)
D255_WSTUB=$(mktemp -d)
make_curl_stub "$D255_WSTUB" "$D255_W/curl-call.txt" 0
d255_fixture "$D255_W"
d226_claim "$D255_W" 100
d226_claim "$D255_W" 200
( cd "$D255_W" && echo a > nested_a.txt && git add -A > /dev/null && git commit -q -m nested_a )
( cd "$D255_W" && echo b > nested_b.txt )
d255_complete "$D255_W" 200 "$D255_WSTUB"
assert_eq "23w (D255): with a hook-mediated commit the nested snapshot is the owned delta only" \
  "nested_b.txt" "$(d255_paths "$D255_W")"
( cd "$D255_W" && echo own > outer_own.txt && git add -A > /dev/null && git commit -q -m outer_own )
d255_complete "$D255_W" 100 "$D255_WSTUB"
assert_eq "23w (D255): the manual nested commit falls back into the outer (over-report) while the owned one stays out" \
  "nested_a.txt,outer_own.txt" "$(d255_paths "$D255_W")"
rm -rf "$D255_W" "$D255_WSTUB"

# 23x (D255/D256): depth 3 — the middle task commits on BOTH sides of the
# innermost window. The innermost owns its hook-authored commit; the middle
# keeps both its manual commits (window 30's owned set supersedes purity so
# inner_c is subtracted exactly). At the OUTER's completion, the middle's
# window is a fallback window (its own after_doing authored nothing, so its
# owned record is empty), and pre-D256 it read PURE because window 30's SPAN
# covered mid_a — but mid_a is not 30's commit; span coverage there is the
# same shared-base overlap arithmetic that let concurrent siblings steal the
# outer's commit (23s2), and a rule keeping this outer clean would re-open
# that steal whenever one sibling committed through hooks and the other by
# hand. Only 30's exact OWNED commit grounds coverage now, so the middle's
# window reads AMBIGUOUS and the outer over-reports the middle's manual
# commits — noise in place of lost work, the same decided trade 23s pins.
D255_X=$(mktemp -d)
D255_XSTUB=$(mktemp -d)
make_curl_stub "$D255_XSTUB" "$D255_X/curl-call.txt" 0
d255_fixture "$D255_X"
d226_claim "$D255_X" 10
d226_claim "$D255_X" 20
d226_claim "$D255_X" 30
( cd "$D255_X" && echo ma > mid_a.txt && git add -A > /dev/null && git commit -q -m mid_a )
( cd "$D255_X" && echo i > inner_c.txt )
d255_complete "$D255_X" 30 "$D255_XSTUB"
assert_eq "23x (D255): the innermost snapshot is its owned commit only" \
  "inner_c.txt" "$(d255_paths "$D255_X")"
( cd "$D255_X" && echo mb > mid_b.txt && git add -A > /dev/null && git commit -q -m mid_b )
d255_complete "$D255_X" 20 "$D255_XSTUB"
assert_eq "23x (D255): the middle keeps both manual commits; the owned innermost commit is subtracted exactly" \
  "mid_a.txt,mid_b.txt" "$(d255_paths "$D255_X")"
( cd "$D255_X" && echo x > outer_x.txt && git add -A > /dev/null && git commit -q -m outer_x )
d255_complete "$D255_X" 10 "$D255_XSTUB"
assert_eq "23x (D255/D256): the outer over-reports the middle's manual commits rather than trusting span overlap; the owned inner commit stays subtracted exactly" \
  "mid_a.txt,mid_b.txt,outer_x.txt" "$(d255_paths "$D255_X")"
rm -rf "$D255_X" "$D255_XSTUB"

# 23y: the owned records must survive the claim-time cache rewrite (the D236
# bug class — a truncating rewrite that drops the family silently reverts the
# signal on the very next claim). Geometry chosen so fallback CANNOT mask a
# dropped record: without the carry-forward, window 200 reads AMBIGUOUS and
# nested_b leaks into the outer snapshot.
D255_Y=$(mktemp -d)
D255_YSTUB=$(mktemp -d)
make_curl_stub "$D255_YSTUB" "$D255_Y/curl-call.txt" 0
d255_fixture "$D255_Y"
d226_claim "$D255_Y" 100
d226_claim "$D255_Y" 200
( cd "$D255_Y" && echo during > outer_during.txt && git add -A > /dev/null && git commit -q -m outer_during )
( cd "$D255_Y" && echo b > nested_b.txt )
d255_complete "$D255_Y" 200 "$D255_YSTUB"
d226_claim "$D255_Y" 300
assert_contains "23y (D255): the owned record survives a later claim's truncating rewrite" \
  "TASK_OWNED_200=" "$(cat "$D255_Y/.stride-env-cache" 2>/dev/null)"
( cd "$D255_Y" && echo c > fileC.txt )
d255_complete "$D255_Y" 300 "$D255_YSTUB"
d255_complete "$D255_Y" 100 "$D255_YSTUB"
assert_eq "23y (D255): with surviving owned records the outer neither double-reports nor loses" \
  "outer_during.txt" "$(d255_paths "$D255_Y")"
rm -rf "$D255_Y" "$D255_YSTUB"

# 23z: the 20-SHA value cap. An after_doing that authors 21 commits records
# the OVERFLOW sentinel, which every consumer treats exactly like no-record —
# the nested capture falls back to base..working-tree (all 21 files present
# proves OVERFLOW was never consumed as a truncated owned list), and the
# outer's fallback classification reads the 21-commit window as AMBIGUOUS and
# over-reports (sane, never loss).
D255_Z=$(mktemp -d)
D255_ZSTUB=$(mktemp -d)
make_curl_stub "$D255_ZSTUB" "$D255_Z/curl-call.txt" 0
(
  cd "$D255_Z" || exit 1
  git init -q
  git config user.email "test@test.local"
  git config user.name "Test"
  cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
.stride/
curl-call.txt
GITIGNORE
  printf '## before_doing\n```bash\ntrue\n```\n\n## after_doing\n```bash\nfor i in $(seq 1 21); do echo $i > f$i.txt && git add -A > /dev/null && git commit -q -m c$i; done || true\n```\n' > .stride.md
  echo "v1" > tracked.txt
  git add .gitignore tracked.txt > /dev/null
  git commit -q -m "v1"
)
d226_claim "$D255_Z" 100
d226_claim "$D255_Z" 200
d255_complete "$D255_Z" 200 "$D255_ZSTUB"
assert_contains "23z (D255): a 21-commit delta records the OVERFLOW sentinel, never a truncated list" \
  "TASK_OWNED_200='OVERFLOW'" "$(cat "$D255_Z/.stride-env-cache" 2>/dev/null)"
assert_eq "23z (D255): OVERFLOW is consumed as fallback — the nested snapshot carries all 21 files" \
  "21" "$(jq 'length' "$D255_Z/.stride-changed-files.json" 2>/dev/null)"
rm -rf "$D255_Z" "$D255_ZSTUB"

# 23z2: a rebase orphans the recorded SHAs. The window head stops being an
# ancestor of HEAD, the window drops, everything falls back — the outer's own
# work is never lost (over-report is acceptable, loss is not).
D255_R=$(mktemp -d)
D255_RSTUB=$(mktemp -d)
make_curl_stub "$D255_RSTUB" "$D255_R/curl-call.txt" 0
d255_fixture "$D255_R"
d226_claim "$D255_R" 100
d226_claim "$D255_R" 200
( cd "$D255_R" && echo during > outer_during.txt && git add -A > /dev/null && git commit -q -m outer_during )
( cd "$D255_R" && echo b > nested_b.txt )
d255_complete "$D255_R" 200 "$D255_RSTUB"
(
  cd "$D255_R" || exit 1
  git reset -q --hard HEAD~1
  echo b2 > nested_b.txt && git add -A > /dev/null && git commit -q -m rewritten
  echo after > outer_after.txt && git add -A > /dev/null && git commit -q -m outer_after
)
d255_complete "$D255_R" 100 "$D255_RSTUB"
assert_contains "23z2 (D255): orphaned owned SHAs never lose the outer's own work (over-report ok)" \
  "outer_after.txt" "$(d255_paths "$D255_R")"
assert_contains "23z2 (D255): the outer's mid-window commit also survives the rewrite" \
  "outer_during.txt" "$(d255_paths "$D255_R")"
rm -rf "$D255_R" "$D255_RSTUB"

# 23z3 (D271): an OUTERMOST task must not narrow to its owned set. A single
# claim (no other window ever exists), a manual mid-task commit, and a dirty
# tracked edit the after_doing sweep commits (making the owned set genuinely
# non-empty — the shape that trips the bug). Nested tasks may narrow because
# the dropped base..H0 commits fall back into the enclosing OPEN window
# (23u/23w pin that over-report); with no other open window there is no
# absorber, and pre-D271 the snapshot was tracked.txt alone — the manual
# commit silently vanished from an outermost task's own report.
D271_A=$(mktemp -d)
D271_ASTUB=$(mktemp -d)
make_curl_stub "$D271_ASTUB" "$D271_A/curl-call.txt" 0
d255_fixture "$D271_A"
d226_claim "$D271_A" 100
( cd "$D271_A" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D271_A" && echo dirty >> tracked.txt )
d255_complete "$D271_A" 100 "$D271_ASTUB"
assert_contains "23z3 (D271): the sweep still records a non-empty owned set (the narrowing trigger is real)" \
  "TASK_OWNED_100=" "$(cat "$D271_A/.stride-env-cache" 2>/dev/null)"
assert_eq "23z3 (D271): an outermost task's manual commit survives alongside its own after_doing commit" \
  "manual.txt,tracked.txt" "$(d255_paths "$D271_A")"
rm -rf "$D271_A" "$D271_ASTUB"

# 23z4 (D271): same geometry with a stray UNTRACKED file as the sweep fodder —
# the common accidental shape (a junk file left in the tree) that made the
# swept residue masquerade as the task's whole deliverable.
D271_B=$(mktemp -d)
D271_BSTUB=$(mktemp -d)
make_curl_stub "$D271_BSTUB" "$D271_B/curl-call.txt" 0
d255_fixture "$D271_B"
d226_claim "$D271_B" 100
( cd "$D271_B" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D271_B" && echo stray > stray.txt )
d255_complete "$D271_B" 100 "$D271_BSTUB"
assert_eq "23z4 (D271): an outermost task's manual commit survives alongside a swept stray file" \
  "manual.txt,stray.txt" "$(d255_paths "$D271_B")"
rm -rf "$D271_B" "$D271_BSTUB"

# 23z5 (D271 edge): after_doing authors NOTHING at top level (clean tree at
# completion). The owned set is the recorded-empty fact, narrowing never had a
# trigger, and the wide path reports the manual commit — pinned so the D271
# gate can never regress the already-correct empty-owned outermost shape.
D271_C=$(mktemp -d)
D271_CSTUB=$(mktemp -d)
make_curl_stub "$D271_CSTUB" "$D271_C/curl-call.txt" 0
d255_fixture "$D271_C"
d226_claim "$D271_C" 100
( cd "$D271_C" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
d255_complete "$D271_C" 100 "$D271_CSTUB"
assert_contains "23z5 (D271): a sweep that authors nothing records the empty owned set at top level" \
  "TASK_OWNED_100=''" "$(cat "$D271_C/.stride-env-cache" 2>/dev/null)"
assert_eq "23z5 (D271): the outermost snapshot still reports the manual commit when the sweep authored nothing" \
  "manual.txt" "$(d255_paths "$D271_C")"
rm -rf "$D271_C" "$D271_CSTUB"

# 23z6 (D271): the observed worst case — an outer task with 22 nested
# completions and a junk sweep at its own completion. Pre-D271 the outer's
# snapshot was ONLY the junk its after_doing swept (the entire real
# deliverable missing); the outermost gate keeps the deliverable, and the
# exact match also guards the wrong-diff direction (no nested file may leak
# into the outer's snapshot through the 22 closed windows).
D271_D=$(mktemp -d)
D271_DSTUB=$(mktemp -d)
make_curl_stub "$D271_DSTUB" "$D271_D/curl-call.txt" 0
d255_fixture "$D271_D"
d226_claim "$D271_D" 100
(
  cd "$D271_D" || exit 1
  echo "deliverable" > outer_deliverable.txt
  git add outer_deliverable.txt > /dev/null
  git commit -q -m "outer deliverable"
)
for i in $(seq 1 22); do
  D271_ID=$((200 + i))
  d226_claim "$D271_D" "$D271_ID"
  ( cd "$D271_D" && echo "n$i" > "nested_$i.txt" )
  d255_complete "$D271_D" "$D271_ID" "$D271_DSTUB"
done
( cd "$D271_D" && echo junk > junk.txt )
d255_complete "$D271_D" 100 "$D271_DSTUB"
assert_eq "23z6 (D271): after 22 nested completions the outer reports its deliverable plus the sweep, never only the swept residue" \
  "junk.txt,outer_deliverable.txt" "$(d255_paths "$D271_D")"
rm -rf "$D271_D" "$D271_DSTUB"

# 23z7 (D271): a stale base-without-head cache line must not flip the
# outermost gate. A dead open-window record (abandoned claim's leftover, a
# rebase-orphaned or corrupt SHA — here one that resolves to nothing) has no
# completion coming to absorb anything, so treating it as a live absorber
# would resurrect the exact D271 under-report through one junk cache line.
# The predicate validates candidates like attributed_commit_ranges does
# (resolvable + ancestor of HEAD), so the 23z3 geometry still reports both
# changes with the stale line present.
D271_E=$(mktemp -d)
D271_ESTUB=$(mktemp -d)
make_curl_stub "$D271_ESTUB" "$D271_E/curl-call.txt" 0
d255_fixture "$D271_E"
d226_claim "$D271_E" 100
printf "TASK_BASE_REF_999='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'\n" >> "$D271_E/.stride-env-cache"
( cd "$D271_E" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D271_E" && echo dirty >> tracked.txt )
d255_complete "$D271_E" 100 "$D271_ESTUB"
assert_eq "23z7 (D271): a stale open-window record never re-narrows an outermost task's snapshot" \
  "manual.txt,tracked.txt" "$(d255_paths "$D271_E")"
rm -rf "$D271_E" "$D271_ESTUB"

# --- D273: window-state drift ---------------------------------------------
# 23z7 pins the CORRUPT record (a SHA that resolves to nothing). It does not
# reach the case D271 explicitly left open: a GENUINELY ABANDONED claim, whose
# base is a real commit and a real ancestor, so every check 23z7 exercises
# passes. Nothing ages such a line out — there is no unclaim path in this
# script, claim expiry is server-side only, and D268 eviction pins open windows
# — so one abandoned claim re-enabled the D255 narrowing for every later
# outermost task in the checkout, permanently. That is the D271 under-report
# restored by a record with no owner, and the 60-minute claim expiry makes it
# routine rather than exotic.
#
# 23z8 and 23z9 are a PAIR and must be read together: identical geometry,
# differing only in the age of the phantom window's base. The pair is what
# makes either case meaningful — 23z9 alone would pass before this change, and
# 23z8 alone could pass by disabling narrowing outright.
#
# A phantom window is a base line plus the claim-time stamp its own claim
# would have written. The stamp — not the base commit's date — is what the
# predicate ages, so these helpers take the stamp as an argument: `now` for a
# live window, an epoch far in the past for an abandoned one. Writing the base
# WITHOUT a stamp is a third, meaningful state (a record from a hook version
# that predates D273), exercised by 23z17.
d273_phantom() { # $1 = dir, $2 = id, $3 = base sha, $4 = epoch stamp ('' for none)
  printf "TASK_BASE_REF_%s='%s'\n" "$2" "$3" >> "$1/.stride-env-cache"
  [ -n "${4:-}" ] && printf "TASK_BASE_AT_%s='%s'\n" "$2" "$4" >> "$1/.stride-env-cache"
  return 0
}
d273_now() { date +%s; }

# 23z8 (D273): the abandoned claim. TASK_BASE_REF_999 resolves, is an ancestor
# of HEAD, and has no head partner — it passes every 23z7 check — but its own
# claim stamp is years old, so no live session is behind it and nothing is
# coming to absorb this task's manual commit. Aged out, the completing task is
# outermost and keeps the wide path.
D273_A=$(mktemp -d)
D273_ASTUB=$(mktemp -d)
make_curl_stub "$D273_ASTUB" "$D273_A/curl-call.txt" 0
d255_fixture "$D273_A"
d226_claim "$D273_A" 100
D273_A_SHA=$( cd "$D273_A" && git rev-parse HEAD )
d273_phantom "$D273_A" 999 "$D273_A_SHA" 1577836800
( cd "$D273_A" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_A" && echo dirty >> tracked.txt )
d255_complete "$D273_A" 100 "$D273_ASTUB"
assert_eq "23z8 (D273): an abandoned open window past the age horizon stops absorbing, so the outermost task keeps its manual commit" \
  "manual.txt,tracked.txt" "$(d255_paths "$D273_A")"
rm -rf "$D273_A" "$D273_ASTUB"

# 23z9 (D273): the control for 23z8 — same geometry, same base commit, ONLY the
# claim stamp differs. It must still narrow: the age check may retire dead
# records and nothing else. The pair is what makes either case mean anything.
D273_B=$(mktemp -d)
D273_BSTUB=$(mktemp -d)
make_curl_stub "$D273_BSTUB" "$D273_B/curl-call.txt" 0
d255_fixture "$D273_B"
d226_claim "$D273_B" 100
D273_B_SHA=$( cd "$D273_B" && git rev-parse HEAD )
d273_phantom "$D273_B" 999 "$D273_B_SHA" "$(d273_now)"
( cd "$D273_B" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_B" && echo dirty >> tracked.txt )
d255_complete "$D273_B" 100 "$D273_BSTUB"
assert_eq "23z9 (D273): a FRESH open window still absorbs, so the narrowing D255 exists for is untouched" \
  "tracked.txt" "$(d255_paths "$D273_B")"
rm -rf "$D273_B" "$D273_BSTUB"

# 23z10 (D273): the horizon is overridable, and raising it past the record's
# age puts the SAME window back in service — so 23z8 turns on age alone and not
# on some other property of that cache line. Digits-only path.
D273_C=$(mktemp -d)
D273_CSTUB=$(mktemp -d)
make_curl_stub "$D273_CSTUB" "$D273_C/curl-call.txt" 0
d255_fixture "$D273_C"
d226_claim "$D273_C" 100
D273_C_SHA=$( cd "$D273_C" && git rev-parse HEAD )
d273_phantom "$D273_C" 999 "$D273_C_SHA" 1577836800
( cd "$D273_C" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_C" && echo dirty >> tracked.txt )
(
  cd "$D273_C" || exit 1
  echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D273_CSTUB:$PATH" \
      STRIDE_OPEN_WINDOW_MAX_AGE_SECS=9999999999 bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
)
assert_eq "23z10 (D273): raising STRIDE_OPEN_WINDOW_MAX_AGE_SECS past the record's age restores the narrowing" \
  "tracked.txt" "$(d255_paths "$D273_C")"
rm -rf "$D273_C" "$D273_CSTUB"

# 23z11 (D273): the two override values that must NOT disable the check. A
# non-numeric one falls back to the documented default (the direction 26f pins
# for the budget override); an out-of-range one does too, which is the point —
# `test -gt` parses with strtoimax, so past 2^63 the comparison becomes an
# ERROR, and with no `set -e` the `&& continue` would short-circuit and leave
# every dead record counted as live. Both must leave the dead window dead.
for D273_OV in "not-a-number" "99999999999999999999"; do
  D273_D=$(mktemp -d)
  D273_DSTUB=$(mktemp -d)
  make_curl_stub "$D273_DSTUB" "$D273_D/curl-call.txt" 0
  d255_fixture "$D273_D"
  d226_claim "$D273_D" 100
  D273_D_SHA=$( cd "$D273_D" && git rev-parse HEAD )
  d273_phantom "$D273_D" 999 "$D273_D_SHA" 1577836800
  ( cd "$D273_D" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
  ( cd "$D273_D" && echo dirty >> tracked.txt )
  (
    cd "$D273_D" || exit 1
    echo '{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/100/complete"}}' \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$D273_DSTUB:$PATH" \
        STRIDE_OPEN_WINDOW_MAX_AGE_SECS="$D273_OV" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  assert_eq "23z11 (D273): an unusable horizon override ('$D273_OV') falls back to the default and the dead window stays dead" \
    "manual.txt,tracked.txt" "$(d255_paths "$D273_D")"
  rm -rf "$D273_D" "$D273_DSTUB"
done

# 23z17 (D273): the boundary, and the two states either side of it. The
# implementation chose strict -gt — age exactly AT the horizon is still LIVE —
# and nothing else in the suite lands on that line, so flipping -gt to -ge
# would otherwise pass unnoticed. Asserted against the predicate directly with
# the horizon pinned to 100s: at 100s old it must narrow, at 101s it must not.
# The third row is the no-stamp case, which is how every window written by a
# pre-D273 hook looks and is the whole abandoned population this retires.
# Each row writes to its OWN result path, removed first: a shared path would
# let a row whose subshell died before printing pass on the PREVIOUS row's
# verdict — and rows 2-5 all expect DEAD, so the no-stamp row (the one that
# pins the whole abandoned population) is exactly where that would hide. An
# absent file now reads as empty and fails loudly.
D273_IDX=0
for D273_ROW in "100:LIVE:exactly at the horizon is still live (strict -gt)" \
  "101:DEAD:one second past the horizon is dead" \
  "RAW=08:DEAD:a leading-zero stamp is rejected, never read as octal" \
  "RAW=99999999999999999999:DEAD:a stamp too wide for the arithmetic is rejected, never wrapped into LIVE" \
  "-86400:DEAD:a stamp dated in the FUTURE is not a small age, it is an invalid one" \
  ":DEAD:a record with no claim stamp at all is dead"; do
  D273_IDX=$((D273_IDX + 1))
  D273_AGE="${D273_ROW%%:*}"
  D273_REST="${D273_ROW#*:}"
  D273_WANT="${D273_REST%%:*}"
  D273_WHAT="${D273_REST#*:}"
  D273_EDGE="$TMPDIR_TEST/d273_edge_$D273_IDX"
  rm -f "$D273_EDGE"
  (
    # shellcheck source=/dev/null
    HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
    D273_J=$(mktemp -d)
    PROJECT_DIR="$D273_J"
    ENV_CACHE="$D273_J/.stride-env-cache"
    STRIDE_OPEN_WINDOW_MAX_AGE_SECS=100
    (
      cd "$D273_J" || exit 1
      git init -q
      git config user.email "test@test.local"
      git config user.name "Test"
      echo v1 > f.txt
      git add f.txt > /dev/null
      git commit -q -m v1
    )
    D273_J_SHA=$( cd "$D273_J" && git rev-parse HEAD )
    printf "TASK_BASE_REF_999='%s'\n" "$D273_J_SHA" > "$ENV_CACHE"
    case "$D273_AGE" in
      '') : ;;
      RAW=*) printf "TASK_BASE_AT_999='%s'\n" "${D273_AGE#RAW=}" >> "$ENV_CACHE" ;;
      *) printf "TASK_BASE_AT_999='%s'\n" "$(( $(date +%s) - D273_AGE ))" >> "$ENV_CACHE" ;;
    esac
    if another_open_window_exists 100; then
      printf 'LIVE' > "$D273_EDGE"
    else
      printf 'DEAD' > "$D273_EDGE"
    fi
    rm -rf "$D273_J"
  ) > /dev/null 2>&1 || true
  assert_eq "23z17 (D273): $D273_WHAT" "$D273_WANT" "$(cat "$D273_EDGE" 2>/dev/null)"
done

# 23z18 (D273): the claim-time stamp must SURVIVE a later claim. The cache is
# rebuilt at claim from select_kept_window_records plus fixed identity keys,
# which emit only the base/head/owned families — so without the carry-forward
# every surviving stamp would vanish on the next claim, every open window would
# read as unstamped, and the predicate would retire live windows wholesale.
# This is the 23u nesting geometry with an extra claim in the middle: if the
# outer's stamp were lost, the nested completion would take the wide path.
D273_K=$(mktemp -d)
D273_KSTUB=$(mktemp -d)
make_curl_stub "$D273_KSTUB" "$D273_K/curl-call.txt" 0
d255_fixture "$D273_K"
d226_claim "$D273_K" 100
assert_contains "23z18 (D273): a claim stamps when its own window opened" \
  "TASK_BASE_AT_100=" "$(cat "$D273_K/.stride-env-cache" 2>/dev/null)"
d226_claim "$D273_K" 200
assert_contains "23z18 (D273): a later claim carries the earlier open window's stamp forward" \
  "TASK_BASE_AT_100=" "$(cat "$D273_K/.stride-env-cache" 2>/dev/null)"
( cd "$D273_K" && echo during > outer_during.txt && git add -A > /dev/null && git commit -q -m outer_during )
( cd "$D273_K" && echo b > nested_b.txt )
d255_complete "$D273_K" 200 "$D273_KSTUB"
assert_eq "23z18 (D273): the surviving stamp keeps the outer window live, so nesting still narrows" \
  "nested_b.txt" "$(d255_paths "$D273_K")"
rm -rf "$D273_K" "$D273_KSTUB"

# --- D273: self-heal replays the capture-time verdict ----------------------
# The Group 23 drives above never PUT: resolve_stride_api_{url,token} read the
# completion COMMAND, and d255_complete's command carries no Authorization
# header, so finalize_after_doing stops before the upload block. These cases
# need the upload to happen (a failed PUT is what arms the self-heal), so they
# drive a command that carries one — the Group 13 idiom, in Group 23 geometry.
d273_complete_auth() { # $1 = dir, $2 = task id, $3 = stub dir
  (
    cd "$1" || exit 1
    jq -nc --arg cmd "curl -X PATCH https://stride.example.com/api/tasks/$2/complete -H \"Authorization: Bearer tok\"" \
      '{tool_input:{command:$cmd}}' \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$3:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
}
d273_before_review() { # $1 = dir, $2 = task id, $3 = stub dir
  (
    cd "$1" || exit 1
    jq -nc --arg cmd "curl -X PATCH https://stride.example.com/api/tasks/$2/complete -H \"Authorization: Bearer tok\"" \
      --arg out "{\"data\":{\"id\":$2},\"hooks\":[{\"name\":\"before_review\"}]}" \
      '{tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
      | CLAUDE_PROJECT_DIR="$PWD" PATH="$3:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
}

# 23z12 (D273): the headline. Nested 200 completes inside outer 100's window,
# narrows correctly, and its PUT fails — so the snapshot it captured is not on
# the server and before_review must re-upload it. Outer 100 then completes in
# that gap, which does TWO things the retry used to lose to: it closes the only
# other open window, so re-deriving the D255 gate now answers "outermost"; and
# its own record_diff_upload_state TRUNCATES the shared state file, so 200's
# persisted judgment is overwritten with 100's. The retry therefore re-captured
# WIDE over its own narrowed primary and manual.txt was attributed to both
# tasks. The verdict is now stamped per task at capture time, so the retry
# re-uploads what it actually captured.
D273_E=$(mktemp -d)
D273_E500=$(mktemp -d)
D273_E200=$(mktemp -d)
make_curl_stub "$D273_E500" "$D273_E/curl-call.txt" 0 500
make_curl_stub "$D273_E200" "$D273_E/curl-call.txt" 0 200
d255_fixture "$D273_E"
d226_claim "$D273_E" 100
d226_claim "$D273_E" 200
( cd "$D273_E" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_E" && echo dirty >> tracked.txt )
d273_complete_auth "$D273_E" 200 "$D273_E500"
D273_E_PRIMARY="$(d255_paths "$D273_E")"
assert_eq "23z12 (D273): the nested primary capture narrows to its own commit" \
  "tracked.txt" "$D273_E_PRIMARY"
assert_contains "23z12 (D273): the capture stamps its verdict per task, where an interleaved completion cannot truncate it" \
  "TASK_NARROWED_200='yes'" "$(cat "$D273_E/.stride-env-cache" 2>/dev/null)"
d273_complete_auth "$D273_E" 100 "$D273_E200"
assert_contains "23z12 (D273): the interleaved completion really does overwrite the shared state file" \
  "task_id=100" "$(cat "$D273_E/.stride-diff-upload-state" 2>/dev/null)"
d273_before_review "$D273_E" 200 "$D273_E200"
assert_eq "23z12 (D273): the delayed self-heal re-uploads the judgment its OWN capture reached, not the one retry-time state implies" \
  "$D273_E_PRIMARY" "$(d255_paths "$D273_E")"
rm -rf "$D273_E" "$D273_E500" "$D273_E200"

# 23z13 (D273): the fallback, and the control that makes 23z12 mean something.
# Identical drive with BOTH carriers of the verdict removed — the state written
# by a hook version that predates this change. With nothing on record the retry
# re-derives exactly as it did before, which in this geometry is the wide path.
# 23z12 and 23z13 differ only in whether a verdict was persisted, so the pair
# pins that the replay is what changes the outcome.
D273_F=$(mktemp -d)
D273_F500=$(mktemp -d)
D273_F200=$(mktemp -d)
make_curl_stub "$D273_F500" "$D273_F/curl-call.txt" 0 500
make_curl_stub "$D273_F200" "$D273_F/curl-call.txt" 0 200
d255_fixture "$D273_F"
d226_claim "$D273_F" 100
d226_claim "$D273_F" 200
( cd "$D273_F" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_F" && echo dirty >> tracked.txt )
d273_complete_auth "$D273_F" 200 "$D273_F500"
grep -v '^TASK_NARROWED_' "$D273_F/.stride-env-cache" > "$D273_F/.env-tmp" 2>/dev/null
mv "$D273_F/.env-tmp" "$D273_F/.stride-env-cache"
d273_complete_auth "$D273_F" 100 "$D273_F200"
d273_before_review "$D273_F" 200 "$D273_F200"
assert_eq "23z13 (D273): with no verdict on record the self-heal re-derives exactly as it did before this change" \
  "manual.txt,tracked.txt" "$(d255_paths "$D273_F")"
rm -rf "$D273_F" "$D273_F500" "$D273_F200"

# 23z14 (D273): a tampered verdict degrades to the WIDE path, never to
# narrowing and never to executing anything. The value is only ever compared,
# so the risk is not injection but a hand-edited or corrupted line steering the
# retry into under-reporting — the one direction D271 forbids. No interleaved
# completion here: the outer window is still open, so BOTH a faithful replay
# (`yes`) and a fresh re-derivation would narrow. Only the tamper path gives
# the wide answer, which is what makes this assertion decisive rather than
# incidental.
D273_G=$(mktemp -d)
D273_G500=$(mktemp -d)
D273_G200=$(mktemp -d)
make_curl_stub "$D273_G500" "$D273_G/curl-call.txt" 0 500
make_curl_stub "$D273_G200" "$D273_G/curl-call.txt" 0 200
d255_fixture "$D273_G"
d226_claim "$D273_G" 100
d226_claim "$D273_G" 200
( cd "$D273_G" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_G" && echo dirty >> tracked.txt )
d273_complete_auth "$D273_G" 200 "$D273_G500"
sed "s/^TASK_NARROWED_200=.*/TASK_NARROWED_200='\$(touch pwned.txt)'/" \
  "$D273_G/.stride-env-cache" > "$D273_G/.env-tmp" 2>/dev/null
mv "$D273_G/.env-tmp" "$D273_G/.stride-env-cache"
d273_before_review "$D273_G" 200 "$D273_G200"
assert_eq "23z14 (D273): a tampered verdict degrades to the wide path, never to narrowing" \
  "manual.txt,tracked.txt" "$(d255_paths "$D273_G")"
if [ -e "$D273_G/pwned.txt" ]; then
  echo -e "  ${RED}FAIL${RESET}: 23z14 (D273): the tampered verdict was EXECUTED, not compared"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 23z14 (D273): the tampered verdict is compared, never executed"
  PASS=$((PASS + 1))
fi
rm -rf "$D273_G" "$D273_G500" "$D273_G200"

# 23z15 (D273, superseded in part by D269): the edge D273's testing_strategy
# named — a record whose id SANITIZES into the caller's key space.
#
# WHEN THIS WAS WRITTEN the sanitizer mapped every non-alphanumeric to '_', so
# `10-0` and `10_0` produced the same key and the predicate excluded the record
# as self. D269 removed the collision at its source: a non-integer id names NO
# record, so such a line cannot be read at all.
#
# THE FIXTURE IS BUILT TO TELL THOSE TWO APART, because the first version of
# this rewrite could not. It asserted the new mechanism while the record was
# actually being skipped at the D273 age gate for a stamp that was simply
# absent — the same skip a pre-D269 script would perform, so the stated reason
# was asserted rather than demonstrated. Here the caller is an INTEGER id
# (100), the phantom record carries a NON-integer id (10_0), and it is given a
# FRESH stamp. Pre-D269 that phantom is a live absorber: its key resolves, its
# stamp is found, self-exclusion does not apply because the ids differ, so the
# predicate answers "open window". Post-D269 the non-integer id names no
# record, so neither its head nor its stamp can be looked up and it vouches for
# nothing. The two answers differ, which is what makes this a test.
(
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
  D273_H=$(mktemp -d)
  PROJECT_DIR="$D273_H"
  ENV_CACHE="$D273_H/.stride-env-cache"
  (
    cd "$D273_H" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo v1 > f.txt
    git add f.txt > /dev/null
    git commit -q -m v1
  )
  D273_H_SHA=$( cd "$D273_H" && git rev-parse HEAD )
  printf "TASK_BASE_REF_10_0='%s'\n" "$D273_H_SHA" > "$ENV_CACHE"
  printf "TASK_BASE_AT_10_0='%s'\n" "$(date +%s)" >> "$ENV_CACHE"
  if another_open_window_exists 100; then
    echo "COLLIDE_OPEN" > "$D273_H/result"
  else
    echo "COLLIDE_SELF" > "$D273_H/result"
  fi
  cp "$D273_H/result" "$TMPDIR_TEST/d273_collide" 2>/dev/null || true
  rm -rf "$D273_H"
) > /dev/null 2>&1 || true
assert_eq "23z15 (D273/D269): a freshly-stamped record under a NON-integer id vouches for no window, because that id names no record" \
  "COLLIDE_SELF" "$(cat "$TMPDIR_TEST/d273_collide" 2>/dev/null)"

# 23z15b (D269): the self-exclusion 23z15 used to demonstrate, driven with an
# integer id so it still exercises a live path after D269. A task must not treat
# its OWN open window as another task's absorber.
(
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
  D269_S=$(mktemp -d)
  PROJECT_DIR="$D269_S"
  ENV_CACHE="$D269_S/.stride-env-cache"
  (
    cd "$D269_S" || exit 1
    git init -q; git config user.email "test@test.local"; git config user.name "Test"
    echo v1 > f.txt; git add f.txt > /dev/null; git commit -q -m v1
  )
  D269_S_SHA=$( cd "$D269_S" && git rev-parse HEAD )
  printf "TASK_BASE_REF_100='%s'\n" "$D269_S_SHA" > "$ENV_CACHE"
  printf "TASK_BASE_AT_100='%s'\n" "$(date +%s)" >> "$ENV_CACHE"
  if another_open_window_exists 100; then printf 'OPEN' > "$TMPDIR_TEST/d269_self"; else printf 'SELF' > "$TMPDIR_TEST/d269_self"; fi
  rm -rf "$D269_S"
) > /dev/null 2>&1 || true
assert_eq "23z15b (D269): a task's own FRESH open window is still excluded as self, not counted as an absorber" \
  "SELF" "$(cat "$TMPDIR_TEST/d269_self" 2>/dev/null)"

# 23z15c (D269): the headline — two ids differing only in punctuation can no
# longer share a per-task record family. The repro that found it: claim `42-x`,
# complete it, then claim `42.x`; both sanitized to suffix `42_x`, so
# TASK_OWNED_42_x / TASK_BASE_REF_42_x / TASK_HEAD_REF_42_x were SHARED and the
# second claim inherited the first task's records, treating the claim as a
# re-claim of the same key and dropping the shared self record.
#
# Asserted across ALL FIVE families, because they share one sanitizer and the
# task's own pitfall demands the disposition apply to every one identically —
# while its text says THREE, having been written before D273 added the last
# two. Driving all five is what makes that pitfall verifiable rather than
# assumed.
(
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
  {
    printf 'colliding:'
    for _k in task_base_ref_key task_head_ref_key task_owned_key task_base_at_key task_narrowed_key; do
      printf ' %s=[%s|%s]' "$_k" "$($_k '42-x')" "$($_k '42.x')"
    done
    printf '\ninteger:'
    for _k in task_base_ref_key task_head_ref_key task_owned_key task_base_at_key task_narrowed_key; do
      printf ' %s' "$($_k '42')"
    done
    printf '\nreserved: [%s][%s][%s] allpunct:[%s] underscore:[%s] long:[%s]' \
      "$(task_base_ref_key TRUSTED)" "$(task_base_ref_key OWNER)" "$(task_base_ref_key UNPROVEN)" \
      "$(task_base_ref_key './-')" "$(task_base_ref_key '10_0')" \
      "$(task_base_ref_key '00000000000000000000000000000042')"
  } > "$TMPDIR_TEST/d269_keys" 2>/dev/null || true
) > /dev/null 2>&1 || true
D269_KEYS=$(cat "$TMPDIR_TEST/d269_keys" 2>/dev/null)
# Every family yields NO key for either colliding id, so they cannot share one.
assert_eq "23z15c (D269): all five families refuse both colliding ids, so no two ids differing only in punctuation can share a record" \
  "colliding: task_base_ref_key=[|] task_head_ref_key=[|] task_owned_key=[|] task_base_at_key=[|] task_narrowed_key=[|]" \
  "$(printf '%s\n' "$D269_KEYS" | grep '^colliding:')"
# Integer ids are untouched — the guard must not cost the real population.
assert_eq "23z15c (D269): integer ids still produce their five distinct family keys" \
  "integer: TASK_BASE_REF_42 TASK_HEAD_REF_42 TASK_OWNED_42 TASK_BASE_AT_42 TASK_NARROWED_42" \
  "$(printf '%s\n' "$D269_KEYS" | grep '^integer:')"
# The reserved-word guard is preserved (D269 pitfall), and the named edge cases.
# `10_0` is refused too: underscore is in the sanitizer's alphabet but not in
# the integer invariant, so this records that the guard is digits-only rather
# than merely punctuation-stripping.
assert_eq "23z15c (D269): reserved words, all-punctuation, underscore and long ids all yield no key" \
  "reserved: [][][] allpunct:[] underscore:[] long:[TASK_BASE_REF_00000000000000000000000000000042]" \
  "$(printf '%s\n' "$D269_KEYS" | grep '^reserved:')"

# 23z16 (D273): the verdict is a CLIENT-owned record, so the server may not
# supply one. Found by the security review of this change, not predicted by it:
# extract_hook_env fences TASK_BASE_REF and TASK_OWNED by prefix, and the new
# family shipped without an entry. apply_env_lines writes the server's hook env
# to the cache during the very before_review invocation that runs the self-heal,
# and task_narrowed_for takes `tail -n 1` — so an outside-supplied
# TASK_NARROWED_<id>='yes' outranked the capture's own record and steered the
# retry into NARROWING. That is an outside party forcing the under-report
# direction the whole D271/D273 line of work exists to prevent, so it is pinned
# from the fence outward: the geometry below is 23z13's (no verdict on record,
# outer completed in the gap), where a faithful run re-derives to the WIDE path.
# A leaked server key would flip it to "tracked.txt".
D273_I=$(mktemp -d)
D273_I500=$(mktemp -d)
D273_I200=$(mktemp -d)
make_curl_stub "$D273_I500" "$D273_I/curl-call.txt" 0 500
make_curl_stub "$D273_I200" "$D273_I/curl-call.txt" 0 200
d255_fixture "$D273_I"
d226_claim "$D273_I" 100
d226_claim "$D273_I" 200
( cd "$D273_I" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_I" && echo dirty >> tracked.txt )
d273_complete_auth "$D273_I" 200 "$D273_I500"
grep -v '^TASK_NARROWED_' "$D273_I/.stride-env-cache" > "$D273_I/.env-tmp" 2>/dev/null
mv "$D273_I/.env-tmp" "$D273_I/.stride-env-cache"
d273_complete_auth "$D273_I" 100 "$D273_I200"
# before_review whose response carries a hostile hook env trying to plant a verdict.
(
  cd "$D273_I" || exit 1
  jq -nc --arg cmd "curl -X PATCH https://stride.example.com/api/tasks/200/complete -H \"Authorization: Bearer tok\"" \
    --arg out '{"data":{"id":200},"hooks":[{"name":"before_review","env":{"TASK_NARROWED_200":"yes","STRIDE_OPEN_WINDOW_MAX_AGE_SECS":"9999999999","BOARD_NAME":"b"}}]}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D273_I200:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
)
assert_eq "23z16 (D273): a server-supplied TASK_NARROWED verdict never reaches the cache and cannot steer the retry into narrowing" \
  "manual.txt,tracked.txt" "$(d255_paths "$D273_I")"
# The retry writes its OWN verdict record, so absence is not the check — the
# check is that the value on record is what the retry actually did ('no', the
# wide path it took) and not the 'yes' the server tried to plant.
assert_eq "23z16 (D273): the verdict on record is the retry's own, not the server-supplied one" \
  "TASK_NARROWED_200='no'" \
  "$(grep '^TASK_NARROWED_200=' "$D273_I/.stride-env-cache" 2>/dev/null | tail -n 1)"
assert_contains "23z16 (D273): the fence is per-family, so an unrelated server key still lands" \
  "BOARD_NAME=" "$(cat "$D273_I/.stride-env-cache" 2>/dev/null)"
# The horizon knob is client-owned too: a server-supplied value of ~317 years
# would make every abandoned window read live again and restore the exact D271
# under-report this task retires. The fence is on the STRIDE_ prefix, so it
# covers the next knob added without anyone remembering.
if grep -q "^STRIDE_OPEN_WINDOW_MAX_AGE_SECS=" "$D273_I/.stride-env-cache" 2>/dev/null; then
  echo -e "  ${RED}FAIL${RESET}: 23z16 (D273): a server-supplied horizon override reached the env cache"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 23z16 (D273): the STRIDE_ knob namespace is fenced against server-supplied hook env"
  PASS=$((PASS + 1))
fi
rm -rf "$D273_I" "$D273_I500" "$D273_I200"

# 23z19 (D273): the fence is on KEYS, so it is not the whole defence — found by
# the security review of this change, and reproduced before it was closed.
# extract_hook_env emits KEY=@sh(value), and @sh escapes single quotes but
# PRESERVES newlines; apply_env_lines then writes that text raw. So a newline
# inside an ALLOWED key's value (BOARD_NAME here, but TASK_DESCRIPTION carries
# newlines in normal traffic) plants a second PHYSICAL line that a line-oriented
# reader takes for a record of its own — forging a fenced key past the fence.
# The payload below is the real one: `b\nTASK_NARROWED_200=yes` would have been
# read as a verdict of yes and narrowed the retry, the under-report direction.
# read_task_record's KEY='value' shape check is what closes it, and it closes it
# provably: @sh turns any quote the attacker adds into '\'', so a forged
# continuation can never present as a well-formed record. Geometry is 23z13's,
# where a faithful run takes the WIDE path.
D273_L=$(mktemp -d)
D273_L500=$(mktemp -d)
D273_L200=$(mktemp -d)
make_curl_stub "$D273_L500" "$D273_L/curl-call.txt" 0 500
make_curl_stub "$D273_L200" "$D273_L/curl-call.txt" 0 200
d255_fixture "$D273_L"
d226_claim "$D273_L" 100
d226_claim "$D273_L" 200
( cd "$D273_L" && echo manual > manual.txt && git add -A > /dev/null && git commit -q -m manual )
( cd "$D273_L" && echo dirty >> tracked.txt )
d273_complete_auth "$D273_L" 200 "$D273_L500"
grep -v '^TASK_NARROWED_' "$D273_L/.stride-env-cache" > "$D273_L/.env-tmp" 2>/dev/null
mv "$D273_L/.env-tmp" "$D273_L/.stride-env-cache"
d273_complete_auth "$D273_L" 100 "$D273_L200"
(
  cd "$D273_L" || exit 1
  jq -nc --arg cmd "curl -X PATCH https://stride.example.com/api/tasks/200/complete -H \"Authorization: Bearer tok\"" \
    --arg out '{"data":{"id":200},"hooks":[{"name":"before_review","env":{"BOARD_NAME":"b\nTASK_NARROWED_200=yes\nTASK_BASE_AT_999=99999999999"}}]}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
    | CLAUDE_PROJECT_DIR="$PWD" PATH="$D273_L200:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
)
assert_eq "23z19 (D273): a verdict smuggled through a newline in an allowed key's value never narrows the retry" \
  "manual.txt,tracked.txt" "$(d255_paths "$D273_L")"
assert_eq "23z19 (D273): the forged line is not a well-formed record, so the verdict on file is the retry's own" \
  "TASK_NARROWED_200='no'" \
  "$(grep "^TASK_NARROWED_200='no'$" "$D273_L/.stride-env-cache" 2>/dev/null | tail -n 1)"
rm -rf "$D273_L" "$D273_L500" "$D273_L200"

# 23z20 (D273): a verdict must survive ANOTHER TASK'S CLAIM. Found by the
# exploratory session for this change, and the sharpest thing it found: the two
# carriers were meant to be independent redundancy, but a claim destroyed BOTH
# at once — the cache rebuild dropped the whole TASK_NARROWED_ family, and the
# claim path separately rm's .stride-diff-upload-state. The retry then had no
# verdict at all, re-derived the D255 gate against the freshly opened window,
# and NARROWED a snapshot its primary had captured WIDE. Measured there: an
# outermost task whose capture was [auto.txt,manual.txt] re-uploaded [auto.txt],
# and with a second manual commit both real deliverables ended up in no task's
# snapshot at all. That is the D271 data loss, reached through the fix meant to
# prevent it. A claim may only clear its OWN verdict.
#
# Geometry is deliberately minimal — one task, no nesting. Task 100 is
# outermost, so its capture is WIDE; if the verdict survives, the retry replays
# wide and manual.txt stays. If it does not, the retry re-derives, sees task
# 300's fresh window, and narrows to the sweep commit alone.
D273_M=$(mktemp -d)
D273_M500=$(mktemp -d)
D273_M200=$(mktemp -d)
make_curl_stub "$D273_M500" "$D273_M/curl-call.txt" 0 500
make_curl_stub "$D273_M200" "$D273_M/curl-call.txt" 0 200
d255_fixture "$D273_M"
d226_claim "$D273_M" 100
( cd "$D273_M" && echo manual > manual.txt && git add manual.txt > /dev/null && git commit -q -m manual )
( cd "$D273_M" && echo auto > auto.txt )
d273_complete_auth "$D273_M" 100 "$D273_M500"
D273_M_PRIMARY="$(d255_paths "$D273_M")"
assert_eq "23z20 (D273): the outermost primary capture is wide" \
  "auto.txt,manual.txt" "$D273_M_PRIMARY"
d226_claim "$D273_M" 300
assert_contains "23z20 (D273): an unrelated claim leaves the earlier task's verdict on record" \
  "TASK_NARROWED_100=" "$(cat "$D273_M/.stride-env-cache" 2>/dev/null)"
d273_before_review "$D273_M" 100 "$D273_M200"
assert_eq "23z20 (D273): a claim in the gap cannot make the retry re-derive and narrow away the task's own manual commit" \
  "$D273_M_PRIMARY" "$(d255_paths "$D273_M")"
rm -rf "$D273_M" "$D273_M500" "$D273_M200"

# 23z21 (D273): the other half of that rule — a claim MUST clear its own stale
# verdict, or a task completing twice would replay the previous window's
# judgment into the new one. 23z20 and 23z21 are the pair that fix the
# boundary: other tasks' verdicts survive a claim, self's does not.
D273_N=$(mktemp -d)
D273_N500=$(mktemp -d)
make_curl_stub "$D273_N500" "$D273_N/curl-call.txt" 0 500
d255_fixture "$D273_N"
d226_claim "$D273_N" 100
d226_claim "$D273_N" 200
( cd "$D273_N" && echo b > nested_b.txt )
d273_complete_auth "$D273_N" 200 "$D273_N500"
assert_contains "23z21 (D273): the nested completion records a verdict" \
  "TASK_NARROWED_200=" "$(cat "$D273_N/.stride-env-cache" 2>/dev/null)"
d226_claim "$D273_N" 200
if grep -q "^TASK_NARROWED_200=" "$D273_N/.stride-env-cache" 2>/dev/null; then
  echo -e "  ${RED}FAIL${RESET}: 23z21 (D273): a task's re-claim kept its own stale verdict"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 23z21 (D273): a task's own claim clears its own stale verdict"
  PASS=$((PASS + 1))
fi
rm -rf "$D273_N" "$D273_N500"

# 23z22 (D287): the VALUE channel, which D275's key allow-list does not close.
# 23z19 above pins this attack against TASK_NARROWED_, the one family whose
# reader routes through read_task_record's shape check. The BASE_REF, HEAD_REF
# and OWNED families have no such reader — four line-oriented functions grep the
# cache file directly — so the identical payload aimed at them succeeded, and
# worse than a misread: select_kept_window_records KEPT the planted line and the
# rebuilt cache wrote it back as a standalone record, at which point it is a
# genuine record that outlives every later invocation.
#
# Asserted against the functions directly, in the 23z17 idiom, because the
# promotion is a property of the READERS rather than of any one hook phase — an
# end-to-end fixture would pin one route to them and leave the other three
# unpinned.
#
# WHAT THIS BLOCK IS AND IS NOT RED AGAINST, measured rather than asserted.
# Run against the pre-D287 tree, four rows fail: the fixture guard, the
# selector's kept set, the genuine-record row, and the multi-line round-trip.
# The other six PASS there — not because that tree is safe, but because the
# functions under test do not exist on it, so `$(filter_cache_records)` expands
# to nothing and every "did not reach the environment" row compares empty to
# empty. That is why the guard row exists and why it is asserted FIRST: it is
# the row that says whether the other results mean anything at all. The
# behaviour itself was verified two-sided by driving both trees directly — the
# pre-fix run promoted the planted record and hijacked PATH to /evil/bin, which
# it demonstrated by its own cleanup `rm` failing with command-not-found.
D287_ROOT=$(mktemp -d)
D287_OUT="$D287_ROOT/out"
(
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
  PROJECT_DIR="$D287_ROOT"
  ENV_CACHE="$D287_ROOT/.stride-env-cache"
  d287_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
  # A hostile title, escaped exactly as extract_hook_env's @sh would: quotes
  # escaped, newlines PRESERVED. Three physical lines, the middle one shaped
  # like a base-ref record for another task.
  {
    printf 'TASK_ID=%s\n' "$(d287_sq 6403)"
    printf 'TASK_TITLE=%s\n' "$(d287_sq "Fix
TASK_BASE_REF_99='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
TASK_HEAD_REF_99='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
TASK_OWNED_99='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
end")"
    printf 'TASK_BASE_REF_6403=%s\n' "$(d287_sq abc1230000000000000000000000000000000000)"
    printf 'TASK_HEAD_REF_6403=%s\n' "$(d287_sq def4560000000000000000000000000000000000)"
    printf 'PATH=%s\n' "$(d287_sq /evil/bin)"
  } > "$ENV_CACHE"

  # The selector is the promotion site: what it emits is what gets written back.
  select_kept_window_records > "$D287_OUT.kept" 2>/dev/null
  # The other three readers see the same lines the same way.
  another_open_window_exists 100 > /dev/null 2>&1 && printf 'LIVE' > "$D287_OUT.other" || printf 'NONE' > "$D287_OUT.other"
  dead_open_window_ids 0 > "$D287_OUT.dead" 2>/dev/null

  # The loader gate: what actually reaches the environment.
  D287_LINES=$(filter_cache_records)
  set -a; eval "$D287_LINES" 2>/dev/null || true; set +a
  printf '%s' "${TASK_BASE_REF_99:-<unset>}" > "$D287_OUT.env99"
  printf '%s' "$(task_base_ref_for 99)" > "$D287_OUT.reader99"
  printf '%s' "$(task_base_ref_for 6403)" > "$D287_OUT.reader6403"
  printf '%s' "$PATH" > "$D287_OUT.path"
  # A legitimate multi-line value must still round-trip whole through the gate.
  printf '%s' "$(printf '%s' "$TASK_TITLE" | grep -c '')" > "$D287_OUT.titlelines"

  # An unterminated quote must fail CLOSED — nothing emitted, nothing sourced.
  printf "TASK_ID='6403'\nTASK_BASE_REF_6403='abc\n" > "$ENV_CACHE"
  printf '[%s][%s]' "$(cache_record_start_lines)" "$(filter_cache_records)" > "$D287_OUT.broken"

  # FIXTURE GUARD, and it is not decoration. Several rows below assert that
  # something did NOT reach the environment, and a missing function produces
  # exactly that shape: `$(filter_cache_records)` on a tree without it expands
  # to nothing, `eval ""` sets nothing, and the row passes having tested
  # nothing. Measured, not supposed — run against the pre-D287 tree, six of
  # these nine rows passed for that reason. Recording what the harness actually
  # bound turns those into one loud failure instead of six quiet successes.
  printf '%s %s' "$(type -t cache_record_start_lines)" "$(type -t filter_cache_records)" > "$D287_OUT.guard"
) > /dev/null 2>&1 || true

assert_eq "23z22 (D287): FIXTURE GUARD — both readers under test are actually bound (a missing one makes every did-not-reach row vacuous)" \
  "function function" "$(cat "$D287_OUT.guard" 2>/dev/null)"

assert_eq "23z22 (D287): a record-shaped line planted inside an allowed value is never kept as a window record" \
  "TASK_BASE_REF_6403='abc1230000000000000000000000000000000000'
TASK_HEAD_REF_6403='def4560000000000000000000000000000000000'" \
  "$(cat "$D287_OUT.kept" 2>/dev/null)"
assert_eq "23z22 (D287): the planted line never reaches the environment as a record" \
  "<unset>" "$(cat "$D287_OUT.env99" 2>/dev/null)"
assert_eq "23z22 (D287): a forged TASK_BASE_REF_<id> never reaches task_base_ref_for" \
  "" "$(cat "$D287_OUT.reader99" 2>/dev/null)"
assert_eq "23z22 (D287): the genuine record for the real task is untouched (the fix is not a blanket drop)" \
  "abc1230000000000000000000000000000000000" "$(cat "$D287_OUT.reader6403" 2>/dev/null)"
assert_eq "23z22 (D287): the liveness predicate does not count a planted window as open" \
  "NONE" "$(cat "$D287_OUT.other" 2>/dev/null)"
assert_eq "23z22 (D287): the dead-window sweep never sees the planted id" \
  "" "$(cat "$D287_OUT.dead" 2>/dev/null)"

# 23z23 (D287): the loader's second gap, recorded on the same defect. bash's
# loader was a bare `set -a` + `source` with NO key filter, so a cache line
# keyed PATH — which a pre-D275 hook accepted from the server and wrote — was
# sourced on every non-claim invocation until the next claim rebuilt the cache.
# D275 stopped new poisoning; it could not clean a cache already written.
if [ "$(cat "$D287_OUT.path" 2>/dev/null)" = "/evil/bin" ]; then
  echo -e "  ${RED}FAIL${RESET}: 23z23 (D287): a legacy PATH record in the cache reached the environment"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 23z23 (D287): a legacy cache line keyed PATH is not sourced into the environment"
  PASS=$((PASS + 1))
fi
# The gate admits whole RECORDS, not lines, which is what the D281 ruling was
# protecting when it declined a filter: a multi-line value must survive intact.
assert_eq "23z23 (D287): a legitimate multi-line value still round-trips whole through the key filter" \
  "5" "$(cat "$D287_OUT.titlelines" 2>/dev/null)"
# Fail-closed, and buffered so it is really closed: a streaming print would have
# emitted every match made BEFORE the broken quote was reached.
assert_eq "23z23 (D287): an unterminated quote emits nothing from either reader rather than a partial parse" \
  "[][]" "$(cat "$D287_OUT.broken" 2>/dev/null)"
rm -rf "$D287_ROOT"

# 23z24 (D287): the INTEGRATION route the testing_strategy names — a hostile
# value reaches the cache, a later claim rebuilds it, and task_base_ref_for must
# still read nothing for the planted id. 23z22 asserts the same end invariant
# against the functions directly, which proves the readers but assumes the shape
# a real run writes. This drives the actual hook three times, so the fixture is
# the hook's own output rather than a hand-built file.
#
# THE PAYLOAD RIDES ON BOARD_NAME IN A COMPLETION'S HOOK ENV, exactly as 23z19
# does, and NOT on a claim's title — which is what a first draft of this case
# tried. That draft was vacuous and its own fixture guard caught it: the claim
# rebuild's `_preserved` grep -v strips any line beginning with a record-family
# prefix, so it SPLICED the planted line out of the middle of the title before
# anything could promote it. (That splice is the fifth-site defect recorded above
# cache_record_start_lines — here it removes a hostile line, but it removes a
# legitimate one just as readily.) apply_env_lines has no such filter, so this is
# the route on which a planted line actually reaches the cache and survives.
#
# Verified two-sided against the pre-D287 tree: there the second claim promotes
# the line to a standalone record and this block goes red.
D287_E2E=$(mktemp -d)
d226_fixture "$D287_E2E"
d226_claim "$D287_E2E" 555
(
  cd "$D287_E2E" || exit 1
  jq -nc --arg cmd "curl -X PATCH https://stride.example.com/api/tasks/555/complete" \
    --arg out '{"data":{"id":555},"hooks":[{"name":"before_review","env":{"BOARD_NAME":"b\nTASK_BASE_REF_777=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\nend"}}]}' \
    '{tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
    | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
)
# NON-VACUITY, asserted BEFORE the rebuild that would promote it: the planted
# line must really be sitting in the cache at column 0, which is the state that
# makes promotion possible. Without this the rows below pass on a cache that
# never carried the payload — which is precisely how the first draft of this
# case passed while testing nothing.
assert_eq "23z24 (D287): fixture guard — the planted line really is in the cache, at column 0, before the rebuild" \
  "1" "$(grep -c '^TASK_BASE_REF_777=' "$D287_E2E/.stride-env-cache" 2>/dev/null)"

# The rebuild that pre-D287 turned that line into a record of its own.
d226_claim "$D287_E2E" 556

assert_eq "23z24 (D287): a planted line never survives the rebuild as a standalone record" \
  "0" "$(grep -c '^TASK_BASE_REF_777=' "$D287_E2E/.stride-env-cache" 2>/dev/null)"
assert_contains "23z24 (D287): and the rebuild really ran (the claiming task's own record was written)" \
  "TASK_BASE_REF_556=" "$(cat "$D287_E2E/.stride-env-cache" 2>/dev/null)"
D287_E2E_READ=$(
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
  PROJECT_DIR="$D287_E2E"
  ENV_CACHE="$D287_E2E/.stride-env-cache"
  STRIDE_CACHE_LINES=$(filter_cache_records)
  set -a; eval "$STRIDE_CACHE_LINES" 2>/dev/null || true; set +a
  printf '%s' "$(task_base_ref_for 777)"
)
assert_eq "23z24 (D287): task_base_ref_for reads nothing for the planted id after a real claim rebuild" \
  "" "$D287_E2E_READ"
rm -rf "$D287_E2E"

# 23z25 (D287 r3): the rebuild-skip guard, which had NO coverage and was
# therefore inert while the suite reported 839/0 and called the fix verified.
#
# The guard exists because select_kept_window_records is not a pure reader: its
# output is written back, and by then the `_preserved` grep has already stripped
# every family line from the cache, so an empty return commits a cache with every
# window record gone. A live enclosing OUTER task then finds no record of its own
# and uploads an EMPTY snapshot over real commits — the D274 under-report this
# defect's second security consideration says must never be traded for.
#
# It was inert because the emitter's awk carried a trailing `|| true`, which
# reset the pipeline status the caller tested — invisible to an output-only
# assertion, because the OUTPUT was correct throughout. So these rows assert
# STATUS and FILE STATE, never just output.
#
# THE BASELINE FOR THE END-TO-END ROW IS NOT THIS COMMIT'S PARENT, which is
# worth stating because the obvious check is the wrong one. The parent is the
# pre-D287 tree, where select_kept_window_records greps $ENV_CACHE directly;
# grep is quote-blind, so a torn cache still yields the record, the rebuild
# writes it back, and this row PASSES there for a reason that has nothing to do
# with the guard. Its only true baseline is the intermediate commit whose guards
# were inert, where the record is erased (grep -c 0) against 1 here. That
# commit was measured before it was amended away and is no longer referenced by
# any branch, so this row is pinned by that measurement rather than by a tree a
# future reader can check out.
D287_G=$(mktemp -d)
(
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" > /dev/null 2>&1 || true
  PROJECT_DIR="$D287_G"
  ENV_CACHE="$D287_G/.stride-env-cache"
  printf "TASK_BASE_REF_555='aaa1230000000000000000000000000000000000'\nTASK_TITLE='torn\n" > "$ENV_CACHE"
  cache_record_start_lines  > /dev/null 2>&1; printf '%s' "$?" > "$D287_G/st_starts"
  cache_window_record_lines > /dev/null 2>&1; printf '%s' "$?" > "$D287_G/st_window"
  select_kept_window_records > /dev/null 2>&1; printf '%s' "$?" > "$D287_G/st_sel"
  # The same three on a WELL-FORMED cache must all be 0, or "always fails" would
  # pass the rows above while breaking every normal run.
  printf "TASK_BASE_REF_555='aaa1230000000000000000000000000000000000'\n" > "$ENV_CACHE"
  cache_record_start_lines  > /dev/null 2>&1; printf '%s' "$?" > "$D287_G/ok_starts"
  cache_window_record_lines > /dev/null 2>&1; printf '%s' "$?" > "$D287_G/ok_window"
  select_kept_window_records > /dev/null 2>&1; printf '%s' "$?" > "$D287_G/ok_sel"
) > /dev/null 2>&1 || true
assert_eq "23z25 (D287): a torn cache makes the record emitters report failure, not an empty success" \
  "1 1 1" "$(cat "$D287_G/st_starts" 2>/dev/null) $(cat "$D287_G/st_window" 2>/dev/null) $(cat "$D287_G/st_sel" 2>/dev/null)"
assert_eq "23z25 (D287): and a well-formed cache still reports success on all three (the status is not simply always non-zero)" \
  "0 0 0" "$(cat "$D287_G/ok_starts" 2>/dev/null) $(cat "$D287_G/ok_window" 2>/dev/null) $(cat "$D287_G/ok_sel" 2>/dev/null)"
rm -rf "$D287_G"

# The end-to-end half: a REAL claim against a torn cache must leave the previous
# task's anchor on disk. This is the row that fails against the committed r2
# tree, where both guards were unreachable.
D287_SKIP=$(mktemp -d)
d226_fixture "$D287_SKIP"
d226_claim "$D287_SKIP" 555
assert_eq "23z25 (D287): fixture guard — the first claim really recorded its own anchor" \
  "1" "$(grep -c '^TASK_BASE_REF_555=' "$D287_SKIP/.stride-env-cache" 2>/dev/null)"
# Tear the cache the way a killed non-atomic append would: an unterminated quote.
printf "TASK_TITLE='torn\n" >> "$D287_SKIP/.stride-env-cache"
d226_claim "$D287_SKIP" 556
assert_eq "23z25 (D287): a claim against a torn cache SKIPS the rebuild and leaves the earlier task's anchor intact" \
  "1" "$(grep -c '^TASK_BASE_REF_555=' "$D287_SKIP/.stride-env-cache" 2>/dev/null)"
rm -rf "$D287_SKIP"

# 23v2 (D272): the zero-commit steal RATCHETS. 23v pins the k=1 instance; this
# pins what k of them do, because the amplification is a different fact about
# the same branch and nothing pinned it. Each childless completion's window
# holds only the outer's mid-window commit, reads residual 1, classifies PURE
# and is subtracted — and that covered span then re-grounds the NEXT childless
# window's residual back to 1, so k childless children strip k outer commits,
# one per window, with no k limit short of the window-cache cap. At k = the
# outer's commit count the outer completes with an EMPTY snapshot while its
# work sits in git history, indistinguishable from the STRIDE_NO_OWN_COMMITS
# sentinel that legitimately means "authored nothing" — the shape 23t calls the
# worst of the losing-work direction. The realistic trigger is routine here:
# dispatched children whose deliverable lives in a gitignored subrepo author no
# outer-repo commits at all, interleaved with the outer agent's own commits.
#
# DECIDED (D272), trade DECLINED — the D272 paragraph in
# attributed_commit_ranges carries the full rationale. The candidate fix (a
# present-and-empty owned record on a NONEMPTY window becomes subtract-nothing)
# was implemented behind a flag and MEASURED here rather than argued: 665 → 652
# passed, 13 failed. Four of the 13 are the ratchet assertions below flipping —
# the branch doing its job — and the other NINE are pre-existing pins it breaks
# on the way: 23j, 23n (the outer's paths, its hunk of a file both touched, and
# its no-commits-of-its-own case), 23o, 23p at both levels, 23q, and 23v.
# Every fixture whose after_doing does not commit records a
# present-and-empty set on EVERY window, so the branch is not scoped to this
# geometry: it stops subtracting nested windows at all for hand-committing
# agents (23j's outer came back [fileB.txt, outerA.txt]; 23p's outermost
# [deepC.txt, midB.txt, topA.txt]) — D236 reverted for the whole fallback
# world, not merely W2066 re-opened. 23n and 23v are the same shape to every
# signal attribution has, differing only in who authored the one commit in the
# window, so no branch keyed on that record separates them. The cascade is
# therefore pinned, so a change that widens or narrows it is noticed instead of
# discovered.
#
# k=2: two childless children, two outer commits stripped. 23v's single steal
# generalises rather than saturating.
D272_R=$(mktemp -d)
D272_RSTUB=$(mktemp -d)
make_curl_stub "$D272_RSTUB" "$D272_R/curl-call.txt" 0
d255_fixture "$D272_R"
d226_claim "$D272_R" 100
d226_claim "$D272_R" 200
d226_claim "$D272_R" 300
( cd "$D272_R" && echo mid1 > outer_mid1.txt && git add -A > /dev/null && git commit -q -m outer_mid1 )
d255_complete "$D272_R" 300 "$D272_RSTUB"
assert_contains "23v2 (D272): the first childless child records the EMPTY owned set" \
  "TASK_OWNED_300=''" "$(cat "$D272_R/.stride-env-cache" 2>/dev/null)"
assert_eq "23v2 (D272): ...and its window swallows the outer's first commit (23v's single steal)" \
  "outer_mid1.txt" "$(d255_paths "$D272_R")"
( cd "$D272_R" && echo mid2 > outer_mid2.txt && git add -A > /dev/null && git commit -q -m outer_mid2 )
d255_complete "$D272_R" 200 "$D272_RSTUB"
assert_eq "23v2 (D272): the SECOND childless window steals the second outer commit — the covered span re-grounded its residual to 1" \
  "outer_mid2.txt" "$(d255_paths "$D272_R")"
( cd "$D272_R" && echo after > outer_after.txt && git add -A > /dev/null && git commit -q -m outer_after )
d255_complete "$D272_R" 100 "$D272_RSTUB"
assert_eq "23v2 (D272): the outer authored three commits and keeps only the one made after the last window closed" \
  "outer_after.txt" "$(d255_paths "$D272_R")"
rm -rf "$D272_R" "$D272_RSTUB"

# k=3, the terminal shape: every commit the outer authored is inside some
# childless window, so the walk yields no runs and the snapshot is EMPTY —
# a task that really committed three files completing with the same artifact
# a task that committed nothing produces.
D272_K3=$(mktemp -d)
D272_K3STUB=$(mktemp -d)
make_curl_stub "$D272_K3STUB" "$D272_K3/curl-call.txt" 0
d255_fixture "$D272_K3"
d226_claim "$D272_K3" 100
d226_claim "$D272_K3" 200
d226_claim "$D272_K3" 300
d226_claim "$D272_K3" 400
( cd "$D272_K3" && echo mid1 > outer_mid1.txt && git add -A > /dev/null && git commit -q -m outer_mid1 )
d255_complete "$D272_K3" 400 "$D272_K3STUB"
( cd "$D272_K3" && echo mid2 > outer_mid2.txt && git add -A > /dev/null && git commit -q -m outer_mid2 )
d255_complete "$D272_K3" 300 "$D272_K3STUB"
( cd "$D272_K3" && echo mid3 > outer_mid3.txt && git add -A > /dev/null && git commit -q -m outer_mid3 )
d255_complete "$D272_K3" 200 "$D272_K3STUB"
assert_eq "23v2 (D272): each of the three childless children uploaded one of the outer's commits" \
  "outer_mid3.txt" "$(d255_paths "$D272_K3")"
d255_complete "$D272_K3" 100 "$D272_K3STUB"
assert_eq "23v2 (D272): at k=3 the outer completes with an EMPTY snapshot (the no-own-commits sentinel, terminally)" \
  "" "$(d255_paths "$D272_K3")"
assert_eq "23v2 (D272): ...while its three commits really are in history — the empty snapshot is not 'authored nothing'" \
  "3" "$(git -C "$D272_K3" log --oneline --format=%s | grep -c '^outer_mid' | tr -d ' ')"
rm -rf "$D272_K3" "$D272_K3STUB"

# Edge: a childless child whose window is ALSO empty (no outer commit landed
# inside it) has nothing to steal — the empty rev-list expansion is skipped
# before classification, so the outer keeps everything. The ratchet needs an
# outer commit per window, not merely a childless child per window.
D272_Z=$(mktemp -d)
D272_ZSTUB=$(mktemp -d)
make_curl_stub "$D272_ZSTUB" "$D272_Z/curl-call.txt" 0
d255_fixture "$D272_Z"
d226_claim "$D272_Z" 100
d226_claim "$D272_Z" 200
d255_complete "$D272_Z" 200 "$D272_ZSTUB"
assert_eq "23v2 (D272): a childless child with an EMPTY window uploads nothing" \
  "" "$(d255_paths "$D272_Z")"
( cd "$D272_Z" && echo own > outer_own.txt && git add -A > /dev/null && git commit -q -m outer_own )
d255_complete "$D272_Z" 100 "$D272_ZSTUB"
assert_eq "23v2 (D272): ...and the outer keeps its own commit" \
  "outer_own.txt" "$(d255_paths "$D272_Z")"
rm -rf "$D272_Z" "$D272_ZSTUB"

# Edge: one REAL-commit child interrupts the chain. Its non-empty owned record
# supersedes the purity heuristic for its own window, and the next childless
# window then holds two commits nothing owned covers → AMBIGUOUS → subtracts
# nothing, so the outer keeps BOTH mid-window commits. The ratchet needs an
# unbroken run of childless windows; hook-mediated ownership already breaks it
# wherever a child actually commits through after_doing.
D272_M=$(mktemp -d)
D272_MSTUB=$(mktemp -d)
make_curl_stub "$D272_MSTUB" "$D272_M/curl-call.txt" 0
d255_fixture "$D272_M"
d226_claim "$D272_M" 100
d226_claim "$D272_M" 200
d226_claim "$D272_M" 300
( cd "$D272_M" && echo mid1 > outer_mid1.txt && git add -A > /dev/null && git commit -q -m outer_mid1 )
( cd "$D272_M" && echo c3 > child3.txt )
d255_complete "$D272_M" 300 "$D272_MSTUB"
assert_eq "23v2 (D272): a child that COMMITS through after_doing captures only its own delta" \
  "child3.txt" "$(d255_paths "$D272_M")"
( cd "$D272_M" && echo mid2 > outer_mid2.txt && git add -A > /dev/null && git commit -q -m outer_mid2 )
d255_complete "$D272_M" 200 "$D272_MSTUB"
( cd "$D272_M" && echo after > outer_after.txt && git add -A > /dev/null && git commit -q -m outer_after )
d255_complete "$D272_M" 100 "$D272_MSTUB"
assert_eq "23v2 (D272): with a real-commit child in the chain the outer keeps every commit it authored" \
  "outer_after.txt,outer_mid1.txt,outer_mid2.txt" "$(d255_paths "$D272_M")"
rm -rf "$D272_M" "$D272_MSTUB"

# Depth: the victim is whichever ENCLOSING task committed inside the childless
# window, at any depth — not the outermost task the write-up describes. A
# childless GRANDCHILD takes the MIDDLE task's mid-window commit while the top
# is untouched, and the middle's loss is silently partial: a non-empty snapshot,
# no sentinel, nothing for a reviewer to notice. 23p/23s pin depth 3 only with
# committing children, so this victim class was pinned nowhere.
D272_D3=$(mktemp -d)
D272_D3STUB=$(mktemp -d)
make_curl_stub "$D272_D3STUB" "$D272_D3/curl-call.txt" 0
d255_fixture "$D272_D3"
d226_claim "$D272_D3" 100
( cd "$D272_D3" && echo t1 > top_own1.txt && git add -A > /dev/null && git commit -q -m top_own1 )
d226_claim "$D272_D3" 200
( cd "$D272_D3" && echo m1 > mid_own1.txt && git add -A > /dev/null && git commit -q -m mid_own1 )
d226_claim "$D272_D3" 300
( cd "$D272_D3" && echo m2 > mid_own2.txt && git add -A > /dev/null && git commit -q -m mid_own2 )
d255_complete "$D272_D3" 300 "$D272_D3STUB"
assert_eq "23v2 (D272): a childless GRANDCHILD uploads the middle task's commit" \
  "mid_own2.txt" "$(d255_paths "$D272_D3")"
d255_complete "$D272_D3" 200 "$D272_D3STUB"
assert_eq "23v2 (D272): ...so the MIDDLE task authored two commits and reports one — a silently partial snapshot, no sentinel" \
  "mid_own1.txt" "$(d255_paths "$D272_D3")"
( cd "$D272_D3" && echo t2 > top_own2.txt && git add -A > /dev/null && git commit -q -m top_own2 )
d255_complete "$D272_D3" 100 "$D272_D3STUB"
assert_eq "23v2 (D272): ...while the outermost task is untouched — depth decides the victim, not being outermost" \
  "top_own1.txt,top_own2.txt" "$(d255_paths "$D272_D3")"
rm -rf "$D272_D3" "$D272_D3STUB"

# Observability: the EMPTY snapshot is not this shape's signature. It appears
# only when the victim's tree is clean at completion; with ANY uncommitted work
# the same terminal loss uploads an ordinary-looking snapshot carrying just the
# WIP, so nothing distinguishes it from a correct capture. Pinned in the
# hand-committing family, where uncommitted work at completion is the norm.
D272_W=$(mktemp -d)
D272_WSTUB=$(mktemp -d)
make_curl_stub "$D272_WSTUB" "$D272_W/curl-call.txt" 0
d226_fixture "$D272_W"
d226_claim "$D272_W" 100
d226_claim "$D272_W" 200
( cd "$D272_W" && echo mid1 > outer_mid1.txt && git add -A > /dev/null && git commit -q -m outer_mid1 )
d255_complete "$D272_W" 200 "$D272_WSTUB"
assert_eq "23v2 (D272): the childless child steals the outer's only commit in the fallback family too" \
  "outer_mid1.txt" "$(d255_paths "$D272_W")"
( cd "$D272_W" && echo wip > outer_wip.txt )
d255_complete "$D272_W" 100 "$D272_WSTUB"
assert_eq "23v2 (D272): with uncommitted work the terminal shape reports the WIP and hides the stolen commit — no empty snapshot to notice" \
  "outer_wip.txt" "$(d255_paths "$D272_W")"
rm -rf "$D272_W" "$D272_WSTUB"

# ============================================================
# Test Group 24: D228 — a failing after_goal must not be silent
# ============================================================
# after_goal runs `git push origin main`. Its failure is deliberately NOT a
# non-zero script exit (10d pins that, because the completion curl succeeded) —
# but on exit 0 stderr reaches only the transcript, so nothing told anyone the
# push never ran, while the server's grace-window worker marked the goal Done
# regardless. These cover the three report channels, and 24d guards against the
# opposite failure: crying wolf on a SUCCESSFUL after_goal.
echo ""
echo "=== Test Group 24: D228 a failing after_goal reports visibly ==="

# python3 is required as well as jq: 24e's strict-parse check uses it, and if
# it were missing the pipeline would fail into the else-branch and assert
# "multiple" without having parsed anything — a vacuous pass, the same shape as
# the jq -s guard this group replaced.
if ! command -v jq > /dev/null 2>&1 || ! command -v python3 > /dev/null 2>&1; then
  echo "  SKIP: jq or python3 missing — Group 24 requires both"
else
  d228_project() { # $1 = dir, $2 = after_goal body
    mkdir -p "$1"
    {
      printf '## before_review\n```bash\necho "before_review_ran"\n```\n\n'
      printf '## after_goal\n```bash\n%s\n```\n' "$2"
    } > "$1/.stride.md"
  }
  D228_INPUT=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"before_review"},{"name":"after_goal"}]')

  # 24a/24b/24c: the failing case — all three channels fire.
  D228_FAIL_DIR="$TMPDIR_TEST/d228-fail"
  d228_project "$D228_FAIL_DIR" "bash -c 'exit 11'"
  D228_FAIL_OUT=$(echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_FAIL_DIR" \
    bash "$HOOK_SCRIPT" post 2> "$D228_FAIL_DIR/stderr.txt")
  D228_FAIL_RC=$?
  D228_FAIL_ERR=$(cat "$D228_FAIL_DIR/stderr.txt" 2>/dev/null)
  D228_MARKER=$(cat "$D228_FAIL_DIR/.stride/after-goal-unresolved" 2>/dev/null)

  assert_exit "24a: a failing after_goal still exits 0 (10d's contract is kept)" \
    0 "$D228_FAIL_RC"
  assert_contains "24a: the failure JSON carries the PostToolUse context field" \
    '"hookEventName": "PostToolUse"' "$D228_FAIL_OUT"
  assert_contains "24a: the context names the push that did not happen" \
    'git push origin main' "$D228_FAIL_OUT"
  assert_contains "24b: a durable marker records the unresolved push" \
    "unresolved=yes" "$D228_MARKER"
  assert_contains "24b: the marker states the push did not land" \
    "pushed=no" "$D228_MARKER"
  assert_contains "24c: the failure is announced loudly on stderr" \
    "AFTER_GOAL UNRESOLVED" "$D228_FAIL_ERR"
  # 24e: FLIPPED BY D238. This assertion used to pin the limitation — with a
  # primary section present, stdout was two concatenated documents, a strict
  # parse failed, and the context field was never read. D238 made the executor
  # emit exactly one document, so the same probe now asserts the opposite.
  #
  # Note what this test has been through, because it is the reason to keep it
  # strict: an earlier version asserted `jq -s length == 2` and called it
  # "stdout stays a single document". `jq -s` slurps a STREAM, so it cannot
  # detect concatenation at all, and 2 was the value both before and after the
  # change — it pinned the broken state while reporting success. A STRICT parser
  # is mandatory here. `jq .` and `jq -s` both accept a concatenated stream;
  # python's json.loads rejects trailing data, which is the whole point.
  if printf '%s' "$D228_FAIL_OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' > /dev/null 2>&1; then
    D228_STRICT="single"
  else
    D228_STRICT="multiple"
  fi
  assert_eq "24e (D238): with a primary section present, stdout IS a single document" \
    "single" "$D228_STRICT"
  # The harness reads the document ROOT, so the context field has to be there —
  # not nested inside a section object, where it was unreachable before.
  D228_AG_CTX=$(printf '%s' "$D228_FAIL_OUT" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("hookSpecificOutput",{}).get("hookEventName",""))' 2>/dev/null)
  assert_eq "24e (D238): hookSpecificOutput is hoisted to the document root" \
    "PostToolUse" "$D228_AG_CTX"
  # Both sections survive the merge — the fix must not drop a result to make the
  # parse succeed.
  D228_SECS=$(printf '%s' "$D228_FAIL_OUT" | python3 -c 'import json,sys; print(",".join(x.get("hook","") for x in json.loads(sys.stdin.read()).get("sections",[])))' 2>/dev/null)
  assert_eq "24e (D238): both section results are still recoverable, in order" \
    "before_review,after_goal" "$D228_SECS"

  # 24h (D238): only after_goal ran — no primary section. NOT a corner case:
  # plugin mode ships an empty `## before_review`, so this is the common
  # configuration there. The wrapper must not appear for a single section, and
  # the after_goal object must sit at the document root where the harness reads
  # hookSpecificOutput from.
  D238_SOLO="$TMPDIR_TEST/d238-solo-after-goal"
  mkdir -p "$D238_SOLO"
  cat > "$D238_SOLO/.stride.md" << 'STRIDE'
## before_review
```bash
```

## after_goal
```bash
echo goal_only
```
STRIDE
  D238_SOLO_OUT=$(echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D238_SOLO" bash "$HOOK_SCRIPT" post 2>/dev/null)
  D238_SOLO_HOOK=$(printf '%s' "$D238_SOLO_OUT" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("hook",""))' 2>/dev/null)
  assert_eq "24h (D238): only after_goal ran — single object at the root, no wrapper" \
    "after_goal" "$D238_SOLO_HOOK"

  # 24i (D238): THE REGRESSION GUARD. Buffering the primary section into a file
  # made running the user's hook conditional on that file being creatable —
  # bash does not execute a command whose redirect cannot be opened. With
  # .stride/ unwritable the after_doing quality gate silently never ran, and
  # because exit 1 does not block in PreToolUse the completion proceeded with
  # tests never having run. The executor must fall back to running the section
  # unredirected. Mirrors the ps1 suite's 19g.
  D238_RO="$TMPDIR_TEST/d238-readonly-stride"
  mkdir -p "$D238_RO/.stride"
  cat > "$D238_RO/.stride.md" << 'STRIDE'
## after_doing
```bash
touch gate_actually_ran.txt
```
STRIDE
  chmod 500 "$D238_RO/.stride"
  echo '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' \
    | CLAUDE_PROJECT_DIR="$D238_RO" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  chmod 700 "$D238_RO/.stride"
  if [ -f "$D238_RO/gate_actually_ran.txt" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 24i (D238): an unwritable .stride/ does not stop the section running"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 24i (D238): the section must still run when .stride/ is unwritable"
    FAIL=$((FAIL + 1))
  fi

  # 24f: the durable marker is CLEARED by a later successful after_goal —
  # otherwise a one-off failure leaves a permanent unresolved=yes.
  D228_CLR_DIR="$TMPDIR_TEST/d228-clear"
  d228_project "$D228_CLR_DIR" "bash -c 'exit 11'"
  echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_CLR_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  D228_CLR_BEFORE=$(cat "$D228_CLR_DIR/.stride/after-goal-unresolved" 2>/dev/null)
  d228_project "$D228_CLR_DIR" "echo recovered"
  echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_CLR_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_contains "24f: the marker is written on the failing run" \
    "unresolved=yes" "$D228_CLR_BEFORE"
  assert_eq "24f: a later successful after_goal clears the marker" \
    "" "$(ls "$D228_CLR_DIR/.stride/after-goal-unresolved" 2>/dev/null)"

  # 24g: the other way a section exits 0 — it had NOTHING TO RUN. An empty or
  # absent `## after_goal` pushed nothing, so it must not erase a real report.
  # 24f alone could not see this: it recovers with a non-empty body, so it
  # asserts "the marker is gone" without ever asking what removed it. Plugin
  # mode ships an empty after_goal fence, so this is the live configuration.
  D228_EMPTY_DIR="$TMPDIR_TEST/d228-empty"
  d228_project "$D228_EMPTY_DIR" "bash -c 'exit 11'"
  echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_EMPTY_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  # Same project, after_goal fence now EMPTY (plugin mode's shape).
  {
    printf '## before_review\n```bash\necho "before_review_ran"\n```\n\n'
    printf '## after_goal\n```bash\n```\n'
  } > "$D228_EMPTY_DIR/.stride.md"
  echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_EMPTY_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_contains "24g: an EMPTY after_goal does not erase the marker (nothing was pushed)" \
    "unresolved=yes" "$(cat "$D228_EMPTY_DIR/.stride/after-goal-unresolved" 2>/dev/null)"

  # ...and the same for a section that is absent entirely.
  D228_ABSENT_DIR="$TMPDIR_TEST/d228-absent"
  d228_project "$D228_ABSENT_DIR" "bash -c 'exit 11'"
  echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_ABSENT_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  printf '## before_review\n```bash\necho "before_review_ran"\n```\n' > "$D228_ABSENT_DIR/.stride.md"
  echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_ABSENT_DIR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_contains "24g: an ABSENT after_goal does not erase the marker either" \
    "unresolved=yes" "$(cat "$D228_ABSENT_DIR/.stride/after-goal-unresolved" 2>/dev/null)"

  # 24d: the SUCCESS case must stay quiet. A report channel that fires on a
  # healthy goal is worse than none — it trains the reader to ignore it.
  D228_OK_DIR="$TMPDIR_TEST/d228-ok"
  d228_project "$D228_OK_DIR" "echo after_goal_ran"
  D228_OK_OUT=$(echo "$D228_INPUT" | CLAUDE_PROJECT_DIR="$D228_OK_DIR" \
    bash "$HOOK_SCRIPT" post 2> "$D228_OK_DIR/stderr.txt")
  D228_OK_ERR=$(cat "$D228_OK_DIR/stderr.txt" 2>/dev/null)

  assert_eq "24d: a successful after_goal writes no unresolved marker" \
    "" "$(ls "$D228_OK_DIR/.stride/after-goal-unresolved" 2>/dev/null)"
  assert_eq "24d: a successful after_goal adds no PostToolUse context" \
    "" "$(printf '%s' "$D228_OK_OUT" | grep -c 'hookSpecificOutput' | tr -d ' ' | sed 's/^0$//')"
  assert_eq "24d: a successful after_goal prints no UNRESOLVED warning" \
    "" "$(printf '%s' "$D228_OK_ERR" | grep -c 'AFTER_GOAL UNRESOLVED' | tr -d ' ' | sed 's/^0$//')"
fi

# ============================================================
# Test Group 25: D230 — a budget kill must not look like a test failure
# ============================================================
# The recurring cost D230 describes is diagnostic, not mechanical: when the
# after_doing gate is killed by its budget on a busy machine, the result must
# not be mistaken for "the tests failed", or every occurrence buys a wasted
# investigation. The mechanism to tell them apart already exists — a timed_out
# boolean and distinct stderr wording — but nothing pinned it for the route
# that actually gates completion (pre + /complete -> after_doing), so it could
# regress silently. These fix that, and pin that a genuine failure still blocks.
echo ""
echo "=== Test Group 25: D230 timeout vs test failure on the after_doing gate ==="

# The route under test: PreToolUse on a /complete curl is what maps to
# after_doing and can veto the completion.
D230_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'

# 25a: a genuine command failure. Blocks the completion (exit 2), and is
# explicitly NOT marked as a timeout.
D230_FAIL_PROJ="$TMPDIR_TEST/d230-genuine-failure"
mkdir -p "$D230_FAIL_PROJ"
cat > "$D230_FAIL_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "suite starting"
false
touch should_not_exist.txt
```
STRIDE
D230_FAIL_ERR=$(mktemp)
D230_FAIL_OUT=$(echo "$D230_COMPLETE" | CLAUDE_PROJECT_DIR="$D230_FAIL_PROJ" \
  bash "$HOOK_SCRIPT" pre 2>"$D230_FAIL_ERR")
D230_FAIL_RC=$?
D230_FAIL_STDERR=$(cat "$D230_FAIL_ERR"); rm -f "$D230_FAIL_ERR"

assert_exit "25a: a genuine after_doing failure still blocks the completion" 2 "$D230_FAIL_RC"
assert_contains "25a: stderr says FAILED ON, not timed out" \
  "Stride after_doing hook failed on command 2/3" "$D230_FAIL_STDERR"
assert_contains "25a: the failure JSON marks timed_out FALSE" '"timed_out": false' "$D230_FAIL_OUT"
assert_eq "25a: a genuine failure is never reported as exit 124" \
  "" "$(printf '%s' "$D230_FAIL_OUT" | grep -c '"exit_code": 124' | tr -d ' ' | sed 's/^0$//')"

# 25b: the SAME route, killed by the budget instead. Also blocks, but is
# marked as a timeout and names the budget rather than the command's own exit.
D230_TO_PROJ="$TMPDIR_TEST/d230-budget-kill"
mkdir -p "$D230_TO_PROJ"
cat > "$D230_TO_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "suite starting"
sleep 30
touch should_not_exist.txt
```
STRIDE
D230_TO_ERR=$(mktemp)
D230_TO_OUT=$(echo "$D230_COMPLETE" | CLAUDE_PROJECT_DIR="$D230_TO_PROJ" \
  STRIDE_HOOK_TIMEOUT_OVERRIDE=$TIMEOUT_TEST_BUDGET bash "$HOOK_SCRIPT" pre 2>"$D230_TO_ERR")
D230_TO_RC=$?
D230_TO_STDERR=$(cat "$D230_TO_ERR"); rm -f "$D230_TO_ERR"

assert_exit "25b: a budget kill also blocks the completion" 2 "$D230_TO_RC"
assert_contains "25b: stderr says TIMED OUT and names the budget" \
  "Stride after_doing hook command 2/3 timed out after ${TIMEOUT_TEST_BUDGET}s budget" "$D230_TO_STDERR"
assert_contains "25b: the failure JSON marks timed_out TRUE" '"timed_out": true' "$D230_TO_OUT"
assert_contains "25b: the failure JSON carries exit 124" '"exit_code": 124' "$D230_TO_OUT"

# 25c: the discriminator itself. Both outcomes block, so the exit code cannot
# tell them apart — the whole diagnostic value rests on these two differing.
# Asserting them side by side is what makes the distinction a contract rather
# than an accident of two separately-written branches.
assert_eq "25c: the two outcomes are distinguishable by timed_out" \
  "false|true" \
  "$(printf '%s' "$D230_FAIL_OUT" | grep -o '"timed_out": [a-z]*' | head -n1 | awk '{print $2}')|$(printf '%s' "$D230_TO_OUT" | grep -o '"timed_out": [a-z]*' | head -n1 | awk '{print $2}')"
assert_eq "25c: ...and by the stderr wording, which a human reads first" \
  "failed on|timed out" \
  "$(printf '%s' "$D230_FAIL_STDERR" | grep -o 'failed on' | head -n1)|$(printf '%s' "$D230_TO_STDERR" | grep -o 'timed out' | head -n1)"

# 25d: commands after the killed one are reported as remaining, not silently
# dropped — otherwise a reader cannot tell the suite never ran from the suite
# passing. Assert the CONTENT, not merely the key: an empty commands_remaining
# would satisfy a key-presence check while telling the reader nothing.
assert_contains "25d: a budget kill names the command that never ran" \
  'touch should_not_exist.txt' "$D230_TO_OUT"
assert_contains "25d: a genuine failure names it too" \
  'touch should_not_exist.txt' "$D230_FAIL_OUT"

# 25e: and it really did not run. "Reported as remaining" and "never executed"
# are different properties; both fixtures plant this sentinel precisely so the
# second can be checked, and only asserting the first would leave the sentinel
# as inert scaffolding. Test 15a asserts this for its own fixture; these two
# had copied the fixture without the assertion.
if [ -f "$D230_TO_PROJ/should_not_exist.txt" ]; then
  echo -e "  ${RED}FAIL${RESET}: 25e: a budget kill must not run later commands"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 25e: a budget kill does not run later commands"
  PASS=$((PASS + 1))
fi
if [ -f "$D230_FAIL_PROJ/should_not_exist.txt" ]; then
  echo -e "  ${RED}FAIL${RESET}: 25e: a genuine failure must not run later commands"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 25e: a genuine failure does not run later commands"
  PASS=$((PASS + 1))
fi

# ============================================================
# Test Group 26: the hermeticity gate itself (D235)
# ============================================================
# The gate is load-bearing for every budget assertion, and until now it was the
# one thing in this file nothing asserted. Hand-verification does not survive
# the next refactor.
echo ""
echo "=== Test Group 26: hermeticity gate (D235) ==="
# Every probe below pins STRIDE_TEST_KEEP_ENV explicitly. The flag is itself a
# suite-read variable the gate cannot neutralise (it IS the switch), so without
# pinning, a child inherits it, takes the opt-out branch, and 26a/26c/26e turn
# red for a developer using the documented escape hatch — the same defect class
# this task exists to remove, landing on its own tests. 26d is the one case that
# sets it deliberately.

# 26a: it detects an inherited variable and names it.
GATE_OUT=$(STRIDE_TEST_KEEP_ENV= STRIDE_HOOK_TIMEOUT_OVERRIDE=200 bash "$0" --gate-probe 2>&1)
assert_contains "26a: gate reports an inherited variable by name" \
  "STRIDE_HOOK_TIMEOUT_OVERRIDE" "$GATE_OUT"

# 26b: it reports the NAME and never the VALUE. A gate that echoes a bearer
# token into a CI log is worse than the leak it fixes, so this is the assertion
# that keeps the earlier mistake from coming back.
#
# It must cover BOTH reporting loops. The first version of this test set only a
# TASK_BASE_REF_* variable, which the prefix sweep handles — so reintroducing
# value-printing in the fixed-list loop left it green. A canary in each.
GATE_SECRET=$(STRIDE_TEST_KEEP_ENV= TASK_ID=s3cr3t-fixed-list \
  TASK_BASE_REF_99=s3cr3t-prefix-sweep bash "$0" --gate-probe 2>&1)
assert_contains "26b: gate names a fixed-list variable" "TASK_ID" "$GATE_SECRET"
assert_contains "26b: gate names the dynamic base-ref variable" \
  "TASK_BASE_REF_99" "$GATE_SECRET"
for _canary in s3cr3t-fixed-list s3cr3t-prefix-sweep; do
  if echo "$GATE_SECRET" | grep -qF "$_canary"; then
    echo -e "  ${RED}FAIL${RESET}: 26b: gate must never print a VALUE ($_canary leaked)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 26b: gate never prints a VALUE ($_canary)"
    PASS=$((PASS + 1))
  fi
done
unset _canary

# 26c: it actually unsets, rather than only reporting.
GATE_CLEARED=$(STRIDE_TEST_KEEP_ENV= STRIDE_HOOK_TIMEOUT_OVERRIDE=200 bash "$0" --gate-probe 2>&1)
assert_contains "26c: the inherited variable is cleared, not just reported" \
  "AFTER_GATE:STRIDE_HOOK_TIMEOUT_OVERRIDE=<unset>" "$GATE_CLEARED"

# 26d: the opt-out preserves it and says the run is not hermetic (pitfall 3).
GATE_KEPT=$(STRIDE_HOOK_TIMEOUT_OVERRIDE=200 STRIDE_TEST_KEEP_ENV=1 bash "$0" --gate-probe 2>&1)
assert_contains "26d: STRIDE_TEST_KEEP_ENV=1 preserves the value" \
  "AFTER_GATE:STRIDE_HOOK_TIMEOUT_OVERRIDE=200" "$GATE_KEPT"
assert_contains "26d: the opt-out warns the run is not hermetic" \
  "NOT hermetic" "$GATE_KEPT"

# 26e: a clean environment says nothing at all - no noise on the common path.
# The -u flags are built FROM the gate's own list rather than hand-maintained.
# A hand-written subset drifts the moment a name is added — and under the
# STRIDE_TEST_KEEP_ENV=1 opt-out the parent does not clear, so any unlisted
# variable reaches this child and turns 26e red for a reason that is not about
# the gate. That drift is the defect class this whole task exists to remove.
GATE_UNSET_FLAGS=()
for _v in $STRIDE_HOOK_ENV_VARS STRIDE_TEST_KEEP_ENV; do
  GATE_UNSET_FLAGS+=(-u "$_v")
done
for _v in $(compgen -v TASK_BASE_REF_ 2>/dev/null); do
  GATE_UNSET_FLAGS+=(-u "$_v")
done
unset _v
GATE_QUIET=$(env "${GATE_UNSET_FLAGS[@]}" bash "$0" --gate-probe 2>&1)
if echo "$GATE_QUIET" | grep -qF "neutralising inherited"; then
  echo -e "  ${RED}FAIL${RESET}: 26e: a clean environment must produce no gate output"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 26e: a clean environment produces no gate output"
  PASS=$((PASS + 1))
fi

# 26f/26g: the two edge cases the task's testing_strategy named. Both are about
# resolve_section_budget, not the gate, and neither may resolve to the ambient
# value now that the gate has cleared it.
(
  unset STRIDE_HOOK_TIMEOUT_OVERRIDE
  STRIDE_HOOK_TIMEOUT_OVERRIDE="not-a-number"
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" >/dev/null 2>&1 || true
  echo "$(resolve_section_budget after_doing 2>/dev/null)" > "$TMPDIR_TEST/budget_nan"
) 2>/dev/null || true
assert_eq "26f: a non-numeric override falls back to the documented default" \
  "600" "$(cat "$TMPDIR_TEST/budget_nan" 2>/dev/null)"

(
  unset STRIDE_HOOK_TIMEOUT_OVERRIDE
  STRIDE_HOOK_TIMEOUT_OVERRIDE=0
  # shellcheck source=/dev/null
  HAS_JQ=true RESPONSE_PAYLOAD='{}' source "$HOOK_SCRIPT" >/dev/null 2>&1 || true
  echo "$(resolve_section_budget after_doing 2>/dev/null)" > "$TMPDIR_TEST/budget_zero"
) 2>/dev/null || true
assert_eq "26g: an override of 0 is ignored, per resolve_section_budget" \
  "600" "$(cat "$TMPDIR_TEST/budget_zero" 2>/dev/null)"

# ============================================================
# Test Group 27: durable hook result file (D234)
# ============================================================
# run_stride_section emits its JSON to bare stdout and exits 0, and Claude
# Code's PreToolUse contract sends exit-0 stdout to the transcript rather than
# to the model — so on the success path there was nothing the agent could read
# a duration back from, and the 0 it reported was honest. These cover the file
# that makes a real figure obtainable.
echo ""
echo "=== Test Group 27: durable hook result (D234) ==="

D234_CLAIM='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
D234_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'

# 27a: a successful section writes the file, with the measured duration.
D234_PROJ="$TMPDIR_TEST/d234-success"
mkdir -p "$D234_PROJ"
cat > "$D234_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
sleep 1
```
STRIDE
OUTPUT=$(echo "$D234_CLAIM" | CLAUDE_PROJECT_DIR="$D234_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
D234_FILE="$D234_PROJ/.stride/.hook-result-before_doing.json"
if [ -f "$D234_FILE" ]; then
  echo -e "  ${GREEN}PASS${RESET}: 27a: a successful section writes the durable result"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 27a: a successful section must write the durable result"
  FAIL=$((FAIL + 1))
fi
D234_MS=$(jq -r '.duration_ms' "$D234_FILE" 2>/dev/null)
assert_eq "27a: the file names the hook it belongs to" \
  "before_doing" "$(jq -r '.hook' "$D234_FILE" 2>/dev/null)"
assert_eq "27a: the persisted status is success" \
  "success" "$(jq -r '.status' "$D234_FILE" 2>/dev/null)"
# A 1s sleep must land well above zero. Asserting >0 rather than a range keeps
# this off the wall clock, which is what makes the rest of this suite flaky.
if [ -n "$D234_MS" ] && [ "$D234_MS" -gt 0 ] 2>/dev/null; then
  echo -e "  ${GREEN}PASS${RESET}: 27a: the persisted duration_ms is a real measurement (${D234_MS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 27a: persisted duration_ms must be > 0, got '$D234_MS'"
  FAIL=$((FAIL + 1))
fi
assert_eq "27a: stdout still carries the same duration (contract unchanged)" \
  "$D234_MS" "$(echo "$OUTPUT" | jq -r '.duration_ms' 2>/dev/null)"

# 27b: an EMPTY section writes nothing. This is plugin mode, it does no work,
# and 0 is the truthful answer — a missing file must mean "keep 0", never an
# error and never a licence to invent a figure.
D234_EMPTY="$TMPDIR_TEST/d234-empty"
mkdir -p "$D234_EMPTY"
cat > "$D234_EMPTY/.stride.md" << 'STRIDE'
## before_doing
```bash
```
STRIDE
echo "$D234_CLAIM" | CLAUDE_PROJECT_DIR="$D234_EMPTY" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
if [ -f "$D234_EMPTY/.stride/.hook-result-before_doing.json" ]; then
  echo -e "  ${RED}FAIL${RESET}: 27b: an empty section must not write a result file"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 27b: an empty section writes no result file (0 stays truthful)"
  PASS=$((PASS + 1))
fi

# 27c: one hook's result never overwrites another's. Separate paths make this
# structural rather than something a writer has to remember.
D234_TWO="$TMPDIR_TEST/d234-two-hooks"
mkdir -p "$D234_TWO"
cat > "$D234_TWO/.stride.md" << 'STRIDE'
## after_doing
```bash
echo after_doing_ran
```

## before_review
```bash
echo before_review_ran
```
STRIDE
echo "$D234_COMPLETE" | CLAUDE_PROJECT_DIR="$D234_TWO" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
echo "$D234_COMPLETE" | CLAUDE_PROJECT_DIR="$D234_TWO" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
assert_eq "27c: after_doing keeps its own result" "after_doing" \
  "$(jq -r '.hook' "$D234_TWO/.stride/.hook-result-after_doing.json" 2>/dev/null)"
assert_eq "27c: before_review keeps its own result" "before_review" \
  "$(jq -r '.hook' "$D234_TWO/.stride/.hook-result-before_review.json" 2>/dev/null)"

# 27d: the failure path persists a duration too. Before D234 the failure JSON
# carried no duration at all, because it was computed only after that branch
# had already returned — so the ONLY duration the executor emitted was on the
# one path whose output the agent cannot read.
D234_FAIL="$TMPDIR_TEST/d234-fail"
mkdir -p "$D234_FAIL"
cat > "$D234_FAIL/.stride.md" << 'STRIDE'
## after_doing
```bash
sleep 1
exit 7
```
STRIDE
echo "$D234_COMPLETE" | CLAUDE_PROJECT_DIR="$D234_FAIL" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
D234_FF="$D234_FAIL/.stride/.hook-result-after_doing.json"
assert_eq "27d: the failure path persists its result too" "failed" \
  "$(jq -r '.status' "$D234_FF" 2>/dev/null)"
D234_FMS=$(jq -r '.duration_ms' "$D234_FF" 2>/dev/null)
if [ -n "$D234_FMS" ] && [ "$D234_FMS" -gt 0 ] 2>/dev/null; then
  echo -e "  ${GREEN}PASS${RESET}: 27d: a failed hook carries a real duration_ms (${D234_FMS}ms)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 27d: failed duration_ms must be > 0, got '$D234_FMS'"
  FAIL=$((FAIL + 1))
fi

# 27e: a later task overwrites the previous one's file for the SAME hook, which
# is intended — the reader wants the current task's figure, not a history.
# Length alone cannot pin this: a write that silently no-ops leaves the PREVIOUS
# file in place and still yields length 1. So the section body changes between
# the two runs and the assertion reads it back out — freshness, not just shape.
cat > "$D234_TWO/.stride.md" << 'STRIDE'
## after_doing
```bash
echo after_doing_RERUN
```
STRIDE
echo "$D234_COMPLETE" | CLAUDE_PROJECT_DIR="$D234_TWO" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
assert_eq "27e: a re-run replaces the same hook's result rather than appending" "1" \
  "$(jq -s 'length' "$D234_TWO/.stride/.hook-result-after_doing.json" 2>/dev/null)"
assert_eq "27e: the replacement carries the SECOND run's data, not the first's" \
  "echo after_doing_RERUN" \
  "$(jq -r '.commands_completed[0]' "$D234_TWO/.stride/.hook-result-after_doing.json" 2>/dev/null)"

# 27f: a claim clears the previous task's result files. They carry no task id,
# and the documented reader rule covers only ABSENCE ("no file means the section
# was empty, keep 0") — so a leftover is indistinguishable from this task's own
# result. That is reachable, not theoretical: swapping .stride.md to plugin mode
# empties every section, so the new task writes nothing and the old figure would
# be read as its own.
D234_CLEAR="$TMPDIR_TEST/d234-claim-clear"
mkdir -p "$D234_CLEAR/.stride"
echo '{"hook":"after_doing","status":"success","duration_ms":999999}' \
  > "$D234_CLEAR/.stride/.hook-result-after_doing.json"
cat > "$D234_CLEAR/.stride.md" << 'STRIDE'
## before_doing
```bash
```
STRIDE
echo "$D234_CLAIM" | CLAUDE_PROJECT_DIR="$D234_CLEAR" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
if [ -f "$D234_CLEAR/.stride/.hook-result-after_doing.json" ]; then
  echo -e "  ${RED}FAIL${RESET}: 27f: a claim must clear the previous task's hook results"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 27f: a claim clears the previous task's hook results (no stale figure)"
  PASS=$((PASS + 1))
fi

# ============================================================
# Test Group 28: W2079 — hot-path skill byte budgets
# ============================================================
# The budget check is a drift detector (D229 philosophy): it fails this gate
# when a hot-path SKILL.md regrows past its budget, so regrowth is a visible
# decision instead of an accident. Budgets and the failure guidance live in
# scripts/check-skill-budgets.sh.
echo ""
echo "=== Test Group 28: W2079 hot-path skill byte budgets ==="
W2079_OUT=$(bash "$SCRIPT_DIR/../scripts/check-skill-budgets.sh" 2>&1)
W2079_RC=$?
if [ "$W2079_RC" -eq 0 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 28a: all hot-path skill files under budget"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 28a: a hot-path skill file is over budget (or the check errored)"
  printf '%s\n' "$W2079_OUT"
  FAIL=$((FAIL + 1))
fi

# ============================================================
# Test Group 29: W2099 — Windows PowerShell 5.1 static-compatibility gate
# ============================================================
# stride-hook.sh execs powershell.exe (Windows PowerShell 5.1), not pwsh, so a
# 7-only construct this machine's pwsh 7 happily accepts would fail only on a
# user's Windows box. scripts/check-ps1-compat.sh runs PSScriptAnalyzer's
# PSUseCompatibleSyntax and PSUseCompatibleCmdlets over hooks/*.ps1 targeting
# 5.1.
#
# SYNTAX and CMDLET-NAME only. A clean run is NOT evidence the hook RUNS on
# 5.1 — the verified blind spots are listed in README.md under "What this gate
# cannot see", and runtime verification on a real Windows host is a separate
# job that this group does not do and must not be read as doing.
#
# Exit codes: 0 clean, 1 findings or gate error, 2 tooling absent. A 2 SKIPs
# rather than failing, matching how this suite already skips groups needing
# jq, git, or python3 — pwsh is in that same class, and a permanently red
# suite on machines without it would just train people to ignore reds, which
# is the exact failure this whole gate exists to prevent.
#
# The ps1 twin suite has no Group 29: this gate analyses hooks/*.ps1 and
# scripts/*.ps1 from OUTSIDE, and a ps1 suite gating itself would certify its
# own host.
#
# (W2107) The trailing clause here used to read "as with Group 28", which
# stopped being true when W2105 gave Group 28 a ps1 counterpart. W2105 could
# not correct it -- test-stride-hook.sh was read-only for that task -- and
# recorded the staleness in CHANGELOG.md instead; W2107 touches this file, so
# it is corrected here rather than left as a second-hand note. Group 30 below
# is likewise mirrored, as ps1 Group 32. Group 29 is now the only bash-only
# group, and for the reason just stated rather than by convention.
echo ""
echo "=== Test Group 29: W2099 PowerShell 5.1 static-compatibility gate ==="
W2099_OUT=$(bash "$SCRIPT_DIR/../scripts/check-ps1-compat.sh" 2>&1)
W2099_RC=$?
if [ "$W2099_RC" -eq 2 ] && [ "${STRIDE_PS1_GATE_REQUIRED:-0}" = "1" ]; then
  # Opt-in enforcement. The SKIP below is the right default for contributor
  # machines, but it means a runner without pwsh reports a fully green suite
  # while hooks/*.ps1 was never gated at all — and green is what readers act
  # on. Set STRIDE_PS1_GATE_REQUIRED=1 wherever the gate is meant to be
  # mandatory (CI, a release check) to turn absent tooling into a failure
  # instead of a silent pass. Unset, behaviour is exactly as before.
  echo -e "  ${RED}FAIL${RESET}: 29a: STRIDE_PS1_GATE_REQUIRED=1 but pwsh or PSScriptAnalyzer is not installed"
  printf '%s\n' "$W2099_OUT"
  FAIL=$((FAIL + 1))
elif [ "$W2099_RC" -eq 2 ]; then
  echo "  SKIP: 29a: pwsh or PSScriptAnalyzer not installed — the 5.1 gate needs both"
  echo "        (set STRIDE_PS1_GATE_REQUIRED=1 to make this a failure instead)"
  printf '%s\n' "$W2099_OUT"
elif [ "$W2099_RC" -eq 0 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 29a: hooks/*.ps1 clean against the PowerShell 5.1 syntax and cmdlet rules"
  PASS=$((PASS + 1))
  # Surface analyzer-version drift even on a PASS. The gate accepts any build
  # at or above the pinned version so a contributor on a newer one is not
  # blocked, which means the build supplying this verdict can differ from the
  # one the repo pins. Swallowing the whole output here — the obvious thing to
  # do on a green branch — would make that drift invisible in the one run that
  # happens routinely. Only warn: lines are echoed, so a clean run stays quiet.
  printf '%s\n' "$W2099_OUT" | grep '^warn:' || true
else
  echo -e "  ${RED}FAIL${RESET}: 29a: a hooks/*.ps1 file uses a construct Windows PowerShell 5.1 cannot run (or the gate errored)"
  printf '%s\n' "$W2099_OUT"
  FAIL=$((FAIL + 1))
fi

# 29b: the gate must be able to go RED. A compatibility gate that cannot fail
# is worse than no gate, because it certifies. Point the same script at a
# scratch file of constructs 5.1 cannot parse and require a non-zero exit
# naming BOTH rules — checking both is what catches the silent
# half-misconfiguration where one rule goes quiet and the other still reports.
if [ "$W2099_RC" -ne 2 ]; then
  W2099_PROBE_DIR="$TMPDIR_TEST/w2099-probe"
  mkdir -p "$W2099_PROBE_DIR"
  cat > "$W2099_PROBE_DIR/probe.ps1" << 'PROBE'
$x = 1
$y = $x ? 'a' : 'b'
$z = $null ?? 'c'
Get-Uptime
PROBE
  W2099_NEG_OUT=$(bash "$SCRIPT_DIR/../scripts/check-ps1-compat.sh" "$W2099_PROBE_DIR" 2>&1)
  W2099_NEG_RC=$?
  # Assert on the SCAN's own findings, not on bare rule names appearing
  # anywhere in the output. The self-test success banner and the
  # GATE SELF-TEST FAILED block both name each rule, so a bare grep for the
  # rule names is satisfied unconditionally and leaves rc==1 as the only
  # load-bearing check — which a gate broken so that a rule goes silent also
  # produces, from the self-test, having scanned nothing. Requiring the
  # INCOMPATIBLE: prefix means only real findings against the scratch file can
  # satisfy this, and the absence check rules out the self-test-failure path
  # masquerading as a successful rejection.
  if [ "$W2099_NEG_RC" -eq 1 ] \
     && printf '%s' "$W2099_NEG_OUT" | grep -q "INCOMPATIBLE:.*PSUseCompatibleSyntax" \
     && printf '%s' "$W2099_NEG_OUT" | grep -q "INCOMPATIBLE:.*PSUseCompatibleCmdlets" \
     && ! printf '%s' "$W2099_NEG_OUT" | grep -q "GATE SELF-TEST FAILED"; then
    echo -e "  ${GREEN}PASS${RESET}: 29b: the gate rejects 7-only syntax and a 7-only cmdlet in a scratch file"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 29b: the gate stayed green on a deliberately 7-only scratch file (rc=$W2099_NEG_RC) — it may be a no-op"
    printf '%s\n' "$W2099_NEG_OUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W2099_PROBE_DIR"
fi

# ============================================================
# Test Group 30: W2107 -- the port-canon drift check, both halves
# ============================================================
# Runs the SELF-TEST of check-port-canon.sh and check-port-canon.ps1, and
# cross-checks the two against each other.
#
# NEVER the fleet scan. Its correct result today is exit 1 -- the fleet has not
# adopted the anchor contract yet -- so registering it here would install a
# permanently-red group, and a permanently-red group trains people to ignore
# the suite. The fleet scan stays an ungated release-time step, exactly as
# README describes it.
#
# TWO DIFFERENT REASONS A LEG CAN NOT RUN, and they are deliberately not the
# same thing:
#
#   exit 2 from either half is a FAIL. Neither half has a machine-fault tier --
#   the bash half shells only awk and grep, and the ps1 half's ConvertFrom-Json
#   ships inside every PowerShell that could run it. A 2 therefore means "no
#   verdict was possible" about the CANON, which is a real failure.
#
#   pwsh being absent is a SKIP for the ps1 leg only. That is a statement about
#   this machine, not about the canon. STRIDE_PS1_GATE_REQUIRED=1 turns it into
#   a failure, following Group 29's opt-in enforcement -- a runner without pwsh
#   otherwise reports a fully green suite while half the pair never ran.
echo ""
echo "=== Test Group 30: W2107 port-canon drift check (self-test, never the fleet scan) ==="

W2107_SH_OUT=$(bash "$SCRIPT_DIR/../scripts/check-port-canon.sh" --self-test 2>&1)
W2107_SH_RC=$?
if [ "$W2107_SH_RC" -eq 0 ] && printf '%s\n' "$W2107_SH_OUT" | grep -q '^self-test: [1-9][0-9]* passed, 0 failed$'; then
  # Asserting the TALLY LINE, not just the exit code: a self-test that ran zero
  # cases also exits 0, and "0 passed, 0 failed" is the shape a broken harness
  # produces. The count is not pinned here on purpose -- the suites assert that
  # it is non-zero and clean, and the two halves assert it against EACH OTHER
  # in 30c, which is the check that actually catches a lost case.
  echo -e "  ${GREEN}PASS${RESET}: 30a: the bash half's self-test is clean ($(printf '%s\n' "$W2107_SH_OUT" | grep '^self-test: [0-9]' | tail -1))"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 30a: the bash half's self-test did not pass cleanly (rc=$W2107_SH_RC)"
  printf '%s\n' "$W2107_SH_OUT" | tail -20
  FAIL=$((FAIL + 1))
fi

W2107_PS_RAN=0
if command -v pwsh > /dev/null 2>&1; then
  W2107_PS_OUT=$(pwsh -NoProfile -File "$SCRIPT_DIR/../scripts/check-port-canon.ps1" -SelfTest 2>&1)
  W2107_PS_RC=$?
  W2107_PS_RAN=1
  if [ "$W2107_PS_RC" -eq 0 ] && printf '%s\n' "$W2107_PS_OUT" | grep -q '^self-test: [1-9][0-9]* passed, 0 failed$'; then
    echo -e "  ${GREEN}PASS${RESET}: 30b: the PowerShell half's self-test is clean ($(printf '%s\n' "$W2107_PS_OUT" | grep '^self-test: [0-9]' | tail -1))"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 30b: the PowerShell half's self-test did not pass cleanly (rc=$W2107_PS_RC)"
    printf '%s\n' "$W2107_PS_OUT" | tail -20
    FAIL=$((FAIL + 1))
  fi
elif [ "${STRIDE_PS1_GATE_REQUIRED:-0}" = "1" ]; then
  echo -e "  ${RED}FAIL${RESET}: 30b: STRIDE_PS1_GATE_REQUIRED=1 but pwsh is not installed"
  FAIL=$((FAIL + 1))
else
  echo "  SKIP: 30b: pwsh not installed -- the PowerShell half cannot run here"
  echo "        (set STRIDE_PS1_GATE_REQUIRED=1 to make this a failure instead)"
fi

# WHAT THIS GROUP DOES NOT DO, said here rather than left to be discovered: it
# has no counterpart to ps1 Group 32d, the fixture-tree comparison that runs
# both halves over one canon and diffs their REPORTS. A developer or a Unix CI
# runner executing only this suite therefore gets case-name equality (30c) but
# not report-level agreement, even with pwsh installed. Criterion 5 asks for the
# cross-verification once and the ps1 parity ledger records Group 32 as its
# home; this note exists so the asymmetry is a stated choice rather than a gap
# someone finds by grepping.
#
# 30c: the two halves must agree about WHICH CASES EXIST. Comparing the ok:
# name sets catches a case renamed or lost on one side, which neither half's
# own tally can see -- each is internally consistent while disagreeing with the
# other. The [ps1-only] and [bash-only] prefixes and the skipped-with-reason
# suffix are the three sanctioned asymmetries and are normalized out; anything
# else is a divergence. ([bash-only] was added by D294 -- see below.)
if [ "$W2107_PS_RAN" -eq 1 ]; then
  # Three sanctioned asymmetries now, not two. [bash-only] is the mirror of
  # [ps1-only], added by D294 for a case whose HAZARD cannot exist in the other
  # half -- the grep-stub pair, which pins behaviour of a grep this half shells
  # out to and the PowerShell half never invokes. Both markers are filtered
  # from BOTH lists, so a marked case is out of the comparison whichever side
  # it lives on. Marking is not a way to silence a divergence: a case is marked
  # only when the other half CANNOT have the hazard, and a case testing an
  # outcome both halves owe gets ported instead. The non-vacuity guard below
  # still sees every unmarked case -- all but the marked lines -- so filtering
  # cannot empty the list while real cases remain. No count is pinned here on
  # purpose: a figure in a comment is the drift this very group exists to
  # catch, and D294 removed one of those from the ps1 suite in the same change.
  W2107_SH_NAMES=$(printf '%s\n' "$W2107_SH_OUT" | grep '^ok: ' | sed 's/ \[skipped on this host:.*\]$//' | grep -v '^ok: \[ps1-only\]' | grep -v '^ok: \[bash-only\]' | sort)
  W2107_PS_NAMES=$(printf '%s\n' "$W2107_PS_OUT" | grep '^ok: ' | sed 's/ \[skipped on this host:.*\]$//' | grep -v '^ok: \[ps1-only\]' | grep -v '^ok: \[bash-only\]' | sort)
  if [ -z "$W2107_SH_NAMES" ]; then
    # Non-vacuity: two empty sets compare equal forever.
    echo -e "  ${RED}FAIL${RESET}: 30c: the bash half emitted no ok: lines, so the cross-check would pass vacuously"
    FAIL=$((FAIL + 1))
  elif [ "$W2107_SH_NAMES" = "$W2107_PS_NAMES" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 30c: both halves ran the same $(printf '%s\n' "$W2107_SH_NAMES" | wc -l | tr -d ' ') named cases"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 30c: the two halves disagree about which cases exist"
    diff <(printf '%s\n' "$W2107_SH_NAMES") <(printf '%s\n' "$W2107_PS_NAMES") | head -20
    FAIL=$((FAIL + 1))
  fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed (out of $TOTAL)"

# (D241) Report the run's own wall clock and the load it measured, so a loaded
# run is distinguishable from a failing one WITHOUT re-running it. This is the
# cheap step that would have prevented this defect's original misdiagnosis: a
# 5-run sample taken beside an 85-second Elixir suite was read as a code
# regression, when every failure in it was load-induced.
SUITE_WALL_MS=$(( $(suite_now_ms) - SUITE_START_MS ))
SUITE_WALL_S=$(( SUITE_WALL_MS / 1000 ))
# Sample the load AGAIN at the end. Calibrating only at t=0 misses the exact
# scenario that filed this defect: the 85-second Elixir suite that skewed the
# original 5-run sample started while the hook suite was already running. A run
# that begins quiet and turns busy would otherwise scale nothing, warn about
# nothing, and fail with no indication in its own output that the machine was
# the cause.
SUITE_OVERHEAD_END_MS=$(calibrate_suite_overhead_ms)
echo "Wall clock: ${SUITE_WALL_S}s (idle baseline ~${SUITE_WALL_BASELINE_S}s)  |  startup overhead: ${SUITE_OVERHEAD_MS}ms at start, ${SUITE_OVERHEAD_END_MS}ms at end (idle baseline ${SUITE_LOAD_BASELINE_MS}ms)"
SUITE_END_SCALE=$(( (SUITE_OVERHEAD_END_MS + SUITE_LOAD_BASELINE_MS - 1) / SUITE_LOAD_BASELINE_MS ))
if [ "$SUITE_LOAD_SCALE" -gt 1 ] || [ "$SUITE_END_SCALE" -gt 1 ] || [ "$SUITE_WALL_S" -gt $(( SUITE_WALL_BASELINE_S * 2 )) ]; then
  echo ""
  echo "WARNING: this machine was LOADED during the run (${SUITE_LOAD_SCALE}x at start,"
  echo "         ${SUITE_END_SCALE}x at end, ${SUITE_WALL_S}s wall clock against a ~${SUITE_WALL_BASELINE_S}s idle"
  echo "         baseline). Wall-clock backstops were scaled to the START sample, so a"
  echo "         run that only became busy later got LESS headroom than it needed."
  echo "         Reproduce any failure above on a quiet machine before diagnosing it as"
  echo "         a code defect — that mistake is what filed D241."
fi
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
