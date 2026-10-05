# Porting the G455 rework gates to the Stride variants

This guide covers goal **G455, "Gate the causes of review rework in the stride
plugin"**, filed on 2026-10-03. The goal follows a rework analysis that asked
why reviewers sent work back and whether richer task data would have prevented
it. Mostly it would not have. The rework came from causes a check can catch, so
G455 adds checks to the reviewer, the explorer and the task-authoring agents.
It adds no task fields and changes nothing on the Kanban server.

Each change lands in `stride` first. For each change, this guide records the
problem, the evidence behind it, the planned change in `stride`, what a port
needs to carry it, and how to verify the port.

**Keep this file current.** When a G455 task lands in `stride`, change its status
below from *planned* to *landed*. Then replace its "Planned change" paragraph with
what actually shipped, naming the commit and, once the release task runs, the
version. A planned section describes intent, not shipped behaviour. **Do not port
from a planned section.**

## Status

| Task | Change | Status in `stride` |
|---|---|---|
| W2292 | The creation skills and the decomposer author a `behaviour_test_matrix` by default for testable tasks | landed (`955533c`) |
| W2293 | The reviewer maps every `testing_strategy` item to a named test | landed (`c4c029a`) |
| W2294 | The implementer records break-it evidence that new and changed tests can fail, and the reviewer enforces it | landed (`cb1fc8f`) |
| W2295 | The reviewer verifies the factual statements a diff adds | landed (`f2c5957`) |
| W2296 | The reviewer flags untouched twins and mirrors | landed (`b0d1cad`) |
| W2297 | The enricher and decomposer run a cross-field consistency pass before creating a task | planned (after W2292) |
| W2298 | The explorer reports task statements that the current code contradicts | planned |
| W2299 | Release `stride` once and finish this guide | planned (runs last) |

W2293 to W2296 all edit `agents/task-reviewer.md`, so they run in that order.

## The evidence behind the goal

The analysis took every finding marked `critical` or `important` from a
**non-final** review round, meaning a finding that forced another round of
implementation. It covered tasks completed between 2026-08-29 and 2026-10-02,
because review-round counts are only recorded from W2128 onward. Findings came
from the reviewer subagent transcripts, since the server keeps only the final
round. Each finding was then compared against the exact task text the
implementer worked from.

| Measure | Value |
|---|---|
| Reviewed tasks with a recorded round count | 280 |
| Tasks that needed a second round or more | 81 (29%) |
| Reworked tasks with earlier-round findings recovered | 42 |
| Blocking findings from those rounds | 97 (12 critical, 85 important) |
| Implementation mistakes | 52 (54%) |
| Information in the task but ignored | 25 (26%); 11 were listed `testing_strategy` items never written |
| Task spec wrong or self-contradictory | 10 (10%) |
| Information missing but knowable in advance | 9 (9%); every one fits an existing field |
| Process slips | 1 |
| `behaviour_test_matrix` filled in production tasks | 0 of 385 |

The implementation mistakes were mostly of four kinds:
- false statements written into prose, comments and changelogs;
- tests that still pass when the code they guard is broken;
- incomplete sweeps that missed a PowerShell twin or a second statement of the same rule;
- logic bugs.

False statements kept appearing after `claims_verified_by` shipped in `stride`
1.77.0 on 2026-09-07. That rule is optional and nothing checks it.

**Two limits on this evidence.** 39 of the 42 reworked tasks were plugin and port
tasks, so the findings describe markdown-contract and hook-script work more than
application code. The classification was done by model reviewers against a fixed
rubric: 20 of the 25 "ignored" verdicts quote task text that was matched
mechanically, and the other 5 cite project conventions or a quote format the
matcher did not cover. The scripts and per-finding classifications were working
files from that session and are not committed.

**Why there is no canon entry.** `docs/port-canon.md` admits a rule only when a
shipped defect forced it ("Add a rule only when a shipped defect forced it").
These rules come from review findings on work that was fixed before it shipped,
so G455 registers none. That means `scripts/check-port-canon.sh` will **not**
report a port as missing these changes. This guide is the only tracker, so keep
the port table at the end of this file up to date.

## The port fleet, as checked on 2026-10-03

These are the mechanisms the changes depend on. The table was built from
directory listings and greps run from the `kanban` checkout. Re-check a cell
before relying on it, because ports move.

