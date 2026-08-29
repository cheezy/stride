# Port canon — the rules every Stride port must carry

**Status:** Normative. This file is the schema of record for **which rules cross
port boundaries**, what each one requires in substance, and which ports owe it.
It is consumed by the drift check, which reads the fenced JSON blocks below and
reports, per rule and per port, whether the port carries the rule at its current
version.

**The rule in one line:** the canon owns *substance and applicability*; each port
owns *voicing*. Two ports satisfying the same entry in different words are both
compliant — that is the D240 per-port shaping precedent, and requiring
byte-identical text across ports would contradict it.

> **Scope.** This file governs cross-port rules only. It does not own the
> completion payload (`stride/skills/stride-completing-tasks/SKILL.md`), the
> reviewer block (`stride/agents/task-reviewer.md`), or the lifecycle
> (`stride/skills/stride-workflow/SKILL.md`). Where an entry restates a rule
> those files define, they remain the source and this file cites them by path.
> An entry's job is to say *that the rule crosses ports and who owes it*, not to
> become a second definition that can drift from the first.

## Release gate

`scripts/check-port-canon.sh` is what reads this file and reports the fleet
against it. It is a release-time step rather than an automatic one: nothing
runs it for you, and `stride/README.md` documents how to invoke it and what its
exit codes mean. Run it before cutting a port or catalog release, and read a
non-zero result as blocking. This section deliberately stops here — the
checker's contract belongs to the script and its README entry, and restating it
would create exactly the second copy the Scope note above forbids. What this
section does carry, below, is the disposition of findings raised against the
gate itself — a record, not a contract.

> **Two findings from the W2108 audit sat deferred with no owner, and both are
> now closed.** One: `head -1` collapsed multiple anchors for a single id — one
> auditor read that as a suppressed STALE tier, another independently judged it
> defensible. Two: the canon self-exclusion matched an exact path string, so an
> aliased `--ports-parent`, or a vendored copy of this file inside a port, would
> have credited that port with every anchor it found. Both were filed rather
> than patched, because each was read as a judgement call about intent rather
> than a defect. **D293** closed both, with self-test cases that fail against
> the pre-fix script; the measurements and the bash/PowerShell split stay in the
> script header, beside the code they describe. What belongs *here* is the
> disposition itself. A finding deferred by an explicit decision has no owner
> and no expiry while it lives only in a script comment — which is how these two
> outlived three rounds and became more wrong than when they were filed. Record
> the decision in the entry it governs, or in this section when it governs the
> gate rather than a rule.

> **The fleet scan stays out of the pass/fail suite, and the reason changed
> under it.** Until W2121 the script's own header gave its exit-1 result as the
> justification — anchors were still MISSING fleet-wide, so wiring it in would
> have installed a permanently-red gate. W2119 closed the last of
> the last of those cells, and the scan no longer reports drift, which retires
> that reason entirely. Take the result from a live run, not from this
> sentence.
> It is not wired in anyway, on grounds that do not depend on the tally: a bare
> run measures eleven subjects -- this repository, eight sibling ports and two
> vendored catalogs -- ten of which this repo does not control, so a red result
> usually means another repository has work in flight rather than that the
> change under test broke anything, and STALE is the correct intermediate state
> of a deliberate version bump rather than a fault. A recorded deferral is not
> one of the grounds — deferred cells cannot make the script exit non-zero.
> What is gated is `--self-test`, which is hermetic. Revisit this if the scan
> ever gains a mode scoped to a single repository — and before wiring it into
> anything automated, close **D301**, which records that the `--ports-parent`
> and `--canon` overrides are not confined to the fleet trees. That is harmless
> while the scan is advisory and a caller needs local shell access to set argv;
> it is the property that has to hold first if that ever stops being true.

## How to read this file

Every rule below is one H3 entry with the same seven parts in the same order:
an anchor comment, **Substance**, **Provenance**, **Defect trace**, **Port-side
anchor**, **Applicability** (a fenced JSON block), and **History**. An entry may
add entry-specific prose notes after those seven parts; they carry no
machine-readable content and no consumer reads them.

**The applicability blocks are the machine-readable interface.** A consumer
extracts every fenced `json` block in document order: the **first** is the port
registry, and **every block after it is one rule entry**. There are no optional
keys and no per-entry special cases — a consumer that needs an `if` for a
particular rule id has found a defect in this file, not in itself.

**Positional extraction is guarded, not trusted.** Every block is
self-identifying — the registry by its `canon_schema_version` key, every entry by
its `id` key — and **a consumer MUST validate that discriminator rather than
relying on position alone.** Correspondingly, **no `json`-tagged fence may appear
in this file except the registry and the entries**: an illustrative JSON example
inside an entry's prose would silently become a phantom rule and shift the index
of every block after it. Illustrate with a table, prose, or a fence tagged as
something other than `json`. The two halves cover each other — the prohibition
keeps the file honest, the discriminator check means a consumer survives it being
broken.

**`applies_to` is normative, not observational.** It records what a port *must*
carry, never what it currently *does* carry. A port failing an entry is what the
drift check exists to report; it is never grounds for editing that port's status
to `not_applicable` to make the report green.

