# Porting the G446–G448 plugin fixes to the Stride variants

This is the porting guide for the three improvement goals filed on 2026-10-02
after a measured review of the `stride` plugin:

- **G446 — accuracy**
- **G447 — speed**
- **G448 — token usage**

The user's priority order was accuracy, then speed, then tokens. Each fix lands
in `stride` first. This document records what each fix changes, why it was made,
which mechanisms a port needs to carry it, and how to verify the port.

**Keep this file current.** When a task in these goals lands in `stride`, change
its status below from *planned* to *landed*. Then replace its "Planned change"
paragraph with what actually shipped, including the commit and the release. A
planned section describes intent, not shipped behaviour. Do not port from a
planned section.

## Status

| Task | Goal | Fix | Status in `stride` |
|---|---|---|---|
| W2248 | G446 | The post-claim hook writes the claimed task to `.stride/.task-<IDENTIFIER>.json` | **landed in 1.81.0** |
| W2249 | G446 | Explorer, planner and reviewer dispatches pass `TASK_FILE` instead of retyped task fields | **landed in 1.81.0** |
| W2250 | G446 | Dispatcher mode becomes the default for multi-task requests, with an opt-out | **landed in 1.83.0** |
| W2251 | G446 | Step 0 warns when the installed plugin is older than the published pin | **landed in 1.83.0** |
| W2252 | G447 | Round two of review must be earned | **landed in 1.81.0** |
| W2253 | G447 | Carry the `review-round-cap` v2 canon change to every port | planned. **This document is its input.** |
| W2254 | G447 | The main agent reads key files while the explorer runs, with no edits until it reports | **landed in 1.81.0** |
| W2255 | G447 | The Stop gate does not block while a dispatched stride subagent is still running | **landed in 1.81.0** |
| W2256 | G448 | Discovery uses a slim `GET /api/tasks/next`; the task body comes from the claim | **landed in 1.81.0** |
| W2257 | G448 | Move rationale out of `stride-workflow` SKILL.md and `review-block-extraction.md` | **landed in 1.83.0** |
| W2258 | G448 | Move rationale out of `stride-completing-tasks` SKILL.md and `agents/task-reviewer.md` | **landed in 1.83.0** |
| W2259 | G448 | Measure the token and wall-clock effect of all three goals | measured; released in 1.84.0 — [`token-measurement-g446-g448.md`](token-measurement-g446-g448.md) |

## The evidence behind the goals

These figures were measured on 2026-10-02 from the 9-task G439 session (transcript
`0286faaf`, with `stride` 1.78.0 installed). Usage was deduplicated by message id.
Counting content-block records instead roughly doubles the request count.

| Measure | Value |
|---|---|
| Wall clock | 231 min |
| Main-loop requests | 518 |
| Main-loop context | grew from 70K to 965K tokens per request (431K average, 223M total, about 72% of all tokens) |
| `task-reviewer` | 19 dispatches for 9 tasks, 64.5 min, 35M tokens |
| `task-explorer` | 9 dispatches, 38.6 min, 31M tokens |
| `security-reviewer` | 13 dispatches, 19.4 min |
| Hand-typed dispatch prompts | 149 KB to the reviewer and 37 KB to the explorer, about 65K output tokens |
| Stop-gate blocks | 18 in the session, and 106 across the last 18 sessions. Every sampled block fired while a background subagent was still running |
| `/complete` 422s | 9 of 211 recent completions |

Use these as the "before" numbers when you judge whether a port gained anything.
They come from one session of plugin work. W2259 owns the measured "after", so do
not quote a percentage saving for a port until that exists.

