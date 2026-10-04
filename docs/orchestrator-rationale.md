# stride-workflow orchestrator rationale

Rationale, provenance and history moved out of `skills/stride-workflow/SKILL.md` and `skills/stride-workflow/review-block-extraction.md` (W2257) so they are not re-paid on every request. **This file carries no rule.** Every gate, decision matrix, Decision Summary, schema, self-check, prompt-injection framing and redaction rule stays inline in those two files; each section below is reached from a pointer at the site it came from. Read it to learn why a rule is shaped as it is; a task run that never opens it is still correct. Where a section here and the skill disagree, the skill wins.

## Why the Orchestrator Exists

*From `skills/stride-workflow/SKILL.md` § Purpose.*

During a 17-task session, an agent consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. The root cause: too many disconnected skills that the agent had to remember to invoke at specific moments. Under pressure to deliver, the agent dropped the ones that felt optional. This orchestrator eliminates that failure mode.

## Former Inline Plan and Review Triggers

*From `skills/stride-workflow/SKILL.md` § Step 3 Branch C and § Step 5.*

Two bullets in SKILL.md once stated their own trigger beside the decision matrix, and both were removed for the same reason (D221: the matrix is the sole decision point).

**Step 3 Branch C, the Plan bullet.** This bullet previously stated its own trigger ("medium+ OR 3+ key_files OR 3+ acceptance criteria lines"), which could fire on a row whose `Plan` column said Skip — see SKILL.md § One signal the matrix deliberately does not act on.

**Step 5, the Review line.** This line previously restated its own trigger ("medium+ OR 2+ key_files"), which disagreed with the matrix for a `small` defect with 1 `key_file` — the same defect as D221, in the Review column instead of the Plan column.

## Step 5.6 Is Mirrored in stride-subagent-workflow

*From `skills/stride-workflow/SKILL.md` § Step 5.6.*

Step 5.6 is stated a second time, intentionally identical in substance, in `stride-subagent-workflow` **Phase 3.6** — **keep the two in sync; an edit in SKILL.md needs the matching edit there.** The step's procedure lives in `skills/stride-workflow/optional-hardening.md`, so that is the file an edit on this side actually lands in.

## Why Step 7 Deletes the Working Artifacts

*From `skills/stride-workflow/SKILL.md` § Step 7.*

The `.stride/` working artifacts — review blocks, reports, merged copies, explorer and plan reports, exploratory reports and the claimed task file — quote diff content, source or app responses verbatim; `<N>` increments every round, so without this a project accrues an unbounded on-disk corpus of excerpts. That matters most where the `.gitignore` mention in Step 0 went unheeded: a project whose `## after_doing` runs `git add -A` would otherwise sweep review blocks and exploration reports into a commit.

## Where the reason_code Vocabulary Came From

*From `skills/stride-workflow/SKILL.md` § Workflow Telemetry.*

The vocabulary was derived by classifying the skip reasons actually persisted on the production board, so every code names a skip that really happens.

## commit_pending Evidence — Nested Repos and Residuals

*From `skills/stride-workflow/review-block-extraction.md` § The `commit_pending` dispatch assertion.*

review-block-extraction.md says to omit `base_ref` and `head` on a nested-repo commit. Why: The project-root base ref is not a valid object in a nested plugin or vendored repo and no artifact records that repo's claim-time HEAD, so the only base you could offer is its current `HEAD`, which makes the range empty by construction and proves nothing; there the carve-out rests on the assertion alone, exactly as it did before this evidence existed.

**Two residuals are stated rather than hidden.** Omitting both keys on a project-root commit still reaches the assertion-only path, because a dispatch without evidence must behave exactly as before and the reviewer cannot tell that omission from a nested-repo one; and `.stride-env-cache` is a hook artifact, not a tamper-proof one — an agent that rewrites its `TASK_BASE_REF` line can still steer check (3). Both are narrower than the honour system they replace on the evidence path, and neither is closed here.

