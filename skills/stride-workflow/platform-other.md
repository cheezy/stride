# Other Environments Reference (Cursor / Windsurf / Continue)

Read this whenever Platform Detection resolved to **Other Environments** — you have no `Agent` tool, or you were unsure and took the safe default. It holds the non-Claude-Code branches extracted from Steps 1, 2, 3, 5 and 6, plus the Other Environments half of the Quick Reference Card. Two non-Claude-Code branches deliberately live elsewhere and are **not** repeated here: Step 3 Branch A's goal-decomposition item, which stays inline in SKILL.md because it is one item mid-list, and Step 5.5's always-fall-back rule, which lives in `optional-exploratory-testing.md`. Read this **alongside** SKILL.md, not instead of it. SKILL.md still owns the step sequence and every gate and Decision Summary, and none of that is repeated here — a row you need may well be there rather than here. The Platform Summary table and the Decision Matrix Quick Check are in `reference.md`, alongside the Claude Code half of the Quick Reference Card. The headings below are verbatim from SKILL.md; each `##` above one names the step it came from.

## Step 1: Task Discovery — the enrichment branch

#### Other Environments: Invoke the Enrichment Skill

1. Invoke `stride-enriching-tasks` and walk through its Manual Walkthrough Phases (Phase 1 intent parse → Phase 2 codebase exploration → Phase 3 complexity → Phase 4 18-item checklist).
2. Submit the assembled JSON via `PATCH /api/tasks/:id` per the API Integration block in that skill.

## Step 2: Claim the Task

### Other Environments (manual hooks)

1. Read `.stride.md` `## before_doing` section
2. Execute each command line immediately via Bash -- no permission prompts, no confirmation
3. Capture `exit_code`, `output`, `duration_ms`
4. If hook fails (non-zero exit): fix the issue, re-run -- do NOT proceed
5. Call `POST /api/tasks/claim` with the captured `before_doing_result`

## Step 3: Explore the Codebase (Decision Matrix) — Branch C only (medium+, or 2+ key_files)

#### Other Environments: Manual Exploration

1. Read each file in `key_files` to understand current state
2. Search for patterns mentioned in `patterns_to_follow`
3. Find related test files
4. For medium+ tasks, outline your implementation approach before coding

## Step 5: Code Review (Decision Matrix)

### Other Environments: Self-Review

Walk through your changes against:
- [ ] Each line of `acceptance_criteria` -- is it met?
- [ ] Each item in `pitfalls` -- did you avoid it?
- [ ] `patterns_to_follow` -- does your code match?
- [ ] `testing_strategy` -- did you write the specified tests?
- [ ] `behaviour_test_matrix` -- if the task supplied one (it is optional, so many tasks will not): does every row's named test exist, and does each row's `status` reflect reality?

## Step 6: Execute Hooks

### Other Environments (manual hooks)

**Execute each hook immediately -- no permission prompts, no confirmation.**

1. **after_doing hook** (blocking, 120s timeout):
   - Read `.stride.md` `## after_doing` section
   - Execute each command line one at a time via Bash
   - Capture `exit_code`, `output`, `duration_ms`
   - If fails: fix issues, re-run until success. Do NOT proceed while failing.

2. **before_review hook** (blocking, 60s timeout):
   - Read `.stride.md` `## before_review` section
   - Execute each command line one at a time via Bash
   - Capture `exit_code`, `output`, `duration_ms`
   - If fails: fix issues, re-run until success. Do NOT proceed while failing.

## Quick Reference Card — the Other Environments half

```
OTHER ENVIRONMENTS (Cursor, Windsurf, Continue):
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 2. Claim: Execute before_doing manually, then POST /api/tasks/claim
├─ 3. Explore (check decision matrix):
│     ├─ Goal/large undecomposed → Break down manually → Create via API
│     ├─ Small, 0-1 key_files → Skip to Step 4
│     └─ Otherwise → Read key_files, search patterns, outline approach
├─ 4. Implement: Write code using task metadata as guide
├─ 5. Review (check decision matrix):
│     ├─ Small, 0-1 key_files → Skip the review, continue to 5.5 (NOT Step 6 —
│     │                         5.5 gates on manual_tests + plugin, never on review)
│     └─ Otherwise → Self-review against acceptance criteria + pitfalls
├─ 5.5 Manual & Exploratory Testing (optional, gated):
│     └─ No Agent tool → Always fall back (note manual tests as human responsibility)
├─ 6. Hooks: Execute after_doing (120s) + before_review (60s) manually
├─ 7. Complete: PATCH /api/tasks/:id/complete with ALL fields + hook results
└─ 8. Loop: needs_review=false → Step 1 | needs_review=true → STOP
```
