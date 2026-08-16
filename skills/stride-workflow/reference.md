# Orchestrator Reference

Lookup material for the stride-workflow orchestrator, kept out of the hot path because running a task does not require reading it. It holds the Step Name Vocabulary for `workflow_steps`, the Edge Cases, the Complete Workflow Flowchart, the Platform Summary, the Failure Modes table, the Quick Reference Card, and the Step 3 Design Rationale. **Nothing here is authoritative:** the flowchart and the card summarise the procedure, they do not define it. Everything the workflow actually executes — every step, gate, Decision Summary, schema and self-check — stays in SKILL.md or the gated step file it names (the optional-*.md siblings), and nothing here is repeated there; where a summary here disagrees with SKILL.md or a step file, the step file wins. Read this when you want to look something up, not to find out what to do next. The two places SKILL.md sends you here mid-run — the `workflow_steps` schema note and its ordering rule — each name an inline answer first. **Granularity rule (D250):** the Quick Reference Card owes every gate, check, and stop condition the flowchart carries — compressed to one line each, never dropped. Dispositions that decide stop-versus-continue (the dispatcher statuses, the session endings, the hardening arms) count as stop conditions and are carried; purely recording dispositions, derivations, and telemetry mechanics sit below summary granularity in **both** renderings and live only in the step files, with two deliberate exceptions carried because their failure modes are safety-bearing: the deep-security fail-closed rule (malformed or absent verdicts never downgrade to passed), and — decided and recorded here per D252 — the curl stdout-preservation rule (every claim and complete curl pipes only into `tee`; `-o`, an appended `> /dev/null`, or any transformer pipe silently empties `changed_files` and can mark the base ref unproven, with no error anywhere — a failure mode hit live twice in the week this was decided, which is why it is classified as a summary-owed check rather than invocation mechanics). The Step 3 mis-labelling check (a `small` task carrying 3+ key_files or 3+ acceptance-criteria lines is recorded in `completion_notes` AND `completion_summary`, never a planner trigger) is explicitly ruled **below** summary granularity per D252: it is a purely recording disposition with no stop-versus-continue arm, so it lives in SKILL.md Step 3 alone and neither rendering carries it.

### Step Name Vocabulary

The `name` field must be one of these six values. Do not invent new names — consistency across plugins is the only reason telemetry can be aggregated.

| Step name | When to record it | Orchestrator step |
|---|---|---|
| `explorer` | Codebase exploration (Claude Code: `stride:task-explorer` agent; other: manual file reads) | Step 3 |
| `planner` | Implementation planning (Claude Code: `Plan` agent; other: manual outline) | Step 3 |
| `implementation` | Writing code | Step 4 |
| `reviewer` | Code review (Claude Code: `stride:task-reviewer` agent; other: self-review) | Step 5 |
| `after_doing` | The `after_doing` hook execution | Step 6 |
| `before_review` | The `before_review` hook execution | Step 6 |

## Edge Cases

### Hook failure mid-workflow
- All five hooks are blocking (`before_doing`, `after_doing`, `before_review`, `after_review`, `after_goal`) — a non-zero exit aborts the action each one gates
- Timing per the SKILL.md hooks table: `after_doing` fires BEFORE the completion curl and blocks it; `before_review` fires AFTER `/complete` succeeds — its failure is fixed and the hook re-run, never a reason to re-send `/complete`
- `before_doing` fires after the claim curl succeeds; when it fails, fix the issue and retry the claim curl (SKILL.md Step 2)
- Fix the root cause, re-run the hook, then proceed
- In Claude Code, dispatch `stride:hook-diagnostician` for complex failures
- Never skip a blocking hook or call complete with a failed hook result

### Claim failure (the Backlog claim-fail guard)
- A failed claim is a terminal stop, never a fallback to building outside the lifecycle
- Report why the task is not claimable (still in Backlog, already claimed, dependency-blocked) and end the turn
- Never implement a task whose claim did not succeed; promoting Backlog → Ready is a human action in the board UI (SKILL.md, "Backlog Claim-Fail Guard")

### Stale orchestrator marker
- The activation marker (`.stride/.orchestrator_active`) is stale 4 hours after its `started_at`; the PreToolUse gate treats stale as missing and may delete it on read
- If the gate blocks a sub-skill dispatch mid-task (a long task outliving its marker), re-write the marker per Step 0's Write Command and invoke again
- Clear the marker explicitly at every stop (Step 8) — never rely on the 4-hour expiry, which would leave a window where direct sub-skill invocations slip the gate