**Closed vocabularies.** A canon that requires ports to close their vocabularies
must close its own. Entry `status` is `active` | `superseded`; `provenance` is
`quoted` | `synthesized-from-shipped-fixes`; `check` is `anchor` | `property`;
port `status` is `required` | `not_applicable` | `deferred`. **`variant` is
closed at `""` (no divergence), `four-section-keys`, `five-section-keys`, and
`lib-matrix`** — adding a value means adding it here, in the same edit, with the
entry's Substance explaining it.

**`variant` is a property of a rule in a port, not of the port.** The same port
legitimately carries different `variant` values on different entries, because it
answers "how does *this rule* land differently here" — `stride-copilot-lite` is
`four-section-keys` on `verdict-note` and `lib-matrix` on `row-precedence`, and
both are correct. **Do not read a port's structure out of one entry's `variant`,
and do not try to make them agree across entries.**

### The anchor

Each entry declares an anchor that ports embed beside their own voicing of the
rule. It is an HTML comment containing the word *canon*, immediately followed by
a colon, then the entry's `id`, a space, and `v` followed by the version integer
— exactly as written on the line under each H3 heading below.

The JSON carries `id` and `version` as separate keys and **never** a composed
anchor string. The anchor is derivable from those two keys, so an anchor that
disagrees with its own entry is structurally impossible, and the count of anchor
comments in this file stays equal to the number of entries.

### The port registry

`dir` is a directory name relative to the **parent** of this repository's root,
not to this repository. The canon lives in `stride/`, which cannot see its
sibling ports from the inside; a consumer resolving `dir` against the stride repo
root will find nothing and wrongly report every port missing.

**`dir` is one path segment, and a consumer must enforce that.** It matches
`^[A-Za-z0-9._-]+$` — no path separator, no `..` segment, no leading `/`. A
consumer MUST reject an entry whose `dir` violates that shape, and MUST resolve
it as exactly one level above this repository's root and never deeper. The
constraint is stated because the instruction above sends a consumer *outside*
its own repository to find each port: an implementer who resolves `dir` by naive
string concatenation, against a registry someone later edits, would read paths
the canon never intended to name. Stating the field's lexical shape closes that
without costing the no-special-cases promise — it is one check on every entry,
not a rule per entry.

**On "five ports".** The goal text that commissioned this file says the canon
covers "the five ports that exist today". That five is the five **non-Claude
runtime** ports — codex, copilot, gemini, opencode, pi. It does not count the
`stride` source itself or the two lite variants, all of which exist and all of
which owe these rules. The registry therefore names **nine** ports explicitly
rather than relying on "five" as an integer, which is what the acceptance
criterion asks for: the matrix names the ports it covers.

**`stride-opencode-lite` was in the registry and out of scope, and is now in
scope.** While G403 was unshipped its repository was unscaffolded, so it carried
`"exists": false` and every entry gave it `"status": "deferred"`. It was recorded
present-with-a-status rather than omitted, so that the day G403 shipped it would
become in scope by flipping fields rather than by reworking the matrix or any
anchor audit that had read it — and that is exactly how the transition was
performed, in D291, once the port shipped at `v0.1.0`. Omitting it silently would
have made "not yet built" indistinguishable from "never considered"; keeping the
row is also what made the staleness visible, because a deferred row that outlives
its reason is a row someone can find.

```json
{
  "canon_schema_version": 1,
  "ports": [
    {"id": "stride",              "family": "claude",   "dir": "stride",              "exists": true,  "note": "Source of record; every other port is shaped from it."},
    {"id": "stride-codex",        "family": "codex",    "dir": "stride-codex",        "exists": true,  "note": "Full port."},
    {"id": "stride-copilot",      "family": "copilot",  "dir": "stride-copilot",      "exists": true,  "note": "Full port."},
    {"id": "stride-copilot-lite", "family": "copilot",  "dir": "stride-copilot-lite", "exists": true,  "note": "Lite variant; carries its decision matrix in lib/select_workflow_branch.md, not skills/."},
    {"id": "stride-gemini",       "family": "gemini",   "dir": "stride-gemini",       "exists": true,  "note": "Full port."},
    {"id": "stride-lite",         "family": "claude",   "dir": "stride-lite",         "exists": true,  "note": "Lite variant; carries its decision matrix in lib/select_workflow_branch.md, not skills/."},
    {"id": "stride-opencode",     "family": "opencode", "dir": "stride-opencode",     "exists": true,  "note": "Full port."},
    {"id": "stride-pi",           "family": "pi",       "dir": "stride-pi",           "exists": true,  "note": "Full port. Its reviewer agent is nested at extensions/subagent-dispatch/agents/stride-task-reviewer.md, not at a top-level agents/ directory; skills/stride-workflow/SKILL.md carries only a fallback self-review checklist for when custom agents are unavailable."},
    {"id": "stride-opencode-lite","family": "opencode", "dir": "stride-opencode-lite","exists": true,  "note": "Lite variant. Deferred on every entry while G403 was unshipped; scaffolded and tagged v0.1.0, and brought into scope by D291. Unlike the other lite variants it carries its decision matrix in skills/stride-opencode-lite-workflow/SKILL.md, not lib/, so it takes the unqualified variant on the matrix entries."}
  ]
}
```

