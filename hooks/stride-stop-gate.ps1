# stride-stop-gate.ps1 — Stop gate: refuses to end a session while a claimable
# Stride task remains.
#
# PowerShell companion to stride-stop-gate.sh for native Windows. The bash half
# execs this script when it detects Windows; hooks.json only ever registers the
# .sh.
#
# INPUT CONTRACT — $env:CLAUDE_PROJECT_DIR/.stride/.loop-state.json, written on
# a successful completion by stride-hook's W2123 path and cleared on ANY claim.
# Exactly four keys:
#   {"identifier":"W123","needs_review":false,"completed_at":"<ISO8601-Z>","session_id":"<id>"}
# Its presence means a completion happened and no claim has followed it yet;
# its absence means there is nothing to gate on.
#
# BLOCK CONDITION (the only one): the loop-state file exists AND its
# needs_review is the JSON boolean false AND GET /api/tasks/next answers 200
# with a non-empty .data.identifier.
#
# PERMIT — everything else: no file, malformed file, needs_review not false,
# no API URL or token, transport failure, timeout, any non-200 (an empty Ready
# queue answers 404, so "no task" and "non-200" are the same wire event), a
# 200 with no usable identifier, or a spent re-block budget.
#
# EXIT 2 IS THE LOAD-BEARING MECHANISM; the stdout object is best-effort
# enrichment carrying both documented Stop output spellings — the current
# hookSpecificOutput form and the legacy decision/reason pair — in ONE
# document, since two concatenated documents fail a strict parse (D238).
#
# Registered for Stop ONLY, never SubagentStop.
#
# Never echoes the token: it is read by Resolve-StrideApiToken, reaches exactly
# one place — the Authorization header — and is never logged or interpolated.
#
# DOCUMENTED DIVERGENCE from the bash half: Windows PowerShell 5.1 has no
# connect-timeout, so -TimeoutSec bounds the whole request and this half has
# ONE bound where bash has two (--connect-timeout 3 plus --max-time 5). The
# hooks.json timeout remains an independent backstop on both.
#
# Exit codes:
#   0 — stop permitted
#   2 — stop blocked

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$LoopStateFile = Join-Path $ProjectDir '.stride/.loop-state.json'
$BlockCounterFile = Join-Path $ProjectDir '.stride/.stop-gate-blocks'
# (W2125) The record carrying the two terminal states that cannot be derived —
# an explicit user halt, and an unrecoverable error. The full contract is in
# skills/stride-workflow/terminal-states.md.
$TerminalStateFile = Join-Path $ProjectDir '.stride/.terminal-state.json'
# (W2178) Written only by stride-hook; read here as a POINTER, never as a fact:
# its TASK_IDENTIFIER survives a completion, an unclaim, and the session that
# wrote it. The live task is the fact.
$EnvCacheFile = Join-Path $ProjectDir '.stride-env-cache'
# BLOCK CONDITIONS (two, mutually exclusive — see the shell half's header for
# the full statement). The loop-state file's presence selects which applies, so
# at most ONE API call is made on any path: an unfollowed completion, or a held
# claim that was never completed.

# How many times this gate refuses ONE unfollowed completion before letting the
# session go. The intended path needs exactly one block — the claim that
# follows clears the loop state — so 2 leaves a single block of margin.
# Wedging a session is strictly worse than missing a gate.
$MaxBlocks = 2
if ($env:STRIDE_STOP_GATE_MAX_BLOCKS) {
    # Nine digits maximum, matching the bash twin. TryParse already rejects an
    # oversized value here, but the halves must agree on WHICH values are
    # honoured, not merely on failing safe.
    $parsedMax = 0
    if ($env:STRIDE_STOP_GATE_MAX_BLOCKS -cmatch '\A[0-9]{1,9}\z' -and
        [int]::TryParse($env:STRIDE_STOP_GATE_MAX_BLOCKS, [ref]$parsedMax) -and $parsedMax -ge 0) {
        $MaxBlocks = $parsedMax
    }
}

# The gate speaks only when it had something to gate on: the quiet paths — no
# jq, a re-firing stop, and above all the no-loop-state case that fires on every
# Stop event in any project — stay silent, so the one channel carrying the state
# does not become noise a reader learns to skip.
function Exit-PermitState {
    param([string]$State)
    [Console]::Error.WriteLine("stride-stop-gate: permitting the stop under sanctioned terminal state $State")
    exit 0
}

