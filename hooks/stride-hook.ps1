# stride-hook.ps1 — Bridges Claude Code hooks to Stride .stride.md hook execution
#
# PowerShell companion to stride-hook.sh for Windows compatibility.
# Called by Claude Code's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the Bash command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | pwsh stride-hook.ps1 <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in PreToolUse context)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Arguments and paths ---
$Phase = if ($args.Count -gt 0) { $args[0] } else { '' }
$ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$StrideMd = Join-Path $ProjectDir '.stride.md'
$EnvCache = Join-Path $ProjectDir '.stride-env-cache'
# (D226) Whether THIS call's own response proved the task identity. Mirrors
# stride-hook.sh's TASK_IDENTITY_REFRESHED. Declared here because Set-StrictMode
# makes reading an unset variable an error, and the gate is read on every
# before_doing route whether or not the claim block set it.
$script:TaskIdentityRefreshed = $false
# (D118) Canonical API-response snapshot. When present, after_goal detection,
# env forwarding, and the claim env-cache refresh prefer it over the harness-
# truncatable tool_response.stdout. Best-effort fast path only — the reliability
# guarantee is D119's hook-initiated fresh call.
$ResponseFile = Join-Path $ProjectDir '.stride/.last-api-response.json'

# (W1453) Keys exported with an empty value. .NET's SetEnvironmentVariable
# DELETES a Process env var when handed '', so the defined-but-empty contract
# (hook-execution.md: omitted keys export as empty strings, preventing
# ${VAR?} / set -u aborts in user commands) cannot be represented in the
# process env block alone. Invoke-StrideSection re-adds these keys as
# KEY='' entries on each section child's environment.
$StrideEmptyEnvKeys = @()

# (W1457) Record the claim-time dirty baseline: every path already modified
# (vs the fresh TASK_BASE_REF) or untracked at claim time, with its current
# blob hash, one "<hash> <path>" line each. The upload filter consults this
# to exclude pre-existing unrelated edits from completion snapshots unless
# the file changed again after claim (hash differs -> included). Persisted
# on disk (claim and completion can happen in different sessions), cleaned
# up with the other hook artifacts. Best-effort: failure leaves an absent
# baseline, which the filter treats as "no exclusion".
function Write-DirtyBaseline {
    param([string]$BaseRef)
    $blFile = Join-Path $ProjectDir '.stride-dirty-baseline'
    Remove-Item -Force $blFile -ErrorAction SilentlyContinue
    if (-not $BaseRef) { return }
    try {
        $tracked = @(& git -C $ProjectDir diff --name-only $BaseRef 2>$null)
        if ($LASTEXITCODE -ne 0) { $tracked = @() }
        $untracked = @(& git -C $ProjectDir ls-files --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -ne 0) { $untracked = @() }
        $paths = @(($tracked + $untracked) | Where-Object { $_ } | Select-Object -Unique)
        if ($paths.Count -eq 0) { return }
        $lines = @()
        foreach ($p in $paths) {
            $full = Join-Path $ProjectDir $p
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $h = (& git -C $ProjectDir hash-object -- $p 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or -not $h) { $h = 'unhashable' }
            } else {
                $h = 'absent'
            }
            $lines += "$h $p"
        }
        Set-Content -Path $blFile -Value $lines -Encoding UTF8
    } catch {
        # Best-effort — an absent baseline just means no exclusion.
    }
}

# (W1457) Load the dirty baseline as a path->hash map; $null when absent.
function Read-DirtyBaseline {
    $blFile = Join-Path $ProjectDir '.stride-dirty-baseline'
    if (-not (Test-Path -LiteralPath $blFile -PathType Leaf)) { return $null }
    $map = @{}
    try {
        foreach ($line in Get-Content -Path $blFile -Encoding UTF8) {
            if ($line -match '^(\S+) (.+)$') { $map[$Matches[2]] = $Matches[1] }
        }
    } catch {
        return $null
    }
    if ($map.Count -eq 0) { return $null }
    return $map
}

# (D118) Read the canonical API-response snapshot. Returns the parsed object
# when the file exists and holds valid JSON, else $null so callers fall back to
# the tool_response parse. Defined ahead of the claim env-cache block and
# Get-ResponsePayload so both can prefer the file. Best-effort fast path — the
# reliability guarantee is D119's hook-initiated fresh call.
function Read-CanonicalResponse {
    if (-not $ResponseFile) { return $null }
    if (-not (Test-Path -LiteralPath $ResponseFile -PathType Leaf)) { return $null }
    $content = $null
    try { $content = Get-Content -LiteralPath $ResponseFile -Raw -ErrorAction Stop } catch { return $null }
    if (-not $content) { return $null }
    try { return ($content | ConvertFrom-Json) } catch { return $null }
}

# (W1609) Capture THIS call's API response to the canonical file so the file-
# first resolver and the claim env-cache refresh read the CURRENT call's data
# rather than a stale prior-call file. Only complete, valid JSON is written — a
# truncated stdout leaves any out-of-band copy intact so a value written by a
# curl passthrough (or a later phase) survives. Best-effort; never throws.
function Save-CanonicalResponse {
    param([string]$InputJson)
    if (-not $ResponseFile) { return }
    if (-not $InputJson) { return }
    $parsed = $null
    try { $parsed = $InputJson | ConvertFrom-Json } catch { return }
    if ($null -eq $parsed) { return }
    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') { return }
    $resp = $parsed.tool_response
    if (-not $resp) { return }

    $payloadStr = $null
    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        $payloadStr = [string]$resp.stdout
    } elseif ($resp -is [string]) {
        $payloadStr = $resp
    } elseif ($resp -is [PSCustomObject]) {
        try { $payloadStr = ($resp | ConvertTo-Json -Depth 100 -Compress) } catch { return }
    }
    if (-not $payloadStr) { return }
    # A truncated blob must never overwrite a good file — only persist valid JSON.
    try { $null = $payloadStr | ConvertFrom-Json } catch { return }

    try {
        $dir = Split-Path -Parent $ResponseFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Set-Content -LiteralPath $ResponseFile -Value $payloadStr -NoNewline -Encoding UTF8
    } catch {
        # Best-effort — an unwritten file just falls back to the stdout parse.
    }
}

# --- Bash-command routing (D220) ---
# Decision-identical mirror of stride-hook.sh's stride_route_command and its
# _stride_* helpers. THE COMMAND TEXT IS UNTRUSTED ROUTING INPUT: a changed_files
# PUT carries a raw code diff, and a heredoc writing documentation can contain
# the completion curl verbatim, so containment is not evidence of issuance.
# Requires (1) curl/wget in command position outside quotes and heredoc bodies,
# (2) the endpoint as the TAIL of a URL in an ARGUMENT position, (3) a method
# consistent with the endpoint. Fails closed: anything unparseable routes
# nowhere, because running the wrong section runs real git state changes while
# running none only misses a gate.
# THESE TWO FILES MUST STAY IN LOCKSTEP — see hooks/stride-hook.sh.

$script:StrideQuoteState = ''
$script:StrideQuoteRest  = ''

# Advance the quote state ('' | sq | dq) across $Text. With -StopWhenClosed,
# stop as soon as the state returns to '' and leave the remainder in
# $script:StrideQuoteRest.
#
# Backslash escapes ARE modelled, and must be: outside single quotes a backslash
# escapes the next character, so a JSON payload's \" does NOT close the enclosing
# double quote. Ignoring that flips the tracker OUT of quoting on an odd number
# of \" and lets payload text be scanned as syntax — a FAIL-OPEN bug.
function Update-StrideQuoteState {
    param([string]$Text, [switch]$StopWhenClosed)
    $script:StrideQuoteRest = ''
    if ($Text.IndexOf("'") -lt 0 -and $Text.IndexOf('"') -lt 0 -and $Text.IndexOf('\') -lt 0) { return }
    # Index of the character most recently consumed AS an escape. The aq test
    # below must not treat an escaped `\$` as introducing ANSI-C quoting — bash
    # reads `\$'a\'b` as a literal dollar followed by a PLAIN single-quoted
    # string, so the `\'` closes it. The sh mirror gets this right for free
    # because it consumes the escaped character before testing the prefix.
    $escapedAt = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq '\') {
            # No escapes inside plain single quotes; everywhere else \x makes x literal.
            if ($script:StrideQuoteState -cne 'sq') { $escapedAt = $i + 1; $i++ }
            continue
        }
        if ($c -ne '"' -and $c -ne "'") { continue }
        if ($script:StrideQuoteState -ceq '') {
            if ($c -eq "'") {
                # $'...' is ANSI-C quoting, where \' does NOT close the string.
                $script:StrideQuoteState = if ($i -gt 0 -and $Text[$i - 1] -eq '$' -and ($i - 1) -ne $escapedAt) { 'aq' } else { 'sq' }
            } else {
                $script:StrideQuoteState = 'dq'
            }
        } elseif ($script:StrideQuoteState -ceq 'sq' -or $script:StrideQuoteState -ceq 'aq') {
            if ($c -eq "'") { $script:StrideQuoteState = '' }
        } else {
            if ($c -eq '"') { $script:StrideQuoteState = '' }
        }
        if ($StopWhenClosed -and $script:StrideQuoteState -ceq '') {
            $script:StrideQuoteRest = $Text.Substring($i + 1)
            return
        }
    }
}

