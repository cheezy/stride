#!/usr/bin/env bash
#
# check-port-canon.sh -- port drift check against docs/port-canon.md.
#
# Reads the canon, then verifies that every port the canon holds responsible
# for a rule actually carries that rule's anchor, at the canon's current
# version. Reports per port per rule:
#
#   MISSING       the port owes this rule and carries no anchor for it
#   STALE         an anchor is present, at an older version than the canon's
#   UNEXPECTED    an anchor is present for a rule this port does not owe,
#                 or for an id the canon does not define at all
#   DEFECT        a check: "property" rule the port's files actually violate
#   UNVERIFIABLE  a check: "property" rule this script cannot evaluate,
#                 because the canon's entry version is ahead of the checker
#   ok            the cell is clean
#
# ROUND 5 -- independent security audit (W2108), recorded here because a
# checker's credibility rests on what has been tried against it, and that
# history is invisible from the code alone.
#
# Two auditors read this file independently: one given a value-flow map of the
# script, one given nothing but the file and the canon. Neither was told what
# the other found, and neither was told the two candidates the exploration
# phase had flagged -- both of which were REFUTED before the audit ran (the
# property loop's missing tab/newline guard is unreachable because
# scan_anchors refuses first; a duplicate entry id makes $astatus multi-line,
# which matches no clean branch and therefore fails toward being checked).
#
# They converged on one root shape, which is the finding of this round:
#
#   find SUCCEEDING was read as "the tree was examined". Every read failure
#   BELOW find collapsed into the same empty output that a clean file
#   produces -- an unreadable file, a grep error, a grep -I binary skip, a
#   symlinked .md, a symlinked port directory, an empty walk.
#
# Rounds 1-4 closed exactly this class twice, at the directory granularity
# (find's exit status) and at the path-representability granularity (the NUL
# walk plus the tab/newline refusal). The FILE granularity was never closed,
# so seven distinct false greens remained, each reproduced before and after:
#
#   1. chmod 000 on a file holding a real D217 violation flipped exit 1 to
#      exit 0, reporting "property verified across 1 markdown files" -- a
#      count that included the file nobody opened.
#   2. An unreadable .md hid an UNEXPECTED anchor; the port reported clean.
#   3. A single NUL byte did the same, silently: grep -I skips and exits 1,
#      which is byte-identical to "no anchors here", with no stderr at all.
#   4. A port checked out as a symlink passed [ -d ] and was not descended by
#      find's default -P: "verified across 0 markdown files", exit 0, over a
#      tree full of violations.
#   5. A symlinked .md is not -type f, so it left the walk in silence.
#   6. A port whose rows were all not_applicable/deferred recorded NOTHING
#      when its tree could not be enumerated -- record() is the only writer of
#      STATUS -- so the run printed "NOT FULLY EXAMINED" and "repos needing
#      work: <port>" and still exited 0.
#   7. A json fence with one trailing space, or written with tildes, opened an
#      ordinary fence: the rule entry inside it ceased to exist for this
#      checker while rendering normally for every human, taking its MISSING
#      cells with it.
#
# An eighth, found while planning and fixed with them: the registry's
# exists:false and a row's status are two statements about one port, and the
# report layer read only the first -- deferring every rule without reading a
# row, so a half-applied canon edit exited 0 over a port owing everything.
#
# Review of those fixes then found three more instances of the SAME root
# shape, in the round-5 lines themselves -- which is the fourth time in five
# rounds that a fix left a sibling path open, and the reason they are recorded
# here rather than quietly folded in:
#
#   a. grep's -I heuristic was left at the ambient locale while the two guards
#      above it pinned LC_ALL=C. The NUL byte-count test closed only the NUL
#      branch; under a multibyte locale, and under a non-GNU grep, "binary"
#      is a wider set than "contains a NUL" and the surplus folded back into
#      "no anchors here". Now pinned.
#   b. A symlinked SUBDIRECTORY does not match -name '*.md', so filtering by
#      name inside find left it in exactly the silence the file-level fix had
#      just closed. find now prints every symlink and the shell decides.
#   c. The property loop is a SECOND, independent find, and it handed paths
#      straight to fence_defect, which follows a link. That was safe only
#      because scan_anchors refuses first -- making a read-outside-the-tree
#      guarantee depend on call ordering across two enumerations, the same
#      time-of-check/time-of-use shape this walker was already defeated by
#      once. The guard is now applied where the value is used.
#
#      It was first written to refuse EVERY symlink and annotated here as
#      "unreachable today". Both were wrong, and review caught them: the
#      branch is reached whenever a port under a property rule holds an
#      ordinary symlink, and refusing every symlink made the two passes
#      disagree about one tree -- an ordinary link.txt became UNVERIFIABLE
#      over a genuinely clean port. A false RED rather than a false green, so
#      no pitfall was broken and the fleet stayed invariant, which is exactly
#      why nothing caught it: the round's own new self-test for a harmless
#      symlink ran the ANCHOR canon, so the property loop never executed. It
#      now carries scan_anchors' exemption, and the symlink cases run under
#      both canons.
#
#      That correction then overshot in the other direction, and a third
#      review round caught it: gating only the REFUSAL let the exempt symlink
#      fall through to code that READS it. fence_defect follows a link, so
#      link.txt -> /outside/anything was read and its content attributed to
#      this port -- a read outside the port tree, which is the property the
#      NUL walk exists to protect -- and it counted into nfiles, so a port
#      with no real markdown at all walked past the empty-walk refusal and
#      reported "property verified across 1 markdown files". It survived the
#      round that introduced it because that round's fixture linked to an
#      in-tree file that resolves. No symlink is read here now: refused if it
#      is a directory or *.md, ignored otherwise, which is what scan_anchors
#      does with its bare ':'.
#
#      Three rounds of review, three different defects, all in the symlink
#      handling added by ONE fix. That is the strongest evidence in this
#      file's history for the rule it keeps relearning: a guard and its
#      sibling must agree about the whole tree, not about the case the
#      fixture happened to build.
#
# The suite grew from 72 cases to 100. No existing case was modified, and the
# fleet result is byte-identical before and after (exit 1; ok 4, missing 44,
# defect 4) -- the changes only ever move a cell toward refusal.
# (Both figures in this paragraph are W2108's record, not today's: the suite
# is now at 104 and the fleet at ok 51 / missing 1. D285 annotated the tally
# and left the count unannotated, which was the same misreading hazard half
# done; this note closes it. Read the whole paragraph as that round's log.)
#
# Two findings were recorded and deliberately NOT fixed, because both are
# judgement calls about intent rather than defects: head -1 collapses multiple
# anchors for one id (the informed auditor called it a suppressed STALE tier,
# the blind auditor independently judged it defensible), and the canon
# self-exclusion is an exact path string, so an aliased --ports-parent or a
# vendored copy of the canon inside a port would credit that port with every
# anchor. Both are filed rather than patched under time pressure: this file
# has twice had a fix introduce the next round's defect.
#
# D285 -- DISPOSITION OF THE DEFERRED FINDINGS
#
# One fixed, three declined. The decline is a decision with a reason, not a
# deferral repeated: each names what would have to change for it to be taken
# up, so the next reader inherits the argument rather than the backlog.
#
#   FIXED -- finding 3, the grep -I readable-as-text decision.
#      LC_ALL=C pinned the locale axis; -I still let grep's own heuristic
#      decide, and a heuristic broader than "contains a NUL" skips a NUL-free
#      file and exits 1, which is byte-identical to "no anchors here". The
#      scan now passes -a instead, so readable-as-text is decided by the
#      byte-count guard from the file's own content and by nothing else. The
#      reasoning and the measurement are at the call site in emit_anchors.
#      Two self-test cases cover it; both fail against the pre-fix script
#      (measured: pre-fix 100 passed / 2 failed, post-fix 102 / 0).
#      A LOCALE-axis pair was added afterwards, when an exploratory session
#      showed LC_ALL=C could be deleted from the scan with the suite still
#      reporting every case passing, while a not-owed anchor went back to
#      reading clean. Measured with the prefix deleted: 102 passed / 2 failed,
#      the two new cases. The three axes -- NUL, implementation, locale -- now
#      each have a case, which is the state that makes "the record matches the
#      code" checkable rather than asserted.
#      This finding was bash-only -- the PowerShell twin reads raw bytes via
#      .NET and never shells out to grep -- so fixing it CONVERGES the pair.
#
#   DECLINED -- finding 1 (head -1), finding 2a (exact-path self-exclusion)
#   and finding 2b (a canon copy inside a port tree satisfies every anchor).
#      Not declined on their merits. Findings 1 and 2a exist in
#      check-port-canon.ps1 in the same shape (its first-match lookup, and its
#      -ceq path comparison), and its own header makes a one-sided behaviour
#      change a defect in itself: the two halves' verdicts must agree on every
#      real input. Finding 2b is the same context-free anchor match on both
#      sides. So each of the three is a PAIRED change -- bash and PowerShell
#      together, with matching cases in both suites and a cross-verified run
#      of the pair -- which is a different and larger piece of work than the
#      one-sided edit the fault site invites. Fixing either half alone here
#      would manufacture exactly the disagreement class this pair is designed
#      to prevent, which is why "small and obvious" is the wrong reading of
#      these three.
#      Taking them up means doing all three across both halves in one change,
#      on a machine with pwsh, with the cross-verification run. Filed as D293
#      rather than done, and the .ps1 twin carries the mirror of this note.
#      Note the .ps1 declines finding 1 by pointing at the bash half, and this
#      file previously declined it without pointing anywhere -- so the two
#      notes together read as a loop. The loop is what the paired task breaks.
#
# The suite is at 104 cases. The current fleet baseline is exit 1 with
# ok 51, missing 1, stale 0, unexpected 0, defect 0, unverifiable 0 and 5
# deferred, unchanged by this work -- and note it is nothing like the
# "ok 4, missing 44, defect 4" recorded above, which was true when W2108 ran
# and has been overtaken by the fleet adopting anchors. Read that figure as
# that round's record, not as today's expected result.
#
# Anchors are searched per port DIRECTORY, never at a fixed path: ports keep
# these rules in structurally different places, and a fixed-path search finds
# nothing in three of the nine and reports false MISSING.
#
# The canon file itself is excluded from the anchor search. It is where every
# anchor is DEFINED, and it lives inside the "stride" port's own directory, so
# scanning it would report that port compliant on the strength of the
# definition site rather than an adoption site.
#
# EXIT CODES
#   0  every applicable cell reports ok
#   1  at least one cell reports MISSING, STALE, UNEXPECTED, DEFECT or
#      UNVERIFIABLE -- drift exists and is listed above
#   2  no verdict was possible: the canon is absent, unparseable, carries a
#      schema version this checker does not understand, has a bad registry
#      dir, or the command line was wrong
#
#   Under --self-test the codes mean: 0 every case passed, 1 at least one case
#   failed, 2 the temp dir could not be created or the flags were combined
#   wrongly. Note the gate's own correct result against the real fleet today is
#   exit 1 -- one anchor is still MISSING (D285 corrected this line, which said
#   every anchor was missing because no port had adopted one; 51 cells now
#   report ok) -- which is why this script is deliberately NOT wired into the
#   pass/fail hook suite the way its siblings are. Run --self-test to prove
#   the gate; run it bare to see the fleet's drift.
#
#   Note 2 does NOT mean what it means in check-ps1-compat.sh, where it is
#   reserved for the machine lacking pwsh. This script shells out to nothing
#   but awk and grep, so it has no machine-fault tier. What 2 shares with that
#   sibling is the operational meaning: this run proved nothing, so do not read
#   its silence as a pass.
#
# The gate performs no installs, opens no network connection, and writes no
# file. It reads local files and prints to stdout.

set -u
# Pathname expansion is disabled for the whole script. Filenames from find and
# anchor ids from scanned files are iterated in unquoted for-loops so they split
# on the newline IFS -- but IFS does not govern globbing, so without this a file
# named a[1].md is expanded against the filesystem before the loop body sees it.
# Demonstrated: a real fence violation in a[1].md was replaced by a clean
# sibling a1.md, and the gate reported the property verified and exited 0.
# Nothing here relies on globbing; the fence walker's case patterns are case
# patterns, which set -f does not affect.
set -f

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CANON="$ROOT/docs/port-canon.md"
PORTS_PARENT=""
SELF_TEST=0
CANON_SET=0
PORTS_SET=0

# Absolute path to this script, so --self-test can re-invoke it against the
# fixtures rather than duplicating any of its logic.
SELF="$ROOT/scripts/$(basename "$0")"

usage() {
  cat <<'USAGE'
usage: check-port-canon.sh [--ports-parent DIR] [--canon PATH] [-h|--help]

  --ports-parent DIR  Directory holding the port checkouts. Each registry
                      "dir" is resolved as one level below this directory.
                      Defaults to the parent of the stride repo root, which
                      is where the ports sit in a normal checkout.
  --canon PATH        Canon document to read. Defaults to docs/port-canon.md
                      inside this repo.
  --self-test         Prove the gate still detects MISSING, STALE, UNEXPECTED,
                      DEFECT and UNVERIFIABLE -- and still reports a clean tree
                      as clean -- by running it against synthetic fixtures under
                      a temp dir, then stop. Scans nothing real.
  -h, --help          Print this message.

--ports-parent and --canon exist so the check can be exercised against a
synthetic fixture tree. Neither is needed in normal use.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) SELF_TEST=1; shift ;;
    --ports-parent)
      [ $# -ge 2 ] || { echo "GATE ERROR: --ports-parent needs a directory" >&2; exit 2; }
      PORTS_PARENT="$2"; PORTS_SET=1; shift 2 ;;
    --canon)
      [ $# -ge 2 ] || { echo "GATE ERROR: --canon needs a path" >&2; exit 2; }
      CANON="$2"; CANON_SET=1; shift 2 ;;
    *) echo "GATE ERROR: unknown option \"$1\"" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PORTS_PARENT" ] || PORTS_PARENT="$(cd "$ROOT/.." && pwd)"

