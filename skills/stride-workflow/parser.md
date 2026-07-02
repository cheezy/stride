# `.stride.md` Parser Reference

The `.stride.md` file is the agent-side hook script. Each lifecycle hook is declared as a `## <hook_name>` section whose body is a single fenced ```bash code block. The Stride hook bridge (`stride/hooks/stride-hook.sh` and `stride/hooks/stride-hook.ps1`) reads this file and executes the lines that belong to the active `$HOOK_NAME`.

## Recognized Sections

The parser recognizes these five hook sections:

| Section | Trigger | Blocking | Timeout |
|---|---|---|---|
| `## before_doing` | After `POST /api/tasks/claim` | yes | 60s |
| `## after_doing` | Before `PATCH /api/tasks/:id/complete` | yes | 120s |
| `## before_review` | After `PATCH /api/tasks/:id/complete` | yes | 60s |
| `## after_review` | After `PATCH /api/tasks/:id/mark_reviewed` | no | 60s |
| `## after_goal` | After the final task in a goal completes | yes | 60s |

Sections not in this list are ignored — they parse cleanly but never execute, because no lifecycle event sets `$HOOK_NAME` to their name.

## Parsing Rules

The parser applies these rules uniformly to every recognized section:

1. **Section heading match.** A section starts at a line of the form `## <name>` (exactly two `#`, single space, name with any trailing whitespace trimmed). The name is compared verbatim against `$HOOK_NAME`.
2. **First-wins.** If the same section appears more than once, only the first occurrence is used. Parsing stops at the next `## ` heading after the matched section.
3. **Body is a single fenced bash block.** Inside the matched section, the parser captures the first ```bash … ``` fenced block. Lines outside the fence (prose, comments, additional fences) are ignored.
4. **Missing section is a no-op.** If the requested section is absent, the parser yields an empty command list. The hook bridge exits cleanly (exit 0) — it is **not** an error.
5. **Comment and blank lines inside the fence are skipped.** Lines whose first non-whitespace character is `#`, and lines that are empty after trimming, are filtered out of the executable command list.

## Line Execution Model (Logical Lines)

The fenced body executes as **one command per logical line**:

1. **Backslash continuation joins physical lines.** A physical line ending in an **unquoted, unescaped** backslash continues onto the next physical line — the backslash-newline pair is removed and the lines join into one logical line, per normal shell semantics. Continuation may span any number of physical lines.
2. **Quoting is respected.** A backslash inside single quotes is a literal character and does **not** trigger joining (multi-line single-quoted strings remain unsupported — the one-logical-line model stays). A trailing `\\` is an escaped backslash — the command ends there, no join. Inside double quotes and outside quotes, a trailing backslash continues the line. Quote state carries across joined lines.
3. **Comment and blank skipping applies to logical lines, after joining.** A `#` at the start of a continuation's next physical line is joined into the command (where the shell treats it as a trailing comment) — it does not break the continuation. Only logical lines whose first non-whitespace character is `#`, or that are blank after trimming, are skipped. **Comments themselves never continue:** `#` lexes to end-of-line in shell, so a trailing backslash on a standalone comment line is inert and cannot swallow the next command.
4. **A trailing backslash on the section's last line never hangs or drops the command** — the accumulated logical line executes with the continuation marker stripped.
5. **Each logical line runs as a single command** in its own shell child; commands do not share `cd` or variable state (see hook-execution.md's "Each Line Runs in a Fresh Shell").

This makes the canonical multi-line examples in the workflow skill and hook-execution.md (e.g. `gh pr create \` with continued `--title`/`--body` arguments) parse and execute as one command.

These rules apply to all five sections, including `## after_goal`. The parser itself is section-name-agnostic — it matches whatever name the caller passed in `$HOOK_NAME` — so adding `after_goal` to the recognized list is documentation only; no code change is required in `stride-hook.sh`.

## Back-Compatibility

Older `.stride.md` files that predate `## after_goal` continue to work without modification. When the server fires the `after_goal` lifecycle event against a project whose `.stride.md` does not declare that section, the parser returns an empty command list and the hook bridge reports a clean no-op result.

## `## after_goal` Section

The `## after_goal` hook fires when the final remaining task inside a goal completes — i.e., the goal itself transitions to Done. It receives these additional environment variables in addition to the standard `TASK_*` / `BOARD_*` / `AGENT_NAME` set:

- `GOAL_ID`
- `GOAL_IDENTIFIER`
- `GOAL_TITLE`
- `GOAL_DESCRIPTION`

Example declaration:

```markdown
## after_goal

```bash
echo "Goal $GOAL_IDENTIFIER ($GOAL_TITLE) finished"
./scripts/notify-team.sh "$GOAL_IDENTIFIER" "$GOAL_TITLE"
```
```

If `## after_goal` is omitted, the agent reports a clean no-op result (`exit_code: 0`, empty `output`) back to the server — the goal-completion lifecycle still runs end-to-end.
