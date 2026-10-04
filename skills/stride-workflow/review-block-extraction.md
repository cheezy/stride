# Review Block Extraction Reference

Read this at Step 5, after the task-reviewer has returned (or when an older reviewer emitted its block inline), while building `reviewer_result`. The dispatch procedure, the three-source order, and the always-read-from-the-paths-YOU-supplied rule stay in the orchestrator skill; everything below is the mechanics that run once you hold `$BLOCK` and `$REPORT`.

## The `commit_pending` dispatch assertion

**`commit_pending` — orchestrator-asserted, not a field the task supplies.** Step 5's reviewer dispatch passes every review field *the task supplies*; this one is a lifecycle fact only you know, so it is passed alongside that list rather than added to it. **Set it when this task's commit is genuinely a step still ahead of the review.** Step 5 runs before Steps 6 and 7, so on a project whose `## after_doing` stages and commits (`git add -A`) that is the ordinary case; on a nested-repo task it is whichever later step or operator makes that commit. **On that nested-repo shape, make `performed_by` do real work**: a criterion reading only "the fix is committed to the plugin repo" gives the reviewer nothing to separate your scheduled commit from an earlier one the task itself required, so leg (c) is undecidable and the standing default refuses the carve-out — you get the blocked round anyway. Name the step **and** its position relative to this task's work (for example "the operator's manual commit inside the nested plugin repo, made after this review and after the after_doing gate — no earlier commit in that repo was required by this task"), so leg (c) has a yardstick. If this task DID require an earlier commit in that repo, do not assert the flag at all. **What it must carry:** `{ "pending": true, "performed_by": "<the step that makes this commit>" }`, plus the pre-review commit state below when it can be produced. A bare `true` with no `performed_by` is an incomplete assertion — **do not send one**: `performed_by` is precisely what lets the reviewer tell a scheduled commit from an overdue one, and without it the flag degrades into a blanket licence to ignore any commit criterion. **When NOT to set it:** when the task's own work required a commit that should already have happened — a mid-work commit the task specified, or a nested-repo commit already made. **Never set it to make a `changes_requested` round pass.** It asserts a lifecycle fact, not a desired outcome; asserting it falsely hides real uncommitted work, which is a worse defect than the extra round it would have avoided. **Re-review rounds:** re-evaluate the assertion each round, and stop sending it once the commit has actually been made. The carve-out's semantics — what qualifies, what is emitted, and what it may never do — are owned by `stride/agents/task-reviewer.md` (the `acceptance_criteria` array hard rule and the `status` rule); do not restate them here.

**Pre-review commit state — `base_ref` and `head` — makes leg (a) checkable.** When this task's commit lands in the **project-root** repo, add `"base_ref"` (the base the hook itself would select from `.stride-env-cache` — this task's per-task `TASK_BASE_REF_<id>` record when one exists, else the shared `TASK_BASE_REF` Step 5 read for the diff, provided the cache marks it neither unproven nor owned by another task) and `"head"` (`git rev-parse HEAD` at the moment you dispatch) to `commit_pending`. The reviewer does not take them on trust: it checks `head` against the repo's own `HEAD`, `base_ref` against that same hook-selected base (a missing cache fails verification rather than skipping the check), and ancestry between them, then requires that the commit the criterion asks for is absent from `base_ref..head` — the full procedure is in `stride/agents/task-reviewer.md`. Pass the two values as bare object names and nothing else: no paths, no remotes, no command text. **On a nested-repo commit, omit both and say so in the dispatch prompt.** **Never send one key without the other** — the reviewer treats a lone key as failed verification, not as absent evidence. An older orchestrator that sends neither key is unaffected. Why a nested-repo commit omits both, and the two residuals this evidence leaves open: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § commit_pending Evidence — Nested Repos and Residuals.

**The carve-out is scope-pinned by a check you must not skip.** This pin verifies *containment*, not lifecycle order, so it runs whether or not the `base_ref`/`head` evidence is present: the *result* is verified — the `commit_pending_scope_ok` boolean in the MANDATORY Source A self-check below asserts that every `"not_met"` criterion is either paired with an `acceptance_criteria` issue or carries the sentinel, never neither and never both. It runs on **both** extraction paths — as `commit_pending_scope_ok` in the Source A jq, and as the matching assertion in the Source B self-check, which is reachable whenever the reviewer's block write fails and it emits the fence inline — costs a dispatch without `commit_pending` nothing, and **a failure on either path means do not submit.** The check and its exact jq are in the Source A self-check below; do not restate them elsewhere. Why it runs even where that evidence exists: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why the Scope Pin Runs Either Way.

## Review rounds — the counter, the cap, and its five variables

**A round is a reviewer dispatch that produced a `$MERGED` file** — not a dispatch. `<N>` stays a dispatch counter that increments for crashed re-dispatches so two dispatches never share a path, so a crashed or unparsable reviewer burns a filename, not a round. `$MERGED` is the authority rather than `$BLOCK` because it is written on **both** Source A and Source B, so an inline-fence round counts identically to a file round.

**Run this block AFTER this round's `$MERGED` has been written**, on both source paths, so the recount includes the round you are about to submit. That ordering is load-bearing — the Source B round-cap comment says why — so Source B runs its round-cap assert below the `json.dump`.

The counter lives in `$ROUNDS_FILE` — `.stride/.review-rounds-<IDENTIFIER>.json`, absolute, under the same resolved project root as `$BLOCK`, `$REPORT` and `$MERGED`. `$IDENT` is the task identifier only when it matches `^[A-Za-z0-9_-]+$` **anchored — a containment match would let `../../etc/x` through as a path component** — else the numeric task id. Test it as a full match, never a substring: `case "$IDENT" in ( '' | *[!A-Za-z0-9_-]* ) IDENT="$TASK_ID" ;; esac`. The file carries exactly two keys, `{"identifier": "W1234", "rounds": 2}` — an identifier and an integer, never a finding, never review content, and never a path built from task free text.

**Disk is the authority; the file is a record.** Recount on every use and take the larger, so a lost file cannot reset the cap and a stale one cannot under-report:

