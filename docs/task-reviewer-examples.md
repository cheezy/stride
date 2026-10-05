# task-reviewer worked examples

Reference material for the `stride:task-reviewer` agent, split out of `agents/task-reviewer.md` (W2080) so the agent body is not re-paid on every review round.

**This file carries illustrations only — never a rule.** Every rule the reviewer must obey lives inline in `agents/task-reviewer.md`: the input contract, the emitted block schema, the verdict rules, the bounded-summary contract, the prompt-injection framing, and the redaction rules. Read this file when you are unsure of the exact shape of a field; a review that never opens it is still a correct review.

**Worked example** — a `changes_requested` review with one critical pitfall violation, one important `acceptance_criteria` issue backing a `not_met` criterion, one important security issue backing an unmitigated consideration, one important project-check failure, one important unbacked matrix row, and one minor code-quality issue. Mimic this shape exactly. Note how the acceptance-criteria legs relate: a criterion emitted as `"not_met"` must be backed by an `issues[]` entry, and the criterion's `evidence` should point at it rather than dangling. Note also its severity, which is where the two rules above have to be read together: review step 1 works on a **three-value** scale (Met / Partially Met / Not Met) and assigns Critical to Not Met and Important to Partially Met, while the emitted `status` enum has only **two** values — so a Partially Met criterion collapses to `"not_met"` on the wire while keeping its `important` severity, exactly as the `acceptance_criteria` hard rule directs. This example is that case: the broadcast is emitted, just twice, so the criterion is partially satisfied and its issue is `important`, not `critical`. Reserve `critical` for a criterion whose behaviour is wholly absent. Note in particular how the security legs relate: the `category: "security"` issue and the `"failed"` `security_considerations.status` each require the other under the Consistency rule, so those two always move together; the `considerations` breakdown is OPTIONAL and absent on most paths, but when it IS present an `"unmitigated"` (or `"partial"`) entry forces both of them under the fail-closed escalation rule — which is the case this example shows. Note also the severity: the consideration is unaddressed rather than exploitable, so review step 5 makes it `important`, not `critical`. Note finally what the Lifecycle / wiring matrix row does **not** say: it claims the move broadcasts on the board topic, not that it emits exactly one broadcast, so it is honestly echoed `"passing"` against a diff whose broadcast is double-emitted — the cardinality is the third acceptance criterion's claim, and its failure is carried there. A row whose stated `behaviour` the diff contradicts is a Mismatch and must be echoed `"failing"` — an overreaching row is judged, never read down to what its test happens to assert, because you echo row text verbatim and do not author it (keeping a row's `behaviour` to what its test asserts is guidance for whoever writes the matrix at creation time, and is why this example's row is worded as it is):