# Return $CommandText with every heredoc BODY removed. The opening line is KEPT
# (a curl can legitimately read its payload from `-d @- <<'JSON'`). This is what
# stops an agent writing documentation ABOUT the completion curl from being
# routed as one.
# Apply bash's quote removal to a heredoc delimiter word. NOT a delete-all-quotes
# reduction: bash KEEPS what a backslash escapes and KEEPS quoted contents, so
# `E\'F` is the delimiter E'F. Deleting them yields a SHORTER word, and if that
# shorter word appears in the body before bash's real terminator the queue
# dequeues early and the rest of the body is scanned as syntax. `''` and `""`
# still reduce to the empty string, preserving the first-empty-line rule.
function Get-StrideHeredocDelim {
    param([string]$Word)
    $o = New-Object System.Text.StringBuilder
    $state = ''
    $any = $false
    $unsafe = $false
    $stop = @(' ', "`t", ';', '|', '&', '(', ')', '<', '>')
    $i = 0
    for (; $i -lt $Word.Length; $i++) {
        $c = $Word[$i]
        if ($state -ceq 'sq') {
            if ($c -eq "'") { $state = '' } else { [void]$o.Append($c) }
            continue
        }
        if ($state -ceq 'aq') {
            if ($c -eq "'") { $state = '' }
            elseif ($c -eq '\') {
                # Inside $'…' bash INTERPRETS escapes (\n is a newline, \x41 is
                # A). We do not implement that table; for \' \" \\ the ANSI-C
                # meaning IS the next character, so those agree. Anything else
                # would render SHORTER than bash's delimiter and dequeue the body
                # early — mark it unsafe so it never terminates instead.
                if ($i + 1 -lt $Word.Length) {
                    $i++
                    $n = $Word[$i]
                    if ($n -ne "'" -and $n -ne '"' -and $n -ne '\') { $unsafe = $true }
                    [void]$o.Append($n)
                }
            }
            else { [void]$o.Append($c) }
            continue
        }
        if ($state -ceq 'dq') {
            if ($c -eq '"') { $state = '' }
            elseif ($c -eq '\') {
                # Inside " " bash removes the backslash ONLY before $ ` " \ .
                $n = if ($i + 1 -lt $Word.Length) { $Word[$i + 1] } else { [char]0 }
                if ($n -eq '$' -or $n -eq '`' -or $n -eq '"' -or $n -eq '\') {
                    $i++; [void]$o.Append($n)
                } else { [void]$o.Append('\') }
            }
            else { [void]$o.Append($c) }
            continue
        }
        if ($stop -ccontains [string]$c) { break }
        $any = $true
        if ($c -eq '\') { if ($i + 1 -lt $Word.Length) { $i++; [void]$o.Append($Word[$i]) }; continue }
        if ($c -eq "'") { $state = 'sq'; continue }
        if ($c -eq '"') { $state = 'dq'; continue }
        if ($c -eq '$') {
            $n = if ($i + 1 -lt $Word.Length) { $Word[$i + 1] } else { [char]0 }
            if ($n -eq "'") { $state = 'aq'; $i++; continue }
            if ($n -eq '"') { $state = 'dq'; $i++; continue }
            [void]$o.Append('$'); continue
        }
        [void]$o.Append($c)
    }
    return [pscustomobject]@{ Delim = $o.ToString(); Any = $any; Unsafe = $unsafe; Consumed = $i }
}

function Remove-StrideHeredocBodies {
    param([string]$CommandText)
    $out = New-Object System.Collections.Generic.List[string]
    # FIFO of pending openers, not a single value: bash allows several on one
    # line and consumes their bodies in order.
    $queue = New-Object System.Collections.Generic.Queue[object]
    # Quote state carried across lines, so a `<<` inside a string is not read as
    # an opener. Saved/restored because Get-StrideRoute uses the same tracker.
    $savedQ = $script:StrideQuoteState
    $script:StrideQuoteState = ''
    foreach ($line in [regex]::Split($CommandText, "\r?\n")) {
        if ($queue.Count -gt 0) {
            $head = $queue.Peek()
            # An Unsafe delimiter is one we could not derive exactly (ANSI-C
            # escapes we do not interpret). It never matches, so the body is
            # swallowed to EOF — fail-closed, rather than dequeuing early on a
            # rendering that is not bash's.
            if ($head.Unsafe) { continue }
            # bash strips only TABS for <<- ; stripping spaces too would let a
            # space-indented lookalike end the body early for us but not for bash.
            $t = if ($head.Dash) { $line.TrimStart("`t".ToCharArray()) } else { $line }
            if ($t -ceq $head.Delim) { [void]$queue.Dequeue() }
            continue
        }
        $out.Add($line)
        # Walk the line left to right: `<<<` is a here-string that must skip only
        # ITSELF, every opener on the line must be registered, and a `<<` inside
        # a quoted string is text rather than a redirection.
        $pos = 0
        foreach ($m in [regex]::Matches($line, '<<(<?)(-?)[ \t]*')) {
            if ($m.Index -lt $pos) { continue }
            Update-StrideQuoteState -Text $line.Substring($pos, $m.Index - $pos)
            $pos = $m.Index + 2
            if ($script:StrideQuoteState -cne '') { continue }
            if ($m.Groups[1].Value -ceq '<') { continue }   # here-string
            $w = Get-StrideHeredocDelim $line.Substring($m.Index + $m.Length)
            # Guard on "a word was present": `<<''` and `<<""` are valid heredocs
            # whose body ends at the first EMPTY line.
            if (-not $w.Any) { continue }
            [void]$queue.Enqueue([pscustomobject]@{
                Dash = ($m.Groups[2].Value -ceq '-'); Delim = $w.Delim; Unsafe = $w.Unsafe })
            $pos = $m.Index + $m.Length + $w.Consumed
        }
        if ($pos -lt $line.Length) { Update-StrideQuoteState -Text $line.Substring($pos) }
    }
    $script:StrideQuoteState = $savedQ
    return ($out -join "`n")
}

# A fresh shell segment: new command position, no client, no URL yet.
function New-StrideSegment {
    return @{ Pos = $true; Client = ''; Method = ''; Implied = '';
              Endpoint = ''; TaskId = ''; UrlSeen = $false; Next = '' }
}

# Classify a candidate URL ARGUMENT. Only the FIRST argument-position token
# containing /api/tasks/ is considered (curl's own request-URL semantic), so a
# later bare word inside a payload can neither override nor supply a target. The
# endpoint must be the TAIL of the path, which is why a completion URL embedded
# in a JSON value is not a request target.
function Set-StrideSegmentUrl {
    param($Seg, [string]$Token, $Vars)
    if ($Seg.UrlSeen) { return }
    $u = $Token.TrimStart('"', "'", '\', '(').TrimEnd('"', "'", '\', ',', ';', ')', '`')
    # (D220) Pitfall 2 — the URL "may be written in a shell variable rather than
    # as a literal". `URL="$STRIDE_API_URL/api/tasks/$TASK_ID/complete"; curl -X
    # PATCH "$URL"` routed before this change and must keep routing.
    if ($u.StartsWith('$')) {
        $n = $u.Substring(1)
        if ($n.StartsWith('{')) { $n = $n.Substring(1) }
        if ($n.EndsWith('}'))   { $n = $n.Substring(0, $n.Length - 1) }
        if ($n -cmatch '^[A-Za-z0-9_]+$' -and $Vars.ContainsKey($n)) { $u = $Vars[$n] }
    }
    if ($u -cnotlike '*/api/tasks/*') { return }
    $Seg.UrlSeen = $true
    $u = ($u -split '\?')[0]
    $u = ($u -split '#')[0]
    # Strip ONE trailing slash, as the sh mirror's ${u%/} does.
    if ($u.EndsWith('/')) { $u = $u.Substring(0, $u.Length - 1) }
    $i = $u.IndexOf('/api/tasks/')
    $rest = $u.Substring($i + '/api/tasks/'.Length)
    if ($rest -ceq 'claim') { $Seg.Endpoint = 'claim'; $Seg.TaskId = ''; return }
    $slash = $rest.IndexOf('/')
    if ($slash -lt 0) { return }
    $id  = $rest.Substring(0, $slash)
    $act = $rest.Substring($slash + 1)
    if ($act -cne 'complete' -and $act -cne 'mark_reviewed') { return }
    if ($id -ceq '') { return }
    $Seg.Endpoint = $act
    # (D127) Only a NUMERIC id is authoritative; $TASK_ID interpolation leaves it
    # empty and callers fall back to the env cache, exactly as before D220.
    $Seg.TaskId = if ($id -cmatch '^[0-9]+$') { $id } else { '' }
}

# Record NAME=VALUE seen in command position, but only when VALUE names the API.
function Add-StrideVar {
    param($Vars, [string]$Token)
    $n = $Token.Substring(0, $Token.IndexOf('='))
    if ($n -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return }
    # A SECOND assignment to the same name means the effective value depends on
    # control flow we do not evaluate — store an empty sentinel so the lookup
    # declines to resolve rather than guessing which branch bash took. EVERY name
    # is recorded, even when its value does not name the API, so the sentinel is
    # order-INDEPENDENT (recording only API-valued names missed the common
    # `if $DRY; then URL=noop; else URL=…/complete; fi` ordering).
    if ($Vars.ContainsKey($n)) { $Vars[$n] = ''; return }
    $v = $Token.Substring($Token.IndexOf('=') + 1).Trim('"', "'", ';')
    if ($v -cnotlike '*/api/tasks/*') { $v = '' }
    $Vars[$n] = $v
}

# Decide whether the accumulated segment is a real lifecycle call.
function Test-StrideSegment {
    param($Seg)
    if ($Seg.Client -ceq '' -or $Seg.Endpoint -ceq '') { return $null }
    $m = $Seg.Method
    if ($m -ceq '') { $m = $Seg.Implied }
    if ($m -ceq '') { $m = 'GET' }
    $m = ($m -replace '["'']', '').ToUpperInvariant()
    # -X "$METHOD" cannot be resolved statically. Allow it — a silent non-firing
    # after_doing removes the quality gate entirely — but only when the call also
    # carries a BODY, which every documented lifecycle curl does and a read-only
    # probe of the same URL does not.
    if ($m -ceq '' -or $m.Contains('$') -or $m.Contains('`')) {
        $m = if ($Seg.Implied -cne '') { 'UNKNOWN' } else { 'GET' }
    }
    if ($Seg.Endpoint -ceq 'claim') {
        if ($m -cne 'POST' -and $m -cne 'UNKNOWN') { return $null }
    } else {
        if ($m -cne 'PATCH' -and $m -cne 'POST' -and $m -cne 'UNKNOWN') { return $null }
    }
    return [pscustomobject]@{ Endpoint = $Seg.Endpoint; TaskId = $Seg.TaskId }
}

# THE single routing entry point (D220). $Phase is pre|post ('' for an id-only
# query). Returns Endpoint / HookName / TaskId; all routing sites read it, so
# they cannot drift apart.
function Get-StrideRoute {
    param([string]$Phase, [string]$CommandText)

    $route = [pscustomobject]@{ Endpoint = ''; HookName = ''; TaskId = '' }
    # Fast path: the overwhelming majority of Bash calls never mention the API.
    if (-not $CommandText -or ($CommandText -cnotlike '*/api/tasks/*')) { return $route }

    $script:StrideQuoteState = ''
    $seg  = New-StrideSegment
    $hit  = $null
    $pend = ''
    # Ordinal comparer, NOT a bare @{}: PowerShell hashtables match keys
    # case-insensitively, which would resolve $url against a URL= assignment that
    # bash would never resolve — a fail-open divergence from the sh mirror.
    $vars = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    $optValue = @('-H','--header','-o','--output','-u','--user','-A','--user-agent',
        '-e','--referer','-b','--cookie','-c','--cookie-jar','-w','--write-out',
        '-m','--max-time','--connect-timeout','--retry','--retry-delay','-x','--proxy',
        '-E','--cert','--key','--cacert','--capath','-K','--config','--resolve',
        '--interface','--limit-rate','--oauth2-bearer','-D','--dump-header','--trace',
        '--trace-ascii','--stderr','--netrc-file','--form-string','--cert-type',
        '--key-type','--pinnedpubkey','--proxy-user','--noproxy','--unix-socket',
        '--output-dir','--range','-r')
    # A redirection target is not a request URL. This pattern reproduces the sh
    # mirror's case list EXACTLY, including every file descriptor 0-9 — an
    # enumeration of only 0-2 left `3> /path/api/tasks/9/complete` unconsumed,
    # so the redirect target reached the URL classifier and supplied both the
    # section and the task id.
    $redirOp = '^(>|>>|>\||<|&>|&>>|&|[0-9](>|>>|<|>&))$'
    $dataOpt = @('-d','--data','--data-raw','--data-binary','--data-ascii',
        '--data-urlencode','-F','--form','-T','--upload-file')
    $prefix = @('env','sudo','command','builtin','exec','nohup','nice','stdbuf',
        'timeout','time','if','while','until')
    $sep = @(';',';;','&','&&','|','||','|&','(',')','{','}','!',
        'then','else','elif','do','done','fi')

    foreach ($rawIn in [regex]::Split((Remove-StrideHeredocBodies $CommandText), "\r?\n")) {
        # Drop a trailing CR before anything else, exactly as the sh mirror does,
        # so a CRLF command's URL token is not left with a \r that no tail matches.
        $raw = if ($rawIn.EndsWith("`r")) { $rawIn.Substring(0, $rawIn.Length - 1) } else { $rawIn }
        # Join backslash continuations FIRST: the documented completion curl
        # spans five physical lines and its URL is not always on the curl line.
        if ($raw.EndsWith('\')) { $pend += $raw.Substring(0, $raw.Length - 1) + ' '; continue }
        $line = $pend + $raw
        $pend = ''

        if ($script:StrideQuoteState -cne '') {
            # Inside a multi-line quoted payload: no command position exists here.
            Update-StrideQuoteState -Text $line -StopWhenClosed
            if ($script:StrideQuoteState -cne '') { continue }
            $line = $script:StrideQuoteRest
        } else {
            $hit = Test-StrideSegment $seg
            if ($hit) { break }
            $seg = New-StrideSegment
        }

        # Once a variable holding an API URL has been recorded, a later line can
        # name it without mentioning the path, so the fast path must not skip it.
        # A line carrying an assignment must be tokenised even when it names no
        # API path, or the FIRST of two assignments is hidden and the second
        # looks like a first — no sentinel, and a branch-dependent URL resolves.
        if ($line -cnotlike '*/api/tasks/*' -and $vars.Count -eq 0 -and
            $line -cnotmatch '(^|\s)[A-Za-z_][A-Za-z0-9_]*=') {
            Update-StrideQuoteState -Text $line; continue
        }

        foreach ($t in ($line -split '\s+')) {
            if ($t -ceq '') { continue }
            $tok = $t
            $qb = $script:StrideQuoteState
            Update-StrideQuoteState -Text $tok
            # A token that BEGAN inside a quoted string is payload text, never syntax.
            if ($qb -cne '') { continue }

            # Mirror the sh `case` ordering exactly: $( wins over a backtick.
            if ($tok.Contains('$(')) {
                $tok = $tok.Substring($tok.LastIndexOf('$(') + 2)
                $hit = Test-StrideSegment $seg
                if ($hit) { break }
                $seg = New-StrideSegment
                if ($tok -ceq '') { continue }
            } elseif ($tok.Contains('`')) {
                $tok = $tok.Substring($tok.LastIndexOf('`') + 1)
                $hit = Test-StrideSegment $seg
                if ($hit) { break }
                $seg = New-StrideSegment
                if ($tok -ceq '') { continue }
            }
            if ($sep -ccontains $tok) {
                $hit = Test-StrideSegment $seg
                if ($hit) { break }
                $seg = New-StrideSegment
                continue
            }
            if ($tok.Contains(';')) {
                # `URL=...;` puts the assignment and the separator in one token.
                $pre = $tok.Substring(0, $tok.IndexOf(';'))
                if ($pre -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') { Add-StrideVar $vars $pre }
                $hit = Test-StrideSegment $seg
                if ($hit) { break }
                $seg = New-StrideSegment
                $tok = $tok.Substring($tok.LastIndexOf(';') + 1)
                if ($tok -ceq '') { continue }
            }

            if ($seg.Pos) {
                # `(curl ...)` in a subshell — the paren opens a command position.
                # NOT `{`: it is a reserved word requiring a following space, so
                # it already arrives as its own separator token.
                while ($tok.StartsWith('(')) { $tok = $tok.Substring(1) }
                if ($tok -ceq '') { continue }
                if ($tok -clike '-*') { continue }
                if ($tok -cmatch '^[0-9][0-9smhd.]*$') { continue }
                if ($tok -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') { Add-StrideVar $vars $tok; continue }
                # sh splits the basename on '/' only and matches curl/wget/.exe
                # literally — mirror that rather than also splitting on '\'.
                $base = $tok.Substring($tok.LastIndexOf('/') + 1)
                if ($prefix -ccontains $base) { continue }
                if ($base -ceq 'curl' -or $base -ceq 'curl.exe' -or
                    $base -ceq 'wget' -or $base -ceq 'wget.exe') {
                    $seg.Client = $base -creplace '\.exe$', ''
                    $seg.Pos = $false; continue
                }
                # Another program owns this segment.
                $seg.Pos = $false; $seg.Client = ''; continue
            }
            if ($seg.Client -ceq '') { continue }

            if ($seg.Next -cne '') {
                if ($seg.Next -ceq 'method') { $seg.Method = $tok }
                elseif ($seg.Next -ceq 'url') { Set-StrideSegmentUrl $seg $tok $vars }
                $seg.Next = ''
                continue
            }

            if ($tok -ceq '-X' -or $tok -ceq '--request') { $seg.Next = 'method'; continue }
            if ($tok -ceq '--url')                        { $seg.Next = 'url'; continue }
            if ($tok -ceq '-G' -or $tok -ceq '--get')     { $seg.Method = 'GET'; continue }
            if ($tok -clike '--method=*')  { $seg.Method = $tok.Substring(9);  continue }
            if ($tok -clike '--request=*') { $seg.Method = $tok.Substring(10); continue }
            if ($tok -clike '--url=*')     { Set-StrideSegmentUrl $seg $tok.Substring(6) $vars; continue }
            if ($tok -clike '-X*')         { $seg.Method = $tok.Substring(2);  continue }
            if ($dataOpt -ccontains $tok) {
                if ($seg.Implied -ceq '') { $seg.Implied = 'POST' }
                $seg.Next = 'value'; continue
            }
            if ($tok -clike '--data=*'     -or $tok -clike '--data-raw=*' -or
                $tok -clike '--data-binary=*' -or $tok -clike '--data-ascii=*' -or
                $tok -clike '--data-urlencode=*' -or
                $tok -clike '--post-data*' -or $tok -clike '--post-file*' -or
                $tok -clike '--body-data*' -or $tok -clike '--body-file*' -or
                $tok -clike '-d*') {
                if ($seg.Implied -ceq '') { $seg.Implied = 'POST' }
                continue
            }
            if ($optValue -ccontains $tok) { $seg.Next = 'value'; continue }
            if ($tok -cmatch '^-[^-].*X$') { $seg.Next = 'method'; continue }
            if ($tok -clike '-*')          { continue }
            if ($tok -cmatch $redirOp)     { $seg.Next = 'value'; continue }
            if ($tok.Contains('>') -or $tok.Contains('<')) { continue }  # attached, e.g. >/tmp/f
            Set-StrideSegmentUrl $seg $tok $vars
        }
        if ($hit) { break }
    }
    if (-not $hit) { $hit = Test-StrideSegment $seg }
    if (-not $hit) { return $route }

    $route.Endpoint = $hit.Endpoint
    $route.TaskId   = $hit.TaskId
    # Case-sensitive throughout, matching the sh mirror's `case` semantics.
    if ($Phase -ceq 'post') {
        if     ($hit.Endpoint -ceq 'claim')         { $route.HookName = 'before_doing' }
        elseif ($hit.Endpoint -ceq 'mark_reviewed') { $route.HookName = 'after_review' }
        elseif ($hit.Endpoint -ceq 'complete')      { $route.HookName = 'before_review' }
    } elseif ($Phase -ceq 'pre' -and $hit.Endpoint -ceq 'complete') {
        $route.HookName = 'after_doing'
    }
    return $route
}

# Exit early if no phase argument or no .stride.md
if (-not $Phase) { exit 0 }
if (-not (Test-Path $StrideMd)) { exit 0 }

# Read Claude Code hook input from stdin
$Input = @($input) -join "`n"
if (-not $Input) { exit 0 }

# --- Extract the Bash command from hook JSON ---
$Command = ''
try {
    $json = $Input | ConvertFrom-Json
    $Command = $json.tool_input.command
} catch {
    # Fallback: simple string extraction for "command" : "value"
    if ($Input -match '"command"\s*:\s*"([^"]*)"') {
        $Command = $Matches[1]
    }
}

if (-not $Command) { exit 0 }

# --- Determine which Stride hook to run (D220) ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review
#
# Get-StrideRoute is the ONLY place the command text is inspected for routing: it
# requires the call to actually ISSUE the request rather than merely mention it.
# The after-goal gate below reads $StrideRoute.Endpoint so the two cannot drift.

$StrideRoute = Get-StrideRoute -Phase $Phase -CommandText $Command
$HookName = $StrideRoute.HookName

# Not a Stride API call — exit cleanly
if (-not $HookName) { exit 0 }

# (W1609) Persist THIS call's response to the canonical file before the claim
# env-cache refresh reads it, so a valid current stdout overwrites any stale
# prior-call file (no staleness regression) and a truncated stdout leaves an
# out-of-band copy intact.
if ($Phase -eq 'post') {
    Save-CanonicalResponse -InputJson $Input
}

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if ($HookName -eq 'before_doing') {
    try {
        $taskJson = $null

        # (D118/W1609) Fast path — prefer the untruncated canonical response
        # file. Falls through to the tool_response parse below when it is absent
        # or does not carry a task object.
        $canon = Read-CanonicalResponse
        if ($null -ne $canon) {
            $canonProps = $canon.PSObject.Properties.Name
            if (($canonProps -contains 'data') -and $canon.data -and
                ($canon.data.PSObject.Properties.Name -contains 'id') -and $canon.data.id) {
                $taskJson = $canon.data
            } elseif (($canonProps -contains 'id') -and $canon.id) {
                $taskJson = $canon
            }
        }

        $json = $Input | ConvertFrom-Json
        $response = $json.tool_response
        if (-not $taskJson -and $response) {

            # Shape 1: Claude Code Bash tool wraps API JSON inside tool_response.stdout
            # — peel that layer first before parsing.
            if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                try {
                    $innerObj = $response.stdout | ConvertFrom-Json
                    if ($innerObj.data -and $innerObj.data.id) {
                        $taskJson = $innerObj.data
                    } elseif ($innerObj.id) {
                        $taskJson = $innerObj
                    }
                } catch {
                    # stdout was not parseable JSON — fall through to other shapes
                }
            }

            # Shape 2: tool_response is a JSON-encoded string (legacy harnesses)
            if (-not $taskJson -and $response -is [string]) {
                try {
                    $responseObj = $response | ConvertFrom-Json
                    if ($responseObj.data -and $responseObj.data.id) {
                        $taskJson = $responseObj.data
                    } elseif ($responseObj.id) {
                        $taskJson = $responseObj
                    }
                } catch {
                    # not parseable — skip caching
                }
            }

            # Shape 3: raw API JSON object directly in tool_response.
            # Guard property access by name first — under Set-StrictMode Latest,
            # reading a non-existent property (e.g. .data on the stdout-wrapper
            # object) throws, which would otherwise abort the whole caching block
            # before the persisted-output fallback and base-ref refresh run.
            if (-not $taskJson -and $response -is [PSCustomObject]) {
                $responseProps = $response.PSObject.Properties.Name
                if (($responseProps -contains 'data') -and $response.data -and $response.data.id) {
                    $taskJson = $response.data
                } elseif (($responseProps -contains 'id') -and $response.id) {
                    $taskJson = $response
                }
            }

            # Shape 4: persisted-output file fallback (W1087, mirrors the bash
            # Shape 3). When the claim response is large, Claude Code writes the
            # tool output to a file and leaves only a "Full output saved to:
            # <absolute path>" notice in stdout. Recover the API JSON by reading
            # that file. The path is harness-controlled, so require an existing
            # regular file and parse it with ConvertFrom-Json only — never
            # invoke, dot-source, or write to it.
            if (-not $taskJson) {
                $notice = $null
                if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                    $notice = $response.stdout
                } elseif ($response -is [string]) {
                    $notice = $response
                }
                if ($notice -and ($notice -imatch 'saved to')) {
                    # Keep the path from its first "/" to end of the notice line so
                    # a path containing spaces survives; tolerate a wrapping quote.
                    $noticeLine = ($notice -split "`n" | Where-Object { $_ -imatch 'saved to' } | Select-Object -First 1)
                    if ($noticeLine) {
                        $persistPath = '/' + ($noticeLine -replace '^[^/]*/', '')
                        $persistPath = ($persistPath.TrimEnd()) -replace '"$', ''
                        if (Test-Path -LiteralPath $persistPath -PathType Leaf) {
                            try {
                                $persistObj = (Get-Content -LiteralPath $persistPath -Raw -ErrorAction SilentlyContinue) | ConvertFrom-Json
                                # Guard property access by name (StrictMode) so an
                                # id-only persisted payload caches identity lines
                                # exactly as the bash reference does, rather than
                                # throwing and falling through to the base-ref-only
                                # refresh.
                                $persistProps = $persistObj.PSObject.Properties.Name
                                if (($persistProps -contains 'data') -and $persistObj.data -and $persistObj.data.id) {
                                    $taskJson = $persistObj.data
                                } elseif (($persistProps -contains 'id') -and $persistObj.id) {
                                    $taskJson = $persistObj
                                }
                            } catch {
                                # persisted file not parseable JSON — fall through
                            }
                        }
                    }
                }
            }
        }

        # (D142) This block refreshes IDENTITY only. TASK_BASE_REF is
        # deliberately NOT written here: the ## before_doing section has not
        # run yet, and its `git pull` moves HEAD — a base captured now would
        # anchor the diff at the PRE-pull commit and span another clone's
        # pulled work (D132/W1678). Invoke-FinalizeBeforeDoing writes the base
        # (and the dirty baseline) after the section finishes.
        # (D226) Ownership may be stamped ONLY when THIS call's own response
        # carried the SAME id that was resolved. Read-CanonicalResponse
        # survives across calls, so a truncated nested claim otherwise
        # resolves the PREVIOUS claim's payload, reports the outer task's id,
        # overwrites that task's record with this claim's HEAD and then
        # vouches for it — the owner then MATCHES at completion, the refusal
        # never fires, and the outer task carries a foreign base. Measured on
        # the bash twin; this is the same gate, because the same resolver
        # shape produces the same defect here.
        $ownCallId = ''
        if ($response) {
            $ownObj = $null
            try {
                if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                    $ownObj = $response.stdout | ConvertFrom-Json
                } elseif ($response -is [string]) {
                    $ownObj = $response | ConvertFrom-Json
                } elseif ($response -is [PSCustomObject]) {
                    $ownObj = $response
                }
            } catch {
                $ownObj = $null
            }
            if ($ownObj) {
                $ownProps = $ownObj.PSObject.Properties.Name
                if (($ownProps -contains 'data') -and $ownObj.data -and
                    ($ownObj.data.PSObject.Properties.Name -contains 'id') -and $ownObj.data.id) {
                    $ownCallId = [string]$ownObj.data.id
                } elseif (($ownProps -contains 'id') -and $ownObj.id) {
                    $ownCallId = [string]$ownObj.id
                }
            }
        }
        if ($taskJson -and $ownCallId -and ($ownCallId -eq [string]$taskJson.id)) {
            $script:TaskIdentityRefreshed = $true
        }

        if ($taskJson) {
            # (D226) This rewrite TRUNCATES the cache, so carry the per-task
            # base-ref records across it — a nested claim must not erase an
            # outer task's anchor. The shared TASK_BASE_REF / _TRUSTED /
            # _OWNER keys are still dropped here, exactly as D142 requires.
            $keptBaseRecords = @()
            if (Test-Path $EnvCache) {
                $keptBaseRecords = @(Get-Content $EnvCache -Encoding UTF8 | Where-Object {
                    $_ -match '^TASK_BASE_REF_[A-Za-z0-9_]+=' -and
                    $_ -notmatch '^TASK_BASE_REF_TRUSTED=' -and
                    $_ -notmatch '^TASK_BASE_REF_OWNER='
                } | Select-Object -Last 20)
            }
            $cacheLines = @(
                "TASK_ID=$($taskJson.id)"
                "TASK_IDENTIFIER=$($taskJson.identifier)"
                "TASK_TITLE=$($taskJson.title)"
                "TASK_STATUS=$($taskJson.status)"
                "TASK_COMPLEXITY=$($taskJson.complexity)"
                "TASK_PRIORITY=$($taskJson.priority)"
            ) + $keptBaseRecords
            $cacheLines | Set-Content -Path $EnvCache -Encoding UTF8
        } elseif (Test-Path $EnvCache) {
            # (W1086/D142) No parseable response and no usable persisted
            # file: keep the existing TASK_ identity lines (a later
            # completion can still recover TASK_ID) but STRIP the inherited
            # TASK_BASE_REF (and its trust marker) NOW — even if this process
            # dies before Invoke-FinalizeBeforeDoing rewrites it, a base from
            # a previous task or session must never survive a claim.
            # (D226) TASK_BASE_REF_OWNER goes with the base it stamps; the
            # per-task TASK_BASE_REF_<id> records are kept, since they belong
            # to tasks other than this claim.
            $preserved = @(Get-Content $EnvCache -Encoding UTF8 | Where-Object { $_ -notmatch '^TASK_BASE_REF=' -and $_ -notmatch '^TASK_BASE_REF_TRUSTED=' -and $_ -notmatch '^TASK_BASE_REF_OWNER=' })
            if ($preserved.Count -gt 0) {
                $preserved | Set-Content -Path $EnvCache -Encoding UTF8
            } else {
                Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
            }
        }

        # A claim always opens a new task window: clear the previous task's
        # snapshot, upload state (W1095 — a stale 2xx would suppress the
        # before_review self-heal retry), and dirty baseline unconditionally.
        Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $ProjectDir '.stride-dirty-baseline') -ErrorAction SilentlyContinue
    } catch {
        # Caching failure is non-fatal
    }
}

# Load cached env vars if available (all hooks benefit from this)
if (Test-Path $EnvCache) {
    Get-Content $EnvCache -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# --- Server-supplied hook env forwarding (W1453) ---
# hook-execution.md declares the server's hook env block the single source of
# truth for the variables the executor exports. The functions below extract
# the `env` object from the hook entry of an intercepted response (singular
# `.hook` on claim responses, `.hooks[]` on /complete and /mark_reviewed),
# export every key into the Process environment (inherited by the bash -c
# children that run the sections), and append it to the env cache so
# follow-up agent commands (e.g. the after_goal PATCH) can still read the
# values. Keys the server omits export as empty strings. Mirrors the bash
# extract_response_payload / extract_hook_env / apply_env_lines /
# export_after_goal_env helpers — both scripts must agree on behavior.

# Peel the API payload out of Claude Code hook input. Same three shapes as
# Test-AfterGoalInResponse (which is rewritten on top of this function).
# Returns the parsed payload object, or $null when unparseable.
function Get-ResponsePayload {
    param([string]$InputJson)

    # (D118) Fast path — prefer the untruncated canonical response file.
    $fromFile = Read-CanonicalResponse
    if ($null -ne $fromFile) { return $fromFile }

    if (-not $InputJson) { return $null }

    try {
        $parsed = $InputJson | ConvertFrom-Json
    } catch {
        return $null
    }

    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') { return $null }

    $resp = $parsed.tool_response
    if (-not $resp) { return $null }

    $payload = $null

    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        # Shape 1: {"stdout":"<json>"} wrap (Claude Code Bash tool). A truncated
        # stdout fails to parse and MUST resolve to $null (not the wrapper) so
        # the D119 fresh call fires — hence elseif, never a fall-through to the
        # raw-object shape below.
        try { $payload = $resp.stdout | ConvertFrom-Json } catch { $payload = $null }
    } elseif ($resp -is [string]) {
        # Shape 2: tool_response is itself a JSON-encoded string.
        try { $payload = $resp | ConvertFrom-Json } catch { $payload = $null }
    } elseif ($resp -is [PSCustomObject]) {
        # Shape 3: raw API JSON object directly (other harnesses).
        $payload = $resp
    }

    # (W1086) Shape 4: persisted-output file fallback. When the response is
    # large, Claude Code writes the tool output to a file and leaves only a
    # "Full output saved to: <path>" notice in stdout. Recover the API JSON by
    # reading that file — an existing regular file parsed with ConvertFrom-Json
    # only; never invoked, dot-sourced, or written.
    if ($null -eq $payload) {
        $notice = $null
        if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
            $notice = [string]$resp.stdout
        } elseif ($resp -is [string]) {
            $notice = $resp
        }
        if ($notice -and ($notice -imatch 'saved to')) {
            $noticeLine = ($notice -split "`n" | Where-Object { $_ -imatch 'saved to' } | Select-Object -First 1)
            if ($noticeLine) {
                $persistPath = '/' + ($noticeLine -replace '^[^/]*/', '')
                $persistPath = ($persistPath.TrimEnd()) -replace '"$', ''
                if (Test-Path -LiteralPath $persistPath -PathType Leaf) {
                    try {
                        $payload = (Get-Content -LiteralPath $persistPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json)
                    } catch {
                        $payload = $null
                    }
                }
            }
        }
    }

    return $payload
}

# Collect the env object of the named hook entry as an ordered map. Keys must
# be valid shell identifiers — anything else is dropped, because the values
# reach a bash -c child via the environment and the cache loader is
# line-based. HOOK_NAME is excluded (the executor routes on its own value; a
# cached HOOK_NAME line would misroute later invocations). TASK_BASE_REF is
# excluded (client-only diff anchor owned by the claim branch).
function Get-HookEnvFromPayload {
    param($Payload, [string]$HookEntryName)

    $envMap = [ordered]@{}
    if ($null -eq $Payload) { return $envMap }

    $payloadProps = $Payload.PSObject.Properties.Name
    $entries = @()
    if (($payloadProps -contains 'hooks') -and $Payload.hooks) {
        $entries += @($Payload.hooks)
    }
    if (($payloadProps -contains 'hook') -and $Payload.hook -is [PSCustomObject]) {
        $entries += $Payload.hook
    }

    foreach ($entry in $entries) {
        if (-not ($entry -is [PSCustomObject])) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'name') { continue }
        if ($entry.name -ne $HookEntryName) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'env') { continue }
        $envObj = $entry.env
        if (-not ($envObj -is [PSCustomObject])) { continue }
        foreach ($prop in $envObj.PSObject.Properties) {
            $key = $prop.Name
            if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ($key -eq 'HOOK_NAME' -or $key -eq 'TASK_BASE_REF') { continue }
            $envMap[$key] = [string]$prop.Value
        }
        break
    }

    return $envMap
}

# (W1454) Server-supplied timeout (milliseconds) for the named hook entry —
# sibling of Get-HookEnvFromPayload, selecting `timeout` instead of `env`.
# Returns [long] milliseconds, or $null when absent/invalid (documented
# defaults apply).
function Get-HookTimeoutMsFromPayload {
    param($Payload, [string]$HookEntryName)

    if ($null -eq $Payload) { return $null }

    $payloadProps = $Payload.PSObject.Properties.Name
    $entries = @()
    if (($payloadProps -contains 'hooks') -and $Payload.hooks) {
        $entries += @($Payload.hooks)
    }
    if (($payloadProps -contains 'hook') -and $Payload.hook -is [PSCustomObject]) {
        $entries += $Payload.hook
    }

    foreach ($entry in $entries) {
        if (-not ($entry -is [PSCustomObject])) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'name') { continue }
        if ($entry.name -ne $HookEntryName) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'timeout') { return $null }
        $t = $entry.timeout
        if ($t -is [int] -or $t -is [long] -or $t -is [double]) {
            $ms = [long][math]::Floor([double]$t)
            if ($ms -gt 0) { return $ms }
        }
        return $null
    }
    return $null
}