# --------------------------------------------------------------------------
# Self-test.
#
# Proves the gate still detects what it claims to detect, by running this
# script against synthetic canons and port trees. It exists for the same
# reason check-ps1-compat.sh --self-test does: a gate whose green result is
# never exercised can rot into one that always reports the same thing and
# still looks correct.
#
# That is not hypothetical here. An early version of the anchor search used
# grep -I without -E, so "+" was literal and NO anchor ever matched. Every
# real-fleet run still looked perfect, because on today's fleet every cell is
# MISSING regardless. The all-clean case below is what caught it, and it is
# why a red-by-design gate still needs green fixtures.
#
# Everything is created under mktemp -d and removed on exit. Nothing outside
# that directory is written.
# --------------------------------------------------------------------------
self_test() {
  # tmp is deliberately NOT local: the EXIT trap fires after this function has
  # returned, and a local would be out of scope by then -- which set -u makes a
  # fatal error rather than a silent one.
  local pass fail out rc f3
  tmp="$(mktemp -d)" || { echo "GATE ERROR: could not create a temp dir for --self-test" >&2; exit 2; }
  # Single-quoted body: $tmp is resolved by the shell when the trap fires,
  # never interpolated into the trap string. An interpolated value containing a
  # quote would close the quoting and let the remainder run.
  trap 'rm -rf "$tmp"' EXIT
  pass=0; fail=0
  f3='```'

  st_canon() { # $1=path $2=schema $3=beta-status $4=version $5=check $6=id
    local id="${6:-rule-one}" chk="${5:-anchor}" ver="${4:-1}"
    {
      echo "# canon"
      echo "${f3}json"
      echo "{ \"canon_schema_version\": $2,"
      echo '  "ports": ['
      echo '    {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""},'
      echo '    {"id": "beta",  "family": "f", "dir": "beta",  "exists": true, "note": ""}'
      echo '  ] }'
      echo "${f3}"
      echo "### r"
      echo "<!-- canon:$id v$ver -->"
      echo "${f3}json"
      echo "{ \"id\": \"$id\", \"version\": $ver, \"status\": \"active\", \"superseded_by\": null,"
      echo "  \"provenance\": \"quoted\", \"defects\": [\"D1\"], \"check\": \"$chk\", \"check_hint\": \"h\","
      echo '  "applies_to": ['
      echo '    {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
      echo "    {\"port\": \"beta\", \"status\": \"${3:-required}\", \"variant\": \"\", \"reason\": \"r\"} ] }"
      echo "${f3}"
    } > "$1"
  }

  st_run() { bash "$SELF" --canon "$1" --ports-parent "$2" 2>&1; }

  st_assert() { # $1=name $2=want-exit $3=got-exit $4=want-substring $5=output
    local ok=1
    [ "$2" = "$3" ] || ok=0
    if [ -n "$4" ]; then echo "$5" | grep -q "$4" || ok=0; fi
    if [ "$ok" -eq 1 ]; then
      pass=$((pass + 1)); echo "ok: $1"
    else
      fail=$((fail + 1))
      echo "SELF-TEST FAILED: $1 (wanted exit $2, got $3; wanted /$4/)"
      echo "$5" | sed 's/^/    /'
    fi
  }

  st_refute() { # $1=name $2=must-NOT-contain $3=output
    if echo "$3" | grep -q "$2"; then
      fail=$((fail + 1)); echo "SELF-TEST FAILED: $1 (output must not contain /$2/)"
    else
      pass=$((pass + 1)); echo "ok: $1"
    fi
  }

  # --- the green case. Without it, a checker that always reports MISSING
  # --- would satisfy every red case below and look correct.
  mkdir -p "$tmp/k/alpha" "$tmp/k/beta"
  st_canon "$tmp/k.md" 1
  printf 'x\n<!-- canon:rule-one v1 -->\n' > "$tmp/k/alpha/a.md"
  printf 'x\n<!-- canon:rule-one v1 -->\n' > "$tmp/k/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/k")"; rc=$?
  st_assert "all-clean tree exits 0" 0 "$rc" "ok: rule-one v1" "$out"
  st_refute "all-clean tree prints no work list" "work list:" "$out"

  # --- MISSING
  mkdir -p "$tmp/m/alpha" "$tmp/m/beta"
  printf 'x\n' > "$tmp/m/alpha/a.md"; printf 'x\n' > "$tmp/m/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/m")"; rc=$?
  st_assert "absent anchor reports MISSING and exits 1" 1 "$rc" "MISSING: rule-one v1" "$out"
  st_assert "MISSING produces an actionable work list entry" 1 "$rc" "add <!-- canon:rule-one v1 -->" "$out"

  # --- STALE
  st_canon "$tmp/s.md" 1 required 2
  mkdir -p "$tmp/s/alpha" "$tmp/s/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/s/alpha/a.md"
  printf '<!-- canon:rule-one v2 -->\n' > "$tmp/s/beta/b.md"
  out="$(st_run "$tmp/s.md" "$tmp/s")"; rc=$?
  st_assert "older anchor reports STALE" 1 "$rc" "STALE: rule-one" "$out"

  # --- UNEXPECTED, both kinds
  st_canon "$tmp/u.md" 1 not_applicable
  mkdir -p "$tmp/u/alpha" "$tmp/u/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/u/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/u/beta/b.md"
  out="$(st_run "$tmp/u.md" "$tmp/u")"; rc=$?
  st_assert "anchor on a not_applicable port reports UNEXPECTED" 1 "$rc" "UNEXPECTED: rule-one" "$out"

  mkdir -p "$tmp/x/alpha" "$tmp/x/beta"
  printf '<!-- canon:rule-one v1 -->\n<!-- canon:ghost-rule v1 -->\n' > "$tmp/x/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/x/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/x")"; rc=$?
  st_assert "anchor for an undefined id reports UNEXPECTED" 1 "$rc" 'canon defines no rule "ghost-rule"' "$out"

  # --- the canon self-exclusion. The canon defines every anchor and lives
  # --- inside a registered port, so scanning it reports that port compliant
  # --- off the definition site. This case puts the canon INSIDE alpha, which
  # --- is what the real fleet looks like, and a relative path is what broke it.
  mkdir -p "$tmp/e/alpha/docs" "$tmp/e/beta"
  st_canon "$tmp/e/alpha/docs/port-canon.md" 1
  printf 'x\n' > "$tmp/e/beta/b.md"
  out="$(st_run "$tmp/e/alpha/docs/port-canon.md" "$tmp/e")"; rc=$?
  st_assert "canon inside a port does not make that port compliant" 1 "$rc" "MISSING: rule-one v1" "$out"
  st_refute "canon is never reported as an adoption site" "ok: rule-one v1 at docs/port-canon.md" "$out"
  out="$(cd "$tmp/e" && bash "$SELF" --canon alpha/docs/port-canon.md --ports-parent . 2>&1)"; rc=$?
  st_assert "relative --canon still excludes the canon" 1 "$rc" "MISSING: rule-one v1" "$out"

  # --- a registered, exists:true port whose directory is absent is a gate
  # --- fault, and a gate fault must not be downgraded by an ordinary finding
  # --- recorded later. Order matters: the absent port is listed FIRST here.
  {
    echo "# canon"; echo "${f3}json"
    echo '{ "canon_schema_version": 1,'
    echo '  "ports": [ {"id": "gone", "family": "f", "dir": "gone", "exists": true, "note": ""},'
    echo '             {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""} ] }'
    echo "${f3}"; echo "<!-- canon:rule-one v1 -->"; echo "${f3}json"
    echo '{ "id": "rule-one", "version": 1, "status": "active", "superseded_by": null,'
    echo '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
    echo '  "applies_to": [ {"port": "gone", "status": "required", "variant": "", "reason": ""},'
    echo '                  {"port": "alpha", "status": "required", "variant": "", "reason": ""} ] }'
    echo "${f3}"
  } > "$tmp/gf.md"
  mkdir -p "$tmp/gf/alpha"; printf 'x\n' > "$tmp/gf/alpha/a.md"
  out="$(st_run "$tmp/gf.md" "$tmp/gf")"; rc=$?
  st_assert "an absent required port is a gate fault, not downgraded to a finding" 2 "$rc" "" "$out"

  # --- deferred on a port that DOES exist: excluded from the tallies, and
  # --- never reported as MISSING.
  st_canon "$tmp/df.md" 1 deferred
  mkdir -p "$tmp/df/alpha" "$tmp/df/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/df/alpha/a.md"
  printf 'x\n' > "$tmp/df/beta/b.md"
  out="$(st_run "$tmp/df.md" "$tmp/df")"; rc=$?
  st_assert "deferred on an existing port is not a finding" 0 "$rc" "1 cells deferred" "$out"
  st_refute "deferred port is never reported MISSING" "MISSING" "$out"

  # --- deferred on a port that does not exist at all
  {
    echo "# canon"; echo "${f3}json"
    echo '{ "canon_schema_version": 1,'
    echo '  "ports": [ {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""},'
    echo '             {"id": "ghost", "family": "f", "dir": "ghost", "exists": false, "note": "n"} ] }'
    echo "${f3}"; echo "<!-- canon:rule-one v1 -->"; echo "${f3}json"
    echo '{ "id": "rule-one", "version": 1, "status": "active", "superseded_by": null,'
    echo '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
    echo '  "applies_to": [ {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
    echo '                  {"port": "ghost", "status": "deferred", "variant": "", "reason": "r"} ] }'
    echo "${f3}"
  } > "$tmp/dg.md"
  mkdir -p "$tmp/dg/alpha"; printf '<!-- canon:rule-one v1 -->\n' > "$tmp/dg/alpha/a.md"
  out="$(st_run "$tmp/dg.md" "$tmp/dg")"; rc=$?
  st_assert "unscaffolded deferred port reports distinctly and exits 0" 0 "$rc" "deferred: not scaffolded" "$out"

  # --- vendored catalog copies. These are checked against the same rules but
  # --- tallied separately, and the UNEXPECTED sweep must fire there too --
  # --- without it a catalog carrying an invented anchor is silently ignored.
  mkdir -p "$tmp/c/alpha" "$tmp/c/beta" "$tmp/c/stride-codex-marketplace/plugins/stride-codex"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/c/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/c/beta/b.md"
  printf 'x\n' > "$tmp/c/stride-codex-marketplace/plugins/stride-codex/vend.md"
  out="$(st_run "$tmp/k.md" "$tmp/c")"; rc=$?
  st_assert "a catalog missing an anchor is a finding" 1 "$rc" "MISSING: catalog stride-codex-marketplace" "$out"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/c/stride-codex-marketplace/plugins/stride-codex/vend.md"
  out="$(st_run "$tmp/k.md" "$tmp/c")"; rc=$?
  st_assert "a fully-vendored catalog is clean" 0 "$rc" "ok: catalog stride-codex-marketplace" "$out"
  printf '<!-- canon:rule-one v1 -->\n<!-- canon:invented v9 -->\n' > "$tmp/c/stride-codex-marketplace/plugins/stride-codex/vend.md"
  out="$(st_run "$tmp/k.md" "$tmp/c")"; rc=$?
  st_assert "an invented anchor in a catalog is UNEXPECTED, not silence" 1 "$rc" 'UNEXPECTED: catalog .* no rule "invented"' "$out"
  st_canon "$tmp/cs.md" 1 required 2
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/c/stride-codex-marketplace/plugins/stride-codex/vend.md"
  printf '<!-- canon:rule-one v2 -->\n' > "$tmp/c/alpha/a.md"
  printf '<!-- canon:rule-one v2 -->\n' > "$tmp/c/beta/b.md"
  out="$(st_run "$tmp/cs.md" "$tmp/c")"; rc=$?
  st_assert "a stale catalog copy is a finding" 1 "$rc" "STALE: catalog stride-codex-marketplace" "$out"

  # --- the property check: both fence characters, the unclosed verdict, and
  # --- the version binding that makes UNVERIFIABLE possible.
  st_canon "$tmp/p1.md" 1 required 1 property fence-nesting
  mkdir -p "$tmp/p1/alpha" "$tmp/p1/beta"
  printf '# t\n\n%sbash\necho hi\n%s\n' "$f3" "$f3" > "$tmp/p1/alpha/good.md"
  printf '# t\n\n%sbash\necho hi\n%s\n' "$f3" "$f3" > "$tmp/p1/beta/good.md"
  out="$(st_run "$tmp/p1.md" "$tmp/p1")"; rc=$?
  st_assert "a clean tree passes the property check" 0 "$rc" "ok: fence-nesting" "$out"

  printf '# t\n\n%smarkdown\n## s\n\n%sjson\n{}\n%s\n\n%s\n' "$f3" "$f3" "$f3" "$f3" > "$tmp/p1/alpha/bad.md"
  out="$(st_run "$tmp/p1.md" "$tmp/p1")"; rc=$?
  st_assert "a backtick nested fence is a DEFECT" 1 "$rc" "DEFECT: fence-nesting" "$out"

  rm -f "$tmp/p1/alpha/bad.md"
  printf '# t\n\n~~~markdown\n## s\n\n~~~json\n{}\n~~~\n\n~~~\n' > "$tmp/p1/alpha/bad.md"
  out="$(st_run "$tmp/p1.md" "$tmp/p1")"; rc=$?
  st_assert "the same shape written with tildes is a DEFECT too" 1 "$rc" "DEFECT: fence-nesting" "$out"

  rm -f "$tmp/p1/alpha/bad.md"
  printf '# t\n\n%sbash\necho never closed\n' "$f3" > "$tmp/p1/alpha/open.md"
  out="$(st_run "$tmp/p1.md" "$tmp/p1")"; rc=$?
  st_assert "an unclosed fence is a DEFECT" 1 "$rc" "unclosed:" "$out"
  rm -f "$tmp/p1/alpha/open.md"

  st_canon "$tmp/p7.md" 1 required 7 property fence-nesting
  out="$(st_run "$tmp/p7.md" "$tmp/p1")"; rc=$?
  st_assert "a property entry ahead of this checker is UNVERIFIABLE" 1 "$rc" "UNVERIFIABLE: fence-nesting v7" "$out"
  st_refute "an unimplemented property version never silently passes" "ok: fence-nesting" "$out"

  # --- vendored trees are excluded from the scan: a node_modules copy is a
  # --- dependency's file, not the port's, and must not satisfy a rule.
  mkdir -p "$tmp/nm/alpha/node_modules/dep" "$tmp/nm/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/nm/alpha/node_modules/dep/vendored.md"
  printf 'x\n' > "$tmp/nm/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/nm/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/nm")"; rc=$?
  st_assert "an anchor inside node_modules does not satisfy the rule" 1 "$rc" "MISSING: rule-one v1" "$out"

  # --- the parser refuses rather than guessing. Each of these would otherwise
  # --- be a silently wrong verdict.
  cp "$tmp/k.md" "$tmp/ph.md"
  printf '\n### note\n%sjson\n{"illustrative": true}\n%s\n' "$f3" "$f3" >> "$tmp/ph.md"
  out="$(st_run "$tmp/ph.md" "$tmp/k")"; rc=$?
  st_assert "a json block matching neither shape halts" 2 "$rc" "matches neither the registry shape" "$out"

  sed 's|"dir": "alpha"|"dir": "../escape"|' "$tmp/k.md" > "$tmp/bd.md"
  out="$(st_run "$tmp/bd.md" "$tmp/k")"; rc=$?
  st_assert "a dir that is not a single path segment halts" 2 "$rc" "not a single path segment" "$out"

  st_canon "$tmp/sv.md" 99
  out="$(st_run "$tmp/sv.md" "$tmp/k")"; rc=$?
  st_assert "an unknown canon_schema_version halts" 2 "$rc" "not the schema this checker understands" "$out"

  sed 's|{"port": "alpha", "status": "required"|{"port": "beta", "status": "required"|' "$tmp/k.md" > "$tmp/ord.md"
  out="$(st_run "$tmp/ord.md" "$tmp/k")"; rc=$?
  st_assert "applies_to out of registry order halts" 2 "$rc" "rows must follow registry order" "$out"

  sed 's|"check": "anchor"|"check": "sideways"|' "$tmp/k.md" > "$tmp/vo.md"
  out="$(st_run "$tmp/vo.md" "$tmp/k")"; rc=$?
  st_assert "a value outside a closed vocabulary halts" 2 "$rc" "outside the closed vocabulary" "$out"

  sed 's|"variant": "", "reason": "r"|"variant": "made-up", "reason": "r"|' "$tmp/k.md" > "$tmp/vv.md"
  out="$(st_run "$tmp/vv.md" "$tmp/k")"; rc=$?
  st_assert "a variant outside the declared vocabulary halts" 2 "$rc" "outside the canon's declared vocabulary" "$out"

  sed 's|"defects": \["D1"\]|"defects": []|' "$tmp/k.md" > "$tmp/nd.md"
  out="$(st_run "$tmp/nd.md" "$tmp/k")"; rc=$?
  st_assert "an entry with no defect trace halts" 2 "$rc" "empty defects array" "$out"

  sed 's|"check_hint": "h",||' "$tmp/k.md" > "$tmp/mk.md"
  out="$(st_run "$tmp/mk.md" "$tmp/k")"; rc=$?
  st_assert "an entry missing a required key halts" 2 "$rc" "missing required key" "$out"

  # --- the invariant the report layer exists to hold: a non-zero exit ALWAYS
  # --- produces a non-empty work list. A port-level UNEXPECTED used to fail
  # --- the gate while printing no work list at all, so the failing report and
  # --- a clean pass differed by two content lines.
  mkdir -p "$tmp/inv/alpha" "$tmp/inv/beta"
  printf '<!-- canon:rule-one v1 -->\n<!-- canon:invented-rule v9 -->\n' > "$tmp/inv/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/inv/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/inv")"; rc=$?
  st_assert "an unknown anchor fails the gate AND produces a work list" 1 "$rc" "work list:" "$out"
  st_assert "the unknown-anchor work item names the port and the anchor" 1 "$rc" "alpha: remove the unknown" "$out"
  st_refute "a failing run never claims a work list defect" "EMPTY, but findings exist" "$out"

  # --- a per-port verdict line, so "which repos need work" is answerable
  out="$(st_run "$tmp/k.md" "$tmp/k")"; rc=$?
  st_assert "a clean port prints a clean verdict" 0 "$rc" "verdict: clean" "$out"
  st_assert "a clean run lists the clean repos" 0 "$rc" "clean repos:" "$out"
  out="$(st_run "$tmp/k.md" "$tmp/m")"; rc=$?
  st_assert "a dirty port prints a NEEDS WORK verdict" 1 "$rc" "verdict: NEEDS WORK" "$out"
  st_assert "a dirty run lists the repos needing work" 1 "$rc" "repos needing work:" "$out"

  # --- MISSING work items must carry the literal to paste, not a description
  st_assert "a MISSING work item carries the anchor literal" 1 "$rc" "add <!-- canon:rule-one v1 -->" "$out"

  # --- a catalog finding must reach the kind counters, not only a side count.
  # --- The tally previously read "stale 0" with a STALE catalog row above it.
  mkdir -p "$tmp/ct/alpha" "$tmp/ct/beta" "$tmp/ct/stride-codex-marketplace/plugins/stride-codex"
  st_canon "$tmp/ct.md" 1 required 2
  printf '<!-- canon:rule-one v2 -->\n' > "$tmp/ct/alpha/a.md"
  printf '<!-- canon:rule-one v2 -->\n' > "$tmp/ct/beta/b.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/ct/stride-codex-marketplace/plugins/stride-codex/vend.md"
  out="$(st_run "$tmp/ct.md" "$tmp/ct")"; rc=$?
  st_assert "a stale catalog is counted in the stale tally, not hidden" 1 "$rc" "stale 1" "$out"
  st_refute "the tally never reports stale 0 beside a STALE row" "stale 0," "$out"

  # --- a catalog that is not checked out must be reported, never skipped
  mkdir -p "$tmp/pc2/alpha" "$tmp/pc2/beta" "$tmp/pc2/stride-codex-marketplace/plugins/stride-codex"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/pc2/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/pc2/beta/b.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/pc2/stride-codex-marketplace/plugins/stride-codex/vend.md"
  out="$(st_run "$tmp/k.md" "$tmp/pc2")"; rc=$?
  st_assert "an absent catalog is reported as NOT EXAMINED" 0 "$rc" "NOT EXAMINED" "$out"
  st_assert "the summary counts the unexamined catalogs" 0 "$rc" "were NOT examined" "$out"

  # --- UNVERIFIABLE work belongs to the checker, not to every port
  st_canon "$tmp/uv.md" 1 required 7 property fence-nesting
  mkdir -p "$tmp/uv/alpha" "$tmp/uv/beta"
  printf 'clean\n' > "$tmp/uv/alpha/a.md"; printf 'clean\n' > "$tmp/uv/beta/b.md"
  out="$(st_run "$tmp/uv.md" "$tmp/uv")"; rc=$?
  st_assert "UNVERIFIABLE routes the work to the checker" 1 "$rc" "scripts/check-port-canon.sh: implement" "$out"
  st_refute "UNVERIFIABLE does not tell a port to update a check it does not have" "alpha: update the fence-nesting property check" "$out"

  # --- the first-run framing, so a red first report is not read as a bug
  out="$(st_run "$tmp/k.md" "$tmp/m")"; rc=$?
  st_assert "an all-missing run explains that this is the expected first-run state" 1 "$rc" "expected first-run state" "$out"

  # --- a property ok must say what it walked
  st_canon "$tmp/pv.md" 1 required 1 property fence-nesting
  mkdir -p "$tmp/pv/alpha" "$tmp/pv/beta"
  printf '# t\n\n%sbash\necho hi\n%s\n' "$f3" "$f3" > "$tmp/pv/alpha/good.md"
  printf '# t\n\n%sbash\necho hi\n%s\n' "$f3" "$f3" > "$tmp/pv/beta/good.md"
  out="$(st_run "$tmp/pv.md" "$tmp/pv")"; rc=$?
  st_assert "a property ok states how many files were walked" 0 "$rc" "property verified across" "$out"

  # --- record-forgery: a canon string carrying a tab or a newline could shift
  # --- a later field or forge a whole record. Both produced a false green.
  sed 's|"family": "f"|"family": "f\\t../decoy"|' "$tmp/k.md" > "$tmp/tab.md"
  mkdir -p "$tmp/tb/alpha" "$tmp/tb/beta" "$tmp/decoy"
  printf 'x\n' > "$tmp/tb/alpha/a.md"; printf 'x\n' > "$tmp/tb/beta/b.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/decoy/planted.md"
  out="$(st_run "$tmp/tab.md" "$tmp/tb")"; rc=$?
  st_assert "a tab in a canon string halts instead of shifting a field" 2 "$rc" "would forge a record boundary" "$out"
  st_refute "a shifted field never yields a false ok" "ok: rule-one" "$out"

  sed 's|"check_hint": "h"|"check_hint": "h\\nPORT\\t9\\tPHANTOM\\tf\\tphantom\\ttrue"|' "$tmp/k.md" > "$tmp/nl.md"
  out="$(st_run "$tmp/nl.md" "$tmp/k")"; rc=$?
  st_assert "a newline in a canon string cannot forge a record" 2 "$rc" "would forge a record boundary" "$out"
  st_refute "no phantom port is ever processed" "PHANTOM" "$out"

  # --- a filename that is a glob pattern must not be expanded away. The real
  # --- violation lived in a[1].md and a clean sibling a1.md replaced it.
  st_canon "$tmp/pg.md" 1 required 1 property fence-nesting
  mkdir -p "$tmp/pg/alpha" "$tmp/pg/beta"
  printf '# t\n\n%smarkdown\n## s\n\n%sjson\n{}\n%s\n\n%s\n' "$f3" "$f3" "$f3" "$f3" > "$tmp/pg/alpha/a[1].md"
  printf 'clean\n' > "$tmp/pg/alpha/a1.md"
  printf 'clean\n' > "$tmp/pg/beta/b.md"
  out="$(st_run "$tmp/pg.md" "$tmp/pg")"; rc=$?
  st_assert "a violation in a glob-shaped filename is still found" 1 "$rc" "DEFECT: fence-nesting" "$out"

  # --- an anchor id starting with a dash must not reach grep as an option
  mkdir -p "$tmp/dash/alpha" "$tmp/dash/beta"
  printf '<!-- canon:rule-one v1 -->\n<!-- canon:-Ifoo v1 -->\n' > "$tmp/dash/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/dash/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/dash" 2>&1)"; rc=$?
  st_refute "a leading-dash anchor id never reaches grep as an option" "No such file or directory" "$out"

  # --- an unreadable tree must be UNVERIFIABLE, never "property verified"
  if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$tmp/perm/alpha/locked" "$tmp/perm/beta"
    printf 'clean\n' > "$tmp/perm/beta/b.md"
    chmod 000 "$tmp/perm/alpha/locked"
    out="$(st_run "$tmp/pg.md" "$tmp/perm" | sed -n '/^alpha$/,/^$/p')"
    chmod 755 "$tmp/perm/alpha/locked"
    st_refute "an unreadable subtree is never reported as property verified" "ok: fence-nesting" "$out"
  else
    echo "ok: unreadable-subtree case skipped (running as root)"
    pass=$((pass + 1))
  fi

  # --- the dot segments pass a charset test but are not port directories, and
  # --- ".." walked the scan out of the ports parent entirely.
  sed 's|"dir": "alpha"|"dir": ".."|' "$tmp/k.md" > "$tmp/dd.md"
  out="$(st_run "$tmp/dd.md" "$tmp/k")"; rc=$?
  st_assert "a dir of .. is refused as a traversal" 2 "$rc" "directory traversal rather than a port directory" "$out"
  sed 's|"dir": "alpha"|"dir": "."|' "$tmp/k.md" > "$tmp/dot.md"
  out="$(st_run "$tmp/dot.md" "$tmp/k")"; rc=$?
  st_assert "a dir of . is refused as a traversal" 2 "$rc" "directory traversal rather than a port directory" "$out"

  # --- an entry id reaches grep as a pattern, so it must carry no regex
  # --- metacharacters. A crafted one resolved a lookup to a DIFFERENT entry.
  sed 's|"id": "rule-one"|"id": "a\\\\.c"|' "$tmp/k.md" > "$tmp/rid.md"
  out="$(st_run "$tmp/rid.md" "$tmp/k")"; rc=$?
  st_assert "an entry id outside the anchor charset is refused" 2 "$rc" "outside the anchor charset" "$out"

  # --- a filename containing the old sed delimiter silently dropped its anchor
  mkdir -p "$tmp/pipe/alpha" "$tmp/pipe/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/pipe/alpha/ok.md"
  printf '<!-- canon:ghost-rule v1 -->\n' > "$tmp/pipe/alpha/a|b.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/pipe/beta/b.md"
  out="$(st_run "$tmp/k.md" "$tmp/pipe")"; rc=$?
  st_assert "an anchor in a filename containing a pipe is still seen" 1 "$rc" 'no rule "ghost-rule"' "$out"

  # --- an unreadable subtree must make the ANCHOR pass unverifiable too, not
  # --- only the property pass: a short file list hides UNEXPECTED anchors.
  if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$tmp/aperm/alpha/locked" "$tmp/aperm/beta"
    printf '<!-- canon:rule-one v1 -->\n' > "$tmp/aperm/alpha/a.md"
    printf '<!-- canon:rule-one v1 -->\n' > "$tmp/aperm/beta/b.md"
    printf '<!-- canon:ghost v1 -->\n' > "$tmp/aperm/alpha/locked/hidden.md"
    chmod 000 "$tmp/aperm/alpha/locked"
    out="$(st_run "$tmp/k.md" "$tmp/aperm" 2>/dev/null)"; rc=$?
    chmod 755 "$tmp/aperm/alpha/locked"
    st_assert "an unreadable subtree makes the anchor pass UNVERIFIABLE" 1 "$rc" "refusing to judge anchors on a partial file list" "$out"
    st_refute "a partially-enumerated port is never reported clean" "verdict: clean" \
      "$(echo "$out" | sed -n '/^alpha$/,/^$/p')"
  else
    echo "ok: unreadable-anchor-tree case skipped (running as root)"
    pass=$((pass + 1)); pass=$((pass + 1))
  fi

  # --- the filename channel. A newline-delimited file list cannot represent a
  # --- filename containing a newline: the tail became a CWD-relative path and
  # --- the gate read a file outside the scanned tree, attributing it to a port.
  mkdir -p "$tmp/nlfn/alpha" "$tmp/nlfn/beta" "$tmp/nlcwd"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/nlfn/beta/b.md"
  printf '<!-- canon:ghost-from-cwd v1 -->\n' > "$tmp/nlcwd/planted.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/nlfn/alpha/a
