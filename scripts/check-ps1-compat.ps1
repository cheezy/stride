<#
.SYNOPSIS
    W2099: Windows PowerShell 5.1 static-compatibility worker for hooks/*.ps1.

.DESCRIPTION
    Runs PSScriptAnalyzer's PSUseCompatibleSyntax and PSUseCompatibleCmdlets
    against the plugin's PowerShell files, targeting Windows PowerShell 5.1.

    Invoke this through scripts/check-ps1-compat.sh, which checks that pwsh
    exists before calling here. This file is the worker, not the entry point.

    SCOPE OF THE GUARANTEE: 7-only *syntax*, and 7-only *cmdlet names* the 5.1
    profile knows about. That is all it can see. A clean run is NOT evidence
    the hook RUNS on 5.1 -- runtime verification is a separate job. The
    verified list of blind spots is in README.md, "What this gate cannot see".

    This script NEVER installs anything, and nothing in the plugin's hook path
    invokes it. Installing a module on a user's machine is not an acceptable
    hook side effect; the prerequisite is documented, never automated.

.PARAMETER Path
    Optional file or directory to scan instead of the repo's hooks/ directory.
    Used by the test suite's negative case to prove the gate can go red. The
    committed scope is hooks/*.ps1.

.PARAMETER SelfTestOnly
    Run only the self-test probe and exit. Proves the gate still detects
    7-only code without scanning the repo.

.NOTES
    Exit codes:
      0  clean -- self-test proved both rules live, and every file scanned OK
      1  real findings, OR the gate itself is broken/misconfigured
      2  tooling absent (PSScriptAnalyzer missing or too old)

    The 1-vs-2 split is deliberate: 1 means "the repo or the code has a
    problem", 2 means "this machine cannot answer the question". The test
    suite skips on 2 and fails on 1.
#>

[CmdletBinding()]
param(
    [string]$Path,
    [switch]$SelfTestOnly
)

$ErrorActionPreference = 'Stop'

# Pinned in one place; the message below and README.md must agree with it.
$PssaMinVersion = '1.25.0'
$InstallCmd = 'pwsh -NoProfile -Command "Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser"'

# ---------------------------------------------------------------------------
# Tooling: the module must be present. Fail with ONE clear line, never a
# PowerShell error record -- a stack trace here reads as a broken gate rather
# than a missing prerequisite, and sends the reader debugging the wrong thing.
#
# -MinimumVersion, not -RequiredVersion: a contributor already on a newer
# build should not be blocked. The pin lives in the documented INSTALL
# command, which is what the security consideration asks for -- so a fresh
# install is reproducible, while an existing newer one still works. The
# resolved version is printed on every run, so a different build is visible
# rather than silent.
# ---------------------------------------------------------------------------
try {
    Import-Module PSScriptAnalyzer -MinimumVersion $PssaMinVersion -ErrorAction Stop
}
catch {
    $firstLine = ($_.Exception.Message -split "`r?`n")[0]
    Write-Output "GATE UNAVAILABLE: PSScriptAnalyzer $PssaMinVersion or newer is not installed - the PowerShell 5.1 compatibility gate cannot run."
    Write-Output "  Reason: $firstLine"
    Write-Output "  Install it once with:"
    Write-Output "    $InstallCmd"
    Write-Output "  This gate never installs anything for you."
    exit 2
}

$pssaVersion = (Get-Module PSScriptAnalyzer).Version.ToString()

# Version drift must be LOUD, not merely printed.
#
# The documented install command pins -RequiredVersion, but the runtime check
# above accepts -MinimumVersion so a contributor already on a newer build is
# not blocked. That usability choice opens a gap: on a machine where someone
# installed a newer PSScriptAnalyzer separately, the gate silently binds to a
# build this repo never asked for, and the verdict of a correctness gate then
# comes from a module of unasserted provenance.
#
# Printing the resolved version is not sufficient on its own: the bash suite
# captures this script's whole output and, on the PASS branch, would discard
# it -- so the one consumer that runs this gate routinely would never see the
# drift. A distinct `warn:` prefix is what lets Group 29 surface drift on a
# PASS without dumping the entire clean run.
#
# Drift warns rather than fails, deliberately: failing would block exactly the
# contributor the -MinimumVersion allowance exists to accommodate. Loud and
# green beats silent and green; red would be wrong.
if ($pssaVersion -ne $PssaMinVersion) {
    Write-Output ("warn: PSScriptAnalyzer {0} is in use, but this repo pins {1} in its documented install command." -f $pssaVersion, $PssaMinVersion)
    Write-Output "  The gate still ran, and its self-test independently re-proved both rules fire on this build."
    Write-Output "  Pin deliberately, or reinstall the pinned build with:"
    Write-Output "    $InstallCmd"
}

# ---------------------------------------------------------------------------
# Settings. Missing settings is a gate error (1), not a tooling problem (2):
# the file is committed, so its absence means the repo is broken.
# ---------------------------------------------------------------------------
$settingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    Write-Output "GATE ERROR: settings file not found at $settingsPath"
    Write-Output "  scripts/PSScriptAnalyzerSettings.psd1 is committed and pins both compatibility rules."
    Write-Output "  Restore it rather than inlining rules here - one source of truth for the 5.1 target."
    exit 1
}

# ---------------------------------------------------------------------------
# SELF-TEST -- runs on EVERY invocation, before the scan.
#
# A compatibility gate that has silently stopped detecting anything still
# exits 0 and still looks green. That is the failure this guards against, and
# it is not hypothetical: PSUseCompatibleSyntax goes inert if its `Enable` key
# is dropped, and PSUseCompatibleCmdlets is dropped if an `Enable` key is
# ADDED. Both are silent. See the header of PSScriptAnalyzerSettings.psd1.
#
# Asserted PER RULE, never on a total. A total-only check passes in exactly
# the misconfiguration above, where one rule goes quiet and the other still
# reports. Parse errors also arrive as findings, which would pad a total.
#
# -ScriptDefinition, not a temp file: nothing is written to disk, so there is
# no scratch file to leak and no cleanup that can fail. No network.
# ---------------------------------------------------------------------------
$probe = @'
$probeValue = 1
$probeTernary = $probeValue ? 'a' : 'b'
$probeCoalesce = $null ?? 'c'
Get-Uptime
'@

$probeFindings = @(Invoke-ScriptAnalyzer -ScriptDefinition $probe -Settings $settingsPath)
$probeSyntax = @($probeFindings | Where-Object { $_.RuleName -eq 'PSUseCompatibleSyntax' }).Count
$probeCmdlets = @($probeFindings | Where-Object { $_.RuleName -eq 'PSUseCompatibleCmdlets' }).Count

if ($probeSyntax -lt 1 -or $probeCmdlets -lt 1) {
    $silent = @()
    if ($probeSyntax -lt 1) { $silent += 'PSUseCompatibleSyntax' }
    if ($probeCmdlets -lt 1) { $silent += 'PSUseCompatibleCmdlets' }
    Write-Output ("GATE SELF-TEST FAILED: {0} produced no findings on a probe that is deliberately 7-only." -f ($silent -join ' and '))
    Write-Output "  The gate cannot certify anything in this state - a scan would report clean because"
    Write-Output "  the rule is silent, not because the code is compatible."
    Write-Output "  Check scripts/PSScriptAnalyzerSettings.psd1. The two rules disagree about the Enable key:"
    Write-Output "    PSUseCompatibleSyntax  REQUIRES  Enable = `$true  (omit it and the rule never fires)"
    Write-Output "    PSUseCompatibleCmdlets MUST NOT have an Enable key (add one and the rule is dropped)"
    Write-Output "  Making that file look symmetric is the usual cause."
    exit 1
}

Write-Output ("ok: gate self-test - PSUseCompatibleSyntax ({0}) and PSUseCompatibleCmdlets ({1}) both fired on the 7-only probe" -f $probeSyntax, $probeCmdlets)
Write-Output ("ok: PSScriptAnalyzer {0} - settings scripts/PSScriptAnalyzerSettings.psd1, target Windows PowerShell 5.1" -f $pssaVersion)

if ($SelfTestOnly) {
    exit 0
}

# ---------------------------------------------------------------------------
# Resolve what to scan.
#
# Default is the repo's hooks/ directory, enumerated with a bare *.ps1 glob --
# NO -Exclude and no filename filter. Including the two ps1 TEST SUITES is
# deliberate, for three reasons:
#
#   1. They are already clean, so inclusion costs nothing and an exclusion
#      would buy nothing.
#   2. hooks/test-stride-hook.ps1 is THE artifact a Windows contributor runs
#      to prove the hook works. If the suite itself cannot parse under 5.1,
#      that contributor can verify nothing -- its 5.1-parseability is a real
#      property worth gating, not an accident.
#   3. The acceptance criterion says hooks/*.ps1 literally. Matching the
#      literal glob makes coverage self-evident, where an exclusion list is a
#      maintenance liability and a silent coverage hole: a new hooks/*.ps1
#      would have to be remembered into it.
#
# One ok: line is printed per file, so all four names appear in every clean
# run and the scope is visible rather than asserted.
# ---------------------------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
$scanTarget = if ($Path) { $Path } else { Join-Path $repoRoot 'hooks' }

if (-not (Test-Path -LiteralPath $scanTarget)) {
    Write-Output "GATE ERROR: scan target not found: $scanTarget"
    exit 1
}

if (Test-Path -LiteralPath $scanTarget -PathType Leaf) {
    $files = @(Get-Item -LiteralPath $scanTarget)
}
else {
    # NON-RECURSIVE, deliberately: the acceptance criterion names hooks/*.ps1,
    # and that glob does not descend. Every .ps1 in this repo is directly in
    # hooks/, so the scanned set is complete today.
    #
    # But "complete today" is exactly the silent-coverage-hole shape the scope
    # comment above rejects an exclusion list for, so it is not left to be
    # inferred: if a subdirectory ever holds .ps1 files, say so out loud rather
    # than passing clean over an unscanned tree. This warns rather than fails —
    # a nested file is not itself an incompatibility, and the honest report is
    # "these were not scanned", not a red gate for code nobody has judged.
    $files = @(Get-ChildItem -LiteralPath $scanTarget -Filter '*.ps1' -File | Sort-Object Name)

    # Name everything PowerShell-ish that the *.ps1 glob drops: files one or
    # more levels down, and sibling .psm1 modules. Both are silently invisible
    # otherwise, and one clean top-level file is enough to carry an entire
    # unscanned tree to a green exit 0 -- partial coverage reported as full
    # coverage, which is the vacuous-scan lie in a form the zero-file guard
    # does not catch.
    $scanTargetFull = (Get-Item -LiteralPath $scanTarget).FullName
    $scannedPaths = @($files | ForEach-Object { $_.FullName })
    # Capture enumeration errors rather than swallowing them. A subdirectory
    # that cannot be read yields no files AND no warning under a bare
    # SilentlyContinue, so a .ps1 beneath it becomes invisible again -- a small
    # instance of the exact silent-omission class this enumeration was added to
    # close. -Recurse does not follow directory symlinks without -FollowSymlink,
    # so there is no loop risk here.
    $gciErrors = @()
    $skipped = @(
        Get-ChildItem -LiteralPath $scanTarget -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable +gciErrors |
            Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $scannedPaths -notcontains $_.FullName }
    )
    foreach ($gciError in $gciErrors) {
        Write-Output ("warn: could not enumerate {0} - any PowerShell file beneath it was NOT scanned." -f $gciError.TargetObject)
    }
    if ($skipped.Count -gt 0) {
        Write-Output ("warn: {0} PowerShell file(s) under {1} were NOT scanned - this gate matches *.ps1 in that directory only, and does not recurse." -f $skipped.Count, $scanTargetFull)
        foreach ($s in $skipped) {
            Write-Output ("  unscanned: {0}" -f $s.FullName)
        }
        Write-Output "  Move them alongside the others, or widen the scan here and the documented scope to match."
    }
}

# A vacuous scan must be RED, never green. Zero files matched means the glob,
# the layout, or the argument is wrong -- reporting "all clean" over an empty
# set is the same class of lie the self-test above exists to prevent.
if ($files.Count -eq 0) {
    Write-Output "GATE ERROR: no *.ps1 files matched under $scanTarget"
    Write-Output "  A scan over zero files is not a pass. Check the path, or the hooks/ layout."
    exit 1
}

$status = 0
$sawCompatFinding = $false
foreach ($file in $files) {
    $displayName = $file.FullName
    if ($displayName.StartsWith($repoRoot)) {
        $displayName = $displayName.Substring($repoRoot.Length).TrimStart([char]'/', [char]'\')
    }

    # A suppressed file and a clean file print the same line, so say when one is
    # in force. A SuppressMessageAttribute above a file-level param() silences
    # the rule for the WHOLE file, and neither the scan nor the self-test can
    # see it -- the self-test runs against its own in-memory probe, so it stays
    # green while the file under scan is entirely unchecked. Without this line
    # the loss of coverage is invisible to the gate AND to code review, which is
    # the same "clean because the checker is quiet" failure the self-test exists
    # to prevent, arriving by a different door.
    #
    # Read as raw text on purpose: the attribute is what makes the finding
    # disappear, so it cannot be detected from the findings themselves.
    $rawText = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    # The `Attribute` suffix is optional: PowerShell appends it during
    # attribute resolution, so [Diagnostics.CodeAnalysis.SuppressMessage(...)]
    # is valid and is honoured by PSScriptAnalyzer just as the suffixed form
    # is. Matching only the suffixed spelling would leave a file blinded by the
    # shorter one printing an unqualified "clean" -- the exact shape this warn
    # exists to close.
    if ($rawText -and $rawText -match 'SuppressMessage(Attribute)?\s*\(\s*[''"]PSUseCompatible') {
        Write-Output ("warn: $displayName declares a SuppressMessageAttribute for a compatibility rule - findings it covers are hidden from this scan.")
        Write-Output "  Confirm it sits on a function and not above a file-level param(): at file scope it blinds the whole file."
    }

    # Undecodable content is not a clean file, it is a file nothing was learned
    # about. PSScriptAnalyzer returns zero findings for bytes it cannot read as
    # script text (BOM-less UTF-16, binary), which would otherwise print the
    # same positive "clean" assertion a genuinely compatible file earns -- the
    # vacuous-scan guard's principle applied to content rather than file count.
    # An embedded NUL is the precise signal, not emptiness: BOM-less UTF-16
    # decodes to plausible-looking text with a NUL between every character, so
    # a whitespace test passes it straight through. No legitimate PowerShell
    # source contains a NUL, and both failure shapes this catches -- BOM-less
    # UTF-16 and raw binary -- produce them. (A BOM is decisive: the same
    # payload WITH one decodes correctly and is analyzed normally.)
    if ($file.Length -gt 0 -and ($null -eq $rawText -or $rawText.Contains([char]0))) {
        Write-Output "GATE ERROR: $displayName is $($file.Length) bytes but did not decode as script text."
        Write-Output "  Nothing was analyzed, so this is not a pass - the analyzer returns zero findings"
        Write-Output "  for bytes it cannot read, which is indistinguishable from a clean file."
        Write-Output "  BOM-less UTF-16 and binary content both land here. Re-save it as UTF-8."
        $status = 1
        continue
    }

    # A whitespace-only file is a DIFFERENT condition and gets its own line: it
    # decoded fine, it simply carries no code. Folding it into the encoding
    # branch above would tell someone to re-save a perfectly valid placeholder
    # as UTF-8 -- a diagnosis that sends them after the wrong problem, which is
    # the same mistake the UNANALYZABLE split exists to correct. It is not an
    # error: an empty placeholder is legitimately compatible with everything.
    if ($file.Length -gt 0 -and [string]::IsNullOrWhiteSpace($rawText)) {
        Write-Output "ok: $displayName - clean (whitespace only, no code to check)"
        continue
    }

    # Invoke-ScriptAnalyzer has no -LiteralPath (checked: its parameter set is
    # Path / ScriptDefinition only), and -Path GLOBS. A filename containing a
    # wildcard metacharacter -- [ ] * ? -- therefore resolves to nothing and
    # returns zero findings, which prints as "ok: <file> - clean" for a file
    # that was never analyzed. Verified: a file named `we[ir]d.ps1` holding a
    # ternary AND Get-Uptime came back clean.
    #
    # Escaping the path is what makes -Path behave literally. Every other path
    # operation in this script already uses -LiteralPath; this was the one call
    # that still globbed, and so the last vacuous-clean door in the file.
    $literalPath = [System.Management.Automation.WildcardPattern]::Escape($file.FullName)

    # @(...) so a single finding does not collapse to a scalar and lose .Count.
    $findings = @(Invoke-ScriptAnalyzer -Path $literalPath -Settings $settingsPath)

    if ($findings.Count -eq 0) {
        Write-Output "ok: $displayName - clean"
        continue
    }

    $status = 1
    foreach ($finding in $findings) {
        # Label by what the finding actually IS. PSScriptAnalyzer also emits
        # parse errors and FileReadError regardless of IncludeRules, and calling
        # those "INCOMPATIBLE" asserts something false about them: a permission
        # error is not a construct, does not exist-or-not in 5.1, and cannot be
        # rewritten. Worse, the compatibility footer would then advise
        # suppressing it -- which is how a reader debugging a typo ends up
        # blinding a whole file.
        if ($finding.RuleName -eq 'PSUseCompatibleSyntax' -or $finding.RuleName -eq 'PSUseCompatibleCmdlets') {
            Write-Output ("INCOMPATIBLE: {0}:{1} {2} - {3}" -f $displayName, $finding.Line, $finding.RuleName, $finding.Message)
            $sawCompatFinding = $true
        }
        else {
            Write-Output ("UNANALYZABLE: {0}:{1} {2} - {3}" -f $displayName, $finding.Line, $finding.RuleName, $finding.Message)
            Write-Output "  Not a 5.1 compatibility problem: the file could not be read or parsed, so it was"
            Write-Output "  never actually checked. Fix the file itself - do NOT suppress this."
        }
    }
}

# Only print the compatibility guidance when there is a compatibility finding
# to guide. Printing it after a lone parse or read error tells the reader to
# rewrite a construct that does not exist.
if ($sawCompatFinding) {
    Write-Output ""
    Write-Output "  These constructs do not exist in Windows PowerShell 5.1. stride-hook.sh execs"
    Write-Output "  powershell.exe, so this fails ONLY on a user's Windows box - never on the pwsh 7"
    Write-Output "  you are reading this on. That asymmetry is why this gate exists."
    Write-Output "  Rewrite the construct in a form 5.1 accepts. That is almost always the answer."
    Write-Output "  If a divergence is genuinely deliberate, suppress THAT ONE finding at its site:"
    Write-Output "    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('<Rule>', '', Justification = '<why>')]"
    Write-Output "  PUT IT ON THE ENCLOSING FUNCTION, never above a file-level param()."
    Write-Output "  At file scope that attribute silences the rule for the ENTIRE FILE - every"
    Write-Output "  construct in it, including ones nobody has written yet - and the run then"
    Write-Output "  prints the same 'clean' line a genuinely compatible file gets. On a function"
    Write-Output "  it is correctly confined to that function. This gate warns when it sees a"
    Write-Output "  suppression, but the placement is still yours to get right."
    Write-Output "  Never remove a rule from scripts/PSScriptAnalyzerSettings.psd1 to get a green run -"
    Write-Output "  that blinds the gate everywhere at once, which is strictly worse than no gate."
}

exit $status
