#!/usr/bin/env bash
# stride-stop-gate.sh — Stop gate: refuses to end a session while a claimable
# Stride task remains.
#
# This converts "the agent should claim the next task" from prose into a
# mechanism. A rule an agent can simply not follow is not a rule; a Stop hook
# that refuses the stop is. The evidence it reads is written by the completion
# path in stride-hook.sh (W2123) and cleared by the very next claim, so the
# state machine resolves itself: block -> agent claims -> claim clears the
# state -> the next stop is permitted.
#
# INPUT CONTRACT — $CLAUDE_PROJECT_DIR/.stride/.loop-state.json, written on a
# successful completion and cleared on ANY claim. Exactly four keys:
#   {"identifier":"W123","needs_review":false,"completed_at":"<ISO8601-Z>","session_id":"<id>"}
# Its presence means: a completion happened and no claim has followed it yet.
# Its ABSENCE means there is nothing to gate on, which is the common case and
# the cheapest path through this script — one file test and no network.
#
# BLOCK CONDITION (the only one):
#   the loop-state file exists AND its needs_review is the JSON boolean false
#   AND GET /api/tasks/next answers 200 with a non-empty .data.identifier.
#
# PERMIT — everything else, without exception. Named, because "fails open" is
# a claim that has to be discharged case by case:
#   - no loop-state file, or it is unreadable/unparseable/malformed
#   - needs_review is true, absent, null, or not a boolean
#   - no jq, no curl, no API URL, no API token
#   - transport failure, DNS failure, connect timeout, read timeout
#   - any non-200 status. NOTE an empty Ready queue answers **404**, not a 200
#     with empty data — verified against the live API — so "no task available"
#     and "non-200" are the same wire event and both permit here.
#   - a 200 whose body is not JSON, or carries no usable identifier
#   - the re-block guard's budget is spent, or its own state cannot be written
#
# The harness helps: only exit 2 blocks. A timeout, a crash, a non-zero exit,
# or malformed stdout all permit the stop. Every permit path below is still
# written and tested explicitly rather than left to that accident.
#
# EXIT 2 IS THE LOAD-BEARING MECHANISM. The JSON object on stdout is
# best-effort enrichment: the published docs show more than one Stop output
# shape and none is clearly current, so this emits one object carrying both
# spellings. Unknown keys are ignored, and if the object is ignored entirely
# the exit code still blocks and stderr still carries the reason.
#
# Registered for `Stop` ONLY, never `SubagentStop`. A subagent has no Stride
# loop of its own, and blocking one on its parent's loop state would wedge work
# that can never clear the gate.
#
# Never echoes the token. It is read by resolve_stride_api_token, reaches
# exactly one place — curl's Authorization header argument — and is never
# logged, exported, or interpolated into any message.
#
# Exit codes:
#   0 — stop permitted
#   2 — stop blocked (Claude Code interprets exit 2 from Stop as a block)

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
LOOP_STATE_FILE="$PROJECT_DIR/.stride/.loop-state.json"
BLOCK_COUNTER_FILE="$PROJECT_DIR/.stride/.stop-gate-blocks"
# (W2125) The record carrying the two terminal states that cannot be derived —
# an explicit user halt, and an unrecoverable error. States 1 and 2 need no
# file: they already follow from the loop-state file plus the API. The full
# contract is in skills/stride-workflow/terminal-states.md.
TERMINAL_STATE_FILE="$PROJECT_DIR/.stride/.terminal-state.json"

