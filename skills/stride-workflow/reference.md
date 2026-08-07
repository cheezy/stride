# Orchestrator Reference

Lookup material for the stride-workflow orchestrator, kept out of the hot path because running a task does not require reading it. It holds the Step Name Vocabulary for `workflow_steps`, the Edge Cases, the Complete Workflow Flowchart, the Platform Summary, the Failure Modes table, and the Quick Reference Card. **Nothing here is authoritative:** the flowchart and the card summarise the procedure, they do not define it. Everything the workflow actually executes — every step, gate, Decision Summary, schema and self-check — stays in SKILL.md, and nothing here is repeated there. Read this when you want to look something up, not to find out what to do next. The two places SKILL.md sends you here mid-run — the `workflow_steps` schema note and its ordering rule — each name an inline answer first.

### Step Name Vocabulary

The `name` field must be one of these six values. Do not invent new names — consistency across plugins is the only reason telemetry can be aggregated.

| Step name | When to record it | Orchestrator step |
|---|---|---|
| `explorer` | Codebase exploration (Claude Code: `stride:task-explorer` agent; other: manual file reads) | Step 3 |
| `planner` | Implementation planning (Claude Code: `Plan` agent; other: manual outline) | Step 3 |
| `implementation` | Writing code | Step 4 |
| `reviewer` | Code review (Claude Code: `stride:task-reviewer` agent; other: self-review) | Step 5 |
| `after_doing` | The `after_doing` hook execution | Step 6 |
| `before_review` | The `before_review` hook execution | Step 6 |

## Edge Cases

### Hook failure mid-workflow
- Blocking hooks (`after_doing`, `before_review`) must pass before completion
- Fix the root cause, re-run the hook, then proceed
- In Claude Code, dispatch `stride:hook-diagnostician` for complex failures
- Never skip a blocking hook or call complete with a failed hook result

### Task that needs_review=true
- Stop after Step 7. Do not claim the next task.
- The human reviewer will handle the review cycle.
- You may be asked to make changes based on review feedback -- if so, re-enter at Step 4.

### Goal type tasks
- Goals are decomposed, not implemented directly
- The decomposer creates child tasks -- claim and work those individually
- Each child task follows this full workflow independently

### Skills update required
- If any API response includes `skills_update_required`, run `/plugin update stride` and retry

---

## Complete Workflow Flowchart

```
STEP 0: Prerequisites
  .stride_auth.md exists? --> NO --> Ask user
  .stride.md exists?      --> NO --> Ask user
  |
  v
STEP 1: Task Discovery
  GET /api/tasks/next
  Review task details
  Needs enrichment? --> YES --> Invoke stride-enriching-tasks
  |
  v
STEP 2: Claim
  [Claude Code] POST /api/tasks/claim (hooks auto-fire)
  [Other]       Execute before_doing manually, then POST claim
  |
  v
STEP 3: Explore (Decision Matrix)
  Goal/large undecomposed? --> Decompose --> Create children --> Claim first child --> Step 1
  Small, 0-1 key_files?   --> Skip to Step 4
  Otherwise:
    [Claude Code] Dispatch task-explorer, optionally Plan agent
    [Other]       Read key_files, search patterns manually
  |
  v
STEP 4: Implement
  Write code using explorer output, plan, acceptance criteria
  Follow patterns_to_follow, avoid pitfalls
  |
  v
STEP 5: Code Review (Decision Matrix)
  Small, 0-1 key_files? --> Skip the review, BUT [Claude Code] still evaluate the
                            deep security-considerations gate (security_considerations
                            + plugin, no reviewer precondition; non-Claude-Code -->
                            skip it), then CONTINUE TO STEP 5.5 (not Step 6):
                            5.5 likewise gates on manual_tests + plugin only,
                            never on review
  Otherwise:
    [Claude Code] Dispatch task-reviewer, fix Critical/Important issues, then
                  evaluate the SAME deep security-considerations gate — it fires
                  on both branches; it is not a small-task-only step
    [Other]       Self-review against acceptance criteria
  |
  v
STEP 5.5: Manual & Exploratory Testing (Optional, Gated)
  manual_tests empty OR plugin not available OR non-Claude-Code? --> Skip to Step 6 (no failure)
  Otherwise (Claude Code + plugin available + non-empty manual_tests):
    [Claude Code] Dispatch the stride-exploratory-testing:explorer AGENT (the only sanctioned
                  surface -- never /explore, /pair, or the plugin's router skill),
                  each manual_test as a charter, capture findings (safety boundary preserved)
    Pass charter + ONE environment-context block: app reach, the user's authorized/non-prod
                  affirmative (no affirmative --> do not dispatch), tools, seed-data pointers,
                  and an explicit session budget in the INSTALLED agent's unit
    Critical whose responsible lines you wrote --> escalate fail-closed (testing_strategy failed
                  + category:testing Critical issue), fix, re-run the charter, re-review
    Critical in lines you did not write        --> report + file a follow-up defect, never block
    No structured review block in the payload  --> no escalation; never synthesize one

STEP 5.6: Harden findings into checks (Optional, Gated)
  No session / no convertible findings / no /harden / non-Claude-Code? --> Skip (no failure)
  Otherwise: dispatch /harden (no --output) --> drafts land staged in .exploratory/checks/
    Staged is the default and always safe. A check enters the suite ONLY if the file
      loads clean AND the case is green or inert -- established by RUNNING the suite once,
      never by expecting. Otherwise revert the move and file a follow-up defect.
    Anything written here is post-review: name it in completion_notes, completion_summary
      and actual_files_changed, and re-review whenever a check entered the tree
  |
  v
STEP 6: Execute Hooks
  [Claude Code] Automatic -- just make the curl call in Step 7
  [Other]       Execute after_doing (120s), then before_review (60s)
  Hook fails?   --> Fix, re-run, do NOT proceed
  |
  v
STEP 7: Complete
  PATCH /api/tasks/:id/complete with ALL required fields
  |
  v
STEP 8: Post-Completion
  needs_review=true?  --> STOP, wait for human
  needs_review=false? --> Execute after_review, loop to Step 1
```