# (W1454) Resolve the section budget in seconds. Precedence:
#   STRIDE_HOOK_TIMEOUT_OVERRIDE (integer seconds; test/ops escape hatch)
#   > server hook-entry timeout (ms, rounded up to whole seconds)
#   > documented default (600s for every section — parser.md's table).
# (D229) These are HANG DETECTORS, not performance gates. A developer's
# .stride.md commands are theirs; the executor must never kill one for being
# slow. Sized well above every measured legitimate run — cold before_doing 80s,
# cold after_doing 138s (200s+ with coverage), ~1.9x that again under load.
# Clamped to 890s so no inner budget can reach the 900s hooks.json outer
# ceiling. after_doing runs at PRE phase — no tool_response exists yet, so it
# always resolves to the documented 600s default.
function Resolve-SectionBudget {
    param([string]$Section)

    $budget = [long]0
    $override = [System.Environment]::GetEnvironmentVariable('STRIDE_HOOK_TIMEOUT_OVERRIDE', 'Process')
    if ($override -and $override -match '^\d+$' -and [long]$override -gt 0) {
        $budget = [long]$override
    } else {
        $ms = Get-HookTimeoutMsFromPayload -Payload $script:responsePayload -HookEntryName $Section
        if ($ms) { $budget = [long][math]::Ceiling($ms / 1000.0) }
    }
    if ($budget -le 0) {
        $budget = 600
    }
    if ($budget -gt 890) { $budget = 890 }
    return [int]$budget
}

