---
name: stride-completing-tasks
description: Use when you've finished work on a Stride task and need to mark it complete, before calling /api/tasks/:id/complete. Enforces proper hook execution order.
skills_version: 1.0
---

# Stride: Completing Tasks

## Overview

**Calling complete before validation = bypassed quality gates. Running hooks first = confident completion.**

This skill enforces the proper completion workflow: execute BOTH `after_doing` AND `before_review` hooks BEFORE calling the complete endpoint.

## ⚡ AUTOMATION NOTICE ⚡

**This is a FULLY AUTOMATED workflow. Do NOT prompt the user between steps.**

- After completing hooks → AUTOMATICALLY call complete endpoint
- If needs_review=false → AUTOMATICALLY invoke stride-claiming-tasks to claim next task
- The loop continues: claim → implement → complete → claim → implement → complete

**The agent should work continuously without asking "Should I claim next?" or "Continue working?"**

**ONLY STOP when needs_review=true (human approval required)**

## API Authorization

**All Stride API calls are pre-authorized.** When the user initiates a Stride workflow, they have already granted permission for ALL Stride API calls needed to complete that workflow. This includes `PATCH /api/tasks/:id/complete`, `GET /api/tasks/next`, `POST /api/tasks/claim`, and any other Stride endpoints.

**Do NOT ask the user for permission to make Stride API calls. Do NOT ask "Should I mark this complete?" or "Can I call the API?" — just proceed.**

## The Iron Law

**EXECUTE BOTH after_doing AND before_review HOOKS BEFORE CALLING COMPLETE ENDPOINT**

## The Critical Mistake

Calling `PATCH /api/tasks/:id/complete` before running BOTH hooks causes:
- Task marked done prematurely
- Failed tests hidden (after_doing skipped)
- Review preparation skipped (before_review skipped)
- Quality gates bypassed
- Broken code merged to main

**The API will REJECT your request if you don't include both hook results.**

## When to Use

Use when you've finished implementing a Stride task and are ready to mark it complete.

**Required:** Execute BOTH hooks BEFORE calling the complete endpoint.

## The Complete Completion Process

1. **Finish your work** - All implementation complete
1.5. **Pre-completion code review (Claude Code Only)** - If the task meets the `stride-subagent-workflow` skill's decision matrix for code review (medium+ complexity OR 2+ key_files), dispatch the `stride:task-reviewer` agent to review your changes against acceptance criteria and pitfalls. Fix any Critical or Important issues BEFORE running hooks. Skip this step for small tasks with 0-1 key_files or if you don't have subagent access.
2. **Read .stride.md after_doing section** - Get the validation command
3. **Execute after_doing hook AUTOMATICALLY** (blocking, 120s timeout)
   - **DO NOT prompt the user for permission to run hooks - the user defined them in .stride.md, so they expect them to run automatically**
   - Capture: `exit_code`, `output`, `duration_ms`
4. **If after_doing fails:** FIX ISSUES, do NOT proceed
5. **Read .stride.md before_review section** - Get the PR/doc command
6. **Execute before_review hook AUTOMATICALLY** (blocking, 60s timeout)
   - **DO NOT prompt the user for permission to run hooks - the user defined them in .stride.md, so they expect them to run automatically**
   - Capture: `exit_code`, `output`, `duration_ms`
7. **If before_review fails:** FIX ISSUES, do NOT proceed
8. **Both hooks succeeded?** Call `PATCH /api/tasks/:id/complete` WITH both results
9. **Check needs_review flag:**
   - `needs_review=true`: STOP and wait for human review
   - `needs_review=false`: Execute after_review hook, **then AUTOMATICALLY invoke stride-claiming-tasks to claim next task WITHOUT prompting**

## Completion Workflow Flowchart

