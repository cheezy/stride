# stride-completing-tasks rationale

Rationale, provenance and history moved out of `skills/stride-completing-tasks/SKILL.md` (W2258) because that skill stays resident in the main loop's context once it is loaded. **This file carries no rule.** The Completion Request Field Reference, the Explorer/Reviewer Result Schema (both shapes and the five-value skip-reason enum), the mandatory pre-submission self-check list, the prompt-injection framing and the redaction rules all stay inline in the skill; each section below is reached from a pointer at the site it came from. Read it to learn why a rule is shaped as it is; a completion built without ever opening it is still correct. Where a section here and the skill disagree, the skill wins.

## Why the Verification Checklist Exists

*From `skills/stride-completing-tasks/SKILL.md` § BEFORE CALLING COMPLETE: Verification Checklist.*

Skipping these steps is not faster — it produces lower quality work that takes longer to fix. The checklist exists because agents consistently skipped these steps under pressure to deliver quickly.

The `project_checks` half of the whole-object copy rule has a visible symptom when it is broken: a missing or trimmed `project_checks` array leaves the Review queue's Code review panel silently empty, and the server contract now hard-rejects it.

## Why the Self-Check Repeats Server-Enforced Rules

*From `skills/stride-completing-tasks/SKILL.md` § MANDATORY pre-submission self-check, the failed-verdict note checkbox.*

The failed-verdict note checkbox mirrors the Verdict-note rule in `stride/agents/task-reviewer.md`. It was added to the completion self-check because that rule was previously policed only by the model that would emit the stub.

The Kanban server enforces the same rule too, unconditionally and in every mode (`Kanban.Tasks.CompletionValidation.ReviewContract`), so a stubbed note is a `422` rather than something the checklist alone catches. Reaching that 422 still costs a round trip, and the rejection names the offending section — which is why the self-check catches it first.

## Why Outcome 3 Escalates Instead of Submitting

*From `skills/stride-completing-tasks/SKILL.md` § MANDATORY pre-submission self-check, "Resolving a verdict/issue disagreement".*

Outcome 3 — a re-run that neither raises the finding nor explains its rejection — is the one branch of the self-check that ends in **escalation rather than submission**. The third exit in the self-check's preamble ends in submission because there the finding is already structurally present in `reviewer_result`, and the `completion_notes` record only adds to it. In outcome 3 the record would substitute for the finding, and the alternative to escalating is shipping structural silence about a real finding.

## Why the Self-Check Is Scoped to a Parsed Block

*From `skills/stride-completing-tasks/SKILL.md` § MANDATORY pre-submission self-check, the `behaviour_test_matrix` and nested `considerations[]` checkboxes.*

The `behaviour_test_matrix` checkbox carries the same scoping as the `not_assessed` checkbox, for the same reason: it applies to a payload where a reviewer ran and its block parsed, because only such a payload can carry a `behaviour_test_matrix` verdict at all. Source C is the case where neither the block file nor an inline fence yielded a parsable object.

The nested `considerations[]` checkbox is the third scoping case. The deep security-considerations sub-step's gate is *non-empty `security_considerations` plus plugin availability*, and it does **not** require the task-reviewer to have been dispatched — so on a Shape 2 self-reported skip or the Source C prose fallback, the specialist's verdicts come back with no copied object to merge them into. Fail-closed survives the scoping; only its carrier changes, which the skill still states inline.

## The Grace-Period Rollout

*From `skills/stride-completing-tasks/SKILL.md` § Explorer/Reviewer Result Schema › Grace-period rollout.*

Until the server flips `:strict_completion_validation` to true, a missing or invalid `explorer_result` / `reviewer_result` produces a structured warning log but the request succeeds. Agents that lag the rollout start getting 422 rejections on the flip day, which is why the skill says to emit both fields correctly now. Independently of that flag, a dispatched review's structured block is required unconditionally.
