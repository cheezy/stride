# Completing-Tasks Reference

Lookup material for the stride-completing-tasks skill, kept out of the hot path because building a valid completion payload does not require reading it. **Nothing here is authoritative:** the flowchart, the Implementation Workflow list, and the Quick Reference Card summarise the procedure SKILL.md defines, and the worked payload example illustrates the shapes SKILL.md's Completion Request Field Reference and Explorer/Reviewer Result Schema own — where anything here disagrees with SKILL.md, SKILL.md wins.

## Completion Workflow Flowchart

```
Work Complete
    ↓
[Claude Code Only] Check decision matrix for code review
    ↓
Matrix says YES in the Review column? ─YES→ Dispatch stride:task-reviewer
    ↓ NO (or no subagent access)          ↓
    ↓                              Issues found? ─YES→ Fix issues
    ↓                                     ↓ NO            ↓
    ←─────────────────────────────────────←──────────────←─┘
    ↓
Step 5.5 / Phase 3.5: Manual & Exploratory Testing (optional, gated)
  Gate = manual_tests non-empty AND the exploratory plugin is available.
  NO review precondition — the NO branch above reaches this too.
  Gate not met → straight on to the hook, no failure.
    ↓
Step 5.6 / Phase 3.6: Harden findings into checks (optional, gated)
    ↓
Read .stride.md after_doing section
    ↓
Execute after_doing (600s timeout, blocking)
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
Execute before_review (600s timeout, blocking)
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
Execute after_review (600s timeout, blocking)
    ↓
Success? ─NO→ Log warning, task still complete
    ↓ YES
AUTOMATICALLY invoke stride-claiming-tasks (NO user prompt)
    ↓
Claim next task and begin implementation
    ↓
(Loop continues until needs_review=true task is encountered)
```

---

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

---

## Quick Reference Card

```
CLAUDE CODE COMPLETION WORKFLOW (automatic hooks):
├─ 1. Work is complete ✓
├─ 2. [Optional] Dispatch task-reviewer for code review ✓
├─ 2a. [Optional, gated] Step 5.5 manual & exploratory testing ✓
│      Gate = manual_tests non-empty AND plugin available — never on review,
│      so a small 0-1 key_files task that skipped step 2 still reaches this
│      (then Step 5.6 /harden, if that session returned convertible findings)
├─ 3. Call PATCH /api/tasks/:id/complete directly ✓
│     (hooks.json PreToolUse auto-runs after_doing first
│      hooks.json PostToolUse auto-runs before_review after)
├─ 4. PreToolUse hook failed? → Fix issues, retry curl ✓
├─ 5. needs_review=true? → STOP, wait for human ✓
└─ 6. needs_review=false? → after_review auto-fires, claim next ✓

🚨 DO NOT manually execute .stride.md commands in Claude Code
🚨 DO NOT run separate Bash commands to "capture hook results"
🚨 JUST make the curl call — hooks.json handles everything

OTHER ENVIRONMENTS (manual hooks):
├─ 1. Work is complete ✓
├─ 2. Execute after_doing (600s timeout, blocking) ✓
├─ 3. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 4. Execute before_review (600s timeout, blocking) ✓
├─ 5. Hook fails? → FIX, retry, DO NOT proceed ✓
├─ 6. Both succeed? → Call PATCH /api/tasks/:id/complete WITH both results ✓
├─ 7. needs_review=true? → STOP, wait for human ✓
└─ 8. needs_review=false? → Execute after_review, claim next ✓

API ENDPOINT: PATCH /api/tasks/:id/complete?response_view=slim
REQUIRED BODY: {
  "agent_name": "Claude Opus 4.6",
  "time_spent_minutes": 45,
  "completion_notes": "...",
  "review_report": "..." (optional — include when task-reviewer ran),
  "skills_version": "1.0",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Executed by Claude Code hooks system",
    "duration_ms": 0
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Executed by Claude Code hooks system",
    "duration_ms": 0
  },
  "explorer_result": {
    "dispatched": true,
    "summary": "<40+ non-whitespace chars>",
    "duration_ms": 12000
  },
  "reviewer_result": {
    "dispatched": true,
    "duration_ms": 8000,
    "summary": "<40+ non-whitespace chars>",
    "issues_found": 0,
    "acceptance_criteria_checked": 5,
    "schema_version": "1.6",
    "status": "approved",
    "issue_counts": {"critical": 0, "important": 0, "minor": 0},
    "issues": [],
    "acceptance_criteria": [{"criterion": "<verbatim>", "status": "met", "evidence": "<file:line>"}],
    "project_checks": [],
    "testing_strategy": {"status": "passed"},
    "patterns": {"status": "passed"},
    "pitfalls": {"status": "passed"},
    "security_considerations": {"status": "passed"}
  },
  "workflow_steps": [
    {"name": "explorer",       "dispatched": true,  "duration_ms": 12450},
    {"name": "planner",        "dispatched": true,  "duration_ms": 8200},
    {"name": "implementation", "dispatched": true,  "duration_ms": 1820000},
    {"name": "reviewer",       "dispatched": true,  "duration_ms": 15300},
    {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
    {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
  ]
}

reviewer_result (dispatched) = the task-reviewer agent's structured block
(schema_version/status/issue_counts/issues[]/acceptance_criteria[]/project_checks[]/testing_strategy/patterns/pitfalls/security_considerations)
merged with dispatched:true + duration_ms + derived legacy issues_found/acceptance_criteria_checked.
Source order: A the block file under .stride/ (normal), B an inline ```json fence
(older reviewer / write-failure), C the prose fallback. review_report comes from
the reviewer's report file, NOT its returned response (a bounded summary);
fall back to the returned text only when no report file exists.
See stride-workflow Step 5 for the chain; schema owned by stride/agents/task-reviewer.md.

