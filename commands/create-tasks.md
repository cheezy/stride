---
description: Create one or more Stride work tasks or defects, optionally informed by a directory of project markdown passed with --dir (alias --context). Loads the .md files as a read-only context bundle and routes through the stride-workflow orchestrator, which dispatches stride-creating-tasks. Never invokes the creation sub-skill directly.
allowed-tools: Bash(test:*), Bash(grep:*), Bash(find:*), Read, Glob, Skill
argument-hint: "[--dir <path>] [task description]"
---

# /stride:create-tasks

Create one or more Stride work tasks (or defects), optionally informed by a directory of project markdown. This command is a thin surface: it parses `$ARGUMENTS`, optionally loads a read-only markdown **context bundle** from `--dir`, then routes through the **`stride-workflow`** orchestrator, which dispatches the `stride-creating-tasks` sub-skill. The task-field contract — required fields, the four review_queue-scored fields, and the embedded-object formats — lives in `skills/stride-creating-tasks/SKILL.md` and is enforced there.

**This command never invokes `stride-creating-tasks` directly** — the sub-skill gate would block that. It always goes through `stride-workflow`, which writes the activation marker that permits the dispatch.

## What to do

### Step 1: Parse `$ARGUMENTS`

The user invoked you with `$ARGUMENTS`. Parse in this fixed order — `--dir` (alias `--context`) first, then everything remaining is the free-text **creation intent** (the task description):

- If `--dir` or `--context` appears, set `CONTEXT_DIR` to its value and remove the consumed token(s). Accept BOTH shapes:
  - `--dir <value>` / `--context <value>` — the value is the **next** token.
  - `--dir=<value>` / `--context=<value>` — the value is the substring after `=`.
- Everything left after removing the flag is `INTENT` (the natural-language description of what to create). `INTENT` MAY be empty — the orchestrator and sub-skill will gather it interactively.

### Step 2: Validate the context directory

Only when `CONTEXT_DIR` is set:

```bash
if [ -n "$CONTEXT_DIR" ]; then
  if [ ! -d "$CONTEXT_DIR" ]; then
    echo "stride:create-tasks: --dir path does not exist or is not a directory: $CONTEXT_DIR" >&2
    exit 1
  fi
  if [ -z "$(find "$CONTEXT_DIR" -maxdepth 1 -type f -name '*.md' -print -quit)" ]; then
    echo "stride:create-tasks: no .md files found in $CONTEXT_DIR — continuing with no context bundle" >&2
  fi
fi
```

- A `--dir` that is **set but missing** (or not a directory) is a hard error: print the message and exit non-zero **before any task work begins**.
- A directory that **exists but contains no `.md` files** is NOT an error: warn and continue with an empty context bundle.
- When `CONTEXT_DIR` is unset, skip this step entirely and proceed to a normal interactive creation.

### Step 3: Load the context bundle (read-only)

If `CONTEXT_DIR` is set and contains `.md` files, enumerate and read them — **only files inside `CONTEXT_DIR`, never outside it**:

```bash
find "$CONTEXT_DIR" -maxdepth 1 -type f -name '*.md'
```

Use `Glob` to list the markdown files and `Read` to load each file's contents into `CONTEXT_BUNDLE`. The bundle is **read-only** — consume it as reference material; never edit the source markdown, and never read files outside `CONTEXT_DIR`.

### Step 4: Route through the `stride-workflow` orchestrator

Use the `Skill` tool to invoke `stride-workflow`, passing the creation intent and the loaded context bundle. The orchestrator writes the activation marker and dispatches `stride-creating-tasks` with the bundle forwarded verbatim:

```
Skill(skill: "stride-workflow",
      args: "intent=create-tasks; description=<INTENT>; context_dir=<CONTEXT_DIR>; context_bundle=<CONTEXT_BUNDLE>")
```

Do NOT invoke `stride-creating-tasks` yourself. The orchestrator is the only sanctioned path — it satisfies the sub-skill STOP gate by dispatching from inside itself, and it forwards the context bundle to the sub-skill, which mines it per its **Consuming Provided Context** section. The context **augments** the user's interactive intent; it never silently overrides the user's confirmation, and it never excuses leaving a required field (including the four review_queue-scored fields) blank.

## Terminal state

This command's terminal state is **tasks created** — not tasks built. After the orchestrator dispatches `stride-creating-tasks` and the task(s) are created, it reports the new `W###` / `D###` identifiers and **stops**. It does not claim, start, or implement the work, and it does not continue into a build loop. Newly created tasks land in the **Backlog** and become claimable only after a human promotes them to Ready. Building a created task is a separate, explicitly-invoked action — a fresh request to work the task, which re-enters the `stride-workflow` orchestrator. See the orchestrator's **Creation Terminal State** section.
