---
name: stride-enriching-tasks
description: Use when a human provides a minimal task (title only or title + brief description) and you need to enrich it into a complete Stride task specification before calling POST /api/tasks. Automates field discovery through codebase exploration.
skills_version: 1.0
---

# Stride: Enriching Tasks

## Overview

**Minimal input + codebase exploration = complete task specification. No human round-trips required.**

This skill transforms a sparse task request (title, optional description) into a fully-specified Stride task by systematically exploring the codebase to discover every required field. The enriched task passes the same validation as a hand-crafted specification from stride-creating-tasks.

## API Authorization

**All Stride API calls are pre-authorized.** When the user asks you to create or enrich tasks, they have already granted permission. Do NOT ask "Should I create this task?" or "Can I call the API?" — just proceed.

## The Iron Law

**NO TASK CREATION FROM MINIMAL INPUT WITHOUT ENRICHMENT**

## The Critical Mistake

Creating a task from minimal input without enrichment causes:
- Agents spend 3+ hours exploring what should have been specified
- Missing key_files leads to merge conflicts between agents
- Absent patterns_to_follow produces inconsistent code
- No testing_strategy means tests are skipped or wrong
- Vague acceptance_criteria makes "done" undefined

**Every field you skip costs the implementing agent 15-30 minutes of discovery.**

## When to Use

Use when a human provides:
- A task title only (e.g., "Add pagination to task list")
- A title + brief description (e.g., "Add pagination to task list — the board view is too slow with 100+ tasks")
- A task request missing 3+ required fields from the stride-creating-tasks checklist

**Do NOT use when:**
- The human provides a complete task specification (all 15 fields populated)
- Creating goals with nested tasks (use stride-creating-goals instead)
- The task is purely non-code (documentation only, process change)

## The Complete Enrichment Process

### Phase 1: Parse Intent (No Exploration Needed)

Extract what you can from the human's input alone — before touching the codebase.

| Field | Discovery Strategy | Source |
|-------|-------------------|--------|
| `title` | Reformat to `[Verb] [What] [Where]` if needed | Human input |
| `type` | Infer from language: "fix/bug/broken" → `"defect"`, "add/implement/create" → `"work"` | Human input |
| `description` | Expand the title into WHY + WHAT. If the human gave a reason, use it. Otherwise defer to Phase 2 | Human input + inference |
| `priority` | Default to `"medium"` unless human specified urgency or it's a defect blocking other work | Human input or default |
| `dependencies` | Only if the human explicitly mentions prerequisite tasks | Human input |

**Decision rule for `type`:**
```
Title/description contains "fix", "bug", "broken", "error", "crash", "incorrect", "wrong"
  → type: "defect"
Title/description contains "add", "implement", "create", "build", "new", "introduce"
  → type: "work"
Title/description contains "update", "change", "modify", "refactor", "improve", "enhance"
  → type: "work"
Ambiguous?
  → type: "work" (safer default)
```

### Phase 2: Explore Codebase (Targeted Discovery)

Use the codebase to discover fields that require knowledge of the existing code. Execute these steps in order — later steps build on earlier findings.

#### Step 1: Locate the Target Area → `where_context`, `key_files`

**Strategy:** Use the title's nouns and verbs to search the codebase.

1. **Extract keywords** from title (e.g., "Add pagination to task list" → `pagination`, `task`, `list`)
2. **Search for existing modules** using `Grep` with keywords against `lib/` and `lib/*_web/`
3. **Search for related LiveViews/controllers** if the task is UI-related
4. **Search for context modules** if the task involves data/business logic
5. **Read the top candidates** (max 5 files) to confirm relevance

**Decision logic for key_files:**
```
For each file found:
  - Will this file be MODIFIED by the task? → Include with note explaining the change
  - Is this file REFERENCE ONLY (pattern source)? → Do NOT include as key_file (use patterns_to_follow instead)
  - Does this file ALREADY do something similar? → Include if it needs modification, otherwise use as pattern

For new files that need to be created:
  - Include with note "New file to create"
  - Set position based on creation order
```

