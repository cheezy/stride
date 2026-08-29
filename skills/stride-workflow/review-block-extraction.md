# Review Block Extraction Reference

Read this at Step 5, after the task-reviewer has returned (or when an older reviewer emitted its block inline), while building `reviewer_result`. The dispatch procedure, the three-source order, and the always-read-from-the-paths-YOU-supplied rule stay in the orchestrator skill; everything below is the mechanics that run once you hold `$BLOCK` and `$REPORT`.

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

`$s[0] + {…}` **is** the whole-object copy: jq's object merge makes "copy everything, overlay exactly five keys" mechanical rather than remembered, which is the strongest available reading of the set relation stated below. The `issue_counts` sum is spelled out per severity deliberately — `[.issue_counts[]] | add` would also sum unrecognized severity keys and contradict the mapping rule below.

**MANDATORY self-check for Source A** — prints six values and no payload:

```bash
jq -n --slurpfile s "$BLOCK" --slurpfile r "$MERGED" --argjson n "$TASK_CRITERION_LINES" '
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
      pin_terms: { not_met: $not_met, sentinel: ($pending|length), ac_issues: $ac_issues } }'
```

`dropped_sections` must be `[]` and **all four** booleans `true`. `pin_terms` is diagnostic, not a pass/fail value — it exists so a failure tells you *which* term broke. A failure means you trimmed the output: **fix the copy, never weaken the check.** For the acceptance-criteria mismatch specifically, **re-run the reviewer — never truncate or pad the array to force the count.**

`commit_pending_scope_ok` is the commit-pending carve-out's scope pin, and it runs here because this is the one self-check that already holds `$BLOCK` open before Step 7 deletes it — making the pin free rather than a new harness. The invariant: **every `"not_met"` criterion is either paired with an `acceptance_criteria` issue or carries the sentinel — never neither, never both.** **The sentinel count is pinned to a row that is BOTH `status: "not_met"` AND whose `evidence` starts with the sentinel** — the status filter matters, because a sentinel can only ever legally sit on a `not_met` row, and without the filter a stray sentinel on a `met` row would silently cancel a genuinely dropped pairing. A whole-file `grep` for the literal is likewise NOT this check and is inflated by the string appearing in criterion text, in `summary`, or in a `note`. On a review with no carve-out the sentinel count is `0` and the check reduces to the pairing rule that always held, so it costs a dispatch without `commit_pending` nothing.

**Be exact about what this detects, because it is narrower than it looks.** It catches a **half-application** — a sentinel written without the matching suppression, or a suppression without the sentinel. It also stops a stray sentinel on a `met` row from cancelling a genuinely dropped pairing, though **it does not by itself report that stray sentinel**: the status filter removes such a row from every term, so a block whose *only* defect is a misplaced sentinel passes. **It does NOT catch mis-qualification.** A reviewer that wrongly decides a criterion qualifies and then applies the carve-out's *complete* documented shape moves the sentinel count up and the paired-issue count down by the same amount, so the equality still holds and the pin still returns `true`. That is one judgement error, not the two compensating errors the "wrong-but-balanced" caveat below describes, and it is the failure mode the three-part AND — not this pin — exists to prevent. **Do not read a green pin as confirmation that the carve-out was correctly granted; it confirms only that whatever was granted was applied consistently.**

`commit_pending_shape_ok` is the one piece of mis-qualification that *is* mechanically checkable, and it covers the explicit never-list: a sentinel-bearing criterion whose text mentions pushing, tagging, releasing, deploying, or opening a pull request is refused outright. It is a keyword heuristic, not a proof — it cannot read leg (b) or leg (c) — but it converts the never-list from prose into a check.

**On failure, do not submit — and read `pin_terms` before choosing the remedy, because the three failing conditions need different ones.** If `sentinel` exceeds the carve-outs you actually intended, a criterion was wrongly granted: re-dispatch the reviewer with `<N>` incremented and the failure named. If `ac_issues` is short, a pairing was dropped: same remedy. If `commit_pending_shape_ok` is `false`, the carve-out reached the never-list: drop the `commit_pending` assertion and review normally. **And one case is neither**: if you asserted no `commit_pending` at all and `sentinel` is nonzero, the sentinel arrived as *data* — most often a reviewer correctly quoting a criterion whose own text embeds it. Neither remedy above applies; treat it as the evidence-collision case the sentinel rule below governs, and have the reviewer re-emit that `evidence` without leading with the literal.

Two limits, stated rather than papered over: this is **detection after the fact, not prevention**, and being count arithmetic it is satisfied by a wrong-but-balanced block. It is the strongest mechanical control available for a prose contract, not a proof — and per the paragraph above, it is not a control on qualification at all.

**Both lookups are total on purpose — `(.acceptance_criteria // [])` and `(.evidence // "")`.** The block is reviewer-authored JSON, and all four values are computed in one `jq -n`, so an unguarded `.acceptance_criteria[]` on an absent key (`Cannot iterate over null`) or an unguarded `.evidence` that is `null` on **any** row — including an unrelated `"met"` one — would abort the whole invocation and take `dropped_sections`, `project_checks_equal` and `acceptance_criteria_equal` down with it. That would make a previously-working check fail on blocks it used to handle, which is a worse outcome than the one this pin prevents. The guards convert those inputs into an honest `false` instead, which is the failure vocabulary this check actually documents. Mirror the same two guards in the Python equivalent sanctioned below.

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

# D248: write the merged object to the SAME absolute $MERGED path Source A uses
# (.stride/.reviewer-result-<IDENTIFIER>-r<N>.json under the resolved project
# root), so Step 7's `jq --slurpfile r "$MERGED"` splice works identically on
# both source paths — and reviewer_result never has to pass through your
# context to reach the payload. The deep-security and Step 5.5 escalations
# then mutate this file exactly as they do on Source A.
merged_path = "<the $MERGED path resolved as in the Source A pattern above>"
with open(merged_path, "w") as f:
    json.dump(reviewer_result, f)
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

**The self-check agrees with that guarantee — it does not override it.** The `stride-completing-tasks` hard gate's "No `not_assessed` for a task-supplied section" and "`behaviour_test_matrix` verdict present" checkboxes are **scoped to a payload where a structured block was actually parsed — from the block file (Source A) or an inline fence (Source B)**. This fallback payload has none by construction, so both checks are inapplicable rather than failed, and the completion proceeds. Do **not** try to satisfy them by hand-writing a verdict, back-filling a placeholder, or re-labelling this dispatched review as a self-reported skip — all three are forbidden, and none is needed. The remaining checks still bind on what this payload does carry. The same scoping is what lets a **Shape 2 self-reported skip** — a small task with 0-1 `key_files` that the Step 3 decision matrix legitimately excused from review — complete without a verdict it was never supposed to produce; re-running the reviewer is not the remedy in either case, since here it already ran and there the matrix says it should not.
