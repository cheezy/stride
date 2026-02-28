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
