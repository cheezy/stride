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

usage() {
  cat <<'USAGE'
usage: check-port-canon.sh [--ports-parent DIR] [--canon PATH] [-h|--help]

  --ports-parent DIR  Directory holding the port checkouts. Each registry
                      "dir" is resolved as one level below this directory.
                      Defaults to the parent of the stride repo root, which
                      is where the ports sit in a normal checkout.
  --canon PATH        Canon document to read. Defaults to docs/port-canon.md
                      inside this repo.
  -h, --help          Print this message.

Both flags exist so the check can be exercised against a synthetic fixture
tree. Neither is needed in normal use.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ports-parent)
      [ $# -ge 2 ] || { echo "GATE ERROR: --ports-parent needs a directory" >&2; exit 2; }
      PORTS_PARENT="$2"; shift 2 ;;
    --canon)
      [ $# -ge 2 ] || { echo "GATE ERROR: --canon needs a path" >&2; exit 2; }
      CANON="$2"; shift 2 ;;
    *) echo "GATE ERROR: unknown option \"$1\"" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PORTS_PARENT" ] || PORTS_PARENT="$(cd "$ROOT/.." && pwd)"

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
      echo "  GATE ERROR: registry says $pid exists but $ptree is not a directory"
      STATUS=2
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
        echo "  UNVERIFIABLE: $eid v$ever -- this checker implements ${impl:-no} version; refusing to pass on logic that no longer matches the rule"
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
  [ -d "$ctree" ] || { echo "  skipped: $cat not checked out here"; continue; }
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

exit "$STATUS"
