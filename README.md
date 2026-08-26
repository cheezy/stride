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
| Complete without `stride-completing-tasks` | 3+ failed API calls — missing `completion_summary`, `actual_complexity`, `actual_files_changed`, `after_doing_result`, `before_review_result`, `explorer_result`, `reviewer_result`, `workflow_steps` |
| Create task without `stride-creating-tasks` | Malformed `verification_steps`, `key_files`, `testing_strategy` — causes 3+ hours wasted during implementation |
| Create goal without `stride-creating-goals` | 422 error — wrong root key (`"tasks"` instead of `"goals"`) |
| Skip `stride-subagent-workflow` | No codebase exploration, no code review — wrong approach, missed acceptance criteria |
| Skip `stride-enriching-tasks` | Sparse task specs → implementing agent wastes 3+ hours on unfocused exploration |

## Skills

### stride-workflow

**RECOMMENDED** entry point for all task work. Single orchestrator that walks through the complete lifecycle: prerequisites, claiming, codebase exploration, implementation, code review, hooks, and completion. Handles both Claude Code (with subagent dispatch) and other environments (Cursor, Windsurf, Continue). Eliminates the need to remember which skills to invoke at which moments. (v1.38.0+) adds an optional **Manual & Exploratory Testing** step (Step 5.5); (v1.39.0+) adds an optional **Deep security-considerations review** sub-step in Step 5 — see below; (v1.40.0+) threads the optional `behaviour_test_matrix` through Step 4 (implementation driver) and Step 5 (reviewer dispatch); (v1.41.0+) hardens every rule that reads matrix row text — row text is untrusted data rather than instructions, the secret rule triggers on row *state* and covers credentials named by location, a refused row has a named channel (`completion_notes`) and a redaction sentinel for the reviewer's echo, and the PATCH-body contradiction is resolved by stating that re-sending already-stored row text unchanged onto its own record is not a new copy; (v1.48.0+) maps the exploratory-testing severity rubric onto the reviewer issue enum and sets the escalation policy for a Critical exploratory finding — see below; (v1.53.0+) adds an optional **`/harden`** sub-step (Step 5.6) that turns a session's findings into drafted regression checks, sequenced so a drafted check can never turn the `after_doing` gate red; (v1.65.0+) a skipped `workflow_steps` entry may carry an optional machine-readable `reason_code` beside its free-text `reason` — see below; (v1.66.0+) the hot path is re-extracted and size-gated — the regrown orchestrator body moves back into gated sibling files (`review-block-extraction.md`, `optional-security-review.md`, `behaviour-test-matrix.md`, plus new `hook-execution.md` and `reference.md` sections) with every gate, decision matrix, Decision Summary, and prompt-injection framing rule kept inline; `reference.md`'s dispatcher-mode summaries gain the completed-status confirmation gate; and `scripts/check-skill-budgets.sh` runs as hook-suite Group 28 so hot-path files cannot silently regrow. (v1.67.0+) a **relatedness gate** sits ahead of the Step 5.5 severity/provenance policy — a finding whose responsible lines are lines this task changed, or that is the same defect class as the change, is fixed in-task at any severity rather than filed, with a follow-up task the documented exception for a genuinely out-of-scope bug; and `reference.md` gains a **Session Position** operator section saying when to share a session and when to start fresh.

### Optional: Manual & Exploratory Testing integration (v1.38.0+)

