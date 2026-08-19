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
#   exit 1 -- every anchor is MISSING because no port has adopted one yet --
#   which is why this script is deliberately NOT wired into the pass/fail hook
#   suite the way its siblings are. Run --self-test to prove the gate; run it
#   bare to see the fleet's drift.
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
  local tmp pass fail out rc f3
  tmp="$(mktemp -d)" || { echo "GATE ERROR: could not create a temp dir for --self-test" >&2; exit 2; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
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
  st_assert "MISSING produces a work list entry" 1 "$rc" "add the rule-one v1 anchor" "$out"

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
  st_assert "deferred on an existing port is not a finding" 0 "$rc" "deferred 1" "$out"
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
      if (rest == "json") { injson = 1; blocknum++; blockline = NR; blob = "" }
      next
    } else if (run >= fencelen && rest ~ /^[ \t]*$/) {
      if (injson) { classify() ; injson = 0 }
      infence = 0; fencelen = 0
      next
    }
  }
  if (injson) blob = blob $0 "\n"
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
      PORTID[i] = pid
      printf "PORT\t%d\t%s\t%s\t%s\t%s\n", i, pid, V["ports." i ".family"], V["ports." i ".dir"], V["ports." i ".exists"]
    }
    nports = n
    return
  }

  if ("id" in V) {
    if (blocknum == 1) fail("first json block carries an id but no canon_schema_version; the registry must come first")
    eid = V["id"]
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
    printf "ENTRY\t%d\t%s\t%s\t%s\t%s\t%s\n", nentries, eid, V["version"], V["status"], V["provenance"], V["check"]
    printf "HINT\t%s\t%s\n", eid, V["check_hint"]
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
      printf "APPLY\t%s\t%d\t%s\t%s\t%s\n", eid, i, PORTID[i], j, V["applies_to." i ".variant"]
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
  [ -r "$file" ] || return 0
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
port_md_files() {
  find "$1" -type f -name '*.md' \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/deps/*' \
    -not -path '*/_build/*' 2>/dev/null
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
scan_anchors() {
  local dir="$1" f rel
  port_md_files "$dir" | while IFS= read -r f; do
    [ "$f" = "$EXCLUDE_CANON" ] && continue
    grep -EIno '<!--[[:space:]]*canon:[A-Za-z0-9_-]+[[:space:]]+v[0-9]+[[:space:]]*-->' "$f" 2>/dev/null \
      | while IFS= read -r hit; do
          rel="${f#$dir/}"
          echo "$hit" | sed -E "s|^([0-9]+):<!--[[:space:]]*canon:([A-Za-z0-9_-]+)[[:space:]]+v([0-9]+)[[:space:]]*-->|\2\t\3\t$rel:\1|"
        done
  done
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
CAT_FINDINGS=0
WORKLIST=""

EXCLUDE_CANON="$CANON"

SCHEMA_V="$(field "$(recs SCHEMA)" 2)"
echo "port canon drift check -- schema $SCHEMA_V, canon $CANON"
echo "ports parent: $PORTS_PARENT"
echo ""
echo "rules:"
recs ENTRY | while IFS= read -r e; do
  eid="$(field "$e" 3)"; ever="$(field "$e" 4)"; echk="$(field "$e" 7)"
  echo "  $eid v$ever ($echk)"
  echo "$RECORDS" | grep "^HINT	$eid	" | cut -f3 | sed 's/^/      hint: /'
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

OLDIFS="$IFS"
IFS='
'
for pline in $PORT_LINES; do
  pidx="$(field "$pline" 2)"
  pid="$(field "$pline" 3)"
  pdir="$(field "$pline" 5)"
  pexists="$(field "$pline" 6)"
  ptree="$PORTS_PARENT/$pdir"

  echo "$pid"

  if [ ! -d "$ptree" ]; then
    if [ "$pexists" = "false" ]; then
      # Registered, deliberately not scaffolded. Reported distinctly and kept
      # out of every drift tally -- it owes nothing until it exists.
      echo "  deferred: not scaffolded on disk ($pdir); every rule deferred"
      for eline in $ENTRY_LINES; do N_DEFERRED=$((N_DEFERRED + 1)); done
    else
      echo "  GATE ERROR: registry says $pid exists but $ptree is not a directory" >&2
      GATE_FAULT=1
    fi
    echo ""
    continue
  fi

  FOUND="$(scan_anchors "$ptree")"

  for eline in $ENTRY_LINES; do
    eid="$(field "$eline" 3)"
    ever="$(field "$eline" 4)"
    echk="$(field "$eline" 7)"
    arow="$(echo "$RECORDS" | grep "^APPLY	$eid	$pidx	")"
    astatus="$(field "$arow" 5)"

    if [ "$astatus" = "deferred" ]; then
      N_DEFERRED=$((N_DEFERRED + 1)); continue
    fi

    if [ "$echk" = "property" ]; then
      if [ "$astatus" = "not_applicable" ]; then N_NA=$((N_NA + 1)); continue; fi
      impl="$(property_impl_version "$eid")"
      if [ -z "$impl" ] || [ "$impl" != "$ever" ]; then
        echo "  UNVERIFIABLE: $eid v$ever -- this checker implements v${impl:-none}; refusing to pass on logic that no longer matches the rule"
        N_UNVERIFIABLE=$((N_UNVERIFIABLE + 1)); STATUS=1
        WORKLIST="$WORKLIST
  $pid: update the $eid property check to v$ever"
        continue
      fi
      hits=""
      for f in $(port_md_files "$ptree"); do
        d="$(fence_defect "$f")"
        [ -n "$d" ] && hits="$hits ${f#$ptree/}($d)"
      done
      if [ -n "$hits" ]; then
        echo "  DEFECT: $eid --$hits"
        N_DEFECT=$((N_DEFECT + 1)); STATUS=1
        WORKLIST="$WORKLIST
  $pid: fix the $eid violations listed above"
      else
        echo "  ok: $eid (property verified)"
        N_OK=$((N_OK + 1))
      fi
      continue
    fi

    # check: anchor
    hit="$(echo "$FOUND" | grep "^$eid	" | head -1)"
    if [ "$astatus" = "not_applicable" ]; then
      if [ -n "$hit" ]; then
        echo "  UNEXPECTED: $eid at $(field "$hit" 3) -- this port does not owe this rule"
        N_UNEXPECTED=$((N_UNEXPECTED + 1)); STATUS=1
      else
        N_NA=$((N_NA + 1))
      fi
      continue
    fi

    if [ -z "$hit" ]; then
      echo "  MISSING: $eid v$ever"
      N_MISSING=$((N_MISSING + 1)); STATUS=1
      WORKLIST="$WORKLIST
  $pid: add the $eid v$ever anchor"
    else
      hver="$(field "$hit" 2)"
      if [ "$hver" = "$ever" ]; then
        echo "  ok: $eid v$ever at $(field "$hit" 3)"
        N_OK=$((N_OK + 1))
      else
        echo "  STALE: $eid at $(field "$hit" 3) carries v$hver, canon is at v$ever"
        N_STALE=$((N_STALE + 1)); STATUS=1
        WORKLIST="$WORKLIST
  $pid: bump the $eid anchor from v$hver to v$ever"
      fi
    fi
  done

  # Anchors for ids the canon does not define at all.
  for hit in $FOUND; do
    hid="$(field "$hit" 1)"
    if ! echo "$ENTRY_LINES" | cut -f3 | grep -qx "$hid"; then
      echo "  UNEXPECTED: canon defines no rule \"$hid\" (found at $(field "$hit" 3))"
      N_UNEXPECTED=$((N_UNEXPECTED + 1)); STATUS=1
    fi
  done
  echo ""
done
IFS="$OLDIFS"

# --------------------------------------------------------------------------
# Vendored catalog copies.
#
# Two marketplace repos vendor real copies of a port's agent and skill files.
# Those copies drift independently of the source port, so an anchor placed in
# the port does not reach them. The canon's applies_to does not model catalog
# copies at all -- it registers ports -- so these are checked against the same
# rules but tallied and labelled separately rather than folded into the
# registry rows. The other marketplaces reference their plugins by URL and
# vendor nothing, so there is nothing in them to drift.
#
# A catalog that is not checked out locally is skipped, not reported: its
# absence is a fact about this machine, not drift in the fleet.
# --------------------------------------------------------------------------
CATALOGS="stride-codex-marketplace/plugins/stride-codex
stride-copilot-marketplace/plugins/stride-copilot
stride-copilot-marketplace/plugins/stride-copilot-lite"

echo "vendored catalog copies"
CAT_ANY=0
OLDIFS="$IFS"
IFS='
'
for cat in $CATALOGS; do
  ctree="$PORTS_PARENT/$cat"
  [ -d "$ctree" ] || continue
  CAT_ANY=1
  CFOUND="$(scan_anchors "$ctree")"
  for eline in $ENTRY_LINES; do
    eid="$(field "$eline" 3)"
    ever="$(field "$eline" 4)"
    echk="$(field "$eline" 7)"
    [ "$echk" = "property" ] && continue
    hit="$(echo "$CFOUND" | grep "^$eid	" | head -1)"
    if [ -z "$hit" ]; then
      echo "  MISSING: catalog $cat -- $eid v$ever"
      CAT_FINDINGS=$((CAT_FINDINGS + 1)); STATUS=1
      WORKLIST="$WORKLIST
  catalog $cat: add the $eid v$ever anchor (or re-vendor from the port)"
    else
      hver="$(field "$hit" 2)"
      if [ "$hver" = "$ever" ]; then
        echo "  ok: catalog $cat -- $eid v$ever at $(field "$hit" 3)"
      else
        echo "  STALE: catalog $cat -- $eid at $(field "$hit" 3) carries v$hver, canon is at v$ever"
        CAT_FINDINGS=$((CAT_FINDINGS + 1)); STATUS=1
        WORKLIST="$WORKLIST
  catalog $cat: re-vendor; $eid anchor is v$hver, canon is v$ever"
      fi
    fi
  done
  # Anchors for ids the canon does not define at all. applies_to does not model
  # catalog copies, so every canon-defined id is expected in one -- only an id
  # the canon defines nowhere can be UNEXPECTED here. Without this sweep a
  # catalog carrying an invented anchor was silently ignored and the run could
  # exit 0 with a finding present.
  for hit in $CFOUND; do
    hid="$(field "$hit" 1)"
    if ! echo "$ENTRY_LINES" | cut -f3 | grep -qx "$hid"; then
      echo "  UNEXPECTED: catalog $cat -- canon defines no rule \"$hid\" (found at $(field "$hit" 3))"
      CAT_FINDINGS=$((CAT_FINDINGS + 1)); STATUS=1
      WORKLIST="$WORKLIST
  catalog $cat: remove or re-vendor the unknown \"$hid\" anchor"
    fi
  done
done
IFS="$OLDIFS"
[ "$CAT_ANY" -eq 0 ] && echo "  (no vendored catalogs checked out here)"
echo ""

echo "tally: ok $N_OK, missing $N_MISSING, stale $N_STALE, unexpected $N_UNEXPECTED, defect $N_DEFECT, unverifiable $N_UNVERIFIABLE"
echo "tally: catalog findings $CAT_FINDINGS; not applicable $N_NA; deferred $N_DEFERRED"

if [ -n "$WORKLIST" ]; then
  echo ""
  echo "work list:$WORKLIST"
fi

if [ "$GATE_FAULT" -eq 1 ]; then
  echo "GATE ERROR: at least one registered port could not be examined; this run proved nothing about it" >&2
  exit 2
fi
exit "$STATUS"
