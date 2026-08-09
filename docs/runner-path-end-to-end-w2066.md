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
one; the documented `hook_blocked` resume path was exercised and works — and
`after_goal` under dispatcher mode and a reviewer `changes_requested` round
remain **unexercised** and are named as gaps below.

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

**Attribution, stated honestly.** The block had **two independent causes**, not
only the probe. `mix test --cover` also **exceeded the `after_doing` budget**.
AC2 is satisfied either way — both are genuine `after_doing` failures and the
completion provably did not happen — but the block is not cleanly attributable
to the injected fault alone. That timeout is a real finding in its own right and
is carried into [Recommendations](#recommendations).

**The budget, measured rather than assumed.** This paragraph has now been wrong
twice, in the same way both times, and both errors were caught in review rather
than by the run. They are recorded rather than quietly amended, because the
failure mode is the subject of this document: *a plausible number compared
against the wrong denominator.*

- **Round 1** claimed a **200s** budget with ~30s of headroom, taken from the
  runner's own record. No 200s budget exists anywhere. It conflated
  runner-reported *phase wall-clock* with *hook execution time*.
- **Round 2** claimed **119s against 120s → one second of headroom**. The 120s
  is real, but it is not `mix test --cover`'s budget. It conflated *one
  command's duration* with *the whole section's shared budget*.

| Observable | Reading |
|---|---|
| Configured budget, server side | **120 000 ms** — `lib/kanban/hooks.ex:17`, `"after_doing" => %{blocking: true, timeout: 120_000}` |
| Configured budget, hook side | **120 s** — `stride/hooks/stride-hook.sh:1254`; clamped to 290s at `:1294`. **No 200s budget exists anywhere** |
| **Budget scope** | **Per SECTION, not per command** — `stride-hook.sh:1246-1248`: "The budget is per SECTION (wall clock across all its commands), not per command." Each command is wrapped with the **remaining** budget (`:1578-1603`), and a command that starts with nothing left is failed unrun with `120s section budget exhausted before this command started` (`:1587-1593`) |
| `mix test --cover`, warm build, timed standalone | **119 s**, exit 0 — **not comparable to the section budget**, since four more commands share it |
| Did the full section ever fit? | **Yes.** The commit is command **5/5**, and both green runs produced it — `30aa57c4` and `2cf4dab1`, carrying `after_doing`'s exact subject template. All five commands completed inside 120s, so in those runs the test command took materially less than the standalone 119s |

**What is actually established.** The budget is 120s for the whole section. A
standalone warm `mix test --cover` was measured at 119s. Both green runs fit all
five commands inside the budget, so their test runs were faster than that
standalone figure. The red run exhausted the budget at command 1/5.

**What is not established, and is left open rather than guessed at.** Why the
standalone measurement (119s) so far exceeds what the same command must have
taken inside the passing runs is **not explained by anything measured here**.
Build warmth is the obvious candidate — the attempt-2 runner reported
pre-warming the test build — but no timing was captured inside the hook to
confirm it, so the true in-hook duration and the real margin are unknown. The
fragility is real and is arguably *understated* by "one second of headroom": a
command that can take ~119s standalone shares a 120s budget with four others,
and it exhausted that budget in one of three runs. But the margin cannot be
quantified from these runs, and D223 asks for it to be measured rather than
inferred.

**The transferable lesson**, which is why both errors are kept on the page:
runner-reported `phase_ms` is phase wall-clock, not hook execution time; and a
standalone command timing is not a reading against a section budget. Neither
comparison is valid, and both produce numbers that look like measurements.

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

1. **`after_doing`'s 120s section budget is shared across five commands, and one
   of them can take ~119s standalone.** The budget covers `mix test --cover`,
   `mix format --check-formatted`, `mix credo --strict`, `mix sobelow` and the
   commit *together*; a standalone warm `mix test --cover` was measured at 119s;
   and the budget was exhausted at command 1/5 during the red run, blocking the
   completion. Both green runs did fit all five commands inside it, so the
   in-hook test duration is lower than the standalone figure — by an unmeasured
   amount. The block is indistinguishable from a real test failure, so every
   occurrence costs a diagnosis. **The margin is not quantified here**, and the
   quantification is part of what D223 asks for. This finding's numbers were
   wrong twice before this statement; see
   [the budget](#the-gate-in-its-failing-direction) for both errors.
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
7. **The red block is not cleanly attributable to the injected fault.** The
   budget exhaustion was an independent, unplanned second cause. Whether it
   would have blocked attempt 1 on its own is **not** established — see the
   budget table under
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
13. **This document's budget figures were wrong twice**, in the same way both
    times, and both errors were caught in review rather than by the run — first
    a non-existent 200s budget taken from a runner's record, then a real 120s
    budget compared against one command's standalone timing when it is shared
    across five. Recorded because a verification document that silently fixed
    its own numbers would be asking for more trust than it earned — and because
    the error class is the document's own subject: a plausible number compared
    against the wrong denominator.

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
curl -sS -H "Authorization: Bearer $T" "$U/api/tasks/<ID>" -o .stride/.verify-G.json

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
3. **Get `after_doing` off its budget ceiling** — **D223** (finding 1). The 120s
   is a *section* budget shared by five commands, one of which takes ~119s
   standalone, and it was exhausted at command 1/5 in one of three runs. Split
   coverage out of the blocking gate, or raise the budget — but **measure the
   section first**, because this document could not quantify the real margin and
   twice got the arithmetic wrong trying. D223's premise has been corrected
   twice and now asks for that measurement explicitly.
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