# How many times this gate will refuse ONE unfollowed completion before letting
# the session go. The intended path needs exactly one block — the claim that
# follows clears the loop state — so 2 leaves a single block of margin for a
# benign second stop without ever feeling like a wedge to someone who genuinely
# wants to leave. Wedging a session is strictly worse than missing a gate.
STOP_GATE_MAX_BLOCKS=2
# VALIDATE THE OVERRIDE, or it becomes the wedge this guard exists to prevent.
# An unvalidated value reaches `[ "$n" -gt "$MAX" ]`, where a non-numeric right
# operand makes `[` ERROR with status 2; the `if` reads that as false and the
# gate blocks EVERY time, unbounded. The reachable path is not exotic — someone
# trying to turn the gate off with STRIDE_STOP_GATE_MAX_BLOCKS=off would get a
# permanently unstoppable session, the precise opposite of their intent. Only
# an unsigned decimal integer is honoured; anything else keeps the default.
# (The PowerShell half has always guarded this with [int]::TryParse.)
# The length bound is not cosmetic: an all-digit value at or above 2^63 passes
# a charset check and then makes `[ -gt ]` error, which reads as false and
# blocks unboundedly — the same wedge, reached by someone RAISING the budget
# instead of disabling it. Nine digits keeps every accepted value far inside
# integer range, and no real budget approaches it.
case "${STRIDE_STOP_GATE_MAX_BLOCKS:-}" in
  '') ;;
  *[!0-9]*) ;;
  *) [ "${#STRIDE_STOP_GATE_MAX_BLOCKS}" -le 9 ] \
       && STOP_GATE_MAX_BLOCKS="$STRIDE_STOP_GATE_MAX_BLOCKS" ;;
esac

# --- Platform detection: delegate to PowerShell on native Windows ---
#
# DELIBERATE DIVERGENCE from stride-skill-gate.sh:29-47, whose equivalent
# branches exit 2. Copied verbatim into a Stop hook, "the .ps1 is missing" or
# "powershell.exe is missing" would become an unconditional, permanent,
# UNCOUNTED block of every stop on that machine — the re-block guard below
# never runs, so nothing could bound it. For a Stop gate, a broken delegation
# must permit.
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-stop-gate.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    printf 'stride-stop-gate: Windows detected but stride-stop-gate.ps1 not found at %s; permitting the stop\n' \
      "$PS1_SCRIPT" >&2
    exit 0
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    printf 'stride-stop-gate: Windows detected but powershell.exe not found in PATH; permitting the stop\n' >&2
    exit 0
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT"
fi

# --- Permit messages ---
# The gate speaks only when it had something to gate on. The quiet paths — no
# jq, a re-firing stop, and above all the no-loop-state case, which fires on
# every Stop event in any project — stay silent; a line on each of those would
# put gate chatter on every stop in the repo and train a reader to ignore the
# one channel that carries the state.
permit_state() {
  printf 'stride-stop-gate: permitting the stop under sanctioned terminal state %s\n' "$1" >&2
  exit 0
}

# A stop that fits none of the four is not filed under a fifth state — it is
# reported as what it is. The gate still permits (it fails open by design), but
# an unsanctioned stop becomes visible rather than invisible, which is the
# entire point of enumerating the states.
permit_undetermined() {
  printf 'stride-stop-gate: permitting the stop, but no sanctioned terminal state could be determined (%s) — this stop is unsanctioned\n' "$1" >&2
  exit 0
}

# --- Escape hatch ---
# No weaker than what the agent could already do by deleting the loop-state
# file; documented so a human who wants out has a stated way rather than a
# discovered one.
if [ "${STRIDE_ALLOW_STOP:-}" = "1" ]; then
  # Named rather than silent: it fires only when a human deliberately set the
  # variable, so there is no noise cost, and "the override was used and no
  # sanctioned state was established" is exactly what the record should show.
  permit_undetermined "STRIDE_ALLOW_STOP=1 was set"
fi

# --- Counter helpers ---
# Plain text, one line, "<identifier> <count>". Not JSON: the read then needs
# no parser, and any corruption reads as a fresh count rather than an error.
reset_block_counter() {
  rm -f "$BLOCK_COUNTER_FILE" 2>/dev/null || true
}