# Export a map into the Process environment (inherited by the bash -c
# children that run sections) and append it to the env cache, best-effort,
# so the values survive for follow-up agent commands. The cache loader is
# line-based, so embedded newlines are collapsed to spaces in the cached
# copy — the process env keeps the exact value. SetEnvironmentVariable
# involves no shell parsing, so crafted values have no injection surface
# here. Never echoes values to stdout/stderr.
function Set-HookEnv {
    param($EnvMap)

    if ($null -eq $EnvMap -or $EnvMap.Count -eq 0) { return }

    $cacheLines = @()
    foreach ($key in @($EnvMap.Keys)) {
        $value = [string]$EnvMap[$key]
        [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        if ($value -eq '') {
            # SetEnvironmentVariable('', 'Process') DELETED the variable —
            # remember the key so sections still see it defined-but-empty.
            if ($script:StrideEmptyEnvKeys -notcontains $key) {
                $script:StrideEmptyEnvKeys += $key
            }
        } else {
            $script:StrideEmptyEnvKeys = @($script:StrideEmptyEnvKeys | Where-Object { $_ -ne $key })
        }
        $cacheLines += "$key=" + ($value -replace "`r?`n", ' ')
    }
    try {
        Add-Content -Path $EnvCache -Value $cacheLines -Encoding UTF8
    } catch {
        # Best-effort cache append — export already succeeded.
    }
}

# after_goal env: export what the server supplied, default every documented
# GOAL_* key it omitted to an empty string (defined-but-empty, never an
# error), and fall back to the completed task's parent_id from the same
# response payload when GOAL_ID itself is missing or empty. The fallback is
# response-local — the executor still never queries the API for goal state.
function Set-AfterGoalEnv {
    param($Payload)

    $envMap = Get-HookEnvFromPayload -Payload $Payload -HookEntryName 'after_goal'

    foreach ($key in @('GOAL_ID', 'GOAL_IDENTIFIER', 'GOAL_TITLE', 'GOAL_DESCRIPTION')) {
        if (-not $envMap.Contains($key)) { $envMap[$key] = '' }
    }

    # Parent-id fallback: the server built the after_goal env from the
    # completed child task and omitted GOAL_ID (or sent it empty). The parent
    # id in the same response's data object IS the goal id.
    if (-not $envMap['GOAL_ID'] -and $null -ne $Payload) {
        $parentId = $null
        $payloadProps = $Payload.PSObject.Properties.Name
        if (($payloadProps -contains 'data') -and $Payload.data -and
            ($Payload.data.PSObject.Properties.Name -contains 'parent_id')) {
            $parentId = $Payload.data.parent_id
        } elseif ($payloadProps -contains 'parent_id') {
            $parentId = $Payload.parent_id
        }
        if ($null -ne $parentId -and "$parentId") { $envMap['GOAL_ID'] = "$parentId" }
    }

    Set-HookEnv -EnvMap $envMap
}

# (W1453) Forward the server-supplied hook env for the routed hook. Applied
# AFTER the cache load so server-supplied keys override stale cached values;
# keys the server does not supply keep their cached values. PreToolUse (pre
# phase) has no tool_response yet, so this is post-only.
$afterGoalRouted = $false
$responsePayload = $null
if ($Phase -eq 'post') {
    $responsePayload = Get-ResponsePayload -InputJson $Input
    Set-HookEnv -EnvMap (Get-HookEnvFromPayload -Payload $responsePayload -HookEntryName $HookName)
}

# Resolve the Stride API base URL for the changed_files upload. Primary source
# is $ProjectDir\.stride_auth.md (the same file the agent reads) — its
# `**API URL:** `<url>`` line — falling back to a literal URL in $Command.
function Resolve-StrideApiUrl {
    $auth = Join-Path $ProjectDir '.stride_auth.md'
    $url = ''
    if (Test-Path $auth) {
        $line = Get-Content -Path $auth | Where-Object { $_ -match '\*\*API URL:\*\*' } | Select-Object -First 1
        if ($line -and $line -match 'https?://[A-Za-z0-9._:/-]+') { $url = $Matches[0] }
    }
    if (-not $url -and $Command -match 'https?://[A-Za-z0-9._-]+(:[0-9]+)?') { $url = $Matches[0] }
    return $url
}

# Resolve the Stride API bearer token for the changed_files upload. Primary
# source is the production `**API Token:** `<token>`` line in
# $ProjectDir\.stride_auth.md — deliberately NOT the `**Local API Token:**`
# line (the `**API Token:**` pattern does not match `**Local API Token:**`) —
# falling back to a literal `Bearer <token>` in $Command. Never logged.
function Resolve-StrideApiToken {
    $auth = Join-Path $ProjectDir '.stride_auth.md'
    $token = ''
    if (Test-Path $auth) {
        $line = Get-Content -Path $auth | Where-Object { $_ -match '\*\*API Token:\*\*' } | Select-Object -First 1
        if ($line -and $line -match '`([^`]+)`') { $token = $Matches[1] }
    }
    if (-not $token -and $Command -match 'Bearer\s+([A-Za-z0-9._+/=-]+)') { $token = $Matches[1] }
    return $token
}

# PUT the on-disk snapshot to /api/tasks/<id>/changed_files as the
# transport-encoded envelope {"changed_files":{"encoding":"base64",
# "data":"<b64>"}} so an edge request filter does not misread a unified code
# diff as an attack and drop the upload (D61). The raw file bytes are
# encoded directly so the wire body carries no recognizable source text.
# Returns the HTTP status code as a string ('000' on transport failure),
# warns on stderr for non-2xx, and never throws. Mirror of stride-hook.sh's
# upload_changed_files_snapshot (W1094) — shared by Invoke-FinalizeAfterDoing
# and the before_review self-heal.
function Invoke-ChangedFilesUpload {
    param([string]$TaskId, [string]$ApiBase, [string]$Token)
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    $httpCode = '000'
    try {
        $bytes = [System.IO.File]::ReadAllBytes($snapshotPath)
        # D67: defensively strip the hook's OWN root artifacts from the snapshot
        # before upload. The bash capture already excludes them, but this ps1
        # may PUT a snapshot produced by an older/unfiltered capture or one that
        # was committed into the repo. Match only the exact repo-root paths — a
        # same-named file in a subdirectory has a path prefix and is kept. Only
        # re-encode when an artifact was actually dropped, so an already-clean
        # snapshot uploads byte-for-byte as before; an unparseable snapshot
        # falls through to the raw bytes unchanged.
        try {
            $entries = @([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
            # (W1457) Hard name exclusions (.stride.md, .stride_auth.md — the
            # auth file must NEVER be uploaded — and the baseline artifact),
            # plus the claim-time dirty-baseline exclusion: entries whose path
            # was already dirty at claim AND whose file is hash-identical now
            # are pre-existing unrelated edits, not task work. Hash mismatch,
            # deletion, or unhashable -> keep (include when in doubt).
            $dirtyBaseline = Read-DirtyBaseline
            # (D142) Paths that differ between TASK_BASE_REF and HEAD are
            # COMMITTED task work — the task's auto-commit contains them, so
            # the baseline filter below must never drop them (D137 silently
            # lost 4 tracked edits and an untracked migration whose content
            # matched their claim-time hashes after the auto-commit).
            # (D226) Prefer the base recorded by THIS task's own claim. The
            # shared TASK_BASE_REF is the nested task's after a nested claim,
            # and feeding a foreign range to the override below misfires in
            # BOTH directions — real task work that was dirty at claim gets
            # dropped (the D137 loss D142 exists to prevent), and foreign
            # paths get retained. This script builds no snapshot, but it does
            # read the base, so the read needs the same per-task selection the
            # bash twin applies.
            $committedRange = @()
            $cfBase = ''
            if ($TaskId) {
                $ownKey = 'TASK_BASE_REF_' + ($TaskId -replace '[^A-Za-z0-9_]', '_')
                $cfBase = [System.Environment]::GetEnvironmentVariable($ownKey, 'Process')
                # Records written by the bash twin are sq_escape'd and the
                # cache loader keeps the literal quotes, so strip them.
                if ($cfBase) { $cfBase = $cfBase.Trim("'") }
            }
            if (-not $cfBase) {
                $cfBase = [System.Environment]::GetEnvironmentVariable('TASK_BASE_REF', 'Process')
                if ($cfBase) { $cfBase = $cfBase.Trim("'") }
            }
            if ($cfBase) {
                try {
                    $committedRange = @(& git -C $ProjectDir diff --name-only $cfBase HEAD 2>$null)
                    if ($LASTEXITCODE -ne 0) { $committedRange = @() }
                } catch {
                    $committedRange = @()
                }
            }
            $filtered = @($entries | Where-Object {
                if ($_.path -eq '.stride-diff-upload-state' -or
                    $_.path -eq '.stride-changed-files.json' -or
                    $_.path -eq '.stride-dirty-baseline' -or
                    $_.path -eq '.stride.md' -or
                    $_.path -eq '.stride_auth.md') { return $false }
                # (W1609) Hard-exclude the whole root .stride/ state directory
                # (orchestrator marker, the .last-api-response.json capture) —
                # mirrors stride-hook.sh's `$0 !~ /^\.stride\//`.
                if ($_.path -match '^\.stride/') { return $false }
                if ($dirtyBaseline -and $dirtyBaseline.ContainsKey($_.path)) {
                    # (D142) Committed-range override: a path the task's
                    # commits contain is task work by definition — never
                    # baseline-excluded.
                    if ($committedRange -contains $_.path) { return $true }
                    $blHash = $dirtyBaseline[$_.path]
                    if ($blHash -eq 'unhashable') { return $true }
                    $full = Join-Path $ProjectDir $_.path
                    if (Test-Path -LiteralPath $full -PathType Leaf) {
                        $curHash = (& git -C $ProjectDir hash-object -- $_.path 2>$null | Out-String).Trim()
                        if ($LASTEXITCODE -ne 0 -or -not $curHash) { return $true }
                    } else {
                        $curHash = 'absent'
                    }
                    return ($curHash -ne $blHash)
                }
                return $true
            })
            if ($filtered.Count -ne $entries.Count) {
                # Pipe (not -InputObject) so an array is not double-wrapped into
                # [[...]]; guard the empty case explicitly because piping zero
                # items emits nothing rather than `[]`.
                if ($filtered.Count -eq 0) {
                    $filteredJson = '[]'
                } else {
                    $filteredJson = $filtered | ConvertTo-Json -Depth 10 -Compress -AsArray
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($filteredJson)
            }
        } catch {
            # Snapshot not parseable as the expected array — keep the raw bytes.
        }
        $b64 = [System.Convert]::ToBase64String($bytes)
        $body = @{ changed_files = @{ encoding = 'base64'; data = $b64 } } |
            ConvertTo-Json -Depth 5 -Compress
        # -SkipHttpErrorCheck keeps non-2xx responses on the success path so
        # the real status code is recorded instead of a generic '000'.
        $resp = Invoke-WebRequest `
            -Uri "$ApiBase/api/tasks/$TaskId/changed_files" `
            -Method Put `
            -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $Token" } `
            -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 10
        $httpCode = "$($resp.StatusCode)"
    } catch {
        # Transport failure (connection refused, DNS, timeout) — '000',
        # matching the bash twin's `|| printf '000'`.
        $httpCode = '000'
    }
    # Surface a failed upload instead of dropping it silently. The diff is
    # non-fatal to completion, so we warn rather than abort.
    if ($httpCode -notmatch '^2') {
        [Console]::Error.WriteLine(
            "stride-hook: changed_files upload failed (HTTP $httpCode) for task $TaskId")
    }
    return $httpCode
}

# Record the outcome of a changed_files PUT attempt (W1094) so the
# before_review self-heal can verify it on a fresh timeout budget. Task id
# and HTTP code ONLY — never the URL or bearer token (the file lives
# untracked in the project root alongside the other .stride artifacts).
function Write-DiffUploadState {
    param([string]$TaskId, [string]$HttpCode)
    try {
        Set-Content -Path (Join-Path $ProjectDir '.stride-diff-upload-state') `
            -Value "task_id=$TaskId`nhttp_code=$HttpCode" -Encoding UTF8
    } catch {
        # Best-effort: a failed state write must never block the hook.
    }
}

# (D127) Resolve the authoritative task id for the CURRENT completion from the
# /complete or /mark_reviewed URL in the command, independent of the env cache.
# Mirror of stride-hook.sh's task_id_from_command. Those URLs always carry
# /api/tasks/<id>/<action>, so the changed_files upload targets the task the
# agent is actually completing even when a hidden claim left a STALE TASK_ID in
# the env cache — the confirmed empty-changed_files root cause (G321/D126: the
# diff was PUT to the previous task). Returns '' for the claim path (whose URL
# has no id); callers fall back to the env-cache TASK_ID then.
# (D220) Shares the ONE parser with routing, so an id can never be scraped out of
# a command that did not actually issue the request — the `echo` that drove a
# live changed_files PUT against task 999999999 went through this path.
function Get-TaskIdFromCommand {
    param([string]$CommandText)
    return (Get-StrideRoute -Phase '' -CommandText $CommandText).TaskId
}

# Fire-and-forget upload of the per-file diff snapshot to the Stride server.
# Mirror of stride-hook.sh's finalize_after_doing PUT path. URL and token are
# resolved by Resolve-StrideApiUrl / Resolve-StrideApiToken — preferring
# $ProjectDir\.stride_auth.md so the upload works whether the agent's
# completion curl used literal values or shell variables ($STRIDE_API_URL /
# $STRIDE_API_TOKEN), with the $Command literal extraction kept as a fallback.
# Silently no-ops if any prerequisite is missing (snapshot file, URL, token,
# TASK_ID) so behavior degrades to the legacy on-disk-only snapshot.
function Invoke-FinalizeAfterDoing {
    if ($HookName -ne 'after_doing') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken

    # (D127) Target the task id from the /complete URL, not the env cache, so a
    # stale TASK_ID from a hidden claim response cannot route the diff to the
    # wrong task. Fall back to the env-cache TASK_ID only if the URL carries no id.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }
    if (-not $apiBase -or -not $token -or -not $taskId) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    # (W1094) Record the outcome after EVERY PUT attempt so the before_review
    # self-heal can verify it on a fresh timeout budget. A skipped PUT
    # (missing preconditions) deliberately writes nothing: missing state
    # means "no healthy upload on record" and the retry re-checks the same
    # preconditions itself.
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
}

# (D142) Rewrite TASK_BASE_REF — and re-record the dirty baseline — AFTER the
# ## before_doing section has run. Mirror of stride-hook.sh's
# finalize_before_doing: the section's `git pull` moves HEAD, so a base
# captured before it anchors the after_doing diff at the PRE-pull commit and
# the snapshot spans another clone's pulled work (the D132/W1678 incident).
# Called from the main flow right after Invoke-StrideSection returns for the
# before_doing route, regardless of the section's exit code (the claim
# already succeeded — PostToolUse cannot veto it). Skips silently when HEAD
# is unresolvable (not a git repo) — the pre-section strip already removed
# any inherited TASK_BASE_REF in that case.
# (D226) PARITY NOTE. An earlier version of this comment claimed this script
# had "no read half to fix". That was WRONG and review caught it: this script
# does not BUILD a snapshot, but Invoke-ChangedFilesUpload does READ
# TASK_BASE_REF and run `git diff --name-only <base> HEAD` to drive D142's
# committed-range override. A foreign base there silently drops real task work
# or retains foreign paths. That read is now routed through the per-task
# record, so both halves are covered here:
#   WRITE half — a nested claim overwriting the shared TASK_BASE_REF happens
#     identically to the bash twin, and is mirrored below.
#   READ half — smaller than the bash twin's (no capture step to protect, so
#     no select_task_snapshot_base equivalent and nothing to REFUSE), but the
#     base selection it does perform now prefers this task's own record.
# The refusal path itself has no counterpart here, because there is no diff
# built on this side to refuse. State that precisely rather than claiming
# blanket parity — the last blanket claim in this comment was false.
function Invoke-FinalizeBeforeDoing {
    if ($HookName -ne 'before_doing') { return }
    $baseRef = ''
    try {
        $rev = & git -C $ProjectDir rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $rev) { $baseRef = ($rev | Out-String).Trim() }
    } catch {
        $baseRef = ''
    }
    if (-not $baseRef) { return }
    try {
        # TASK_BASE_REF_TRUSTED marks a base written by THIS post-before_doing
        # capture (the task branch point by construction) — the bash twin's
        # resolve_snapshot_base skips its branch-point rule for marked bases.
        # (D226) An owner stamp and a per-task record ride alongside the shared
        # keys, and earlier tasks' records are carried across, so a nested
        # claim cannot make an outer task's anchor unrecoverable.
        #
        # Stamped ONLY when this call's own response proved the identity (see
        # the gate in the claim block). Withholding costs nothing: the task
        # falls back to the shared TASK_BASE_REF, which on its own claim is
        # genuinely its own base. Stamping from an unproven identity is what
        # makes the refusal fire on the wrong side.
        $owner = ''
        $ownerKey = ''
        if ($script:TaskIdentityRefreshed) {
            $owner = $env:TASK_ID
            if ($owner) {
                $sanitized = $owner -replace '[^A-Za-z0-9_]', '_'
                # The per-task keys share a namespace with the TRUSTED and
                # OWNER markers; an id sanitizing to either would set those
                # from data. Ids are integers, so this stays theoretical.
                if ($sanitized -and $sanitized -ne 'TRUSTED' -and $sanitized -ne 'OWNER') {
                    $ownerKey = 'TASK_BASE_REF_' + $sanitized
                }
            }
            if (-not $ownerKey) { $owner = '' }
        }
        $preserved = @()
        $records = @()
        if (Test-Path $EnvCache) {
            $existing = @(Get-Content $EnvCache -Encoding UTF8)
            $preserved = @($existing | Where-Object {
                $_ -notmatch '^TASK_BASE_REF=' -and
                $_ -notmatch '^TASK_BASE_REF_TRUSTED=' -and
                $_ -notmatch '^TASK_BASE_REF_OWNER=' -and
                $_ -notmatch '^TASK_BASE_REF_[A-Za-z0-9_]+='
            })
            $records = @($existing | Where-Object {
                $_ -match '^TASK_BASE_REF_[A-Za-z0-9_]+=' -and
                $_ -notmatch '^TASK_BASE_REF_TRUSTED=' -and
                $_ -notmatch '^TASK_BASE_REF_OWNER=' -and
                ($ownerKey -eq '' -or $_ -notmatch ('^' + [regex]::Escape($ownerKey) + '='))
            } | Select-Object -Last 19)
        }
        $newLines = $preserved + $records + "TASK_BASE_REF=$baseRef" + "TASK_BASE_REF_TRUSTED=1"
        if ($ownerKey) {
            $newLines = $newLines + "TASK_BASE_REF_OWNER=$owner" + "$ownerKey=$baseRef"
        }
        $newLines | Set-Content -Path $EnvCache -Encoding UTF8
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF', $baseRef, 'Process')
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_TRUSTED', '1', 'Process')
        if ($ownerKey) {
            [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_OWNER', $owner, 'Process')
            [System.Environment]::SetEnvironmentVariable($ownerKey, $baseRef, 'Process')
        }
        # (W1457→D142) The dirty baseline moves with the base capture:
        # post-pull paths hashed against the post-pull base, so the exclusion
        # set and the diff anchor can never disagree.
        Write-DirtyBaseline -BaseRef $baseRef
    } catch {
        # Best-effort — a failed rewrite must never block the hook.
    }
}

# (W1094) Self-heal for the changed_files upload — mirror of
# stride-hook.sh's self_heal_changed_files_upload. The after_doing gate can
# burn the whole 600s hook budget, killing the process before or during the
# snapshot PUT — or the PUT itself returned non-2xx. before_review
# (PostToolUse on the same completion curl) runs on a FRESH budget, so it
# verifies the recorded outcome and re-PUTs the on-disk snapshot when no
# healthy upload is on record for the current task. Best-effort: never
# throws, never changes the hook's exit semantics. Unlike the bash twin
# this script has no capture step — the on-disk snapshot is the source of
# truth, so the retry re-uploads it as-is.
function Invoke-SelfHealChangedFilesUpload {
    if ($HookName -ne 'before_review') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }
    # (D127) Prefer the task id from the /complete URL over the env-cache TASK_ID
    # so the self-heal re-PUTs to the CORRECT task even after a stale claim.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }
    if (-not $taskId) { return }

    # Healthy 2xx recorded for THIS task → do not re-upload (snapshot
    # semantics anchor at after_doing time; avoid pointless API load).
    # Missing file, different task id, or non-2xx/empty code → retry.
    $stateFile = Join-Path $ProjectDir '.stride-diff-upload-state'
    $stateTask = ''
    $stateCode = ''
    if (Test-Path $stateFile) {
        try {
            foreach ($line in Get-Content -Path $stateFile -Encoding UTF8) {
                if ($line -match '^task_id=(.*)$' -and -not $stateTask) { $stateTask = $Matches[1] }
                if ($line -match '^http_code=(.*)$' -and -not $stateCode) { $stateCode = $Matches[1] }
            }
        } catch {
            # Unreadable state degrades to "retry".
        }
    }
    if ($stateTask -eq $taskId -and $stateCode -match '^2') { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
    # (W1658) before_review is the LAST retry. A non-2xx here means the diff is
    # definitively lost for this task — surface it loudly (distinct from the
    # per-attempt warning) and mark the state file unresolved so the failure is
    # actionable and never silently swallowed. A later successful PUT overwrites
    # the state file, clearing the mark.
    if ($httpCode -notmatch '^2') {
        [Console]::Error.WriteLine("stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task $taskId (HTTP $httpCode) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.")
        try {
            Add-Content -Path (Join-Path $ProjectDir '.stride-diff-upload-state') -Value 'unresolved=yes' -Encoding UTF8
        } catch {
            # Best-effort: a failed marker write must never block the hook.
        }
    }
}

# Parse and execute one .stride.md hook section. Takes the section name
# (e.g. "before_doing", "after_goal") and returns 0 on no-op (missing
# section or empty commands) / all-success, or 2 on first failure.
# Emits the same structured success/failed JSON shape as the original
# inline block — `$Section` is substituted for what used to be the
# global `$HookName`. Reuses Invoke-FinalizeAfterDoing which gates
# internally on the GLOBAL `$HookName`, so calling this for "after_goal"
# does NOT re-trigger the after_doing snapshot PUT.
# (W1456) Shell-semantics line-continuation check for the bash-section
# parser — mirror of line_continues in stride-hook.sh. Returns $true when
# the LOGICAL line ends in a backslash that escapes the newline: unescaped
# and not inside single quotes. Inside single quotes a backslash is a
# literal character; a trailing `\\` is an escaped backslash, not a
# continuation. Callers pass the accumulated logical line so quote state
# carries across joins.
function Test-LineContinues {
    param([string]$Line)

    $i = 0
    $state = 'none'
    while ($i -lt $Line.Length) {
        $c = $Line[$i]
        if ($state -eq 'single') {
            if ($c -eq "'") { $state = 'none' }
            $i++
        } elseif ($c -eq '\') {
            if (($i + 1) -eq $Line.Length) { return $true }
            $i += 2
        } elseif ($state -eq 'double') {
            if ($c -eq '"') { $state = 'none' }
            $i++
        } else {
            if ($c -eq "'") { $state = 'single' }
            elseif ($c -eq '"') { $state = 'double' }
            $i++
        }
    }
    return $false
}

function Invoke-StrideSection {
    param([string]$Section)

    $rawContent = Get-Content $StrideMd -Raw -Encoding UTF8
    $rawContent = $rawContent -replace "`r`n", "`n"
    $sectionLines = $rawContent -split "`n"

    $secCommands = ''
    $secFound = $false
    $secCapture = $false

    foreach ($rawLine in $sectionLines) {
        $line = $rawLine.TrimEnd("`r")

        if ($line -match '^## (.+)$') {
            if ($secFound) { break }
            $heading = $Matches[1].TrimEnd()
            if ($heading -eq $Section) { $secFound = $true }
            continue
        }

        if ($secFound) {
            if ($line -match '^```bash') {
                $secCapture = $true
                continue
            }
            if ($line -match '^```') {
                if ($secCapture) { break }
                continue
            }
            if ($secCapture) {
                $secCommands += $line + "`n"
            }
        }
    }

    if (-not $secCommands.Trim()) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    # (W1456) Join backslash-continued physical lines into logical lines
    # first (the backslash-newline pair is removed, per shell semantics);
    # trimming and comment/blank skipping apply to logical lines AFTER
    # joining. Mirror of the stride-hook.sh loop.
    $secCmdList = @()
    $secPending = ''
    foreach ($cmd in ($secCommands -split "`n")) {
        $cmd = $cmd.TrimEnd("`r")
        if ($secPending) {
            $cmd = $secPending + $cmd
            $secPending = ''
        } else {
            # Comments never continue: '#' lexes to end-of-line in shell,
            # so a trailing backslash on a standalone comment line is inert
            # — skip it here so it cannot swallow the next command.
            if ($cmd.TrimStart().StartsWith('#')) { continue }
        }
        if (Test-LineContinues -Line $cmd) {
            $secPending = $cmd.Substring(0, $cmd.Length - 1)
            continue
        }
        $trimmedCmd = $cmd.TrimStart()
        if (-not $trimmedCmd) { continue }
        if ($trimmedCmd.StartsWith('#')) { continue }
        $secCmdList += $trimmedCmd
    }
    # Trailing backslash on the section's last line — emit the accumulated
    # command with the marker already stripped; never hang or drop it.
    if ($secPending) {
        $trimmedCmd = $secPending.TrimStart()
        if ($trimmedCmd -and -not $trimmedCmd.StartsWith('#')) {
            $secCmdList += $trimmedCmd
        }
    }

    if ($secCmdList.Count -eq 0) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    Set-Location $ProjectDir

    # Early per-file diff snapshot upload (W1093 parity, ported in W1095) —
    # the after_doing section runs the full quality gate, and the 600s hook
    # timeout can kill this process mid-loop, silently losing the diff
    # upload. PUT the snapshot BEFORE the first command executes; the
    # post-loop call below is KEPT as a refresh once the gate succeeds. A
    # bare call is safe: Invoke-FinalizeAfterDoing gates internally on the
    # GLOBAL $HookName (so the after_goal reuse of this function stays
    # inert), emits nothing on stdout, and never throws.
    Invoke-FinalizeAfterDoing

    $secCompletedCmds = @()
    # Parallel to $secCompletedCmds: one object per successful command holding
    # its tail-truncated stdout/stderr, folded into the success JSON's
    # commands_output array (D65). Keeps passing-gate output off Console.Error
    # so Claude Code does not render it under a false "PreToolUse:Bash hook
    # error" label.
    $secCmdOutputs = @()
    $secStartTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # (W1455) Millisecond wall clock for duration_ms reporting; the seconds
    # clock above stays the budget-bookkeeping source.
    $secStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $secCmdIndex = 0
    $secCmdTotal = $secCmdList.Count
    # (W1454) Section-level budget: each command gets the REMAINING budget so
    # the whole section can never exceed its documented table value.
    $secBudget = Resolve-SectionBudget -Section $Section

    foreach ($execTrimmed in $secCmdList) {
        $secStdoutFile = [System.IO.Path]::GetTempFileName()
        $secStderrFile = [System.IO.Path]::GetTempFileName()

        try {
            $secTimedOut = $false
            $secCmdExit = 0
            $secElapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $secStartTime
            $secRemainingSec = $secBudget - $secElapsed

            if ($secRemainingSec -le 0) {
                # Earlier commands consumed the whole section budget — do not
                # start this one.
                $secTimedOut = $true
                $secCmdExit = 124
                Set-Content -Path $secStderrFile -Value "${secBudget}s section budget exhausted before this command started" -Encoding UTF8 -NoNewline
            } else {
                # ProcessStartInfo.ArgumentList passes each element as an exact
                # argv entry on every platform. Start-Process -ArgumentList must
                # NOT be used here: it joins the elements into a single string,
                # which .NET on Unix re-splits on whitespace, so a multi-word
                # command reaches bash -c mangled and its output is lost.
                $secPsi = [System.Diagnostics.ProcessStartInfo]::new()
                $secPsi.FileName = 'bash'
                $secPsi.ArgumentList.Add('-c')
                $secPsi.ArgumentList.Add($execTrimmed)
                $secPsi.RedirectStandardOutput = $true
                $secPsi.RedirectStandardError = $true
                $secPsi.UseShellExecute = $false
                $secPsi.WorkingDirectory = (Get-Location).Path
                # (W1453) Re-add empty-valued keys the Process env block cannot
                # hold, so user commands see them defined-but-empty per the
                # hook-execution.md contract (prevents ${VAR?} / set -u aborts).
                foreach ($emptyKey in $script:StrideEmptyEnvKeys) {
                    $secPsi.Environment[$emptyKey] = ''
                }
                $proc = [System.Diagnostics.Process]::Start($secPsi)
                # Drain both pipes concurrently: a synchronous ReadToEnd on
                # stdout would deadlock if the child fills the stderr pipe
                # buffer (~64KB) while its stdout is still open — gate commands
                # like `mix compile` can emit that much warning text.
                $secOutTask = $proc.StandardOutput.ReadToEndAsync()
                $secErrTask = $proc.StandardError.ReadToEndAsync()
                # (W1454) Bounded wait on the remaining section budget. On
                # expiry, Kill($true) terminates the ENTIRE process tree so a
                # hung command's children cannot keep running with the
                # exported env, then synthesize the conventional exit 124.
                if (-not $proc.WaitForExit([int]($secRemainingSec * 1000))) {
                    $secTimedOut = $true
                    try { $proc.Kill($true) } catch { }
                    $proc.WaitForExit()
                }
                # Bounded drain: the pipes close when the tree is killed; the
                # 5s guard covers a detached grandchild holding a pipe open.
                $secProcStdout = if ($secOutTask.Wait(5000)) { $secOutTask.Result } else { '' }
                $secProcStderr = if ($secErrTask.Wait(5000)) { $secErrTask.Result } else { '' }
                Set-Content -Path $secStdoutFile -Value $secProcStdout -Encoding UTF8 -NoNewline
                Set-Content -Path $secStderrFile -Value $secProcStderr -Encoding UTF8 -NoNewline
                $secCmdExit = if ($secTimedOut) { 124 } else { $proc.ExitCode }
            }

            if ($secCmdExit -eq 0) {
                $secCompletedCmds += $execTrimmed
                # Do NOT write the passing command's output to Console.Error:
                # Claude Code renders any hook stderr under a red
                # "PreToolUse:Bash hook error" label even on exit 0 (D65).
                # Instead capture a tail-truncated copy — same -50 cap as the
                # failure path below — into $secCmdOutputs, folded into the
                # success JSON's commands_output array so agents keep visibility.
                $secOkStdout = ''
                $secOkStderr = ''
                if (Test-Path $secStdoutFile) {
                    # @() guards against $null (empty file) under StrictMode.
                    $allLines = @(Get-Content $secStdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secOkStdout = $allLines -join "`n"
                }
                if (Test-Path $secStderrFile) {
                    $allLines = @(Get-Content $secStderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secOkStderr = $allLines -join "`n"
                }
                $secCmdOutputs += [ordered]@{
                    command = $execTrimmed
                    stdout  = $secOkStdout
                    stderr  = $secOkStderr
                }
            } else {
                $secCmdStdout = ''
                $secCmdStderr = ''
                if (Test-Path $secStdoutFile) {
                    # @() coerces $null (empty file) into an empty array so
                    # .Count is safe under Set-StrictMode -Version Latest.
                    $allLines = @(Get-Content $secStdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secCmdStdout = $allLines -join "`n"
                }
                if (Test-Path $secStderrFile) {
                    $allLines = @(Get-Content $secStderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secCmdStderr = $allLines -join "`n"
                }
                Remove-Item -Force $secStdoutFile, $secStderrFile -ErrorAction SilentlyContinue

                $secRemainingCmds = @()
                if (($secCmdIndex + 1) -lt $secCmdTotal) {
                    $secRemainingCmds = $secCmdList[($secCmdIndex + 1)..($secCmdTotal - 1)]
                }

                $failureResult = [ordered]@{
                    hook              = $Section
                    status            = 'failed'
                    failed_command    = $execTrimmed
                    command_index     = $secCmdIndex
                    exit_code         = $secCmdExit
                    timed_out         = [bool]$secTimedOut
                    budget_seconds    = $secBudget
                    stdout            = $secCmdStdout
                    stderr            = $secCmdStderr
                    commands_completed = $secCompletedCmds
                    commands_remaining = $secRemainingCmds
                }
                # Write JSON directly to the host stdout stream rather than
                # via the function's output pipeline — otherwise the caller's
                # $primaryRc = Invoke-StrideSection ... assignment captures
                # the JSON alongside the int `return`, producing an array
                # and breaking the `-ne 0` check on every success path.
                [Console]::Out.WriteLine(($failureResult | ConvertTo-Json -Depth 5 -Compress))

                if ($secTimedOut) {
                    [Console]::Error.WriteLine("Stride $Section hook command $($secCmdIndex + 1)/$($secCmdTotal) timed out after ${secBudget}s budget: $execTrimmed")
                } else {
                    [Console]::Error.WriteLine("Stride $Section hook failed on command $($secCmdIndex + 1)/$($secCmdTotal): $execTrimmed")
                }
                if ($secCmdStderr) { [Console]::Error.WriteLine($secCmdStderr) }

                return 2
            }
        } finally {
            Remove-Item -Force $secStdoutFile, $secStderrFile -ErrorAction SilentlyContinue
        }

        $secCmdIndex++
    }

    # Per-file diff snapshot PUT — no-op outside after_doing (gates on the
    # GLOBAL $HookName, so calling this for "after_goal" does not retrigger).
    # (W1095) This is the REFRESH of the early pre-loop upload — keep it: the
    # gate's commands may rewrite the snapshot, and this re-uploads the
    # final state.
    Invoke-FinalizeAfterDoing

    $secEndTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $secDuration = $secEndTime - $secStartTime
    # (W1455) duration_ms is the hook-execution.md contract field; never
    # negative. duration_seconds is DEPRECATED — kept for one release for
    # any consumer still parsing it.
    $secDurationMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $secStartMs
    if ($secDurationMs -lt 0) { $secDurationMs = 0 }

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = $secCompletedCmds
        commands_output    = $secCmdOutputs
        duration_ms        = $secDurationMs
        duration_seconds   = $secDuration
    }
    # See the failure-path note above: route JSON to the host stdout so it
    # is not captured by `$primaryRc = Invoke-StrideSection ...`.
    # Depth 6 so the commands_output array of objects serializes fully.
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 6 -Compress))

    return 0
}

# Detect an `after_goal` entry in the response's `hooks` array. Handles
# both Claude Code's wrapped form (`tool_response.stdout` is a JSON string
# whose body contains the response) and raw-API-JSON form. Returns $true
# when an entry with name == "after_goal" is found, $false otherwise.
# Mirrors stride-hook.sh:response_has_after_goal — both scripts must agree
# on detection so Windows + Unix agents behave identically (pitfall:
# behavioral drift between .sh and .ps1).
# Pure predicate on an ALREADY-resolved payload object: does it carry an
# after_goal hook entry? Single-sourced so Test-AfterGoalInResponse and
# Invoke-AfterGoalRouting share one detection (mirrors bash payload_has_after_goal).
function Test-PayloadHasAfterGoal {
    param($Payload)

    if ($null -eq $Payload) { return $false }
    if (-not ($Payload.PSObject.Properties.Name -contains 'hooks')) { return $false }
    if ($null -eq $Payload.hooks) { return $false }

    foreach ($entry in @($Payload.hooks)) {
        if ($entry -and ($entry.PSObject.Properties.Name -contains 'name') -and $entry.name -eq 'after_goal') {
            return $true
        }
    }

    return $false
}

function Test-AfterGoalInResponse {
    param([string]$InputJson)

    # (W1453/D118) The payload shapes and the canonical-file fast path live in
    # Get-ResponsePayload now — detection and env extraction must agree.
    Test-PayloadHasAfterGoal -Payload (Get-ResponsePayload -InputJson $InputJson)
}

# --- After-goal execution (shared by the D118 fast path and the D119 fresh call) ---
# Export GOAL_* from the given payload and run the local ## after_goal section as
# a blocking hook, restoring HOOK_NAME afterward. Centralised so both detection
# paths run the section identically — and, because Invoke-AfterGoalRouting calls
# exactly one path, exactly once (de-dup). Mirrors bash run_after_goal_section.
function Invoke-AfterGoalSection {
    param($Payload)
    $script:afterGoalRouted = $true
    Set-AfterGoalEnv -Payload $Payload
    $savedHookNameEnv = [System.Environment]::GetEnvironmentVariable('HOOK_NAME', 'Process')
    [System.Environment]::SetEnvironmentVariable('HOOK_NAME', 'after_goal', 'Process')
    $null = Invoke-StrideSection -Section 'after_goal'
    [System.Environment]::SetEnvironmentVariable('HOOK_NAME', $savedHookNameEnv, 'Process')
}

# (D119) Reliability guarantee. Detect after_goal via a fresh, hook-initiated
# GET /api/tasks/:id/after_goal_status (W1613's compact endpoint). An HTTP call
# the hook makes itself is NOT subject to the Bash-tool output truncation that
# can gut the agent-handed /complete response, and needs zero agent cooperation.
# Runs ## after_goal from the endpoint's compact GOAL_* env when after_goal_armed
# is true. Best-effort: a missing prerequisite (TASK_ID/URL/token) or an
# unreachable / non-JSON endpoint degrades to a clean no-op — the server's grace-
# window worker still completes the goal. Never logs the token.
function Invoke-AfterGoalDetectionViaApi {
    $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process')
    if (-not $taskId) { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token) { return }

    $resp = $null
    try {
        $resp = Invoke-WebRequest `
            -Uri "$apiBase/api/tasks/$taskId/after_goal_status" `
            -Method Get `
            -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 10
    } catch {
        return
    }
    if ($null -eq $resp) { return }

    $status = $null
    try { $status = $resp.Content | ConvertFrom-Json } catch { return }
    if ($null -eq $status) { return }

    $armed = $false
    if (($status.PSObject.Properties.Name -contains 'after_goal_armed') -and $status.after_goal_armed) {
        $armed = $true
    }
    if (-not $armed) { return }

    # Wrap the endpoint's flat env into the after_goal-hook-entry shape
    # Set-AfterGoalEnv consumes; carry goal_id as data.parent_id so the GOAL_ID
    # parent-id fallback still applies if the env omits it.
    $envObj = if ($status.PSObject.Properties.Name -contains 'env') { $status.env } else { [PSCustomObject]@{} }
    $goalId = if ($status.PSObject.Properties.Name -contains 'goal_id') { $status.goal_id } else { $null }
    $payload = [PSCustomObject]@{
        hooks = @([PSCustomObject]@{ name = 'after_goal'; env = $envObj })
        data  = [PSCustomObject]@{ parent_id = $goalId }
    }

    Invoke-AfterGoalSection -Payload $payload
}

# --- After-goal routing (W504 / D118 / D119) ---
# Two mutually-exclusive paths so ## after_goal runs at most once:
#   * Fast path (D118): a resolved (complete) payload answers definitively —
#     armed runs the section; parseable-but-absent means definitively not armed.
#   * Reliability guarantee (D119): a $null payload (truncated/absent/unparseable
#     handed response) triggers the hook-initiated fresh call.
function Invoke-AfterGoalRouting {
    param($Payload)

    if ($null -ne $Payload) {
        if (Test-PayloadHasAfterGoal -Payload $Payload) { Invoke-AfterGoalSection -Payload $Payload }
        return
    }

    Invoke-AfterGoalDetectionViaApi
}

# (W1094 parity, ported in W1095) Verify-and-retry the changed_files upload
# before the primary before_review section runs — fresh PostToolUse budget;
# TASK_ID is in scope from the env cache. Self-gates on
# $HookName == 'before_review'; best-effort, never fails the hook.
try { Invoke-SelfHealChangedFilesUpload } catch { }

# --- Execute the primary hook ---
$primaryRc = Invoke-StrideSection -Section $HookName

# (D142) Capture TASK_BASE_REF only now — AFTER ## before_doing ran its
# `git pull` / branch checkout — so the base is the post-pull branch point.
# Runs even when the section failed: the claim already succeeded (PostToolUse
# cannot veto it) and a partially-run section still leaves HEAD more accurate
# than the pre-pull value. No-op for every other hook route.
try { Invoke-FinalizeBeforeDoing } catch { }

if ($primaryRc -ne 0) {
    exit $primaryRc
}

# --- After-goal routing (W505 / mirrors stride-hook.sh W504 / D118 / D119) ---
# When completing the last child of a goal, run the local `## after_goal`
# section as a blocking hook. Detection prefers the handed response when it is
# complete (D118 fast path via the file-first $responsePayload) and otherwise
# falls back to a fresh, hook-initiated GET /api/tasks/:id/after_goal_status that
# is immune to harness truncation (D119 — the reliability guarantee).
# Invoke-AfterGoalRouting keeps the two paths mutually exclusive so the section
# runs at most once. Missing `## after_goal` in .stride.md is a clean no-op; the
# server's grace-window worker still covers goal completion when neither path
# can detect it. A non-zero section exit is surfaced via the structured JSON
# shape, never as a non-zero script exit (the primary curl already succeeded).
# (D220) Gate on the endpoint the router already resolved, never on the raw
# command text — a mention of a completion URL is not a completion call.
if ($Phase -eq 'post' -and
    ($StrideRoute.Endpoint -ceq 'complete' -or $StrideRoute.Endpoint -ceq 'mark_reviewed')) {
    Invoke-AfterGoalRouting -Payload $responsePayload
}

# Clean up env cache, per-file diff snapshot, and upload state after the
# final hook in the lifecycle (W1095 mirrors the bash after_review cleanup).
# after_goal piggy-backs on after_review's lifecycle when present, so this
# gate intentionally stays on $HookName == 'after_review'.
if ($HookName -eq 'after_review') {
    # (W1453) Keep the env cache when after_goal rode this response — the
    # agent still needs GOAL_ID from it for the follow-up
    # PATCH /api/tasks/:goal_id/after_goal. The next claim rewrites the cache.
    if (-not $afterGoalRouted) {
        Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
    }
    Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-dirty-baseline') -ErrorAction SilentlyContinue
}

exit 0
