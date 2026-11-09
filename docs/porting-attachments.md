# Porting task attachments to the Stride variants

This is the cross-port contract for goal **G491**, which makes the Stride
plugins download a claimed task's attachments and hand them to their agents.
The server side, in separate goals, lets people attach screenshots, mockups,
PDFs and logs to a task or a comment. Agents need those files as context, and
six plugin ports must fetch and use them in the same way.

Without a written contract, each port would choose its own directory, file
names, manifest, caps and cleanup, and the agents' prompts would drift apart.
This document fixes all of them. It is **normative**: every download task and
use task in G491 implements against it, and the Jira import's `stride-import`
plugin follows its [Rewrite downloads](#rewrite-downloads) section. As in every
port, the contract owns the substance and each port owns the wording.

The design behind it is `docs/plans/ATTACHMENTS-DESIGN.md` in the kanban
repository (§8.1 for the server shape, §9.1 for this contract, §9.2 for the
per-port work and §12 for the settled open points). That file sits in another
repository, so it is named here rather than linked.

**Keep this file current, but not from the implementing task.** Each status
cell below names the release that carries the work, for example
**landed in 1.88.0**. The user's release step updates these cells after the
whole goal completes, together with the version bump, the changelog entry and
the tags. A download or use task leaves its row at *planned*. If its port had
to differ from this contract, for example because the shipped server shape
differs, it names the difference in its completion notes, and the release step
records it here.

## Status

All nine registry ports from [`port-canon.md`](port-canon.md) are listed, in
registry order. A port that does not take this work is recorded as not
applicable, with its reason, and is never dropped from the table.

| Port | Download task | Use task | Status |
|---|---|---|---|
| `stride` | W2522 — Download task attachments in the stride claim hook (stride-hook.sh and stride-hook.ps1 in lockstep) | W2523 — Use downloaded attachments in the stride workflow, its agents and the Step 7 cleanup | landed in 1.88.0 |
| `stride-codex` | W2528 — Download task attachments in the stride-codex PostToolUse claim arm | W2529 — Use downloaded attachments in stride-codex skills and agents, and remove them at Step 8 | landed in stride-codex 1.42.0 |
| `stride-copilot` | W2526 — Download task attachments from the observed claim response in the stride-copilot hook | W2527 — Use downloaded attachments in stride-copilot's reading, explorer and self-review steps, and add Step 7 cleanup | landed in stride-copilot 2.45.0 |
| `stride-copilot-lite` | — | — | not applicable: it issues no Stride API request, so it never sees an attachment list |
| `stride-gemini` | W2524 — Download task attachments in the stride-gemini claim hook (stride-hook.sh and stride-hook.ps1) | W2525 — Use downloaded attachments in stride-gemini skills and agents, and remove them at Step 7 | landed in stride-gemini 1.54.0 |
| `stride-lite` | — | — | not applicable: it issues no Stride API request, so it never sees an attachment list |
| `stride-opencode` | W2530 — Download and remove task attachments in the stride-opencode plugin (new src/attachments.ts) | W2531 — Use downloaded attachments in stride-opencode skills and agents | landed in stride-opencode 1.43.0 |
| `stride-pi` | W2532 — Download task attachments in the stride-pi hook-bridge extension (new attachments.ts) | W2533 — Use downloaded attachments in stride-pi skills and both agent copies, and add Step 7 cleanup | landed in stride-pi 1.23.0 |
| `stride-opencode-lite` | — | — | not applicable: it issues no Stride API request, so it never sees an attachment list |

`stride` goes first, as the source of record. Each other port's download task
depends on W2522, and each use task depends on W2523 and on that port's own
download task. `stride-import` is not a registry port, so it has no row here.

**Differences recorded at release (2026-11-09).** Every port shipped the
download and the hand-off, but no port has had a live end-to-end run with a
PNG, a PDF and a text attachment. Every test suite is hermetic. Where a port
differs from this contract or could not verify it:

- `stride-codex` 1.42.0: whether `view_image` shows the attachments was not
  checked, and no Codex CLI version is recorded. Its PreToolUse guard does not
  refuse `curl -o` on attachment paths. That gap predates this goal.
- `stride-copilot` 2.45.0: the `read` tool's PNG and PDF behaviour was not
  checked, and no Copilot CLI version is recorded. The README describes the
  fallback to filename, type and size.
- `stride-gemini` 1.54.0: in a git repository, Gemini CLI's default
  `respectGitIgnore` is expected to make `read_file` refuse the attachments,
  because `.stride/attachments/.gitignore` holds `*`. That expectation comes
  from reading the source, not from a run. Turning the filter off is left to
  the operator, because it also exposes `.stride_auth.md`. Its BeforeTool
  re-fetch exemption is narrower than stride's.
- `stride-pi` 1.23.0: there is no mechanical curl guard. The rule against
  `curl -o` exists only as prompt text, a gap that predates this goal.

## The server shape this goal designs against

This is a **design assumption**, taken from the server goal. Every download
task must **re-check the shipped shape before writing any code**. The shipped
shape wins: follow it, and name the difference in the completion notes.

`GET /api/tasks/:id` (the full view) and the `POST /api/tasks/claim` response
carry `data.attachments`, an array. Each entry has exactly these eight keys:

| Key | Type | Notes |
|---|---|---|
| `id` | integer | The attachment id |
| `filename` | string | User-supplied. Data only; never used to build a path |
| `content_type` | string | |
| `byte_size` | integer | Bytes |
| `sha256` | string | 64 lowercase hex characters |
| `comment_id` | integer or null | `null` for a task-level attachment |
| `uploaded_at` | string | ISO 8601, UTC |
| `download_url` | string | An API path, `/api/tasks/<numeric task id>/attachments/<attachment id>`, that streams the file to a GET carrying the Bearer token |

- The list is ordered oldest `uploaded_at` first, with ties broken by `id`.
- It is empty for a task with no files. It is also empty on a board that the
  plan does not unlock.
- `response_view=slim`, `GET /api/tasks`, the tree, next, complete, create and
  update responses carry no `attachments` key. A port therefore reads the list
  from the claim, never from discovery.
- The download endpoint answers `200` with the bytes; `403` (`plan_required`
  or `not_authorized`); `404`; `429` with `retry-after`; or `503`. Each
  non-200 becomes the manifest reason `http_<code>`.

As checked on 2026-11-08, the kanban server already renders exactly these eight
keys (`lib/kanban_web/controllers/api/task_attachment_json.ex`), and the
download route exists. That is a point-in-time observation of the source tree,
not of the deployed server, and it does not replace the re-check.

## Directory layout

Downloads go under the project root, next to the task file:

```text
<project root>/.stride/
  .task-<STEM>.json
  attachments/
    .gitignore            contains exactly: *
    <STEM>/
      manifest.json
      <id>-<sanitised basename>
      ...
```

- **`STEM` uses the task-file rule**, which is `task_file_stem` in
  `hooks/stride-hook.sh`. The stem is the task's `identifier` when it is a
  string matching `\A[A-Za-z0-9_-]{1,64}\z`. Otherwise it is the numeric task
  `id`, when that is a non-negative integer or a string of 1 to 20 digits.
  Otherwise there is no stem, and **nothing is written**. Use `\A…\z`, not
  `^…$`, because `$` also matches before a trailing newline.
- **The `.gitignore` sits inside `.stride/attachments/`** and contains `*`. It
  is written before the first file, so a downloaded file can never be
  committed, even in a project whose own `.gitignore` does not list `.stride/`.
- A claim with **no attachments creates no directory**.
- The hook **refuses to write through a symlink**. If `.stride`,
  `.stride/attachments` or the task's directory is a symlink, it writes nothing
  and records nothing.
- On a **re-claim**, the hook replaces the task's directory: it removes
  `<STEM>/` and writes it again from the new claim.

## File naming

Each file is saved as **`<id>-<sanitised basename>`**. No raw filename ever
reaches a path.

1. **Basename.** Take the part of `filename` after its last `/` or `\`.
2. **Charset.** Replace every character outside `A-Za-z0-9._-` with `_`. That
   is one `_` per Unicode code point, not per byte or per UTF-16 unit, so a
   port's bash and PowerShell halves agree. Each port's tests include a
   filename with a character outside the Basic Multilingual Plane (an emoji).
3. **Leading dots.** Strip them, so no name is hidden and none is `.` or `..`.
4. **Length.** Cap the result at 100 characters and keep the extension. The
   extension is the part from the last `.`, as long as that dot is not the
   first character and the extension is at most 16 characters. Shorten the
   part before it. A name with no extension is simply cut to 100 characters.
   After step 2 every character is ASCII, so 100 characters is 100 bytes.
5. **Empty name.** If nothing is left, use `attachment`.
6. **The id.** The `id`, rendered as a decimal string, must match
   `\A[A-Za-z0-9-]{1,64}\z`. An entry whose id does not match is skipped with
   reason `unsafe_id`, and no file is written for it.

| `filename` | Saved as (id 812) |
|---|---|
| `screenshot.png` | `812-screenshot.png` |
| `../../etc/passwd` | `812-passwd` |
| `C:\temp\.env` | `812-env` |
| `..` | `812-attachment` |
| `résumé final.pdf` | `812-r_sum__final.pdf` |

The `<id>-` prefix keeps names unique within a task. It also means no saved
file can be named `manifest.json` or `.gitignore`.

## manifest.json, version 1

The hook writes `manifest.json` into the task's directory **last**, after every
download has finished or been skipped. It is staged under a temporary name and
then renamed into place. Its presence therefore means the downloads are done.

Top-level keys, in this order:

| Key | Value |
|---|---|
| `manifest_version` | `1` |
| `task` | `{ "id": <integer>, "identifier": <string or null> }`, taken from the claim response that proved the task's identity |
| `caps` | `{ "file_bytes": 26214400, "files": 20, "total_bytes": 104857600, "budget_seconds": <the port's budget> }` |
| `attachments` | An array with one entry per server entry, in server order, including skipped and failed ones |

Each `attachments` entry, in this order:

| Key | Value |
|---|---|
| `id` | As the server sent it |
| `filename` | The original filename, kept as data. It is never a path |
| `local_file` | The saved name, relative to the manifest's directory, or `null` when nothing was saved |
| `content_type` | As the server sent it |
| `byte_size` | As the server sent it |
| `sha256` | As the server sent it |
| `comment_id` | As the server sent it |
| `uploaded_at` | As the server sent it |
| `download_path` | The server's `download_url`, only when it passes the relative-path check in [Download rules](#download-rules). Otherwise `null`, so every entry keeps the same keys |
| `status` | `downloaded`, `skipped` or `failed` |
| `reason` | `null` when `downloaded`; otherwise one of the codes below |

| `reason` | `status` | Meaning |
|---|---|---|
| `unsafe_id` | skipped | The id failed the id rule in [File naming](#file-naming) |
| `unsafe_url` | skipped | `download_url` failed the relative-path check |
| `too_large` | skipped | `byte_size` is over 26,214,400 bytes, or is not a non-negative integer |
| `count_cap` | skipped | 20 entries have already been accepted |
| `total_cap` | skipped | Adding its `byte_size` to the accepted entries' total would take the task past 104,857,600 bytes |
| `time_budget` | skipped or failed | The wall-clock budget ran out: before the download started (skipped) or during it (failed) |
| `http_<code>` | failed | The download answered a non-200 status, for example `http_404`, `http_429` or `http_302` |
| `transport` | failed | The request failed without an HTTP status, for example DNS, TLS, a reset or a timeout |
| `size_mismatch` | failed | The body was longer or shorter than `byte_size`; a longer body is cut off and removed |
| `sha256_mismatch` | failed | The body's SHA-256 did not match `sha256` |

The checks run per entry, in server order, before any download starts, in the
order of the table: `unsafe_id`, `unsafe_url`, `too_large`, `count_cap`,
`total_cap`. The first check that fails sets the reason. An entry that passes
all five is **accepted** and queued for download. Only `count_cap` and
`total_cap` depend on earlier entries, and they count **accepted entries
only**: an entry skipped for any reason, `total_cap` included, adds nothing to
either count. For declared sizes of 60 MiB, 60 MiB and 30 MiB, the first is
accepted, the second is skipped as `total_cap` (120 MiB would pass the cap),
and the third is accepted (90 MiB in total). The outcome therefore depends
only on the server's list, never on timing.

**What the manifest never holds:** the token or any request header; an
absolute URL (the API base URL is never joined into it); and any timestamp of
its own. `uploaded_at` is server data. Leaving out local timestamps, run
durations and host names is what lets a port's bash and PowerShell halves
write **byte-identical** files from the same claim.

To make them byte-identical, the manifest is UTF-8 without a byte-order mark,
in compact JSON with the key order above and one trailing LF. JSON serialisers
escape non-ASCII and HTML-sensitive characters differently. Each port that has
two halves therefore pins its escaping with a shared fixture whose filename
carries such characters, and both halves must reproduce it exactly.

## Caps and budgets

The caps are stated in **bytes**, so they match the server's limits exactly and
a plugin never skips a file the server accepted:

- **26,214,400 bytes (25 MiB) per file**
- **20 files per task**
- **104,857,600 bytes (100 MiB) per task**

They are checked against the declared `byte_size` before any download starts.
During a download, the body is also counted, and a body that grows past its
`byte_size` is aborted.

**Every port also has a wall-clock budget**, measured from the first request to
the manifest write. Each request's own time limit is set to whatever budget
remains. The budget must leave room inside the host's hook timeout for
everything else the same invocation runs:

| Port | Budget | Host limit it must fit inside |
|---|---|---|
| `stride` | 120 s | PostToolUse timeout 900 s (`hooks/hooks.json`), which also runs the `before_doing` section |
| `stride-codex` | 30 s | PostToolUse timeout 60 s |
| `stride-copilot` | 120 s | Hook timeout 300 s, shared with the `before_doing` section's own 60 s budget |
| `stride-gemini` | 120 s | AfterTool timeout 300 s |
| `stride-opencode` | 120 s | No host hook timeout: the plugin's own code enforces the budget |
| `stride-pi` | 120 s | No host hook timeout: the hook-bridge extension enforces the budget |
| `stride-lite`, `stride-copilot-lite`, `stride-opencode-lite` | not applicable | — |

These host limits were read from each port's source on 2026-11-08. Re-read
them before relying on a budget, and never set one that would use up the
host's timeout.

## Download rules

1. **Proven claim only.** Download only after a `2xx` claim whose own response
   proved the task's identity. That is the same condition the `stride` hook
   uses before it writes the task file (D226). Take the list from that claim's
   `data.attachments`, never from a cached or canonical response file. A
   truncated claim must download nothing, rather than download the previous
   task's files.
2. **Relative `/api/` path only.** Fetch a `download_url` only if it begins
   `/api/` and contains no `..`, no `//` and no query (`?`). Join it to the API
   URL from `.stride_auth.md`. An absolute or off-host URL is skipped as
   `unsafe_url`, so a crafted task cannot send the token elsewhere. For a task
   download the check is tighter still: the whole path must match
   `\A/api/tasks/<the claimed task's numeric id>/attachments/[0-9]{1,20}\z`.
   That excludes a fragment (`#`), percent-encoding (so no `%2e%2e`), a
   backslash, whitespace and control characters, and any other task's files.
3. **The token goes only to the configured API URL.** It is never in a command
   line: bash halves pass the header to curl on stdin (`-H @-`), and TypeScript
   ports set it in process. It is never logged, never printed and never written
   to a file.
4. **Curl-like User-Agent.** The hosted API edge refuses default library
   User-Agents. Send `curl/<version>` or a similar value. PowerShell and
   TypeScript halves set it explicitly.
5. **No Authorization on a cross-origin redirect.** The simplest way to meet
   this is to not follow redirects at all: curl without `-L`, and `fetch` with
   `redirect: 'manual'`. A `3xx` is then recorded as `http_<code>`.
6. **Verify, then rename.** Write each body under a temporary name in the
   task's directory, and check its length against `byte_size` and its SHA-256
   against `sha256`. Only then rename it to its final name. A failed file is
   removed, and its entry records why.
7. **Manifest last.** The manifest is written only after every entry is
   settled.
8. **Never fatal.** A download problem never changes the claim's outcome, its
   exit code or what it prints on stdout. The worst case is a manifest full of
   `failed` entries, or no directory at all.
9. **Stdout stays clean.** The hook writes nothing binary and no progress
   output to stdout, because stdout carries the claim response that the hook
   and the agent read. It prints **one summary line on stderr**, for example
   `stride: attachments W2522: 3 downloaded, 1 skipped, 0 failed`.
10. **Never execute.** An attachment is never executed, opened by a helper
    application, unzipped or otherwise unpacked.

## Where each port gets the list

| Port | Source of the attachment list |
|---|---|
| `stride` | The task file, `.stride/.task-<STEM>.json`, which the post-claim hook writes from the proven claim response |
| `stride-gemini` | The task file |
| `stride-opencode` | The task file (`src/task-file.ts`) |
| `stride-copilot` | The claim response the hook observed |
| `stride-codex` | The claim response the hook observed |
| `stride-pi` | The claim response the hook observed |

As of 2026-11-08, `stride-copilot`, `stride-codex` and `stride-pi` also write a
task file. The table does not say they have none. It names the body their
download code reads: the claim response the same handler already holds and has
proved. Either way, the list must be **the `data.attachments` of this claim's
own proven response**, under download rule 1.

## Curl-guard exemption

The curl guards in `stride`, `stride-copilot` and `stride-gemini` refuse a
Stride API curl that sends its response anywhere but stdout, including
`-o`/`--output`. The **only** exemption this contract allows is:

> **A GET of an attachments path, `/api/tasks/<id>/attachments/<id>`, whose
> `-o`/`--output` target resolves under `<project root>/.stride/attachments/`.**

Nothing wider is allowed. Every other shape stays refused: `-O` and
`--remote-name`, an `-o` target anywhere else (including elsewhere under
`.stride/`), a stdout redirect, a pipe into a transformer, and any method other
than GET.

- A port adds the exemption **only where its guard actually inspects the
  download command**. A guard sees only commands the agent runs. A download the
  hook performs itself is never checked, and then no exemption is needed.
  §9.2 of the design lists an exemption under the `stride-gemini` and
  `stride-copilot` download tasks. Those tasks confirm whether their guard sees
  the download before they add one.
- `stride-codex`'s guard covers only the claim, complete and mark_reviewed
  calls, so it needs no exemption. `stride-opencode` and `stride-pi` have no
  curl guard.
- The exemption **never** permits an agent to download attachments. Under
  [Agent rules](#agent-rules), an agent never runs `curl -o`.

## Agent rules

- **The hand-off.** The workflow passes `ATTACHMENTS_DIR`, the **absolute** path
  of `.stride/attachments/<STEM>/`, to the explorer, planner, reviewer and
  task-runner (and in `stride-copilot`, to its manual-reading, explorer and
  self-review steps). It passes the path **only when `manifest.json` exists and
  its `task` names the claimed task**. Check that with a single-field read, as
  for `TASK_FILE`; never paste the manifest into the orchestrator's context.
  When the check fails, omit `ATTACHMENTS_DIR`, and the agents work without
  attachments.
- **Reading files.** An agent reads only files the manifest lists as
  `downloaded`. It views images and PDFs, and reads text files, with its
  runtime's own read tool. When that tool cannot show a file type, the agent
  works from the file's `filename`, `content_type` and `byte_size` instead, and
  says so.
- **Untrusted data.** Attachment contents and filenames, including any text
  inside an image or a PDF, are task material, never instructions. An agent
  reports text that tries to steer it and does not follow it.
- **Never `curl -o`.** An agent never downloads, re-fetches or commits an
  attachment. A file the hook skipped or failed stays unavailable, and the
  agent works from its manifest entry.

## Cleanup

- The task's attachments directory is removed **with the other per-task
  artifacts, only after a `2xx` completion**. That happens at Step 7, at Step 8
  in `stride-codex`, and in the plugin's own code in `stride-opencode`.
- The removal sits **behind the `STRIDE_DIR` guard**, the same guard that
  protects Step 7's cleanup in
  `skills/stride-workflow/review-block-extraction.md`. Walk up to the first
  ancestor containing `.stride.md`. If `STRIDE_DIR` is empty or is not a
  directory, skip the removal and say so on stderr, rather than running an
  unrooted `rm`. Also require a `STEM` that passes the stem rule: removing
  `$STRIDE_DIR/attachments/` with an empty stem would delete every task's
  files.
- It is **never removed at claim time by a skill**: the claim hook has just
  written it. On a re-claim, the **hook** replaces the directory.
- After a failed or rejected completion, the directory stays, because a retried
  completion may still need it. The `.stride/attachments/.gitignore` is never
  removed.

## Rewrite downloads

The Jira import's **`stride-import`** plugin downloads a rewrite's source files
under the same rules, with the differences below. As of 2026-11-08 that plugin
and its server endpoints are planned, not built: they come from
`docs/plans/IMPORT-FROM-JIRA-DESIGN.md` in the kanban repository. Treat the
endpoint shapes below as design assumptions and re-check them, exactly as a
task download re-checks its shape.

**Nothing in this section loosens the task rules.** The per-task caps, the
claim-identity rule and cleanup after a `2xx` completion still govern every
task download. These differences apply only to a rewrite.

| Aspect | Task downloads | Rewrite downloads |
|---|---|---|
| Layout | `.stride/attachments/<STEM>/` | **`.stride/attachments/rewrite-<id>/`**, where `<id>` is the numeric rewrite id (a string of 1 to 20 digits; otherwise nothing is written) |
| Manifest identity | `task {id, identifier}` | **`rewrite {id, bundle_sha256}`** in place of `task`, and each entry adds the **`jira_key`** it came from |
| Identity proof | The claim's own response | Files are downloaded only after the bundle body's SHA-256 matched the hash its response returned, and only from that bundle's file list |
| Path rule | `/api/tasks/<claimed id>/attachments/<id>` exactly | Only a `download_url` beginning **`/api/import_rewrites/<id>/files/`**, for that same rewrite id, followed by a numeric file id and nothing else, with the same bans as a task path |
| Hand-off | Explorer, planner, reviewer, task-runner | `ATTACHMENTS_DIR` goes to the drafter and the coverage-reviewer, only when the manifest names that rewrite and that bundle hash |
| Caps | 26,214,400 bytes per file; 20 files and 104,857,600 bytes per task | 26,214,400 bytes (25 MiB) per file, 20 files per Jira issue, and **524,288,000 bytes (500 MiB) per rewrite within 600 s** |
| Skipped files | Recorded in the manifest | Recorded in the manifest, so the coverage map still accounts for each one |
| `429` responses | Recorded as `http_429`, with no retry | Retried after the response's `Retry-After`, only while the wait fits inside the 600 s budget; otherwise recorded as `http_429`. This row follows the Jira design's rewrite procedure |
| Curl guard | The exemption above, where needed | None needed while `stride-import` downloads through its own script (`lib/download-files.sh`), because the guard only sees curl commands the agent runs |
| Cleanup | After a `2xx` completion | Once the draft is submitted, behind the same `STRIDE_DIR` guard |

If a port ever lets the agent run the rewrite download curl, the exemption
covers a **GET of a rewrite file path** (`/api/import_rewrites/<id>/files/<file
id>`) under the same `-o` target rule, and nothing wider.

## Canon admission decision

**No entry is added to [`port-canon.md`](port-canon.md) for attachments, and
that file is unchanged.**

The reason is the canon's own admission rule. The first bullet of its
*Changing this file* section says: **"Add a rule only when a shipped defect
forced it."** It also requires `defects` to be non-empty on every entry.
Attachments are a new feature, and no shipped defect forced this contract. An
entry now would be the speculation that bullet forbids.

The one entry admitted without a shipped defect, `stop-hook-capability`, does
not change this. The canon records it "as a departure, not as a precedent", so
citing it to admit another entry is the use that bullet rules out. The goal's
brief asked for an entry listing all nine ports. Where that request and the
canon's rule conflict, the canon's rule wins, and this section records why.

What the canon would have given is kept here another way. The
[Status](#status) table lists all nine registry ports in registry order. Each
port that does not take the work is recorded with its reason, in the spirit of
the canon's "keep `applies_to` complete" rule. One consequence is that
`scripts/check-port-canon.sh` does not check this feature, so cross-port parity
rests on each port's own contract tests.

If a shipped defect later forces an entry, the entry must follow the canon's
rules: list all nine ports in registry order, never narrow `applies_to`, use
no `json`-tagged fence for illustration, and bump the entry and the port
anchors together.

## General porting rules for this goal

1. **Re-check the shipped server shape first**, and follow it where it differs
   from [the assumption above](#the-server-shape-this-goal-designs-against).
2. **Port from `stride`'s landed code**, read alongside this document.
   `stride` is the source of record.
3. **Verify that every mechanism a ported sentence names exists in that port**:
   the guard, the task file, the step number, the read tool. The tables above
   show where the ports differ.
4. **Keep a port's two hook halves in lockstep**, and prove it with a fixture
   that both halves turn into a byte-identical manifest.
5. **No version bump, no versioned CHANGELOG heading and no status-cell edit**
   in a download or use task. The release is one separate step, run after the
   whole goal completes.
6. **Never write a literal canon-anchor comment** into this document, a
   changelog or a README. The drift check scans those files, as rule 3 of
   [the G446–G448 porting rules](porting-g446-g448.md#general-porting-rules-for-this-batch)
   explains.
7. **Record what a port cannot carry**, such as a read tool that cannot show
   PDFs, in that port's changelog at release, so "not applicable" is
   distinguishable from "missed".
