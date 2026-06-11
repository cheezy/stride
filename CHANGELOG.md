# Changelog

All notable changes to the Stride plugin will be documented in this file.

## [1.25.0] - 2026-06-10

### Changed — the changed-files diff upload survives the after_doing timeout (W1093-W1096)

The after_doing quality gate (tests with coverage, credo, sobelow, auto-commit) shares one hook timeout with the per-file diff upload that used to run only **after** every gate command succeeded. On a slow gate the timeout killed the process before the upload, silently losing the task's diffs (exactly how task W1092 lost its file diffs). This release defends in four layers:

- **`hooks/stride-hook.sh`** (W1093) — `run_stride_section` now calls `finalize_after_doing` **before** the first after_doing section command executes (immediately after the command-list parse and `cd "$PROJECT_DIR"`), and KEEPS the existing post-commands call as a refresh so tree-mutating gate commands (formatters, gettext extraction) still surface in the final snapshot. The early call is gated internally on the GLOBAL `$HOOK_NAME`, so the `after_goal` reuse of `run_stride_section` stays inert; a degraded capture still writes a best-effort `[]` snapshot and never blocks the gate. New Test Group 12 (12a-12e) covers the ordering, stdout purity, the gate, failed-gate survival, and the non-repo path.
- **`hooks/stride-hook.sh`** (W1094) — self-heal layer: `finalize_after_doing` records each PUT outcome in `$PROJECT_DIR/.stride-diff-upload-state` (task id + HTTP code ONLY — never the URL or bearer token), and the before_review hook — a fresh PostToolUse timeout budget — verifies that state, re-capturing against `TASK_BASE_REF` and re-PUTting when the state is missing, names a different task, or recorded a non-2xx. A healthy 2xx for the current task short-circuits before credential resolution (a successful after_doing upload is never repeated). The upload moved into a shared `upload_changed_files_snapshot` helper (same D61 base64 envelope, same stderr warning style). The state file is cleaned at the before_doing claim refresh and the after_review cleanup. New Test Group 13 (13a-13j).
- **`hooks/stride-hook.ps1`** (W1095) — Windows parity: the same early upload, upload-state file, and before_review retry (`Invoke-ChangedFilesUpload` / `Write-DiffUploadState` / `Invoke-SelfHealChangedFilesUpload`), with the claim refresh and after_review cleanup now also clearing the snapshot and state (the ps1 script has no capture step, so a stale snapshot must never be re-uploaded under a new task id). Also repairs the ps1 test suite, which failed at baseline on pwsh 7.6: a reserved `$Input` parameter name, a StrictMode `.Count`-on-null crash that killed the run, `Start-Process -ArgumentList` argv mangling on Unix .NET that silently lost ALL section-command output (replaced with `ProcessStartInfo.ArgumentList` + concurrent `ReadToEndAsync` drains to avoid the stderr-pipe deadlock), hand-rolled invalid JSON in two tests that dropped the Bearer token, a listener-startup race, and stale pre-D61 raw-body assertions. New Test Group 9 (9a-9i); the ps1 suite is 131 assertions green, the bash suite 198.
- **`hooks/hooks.json` + `README.md`** (W1096) — headroom: both Bash hook timeouts raised 120 → 300 seconds (the Skill-matcher gate stays at 10 seconds), with a new README subsection documenting the after_doing time budget as a shared ceiling, the kill behavior on timeout, and the trim-or-fork recommendation for slow gates.

**`.gitignore` note:** projects should add `.stride-diff-upload-state` alongside `.stride-env-cache` and `.stride-changed-files.json` — all three are temp artifacts written between hook invocations.

## [1.24.0] - 2026-06-09

### Changed — review reports must be delivered complete, NO EXCEPTIONS (G222)

**Every part of a dispatched review report is now mandatory on every task completion — there are NO EXCEPTIONS.** All review information the task supplies — `security_considerations`, `testing_strategy`, `patterns_to_follow`, `pitfalls`, `acceptance_criteria` — must be passed to the reviewer, and the reviewer's entire structured output (every project check and every section verdict) must reach the server intact. Not for small tasks, not for trivial tasks, never with a promise to fix it later. This is the plugin-side source fix for the recurring defect where a task's security considerations came back **"not assessed"** and the project-checks list was silently **truncated** (3 of 26 reached the server). The Kanban server independently hard-rejects an incomplete or task-inconsistent report (goal G221); this release makes the plugin always *produce* a complete one.

- **`skills/stride-workflow/SKILL.md`** (W1072) — The Code Review step's reviewer-dispatch instruction now passes **every** review field the task supplies (`acceptance_criteria`, `pitfalls`, `patterns_to_follow`, `testing_strategy`, `security_considerations`, `description`, `what`, `why`), matching the reviewer agent's documented input contract. It previously listed only four, so `security_considerations` was never handed to the reviewer and came back `not_assessed`.
- **`agents/task-reviewer.md`** (W1073) — `not_assessed` is now reserved **strictly** for a section the task itself left empty; a task-supplied section MUST receive a real `passed`/`failed` verdict, and the reviewer is told it always receives every supplied field. Enum values and the failed-implies-issue consistency rule are unchanged.
- **`skills/stride-workflow/SKILL.md`** + **`skills/stride-completing-tasks/SKILL.md`** (W1074) — The `reviewer_result` passthrough is now a mechanical **whole-object copy** with a mandatory self-check: every section the reviewer produced must be present, and the submitted `project_checks` count must equal the reviewer's. Hand-typing or sub-selecting the output is forbidden — no exceptions.
- **`skills/stride-completing-tasks/SKILL.md`** (W1075) — A mandatory **pre-submission self-check hard gate** refuses to submit a thin or task-inconsistent report (section presence, project-checks completeness, no `not_assessed` for a task-supplied section — including security considerations). No small-task, trivial-task, or fix-it-later bypass.
- **`skills/stride-subagent-workflow/SKILL.md`** + **`agents/task-reviewer.md`** (W1076) — Aligned the subagent-workflow dispatch doc to the full input list (it had kept the old shorter four-field set) and made the reviewer's input contract single-sourced, so no runtime path reintroduces the omission.

### Backward compatibility

Documentation/agent-prompt change only — no wire-shape, hook, `.stride.md`, `.stride_auth.md`, or `.gitignore` changes. The changes make the plugin always emit the complete `reviewer_result` the schema already defines (stored as `:jsonb` and persisted verbatim since v1.22.1). **Deliberate, accepted consequence:** a client that submits a thin or task-inconsistent dispatched review can no longer complete the task — that is the intended forcing function. Sibling-runtime variant prompts (Cursor / Windsurf / Continue / Codex / Gemini) live in their own repos and are out of scope for this release.

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. No configuration changes required.

### Source

Goal G222 (the plugin must always deliver complete review information — no exceptions): W1072 (pass every review field), W1073 (reserve `not_assessed` for genuinely-empty fields), W1074 (mechanical count-checked passthrough), W1075 (pre-submission self-check gate), W1076 (align the dispatch doc + input contract), W1077 (this release). The Kanban server-side enforcement half is goal G221 (shipped separately).

## [1.23.0] - 2026-06-08

### Updated

- **`agents/task-reviewer.md`** (W1057) — The `project_checks[]` per-entry `status` enum gains a third value, **`not_applicable`**, alongside `met` / `not_met`, and the reviewer is now required to **emit one entry for every top-level `CODE-REVIEW.md` bullet — never omit one**. Previously, with only `met` / `not_met` available, the reviewer silently dropped bullets that had no bearing on the diff under review (a small one-line fix surfaced only 2 of ~9 checks), so the Kanban review queue's "Code review" panel rendered a partial, ambiguous checklist. Now bullets that do not apply are marked `not_applicable` with a one-line reason in `evidence`; `not_applicable` is **approval-neutral** — it produces no paired `issues[]` entry and never contributes to `changes_requested` (only `not_met` does). `schema_version` bumps `"1.3"` → `"1.4"`, and the worked example demonstrates a `not_applicable` row. The example `schema_version` strings in `skills/stride-completing-tasks/SKILL.md` and `skills/stride-workflow/SKILL.md`, and the schema summary in `README.md`, were updated in lockstep so no stale `"1.3"` remains.

### Backward compatibility

Documentation/agent-prompt change only — no wire-shape, hook, `.stride.md`, `.stride_auth.md`, or `.gitignore` changes. The change is additive: `reviewer_result` is already stored as `:jsonb` by the Kanban server and persisted verbatim (v1.22.1), so the new `not_applicable` status value flows through with no consumer edit. Payloads from reviewers on the prior `"1.3"` schema (emitting only `met` / `not_met`) remain valid. The Kanban review-queue panel renders `not_applicable` as a neutral "N/A" pill (kanban-side W1058, ships independently).

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. No configuration changes required.

### Source

W1057 (reviewer `not_applicable` status + full-checklist emission) under goal G219. The Kanban-repo half — the review-queue "N/A" pill rendering — ships independently under W1058.

## [1.22.1] - 2026-06-08

### Fixed

- **`skills/stride-workflow/SKILL.md`** (D63) — The Step 6 "Extracting the structured review block" guidance built `reviewer_result` from a **hand-maintained enumerated copy-list** of structured keys, and that list omitted `project_checks`. As a result the reviewer agent's CODE-REVIEW.md per-bullet audit was silently dropped on completion and the Kanban review queue's "Code review" panel (gated on `reviewer_result["project_checks"]`) rendered nothing. The guidance is now a **verbatim passthrough**: copy the reviewer's entire parsed JSON object into `reviewer_result` and overlay only the legacy summary fields (`dispatched`, `duration_ms`, `summary`, `issues_found`, `acceptance_criteria_checked`) on top — so any key the schema gains later flows through automatically with no consumer edit. The fallback (no parseable JSON block) was inverted to a legacy-only *send* list so it no longer enumerates structured keys either.

### Updated

- **`agents/task-reviewer.md`, `skills/stride-completing-tasks/SKILL.md`** (W1049) — Added an explicit **consumption invariant** so the class of bug cannot recur: `agents/task-reviewer.md` is the single place the structured key-set is enumerated, and orchestrators/completion skills MUST persist the reviewer's emitted JSON block **verbatim** and MUST NOT maintain their own allow-list of keys to copy. `stride-completing-tasks` gains a completion-checklist item verifying `reviewer_result` carries the full structured block (incl. `project_checks`) and reinforces "passthrough verbatim; never re-enumerate" in its reviewer_result prose.