# A stop fitting none of the four is not filed under a fifth state — it is
# reported as what it is. The gate still permits; the stop becomes visible.
function Exit-PermitUndetermined {
    param([string]$Why)
    [Console]::Error.WriteLine("stride-stop-gate: permitting the stop, but no sanctioned terminal state could be determined ($Why) — this stop is unsanctioned")
    exit 0
}

# --- Escape hatch ---
if ($env:STRIDE_ALLOW_STOP -eq '1') {
    # Named rather than silent: it fires only when a human deliberately set the
    # variable, so there is no noise cost, and "the override was used and no
    # sanctioned state was established" is what the record should show.
    Exit-PermitUndetermined -Why 'STRIDE_ALLOW_STOP=1 was set'
}

function Reset-BlockCounter {
    if (Test-Path -LiteralPath $BlockCounterFile) {
        Remove-Item -LiteralPath $BlockCounterFile -Force -ErrorAction SilentlyContinue
    }
}

# Blocks recorded so far for THIS completion. Keyed on the loop-state
# identifier — the task just completed — and NOT on the claimable task's
# identifier, which can change between attempts when another agent takes the
# head of the queue; keying on that would silently reset the count and restore
# the unbounded loop this guard prevents.
function Get-BlockCount {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $BlockCounterFile)) { return 0 }
    try {
        $line = (Get-Content -LiteralPath $BlockCounterFile -Raw -ErrorAction Stop).Trim()
    } catch {
        return 0
    }
    if (-not $line) { return 0 }
    $parts = $line -split '\s+'
    if ($parts.Count -lt 2) { return 0 }
    if ($parts[0] -cne $Key) { return 0 }
    $n = 0
    if (-not [int]::TryParse($parts[1], [ref]$n)) { return 0 }
    if ($n -lt 0) { return 0 }
    return $n
}

function Resolve-StrideApiUrl {
    $auth = Join-Path $ProjectDir '.stride_auth.md'
    $url = ''
    if (Test-Path -LiteralPath $auth) {
        $line = Get-Content -LiteralPath $auth | Where-Object { $_ -match '\*\*API URL:\*\*' } | Select-Object -First 1
        if ($line -and $line -match 'https?://[A-Za-z0-9._:/-]+') { $url = $Matches[0] }
    }
    return $url
}

# The production `**API Token:**` line, deliberately NOT `**Local API Token:**`.
# Never logged.
function Resolve-StrideApiToken {
    $auth = Join-Path $ProjectDir '.stride_auth.md'
    $token = ''
    if (Test-Path -LiteralPath $auth) {
        $line = Get-Content -LiteralPath $auth | Where-Object { $_ -match '\*\*API Token:\*\*' } | Select-Object -First 1
        if ($line -and $line -match '`([^`]+)`') { $token = $Matches[1] }
    }
    return $token
}

# Same charset rule the writer enforces (loop_state_safe / Test-LoopStateSafe).
function Test-IdentifierShaped {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value.Length -gt 64) { return $false }
    return ($Value -cmatch '\A[A-Za-z0-9_.:-]+\z')
}

# ONE JSON document on stdout — two concatenated documents fail a strict parse,
# which this repo has already been bitten by (D238) — carrying both candidate
# Stop output spellings as sibling keys.
function Invoke-Block {
    param([string]$Reason)
    # Carries BOTH documented spellings as sibling keys of ONE object: the
    # current hookSpecificOutput form, and the legacy decision/reason pair that
    # Anthropic's own reference stop hook still emits. A harness honouring only
    # the legacy names would otherwise get the block (from exit 2) without the
    # reason text, which is the one thing this object exists to deliver.
    $obj = [ordered]@{
        decision           = 'block'
        reason             = $Reason
        systemMessage      = $Reason
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'Stop'
            permissionDecision       = 'deny'
            permissionDecisionReason = $Reason
        }
    }
    Write-Output ($obj | ConvertTo-Json -Compress -Depth 5)
    [Console]::Error.WriteLine("stride-stop-gate: $Reason")
    exit 2
}

# --- Read the Stop payload ---
$rawInput = @($input) -join "`n"