**The first drift run was red in every anchor cell, and that was expected.** No
port carried any anchor for any rule at the time: the anchor contract is
introduced by this file, so it necessarily postdated every port. With five
entries against the ports then in scope, every non-deferred cell reported MISSING
on that first run, including entries whose rule the port already carried in
substance (`verdict-note` was the clearest case: D240 ported it fleet-wide, and
it still reported MISSING everywhere until the anchors were placed). That first
report was a work list, not a verdict on the fleet or on the checker, and it has
since been worked off — **do not read the passage above as current fleet
state.** The live run is the only authority on that; take the tally from
`scripts/check-port-canon.sh`, never from a sentence in this file. **The correct
response to a MISSING cell is to place the anchor, never to edit `applies_to` to
make the report green** — which this file forbids twice, and means both times.

**Anchors are checked per port directory, not per file.** Ports keep these rules
in structurally different places — full ports in `skills/stride-workflow/` and
`skills/stride-subagent-workflow/`; `stride-copilot-lite` and `stride-lite` in
`lib/select_workflow_branch.md`; `stride-opencode-lite` in
`skills/stride-opencode-lite-workflow/`, so "lite variant" does **not** imply
`lib/`; and `stride-pi` splitting them — three at the ordinary
`skills/stride-workflow/` path, but its reviewer anchor nested under
`extensions/subagent-dispatch/agents/`, because it ships no top-level `agents/`
directory. A check that expects a fixed path finds nothing in several of the nine
and reports false misses — which is why the checker searches the port directory
instead of a path, and why this passage names shapes rather than a count. Take
the actual anchor sites from a live run, which prints the file and line it
matched for every cell.

## Rules

### 1. A failed section verdict must carry a substantive note — `verdict-note`

<!-- canon:verdict-note v1 -->

**Substance.** When a reviewer emits a section verdict of `failed` — on
`testing_strategy`, `patterns`, `pitfalls`, `security_considerations`, or
`behaviour_test_matrix` — the accompanying `note` is REQUIRED and must name the
specific violation or gap in at least 20 non-whitespace characters. A
placeholder, a stub, a `TODO`, an empty string, or a bare restatement of the
status is invalid output. Paired with it is the consistency rule: a `failed`
verdict must also be backed by at least one `issues[]` entry of the matching
category. Having nothing substantive to write in the note is a signal that the
verdict itself is wrong, not that the note is optional — but that never licenses
downgrading a verdict that IS backed by an issue.

**Provenance.** Quoted. The rule is stated normatively at
`stride/agents/task-reviewer.md` under "Verdict-note rule (anti-placeholder)"
and "Consistency rule"; that file remains the source.

**Defect trace.** D222 (the placeholder note observed in the wild), D231 (the
server began rejecting note-less failed verdicts unconditionally, so this stopped
being advisory), D240 (ported across the fleet, establishing that ports voice it
differently).

**Port-side anchor.** Beside the port's own statement of the failed-verdict note
requirement, wherever its reviewer contract or self-review checklist defines
section verdicts.

**Applicability.** `variant` records a genuine structural difference in how many
section verdicts the port's prompts enumerate — not a difference in the rule.
The lite variants have no `behaviour_test_matrix` anywhere in their trees, so
their reviewers list four section keys; the rule binds all four identically.
`stride-pi` is also `four-section-keys`: its reviewer agent enumerates four
section tiles and carries no `behaviour_test_matrix` key, even though the port's
fallback self-review checklist mentions the field. That divergence from the
source's five is real and is recorded here rather than smoothed over — see the
`reason` on its row for where the rule actually lives in that port.

```json
{
  "id": "verdict-note",
  "version": 1,
  "status": "active",
  "superseded_by": null,
  "provenance": "quoted",
  "defects": ["D222", "D231", "D240"],
  "check": "anchor",
  "check_hint": "Anchor sits beside the port's failed-verdict note requirement in its reviewer contract or self-review checklist.",
  "applies_to": [
    {"port": "stride",              "status": "required",       "variant": "five-section-keys",             "reason": ""},
    {"port": "stride-codex",        "status": "required",       "variant": "five-section-keys",             "reason": ""},
    {"port": "stride-copilot",      "status": "required",       "variant": "five-section-keys",             "reason": ""},
    {"port": "stride-copilot-lite", "status": "required",       "variant": "four-section-keys",             "reason": "No behaviour_test_matrix anywhere in the tree, so the reviewer enumerates four section verdicts."},
    {"port": "stride-gemini",       "status": "required",       "variant": "five-section-keys",             "reason": ""},
    {"port": "stride-lite",         "status": "required",       "variant": "four-section-keys",             "reason": "No behaviour_test_matrix anywhere in the tree, so the reviewer enumerates four section verdicts."},
    {"port": "stride-opencode",     "status": "required",       "variant": "five-section-keys",             "reason": ""},
    {"port": "stride-pi",           "status": "required",       "variant": "four-section-keys",             "reason": "Reviewer agent is nested at extensions/subagent-dispatch/agents/stride-task-reviewer.md, not a top-level agents/; it enumerates four section tiles and carries no behaviour_test_matrix key."},
    {"port": "stride-opencode-lite","status": "required",       "variant": "four-section-keys",             "reason": "No behaviour_test_matrix anywhere in the tree, so the reviewer enumerates four section verdicts."}
  ]
}
```

**History.** v1 — seeded from D222/D231/D240.

### 2. The decision matrix is the sole decision point — `decision-matrix-authority`