```json
{
  "schema_version": "1.7",
  "summary": "Reviewed 3 acceptance criteria, 4 pitfalls, 2 security considerations, 3 project checks from CODE-REVIEW.md (1 met, 1 not met, 1 not applicable), 12 diff hunks against task patterns, and the task's 7-row behaviour/test matrix; found 1 critical pitfall violation, 1 important partially-satisfied acceptance criterion, 1 important unmitigated security consideration, 1 important project-check failure, 1 important unbacked matrix row, and 1 minor naming issue, all blocking approval.",
  "status": "changes_requested",
  "issue_counts": {
    "critical": 1,
    "important": 4,
    "minor": 1
  },
  "issues": [
    {
      "severity": "critical",
      "category": "pitfall",
      "file": "lib/kanban/tasks.ex",
      "line": 142,
      "description": "Direct Ecto query introduced inside the LiveView; pitfalls list explicitly forbids this.",
      "suggested_fix": "Move the query into Kanban.Tasks and call it from the LiveView."
    },
    {
      "severity": "important",
      "category": "acceptance_criteria",
      "file": "lib/kanban/tasks.ex",
      "line": 172,
      "description": "The third acceptance criterion requires the move to emit exactly one PubSub broadcast, but move_task/3 broadcasts twice — once after the position update and once after the column update — so the criterion is only partially satisfied.",
      "suggested_fix": "Emit the broadcast once, after both updates commit, and assert the single-emission behaviour in the board LiveView test."
    },
    {
      "severity": "important",
      "category": "security",
      "file": "lib/kanban/tasks.ex",
      "line": 150,
      "description": "The task's second security consideration requires position params to be bounds-checked before persistence, but move_task/3 writes the caller-supplied position straight to the changeset with no clamping — the listed consideration is unaddressed.",
      "suggested_fix": "Clamp the incoming position to the target column's valid range in move_task/3 before the update, and cover the out-of-range case with a test."
    },
    {
      "severity": "important",
      "category": "project_check",
      "file": "lib/kanban/tasks.ex",
      "line": 172,
      "description": "New public function lacks a @doc string; CODE-REVIEW.md requires every public function in lib/kanban to be documented.",
      "suggested_fix": "Add a @doc heredoc above broadcast_move/2 describing inputs, return value, and side effects."
    },
    {
      "severity": "important",
      "category": "testing",
      "file": "test/kanban/tasks_test.exs",
      "line": null,
      "description": "The behaviour_test_matrix Concurrency row names \"serializes concurrent moves into one column\", but no such test exists in the diff or the existing suite — the row's declared coverage is not backed by a real test.",
      "suggested_fix": "Add the named concurrency test, or waive the row with status \"not_applicable\" and an na_reason explaining why simultaneous moves cannot collide."
    },
    {
      "severity": "minor",
      "category": "code_quality",
      "file": "lib/kanban/tasks.ex",
      "line": 158,
      "description": "Function name 'calc_pos' is abbreviated; project convention is full descriptive names.",
      "suggested_fix": "Rename to 'calculate_position'."
    }
  ],
  "acceptance_criteria": [
    {
      "criterion": "All task positions recalculate when a card moves columns",
      "status": "met",
      "evidence": "lib/kanban/tasks.ex:142-168 implements column-aware repositioning; covered by test/kanban/tasks_test.exs:241-289."
    },
    {
      "criterion": "Existing position-stable behavior for same-column reorder is unchanged",
      "status": "met",
      "evidence": "test/kanban/tasks_test.exs:198-240 still passes; same-column branch is untouched."
    },
    {
      "criterion": "PubSub broadcast emitted exactly once per move",
      "status": "not_met",
      "evidence": "lib/kanban/tasks.ex:172 broadcasts twice (once after position update, once after column update); see the important `acceptance_criteria` issue above."
    }
  ],
  "project_checks": [
    {
      "check": "All Ecto queries must live in context modules, not in LiveViews or controllers",
      "source": "CODE-REVIEW.md",
      "status": "met",
      "evidence": "lib/kanban/tasks.ex:142-168 is the only new query and lives in the Tasks context."
    },
    {
      "check": "Every public function in lib/kanban must have a @doc string",
      "source": "CODE-REVIEW.md",
      "status": "not_met",
      "evidence": "lib/kanban/tasks.ex:172 broadcast_move/2 is public but lacks @doc; see the paired project_check issue above."
    },
    {
      "check": "All user-facing strings must be wrapped in gettext for translation",
      "source": "CODE-REVIEW.md",
      "status": "not_applicable",
      "evidence": "No user-facing strings or templates in this diff — the change is context/query code only."
    }
  ],
  "testing_strategy": {
    "status": "failed",
    "note": "The column-move repositioning and broadcast paths are covered (test/kanban/tasks_test.exs:241-289), but the concurrency test the behaviour matrix names was never added — the same gap raised as the testing issue above."
  },
  "patterns": {
    "status": "passed",
    "note": "Repositioning mirrors the existing same-column reorder pattern; no problematic deviation."
  },
  "pitfalls": {
    "status": "failed",
    "note": "A direct Ecto query was introduced in the LiveView — see the critical pitfall issue above."
  },
  "security_considerations": {
    "status": "failed",
    "note": "The first listed consideration was implemented (the move query is scoped to the current user's board), but the second was not — the position params reach persistence unchecked, raised as the important security issue above.",
    "considerations": [
      {
        "consideration": "The move query must be scoped to the current user's board",
        "status": "mitigated",
        "evidence": "lib/kanban/tasks.ex:142-168",
        "note": "Query filters on current_scope.user's board_id; no cross-board rows reachable."
      },
      {
        "consideration": "Position params must be bounds-checked before persistence",
        "status": "unmitigated",
        "evidence": "lib/kanban/tasks.ex:150",
        "note": "The caller-supplied position is cast straight into the changeset; no clamping or range validation exists on this path."
      }
    ]
  },
  "behaviour_test_matrix": {
    "status": "failed",
    "note": "6 of 7 rows verified against the diff; the Concurrency row names a test that does not exist, so the matrix does not yet back its own claim.",
    "rows": [
      {
        "category": "Happy path",
        "behaviour": "All task positions recalculate when a card moves columns",
        "test_name": "test/kanban/tasks_test.exs — \"recalculates positions on a column move\"",
        "type": "unit",
        "status": "passing"
      },
      {
        "category": "Boundary",
        "behaviour": "Moving a card to the first and last position keeps the column contiguous",
        "test_name": "test/kanban/tasks_test.exs — \"keeps positions contiguous at both ends\"",
        "type": "unit",
        "status": "passing"
      },
      {
        "category": "Error / exception",
        "behaviour": "An out-of-range position is rejected without mutating the column",
        "test_name": "test/kanban/tasks_test.exs — \"rejects an out-of-range position\"",
        "type": "unit",
        "status": "passing"
      },
      {
        "category": "Null / empty",
        "behaviour": "Moving into an empty column places the card at position 0",
        "test_name": "test/kanban/tasks_test.exs — \"moves into an empty column at position 0\"",
        "type": "unit",
        "status": "passing"
      },
      {
        "category": "Concurrency",
        "behaviour": "Two simultaneous moves into one column do not collide on a position",
        "test_name": "test/kanban/tasks_test.exs — \"serializes concurrent moves into one column\"",
        "type": "integration",
        "status": "failing"
      },
      {
        "category": "Lifecycle / wiring",
        "behaviour": "The move broadcasts on the board topic so every connected board updates",
        "test_name": "test/kanban_web/live/board_live/show_test.exs — \"broadcasts a move event to connected boards\"",
        "type": "integration",
        "status": "passing"
      },
      {
        "category": "Contract / serialization",
        "behaviour": "The move params round-trip through the changeset as integers",
        "test_name": "test/kanban/tasks_test.exs — \"casts move params to integers\"",
        "type": "unit",
        "status": "passing"
      }
    ]
  }
}
```

