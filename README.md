# Stride

Task lifecycle skills for [Stride](https://www.stridelikeaboss.com) kanban — a task management platform designed for AI agents.

## Installation

Add the Stride marketplace to Claude Code:

```
/plugin marketplace add cheezy/stride-marketplace
```

Then install the Stride plugin:

```
/plugin install stride@stride-marketplace
```

## Mandatory Skill Chain

Every Stride skill is **MANDATORY** — not optional. Each skill contains required API fields, hook execution patterns, and validation rules that are ONLY documented in that skill. Attempting to call Stride API endpoints without invoking the corresponding skill first results in API rejections, malformed data, or hours of wasted rework.

### Workflow Order

When working on tasks, skills MUST be invoked in this order:

```
stride:stride-claiming-tasks          ← BEFORE calling GET /api/tasks/next or POST /api/tasks/claim
    ↓
stride:stride-subagent-workflow       ← AFTER claim succeeds, BEFORE implementation (Claude Code only)
    ↓
[implementation]
    ↓
stride:stride-completing-tasks        ← BEFORE calling PATCH /api/tasks/:id/complete
```

When creating tasks or goals:

```
stride:stride-enriching-tasks         ← WHEN task has empty key_files/testing_strategy/verification_steps
    ↓
stride:stride-creating-tasks          ← BEFORE calling POST /api/tasks (work tasks or defects)
stride:stride-creating-goals          ← BEFORE calling POST /api/tasks/batch (goals with nested tasks)
```

### Why This Matters

| Without skill | What happens |
|---------------|-------------|
| Claim without `stride-claiming-tasks` | API rejects — missing `before_doing_result` |
| Complete without `stride-completing-tasks` | 3+ failed API calls — missing `completion_summary`, `actual_complexity`, `actual_files_changed`, `after_doing_result`, `before_review_result` |
| Create task without `stride-creating-tasks` | Malformed `verification_steps`, `key_files`, `testing_strategy` — causes 3+ hours wasted during implementation |
| Create goal without `stride-creating-goals` | 422 error — wrong root key (`"tasks"` instead of `"goals"`) |
| Skip `stride-subagent-workflow` | No codebase exploration, no code review — wrong approach, missed acceptance criteria |
| Skip `stride-enriching-tasks` | Sparse task specs → implementing agent wastes 3+ hours on unfocused exploration |

## Skills

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Contains ALL 5 required completion fields and both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings).

### stride-creating-goals

**MANDATORY** before batch creation or goal creation. Contains the only correct batch format — root key must be `"goals"` not `"tasks"`. Most common API error when skipped.

### stride-enriching-tasks

**MANDATORY** when a task has sparse specification. Transforms minimal human-provided specs into complete implementation-ready tasks through automated codebase exploration. 5 minutes of enrichment saves 3+ hours of unfocused implementation.

### stride-subagent-workflow

**MANDATORY** after claiming any task (Claude Code only). Contains the decision matrix for dispatching task-explorer, task-reviewer, task-decomposer, and hook-diagnostician agents. Determines exploration and review strategy based on task complexity and key_files count.

## Agents

### stride:task-explorer

A read-only codebase exploration agent dispatched after claiming a task. Reads every file listed in `key_files`, finds related test files, searches for patterns referenced in `patterns_to_follow`, navigates to `where_context`, and returns a structured summary so the primary agent can start coding with full context.

### stride:task-decomposer

Breaks goals and large tasks into dependency-ordered child tasks. Uses scope analysis, task boundary identification, and dependency ordering to produce implementation-ready task arrays with complexity estimates, key files, and testing strategies per task. Claude Code only.

### stride:task-reviewer

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, and verifies `testing_strategy` alignment. Returns categorized issues (Critical/Important/Minor) with file and line references.

### stride:hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Accepts both structured JSON from Claude Code hooks and raw text from legacy agent-executed hooks. Dispatched automatically when blocking hooks fail during the completion workflow. Claude Code only.

## Automatic Hook Execution (Claude Code Hooks)

When the Stride plugin is enabled, `.stride.md` hooks execute **automatically without permission prompts** via Claude Code's hook system. The plugin ships a `hooks/hooks.json` that registers PreToolUse and PostToolUse hooks on Bash commands, and a `hooks/stride-hook.sh` script that:

1. Detects Stride API calls (claim, complete, mark_reviewed) in Bash tool commands
2. Parses the corresponding section from your `.stride.md`
3. Executes each uncommented command sequentially
4. Caches task environment variables (`$TASK_IDENTIFIER`, `$TASK_TITLE`, etc.) from the claim response for use in all subsequent hooks
5. Outputs structured JSON for diagnostics on both success and failure
6. Blocks tool calls (exit 2) on failure in PreToolUse context

**Hook routing:**

| Claude Code Event | API Endpoint Pattern | Stride Hook |
|---|---|---|
| PostToolUse (Bash) | `/api/tasks/claim` | `before_doing` |
| PreToolUse (Bash) | `/api/tasks/:id/complete` | `after_doing` (blocks completion on failure) |
| PostToolUse (Bash) | `/api/tasks/:id/complete` | `before_review` |
| PostToolUse (Bash) | `/api/tasks/:id/mark_reviewed` | `after_review` |

**Note:** Add `.stride-env-cache` to your `.gitignore` — this temp file caches task metadata between hook invocations and is cleaned up automatically after the `after_review` hook.

## Configuration

Before using Stride skills, you need two configuration files in your project root:

### `.stride_auth.md`

Contains your API credentials (never commit this file):

```markdown
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `your-token-here`
- **User Email:** `your-email@example.com`
```

### `.stride.md`

Contains hook scripts that run during the task lifecycle:

```markdown
## before_doing
git pull origin main
mix deps.get

## after_doing
mix test
mix credo --strict
```

## Updating

To update to the latest version of Stride skills:

```
/plugin update stride
```

## License

MIT — see [LICENSE](LICENSE) for details.