**For defect tasks**, additionally:
- Search for the error message or symptom in the codebase
- Check recent git log for related changes that may have introduced the bug
- Identify the failing code path

#### Step 2: Discover Patterns → `patterns_to_follow`

**Strategy:** Look at sibling files and similar implementations.

1. **Read sibling modules** in the same directory as key_files (e.g., if modifying `task_live/index.ex`, read other files in `task_live/`)
2. **Find the closest analog** — a feature similar to what's being built (e.g., if adding pagination, search for existing pagination in other views)
3. **Extract the pattern:** module structure, function naming, error handling, test approach
4. **Format as newline-separated references:**
   ```
   See lib/kanban_web/live/board_live/index.ex for LiveView event handling pattern
   Follow test structure in test/kanban_web/live/board_live/index_test.exs
   ```

**Decision logic:**
```
Found a similar feature in the codebase?
  → Extract its pattern (module structure, naming, test approach)
Found sibling modules in the same directory?
  → Note their common structure as the pattern to follow
No similar feature exists?
  → Note the general project conventions (from CLAUDE.md/AGENTS.md patterns)
```

#### Step 3: Analyze Testing → `testing_strategy`

**Strategy:** Find existing test files for the key_files and infer what tests are needed.

1. **Map key_files to test files** (e.g., `lib/kanban/tasks.ex` → `test/kanban/tasks_test.exs`)
2. **Read existing test files** to understand:
   - Test helper modules used (`ConnCase`, `DataCase`, custom helpers)
   - Factory/fixture patterns
   - Assertion style
3. **Generate test cases** based on the task's scope:
   - `unit_tests`: One per public function being added/modified
   - `integration_tests`: End-to-end scenarios for the feature
   - `manual_tests`: Visual/UX verification if UI is involved
   - `edge_cases`: Null inputs, empty lists, concurrent access, permission boundaries
   - `coverage_target`: "100% for new/modified functions"

**For defect tasks**, additionally:
- Include a regression test that reproduces the original bug
- Test the fix doesn't break related functionality

#### Step 4: Define Verification → `verification_steps`

**Strategy:** Generate concrete, runnable verification commands.

1. **Always include** a `mix test` step targeting the specific test file(s)
2. **Always include** `mix credo --strict` for code quality
3. **Add manual steps** for UI changes (describe what to click/verify)
4. **Add command steps** for any migrations, seeds, or data changes

**Template:**
```json
[
  {"step_type": "command", "step_text": "mix test test/path/to/test.exs", "expected_result": "All tests pass", "position": 0},
  {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 1},
  {"step_type": "manual", "step_text": "[Describe UI verification]", "expected_result": "[Expected visual result]", "position": 2}
]
```

#### Step 5: Identify Risks → `pitfalls`

**Strategy:** Analyze the code area for common traps.

1. **Check for shared state** — does the file use PubSub, assigns, or global state that could cause side effects?
2. **Check for N+1 queries** — does the code area have Ecto preloads or joins that need attention?
3. **Check for authorization** — does the code area enforce user permissions that must be maintained?
4. **Check for existing tests** — are there tests that could break from the change?
5. **Check CLAUDE.md/AGENTS.md** for project-specific pitfalls (dark mode, translations, etc.)

**Common pitfall categories:**
- "Don't modify [shared component] — it's used by [N] other views"
- "Don't add Ecto queries directly in LiveViews — use context modules"
- "Don't forget translations for user-visible text"
- "Don't break existing tests in [related test file]"

#### Step 6: Define Done → `acceptance_criteria`

**Strategy:** Convert the task intent into observable, testable outcomes.

1. **Start with the user-facing outcome** ("Pagination controls appear below the task list")
2. **Add technical requirements** ("Query limits results to 25 per page")
3. **Add negative criteria** ("Existing task list functionality unchanged")
4. **Add quality criteria** ("All existing tests still pass")

**Format as newline-separated string:**
```
Pagination controls visible below task list
Page size defaults to 25 tasks
Next/Previous navigation works correctly
URL updates with page parameter
All existing tests still pass
```