# Blocks recorded so far for THIS completion. Keyed on the loop-state
# identifier — the task just completed — and NOT on the claimable task's
# identifier, which can change between attempts when another agent takes the
# head of the queue. Keying on that would silently reset the count and restore
# the unbounded loop this guard exists to prevent.
read_block_count() {
  local _key="$1" _line _stored_key _stored_count
  [ -f "$BLOCK_COUNTER_FILE" ] || { printf '0'; return 0; }
  _line=$(cat "$BLOCK_COUNTER_FILE" 2>/dev/null || printf '')
  _stored_key="${_line%% *}"
  _stored_count="${_line##* }"
  [ "$_stored_key" = "$_key" ] || { printf '0'; return 0; }
  case "$_stored_count" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$_stored_count" ;;
  esac
}

# --- Block emitter ---
# ONE JSON document on stdout. Two concatenated documents fail a strict parse,
# which this repo has already been bitten by (D238), so the two candidate Stop
# shapes are carried as sibling keys of a single object rather than as two.
emit_block() {
  local _reason="$1"
  # Carries BOTH documented spellings as sibling keys of ONE object: the
  # current hookSpecificOutput form, and the legacy {"decision":"block",
  # "reason":...} pair that Anthropic's own reference stop hook still emits. A
  # harness honouring only the legacy names would otherwise get the block (from
  # exit 2) without the reason text, which is the one thing this object exists
  # to deliver. Unknown keys are ignored, so carrying both costs nothing.
  jq -nc --arg r "$_reason" \
    '{decision: "block",
      reason: $r,
      systemMessage: $r,
      hookSpecificOutput: {hookEventName: "Stop",
                           permissionDecision: "deny",
                           permissionDecisionReason: $r}}'
  printf 'stride-stop-gate: %s\n' "$_reason" >&2
  exit 2
}

# --- Read the Stop payload ---
INPUT=$(cat 2>/dev/null || printf '')

command -v jq > /dev/null 2>&1 || exit 0

# Defensive read of stop_hook_active: in the versions that send it, it marks a
# Stop that is re-firing after this hook's own block, and honouring it avoids a
# loop the harness already knows about. It is NOT in the current published
# schema, so it is read as a bonus and never depended on — the counter below is
# the actual guarantee.
if [ -n "$INPUT" ] \
  && printf '%s' "$INPUT" | jq -e 'try (.stop_hook_active == true) catch false' > /dev/null 2>&1; then
  exit 0
fi

