# Changelog

All notable changes to the Stride plugin will be documented in this file.

## [1.5.0] - 2026-03-24

### Added

- **`hooks/stride-hook.sh`** — Generic shell script that bridges Claude Code hooks to Stride `.stride.md` hook execution. Parses any user-defined `.stride.md` file, routes Claude Code PreToolUse/PostToolUse events to the correct hook section based on API endpoint patterns (claim → before_doing, complete → after_doing/before_review, mark_reviewed → after_review), and executes each uncommented command sequentially. Exits 2 on failure to block tool calls in PreToolUse context. Eliminates all permission prompts for hook commands.
- **`hooks/hooks.json`** — Claude Code hook configuration that activates automatically when the Stride plugin is enabled. Registers PostToolUse and PreToolUse hooks on Bash commands, routing to stride-hook.sh. No user settings changes needed.
- **Environment variable caching** — After a successful task claim, stride-hook.sh extracts task metadata (TASK_ID, TASK_IDENTIFIER, TASK_TITLE, TASK_STATUS, TASK_COMPLEXITY, TASK_PRIORITY) from the API response and caches them to `.stride-env-cache`. All subsequent hooks load the cached variables, enabling `.stride.md` commands to reference `$TASK_IDENTIFIER`, `$TASK_TITLE`, etc. Cache is cleaned up after the after_review hook.
- **Structured JSON output** — stride-hook.sh emits structured JSON on stdout for both success and failure. On failure: hook name, failed_command, command_index, exit_code, stdout, stderr, commands_completed, commands_remaining. On success: hook name, commands_completed, duration_seconds. Command output goes to stderr for Claude's feedback channel.

### Changed

- **`stride:hook-diagnostician` agent** — Added structured JSON input detection and parsing. The diagnostician now accepts both structured JSON from Claude Code hooks (with pre-parsed fields) and raw text from legacy agent-executed hooks. When JSON input is detected, fields are extracted directly without boundary detection. Output format updated to include command sequence context (PASSED/FAILED/SKIPPED) when structured JSON is the input.
- **`README.md`** — Added "Automatic Hook Execution (Claude Code Hooks)" section documenting the new hook routing, environment variable caching, and `.stride-env-cache` gitignore note.

## [1.4.0] - 2026-03-17

### Changed

- **`stride-completing-tasks`** — Added optional `review_report` field to all 4 completion documentation sections: API Request Format JSON example, Completion Request Field Reference table (type: string, required: No), Quick Reference Card REQUIRED BODY, and step 1.5 (capture reviewer output for review_report). Clearly documented as optional — agents omit it when no review was performed.
- **`stride-subagent-workflow`** — Updated Phase 3 (Code Review) to instruct agents to capture the task-reviewer agent's return value as `review_report` for inclusion in the completion API call. Capture applies regardless of review outcome (Approved or issues found). When the reviewer is skipped (small tasks with 0-1 key_files), `review_report` is simply omitted.
- **`stride:task-reviewer` agent** — Added "Output persistence" note clarifying that the structured review output will be stored as the `review_report` field on the Stride task record via the completion API. Instructs the agent to always produce a complete, well-formatted review even for Approved results since the report is persisted.

## [1.3.0] - 2026-03-17

### Changed