## Why the Scope Pin Runs Either Way

*From `skills/stride-workflow/review-block-extraction.md` § The `commit_pending` dispatch assertion.*

The assertion is self-certified wherever the `base_ref`/`head` evidence is absent — a nested-repo commit, or an orchestrator that predates it — because you are the party whose review round it unblocks, and without that evidence the reviewer has nothing independent of you about lifecycle order. Where the evidence is present it verifies that **no matching commit has been made since the claim** — narrower than "a commit really is still ahead": an overdue commit is equally absent from the range and still rests on leg (c), and a `performed_by` step that never commits (an empty `## after_doing`, say) goes undetected. The scope pin verifies *containment*, a different property, so it runs either way.

## Why the Round-Counter Loop Is Written This Way

*From `skills/stride-workflow/review-block-extraction.md` § Review rounds.*

**Three details in the round-counter loop are each load-bearing, and each was a defect before it was a line.** `jq -e 'type == "object"'` is the parsability test rather than `jq empty`, because **`jq empty` succeeds on a zero-byte, whitespace-only, or bare-`null` file** — exactly the shapes a reviewer killed mid-write leaves behind — and counting one of those as a round breaks the guarantee that a crashed dispatch burns a filename and not a round. The numeric `sort -n` is why the previous round is read correctly past nine dispatches. And both `case` guards use a **leading `(`** in the pattern so they parse inside a command substitution on bash 3.2, which ships as `/bin/bash` on macOS.

## Why CRITICAL_CLEARED Exists

*From `skills/stride-workflow/review-block-extraction.md` § Review rounds.*

Without `CRITICAL_CLEARED` the exemption is keyed on *who discovered* the Critical rather than on whether one existed: a Critical you find yourself, fix, and dispatch a round to verify comes back clean, so `PRIOR_CRITICAL` is `0`, the cap refuses the submission, and the task has no compliant exit at all — recording is forbidden for a `critical` and `review_blocked` requires one still *open*, while this one is fixed and verified.

## Why the Counter Is Cleared at Claim Time

*From `skills/stride-workflow/review-block-extraction.md` § Review rounds.*

The counter and its artifacts are scoped to **one attempt**, not to the checkout. Step 7 deletes them only after a successful completion, so every other exit — a failed `after_doing` gate, an interrupted session, an expired claim — leaves them behind, and the next attempt's *first* review round would be counted as round three and refused with `PRIOR_CRITICAL` of `0`, which is the most reachable way to strand a task that this cap has. Clear them on a successful claim, using the same anchored `$IDENT`; this mirrors how the hook executor clears `.stride/.hook-result-*.json` at claim time (D234).

## Why the Source A Merge Is a Whole-Object Overlay

*From `skills/stride-workflow/review-block-extraction.md` § Source A pattern.*

`$s[0] + {…}` **is** the whole-object copy: jq's object merge makes "copy everything, overlay exactly five keys" mechanical rather than remembered, which is the strongest available reading of the set relation stated in review-block-extraction.md § Field mapping. The `issue_counts` sum is spelled out per severity deliberately — `[.issue_counts[]] | add` would also sum unrecognized severity keys and contradict the mapping rule in that same section.

## What commit_pending_scope_ok Detects

*From `skills/stride-workflow/review-block-extraction.md` § Source A pattern.*

**Be exact about what this detects, because it is narrower than it looks.** It catches a **half-application** — a sentinel written without the matching suppression, or a suppression without the sentinel. It also stops a stray sentinel on a `met` row from cancelling a genuinely dropped pairing, though **it does not by itself report that stray sentinel**: the status filter removes such a row from every term, so a block whose *only* defect is a misplaced sentinel passes. **It does NOT catch mis-qualification.** A reviewer that wrongly decides a criterion qualifies and then applies the carve-out's *complete* documented shape moves the sentinel count up and the paired-issue count down by the same amount, so the equality still holds and the pin still returns `true`. That is one judgement error, not the two compensating errors the "wrong-but-balanced" caveat in review-block-extraction.md describes, and it is the failure mode the three-part AND — not this pin — exists to prevent. **Do not read a green pin as confirmation that the carve-out was correctly granted; it confirms only that whatever was granted was applied consistently.**

