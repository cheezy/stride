#!/usr/bin/env python3
"""W2067/W2090: token cost of the dispatcher path, walked recursively.

Why this exists rather than `baseline.py`: the dispatcher path nests two levels
of subagent (main loop -> task-runner -> explorer/reviewer), and `baseline.py`
walks one. Omitting the second level understates the new path by ~1.07M tokens
and is pitfall 3 of W2067 verbatim.

Attribution follows token-baseline.md: subagents are resolved by `toolUseId`
from `subagents/agent-*.meta.json`, not by scraping ids out of transcript text.
Both live under the project directory, so this is reproducible rather than
dependent on a session-scoped temp directory.

W2090 generalised the three things that used to be hand-encoded — the dispatch
records, their session positions, and the baseline totals — so measuring a new
session is a command line rather than an editing session. The bare invocation
still reproduces the committed W2067 figures byte for byte; see --help.

Usage:
  python3 w2067-recursive.py                       # legacy W2067 run, output frozen
  python3 w2067-recursive.py --session <id>        # any dispatcher session
  python3 w2067-recursive.py --session <id> --inline-session <id>
"""
import argparse
import collections
import glob
import json
import os
import re
import sys

KEYS = ("input_tokens", "cache_creation_input_tokens",
        "cache_read_input_tokens", "output_tokens")
IN_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")

PROJECT = os.path.expanduser("~/.claude/projects/-Users-cheezy-dev-elixir-kanban")

# The session W2067 measured. Its output is published, so the argument-free
# invocation above is a regression test, not merely a default.
LEGACY_SESSION = "bf444983-1ea3-4214-ac72-1529b3f553ea"

# Position convention, per session. See resolve_positions() for why the legacy
# session is pinned: under the other convention its two tasks would land on
# different baseline rows and every published percentage would move.
LEGACY_POSITION_MODE = {LEGACY_SESSION: "dispatch"}

# Inline baseline, per session position. Verbatim from the source-data table in
# token-measurement-g404-g405.md ("Token totals"): W2055 1st, W2057 2nd,
# W2058 3rd. Derived sums live in baseline_for() so a second literal cannot
# drift away from this one — that drift is what BASE and POS used to risk.
BASELINE = {
    1: {"req": 79, "cc": 394_696, "cr": 7_627_270, "out": 40_017, "in": 8_024_618},
    2: {"req": 114, "cc": 426_082, "cr": 17_275_226, "out": 48_876, "in": 17_701_524},
    3: {"req": 131, "cc": 483_909, "cr": 26_295_505, "out": 63_840, "in": 26_780_386},
}

NUMWORD = {1: "ONE", 2: "TWO", 3: "THREE", 4: "FOUR", 5: "FIVE", 6: "SIX"}

RUNNER_AGENT_TYPE = "stride:task-runner"
RE_TASK_ID = re.compile(r'"task_identifier"\s*:\s*"([A-Za-z0-9_-]+)"')
RE_ATTEMPT = re.compile(r'"attempt"\s*:\s*(\d+)')
RE_CLAIM_ID = re.compile(r'"identifier"\s*:\s*"([A-Za-z0-9_-]+)"')

MISSING = []


# --------------------------------------------------------------------------
# session context
# --------------------------------------------------------------------------

class Session(object):
    """One transcript plus its subagent directory, resolved together."""

    def __init__(self, session_id, subagents_dir=None):
        self.id = session_id
        self.path = os.path.join(PROJECT, session_id + ".jsonl")
        self.subagents = subagents_dir or os.path.join(PROJECT, session_id, "subagents")
        if not os.path.exists(self.path):
            print("!! no transcript at %s" % self.path, file=sys.stderr)
            sys.exit(1)
        self.meta = self.load_meta()

    def load_meta(self):
        """agentId -> {agentType, description, toolUseId, spawnDepth}."""
        meta = {}
        for p in glob.glob(os.path.join(self.subagents, "agent-*.meta.json")):
            agent = os.path.basename(p)[len("agent-"):-len(".meta.json")]
            try:
                meta[agent] = json.loads(open(p).read())
            except Exception:
                # A malformed meta file must be loud: a silently skipped agent
                # is exactly the undercount this script exists to prevent.
                print("!! unreadable meta for agent %s" % agent, file=sys.stderr)
                sys.exit(1)
        return meta

    def records(self):
        """(line_index, parsed_record) for every parseable line."""
        for i, line in enumerate(open(self.path, errors="replace")):
            try:
                yield i, json.loads(line)
            except Exception:
                continue


