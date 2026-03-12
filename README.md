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

## Skills

### stride-claiming-tasks

Enforces the proper task claiming workflow including prerequisite verification, before_doing hook execution, and immediate transition to active work. Prevents merge conflicts and outdated code by ensuring setup runs before any task is claimed.

### stride-completing-tasks

Manages the task completion workflow with after_doing hook execution (tests, linting, formatting), completion API calls, and review lifecycle management. Ensures validation passes before marking work as done.

### stride-creating-tasks

Comprehensive task specification enforcement for creating individual work tasks and defects. Prevents underspecified tasks that lead to failed implementations by requiring detailed context, acceptance criteria, key files, and verification steps.

### stride-creating-goals

Goal and batch creation with dependency management. Handles creating large initiatives with multiple nested tasks, proper dependency ordering, and cross-goal coordination.

### stride-enriching-tasks

Transforms minimal task specifications into full implementation-ready specs. Explores the codebase in 4 phases to populate key_files, testing_strategy, verification_steps, acceptance_criteria, patterns_to_follow, and other fields. Handles defect tasks, title-only tasks, and ambiguous contexts.

### stride-subagent-workflow

Orchestrates specialized subagents at four points in the task lifecycle: goal decomposition, codebase exploration after claiming, implementation planning for complex tasks, and code review before completion hooks. Uses a decision matrix based on task complexity and key_files count to determine which subagents to dispatch — zero overhead for simple tasks, full coverage for complex ones. Claude Code only.

## Agents

### stride:task-explorer

A read-only codebase exploration agent dispatched after claiming a task. Reads every file listed in `key_files`, finds related test files, searches for patterns referenced in `patterns_to_follow`, navigates to `where_context`, and returns a structured summary so the primary agent can start coding with full context.

### stride:task-decomposer

Breaks goals and large tasks into dependency-ordered child tasks. Uses scope analysis, task boundary identification, and dependency ordering to produce implementation-ready task arrays with complexity estimates, key files, and testing strategies per task. Claude Code only.

### stride:task-reviewer

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, and verifies `testing_strategy` alignment. Returns categorized issues (Critical/Important/Minor) with file and line references.

### stride:hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Dispatched automatically when blocking hooks fail during the completion workflow. Claude Code only.

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