### Backward compatibility

Documentation/skill-instruction change only — no wire-shape, hook, `.stride.md`, `.stride_auth.md`, or `.gitignore` changes. `reviewer_result` is already stored as `:jsonb` by the Kanban server and the `project_checks[]` field already exists (v1.18.0+) and is already rendered by the review queue; this release simply stops the orchestrator from dropping it on the way out. Payloads produced by the prior enumerated guidance remain valid.

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. No configuration changes required.

### Source

D63 (verbatim-passthrough fix), W1049 (single-source-of-truth consumption invariant). The Kanban-repo half — a regression test asserting `reviewer_result.project_checks` round-trips and the review queue "Code review" panel renders — ships independently under W1050.

## [1.22.0] - 2026-06-07

### Updated

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (D61) — The `after_doing` hook now uploads the per-file diff snapshot to `/api/tasks/:id/changed_files` as a **transport-encoded envelope** — `{"changed_files":{"encoding":"base64","data":"<single-line-base64>"}}` — instead of the raw `{"changed_files":[...]}` array. An edge request filter (WAF) in front of the Stride server can misread a dense code diff as an attack payload and silently drop the upload, leaving `changed_files` empty in the review queue; base64-wrapping the body neutralizes that false positive while the server decodes it back to the identical list. The base64 is emitted single-line (wrap newlines stripped) so it is valid inside the JSON string. When `base64` is unavailable the hook **falls back** to the raw `{"changed_files":[...]}` shape (a bare top-level array would land at `params['_json']` and persist as NULL, so the object wrapper is preserved on both paths). The upload now captures the HTTP status and **warns to stderr on a non-2xx response** (`stride-hook: changed_files upload failed (HTTP <code>) for task <id>`) rather than discarding the result — the diff is still non-fatal to completion, so the hook warns rather than aborts, and the bearer token is never logged. The PowerShell mirror (`hooks/stride-hook.ps1`) applies the same encoding, fallback, and status-warning behavior via `[System.Convert]::ToBase64String` and `[Console]::Error.WriteLine`.

### Backward compatibility