# Defensive read of stop_hook_active: where it exists it marks a Stop
# re-firing after this hook's own block. It is NOT in the current published
# schema, so it is a bonus and never depended on — the counter is the guarantee.
if ($rawInput) {
    try {
        $stopObj = $rawInput | ConvertFrom-Json
        if ($null -ne $stopObj -and
            $stopObj.PSObject.Properties.Match('stop_hook_active').Count -gt 0 -and
            $stopObj.stop_hook_active -eq $true) {
            exit 0
        }
    } catch {
        # An unparseable Stop payload is not a reason to block.
    }
}

# --- Terminal states 3 and 4, from the recorded file (W2125) ---
# Deliberately BEFORE the loop-state test: a halt and an unrecoverable error are
# terminal whether or not a completion is awaiting a claim. Every rejection
# falls through to the normal logic rather than exiting, so a malformed or
# foreign record can never disable the gate — only fail to permit.
if (Test-Path -LiteralPath $TerminalStateFile) {
    $tsRec = $null
    try {
        $tsRaw = (Get-Content -LiteralPath $TerminalStateFile -Raw -ErrorAction Stop)
        # The raw text must be a JSON OBJECT. ConvertFrom-Json returns a
        # one-element array as the element itself, so `[ {...} ]` silently
        # became the record on this half while the bash twin refused it — the
        # same file ending a session on one host and not the other.
        if ($tsRaw -and $tsRaw.TrimStart() -clike '{*') {
            $tsRec = $tsRaw | ConvertFrom-Json
        }
    } catch {
        $tsRec = $null
    }
    if ($null -ne $tsRec -and $tsRec -is [PSCustomObject]) {
        $tsKind = ''
        if ($tsRec.PSObject.Properties.Match('kind').Count -gt 0 -and $tsRec.kind -is [string]) {
            $tsKind = [string]$tsRec.kind
        }
        $tsSid = ''
        if ($tsRec.PSObject.Properties.Match('session_id').Count -gt 0) {
            $tsSid = [string]$tsRec.session_id
        }

        # Session identity first, because it is exact: a record from an earlier
        # session is recognisably foreign and is ignored. That is what stops a
        # stale record silently switching the gate off, which is strictly worse
        # than a refused stop.
        $tsCurrent = ''
        if ($rawInput) {
            try {
                $tsIn = $rawInput | ConvertFrom-Json
                if ($null -ne $tsIn -and $tsIn.PSObject.Properties.Match('session_id').Count -gt 0) {
                    $tsCurrent = [string]$tsIn.session_id
                }
            } catch {
                $tsCurrent = ''
            }
        }
        if (-not $tsCurrent) { $tsCurrent = [string]$env:CLAUDE_SESSION_ID }

        # 'unknown' is a SENTINEL, not an identity. Letting the exact-match
        # branch fire when both sides carried it skipped the window entirely and
        # honoured a six-year-old record — the gate silently off, which this
        # design ranks as the worst outcome available.
        $tsOk = $false
        # recorded_at_epoch must be a NUMBER here, not merely present: the bash
        # twin populates its epoch only for a JSON number, so a string, null or
        # object epoch was honoured on this half and ignored on the other — the
        # same divergence family as the four already closed, and the fallback
        # branch below already got this right.
        $tsEpochTyped = $false
        if ($tsRec.PSObject.Properties.Match('recorded_at_epoch').Count -gt 0 -and
            $tsRec.recorded_at_epoch -isnot [string]) {
            $tsEpochProbe = [int64]0
            if ([int64]::TryParse([string]$tsRec.recorded_at_epoch, [ref]$tsEpochProbe)) {
                $tsEpochTyped = $true
            }
        }
        if ($tsSid -and ($tsSid -cne 'unknown') -and
            $tsCurrent -and ($tsCurrent -cne 'unknown') -and
            ($tsSid -ceq $tsCurrent) -and $tsEpochTyped) {
            $tsOk = $true
        } elseif (($tsSid -ceq 'unknown') -and ((-not $tsCurrent) -or ($tsCurrent -ceq 'unknown'))) {
            # Neither side knows its session, so identity cannot decide it.
            # Fall back to a short window — heuristic only where it must be.
            # The writer stores the literal 'unknown' rather than a uuid for
            # exactly this reason: a uuid is foreign to every session, so state
            # 3 would be permanently unreachable with nothing to show why.
            if ($tsRec.PSObject.Properties.Match('recorded_at_epoch').Count -gt 0) {
                $tsEpoch = 0
                if ($tsRec.recorded_at_epoch -isnot [string] -and
                    [int64]::TryParse([string]$tsRec.recorded_at_epoch, [ref]$tsEpoch)) {
                    $tsAge = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $tsEpoch
                    if ($tsAge -ge 0 -and $tsAge -le 900) { $tsOk = $true }
                }
            }
        }

        if ($tsOk) {
            if ($tsKind -ceq 'halt') {
                # The record states THAT a halt occurred and WHEN — it carries
                # no quote of the user's message, by contract. A user's words
                # can contain a pasted credential, customer data, or a private
                # path, and this file persists past the turn, so the transcript
                # keeps the words and the record keeps only the fact and the
                # timestamp that locate them. kind, session and epoch are
                # already validated above.
                Exit-PermitState -State '3 (the user halted the loop)'
            } elseif ($tsKind -ceq 'error') {
                # Machine-produced evidence, not an assertion. A recoverable
                # hook failure is not this state; honouring one would permit any
                # stop after any failed hook — a fifth state in state 4's
                # clothes.
                # exit_code is checked WIDTH-INDEPENDENTLY: ConvertFrom-Json
                # yields Int64 for a JSON number, so `-is [int]` (Int32)
                # rejects a perfectly valid record and state 4 becomes
                # unreachable on this half alone — a divergence in exactly the
                # check the two halves must agree on. Strings are still
                # refused, matching the bash twin's `type == "number"`.
                $tsExit = $null
                if ($tsRec.PSObject.Properties.Match('exit_code').Count -gt 0 -and
                    $tsRec.exit_code -isnot [string]) {
                    $tsExitParsed = [int64]0
                    if ([int64]::TryParse([string]$tsRec.exit_code, [ref]$tsExitParsed)) {
                        $tsExit = $tsExitParsed
                    }
                }
                # Bounded, machine-produced evidence only: a non-zero exit
                # code and a step name from the workflow's own vocabulary. NO
                # command string and NO stderr capture — a Stride command
                # routinely carries a bearer token and stderr carries whatever
                # the failing tool printed, and neither belongs in a file that
                # outlives the turn.
                $tsStep = ''
                if ($tsRec.PSObject.Properties.Match('step').Count -gt 0 -and
                    $tsRec.step -is [string]) {
                    $tsStep = [string]$tsRec.step
                }
                if ($null -ne $tsExit -and $tsExit -ne 0 -and
                    $tsExit -gt -2147483648 -and $tsExit -lt 2147483648 -and
                    ($tsStep -cmatch '\A[a-z_]{1,32}\z')) {
                    Exit-PermitState -State '4 (an unrecoverable error was recorded)'
                }
            }
        }
    }
}