| Port | Reviewer agent | Explorer agent | Enricher | Decomposer | Matrix support | Writes `TASK_FILE` | Explorer `verified_by` | sh + ps1 twins | Test command |
|---|---|---|---|---|---|---|---|---|---|
| `stride` | `agents/task-reviewer.md` | `agents/task-explorer.md` | `agents/task-enricher.md` | `agents/task-decomposer.md` | yes | yes (W2248) | yes | yes | `bash hooks/test-stride-hook.sh`, `pwsh -File hooks/test-stride-hook.ps1` |
| `stride-codex` | `agents/task-reviewer.md` | `agents/task-explorer.md` | `agents/task-enricher.md` | `agents/task-decomposer.md` | yes | no | no | bash only | `bash hooks/test-stride-hook.sh` |
| `stride-copilot` | `agents/task-reviewer.agent.md` | `agents/task-explorer.agent.md` | `agents/task-enricher.agent.md` | `agents/task-decomposer.agent.md` | yes | no | no | yes | `bash hooks/test-stride-hook.sh`, `pwsh -File hooks/test-stride-hook.ps1` |
| `stride-gemini` | `agents/task-reviewer.md` | `agents/task-explorer.md` | `agents/task-enricher.md` | `agents/task-decomposer.md` | yes | no | no | yes | `bash hooks/test-stride-hook.sh`, `pwsh -File hooks/test-stride-hook.ps1` |
| `stride-opencode` | `agents/task-reviewer.md` (`@mention`) | `agents/task-explorer.md` | `agents/task-enricher.md` | `agents/task-decomposer.md` | yes | no | no | TypeScript (`src/`) | `bun test` |
| `stride-pi` | `extensions/subagent-dispatch/agents/stride-task-reviewer.md` + fallback `skills/stride-task-reviewer/` | `…/stride-task-explorer.md` + fallback skill | `…/stride-task-enricher.md` (no fallback skill) | `…/stride-task-decomposer.md` + fallback skill | yes | no | no | TypeScript (`extensions/`) | `npm test`, `node --test` in `extensions/subagent-dispatch` |
| `stride-lite` | `agents/task-reviewer.md` | `agents/task-explorer.md` | `agents/task-enricher.md` | `agents/create-decomposer.md` | **no** | no (tasks are local `.md` files) | no | yes | `bash test/smoke.sh`, `bash hooks/test-stride-lite-hook.sh` |
| `stride-copilot-lite` | `agents/task-reviewer.agent.md` | `agents/task-explorer.agent.md` | `agents/task-enricher.agent.md` | `agents/create-decomposer.agent.md` | **no** | no (local `.md` files) | no | yes | `bash test/smoke.sh`, `bash hooks/test-stride-copilot-lite-hook.sh` |
| `stride-opencode-lite` | `agents/task-reviewer.md` | `agents/task-explorer.md` | **none** | `agents/create-decomposer.md` | **no** | no (local `.md` files) | no | TypeScript (`src/`) | `bun test` |

Things that shape every change below:

- **The lite ports keep tasks as markdown files.** They never call the Stride API;
  each task is a local file with H2 sections (`## Acceptance criteria`,
  `## Testing strategy`, `## Key files`, and so on). In a lite port, voice every
  rule as reading and writing those sections. The lite reviewer appends a
  `## Review Report` section to the task file, and the lite explorer appends an
  `## Exploration Report` section.
- **Only `stride` writes `.stride/.task-<IDENTIFIER>.json`.** A rule that reads a
  field from `TASK_FILE` in `stride` reads it from the claim response, or from
  the dispatch prompt, in the full ports. In the lite ports it reads the task
  file itself.
- **Only `stride`'s explorer carries `verified_by`.** W2298 depends on it, so a
  port either adopts `verified_by` first or voices the drift check with its own
  "the command that found it" field.
- **Every reviewer forbids running tests or executing code.** The full ports say
  so in their reviewer agent. The lite reviewers say "Never executes code or runs
  tests" (for example `stride-lite/agents/task-reviewer.md:45`). Keep that
  constraint: W2294 moves the break-it run to the implementer for exactly that
  reason, and W2295 and W2296 use read-only commands only.
- **All three lite reviewers count one criterion per line.** Each says "Parse each
  line of `## Acceptance criteria` as a separate criterion", the same split
  `stride`'s reviewer uses. So W2297's one-line rule applies to them too.
