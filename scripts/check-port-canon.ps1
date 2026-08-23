#!/usr/bin/env pwsh
#
# check-port-canon.ps1 -- port drift check against docs/port-canon.md.
#
# The PowerShell half of the pair whose bash half is check-port-canon.sh
# (W2084). Same verdicts, same exit codes, same message substrings, against the
# same inputs -- and a DIFFERENT implementation underneath, deliberately.
# W2107's brief says so in as many words: do not translate the awk tokenizer
# line for line, use ConvertFrom-Json, let the two halves differ structurally,
# and then prove they agree. Two independent readings of one document that
# reach the same verdict are worth more than one reading run twice.
#
# Reports per port per rule, exactly as the bash half does:
#
#   MISSING       the port owes this rule and carries no anchor for it
#   STALE         an anchor is present, at an older version than the canon's
#   UNEXPECTED    an anchor is present for a rule this port does not owe,
#                 or for an id the canon does not define at all
#   DEFECT        a check: "property" rule the port's files actually violate
#   UNVERIFIABLE  a check: "property" rule this script cannot evaluate
#   ok            the cell is clean
#
# ---------------------------------------------------------------------------
# EXIT CODES, and why tier 2 means here what it means in the bash half
# ---------------------------------------------------------------------------
#
#   0  every applicable cell reports ok
#   1  at least one cell reports MISSING, STALE, UNEXPECTED, DEFECT or
#      UNVERIFIABLE -- drift was found
#   2  no verdict was possible: the canon is absent, unparseable, carries an
#      unknown schema version, has a bad registry dir, or the command line was
#      wrong
#
# There is NO MACHINE-FAULT TIER HERE, and that is worth stating rather than
# leaving to be inferred, because the sibling gate in this same directory uses
# its 2 differently. check-ps1-compat.ps1 reserves 2 for a machine that lacks
# PSScriptAnalyzer -- a real "this host cannot answer the question" case. This
# script has no such dependency: ConvertFrom-Json and the .NET file APIs ship
# inside every PowerShell that could execute this file at all, so the only
# thing that can be absent is the input. The one dependency this half has that
# the bash half does not is PowerShell itself, and that dependency is satisfied
# by the fact that this script is running.
#
# So 2 carries the same document-or-argument meaning as check-port-canon.sh's
# 2, and shares with both siblings the operational meaning that matters most:
# THIS RUN PROVED NOTHING. Do not read its silence as a pass.
#
# ---------------------------------------------------------------------------
# WHAT THIS HALF HAS TO GET RIGHT THAT THE BASH HALF DID NOT
# ---------------------------------------------------------------------------
#
# The bash half carries a five-round audit history in its header, whose round-5
# finding is one shape: enumeration SUCCEEDING was read as "the tree was
# examined", and every read failure below it collapsed into the same empty
# output a clean file produces. PowerShell reaches that shape more easily than
# bash does, not less, because -ErrorAction SilentlyContinue turns any read
# failure into $null, and $null is falsy, and falsy reads as clean. Every guard
# below exists against that:
#
#   * Files are read as BYTES in try/catch. Any failure yields an 'unreadable'
#     sentinel that is distinguishable from an empty file at the type level --
#     never an empty string, which is what a clean empty file also produces.
#   * A NUL byte refuses the file, mirroring the bash half's grep -I refusal.
#   * Decoding is ISO-8859-1 (code page 28591), not UTF-8. UTF8.GetString maps
#     invalid bytes to U+FFFD and can merge or vanish content -- the exact
#     failure D281 filed against stride-hook.ps1, whose decided answer was this
#     same bijective Latin-1 projection. The anchor and fence patterns are pure
#     ASCII, so Latin-1 scanning is exact, and it removes the locale dependency
#     the bash half could only pin rather than close.
#   * Enumeration happens ONCE and both passes consume its result, with the
#     status carried alongside. The bash half walks the tree twice and its own
#     header records that as the shape it kept being defeated by.
#   * A reparse point that is a directory or a .md REFUSES the port; any other
#     reparse point is ignored and never read.
#   * Add-Record is the only writer of $script:Status, so a suppressed record
#     cannot silently leave a port green.
#
# And three failure modes that are PowerShell's alone, which no amount of
# fidelity to the bash half would have caught:
#
#   * -eq, -match and -like are CASE-INSENSITIVE by default. "Required",
#     "ANCHOR" and "Quoted" would sail past a closed-vocabulary check that the
#     bash half's case/= refuses at exit 2. Every id, status, variant, check,
#     provenance and schema comparison below uses -ceq / -cmatch.
#   * Without Set-StrictMode a missing JSON key reads as $null rather than
#     throwing, which is indistinguishable from a key that legitimately holds
#     null -- and superseded_by legitimately holds null. Key PRESENCE is tested
#     through psobject.Properties, never through $null-ness.
#   * A CRLF checkout ends every line with \r, which stops an end-of-line
#     anchor and a fence closer matching. Lines are trimmed of \r on split.
#
# ---------------------------------------------------------------------------
# HONEST LIMITS
# ---------------------------------------------------------------------------
#
# Nothing here has been executed under Windows PowerShell 5.1, which is the
# host stride-hook.sh execs on Windows. It is written to 5.1's subset and
# check-ps1-compat.sh gates that subset by AST, but a gate that reads is not a
# run -- the D237 precedent for saying so rather than implying coverage.
#
# The self-test's platform-conditional cases (chmod, symlinks, exotic
# filenames) are skipped with a printed reason on hosts that cannot create
# their fixtures, never silently absent. The ledger at the end of self_test
# names them.
#
# This script reads local files only. It fetches nothing, sends nothing, and
# writes nothing outside its own self-test temp directory.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# (W2107 r2) $IsWindows was introduced in PowerShell Core 6. Under
# Set-StrictMode -Version Latest a reference to it on Windows PowerShell 5.1 --
# the host stride-hook.sh actually execs -- is a TERMINATING error, so the
# self-test would abort at its first platform-conditional block instead of
# printing the skip reasons this file promises. Nothing would be falsely green,
# but the coverage ledger would never print on the one host the HONEST LIMITS
# section says matters most. check-ps1-compat.sh gates 7-only SYNTAX and CMDLET
# names by AST and cannot see an automatic variable, so this had to be caught
# by reading rather than by the gate.
$script:OnWindows = ([System.IO.Path]::DirectorySeparatorChar -ceq '\')

$script:Self = $PSCommandPath
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $script:Self)

# --------------------------------------------------------------------------
# Argument parsing.
#
# Hand-rolled rather than [CmdletBinding()]: a binding failure would emit
# PowerShell's own message and its own exit code, and this half's contract is
# to match the bash half's message substring and its exit 2. Both the
# PowerShell spelling and the bash spelling are accepted for every flag, so a
# command line copied from the README or from the sibling works either way.
# --------------------------------------------------------------------------
$Canon = ''
$PortsParent = ''
$SelfTest = $false
$ShowHelp = $false
$CanonSet = $false
$PortsSet = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    switch -CaseSensitive -Regex ($a) {
        # (W2107 r2) The arity guard the bash half has and this did not. As the
        # LAST argument, `-Canon` incremented past the end and indexed $args --
        # which under Set-StrictMode -Version Latest is a TERMINATING error, so
        # the process exited 1 with a PowerShell stack trace instead of 2 with
        # this half's message. In this contract exit 1 means "drift found", so a
        # mistyped command line reported drift.
        '^(-Canon|--canon)$' {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine('GATE ERROR: --canon needs a path')
                exit 2
            }
            $i++; $Canon = [string]$args[$i]; $CanonSet = $true; break
        }
        '^(-PortsParent|--ports-parent)$' {
            if ($i + 1 -ge $args.Count) {
                [Console]::Error.WriteLine('GATE ERROR: --ports-parent needs a directory')
                exit 2
            }
            $i++; $PortsParent = [string]$args[$i]; $PortsSet = $true; break
        }
        '^(-SelfTest|--self-test)$'      { $SelfTest = $true; break }
        '^(-h|-Help|--help)$'            { $ShowHelp = $true; break }
        default {
            [Console]::Error.WriteLine("GATE ERROR: unknown option ""$a""")
            exit 2
        }
    }
}

if ($ShowHelp) {
    Write-Output @'
check-port-canon.ps1 -- port drift check against docs/port-canon.md.

  -Canon <path>         the canon document (default: docs/port-canon.md)
  -PortsParent <path>   the directory the port repos live in (default: ..)
  -SelfTest             prove the checker detects what it claims; scans nothing
  -h, --help            this text

Exit codes: 0 all clear, 1 drift found, 2 no verdict possible.
The bash spellings --canon / --ports-parent / --self-test are also accepted.
'@
    exit 0
}

if (-not $Canon) { $Canon = Join-Path $script:RepoRoot 'docs/port-canon.md' }
if (-not $PortsParent) { $PortsParent = Split-Path -Parent $script:RepoRoot }

# --------------------------------------------------------------------------
# Byte-level file reading.
#
# Everything below reads BYTES and decodes ISO-8859-1, never Get-Content with
# -ErrorAction SilentlyContinue. The reasons are in the header: a swallowed
# read failure is indistinguishable from a clean file, and a UTF-8 decode maps
# invalid bytes to U+FFFD and can merge or vanish content (D281). Latin-1 is
# bijective over 0x00-0xFF and the patterns matched against it are pure ASCII,
# so the scan is exact and locale-independent.
#
# Returns a hashtable so the caller can tell the three outcomes apart at the
# type level: Ok=$true with Text, Ok=$false with Reason='unreadable', or
# Ok=$false with Reason='nul'. An empty FILE is Ok=$true with Text=''. That
# distinction is the whole point -- collapsing it is the round-5 defect.
# --------------------------------------------------------------------------
function Read-CanonBytes {
    param([string]$Path)
    $bytes = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        return @{ Ok = $false; Reason = 'unreadable'; Text = '' }
    }
    foreach ($b in $bytes) {
        if ($b -eq 0) { return @{ Ok = $false; Reason = 'nul'; Text = '' } }
    }
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    return @{ Ok = $true; Reason = ''; Text = $enc.GetString($bytes) }
}

# Split into lines without inventing or losing one, and strip a CRLF's \r so
# an end-of-line anchor and a fence closer still match on a CRLF checkout.
function Split-CanonLines {
    param([string]$Text)
    $lines = $Text -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) { $out.Add(($l -replace "`r$", '')) }
    return $out
}

# --------------------------------------------------------------------------
# safe() -- the bash half refuses any canon string carrying a tab or newline,
# because those are its record separators and a crafted value would forge a
# field boundary. This half has no record stream: ConvertFrom-Json hands back
# an object graph and nothing is ever re-split.
#
# The refusal is implemented anyway, and deliberately so. Criterion 1 makes the
# two halves' VERDICTS the contract, and a refusal is a verdict: a canon that
# halts the bash half at exit 2 must halt this one at exit 2 with the same
# substring, or the pair disagrees on a real input. Dropping it as "not
# applicable to my implementation" would be exactly the kind of local reasoning
# that makes a pair stop being a pair.
# --------------------------------------------------------------------------
# (W2107 r2) A KNOWN GAP, recorded rather than closed here, because closing it
# in one half would BREAK the pair. The refusal covers tab and newline -- the
# bash half's record separators -- and not the rest of the control range, so a
# canon string carrying ESC or a bare CR passes both halves and is printed
# verbatim into a terminal report. A value shaped like "alpha<ESC>[1A<ESC>[2K"
# can overwrite the line above it, and the lines above are where "verdict:
# NEEDS WORK" and "GATE ERROR" are emitted: the drift a reviewer is reading the
# report to find can be erased from the screen while the exit code still says 1.
#
# Widening this refusal to [\x00-\x1F\x7F-\x9F] is the right fix and it must
# land in BOTH halves in one change. Doing it here alone would make a canon
# carrying ESC halt this half at exit 2 while the bash half scanned it and
# exited 0 or 1 -- a real input on which the pair disagrees, which is exactly
# what acceptance criterion 1 forbids and what W2107's own cross-verification
# would catch. W2107's pitfall 4 also forbids changing the .sh half's
# behaviour while pairing it. So: filed as the follow-up it is, not smuggled in
# as a one-sided hardening.
function Assert-SafeCanonString {
    param([string]$Value, [string]$What)
    if ($Value -cmatch "[`t`n]") {
        Stop-Gate "$What contains a tab or newline, which would forge a record boundary; refusing to parse it"
    }
}

# In the bash half the parser is a SUBPROCESS, so a parse failure prints the
# specific reason and then the shell adds a summary line of its own. A halt
# raised before the parser runs -- a bad flag, an unreadable canon -- prints
# only the reason. This half has no subprocess boundary, so the distinction is
# carried by a flag instead; without it the two halves emit different text for
# the same input, which the fixture-tree cross-check catches at tier 2.
$script:InParse = $false

function Stop-Gate {
    param([string]$Message)
    [Console]::Error.WriteLine("GATE ERROR: $Message")
    if ($script:InParse) {
        [Console]::Error.WriteLine('GATE ERROR: canon did not parse; no verdict is possible')
    }
    exit 2
}

# --------------------------------------------------------------------------
# The canon parser.
#
# Blocks are classified by their own discriminator key -- canon_schema_version
# for the registry, id for a rule entry -- never by position. A json fence
# matching neither shape halts the run; absorbing it silently would make it a
# phantom entry.
#
# The fence walker tolerates trailing whitespace on the info string. That is
# load-bearing rather than cosmetic: a byte-exact "json" test made
# ```json-with-a-trailing-space open an ORDINARY fence, so the entry inside it
# ceased to exist for the checker while rendering normally for every human --
# and a fleet carrying no anchor for that rule reported clean.
#
# The anchor-count backstop below is the general defense against every OTHER
# way a block can go unclassified rather than halt, including a tilde fence
# this walker does not track. It compares what the DOCUMENT declares against
# what the parser consumed, which is the only check that can see an entry that
# vanished -- a vanished entry produces no cells and no findings, so there is
# nothing else to notice.
# --------------------------------------------------------------------------
$script:SupportedSchema = 1
$script:EntryKeys = @('id','version','status','superseded_by','provenance','defects','check','check_hint','applies_to')
$script:VariantVocabulary = @('','four-section-keys','five-section-keys','lib-matrix')