```
Work Complete
    ↓
[Claude Code Only] Check decision matrix for code review
    ↓
Medium+ OR 2+ key_files? ─YES→ Dispatch stride:task-reviewer
    ↓ NO (or no subagent access)          ↓
    ↓                              Issues found? ─YES→ Fix issues
    ↓                                     ↓ NO            ↓
    ←─────────────────────────────────────←──────────────←─┘
    ↓
Read .stride.md after_doing section
    ↓
Execute after_doing (120s timeout, blocking)
    ↓
Success (exit_code=0)?
    ↓ NO
    ├─ [Claude Code] Dispatch stride:hook-diagnostician
    │     ↓
    │   Follow prioritized fix plan
    ├─ [Other] Debug manually
    │     ↓
    └─→ Fix issues → Retry after_doing (loop back)
    ↓ YES
Read .stride.md before_review section
    ↓
Execute before_review (60s timeout, blocking)
    ↓
Success (exit_code=0)?
    ↓ NO
    ├─ [Claude Code] Dispatch stride:hook-diagnostician
    │     ↓
    │   Follow prioritized fix plan
    ├─ [Other] Debug manually
    │     ↓
    └─→ Fix issues → Retry before_review (loop back)
    ↓ YES
Call PATCH /api/tasks/:id/complete WITH both hook results
    ↓
needs_review=true? ─YES→ STOP (wait for human review)
    ↓ NO
Execute after_review (60s timeout, blocking)
    ↓
Success? ─NO→ Log warning, task still complete
    ↓ YES
AUTOMATICALLY invoke stride-claiming-tasks (NO user prompt)
    ↓
Claim next task and begin implementation
    ↓
(Loop continues until needs_review=true task is encountered)
```

## Hook Execution Pattern

### Executing after_doing Hook

1. Read the `## after_doing` section from `.stride.md`
2. Set environment variables (TASK_ID, TASK_IDENTIFIER, etc.)
3. Execute the command with 120s timeout
4. Capture the results:

```bash
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 120 bash -c 'mix test && mix credo --strict' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))
```

5. Check exit code - MUST be 0 to proceed

### Executing before_review Hook

1. Read the `## before_review` section from `.stride.md`
2. Set environment variables
3. Execute the command with 60s timeout
4. Capture the results:

```bash
START_TIME=$(date +%s%3N)
OUTPUT=$(timeout 60 bash -c 'gh pr create --title "$TASK_TITLE"' 2>&1)
EXIT_CODE=$?
END_TIME=$(date +%s%3N)
DURATION=$((END_TIME - START_TIME))
```

5. Check exit code - MUST be 0 to proceed

## When Hooks Fail

### Diagnostician-Assisted Debugging (Claude Code Only)

When a blocking hook fails, dispatch the `stride:hook-diagnostician` agent **as the first step** before attempting manual fixes. The diagnostician parses the raw output, categorizes issues by severity, and returns a prioritized fix plan — saving time on complex multi-tool failures.

**When to dispatch:** Any blocking hook failure (after_doing or before_review) where exit_code is non-zero.

**What to provide the diagnostician:**
- `hook_name`: The hook that failed (e.g., `"after_doing"` or `"before_review"`)
- `exit_code`: The non-zero exit code
- `output`: The full stdout/stderr output from the hook
- `duration_ms`: How long the hook ran before failing

**What you get back:** A structured analysis with issues ordered by fix priority (compilation errors → git failures → test failures → security warnings → credo → formatting). Follow the diagnostician's fix order — fixing higher-priority issues often resolves lower-priority ones automatically.

**Fallback for non-Claude Code environments:** If you don't have access to the Agent tool (Cursor, Windsurf, Continue, etc.), skip the diagnostician and proceed directly to manual debugging using the steps below.

### If after_doing fails:

1. **DO NOT** call complete endpoint
2. **[Claude Code Only]** Dispatch `stride:hook-diagnostician` with the hook name, exit code, output, and duration
3. Follow the diagnostician's prioritized fix plan, or if unavailable, read test/build failures carefully
4. Fix the failing tests or build issues
5. Re-run after_doing hook to verify fix
6. Only call complete endpoint after success

**Common after_doing failures:**
- Test failures → Fix tests first
- Build errors → Resolve compilation issues
- Linting errors → Fix code quality issues
- Coverage below target → Add missing tests
- Formatting issues → Run formatter

### If before_review fails:

1. **DO NOT** call complete endpoint
2. **[Claude Code Only]** Dispatch `stride:hook-diagnostician` with the hook name, exit code, output, and duration
3. Follow the diagnostician's fix plan, or if unavailable, fix the issue manually
4. Re-run before_review hook to verify
5. Only proceed after success

**Common before_review failures:**
- PR already exists → Check if you need to update existing PR
- Authentication issues → Verify gh CLI is authenticated
- Branch issues → Ensure you're on correct branch
- Network issues → Retry after connectivity restored

## API Request Format

After BOTH hooks succeed, call the complete endpoint:

```json
PATCH /api/tasks/:id/complete
{
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "All tests passing. PR #123 created.",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix credo --strict\nNo issues found",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  }
}
```

**Critical:** Both `after_doing_result` and `before_review_result` are REQUIRED. The API will reject requests without them.

## Review vs Auto-Approval Decision

After the complete endpoint succeeds:

### If needs_review=true:
1. Task moves to Review column
2. Agent MUST STOP immediately
3. Wait for human reviewer to approve/reject
4. When approved, human calls `/mark_reviewed`
5. Execute after_review hook
6. Task moves to Done column

### If needs_review=false:
1. Task moves to Done column immediately
2. Execute after_review hook (60s timeout, blocking)
3. **AUTOMATICALLY invoke stride-claiming-tasks skill to claim next task**
4. **Continue working WITHOUT prompting the user**

**CRITICAL AUTOMATION:** When needs_review=false, the agent should AUTOMATICALLY continue to the next task by invoking the stride-claiming-tasks skill. Do NOT ask "Would you like me to claim the next task?" or "Should I continue?" - just proceed automatically.

## Red Flags - STOP