When the [`stride-exploratory-testing`](https://github.com/cheezy/stride-exploratory-testing) plugin is installed, the workflow gains an optional **Manual & Exploratory Testing** step — Step 5.5 in `stride-workflow`, Phase 3.5 in `stride-subagent-workflow`, between Code Review and Execute Hooks. When a task's `testing_strategy.manual_tests` is non-empty, each manual test is framed as an exploratory **charter** and the plugin runs a time-boxed session via its **one non-interactive session surface** — the `explorer` agent, dispatched once per charter. (`/charter` and `/debrief` are non-interactive too; they simply do not run sessions.) Interactive commands are never auto-dispatched, including `/explore` itself: its opening question round asks which interaction tools the session has, which a slash command cannot answer for itself, so it cannot be driven unattended. `/pair` in particular is the plugin's human-at-the-keyboard surface and is a deliberate human action, never something the workflow starts, because the orchestrator does not prompt the user between steps and an unattended prompt would stall the task until its claim expired. `/nightmare-headline` and `/recon` are excluded on the same grounds, as is the plugin's own routing skill — the surface a careless "dispatch the plugin" lands on, which can hand the request to any of them. The skills carry that list in full, and behind it a principle that governs whatever the plugin gains later: dispatch a command, agent **or skill** only if it completes unattended, judging it by the prompts it *can* raise rather than only those it always raises. The findings are recorded in existing completion fields (`completion_notes` and the `reviewer_result.testing_strategy` note) — no new completion field is introduced. **(v1.51.0+)** that summary also names **who is harmed and how** for each bug, not only its severity, since severity says how bad a failure is and never who it lands on — read from the installed contract's impact field where it has one, and assessed in the agent's own words where it does not. Where no reviewer ran, `completion_notes` is the only carrier and is persisted only by newer Stride servers, so one line is mirrored into the required, always-rendered `completion_summary` as a durability backstop — an existing field, not a new one. When a written session artifact exists, its path is cited so a reader can reach the full record instead of only the paragraph; the path is recorded repository-relative, and never the artifact's contents, which may hold unredacted session output. In practice the automated path writes no artifact — nothing in the `explorer` agent's contract asks it to write a session file — so the prose summary is the normal and complete record there, and a path appears only when a human separately ran a session that wrote one. Dispatched manual testing preserves the exploratory-testing safety boundary — it never runs destructive or production-mutating actions. The creation skills add an advisory note nudging authors to phrase `manual_tests` entries as chartable scenarios. **Before your first session, add `.exploratory/` to the project's `.gitignore`**, alongside `.stride/`. A session that writes to disk puts it there **by default** — `/explore`, `/pair` and `/harden` each take an `--output` flag that relocates artifacts elsewhere, and a relocated path needs its own entry — holding transcribed application output, and it arrives untracked — so if your `.stride.md` `## after_doing` section stages everything before committing (`git add -A` is a common quality-gate shape), it will sweep those files into a commit. Neither behaviour is wrong on its own; they interact badly, and one line prevents it. The plugin never edits your `.gitignore` for you, and the entry is inert when the directory never appears. Add it **before** your first session: `.gitignore` does not untrack a path git already tracks, so an artifact that has already been committed needs `git rm --cached` as well.

**(v1.48.0+)** each finding's severity maps onto `reviewer_result.issues[].severity` — Critical → `critical`, High and Moderate → `important`, Minor → `minor`, with an absent or unrecognized value landing on `important` and never on `critical`; the four-into-three collapse falls on High/Moderate because the reviewer values are dispositions at the completion gate rather than descriptions. A **Critical** finding now has a stated escalation policy in both Step 5.5 and Phase 3.5, turning on one decidable question: **are the responsible lines among the lines this task added or modified?** The agent localizes the finding to its fault site by reading the repository, then compares that against its own change set — every line changed relative to the task's base ref (read from the project root's `.stride-env-cache`, since that value is exported to hooks and not to the agent, and computed in the repo actually edited when that is a nested one), staged, unstaged and untracked-new included, **minus the paths already dirty when the task was claimed**, which are the human's edits rather than the agent's. The application's output is a lead for locating the defect and never evidence of provenance, because an escalation that blocks completion must not be triggerable by content an attacker can influence — and for the same reason the change set is never widened to the task's author-written `key_files`. **Introduced** — lines this task wrote — escalates **fail-closed in the same shape as the security integration**: `testing_strategy.status` → `failed`, a `category: testing` Critical issue appended to `issues[]`, `issue_counts.critical` and `issues_found` incremented, and the defect fixed, the charter re-run, and the reviewer re-run before completing. Every other case — the fault site is elsewhere, the change set cannot be determined, or the fault site could not be identified — is **discovered**: it appends nothing and flips nothing, and is recorded in `completion_notes` and one line of `completion_summary` and filed as a follow-up defect, so a bug whose responsible lines this task did not write never blocks it. No new completion field is introduced, and when the payload carries no structured review block — review skipped, or its JSON unparseable — there is no `issues[]` to escalate into and none is synthesized.

**(v1.53.0+) Optional hardening.** When a session returns convertible findings and the `/stride-exploratory-testing:harden` command is available, an optional **Step 5.6** (Phase 3.6 in the subagent skill) drafts one regression check per bug — the step that turns *Explored* back into *Checked*, so a bug found once stays found. `/harden` runs nothing and writes drafts to `.exploratory/checks/`, outside your test tree, so nothing enters your suite without you moving it there. That sequencing is the point: a check for an **unfixed** bug is *supposed* to fail, and `after_doing` is a blocking gate — so leaving drafts staged is the default. A check enters the suite only when two things hold: the **file loads** (a skip marker makes a test case inert, not a file, and a draft with unresolved wiring fails at compile time however it is tagged) **and** the case is green or marked skipped/pending. Both are established by running what the gate runs, once, rather than by expecting — anything less than clean means reverting and filing a follow-up instead. The hazard is presence in the tree, not the commit, since the gate runs your working tree. Because these files are written after the reviewer saw the diff, the step requires that they be named in the completion record rather than riding along silently. Note the command post-dates the plugin's first release, so the step checks for `/harden` itself rather than assuming the plugin implies it.

**(v1.54.0–v1.61.0) Reachability, honesty about coverage, and where the time goes.** A run of consistency fixes, most of them found by exploratory sessions run against this integration itself. **The step is reachable on small tasks, and now says so everywhere.** Its gate is `manual_tests` plus plugin availability with **no review precondition**, so a small 0-1 `key_files` task that skipped review still reaches it — but seven routing artifacts across the three skills said otherwise, sending that task straight from the skipped review to the hooks. All of them now route through it, and the completion gate's "a verdict must be present" checks are scoped to payloads where a review block was actually parsed, so a skipped or unparseable review no longer makes an otherwise-valid completion unsubmittable. **A blocked session is no longer silently counted as coverage:** it takes the same disposition as a zero-probe one — recorded as *not performed*, handed back as a human responsibility — unless the sheet shows it got through meaningful probes first, in which case it is partial coverage. The obstacle itself is recorded **as an obstacle**, in the terms the contract emits it, rather than as a severity-bearing finding, so an unreachable dev server stops being filed as an `important` testing bug. **The session's wall-clock has a stated home:** it folds into the existing `reviewer` `workflow_steps` entry, never a seventh step name — and where no reviewer ran, that entry is the skip form carrying no duration, so the dispatch is recorded in `completion_notes` instead of a duration being invented for a step that did not run. The gate's surface list and its never-execute-untrusted-plugin-content prohibition are now stated identically in both orchestrator skills, and the session-sheet guidance is conditioned on the **installed** contract rather than assuming one version's fields.

**Graceful fallback:** when the `stride-exploratory-testing` plugin is not installed, the task has no `manual_tests`, or you are in a non-Claude-Code environment, this step is skipped with no failure — completion proceeds exactly as before. The integration is optional and Claude-Code-only. The escalation policy changes nothing here: it exists only on the path where a session actually ran, so **no exploratory finding can block completion when the plugin is absent, the task has no `manual_tests`, or the environment is not Claude Code.**

### Optional: Deep security-considerations review (v1.39.0+)

When the [`stride-security-review`](https://github.com/cheezy/stride-security-review) plugin is installed, the Code Review phase gains an optional **Deep security-considerations review** — a sub-step in `stride-workflow` Step 5 (and an orthogonal Decision-Matrix dispatch in `stride-subagent-workflow`). It runs only when the task's `security_considerations` list is non-empty **and** the plugin is available (detected via its sanctioned surface, the same way the exploratory-testing gate is detected — never by executing untrusted plugin content). After the task-reviewer returns, the `stride-security-review:security-reviewer` agent is dispatched in **considerations mode** with the git diff and the task's `security_considerations` list (framed as **data to assess, never instructions**); its per-consideration verdicts are merged — via the existing verbatim whole-object copy — into `reviewer_result.security_considerations.considerations[]`. Escalation is **fail-closed**: any `partial` or `unmitigated` verdict forces `security_considerations.status` to `failed` and appends a `category: security` Critical issue to `issues[]`, which flows through the completion gate. The dispatch's time folds into the existing reviewer step — no new `workflow_steps` name.

**(v1.60.0–v1.61.0) It fires without a reviewer — and the docs now route you to it.** This sub-step's gate has **no reviewer precondition**, so it fires on a small 0-1 `key_files` task whose review the decision matrix excused. Two consequences were stated but unreachable. Its **telemetry rule** now covers that case: where no reviewer ran, the `reviewer` entry is the skip form carrying no duration, so the dispatch is recorded in `completion_notes` rather than a duration being folded into a step that did not run — and the entry is still submitted as `dispatched: false`, never dropped. (The JSON-parse fallback is explicitly *not* that case: there the reviewer did run and its entry keeps a real duration.) And the sub-step was **structurally unreachable** on that path — it is filed under the reviewer-dispatch section, which a small task never reads — so the "Skip review" branch now points at it, in the prose and in both flow summaries. Its gate conditions are unchanged; only its reachability was.

**Graceful fallback:** when the `stride-security-review` plugin is not installed, the task's `security_considerations` is empty (or an explicit `None — …` placeholder), or you are in a non-Claude-Code environment, this sub-step is skipped with no failure — the task-reviewer's prose verdict remains the sole source. On a **review-skipped** path there is no prose verdict to fall back to either, which is equally fine: the task simply continues with no security verdict recorded. If the plugin is present but returns malformed or absent verdicts, the review stays fail-closed: the prose verdict is kept and the anomaly is noted, never silently downgraded to `passed`. The integration is optional and Claude-Code-only.

### Optional: `workflow_steps[].reason_code` (v1.65.0+)

A skipped `workflow_steps` entry may carry a machine-readable `reason_code` **beside** its free-text `reason` — the code is what the compliance dashboard aggregates, the prose is what a human reads on the task detail page. Six values, derived by classifying every skipped entry persisted on a real board rather than invented: `decision_matrix_skip`, `ran_inline`, `hook_body_empty`, `subsumed_by_task_spec`, `folded_into_prior_step`, `matrix_deviation`.

The measured problem: **73 skipped entries produced 58 distinct reason strings averaging 145 characters**, so grouping them verbatim is very nearly one row per entry.

**Supplying it is optional and omitting it is always valid** — `reason` stays required-when-skipped and unconstrained, so an agent that predates this field, on any runtime, completes exactly as before. A `reason_code` outside the list **is** rejected, which is what stops a typo opening its own silent bucket. Use `matrix_deviation` when the decision matrix called for a step you did not run: it is the one code that records non-compliance, and reaching for `decision_matrix_skip` there would launder a deviation into a sanctioned skip. The validator and the aggregation live in the Stride server; emitting a code against a server that predates them is harmless.

**Canon-governed — entry `reason-code-vocabulary` in `docs/port-canon.md`.** That entry registers this vocabulary as one every port must carry, and the list above restates it rather than being its source of record. A change to its substance owes a version bump in two places before the next release: that entry in the canon, and stride's own `reason-code-vocabulary` anchor — which lives beside the picking table in `skills/stride-workflow/SKILL.md`, not in this file. This README deliberately carries no anchor of its own: the canon assigns one per rule per port directory, and stride's is already placed.

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Owns the completion contract — its Completion Request Field Reference table is the authoritative required-field set (including `explorer_result`, `reviewer_result`, and `workflow_steps`, which the API rejects requests without) and it documents both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time. (v1.66.0+) the skill is roughly half its former size: the happy path — the Field Reference, the Explorer/Reviewer Result Schema with the skip-reason enum, the pre-submission hard gate, and the curl stdout rules — stays inline, while worked examples, the per-file-diff back-compat subtree, hook-failure remediation, and the summaries move to four sibling files (`manual-testing-findings.md`, `diff-capture.md`, `hook-failures.md`, `reference.md`), each reachable from a pointer at its original site; no field requirement, schema shape, or enum value changed.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings). Also documents the optional `technical_details` field — a free-form JSON object (no fixed keys) for any extra technical context; it is optional everywhere and is not one of the five review_queue-scored fields. (v1.30.0+) documents the optional `created_by_agent` field — set it to the plugin's own agent name (the same value sent as `agent_name` on claim/complete) so the `/agents` feed attributes the creating agent; it is create-only and forbidden on `PATCH`. (v1.37.0+) documents the **top-level `agent_name`** beside the `task` root key on every create request — the always-sent fallback the server reads when `created_by_agent` is omitted (which cannot be backfilled), with the full five-step resolution order and an explicit note that `agent_name` is display metadata only, never an authorization signal. The same release adds a **Request Envelope** section: `POST /api/tasks` takes `{"agent_name": "...", "task": {...}}`, not a bare task object — the skill previously documented the body without its `task` root key, which the server rejects with a `422`.

### stride-creating-goals

**MANDATORY** before batch creation or goal creation. Contains the only correct batch format — root key must be `"goals"` not `"tasks"`. Most common API error when skipped. (v1.30.0+) documents `created_by_agent` on the batch goal — set once on the goal; the server propagates it to every nested child task. (v1.37.0+) documents the **top-level `agent_name`** beside the `goals` root key — outside the array, not on any goal or task — set to the same plain agent name sent on claim and complete, with the same five-step resolution order and display-metadata-only caveat.

### stride-enriching-tasks

**MANDATORY** when a task has sparse specification. Transforms minimal human-provided specs into complete implementation-ready tasks through automated codebase exploration. 5 minutes of enrichment saves 3+ hours of unfocused implementation.

### stride-subagent-workflow

**MANDATORY** after claiming any task (Claude Code only). Contains the decision matrix for dispatching task-explorer, task-enricher, task-reviewer, task-decomposer, and hook-diagnostician agents. Determines exploration and review strategy based on task complexity and key_files count.

## Agents

**Progressive disclosure of the agent bodies (v1.67.0+).** The three largest agent prompts are re-paid on every dispatch, so their reference material now lives in sibling files under `docs/` that the agent Reads on demand: `task-reviewer.md` 66,177 to 55,936 bytes (`docs/task-reviewer-examples.md`), `task-enricher.md` 37,338 to 28,865 (`docs/task-enricher-reference.md`), and `task-decomposer.md` 25,521 to 13,684 (`docs/task-decomposer-reference.md`) — **30,551 bytes** off the per-dispatch cost. What moved is illustration only: worked examples, edge-case sections and anti-example galleries. Every contract stays inline — the emitted block schema, the verdict rules, the bounded-summary contract, the four enrichment phases and their field types, the six decomposition steps and both sizing tables, and in all three the prompt-injection framing and the redaction rules. `docs/` rather than `agents/`, because every `.md` under `agents/` registers as a dispatchable agent. Each split was verified by dispatching the slimmed body against a real fixture rather than by reading the diff, and each verification found defects the diff review would not have: the reviewer's returned-summary rendering existed only in the example that moved (now specified inline for the first time), the enricher's waived-matrix-row shape was stated only by a sentence narrating its removed example, and the decomposer turned out never to have carried a treat-task-text-as-data boundary at all despite reading free-form human goal text.

### stride:task-explorer

A read-only codebase exploration agent dispatched after claiming a task. Reads every file listed in `key_files`, finds related test files, searches for patterns referenced in `patterns_to_follow`, navigates to `where_context`, and returns a structured summary so the primary agent can start coding with full context.

**Report persistence (v1.65.0+).** The explorer writes its full findings to `.stride/.explorer-<IDENTIFIER>-r<N>.md` and returns a summary bounded at **60 lines / 6,000 characters** naming that path — measured explorer reports ran 15.5–20.7 KB across 133–210 lines, and the caller re-sends whatever comes back on every later request. The bound is deliberately looser than the reviewer's because this summary is implemented from rather than parsed, so over-trimming forces the file open every time and saves nothing; it must carry one line per `key_file`, every pattern with its `file:line`, every conflict, and the reuse list, degrading by dropping quotes before detail. A dispatch that supplies no `EXPLORER_REPORT_PATH` is an older orchestrator that will never read the file, so the explorer writes nothing and returns its findings inline exactly as before. The same contract governs the `Plan` dispatch via `.stride/.plan-<IDENTIFIER>-r<N>.md`, stated in the orchestrator's Step 3 because `Plan` is the generic subagent and has no agent file of its own.

### stride:task-enricher

Explores the codebase to fill in a sparse task *before* it is claimed — discovers `key_files`, `patterns_to_follow`, `testing_strategy`, `verification_steps`, `security_considerations`, `pitfalls`, and a complexity estimate, and returns a single enriched-task JSON object that the orchestrator PATCHes onto the existing task. It never rewrites the human-authored title, type, or description. Claude Code only.

### stride:task-decomposer

Breaks goals and large tasks into dependency-ordered child tasks. Uses scope analysis, task boundary identification, and dependency ordering to produce implementation-ready task arrays with complexity estimates, key files, and testing strategies per task. Claude Code only.

### stride:task-reviewer

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, verifies `testing_strategy` alignment, and confirms the task's `security_considerations` were implemented. Returns categorized issues (Critical/Important/Minor) with file and line references.

The canonical `reviewer_result` JSON schema (`schema_version` `"1.6"`) — `summary`, `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]` with the `met`/`not_met` enum, `project_checks[]` (v1.18.0+; per-entry `status` enum `met`/`not_met`/`not_applicable` and full-checklist emission as of v1.23.0), and the per-section `testing_strategy` / `patterns` / `pitfalls` (v1.19.0+) / `security_considerations` (v1.21.0+) verdict objects (`passed`/`failed`/`not_assessed`), plus the OPTIONAL `behaviour_test_matrix` verdict with its per-row breakdown (v1.40.0+; emitted only when the task supplies a matrix) — is defined in [`agents/task-reviewer.md`](agents/task-reviewer.md) and is the schema of record for all six reviewer-variant prompts. Variant prompts cite that path; do not duplicate the schema elsewhere. The full structured block is persisted **verbatim** as `reviewer_result`: orchestrators and completion skills passthrough every key the reviewer emits and never re-enumerate an allow-list of which keys to copy (v1.22.1), so any field the schema gains flows through automatically. As of **v1.24.0**, review reports must be delivered **complete, with no exceptions**: the orchestrator passes the reviewer every field the task supplies (including `security_considerations`), `not_assessed` is reserved strictly for a section the task left empty, the structured output is carried through by a mechanical whole-object copy, and a mandatory pre-submission self-check refuses to complete a task whose review is thin or leaves a task-supplied section unassessed. The persisted block is rendered by the Kanban review queue (issue list, acceptance verdicts, code-review checks, and the four section-verdict tiles). As of **v1.42.0**, the file's worked example also demonstrates `category: "security"` — an `important`-severity issue paired with an `unmitigated` `considerations[]` entry and a `failed` `security_considerations` verdict — so the fail-closed escalation rule, and step 5's Important-unless-exploitable severity split, are shown rather than only stated. As of **v1.43.0**, the example's `not_met` acceptance criterion is likewise backed by a `category: "acceptance_criteria"` issue its `evidence` resolves to, and the preamble records why that issue is `important` rather than `critical`: review step 1 works on a three-value scale (Met / Partially Met / Not Met) while the emitted `status` enum has two, so a partially-satisfied criterion collapses to `not_met` on the wire and keeps `important` severity, with `critical` reserved for a criterion whose behaviour is wholly absent. `pattern` is now the only `issues[].category` value with no worked instance. As of **v1.44.0**, a real finding outranks `not_assessed` in all four section tiles — an empty task section plus a genuine matching-category issue is `failed`, never `not_assessed`, with suppressing or re-labelling the finding named as the worse defect; review step 5's dimension checks now run whether or not the task listed considerations; and the two nested-array escalation rules bind in both directions, with deliberately opposite reverse cases (a `failed` `security_considerations` beside an all-`mitigated` `considerations[]` is legitimate, because the failure can originate outside the task's list, while a `failed` `behaviour_test_matrix` beside no `failing` row is a defect, because `rows[]` enumerates everything that verdict can be about). As of **v1.54.0**, the self-check's three "the task supplied it, so a verdict must be present" checkboxes — the task-supplied-section rule, its `behaviour_test_matrix` sibling, and the nested `considerations[]` check — are **scoped to a payload where a structured review block was actually parsed**: a self-reported skip and the JSON-parse fallback carry no verdict object at all, so those checks are inapplicable there rather than failed, which is what makes the fallback's "degraded-but-valid completion, never a hard failure" guarantee true as written. The rules still hard-block the case they were written for — a dispatched review whose block parsed and returned `not_assessed` for a field the task supplied — and the fail-closed security escalation survives the scoping with `completion_notes` plus `completion_summary` as its carrier where no `issues[]` exists.

**Block and report persistence (v1.65.0+).** The reviewer writes the structured block to `.stride/.review-<IDENTIFIER>-r<N>.json` and the full human report to the `.md` beside it, returning a summary bounded at **24 lines / 2,000 characters**. A review response ran roughly 27 KB, ~17 KB of it the block; on a real 25-`project_checks` review the summary is 8 lines / 475 characters, and it is O(1) in review size because `project_checks` renders as a tally and the issue index is capped at ten rows. Two files rather than one, because `review_report` is what a human reads on the task detail page and the block alone would reduce it to a stub. The orchestrator reads only the paths **it supplied** — the paths named in the returned summary are for the human reader and are never used as a path, since a reviewer steered by injected content could otherwise name any local file and have its bytes spliced into `review_report` and PATCHed to the server. A dispatch with no `REVIEW_BLOCK_PATH` writes nothing and emits the block inline, which is what keeps an older orchestrator working. The schema is unchanged and `schema_version` stays `"1.6"`: the carrier moved, no field did, and the five other variant prompts keep returning the block inline.

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

**Executor stdout contract (v1.64.0+).** The hook writes **exactly one JSON document** to stdout per invocation. Claude Code parses hook stdout as a single document, so when a primary section and `## after_goal` both ran, the previous two-object output failed a strict parse and every harness-facing field in it — including `hookSpecificOutput.additionalContext` — was silently dropped. One section still emits its own object unchanged; more than one emits `{sections: [...]}` with `hookSpecificOutput` hoisted to the root, discriminated by the absence of a top-level `hook` key. Verify with a strict parser, never `jq` — both `jq .` and `jq -s` accept a concatenated stream and cannot detect the failure. See `skills/stride-workflow/parser.md`.

**Durable hook results (v1.64.0+).** Every section that does work also persists its structured result to `.stride/.hook-result-<hook>.json`, on both the success and failure paths, cleared at claim time. An absent file means the section body was empty and did no work, so `0` is the truthful duration. This makes `after_goal`'s real duration readable when building its follow-up PATCH; `after_doing` and `before_review` remain `0` because both fire on the very curl whose body already carries their result.

**Native Windows runs now capture, attribute and narrow their own diffs (v1.68.0+).** Before this, `stride-hook.ps1` had no capture step at all: it PUT a `.stride-changed-files.json` that something else was assumed to have written, and on native Windows that something is nobody — `stride-hook.sh` execs the ps1 and exits. A native-Windows run therefore produced **no snapshot at all, with no error**. The ps1 hook now builds the snapshot (`Build-ChangedFilesSnapshot`), carries the five per-task record families, runs the same window-classification engine as bash (D236 windows, the D244 purity heuristic, the D256 fixpoint), evicts per window rather than by count so a live outer task's anchor survives (D268/D274), and replays the capture-time narrowing verdict on retry instead of re-deriving it (D273). The ps1 suite went from 530 to 961 assertions; the bash suite is unchanged at 787 and both bash files are byte-identical across the whole port.

**What still does not work on Windows PowerShell 5.1, stated because an over-claim here is the hazard.** The `Invoke-WebRequest -SkipHttpErrorCheck` blocker is **fixed** (**D277**): the 7.0+ parameter is gone from both call sites, so a non-2xx now throws on either host and the real status is recovered from the exception's `.Response`, with a null response — the transport case — yielding `000`, matching what the bash twin gets from `|| printf '000'`. Before that fix, binding failed before the request issued and every 5.1 upload recorded `000`, while the after_goal detection call swallowed the same failure under a `catch { return }` and no-opped D119 silently. What has **not** changed is the harder gap: nothing in this repo has ever *executed* the hook under `powershell.exe` — the compatibility gate is static and the ps1 suite runs under pwsh 7 (**D237**), so D277's fix is verified by reasoning and by pwsh-7 behaviour, not by a 5.1 run. D277 was found by reading rather than by a red gate; the regression cover that would now catch its return is Test Group 30 in the ps1 suite, not the gate.

**Commit attribution hardening (v1.67.0+).** The window model that attributes commits to tasks now classifies each window before subtracting it: a window whose residual is one commit is PURE and subtracts whole, two or more residual commits make it AMBIGUOUS and it subtracts only what other windows cover, with the trade decided for never losing an author's commit (D244). A nested task that commits through `after_doing` records its exact SHAs, so it no longer absorbs the outer's mid-window commit (D255); purity is a fixpoint, so two concurrently-open siblings can no longer manufacture purity from their mutual overlap (D256); eviction is per window and open-window-aware, so a live outer's anchor never falls to the cap (D268); and an outermost task — which has no enclosing window to absorb a dropped commit — keeps its manual commits instead of silently under-reporting them (D271). The remaining zero-commit-child steal is documented and pinned rather than fixed: the candidate branch was implemented behind a flag and measured to break nine pre-existing pins, reverting per-window attribution for every hand-committing agent (D272).

**Task-attributed `changed_files` (v1.64.0+).** A completing task's diff snapshot now carries the commits **that task** made, rather than everything committed between its claim and its completion. Tasks that claim and complete inside another task's window — the normal shape under dispatcher mode — no longer have their commits absorbed by the outer task.
6. Blocks tool calls (exit 2) on failure in PreToolUse context

**Hook routing:**

| Claude Code Event | API Endpoint Pattern | Stride Hook |
|---|---|---|
| PostToolUse (Bash) | `/api/tasks/claim` | `before_doing` |
| PreToolUse (Bash) | `/api/tasks/:id/complete` | `after_doing` (blocks completion on failure) |
| PostToolUse (Bash) | `/api/tasks/:id/complete` | `before_review` (+ `after_goal` if the response bundles it) |
| PostToolUse (Bash) | `/api/tasks/:id/mark_reviewed` | `after_review` (+ `after_goal` if the response bundles it) |

**`after_goal` (v1.17.0+):** the server bundles an `after_goal` entry alongside the primary hook in the response of `/complete` or `/mark_reviewed` when the completing task is the final child of a parent goal. The plugin auto-executes the local `## after_goal` section as a blocking hook (600s timeout, same shape as `after_doing`) and emits a structured result on stdout. The agent forwards the result via `PATCH /api/tasks/:goal_id/after_goal` to flip the goal to Done. A missing `## after_goal` section in `.stride.md` is a clean no-op (back-compat — older `.stride.md` files keep working unmodified). The hook receives `GOAL_ID` / `GOAL_IDENTIFIER` / `GOAL_TITLE` / `GOAL_DESCRIPTION` env vars from the server's `hook.env`, and is general-purpose (Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses — not just PR creation). **(v1.34.0+)** detection is now reliable regardless of `/complete` response size: the harness truncates a large `tool_response.stdout` mid-JSON, so the hook prefers a full canonical response file (`.stride/.last-api-response.json`) and, when that is absent/truncated, spawns a fresh `GET /api/tasks/:id/after_goal_status` call (not subject to Bash-tool truncation, zero agent cooperation) as the authoritative guarantee — the two paths are mutually exclusive so `## after_goal` runs at most once, and against a server without that endpoint the fresh call is a clean no-op (the grace worker still flips the goal to Done).

**Note:** Add `.stride-env-cache`, `.stride-changed-files.json`, `.stride-diff-upload-state`, `.stride-dirty-baseline`, and the `.stride/` directory to your `.gitignore` — all are temp artifacts written between hook invocations. **(v1.52.0+)** add **`.exploratory/`** too when the `stride-exploratory-testing` plugin is installed: session artifacts land there, hold transcribed application output, and arrive untracked, so an `## after_doing` section that stages everything would commit them (see the Manual & Exploratory Testing section). **(v1.34.0+)** `.stride/.last-api-response.json` is the canonical full API response the hook writes early in the post phase so `## after_goal` detection survives a harness-truncated `tool_response.stdout`; it lives under `.stride/` and is hard-excluded from every snapshot by name. `.stride-dirty-baseline` (v1.33.0+) records the paths already modified or untracked at claim time (with blob hashes) so pre-existing unrelated edits are excluded from `changed_files` unless re-modified during the task; like the other artifacts it is excluded from snapshots by name and cleaned up at claim refresh and after `after_review`. `.stride-env-cache` caches task metadata (including the base commit captured at claim time — **(v1.28.0+)** this `TASK_BASE_REF` is now refreshed on **every** claim, including when the claim response is too large to parse inline and Claude Code persists it to a file: the hook recovers the JSON from that "saved to" file, and even when no JSON is obtainable it still rewrites `TASK_BASE_REF` to the current HEAD so a stale base ref from a previous claim can never make `changed_files` span unrelated commits); `.stride-changed-files.json` holds the per-file diff snapshot; `.stride-diff-upload-state` (v1.25.0+) records the last upload outcome (task id + HTTP code only, never credentials). **Gitignoring `.stride-diff-upload-state` and `.stride-changed-files.json` matters:** if they stay tracked, an `after_doing` auto-commit that stages everything will commit them, and because their contents change on every run they then surface in every later task's diff against base, polluting `changed_files`. **(v1.27.0+)** `capture_changed_files` also excludes both of these root artifacts from the snapshot as a backstop (anchored to the repository root, so a same-named file in a subdirectory of your project is still captured) — but gitignoring them keeps them out of your commits in the first place. **(v1.25.0+)** the snapshot is captured and uploaded **before** the `after_doing` section commands run — so a hook timeout mid-quality-gate no longer loses the diffs — then refreshed after all commands succeed, and the `before_review` hook verifies the recorded outcome on its own fresh timeout budget, re-capturing and re-uploading when the recorded state is missing, stale, or non-2xx (a healthy upload is never repeated). On Stride server v1.16.0+ the `after_doing` hook PUTs this snapshot to the server automatically (no agent action required); against older servers, agents inline-cat the file into the completion body (see `stride-completing-tasks` SKILL.md). All three files are cleaned up automatically at the claim refresh and after the `after_review` hook. **(v1.22.0+)** The automatic PUT sends a transport-encoded envelope — `{"changed_files":{"encoding":"base64","data":"<base64>"}}` — so an edge request filter (WAF) cannot misread a code diff as an attack and silently drop the upload; the server decodes it back to the identical list. When `base64` is unavailable the hook falls back to the raw `{"changed_files":[...]}` shape, and a non-2xx upload response is now surfaced as a stderr warning (non-fatal; the bearer token is never logged). **(v1.35.0+)** the upload now targets the task id parsed from the `/complete`|`/mark_reviewed` command URL rather than the claim-time env-cache `TASK_ID`, so a stale or corrupt cache can no longer upload the diff to the previous task (D127); and when the `before_review` self-heal — the last retry — still fails to land a 2xx, the hook logs a distinct `CHANGED_FILES UPLOAD UNRESOLVED` message and appends `unresolved=yes` to `.stride-diff-upload-state` (fail-soft — it never vetoes the completion; a later successful PUT self-clears the mark) so a definitively-lost diff is actionable rather than silent (W1658). Both land in `stride-hook.sh` and `stride-hook.ps1`. **(v1.36.0+)** `TASK_BASE_REF` is captured **after** the `## before_doing` section runs — the section's `git pull` moves HEAD, and a pre-pull base made the diff span another clone's pushed commits (D132); the claim interception now strips any inherited base immediately and writes it (plus a `TASK_BASE_REF_TRUSTED` marker and the dirty baseline) post-section, jq-free. Every capture also passes the base through a `resolve_snapshot_base` trust guard that loudly recomputes empty/unresolvable, non-ancestor, or (for unmarked inherited values only) pre-branch-point bases from the task branch point — resolved once per task window and persisted as a `base=` line in `.stride-diff-upload-state` so the self-heal reuses the same judgment — and paths committed between the base and HEAD can never be dropped by the dirty-baseline filter (D137: committed task files whose content matched their claim-time hashes silently vanished from the snapshot).

### The `after_doing` time budget

The two Bash hook entries in `hooks/hooks.json` carry a **300-second timeout** (the Skill-matcher gate stays at 10 seconds — it fires on every Skill invocation and must remain fast). The timeout is a **ceiling, not a guarantee**: the entire `after_doing` section — every command in your `.stride.md` quality gate (test suite with coverage, credo, sobelow, auto-commit) plus the plugin's own snapshot work — shares this one budget.

When the budget is exceeded, Claude Code kills the hook process. With the early-capture fix (v1.25.0+) the per-file diffs are already uploaded before your gate commands start, so a timeout no longer loses them — but the structured success JSON, the post-command snapshot refresh, and any not-yet-run gate commands are still lost, and the completion call is blocked as if the gate had failed.

If your project's quality gate runs close to the ceiling, either trim the `.stride.md` `## after_doing` section (move slow steps like a full coverage run into CI) or raise the `timeout` values further in a fork of the plugin.

## Configuration

Before using Stride skills, you need two configuration files in your project root — and one `.gitignore` addition.

### `.gitignore`

Add these before your first task. Every entry is either a working artifact or a credentials file, and none should ever be committed:

```gitignore
.stride/
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
.stride-dirty-baseline
.stride_auth.md
.exploratory/
```

`.stride_auth.md` holds your API token. `.exploratory/` is where exploratory-testing session artifacts land when that plugin is installed — they hold transcribed application output and arrive untracked, so an `## after_doing` section that stages everything (`git add -A`) would commit them. Add the line **before** your first session: `.gitignore` does not untrack a path git already tracks, so an artifact already committed needs `git rm --cached` too.

The two configuration files:

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

**(v1.64.0+)** Both suites calibrate machine load at the start and end of a run
and scale their wall-clock backstops accordingly — clamped below each case's
un-killed duration, so a timeout that never fires still fails. Each run reports
its own wall clock and warns when the machine was busy, so a loaded run is
distinguishable from a failing one without re-running it.

**(v1.66.0+)** The bash suite's final group (Group 28) runs
`scripts/check-skill-budgets.sh`, the hot-path byte-budget drift detector: the
gate fails when `stride-workflow/SKILL.md`, `stride-completing-tasks/SKILL.md`,
or `stride-claiming-tasks/SKILL.md` exceeds its stated budget, and the failure
output names the file, its size, its budget, the extraction pattern to apply,
and where the budget table lives. Budgets sit 12-13% above post-extraction
sizes, so ordinary edits pass and only sustained regrowth trips (D229
philosophy); raising one is a deliberate, reviewed decision.

**(v1.68.0+)** Group 29 runs `scripts/check-ps1-compat.sh`, a static Windows
PowerShell 5.1 compatibility gate over `hooks/*.ps1` **and `scripts/*.ps1`** —
six files, the ps1 test suites included. It runs PSScriptAnalyzer's `PSUseCompatibleSyntax`
(`TargetVersions = 5.1`) and `PSUseCompatibleCmdlets`
(`desktop-5.1.14393.206-windows`), pinned in
`scripts/PSScriptAnalyzerSettings.psd1`, because `stride-hook.sh` execs
`powershell.exe` (5.1) and not `pwsh`: a 7-only construct a contributor's
pwsh 7 accepts would fail only on a user's Windows box. Every run first proves
itself against an in-memory 7-only probe and fails when either rule stops
firing, so a misconfigured settings file cannot pass as a clean run. The group
skips — loudly, printing the install command — when pwsh or the analyzer is
absent.

**(v1.71.0+)** bash Group 30 and PowerShell Group 32 run the **self-test** of
both halves of the port-canon drift check, in both suites, and cross-verify the
two against each other. They never run the fleet scan: its correct result today
is exit 1, and a permanently-red group teaches people to ignore the suite.

The cross-verification is what makes the pair worth having. `30c`/`32c` compare
the two halves' **case-name sets**, so a case renamed or lost on one side goes
red — something neither half's own tally can see, since each stays internally
consistent while disagreeing with the other. `32d` then runs both halves
against **one fixture tree** — the three exit tiers (0 all-clean, 1
drift-found, 2 no-verdict-possible), plus fixtures that reach the verdict space
(a stale anchor, an unknown-id anchor, vendored content under each pruned
directory) and the property path (including a case-varied rule id and a
case-varied registry key, the two shapes where the halves were found to
diverge) — and compares exit codes, tally counts, verdict lines and work lists, normalizing only the two absolute-path header
lines and each script's reference to its own filename. Both halves also agree
line for line over the real fleet, which is stronger evidence than any of these
— and is exactly what cannot be a test group, because it is red by design.

Adding both halves' self-tests costs roughly a minute of wall clock in each
suite (about 9s for the bash half, about 55s for the PowerShell half, which
re-execs its own script once per case group). `SUITE_WALL_BASELINE_S` in
`hooks/test-stride-hook.sh` was raised from 100 to 175 to match, rather than
trimming cases to fit the old number.

```
bash hooks/test-stride-hook.sh
pwsh hooks/test-stride-hook.ps1
```

These run by default with no setup, and they make no network requests — with
one exception in both respects, described next.

### The PowerShell 5.1 compatibility gate

Group 29 — and the same gate run on its own — needs PSScriptAnalyzer installed
once. That install is the suite's only setup step and its only network fetch,
at install time only, never during a run:

```
pwsh -NoProfile -Command "Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser"
```

The version is pinned so a later run cannot silently take a different build.
**Nothing in the plugin installs it for you** — no hook installs modules on
your machine. Without it, Group 29 skips with that command in its output, and
the rest of the suite is unaffected.

Run the gate on its own with:

```
bash scripts/check-ps1-compat.sh              # scan hooks/*.ps1
bash scripts/check-ps1-compat.sh --self-test  # prove the gate still detects 7-only code
```

Exit codes: `0` clean, `1` findings or a gate error, `2` pwsh or
PSScriptAnalyzer not installed.

When the analyzer in use is not the pinned version, the gate still runs and
still passes — the pin is a lower bound at runtime so a contributor already on
a newer build is not blocked — but it emits a `warn:` line naming both
versions, and Group 29 surfaces that line even on a pass. Drift is visible
rather than silent.

Because absent tooling *skips*, a runner without pwsh reports a green suite
having gated nothing. Where the gate is meant to be mandatory — CI, a release
check — set `STRIDE_PS1_GATE_REQUIRED=1` and the skip becomes a failure:

```
STRIDE_PS1_GATE_REQUIRED=1 bash hooks/test-stride-hook.sh
```

The gate matches `hooks/*.ps1` and **does not recurse**, matching the scope it
documents. If a `.ps1` ever lands in a subdirectory it is not scanned, so the
gate names it in a `warn:` line rather than passing clean over an unexamined
tree.

#### What this gate cannot see

A clean run means exactly this: no PowerShell 7-only **syntax**, and no cmdlet
**name** the 5.1 profile knows to be 7-only. It is not evidence that the hook
*runs* on 5.1 — runtime verification on a real Windows host is a separate job.
The gaps below were each confirmed by execution, not assumed:

- **7-only parameters on cmdlets that exist in 5.1 are invisible to _this
  gate_, and still are.** `ForEach-Object -Parallel`,
  `Get-Content -AsByteStream` and `ConvertFrom-Json -AsHashtable` all pass
  silently: the cmdlet rule checks that a cmdlet *name* resolves, never which
  parameters it accepts. Nothing below changes that — the coverage that closed
  **D277** lives in the ps1 suite, not here.
  This repo *had* **two live instances** (W2106):
  `Invoke-WebRequest -SkipHttpErrorCheck` at both call sites — the
  `changed_files` PUT, which therefore never issued on 5.1, and the after_goal
  detection call, which sits under a `catch { return }` and so degraded D119
  detection to a silent no-op on every 5.1 run. **Both are removed as of
  D277**; the surviving mentions in `hooks/stride-hook.ps1` are comments
  recording why the parameter is not used. Line numbers are deliberately not
  cited here — the two this entry used to name had already drifted by the time
  D277 was worked, which is its own small lesson about pinning a defect to a
  line in prose.
  They were found by reading, not by this gate. What replaces the reading is
  **Test Group 30 in `hooks/test-stride-hook.ps1`**: an AST walk over
  `hooks/*.ps1` and `scripts/*.ps1` that checks each command's named parameters
  against a per-cmdlet denylist of 7-only ones. It is **abbreviation-aware** (so
  `-SkipHttpError` is caught too) and **alias-aware** (`iwr -SkipHttpErrorCheck`
  resolves to `Invoke-WebRequest` before the lookup — without that it passed
  clean, which is what D277's review found). It also catches the positional form
  of the same class: a 3-argument `Join-Path`, which silently binds the 7-only
  `-AdditionalChildPath`. It carries a planted-violation case, exercised through
  the same function the real assertions use, so a scan that silently stopped
  matching fails rather than passing clean.
  A denylist is **incomplete by construction** — it catches what someone has
  learned to list. That is strictly more than the name-only gate sees, and
  strictly less than "every 7-only parameter".
  **It is suite coverage, not a gate**, so it runs with the ps1 suite and not
  with `check-ps1-compat.sh`; extending the denylist is how a newly-learned
  parameter gets pinned.
- **The .NET API surface is invisible.** A 3-argument
  `[System.IO.File]::Move(src, dst, overwrite)` — an overload .NET Framework
  does not have — is flagged by neither rule. Related and more important:
  `Move-Item -Force` at `hooks/stride-hook.ps1:57` and `:154` is a *behaviour*
  divergence, because 5.1 implements `-Force` as delete-then-move; the
  consequence is written up at `hooks/stride-hook.ps1:40-46`. No static rule
  can see it, so it is recorded here as a gap and **not** as a suppressed
  finding — a suppression would falsely imply the analyzer had flagged it.
- **`Set-StrictMode -Version Latest`** (`hooks/stride-hook.ps1:14`,
  `hooks/stride-skill-gate.ps1:17`) is valid on both hosts, but `Latest`
  resolves to a different strictness on each. Not flagged, by design.
- **The syntax rule covers five constructs, not "7-only syntax" in general.**
  An exploratory pass over ~40 constructs found it detects `? :`, `??`, `??=`,
  `&&`/`||` pipeline chains, and `${x}?.Member` — and misses `${x}?[0]` (the
  null-conditional *index*, introduced in the same release as the member form
  it does catch), `clean{}` blocks, the background operator `&`, the 7.0
  numeric literal suffixes (`100u`, `1n`, `1.5d`, `16l`, `5s`, `3y`), and the
  `` `e `` / `` `u{} `` escape sequences. The escapes are the nastiest shape:
  on 5.1 they are not errors at all, the backtick is simply dropped and the
  script emits the literal text.
- **The cmdlet profile's coverage is arbitrary within a single family.** Of
  twelve genuinely 7-only cmdlets tested it flagged five and missed
  `Get-Error`, `Join-String`, `Start-ThreadJob`, `Enable-ExperimentalFeature`,
  `Debug-Runspace`, `Get-PSSubsystem` and `Switch-Process` — flagging
  `Get-ExperimentalFeature` while missing `Enable-ExperimentalFeature`. It is
  a name-membership test, so a *misspelled* cmdlet is equally invisible.
- **7-only automatic variables and the whole .NET surface are invisible**, and
  this is the class most likely to bite: `$IsWindows` / `$IsLinux` / `$IsMacOS`
  / `$IsCoreCLR`, `$PSStyle`, `$PSNativeCommandUseErrorActionPreference`,
  7-only types such as `[System.Half]` and `System.Text.Json`, and
  .NET-Core-only method overloads. None produces a syntax or unknown-cmdlet
  error — just different behaviour, or a runtime throw, on the user's machine.
- **The profile is one specific 5.1 build** (`5.1.14393.206`, Windows Server
  2016 era). Other 5.1 builds may differ at the margins.

**Nesting does not hide anything, and neither do encodings** — both were
tested. A `? :` inside a string interpolation, a here-string or a scriptblock
parameter default is still flagged, as is `&&` inside a scriptblock; and BOMs,
CRLF, latin-1 and a missing trailing newline all analyze correctly. A file
whose bytes do not decode as script text is reported as a gate error rather
than as clean, so "no findings" never stands in for "never analyzed".

What it does catch, also verified by execution: `? :`, `??`, `??=`,
`&&`/`||` pipeline chains and `${x}?.Member` (syntax); and profile-known
7-only cmdlets such as `Get-Uptime`, `Test-Json`, `ConvertFrom-Markdown`,
`Show-Markdown`, `Remove-Service` and `Remove-Alias`.

### The cross-port canon drift check

`scripts/check-port-canon.sh` and `scripts/check-port-canon.ps1` compare every
port repo and vendored catalog copy against the rules registered in
`docs/port-canon.md`, reporting per rule and per port whether the port's anchor
is present, stale, unexpected, or missing.

The two halves are **independent implementations**, not a script and its
transliteration: the bash half tokenises the canon's json with `awk`, the
PowerShell half builds an object graph with `ConvertFrom-Json`. That is
deliberate — two readings of one document that reach the same verdict are worth
more than one reading run twice — and the suites hold them to it (below).

**The FLEET SCAN is still a release-time step that nothing runs for you.** Its
correct result today is exit 1, because the fleet has not adopted the anchor
contract yet, so it cannot be a pass/fail suite group without installing a
permanently-red one. **The SELF-TEST is different and is now gated**: both
halves run as bash Test Group 30 and PowerShell Test Group 32, and those groups
also cross-verify the two halves against each other.

```
bash scripts/check-port-canon.sh                 # scan the fleet against the canon
pwsh scripts/check-port-canon.ps1                # the same scan, the other half
bash scripts/check-port-canon.sh --self-test     # prove the gate still detects drift
pwsh scripts/check-port-canon.ps1 -SelfTest      # the other half's own suite
```

The two suites cover the same cases apart from the sanctioned asymmetries
described below, and `hooks/test-stride-hook.sh` Group
**30c** (with its PowerShell mirror, Group 32c) is what holds them to it: each
compares the two halves' case-name SETS, which catches a case renamed or lost on
one side — something neither half's own tally can see, since each stays
internally consistent while disagreeing with the other. The two tallies are not
expected to be equal; what must be equal is the set of names left after the
sanctioned asymmetries are filtered out. Reproduce with the normalization 30c
itself uses:

```
diff <(bash scripts/check-port-canon.sh --self-test | grep '^ok: ' | sed 's/ \[skipped on this host:.*\]$//' | grep -Ev '^ok: \[(ps1|bash)-only\]' | sort) \
     <(pwsh -NoProfile -File scripts/check-port-canon.ps1 -SelfTest | grep '^ok: ' | sed 's/ \[skipped on this host:.*\]$//' | grep -Ev '^ok: \[(ps1|bash)-only\]' | sort)
```

**Three sanctioned asymmetries, and what each one claims.** A ` [skipped on this
host: …]` suffix means the case exists on both sides but could not run here. A
`[ps1-only]` or `[bash-only]` prefix means the HAZARD does not exist in the other
half at all — not that porting the case was inconvenient. The live example is the
grep-stub pair, marked `[bash-only]`: it pins the behaviour of a grep the bash
half shells out to, and the PowerShell half invokes no grep anywhere. A case
testing an outcome BOTH halves owe is ported instead, which is what happened to
the locale pair. Marking a case that the other half could have run would turn
these groups into the false green they exist to prevent.

Exit codes: `0` every applicable cell reports ok, `1` at least one cell reports
MISSING, STALE, UNEXPECTED, DEFECT or UNVERIFIABLE and the drift is listed
above, `2` no verdict was possible — the canon is absent, unparseable, carries
an unknown schema version, has a bad registry dir, or the command line was
wrong. Under `--self-test` the same codes mean all cases passed, at least one
failed, and the temp dir or the flag combination was wrong.

**Treat `2` as red, not as silence.** It does not mean a missing machine
dependency the way it does in `check-ps1-compat.sh` — the bash half shells out
to nothing but `awk` and `grep`, and the PowerShell half's `ConvertFrom-Json`
ships inside every PowerShell that could run it at all. Neither half has a
machine-fault tier, so in both a `2` means the run proved nothing, and its lack
of findings is not a pass.

**Fix a red result by placing the anchor, never by editing the canon.** A
MISSING cell means the port does not carry the rule's marker beside its own
statement of the rule; the remedy is to add the anchor there, or to write the
rule in that port's own words first where the substance is genuinely absent.
Editing an `applies_to` row in `docs/port-canon.md` to make a cell green
records that the port does not owe a rule it does owe, which turns the gate
into a report of its own configuration. Where a port truly should not owe a
rule, that is a change to the canon made deliberately and on its own terms,
not a way to clear a red line during a release.

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
