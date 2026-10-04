# Multi-task measurement after the accuracy, speed and token goals (W2259)

Measured 2026-10-04. This is the measured "after" that
[`porting-g446-g448.md`](porting-g446-g448.md) § The evidence behind the goals
reserves for W2259; the G439 table there is the "before".

**Read the comparator before any number.** The two sessions ran different task
mixes, on different plugin versions, through different execution paths. Every
figure below is per task or per request, and names its comparator and session
position. No session total is compared, and no single saving percentage is
quoted — this lineage has been mis-quoted from totals before.

## The runs

| | Measured run | Comparator |
|---|---|---|
| Session | `ba8fa028-45d7-4a67-8394-a133716de1f6` | `0286faaf-e02c-440a-92bb-ee5ba28a6af3` (G439) |
| Plugin | `stride` **1.83.0** (released; every skill base dir in the transcript is `stride/1.83.0`) | `stride` 1.78.0 |
| Record bound | lines `0..404` (frozen: the transcript was still growing) | lines `0..2364` for the per-task rows; `0..4418` for the 518-request reproduction |
| Tasks measured | 3 — W2267, W2268, W2269 (goal G450), each `medium` | 3 at the same positions — D337, D338, D339 |
| Path | **dispatcher mode**: one `stride:task-runner` per task, each running its own explorer, planner, reviewer and security reviewer | **inline**: every subagent dispatched from the main loop |
| Work | plugin skill/doc edits plus hook-suite pins in two nested repos | 7 defects + 2 work tasks of plugin work |

**Session position.** Before the three runner tasks, the measured session claimed
W2259 (this task), dispatched its explorer, and unclaimed it — so under the
**claim convention** the runner tasks sit at positions **2–4**, and under the
**dispatch convention** at runner positions **1–3**. The comparator rows are G439's
claim positions 2–4, which all end before G439's first compaction (line 2523).
The measured window contains **no compaction** in the main loop, and none of the
session's 18 subagent transcripts contains one, detected from record structure
(see Caveats).

## Main-loop context per request

Context per request = `input + cache_creation + cache_read` of one request,
deduplicated by message id. "Growth" is last minus first request of the task's
main-loop window.

| Task (claim pos) | Requests | First → last | Mean per request | Growth | Comparator (claim pos) | Requests | First → last | Mean | Growth |
|---|---:|---|---:|---:|---|---:|---|---:|---:|
| W2267 (2) | 7 | 156,377 → 161,449 | 158,971 | 5,072 | D337 (2) | 46 | 469,876 → 611,603 | 548,199 | 141,727 |
| W2268 (3) | 10 | 161,449 → 167,364 | 164,254 | 5,915 | D338 (3) | 68 | 611,603 → 816,582 | 723,890 | 204,979 |
| W2269 (4) | 5 | 167,364 → 171,408 | 169,211 | 4,044 | D339 (4) | 43 | 816,582 → 925,554 | 876,318 | 108,972 |

**Read the growth column, not the mean.** The mean is mostly the context each
task *inherited*, which is session position plus everything before it — W2267
inherited 156K and D337 inherited 470K, and neither number says anything about
the task itself. Growth is what the task added: 4–6K per dispatched task against
109–205K per inline task at the same claim positions. That is the
accumulation dispatcher mode was built to stop, and at positions 2–4 it stopped.

## Subagent tokens per task

Three measures exist and they are **not** interchangeable; the first is the one
this document uses.

| Task (claim pos) | Transcript sum, recursive (context entered) | Subagent requests | Dispatches | Harness `subagent_tokens` | Runner self-report `nested_tokens` |
|---|---:|---:|---:|---:|---:|
| W2267 (2) | 19,205,419 | 121 | 5 | 290,330 | 409,591 |
| W2268 (3) | 23,249,547 | 148 | 6 | 298,251 | 557,896 |
| W2269 (4) | 23,585,769 | 154 | 5 | 297,815 | 491,218 |
| *D337 (2)* | *6,399,196* | *59* | *7* | — | — |
| *D338 (3)* | *16,078,011* | *128* | *9* | — | — |
| *D339 (4)* | *6,465,909* | *61* | *7* | — | — |

