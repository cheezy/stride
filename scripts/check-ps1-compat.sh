#!/usr/bin/env bash
# W2099: Windows PowerShell 5.1 static-compatibility gate for hooks/*.ps1.
#
# stride-hook.sh execs `powershell.exe` -- Windows PowerShell 5.1 -- but every
# PowerShell change in this repo has only ever been executed under pwsh 7, the
# version on the development machines. A 7-only construct therefore passes
# every local run and fails only on a user's Windows box. This gate catches
# that class statically, and it runs anywhere pwsh 7 does, including macOS.
#
# WHAT IT PROVES: no 7-only syntax, and no 7-only cmdlet NAME the 5.1 profile
# knows about. Nothing more. A clean run is NOT evidence the hook RUNS on 5.1
# -- runtime verification on a real Windows host is a separate job. The
# verified list of blind spots is in README.md, "What this gate cannot see";
# read it before drawing a conclusion from a green run.
#
# This script NEVER installs anything, and nothing in the plugin's hook path
# invokes it. A hook that installs modules on a user's machine is an
# unacceptable side effect, so the prerequisite is documented, not automated.
#
# No pipes; no network. The one prerequisite is installed once, by hand.
#
# Exit codes:
#   0  clean  -- the gate proved itself live, and every scanned file passed
#   1  the repo's or the code's fault -- real findings, a broken gate, a
#      missing settings file, a scan that matched nothing, an unknown option
#   2  this machine's fault -- pwsh or PSScriptAnalyzer is not installed
#
# The 1-vs-2 split is what lets the test suite skip on absent tooling while
# still failing loudly on real incompatibilities.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSSA_VERSION="1.25.0"
INSTALL_CMD="pwsh -NoProfile -Command \"Install-Module -Name PSScriptAnalyzer -RequiredVersion ${PSSA_VERSION} -Scope CurrentUser\""

usage() {
  echo "Usage: bash scripts/check-ps1-compat.sh [--self-test] [PATH]"
  echo ""
  echo "  (no arguments)  Scan hooks/*.ps1 against Windows PowerShell 5.1."
  echo "  --self-test     Prove the gate itself still detects 7-only code, then stop."
  echo "  PATH            Scan this file or directory instead of hooks/."
  echo ""
  echo "Exit codes: 0 clean, 1 findings or gate error, 2 pwsh/PSScriptAnalyzer absent."
  echo ""
  echo "Prerequisite, installed once by hand (this gate never installs it for you):"
  echo "  $INSTALL_CMD"
}

SELF_TEST_ONLY=0
# A single scalar, deliberately NOT a bash array: macOS ships bash 3.2, where
# "${ARR[@]}" on an empty array under `set -u` is an unbound-variable error.
# The committed scope is hooks/*.ps1; the positional path exists for the test
# suite's negative case, which needs exactly one throwaway directory.
TARGET=""

for arg in "$@"; do
  case "$arg" in
    --self-test)
      SELF_TEST_ONLY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "GATE ERROR: unknown option '$arg'"
      echo ""
      usage
      exit 1
      ;;
    *)
      # Reject a second positional rather than letting it overwrite the first.
      # Silently scanning only the last of two given paths is the same
      # silent-loss shape the worker refuses when it makes a zero-file scan
      # red: the caller asked for something the gate did not do, and said so.
      if [ -n "$TARGET" ]; then
        echo "GATE ERROR: only one PATH may be given (got '$TARGET' and '$arg')"
        exit 1
      fi
      # An explicit empty argument is a caller mistake, not an absent one.
      # Treating it as absent would quietly scan hooks/ while the caller
      # believed they had scoped the run somewhere else.
      if [ -z "$arg" ]; then
        echo "GATE ERROR: PATH was given as an empty string"
        exit 1
      fi
      TARGET="$arg"
      ;;
  esac
done

# `--self-test PATH` reads naturally as "prove the gate works AND scan PATH",
# but --self-test exits before any scan. Silently discarding the path would
# return 0 having scanned nothing -- the most plausible wrong invocation also
# being the most reassuring-looking one, and a false 0 is the single outcome
# no downstream consumer can detect.
if [ "$SELF_TEST_ONLY" -eq 1 ] && [ -n "$TARGET" ]; then
  echo "GATE ERROR: --self-test does not scan; drop the PATH, or run the two separately:"
  echo "  bash scripts/check-ps1-compat.sh --self-test"
  echo "  bash scripts/check-ps1-compat.sh $TARGET"
  exit 1
fi

# The one check PowerShell cannot make about itself.
if ! command -v pwsh > /dev/null 2>&1; then
  echo "GATE UNAVAILABLE: pwsh not found on PATH - the PowerShell 5.1 compatibility gate cannot run."
  echo "  Install PowerShell 7 (https://aka.ms/powershell), then install the analyzer once:"
  echo "    $INSTALL_CMD"
  echo "  This gate never installs anything for you."
  exit 2
fi

WORKER="$ROOT/scripts/check-ps1-compat.ps1"
if [ ! -f "$WORKER" ]; then
  echo "GATE ERROR: worker script not found at $WORKER"
  exit 1
fi

# -NoProfile is load-bearing: a contributor's PowerShell profile must not be
# able to change this gate's verdict.
if [ "$SELF_TEST_ONLY" -eq 1 ]; then
  pwsh -NoProfile -File "$WORKER" -SelfTestOnly
elif [ -n "$TARGET" ]; then
  pwsh -NoProfile -File "$WORKER" -Path "$TARGET"
else
  pwsh -NoProfile -File "$WORKER"
fi

exit $?
