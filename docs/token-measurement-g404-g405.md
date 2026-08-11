# Per-task token measurement (post-G404, post-G405)

**Status:** Captured 2026-08-08. Revised the same day after G405 was deployed to
production. This is the **after-measurement** that
[`token-baseline.md`](token-baseline.md) was written to be checked against.
**Plugin version measured:** **1.62.0** (post-G404).
**Server:** kanban `main` at `b5737c98` (post-G405), **now live in production** —
the slim views are confirmed serving (see [G405](#g405--api-response-slimming)).

**Verdict in one line:** G404 cut per-request context by **15.2% on a fresh
session, falling to 5.6% by the third task**; G405's slimming works
spectacularly where it is exercised (−99.3% on the index) but its realized
saving is still **zero**, because no client sends the parameter.

> **Read the two G404 numbers together.** 15.2% and 5.6% are the same change
> measured at different points in a session. Quoting either alone misleads. See
> [Why one change has two right answers](#why-one-change-has-two-right-answers).

---

## Source data

One session, three consecutive Stride task runs, measured with the method in
[`token-baseline.md` § Method](token-baseline.md#method) run verbatim.

**Session:** `~/.claude/projects/-Users-cheezy-dev-elixir-kanban/9b003272-dbf1-41cf-8df3-79fc5dbb5ffe.jsonl`
(839 records). **Compaction records: none** — the whole range is one continuous
conversation, so the sums below are safe to present as single figures.

| Run | Task | Complexity | Session position | Record range |
|---|---|---|---|---|
| 1 | W2055 | small | 1st | 42–249 |
| 2 | W2057 | medium | 2nd | 266–475 |
| 3 | W2058 | medium | 3rd | 490–730 |

Boundaries were pinned by matching the **task id** inside the claim/complete
`curl` commands (`6147`, `6149`, `6150`), not by substring — later records in the
session discuss completion in prose and would otherwise produce false bounds.

**Version provenance.** The run used the installed plugin cache, confirmed by the
skill's own reported base directory:
`~/.claude/plugins/cache/stride-marketplace/stride/1.62.0/skills/stride-workflow`.
This satisfies trap 3 in the baseline doc (measure in a session started *after*
the update).

### The bytes→tokens ratio: 2.86

Derived, not assumed. Transcript record 17 is the user turn carrying the
`stride-workflow` skill body — 81,787 characters. The next assistant record
(22) reports `cache_creation_input_tokens = 28,594`.

```
81,787 bytes / 28,594 tokens = 2.86 bytes per token
```

Use this ratio for this plugin's markdown rather than the usual ~4 B/token prose
heuristic; the bodies are dense with tables, backticks and code fences. Note the
G404 goal record estimated the 140KB SKILL.md at "~35k tokens" (a 4 B/token
assumption); the true figure is **48,941**, so G404's absolute token saving was
*larger* than planned even though its percentage share was smaller.

---

## Token totals

Read from `message.usage` on each transcript record, de-duplicated by message id.
Not derived from byte sizes.

| Run | Position | Subagents | Requests | cache_creation | cache_read | Output | Total input |
|---|---|---:|---:|---:|---:|---:|---:|
| W2055 | 1st | 4 | 79 | 394,696 | 7,627,270 | 40,017 | 8,024,618 |
| W2057 | 2nd | 4 | 114 | 426,082 | 17,275,226 | 48,876 | 17,701,524 |
| W2058 | 3rd | 4 | 131 | 483,909 | 26,295,505 | 63,840 | 26,780,386 |

**W2058 breakdown** (the representative full explore→plan→implement→review run):

| Context | Requests | cache_creation | cache_read | Output | Total input |
|---|---:|---:|---:|---:|---:|
| Main loop | 59 | 117,409 | 21,781,207 | 61,198 | 21,898,726 |
| `stride:task-explorer` | 13 | 94,859 | 938,378 | 48 | 1,033,263 |
| `Plan` | 25 | 76,399 | 1,089,591 | 875 | 1,166,037 |
| `stride:task-reviewer` | 14 | 118,575 | 1,260,765 | 1,168 | 1,380,089 |
| `security-reviewer` | 20 | 76,667 | 1,225,564 | 551 | 1,302,271 |
| **TOTAL** | **131** | **483,909** | **26,295,505** | **63,840** | **26,780,386** |

### ⚠️ Do not compare these totals against the baseline table

Against the baseline (D212 6.11M / D213 12.84M / D214 20.89M), these runs are
*higher* at every position. **That is not a G404 regression**, and reporting it
as one would be wrong. The runs differ in ways that dominate the plugin delta:

- **Different subagent mix.** These runs each dispatched a `Plan` **and** a
  `stride-security-review:security-reviewer` — neither existed in D212–D214.
  Those two alone account for 2.47M input tokens on W2058.
- **Different request counts.** 79/114/131 here vs 42/70/85 in the baseline.
- **Different tasks**, of different sizes.

The baseline doc's own trap 1 is about position-in-session; this is the same
class of error one level up. **Only the controlled figure below — byte delta ×
request count — isolates the plugin's contribution.**

---

## G404 — plugin body reduction

### What changed

| File | 1.61.0 | 1.62.0 | Δ |
|---|---:|---:|---:|
| `stride-workflow/SKILL.md` | 139,972 | 80,523 | **−59,449 (−42.5%)** |
| `stride-completing-tasks/SKILL.md` | 93,911 | 93,911 | 0 |
| **Main-loop resident pair** | **233,883** | **174,434** | **−59,449** |

In tokens: **48,941 → 28,154 = −20,786 tokens resident.**

### The saving was fully realized

G404 works by extracting sections into siblings that load only when their gate
fires. The saving is therefore conditional — so it was verified, not assumed.

Each extracted file was probed with a distinctive mid-file line that does **not**
appear in `SKILL.md`, searched against the full transcript:

| Extracted file | Bytes | Loaded this session? |
|---|---:|---|
| `optional-exploratory-testing.md` | 43,022 | **No** |
| `optional-hardening.md` | 9,404 | **No** |
| `platform-other.md` | 4,807 | **No** |
| `reference.md` | 11,121 | **No** |

None loaded, so the full −20,786 tokens landed on all three runs. (Filename
*mentions* do appear in the transcript — those are `SKILL.md`'s own cross
references, which is why the probe matched on body content instead.)

### Why one change has two right answers

Resident content is re-sent on every main-loop request, so the saving is paid
back once per request. Its **percentage** therefore depends entirely on how big
the conversation already is:

| Run | Requests | Avg context per request | G404 share |
|---|---:|---:|---:|
| W2055 (1st in session) | 44 | 137,165 | **15.2%** |
| W2057 (2nd) | 53 | 255,886 | 8.1% |
| W2058 (3rd) | 59 | 369,173 | **5.6%** |

**Nothing about the plugin changed between those rows. The denominator grew
2.7×.** A planning estimate framed against a clean first-run context would
reasonably have predicted ~15% for G404 alone; measuring the third run gives
5.6%. Both are correct, and any single-number claim about this goal is
incomplete without saying which run it describes.

Absolute saving, which does *not* move with position:

| Run | Main-loop requests | cache_read avoided |
|---|---:|---:|
| W2055 | 44 | 914,584 |
| W2057 | 53 | 1,101,658 |
| W2058 | 59 | 1,226,374 |
| | | **3,242,616 (6.2% of the session)** |

| W2058 main-loop input | Tokens |
|---|---:|
| Actual, on 1.62.0 | 21,898,726 |
| Counterfactual, on 1.61.0 | 23,125,100 |
| **G404 saving** | **1,226,374 (5.3%)** |

**G404 worked.** Its ceiling was always modest for the reason the baseline doc's
trap 4 predicted: the plugin body is only ~7.6% of a 369K-token request context
by the third task, so halving one file cannot move the total by much once a
session is under way.

---

## G405 — API response slimming

**Deployment status: LIVE.** Measured against production after deploy:

| Request | Bytes | Δ |
|---|---:|---:|
| `GET /api/tasks` | 2,373,148 | — |
| `GET /api/tasks?response_view=slim` | **16,615** | **−99.3%** |
| `GET /api/tasks/6145/tree` | 319,914 | — |
| `GET /api/tasks/6145/tree?response_view=slim` | **5,810** | **−98.2%** |

The mechanism works, and works dramatically. **Its realized saving is still
zero**, for two remaining reasons.

### 1. Nothing sends the parameter — this is now the only real blocker

`response_view` occurrences:

| Surface | Occurrences |
|---|---:|
| `stride`, `-codex`, `-copilot`, `-gemini`, `-opencode`, `-pi`, `-lite`, `-copilot-lite` (8 port repos) | **0** |
| All 8 installed plugin versions under `~/.claude/plugins/cache/` | **0** |
| `stride/hooks/stride-hook.sh` (which issues the API calls) | **0** |

The feature is opt-in by design — "no existing client sees any change until it
asks" — and **no client asks**. The server now offers the discount; nothing
requests it. This is a one-line change per curl in the plugin, not a redesign.

### 2. On Claude Code, slimming `/complete` is net-negative

Only visible by measuring what *entered context* rather than what the server
sent. Taking the **real** W2058 `/complete` response:

| | Bytes | Tokens |
|---|---:|---:|
| Full view (what the server sent) | 68,670 | 24,010 |
| Slim view (computed from the same payload) | 4,735 | 1,655 |
| **Reduction on the wire** | **−93.1%** | **−22,354** |

But the harness had already truncated the oversized result:

| What actually reached the model | Bytes | Tokens |
|---|---:|---:|
| Full response, harness-truncated to a preview | 2,241 | 783 |
| Slim response — under the threshold, enters **whole** | 4,735 | 1,655 |
| **Net effect of slimming on Claude Code** | **+2,494** | **+872** |

What dominates the full payload, for reference:

| Field | Bytes |
|---|---:|
| `changed_files` | 26,627 |
| `reviewer_result` | 17,144 |
| `completion_notes` | 8,220 |
| `review_report` | 5,824 |
| `hooks` (kept in **both** views) | 4,468 |

### What G405 is actually worth

- **`/tasks/next`, `/claim` and the GET endpoints: wire the parameter in.** The
  index and tree reductions above are enormous and real.
- **`/complete` on Claude Code: correctness, not tokens.** Harness truncation is
  precisely what broke `after_goal` detection and forced the D118/D119 workarounds
  (`.last-api-response.json` capture, then a hook-initiated status GET). A slim
  response never crosses the truncation threshold, so it removes that failure
  mode at the source. That is the claim worth making here.
- **On runtimes without output truncation** (opencode, codex, copilot), the full
  24,010 tokens *would* enter context, and `/complete` slimming saves ~22K per
  completion.

---

## Where the tokens actually go

Unique content added across the three runs, attributed by source:

| Source | Calls | Bytes | ~Tokens | Share |
|---|---:|---:|---:|---:|
| Bash tool results | 131 | 210,874 | 73,732 | **48.1%** |
| Agent / subagent reports | 12 | 175,475 | 61,354 | **40.0%** |
| Read | 14 | 23,889 | 8,352 | 5.4% |
| Assistant text | — | 15,290 | 5,346 | 3.5% |
| Edit | 58 | 11,691 | 4,087 | 2.7% |
| Write | 5 | 1,047 | 366 | 0.2% |

**Stride API responses across all three runs totalled 27,132 bytes — under 10K
tokens, ~0.03% of the session.** The plugin body and the API payloads are not
the cost centre. **Tool output and subagent reports are ~88% of it.**

---

## The lever that dwarfs both goals: session position

| | Tokens |
|---|---:|
| Session as run — 3 tasks, one conversation | 52,506,528 |
| Same 3 tasks, each at first-position cost | ~24,073,854 |
| **Difference** | **~28,432,674 (54%)** |
| G404's actual saving across the same 3 tasks | 3,242,616 (6.2%) |

Clearing context between tasks is worth roughly **nine times** what G404
delivered, and it requires no code at all.

**Treat 54% as an upper bound, not a measurement.** It is confounded: W2055 was a
`small` task while the other two were `medium`, and request counts grew 44→53→59
with task size as well as position. The direction is not in doubt — average
context per request grew 137K → 369K while the plugin stayed constant — but the
magnitude mixes two causes.

The trade is real: clearing between tasks loses cross-task context, which is
worth something when consecutive tasks share a goal (as W2055/W2057/W2058 did —
each built directly on the last). This is a judgement call, not a free win.

---

## Caveats

1. **The end-to-end totals are confounded** (different tasks, different subagent
   mix, more requests). Only the controlled byte-delta × request-count figure
   isolates G404. Stated again here because it is the easiest number in this
   document to misread.
2. **The 2.86 B/token ratio is derived from one large sample** of this plugin's
   own markdown. It is right for skill bodies; JSON API payloads may differ.
3. **The index and tree slim figures are now live-measured** against production.
   **The `/complete` slim figure remains a reconstruction** — applying the
   documented `ack_data/1` key set to a real captured payload — because
   measuring it live requires completing a task, and none was available. The key
   set is fixed in code, so the figure is tight, but it is not a live capture.
4. **`changed_files` never costs the agent anything today** regardless of view:
   the hook uploads it with `curl -o /dev/null`, so that response never enters
   the agent's context. W2056's slimming of that endpoint saves the agent zero
   tokens by construction.
5. **This session's own numbers understate the full-response cost**, because
   three of the four completion curls were client-summarised through `python3`
   (109–558 B entered context) and the fourth was truncated. An agent following
   the plugin's documented `| tee` pattern verbatim would pay more.
6. **The 18–25% figure estimated before this work could not be audited.** The
   planning conversation was not available when this measurement was taken, and
   no percentage estimate is recorded in the G404/G405 goal records, the repo, or
   the subrepo docs. The [two-answers section](#why-one-change-has-two-right-answers)
   reconstructs what denominator would produce it, but that is inference.

---

## Reproduction

```bash
S=~/.claude/projects/-Users-cheezy-dev-elixir-kanban/9b003272-dbf1-41cf-8df3-79fc5dbb5ffe.jsonl

# compaction check — must report none
python3 -c "print([i for i,l in enumerate(open('$S',errors='replace')) if '\"isCompactSummary\":true' in l] or 'none')"

# token totals (baseline.py is verbatim from token-baseline.md § Method step 3)
python3 baseline.py $S  42 249 "W2055 (1st)"
python3 baseline.py $S 266 475 "W2057 (2nd)"
python3 baseline.py $S 490 730 "W2058 (3rd)"

# G404: body sizes, both versions
C=~/.claude/plugins/cache/stride-marketplace/stride
wc -c $C/1.61.0/skills/stride-workflow/SKILL.md $C/1.62.0/skills/stride-workflow/SKILL.md

# G405: is the parameter sent anywhere?  (expect 0)
grep -rl --no-ignore "response_view" stride*/ ~/.claude/plugins/cache/ | wc -l

# G405: confirm the slim views are serving in production
curl -sS -H "Authorization: Bearer $TOKEN" "$URL/api/tasks"                    -o /dev/null -w '%{size_download}\n'
curl -sS -H "Authorization: Bearer $TOKEN" "$URL/api/tasks?response_view=slim" -o /dev/null -w '%{size_download}\n'
```

---

## Recommendations

Ordered by return, largest first.

1. **Reconsider how work is sessioned.** ~54% (upper bound) sits in session
   position, against G404's 6.2%. Weigh it against the cross-task context that
   clearing discards — for a goal whose tasks build on each other, that context
   has real value. Worth a deliberate decision rather than a default.
2. **Cap the 88%.** Bash output and subagent reports dominate. Two concrete
   targets: subagent reports ran 100K+ tokens each with four dispatched per task,
   and `GET /api/tasks` returns 2.4 MB unslimmed (~840K tokens) — an agent that
   calls it without the parameter loses its context window instantly. That last
   one is a latent incident, not an optimisation.
3. **Wire `response_view=slim` into the plugin's curls.** The server now serves
   it and nothing requests it, so G405 is finished code delivering nothing. Apply
   it to `/tasks/next`, `/claim` and the GETs. For `/complete`, apply it for the
   truncation fix and the non-Claude ports — not for tokens on this runtime.
4. **Always report this class of number with its position in session.** The same
   change measured 15.2% and 5.6% in one sitting. A single headline percentage
   for a resident-context change is not a well-formed claim.

---

# Post-isolation measurement (G406, W2067)

The G406 dispatcher path runs each task in a `stride:task-runner` subagent so the
main loop holds only a bounded handoff record. This section measures it against
the post-G404 baseline above.

**Method**, per `token-baseline.md`: `message.usage` only, de-duplicated by
message id, `TOTAL_IN` = `input + cache_creation + cache_read` with output
reported separately, so both sides of every comparison mean the same thing.
Subagents are walked **recursively** — each runner dispatches its own explorer
and reviewer, and the standard `baseline.py` walks only one level.

**The headline, worst number first.** On the metric `token-baseline.md` names as
most robust — `cache_creation_input_tokens`, what newly entered a context — the
dispatcher path is **25.5% worse**. On total input per request it is **8.6%
better**. On raw totals it is 51.7% better, but that figure measures task size,
not architecture. The design estimated 34–46%; the raw figure beats it and no
like-for-like figure reaches it.

## How little of this path has ever run

Across **every** session transcript on this machine there are **four** real
`stride:task-runner` dispatches: one availability probe, and three here — W2072,
W2073, and a resume of W2073 after its first attempt was blocked. So the
dispatcher path has ever carried **two distinct tasks**.

That is the shape G405 had — a working feature no client called. Every
percentage below rests on n=2, and the mechanism claims are correspondingly weak.

## The runs

Session `bf444983…`, dispatches at records 204, 255 and 272; that session's only
compaction record is at 1936, so the measured window is one continuous
conversation, as the method requires.

**Main-loop window rule**, stated because it differs from the baseline's: the
baseline attributed a task's whole claim→complete range to it. On the dispatcher
path the main loop's *only* task-specific cost is the dispatch record and its
handoff result, so that is what is attributed. The turn that consumes the
handoff and decides what to do next is ordinary main-loop conversation and is
not charged to either task, on either side of the comparison.

| Context | Req | cache_creation | cache_read | Output | TOTAL_IN |
|---|---:|---:|---:|---:|---:|
| W2072 main-loop window | 1 | 1,852 | 163,375 | 1,692 | 165,229 |
| W2072 runner | 40 | 216,542 | 5,237,781 | 3,085 | 5,454,397 |
| W2072 runner → reviewer | 4 | 146,842 | 144,001 | 8 | 290,851 |
| W2072 runner → explorer | 3 | 57,985 | 105,306 | 7 | 163,297 |
| W2073 main-loop window | 1 | 3,092 | 182,232 | 1,616 | 185,326 |
| W2073 runner | 25 | 179,873 | 2,896,998 | 1,359 | 3,076,917 |
| W2073 runner → reviewer | 3 | 67,641 | 145,552 | 9 | 213,199 |
| W2073 runner → explorer | 3 | 61,215 | 106,402 | 9 | 167,623 |
| W2073 resume window | 1 | 3,858 | 190,595 | 1,558 | 194,455 |
| W2073 runner (att 2) | 17 | 171,311 | 2,101,032 | 863 | 2,272,374 |
| W2073 runner (att 2) → explorer | 2 | 57,918 | 47,795 | 7 | 105,717 |
| W2073 runner (att 2) → reviewer | 2 | 62,089 | 72,127 | 6 | 134,220 |
| **Two-task total** | **102** | **1,030,218** | **11,393,196** | **10,219** | **12,423,605** |
| **Baseline, positions 1+2** | **193** | **820,778** | **24,902,496** | **88,893** | **25,726,142** |

W2073's resume is included. A task that needed two attempts is not a favourable
case, and excluding it would be picking the flattering number.

**The runners' own subagents are the tier most easily missed** — six contexts,
17 requests, 1,074,907 tokens. An earlier version of this section omitted them,
which is pitfall 3 verbatim, and the omission was asymmetric because the
baseline rows include their four subagents each. It also ran *against* the
result: correcting it moved the per-request figure from −0.3% to +8.6%.

## Why the raw 51.7% is not an architecture result

**Output came out 88.5% lower** (10,219 against 88,893). Isolation does not
change output — moving work into a subagent does not make the model write less.
So that gap is not a saving; it is evidence the two task sets are different
sizes. Request counts agree: **102 against 193**.

Normalising per request gives **+8.6%** (121,800 against 133,296). But that is
an *intensity* metric, and the architecture under test changes the number and
mix of requests — which is its mechanism. In the new path most requests are
subagent requests with small fresh contexts; in the baseline most are main-loop
requests carrying an accumulated conversation. Output per request is 100 against
460, which says the request populations are not comparable units either.

The honest position: 51.7% is a true **description** of what two sessions cost
and an unsupportable **attribution** to architecture; +8.6% is the closest
available like-for-like and still not a controlled comparison. At n=2 with
different tasks there is no controlled comparison to be had — which is what
recommendation 4 above already said.

## The position effect belongs to the baseline, not to isolation

| Run | Position | TOTAL_IN | Req | Per request |
|---|---|---:|---:|---:|
| W2072 | 1st | 6,073,774 | 48 | 126,536 |
| W2073 (incl. resume) | 2nd | 6,349,831 | 54 | 117,589 |
| W2055 (baseline) | 1st | 8,024,618 | 79 | 101,577 |
| W2057 (baseline) | 2nd | 17,701,524 | 114 | 155,276 |

An earlier version read this as "isolation pays from position 2 onward". That
attributes to isolation something isolation cannot do: every runner starts at a
fresh context, so the new path has **no position effect at all** — 126,536 to
117,589 is task-to-task variation. The entire split comes from the *baseline*
side climbing 101,577 → 155,276.

The correct statement is stronger and needs no n>2: **the new path is flat with
position while the baseline rises.** Where the two lines cross, though, depends
on which metric you ask:

| Per position | tokens/req | cache_creation | modelled cost/req |
|---|---:|---:|---:|
| Position 1 | −24.6% | −7.2% | −26.1% |
| Position 2 | **+24.3%** | **−42.5%** | **−14.6%** |

- **On modelled cost they have not crossed by task 2** — the new path is still
  14.6% more expensive, converging but not level.
- **On `cache_creation` they diverge rather than converge**, because the resume
  pays a second cold start at position 2.

So the crossover is real on the metric it is stated in, and unmeasured on the
metric that decides whether to turn this on. Where the cost lines cross is in
the Unknown list below, not established here.

## Re-discovery, measured

`cache_creation_input_tokens` is what newly entered a context. Of the new path's
**1,030,218**, some **1,021,416 — 99% — is inside the runners and their
subagents**, against 8,802 in the main loop. That is the isolated contexts
loading skills, task bodies and files the main loop already had resident.

Against the baseline's 820,778, the new path creates **25.5% more** cache. This
is the cold-start premium, and the framing matters: it is not a position-1 cost
that later tasks recover. Every runner pays it, on every task, forever.

At position 2 the saving is (155,276 − 117,589) × 54 = 2,035,098 tokens, against
600,047 of runner cache_creation — so re-discovery returns **29.5%**, about a
third, of what isolation saves there. At position 1 it exceeds the saving
entirely.

## Pricing mix

Token counts are not costs. Applying the standard published multipliers — cache
write 1.25×, cache read 0.1×, output 5× base input — as a stated assumption:

- **Raw: 37.5% cheaper** (against 51.7% on tokens). Pricing shrinks the raw win,
  because the win is mostly cheap cache reads.
- **Per request: 18.3% more expensive.** Isolation trades cheap cache reads
  (0.1×) for expensive cache writes (1.25×), and the +8.6% token saving inverts.

That inversion is pitfall 4's real point, and it is the single most important
line here for anyone deciding whether to turn this on.

## What this does and does not license

- **Supported:** main-loop growth is bounded — the main-loop windows are
  165–195K each regardless of how much work the runner did. The new path is flat
  with position where the baseline rises.
- **Not supported:** a 34–46% saving. Like for like it is +8.6% on tokens, −18.3%
  on modelled cost, and −25.5% on the method's preferred metric.
- **Unknown:** everything past position 2, and **where the cost lines cross**.
  On modelled cost the new path is still 14.6% more expensive at position 2, so
  the crossover is somewhere beyond the measured range. The lines are flat and
  rising, so it should arrive — but no session has run a third dispatched task.

## Caveats

1. **n = 2 distinct tasks**, one of which needed a resume.
2. **Task sizes differ materially** (102 vs 193 requests); every conclusion uses
   the per-request normalisation, which is itself imperfect for the reason above.
3. **Pricing multipliers are assumed**, not read from an invoice.
4. **Position matching is approximate.** A runner's position is inside its own
   fresh context while the main loop had already run part of a task.

## Reproduction

```bash
python3 stride/docs/scripts/w2067-recursive.py
```

The standard `baseline.py` will not reproduce these figures: it walks one level
of subagents, and the dispatcher path needs two.

Attribution follows the documented rule rather than a heuristic. Children are
resolved by **`toolUseId`** from `subagents/agent-*.meta.json`, matched against
the tool_use ids each parent transcript actually issued — the same mechanism
`token-baseline.md` specifies. An earlier version scraped `agentId` strings out
of raw transcript text in a session-scoped temp directory, and documented the
resulting non-durability as an unavoidable limit. It was not: the durable copies
live under the project directory and carry the exact mapping, so the script now
reads those and takes the session id as an argument.

That correction left behind something better than the fix. The superseded
`agentId` scrape and the `toolUseId` mapping are **independent mechanisms
reading different files in different directories**, and they agree on all twelve
rows. Two attributions converging is stronger evidence for these figures than
either is alone — an accident of fixing a method violation, but a real one.

Two guards, because this script exists to prevent an undercount and could
commit one itself:

- a **missing child transcript is fatal and loud**, not silently zero — that is
  the failure this measurement already made once;
- the per-position and two-task views are **asserted to agree**, so a subagent
  reachable from two parents cannot be counted once in one view and twice in
  the other.
