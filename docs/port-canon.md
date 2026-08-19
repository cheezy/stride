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

**`applies_to` is normative, not observational.** It records what a port *must*
carry, never what it currently *does* carry. A port failing an entry is what the
drift check exists to report; it is never grounds for editing that port's status
to `not_applicable` to make the report green.

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

**`stride-opencode-lite` is in the registry and out of scope, deliberately.** Its
repository is unscaffolded — G403 has not shipped and every child task is Backlog
or blocked — so it carries `"exists": false` and every entry gives it
`"status": "deferred"`. It is recorded present-with-a-status rather than omitted,
so that the day G403 ships it becomes in scope by flipping two fields, with no
rework of the matrix or of any anchor audit that read it. Omitting it silently
would make "not yet built" indistinguishable from "never considered".

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
    {"id": "stride-pi",           "family": "pi",       "dir": "stride-pi",           "exists": true,  "note": "Full port with no agents/ directory; reviewer duties run as a self-review checklist in skills/stride-workflow/SKILL.md."},
    {"id": "stride-opencode-lite","family": "opencode", "dir": "stride-opencode-lite","exists": false, "note": "Not scaffolded; G403 has not shipped. Deferred on every entry until it does."}
  ]
}
```

**Anchors are checked per port directory, not per file.** Ports keep these rules
in structurally different places — full ports in `skills/stride-workflow/` and
`skills/stride-subagent-workflow/`, lite variants in `lib/`, and `stride-pi` in a
self-review checklist because it ships no `agents/` directory. A check that
expects a fixed path finds nothing in three of the nine and reports false
misses.

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
`stride-pi` does carry `behaviour_test_matrix`, in a self-review checklist rather
than a reviewer agent, because it ships no `agents/` directory.

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
    {"port": "stride-pi",           "status": "required",       "variant": "five-section-keys-self-review", "reason": "No agents/ directory; the section verdicts live in a Step 5 self-review checklist in skills/stride-workflow/SKILL.md."},
    {"port": "stride-opencode-lite","status": "deferred",       "variant": "",                              "reason": "Repository not scaffolded; G403 has not shipped."}
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

**Applicability.** Required everywhere, including both lite variants: they carry
a decision matrix in `lib/select_workflow_branch.md`, so a competing trigger can
arise there exactly as it can in a full port.

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
    {"port": "stride-opencode-lite","status": "deferred", "variant": "",           "reason": "Repository not scaffolded; G403 has not shipped."}
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
statement of the precedence order. The subagent-workflow mirror does not carry a
second anchor; one anchor per port directory.

**Applicability.** Required everywhere. **This entry is expected to report
MISSING for every port on the drift check's first run** — grepping each port
directory for the precedence rule returns zero matches today, in all eight
existing ports. That is not a reason to soften it: the rule IS enforced
canonically in the source, and the ports are what drifted. It is also the
evidence that the drift check can go red, which a report that came back green
across the board on day one would not have provided.

**Delivery note.** D253 would hand-port this rule to ten tables across five port
repositories — each port's Step 3 matrix plus its subagent-workflow mirror. It is
seeded here instead and delivered by the sync task in this goal, so those tables
are edited once rather than twice; D253 is closed by that sync rather than worked
separately.

```json
{
  "id": "row-precedence",
  "version": 1,
  "status": "active",
  "superseded_by": null,
  "provenance": "quoted",
  "defects": ["D253", "D221", "D232"],
  "check": "anchor",
  "check_hint": "One anchor per port directory, beside its Step 3 matrix. The subagent-workflow mirror carries no second anchor. Expected MISSING everywhere on the first run.",
  "applies_to": [
    {"port": "stride",              "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-codex",        "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-copilot",      "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-copilot-lite", "status": "required", "variant": "lib-matrix", "reason": "Matrix lives in lib/select_workflow_branch.md rather than skills/stride-workflow/."},
    {"port": "stride-gemini",       "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-lite",         "status": "required", "variant": "lib-matrix", "reason": "Matrix lives in lib/select_workflow_branch.md rather than skills/stride-workflow/."},
    {"port": "stride-opencode",     "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "",           "reason": ""},
    {"port": "stride-opencode-lite","status": "deferred", "variant": "",           "reason": "Repository not scaffolded; G403 has not shipped."}
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

**Applicability.** Required everywhere — every port emits `workflow_steps`. Today
only the source carries the vocabulary, so this entry is expected to report
MISSING for the other eight.

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
    {"port": "stride-lite",         "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode",     "status": "required", "variant": "", "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode-lite","status": "deferred", "variant": "", "reason": "Repository not scaffolded; G403 has not shipped."}
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
only as narrative, in the D217 changelog entry at `stride-lite/CHANGELOG.md`,
which states the rule directly but binds nothing and is not where a port would
look for it. The substance above is authored here, derived from that narrative
and from the two fixes named below. This entry is disclosed
as authored rather than presented as a citation, but it is the opposite of
speculative: it is the rule two independent defects were fixed by applying, in
two different repositories, which is precisely the D239 standard this canon
follows.

**Defect trace.** D243 — `stride-copilot-lite` commit `6980f29`, "close the
runaway fence in the reviewer prompt with a four-backtick wrapper". D217 —
`stride-lite` commit `2af0ff1`, "agents/task-reviewer.md nests a 3-backtick json
fence inside a 3-backtick markdown fence", whose changelog entry states the rule
directly: *a nested fence is legitimate only when the outer one is wider*.

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
  "check_hint": "Walk every fenced block in the port's markdown as a renderer would. Report an opener that reaches EOF unclosed, and any fence of the same width as its enclosing block that carries an info string. Do not count or balance fences; both report the D217 shape clean.",
  "applies_to": [
    {"port": "stride",              "status": "required", "variant": "", "reason": ""},
    {"port": "stride-codex",        "status": "required", "variant": "", "reason": ""},
    {"port": "stride-copilot",      "status": "required", "variant": "", "reason": ""},
    {"port": "stride-copilot-lite", "status": "required", "variant": "", "reason": ""},
    {"port": "stride-gemini",       "status": "required", "variant": "", "reason": ""},
    {"port": "stride-lite",         "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode",     "status": "required", "variant": "", "reason": ""},
    {"port": "stride-pi",           "status": "required", "variant": "", "reason": ""},
    {"port": "stride-opencode-lite","status": "deferred", "variant": "", "reason": "Repository not scaffolded; G403 has not shipped."}
  ]
}
```

**History.** v1 — authored from the D243 and D217 fixes.

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