- **`stride-enriching-tasks`** — Enrichment no longer modifies `title`, `type`, or `description` fields. These are now preserved exactly as the human provided them. Previously, the skill would reformat the title to `[Verb] [What] [Where]`, infer `type` from language cues (e.g., "fix" → defect), and expand the description. Enrichment now only populates technical fields discovered through codebase exploration: `key_files`, `testing_strategy`, `verification_steps`, `patterns_to_follow`, `pitfalls`, `acceptance_criteria`, `where_context`, `why`, `what`, and `complexity`. Updated Phase 1, Before/After example, Phase 4 checklist, flowchart, PATCH API example, defect handling section, Quick Reference Card, and implementation workflow to reflect this change.
- **`stride-claiming-tasks`** — Added prominent "HOOK EXECUTION: NEVER PROMPT FOR PERMISSION" section with explicit prohibited behaviors and correct execution pattern. Strengthened hook execution instructions at every mention point (Complete Claiming Process, Hook Execution Pattern, Quick Reference Card). Added new Common Mistake #4 (prompting for hook permission) and new Red Flag entries. Hooks are pre-authorized by the user who authored `.stride.md` — agents must execute them immediately via direct Bash tool calls without any confirmation text or permission prompts.
- **`stride-completing-tasks`** — Added identical "HOOK EXECUTION: NEVER PROMPT FOR PERMISSION" section. Strengthened after_doing and before_review hook execution instructions. Added new Common Mistake #4 (prompting for hook permission) and new Red Flag entries for both after_doing and before_review hooks. Same principle: hooks are pre-authorized, execute immediately.

## [1.2.1] - 2026-03-12

### Changed

- **ALL 6 skills** — Changed frontmatter descriptions from soft "Use when..." language to "MANDATORY before calling [endpoint]..." language with specific API endpoints and failure consequences. These descriptions appear in the available skills list and are the primary lever for compelling invocation.
- **`stride-claiming-tasks`** — Added mandatory preamble section (matching completing-tasks pattern) listing required `before_doing_result` fields and the mandatory skill chain to invoke after claiming. Updated "MANDATORY: Next Skill After Claiming" to reference only plugin skills.
- **`stride-completing-tasks`** — Added mandatory preamble listing all 5 required completion API fields (completion_summary, actual_complexity, actual_files_changed, after_doing_result, before_review_result) with warning that skipping causes 3+ failed API calls. Updated "MANDATORY: Previous Skill Before Completing" to reference only plugin skills.
- **`stride-creating-tasks`** — Added mandatory preamble listing all field format requirements (verification_steps objects, key_files objects, testing_strategy arrays, type enum).
- **`stride-creating-goals`** — Added mandatory preamble documenting the critical batch format requirement (root key "goals" not "tasks") and dependency patterns.
- **`stride-subagent-workflow`** — Added mandatory preamble listing all 4 agents that can be dispatched and what skipping means (no exploration, no review, no decomposition). Updated skill chain position to reference only plugin skills.
- **`stride-enriching-tasks`** — Added mandatory preamble with trigger conditions (empty key_files, missing testing_strategy, no verification_steps) and enrichment capabilities.
- **`README.md`** — Added "Mandatory Skill Chain" section with workflow order diagram, "Why This Matters" failure table, and updated all skill descriptions to lead with "MANDATORY".

### Fixed

- Agents skipping stride plugin skills and calling completion API from memory, resulting in repeated API rejections due to missing required fields and hook results. Root cause: 4 of 6 skill descriptions used soft "Use when..." language that agents interpreted as optional. All descriptions now use "MANDATORY before calling [endpoint]" pattern with failure consequences.
- Cross-skill references included project-specific skills (`stride-development-guidelines`) that don't ship with the plugin. Removed all references to non-plugin skills from the skill chain.

## [1.2.0] - 2026-03-12

### Added

- **`stride-enriching-tasks` skill** — 4-phase enrichment workflow that transforms minimal task specifications into full implementation-ready specs. Explores codebase to populate key_files, testing_strategy, verification_steps, acceptance_criteria, patterns_to_follow, and 10 other fields. Handles defect tasks, title-only tasks, and ambiguous contexts with decision logic for when to explore vs. ask a human.
- **`stride:task-decomposer` agent** — Custom Claude Code agent that breaks goals and large tasks into dependency-ordered child tasks. Uses 6-step methodology: Scope Analysis, Task Boundary Identification (4 strategies), Dependency Ordering (3 types), Complexity Estimation, Full Specification per Task, and Output Assembly. Produces ready-to-create task arrays with correct dependency indices.
- **`stride:hook-diagnostician` agent** — Custom Claude Code agent that analyzes hook failure output and returns a prioritized fix plan. Parses 6 failure categories (compilation errors, test failures, security warnings, credo issues, format failures, git failures) with regex-based detection, structured output per issue, and a fix prioritization scheme that prevents wasted effort on cascading failures.