## Why Every round_cap_ok Term Is Type-Guarded

*From `skills/stride-workflow/review-block-extraction.md` § Source A pattern.*

**Every term is type-guarded, and that is not defensive padding.** jq's total ordering ranks strings, arrays and objects *above* all numbers, so a bare `$prior_critical > 0` returns **true** for `"0"`, `"abc"`, `[]` or `{}` — a reviewer emitting string-typed `issue_counts` would silently disable the cap entirely — and a bare `$round <= 2` returns **true** for `null`, because null sorts below every number. Both failures are *fail-open*: the cap stops binding and reads green. `(… | numbers) // <default>` coerces every non-number to the default, and the `$r >= 0` term turns a malformed round into a refusal rather than a pass, so malformed input now fails **closed** on both terms. The shell `:-` defaults matter for a different reason, and note `REVIEW_ROUND` defaults to **`-1`, not `0`**: an unset round means the round-counter recount did not run, which is a defect rather than a first round, so it fails closed and shows `round: -1` in `pin_terms` — the one value that says *run the recount, then re-check* rather than *you are past the cap*. `PRIOR_SECURITY` fails closed to `0` like `PRIOR_CRITICAL`. `FIX_CODE_PATHS` is the one deliberately permissive default — `-1`, *unmeasured*, which keeps round two available as it was before the triggers existed and never buys a third round; it is computed from git by you, never read from the reviewer's block, so the string-typed-input threat above does not reach it. The other reason is mechanical: `--argjson` parses its value before the program runs, so an *unset* variable aborts jq with exit 2 and emits nothing at all — taking `dropped_sections` and the four `commit_pending` booleans down with it, which is the same whole-invocation abort the `// []` and `// ""` guards elsewhere in review-block-extraction.md exist to prevent.

**The Source B half applies the identical coercion**, including excluding booleans from the numeric types — Python's `bool` is a subclass of `int`, so an unguarded `prior_critical > 0` would pass on `true` where the jq half refuses. The two halves must return the same verdict for the same inputs; which path an orchestrator lands on is decided by whether the reviewer's file write succeeded, which is an accident of I/O and must never change a verdict.

## Why round_cap_ok Reads the Previous Round

*From `skills/stride-workflow/review-block-extraction.md` § Source A pattern.*

`round_cap_ok` is the two-round cap's enforcement half, and it is here — in the Source A self-check — for the same reason the scope pin is: this self-check already runs once per round, so the pin is free rather than a new harness. It deliberately reads the **previous** round's Critical count rather than the current block's. That is the trap it avoids: a legitimate third round dispatched to clear a round-two Critical will usually come back with zero criticals, and a check reading the *current* block would refuse exactly the submission the exemption exists to permit.

## Why the Scope-Pin Lookups Are Total

*From `skills/stride-workflow/review-block-extraction.md` § Source A pattern.*

**Both lookups are total on purpose — `(.acceptance_criteria // [])` and `(.evidence // "")`.** The block is reviewer-authored JSON, and all four values are computed in one `jq -n`, so an unguarded `.acceptance_criteria[]` on an absent key (`Cannot iterate over null`) or an unguarded `.evidence` that is `null` on **any** row — including an unrelated `"met"` one — would abort the whole invocation and take `dropped_sections`, `project_checks_equal` and `acceptance_criteria_equal` down with it. That would make a previously-working check fail on blocks it used to handle, which is a worse outcome than the one this pin prevents. The guards convert those inputs into an honest `false` instead, which is the failure vocabulary this check actually documents.