# --- No loop state: nothing to gate on, OR a claim is still held (W2178) ---
#
# The loop-state file is written by a completion and cleared by ANY claim, so
# its presence names the LAST lifecycle event. Present -> a completion, and the
# W2124 condition below applies unchanged. Absent -> a claim with no completion
# after it, which is the second block condition. The two are the sides of one
# file test, so they are mutually exclusive and the gate still makes AT MOST
# ONE bounded API call on every path.
if (-not (Test-Path -LiteralPath $LoopStateFile)) {
    # LOCAL PRE-FILTER, and a filter rather than the evidence. Both keys are
    # refreshed only at claim time or from a hook's own server-supplied env, and
    # a claim whose response did not parse KEEPS the previous task's values -- so
    # a passing pre-filter proves nothing, and a failing one costs only a missed
    # gate, which is the safe side. What it buys is the thing an exit-path hook
    # cannot afford to lose: on the overwhelming majority of stops it is one
    # file read and no network.
    $heldIdent = ''
    $heldInProgress = $false
    if (Test-Path -LiteralPath $EnvCacheFile) {
        foreach ($line in (Get-Content -LiteralPath $EnvCacheFile -ErrorAction SilentlyContinue)) {
            # The writer single-quote escapes values. Anchored and case-sensitive,
            # matching the shell half's grep exactly so the two cannot disagree.
            if (-not $heldIdent -and $line -cmatch "\ATASK_IDENTIFIER='([A-Za-z0-9_.:-]{1,64})'\z") {
                $heldIdent = $Matches[1]
            }
            if ($line -ceq "TASK_STATUS='in_progress'") { $heldInProgress = $true }
        }
    }
    # A dot segment passes the charset and would be normalised away by the URL,
    # aiming the request at a different path. Refused by name.
    if ($heldIdent -eq '.' -or $heldIdent -eq '..') { $heldIdent = '' }
    # Test-IdentifierShaped as a second gate, so a change to either shape rule
    # cannot silently make the halves disagree.
    if ((-not $heldIdent) -or (-not (Test-IdentifierShaped -Value $heldIdent)) -or (-not $heldInProgress)) {
        # The pre-existing path, unchanged and still silent.
        Reset-BlockCounter
        exit 0
    }

    $heldBase = Resolve-StrideApiUrl
    $heldToken = Resolve-StrideApiToken
    if ((-not $heldBase) -or (-not $heldToken)) {
        Exit-PermitUndetermined -Why 'no API URL or token could be resolved'
    }

    # Same shape as the completion branch's call: -UseBasicParsing and NOT
    # -SkipHttpErrorCheck, which is 7.0+ and denylisted for 5.1 (D277), so a
    # non-2xx throws and is caught below. Carries forward the documented
    # divergence that this half has ONE timeout bound where the shell half has
    # two.
    $heldStatus = ''
    $heldExpiry = ''
    $heldCompletedBy = $null
    $heldHasCompletedBy = $false
    $heldIdentEcho = ''
    try {
        $heldResp = Invoke-WebRequest `
            -Uri "$heldBase/api/tasks/$heldIdent`?fields=status,claim_expires_at,completed_by_id" `
            -Headers @{ Authorization = "Bearer $heldToken" } `
            -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop
        $heldStatusCode = [int]$heldResp.StatusCode
        $heldBody = [string]$heldResp.Content
    } catch {
        $heldThrown = 0
        try {
            if ($_.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and
                $null -ne $_.Exception.Response) {
                $heldThrown = [int]$_.Exception.Response.StatusCode
            }
        } catch {
            $heldThrown = 0
        }
        # A 404 here is NOT state 1. State 1 is a statement about the Ready
        # queue, which this call never asks about. It means the pointer names
        # nothing this token can see, so no claim is held and the record is dead.
        if ($heldThrown -eq 404) {
            Reset-BlockCounter
            Exit-PermitUndetermined -Why 'the claimed task could not be found'
        }
        if ($heldThrown -ne 0) {
            Exit-PermitUndetermined -Why "the API answered $heldThrown"
        }
        Exit-PermitUndetermined -Why 'the API could not be reached, or the request timed out'
    }
    # No 404 arm here, deliberately -- without -SkipHttpErrorCheck every non-2xx
    # THROWS and is handled in the catch above. What IS reachable is a 2xx that
    # is not 200 (a 201, 202 or 204), which establishes nothing about a held
    # claim. The shell half permits the same shape at its own non-200 test, and
    # omitting this arm was a divergence rather than a simplification.
    if ($heldStatusCode -ne 200) {
        Exit-PermitUndetermined -Why "the API answered $heldStatusCode"
    }
    if (-not $heldBody) {
        Exit-PermitUndetermined -Why 'the API returned an empty body'
    }
    try {
        $heldDoc = $heldBody | ConvertFrom-Json -ErrorAction Stop
        $heldData = $heldDoc.data
        # Set-StrictMode -Version Latest makes reading an absent property a
        # terminating error, so every field is probed before it is read.
        # -is [string], not a bare cast: a NUMERIC identifier would satisfy the
        # cast and compare equal below, where the shell half's jq equality
        # refuses it. Same rule as the completion branch's own type check.
        if ($heldData.PSObject.Properties.Match('identifier').Count -gt 0 -and
            $heldData.identifier -is [string]) {
            $heldIdentEcho = [string]$heldData.identifier
        }
        if ($heldData.PSObject.Properties.Match('status').Count -gt 0) {
            $heldStatus = [string]$heldData.status
        }
        # ConvertFrom-Json on this half does NOT hand back the string the server
        # sent: it recognises the ISO-8601 shape and yields a [DateTime]. The
        # shell half compares the raw text, so taking only the string case here
        # left the expiry empty on every real response and permitted every held
        # claim -- the halves agreeing on the code and disagreeing on the
        # behaviour. Both types are handled, and a DateTime is rendered back to
        # the same fixed-width UTC text the shell half compares.
        if ($heldData.PSObject.Properties.Match('claim_expires_at').Count -gt 0) {
            if ($heldData.claim_expires_at -is [string]) {
                $heldExpiry = [string]$heldData.claim_expires_at
            } elseif ($heldData.claim_expires_at -is [DateTime]) {
                $heldExpiry = ([DateTime]$heldData.claim_expires_at).ToUniversalTime().ToString(
                    "yyyy-MM-ddTHH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
        if ($heldData.PSObject.Properties.Match('completed_by_id').Count -gt 0) {
            $heldHasCompletedBy = $true
            $heldCompletedBy = $heldData.completed_by_id
        }
    } catch {
        Exit-PermitUndetermined -Why 'the claimed task response could not be parsed'
    }
    # The projection always carries id and identifier, so the answer can be
    # checked against the question. A gate that cannot say which task it is
    # refusing over must not refuse.
    if ($heldIdentEcho -cne $heldIdent) {
        Exit-PermitUndetermined -Why 'the API answered for a different task'
    }

    # THREE conditions, each separately load-bearing -- see the shell half for
    # the reasoning, which was verified against the server rather than assumed.
    if ($heldStatus -cne 'in_progress') {
        Reset-BlockCounter
        Exit-PermitUndetermined -Why 'the claimed task is no longer in progress'
    }
    if ($heldHasCompletedBy -and $null -ne $heldCompletedBy) {
        Reset-BlockCounter
        Exit-PermitUndetermined -Why 'the claimed task has already been completed'
    }
    # Fixed-width ISO-8601 UTC on both sides, compared ORDINALLY as text.
    # InvariantCulture and CompareOrdinal are both load-bearing: a th-TH host
    # renders the year as 2569 under the current culture, and PowerShell's own
    # -gt on strings is culture-aware, so either default would read every claim
    # as unexpired. The shell half compares the same two fixed-width strings.
    if ($heldExpiry -cnotmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z') {
        Reset-BlockCounter
        Exit-PermitUndetermined -Why 'the claimed task records no usable claim expiry'
    }
    $heldNow = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    if ([string]::CompareOrdinal($heldExpiry, $heldNow) -le 0) {
        Reset-BlockCounter
        Exit-PermitUndetermined -Why 'the claim on the task has expired'
    }

    # --- The SAME re-block budget, namespaced by fact rather than by file ---
    # The key is held:<IDENT>, not the bare identifier, so a session that burned
    # its budget refusing a held claim on W1 does not then find the budget spent
    # when it completes W1 and skip a real gate. One counter, one file, two keys.
    $heldKey = "held:$heldIdent"
    $heldCount = Get-BlockCount -Key $heldKey
    if (($heldCount + 1) -gt $MaxBlocks) {
        [Console]::Error.WriteLine("stride-stop-gate: already refused this stop $heldCount time(s) for $heldIdent")
        Exit-PermitUndetermined -Why 'the re-block budget for this held claim is spent'
    }
    # WRITE FIRST, AND PERMIT IF THE WRITE FAILS -- a block this gate cannot
    # count is a block it cannot bound, and an unbounded block wedges the
    # session.
    try {
        $heldDir = Split-Path -Parent $BlockCounterFile
        if (-not (Test-Path -LiteralPath $heldDir)) {
            New-Item -ItemType Directory -Path $heldDir -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $BlockCounterFile -Value ("{0} {1}" -f $heldKey, ($heldCount + 1)) `
            -Encoding UTF8 -ErrorAction Stop
    } catch {
        Exit-PermitUndetermined -Why 'the block count could not be recorded, and an uncounted block cannot be bounded'
    }

    # The identifier named is the HELD task -- the one the agent must act on.
    Invoke-Block -Reason "Stride: this session cannot end yet. Task $heldIdent is still claimed by this session and was never completed. Complete it with the stride:stride-workflow skill, or release it with POST /api/tasks/$heldIdent/unclaim — either clears this gate. To stop anyway, stop again — this gate refuses at most $MaxBlocks time(s) for one held claim — or set STRIDE_ALLOW_STOP=1."
}