```bash
# $STRIDE_DIR is the resolved project root's .stride/ -- the SAME directory that
# holds $BLOCK, $REPORT and $MERGED. Resolve the root as Step 5 does: walk up to
# the first ancestor containing .stride.md ($CLAUDE_PROJECT_DIR is not reliably
# set). Assign it explicitly; unlike $BLOCK, whose unset value makes jq fail
# loudly, an unset $STRIDE_DIR would glob nothing, yield RECOUNT=0 and let the
# cap read green -- a fail-open, and the exact class this block guards against.
STRIDE_DIR="${STRIDE_DIR:-}"
if [ -z "$STRIDE_DIR" ] || [ ! -d "$STRIDE_DIR" ]; then
  # Fail CLOSED: no directory means no evidence, not "no rounds yet".
  REVIEW_ROUND=-1; PRIOR_CRITICAL=0; PRIOR_SECURITY=0
  echo "round-cap: STRIDE_DIR unset or not a directory -- resolve it and re-check" >&2
else
ROUNDS_FILE="$STRIDE_DIR/.review-rounds-$IDENT.json"
ROUND_LIST=$(for f in "$STRIDE_DIR/.reviewer-result-$IDENT-r"*.json; do
  [ -f "$f" ] || continue
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || continue
  n=${f##*-r}; n=${n%.json}
  case "$n" in ( '' | *[!0-9]* ) continue ;; esac
  printf '%s\t%s\n' "$n" "$f"
done | sort -n -k1,1)
RECOUNT=$(printf '%s' "$ROUND_LIST" | grep -c .)
RECORDED=$(jq -r 'if (.rounds|type) == "number" then (.rounds|floor) else 0 end' "$ROUNDS_FILE" 2>/dev/null || echo 0)
case "$RECORDED" in ( '' | *[!0-9]* ) RECORDED=0 ;; esac
REVIEW_ROUND=$RECORDED
[ "$RECOUNT" -gt "$RECORDED" ] && REVIEW_ROUND=$RECOUNT
jq -n --arg id "$IDENT" --argjson n "$REVIEW_ROUND" '{identifier: $id, rounds: $n}' \
  > "$ROUNDS_FILE.tmp" && mv "$ROUNDS_FILE.tmp" "$ROUNDS_FILE"

# PRIOR_CRITICAL: the PREVIOUS round's critical count -- the second-highest
# entry by NUMERIC round index. Ordering matters and is not cosmetic: lexical
# order sorts r10 before r9, so a string-ordered "second highest" reads r8 at
# ten dispatches and silently turns a live exemption into a refusal.
# PRIOR_SECURITY: that same round's count of category "security" issues, at any
# severity -- one of round two's three triggers. Type-guarded like the rest.
PRIOR_CRITICAL=0; PRIOR_SECURITY=0
if [ "$RECOUNT" -ge 2 ]; then
  PREV=$(printf '%s\n' "$ROUND_LIST" | tail -2 | head -1 | cut -f2)
  [ -n "$PREV" ] && PRIOR_CRITICAL=$(jq -r '(.issue_counts.critical | numbers) // 0 | floor' "$PREV" 2>/dev/null || echo 0)
  [ -n "$PREV" ] && PRIOR_SECURITY=$(jq -r '[((.issues | arrays) // [])[] | objects | select(.category == "security")] | length' "$PREV" 2>/dev/null || echo 0)
fi
case "$PRIOR_CRITICAL" in ( '' | *[!0-9]* ) PRIOR_CRITICAL=0 ;; esac
case "$PRIOR_SECURITY" in ( '' | *[!0-9]* ) PRIOR_SECURITY=0 ;; esac
fi
```