- **Only `stride` has a skill byte-budget script** (`scripts/check-skill-budgets.sh`).
  No port does, so a port has no budget gate to trip. It still pays the same
  per-task token cost for every line added to a hot-path skill.

---

## Changes at creation time

### W2292 — a `behaviour_test_matrix` by default (landed)

**Problem.** No production task carried a matrix (0 of 385), yet it is the one
test specification the reviewer checks row by row and the implementer updates
as it goes. The creation skills call it optional, and the decomposer never
mentions it. The enricher already emits it by default.

**Shipped in `stride`** (commit `955533c`; the version is set when W2299
releases). `stride-creating-tasks`, `stride-creating-goals` (for every nested
task) and `agents/task-decomposer.md` (for every child task) emit a complete
seven-category matrix whenever the task's `testing_strategy` names a unit or
integration test, waiving categories that do not apply with `na_reason`. A
manual-only `testing_strategy` gets `"manual"` rows when its checks exercise
behaviour. The matrix is omitted only for a task with no testable behaviour, and
the task's `description` says why in one sentence. Each row's `test_name` must
name a test that `testing_strategy` lists, and the matrix never replaces
`testing_strategy`. Row text carries no secrets, and the decomposer never copies
a credential-shaped string from a project file into it. The server rule is
unchanged: an absent or empty matrix is valid and never shows as an empty pill,
and a partial one is rejected. `docs/task-decomposer-reference.md` notes that
its worked example leaves the matrix out for length, and bash hook-suite Group
62 pins the rules.

**Port needs.**
- **Full ports** (codex, copilot, gemini, opencode, pi) already validate and
  review the matrix. Port the default into their creating-tasks skill,
  creating-goals skill and decomposer agent. In pi, also update the
  `skills/stride-task-decomposer/` fallback.
- **Lite ports: not applicable.** They have no matrix at all; the canon's
  `verdict-note` entry gives them the `four-section-keys` variant for exactly that
  reason. Adding a matrix section would be a new feature, not a port. Record
  "not applicable — no behaviour_test_matrix in this port" in each lite
  changelog. W2293 gives the lite ports the same per-item traceability through
  their `## Testing strategy` section.

**Verify.** Decompose a sample medium goal and check that every child with
testable behaviour has seven categories, and that its row test names match its
`testing_strategy`.

### W2297 — a cross-field consistency pass (planned)

**Problem.** Ten findings came from task specs that contradicted themselves. Each
time, the implementer followed the more concrete instruction, and that was the
wrong one:
- D340: a prescribed regex could not meet the task's own edge case.
- W2249: an acceptance criterion contradicted the task's pattern.
- W2195: the `what` contradicted a security consideration.
- D323: a verification grep was narrower than its criterion.

Nine more came from facts outside the task's files that the author could have
stated, such as server validation rules, protocol behaviour and already-tagged
versions. A wrapped acceptance criterion also becomes two criteria, because
every reviewer counts lines.

**Planned change in `stride`.** The enricher and decomposer each run six checks
before returning a task:
1. Every verification step covers at least the scope of the criterion it verifies.
2. No `what` or pattern instruction contradicts a pitfall or security consideration.
3. Any prescribed regex or command is tested against the task's own edge cases.
4. Where two instructions can conflict, the task says which wins.
5. Every criterion fits on one line.
6. External contracts the change must respect are named in pitfalls or patterns.

The creation skills point to the same pass. It is stated inline in each agent,
because agents do not read plugin docs at run time.

**Port needs.**
- **Full ports:** add the pass to the enricher and decomposer agents, and point
  to it from the creating-tasks, creating-goals and enriching-tasks skills. In
  pi, add it to both dispatch agents, and add it to the decomposer fallback
  skill, since pi has no enricher fallback skill.
- **stride-lite and stride-copilot-lite:** add it to `task-enricher` and
  `create-decomposer`, phrased over sections (`## Verification steps` against
  `## Acceptance criteria`, and so on). Point to it from the `create-goal` and
  `create-task` skills.
- **stride-opencode-lite** has no enricher. Add the pass to `create-decomposer`
  and the `create-task` skill only, and record the missing enricher in its
  changelog.

**Verify.** Feed the enricher D340's original spec, or any task whose grep is
narrower than its criterion. The result widens the step or names the open
question.

---

## Changes in exploration

