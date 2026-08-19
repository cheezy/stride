# W2079/W2105: byte-budget drift detector for the hot-path skill files.
#
# PowerShell counterpart to check-skill-budgets.sh. Same three files, same
# budgets, same byte counts, same exit codes (0 clean, 1 over budget or a table
# entry with no file). Test Group 28 in test-stride-hook.ps1 invokes this and
# also cross-checks its numbers against the bash script's, so the two cannot
# drift apart silently - which is the whole point of a drift detector.
#
# Budgets are drift detectors, not targets (the D229 philosophy): each is set
# 10-15% above the post-extraction size so ordinary edits pass and only
# sustained regrowth trips it. The cold optional-*.md and reference sibling
# files are deliberately UNBUDGETED - growing them is the point of extraction.
#
# BYTES, NOT CHARACTERS, AND NOT LINES. The bash script uses `wc -c`, which
# counts bytes on disk. Get-Content -Raw would decode text and could disagree on
# a UTF-8 file with multi-byte characters or on CRLF line endings, so this reads
# the raw byte length instead. That agreement is asserted, not assumed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:Status = 0

function Test-SkillBudget {
    param([string]$File, [int]$Budget)
    $path = Join-Path $RepoRoot $File
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Output "BUDGET CHECK ERROR: $File - budget table entry has no matching file (missing or renamed?). The table is in scripts/check-skill-budgets.ps1 - update the entry to the file's new path."
        $script:Status = 1
        return
    }
    $size = [System.IO.File]::ReadAllBytes($path).Length
    if ($size -gt $Budget) {
        Write-Output "BUDGET EXCEEDED: $File is $size bytes (budget: $Budget)."
        Write-Output "  Hot-path skill files are size-budgeted so regrowth is a visible decision,"
        Write-Output "  not an accident. Move cold material to a gated sibling file instead of"
        Write-Output "  growing the hot path - see CHANGELOG.md's W2077 and W2078 extraction"
        Write-Output "  entries for the pattern (sibling named at its gate, pointer at the"
        Write-Output "  original site, Decision Summary stays inline)."
        Write-Output "  If extraction is genuinely wrong for this change, the budget table is in"
        Write-Output "  scripts/check-skill-budgets.ps1 - raising a budget is a deliberate,"
        Write-Output "  reviewed decision, never a reflex to make this check pass."
        $script:Status = 1
    } else {
        Write-Output "ok: $File - $size of $Budget bytes"
    }
}

# Budget table (bytes). MUST match scripts/check-skill-budgets.sh entry for
# entry - Group 28 asserts that, because two drift detectors that disagree
# about the budget detect nothing.
Test-SkillBudget -File 'skills/stride-workflow/SKILL.md'         -Budget 101000
Test-SkillBudget -File 'skills/stride-completing-tasks/SKILL.md' -Budget 64000
Test-SkillBudget -File 'skills/stride-claiming-tasks/SKILL.md'   -Budget 33500

exit $script:Status
