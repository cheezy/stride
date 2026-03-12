# Changelog

All notable changes to the Stride plugin will be documented in this file.

## [1.2.1] - 2026-03-12

### Changed

- **`stride-claiming-tasks`** — Added "MANDATORY: Next Skill After Claiming" section that explicitly lists the 3 skills agents must invoke after claiming (stride-subagent-workflow, stride-development-guidelines, stride-completing-tasks). Prevents agents from skipping directly to completion.
- **`stride-completing-tasks`** — Added mandatory preamble listing all 5 required completion API fields (completion_summary, actual_complexity, actual_files_changed, after_doing_result, before_review_result) with warning that skipping causes 3+ failed API calls. Added "MANDATORY: Previous Skill Before Completing" section referencing prerequisite skills.
- **`stride-subagent-workflow`** — Added "MANDATORY: Skill Chain Position" section showing where this skill sits in the claim→subagent→guidelines→complete sequence.
- **`plugin.json`** — Version bumped from 1.2.0 to 1.2.1.

### Fixed

- Agents skipping stride plugin skills and calling completion API from memory, resulting in repeated API rejections due to missing required fields and hook results. Skills now cross-reference each other in a mandatory chain.

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