<!-- canon:decision-matrix-authority v1 -->

**Substance.** The Step 3 decision matrix is the SOLE decision point for every
column it carries — Decompose, Explore, Plan, Review, and Isolate. No prose,
section, flowchart, or quick-reference card anywhere in a port may state a
second, separately-satisfiable condition for any of those columns; where such
text exists it describes what the matrix already decided and defers to it, and
where it appears to give an independent trigger, **the matrix wins**. A port that
mirrors the matrix (typically in its subagent-workflow skill) must agree with it
row for row, and the Step 3 matrix is authoritative where they diverge.

**Provenance.** Quoted. Stated normatively in
`stride/skills/stride-workflow/SKILL.md` immediately below the Step 3 decision
matrix; that file remains the source.

**Defect trace.** D221 (two independently-satisfiable triggers for the same
column, which corrupted the telemetry that reads them), D232 (the same defect
recurring in a second column).

**Port-side anchor.** Beside the port's Step 3 decision matrix, next to its own
statement of the sole-decision-point rule.

**Applicability.** Required everywhere, the lite variants included: each carries
a decision matrix of its own, so a competing trigger can arise there exactly as it
can in a full port. Where that matrix lives differs — `stride-copilot-lite` and
`stride-lite` keep it in `lib/select_workflow_branch.md`, while
`stride-opencode-lite` keeps it in `skills/stride-opencode-lite-workflow/` — which
is why the two carry the `lib-matrix` variant on their rows below and the third
does not.

```json
{
  "id": "decision-matrix-authority",
  "version": 1,
  "status": "active",
  "superseded_by": null,
  "provenance": "quoted",
  "defects": ["D221", "D232"],
  "check": "anchor",
  "check_hint": "Anchor sits beside the port's decision matrix, wherever that matrix lives in the port's tree.",
  "applies_to": [
    {"port": "stride",              "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-codex",        "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-copilot",      "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-copilot-lite", "status": "required", "variant": "lib-matrix", "reason": "Matrix lives in lib/select_workflow_branch.md rather than skills/stride-workflow/."},
    {"port": "stride-gemini",       "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-lite",         "status": "required", "variant": "lib-matrix", "reason": "Matrix lives in lib/select_workflow_branch.md rather than skills/stride-workflow/."},
    {"port": "stride-opencode",     "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-opencode-lite","status": "required", "variant": "",           "reason": "Carries its decision matrix in skills/stride-opencode-lite-workflow/SKILL.md rather than lib/select_workflow_branch.md as the other lite variants do, so it takes the unqualified variant rather than lib-matrix."}
  ]
}
```

**History.** v1 — seeded from D221/D232.

### 3. Decision-matrix row precedence and the complexity fallback — `row-precedence`

<!-- canon:row-precedence v1 -->

**Substance.** More than one matrix row can match a task, so rows are resolved
**top-down in a fixed order**, and exactly one row survives for every task:

1. **Branch A first** — goal type, large-and-undecomposed, or a 25+ hour
   estimate routes to decomposition, and no other row applies.
2. **Then `small, 0-1 key_files`, whatever the task's type.** This row is an
   economics floor, not a statement about work kind: a one-file change is a
   one-file change whether it is labelled `work` or `defect`.
3. **Then `Defect type`,** for any remaining defect — it outranks the complexity
   rows because the row exists to say something about defects specifically. Its
   `Skip (unless large)` resolves as: a **large** defect gets `Plan = YES`, every
   other defect gets `Plan = Skip`.
4. **Then the complexity row** — `small, 2+ key_files`, `medium`, or `large`.
5. **Then the fallback row, and only then.**

The fallback row is `Complexity absent or unrecognised`, and it fires **only**
when `complexity` is missing or is not one of the three known values — it is a
fallback, never a tiebreaker. Its behaviour is to run everything: Decompose Skip,
Explore YES, Plan YES, Review YES, Isolate YES.

Both halves are load-bearing. Without the order, a **medium defect** matches both
`medium (any)` and `Defect type` with conflicting answers, and a **small
0-1-key_files defect** matches two rows that disagree about whether exploration
and review run at all. Without the fallback row, a task with missing or unknown
complexity matches **zero** rows and the outcome is undefined. Step 2's placement
above step 3 is deliberate: putting the type row first would flip Explore, Review
and Isolate to YES for every small one-file defect.

**Provenance.** Quoted. Stated normatively under "Row precedence" in
`stride/skills/stride-workflow/SKILL.md`, whose Step 3 matrix carries the
`| Complexity absent or unrecognised | Skip | YES | YES | YES | YES |` row.

**Defect trace.** D253 (the rule is enforced in the source and absent from every
port). D221 and D232 are its lineage — this is the same ambiguity those defects
addressed, relocated from the prose *around* the matrix to the rows *inside* it.

**Port-side anchor.** Beside the port's Step 3 decision matrix, next to its own
statement of the precedence order — wherever that normative statement lives,
which is the workflow skill in most ports, the subagent-workflow skill where
that is the matrix rather than a mirror, and the helper in the lib-matrix
ports. Where a port restates the matrix a second time, whether in a
subagent-workflow mirror or a derived table in its workflow skill, that
restatement carries no anchor. One anchor per port directory.