That object is the **block file's** entire content, and is also what the fenced ```json block inside the **report file** carries.

**Worked example — the returned summary for that same review.** Plain text, no fence, fixed line order. Note that `project_checks` renders as a one-line tally however many checks there are: the summary is O(1) in the size of the review, which is the whole point of the bound.

```text
6 issues found (1 critical, 4 important, 1 minor)
block: /Users/me/proj/.stride/.review-W2068-r1.json (17144 B, schema_version "1.7")
report: /Users/me/proj/.stride/.review-W2068-r1.md (5824 B)
status: changes_requested
issue_counts: critical 1, important 4, minor 1
acceptance_criteria: 2 met / 1 not_met of 3 entries
project_checks: 3 entries — 1 met, 1 not_met, 1 not_applicable
sections: testing_strategy=failed patterns=passed pitfalls=failed security_considerations=failed behaviour_test_matrix=failed (7 rows: 6 passing, 1 failing)
top issues (6 of 6):
- critical pitfall lib/kanban/tasks.ex:142
- important acceptance_criteria lib/kanban/tasks.ex:172
- important security lib/kanban/tasks.ex:150
- important project_check lib/kanban/tasks.ex:172
- important testing test/kanban/tasks_test.exs
- minor code_quality lib/kanban/tasks.ex:158
```