# (W2107 r2) The text the BASH half compares against. Its awk tokenizer keeps
# a json literal as its source text, so `"exists": false` reaches its test as
# the four characters `false`. ConvertFrom-Json gives a [bool] instead, and
# [string]$false is "False" -- so a direct string compare against 'false' would
# never match, and the exists:false branch would be unreachable. Mapping the
# boolean back to its literal text keeps the two halves comparing the same
# thing; every other value is passed through unchanged, so a malformed "yes"
# or a quoted "False" still lands on the same branch in both halves.
function ConvertTo-CanonTokenText {
    param($Value)
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    # (W2107 r3) A present JSON null reads as the four characters `null`, for
    # the same reason as the boolean: the bash tokenizer keeps the literal as
    # its source text. Without this, [string]$null is "" and three divergences
    # follow -- `"variant": null` became a legal empty variant here while
    # halting the bash half, and a registry `"id": null` halted here while the
    # bash half accepted the literal id "null".
    if ($null -eq $Value) { return 'null' }
    return [string]$Value
}

# (W2107 r3) The bash token text of a field, with ABSENT and PRESENT-NULL kept
# apart. The bash tokenizer has no key at all for an absent field -- its `in V`
# test is false -- while a present `null` is stored as the literal text. Mapping
# both to "null" made an absent registry `id` read as the id "null", so the
# no-id halt stopped firing and a canon with uppercase keys took a different
# halt from the bash half. Absent is '' here; present-null is 'null'.
function Get-CanonField {
    param($Object, [string]$Name)
    foreach ($prop in $Object.psobject.Properties) {
        if ($prop.Name -ceq $Name) { return (ConvertTo-CanonTokenText -Value $prop.Value) }
    }
    return ''
}

# (W2107 r2) CASE-SENSITIVE KEY RETRIEVAL. PowerShell member access -- $p.id --
# is case-insensitive by construction, so a registry writing "ID"/"DIR"/
# "EXISTS" produced a full clean fleet report at exit 0 where the bash half's
# awk tokenizer keys on the literal text ports.0.id, finds it absent, and halts
# at exit 2. The entry-level keys were already guarded this way; the registry
# ports and applies_to rows were not, and those carry exactly the port ids and
# row statuses the header's case-sensitivity claim is about. The claim guarded
# their COMPARISON and not their RETRIEVAL, which is the more dangerous half.
#
# Returns $null when the key is absent in its exact spelling, so a caller can
# tell "absent" from "present and empty" -- the same distinction the rest of
# this file keeps everywhere else.
function Get-JsonMember {
    param($Object, [string]$Name)
    foreach ($prop in $Object.psobject.Properties) {
        if ($prop.Name -ceq $Name) { return $prop.Value }
    }
    return $null
}

function Test-JsonMember {
    param($Object, [string]$Name)
    foreach ($prop in $Object.psobject.Properties) {
        if ($prop.Name -ceq $Name) { return $true }
    }
    return $false
}