**Applicability.** Required everywhere. **This entry reported MISSING for every
port on the drift check's first run**, and it is worth keeping why on the record,
because the two halves of that sentence rested on different facts: the **rule**
was present in exactly one of the nine ports — `stride`, the source, which
carries the `Complexity absent or unrecognised` row and the precedence list that
this entry quotes — and absent from the others that existed. The **anchor** was
present in none of them, `stride` included. `check: "anchor"` tests the anchor,
so every port reported MISSING on that run, and `stride` reported MISSING while
carrying the rule. That was never a reason to soften the entry: the rule IS
enforced canonically in the source, and the ports are what drifted. The anchors
have since been placed across the fleet; consult a live run for which cells are
outstanding today.

**Delivery note (historical).** D253 would have hand-ported this rule to ten
tables across the port repositories then in scope — each port's Step 3 matrix plus
its subagent-workflow mirror. It was seeded here instead and delivered by the sync
task, so those tables were edited once rather than twice. The anchors have since
landed; whether D253 itself is recorded closed is a board question, not one this
file can answer — check the board rather than reading closure out of this note.

```json
{
  "id": "row-precedence",
  "version": 1,
  "status": "active",
  "superseded_by": null,
  "provenance": "quoted",
  "defects": ["D253", "D221", "D232"],
  "check": "anchor",
  "check_hint": "One anchor per port directory, beside the port's normative matrix. Any second restatement of it carries no anchor.",
  "applies_to": [
    {"port": "stride",              "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-codex",        "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-copilot",      "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-copilot-lite", "status": "required", "variant": "lib-matrix", "reason": "Matrix lives in lib/select_workflow_branch.md rather than skills/stride-workflow/. No table in this port carries a Decompose or an Isolate column, and the matrix is restated, unanchored, in the workflow skill and the README."},
    {"port": "stride-gemini",       "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-lite",         "status": "required", "variant": "lib-matrix", "reason": "Matrix lives in lib/select_workflow_branch.md rather than skills/stride-workflow/. No table in this port carries a Decompose or an Isolate column, and the matrix is restated, unanchored, in the workflow skill and the README."},
    {"port": "stride-opencode",     "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-opencode-lite","status": "required", "variant": "",           "reason": "No subagent-workflow mirror exists in this port, so the rule has a single statement site rather than two. Its matrix carries three outcome columns, not five: there is no Decompose column and no Isolate column, so the precedence order resolves over Explore, Plan and Review alone. It also carries no separate defect row: every task file gets a complexity value from create-decomposer, so a defect follows its complexity row like any other task."}
  ]
}
```

**History.** v1 — seeded from D253, carrying the lineage of D221/D232.

### 4. The `reason_code` skip vocabulary is six closed values — `reason-code-vocabulary`

<!-- canon:reason-code-vocabulary v1 -->

**Substance.** A `workflow_steps` entry with `dispatched: false` may carry a
`reason_code` alongside its prose `reason` — **alongside, never instead of**: the
code is what the compliance dashboard aggregates, the prose is what a human
reads. The vocabulary is closed at six values; a code outside it is rejected with
a `422`, while omitting the key entirely is always valid.

| Code | Use when |
|---|---|
| `decision_matrix_skip` | The decision matrix says this task's row skips this step |
| `ran_inline` | The step's work was performed, but in the main loop rather than by a dispatched subagent |
| `hook_body_empty` | The `.stride.md` section body is empty, so the hook is a no-op |
| `subsumed_by_task_spec` | The task specification already settled what this step would have decided |
| `folded_into_prior_step` | An earlier step already produced this step's output |
| `matrix_deviation` | The matrix called for this step and it was deliberately not run |

`matrix_deviation` is the one value that records **non-compliance**, and that is
why it exists: a step the matrix called for and that did not run must be reported
with that code, never dressed up as `decision_matrix_skip`.

**Provenance.** Quoted. Stated normatively under "Picking a `reason_code`" in
`stride/skills/stride-workflow/SKILL.md`. The vocabulary was derived by
classifying the skip reasons actually persisted on the production board, which is
the D239 style this canon follows: entries come from what shipped, not from
speculation.

**Defect trace.** D239.

**Port-side anchor.** Beside the port's own `reason_code` table or list, wherever
it documents `workflow_steps` skips.

**Applicability.** Required wherever a port emits `workflow_steps`. Read the
`applies_to` rows below for who that is today rather than taking a count from this
sentence. **`stride-lite` and `stride-opencode-lite` state the same structural
fact about themselves** and are both recorded `deferred` with those grounds as
their reason: neither emits a `workflow_steps` object and neither has a
completion endpoint, so a closed set of rejection codes has nothing to reject
against. Both rows are the one sanctioned shape of a narrowed cell — a
structural fact about the port, recorded with its reason — and not the
forbidden move of narrowing applicability to green a report. On the first run
only the source carried the vocabulary; consult a live run for which cells are
outstanding today.

