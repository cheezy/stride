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
# UNBUDGETED - growing them is the point of extraction. The one sibling that is
# budgeted, review-block-extraction.md, is read on every reviewed task, so it
# is hot-path in practice (W2257). agents/task-reviewer.md is not a skill, but
# its body is the start of every reviewer request, so it is budgeted like a
# hot-path file (W2258).
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

# Budget table (bytes). Sizes after the W2257 and W2258 rationale extractions:
#   stride-workflow/SKILL.md                         98,446
#   stride-workflow/review-block-extraction.md       50,906
#   stride-completing-tasks/SKILL.md                 59,165 (W2258; was 63,905)
#   stride-claiming-tasks/SKILL.md                   31,602 (W2079 era: 29,694)
#   agents/task-reviewer.md                          74,535 (W2258; was 77,339)
# review-block-extraction.md is ~12% above its size, per the 10-15% rule.
# stride-workflow/SKILL.md is deliberately NOT: 10-15% above 98,446 would RAISE
# its budget from 101,000, so W2257 lowered it to 100,000 (~1.6% headroom)
# instead, keeping the saving from being regrown silently. W2258 holds
# stride-completing-tasks/SKILL.md (64,000 -> 61,000, ~3.1%) and the newly
# budgeted agents/task-reviewer.md (77,000, ~3.3%, below its pre-extraction
# size) tighter for the same reason. Raising a budget is a deliberate,
# reviewed decision - never a reflex to make this check pass.
check "skills/stride-workflow/SKILL.md"                     100000
check "skills/stride-workflow/review-block-extraction.md"    57000
check "skills/stride-completing-tasks/SKILL.md"              61000
check "skills/stride-claiming-tasks/SKILL.md"                33500
check "agents/task-reviewer.md"                              77000

exit "$STATUS"
