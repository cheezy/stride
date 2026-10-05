# task-reviewer rationale

Rationale, provenance and defect history moved out of `agents/task-reviewer.md` (W2258) because that file's body is the start of every request a dispatched reviewer makes. **This file carries no rule, and a review never needs it.** The block schema, the verdict and consistency rules, the bounded-summary contract and its line caps, the prompt-injection framing and every redaction rule stay inline in the agent file; each section below is reached from a pointer at the site it came from. It lives under `docs/` rather than beside the agent because every `.md` under `agents/` registers as an agent, and it is kept apart from `docs/task-reviewer-examples.md`, which the reviewer reads on demand and which stays illustrations-only. Where a section here and the agent file disagree, the agent file wins.

## schema_version Bump History

*From `agents/task-reviewer.md` — the schema-of-record note and the `schema_version` field.*

`schema_version` is bumped only when a change adds or removes a field. By that rule W2129 **did** bump it, `"1.6"` → `"1.7"`, because it added the `cosmetic` key to `issues[]` entries; the two changes before it held at `"1.6"` precisely because they added no field. The file-persistence contract in review step 8 moved the carrier and touched no field, so it did not bump the version. Neither did the commit-pending carve-out: it changes how existing fields are computed and adds no field.

Nothing gates on the value — the server validates `schema_version` as a semver-shaped string only.

## Why a Commit-Pending Criterion Is Not a Defect

*From `agents/task-reviewer.md` review step 1, "One exception, and only one — a commit-pending criterion".*

The review runs before the commit by design, so a criterion that asks for nothing but that commit would otherwise be raised as a Critical every time — a false positive the carve-out exists to remove. Reporting it as pending with no paired `issues[]` entry at any severity is exactly what the `acceptance_criteria` array hard rule specifies, and it is what the downstream scope-pin invariant (`commit_pending_scope_ok`) counts on: it reads the `PENDING COMMIT — ` sentinel as the only machine-readable trace of the carve-out.

**Why the evidence checks fail closed, and how the carve-out sits beside the pairing rules** (moved here from the agent by W2296). The claim hook records the local `HEAD` in `.stride-env-cache` at claim time, so the base it supplies is a hook artifact rather than dispatch input, though not proof against an agent that edits the file. A missing env file fails the check rather than skipping it: an orchestrator sending `base_ref` must have read it, and skipping would let a `base_ref` equal to `head` verify an empty range that proves nothing. The carve-out does not actually conflict with the step-5 rule that a real finding is always emitted: its premise is that a scheduled step is not a finding, so there is nothing produced to suppress, but both rules apply to one criterion, so neither may silently override the other. In the `status` rule, a commit-pending criterion contributes nothing because it names no defect: the carve-out suppresses its paired `issues[]` entry, so it reaches neither `issues` nor `issue_counts`, and the other two clauses of that rule are untouched by it.

## Section Verdict Rules — Provenance and Reach

*From `agents/task-reviewer.md` review step 5, the verdict rule for all four section tiles and "A real finding always outranks `not_assessed`".*

Reporting a task-supplied section as `not_assessed` is the exact D60 bug, where a task's `security_considerations` came back "not assessed".

The finding-outranks-`not_assessed` rule is stated for all four sections, but in practice the reachable instances today are `security` (review step 5 assesses its dimensions on every diff) and `testing` (a `failing` matrix row on a task with no `testing_strategy`). Review steps 2 and 3 remain scoped to what the task listed, so the `pitfall` and `pattern` instances only become reachable if those steps are ever broadened; the rule is stated for all four so it does not have to be rewritten if they are.

The credential carve-out in review step 4 is the **worked instance** of that rule, not a separate exception: a `category: "security"` issue raised for a credential-bearing matrix row flips `security_considerations` to `"failed"` on a task that supplied none, because a credential in the task's own matrix is a real security finding. Its trigger is unchanged and unwidened — it is simply no longer the *only* such case. (The agent file states this twice inline, in the redaction bullet and in the step-5 verdict bullet; the standalone paragraph that restated it a third time is what moved here.)

## Why an Unsupplied Path Means Inline Output

*From `agents/task-reviewer.md` review step 8, the `block file` artifact.*