```json
{
  "id": "reason-code-vocabulary",
  "version": 1,
  "status": "active",
  "superseded_by": null,
  "provenance": "quoted",
  "defects": ["D239"],
  "check": "anchor",
  "check_hint": "Anchor sits beside the port's reason_code table, wherever it documents workflow_steps skips.",
  "applies_to": [
    {"port": "stride",              "status": "required", "variant": "", "reason": ""},
    {"port": "stride-codex",        "status": "required", "variant": "", "reason": ""},
    {"port": "stride-copilot",      "status": "required", "variant": "", "reason": ""},
    {"port": "stride-copilot-lite", "status": "required", "variant": "", "reason": ""},
    {"port": "stride-gemini",       "status": "required", "variant": "", "reason": ""},
    {"port": "stride-lite",         "status": "deferred", "variant": "", "reason": "Emits no workflow_steps object and has no completion endpoint, so the closed six-value set has nothing to reject against. Four of the six codes name conditions its loop cannot reach, and the remaining two would restate its own skip table in imported spelling. The port records these same grounds itself in skills/stride-lite-workflow/SKILL.md. Reopen if a completion API and a workflow_steps payload ever land there."},
    {"port": "stride-opencode",     "status": "required", "variant": "", "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode-lite","status": "deferred", "variant": "", "reason": "Emits no workflow_steps object and has no completion endpoint, so the closed six-value set has nothing to reject against. Four of the six codes name conditions its loop cannot reach, and the remaining two would restate its own two-value skip table in imported spelling. The port records these same grounds itself in skills/stride-opencode-lite-workflow/SKILL.md. Reopen if a completion API and a workflow_steps payload ever land there."}
  ]
}
```

**History.** v1 — seeded from D239.

### 5. A nested fence is legitimate only when the outer one is wider — `fence-nesting`

<!-- canon:fence-nesting v1 -->

**Substance.** Where a markdown file in a port embeds one fenced code block
inside another — a prompt quoting a JSON payload, a skill quoting a hook body —
the **outer fence must be strictly wider** than every fence nested inside it. A
fence of the *same* width as the block it sits in terminates that block early,
so the remainder of the file renders as prose and the agent reading it silently
loses the rest of the instruction.

**The rule is about both fence characters, not just backticks.** CommonMark
treats backtick and tilde fences alike, and **a closer must use the same
character as its opener — so a backtick fence never closes a tilde fence.** A
check that walks only backticks passes the identical defect written with tildes,
which is why the shipped walker covers both.

Two consequences follow, and both are the point of the rule:

- **Counting or balancing fences cannot detect this.** The defective file that
  produced D217 carried six fence lines that balanced perfectly while pairing
  wrongly; a balance check reports it clean. A check must walk fences the way a
  renderer does, and report two distinct defects: an opener that reaches
  end-of-file unclosed, and a fence of the same width as its enclosing block that
  carries an info string.
- **The fix is to widen the outer fence, not to narrow the inner one.** Both
  shipped fixes did exactly that.

**Provenance.** **Synthesized from shipped fixes — not quoted.** No *normative*
statement of this rule exists in any port's skill or agent contract; it survives
only as narrative in the D217 changelog entry at `stride-lite/CHANGELOG.md`, and
as executable logic in that port's `test/smoke.sh`. Neither binds another port,
and neither is where a maintainer would look. The substance above is authored
here, derived from that narrative, from the walker's own comments, and from the
two fixes named below. This entry is disclosed
as authored rather than presented as a citation, but it is the opposite of
speculative: it is the rule two independent defects were fixed by applying, in
two different repositories, which is precisely the D239 standard this canon
follows.

**Defect trace.** Two defects, and their shipped work took **different shapes** —
worth stating exactly, because this entry has no normative source to fall back on
and its citations are its whole evidentiary basis.

- **D243** — `stride-copilot-lite` commit `6980f29`, "close the runaway fence in
  the reviewer prompt with a four-backtick wrapper". This one *is* a fence
  widening, and it is the direct instance of the rule.
- **D217** — `stride-lite` commit `2af0ff1`, "agents/task-reviewer.md nests a
  3-backtick json fence inside a 3-backtick markdown fence". **This commit
  contains no fence edit**, and says so in its own message: the widening had
  already landed incidentally under W2016 (`9055147`). What `2af0ff1` shipped is
  the **check** — `fence_defect()` in `stride-lite/test/smoke.sh`, a
  renderer-faithful fence walker, plus the changelog entry that states the rule
  directly: *a nested fence is legitimate only when the outer one is wider*.

**That walker is the reference implementation of this entry's property check**,
and it is the artifact to read before writing another one — it is still the only
one in the fleet, and only a minority of the nine ports carry a `test/smoke.sh`
at all. Enumerate that minority from the tree rather than from this sentence: it
grew by one when `stride-opencode-lite` came into scope, and a count written here
goes stale the next time a port gains a suite.

**Port-side anchor.** None. This is a prohibition on file structure, not a rule
with a host paragraph to sit beside, so there is nowhere in a port for an anchor
to live.

**Applicability.** Required everywhere, and checked as a **property** rather than
an anchor. `check: "property"` is data the consumer switches on — the key set is
identical to every other entry, so this is not a format special case. The
property is byte-verifiable across a port's whole markdown tree, which is a
stronger check than an anchor's presence, not a weaker one.

**A note on this file's own examples.** This entry deliberately states the rule
in prose instead of demonstrating it with a worked nested-fence example. A
demonstration would have to contain the defective shape, and the canon must not
ship a file that trips its own rule.