function ConvertFrom-Canon {
    param([string]$Path)

    $script:InParse = $true
    $read = Read-CanonBytes -Path $Path
    if (-not $read.Ok) { Stop-Gate "canon not readable at $Path" }
    $lines = Split-CanonLines -Text $read.Text

    $blocks = New-Object System.Collections.Generic.List[object]
    $inFence = $false
    $fenceLen = 0
    $inJson = $false
    $blockNum = 0
    $blockLine = 0
    $blob = New-Object System.Text.StringBuilder
    $nDefs = 0
    $anchorDef = '<!--[ \t]*canon:[A-Za-z0-9][A-Za-z0-9_-]*[ \t]+v[0-9]+[ \t]*-->'

    for ($n = 0; $n -lt $lines.Count; $n++) {
        $raw = $lines[$n]
        $line = $raw -replace '^[ \t]+', ''
        if ($line.StartsWith('```', [System.StringComparison]::Ordinal)) {
            $run = 0
            $rest = $line
            while ($rest.Length -gt 0 -and $rest[0] -ceq '`') { $rest = $rest.Substring(1); $run++ }
            if (-not $inFence) {
                $inFence = $true
                $fenceLen = $run
                $info = $rest -replace '[ \t\r]+$', ''
                if ($info -ceq 'json') {
                    $inJson = $true
                    $blockNum++
                    $blockLine = $n + 1
                    $blob = New-Object System.Text.StringBuilder
                }
                continue
            } elseif ($run -ge $fenceLen -and $rest -match '^[ \t]*$') {
                if ($inJson) {
                    $blocks.Add(@{ Num = $blockNum; Line = $blockLine; Body = $blob.ToString() })
                    $inJson = $false
                }
                $inFence = $false
                $fenceLen = 0
                continue
            }
        }
        if ($inJson) { $null = $blob.Append($raw).Append("`n") }
        # -cmatch. This is the one production pattern carrying letters
        # (canon:, v), and a case-insensitive match counted a prose line like
        # <!-- CANON:example V9 --> that awk's ~ operator in the bash half does
        # not -- tripping the anchor-count backstop at exit 2 on one side only.
        if (-not $inFence -and $raw -cmatch $anchorDef) { $nDefs++ }
    }
    if ($inFence) { Stop-Gate 'unclosed fence at end of canon' }

    $registry = $null
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($b in $blocks) {
        $obj = $null
        try {
            $obj = $b.Body | ConvertFrom-Json
        } catch {
            Stop-Gate ("json block #" + $b.Num + " (line " + $b.Line + ") did not parse as json")
        }
        $names = @($obj.psobject.Properties.Name)
        $hasSchema = $false
        $hasId = $false
        foreach ($nm in $names) {
            if ($nm -ceq 'canon_schema_version') { $hasSchema = $true }
            if ($nm -ceq 'id') { $hasId = $true }
        }

        if ($hasSchema) {
            if ($b.Num -ne 1) {
                Stop-Gate ("registry block found at position " + $b.Num + "; the registry must be the first json block")
            }
            $schemaVal = Get-CanonField -Object $obj -Name 'canon_schema_version'
            if ($schemaVal -cne [string]$script:SupportedSchema) {
                Stop-Gate ("canon_schema_version " + $schemaVal + " is not the schema this checker understands (" + $script:SupportedSchema + "); refusing to parse optimistically")
            }
            # Get-JsonMember returns $null for an absent key rather than
            # throwing, so a registry block carrying canon_schema_version and no
            # ports key halts here with the bash half's message instead of
            # dying on a StrictMode non-existent-property access.
            $portsRaw = Get-JsonMember -Object $obj -Name 'ports'
            $ports = @()
            if ($null -ne $portsRaw) { $ports = @($portsRaw) }
            if ($ports.Count -eq 0) { Stop-Gate 'registry carries no ports' }
            $plist = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $ports.Count; $i++) {
                $p = $ports[$i]
                $portId = Get-CanonField -Object $p -Name 'id'
                if (-not $portId) { Stop-Gate ("registry port " + $i + " has no id") }
                $pdir = Get-CanonField -Object $p -Name 'dir'
                if ($pdir -cnotmatch '^[A-Za-z0-9._-]+$') {
                    Stop-Gate ("registry port ""$portId"" has dir ""$pdir"" which is not a single path segment matching ^[A-Za-z0-9._-]+$")
                }
                # "." and ".." are entirely allowed characters, so the charset
                # test above admits them -- and ".." walks the scan out of the
                # ports parent. Neither names a port.
                if ($pdir -ceq '.' -or $pdir -ceq '..') {
                    Stop-Gate ("registry port ""$portId"" has dir ""$pdir"", which is a directory traversal rather than a port directory")
                }
                Assert-SafeCanonString -Value $portId -What 'port id'
                Assert-SafeCanonString -Value (Get-CanonField -Object $p -Name 'family') -What 'port family'
                Assert-SafeCanonString -Value $pdir -What 'port dir'
                $plist.Add([pscustomobject]@{
                    Id = $portId; Family = (Get-CanonField -Object $p -Name 'family'); Dir = $pdir
                    # (W2107 r2) NEGATIVE, matching `[ "$pexists" = "false" ]`
                    # in the bash half. Testing positively for true/True sent a
                    # malformed value such as "yes" -- or the string "False" --
                    # down the opposite branch from the bash half at both the
                    # exists/status consistency halt and the
                    # deferred-because-unscaffolded path.
                    Exists = (-not ((Get-CanonField -Object $p -Name 'exists') -ceq 'false'))
                    Note = (Get-CanonField -Object $p -Name 'note')
                })
            }
            $registry = $plist
            continue
        }

        if ($hasId) {
            if ($b.Num -eq 1) {
                Stop-Gate 'first json block carries an id but no canon_schema_version; the registry must come first'
            }
            if ($null -eq $registry) { Stop-Gate 'no registry block found in the canon' }
            $eid = Get-CanonField -Object $obj -Name 'id'
            if ($eid -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
                Stop-Gate ("entry id ""$eid"" is outside the anchor charset ^[A-Za-z0-9][A-Za-z0-9_-]`$; an id that cannot appear in an anchor is meaningless to the canon")
            }
            foreach ($k in $script:EntryKeys) {
                if (-not (Test-JsonMember -Object $obj -Name $k)) {
                    Stop-Gate ("entry ""$eid"" is missing required key ""$k""")
                }
            }
            $status = Get-CanonField -Object $obj -Name 'status'
            if ($status -cne 'active' -and $status -cne 'superseded') {
                Stop-Gate ("entry ""$eid"" has status ""$status"" outside the closed vocabulary active|superseded")
            }
            $prov = Get-CanonField -Object $obj -Name 'provenance'
            if ($prov -cne 'quoted' -and $prov -cne 'synthesized-from-shipped-fixes') {
                Stop-Gate ("entry ""$eid"" has provenance ""$prov"" outside its closed vocabulary")
            }
            $check = Get-CanonField -Object $obj -Name 'check'
            if ($check -cne 'anchor' -and $check -cne 'property') {
                Stop-Gate ("entry ""$eid"" has check ""$check"" outside the closed vocabulary anchor|property")
            }
            $ver = Get-CanonField -Object $obj -Name 'version'
            if ($ver -cnotmatch '^[0-9]+$') { Stop-Gate ("entry ""$eid"" has non-integer version ""$ver""") }
            # A present `"defects": null` has no .__len in the bash tokenizer
            # and halts there; @($null).Count is 1 here, which accepted it.
            $defectsVal = Get-JsonMember -Object $obj -Name 'defects'
            $defectsCount = 0
            if ($null -ne $defectsVal) { $defectsCount = @($defectsVal).Count }
            if ($defectsCount -eq 0) { Stop-Gate ("entry ""$eid"" has an empty defects array") }
            Assert-SafeCanonString -Value $eid -What 'entry id'
            Assert-SafeCanonString -Value $ver -What 'entry version'
            Assert-SafeCanonString -Value (Get-CanonField -Object $obj -Name 'check_hint') -What 'check_hint'

            $rows = @(Get-JsonMember -Object $obj -Name 'applies_to')
            if ($rows.Count -ne $registry.Count) {
                Stop-Gate ("entry ""$eid"" lists " + $rows.Count + " applies_to rows but the registry has " + $registry.Count + " ports; every entry must list all ports in registry order")
            }
            $applies = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $r = $rows[$i]
                $rp = Get-CanonField -Object $r -Name 'port'
                if ($rp -cne $registry[$i].Id) {
                    Stop-Gate ("entry ""$eid"" applies_to row " + $i + " names port ""$rp"" but registry position " + $i + " is """ + $registry[$i].Id + """; rows must follow registry order")
                }
                $rs = Get-CanonField -Object $r -Name 'status'
                if ($rs -cne 'required' -and $rs -cne 'not_applicable' -and $rs -cne 'deferred') {
                    Stop-Gate ("entry ""$eid"" row ""$rp"" has status ""$rs"" outside the closed vocabulary required|not_applicable|deferred")
                }
                $rv = Get-CanonField -Object $r -Name 'variant'
                $variantOk = $false
                foreach ($v in $script:VariantVocabulary) { if ($rv -ceq $v) { $variantOk = $true } }
                if (-not $variantOk) {
                    Stop-Gate ("entry ""$eid"" row ""$rp"" has variant ""$rv"" outside the canon's declared vocabulary")
                }
                # The registry's exists and the row's status are two statements
                # about the same port. A canon edit that flipped rows to
                # required but left exists:false reported "nothing owed yet"
                # and exited 0 over a port owing every rule. Every other canon
                # inconsistency halts; this one resolved toward green.
                if (-not $registry[$i].Exists -and $rs -cne 'deferred') {
                    Stop-Gate ("entry ""$eid"" row ""$rp"" has status ""$rs"" but the registry says that port does not exist; a port that is not scaffolded can only defer a rule, never owe it")
                }
                Assert-SafeCanonString -Value $rv -What 'variant'
                $applies.Add([pscustomobject]@{ Port = $rp; Status = $rs; Variant = $rv })
            }
            $entries.Add([pscustomobject]@{
                Id = $eid; Version = [int]$ver; Status = $status; Provenance = $prov
                Check = $check; CheckHint = (Get-CanonField -Object $obj -Name 'check_hint'); AppliesTo = $applies
            })
            continue
        }

        Stop-Gate ("json block #" + $b.Num + " (line " + $b.Line + ") matches neither the registry shape (canon_schema_version) nor an entry shape (id)")
    }

    if ($null -eq $registry) { Stop-Gate 'no registry block found in the canon' }
    if ($entries.Count -eq 0) { Stop-Gate 'no rule entries found in the canon' }
    if ($nDefs -ne $entries.Count) {
        Stop-Gate ("the canon carries $nDefs anchor definition line(s) but " + $entries.Count + " parsed rule entr(y/ies); a block the document defines did not reach this parser (an unrecognised info string or a tilde fence will do it), and an entry that silently vanishes produces no cells and no findings")
    }
    # Parsing is over; halts raised from here on are about the FLEET, not the
    # document, and carry no "canon did not parse" line in either half.
    $script:InParse = $false
    return @{ Ports = $registry; Entries = $entries }
}

# --------------------------------------------------------------------------
# ONE enumeration, two consumers.
#
# The bash half walks each port twice -- once for anchors, once for the
# property pass -- and its own header records that as the shape it kept being
# defeated by: a guard added to one walk said nothing about the other. This
# half walks once and hands both passes the same list, with the enumeration's
# STATUS carried alongside it rather than inferred from emptiness.
#
# Disposition per item, mirroring the bash half's refusals exactly:
#   scan    an ordinary .md; read it
#   refuse  a reparse point that is a directory or a .md -- it can resolve
#           outside the port tree, so reading it would attribute another tree's
#           content to this port, and SKIPPING it silently is how a not-owed
#           anchor in a symlinked .md kept a port clean
#   ignore  any other reparse point: carries no markdown, hides nothing, and
#           must not count toward the enumerated file total either
#
# Ok=$false means the walk did not complete. That is not the same as an empty
# walk, and neither is the same as a clean one; all three are distinguishable
# here by construction.
# --------------------------------------------------------------------------
function Get-PortMarkdown {
    param([string]$Root)

    $result = @{ Ok = $true; Items = (New-Object System.Collections.Generic.List[object]); Unrepresentable = $false }

    $start = $null
    try { $start = Get-Item -LiteralPath $Root -Force } catch { $result.Ok = $false; return $result }
    # find -H resolves the START point only. A port checked out as a symlink
    # passed [ -d ] and was not descended by find's default -P: "verified
    # across 0 markdown files", exit 0, over a tree full of violations.
    $startPath = $start.FullName
    if ($start.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        try { $startPath = (Get-Item -LiteralPath $Root -Force).Target } catch { $startPath = $Root }
        if (-not $startPath) { $startPath = $Root }
        if (-not [System.IO.Path]::IsPathRooted($startPath)) {
            $startPath = Join-Path (Split-Path -Parent $start.FullName) $startPath
        }
    }

    # (W2107 r2) WALK ORDER IS UNSPECIFIED IN BOTH HALVES, and that is a shared
    # latent divergence rather than one this port introduced. This drives a LIFO
    # stack over Get-ChildItem (name-ordered per directory); the bash half
    # consumes find's readdir order. Neither sorts. Where a port anchors ONE
    # rule id in more than one file, or more than one file carries a fence
    # defect, "first hit" and the order of the joined defect list can differ
    # between the halves -- and between two runs of the bash half on different
    # filesystems.
    #
    # Not fixed here, deliberately: sorting this side would make it
    # deterministic but no closer to the other side, and W2107 pitfall 4 forbids
    # changing the bash half while pairing it. Sorting BOTH is the real fix and
    # is one change touching both files -- the third such follow-up this task
    # found, with the control-character refusal and the .md case-sensitivity.
    # Today's canon anchors each id once per port, so it is unreachable on the
    # real fleet; it is written down because "unreachable today" is a fact about
    # the canon, not about this code.
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($startPath)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $kids = $null
        try { $kids = @(Get-ChildItem -LiteralPath $dir -Force) } catch { $result.Ok = $false; continue }
        foreach ($k in $kids) {
            $rel = $k.FullName
            if ($rel.StartsWith($startPath, [System.StringComparison]::Ordinal)) { $rel = $rel.Substring($startPath.Length).TrimStart([char]'/', [char]'\') }
            # A path carrying a tab or newline cannot be reported safely, and
            # the bash half refuses the whole port on it rather than printing a
            # row that could be misread as two.
            if ($rel -cmatch "[`t`n]") { $result.Unrepresentable = $true; $result.Ok = $false; continue }
            $isLink = [bool]($k.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            $isDir = [bool]($k.PSIsContainer)
            # (W2107 r2) ORDINAL and CASE-SENSITIVE, matching the bash half
            # exactly -- and this is a case where the obviously-safer-looking
            # change is the wrong one, so the reasoning is recorded rather than
            # the conclusion.
            #
            # A security pass argued for OrdinalIgnoreCase: NOTES.MD is markdown
            # to every renderer and every human, so an ordinal test makes an
            # UNEXPECTED anchor parked in it invisible. That is a REAL gap. It
            # was implemented, and then reverted, because it is a gap in BOTH
            # halves and closing it in one breaks the pair. Measured, not
            # assumed: `find -H <dir> -type f -name '*.md'` does not match
            # NOTES.MD even on a case-insensitive macOS volume, because fnmatch
            # is case-sensitive regardless of the filesystem. So an
            # OrdinalIgnoreCase test here scans a file the bash half never sees
            # -- the two disagree on a real input, which is precisely what
            # acceptance criterion 1 forbids, and W2107 pitfall 4 forbids fixing
            # it by changing the bash half while pairing it.
            #
            # Filed as a joint follow-up, alongside the control-character gap
            # above Assert-SafeCanonString. Both need one change touching both
            # halves; neither is a one-sided hardening.
            $isMd = $k.Name.EndsWith('.md', [System.StringComparison]::Ordinal)
            if ($isLink) {
                if ($isDir -or $isMd) {
                    $result.Items.Add([pscustomobject]@{ Full = $k.FullName; Rel = $rel; Disposition = 'refuse' })
                } else {
                    $result.Items.Add([pscustomobject]@{ Full = $k.FullName; Rel = $rel; Disposition = 'ignore' })
                }
                continue
            }
            if ($isDir) {
                # (W2107 r2) All FOUR of the bash half's prunes, not just this
                # one. It excludes '*/.git/*', '*/node_modules/*', '*/deps/*'
                # and '*/_build/*'; pruning only node_modules meant any .md
                # under .git, deps or _build was scanned by this half and
                # invisible to that one -- a dependency README carrying an
                # anchor becomes ok or UNEXPECTED here and MISSING there, the
                # walked-file count differs, and a fence defect in a vendored
                # README exits 1 here and 0 there. Latent on today's fleet,
                # which is exactly why the fleet-scan diff could not catch it.
                #
                # Case-SENSITIVE, for the same measured reason as the .md
                # test: the bash half's `-not -path '*/node_modules/*'` does not
                # prune Node_Modules, so pruning it here would make this half
                # skip a tree the other one walks.
                if ($k.Name -ceq 'node_modules' -or $k.Name -ceq '.git' -or
                    $k.Name -ceq 'deps' -or $k.Name -ceq '_build') { continue }
                $stack.Push($k.FullName)
                continue
            }
            if ($isMd) {
                $result.Items.Add([pscustomobject]@{ Full = $k.FullName; Rel = $rel; Disposition = 'scan' })
            }
        }
    }
    return $result
}

$script:AnchorPattern = '<!--[ \t]*canon:([A-Za-z0-9][A-Za-z0-9_-]*)[ \t]+v([0-9]+)[ \t]*-->'

# Every anchor in one file. Returns Ok=$false when the file could not be
# scanned, so the caller refuses the port instead of judging it on a list short
# by exactly the files that failed -- a short list is fatal for the UNEXPECTED
# sweep specifically, which can only fire on anchors it sees.
function Get-FileAnchors {
    param([string]$Path, [string]$Rel)
    $read = Read-CanonBytes -Path $Path
    if (-not $read.Ok) { return @{ Ok = $false; Hits = @() } }
    $hits = New-Object System.Collections.Generic.List[object]
    $lines = Split-CanonLines -Text $read.Text
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Matches($lines[$i], $script:AnchorPattern)
        foreach ($mm in $m) {
            $hits.Add([pscustomobject]@{
                Id = $mm.Groups[1].Value; Version = $mm.Groups[2].Value
                Where = ($Rel + ':' + ($i + 1))
            })
        }
    }
    return @{ Ok = $true; Hits = $hits }
}

function Get-PortAnchors {
    param($Walk, [string]$ExcludeCanon)
    if (-not $Walk.Ok) { return @{ Ok = $false; Hits = @() } }
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Walk.Items) {
        if ($it.Disposition -ceq 'ignore') { continue }
        if ($it.Disposition -ceq 'refuse') { return @{ Ok = $false; Hits = @() } }
        if ($ExcludeCanon -and $it.Full -ceq $ExcludeCanon) { continue }
        $r = Get-FileAnchors -Path $it.Full -Rel $it.Rel
        if (-not $r.Ok) { return @{ Ok = $false; Hits = @() } }
        foreach ($h in $r.Hits) { $hits.Add($h) }
    }
    return @{ Ok = $true; Hits = $hits }
}

# --------------------------------------------------------------------------
# The one property check this version implements: fence-nesting v1.
#
# Ported faithfully from the bash half, which is the reference implementation
# of D217. An empty return means CLEAN, so "I could not open this file" must
# NOT use it -- that was the round-5 defect: an unreadable file returned clean,
# was counted into the file total, and printed "property verified across N
# markdown files" naming a count that included a file nobody read.
#
# The nested-fence branch OVER-approximates deliberately: an inner opener whose
# closer ends the outer block and literal text that looks like one are
# structurally identical, and the remedy is the same either way. Do not "fix"
# it as a false positive.
# --------------------------------------------------------------------------
function Test-FenceDefect {
    param([string]$Path)
    $read = Read-CanonBytes -Path $Path
    if (-not $read.Ok) { return 'unreadable' }
    $lines = Split-CanonLines -Text $read.Text
    $open = $false; $openLen = 0; $openLine = 0; $openChar = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $stripped = $lines[$i] -replace '^[ \t]+', ''
        $fchar = ''
        if ($stripped.StartsWith('```', [System.StringComparison]::Ordinal)) { $fchar = '`' }
        elseif ($stripped.StartsWith('~~~', [System.StringComparison]::Ordinal)) { $fchar = '~' }
        else { continue }
        $rest = $stripped
        $run = 0
        while ($rest.Length -gt 0 -and $rest[0] -ceq $fchar) { $rest = $rest.Substring(1); $run++ }
        if (-not $open) {
            if ($fchar -ceq '`' -and $rest.Contains('`')) { continue }
            $open = $true; $openLen = $run; $openLine = $i + 1; $openChar = $fchar
        } elseif ($fchar -ceq $openChar) {
            $tail = $rest -replace '^[ \t]+', ''
            if (-not $tail -and $run -ge $openLen) {
                $open = $false; $openLen = 0; $openLine = 0; $openChar = ''
            } elseif ($tail -and $run -eq $openLen) {
                return ('nested:' + ($i + 1))
            }
        }
    }
    if ($open) { return ('unclosed:' + $openLine) }
    return ''
}

# --------------------------------------------------------------------------
# The verdict dispatcher.
#
# One site produces the printed row, the counter and the work-list entry, so
# the tally cannot disagree with the body and a finding cannot fail the gate
# while leaving the work list empty. Add-Record is the ONLY writer of
# $script:Status -- the bash half's round-5 finding #6 exists precisely because
# a suppressed record left a port green, and that invariant is what makes the
# suppression impossible to reintroduce quietly.
# --------------------------------------------------------------------------
function Reset-RunState {
    $script:N = @{ ok=0; MISSING=0; STALE=0; UNEXPECTED=0; DEFECT=0; UNVERIFIABLE=0; deferred=0; na=0 }
    $script:AnchorOk = 0
    $script:CatFindings = 0
    $script:Status = 0
    $script:GateFault = $false
    $script:PortDirty = $false
    $script:WorkList = New-Object System.Collections.Generic.List[string]
    $script:Out = New-Object System.Collections.Generic.List[string]
}

function Add-Record {
    param(
        [string]$Kind, [string]$Indent, [string]$Message,
        [string]$Work = '', [string]$Subject = ''
    )
    $script:N[$Kind] = $script:N[$Kind] + 1
    switch -CaseSensitive ($Kind) {
        'ok'           { $script:Out.Add("$Indent" + "ok: $Message") }
        'MISSING'      { $script:Out.Add("$Indent" + "MISSING: $Message") }
        'STALE'        { $script:Out.Add("$Indent" + "STALE: $Message") }
        'UNEXPECTED'   { $script:Out.Add("$Indent" + "UNEXPECTED: $Message") }
        'DEFECT'       { $script:Out.Add("$Indent" + "DEFECT: $Message") }
        'UNVERIFIABLE' { $script:Out.Add("$Indent" + "UNVERIFIABLE: $Message") }
        'deferred'     { if ($Message) { $script:Out.Add("$Indent" + "deferred: $Message") } }
        'na'           { if ($Message) { $script:Out.Add("$Indent" + "not applicable: $Message") } }
    }
    if ($Kind -ceq 'ok' -or $Kind -ceq 'deferred' -or $Kind -ceq 'na') { return }
    $script:Status = 1
    $script:PortDirty = $true
    if ($Subject -ceq 'catalog') { $script:CatFindings++ }
    if ($Work) { $script:WorkList.Add("  $Work") }
}

function Get-AnchorLiteral {
    param([string]$Id, [string]$Version)
    return "<!-- canon:$Id v$Version -->"
}

# (W2107 r2) An ORDINAL-comparer dictionary, not @{}. A PowerShell hashtable
# literal compares keys case-INSENSITIVELY, and the key looked up here is a
# canon-controlled rule id whose validator admits ^[A-Za-z0-9][A-Za-z0-9_-]*$ --
# so "Fence-Nesting" is a legal id that resolved to the fence-nesting
# implementation and reported "property verified across N markdown files" at
# exit 0, where the bash half's case-based lookup finds nothing and reports
# UNVERIFIABLE at exit 1. A false green, in the exact direction this file
# exists to prevent, reached through the container rather than the comparison:
# the -cne guarding the version below is correct and was simply never reached.
$script:PropertyImpl = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$script:PropertyImpl.Add('fence-nesting', '1')

$script:Catalogs = @(
    'stride-codex-marketplace/plugins/stride-codex',
    'stride-copilot-marketplace/plugins/stride-copilot',
    'stride-copilot-marketplace/plugins/stride-copilot-lite'
)

function Invoke-CanonCheck {
    param([string]$CanonPath, [string]$PortsParentPath)

    Reset-RunState
    $parsed = ConvertFrom-Canon -Path $CanonPath
    $ports = $parsed.Ports
    $entries = $parsed.Entries

    $script:Out.Add("port canon drift check -- schema $script:SupportedSchema")
    $script:Out.Add("  canon:        $CanonPath")
    $script:Out.Add("  ports parent: $PortsParentPath")
    $script:Out.Add('')
    $script:Out.Add('rules:')
    foreach ($e in $entries) { $script:Out.Add("  $($e.Id) v$($e.Version) ($($e.Check))") }
    $script:Out.Add('')

    $cleanPorts = New-Object System.Collections.Generic.List[string]
    $dirtyPorts = New-Object System.Collections.Generic.List[string]

    for ($pi = 0; $pi -lt $ports.Count; $pi++) {
        $p = $ports[$pi]
        # Re-validated here rather than trusted across the parse boundary: this
        # value becomes a filesystem path.
        if ($p.Dir -cnotmatch '^[A-Za-z0-9._-]+$' -or $p.Dir -ceq '.' -or $p.Dir -ceq '..') {
            [Console]::Error.WriteLine("GATE ERROR: port ""$($p.Id)"" resolved to dir ""$($p.Dir)"", which is not a single path segment")
            $script:GateFault = $true
            $script:Out.Add('')
            continue
        }
        $ptree = Join-Path $PortsParentPath $p.Dir
        $script:PortDirty = $false
        $script:Out.Add($p.Id)

        if (-not (Test-Path -LiteralPath $ptree -PathType Container)) {
            if (-not $p.Exists) {
                $script:Out.Add("  deferred: not scaffolded on disk ($($p.Dir)); all rules deferred until it is")
                foreach ($e in $entries) { Add-Record -Kind 'deferred' -Indent '  ' -Message '' }
                $script:Out.Add('  verdict: deferred -- nothing owed yet')
            } else {
                [Console]::Error.WriteLine("  GATE ERROR: registry says $($p.Id) exists but $ptree is not a directory")
                $script:Out.Add("  GATE ERROR: registry says $($p.Id) exists but $ptree is not a directory")
                $script:GateFault = $true
                $script:Out.Add('  verdict: NOT EXAMINED')
            }
            $script:Out.Add('')
            continue
        }

        $walk = Get-PortMarkdown -Root $ptree
        $found = Get-PortAnchors -Walk $walk -ExcludeCanon $CanonPath

        if (-not $found.Ok) {
            # One port-level refusal FIRST, owed by the port rather than by any
            # cell. A port whose rows are all not_applicable/deferred otherwise
            # recorded NOTHING -- and since Add-Record is the only writer of
            # Status, the run printed NOT FULLY EXAMINED and still exited 0.
            Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                -Message "$($p.Id) -- could not fully enumerate $ptree; refusing to judge any cell on a partial file list" `
                -Work "$($p.Id): make $ptree readable so the anchor scan can run"
            foreach ($e in $entries) {
                $row = $e.AppliesTo[$pi]
                if ($row.Status -cne 'required') { continue }
                Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                    -Message "$($e.Id) -- could not fully enumerate $ptree; refusing to judge anchors on a partial file list" `
                    -Work "$($p.Id): make $ptree readable so the anchor scan can run"
            }
            $script:Out.Add('  verdict: NOT FULLY EXAMINED')
            $dirtyPorts.Add($p.Id)
            $script:Out.Add('')
            continue
        }

        foreach ($e in $entries) {
            $row = $e.AppliesTo[$pi]
            $astatus = $row.Status

            if ($astatus -ceq 'deferred') { Add-Record -Kind 'deferred' -Indent '  ' -Message ''; continue }

            if ($e.Check -ceq 'property') {
                if ($astatus -ceq 'not_applicable') { Add-Record -Kind 'na' -Indent '  ' -Message ''; continue }
                $impl = ''
                if ($script:PropertyImpl.ContainsKey($e.Id)) { $impl = $script:PropertyImpl[$e.Id] }
                if (-not $impl -or $impl -cne [string]$e.Version) {
                    $shown = $impl
                    if (-not $shown) { $shown = 'none' }
                    # The work belongs to THIS SCRIPT, not to the port. Routing
                    # it per-port turned one script edit into one work item per
                    # port, pointing readers at repos containing no check.
                    Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                        -Message "$($e.Id) v$($e.Version) -- this checker implements v$shown; refusing to pass on logic that no longer matches the rule" `
                        -Work "scripts/check-port-canon.ps1: implement the $($e.Id) property check at v$($e.Version) (this is a checker change, not a port change)"
                    continue
                }
                $nfiles = 0
                $hits = New-Object System.Collections.Generic.List[string]
                $linked = New-Object System.Collections.Generic.List[string]
                $unread = New-Object System.Collections.Generic.List[string]
                foreach ($it in $walk.Items) {
                    if ($it.Disposition -ceq 'ignore') { continue }
                    if ($it.Disposition -ceq 'refuse') { $linked.Add(' ' + $it.Rel); continue }
                    $nfiles++
                    $d = Test-FenceDefect -Path $it.Full
                    if ($d -ceq 'unreadable') { $unread.Add(' ' + $it.Rel); continue }
                    if ($d) { $hits.Add(' ' + $it.Rel + '(' + $d + ')') }
                }
                if ($linked.Count -gt 0) {
                    Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                        -Message "$($e.Id) -- refusing to follow symlinked markdown:$($linked -join ''); its target can resolve outside $ptree" `
                        -Work "$($p.Id): replace the symlink(s)$($linked -join '') with real files, or remove them from the port tree"
                    continue
                }
                if ($unread.Count -gt 0) {
                    Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                        -Message "$($e.Id) -- could not read$($unread -join ''); refusing to report a property verified over files that were never opened" `
                        -Work "$($p.Id): make$($unread -join '') readable so the $($e.Id) property check can run"
                    continue
                }
                if (-not $walk.Ok) {
                    Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                        -Message "$($e.Id) -- could not enumerate the markdown under $ptree; refusing to report a check that did not run" `
                        -Work "$($p.Id): make $ptree readable so the $($e.Id) property check can run"
                    continue
                }
                if ($nfiles -eq 0) {
                    # A pass produced by an empty walk is not a pass.
                    Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                        -Message "$($e.Id) -- no markdown was enumerated under $ptree; refusing to report a property verified over an empty walk" `
                        -Work "$($p.Id): check that $ptree is a populated checkout; the $($e.Id) property check had nothing to walk"
                    continue
                }
                if ($hits.Count -gt 0) {
                    Add-Record -Kind 'DEFECT' -Indent '  ' -Message "$($e.Id) --$($hits -join '')" `
                        -Work "$($p.Id): fix the $($e.Id) violations listed in the body above"
                } else {
                    Add-Record -Kind 'ok' -Indent '  ' -Message "$($e.Id) (property verified across $nfiles markdown files)"
                }
                continue
            }

            # check: anchor
            $hit = $null
            foreach ($h in $found.Hits) { if ($h.Id -ceq $e.Id) { $hit = $h; break } }

            if ($astatus -ceq 'not_applicable') {
                if ($hit) {
                    Add-Record -Kind 'UNEXPECTED' -Indent '  ' `
                        -Message "$($e.Id) at $($hit.Where) -- this port does not owe this rule" `
                        -Work "$($p.Id): remove the $($e.Id) anchor at $($hit.Where); this port does not owe that rule"
                } else {
                    Add-Record -Kind 'na' -Indent '  ' -Message ''
                }
                continue
            }

            if (-not $hit) {
                Add-Record -Kind 'MISSING' -Indent '  ' -Message "$($e.Id) v$($e.Version)" `
                    -Work "$($p.Id): add $(Get-AnchorLiteral -Id $e.Id -Version $e.Version) beside this port's own statement of the $($e.Id) rule"
            } elseif ($hit.Version -ceq [string]$e.Version) {
                $script:AnchorOk++
                Add-Record -Kind 'ok' -Indent '  ' -Message "$($e.Id) v$($e.Version) at $($hit.Where)"
            } else {
                Add-Record -Kind 'STALE' -Indent '  ' `
                    -Message "$($e.Id) at $($hit.Where) carries v$($hit.Version), canon is at v$($e.Version)" `
                    -Work "$($p.Id): update $($hit.Where) to $(Get-AnchorLiteral -Id $e.Id -Version $e.Version)"
            }
        }

        # Anchors for ids the canon does not define at all.
        foreach ($h in $found.Hits) {
            $known = $false
            foreach ($e in $entries) { if ($e.Id -ceq $h.Id) { $known = $true; break } }
            if (-not $known) {
                Add-Record -Kind 'UNEXPECTED' -Indent '  ' `
                    -Message "canon defines no rule ""$($h.Id)"" (found at $($h.Where))" `
                    -Work "$($p.Id): remove the unknown ""$($h.Id)"" anchor at $($h.Where), or add that rule to the canon"
            }
        }

        if ($script:PortDirty) {
            $script:Out.Add('  verdict: NEEDS WORK')
            $dirtyPorts.Add($p.Id)
        } else {
            $script:Out.Add('  verdict: clean')
            $cleanPorts.Add($p.Id)
        }
        $script:Out.Add('')
    }

    # --- vendored catalog copies ---
    $script:Out.Add('vendored catalog copies')
    $script:Out.Add('  (this list is owned by this script, not by the canon: the canon registers')
    $script:Out.Add('   ports. stride-marketplace and stride-gemini-marketplace reference their')
    $script:Out.Add('   plugins by URL and vendor no files, so they have nothing to drift.)')
    $catAbsent = 0
    foreach ($cat in $script:Catalogs) {
        $ctree = Join-Path $PortsParentPath $cat
        if (-not (Test-Path -LiteralPath $ctree -PathType Container)) {
            $script:Out.Add("  NOT EXAMINED: $cat is not checked out here -- this run says nothing about it")
            $catAbsent++
            continue
        }
        $cwalk = Get-PortMarkdown -Root $ctree
        $cfound = Get-PortAnchors -Walk $cwalk -ExcludeCanon $CanonPath
        if (-not $cfound.Ok) {
            Add-Record -Kind 'UNVERIFIABLE' -Indent '  ' `
                -Message "catalog $cat -- could not fully enumerate $ctree; refusing to judge anchors on a partial file list" `
                -Work "catalog $cat`: make $ctree readable so the anchor scan can run" -Subject 'catalog'
            continue
        }
        foreach ($e in $entries) {
            if ($e.Check -ceq 'property') { continue }
            $hit = $null
            foreach ($h in $cfound.Hits) { if ($h.Id -ceq $e.Id) { $hit = $h; break } }
            if (-not $hit) {
                Add-Record -Kind 'MISSING' -Indent '  ' -Message "catalog $cat -- $($e.Id) v$($e.Version)" `
                    -Work "catalog $cat`: re-vendor from the port, or add $(Get-AnchorLiteral -Id $e.Id -Version $e.Version)" -Subject 'catalog'
            } elseif ($hit.Version -ceq [string]$e.Version) {
                Add-Record -Kind 'ok' -Indent '  ' -Message "catalog $cat -- $($e.Id) v$($e.Version) at $($hit.Where)"
            } else {
                Add-Record -Kind 'STALE' -Indent '  ' `
                    -Message "catalog $cat -- $($e.Id) at $($hit.Where) carries v$($hit.Version), canon is at v$($e.Version)" `
                    -Work "catalog $cat`: re-vendor; its $($e.Id) anchor is v$($hit.Version) and the canon is at v$($e.Version)" -Subject 'catalog'
            }
        }
        foreach ($h in $cfound.Hits) {
            $known = $false
            foreach ($e in $entries) { if ($e.Id -ceq $h.Id) { $known = $true; break } }
            if (-not $known) {
                Add-Record -Kind 'UNEXPECTED' -Indent '  ' `
                    -Message "catalog $cat -- canon defines no rule ""$($h.Id)"" (found at $($h.Where))" `
                    -Work "catalog $cat`: remove or re-vendor the unknown ""$($h.Id)"" anchor" -Subject 'catalog'
            }
        }
    }
    $script:Out.Add('')

    $script:Out.Add('tally (all subjects, ports and catalogs together):')
    $script:Out.Add("  ok $($script:N['ok']), missing $($script:N['MISSING']), stale $($script:N['STALE']), unexpected $($script:N['UNEXPECTED']), defect $($script:N['DEFECT']), unverifiable $($script:N['UNVERIFIABLE'])")
    $script:Out.Add("  of those, $script:CatFindings are in vendored catalogs; $($script:N['na']) cells not applicable; $($script:N['deferred']) cells deferred")
    $script:Out.Add('  note: these count RULE CELLS, not repositories -- see the verdict lines above for repositories')
    if ($catAbsent -gt 0) { $script:Out.Add("  note: $catAbsent vendored catalog(s) were not checked out and were NOT examined") }
    $script:Out.Add('')
    if ($cleanPorts.Count -gt 0) { $script:Out.Add('clean repos: ' + ($cleanPorts -join ' ')) }
    if ($dirtyPorts.Count -gt 0) { $script:Out.Add('repos needing work: ' + ($dirtyPorts -join ' ')) }

    if ($script:WorkList.Count -gt 0) {
        $script:Out.Add('')
        $script:Out.Add('work list:')
        foreach ($w in $script:WorkList) { $script:Out.Add($w) }
    } elseif ($script:Status -ne 0) {
        $script:Out.Add('')
        $script:Out.Add('work list: EMPTY, but findings exist -- this is a defect in this script;')
        $script:Out.Add('  every finding is meant to produce an actionable entry.')
    }

    if ($script:N['MISSING'] -gt 0 -and $script:AnchorOk -eq 0) {
        $script:Out.Add('')
        $script:Out.Add('note: every anchor cell is MISSING and none is present. If the anchor contract')
        $script:Out.Add('  is new to this fleet, that is the expected first-run state, not a broken')
        $script:Out.Add('  checker: no port has adopted an anchor yet. Read the work list as a work')
        $script:Out.Add('  list, not as a verdict on the fleet or on this tool.')
    }

    # [Console]::Out, not Write-Output: this function RETURNS its exit code,
    # and anything written to the output stream would be captured into that
    # return value by the caller's `exit (...)` -- the report would vanish and
    # the exit code would become an array. The bash half writes to stdout; so
    # does this, just through the channel a function cannot accidentally
    # swallow.
    foreach ($l in $script:Out) { [Console]::Out.WriteLine($l) }

    if ($script:GateFault) {
        [Console]::Error.WriteLine('GATE ERROR: at least one registered port could not be examined; this run proved nothing about it')
        return 2
    }
    return $script:Status
}


function Invoke-SelfTestBody {
    param([string]$Tmp)
    $f3 = $script:F3

    # --- the green case. Without it, a checker that always reports MISSING
    # --- would satisfy every red case below and look correct.
    New-StDir @("$Tmp/k/alpha", "$Tmp/k/beta")
    New-StCanon -Path "$Tmp/k.md" -Schema 1
    Set-StFile -Path "$Tmp/k/alpha/a.md" -Text "x`n<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/k/beta/b.md"  -Text "x`n<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/k"
    St-Assert "all-clean tree exits 0" 0 $r.ExitCode "ok: rule-one v1" $r.Output
    St-Refute "all-clean tree prints no work list" "work list:" $r.Output

    # --- MISSING
    New-StDir @("$Tmp/m/alpha", "$Tmp/m/beta")
    Set-StFile -Path "$Tmp/m/alpha/a.md" -Text "x`n"
    Set-StFile -Path "$Tmp/m/beta/b.md"  -Text "x`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/m"
    St-Assert "absent anchor reports MISSING and exits 1" 1 $r.ExitCode "MISSING: rule-one v1" $r.Output
    St-Assert "MISSING produces an actionable work list entry" 1 $r.ExitCode "add <!-- canon:rule-one v1 -->" $r.Output

    # --- STALE
    New-StCanon -Path "$Tmp/s.md" -Schema 1 -BetaStatus 'required' -Version '2'
    New-StDir @("$Tmp/s/alpha", "$Tmp/s/beta")
    Set-StFile -Path "$Tmp/s/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/s/beta/b.md"  -Text "<!-- canon:rule-one v2 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/s.md" -PortsParent "$Tmp/s"
    St-Assert "older anchor reports STALE" 1 $r.ExitCode "STALE: rule-one" $r.Output

    # --- UNEXPECTED, both kinds
    New-StCanon -Path "$Tmp/u.md" -Schema 1 -BetaStatus 'not_applicable'
    New-StDir @("$Tmp/u/alpha", "$Tmp/u/beta")
    Set-StFile -Path "$Tmp/u/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/u/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/u.md" -PortsParent "$Tmp/u"
    St-Assert "anchor on a not_applicable port reports UNEXPECTED" 1 $r.ExitCode "UNEXPECTED: rule-one" $r.Output

    New-StDir @("$Tmp/x/alpha", "$Tmp/x/beta")
    Set-StFile -Path "$Tmp/x/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n<!-- canon:ghost-rule v1 -->`n"
    Set-StFile -Path "$Tmp/x/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/x"
    St-Assert "anchor for an undefined id reports UNEXPECTED" 1 $r.ExitCode 'canon defines no rule "ghost-rule"' $r.Output

    # --- the canon self-exclusion. The canon defines every anchor and lives
    # --- inside a registered port, so scanning it reports that port compliant
    # --- off the definition site. A RELATIVE path is what broke it.
    New-StDir @("$Tmp/e/alpha/docs", "$Tmp/e/beta")
    New-StCanon -Path "$Tmp/e/alpha/docs/port-canon.md" -Schema 1
    Set-StFile -Path "$Tmp/e/beta/b.md" -Text "x`n"
    $r = Invoke-StRun -Canon "$Tmp/e/alpha/docs/port-canon.md" -PortsParent "$Tmp/e"
    St-Assert "canon inside a port does not make that port compliant" 1 $r.ExitCode "MISSING: rule-one v1" $r.Output
    St-Refute "canon is never reported as an adoption site" "ok: rule-one v1 at docs/port-canon.md" $r.Output
    $r = Invoke-StRun -Canon 'alpha/docs/port-canon.md' -PortsParent '.' -WorkDir "$Tmp/e"
    St-Assert "relative --canon still excludes the canon" 1 $r.ExitCode "MISSING: rule-one v1" $r.Output

    # --- a registered, exists:true port whose directory is absent is a gate
    # --- fault, and a gate fault must not be downgraded by an ordinary finding
    # --- recorded later. Order matters: the absent port is listed FIRST.
    Set-StCanonFile -Path "$Tmp/gf.md" -Lines @(
        '# canon'
        "${f3}json"
        '{ "canon_schema_version": 1,'
        '  "ports": [ {"id": "gone", "family": "f", "dir": "gone", "exists": true, "note": ""},'
        '             {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""} ] }'
        "$f3"
        '<!-- canon:rule-one v1 -->'
        "${f3}json"
        '{ "id": "rule-one", "version": 1, "status": "active", "superseded_by": null,'
        '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
        '  "applies_to": [ {"port": "gone", "status": "required", "variant": "", "reason": ""},'
        '                  {"port": "alpha", "status": "required", "variant": "", "reason": ""} ] }'
        "$f3"
    )
    New-StDir @("$Tmp/gf/alpha")
    Set-StFile -Path "$Tmp/gf/alpha/a.md" -Text "x`n"
    $r = Invoke-StRun -Canon "$Tmp/gf.md" -PortsParent "$Tmp/gf"
    St-Assert "an absent required port is a gate fault, not downgraded to a finding" 2 $r.ExitCode "" $r.Output

    # --- deferred on a port that DOES exist
    New-StCanon -Path "$Tmp/df.md" -Schema 1 -BetaStatus 'deferred'
    New-StDir @("$Tmp/df/alpha", "$Tmp/df/beta")
    Set-StFile -Path "$Tmp/df/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/df/beta/b.md"  -Text "x`n"
    $r = Invoke-StRun -Canon "$Tmp/df.md" -PortsParent "$Tmp/df"
    St-Assert "deferred on an existing port is not a finding" 0 $r.ExitCode "1 cells deferred" $r.Output
    St-Refute "deferred port is never reported MISSING" "MISSING" $r.Output

    # --- deferred on a port that does not exist at all
    Set-StCanonFile -Path "$Tmp/dg.md" -Lines @(
        '# canon'
        "${f3}json"
        '{ "canon_schema_version": 1,'
        '  "ports": [ {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""},'
        '             {"id": "ghost", "family": "f", "dir": "ghost", "exists": false, "note": "n"} ] }'
        "$f3"
        '<!-- canon:rule-one v1 -->'
        "${f3}json"
        '{ "id": "rule-one", "version": 1, "status": "active", "superseded_by": null,'
        '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
        '  "applies_to": [ {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
        '                  {"port": "ghost", "status": "deferred", "variant": "", "reason": "r"} ] }'
        "$f3"
    )
    New-StDir @("$Tmp/dg/alpha")
    Set-StFile -Path "$Tmp/dg/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/dg.md" -PortsParent "$Tmp/dg"
    St-Assert "unscaffolded deferred port reports distinctly and exits 0" 0 $r.ExitCode "deferred: not scaffolded" $r.Output

    # --- vendored catalog copies, checked against the same rules but tallied
    # --- separately. The UNEXPECTED sweep must fire there too.
    $cx = "$Tmp/c/stride-codex-marketplace/plugins/stride-codex"
    New-StDir @("$Tmp/c/alpha", "$Tmp/c/beta", $cx)
    Set-StFile -Path "$Tmp/c/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/c/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$cx/vend.md" -Text "x`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/c"
    St-Assert "a catalog missing an anchor is a finding" 1 $r.ExitCode "MISSING: catalog stride-codex-marketplace" $r.Output
    Set-StFile -Path "$cx/vend.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/c"
    St-Assert "a fully-vendored catalog is clean" 0 $r.ExitCode "ok: catalog stride-codex-marketplace" $r.Output
    Set-StFile -Path "$cx/vend.md" -Text "<!-- canon:rule-one v1 -->`n<!-- canon:invented v9 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/c"
    St-Assert "an invented anchor in a catalog is UNEXPECTED, not silence" 1 $r.ExitCode 'UNEXPECTED: catalog .* no rule "invented"' $r.Output
    New-StCanon -Path "$Tmp/cs.md" -Schema 1 -BetaStatus 'required' -Version '2'
    Set-StFile -Path "$cx/vend.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/c/alpha/a.md" -Text "<!-- canon:rule-one v2 -->`n"
    Set-StFile -Path "$Tmp/c/beta/b.md"  -Text "<!-- canon:rule-one v2 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/cs.md" -PortsParent "$Tmp/c"
    St-Assert "a stale catalog copy is a finding" 1 $r.ExitCode "STALE: catalog stride-codex-marketplace" $r.Output

    # --- the property check: both fence characters, the unclosed verdict, and
    # --- the version binding that makes UNVERIFIABLE possible.
    New-StCanon -Path "$Tmp/p1.md" -Schema 1 -BetaStatus 'required' -Version '1' -Check 'property' -Id 'fence-nesting'
    New-StDir @("$Tmp/p1/alpha", "$Tmp/p1/beta")
    Set-StFile -Path "$Tmp/p1/alpha/good.md" -Text "# t`n`n${f3}bash`necho hi`n$f3`n"
    Set-StFile -Path "$Tmp/p1/beta/good.md"  -Text "# t`n`n${f3}bash`necho hi`n$f3`n"
    $r = Invoke-StRun -Canon "$Tmp/p1.md" -PortsParent "$Tmp/p1"
    St-Assert "a clean tree passes the property check" 0 $r.ExitCode "ok: fence-nesting" $r.Output

    Set-StFile -Path "$Tmp/p1/alpha/bad.md" -Text "# t`n`n${f3}markdown`n## s`n`n${f3}json`n{}`n$f3`n`n$f3`n"
    $r = Invoke-StRun -Canon "$Tmp/p1.md" -PortsParent "$Tmp/p1"
    St-Assert "a backtick nested fence is a DEFECT" 1 $r.ExitCode "DEFECT: fence-nesting" $r.Output

    Remove-Item -LiteralPath "$Tmp/p1/alpha/bad.md" -Force
    Set-StFile -Path "$Tmp/p1/alpha/bad.md" -Text "# t`n`n~~~markdown`n## s`n`n~~~json`n{}`n~~~`n`n~~~`n"
    $r = Invoke-StRun -Canon "$Tmp/p1.md" -PortsParent "$Tmp/p1"
    St-Assert "the same shape written with tildes is a DEFECT too" 1 $r.ExitCode "DEFECT: fence-nesting" $r.Output

    Remove-Item -LiteralPath "$Tmp/p1/alpha/bad.md" -Force
    Set-StFile -Path "$Tmp/p1/alpha/open.md" -Text "# t`n`n${f3}bash`necho never closed`n"
    $r = Invoke-StRun -Canon "$Tmp/p1.md" -PortsParent "$Tmp/p1"
    St-Assert "an unclosed fence is a DEFECT" 1 $r.ExitCode "unclosed:" $r.Output
    Remove-Item -LiteralPath "$Tmp/p1/alpha/open.md" -Force

    New-StCanon -Path "$Tmp/p7.md" -Schema 1 -BetaStatus 'required' -Version '7' -Check 'property' -Id 'fence-nesting'
    $r = Invoke-StRun -Canon "$Tmp/p7.md" -PortsParent "$Tmp/p1"
    St-Assert "a property entry ahead of this checker is UNVERIFIABLE" 1 $r.ExitCode "UNVERIFIABLE: fence-nesting v7" $r.Output
    St-Refute "an unimplemented property version never silently passes" "ok: fence-nesting" $r.Output

    # --- vendored trees are excluded: a node_modules copy is a dependency's
    # --- file, not the port's, and must not satisfy a rule.
    New-StDir @("$Tmp/nm/alpha/node_modules/dep", "$Tmp/nm/beta")
    Set-StFile -Path "$Tmp/nm/alpha/node_modules/dep/vendored.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/nm/alpha/a.md" -Text "x`n"
    Set-StFile -Path "$Tmp/nm/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/nm"
    St-Assert "an anchor inside node_modules does not satisfy the rule" 1 $r.ExitCode "MISSING: rule-one v1" $r.Output

    # --- the parser refuses rather than guessing. Each of these would
    # --- otherwise be a silently wrong verdict.
    $kText = [System.IO.File]::ReadAllText("$Tmp/k.md", [System.Text.Encoding]::GetEncoding(28591))
    Set-StFile -Path "$Tmp/ph.md" -Text ($kText + "`n### note`n${f3}json`n{""illustrative"": true}`n$f3`n")
    $r = Invoke-StRun -Canon "$Tmp/ph.md" -PortsParent "$Tmp/k"
    St-Assert "a json block matching neither shape halts" 2 $r.ExitCode "matches neither the registry shape" $r.Output

    Set-StFile -Path "$Tmp/bd.md" -Text ($kText -replace '"dir": "alpha"', '"dir": "../escape"')
    $r = Invoke-StRun -Canon "$Tmp/bd.md" -PortsParent "$Tmp/k"
    St-Assert "a dir that is not a single path segment halts" 2 $r.ExitCode "not a single path segment" $r.Output

    New-StCanon -Path "$Tmp/sv.md" -Schema 99
    $r = Invoke-StRun -Canon "$Tmp/sv.md" -PortsParent "$Tmp/k"
    St-Assert "an unknown canon_schema_version halts" 2 $r.ExitCode "not the schema this checker understands" $r.Output

    Set-StFile -Path "$Tmp/ord.md" -Text ($kText -replace '\{"port": "alpha", "status": "required"', '{"port": "beta", "status": "required"')
    $r = Invoke-StRun -Canon "$Tmp/ord.md" -PortsParent "$Tmp/k"
    St-Assert "applies_to out of registry order halts" 2 $r.ExitCode "rows must follow registry order" $r.Output

    Set-StFile -Path "$Tmp/vo.md" -Text ($kText -replace '"check": "anchor"', '"check": "sideways"')
    $r = Invoke-StRun -Canon "$Tmp/vo.md" -PortsParent "$Tmp/k"
    St-Assert "a value outside a closed vocabulary halts" 2 $r.ExitCode "outside the closed vocabulary" $r.Output

    Set-StFile -Path "$Tmp/vv.md" -Text ($kText -replace '"variant": "", "reason": "r"', '"variant": "made-up", "reason": "r"')
    $r = Invoke-StRun -Canon "$Tmp/vv.md" -PortsParent "$Tmp/k"
    St-Assert "a variant outside the declared vocabulary halts" 2 $r.ExitCode "outside the canon's declared vocabulary" $r.Output

    Set-StFile -Path "$Tmp/nd.md" -Text ($kText -replace '"defects": \["D1"\]', '"defects": []')
    $r = Invoke-StRun -Canon "$Tmp/nd.md" -PortsParent "$Tmp/k"
    St-Assert "an entry with no defect trace halts" 2 $r.ExitCode "empty defects array" $r.Output

    Set-StFile -Path "$Tmp/mk.md" -Text ($kText -replace '"check_hint": "h",', '')
    $r = Invoke-StRun -Canon "$Tmp/mk.md" -PortsParent "$Tmp/k"
    St-Assert "an entry missing a required key halts" 2 $r.ExitCode "missing required key" $r.Output

    # --- the invariant the report layer exists to hold: a non-zero exit ALWAYS
    # --- produces a non-empty work list.
    New-StDir @("$Tmp/inv/alpha", "$Tmp/inv/beta")
    Set-StFile -Path "$Tmp/inv/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n<!-- canon:invented-rule v9 -->`n"
    Set-StFile -Path "$Tmp/inv/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/inv"
    St-Assert "an unknown anchor fails the gate AND produces a work list" 1 $r.ExitCode "work list:" $r.Output
    St-Assert "the unknown-anchor work item names the port and the anchor" 1 $r.ExitCode "alpha: remove the unknown" $r.Output
    St-Refute "a failing run never claims a work list defect" "EMPTY, but findings exist" $r.Output

    # --- a per-port verdict line, so "which repos need work" is answerable
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/k"
    St-Assert "a clean port prints a clean verdict" 0 $r.ExitCode "verdict: clean" $r.Output
    St-Assert "a clean run lists the clean repos" 0 $r.ExitCode "clean repos:" $r.Output
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/m"
    St-Assert "a dirty port prints a NEEDS WORK verdict" 1 $r.ExitCode "verdict: NEEDS WORK" $r.Output
    St-Assert "a dirty run lists the repos needing work" 1 $r.ExitCode "repos needing work:" $r.Output
    St-Assert "a MISSING work item carries the anchor literal" 1 $r.ExitCode "add <!-- canon:rule-one v1 -->" $r.Output

    # --- a catalog finding must reach the kind counters, not only a side count.
    $ctx = "$Tmp/ct/stride-codex-marketplace/plugins/stride-codex"
    New-StDir @("$Tmp/ct/alpha", "$Tmp/ct/beta", $ctx)
    New-StCanon -Path "$Tmp/ct.md" -Schema 1 -BetaStatus 'required' -Version '2'
    Set-StFile -Path "$Tmp/ct/alpha/a.md" -Text "<!-- canon:rule-one v2 -->`n"
    Set-StFile -Path "$Tmp/ct/beta/b.md"  -Text "<!-- canon:rule-one v2 -->`n"
    Set-StFile -Path "$ctx/vend.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/ct.md" -PortsParent "$Tmp/ct"
    St-Assert "a stale catalog is counted in the stale tally, not hidden" 1 $r.ExitCode "stale 1" $r.Output
    St-Refute "the tally never reports stale 0 beside a STALE row" "stale 0," $r.Output

    # --- a catalog that is not checked out must be reported, never skipped
    $p2x = "$Tmp/pc2/stride-codex-marketplace/plugins/stride-codex"
    New-StDir @("$Tmp/pc2/alpha", "$Tmp/pc2/beta", $p2x)
    Set-StFile -Path "$Tmp/pc2/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/pc2/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$p2x/vend.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/pc2"
    St-Assert "an absent catalog is reported as NOT EXAMINED" 0 $r.ExitCode "NOT EXAMINED" $r.Output
    St-Assert "the summary counts the unexamined catalogs" 0 $r.ExitCode "were NOT examined" $r.Output

    # --- UNVERIFIABLE work belongs to the checker, not to every port
    New-StCanon -Path "$Tmp/uv.md" -Schema 1 -BetaStatus 'required' -Version '7' -Check 'property' -Id 'fence-nesting'
    New-StDir @("$Tmp/uv/alpha", "$Tmp/uv/beta")
    Set-StFile -Path "$Tmp/uv/alpha/a.md" -Text "clean`n"
    Set-StFile -Path "$Tmp/uv/beta/b.md"  -Text "clean`n"
    $r = Invoke-StRun -Canon "$Tmp/uv.md" -PortsParent "$Tmp/uv"
    # The bash half names its own filename here; this half names its own. That
    # is the one self-referencing difference the hook suites normalize out.
    St-Assert "UNVERIFIABLE routes the work to the checker" 1 $r.ExitCode "scripts/check-port-canon.ps1: implement" $r.Output
    St-Refute "UNVERIFIABLE does not tell a port to update a check it does not have" "alpha: update the fence-nesting property check" $r.Output

    # --- the first-run framing, so a red first report is not read as a bug
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/m"
    St-Assert "an all-missing run explains that this is the expected first-run state" 1 $r.ExitCode "expected first-run state" $r.Output

    # --- a property ok must say what it walked
    New-StCanon -Path "$Tmp/pv.md" -Schema 1 -BetaStatus 'required' -Version '1' -Check 'property' -Id 'fence-nesting'
    New-StDir @("$Tmp/pv/alpha", "$Tmp/pv/beta")
    Set-StFile -Path "$Tmp/pv/alpha/good.md" -Text "# t`n`n${f3}bash`necho hi`n$f3`n"
    Set-StFile -Path "$Tmp/pv/beta/good.md"  -Text "# t`n`n${f3}bash`necho hi`n$f3`n"
    $r = Invoke-StRun -Canon "$Tmp/pv.md" -PortsParent "$Tmp/pv"
    St-Assert "a property ok states how many files were walked" 0 $r.ExitCode "property verified across" $r.Output

    # --- record-forgery. This half has no record stream to forge, but the
    # --- refusal is a VERDICT and must match: a canon that halts the bash half
    # --- has to halt this one too, or the pair disagrees on a real input.
    $kText = [System.IO.File]::ReadAllText("$Tmp/k.md", [System.Text.Encoding]::GetEncoding(28591))
    New-StDir @("$Tmp/tb/alpha", "$Tmp/tb/beta", "$Tmp/decoy")
    Set-StFile -Path "$Tmp/tb/alpha/a.md" -Text "x`n"
    Set-StFile -Path "$Tmp/tb/beta/b.md"  -Text "x`n"
    Set-StFile -Path "$Tmp/decoy/planted.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/tab.md" -Text ($kText -replace '"family": "f"', ('"family": "f' + "`t" + '../decoy"'))
    $r = Invoke-StRun -Canon "$Tmp/tab.md" -PortsParent "$Tmp/tb"
    St-Assert "a tab in a canon string halts instead of shifting a field" 2 $r.ExitCode "would forge a record boundary" $r.Output
    St-Refute "a shifted field never yields a false ok" "ok: rule-one" $r.Output

    Set-StFile -Path "$Tmp/nl.md" -Text ($kText -replace '"check_hint": "h"', ('"check_hint": "h' + "`n" + 'PORT' + "`t" + '9' + "`t" + 'PHANTOM' + "`t" + 'f' + "`t" + 'phantom' + "`t" + 'true"'))
    $r = Invoke-StRun -Canon "$Tmp/nl.md" -PortsParent "$Tmp/k"
    St-Assert "a newline in a canon string cannot forge a record" 2 $r.ExitCode "would forge a record boundary" $r.Output
    St-Refute "no phantom port is ever processed" "PHANTOM" $r.Output

    # --- a filename that is a glob pattern must not be expanded away.
    New-StCanon -Path "$Tmp/pg.md" -Schema 1 -BetaStatus 'required' -Version '1' -Check 'property' -Id 'fence-nesting'
    New-StDir @("$Tmp/pg/alpha", "$Tmp/pg/beta")
    Set-StFile -Path "$Tmp/pg/alpha/a[1].md" -Text "# t`n`n${f3}markdown`n## s`n`n${f3}json`n{}`n$f3`n`n$f3`n"
    Set-StFile -Path "$Tmp/pg/alpha/a1.md" -Text "clean`n"
    Set-StFile -Path "$Tmp/pg/beta/b.md"   -Text "clean`n"
    $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/pg"
    St-Assert "a violation in a glob-shaped filename is still found" 1 $r.ExitCode "DEFECT: fence-nesting" $r.Output

    # --- an anchor id starting with a dash must not reach a tool as an option
    New-StDir @("$Tmp/dash/alpha", "$Tmp/dash/beta")
    Set-StFile -Path "$Tmp/dash/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n<!-- canon:-Ifoo v1 -->`n"
    Set-StFile -Path "$Tmp/dash/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/dash"
    St-Refute "a leading-dash anchor id never reaches grep as an option" "No such file or directory" $r.Output

    # --- an unreadable tree must be UNVERIFIABLE, never "property verified"
    if ($script:OnWindows) {
        St-Skip "an unreadable subtree is never reported as property verified" "chmod has no Windows equivalent here"
    } else {
        New-StDir @("$Tmp/perm/alpha/locked", "$Tmp/perm/beta")
        Set-StFile -Path "$Tmp/perm/beta/b.md" -Text "clean`n"
        try {
            & chmod 000 "$Tmp/perm/alpha/locked" 2>$null
            $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/perm"
        } finally { & chmod 755 "$Tmp/perm/alpha/locked" 2>$null }
        $alphaOnly = Get-StPortSection -Output $r.Output -Port 'alpha'
        St-Refute "an unreadable subtree is never reported as property verified" "ok: fence-nesting" $alphaOnly
    }

    # --- the dot segments pass a charset test but are not port directories,
    # --- and ".." walked the scan out of the ports parent entirely.
    Set-StFile -Path "$Tmp/dd.md" -Text ($kText -replace '"dir": "alpha"', '"dir": ".."')
    $r = Invoke-StRun -Canon "$Tmp/dd.md" -PortsParent "$Tmp/k"
    St-Assert "a dir of .. is refused as a traversal" 2 $r.ExitCode "directory traversal rather than a port directory" $r.Output
    Set-StFile -Path "$Tmp/dot.md" -Text ($kText -replace '"dir": "alpha"', '"dir": "."')
    $r = Invoke-StRun -Canon "$Tmp/dot.md" -PortsParent "$Tmp/k"
    St-Assert "a dir of . is refused as a traversal" 2 $r.ExitCode "directory traversal rather than a port directory" $r.Output

    # --- an entry id carrying regex metacharacters resolved a lookup to a
    # --- DIFFERENT entry's row and produced a clean verdict over ports that
    # --- owed the rule. Refused on charset, in both halves.
    Set-StFile -Path "$Tmp/rid.md" -Text ($kText -replace '"id": "rule-one"', '"id": "a\\.c"')
    $r = Invoke-StRun -Canon "$Tmp/rid.md" -PortsParent "$Tmp/k"
    St-Assert "an entry id outside the anchor charset is refused" 2 $r.ExitCode "outside the anchor charset" $r.Output

    # --- a filename containing the old sed delimiter silently dropped its anchor
    New-StDir @("$Tmp/pipe/alpha", "$Tmp/pipe/beta")
    Set-StFile -Path "$Tmp/pipe/alpha/ok.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/pipe/alpha/a|b.md" -Text "<!-- canon:ghost-rule v1 -->`n"
    Set-StFile -Path "$Tmp/pipe/beta/b.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/pipe"
    St-Assert "an anchor in a filename containing a pipe is still seen" 1 $r.ExitCode 'no rule "ghost-rule"' $r.Output

    # --- an unreadable subtree must make the ANCHOR pass unverifiable too, not
    # --- only the property pass: a short file list hides UNEXPECTED anchors.
    if ($script:OnWindows) {
        St-Skip "an unreadable subtree makes the anchor pass UNVERIFIABLE" "chmod has no Windows equivalent here"
        St-Skip "a partially-enumerated port is never reported clean" "chmod has no Windows equivalent here"
    } else {
        New-StDir @("$Tmp/aperm/alpha/locked", "$Tmp/aperm/beta")
        Set-StFile -Path "$Tmp/aperm/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/aperm/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/aperm/alpha/locked/hidden.md" -Text "<!-- canon:ghost v1 -->`n"
        try {
            & chmod 000 "$Tmp/aperm/alpha/locked" 2>$null
            $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/aperm"
        } finally { & chmod 755 "$Tmp/aperm/alpha/locked" 2>$null }
        St-Assert "an unreadable subtree makes the anchor pass UNVERIFIABLE" 1 $r.ExitCode "refusing to judge anchors on a partial file list" $r.Output
        St-Refute "a partially-enumerated port is never reported clean" "verdict: clean" (Get-StPortSection -Output $r.Output -Port 'alpha')
    }

    # --- the filename channel. A newline in a name cannot be represented in a
    # --- newline-delimited list, and the tail became a CWD-relative path -- so
    # --- the gate read a file OUTSIDE the scanned tree and blamed a port for it.
    New-StDir @("$Tmp/nlfn/alpha", "$Tmp/nlfn/beta", "$Tmp/nlcwd")
    Set-StFile -Path "$Tmp/nlfn/beta/b.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/nlcwd/planted.md" -Text "<!-- canon:ghost-from-cwd v1 -->`n"
    $nlName = "$Tmp/nlfn/alpha/a" + "`n" + "planted.md"
    $nlMade = $false
    try { Set-StFile -Path $nlName -Text "<!-- canon:rule-one v1 -->`n"; $nlMade = $true } catch { $nlMade = $false }
    if (-not $nlMade) {
        St-Skip "a newline-named file makes the tree UNVERIFIABLE" "this filesystem will not create a newline-bearing name"
        St-Skip "no file outside the ports parent is attributed to a port" "this filesystem will not create a newline-bearing name"
    } else {
        $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/nlfn" -WorkDir "$Tmp/nlcwd"
        St-Assert "a newline-named file makes the tree UNVERIFIABLE" 1 $r.ExitCode "refusing to judge anchors on a partial file list" $r.Output
        St-Refute "no file outside the ports parent is attributed to a port" "ghost-from-cwd" $r.Output
    }

    # --- a literal backslash-n in a filename became a REAL newline under awk's
    # --- -v escape processing and forged an anchor record. No -v here, but the
    # --- verdict must match.
    New-StDir @("$Tmp/forge/alpha", "$Tmp/forge/beta")
    Set-StFile -Path "$Tmp/forge/beta/b.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/forge/alpha/q\nrule-one\t1\tzz.md" -Text "<!-- canon:other v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/forge"
    St-Assert "a filename cannot forge an anchor record" 1 $r.ExitCode "MISSING: rule-one v1" $r.Output
    St-Refute "a forged path never yields an ok cell" "ok: rule-one v1 at zz.md" $r.Output

    # --- awkward but REPRESENTABLE names must still be scanned, not refused:
    # --- the refusal is about tabs and newlines, not about odd characters.
    New-StDir @("$Tmp/odd/alpha", "$Tmp/odd/beta")
    Set-StFile -Path "$Tmp/odd/alpha/-e.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/odd/beta/a b`$(id)[1]*.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/odd"
    St-Assert "odd but representable filenames are scanned, not refused" 0 $r.ExitCode "ok: rule-one v1 at -e.md" $r.Output


    # ======================================================================
    # ROUND 5 (W2108). One root shape behind all of these: enumeration
    # SUCCEEDING was read as "the tree was examined", so every read failure
    # below it collapsed into the same empty output a clean file produces.
    # This half reaches that shape more easily than bash does -- an
    # -ErrorAction SilentlyContinue anywhere in the read path would recreate
    # every one of them at once.
    # ======================================================================

    # --- a port owing NOTHING still owes an UNEXPECTED sweep, so an
    # --- unenumerable tree must refuse even when no entry is required.
    if ($script:OnWindows) {
        St-Skip "an unenumerable port with no required rule still fails the gate" "chmod has no Windows equivalent here"
        St-Skip "an unenumerable port never exits clean for want of a required rule" "chmod has no Windows equivalent here"
    } else {
        New-StCanon -Path "$Tmp/na.md" -Schema 1 -BetaStatus 'not_applicable'
        New-StDir @("$Tmp/nax/alpha", "$Tmp/nax/beta/locked")
        Set-StFile -Path "$Tmp/nax/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/nax/beta/locked/hidden.md" -Text "<!-- canon:rule-one v1 -->`n"
        try {
            & chmod 000 "$Tmp/nax/beta/locked" 2>$null
            $r = Invoke-StRun -Canon "$Tmp/na.md" -PortsParent "$Tmp/nax"
        } finally { & chmod 755 "$Tmp/nax/beta/locked" 2>$null }
        St-Assert "an unenumerable port with no required rule still fails the gate" 1 $r.ExitCode "refusing to judge any cell on a partial file list" $r.Output
        St-Refute "an unenumerable port never exits clean for want of a required rule" "(?m)^clean repos:.*beta" $r.Output
    }

    # --- an unreadable FILE is not a clean file.
    if ($script:OnWindows) {
        St-Skip "an unreadable file is never counted as property verified" "chmod has no Windows equivalent here"
        St-Skip "an unreadable file never yields a property-verified cell" "chmod has no Windows equivalent here"
        St-Skip "an unreadable file makes the anchor pass UNVERIFIABLE" "chmod has no Windows equivalent here"
        St-Skip "an unreadable file never leaves a port reported clean" "chmod has no Windows equivalent here"
    } else {
        New-StCanon -Path "$Tmp/pu.md" -Schema 1 -BetaStatus 'required' -Version '1' -Check 'property' -Id 'fence-nesting'
        New-StDir @("$Tmp/pu/alpha", "$Tmp/pu/beta")
        Set-StFile -Path "$Tmp/pu/beta/b.md" -Text "clean`n"
        Set-StFile -Path "$Tmp/pu/alpha/bad.md" -Text "# t`n`n${f3}markdown`n## s`n`n${f3}json`n{}`n$f3`n`n$f3`n"
        try {
            & chmod 000 "$Tmp/pu/alpha/bad.md" 2>$null
            $r = Invoke-StRun -Canon "$Tmp/pu.md" -PortsParent "$Tmp/pu"
        } finally { & chmod 644 "$Tmp/pu/alpha/bad.md" 2>$null }
        St-Assert "an unreadable file is never counted as property verified" 1 $r.ExitCode "UNVERIFIABLE" $r.Output
        St-Refute "an unreadable file never yields a property-verified cell" "ok: fence-nesting" (Get-StPortSection -Output $r.Output -Port 'alpha')

        New-StDir @("$Tmp/au/alpha", "$Tmp/au/beta")
        Set-StFile -Path "$Tmp/au/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/au/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/au/alpha/secret.md" -Text "<!-- canon:ghost-rule v1 -->`n"
        try {
            & chmod 000 "$Tmp/au/alpha/secret.md" 2>$null
            $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/au"
        } finally { & chmod 644 "$Tmp/au/alpha/secret.md" 2>$null }
        St-Assert "an unreadable file makes the anchor pass UNVERIFIABLE" 1 $r.ExitCode "partial file list" $r.Output
        St-Refute "an unreadable file never leaves a port reported clean" "clean repos:.*alpha" $r.Output
    }

    # --- a NUL byte. The bash half's grep -I skips and exits 1, which is
    # --- byte-identical to "no anchors here". This half refuses on the byte
    # --- itself, so the refusal does not move when a heuristic does.
    New-StDir @("$Tmp/bin/alpha", "$Tmp/bin/beta")
    Set-StFile -Path "$Tmp/bin/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/bin/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/bin/alpha/binary.md" -Text ("x" + [char]0 + "x`n<!-- canon:ghost-rule v1 -->`n")
    $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/bin"
    St-Assert "a NUL-bearing .md is refused, not read as anchor-free" 1 $r.ExitCode "partial file list" $r.Output
    St-Refute "a NUL-bearing .md never leaves a port reported clean" "clean repos:.*alpha" $r.Output

    # --- symlink classes. New-Item -ItemType SymbolicLink needs Developer Mode
    # --- or admin on Windows, so the whole block reports its reason there.
    if (-not (Test-StCanSymlink -Tmp $Tmp)) {
        foreach ($n in @(
            "a symlinked port directory is still descended",
            "a symlinked port directory never passes on an empty walk",
            "a symlinked .md is refused, never silently skipped",
            "a symlinked .md never leaves a port reported clean",
            "a symlinked subdirectory is refused, never silently skipped",
            "a symlinked subdirectory never leaves a port reported clean",
            "a harmless non-markdown symlink does not make a port unexaminable",
            "a harmless symlink is exempt in the property pass too",
            "a harmless symlink never yields a refusal in the property pass",
            "a symlink out of the tree is never read by the property pass",
            "an exempt symlink never counts toward the enumerated file total",
            "a port whose only entry is an exempt symlink is unverifiable, not verified",
            "a dangling exempt symlink is ignored by both passes alike",
            "a symlinked .md is refused in the property pass",
            "a symlinked .md never yields a property-verified cell"
        )) { St-Skip $n "this host cannot create symbolic links" }
    } else {
        # a port checked out as a SYMLINK must still be descended
        New-StDir @("$Tmp/slreal", "$Tmp/sl/beta")
        Set-StFile -Path "$Tmp/slreal/bad.md" -Text "# t`n`n${f3}markdown`n## s`n`n${f3}json`n{}`n$f3`n`n$f3`n"
        Set-StFile -Path "$Tmp/sl/beta/b.md" -Text "clean`n"
        New-StLink -Link "$Tmp/sl/alpha" -Target "$Tmp/slreal"
        $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/sl"
        St-Assert "a symlinked port directory is still descended" 1 $r.ExitCode "DEFECT: fence-nesting" $r.Output
        St-Refute "a symlinked port directory never passes on an empty walk" "across 0 markdown files" $r.Output

        # a symlinked .md is refused rather than followed
        New-StDir @("$Tmp/slf/alpha", "$Tmp/slf/beta")
        Set-StFile -Path "$Tmp/slf/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/slf/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/slf/alpha/note.txt" -Text "<!-- canon:ghost-rule v1 -->`n"
        New-StLink -Link "$Tmp/slf/alpha/linked.md" -Target "$Tmp/slf/alpha/note.txt"
        $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/slf"
        St-Assert "a symlinked .md is refused, never silently skipped" 1 $r.ExitCode "partial file list" $r.Output
        St-Refute "a symlinked .md never leaves a port reported clean" "clean repos:.*alpha" $r.Output

        # the same gap one level down: a symlinked SUBDIRECTORY
        New-StDir @("$Tmp/sld/alpha", "$Tmp/sld/beta", "$Tmp/sldout")
        Set-StFile -Path "$Tmp/sld/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/sld/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/sldout/hidden.md" -Text "<!-- canon:ghost-rule v1 -->`n"
        New-StLink -Link "$Tmp/sld/alpha/docs" -Target "$Tmp/sldout"
        $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/sld"
        St-Assert "a symlinked subdirectory is refused, never silently skipped" 1 $r.ExitCode "partial file list" $r.Output
        St-Refute "a symlinked subdirectory never leaves a port reported clean" "clean repos:.*alpha" $r.Output

        # a symlink that is neither a directory nor markdown hides nothing --
        # an over-broad guard would report every ordinary port unexaminable.
        New-StDir @("$Tmp/slh/alpha", "$Tmp/slh/beta")
        Set-StFile -Path "$Tmp/slh/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/slh/beta/b.md"  -Text "<!-- canon:rule-one v1 -->`n"
        Set-StFile -Path "$Tmp/slh/alpha/notes.txt" -Text "x`n"
        New-StLink -Link "$Tmp/slh/alpha/link.txt" -Target "$Tmp/slh/alpha/notes.txt"
        $r = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/slh"
        St-Assert "a harmless non-markdown symlink does not make a port unexaminable" 0 $r.ExitCode "ok: rule-one v1" $r.Output

        # EVERY symlink case must run under the PROPERTY canon too -- running
        # them only under the anchor canon is what let the two passes disagree
        # about one tree.
        New-StDir @("$Tmp/slhp/alpha", "$Tmp/slhp/beta")
        Set-StFile -Path "$Tmp/slhp/alpha/a.md" -Text "clean`n"
        Set-StFile -Path "$Tmp/slhp/beta/b.md"  -Text "clean`n"
        Set-StFile -Path "$Tmp/slhp/alpha/notes.txt" -Text "x`n"
        New-StLink -Link "$Tmp/slhp/alpha/link.txt" -Target "$Tmp/slhp/alpha/notes.txt"
        $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/slhp"
        St-Assert "a harmless symlink is exempt in the property pass too" 0 $r.ExitCode "ok: fence-nesting" $r.Output
        St-Refute "a harmless symlink never yields a refusal in the property pass" "refusing to follow symlinked markdown" $r.Output

        # the exempt symlink must be IGNORED, never read: a link to a file
        # OUTSIDE the port tree was read and attributed to the port, and it
        # counted into the file total, walking past the empty-walk refusal.
        New-StDir @("$Tmp/slout/alpha", "$Tmp/slout/beta", "$Tmp/slelsewhere")
        Set-StFile -Path "$Tmp/slelsewhere/planted.txt" -Text "# t`n`n${f3}markdown`n## s`n`n${f3}json`n{}`n$f3`n`n$f3`n"
        Set-StFile -Path "$Tmp/slout/beta/b.md" -Text "clean`n"
        New-StLink -Link "$Tmp/slout/alpha/link.txt" -Target "$Tmp/slelsewhere/planted.txt"
        $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/slout"
        St-Refute "a symlink out of the tree is never read by the property pass" "planted.txt" $r.Output
        St-Refute "an exempt symlink never counts toward the enumerated file total" "across 1 markdown files" (Get-StPortSection -Output $r.Output -Port 'alpha')
        St-Assert "a port whose only entry is an exempt symlink is unverifiable, not verified" 1 $r.ExitCode "refusing to report a property verified over an empty walk" $r.Output

        # a DANGLING exempt symlink must be treated identically, or the two
        # passes disagree about one tree again.
        New-StDir @("$Tmp/sldang/alpha", "$Tmp/sldang/beta")
        Set-StFile -Path "$Tmp/sldang/alpha/a.md" -Text "clean`n"
        Set-StFile -Path "$Tmp/sldang/beta/b.md"  -Text "clean`n"
        New-StLink -Link "$Tmp/sldang/alpha/dangling.txt" -Target "$Tmp/nonexistent-target"
        $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/sldang"
        St-Assert "a dangling exempt symlink is ignored by both passes alike" 0 $r.ExitCode "ok: fence-nesting" $r.Output

        New-StDir @("$Tmp/slp/alpha", "$Tmp/slp/beta")
        Set-StFile -Path "$Tmp/slp/alpha/a.md" -Text "clean`n"
        Set-StFile -Path "$Tmp/slp/beta/b.md"  -Text "clean`n"
        Set-StFile -Path "$Tmp/slp/alpha/real.txt" -Text "clean`n"
        New-StLink -Link "$Tmp/slp/alpha/linked.md" -Target "$Tmp/slp/alpha/real.txt"
        $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/slp"
        St-Assert "a symlinked .md is refused in the property pass" 1 $r.ExitCode "UNVERIFIABLE" $r.Output
        St-Refute "a symlinked .md never yields a property-verified cell" "ok: fence-nesting" (Get-StPortSection -Output $r.Output -Port 'alpha')
    }

    # --- "verified across 0 markdown files" was still a pass. Disclosing the
    # --- empty enumeration is not the same as refusing to conclude from it.
    New-StDir @("$Tmp/mt/alpha", "$Tmp/mt/beta")
    Set-StFile -Path "$Tmp/mt/beta/b.md" -Text "clean`n"
    $r = Invoke-StRun -Canon "$Tmp/pg.md" -PortsParent "$Tmp/mt"
    St-Assert "an empty enumeration is unverifiable, not verified" 1 $r.ExitCode "refusing to report a property verified over an empty walk" $r.Output
    St-Refute "an empty port directory never yields a property-verified cell" "across 0 markdown files" $r.Output

    # --- the registry's exists:false and a row's status are two statements
    # --- about one port. The report layer read only the first and deferred
    # --- EVERY rule without looking at a row, so a half-applied canon edit
    # --- exited 0 over a port owing every rule.
    Set-StCanonFile -Path "$Tmp/xf.md" -Lines @(
        '# canon'
        "${f3}json"
        '{ "canon_schema_version": 1,'
        '  "ports": ['
        '    {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""},'
        '    {"id": "ghost", "family": "f", "dir": "ghost", "exists": false, "note": "n"}'
        '  ] }'
        "$f3"
        '### r'
        '<!-- canon:rule-one v1 -->'
        "${f3}json"
        '{ "id": "rule-one", "version": 1, "status": "active", "superseded_by": null,'
        '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
        '  "applies_to": ['
        '    {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
        '    {"port": "ghost", "status": "required", "variant": "", "reason": "r"} ] }'
        "$f3"
    )
    New-StDir @("$Tmp/xf/alpha")
    Set-StFile -Path "$Tmp/xf/alpha/a.md" -Text "<!-- canon:rule-one v1 -->`n"
    $r = Invoke-StRun -Canon "$Tmp/xf.md" -PortsParent "$Tmp/xf"
    St-Assert "a port the registry says is absent cannot be required to carry a rule" 2 $r.ExitCode "can only defer a rule, never owe it" $r.Output

    # --- a byte-exact "json" info-string test dropped a block that renders as
    # --- json to every human: the entry inside it ceased to exist for the
    # --- checker, taking its MISSING cells with it.
    Set-StFile -Path "$Tmp/ws.md" -Text ($kText -replace ('(?m)^' + [regex]::Escape($f3) + 'json$'), ($f3 + 'json '))
    $r = Invoke-StRun -Canon "$Tmp/ws.md" -PortsParent "$Tmp/m"
    St-Assert "a json fence with a trailing space is still parsed" 1 $r.ExitCode "MISSING: rule-one v1" $r.Output

    # --- the backstop for every OTHER way a block can go unclassified: the
    # --- canon's own anchor definition lines counted against the entries that
    # --- reached the parser. A tilde fence is invisible to the backtick walker
    # --- entirely, so no info-string fix can catch it.
    Set-StFile -Path "$Tmp/tl.md" -Text ($kText + @"
### r2
<!-- canon:rule-two v1 -->
~~~json
{ "id": "rule-two", "version": 1, "status": "active", "superseded_by": null,
  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",
  "applies_to": [
    {"port": "alpha", "status": "required", "variant": "", "reason": ""},
    {"port": "beta", "status": "required", "variant": "", "reason": "r"} ] }
~~~
"@)
    $r = Invoke-StRun -Canon "$Tmp/tl.md" -PortsParent "$Tmp/m"
    St-Assert "an entry that never reached the parser is caught by the anchor count" 2 $r.ExitCode "did not reach this parser" $r.Output

    # --- CLI surface
    $r = Invoke-StRaw -ScriptArgs @('--help')
    St-Assert "--help exits 0 and documents the flags" 0 $r.ExitCode "ports-parent" $r.Output
    $r = Invoke-StRaw -ScriptArgs @('--bogus')
    St-Assert "an unknown option exits 2" 2 $r.ExitCode "unknown option" $r.Output
    $r = Invoke-StRaw -ScriptArgs @('--canon', '/nonexistent/nope.md')
    St-Assert "an unreadable canon exits 2" 2 $r.ExitCode "canon not readable" $r.Output
    $r = Invoke-StRaw -ScriptArgs @('--ports-parent', '/nonexistent/nope')
    St-Assert "a missing ports parent exits 2" 2 $r.ExitCode "ports parent directory not found" $r.Output

    # --- the enumeration is ONE walk. The bash half's previous guard compared
    # --- two separate walks, so removing a file between them cancelled the
    # --- difference and let a newline-named file through -- a TOCTOU on a
    # --- mutable tree. This half walks once by construction, which is what
    # --- makes the race unreachable rather than merely unlikely; the probe
    # --- stays because "unreachable by construction" is a claim, and a claim
    # --- about concurrency is worth an experiment.
    New-StDir @("$Tmp/race/alpha", "$Tmp/race/beta")
    Set-StFile -Path "$Tmp/race/beta/b.md" -Text "<!-- canon:rule-one v1 -->`n"
    Set-StFile -Path "$Tmp/race/alpha/a.md" -Text "x`n"
    Set-StFile -Path "$Tmp/racesecret.md" -Text "<!-- canon:rule-one v1 -->`n"
    $raceName = "$Tmp/race/alpha/z" + "`n" + "../racesecret.md"
    $raceMade = $false
    try { Set-StFile -Path $raceName -Text "x`n"; $raceMade = $true } catch { $raceMade = $false }
    if (-not $raceMade) {
        St-Skip "a mutating tree cannot slip a newline-named file past the guard" "this filesystem will not create a newline-bearing name"
    } else {
        $raceFalse = 0
        for ($i = 0; $i -lt 8; $i++) {
            $churn = Start-Job -ScriptBlock {
                param($d)
                for ($j = 0; $j -lt 10; $j++) {
                    try { [System.IO.File]::WriteAllText((Join-Path $d 'churn.md'), "x`n") } catch { }
                    try { Remove-Item -LiteralPath (Join-Path $d 'churn.md') -Force -ErrorAction SilentlyContinue } catch { }
                }
            } -ArgumentList "$Tmp/race/alpha"
            $rr = Invoke-StRun -Canon "$Tmp/k.md" -PortsParent "$Tmp/race" -WorkDir $Tmp
            if ($rr.Output -cmatch 'ok: rule-one v1 at racesecret\.md') { $raceFalse++ }
            Wait-Job $churn | Out-Null
            Remove-Job $churn -Force | Out-Null
        }
        if ($raceFalse -eq 0) {
            $script:StPass++
            [Console]::Out.WriteLine("ok: a mutating tree cannot slip a newline-named file past the guard")
        } else {
            $script:StFail++
            [Console]::Out.WriteLine("SELF-TEST FAILED: a mutating tree slipped a newline-named file past the guard ($raceFalse/8 runs read outside the tree)")
        }
    }
}

# Symlink creation is a privileged operation on Windows unless Developer Mode
# is on, so it is PROBED rather than assumed -- a case that cannot build its
# fixture is skipped with its reason, never silently absent.
function Test-StCanSymlink {
    param([string]$Tmp)
    $probeDir = Join-Path $Tmp 'linkprobe'
    try {
        New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
        $target = Join-Path $probeDir 't.txt'
        Set-StFile -Path $target -Text "x`n"
        $link = Join-Path $probeDir 'l.txt'
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function New-StLink {
    param([string]$Link, [string]$Target)
    # (W2107 r2) Windows PowerShell 5.1's Remove-Item -Recurse deletes through a
    # directory symlink into its TARGET, where pwsh 6.2+ removes only the link.
    # Every fixture here targets a path under the sandbox, so the difference is
    # inert -- but "inert by fixture discipline" is a property a future case can
    # break silently, and the teardown is what would do the damage. Asserted so
    # it stays inert by construction.
    if (-not $Target.StartsWith($script:StSandbox, [System.StringComparison]::Ordinal)) {
        throw "self-test fixture error: symlink target $Target is outside the sandbox $($script:StSandbox)"
    }
    $dir = Split-Path -Parent $Link
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    New-Item -ItemType SymbolicLink -Path $Link -Target $Target -ErrorAction Stop | Out-Null
}

# The bash half slices one port's block out of the report with sed before
# refuting inside it, so a clean OTHER port cannot satisfy the refutation.
function Get-StPortSection {
    param([string]$Output, [string]$Port)
    $lines = $Output -split "`n"
    $keep = New-Object System.Collections.Generic.List[string]
    $inPort = $false
    foreach ($l in $lines) {
        if ($l -ceq $Port) { $inPort = $true; $keep.Add($l); continue }
        if ($inPort) {
            if ($l -ceq '') { break }
            $keep.Add($l)
        }
    }
    return ($keep -join "`n")
}

# --------------------------------------------------------------------------
# Main dispatch.
#
# --self-test scans nothing real, so it runs before the canon is required.
# Combining it with -Canon/-PortsParent reads naturally as "prove the gate AND
# scan this", but it never scans; silently discarding the paths would be the
# worse surprise. Same guard, same wording, as the bash half.
# --------------------------------------------------------------------------
# ==========================================================================
# --self-test: prove the checker detects what it claims.
#
# Mirrors the bash half's self-test case for case, BY OUTCOME rather than by
# mechanism. Each case here uses the same fixture, expects the same exit code
# and the same message substring, and carries the SAME CASE NAME STRING -- that
# last part is what lets the hook suites compare the two halves' ok: line sets
# and notice a case that was renamed or lost on one side.
#
# Several cases exist because of awk/grep mechanics this half does not have --
# the tab/newline record-forgery pair, the entry-id charset refusal. They are
# mirrored anyway. Criterion 1 makes the two halves' VERDICTS the contract, and
# a refusal is a verdict: a canon that halts the bash half at exit 2 must halt
# this one too, or the pair disagrees on a real input.
#
# Everything is written under one temp directory and removed in a finally --
# the PowerShell equivalent of the bash half's single-quoted EXIT trap, and
# stronger, since a finally cannot be defeated by an interpolated value. This
# script writes nothing outside that directory.
# ==========================================================================
function Invoke-SelfTest {
    $script:StPass = 0
    $script:StFail = 0
    $script:StSkip = 0
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("port-canon-selftest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $script:StSandbox = $tmp
    try {
        Invoke-SelfTestBody -Tmp $tmp
    } finally {
        Remove-StSandbox -Path $tmp
    }
    [Console]::Out.WriteLine('')
    # (W2107 r2) The skip count is REPORTED. St-Skip increments StPass so a
    # platform-conditional case is counted rather than silently absent -- but
    # that made "100 passed, 0 failed" identical on a host that ran every case
    # and one that skipped a dozen, and both suites normalize the per-case
    # suffix away before comparing. Printed on its own line so the tally line
    # the suites match on keeps its exact shape.
    if ($script:StSkip -gt 0) {
        [Console]::Out.WriteLine("self-test: $($script:StSkip) case(s) skipped on this host -- fixtures it cannot create; see the [skipped on this host] lines above")
    }
    [Console]::Out.WriteLine("self-test: $($script:StPass) passed, $($script:StFail) failed")
    if ($script:StFail -ne 0) { return 1 }
    return 0
}

$script:F3 = '```'

# st_canon's six positional arguments, same defaults.
# (W2107 r2) The teardown reports its own failure instead of swallowing it
# twice. It used to be `Remove-Item -ErrorAction SilentlyContinue` inside an
# empty catch: a mode-000 fixture left behind by an exception mid-run cannot be
# enumerated, so the removal failed partially and said nothing -- a cleanup that
# cannot report its own failure is the same shape as the read failures the rest
# of this file is built to refuse. The chmod restore is now exception-safe at
# each site as well, so this is the second line of defence rather than the first.
function Remove-StSandbox {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    } catch { }
    # A directory the run left unreadable is the one thing that can block this.
    if (-not $script:OnWindows) {
        try {
            & chmod -R u+rwX $Path 2>$null
        } catch { }
    }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        [Console]::Out.WriteLine("SELF-TEST WARNING: sandbox $Path could not be removed")
    }
}

function New-StCanon {
    param(
        [string]$Path, [int]$Schema = 1, [string]$BetaStatus = 'required',
        [string]$Version = '1', [string]$Check = 'anchor', [string]$Id = 'rule-one'
    )
    $f3 = $script:F3
    $lines = @(
        '# canon'
        "${f3}json"
        "{ ""canon_schema_version"": $Schema,"
        '  "ports": ['
        '    {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""},'
        '    {"id": "beta",  "family": "f", "dir": "beta",  "exists": true, "note": ""}'
        '  ] }'
        "$f3"
        '### r'
        "<!-- canon:$Id v$Version -->"
        "${f3}json"
        "{ ""id"": ""$Id"", ""version"": $Version, ""status"": ""active"", ""superseded_by"": null,"
        "  ""provenance"": ""quoted"", ""defects"": [""D1""], ""check"": ""$Check"", ""check_hint"": ""h"","
        '  "applies_to": ['
        '    {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
        "    {""port"": ""beta"", ""status"": ""$BetaStatus"", ""variant"": """", ""reason"": ""r""} ] }"
        "$f3"
    )
    Set-StCanonFile -Path $Path -Lines $lines
}

# Written as bytes with LF terminators so a fixture is byte-identical on every
# host: Set-Content would emit CRLF on Windows and the fence walker's own CR
# tolerance would then be the thing under test rather than the case.
function Set-StCanonFile {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = ($Lines -join "`n") + "`n"
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::GetEncoding(28591).GetBytes($text))
}

function Set-StFile {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::GetEncoding(28591).GetBytes($Text))
}