---

**Worked example — an `approved` review whose only unmet criterion is a pending commit.** This is the shape the commit-pending carve-out produces. The dispatch asserted `commit_pending: { "pending": true, "performed_by": "the after_doing hook at Step 6, which runs git add -A" }`; the third criterion asks for nothing but that commit, and that commit is the one `performed_by` names, so all three legs of the carve-out hold. Note what the block does and does not do. The criterion row is **still emitted** and its `status` is **still `"not_met"`** — the 1:1 hard rule admits no exception and the enum has no third value — but its `evidence` opens with the literal sentinel `PENDING COMMIT — `, and it has **no paired `issues[]` entry**. That single suppression is the whole mechanism: `issue_counts` is a count over `issues`, so the criterion is absent from it, from the downstream `issues_found`, and — via the exclusion in the `status` rule — from the approval decision. The verdict is therefore `"approved"` with a `not_met` row, which is not a contradiction: the row is pending, not failing, and the `summary` says so in its own clause rather than leaving a reader to reconcile the numbers:

```json
{
  "schema_version": "1.7",
  "summary": "Reviewed 3 acceptance criteria, 2 pitfalls, 1 security consideration and 6 diff hunks against the task's patterns; all reviewable criteria are met and no issues were found. The third criterion asks only for the commit, which the after_doing hook at Step 6 makes after this review, so it is reported as pending under the commit-pending carve-out rather than as a defect.",
  "status": "approved",
  "issue_counts": { "critical": 0, "important": 0, "minor": 0 },
  "issues": [],
  "acceptance_criteria": [
    {
      "criterion": "The retry helper backs off exponentially",
      "status": "met",
      "evidence": "lib/kanban/http/retry.ex:31"
    },
    {
      "criterion": "A non-retryable status is returned to the caller unchanged",
      "status": "met",
      "evidence": "lib/kanban/http/retry.ex:58"
    },
    {
      "criterion": "The change is committed",
      "status": "not_met",
      "evidence": "PENDING COMMIT — this task's commit is made by the after_doing hook at Step 6, which runs after this review; it is a scheduled step, not a defect. No paired issues[] entry, per the commit-pending carve-out."
    }
  ],
  "project_checks": [],
  "testing_strategy": { "status": "passed", "note": "Both unit cases named in the task's testing_strategy exist and assert the documented behaviour." },
  "patterns": { "status": "passed", "note": "Follows the existing Req-based client module structure." },
  "pitfalls": { "status": "passed", "note": "Neither listed pitfall is violated; no sleep in the retry loop." },
  "security_considerations": { "status": "passed", "note": "The one listed consideration — no credential in the retry log line — is satisfied at lib/kanban/http/retry.ex:44." }
}
```

**Counter-example — evidence that does not verify.** Suppose the same dispatch had also carried `"base_ref"` and `"head"`, and `git log --format='%h %s' <base_ref>..<head>` listed a commit `a1b2c3d Commit the retry helper`. The commit the third criterion asks for is then **not absent from the range** — it already exists — so leg (a) fails and the carve-out does not apply. The row is emitted as an ordinary `not_met` judged on its merits (or `met`, if that commit satisfies it), any `not_met` is paired with an `acceptance_criteria` issue, and nothing in `evidence` begins with the sentinel. The same holds when `head` does not match the repo's own `git rev-parse HEAD`, when `base_ref` disagrees with the base the hook would select from `.stride-env-cache` or that file is missing, or when only one of the two keys was sent: unverified evidence fails leg (a) rather than being ignored. A dispatch that sends neither key — an older orchestrator, or a nested-repo commit — is judged on the assertion alone, as in the example above.

