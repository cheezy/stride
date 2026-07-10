# Porting the changed_files upload fix to the other Stride plugin runtimes

**Audience:** whoever maintains the non-Claude-Code Stride plugin ports (Gemini,
Codex, Copilot, OpenCode, Pi, and any future runtime).
**Status of the reference implementation:** DONE in the Claude Code plugin
(`stride/hooks/stride-hook.sh` + `stride/hooks/stride-hook.ps1`).
**Source tasks:** D126 (root cause), **D127** (the fix), **W1658** (fail loud).
Full root-cause detail is in [`root-cause-changed-files-empty.md`](./root-cause-changed-files-empty.md).

This document describes **two hook changes** that every Stride plugin runtime
should replicate. It is written logic-first so it ports to any language; the
Claude Code bash/PowerShell code is included as the concrete reference.

> **Not in scope for the plugins:** the server-side detect-and-flag safety net
> (task **D128**) lives in the kanban application, which is the single server all
> plugins talk to. It is deployed once and is shared by every runtime — there is
> **nothing to port per-plugin** for D128.

---

## 1. The problem (why this change exists)

Completed review tasks were arriving in the Review column with an **empty
`changed_files`** array, so the code-review view rendered every line as
`UNKNOWN`. Observed across a whole batch, 100% of the time.

**Root cause:** the hook uploads the per-file diff (`changed_files`) by `PUT`ing
to `/api/tasks/<TASK_ID>/changed_files`, and it took `<TASK_ID>` from the
**env cache**. The env cache is seeded at **claim** time by reading the claim
API response off the Bash tool's **stdout**. When that response is hidden from
the hook — the agent redirected the curl (`-o`), piped it through a transformer
(`jq`/`head`/…), or an oversized response was truncated with no fallback — the
cache keeps the **stale `TASK_ID` of the *previous* task**. (Note: `TASK_BASE_REF`
is still refreshed to HEAD; only the *identity* goes stale.) The `after_doing`
upload then PUTs the diff to the **previous** task, and the current task's
`changed_files` stays empty — silently.

The diff pipeline was therefore **load-bearing on the agent formatting the curl
correctly**, which is fragile and fails silently.

---

## 2. Change #1 — target the diff upload by the `/complete` URL id (D127)

**The insight:** on the `after_doing` / `before_review` path, the hook is
processing a `/complete` (or `/mark_reviewed`) curl whose URL **always** carries
the authoritative task id: `…/api/tasks/<id>/complete`. So derive the task id
**from that URL** and use it as the upload target, instead of the (possibly
stale) env-cache id. Fall back to the env-cache id **only** when the command has
no such URL (the claim path, whose URL carries no id).

This removes the dependency on the claim having seeded the cache correctly, and
**needs no network call** — the id is a pure parse of the command already in hand.

### 2a. Add a URL→id helper

**bash** (`stride-hook.sh`):

```bash
task_id_from_command() {
  local _rest
  case "$1" in
    */api/tasks/*/complete*|*/api/tasks/*/mark_reviewed*)
      _rest="${1#*/api/tasks/}"
      _rest="${_rest%%/*}"
      case "$_rest" in
        "" | *[!0-9]*) printf '' ;;   # not a bare numeric id → empty
        *) printf '%s' "$_rest" ;;
      esac
      ;;
    *) printf '' ;;                    # claim/next/etc. → empty (use env fallback)
  esac
}
```

**PowerShell** (`stride-hook.ps1`):

```powershell
function Get-TaskIdFromCommand {
    param([string]$CommandText)
    if ($CommandText -match '/api/tasks/([0-9]+)/(?:complete|mark_reviewed)') {
        return $Matches[1]
    }
    return ''
}
```

**Any other language:** match `/api/tasks/(\d+)/(complete|mark_reviewed)` against
the intercepted command string; return the captured digits, or empty if no match.

### 2b. Use it wherever the hook currently reads the env-cache task id for the upload

There are **two** call sites — do both:

1. **The `after_doing` finalize** (the function that captures the snapshot and
   PUTs it). Resolve the id from the command first, fall back to the env id:

   ```bash
   # in finalize_after_doing, before the upload:
   _tid=$(task_id_from_command "${COMMAND:-}")
   [ -n "$_tid" ] || _tid="${TASK_ID:-}"
   # …then use "$_tid" in upload_changed_files_snapshot AND record_diff_upload_state
   ```

2. **The `before_review` self-heal / retry** (the function that re-PUTs when no
   healthy 2xx is on record). Use the same URL-derived id for the state-file
   comparison, the re-PUT, and the state write:

   ```bash
   _tid=$(task_id_from_command "${COMMAND:-}")
   [ -n "$_tid" ] || _tid="${TASK_ID:-}"
   [ -n "$_tid" ] || return 0
   # …compare recorded state against "$_tid"; re-PUT to "$_tid"; record "$_tid"
   ```

If your runtime's self-heal reads `TASK_ID` from the environment/cache to decide
whether a healthy upload is on record, that comparison **must** also use the
URL-derived id, or the finalize (now URL-targeted) and the self-heal will disagree
on which task they're talking about.

### 2c. Gotchas (all confirmed in review)

- **Gate it to the completion path.** The hook already exits early on non-Stride
  commands; the URL parse only runs on `/complete` / `/mark_reviewed`. Do **not**
  fire a lookup on every command.