# --- AC6, plus every malformed-file case, in one rule ---
# Only the literal JSON boolean false proceeds.
# A file that does not parse records no completion and no review requirement,
# so it cannot establish state 2 — and on this half these paths used to exit 0
# in total SILENCE, which is the invisible stop the four states exist to
# eliminate. Parse, type, and value are three separate questions.
$loop = $null
try {
    $loop = (Get-Content -LiteralPath $LoopStateFile -Raw -ErrorAction Stop) | ConvertFrom-Json
} catch {
    Reset-BlockCounter
    Exit-PermitUndetermined -Why 'the loop-state file could not be parsed'
}
# A value that PARSED but is not an object — an array, a bare string, a number,
# a boolean — reports the same reason bash does. Only a genuine ConvertFrom-Json
# failure is "could not be parsed": `[1,2,3]` parses perfectly well, and calling
# that a parse failure made the two halves give different reasons for the same
# file, which is the divergence family this gate keeps producing.
if ($null -eq $loop -or $loop -isnot [PSCustomObject]) {
    Reset-BlockCounter
    Exit-PermitUndetermined -Why 'the loop-state file records no usable needs_review'
}
if ($loop.PSObject.Properties.Match('needs_review').Count -eq 0 -or
    $loop.needs_review -isnot [bool]) {
    Reset-BlockCounter
    Exit-PermitUndetermined -Why 'the loop-state file records no usable needs_review'
}
if ($loop.needs_review -ne $false) {
    Reset-BlockCounter
    # Decided by the completion record alone; no API call is needed to
    # establish state 2, so this precedes the network leg.
    Exit-PermitState -State '2 (the completed task needs human review)'
}