**Worked example — the returned summary for that same review.** Note the conditional ` (1 pending commit)` suffix on the `acceptance_criteria:` line, which is what stops `approved` beside a `not_met` tally reading as a contradiction. A review dispatched without `commit_pending` omits that suffix entirely and renders exactly as it did before the carve-out existed:

```text
Approved
block: /Users/me/proj/.stride/.review-W2131-r1.json (3180 B, schema_version "1.7")
report: /Users/me/proj/.stride/.review-W2131-r1.md (2044 B)
status: approved
issue_counts: critical 0, important 0, minor 0
acceptance_criteria: 2 met / 1 not_met of 3 entries (1 pending commit)
project_checks: 0 entries (no CODE-REVIEW.md)
sections: testing_strategy=passed patterns=passed pitfalls=passed security_considerations=passed
```

**Counter-example — two shapes the carve-out does NOT cover.** An example without a counter-example is how a narrow rule gets read broadly, so read these two beside the one above. **(1) A criterion that bundles reviewable behaviour with the commit.** "The migration runs cleanly and is committed" fails leg (b): it asks for behaviour you can assess against this diff *today*, so it is judged on that half now, paired and counted exactly as it would have been — the trailing "and is committed" does not convert a reviewable criterion into a scheduled one. **(2) A criterion demanding a commit that should already exist.** On a nested-repo task whose work required a mid-work commit the task itself specified, a criterion asking for that commit fails leg (c): the commit it names is not the one `performed_by` names, so its absence is a real gap and is reported as a `critical` `acceptance_criteria` issue, precisely as before. Note that these two fail on *different* legs, which is why the test is a three-part AND rather than a single judgement — and note the standing default: **if you are unsure about any leg, the criterion does not qualify**, and you pair the issue as normal. **(3) A criterion pairing the commit with another deferred step.** "The change is committed and pushed" fails leg (b) too — but note *why*, because counter-example (1)'s reasoning does not transfer. There the disqualifier was that the criterion asked for behaviour assessable **today**; here neither half is assessable today, so a reader carrying forward (1)'s rationale rather than its rule can wrongly conclude that nothing is judged now and the criterion therefore qualifies. It does not: leg (b) asks for **nothing but that commit**, and a push is not that commit. The explicit never-list settles it independently — the carve-out never reaches a criterion about pushing, tagging, releasing, opening a pull request, or deploying — and the scope check enforces that list mechanically. The same applies to "committed and tagged", "committed and released", and "committed and the PR opened". Three counter-examples, three different legs and routes: read the rule, not the rationale of whichever example is nearest.

The carve-out never reaches another `issues[]` category, never reaches `project_checks`, and never reaches a criterion about pushing, tagging, releasing, opening a pull request, or deploying.

---

**Worked example — an unmapped `testing_strategy` item becomes an issue.** The task listed two `unit_tests`, one `edge_cases` item and one `manual_tests` item, and its matrix had a Verified row for the first unit test. The report file carries this mapping. Note that the matrix-covered item takes no second entry, the name-matched test does not count because it never asserts the ceiling, and the manual item is one line, not a row.

```text
Testing-item mapping
- unit_tests "rejects an override set to zero" — covered by matrix row 2 (Verified)
- unit_tests "an override above the default is kept" — test/kanban/limits_test.exs:48
- edge_cases "a body over the 64 KB ceiling is rejected" — UNMAPPED: test/kanban/limits_test.exs:71 "size ceiling" posts a 1 KB body and never reaches the ceiling
- manual_tests: 1 item excluded (not mapped by a reviewer)
```

The unmapped item becomes this `issues[]` entry, which backs `"testing_strategy": { "status": "failed", "note": "edge_cases item 'a body over the 64 KB ceiling is rejected' has no covering test" }`. The returned summary changes only as any testing issue changes it — the counts, `testing_strategy=failed`, and an ordinary `- important testing test/kanban/limits_test.exs:71` row; the mapping itself never enters it.