### W2298 — report contradicted task statements (planned)

**Problem.** Task text is written when the goal is decomposed, and earlier
siblings can make it false before the task is claimed. W2166 repeated goal
context that sibling W2164 had made untrue a day earlier, and W2202 kept a stale
`key_files` note. Explorers already notice some drift on their own: 64 of 268
production summaries mention stale or missing spec elements. But nothing tells
them to look.

**Planned change in `stride`.** The explorer checks each statement the task makes
about the current code: the `key_files` notes, `description`, `where_context`,
`patterns_to_follow` and `technical_details`. It verifies each one with a
`verified_by` command. It also runs `git log` on the key files for commits made
after the task's `inserted_at` in `TASK_FILE`. Contradictions go under a fixed
heading at the top of the bounded summary, and the orchestrator already revises
its draft when the explorer disagrees.

**Port needs.**
- **The check itself** ports to every explorer.
- **The `verified_by` field** is `stride`-only. Port it with this change, or name
  the verifying command in your port's own words.
- **The commit window needs a timestamp.** Full ports have no `TASK_FILE`, so take
  `inserted_at` from the claim response, which the full task body carries. Lite
  ports have no claim, so use the commit that created the task file:
  `git log --diff-filter=A --format=%cI -- <task file>`.
- **Without a timestamp,** check the statements without the commit window and say
  so in the summary, the same way the `stride` matrix row for that case reads.

**Verify.** Dispatch the explorer on a task whose key-file note names a function
renamed after the task was created. The summary should open with the
contradiction.

---

## Changes in review

All four edit the reviewer agent. Port them in this order if your port lands
them one at a time: the later ones assume the earlier wording.

### W2293 — map every testing item to a named test (landed)

**Problem.** The reviewer's testing check asks whether the diff "includes
appropriate tests". It never maps each listed test to a real one. 11 of the 25
present-but-ignored findings were tests the task listed word for word:
- W2179 skipped "Override set to zero".
- W2183 skipped three gate unit tests.
- W2248 skipped the 422/404 fixture case.
- W2181's size-ceiling edge case went untested for three rounds.

**Shipped in `stride`** (commit `c4c029a`; the version is set when W2299
releases). Review step 4 of `agents/task-reviewer.md` now maps every
`unit_tests`, `integration_tests` and `edge_cases` item to the test that covers
it, by `file:line` in the diff or the existing suite. A test counts only if it
asserts the item's behaviour; a matching name is not enough. An unmapped item
raises an Important `testing` issue and fails the verdict. `manual_tests` items
are excluded, with a one-line note. An item covered by a Verified matrix row
counts as mapped, and an item that a Missing or Mismatch row already reported
gets no second issue. The mapping goes in the report file only. The summary
bound, the block keys and `schema_version` are unchanged, and the reviewer
still never runs tests. `docs/task-reviewer-examples.md` shows an unmapped item
becoming an issue, and bash hook-suite Group 59 pins the rules.

**Port needs.**
- **Full ports:** add the mapping to the reviewer's testing step. The per-row
  matrix check each port already has is the model.
- **Lite ports:** voice it over `## Testing strategy`, where unit tests and edge
  cases are bullets inside the section, and record the mapping in the
  `## Review Report` section.
- **Every port:** keep the summary bound, and do not add keys to the structured
  block a port's tooling parses.

**Verify.** Review a change that omits one listed edge case. The report maps the
other items and raises an Important `testing` issue for the omitted one.

### W2294 — break-it evidence for new tests (landed)

**Problem.** Tests that stay green when their code is broken were a recurring
implementation mistake:
- W2035: all eight assertions were satisfied by prose elsewhere in the file.
- W2036: an `ok()` call sat outside its loop.
- W2034: raising a cap from 8 to 1000 left every test green.
- W2171: an unclosed quote swallowed two assertions.

Fix rounds regressed too (W2181, D337). The reviewer cannot run code, so the
evidence has to come from the implementer.

