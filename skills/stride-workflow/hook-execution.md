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

The timeout for `after_goal` comes from the server-supplied `hook.timeout` field on the hook payload (in milliseconds). The executor MUST honor this value — it must not clamp it down, extend it, or substitute a hard-coded default. The server sends **600s for every blocking hook**, including `after_goal` (D229). That figure is a hang detector rather than a performance gate: a section's commands belong to whoever wrote the `.stride.md`, and the executor must never kill one for being slow. It is sized above every measured legitimate run — cold `before_doing` 80s, cold `after_doing` 138s (200s+ with coverage), roughly 1.9x those again under load — and is clamped to 890s under the 900s `hooks.json` outer ceiling.

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
