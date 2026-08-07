# Per-task token baseline (pre-restructuring)

**Status:** Captured. Baseline task **W2045** (goal **G404**, "Cut the Stride
plugin's per-task context footprint via progressive disclosure").
**Plugin version measured:** **1.61.0** — subrepo HEAD `6893a8b`.
**Purpose:** Every later task in G404 claims a token saving. This document is the
before-measurement those claims are checked against. Re-run the method in
[Method](#method) after the changes and compare against
[Results](#results-1610-baseline).

## What was measured

One representative Stride task run, end to end: **D214** — *"Opacity-on-text
usages predating D213's rule remain untracked, including one that dims a
contrast-gated status pair."*

D214 was chosen because it exercises the full workflow rather than a fast path:
2 × `stride:task-explorer` dispatches, 17 `Edit` + 2 `Write` calls during
implementation, and 2 × `stride:task-reviewer` dispatches (an initial review plus
a re-review after fixes). A task that skipped explore or review would understate
the footprint the goal is trying to cut.

**Source:** session transcript
`~/.claude/projects/-Users-cheezy-dev-elixir-kanban/17e3d00a-70b2-45e0-a8ad-112690546d1f.jsonl`,
records 481–673 (the `POST /api/tasks/claim` record through the
`PATCH /api/tasks/:id/complete` record), plus the four subagent transcripts that
run dispatched.

Two neighbouring runs from the same session — **D212** (records 66–234) and
**D213** (records 265–435) — are recorded alongside it, because the
position-in-session effect below is only visible with more than one data point.

## Results (1.61.0 baseline)

### Token totals

All figures are read from the `message.usage` object on each transcript record.
They are **not** derived from byte sizes.

**D214 — the representative run**

| Context | Requests | `input_tokens` | `cache_creation_input_tokens` | `cache_read_input_tokens` | `output_tokens` | Total input |
|---|---:|---:|---:|---:|---:|---:|
| Main loop | 45 | 83 | 96,246 | 17,269,621 | 49,783 | 17,365,950 |
| `task-explorer` #1 | 7 | 316 | 74,728 | 360,138 | 24 | 435,182 |
| `task-explorer` #2 | 13 | 1,039 | 127,951 | 1,248,065 | 49 | 1,377,055 |
| `task-reviewer` #1 | 10 | 19 | 97,998 | 742,219 | 38 | 840,236 |
| `task-reviewer` #2 | 10 | 19 | 71,190 | 795,879 | 32 | 867,088 |
| **TASK TOTAL** | **85** | **1,476** | **468,113** | **20,415,922** | **49,926** | **20,885,511** |

Total input + output for D214: **20,935,437 tokens**.

**All three runs in the session**

| Task | Position in session | Subagents | Requests | Cache creation | Cache read | Output | Total input |
|---|---|---:|---:|---:|---:|---:|---:|
| D212 | 1st | 1 | 42 | 194,626 | 5,918,196 | 38,262 | 6,112,900 |
| D213 | 2nd | 4 | 70 | 444,579 | 12,395,732 | 46,873 | 12,840,442 |
| D214 | 3rd | 4 | 85 | 468,113 | 20,415,922 | 49,926 | 20,885,511 |

**Cache read dominates, and it compounds with position in the session.** The main
loop re-sends the whole conversation on every request, so the resident skill
bodies are paid for once per request, not once per task — 45 times over for D214.
This is the effect G404 exists to reduce.

**Compare like with like.** A post-change run must be compared against a run at
the *same position in its session* — D214 against a 3rd run, D212 against a 1st.
Comparing a fresh 1st run to this 3rd run would show a "saving" that is entirely
the position effect. The most robust single comparison is **main-loop
`cache_creation_input_tokens`**, which tracks what newly entered the context
rather than how long the conversation already was.

### Byte sizes loaded during that run

Verified: the installed plugin cache
`~/.claude/plugins/cache/stride-marketplace/stride/1.61.0/` is byte-identical to
the `stride/` subrepo working tree at HEAD (`diff -r -q` over `skills/` and
`agents/` reports no differences), so the repo sizes below are exactly the bytes
that loaded.

Reproduce with, from the kanban repo root:

```bash
wc -c stride/skills/*/SKILL.md stride/agents/*.md
```

| File | Total | Frontmatter | Body |
|---|---:|---:|---:|
| `skills/stride-claiming-tasks/SKILL.md` | 28,981 | 348 | 28,633 |
| `skills/stride-completing-tasks/SKILL.md` | 93,911 | 417 | 93,494 |
| `skills/stride-creating-goals/SKILL.md` | 23,339 | 342 | 22,997 |
| `skills/stride-creating-tasks/SKILL.md` | 32,810 | 396 | 32,414 |
| `skills/stride-enriching-tasks/SKILL.md` | 26,873 | 362 | 26,511 |
| `skills/stride-subagent-workflow/SKILL.md` | 67,693 | 420 | 67,273 |
| `skills/stride-workflow/SKILL.md` | 139,972 | 763 | 139,209 |
| `agents/hook-diagnostician.md` | 17,610 | 1,334 | 16,276 |
| `agents/task-decomposer.md` | 25,521 | 1,175 | 24,346 |
| `agents/task-enricher.md` | 37,338 | 1,805 | 35,533 |
| `agents/task-explorer.md` | 5,011 | 1,381 | 3,630 |
| `agents/task-reviewer.md` | 54,809 | 1,548 | 53,261 |
| **TOTAL** | **553,868** | **10,291** | **543,577** |

Existing `stride-workflow` reference files, already loaded on demand rather than
resident — the precedent G404 extends:

| File | Bytes |
|---|---:|
| `skills/stride-workflow/hook-execution.md` | 21,496 |
| `skills/stride-workflow/parser.md` | 5,302 |
| `skills/stride-workflow/pretooluse-command-rewrite-spike.md` | 6,596 |

**Which of those bodies were actually resident during D214.** Skill bodies load
on `Skill` invocation and stay in context for the rest of the session. In this
session the plugin skills invoked were:

| Body | Loaded at record | Context | Bytes |
|---|---|---|---:|
| `skills/stride-workflow/SKILL.md` | 15 (before D212) | main loop | 139,972 |
| `skills/stride-completing-tasks/SKILL.md` | 213 (during D212) | main loop | 93,911 |
| `agents/task-explorer.md` | per dispatch | subagent | 5,011 |
| `agents/task-reviewer.md` | per dispatch | subagent | 54,809 |

Main-loop resident plugin body bytes during D214: **233,883**. The other seven
bodies did not load in this session; their frontmatter descriptions were resident
throughout, which is the **10,291-byte** always-resident surface G404's pitfalls
place off limits.

## Method

Reproduce identically as follows.

### 1. Pick the run and find its record range

The transcript is one JSON object per line. Boundaries are the records issuing
the claim and completion curls:

```bash
python3 - <<'PY'
import json
P = "<session>.jsonl"
for i, line in enumerate(open(P, errors="replace")):
    try: r = json.loads(line)
    except Exception: continue
    if r.get("type") != "assistant": continue
    s = json.dumps(r)
    if "/api/tasks/claim" in s: print(i, "CLAIM")
    if "api/tasks" in s and "/complete" in s: print(i, "COMPLETE")
PY
```

Use the claim record as `claim_line` and the completion record as
`complete_line`. Both bounds are **0-indexed and inclusive**.

### 2. Confirm the session was not compacted

A compacted session splits usage across context windows and the range above stops
being one continuous conversation. Check before trusting the numbers:

```bash
python3 -c "
import json,sys
P=sys.argv[1]
hits=[i for i,l in enumerate(open(P,errors='replace')) if '\"isCompactSummary\":true' in l]
print('compaction records:', hits or 'none')
" <session>.jsonl
```

The baseline session (`17e3d00a…`) reports **none**. If a candidate session
reports any, either pick a different run or measure each window separately and
say so — do not sum across a compaction boundary and present it as one figure.

### 3. Sum the usage records

Save as `baseline.py` and run
`python3 baseline.py <session>.jsonl <claim_line> <complete_line> <label>`.

```python
#!/usr/bin/env python3
"""Measure the token cost of one Stride task run from Claude Code transcripts."""
import json, os, sys, glob, collections

session, claim_line, complete_line = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
label = sys.argv[4] if len(sys.argv) > 4 else os.path.basename(session)

KEYS = ("input_tokens", "cache_creation_input_tokens",
        "cache_read_input_tokens", "output_tokens")


def sum_usage(path, lo=None, hi=None):
    """Sum usage over assistant records, de-duplicated by message id."""
    tot, seen, n = collections.Counter(), set(), 0
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            if lo is not None and (i < lo or i > hi):
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("type") != "assistant":
                continue
            msg = r.get("message") or {}
            u = msg.get("usage")
            if not u or msg.get("id") in seen:
                continue
            seen.add(msg.get("id"))
            n += 1
            for k in KEYS:
                tot[k] += u.get(k, 0)
    return tot, n


def agent_tool_use_ids(path, lo, hi):
    ids = []
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            if i < lo or i > hi:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            for c in ((r.get("message") or {}).get("content") or []):
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Agent":
                    ids.append(c.get("id"))
    return ids


def report(name, tot, n):
    total_in = tot["input_tokens"] + tot["cache_creation_input_tokens"] + tot["cache_read_input_tokens"]
    print(f"  {name:<24} req={n:<4} in={tot['input_tokens']:>8,}  "
          f"cache_creation={tot['cache_creation_input_tokens']:>9,}  "
          f"cache_read={tot['cache_read_input_tokens']:>12,}  "
          f"out={tot['output_tokens']:>8,}  TOTAL_IN={total_in:>12,}")
    return total_in


sub_dir = os.path.join(os.path.dirname(session),
                       os.path.basename(session)[:-6], "subagents")
by_tool_use = {}
for meta in glob.glob(os.path.join(sub_dir, "*.meta.json")):
    m = json.load(open(meta))
    by_tool_use[m.get("toolUseId")] = (meta[:-len(".meta.json")] + ".jsonl",
                                       m.get("agentType"), m.get("description"))

print(f"=== {label}  (lines {claim_line}-{complete_line}) ===")
main, main_n = sum_usage(session, claim_line, complete_line)
report("main loop", main, main_n)

grand, grand_n = collections.Counter(main), main_n
for tid in agent_tool_use_ids(session, claim_line, complete_line):
    if tid not in by_tool_use:
        print(f"  !! no subagent transcript for {tid}")
        continue
    p, atype, desc = by_tool_use[tid]
    t, n = sum_usage(p)
    report(f"  {atype}", t, n)
    grand.update(t)
    grand_n += n

print("  " + "-" * 110)
total = report("TASK TOTAL", grand, grand_n)
print(f"  billable input+output = {total + grand['output_tokens']:,}")
```

The exact invocations that produced [Results](#results-1610-baseline):

```bash
T=~/.claude/projects/-Users-cheezy-dev-elixir-kanban/17e3d00a-70b2-45e0-a8ad-112690546d1f.jsonl
python3 baseline.py $T  66 234 D212
python3 baseline.py $T 265 435 D213
python3 baseline.py $T 481 673 D214
```

### 4. Capture the byte sizes

```bash
wc -c stride/skills/*/SKILL.md stride/agents/*.md          # totals
```

For the frontmatter/body split, and to confirm the installed cache matches the
repo:

```bash
python3 -c "
import glob
for p in sorted(glob.glob('stride/skills/*/SKILL.md')) + sorted(glob.glob('stride/agents/*.md')):
    raw = open(p,'rb').read()
    end = raw.index(b'\n---\n', 3) + 5
    print(f'{p:<52}{len(raw):>9,}{end:>9,}{len(raw)-end:>9,}')
"
diff -r -q ~/.claude/plugins/cache/stride-marketplace/stride/<version>/skills stride/skills
diff -r -q ~/.claude/plugins/cache/stride-marketplace/stride/<version>/agents stride/agents
```

## Counting rules that make the numbers reproducible

These are the decisions that would otherwise silently change the totals:

- **One record, one API response.** Only `type == "assistant"` records carry
  `message.usage`. Records are de-duplicated by `message.id`, so a streamed
  response is counted once, not once per chunk.
- **The four counters are disjoint — never double-count.** `input_tokens` counts
  **only uncached** input; cached input appears solely in
  `cache_read_input_tokens` and `cache_creation_input_tokens`. Total input is the
  sum of all three. Adding a separately-computed "total input" on top of these,
  or treating `input_tokens` as the whole prompt, inflates the figure.
- **`usage.cache_creation` (the object) is ignored.** Only the scalar
  `cache_creation_input_tokens` is summed; the object is a per-TTL breakdown of
  the same tokens.
- **Subagents are attributed by `toolUseId`.** Each `subagents/agent-*.meta.json`
  carries the `toolUseId` of the `Agent` tool_use that spawned it; a subagent
  counts toward a task only when that id appears inside the task's record range.
  Subagent transcripts are summed in full — they begin and end within their
  dispatch.
- **Bounds are inclusive and 0-indexed**, and both the claim and completion
  records are inside the range.
- **Byte sizes are measured, never estimated**, with `wc -c` at a known plugin
  version — and token counts are never inferred from them.

## Handling note

Session transcripts contain full conversation text, including anything that
appeared in tool output. **Quote only aggregate token counts into this document —
never transcript excerpts.** Every figure above is an aggregate produced by the
script; no transcript content is reproduced here, and a re-run should keep it
that way.