function New-StDir {
    param([string[]]$Paths)
    foreach ($d in $Paths) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
}

# Re-invokes the SHIPPED file as a subprocess, exactly as st_run does, so the
# self-test proves the artifact rather than the functions loaded in memory.
function Invoke-StRun {
    param([string]$Canon, [string]$PortsParent, [string]$WorkDir = '')
    $prev = $null
    if ($WorkDir) { $prev = (Get-Location).Path; Set-Location -LiteralPath $WorkDir }
    try {
        $out = & pwsh -NoProfile -File $script:Self -Canon $Canon -PortsParent $PortsParent 2>&1
        $code = $LASTEXITCODE
    } finally {
        if ($prev) { Set-Location -LiteralPath $prev }
    }
    return @{ Output = (($out | Out-String) -replace "`r`n", "`n"); ExitCode = $code }
}

function Invoke-StRaw {
    param([string[]]$ScriptArgs)
    $out = & pwsh -NoProfile -File $script:Self @ScriptArgs 2>&1
    return @{ Output = (($out | Out-String) -replace "`r`n", "`n"); ExitCode = $LASTEXITCODE }
}

function St-Assert {
    param([string]$Name, [int]$WantExit, [int]$GotExit, [string]$WantMatch, [string]$Output)
    $ok = $true
    if ($WantExit -ne $GotExit) { $ok = $false }
    # -cnotmatch, not -notmatch. The bash half asserts with grep, which is
    # case-sensitive; PowerShell's -match is not. The first run of this file
    # caught it live: the refute for /MISSING/ matched "missing 0" in the tally
    # line and failed a case the bash half passes. Same trap the header names
    # for the checker's own comparisons, one layer out in its test harness.
    if ($WantMatch -and ($Output -cnotmatch $WantMatch)) { $ok = $false }
    if ($ok) {
        $script:StPass++
        [Console]::Out.WriteLine("ok: $Name")
    } else {
        $script:StFail++
        [Console]::Out.WriteLine("SELF-TEST FAILED: $Name (wanted exit $WantExit, got $GotExit; wanted /$WantMatch/)")
        foreach ($l in ($Output -split "`n")) { [Console]::Out.WriteLine("    $l") }
    }
}