- "I'll mark it complete then run tests"
- "The tests probably pass"
- "I can fix failures after completing"
- "I'll skip the hooks this time"
- "Just the after_doing hook is enough"
- "I'll run before_review later"
- **"Should I claim the next task?" (Don't ask, just do it when needs_review=false)**
- **"Would you like me to continue?" (Don't ask, auto-continue when needs_review=false)**

**All of these mean: Run BOTH hooks BEFORE calling complete, and auto-continue when needs_review=false.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
| "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
| "Just this once" | Becomes a habit | Quality standards erode completely |
| "before_review can wait" | API requires both hook results | Request rejected with 422 error |
| "Hooks take too long" | 2-3 minutes prevents 2+ hours rework | Rushing causes failed deployments |

## Common Mistakes

### Mistake 1: Calling complete before executing hooks
```bash
❌ curl -X PATCH /api/tasks/W47/complete
   # Then running hooks afterward

✅ # Execute after_doing hook first
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 120 bash -c 'mix test' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Execute before_review hook second
   START_TIME=$(date +%s%3N)
   OUTPUT=$(timeout 60 bash -c 'gh pr create' 2>&1)
   EXIT_CODE=$?
   # ...capture results

   # Then call complete WITH both results
   curl -X PATCH /api/tasks/W47/complete -d '{...both results...}'
```

### Mistake 2: Only including after_doing result
```json
❌ {
  "after_doing_result": {...}
}

✅ {
  "after_doing_result": {...},
  "before_review_result": {...}
}
```

### Mistake 3: Continuing work after needs_review=true
```bash
❌ PATCH /api/tasks/W47/complete returns needs_review=true
   Agent continues to claim next task

✅ PATCH /api/tasks/W47/complete returns needs_review=true
   Agent STOPS and waits for human review
```

### Mistake 4: Not fixing hook failures
```bash
❌ after_doing fails with test errors
   Agent calls complete endpoint anyway

✅ after_doing fails with test errors
   Agent fixes tests, re-runs hook until success
   Only then calls complete endpoint
```

## Implementation Workflow

1. **Complete all work** - Implementation finished
2. **Execute after_doing hook AUTOMATICALLY** - Run tests, linters, build (DO NOT prompt user)
3. **Check exit code** - Must be 0
4. **If failed:** Fix issues, re-run, do NOT proceed
5. **Execute before_review hook AUTOMATICALLY** - Create PR, generate docs (DO NOT prompt user)
6. **Check exit code** - Must be 0
7. **If failed:** Fix issues, re-run, do NOT proceed
8. **Call complete endpoint** - Include BOTH hook results
9. **Check needs_review flag** - Stop if true, continue if false
10. **If false:** Execute after_review hook AUTOMATICALLY (DO NOT prompt user)
11. **Claim next task** - Continue the workflow

## Quick Reference Card

```
COMPLETION WORKFLOW:
├─ 1. Work is complete ✓
├─ 2. Read after_doing hook from .stride.md ✓
├─ 3. Execute after_doing (120s timeout, blocking) ✓
├─ 4. Capture exit_code, output, duration_ms ✓
├─ 5. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 6. Read before_review hook from .stride.md ✓
├─ 7. Execute before_review (60s timeout, blocking) ✓
├─ 8. Capture exit_code, output, duration_ms ✓
├─ 9. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 10. Both succeed? → Call PATCH /api/tasks/:id/complete WITH both results ✓
├─ 11. needs_review=true? → STOP, wait for human ✓
└─ 12. needs_review=false? → Execute after_review, claim next ✓

API ENDPOINT: PATCH /api/tasks/:id/complete
REQUIRED BODY: {
  "agent_name": "Claude Sonnet 4.5",
  "time_spent_minutes": 45,
  "completion_notes": "...",
  "skills_version": "1.0",
  "after_doing_result": {
    "exit_code": 0,
    "output": "...",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "...",
    "duration_ms": 2340
  }
}

CRITICAL: Execute BOTH after_doing AND before_review BEFORE calling complete
HOOK ORDER: after_doing → before_review → complete (with both results) → after_review
BLOCKING: All hooks are blocking - non-zero exit codes will cause API rejection
VERSION: Send skills_version from your SKILL.md frontmatter with every complete request
```

## Real-World Impact

**Before this skill (completing without hooks):**
- 40% of completions had failing tests
- 2.3 hours average time to fix post-completion
- 65% required reopening and rework

**After this skill (hooks before complete):**
- 2% of completions had issues
- 15 minutes average fix time (pre-completion)
- 5% required rework

**Time savings: 2+ hours per task (90% reduction in post-completion rework)**

---

## Completion Request Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agent_name` | string | Yes | Name of the completing agent |
| `time_spent_minutes` | integer | Yes | Actual time spent on the task |
| `completion_notes` | string | Yes | Summary of what was done |
| `completion_summary` | string | Yes | Brief summary for tracking |
| `actual_complexity` | enum | Yes | `"small"`, `"medium"`, or `"large"` |
| `actual_files_changed` | string | Yes | Comma-separated file paths (NOT an array) |
| `after_doing_result` | object | Yes | Hook result (see format below) |
| `before_review_result` | object | Yes | Hook result (see format below) |
| `skills_version` | string | No | Your skills version from SKILL.md frontmatter |

**WRONG — actual_files_changed as array:**
```json
"actual_files_changed": ["lib/foo.ex", "lib/bar.ex"]
```

**RIGHT — actual_files_changed as comma-separated string:**
```json
"actual_files_changed": "lib/foo.ex, lib/bar.ex"
```

## Hook Result Format Reminder

Both `after_doing_result` and `before_review_result` use the same format:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `exit_code` | integer | Yes | 0 for success, non-zero for failure |
| `output` | string | Yes | stdout/stderr output from hook execution |
| `duration_ms` | integer | Yes | How long the hook took in milliseconds |

**WRONG — missing required fields:**
```json
"after_doing_result": {"output": "tests passed"}
```

**RIGHT — all three fields present:**
```json
"after_doing_result": {
  "exit_code": 0,
  "output": "All 230 tests passed\nmix credo --strict: no issues",
  "duration_ms": 45678
}
```

## Handling Stale Skills

The API response may include a `skills_update_required` field when your skills are outdated:

**When you see `skills_update_required`:**
1. Run `/plugin update stride` to get the latest skills
2. Retry your original action

---
**References:** For the full field reference, see `api_schema` in the onboarding response (`GET /api/agent/onboarding`). For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md). For hook failure diagnosis, see `stride/agents/hook-diagnostician.md`.