### Task that needs_review=true
- Stop after Step 7. Do not claim the next task.
- The human reviewer will handle the review cycle.
- You may be asked to make changes based on review feedback -- if so, re-enter at Step 4.

### Goal type tasks
- Goals are decomposed, not implemented directly
- The decomposer creates child tasks -- claim and work those individually
- Each child task follows this full workflow independently

### Skills update required
- If any API response includes `skills_update_required`, run `/plugin update stride` and retry

---

## Complete Workflow Flowchart

```
STEP 0: Prerequisites
  .stride_auth.md exists? --> NO --> Ask user
  .stride.md exists?      --> NO --> Ask user
  Write the activation marker (.stride/.orchestrator_active) -- mandatory; without it the
    gate blocks the workflow's own sub-skill dispatches
  Mention missing .gitignore entries -- UNCONDITIONAL for .stride/ and .stride_auth.md,
    plus .exploratory/ only when the exploratory plugin is installed; never edit
    their .gitignore yourself
  Exploratory plugin installed? --> collect the authorized/non-production affirmative HERE
    or never (asking between steps is illegal)
  |
  v
STEP 1: Task Discovery
  GET /api/tasks/next
  Review task details
  Needs enrichment? --> YES --> Invoke stride-enriching-tasks
  |
  v
STEP 1.5: Dispatcher Mode (Optional, Gated)
  No opt-in / non-Claude-Code? --> Skip; run Steps 2-8 inline (default)
  stride:task-runner agent unavailable? --> Skip inline AND record that isolation was
    unavailable, so "could not" is distinguishable from "never considered"
  Branch A task (goal / large undecomposed / 25+ hours)? --> Do NOT dispatch; run Steps 2-8 inline
  Step 3 matrix Isolate column says inline (small, 0-1 key_files)? --> Do NOT dispatch; run Steps 2-8 inline
  Otherwise: dispatch ONE stride:task-runner with the identifier only, read ONE record
    completed --> confirm via the projected read (fields=status,needs_review — degrade-safe:
      an older server ignores the projection and the full body still answers; a disagreement
                  or failed read = abandoned/unparseable_record, report and stop), then loop to Step 1
    completed_needs_review / claim_blocked / review_blocked / failed --> STOP and report
    hook_blocked --> re-dispatch once (attempt 2), then stop
    nothing / unparseable / budget expired --> write abandoned yourself; never re-dispatch, never clean up
  Steps 2-8 are unchanged -- the runner executes them in its own context
  Every stop (any non-completed disposition) --> clear the activation marker per Step 8
    before ending the turn
  |
  v
STEP 2: Claim
  [Claude Code] POST /api/tasks/claim (hooks auto-fire)
  [Other]       Execute before_doing manually, then POST claim
  Curl rule (every claim and complete curl): pipe only into tee -- -o, > /dev/null,
    or any transformer pipe silently empties changed_files / marks the base unproven
  Claim failed (Backlog / already claimed / blocked)? --> terminal STOP: report it and
    end the turn; NEVER build a task whose claim did not succeed
  |
  v
STEP 3: Explore (Decision Matrix)
  Goal/large undecomposed? --> Decompose --> Create children --> Claim first child --> Step 1
  Row says Skip for Explore/Plan/Review? --> Skip to Step 4
  Otherwise:
    [Claude Code] Dispatch task-explorer; Plan agent iff the matrix's Plan column says YES
    [Other]       Read key_files, search patterns manually
  |
  v
STEP 4: Implement
  Write code using explorer output, plan, acceptance criteria
  Follow patterns_to_follow, avoid pitfalls
  |
  v
STEP 5: Code Review (Decision Matrix)
  Row's Review column says Skip? --> Skip the review, BUT [Claude Code] still evaluate the
                            deep security-considerations gate (security_considerations
                            + plugin, no reviewer precondition; non-Claude-Code -->
                            skip it), then CONTINUE TO STEP 5.5 (not Step 6):
                            5.5 likewise gates on manual_tests + plugin only,
                            never on review
  Otherwise:
    [Claude Code] Dispatch task-reviewer, fix Critical/Important issues, then
                  evaluate the SAME deep security-considerations gate — it fires
                  on both branches; it is not a small-task-only step
                  (verdicts malformed/absent? fail closed: keep the prose verdict,
                  note the anomaly, never downgrade to passed — and treat the
                  unconfirmed consideration like an un-addressed one: fix before
                  completing)
    [Other]       Self-review against acceptance criteria
  |
  v
STEP 5.5: Manual & Exploratory Testing (Optional, Gated)
  manual_tests empty OR plugin not available OR non-Claude-Code? --> Skip to Step 6 (no failure)
  Otherwise (Claude Code + plugin available + non-empty manual_tests):
    [Claude Code] Dispatch the stride-exploratory-testing:explorer AGENT (the only sanctioned
                  surface -- never /explore, /pair, or the plugin's router skill),
                  each manual_test as a charter, capture findings (safety boundary preserved)
    Pass charter + ONE environment-context block: app reach, the user's authorized/non-prod
                  affirmative (no affirmative --> do not dispatch), tools, seed-data pointers,
                  and an explicit session budget in the INSTALLED agent's unit
    How the session ENDED bounds the coverage claim: charter quiet --> performed;
      probe budget exhausted --> partial coverage, file leftover risk as a follow-up;
      blocked or tool-call ceiling at ~zero probes --> NOT performed, hand the manual
      test back as a human responsibility (the obstacle is recorded as an obstacle,
      never as a severity-bearing finding); older-contract stopped_early --> resolve
      from the sheet, conservatively; budget too small to fund one charter --> do
      not dispatch at all; blocked or ceiling AFTER meaningful probes --> partial
      coverage, record the findings and say the coverage claim is incomplete
    Relatedness gate FIRST, at ANY severity: responsible lines are lines this task
      changed, OR same defect class as the change --> fix in-task + re-review, never
      file; the severity/provenance policy below governs only out-of-scope findings
      (moved/reformatted-only lines shown to predate the change are NOT related -->
      out-of-scope below; a follow-up task is the exception for a real out-of-scope
      bug, never the default)
    Critical whose responsible lines you wrote --> escalate fail-closed (testing_strategy failed
                  + category:testing Critical issue), fix, re-run the charter, re-review
    Out-of-scope or provenance-undetermined Critical --> report + file a
                  follow-up defect, never block
    No structured review block in the payload  --> no escalation; never synthesize one

STEP 5.6: Harden findings into checks (Optional, Gated)
  No session / no convertible findings / non-Claude-Code? --> Skip (no failure)
  /harden unavailable? --> Skip AND record that hardening was unavailable, so "could
    not" is distinguishable from "never considered"
  Otherwise: dispatch /harden (no --output) --> drafts land staged in .exploratory/checks/
    Staged is the default and always safe. A check enters the suite ONLY if the file
      loads clean AND the case is green or inert -- established by RUNNING the suite once,
      never by expecting. Otherwise revert the move and file a follow-up defect.
    Never overwrite an existing test file -- that check is YOURS, /harden never writes
      there; cannot make a check load clean or mark it inert --> leave it staged AND
      file a follow-up defect carrying the check's substance, not just its path
    Anything written here is post-review: name it in completion_notes, completion_summary
      and actual_files_changed, and re-review whenever a check entered the tree
  |
  v
STEP 6: Execute Hooks
  [Claude Code] Automatic -- just make the curl call in Step 7
  [Other]       Execute after_doing (600s), then before_review (600s)
  Hook fails?   --> Fix, re-run, do NOT proceed
  |
  v
STEP 7: Complete
  FIRST run the mandatory pre-submission self-check (every reviewer section present,
    project_checks count equal, no not_assessed for a task-supplied section) -- it
    must pass before you submit. The not_assessed check is SCOPED to payloads where
    a structured review block was parsed; Shape 2 skips and Source C carry no verdict
    and pass -- never hand-write a verdict to satisfy it
  PATCH /api/tasks/:id/complete with ALL required fields
    (pipe only into tee -- the Step 2 curl rule applies here too)
  |
  v
STEP 8: Post-Completion
  needs_review=true?  --> STOP, wait for human (changes requested --> re-enter at Step 4)
  needs_review=false? --> Execute after_review, loop to Step 1
  Last child of a goal? --> verify the push landed (git log origin/main..main empty) --
    the grace worker flips the goal to Done but does NOT push
  Workflow stops (no tasks / halt / review wait / abort)? --> clear the activation marker
```

