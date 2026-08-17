# W2099: PSScriptAnalyzer settings for the Windows PowerShell 5.1 compatibility gate.
#
# WHY 5.1 AND NOT pwsh 7: stride-hook.sh execs `powershell.exe`, which is
# Windows PowerShell 5.1. Every PowerShell change in this repo has only ever
# been executed under pwsh 7 -- the version on the development machines. A
# 7-only construct therefore passes every local run and fails only on a user's
# Windows box. These two rules catch that class before it ships.
#
# WHAT THIS BUYS, PRECISELY: 7-only *syntax*, and 7-only *cmdlet names* the
# profile knows about. That is all. It is NOT evidence the hook RUNS on 5.1 --
# runtime verification is a separate job. The full, verified list of what this
# gate cannot see is in README.md, "What this gate cannot see". Read it before
# concluding anything from a green run.
#
# ---------------------------------------------------------------------------
# THE `Enable` KEY IS ASYMMETRIC. DO NOT "TIDY" IT.
# ---------------------------------------------------------------------------
# These two rules disagree about the `Enable` key, and both failure modes are
# SILENT -- the rule simply stops producing findings while the run still exits
# 0 and looks clean:
#
#   PSUseCompatibleSyntax  REQUIRES `Enable = $true`.
#                          Omit it and the rule never fires.
#   PSUseCompatibleCmdlets MUST NOT be given `Enable` at all.
#                          Add it and the rule is dropped.
#
# Verified on PSScriptAnalyzer 1.25.0 / pwsh 7.6.4 by running the same 7-only
# probe through all three shapes: omitting Enable on the syntax rule lost every
# PSUseCompatibleSyntax finding; adding Enable to the cmdlet rule lost every
# PSUseCompatibleCmdlets finding; the shape below produced both.
#
# A symmetric-looking file (Enable on both, or neither) is exactly the thing
# that reads as correct, passes review, and quietly certifies nothing. This is
# why scripts/check-ps1-compat.ps1 re-proves both rules against an in-memory
# probe on EVERY run and fails when either goes silent. If you change anything
# in this file, that self-test is what will tell you whether you broke it.
#
# ---------------------------------------------------------------------------
# WHY THIS LIVES IN scripts/ AND NOT THE REPO ROOT
# ---------------------------------------------------------------------------
# A .psd1 at the plugin root reads as a PowerShell *module manifest* and would
# invite that misreading. The trade-off is that editors and a bare
# `Invoke-ScriptAnalyzer` will not auto-discover it -- the gate always passes
# `-Settings` explicitly, so nothing in this repo depends on auto-discovery.
#
# Changing TargetVersions or the compatibility profile is a deliberate,
# reviewed decision -- never a reflex to make a failing run pass. To silence a
# single deliberate divergence, suppress THAT finding with a justified
# SuppressMessageAttribute at the site; never remove a rule from this file,
# which would blind the gate everywhere at once.

@{
    IncludeRules = @(
        'PSUseCompatibleSyntax'
        'PSUseCompatibleCmdlets'
    )

    Rules = @{
        # Enable is REQUIRED here. See the asymmetry note above.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }

        # NO Enable key here -- adding one silently drops this rule.
        #
        # 'desktop-5.1.14393.206-windows' is the only 5.1 cmdlet profile shipped
        # with PSScriptAnalyzer (Windows Server 2016 era). Other 5.1 builds may
        # differ at the margins, and the profile's own data has gaps -- both are
        # recorded in README.md's gap list rather than implied away here.
        PSUseCompatibleCmdlets = @{
            compatibility = @('desktop-5.1.14393.206-windows')
        }
    }
}