planted.md"
  out="$(cd "$tmp/nlcwd" && bash "$SELF" --canon "$tmp/k.md" --ports-parent "$tmp/nlfn" 2>/dev/null)"; rc=$?
  st_assert "a newline-named file makes the tree UNVERIFIABLE" 1 "$rc" "refusing to judge anchors on a partial file list" "$out"
  st_refute "no file outside the ports parent is attributed to a port" "ghost-from-cwd" "$out"

  # --- awk -v applies POSIX escape processing to its assignment, so a literal
  # --- backslash-n in a filename became a real newline and forged a record.
  mkdir -p "$tmp/forge/alpha" "$tmp/forge/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/forge/beta/b.md"
  printf '<!-- canon:other v1 -->\n' > "$tmp/forge/alpha/q\\nrule-one\\t1\\tzz.md"
  out="$(st_run "$tmp/k.md" "$tmp/forge")"; rc=$?
  st_assert "a filename cannot forge an anchor record" 1 "$rc" "MISSING: rule-one v1" "$out"
  st_refute "a forged path never yields an ok cell" "ok: rule-one v1 at zz.md" "$out"

  # --- awkward but REPRESENTABLE names must still be scanned, not refused:
  # --- the refusal is about tabs and newlines, not about odd characters.
  mkdir -p "$tmp/odd/alpha" "$tmp/odd/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/odd/alpha/-e.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/odd/beta/a b\$(id)[1]*.md"
  out="$(st_run "$tmp/k.md" "$tmp/odd")"; rc=$?
  st_assert "odd but representable filenames are scanned, not refused" 0 "$rc" "ok: rule-one v1 at -e.md" "$out"

  # --- the enumeration is ONE walk. The previous guard compared two separate
  # --- find walks, so removing a file between them cancelled the difference
  # --- and let a newline-named file through -- a TOCTOU on a mutable tree.
  mkdir -p "$tmp/race/alpha" "$tmp/race/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/race/beta/b.md"
  printf 'x\n' > "$tmp/race/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/racesecret.md"
  printf 'x\n' > "$tmp/race/alpha/z