---

## Platform Summary

| Capability | Claude Code | Cursor / Windsurf / Continue |
|---|---|---|
| Hook execution | Automatic (hooks.json) | Manual (read .stride.md, run via Bash) |
| Task exploration | Dispatch `stride:task-explorer` agent | Read key_files manually |
| Implementation planning | Dispatch Plan agent | Outline approach manually |
| Code review | Dispatch `stride:task-reviewer` agent | Self-review against criteria |
| Manual & exploratory testing | Dispatch the `stride-exploratory-testing:explorer` agent (when installed) with an explicit session budget and the user's authorized/non-production affirmative; never a command or the router skill; else fall back | Always fall back (human responsibility) |
| Hardening findings into checks | Optional Step 5.6: dispatch `/harden` (when available) to draft regression checks; staged by default, never left red in the tree | Not available — no `/harden` |
| Hook failure diagnosis | Dispatch `stride:hook-diagnostician` | Debug manually |
| Goal decomposition | Dispatch `stride:task-decomposer` agent | Break down manually, create via API |

**Both platforms follow the same step sequence.** The difference is HOW each step is executed (subagent dispatch vs manual work), not WHETHER it's executed.

---

## Failure Modes This Skill Prevents

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 5 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 7 loads the contract from stride-completing-tasks |
| Skipped hooks | Agent called complete directly | Step 6 blocks Step 7 |
| Asked user permission | Agent prompted between steps | Automation notice says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |

