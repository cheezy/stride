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

1. Reads `hook.env` from the server's response payload (the same response that delivers the hook to the agent).
2. Exports each key/value pair into the child process environment using the same export mechanism as the existing `TASK_*` pattern — `set -a; . cache; set +a` in the shell executor, the equivalent `$env:<NAME> = …` in PowerShell.
3. Does NOT look up the goal record, query the API, or derive any `GOAL_*` value from local state. If the server omits a key (for example `GOAL_DESCRIPTION` on a goal whose description was never set), the executor exports it as the empty string. The child command sees the variable as defined-but-empty, which matches POSIX expectations and prevents `set -u` aborts inside user commands.
4. Treats `after_goal` as a blocking hook — see [Blocking Behavior, Timeout, and Result Capture](#blocking-behavior-timeout-and-result-capture) below for the wait, timeout, and `{exit_code, output, duration_ms}` reporting contract.

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

The timeout for `after_goal` comes from the server-supplied `hook.timeout` field on the hook payload (in milliseconds). The executor MUST honor this value — it must not clamp it down, extend it, or substitute a hard-coded default. The server constrains `hook.timeout` for all blocking hooks to the **60-120s window** (`before_doing` and `before_review` use 60s; `after_doing` uses 120s); `after_goal` is delivered with a value in the same range (typically 60s for notification-style hooks, 120s if the server provisioned a heavier budget).

Pseudocode for the wrapper applied to the matched command list:

```bash
START=$(date +%s%3N)
OUTPUT=$(timeout "${HOOK_TIMEOUT_S}s" bash -c "$COMMANDS" 2>&1)
EXIT_CODE=$?           # 124 = GNU coreutils timeout signal; 143 = SIGTERM on BSD
DURATION_MS=$(( $(date +%s%3N) - START ))
```

The exact form differs per platform (`Stop-Process` on PowerShell, `gtimeout` on macOS without GNU coreutils), but the contract is identical: wall-clock duration is measured around the wait, stdout and stderr are merged, and the child's exit status propagates verbatim.

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
- **`hook.timeout` missing from the server payload.** Treated as a protocol error — the executor should reject the hook and report `exit_code: -1` with an `output` explaining the missing field, rather than guess a default. (In practice the server always supplies it; this branch exists so the agent never silently invents a timeout budget.)