$completedIdent = ''
if ($loop.PSObject.Properties.Match('identifier').Count -gt 0) {
    $completedIdent = [string]$loop.identifier
}
if (-not (Test-IdentifierShaped -Value $completedIdent)) {
    Exit-PermitUndetermined -Why 'the completed identifier is missing or not identifier-shaped'
}

# --- The network leg, reached only when the local evidence already says block ---

$apiBase = Resolve-StrideApiUrl
$token = Resolve-StrideApiToken
if (-not $apiBase -or -not $token) { Exit-PermitUndetermined -Why 'no API URL or token could be resolved' }

# --- AC7 ---
# -UseBasicParsing and NOT -SkipHttpErrorCheck: that parameter is 7.0+ and is
# denylisted for 5.1 compatibility (D277), so a non-2xx THROWS on both hosts
# and is caught below, which is the permit path anyway.
#
# -MaximumRedirection 0 because this request carries a Bearer token and Windows
# PowerShell 5.1 -- the runtime this file targets -- PRESERVES the Authorization
# header across redirects, including cross-origin ones; header stripping arrived
# only in PowerShell 6. Without it a 302 from the configured host replays the
# user's token to a host of the redirector's choosing. curl is invoked without
# -L on the other half, so following redirects here was also a divergence in
# exactly the token-containment property this gate is required to hold. A 3xx
# now throws into the catch and permits, matching curl.
$statusCode = 0
$body = ''
try {
    $resp = Invoke-WebRequest -Uri "$apiBase/api/tasks/next" `
        -Headers @{ Authorization = "Bearer $token" } `
        -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop
    $statusCode = [int]$resp.StatusCode
    $body = [string]$resp.Content
} catch {
    # Transport failure, DNS failure, timeout, and every non-2xx status land
    # here on this half, because a non-2xx throws. An empty Ready column
    # answers 404, which IS state 1 — so the status is recovered from the
    # exception where possible and only a genuinely unknown outcome is
    # reported as undetermined.
    $thrownCode = 0
    try {
        if ($_.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and
            $null -ne $_.Exception.Response) {
            $thrownCode = [int]$_.Exception.Response.StatusCode
        }
    } catch {
        $thrownCode = 0
    }
    if ($thrownCode -eq 404) {
        Exit-PermitState -State '1 (no claimable task remains)'
    }
    if ($thrownCode -ne 0) {
        Exit-PermitUndetermined -Why "the API answered $thrownCode"
    }
    Exit-PermitUndetermined -Why 'the API could not be reached, or the request timed out'
}

