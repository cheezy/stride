# The runner path, verified end to end on real tasks (W2066)

**Status:** captured 2026-08-09. Plugin version under test: **1.63.0** (`stride`
subrepo commit `8f80ee6`, the release that shipped the runner, the handoff
contract, dispatcher mode and the isolation size gate). Kanban `main` before the
run: `b5737c98`; after: `2cf4dab1`. Hook mode during the run: **`stride_dev`**
(the real hook bodies), not the repo's day-to-day `plugin_dev`. Tasks used:
**W2072** (id 6168) and **W2073** (id 6169), both created for this verification.

## Verdict in one line

The runner path carries a real task from claim to Done with a complete
completion payload, a populated diff and a fast-forward branch merge; the
`after_doing` gate was observed **blocking** a completion, not merely passing
one — though by an unplanned timeout rather than by the fault this run planted;
and the documented `hook_blocked` resume path was exercised and works.

The run's most consequential result was not one it set out to check: the
`after_doing` section **exceeds its own default budget** and is survivable only
because of an uncommitted per-machine override, which means a fresh clone cannot
complete a task at all (finding 1, **D223**).

`after_goal` under dispatcher mode, a reviewer `changes_requested` round *inside
a runner*, and a `needs_review=true` stop all remain **unexercised** and are
named as gaps below.

## Why this document exists

Every failure mode this change can introduce is silent. A completion that
skipped the test gate looks exactly like one that passed it. So each guarantee
below is checked against a **specific observable**, and the absence of an error
is never treated as evidence. Where a guarantee is proven by something *not*
happening, the reading is stated as a negative and the pre-run value is shown
beside the post-run value.

## Source data

Three runs, each a real `stride:task-runner` dispatch against the live board:

| Run | Task | Direction | Runner status | `completion_submitted` | Outcome |
|---|---|---|---|---|---|
| 1 | W2072 | green | `completed` | `true` | Done |
| 2 | W2073 attempt 1 | gate armed red | `hook_blocked` | **`false`** | no completion recorded |
| 3 | W2073 attempt 2 | resume from run 2 | `completed` | `true` | Done |

Both tasks are `small` with 2 `key_files` — the Step 3 matrix row
`small, 2+ key_files → Isolate: YES`, so the Step 1.5 size gate dispatches them
rather than routing them inline. Both are **standalone** (`parent_id: null`) by
design, so `after_goal` never fires and no throwaway commit is pushed to origin.

