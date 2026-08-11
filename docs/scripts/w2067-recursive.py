#!/usr/bin/env python3
"""W2067: token cost of the G406 dispatcher path, walked recursively.

Why this exists rather than `baseline.py`: the dispatcher path nests two levels
of subagent (main loop -> task-runner -> explorer/reviewer), and `baseline.py`
walks one. Omitting the second level understates the new path by ~1.07M tokens
and is pitfall 3 of W2067 verbatim.

Attribution follows token-baseline.md: subagents are resolved by `toolUseId`
from `subagents/agent-*.meta.json`, not by scraping ids out of transcript text.
Both live under the project directory, so this is reproducible rather than
dependent on a session-scoped temp directory.

Usage:  python3 w2067-recursive.py [session-id]
"""
import json, collections, os, sys, glob

KEYS = ("input_tokens", "cache_creation_input_tokens",
        "cache_read_input_tokens", "output_tokens")
IN_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")

PROJECT = os.path.expanduser("~/.claude/projects/-Users-cheezy-dev-elixir-kanban")
SESSION_ID = sys.argv[1] if len(sys.argv) > 1 else "bf444983-1ea3-4214-ac72-1529b3f553ea"
SESSION = os.path.join(PROJECT, SESSION_ID + ".jsonl")
SUBAGENTS = os.path.join(PROJECT, SESSION_ID, "subagents")

# The three dispatch records and the runners they spawned. The main-loop window
# is the dispatch record alone: on the dispatcher path the main loop's only
# task-specific cost is issuing the dispatch and receiving the handoff record.
DISPATCHES = [
    ("W2072", 204, "afcb1190f06f2b9d1", 1),
    ("W2073", 255, "a03dd1e3fc610868a", 2),
    ("W2073 resume", 272, "ad43416114629a706", 2),
]
BASE = {"cc": 394_696 + 426_082, "cr": 7_627_270 + 17_275_226,
        "out": 40_017 + 48_876, "total_in": 8_024_618 + 17_701_524, "req": 79 + 114}


def sum_usage(path, only_line=None):
    """Sum usage over assistant records, de-duplicated by message id."""
    tot, seen, n = collections.Counter(), set(), 0
    for i, line in enumerate(open(path, errors="replace")):
        if only_line is not None and i != only_line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("type") != "assistant":
            continue
        m = r.get("message") or {}
        mid = m.get("id")
        if mid and mid in seen:
            continue
        if mid:
            seen.add(mid)
        u = m.get("usage") or {}
        if not u:
            continue
        n += 1
        for k in KEYS:
            tot[k] += u.get(k, 0) or 0
    return tot, n


def load_meta():
    """agentId -> {agentType, description, toolUseId, spawnDepth}."""
    meta = {}
    for p in glob.glob(os.path.join(SUBAGENTS, "agent-*.meta.json")):
        agent = os.path.basename(p)[len("agent-"):-len(".meta.json")]
        try:
            meta[agent] = json.loads(open(p).read())
        except Exception:
            # A malformed meta file must be loud: a silently skipped agent is
            # exactly the undercount this script exists to prevent.
            print("!! unreadable meta for agent %s" % agent, file=sys.stderr)
            sys.exit(1)
    return meta


META = load_meta()
MISSING = []