def sum_usage(path, lines=None):
    """Sum usage over assistant records, de-duplicated by message id.

    `lines` is None (whole transcript), a single int, or any container
    supporting `in` — a range() is the usual caller. The single-int form is the
    dispatcher main-window rule and is unchanged from W2067.
    """
    if isinstance(lines, int):
        lines = (lines,)
    tot, seen, n = collections.Counter(), set(), 0
    for i, line in enumerate(open(path, errors="replace")):
        if lines is not None and i not in lines:
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


# --------------------------------------------------------------------------
# discovery
# --------------------------------------------------------------------------

def tool_uses(record, name=None):
    for c in (record.get("message", {}) or {}).get("content") or []:
        if not isinstance(c, dict) or c.get("type") != "tool_use":
            continue
        if name is None or c.get("name") == name:
            yield c


def discover_dispatches(sess):
    """Auto-discover task-runner dispatches: [(label, line, agent, task, attempt)].

    Replaces the hand-encoded DISPATCHES list. Identifier and attempt come from
    the dispatch prompt's own JSON block; the child agent is resolved by
    toolUseId, never by eyeball.
    """
    by_tool_use = {m.get("toolUseId"): child for child, m in sess.meta.items()}
    found = []
    for i, r in sess.records():
        for c in tool_uses(r, "Agent"):
            inp = c.get("input") or {}
            if inp.get("subagent_type") != RUNNER_AGENT_TYPE:
                continue
            prompt = inp.get("prompt") or ""
            ids = RE_TASK_ID.findall(prompt)
            attempts = RE_ATTEMPT.findall(prompt)
            agent = by_tool_use.get(c.get("id"))
            # A guessed identifier is a mis-assigned position, which is a wrong
            # percentage. Never fall back to input["description"].
            if not ids:
                print("!! task-runner dispatch at line %d carries no task_identifier "
                      "in its prompt — cannot assign a position" % i, file=sys.stderr)
                sys.exit(1)
            if agent is None:
                print("!! task-runner dispatch at line %d (%s) has no subagent meta "
                      "for toolUseId %s — its cost would be UNCOUNTED"
                      % (i, ids[0], c.get("id")), file=sys.stderr)
                sys.exit(1)
            attempt = int(attempts[0]) if attempts else 1
            task = ids[0]
            if attempt == 1:
                label = task
            elif attempt == 2:
                label = "%s resume" % task
            else:
                label = "%s att %d" % (task, attempt)
            found.append((label, i, agent, task, attempt))
    if not found:
        print("!! no %s dispatches found in %s" % (RUNNER_AGENT_TYPE, sess.id),
              file=sys.stderr)
        sys.exit(1)
    return found


def discover_task_starts(sess):
    """[(line, identifier)] for every task start in the transcript, in order.

    A task start is a main-loop claim curl or the first task-runner dispatch of
    an identifier — the union is what token-baseline.md calls a task, whether it
    was worked inline or dispatched. De-duplicated by identifier.
    """
    starts, seen = [], set()
    for i, r in sess.records():
        for c in tool_uses(r):
            inp = c.get("input") or {}
            ident = None
            if c.get("name") == "Agent" and inp.get("subagent_type") == RUNNER_AGENT_TYPE:
                ids = RE_TASK_ID.findall(inp.get("prompt") or "")
                ident = ids[0] if ids else None
            else:
                cmd = inp.get("command") or ""
                if "/api/tasks/claim" in cmd:
                    ids = RE_CLAIM_ID.findall(cmd)
                    ident = ids[0] if ids else None
            if ident and ident not in seen:
                seen.add(ident)
                starts.append((i, ident))
    return starts


def discover_inline_runs(sess):
    """[(identifier, start_line, end_line)] for tasks worked in the main loop.

    A run is its claim curl through the matching /complete curl, inclusive, per
    token-baseline.md step 1. Tasks dispatched to a runner are excluded — their
    cost is measured by the dispatcher path, not here.
    """
    dispatched = {d[3] for d in find_dispatch_identifiers(sess)}
    claims, completes = [], []
    for i, r in sess.records():
        for c in tool_uses(r):
            cmd = (c.get("input") or {}).get("command") or ""
            if "/api/tasks/claim" in cmd:
                ids = RE_CLAIM_ID.findall(cmd)
                if ids:
                    claims.append((i, ids[0]))
            elif "/api/tasks/" in cmd and "/complete" in cmd:
                completes.append(i)
    runs = []
    for n, (line, ident) in enumerate(claims):
        if ident in dispatched:
            continue
        nxt = claims[n + 1][0] if n + 1 < len(claims) else None
        end = None
        for cl in completes:
            if cl > line and (nxt is None or cl < nxt):
                end = cl
        if end is None:
            # An unfinished run is real data (this is how a session in progress
            # looks) but it is not comparable with a completed one. Say so.
            print("   (%s: claimed at %d, no /complete found — measured to end of "
                  "transcript, INCOMPLETE)" % (ident, line), file=sys.stderr)
            end = last_line(sess)
        runs.append((ident, line, end))
    return runs


