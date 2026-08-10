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
the post-G404 baseline above. Method per `token-baseline.md`: `message.usage`
only, de-duplicated by message id, subagent totals included.

**The headline first, because it is not the flattering number.** Raw totals show
a **55.8%** saving. Normalised for task size, the two-task figure is **−0.3%** —
parity. The design estimated 34–46%; the raw figure beats it and the like-for-like
figure does not reach it. Both are below.

## How little of this path has ever run

Across **every** session transcript on this machine there are **four** real
`stride:task-runner` dispatches: one availability probe, and three here —
W2072, W2073, and a resume of W2073 after its first attempt was blocked. So the
dispatcher path has ever carried **two distinct tasks**.

That is the same shape as G405, which "shipped a working feature that no client
ever called". The feature works; it is barely exercised. Any percentage below
rests on n=2.

## The runs

Session `bf444983…`, dispatches at records 204, 255 and 272 — all before the
session's compaction record at 1936, so the measured window is one continuous
conversation, as the method requires.

| Context | Requests | cache_creation | cache_read | Output | Total input |
|---|---:|---:|---:|---:|---:|
| W2072 main-loop window | 1 | 1,852 | 163,375 | 1,692 | 166,921 |
| W2073 main-loop window | 1 | 3,092 | 182,232 | 1,616 | 186,942 |
| W2073 resume window | 1 | 3,858 | 190,595 | 1,558 | 196,013 |
| W2072 runner | 40 | 216,542 | 5,237,781 | 3,085 | 5,457,482 |
| W2073 runner | 25 | 179,873 | 2,896,998 | 1,359 | 3,078,276 |
| W2073 runner (attempt 2) | 17 | 171,311 | 2,101,032 | 863 | 2,273,237 |
| **Two-task total (new path)** | **85** | **576,528** | **10,772,013** | **10,173** | **11,358,871** |
| **Baseline, positions 1+2** | **193** | **820,778** | **24,902,496** | **88,893** | **25,726,142** |

W2073's resume is included. It inflates the new path — a task that needed two
attempts is not a favourable case — and excluding it would be picking the
flattering number.

## Why the raw 55.8% is not the answer

**Output tokens came out 88.6% lower** (10,173 against 88,893). Isolation does
not change output — moving work into a subagent does not make the model write
less. So that gap is not a saving; it is evidence the two sets of tasks are not
the same size. The request counts say it plainly: **85 against 193**. The new-path
tasks were under half the work.

Comparing them raw measures task size, not architecture. Normalising by request:

| Run | Position | Total input | Requests | Per request |
|---|---|---:|---:|---:|
| W2072 | 1st | 5,624,403 | 41 | 137,180 |
| W2073 (incl. resume) | 2nd | 5,734,468 | 44 | 130,328 |
| W2055 (baseline) | 1st | 8,024,618 | 79 | 101,577 |
| W2057 (baseline) | 2nd | 17,701,524 | 114 | 155,276 |

- **Two-task, per request: −0.3%.** 133,633 against 133,296. Parity.
- **Position 1: −35.1%.** The new path is *worse* — 137,180 against 101,577.
- **Position 2: +16.1%.** The new path is better — 130,328 against 155,276.

The shape is the mechanism working as designed, with a cost the design under-weighted.
Isolation stops the conversation accumulating, so it pays from position 2 onward.
It also makes every runner start cold, so position 1 pays a premium it never
recovers within a single task.

## Re-discovery, measured (not just named)

`cache_creation_input_tokens` is what *newly entered* a context — the baseline
document names it the most robust single comparison, and it is also where
re-discovery shows up.

Of the new path's **576,528** cache_creation, **567,726 — 98% — is inside the
runners**, against 8,802 in the main loop. That is the isolated contexts loading
skills, task bodies and files the main loop already had resident.

So re-discovery is not a rounding error against the saving; at position 1 it
exceeds it. This is the answer to "how much of the modelled saving is returned":
**at position 1, more than all of it; by position 2, about a quarter of it.**

## What this does and does not license

- **Supported:** the dispatcher path reduces per-request context from the second
  task onward, and reduces total main-loop growth substantially — the main-loop
  windows are ~170–196K each regardless of how much work the runner did.
- **Not supported:** a general "34–46% saving" claim. Like for like, two tasks
  came out at parity, and the first task came out worse.
- **Unknown:** everything beyond position 2. The curve suggests the saving keeps
  growing with position, exactly as the baseline's position effect predicts, but
  no session has ever run a third dispatched task, so that is a projection.

## Caveats

1. **n = 2 distinct tasks**, one of which needed a resume.
2. **Task sizes differ materially** from the baseline runs (85 vs 193 requests);
   every conclusion above uses the per-request normalisation for that reason.
3. **Pricing mix is not addressed.** These are token counts. Cache reads,
   cache writes and output are not priced alike, and output — the most expensive
   per token — is unchanged by isolation. A cost saving is therefore smaller than
   any input-token percentage here, and this document does not compute one.
4. **Position matching is approximate.** The baseline positions are positions in
   a main-loop session; a runner's position is inside its own fresh context while
   the main loop had already run part of a task. The mapping is defensible but
   not exact, and it is the trap the baseline document names first.