# --- Terminal states 3 and 4, from the recorded file (W2125) ---
# Deliberately BEFORE the loop-state test: a user halt and an unrecoverable
# error are terminal regardless of whether a completion is awaiting a claim.
# Every rejection below falls through to the normal logic rather than exiting,
# so a malformed or foreign record can never disable the gate — it can only
# fail to permit, which is the safe direction.
if [ -f "$TERMINAL_STATE_FILE" ]; then
  _ts_kind=$(jq -r 'try (if (.kind | type) == "string" then .kind else "" end) catch ""' \
    "$TERMINAL_STATE_FILE" 2>/dev/null || printf '')
  _ts_sid=$(jq -r 'try (.session_id // "") catch ""' "$TERMINAL_STATE_FILE" 2>/dev/null || printf '')
  _ts_epoch=$(jq -r 'try (if (.recorded_at_epoch | type) == "number" then (.recorded_at_epoch | floor | tostring) else "" end) catch ""' \
    "$TERMINAL_STATE_FILE" 2>/dev/null || printf '')

  # Session identity first, because it is exact. A record from an earlier
  # session is recognisably foreign and is ignored — that is what keeps a stale
  # record from silently switching the gate off, which is the worst outcome
  # available here and strictly worse than a refused stop.
  _ts_current=$(printf '%s' "$INPUT" | jq -r 'try (.session_id // "") catch ""' 2>/dev/null || printf '')
  [ -n "$_ts_current" ] || _ts_current="${CLAUDE_SESSION_ID:-}"
  # `unknown` is a SENTINEL, not an identity. An earlier revision let the
  # exact-match branch fire when both sides carried it, which skipped the window
  # entirely and honoured a six-year-old record — the gate silently off, the one
  # outcome this design ranks worst. The sentinel now always routes through the
  # window, whichever side it appears on, and a real session id never matches it.
  _ts_ok=no
  if [ -n "$_ts_sid" ] && [ "$_ts_sid" != "unknown" ] \
    && [ -n "$_ts_current" ] && [ "$_ts_current" != "unknown" ] \
    && [ "$_ts_sid" = "$_ts_current" ] && [ -n "$_ts_epoch" ]; then
    _ts_ok=yes
  elif [ "$_ts_sid" = "unknown" ] && { [ -z "$_ts_current" ] || [ "$_ts_current" = "unknown" ]; } \
    && [ -n "$_ts_epoch" ]; then
    # Neither side knows its session, so identity cannot decide it. Fall back to
    # a short window — heuristic only where it has to be. The writer stores the
    # literal `unknown` rather than a generated uuid for exactly this reason: a
    # uuid would be foreign to every session, making state 3 permanently
    # unreachable in that runtime with nothing to show why.
    _ts_now=$(date -u +%s 2>/dev/null || printf '0')
    case "$_ts_now$_ts_epoch" in
      *[!0-9]*) ;;
      *) [ "$((_ts_now - _ts_epoch))" -le 900 ] && [ "$((_ts_now - _ts_epoch))" -ge 0 ] && _ts_ok=yes ;;
    esac
  fi

  if [ "$_ts_ok" = "yes" ]; then
    case "$_ts_kind" in
      halt)
        # The record states THAT a halt occurred and WHEN — it carries no quote
        # of the user's message, by contract. A user's words can contain a
        # pasted credential, customer data, or a private path, and this file
        # persists on disk past the turn, so the transcript keeps the words and
        # the record keeps only the fact and the timestamp that locate them.
        # kind, session and epoch have already been validated above, so there
        # is nothing further to check.
        permit_state "3 (the user halted the loop)"
        ;;
      error)
        # Bounded, machine-produced evidence only: a non-zero exit code and a
        # step name from the workflow's own vocabulary. NO command string and
        # NO stderr capture — a Stride command routinely carries a bearer token
        # and stderr carries whatever the failing tool printed, and neither
        # belongs in a file that outlives the turn.
        #
        # A recoverable hook failure is not this state: honouring one would
        # permit any stop after any failed hook, a fifth state wearing state
        # 4's clothes. exit_code must be a WHOLE number in range — `type ==
        # "number"` alone accepted 0.5 and 1e300, which the PowerShell half
        # rejects, so the same record ended a session on one host and not the
        # other.
        if jq -e 'try ((.exit_code | type) == "number"
                       and (.exit_code == (.exit_code | floor))
                       and (.exit_code > -2147483648) and (.exit_code < 2147483648)
                       and (.exit_code != 0)
                       and (.step | type) == "string"
                       and (.step | test("^[a-z_]{1,32}$"))) catch false' \
          "$TERMINAL_STATE_FILE" > /dev/null 2>&1; then
          permit_state "4 (an unrecoverable error was recorded)"
        fi
        ;;
    esac
  fi
fi

# --- AC3: no loop state, nothing to gate on ---
if [ ! -f "$LOOP_STATE_FILE" ]; then
  reset_block_counter
  exit 0
fi

# --- AC6: the last completion needs human review, so the loop legitimately stops ---
# Only the literal JSON boolean false proceeds. true, "false" as a string,
# null, an absent key, and an unparseable file all land here, which makes this
# one rule cover AC6 and every malformed-file case at once.
# A file that does not parse records no completion and no review requirement,
# so it cannot establish state 2. Announcing one would file an unsanctioned
# stop under a sanctioned state — exactly the audit failure this design exists
# to remove — so it is reported as undetermined instead.
if ! jq -e . "$LOOP_STATE_FILE" > /dev/null 2>&1; then
  reset_block_counter
  permit_undetermined "the loop-state file could not be parsed"