```json
{
  "id": "fence-nesting",
  "version": 1,
  "status": "active",
  "superseded_by": null,
  "provenance": "synthesized-from-shipped-fixes",
  "defects": ["D243", "D217"],
  "check": "property",
  "check_hint": "Walk every fenced block in the port's markdown as a renderer would, in BOTH fence characters: a closer must use the same character as its opener, so a backtick fence never closes a tilde fence. Report an opener that reaches EOF unclosed, and any fence of the same width as its enclosing block that carries an info string. Do not count or balance fences; both report the D217 shape clean. Reference implementation: fence_defect() in stride-lite/test/smoke.sh.",
  "applies_to": [
    {"port": "stride",              "status": "required", "variant": "", "reason": ""},
    {"port": "stride-codex",        "status": "required", "variant": "", "reason": ""},
    {"port": "stride-copilot",      "status": "required", "variant": "", "reason": ""},
    {"port": "stride-copilot-lite", "status": "required", "variant": "", "reason": ""},
    {"port": "stride-gemini",       "status": "required", "variant": "", "reason": ""},
    {"port": "stride-lite",         "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode",     "status": "required", "variant": "", "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode-lite","status": "required", "variant": "", "reason": ""}
  ]
}
```

**History.** v1 — authored from the D243 and D217 fixes.

## Discovery — how a maintainer reaches this file

**The edit-site back-reference is installed (D283), and this section records
what now points here so the next maintainer does not have to rediscover it.**
Read the groups below as a description to re-verify, not a tally to trust: the
previous version of this section led with a count and asserted something false
about its own fleet, and any figure here is true only of the day it was
written. Routes fall into three groups.

**Inside this repository.** The README names the release gate that reads this
file; the changelog records that gate and this mechanism;
`scripts/check-port-canon.sh` and its PowerShell twin name it because they parse
it, and the hook suite exercises them.

**Across the fleet.** Two ports cite this document by path and rule id where they
record why they have not adopted `reason-code-vocabulary` — `stride-lite` and
`stride-opencode-lite`. Read "not adopted" as plain English rather than as a
status value: both rows are recorded `deferred`, on the same structural ground.
Consult a live run for the statuses in force today rather than taking them from
this sentence. `stride-copilot` and `stride-gemini` name it in their changelogs.

> **The `stride-opencode-lite` citation once contradicted this file's own
> registry, and no longer does.** The registry carried `"exists": false` for that
> port and deferred it on every entry after the repository had already been
> scaffolded and tagged `v0.1.0` — and because the drift check skips a port it
> believes absent, that port was printed among the clean repos without a single
> rule cell being examined. **D291** performed the registry transition described
> under "Changing this file": `exists` is now `true`, four entries carry
> an applicable status and `reason-code-vocabulary` carries `deferred` with its
> reason — D291 recorded that row `not_applicable`, and W2118 aligned it with
> `stride-lite`'s identically-grounded row — and the port is examined on every
> run. The episode is kept here because it is the failure mode this file most
> wants a reader to recognise — a gate reporting a subject clean that it never
> looked at.

**At the edit site — the direction that was missing.** Each source file in this
repository that states or restates a governed rule now carries a back-reference
beside it, naming this file by path and the entry id, so that editing the rule
surfaces the obligation without the editor having to already know this document
exists.

That direction is the one that matters for the versioning rule below, which
requires a version bump when a rule's **substance** changes. Substance changes
in the source file, not here. Without a pointer at the edit site, a maintainer
editing (say) the Step 3 matrix in `stride/skills/stride-workflow/SKILL.md` got
no signal that the edit crossed port boundaries: the canon kept saying `v1`,
every port kept its `v1` anchor, and the drift check reported green over a fleet
that had drifted — **the failure looked exactly like success**, which is the one
shape a safeguard must not have. That was D283, and the back-references are its
fix.

**What the back-references are, and what they are deliberately not.** Each one
names this file and the entry id it is governed by, and states that a substance
change owes a version bump here. **None restates the governed rule** — a second
copy of the substance is precisely the drift the Scope note above forbids, so
the back-reference points at the obligation and stops. Each is voiced in its own
file's idiom rather than in one imported form, per the D240 per-port shaping
precedent.

**Which files carry one, and why each.** Two are this repository's Provenance
sources: `stride/agents/task-reviewer.md` for `verdict-note`, and
`stride/skills/stride-workflow/SKILL.md` for the other three entries, at three
separate sites. A third, `stride/skills/stride-completing-tasks/SKILL.md`, is
named by the Scope note above as a source of record and restates two of the
governed rules. The fourth, `stride/skills/stride-subagent-workflow/SKILL.md`,
is neither a Provenance source nor named in the Scope note — it holds the
decision-matrix mirror, which the `row-precedence` entry's Port-side anchor
addresses by name. The fifth, `stride/README.md`, is named by neither the
entries nor the Scope note either; it restates the `reason_code` vocabulary, and
D292 gave it a back-reference on that ground alone — which is what makes this
list an application of the site test rather than of the narrower membership one.
`fence-nesting` has no site here at all: it is provenanced to
`stride-lite` and its Port-side anchor is `None`, so there is nothing in this
repository to install a back-reference beside.

