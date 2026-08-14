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

**MANDATORY self-check for Source A** — prints three values and no payload:

```bash
jq -n --slurpfile s "$BLOCK" --slurpfile r "$MERGED" --argjson n "$TASK_CRITERION_LINES" '
  { dropped_sections: (($s[0]|keys) - ($r[0]|keys)),
    project_checks_equal: ((($r[0].project_checks // [])|length) == (($s[0].project_checks // [])|length)),
    acceptance_criteria_equal: (($r[0].acceptance_criteria|length) == $n) }'
```

`dropped_sections` must be `[]` and both booleans `true`. A failure means you trimmed the output: **fix the copy, never weaken the check.** For the acceptance-criteria mismatch specifically, **re-run the reviewer — never truncate or pad the array to force the count.**

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