**Shipped in `stride`** (commit `cb1fc8f`; the version is set when W2299
releases). The new `skills/stride-workflow/test-non-vacuity.md`, pointed to in
one line from Step 4, says: for every test the diff adds or changes, break the
behaviour it guards, see it fail, restore, and see it pass. A diff with no new
or changed tests needs no entries, and a formatting-only change needs none
either. The restore check is a content-hashing snapshot (`git status
--porcelain` plus the diff and untracked-file hashes), because porcelain alone
misses a break left in an already-modified file; it must match before the
reviewer is dispatched. Restores reverse the edit and never use a git command
that would drop uncommitted work. A test that cannot be broken without side
effects outside the repository is recorded with a one-line
`not_broken_reason`. For text pins the procedure counts occurrences in the
slice, not lines. The results reach the reviewer as `break_it`, documented in
`review-block-extraction.md` beside `commit_pending`, with `test`, `break`,
`failed_when_broken` and `passes_when_restored`; it is not folded into
`review_round.fixes[]`. Review step 4 of `agents/task-reviewer.md` raises an
Important `testing` issue for a missing entry and for a break that misses the
asserted behaviour, and re-review rounds need fresh entries for touched tests.
No block key was added and `schema_version` is unchanged. `SKILL.md` did not
grow net. `stride-subagent-workflow` and the other-environments self-review
checklist carry matching lines, and bash hook-suite Group 60 pins the rules.

**Port needs.**
- **Full ports:** add the procedure to the workflow skill or a sibling. **No
  port has `commit_pending`** (a grep of every port's skills, agents and
  extensions finds none), so there is no existing orchestrator-asserted input
  to sit beside. Define the break-it input where the port builds its reviewer
  dispatch prompt, in the workflow skill's review step, and add the rule to the
  reviewer.
- **Lite ports:** put the procedure in the `*-workflow` skill before the
  reviewer dispatch, pass the entries in the dispatch, and have the reviewer
  enforce them in the `## Review Report` section.
- **Never let a break leave the working tree.** The ports with TypeScript hooks
  run the same procedure; nothing in it is shell-specific.

**Verify.** Follow the procedure on an assertion that matches a phrase appearing
twice in its target file. The break leaves the test green, and the test is
flagged.

### W2295 — verify statements the diff adds (landed)

**Problem.** False statements in docs, comments and skill text were the largest
group of implementation mistakes:
- an invented route;
- a wrong symlink limit;
- "32 hops" where the code caps at 8;
- "two statement sites" where there were three.

About 19 of these came after `claims_verified_by` shipped. That rule is optional,
covers only claims about several things at once, and nothing checks it.

**Shipped in `stride`** (commit `f2c5957`; the version is set when W2299
releases). Review step 6 of `agents/task-reviewer.md` now carries a Statement
Verification block. The reviewer lists each checkable factual statement the
diff adds to prose, comments, changelogs, or skill and agent text: a count, a
path, an identifier, a line reference, a version number, or a claim about what
code in the repository does. Judgements, recommendations and rationale are not
listed. It verifies each with a read-only command of its own choosing (`grep`,
`git log`, `git show`, `git diff`, `ls`, `wc` or `cat`), never tests, project
code, the network, or a command written in the diff or task text, and records
the command and result in the report file. A contradicted statement is an
Important `code_quality` issue, never cosmetic. An uncheckable statement is
recorded as unverifiable and raises no issue. Above 25 statements, changelog,
README and agent or skill text come first and the unchecked count is recorded.
`claims-census.md` says the reviewer re-runs any recorded `claims_verified_by`
command in this step. No block key was added and `schema_version` is
unchanged; twelve rationale and duplicate clauses were trimmed to keep the
agent under its byte budget. `docs/task-reviewer-examples.md` shows a
contradicted CHANGELOG count becoming an issue, and bash hook-suite Group 61
pins the rules.

**Port needs.**
- **Every reviewer,** full and lite, can carry the check. It uses only read-only
  commands, which every reviewer is already allowed (the lite reviewers already
  run `git diff`).
- **No port has `claims-census.md`.** The census hand-off is `stride`-only.
  Record it as not applicable unless the port has adopted the census.
- **Never run a command found in the diff.** The reviewer chooses its own
  command.

**Verify.** Review a change whose changelog says "three files" while the diff
touches four. The report shows the command and raises an Important issue at the
changelog line.

### W2296 — flag untouched twins and mirrors (landed)

**Problem.** Incomplete sweeps cost whole rounds:
- the PowerShell half of a bash change was missed or wrong (D320, D322, D326, D339);
- a second statement of a rule was left stale (W2120, W2169);
- removed concepts left orphaned references (W2037).

