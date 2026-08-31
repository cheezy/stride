# Terminal States Reference

The four states in which a Stride session may end, and the representation each
one has so the Stop gate can distinguish it rather than take the agent's word
for it.

Read this when recording a halt or an abort, when changing the Stop gate, or
when a permit message names a state and you want to know what it read. The
Decision Summary that resolves which state applies stays in the orchestrator's
Step 8; everything below is the contract behind it.

## Why these are written down

"The workflow finally stops" used to be a judgement the agent made and nothing
audited. An agent could end a session for any reason, or none, and the record
afterwards looked identical to a session that ended correctly. Naming the four
states and giving each a representation turns that judgement into a check: the
gate reads the representation, names the state it is honouring, and says so out
loud when a stop fits none of them.

## The four states

| # | State | Representation the gate reads | How it is established |
|---|---|---|---|
| 1 | No claimable task remains | `GET /api/tasks/next` answers **404**, or `200` with no `.data.identifier` | Derived. An empty Ready column answers 404, not a 200 with empty data |
| 2 | The completed task needs human review | `.stride/.loop-state.json` parses and its `needs_review` is the literal boolean `true` | Derived from the completion the loop-state file records. A file that does not parse, or whose `needs_review` is not a boolean, records no completion and is undetermined rather than state 2 |
| 3 | The user explicitly halted the loop | `.stride/.terminal-state.json` with `kind: "halt"` | Recorded by the agent, never inferred |
| 4 | An unrecoverable error occurred | `.stride/.terminal-state.json` with `kind: "error"` | Recorded by the agent, with machine-produced evidence |

States 1 and 2 need nothing written: they already follow from the loop-state
file plus the API. States 3 and 4 have no derivable evidence, which is exactly
why they need a record.

**A stop that fits none of the four is an unsanctioned stop.** The gate still
permits it — it fails open by design, and refusing to end a session it cannot
reason about would be worse than ending one it should not have. But it says so:
the permit message reports that no sanctioned terminal state could be
determined. Being visible is the whole point; there is no fifth state to file
an awkward stop under.

## An inter-task summary is not a terminal state

Writing a status summary for the user is not a terminal state. **Reporting is
not stopping.** After an inter-task summary the next action is Step 1 — claim
the next task — not the end of the turn.

This is stated because it is the specific unsanctioned stop that motivated
these states: a summary reads like a conclusion, it feels like a natural place
to hand back, and nothing in the record distinguishes it from a session that
ended for a real reason. It is not one of the four, and it does not become one
by being well written.

## The record

One file carries both agent-recorded states. They are mutually exclusive by
construction — a session either halted or aborted — so a single file means one
lifetime rule, one clear command, and no precedence question about what a
reader should do when both exist. The `kind` field distinguishes them, the same
way `needs_review` distinguishes state 2 inside `.loop-state.json` rather than
getting a file of its own.

| Field | Value |
|---|---|
| Path | `$CLAUDE_PROJECT_DIR/.stride/.terminal-state.json` |
| Format | Single-line JSON, `kind` one of `halt` or `error` |
| Always | `kind`, `session_id`, `recorded_at` (ISO8601-Z), `recorded_at_epoch` (integer) |
| `kind: "halt"` adds | nothing. The record states that a halt occurred and when — no more |
| `kind: "error"` adds | `exit_code` (a non-zero **whole** number within ±2³¹, never a string) and `step`, a short lowercase step name matching `^[a-z_]{1,32}$` — a shape, not free text |
| Written by | The agent, in Step 8, on an explicit user halt or an unrecoverable abort. Nothing else writes it |
| Lifecycle | Written at the halt or abort; cleared in Step 0, on any claim, and on an explicit resume |
| Freshness | Honoured when `session_id` matches the Stop payload's **and neither side is the sentinel**. When the record's `session_id` is the literal `unknown`, the 900-second window applies whichever value the payload carries — `unknown` is a sentinel, not an identity, so it never satisfies an identity match |
| Stale handling | Ignored. The gate falls through to its normal logic and still blocks if the block condition holds |
| Directory | `.stride/`, created with `mkdir -p`; already gitignored |

`recorded_at_epoch` is required on every record, not only on the fallback path — a record carrying no timestamp at all was once honoured, which left the freshness apparatus optional in exactly the cases it exists for.

`recorded_at_epoch` exists because comparing ISO8601 timestamps in shell needs
either GNU `date -d` or BSD `date -j -f`, and a script that picks one fails on
exactly one platform in a way no CI would catch. Integers compare the same
everywhere. `recorded_at` is kept beside it for the human reading the file.

### The record carries no free text, deliberately

**A halt record says that a halt happened and when. It does not quote the user,
and it must not.** A user's message can contain anything — a credential pasted
mid-conversation, a customer's data, a private path — and this record is a file
on disk that outlives the turn. Storing the quote would put unbounded text into
an artifact whose whole job is to be small and mechanical.

The same rule governs `kind: "error"`: no command string, no stderr capture, no
API response, no diff content. A Stride command routinely carries a bearer
token, and stderr routinely carries whatever the failing tool printed, so both
are exactly the free text this record refuses. What remains is an exit code and
a step name constrained to `^[a-z_]{1,32}$` — bounded, and far too narrow to
carry anything consideration 2 names: thirty-two characters of lowercase and
underscore cannot hold an API response, a diff, or a bearer token, which carries
digits and is much longer. The constraint is a SHAPE rather than an enumerated
list, and it is written that way here because the gates enforce exactly that and
nothing more.

