# test-stride-hook.ps1 — Tests for stride-hook.ps1 PowerShell hook script
#
# Mirrors all 6 test groups from test-stride-hook.sh.
# Self-contained — no Pester or external dependencies.
#
# Usage: pwsh test-stride-hook.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
function Invoke-HookScript {
    param(
        [string]$InputJson,
        [string]$Phase,
        [string]$ProjectDir
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
# the snapshot before PUT. The ps1 has no capture step, so this upload-side
# filter is the equivalent enforcement point. A same-named file in a
# subdirectory is kept; the legitimate change is kept.
$exclProj = Join-Path $TmpDir 'put-exclude-project'
New-Item -ItemType Directory -Path $exclProj -Force | Out-Null
Set-Content -Path (Join-Path $exclProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-changed-files.json') `
    -Value '[{"path":".stride-diff-upload-state","diff":"state body"},{"path":"lib/foo.ex","diff":"real patch"},{"path":"sub/.stride-changed-files.json","diff":"user file"},{"path":".stride-changed-files.json","diff":"snapshot body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

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

# 7e: No TASK_ID in env cache → finalize no-ops
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
$noIdCmd = 'curl -X PATCH http://stride.example.com/api/tasks/99/complete -H "Authorization: Bearer tok"'
$noIdJson = "{`"tool_input`":{`"command`":`"$noIdCmd`"}}"
$r = Invoke-HookScript -InputJson $noIdJson -Phase 'pre' -ProjectDir $noIdProj
Assert-Exit "7e: hook exits 0 with no TASK_ID" 0 $r.ExitCode

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

# 8e: mark_reviewed URL also routes after_goal (parity with /complete).
$agInputMr = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' `
    -HookNames @('after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputMr -Phase 'post' -ProjectDir $agProj
Assert-Exit "8e: end-to-end after_goal on mark_reviewed exits 0" 0 $r.ExitCode
Assert-Contains "8e: mark_reviewed runs after_review" "after_review_ran" $r.Stdout
Assert-Contains "8e: mark_reviewed runs after_goal" "after_goal_ran" $r.Stdout

# ============================================================
# Test Group 9: early upload + before_review self-heal (W1095,
# mirrors test-stride-hook.sh Groups 12 and 13)
# ============================================================
# The ps1 script has no capture step — the pre-seeded on-disk snapshot is
# the source of truth — so the bash capture-content assertions translate to
# upload-ordering and state-file assertions here. Unreachable-URL cases use
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
    Assert-Contains "10a: inline JSON writes the identifier" "TASK_IDENTIFIER=W42" $cacheA
    Assert-Contains "10a: inline JSON sets TASK_BASE_REF to current HEAD" "TASK_BASE_REF=$headA" $cacheA

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
    Assert-Contains "10b: persisted file supplies the identifier" "TASK_IDENTIFIER=W77" $cacheB
    Assert-Contains "10b: persisted file path sets TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headB" $cacheB

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
    Assert-Contains "10c: garbage stdout still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headC" $cacheC
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
    Assert-Contains "10d: missing persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headD" $cacheD

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
    Assert-Contains "10g: non-JSON persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headG" $cacheG

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
    Assert-Contains "10h: absent cache is created with TASK_BASE_REF at HEAD" "TASK_BASE_REF=$headH" $cacheH
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
    Assert-Contains "10i: persisted path with spaces is recovered" "TASK_IDENTIFIER=W88" $cacheI

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
    Assert-Contains "10j: id-only persisted payload caches the identifier" "TASK_IDENTIFIER=W99" $cacheJ
    Assert-Contains "10j: id-only persisted payload sets TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headJ" $cacheJ
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================"
$Total = $script:PASS + $script:FAIL
Write-Host "Results: $($script:PASS) passed, $($script:FAIL) failed (out of $Total)"
Write-Host "========================================"

} finally {
    # Cleanup
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}

if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