../racesecret.md"
  race_false=0
  for _i in 1 2 3 4 5 6 7 8; do
    ( for _j in 1 2 3 4 5 6 7 8 9 10; do
        printf 'x\n' > "$tmp/race/alpha/churn.md" 2>/dev/null
        rm -f "$tmp/race/alpha/churn.md" 2>/dev/null
      done ) &
    if (cd "$tmp" && bash "$SELF" --canon "$tmp/k.md" --ports-parent "$tmp/race" 2>/dev/null) \
       | grep -q 'ok: rule-one v1 at racesecret.md'; then
      race_false=$((race_false + 1))
    fi
    wait
  done
  if [ "$race_false" -eq 0 ]; then
    pass=$((pass + 1)); echo "ok: a mutating tree cannot slip a newline-named file past the guard"
  else
    fail=$((fail + 1)); echo "SELF-TEST FAILED: a mutating tree slipped a newline-named file past the guard ($race_false/8 runs read outside the tree)"
  fi

  # --- ROUND 5 (W2108). One root shape behind all of these: find SUCCEEDING
  # --- was read as "the tree was examined", so every read failure BELOW find
  # --- -- an unreadable file, a grep error, a binary skip, a symlink, an
  # --- empty walk -- collapsed into the same empty output a clean file
  # --- produces. Rounds 1-4 closed that at the directory granularity (find's
  # --- exit status) and at the path-representability granularity (the NUL
  # --- walk). The file granularity was the layer left open.

  # --- a port owing NOTHING still owes an UNEXPECTED sweep, so an
  # --- unenumerable tree must refuse even when no entry is required. The
  # --- per-required-entry filter recorded nothing at all, and record() is the
  # --- only writer of STATUS: the run printed NOT FULLY EXAMINED and exited 0.
  if [ "$(id -u)" -ne 0 ]; then
    st_canon "$tmp/na.md" 1 not_applicable
    mkdir -p "$tmp/nax/alpha" "$tmp/nax/beta/locked"
    printf '<!-- canon:rule-one v1 -->\n' > "$tmp/nax/alpha/a.md"
    printf '<!-- canon:rule-one v1 -->\n' > "$tmp/nax/beta/locked/hidden.md"
    chmod 000 "$tmp/nax/beta/locked"
    out="$(st_run "$tmp/na.md" "$tmp/nax" 2>/dev/null)"; rc=$?
    chmod 755 "$tmp/nax/beta/locked"
    st_assert "an unenumerable port with no required rule still fails the gate" 1 "$rc" \
      "refusing to judge any cell on a partial file list" "$out"
    st_refute "an unenumerable port never exits clean for want of a required rule" "^clean repos:.*beta" "$out"
  else
    echo "ok: all-not_applicable unenumerable case skipped (running as root)"
    pass=$((pass + 1)); pass=$((pass + 1))
  fi

  # --- an unreadable FILE is not a clean file. fence_defect returned empty --
  # --- its "clean" value -- for a file it never opened, and the caller still
  # --- counted it into "property verified across N markdown files".
  if [ "$(id -u)" -ne 0 ]; then
    st_canon "$tmp/pu.md" 1 required 1 property fence-nesting
    mkdir -p "$tmp/pu/alpha" "$tmp/pu/beta"
    printf 'clean\n' > "$tmp/pu/beta/b.md"
    printf '# t\n\n%smarkdown\n## s\n\n%sjson\n{}\n%s\n\n%s\n' "$f3" "$f3" "$f3" "$f3" > "$tmp/pu/alpha/bad.md"
    chmod 000 "$tmp/pu/alpha/bad.md"
    out="$(st_run "$tmp/pu.md" "$tmp/pu" 2>/dev/null)"; rc=$?
    chmod 644 "$tmp/pu/alpha/bad.md"
    st_assert "an unreadable file is never counted as property verified" 1 "$rc" "UNVERIFIABLE" "$out"
    st_refute "an unreadable file never yields a property-verified cell" "ok: fence-nesting" \
      "$(echo "$out" | sed -n '/^alpha$/,/^$/p')"

    # --- the anchor pass, same granularity: grep exits 1 for "no match" AND
    # --- for a file it cannot read, so a NOT-owed anchor hid behind a chmod.
    mkdir -p "$tmp/au/alpha" "$tmp/au/beta"
    printf '<!-- canon:rule-one v1 -->\n' > "$tmp/au/alpha/a.md"
    printf '<!-- canon:rule-one v1 -->\n' > "$tmp/au/beta/b.md"
    printf '<!-- canon:ghost-rule v1 -->\n' > "$tmp/au/alpha/secret.md"
    chmod 000 "$tmp/au/alpha/secret.md"
    out="$(st_run "$tmp/k.md" "$tmp/au" 2>/dev/null)"; rc=$?
    chmod 644 "$tmp/au/alpha/secret.md"
    st_assert "an unreadable file makes the anchor pass UNVERIFIABLE" 1 "$rc" "partial file list" "$out"
    st_refute "an unreadable file never leaves a port reported clean" "clean repos:.*alpha" "$out"
  else
    echo "ok: unreadable-file cases skipped (running as root)"
    pass=$((pass + 1)); pass=$((pass + 1)); pass=$((pass + 1)); pass=$((pass + 1))
  fi

  # --- a file the scan declines is byte-identical, to the caller, to "this
  # --- file holds no anchors" -- exit 1, no stderr line. (Pre-D285 that
  # --- decline was grep -I's binary heuristic; it is now the byte-count
  # --- guard, which refuses the NUL-bearing fixture below on its own bytes.)
  mkdir -p "$tmp/bin/alpha" "$tmp/bin/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/bin/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/bin/beta/b.md"
  printf 'x\000x\n<!-- canon:ghost-rule v1 -->\n' > "$tmp/bin/alpha/binary.md"
  out="$(st_run "$tmp/k.md" "$tmp/bin" 2>/dev/null)"; rc=$?
  st_assert "a NUL-bearing .md is refused, not read as anchor-free" 1 "$rc" "partial file list" "$out"
  st_refute "a NUL-bearing .md never leaves a port reported clean" "clean repos:.*alpha" "$out"

  # --- a port checked out as a SYMLINK passed [ -d ] but was not descended by
  # --- find's default -P, so the walk was empty and the property cell passed.
  mkdir -p "$tmp/slreal" "$tmp/sl/beta"
  printf '# t\n\n%smarkdown\n## s\n\n%sjson\n{}\n%s\n\n%s\n' "$f3" "$f3" "$f3" "$f3" > "$tmp/slreal/bad.md"
  printf 'clean\n' > "$tmp/sl/beta/b.md"
  ln -s "$tmp/slreal" "$tmp/sl/alpha"
  out="$(st_run "$tmp/pg.md" "$tmp/sl")"; rc=$?
  st_assert "a symlinked port directory is still descended" 1 "$rc" "DEFECT: fence-nesting" "$out"
  st_refute "a symlinked port directory never passes on an empty walk" "across 0 markdown files" "$out"

  # --- a symlinked .md is not -type f, so it left the walk in silence; to a
  # --- reader it is markdown in the port. Refused rather than followed: the
  # --- target can resolve outside the tree.
  mkdir -p "$tmp/slf/alpha" "$tmp/slf/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/slf/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/slf/beta/b.md"
  printf '<!-- canon:ghost-rule v1 -->\n' > "$tmp/slf/alpha/note.txt"
  ln -s note.txt "$tmp/slf/alpha/linked.md"
  out="$(st_run "$tmp/k.md" "$tmp/slf" 2>/dev/null)"; rc=$?
  st_assert "a symlinked .md is refused, never silently skipped" 1 "$rc" "partial file list" "$out"
  st_refute "a symlinked .md never leaves a port reported clean" "clean repos:.*alpha" "$out"

  # --- a symlinked SUBDIRECTORY is the same gap one level down: -H resolves
  # --- only the start point, and a link met during descent is not descended.
  # --- It does not match -name '*.md', so filtering by name in find left it
  # --- in exactly the silence the file-level fix had just closed.
  mkdir -p "$tmp/sld/alpha" "$tmp/sld/beta" "$tmp/sldout"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/sld/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/sld/beta/b.md"
  printf '<!-- canon:ghost-rule v1 -->\n' > "$tmp/sldout/hidden.md"
  ln -s "$tmp/sldout" "$tmp/sld/alpha/docs"
  out="$(st_run "$tmp/k.md" "$tmp/sld" 2>/dev/null)"; rc=$?
  st_assert "a symlinked subdirectory is refused, never silently skipped" 1 "$rc" "partial file list" "$out"
  st_refute "a symlinked subdirectory never leaves a port reported clean" "clean repos:.*alpha" "$out"

  # --- a symlink that is neither a directory nor markdown hides nothing, so
  # --- the refusal must not fire on it: an over-broad guard would report
  # --- every port with an ordinary symlink as unexaminable.
  mkdir -p "$tmp/slh/alpha" "$tmp/slh/beta"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/slh/alpha/a.md"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/slh/beta/b.md"
  printf 'x\n' > "$tmp/slh/alpha/notes.txt"
  ln -s notes.txt "$tmp/slh/alpha/link.txt"
  out="$(st_run "$tmp/k.md" "$tmp/slh")"; rc=$?
  st_assert "a harmless non-markdown symlink does not make a port unexaminable" 0 "$rc" "ok: rule-one v1" "$out"

  # --- EVERY symlink case above must run under the PROPERTY canon too. The
  # --- property loop is a separate walk with its own guard, and running these
  # --- only under the anchor canon is precisely what let the two passes
  # --- disagree about one tree: the property loop refused every symlink and
  # --- turned an ordinary link.txt into UNVERIFIABLE over a clean port, with
  # --- the suite green because no case ever reached that branch.
  mkdir -p "$tmp/slhp/alpha" "$tmp/slhp/beta"
  printf 'clean\n' > "$tmp/slhp/alpha/a.md"
  printf 'clean\n' > "$tmp/slhp/beta/b.md"
  printf 'x\n' > "$tmp/slhp/alpha/notes.txt"
  ln -s notes.txt "$tmp/slhp/alpha/link.txt"
  out="$(st_run "$tmp/pg.md" "$tmp/slhp")"; rc=$?
  st_assert "a harmless symlink is exempt in the property pass too" 0 "$rc" "ok: fence-nesting" "$out"
  st_refute "a harmless symlink never yields a refusal in the property pass" "refusing to follow symlinked markdown" "$out"

  # --- the exempt symlink must be IGNORED, never read. Gating only the
  # --- refusal let it fall through to fence_defect, which follows the link:
  # --- a link to a file OUTSIDE the port tree was read and attributed to the
  # --- port, and it counted into nfiles, walking past the empty-walk refusal.
  # --- The fixture that missed it linked to an in-tree file that resolves.
  mkdir -p "$tmp/slout/alpha" "$tmp/slout/beta" "$tmp/slelsewhere"
  printf '# t\n\n%smarkdown\n## s\n\n%sjson\n{}\n%s\n\n%s\n' "$f3" "$f3" "$f3" "$f3" > "$tmp/slelsewhere/planted.txt"
  printf 'clean\n' > "$tmp/slout/beta/b.md"
  ln -s "$tmp/slelsewhere/planted.txt" "$tmp/slout/alpha/link.txt"
  out="$(st_run "$tmp/pg.md" "$tmp/slout" 2>/dev/null)"; rc=$?
  st_refute "a symlink out of the tree is never read by the property pass" "planted.txt" "$out"
  st_refute "an exempt symlink never counts toward the enumerated file total" "across 1 markdown files" \
    "$(echo "$out" | sed -n '/^alpha$/,/^$/p')"
  st_assert "a port whose only entry is an exempt symlink is unverifiable, not verified" 1 "$rc" \
    "refusing to report a property verified over an empty walk" "$out"

  # --- a DANGLING exempt symlink must be treated identically: scan_anchors
  # --- ignores it, so the property pass must too, or the two passes disagree
  # --- about one tree again -- fence_defect's [ -r ] would have called it
  # --- unreadable and refused the port.
  mkdir -p "$tmp/sldang/alpha" "$tmp/sldang/beta"
  printf 'clean\n' > "$tmp/sldang/alpha/a.md"
  printf 'clean\n' > "$tmp/sldang/beta/b.md"
  ln -s "$tmp/nonexistent-target" "$tmp/sldang/alpha/dangling.txt"
  out="$(st_run "$tmp/pg.md" "$tmp/sldang" 2>/dev/null)"; rc=$?
  st_assert "a dangling exempt symlink is ignored by both passes alike" 0 "$rc" "ok: fence-nesting" "$out"

  mkdir -p "$tmp/slp/alpha" "$tmp/slp/beta"
  printf 'clean\n' > "$tmp/slp/alpha/a.md"
  printf 'clean\n' > "$tmp/slp/beta/b.md"
  printf 'clean\n' > "$tmp/slp/alpha/real.txt"
  ln -s real.txt "$tmp/slp/alpha/linked.md"
  out="$(st_run "$tmp/pg.md" "$tmp/slp" 2>/dev/null)"; rc=$?
  st_assert "a symlinked .md is refused in the property pass" 1 "$rc" "UNVERIFIABLE" "$out"
  st_refute "a symlinked .md never yields a property-verified cell" "ok: fence-nesting" \
    "$(echo "$out" | sed -n '/^alpha$/,/^$/p')"

  # --- "verified across 0 markdown files" was still a pass. Disclosing the
  # --- empty enumeration is not the same as refusing to conclude from it.
  mkdir -p "$tmp/mt/alpha" "$tmp/mt/beta"
  printf 'clean\n' > "$tmp/mt/beta/b.md"
  out="$(st_run "$tmp/pg.md" "$tmp/mt")"; rc=$?
  st_assert "an empty enumeration is unverifiable, not verified" 1 "$rc" \
    "refusing to report a property verified over an empty walk" "$out"
  st_refute "an empty port directory never yields a property-verified cell" "across 0 markdown files" "$out"

  # --- the registry's exists:false and a row's status are two statements about
  # --- one port. The report layer read only the first and deferred EVERY rule
  # --- without looking at a row, so a half-applied canon edit exited 0 over a
  # --- port owing every rule.
  {
    echo "# canon"; echo "${f3}json"
    echo '{ "canon_schema_version": 1,'
    echo '  "ports": ['
    echo '    {"id": "alpha", "family": "f", "dir": "alpha", "exists": true, "note": ""},'
    echo '    {"id": "ghost", "family": "f", "dir": "ghost", "exists": false, "note": "n"}'
    echo '  ] }'; echo "${f3}"; echo "### r"; echo "<!-- canon:rule-one v1 -->"; echo "${f3}json"
    echo '{ "id": "rule-one", "version": 1, "status": "active", "superseded_by": null,'
    echo '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
    echo '  "applies_to": ['
    echo '    {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
    echo '    {"port": "ghost", "status": "required", "variant": "", "reason": "r"} ] }'
    echo "${f3}"
  } > "$tmp/xf.md"
  mkdir -p "$tmp/xf/alpha"
  printf '<!-- canon:rule-one v1 -->\n' > "$tmp/xf/alpha/a.md"
  out="$(st_run "$tmp/xf.md" "$tmp/xf")"; rc=$?
  st_assert "a port the registry says is absent cannot be required to carry a rule" 2 "$rc" \
    "can only defer a rule, never owe it" "$out"

  # --- a byte-exact "json" info-string test dropped a block that renders as
  # --- json to every human: the rule entry inside it ceased to exist for the
  # --- checker, taking its MISSING cells with it.
  sed 's|^'"$f3"'json$|'"$f3"'json |' "$tmp/k.md" > "$tmp/ws.md"
  out="$(st_run "$tmp/ws.md" "$tmp/m")"; rc=$?
  st_assert "a json fence with a trailing space is still parsed" 1 "$rc" "MISSING: rule-one v1" "$out"

  # --- the backstop for every OTHER way a block can go unclassified: the
  # --- canon's own anchor definition lines are counted against the entries
  # --- that reached the parser. A tilde fence is invisible to the backtick
  # --- walker entirely, so no info-string fix can catch it.
  cp "$tmp/k.md" "$tmp/tl.md"
  {
    echo "### r2"
    echo "<!-- canon:rule-two v1 -->"
    echo "~~~json"
    echo '{ "id": "rule-two", "version": 1, "status": "active", "superseded_by": null,'
    echo '  "provenance": "quoted", "defects": ["D1"], "check": "anchor", "check_hint": "h",'
    echo '  "applies_to": ['
    echo '    {"port": "alpha", "status": "required", "variant": "", "reason": ""},'
    echo '    {"port": "beta", "status": "required", "variant": "", "reason": "r"} ] }'
    echo "~~~"
  } >> "$tmp/tl.md"
  out="$(st_run "$tmp/tl.md" "$tmp/m" 2>&1)"; rc=$?
  st_assert "an entry that never reached the parser is caught by the anchor count" 2 "$rc" \
    "did not reach this parser" "$out"

  # --- D285 finding 3: readable-as-text must not depend on grep's heuristic
  #
  # The point of this case is that it does NOT depend on which grep happens to
  # be on PATH. Asserting against the ambient grep would prove nothing here,
  # because /usr/bin/grep -I already scans the fixture correctly -- the bug was
  # only ever reachable through a grep whose binary heuristic is broader. So
  # the case SUPPLIES that grep: a stub that refuses any file carrying a byte
  # outside printable ASCII whenever -I is requested, and delegates otherwise.
  # That is the whole property under test -- the scan must not ask grep to
  # decide readable-as-text -- rather than a statement about this machine.
  #
  # Pre-fix (grep -EIno) the stub fires, the file is skipped, the not-owed
  # anchor in it is never seen, and beta reports na: a false green. Post-fix
  # (grep -Eano) no -I is requested, the stub delegates, and the anchor is
  # seen and reported UNEXPECTED. The fixture is NUL-free by construction, so
  # the byte-count guard above lets it through to grep in both cases -- this
  # case tests the grep axis alone, not the NUL guard.
  mkdir -p "$tmp/f3/beta" "$tmp/f3/alpha" "$tmp/f3bin"
  {
    printf '# beta\n'
    printf 'a \377 byte, no NUL\n'
    printf '<!-- canon:rule-one v1 -->\n'
  } > "$tmp/f3/beta/notes.md"
  # A grep whose binary heuristic is broader than "contains a NUL".
  {
    echo '#!/bin/sh'
    echo 'for _a in "$@"; do'
    echo '  case "$_a" in'
    echo '    -*I*)'
    echo '      for _last in "$@"; do :; done'
    echo '      if [ -f "$_last" ] && LC_ALL=C /usr/bin/grep -q "[^[:print:][:space:]]" "$_last" 2>/dev/null; then'
    echo '        exit 1'
    echo '      fi'
    echo '      ;;'
    echo '  esac'
    echo 'done'
    echo 'exec /usr/bin/grep "$@"'
  } > "$tmp/f3bin/grep"
  chmod +x "$tmp/f3bin/grep"
  # beta is not_applicable for rule-one, so an anchor found there is UNEXPECTED.
  st_canon "$tmp/f3-canon.md" 1 not_applicable 1 anchor rule-one
  out="$(PATH="$tmp/f3bin:$PATH" bash "$SELF" --canon "$tmp/f3-canon.md" --ports-parent "$tmp/f3" 2>&1)"; rc=$?
  st_assert "a broader-heuristic grep cannot hide an anchor from the scan (D285 finding 3)" \
    1 "$rc" "UNEXPECTED" "$out"
  st_refute "a NUL-free non-ASCII file is not silently skipped (D285 finding 3)" \
    "verdict: clean" "$out"

  # --- D285 r2: the LOCALE axis, which nothing covered until this case
  #
  # The suite covered the NUL axis and (above) the grep-IMPLEMENTATION axis,
  # and covered the LOCALE axis nowhere -- so LC_ALL=C on the scan could be
  # deleted and the suite would still report every case passing, while a port
  # carrying an anchor it does not owe went back to reporting clean. An
  # exploratory session demonstrated exactly that. This case closes it.
  #
  # The fixture puts an invalid multibyte byte on the SAME LINE as a not-owed
  # anchor. Under a UTF-8 locale that makes the MATCH fail -- no binary
  # heuristic is involved -- so grep exits 1 and the anchor is never seen.
  # Putting the byte on its own line does not reproduce it, which is why the
  # fixture above (whose 0xFF is on a separate line) does not cover this.
  #
  # The case runs the scan with a UTF-8 locale EXPORTED into its environment.
  # That is the whole point: it proves the scan's own LC_ALL=C prefix wins
  # over a hostile ambient locale. Remove that prefix from the scan and this
  # case fails; keep it and the locale below cannot reach the match.
  mkdir -p "$tmp/loc/beta" "$tmp/loc/alpha"
  printf 'x \377 <!-- canon:rule-one v1 -->\n' > "$tmp/loc/beta/notes.md"
  st_canon "$tmp/loc-canon.md" 1 not_applicable 1 anchor rule-one
  out="$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 bash "$SELF" \
          --canon "$tmp/loc-canon.md" --ports-parent "$tmp/loc" 2>&1)"; rc=$?
  st_assert "an invalid multibyte sequence on the anchor's line cannot hide it" \
    1 "$rc" "UNEXPECTED" "$out"
  st_refute "a hostile ambient locale cannot make a not-owed anchor read clean" \
    "verdict: clean" "$out"

  # --- CLI surface
  out="$(bash "$SELF" --help 2>&1)"; rc=$?
  st_assert "--help exits 0 and documents the flags" 0 "$rc" "ports-parent" "$out"
  out="$(bash "$SELF" --bogus 2>&1)"; rc=$?
  st_assert "an unknown option exits 2" 2 "$rc" "unknown option" "$out"
  out="$(bash "$SELF" --canon /nonexistent/nope.md 2>&1)"; rc=$?
  st_assert "an unreadable canon exits 2" 2 "$rc" "canon not readable" "$out"
  out="$(bash "$SELF" --ports-parent /nonexistent/nope 2>&1)"; rc=$?
  st_assert "a missing ports parent exits 2" 2 "$rc" "ports parent directory not found" "$out"

  echo ""
  echo "self-test: $pass passed, $fail failed"
  rm -rf "$tmp"
  trap - EXIT
  [ "$fail" -eq 0 ] || return 1
  return 0
}