- **Keep the env-cache id as the fallback** for the claim path (no id in that URL).
- **No network call** — this is a pure string parse. Do not "fix" it by adding a
  fresh GET; the URL is authoritative and already present.
- **Preserve idempotency** — the re-PUT must fully replace the server snapshot,
  not append.

---

## 3. Change #2 — fail loud on a terminal upload failure (W1658)

The hook already warns per-attempt on a non-2xx PUT. W1658 adds a **distinct,
loud terminal signal** for when the upload *definitively* fails: the
`before_review` self-heal is the **last** retry, so a non-2xx there means the
diff is lost for the task. When that happens:

1. Print a **distinct** message to stderr (separate from the per-attempt warning),
   e.g.:
   `stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task <id> (HTTP <code>) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.`
2. Mark the upload-state file **unresolved** (append `unresolved=yes` to
   `.stride-diff-upload-state`) so the failure is queryable, not silent.

**Non-blocking rules (important):**

- Do **not** change the hook's exit code / abort an otherwise-valid completion.
  Surface loudly; the completion still succeeds.
- A **legitimately-empty** diff (a genuine no-op change that still PUTs 2xx) must
  take the success path — only non-2xx triggers the loud failure.
- A later **successful** PUT overwrites the state file, clearing the mark
  (the state writer already truncates/overwrites — keep that so the mark
  self-clears).
- Never put the bearer token in the message or the marker (id + HTTP code only).

**bash reference** (end of `self_heal_changed_files_upload`):

```bash
_http_code=$(upload_changed_files_snapshot "$_tid" "$_api_base" "$_token")
record_diff_upload_state "$_tid" "$_http_code"
case "$_http_code" in
  2*) : ;;
  *)
    printf 'stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task %s (HTTP %s) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.\n' \
      "$_tid" "$_http_code" >&2
    printf 'unresolved=yes\n' >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
    ;;
esac
```

**PowerShell reference** (end of `Invoke-SelfHealChangedFilesUpload`):

```powershell
$httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
if ($httpCode -notmatch '^2') {
    [Console]::Error.WriteLine("stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task $taskId (HTTP $httpCode) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.")
    try { Add-Content -Path (Join-Path $ProjectDir '.stride-diff-upload-state') -Value 'unresolved=yes' -Encoding UTF8 } catch { }
}
```

---

## 4. Per-runtime porting checklist

For each plugin repo, regardless of language:

1. **Find the two functions** in that runtime's hook: (a) the `after_doing`
   "finalize" that captures + PUTs the diff, and (b) the `before_review`
   self-heal / retry. (In the TypeScript ports these are methods/functions in the
   hook module; in bash/ps1 they're `finalize_after_doing` /
   `self_heal_changed_files_upload` and their PowerShell twins.)
2. **Add the URL→id helper** (Section 2a) and use it at both sites, falling back
   to the env-cache id only when the URL has no id (Section 2b).
3. **Add the terminal fail-loud + `unresolved=yes` marker** to the self-heal
   (Section 3).
4. **Add tests** (Section 5).
5. Bump the plugin version + CHANGELOG and cut the release per that repo's
   process. (Release order across the fleet is your call, but the server-side
   D128 detector is already independent — see the release-ordering note below.)

**Runtime inventory** (verify against your current set — names may drift):

| Runtime | Hook language | Notes |
|---|---|---|
| Claude Code (`stride`) | bash + PowerShell | **Reference — done.** |
| Gemini | (per that port) | own marketplace catalog |
| Codex | (per that port) | own marketplace catalog (vendored) |
| Copilot | (per that port) | own marketplace catalog (vendored) |
| OpenCode (`stride-opencode`) | TypeScript | github-ref install pin |
| Pi (`stride-pi`) | TypeScript | extract pure logic to a testable module |

---

## 5. Tests to add in each runtime

Mirror the Claude Code coverage:

- **URL→id unit test:** `/complete` and `/mark_reviewed` URLs → the numeric id;
  the claim/next paths and a non-numeric segment → empty.
  *(bash: tests 8j; ps1: covered via the integration test.)*
- **Targeting integration test:** with a **stale** env-cache id and a `/complete`
  command carrying a *different* id, assert the diff PUT targets the **URL** id,
  not the env id. Stub/record the HTTP call and assert the request path.
  *(bash: test 8k; ps1: test 7h.)*
- **Fail-loud test:** force the self-heal's final PUT to return non-2xx and assert
  (a) the distinct `CHANGED_FILES UPLOAD UNRESOLVED` message on stderr and
  (b) `unresolved=yes` in the state file. *(bash: test 13k; ps1: test 7i.)*

Also update any existing test that asserted "missing env `TASK_ID` → no PUT":
with the URL now providing the id, a `/complete` command **should** still PUT
(targeting the URL id). *(bash: test 8c was updated for exactly this.)*

---

## 6. Release-ordering note (server vs plugins)

Because these are independent (no API-contract change), any order is safe. The
recommended sequence is **deploy the server (D128 detector) first**, establish a
baseline from the `[:kanban, :task, :changed_files_missing]` telemetry while the
old plugins are still in the field, **then release the fixed plugins** and watch
that metric drop toward zero — that gives you before/after proof each runtime's
fix landed. Remember plugin releases roll out **per machine** (each agent must
update), so the detector also shows you which installs haven't updated yet.
