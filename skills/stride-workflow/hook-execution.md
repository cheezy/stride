# Hook Executor Reference

The agent-side hook executor runs the commands parsed from `.stride.md` (see [parser.md](parser.md)). It receives a `hook` block from the Stride server at three lifecycle points — `POST /api/tasks/claim`, `PATCH /api/tasks/:id/complete`, and `PATCH /api/tasks/:id/mark_reviewed` — and exports the values from the server's `hook.env` payload into the child process environment before invoking the matched `.stride.md` section.

## Server-Supplied Environment Block

The executor's **single source of truth** for every variable it exports is `hook.env` in the server response. The executor MUST NOT invent, derive, or look up these values client-side. If the server omits a key, the executor sets it to the empty string and continues — it never errors on a missing key.

This contract applies to every hook (`before_doing`, `after_doing`, `before_review`, `after_review`, `after_goal`). The set of keys differs by hook (see the table below); the forwarding rule is identical.

## Variable Inventory by Hook

| Variable | `before_doing` | `after_doing` | `before_review` | `after_review` | `after_goal` |
|---|:---:|:---:|:---:|:---:|:---:|
| `HOOK_NAME` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `AGENT_NAME` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `BOARD_ID` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `BOARD_NAME` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `COLUMN_ID` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `COLUMN_NAME` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `TASK_ID` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_IDENTIFIER` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_TITLE` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_DESCRIPTION` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_STATUS` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_COMPLEXITY` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_PRIORITY` | ✓ | ✓ | ✓ | ✓ | — |
| `TASK_NEEDS_REVIEW` | ✓ | ✓ | ✓ | ✓ | — |
| `GOAL_ID` | — | — | — | — | ✓ |
| `GOAL_IDENTIFIER` | — | — | — | — | ✓ |
| `GOAL_TITLE` | — | — | — | — | ✓ |
| `GOAL_DESCRIPTION` | — | — | — | — | ✓ |

`after_goal` fires when the final remaining task inside a goal completes — i.e., when the goal itself transitions to Done. It carries `GOAL_*` instead of `TASK_*` because the lifecycle event belongs to the goal, not to any single task. The `BOARD_*` / `COLUMN_*` / `AGENT_NAME` / `HOOK_NAME` keys are still present so that hook scripts can reference the board context without hard-coding it.

## `GOAL_*` Forwarding Rule

For `after_goal`, the executor:

1. Reads the `after_goal` entry's `env` object from the server's response payload (the same response that delivers the hook to the agent — the entry arrives in the `hooks` array of the `/complete` or `/mark_reviewed` response).
2. Exports each key/value pair into the child process environment using the same export mechanism as the existing `TASK_*` pattern — escaped `KEY='value'` lines applied under `set -a` and appended to the env cache in the shell executor, `[System.Environment]::SetEnvironmentVariable(..., 'Process')` in PowerShell. Values are escaped so a crafted task title cannot inject shell commands; keys that are not valid shell identifiers are dropped.
3. Does NOT look up the goal record or query the API for any `GOAL_*` value. If the server omits a key (for example `GOAL_DESCRIPTION` on a goal whose description was never set), the executor exports it as the empty string. The child command sees the variable as defined-but-empty, which matches POSIX expectations and prevents `set -u` aborts inside user commands. **One response-local exception:** when the server omits `GOAL_ID` from the entry's `env` — or supplies it empty — the executor derives `GOAL_ID` from the completed task's `parent_id` in the **same intercepted response payload** (`data.parent_id`). The parent of the completing final child IS the goal, so this involves no lookup and no extra round-trip. The fallback applies to `GOAL_ID` only; `GOAL_IDENTIFIER`, `GOAL_TITLE`, and `GOAL_DESCRIPTION` have no safe local derivation and export as `""` when omitted.
4. Treats `after_goal` as a blocking hook — see [Blocking Behavior, Timeout, and Result Capture](#blocking-behavior-timeout-and-result-capture) below for the wait, timeout, and `{exit_code, output, duration_ms}` reporting contract.

### Precedence Over Cached Values

Server-supplied env keys are applied **after** the env cache loads, so for any key the server supplies, the server's value wins over a stale cached value. Keys the server does not supply keep their cached values — during `after_goal` the claim-time `TASK_*` variables therefore remain visible, pointing at the just-completed child task. `HOOK_NAME` is never taken from the server env or written to the cache (the executor routes on its own value and sets `HOOK_NAME=after_goal` explicitly around the section run); `TASK_BASE_REF` is likewise never overwritten by server env (it is a client-only diff anchor owned by the claim branch — see [`TASK_BASE_REF` Lifecycle](#task_base_ref-lifecycle)).

## `TASK_BASE_REF` Lifecycle

`TASK_BASE_REF` is the diff anchor for the per-file `changed_files` snapshot: `after_doing` (and the `before_review` self-heal retry) diff the working tree against it, and the result is what reviewers see in the Review column's file-diff panel. It is **client-only** — never supplied by the server, never overwritten by server env forwarding — and its lifecycle is owned entirely by the claim route (D142):

1. **Stripped at claim interception.** When the executor intercepts a claim (`post` + `/api/tasks/claim`), it refreshes the task **identity** lines in the env cache but deletes any inherited `TASK_BASE_REF` line immediately. A base ref recorded under a previous task or session must never survive into a new task window — even if the process dies before step 2 runs.
2. **Written after `## before_doing` finishes.** The base is captured via `git rev-parse HEAD` only **after** the `## before_doing` section has run, regardless of the section's exit code and with no `jq` dependency. The section's `git pull` moves HEAD; capturing before it anchors the diff at the *pre-pull* commit, which makes the snapshot span commits another clone pushed — the exact D132 incident, where a completed rate-limiting task from a different computer appeared inside an unrelated defect's review diff. Consequently `$TASK_BASE_REF` is **not visible inside the `## before_doing` section itself** — at that point it does not exist yet for the new task. The write also stamps a companion `TASK_BASE_REF_TRUSTED='1'` cache line: a base established this way *is* the task branch point by construction, and the guard below uses the marker to avoid re-judging it against origin refs that the workflow's own pushes may later move.
3. **The dirty baseline moves with it.** The claim-time dirty-path baseline (`.stride-dirty-baseline`, W1457) is recorded at the same post-section moment, hashing paths against the same post-pull base, so the exclusion set and the diff anchor can never disagree.
4. **Trust-guarded at consumption.** Every snapshot capture first passes the base through a staleness guard (`resolve_snapshot_base`). The guard recomputes the base from the **task branch point** — the merge-base of HEAD and the origin default branch — and says so on stderr, whenever the stored value is (a) empty or unresolvable, (b) not an ancestor of HEAD (e.g. rebased away by `git pull --rebase`), or (c) a strict ancestor of the branch point, meaning the diff range would include commits pulled from origin. Rule (c) applies only to bases **without** the `TASK_BASE_REF_TRUSTED` marker — i.e. values inherited from an older plugin or a previous session, the D132 class — because a marked base is the branch point by construction and `origin/main` may legitimately advance past it when the workflow pushes its own task commits before completing. A repo with no origin branch has no branch point to judge against (and no cross-clone pull is possible), so the value passes through unchanged. The guard never silently substitutes: every recompute is announced in the hook output. The judgment runs **once per task window**: `finalize_after_doing` resolves at its early pre-command capture (before the section's own `git push` can move origin refs), memoizes the result for the post-command refresh, and persists it as a `base=` line in `.stride-diff-upload-state` so the `before_review` self-heal reuses the same judgment instead of re-resolving.
5. **Committed task work always survives.** Paths that differ between the base and HEAD are the task's own commits by definition, so the dirty-baseline filter can never exclude them (D137 silently dropped 4 tracked edits and an untracked migration whose content matched their claim-time hashes after the auto-commit committed them).
6. **Cleared with the lifecycle.** The env cache (including `TASK_BASE_REF`) is removed after `after_review`, and the next claim repeats the cycle from step 1.

## Response Payload Source (untruncated)

Step 1 above reads the server's response payload. That payload reaches the executor through the harness as `tool_response.stdout`, which the harness **truncates** for large responses — a `/complete` response echoing a full `reviewer_result` (25 `project_checks`) can exceed the truncation threshold, cutting the JSON mid-string. A truncated payload is invalid JSON, so naive parsing silently fails to detect an `after_goal` entry and the goal-completion push never fires. The executor resolves the payload in this order:

1. **Canonical response file (fast path).** The completion/claim/mark_reviewed curls capture the full response to `$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json` (the `| tee` pattern the `stride-completing-tasks` / `stride-claiming-tasks` skills document). When that file is present and holds valid JSON, the executor reads it in preference to `tool_response.stdout` — it is untruncated by construction. This file lives in the same gitignored `.stride/` directory as the orchestrator marker and never enters a task's `changed_files` snapshot.
2. **`tool_response.stdout` (fallback).** When no canonical file exists, the executor parses the inline stdout as before (unwrapping the `{"stdout": "..."}` Bash-tool shape, then the raw-object and persisted-output-file shapes). A complete stdout is authoritative; a truncated one yields no payload and falls through.
3. **Hook-initiated fresh call (the guarantee).** When neither source yields a complete payload, the executor issues its own `GET /api/tasks/:id/after_goal_status` — a compact, fixed-size endpoint that is never truncated, called from a subprocess the hook spawns (not subject to the harness's tool-output truncation) and needing zero agent cooperation. This is the reliability guarantee: `after_goal` detection does not depend on the agent's curl output being intact or on the capture file being written.

The three sources are mutually exclusive in effect — the `## after_goal` section runs at most once regardless of which source detected it. The capture file is therefore best-effort: it saves the extra round-trip when present, but its absence never breaks detection.

## Why Server-Sourced

`GOAL_ID` and `GOAL_IDENTIFIER` are not present in any prior hook's `hook.env`, and `after_goal` fires after the claim/complete cache has been cleared. Letting the executor reach back into the API to "find" the goal would mean two extra round-trips per goal completion and a divergence risk if the goal record changed between the lifecycle event firing and the executor running. Forwarding the server's authoritative values eliminates both problems.

Hook authors writing `## after_goal` blocks should therefore reference `$GOAL_*` directly, trusting that the values match the goal that just finished:

```bash
## after_goal

```bash
echo "Goal $GOAL_IDENTIFIER ($GOAL_TITLE) finished"
./scripts/notify-team.sh "$GOAL_IDENTIFIER" "$GOAL_TITLE" "$GOAL_DESCRIPTION"
```
```

## Blocking Behavior, Timeout, and Result Capture

`after_goal` is a **blocking** hook. The executor MUST wait for the child process to exit (normally or via timeout) before reporting any result to the server. The server keeps the goal in its current state until the result arrives — a goal does not advance, and dependents do not unblock, while the hook is in flight.

### Timeout Source

The timeout for `after_goal` comes from the server-supplied `hook.timeout` field on the hook payload (in milliseconds). The executor MUST honor this value, subject to the two bounds documented below: it is clamped to 890s (so an inner budget can never reach the 900s `hooks.json` outer ceiling), and when no server value arrives — as at PRE phase, where no response payload exists yet — the documented default applies. It must not otherwise shorten, extend, or substitute the value. The server sends **600s for every blocking hook**, including `after_goal` (D229). That figure is a hang detector rather than a performance gate: a section's commands belong to whoever wrote the `.stride.md`, and the executor must never kill one for being slow. It is sized above every measured legitimate run — cold `before_doing` 80s, cold `after_doing` 138s (200s+ with coverage), roughly 1.9x those again under load — and is clamped to 890s under the 900s `hooks.json` outer ceiling.

Pseudocode for the wrapper applied to the matched command list:

```bash
START=$(date +%s%3N)
OUTPUT=$(timeout "${HOOK_TIMEOUT_S}s" bash -c "$COMMANDS" 2>&1)
EXIT_CODE=$?           # 124 = GNU coreutils timeout signal; 143 = SIGTERM on BSD
DURATION_MS=$(( $(date +%s%3N) - START ))
```

The exact form differs per platform (`Stop-Process` on PowerShell, `gtimeout` on macOS without GNU coreutils), but the contract is identical: wall-clock duration is measured around the wait, stdout and stderr are merged, and the child's exit status propagates verbatim.

### Each Line Runs in a Fresh Shell

Every command line in a hook section executes as its own `bash -c` child (this is what makes the per-line kill-on-budget possible). Shell state does NOT persist across lines: a `cd` on one line does not change the directory of the next, and a plain variable assignment on one line is not visible to the next. Every line starts in the project directory with the exported hook environment (`TASK_*` / `GOAL_*`, the server-supplied hook env, `HOOK_NAME`). Hook authors needing compound state should join the steps on a single line (`cd subdir && make test`).

### Result Shape

The executor reports `after_goal` to the server using the same `{exit_code, output, duration_ms}` shape as every other blocking hook:

| Field | Type | Notes |
|---|---|---|
| `exit_code` | integer | The child process exit status, forwarded verbatim. Timeout uses the platform's timeout signal (`124` on coreutils, `143` on BSD). |
| `output` | string | Merged stdout + stderr from the child process. Not truncated by the executor — the server enforces any size limit. |
| `duration_ms` | integer | Wall-clock milliseconds from immediately before `exec` to immediately after the wait returns, regardless of exit status. |

### Non-Zero Exits Are Never Swallowed

If the child process exits non-zero — for any reason, including timeout — the executor MUST forward that exit code as-is. It MUST NOT remap a non-zero exit to `0`, MUST NOT suppress the `output` payload, and MUST NOT retry the command silently. The server uses the exact `exit_code` value to decide whether the goal stays In Progress (so the operator can investigate) or transitions to Done. Hiding a failure from the server defeats that gate.

This rule applies symmetrically to `after_doing` / `before_review` and is restated here only because `after_goal` is the newest blocking hook and the temptation to "be helpful" by retrying is highest for notification-shaped commands.

### Timeout Distinguishability

A timeout MUST produce a result the server can recognize as distinct from a clean success. The executor relies on the platform timeout utility's exit-code convention — `124` (or `143` on systems whose `timeout` sends `SIGTERM`) — and forwards that value verbatim alongside the captured `output`. The server's `after_goal` handler treats any non-zero `exit_code` as cause to keep the goal In Progress; the specific timeout code is preserved so a human can tell timeout from generic failure when reading the agent-result log.

## Reporting the Result Back to the Server

After the after_goal hook child process exits (cleanly, with a non-zero status, or via timeout), the executor MUST report the captured result to the Stride server. This is what allows the server to transition the goal to Done — without the report, the goal stays In Progress indefinitely.

### Endpoint

```
PATCH /api/tasks/:id/after_goal
```

`:id` is the **goal**'s id or identifier (from `GOAL_ID` / `GOAL_IDENTIFIER` — these are exactly the values the executor just exported into the child environment, so no lookup is needed).

The request requires the standard `Authorization: Bearer $STRIDE_API_TOKEN` header and a JSON body matching the captured-result shape:

```json
{
  "exit_code": 0,
  "output": "Goal G42 (Add notifications) finished\nNotified 4 stakeholders",
  "duration_ms": 1843
}
```

All three fields are required by the server. `exit_code` must be an integer, `output` a string (merged stdout + stderr), and `duration_ms` a non-negative integer.

### Server Response

| Status | Server interpretation | Executor next step |
|---|---|---|
| `2xx` with `exit_code == 0` | Goal transitions to Done; `after_goal_status` flips to `:succeeded` | Hook reported successfully. Loop to next task. |
| `2xx` with `exit_code != 0` | Goal stays In Progress; failure recorded in `after_goal_attempts` | **Surface the failure to the user.** Do NOT silently retry. |
| `422` | Server rejected the payload shape, or the goal is not currently expecting an after_goal report | Surface the error — this is a protocol bug, not a network blip. Stop retrying. |
| `5xx` or network error | Transient | Retry with bounded backoff (see below). |

A 2xx response — regardless of the `exit_code` it carried — means the server **acknowledged** the report. The executor must not POST the same result twice on success.

### Non-Zero Exit Codes Are Not Retried

If the hook's child process exited non-zero, the executor POSTs that result **once** to the agent-result endpoint and then surfaces the failure to the user (in Claude Code, by emitting the failure into the agent's stdout/stderr so the operator sees it; in other environments, the equivalent escalation surface). It MUST NOT re-execute the after_goal command, MUST NOT keep POSTing the same failing result hoping for a different server response, and MUST NOT swallow the result. The operator is expected to fix the underlying cause (broken script, missing dependency, environmental issue) and re-trigger the goal completion manually. Silent retries would hide the failure and defeat the goal-stays-In-Progress gate that exists specifically so a human can investigate.

### Network Errors Use Bounded Backoff

Connection refused, DNS failure, socket timeout, and 5xx responses are transient — the captured `{exit_code, output, duration_ms}` payload is still valid and should be re-sent. The executor retries with **bounded exponential backoff**:

| Attempt | Delay before sending |
|---|---|
| 1 | (immediate) |
| 2 | 1s |
| 3 | 2s |
| 4 | 4s |
| 5 | 8s |
| (give up) | After ~15s total |

After the cap is exhausted, the executor surfaces the network failure to the user with the original captured result attached, so the operator can re-POST manually or re-run the goal completion. The executor MUST NOT loop indefinitely — blocking the agent forever on an unreachable server defeats both responsiveness and the bounded-budget contract `after_goal` shares with the other blocking hooks.

The 422 protocol-rejection case is **not** retried — repeating an invalid payload will not become valid. Only transient (5xx / network / timeout) errors are eligible for backoff.

## Why Every Task-Lifecycle Duration Is Zero (D234, D242)

The orchestrator's Step 6 keeps the operative rules inline — every task-lifecycle hook result carries `duration_ms: 0`, `after_goal` is the one hook whose real figure is read from its durable file, and none of these numbers may be invented. This section is the derivation behind those rules, kept out of the hot path because running a task never requires re-deriving it.

The executor measures a real `duration_ms` and writes it as JSON to **stdout**, then exits 0 — and Claude Code's PreToolUse contract sends exit-0 stdout to the transcript, **not to the model**. Only exit 2 feeds output back. This repo established that independently: see "A hook that *passes* is invisible" in the Behavior When Invoked From a Subagent section below — *"Do not read silence as a pass."*

**D234 made the figure durable.** Every section that actually runs now also writes its structured result to `.stride/.hook-result-<hook>.json` — one file per hook, so `after_doing` and `before_review` cannot overwrite each other — on both the success and the failure path. (The failure shape previously carried no duration at all; D234 computes it before that branch emits.) The file is cleared at claim time along with the other per-task artifacts, so a leftover from the previous task can never be read as this one's. **An absent file means the section body was empty, the executor did no work, and `0` is truthful. Absence is never an error, never a retry, and never a licence to invent a figure.**

**What that does and does not fix. The deciding question is not visibility — it is whether the request that would carry the figure is written BEFORE or AFTER the hook runs.** For all four task-lifecycle hooks the answer is "before", and no durable file can change that:

- **`before_doing_result.duration_ms` — `0`.** This hook fires as **PostToolUse of the claim curl** (`stride-hook.sh`, `post:claim → before_doing`) — the curl whose body already contains `before_doing_result`. Same structural impossibility as `after_doing` below. Its file *does* exist later in the task, but there is nowhere to put the number: the completion payload has no `before_doing_result` field, and `workflow_steps` has six fixed step names that do not include `before_doing`.
- **`after_doing_result.duration_ms` — `0`.** This hook fires as PreToolUse *of the very curl whose body already contains `after_doing_result`*. The payload is fully constructed before the hook runs, so the figure does not exist at write time **even in principle** — and reading the file at that moment would hand you the *previous* task's figure, which is worse than `0` because it is wrong rather than merely absent.
- **`before_review_result.duration_ms` — `0`.** It fires as PostToolUse of that same curl, so its duration does not exist at request time either.
- **`after_goal` — the one that works.** The `## after_goal` section runs as PostToolUse of `/complete`, and the agent then issues a **separate, later** `PATCH /api/tasks/$GOAL_ID/after_goal`. That request is written *after* the hook has already run, so the file exists by then — and the server requires `duration_ms` as a non-negative integer and stores it on the goal.

**There is no follow-up PATCH that fixes the first three, and as of D242 that is a settled decision rather than an open gap — stated plainly so nobody re-derives the chain or re-opens it as a defect.** `after_doing_result` and `before_review_result` are not task schema fields; they are transient completion-request fields whose content is persisted into `workflow_steps` — and `workflow_steps` is on the `PATCH /api/tasks/:id` forbidden list (D227), so a post-completion correction is refused. `before_doing_result` is validated for shape on the claim and never persisted at all.

**D242 evaluated three ways to close it and declined all three.** The deciding fact is what consumes the figure: **nothing aggregates `duration_ms`.** `Kanban.Tasks.Compliance` reads dispatch counts, skip reasons and array length — never durations — and no `SUM`/`AVG` of `duration_ms` exists anywhere in `lib/`. The only consumer is the per-task Workflow Steps panel, so the entire harm was one panel's display accuracy.

- **Rejected — a new `PATCH /api/tasks/:id/hook_result` mirroring `after_goal`.** It would work, and `after_goal` proves the shape. But it buys display accuracy on a figure nothing aggregates at the price of a **second round trip on every single completion, forever** — a permanent per-task cost paid by every task on every runtime, at a time when the active work (G404, G405, G407) is all aimed at cutting per-task cost. Wrong trade.
- **Rejected — narrowly un-forbidding a duration-only `workflow_steps` merge.** D227 made that field forbidden *bluntly* and on purpose, and refuses it outright rather than silently dropping it. There is no precedent anywhere in `lib/` for a scoped partial update of a forbidden field, so this would introduce that pattern for a display fix — and a duration-only writer is exactly the kind of guard that widens by increment.
- **Chosen — accept the `0`, and stop rendering it as a measurement.** The real defect was never the missing number; it was that `"0 ms"` is indistinguishable from a genuine near-instant run. The panel now renders an **em dash** for `after_doing` and `before_review` when their duration is `0`, so a figure that is structurally unknowable reads as unknown instead of as measured. A non-zero value on those steps still renders normally, so this stays correct if a later change ever gives them a real destination.

**`before_doing` has no destination and permanently will not get one.** Its section fires as PostToolUse of the claim curl that already carries `before_doing_result`; the completion payload has no `before_doing_result` field; and `workflow_steps` has six fixed step names that do not include `before_doing`. There is nowhere to put the number even if it were free to obtain, so it is not a gap awaiting a fix. Its durable file exists and is still worth reading when diagnosing a slow claim — it is simply never submitted.

**What did NOT change:** an absent `.stride/.hook-result-<hook>.json` still means the section body was empty, the executor did no work, and `0` is truthful — absence is never an error and never a licence to invent a figure. And `workflow_steps` remains unwritable after completion by any path: no endpoint was added, so entries still cannot be added, removed, reordered or renamed.

## Submitting the after_goal Result PATCH (Step 8 companion)

The orchestrator's Step 8 keeps the gate (last child of a parent goal), the read-it-from-the-durable-file rule, and the verify-the-push rule inline; this section is the submission mechanics it points to.

```bash
AFTER_GOAL_FILE="$CLAUDE_PROJECT_DIR/.stride/.hook-result-after_goal.json"
if [ -f "$AFTER_GOAL_FILE" ]; then
  AFTER_GOAL_RESULT_JSON=$(jq -c '{exit_code: (if .status == "success" then 0 else (.exit_code // 1) end),
                                   output: (.commands_output // .stdout // "" | tostring),
                                   duration_ms: (.duration_ms // 0)}' "$AFTER_GOAL_FILE")
else
  # Empty ## after_goal section (plugin mode): no work was done and no file was
  # written. Without this branch jq exits 2, the substitution captures an empty
  # string, and the curl below sends `-d ""`.
  AFTER_GOAL_RESULT_JSON='{"exit_code": 0, "output": "", "duration_ms": 0}'
fi

curl -X PATCH "$STRIDE_API_URL/api/tasks/$GOAL_ID/after_goal" \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$AFTER_GOAL_RESULT_JSON"
```

`$GOAL_ID` is supplied in the hook's `GOAL_ID` / `GOAL_IDENTIFIER` env vars (see the Variable Inventory above). A `2xx` with `exit_code == 0` transitions the goal to Done. A `2xx` with `exit_code != 0` records the failure on the goal's `after_goal_attempts` audit log and leaves the goal In Progress for the user to investigate and re-trigger.

**How the hook detects `after_goal` reliably.** The `/complete` (and `/mark_reviewed`) response can be large — the echoed `reviewer_result` alone runs to tens of KB — and the harness truncates the `tool_response.stdout` the hook would otherwise parse. The completion/claim curls therefore capture the full response to the canonical file `$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json` (the `| tee` pattern documented in `stride-completing-tasks` / `stride-claiming-tasks`), which the hook reads in preference to the truncatable stdout (D118). When that file is absent or unreadable, the hook falls back to a fresh, hook-initiated `GET /api/tasks/:id/after_goal_status` (D119) — a subprocess the hook spawns, immune to harness truncation and needing no agent cooperation. Detection therefore does not depend on the agent's curl output being intact. The source-of-truth ordering is in the Response Payload Source section above.

**Back-compat (matters for agent runtimes that predate this feature):**

- If `.stride.md` has no `## after_goal` section, the hook script silently no-ops — no JSON is emitted, no PATCH is needed. The server's grace-window worker (configured per board, typically a few minutes) will promote the goal to Done automatically.
- If the agent doesn't PATCH the result at all (older plugin versions, scripted environments), the same grace-window worker covers the gap. The goal transitions to Done after the wait expires, with `after_goal_status: :succeeded` and a synthetic attempt tagged `source: "after_goal_grace_worker"` in the audit log.
- The `## after_goal` hook is general-purpose — Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses.

## Edge Cases

- **Missing `GOAL_DESCRIPTION`.** Goals without a description return `""` from the server. The executor exports `GOAL_DESCRIPTION=""` (empty string, defined) — it does NOT raise an error or fall back to a placeholder. User commands that test `[ -n "$GOAL_DESCRIPTION" ]` will correctly see "empty."
- **Missing `## after_goal` section.** The parser returns an empty command list (see [parser.md](parser.md)). The executor reports a clean no-op result (`exit_code: 0`, empty `output`, `duration_ms: 0`) so the server's lifecycle bookkeeping still completes.
- **Server omits an expected key.** Treated the same as an empty value — exported as `""`, never raised as an error.
- **Server omits or empties `GOAL_ID`.** The executor derives `GOAL_ID` from the completed task's `parent_id` in the same response payload (see the Forwarding Rule above). If `parent_id` is also absent, `GOAL_ID` exports as `""` — still never an error.
- **`after_goal` rides the `mark_reviewed` response.** The executor defers the usual `after_review` env-cache deletion so the agent can still read `GOAL_ID` from the cache for the follow-up `PATCH /api/tasks/:goal_id/after_goal`. The next claim rewrites the cache. The diff-snapshot artifacts are still cleaned up normally.
- **Invalid env key names.** Keys that are not valid shell identifiers (e.g. containing `;` or spaces) are dropped — never written to the cache, never exported, never executed.
- **`hook.timeout` missing from the server payload.** Treated as a protocol error — the executor should reject the hook and report `exit_code: -1` with an `output` explaining the missing field, rather than guess a default. (In practice the server always supplies it; this branch exists so the agent never silently invents a timeout budget.)

## Behavior When Invoked From a Subagent

Everything above is written for the main loop, but the executor has no notion of
who is calling it — and the isolation design in
[`../../docs/orchestrator-context-isolation-design.md`](../../docs/orchestrator-context-isolation-design.md)
rests entirely on that being true. The three facts below were established
experimentally on 2026-08-08 rather than assumed. **Each names the experiment
that established it, and what that experiment did not establish**, so a future
reader can re-run it instead of trusting it.

- **Hooks fire for a subagent's tool calls, exactly as they do in the main loop.**
  Established by two experiments together, and it takes both. **U1** planted the
  file the `after_review` path unconditionally deletes
  (`.stride-changed-files.json`) as a sentinel, then ran a command whose *text*
  matched the `mark_reviewed` URL pattern — at the time, the hook dispatched on
  command text, so this needed no network call and no claimed task. **That premise
  no longer holds, and re-running U1 as originally written now yields a false
  negative.** `D220` (`eb8939f`) landed after these experiments and hardened
  routing to require the call to *actually issue* the request — client in command
  position, endpoint as the tail of a URL in argument position, matching method —
  rather than merely mention it. A plain `echo` containing a `mark_reviewed` URL
  routes nowhere today, so the sentinel survives and a reader would conclude hooks
  do not fire in subagents. **To re-run U1 against current code, issue a real
  `curl`/`wget` request to the endpoint with a matching method — a nonexistent
  task id is enough.** Routing depends on the command and the phase, not on the
  API's response, so the hook chain runs against a `404` just as it does against
  a real task. That keeps the original method's most useful property: the probe
  makes no live write. Three runs: main loop with
  the pattern (sentinel deleted — the detector works), subagent with the pattern
  (sentinel deleted — the hook fired in the subagent), and a negative control,
  subagent *without* the pattern (sentinel survived). The negative control is
  what makes it conclusive: it rules out "something else deletes the file."
  **What U1 alone did not establish:** all three runs used `.stride.md` in plugin
  mode with **empty** hook sections, so U1 proves the hook script is *invoked*,
  not that a populated section body runs. **U3** closes that gap with a populated
  body — cite both, not U1 on its own.

- **A failing blocking hook blocks the subagent's tool call and returns the full
  error text to it.** Established by **U3**, which is the load-bearing one: with
  `.stride.md` in `stride_dev` mode (populated bodies), a deliberately failing
  test was planted so that line 1 of `after_doing` (`mix test --cover`) exited
  non-zero. Main loop and subagent produced *identical* results — the following
  `echo` never ran, and both received `after_doing hook failed on command 1/5`.
  The subagent received the complete error text verbatim, and the call took tens
  of seconds, consistent with the whole test chain running before it failed. That
  the hook aborts on its first failing line was confirmed from the other side too:
  line 5's `git add -A && git commit` was never reached — clean tree, unchanged
  `HEAD`, no new commits. **This is the fact a gate depends on.** A gate that
  fires but does not block is worse than no gate, because it reads as protection.

- **A hook that *passes* is invisible to the subagent.** From **U1**: the
  subagent reported seeing no hook output, no error and no notification, even
  though the sentinel showed the hook had run. **U3 corrects the scope of this**,
  and the correction matters: U1 originally concluded the hook was simply
  "invisible to the subagent," which was an artefact of testing a *passing* hook.
  A failing hook is fully visible. The visibility gap applies only to hooks that
  succeed — the harmless direction. **Do not read silence as a pass.** U1's own
  negative control is the counter-example: there the hook did *not* fire, and the
  subagent observed exactly what it observed when the hook fired and passed —
  nothing. That is precisely why the experiment needed a filesystem sentinel. From
  inside a subagent, *fired-and-passed* and *never-fired* are indistinguishable
  without an out-of-band signal; what the experiments establish is only that a
  passing hook is silent, never that silence implies a pass.

**Not established: what a subagent sees when a gate hook *times out*.** U3 forced
a non-zero exit from a failing command; no experiment forced a timeout. The
executor's own contract above is unambiguous that a timeout is forwarded as a
non-zero exit (`124`/`143`, never remapped), and the gate path has timeout
plumbing of its own — but "a timed-out gate surfaces to a subagent the way a
failing one does" is an inference from those two facts, not a measurement.
**Treat it as unknown until someone runs it**, and do not let the surrounding
confidence of this section borrow authority for it.

**The sentinel technique was a probe, not an interface.** The
`.stride-changed-files.json` deletion is an ordinary implementation detail of the
`after_review` path that U1 repurposed as a detector because it needed a
filesystem-observable signal with no network call. Nothing in `hooks/` or
`test-stride-hook.sh` supports or documents it as a way to test hooks, no flag
enables it, and it must not be described as the recommended way to test hook
firing. It is recorded here because U1's claim is only re-runnable if the method
is written down with it.
