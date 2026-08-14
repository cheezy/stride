#!/usr/bin/env bash
# W2079: byte-budget drift detector for the hot-path skill files.
#
# Budgets are drift detectors, not targets (the D229 philosophy): each is set
# 10-15% above the post-extraction size so ordinary edits pass and only
# sustained regrowth trips it. G404's saving was eaten silently in four days
# because nothing watched skill sizes; this check turns regrowth into a
# visible decision instead of an accident.
#
# The cold optional-*.md and reference sibling files are deliberately
# UNBUDGETED - growing them is the point of extraction.
#
# No external dependencies beyond a POSIX shell and wc; no pipes; no network.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS=0

check() {
  file="$1"
  budget="$2"
  path="$ROOT/$file"
  if [ ! -f "$path" ]; then
    echo "BUDGET CHECK ERROR: $file - budget table entry has no matching file (missing or renamed?). The table is in scripts/check-skill-budgets.sh - update the entry to the file's new path."
    STATUS=1
    return
  fi
  size=$(( $(wc -c < "$path") ))
  if [ "$size" -gt "$budget" ]; then
    echo "BUDGET EXCEEDED: $file is $size bytes (budget: $budget)."
    echo "  Hot-path skill files are size-budgeted so regrowth is a visible decision,"
    echo "  not an accident. Move cold material to a gated sibling file instead of"
    echo "  growing the hot path - see CHANGELOG.md's W2077 and W2078 extraction"
    echo "  entries for the pattern (sibling named at its gate, pointer at the"
    echo "  original site, Decision Summary stays inline)."
    echo "  If extraction is genuinely wrong for this change, the budget table is in"
    echo "  scripts/check-skill-budgets.sh - raising a budget is a deliberate,"
    echo "  reviewed decision, never a reflex to make this check pass."
    STATUS=1
  else
    echo "ok: $file - $size of $budget bytes"
  fi
}

# Budget table (bytes). Post-extraction sizes at W2079 time:
#   stride-workflow/SKILL.md          89,647
#   stride-completing-tasks/SKILL.md  56,750
#   stride-claiming-tasks/SKILL.md    29,694
# Each budget is ~12-13% above that size. Raising a budget is a deliberate,
# reviewed decision - never a reflex to make this check pass.
check "skills/stride-workflow/SKILL.md"         101000
check "skills/stride-completing-tasks/SKILL.md"  64000
check "skills/stride-claiming-tasks/SKILL.md"    33500

exit "$STATUS"