def tool_use_ids(path):
    """tool_use ids issued from this transcript."""
    ids = set()
    for line in open(path, errors="replace"):
        if '"tool_use"' not in line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        for c in (r.get("message", {}) or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                ids.add(c.get("id"))
    return ids


def walk(agent, label, rows, seen):
    """Sum an agent and everything it dispatched, resolved by toolUseId."""
    p = os.path.join(SUBAGENTS, "agent-%s.jsonl" % agent)
    if agent in seen:
        return collections.Counter(), 0
    if not os.path.exists(p):
        # Loud, and fatal at the end. baseline.py prints the same warning; a
        # missing transcript silently returning zero is how round 1 undercounted.
        print("!! no subagent transcript for %s (%s)" % (agent, label), file=sys.stderr)
        MISSING.append(agent)
        return collections.Counter(), 0
    seen.add(agent)
    c, n = sum_usage(p)
    rows.append((label, n, c))
    tot, reqs = collections.Counter(c), n
    issued = tool_use_ids(p)
    for child, m in sorted(META.items()):
        if m.get("toolUseId") in issued and child not in seen:
            cc, cn = walk(child, "%s -> %s" % (label, m.get("agentType", child)), rows, seen)
            tot += cc
            reqs += cn
    return tot, reqs


def run(dispatches, shared_seen):
    rows, agg, reqs = [], collections.Counter(), 0
    for label, line, agent, _pos in dispatches:
        c, n = sum_usage(SESSION, only_line=line)
        if n != 1:
            print("!! main window for %s yielded %d requests, expected 1" % (label, n),
                  file=sys.stderr)
            sys.exit(1)
        rows.append(("%s main window" % label, n, c))
        agg += c
        reqs += n
        c2, n2 = walk(agent, "%s runner" % label, rows, shared_seen)
        agg += c2
        reqs += n2
    return rows, agg, reqs


rows, agg, reqs = run(DISPATCHES, set())

hdr = "{:<44}{:>5}{:>15}{:>14}{:>8}{:>13}".format(
    "context", "req", "cache_create", "cache_read", "output", "TOTAL_IN")
print(hdr)
print("-" * len(hdr))
for label, n, c in rows:
    print("{:<44}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}".format(
        label, n, c["cache_creation_input_tokens"], c["cache_read_input_tokens"],
        c["output_tokens"], sum(c[k] for k in IN_KEYS)))
print("-" * len(hdr))
new_in = sum(agg[k] for k in IN_KEYS)
print("{:<44}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}".format(
    "TWO-TASK TOTAL", reqs, agg["cache_creation_input_tokens"],
    agg["cache_read_input_tokens"], agg["output_tokens"], new_in))
print("{:<44}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}".format(
    "BASELINE pos 1+2", BASE["req"], BASE["cc"], BASE["cr"], BASE["out"], BASE["total_in"]))

print()
print("Raw TOTAL_IN      : {:+.1f}%".format((BASE["total_in"] - new_in) / BASE["total_in"] * 100))
print("Per request       : new {:,}  base {:,}  {:+.1f}%".format(
    new_in // reqs, BASE["total_in"] // BASE["req"],
    ((BASE["total_in"] / BASE["req"]) - (new_in / reqs)) / (BASE["total_in"] / BASE["req"]) * 100))
print("cache_creation    : new {:,}  base {:,}  {:+.1f}%".format(
    agg["cache_creation_input_tokens"], BASE["cc"],
    (BASE["cc"] - agg["cache_creation_input_tokens"]) / BASE["cc"] * 100))
print("output            : new {:,}  base {:,}  {:+.1f}%".format(
    agg["output_tokens"], BASE["out"], (BASE["out"] - agg["output_tokens"]) / BASE["out"] * 100))

CW, CR, OUT = 1.25, 0.1, 5.0


def cost(c):
    return (c["input_tokens"] + c["cache_creation_input_tokens"] * CW
            + c["cache_read_input_tokens"] * CR + c["output_tokens"] * OUT)


# Baseline input_tokens derived, not assumed zero — both sides must mean the same.
b_input = BASE["total_in"] - BASE["cc"] - BASE["cr"]
bc = collections.Counter({"input_tokens": b_input, "cache_creation_input_tokens": BASE["cc"],
                          "cache_read_input_tokens": BASE["cr"], "output_tokens": BASE["out"]})

print()
print("Per position (new path is position-independent; the baseline is not):")
POS = {1: {"in": 8_024_618, "req": 79, "cc": 394_696, "cr": 7_627_270, "out": 40_017},
       2: {"in": 17_701_524, "req": 114, "cc": 426_082, "cr": 17_275_226, "out": 48_876}}
pos_tot, pos_req = collections.Counter(), 0
for pos in (1, 2):
    ds = [d for d in DISPATCHES if d[3] == pos]
    c2, r2 = collections.Counter(), 0
    for label, line, agent, _ in ds:
        cc, nn = sum_usage(SESSION, only_line=line)
        c2 += cc
        r2 += nn
        c3, n3 = walk(agent, label, [], set())
        c2 += c3
        r2 += n3
    pos_tot += c2
    pos_req += r2
    tin = sum(c2[k] for k in IN_KEYS)
    b = POS[pos]
    bcp = collections.Counter({"input_tokens": b["in"] - b["cc"] - b["cr"],
                               "cache_creation_input_tokens": b["cc"],
                               "cache_read_input_tokens": b["cr"], "output_tokens": b["out"]})
    print("  position {}: tokens/req {:+.1f}% | cache_creation {:+.1f}% | cost/req {:+.1f}%".format(
        pos,
        ((b["in"] / b["req"]) - (tin / r2)) / (b["in"] / b["req"]) * 100,
        (b["cc"] - c2["cache_creation_input_tokens"]) / b["cc"] * 100,
        ((cost(bcp) / b["req"]) - (cost(c2) / r2)) / (cost(bcp) / b["req"]) * 100))

print()
print("Pricing mix (cache write {}x, cache read {}x, output {}x base input):".format(CW, CR, OUT))
print("  raw cost     : {:+.1f}%".format((cost(bc) - cost(agg)) / cost(bc) * 100))
print("  cost/request : {:+.1f}%".format(
    ((cost(bc) / BASE["req"]) - (cost(agg) / reqs)) / (cost(bc) / BASE["req"]) * 100))

# The two views must agree; nothing may be counted once in one and twice in the other.
assert pos_req == reqs, "position requests %d != total %d" % (pos_req, reqs)
assert sum(pos_tot[k] for k in IN_KEYS) == new_in, "position TOTAL_IN disagrees with total"
if MISSING:
    print("\n!! %d subagent transcript(s) missing — figures are UNDERCOUNTED" % len(MISSING),
          file=sys.stderr)
    sys.exit(1)
print("\nchecks: positions sum to totals ({} requests, {:,} TOTAL_IN); no missing transcripts".format(
    pos_req, new_in))