# --self-test scans nothing real, so it runs before the canon is required.
# Combining it with --canon/--ports-parent reads naturally as "prove the gate
# AND scan this", but it never scans; silently discarding the paths would be
# the worse surprise. This mirrors the same guard in check-ps1-compat.sh.
if [ "$SELF_TEST" -eq 1 ]; then
  if [ "$CANON_SET" -eq 1 ] || [ "$PORTS_SET" -eq 1 ]; then
    echo "GATE ERROR: --self-test does not scan; drop --canon/--ports-parent, or run the two separately:" >&2
    echo "  bash scripts/check-port-canon.sh --self-test" >&2
    echo "  bash scripts/check-port-canon.sh --canon ... --ports-parent ..." >&2
    exit 2
  fi
  if self_test; then exit 0; else exit 1; fi
fi

# Normalize both paths to absolute BEFORE anything compares them. The canon
# self-exclusion below matches find's output against $CANON, and find always
# emits absolute paths: a relative --canon would never match, the canon would
# be scanned, and the port it lives in would report ok on every anchor off the
# definition site -- the exact false green the exclusion exists to prevent.
if [ -e "$CANON" ]; then
  CANON="$(cd "$(dirname "$CANON")" 2>/dev/null && pwd)/$(basename "$CANON")"
fi
if [ -d "$PORTS_PARENT" ]; then
  PORTS_PARENT="$(cd "$PORTS_PARENT" && pwd)"
fi

if [ ! -r "$CANON" ]; then
  echo "GATE ERROR: canon not readable at $CANON" >&2
  exit 2
fi
if [ ! -d "$PORTS_PARENT" ]; then
  echo "GATE ERROR: ports parent directory not found: $PORTS_PARENT" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Canon parser.
#
# Blocks are classified by their own discriminator key -- canon_schema_version
# for the registry, id for a rule entry -- never by position, which is what the
# canon requires of a consumer. A json fence matching neither shape halts the
# run; absorbing it silently would make it a phantom entry and shift the index
# of every block after it. This accepts exactly the closed schema, nothing more.
#
# The program is emitted by a function rather than assigned from a heredoc
# inside $(...): bash 3.2, which is /bin/bash on macOS, cannot parse a heredoc
# nested in a command substitution.
# --------------------------------------------------------------------------