def find_dispatch_identifiers(sess):
    out = []
    for i, r in sess.records():
        for c in tool_uses(r, "Agent"):
            inp = c.get("input") or {}
            if inp.get("subagent_type") != RUNNER_AGENT_TYPE:
                continue
            ids = RE_TASK_ID.findall(inp.get("prompt") or "")
            if ids:
                out.append((None, i, None, ids[0], None))
    return out


def last_line(sess):
    n = 0
    for n, _ in enumerate(open(sess.path, errors="replace")):
        pass
    return n


def compact_boundaries(sess):
    """Line indices where the transcript was compacted."""
    out = []
    for i, line in enumerate(open(sess.path, errors="replace")):
        if '"compact_boundary"' in line or '"isCompactSummary":true' in line:
            out.append(i)
    return out


def guard_compaction(sess, ranges, what):
    """A compaction inside a measured window voids the ordinal-position premise.

    token-baseline.md measures within one uncompacted window; summing across a
    boundary compares a warm context with a freshly-summarised one. The method
    requires this check and the W2067 script did not have it.
    """
    bounds = compact_boundaries(sess)
    if not bounds:
        return
    for lo, hi in ranges:
        inside = [b for b in bounds if lo <= b <= hi]
        if inside:
            print("!! compaction boundary at line(s) %s falls inside the measured "
                  "%s window %d-%d — positions are not comparable across it"
                  % (", ".join(str(b) for b in inside), what, lo, hi), file=sys.stderr)
            sys.exit(1)


def resolve_positions(sess, dispatches, mode):
    """label -> session position, under the named convention.

    dispatch : ordinal among distinct task-runner identifiers, in line order.
               A resume inherits its parent identifier's position.
    claim    : ordinal among ALL task starts in the window — claims and
               dispatches merged — which is token-baseline.md's own convention.

    Both are printed because they disagree, and the disagreement is not
    cosmetic. On the legacy session the claim convention counts the W2066 claim
    at line 54 as position 1, pushing W2072 to 2 and W2073 to 3; each would then
    be compared against a different baseline row and every published percentage
    would change. That session is therefore pinned to `dispatch`.
    """
    if mode == "dispatch":
        order, pos = [], {}
        for _label, _line, _agent, task, _att in dispatches:
            if task not in order:
                order.append(task)
        for n, task in enumerate(order, 1):
            pos[task] = n
    elif mode == "claim":
        pos = {ident: n for n, (_line, ident) in enumerate(discover_task_starts(sess), 1)}
    else:
        print("!! unknown position mode %r" % mode, file=sys.stderr)
        sys.exit(1)
    return {d[0]: pos[d[3]] for d in dispatches}


# --------------------------------------------------------------------------
# recursive walk
# --------------------------------------------------------------------------