fi
if ! jq -e 'try ((.needs_review | type) == "boolean") catch false' "$LOOP_STATE_FILE" > /dev/null 2>&1; then
  reset_block_counter
  permit_undetermined "the loop-state file records no usable needs_review"
fi
if jq -e 'try (.needs_review == true) catch false' "$LOOP_STATE_FILE" > /dev/null 2>&1; then
  reset_block_counter
  # Reached before the network leg, deliberately: state 2 is decided by the
  # completion record alone and needs no API call to establish.
  permit_state "2 (the completed task needs human review)"
fi

COMPLETED_IDENT=$(jq -r 'try (.identifier // "") catch ""' "$LOOP_STATE_FILE" 2>/dev/null || printf '')
# Same charset rule the writer enforces (stride-hook.sh loop_state_safe). Used
# only as the counter's key, but validated anyway: it is read off disk and a
# value that is not identifier-shaped means the file is not what it claims.
case "$COMPLETED_IDENT" in
  '') permit_undetermined "the loop-state file records no identifier" ;;
  *[!A-Za-z0-9_.:-]*) permit_undetermined "the completed identifier is not identifier-shaped" ;;
esac
[ "${#COMPLETED_IDENT}" -le 64 ] \
  || permit_undetermined "the completed identifier is longer than 64 characters"

# --- The network leg, reached only when the local evidence already says block ---
command -v curl > /dev/null 2>&1 || permit_undetermined "curl is not available"

# Resolvers duplicated from stride-hook.sh:791-816 rather than sourced: sourcing
# that file would execute 6,000 lines of file-scope code on every Stop event.
# Both functions are pure and stable.
resolve_stride_api_url() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _url=""
  if [ -f "$_auth" ]; then
    _url=$(grep -E '\*\*API URL:\*\*' "$_auth" | grep -oE 'https?://[A-Za-z0-9._:/-]+' | head -n 1 || true)
  fi
  printf '%s' "$_url"
}

# The production `**API Token:**` line, deliberately NOT `**Local API Token:**`
# (the pattern does not match the longer label). Prints the token; never logs it.
resolve_stride_api_token() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _tok=""
  if [ -f "$_auth" ]; then
    _tok=$(grep -E '\*\*API Token:\*\*' "$_auth" | grep -oE '`[^`]+`' | head -n 1 | tr -d '`' || true)
  fi
  printf '%s' "$_tok"
}

_api_base=$(resolve_stride_api_url)
_token=$(resolve_stride_api_token)
if [ -z "$_api_base" ] || [ -z "$_token" ]; then
  permit_undetermined "no API URL or token could be resolved"
fi

# --- AC7: bounded, and bounded twice ---
# --max-time 5 rather than the 10 used elsewhere in this plugin: this hook sits
# in the user's exit path, and an API that cannot answer in five seconds is one
# whose answer is not worth making someone wait for. --connect-timeout 3 fails
# fast against a black-holed host. The hooks.json timeout is an independent
# third bound, and a harness kill exits non-2, which permits.
# curl's own stderr is discarded so it can never reach this hook's stderr.
_resp=$(curl -s --connect-timeout 3 --max-time 5 -w '\n%{http_code}' \
  -H "Authorization: Bearer $_token" \
  "$_api_base/api/tasks/next" 2>/dev/null || printf '')

# --- AC4: transport failure, DNS failure, or timeout ---
[ -n "$_resp" ] || permit_undetermined "the API could not be reached, or the request timed out"

_code="${_resp##*$'\n'}"
_body="${_resp%$'\n'*}"