**Keep that loop exactly as written:** `jq -e 'type == "object"'` rather than `jq empty`, the numeric `sort -n`, and the leading `(` in each `case` pattern each fixed a defect — [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why the Round-Counter Loop Is Written This Way.

**Do not confuse the shell `REVIEW_ROUND` with the `review_round` dispatch field.** They are different things that share a name: the dispatch field is what the *reviewer* receives, and absent means round 1 with nothing about its review changing. The shell variable is what this *self-check* consumes, and absent means the recount above never ran — a defect, hence `-1` and a refusal rather than a permissive default.

**`CRITICAL_CLEARED` — the only self-certified variable.** Set it to `1` when this round exists **solely** to verify a fix for a `critical` that no prior round recorded — one found by you while fixing, by a Step 5.5 exploratory escalation, or by a human — and `0` (the default) otherwise. Why it exists: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why CRITICAL_CLEARED Exists. It is asserted on the same terms as `commit_pending`: **record what it was for in `completion_notes` and one line of `completion_summary`** — bounded the way `fixes[]` is bounded: name the `critical` by severity, category and `file:line` plus one line of what the round verified, **never its description or diff text**, redacted as for any session text, and **never set it to make a cap-reached round pass** when the open findings are `important`/`minor` — that is the exact abuse the cap exists to prevent, and it is a worse defect than the round it would avoid.

**What `review_round.fixes[]` may carry.** Name each round-one finding you fixed by **severity, category and `file:line` only** — the fields the bounded summary already rendered into your context — plus one line naming the change you made. **Never paste the previous block, its prose, or diff text.** The dispatch prompt is ephemeral, but it is still an artifact, and the reviewer is barred from reading round one's files precisely so that round one's content does not travel; pasting it here would defeat that by another route.

**Round two has three triggers — decide before you dispatch it.** Round two runs only when round one earned it: round one reported a `critical` (`PRIOR_CRITICAL`), or a `category: "security"` issue at any severity (`PRIOR_SECURITY`, read from round one's `$MERGED`, so it includes a security finding the deep-security escalation wrote there), or round one's fixes edited a code path (`FIX_CODE_PATHS` not `0`). `CRITICAL_CLEARED` above is the one other way a round past the first is legal, on its own terms. **Without a trigger, every fixed finding is recorded, not re-reviewed:** name each on the `fixes[]` bound above — severity, category, `file:line` and one line of what changed, redacted — in `completion_notes` and one line of `completion_summary`, and submit round one's `$MERGED`. Read the two prior-round triggers straight off round one's file before dispatching — `jq -e '((.issue_counts.critical | numbers) // 0) > 0 or ([((.issues | arrays) // [])[] | objects | select(.category == "security")] | length) > 0' "$MERGED"` — and the third from the fence below. That `jq -e` exits `1` for *no prior-round trigger*; any other non-zero exit means `$MERGED` was unset, missing or unreadable — treat it as a trigger, never as none. **Step 5.5's "fixed in this task and re-reviewed" is governed by these triggers too.** A Step 5.5 finding below `critical` is never written to `issues[]`, so `PRIOR_SECURITY` cannot see it: its fix earns round two by editing a code path, and is recorded otherwise. That leaves one gap, disclosed as limit (e) below.

**A code path is decided by path and changed-line shape, never by judgement.** A changed path is **not** code when it is documentation (`*.md`, `*.mdx`, `*.markdown`, `*.rst`, `*.adoc`, anything under `docs/`, `README*`, `CHANGELOG*`, `LICENSE*`), a test (`test/`, `tests/`, `spec/`, `__tests__/`, `*_test.*`, `*.test.*`, `*_spec.*`, `*.spec.*`, `test-*.sh`, `test-*.ps1`), or a text change whose every changed line is blank or a **whole-line** comment: `// …`, `/* … */` closed on the same line, `<!-- … -->`, `<%# … %>`, or `# …` and a bare `#` outside C-family sources, where `#` opens a preprocessor directive. A lone `/*` or `*/`, or a comment followed by code, is code. Everything else is code — `*.txt` included, because `requirements.txt` and `CMakeLists.txt` are build inputs. So a fix confined to docs, comments, the changelog or test wording never buys round two, and a one-character change to a code path always does.

**The fix-path classifier.** Run it with `FIX_STAGE=base` **once**, after round one returns and before your first fix: it snapshots each repository's whole working tree — untracked files included, `.gitignore` honoured — as a git tree, recorded in `.stride/.review-fixbase-<IDENTIFIER>.txt` and never overwritten. Run it with `FIX_STAGE=count` after fixing, to decide whether round two runs, and again beside the recount whenever a round-two self-check runs. `FIX_REPOS` names the repositories the fixes may touch, one per line; on a nested-repo task that is the nested repo, never the project root that ignores it.

```bash
fix_tree() { # $1=repo -> a tree object of the whole working tree, untracked included
  t=$(mktemp -d "${TMPDIR:-/tmp}/stride-fix.XXXXXX") || return 1
  cp "$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)/index" "$t/index" 2>/dev/null
  GIT_INDEX_FILE="$t/index" git -C "$1" add -A >/dev/null 2>&1 &&
    GIT_INDEX_FILE="$t/index" git -C "$1" write-tree 2>/dev/null
  rc=$?; rm -rf "$t"; return $rc
}
fix_code_count() { # $1=repo $2=base tree $3=current tree -> number of code paths changed
  git -C "$1" diff-tree -r --name-only "$2" "$3" | while IFS= read -r p; do
    case "$p" in
      ( .stride/* | *.md | *.mdx | *.markdown | *.rst | *.adoc | docs/* | */docs/* \
      | README* | */README* | CHANGELOG* | */CHANGELOG* | LICENSE* | */LICENSE* ) continue ;;
      ( test/* | */test/* | tests/* | */tests/* | spec/* | */spec/* | __tests__/* | */__tests__/* \
      | *_test.* | *.test.* | *_spec.* | *.spec.* | test-*.sh | */test-*.sh | test-*.ps1 | */test-*.ps1 ) continue ;;
    esac
    # A text change whose every changed line is blank or a WHOLE-LINE comment is
    # not code. No hunk at all (binary, mode-only) counts as code. In C-family
    # sources '#' opens a preprocessor directive, never a comment.
    case "$p" in ( *.c | *.h | *.cc | *.cpp | *.cxx | *.hh | *.hpp | *.m | *.mm ) cfam=1 ;; ( * ) cfam=0 ;; esac
    git -C "$1" diff -U0 --no-color "$2" "$3" -- "$p" | awk -v cfam="$cfam" '
      /^@@/ { h = 1; next }
      h && /^[+-]/ { t = substr($0, 2); sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t); n = length(t)
        if (n == 0 || substr(t, 1, 2) == "//") next
        if (substr(t, 1, 2) == "/*" && n >= 4 && index(t, "*/") == n - 1) next
        if (substr(t, 1, 4) == "<!--" && n >= 7 && index(t, "-->") == n - 2) next
        if (substr(t, 1, 3) == "<%#" && n >= 5 && index(t, "%>") == n - 1) next
        if (!cfam && (t == "#" || substr(t, 1, 2) == "# ")) next
        c = 1 }
      END { exit (h && !c) ? 0 : 1 }' && continue
    echo "$p"
  done | grep -c .
}
STRIDE_DIR="${STRIDE_DIR:-}"
FIX_REPOS="${FIX_REPOS:-$(git rev-parse --show-toplevel 2>/dev/null)}"
FIX_CODE_PATHS=-1   # -1 = unmeasured: round two stays available, a third never does
if [ -z "$STRIDE_DIR" ] || [ ! -d "$STRIDE_DIR" ]; then
  echo "fix-paths: STRIDE_DIR unresolved -- FIX_CODE_PATHS stays -1 (unmeasured)" >&2
else
FIX_BASE_FILE="$STRIDE_DIR/.review-fixbase-$IDENT.txt"
case "${FIX_STAGE:-}" in
( base )
  printf '%s\n' "$FIX_REPOS" | while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    # Never overwrite: the base is the tree as it stood BEFORE the first fix.
    awk -v r="$repo" '{ sub(/^[^ ]* /, "") } $0 == r { f = 1 } END { exit !f }' \
      "$FIX_BASE_FILE" 2>/dev/null && continue
    tree=$(fix_tree "$repo") || tree=unknown
    case "$tree" in ( '' | *[!0-9a-f]* ) tree=unknown ;; esac
    printf '%s %s\n' "$tree" "$repo" >> "$FIX_BASE_FILE"
  done ;;
( count )
  if [ -s "$FIX_BASE_FILE" ]; then
    FIX_CODE_PATHS=$(total=0
      while IFS=' ' read -r base repo; do
        case "$base" in ( '' | *[!0-9a-f]* ) total=-1; break ;; esac
        git -C "$repo" cat-file -e "$base^{tree}" 2>/dev/null || { total=-1; break; }
        now=$(fix_tree "$repo") || { total=-1; break; }
        n=$(fix_code_count "$repo" "$base" "$now")
        case "$n" in ( '' | *[!0-9]* ) total=-1; break ;; esac
        total=$((total + n))
      done < "$FIX_BASE_FILE"
      printf '%s' "$total")
  fi ;;
esac
fi
```

**Five limits of the classification, stated rather than papered over.** (a) It reads paths and line prefixes only: an `@doc` or docstring edit counts as code, `#[derive]` stays code because a comment `#` must be followed by a space or end the line, and in C-family sources no `#` line is a comment. Odd filenames can only over-count, which keeps round two available. In a repository whose product is markdown — this plugin, whose skills and agents are `.md` — a skill edit classifies as documentation. That is deliberate: those were exactly the second rounds that found wording rather than defects. (b) `-1` means *unmeasured* — no base recorded, `$STRIDE_DIR` unresolved, or a tree git could not produce — and keeps round two available, which is the behaviour before this rule existed; it never buys a third round. (c) Only the repositories named in `FIX_REPOS` when the base was recorded are measured. (d) The pin bounds rounds from above only: a round two that should have run and was skipped is caught by nothing mechanical, exactly as before this rule. (e) A security-relevant Step 5.5 finding below `critical` whose fix lands only in documentation paths earns no round two, because Step 5.5 never writes such a finding to `issues[]`; in this plugin that includes shell embedded in a skill's markdown. Name it in `completion_notes` so a human sees the unverified fix.

**Clearing the counter at claim time.** The counter and its artifacts are scoped to **one attempt**, not to the checkout. Clear them on a successful claim, using the same anchored `$IDENT` — why, and the D234 precedent: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why the Counter Is Cleared at Claim Time.

**Resolve `$STRIDE_DIR` here rather than assuming it.** This runs at Step 2, *before* Step 5 resolves the project root, so the variable is normally unset at this point — and an unset one makes every glob below expand against `/` or the cwd and delete nothing, turning the fix for the most reachable stranding route into a silent no-op. Guard it, and skip loudly rather than running an unrooted `rm`. The identical resolution and guard apply to **Step 7's cleanup**, which deletes the same shapes for every round once the PATCH has succeeded; its globs cover every round rather than only the last, because `$BLOCK`/`$REPORT`/`$MERGED` name only the final one, and they are safe precisely because `$IDENT` is anchor-matched above:

```bash
# Walk up to the first ancestor containing .stride.md; CLAUDE_PROJECT_DIR is
# not reliably set, and a nested repo or non-root cwd would guess wrong.
d=$PWD; STRIDE_DIR=""
while [ "$d" != "/" ]; do
  [ -f "$d/.stride.md" ] && { STRIDE_DIR="$d/.stride"; break; }
  d=$(dirname "$d")
done
if [ -z "$STRIDE_DIR" ] || [ ! -d "$STRIDE_DIR" ]; then
  echo "review artifacts: STRIDE_DIR unresolved -- skipping clear, not globbing /" >&2
else
  rm -f "$STRIDE_DIR/.review-rounds-$IDENT.json" "$STRIDE_DIR/.review-fixbase-$IDENT.txt" \
       "$STRIDE_DIR/.review-$IDENT-r"*.json "$STRIDE_DIR/.review-$IDENT-r"*.md \
       "$STRIDE_DIR/.reviewer-result-$IDENT-r"*.json "$STRIDE_DIR/.review-tree-$IDENT-r"*.txt \
       "$STRIDE_DIR/.security-$IDENT-r"* "$STRIDE_DIR/.follow-ups-$IDENT.json"
  # Step 7 only: also "$EXPLORER_REPORT_PATH" "$PLAN_REPORT_PATH" "$STRIDE_DIR/.exploratory-$IDENT-r"*.json "$STRIDE_DIR/.task-$IDENT.json"
  # (never at claim time: the claim hook has just written that task file)
fi
```

Re-claiming is therefore also the **only sanctioned repair** for a counter that over-reports — the take-the-larger rule has no downward path within an attempt, by design, so a stale or inflated `rounds` value would otherwise be permanent. Never hand-delete these files mid-attempt to buy another round: that is the one move this whole control exists to prevent.

**Five limits, stated rather than papered over.** (1) A Source C round writes no `$MERGED` and therefore does not count, so this cap does not bound a reviewer that repeatedly lands on Source C — the convergence rule in `stride/agents/task-runner.md` is what bounds that, and for the same reason a Source C round can never supply a non-zero `PRIOR_CRITICAL` or `PRIOR_SECURITY`, so a Critical found on that path needs `CRITICAL_CLEARED`. (2) **`CRITICAL_CLEARED` is self-certified but NOT result-verified, and that is a real asymmetry with `commit_pending`, which it otherwise resembles.** `commit_pending` is pinned mechanically by `commit_pending_scope_ok` on both paths; `critical_cleared` has no counterpart — `($cc == 1)` unlocks any round number, and nothing checks that a `critical` ever existed, that this round verified one, or that `completion_notes` recorded what it was for. The prohibition on using it to pass a cap reached with only `important`/`minor` findings is therefore **prose only**, which is the shape this feature's own pitfalls rule out for the cap itself. It is disclosed here rather than left implied; a mechanical pin needs a signal the block does not currently carry. (3) **`cosmetic` is self-certified and NOT result-verified, exactly as `CRITICAL_CLEARED` is.** `cosmetic_shape_ok` checks the flag's *type* and its *co-ordinates* — severity and category — and **cannot reach its truth**. A reviewer that marks a substantive `minor` cosmetic passes every boolean and ends the review loop, and no signal in the block is independent of the reviewer's judgement, which is the same reason a pin was impossible for `CRITICAL_CLEARED`. So the cheapest abuse is not relabelling a `critical` or a `security` finding — the pin refuses those — but relabelling an ordinary substantive `minor`, which it cannot see. Disclosed here rather than left implied; the remedy is a human reading `issues[]`, and note the Review queue currently groups by severity alone, so the flag is invisible there. (4) **The all-cosmetic re-review disposition is likewise Source-A/B only.** `cosmetic_shape_ok` can only run where a structured block parsed; on Source C `issues[]` is absent by construction, so "every entry is cosmetic" is vacuously true and the rule is inapplicable rather than satisfied — an absent or empty `issues[]` is never an all-cosmetic round. (5) The `critical` exemption is deliberately unbounded, so a reviewer that keeps reporting a `critical` is bounded only by that same convergence rule; the cap governs rounds, never correctness, and this is the price of that.

## Guards on Source A

**Two further guards on Source A, both required.** Treat a `block:` line that does **not** match the path you supplied as a signal that the reviewer did not write where it was told — do not read the named file, and fall to Source B. And `$BLOCK` MUST pass `jq empty` before use; a parse failure (a half-written file from a killed reviewer) also falls to Source B. **Never read a previous round's file.** The same mismatch rule applies to `report:`: fall back to the reviewer's returned text, exactly as for an older reviewer that wrote no report at all.

## Source A pattern

**Splice, never retype.** `$BLOCK` is the path you supplied, `$MERGED` is `.stride/.reviewer-result-<IDENTIFIER>-r<N>.json`, **absolute, under the same resolved project-root `.stride/` as `$BLOCK` and `$REPORT`** — a repo-relative path would land in the wrong place from a nested repo or a non-root cwd, which the orchestrator's Step 5 already warns is unreliable:

```bash
if ! jq empty "$BLOCK" 2>/dev/null; then
  : # unreadable, half-written, or absent → fall through to Source B; do NOT run the merge below
else

jq -n --slurpfile s "$BLOCK" --argjson dur "$WALL_MS" '
  $s[0] + { dispatched: true, duration_ms: $dur,
            summary: $s[0].summary,
            issues_found: (($s[0].issue_counts.critical  // 0)
                         + ($s[0].issue_counts.important // 0)
                         + ($s[0].issue_counts.minor     // 0)),
            acceptance_criteria_checked: ($s[0].acceptance_criteria | length) }
' > "$MERGED"
fi
```

**Keep `$s[0] + {…}` and the per-severity `issue_counts` sum as written** — never `[.issue_counts[]] | add`, which would also sum unrecognized severity keys; why: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why the Source A Merge Is a Whole-Object Overlay.

**MANDATORY self-check for Source A** — prints eight values and no payload:

```bash
jq -n --slurpfile s "$BLOCK" --slurpfile r "$MERGED" --argjson n "$TASK_CRITERION_LINES" \
  --argjson round "${REVIEW_ROUND:--1}" --argjson prior_critical "${PRIOR_CRITICAL:-0}" \
  --argjson critical_cleared "${CRITICAL_CLEARED:-0}" --argjson prior_security "${PRIOR_SECURITY:-0}" \
  --argjson fix_code_paths "${FIX_CODE_PATHS:--1}" '
  ($s[0].acceptance_criteria // []) as $ac
  | [$ac[] | select(.status=="not_met" and ((.evidence // "") | startswith("PENDING COMMIT — ")))] as $pending
  | ([$ac[] | select(.status=="not_met")] | length) as $not_met
  | ([($s[0].issues // [])[] | select(.category=="acceptance_criteria")] | length) as $ac_issues
  | { dropped_sections: (($s[0]|keys) - ($r[0]|keys)),
      project_checks_equal: ((($r[0].project_checks // [])|length) == (($s[0].project_checks // [])|length)),
      acceptance_criteria_equal: (($r[0].acceptance_criteria|length) == $n),
      commit_pending_scope_ok: (($not_met - ($pending|length)) == $ac_issues),
      commit_pending_shape_ok: (([$pending[]
        | select((.criterion // "") | test("\\bpush|\\btag|\\breleas|\\bdeploy|\\bpull request|\\bPR\\b"; "i"))] | length) == 0),
      cosmetic_shape_ok: ((([$s[0].issues[]? | select(has("cosmetic")) | select((.cosmetic | type) != "boolean")] | length) == 0)
        and (([$s[0].issues[]? | select(.cosmetic == true)
               | select(.severity != "minor" or .category == "security")] | length) == 0)),
      round_cap_ok: ((($round | numbers) // -1) as $r
        | (($prior_critical | numbers) // 0) as $pc
        | (($prior_security | numbers) // 0) as $ps
        | (($fix_code_paths | numbers) // -1) as $fc
        | (($critical_cleared | numbers) // 0) as $cc
        | ($r >= 0) and (($r <= 1)
            or (($r == 2) and (($pc > 0) or ($ps > 0) or ($fc != 0) or ($cc == 1)))
            or (($r >= 3) and (($pc > 0) or ($cc == 1))))),
      pin_terms: { not_met: $not_met, sentinel: ($pending|length), ac_issues: $ac_issues,
                   round: $round, prior_critical: $prior_critical,
                   prior_security: $prior_security, fix_code_paths: $fix_code_paths,
                   critical_cleared: $critical_cleared } }'
```

`dropped_sections` must be `[]` and **all six** booleans `true`. `pin_terms` is diagnostic, not a pass/fail value — it exists so a failure tells you *which* term broke. A failure means you trimmed the output: **fix the copy, never weaken the check.** For the acceptance-criteria mismatch specifically, **re-run the reviewer — never truncate or pad the array to force the count.**

`commit_pending_scope_ok` is the commit-pending carve-out's scope pin, and it runs here because this is the one self-check that already holds `$BLOCK` open before Step 7 deletes it — making the pin free rather than a new harness. The invariant: **every `"not_met"` criterion is either paired with an `acceptance_criteria` issue or carries the sentinel — never neither, never both.** **The sentinel count is pinned to a row that is BOTH `status: "not_met"` AND whose `evidence` starts with the sentinel** — the status filter matters, because a sentinel can only ever legally sit on a `not_met` row, and without the filter a stray sentinel on a `met` row would silently cancel a genuinely dropped pairing. A whole-file `grep` for the literal is likewise NOT this check and is inflated by the string appearing in criterion text, in `summary`, or in a `note`. On a review with no carve-out the sentinel count is `0` and the check reduces to the pairing rule that always held, so it costs a dispatch without `commit_pending` nothing.

**A green `commit_pending_scope_ok` confirms only that whatever carve-out was granted was applied consistently — never that it was correctly granted.** It catches a half-application, not mis-qualification; what it does and does not detect: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § What commit_pending_scope_ok Detects.

`commit_pending_shape_ok` is the one piece of mis-qualification that *is* mechanically checkable, and it covers the explicit never-list: a sentinel-bearing criterion whose text mentions pushing, tagging, releasing, deploying, or opening a pull request is refused outright. It is a keyword heuristic, not a proof — it cannot read leg (b) or leg (c) — but it converts the never-list from prose into a check.

**Every term is type-guarded so malformed input fails closed — keep each `(… | numbers) // <default>` coercion, the `$r >= 0` term and the shell `:-` defaults exactly as written** (`REVIEW_ROUND` and `FIX_CODE_PATHS` default to `-1`, the rest to `0`; `FIX_CODE_PATHS` is computed from git by you, never read from the block). Why each matters: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why Every round_cap_ok Term Is Type-Guarded.

**The Source B half applies the identical coercion**, including excluding booleans from the numeric types, and **the two halves must return the same verdict for the same inputs** — why: the same section of [orchestrator-rationale.md](../../docs/orchestrator-rationale.md).

`round_cap_ok` is the two-round cap's enforcement half. It reads `$REVIEW_ROUND`, `$PRIOR_CRITICAL` and `$PRIOR_SECURITY` computed above and `$FIX_CODE_PATHS` from the classifier, and deliberately reads the **previous** round's Critical count rather than the current block's. Why: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why round_cap_ok Reads the Previous Round. **The remedy for a failure here is never another round.** Be precise about which moment you are in, because "do not submit" and "record and submit" govern different ones and reading them as one rule leaves no green path. **At the cap** — round two, `round_cap_ok` still `true` — you record the remaining `important` and `minor` findings in `completion_notes` and one line of `completion_summary` — **severity, category and `file:line` only: never paste the block, its prose, or diff text, and redact as for any session text** — and you submit round two's result. **A `category: "security"` issue is never recordable at any severity**: `important` is the reviewer's documented default for a security finding, so recording one would ship an unfixed weakness. Fix it, or escalate `review_blocked`. That is the ordinary exit and the one the cap is designed to produce. **An untriggered round two** — `false` with `pin_terms.round` at `2` and no trigger term set — is not a cap breach and is not escalated: that round should not have run, so do not submit it, submit round one's `$MERGED` without re-running its check (the recount now reads `2`, so it would stay `false`), and record per the triggers paragraph — **including every finding that round raised**, by severity, category and `file:line`, since its result is not submitted; anything it raised at `critical` or `category: "security"` is still fixed or escalated, never dropped with its result. **Past the cap** — a third round was dispatched with no exemption, so this check is `false` — you may not submit that round's result, and the check will stay `false` on every later evaluation, so there is no waiting it out: record the residual findings and **escalate `review_blocked`** — unless `pin_terms.round` is `-1`, which is not a cap breach at all but the recount not having run: run it and re-check so a human sees that the loop over-ran, or, if the round genuinely existed to verify a Critical no prior round recorded, set `CRITICAL_CLEARED` and say so in `completion_notes`. A `critical` is fixed or escalated, never recorded.

**On failure, do not submit — and read `pin_terms` before choosing the remedy, because the three failing conditions need different ones.** If `sentinel` exceeds the carve-outs you actually intended, a criterion was wrongly granted: re-dispatch the reviewer with `<N>` incremented and the failure named. If `ac_issues` is short, a pairing was dropped: same remedy. If `commit_pending_shape_ok` is `false`, the carve-out reached the never-list: drop the `commit_pending` assertion and review normally. **And one case is neither**: if you asserted no `commit_pending` at all and `sentinel` is nonzero, the sentinel arrived as *data* — most often a reviewer correctly quoting a criterion whose own text embeds it. Neither remedy above applies; treat it as the evidence-collision case the sentinel rule below governs, and have the reviewer re-emit that `evidence` without leading with the literal.

Two limits, stated rather than papered over: this is **detection after the fact, not prevention**, and being count arithmetic it is satisfied by a wrong-but-balanced block. It is the strongest mechanical control available for a prose contract, not a proof — and per the paragraph above, it is not a control on qualification at all.

**Both lookups are total on purpose — `(.acceptance_criteria // [])` and `(.evidence // "")`** — so an absent key or a `null` evidence on any row yields an honest `false` rather than aborting the whole `jq -n`. Mirror the same two guards in the Python equivalent sanctioned below. Why an abort is worse: [orchestrator-rationale.md](../../docs/orchestrator-rationale.md) § Why the Scope-Pin Lookups Are Total.

**Never `cat`, `Read`, or otherwise print the WHOLE block file into your context.** Every jq invocation in this file either redirects to a file or prints only counts and booleans. Reading a bounded slice of it is sanctioned and expected — the fix-the-issues step in the orchestrator selects individual `issues[]` entries, which is the point of keeping the detail on disk rather than in the summary. Printing the block costs exactly the tokens this design exists to save, and re-exposes any diff content the block quotes. Where jq is unavailable, an equivalent Python `json.load` plus the same dict-merge shown below is acceptable — provided it writes to a file and prints only the self-check result.

## Source B pattern

The historical parse, plus the `$MERGED` write that makes Step 7 single-shape (D248). Extract the first ```json fence and parse it:

```python
import re, json
m = re.search(r'```json\n(.*?)\n```', reviewer_response, re.DOTALL)
structured = json.loads(m.group(1))  # the WHOLE parsed schema

# Whole-object copy — carry EVERY section through, then overlay the legacy
# fields. NEVER re-type or hand-pick keys; selecting a subset is exactly how
# project_checks got truncated (3 of 26 reached the server).
reviewer_result = dict(structured)
reviewer_result.update({
    "dispatched": True,
    "duration_ms": wall_clock_ms,
    "summary": structured["summary"],
    "issues_found": sum(structured["issue_counts"].values()),
    "acceptance_criteria_checked": len(structured["acceptance_criteria"]),
})

# MANDATORY self-check — run before EVERY /complete, NO EXCEPTIONS. A failure
# here means you trimmed the output: fix the copy, never weaken the check.
for section in structured:  # every section the reviewer produced must survive
    assert section in reviewer_result, f"dropped review section: {section}"
assert len(reviewer_result.get("project_checks", [])) == len(structured.get("project_checks", [])), \
    "project_checks count must equal what the reviewer emitted — never trim or sub-select"

# Acceptance-criteria 1:1 check — the reviewer's acceptance_criteria array length
# MUST equal the task's own criterion-line count. A mismatch means the reviewer
# split, merged, added, or dropped criteria (the W1099 6/5 defect). Re-run the
# reviewer with the canonical task criteria — NEVER truncate or pad the array to
# force the count to match.
task_criterion_lines = [c for c in (task["acceptance_criteria"] or "").split("\n") if c.strip()]
assert len(structured["acceptance_criteria"]) == len(task_criterion_lines), \
    "acceptance_criteria count must equal the task's criterion-line count — re-run the reviewer, do not truncate or pad"

# Commit-pending scope pin — the Source B half of the check Source A runs as
# `commit_pending_scope_ok`. Source B is reachable whenever the reviewer's block
# write fails and it emits the fence inline, so leaving it out would be a
# documented path around a control installed specifically to bound the carve-out.
# Invariant: every "not_met" criterion is EITHER paired with an
# acceptance_criteria issue OR carries the sentinel — never neither, never both.
# The .get()/or-"" guards mirror the // [] and // "" guards in the Source A jq:
# the block is reviewer-authored, and a null evidence on any row (even a "met"
# one) must yield an honest failure here, never a TypeError.
import re
_criteria = structured.get("acceptance_criteria") or []
_not_met = sum(1 for c in _criteria if c.get("status") == "not_met")
# The status filter mirrors the jq: a sentinel can only ever legally sit on a
# not_met row, and without the filter a stray sentinel on a met row silently
# cancels a genuinely dropped pairing.
_pending = [c for c in _criteria
            if c.get("status") == "not_met"
            and (c.get("evidence") or "").startswith("PENDING COMMIT — ")]
_paired = sum(1 for i in (structured.get("issues") or [])
              if i.get("category") == "acceptance_criteria")
assert _not_met - len(_pending) == _paired, (
    "commit-pending scope pin failed — do not submit. Terms: "
    f"not_met={_not_met} sentinel={len(_pending)} ac_issues={_paired}. "
    "Read the terms before choosing a remedy, per the Source A guidance above.")
# The never-list, mechanically: a carve-out never reaches a criterion about
# pushing, tagging, releasing, deploying, or opening a pull request.
_never = re.compile(r"\bpush|\btag|\breleas|\bdeploy|\bpull request|\bPR\b", re.I)
assert not [c for c in _pending if _never.search(c.get("criterion") or "")], \
    "commit-pending carve-out reached the never-list — drop the commit_pending assertion and review normally"

# Cosmetic shape pin -- the Source B half of `cosmetic_shape_ok`. A cosmetic
# flag may only ever sit on a minor, non-security finding, and must be a real
# boolean; anything else is a reviewer defect and never something to "fix" by
# editing the block. This refuses rather than coerces. Note it reaches the
# flag's TYPE and CO-ORDINATES only, never its truth -- see limit (3) above for
# the cheaper abuse it cannot see.
_issues = structured.get("issues") or []
assert not [i for i in _issues
            if "cosmetic" in i and not isinstance(i.get("cosmetic"), bool)], \
    "cosmetic must be a boolean when present -- re-run the reviewer, do not coerce it"
assert not [i for i in _issues
            if i.get("cosmetic") is True
            and (i.get("severity") != "minor" or i.get("category") == "security")], \
    "cosmetic is only ever valid on a minor, non-security finding -- do not submit"

# D248: write the merged object to the SAME absolute $MERGED path Source A uses
# (.stride/.reviewer-result-<IDENTIFIER>-r<N>.json under the resolved project
# root), so Step 7's `jq --slurpfile r "$MERGED"` splice works identically on
# both source paths — and reviewer_result never has to pass through your
# context to reach the payload. The deep-security and Step 5.5 escalations
# then mutate this file exactly as they do on Source A.
merged_path = "<the $MERGED path resolved as in the Source A pattern above>"
with open(merged_path, "w") as f:
    json.dump(reviewer_result, f)

# Round-cap pin — the Source B half of `round_cap_ok`. Source B is reachable
# whenever the reviewer's block write fails and it emits the fence inline, so
# leaving it out would be a documented path around the cap.
#
# THIS SITS BELOW THE $MERGED WRITE DELIBERATELY -- it is the one assert in this
# block that must, and moving it up would silently loosen the cap. The recount
# that produces review_round counts the parsing $MERGED files, so it has to see
# this round's; on this path the merge happens after the other asserts, so an
# assert placed with them reads N-1 where Source A reads N, making the effective
# cap three here and two there. Run the round-counter block at the top of this
# file now -- after the dump, before this assert -- and the fix-path classifier
# with FIX_STAGE=count, so review_round, prior_critical, prior_security,
# fix_code_paths and critical_cleared are the values Source A would have computed.
#
# The coercion mirrors the jq `(… | numbers) // default` exactly, bool included:
# Python's bool is a subclass of int, so an unguarded `prior_critical > 0` would
# pass on True where the jq half refuses, and the two halves must never disagree.
def _num(v, default):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else default

_r = _num(review_round, -1)
_pc = _num(prior_critical, 0)
_cc = _num(critical_cleared, 0)
_ps = _num(prior_security, 0)
_fc = _num(fix_code_paths, -1)
assert _r >= 0 and (_r <= 1 or (_r == 2 and (_pc > 0 or _ps > 0 or _fc != 0 or _cc == 1)) or (_r >= 3 and (_pc > 0 or _cc == 1))), (
    "review round cap exceeded — do not submit. Terms: "
    f"round={review_round!r} prior_critical={prior_critical!r} "
    f"prior_security={prior_security!r} fix_code_paths={fix_code_paths!r} "
    f"critical_cleared={critical_cleared!r}. "
    "An UNTRIGGERED round two (round=2, no trigger term) is not a breach: "
    "submit round one's merged result and record the fixed findings. "
    "At the cap the remedy is to RECORD the remaining important/minor findings "
    "in completion_notes and completion_summary (severity/category/file:line "
    "only, redacted) and submit round two's result; a category=security issue "
    "is never recordable at any severity -- fix or escalate it; "
    "PAST the cap, escalate review_blocked (or set CRITICAL_CLEARED if this "
    "round verified a critical no prior round recorded). Never run another "
    "round; a critical is fixed or escalated, never recorded.")


```

## Field mapping into `reviewer_result`

- Legacy fields (always populated):
  - `summary` ← `structured.summary`
  - `issues_found` ← `sum(structured.issue_counts.values())` (sum only the recognized severity keys you receive; pass through any unknown severity keys verbatim inside the structured `issue_counts` object)
  - `acceptance_criteria_checked` ← `len(structured.acceptance_criteria)`
  - `dispatched: true`, `duration_ms: <wall-clock ms>` (as before)
- Structured fields — **copy the reviewer's entire parsed JSON object verbatim** into `reviewer_result`, then overlay the legacy fields above on top. Do **not** maintain an allow-list of which structured keys to copy: whatever the agent emitted is persisted as-is, so any field the schema gains later flows through automatically (this is exactly how `project_checks` was being dropped — an enumerated copy-list silently omitted it). The structured key-set is owned by `stride/agents/task-reviewer.md`; passthrough it, never re-enumerate it here. Concretely, the reviewer currently emits `status`, `issue_counts`, `issues`, `acceptance_criteria`, `project_checks`, `testing_strategy`, `patterns`, `pitfalls`, `security_considerations`, and `schema_version` — but treat that as illustrative, not exhaustive. Because you copy the parsed JSON verbatim, keys the agent did not emit are simply absent (no empty placeholders to send). **Hand-typing, re-typing, or sub-selecting `reviewer_result` is FORBIDDEN — no exceptions, no small-task or brevity shortcut. The mechanical whole-object copy + mandatory self-check above is the only correct path; if the self-check fails, fix the copy, never the assertion.** On Source A the copy is a **byte-level splice from the block file**, which makes the passthrough literal rather than merely intended — and **re-typing a block you read out of that file is the same forbidden act** as hand-typing one out of a response.

**What the copy must produce.** The result is **every key of the parsed block, unchanged, plus exactly the five overlaid keys above** (`dispatched`, `duration_ms`, `summary`, `issues_found`, `acceptance_criteria_checked`) — never fewer keys than the reviewer emitted, never one renamed, dropped, or re-typed on the way. That set relation *is* the mechanic; if you can state which keys you chose to copy, you did it wrong. On Source A the jq merge above *is* that relation, expressed so it cannot be got wrong by hand; on Source B the dict-merge plus its closing `json.dump` produce the same file at the same path. Note that **`$MERGED` — not the block file — is what Step 7 submits, on both source paths**: the escalations the deep security-considerations review makes mutate the merged copy, leaving the block file as the reviewer's unmodified emission, which is what keeps the on-disk block byte-identical to what the reviewer wrote. A populated example of the resulting object lives in the `stride-completing-tasks` skill (`skills/stride-completing-tasks/SKILL.md`, "Explorer/Reviewer Result Schema" — Shape 1) — this file does not duplicate it. The reviewer's own emitted schema is owned by `stride/agents/task-reviewer.md`.

Legacy + structured fields coexist in the same map; the server persists `reviewer_result` as `:jsonb` and tolerates the structured keys today (G143/W688 will validate them explicitly).

## Source C — the prose fallback

**When no source yields a parsable block.** This fires only when **both** Source A and Source B have failed: no usable block file (absent, path mismatch, or `jq empty` failed) **and** no ```json block present or parsable in the response. It is also the path a newer reviewer paired with an older orchestrator lands on, and it must stay degraded-but-valid rather than a hard failure. Do not abort the completion. Instead:

1. Fall back to substring-matching the prose summary line ("Approved" or "N issues found (X critical, Y important, Z minor)") to populate `reviewer_result.summary` and `reviewer_result.issues_found` as before this rollout.
2. Set `acceptance_criteria_checked` from the count of criterion lines you find in the prose acceptance-criteria table, or to `0` if none can be parsed.
3. **Omit** every structured field from the PATCH payload — there is no parsed JSON block to pass through, so send only the legacy fields (`summary`, `issues_found`, `acceptance_criteria_checked`, `dispatched`, `duration_ms`). Do not send empty placeholders for `status`, `project_checks`, `issues`, `acceptance_criteria`, or any other structured key. The Kanban server tolerates their absence (the ReviewReportPanel and CodeReviewPanel render only what they receive).
4. Keep `dispatched: true` and `duration_ms` as captured. The fallback path produces a degraded-but-valid completion, never a hard failure.

**The self-check agrees with that guarantee — it does not override it.** The `stride-completing-tasks` hard gate's "No `not_assessed` for a task-supplied section" and "`behaviour_test_matrix` verdict present" checkboxes are **scoped to a payload where a structured block was actually parsed — from the block file (Source A) or an inline fence (Source B)**. This fallback payload has none by construction, so both checks are inapplicable rather than failed, and the completion proceeds. Do **not** try to satisfy them by hand-writing a verdict, back-filling a placeholder, or re-labelling this dispatched review as a self-reported skip — all three are forbidden, and none is needed. The remaining checks still bind on what this payload does carry. The round cap is scoped the same way and for the same structural reason: this fallback wrote no `$MERGED`, so the dispatch counted as no round and `round_cap_ok` is inapplicable rather than failed — which is also the first of the two stated limits above, not a way around the cap. The same scoping is what lets a **Shape 2 self-reported skip** — a small task with 0-1 `key_files` that the Step 3 decision matrix legitimately excused from review — complete without a verdict it was never supposed to produce; re-running the reviewer is not the remedy in either case, since here it already ran and there the matrix says it should not.