Requires the Stride server (kanban) to accept the transport-encoded envelope (`base64` and `gzip+base64` encodings on `/changed_files`), which ships alongside this release. Against a server that predates envelope support, set environments where `base64` resolves still send the encoded shape; the raw-array fallback path remains byte-compatible with the prior hook for the no-`base64` case. The wire change is additive — no `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required.

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. No configuration changes required.

### Source

D61 (edge-filter-safe transport encoding for the `changed_files` upload, hook status reporting, hook test coverage for the base64 / gzip+base64 / malformed / corrupt-gzip / decompression-bomb paths). The Kanban-server half — decoding the `base64` / `gzip+base64` envelope on `/changed_files` with bounded streaming inflate and size guards — ships independently in the kanban repo.

## [1.21.0] - 2026-06-06

### Added

- **`skills/stride-creating-tasks/SKILL.md`, `skills/stride-enriching-tasks/SKILL.md`, `skills/stride-creating-goals/SKILL.md`** (W999) — `security_considerations` is now a **first-class, review_queue-scored field**, elevated to parity with `testing_strategy`. Each skill's "⚠️ REVIEW QUEUE SCORING" callout now names **five** scored fields (was four) — `acceptance_criteria`, `testing_strategy`, `security_considerations`, `pitfalls`, `patterns_to_follow` — with the field shape documented (array of strings, matching the Kanban task field `{:array, :string}`), a worked example value, and matching pre-submission-checklist, red-flag, and rationalization-table rows. `stride-enriching-tasks` folds a security pass into Phase 2 Step 5 ("Identify risks and security → `pitfalls`, `security_considerations`") and bumps its checklist count 16 → 17. Purely additive; the unrelated "four-phase" enrichment-procedure references are unchanged.
- **`agents/task-enricher.md`, `agents/task-decomposer.md`** (W1000) — Both decomposition/enrichment agents now derive and emit `security_considerations`. `task-enricher.md` folds a code-grounded security-analysis pass (input validation, authorization boundaries, secret handling, injection surfaces, data exposure) into Phase 2 Step 5, adds the checklist row / field-type reminder / array-shape guard / example value, and bumps its 16-item checklist references to 17. `task-decomposer.md` adds `security_considerations` to the required-fields table, the task template, and all four worked-example tasks with concrete values (authz, stored-XSS, atom-exhaustion, user-enumeration / rate-limiting).

### Updated

- **`agents/task-reviewer.md`** (W1001) — The reviewer agent now emits a fourth per-section verdict object, `security_considerations` (`{ "status": "passed" | "failed" | "not_assessed", "note": "<one-line rationale>" }`), alongside `testing_strategy` / `patterns` / `pitfalls`. A new review step 5, **Security Considerations Alignment**, gates whether the task's `security_considerations` were actually *implemented* (input validation, authz boundaries, secret handling, injection surfaces, data exposure; the explicit "None — …" case is honored). The `issues[]` `category` enum gains `"security"`, the consistency rule extends to `testing` / `pattern` / `pitfall` / `security`, and the review-queue tile-reading list adds `security_considerations.status`. `schema_version` is bumped `"1.2"` → `"1.3"` (schema-of-record preamble, step field list, and worked example); subsequent review steps renumber to 6/7/8.
- **`skills/stride-completing-tasks/SKILL.md`, `skills/stride-workflow/SKILL.md`** (W1002) — Both completion-path skills carry the `security_considerations` verdict verbatim into `reviewer_result`. Every `reviewer_result` example pairs `security_considerations` with the other per-section verdicts (same `{status, note}` shape), the verbatim-copied-verdict lists and the "omit any key the agent did not emit" fallback rule now include it, and all example `schema_version` strings are aligned to `"1.3"`. The legacy-only fallback `reviewer_result` block is intentionally left untouched.

### Backward compatibility

Wire-shape additive only. The `security_considerations` verdict object is forward-compatible — the Kanban server stores `reviewer_result` as `:jsonb` and tolerates the new key; older orchestrators that omit it still validate, and the field is omitted (never sent as an empty placeholder) when a reviewer on an older `schema_version` does not emit it. The task INPUT field `security_considerations` already existed on the Kanban task schema; this release makes the plugin populate, verify, and report on it.

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. Tasks created/enriched/decomposed by the updated skills carry `security_considerations`, and reviews run by the updated agent populate the new section-verdict tile.

### Source

W999 (review_queue-scored field in creation/enrichment skills), W1000 (enricher/decomposer population), W1001 (reviewer section verdict + `schema_version` `"1.3"`), W1002 (verdict propagation through completion skills). Minor bump because W1001 adds a new agent capability and bumps `schema_version`, mirroring the 1.19.0 precedent. The Kanban-server UI half — rendering the security-considerations review result on the Review Queue — ships independently as goal G211.

## [1.20.0] - 2026-06-05

### Added

- **`commands/create-tasks.md`** (W944) — New `/stride:create-tasks` slash command. Creates work tasks / defects, optionally seeded from a directory of project markdown via `--dir <path>` (alias `--context`; accepts both `--flag value` and `--flag=value`). It loads the `.md` files as a read-only context bundle and routes through the `stride-workflow` orchestrator, which dispatches `stride-creating-tasks` — it never invokes the creation sub-skill directly. A `--dir` path that is set but missing errors and exits non-zero; a directory with no `.md` files warns and continues.
- **`commands/create-goals.md`** (W945) — New `/stride:create-goals` slash command, the goal-creating sibling of `/stride:create-tasks`. Same `--dir` / `--context` parsing and validation; routes through `stride-workflow` to dispatch `stride-creating-goals`, producing a goal with context-seeded nested tasks.
- **Context-informed creation** (W941–W943) — `skills/stride-workflow/SKILL.md` gains a *Context-Informed Creation (Command Entry Points)* section documenting the two commands and the read-only context-bundle threading contract; `skills/stride-creating-tasks/SKILL.md` and `skills/stride-creating-goals/SKILL.md` each gain a *Consuming Provided Context* section mapping a forwarded markdown bundle onto task / goal fields. Context augments the user's intent and never silently overrides it; the activation-marker requirement, the sub-skill STOP gate, the four review_queue-scored fields, and the `"goals"` root-key / index-dependency rules are all unchanged.

## [1.19.0] - 2026-06-05

### Added

- **`agents/task-reviewer.md`** (D58) — The reviewer agent now emits three new top-level per-section verdict objects in the structured JSON block: `testing_strategy`, `patterns`, and `pitfalls`, each `{ "status": "passed" | "failed" | "not_assessed", "note": "<one-line rationale>" }`. `"failed"` is used when a matching-category issue was raised (`testing` / `pattern` / `pitfall`) or the dimension was otherwise unmet; `"passed"` when the task supplied that metadata and it was satisfied; `"not_assessed"` when the task supplied none. A consistency rule requires every `"failed"` verdict to be backed by a matching-category `issues[]` entry (and vice-versa), so the review-queue per-section tiles always agree with the issue list. Review steps 2 (Pitfall Detection), 3 (Pattern Compliance), and 4 (Testing Strategy Alignment) each gain a "Record the … section verdict" instruction, and the worked example gains the three objects.

### Fixed

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (D54) — `finalize_after_doing` previously extracted the `/changed_files` upload URL and bearer token from the *literal* intercepted completion command (`$COMMAND`). The documented completion curl uses shell variables (`$STRIDE_API_URL` / `$STRIDE_API_TOKEN`), so the greps matched the variable names, the guard failed, and the per-file diff PUT was silently skipped — every completed task ended up with empty `changed_files`. New `resolve_stride_api_url` / `resolve_stride_api_token` helpers (and the PowerShell `Resolve-StrideApiUrl` / `Resolve-StrideApiToken` mirror) now read `$PROJECT_DIR/.stride_auth.md` as the primary source — the production `**API Token:**` line, never `**Local API Token:**` — and fall back to the `$COMMAND` literal extraction for back-compat. Fire-and-forget non-fatal semantics, the empty-creds guard, and the no-token-logging rule are all preserved. New hook tests (`test-stride-hook.sh` 8g/8h/8i; `test-stride-hook.ps1` 7g) cover the variable-command path.

### Updated

- **`agents/task-reviewer.md`** (D58) — `schema_version` bumped from `"1.1"` to `"1.2"` (schema-of-record preamble, step 7 field list, and worked example). The new section-verdict objects are additive top-level keys.
- **`skills/stride-completing-tasks/SKILL.md`** (D57) — The completion contract now documents persisting the reviewer agent's **structured JSON block** verbatim as `reviewer_result` (`schema_version`, `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]`, `project_checks[]`, and the new section verdicts) merged with the legacy summary fields (`dispatched`, `duration_ms`, `issues_found`, `acceptance_criteria_checked`) — instead of the thin issues-found envelope that stripped the issues, acceptance verdicts, and code-review checks the Kanban review queue renders. All three `reviewer_result` examples and the Explorer/Reviewer Result Schema section show the rich block; extraction is delegated to the `stride-workflow` "Extracting the structured review block" (Step 6); the schema itself is owned by `agents/task-reviewer.md` (cited, not redefined). The `dispatched: false` skip-form is unchanged.
- **`skills/stride-workflow/SKILL.md`** (D58) — The Step 6 worked example bumps `schema_version` `"1.0"` → `"1.2"` and adds the section verdicts (the field-mapping list already enumerated them). Example payloads across the skills are aligned to `"1.2"`.

### Backward compatibility

Wire-shape additive only. The three section-verdict objects and the rich-block persistence are forward-compatible — the Kanban server stores `reviewer_result` as `:jsonb` and tolerates the new keys; older orchestrators that emit only the legacy envelope still validate, and the Kanban review queue (v2.x) derives the section tiles from `issues[]` categories when explicit section objects are absent. The hook fix changes only credential *resolution*; the upload remains fire-and-forget and the `$COMMAND` literal path is preserved for setups without `.stride_auth.md`.

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required; the hook fix makes the existing variable-based completion curls upload diffs that were previously dropped. Reviews run by the updated agent populate the three section-verdict tiles automatically.

### Source

D57 (completion-skill rich block), D58 (reviewer section verdicts + `schema_version` `"1.2"`), D54 (hook changed_files credential resolution). Minor bump because D58 adds a new agent capability and bumps `schema_version`. The Kanban-server UI half of the rollout — deriving the section tiles, the status pill, and the panel hardening on the Review Queue — ships independently as defects D56 and D59.

## [1.18.0] - 2026-05-26

### Added

- **`agents/task-reviewer.md`** (W875) — A new step 6 **Project-Level Checks** is inserted between the existing General Code Quality step and the Return Structured Review step (renumbered 6 → 7). The reviewer agent now reads `CODE-REVIEW.md` from the project root, parses each top-level Markdown bullet (`- ` / `* `) beneath any heading as a separate standing review check, evaluates each against the diff with the same Met / Not Met semantics the agent already uses for `acceptance_criteria`, and emits the verdict under a new top-level `project_checks[]` field in the structured JSON block. A case-sensitive `CRITICAL:` prefix on a bullet maps to severity `critical` (the prefix is stripped from the recorded check text); the default severity is `important`. Every `not_met` project_check MUST also produce a paired entry in `issues[]` with `category: "project_check"` and the derived severity, so per-severity telemetry stays consistent. When `CODE-REVIEW.md` does not exist or contains no bullets, `project_checks` is emitted as `[]` — older projects without a `CODE-REVIEW.md` file continue to produce a valid payload. The Output persistence paragraph is extended to list the new project-checks prose table alongside the existing acceptance-criteria table.

### Updated

- **`agents/task-reviewer.md`** (W875) — `schema_version` bumped from `"1.0"` to `"1.1"` in both the step 7 prose definition and the worked example. The `status` rule is extended: `"changes_requested"` now also fires when any `project_check` has status `"not_met"` (in addition to the existing critical/important issue and not_met acceptance_criterion triggers). The `issues[]` `category` enum gains `"project_check"`. The worked example gains a representative `project_checks` array (one `met` + one `not_met` paired with an `important` `project_check` issue) so downstream tooling has a shape reference. Sibling reviewer-variant prompts in the Stride marketplace (Cursor, Windsurf, Continue, Codex, Gemini) are deliberately not modified — they reference this file as the schema of record per the preamble.

### Backward compatibility

Wire-shape additive only. Existing reviewer payloads without `project_checks` continue to be tolerated by the kanban server (`reviewer_result` is persisted as `:jsonb`); existing categories in `issues[]` (`acceptance_criteria` / `pitfall` / `pattern` / `testing` / `code_quality`) continue to validate. Older orchestrators that parse the prior `"1.0"` schema can read the new `"1.1"` payload because the only schema additions are a new top-level array (`project_checks`) and a new value in the existing `category` enum — both forward-compatible additions, not breaking changes. Hook script (`hooks/stride-hook.sh` and `.ps1`) and parser contract are byte-identical to 1.17.3. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required.

### Migration

`/plugin update stride@stride-marketplace` once the marketplace pin lands. Optional but recommended: add a `CODE-REVIEW.md` file at your project root with one bullet per standing review rule. Bullets prefixed with `CRITICAL:` will surface as critical-severity issues when violated; all other bullets surface as important-severity. With no `CODE-REVIEW.md` present, reviewer behavior is identical to 1.17.3 — the new field renders as `project_checks: []` and the structured payload is otherwise unchanged.

### Source

G186 / W875 (the task-reviewer.md edit), W877 (this release). Minor bump because the prompt adds a new agent capability and bumps `schema_version` from `"1.0"` to `"1.1"`. The kanban-server UI half of the rollout — rendering `project_checks` on the Review Queue panel — lives under G188 and ships independently of this plugin release.

## [1.17.3] - 2026-05-25

### Updated

- **`skills/stride-creating-tasks/SKILL.md`** (W850) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING" callout that names the four fields the review_queue dashboard scores on every completion (`acceptance_criteria`, `testing_strategy`, `pitfalls`, `patterns_to_follow`) and frames the consequence of omitting any of them: a visible, public, persistent **empty pill** on the dashboard that does not get back-filled later. Reinforces the same four fields with four new bullets in the existing **Red Flags - STOP** list and four new rows in the existing **Rationalization Table** (each row keyed to a specific rationalization for dropping one of the four fields — "obvious from the title" / "doesn't apply here" / "just nice-to-have" / "can stay empty" — with `Reality` and `Consequence` columns spelling out the empty-pill outcome). No new top-level section was introduced; all reinforcement is co-located with existing structures per the skill's prior structural conventions.
- **`skills/stride-enriching-tasks/SKILL.md`** (W851) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING — ENRICHMENT IS THE LAST CHANCE" callout that names the same four review_queue-scored fields and explicitly frames **enrichment as the final point at which they can be populated before the task hits Doing** — whatever is left empty here renders as an empty pill at completion, and the implementing agent will not back-fill it mid-flight. Strengthens the existing **Phase 4 16-item pre-submission checklist** by promoting `acceptance_criteria`, `testing_strategy`, `pitfalls`, and `patterns_to_follow` to individual mandatory-for-review checklist items (each line annotated with the review_queue-scored consequence and its specific empty-pill condition) rather than bundling them under a single "check formatting" line. Reinforces with four new **Red Flags - STOP** bullets matching the existing imperative tone.
- **`skills/stride-creating-goals/SKILL.md`** (W852) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING — NESTED TASKS ARE NOT EXEMPT" callout that stresses the four-field minimum bar applies to **every nested task in a goal**, individually — there is no "it's just a subtask" discount and the goal-level `description` does not satisfy nested-task fields. Strengthens the existing **Task Nesting Rules** section with a per-field block that enumerates `acceptance_criteria` / `testing_strategy` / `pitfalls` / `patterns_to_follow` with their individual empty-pill conditions, and updates the closing "Minimal nested tasks fail the same way" line to include the review_queue consequence. Adds four new **Red Flags - STOP** bullets and four new **Rationalization Table** rows specifically targeting nested-task offloading rationalizations ("the goal description covers it" / "goal-level only" / "applies to the goal, not its children" / "lives on the goal").

### Backward compatibility

Content-only release. No hook script, parser contract, env-var matrix, API field shape, or workflow step changed — every behavior is byte-identical to 1.17.2. The three SKILL.md edits strengthen guidance only; existing task-creation, enrichment, and goal-creation calls continue to validate without modification. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. Agents that already populate the four fields see no behavior change; agents that previously skipped them get explicit prose about the downstream review_queue scoring consequence.

### Migration

`/plugin update stride@stride-marketplace` (the marketplace pin update to 1.17.3 lands in stride-marketplace 1.30.3). No configuration changes required.

### Source

G166 / W850 (stride-creating-tasks emphasis), W851 (stride-enriching-tasks emphasis), W852 (stride-creating-goals emphasis), W873 (this release). Patch release because the changes are documentation-only emphasis updates inside three SKILL.md files — no behavior change, no API contract change, no hook contract change. The goal of the change set is to raise the floor on the four fields the review_queue dashboard scores at completion, so empty pills become rare rather than common.

## [1.17.2] - 2026-05-25

### Critical fix

- **`hooks/stride-hook.sh`** and **`hooks/stride-hook.ps1`** — `finalize_after_doing` now PUTs a body of shape `{"changed_files": [...]}` instead of a bare top-level array (D35). Under 1.17.1 and earlier the bare array landed at `params['_json']` under Plug.Parsers, validated as `{:ok, nil}`, and was persisted as NULL — silently clearing `changed_files` on every task completed against a 1.16.0+ server that did real PUT-side processing. Symptom: the review queue diff panel showed no per-file unified-patch text for any task completed under 1.17.1, even though the on-disk `.stride-changed-files.json` snapshot was correctly captured. The bash side switches from `--data-binary "@<file>"` to `-d "{\"changed_files\":$(cat "<file>")}"` (inline `cat`, no new temp file). The PowerShell mirror parses the snapshot, wraps it in `@{ changed_files = @($snapshotData) }`, and pipes through `ConvertTo-Json -Depth 100 -Compress` so PowerShell handles JSON escaping itself rather than relying on string concat. The snapshot write-to-disk step is preserved unchanged (legacy `--argjson cf` consumers on older deployments still read it); the fail-soft contract is preserved (`|| true` on bash; `try`/`catch` + `-ErrorAction SilentlyContinue` on PS).

### Added

- **`hooks/test-stride-hook.sh`** — Test Group 8 (D35) gains three new wire-shape assertions: body parses as a JSON object with a `changed_files` key (not a bare array), round-trip equality of the body's `.changed_files` value against the on-disk snapshot, and empty-snapshot wraps as `{"changed_files": []}` (the latter replaces the prior literal-`[]` assertion). The curl stub now captures `-d <inline>` bodies in addition to legacy `--data-binary @<file>`; a new `extract_body` awk helper isolates the captured body for jq-based assertions. Mirror assertions land in `hooks/test-stride-hook.ps1` Group 7. Bash suite total: 151 passed / 0 failed.
- **`hooks/test-stride-hook.sh`** — Test Group 11 (W835) adds a gated end-to-end PUT round-trip that drives `finalize_after_doing` against a real kanban server, GETs the task back, and asserts the persisted `changed_files` equals the snapshot. Three sub-cases: populated-snapshot round-trip with an explicit NULL check that directly catches the D35 bare-array regression, empty-snapshot round-trip persists as `[]` (not NULL), and missing-token fail-soft (finalize exits 0). Gated on `STRIDE_TEST_E2E_URL` + `STRIDE_TEST_E2E_TOKEN` + `STRIDE_TEST_E2E_TASK_ID`; skips cleanly when any are unset; hard-fails (not skips) when the URL doesn't match the `localhost` / `127.0.0.1` / `[::1]` / `*.dev` / `*.local` / `*.test` allowlist. Stub-only testing missed the body-shape regression for multiple releases — this group is the integration-boundary case that wouldn't.
- **`README.md`** — A new "Running the hook test suites" section documents the three required env vars for the gated E2E group and warns against pointing it at a production task. Both `bash hooks/test-stride-hook.sh` and `pwsh hooks/test-stride-hook.ps1` are documented as the default-no-setup test entry points.

### Backward compatibility

The wire-shape fix is fully backward-compatible at the server boundary — a wrapped `{"changed_files": [...]}` body has always been the documented contract; older server deployments that previously accepted a bare array (none observed in practice on 1.16.0+) continue to accept the wrapped form because both routes land at the same `params['changed_files']` slot when the body is a proper object. The four other `.stride.md` hooks (`before_doing`, `after_doing` outer body, `before_review`, `after_review`, `after_goal`) produce byte-identical output to v1.17.1. The on-disk `.stride-changed-files.json` snapshot is preserved unchanged so legacy `--argjson cf` consumers on older deployments still read it.

### Migration

`/plugin update stride@stride-marketplace` (the marketplace pin update to 1.17.2 lands in stride-marketplace 1.30.2). No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. Users on 1.17.1 who already completed tasks with NULLed `changed_files` cannot recover the lost diffs — those completions persisted NULL at the server. Going forward, every task completed under 1.17.2+ will populate `changed_files` correctly.

### Source

G161 / D35 (wire-shape fix in `hooks/stride-hook.{sh,ps1}` + Group 8 assertions in `hooks/test-stride-hook.{sh,ps1}`), W835 (gated E2E Group 11 in `hooks/test-stride-hook.sh` + README docs). Patch release — pure bugfix, no behavior change beyond the wire-shape correction. Critical because every Stride task completion under 1.17.1 silently destroyed diff data.

## [1.17.1] - 2026-05-22

### Fixed

- **`hooks/stride-hook.sh`** — Actually wire the `## after_goal` routing that v1.17.0 announced but did not implement. The release-vs-implementation gap meant a user adding `## after_goal` to `.stride.md` saw no execution even when the server delivered the hook entry in the response payload. Extracts the parse+exec block into a `run_stride_section <section_name>` function (byte-identical output for the four existing routes — empirically confirmed by the 118 pre-existing tests passing unchanged after the refactor) and adds a `response_has_after_goal <input>` detector. After the primary hook succeeds on `post` + `/complete` or `/mark_reviewed`, the script now inspects the response payload's `hooks` array and runs the `## after_goal` section if the server bundled the entry. Missing section is a clean no-op (back-compat). Non-zero exits are surfaced via the same structured JSON shape `after_doing` uses; the agent reads the JSON off stdout to forward via `PATCH /api/tasks/:goal_id/after_goal`. Implemented as W504.
- **`hooks/stride-hook.ps1`** — Windows parallel of the above (W505). Mirrors the bash routing via `Invoke-StrideSection` and `Test-AfterGoalInResponse`. Critical PowerShell-specific fixes during implementation: structured JSON is routed via `[Console]::Out.WriteLine` rather than the function's output pipeline (the latter pollutes the caller's `$primaryRc = Invoke-StrideSection ...` assignment, producing an array instead of an int and breaking the `-ne 0` gate); `Get-Content` reads are wrapped in `@()` so `.Count` is safe under `Set-StrictMode -Version Latest` when commands produce no stdout/stderr.
- **`hooks/test-stride-hook.sh`** and **`hooks/test-stride-hook.ps1`** — End-to-end test coverage for the routing (W506). Each harness adds five cases exercising the full script as a subprocess: after_goal present + section present, after_goal present + section absent (back-compat), after_goal absent (unchanged behavior), section command exits non-zero (structured failure JSON on stdout, script exit 0), and mark_reviewed parity with /complete. Bash suite now reports 149/0.