---

## Quick Reference Card

**Never call `GET /api/tasks` (index) or `GET /api/tasks/:id/tree` without `response_view=slim`** — the bare index measured 2.4 MB (~840,000 tokens) against production; slim serves the same rows at roughly 1% of the size. (Slim on index and tree is G408-era server behaviour: a server predating it **ignores the parameter and serves the 2.4 MB anyway**, so the param is a request, not a guarantee — on such a server avoid the index and tree endpoints outright. If you are unsure which era the server is: no version header or onboarding field tells you, but one probe half-answers — `GET /api/tasks/<id>?fields=column_id` 422s only on a current server, so a 422 proves slim is safe; a 200 leaves the era unresolved (pre-projection servers span both index/tree eras). On a 200, or to skip the probe, take the branch safe on both eras: avoid index/tree and use `next`/show, which degrade safely.) On tree, slim slims the **children** only — the root task always renders full (deliberately, so the caller keeps the detail it asked for), so a childless task's tree shrinks not at all. The claim curl stays full — its response feeds the env-cache identity refresh. The complete curl carries `?response_view=slim` (W2087); its ack plus `hooks[]` covers everything the hook reads — and it degrades safely: an older server ignores the param and echoes the full task, which the hook reads identically, at token cost only.

```
CLAUDE CODE WORKFLOW:
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist; write the activation marker (mandatory);
│     mention missing .gitignore entries (.stride/ + .stride_auth.md unconditionally,
│     .exploratory/ only when the exploratory plugin is installed — never edit it yourself);
│     plugin installed → collect the exploratory authorized/non-prod affirmative HERE or never
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 1.5 Dispatcher Mode (optional, gated):
│     ├─ No opt-in / non-Claude-Code → Skip, run 2-8 inline (default)
│     ├─ No stride:task-runner agent → Skip inline AND record that isolation was unavailable
│     ├─ Branch A task (goal / large undecomposed / 25+ hours) → do NOT dispatch; run 2-8 inline
│     ├─ Step 3 matrix Isolate = inline (small, 0-1 key_files) → do NOT dispatch; run 2-8 inline
│     └─ Else → dispatch one runner per task, act only on its record — plus, on completed, the confirmation read:
│        completed → confirm (fields=status,needs_review, degrade-safe on older servers; disagreement or failed read = abandoned/unparseable_record — report and stop) → loop
│        hook_blocked → re-dispatch once | anything else → stop and report
│        every stop → clear the activation marker before ending the turn
├─ 2. Claim: POST /api/tasks/claim (hooks auto-fire via hooks.json)
│     ├─ Curl rule (claim AND complete): pipe only into tee — -o, > /dev/null, or any
│     │   transformer pipe silently empties changed_files / marks the base unproven
│     └─ Claim failed (Backlog/claimed/blocked) → terminal STOP, report; NEVER build unclaimed work
├─ 3. Explore (check decision matrix):
│     ├─ Goal/large undecomposed → Dispatch task-decomposer → Claim children
│     ├─ Row says Skip for Explore/Plan/Review → Skip to Step 4
│     └─ Otherwise → Dispatch task-explorer (+ Plan agent if the matrix's Plan column says YES)
├─ 4. Implement: Write code using explorer/plan output
├─ 5. Review (check decision matrix):
│     ├─ Row's Review column says Skip → Skip the review, but STILL evaluate the deep
│     │                         security gate (security_considerations + plugin,
│     │                         no reviewer precondition), then continue to 5.5
│     │                         (NOT Step 6 — 5.5 likewise gates on manual_tests
│     │                         + plugin, never on review)
│     └─ Otherwise → Dispatch task-reviewer, fix issues, then evaluate the SAME deep-security
│                     gate — it fires on both branches (malformed/absent verdicts → fail
│                     closed: keep the prose verdict, never downgrade to passed)
├─ 5.5 Manual & Exploratory Testing (optional, gated):
│     ├─ manual_tests empty OR plugin unavailable → Skip to Step 6 (no failure)
│     ├─ Plugin available → Dispatch the stride-exploratory-testing:explorer AGENT only,
│     │                     manual_tests as charters (never a command, never the router skill)
│     │                     Pass charter + one env-context block incl. an explicit budget;
│     │                     no authorized/non-prod affirmative from the user → do not dispatch
│     ├─ Session ending bounds the coverage claim: quiet → performed | probe budget → partial +
│     │   file leftover risk | blocked/ceiling at ~zero probes → NOT performed, hand back
│     │   (obstacle ≠ finding) | stopped_early → resolve from sheet | budget too small → no dispatch
│     │   | blocked/ceiling AFTER meaningful probes → partial coverage, record + say so
│     ├─ Relatedness gate FIRST, any severity: lines you changed OR same defect class →
│     │   fix in-task + re-review, never file (moved-only lines predating the change ≠
│     │   related; a follow-up task = the exception for a real out-of-scope bug)
│     └─ Critical: lines you wrote → escalate fail-closed | out-of-scope or provenance
│        undetermined → report + file
│        (no structured review block in the payload → no escalation; never synthesize one)
├─ 5.6 Harden findings into regression checks (optional, gated):
│     ├─ No session / no convertible findings / non-Claude-Code → Skip, no failure
│     ├─ No /harden → Skip AND record that hardening was unavailable
│     ├─ Dispatch /harden without --output; drafts stay staged in .exploratory/checks/ (safe default)
│     └─ Into the suite only if the file loads clean AND the case is inert or run-green;
│        verify by running once, else revert and file a follow-up carrying the check's
│        substance. NEVER overwrite an existing test file (that check is yours, not
│        /harden's). Surface post-review files (completion_notes, completion_summary,
│        actual_files_changed) and re-review whenever a check entered the tree
├─ 6. Hooks: Automatic via hooks.json (fires on curl call)
├─ 7. Complete: run the mandatory pre-submission self-check FIRST (must pass; the not_assessed
│     check is scoped to parsed-block payloads — never hand-write a verdict to satisfy it), then
│     PATCH /api/tasks/:id/complete with ALL fields
└─ 8. Loop: needs_review=false → after_review auto-fires, loop to Step 1 | needs_review=true →
      STOP (changes requested → re-enter at Step 4). Last child of a goal → verify the push
      landed (the grace worker does NOT push). Workflow stops → clear the activation marker

OTHER ENVIRONMENTS (Cursor, Windsurf, Continue): see platform-other.md

DECISION MATRIX QUICK CHECK:
  There is no quick check. Open Step 3, find the task's row, read the
  column. This block used to restate the rows and drifted out of step
  with them (D221) — it gave Plan for a medium defect where the matrix
  gives Skip. A summary of the matrix is a second matrix.
```