Server readings come from `GET /api/tasks/:id` captured to a file; git readings
come from `git reflog`, which is the durable mid-run record. The full harness is
in [Reproduction](#reproduction).

---

## Guarantee → observable → reading

### AC1 — one real task completes through the dispatcher and reaches Done

**Observable:** `column_id`, `status`, `completed_at` on the task record.

| Run | Reading |
|---|---|
| W2072 | `column_id=130 status=completed completed_at=2026-08-09T14:31:34Z needs_review=false agent="Claude Opus 5" actual_complexity=small` |
| W2073 (attempt 2) | `column_id=130 status=completed completed_at=2026-08-09T15:09:48Z needs_review=false agent="Claude Opus 5" actual_complexity=small` |

**Reading:** both reached Done. That establishes *completed*; the *through the
dispatcher* half rests on the returned records (`status: "completed"`,
`claimed: true`, `completion_submitted: true`, `task_identifier` echoing what was
dispatched) and on the dispatcher having written no code itself — no `Edit` or
`Write` call touched `lib/` or `test/` in the main loop for either task.

**Verdict: PASS.**

### AC2 — the gate blocks when it fails

Its own section: [The gate in its failing direction](#the-gate-in-its-failing-direction).

### AC3 — the completion payload carries the full structured `reviewer_result` and six `workflow_steps`

**Observable A:** the structured section set on the persisted `reviewer_result`,
as a hard `jq -e` gate, plus the key list — because the failure this criterion
really guards is a *thin* payload, not an absent one.

| Run | Reading |
|---|---|
| W2072 | **PASS**, 15 keys: `acceptance_criteria, acceptance_criteria_checked, dispatched, duration_ms, issue_counts, issues, issues_found, patterns, pitfalls, project_checks, schema_version, security_considerations, status, summary, testing_strategy` |
| W2073 | **PASS**, same 15 keys |

That is every structured section **plus** the five legacy overlay keys — the
whole-object passthrough, not a hand-picked subset.

**Observable B:** depth rather than presence.

| Run | Reading |
|---|---|
| W2072 | `schema_version=1.6 status=approved issues=0 ac_entries=4 project_checks=25`; sections `testing=passed patterns=passed pitfalls=passed security=not_assessed` |
| W2073 | `schema_version=1.6 status=approved issues=1 ac_entries=4 project_checks=25`; same section verdicts |

**`project_checks=25` is the sharp reading.** The historical regression here was
an enumerated copy-list silently dropping `project_checks` (3 of 26 reaching the
server). It did not recur on either run.

`security=not_assessed` is correct, not a miss: neither task supplied a
`security_considerations` list, and the server only rejects `not_assessed` for a
task that *did* supply one.

**Observable C:** the 1:1 acceptance-criteria rule — the reviewer's array length
must equal the task's criterion-line count (the W1099 `6/5` defect).

| Run | Reading |
|---|---|
| W2072 | `task_lines=4 reviewer_entries=4` |
| W2073 | `task_lines=4 reviewer_entries=4` |

**Observable D:** `workflow_steps` length and per-entry shape.

Both runs: **exactly 6 entries**, five dispatched and `planner` in the skip form.

```
explorer:       dispatched=true
planner:        dispatched=false  (reason present)
implementation: dispatched=true
reviewer:       dispatched=true
after_doing:    dispatched=true
before_review:  dispatched=true
```

Six entries with one *skip form* is a better test than six dispatched: a
`small, 2+ key_files` task cannot produce six dispatched by the matrix, so this
run exercises the skip shape the schema requires, including its `reason`.

**Verdict: PASS.**

### AC4 — `changed_files` is populated

**Observable:** entry count, per-entry diff size, count of empty diffs, and
`actual_files_changed`. Present-but-empty is the real failure mode, so the empty
count is read explicitly rather than inferred from the entry count.

| Run | Reading |
|---|---|
| W2072 | `count=2` — `lib/kanban_web/duration.ex` (1691 B), `test/kanban_web/duration_test.exs` (1267 B); `empty_diff_entries=0`; `actual_files_changed` names the same two |
| W2073 | `count=2` — `lib/kanban_web/avatar_palette.ex` (555 B), `test/kanban_web/avatar_palette_test.exs` (1218 B); `empty_diff_entries=0`; `actual_files_changed` names the same two |

**Observable (staleness):** the documented silent failure is a runner that
redirects or pipes its **claim** curl, leaving a stale `TASK_ID` so this task's
diff is PUT onto the *previous* task. Under dispatcher mode the claim happens in
a context the dispatcher cannot see, so this is a live risk.

| Run | Reading |
|---|---|
| W2072 | `TASK_ID='6168' TASK_IDENTIFIER='W2072' TASK_BASE_REF='b5737c98…'`; upload state `task_id=6168 http_code=200` |
| W2073 | `TASK_ID='6169' TASK_IDENTIFIER='W2073' TASK_BASE_REF='30aa57c4…'`; upload state `task_id=6169 http_code=200` |

Both fresh and correctly attributed. `.stride_auth.md` and `.stride.md` are
absent from both path lists, as the capture's filter intends.

**Verdict: PASS.**

### AC5 — the task branch is merged and deleted by `before_review`

The end state alone is weak evidence — a branch that never existed also fails to
appear. `git reflog` is the durable mid-run record and is the observable.

W2072:

```
30aa57c4 merge W2072: Fast-forward
b5737c98 checkout: moving from W2072 to main
30aa57c4 commit: Completed task W2072: Render negative minute values as the nil label in KanbanWeb.Duration
b5737c98 checkout: moving from main to W2072
```

W2073 shows the same four-step shape ending `merge W2073: Fast-forward`.

| Observable | W2072 | W2073 |
|---|---|---|
| `git branch --list <IDENT>` | empty (deleted) | empty (deleted) |
| commits on `main` since baseline | exactly 1 | exactly 1 |
| **merge commits** since baseline | **0** | **0** |
| `HEAD` subject | `after_doing`'s exact template | same |
| `git status --short` | empty | empty |

Zero merge commits is what makes this a genuine `--ff-only` merge rather than
something else that also moved `main`.

**Verdict: PASS.**

**Explicit non-observable.** The persisted `before_review_result` is a
**placeholder** — `{"exit_code": 0, "output": "Executed by Claude Code hooks
system", "duration_ms": 0}` — written into the completion payload *before* the
hook fires. It is not evidence that `before_review` succeeded, and reading it as
evidence is exactly the "absence of an error is not evidence" trap, sitting in
plain sight inside the payload. AC5 rests on the reflog.

---

## The gate in its failing direction

A gate that fires but does not block is worse than no gate, because it reads as
protection. So the gate was armed and the completion attempted.

**The instrument.** An untracked failing test, `test/stride_gate_probe_test.exs`.
Untracked is the load-bearing property: `before_doing`'s clean-tree check is
`git diff --quiet && git diff --cached --quiet`, which ignores untracked files,
so the probe is invisible to the **claim** and blocks only the **completion**.
Sabotaging a tracked file would have blocked the wrong gate and the run would
never have started.

Pre-flight readings confirmed the instrument before the run: tracked-tree check
`exit=0` (claim will pass), `git status --short` showing only
`?? test/stride_gate_probe_test.exs`, the file not gitignored, and
`mix test --cover` `exit=2` with **1 failure in 7456** — the probe alone.

**Readings.** Pre-run values are shown beside post-run values, because the proof
is that these did *not* change.

| # | Observable | Pre-run | Post-run | Reading |
|---|---|---|---|---|
| 1 | Runner record | — | `status: "hook_blocked"`, `claimed: true`, **`completion_submitted: false`**, `failure.at_step: "after_doing"` | The runner surfaced the block rather than routing around it |
| 2 | **Server holds no completion** | `completed_at=null`, `workflow_steps=0`, `reviewer_result=null`, col 127 | `completed_at=null`, `completed_by_id=null`, **`workflow_steps=0`**, **`reviewer_result=null`**, **col 128 / `in_progress`** | **The load-bearing reading.** Not "an error appeared" — *no completion exists on the server* |
| 3 | Git: `before_review` never ran | branch absent, `main=30aa57c4` | branch `W2073` **still present**, `main` **still `30aa57c4`**, 0 commits, tree dirty with 2 modified files | The commit (command 5/5) was never reached and nothing merged |

**Attribution — resolved from the hook's own message, after three wrong
attempts.** Earlier drafts claimed the block "had two independent causes". That
is mechanically impossible: `run_with_budget` wraps command 1/5 in
`timeout -k 5 <budget>`, so exactly one of two things happens — the command
completes and returns `mix`'s exit code (2, the probe's failure), or it is killed
and returns 124, in which case the probe's failure is *never reached*. The two
are exclusive, and the discriminating observable was textual and available the
whole time (`stride-hook.sh:1665-1672` emits one of two distinct strings).

| Observable | Reading |
|---|---|
| The hook's own stderr, red run | **`Stride after_doing hook command 1/5 timed out after 200s budget`** — the `TIMED_OUT=true` branch |

**So the proximate cause was the timeout, and the injected probe was never
reached.** The runner learned of the probe separately, by investigating after the
block — which is why its record named both. AC2 is unaffected: the gate failed,
it blocked, and no completion exists on the server. But the *designed* experiment
did not fire. The probe was verified to fail the suite in pre-flight (`exit=2`,
1 failure in 7456) and would have blocked the completion had command 1/5
returned; it did not get the chance.

**The budget, and three wrong answers about it.** This section has now been wrong
three times, and every error was caught in review rather than by the run. They
are kept on the page because the failure mode *is* this document's subject: **a
plausible number compared against the wrong denominator.**

- **Round 1** — "200s budget, ~30s headroom", taken from the runner's record.
  Rejected as unverified.
- **Round 2** — "119s against 120s, one second of headroom". Wrong: 120s is the
  *default*, and it is a **section** budget, not one command's.
- **Round 3** — "120s section budget, margin unknown". Still wrong, because
  nobody checked for an override. Both the author and the reviewer asserted "no
  200s budget exists anywhere" after reading only the default path.

| Observable | Reading |
|---|---|
| Default budget, server side | **120 000 ms** — `lib/kanban/hooks.ex:17` |
| Default budget, hook side | **120 s** — `stride/hooks/stride-hook.sh:1254`; clamped to 290s at `:1294` |
| **Effective budget here** | **200 s** — `STRIDE_HOOK_TIMEOUT_OVERRIDE=200` in `.claude/settings.local.json:163`, which `resolve_section_budget` gives precedence over both the server value and the default (`stride-hook.sh:1285-1286`). Confirmed reaching the hook: it emitted `200s budget` in its own failure message |
| **Budget scope** | **Per SECTION, not per command** — `stride-hook.sh:1245-1247`: "The budget is per SECTION (wall clock across all its commands), not per command." Each command is wrapped with the **remaining** budget (`:1578-1603`); a command starting with none left is failed unrun (`:1587-1593`) |
| `mix test --cover`, warm, standalone | **119 s**, exit 0 — command **1 of 5**, timed directly, no `phase_ms` involved |
| Red-run outcome | **Timed out at 200s**, command 1/5, exit 124 — so that command alone exceeded 200s |
| Green-run section duration | **≤ ~169 s** — `phase_ms.after_doing` (W2072) is an **upper bound**, since the phase encloses the hook section *plus* runner overhead. Corroboration only; not load-bearing |

**What is established, without relying on `phase_ms`.** The effective budget here
is 200s because of a local override; the committed default is 120s. Two readings
carry the finding, and neither is a phase measurement:

1. **`mix test --cover` alone measures 119s warm** — and it is command 1 of 5.
   `format`, `credo --strict`, `sobelow` and the commit share the same section
   budget. 119s plus those four exceeds a 120s default with near-certainty.
2. **In the red run, command 1/5 alone exceeded 200s** — far past the 120s
   default, on its own, before any other command ran.

**The finding this exposes, which none of the earlier versions saw.** This repo
completes tasks *only* because `STRIDE_HOOK_TIMEOUT_OVERRIDE=200` is set in a
`settings.local.json` — a file that is per-machine and not committed. On any
machine without it — a fresh clone, a new contributor, CI — `after_doing` would
exceed its budget and no completion could succeed. That is a substantially bigger
problem than the "narrow headroom" every earlier draft described, and it was
hidden precisely because the override made the local symptom mild.

**What is not established.** The three timing readings — 119s (standalone warm,
command 1), ≤169s (whole section, phase reading), and >200s (command 1 alone,
red run) — span roughly a factor of 1.7 for substantially the same work. Command
1 alone exceeding 200s in one run while the entire five-command section came in
under ~169s in another is **not explained by anything measured here**. Build
warmth is the untested candidate; the red run's `elixir_code_server`
`:gen_server.call` EXIT hints at an intermittent hang rather than steady
slowness. **No in-hook per-command timing was ever captured**, so the true
section duration and the real margin under either budget remain unmeasured —
which is exactly what D223's first acceptance criteria now ask someone to
measure. The margin under the 200s override is **at least ~31s and unknown**,
not the "~31s" an earlier draft asserted.

**The transferable lesson**, and why every wrong version is kept above:
runner-reported `phase_ms` is not hook execution time; a single command's timing
is not a reading against a section budget; and a configured default is not an
effective value until you have checked for an override. Each error produced a
number that looked like a measurement. The only one that settled anything was the
hook's own emitted string.

**The runner did not remove the instrument.** The known hazard for this design is
that a runner told to act on a hook failure investigates, finds an unrelated
failing test, deletes it, and completes cleanly — which would have collapsed
observable 1 and left AC2 resting on the transcript. It did not happen. The
runner identified the probe as a deliberate instrument belonging to another
in-progress task and declined to remove it, reporting both blockers instead.
That is the correct call and it is worth recording as observed behaviour rather
than assumed.

**What the scripted suite covers, and what it cannot.** Test 5h in
`stride/hooks/test-stride-hook.sh` already asserts `stride-hook.sh`'s own
contract: exit 2, `hook failed on command N/M` on stderr, execution stopping at
the failure, and the passing command's output kept off stderr. It was not
extended, because it structurally cannot reach the other half of the chain — it
invokes the hook script directly, with no Claude Code harness and no subagent.
The claim AC2 needs is that *PreToolUse exit 2 blocks the Bash call from inside a
runner subagent, so the completion PATCH never reaches the server*. Half of that
is harness behaviour and half is nesting; neither is scriptable from a bash test
file. Observable 2 above is what closes it.

---

## The resume path

Not an acceptance criterion, but a documented branch nothing had ever run, and
run 2 produced the exact precondition for it.

After the probe was cleared by its owner, W2073 was re-dispatched at
`attempt: 2` with `previous_failure` populated. Preconditions were checked first,
as the contract requires: `status=in_progress`, `assigned_to_id=1` (this token's
user), claim valid for a further 45 minutes.

**Reading:** the runner skipped the claim, resumed the intact uncommitted work on
branch `W2073`, and returned `completed` with `completion_submitted: true`,
committed as `2cf4dab1`. Every AC1/AC3/AC4/AC5 observable then read as a pass.

Worth recording: no structured explorer or reviewer block survived attempt 1, so
the runner **re-dispatched both rather than hand-typing a payload** from what it
remembered. That is the behaviour the completion contract wants, and it is the
reason the resumed run's `reviewer_result` is a genuine 15-key object rather than
a reconstruction.

---

## What this run did not exercise

1. **`after_goal` under dispatcher mode.** Both tasks were deliberately
   standalone. `after_goal` here ends in `mix precommit` and `git push origin
   main`, so manufacturing a throwaway goal would have pushed throwaway commits
   to origin — directly against this task's own instruction to pick low-risk
   work. **Proposed cover: W2067**, G406's genuine last child, which is blocked
   on W2066 and runs next anyway. That is the real last-child case, on real work,
   in its real context.
2. **A reviewer returning `changes_requested`,** forcing a fix-and-re-review loop
   inside the runner. It cannot be forced without designing a task to fail
   review, and a task designed to fail review is not a task. Both runs were
   approved. The nearest thing observed was a reviewer **self-correction** on
   W2072 (below), which is not the same code path. Note the asymmetry: W2066's
   *own* review returned `changes_requested` and drove a fix round — but that
   happened in the main loop, not inside a runner, so it does not close this gap.
3. **A `needs_review=true` task halting the dispatcher loop.** The task's
   `testing_strategy` names this as a manual exploration, and it was **not
   exercised**: both W2072 and W2073 were deliberately created with
   `needs_review=false`, because a task parking in Review would have failed AC1
   ("reaches Done") through no fault of the runner. The contract says such a task
   returns `completed_needs_review` and the dispatcher stops rather than looping;
   that path is documented but unobserved here. It is cheap to cover — one task
   with `needs_review=true` — and it is the natural companion to gap 1, since
   both concern what the dispatcher does *after* a runner returns.

---

## Findings

Four, surfaced by the runs rather than sought:

1. **The `after_doing` section exceeds its own default budget, and only a local
   per-machine override hides it.** The committed default is **120s**;
   `mix test --cover` alone measures **119s** warm and is command **1 of 5**,
   with `format`, `credo --strict`, `sobelow` and the commit sharing the same
   section budget; and in the red run that one command exceeded **200s** by
   itself. This machine sets `STRIDE_HOOK_TIMEOUT_OVERRIDE=200` in
   `.claude/settings.local.json`, which is neither shared nor committed. On any
   machine without that override, `after_doing` would exceed its budget and
   **no completion could succeed at all**. A timeout is also indistinguishable
   from a real test failure to anyone reading the result, so every occurrence
   costs a diagnosis. The margin under the override is **at least ~31s and
   unmeasured** — no in-hook per-command timing was ever captured. This
   finding's numbers were wrong three times before this statement; see
   [the budget](#the-gate-in-its-failing-direction) for all three. Nothing above
   rests on a `phase_ms` reading **except the ~31s lower bound**, which uses the
   phase figure as a *bound* rather than a measurement: if the section takes at
   most ~169s, the margin under a 200s budget is at least ~31s. The fresh-clone
   conclusion uses neither.
2. **`stride-workflow` SKILL.md disagrees with itself on the planner.** The
   Step 3 matrix row `small, 2+ key_files` says Plan = Skip; Branch C's second
   bullet dispatches Plan at 3+ acceptance-criteria lines. Both tasks matched
   both. The evidence that this is a real ambiguity and not a theoretical one:
   the two runners recorded **different reasons for the same skip** —
   run 1 "the conflict was resolved toward the matrix row", run 3 "small
   complexity — the planner is dispatched for medium+ tasks only". The `planner`
   telemetry entry is therefore not comparable across runs.
3. **The task-reviewer emitted an unfilled stub as a verdict.** On W2072 it
   returned `pitfalls: {status: "failed", note: "placeholder"}` beside
   `status: approved` with zero issues — a failed section verdict with no
   matching `issues[]` entry, which is internally inconsistent and is exactly
   what the completion gate keys on. It took a correction round to resolve, and
   it was caught only because that round happened to run.
4. **`after_doing` and `before_review` persist `duration_ms: 0`** on every run.
   W1455 exists precisely so the real `after_doing` duration is copied from the
   visible PreToolUse output; it was not. Telemetry only, no correctness impact.

A fifth, narrower one: on the resumed run the record's `telemetry.phase_ms`
carried only `explorer` and `reviewer`, omitting `implementation`, `after_doing`
and `before_review` — the resume path does not reconstruct phase timings for
work it inherited.

### 6. This verification misattributed its own diff — found at its own completion

**D226.** The sharpest finding of the run, because it was produced by the run
rather than looked for, and it is the exact silent class AC4 exists to guard.

`.stride-env-cache` is a single global file at the project root with no
per-task isolation. W2066 claimed with `TASK_BASE_REF=b5737c98`. Its *work* was
to dispatch runners at W2072 and W2073 — and each nested claim rewrote that
shared cache. By completion the cache held W2073's base, `30aa57c4`.

| Moment | `TASK_ID` | `TASK_BASE_REF` |
|---|---|---|
| W2066 claimed | `6161` | `b5737c98` — its real base |
| W2072 claimed by a runner | `6168` | `b5737c98` |
| W2073 claimed by a runner | `6169` | **`30aa57c4`** |
| W2066 completed | `6161` (refreshed) | **`30aa57c4`** — never restored |

**Reading:** W2066's own deliverable is in the gitignored `stride/` subrepo, so
its true `changed_files` is empty. What it actually carries is **W2073's two
files** — `lib/kanban_web/avatar_palette.ex` and its test — uploaded with
`http_code=200` and no error anywhere. A reviewer opening W2066 sees a diff with
nothing to do with it, and nothing reports a problem.

**Dispatcher mode makes this systematic rather than exotic**, because a task
whose work is to dispatch runners necessarily causes nested claims.

**It could not be corrected on the record.** `PATCH /api/tasks/6161` with a
corrected `completion_notes` returned **200 and silently discarded the field** —
completion fields are immutable after completion, but the API reports success
rather than refusing. So W2066's persisted notes still assert its `changed_files`
is empty, which is wrong, and this document is the correction. That silent-200
is filed separately as **D227**.

---

## Caveats

1. One run of each direction is not a distribution. Three runs total.
2. Six `workflow_steps` were verified as **five dispatched plus one skip form**
   (`planner`), not six dispatched. A `small, 2+ key_files` task cannot produce
   six dispatched by the matrix.
3. The persisted `before_review_result` is a pre-hook placeholder and is **not**
   evidence. AC5 rests on `git reflog`.
4. `after_goal` was deliberately not triggered, so `git push origin main` never
   ran. See gap 1.
5. No reviewer returned `changes_requested`, so the re-review loop **inside the
   runner** is unobserved. See gap 2.
6. The red run blocked on `after_doing` command **1/5**. The other four
   commands' blocking is inferred from `stride-hook.sh` stopping at the first
   non-zero (test 5h), not observed live.
7. **The designed experiment did not fire.** The block's proximate cause was the
   200s timeout, not the injected probe — command 1/5 was killed at the budget
   and never returned the probe's failure. AC2 still holds on its own observable
   (no completion exists on the server), but the demonstration was produced by
   an unplanned timeout rather than by the fault this run planted. The probe was
   verified red in pre-flight and would have blocked the completion; it did not
   get the chance. See
   [the gate section](#the-gate-in-its-failing-direction).
8. `changed_files` was populated (2 files, real diffs, `http_code=200`) on
   attempt 1 **even though that attempt never completed** — the diff capture is
   driven by the hook, not by the completion. Defensible, but it means a
   populated `changed_files` is not by itself evidence that a task completed.
9. Hook mode was `stride_dev`. The repo's steady state is `plugin_dev` with all
   five bodies empty, so **this run does not describe how the repo behaves day to
   day**.
10. The credential check searches for the live token's literal value in the
    artifacts the run produced. It does not prove the absence of every class of
    secret.
11. Both tasks were authored for this verification by the same agent that ran
    them. They are genuine fixes to real latent bugs, but they were not
    independently specified.
12. **AC1's "through the dispatcher" half is weaker than its "reaches Done"
    half.** Done rests on the server record; the dispatcher half rests partly on
    a transcript absence (no `Edit`/`Write` in the main loop) with no pre-run
    value shown — a weaker standard than this document demands of its other
    negatives. The returned records' `task_identifier` and phase telemetry
    corroborate it, but it is not durably evidenced the way AC2's observable 2 is.
13. **This document's budget figures were wrong three times**, and every error
    was caught in review rather than by the run — an unverified 200s taken from
    a runner's record; then 120s compared against one command's standalone
    timing when it is a five-command section budget; then 120s again, by an
    author *and* a reviewer who both asserted "no 200s budget exists" after
    reading only the default path and neither checking for an override. The
    first answer turned out to be right for the wrong reason. Recorded because a
    verification document that silently fixed its own numbers would be asking
    for more trust than it earned — and because the error class is this
    document's own subject: a plausible number compared against the wrong
    denominator, and a configured default mistaken for an effective value.
14. **The verification ran with a non-default hook budget.** Every reading here
    was taken with `STRIDE_HOOK_TIMEOUT_OVERRIDE=200` in effect. A run on a
    machine without that override would behave differently — and per finding 1,
    would not complete at all.

## Security

The run drives the live API and a real git branch, so the check is that no
credential reached anything the run produced.

| Observable | Reading |
|---|---|
| Live token grepped across `.stride/.verify-*.json`, `.stride-env-cache`, `.stride-changed-files.json`, `.stride-diff-upload-state`, this document | **PASS** — absent from all |
| Token occurrences inside the captured diffs | **0** on both runs |
| `.stride_auth.md` / `.stride.md` in `changed_files` paths | **absent** on both runs |
| Returned records | No `Bearer`, no token, no credential in `failure.detail` — the field the contract flags as most likely to leak, and the one the red run actually populated |
| **Git objects** the run created — `30aa57c4`, `2cf4dab1` on kanban `main`, `6c38a1f` in the subrepo | **Clean.** The two kanban commits touch only the four `lib/`+`test/` files and carry `after_doing`'s fixed subject template; the subrepo commit contains only this document. Structurally protected as well: `.gitignore:44,46,47,48,97` cover `.stride_auth.md`, `.stride-env-cache`, `.stride-changed-files.json`, `.stride-diff-upload-state` and `.stride/`, so `after_doing`'s `git add -A` cannot stage any of them |

Scoped honestly: this covers artifacts the run *produces*. The token legitimately
appears inside the runner's own curl invocations, which is its sanctioned use.

**One exposure this does not eliminate.** The extraction idiom keeps the token
out of literal command text and out of everything persisted — but
`-H "Authorization: Bearer $T"` still materialises it in **curl's `argv`** for
the life of the call, where `ps` can read it, and it would be written verbatim
by `set -x` or a `script` capture. That is ephemeral rather than an artifact, so
it does not defeat the consideration, and it is the same idiom `stride-hook.sh`
itself uses. It is recorded because the Reproduction block below is a recipe
others will run: **do not run it under `set -x`**, and on a shared host prefer
feeding the header to `curl --config -` over stdin so the secret never reaches
the process arguments.

## Reproduction

```bash
cd /Users/cheezy/dev/elixir/kanban

# 0. CHECK THE HOOK BUDGET FIRST — every reading below assumes the override.
printenv STRIDE_HOOK_TIMEOUT_OVERRIDE          # expect 200
#    Set in .claude/settings.local.json, which is per-machine and NOT committed.
#    On a machine without it the budget is the 120s default, and per finding 1
#    after_doing is expected to TIME OUT — which looks exactly like a real test
#    failure. Do not start diagnosing a red gate before checking this line.

# 1. Baseline, then switch to real hooks. The tree MUST be clean afterwards or
#    before_doing blocks every claim.
git rev-parse main; git branch --list; git status --short
./stride_dev.sh && git status --short          # expect empty

# 2. Green-baseline every after_doing command, so a later red is attributable.
mix test --cover; mix format --check-formatted
mix credo --strict; mix sobelow --config .sobelow-conf
mix hex.outdated                                # vetoes before_doing if red

# 3. Create the two tasks (POST /api/tasks, root key "task"), then have a human
#    move ONE to Ready. Promotion is a board-UI action; the API cannot do it.

# 4. Green run: dispatch stride:task-runner with the six-field dispatch object.
#    Run NO Bash between the dispatch and the returned record.

# 5. Read every observable. The token is derived inline and never appears as
#    literal command text — the same extraction stride-hook.sh uses.
U=$(grep -E '\*\*API URL:\*\*' .stride_auth.md | grep -oE 'https?://[A-Za-z0-9._:/-]+' | head -n1)
T=$(grep -E '^\- \*\*API Token:\*\*' .stride_auth.md | grep -oE '`[^`]+`' | head -n1 | tr -d '`')
curl -sS -H "Authorization: Bearer $T" "$U/api/tasks/<ID>" | tee .stride/.verify-G.json

jq -r '.data | "col=\(.column_id) status=\(.status) completed_at=\(.completed_at)"' .stride/.verify-G.json
jq -e '.data.reviewer_result | has("status") and has("issue_counts") and has("issues")
       and has("acceptance_criteria") and has("project_checks") and has("testing_strategy")
       and has("patterns") and has("pitfalls") and has("security_considerations")' .stride/.verify-G.json
jq -r '.data.reviewer_result | keys_unsorted | join(", ")' .stride/.verify-G.json
jq -r '"project_checks=\((.data.reviewer_result.project_checks//[])|length) ac=\((.data.reviewer_result.acceptance_criteria//[])|length)"' .stride/.verify-G.json
jq -r '"task_lines=\((.data.acceptance_criteria // "") | split("\n") | map(select(length>0)) | length)"' .stride/.verify-G.json
jq -r '(.data.workflow_steps // []) | length' .stride/.verify-G.json
jq -r '"empty_diffs=\((.data.changed_files // []) | map(select((.diff // "") == "")) | length)"' .stride/.verify-G.json
grep -E '^TASK_ID=|^TASK_IDENTIFIER=' .stride-env-cache      # must match THIS task
git reflog --date=iso -14; git branch --list '<IDENT>'
git log --merges --oneline <BASELINE>..main                  # must be empty

# 6. Red run: plant an UNTRACKED failing test, verify the tracked tree is still
#    clean (so the claim passes) and that the probe alone turns the suite red.
#    Then dispatch, and read the NEGATIVE: completed_at null, workflow_steps 0,
#    reviewer_result null, still column 128, branch still present.

# 7. Restore. Idempotent, and the first action of every abort path.
rm -f test/stride_gate_probe_test.exs && ./plugin_dev.sh \
  && diff -q .stride.md .plugin_dev.md && git branch --list 'W20*' && git status --short
```

## Recommendations

Ordered by return. Findings 1–4 and the moduledoc error were filed as defects
**D221–D225** at the time of writing; all five landed in the Backlog.

1. **Resolve the planner conflict in `stride-workflow` SKILL.md** — **D221**
   (finding 2). Cheapest possible fix — a wording change — and it affects every
   task in every session, not just dispatcher mode. Until it is fixed, the
   `planner` telemetry entry is not comparable across runs.
2. **Stop the task-reviewer emitting placeholder section verdicts** — **D222**
   (finding 3). This is the only finding whose failure mode is a *wrong verdict
   reaching the Review queue* rather than a missing number. A `failed` section
   with an empty `issues[]` should be impossible to emit.
3. **Get the `after_doing` section under its *default* budget** — **D223**
   (finding 1). This is now the most urgent of the five, and its severity was
   invisible until the override was found: a single command measures 119s
   against a 120s default shared by five, so the repo is only completable on
   machines carrying an uncommitted `settings.local.json` override. Either bring
   the section under 120s (split coverage out of the blocking gate) or raise the
   *shared, committed* budget so the override is not load-bearing — and
   **measure the section per-command first**, because this document got the
   arithmetic wrong three times before finding the override, and the readings it
   does have span a factor of 1.7. D223's premise has been corrected three times
   and now asks for that measurement explicitly.
4. **Copy the real `after_doing` duration** into the completion payload per
   W1455, and reconstruct `phase_ms` on the resume path — **D224** (finding 4
   and the resume-path omission).
5. **Correct the `AvatarPalette` moduledoc** — **D225**. It misstates the
   mapping (42 is `human-green`, 43 is `human-pink`), and W2073's own acceptance
   criteria inherited the error from it, which is how a prose bug becomes a
   requirements bug.
6. **Cover `after_goal` under dispatcher mode on W2067** (gap 1), G406's genuine
   last child — including the push verification, since the grace-window worker
   flips the goal to Done but does not push. Not filed as a defect: it is a
   coverage gap in this verification, not a fault in the code.
7. **Cover the `needs_review=true` stop** (gap 3) — one task with
   `needs_review=true`, dispatched, checking that the runner returns
   `completed_needs_review` and that the dispatcher stops the loop rather than
   claiming another task. Also a coverage gap rather than a defect, and the
   cheapest of the three to close.