**This is a real trade and it is worth naming.** An earlier draft required a
verbatim `user_message` so a human could check the claim against the
transcript, which is a genuine auditability gain — and the wrong call. The
transcript already holds the user's words; duplicating them into a persistent
side-file buys a convenience an auditor can get elsewhere, at the cost of an
unbounded-content artifact. The record answers *whether* and *when*; the
transcript answers *what was said*.

A consequence worth stating plainly: with no quote to check, a halt record is
closer to an assertion than that earlier draft pretended. The section below on
auditability already said the agent holds the pen — this makes that more true,
not less. What the record still gives an auditor is a timestamp and a session id
to correlate against the transcript, which is enough to find the moment and read
it there.

### Session identity, and the `unknown` sentinel

The record is honoured only in the session that wrote it. That is exact rather
than heuristic: the Stop payload carries `session_id`, so a record from an
earlier session is recognisably foreign and is ignored.

When `CLAUDE_SESSION_ID` is unset the writer stores the literal string
`unknown` — **not** a generated uuid. A uuid would be permanently foreign to
every session, so state 3 would be unreachable in that runtime and nobody would
see why. With `unknown` on both sides the gate falls back to the 900-second
window: heuristic only where it has to be.

The failure directions are deliberately asymmetric. A record wrongly **ignored**
costs a refused stop, bounded by the gate's re-block budget and by
`STRIDE_ALLOW_STOP=1`. A record wrongly **honoured** turns the gate off
silently. The second is worse, so every ambiguity resolves toward ignoring the
record.

### Write

```bash
mkdir -p "$CLAUDE_PROJECT_DIR/.stride"
jq -nc --arg k "halt" \
  --arg s "${CLAUDE_SESSION_ID:-unknown}" \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson e "$(date -u +%s)" \
  '{kind:$k, session_id:$s, recorded_at:$t, recorded_at_epoch:$e}' \
  > "$CLAUDE_PROJECT_DIR/.stride/.terminal-state.json"
```

For an unrecoverable error, add the exit code and the step it failed in — and
nothing else:

```bash
jq -nc --arg k "error" \
  --arg s "${CLAUDE_SESSION_ID:-unknown}" \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson e "$(date -u +%s)" \
  --argjson c 1 \
  --arg p "implementation" \
  '{kind:$k, session_id:$s, recorded_at:$t, recorded_at_epoch:$e, exit_code:$c, step:$p}' \
  > "$CLAUDE_PROJECT_DIR/.stride/.terminal-state.json"
```

### Clear

```bash
rm -f "$CLAUDE_PROJECT_DIR/.stride/.terminal-state.json"
```

## What "explicit" means

A message **from the user, in this session**, whose plain reading is an
instruction to stop the Stride loop. The record does **not** quote it — see the
no-free-text rule above — so what counted as explicit is settled in the
transcript, which the record's timestamp and session id point at.

None of the following is an explicit halt:

- The agent judging the work a good stopping point.
- The agent having written a summary, report, or status update for the user.
- The user asking a question, asking for an explanation, or asking to see
  something.
- The user approving something — "looks good", "yes", "ship it". Approval of
  work is not an instruction to stop working.
- The user going quiet, or the session having run a long time.
- Any inference from tone, or from the absence of an instruction.
- A hook failure, a test failure, or a review rejection. Those are state 4 at
  most, and only when genuinely unrecoverable.

## This is auditability, not enforcement

The agent holds the pen. Nothing here technically prevents an agent from
writing a halt record it should not have written, and claiming otherwise would
be a worse failure than the one this replaces.

What changes is that the stop becomes **visible and locatable**. The gate names
the state in its permit message, so a fabricated halt appears in the session
record instead of vanishing into a silent stop; the record's timestamp and
session id point at the exact moment in the transcript, where the claim can be
checked against what the user actually said; and `kind: "error"` carries a
non-zero exit code and a step name rather than a bare assertion.

The record does not itself prove the claim, and it is not built to. It says a
halt was recorded, in this session, at this instant — and it makes an
unsanctioned stop distinguishable from a sanctioned one, which is all this set
out to do.

## A corrupt file is not a terminal state

An unreadable `.stride/.loop-state.json` records no completion and no review
requirement, so it cannot establish state 2 — it is reported as an unsanctioned
stop like any other undetermined case. This is written down because the
opposite behaviour was implemented first and was worse than it looked: a single
appended byte turned a correct block into `permitting the stop under sanctioned
terminal state 2`, so an agent that wanted to stop needed no forged record at
all, only to corrupt a file it already owned — and the audit line then read as a
sanctioned, review-gated ending.

The same rule governs every permit the gate reaches after it had something to
gate on: a missing, empty, or malformed identifier is reported, never silent.
Silence is reserved for the paths where the gate had nothing to act on at all.

## The gate never echoes the record

The permit message names the **state** and nothing from the file. Since the
record carries no free text at all, this is a narrow rule rather than a
load-bearing one — but it stays stated, because the same discipline governs the
server-supplied identifier the gate does handle, which it refuses rather than
sanitises when it is not identifier-shaped.