parse_awk_prog() {
cat <<'AWKPROG'
BEGIN {
  SUPPORTED_SCHEMA = 1
  split("id version status superseded_by provenance defects check check_hint applies_to", KEY, " ")
  NKEYS = 9
  VARIANT[""] = 1; VARIANT["four-section-keys"] = 1
  VARIANT["five-section-keys"] = 1; VARIANT["lib-matrix"] = 1
}
# Canon parser. Reads port-canon.md, emits a tab-separated record stream.
#
# Records:
#   SCHEMA <version>
#   PORT   <idx> <id> <family> <dir> <exists>
#   ENTRY  <idx> <id> <version> <status> <provenance> <check>
#   HINT   <entry-id> <check_hint>
#   APPLY  <entry-id> <port-idx> <port-id> <status> <variant>
#   ERR    <message>
#
# This is NOT a general JSON parser. It accepts exactly the canon's closed
# schema and halts on anything else, which is what the canon asks a consumer
# to do rather than parse optimistically.

function fail(msg) { printf "ERR\t%s\n", msg; exit_code = 2; exit 2 }

# Every value that reaches a record MUST be free of the record separators.
# The tokenizer turns the JSON escapes \t and \n into real tabs and newlines,
# so without this a canon string carrying a tab shifts every later field in its
# record -- and one carrying a newline forges an entire synthetic record. Both
# were demonstrated to produce a canon-controlled FALSE GREEN: a tab in
# "family" shifted the PORT record so the shell read a dir the dir-validator
# never saw, and the gate reported ok and exited 0 over ports holding no
# anchor at all. Halting here is the same disposition the dir check takes --
# refuse, never sanitize.
function safe(v, what) {
  if (v ~ /[\t\n]/)
    fail("the value of \"" what "\" contains a tab or newline, which would forge a record boundary; canon string values must contain neither")
  return v
}

# --- tokenizer -------------------------------------------------------------
function tok_init(s) { buf = s; pos = 1; tlen = length(s) }
function skipws(c) {
  while (pos <= tlen) { c = substr(buf, pos, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++; else break }
}
function nexttok(   c, start, out, esc, u) {
  skipws()
  if (pos > tlen) return "EOF"
  c = substr(buf, pos, 1)
  if (c == "{" || c == "}" || c == "[" || c == "]" || c == ":" || c == ",") { pos++; tval = c; return c }
  if (c == "\"") {
    pos++; out = ""
    while (pos <= tlen) {
      c = substr(buf, pos, 1)
      if (c == "\\") {
        esc = substr(buf, pos + 1, 1); pos += 2
        if (esc == "n") out = out "\n"
        else if (esc == "t") out = out "\t"
        else if (esc == "u") { pos += 4; out = out "?" }
        else out = out esc
        continue
      }
      if (c == "\"") { pos++; tval = out; return "STR" }
      out = out c; pos++
    }
    fail("unterminated string in json block #" blocknum " (line " blockline ")")
  }
  start = pos
  while (pos <= tlen) {
    c = substr(buf, pos, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r") break
    pos++
  }
  tval = substr(buf, start, pos - start)
  if (tval == "true" || tval == "false" || tval == "null") return "LIT"
  if (tval ~ /^-?[0-9]+(\.[0-9]+)?$/) return "NUM"
  fail("bad token \"" tval "\" in json block #" blocknum " (line " blockline ")")
}

# --- recursive-descent value reader; flattens into V[path] -----------------
function readval(path,   t, k, i, kt) {
  t = nexttok()
  if (t == "{") {
    if ((kt = nexttok()) == "}") return
    do {
      if (kt != "STR") fail("expected object key in json block #" blocknum " (line " blockline ")")
      k = tval
      if (nexttok() != ":") fail("expected ':' after key \"" k "\" in json block #" blocknum)
      readval(path == "" ? k : path "." k)
      t = nexttok()
      if (t == "}") return
      if (t != ",") fail("expected ',' or '}' in json block #" blocknum " (line " blockline ")")
      kt = nexttok()
    } while (1)
  }
  if (t == "[") {
    i = 0
    skipws()
    if (substr(buf, pos, 1) == "]") { pos++; V[path ".__len"] = 0; return }
    do {
      readval(path "." i); i++
      t = nexttok()
      if (t == "]") { V[path ".__len"] = i; return }
      if (t != ",") fail("expected ',' or ']' in json block #" blocknum " (line " blockline ")")
    } while (1)
  }
  if (t == "STR" || t == "NUM" || t == "LIT") { V[path] = tval; return }
  fail("unexpected token in json block #" blocknum " (line " blockline ")")
}

# --- fence walk: isolate top-level ```json blocks --------------------------
BEGIN { infence = 0; injson = 0; blocknum = 0; nports = 0; nentries = 0 }

{
  line = $0
  sub(/^[ \t]+/, "", line)
  if (line ~ /^```/) {
    run = 0; rest = line
    while (substr(rest, 1, 1) == "`") { rest = substr(rest, 2); run++ }
    if (infence == 0) {
      infence = 1; fencelen = run
      # The info string is compared after trailing whitespace and CR are
      # trimmed. A byte-exact "json" test made ```json-with-a-trailing-space,
      # and every line of a CRLF-checked-out canon, open an ORDINARY fence:
      # the block was never classified, so the rule entry inside it simply did
      # not exist for this checker while rendering normally for every human
      # and every markdown renderer. Its cells were never emitted, so a fleet
      # carrying no anchor for that rule reported clean. Halting on a
      # malformed block is the documented disposition; silently dropping one
      # is the opposite of it.
      info = rest
      sub(/[ \t\r]+$/, "", info)
      if (info == "json") { injson = 1; blocknum++; blockline = NR; blob = "" }
      next
    } else if (run >= fencelen && rest ~ /^[ \t]*$/) {
      if (injson) { classify() ; injson = 0 }
      infence = 0; fencelen = 0
      next
    }
  }
  if (injson) blob = blob $0 "\n"
  # Count the canon's own anchor DEFINITION lines, outside any fence. The
  # canon states the invariant in prose -- one anchor comment per entry -- and
  # the END block below now enforces it. This is the backstop for every way a
  # block can go unclassified rather than halt: a tilde fence (this walker
  # only tracks backticks), an unrecognised info string, or any future
  # variation. A vanished entry is invisible by construction -- no cells, no
  # MISSING rows, nothing to notice -- so it needs a check that counts what
  # the DOCUMENT says rather than what the parser happened to consume.
  #
  # Two consequences, both deliberate and neither obvious. It compares COUNTS,
  # not identities, so two errors that cancel leave it silent: a canon that
  # loses one entry to a tilde fence WHILE carrying one stray anchor-shaped
  # line elsewhere yields ndefs == nentries and passes. And in the other
  # direction, any anchor-shaped line the canon's prose ever quotes -- an
  # example in "Changing this file", say -- is now a hard exit 2. The second
  # is the safe failure and the first is the residual gap; closing it means
  # matching definition ids against parsed entry ids rather than counting.
  if (infence == 0 && $0 ~ /<!--[ \t]*canon:[A-Za-z0-9][A-Za-z0-9_-]*[ \t]+v[0-9]+[ \t]*-->/) ndefs++
}

# --- classify a block by its own discriminator, never by position ----------
function classify(   i, j, n, pid, eid, alen) {
  split("", V)
  tok_init(blob)
  readval("")
  if (nexttok() != "EOF") fail("trailing content after json block #" blocknum " (line " blockline ")")

  if ("canon_schema_version" in V) {
    if (blocknum != 1) fail("registry block found at position " blocknum "; the registry must be the first json block")
    if (V["canon_schema_version"] != SUPPORTED_SCHEMA)
      fail("canon_schema_version " V["canon_schema_version"] " is not the schema this checker understands (" SUPPORTED_SCHEMA "); refusing to parse optimistically")
    printf "SCHEMA\t%s\n", V["canon_schema_version"]
    n = V["ports.__len"] + 0
    if (n == 0) fail("registry carries no ports")
    for (i = 0; i < n; i++) {
      pid = V["ports." i ".id"]
      if (pid == "") fail("registry port " i " has no id")
      if (V["ports." i ".dir"] !~ /^[A-Za-z0-9._-]+$/)
        fail("registry port \"" pid "\" has dir \"" V["ports." i ".dir"] "\" which is not a single path segment matching ^[A-Za-z0-9._-]+$")
      # "." and ".." consist entirely of allowed characters, so the charset
      # test above admits them -- and ".." walks the scan out of the ports
      # parent entirely. Neither names a port, so both are refused here.
      if (V["ports." i ".dir"] == "." || V["ports." i ".dir"] == "..")
        fail("registry port \"" pid "\" has dir \"" V["ports." i ".dir"] "\", which is a directory traversal rather than a port directory")
      PORTID[i] = pid
      PORTEXISTS[i] = V["ports." i ".exists"]
      printf "PORT\t%d\t%s\t%s\t%s\t%s\n", i, safe(pid, "port id"), \
        safe(V["ports." i ".family"], "port family"), safe(V["ports." i ".dir"], "port dir"), \
        safe(V["ports." i ".exists"], "port exists")
    }
    nports = n
    return
  }

  if ("id" in V) {
    if (blocknum == 1) fail("first json block carries an id but no canon_schema_version; the registry must come first")
    eid = V["id"]
    # An id is interpolated into grep patterns and must not carry regex
    # metacharacters. This is the same charset the anchor scanner matches, so
    # an id outside it could never appear in a real anchor anyway -- a crafted
    # one resolved a lookup to a DIFFERENT entry's applies_to row and produced
    # a clean verdict over ports that owed the rule.
    if (eid !~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/)
      fail("entry id \"" eid "\" is outside the anchor charset ^[A-Za-z0-9][A-Za-z0-9_-]*$; an id that cannot appear in an anchor is meaningless to the canon")
    for (i = 1; i <= NKEYS; i++)
      if (!(KEY[i] in V) && !(KEY[i] ".__len" in V))
        fail("entry \"" eid "\" is missing required key \"" KEY[i] "\"")
    if (V["status"] != "active" && V["status"] != "superseded")
      fail("entry \"" eid "\" has status \"" V["status"] "\" outside the closed vocabulary active|superseded")
    if (V["provenance"] != "quoted" && V["provenance"] != "synthesized-from-shipped-fixes")
      fail("entry \"" eid "\" has provenance \"" V["provenance"] "\" outside its closed vocabulary")
    if (V["check"] != "anchor" && V["check"] != "property")
      fail("entry \"" eid "\" has check \"" V["check"] "\" outside the closed vocabulary anchor|property")
    if (V["version"] !~ /^[0-9]+$/) fail("entry \"" eid "\" has non-integer version \"" V["version"] "\"")
    if ((V["defects.__len"] + 0) == 0) fail("entry \"" eid "\" has an empty defects array")
    nentries++
    printf "ENTRY\t%d\t%s\t%s\t%s\t%s\t%s\n", nentries, safe(eid, "entry id"), \
      safe(V["version"], "entry version"), V["status"], V["provenance"], V["check"]
    printf "HINT\t%s\t%s\n", safe(eid, "entry id"), safe(V["check_hint"], "check_hint")
    alen = V["applies_to.__len"] + 0
    if (alen != nports)
      fail("entry \"" eid "\" lists " alen " applies_to rows but the registry has " nports " ports; every entry must list all ports in registry order")
    for (i = 0; i < alen; i++) {
      if (V["applies_to." i ".port"] != PORTID[i])
        fail("entry \"" eid "\" applies_to row " i " names port \"" V["applies_to." i ".port"] "\" but registry position " i " is \"" PORTID[i] "\"; rows must follow registry order")
      j = V["applies_to." i ".status"]
      if (j != "required" && j != "not_applicable" && j != "deferred")
        fail("entry \"" eid "\" row \"" PORTID[i] "\" has status \"" j "\" outside the closed vocabulary required|not_applicable|deferred")
      if (!(V["applies_to." i ".variant"] in VARIANT))
        fail("entry \"" eid "\" row \"" PORTID[i] "\" has variant \"" V["applies_to." i ".variant"] "\" outside the canon's declared vocabulary")
      # The registry's "exists" and the row's status are two statements about
      # the same port, and the report layer trusted only the first: a port with
      # exists:false took the "not scaffolded" branch, which records EVERY
      # entry as deferred without reading a single row. A canon edit that
      # flipped rows to required but left exists:false -- the half-applied
      # shape the canon's own "Changing this file" section warns about --
      # therefore reported "nothing owed yet" and exited 0 over a port owing
      # every rule and never examined. Every other canon inconsistency here
      # halts; this one resolved toward green, so it halts too.
      if (PORTEXISTS[i] == "false" && j != "deferred")
        fail("entry \"" eid "\" row \"" PORTID[i] "\" has status \"" j "\" but the registry says that port does not exist; " \
             "a port that is not scaffolded can only defer a rule, never owe it")
      printf "APPLY\t%s\t%d\t%s\t%s\t%s\n", safe(eid, "entry id"), i, safe(PORTID[i], "port id"), \
        j, safe(V["applies_to." i ".variant"], "variant")
    }
    return
  }
  fail("json block #" blocknum " (line " blockline ") matches neither the registry shape (canon_schema_version) nor an entry shape (id)")
}

END {
  if (exit_code == 2) exit 2
  if (infence == 1) fail("unclosed fence at end of canon")
  if (nports == 0) fail("no registry block found in the canon")
  if (nentries == 0) fail("no rule entries found in the canon")
  if (ndefs != nentries)
    fail("the canon carries " ndefs " anchor definition line(s) but " nentries \
         " parsed rule entr(y/ies); a block the document defines did not reach this parser " \
         "(an unrecognised info string or a tilde fence will do it), and an entry that " \
         "silently vanishes produces no cells and no findings")
}
AWKPROG
}

RECORDS="$(awk "$(parse_awk_prog)" "$CANON")" || {
  echo "$RECORDS" | sed -n 's/^ERR\t/GATE ERROR: /p' >&2
  echo "GATE ERROR: canon did not parse; no verdict is possible" >&2
  exit 2
}

# --------------------------------------------------------------------------
# The property check. Lifted verbatim from stride-lite/test/smoke.sh, which
# the canon's fence-nesting entry names as its reference implementation --
# that walker is what defect D217 shipped, and rewriting it would reproduce
# the tilde blindness it exists to prevent.
# --------------------------------------------------------------------------
fence_defect() {
  local file="$1" line stripped rest run fchar
  local open=0 open_len=0 open_line=0 open_char="" lineno=0
  # An empty return means CLEAN, so "I could not open this file" must not use
  # it. It did: an unreadable file returned 0 with no output, the caller
  # counted it into nfiles, found no hits, and printed "property verified
  # across N markdown files" -- naming a count that included a file nobody
  # read. chmod 000 on a file holding a real D217 violation flipped exit 1 to
  # exit 0. Prior rounds closed this at the DIRECTORY granularity, via find's
  # exit status; this is the same defect one level down.
  [ -r "$file" ] || { printf 'unreadable'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      '```'*) fchar='`' ;;
      '~~~'*) fchar='~' ;;
      *) continue ;;
    esac
    rest="$stripped"
    run=0
    while [ "${rest#"$fchar"}" != "$rest" ]; do
      rest="${rest#"$fchar"}"
      run=$((run + 1))
    done
    if [ "$open" -eq 0 ]; then
      if [ "$fchar" = '`' ]; then
        case "$rest" in
          *'`'*) continue ;;
        esac
      fi
      open=1; open_len="$run"; open_line="$lineno"; open_char="$fchar"
    elif [ "$fchar" = "$open_char" ]; then
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [ -z "$rest" ] && [ "$run" -ge "$open_len" ]; then
        open=0; open_len=0; open_line=0; open_char=""
      elif [ -n "$rest" ] && [ "$run" -eq "$open_len" ]; then
        # Same character, same width, carrying an info string, inside an open
        # block. This OVER-approximates deliberately: the line may be an inner
        # opener whose closer ends the outer block (the D217 defect), or it may
        # be literal text that happens to look like one. The two are
        # structurally identical, so no walk can tell them apart -- and the
        # remedy is the same either way, because showing a fence opener
        # literally also requires widening the fence around it. Reporting both
        # is correct. Do NOT "fix" this as a false positive; see the same note
        # on the reference implementation in stride-lite/test/smoke.sh.
        printf 'nested:%s' "$lineno"
        return 0
      fi
    fi
  done < "$file"
  [ "$open" -eq 1 ] && printf 'unclosed:%s' "$open_line"
  return 0
}

# Which property rules this checker can actually evaluate, and at which
# version. A property entry has no anchor, so it cannot report STALE by
# comparing versions in a port -- its version binds the CHECK instead. If the
# canon's entry is ahead of what is implemented here, the honest answer is
# UNVERIFIABLE, never a pass on logic that no longer matches the rule.
PROPERTY_IMPL="fence-nesting:1"

property_impl_version() {
  case "$PROPERTY_IMPL" in
    *"$1:"*) echo "$PROPERTY_IMPL" | tr ' ' '\n' | sed -n "s/^$1://p" ;;
    *) echo "" ;;
  esac
}