# --- AC4 and AC5: any non-200. An empty Ready queue answers 404 with an
# {"error": ...} body, so both criteria are discharged by this one test. The
# body on that path is server-controlled text and is never parsed or echoed.
# An empty Ready column answers 404 — verified against the live API — so a 404
# IS state 1, not merely a failure to determine one. Every other non-200 is a
# server we could not get an answer from, which establishes nothing.
if [ "$_code" != "200" ]; then
  if [ "$_code" = "404" ]; then
    permit_state "1 (no claimable task remains)"
  fi
  if [ "$_code" = "000" ]; then
    permit_undetermined "the API could not be reached, or the request timed out"
  fi
  permit_undetermined "the API answered $_code"
fi

printf '%s' "$_body" | jq -e . > /dev/null 2>&1 \
  || permit_undetermined "the API response could not be parsed"
printf '%s' "$_body" | jq -e 'type == "object"' > /dev/null 2>&1 \
  || permit_undetermined "the API response was not an object"

# --- AC5, the 200-shaped case: a body with no usable task ---
NEXT_IDENT=$(printf '%s' "$_body" \
  | jq -r 'try (if (.data.identifier | type) == "string" then .data.identifier else "" end) catch ""' \
    2>/dev/null || printf '')
# A 200 carrying no usable identifier is the other shape of state 1.
[ -n "$NEXT_IDENT" ] || permit_state "1 (no claimable task remains)"

# This is the only server-controlled string that reaches the block message, so
# it is refused rather than sanitised if it is not identifier-shaped — a second
# line of defence for AC8 as much as a correctness check.
case "$NEXT_IDENT" in
  *[!A-Za-z0-9_.:-]*)
    permit_undetermined "the next task identifier is not identifier-shaped" ;;
esac
# Length folded in beside the charset test so the halves agree: the PowerShell
# twin checks both inside Test-IdentifierShaped, and a bare exit here made the
# same input silent on one half and reported on the other.
[ "${#NEXT_IDENT}" -le 64 ] \
  || permit_undetermined "the next task identifier is longer than 64 characters"

# --- The re-block guard ---
_count=$(read_block_count "$COMPLETED_IDENT")
if [ "$((_count + 1))" -gt "$STOP_GATE_MAX_BLOCKS" ]; then
  # PERMIT, and deliberately do NOT delete the counter. Deleting it here is
  # what made the budget per-counter-lifetime instead of per-completion: the
  # next stop started from zero and the cycle ran 2,2,0,2,2,0 forever, so every
  # later session paid two more blocks for the same stale completion. Leaving
  # the spent record in place makes "at most N refusals for ONE unfollowed
  # completion" true as written. It is still cleared at the two points that
  # genuinely end this completion's life — the loop-state file disappearing, or
  # its identifier changing — both handled above.
  printf 'stride-stop-gate: already refused this stop %s time(s) for %s\n' \
    "$_count" "$COMPLETED_IDENT" >&2
  permit_undetermined "the re-block budget for this completion is spent"
fi

# WRITE FIRST, AND PERMIT IF THE WRITE FAILS. The order is load-bearing: a
# block this gate cannot count is a block it cannot bound, and an unbounded
# block wedges the session. This guard exists precisely because wedging is
# worse than missing a gate, so its own failure has to resolve on the
# missing-a-gate side.
mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null \
  || permit_undetermined "the .stride directory could not be created"
if ! printf '%s %s\n' "$COMPLETED_IDENT" "$((_count + 1))" > "$BLOCK_COUNTER_FILE" 2>/dev/null; then
  permit_undetermined "the block count could not be recorded, and an uncounted block cannot be bounded"
fi

# --- AC1 + AC2 ---
# The identifier named is the CLAIMABLE task from /api/tasks/next, never the
# loop-state file's identifier, which names the task just COMPLETED. Naming
# that one would tell the agent to claim work it has already finished.
emit_block "Stride: this session cannot end yet. The last completed task recorded no review requirement, and Stride's Ready column still has a claimable task: ${NEXT_IDENT}. Claim it with the stride:stride-workflow skill, which clears this gate. To stop anyway, stop again — this gate refuses at most ${STOP_GATE_MAX_BLOCKS} time(s) for one unfollowed completion — or set STRIDE_ALLOW_STOP=1."