### Updated

- **`skills/stride-workflow/SKILL.md`** — Step 9 now describes the parent goal's Done transition triggered by a successful `after_goal` hook execution (W507). Documents the agent's PATCH /api/tasks/:goal_id/after_goal POST contract, the server-side grace-window worker that bridges older agents which don't POST, and reinforces that the hook is general-purpose (Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses). The Step 7 hooks reference table, GOAL_* env-var matrix, and canonical examples block landed in v1.17.0; this is the Step 9 follow-up.
- **`README.md`** — Hook routing table flags the +after_goal-if-bundled cases on the /complete and /mark_reviewed rows; a paragraph below the table describes the blocking semantics, env vars, agent POST responsibility, and back-compat. The `.stride.md` example shows an optional `## after_goal` section (W508).

### Backward compatibility

A `.stride.md` without a `## after_goal` section continues to work unchanged — the new routing code is a clean no-op for that case. The four existing hook routes (`before_doing` / `after_doing` / `before_review` / `after_review`) produce byte-identical output to v1.17.0 (and prior), empirically confirmed by all 118 pre-existing tests passing unchanged after the parse-and-exec refactor. Older agent runtimes that don't speak the after_goal protocol — including those that don't make the PATCH POST — are covered by the server-side grace-window worker, which promotes the goal after the configured wait expires.

### Migration

`/plugin update stride@stride-marketplace` (the marketplace pin update to 1.17.1 lands in stride-marketplace 1.30.1). No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. To opt into the new hook, add a `## after_goal` section to `.stride.md`.

### Source

G117 / W504 (bash routing), W505 (PowerShell mirror), W506 (end-to-end tests), W507 (SKILL.md Step 9), W508 (README). Patch release because v1.17.0 advertised the feature but the routing wasn't wired — this release closes that gap without changing any other behavior.

## [1.17.0] - 2026-05-22

### Added

- **`## after_goal` hook section** — fifth `.stride.md` hook, fires after the parent goal's final child task completes. Blocking, 60s timeout, same single-bash-fence parsing rule as the four existing hooks. Documented in `skills/stride-workflow/parser.md` (parsing contract) and `skills/stride-workflow/hook-execution.md` (executor contract: env-var forwarding, blocking semantics, result reporting, bounded backoff on network errors). The shell parser in `hooks/stride-hook.sh` is already section-name-agnostic — adding `after_goal` to the recognized set is a documentation-only change.
- **`GOAL_*` env vars** — `GOAL_ID`, `GOAL_IDENTIFIER`, `GOAL_TITLE`, `GOAL_DESCRIPTION` forwarded by the executor into the `## after_goal` child process environment, sourced verbatim from the server-supplied `hook.env`. `BOARD_*`, `COLUMN_*`, `AGENT_NAME`, and `HOOK_NAME` remain present across all five hooks. The executor never invents, derives, or looks up these values client-side; missing keys export as empty string (defined-but-empty), never raised.
- **Hooks reference table in `skills/stride-workflow/SKILL.md`** — Step 7 now opens with a five-row table listing every hook with timing, blocking, timeout, and purpose columns, followed by a Hook Environment Variables matrix (`TASK_*` vs `GOAL_*` per hook) and a Canonical Hook Examples block showing PR-creation for both `## before_review` and `## after_goal`. The example block explicitly notes the hooks are general-purpose — Slack notifications, artifact archival, release pipelines, and project-level smoke tests are equally valid uses.
- **`hooks/test-stride-hook.sh`** — three new tests in Test Group 2 covering the `## after_goal` section: present (2m), absent / back-compat (2n), and duplicate / first-wins (2o). Suite total: 118 passed / 0 failed.

### Backward compatibility

A missing `## after_goal` section parses as a clean no-op (`exit_code: 0`, empty output) — older `.stride.md` files that predate the section keep working without any modification. The server-side grace-window path remains the back-compat bridge for agent runtimes that don't speak the after_goal protocol: when no agent report arrives within the configured window, the server's `AfterGoal.GraceWorker` synthesizes an attempt with `source: "after_goal_grace_worker"` and promotes the goal. Telemetry / metric queries that screen on adoption explicitly exclude the grace-worker `source` tag.

### Migration

`/plugin update stride@stride-marketplace`. Add a `## after_goal` section to `.stride.md` to opt into the new hook; omitting it preserves the prior behavior. Server-side, the receiving deploy must include the `PATCH /api/tasks/:id/after_goal` endpoint and the `after_goal_status` / `after_goal_result` / `after_goal_attempts` columns on the `tasks` table.

### Source

Implemented as G113 / W494 (parser docs + tests), W495 / W496 / W497 (executor doc — env-vars, blocking, agent-result POST), and W501 (SKILL.md hooks-table update). Server-side companion work landed in kanban as W498 (delivery telemetry), W499 (adoption metric), and W500 (goal-to-Done latency p50/p95). Companion marketplace pin bump lands in stride-marketplace.

## [1.16.0] - 2026-05-21

### Added