# Markdown files of a port, excluding vendored trees. The node_modules
# exclusion is load-bearing rather than cosmetic: stride-opencode carries
# 36 MB of node_modules holding 9 .md files that belong to its dependencies,
# not to the port.
port_md_files_nul() {
  # ONE walk, NUL-delimited, with find's exit status appended as a final
  # record. Three things follow, and each closes a defect this script has
  # already had:
  #
  #  * NUL is the only delimiter a filename cannot contain, so a name holding
  #    a newline is carried intact instead of splitting into two words whose
  #    tail grep resolves against the process CWD -- reading outside the tree.
  #  * One walk cannot disagree with itself. The previous guard compared a
  #    NUL-counted walk against a line-counted one, so deleting an unrelated
  #    file between them made the counts coincide and let a newline-named file
  #    through: a time-of-check/time-of-use race on a mutable tree.
  #  * find's status survives, so an unreadable subtree still routes to
  #    UNVERIFIABLE rather than reading as a clean short list.
  #  * -H resolves the START POINT only. Without it a port checked out as a
  #    symlink (a worktree, a convenience alias) was stat'd as a directory by
  #    the [ -d ] gate, then not descended by find's default -P: the walk
  #    returned nothing, find exited 0, and the property check reported
  #    "verified across 0 markdown files" over a tree full of violations.
  #  * -type l is enumerated alongside -type f so a SYMLINKED .md cannot leave
  #    the walk silently. To find, a symlink is not a regular file; to every
  #    reader and renderer it is markdown in the port's tree. scan_anchors
  #    refuses the port when it sees one rather than following it, which keeps
  #    the read-outside-the-tree property this walk was built to protect.
  #    A symlinked DIRECTORY needs the same treatment and does not match
  #    -name '*.md', so it would leave the walk in the same silence: -H
  #    resolves the start point only, and a link met during descent is not
  #    descended. Every symlink is therefore printed and the shell decides;
  #    filtering here by name would reintroduce the gap one level down.
  find -H "$1" \( \( -type f -name '*.md' \) -o -type l \) \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/deps/*' \
    -not -path '*/_build/*' -print0
  printf '%s\0' "$?"
}

# Every anchor comment in a directory, as "id<TAB>version<TAB>relpath:line".
# One pass collects them ALL rather than looking for the ones expected: the
# UNEXPECTED verdict is about anchors nobody asked for, so a search that only
# looks for what it expects can never find them.
#
# EXCLUDE_CANON keeps the canon document itself out of the anchor pass. It is
# the definition site for all five anchors and it lives inside the "stride"
# port's own tree, so counting it would report that port compliant without a
# single port-side adoption.
# Returns 0 with the anchor stream on stdout; 1 when the tree could not be
# judged, for either of two distinct reasons that both mean "refuse":
#
#   * find failed -- an unreadable subtree yields a SHORT list, and a short
#     list is fatal specifically for the UNEXPECTED sweep, which can only fire
#     on anchors it actually sees. MISSING fails safe under a short list;
#     UNEXPECTED does not.
#   * a path cannot be represented in this stream. Records are newline
#     separated and tab delimited, so a path containing either would forge a
#     record -- the same class safe() refuses on the canon side. NUL-walking
#     carries such a name intact this far, which is what makes the refusal
#     honest rather than a silent skip.
#
# Process substitution keeps the loop in the CURRENT shell: a pipeline would
# run it in a subshell and discard both flags. The final record is find's exit
# status, held back one iteration rather than pattern-matched, so no file can
# impersonate the sentinel by being named like one.
scan_anchors() {
  local dir="$1" f prev="" have_prev=0 st="" unrepresentable=0 unreadable=0 linked=0
  while IFS= read -r -d '' f; do
    if [ "$have_prev" -eq 1 ]; then
      case "${prev#$dir/}" in
        *$'\t'*|*$'\n'*)
          echo "GATE ERROR: a path under $dir contains a tab or newline and cannot be reported safely" >&2
          unrepresentable=1 ;;
        *)
          if [ -L "$prev" ] && [ ! -d "$prev" ] && [ "${prev%.md}" = "$prev" ]; then
            # A symlink that is neither a directory nor named *.md carries no
            # markdown into this port and hides nothing; ignoring it keeps the
            # refusal aimed at what can actually conceal an anchor.
            :
          elif [ -L "$prev" ]; then
            # Refused, never followed: the target can resolve outside the port
            # tree, and reading it would attribute another tree's content to
            # this port. Refusing is also what makes it visible -- silently
            # skipping it is how a not-owed anchor in a symlinked .md kept a
            # port clean.
            echo "GATE ERROR: ${prev#$dir/} under $dir is a symbolic link; this checker does not follow symlinked markdown" >&2
            linked=1
          elif [ "$prev" != "$EXCLUDE_CANON" ]; then
            emit_anchors "$prev" "$dir" || unreadable=1
          fi ;;
      esac
    fi
    prev="$f"; have_prev=1
  done < <(port_md_files_nul "$dir")
  st="$prev"
  [ "$st" = 0 ] || return 1
  [ "$unrepresentable" -eq 0 ] || return 1
  # A file the anchor pass could not read makes this list short by exactly the
  # anchors nobody can see, which is the condition the UNEXPECTED sweep cannot
  # survive. Same refusal as an unreadable subtree, one granularity down.
  [ "$unreadable" -eq 0 ] || return 1
  [ "$linked" -eq 0 ] || return 1
  return 0
}

# Emit every anchor in one file as "id<TAB>version<TAB>relpath:line".
# Returns 1 when the file could not be scanned, so the caller can refuse the
# port instead of judging it on a list that is short by exactly the files that
# failed. grep exits 1 both for "no match" and for a file it declines to scan,
# and exits 2 on a read error -- three outcomes the caller previously received
# as one empty stream. (Until D285 the decline was grep's own -I binary
# heuristic; -I is gone, and the byte-count guard below now makes that call
# from the file's own content.) A short anchor list is fatal
# for the UNEXPECTED sweep specifically: it can only fire on anchors it sees,
# so a NOT-owed anchor sitting in an unreadable or NUL-bearing .md made the
# port report clean.
emit_anchors() {
  local f="$1" dir="$2" rel out gst nbytes ntext
  rel="${f#$dir/}"
  [ -r "$f" ] || return 1
  # Detect the binary case explicitly rather than letting -I fold it into
  # "no match". Comparing the byte count with and without NULs is decided by
  # the file's own content, not by grep's heuristic, so the refusal does not
  # move when the heuristic does.
  nbytes="$(LC_ALL=C wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
  ntext="$(LC_ALL=C tr -d '\000' < "$f" 2>/dev/null | LC_ALL=C wc -c | tr -d '[:space:]')"
  [ "$nbytes" = "$ntext" ] || return 1
    # The path is handed to awk through the ENVIRONMENT, not through -v.
    # POSIX requires awk to apply escape processing to a -v assignment, so the
    # two ordinary characters \ and n in a filename became a REAL newline in
    # rel and split one FOUND record into two -- letting a filename forge an
    # id, a version and a path, and produce a clean verdict for a rule the port
    # does not carry. ENVIRON is the one channel awk leaves literal. This is
    # the same record-forgery class safe() guards on the canon side, so the
    # same refusal applies here: a path that still carries a separator is
    # dropped rather than emitted.
    # grep's status is captured rather than discarded: 0 match, 1 no match,
    # >1 a real error. Only the first two are a scan that happened.
    # LC_ALL=C IS STILL LOAD-BEARING, and D285 changed what it is load-bearing
    # FOR. It used to be justified as pinning grep's -I binary heuristic to a
    # byte-oriented locale; -I is gone, so read that job as finished and this
    # one as the live one: under a UTF-8 locale an invalid multibyte sequence
    # makes the MATCH ITSELF fail, with no binary heuristic involved anywhere.
    # An anchor sharing its line with such a byte is then not found, grep exits
    # 1, and that folds back into "no anchors here" -- the same false green,
    # reached by a different route. Measured: with 0xFF on the anchor's own
    # line, LC_ALL=C grep -Eano matches and LC_ALL=en_US.UTF-8 grep -Eano exits
    # 1 empty. (With the byte on a DIFFERENT line both locales match, which is
    # why a fixture has to put it on the same line to see this at all.)
    # DO NOT DELETE THIS PREFIX. The self-test case named
    # "an invalid multibyte sequence on the anchor's line cannot hide it"
    # fails without it -- added by D285 because nothing covered the locale
    # axis, and its absence is how a comment describing a removed flag could
    # have licensed removing a guard that still matters.
    #
    # LC_ALL=C pinned the LOCALE axis; -a pins the IMPLEMENTATION axis, and
    # together with the byte-count test above they close D285 finding 3.
    # -I asked grep to decide readable-as-text by its own heuristic, and a
    # heuristic broader than "contains a NUL" skips a NUL-free file and exits
    # 1 -- byte-identical to "this file holds no anchors". That is fatal for
    # the UNEXPECTED sweep specifically, which can only fire on anchors it
    # sees, so a NOT-owed anchor in such a file made the port report clean.
    # Measured: against a NUL-free file whose only non-ASCII byte is 0xFF,
    # /usr/bin/grep -EIno finds the anchor, while ugrep -EIno exits 1 with no
    # output; -Eano finds it under both. The script runs non-interactively,
    # where grep is /usr/bin/grep, so this was latent here and live on a
    # machine whose PATH puts a broader-heuristic grep first.
    #
    # -a is safe precisely BECAUSE the byte-count test runs first: every file
    # reaching this line is already proven NUL-free from its own bytes, so
    # forcing text treatment cannot make grep read something the guard would
    # have refused. Readable-as-text is now decided by the file's content, not
    # by whichever grep is on PATH -- the same principle the NUL guard states.
    # Do NOT restore -I to "be safe": that reinstates the false green.
    #
    # This also CONVERGES the two halves rather than diverging them. The
    # PowerShell twin reads raw bytes via .NET and never shells out to grep,
    # so it never had this axis to pin; before this change the pair could
    # disagree on exactly such a file, and now they agree.
    out="$(LC_ALL=C grep -Eano '<!--[[:space:]]*canon:[A-Za-z0-9][A-Za-z0-9_-]*[[:space:]]+v[0-9]+[[:space:]]*-->' "$f")"
    gst=$?
    [ "$gst" -le 1 ] || return 1
    printf '%s\n' "$out" \
      | rel="$rel" awk '
          {
            if (match($0, /^[0-9]+:/) == 0) next
            ln = substr($0, 1, RLENGTH - 1)
            rest = substr($0, RLENGTH + 1)
            if (match(rest, /canon:[A-Za-z0-9][A-Za-z0-9_-]*[ \t]+v[0-9]+/) == 0) next
            m = substr(rest, RSTART, RLENGTH)
            sub(/^canon:/, "", m)
            split(m, part, /[ \t]+v/)
            printf "%s\t%s\t%s:%s\n", part[1], part[2], ENVIRON["rel"], ln
          }'
}

recs() { echo "$RECORDS" | grep "^$1	"; }
field() { echo "$1" | cut -f"$2"; }

STATUS=0
# A gate fault is tracked separately from ordinary findings. STATUS is a single
# variable, so setting it to 2 inside the port loop would be overwritten by the
# next STATUS=1 -- making the exit code depend on registry order, which is
# arbitrary. Tier 2 means "no verdict was possible" and must never be
# downgraded by a finding recorded elsewhere in the same run.
GATE_FAULT=0
N_OK=0; N_MISSING=0; N_STALE=0; N_UNEXPECTED=0; N_DEFECT=0; N_UNVERIFIABLE=0
N_DEFERRED=0; N_NA=0
# Catalog findings are counted a second time, as a breakdown -- never instead
# of the per-kind counters. Splitting the kind counts by subject was what let
# the tally print "stale 0" while a STALE catalog row sat in the body above it.
CAT_FINDINGS=0
WORKLIST=""
PORT_DIRTY=0
# Counted separately from N_OK because the first-run framing below is about
# whether any port has ADOPTED an anchor. A property check passing says nothing
# about adoption, and on the real fleet four of them do -- which suppressed the
# note on exactly the run that most needed it.
N_ANCHOR_OK=0

EXCLUDE_CANON="$CANON"

# --------------------------------------------------------------------------
# Every finding goes through here. The body line, the counter and the work-list
# entry are produced together from one call, so the three cannot disagree --
# which they did: a port-level UNEXPECTED printed a body row, bumped a counter,
# and emitted no work-list entry at all, so a run could fail the gate while its
# work list was empty. Deriving all three from one site is the fix; patching
# the three symptoms separately would leave the next finding kind free to
# repeat it.
#
#   record KIND INDENT MESSAGE [WORK-ITEM] [SUBJECT]
#
# KIND drives the counter and the tag. A non-empty WORK-ITEM is appended to the
# work list. SUBJECT is "catalog" to add to the catalog breakdown as well.
# --------------------------------------------------------------------------
record() {
  local kind="$1" indent="$2" msg="$3" work="${4:-}" subject="${5:-}"
  case "$kind" in
    ok)           N_OK=$((N_OK + 1));                   echo "${indent}ok: $msg" ;;
    MISSING)      N_MISSING=$((N_MISSING + 1));         echo "${indent}MISSING: $msg" ;;
    STALE)        N_STALE=$((N_STALE + 1));             echo "${indent}STALE: $msg" ;;
    UNEXPECTED)   N_UNEXPECTED=$((N_UNEXPECTED + 1));   echo "${indent}UNEXPECTED: $msg" ;;
    DEFECT)       N_DEFECT=$((N_DEFECT + 1));           echo "${indent}DEFECT: $msg" ;;
    UNVERIFIABLE) N_UNVERIFIABLE=$((N_UNVERIFIABLE + 1)); echo "${indent}UNVERIFIABLE: $msg" ;;
    deferred)     N_DEFERRED=$((N_DEFERRED + 1));       [ -n "$msg" ] && echo "${indent}deferred: $msg" ;;
    na)           N_NA=$((N_NA + 1));                   [ -n "$msg" ] && echo "${indent}not applicable: $msg" ;;
  esac
  case "$kind" in
    ok|deferred|na) : ;;
    *)
      STATUS=1
      PORT_DIRTY=1
      [ "$subject" = "catalog" ] && CAT_FINDINGS=$((CAT_FINDINGS + 1))
      if [ -n "$work" ]; then
        WORKLIST="$WORKLIST
  $work"
      fi ;;
  esac
}

# The literal a port must embed. Printed in the work list so the entry can be
# acted on without opening the canon: the punctuation is exact -- no space
# after the colon -- and a mistyped anchor reports MISSING again, which reads
# as "not done" rather than "done wrong".
anchor_literal() { printf '<!-- canon:%s v%s -->' "$1" "$2"; }

SCHEMA_V="$(field "$(recs SCHEMA)" 2)"
echo "port canon drift check -- schema $SCHEMA_V"
echo "  canon:        $CANON"
echo "  ports parent: $PORTS_PARENT"
echo ""
echo "rules:"
recs ENTRY | while IFS= read -r e; do
  eid="$(field "$e" 3)"; ever="$(field "$e" 4)"; echk="$(field "$e" 7)"
  echo "  $eid v$ever ($echk)"
done
echo ""
# --------------------------------------------------------------------------
# Main pass, one port at a time.
#
# Written as a for-loop over a captured list rather than a pipeline into
# "while read": in bash 3.2 the right-hand side of a pipe runs in a subshell,
# so every STATUS=1 set inside one would be discarded when it exits, and the
# gate would exit 0 while printing findings.
# --------------------------------------------------------------------------
PORT_LINES="$(recs PORT)"
ENTRY_LINES="$(recs ENTRY)"
CLEAN_PORTS=""
DIRTY_PORTS=""

OLDIFS="$IFS"
IFS='
'
for pline in $PORT_LINES; do
  pidx="$(field "$pline" 2)"
  pid="$(field "$pline" 3)"
  pdir="$(field "$pline" 5)"
  pexists="$(field "$pline" 6)"
  # Re-validate shell-side. The awk parser already rejects a bad dir, and now
  # also rejects the tab/newline that could shift another field into this one
  # -- but this value becomes a filesystem path, so it is checked again here
  # rather than trusted across the record boundary.
  case "$pdir" in
    *[!A-Za-z0-9._-]*|""|.|..)
      echo "GATE ERROR: port \"$pid\" resolved to dir \"$pdir\", which is not a single path segment" >&2
      GATE_FAULT=1
      echo ""
      continue ;;
  esac
  ptree="$PORTS_PARENT/$pdir"
  PORT_DIRTY=0

  echo "$pid"

  if [ ! -d "$ptree" ]; then
    if [ "$pexists" = "false" ]; then
      # Registered, deliberately not scaffolded. Reported once and counted once
      # per rule it is excused from, so the tally reconciles with the row.
      # Note that reconciliation holds for THIS branch only: the unenumerable
      # branch below now emits one port-level UNVERIFIABLE that corresponds to
      # no canon row, so for a port with required rows the UNVERIFIABLE count
      # exceeds the rows the canon states. That is the price of the refusal
      # being owed by the port rather than by any cell, and it is stated here
      # so the next reader does not treat cells-equal-rows as a global
      # invariant and "fix" the refusal back out.
      echo "  deferred: not scaffolded on disk ($pdir); all rules deferred until it is"
      for eline in $ENTRY_LINES; do record deferred "  " ""; done
      echo "  verdict: deferred -- nothing owed yet"
    else
      echo "  GATE ERROR: registry says $pid exists but $ptree is not a directory" >&2
      echo "  GATE ERROR: registry says $pid exists but $ptree is not a directory"
      GATE_FAULT=1
      echo "  verdict: NOT EXAMINED"
    fi
    echo ""
    continue
  fi

  if ! FOUND="$(scan_anchors "$ptree")"; then
    # The tree could not be fully enumerated, so the anchors we did see are not
    # the anchors that are there. Every anchor cell for this port is
    # UNVERIFIABLE rather than judged on a partial list.
    # One port-level refusal FIRST, owed by the port rather than by any cell.
    # The per-entry loop below records only "required" rows, and a port whose
    # rows are all not_applicable/deferred therefore recorded nothing at all:
    # record() is the only writer of STATUS, so the run printed "verdict: NOT
    # FULLY EXAMINED" and "repos needing work: <port>" and still exited 0.
    # The filter was wrong on its own terms -- a short list is fatal for the
    # UNEXPECTED sweep, and a not_applicable row is precisely the row whose
    # ONLY possible finding is UNEXPECTED, so the suppression bit hardest
    # exactly where the refusal matters most.
    record UNVERIFIABLE "  " \
      "$pid -- could not fully enumerate $ptree; refusing to judge any cell on a partial file list" \
      "$pid: make $ptree readable so the anchor scan can run"
    for eline in $ENTRY_LINES; do
      eid="$(field "$eline" 3)"
      arow="$(echo "$RECORDS" | grep "^APPLY	$eid	$pidx	")"
      [ "$(field "$arow" 5)" = "required" ] || continue
      record UNVERIFIABLE "  " \
        "$eid -- could not fully enumerate $ptree; refusing to judge anchors on a partial file list" \
        "$pid: make $ptree readable so the anchor scan can run"
    done
    echo "  verdict: NOT FULLY EXAMINED"
    DIRTY_PORTS="$DIRTY_PORTS $pid"
    echo ""
    continue
  fi

  for eline in $ENTRY_LINES; do
    eid="$(field "$eline" 3)"
    ever="$(field "$eline" 4)"
    echk="$(field "$eline" 7)"
    arow="$(echo "$RECORDS" | grep "^APPLY	$eid	$pidx	")"
    astatus="$(field "$arow" 5)"

    if [ "$astatus" = "deferred" ]; then
      record deferred "  " ""; continue
    fi

    if [ "$echk" = "property" ]; then
      if [ "$astatus" = "not_applicable" ]; then record na "  " ""; continue; fi
      impl="$(property_impl_version "$eid")"
      if [ -z "$impl" ] || [ "$impl" != "$ever" ]; then
        # The work belongs to THIS SCRIPT, not to the port. Routing it per-port
        # turned one script edit into one work item per port, pointing readers
        # at repos that contain no property check to update.
        record UNVERIFIABLE "  " \
          "$eid v$ever -- this checker implements v${impl:-none}; refusing to pass on logic that no longer matches the rule" \
          "scripts/check-port-canon.sh: implement the $eid property check at v$ever (this is a checker change, not a port change)"
        continue
      fi
      nfiles=0; hits=""; pst=""; pprev=""; phave=0; punread=""; plinked=""
      while IFS= read -r -d '' pf; do
        if [ "$phave" -eq 1 ]; then
          # This walk is a SECOND, independent find; scan_anchors having
          # refused a symlink says nothing about what this one returns, and
          # fence_defect follows a link it is handed. Relying on the earlier
          # refusal would make the read-outside-the-tree guarantee a property
          # of call ordering across two enumerations -- the exact time-of-
          # check/time-of-use shape this walker has already been defeated by
          # once. The guard is applied where the value is used instead.
          # No symlink is ever READ here, whatever it is. Two dispositions,
          # and the fall-through is not one of them: a directory or *.md link
          # is REFUSED (it can hide markdown), any other link is IGNORED
          # entirely (it carries none) -- exactly what scan_anchors does with
          # its bare ':'.
          #
          # Gating the refusal but letting the exempt case fall through was a
          # read-outside-the-tree hole, introduced in this same round by the
          # fix for the opposite defect: the exempt link was counted into
          # nfiles and handed to fence_defect, whose `done < "$file"` follows
          # it. link.txt -> /outside/anything was read and attributed to this
          # port, and a port with NO real markdown but one ordinary symlink
          # got nfiles=1, walking straight past the empty-walk refusal below
          # and printing "property verified across 1 markdown files".
          #
          # It survived the round that added it because the fixture linked to
          # an in-tree file that resolves. The lesson is the one this file
          # keeps relearning: the guard and its sibling must agree about the
          # WHOLE tree, not about the case the fixture happened to build.
          if [ -L "$pprev" ]; then
            if [ -d "$pprev" ] || [ "${pprev%.md}" != "$pprev" ]; then
              plinked="$plinked ${pprev#$ptree/}"
            fi
            pprev="$pf"; phave=1; continue
          fi
          nfiles=$((nfiles + 1))
          d="$(fence_defect "$pprev")"
          if [ "$d" = unreadable ]; then
            punread="$punread ${pprev#$ptree/}"
          elif [ -n "$d" ]; then
            hits="$hits ${pprev#$ptree/}($d)"
          fi
        fi
        pprev="$pf"; phave=1
      done < <(port_md_files_nul "$ptree")
      pst="$pprev"
      if [ -n "$plinked" ]; then
        record UNVERIFIABLE "  " \
          "$eid -- refusing to follow symlinked markdown:$plinked; its target can resolve outside $ptree" \
          "$pid: replace the symlink(s)$plinked with real files, or remove them from the port tree"
        continue
      fi
      if [ -n "$punread" ]; then
        record UNVERIFIABLE "  " \
          "$eid -- could not read$punread; refusing to report a property verified over files that were never opened" \
          "$pid: make$punread readable so the $eid property check can run"
        continue
      fi
      if [ "$pst" != 0 ]; then
        record UNVERIFIABLE "  " \
          "$eid -- could not enumerate the markdown under $ptree; refusing to report a check that did not run" \
          "$pid: make $ptree readable so the $eid property check can run"
        continue
      fi
      if [ "$nfiles" -eq 0 ]; then
        # A pass produced by an empty walk is not a pass. Printing the count
        # (the previous fix here) told the reader the enumeration was empty
        # but still recorded ok, so the cell stayed green and the exit code
        # stayed 0 -- which is what a symlinked or unpopulated port checkout
        # produced over a tree full of violations.
        record UNVERIFIABLE "  " \
          "$eid -- no markdown was enumerated under $ptree; refusing to report a property verified over an empty walk" \
          "$pid: check that $ptree is a populated checkout; the $eid property check had nothing to walk"
        continue
      fi
      if [ -n "$hits" ]; then
        record DEFECT "  " "$eid --$hits" \
          "$pid: fix the $eid violations listed in the body above"
      else
        # State what was walked. An unqualified "verified" over an empty
        # enumeration is indistinguishable from one over a real tree.
        record ok "  " "$eid (property verified across $nfiles markdown files)"
      fi
      continue
    fi

    # check: anchor
    hit="$(echo "$FOUND" | grep "^$eid	" | head -1)"
    if [ "$astatus" = "not_applicable" ]; then
      if [ -n "$hit" ]; then
        record UNEXPECTED "  " "$eid at $(field "$hit" 3) -- this port does not owe this rule" \
          "$pid: remove the $eid anchor at $(field "$hit" 3); this port does not owe that rule"
      else
        record na "  " ""
      fi
      continue
    fi

    if [ -z "$hit" ]; then
      record MISSING "  " "$eid v$ever" \
        "$pid: add $(anchor_literal "$eid" "$ever") beside this port's own statement of the $eid rule"
    else
      hver="$(field "$hit" 2)"
      if [ "$hver" = "$ever" ]; then
        record ok "  " "$eid v$ever at $(field "$hit" 3)"
        N_ANCHOR_OK=$((N_ANCHOR_OK + 1))
      else
        record STALE "  " "$eid at $(field "$hit" 3) carries v$hver, canon is at v$ever" \
          "$pid: update $(field "$hit" 3) to $(anchor_literal "$eid" "$ever")"
      fi
    fi
  done

  # Anchors for ids the canon does not define at all.
  for hit in $FOUND; do
    hid="$(field "$hit" 1)"
    if ! echo "$ENTRY_LINES" | cut -f3 | grep -qxF -- "$hid"; then
      record UNEXPECTED "  " "canon defines no rule \"$hid\" (found at $(field "$hit" 3))" \
        "$pid: remove the unknown \"$hid\" anchor at $(field "$hit" 3), or add that rule to the canon"
    fi
  done

  # A per-port verdict, so "which repos need work" is answerable without
  # aggregating rows by eye. The tally's ok count counts CELLS, not repos.
  if [ "$PORT_DIRTY" -eq 1 ]; then
    echo "  verdict: NEEDS WORK"
    DIRTY_PORTS="$DIRTY_PORTS $pid"
  else
    echo "  verdict: clean"
    CLEAN_PORTS="$CLEAN_PORTS $pid"
  fi
  echo ""
done
IFS="$OLDIFS"

# --------------------------------------------------------------------------
# Vendored catalog copies.
#
# Two marketplace repos vendor real copies of a port's agent and skill files.
# Those copies drift independently of the source port, so an anchor placed in
# the port does not reach them. The canon's applies_to registers PORTS and does
# not model catalog copies, so this list is owned by this script rather than by
# the canon -- which the report now states, because a reader could otherwise
# not tell whether the other marketplaces were considered and excluded or
# simply forgotten. They reference their plugins by URL and vendor nothing.
#
# A catalog that is not checked out is reported as NOT EXAMINED, never skipped
# in silence: absence of a row would read as absence of a problem, and a
# partial checkout is the most common state of a fleet this size.
# --------------------------------------------------------------------------
CATALOGS="stride-codex-marketplace/plugins/stride-codex
stride-copilot-marketplace/plugins/stride-copilot
stride-copilot-marketplace/plugins/stride-copilot-lite"

echo "vendored catalog copies"
echo "  (this list is owned by this script, not by the canon: the canon registers"
echo "   ports. stride-marketplace and stride-gemini-marketplace reference their"
echo "   plugins by URL and vendor no files, so they have nothing to drift.)"
CAT_ABSENT=0
OLDIFS="$IFS"
IFS='
'
for cat in $CATALOGS; do
  ctree="$PORTS_PARENT/$cat"
  if [ ! -d "$ctree" ]; then
    echo "  NOT EXAMINED: $cat is not checked out here -- this run says nothing about it"
    CAT_ABSENT=$((CAT_ABSENT + 1))
    continue
  fi
  if ! CFOUND="$(scan_anchors "$ctree")"; then
    record UNVERIFIABLE "  " \
      "catalog $cat -- could not fully enumerate $ctree; refusing to judge anchors on a partial file list" \
      "catalog $cat: make $ctree readable so the anchor scan can run" catalog
    continue
  fi
  for eline in $ENTRY_LINES; do
    eid="$(field "$eline" 3)"
    ever="$(field "$eline" 4)"
    echk="$(field "$eline" 7)"
    [ "$echk" = "property" ] && continue
    hit="$(echo "$CFOUND" | grep "^$eid	" | head -1)"
    if [ -z "$hit" ]; then
      record MISSING "  " "catalog $cat -- $eid v$ever" \
        "catalog $cat: re-vendor from the port, or add $(anchor_literal "$eid" "$ever")" catalog
    else
      hver="$(field "$hit" 2)"
      if [ "$hver" = "$ever" ]; then
        record ok "  " "catalog $cat -- $eid v$ever at $(field "$hit" 3)"
      else
        record STALE "  " "catalog $cat -- $eid at $(field "$hit" 3) carries v$hver, canon is at v$ever" \
          "catalog $cat: re-vendor; its $eid anchor is v$hver and the canon is at v$ever" catalog
      fi
    fi
  done
  for hit in $CFOUND; do
    hid="$(field "$hit" 1)"
    if ! echo "$ENTRY_LINES" | cut -f3 | grep -qxF -- "$hid"; then
      record UNEXPECTED "  " "catalog $cat -- canon defines no rule \"$hid\" (found at $(field "$hit" 3))" \
        "catalog $cat: remove or re-vendor the unknown \"$hid\" anchor" catalog
    fi
  done
done
IFS="$OLDIFS"
echo ""

# --------------------------------------------------------------------------
# Summary. Every number below is produced by record(), from the same call that
# printed the body row, so the tally cannot disagree with the body.
# --------------------------------------------------------------------------
echo "tally (all subjects, ports and catalogs together):"
echo "  ok $N_OK, missing $N_MISSING, stale $N_STALE, unexpected $N_UNEXPECTED, defect $N_DEFECT, unverifiable $N_UNVERIFIABLE"
echo "  of those, $CAT_FINDINGS are in vendored catalogs; $N_NA cells not applicable; $N_DEFERRED cells deferred"
echo "  note: these count RULE CELLS, not repositories -- see the verdict lines above for repositories"
[ "$CAT_ABSENT" -gt 0 ] && echo "  note: $CAT_ABSENT vendored catalog(s) were not checked out and were NOT examined"
echo ""
[ -n "$CLEAN_PORTS" ] && echo "clean repos:$CLEAN_PORTS"
[ -n "$DIRTY_PORTS" ] && echo "repos needing work:$DIRTY_PORTS"

if [ -n "$WORKLIST" ]; then
  echo ""
  echo "work list:$WORKLIST"
elif [ "$STATUS" -ne 0 ]; then
  # Should be unreachable: every record() call that sets STATUS=1 is expected to
  # carry a work item. Saying so beats printing a failing run with no work list.
  echo ""
  echo "work list: EMPTY, but findings exist -- this is a defect in this script;"
  echo "  every finding is meant to produce an actionable entry."
fi

# The first run against a fleet that predates the anchor contract is red in
# every anchor cell BY DESIGN, and the canon says so in prose the reader of
# this report would otherwise never see. Without it, 44 findings on first
# contact reads as a broken checker -- and the likely response is to route
# around the gate, which is worse than the drift it exists to catch.
if [ "$N_MISSING" -gt 0 ] && [ "$N_ANCHOR_OK" -eq 0 ]; then
  echo ""
  echo "note: every anchor cell is MISSING and none is present. If the anchor contract"
  echo "  is new to this fleet, that is the expected first-run state, not a broken"
  echo "  checker: no port has adopted an anchor yet. Read the work list as a work"
  echo "  list, not as a verdict on the fleet or on this tool."
fi

if [ "$GATE_FAULT" -eq 1 ]; then
  echo "GATE ERROR: at least one registered port could not be examined; this run proved nothing about it" >&2
  exit 2
fi
exit "$STATUS"