---

## Platform Summary

| Capability | Claude Code | Cursor / Windsurf / Continue |
|---|---|---|
| Hook execution | Automatic (hooks.json) | Manual (read .stride.md, run via Bash) |
| Task exploration | Dispatch `stride:task-explorer` agent | Read key_files manually |
| Implementation planning | Dispatch Plan agent | Outline approach manually |
| Code review | Dispatch `stride:task-reviewer` agent | Self-review against criteria |
| Manual & exploratory testing | Dispatch the `stride-exploratory-testing:explorer` agent (when installed) with an explicit session budget and the user's authorized/non-production affirmative; never a command or the router skill; else fall back | Always fall back (human responsibility) |
| Hardening findings into checks | Optional Step 5.6: dispatch `/harden` (when available) to draft regression checks; staged by default, never left red in the tree | Not available — no `/harden` |
| Hook failure diagnosis | Dispatch `stride:hook-diagnostician` | Debug manually |
| Goal decomposition | Dispatch `stride:task-decomposer` agent | Break down manually, create via API |

**Both platforms follow the same step sequence.** The difference is HOW each step is executed (subagent dispatch vs manual work), not WHETHER it's executed.

---

## Failure Modes This Skill Prevents

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 5 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 7 loads the contract from stride-completing-tasks |
| Skipped hooks | Agent called complete directly | Step 6 blocks Step 7 |
| Asked user permission | Agent prompted between steps | Automation notice says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |

---

## Quick Reference Card

```
CLAUDE CODE WORKFLOW:
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 2. Claim: POST /api/tasks/claim (hooks auto-fire via hooks.json)
├─ 3. Explore (check decision matrix):
│     ├─ Goal/large undecomposed → Dispatch task-decomposer → Claim children
│     ├─ Small, 0-1 key_files → Skip to Step 4
│     └─ Otherwise → Dispatch task-explorer (+ Plan agent if medium+)
├─ 4. Implement: Write code using explorer/plan output
├─ 5. Review (check decision matrix):
│     ├─ Small, 0-1 key_files → Skip the review, but STILL evaluate the deep
│     │                         security gate (security_considerations + plugin,
│     │                         no reviewer precondition), then continue to 5.5
│     │                         (NOT Step 6 — 5.5 likewise gates on manual_tests
│     │                         + plugin, never on review)
│     └─ Otherwise → Dispatch task-reviewer, fix issues
├─ 5.5 Manual & Exploratory Testing (optional, gated):
│     ├─ manual_tests empty OR plugin unavailable → Skip to Step 6 (no failure)
│     ├─ Plugin available → Dispatch the stride-exploratory-testing:explorer AGENT only,
│     │                     manual_tests as charters (never a command, never the router skill)
│     │                     Pass charter + one env-context block incl. an explicit budget;
│     │                     no authorized/non-prod affirmative from the user → do not dispatch
│     └─ Critical finding? Lines you wrote → escalate fail-closed | Anything else → report + file
│        (no structured review block in the payload → no escalation; never synthesize one)
├─ 5.6 Harden findings into regression checks (optional, gated):
│     ├─ No session / no convertible findings / no /harden / non-Claude-Code → Skip, no failure
│     ├─ Dispatch /harden without --output; drafts stay staged in .exploratory/checks/ (safe default)
│     └─ Into the suite only if the file loads clean AND the case is inert or run-green;
│        verify by running once, else revert and file a follow-up. Surface post-review files
├─ 6. Hooks: Automatic via hooks.json (fires on curl call)
├─ 7. Complete: PATCH /api/tasks/:id/complete with ALL fields
└─ 8. Loop: needs_review=false → Step 1 | needs_review=true → STOP

OTHER ENVIRONMENTS (Cursor, Windsurf, Continue): see platform-other.md

DECISION MATRIX QUICK CHECK:
  small + 0-1 key_files  → Skip explore, plan, review
  small + 2+ key_files   → Explore + Review
  medium/large           → Explore + Plan + Review
  goal/undecomposed      → Decompose first
```

---