# No 404 arm here, deliberately. Without -SkipHttpErrorCheck (7.0+, denylisted
# for 5.1 by D277) every non-2xx THROWS, so a 404 is handled in the catch above
# and an arm for it on this path would be unreachable code pretending to be a
# permit path. What IS reachable here is a 2xx that is not 200 — a 201, 202 or
# 204 — which establishes nothing about a claimable task.
if ($statusCode -ne 200) { Exit-PermitUndetermined -Why "the API answered $statusCode" }
if (-not $body) { Exit-PermitUndetermined -Why 'the API returned an empty body' }

$parsed = $null
try { $parsed = $body | ConvertFrom-Json } catch { Exit-PermitUndetermined -Why 'the API response could not be parsed' }
# A 200 carrying no usable identifier is the other shape of state 1.
if ($null -eq $parsed -or $parsed -isnot [PSCustomObject]) { Exit-PermitUndetermined -Why 'the API response was not an object' }
if ($parsed.PSObject.Properties.Match('data').Count -eq 0) { Exit-PermitState -State '1 (no claimable task remains)' }
$data = $parsed.data
if ($null -eq $data -or $data -isnot [PSCustomObject]) { Exit-PermitState -State '1 (no claimable task remains)' }
if ($data.PSObject.Properties.Match('identifier').Count -eq 0) { Exit-PermitState -State '1 (no claimable task remains)' }
if ($data.identifier -isnot [string]) { Exit-PermitState -State '1 (no claimable task remains)' }

