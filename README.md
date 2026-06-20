# Stride

Drive the full [Stride](https://www.stridelikeaboss.com) kanban task lifecycle from Claude Code — claim, explore, review, and complete tasks, with automatic lifecycle hooks. Stride is a task management platform designed for AI agents.

> **Security:** for what the plugin runs on your machine, what data leaves it,
> and how your API token is handled, see **[SECURITY.md](SECURITY.md)**.

> **External service:** this plugin talks to your Stride server —
> `https://www.stridelikeaboss.com` by default — over HTTPS, authenticated with
> a bearer token you supply. It contacts no other host. See
> [SECURITY.md](SECURITY.md) for exactly what is sent.

## Installation

**From the community plugin directory** (once the listing is approved):

```
/plugin install stride@claude-community
```

**From the Stride marketplace** (available today):

```
/plugin marketplace add cheezy/stride-marketplace
/plugin install stride@stride-marketplace
```

## Prerequisites

- A **Stride account and API token** from [stridelikeaboss.com](https://www.stridelikeaboss.com).
- Two files in your project root: **`.stride_auth.md`** (your API URL + token —
  **never commit it**) and **`.stride.md`** (your lifecycle hook commands). See
  [Configuration](#configuration) below for the exact format.

## What's in this plugin

- **7 skills** — `stride-workflow` (the recommended orchestrator), plus
  `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`,
  `stride-creating-goals`, `stride-enriching-tasks`, and
  `stride-subagent-workflow`.
- **5 subagents** (Claude Code) — `task-explorer`, `task-enricher`,
  `task-decomposer`, `task-reviewer`, and `hook-diagnostician`.
- **2 slash commands** — `/stride:create-tasks` and `/stride:create-goals`.
- **Hooks** — `hooks/hooks.json` wiring plus `stride-hook.sh` and
  `stride-skill-gate.sh` (with `.ps1` equivalents) for automatic lifecycle hook
  execution and the sub-skill gate.

Each component is detailed below.

## Mandatory Skill Chain

Every Stride skill is **MANDATORY** — not optional. Each skill contains required API fields, hook execution patterns, and validation rules that are ONLY documented in that skill. Attempting to call Stride API endpoints without invoking the corresponding skill first results in API rejections, malformed data, or hours of wasted rework.

### Workflow Order

**Recommended:** Use the single orchestrator skill for the complete lifecycle:

```
stride:stride-workflow                ← Invoke ONCE — handles claim → explore → implement → review → complete
```

**Standalone mode** (when you need individual skills):

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

### stride-workflow

**RECOMMENDED** entry point for all task work. Single orchestrator that walks through the complete lifecycle: prerequisites, claiming, codebase exploration, implementation, code review, hooks, and completion. Handles both Claude Code (with subagent dispatch) and other environments (Cursor, Windsurf, Continue). Eliminates the need to remember which skills to invoke at which moments.

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Contains ALL 5 required completion fields and both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings). Also documents the optional `technical_details` field — a free-form JSON object (no fixed keys) for any extra technical context; it is optional everywhere and is not one of the five review_queue-scored fields. (v1.30.0+) documents the optional `created_by_agent` field — set it to the plugin's own agent name (the same value sent as `agent_name` on claim/complete) so the `/agents` feed attributes the creating agent; it is create-only and forbidden on `PATCH`.

### stride-creating-goals

**MANDATORY** before batch creation or goal creation. Contains the only correct batch format — root key must be `"goals"` not `"tasks"`. Most common API error when skipped. (v1.30.0+) documents `created_by_agent` on the batch goal — set once on the goal; the server propagates it to every nested child task.

### stride-enriching-tasks

**MANDATORY** when a task has sparse specification. Transforms minimal human-provided specs into complete implementation-ready tasks through automated codebase exploration. 5 minutes of enrichment saves 3+ hours of unfocused implementation.

### stride-subagent-workflow

**MANDATORY** after claiming any task (Claude Code only). Contains the decision matrix for dispatching task-explorer, task-reviewer, task-decomposer, and hook-diagnostician agents. Determines exploration and review strategy based on task complexity and key_files count.

## Agents

### stride:task-explorer

A read-only codebase exploration agent dispatched after claiming a task. Reads every file listed in `key_files`, finds related test files, searches for patterns referenced in `patterns_to_follow`, navigates to `where_context`, and returns a structured summary so the primary agent can start coding with full context.

### stride:task-enricher

Explores the codebase to fill in a sparse task *before* it is claimed — discovers `key_files`, `patterns_to_follow`, `testing_strategy`, `verification_steps`, `security_considerations`, `pitfalls`, and a complexity estimate, and returns a single enriched-task JSON object that the orchestrator PATCHes onto the existing task. It never rewrites the human-authored title, type, or description. Claude Code only.

### stride:task-decomposer

Breaks goals and large tasks into dependency-ordered child tasks. Uses scope analysis, task boundary identification, and dependency ordering to produce implementation-ready task arrays with complexity estimates, key files, and testing strategies per task. Claude Code only.

### stride:task-reviewer

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, verifies `testing_strategy` alignment, and confirms the task's `security_considerations` were implemented. Returns categorized issues (Critical/Important/Minor) with file and line references.

The canonical `reviewer_result` JSON schema (`schema_version` `"1.4"`) — `summary`, `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]` with the `met`/`not_met` enum, `project_checks[]` (v1.18.0+; per-entry `status` enum `met`/`not_met`/`not_applicable` and full-checklist emission as of v1.23.0), and the per-section `testing_strategy` / `patterns` / `pitfalls` (v1.19.0+) / `security_considerations` (v1.21.0+) verdict objects (`passed`/`failed`/`not_assessed`) — is defined in [`agents/task-reviewer.md`](agents/task-reviewer.md) and is the schema of record for all six reviewer-variant prompts. Variant prompts cite that path; do not duplicate the schema elsewhere. The full structured block is persisted **verbatim** as `reviewer_result`: orchestrators and completion skills passthrough every key the reviewer emits and never re-enumerate an allow-list of which keys to copy (v1.22.1), so any field the schema gains flows through automatically. As of **v1.24.0**, review reports must be delivered **complete, with no exceptions**: the orchestrator passes the reviewer every field the task supplies (including `security_considerations`), `not_assessed` is reserved strictly for a section the task left empty, the structured output is carried through by a mechanical whole-object copy, and a mandatory pre-submission self-check refuses to complete a task whose review is thin or leaves a task-supplied section unassessed. The persisted block is rendered by the Kanban review queue (issue list, acceptance verdicts, code-review checks, and the four section-verdict tiles).

### stride:hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Accepts both structured JSON from Claude Code hooks and raw text from legacy agent-executed hooks. Dispatched automatically when blocking hooks fail during the completion workflow. Claude Code only.

## Commands

Two slash commands create Stride work from existing project markdown. Both wrap the `stride-workflow` orchestrator (which dispatches the matching creation sub-skill) — they never call the creation sub-skills directly, and the orchestrator's activation marker and sub-skill gate still apply.

### /stride:create-tasks

```
/stride:create-tasks [--dir <path>] [task description]
```

Create one or more work tasks (or defects). With `--dir <path>` — alias `--context`, and also accepting `--dir=<path>` — the command loads the `.md` files in that directory as a **read-only context bundle** and forwards it through `stride-workflow` to `stride-creating-tasks`, which mines it for `key_files`, `patterns_to_follow`, `acceptance_criteria` / `description`, and `pitfalls`. A `--dir` path that is set but missing is an error (non-zero exit); a directory with no `.md` files warns and continues. The context **augments** your interactive intent — it never overrides your confirmation or excuses a blank required field (including the five review_queue-scored fields). Only files inside `--dir` are read.

### /stride:create-goals

```
/stride:create-goals [--dir <path>] [goal description]
```

The goal-creating sibling of `/stride:create-tasks`, with identical `--dir` / `--context` parsing and validation. Routes through `stride-workflow` to `stride-creating-goals`, producing a goal with nested tasks seeded from the context bundle. The batch `"goals"` root key and index-based dependency rules are unchanged.

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
| PostToolUse (Bash) | `/api/tasks/:id/complete` | `before_review` (+ `after_goal` if the response bundles it) |
| PostToolUse (Bash) | `/api/tasks/:id/mark_reviewed` | `after_review` (+ `after_goal` if the response bundles it) |

**`after_goal` (v1.17.0+):** the server bundles an `after_goal` entry alongside the primary hook in the response of `/complete` or `/mark_reviewed` when the completing task is the final child of a parent goal. The plugin auto-executes the local `## after_goal` section as a blocking hook (60s timeout, same shape as `after_doing`) and emits a structured result on stdout. The agent forwards the result via `PATCH /api/tasks/:goal_id/after_goal` to flip the goal to Done. A missing `## after_goal` section in `.stride.md` is a clean no-op (back-compat — older `.stride.md` files keep working unmodified). The hook receives `GOAL_ID` / `GOAL_IDENTIFIER` / `GOAL_TITLE` / `GOAL_DESCRIPTION` env vars from the server's `hook.env`, and is general-purpose (Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses — not just PR creation).

**Note:** Add `.stride-env-cache`, `.stride-changed-files.json`, and `.stride-diff-upload-state` to your `.gitignore` — all three are temp files written between hook invocations. `.stride-env-cache` caches task metadata (including the base commit captured at claim time — **(v1.28.0+)** this `TASK_BASE_REF` is now refreshed on **every** claim, including when the claim response is too large to parse inline and Claude Code persists it to a file: the hook recovers the JSON from that "saved to" file, and even when no JSON is obtainable it still rewrites `TASK_BASE_REF` to the current HEAD so a stale base ref from a previous claim can never make `changed_files` span unrelated commits); `.stride-changed-files.json` holds the per-file diff snapshot; `.stride-diff-upload-state` (v1.25.0+) records the last upload outcome (task id + HTTP code only, never credentials). **Gitignoring `.stride-diff-upload-state` and `.stride-changed-files.json` matters:** if they stay tracked, an `after_doing` auto-commit that stages everything will commit them, and because their contents change on every run they then surface in every later task's diff against base, polluting `changed_files`. **(v1.27.0+)** `capture_changed_files` also excludes both of these root artifacts from the snapshot as a backstop (anchored to the repository root, so a same-named file in a subdirectory of your project is still captured) — but gitignoring them keeps them out of your commits in the first place. **(v1.25.0+)** the snapshot is captured and uploaded **before** the `after_doing` section commands run — so a hook timeout mid-quality-gate no longer loses the diffs — then refreshed after all commands succeed, and the `before_review` hook verifies the recorded outcome on its own fresh timeout budget, re-capturing and re-uploading when the recorded state is missing, stale, or non-2xx (a healthy upload is never repeated). On Stride server v1.16.0+ the `after_doing` hook PUTs this snapshot to the server automatically (no agent action required); against older servers, agents inline-cat the file into the completion body (see `stride-completing-tasks` SKILL.md). All three files are cleaned up automatically at the claim refresh and after the `after_review` hook. **(v1.22.0+)** The automatic PUT sends a transport-encoded envelope — `{"changed_files":{"encoding":"base64","data":"<base64>"}}` — so an edge request filter (WAF) cannot misread a code diff as an attack and silently drop the upload; the server decodes it back to the identical list. When `base64` is unavailable the hook falls back to the raw `{"changed_files":[...]}` shape, and a non-2xx upload response is now surfaced as a stderr warning (non-fatal; the bearer token is never logged).

### The `after_doing` time budget

The two Bash hook entries in `hooks/hooks.json` carry a **300-second timeout** (the Skill-matcher gate stays at 10 seconds — it fires on every Skill invocation and must remain fast). The timeout is a **ceiling, not a guarantee**: the entire `after_doing` section — every command in your `.stride.md` quality gate (test suite with coverage, credo, sobelow, auto-commit) plus the plugin's own snapshot work — shares this one budget.

When the budget is exceeded, Claude Code kills the hook process. With the early-capture fix (v1.25.0+) the per-file diffs are already uploaded before your gate commands start, so a timeout no longer loses them — but the structured success JSON, the post-command snapshot refresh, and any not-yet-run gate commands are still lost, and the completion call is blocked as if the gate had failed.

If your project's quality gate runs close to the ceiling, either trim the `.stride.md` `## after_doing` section (move slow steps like a full coverage run into CI) or raise the `timeout` values further in a fork of the plugin.

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

## after_goal
# Optional fifth hook — fires after the parent goal's final child task
# completes. Omit the section entirely for the back-compat no-op path.
./scripts/notify-team.sh "$GOAL_IDENTIFIER" "$GOAL_TITLE"
```

## Updating

To update to the latest version of Stride skills:

```
/plugin update stride
```

## Running the hook test suites

The hook scripts ship with unit-style test suites that stub `curl` to verify
argument shape:

```
bash hooks/test-stride-hook.sh
pwsh hooks/test-stride-hook.ps1
```

These run by default with no setup. They do not make network requests.

### Optional end-to-end PUT round-trip

`test-stride-hook.sh` Test Group 11 drives `finalize_after_doing` against a
real kanban server, GETs the task back, and asserts the persisted
`changed_files` equals the snapshot. This catches wire-shape regressions
across the plugin/server boundary that stub-only tests miss.

The group is gated on three env vars and skips cleanly when any are unset:

```
cd stride
STRIDE_TEST_E2E_URL=http://localhost:4000 \
STRIDE_TEST_E2E_TOKEN=$(grep 'Local API Token:' ../.stride_auth.md | sed 's/.*`\(.*\)`.*/\1/') \
STRIDE_TEST_E2E_TASK_ID=42 \
bash hooks/test-stride-hook.sh
```

Required:
- `STRIDE_TEST_E2E_URL` — base URL of the kanban server (must be
  `http://localhost*`, `http://127.0.0.1*`, or end in `.dev` / `.local` /
  `.test`; production hostnames are a hard fail)
- `STRIDE_TEST_E2E_TOKEN` — API bearer token for that server
- `STRIDE_TEST_E2E_TASK_ID` — id of a sacrificial test task whose
  `changed_files` this group is allowed to overwrite

The group does NOT create or delete tasks — it mutates only the
`changed_files` field on the designated task. Pick a sacrificial task on a
local board, not a production task. The group runs three sub-cases: a
populated-snapshot round-trip, an empty-snapshot round-trip (legitimate
clear), and a fail-soft check (missing token must not crash the hook).

## License

MIT — see [LICENSE](LICENSE) for details.