def agent_dispatch_ids(path):
    """tool_use ids of AGENT dispatches issued from this transcript.

    Filtered to Agent (as baseline.py does) so an unresolvable dispatch can be
    named. Matching on every tool_use id would be harmless today — ids are
    unique across transcripts — but it makes the guard below unwritable, because
    a non-Agent id legitimately has no meta.
    """
    ids = set()
    for line in open(path, errors="replace"):
        if '"tool_use"' not in line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        for c in (r.get("message", {}) or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "Agent":
                ids.add(c.get("id"))
    return ids


def walk(sess, agent, label, rows, seen):
    """Sum an agent and everything it dispatched, resolved by toolUseId."""
    p = os.path.join(sess.subagents, "agent-%s.jsonl" % agent)
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
    issued = agent_dispatch_ids(p)
    by_tool_use = {m.get("toolUseId"): child for child, m in sess.meta.items()}

    # An Agent dispatch with no meta is NEVER REACHED by the loop below, so
    # without this it is silently absent from the totals while the run still
    # reports success. That is the same undercount this script exists to
    # prevent, in the one position the missing-transcript guard cannot see.
    for tid in sorted(issued):
        if tid not in by_tool_use:
            print("!! %s issued Agent dispatch %s with no subagent meta — "
                  "its cost is UNCOUNTED" % (label, tid), file=sys.stderr)
            MISSING.append(tid)

    for child, m in sorted(sess.meta.items()):
        if m.get("toolUseId") in issued and child not in seen:
            cc, cn = walk(sess, child, "%s -> %s" % (label, m.get("agentType", child)),
                          rows, seen)
            tot += cc
            reqs += cn
    return tot, reqs


def run(sess, dispatches, shared_seen):
    rows, agg, reqs = [], collections.Counter(), 0
    for label, line, agent, _task, _att in dispatches:
        c, n = sum_usage(sess.path, lines=line)
        if n != 1:
            print("!! main window for %s yielded %d requests, expected 1" % (label, n),
                  file=sys.stderr)
            sys.exit(1)
        rows.append(("%s main window" % label, n, c))
        agg += c
        reqs += n
        c2, n2 = walk(sess, agent, "%s runner" % label, rows, shared_seen)
        agg += c2
        reqs += n2
    return rows, agg, reqs


# --------------------------------------------------------------------------
# cost model
# --------------------------------------------------------------------------

CW, CR, OUT = 1.25, 0.1, 5.0


def cost(c):
    return (c["input_tokens"] + c["cache_creation_input_tokens"] * CW
            + c["cache_read_input_tokens"] * CR + c["output_tokens"] * OUT)


def counter_from(b):
    """Baseline row -> Counter. input_tokens derived, not assumed zero, so both
    sides of every comparison mean the same thing."""
    return collections.Counter({
        "input_tokens": b["in"] - b["cc"] - b["cr"],
        "cache_creation_input_tokens": b["cc"],
        "cache_read_input_tokens": b["cr"],
        "output_tokens": b["out"],
    })


def baseline_for(positions):
    """Summed inline baseline over the positions actually measured."""
    missing = [p for p in positions if p not in BASELINE]
    if missing:
        print("!! no inline baseline recorded for position(s) %s — add the row to "
              "BASELINE from the source-data table before comparing"
              % ", ".join(str(p) for p in missing), file=sys.stderr)
        sys.exit(1)
    acc = {k: sum(BASELINE[p][k] for p in positions) for k in ("req", "cc", "cr", "out", "in")}
    return acc


def pct(base, new):
    """Published sign convention: positive means the new path is cheaper."""
    return (base - new) / base * 100


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

FMT = "{:<44}{:>5}{:>15,}{:>14,}{:>8,}{:>13,}"


def print_table(rows, agg, reqs, base, positions):
    hdr = "{:<44}{:>5}{:>15}{:>14}{:>8}{:>13}".format(
        "context", "req", "cache_create", "cache_read", "output", "TOTAL_IN")
    print(hdr)
    print("-" * len(hdr))
    for label, n, c in rows:
        print(FMT.format(label, n, c["cache_creation_input_tokens"],
                         c["cache_read_input_tokens"], c["output_tokens"],
                         sum(c[k] for k in IN_KEYS)))
    print("-" * len(hdr))
    new_in = sum(agg[k] for k in IN_KEYS)
    ntasks = len(positions)
    print(FMT.format("%s-TASK TOTAL" % NUMWORD.get(ntasks, str(ntasks)), reqs,
                     agg["cache_creation_input_tokens"], agg["cache_read_input_tokens"],
                     agg["output_tokens"], new_in))
    print(FMT.format("BASELINE pos %s" % "+".join(str(p) for p in positions),
                     base["req"], base["cc"], base["cr"], base["out"], base["in"]))
    return new_in


def print_headline(agg, reqs, new_in, base):
    print()
    print("Raw TOTAL_IN      : {:+.1f}%".format(pct(base["in"], new_in)))
    print("Per request       : new {:,}  base {:,}  {:+.1f}%".format(
        new_in // reqs, base["in"] // base["req"],
        pct(base["in"] / base["req"], new_in / reqs)))
    print("cache_creation    : new {:,}  base {:,}  {:+.1f}%".format(
        agg["cache_creation_input_tokens"], base["cc"],
        pct(base["cc"], agg["cache_creation_input_tokens"])))
    print("output            : new {:,}  base {:,}  {:+.1f}%".format(
        agg["output_tokens"], base["out"], pct(base["out"], agg["output_tokens"])))


def print_per_position(sess, dispatches, pos_by_label, positions):
    print()
    print("Per position (new path is position-independent; the baseline is not):")
    pos_tot, pos_req = collections.Counter(), 0
    for p in positions:
        ds = [d for d in dispatches if pos_by_label[d[0]] == p]
        c2, r2 = collections.Counter(), 0
        for label, line, agent, _task, _att in ds:
            cc, nn = sum_usage(sess.path, lines=line)
            c2 += cc
            r2 += nn
            c3, n3 = walk(sess, agent, label, [], set())
            c2 += c3
            r2 += n3
        pos_tot += c2
        pos_req += r2
        tin = sum(c2[k] for k in IN_KEYS)
        b = BASELINE[p]
        bcp = counter_from(b)
        print("  position {}: tokens/req {:+.1f}% | cache_creation {:+.1f}% | "
              "cost/req {:+.1f}%".format(
                  p,
                  pct(b["in"] / b["req"], tin / r2),
                  pct(b["cc"], c2["cache_creation_input_tokens"]),
                  pct(cost(bcp) / b["req"], cost(c2) / r2)))
    return pos_tot, pos_req


def print_pricing(agg, reqs, base):
    bc = counter_from(base)
    print()
    print("Pricing mix (cache write {}x, cache read {}x, output {}x base input):".format(
        CW, CR, OUT))
    print("  raw cost     : {:+.1f}%".format(pct(cost(bc), cost(agg))))
    print("  cost/request : {:+.1f}%".format(
        pct(cost(bc) / base["req"], cost(agg) / reqs)))


def print_positions_detail(sess, dispatches, dispatch_pos, claim_pos):
    """Both conventions, side by side. Off for the legacy session — see main()."""
    print()
    print("Session positions (two conventions; quote the one you name):")
    print("  {:<20}{:>10}{:>8}{:>10}".format("task", "dispatch", "claim", "line"))
    for label, line, _agent, _task, _att in dispatches:
        print("  {:<20}{:>10}{:>8}{:>10}".format(
            label, dispatch_pos[label], claim_pos[label], line))
    starts = discover_task_starts(sess)
    print("  task starts in window: %s" % ", ".join(
        "%s@%d" % (ident, line) for line, ident in starts))


def print_inline(sess, runs, label):
    """Inline comparator: each main-loop run plus every subagent it dispatched."""
    print()
    print("Inline runs in %s (%s):" % (sess.id[:8], label))
    hdr = "{:<44}{:>5}{:>15}{:>14}{:>8}{:>13}".format(
        "context", "req", "cache_create", "cache_read", "output", "TOTAL_IN")
    print(hdr)
    print("-" * len(hdr))
    out = []
    for n, (ident, lo, hi) in enumerate(runs, 1):
        rows = []
        c, r = sum_usage(sess.path, lines=range(lo, hi + 1))
        rows.append(("%s main loop" % ident, r, c))
        agg, reqs = collections.Counter(c), r
        # Only dispatches issued INSIDE this run's window belong to it.
        issued = agent_dispatch_ids_in_range(sess, lo, hi)
        seen = set()
        for child, m in sorted(sess.meta.items()):
            if m.get("toolUseId") in issued and child not in seen:
                cc, cn = walk(sess, child, "%s -> %s" % (ident, m.get("agentType", child)),
                              rows, seen)
                agg += cc
                reqs += cn
        for lbl, rn, cc in rows:
            print(FMT.format("  " + lbl, rn, cc["cache_creation_input_tokens"],
                             cc["cache_read_input_tokens"], cc["output_tokens"],
                             sum(cc[k] for k in IN_KEYS)))
        tin = sum(agg[k] for k in IN_KEYS)
        print(FMT.format("  %s TOTAL (position %d)" % (ident, n), reqs,
                         agg["cache_creation_input_tokens"], agg["cache_read_input_tokens"],
                         agg["output_tokens"], tin))
        out.append((ident, n, agg, reqs, tin))
    return out


def agent_dispatch_ids_in_range(sess, lo, hi):
    ids = set()
    for i, r in sess.records():
        if i < lo or i > hi:
            continue
        for c in tool_uses(r, "Agent"):
            ids.add(c.get("id"))
    return ids


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Token cost of the dispatcher path, walked recursively.")
    ap.add_argument("session_positional", nargs="?", default=None,
                    help=argparse.SUPPRESS)
    ap.add_argument("--session", default=None,
                    help="dispatcher session id (default: the W2067 session)")
    ap.add_argument("--inline-session", default=None,
                    help="a second session, measured as inline runs, for comparison")
    ap.add_argument("--position-mode", choices=("dispatch", "claim"), default=None,
                    help="which convention assigns session positions")
    ap.add_argument("--subagents-dir", default=None,
                    help="override the subagents directory (used to test the guards)")
    ap.add_argument("--positions-detail", dest="positions_detail",
                    action="store_true", default=None,
                    help="print both position conventions")
    ap.add_argument("--no-positions-detail", dest="positions_detail",
                    action="store_false")
    args = ap.parse_args()

    session_id = args.session or args.session_positional or LEGACY_SESSION
    sess = Session(session_id, args.subagents_dir)

    mode = args.position_mode or LEGACY_POSITION_MODE.get(session_id, "claim")
    dispatches = discover_dispatches(sess)
    pos_by_label = resolve_positions(sess, dispatches, mode)
    positions = sorted(set(pos_by_label.values()))

    guard_compaction(sess, [(d[1], d[1]) for d in dispatches], "dispatch")

    base = baseline_for(positions)

    rows, agg, reqs = run(sess, dispatches, set())
    new_in = print_table(rows, agg, reqs, base, positions)
    print_headline(agg, reqs, new_in, base)
    pos_tot, pos_req = print_per_position(sess, dispatches, pos_by_label, positions)
    print_pricing(agg, reqs, base)

    # The published reproduction command is the bare invocation, so the legacy
    # session's output is frozen. Anything new is additive and off by default
    # there; every other session gets the fuller report.
    detail = args.positions_detail
    if detail is None:
        detail = session_id != LEGACY_SESSION
    if detail:
        print_positions_detail(
            sess, dispatches,
            resolve_positions(sess, dispatches, "dispatch"),
            resolve_positions(sess, dispatches, "claim"))

    if args.inline_session:
        isess = Session(args.inline_session)
        iruns = discover_inline_runs(isess)
        if not iruns:
            print("!! no inline runs found in %s" % args.inline_session, file=sys.stderr)
            sys.exit(1)
        guard_compaction(isess, [(lo, hi) for _i, lo, hi in iruns], "inline")
        inline = print_inline(isess, iruns, "comparator")
        print()
        print("Dispatcher vs this inline comparator, per position:")
        disp = {}
        for p in positions:
            ds = [d for d in dispatches if pos_by_label[d[0]] == p]
            c2, r2 = collections.Counter(), 0
            for label, line, agent, _t, _a in ds:
                cc, nn = sum_usage(sess.path, lines=line)
                c2 += cc
                r2 += nn
                c3, n3 = walk(sess, agent, label, [], set())
                c2 += c3
                r2 += n3
            disp[p] = (c2, r2)
        for ident, n, iagg, ireqs, itin in inline:
            if n not in disp:
                continue
            c2, r2 = disp[n]
            tin = sum(c2[k] for k in IN_KEYS)
            print("  position {} vs {}: tokens/req {:+.1f}% | cache_creation {:+.1f}% | "
                  "cost/req {:+.1f}%".format(
                      n, ident,
                      pct(itin / ireqs, tin / r2),
                      pct(iagg["cache_creation_input_tokens"],
                          c2["cache_creation_input_tokens"]),
                      pct(cost(iagg) / ireqs, cost(c2) / r2)))

    # The two views must agree; nothing may be counted once in one and twice in
    # the other. Explicit, not `assert`: bare asserts vanish under `python3 -O`,
    # and a guard that a common interpreter flag removes is not a guard.
    if pos_req != reqs:
        print("!! position requests %d != total %d" % (pos_req, reqs), file=sys.stderr)
        sys.exit(1)
    if sum(pos_tot[k] for k in IN_KEYS) != new_in:
        print("!! position TOTAL_IN disagrees with the total", file=sys.stderr)
        sys.exit(1)
    if MISSING:
        # De-duplicated: walk() traverses the same agents twice (once for the
        # totals, once per position), so a raw len() reports a multiple of the
        # traversal count rather than a tally. The exit code was always right;
        # the number was not.
        print("\n!! %d unresolved subagent(s) — figures are UNDERCOUNTED" % len(set(MISSING)),
              file=sys.stderr)
        sys.exit(1)
    print("\nchecks: positions sum to totals ({} requests, {:,} TOTAL_IN); "
          "no missing transcripts".format(pos_req, new_in))


if __name__ == "__main__":
    main()