$nextIdent = [string]$data.identifier

# An EMPTY identifier is state 1, not undetermined. The bash twin reaches that
# verdict at its `[ -n "$NEXT_IDENT" ]` test, while this half used to fall
# through to the identifier-shape check below, where an empty string fails and
# reports undetermined — the same wire response yielding a different SANCTIONED
# STATE on the two halves, which is worse than either answer alone. A 200
# carrying an empty identifier means the queue offered nothing, which is state 1
# by definition; the shape check below exists for a non-empty value that is not
# identifier-shaped.
if ($nextIdent.Length -eq 0) { Exit-PermitState -State '1 (no claimable task remains)' }

# The only server-controlled string that reaches the block message, so it is
# refused rather than sanitised — a second line of defence for AC8.
if (-not (Test-IdentifierShaped -Value $nextIdent)) {
    Exit-PermitUndetermined -Why 'the next task identifier is not identifier-shaped'
}

# --- The re-block guard ---
$count = Get-BlockCount -Key $completedIdent
if (($count + 1) -gt $MaxBlocks) {
    # PERMIT, and deliberately do NOT delete the counter. Deleting it here made
    # the budget per-counter-lifetime instead of per-completion: the next stop
    # started from zero and the cycle ran 2,2,0,2,2,0 forever, so every later
    # session paid two more blocks for the same stale completion. Leaving the
    # spent record makes "at most N refusals for ONE unfollowed completion"
    # true as written. It is still cleared at the two events that genuinely end
    # this completion's life — the loop-state file disappearing, or its
    # identifier changing — both handled above.
    [Console]::Error.WriteLine("stride-stop-gate: already refused this stop $count time(s) for $completedIdent")
    Exit-PermitUndetermined -Why 'the re-block budget for this completion is spent'
}

# WRITE FIRST, AND PERMIT IF THE WRITE FAILS. The order is load-bearing: a
# block this gate cannot count is a block it cannot bound, and an unbounded
# block wedges the session. This guard exists because wedging is worse than
# missing a gate, so its own failure must resolve on the missing-a-gate side.
try {
    $strideDir = Join-Path $ProjectDir '.stride'
    if (-not (Test-Path -LiteralPath $strideDir)) {
        New-Item -ItemType Directory -Force -Path $strideDir -ErrorAction Stop | Out-Null
    }
    Set-Content -LiteralPath $BlockCounterFile -Value ("{0} {1}" -f $completedIdent, ($count + 1)) `
        -Encoding UTF8 -ErrorAction Stop
} catch {
    Exit-PermitUndetermined -Why 'the block count could not be recorded, and an uncounted block cannot be bounded'
}

# --- AC1 + AC2 ---
# The identifier named is the CLAIMABLE task from /api/tasks/next, never the
# loop-state file's identifier, which names the task just COMPLETED.
Invoke-Block -Reason ("Stride: this session cannot end yet. The last completed task recorded no review requirement, and Stride's Ready column still has a claimable task: {0}. Claim it with the stride:stride-workflow skill, which clears this gate. To stop anyway, stop again — this gate refuses at most {1} time(s) for one unfollowed completion — or set STRIDE_ALLOW_STOP=1." -f $nextIdent, $MaxBlocks)