- **`hooks/stride-hook.sh`** — `finalize_after_doing()` now PUTs the per-file diff snapshot to Stride immediately after writing `.stride-changed-files.json` to disk. URL and Bearer token are extracted from the intercepted agent completion command in `$COMMAND` (via `grep -oE`) — no new top-level env vars, no `.stride_auth.md` read. The PUT is fire-and-forget (`-s ... > /dev/null 2>&1 || true`) and silently no-ops when any prerequisite is missing (`HAS_JQ=false`, no `curl`, no `TASK_ID`, no URL/token in `$COMMAND`). The function definition moved above the no-`PHASE` early-return guard so tests can source the script and invoke it in isolation — matching the existing pattern documented for `capture_changed_files`. The three call sites in the main flow (no-commands fast-path, empty-cmd-list fast-path, success path) are preserved unchanged. Implementation is 23 lines (under the 30-line ceiling).
- **`hooks/stride-hook.ps1`** — New `Invoke-FinalizeAfterDoing` function mirrors the bash PUT: extracts URL/token from `$Command` via `-match`, PUTs `.stride-changed-files.json` via `Invoke-WebRequest -Method Put` inside `try/catch` with `-ErrorAction SilentlyContinue` for fire-and-forget semantics. Called at three matching exit points (no-commands, empty-cmd-list, success-path). Gated on the snapshot file existing on disk so Windows-only deployments (where `capture_changed_files` is not yet ported to PowerShell) degrade silently to current behavior.
- **`hooks/test-stride-hook.sh`** — New Test Group 8 (W780) — 6 sub-cases covering PUT-success (URL/token/method/body assertions via a stub `curl` recorded into a fixture), no-Bearer-token (PUT skipped, snapshot still written), no-`TASK_ID` (PUT skipped), empty-snapshot (`[]` still PUTs the literal empty array), PUT-failure (stub exits 1, hook still exits 0, snapshot persists), and `HAS_JQ=false` (PUT skipped via the sourced unit-test path). Suite total: 112 passed / 0 failed.
- **`hooks/test-stride-hook.ps1`** — New Test Group 7 (W780) — HttpListener-backed PUT-success test (asserts method, path, Authorization header, body content) plus 4 wrapper-resilience cases (unreachable port doesn't propagate, no snapshot file no-ops, no Bearer token no-ops, no `TASK_ID` no-ops).
- **`skills/stride-completing-tasks/SKILL.md`** — Documentation surface updated for the new flow (W781). The pre-completion verification checklist item for `changed_files` is rewritten to say "No agent-side action is required on Stride server v1.16.0+ — the after_doing hook PUTs the snapshot automatically", with a cross-link to the Per-File Diff Capture (Optional) section for back-compat against ≤ v1.15.x servers. The canonical API Request Format example drops `--argjson cf` and `changed_files: $cf` from the `jq -n`/curl, and its body-shape example drops the `changed_files` field — both reflect the v1.16.0+ flow where the hook owns the upload. The Per-File Diff Capture (Optional) section now leads with an "Upload flow (v1.16.0+)" paragraph describing the hook PUT, followed by a new "Backwards compatibility" subsection with a server-version table and prose explaining both modes coexist. The legacy inline-cat pattern is preserved verbatim under "Legacy inline pattern (≤ v1.15.x deployments)" so agents targeting older servers retain a working recipe. Cross-link to `docs/diff-contract.md` preserved; the schema reference table still lists `changed_files` as optional.

### Why this release

Closes the loop on the "agent must inline the snapshot" bug class. Through v1.15.x, every agent runtime (Claude Code CLI, Claude Code TypeScript SDK, Codex, Gemini, opencode, pi, copilot) had to remember to include `--argjson cf "$(cat ...)"` in the completion curl. Any agent that forgot — or that ran under a runtime where `$CLAUDE_PROJECT_DIR` was unset (fixed in v1.15.1 for the SDK path), or that read the snapshot in a separate Bash tool call before the curl — POSTed an empty `changed_files` even though the hook had captured the diff correctly. With v1.16.0, the `after_doing` hook owns the upload via `PUT /api/tasks/:id/changed_files`. The hook runs in a controlled environment for every agent, so no agent can silently omit `changed_files` anymore. The completion body shrinks accordingly.

### Backward compatibility

`changed_files` in the completion body remains accepted by every supported Stride server — older agent installs that still inline-cat continue to work against v1.16.0+ servers (the server treats the PUT-uploaded value as authoritative when both are present). Against ≤ v1.15.x servers, the new hook PUT 404s harmlessly (fire-and-forget), and the inline-cat pattern is the only path that carries the snapshot — the SKILL.md "Legacy inline pattern" subsection documents it explicitly for that case. The wire shape of the snapshot (`{path, diff}`, the 500-line truncation marker, the binary placeholder) is unchanged.

### Migration

`/plugin update stride@stride-marketplace`. No `.stride_auth.md`, `.stride.md`, or `.gitignore` changes are required. Agent runtimes that still inline `--argjson cf` need no update — both paths coexist. Server-side, the receiving deploy must include the `PUT /api/tasks/:id/changed_files` endpoint (W777); deploys without it 404 the hook PUT silently and the older inline-body path remains the only source of `changed_files`.

### Source

Implemented as G162 / W780 (hook + tests) and W781 (SKILL.md). Companion server endpoint lands in kanban as W777. Companion marketplace pin bump lands in stride-marketplace.

## [1.15.1] - 2026-05-21

### Fixed

- **`skills/stride-completing-tasks/SKILL.md`** — Replaced three occurrences of `"$CLAUDE_PROJECT_DIR/.stride-changed-files.json"` with the defaulted form `"${CLAUDE_PROJECT_DIR:-.}/.stride-changed-files.json"` in the canonical inline-cat pattern. Affected lines: the pre-completion verification checklist item, the canonical `API Request Format` PATCH snippet, and the `Per-File Diff Capture (Optional)` snippet. The inline structure, the `--argjson cf "$(cat ... 2>/dev/null || echo '[]')"` shape, and the binary/truncation contract are unchanged — only the variable expansion is defaulted.

### Why this release

Under Claude Code's TypeScript SDK runtime, `$CLAUDE_PROJECT_DIR` is unset/empty, so the bare expansion produced `/.stride-changed-files.json`. The `cat` failed, the `|| echo '[]'` fallback fired, and agents POSTed `changed_files: []` even when the PreToolUse-on-complete hook had correctly written the snapshot. The defaulted form `${CLAUDE_PROJECT_DIR:-.}` falls back to the current working directory whenever the variable is unset or empty, so the read finds the snapshot under both Claude Code CLI (where the variable is set) and the TypeScript SDK (where it is not). Three of the six Stride plugins are affected by the same defect; stride/ is the lead because it is the most widely installed (via stride-marketplace).

### Backward compatibility

Wire shape unchanged. `hooks/stride-hook.sh` already used the defaulted form, so behavior under the Claude Code CLI is byte-identical to v1.15.0. Under the TypeScript SDK, agents that follow the canonical SKILL.md pattern now successfully capture the snapshot they were already trying to send.

### Source

Implemented as W767/W768 (SKILL.md hotfix in dependent task; release coordination in this task). Companion marketplace pin bump lands in stride-marketplace/.claude-plugin/marketplace.json (stride → 1.15.1) and CHANGELOG. Cross-plugin parity ports for the other affected plugins follow as separate tasks.

## [1.15.0] - 2026-05-20

### Changed

- **`hooks/stride-hook.sh`** — `capture_changed_files()` now reflects the agent's full working state at completion time, not just committed history. The function uses `git diff $base` (no `..HEAD`) so committed-since-base, staged-but-uncommitted, AND modified-but-unstaged changes all surface in a single pass, and adds a `git ls-files --others --exclude-standard` pass to enumerate untracked new files. Untracked text files appear as synthesized new-file unified patches (diffed against `/dev/null` via `git diff --no-index --no-color`); untracked binaries are detected via the `Binary files ... differ` sentinel that `--no-index` emits and use the existing binary placeholder string. A path that is both committed-since-base AND further modified in the working tree appears exactly once in the snapshot with a diff that reflects the final working-tree state. The 500-line per-file truncation rule and the `[binary file — no diff captured]` placeholder string are preserved unchanged.
- **`skills/stride-completing-tasks/SKILL.md`** — Three coordinated surface rewrites so agents stop the broken "separate cat then curl" pattern. (1) The canonical "API Request Format" section now leads with a `bash`/`curl` example that inlines the snapshot read via `--argjson cf "$(cat \"$CLAUDE_PROJECT_DIR/.stride-changed-files.json\" 2>/dev/null || echo '[]')"` INSIDE the `jq -n` that builds the curl's `-d` payload — followed by the JSON body shape as an illustrative supplement. The absolute `$CLAUDE_PROJECT_DIR/...` path is used so a non-root agent CWD does not silently miss the file. (2) The Per-File Diff Capture (Optional) section now contains a "Why inline?" paragraph explaining that the PreToolUse-on-complete hook writes the snapshot DURING the curl call, so a separate Bash tool call BEFORE the curl reads the file before the hook populates it. (3) The pre-completion verification checklist item for `changed_files` is rewritten to test for the inline pattern + absolute path explicitly, replacing the older "read it and embed it verbatim" prose. A new "Working-tree semantic (v1.15.0+)" paragraph documents the broadened capture.
- **`hooks/test-stride-hook.sh`** — Test Group 7 grows from 14 cases to 19 cases with 5 new Option D cases (7o-7s): modified-uncommitted tracked file present in snapshot, staged-uncommitted change present, untracked new file appears as synthesized `+++ b/<path>` patch with `+<content>` body, untracked binary file emits the exact binary placeholder, and dedupe — a committed-then-further-modified path appears exactly once with the diff reflecting the final working-tree content. Existing 7g (real-git integration), 7i (HEAD~1 fallback), 7j (e2e after_doing), 7k (all-commented after_doing), and 7m (empty diff) fixtures updated to add a `.gitignore` for stride runtime artifacts (`.stride.md`, `.stride-env-cache`, `.stride-changed-files.json`) and to redirect subshell stdout to a sibling temp file rather than to a path inside the test's working directory — both adjustments accommodate the new untracked-file capture without weakening any assertion. Test suite reports 100 passed / 0 failed.
- **`.claude-plugin/plugin.json`** — Minor version bump from `1.14.1` to `1.15.0` (the snapshot semantic broadens; the wire shape is unchanged).

### Why this release

A Claude Code task completing without an intermediate commit produced an empty `.stride-changed-files.json`. Diagnosis: (a) `capture_changed_files()` was anchored to `<base>..HEAD`, so working-tree-only changes were invisible; (b) the canonical SKILL.md example read the snapshot in a Bash tool call BEFORE the curl, which means the PreToolUse-on-complete hook had not yet populated the file at read time. This release fixes both seams together — the snapshot now reflects the agent's working state regardless of commit state, and the canonical example inlines the snapshot read inside the curl invocation so the read happens AFTER the hook fires.

### Backward compatibility

The wire shape of `changed_files` is unchanged — same `path` + `diff` keys, same 500-line truncation rule, same binary placeholder string. Completion payloads that omit `changed_files` entirely continue to validate (the empty-array form produced by the inline `|| echo '[]'` fallback is also valid). Reviewers consuming the field see additional content under the new semantic — uncommitted edits and untracked new files now appear in `/review` whereas previously they were silently dropped.

### Source

Implemented as G156/W758 (combined SKILL.md + hook + tests + contract doc + release). Companion contract update lands in `kanban/docs/diff-contract.md` (working-tree-relative encoding guidance, untracked-file note); companion marketplace pin update lands in `stride-marketplace/marketplace.json` and CHANGELOG. Cross-plugin parity ports (G151–G154, G158) port this release into the other five plugins.

## [1.14.1] - 2026-05-20

### Changed

- **`skills/stride-completing-tasks/SKILL.md`** — Surface the optional `changed_files` field in two canonical reading locations so agents who skim the standard example don't have to navigate to the dedicated Per-File Diff Capture (Optional) section before adopting the field. (1) The API Request Format example body (around line 329) now includes both `actual_files_changed` and `changed_files` rows. The `changed_files` entry contains a single object with `path` and a realistic unified-patch `diff` string (proper `\n` and `\"` escapes so the JSON parses). (2) The pre-completion verification checklist (around line 124) now contains a new item with the exact literal text required by W748's AC2: `- [ ] **Did you embed \`.stride-changed-files.json\` into the payload as \`changed_files\`?**` followed by conditional embed-when-exists / omit-when-absent guidance and a cross-link back to the Per-File Diff Capture (Optional) section. (3) A new `**Optional:**` note below the existing review_report optional note points readers at the same section for the snapshot lifecycle and read pattern; the 500-line truncation marker, binary placeholder, and `{path, diff}` shape rules continue to live solely in `docs/diff-contract.md` and are not duplicated. The existing Per-File Diff Capture (Optional) section is preserved untouched. Sourced from W748.
- **`.claude-plugin/plugin.json`** — Patch-bumped from `1.14.0` to `1.14.1`.

### Source

Patch release shipping the W748 SKILL.md surfacing edits. No code, hook, or test changes — pure documentation update so installed plugins pick up the canonical-example and checklist additions via `/plugin update stride@stride-marketplace`. Companion marketplace pin bump lands as W756's stride-marketplace side.

## [1.14.0] - 2026-05-20

### Added

- **`hooks/stride-hook.sh`** — New `capture_changed_files()` bash function implements the G148/W719 per-file diff JSON contract. The function diffs each tracked file between `$TASK_BASE_REF` (captured at claim time in `before_doing`, with `HEAD~1` fallback if absent) and `HEAD`, truncates each diff at exactly 500 lines with the exact contract marker `[diff truncated at 500 lines]`, and emits the exact binary placeholder `[binary file — no diff captured]` (em-dash, U+2014) for files `git diff --numstat` reports as binary. After a successful `after_doing` hook — including the no-commands fast-path where the user's `.stride.md` is empty or all-commented — the script writes the resulting JSON array to `$CLAUDE_PROJECT_DIR/.stride-changed-files.json` so subsequent agent payload assembly can pick it up as the contract's optional `changed_files` field. `before_doing` now snapshots `git rev-parse HEAD` as `TASK_BASE_REF` into `.stride-env-cache` and clears any stale snapshot from a prior task; `after_review` cleans up both the env cache and the snapshot file. The function degrades to `[]` for any non-fatal failure (jq missing, git missing, non-git directory, no commits to diff), so legacy code paths remain valid. The script's early-exit checks were converted to `return 0 2>/dev/null || exit 0` so the test harness can `source` the script and exercise the function in isolation.
- **`skills/stride-completing-tasks/SKILL.md`** — New "Per-File Diff Capture (Optional)" section after the `actual_files_changed` examples documents the optional top-level `changed_files` array on the completion payload, where the snapshot comes from (the stride plugin writes `.stride-changed-files.json` at the end of `after_doing`), how the agent reads it to populate the field (`cat .stride-changed-files.json`, embed verbatim via `jq --argjson`, or omit when the file is absent — both shapes valid), and the backward-compatibility guarantee that completion payloads without `changed_files` remain valid forever. A new row in the Completion Request Field Reference table marks the field as optional. Cross-links to the contract reference doc at `docs/diff-contract.md` as the single source of truth — encoding rules, exact strings, and truncation/binary conventions are not duplicated.
- **`hooks/test-stride-hook.sh`** — New "Test Group 7: Per-file diff capture" (19 cases): truncation at exactly 500 lines (no marker), truncation at 750 lines (truncated to 500 total with marker as the last line), empty input, binary detection via numstat (positive / negative / missing-file), full integration in temp git repos with text + binary + deleted files, non-repo fallback returns `[]`, empty-base-ref → `HEAD~1` fallback, end-to-end `after_doing` snapshot write under both populated and all-commented `.stride.md`, legacy bypass (`before_review` leaves the snapshot file untouched), empty changed-files list when base resolves but no files differ, and null-byte file binary detection. Suite total: 91/91 passing — no regression in the existing six test groups.
- **`README.md`** — Gitignore note expanded to include `.stride-changed-files.json` alongside `.stride-env-cache`, with the cleanup lifecycle explained.

### Changed

- **`agents/task-reviewer.md`, `README.md`** — Declared `agents/task-reviewer.md` as the canonical source of truth for the `reviewer_result` JSON schema (W693). The README now points at the agent file for the structured-review schema rather than risking schema drift between the agent prompt and the workflow skill.

### Why this release

W720 added the server-side optional `changed_files` field. W721–W724 wired the kanban-app review-queue diff panel that consumes it. W719 published the JSON contract. This release implements the agent-side capture for the stride plugin so completion payloads carry per-file unified-patch text alongside the existing `actual_files_changed` comma-separated list. Reviewers can now approve or reject from the review queue without leaving Stride.

### Backward compatibility

`changed_files` is strictly optional on the completion payload and within each entry. Legacy plugin installs (pre-1.14.0) that emit no `changed_files` continue to validate cleanly — the review queue simply shows the file list with no inline diff panel content. Plugins emitting only `path` with no `diff` (because capture failed or the file was deleted) also continue to validate. The marketplace bump pinning users to this release follows in stride-marketplace v1.27.0.

## [1.13.0] - 2026-05-19

### Changed

- **`agents/task-reviewer.md`** — Rewrote step 6 ("Return Structured Review") and the "Output persistence" paragraph to require an unconditional fenced ```json block alongside the existing human-readable prose summary. The block has documented top-level fields (`schema_version`, `summary`, `status`, `issue_counts`, `issues`, `acceptance_criteria`), snake_case throughout, with closed enums for `severity` (`critical` | `important` | `minor`), `category` (`acceptance_criteria` | `pitfall` | `pattern` | `testing` | `code_quality` — matching the five preceding review steps), top-level `status` (`approved` | `changes_requested` — derived from issue severities + criterion outcomes), and acceptance-criterion `status` (`met` | `not_met` — aligned with `Kanban.Tasks.CompletionValidation`'s `@status_enum`). A worked changes_requested example with one critical pitfall violation, one minor code-quality issue, and one not_met criterion is included for the agent to mimic; the example parses cleanly via the task's verification regex (`re.search(r'```json\n(.*?)\n```', ...)`). The prose summary line above the JSON block is preserved verbatim so orchestrator fallback paths that grep for substring summaries continue to work when JSON parsing fails. Frontmatter (`name`, `description`, `model`) and steps 1–5 are unchanged.
- **`skills/stride-workflow/SKILL.md`** — Step 6 ("Code Review") now documents the JSON-block extraction pattern that the agent prompt change makes the contract for. A new "Extracting the structured review block" subsection under the Claude Code path describes (a) extracting the first fenced ```json fence from the reviewer response, (b) the dual field mapping into `reviewer_result` — legacy fields `summary` / `issues_found` (sum of `issue_counts.*`) / `acceptance_criteria_checked` (length of the structured array) populated from the parsed JSON, and the structured fields (`status`, `issue_counts`, `issues`, `acceptance_criteria`, `testing_strategy`, `patterns`, `pitfalls`, `schema_version`) copied verbatim into the same `reviewer_result` map (never under a new top-level API key — the server persists `reviewer_result` as `:jsonb` and the new ReviewReportPanel renders from its contents), (c) a worked example showing a reviewer response paired with the resulting `reviewer_result` PATCH payload (legacy + structured fields coexisting), and (d) the documented fallback when JSON parsing fails — fall back to substring-matching the prose summary, count issues from the prose, omit every structured field from the PATCH (no empty placeholders), keep `dispatched: true` and `duration_ms` as captured. Schema definitions themselves live in `agents/task-reviewer.md` as single source of truth and are not duplicated in the workflow doc. The Decision Matrix, Skip-review rule, Step 8 schema reference, and frontmatter are unchanged.

### Why this release

Reviewer output stops being prose-only and becomes structured data without losing its human readability. The new fenced ```json block carries per-severity issue counts, per-issue file:line and category, and acceptance-criteria coverage in a closed schema that mirrors `Kanban.Tasks.CompletionValidation`'s enum discipline. Downstream Kanban consumers (the upcoming G143/G144/G145 work — ReviewReportPanel, server-side validated structured `reviewer_result` fields, and per-severity telemetry aggregation) can extract structured fields from the completion payload directly, while older deploys continue to see the legacy `summary` / `issues_found` / `acceptance_criteria_checked` integers. The orchestrator now ships both groups inside the same `reviewer_result` map, the agent emits the block unconditionally (Approved runs included), and a documented prose-fallback path preserves behavior when the JSON cannot be parsed. The marketplace bump that pins users to this release follows in W687.

## [1.12.0] - 2026-05-08

### Removed

- **`skills/stride-workflow/SKILL.md`** — Removed all four references to the user-private `stride-development-guidelines` skill. The Step 5 ("Invoke Development Guidelines") section, the corresponding flowchart node, and the two Quick Reference Card lines (Claude Code + Other Environments) have been deleted. That skill is project-local to the plugin author's machine and is not distributed with this plugin, so end users would have seen Step 5 instructing them to invoke a skill that does not exist for them. The numbered Step 5 slot is left empty rather than renumbered — line 121 ("Steps 2, 3, 6, and 8") and the H2 headers for Steps 6–9 reference step numbers explicitly, so renumbering would have required widespread cross-reference updates.

### Why this release

Cross-skill references to non-plugin skills break the workflow for end users. This is the second time `stride-development-guidelines` references have crept into the plugin (see `[1.2.1]` for the prior removal); these guard rails are being applied to all five Stride plugins (`stride`, `stride-codex`, `stride-gemini`, `stride-opencode`, `stride-pi`) in a coordinated release.

## [1.11.0] - 2026-05-05

### Added

- **`agents/task-enricher.md`** — New Claude Code subagent that owns the four-phase task enrichment procedure (parse intent, explore codebase, estimate complexity, assemble JSON). Frontmatter mirrors `task-explorer.md` (model: sonnet, two inline `<example>` blocks). Body covers all six Phase 2 exploration steps with decision-logic blocks, the Phase 3 complexity heuristic table, the 16-item Phase 4 pre-submission checklist, five edge cases, and five common mistakes. Read-only — does NOT call the Stride API; returns a single enriched-task JSON object for the orchestrator to submit. Title, type, and description from human input are sacrosanct and never modified by the agent.
- **`skills/stride-subagent-workflow/SKILL.md`** — New `## Pre-Claim: Enrichment (Sparse Tasks)` section between the Decision Matrix and Phase 0, documenting when to dispatch `stride:task-enricher` (sparse fields detected at orchestrator Step 1), what to pass (identifier + sparse fields with title/type/description sacrosanct), what to expect back (single enriched JSON), and the post-enrichment workflow (PATCH + re-fetch + claim). Agent inventory bullet list also updated.

### Changed

- **`skills/stride-enriching-tasks/SKILL.md`** — Slimmed from 781 lines to 269 lines (66% reduction). Restructured body into platform-aware dispatcher: a `#### Claude Code: Dispatch the Enricher Agent` H4 block (numbered steps mirroring stride-workflow Step 3 style) that dispatches `stride:task-enricher` and submits returned JSON via the existing API Integration block, plus a `#### Other Environments: Manual Walkthrough` block with condensed Phase 1-4 walkthrough for Cursor/Windsurf/Continue users without subagent dispatch. STOP/orchestrator-check preamble preserved verbatim. API Authorization warning preserved verbatim. Phase 4 16-item checklist preserved verbatim. Heuristic tables, edge cases, common mistakes, full output format example, and rationalization tables moved into `agents/task-enricher.md` (manual walkthrough cross-references the agent file for the deep procedure). Frontmatter unchanged.
- **`skills/stride-workflow/SKILL.md`** — Step 1 enrichment check (line 142) updated with Claude Code vs Other Environments subsections matching Step 3's H4 + bold-verb + numbered-step style. Claude Code subsection dispatches `stride:task-enricher` and submits returned JSON via `PATCH /api/tasks/:id`. Other Environments subsection invokes `stride-enriching-tasks` and walks its Manual Walkthrough Phases. Sparse-detection trigger (empty `key_files` OR missing `testing_strategy` OR empty `verification_steps` OR blank `acceptance_criteria`) preserved.
- **`skills/stride-subagent-workflow/SKILL.md` frontmatter** — Description updated to enumerate `stride:task-enricher` alongside the other four agents and to mention the orchestrator's enrichment phase.

### Why this release

Enrichment was the only major exploratory phase still inlined as a heavyweight skill (781 lines). Moving it into a Claude Code subagent matches the established pattern (`task-explorer`, `task-decomposer`, `task-reviewer`, `hook-diagnostician`), isolates the exploration work from the orchestrator's context window, and enables parallel enrichment of multiple sparse tasks. The slimmed skill remains as a thin platform-aware dispatcher so non-Claude-Code users (Cursor, Windsurf, Continue) can still walk the four phases manually.

### Behavior change for users

- **Claude Code users**: when the orchestrator's Step 1 enrichment check fires, it now dispatches the `stride:task-enricher` agent instead of inlining the 781-line skill body. Behavior is equivalent — the agent runs the same four phases — but the orchestrator's context stays clean and the work can run in parallel for batch enrichment scenarios.
- **Other-environment users**: the `stride-enriching-tasks` skill now contains a condensed manual walkthrough (Phase 1-4 with the 16-item checklist preserved verbatim) plus a footer pointer to `agents/task-enricher.md` for the full decision logic, edge cases, and common mistakes. End-to-end verification confirmed the slimmed skill produces enrichments comparable in quality to the agent-path.

## [1.10.0] - 2026-04-29

### Added

- **`hooks/stride-skill-gate.sh` and `hooks/stride-skill-gate.ps1`** — New PreToolUse hook that gates direct invocations of internal Stride sub-skills. The gate reads `tool_input.skill` from the hook payload, allows `stride-workflow` and any non-Stride skill silently, and blocks the six protected sub-skills (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`) unless an orchestrator marker file is present and fresh. Block decisions emit a compact `{"decision":"block","reason":"..."}` JSON to stdout, a human-readable line to stderr, and exit 2 (Claude Code's PreToolUse block convention). Bash version uses jq with a parameter-expansion fallback and portable `date -d`/`date -j -f` freshness logic; PowerShell version uses `ConvertFrom-Json` and `[datetime]::Parse`. Native-Windows delegation mirrors `stride-hook.sh`.
- **`hooks/test-stride-skill-gate.sh` and `hooks/test-stride-skill-gate.ps1`** — Test harnesses covering all seven scenarios: marker missing, marker fresh, marker stale (>4h), `stride-workflow` always allowed, non-Stride skills always allowed, `STRIDE_ALLOW_DIRECT=1` bypass, and plugin-namespaced names (`stride:stride-claiming-tasks`) recognized and gated.
- **`hooks/hooks.json`** — New PreToolUse entry with matcher `Skill` invoking `${CLAUDE_PLUGIN_ROOT}/hooks/stride-skill-gate.sh` (timeout 10s). Existing PostToolUse(Bash) and PreToolUse(Bash) entries unchanged.
- **`skills/stride-workflow/SKILL.md`** — New "Orchestrator Activation Marker" section documenting the marker file contract: path (`$CLAUDE_PROJECT_DIR/.stride/.orchestrator_active`), single-line JSON shape (`session_id`, `started_at` ISO8601-Z, `pid`), 4-hour freshness window, and the `STRIDE_ALLOW_DIRECT=1` bypass. Step 0 (Prerequisites) now writes the marker; Step 9 (Post-Completion) clears it via `rm -f`.
- **All sub-skill `SKILL.md` files** — New "## STOP — orchestrator check" preamble inserted as the first H2 after the title in `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, and `stride-subagent-workflow`. The block tells the agent to invoke `stride:stride-workflow` and not read further if it arrived directly from a user prompt.

### Changed

- **All sub-skill frontmatter `description:` fields** — Reframed as `INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt.` followed by API-contract framing. Removes user-intent verbs (`claim a task`, `complete a task`) so the skill matcher does not pick sub-skills on plain-English Stride prompts.
- **`skills/stride-workflow/SKILL.md` frontmatter `description:`** — Amplified to enumerate user-intent phrases (`claim a task`, `work on the next stride task`, `complete a stride task`, `enrich a stride task`, `decompose a goal`, `create a goal or stride tasks`) and to explicitly list the six sub-skill names dispatched from inside the orchestrator. The matcher now resolves Stride-related user intent to the orchestrator instead of to a sub-skill.

### Why this release

Background and rationale documented in `docs/plans/stride-plugin-feedback.md` (downstream agent feedback from a Claude session that consistently bypassed the orchestrator). This release implements all three layers described there in increasing strength: (1) hard-stop body preambles, (2) reframed frontmatter descriptions, (3) the PreToolUse hook gate. The override env var (`STRIDE_ALLOW_DIRECT=1`) is provided for plugin debugging and CI scenarios where direct sub-skill invocation is intentional.

### Behavior change for users

After upgrading, invoking `stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, or `stride-subagent-workflow` directly will be **blocked** by the PreToolUse hook unless `stride-workflow` was invoked first (writing the marker file in Step 0) or unless `STRIDE_ALLOW_DIRECT=1` is set. Existing flows that already use `stride-workflow` as their entry point are unaffected — the orchestrator dispatches sub-skills through the same Skill tool and the gate reads its own marker as proof of legitimate dispatch.

## [1.9.1] - 2026-04-17

### Changed

- **`agents/task-explorer.md` and `agents/hook-diagnostician.md`** — Pinned both subagents to `model: sonnet` (previously `model: inherit`). Task exploration is mechanical file-reading and pattern-matching, and hook diagnosis is structured triage over tool output — both are well within Sonnet's range and run frequently enough that the speed/cost delta matters. `task-reviewer` and `task-decomposer` remain on `inherit` because reviewer quality and decomposition judgment benefit more from the parent model.

## [1.9.0] - 2026-04-16

### Added

- **`stride-completing-tasks` skill** — Surfaced `explorer_result` and `reviewer_result` in five places so agents cannot forget them: (1) the MANDATORY teaser at the top of the skill lists both as required alongside the hook results; (2) the pre-completion Verification Checklist asks whether both are included; (3) the primary API Request Format example includes both with dispatched-subagent shapes; (4) a new "Explorer/Reviewer Result Schema" section documents the dispatched shape, the skip shape, the five-value skip-reason enum (`no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`), the 40-character non-whitespace summary minimum, a 422 rejection example, and the feature-flag grace-period rollout; (5) the Completion Request Field Reference table lists both as required objects; (6) the Quick Reference Card's `REQUIRED BODY` includes both plus a SKIP FORM snippet.
- **`stride-workflow` skill** — Step 8's Required Fields table and JSON payload example now include `explorer_result` and `reviewer_result`. A new "Explorer and Reviewer Result Rollout" section after "Workflow Telemetry" describes the grace-mode/strict-mode feature-flag phases and directs readers to `stride-completing-tasks` for the full shape (no schema duplication). Orchestrator prose explains that Steps 3 and 6 already capture the data needed to populate these fields in Step 8.

## [1.8.0] - 2026-04-14

### Added

- **`stride-workflow` skill** — New "Workflow Telemetry: The `workflow_steps` Array" section documenting the telemetry array the orchestrator must build up during a task and submit in the `/complete` payload. Defines the six-name vocabulary (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`), the per-step schema (`name`, `dispatched`, `duration_ms`, `reason`), and two end-of-workflow examples — one with full dispatch, one showing decision-matrix skips on a small task. Step 8 is updated to list `workflow_steps` as a required field in the completion payload and to include it in the example JSON.
- **`stride-completing-tasks` skill** — Surfaced `workflow_steps` in four places so agents cannot forget it: (1) the pre-completion Verification Checklist now asks "Is `workflow_steps` included in the complete payload?" with the six-name vocabulary inline; (2) the primary API Request Format payload example includes a six-entry `workflow_steps` array; (3) the Completion Request Field Reference table lists `workflow_steps` as a required array field with a pointer to the stride-workflow schema; (4) the Quick Reference Card's `REQUIRED BODY` example includes it. Schema matches `stride-workflow` key-for-key.

## [1.7.5] - 2026-04-14

### Removed

- **`hooks/stride-hook.sh`** — Removed the diagnostic logging introduced in 1.7.3. The hook no longer writes to `$CLAUDE_PROJECT_DIR/.stride-hook.log` on every invocation: the `_stride_debug` helper, the `_stride_debug_log_file` variable, the `STRIDE_HOOK_DEBUG` environment toggle, and all ~20 `_stride_debug` call sites are gone. The log file served its purpose diagnosing the 1.7.3/1.7.4 env-cache bug, and leaving it on by default pollutes every Stride-enabled project directory with an ever-growing file the user didn't ask for. Operators who need per-invocation traces can temporarily re-add logging locally or run the test suite. Fatal failures (non-zero exit from a hook command) still emit structured JSON on stdout and a human-readable error on stderr — that output is unchanged. The PowerShell companion (`stride-hook.ps1`) never had the debug logging, so it is unchanged in this release.

## [1.7.4] - 2026-04-14

### Fixed

- **`hooks/stride-hook.sh` and `hooks/stride-hook.ps1`** — Env-cache parsing for Claude Code's `tool_response` shape. Claude Code's Bash tool wraps the curl response as `{"stdout": "<api-json-string>", "stderr": "...", ...}`, so the API JSON we want lives inside `.tool_response.stdout` as a string. Earlier versions only matched legacy shapes (raw JSON-encoded string in `tool_response`, or a flat object) and silently logged `tool_response did not contain .data.id or .id — cache not written` against every claim from Claude Code. Result: `TASK_IDENTIFIER`, `TASK_TITLE`, etc. were never exported, and any `.stride.md` command that referenced them ran with empty values (e.g. `git commit -m "Completed task : "`). The hook now tries the wrapper shape first, then falls back to the two legacy shapes.
- **`hooks/stride-hook.sh`** — User commands no longer abort on unset env vars. The hook ran with `set -uo pipefail`, which propagated into each `eval` and aborted the command before it executed if it referenced an unset variable. Now `set +uo pipefail` is set immediately around the `eval`, then re-engaged. Combined with the env-cache fix above, this means a `.stride.md` line like `git commit -a -m "$TASK_TITLE"` runs reliably.
- **`hooks/stride-hook.sh`** — Added `EXEC RESULT` log line for every command (success and failure) recording exit code, stdout bytes, and stderr bytes. Previous versions only logged failures, so a command that returned 0 with empty output (or one that failed silently before running due to `set -u`) left no trace. Operators can now confirm what each step actually did from `.stride-hook.log`.

### Added

- **`hooks/test-stride-hook.sh`** — Regression test for the Claude Code `{"stdout":"<json>"}` env-cache wrapper shape (test 6e). Locks in the 1.7.4 fix so the parsing can't silently regress to the 1.7.3 behavior.

## [1.7.3] - 2026-04-14

### Added

- **`hooks/stride-hook.sh`** — Always-on diagnostic logging to `$CLAUDE_PROJECT_DIR/.stride-hook.log`. One line per hook invocation records the phase, pid, extracted command, routed `HOOK_NAME`, every early-exit reason, the env-cache parse outcome, and each command executed. Lets operators confirm whether Claude Code is invoking the hook at all and trace exactly which branch caused a silent exit. Set `STRIDE_HOOK_DEBUG=0` to disable. Log file is safe to delete and should be added to `.gitignore`. The PowerShell companion (`stride-hook.ps1`) is unchanged in this release.

## [1.7.2] - 2026-04-14

### Fixed

- **`plugin.json`** — Reverted the `"hooks": "./hooks/hooks.json"` declaration added in 1.7.1. Claude Code auto-loads `hooks/hooks.json` by convention, and the `manifest.hooks` field is only for *additional* hook files — so the explicit reference triggered a `Duplicate hooks file detected` installation error. 1.7.1 is broken at install time; upgrade directly to 1.7.2. The underlying question of why hooks appeared inactive in earlier sessions needs further investigation; it is not solved by manifest changes.

## [1.7.1] - 2026-04-14

### Broken

- Declared `"hooks": "./hooks/hooks.json"` in `plugin.json`. Claude Code refuses to install this version with `Duplicate hooks file detected`. Skip this version — upgrade to 1.7.2 instead.

## [1.7.0] - 2026-04-13

### Changed

- **`stride-claiming-tasks`** — Replaced soft "Recommended: Use the Workflow Orchestrator" section with non-negotiable "YOUR NEXT STEP" gate that demands stride-workflow invocation immediately after claiming. Added workflow violation warning to standalone mode section. Defense-in-depth: catches agents that bypass the orchestrator and invoke the claiming skill directly.
- **`stride-completing-tasks`** — Added "BEFORE CALLING COMPLETE: Verification Checklist" with 4 yes/no items: (1) Did you invoke stride-workflow? (2) Did you explore the codebase? (3) Did you review against acceptance criteria? (4) Are you ready for after_doing? If any answer is no, agents are instructed to go back and complete the step. Placed before "The Complete Completion Process" section.

## [1.6.0] - 2026-04-13

### Added

- **`stride-workflow` skill** — Single orchestrator that replaces the pattern of invoking 6+ separate skills at specific moments. Walks through the complete task lifecycle in one skill: prerequisites check, task discovery, claiming with hooks, codebase exploration (subagent dispatch on Claude Code, manual on other platforms), implementation, code review, hook execution, completion API call, and auto-loop for needs_review=false. Includes the subagent decision matrix (from stride-subagent-workflow), platform detection guidance, dual Quick Reference Cards for Claude Code and other environments, edge case handling (hook failures, needs_review branching, goal decomposition), and a failure modes prevention table.

### Changed

- **`stride-claiming-tasks`** — Rewrote the `AUTOMATION NOTICE` section from speed-focused ("work continuously without asking") to process-focused ("the workflow IS the automation — every step exists because skipping it caused failures"). Added "Recommended: Use the Workflow Orchestrator" section pointing to stride-workflow as the primary entry point for new task work. Renamed "MANDATORY: Next Skill After Claiming" to "Next Skill After Claiming (Standalone Mode)" for agents using this skill directly. Removed "Subagent-Guided Implementation" section (absorbed by orchestrator).
- **`stride-completing-tasks`** — Rewrote the `AUTOMATION NOTICE` section with identical process-over-speed reframing consistent with claiming skill. Added "Arriving from stride-workflow" section confirming prerequisites are met when using the orchestrator. Renamed "MANDATORY: Previous Skill Before Completing" to "Previous Skill Before Completing (Standalone Mode)" with stride-workflow listed as the recommended primary path.
- **`README.md`** — Added stride-workflow to the Mandatory Skill Chain, workflow order diagram, and Skills section. Updated descriptions to reflect orchestrator as the recommended entry point.

## [1.5.2] - 2026-03-25

### Added

- **`hooks/stride-hook.ps1`** — PowerShell companion script that mirrors all functionality of stride-hook.sh for Windows compatibility. Uses PowerShell-native idioms: ConvertFrom-Json for JSON parsing (eliminates jq dependency), ConvertTo-Json for structured output, Start-Process for command execution with separate stdout/stderr capture, and [DateTimeOffset]::UtcNow for timing. Handles CRLF line endings, environment variable caching, and all 4 hook lifecycle phases. Produces identical structured JSON output format as the bash version.
- **`hooks/test-stride-hook.ps1`** — Comprehensive PowerShell test suite with 70 assertions across 6 test groups mirroring test-stride-hook.sh. Covers JSON extraction, .stride.md parsing, whitespace trimming, command list building, full end-to-end integration, and edge cases (CRLF, no trailing newline, env caching, structured JSON output). Self-contained — no Pester dependency.
- **Platform detection dispatcher in `stride-hook.sh`** — Detects native Windows environments (COMSPEC set, no OSTYPE) and automatically delegates to stride-hook.ps1 via `powershell.exe -ExecutionPolicy Bypass`. Git Bash (OSTYPE=msys) and WSL continue running bash directly. Provides clear error messages if stride-hook.ps1 or powershell.exe are missing.

### Changed

- **`stride-claiming-tasks` skill** — Added "Claude Code: Hooks Are Fully Automatic" section explaining that hooks.json handles hook execution automatically via stride-hook.sh. Agents in Claude Code should make API calls directly without manually executing .stride.md commands. Separated claiming workflow into "Claude Code (Automatic Hooks)" and "Other Environments (Manual Hooks)" paths. Added new Common Mistake #4 for manually executing hooks in Claude Code. Updated flowchart and Quick Reference Card with both paths.
- **`stride-completing-tasks` skill** — Added identical "Claude Code: Hooks Are Fully Automatic" section for completion hooks. Separated completion workflow into Claude Code and other environment paths. PreToolUse auto-runs after_doing before the complete curl; PostToolUse auto-runs before_review after. Added new Common Mistake #4. Updated flowchart and Quick Reference Card.

## [1.5.1] - 2026-03-24

### Fixed

- **`hooks/stride-hook.sh`** — Replaced `awk`, `sed`, and `seq` with pure bash equivalents for cross-platform compatibility. Windows systems (Git Bash/MSYS2) do not ship `awk` or `sed`, causing the `.stride.md` parser to silently skip all hook commands and exit 0 — a silent failure where hooks appeared to succeed without executing anything. The parser now uses a `while read` loop with `case` statements, the JSON extraction fallback uses bash parameter expansion, whitespace trimming uses `${var#pattern}`, and the remaining-commands loop uses C-style `for ((...))` arithmetic. Also fixed the no-jq JSON extraction guard: when the `"command"` key was absent from the hook JSON, the fallback would extract a value from an unrelated key instead of returning empty.

### Added

- **`hooks/test-stride-hook.sh`** — Comprehensive test suite for stride-hook.sh with 67 tests across 6 groups: JSON command extraction (no-jq fallback), `.stride.md` section parser, whitespace trimming, command list building, full end-to-end integration, and edge cases (CRLF line endings, no trailing newline, environment variable caching). Validates all pure bash replacements produce identical behavior to the original `awk`/`sed` implementations.

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
