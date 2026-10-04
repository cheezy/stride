# check-plugin-current.ps1 — Step 0 plugin-currency check (W2251), PowerShell
# twin of check-plugin-current.sh. Keep the two in sync.
#
# Prints ONE line when the installed stride plugin is older than the version
# the stride-marketplace catalog publishes, and nothing otherwise. Always
# exits 0: it is a warning, never a gate.
#
# WHY: dispatched agents load from the installed plugin cache, so a stale
# install silently runs without shipped fixes. skills_version is "1.0" for
# every release, so the server's skills_update_required cannot see this, and
# the local marketplace clone can be just as stale as the install — so the
# comparison reads the PUBLISHED pin.
#
# USAGE: pwsh -NoProfile -File check-plugin-current.ps1 <skill-base-directory>
#   The skill base directory is ...\stride\<version>\skills\stride-workflow
#   for a marketplace install, so the installed version is the name of the
#   directory two levels up. A local-path install has no version directory;
#   then <base>\..\..\.claude-plugin\plugin.json supplies it. Neither readable
#   -> silence.
#
# SILENCE, exit 0, whenever: the argument is missing, the installed version is
# unreadable or not version-shaped, the pin cannot be fetched within the
# timeout, the catalog does not parse, it has no "stride" entry, or the
# installed version is equal to or newer than the pin.
#
# SECURITY: the pin is read over HTTPS from the canonical catalog only — the
# URL is a constant, not an input, and -MaximumRedirection 0 keeps the request
# on that host. Nothing fetched is executed or sourced; it is parsed as JSON
# data and only a version-shaped string is ever printed. No credential is sent.
#
# COMPARISON is numeric per dot-separated component (1.80.0 > 1.9.0), missing
# components count as 0, and a pre-release suffix sorts below its release
# (1.83.0-rc.1 < 1.83.0). Two pre-releases of the same core are not ordered —
# reported as silence rather than a guess. [version] is deliberately NOT used:
# it rejects pre-release strings.
#
# DOCUMENTED DIVERGENCE from the bash half: Windows PowerShell 5.1 has no
# connect-timeout, so -TimeoutSec bounds the whole request and this half has
# ONE bound where bash has two (--connect-timeout 2 plus --max-time 3).
#
# TEST SEAM: dot-sourcing this file defines the functions without running the
# check, so the test suite can replace Get-StridePinBody in-process instead of
# needing the URL to be an input.

param([string]$BaseDir = '')

Set-StrictMode -Version Latest

$script:StridePinUrl = 'https://raw.githubusercontent.com/cheezy/stride-marketplace/main/.claude-plugin/marketplace.json'
$script:StrideUpdateCmd = '/plugin marketplace update stride-marketplace, then /plugin update stride@stride-marketplace'
$script:StrideVersionRe = '^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$'

function Test-StrideVersionShape {
    param([string]$Version)
    if ([string]::IsNullOrEmpty($Version)) { return $false }
    return ($Version -match $script:StrideVersionRe)
}

# Return the installed version for a skill base directory, or ''.
function Get-StrideInstalledVersion {
    param([string]$Base)
    try {
        $trimmed = $Base.TrimEnd('/', '\')
        $pluginRoot = Split-Path -Parent (Split-Path -Parent $trimmed)
        $dirVersion = Split-Path -Leaf $pluginRoot
        if (Test-StrideVersionShape $dirVersion) { return $dirVersion }
        $manifest = Join-Path (Join-Path $pluginRoot '.claude-plugin') 'plugin.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return '' }
        $parsed = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($parsed.PSObject.Properties.Match('version').Count -gt 0 -and $parsed.version -is [string]) {
            return $parsed.version
        }
    } catch {
        return ''
    }
    return ''
}

# Fetch the catalog body as a string, or ''. Replaced in-process by the tests.
function Get-StridePinBody {
    try {
        $resp = Invoke-WebRequest -Uri $script:StridePinUrl -UseBasicParsing `
            -TimeoutSec 3 -MaximumRedirection 0 -UserAgent 'curl/stride-plugin-check' `
            -ErrorAction Stop
        $content = $resp.Content
        # Content is Byte[] when the response has no text Content-Type; a bare
        # [string] cast would render the bytes as numbers, so decode it.
        if ($content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($content) }
        return [string]$content
    } catch {
        return ''
    }
}

# Return the published stride version from catalog JSON text, or ''.
function Get-StridePublishedVersion {
    param([string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return '' }
    try {
        $catalog = $Body | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $catalog -or $catalog.PSObject.Properties.Match('plugins').Count -eq 0) { return '' }
        foreach ($entry in @($catalog.plugins)) {
            if ($null -eq $entry) { continue }
            if ($entry.PSObject.Properties.Match('name').Count -eq 0) { continue }
            if ($entry.name -ne 'stride') { continue }
            if ($entry.PSObject.Properties.Match('version').Count -gt 0 -and $entry.version -is [string]) {
                return $entry.version
            }
            return ''
        }
    } catch {
        return ''
    }
    return ''
}

# $true when $Older is strictly older than $Newer. Both must be version-shaped.
function Test-StrideVersionOlder {
    param([string]$Older, [string]$Newer)
    $aCore = ($Older -split '-', 2)[0]
    $bCore = ($Newer -split '-', 2)[0]
    $aPre = $Older.Length -gt $aCore.Length
    $bPre = $Newer.Length -gt $bCore.Length
    $aParts = $aCore.Split('.')
    $bParts = $bCore.Split('.')
    $n = [Math]::Max($aParts.Count, $bParts.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = [decimal]0
        $y = [decimal]0
        if ($i -lt $aParts.Count) { $x = [decimal]::Parse($aParts[$i]) }
        if ($i -lt $bParts.Count) { $y = [decimal]::Parse($bParts[$i]) }
        if ($x -lt $y) { return $true }
        if ($x -gt $y) { return $false }
    }
    # Equal cores: only "pre-release vs its release" is ordered.
    return ($aPre -and -not $bPre)
}

function Invoke-StridePluginCheck {
    param([string]$Base)
    if ([string]::IsNullOrEmpty($Base)) { return }
    $installed = Get-StrideInstalledVersion $Base
    if (-not (Test-StrideVersionShape $installed)) { return }
    $published = Get-StridePublishedVersion (Get-StridePinBody)
    if (-not (Test-StrideVersionShape $published)) { return }
    if (Test-StrideVersionOlder $installed $published) {
        Write-Output ("stride plugin {0} is installed but the marketplace publishes {1} - update with: {2}" -f $installed, $published, $script:StrideUpdateCmd)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-StridePluginCheck $BaseDir } catch { $null = $_ }
    exit 0
}