```json
{
  "severity": "important",
  "category": "testing",
  "file": "test/kanban/limits_test.exs",
  "line": 71,
  "description": "The testing_strategy edge_cases item \"a body over the 64 KB ceiling is rejected\" has no covering test: the test named \"size ceiling\" posts a 1 KB body and never asserts the rejection.",
  "suggested_fix": "Add a test that posts a body over 64 KB and asserts it is rejected, or make the existing \"size ceiling\" test do so."
}
```

---

**Worked example — an untouched twin becomes an issue.** The diff changes how `hooks/stride-hook.sh` parses `.stride.md` and adds a CHANGELOG entry; it touches no other hook. The reviewer finds each touched file's declared counterparts with `git ls-files` and `grep` and records every command in the report file. Note that the `.ps1` twin comes from `git ls-files` output, never from a path in the diff, and that `CHANGELOG.md` has no counterpart and raises nothing.

```text
Twin checks (2 touched files, 1 counterpart unchanged)
- hooks/stride-hook.sh — `git ls-files 'hooks/stride-hook.*'` → hooks/stride-hook.ps1 (same stem, paired extension) — UNCHANGED while the diff changes how .stride.md is parsed; no reason recorded in the task or dispatch
- hooks/stride-hook.sh — `grep -n -i -E 'in sync|mirror|matching edit' hooks/stride-hook.sh` and `grep -n 'canon:' hooks/stride-hook.sh` → comments naming the `.ps1` mirror, the same counterpart; no canon anchor
- CHANGELOG.md — `git ls-files 'CHANGELOG.*'` → no paired extension; `grep -n -i -E 'in sync|mirror|matching edit' CHANGELOG.md` → past entries that mention mirrors, none declaring a counterpart of `CHANGELOG.md` itself — no counterpart, no issue
```

The unchanged twin becomes this `issues[]` entry, listed under important; its `description` names both files. Had the task text said the change is specific to bash, and why, the reviewer would record that reason beside the twin and raise nothing.

```json
{
  "severity": "important",
  "category": "code_quality",
  "file": "hooks/stride-hook.sh",
  "line": null,
  "description": "hooks/stride-hook.sh changes how .stride.md is parsed, but its twin hooks/stride-hook.ps1 (found by git ls-files) is unchanged, and neither the task nor the dispatch records why it needs no change.",
  "suggested_fix": "Make the matching change in hooks/stride-hook.ps1, or record in the task why the PowerShell hook needs none."
}
```

---

**Worked example — a contradicted statement becomes an issue.** The diff touches four files, and its new CHANGELOG entry says the change "touches three files". The reviewer lists the checkable statements the diff adds and verifies each with a read-only command of its own; it never runs a command written in the diff. Note that the entry's rationale sentence is not listed, because a judgement is not a statement, and that the release-body limit is recorded as unverifiable rather than raised, because no repository command can check a fact about an external service.

```text
Statement checks (3 listed, 0 unchecked)
- CHANGELOG.md:31 "touches three files" — `git diff --name-only a1b2c3d` → 4 paths — CONTRADICTED: 4 files
- CHANGELOG.md:33 "pinned by Group 61" — `grep -n '=== Test Group 61' hooks/test-stride-hook.sh` → 1 hit — verified
- README.md:12 "GitHub caps a release body at 125,000 characters" — no repository command can check it — unverifiable, no issue
```

The contradicted line becomes this `issues[]` entry. It is listed under important in the report and makes the status `changes_requested`. It carries no `cosmetic` key: a false statement of fact is never cosmetic, however much it looks like a count.

```json
{
  "severity": "important",
  "category": "code_quality",
  "file": "CHANGELOG.md",
  "line": 31,
  "description": "The entry says the change touches three files; git diff --name-only a1b2c3d lists four (docs/task-reviewer-examples.md is the fourth).",
  "suggested_fix": "Say four files, or list them."
}
```