---


## Step 3 Design Rationale

The rules these derivations produced stay inline in SKILL.md's Step 3 — the mis-labelling check, the both-channels recording rule, and the small-0-1-key_files Isolate floor. Nothing here adds a condition or a trigger; this is the history and the arithmetic behind rules the matrix already carries.

### Why the mis-labelling signal is not a planner trigger (D221)

A task labelled `small` that carries 3+ `key_files` or 3+ acceptance-criteria lines is a task whose complexity label is probably wrong. Branch C used to treat that as an independent trigger to dispatch a planner, which is exactly what collided with the `small, 2+ key_files` row's `Plan = Skip` — two rules, one task, no stated precedence. Measured consequence: two runners on identically-shaped tasks (both `small`, 2 `key_files`, 4 criteria lines) resolved it differently and wrote **different reasons for the same skip** into their `workflow_steps` telemetry, making the `planner` entry non-comparable across runs. The trigger is gone; the signal is not — SKILL.md keeps it as a mis-labelling check.

**Why both channels.** `completion_notes` is persisted only by Stride servers from D188 onward and you cannot tell which version you are talking to, so a mis-labelling noted there alone may reach nobody; `completion_summary` is required, persisted, and rendered on the Review queue. A signal routed to a channel that might not exist is not a preserved signal.

### Why small 0-1 key_files tasks are not isolated — the measured derivation

**A dispatch re-pays a fixed base of ~92,000 `cache_creation` tokens** — system prompt, tool definitions, skill bodies, task prompt — measured on W2058. That figure does not shrink with the task. What isolation *saves* does scale with the task, so there is a floor below which the base is not repaid, and the design sketch names it: "dispatching a subagent for a two-minute task will lose money."

