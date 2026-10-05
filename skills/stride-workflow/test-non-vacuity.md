# Break-it: proving a new or changed test can fail

Read this at Step 4 when this task's diff adds or changes a test. The rule is one sentence: for every test the diff adds or changes, break the behaviour it guards, run it and see it fail, restore, and run it again and see it pass. If it adds or changes none, none of this applies — there are no entries, Step 5 sends no `break_it`, and that absence is correct, not a gap.

Why the evidence has to come from you: the reviewer never runs code (`stride/agents/task-reviewer.md`, "Do not run tests or execute code"), so it can read a test but cannot see whether the test would ever go red. Tests that stayed green with the code they guard broken were a recurring mistake — in W2035 every assertion was satisfied by prose elsewhere in the file, in W2036 an `ok()` call sat outside its loop and fired unconditionally, in W2034 raising a cap from 8 to 1000 left every test green, and in W2171 an unclosed quote swallowed two assertions. Fix rounds regressed the same way (W2181 rounds 2 and 3, D337 round 2). Those were caught only because a reviewer happened to mutate them by hand; this procedure turns that luck into a check.

## What counts as a new or changed test

- A test is the smallest unit the runner reports on: an ExUnit `test`, a JavaScript `it`, or one `assert_*` line in the bash hook suite.
- **New** means the diff adds it. **Changed** means the diff edits its assertion, its setup or fixture, or the file or slice it reads.
- A test changed only in formatting — whitespace, line wrapping or comments, with every assertion and setup line unchanged in meaning — needs no entry. When in doubt, it changed.
- A test the diff does not add or change needs no break, even when its file changed elsewhere.
- When one test gains several new or changed assertions, record one entry per assertion, with `test` naming its line.

## The procedure

Work in the repository under change — on a plugin task, that is the nested repo, not the outer project.

1. **Snapshot the tree before the first break.** Porcelain status alone is not enough: at Step 4 your files are already modified, so a break left inside an already-modified file does not change its status line. Hash content as well: `snap() { git status --porcelain --untracked-files=all; git diff HEAD --binary; git ls-files --others --exclude-standard -z | xargs -0 shasum; }; snap | shasum`. Keep the printed hash in your notes — shell variables do not survive between tool calls, and a snapshot file would change the tree it describes.
2. **Break the behaviour minimally**, with one edit at the site that carries it: invert the condition, change the constant, remove the pinned phrase. The break must touch the behaviour the test asserts — a break somewhere the test never reads proves nothing. Never delete a file to break a test.
3. **Run that test and see it fail.** Record what you observed as `failed_when_broken`.
4. **Restore by reversing exactly that edit** — never with `git checkout`, `git restore`, `git stash` or `git reset`, which would also throw away your uncommitted work in the same file.
5. **Run it again and see it pass.** Record `passes_when_restored`.

**After the last test, run the snapshot again: the second hash must equal the first before the reviewer is dispatched**, and before any commit or hook runs. On a mismatch, find the leftover edit with `git diff` and reverse it, then re-snapshot.

**A test green when broken is vacuous.** Fix the test — narrow the slice it reads, make the pinned phrase unique, move the assertion inside its loop, close the quote — and break it again. Send `false` only when you cannot fix it, and never flip an observed `false` to `true`.

### Text pins

For a test that pins a phrase in a document, the break is altering that phrase at the site that carries the rule. First count its occurrences in the text the test reads: `sed -n '<range>p' <file> | grep -oF -- '<phrase>' | wc -l` — occurrences, not `grep -c`, which counts lines and reports 1 for a line that carries the phrase twice (a markdown link `[x.md](x.md)` does exactly that). A count above 1 means a one-site break leaves the test green — the shape of W2035. Narrow the slice or pin a longer phrase until the count is 1.

Text pins may be broken together in one batched run when every pinned phrase occurs exactly once in its slice and no two pinned phrases overlap; each broken pin must then fail and nothing outside the batch may change. Overlap is about phrases, not lines — several pins can sit on one physical line.

## Safety rules

- Breaks happen only in the working tree of the repository under change. Nothing outside it is edited, created or deleted.
- **No destructive commands, no network.** No `rm -rf`, no history rewrite, no restoring by checkout, no call to a remote, a registry, an API or the Stride server.
- No shared state: no shared database (a test's own sandbox is fine), no global configuration, no hook cache files, no other process.
- Never place a break in a gitignored file: the snapshot hashes only tracked and unignored files, so it could not prove that restore.
- **Never commit a broken state.** One break at a time unless batched as above, and the snapshot check proves the restore.
- A test that cannot be broken without side effects outside the repository is recorded with a one-line `not_broken_reason` instead of being skipped silently. Its `break` and both booleans are `null`. A reason that names no outside side effect — "slow", "obvious", "trivial" — is not a reason: break the test.

## The `break_it` entries

```json
[
  { "test": "hooks/test-stride-hook.sh:16140", "break": "removed the pinned phrase at skills/stride-workflow/x.md:12", "failed_when_broken": true, "passes_when_restored": true },
  { "test": "test/kanban/mailer_test.exs:41", "break": null, "failed_when_broken": null, "passes_when_restored": null, "not_broken_reason": "the guarded behaviour is the remote SMTP handshake; breaking it needs the network" }
]
```

- `test` is `<file>:<line>` or `<file>:<test name>`, repo-relative.
- `break` is one line naming what you changed and at which `file:line`.
- `failed_when_broken` and `passes_when_restored` record what you observed, never what you expected.
- Never paste test bodies, diff text or command output into an entry. A credential-shaped string becomes `[REDACTED — break text embedded a credential]` with its `file:line` cited instead — in the dispatch prompt, in `completion_notes` and in `completion_summary` alike.

Step 5 sends the entries to the reviewer as `break_it` — the input is documented in [review-block-extraction.md](review-block-extraction.md) beside `commit_pending`. When the decision matrix skips review, run the procedure anyway and send nothing. Without a reviewer subagent, check your own entries in self-review the way review step 4 of `stride/agents/task-reviewer.md` does.

## Re-review rounds

A fix touches a test when it edits the test or the site that test's entry broke. Break every touched test again; send fresh entries for those and round one's entries unchanged for the rest. Fixes that touch no test: resend round one's entries unchanged. When the round cap means no round two runs, still break every touched test again before submitting — a fix round is exactly where W2181 and D337 regressed. `review_round.fixes[]` is not this record: it says what changed, not what was proven.

## Worked example — a phrase that appears twice

A test pins the bare filename against the whole file: `assert_contains "Na: pointer" 'x.md' "$(cat SKILL.md)"`, where the pointer line reads `[x.md](x.md)`. The implementer breaks the link text, `[x.md]` becomes `[y.md]`, and runs the suite: the test stays green, because `x.md` still appears in the link target and the whole file is the slice. The occurrence count would have said so first — `grep -oF -- 'x.md'` finds it twice on that one line, where `grep -c` reports 1. The entry would read `failed_when_broken: false`, so the test is vacuous. The fix is to pin a phrase that occurs once in a narrower slice — the whole link, or the bold sentence around it — then break it again and observe the failure.

## One limit, stated rather than papered over

The entries are your own observation. The reviewer checks that each is plausible against the diff — that the break touches what the test asserts — but cannot re-run it, which is the same honour system as `commit_pending`'s `performed_by`. What the check removes is the silent case: a new test that nobody ever saw fail.
