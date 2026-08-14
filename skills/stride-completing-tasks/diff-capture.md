# Per-File Diff Capture (Optional)

Back-compat only — Stride servers ≤ v1.15.x that still expect `changed_files` in the completion body. On v1.16.0+ the `after_doing` hook PUTs the snapshot to the server automatically and none of this is needed. The wire-format encoding rules stay in `docs/diff-contract.md`; the completion contract stays in SKILL.md.


The completion payload accepts an optional top-level `changed_files` array — one
entry per file the agent touched, with the unified-patch text alongside the
path. The Stride server is the consumer; the review-queue UI renders these
diffs inline so reviewers approve or reject without leaving Stride.

The full encoding rules — field shape, the 500-line truncation marker, the
binary-file placeholder, and the backward-compatibility guarantees — live in
the contract doc and are the single source of truth:

> **Contract:** [`docs/diff-contract.md`](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/diff-contract.md)
> (defines `path` / `diff` keys, exact truncation marker string, exact binary
> placeholder string, the 500-line inclusive cap, and the optional-field rules)

**How the stride plugin produces this data.** After a successful `after_doing`
hook the plugin captures the agent's working-tree state versus the
`$TASK_BASE_REF` anchor — committed changes, staged-but-uncommitted changes,
modified-but-unstaged changes, AND untracked-new files (not in `.gitignore`)
all surface in a single snapshot. Untracked new files appear as synthesized
new-file unified patches (diffed against `/dev/null`); untracked binaries use
the binary placeholder. The plugin applies the contract's truncation and
binary conventions and writes the JSON array to
`$CLAUDE_PROJECT_DIR/.stride-changed-files.json`. The snapshot is per-project,
refreshed at the end of every `after_doing`, and cleaned up on `after_review`.

**Working-tree semantic (v1.15.0+).** The snapshot reflects the agent's
working state at completion time, regardless of commit state. An agent that
edits a file and calls `/complete` WITHOUT committing first still produces a
populated snapshot — the diff is captured from the working tree against
`$TASK_BASE_REF`, not from `..HEAD`. Earlier plugin versions (≤ 1.14.x)
required a commit before completion or the snapshot was empty.

**Claim-time dirty-baseline exclusion (W1457).** At claim time the
`before_doing` branch records every path that is already modified or
untracked, with its blob hash, to `.stride-dirty-baseline`. At capture time
a path is excluded from the snapshot only when it appears in that baseline
AND its blob hash is unchanged — i.e. it is a pre-existing edit unrelated to
the task. A baselined file that is modified again during the task IS
included (hash differs), as are ambiguous cases (deleted after claim,
unhashable — when in doubt, include). A missing baseline (older claim)
disables the exclusion. Independently of the baseline, `.stride.md`,
`.stride_auth.md` (credentials — never uploaded under any circumstances),
and the hook's own bookkeeping artifacts are hard-excluded by name.

**Upload flow (v1.16.0+).** The plugin's `after_doing` hook now uploads the
snapshot to the Stride server itself: immediately after writing
`.stride-changed-files.json`, the hook issues a fire-and-forget
`PUT {URL}/api/tasks/{TASK_ID}/changed_files`. The request body is NOT the
raw snapshot: the file bytes are wrapped in a base64 transport envelope —
`{"changed_files": {"encoding": "base64", "data": "<base64>"}}` — so an edge
request filter cannot misread a unified code diff as an attack and drop the
upload (the envelope and its rules are owned by
[`docs/diff-contract.md`](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/diff-contract.md);
do not duplicate them here). URL and Bearer token are resolved from
`$PROJECT_DIR/.stride_auth.md` FIRST (its `**API URL:**` and `**API Token:**`
lines — placeholder example: `stride_dev_<token>`), falling back to values
extracted from the agent's intercepted completion curl when the auth file is
absent or incomplete — so the upload works whether the curl used literal
values or `$STRIDE_API_URL`/`$STRIDE_API_TOKEN` shell variables. The PUT
runs BEFORE the agent's completion request executes (inside the PreToolUse
path) so the server has the diff data attached to the task by the time
`/complete` lands. The agent's completion body does NOT need to include
`changed_files`.

## Limitations

- **Nested git repositories are invisible to the capture.** The snapshot
  diffs only the outer project repository. Work done inside a nested repo
  with its own `.git` directory (e.g. a plugin subrepo that the outer
  project gitignores) never appears in `changed_files` — the outer `git
  diff`/`ls-files` nets cannot see inside it. The working convention: put
  the subrepo commit hash(es) in `completion_notes` so reviewers can find
  the real diff in the subrepo's history.
- **Pre-existing dirty files are excluded by design** via the claim-time
  dirty baseline above — if a reviewer reports a "missing" diff for a file,
  check whether it was already dirty before the claim and unchanged since.

## Backwards compatibility

| Server version | How `changed_files` reaches the server |
|---|---|
| v1.16.0+ | `after_doing` hook PUTs the snapshot. Agent body does NOT need `changed_files`. |
| ≤ v1.15.x | Hook only writes the snapshot to disk. Agent must inline-read it in the completion body via the legacy pattern below. |

Both modes coexist: on a v1.16.0+ server, sending `changed_files` in the body
still works (the server treats the PUT-uploaded value as authoritative). On
older servers, the hook PUT 404s harmlessly (fire-and-forget) and the inline
body remains the only path. If you are unsure of the deployed server version
or you want a single curl that works against both, use the legacy inline
pattern below — it remains valid against every supported server. That
includes the `?response_view=slim` param below — servers predating the slim
view ignore it and return the full body.

**Legacy inline pattern (≤ v1.15.x deployments).** Inline the snapshot read
inside the curl invocation using `jq -n --argjson cf`, with the absolute
`$CLAUDE_PROJECT_DIR` path so the read works regardless of the Bash call's
CWD. The inline-cat must live inside the SAME curl invocation: the
PreToolUse-on-complete hook writes `.stride-changed-files.json` during the
curl call, so any earlier Bash tool call that reads the file runs BEFORE the
hook has populated it.

```bash
curl -X PATCH "$STRIDE_API_URL/api/tasks/$TASK_ID/complete?response_view=slim" \
  -H "Authorization: Bearer $STRIDE_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n \
    --argjson cf "$(cat "${CLAUDE_PROJECT_DIR:-.}/.stride-changed-files.json" 2>/dev/null || echo '[]')" \
    --arg summary 'completion summary text' \
    --arg notes 'completion notes text' \
    '{
       completion_summary: $summary,
       completion_notes: $notes,
       changed_files: $cf,
       actual_complexity: "small"
     }')"
```

If `.stride-changed-files.json` is absent — older plugin install, non-git
project, capture failed, jq missing on the agent's machine — the inlined
`|| echo '[]'` fallback produces an empty array. Empty `changed_files` is a
valid shape; the server accepts it. Do NOT synthesize diffs by hand to "fill
in" the field; emit only what the plugin captured (or `[]`). Both shapes
below are valid completions:

```json
"changed_files": [
  {"path": "lib/foo.ex", "diff": "--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1,3 +1,4 @@\n defmodule Foo do\n+  @moduledoc \"Foo\"\n end\n"},
  {"path": "assets/logo.png", "diff": "[binary file — no diff captured]"}
]
```

```json
"changed_files": []
```

`changed_files` in the completion body is strictly optional — completion
payloads that omit it remain fully valid forever, regardless of server
version.
