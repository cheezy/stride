# Design sketch: cutting orchestrator context by isolating per-task work

**Status:** Sketch for discussion. Nothing here is built, and two load-bearing
questions are unverified — see [Blocking unknowns](#blocking-unknowns). Do not
start implementation until those are answered; the answers decide which option
is even possible.

**Problem:** measured in
[`token-measurement-g404-g405.md`](token-measurement-g404-g405.md). G404 cut the
resident plugin body by 20,786 tokens (5.6–15.2% depending on session position).
The remaining cost is not the plugin and not the API — it is **what accumulates
in the main loop and is then re-sent on every later request**.

---

## The measured target

Across three task runs in one session (52.5M input tokens total):

| Source | ~Tokens | Share of unique content |
|---|---:|---:|
| Bash tool results | 73,732 | **48.1%** |
| Agent / subagent reports | 61,354 | **40.0%** |
| Everything else | 18,151 | 11.9% |

Twelve individual results account for **45% of all context**, and **nine of the
top twelve are subagent reports**:

| Result | Bytes |
|---|---:|
| `task-reviewer` (W2058) | 27,335 |
| `task-reviewer` (W2057) | 25,293 |
| `task-reviewer` (W2055) | 21,756 |
| `Plan` (W2057) | 18,043 |
| `Plan` (W2058) | 17,431 |
| `task-explorer` (W2058) | 14,351 |
| `git diff` dump | 14,260 |
| `task-explorer` (W2057) | 14,140 |
| `Plan` (W2055) | 12,214 |
| `git diff --stat` dump | 11,045 |
| `task-explorer` (W2055) | 10,602 |
| `mix precommit` tail | 8,226 |

**9 subagent reports = 161,165 B ≈ 56,351 tokens**, averaging 6,261 tokens each.

### Why this compounds

The main loop re-sends the whole conversation on every request. A report landing
in the main loop is paid for once per *remaining* request in the session, not
once. The session ran **156 main-loop requests** across three tasks, and average
context per request grew **137,165 → 369,173**.

**The architectural mistake is that the most expensive context lives in the most
expensive place.** The orchestrator runs in the main loop, so every file read,
diff, test run and subagent report accumulates where it will be re-sent most
often — and then the *next* task inherits all of it.

---

## Does this actually reduce billed tokens, or just move them?

**It reduces them.** This is the question the rest of this document is only
useful if it answers, because a subagent does not destroy tokens — it pays them
itself, and adds its own overhead. Two things have to be true, and both are:

### 1. The same work is billed at a lower rate in a subagent

Measured on W2058:

| Context | Requests | Total input | Tokens per request |
|---|---:|---:|---:|
| Main loop | 59 | 21,898,726 | **371,164** |
| `explorer` | 13 | 1,033,263 | 79,481 |
| `Plan` | 25 | 1,166,037 | 46,641 |
| `reviewer` | 14 | 1,380,089 | 98,577 |
| `security-reviewer` | 20 | 1,302,271 | 65,113 |
| **All subagents** | **72** | **4,881,660** | **67,800** |

**A main-loop request costs 5.5× a subagent request.** Same model, same work —
the difference is entirely how much conversation is being re-sent. Relocating a
request from the main loop to a subagent is therefore a straight ~5.5× discount
on that request.

### 2. The subagent's accumulation dies instead of being inherited

The main loop's cost is roughly `Σ context(i)` over its requests, and context
only grows. Work done in the main loop during task 1 is re-sent on every request
of tasks 2 and 3. Work done in a subagent is re-sent only within that subagent,
then discarded. **Eliminating the cross-task compounding is where most of the
saving comes from**, not from the per-request discount alone.

### Two independent estimates, which converge

**Mechanism model.** ~96 of 156 main-loop requests are implementation-shaped
(38 Bash + 19 Edit + 2 Write on W2058 alone). Moving them:

```
96 requests × 267,000 (main-loop average) = 25,632,000
96 requests ×  80,000 (implementer subagent) =  7,680,000
                                    saving = 17,952,000  (34% of session)
```

**Empirical anchor.** W2055 ran first in the session and cost 8,024,618 for 44
main-loop requests. Scaling that first-position cost by each task's request
count, to correct for task size:

| Task | Requests | Cost if run fresh |
|---|---:|---:|
| W2055 | 44 | 8,024,618 |
| W2057 | 53 | 9,666,017 |
| W2058 | 59 | 10,760,283 |
| **Total** | | **28,450,918** |

vs **52,502,688** observed → **46% saving**.

Two methods from different directions land at **34–46%**. Take the lower end for
Option B (which isolates only implementation) and the upper for Option A.

### The overhead this costs

Isolation is not free. Each dispatch re-pays a base: system prompt, tool
definitions, skill bodies, task prompt. Observed subagent `cache_creation` on
W2058 was ~92,000 per subagent. Adding one implementer per task:

```
92,000 × 3 tasks = 276,000 tokens ≈ 4.6% of session effective cost
```

**Real, and roughly an order of magnitude smaller than the saving.** It does mean
isolation has a floor: dispatching a subagent for a two-minute task will lose
money. The decision matrix should gate it on task size, exactly as it already
gates explorer and planner.

### What does not change

- **Output tokens.** ~152,733 across the session, unchanged by isolation — the
  same work is done and written. At ~5× the input rate, output is **9% of
  effective cost** today and would become a *larger* share afterwards.
- **The mix shifts toward the more expensive token type.** `cache_read` is
  **97.5% of input tokens but only 68% of effective cost** (it bills at roughly
  0.1×). Subagents run a much higher `cache_creation` ratio (7.5% vs the main
  loop's 0.5%), and creation bills at ~1.25×. Re-running the estimate in effective
  cost units rather than raw tokens gives ~49% instead of ~54% for full
  isolation — the same conclusion, modestly compressed.

> Pricing multipliers used: `cache_read` 0.1×, `cache_creation` 1.25×, `output`
> 5× base input. These are the standard published ratios; confirm against the
> actual plan before quoting a dollar figure.

### How it could backfire

- **Re-discovery.** An isolated task re-reads what the previous one established.
  W2057 built on the renderer W2055 had just relocated; a cold subagent would
  re-explore it. Some of the 34–46% comes back as re-work, and **nobody has
  measured how much**.
- **Too many small dispatches.** Below some task size the ~92,000-token spin-up
  exceeds what isolation saves.

---

## Resolved unknowns (experiments run 2026-08-08)

Both were run before choosing an option. **Both came back favourable**, which
unblocks Option A and removes the review-quality objection against it.

> **D220 (`eb8939f`) landed after these experiments and changed how U1 re-runs.**
> Routing no longer dispatches on command text: it requires the call to actually
> issue the request (client in command position, endpoint as a URL tail in
> argument position, matching method). The `~1561` line citation below predates
> that commit. U1's *result* stands — the hook fired in the subagent — but a
> re-run needs a real `curl`/`wget`, not a command that merely contains the URL.
>
> **The three hook facts below now also live in the executor's own reference**,
> [`../skills/stride-workflow/hook-execution.md`](../skills/stride-workflow/hook-execution.md),
> under "Behavior When Invoked From a Subagent" — with their methods, so they can
> be re-run. That is where someone touching the executor will look, and it is the
> copy that has to survive; this section keeps the full experimental write-up.
> **An edit to either belongs in both.**

### U1. Do hooks fire for a **subagent's** tool calls? — **YES**

Method. The hook dispatches on *command text*, not on a real API call
(`stride-hook.sh` ~1561: `*/api/tasks/*/mark_reviewed*` → `after_review`), and
the `after_review` path unconditionally deletes `.stride-changed-files.json`.
That gives a filesystem detector needing no network call and no claimed task: plant
a sentinel at that path, run a command containing a `mark_reviewed` URL, see whether
the sentinel survives.

| Run | Where | Command contains pattern? | Sentinel | Reading |
|---|---|---|---|---|
| Positive control | main loop | yes | **deleted** | detector works |
| **Test** | **subagent** | **yes** | **deleted** | **hook fired in subagent** |
| Negative control | subagent | no | **survived** | deletion is caused by the pattern match, not by subagent activity |

The negative control is what makes this conclusive: it rules out "something else
deletes the file". The subagent itself reported seeing **no** hook output, error
or notification — so **the hook fires but is invisible to the subagent**, which
matters for error handling (a subagent cannot see an `after_doing` failure the
way the main loop does; it surfaces as a blocked tool call).

**Scope of the result.** All three runs happened while `.stride.md` was in plugin
mode with **empty hook sections**, so the probe proves the hook script is
*invoked* and executes its own logic — not that a populated section body runs.
The comparison is still like-for-like (control and test both ran empty), and the
chain closes as follows:

- Main loop, **populated** sections → hooks demonstrably execute (the three task
  runs measured today ran `mix test --cover`, committed, merged and pushed).
- Main loop, **empty** sections → hook invoked, cleanup runs *(positive control)*.
- Subagent, **empty** sections → hook invoked, cleanup runs, **identical to the
  main loop** *(test)*.

So hook invocation is not main-loop-specific, and which section body executes is a
function of `.stride.md` content rather than of the caller. **The one thing still
unverified is narrower and is the part that matters most: whether a hook that
exits non-zero actually *blocks* a subagent's tool call**, as it does in the main
loop. Confirm that specifically — with a deliberately failing section — before
relying on `after_doing` as a gate from inside a subagent. A gate that fires but
does not block is worse than no gate, because it reads as protection.

### U2. Can a subagent dispatch a subagent? — **YES (tool present)**

A dispatched `general-purpose` subagent enumerated its own tools and reported
`Agent` as directly loaded and callable, alongside a harness-injected list of
~13 dispatchable `subagent_type` values (`Explore`, `Plan`, `stride:task-explorer`,
`stride:task-reviewer`, …). It also has `Skill`.

**Caveat:** this establishes *tool presence*, not a verified end-to-end nested
dispatch. Confirm with an actual nested dispatch before building on it.

### U3. Does a **failing** blocking hook actually block a subagent's tool call? — **YES**

Re-run with `.stride.md` back in `stride_dev` mode (populated hook bodies). A
deliberately failing test was planted so line 1 of `after_doing`
(`mix test --cover`) exits non-zero. Because the hook aborts on the first failing
line, line 5 (`git add -A && git commit`) can never be reached — verified after:
clean tree, unchanged HEAD, no new commits.

| Run | Where | Echo executed? | Result |
|---|---|---|---|
| Positive control | main loop | **no** | `PreToolUse:Bash hook error … after_doing hook failed on command 1/5` |
| **Test** | **subagent** | **no** | **identical error, tool call blocked** |

**The gate holds inside a subagent.** The subagent received the full hook error
verbatim, the `echo` never ran, and the call took tens of seconds — consistent
with the whole `mix test --cover` chain executing before failing.

This also **supersedes the U1 caveat**: a *populated* section body demonstrably
runs for a subagent's tool call, and a non-zero exit demonstrably blocks it.

**Correction to an earlier finding.** U1 concluded the hook is "invisible to the
subagent". That was an artefact of testing a *passing* hook. A **failing** hook is
fully visible — the subagent received the complete error text. The visibility gap
applies only to hooks that succeed, which is the harmless direction.

### U2 (strengthened). Nested dispatch verified end-to-end — **YES**

Not merely tool presence: a subagent dispatched a nested `general-purpose`
subagent and received its reply (`NESTED-OK`, 40,764 tokens, 1,856 ms). Nesting
works at this depth.

### What this changes

- **The gate risk against Option A is not valid.** It was the single objection
  that could have disqualified A, and it does not survive contact with the
  experiment. A task-runner subagent issuing the completion curl gets the same
  blocking `after_doing` gate, with the same visible failure, as the main loop.
- **Option A is fully unblocked** — U1, U2 and U3 all favourable.
- **The review-independence objection is gone too**, since nesting is verified: a
  task-runner can dispatch its own reviewer and emit the full structured block.
  The [completion-contract section](#effect-on-the-completion-contract) is
  therefore contingent and does not apply to the expected design.
- **Option B remains lower-risk** only in the weak sense of changing less. Its
  specific safety advantage — "keeps the gate where it is known to work" — has
  been dissolved by U3.

### A real hazard surfaced by the experiment — file this as a defect

**This is the most actionable finding of the session, and it is independent of
everything else in this document.**

`stride-hook.sh` dispatches on the *literal text* of a Bash command. It does not
check that the command is a `curl`, that it makes a network call, or that a task
is claimed. Two consequences, both observed today rather than theorised:

**1. It scraped a task ID out of a harmless `echo` and drove a live API write.**

```
stride-hook: changed_files upload failed (HTTP 404) for task 999999999
```

No task was claimed and no request was made — `999999999` existed only as a
string inside an `echo` argument.

**2. It fired on a document being written *about* the hazard.**

While writing this very section, a `python` heredoc containing the pattern
`*/api/tasks/*/complete*` as **prose inside a markdown code span** matched
the PostToolUse rule, which ran `before_review`:

```
Stride before_review hook failed on command 2/3: git merge --ff-only "$TASK_IDENTIFIER"
merge: W2058 - not something we can merge
```

It resolved `$TASK_IDENTIFIER` from a **stale `.stride-env-cache`** left by a task
completed hours earlier, then attempted a real `git merge` against a branch that
had already been deleted. It failed harmlessly only because the branch was gone.
The next line in that hook is `git branch -d "$TASK_IDENTIFIER"`.

**Why this matters.** Any command whose text merely *contains* a matching URL —
a shell comment, an `echo`, a heredoc, a `grep` pattern, a commit message, a
documentation file being written — will trigger a full hook chain. On the `pre`
path that means running an entire test suite; on the `post` path it means real
`git checkout` / `merge` / `branch -d` operations, against whatever identifier
happens to be left in the env cache.

**Suggested fixes**, roughly in order of value:

1. **Match on the command being an actual API invocation**, not on text
   containing a URL — require a `curl` (or equivalent) invoking the endpoint,
   rather than a substring match anywhere in the command.
2. **Refuse to run when no task is active.** A stale `.stride-env-cache` should
   not be able to drive `git merge` / `git branch -d`. Clear it on
   `after_review` unconditionally, or treat a completed task's identifier as
   expired.
3. **Require the extracted task ID to be the claimed task**, rather than
   whatever integer appears in the text, before issuing any API write.

## Option C — Report-to-file discipline

**The smallest change, the least risk, and it composes with everything below.
Start here regardless of how U1/U2 resolve.**

Subagents currently return their full analysis as prose into the main loop.
Instead: **write the full output to a file, return a short summary plus the
path.** The orchestrator reads the file only when it actually needs the detail —
and for the reviewer, it needs the file only to build the completion payload.

```
task-reviewer  →  writes .stride/review-<TASK>.json   (full structured block)
               →  returns ~20 lines: status, issue counts, verdicts, path
```

**Nothing about the workflow changes.** Same dispatches, same decision matrix,
same hooks, same completion contract. The orchestrator already copies the
reviewer's structured JSON verbatim into `reviewer_result` — reading it from a
file is *more* reliable than re-parsing it out of a prose response, and removes
the fenced-block extraction fallback path entirely.

**Estimated saving: ~6-8% of billed tokens** (≈3-4M on this session). If the 9
reports drop from ~6,261 to ~2,000 tokens each, ≈38K tokens of resident content
is removed; a report entering mid-session is re-read by roughly half the
remaining requests, so ≈38K × ~78 ≈ **3.0M tokens** — **comparable to G404's
entire measured saving (3.24M)**, for a fraction of the work.

This option reduces *content*, not request count, so it captures none of the
5.5× per-request discount. That is why its ceiling is far below B and A.

Treat it as order-of-magnitude: it assumes an average entry point mid-session
and a uniform request distribution, neither of which is exactly true.

**Risks.** Low. Files must be gitignored (`.stride/` already is). A report path
recorded in `completion_notes` dangles for anyone on another machine — carry the
substance, not just the path, exactly as the hardening step already requires.

---

## Option B — Isolate the implementation phase

**Move Step 4 (implementation) into a subagent. Leave everything else in the
main loop.**

```
main loop:  discover → claim(curl) → explore → plan
                ↓
            dispatch implementer  ← all Edit/Write/Bash accumulation lives here
                ↓  returns: summary + files touched
main loop:  review → hooks → complete(curl) → loop
```

**Why this shape specifically:** the claim and completion curls stay in the main
loop, so **U1 does not block it**. The hooks fire exactly as they do today. The
reviewer still dispatches from the main loop with independent context, so review
quality is unchanged. Only the noisy part moves.

The reviewer does not need the implementer's narration — it reads the diff from
git, which is already how it works.

**Estimated saving: ~30-40% of billed tokens.** This is the option the
mechanism model above prices directly — it relocates the ~96 implementation-shaped
requests from the main loop's 267K/request to an implementer subagent's ~80K,
worth ≈17.9M on this session (34%), plus the content reduction from Option C.
Unlike C, it captures the per-request discount, which is where the money is.

**Risks.**
- The implementer subagent must be trusted to follow `pitfalls`,
  `patterns_to_follow` and the project's development-guidelines skill without the
  orchestrator watching each edit. Its prompt has to carry all of that.
- Debugging gets harder: when implementation goes wrong, the main loop sees a
  summary rather than the trail. Mitigate with Option C's file discipline —
  the implementer writes a full log.
- An `after_doing` failure surfaces in the main loop *after* the implementer has
  exited, so the fix loop needs a way back in — either re-dispatch with the
  failure text, or fall back to fixing inline.

---

## Option A — Full per-task isolation

**Main loop becomes a thin dispatcher.** One subagent owns the entire lifecycle
for one task and returns a short record.

```
main loop:  loop { dispatch task-runner → record 20-line result }
```

**Both directions of that handoff are specified in
[`task-runner-contract.md`](task-runner-contract.md)** — the exact inbound field
set, the returned record's field-by-field schema, its **4,000-byte cap** and the
arithmetic behind that number, the status enum that tells a `needs_review` stop
and a blocked claim apart from a plain success, and what must never cross in
either direction. **"A short record" is not a specification.** Without a written
cap the return grows by accretion until the isolation is worthless, and nothing
fails while it happens.

**Largest ceiling: ~46% of billed tokens** (52.5M → ~28.5M across the three
measured tasks, after correcting for task size by scaling on request count; ~49%
in effective-cost units). Some of it returns as re-discovery when each task
starts cold, and that share is unmeasured.

**This is the option gated on both unknowns, and it is the most likely to be
unbuildable as stated.**

- If **U1** says hooks do not fire in subagents → **this option is dead** unless
  the claim/complete curls are somehow proxied back through the main loop, which
  defeats the isolation.
- If **U2** says nesting is unavailable → explorer, planner and reviewer all
  collapse inline, with the consequences below.

---

## Effect on the completion contract

Only Option A changes it, and the change is a real quality regression that
should be weighed rather than absorbed.

If the reviewer runs **inline** inside the task-runner, `reviewer_result` must be
submitted as the **Shape 2 self-reported skip** — `dispatched: false`, reason
`self_reported_review`. That is contract-legal (the reason enum already carries
it) and the server accepts it. Two consequences:

1. **The review queue loses the structured block.** No `issues[]`, no per-criterion
   verdicts, no `project_checks` — the Code review panel renders nothing. That is
   precisely what the whole-object-copy rule and the 25-bullet `project_checks`
   contract exist to populate.
2. **The task-runner must not fabricate a dispatched-shape block.** Writing a
   structured `reviewer_result` with `dispatched: true` when no independent
   reviewer ran is exactly the fabrication `stride-completing-tasks` forbids.
   Shape 2 is the honest encoding, and it is worse.

`workflow_steps` degrades gracefully — `explorer` / `planner` / `reviewer` would
be `dispatched: false` with `self_reported_*` reasons, which the six-entry
contract already accommodates.

**The deeper cost is adversarial independence.** A reviewer sharing context with
the implementer has already seen the reasoning that produced the code, and is
measurably less likely to challenge it. In this session the dispatched reviewers
caught three real issues — a vacuity risk in three cap tests, and two caps too
loose to catch a realistic regression — none of which the implementing context
had noticed. That is the value being traded away.

---

## Recommended sequence

1. **Run the two experiments (U1, U2).** Cheap, and they determine everything.
2. **Ship Option C.** It is independent of both answers, carries the least risk,
   and is worth roughly what G404 delivered.
3. **Then Option B**, if C is not enough. It is compatible with hooks as they
   work today and preserves review independence.
4. **Treat Option A as conditional.** Only if U1 and U2 both come back
   favourable, and only if the review-independence cost is judged acceptable.
   If nesting is unavailable, A is probably not worth its quality cost.

**A cheaper thing to try first, before any of this:** run each task as its own
`claude -p "work the next stride task"` invocation. That gets Option A's context
isolation with zero code, at the cost of losing cross-task continuity. It is the
fastest way to find out whether the ~54% is real before designing around it.

---

## What this does not address

- **Cross-task context has value.** W2057 built directly on the renderer W2055
  relocated; W2058 wrote guards for both. Isolation makes each task re-discover
  what the previous one established. Some of the saving is real; some is
  re-discovery moved elsewhere. Nobody has measured the split.
- **`GET /api/tasks` still returns 2.4 MB unslimmed** (~840K tokens). Unrelated
  to this design, and more urgent than any of it — an agent that calls it without
  `response_view=slim` loses its context window immediately (and even with the
  param on a server predating G408's slim-on-index, which ignores it).
- **`response_view=slim` is still sent by nothing.** Deployed, working, unused.
  Independent of this work and much smaller, but nearly free. *(Historical, as
  written: the plugin has since wired the param into its index/tree rule (W2086)
  and the complete curl (W2087).)*
