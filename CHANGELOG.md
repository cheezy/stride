# Changelog

All notable changes to the Stride plugin will be documented in this file.

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