The floor lands where it does because of what the saving is actually made of. **The largest single component of what a task accumulates into the main loop is its subagent reports** — originally measured at 9 reports totalling 161,165 B ≈ 56,351 tokens, averaging 6,261 tokens each — **but that baseline predates G407, and the current figure is roughly 7× smaller**: report-to-file cut what reaches context to **2,646 B ≈ 925 tokens per report** (an 85.2% cut, W2071; the measurement doc names the per-report into-context figure as the comparable one and warns that session totals are not). **One confounder rides with that average and matters here:** it was measured over six dispatches **none of which was a planner**, and the planner report is the largest single artefact measured in this repo (34.8 KB). Applying it to a planner-inclusive task is therefore an extrapolation — defensible because report-to-file bounds every agent's *returned* summary regardless of how large its on-disk report grows, but an extrapolation nonetheless. A medium task dispatches an explorer, a planner and a reviewer, so on today's figure its reports accumulate roughly **2,775 tokens** before any diff or hook output, not the ~19,000 the pre-G407 average implied. **A small 0-1 key_files task dispatches none of them** — the matrix already excuses it from all three — so that component is exactly zero, and all that is left to save is its own diff and tool results.

The arithmetic, so the threshold is checkable rather than asserted. A dispatcher makes about 4 main-loop requests per task, and context accumulated at task *k* is re-sent on every later main-loop request, so isolation repays its base when

```
accumulated_tokens × 4 × (N − k) > 92,000
```

which for a 20-task session with ten tasks still to run is about **2,300 tokens** of accumulation. **State this as a position rather than a single ratio, because the post-G407 correction moved it.** A medium task's three reports now accumulate ~2,775 tokens, which clears the floor only while `(N − k) > ~8` — so on today's figure a medium task is worth isolating in roughly the **front half** of a 20-task session and not the back half. Under the superseded 6,261 average the break-even sat at `(N − k) ≈ 1.2`, i.e. essentially always, so the correction changes this gate from "always justified for a medium task" to "justified early". A one-file task with no reports has to clear it on a single diff, and generally will not at any position.

**Two honest caveats.** The break-even is position-dependent — the same task is worth isolating early in a long session and not worth it as the last task — and the gate deliberately does not use position, because `complexity` and `key_files` are the signals already available at discovery and already driving the matrix. And the 2,300-token figure inherits the 4-requests-per-task and 20-task assumptions from the cap derivation in [`../../docs/task-runner-contract.md`](../../docs/task-runner-contract.md), neither of which is measured. The direction is robust even if the number moves: a fixed base against a saving that scales with reports a small task never produces.

## Session Position (Operator Guidance)

This section is for the human operator who starts sessions and decides which tasks to feed them — the agent cannot clear its own session, so nothing here is agent procedure and no workflow step reads it.

**The policy.** Unrelated tasks — typically standalone defects — each get a fresh or cleared session. Tasks that genuinely build on each other — children of one goal working toward one change — share a session. The parent/standalone shorthand has three edge cases that cut against it: a goal whose children are independent despite sharing a parent reads as unrelated tasks (fresh sessions); a standalone defect filed as a follow-up to work completed minutes earlier reads as building on it (share the session); and "share" can only extend a session that still exists — a `needs_review=true` child ends the session at Step 8's stop regardless of what was planned, and an overnight gap usually means the session is gone, so in both cases the resume-or-clear decision afterwards applies this same principle to the tasks that remain rather than inheriting the original grouping. What decides is whether the next task will actually reuse the context the last one built, not what the board's hierarchy says. **The share branch is costed and materially narrowed in "The share-vs-clear threshold" below — read it before applying this paragraph's shorthand**, which states the grouping rule but not its price.

**The measured basis** ([`../../docs/token-measurement-g404-g405.md`](../../docs/token-measurement-g404-g405.md), "The lever that dwarfs both goals: session position"): the measured three-task session cost 52,506,528 tokens as run; the same three tasks each at first-position cost would have been ~24,073,854 — a difference of ~28,432,674 tokens, 54% — against G404's 6.2% actual saving across the same three tasks. In the doc's words, clearing context between tasks is worth roughly nine times what G404 delivered, and it requires no code at all.

