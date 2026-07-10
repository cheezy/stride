# Root cause: empty `changed_files` on completed tasks (D126)

**Status:** Confirmed. Investigation task **D126** (goal **G321**).
**Symptom:** Tasks complete with `changed_files: []` on the server, so the Review
UI renders every line as `UNKNOWN`. Observed on all 11 tasks of one batch
(D105–D115), 100% of the time, independent of `needs_review`.

## The failure in one sentence

The `changed_files` diff pipeline is driven entirely by the plugin hook
(`stride-hook.sh`) reading the Stride API response off the Bash tool's **stdout**;
when the claim curl's response is hidden from the hook — the agent redirected it
(`-o`), piped it through a transformer (`jq`/`head`/`awk`), or an oversized
`/complete` response was truncated with no `.stride/.last-api-response.json`
fallback — the hook cannot recover the new task's identity, so it leaves the
**stale `TASK_ID`** of the previous task in the env cache. The later
`after_doing` capture then `PUT`s the diff to that previous task's id, and the
current task's `changed_files` stays `[]`.

## Why the review *results* survive but the *diff* does not

Two kinds of data travel two paths:

- **Review results** (`reviewer_result`, `review_report`) ride **inside the
  `PATCH /complete` body** the agent sends. They do not depend on the hook.
- **File diffs** (`changed_files`) are captured and `PUT` **by the hook**, which
  needs to observe the API call/response on stdout.

This is the observed fingerprint: on all 11 tasks `actual_files_changed` (a
body field) is populated while `changed_files` (hook-captured) is empty.

## The mechanism, link by link

1. **Claim.** The `post` hook is meant to seed `.stride-env-cache` with
   `TASK_ID`, `TASK_IDENTIFIER` (from the claim response) and `TASK_BASE_REF`
   (local `git rev-parse HEAD`). Subsequent hooks read this cache.
2. **Hidden response → stale identity.** When the claim response is not visible
   to the hook (redirect/pipe/truncation, no canonical-file fallback), the
   fallback else-branch **refreshes `TASK_BASE_REF` to HEAD** but has no response
   to read the identity from, so **`TASK_ID`/`TASK_IDENTIFIER` are left stale**
   (the prior task's). This was confirmed empirically: a *visible* claim updates
   `TASK_ID` to the new task; a *hidden* claim leaves it unchanged.
3. **After_doing PUTs to the wrong task.** `finalize_after_doing` captures the
   diff correctly (base ref was refreshed) but `PUT`s it to the **stale
   `TASK_ID`**'s `/changed_files` endpoint — the *previous* task. The current
   task's `changed_files` is never populated (and the previous task's may be
   overwritten). The stale-identity link — not a stale base ref — is the driver.

## Deterministic reproduction

```bash
HOOK_SCRIPT="$PWD/stride/hooks/stride-hook.sh"
D=$(mktemp -d); cd "$D"
git init -q; git config user.email t@t.local; git config user.name T
echo v1 > a.txt; git add a.txt; git commit -q -m v1
# A .stride.md MUST exist, or the hook exits at the STRIDE_MD guard before seeding:
printf '## before_doing\n```bash\ntrue\n```\n' > .stride.md
printf "TASK_ID='OLD999'\nTASK_IDENTIFIER='W000'\nTASK_BASE_REF='deadbeef'\n" > .stride-env-cache
# Claim whose JSON response is hidden from stdout (agent used `-o`):
CLAIM='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -o out.json"},"tool_response":{"stdout":"HTTP 201"}}'
echo "$CLAIM" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post >/dev/null 2>&1
grep '^TASK_ID=' .stride-env-cache   # → still TASK_ID='OLD999' (stale); TASK_BASE_REF, by contrast, refreshed to HEAD
# Contrast: the same claim WITHOUT `-o` (response visible on stdout) updates TASK_ID to the new task.
```

The same behavior was observed live: claiming D126 with a `-o` redirect left
`.stride-env-cache` pointing at the previously-worked task (`W1645`), and no
`.stride-changed-files.json` snapshot or `.stride-diff-upload-state` file was
ever produced.

## Why this is NOT the 120-second timeout

A timeout is intermittent and would kill an upload *after* a capture. Here there
is **no capture at all** (no snapshot file ever), it is **100% consistent**, and
it reproduces the instant the response is hidden from the hook — which has
nothing to do with the clock. The checked-in `after_doing` gate running the full
suite was present, but it is not the cause of the empty diffs.

## Implications for the fix (goal G321)

- **Server gate (D128) is the only guarantee.** A client-side, hook-driven,
  silent pipeline cannot be *trusted*; the server must refuse a review-bound
  completion that lacks a valid diff.
- **Legitimately-empty is distinguishable.** A *lost* diff shows `changed_files`
  empty **while `actual_files_changed` is non-empty**. A *genuine* no-op change
  has **both** empty. The gate keys on that mismatch, so it never blocks a real
  no-op change.
- **Make the hook stdout-independent (D127).** Resolve `TASK_ID` from the env
  cache or a fresh hook-initiated `GET` (the D119 `after_goal` pattern) and
  capture the local diff regardless of curl formatting, so a correctly-formatted
  curl is no longer load-bearing.
- **Document the correct invocation (W1661).** Never `-o`/pipe-transform; always
  `| tee "$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json"` to preserve
  stdout *and* persist the truncation fallback. Defense-in-depth, not the guarantee.