- **Transcript sum** walks `subagents/agent-*.meta.json` recursively through
  `parentAgentId`, so a runner's own explorer, planner and reviewers are counted
  under its task. Usage deduplicated by message id per transcript.
- **Harness `subagent_tokens`** (the task notification) is two orders of
  magnitude below the transcript sum and is not a consumption figure for the
  subtree — never sum it or compare it with the first column.
- **Runner `nested_tokens`** is the runner's own report of its children; it
  excludes the runner itself. Record-only; not a measurement.

**Subagent tokens per task went up, and that is expected rather than hidden.**
Under dispatcher mode the runner is itself a subagent that carries the whole
lifecycle — the work the inline path did in the main loop now happens in the
runner's context, so it moves into this column. The two columns have to be read
together, which is what the next table does.

## Produced vs entered

Following the G407 / W2090 framing, with one definition stated so it cannot drift:
**entered** = the task's main-loop context summed over its window; **produced** =
entered + its subagent transcript sum. **Entered share** = entered ÷ produced.

| Task (claim pos) | Entered (main loop) | Produced | Entered share | Comparator (claim pos) | Entered | Produced | Entered share |
|---|---:|---:|---:|---|---:|---:|---:|
| W2267 (2) | 1,112,803 | 20,318,222 | **5.5%** | D337 (2) | 25,217,176 | 31,616,372 | **79.8%** |
| W2268 (3) | 1,642,541 | 24,892,088 | **6.6%** | D338 (3) | 49,224,528 | 65,302,539 | **75.4%** |
| W2269 (4) | 846,057 | 24,431,826 | **3.5%** | D339 (4) | 37,681,684 | 44,147,593 | **85.4%** |

