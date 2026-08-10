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
# section and appended to the env cache for the follow-up PATCH.
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
Assert-Contains "8f: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID=7" $agEnvCacheF
Assert-Contains "8f: env cache carries GOAL_IDENTIFIER" "GOAL_IDENTIFIER=G7" $agEnvCacheF

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
Assert-Contains "8j: surviving cache carries GOAL_ID" "GOAL_ID=7" $agEnvCacheJ
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
Assert-Contains "8l: cached copy collapses the newline to a space" "GOAL_TITLE=line1 line3" $agEnvCacheL

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
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = '1'
try {
    $toStart = [DateTimeOffset]::UtcNow
    $r = Invoke-HookScript -InputJson $claimJson11 -Phase 'post' -ProjectDir $toProj
    $toWall = ([DateTimeOffset]::UtcNow - $toStart).TotalSeconds
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "11a: timed-out hook exits 2 (blocking failure)" 2 $r.ExitCode
Assert-Contains "11a: stderr names the hook and budget" "Stride before_doing hook command 2/3 timed out after 1s budget" $r.Stderr
Assert-Contains "11a: failure JSON marks timed_out" '"timed_out":true' $r.Stdout
Assert-Contains "11a: failure JSON carries exit 124" '"exit_code":124' $r.Stdout
Assert-Contains "11a: failure JSON carries the budget" '"budget_seconds":1' $r.Stdout
if (Test-Path (Join-Path $toProj 'should_not_exist.txt')) {
    Write-Host "  FAIL: 11a: commands after the timeout must not run" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 11a: commands after the timeout do not run" -ForegroundColor Green
    $script:PASS++
}
if ($toWall -lt 20) {
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
if ($srvWall -lt 20) {
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
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = '4'
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
Assert-Contains "11d: budget reported is the section budget" '"budget_seconds":4' $r.Stdout
if ($spanWall -lt 15) {
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
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = '1'
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

# 14b: The upload filter drops claim-dirty unchanged entries and the two
# dot-files, keeps task work and re-modified entries.
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
Set-Content -Path (Join-Path $blUpProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $blUpProj '.stride-changed-files.json') `
    -Value '[{"path":"pre.txt","diff":"pre-existing"},{"path":"remod.txt","diff":"re-modified"},{"path":"work.txt","diff":"task work"},{"path":".stride_auth.md","diff":"SECRET"},{"path":".stride.md","diff":"hook file"}]' -Encoding UTF8
Set-Content -Path (Join-Path $blUpProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

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
Assert-Contains "15b: truncated claim recovers identifier from the canonical file" "TASK_IDENTIFIER=W609" $d15bCache

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
Assert-Contains "16a: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID=55" $w16aCache

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
    Assert-Contains "17a: claim records the POST-pull branch point as TASK_BASE_REF" "TASK_BASE_REF=$postPull" $d142Cache
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
$env:STRIDE_HOOK_TIMEOUT_OVERRIDE = '1'
try {
    $rTo = Invoke-HookScript -InputJson $d230Complete -Phase 'pre' -ProjectDir $d230ToProj
} finally {
    Remove-Item Env:STRIDE_HOOK_TIMEOUT_OVERRIDE -ErrorAction SilentlyContinue
}
Assert-Exit "18b: a budget kill also blocks the completion" 2 $rTo.ExitCode
Assert-Contains "18b: stderr says TIMED OUT and names the budget" `
    "Stride after_doing hook command 2/3 timed out after 1s budget" $rTo.Stderr
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
