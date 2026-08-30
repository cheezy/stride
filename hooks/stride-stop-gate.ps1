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

# How many times this gate refuses ONE unfollowed completion before letting the
# session go. The intended path needs exactly one block — the claim that
# follows clears the loop state — so 2 leaves a single block of margin.
# Wedging a session is strictly worse than missing a gate.
$MaxBlocks = 2
if ($env:STRIDE_STOP_GATE_MAX_BLOCKS) {
    $parsedMax = 0
    if ([int]::TryParse($env:STRIDE_STOP_GATE_MAX_BLOCKS, [ref]$parsedMax) -and $parsedMax -ge 0) {
        $MaxBlocks = $parsedMax
    }
}

# --- Escape hatch ---
if ($env:STRIDE_ALLOW_STOP -eq '1') { exit 0 }

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

# --- AC3: no loop state, nothing to gate on ---
if (-not (Test-Path -LiteralPath $LoopStateFile)) {
    Reset-BlockCounter
    exit 0
}

# --- AC6, plus every malformed-file case, in one rule ---
# Only the literal JSON boolean false proceeds.
$loop = $null
try {
    $loop = (Get-Content -LiteralPath $LoopStateFile -Raw -ErrorAction Stop) | ConvertFrom-Json
} catch {
    Reset-BlockCounter
    exit 0
}
if ($null -eq $loop -or $loop -isnot [PSCustomObject]) { Reset-BlockCounter; exit 0 }
if ($loop.PSObject.Properties.Match('needs_review').Count -eq 0) { Reset-BlockCounter; exit 0 }
if ($loop.needs_review -isnot [bool]) { Reset-BlockCounter; exit 0 }
if ($loop.needs_review -ne $false) { Reset-BlockCounter; exit 0 }

$completedIdent = ''
if ($loop.PSObject.Properties.Match('identifier').Count -gt 0) {
    $completedIdent = [string]$loop.identifier
}
if (-not (Test-IdentifierShaped -Value $completedIdent)) { exit 0 }

# --- The network leg, reached only when the local evidence already says block ---
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

$apiBase = Resolve-StrideApiUrl
$token = Resolve-StrideApiToken
if (-not $apiBase -or -not $token) { exit 0 }

# --- AC7 ---
# -UseBasicParsing and NOT -SkipHttpErrorCheck: that parameter is 7.0+ and is
# denylisted for 5.1 compatibility (D277), so a non-2xx THROWS on both hosts
# and is caught below, which is the permit path anyway.
$statusCode = 0
$body = ''
try {
    $resp = Invoke-WebRequest -Uri "$apiBase/api/tasks/next" `
        -Headers @{ Authorization = "Bearer $token" } `
        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $statusCode = [int]$resp.StatusCode
    $body = [string]$resp.Content
} catch {
    # AC4: transport failure, DNS failure, timeout, and every non-2xx status
    # (including the 404 an empty Ready queue returns) land here. All permit.
    exit 0
}

if ($statusCode -ne 200) { exit 0 }
if (-not $body) { exit 0 }

$parsed = $null
try { $parsed = $body | ConvertFrom-Json } catch { exit 0 }
if ($null -eq $parsed -or $parsed -isnot [PSCustomObject]) { exit 0 }
if ($parsed.PSObject.Properties.Match('data').Count -eq 0) { exit 0 }
$data = $parsed.data
if ($null -eq $data -or $data -isnot [PSCustomObject]) { exit 0 }
if ($data.PSObject.Properties.Match('identifier').Count -eq 0) { exit 0 }
if ($data.identifier -isnot [string]) { exit 0 }

$nextIdent = [string]$data.identifier

# The only server-controlled string that reaches the block message, so it is
# refused rather than sanitised — a second line of defence for AC8.
if (-not (Test-IdentifierShaped -Value $nextIdent)) {
    if ($nextIdent) {
        [Console]::Error.WriteLine('stride-stop-gate: the next task identifier is not identifier-shaped; permitting the stop')
    }
    exit 0
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
    [Console]::Error.WriteLine("stride-stop-gate: already refused this stop $count time(s) for $completedIdent; permitting the stop")
    exit 0
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
    [Console]::Error.WriteLine('stride-stop-gate: could not record the block count; permitting the stop rather than blocking unbounded')
    exit 0
}

# --- AC1 + AC2 ---
# The identifier named is the CLAIMABLE task from /api/tasks/next, never the
# loop-state file's identifier, which names the task just COMPLETED.
Invoke-Block -Reason ("Stride: this session cannot end yet. The last completed task recorded no review requirement, and Stride's Ready column still has a claimable task: {0}. Claim it with the stride:stride-workflow skill, which clears this gate. To stop anyway, stop again — this gate refuses at most {1} time(s) for one unfollowed completion — or set STRIDE_ALLOW_STOP=1." -f $nextIdent, $MaxBlocks)
