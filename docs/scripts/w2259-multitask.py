#!/usr/bin/env python3
"""W2259: per-task measurement of a multi-task session, inline or dispatcher.

Why this exists rather than `w2067-recursive.py`: that script measures token
cost only, refuses any window a compaction falls inside, and its compaction
test matches the string "compact_boundary" anywhere in a record — so a
subagent that merely *mentions* compaction trips it. W2259 needs five metrics
per task — main-loop context per request, subagent tokens, wall clock,
reviewer dispatches and Stop-gate blocks — and needs them across a window that
may contain a compaction, reported per compaction window rather than refused.

Counting rules (token-baseline.md § Counting rules, restated where they bite):

  * A request is one assistant `message.id`. Claude Code writes one record per
    content block, all carrying the same usage, so counting records roughly
    doubles the request count — the 2026-10-02 review's first error. Every
    usage figure here is deduplicated by message id.
  * Main-loop context per request = input_tokens + cache_creation_input_tokens
    + cache_read_input_tokens of that request: what the model was sent.
  * Subagents are resolved by `toolUseId` from `subagents/agent-*.meta.json`
    and walked recursively through `parentAgentId`, so a task-runner's own
    explorer, planner and reviewers are attributed to its task.
  * A compaction is a record with `isCompactSummary: true` or a `system`
    record with `subtype == "compact_boundary"` — structure, never text.
  * A Stop-gate block is a `system` / `stop_hook_summary` record with a
    non-empty `hookErrors`. It is cross-checked against the
    `hook_blocking_error` attachments for the Stop event; their text is never
    printed (transcripts can carry secrets — aggregates only).

Task windows:

  * inline task: starts at its first claim curl; wall clock runs to its first
    complete curl after that.
  * dispatched task: starts at the `stride:task-runner` Agent call; wall clock
    runs to the arrival of the runner's record (its SubagentHandback message).
  * Every task's *main-loop* window runs from its start to the next task's
    start (or the end of --lines), so between-task turns are attributed to the
    task that precedes them, on both sides of any comparison.

Usage:
  python3 w2259-multitask.py --self-test
  python3 w2259-multitask.py --session <id> [--lines LO:HI] [--json]
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

PROJECT = os.path.expanduser("~/.claude/projects/-Users-cheezy-dev-elixir-kanban")

CLAIM_RE = re.compile(r'/api/tasks/claim')
CLAIM_ID_RE = re.compile(r'"identifier\\?"\s*:\s*\\?"([WDG][0-9]+)')
COMPLETE_RE = re.compile(r'-X\s+PATCH\s+\S*/api/tasks/\S+/complete')
HANDBACK_RE = re.compile(r'agent-message from=\\?"(a[0-9a-f]+)')


def parse_ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def context_of(usage):
    return (usage.get("input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0))


def dedupe_usage(records, main_only=True):
    """Collapse content-block records to one entry per message id.

    Returns (requests, raw_records): `requests` is a list of
    (line, timestamp, usage) in first-seen order, one per message id;
    `raw_records` is how many usage-bearing assistant records there were.
    A usage record with no message id cannot be deduplicated and is skipped.

    The line and timestamp are the first record's, but the usage is the LAST
    record's: input-side fields are identical across a message's records, while
    output_tokens on an early content-block record is a streaming partial.
    """
    seen = {}
    order = []
    raw = 0
    for line, record in records:
        if record.get("type") != "assistant":
            continue
        if main_only and record.get("isSidechain"):
            continue
        message = record.get("message") or {}
        usage = message.get("usage")
        message_id = message.get("id")
        if not usage or not message_id:
            continue
        raw += 1
        if message_id not in seen:
            order.append(message_id)
            seen[message_id] = (line, record.get("timestamp"), usage)
        else:
            first_line, first_ts, _ = seen[message_id]
            seen[message_id] = (first_line, first_ts, usage)
    return [seen[m] for m in order], raw


def is_compaction(record):
    if record.get("isCompactSummary") is True:
        return True
    return record.get("type") == "system" and record.get("subtype") == "compact_boundary"


def is_stop_block(record):
    return (record.get("type") == "system"
            and record.get("subtype") == "stop_hook_summary"
            and bool(record.get("hookErrors")))


def is_stop_attachment(record):
    attachment = record.get("attachment")
    return (isinstance(attachment, dict)
            and attachment.get("type") == "hook_blocking_error"
            and attachment.get("hookEvent") == "Stop")


def tool_uses(record):
    if record.get("type") != "assistant" or record.get("isSidechain"):
        return []
    content = (record.get("message") or {}).get("content") or []
    return [c for c in content if isinstance(c, dict) and c.get("type") == "tool_use"]


def load_lines(path, lo, hi):
    out = []
    with open(path) as handle:
        for line, raw in enumerate(handle):
            if line < lo:
                continue
            if line > hi:
                break
            out.append((line, json.loads(raw)))
    return out


def load_meta(session):
    meta = {}
    for path in glob.glob(os.path.join(PROJECT, session, "subagents", "agent-*.meta.json")):
        agent_id = os.path.basename(path)[len("agent-"):-len(".meta.json")]
        with open(path) as handle:
            entry = json.load(handle)
        entry["agentId"] = agent_id
        meta[agent_id] = entry
    return meta


def discover_tasks(records, meta):
    """Return task starts in transcript order: dicts with mode/id/start/end."""
    by_tool_use = {m["toolUseId"]: m["agentId"] for m in meta.values() if m.get("toolUseId")}
    tasks = []
    claimed = set()
    for line, record in records:
        for use in tool_uses(record):
            name = use.get("name")
            inp = use.get("input") or {}
            if name == "Agent" and inp.get("subagent_type") == "stride:task-runner":
                prompt = inp.get("prompt", "")
                found = re.search(r'"task_identifier"\s*:\s*"([WD][0-9]+)"', prompt)
                tasks.append({"mode": "runner", "id": found.group(1) if found else "?",
                              "start": line, "start_ts": record["timestamp"],
                              "agent": by_tool_use.get(use.get("id"))})
            if name == "Bash":
                command = inp.get("command", "")
                if CLAIM_RE.search(command) and "curl" in command:
                    found = CLAIM_ID_RE.search(command)
                    if found and found.group(1) not in claimed:
                        claimed.add(found.group(1))
                        tasks.append({"mode": "inline", "id": found.group(1),
                                      "start": line, "start_ts": record["timestamp"]})
    return tasks


def task_end(task, records, window_hi):
    """Line and timestamp the task's wall clock ends at, or (None, None)."""
    for line, record in records:
        if line <= task["start"] or line > window_hi:
            continue
        if task["mode"] == "inline":
            if any(u.get("name") == "Bash" and COMPLETE_RE.search((u.get("input") or {}).get("command", ""))
                   for u in tool_uses(record)):
                return line, record["timestamp"]
        elif record.get("type") == "user" and task.get("agent"):
            found = HANDBACK_RE.search(json.dumps((record.get("message") or {}).get("content")))
            if found and found.group(1) == task["agent"]:
                return line, record["timestamp"]
    return None, None