**The test is site-based, and the last known divergence is closed.** The test is
*every site in this repository that states or restates a governed rule* — not
merely the files this document happens to cite. D283 applied it per-file over
four files and recorded the shortfall rather than papering over it: `README.md`
restates the six-value `reason_code` vocabulary and the `matrix_deviation`
clause, and carried no back-reference. **D292** closed that site, so the applied
test and the ideal now coincide, and the claim above is a claim this section can
make. Two consequences worth keeping: the README back-reference carries **no
anchor comment**, because this file assigns one anchor per rule per port
directory and stride's `reason-code-vocabulary` anchor already sits in
`skills/stride-workflow/SKILL.md`. How either checker behaves when a second is
added is the script's contract, not this file's — see the Release gate section,
which stops at the same line and for the same reason. And "no known divergence"
is not "provably
none": it rests on a `reason_code` sweep of this repository at a point in time,
so a new restatement added later owes its own back-reference, and finding one is
a defect to file rather than evidence the test changed. One carve-out the test
needs stating, because the sweep does surface it: **`CHANGELOG.md` is not an edit
site.** It restates governed substance in its historical entries — the D239 entry
enumerates the whole vocabulary — but a released entry is a record of what
shipped, not a statement of the current rule, so there is nothing there for a
back-reference to prompt and editing one to track a rule change would falsify the
record. Sites are the files a maintainer changes to change the rule.

**What remains maintainer-enforced.** The back-reference surfaces the obligation
at the edit site; it does not enforce it. Nothing fails a build when a substance
change lands without a version bump — `scripts/check-port-canon.sh` compares
anchors against entries and cannot see that a rule's *meaning* moved underneath
an unchanged version. So the discipline is now **prompted rather than silent**,
which is the improvement D283 bought, and it is still a human who must act on
the prompt. Say that when handing work to someone who has not read this
section.

## Versioning and supersession

Every seed entry is `v1`, `"status": "active"`, `"superseded_by": null`.

- **A change to a rule's substance bumps the integer** in both the anchor comment
  and the entry's `version` key, and appends a `History` bullet. Every port still
  carrying the previous version reports STALE rather than MISSING — the drift
  check distinguishes the two by comparing the version in the port's anchor
  against the version in the entry.
- **Editorial rewording does not bump the version.** If a port carrying the rule
  correctly would still be carrying it correctly after the edit, the version
  stands.
- **A superseded rule keeps its entry.** Set `"status": "superseded"` and name the
  replacement in `"superseded_by"`, and leave the anchor comment in place. Ids are
  stable forever and are never reused. One consequence to record: once an entry is
  superseded, the count of anchor comments in this file equals the number of
  entries **including superseded ones**, not the number of active rules.
- **A `check: "property"` entry cannot report STALE, and needs its own answer.**
  Staleness is detected by comparing a port's anchor version against the entry's,
  and a property entry has no anchor by design — so bumping `fence-nesting` to
  `v2` would leave every port reporting compliant against the *old* rule. **A
  property entry's version therefore binds the check, not the ports:** on a bump,
  the drift check's own implementation of that property must be updated in the
  same change, and a check that has not been updated must report the entry
  UNVERIFIABLE rather than passing it. This is the one place the file's
  no-per-entry-special-cases promise is genuinely strained; it is stated rather
  than hidden, and it is `check`, not the rule id, that a consumer switches on.
- **`canon_schema_version` versions the *format*, not the rules.** Bump it when
  the shape of the registry or of an entry changes — a key added, removed, or
  re-typed, or a vocabulary above extended. Rule edits never touch it. **A
  consumer meeting a `canon_schema_version` it does not know MUST stop and report
  that, not parse optimistically:** a format it does not understand is exactly
  the case where a confident green report is worst.

## Changing this file

- **Add a rule only when a shipped defect forced it.** An entry with no defect
  trace is a speculation, and a canon of speculations rots exactly like the
  scattered docs it replaces. `defects` is non-empty on every entry.
- **Keep `applies_to` complete.** Every entry lists all nine registry ports, in
  registry order, always. A port that does not owe a rule is recorded
  `not_applicable` **with a reason**, never dropped from the list — that single
  invariant is what lets a consumer read every entry the same way.
- **Never narrow applicability to make a drift report green.** A red report is
  the check working.
- **State substance, not wording.** If an entry cannot be satisfied except by
  copying its exact text, it has overreached into voicing, which D240 established
  belongs to the port.
- **Adding or retiring a port touches every entry, not just the registry.** A new
  port needs a registry row **and** a new `applies_to` element in **every** entry,
  at the registry's position — that is five edits today, and it grows with the
  canon. Retiring one is the same edit in reverse. `stride-opencode-lite` is the
  worked example: when G403 shipped, D291 set its registry `exists` to `true` and
  changed its `status` from `deferred` on each entry it then owed — one registry
  field plus one field per entry, never a row added to only some. Note what that
  transition is **not** licence to do: a port coming into scope owes an
  applicable status on each entry, and `not_applicable` is available only where a
  structural fact about the port makes the rule unreachable, recorded with its
  reason.
- **When an entry's anchor has nowhere to sit, say so rather than improvising.**
  A `check_hint` locates a host paragraph, and for a rule a port has not adopted
  yet that paragraph does not exist — the case that seeded this rule, when
  `row-precedence` and `reason-code-vocabulary` had a host paragraph in almost no
  port. The anchor goes in **only when the port's own voicing of the rule does**,
  and the two land in the same change. An
  anchor placed beside nothing makes the drift check report a compliance the port
  does not have, which is worse than the MISSING it replaced.