**The "after" now exists:** [`token-measurement-g446-g448.md`](token-measurement-g446-g448.md)
(measured 2026-10-04, `stride` 1.83.0, three dispatched tasks at claim positions
2–4 against G439's D337–D339). It compares per task and per request only; read its
comparator section before quoting any figure from it.

## The port fleet, as checked on 2026-10-02

These are the mechanisms the fixes depend on, port by port. The table was built
from directory listings and greps run from the `kanban` checkout. The `review-round-cap`
column comes from `bash scripts/check-port-canon.sh`. Re-run both before you rely
on a cell, because ports move.

| Port | Hook executable | Stop gate | `task-runner` agent | `round_cap_ok` predicate in markdown | `review-round-cap` anchor |
|---|---|---|---|---|---|
| `stride` | `hooks/stride-hook.sh` + `.ps1` | `hooks/stride-stop-gate.sh` + `.ps1` | yes | yes | v2 at `skills/stride-workflow/SKILL.md:455` |
| `stride-codex` | `hooks/stride-hook.sh` | `hooks/stride-stop-gate.sh` | no | yes | v1 at `skills/stride-workflow/SKILL.md:303` |
| `stride-copilot` | `hooks/stride-hook.sh` | `hooks/stride-stop-gate.sh` + `.ps1` | no | yes | v1 at `skills/stride-workflow/SKILL.md:218` and in `CHANGELOG.md:677` |
| `stride-copilot-lite` | `hooks/stride-copilot-lite-hook.sh` + `.ps1` | none | no | no | v1 at `skills/stride-copilot-lite-workflow/SKILL.md:540` |
| `stride-gemini` | `hooks/stride-hook.sh` | `hooks/stride-stop-gate.sh` + `.ps1` | no | yes | v1 at `skills/stride-workflow/SKILL.md:318` |
| `stride-lite` | `hooks/stride-lite-hook.sh` | none | no | no | v1 at `skills/stride-lite-workflow/SKILL.md:614` |
| `stride-opencode` | TypeScript plugin in `src/` (`index.ts`, `hook-exec.ts`, `capture.ts`) | no Stop-gate file found; it has `src/advisory-continuation.ts` | no | no | v1 at `skills/stride-workflow/SKILL.md:339` |
| `stride-pi` | Pi extension in `extensions/hook-bridge/` | no Stop-gate file found; it has `extensions/hook-bridge/advisory-continuation.ts` | no | no | v1 at `skills/stride-workflow/SKILL.md:233` |
| `stride-opencode-lite` | TypeScript plugin in `src/` (`gate.ts`, `hook-exec.ts`) | no Stop-gate file found | no | no | v1 at `skills/stride-opencode-lite-workflow/SKILL.md:569` |

The vendored catalog copies (`stride-codex-marketplace`, and the copilot and
copilot-lite plugins in `stride-copilot-marketplace`) carry the same files as
their ports, and the canon check reports them separately. A port fix is not
finished until its catalog copy is synced. Each port's `RELEASE.md` and the
release-process notes say whether that port needs a catalog sync, a tag only, or
no marketplace at all.

Two facts from this table decide most of the porting work:

1. **Only `stride` has `stride:task-runner`.** W2250 (dispatcher by default) does
   not apply to any port until the port has a runner. Porting the runner is its
   own project; this document does not cover it.
2. **Only `stride`, `stride-codex`, `stride-copilot` and `stride-gemini` have a
   `round_cap_ok` predicate in their workflow markdown.** In the other five
   ports, the review-round rule is prose only. They port W2252's rule text and
   skip the predicate work.

## Port status

Add a column as each port takes the batch. Use the notation from
[`porting-rework-prevention.md`](porting-rework-prevention.md) § Port status:
not started, in progress, ported (version), or not applicable (reason). Name
the port's own task in brackets, so a cell can be traced to its commit.

| Task | `stride-opencode` |
|---|---|
| W2248 | ported (1.40.0) [W2300] |
| W2249 | ported (1.40.0) [W2301] |
| W2250 | not applicable (no `task-runner` agent) |
| W2251 | ported (1.40.0) [W2302] |
| W2252 | ported (1.40.0) [W2303]; prose only, so the round-two triggers are followed, not enforced |
| W2253 | ported (1.40.0) [W2303]; the canon check reports `review-round-cap` v2 at `skills/stride-workflow/SKILL.md:459` |
| W2254 | not applicable (OpenCode's task tool blocks until the explorer returns, so there is nothing to overlap) [W2304] |
| W2255 | not applicable (no blocking Stop gate; the advisory continuation cannot hold a stop) |
| W2256 | ported (1.41.0) [W2305] |
| W2257 | ported (1.41.0) [W2306] |
| W2258 | ported (1.41.0) [W2307] |
| W2259 | not applicable (measured `stride` on Claude Code only; the port claims no saving) |

`stride-opencode` took the batch in two releases, not the one that rule 4 below
asks for: 1.40.0 shipped before W2305–W2307 were done. Its 1.41.0 changelog
entry gives the reason for each of the four not-applicable rows above, under
"Not ported". The fleet table above is
still the 2026-10-02 snapshot, so its `stride-opencode` anchor cell shows v1.

---

## G446 — accuracy

### W2248 — the hook writes the claimed task to a file (**landed in 1.81.0**)

**Problem.** Task fields reach subagents only by being retyped into each dispatch
prompt. One session retyped about 186 KB this way. Paraphrase in that copy is a
known cause of `/complete` 422s; the acceptance-criteria 1:1 mapping is the usual
casualty.

**What shipped.** After a 2xx `POST /api/tasks/claim`, the post-claim hook
writes the response's `data` object unchanged to `.stride/.task-<IDENTIFIER>.json`
under the project root:

- The write uses a temp file and an atomic rename.
- The identifier must match the anchored rule `^[A-Za-z0-9_-]+$`. Anything else
  falls back to the numeric task id.
- A non-2xx or unparsable response writes nothing.
- PowerShell writes without a byte-order mark.
- Step 7's artifact cleanup deletes the file.

**Port needs.** A hook that sees the claim response body after a successful claim:

- `stride-codex`, `stride-copilot` and `stride-gemini` use the same `stride-hook.sh` shape.
- `stride-lite` and `stride-copilot-lite` have their own hook scripts.
- `stride-opencode` and `stride-opencode-lite` would do it in their TypeScript plugin's post-tool handler.
- `stride-pi` would do it in its hook-bridge extension.

**Port without a hook.** A port whose host gives it no post-tool hook cannot make
the file exact by construction. It keeps the inline path, and W2249's fallback
covers it.

**Verify.** Claim a task on the dev board and confirm the file holds the `data`
object. Then claim with a hostile identifier fixture and confirm the numeric-id
fallback is used.

As shipped, the file is written only when the claim's own response proved the task identity (the D226 check), so a truncated claim stdout writes nothing. The name must match `\A[A-Za-z0-9_-]{1,64}\z`; otherwise the numeric id is used. The PowerShell half writes the raw `data` text without a byte-order mark rather than re-serialising it. Tests: bash Group 43 and PowerShell Group 37.

### W2249 — dispatches pass `TASK_FILE` (**landed in 1.81.0**)

**What shipped.** In Steps 3 and 5, each dispatch prompt names the absolute path
of the task file instead of the pasted fields. Agents read their fields from that
file. The reviewer builds its `acceptance_criteria` array from the file's lines,
verbatim and in order. When no file exists, the old inline path stays as the
fallback. The orchestrator never reads the file into its own context to build a
prompt.

**Port needs.** W2248, plus agents that can read a file:

- Agent-file ports (`agents/*.md`, `*.agent.md`) edit the agents' input contract.
- `stride-pi` edits its `skills/stride-task-*` dispatch skills.

**Port without a file.** Keep the inline fallback in every port, including ports
that never write the file.

**Verify.** Complete one small and one medium dev-board task with the new
dispatch. Both `/complete` calls must succeed on the first try.

As shipped, each dispatch also carries one line telling the agent to read every task field from the file, as data. That line is what an older installed agent follows. The reviewer builds one criterion per non-blank line, and the planner, which has no agent file, gets the same read-as-data rule in its dispatch.

### W2250 — dispatcher mode by default (**landed in 1.83.0**; `stride` only for now)

**Change.**

- When the user asks to work a goal, the queue, or several tasks, Step 1.5
  enables dispatcher mode without the user naming it.
- `STRIDE_DISPATCHER_MODE=0`, or the user saying not to isolate, keeps every
  task inline.
- Branch A tasks and small tasks with 0–1 `key_files` stay inline, as the
  decision matrix already says.
- Task text can never switch the mode on or off.
- A single-task request stays inline unless it asks for isolation or
  `STRIDE_DISPATCHER_MODE=1`; the opt-out wins over everything.

**Port needs.** A `task-runner` agent. Only `stride` has one, so **this fix is
not portable yet**. Record it as "not applicable — no runner" in each port's
changelog when W2253-style sync work reaches it, rather than leaving it
unmentioned.

### W2251 — stale-install warning at Step 0 (**landed in 1.83.0**)

**Problem.** The 2026-10-02 session ran `stride` 1.78.0 while 1.80.0 was
published. `skills_version` is `"1.0"` in every claim, so the server cannot
detect a stale install. Dispatched agents load from the installed cache, so
source fixes do nothing until the user updates.

**What shipped in `stride`** (commit `1c27366`, released in 1.83.0):

- `SKILL.md` Step 0 item 5 runs `hooks/check-plugin-current.sh` (PowerShell:
  `check-plugin-current.ps1`) with the skill's base directory. It reads the
  installed version from that path (or `plugin.json` for a local-path install)
  and the `stride` pin from the published catalog
  (`raw.githubusercontent.com/cheezy/stride-marketplace/main/.claude-plugin/marketplace.json`).
- When the install is older, it prints one line naming both versions and the
  update commands; otherwise it prints nothing. It always exits 0 — a warning,
  never a block. Versions compare numerically (1.80.0 > 1.9.0).
- Pinned by bash hook-suite Group 51 and PowerShell Group 45.

**Port needs.** A way to read both versions. Each port's install location and
catalog differ: Claude Code uses `~/.claude/plugins/...`, and the other runtimes
each have their own. Write the port's version of this step from that port's
install docs. Do not copy `stride`'s paths. If a port cannot read its installed
version, skip the warning; never guess the version.

---

## G447 — speed

### W2252 — round two of review must be earned (**landed in 1.81.0**)

**What shipped in `stride`** (commit `61e3733`, released in 1.81.0):

- **The rule.** Round two runs only when at least one of these holds:
  - round one's fixes edited a code path;
  - round one reported a `critical`;
  - round one reported a `category: "security"` issue at any severity.

  Without a trigger, every fixed finding is **recorded, not re-reviewed**: by
  severity, category, `file:line` and a one-line change, in `completion_notes`
  and in one line of `completion_summary`. Round one's result is then submitted.
  These stay unchanged: the `critical` exemption, the rule that a security issue
  is never just recorded, and the record-don't-fix disposition after round two.
- **The classifier**, in `skills/stride-workflow/review-block-extraction.md`
  under "The fix-path classifier":
  - With `FIX_STAGE=base`, run once before the first fix. It snapshots each
    repository's whole working tree as a git tree, untracked files included, in
    `.stride/.review-fixbase-<IDENTIFIER>.txt`. It never overwrites that file.
  - With `FIX_STAGE=count`, it sets `FIX_CODE_PATHS` to the number of changed
    paths that are not documentation, not tests, and not whole-line comment
    changes.
  - In C-family sources, `#` is never treated as a comment.
  - `*.txt` counts as code.
  - `-1` means unmeasured, which keeps round two available.
- **The predicate.** `round_cap_ok` gains two terms, in both the Source A jq and
  the Source B Python assert:
  - `prior_security` is counted beside `PRIOR_CRITICAL` from the previous round's
    merged file.
  - `fix_code_paths` comes from the classifier.

  Round two passes only with a trigger. Neither new term ever buys a third round.
  An untriggered round two is not escalated: submit round one's result, and
  record every finding round two raised.
- **The canon.** Entry `review-round-cap` moved to **v2**, together with
  `stride`'s anchor.
- **Mirrors updated:** `stride-completing-tasks`, `stride-subagent-workflow`,
  `agents/task-runner.md`, the README and `optional-exploratory-testing.md`. In
  the last one, Step 5.5's "re-reviewed" now defers to the triggers.
- **Tests.** Hook-suite Group 36 runs the new predicate and the classifier from
  the contract's own bytes. Checks 36af, 36ag, 36ah and 36ai are new; 36n and
  36w were rewritten.
- **Disclosed limits:**
  - (a) Markdown is classified as documentation even where it is the product, as
    in every Stride plugin.
  - (b) `-1` means unmeasured.
  - (c) Only repositories named in `FIX_REPOS` are measured.
  - (d) The pin bounds rounds only from above.
  - (e) A security-relevant Step 5.5 finding below `critical`, fixed only in
    documentation paths, gets no round two.

**Port procedure.** W2253 owns this. For every port:

1. **Rewrite the round-cap paragraph** with the three triggers and the
   recorded-not-re-reviewed disposition. Use the port's own voicing; the canon
   compares substance, not wording. Check for copy-paste with the n-gram method
   rather than sentence matching.
2. **Bump the anchor** beside that paragraph to v2. On `stride-copilot`, the
   checker also reports the copy in `CHANGELOG.md:677`. Decide whether that
   changelog copy should be an anchor at all, rather than bumping it blindly.
3. **Ports with a `round_cap_ok` predicate** (`stride-codex`, `stride-copilot`,
   `stride-gemini`):
   - Port the two new terms into both halves, with the same type guards. Malformed
     `prior_security` fails closed to 0; `fix_code_paths` defaults to `-1`.
   - Port the `PRIOR_SECURITY` line in the recount.
   - Port the classifier fence and the fix-base file, and add that file to the
     artifact clear.
   - Port the Group 36 fixtures if the port runs that suite.
   - **Before porting the numbering,** check where the port's shape and step
     numbers differ from `stride`'s (`stride-codex` inverts Shape 1 and 2).
4. **Prose-only ports** (`stride-copilot-lite`, `stride-lite`,
   `stride-opencode`, `stride-pi`, `stride-opencode-lite`): port the rule and the
   classification definition as prose. Do not invent a predicate the port cannot
   run. State in the port's changelog that the round-two trigger is followed, not
   enforced, there.
5. **Mirrors.** Update each mirror the port carries: its completing-tasks
   self-check, its subagent-workflow text, its runner (none today), its README,
   and its exploratory-testing step.
6. **Sync the vendored catalog copy** where the port has one. Re-run
   `bash scripts/check-port-canon.sh` from `stride`. The port should print `ok`
   for `review-round-cap v2`.

**Verify per port:**

- The canon check reports `ok` for the port and its catalog copy.
- The port's own test suite passes.
- Where a predicate was ported, a docs-only fixture is refused at round 2 and a
  code fixture is allowed.

### W2253 — carry the canon change to every port (planned)

This is the W2252 port procedure above, run across all eight ports and the
catalogs. Expect STALE until each port lands; the canon describes that as the
normal state after a deliberate bump.

### W2254 — read while the explorer runs (**landed in 1.81.0**)

**Problem.** Explorer dispatches took 38.6 minutes over 9 tasks. The main agent
sat idle for each one before writing anything.

**What shipped.** While the explorer runs, the main agent may read the task's
`key_files` and plan, but it may not edit until the explorer's report arrives.
The explorer's output still governs.

**Port needs.** A way to dispatch the explorer without blocking (a background
subagent). Without one, the port has nothing to overlap. Write that into the
port's text rather than porting an instruction it cannot follow.

As shipped, Step 3 Branch C and the subagent-workflow Phase 1 mirror carry the rule, and Group 40 pins the wording.

### W2255 — no Stop-gate block while a subagent runs (**landed in 1.81.0**)

**Problem.** The Stop gate blocks a session that still holds a claim. With
background subagents, the main agent ends its turn to wait. Each wait costs a
blocked stop and an extra round trip: 18 in one session, and 106 across the last
18 sessions.

**Evidence the fix rests on (measured, Claude Code 2.1.287).** Throwaway
`claude -p` sessions with project-local hooks logged every agent-related event:
- `PreToolUse` and `PostToolUse` fire for the `Agent` tool at launch.
- `SubagentStart` and `SubagentStop` carry `agent_id` and `agent_type`.
- The **`Stop` input carries `background_tasks`**. While a background agent
  runs, it lists `{id, type: "subagent", status: "running", agent_type}`, and
  the list is empty once the agent finishes.
- A plugin agent appears as, for example, `"stride:hook-diagnostician"`.

The documentation does not cover any of this, so **re-measure it on each runtime
before porting.**

**What shipped.** Two changes, both in the held-claim branch, after the local
pre-filter and before the one API call, in both gate halves:
- **The permit.** The gate permits the stop while the live list holds a running
  agent of an exact type stride dispatches. That covers its task agents, the
  security reviewer, the exploratory-testing agents and the generic `Plan`
  agent, matched as whole strings and never by prefix. The permit names the
  agent's type and id, never its description.
- **The time bound.** A wait is one held claim plus one set of pending agent ids.
  Its first permit records `{identifier, agents, since_epoch}` in
  `.stride/.stop-pending-since.json`, and permits stop after 30 minutes. A
  different set of pending agents starts a new wait. A stop with nothing pending
  clears the record. A wait that cannot be recorded does not permit.

Parsing is strict and identical in both halves: a JSON object, an array of
tasks, string fields, exact matches and a whole-number epoch. No hook
registration changed. Tests: bash Group 44 and PowerShell Group 38.

**Port needs.**
- A **blocking Stop gate**: `stride-codex`, `stride-copilot` and `stride-gemini`
  have one.
- A runtime whose Stop input lists **running background agents**. This is the
  part to verify per runtime. Without such a list the fix cannot be ported, so
  record "not applicable" rather than inventing a marker.
- `stride-opencode` and `stride-pi` use advisory continuation rather than a
  blocking Stop gate. Read how those ports end a turn first.

---

## G448 — token usage

### W2256 — slim discovery (**landed in 1.81.0**)

**Problem.** Each task body arrived twice: once from `next` (7–9 KB) and again
from `claim` (8–11 KB).

**What shipped.** Discovery calls `GET /api/tasks/next?response_view=slim`.
That returns the 11-key task summary (id, identifier, title, type, status,
priority, complexity, dependencies, created_by_agent, parent_id,
claim_expires_at), not the body. An older server ignores the parameter and
returns the full task.
- The full task body comes from the claim response, which the hooks already
  read.
- The enrichment check moves to after the claim, because it needs fields the
  summary lacks.
- Dispatcher mode's size gate needs `key_files`, so only the dispatcher path
  fetches `GET /api/tasks/:id` — now the default for goal, queue and
  multi-task requests (W2250).
- A runtime that runs `before_doing` before the claim also fetches
  `GET /api/tasks/:id` first.
- The Stop gate's own `next` call goes slim too; it reads only the status code
  and the identifier.

**Port needs.** Nothing on the host side; this is skill text plus the server's
existing slim view. Every port can take it. Ports that run the enrichment check
before claiming must move it to after the claim.

**Verify.** Run one task from discovery to completion and confirm the discovery
response is the slim shape.

### W2257 — lighter `stride-workflow` hot path (**landed in 1.83.0**; `stride` only for now)

**Change.**

- Rationale, provenance and history moved out of `skills/stride-workflow/SKILL.md`
  (100,992 → 98,446 B, −2.5%) and `skills/stride-workflow/review-block-extraction.md`
  (56,272 → 50,906 B, −9.5%) into a new `docs/orchestrator-rationale.md`, one
  `##` section per moved block.
- Each moved block left a one-sentence pointer at its original site naming the
  doc and the section. Text that duplicated another file (`reference.md` §
  Edge Cases, `hook-execution.md`, a Source B code comment) was deleted with a
  pointer to that file instead of being copied.
- The six canon back-reference paragraphs were shortened, not moved. Each keeps
  the `port-canon.md` path, the entry id and the version-bump obligation, which
  is what the `edit-site-back-reference` check reads.
- Every gate, decision matrix, Decision Summary, schema, self-check, executed
  code block, prompt-injection framing and redaction rule stayed inline, as did
  the text `docs/port-canon.md` quotes. No canon version changed.
- `scripts/check-skill-budgets.sh` and `.ps1`: `stride-workflow/SKILL.md`
  lowered from 101,000 to 100,000, and `review-block-extraction.md` budgeted
  for the first time at 57,000.

**Port needs.** Each port's skills are its own voicing, so port the *method*, not
the bytes:

1. Identify the rationale paragraphs in the port's hot path.
2. Move them to the port's docs, never under a directory where every `.md`
   registers as an agent.
3. Keep every canon anchor beside its governed text, with a back-reference
   paragraph below it that names `port-canon.md` and the entry id.
4. Leave a pointer at every original site.

Canon provenance quotes must still match the governed text verbatim after the
move.

**Verify.** The port's canon check reports no new failing cell, its budget check
(if any) passes, and its hook suite stays green.

### W2258 — lighter `stride-completing-tasks` and reviewer (**landed in 1.83.0**; `stride` only for now)

**Change.**

- Rationale, provenance and defect history moved out of
  `skills/stride-completing-tasks/SKILL.md` (63,905 → 59,165 B, −7.4%) into a
  new `docs/completion-rationale.md`, and out of `agents/task-reviewer.md`
  (77,339 → 74,535 B, −3.6%) into a new `docs/task-reviewer-rationale.md`, one
  `##` section per moved block, each reached from a pointer at its original
  site.
- Text that duplicated another inline statement was deleted rather than moved:
  repeated D188 `completion_summary` caveats (the self-check preamble keeps the
  reason), the hooks-are-automatic and duration-zero restatements, the
  reviewer-result source-chain paragraph (Shape 1 keeps it), the response-capture
  explanation (`hook-execution.md` keeps it), the `CRITICAL_CLEARED` reason
  (`docs/orchestrator-rationale.md` keeps it), and the reviewer's standalone
  credential worked-instance paragraph (stated twice more inline).
- The completion field reference, both result shapes, the skip-reason enum, the
  self-check list, the reviewer's block schema, verdict and consistency rules,
  bounded-summary contract and line caps, prompt-injection framing and redaction
  rules all stayed inline, as did both canon-anchored blocks
  (`cosmetic-finding-class`, `verdict-note`) byte for byte. No canon version
  changed.
- `scripts/check-skill-budgets.sh` and `.ps1`: `stride-completing-tasks/SKILL.md`
  lowered from 64,000 to 61,000, and `agents/task-reviewer.md` budgeted for the
  first time at 77,000.

**Port needs.** The same method as W2257, applied to the port's completion skill
and its reviewer prompt in its own voicing. A port's reviewer variant must keep
the block schema, every verdict rule and every redaction and prompt-injection
rule inline, because a dispatched reviewer never opens the rationale doc.

**Verify.** The port's canon check reports no new failing cell, its budget check
(if any) passes, its hook suite stays green, and one dispatched review on the
slimmed reviewer completes on the first `/complete`.

### W2259 — measure the effect (measured; last)

Run a multi-task session with all landed fixes, using the method in
`docs/token-baseline.md`. Name the comparator and the session position for every
figure. G404's saving was 15.2% on a fresh session but 5.6% by task 3, so a
number without its comparator is meaningless. Ports should not claim savings
from this measurement; it measures `stride` on Claude Code.

---

## General porting rules for this batch

1. **Port from landed sections only.** A planned section is an intention.
2. **Verify every mechanism a ported sentence names exists in that port**:
   hooks, agents, gates, predicates. Several fixes here depend on a `stride`-only
   mechanism, and the table above shows which.
3. **Bump canon entries and anchors together.** Never write a literal
   canon-anchor comment into a changelog, README or this document; the drift
   check scans those files and would count it.
4. **One release per port per batch.** Commit per task, then make one version
   bump, changelog entry, tag and release at the end. Do not cut a release per
   fix.
5. **Record what a port cannot carry** — no runner, no Stop gate, no predicate —
   in that port's changelog, so "not applicable" is distinguishable from "missed".