def subtree(session, roots, meta):
    """Recursively attribute subagents under `roots`; dedupe each transcript."""
    children = {}
    for entry in meta.values():
        children.setdefault(entry.get("parentAgentId"), []).append(entry["agentId"])
    queue = list(roots)
    agents = []
    while queue:
        agent_id = queue.pop(0)
        agents.append(agent_id)
        queue.extend(children.get(agent_id, []))
    totals = {"requests": 0, "context": 0, "output": 0, "cache_creation": 0, "compactions": 0}
    by_type = {}
    for agent_id in agents:
        path = os.path.join(PROJECT, session, "subagents", f"agent-{agent_id}.jsonl")
        if not os.path.exists(path):
            sys.exit(f"MISSING subagent transcript for {agent_id}")
        records = load_lines(path, 0, 10**12)
        totals["compactions"] += sum(1 for _, r in records if is_compaction(r))
        requests, _ = dedupe_usage(records, main_only=False)
        totals["requests"] += len(requests)
        for _, _, usage in requests:
            totals["context"] += context_of(usage)
            totals["output"] += usage.get("output_tokens", 0)
            totals["cache_creation"] += usage.get("cache_creation_input_tokens", 0)
        agent_type = meta[agent_id].get("agentType", "?")
        by_type[agent_type] = by_type.get(agent_type, 0) + 1
    return totals, by_type