SKIP FORM for explorer_result / reviewer_result (when subagent not dispatched):
  {"dispatched": false, "reason": "<enum>", "summary": "<40+ non-whitespace chars>"}
Reason enum: no_subagent_support, small_task_0_1_key_files, trivial_change_docs_only,
             self_reported_exploration, self_reported_review

VERSION: Send skills_version from your SKILL.md frontmatter with every complete request
```

---

## Worked completion payload example

```bash
curl -X PATCH "$STRIDE_API_URL/api/tasks/$TASK_ID/complete?response_view=slim" \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --arg agent_name 'Claude Opus 4.6' \
    --arg notes 'All tests passing. PR #123 created.' \
    --arg summary 'Brief one-line summary for tracking.' \
    --arg complexity 'small' \
    --arg files 'lib/foo.ex, test/foo_test.exs' \
    --arg report '## Review Summary\n\nApproved — 0 issues found.' \
    '{
       agent_name: $agent_name,
       time_spent_minutes: 45,
       completion_notes: $notes,
       completion_summary: $summary,
       actual_complexity: $complexity,
       actual_files_changed: $files,
       review_report: $report,
       after_doing_result: {exit_code: 0, output: "...", duration_ms: 45678},
       before_review_result: {exit_code: 0, output: "...", duration_ms: 2340},
       explorer_result: {dispatched: true, summary: "...", duration_ms: 12450},
       reviewer_result: {dispatched: true, duration_ms: 15300, summary: "...", issues_found: 0, acceptance_criteria_checked: 5, schema_version: "1.6", status: "approved", issue_counts: {critical: 0, important: 0, minor: 0}, issues: [], acceptance_criteria: [], project_checks: [], testing_strategy: {status: "passed"}, patterns: {status: "passed"}, pitfalls: {status: "passed"}, security_considerations: {status: "passed"}},
       workflow_steps: [
         {name: "explorer", dispatched: true, duration_ms: 12450},
         {name: "planner", dispatched: true, duration_ms: 8200},
         {name: "implementation", dispatched: true, duration_ms: 1820000},
         {name: "reviewer", dispatched: true, duration_ms: 15300},
         {name: "after_doing", dispatched: true, duration_ms: 45678},
         {name: "before_review", dispatched: true, duration_ms: 2340}
       ]
     }')" \
  | tee "$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json"
