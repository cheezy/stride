# Security Model

This document describes what the **stride** Claude Code plugin does at runtime,
written for a security reviewer evaluating it for the plugin directory. Every
claim here is backed by the plugin's own code — primarily
[`hooks/stride-hook.sh`](hooks/stride-hook.sh),
[`hooks/stride-skill-gate.sh`](hooks/stride-skill-gate.sh), and
[`hooks/hooks.json`](hooks/hooks.json) (with behaviorally equivalent
PowerShell variants `*.ps1`).

## Trust boundary (read this first)

- **What runs on your machine:** only the shell commands **you** write in your
  project-local `.stride.md` file, plus a small set of read-only `git` commands
  and one `curl` upload the plugin makes itself (enumerated below). The plugin
  ships **no** hook commands of its own to execute against your code.
- **What leaves your machine:** exactly one kind of network request — a `PUT`
  of your task's per-file diff to **your configured Stride server**
  (`stridelikeaboss.com` by default). Nothing else is transmitted by the plugin.
- **Where your secret lives:** a project-local `.stride_auth.md` file that you
  create and that is **never committed** (documented in the README). The plugin
  reads it; it never bundles, prints, or logs the token.
- **What the plugin does NOT do:** no telemetry/analytics, no background
  processes, no auto-update of itself, no arbitrary code execution beyond the
  `.stride.md` sections you author, and no credential access from the skill gate.

## What the plugin installs

Skills, subagents, and slash commands (all Markdown — instructions for the
agent, not executable code), plus two hook scripts wired via `hooks.json`. The
only executable surface is those hook scripts.

## What runs at runtime

`hooks.json` registers three hooks, all matching tool **events** (not arbitrary
triggers):

| Event | Matcher | Script | Timeout |
|-------|---------|--------|---------|
| `PreToolUse` | `Bash` | `stride-hook.sh pre` | 300s |
| `PostToolUse` | `Bash` | `stride-hook.sh post` | 300s |
| `PreToolUse` | `Skill` | `stride-skill-gate.sh` | 10s |

### Lifecycle dispatch

`stride-hook.sh` inspects the **intercepted Bash command** to decide whether it
is a Stride API call and, if so, which lifecycle phase it is in. The routing is
a simple URL-pattern match:

- `post` + `…/api/tasks/claim` → `before_doing`
- `pre` + `…/api/tasks/:id/complete` → `after_doing` *(blocking)*
- `post` + `…/api/tasks/:id/complete` → `before_review`
- `post` + `…/api/tasks/:id/mark_reviewed` → `after_review`

If the command matches none of these patterns (any ordinary `git`, `ls`, build
command, etc.), the hook exits cleanly and does nothing. **The hook only acts on
Stride API calls.**

### What actually executes

For a matched phase, the hook reads the **same-named section from your
project-local `.stride.md`** (e.g. the fenced `bash` block under
`## after_doing`) and runs the commands you put there. These commands are
**user-authored**: the plugin does not inject or substitute commands of its own
into them. A missing `.stride.md` or an empty section is a silent no-op.

Beyond running your `.stride.md` commands, the only commands the plugin itself
executes are read-only bookkeeping for the per-file diff feature:

- `git rev-parse HEAD` (record the claim-time base commit)
- `git diff` / `git ls-files --others --exclude-standard` (compute the
  working-tree diff since that base, including untracked files)
- one `curl -X PUT` upload (below)
- `rm -f` of its own scratch files (`.stride-changed-files.json`,
  `.stride-diff-upload-state`, `.stride-env-cache`)

## What data leaves the machine, and where

The plugin makes **exactly one** kind of outbound request: after the
`after_doing` phase it PUTs the task's per-file diff snapshot to

```
PUT {your API URL}/api/tasks/{task_id}/changed_files
Authorization: Bearer {your token}
```

- **Destination host** is whatever you configured as the API URL in
  `.stride_auth.md` — `https://www.stridelikeaboss.com` by default. The plugin
  does not contact any other host.
- **Payload** is the working-tree diff for the current task (a JSON array of
  `{path, diff}` entries, base64-wrapped only so an edge request filter does not
  misread a code diff as an attack). It contains your code changes for the task
  — the same diff a reviewer sees in Stride. Binary files are replaced with a
  placeholder and large diffs are truncated at 500 lines.
- The upload is **fire-and-forget and non-fatal**: a failed PUT warns on stderr
  and never blocks your work. Its bookkeeping file records only the task id and
  HTTP status — **never** the URL or token.

Network calls made by **your own `.stride.md` commands** (e.g. a `gh pr create`
you wrote) are your configuration, not the plugin's, and pass through untouched.

## Token & credential handling

The bearer token and API URL are resolved at runtime, in this order:

1. **Project-local `.stride_auth.md`** — the `**API URL:**` and `**API Token:**`
   lines. The token resolver deliberately matches the production `**API Token:**`
   line and **not** a `**Local API Token:**` line.
2. **Fallback:** the `Bearer <token>` and URL literally present in the
   intercepted completion `curl` command (back-compat for when the auth file is
   absent).

There is **no hardcoded credential anywhere in the plugin**, and the resolver
does not read process environment variables. The token is passed only as a
`curl -H "Authorization: Bearer …"` header; it is **never** echoed, written to
stdout/stderr, or stored in any scratch file. `.stride_auth.md` is user-created
and the README explicitly instructs that it must never be committed.

A full credential-hygiene sweep of this repository (no tracked secrets, no
hardcoded credentials, no token literal in git history) is recorded in
[`SUBMISSION-AUDIT.md`](SUBMISSION-AUDIT.md).

## The skill gate (`stride-skill-gate.sh`)

A purely **local** PreToolUse gate on `Skill` invocations. It reads a marker
file (`.stride/.orchestrator_active`) that the workflow orchestrator writes, and
**blocks** a fixed list of six internal sub-skills from being invoked directly
outside the orchestrator (returning exit 2). Everything else is allowed. The
gate makes **no network calls and touches no credentials** — it is a workflow
guardrail, not a security control over your data. It can be bypassed for
debugging with `STRIDE_ALLOW_DIRECT=1`.

## Blocking semantics & failure modes

| Hook | Blocks the action? | On failure |
|------|--------------------|------------|
| `after_doing` | **Yes** (PreToolUse, exit 2) | Your quality gate failed — completion is blocked until you fix it |
| `stride-skill-gate` | **Yes** (PreToolUse, exit 2) | A guarded sub-skill was invoked outside the orchestrator |
| `before_doing` / `before_review` / `after_review` | No | Logged; work continues (the diff upload self-heals on a fresh budget) |

Missing tools or files degrade gracefully: no `.stride.md`, no `git`, no `jq`,
or a failed diff capture all resolve to a silent no-op or an empty snapshot —
never a crash and never a blocked action (except the two intentional gates
above).

## Cross-platform parity

The PowerShell variants (`stride-hook.ps1`, `stride-skill-gate.ps1`) implement
the **same** model with no security-relevant drift: same lifecycle dispatch,
same two-source token resolution, same single `changed_files` upload (via
`Invoke-WebRequest`), same marker-based skill gate. On native Windows the `.sh`
entrypoint delegates to the `.ps1` script so behavior is consistent everywhere.

## Reporting

Security concerns about this plugin can be raised via the issue tracker at
<https://github.com/cheezy/stride>.