def measure(session, lo, hi):
    path = os.path.join(PROJECT, f"{session}.jsonl")
    records = load_lines(path, lo, hi)
    meta = load_meta(session)
    by_tool_use = {m["toolUseId"]: m["agentId"] for m in meta.values() if m.get("toolUseId")}
    tasks = discover_tasks(records, meta)
    last_line = records[-1][0] if records else hi
    compactions = [line for line, record in records if is_compaction(record)]
    rows = []
    for position, task in enumerate(tasks, start=1):
        window_hi = tasks[position]["start"] - 1 if position < len(tasks) else last_line
        window = [(ln, r) for ln, r in records if task["start"] <= ln <= window_hi]
        requests, raw = dedupe_usage(window)
        series = [context_of(u) for _, _, u in requests]
        end_line, end_ts = task_end(task, records, window_hi)
        roots = []
        for _, record in window:
            for use in tool_uses(record):
                if use.get("name") == "Agent" and use.get("id") in by_tool_use:
                    roots.append(by_tool_use[use["id"]])
        sub, by_type = subtree(session, roots, meta)
        stops = sum(1 for _, r in window if is_stop_block(r))
        stop_attachments = sum(1 for _, r in window if is_stop_attachment(r))
        crossing = [c for c in compactions if task["start"] <= c <= window_hi]
        rows.append({
            "position": position, "id": task["id"], "mode": task["mode"],
            "lines": [task["start"], window_hi],
            "main_requests": len(requests), "main_raw_records": raw,
            "ctx_first": series[0] if series else 0, "ctx_last": series[-1] if series else 0,
            "ctx_max": max(series) if series else 0,
            "ctx_mean": sum(series) // len(series) if series else 0,
            "ctx_sum": sum(series),
            "ctx_growth": (series[-1] - series[0]) if series else 0,
            # entered share: of everything this task's work sent to a model
            # (main-loop window + its subagent tree), the part the main loop
            # carried. Produced = entered + subagent context.
            "entered_share_pct": (round(100 * sum(series) / (sum(series) + sub["context"]), 1)
                                  if series or sub["context"] else None),
            "wall_min": (round((parse_ts(end_ts) - parse_ts(task["start_ts"])).total_seconds() / 60, 1)
                         if end_ts else None),
            "complete": end_line is not None,
            "sub_requests": sub["requests"], "sub_context": sub["context"],
            "sub_output": sub["output"], "sub_cache_creation": sub["cache_creation"],
            "sub_compactions": sub["compactions"],
            "dispatches": by_type,
            "reviewers": by_type.get("stride:task-reviewer", 0),
            "stop_blocks": stops, "stop_attachments": stop_attachments,
            "compactions_in_window": crossing,
        })
    all_requests, all_raw = dedupe_usage(records)
    series = [context_of(u) for _, _, u in all_requests]
    summary = {
        "session": session, "lines": [lo, last_line],
        "main_requests": len(all_requests), "main_raw_records": all_raw,
        "ctx_first": series[0] if series else 0, "ctx_max": max(series) if series else 0,
        "ctx_sum": sum(series),
        "compactions": compactions,
        "stop_blocks": sum(1 for _, r in records if is_stop_block(r)),
        "stop_attachments": sum(1 for _, r in records if is_stop_attachment(r)),
    }
    return summary, rows