```

The resulting request body has this shape (illustrative — populated values
match the `--arg` substitutions above):

```json
{
  "agent_name": "Claude Opus 4.6",
  "time_spent_minutes": 45,
  "completion_notes": "All tests passing. PR #123 created.",
  "completion_summary": "Brief one-line summary for tracking.",
  "actual_complexity": "small",
  "actual_files_changed": "lib/foo.ex, test/foo_test.exs",
  "review_report": "## Review Summary\n\nApproved — 0 issues found.",
  "after_doing_result": {
    "exit_code": 0,
    "output": "Running tests...\n230 tests, 0 failures\nmix credo --strict\nNo issues found",
    "duration_ms": 45678
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "Creating pull request...\nPR #123 created: https://github.com/org/repo/pull/123",
    "duration_ms": 2340
  },
  "explorer_result": {
    "dispatched": true,
    "summary": "Explored lib/foo.ex and test/foo_test.exs; identified existing error-tuple pattern to mirror",
    "duration_ms": 12450
  },
  "reviewer_result": {
    "dispatched": true,
    "duration_ms": 15300,
    "summary": "Reviewed the diff against all 5 acceptance criteria and the 3 pitfalls; no issues found",
    "issues_found": 0,
    "acceptance_criteria_checked": 5,
    "schema_version": "1.6",
    "status": "approved",
    "issue_counts": {"critical": 0, "important": 0, "minor": 0},
    "issues": [],
    "acceptance_criteria": [
      {"criterion": "Toggle persists across sessions", "status": "met", "evidence": "lib/foo.ex:142; test/foo_test.exs:88"}
    ],
    "project_checks": [],
    "testing_strategy": {"status": "passed", "note": "Tests cover the new toggle persistence."},
    "patterns": {"status": "passed", "note": "Follows the existing settings-update pattern."},
    "pitfalls": {"status": "passed", "note": "No listed pitfall violated."},
    "security_considerations": {"status": "passed", "note": "Theme preference scoped to the authenticated user; no injection surface."}
  },
  "workflow_steps": [
    {"name": "explorer",       "dispatched": true,  "duration_ms": 12450},
    {"name": "planner",        "dispatched": true,  "duration_ms": 8200},
    {"name": "implementation", "dispatched": true,  "duration_ms": 1820000},
    {"name": "reviewer",       "dispatched": true,  "duration_ms": 15300},
    {"name": "after_doing",    "dispatched": true,  "duration_ms": 45678},
    {"name": "before_review",  "dispatched": true,  "duration_ms": 2340}
  ]
}
```

---

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

### Mistake 4: Manually executing hooks in Claude Code
```bash
❌ Agent reads .stride.md, runs "mix test" and "mix credo" via Bash tool
   Agent captures exit code and duration
   Agent then makes the complete curl call
   (This triggers permission prompts and duplicates what hooks.json does)

✅ Agent just makes the complete curl call directly:
   curl -X PATCH .../api/tasks/:id/complete -d '{...}'
   (hooks.json PreToolUse auto-runs after_doing via stride-hook.sh
    hooks.json PostToolUse auto-runs before_review via stride-hook.sh)
```

### Mistake 5: Prompting user for permission to run hooks (non-Claude-Code)
```bash
❌ Agent says "Let me run the after_doing hooks" then waits for user approval
❌ Agent asks "Should I execute mix test?"
❌ Agent presents hook commands and pauses for confirmation

✅ Agent reads .stride.md after_doing section
   Agent immediately executes each command via Bash tool calls
   No announcement, no confirmation, no waiting
   (The user authored these hooks — they are pre-authorized)
```

### Mistake 6: Not fixing hook failures
```bash
❌ after_doing fails with test errors
   Agent calls complete endpoint anyway

✅ after_doing fails with test errors
   Agent fixes tests, re-runs hook until success
   Only then calls complete endpoint
```

---

## Red Flags - STOP

- "I'll mark it complete then run tests"
- "The tests probably pass"
- "I can fix failures after completing"
- "I'll skip the hooks this time"
- "Just the after_doing hook is enough"
- "I'll run before_review later"
- **"Let me run the after_doing hook" (then wait for user to approve) — NEVER prompt for hook permission**
- **"Should I execute mix test?" — hooks are pre-authorized, just run them**
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

---

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
