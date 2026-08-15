# task-enricher reference

Reference material for the `stride:task-enricher` agent, split out of `agents/task-enricher.md` (W2081) so the agent body is not re-paid on every dispatch.

**This file carries edge cases, anti-examples and one worked example — never a rule of the enrichment contract.** The four phases, the field-type contract, the never-modify-human-authored-fields rule, the seven behaviour-matrix categories and the no-secrets rule all live inline in `agents/task-enricher.md`. An ordinary enrichment never needs this file.

## Edge Cases

### No matching files found

When Grep returns no results for the task keywords:

1. **Broaden the search** — use fewer keywords or synonyms
   ```bash
   # Original: no results for "pagination"
   Grep pattern="page|limit|offset" path="lib/"
   ```
2. **Search by directory structure** — explore the expected location
   ```bash
   Glob pattern="lib/kanban_web/live/**/*.ex"
   ```
3. **Check if this is a new feature area** — the files may need to be created. Set `key_files` with `"note": "New file to create"`. Look at similar features for the pattern to follow.
4. **If still no results** — this may be a novel feature. Set `key_files` based on project conventions (e.g., `lib/kanban/` for context, `lib/kanban_web/live/` for LiveView).

### Ambiguous context

When the task title could apply to multiple areas:

1. **Search all candidate areas** and compare relevance
   ```bash
   Grep pattern="task" path="lib/kanban/" output_mode="files_with_matches"
   Grep pattern="task" path="lib/kanban_web/" output_mode="files_with_matches"
   ```
2. **Rank by specificity** — prefer the file that most directly implements the feature.
3. **If still ambiguous** — ask the human with specific options:
   ```
   "The task could apply to:
   (A) lib/kanban/tasks.ex — the Tasks context module (data layer)
   (B) lib/kanban_web/live/task_live/index.ex — the task list LiveView (UI layer)
   Which area needs the change?"
   ```

### Multiple possible patterns

When several existing features could serve as the pattern:

1. **Prefer the most recent pattern** — it reflects the latest project conventions
   ```bash
   git log --oneline -5 -- lib/kanban_web/live/board_live/
   git log --oneline -5 -- lib/kanban_web/live/task_live/
   ```
2. **Prefer the pattern in the same directory** — sibling modules share conventions.
3. **Prefer the simpler pattern** — unless the task requires the complexity of the more advanced one.
4. **Document your choice** in `patterns_to_follow` with reasoning.

### Task in an unfamiliar technology area

When the task references technology you don't recognize in the codebase:

1. **Search `mix.exs` for related dependencies:**
   ```bash
   Grep pattern="dep_name" path="mix.exs"
   ```
2. **Check if dependency documentation is available:**
   ```bash
   mix usage_rules.search_docs "topic" -p package_name
   ```
3. **If the technology doesn't exist in the project** — note it as a dependency to add and bump complexity up one level.
4. **If still unclear** — ask the human about the technology choice.

### Minimal task with only a title

When the human provides just a title like "Add search":

1. Run Phase 1 with defaults (priority=medium) — title, type, and description are preserved as-is from human input.
2. In Phase 2, use the title keywords more aggressively:
   ```bash
   Grep pattern="search" path="lib/" output_mode="files_with_matches"
   Grep pattern="search" path="test/" output_mode="files_with_matches"
   ```
3. The `why` and `what` fields will be primarily derived from what you find in the codebase.
4. If the title is too vague to determine even the general area (e.g., "Fix it"), ask the human for clarification.


## Common Mistakes

### Mistake 1: Including reference-only files as key_files
```
❌ key_files includes a file that won't be modified (just read for patterns)

✅ Reference-only files go in patterns_to_follow, not key_files
   key_files = files that will be CHANGED
   patterns_to_follow = files to READ for guidance
```

### Mistake 2: Generic testing_strategy
```
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

### Mistake 5: Wrong field types in API submission
```
❌ "acceptance_criteria": ["Criterion 1", "Criterion 2"]
✅ "acceptance_criteria": "Criterion 1\nCriterion 2"

❌ "verification_steps": ["mix test", "mix credo"]
✅ "verification_steps": [
     {"step_type": "command", "step_text": "mix test", "position": 0}
   ]

❌ "testing_strategy": {"unit_tests": "Test the feature"}
✅ "testing_strategy": {"unit_tests": ["Test the feature"]}

❌ "security_considerations": "Authorize the user"
❌ "security_considerations": {"authz": "Authorize the user"}
✅ "security_considerations": ["Authorize the requesting user owns the resource before mutating"]
```


## Worked example

A fully-populated enriched-task object. It illustrates the field shapes the body specifies; where the two ever disagree, the body wins.

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
  ],
  "security_considerations": [
    "Scope the paginated query to tasks the current user is authorized to view — never page across other users' data",
    "Coerce and bounds-check the page/page_size params (reject negatives and absurd sizes) to avoid resource-exhaustion queries"
  ],
  "behaviour_test_matrix": [
    {
      "category": "Happy path",
      "behaviour": "Returns the first page of tasks at the default page size of 25",
      "test_name": "test/kanban/tasks_test.exs — \"paginates tasks at the default page size\"",
      "type": "unit",
      "status": "planned",
      "position": 0
    },
    {
      "category": "Boundary",
      "behaviour": "The final page returns fewer rows than page_size, and consecutive pages never overlap",
      "test_name": "test/kanban/tasks_test.exs — \"returns a short final page without overlapping rows\"",
      "type": "unit",
      "status": "planned",
      "position": 1
    },
    {
      "category": "Error / exception",
      "behaviour": "A negative or non-integer page param is rejected and falls back to page 1 without raising",
      "test_name": "test/kanban_web/live/task_live/index_test.exs — \"falls back to page 1 on a malformed page param\"",
      "type": "integration",
      "status": "planned",
      "position": 2
    },
    {
      "category": "Null / empty",
      "behaviour": "A board with no tasks renders the empty state rather than pagination controls",
      "test_name": "test/kanban_web/live/task_live/index_test.exs — \"renders the empty state with no tasks\"",
      "type": "integration",
      "status": "planned",
      "position": 3
    },
    {
      "category": "Concurrency",
      "behaviour": "N/A — pagination adds a read-only query with no new shared-state writer",
      "test_name": "N/A",
      "status": "not_applicable",
      "na_reason": "The change introduces no write path, so there is no concurrent-writer race to cover",
      "position": 4
    },
    {
      "category": "Lifecycle / wiring",
      "behaviour": "The current page survives a handle_params round trip so a refresh or back-button lands on the same page",
      "test_name": "test/kanban_web/live/task_live/index_test.exs — \"keeps the current page across handle_params\"",
      "type": "integration",
      "status": "planned",
      "position": 5
    },
    {
      "category": "Contract / serialization",
      "behaviour": "page and page_size round-trip through the URL query string as 1-based integers",
      "test_name": "test/kanban/tasks_test.exs — \"coerces page params to 1-based integers\"; test/kanban_web/live/task_live/index_test.exs — \"round-trips the page params in the URL\"",
      "type": "unit / integration",
      "status": "planned",
      "position": 6
    }
  ],
  "technical_details": {
    "data_shapes": {"page_params": "page (1-based integer), page_size (defaults to 25)"},
    "gotchas": ["The existing task query is unsorted — add a stable ORDER BY before paginating or pages will overlap"]
  }
}
```