def print_report(summary, rows):
    s = summary
    print(f"session {s['session']} lines {s['lines'][0]}..{s['lines'][1]}")
    print(f"  main-loop requests {s['main_requests']} (from {s['main_raw_records']} usage records)"
          f"  context first {s['ctx_first']:,} max {s['ctx_max']:,} sum {s['ctx_sum']:,}")
    print(f"  compactions at lines {s['compactions'] or 'none'}"
          f"  stop-gate blocks {s['stop_blocks']} (attachments {s['stop_attachments']})")
    for r in rows:
        flag = "" if r["complete"] else "  INCOMPLETE"
        comp = f"  CROSSES COMPACTION {r['compactions_in_window']}" if r["compactions_in_window"] else ""
        print(f"  pos {r['position']} {r['id']} [{r['mode']}] lines {r['lines'][0]}..{r['lines'][1]}{flag}{comp}")
        print(f"    main: {r['main_requests']} req, context {r['ctx_first']:,} -> {r['ctx_last']:,}"
              f" (growth {r['ctx_growth']:,}, max {r['ctx_max']:,}, mean {r['ctx_mean']:,},"
              f" sum {r['ctx_sum']:,})")
        print(f"    subagents: {sum(r['dispatches'].values())} dispatches, {r['sub_requests']} req,"
              f" context {r['sub_context']:,}, output {r['sub_output']:,},"
              f" cache_creation {r['sub_cache_creation']:,}, compactions {r['sub_compactions']}")
        print(f"    entered share {r['entered_share_pct']}%")
        print(f"    wall {r['wall_min']} min  reviewers {r['reviewers']}  stop blocks {r['stop_blocks']}"
              f"  by type {json.dumps(r['dispatches'], sort_keys=True)}")


def self_test():
    def assistant(message_id, usage, sidechain=False):
        return {"type": "assistant", "isSidechain": sidechain,
                "message": {"id": message_id, "usage": usage, "content": []}}
    usage = {"input_tokens": 1, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 100,
             "output_tokens": 5}
    records = list(enumerate([
        assistant("m1", usage), assistant("m1", usage),     # two content blocks, one request
        assistant("m2", usage),
        assistant(None, usage),                             # no id: not countable
        assistant("s1", usage, sidechain=True),             # sidechain: not main loop
        {"type": "user", "message": {"content": "mentions compact_boundary in text"}},
        {"type": "system", "subtype": "compact_boundary"},
        {"type": "user", "isCompactSummary": True},
        {"type": "system", "subtype": "stop_hook_summary", "hookErrors": ["x"]},
        {"type": "system", "subtype": "stop_hook_summary", "hookErrors": []},
        {"attachment": {"type": "hook_blocking_error", "hookEvent": "Stop"}},
    ]))
    requests, raw = dedupe_usage(records)
    checks = [
        ("dedupe by message id", len(requests) == 2),
        ("raw records counted per content block", raw == 3),
        ("context = input + cache_creation + cache_read", context_of(usage) == 111),
        ("text mention is not a compaction", not is_compaction(records[5][1])),
        ("structural compactions detected", sum(is_compaction(r) for _, r in records) == 2),
        ("stop block needs hookErrors", sum(is_stop_block(r) for _, r in records) == 1),
        ("stop attachment detected", sum(is_stop_attachment(r) for _, r in records) == 1),
        ("sidechain counted when not main-only", len(dedupe_usage(records, main_only=False)[0]) == 3),
        ("last-seen usage wins within one message id",
         dedupe_usage(list(enumerate([assistant("m9", dict(usage, output_tokens=2)),
                                      assistant("m9", dict(usage, output_tokens=7))])))[0][0][2]
         ["output_tokens"] == 7),
    ]
    failed = [name for name, ok in checks if not ok]
    for name in failed:
        print(f"FAIL: {name}")
    print(f"self-test: {len(checks) - len(failed)} of {len(checks)} checks passed")
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--session", help="session id (transcript basename)")
    parser.add_argument("--lines", default="0:999999999",
                        help="inclusive LO:HI record bound; freezes a still-growing transcript")
    parser.add_argument("--json", action="store_true", help="print aggregates as JSON")
    parser.add_argument("--self-test", action="store_true", help="run the in-memory checks and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.session:
        parser.error("--session is required unless --self-test")
    lo, hi = (int(x) for x in args.lines.split(":"))
    summary, rows = measure(args.session, lo, hi)
    if summary["stop_blocks"] != summary["stop_attachments"]:
        print("WARNING: stop_hook_summary and hook_blocking_error counts disagree", file=sys.stderr)
    if args.json:
        print(json.dumps({"summary": summary, "tasks": rows}, indent=2))
    else:
        print_report(summary, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