**The caveats travel with the numbers — the measurement doc attaches them itself.** Treat 54% as an **upper bound, not a measurement**: it is confounded (one task was `small` while the other two were `medium`, and request counts grew with task size as well as position), so the direction is not in doubt but the magnitude mixes two causes. And **the trade is real**: clearing discards cross-task context, which is worth something exactly when consecutive tasks share a goal — the measured session's three tasks each built directly on the last, which is why this is a judgement call, not a free win. Be clear-eyed about what that means for the share branch specifically: the measured session *was* a building-goal session, so the ~54% upper bound is the measured price of sharing, and the judgement being made is whether the reuse is worth that price. The isolation-floor derivation above prices the accumulation side of this same trade class; the heuristic below prices the reuse side, so the judgement is checkable rather than bare — but it stays a **heuristic with stated assumptions, never an absolute rule**, because the reuse side's key input is not measured. Per the doc's own reporting rule, a percentage of this class is only well-formed with its position-in-session attached: the same G404 change measured 15.2% at first position and 5.6% by task three in one sitting.

### The share-vs-clear threshold — what sharing costs, and when reuse outruns it

**The shape, mirroring the isolation floor above.** Sharing carries a finished task's context into every later request of the session; clearing discards it and makes the next task re-discover what it needs. So the threshold at which sharing pays is

```
rediscovery_tokens > carried_tokens × requests_per_task × (N − k)
```

where `carried_tokens` is **everything already resident when the boundary is reached — not one task's residue** (at boundary `k` that is `k` completed tasks' worth, which is why the bar is not flat along a chain), `N − k` is the tasks still to run, and `rediscovery_tokens` is what a fresh session would spend re-establishing what it lost. **Scope: this models a linear queue.** Where a task depends on a *non-adjacent* predecessor — the diamond that a partially-dependent goal generically produces — the inequality has no term for it and does not apply; see the ordering note at the end.

**Do not inherit the isolation floor's `4` here — this branch has its own measured cadence, and they differ by an order of magnitude.** That derivation's 4-requests-per-task comes from the cap derivation in [`../../docs/task-runner-contract.md`](../../docs/task-runner-contract.md), which is a **dispatcher-mode runner's** main-loop cadence and is explicitly unmeasured there. This section governs **human-operator sessions doing the work inline**, and those *are* measured: the same three-task session ran **44, 53 and 59** main-loop requests per task (token-measurement doc, the request/context table under "Why one change has two right answers" — *not* the session-position table, which carries the 54% figures only). Using 4 here would under-price sharing by roughly 12×.

**The cost side — derived from measurements, not itself measured.** In the same table (the "two right answers" table, not the session-position one) average context per request grew **137,165 → 255,886 → 369,173**, so a completed task adds roughly **113,000–119,000 tokens** to what is resident (deltas 118,721 and 113,287; mean **116,004**). **Call that derived, not measured**, and hold it loosely for two reasons: a delta of per-task *averages* conflates what task `k` left behind with what task `k+1` grew on its own, and the ordering runs the wrong way — the **small** task's delta (118,721) exceeds the **medium** one's (113,287), which a clean per-task residue should not. Likewise `requests_per_task`: the measured 44/53/59 is used below as a flat **~50**, and the source attributes that growth to task size *as well as* position, so flattening it is an assumption, not a reading. With those caveats, one boundary of a two-task session costs on the order of **5–6 million tokens**.

**The input that is not measured — and this is the honest limit of the heuristic.** No figure anywhere in this repo prices `rediscovery_tokens` for operator session-clearing. The design sketch says so directly: "Some of the saving is real; some is re-discovery moved elsewhere. Nobody has measured the split" ([`../../docs/orchestrator-context-isolation-design.md`](../../docs/orchestrator-context-isolation-design.md)). A re-discovery figure of **29.5% at position 2** does exist in the measurement doc, but it prices a **task-runner's cold start**, not an operator's cleared session — a different scenario, and borrowing it would be exactly the silent-inheritance error this section just warned about for `4`.

**Price, not token count, decides it — and the unit must be stated.** Compare against a subagent dispatch, the most expensive re-discovery mechanism here. Raw counts would make the carry look ~60× dearer, but that comparison is invalid: the two sides are **different token kinds** — re-sent context is `cache_read`, a dispatch base is `cache_write`. Applying the measurement doc's own multipliers (**cache write 1.25×, cache read 0.1×, output 5×** — all three, which it flags as assumed rather than invoiced), the carry is 5,800,000 × 0.1 ≈ **580,000** base-equivalents. What it is measured against depends on a convention this section must name rather than assume:

- against a dispatch's **spin-up base** — 92,000 `cache_write` ≈ **115,000** base-equivalents — the ratio is **~5×**;
- against a **full measured explorer dispatch** (W2058: 94,859 `cache_write` × 1.25 + 938,378 `cache_read` × 0.1 + 48 output × 5 ≈ **212,652** base-equivalents — a price-adjusted figure, not a raw sum of those three counts), it is **~2.7×**.