### Phase 3: Estimate Complexity → `complexity`

**Heuristics:**

| Signal | Complexity |
|--------|-----------|
| 1-2 key_files, single module change, existing pattern to follow | `"small"` |
| 3-5 key_files, multiple modules, some new patterns needed | `"medium"` |
| 5+ key_files, new architecture, cross-cutting concerns, migrations | `"large"` |
| Defect with clear reproduction + obvious fix | `"small"` |
| Defect requiring investigation across modules | `"medium"` |
| Defect in complex system interaction or race condition | `"large"` |

**Additional signals:**
- Database migration required? → Bump up one level
- New dependencies needed? → Bump up one level
- UI + backend changes? → At least `"medium"`
- Security-sensitive code? → At least `"medium"`

### Phase 4: Assemble and Validate

Combine all discovered fields into the final task specification.

**Pre-submission checklist:**
- [ ] `title` follows `[Verb] [What] [Where]` format
- [ ] `type` is exactly `"work"` or `"defect"`
- [ ] `description` contains both WHY and WHAT
- [ ] `complexity` matches the heuristic analysis
- [ ] `priority` is set (default `"medium"` if unspecified)
- [ ] `why` explains the problem or value
- [ ] `what` describes the specific change
- [ ] `where_context` points to the code/UI area
- [ ] `key_files` is an array of objects with `file_path`, `note`, `position`
- [ ] `dependencies` is an array (empty `[]` if none)
- [ ] `verification_steps` is an array of objects with `step_type`, `step_text`, `position`
- [ ] `testing_strategy` has `unit_tests`, `integration_tests`, `manual_tests` as arrays of strings
- [ ] `acceptance_criteria` is a newline-separated string
- [ ] `patterns_to_follow` is a newline-separated string
- [ ] `pitfalls` is an array of strings
- [ ] `needs_review` is set to `false`

## Enrichment Workflow Flowchart

```
Human provides minimal input (title + optional description)
    ↓
Phase 1: Parse Intent
├─ Extract title → reformat to [Verb] [What] [Where]
├─ Infer type (work vs defect) from language
├─ Set priority (from input or default "medium")
├─ Note any explicit dependencies
    ↓
Phase 2: Explore Codebase
├─ Step 1: Grep for keywords → locate target files
│   ├─ Read top candidates (max 5)
│   ├─ Determine key_files (files to modify)
│   └─ Set where_context from directory/module location
├─ Step 2: Read sibling modules → find patterns
│   ├─ Identify closest analog feature
│   └─ Extract patterns_to_follow
├─ Step 3: Map key_files to test files → build testing_strategy
│   ├─ Read existing test patterns
│   └─ Generate unit/integration/manual/edge test cases
├─ Step 4: Generate verification_steps from test files + credo
├─ Step 5: Analyze code area for pitfalls
│   └─ Check shared state, N+1, auth, existing tests
└─ Step 6: Convert intent to acceptance_criteria
    ↓
Phase 3: Estimate Complexity
├─ Count key_files, assess pattern novelty
└─ Apply heuristic table → small/medium/large
    ↓
Phase 4: Assemble and Validate
├─ Combine all fields into API-compatible JSON
├─ Run pre-submission checklist
└─ Submit via POST /api/tasks
```

## When to Explore vs When to Ask the Human

**Explore (default — prefer automation):**
- Which files to modify → Grep + Read
- What patterns exist → Read sibling modules
- What tests to write → Read existing test files
- What could go wrong → Analyze code area

**Ask the human ONLY when:**
- The title is completely ambiguous (could mean 3+ different features)
- The task requires domain knowledge not in the codebase (business rules, legal requirements)
- Multiple valid approaches exist with significantly different trade-offs (e.g., client-side vs server-side pagination)
- The task affects external systems not visible in the codebase (third-party APIs, infrastructure)

**Decision rule:**
```
Can I determine the answer from the codebase alone?
  → YES: Explore and decide
  → NO, but I can make a reasonable default?
  → YES: Use the default, note it in the description
  → NO: Ask the human (provide 2-3 specific options, not open-ended questions)
```

