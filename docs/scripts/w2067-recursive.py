#!/usr/bin/env python3
"""W2067, corrected: walk subagents RECURSIVELY.

The first pass counted the runners but not the subagents the runners themselves
dispatched (an explorer and a reviewer each). That is pitfall 3 verbatim, and it
is asymmetric: the baseline rows include their own subagents.

Uses the script's TOTAL_IN convention (input + cache_creation + cache_read),
reporting output separately, so both sides of the comparison mean the same thing.
"""
import json, collections, os, re

KEYS = ("input_tokens", "cache_creation_input_tokens",
        "cache_read_input_tokens", "output_tokens")
IN_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
S = "/Users/cheezy/.claude/projects/-Users-cheezy-dev-elixir-kanban/bf444983-1ea3-4214-ac72-1529b3f553ea.jsonl"
T = "/private/tmp/claude-501/-Users-cheezy-dev-elixir-kanban/bf444983-1ea3-4214-ac72-1529b3f553ea/tasks"


def su(path, lo=None, hi=None):
    tot, seen, n = collections.Counter(), set(), 0
    for i, line in enumerate(open(path, errors="replace")):
        if lo is not None and (i < lo or i > hi):
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
    return tot, n, seen


def children(path):
    """agentIds dispatched from within this transcript."""
    out = []
    txt = open(path, errors="replace").read()
    for m in re.finditer(r'"agentId"\s*:\s*"([a-z0-9]+)"', txt):
        out.append(m.group(1))
    return sorted(set(out))


def walk(agent, label, rows, seen_agents):
    """Sum an agent and everything it dispatched, depth-first."""
    p = os.path.join(T, agent + ".output")
    if not os.path.exists(p) or agent in seen_agents:
        return collections.Counter(), 0
    seen_agents.add(agent)
    c, n, mids = su(p)
    rows.append((label, n, c))
    tot, reqs = collections.Counter(c), n
    for ch in children(p):
        if ch == agent:
            continue
        cc, cn = walk(ch, label + " -> " + ch[:8], rows, seen_agents)
        tot += cc
        reqs += cn
    return tot, reqs


rows, seen_agents = [], set()
agg, reqs = collections.Counter(), 0

for label, lo, hi in [("W2072 main window", 204, 213),
                      ("W2073 main window", 255, 256),
                      ("W2073 resume window", 272, 273)]:
    c, n, _ = su(S, lo, hi)
    rows.append((label, n, c))
    agg += c
    reqs += n

for label, a in [("W2072 runner", "afcb1190f06f2b9d1"),
                 ("W2073 runner", "a03dd1e3fc610868a"),
                 ("W2073 runner att2", "ad43416114629a706")]:
    c, n = walk(a, label, rows, seen_agents)
    agg += c
    reqs += n

hdr = "{:<34}{:>5}{:>15}{:>14}{:>8}{:>13}".format(
    "context", "req", "cache_create", "cache_read", "output", "TOTAL_IN")
print(hdr)
print("-" * len(hdr))
for label, n, c in rows:
    print("{:<34}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}".format(
        label, n, c["cache_creation_input_tokens"], c["cache_read_input_tokens"],
        c["output_tokens"], sum(c[k] for k in IN_KEYS)))
print("-" * len(hdr))
new_in = sum(agg[k] for k in IN_KEYS)
print("{:<34}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}".format(
    "TWO-TASK TOTAL (corrected)", reqs, agg["cache_creation_input_tokens"],
    agg["cache_read_input_tokens"], agg["output_tokens"], new_in))

b_cc, b_cr = 394_696 + 426_082, 7_627_270 + 17_275_226
b_out, b_in = 40_017 + 48_876, 8_024_618 + 17_701_524
b_req = 79 + 114
print("{:<34}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}".format(
    "BASELINE pos 1+2", b_req, b_cc, b_cr, b_out, b_in))

print()
print("Raw TOTAL_IN saving        : {:+.1f}%".format((b_in - new_in) / b_in * 100))
print("Per request                : new {:,}/req  base {:,}/req  {:+.1f}%".format(
    new_in // reqs, b_in // b_req, ((b_in / b_req) - (new_in / reqs)) / (b_in / b_req) * 100))
print("cache_creation (method's preferred metric): new {:,}  base {:,}  {:+.1f}%".format(
    agg["cache_creation_input_tokens"], b_cc,
    (b_cc - agg["cache_creation_input_tokens"]) / b_cc * 100))
print("output                     : new {:,}  base {:,}  {:+.1f}%".format(
    agg["output_tokens"], b_out, (b_out - agg["output_tokens"]) / b_out * 100))

# per position, recursive
print()
for lbl, mains, agents, base_in, base_req in [
        ("position 1", [(204, 213)], ["afcb1190f06f2b9d1"], 8_024_618, 79),
        ("position 2", [(255, 256), (272, 273)], ["a03dd1e3fc610868a", "ad43416114629a706"], 17_701_524, 114)]:
    c2, r2 = collections.Counter(), 0
    for lo, hi in mains:
        cc, nn, _ = su(S, lo, hi)
        c2 += cc
        r2 += nn
    for a in agents:
        cc, nn = walk(a, "x", [], set())
        c2 += cc
        r2 += nn
    tin = sum(c2[k] for k in IN_KEYS)
    print("{}: new {:,} over {} req = {:,}/req | base {:,}/{} = {:,}/req | {:+.1f}%".format(
        lbl, tin, r2, tin // r2, base_in, base_req, base_in // base_req,
        ((base_in / base_req) - (tin / r2)) / (base_in / base_req) * 100))

# pricing mix
print()
CW, CR, OUT = 1.25, 0.1, 5.0
def cost(c):
    return (c["input_tokens"] + c["cache_creation_input_tokens"] * CW
            + c["cache_read_input_tokens"] * CR + c["output_tokens"] * OUT)
bc = collections.Counter({"input_tokens": 0, "cache_creation_input_tokens": b_cc,
                          "cache_read_input_tokens": b_cr, "output_tokens": b_out})
print("Pricing mix (cache write 1.25x, cache read 0.1x, output 5x base input):")
print("  raw cost      : new {:,.0f}  base {:,.0f}  {:+.1f}%".format(
    cost(agg), cost(bc), (cost(bc) - cost(agg)) / cost(bc) * 100))
print("  cost/request  : new {:,.0f}  base {:,.0f}  {:+.1f}%".format(
    cost(agg) / reqs, cost(bc) / b_req,
    ((cost(bc) / b_req) - (cost(agg) / reqs)) / (cost(bc) / b_req) * 100))