**A dispatched task put 3.5–6.6% of what it produced into the main loop; the inline
tasks at the same claim positions put 75–85% in.** This points the same way as
the asymmetry W2090 found (0.70% for D274 at claim position 2 on 1.67.0, against
66–90% for its comparator B's inline tasks at claim positions 1–4), now on the
released plugin with the mode on by default. W2090 counted its "entered" column
differently, so read the two as the same direction, not the same quantity. It is a statement about where tokens are paid, not
about how many: **do not compare the "Produced" columns** — they are different
tasks with different work, and the pitfall this task names applies to them
exactly as it does to session totals.

## Wall clock per task

Definitions differ by path and are stated per side. **Inline:** first claim curl
→ first complete curl. **Dispatched:** the `stride:task-runner` Agent call → the
arrival of the runner's record in the main loop.

| Task (claim pos) | Wall clock | Comparator (claim pos) | Wall clock |
|---|---:|---|---:|
| W2267 (2) | 36.4 min | D337 (2) | 28.3 min |
| W2268 (3) | 32.1 min | D338 (3) | 38.6 min |
| W2269 (4) | 20.8 min | D339 (4) | 23.6 min |

Means are 29.8 and 30.2 minutes. **No wall-clock effect is claimed** — three
different tasks a side cannot separate the plugin from the work. What the rows do
show is that isolation did not cost wall clock at this size: a dispatched task
also re-runs a fresh base context, and every runner dispatched a planner (the
inline comparator dispatched one in one of three).

W2268's runner sent an interim notification at 20.7 min while its own background
work was still running; its record arrived at 32.1 min, which is the figure above.

The comparator table's 231-minute session wall clock is a session total over a
different task count; it is not compared.

## Reviewer dispatches per task

| Task (claim pos) | `task-reviewer` | `security-reviewer` | Comparator (claim pos) | `task-reviewer` | `security-reviewer` |
|---|---:|---:|---|---:|---:|
| W2267 (2) | 1 | 1 | D337 (2) | 3 | 3 |
| W2268 (3) | 1 | 1 | D338 (3) | 3 | 4 |
| W2269 (4) | 1 | 1 | D339 (4) | 3 | 3 |

**1.0 reviewer dispatches per task, against 3.0 at the same positions** (and 19
for 9, 2.11 per task, across all of G439 lines `0..4418`). W2267's single round
reported one important and two minor issues; its runner fixed them and recorded
that no round-two trigger fired, so no second round was dispatched — the
review-round-cap rule doing what it was written to do. W2268 and W2269 were approved in one round.

## Stop-gate blocks

| Task (claim pos) | Blocks in window | Comparator (claim pos) | Blocks in window |
|---|---:|---|---:|
| W2267 (2) | 0 | D337 (2) | 2 |
| W2268 (3) | 2 | D338 (3) | 2 |
| W2269 (4) | 1 | D339 (4) | 2 |

**3 blocks across 3 tasks, against G439's 2 per task at every one of its 9
positions (18 in lines `0..4418`).** All 3 measured blocks were **false positives
of one kind**: each fired while a runner held the task, and the gate attributed
the runner's claim — or the previous runner's `needs_review=false` completion — to
the main session ("unfollowed completion" twice, "held claim" once). The
dispatcher correctly took no action on any of them. G439's blocks were the
inline variant of the same blind spot (each sampled one fired while a background
subagent was running). The count fell; the cause did not change, and wants a
defect against the Stop gate's runner awareness.

## Caveats

1. **Different task mixes, three tasks a side.** Same claim positions, different
   work. Per-request context, growth and entered share are path effects that
   W2090 already showed survive every comparator; wall clock and "Produced" are
   not, and are reported for completeness only.
2. **Different plugin versions on the comparator side.** G439 ran 1.78.0, so the
   comparator also predates the accuracy and token goals (G446–G448). The
   measured run cannot separate dispatcher mode's effect from those goals'.
3. **Compaction.** None in the measured window — main loop or subagents. G439 is
   compacted at lines 2523 and 4200 (each a `compact_boundary` record followed by
   an `isCompactSummary` record), so its "70K to 965K" spans three context
   windows; the per-task comparator rows above stop at line 2364, before either.
   `w2067-recursive.py`'s compaction guard matches the *string*
   `compact_boundary`, which two subagent transcripts in this session (the
   measuring task's own explorer and planner) merely mention;
   `w2259-multitask.py` tests record structure instead.
4. **The measuring task is excluded.** W2259 sits at claim position 1 of the
   measured session, was unclaimed before the runs, and was re-claimed after;
   its rows are `INCOMPLETE` in the script output and appear in no table.
5. **Background overlap.** Subagent spans overlap each other and the main loop,
   so subagent time is never added to wall clock.
6. **The runners' `exploratory_env` was `null`.** Step 5.5 skipped on all three
   tasks (no authorized environment), so their manual tests went to a human. An
   inline comparator task that ran an exploratory session (D336, position 1)
   carries that cost; positions 2–4 on both sides do not.

## Reproduction

```bash
cd /Users/cheezy/dev/elixir/kanban

# counting rules (dedupe by message id, structural compaction, stop blocks)
python3 stride/docs/scripts/w2259-multitask.py --self-test

# every measured-run figure in this document
python3 stride/docs/scripts/w2259-multitask.py \
  --session ba8fa028-45d7-4a67-8394-a133716de1f6 --lines 0:404

# every comparator per-task row (claim positions 1-4, before the first compaction)
python3 stride/docs/scripts/w2259-multitask.py \
  --session 0286faaf-e02c-440a-92bb-ee5ba28a6af3 --lines 0:2364

# reproduce G439's 518 main-loop requests, 223,399,601 context, 19 reviewer
# dispatches and 18 stop blocks (from 1,103 content-block records)
python3 stride/docs/scripts/w2259-multitask.py \
  --session 0286faaf-e02c-440a-92bb-ee5ba28a6af3 --lines 0:4418

# plugin version of each transcript
grep -o 'stride/1\.[0-9]*\.0/skills' \
  ~/.claude/projects/-Users-cheezy-dev-elixir-kanban/ba8fa028-45d7-4a67-8394-a133716de1f6.jsonl
```

Quoted from the measured session's records, not recomputed by the script: the
harness `subagent_tokens` and runner `nested_tokens` (the three task
notifications and runner records), W2268's 20.7-minute interim notification (its
first task notification, 15:18:13Z, against the 14:57:31Z dispatch), W2267's
review issue counts (its runner record), and which Stop-gate condition each of
the 3 blocks named (their `stop_hook_summary` records; the script counts them,
the reason labels are read off the gate's own message names). Aggregates only: no transcript excerpt, hook output or record text is
reproduced here.