## Output Format

The enriched task MUST match the Stride API task schema exactly:

```json
{
  "title": "Add pagination to task list view",
  "type": "work",
  "description": "The board view becomes slow with 100+ tasks. Add server-side pagination to the task list to improve load times and usability.",
  "complexity": "medium",
  "priority": "medium",
  "needs_review": false,
  "why": "Board view performance degrades with large task counts, impacting user productivity",
  "what": "Server-side pagination with configurable page size for the task list LiveView",
  "where_context": "lib/kanban_web/live/task_live/ — task list LiveView and related context module",
  "estimated_files": "3-5",
  "key_files": [
    {"file_path": "lib/kanban_web/live/task_live/index.ex", "note": "Add pagination params and event handlers", "position": 0},
    {"file_path": "lib/kanban/tasks.ex", "note": "Add paginated query function", "position": 1},
    {"file_path": "lib/kanban_web/live/task_live/index.html.heex", "note": "Add pagination controls to template", "position": 2}
  ],
  "dependencies": [],
  "verification_steps": [
    {"step_type": "command", "step_text": "mix test test/kanban_web/live/task_live/index_test.exs", "expected_result": "All pagination tests pass", "position": 0},
    {"step_type": "command", "step_text": "mix test test/kanban/tasks_test.exs", "expected_result": "Paginated query tests pass", "position": 1},
    {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues found", "position": 2},
    {"step_type": "manual", "step_text": "Navigate to task list with 50+ tasks and verify pagination controls work", "expected_result": "Page navigation works, 25 tasks per page", "position": 3}
  ],
  "testing_strategy": {
    "unit_tests": [
      "Test paginated query returns correct page size",
      "Test page parameter defaults to 1",
      "Test out-of-range page returns empty list"
    ],
    "integration_tests": [
      "Test full pagination flow: load page, click next, verify new results"
    ],
    "manual_tests": [
      "Visual verification of pagination controls",
      "Test with 0, 1, 25, and 100+ tasks"
    ],
    "edge_cases": [
      "Empty task list (0 tasks)",
      "Exactly one page of tasks (25)",
      "Invalid page parameter in URL"
    ],
    "coverage_target": "100% for pagination query and LiveView handlers"
  },
  "acceptance_criteria": "Pagination controls visible below task list\nPage size defaults to 25 tasks\nNext/Previous navigation works correctly\nURL updates with page parameter\nPerformance improved for 100+ tasks\nAll existing tests still pass",
  "patterns_to_follow": "See lib/kanban_web/live/board_live/index.ex for LiveView event handling pattern\nFollow existing query pattern in lib/kanban/tasks.ex for Ecto pagination\nSee test/kanban_web/live/board_live/index_test.exs for LiveView test structure",
  "pitfalls": [
    "Don't add Ecto queries directly in the LiveView — use the Tasks context module",
    "Don't forget to handle the case where page param is missing or invalid",
    "Don't break existing task list sorting or filtering",
    "Don't forget translations for pagination labels"
  ]
}
```

## Handling Defect Tasks

Defect enrichment follows the same phases but with adjusted strategies:

**Phase 1 differences:**
- `type` is always `"defect"`
- `description` should include: symptom, expected behavior, reproduction steps (if known)
- `why` focuses on the impact of the bug

**Phase 2 differences:**
- Step 1: Search for error messages, stack traces, or the buggy behavior in code
- Step 3: Always include a regression test that reproduces the bug
- Step 5: Check git log for recent changes to the affected area
- Step 6: Acceptance criteria must include "Bug no longer reproducible"

**Example defect `description`:**
```
"When a user submits a task with special characters in the title, the form crashes with a 500 error. Expected: task saves successfully with escaped characters. Impact: users cannot create tasks with common characters like & and <."
```

## Red Flags - STOP

- "The title is clear enough, I'll skip enrichment"
- "I'll just fill in the required fields with placeholders"
- "Exploring the codebase takes too long, I'll guess"
- "The human can add details later"
- "This is a simple task, it doesn't need all 15 fields"