### Changed

- **`stride-claiming-tasks`** — Added step 4 "Check task completeness" with enrichment check. Tasks with missing key_files, testing_strategy, verification_steps, acceptance_criteria, or patterns_to_follow now invoke stride-enriching-tasks before the before_doing hook. Updated flowchart and quick reference card.
- **`stride-completing-tasks`** — Added "Diagnostician-Assisted Debugging" section to hook failure handling. Both after_doing and before_review failure paths now dispatch stride:hook-diagnostician as the first step (Claude Code only) with fallback to manual debugging. Updated flowchart with diagnostician branches.
- **`stride-subagent-workflow`** — Added Phase 0: Decomposition before existing phases. Updated decision matrix with decomposer dispatch criteria (goal type, large complexity without children, 25+ hour estimate). Updated flowchart and quick reference card with decomposer agent.
- **`plugin.json`** — Version bumped from 1.1.0 to 1.2.0.

## [1.1.0] - 2026-03-11

### Added

- **`stride:task-explorer` agent** — Custom Claude Code agent for targeted codebase exploration after claiming a task. Reads key_files, finds related tests, searches for patterns_to_follow, navigates where_context, and returns a structured summary for confident implementation.
- **`stride:task-reviewer` agent** — Custom Claude Code agent for pre-completion code review. Validates git diff against acceptance_criteria, detects pitfall violations, checks pattern compliance, verifies testing strategy alignment, and returns categorized issues (Critical/Important/Minor).
- **`stride-subagent-workflow` skill** — Orchestration skill that tells agents WHEN to dispatch subagents based on a decision matrix (task complexity + key_files count). Covers three phases: exploration after claim, conditional planning for complex tasks, and code review before completion hooks. Claude Code only — agents without subagent access skip automatically.
- **API Authorization sections** in all four skills (claiming, completing, creating-tasks, creating-goals) — Explicitly states that all Stride API calls are pre-authorized when the user initiates a workflow. Prevents agents from asking unnecessary permission before API calls.

### Changed

- **`stride-claiming-tasks`** — Added "Subagent-Guided Implementation (Claude Code Only)" section after the "After Successful Claim" section, pointing agents to the subagent workflow skill before coding.
- **`stride-completing-tasks`** — Added step 1.5 for pre-completion code review between "Finish your work" and "Read .stride.md after_doing section". Updated the completion workflow flowchart with an optional code review branch.
- **`plugin.json`** — Version bumped from 1.0.0 to 1.1.0.

## [1.0.0] - 2026-02-28

### Added

- **`stride-claiming-tasks` skill** — Enforces proper task claiming workflow: prerequisite verification (.stride_auth.md and .stride.md), before_doing hook execution with timing capture, and immediate transition to implementation. Includes automation notice for continuous claim-implement-complete loop.
- **`stride-completing-tasks` skill** — Enforces dual-hook completion workflow: after_doing hook (tests, linting, 120s timeout) and before_review hook (PR creation, 60s timeout) must both succeed before calling the complete endpoint. Handles needs_review gating and auto-continuation.
- **`stride-creating-tasks` skill** — Prevents minimal task specifications that cause 3+ hour exploration failures. Enforces comprehensive field population including key_files, acceptance_criteria, testing_strategy, pitfalls, patterns_to_follow, and verification_steps.
- **`stride-creating-goals` skill** — Enforces proper goal creation with nested tasks, correct batch format ("goals" root key, not "tasks"), within-goal dependency management, and cross-goal dependency workarounds.
- **Plugin configuration** — plugin.json with metadata, README with installation instructions, MIT license.
- **Hook execution patterns** — Documented before_doing, after_doing, before_review, and after_review hook lifecycle with timing capture, exit code handling, and failure recovery procedures.
- **Stale skills detection** — All skills handle `skills_update_required` API responses with instructions to run `/plugin update stride`.