A dispatch without `REVIEW_BLOCK_PATH` / `REVIEW_REPORT_PATH` is an older orchestrator that will never look for a file. Writing one anyway would leave it parsing a response with no fence, which lands it on a legacy-only payload that the completion API rejects with a `422` on a dispatched review. Deriving a default path therefore turns a working pairing into a broken one.

## Why the Review Is Split Across Two Files

*From `agents/task-reviewer.md` review step 8 (the `report file` and `write failure` artifacts) and § Output persistence.*

A full review response runs to tens of KB (measured: ~27 KB of response, ~17 KB of it the block alone), which burns main-loop context on every dispatch and risks harness truncation of the very field that must survive verbatim. The split follows the `.stride/` precedent already used for `.stride/.last-api-response.json` (D118) and `.stride/.hook-result-<hook>.json` (D234): write the full copy to a durable file, and let the consumer read it from there instead of from a truncatable stream.

The redaction rules are restated on the report file rather than left inherited from the block file because the prose issue list is the carrier that quotes diff content most often, the report file's bytes are spliced verbatim into `review_report` and rendered to humans, and like the block file it outlives the session.

The two carriers fail and recover independently because emitting only the block on a report-file failure would strip the issue list and both tables out of the `review_report` a human reads — the exact loss the report file exists to prevent.

## Why the Matrix Rows Have No Reverse-Direction Exception

*From `agents/task-reviewer.md` § `behaviour_test_matrix`, the escalation/consistency rule.*

The asymmetry with the `considerations` rule is deliberate and follows from what each array is. `considerations[]` breaks down *one* of the inputs the `security_considerations` verdict draws on, so that verdict can legitimately fail on something the array has no slot for. `rows[]` is the **complete** enumeration of everything the `behaviour_test_matrix` verdict draws on: the reviewer echoes the task's matrix row for row and never invents rows, so nothing a matrix failure can be about is not a row.

## How the Summary Line Caps Were Chosen

*From `agents/task-reviewer.md` review step 8, the canonical line formats.*

The conditional ` (<n> pending commit)` suffix on the `acceptance_criteria:` line is what stops an `approved` verdict beside a `not_met` tally reading as a contradiction — the row is pending, not failing — and it is why that line's cap is 80 rather than 60. The 20 characters were taken from the **`block:`** cap (200 → 180), not from `sections:`: both path lines were capped at 200 but render around 90 in practice, so `block:` had real headroom, whereas the `sections:` line's own reachable worst case — five verdicts spelled out, with a `behaviour_test_matrix` verdict and its row tally — measures up to 188 characters and would not fit 180. The per-line caps still sum to 2,000.

The per-line caps are how the 2,000-character bound is met by construction rather than by counting. The drop-rows rule handles too many rows; the per-row truncation handles one row that is too long, and together they make the bound hold by construction (moved here from the agent by W2295).

Naming an unread location in a security finding's `suggested_fix` is not exploring it, so the rule that raises such a finding leaves the review-only-the-changes-in-the-diff constraint intact (moved here from the agent by W2296).

## Observed Defects Behind Schema Rules

*From `agents/task-reviewer.md` § `acceptance_criteria` and § `pitfalls`.*

- **The 1:1 `acceptance_criteria` rule.** Re-enumerating the criteria list is exactly how a 5-criterion task produced a nonsensical `6/5` review display. The 1:1 correspondence is what keeps `acceptance_criteria_checked` consistent with the task's own count, and review step 1's three working labels (Met / Partially Met / Not Met) collapse onto the two wire values while the paired issue's severity carries the distinction the enum cannot (moved here from the agent by W2296).
- **The anti-placeholder Verdict-note rule.** The `pitfalls` section is the one the placeholder defect was observed on: `"note": "placeholder"` beside `"status": "failed"` on an otherwise-`approved` review.
- **No enumerated copy-list in a consumer.** An enumerated copy-list is exactly what silently dropped `project_checks` from the Review queue's Code review panel, which is why consumers splice the whole block (moved here from the agent's description by W2295).
- **One redaction sentinel.** The same fixed sentinel string is used in the matrix rows and the `considerations` breakdown, so a reader can find every redaction with a single search (moved here from the agent by W2295).