The base is the right denominator when asking "does spinning one up repay itself"; the full cost is the right one when asking "would I rather re-run an explorer than carry this". **Use the full-dispatch figure here** — this branch asks the second question. And the doc's session-level counterfactual (~28.4M across **two** boundaries → 14.2M each; × 0.1 ÷ 212,652) puts an upper bound near **6.7×**. So the honest bracket is **roughly 3–7×**, not 60×.

**A single-figure headline would be wrong, because the bar moves with position.** The bar is `carried × 50 × (N − k)` and `carried` grows with `k`, so it is smallest at the ends of a chain and largest in the middle. For a 5-task goal, in **full-dispatch equivalents**: about **11 / 16 / 16 / 11** at boundaries 1 through 4. Quote the position with the number, exactly as the parent paragraph's own reporting rule demands — "about five" with no `(N − k)` attached is the cheapest boundary in the session, and using it everywhere under-prices sharing several-fold.

**What the costing actually establishes — and its structural limit, which is the honest headline.** Read the two branches together and a pattern falls out: **where the reuse is written down, re-discovery collapses to "read the artifact" — cheap, far under any bar, so the answer is clear. Where it is not written down, `rediscovery_tokens` is exactly the quantity nobody can estimate, so the inequality returns nothing.** The costed test therefore yields **clear or undefined; on these figures it does not return share on its own.** That is not a rule that sharing is wrong — it is a finding about what the token arithmetic can and cannot decide, and it cuts two ways. It means the routine cases (children reading the same few files) are settled, and it means **when sharing genuinely is right, it is right for reasons this arithmetic does not capture** — an operator's re-briefing time, the risk of losing an undocumented decision — which is precisely why the policy above stays a judgement call and why this section does not convert it into a rule. Note too that this workflow actively shrinks the unwritten-down category: the both-channels recording rule and report-to-file push decisions onto disk, which moves cases toward the clear branch over time.

**Chain length, and why the bound rarely gets to fire.** `carried` accumulates, so the k-th task of a shared chain carries every earlier task's residue — the measured session's third task was already re-sending 2.7× the first's context per request — and one more shared boundary costs correspondingly more. **Two assumptions, stated rather than smuggled:** that reuse value is roughly flat in chain length (unmeasured; if reuse instead grows with the chain, the bound weakens), and the flat `requests_per_task` noted above. On the flat reading a long building chain does not justify one session end to end: split it and re-apply the test at each boundary rather than inheriting the original grouping, the same resume-or-clear principle the policy paragraph applies after an interruption. **In practice this bound is mostly redundant** — a walkthrough of a five-child building goal cleared at the *first* boundary, so no chain formed for it to bound. It bites only where the early boundaries are genuinely close.

**Queue order is the operator's real lever, and it sits outside the formula.** The index `k` presupposes an order the board supplies but the operator controls. On a partially-dependent goal, moving a task to follow the one it actually builds on changes every boundary's answer, and it is usually the better move than deciding share-or-clear on the order as given. **Reorder first, then apply the test** — and where a task's real predecessor cannot be made adjacent (a genuine diamond), the inequality does not model that boundary and the judgement stands unpriced.

**Caveats, in the isolation floor's own spirit.** The ~54% remains an **upper bound, not a measurement**, and confounded — every figure here inherits that, so treat the 5–6 million as an order of magnitude, not an estimate, and the 3–7× bracket as its shape rather than its value. The multipliers are the doc's **assumed** ones, not invoiced. The break-even is **position-dependent** exactly as the isolation floor's is, which is why the bar is quoted per boundary above and never as one number. And **when you cannot estimate `rediscovery_tokens`, this degrades to the judgement call it replaced** — say what you actually know and decide, rather than fabricating a figure to make the inequality resolve. Given the structural limit above, that fallback is not a rare edge: it is where the whole share branch lives.

**What a walkthrough showed.** The queues below were **constructed for this walkthrough**, not drawn from a real session — so read the results as how the test behaves on those shapes, not as a replay of observed operator decisions. Applied to a constructed five-child **building** goal, the test cleared at all four boundaries and two readers agreed — determinate, but note the answer is the *opposite* of the policy shorthand's "children of one goal share a session", which is the narrowing this section exists to surface. Applied to a constructed five-child **partially-dependent** goal it resolved only two of four boundaries: one where the qualitative share trigger met a bar the reader had to position-correct, and one diamond the model cannot represent. **So the honest claim is that this settles the routine cases and leaves the hard ones explicitly open** — not that it groups every queue.