**All of these mean: Run the full enrichment process. Every field saves 15-30 minutes for the implementing agent.**

## Rationalization Table

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Title is self-explanatory" | Missing key_files → 2+ hours file hunting | Agent explores wrong area of codebase |
| "I'll guess the key_files" | Wrong files → merge conflicts | Blocks other agents, requires rework |
| "Testing strategy is obvious" | Missing edge cases → bugs in production | Incomplete tests miss real failures |
| "Patterns aren't important" | Inconsistent code → review rejection | Task must be redone following patterns |
| "Pitfalls are just warnings" | Missing pitfalls → repeating known mistakes | Same bugs keep reappearing |
| "I'll enrich only the hard fields" | Partial enrichment → partial quality | 50% enriched task ≈ minimal task in practice |

## Common Mistakes

### Mistake 1: Including reference-only files as key_files
```json
❌ key_files includes a file that won't be modified (just read for patterns)
✅ Reference-only files go in patterns_to_follow, not key_files
   key_files = files that will be CHANGED
   patterns_to_follow = files to READ for guidance
```

### Mistake 2: Generic testing_strategy
```json
❌ "unit_tests": ["Test the feature works"]
✅ "unit_tests": [
     "Test paginated query returns exactly page_size results",
     "Test paginated query with offset skips correct number of records",
     "Test paginated query with empty result set returns []"
   ]
```

### Mistake 3: Skipping exploration for "simple" tasks
```
❌ "This is just adding a field, I know where it goes"
   Result: missed migration, missed test, missed validation

✅ Always run Phase 2, even for small tasks
   Result: discovered the field also needs a changeset validator and index
```

### Mistake 4: Open-ended questions to the human
```
❌ "What should I do for this task?"
✅ "I found two approaches: (A) add pagination to the existing LiveView, or
    (B) create a new paginated component. A is simpler but B is more reusable.
    Which do you prefer?"
```

## Quick Reference Card

```
ENRICHMENT PHASES:
├─ Phase 1: Parse Intent (no codebase access needed)
│   ├─ title → [Verb] [What] [Where]
│   ├─ type → "work" or "defect" from language cues
│   ├─ priority → from input or default "medium"
│   └─ dependencies → from human input only
│
├─ Phase 2: Explore Codebase (6 ordered steps)
│   ├─ Step 1: Grep keywords → key_files + where_context
│   ├─ Step 2: Read siblings → patterns_to_follow
│   ├─ Step 3: Map to tests → testing_strategy
│   ├─ Step 4: Build commands → verification_steps
│   ├─ Step 5: Analyze risks → pitfalls
│   └─ Step 6: Define outcomes → acceptance_criteria
│
├─ Phase 3: Estimate Complexity
│   └─ Heuristic: files × pattern_novelty × migrations
│
└─ Phase 4: Assemble and Validate
    ├─ Combine all fields into API JSON
    ├─ Run 16-item checklist
    └─ Submit via POST /api/tasks

FIELD DISCOVERY ORDER (optimized for dependency):
  1. title (reformat)        — from input
  2. type (infer)            — from input
  3. key_files (search)      — enables steps 4-8
  4. where_context (derive)  — from key_files location
  5. patterns_to_follow      — from key_files siblings
  6. testing_strategy        — from key_files test mapping
  7. verification_steps      — from testing_strategy
  8. pitfalls                — from key_files analysis
  9. acceptance_criteria     — from task intent + code context
 10. description (expand)    — from all above
 11. why (articulate)        — from input + context
 12. what (specify)          — from key_files + patterns
 13. complexity (estimate)   — from all signals
 14. priority               — from input or default
 15. dependencies           — from input only

DECISION RULE:
  Can determine from codebase? → Explore and decide
  Reasonable default exists?   → Use default, note in description
  Neither?                     → Ask human with 2-3 specific options
```

---
**References:** For the full field reference, see stride-creating-tasks SKILL.md. For codebase exploration patterns, see the task-explorer agent definition. For endpoint details, see the [API Reference](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/api/README.md).