function St-Refute {
    param([string]$Name, [string]$MustNotMatch, [string]$Output)
    if ($Output -cmatch $MustNotMatch) {
        $script:StFail++
        [Console]::Out.WriteLine("SELF-TEST FAILED: $Name (output must not contain /$MustNotMatch/)")
    } else {
        $script:StPass++
        [Console]::Out.WriteLine("ok: $Name")
    }
}

# A case whose fixture this host cannot create is printed with its reason and
# counted, never silently absent -- an absent case and a passing one look the
# same in a tally, which is the failure mode this whole file exists against.
function St-Skip {
    param([string]$Name, [string]$Reason)
    $script:StPass++
    $script:StSkip++
    [Console]::Out.WriteLine("ok: $Name [skipped on this host: $Reason]")
}

if ($SelfTest) {
    if ($CanonSet -or $PortsSet) {
        [Console]::Error.WriteLine('GATE ERROR: --self-test does not scan; drop --canon/--ports-parent, or run the two separately:')
        [Console]::Error.WriteLine('  pwsh scripts/check-port-canon.ps1 -SelfTest')
        [Console]::Error.WriteLine('  pwsh scripts/check-port-canon.ps1 -Canon ... -PortsParent ...')
        exit 2
    }
    exit (Invoke-SelfTest)
}

# Normalize both paths to absolute BEFORE anything compares them. The canon
# self-exclusion matches enumerated paths against $Canon, and those are
# absolute: a relative -Canon would never match, the canon would be scanned,
# and the port it lives in would report ok on every anchor off the definition
# site -- the exact false green the exclusion exists to prevent.
if (Test-Path -LiteralPath $Canon) {
    $Canon = (Resolve-Path -LiteralPath $Canon).Path
}
if (Test-Path -LiteralPath $PortsParent -PathType Container) {
    $PortsParent = (Resolve-Path -LiteralPath $PortsParent).Path
}

$canonReadable = $false
if (Test-Path -LiteralPath $Canon -PathType Leaf) {
    $probe = Read-CanonBytes -Path $Canon
    if ($probe.Ok) { $canonReadable = $true }
}
if (-not $canonReadable) { Stop-Gate "canon not readable at $Canon" }
if (-not (Test-Path -LiteralPath $PortsParent -PathType Container)) {
    Stop-Gate "ports parent directory not found: $PortsParent"
}

exit (Invoke-CanonCheck -CanonPath $Canon -PortsParentPath $PortsParent)