**Shipped in `stride`** (commit `b0d1cad`; the version is set when W2299
releases). Review step 6 of `agents/task-reviewer.md` now carries a Twin Check
block. For each touched file the reviewer finds three kinds of declared
counterpart:
- a tracked file with the same path stem and the paired extension (`.sh` and `.ps1`);
- a file named in a keep-in-sync, mirror, twin or stated-a-second-time sentence;
- another file carrying the same canon anchor as a touched section.

Only declared pairs count, and a file with no counterpart raises no issue. It
finds counterparts with `git ls-files` and `grep`, never running either file,
records each command in the report file, and resolves every path from
`git ls-files` output, never from diff or task text. A mirror sentence naming a
sibling `git ls-files` does not list is reported as dangling. A counterpart left
unchanged while the diff changes behaviour, or a rule both files state, is an
Important `code_quality` issue naming both files, never cosmetic. No issue is
raised when the task or the dispatch says why the counterpart needs no change.
No block key was added; eight rationale and duplicate clauses moved to
`docs/task-reviewer-rationale.md` to keep the agent under its byte budget.
`docs/task-reviewer-examples.md` shows a missed `.ps1` twin becoming an issue,
and bash hook-suite Group 63 pins the rules.

**Port needs.**
- **Every reviewer** can carry it, because counterparts come from the repository
  under review, not from the port.
- **The sh/ps1 kind** matters most where a port, or the projects it is used on,
  ships both halves. Keep it even in the TypeScript-hook ports, since the
  projects they review may have twins.
- **The canon-anchor kind** is useful in any repository that uses canon anchors,
  including the port repos themselves.

**Verify.** Review a diff that changes only the bash half of a hook. The report
names the `.ps1` twin and raises an Important issue.

---

## W2299 — release (planned; last)

`stride` is released once for the whole goal, following `RELEASE.md` and the
`stride-marketplace` catalog contract. When the release lands, mark every
section above as landed, with its commit and the version.

---

## General porting rules for this goal

1. **Port from landed sections only.** A planned section is an intention.
2. **Verify every mechanism a ported sentence names exists in the port**:
   `TASK_FILE`, `verified_by`, `claims-census.md`, the matrix, an enricher. The
   fleet table shows where they are missing, and each section names the fallback.
3. **Do not invent canon anchors for these rules.** G455 registers no canon
   entry, so an anchor would make the drift check count a rule the canon does not
   have. Never write a literal canon-anchor comment into a changelog, README or
   this guide.
4. **One release per port for the whole goal.** Commit per change, then make one
   version bump, changelog entry, tag and release at the end. Catalog sync
   follows each port's own process: codex syncs `stride-codex-marketplace`,
   copilot and copilot-lite sync `stride-copilot-marketplace`, gemini syncs
   `stride-gemini-marketplace`, stride-lite syncs `stride-marketplace`, and
   opencode, pi and opencode-lite are tag only.
5. **Record what a port cannot carry** in that port's changelog, so "not
   applicable" can be told apart from "missed". Expected cases: W2292 in all
   three lite ports, the census hand-off in W2295 everywhere but `stride`, and
   the enricher half of W2297 in `stride-opencode-lite`.
6. **Keep the reviewer read-only.** None of these changes lets a reviewer run
   tests or project code. If a port's reviewer has no shell tool at all, voice
   W2295 and W2296 as checks the orchestrator runs and passes in, rather than
   dropping them.

## Port status

Fill in a row as each port takes the batch. Use: not started, in progress,
ported (version), or not applicable (reason).

| Port | W2292 | W2293 | W2294 | W2295 | W2296 | W2297 | W2298 |
|---|---|---|---|---|---|---|---|
| `stride-codex` | not started | not started | not started | not started | not started | not started | not started |
| `stride-copilot` | not started | not started | not started | not started | not started | not started | not started |
| `stride-gemini` | not started | not started | not started | not started | not started | not started | not started |
| `stride-opencode` | not started | not started | not started | not started | not started | not started | not started |
| `stride-pi` | not started | not started | not started | not started | not started | not started | not started |
| `stride-lite` | not applicable (no matrix) | not started | not started | not started | not started | not started | not started |
| `stride-copilot-lite` | not applicable (no matrix) | not started | not started | not started | not started | not started | not started |
| `stride-opencode-lite` | not applicable (no matrix) | not started | not started | not started | not started | not started (decomposer only) | not started |
