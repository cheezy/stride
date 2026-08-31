#!/usr/bin/env bash
# stride-hook.sh — Bridges Claude Code hooks to Stride .stride.md hook execution
#
# Called by Claude Code's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the Bash command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | stride-hook.sh <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in PreToolUse context)

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
STRIDE_MD="$PROJECT_DIR/.stride.md"
ENV_CACHE="$PROJECT_DIR/.stride-env-cache"
# (D118) Canonical API-response snapshot. When present, after_goal detection and
# env extraction prefer it over the harness-truncatable tool_response.stdout.
# Best-effort fast path only — the reliability guarantee is D119's fresh call.
RESPONSE_FILE="$PROJECT_DIR/.stride/.last-api-response.json"

# (W2123) Loop state. The Stop gate cannot refuse an action it has no evidence
# for, so a successful completion records that it happened and the next claim
# clears it. Written by the hook rather than the agent on purpose: an
# agent-written marker is exactly as skippable as the instruction it replaces.
LOOP_STATE_FILE="$PROJECT_DIR/.stride/.loop-state.json"

# (D234) Durable per-hook result. run_stride_section emits its structured JSON
# to bare STDOUT and exits 0, but Claude Code's PreToolUse contract sends exit-0
# stdout to the transcript, NOT to the model — only exit 2 feeds output back. So
# on the success path there is nothing for the agent to read, and the
# duration_ms it reports has to come from somewhere else. This file is that
# somewhere.
#
# ONE FILE PER HOOK, not one keyed file: after_doing and before_review must not
# overwrite each other, and separate paths make that structural rather than
# something a writer has to remember.
#
# A MISSING FILE IS NORMAL AND MEANS "KEEP 0". In plugin mode every .stride.md
# section body is empty, run_stride_section returns before doing any work and
# emits nothing, and 0 is the truthful answer. Readers must never treat absence
# as an error, a retry, or a licence to invent a figure.
hook_result_file() {
  printf '%s/.stride/.hook-result-%s.json' "$PROJECT_DIR" "$1"
}

# Best-effort and never fatal: a hook must not fail because a duration could not
# be recorded. Written atomically so a reader never sees a half-file.
write_hook_result() {
  local _hook="$1" _json="$2" _dest _tmp
  _dest=$(hook_result_file "$_hook")
  mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null || return 0
  _tmp=$(mktemp "$PROJECT_DIR/.stride/hook-result.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n' "$_json" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$_dest" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
  return 0
}

# (W2123) Loop-state helpers.
#
# Structurally keep response bodies, task free text and credentials out of the
# file: every string that reaches it must first match a conservative charset.
# A value that fails this is refused rather than sanitised — the file records
# two identifiers, and anything that is not identifier-shaped does not belong
# in it.
loop_state_safe() {
  [ -n "${1:-}" ] || return 1
  [ "${#1}" -le 64 ] || return 1
  case "$1" in
    *[!A-Za-z0-9_.:-]*) return 1 ;;
  esac
  return 0
}

# A payload describes a SUCCESSFUL completion only when it carries the two
# fields the state file is built from. Every non-success body the API emits
# (validation errors, 404s, 422s) lacks `.data` entirely, so this is the
# discriminator — curl has no `-f` here and the W2131 guard forbids `-o` and
# transformer pipes, so a 422 body always lands on stdout and would otherwise
# be indistinguishable from a success.
loop_state_payload_ok() {
  printf '%s' "${1:-}" | jq -e '
    try (
      (.data.identifier | type == "string" and length > 0)
      and (.data.needs_review | type == "boolean")
    ) catch false
  ' > /dev/null 2>&1
}

# Atomic and never fatal, copying write_hook_result's mechanics exactly: the
# temp file is created in the DESTINATION directory so the rename is same-fs,
# a failure at any point leaves no temp behind, and the function still returns
# 0. This is a gate input, not a correctness dependency — a completion must
# never fail because the loop state could not be recorded.
write_loop_state() {
  local _json="$1" _tmp
  # `mv` into a DIRECTORY succeeds by relocating the temp inside it, so the
  # failure branch below never runs: the record lands where no reader looks and
  # the temp survives indefinitely. Refuse any destination that exists and is
  # not a regular file, rather than assuming mv fails when it is unusable.
  if [ -e "$LOOP_STATE_FILE" ] && [ ! -f "$LOOP_STATE_FILE" ]; then
    printf 'stride-hook: loop-state path is not a regular file; not recording\n' >&2
    return 0
  fi
  mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null || {
    printf 'stride-hook: could not create .stride/ for the loop state; continuing\n' >&2
    return 0
  }
  _tmp=$(mktemp "$PROJECT_DIR/.stride/loop-state.XXXXXX" 2>/dev/null) || {
    printf 'stride-hook: could not stage the loop state; continuing\n' >&2
    return 0
  }
  if printf '%s\n' "$_json" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$LOOP_STATE_FILE" 2>/dev/null || {
      printf 'stride-hook: could not move the loop state into place; continuing\n' >&2
      rm -f "$_tmp" 2>/dev/null
    }
  else
    printf 'stride-hook: could not write the loop state; continuing\n' >&2
    rm -f "$_tmp" 2>/dev/null
  fi
  return 0
}

# Self-gates on before_review — the hook that fires AFTER a /complete succeeds.
# Never writes to stdout: the D238 contract is that this script emits exactly
# one JSON document, so every diagnostic here goes to stderr.
record_loop_state_for_completion() {
  local _payload _src="" _ident _needs _sid _json

  [ "${HOOK_NAME:-}" = "before_review" ] || return 0
  [ "${HAS_JQ:-false}" = "true" ] || return 0

  # Tier 1 — THIS call's payload, and deliberately NOT
  # extract_response_payload. That helper is canonical-file-first (D118) and
  # .stride/.last-api-response.json survives across calls, so on a truncated
  # 422 it resolves the previous CLAIM payload — which carries both fields —
  # and would record a completion that never happened. Same staleness shape as
  # D226, so this uses the same own-call primitive D226 does.
  _payload=$(unwrap_tool_response "$INPUT")
  if loop_state_payload_ok "$_payload"; then
    _src="$_payload"
  elif [ -n "${STRIDE_ROUTE_TASK_ID:-}" ] && loop_state_payload_ok "${RESPONSE_PAYLOAD:-}" \
    && printf '%s' "${RESPONSE_PAYLOAD:-}" | jq -e --arg tid "$STRIDE_ROUTE_TASK_ID" '
         try ((.hooks | type == "array") and ((.data.id | tostring) == $tid)) catch false
       ' > /dev/null 2>&1; then
    # Tier 2 — the harness truncated a large SUCCESS, so this call's own stdout
    # will not parse. Fall back to the canonical snapshot, but only when it
    # demonstrably belongs to THIS completion: `.hooks` is an array (a claim
    # carries singular `.hook`) and its task id equals the id this command
    # routed on. Both guards must hold, or the D226 staleness walks back in
    # through the fallback.
    #
    # WHY THE SNAPSHOT HOLDS THIS COMPLETION AND NOT THE LAST CLAIM — state it,
    # because omitting it has already led two readers to opposite wrong
    # conclusions: one that this block is unreachable dead weight, the other
    # that extract_response_payload's "saved to" branch covers the case
    # instead. Neither is right. The completion curl is REQUIRED to end in
    # `| tee .stride/.last-api-response.json` — the W2131 pre-phase guard
    # refuses the call otherwise — and capture_canonical_response writes the
    # same file, so by the time this runs the snapshot carries THIS response,
    # untruncated, not the previous claim's. (The "saved to" branch cannot
    # substitute: read_canonical_response runs FIRST inside
    # extract_response_payload, so a non-empty snapshot preempts it.) Tier 2 is
    # the only path that records anything on a harness-truncated large success.
    _src="${RESPONSE_PAYLOAD:-}"
  fi
  if [ -z "$_src" ]; then
    # A 422 legitimately records nothing, and announcing every failed
    # completion would be noise. An UNPARSABLE body is the different case: the
    # completion may well have succeeded server-side and the evidence is simply
    # lost, which is indistinguishable from "nothing to record" unless said.
    # `jq empty`, not `jq -e .`: -e sets its exit status from the VALUE, so a
    # body of `false` or `null` — both perfectly well-formed — would be
    # announced as unparsable, and an ABSENT body would exit 4 on no input and
    # be announced as a parse failure that never happened. `empty` fails only
    # on a genuine parse error, and the -n guard keeps "no body at all" out of
    # a channel that claims a body failed to parse.
    if [ -n "$_payload" ] && ! printf '%s' "$_payload" | jq empty > /dev/null 2>&1; then
      printf 'stride-hook: completion response was unparsable; no loop state recorded\n' >&2
    fi
    return 0
  fi

  _ident=$(printf '%s' "$_src" | jq -r '.data.identifier' 2>/dev/null || echo "")
  _needs=$(printf '%s' "$_src" | jq -r '.data.needs_review' 2>/dev/null || echo "")
  loop_state_safe "$_ident" || return 0
  case "$_needs" in true|false) ;; *) return 0 ;; esac

  # The session id is the ONLY field read out of $INPUT, which also carries the
  # Bearer token in .tool_input.command — never widen this read.
  _sid=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  [ -n "$_sid" ] || _sid="${CLAUDE_SESSION_ID:-}"
  loop_state_safe "$_sid" || _sid="unknown"

  _json=$(jq -nc \
    --arg ident "$_ident" \
    --argjson needs "$_needs" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "$_sid" \
    '{identifier: $ident, needs_review: $needs, completed_at: $ts, session_id: $sid}' \
    2>/dev/null) || return 0
  [ -n "$_json" ] || return 0

  write_loop_state "$_json"
  return 0
}

# (D238) The after_goal section's structured result, stashed by
# run_after_goal_section so that emit_hook_stdout can emit ONE document. Declared
# here because `set -u` is active and the emitter reads it unconditionally.
AFTER_GOAL_JSON=""

# (D236) Sentinel for "attribution applies and this task owns NO commits" — as
# distinct from "no nested window applies", which is empty output. Cannot
# collide with a git range.
STRIDE_NO_OWN_COMMITS="__stride_no_own_commits__"

# (D255) Sentinel value for a TASK_OWNED_<id> record whose after_doing delta
# exceeded the 20-SHA cap. Consumers treat it EXACTLY like no-record (purity
# fallback) — never as a truncated list, which would mis-subtract.
STRIDE_OWNED_OVERFLOW="OVERFLOW"

# (D274) Open-window count at which the liveness sweep engages in
# select_kept_window_records. This is NOT an eviction cap: above it the
# selector drops only open windows it can PROVE dead, and keeps every open
# window it cannot. It inherits the pre-D274 cap's arithmetic (one less when
# the caller reserves a slot) so the point at which housekeeping engages is
# unchanged — only what happens there.
STRIDE_OPEN_WINDOW_SWEEP_AT=20
# (D255) Owned-commit delta state for the CURRENT completion, set by
# run_stride_section around the after_doing command loop and consumed once by
# finalize_after_doing's post-loop call. Declared for `set -u`.
SNAP_OWNED_H0=""
SNAP_OWNED_H1=""
SNAP_OWNED_LOOP_RAN=false
SNAP_OWNED_SET=""
SNAP_OWNED_RECORDED=false

# (D238) Set only on the doubly-degraded path where no stdout buffer could be
# created anywhere and the primary section therefore ran unbuffered. Declared at
# file scope because `set -u` is active.
PRIMARY_UNREDIRECTED=false

# (D220) Published by stride_route_command — the single source of truth for
# "which Stride lifecycle endpoint, if any, is this Bash call actually issuing?".
# Declared here because `set -u` is active and the after-goal gate reads
# STRIDE_ROUTE_ENDPOINT on every post-phase run.
STRIDE_ROUTE_ENDPOINT=""
STRIDE_ROUTE_HOOK=""
STRIDE_ROUTE_TASK_ID=""
_SR_Q=""
_SR_REST=""
_SR_NL='
'
_SR_CR=$(printf '\r')

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-hook.sh: Windows detected but stride-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# --- Per-file diff capture (G148/W719 contract, Option D semantic) ---
# Emits a JSON array of `{path, diff}` entries to stdout, one per file that
# differs between $1 (base ref) and the agent's WORKING TREE at the time the
# function runs. The snapshot captures committed-since-base, staged-but-
# uncommitted, modified-but-unstaged, AND untracked-but-not-gitignored changes
# in a single pass — so reviewers see the agent's full working state at
# completion time, regardless of whether the agent committed before calling
# /complete. Truncates diffs over 500 lines with the contract marker; emits
# the binary placeholder for files git reports as binary in --numstat (tracked)
# or that contain a NUL byte (untracked). Falls back to HEAD~1 when the
# provided base is empty or unresolvable. Returns an empty array (and exit 0)
# for any degraded path (jq missing, git missing, not in a repo, no commits to
# diff) so callers can treat this strictly as "best-effort capture".
# (D236) Run a git subcommand once per attributed range and concatenate the
# output. Extracted because the same loop appeared at four call sites in
# capture_changed_files, differing only in the git subcommand — and a
# range-expansion bug fixed at three of four sites is exactly the class of
# defect this file has already paid for.
#   $1  newline-separated "<from> <to>" ranges (the sentinel is skipped)
#   $2  pathspec to limit to, or "" for none
#   $3+ git arguments
# Invocation order matters and is why the pathspec is its own parameter rather
# than part of "$@": git wants `diff <from> <to> -- <path>`, and everything
# after `--` is a path — passing the pathspec inside the argument list put it
# BEFORE the endpoints and silently produced an empty per-file patch.
expand_own_ranges() {
  local _ranges="$1" _path="$2"; shift 2
  local _r _rf _rt
  while IFS= read -r _r; do
    [ -n "$_r" ] || continue
    [ "$_r" = "$STRIDE_NO_OWN_COMMITS" ] && continue
    _rf="${_r%% *}"; _rt="${_r##* }"
    if [ -n "$_path" ]; then
      git "$@" "$_rf" "$_rt" -- "$_path" 2>/dev/null || true
    else
      git "$@" "$_rf" "$_rt" 2>/dev/null || true
    fi
  done <<< "$_ranges"
}

capture_changed_files() {
  local base="${1:-}"
  # (D236) Optional: newline-separated "<from> <to>" git ranges naming the
  # commits that belong to THIS task, with any nested task's commits already
  # removed. When empty the function behaves exactly as it always has —
  # `git diff <base>` against the working tree — so every existing caller and
  # test is untouched. When set, the committed half of the snapshot is built
  # from these ranges instead, and the working-tree half is added on top,
  # because uncommitted changes belong to whoever is completing now.
  local own_ranges="${2:-}"
  local max_lines=500
  local trunc_marker="[diff truncated at 500 lines]"
  local bin_placeholder="[binary file — no diff captured]"

  if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi

  if [ -z "$base" ] || ! git rev-parse --verify "$base" > /dev/null 2>&1; then
    if git rev-parse --verify "HEAD~1" > /dev/null 2>&1; then
      base="HEAD~1"
    else
      printf '[]\n'
      return 0
    fi
  fi

  # (D278) Every path listing below uses -z and is read NUL-delimited into a
  # bash array. git quotes any path holding a byte >= 0x80 (also TAB, newline,
  # backslash, double quote) in its non--z output, under core.quotePath, which
  # defaults to true — so a Cyrillic path arrived as the literal 14-character
  # string "\320\264\320\276\320\272/plain.txt". That spelling was written
  # into the snapshot AND fed back to `git diff -- <path>`, which matches
  # nothing because the quoted form is not a valid pathspec: the entry carried
  # a fabricated path AND an empty diff, losing 100% of that file's content.
  # -z emits the raw bytes git accepts as a pathspec, fixing both halves.
  #
  # A scalar `$(...)` capture CANNOT hold a NUL-delimited list — bash drops the
  # NULs and the paths run together into one string. Hence the
  # `while IFS= read -r -d ''` array loops throughout.
  #
  # Arrays are also why the dedupe/exclusion pass below is hand-rolled rather
  # than awk: this hook runs on macOS's BSD awk, which does NOT honour
  # RS="\0" (verified — it stops at the first NUL), so the previous
  # `awk 'NF && !seen[$0]++'` has no NUL-safe equivalent here.
  #
  # Do NOT "fix" this by setting core.quotePath: it is user config the hook
  # must never mutate.

  # Tracked files that differ between base and the working tree (committed,
  # staged, and unstaged changes all surface in a single `git diff <base>`).
  local -a tracked_files=()
  local _cf_tf
  if [ -n "$own_ranges" ]; then
    # Union of every attributed range plus the uncommitted working tree.
    while IFS= read -r -d '' _cf_tf; do
      [ -n "$_cf_tf" ] && tracked_files+=("$_cf_tf")
    done < <( {
      expand_own_ranges "$own_ranges" "" diff --name-only -z
      git diff --name-only -z HEAD 2>/dev/null || true
    } )
  else
    while IFS= read -r -d '' _cf_tf; do
      [ -n "$_cf_tf" ] && tracked_files+=("$_cf_tf")
    done < <(git diff --name-only -z "$base" 2>/dev/null || true)
  fi

  # Untracked files not covered by .gitignore.
  local -a untracked_files=()
  local _cf_uf
  while IFS= read -r -d '' _cf_uf; do
    [ -n "$_cf_uf" ] && untracked_files+=("$_cf_uf")
  done < <(git ls-files --others --exclude-standard -z 2>/dev/null || true)

  # Combine; dedupe by path. Untracked entries should not overlap tracked
  # (git would report a path as one OR the other, not both), but the
  # `_cf_seen` membership check below makes the single-entry-per-path
  # invariant explicit. (D278 replaced the awk `!seen[$0]++` pass this
  # comment used to describe — see the -z note above for why awk cannot do
  # the job on a NUL-delimited list.)
  #
  # Exclude the hook's OWN bookkeeping artifacts (D67): the upload-state file
  # and the on-disk snapshot live at the project/repo root and otherwise pass
  # both nets — .stride-diff-upload-state as an untracked entry, and either of
  # them as a tracked diff once a project's after_doing auto-commit has staged
  # them. git's name-only/ls-files output is repo-root-relative, so the exact
  # whole-line match anchors to the ROOT artifacts only; a same-named file in a
  # subdirectory (e.g. sub/.stride-changed-files.json) has a path prefix and is
  # still captured.
  # (W1457) Also hard-exclude by name: .stride.md (the hook script itself,
  # routinely dirty in working repos), .stride_auth.md (credentials — must
  # NEVER be uploaded, tracked, untracked, or edited), and the claim-time
  # dirty-baseline state file (a hook artifact like the two above).
  # (W1609) Hard-exclude the whole root-level .stride/ state directory — it
  # holds hook-internal artifacts (the orchestrator marker, the canonical
  # .last-api-response.json capture) that are gitignored in real projects but
  # must never appear in a task's changed_files even in repos that forgot to
  # ignore them.
  local -a all_files=()
  local _cf_seen=$'\n'
  local _cf_cand
  for _cf_cand in ${tracked_files[@]+"${tracked_files[@]}"} ${untracked_files[@]+"${untracked_files[@]}"}; do
    [ -n "$_cf_cand" ] || continue
    case "$_cf_cand" in
      .stride-diff-upload-state|.stride-changed-files.json|.stride-dirty-baseline|.stride.md|.stride_auth.md) continue ;;
      .stride/*) continue ;;
    esac
    # Dedupe. The membership index is a newline-delimited string because bash
    # 3.2 has no associative arrays and no variable can hold a NUL. A path
    # containing a literal newline therefore dedupes imprecisely — the same
    # limit the awk pass had, and the entry is still captured correctly.
    case "$_cf_seen" in
      *$'\n'"$_cf_cand"$'\n'*) continue ;;
    esac
    _cf_seen="${_cf_seen}${_cf_cand}"$'\n'
    all_files+=("$_cf_cand")
  done

  if [ "${#all_files[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  # numstat for tracked changes — used to detect binaries among tracked files
  # via the `- - <path>` marker. Untracked files are not in numstat; their
  # binary detection runs separately on file contents.
  # (D278) Binary detection reads `--numstat -z` and collects the set of binary
  # paths up front. The -z form is not just the non--z form with NULs: for a
  # RENAME git emits THREE NUL tokens — "<added>TAB<deleted>TAB" (no path), then
  # the old path, then the new path — where an ordinary entry is a single
  # "<added>TAB<deleted>TAB<path>" token. The previous fixed-three-field TAB scan
  # could never match a renamed file, so a renamed BINARY escaped the
  # placeholder and leaked a raw "Binary files ... differ" body. This walk
  # advances variably and records the NEW path, which is the one the snapshot
  # lists. (Ported from stride-hook.ps1 Get-NumstatBinarySet.)
  local -a binary_paths=()
  local _cf_ns _cf_ns_added _cf_ns_rest _cf_ns_deleted _cf_ns_path
  local _cf_ns_isbin=0 _cf_ns_state=0
  while IFS= read -r -d '' _cf_ns; do
    case "$_cf_ns_state" in
      1) _cf_ns_state=2; continue ;;
      2) _cf_ns_state=0
         [ "$_cf_ns_isbin" -eq 1 ] && binary_paths+=("$_cf_ns")
         continue ;;
    esac
    _cf_ns_added="${_cf_ns%%	*}"
    _cf_ns_rest="${_cf_ns#*	}"
    _cf_ns_deleted="${_cf_ns_rest%%	*}"
    _cf_ns_path="${_cf_ns_rest#*	}"
    if [ "$_cf_ns_added" = "-" ] && [ "$_cf_ns_deleted" = "-" ]; then
      _cf_ns_isbin=1
    else
      _cf_ns_isbin=0
    fi
    if [ -z "$_cf_ns_path" ]; then
      _cf_ns_state=1
    elif [ "$_cf_ns_isbin" -eq 1 ]; then
      binary_paths+=("$_cf_ns_path")
    fi
  done < <( if [ -n "$own_ranges" ]; then
      expand_own_ranges "$own_ranges" "" diff --numstat -z
      git diff --numstat -z HEAD 2>/dev/null || true
    else
      git diff --numstat -z "$base" 2>/dev/null || true
    fi )

  local jsonl_file
  jsonl_file=$(mktemp)

  # (W1457) Claim-time dirty baseline: paths that were already modified or
  # untracked when the task was claimed are excluded from the snapshot
  # UNLESS the file changed again after claim (blob hash differs). When in
  # doubt — unhashable, deleted-after-claim, hash mismatch — include: one
  # extra diff beats silently losing task work. A missing/empty baseline
  # (older claim, non-git dir) falls back to the unfiltered behavior.
  local _baseline_file="${PROJECT_DIR:-.}/.stride-dirty-baseline"

  # (D142) Paths that differ between base and HEAD are COMMITTED task work —
  # the task's auto-commit contains them, so the baseline filter below must
  # never drop them. D137 silently lost 4 tracked edits and an untracked
  # migration exactly this way: they were dirty at claim time, the auto-commit
  # committed that same content, and the unchanged-since-claim blob hash then
  # excluded them from the snapshot.
  local -a committed_range=()
  local _cf_cr
  while IFS= read -r -d '' _cf_cr; do
    [ -n "$_cf_cr" ] && committed_range+=("$_cf_cr")
  done < <( if [ -n "$own_ranges" ]; then
      expand_own_ranges "$own_ranges" "" diff --name-only -z
    else
      git diff --name-only -z "$base" HEAD 2>/dev/null || true
    fi )

  local file
  for file in ${all_files[@]+"${all_files[@]}"}; do
    [ -z "$file" ] && continue

    if [ -s "$_baseline_file" ]; then
      local _bl _bl_hash _bl_path _cur_hash _bl_excluded=0
      while IFS= read -r _bl; do
        _bl_hash="${_bl%% *}"
        _bl_path="${_bl#* }"
        if [ "$_bl_path" = "$file" ]; then
          if [ -f "$file" ]; then
            _cur_hash=$(git hash-object -- "$file" 2>/dev/null || echo "unhashable-now")
          else
            _cur_hash="absent"
          fi
          if [ "$_cur_hash" = "$_bl_hash" ] && [ "$_bl_hash" != "unhashable" ]; then
            _bl_excluded=1
          fi
          break
        fi
      done < "$_baseline_file"
      # (D142) Committed-range override: a path the task's commits contain is
      # task work by definition — never baseline-excluded.
      if [ "$_bl_excluded" -eq 1 ] && [ "${#committed_range[@]}" -gt 0 ]; then
        local _cr
        for _cr in "${committed_range[@]}"; do
          if [ "$_cr" = "$file" ]; then
            _bl_excluded=0
            break
          fi
        done
      fi
      [ "$_bl_excluded" -eq 1 ] && continue
    fi

    # Determine whether this path is in the untracked list (membership lookup,
    # not just empty check — tracked_files and untracked_files were merged
    # above with dedupe).
    local is_untracked=0
    if [ "${#untracked_files[@]}" -gt 0 ]; then
      local u
      for u in "${untracked_files[@]}"; do
        if [ "$u" = "$file" ]; then
          is_untracked=1
          break
        fi
      done
    fi

    local is_binary=0
    local diff_text=""

    if [ "$is_untracked" -eq 1 ]; then
      # Untracked: synthesize a new-file unified patch by diffing the file
      # against /dev/null. `git diff --no-index` exits 1 when files differ —
      # that is the expected path here, so we ignore the exit code and
      # capture whatever stdout it produced. --no-color guards against
      # pager/color being inherited from the user's git config.
      #
      # Binary detection uses git's own determination: when --no-index sees
      # a binary file, it emits "Binary files /dev/null and <path> differ"
      # instead of a unified patch. Sniffing that prefix is more reliable
      # than a NUL-byte grep (bash truncates $'\0' to an empty pattern,
      # which matches every line and falsely flags text files as binary).
      diff_text=$(git diff --no-index --no-color /dev/null "$file" 2>/dev/null)
      # For new files, --no-index emits a header (`diff --git`,
      # `new file mode`, `index ...`) BEFORE the "Binary files ... differ"
      # sentinel line, so we have to check anywhere in the output rather
      # than just the prefix.
      if printf '%s\n' "$diff_text" | grep -q '^Binary files .* differ$'; then
        is_binary=1
      fi
    elif [ "${#binary_paths[@]}" -gt 0 ]; then
      local _bp
      for _bp in "${binary_paths[@]}"; do
        if [ "$_bp" = "$file" ]; then
          is_binary=1
          break
        fi
      done
    fi

    if [ "$is_binary" -eq 1 ]; then
      diff_text="$bin_placeholder"
    else
      if [ "$is_untracked" -eq 0 ]; then
        if [ -n "$own_ranges" ]; then
          # (D236) One patch per attributed range that touched this path, then
          # the uncommitted change on top. A file touched in two runs — the
          # interleaved shape, where the task committed both before and after a
          # nested task's window — legitimately yields two patches; each is a
          # complete unified diff with its own header, and together they are
          # exactly this task's change to the file and nothing else. A file
          # both this task and a nested task touched shows only THIS task's
          # hunks, which is the whole point.
          diff_text=$( {
            expand_own_ranges "$own_ranges" "$file" diff
            git diff HEAD -- "$file" 2>/dev/null || true
          } )
        else
          # Tracked: working-tree diff vs base (committed + staged + unstaged
          # changes all in one diff).
          diff_text=$(git diff "$base" -- "$file" 2>/dev/null || printf '')
        fi
      fi
      # diff_text for untracked was already captured above.
      # (D279) Count lines with wc, NOT by substituting the newlines out.
      # `${diff_text//$'\n'/}` builds a second copy of the whole diff, and on a
      # long line bash's substitution goes quadratic: MEASURED on a 200KB
      # single-line diff, the count alone took 37,063 ms while the git call
      # that produced the diff took 34 ms, the binary probe 30 ms and the jq
      # encode 35 ms. A 400KB diff never finished inside the 120s after_doing
      # budget, so the hook was killed and the snapshot lost silently — the
      # completion still succeeded and Review simply showed no diffs.
      #
      # The blowup needs newlines to be PRESENT, which is why this hid for so
      # long: the same substitution over a 400KB string containing NO newline
      # runs in 112 ms. A minified bundle, a single-line lockfile or a base64
      # asset is a handful of newlines in a very long line — exactly the shape
      # that is slowest.
      #
      # `printf '%s\n' | wc -l | tr -d ' '` is the idiom this file already
      # uses in four other places; the tr strips the leading pad BSD wc emits.
      # It is arithmetically identical to the old expression — newline count
      # plus one — because printf appends the terminator wc counts on: verified
      # equal for empty, one-line, trailing-newline, no-trailing-newline, and
      # at the 499/500/501/750 truncation boundaries. Same count, 30 ms.
      local line_count=0
      if [ -n "$diff_text" ]; then
        line_count=$(printf '%s\n' "$diff_text" | wc -l | tr -d ' ')
      fi
      if [ "$line_count" -gt "$max_lines" ]; then
        local truncated
        truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
        diff_text="${truncated}
${trunc_marker}"
      fi
    fi

    jq -n --arg path "$file" --arg diff "$diff_text" '{path: $path, diff: $diff}' >> "$jsonl_file"
  done

  if [ -s "$jsonl_file" ]; then
    jq -s '.' < "$jsonl_file"
  else
    printf '[]\n'
  fi
  rm -f "$jsonl_file"
}

# (W1457) Record the claim-time dirty baseline: every path already modified
# (vs the fresh TASK_BASE_REF) or untracked at claim time, with its current
# blob hash, one `<hash> <path>` line each. capture_changed_files consults
# this to exclude pre-existing unrelated edits from completion snapshots —
# unless the file changes again after claim (hash differs → included).
# Persisted on disk (claim and completion can happen in different sessions)
# and cleaned up with the other hook artifacts. Best-effort: any failure
# leaves an absent/empty baseline, which capture treats as "no exclusion".
record_dirty_baseline() {
  local _base="$1"
  local _bl_file="$PROJECT_DIR/.stride-dirty-baseline"
  rm -f "$_bl_file" 2>/dev/null || true
  command -v git > /dev/null 2>&1 || return 0
  [ -n "$_base" ] || return 0
  # (D278) -z here too, and for a reason beyond this function's own
  # correctness: capture_changed_files string-compares each baseline path
  # against its own now-RAW path. Left quoted, the two spellings could never
  # match for a non-ASCII path, so the W1457 pre-existing-edit filter would go
  # silently inert for exactly those files — fixing the capture alone would
  # have introduced that. The file stays `<hash> <path>` newline-delimited;
  # only the spelling of <path> changes.
  #
  # (D286) The divergence this comment used to record is CLOSED. For one window
  # the two executors disagreed here: bash recorded the baseline RAW and
  # captured RAW, while the PowerShell twin's Write-DirtyBaseline still listed
  # WITHOUT -z, recording QUOTED against its own RAW capture (W2100) and leaving
  # the W1457 filter inert for non-ASCII paths on Windows only. That was a
  # follow-up rather than a bash-side fix, and D286 closed it: Write-DirtyBaseline
  # now lists with -z and splits on NUL through the same Split-NulList this side
  # mirrors. Both executors record RAW and capture RAW.
  #
  # The pair must stay in step. Fixing one side alone is what created the
  # divergence in the first place, and the failure it produced was silent —
  # over-report is the safe direction, so nothing was ever loud about it.
  local -a _paths=()
  local _p _h
  while IFS= read -r -d '' _p; do
    [ -n "$_p" ] && _paths+=("$_p")
  done < <( (cd "$PROJECT_DIR" 2>/dev/null && {
    git diff --name-only -z "$_base" 2>/dev/null
    git ls-files --others --exclude-standard -z 2>/dev/null
  }) || true )
  [ "${#_paths[@]}" -gt 0 ] || return 0
  for _p in "${_paths[@]}"; do
    [ -z "$_p" ] && continue
    if [ -f "$PROJECT_DIR/$_p" ]; then
      _h=$( (cd "$PROJECT_DIR" && git hash-object -- "$_p") 2>/dev/null || echo "unhashable")
    else
      _h="absent"
    fi
    printf '%s %s\n' "$_h" "$_p" >> "$_bl_file" 2>/dev/null || true
  done
  return 0
}

# (D142) Trust guard for the snapshot base ref. TASK_BASE_REF is supposed to
# be the task branch point — the commit HEAD pointed at right after the
# ## before_doing section finished (post-pull). A value inherited from a
# previous task or session can predate commits that arrived via the
# before_doing pull; diffing from it would span ANOTHER clone's completed
# task (the D132/W1678 incident). Rules, in order:
#   1. empty or unresolvable base            → recompute from the branch point
#   2. base is not an ancestor of HEAD       → recompute (e.g. rebased away)
#   3. base is a STRICT ancestor of the task branch point → recompute — the
#      range base..HEAD would include commits pulled from origin. A plain
#      is-ancestor-of-HEAD check cannot catch this: the D132 stale base WAS
#      an ancestor of HEAD.
# "Task branch point" = merge-base of HEAD and the origin default branch.
# Without an origin branch there is no branch point to judge against (and no
# cross-clone pull is possible), so the base passes through unchanged and
# capture_changed_files keeps its own HEAD~1 fallback. Recomputes are
# announced on stderr — never silently. Prints the base to use on stdout.
resolve_snapshot_base() {
  local _base="${1:-}" _bp="" _remote_head="" _c _reason="" _base_sha=""
  if ! command -v git > /dev/null 2>&1 \
    || ! git rev-parse --verify --quiet HEAD > /dev/null 2>&1; then
    printf '%s' "$_base"
    return 0
  fi
  _remote_head=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  _remote_head="${_remote_head#refs/remotes/}"
  if [ -z "$_remote_head" ]; then
    for _c in origin/main origin/master; do
      if git rev-parse --verify --quiet "$_c" > /dev/null 2>&1; then
        _remote_head="$_c"
        break
      fi
    done
  fi
  [ -n "$_remote_head" ] && _bp=$(git merge-base HEAD "$_remote_head" 2>/dev/null || true)
  if [ -z "$_bp" ]; then
    printf '%s' "$_base"
    return 0
  fi

  if [ -z "$_base" ] || ! _base_sha=$(git rev-parse --verify --quiet "$_base^{commit}" 2>/dev/null); then
    _reason="empty or unresolvable"
  elif ! git merge-base --is-ancestor "$_base_sha" HEAD 2>/dev/null; then
    _reason="not an ancestor of HEAD"
  elif [ "${TASK_BASE_REF_TRUSTED:-}" != "1" ] \
    && [ "$_base_sha" != "$_bp" ] \
    && git merge-base --is-ancestor "$_base_sha" "$_bp" 2>/dev/null; then
    # Rule 3 judges only INHERITED bases (no trust marker): a base the
    # current claim's post-before_doing capture wrote IS the branch point by
    # construction, and origin/main may legitimately have advanced past it
    # when the workflow pushes its own task commits before completing.
    _reason="older than the task branch point, so the diff would span commits pulled from origin"
  fi
  if [ -z "$_reason" ]; then
    printf '%s' "$_base"
    return 0
  fi
  printf 'stride-hook: TASK_BASE_REF %s is not trustworthy (%s); recomputed the snapshot base from the task branch point: %s\n' \
    "${_base:-<empty>}" "$_reason" "$_bp" >&2
  printf '%s' "$_bp"
}

# Helper: resolve the Stride API base URL for the changed_files upload.
# Primary source is $PROJECT_DIR/.stride_auth.md (the same file the agent
# reads) — its `**API URL:** `<url>`` line. Falls back to a literal URL in the
# intercepted $COMMAND for back-compat when the auth file is absent. Prints the
# URL (or empty) on stdout.
resolve_stride_api_url() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _url=""
  if [ -f "$_auth" ]; then
    _url=$(grep -E '\*\*API URL:\*\*' "$_auth" | grep -oE 'https?://[A-Za-z0-9._:/-]+' | head -n 1 || true)
  fi
  if [ -z "$_url" ]; then
    _url=$(printf '%s' "${COMMAND:-}" | grep -oE 'https?://[A-Za-z0-9._-]+(:[0-9]+)?' | head -n 1 || true)
  fi
  printf '%s' "$_url"
}

# Helper: resolve the Stride API bearer token for the changed_files upload.
# Primary source is the production `**API Token:** `<token>`` line in
# $PROJECT_DIR/.stride_auth.md — deliberately NOT the `**Local API Token:**`
# line (the `**API Token:**` pattern does not match `**Local API Token:**`).
# Falls back to a literal `Bearer <token>` in the intercepted $COMMAND. Prints
# the token (or empty) on stdout; never logs it.
resolve_stride_api_token() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _tok=""
  if [ -f "$_auth" ]; then
    _tok=$(grep -E '\*\*API Token:\*\*' "$_auth" | grep -oE '`[^`]+`' | head -n 1 | tr -d '`' || true)
  fi
  if [ -z "$_tok" ]; then
    _tok=$(printf '%s' "${COMMAND:-}" | grep -oE 'Bearer +[A-Za-z0-9._+/=-]+' | head -n 1 | sed 's/^Bearer  *//' || true)
  fi
  printf '%s' "$_tok"
}

# Helper: PUT the on-disk snapshot ($PROJECT_DIR/.stride-changed-files.json)
# to /api/tasks/<id>/changed_files. We send the transport-encoded envelope
# {"changed_files":{"encoding":"base64","data":"<b64>"}} rather than the raw
# array so an edge request filter does not misread a code diff as an attack
# and drop the upload (D61). The server decodes it back to the same list. The
# base64 MUST be single-line so the value is valid inside the JSON string
# (strip any wrap newlines). When base64 is unavailable we fall back to the
# raw {"changed_files":[...]} shape — a bare top-level array would land at
# params['_json'] and persist as NULL. Prints the HTTP code on stdout ('000'
# on transport failure), warns on stderr for non-2xx, always returns 0.
# Shared by finalize_after_doing and the before_review self-heal (W1094) —
# callers MUST capture stdout or the code would leak into the hook's
# structured-JSON stdout contract.
upload_changed_files_snapshot() {
  local _task_id="$1" _api_base="$2" _token="$3"
  local _b64="" _http_code
  if command -v base64 > /dev/null 2>&1; then
    _b64=$(base64 < "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
  fi

  if [ -n "$_b64" ]; then
    _http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $_token" \
      -H 'Content-Type: application/json' \
      -d "{\"changed_files\":{\"encoding\":\"base64\",\"data\":\"$_b64\"}}" \
      "$_api_base/api/tasks/$_task_id/changed_files" 2>/dev/null || printf '000')
  else
    _http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $_token" \
      -H 'Content-Type: application/json' \
      -d "{\"changed_files\":$(cat "$PROJECT_DIR/.stride-changed-files.json")}" \
      "$_api_base/api/tasks/$_task_id/changed_files" 2>/dev/null || printf '000')
  fi

  # Surface a failed upload instead of dropping it silently. The diff is
  # non-fatal to completion, so we warn rather than abort.
  case "$_http_code" in
    2*) : ;;
    *)
      printf 'stride-hook: changed_files upload failed (HTTP %s) for task %s\n' \
        "$_http_code" "$_task_id" >&2
      ;;
  esac
  printf '%s' "$_http_code"
  return 0
}

# Helper: record the outcome of a changed_files PUT attempt (W1094) so the
# before_review self-heal can verify it on a fresh timeout budget. Task id,
# HTTP code, and (D142) the trust-guard-resolved snapshot base ONLY — never
# the URL or bearer token (the file lives untracked in the project root
# alongside the other .stride artifacts). The base lets the self-heal reuse
# the after_doing-time judgment instead of re-resolving against origin refs
# the section's own `git push` may have moved.
record_diff_upload_state() {
  {
    printf 'task_id=%s\n' "$1"
    printf 'http_code=%s\n' "$2"
    if [ -n "${3:-}" ]; then
      printf 'base=%s\n' "$3"
    fi
  } > "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
}

# --- Bash-command routing (D220) ---
# Decide which .stride.md lifecycle section a Claude Code Bash tool call should
# run. THE COMMAND TEXT IS UNTRUSTED ROUTING INPUT: a changed_files PUT carries a
# raw code diff, and a heredoc writing documentation can contain the completion
# curl verbatim, so "the string contains /api/tasks/<id>/complete" is not
# evidence that the call IS a completion. Before D220 it was treated as such, and
# a plain `echo`, a `grep`, and a python heredoc each ran real
# commit/checkout/merge/branch-delete sections and drove a live API write against
# an id scraped out of prose.
#
# Routing now requires ALL of:
#   1. curl/wget in COMMAND position of a shell segment — outside every quoted
#      string and outside every heredoc body;
#   2. the endpoint as the TAIL of a URL in an ARGUMENT position of that client
#      (option values for -d/-H/-o/... are consumed, so a payload cannot supply
#      the request URL);
#   3. an HTTP method consistent with the endpoint (claim POST; complete and
#      mark_reviewed PATCH or POST) — the guard that keeps a
#      PUT .../changed_files whose diff mentions a completion URL from routing as
#      a completion, and that drops a bare GET probe of /complete.
#
# Deliberately lenient where a miss would be SILENT: an unresolvable method
# (-X "$METHOD") is allowed WHEN the call also carries a body, because a
# completion that quietly stops firing after_doing removes the quality gate
# entirely. Everything it cannot parse routes NOWHERE: running the wrong section
# runs real git state changes, running none only misses a gate.
#
# ACCEPTED MISSES — forms that DO issue a lifecycle request but route nowhere.
# All fail closed, none is reachable from payload or diff text, and each is a
# decision rather than an oversight:
#   * a lifecycle call made by anything but curl/wget — `bash -c 'curl …'`,
#     `echo $URL | xargs curl`, python/requests;
#   * a URL assembled by command substitution, e.g. "$(echo $U)/api/tasks/1/complete";
#   * a URL variable ASSIGNED TWICE in one command — which branch bash took is
#     not knowable here, and guessing decides both the section and the task the
#     changed_files diff is PUT to, so resolution is declined outright;
#   * wget's `-c -r -b -E -x -K`, which take no value there but do in curl, so
#     one placed immediately before the URL swallows it. Keying the option table
#     off the client would double the surface that must stay byte-identical
#     between this file and the .ps1 mirror;
#   * an arithmetic left shift on a line BEFORE the call, `V=$((1<<3))`: the
#     heredoc walk reads `<<` outside quotes as an opener and swallows to the
#     matching word. (On the SAME line it is harmless — opener lines are kept.)

# Advance $_SR_Q ("" | sq | dq) across the quote characters of $1. With a second
# argument, stop as soon as the state returns to "" and leave the unconsumed
# remainder in $_SR_REST (lets the scanner skip a multi-line payload in one
# call).
#
# Backslash escapes ARE modelled, and must be: outside single quotes a backslash
# escapes the next character, so a JSON payload's \" does NOT close the enclosing
# double quote. Ignoring that flips the tracker OUT of quoting on an odd number
# of \" and lets payload text be scanned as syntax — a FAIL-OPEN bug that
# re-enables the original D220 misroute for a -d value placed before the URL.
_stride_quotes() {
  _q_r="$1"
  _q_stop="${2:-}"
  _SR_REST=""
  case "$_q_r" in *\'*|*\"*|*\\*) : ;; *) return 0 ;; esac
  # A huge token (an inline JSON payload) is first collapsed so the loop stays
  # O(specials^2) instead of O(bytes*specials). Every run of ordinary characters
  # becomes a single '.', which preserves ADJACENCY — the one property escape
  # handling depends on — where a quote-only reduction would falsely make a
  # backslash adjacent to a later quote. Measured worst case: an 82 KB inline
  # payload carrying 8000 quote characters costs ~2.5s here (0.7s in the ps1
  # mirror, which can scan characters directly). Ordinary commands cost ~10ms,
  # and the /api/tasks/ fast path in stride_route_command means the vast
  # majority never reach this function at all.
  if [ -z "$_q_stop" ] && [ "${#_q_r}" -gt 512 ]; then
    _q_r=$(printf '%s' "$_q_r" | sed "s/[^\"'\\\$]\{1,\}/./g")
  fi
  while :; do
    case "$_q_r" in *\'*|*\"*|*\\*) : ;; *) break ;; esac
    # Whichever of ' " \ comes first is the next significant character.
    # Comparing %%-trimmed prefix lengths avoids a bracket set containing quotes.
    _q_a="${_q_r%%\'*}"
    _q_b="${_q_r%%\"*}"
    _q_e="${_q_r%%\\*}"
    _q_c="'"; _q_n="${#_q_a}"
    if [ "${#_q_b}" -lt "$_q_n" ]; then _q_c='"'; _q_n="${#_q_b}"; fi
    if [ "${#_q_e}" -lt "$_q_n" ]; then _q_c='\'; _q_n="${#_q_e}"; fi
    case "$_q_c" in
      "'") _q_r="${_q_r#"$_q_a"?}" ;;
      '"') _q_r="${_q_r#"$_q_b"?}" ;;
      *)   _q_r="${_q_r#"$_q_e"?}" ;;
    esac
    case "$_SR_Q" in
      "")  case "$_q_c" in
             # $'...' is ANSI-C quoting, where \' does NOT close the string —
             # treating it as a plain '...' exits quoting early and lets the rest
             # of the token be scanned as syntax.
             "'") case "$_q_a" in *\$) _SR_Q=aq ;; *) _SR_Q=sq ;; esac ;;
             '"') _SR_Q=dq ;;
             *)   _q_r="${_q_r#?}" ;;    # unquoted \x — x is literal, never syntax
           esac ;;
      sq)  case "$_q_c" in "'") _SR_Q="" ;; esac ;;   # no escapes inside ' '
      aq)  case "$_q_c" in
             "'") _SR_Q="" ;;
             '\') _q_r="${_q_r#?}" ;;     # \' inside $'...' does NOT close it
           esac ;;
      *)   case "$_q_c" in
             '"') _SR_Q="" ;;
             '\') _q_r="${_q_r#?}" ;;     # \" inside " " does NOT close it
           esac ;;
    esac
    if [ -n "$_q_stop" ] && [ -z "$_SR_Q" ]; then
      _SR_REST="$_q_r"
      return 0
    fi
  done
  return 0
}

# Record NAME=VALUE seen in command position, but only when VALUE names the API —
# the list stays at zero or one entry in practice, so the lookup below is cheap.
_stride_record_var() {
  _rv_n="${1%%=*}"
  _rv_v="${1#*=}"
  while :; do case "$_rv_v" in \"*|\'*) _rv_v="${_rv_v#?}" ;; *) break ;; esac; done
  while :; do case "$_rv_v" in *\"|*\'|*\;) _rv_v="${_rv_v%?}" ;; *) break ;; esac; done
  # A SECOND assignment to the same name means the effective value depends on
  # control flow we do not evaluate (`if …; then URL=A; else URL=B; fi`). Record
  # an empty sentinel so the lookup declines to resolve rather than guessing
  # which branch bash took — that guess decides both which section runs and
  # which task the changed_files diff is PUT to. Declining means the URL token
  # keeps its literal `$NAME` form, which carries no /api/tasks/, so NO section
  # fires at all — not "the right section with a fallback id". That is the
  # deliberate fail-closed trade: a reassigned URL variable loses the gate.
  #
  # EVERY name is recorded, even when its value does not name the API, so the
  # sentinel is order-INDEPENDENT. Recording only API-valued names made it fire
  # for (api, other) but not for (other, api) — and the second ordering is the
  # common one (`if $DRY; then URL=noop; else URL=…/complete; fi`), which would
  # resolve and run commit/checkout/merge for a call that issued nothing.
  case "$_SR_NL$_s_vars" in
    *"$_SR_NL$_rv_n="*) _s_vars="$_rv_n=$_SR_NL$_s_vars"; return 0 ;;
  esac
  case "$_rv_v" in */api/tasks/*) : ;; *) _rv_v="" ;; esac
  # PREPEND so the lookup below finds the most recent assignment first.
  _s_vars="$_rv_n=$_rv_v$_SR_NL$_s_vars"
  return 0
}

# Print the recorded value of variable $1, or nothing.
_stride_var() {
  _lv_r="$_s_vars"
  while [ -n "$_lv_r" ]; do
    _lv_e="${_lv_r%%"$_SR_NL"*}"
    _lv_r="${_lv_r#"$_lv_e"}"
    _lv_r="${_lv_r#"$_SR_NL"}"
    case "$_lv_e" in "$1="*) printf '%s' "${_lv_e#*=}"; return 0 ;; esac
  done
  return 0
}

# Derive the heredoc delimiter from the text following `<<` (and any `-`),
# applying bash's word splitting AND quote removal in ONE pass.
#
# Both halves have to happen together. Splitting the word first and unquoting
# after cuts `<<'A B'` and `<<a\ b` at a QUOTED space, and cannot see the `$` of
# `$'…'` or `$"…"`; a delete-all-quotes reduction loses what a backslash escapes,
# so `<<E\'F` becomes EF. Every one of those yields a SHORTER delimiter than
# bash's — and a shorter delimiter can match a body line BEFORE bash's real
# terminator, ending the body early and leaving the rest of it, which is data in
# bash, to be scanned as syntax. That is fail-OPEN, not mere truncation.
#
# Sets _HD_D (delimiter), _HD_REST (unconsumed remainder) and _HD_ANY (1 when a
# word was present at all, so `<<''` still queues an empty delimiter — whose body
# ends at the first empty line — while `<< ;` queues nothing).
_stride_hd_delim() {
  _hd_i="$1"
  _HD_D=""; _HD_REST=""; _HD_ANY=0; _HD_UNSAFE=0
  _hd_st=""
  while [ -n "$_hd_i" ]; do
    _hd_c="${_hd_i%"${_hd_i#?}"}"
    _hd_i="${_hd_i#?}"
    case "$_hd_st" in
      sq) if [ "$_hd_c" = "'" ]; then _hd_st=""; else _HD_D="$_HD_D$_hd_c"; fi ;;
      aq) case "$_hd_c" in
            "'") _hd_st="" ;;
            # Inside $'…' bash INTERPRETS escape sequences: \n is a newline, \x41
            # is A. We do not implement that table. For \' \" \\ the ANSI-C
            # meaning IS the next character, so those agree; anything else would
            # render SHORTER than bash's delimiter, which dequeues the body early
            # — fail-open. Mark the word unsafe instead, so it never terminates
            # and the body is swallowed to EOF: fail-closed, like every other
            # form we cannot parse.
            '\') _hd_n="${_hd_i%"${_hd_i#?}"}"
                 case "$_hd_n" in
                   "'"|'"'|'\') : ;;
                   *) _HD_UNSAFE=1 ;;
                 esac
                 _HD_D="$_HD_D$_hd_n"; _hd_i="${_hd_i#?}" ;;
            *)   _HD_D="$_HD_D$_hd_c" ;;
          esac ;;
      dq) case "$_hd_c" in
            '"') _hd_st="" ;;
            # Inside " " bash removes the backslash ONLY before $ ` " \ and
            # newline; anywhere else both characters survive.
            '\') _hd_n="${_hd_i%"${_hd_i#?}"}"
                 case "$_hd_n" in
                   '$'|'`'|'"'|'\') _HD_D="$_HD_D$_hd_n"; _hd_i="${_hd_i#?}" ;;
                   *) _HD_D="$_HD_D\\" ;;
                 esac ;;
            *)   _HD_D="$_HD_D$_hd_c" ;;
          esac ;;
      *)  case "$_hd_c" in
            ' '|'	'|';'|'|'|'&'|'('|')'|'<'|'>')
              _HD_REST="$_hd_c$_hd_i"; return 0 ;;
          esac
          _HD_ANY=1
          case "$_hd_c" in
            '\') _HD_D="$_HD_D${_hd_i%"${_hd_i#?}"}"; _hd_i="${_hd_i#?}" ;;
            "'") _hd_st=sq ;;
            '"') _hd_st=dq ;;
            '$') case "$_hd_i" in
                   \'*) _hd_st=aq; _hd_i="${_hd_i#?}" ;;
                   \"*) _hd_st=dq; _hd_i="${_hd_i#?}" ;;
                   *)   _HD_D="$_HD_D\$" ;;
                 esac ;;
            *)   _HD_D="$_HD_D$_hd_c" ;;
          esac ;;
    esac
  done
  _HD_REST=""
  return 0
}

# Print $1 with every heredoc BODY removed. The opening line is KEPT (a curl can
# legitimately read its payload from `-d @- <<'JSON'`); everything up to and
# including the delimiter line is dropped. This is what stops an agent writing
# documentation ABOUT the completion curl from being routed as one — a doc line
# inside a heredoc sits at column 0 with clean quote state, so it satisfies every
# other requirement.
_stride_strip_heredocs() {
  printf '%s\n' "$1" | (
    # FIFO of pending "<dash>:<delimiter>" entries. A queue, not a single value:
    # bash allows several openers on one line (`cat <<A > x; cat <<B > y`) and
    # consumes their bodies in order, so tracking only the first leaves the
    # second body to be scanned as syntax.
    _hd_q=""
    # Quote state carried across lines, so a `<<` inside a string is not read as
    # an opener. Separate from the scanner's own $_SR_Q run: the two run in
    # different subshells of the pipeline below.
    _hd_state=""
    while IFS= read -r _hd_line; do
      if [ -n "$_hd_q" ]; then
        _hd_e="${_hd_q%%
*}"
        _hd_dash="${_hd_e%%:*}"
        _hd_delim="${_hd_e#*:}"
        _hd_t="$_hd_line"
        # dash "2" marks a delimiter we could not derive exactly (ANSI-C escapes
        # we do not interpret). It never matches, so the body is swallowed to
        # EOF — fail-closed, rather than dequeuing early on a rendering that is
        # not bash's and exposing the rest of the body to the scanner.
        if [ "$_hd_dash" = 2 ]; then continue; fi
        # bash strips only TABS for <<- ; stripping spaces too would let a
        # space-indented lookalike end the body early for us but not for bash.
        if [ -n "$_hd_dash" ]; then _hd_t="${_hd_t#"${_hd_t%%[!	]*}"}"; fi
        if [ "$_hd_t" = "$_hd_delim" ]; then
          _hd_q="${_hd_q#"$_hd_e"}"
          _hd_q="${_hd_q#
}"
        fi
        continue
      fi
      printf '%s\n' "$_hd_line"
      # Walk the line left to right. A positional scan, because `<<<` is a
      # here-string that must skip only ITSELF — testing the whole line and
      # skipping it wholesale lets a real heredoc on the same line go
      # unregistered.
      # The walk is QUOTE-AWARE: a `<<` inside a string is text (`echo "shift <<
      # END"`, `cout << x`), and treating it as an opener swallows lines until
      # one happens to equal the derived word — which can eat the opening quote
      # of a later payload and desynchronise the scanner's own tracker, or eat a
      # real completion curl and silently drop the after_doing gate.
      _hd_r="$_hd_line"
      while :; do
        case "$_hd_r" in *'<<'*) : ;; *) break ;; esac
        _hd_pre="${_hd_r%%<<*}"
        _SR_Q="$_hd_state"; _stride_quotes "$_hd_pre"; _hd_state="$_SR_Q"
        _hd_r="${_hd_r#*<<}"
        if [ -n "$_hd_state" ]; then continue; fi
        case "$_hd_r" in '<'*) _hd_r="${_hd_r#<}"; continue ;; esac
        case "$_hd_r" in -*) _hd_dash=1; _hd_r="${_hd_r#-}" ;; *) _hd_dash="" ;; esac
        _hd_a="${_hd_r#"${_hd_r%%[! 	]*}"}"
        _stride_hd_delim "$_hd_a"
        _hd_r="$_HD_REST"
        # Guard on "a word was present", not on the derived text: `<<''` and
        # `<<""` are valid heredocs whose body ends at the first EMPTY line.
        # Guarding on the derived text drops them entirely, leaving the body to
        # be scanned as syntax — the precondition this function exists to remove.
        if [ "$_HD_UNSAFE" -eq 1 ]; then _hd_dash=2; fi
        if [ "$_HD_ANY" -eq 1 ]; then _hd_q="$_hd_q$_hd_dash:$_HD_D
"; fi
      done
      _SR_Q="$_hd_state"; _stride_quotes "$_hd_r"; _hd_state="$_SR_Q"
    done
  )
}

# Start a fresh shell segment (new command position, no client, no URL).
_stride_seg_reset() {
  _s_pos=1; _s_client=""; _s_method=""; _s_implied=""
  _s_ep=""; _s_id=""; _s_urlseen=0; _s_next=""
  return 0
}

# Classify a candidate URL ARGUMENT. Only the FIRST argument-position token that
# contains /api/tasks/ is ever considered ($_s_urlseen), because that is curl's
# own request-URL semantic — so a later bare word inside a payload can neither
# override nor supply a target. The endpoint must be the TAIL of the path (a
# trailing / and a ?query are tolerated), which is why a completion URL embedded
# in a JSON value — {"u":".../complete"} — is not a request target.
_stride_take_url() {
  [ "$_s_urlseen" -eq 0 ] || return 0
  _u_t="$1"
  while :; do
    case "$_u_t" in \"*|\'*|\\*|\(*) _u_t="${_u_t#?}" ;; *) break ;; esac
  done
  while :; do
    case "$_u_t" in *\"|*\'|*\\|*,|*\;|*\)|*\`) _u_t="${_u_t%?}" ;; *) break ;; esac
  done
  # (D220) Pitfall 2 — the URL "may be written in a shell variable rather than as
  # a literal". `URL="$STRIDE_API_URL/api/tasks/$TASK_ID/complete"; curl -X PATCH
  # "$URL"` routed before this change and must keep routing; a silent miss here
  # would remove the after_doing gate entirely.
  case "$_u_t" in
    '$'*)
      _u_n="${_u_t#\$}"; _u_n="${_u_n#\{}"; _u_n="${_u_n%\}}"
      case "$_u_n" in
        "" | *[!A-Za-z0-9_]*) : ;;
        *) _u_v=$(_stride_var "$_u_n"); [ -z "$_u_v" ] || _u_t="$_u_v" ;;
      esac
      ;;
  esac
  case "$_u_t" in */api/tasks/*) : ;; *) return 0 ;; esac
  _s_urlseen=1
  _u_p="${_u_t%%\?*}"; _u_p="${_u_p%%#*}"; _u_p="${_u_p%/}"
  _u_r="${_u_p#*/api/tasks/}"
  if [ "$_u_r" = "claim" ]; then
    _s_ep=claim; _s_id=""
    return 0
  fi
  case "$_u_r" in */*) : ;; *) return 0 ;; esac
  _u_id="${_u_r%%/*}"
  _u_act="${_u_r#*/}"
  case "$_u_act" in complete|mark_reviewed) : ;; *) return 0 ;; esac
  [ -n "$_u_id" ] || return 0
  _s_ep="$_u_act"
  # (D127) Only a NUMERIC id is authoritative; $TASK_ID interpolation leaves it
  # empty and callers fall back to the env cache, exactly as before D220.
  case "$_u_id" in *[!0-9]*) _s_id="" ;; *) _s_id="$_u_id" ;; esac
  return 0
}

# Decide whether the segment accumulated so far is a real lifecycle call.
_stride_seg_eval() {
  [ -n "$_s_client" ] || return 0
  [ -n "$_s_ep" ] || return 0
  _e_m="$_s_method"
  [ -n "$_e_m" ] || _e_m="$_s_implied"
  [ -n "$_e_m" ] || _e_m=GET
  _e_m=$(printf '%s' "$_e_m" | tr -d "\"'" | tr '[:lower:]' '[:upper:]')
  # -X "$METHOD" cannot be resolved statically. Allow it — a silent non-firing
  # after_doing removes the quality gate entirely, which is worse than an
  # over-permissive method — but only when the call also carries a BODY. Every
  # documented lifecycle curl does; a bare read-only probe of the same URL does
  # not, and that probe should not run git commit/checkout/merge.
  case "$_e_m" in
    *'$'*|*'`'*|"")
      if [ -n "$_s_implied" ]; then _e_m=UNKNOWN; else _e_m=GET; fi ;;
  esac
  case "$_s_ep" in
    claim)
      case "$_e_m" in POST|UNKNOWN) : ;; *) return 0 ;; esac ;;
    complete|mark_reviewed)
      case "$_e_m" in PATCH|POST|UNKNOWN) : ;; *) return 0 ;; esac ;;
    *) return 0 ;;
  esac
  _s_hit="$_s_ep:$_s_id"
  return 0
}

# Read heredoc-stripped lines on stdin; print "<endpoint>:<numeric-id>" for the
# first real lifecycle call found, nothing otherwise.
_stride_scan_stream() {
  _SR_Q=""; _s_pend=""; _s_hit=""; _s_vars=""
  _stride_seg_reset
  _s_hadf=0
  case "$-" in *f*) _s_hadf=1 ;; esac
  set -f
  while IFS= read -r _s_line; do
    # A CRLF command would otherwise carry \r into the final token and never
    # match a URL tail (the ps1 mirror splits on \r?\n, so this keeps the two
    # deciding alike).
    _s_line="${_s_line%"$_SR_CR"}"
    # Join backslash continuations FIRST: the documented completion curl spans
    # five physical lines and its URL is not always on the `curl` line.
    case "$_s_line" in *\\) _s_pend="$_s_pend${_s_line%?} "; continue ;; esac
    _s_line="$_s_pend$_s_line"; _s_pend=""

    if [ -n "$_SR_Q" ]; then
      # Inside a multi-line quoted string (a -d '<diff>' payload): no command
      # position exists here. Jump to wherever the quote closes.
      _stride_quotes "$_s_line" stop
      if [ -n "$_SR_Q" ]; then continue; fi
      _s_line="$_SR_REST"
    else
      _stride_seg_eval
      if [ -n "$_s_hit" ]; then break; fi
      _stride_seg_reset
    fi

    # A logical line with no /api/tasks/ can never produce a hit; only its
    # quote-state effect matters. Once a variable holding an API URL has been
    # recorded, though, a later line can name it without mentioning the path.
    case "$_s_line" in
      */api/tasks/*) : ;;
      # A line carrying an assignment must be tokenised even when it names no
      # API path: skipping it hides the FIRST of two assignments, so the second
      # looks like a first, no ambiguity sentinel is recorded, and a
      # branch-dependent URL resolves after all. That is the whole multi-line
      # layout — `if $DRY; then URL=noop; else URL=…/complete; fi` — which the
      # one-line tests cannot reach.
      [A-Za-z_]*=*|*' '[A-Za-z_]*=*|*'	'[A-Za-z_]*=*) : ;;
      *) if [ -z "$_s_vars" ]; then _stride_quotes "$_s_line"; continue; fi ;;
    esac

    set -- $_s_line
    for _s_tok do
      _s_qb="$_SR_Q"
      _stride_quotes "$_s_tok"
      # A token that BEGAN inside a quoted string is payload text, never syntax.
      if [ -n "$_s_qb" ]; then continue; fi

      case "$_s_tok" in
        *'$('*) _s_tok="${_s_tok##*\$\(}"
                _stride_seg_eval
                if [ -n "$_s_hit" ]; then break; fi
                _stride_seg_reset
                if [ -z "$_s_tok" ]; then continue; fi ;;
        *'`'*)  _s_tok="${_s_tok##*\`}"
                _stride_seg_eval
                if [ -n "$_s_hit" ]; then break; fi
                _stride_seg_reset
                if [ -z "$_s_tok" ]; then continue; fi ;;
      esac

      case "$_s_tok" in
        ';'|';;'|'&'|'&&'|'|'|'||'|'|&'|'('|')'|'{'|'}'|'!'|then|else|elif|do|done|fi)
          _stride_seg_eval
          if [ -n "$_s_hit" ]; then break; fi
          _stride_seg_reset
          continue ;;
        *\;*)                       # `cd foo;curl ...` with no space
          # `URL=...;` puts the assignment and the separator in one token, so
          # capture the prefix before discarding it.
          _s_pre="${_s_tok%%\;*}"
          case "$_s_pre" in
            [A-Za-z_]*=*)
              case "${_s_pre%%=*}" in
                *[!A-Za-z0-9_]*) : ;;
                *) _stride_record_var "$_s_pre" ;;
              esac ;;
          esac
          _stride_seg_eval
          if [ -n "$_s_hit" ]; then break; fi
          _stride_seg_reset
          _s_tok="${_s_tok##*\;}"
          if [ -z "$_s_tok" ]; then continue; fi ;;
      esac

      if [ "$_s_pos" -eq 1 ]; then
        # `(curl ...)` in a subshell — the paren opens a new command position.
        # NOT `{`: it is a reserved word requiring a following space, so it
        # already arrives as its own separator token. Stripping it here would
        # only make a syntactically broken `{curl` route.
        while :; do case "$_s_tok" in \(*) _s_tok="${_s_tok#?}" ;; *) break ;; esac; done
        if [ -z "$_s_tok" ]; then continue; fi
        case "$_s_tok" in
          -*) continue ;;                                   # nice -n, timeout -k
          [0-9]*) case "$_s_tok" in *[!0-9smhd.]*) : ;; *) continue ;; esac ;;
        esac
        case "$_s_tok" in                                   # VAR=value prefix
          [A-Za-z_]*=*)
            case "${_s_tok%%=*}" in
              *[!A-Za-z0-9_]*) : ;;
              *) _stride_record_var "$_s_tok"; continue ;;
            esac ;;
        esac
        case "${_s_tok##*/}" in
          env|sudo|command|builtin|exec|nohup|nice|stdbuf|timeout|time|if|while|until)
            continue ;;
          curl|curl.exe|wget|wget.exe)
            _s_client="${_s_tok##*/}"; _s_client="${_s_client%.exe}"
            _s_pos=0; continue ;;
          *)
            _s_pos=0; _s_client=""; continue ;;             # another program owns it
        esac
      fi

      [ -n "$_s_client" ] || continue

      if [ -n "$_s_next" ]; then
        case "$_s_next" in
          method) _s_method="$_s_tok" ;;
          url)    _stride_take_url "$_s_tok" ;;
          *)      : ;;                                      # consumed option value
        esac
        _s_next=""
        continue
      fi

      case "$_s_tok" in
        -X|--request)  _s_next=method; continue ;;
        --url)         _s_next=url; continue ;;
        -G|--get)      _s_method=GET; continue ;;
        --method=*)    _s_method="${_s_tok#--method=}"; continue ;;
        --request=*)   _s_method="${_s_tok#--request=}"; continue ;;
        --url=*)       _stride_take_url "${_s_tok#--url=}"; continue ;;
        -X*)           _s_method="${_s_tok#-X}"; continue ;;
        -d|--data|--data-raw|--data-binary|--data-ascii|--data-urlencode|-F|--form|-T|--upload-file)
          [ -n "$_s_implied" ] || _s_implied=POST
          _s_next=value; continue ;;
        --data=*|--data-raw=*|--data-binary=*|--data-ascii=*|--data-urlencode=*|--post-data*|--post-file*|--body-data*|--body-file*|-d*)
          [ -n "$_s_implied" ] || _s_implied=POST
          continue ;;
        -H|--header|-o|--output|-u|--user|-A|--user-agent|-e|--referer|-b|--cookie|-c|--cookie-jar|-w|--write-out|-m|--max-time|--connect-timeout|--retry|--retry-delay|-x|--proxy|-E|--cert|--key|--cacert|--capath|-K|--config|--resolve|--interface|--limit-rate|--oauth2-bearer|-D|--dump-header|--trace|--trace-ascii|--stderr|--netrc-file|--form-string|--cert-type|--key-type|--pinnedpubkey|--proxy-user|--noproxy|--unix-socket|--output-dir|--range|-r)
          _s_next=value; continue ;;
        -[!-]*X)       _s_next=method; continue ;;          # bundled -sSX PATCH
        -*)            continue ;;
        # A redirection target is not a request URL. `curl ... > /tmp/api/tasks/9/complete`
        # must not be read as one.
        '>'|'>>'|'>|'|'<'|'&>'|'&>>'|[0-9]'>'|[0-9]'>>'|[0-9]'<'|[0-9]'>&'|'&')
          _s_next=value; continue ;;
        *'>'*|*'<'*)   continue ;;                          # attached, e.g. >/tmp/f
        *)             _stride_take_url "$_s_tok"; continue ;;
      esac
    done
    if [ -n "$_s_hit" ]; then break; fi
  done
  if [ -z "$_s_hit" ]; then _stride_seg_eval; fi
  [ "$_s_hadf" -eq 1 ] || set +f
  if [ -n "$_s_hit" ]; then printf '%s\n' "$_s_hit"; fi
  return 0
}

# THE single routing entry point (D220). $1 = pre|post (empty for an id-only
# query), $2 = the Bash command. Sets STRIDE_ROUTE_ENDPOINT / STRIDE_ROUTE_HOOK /
# STRIDE_ROUTE_TASK_ID; prints nothing, so callers need no subshell. All three
# routing sites read those globals, so they cannot drift apart.
stride_route_command() {
  _sr_phase="$1"
  _sr_cmd="$2"
  STRIDE_ROUTE_ENDPOINT=""
  STRIDE_ROUTE_HOOK=""
  STRIDE_ROUTE_TASK_ID=""
  # Fast path: the overwhelming majority of Bash calls never mention the API.
  case "$_sr_cmd" in */api/tasks/*) : ;; *) return 0 ;; esac
  _sr_hit=$(_stride_strip_heredocs "$_sr_cmd" | _stride_scan_stream)
  [ -n "$_sr_hit" ] || return 0
  STRIDE_ROUTE_ENDPOINT="${_sr_hit%%:*}"
  STRIDE_ROUTE_TASK_ID="${_sr_hit#*:}"
  case "$_sr_phase:$STRIDE_ROUTE_ENDPOINT" in
    post:claim)         STRIDE_ROUTE_HOOK=before_doing ;;
    post:mark_reviewed) STRIDE_ROUTE_HOOK=after_review ;;
    post:complete)      STRIDE_ROUTE_HOOK=before_review ;;
    pre:complete)       STRIDE_ROUTE_HOOK=after_doing ;;
  esac
  return 0
}

# (D127) Resolve the authoritative task id for the CURRENT completion from the
# /complete or /mark_reviewed URL in the command, independent of the env cache.
# Those URLs always carry /api/tasks/<id>/<action>, so the changed_files upload
# targets the task the agent is actually completing even when a hidden claim
# response left a STALE TASK_ID in the env cache — the confirmed empty-
# changed_files root cause (G321/D126: the diff was PUT to the previous task).
# Returns empty when the command carries no such URL (e.g. the claim path, whose
# URL has no id); callers fall back to the env-cache TASK_ID in that case.
# (D220) Shares the ONE parser with routing, so an id can never be scraped out
# of a command that did not actually issue the request — the `echo` that drove a
# live changed_files PUT against task 999999999 went through this path. The
# published globals are saved and restored so callers see no side effect.
task_id_from_command() {
  local _sv_ep="$STRIDE_ROUTE_ENDPOINT" _sv_hk="$STRIDE_ROUTE_HOOK" \
        _sv_id="$STRIDE_ROUTE_TASK_ID" _out
  stride_route_command "" "$1"
  _out="$STRIDE_ROUTE_TASK_ID"
  STRIDE_ROUTE_ENDPOINT="$_sv_ep"; STRIDE_ROUTE_HOOK="$_sv_hk"
  STRIDE_ROUTE_TASK_ID="$_sv_id"
  printf '%s' "$_out"
}

# (D226) Per-task base-ref records.
#
# `.stride-env-cache` is ONE file for the whole repo, keyed by nothing, and
# every claim rewrites the shared TASK_BASE_REF. A NESTED claim therefore
# replaces the outer task's diff anchor with the inner task's — and dispatcher
# mode makes that routine rather than exotic, because a task whose work is to
# dispatch runners necessarily claims inside its own window. Observed: W2066
# claimed at b5737c98, dispatched runners for W2072/W2073, and completed with
# W2073's base — uploading W2073's two files onto W2066 with HTTP 200 and no
# error anywhere.
#
# The anchor is therefore recorded per task id as well as in the shared key,
# and those records are PRESERVED across later claims, so an outer task keeps
# its own base at any nesting depth (depth is not bounded by anything today).
# A flat `TASK_BASE_REF_<id>` line keeps this inside the existing cache on
# purpose: a new dotfile would need a `.gitignore` entry in every consuming
# project, which the plugin cannot add on the user's behalf.
# (D288) Drop every record whose key is exactly $1 from the env cache, on
# stdout. This replaces `grep -v "^KEY="` at the record-writer sites, and the
# reason is the whole of D288: those writers pipe the filter's stdout straight
# into write_env_cache, so a grep that declines to read the cache commits
# whatever little it did emit. That is not hypothetical - measured here, on a
# cache holding one byte >= 0x80:
#
#   /usr/bin/grep (BSD 2.6.0-FreeBSD)  LC_ALL=C and en_US.UTF-8   keeps every
#                                      line, invalid byte survives - SAFE
#   ugrep 7.8.4 with -I                emits NOTHING, exit 1      - every
#                                      unrelated record silently lost
#   ugrep 7.8.4 default                prints "Binary file <path> matches" on
#                                      STDOUT at exit 0 - the cache is replaced
#                                      by that notice plus the new record, and
#                                      the cache's own path is embedded in it
#
# Locale made no difference in any row, which is why LC_ALL=C is not the remedy
# (D288 pitfall 1). `grep -a` is not POSIX and would need cross-host evidence
# this task does not have (pitfall 2). awk has no binary-input refusal at all,
# is POSIX, and is already how the claim block computes its own preserved set -
# so the fix is to stop asking grep. GNU grep on Linux remains unmeasured; with
# grep out of this path that is no longer load-bearing here.
#
# A literal prefix comparison, not a regex, so a key never has to be escaped.
# (It was also NOT quote-aware at first, on the theory that a byte-for-byte
# swap for the grep was the conservative choice. Round 3 showed that theory was
# wrong - see the note above the filter itself - so it is quote-aware now.)
#
# REGEX-FREE ON PURPOSE, and this is the sharp edge of the whole fix. awk is
# immune to grep's binary refusal; awk's REGEX engine is not immune to the same
# byte. Measured on the same cache:
#
#   awk '/^AGENT_NAME=/ {next} {print}'    LC_ALL=C          rc 0, 2 lines
#   awk '/^AGENT_NAME=/ {next} {print}'    LC_ALL=en_US.UTF-8 rc 2, NOTHING,
#                                          "awk: towc: multibyte conversion
#                                          failure" - and the ambient locale on
#                                          a developer machine is a UTF-8 one
#   awk 'substr($0,1,11) != "AGENT_NAME="' both locales      rc 0, 2 lines
#
# So swapping grep for a REGEX awk would have moved the defect rather than
# fixed it: same silent-empty stdout, same exit-code-swallowing `|| true`, new
# tool. No cache filter below matches a regex against $0 or against a value;
# matching is index/substr on the ASCII key before the first "=". A regex on an
# already-EXTRACTED key is safe and two filters elsewhere legitimately use one
# (the family test in cache_window_record_lines, and the loader charset gate) -
# it is the subject of the match that has to be clean, not the tool.
# LC_ALL=C would also make awk byte-oriented, and is deliberately NOT used:
# D288 pitfall 1 rules it out, and index/substr needs no locale assumption at
# all, which is the stronger property.
drop_cache_key() {
  local _k="${1:-}"
  [ -n "$_k" ] || { cat "$ENV_CACHE" 2>/dev/null || true; return 0; }
  # (D288) Absent cache: a clean empty result. Present-but-unreadable: awk
  # exits non-zero and that status PROPAGATES, exactly as in the two filters
  # below. The `|| true` this used to end in made those two cases identical,
  # and the count gate could not tell them apart either.
  [ -f "$ENV_CACHE" ] || return 0
  # (D288 r3) QUOTE-AWARE, and this is a deliberate semantic change rather than
  # the byte-for-byte grep swap the first pass aimed at. The grep was line
  # oriented; the shape gate downstream is not. A value is attacker-authored
  # free-form text (TASK_DESCRIPTION and GOAL_DESCRIPTION are allow-listed and
  # land multi-line), so a description whose LAST line began with this key had
  # that line - the one carrying the value's closing quote - deleted from the
  # middle of a well-formed cache, and the torn stream was then refused by the
  # gate. A crafted description could therefore suppress a legitimate write.
  # Matching only OUTSIDE quotes, and dropping the record's whole span, makes
  # this filter agree with the gate about what a record is. It also fixes the
  # older, quieter half of the same bug: the grep silently deleted any INTERIOR
  # value line that happened to start with the key.
  awk -v k="$_k" -v q="'" '
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; drop = 0 }
    {
      if (!inq) { drop = (substr($0, 1, length(k) + 1) == k "=") }
      scan($0)
      if (!drop) print
    }
    END { if (inq) exit 1 }
  ' "$ENV_CACHE" 2>/dev/null
}

# (D288) The key of a cache line, or "" when the line does not begin one.
# Walks only the ASCII run before the first "=", so an invalid byte in the
# VALUE is never inspected. Shared, as awk text, by every filter below - the
# alternative was four copies that could drift.
CACHE_KEY_AWK_FNS='
function key_of(s,   p, i, c) {
  p = index(s, "=")
  if (p < 2) return ""
  for (i = 1; i < p; i++) {
    c = substr(s, i, 1)
    if (index("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_", c) == 0) return ""
  }
  if (index("0123456789", substr(s, 1, 1)) > 0) return ""
  return substr(s, 1, p - 1)
}
function has_prefix(k, pfx) { return (k != "" && substr(k, 1, length(pfx)) == pfx) }
'

# (D288) The per-window records a claim rebuilds from scratch. Exactly the set
# the grep -v it replaces named, one test per pattern, in the same order.
#
# NO `|| true`. The caller MUST be able to tell "the filter ran and this cache
# genuinely holds nothing else" from "the filter could not read the cache" -
# swallowing the status collapses those into an empty string at exit 0, which
# is precisely the shape D288 exists to remove. Moving the defect from grep to
# awk would have been no fix at all.
# TRUSTED/OWNER/UNPROVEN stay spelled out even though the generic
# TASK_BASE_REF_ test already covers them, exactly as the grep spelled them.
drop_task_window_records() {
  # (D288) An ABSENT cache is an empty starting point, not a failure to read
  # one — a fresh checkout has no cache, and treating that as "the filter could
  # not read it" would make the caller skip a rebuild it must perform. Only a
  # cache that EXISTS and could not be filtered propagates a failure.
  [ -f "$ENV_CACHE" ] || return 0
  # (D288 r3) Quote-aware, for the reason set out above drop_cache_key: a
  # crafted description whose last line began with one of these keys otherwise
  # tore the closing quote off a well-formed cache and got the rebuild refused.
  awk -v q="'" "$CACHE_KEY_AWK_FNS"'
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; drop = 0 }
    {
      if (!inq) {
        k = key_of($0)
        if (k == "TASK_BASE_REF") { drop = 1 }
        else if (k == "TASK_BASE_REF_TRUSTED") { drop = 1 }
        else if (k == "TASK_BASE_REF_OWNER") { drop = 1 }
        else if (k == "TASK_BASE_REF_UNPROVEN") { drop = 1 }
        else if (has_prefix(k, "TASK_BASE_REF_")) { drop = 1 }
        else if (has_prefix(k, "TASK_HEAD_REF_")) { drop = 1 }
        else if (has_prefix(k, "TASK_OWNED_")) { drop = 1 }
        else if (has_prefix(k, "TASK_BASE_AT_")) { drop = 1 }
        else if (has_prefix(k, "TASK_NARROWED_")) { drop = 1 }
        else { drop = 0 }
      }
      scan($0)
      if (!drop) print
    }
    END { if (inq) exit 1 }
  ' "$ENV_CACHE" 2>/dev/null
}

# (D288) The narrower set the claim block's fallback drops - the four shared
# base-ref records only, leaving every per-task window record in place. Status
# propagated for the same reason as above, and it matters more here: the
# caller DELETES the cache when this comes back empty.
drop_shared_base_records() {
  # (D288) An ABSENT cache is an empty starting point, not a failure to read
  # one — a fresh checkout has no cache, and treating that as "the filter could
  # not read it" would make the caller skip a rebuild it must perform. Only a
  # cache that EXISTS and could not be filtered propagates a failure.
  [ -f "$ENV_CACHE" ] || return 0
  # (D288 r3) Quote-aware, for the reason set out above drop_cache_key: a
  # crafted description whose last line began with one of these keys otherwise
  # tore the closing quote off a well-formed cache and got the rebuild refused.
  awk -v q="'" "$CACHE_KEY_AWK_FNS"'
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; drop = 0 }
    {
      if (!inq) {
        k = key_of($0)
        if (k == "TASK_BASE_REF") { drop = 1 }
        else if (k == "TASK_BASE_REF_TRUSTED") { drop = 1 }
        else if (k == "TASK_BASE_REF_OWNER") { drop = 1 }
        else if (k == "TASK_BASE_REF_UNPROVEN") { drop = 1 }
        else { drop = 0 }
      }
      scan($0)
      if (!drop) print
    }
    END { if (inq) exit 1 }
  ' "$ENV_CACHE" 2>/dev/null
}

# (D226) Every write of the env cache goes through here, so no reader can ever
# observe a half-written file. Three sites used to truncate in place — and a
# reader mid-write is not hypothetical, because parallel dispatched runners
# genuinely claim concurrently.
#
# The temp file lives in `.stride/`, not beside the cache: `.stride/` is
# already hard-excluded from capture_changed_files AND from typical project
# gitignores, whereas `.stride-env-cache.aB3xY9` matches neither, so a process
# killed between create and rename would otherwise leave a stray file that
# lands in the NEXT task's uploaded diff and gets swept into a commit by any
# `after_doing` running `git add -A`. Budget kills are documented reality here
# (D229), so that window is real. Same filesystem either way, so `mv` remains
# a rename(2).
#
# On any failure the PREVIOUS cache survives intact — never truncated, never
# absent. Reads the new content from stdin.
write_env_cache() {
  local _tmp _floor=0 _prev=0 _staged=0
  # (D288) --preserve-from-cache asks the sink to refuse a write that would
  # drop records the caller never meant to drop. Opt-in, because only the
  # single-key record writers have the "output is the previous cache minus at
  # most one record" invariant; the rebuild sites legitimately shrink the cache
  # (window eviction, the claim block's preserved-only fallback) and must not
  # be held to it.
  if [ "${1:-}" = "--preserve-from-cache" ]; then
    _floor=1
    shift
  fi
  mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null || true
  _tmp=$(mktemp "$PROJECT_DIR/.stride/env-cache.XXXXXX" 2>/dev/null || printf '')
  if [ -z "$_tmp" ]; then
    cat > /dev/null 2>&1 || true
    printf 'stride-hook: could not stage an env-cache write; keeping the previous cache\n' >&2
    return 1
  fi
  # `cat`'s status is checked, not discarded: a write error after partial
  # output (ENOSPC, EIO) would otherwise leave a truncated temp that the
  # rename then commits OVER a good cache — turning "keep the previous cache
  # on failure" into exactly the corruption it promises to prevent.
  if ! cat > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    printf 'stride-hook: could not stage an env-cache write; keeping the previous cache\n' >&2
    return 1
  fi
  # (D288) Shape gate, unconditional, and the half that catches the failure the
  # task did not anticipate. A grep that declines to read the cache may not go
  # quiet: ugrep's default prints "Binary file <path> matches" to STDOUT and
  # exits 0, so an emptiness test - the remedy D288 was filed proposing - passes
  # it straight through and commits a "cache" that is one line of English prose
  # plus the new record. Every top-level line of a real cache is KEY=..., and a
  # value can only contribute lines while the scanner is INSIDE its quotes, so
  # a top-level line that is not a record did not come from the cache. Blank
  # lines are allowed: they carry nothing and no notice looks like one.
  #
  # Not steerable by cache content (D288 security consideration 2): every value
  # is sq_escape'd, so an attacker-authored title lands inside single quotes,
  # where this check does not look. Unbalanced quotes at EOF mean the stream is
  # truncated or was never a cache; refusing keeps the previous file, which is
  # the direction the PowerShell twin already fails in.
  if ! awk -v q="'" "$CACHE_KEY_AWK_FNS"'
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0 }
    {
      if (!inq && $0 != "" && key_of($0) == "") exit 1
      scan($0)
    }
    END { if (inq) exit 1 }
  ' "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    printf 'stride-hook: REFUSING an env-cache write that is not shaped like a cache; keeping the previous cache (%s) - remove that file to recover\n' \
      "$ENV_CACHE" >&2
    return 1
  fi
  # (D288) Count gate, opt-in. A single-key record writer removes at most one
  # record and adds one back, so a result holding fewer than (previous - 1)
  # records means the filter ahead of it dropped records nobody asked it to.
  # Counted quote-aware, so a multi-line value counts once - the live cache
  # really does carry those, since TASK_DESCRIPTION is a whole paragraph.
  if [ "$_floor" = 1 ] && [ -s "$ENV_CACHE" ]; then
    _prev=$(count_cache_records "$ENV_CACHE")
    _staged=$(count_cache_records "$_tmp")
    # (D288) Refuse when the gate cannot JUDGE, not only when it judges
    # against. A cache that exists but cannot be READ - root-owned, mode 000,
    # an ACL, or unlinked mid-run - makes the filter ahead of this return
    # nothing AND makes this count come back empty, and `[ -s ]` is satisfied
    # by stat alone while `mv` still succeeds into a writable directory. An
    # abstention here therefore committed the one-record cache the filter had
    # produced, silently, at exit 0: the exact shape this gate exists to close,
    # surviving at the one site the first fix did not reach. This strands no
    # legacy cache. Since r3 the filters are quote-aware and EXIT 1 on an
    # unbalanced cache rather than passing it through, so a record write bails
    # at its own source check and never arrives here; a rebuild site routes the
    # same failure into _rebuild_ok. Either way the previous cache stands.
    if [ -z "$_prev" ] || [ -z "$_staged" ]; then
      rm -f "$_tmp" 2>/dev/null || true
      printf 'stride-hook: REFUSING an env-cache write whose record counts could not be established; keeping the previous cache (%s)\n' \
        "$ENV_CACHE" >&2
      return 1
    fi
    if [ "$_prev" -gt 0 ] && [ "$_staged" -lt $((_prev - 1)) ]; then
      rm -f "$_tmp" 2>/dev/null || true
      printf 'stride-hook: REFUSING an env-cache write that would drop %s of %s records; keeping the previous cache\n' \
        "$((_prev - _staged))" "$_prev" >&2
      return 1
    fi
  fi
  if ! mv -f "$_tmp" "$ENV_CACHE" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    printf 'stride-hook: could not commit an env-cache write; keeping the previous cache\n' >&2
    return 1
  fi
  return 0
}

# (D288) Quote-aware count of records in a cache file. A record starts only on
# a line the scanner reaches outside quotes; continuation lines of a multi-line
# value belong to the record that opened them. Prints nothing on a parse
# failure (EOF inside a value), which the caller reads as "do not judge".
count_cache_records() {
  awk -v q="'" "$CACHE_KEY_AWK_FNS"'
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; n = 0 }
    { if (!inq && key_of($0) != "") n++; scan($0) }
    END { if (inq) exit 1; print n }
  ' "${1:-}" 2>/dev/null || printf ''
}

# The per-task keys share a namespace with TASK_BASE_REF_TRUSTED and
# TASK_BASE_REF_OWNER, so an id sanitizing to either would emit a record line
# that sets the trust flag or the owner from server data. Ids are integers, so
# this is theoretical — and it costs two lines to keep it that way.
# (D269) The ONE place a per-task record key is built, for all five families.
#
# They were five byte-identical copies differing only in a prefix string, and
# that duplication had already bitten: D269's own text and pitfall say the
# sanitizer is shared by THREE families and that any fix "must apply to all
# THREE identically" — written before D273 added TASK_BASE_AT_ and
# TASK_NARROWED_. A fix applied to the three the task names would have left two
# families colliding. Folding them into one function makes "identically" true
# by construction instead of by five copies staying in sync.
#
# THE INVARIANT: a task id is an integer. Not an assumption — the API documents
# the response `id` as an integer (docs/api/get_tasks.md, get_tasks_id.md) and
# the schema has no @primary_key override, so Ecto's default integer primary key
# applies. This function ENFORCES that rather than restating it: a non-integer
# id yields NO key, so no per-task record is written for it and the caller
# degrades to the shared-base path exactly as it does for a reserved word.
#
# Why enforcement lives here and not only at the parse boundary: this is the
# single choke point every family goes through, so one guard covers every entry
# path — the /complete URL, the claim response, and the env-cache fallback —
# including any added later. The URL parse already validates digits-only for
# the same reason (D127, "only a NUMERIC id is authoritative"); this makes the
# codebase consistent rather than introducing a new rule.
#
# What it fixes: `tr -c 'A-Za-z0-9_' '_'` is NOT injective, so two ids differing
# only in punctuation collapsed to one key — `42-x` and `42.x` both became
# suffix `42_x` and SHARED their base/head/owned records, letting one task's
# completion consume or reset another's attribution state. Digits cannot
# collide under that mapping, so refusing non-integers removes the collision
# rather than re-encoding around it.
#
# The reserved-word guard is kept even though a digits-only id can no longer
# produce TRUSTED/OWNER/UNPROVEN: it costs nothing, and it is what keeps this
# safe if the id rule is ever widened. Order matters — sanitize, then reject.
task_record_key() { # $1 = family prefix (with trailing _), $2 = task id
  local _s
  case "${2:-}" in
    "" | *[!0-9]*) return 0 ;;
  esac
  _s=$(printf '%s' "$2" | tr -c 'A-Za-z0-9_' '_')
  case "$_s" in
    "" | TRUSTED | OWNER | UNPROVEN) return 0 ;;
  esac
  printf '%s%s' "$1" "$_s"
}

task_base_ref_key() { task_record_key 'TASK_BASE_REF_' "${1:-}"; }

# Prints the base recorded by the given task's OWN claim, or empty when none
# is on record (an older cache, or a claim whose response never parsed).
task_base_ref_for() {
  local _k _v
  [ -n "${1:-}" ] || return 0
  _k=$(task_base_ref_key "$1")
  _v="${!_k:-}"
  printf '%s' "$_v"
}

# (D236) Per-task completion HEAD. The base records D226 added say where each
# task STARTED; attributing commits also needs to know where each nested task
# ENDED, and nothing recorded that. Without an end marker a base alone cannot
# separate a nested task's commits from the outer task's own later ones — every
# commit after the nested claim is a descendant of that claim's base, including
# the outer task's.
task_head_ref_key() { task_record_key 'TASK_HEAD_REF_' "${1:-}"; }

task_head_ref_for() {
  local _k _v
  [ -n "${1:-}" ] || return 0
  _k=$(task_head_ref_key "$1")
  _v="${!_k:-}"
  printf '%s' "$_v"
}

# (D236) Stamp the completing task's HEAD so a later OUTER completion can tell
# where this task's commits stop. Best-effort and never fatal: a missing record
# only means the outer task falls back to its own base, which is exactly
# today's behaviour.
record_task_head_ref() {
  local _tid="${1:-}" _key _head
  [ -n "$_tid" ] || return 0
  _key=$(task_head_ref_key "$_tid")
  [ -n "$_key" ] || return 0
  # (D268) A head without its base partner is a half-bounded window no reader
  # can use — attribution requires BOTH ends, and the per-window selector
  # drops orphans at the next claim anyway. Writing it (e.g. on the refused
  # completion of an evicted task) only re-creates transiently the exact shape
  # the D268 policy declares impossible, so skip it when no base record exists.
  [ -n "$(task_base_ref_for "$_tid")" ] || return 0
  _head=$( (cd "$PROJECT_DIR" 2>/dev/null && git rev-parse HEAD 2>/dev/null) || printf '')
  [ -n "$_head" ] || return 0
  # (D288 r3) Capture the filter FIRST and consume its status here. Inside a
  # brace-group pipeline the filter's exit code is invisible, which left the
  # sink's count gate as the only thing standing between an unreadable cache
  # and a one-record cache committed over a populated one — and that gate works
  # only because awk happens to treat an unopenable input as fatal. Checking
  # here does not depend on that.
  local _body
  # The bail is diagnosed, not silent. Bailing here skips write_env_cache
  # entirely, so the sink gates' messages are unreachable from this site and a
  # refusal would otherwise produce no stderr at all - which is the failure
  # mode this whole defect is about, in miniature.
  _body=$(drop_cache_key "$_key") || {
    printf 'stride-hook: could not filter the env cache for %s; keeping the previous cache (%s)\n' \
      "$_key" "$ENV_CACHE" >&2
    return 0
  }
  {
    [ -n "$_body" ] && printf '%s\n' "$_body"
    printf "%s='%s'\n" "$_key" "$_head"
  } | write_env_cache --preserve-from-cache || true
  return 0
}

# (D255) Per-task owned-commit record: the commits this task's OWN after_doing
# command loop authored (H0..H1 around the loop). ADDITIVE signal — absence,
# emptiness, or OVERFLOW all degrade to the D244 window/purity fallback.
task_owned_key() { task_record_key 'TASK_OWNED_' "${1:-}"; }

# Prints the recorded owned set for the given task id. Return status is the
# presence signal: 0 = a record EXISTS (value may legitimately be empty),
# 1 = no record. Reads the CACHE FILE, not the environment, so absent-vs-empty
# is decidable and an exported variable cannot forge a record.
# (D273) Read a per-task record from the cache FILE, accepting ONLY a
# well-formed KEY='value' line.
#
# (D287) It is NOT the only file-reading path, and the sentence that used to
# claim so here — "every file-reading per-task lookup goes through here" — was
# false when written and is what let the gap below go unnoticed. The four window
# readers (dead_open_window_ids, select_kept_window_records,
# another_open_window_exists, attributed_commit_ranges) read the BASE_REF,
# HEAD_REF and OWNED families line by line and never route through this
# function, so this shape check never covered them. They are now quote-aware at
# their own source — see cache_record_start_lines — which closes the same class
# one step earlier, before a candidate line is ever matched. Both guards stand:
# this one proves a single record well-formed, that one decides which lines are
# records at all.
#
# The shape check is a security boundary, not tidiness. A server-supplied hook
# env VALUE may legitimately contain newlines — TASK_DESCRIPTION routinely does
# — and extract_hook_env's @sh quoting preserves them, so apply_env_lines
# writes a value spanning several PHYSICAL lines. A line-oriented reader then
# reads a continuation line as a record of its own, which turns a value on an
# ALLOWED key into a forged record on a fenced one: `"b\nTASK_NARROWED_200=yes"`
# plants a line that outranks the one this client wrote and steers a retry into
# NARROWING — the under-report direction, reached past a fence that only
# filters keys. Demanding the full quoted shape closes it at the reader, where
# it is provable rather than probable: @sh escapes any single quote in the
# injected text as '\'', so a forged continuation can never present as
# KEY='value'.
#
# What the readers give up in exchange, stated exactly rather than generously:
# sq_escape renders an embedded quote as '\'' too, so a LEGITIMATE record whose
# value contained one would also fail this shape and read as absent. That is
# survivable only because all three families this reader serves carry
# constrained values — `yes`/`no`, epoch digits, and hex SHAs or the OVERFLOW
# sentinel — none of which can contain a quote. It is not a property of
# sq_escape, and a future family with free-form values must not be routed here
# without revisiting it. The failure direction is safe either way: an
# unreadable record degrades to the wide path.
read_task_record() { # $1 = full key
  local _key="${1:-}" _line
  [ -n "$_key" ] || return 1
  # (D288) awk, not grep, and the read side needed this as much as the write
  # side did. Under ugrep's default refusal this grep does not return nothing -
  # it returns "Binary file <path> matches" on stdout at exit 0. That line has
  # no "=", so the strips below are all no-ops and the function hands the
  # English diagnostic back to its callers AS the record's value, which then
  # reaches attribution and gets re-written into the cache sq_escape'd. The
  # shape is checked explicitly here rather than trusted from an anchored
  # pattern: starts with KEY=', ends with ', and no quote in between.
  _line=$(awk -v k="$_key" -v q="'" '
    {
      pfx = k "=" q
      if (length($0) < length(pfx) + 1) next
      if (substr($0, 1, length(pfx)) != pfx) next
      if (substr($0, length($0), 1) != q) next
      body = substr($0, length(pfx) + 1, length($0) - length(pfx) - 1)
      if (index(body, q) > 0) next
      found = 1
      last = body
    }
    END { if (found) print last }
  ' "$ENV_CACHE" 2>/dev/null || true)
  [ -n "$_line" ] || return 1
  printf '%s' "$_line"
  return 0
}

task_owned_for() {
  local _key
  _key=$(task_owned_key "${1:-}")
  [ -n "$_key" ] || return 1
  read_task_record "$_key"
}

# (D255) Best-effort, never fatal — a missing record only means fallback.
record_task_owned() {
  local _tid="${1:-}" _val="${2:-}" _key
  [ -n "$_tid" ] || return 0
  _key=$(task_owned_key "$_tid")
  [ -n "$_key" ] || return 0
  # (D268) Same orphan guard as record_task_head_ref. Attribution consumes
  # owned records only for a window with BOTH base and head; the one reader
  # that does not require the pair is the before_review self-heal retry, which
  # on a legacy pre-D226 cache (shared base, no per-task record) now falls
  # back from owned-set narrowing to the purity heuristic — an accepted,
  # transitional, safe-direction delta (over-collect, never under-report).
  [ -n "$(task_base_ref_for "$_tid")" ] || return 0
  # (D288 r3) Filter status consumed here, not left to the sink — see
  # record_task_head_ref.
  local _body
  # The bail is diagnosed, not silent. Bailing here skips write_env_cache
  # entirely, so the sink gates' messages are unreachable from this site and a
  # refusal would otherwise produce no stderr at all - which is the failure
  # mode this whole defect is about, in miniature.
  _body=$(drop_cache_key "$_key") || {
    printf 'stride-hook: could not filter the env cache for %s; keeping the previous cache (%s)\n' \
      "$_key" "$ENV_CACHE" >&2
    return 0
  }
  {
    [ -n "$_body" ] && printf '%s\n' "$_body"
    printf "%s=%s\n" "$_key" "$(sq_escape "$_val")"
  } | write_env_cache --preserve-from-cache || true
  return 0
}

# (D287) Emit the cache's record-START lines, and only those.
#
# THE PROBLEM THIS SOLVES. Four window readers are LINE-oriented: each greps
# $ENV_CACHE for a record-family prefix one physical line at a time —
# dead_open_window_ids, select_kept_window_records, another_open_window_exists
# and attributed_commit_ranges.
#
# A FIFTH SITE reads the same prefixes the same way and is deliberately NOT
# converted: the `_preserved` grep -v in finalize_before_doing, and its twin on
# the claim path. Those are exclusion-only, so they cannot PROMOTE a planted line
# — but they can splice an interior line out of the middle of a legitimate
# multi-line TASK_TITLE or TASK_DESCRIPTION that happens to begin with one of
# these prefixes, corrupting that value rather than forging a record. Different
# defect, different direction, out of this one's scope; recorded here so the next
# reader does not take the list of four as exhaustive. It is not.
# A value on an ALLOWED hook-env key can carry a newline — extract_hook_env's
# `@sh` escapes quotes but preserves newlines, and apply_env_lines deliberately
# does not flatten, because `source` reassembles a quoted value across one. So a
# task title of the form
#
#     Fix<LF>TASK_BASE_REF_99='<sha>'<LF>end
#
# lands in the cache as three physical lines with a bare, record-SHAPED line in
# the middle of a quoted value. Sourcing that cache is safe — `source` is
# quote-aware and hands the whole thing back as one TASK_TITLE. Grepping it is
# not: the interior line matches, select_kept_window_records keeps it, and the
# rebuilt cache then writes it out as a STANDALONE record. After that rebuild it
# is a genuine record — D273's `^KEY='[^']*'$` shape check in read_task_record no
# longer applies, because the line is no longer a continuation — and
# task_base_ref_for reads the forged value straight from the environment. The
# result is a forged snapshot base or head/owned record for another task: the
# D226/D268/D273 commit-attribution property defeated through a fence that
# filters KEYS only (D275) while the VALUE channel stayed open.
#
# THE FIX is to decide what a record IS before matching one. A line begins a
# record only when the scanner is OUTSIDE a quoted value; anywhere else it is
# continuation text, whatever it looks like.
#
# The quote/escape state machine is `scan()`, byte-identical to the one in
# apply_env_lines. Stated plainly because the first version of this comment
# claimed it was "one idiom, three call sites", which it is not: awk has no
# include, so this is a COPY. That is a real cost — a fix to the state machine
# has to land in every copy — and it is accepted here rather than hidden,
# because the alternative on offer was a second, differently-worded scanner,
# which is the thing that actually goes wrong.
#
# (D288) The count was four, then six, and is now ELEVEN: D288 added five more
# — the shape gate and count_cache_records in its first pass, and the three
# quote-aware cache filters in its third. This comment used to name the number
# and instruct "change all six", which had quietly become a trap that would
# have left five sites behind. Do not trust a number written here: COUNT them,
# with `grep -c '^ *function scan(s,'`, anchored so it does not match this
# sentence. The right fix is to fold scan() into CACHE_KEY_AWK_FNS, which
# already exists to stop exactly this drift and which five of these copies sit
# immediately after loading — deliberately left as a separate change rather
# than folded into a defect about grep, and named here so it is not lost.
#
# This is the property stride-hook.ps1 has carried since D280 via
# Split-EnvCacheRecord, which groups physical lines into records before any regex
# runs; bash had no equivalent, so this is an executor divergence closed, not a
# new invention.
#
# FAILS CLOSED, and the buffering is what makes that true. Matches accumulate in
# out[] and are printed only from END, so an unterminated quote at EOF exits
# non-zero having printed NOTHING — a streaming `print` would have emitted every
# match before reaching the broken quote, which is fail-OPEN wearing a check.
#
# EMPTY OUTPUT IS NOT THE WHOLE CONTRACT: the STATUS is, and the two callers of
# this function want opposite things from it. The three pure READERS take the
# empty and degrade safely — the sweep proves nothing dead, the predicate reports
# no other open window, the attribution loop attributes no window, all of which
# make a task OVER-report its commits, the recoverable half of the D244/D274
# trade. select_kept_window_records is not a pure reader: its output is written
# BACK, so for it an empty set is not a safe degrade but an erasure, and it
# propagates the failure instead so its callers skip the rebuild entirely. An
# earlier version of this comment claimed all four callers behave "exactly as
# they do for an empty cache" and treated that as uniformly safe; that was wrong
# in the one case that writes, which is the case that matters.
cache_record_start_lines() {
  [ -f "$ENV_CACHE" ] || return 0
  awk -v q="'" '
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; n = 0 }
    { if (!inq && index($0, "=") > 1) { n++; out[n] = $0 } scan($0) }
    END { if (inq) exit 1; for (i = 1; i <= n; i++) print out[i] }
  ' "$ENV_CACHE" 2>/dev/null || {
    # (D287 r2) The status is the caller's to act on, so it is returned rather
    # than swallowed. Without this, "the cache does not parse" and "the cache
    # holds no records" are the same empty string — and they demand OPPOSITE
    # handling at the one caller that writes its output back. The stderr line
    # follows write_env_cache's convention: this file already tells an operator
    # when it degrades, and a silent degrade here is the expensive kind to
    # diagnose because every symptom appears one claim later.
    printf 'stride-hook: env cache could not be read (unterminated quote, or awk unavailable); no window records read\n' >&2
    return 1
  }
}

# (D287 r2) Emit only WELL-FORMED per-task window records: a numeric id and the
# canonical `KEY='value'` shape read_task_record (D273) already demands.
#
# WHY A SHAPE GATE ON TOP OF THE QUOTE-AWARENESS. Making the readers quote-aware
# stops a NEW planted line from being promoted, but it does nothing about a line
# a pre-D287 hook ALREADY promoted — and the strongest payload is the unquoted
# one. A title of the form `Fix<LF>TASK_BASE_REF_<victim>=<40 hex><LF>end` plants
# an interior line with zero quote toggles; once an old hook promoted it, it sits
# in the cache as a standalone, well-formed-looking, UNQUOTED assignment that the
# quote scanner has no reason to reject. The selector would carry it forward at
# every claim — D274 pins open windows outright, and a base with no head is an
# open window — so it would outlive the fix indefinitely.
#
# Every record this file actually writes goes through sq_escape or jq `@sh`, so
# it is always `KEY='...'`, and every id goes through task_record_key, which
# rejects a non-numeric one. The promoted residue passes neither test. Raised by
# the security review of this change, which correctly noted that the loader gate
# below already makes this argument for legacy PATH lines and then failed to
# apply it to the record families the defect is actually about.
#
# The three sanctioned non-numeric siblings — TASK_BASE_REF_TRUSTED, _OWNER and
# _UNPROVEN — are not window records and are not emitted here; the readers never
# wanted them (each excluded them by hand) and the loader admits them by name.
cache_window_record_lines() {
  # (D287 r3) Captured FIRST, then filtered — not `{ ... || return 1; } | awk`,
  # which was the r2 shape. The defect there was the awk's trailing `|| true`,
  # which reset the pipeline's status to 0, so the caller's `|| return 1` could
  # never fire: both rebuild-skip guards were unreachable and the erasure
  # regression they were added to close stayed fully live, while the suite
  # reported green because every assertion checked output and none checked a
  # status. Found by review round 2.
  #
  # An earlier version of this comment called that shape "inert twice over",
  # adding that a `return` on the left of a pipe exits a subshell rather than
  # the function. The mechanism is real but it was NOT a second cause here:
  # this script runs under `set -uo pipefail` (line 14), so the subshell's 1
  # became the pipeline's status and `|| true` alone is what discarded it —
  # verified by repro, the same shape without `|| true` returns 1. Capturing
  # first is still the right form: it makes the status the caller reads a
  # property of the assignment rather than of pipefail staying enabled.
  local _starts
  _starts=$(cache_record_start_lines) || return 1
  printf '%s\n' "$_starts" | awk -v q="'" '
    function quoted(s, k,   v) {
      v = substr(s, length(k) + 2)
      if (length(v) < 2) return 0
      if (substr(v, 1, 1) != q) return 0
      if (substr(v, length(v), 1) != q) return 0
      if (index(substr(v, 2, length(v) - 2), q) != 0) return 0
      return 1
    }
    {
      if (index($0, "=") <= 1) next
      key = substr($0, 1, index($0, "=") - 1)
      if (key !~ /^TASK_(BASE_REF|HEAD_REF|OWNED|NARROWED|BASE_AT)_[0-9]+$/) next
      if (!quoted($0, key)) next
      print
    }
  ' 2>/dev/null
}

# (D287) Emit the cache's WHOLE records — start line plus every continuation
# line — for allowed keys only, dropping the rest. The loader's gate.
#
# WHY A GATE HERE AT ALL, superseding the D281 ruling that used to sit at the
# loader. That ruling declined a key filter on two grounds, and D287 falsifies
# the load-bearing one. It argued the only residual case was "a cache authored by
# something other than the two executors — at which point the attacker already
# has write access to a file bash sources." That is not the only case: an
# executor ITSELF could author a hostile record, because select_kept_window_records
# promoted a planted interior line and write_env_cache committed it. The upstream
# D275 allow-list also stops NEW poisoning without cleaning a cache already
# written by a pre-D275 hook — one that accepted PATH, BASH_ENV, LD_PRELOAD and
# the rest — and that line is sourced on every non-claim invocation until the next
# claim rebuilds the cache. Every machine that ran the old hook against a hostile
# response carries one until then.
#
# The ruling's OTHER ground was sound and is honoured rather than overturned: an
# allow-list must not cost the reassembly of a quoted multi-line value, which is
# the one thing this side does right and the ps1 had to work to imitate. So the
# mechanism is unchanged — the filtered text is still interpreted by the shell,
# under `set -a`, exactly as apply_env_lines already does with `eval` — and only
# the CONTENT is gated. A record is admitted or dropped whole, so a multi-line
# TASK_TITLE still arrives as one value.
#
# NO THIRD KEY LIST. Admission is STRIDE_HOOK_ENV_ALLOW — the same 17 documented
# hook-env names D275 fenced the server down to — plus the five client-owned
# `task_*_key` record families, plus the bare TASK_BASE_REF that the claim's own
# identity block writes. STRIDE_ is deliberately NOT admitted: nothing writes an
# executor tuning knob to the cache, so a STRIDE_ record could only be a forged
# or legacy one, and admitting it would re-open the D273 age-horizon knob.
#
# Fails closed on an unterminated quote for the same reason and by the same
# buffering as cache_record_start_lines: nothing is sourced, so the hook falls
# back to the server-supplied env applied immediately below it.
filter_cache_records() {
  local _allow
  [ -f "$ENV_CACHE" ] || return 0
  _allow=$(printf '%s' "$STRIDE_HOOK_ENV_ALLOW" | tr -d '[]"' | tr ',' ' ')
  awk -v q="'" -v allow="$_allow TASK_BASE_REF" '
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    function quoted(s, k,   v) {
      v = substr(s, length(k) + 2)
      if (length(v) < 2) return 0
      if (substr(v, 1, 1) != q) return 0
      if (substr(v, length(v), 1) != q) return 0
      if (index(substr(v, 2, length(v) - 2), q) != 0) return 0
      return 1
    }
    BEGIN {
      inq = 0; esc = 0; keep = 0; n = 0
      na = split(allow, a, " ")
      for (i = 1; i <= na; i++) if (a[i] != "") ok[a[i]] = 1
    }
    {
      # Outside a quoted value, every line decides its own fate: a record start
      # is admitted on its key, and anything else at this level is junk. Inside
      # one, the start line'"'"'s verdict carries, which is what keeps a
      # multi-line value whole.
      if (!inq) {
        keep = 0
        if (index($0, "=") > 1) {
          key = substr($0, 1, index($0, "=") - 1)
          # (D287 r2) Anchored, and charset-checked before anything else. The
          # family test used to be an unanchored prefix with no validation of
          # the key at all, so a start line such as
          # `TASK_OWNED_0;curl ...|sh; x=1` satisfied it and was handed verbatim
          # to `eval` under `set -a` — arbitrary execution rather than an
          # assignment. Not reachable today, because extract_hook_env has
          # enforced this same charset on server keys since W1453 — but this
          # gate exists precisely to be the last line of defence for a cache the
          # file already treats as hostile, so it validates rather than assumes.
          if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
            if (key in ok) keep = 1
            else if (key == "TASK_BASE_REF_TRUSTED" || key == "TASK_BASE_REF_OWNER" \
                     || key == "TASK_BASE_REF_UNPROVEN") keep = 1
            else if (key ~ /^TASK_(BASE_REF|HEAD_REF|OWNED|NARROWED|BASE_AT)_[0-9]+$/ \
                     && quoted($0, key)) keep = 1
          }
        }
      }
      if (keep) { n++; out[n] = $0 }
      scan($0)
    }
    END { if (inq) exit 1; for (i = 1; i <= n; i++) print out[i] }
  ' "$ENV_CACHE" 2>/dev/null || {
    # (D287 r3) The loader's degrade is the quietest one in the file and the
    # most confusing to hit: nothing is sourced, so the hook runs with no
    # TASK_ID, TASK_IDENTIFIER or TASK_TITLE and every downstream symptom looks
    # like a server problem. Say so here rather than leaving the operator to
    # infer it.
    #
    # Status is deliberately NOT propagated: the loader has nothing better to do
    # than continue with nothing. On the POST phase the server-supplied env is
    # applied immediately below, so the identity keys come back; on the PRE
    # phase (which is how after_doing is routed) they do NOT — apply_env_lines
    # is gated on `[ "$PHASE" = "post" ]` — so that invocation genuinely runs
    # without them. An earlier version of this comment cited the re-application
    # without that qualifier and was therefore only half true. Failing the hook
    # instead would be worse: a torn cache would then block completion rather
    # than degrade it.
    printf 'stride-hook: env cache could not be read (unterminated quote, or awk unavailable); continuing without cached values\n' >&2
    return 0
  }
}

# (D274) Liveness sweep for OPEN windows — the replacement for D268's
# open-window count cap, which could not tell a live enclosing outer from an
# abandoned claim and so evicted the outer. $1 = the sweep threshold, $2 =
# an optional reserved base-ref KEY to ignore. Prints a space-separated list
# of task ids whose OPEN window is provably dead, or nothing.
#
# Fail-safe by construction, because a false positive here is the very data
# loss this whole subsystem exists to prevent:
#   * below the threshold it runs no git at all and proves nothing dead, so
#     the ordinary cache (a handful of open windows) is untouched and pays
#     nothing;
#   * with an unreadable repository it returns empty, keeping every window;
#   * a record is called dead ONLY when its base does not resolve to a commit
#     at all. That is deliberately HALF of what another_open_window_exists
#     treats as unusable: that predicate also skips a base that is not an
#     ancestor of HEAD, and this sweep must NOT, because the two act on
#     different state. Ancestry is a property of where HEAD points right
#     NOW — a detached HEAD, a bisect, or a checkout of an older commit makes
#     a perfectly live outer's base a non-ancestor for as long as that lasts.
#     Skipping such a base is recoverable the moment HEAD comes back;
#     DELETING its record is not, and one claim during a bisect with more
#     than the threshold open would erase live anchors permanently — D274's
#     own outcome through a different door. Non-resolution is the only
#     irreversible signal, so it is the only one this sweep acts on.
#   * a base whose value is not even SHA-shaped is KEPT rather than swept:
#     unusable is not the same as provably dead, and keeping is the safe
#     direction.
# Openness is read from the cache FILE (base ids minus head ids) rather than
# from the sourced environment, matching the selector this feeds.
dead_open_window_ids() {
  local _sweep_at="${1:-0}" _reserve="${2:-}" _open _id _b _dead=""
  [ -f "$ENV_CACHE" ] || return 0
  _open=$( { cache_window_record_lines || true; } | awk -v reserve="$_reserve" '
    /^TASK_BASE_REF_[A-Za-z0-9_]*=/ {
      key = $0; sub(/=.*/, "", key)
      if (key == "TASK_BASE_REF_TRUSTED" || key == "TASK_BASE_REF_OWNER" \
          || key == "TASK_BASE_REF_UNPROVEN") next
      if (reserve != "" && key == reserve) next
      id = key; sub(/^TASK_BASE_REF_/, "", id)
      nb++; bid[nb] = id; bval[id] = substr($0, index($0, "=") + 1)
      next
    }
    /^TASK_HEAD_REF_[A-Za-z0-9_]*=/ {
      id = $0; sub(/^TASK_HEAD_REF_/, "", id); sub(/=.*/, "", id); head[id] = 1
    }
    END { for (i = 1; i <= nb; i++) if (!(bid[i] in head)) print bid[i] "\t" bval[bid[i]] }
  ' 2>/dev/null || true)
  [ -n "$_open" ] || return 0
  [ "$(printf '%s\n' "$_open" | wc -l | tr -d ' ')" -gt "$_sweep_at" ] || return 0
  (cd "$PROJECT_DIR" 2>/dev/null && git rev-parse --verify --quiet HEAD > /dev/null 2>&1) || return 0
  while IFS=$'\t' read -r _id _b; do
    [ -n "$_id" ] || continue
    _b="${_b#\'}"
    _b="${_b%\'}"
    # Only a SHA-shaped value can be PROVED absent; anything else is merely
    # unusable, which is not a licence to delete it.
    case "$_b" in
      "" | *[!0-9a-fA-F]*) continue ;;
    esac
    (cd "$PROJECT_DIR" 2>/dev/null \
      && git rev-parse --verify --quiet "${_b}^{commit}" > /dev/null 2>&1) \
      || _dead="${_dead} ${_id}"
  done <<< "$_open"
  printf '%s' "${_dead# }"
}

# (D268) Per-window eviction for the three per-task record families. The old
# per-family `tail -n 20` pipelines evicted the OLDEST record — structurally
# the longest-lived OUTER task's own anchor — so at 20 nested completions the
# outer task uploaded an empty snapshot for its real work.
#
# (D274) D268 pinned open windows but still capped them BY COUNT, and that cap
# reached the same defect from the other side. The cap kept the newest opens
# and dropped the oldest, and the oldest open window is structurally the live
# enclosing OUTER — while the twenty newer opens that triggered the eviction
# are exactly the ones kept. Measured on the hook itself: 19 concurrently open
# children left the outer's anchor and its deliverable intact; 20 lost both,
# and with two enclosing levels open, BOTH anchors went and both tasks
# completed with empty snapshots over real commits. No count cap can be made
# safe here. An open window is by definition a claim that has not completed,
# so any open window may still be live, and the order records happen to sit in
# the cache says nothing about which one is not; raising the cap only moves
# the boundary. The decided policy:
#   1. OPEN windows are NEVER evicted by a count cap. A window is open when
#      its TASK_BASE_REF_<id> has no TASK_HEAD_REF_<id> partner (the head is
#      written at completion), so a still-in-flight task's anchor never falls
#      to a cap however many newer claims arrive. Housekeeping must not cost
#      correctness, and evicting a live window costs a whole task's snapshot.
#   2. The count becomes a SWEEP THRESHOLD, not an eviction threshold. Above
#      STRIDE_OPEN_WINDOW_SWEEP_AT concurrently open windows, open windows are
#      tested for liveness and only the PROVABLY DEAD are dropped — a base
#      that does not resolve to a commit, and nothing else. Such a record is
#      one another_open_window_exists and the attribution walk already skip,
#      so dropping it removes nothing any reader would have used. When every
#      open window is live they are ALL kept: the selector deliberately
#      returns more than the threshold rather than erase live work.
#
#      STATED BOUND, and what it does NOT cover. The cache holds one
#      open-window record per claim whose base still resolves — so growth is
#      bounded by the number of claims whose base commit still exists, not by
#      history and not by a count. Be honest about the gap this leaves: on a
#      fast-forward-only trunk, which is what .stride.md's before_doing
#      produces (checkout main, pull --rebase, checkout -B), an ABANDONED
#      claim's base is a main commit that resolves forever, so the sweep will
#      never reap it. That population is bounded by nothing but the number of
#      claims that were abandoned, at one cache line each.
#      That is a deliberate trade, not an oversight. Bounding it by a count is
#      exactly what produced D274, because NOTHING IN THE CACHE distinguishes
#      an abandoned claim from a live enclosing outer — both are simply a base
#      with no head — so any count-based reaper must guess, and its wrong
#      guesses erase live work. Reaping abandoned claims properly needs a
#      signal the cache does not carry (claim age, or an unclaim that removes
#      the record), which is a separate change; until then this subsystem
#      prefers unbounded-but-tiny growth over erasing a live task's anchor.
#      Cost follows the same bound: above the threshold the sweep spends one
#      git process per open window, and a claim runs the selector twice (the
#      identity rewrite and finalize_before_doing), so it pays that twice.
#      Both are well inside the hook budget at any plausible open count.
#
#      The sweep is fail-safe in both directions — it runs no git at all below
#      the threshold, and when the repository cannot be read, or a base is not
#      even SHA-shaped, it proves nothing dead and keeps everything.
#   3. CLOSED windows newer than the oldest kept open window are ALL kept:
#      they are nested windows inside a live outer's window, and evicting one
#      would make the outer absorb that nested task's commits into its own
#      snapshot (a wrong-diff, strictly worse than the no-diff this subsystem
#      degrades to everywhere else). Cache growth from this clause is bounded
#      by the outer window's lifetime, at ~one line per nested completion.
#   4. CLOSED windows older than every open window cap at 20, oldest evicted
#      first — a window that predates every live claim cannot intersect any
#      live attribution.
#   5. Eviction is PER WINDOW, not per family — the decided answer to the
#      family-desync question: head/owned records are kept exactly when their
#      base survives, and an orphan head/owned record (no base partner) is
#      dropped, since attribution needs both ends and a half-bounded window
#      is unusable. The independent per-family caps could previously leave
#      one; this selector cannot.
# Emits the kept lines (base, then head, then owned, each family in cache
# order) from $ENV_CACHE. $1 (optional) is a base-ref KEY to exclude because
# the caller appends a fresh record for that task itself; the sweep threshold
# drops by one then, matching the pre-D274 cap's reserved-slot arithmetic.
select_kept_window_records() {
  local _reserve="${1:-}" _sweep_at="$STRIDE_OPEN_WINDOW_SWEEP_AT" _dead _recs
  [ -n "$_reserve" ] && _sweep_at=$((_sweep_at - 1))
  _dead=$(dead_open_window_ids "$_sweep_at" "$_reserve" || true)
  # (D287) THE PROMOTION SITE. These three greps used to run against the cache
  # FILE, so a record-shaped line planted inside a quoted value matched, was
  # kept, and was written back by write_env_cache as a record in its own right.
  # They now run against record-START lines only. Parsed ONCE and reused, not
  # three times: the fail-closed empty on a broken quote must be the same answer
  # for all three families, or a partly-parsed cache could keep a head record
  # whose base was dropped — precisely the orphan state the selector's kept[]
  # gate exists to prevent.
  # (D287 r2) NOT `|| true`. This function is the only one of the four whose
  # output is written BACK: by the time finalize_before_doing calls it, the
  # `_preserved` grep has already stripped every family line from the cache, so
  # an empty return here does not mean "read nothing this once" — it means the
  # rebuild commits a cache with every window record gone, permanently. When the
  # erased record is a live enclosing OUTER task's own anchor, that task's
  # completion finds no record, hits select_task_snapshot_base's owner-mismatch
  # refusal and uploads an EMPTY snapshot over real commits: the D274 outcome,
  # and the under-report direction this defect's own security note says must not
  # be traded for. So a parse failure propagates and both call sites skip the
  # rewrite, leaving the previous cache intact — write_env_cache's existing
  # contract. Found by the security review of this change; the first version
  # returned empty here and called it fail-closed.
  _recs=$(cache_window_record_lines) || return 1
  {
    printf '%s\n' "$_recs" | grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' 2>/dev/null \
      | grep -v -e '^TASK_BASE_REF_TRUSTED=' -e '^TASK_BASE_REF_OWNER=' \
          -e '^TASK_BASE_REF_UNPROVEN=' || true
    printf '::FAMILY::\n'
    printf '%s\n' "$_recs" | grep -e '^TASK_HEAD_REF_[A-Za-z0-9_]*=' 2>/dev/null || true
    printf '::FAMILY::\n'
    printf '%s\n' "$_recs" | grep -e '^TASK_OWNED_[A-Za-z0-9_]*=' 2>/dev/null || true
  } | awk -v reserve="$_reserve" -v dead="$_dead" '
    BEGIN { if (dead != "") { nd = split(dead, _d, " "); for (k = 1; k <= nd; k++) deadid[_d[k]] = 1 } }
    $0 == "::FAMILY::" { fam++; next }
    fam == 0 {
      if (reserve != "" && index($0, reserve "=") == 1) next
      id = $0; sub(/^TASK_BASE_REF_/, "", id); sub(/=.*/, "", id)
      # (D274) A swept dead open window: its head/owned partners cannot
      # survive it, and the kept[] gate below drops them with it.
      if (id in deadid) next
      nb++; bline[nb] = $0; bid[nb] = id
      next
    }
    fam == 1 {
      id = $0; sub(/^TASK_HEAD_REF_/, "", id); sub(/=.*/, "", id)
      nh++; hline[nh] = $0; hid[nh] = id; head[id] = 1
      next
    }
    {
      id = $0; sub(/^TASK_OWNED_/, "", id); sub(/=.*/, "", id)
      no++; oline[no] = $0; oid[no] = id
    }
    END {
      for (i = 1; i <= nb; i++) open[i] = (bid[i] in head) ? 0 : 1
      # (D274) Every surviving open window is kept, however many there are.
      # The only open windows already gone are the ones the liveness sweep
      # proved dead before this awk ever saw them.
      for (i = 1; i <= nb; i++) if (open[i]) keep[i] = 1
      # anchor = oldest KEPT open window (keep[] holds only opens so far)
      anchor = 0
      for (i = 1; i <= nb; i++) if (keep[i]) { anchor = i; break }
      limit = (anchor > 0) ? anchor - 1 : nb
      c = 0
      for (i = limit; i >= 1; i--) if (!open[i]) { c++; if (c <= 20) keep[i] = 1 }
      if (anchor > 0) for (i = anchor; i <= nb; i++) if (!open[i]) keep[i] = 1
      for (i = 1; i <= nb; i++) if (keep[i]) { print bline[i]; kept[bid[i]] = 1 }
      for (i = 1; i <= nh; i++) if (hid[i] in kept) print hline[i]
      for (i = 1; i <= no; i++) if (oid[i] in kept) print oline[i]
    }'
}

# (D255) Compute the owned set for the loop delta H0..H1: space-separated full
# SHAs in rev-list order (newest first), capped at 20; over the cap prints the
# OVERFLOW sentinel; identical endpoints print nothing (the empty record).
compute_owned_set() {
  local _h0="${1:-}" _h1="${2:-}" _sha _out="" _count=0
  [ -n "$_h0" ] && [ -n "$_h1" ] || return 0
  [ "$_h0" = "$_h1" ] && return 0
  while IFS= read -r _sha; do
    [ -n "$_sha" ] || continue
    _count=$((_count + 1))
    if [ "$_count" -gt 20 ]; then
      printf '%s' "$STRIDE_OWNED_OVERFLOW"
      return 0
    fi
    if [ -n "$_out" ]; then _out="${_out} ${_sha}"; else _out="$_sha"; fi
  done <<< "$( (cd "$PROJECT_DIR" 2>/dev/null && git rev-list "${_h0}..${_h1}" 2>/dev/null) || true)"
  printf '%s' "$_out"
}

# (D255) Convert a non-empty owned set into one "<from> <to>" range line for
# expand_own_ranges. The set is contiguous by construction (a single H0..H1
# delta), so the range is <oldest>^ <newest>. Prints nothing — callers fall
# back — when the set is empty/OVERFLOW or the oldest commit's parent does not
# resolve (root commit, or a rebase already rewrote the SHAs away; matching
# nothing over-reports, the documented safer failure).
owned_set_to_range() {
  local _set="${1:-}" _s _first="" _last=""
  [ -n "$_set" ] || return 0
  [ "$_set" = "$STRIDE_OWNED_OVERFLOW" ] && return 0
  for _s in $_set; do
    [ -n "$_first" ] || _first="$_s"
    _last="$_s"
  done
  [ -n "$_last" ] || return 0
  (cd "$PROJECT_DIR" 2>/dev/null && git rev-parse --verify "${_last}^" > /dev/null 2>&1) || return 0
  printf '%s^ %s' "$_last" "$_first"
}

# (D273) The claim-time stamp for a per-task window, and the horizon that
# decides when one is too old to keep vouching in another_open_window_exists.
#
# Nothing else ages an open window out. There is no unclaim path in this
# script, claim expiry is server-side only, and D274 made the position
# stronger, not weaker: it removed D268's open-window COUNT cap outright
# because no count can distinguish a live enclosing outer from an abandoned
# claim, so open windows are now pinned unconditionally and the only aging
# left — dead_open_window_ids — retires a record solely when its base fails
# to resolve. D274's own comment states the residue: on a fast-forward-only
# trunk an abandoned claim's base is a main commit that resolves forever, so
# that sweep can never reap it. One such record re-enabled the D255 narrowing
# for every later outermost task in the checkout, permanently — the D271
# under-report, resurrected by a record with no owner. This is that bound.
task_base_at_key() { task_record_key 'TASK_BASE_AT_' "${1:-}"; }

# Epoch seconds recorded when the given task's window opened, or empty.
task_base_at_for() {
  local _key
  _key=$(task_base_at_key "${1:-}")
  [ -n "$_key" ] || return 1
  read_task_record "$_key"
}

#
# 4 hours matches the orchestrator activation marker's own freshness window
# (skills/stride-workflow/SKILL.md: markers older than started_at + 4h are
# treated as stale). Past it the session that opened the window is presumed
# dead, and this plugin already says so about its own marker.
#
# The trade is deliberate and one-sided: an outer window that legitimately
# outlives the horizon stops absorbing, so tasks nesting inside it take the
# wide path and OVER-report — the same safe direction D271 chose, and never
# the under-report this exists to prevent.
#
# STRIDE_OPEN_WINDOW_MAX_AGE_SECS overrides the default. It is validated
# digits-only and used solely as an arithmetic operand, never interpolated
# into a command string; any other value falls back to the default rather
# than disabling the check.
open_window_max_age_secs() {
  local _v="${STRIDE_OPEN_WINDOW_MAX_AGE_SECS:-}"
  case "$_v" in
    '' | *[!0-9]*) printf '14400'; return 0 ;;
  esac
  # Width matters as much as shape. `test -gt` parses with strtoimax, so a
  # value past 2^63 makes the comparison an ERROR rather than a false — and
  # with no `set -e` the `&& continue` just short-circuits, so the age check
  # stops running and narrowing silently comes back. That is the one direction
  # this function must never fail in, so an out-of-range value degrades to the
  # documented default exactly as a non-numeric one does. Ten digits is ~317
  # years, well past any horizon anyone means.
  [ "${#_v}" -le 10 ] || { printf '14400'; return 0; }
  printf '%s' "$_v"
}

# (D271) TRUE (status 0) when some task OTHER than $1 has an OPEN window on
# record — a TASK_BASE_REF_<id> line with no TASK_HEAD_REF_<id> partner (the
# head is written only at completion; the same open-window definition D268's
# select_kept_window_records uses). Decides whether the D255 owned-set
# narrowing is safe for the completing task's own capture: the commits the
# narrowing drops (base..H0 — manual mid-task commits) can only be absorbed
# by a window that is still open, so with no other open window the completing
# task is OUTERMOST and must keep the wide D244 purity/window path instead.
# Closed windows deliberately do not count: a sibling that already completed
# can never absorb anything. Bases are read from the cache FILE and heads via
# the sourced env, matching attributed_commit_ranges, so this predicate stays
# consistent with the attribution walk it gates — including its validation:
# a candidate base must resolve AND be an ancestor of HEAD, or the line is a
# stale record (a garbage or rebase-orphaned SHA), not a live window. Without
# that check a single dead base-without-head cache line would flip this
# predicate forever — no unclaim path ever removes one, and D268 eviction
# deliberately pins open windows — narrowing every later outermost task in
# the checkout and silently resurrecting the exact D271 under-report. The
# skip direction is the safe one: treating a dubious line as no-window means
# the wide path, which over-reports but never loses this task's own work.
# (D273) The lifecycle gap that note recorded is now closed by the age check
# below: a genuinely abandoned claim leaves a resolvable, ancestor
# base-without-head line that no unclaim path ever removes, so without an age
# horizon one dead record vouches as a live absorber forever.
another_open_window_exists() {
  local _self="${1:-}" _self_key="" _line _bkey _id _b _bt _age _now _max_age
  [ -n "$_self" ] && _self_key=$(task_base_ref_key "$_self")
  # (D273) Resolve the clock and the horizon once, outside the loop. Without a
  # usable clock the age check cannot run, and the D271 rule is that every
  # validation failure takes the wide path — so answer "no open window" rather
  # than vouching for records this predicate cannot age.
  _now=$(date +%s 2>/dev/null || printf '')
  case "$_now" in
    '' | *[!0-9]*) return 1 ;;
  esac
  _max_age=$(open_window_max_age_secs)
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _bkey="${_line%%=*}"
    [ -n "$_self_key" ] && [ "$_bkey" = "$_self_key" ] && continue
    case "$_bkey" in
      TASK_BASE_REF_TRUSTED | TASK_BASE_REF_OWNER | TASK_BASE_REF_UNPROVEN) continue ;;
    esac
    _id="${_bkey#TASK_BASE_REF_}"
    [ -n "$(task_head_ref_for "$_id")" ] && continue
    _b="${_line#*=}"
    _b="${_b#\'}"
    _b="${_b%\'}"
    [ -n "$_b" ] || continue
    (cd "$PROJECT_DIR" 2>/dev/null \
      && git rev-parse --verify --quiet "${_b}^{commit}" > /dev/null 2>&1 \
      && git merge-base --is-ancestor "$_b" HEAD 2>/dev/null) || continue
    # (D273) Resolvable and an ancestor is necessary but not sufficient: an
    # abandoned claim leaves exactly that shape behind permanently. Age the
    # record out by WHEN THE WINDOW WAS OPENED, read from the TASK_BASE_AT_<id>
    # stamp its own claim wrote.
    #
    # The stamp exists because the obvious free signal is wrong. The base
    # commit's committer time (`git show -s --format=%ct`) measures when the
    # repo last moved, not when the claim happened: a task claiming on a HEAD
    # that is already older than the horizon — the ordinary case at the start
    # of a session, and for the whole life of a long outer window that never
    # re-anchors — would read as abandoned from its first nested completion
    # onward. That silently disables the D255 narrowing 23u/23w pin, in the
    # common case rather than a corner, and no fixture that commits just
    # before claiming can see it. The direction is safe, but a "safe" answer
    # given almost always is not the behaviour this predicate is for.
    #
    # A MISSING stamp reads as dead, and that is deliberate rather than
    # conservative-by-accident: every window opened by a hook carrying this
    # change is stamped at claim, so an unstamped record was written by an
    # older version — which makes it, by construction, from an earlier
    # session. That is exactly the abandoned population this closes, and it
    # needs no migration. A mixed-version checkout costs the older agent's
    # live window the narrowing, which over-reports; the one direction D271
    # forbids stays unreachable. Age exactly AT the horizon counts as live
    # (strict -gt).
    _bt=$(task_base_at_for "$_id") || _bt=""
    # Digits-only is NOT enough on either count, and both failures were
    # reproduced. A leading zero makes `$(( ))` read the stamp as OCTAL, and
    # `08` is not a valid octal literal — under bash 3.2 (the macOS default
    # this hook runs on) that is a FATAL expansion error, so it does not skip
    # the record, it kills the hook mid-completion. A value past 2^63 wraps
    # silently instead, making the difference hugely negative and the dead
    # record read LIVE — the under-report direction, and the same trap the
    # horizon override already guards on its side. Bound the width and force
    # base 10; `date +%s` produces neither shape, so anything that trips this
    # was written by something other than a claim.
    case "$_bt" in
      '' | *[!0-9]*) continue ;;
    esac
    [ "${#_bt}" -le 10 ] || continue
    # The age needs a LOWER bound as well as an upper one. A stamp ahead of the
    # clock is not a small age, it is a NEGATIVE one, and negative trivially
    # passes `-gt $_max_age` — so a window stamped in the future would vouch as
    # live for as long as the stamp stayed ahead, which is exactly the
    # forever-live record this whole check exists to retire. Reachable without
    # tampering: a clock corrected backwards after NTP or a suspend, or a
    # checkout shared between hosts that disagree on time. A stamp that cannot
    # be a valid age is a validation failure like any other, so it takes the
    # wide path.
    _age=$((_now - 10#$_bt))
    [ "$_age" -ge 0 ] || continue
    [ "$_age" -gt "$_max_age" ] && continue
    return 0
  done <<< "$( { cache_window_record_lines || true; } | grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' 2>/dev/null || true)"
  return 1
}

# (D273) Answer the D255 outermost gate for a RETRY. $1 is the narrowed= value
# the primary capture persisted for THIS task (empty when the state file
# predates D273, belongs to another task, or was never written); $2 is the
# task id. TRUE (status 0) means narrow.
#
# A verdict reached at capture time is a FACT ABOUT THAT CAPTURE. Re-deriving
# it at retry time asks a different question — "is a window open NOW" — and a
# completion landing in the gap between a failed PUT and before_review changes
# the answer, so the retry uploaded a wide snapshot over a narrowed one and
# double-attributed a commit. Replaying removes the gap entirely.
#
# The value is compared, never executed or interpolated. Only the exact literal
# `yes` narrows: `no` and ANY other content — a truncated write, a hand-edited
# line, a tampered file — fall through to the wide path, which over-reports but
# can never lose this task's own work. Only a genuinely ABSENT verdict
# re-derives, which is exactly the older-state-file case that must keep
# behaving as it did before this change.
replay_narrowing_decision() {
  case "${1:-}" in
    yes) return 0 ;;
    '') another_open_window_exists "${2:-}" ;;
    *) return 1 ;;
  esac
}

# (D273) The per-task home for that verdict, mirroring the TASK_OWNED_ family.
# .stride-diff-upload-state carries a `narrowed=` line too, but it holds ONE
# task at a time and record_diff_upload_state TRUNCATES it — so the interleaved
# completion this fix is about (another task completing between a failed PUT
# and before_review) overwrites the state file with its own task_id and the
# verdict is gone exactly when it is needed. A per-task record survives that,
# because a completion only rewrites the line it owns.
#
# LIFETIME IS BOUNDED WITHOUT ANY EVICTION CHANGE. Reads happen between a
# capture and that same completion's before_review — seconds to minutes — and
# the next claim rebuilds the cache from select_kept_window_records, which
# emits only the base/head/owned families and therefore drops this one
# wholesale. A record that outlives its completion is cleared by the next
# claim, and until then it is one short line. Nothing here touches D268/D274
# eviction policy.
task_narrowed_key() { task_record_key 'TASK_NARROWED_' "${1:-}"; }

task_narrowed_for() {
  local _key
  _key=$(task_narrowed_key "${1:-}")
  [ -n "$_key" ] || return 1
  read_task_record "$_key"
}

# Best-effort, never fatal — a missing record only means the resolver falls
# back to the state file and then to re-derivation.
record_task_narrowed() {
  local _tid="${1:-}" _val="${2:-}" _key
  [ -n "$_tid" ] || return 0
  _key=$(task_narrowed_key "$_tid")
  [ -n "$_key" ] || return 0
  # (D288 r3) Filter status consumed here, not left to the sink — see
  # record_task_head_ref.
  local _body
  # The bail is diagnosed, not silent. Bailing here skips write_env_cache
  # entirely, so the sink gates' messages are unreachable from this site and a
  # refusal would otherwise produce no stderr at all - which is the failure
  # mode this whole defect is about, in miniature.
  _body=$(drop_cache_key "$_key") || {
    printf 'stride-hook: could not filter the env cache for %s; keeping the previous cache (%s)\n' \
      "$_key" "$ENV_CACHE" >&2
    return 0
  }
  {
    [ -n "$_body" ] && printf '%s\n' "$_body"
    printf "%s=%s\n" "$_key" "$(sq_escape "$_val")"
  } | write_env_cache --preserve-from-cache || true
  return 0
}

# (D273) The capture-time verdict for $1, from the per-task record first and
# the state file's `narrowed=` line second. Empty means no verdict is on
# record and the caller must re-derive — the older-state-file case, and the
# case where a claim rebuilt the cache between capture and retry.
resolve_capture_narrowing() {
  local _rec
  _rec=$(task_narrowed_for "${1:-}") || _rec=""
  if [ -n "$_rec" ]; then
    printf '%s' "$_rec"
    return 0
  fi
  printf '%s' "${2:-}"
}

# (D236) capture_changed_files diffs base..working-tree, so every commit made
# between an outer task's claim and its completion lands in that task's
# snapshot — including commits from tasks that claimed, worked and completed
# inside the outer task's window. Measured on W2066's sequence: claim A,
# claim+complete B and C from inside A, complete A, and A's snapshot was
# [fileB.txt, fileC.txt, outerA.txt] when only outerA.txt is A's. Dispatcher
# mode makes that routine rather than exotic.
#
# (D244) The under-reporting direction of the window model is closed by the
# per-window PURITY classification below. The original limitation: a commit the
# OUTER task makes WHILE a nested task is in flight falls inside that nested
# task's (base, head] window, so the flat window union attributed it to the
# child and the outer task's snapshot lost it. Measured: claim A, claim B,
# A commits, B commits, complete B, complete A gave B=[nested_b, outer_during]
# and A=[outer_after] — A lost outer_during.
#
# True per-COMMIT ownership is NOT recoverable from topology: hooks fire only
# on claim/complete, so nothing observes the interior of a window, and two
# commits that both exist before the next hook invocation are topologically
# indistinguishable (D244's investigation verified this twice). What topology
# DOES decide per window: how many of its commits no OTHER recorded window
# covers (its RESIDUAL). One residual commit is the window task's own
# auto-commit — the window is PURE and its whole span is subtracted, exactly
# the D236 behaviour. Two or more residual commits mean at least one was
# authored outside any nested task (the outer task committing mid-window) and
# topology cannot say which — the window is AMBIGUOUS, only the commits other
# windows cover are subtracted, and the residual falls through into the
# caller's own snapshot (over-report, the documented safer failure).
#
# (D255) On top of that fallback sits an ADDITIVE per-window ownership signal:
# run_stride_section records the HEAD delta around the after_doing command
# loop as TASK_OWNED_<id> (see task_owned_key and friends). A NON-EMPTY,
# non-OVERFLOW record names that window's commits exactly — the purity
# classification is superseded for that window, the completing task's own
# capture narrows to exactly its delta, and a later outer completion subtracts
# exactly those SHAs. Absent, EMPTY, or OVERFLOW records keep the purity
# fallback above: OVERFLOW because a truncated list would mis-subtract, and
# EMPTY because with manual (non-hook-mediated) commits "the loop authored
# nothing" does not mean "the task authored nothing" — a zero-commit hook run
# beside a manual commit is exactly the ambiguity topology cannot resolve, so
# the zero-commit-steal geometry (D244's P2 probe) deliberately remains the
# open, documented behaviour (test 23v pins it). STRIDE_NO_OWN_COMMITS
# sentinel semantics are unchanged. Test 23r pins the fallback keeping the
# outer's mid-window commit; 23u/23w/23x pin hook-mediated ownership.
#
# (D272) That steal RATCHETS, and the amplification is pinned rather than
# fixed — a decision, not an oversight. Each childless window subtracted here
# joins the covered set, which re-grounds the NEXT childless window's residual
# to 1, so k childless completions interleaved with k outer commits strip all k
# from their author's snapshot; at k = the outer's commit count the walk below
# yields no runs and emits STRIDE_NO_OWN_COMMITS — an EMPTY snapshot for a task
# that really committed, colliding with the sentinel's legitimate meaning.
# 23v2 pins k=2, the k=3 terminal shape, the two shapes that do NOT ratchet
# (an empty window has nothing to steal; a real-commit child's owned record
# supersedes its window and breaks the chain), and that the victim is whichever
# ENCLOSING task committed inside the window at ANY depth — a childless
# grandchild takes the middle task's commit and leaves the outermost intact.
# Do not read the empty snapshot as this shape's signature: it appears only
# when the victim's tree is clean at completion. With ANY uncommitted work the
# same terminal loss uploads an ordinary-looking non-empty snapshot (just the
# WIP), so there is no artifact-level tell at all — measured, and the reason
# the pin exists rather than a detection rule.
#
# The obvious fix — a PRESENT-and-empty record on a NONEMPTY window becomes
# subtract-nothing — was implemented behind a flag and MEASURED against the
# suite before being declined: 665 → 652 passed, 13 failed. Nine of the 13 are
# pre-existing pins — 23j, 23n ×3 (its outer's paths, its hunk of a file both
# touched, and its no-commits-of-its-own case), 23o, 23p ×2, 23q, 23v — and the
# other four are 23v2's own ratchet assertions flipping, which is the branch
# working. It is not scoped to this geometry because it is
# not scoped to this SIGNAL: every fixture whose after_doing does not commit
# records a present-and-empty set on EVERY window, so the branch stops
# subtracting nested windows at all for hand-committing agents — 23j's outer
# came back [fileB.txt, outerA.txt] and 23p's outermost [deepC.txt, midB.txt,
# topA.txt]. That is not "W2066 re-opened for 23n's geometry"; it is D236
# reverted for the whole fallback world. 23n and 23v are the same shape to
# every signal attribution has (one-commit window, present-and-empty record),
# differing only in who authored the commit — which is exactly what topology
# cannot see — so no branch keyed on that record can keep one and fix the
# other. Narrowing instead which windows may GROUND another window's purity
# (excluding weak-pure ones from the fixpoint pool) does break the chain, but
# on the same measurement it degrades every nested fallback geometry toward
# over-report as well, and each of those is its own decided trade (23p, 23s);
# it is recorded here as the live candidate if the ratchet is ever re-decided.
#
# Two things the cap does NOT do for this, both measured rather than reasoned,
# because the obvious reading of D268 is that it eventually bounds the cascade
# and it does not. (1) The 20-window cap is UNREACHABLE while the victim is
# open: select_kept_window_records keeps every CLOSED window newer than the
# oldest kept OPEN one, so 22 childless windows inside one live outer evicted
# nothing (23 base records live) and all 22 of its commits were stolen. k is
# bounded by the session, not by the cache. (2) Nested-window eviction would
# only ever RESTORE a stolen commit to its author — removing a window removes
# coverage — but that is vacuous here for the same reason, and it is NOT the
# eviction this fleet actually hits. The one that fires is the OPEN-window cap,
# which evicts the OLDEST open window — structurally the live outer, not the
# abandoned claims this comment's neighbours reason about — and its direction
# is total loss, not restoration. Filed separately; it is D268's own selector,
# reachable with no ratchet involved at all.
#
# (D236) The commit RANGES that belong to the completing task, one per line as
# "<from> <to>" (a git range from..to). Empty output means "no nested work to
# subtract" and the caller keeps its ordinary single-base path unchanged.
#
# Why ranges rather than one anchor: a nested task completes before the outer
# one, so its commits are contiguous — but the OUTER task may have committed
# both before and after that window. Its own commits are therefore one or more
# contiguous RUNS separated by nested windows, and each run is expressible as a
# git range. The common shape (dispatch, then the outer task's own auto-commit
# at completion) is a single run; the interleaved shape W2066 actually produced
# is two. A single anchor cannot express two runs, which is why this returns a
# list.
attributed_commit_ranges() {
  local _own_base="${1:-}" _self="${2:-}"
  [ -n "$_own_base" ] || return 0
  command -v git > /dev/null 2>&1 || return 0
  git rev-parse --verify "$_own_base" > /dev/null 2>&1 || return 0

  local _self_key=""
  [ -n "$_self" ] && _self_key=$(task_base_ref_key "$_self")

  # Collect every OTHER task's window. A window needs BOTH ends: the base says
  # where it started, the D236 head record says where it stopped. Without the
  # end marker the window cannot be bounded, so it is skipped rather than
  # guessed at — that degrades to today's behaviour, never to a wrong diff.
  local _windows="" _line _bkey _id _b _h
  local _owned_rec _oc _superseded="" _owned_covered=""
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _bkey="${_line%%=*}"
    [ "$_bkey" = "$_self_key" ] && continue
    case "$_bkey" in
      TASK_BASE_REF_TRUSTED | TASK_BASE_REF_OWNER | TASK_BASE_REF_UNPROVEN) continue ;;
    esac
    _id="${_bkey#TASK_BASE_REF_}"
    _b="${_line#*=}"; _b="${_b#\'}"; _b="${_b%\'}"
    _h=$(task_head_ref_for "$_id")
    [ -n "$_b" ] && [ -n "$_h" ] || continue
    git rev-parse --verify "$_b" > /dev/null 2>&1 || continue
    git rev-parse --verify "$_h" > /dev/null 2>&1 || continue
    git merge-base --is-ancestor "$_own_base" "$_b" 2>/dev/null || continue
    git merge-base --is-ancestor "$_h" HEAD 2>/dev/null || continue
    # (D255) A window whose task recorded a NON-EMPTY owned set names its
    # commits exactly — the purity heuristic is superseded for that window.
    # Empty, OVERFLOW, and absent all fall back to the D244 classification:
    # OVERFLOW because a truncated list would mis-subtract, and empty because
    # with manual (non-hook-mediated) commits "the loop authored nothing" does
    # not mean "the task authored nothing" — treating '' as subtract-nothing
    # re-opens W2066 for every task whose agent commits by hand (23n's exact
    # fixture geometry). SHAs a later rebase orphaned simply match nothing in
    # the walk below → over-report, the documented safer failure.
    _owned_rec=""
    if _owned_rec=$(task_owned_for "$_id") \
      && [ -n "$_owned_rec" ] && [ "$_owned_rec" != "$STRIDE_OWNED_OVERFLOW" ]; then
      _superseded="${_superseded}${_b} ${_h}"$'\n'
      for _oc in $_owned_rec; do
        _owned_covered="${_owned_covered}${_oc}"$'\n'
      done
    fi
    _windows="${_windows}${_b} ${_h}"$'\n'
  done <<< "$( { cache_window_record_lines || true; } | grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' 2>/dev/null || true)"

  [ -n "$_windows" ] || return 0

  # (D244/D256) Classify each window before subtracting it, instead of pouring
  # every window into one flat union. Per window: expand it once with rev-list
  # (`<base>..<head>` is base-EXCLUSIVE, which is load-bearing — a nested
  # task's base is normally the outer task's own last commit, and including it
  # attributed the outer's work to its child), then count its RESIDUAL — the
  # commits nothing KNOWN covers. Residual <= 1: the window is PURE (the one
  # residual commit is that task's own auto-commit) and its full span joins the
  # covered set, exactly the D236 behaviour. Residual >= 2: the window is
  # AMBIGUOUS — an outer commit landed mid-window and cannot be told apart from
  # the task's own — so it contributes NOTHING and its commits fall through to
  # the caller (over-reporting, the safer failure).
  #
  # (D256) What counts as "known" is a PURITY FIXPOINT, not the union of all
  # other windows. D244 computed each residual against every other window's
  # full span, and that let two windows open CONCURRENTLY (both bases predating
  # the outer's mid-window commit) mutually "cover" the commits they merely
  # share: each residual dropped to <= 1, both misclassified PURE, and the
  # union subtracted the outer's own commit — losing work from its author's
  # snapshot, the exact direction D244 exists to close. Mutual coverage is
  # evidence of AMBIGUITY, not purity: a commit has one owner. So windows are
  # classified smallest-set-first, and a window's residual is reduced only by
  # (a) commits in a D255 owned record — exact per-commit ownership, no
  # nesting needed — and (b) the sets of windows ALREADY classified PURE that
  # NEST inside this window (subset, never mere intersection, never an
  # ambiguous window). In the sibling geometry neither sibling finds a pure
  # sub-window, both read AMBIGUOUS, and the outer keeps its commit while
  # absorbing the siblings' — over-reporting, the documented safer failure.
  # Cost: proper nesting with clean windows (23p) classifies identically; the
  # 23s depth-3 geometry, which is topologically IDENTICAL to the sibling
  # repro (per-commit ownership is not recoverable from topology — see the
  # header comment), now resolves the same way the sibling case must: the
  # outer over-reports instead of a window whose residual was explained by an
  # ambiguous neighbour subtracting. That loss-vs-noise trade is decided in
  # favour of never losing an author's commit; 23s pins it. Sets live in a
  # scratch dir (newline SHA files; wc/grep do the set algebra) — if mktemp
  # fails, every fallback window is treated as AMBIGUOUS, which degrades to
  # pure over-report, never to a lost commit. The rev-list expansion stays
  # O(n) and the subset tests O(n^2) in recorded windows, bounded by the
  # cache cap — well inside the hook budget the flat union was sized for.
  local _w _wb _wh _covered_set="" _set_i
  local _fixdir _fx_n=0 _fx_order="" _fx_pool="" _fx_f _fx_p _fx_size _fx_idx _residual_count
  _fixdir=$(mktemp -d 2>/dev/null) || _fixdir=""
  if [ -n "$_fixdir" ]; then
    printf '%s' "$_owned_covered" > "$_fixdir/owned"
    while IFS= read -r _w; do
      [ -n "$_w" ] || continue
      # (D255) Owned windows contribute their exact SHAs (already collected in
      # _owned_covered, which also seeds the fixpoint's known set) and skip
      # classification.
      if [ -n "$_superseded" ] && printf '%s' "$_superseded" | grep -qxF -- "$_w"; then
        continue
      fi
      _wb="${_w%% *}"; _wh="${_w##* }"
      _set_i=$(git rev-list "${_wb}..${_wh}" 2>/dev/null || true)
      [ -n "$_set_i" ] || continue
      _fx_n=$((_fx_n + 1))
      printf '%s\n' "$_set_i" > "$_fixdir/set_$_fx_n"
      _fx_size=$(wc -l < "$_fixdir/set_$_fx_n" | tr -d ' ')
      _fx_order="${_fx_order}${_fx_size} ${_fx_n}"$'\n'
    done <<< "$_windows"
    # Duplicate base+head lines collapse to identical set files; the first
    # classifies on its own merits and the duplicate then nests inside it —
    # same disposition as the old identical-line skip, stated so the removal
    # of that skip is deliberate rather than lost.
    while IFS= read -r _fx_idx; do
      [ -n "$_fx_idx" ] || continue
      _fx_idx="${_fx_idx#* }"
      _fx_f="$_fixdir/set_$_fx_idx"
      : > "$_fixdir/cov"
      [ -s "$_fixdir/owned" ] && grep -xFf "$_fixdir/owned" "$_fx_f" >> "$_fixdir/cov" 2>/dev/null
      for _fx_p in $_fx_pool; do
        # Pool set ⊆ this set? (non-empty, and no line of it falls outside)
        if [ -s "$_fx_p" ] && ! grep -vxFf "$_fx_f" "$_fx_p" 2>/dev/null | grep -q .; then
          cat "$_fx_p" >> "$_fixdir/cov"
        fi
      done
      if [ -s "$_fixdir/cov" ]; then
        _residual_count=$(grep -cvxFf "$_fixdir/cov" "$_fx_f" 2>/dev/null || true)
      else
        _residual_count=$(wc -l < "$_fx_f" | tr -d ' ')
      fi
      # An errored count (empty) defaults to the full set size, never to 0 —
      # every failure in this fixpoint must degrade toward AMBIGUOUS
      # (over-report), and a zero default is the one branch that would fail
      # toward subtracting a span, i.e. toward lost work.
      [ -n "$_residual_count" ] || _residual_count=$(wc -l < "$_fx_f" | tr -d ' ')
      if [ "${_residual_count:-1}" -le 1 ]; then
        _covered_set="${_covered_set}$(cat "$_fx_f")"$'\n'
        _fx_pool="$_fx_pool $_fx_f"
      fi
    done <<< "$(printf '%s' "$_fx_order" | sort -n -k1,1 -k2,2)"
    rm -rf "$_fixdir"
  fi

  # (D255) Owned windows' exact SHAs join the covered set alongside the
  # classified windows' contributions.
  _covered_set="${_covered_set}${_owned_covered}"

  # Walk the task's range oldest-first, dropping covered commits and grouping
  # the survivors into contiguous runs.
  local _run_start="" _run_prev="" _out=""
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    if printf '%s' "$_covered_set" | grep -qxF "$_c"; then
      # A nested commit closes any run that was open.
      if [ -n "$_run_start" ]; then
        _out="${_out}${_run_start}^ ${_run_prev}"$'\n'
        _run_start=""; _run_prev=""
      fi
      continue
    fi
    [ -z "$_run_start" ] && _run_start="$_c"
    _run_prev="$_c"
  done <<< "$(git rev-list --reverse "${_own_base}..HEAD" 2>/dev/null || true)"
  [ -n "$_run_start" ] && _out="${_out}${_run_start}^ ${_run_prev}"$'\n'

  # EMPTY OUTPUT IS AMBIGUOUS, so it is never used to mean two things. No
  # output at all means "no nested window applies here" and the caller keeps
  # its ordinary single-base behaviour. But a task whose commits were ALL made
  # by nested tasks — the outer task whose own deliverable lives in a gitignored
  # subrepo, so it has no outer-repo commits of its own — also produces zero
  # runs, and that must yield an EMPTY snapshot rather than falling back to the
  # base and absorbing its children's work. The sentinel keeps the two apart.
  if [ -z "$_out" ]; then
    printf '%s' "$STRIDE_NO_OWN_COMMITS"
    return 0
  fi
  printf '%s' "$_out"
  return 0
}
# (D226) Choose the diff anchor for the task actually being completed, in
# precedence order:
#   1. the per-task record written by THAT task's own claim — survives any
#      number of nested claims, so the outer task keeps its own base;
#   2. the shared TASK_BASE_REF, when nothing proves it belongs elsewhere —
#      caches written before this fix carry no owner stamp, and refusing them
#      would break diff capture for every task already in flight on upgrade;
#   3. REFUSE, when the shared base carries an owner stamp naming a DIFFERENT
#      task. A wrong diff presented as correct is worse than no diff, and the
#      pipeline already treats `[]` as a valid shape (test 8d).
# Prints the base on stdout; returns 1 for the refusal case. The refusal is
# announced on stderr because silence is the actual defect being fixed here.
select_task_snapshot_base() {
  local _tid="${1:-}" _own _owner
  _own=$(task_base_ref_for "$_tid")
  if [ -n "$_own" ]; then
    printf '%s' "$_own"
    return 0
  fi
  _owner="${TASK_BASE_REF_OWNER:-}"
  if [ -n "$_tid" ] && [ -n "$_owner" ] && [ "$_owner" != "$_tid" ]; then
    printf 'stride-hook: REFUSING the changed_files diff for task %s — cached TASK_BASE_REF %s was written by task %s, so the captured diff would belong to another task. Uploading an empty snapshot instead.\n' \
      "$_tid" "${TASK_BASE_REF:-<empty>}" "$_owner" >&2
    return 1
  fi
  # A base whose claim could not prove WHOSE it was. Without this the absence
  # of a stamp reads identically to a legacy cache, and rule 2 hands out the
  # base anyway — so two claims that both declined the gate (one systematic
  # cause, an oversized response, happening twice in a window) leave an outer
  # task diffing from a nested claim's base with nothing to contradict. The
  # marker is what separates "written by this version, owner unknown" from
  # "written before this version existed": a legacy cache has neither marker
  # nor record, so it still captures and pitfall 1 stands.
  if [ -n "$_tid" ] && [ "${TASK_BASE_REF_UNPROVEN:-}" = "1" ]; then
    printf 'stride-hook: REFUSING the changed_files diff for task %s — cached TASK_BASE_REF %s was written by a claim that could not prove which task it belonged to, and no base is recorded for this task. Uploading an empty snapshot instead.\n' \
      "$_tid" "${TASK_BASE_REF:-<empty>}" >&2
    return 1
  fi
  printf '%s' "${TASK_BASE_REF:-}"
  return 0
}

# Helper: persist the per-file diff snapshot, then fire-and-forget PUT it to
# the Stride server. Runs only for after_doing; capture and upload failures
# are both non-fatal. URL and token are resolved by resolve_stride_api_url /
# resolve_stride_api_token — preferring $PROJECT_DIR/.stride_auth.md so the
# upload works regardless of whether the agent's completion curl used literal
# values or shell variables ($STRIDE_API_URL / $STRIDE_API_TOKEN), with the
# $COMMAND literal extraction kept as a back-compat fallback.
# Placed before the early-return guards so tests can source this script and
# invoke finalize_after_doing in isolation.
finalize_after_doing() {
  if [ "${HOOK_NAME:-}" = "after_doing" ]; then
    local snapshot _tid _base_candidate
    # (D127) Target the task id from the /complete URL, not the env cache, so a
    # stale TASK_ID from a hidden claim response cannot route the diff to the
    # wrong task. Fall back to the env-cache TASK_ID only if the URL carries no id.
    # (D226) Resolved BEFORE the base is chosen — the base now depends on which
    # task is completing, which it did not when this ran after the resolution.
    _tid=$(task_id_from_command "${COMMAND:-}")
    [ -n "$_tid" ] || _tid="${TASK_ID:-}"

    # (D142) Run the base through the trust guard ONCE per process and
    # memoize the judgment. The refresh call runs AFTER the section's
    # commands — an ## after_doing that pushes the default branch moves
    # origin/main to HEAD, which would make a CORRECT base look like a
    # strict ancestor of the branch point and recompute it to HEAD (empty
    # snapshot overwriting the good early upload). The early pre-command
    # resolution sees the pre-push origin refs, so it is the authoritative
    # judgment for the whole task window. The subshell cd anchors git to the
    # project repo (the empty-section path reaches here without
    # run_stride_section's cd); the guard's recompute notice stays on stderr
    # so it reaches the hook output instead of being swallowed by the
    # capture call's 2>/dev/null.
    if [ "${SNAP_BASE_RESOLVED_DONE:-false}" != "true" ]; then
      # (D226) Pick the anchor for THIS task first. A refusal (the shared base
      # demonstrably belongs to another task) short-circuits capture entirely:
      # an empty snapshot is a valid shape, another task's diff is not.
      if _base_candidate=$(select_task_snapshot_base "$_tid"); then
        SNAP_BASE_RESOLVED=$( (cd "$PROJECT_DIR" 2>/dev/null && resolve_snapshot_base "$_base_candidate") || printf '%s' "$_base_candidate")
        SNAP_BASE_REFUSED=false
        # (D236) Commits made by tasks that claimed and completed INSIDE this
        # task's window are not this task's work. Empty means nothing to
        # subtract, and the ordinary single-base path runs unchanged.
        SNAP_OWN_RANGES=$( (cd "$PROJECT_DIR" 2>/dev/null && attributed_commit_ranges "$SNAP_BASE_RESOLVED" "$_tid") || printf '')
      else
        SNAP_BASE_RESOLVED=""
        SNAP_BASE_REFUSED=true
      fi
      SNAP_BASE_RESOLVED_DONE=true
    fi
    # (D255) Record what this task's OWN after_doing loop authored — once per
    # completion, and only when run_stride_section actually ran the loop (the
    # empty-section/plugin-mode path never sets the flag, so it records nothing
    # and stays byte-identical). '' is recorded deliberately: "ran and authored
    # nothing" is a fact, distinct from no-record — though consumers currently
    # treat both as fallback (see attributed_commit_ranges). Written BEFORE the
    # capture so the before_review self-heal on this same completion reads the
    # fresh record, and gated on SNAP_OWNED_RECORDED so the pre-loop early call
    # can never consume a stale record from a previous completion of this id.
    if [ "${SNAP_OWNED_LOOP_RAN:-false}" = "true" ] && [ "${SNAP_OWNED_RECORDED:-false}" != "true" ]; then
      SNAP_OWNED_SET=$(compute_owned_set "${SNAP_OWNED_H0:-}" "${SNAP_OWNED_H1:-}")
      record_task_owned "$_tid" "$SNAP_OWNED_SET"
      SNAP_OWNED_RECORDED=true
    fi
    # (D273) The narrowing verdict this capture reaches, persisted below so the
    # before_review self-heal REPLAYS it instead of re-deriving it against
    # retry-time state. Default "no": every path that never reaches the
    # narrowing branch — a refusal, no owned record, an empty owned range —
    # captured wide, and wide is also the value a tampered or unreadable line
    # must degrade to.
    local _narrowed=no
    # (D273) Stamp the SAFE default before the capture runs, not just the real
    # verdict after it — the same write-before-capture guarantee record_task_owned
    # takes above, and for the same reason. Without it a completion killed
    # inside capture_changed_files (exactly what the self-heal exists for) can
    # leave a PREVIOUS window's `yes` on record for the retry to replay,
    # narrowing a window whose verdict was never computed. That is reachable on
    # the unproven-claim path, where the self-filter at claim has no owner id to
    # work from — so it must be closed here, where no id is needed. A kill
    # anywhere in the capture now leaves `no`, the wide answer.
    record_task_narrowed "$_tid" "$_narrowed"
    if [ "${SNAP_BASE_REFUSED:-false}" = "true" ]; then
      snapshot='[]'
    else
      # (D255) When this completion's own loop authored commits, its committed
      # contribution is exactly that delta plus the uncommitted working tree —
      # commits in base..H0 (an outer task's mid-window work, or this task's
      # own pre-hook manual commits) fall out. (D271) That trade is safe ONLY
      # while some OTHER task's window is still open: a nested task's dropped
      # commits fall back into the enclosing task's later snapshot — the
      # documented over-report, pinned by 23u/23w. An OUTERMOST task has no
      # absorber, so the same narrowing silently under-reported its own manual
      # mid-task commits (worst observed: a 22-child outer whose snapshot was
      # only the junk its after_doing swept, its real deliverable missing).
      # With no other open window the owned range is instead UNIONED with the
      # task's attributed ranges: SNAP_OWN_RANGES was computed BEFORE the loop
      # ran, so the loop's own commits are in no attributed range and are no
      # longer uncommitted by capture time — replacing the narrowing with the
      # attributed ranges alone would trade losing the manual commits for
      # losing the sweep's. When there are no attributed ranges at all (no
      # other windows recorded), _cap_ranges stays empty and the plain
      # base..working-tree diff already covers both.
      local _cap_ranges
      _cap_ranges="${SNAP_OWN_RANGES:-}"
      if [ "${SNAP_OWNED_RECORDED:-false}" = "true" ] \
        && [ -n "${SNAP_OWNED_SET:-}" ] \
        && [ "${SNAP_OWNED_SET:-}" != "$STRIDE_OWNED_OVERFLOW" ]; then
        local _owned_range
        _owned_range=$(owned_set_to_range "${SNAP_OWNED_SET:-}")
        if [ -n "$_owned_range" ]; then
          if another_open_window_exists "$_tid"; then
            _cap_ranges="$_owned_range"
            _narrowed=yes
          elif [ -n "$_cap_ranges" ]; then
            _cap_ranges="${_cap_ranges}"$'\n'"${_owned_range}"
          fi
        fi
      fi
      snapshot=$(capture_changed_files "${SNAP_BASE_RESOLVED:-}" "$_cap_ranges" 2>/dev/null || printf '[]')
    fi
    printf '%s\n' "$snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
    # (D236) Stamp where THIS task's commits stop, so an outer task completing
    # later can subtract this window. Written after the capture so it records
    # the HEAD the snapshot was actually taken against.
    record_task_head_ref "$_tid"
    # (D273) Stamp the verdict this capture reached, next to the head it was
    # taken against and BEFORE any PUT is attempted — so the before_review
    # self-heal replays it however the PUT goes, and whatever another agent's
    # completion does to the shared state file in the gap.
    record_task_narrowed "$_tid" "$_narrowed"

    # No-op silently if any prerequisite is missing — preserves the on-disk
    # snapshot for legacy --argjson cf consumers.
    if [ "${HAS_JQ:-false}" = "true" ] && command -v curl > /dev/null 2>&1 && [ -n "$_tid" ]; then
      local _api_base _token
      _api_base=$(resolve_stride_api_url)
      _token=$(resolve_stride_api_token)
      if [ -n "$_api_base" ] && [ -n "$_token" ]; then
        # Upload via the shared D61 transport-envelope helper.
        local _http_code
        _http_code=$(upload_changed_files_snapshot "$_tid" "$_api_base" "$_token")
        # (W1094) Record the outcome after EVERY PUT attempt so the
        # before_review self-heal can verify it on a fresh timeout budget.
        # A skipped PUT (missing preconditions) deliberately writes nothing:
        # missing state means "no healthy upload on record" and the retry
        # re-checks the same preconditions itself. (D142) The resolved base
        # rides along so the self-heal reuses this task window's judgment.
        record_diff_upload_state "$_tid" "$_http_code" "${SNAP_BASE_RESOLVED:-}"
        # (D273) Persist the narrowing verdict alongside the base, appended
        # after the truncating write the same way refused_base is. The base
        # alone was never enough: the self-heal re-DERIVED the D255 outermost
        # gate at retry time, so a completion landing in the gap between a
        # failed PUT and before_review could flip another_open_window_exists
        # and let the retry upload a WIDE snapshot over this narrowed one —
        # one commit then attributed to two tasks. A decision reached at
        # capture time is a fact about THIS capture; re-deriving it later asks
        # a different question and gets a different answer.
        printf 'narrowed=%s\n' "$_narrowed" >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
        # (D226) A refusal is durable, not just a line on stderr that scrolls
        # away — the same reasoning as W1658's unresolved marker. It also stops
        # the before_review self-heal from re-capturing against the foreign
        # base and quietly undoing the refusal on its fresh budget.
        if [ "${SNAP_BASE_REFUSED:-false}" = "true" ]; then
          printf 'refused_base=yes\n' >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
        fi
      fi
    fi
  fi
}

# (D142) Rewrite TASK_BASE_REF — and re-record the dirty baseline — AFTER the
# ## before_doing section has run. The section's `git pull` moves HEAD, so a
# base captured before it anchors the after_doing diff at the PRE-pull commit
# and the snapshot spans another clone's pulled work (the D132/W1678
# incident). Called from the main flow right after run_stride_section returns
# for the before_doing route, regardless of the section's exit code (the
# claim already succeeded — PostToolUse cannot veto it, and a partially-run
# section still leaves HEAD more accurate than the pre-pull value) and with
# no jq dependency (the identity refresh is jq-gated; this must not be).
# Skips silently when HEAD is unresolvable (not a git repo) — the pre-section
# strip already removed any inherited TASK_BASE_REF in that case.
finalize_before_doing() {
  [ "${HOOK_NAME:-}" = "before_doing" ] || return 0
  local _base_ref _preserved _records _owner _key _tmp_cache
  _base_ref=$( (cd "$PROJECT_DIR" && git rev-parse HEAD) 2>/dev/null || true)
  [ -n "$_base_ref" ] || return 0
  # TASK_BASE_REF_TRUSTED marks a base written by THIS post-before_doing
  # capture: it is the task branch point by construction, so the trust
  # guard's branch-point rule (rule 3) does not second-guess it — a workflow
  # that pushes its own task commits before completing would otherwise make
  # a correct base look like it predates the branch point. Inherited caches
  # (older plugin, previous session) lack the marker and get the full guard.
  # (D226) The shared keys are rewritten as before, but an owner stamp and a
  # per-task record ride alongside so a later NESTED claim cannot make this
  # task's anchor unrecoverable. Earlier tasks' records are carried across
  # untouched — that is what lets the OUTER task keep its own base — and
  # capped so the cache cannot grow without bound over a long-lived checkout.
  # (D226) Ownership is stamped ONLY when this claim parsed its own identity.
  # On the unparsed path TASK_ID still holds the PREVIOUS task's id, so
  # stamping would overwrite that task's record with this claim's HEAD and
  # then vouch for it — a matching owner that silently defeats the refusal.
  # Writing neither leaves the outer task's record intact and correct, and the
  # nested task falls back to the shared base, which is genuinely its own.
  # Stamped from the id the gate VALIDATED, never from the sourced TASK_ID —
  # see the gate's own comment. A failed cache write then costs the identity
  # refresh but can never desynchronize the stamp from the base it vouches for.
  _owner=""
  _key=""
  if [ "${TASK_IDENTITY_REFRESHED:-0}" = "1" ]; then
    _owner="${TASK_OWNER_ID:-}"
    [ -n "$_owner" ] && _key=$(task_base_ref_key "$_owner")
    [ -n "$_key" ] || _owner=""
  fi
  # (D273) TASK_BASE_AT_ is dropped here and re-emitted below for exactly the
  # windows the selector keeps, so a stamp can never outlive the base it dates.
  # TASK_NARROWED_ is dropped and NOT re-emitted: a claim opens a new window,
  # and a verdict from a previous completion must not survive into it — the
  # same reasoning that clears .stride-diff-upload-state at claim time.
  # (D288) awk, not grep, for the reason set out above drop_cache_key: a grep
  # that refuses to read a cache carrying a byte >= 0x80 returns nothing here,
  # and this set is what carries GOAL_*, BOARD_* and TASK_DESCRIPTION across a
  # claim. The patterns are the same ones, one per line, in the same order -
  # TRUSTED/OWNER/UNPROVEN stay spelled out even though the generic
  # TASK_BASE_REF_ rule already covers them, exactly as the grep spelled them.
  # (D288) A filter that could not read the cache is NOT an empty preserved
  # set. Treated as one, this site would omit GOAL_*, BOARD_* and
  # TASK_DESCRIPTION and commit the result at exit 0 - the same silent loss,
  # one tool along. Routed into the existing _rebuild_ok sentinel below, whose
  # contract is already "the previous cache stands, untouched".
  local _preserved_failed=0
  if ! _preserved=$(drop_task_window_records); then
    _preserved=""
    _preserved_failed=1
  fi
  # (D268) The cap keeps a long-lived checkout from growing the cache without
  # bound — but the old per-family `tail` dropped the OLDEST record, which is
  # structurally the still-open OUTER task's own anchor, and at 20 nested
  # completions the outer uploaded an empty snapshot for its real work. The
  # pre-D268 comment's safety argument (evicted task falls through to the
  # shared base, finds an owner stamp naming a different task, and REFUSES
  # loudly — no-diff, never wrong-diff) was written for OTHER tasks' records
  # and still holds as the degrade for the pathological cases; it was never an
  # argument for evicting a live window's anchor. Eviction is now per-window
  # and open-window-aware — see select_kept_window_records for the decided
  # policy: open windows pinned outright (D274 — no count cap can tell a live
  # enclosing outer from an abandoned claim, so a liveness sweep above the
  # threshold is the aging bound instead), closed windows inside a live
  # outer's window all kept (evicting one would
  # be a wrong-diff, the outer absorbing that nested task's commits), older
  # closed windows capped at 20, and head/owned records live and die with
  # their base so the cap can never leave a half-bounded window. The refusal
  # path in select_task_snapshot_base is untouched.
  # (D287 r2) A parse failure means "do not rebuild", not "rebuild with nothing".
  local _rebuild_ok=1
  [ "$_preserved_failed" = 1 ] && _rebuild_ok=0
  _records=$(select_kept_window_records "$_key") || { _records=""; _rebuild_ok=0; }
  # (D255) A claim opens a fresh window for this task: its own owned record
  # from a PREVIOUS completion must not survive into it. Other tasks' records
  # pass through untouched (they are the whole point). Unproven claims (no
  # validated owner) cannot name their record and leave it — the completion's
  # own re-record overwrites it before capture on the normal path. With $_key
  # reserved above the selector already drops this task's whole previous
  # window (base, head, owned together); this filter remains for the unproven
  # path where no key could be reserved.
  local _owned_self_key=""
  [ -n "$_owner" ] && _owned_self_key=$(task_owned_key "$_owner")
  if [ -n "$_owned_self_key" ]; then
    _records=$(printf '%s\n' "$_records" | grep -v -e "^${_owned_self_key}=" || true)
  fi
  # (D273) Carry each KEPT window's claim-time stamp forward. This is not a
  # change to eviction policy and deliberately not part of
  # select_kept_window_records — which windows survive is decided there and
  # read here; a new family simply follows that decision instead of being
  # silently erased by the rebuild. Without this the stamps vanish at the next
  # claim, every surviving window reads as unstamped, and the predicate would
  # retire live windows wholesale.
  local _at_lines="" _rec_line _rec_id _rec_key _rec_stamp _at_key _at_now _narrowed_self_key
  while IFS= read -r _rec_line; do
    case "$_rec_line" in
      TASK_BASE_REF_*) : ;;
      *) continue ;;
    esac
    _rec_id="${_rec_line%%=*}"
    _rec_id="${_rec_id#TASK_BASE_REF_}"
    case "$_rec_id" in
      "" | TRUSTED | OWNER | UNPROVEN) continue ;;
    esac
    # Look each record up through the same sanitizer and the same shape-checked
    # reader every other per-task lookup uses, and RE-EMIT it rather than
    # copying the matched line. Copying a grep hit would promote a forged
    # continuation line to a first-class record that survives the next claim;
    # going through read_task_record means only a well-formed record is ever
    # carried, and sq_escape re-normalizes it on the way out.
    _rec_key=$(task_base_at_key "$_rec_id")
    if [ -n "$_rec_key" ] && _rec_stamp=$(read_task_record "$_rec_key"); then
      [ -n "$_rec_stamp" ] && _at_lines="${_at_lines}${_rec_key}=$(sq_escape "$_rec_stamp")"$'\n'
    fi
    # (D273) The narrowing verdict travels with its window too. Dropping the
    # whole family at claim looked right — a claim opens a new window, so a
    # stale verdict must not survive into it — but that reasoning is about the
    # CLAIMING task's own record, and applying it to every task destroyed the
    # verdict of any OTHER task still waiting to self-heal. An exploratory
    # session drove it: one unrelated claim between a failed PUT and
    # before_review left the retry with no verdict on either carrier (the state
    # file is separately rm'd at claim), so it re-derived the D255 gate — the
    # exact question this fix exists to stop it re-asking — and narrowed a
    # snapshot that had captured wide, orphaning two real commits into no
    # task's diff at all. Self's own record is dropped below, the same way
    # self's owned record is.
    _rec_key=$(task_narrowed_key "$_rec_id")
    if [ -n "$_rec_key" ] && _rec_stamp=$(read_task_record "$_rec_key"); then
      _at_lines="${_at_lines}${_rec_key}=$(sq_escape "$_rec_stamp")"$'\n'
    fi
  done <<< "$_records"
  # (D273) Self's verdict belongs to the window this claim replaces. The
  # reserve above already drops self's whole window from $_records on the
  # proven path, and this mirrors _owned_self_key for the rest.
  #
  # The UNPROVEN path keeps self's stale verdict, and that is a deliberate
  # trade rather than an oversight. With no validated owner there is no id this
  # can trust, and filtering on an unvalidated one would drop ANOTHER task's
  # verdict — the exact data-loss shape this whole carry-forward exists to
  # close, swapped for a much narrower one. The residue is only readable by a
  # completion that reaches before_review's self-heal without
  # finalize_after_doing having run (killed between the pre and post phases),
  # and only alongside an equally stale TASK_OWNED_ record, whose survival on
  # this same path is the pre-existing D255 trade. Before D273 that corner
  # re-derived and could narrow too, so this widens an already-unsound
  # configuration rather than opening a new class.
  if [ -n "$_owner" ]; then
    _narrowed_self_key=$(task_narrowed_key "$_owner")
    if [ -n "$_narrowed_self_key" ]; then
      _at_lines=$(printf '%s' "$_at_lines" | grep -v -e "^${_narrowed_self_key}=" || true)
      [ -n "$_at_lines" ] && _at_lines="${_at_lines}"$'\n'
    fi
  fi
  # (D226) Atomic, via the shared writer. A true race still loses one task's
  # record (last writer wins) — which degrades to a REFUSAL rather than a
  # wrong diff, since the surviving owner stamp will name someone else — but
  # no reader can observe a partial file.
  if [ "$_rebuild_ok" = 0 ]; then
    # (D287 r2) The previous cache stands, untouched. Skipping this rewrite is
    # the same failure contract write_env_cache already keeps, and it is the
    # only branch that does not erase live window anchors.
    printf 'stride-hook: skipping the env-cache rebuild; the previous cache is kept intact\n' >&2
    return 0
  fi
  {
    [ -n "$_preserved" ] && printf '%s\n' "$_preserved"
    [ -n "$_records" ] && printf '%s\n' "$_records"
    [ -n "$_at_lines" ] && printf '%s' "$_at_lines"
    echo "TASK_BASE_REF=$(sq_escape "$_base_ref")"
    echo "TASK_BASE_REF_TRUSTED='1'"
    if [ -n "$_owner" ]; then
      echo "TASK_BASE_REF_OWNER=$(sq_escape "$_owner")"
      echo "$_key=$(sq_escape "$_base_ref")"
      # (D273) Stamp this window's open time next to the base it dates, from
      # the same validated owner id. An unstampable clock leaves no line,
      # which the predicate reads as dead — the safe direction.
      _at_key=$(task_base_at_key "$_owner")
      _at_now=$(date +%s 2>/dev/null || printf '')
      case "$_at_now" in
        '' | *[!0-9]*) : ;;
        *) [ -n "$_at_key" ] && echo "$_at_key=$(sq_escape "$_at_now")" ;;
      esac
    else
      # Marks a base this version wrote without being able to prove its owner,
      # so a later completion can tell it apart from a pre-fix cache.
      echo "TASK_BASE_REF_UNPROVEN='1'"
    fi
  } | write_env_cache || true
  export TASK_BASE_REF="$_base_ref"
  export TASK_BASE_REF_TRUSTED="1"
  if [ -n "$_owner" ]; then
    export TASK_BASE_REF_OWNER="$_owner"
    export "$_key=$_base_ref"
    unset TASK_BASE_REF_UNPROVEN
  else
    export TASK_BASE_REF_UNPROVEN="1"
    unset TASK_BASE_REF_OWNER
  fi
  # (W1457→D142) The dirty baseline moves with the base capture: post-pull
  # paths hashed against the post-pull base, so the exclusion set and the
  # diff anchor can never disagree.
  record_dirty_baseline "$_base_ref"
  return 0
}

# --- (W1094) Self-heal for the changed_files upload ---
# The after_doing gate can burn the whole 600s hook budget, killing the
# process before or during the snapshot PUT — or the PUT itself returned
# non-2xx. before_review (PostToolUse on the same completion curl) runs on a
# FRESH budget, so it verifies the recorded outcome and re-captures +
# re-PUTs when no healthy upload is on record for the current task.
# Best-effort: never returns non-zero, and never touches the snapshot file
# unless a retry PUT is actually possible (preserves the on-disk snapshot
# for degraded environments and legacy consumers).
self_heal_changed_files_upload() {
  [ "${HOOK_NAME:-}" = "before_review" ] || return 0
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  command -v curl > /dev/null 2>&1 || return 0

  # (D127) Prefer the task id from the /complete URL over the env-cache TASK_ID
  # so the self-heal re-PUTs to the CORRECT task even when a hidden claim left a
  # stale TASK_ID behind. Fall back to the env cache only if the URL has no id.
  local _tid
  _tid=$(task_id_from_command "${COMMAND:-}")
  [ -n "$_tid" ] || _tid="${TASK_ID:-}"
  [ -n "$_tid" ] || return 0

  # Healthy 2xx recorded for THIS task → do not re-upload (snapshot
  # semantics anchor at after_doing time; avoid pointless API load).
  # Missing file, different task id, or non-2xx/empty code → retry.
  local _state_file="$PROJECT_DIR/.stride-diff-upload-state"
  local _state_task="" _state_code="" _state_base="" _state_narrowed=""
  if [ -f "$_state_file" ]; then
    _state_task=$(grep '^task_id=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_code=$(grep '^http_code=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_base=$(grep '^base=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    # (D273) The capture-time narrowing verdict, read on the same terms as the
    # base: only a record for THIS task may speak for this capture.
    if [ "$_state_task" = "$_tid" ]; then
      _state_narrowed=$(grep '^narrowed=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    fi
  fi
  if [ "$_state_task" = "$_tid" ]; then
    case "$_state_code" in
      2*) return 0 ;;
    esac
  fi

  # Resolve credentials BEFORE overwriting the snapshot — when no PUT is
  # possible the stale on-disk snapshot must be left untouched.
  local _api_base _token
  _api_base=$(resolve_stride_api_url)
  _token=$(resolve_stride_api_token)
  if [ -z "$_api_base" ] || [ -z "$_token" ]; then
    return 0
  fi

  # Re-capture against the claim-time base ref. The subshell cd anchors git
  # to the project repo without disturbing the main script's cwd (the
  # before_review section's own `cd "$PROJECT_DIR"` has not run yet).
  # (D142) Prefer the base finalize_after_doing resolved and persisted for
  # THIS task — re-resolving here would re-judge against origin refs the
  # after_doing section's own `git push` may have moved (a correct base
  # would look stale and recompute to HEAD, emptying the snapshot). Only
  # when no persisted judgment exists (process killed before any PUT) run
  # the trust guard fresh — the retry must never resurrect a stale base the
  # primary capture would have refused.
  local _snapshot _http_code _snap_base _sel _own_ranges="" _refused=false
  if [ "$_state_task" = "$_tid" ] && [ -n "$_state_base" ]; then
    _snap_base="$_state_base"
  elif _sel=$(select_task_snapshot_base "$_tid"); then
    # (D226) Same per-task anchor selection as the primary capture. Without
    # this the retry would re-derive the shared TASK_BASE_REF and re-upload
    # the very diff the primary capture refused — on a fresh budget, after
    # the refusal notice had already scrolled past.
    _snap_base=$( (cd "$PROJECT_DIR" 2>/dev/null && resolve_snapshot_base "$_sel") || printf '%s' "$_sel")
  else
    _snap_base=""
    _refused=true
  fi
  # (D236) Attribution belongs to EVERY non-refused path, not just the
  # base-selection branch. Computing it inside the `elif` missed the
  # persisted-base branch above — which is the branch actually taken whenever
  # the primary PUT failed and left state on disk, i.e. exactly when this
  # self-heal runs. The retry then re-captured base..working-tree and
  # re-uploaded the over-collected snapshot OVER the narrowed one, silently
  # undoing this whole fix; last write wins on the server. Review reproduced
  # it with a curl stub returning 500.
  if [ "$_refused" != "true" ]; then
    _own_ranges=$( (cd "$PROJECT_DIR" 2>/dev/null && attributed_commit_ranges "$_snap_base" "$_tid") || printf '')
  fi
  # (D255) Same owned-set override as the primary capture: without it a failed
  # PUT would let the retry re-upload the base-wide snapshot OVER the narrowed
  # one (the exact D236 last-write-wins geometry this self-heal already guards
  # for attribution). The record was written by finalize_after_doing before any
  # PUT was attempted, so it is on disk whenever this retry runs after a
  # recorded loop; a completion killed before the record falls back cleanly.
  # (D271) And the same outermost gate as the primary capture: without it the
  # retry would re-narrow and upload the under-reporting snapshot OVER the
  # wide one the primary capture just took — the same last-write-wins shape,
  # in the opposite direction. Self's own window is closed by now (the head
  # was recorded before the primary PUT); the predicate excludes self, so for
  # a single sequential agent it answers as it did at capture time. When
  # ANOTHER completion lands in the gap between the failed PUT and this retry
  # (multi-agent on one checkout), the answer can shift and the retry's
  # judgment diverges from the primary's — over-report direction on the
  # demonstrated open-to-closed flip.
  # (D273) That divergence is now closed from the other end: the primary
  # capture PERSISTS its verdict and this retry replays it, so the retry
  # answers the question the capture answered rather than re-asking it of
  # retry-time state. Only the D255 narrowing verdict is replayed —
  # attribution above stays re-derived on purpose, because the retry's wide
  # path covers the sweep commit without the primary's union logic.
  local _owned_rec _owned_range _retry_narrowed=no
  if [ "$_refused" != "true" ] && _owned_rec=$(task_owned_for "$_tid"); then
    if [ -n "$_owned_rec" ] && [ "$_owned_rec" != "$STRIDE_OWNED_OVERFLOW" ] \
      && replay_narrowing_decision "$(resolve_capture_narrowing "$_tid" "$_state_narrowed")" "$_tid"; then
      _owned_range=$(owned_set_to_range "$_owned_rec")
      if [ -n "$_owned_range" ]; then
        _own_ranges="$_owned_range"
        _retry_narrowed=yes
      fi
    fi
  fi
  if [ "$_refused" = "true" ]; then
    _snapshot='[]'
  else
    _snapshot=$( (cd "$PROJECT_DIR" && capture_changed_files "$_snap_base" "${_own_ranges:-}") 2>/dev/null || printf '[]')
  fi
  printf '%s\n' "$_snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  _http_code=$(upload_changed_files_snapshot "$_tid" "$_api_base" "$_token")
  record_diff_upload_state "$_tid" "$_http_code" "$_snap_base"
  # (D273) Same truncation reasoning as the refusal stamp below: re-record the
  # verdict THIS upload actually captured under, so the durable record still
  # describes the snapshot the server now holds. BOTH carriers are updated, not
  # just the state file — resolve_capture_narrowing prefers the per-task
  # record, so leaving that one stale would make the durable claim true of the
  # file a human reads and false of the one the code reads. They can genuinely
  # diverge: _retry_narrowed is yes only when owned_set_to_range resolved, so a
  # replayed yes whose range comes back empty uploads wide.
  printf 'narrowed=%s\n' "$_retry_narrowed" >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  record_task_narrowed "$_tid" "$_retry_narrowed"
  # (D226) record_diff_upload_state TRUNCATES the state file, so a refusal
  # that reaches the retry must be re-stamped or the durable record is erased
  # by the very path that most needs it on file.
  if [ "$_refused" = "true" ]; then
    printf 'refused_base=yes\n' >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  fi
  # (W1658) before_review is the LAST retry. If it still did not land, the diff
  # is definitively lost for this task — surface it LOUDLY (distinct from the
  # per-attempt warning in upload_changed_files_snapshot) and mark the state file
  # unresolved so the failure is actionable and never silently swallowed. A later
  # successful PUT overwrites the state file, clearing the mark.
  case "$_http_code" in
    2*) : ;;
    *)
      printf 'stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task %s (HTTP %s) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.\n' \
        "$_tid" "$_http_code" >&2
      printf 'unresolved=yes\n' >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
      ;;
  esac
  return 0
}

# --- Per-hook command timeouts (W1454) ---
# parser.md's budget table is the contract: 600s for every section (D229 —
# a hang detector, not a performance gate). The budget is
# per SECTION (wall clock across all its commands), not per command — each
# command is wrapped with the REMAINING budget so a section can never exceed
# its table value regardless of command count, keeping every inner budget
# under the 900s hooks.json outer ceiling.

# Documented per-section budget in seconds.
default_budget_for_section() {
  # (D229) These are HANG DETECTORS, not performance gates. A developer's
  # .stride.md commands are theirs; the executor must never kill one for being
  # slow. Sized well above every measured legitimate run — cold before_doing
  # 80s, cold after_doing 138s (200s+ with --cover), and ~1.9x that again under
  # concurrent load — so only a genuinely stuck command trips them.
  case "$1" in
    *) printf '600' ;;
  esac
}

# Server-supplied timeout (milliseconds) for the named hook entry — jq
# sibling of extract_hook_env, selecting `.timeout` instead of `.env`.
# No jq or no payload → prints nothing (documented defaults apply),
# mirroring extract_hook_env's jq-gated no-fallback design.
extract_hook_timeout_ms() {
  local _payload="$1" _name="$2"
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "$_payload" ] || return 0
  printf '%s' "$_payload" | jq -r --arg name "$_name" '
    ((.hooks // []) + (if (has("hook") and (.hook | type == "object")) then [.hook] else [] end)
     | map(select(type == "object" and .name == $name))
     | (first // {}) | .timeout
    ) | select(type == "number") | floor
  ' 2>/dev/null || true
}

# Resolve the section budget in seconds. Precedence:
#   STRIDE_HOOK_TIMEOUT_OVERRIDE (integer seconds; test/ops escape hatch)
#   > server hook-entry timeout (ms, rounded up to whole seconds)
#   > documented default.
# Clamped to 890s so no inner budget can reach the 900s hooks.json outer
# ceiling (dormant for spec-compliant 600s server values). after_doing
# runs at PRE phase — no tool_response exists yet, so it always resolves
# to the documented 600s default.
resolve_section_budget() {
  local _section="$1" _budget="" _ms=""
  if [[ "${STRIDE_HOOK_TIMEOUT_OVERRIDE:-}" =~ ^[0-9]+$ ]] && [ "${STRIDE_HOOK_TIMEOUT_OVERRIDE}" -gt 0 ]; then
    _budget="$STRIDE_HOOK_TIMEOUT_OVERRIDE"
  else
    _ms=$(extract_hook_timeout_ms "${RESPONSE_PAYLOAD:-}" "$_section")
    if [[ "$_ms" =~ ^[0-9]+$ ]] && [ "$_ms" -gt 0 ]; then
      _budget=$(( (_ms + 999) / 1000 ))
    fi
  fi
  [ -z "$_budget" ] && _budget=$(default_budget_for_section "$_section")
  [ "$_budget" -gt 890 ] && _budget=890
  printf '%s' "$_budget"
}

# (W1456) Shell-semantics line-continuation check. Returns 0 when the
# LOGICAL line ends in a backslash that escapes the newline — i.e. the
# backslash is unescaped and not inside single quotes. Mirrors real shell
# rules: outside quotes and inside double quotes, backslash-newline is a
# continuation; inside single quotes a backslash is a literal character;
# `\\` at end of line is an escaped backslash, not a continuation. Callers
# pass the accumulated logical line so quote state carries across joins.
line_continues() {
  # NOTE: _len must be declared in a SEPARATE local statement — the words
  # of a single `local a=$1 b=${#a}` command are expanded before any
  # assignment lands, so ${#_line} would read the (unset) outer variable
  # and abort under `set -u`.
  local _line="$1"
  local _i=0 _len=${#_line} _state="none" _c
  while [ "$_i" -lt "$_len" ]; do
    _c="${_line:_i:1}"
    if [ "$_state" = "single" ]; then
      [ "$_c" = "'" ] && _state="none"
      _i=$((_i + 1))
    elif [ "$_c" = "\\" ]; then
      # Backslash escapes the next char; with no next char it escapes the
      # newline — that IS the continuation marker.
      [ $((_i + 1)) -eq "$_len" ] && return 0
      _i=$((_i + 2))
    elif [ "$_state" = "double" ]; then
      [ "$_c" = '"' ] && _state="none"
      _i=$((_i + 1))
    else
      case "$_c" in
        "'") _state="single" ;;
        '"') _state="double" ;;
      esac
      _i=$((_i + 1))
    fi
  done
  return 1
}

# (W1455) Portable millisecond clock. GNU date supports %N (nanoseconds);
# BSD/macOS date prints a literal trailing 'N', so probe once and fall back
# to perl Time::HiRes (ships with macOS), then to whole-second granularity
# times 1000. STRIDE_HOOK_TIME_SOURCE forces the source for tests:
# ns|perl|seconds.
STRIDE_TIME_SOURCE_RESOLVED=""
resolve_time_source() {
  if [ -z "$STRIDE_TIME_SOURCE_RESOLVED" ]; then
    case "${STRIDE_HOOK_TIME_SOURCE:-}" in
      ns|perl|seconds) STRIDE_TIME_SOURCE_RESOLVED="${STRIDE_HOOK_TIME_SOURCE}" ;;
      *)
        if [[ "$(date +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
          STRIDE_TIME_SOURCE_RESOLVED="ns"
        elif command -v perl >/dev/null 2>&1 && \
             [[ "$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)" =~ ^[0-9]+$ ]]; then
          STRIDE_TIME_SOURCE_RESOLVED="perl"
        else
          STRIDE_TIME_SOURCE_RESOLVED="seconds"
        fi ;;
    esac
  fi
  printf '%s' "$STRIDE_TIME_SOURCE_RESOLVED"
}

# Current wall-clock time in integer milliseconds via the resolved source.
# Callers invoke this through $(now_ms), a subshell — so the cache only
# helps when the PARENT shell warmed it first (run_stride_section does)
# and the subshell inherits the resolved value.
now_ms() {
  resolve_time_source > /dev/null
  case "$STRIDE_TIME_SOURCE_RESOLVED" in
    ns)
      local _ns
      _ns=$(date +%s%N)
      printf '%s' $(( _ns / 1000000 ))
      ;;
    perl)
      perl -MTime::HiRes=time -e 'printf "%d", time()*1000'
      ;;
    *)
      printf '%s' $(( $(date +%s) * 1000 ))
      ;;
  esac
}

# Probe for a usable timeout utility once and cache the answer.
# STRIDE_HOOK_TIMEOUT_TOOL forces the choice for tests: timeout|gtimeout|none
# ("none" selects the built-in watchdog). The probe is functional (-k needs
# GNU/FreeBSD semantics), so a BusyBox `timeout` lacking -k falls through.
STRIDE_TIMEOUT_TOOL_RESOLVED=""
resolve_timeout_tool() {
  if [ -z "$STRIDE_TIMEOUT_TOOL_RESOLVED" ]; then
    case "${STRIDE_HOOK_TIMEOUT_TOOL:-}" in
      none)             STRIDE_TIMEOUT_TOOL_RESOLVED="watchdog" ;;
      timeout|gtimeout) STRIDE_TIMEOUT_TOOL_RESOLVED="${STRIDE_HOOK_TIMEOUT_TOOL}" ;;
      *)
        if command -v timeout >/dev/null 2>&1 && timeout -k 1 1 true >/dev/null 2>&1; then
          STRIDE_TIMEOUT_TOOL_RESOLVED="timeout"
        elif command -v gtimeout >/dev/null 2>&1 && gtimeout -k 1 1 true >/dev/null 2>&1; then
          STRIDE_TIMEOUT_TOOL_RESOLVED="gtimeout"
        else
          STRIDE_TIMEOUT_TOOL_RESOLVED="watchdog"
        fi ;;
    esac
  fi
  printf '%s' "$STRIDE_TIMEOUT_TOOL_RESOLVED"
}

# Run one command as a fresh `bash -c` child under a seconds budget. Sets
# RWB_EXIT / RWB_TIMED_OUT for the caller. timeout's default (non
# --foreground) mode runs the child in its own process group and signals the
# whole group, so a hung command's children die with it — the security
# contract for killed hooks. The watchdog fallback (stock macOS: no GNU
# coreutils) gets the same via `set -m` (own pgid for the background job)
# plus kill -- -pgid, TERM then KILL after a 2s grace, synthesizing the
# conventional exit 124.
RWB_EXIT=0
RWB_TIMED_OUT=false
run_with_budget() {
  local _secs="$1" _out="$2" _err="$3" _cmd="$4" _tool _pid _deadline
  RWB_TIMED_OUT=false
  _tool=$(resolve_timeout_tool)
  if [ "$_tool" = "timeout" ] || [ "$_tool" = "gtimeout" ]; then
    "$_tool" -k 5 "$_secs" bash -c "$_cmd" > "$_out" 2> "$_err" < /dev/null
    RWB_EXIT=$?
    # Known GNU-timeout ambiguity: a command that genuinely exits 124 within
    # budget is indistinguishable from a timeout kill here (the watchdog
    # branch below only flags on actual deadline expiry). Accepted — 124 is
    # the documented timeout convention, so hook commands should not use it.
    [ "$RWB_EXIT" -eq 124 ] && RWB_TIMED_OUT=true
  else
    set -m
    bash -c "$_cmd" > "$_out" 2> "$_err" < /dev/null &
    _pid=$!
    set +m
    _deadline=$(( $(date +%s) + _secs ))
    while kill -0 "$_pid" 2>/dev/null && [ "$(date +%s)" -lt "$_deadline" ]; do
      sleep 0.2
    done
    if kill -0 "$_pid" 2>/dev/null; then
      RWB_TIMED_OUT=true
      kill -TERM -- "-$_pid" 2>/dev/null || kill -TERM "$_pid" 2>/dev/null || true
      sleep 2
      kill -KILL -- "-$_pid" 2>/dev/null || kill -KILL "$_pid" 2>/dev/null || true
    fi
    wait "$_pid" 2>/dev/null
    RWB_EXIT=$?
    [ "$RWB_TIMED_OUT" = "true" ] && RWB_EXIT=124
  fi
}

# --- Parse and execute one .stride.md hook section ---
# Takes a single section name (e.g. "before_doing", "after_goal") and:
#   1. Parses the first `## <section>` block from .stride.md (first-wins,
#      single ```bash fence, identical to the four-hook routes).
#   2. Returns 0 immediately when the section is missing OR the fenced body
#      is empty — back-compat no-op for older .stride.md files.
#   3. Otherwise executes each command sequentially; on the first non-zero
#      exit, emits the structured failed-JSON (or the plain-text fallback
#      when $HAS_JQ=false) and returns 2.
#   4. On all-success, emits the structured success-JSON (jq-only) and
#      returns 0.
# Reuses the global $HAS_JQ, $STRIDE_MD, $PROJECT_DIR, and the file-scope
# `finalize_after_doing` hook (which gates internally on the GLOBAL $HOOK_NAME,
# so calling this for "after_goal" does NOT re-trigger the after_doing snapshot).
# Placed alongside capture_changed_files / finalize_after_doing so tests can
# source the script and invoke the function in isolation.
run_stride_section() {
  local _section="$1"
  local _commands=""
  local _found=0
  local _capture=0
  local _line _heading

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _heading="${_line#\#\# }"
        _heading="${_heading%"${_heading##*[![:space:]]}"}"
        [ "$_heading" = "$_section" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && _commands="${_commands}${_line}
"
    fi
  done < "$STRIDE_MD"

  if [ -z "$_commands" ]; then
    finalize_after_doing
    return 0
  fi

  local _cmd _trimmed
  local _cmd_list _pending
  _cmd_list=()
  _pending=""
  # (W1456) Physical lines are joined into LOGICAL lines first: a line
  # ending in an unquoted, unescaped backslash continues onto the next
  # physical line (the backslash-newline pair is removed, per shell
  # semantics). Trimming and comment/blank skipping apply to logical
  # lines AFTER joining — a `#` on a continuation line is part of the
  # joined command (where the shell treats it as a trailing comment),
  # never a skip. One command per logical line remains the model.
  while IFS= read -r _cmd; do
    _cmd="${_cmd%$'\r'}"
    if [ -n "$_pending" ]; then
      _cmd="${_pending}${_cmd}"
      _pending=""
    else
      # Comments never continue: `#` lexes to end-of-line in shell, so a
      # trailing backslash on a standalone comment line is inert — skip the
      # line here so it cannot swallow the next command. (A `#` on a
      # continuation body line still joins, handled above.)
      case "${_cmd#"${_cmd%%[![:space:]]*}"}" in
        \#*) continue ;;
      esac
    fi
    if line_continues "$_cmd"; then
      _pending="${_cmd%\\}"
      continue
    fi
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    [ -z "$_trimmed" ] && continue
    case "$_trimmed" in \#*) continue ;; esac
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"
  # A trailing backslash on the section's last line: emit the accumulated
  # command with the continuation marker already stripped — never hang or
  # drop it.
  if [ -n "$_pending" ]; then
    _trimmed="${_pending#"${_pending%%[![:space:]]*}"}"
    if [ -n "$_trimmed" ]; then
      case "$_trimmed" in \#*) : ;; *) _cmd_list+=("$_trimmed") ;; esac
    fi
  fi

  if [ ${#_cmd_list[@]} -eq 0 ]; then
    finalize_after_doing
    return 0
  fi

  cd "$PROJECT_DIR"

  # (D255) Anchor the owned-commit delta: HEAD before the first section command
  # runs. after_doing only — after_goal reuses this function and must stay inert.
  if [ "${HOOK_NAME:-}" = "after_doing" ]; then
    SNAP_OWNED_H0=$(git rev-parse HEAD 2>/dev/null || printf '')
  fi

  # Early per-file diff snapshot (W1093) — the after_doing section runs the
  # full quality gate, and the 600s hook timeout can kill this process
  # mid-loop, silently losing the diff upload (how W1092 lost its diffs).
  # Capture and PUT the snapshot BEFORE the first command executes; the
  # post-loop call below is KEPT as a refresh once the gate succeeds. A bare
  # call is safe: finalize_after_doing is idempotent, gates internally on the
  # GLOBAL $HOOK_NAME (so the after_goal reuse of this function stays inert),
  # emits nothing on stdout, and never returns non-zero — a degraded capture
  # still writes a best-effort [] snapshot. Placed after the cd so
  # capture_changed_files diffs $PROJECT_DIR's repo.
  finalize_after_doing

  local _completed_file _output_file
  _completed_file=$(mktemp)
  # Parallel to _completed_file: one JSON object per successful command holding
  # its tail-truncated stdout/stderr, slurped into the success JSON's
  # commands_output array (D65). Keeps passing-gate output off fd 2 so Claude
  # Code does not render it under a false "PreToolUse:Bash hook error" label.
  _output_file=$(mktemp)
  local _start_secs _start_ms
  _start_secs=$(date +%s)
  # (W1455) Millisecond wall clock for duration_ms reporting; the seconds
  # clock above stays the budget-bookkeeping source (whole-second math).
  # Warm the time-source cache in THIS shell first — $(now_ms) runs in a
  # subshell, so without this the probe would repeat on every call.
  resolve_time_source > /dev/null
  _start_ms=$(now_ms)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _output_json _end_secs _duration _i
  local _section_budget _remaining _elapsed _timed_out
  local _duration_ms _hook_result
  _section_budget=$(resolve_section_budget "$_section")

  for _trimmed in "${_cmd_list[@]}"; do
    _cmd_stdout_file=$(mktemp)
    _cmd_stderr_file=$(mktemp)

    _elapsed=$(( $(date +%s) - _start_secs ))
    _remaining=$(( _section_budget - _elapsed ))
    _timed_out=false
    if [ "$_remaining" -le 0 ]; then
      # Earlier commands consumed the whole section budget — do not start.
      _cmd_exit=124
      _timed_out=true
      : > "$_cmd_stdout_file"
      printf '%ss section budget exhausted before this command started\n' \
        "$_section_budget" > "$_cmd_stderr_file"
    else
      # (W1454) Each command runs as a fresh `bash -c` child so it can be
      # killed when the section budget expires. Same-shell eval persistence
      # (cd/vars carrying across .stride.md lines) is intentionally gone —
      # the PowerShell executor never had it, so no cross-platform hook could
      # rely on it — and all documented env (TASK_*, GOAL_*, HOOK_NAME,
      # server hook env) is exported and survives into the child. The old
      # `set +uo pipefail` relaxation is unneeded: the child is a fresh bash
      # with default options.
      run_with_budget "$_remaining" "$_cmd_stdout_file" "$_cmd_stderr_file" "$_trimmed"
      _cmd_exit=$RWB_EXIT
      _timed_out=$RWB_TIMED_OUT
    fi

    if [ "$_cmd_exit" -eq 0 ]; then
      echo "$_trimmed" >> "$_completed_file"
      # Do NOT cat the passing command's output to fd 2: Claude Code renders any
      # hook stderr under a red "PreToolUse:Bash hook error" label even on exit
      # 0 (D65). Instead capture a tail-truncated copy — same -50 cap as the
      # failure path — into _output_file as a JSON object, folded into the
      # success JSON's commands_output array below so agents keep visibility.
      if [ "$HAS_JQ" = "true" ]; then
        _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
        _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
        jq -n \
          --arg command "$_trimmed" \
          --arg stdout "$_cmd_stdout" \
          --arg stderr "$_cmd_stderr" \
          '{command: $command, stdout: $stdout, stderr: $stderr}' >> "$_output_file"
      fi
    else
      _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
      _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
      rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"

      _remaining_file=$(mktemp)
      if [ $((_cmd_index + 1)) -lt $_cmd_total ]; then
        for ((_i = _cmd_index + 1; _i < _cmd_total; _i++)); do
          echo "${_cmd_list[$_i]}" >> "$_remaining_file"
        done
      fi

      # (D234) The duration is computed HERE, before the failure branch emits.
      # Previously it was only computed further down, on the success path — so
      # the one path that emitted a duration was the one whose output the agent
      # cannot read, and the readable path carried none at all.
      _duration_ms=$(( $(now_ms) - _start_ms ))
      [ "$_duration_ms" -lt 0 ] && _duration_ms=0

      if [ "$HAS_JQ" = "true" ]; then
        _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")
        _remaining_json=$(jq -R . < "$_remaining_file" | jq -s . 2>/dev/null || echo "[]")

        _hook_result=$(jq -n \
          --arg hook "$_section" \
          --argjson duration_ms "$_duration_ms" \
          --arg failed "$_trimmed" \
          --argjson index "$_cmd_index" \
          --argjson exit_code "$_cmd_exit" \
          --argjson timed_out "$_timed_out" \
          --argjson budget "$_section_budget" \
          --arg stdout "$_cmd_stdout" \
          --arg stderr "$_cmd_stderr" \
          --argjson completed "$_completed_json" \
          --argjson remaining "$_remaining_json" \
          '{
            hook: $hook,
            status: "failed",
            failed_command: $failed,
            command_index: $index,
            exit_code: $exit_code,
            timed_out: $timed_out,
            budget_seconds: $budget,
            stdout: $stdout,
            stderr: $stderr,
            commands_completed: $completed,
            commands_remaining: $remaining,
            duration_ms: $duration_ms
          }')
        write_hook_result "$_section" "$_hook_result"
        printf '%s\n' "$_hook_result"
      else
        echo "HOOK=$_section STATUS=failed COMMAND=$_trimmed EXIT=$_cmd_exit TIMED_OUT=$_timed_out BUDGET=$_section_budget DURATION_MS=$_duration_ms"
      fi

      if [ "$_timed_out" = "true" ]; then
        echo "Stride $_section hook command $((_cmd_index + 1))/$_cmd_total timed out after ${_section_budget}s budget: $_trimmed" >&2
      else
        echo "Stride $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed" >&2
      fi
      [ -n "$_cmd_stderr" ] && echo "$_cmd_stderr" >&2
      rm -f "$_completed_file" "$_remaining_file" "$_output_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  # (D255) The loop ran to completion: close the delta. The failure path above
  # returns 2 before reaching here, so a vetoed completion records nothing and
  # the retry starts a fresh window (its pre-retry commits then fall back to
  # the window model — over-report, never loss). An unresolvable HEAD (no
  # commits yet) also records nothing.
  if [ "${HOOK_NAME:-}" = "after_doing" ] && [ -n "${SNAP_OWNED_H0:-}" ]; then
    SNAP_OWNED_H1=$(git rev-parse HEAD 2>/dev/null || printf '')
    [ -n "${SNAP_OWNED_H1:-}" ] && SNAP_OWNED_LOOP_RAN=true
  fi

  # Per-file diff snapshot (G148/W719) — no-op outside after_doing (gates on
  # the GLOBAL $HOOK_NAME). Calling run_stride_section for "after_goal" does
  # NOT re-trigger this: $HOOK_NAME is "after_goal" during that call (W1453),
  # which never equals "after_doing".
  # (W1093) This is the REFRESH of the early pre-loop snapshot — keep it: the
  # gate's commands may modify files, and this re-captures the final tree.
  finalize_after_doing

  _end_secs=$(date +%s)
  _duration=$((_end_secs - _start_secs))
  # (W1455) duration_ms is the hook-execution.md contract field. Guard against
  # clock weirdness — never emit a negative duration.
  _duration_ms=$(( $(now_ms) - _start_ms ))
  [ "$_duration_ms" -lt 0 ] && _duration_ms=0

  if [ "$HAS_JQ" = "true" ]; then
    _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")
    _output_json=$(jq -s . < "$_output_file" 2>/dev/null || echo "[]")

    # duration_seconds is DEPRECATED in favor of duration_ms (the
    # hook-execution.md field name) — kept for one release for any
    # consumer still parsing it.
    _hook_result=$(jq -n \
      --arg hook "$_section" \
      --argjson duration "$_duration" \
      --argjson duration_ms "$_duration_ms" \
      --argjson completed "$_completed_json" \
      --argjson outputs "$_output_json" \
      '{
        hook: $hook,
        status: "success",
        commands_completed: $completed,
        commands_output: $outputs,
        duration_ms: $duration_ms,
        duration_seconds: $duration
      }')
    # (D234) Persist BEFORE printing: stdout on the exit-0 path reaches the
    # transcript, not the model, so the file is the only channel the agent can
    # actually read this figure back from.
    write_hook_result "$_section" "$_hook_result"
    printf '%s\n' "$_hook_result"
  fi

  rm -f "$_completed_file" "$_output_file"
  return 0
}

# --- Canonical response-file fast path (D118) ---
# The harness can truncate a large /complete tool_response.stdout mid-JSON,
# which silently breaks after_goal detection and env extraction. When the agent
# (or a PreToolUse capture) has written the full API response to the canonical
# file ($RESPONSE_FILE), prefer it over the truncatable stdout. Prints the
# file's JSON when it is present AND parses as valid JSON; prints nothing
# otherwise so the caller falls back to the tool_response.stdout parse. Gated on
# $HAS_JQ — the validity check needs jq, and a garbage/truncated file must never
# shadow the stdout fallback. Best-effort only: a stale-but-valid file is used
# as-is (D119's fresh call is the reliability guarantee, not this fast path).
read_canonical_response() {
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "${RESPONSE_FILE:-}" ] || return 0
  [ -f "$RESPONSE_FILE" ] || return 0

  local _content
  _content=$(cat "$RESPONSE_FILE" 2>/dev/null) || return 0
  [ -n "$_content" ] || return 0

  # Validate before trusting it — a truncated/garbage file must fall through.
  echo "$_content" | jq -e . > /dev/null 2>&1 || return 0

  printf '%s' "$_content"
}

# (W1609) Capture the current API response to the canonical file. The hook is a
# PostToolUse observer, so the freshest untruncated data it can persist is THIS
# call's tool_response.stdout when it parses as complete JSON. Writing it keeps
# $RESPONSE_FILE current for the file-first resolver below: the claim env-cache
# refresh and after_goal detection then read the CURRENT call's data instead of
# a stale prior-call file. When the current stdout is itself truncated the file
# is left untouched, so a value written out-of-band (a `curl ... | tee
# "$RESPONSE_FILE"` / `--output` passthrough on the completion/claim/
# mark_reviewed curls, or a future PreToolUse capture) survives as the
# best-effort source. Only complete, valid JSON is ever written — a truncated
# blob must never overwrite a good file. Gated on $HAS_JQ.
# (W1609) Unwrap the API payload string from a hook input's .tool_response: the
# Claude Code Bash tool wraps it as {"stdout":"<json>"}, other harnesses carry
# the API JSON directly. Prints the unwrapped payload (possibly truncated), or
# nothing. Single-sourced so the read side (extract_response_payload) and the
# write side (capture_canonical_response) share one unwrap and cannot diverge.
unwrap_tool_response() {
  local _hook_input="$1"
  local _response _payload

  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "$_hook_input" ] || return 0

  _response=$(echo "$_hook_input" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
  [ -n "$_response" ] || return 0

  if echo "$_response" | jq -e 'type == "object" and has("stdout")' > /dev/null 2>&1; then
    _payload=$(echo "$_response" | jq -r '.stdout // ""' 2>/dev/null)
  else
    _payload="$_response"
  fi

  printf '%s' "$_payload"
}

capture_canonical_response() {
  local _hook_input="$1"
  local _payload

  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "${RESPONSE_FILE:-}" ] || return 0

  _payload=$(unwrap_tool_response "$_hook_input")
  [ -n "$_payload" ] || return 0
  # Only persist a COMPLETE, valid API JSON — a truncated blob must never
  # overwrite a good (e.g. curl-tee'd) canonical file.
  echo "$_payload" | jq -e . > /dev/null 2>&1 || return 0

  mkdir -p "$(dirname "$RESPONSE_FILE")" 2>/dev/null || return 0
  printf '%s' "$_payload" > "$RESPONSE_FILE" 2>/dev/null || true
}

# --- After-goal detection (W504) ---
# Inspects the response payload for an `after_goal` entry in the response's
# `hooks` array. The server bundles after_goal alongside before_review (post +
# /complete) or after_review (post + /mark_reviewed) when the completing task is
# the last child of a parent goal. Returns 0 when after_goal is present in the
# payload, 1 otherwise. Gated on $HAS_JQ — environments without jq cannot parse
# the response and degrade cleanly to "no after_goal detected".
#
# (D118/W1609) Payload source order is owned by the single shared resolver
# extract_response_payload: canonical response file first (survives harness
# truncation), then the tool_response.stdout unwrap, then the W1086 persisted-
# output file. Delegating here keeps after_goal detection, env forwarding, and
# the claim env-cache refresh on ONE resolver so they can never diverge.
# Pure jq predicate on an ALREADY-resolved payload string (no $INPUT unwrap):
# does it carry an after_goal hook entry? Single-sourced so response_has_after_goal
# and route_after_goal share one after_goal detection expression (D119).
payload_has_after_goal() {
  local _payload="$1"
  [ "${HAS_JQ:-false}" = "true" ] || return 1
  [ -n "$_payload" ] || return 1
  echo "$_payload" \
    | jq -e '(.hooks // []) | map(select(.name == "after_goal")) | length > 0' \
        > /dev/null 2>&1
}

response_has_after_goal() {
  local _hook_input="$1"

  [ "$HAS_JQ" = "true" ] || return 1

  payload_has_after_goal "$(extract_response_payload "$_hook_input")"
}

# --- Server-supplied hook env forwarding (W1453) ---
# hook-execution.md declares the server's hook env block the single source of
# truth for the variables the executor exports. The helpers below extract the
# `env` object from the hook entry of an intercepted response (singular
# `.hook` on claim responses, `.hooks[]` on /complete and /mark_reviewed),
# escape each value, export it into the running shell (set -a), and write it
# to the env cache (D260: replacing any prior record for the keys this call
# writes, not appending) so follow-up agent commands (e.g. the after_goal
# PATCH) can still read the values. Keys the server omits export as empty strings.

# Single-quote a value for a file sourced by the shell. Embedded single
# quotes become '\'' — nothing inside single quotes is ever interpreted, so
# a crafted task title cannot inject commands into the executor.
sq_escape() {
  # _q is the 4-char sequence '\'' (close quote, escaped quote, reopen quote).
  local _q="'\\''"
  local _v="${1//\'/$_q}"
  printf "'%s'" "$_v"
}

# Peel the API payload out of Claude Code hook input: .tool_response may wrap
# the API JSON as {"stdout":"<json>"} (Bash tool) or carry it directly (other
# harnesses). Prints the payload JSON, or nothing when unparseable/no jq.
#
# (D118/W1609) The single shared response resolver. Source order:
#   1. the canonical response file (survives harness truncation) — D118
#   2. tool_response.stdout, unwrapped from the Claude Code {"stdout":...} shape
#      or taken raw (other harnesses), when it is complete valid JSON
#   3. the W1086 persisted-output file named by a "Full output saved to: <path>"
#      stdout notice, when stdout was too large to inline
# Falls back to the best-effort (possibly truncated) stdout blob as a last
# resort; callers jq-guard their own use, so a truncated blob degrades cleanly.
# Reused by response_has_after_goal, the env-forwarding path, AND the claim
# env-cache/TASK_BASE_REF refresh so none of them can diverge (W1609 pitfall).
extract_response_payload() {
  local _hook_input="$1"
  local _payload _notice _persist_line _persist_path _persist_json

  [ "$HAS_JQ" = "true" ] || return 0

  # (D118) Fast path — prefer the untruncated canonical response file.
  _payload=$(read_canonical_response)
  if [ -n "$_payload" ]; then
    printf '%s' "$_payload"
    return 0
  fi

  # Unwrap the current call's stdout payload (shared with capture_canonical_response).
  _payload=$(unwrap_tool_response "$_hook_input")
  [ -n "$_payload" ] || return 0

  # Use the stdout payload when it is complete, valid JSON.
  if echo "$_payload" | jq -e . > /dev/null 2>&1; then
    printf '%s' "$_payload"
    return 0
  fi

  # (W1086) Shape 3: persisted-output file fallback. When the response is large,
  # Claude Code writes the tool output to a file and leaves only a notice —
  # "Full output saved to: <absolute path>" — in stdout. Recover the API JSON by
  # reading that file. The path is harness-controlled, so require an existing
  # regular file and parse it with jq only — never source, eval, or write to it.
  # _payload is guaranteed non-empty here (the early return above), and for the
  # non-wrapped harness shape it already holds the raw stdout notice.
  _notice="$_payload"
  if printf '%s' "$_notice" | grep -qi 'saved to'; then
    # Keep the path from its first "/" to end of the notice line so a path
    # containing spaces survives; tolerate the notice wrapping it in quotes.
    _persist_line=$(printf '%s\n' "$_notice" | grep -i 'saved to' | head -1)
    _persist_path="/${_persist_line#*/}"
    _persist_path="${_persist_path%\"}"
    if [ -n "$_persist_line" ] && [ -f "$_persist_path" ]; then
      _persist_json=$(cat "$_persist_path" 2>/dev/null || echo "")
      if [ -n "$_persist_json" ] && echo "$_persist_json" | jq -e . > /dev/null 2>&1; then
        printf '%s' "$_persist_json"
        return 0
      fi
    fi
  fi

  # Best-effort last resort: whatever we unwrapped (possibly truncated).
  printf '%s' "$_payload"
}

# Print escaped KEY='value' assignment lines for the env object of the named
# hook entry in the payload. Keys must be valid shell identifiers — anything
# else is dropped, because an unquoted key left of `=` in a sourced file is
# the real injection vector. HOOK_NAME is excluded: the executor routes on
# its own script-global and a cached HOOK_NAME line would misroute every
# later invocation. TASK_BASE_REF is excluded: it is a client-only diff
# anchor owned by the claim branch (W1086). Values go through jq's @sh so
# embedded quotes and newlines cannot escape the single-quoting.
# (D226) The jq filter below fences the TASK_BASE_REF namespace by PREFIX
# rather than by equality. D142 excluded TASK_BASE_REF as a client-only diff
# anchor; D226 added TASK_BASE_REF_OWNER, _UNPROVEN, _TRUSTED and the per-task
# TASK_BASE_REF_<id> records to the same family, and each one defeats a
# different rule in the base selection. Fencing the namespace declares that the
# client owns it, and covers the next key added without anyone remembering to
# update the filter.
#
# (D273) That protection is per-FAMILY, not automatic — a new family needs its
# own prefix here, and TASK_NARROWED was added without one. The consequence was
# concrete rather than theoretical: apply_env_lines wrote these lines to the
# cache in the same before_review invocation that then runs the self-heal, and
# task_narrowed_for reads the file with `tail -n 1`, so a server-supplied
# TASK_NARROWED_<id> outranked the record the capture wrote and steered the
# retry into narrowing — an outside party forcing the UNDER-report direction
# this whole subsystem exists to prevent. (D260) It APPENDED when this was
# found; it now replaces in place for the keys each call writes, so a future
# unfenced family would fare WORSE than described here — the forwarded line
# would DELETE the capture's record rather than outrank it. Same escalation
# the D258 paragraph below records, for the same reason. TASK_BASE_AT is fenced on the same
# terms: a supplied stamp would let an outside party keep a dead window alive
# (or retire a live one) and reach the same narrowing decision one step
# earlier. Every client-owned family belongs in this list.
#
# (D258) TASK_HEAD_REF was the last family still outside this list, and it was
# the one with the sharpest consequence. D226's reasoning — that server data
# must not set record-namespace keys — applies to head refs at least as hard:
# they define where a task's window CLOSES, so they drive the D236/D244
# commit-attribution walk directly. And an injected one is durable in a way an
# injected base ref is not: record_task_head_ref only ever repairs the
# COMPLETING task's own id, so a record forged for any OTHER id is never
# repaired, and select_kept_window_records emits every surviving head line
# without per-key dedup. When this was found, apply_env_lines appended, so the
# forged line sat BESIDE the genuine one and won on a last-match read.
# (D260) It now replaces in place for the keys each call writes, which makes
# the consequence WORSE rather than better for any family that ever escapes
# this filter: a forged key would DELETE the genuine record instead of merely
# outranking it. Not reachable today — all five families plus STRIDE_ are
# fenced below — but whoever adds the sixth family should know the blast
# radius grew.
#
# Not theoretical — demonstrated end to end. A synthetic complete response for
# an OUTER task whose hooks[].env carried TASK_HEAD_REF_<nested_id> pointing at
# the root commit planted a forged window head, and the outer's uploaded
# snapshot then gained the nested task's file relative to an uninjected
# control. TASK_OWNED_* and TASK_BASE_REF_* controls in the same env were
# correctly dropped, which is exactly what made the asymmetry visible.
#
# With this clause every client-owned record family is fenced: the five
# task_*_key families plus STRIDE_. What remains is the structural gap the
# note above describes — a deny-list cannot cover a key nobody has thought of,
# and PATH/BASH_ENV/IFS/GIT_SSH_COMMAND still pass — which is filed as D275
# and deliberately out of scope here.
#
# (D273) STRIDE_ is fenced for the same reason one level up. The executor's own
# tuning knobs are client-owned by definition — none is meant to arrive from the
# server — and STRIDE_OPEN_WINDOW_MAX_AGE_SECS in particular decides the age
# horizon, so a supplied value of 9999999999 would make every abandoned window
# read live again and restore the exact D271 under-report this task retires.
# Fencing the prefix rather than the one name covers the next knob added.
#
# NOTE (out of scope here, filed separately): this filter is a DENY-list, so
# every key it does not name still reaches apply_env_lines' eval and the env
# cache — including PATH, BASH_ENV, IFS and GIT_SSH_COMMAND. That is a
# pre-existing hole, not one this task opened, and closing it properly means
# turning this into an ALLOW-list of the documented hook-env keys.
#
# The match is case-SENSITIVE here and case-INsensitive in the ps1 twin, and
# that difference is deliberate: each matches the variable semantics of its own
# platform. Bash variables are case-sensitive, so Task_Base_Ref_100 lands in a
# different variable and cannot collide with the names the guard reads; Windows
# environment variables are case-insensitive, so that same key WOULD be found
# there. Do not harmonize the two — making the ps1 side case-sensitive re-opens
# the hole it closes.
#
# NOTE for editors: the filter is a single-quoted shell string, so it cannot
# contain an apostrophe. Comments belong here, not inside it.
# (D275) The key filter is an ALLOW-list of the exact names the executor
# documents, and it has to be: everything that gets past here is eval'd under
# `set -a` by apply_env_lines AND appended to .stride-env-cache, which is
# `.`-sourced under `set -a` on every later invocation. So a key that slips
# through is not a one-off — it is durable until the next claim truncates the
# cache, and it arrives from an API response body.
#
# The previous filter was a DENY-list naming HOOK_NAME and five client-owned
# families, which is wrong by construction here because the dangerous set is
# open-ended: PATH, BASH_ENV, IFS, ENV, SHELLOPTS, LD_PRELOAD, DYLD_*,
# GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF, GIT_CONFIG* and PS4 all passed it. A
# server-supplied PATH re-points every later git, curl, date, jq and grep the
# hook runs, in the SAME process, which is code execution on the developer
# machine sourced from a response body.
#
# EXACT names, not prefixes. The server is the untrusted party, so `TASK_*`
# would readmit exactly the client-owned families the old filter had to name
# one by one; enumerating instead means those are excluded because they are
# not on the list, rather than because someone remembered to exclude them.
# HOOK_NAME is documented but deliberately absent: the executor routes on its
# own value and sets it around the section run, and hook-execution.md records
# that it is never taken from the server or written to the cache.
#
# The list is the Variable Inventory in skills/stride-workflow/hook-execution.md.
# Adding a documented variable there means adding it here, and the suite has a
# case that fails if the two drift.
STRIDE_HOOK_ENV_ALLOW='["TASK_ID","TASK_IDENTIFIER","TASK_TITLE","TASK_DESCRIPTION","TASK_STATUS","TASK_COMPLEXITY","TASK_PRIORITY","TASK_NEEDS_REVIEW","BOARD_ID","BOARD_NAME","COLUMN_ID","COLUMN_NAME","AGENT_NAME","GOAL_ID","GOAL_IDENTIFIER","GOAL_TITLE","GOAL_DESCRIPTION"]'

extract_hook_env() {
  local _payload="$1" _name="$2"
  [ "$HAS_JQ" = "true" ] || return 0
  [ -n "$_payload" ] || return 0
  printf '%s' "$_payload" | jq -r --arg name "$_name" --argjson allow "$STRIDE_HOOK_ENV_ALLOW" '
    (
      (.hooks // []) + (if (has("hook") and (.hook | type == "object")) then [.hook] else [] end)
      | map(select(type == "object" and .name == $name))
      | (first // {})
      | (.env // {})
    )
    | if type == "object" then . else {} end
    | to_entries[]
    | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    | select(.key | IN($allow[]))
    | .key + "=" + (.value | tostring | @sh)
  ' 2>/dev/null || true
}

# Export assignment lines into the running shell and write them to the env
# cache (best-effort) so the values survive for follow-up agent commands.
# Every line is KEY='escaped-value' (see extract_hook_env / sq_escape), so
# the eval is confined to plain assignments. Never echoes values to
# stdout/stderr (they may contain task descriptions or other sensitive
# content).
#
# (D260) This used to APPEND unconditionally, and the comment defending that
# gave two reasons which no longer hold:
#
#   "a line-based rewrite would corrupt values with embedded newlines" — true
#   of a LINE-based rewrite, which is why the collapse below is quote-aware
#   instead (the same scanner D257 and D259 use). That objection was correct
#   and is now answered rather than ignored.
#
#   "the next claim truncates the cache anyway, bounding growth" — too coarse.
#   The claim truncates, then this function appends in the SAME invocation, so
#   a single parseable claim ends with two lines per identity key: the rewrite
#   wrote the data block's values, this wrote the env block's. Measured: with
#   data status=doing/title="Task title in data" and hook.env
#   TASK_STATUS=ready/TASK_TITLE="…(stale)", grep -m1 returns the data values
#   and sourcing returns the env values, in ONE run. And within a claim window
#   nothing truncates at all, so every later post hook appends another copy —
#   measured going 2 → 3 → 4 lines for TASK_TITLE across two before_review
#   invocations. Growth is bounded only across claims, not within a window.
#
# WHICH WRITER WINS: the forwarded env block, and that is a deliberate choice
# rather than a consequence. The eval above runs after the cache load, so the
# env value is already what the ## before_doing section receives in its
# process env — verified by running a skewed claim and reading the section's
# own stdout. Making the cache agree therefore changes no behaviour any
# section can observe; the alternative the defect proposed, skipping the
# forward for keys the rewrite already wrote, would have flipped the value the
# section sees, which its own pitfall forbids. So: last write wins, exactly as
# sourcing already resolved it, now with one line to read instead of two that
# disagree.
#
# Scope is the keys THIS call writes. Every other line in the cache is passed
# through untouched, including all five per-task record families — collapsing
# those would reopen D226/D268/D273.
apply_env_lines() {
  local _lines="$1" _keys _rewritten
  [ -n "$_lines" ] || return 0
  set -a
  eval "$_lines" 2>/dev/null || true
  set +a

  # The keys this call is writing — read only from record-START lines, so a
  # continuation line inside a multi-line value can never be mistaken for a key.
  # Emitted SPACE-separated, not newline-separated, because awk's -v cannot
  # carry an embedded newline: with one key a newline-joined list happens to
  # work and with two it silently breaks, so the collapse would have been a
  # no-op on exactly the multi-key case it exists for. Key names are
  # [A-Za-z0-9_] (extract_hook_env's own test enforces it), so a space is an
  # unambiguous delimiter.
  _keys=$(printf '%s\n' "$_lines" | awk -v q="'" '
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0 }
    { if (!inq && index($0, "=") > 1) printf "%s ", substr($0, 1, index($0, "=") - 1); scan($0) }
  ' 2>/dev/null || true)

  # Drop this call's keys from the cache, then re-append — one record per key,
  # carrying the value just exported. Fails closed: if the scan cannot parse
  # the cache (unbalanced quoting, or no awk) it falls back to the historical
  # append, which duplicates rather than risking a dropped record.
  if [ -n "$_keys" ] && [ -f "$ENV_CACHE" ] && _rewritten=$(awk -v q="'" -v keys="$_keys" '
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; drop = 0; n = split(keys, k, " "); for (i = 1; i <= n; i++) if (k[i] != "") kill[k[i]] = 1 }
    {
      if (!inq) { drop = (index($0, "=") > 1 && (substr($0, 1, index($0, "=") - 1) in kill)) }
      scan($0)
      if (!drop) print
    }
    END { if (inq) exit 1 }
  ' "$ENV_CACHE" 2>/dev/null); then
    {
      [ -n "$_rewritten" ] && printf '%s\n' "$_rewritten"
      printf '%s\n' "$_lines"
    } | write_env_cache || true
  else
    printf '%s\n' "$_lines" >> "$ENV_CACHE" 2>/dev/null || true
  fi
}

# after_goal env: export what the server supplied, default every documented
# GOAL_* key it omitted to an empty string (defined-but-empty, never an
# error), and fall back to the completed task's parent_id from the same
# response payload when GOAL_ID itself is missing or empty. The fallback is
# response-local — the executor still never queries the API for goal state.
export_after_goal_env() {
  local _payload="$1"
  local _lines _supplied _key _parent _collapsed
  _lines=$(extract_hook_env "$_payload" "after_goal")

  # Which keys did the server actually supply? Asked of jq directly (one key
  # name per line) rather than grepped out of the assignment text — a value
  # with an embedded newline could otherwise masquerade as a KEY= line and
  # suppress an omitted key's empty-string default.
  _supplied=""
  if [ "$HAS_JQ" = "true" ] && [ -n "$_payload" ]; then
    _supplied=$(printf '%s' "$_payload" | jq -r '
      (
        (.hooks // []) + (if (has("hook") and (.hook | type == "object")) then [.hook] else [] end)
        | map(select(type == "object" and .name == "after_goal"))
        | (first // {})
        | (.env // {})
      )
      | if type == "object" then . else {} end
      | keys[]
    ' 2>/dev/null || true)
  fi

  for _key in GOAL_ID GOAL_IDENTIFIER GOAL_TITLE GOAL_DESCRIPTION; do
    if ! printf '%s\n' "$_supplied" | grep -qx "$_key"; then
      _lines="${_lines}
${_key}=''"
    fi
  done

  apply_env_lines "$_lines"

  # Parent-id fallback: the server built the after_goal env from the completed
  # child task and omitted GOAL_ID (or sent it empty). The parent id in the
  # same response's data object IS the goal id.
  if [ -z "${GOAL_ID:-}" ] && [ "$HAS_JQ" = "true" ] && [ -n "$_payload" ]; then
    _parent=$(printf '%s' "$_payload" | jq -r '.data.parent_id // .parent_id // empty' 2>/dev/null || true)
    if [ -n "$_parent" ] && [ "$_parent" != "null" ]; then
      GOAL_ID="$_parent"
      export GOAL_ID
    fi
  fi

  # (D245/D257) Collapse the four GOAL_* keys to exactly one cache line each.
  #
  # (D245) established the invariant: a first-match reader (grep -m1) and a
  # sourcing reader of this file must agree. It fixed the one geometry it had
  # in hand by replacing GOAL_ID in place -- but only inside the parent-id
  # fallback above, so the guard ran only when that fallback fired.
  #
  # (D257) Two geometries stayed one response-shape away from that fix, and
  # apply_env_lines was why: it APPENDED every line, supplied or defaulted, on
  # every call. (D260 has since made it replace-in-place for the keys each call
  # writes, so that append no longer happens — the history is kept because it
  # is what these two geometries were.) So within a single claim window, where
  # no claim intervenes to truncate the cache:
  #   1. Run 1 establishes GOAL_ID='7'. Run 2 omits both the GOAL_ID env key
  #      and data.parent_id, so the defaults loop above appended GOAL_ID=''
  #      AFTER the real value and the fallback never ran to clean it up.
  #      grep -m1 then reads the PREVIOUS goal's id while sourcing reads ''.
  #   2. GOAL_IDENTIFIER, GOAL_TITLE and GOAL_DESCRIPTION never had a
  #      replace-in-place at all, so two runs accumulate contradictory pairs
  #      and a first-match reader reconstructs GOAL_ID='7' beside
  #      GOAL_IDENTIFIER='G6' -- two different goals stitched into one
  #      identity. A commit message, PR body or notification built from those
  #      fields then names the wrong goal, which is the harm that matters.
  #
  # Doing it here, unconditionally and for all four keys, is what makes the
  # invariant hold by construction rather than per-geometry: this runs on
  # EVERY after_goal export, whether or not the fallback fired, and it is
  # placed after the fallback so it captures GOAL_ID's final value.
  #
  # The values come from the exported environment, which apply_env_lines has
  # already eval'd -- so the line written is exactly what a sourcing reader
  # would have resolved to, and LAST-WINS SOURCING SEMANTICS ARE PRESERVED
  # rather than changed. An omitted key resolves to the defaults loop's empty
  # string, which is deliberate and contract-mandated (hook-execution.md: a
  # key the server omits is exported defined-but-empty, never absent, so a
  # `set -u` section can reference it) -- and it is also what stops a previous
  # run's value from surviving into a run for a different goal.
  #
  # Scope is exactly these four keys: BOARD_*, COLUMN_* and AGENT_NAME ride the
  # same after_goal env and are deliberately untouched HERE.
  #
  # (D260) This block is NOT redundant with apply_env_lines' own collapse, and
  # the reason is the parent-id fallback above — but state the mechanism
  # exactly, because the obvious one is wrong. apply_env_lines has ALREADY
  # written all four keys by this point (the defaults loop hands it every
  # omitted one as ''), and the fallback then assigns only the SHELL variable.
  # So nothing appends a second GOAL_ID; what would happen without this block
  # is quieter and worse to debug: the cache would keep the empty default while
  # the process env holds the parent id, so the section and the cache would
  # disagree about the goal. Re-emitting all four from the exported values is
  # what closes that gap.
  #
  # The ps1 twin's equivalent block IS fully redundant, because there the
  # fallback writes into the env map BEFORE that port's collapse runs. Two
  # structurally similar blocks, two different answers — check each against its
  # own call order rather than against the other.
  #
  # THE FILTER IS QUOTE-AWARE, AND IT HAS TO BE. A plain `grep -v '^KEY='` is
  # what D245 used, and it was safe there only because GOAL_ID is always a
  # numeric id. GOAL_TITLE and GOAL_DESCRIPTION are free-form and routinely
  # span lines, so a line-based filter deletes the middle of a value instead of
  # a record — the corruption apply_env_lines' comment used to cite as its
  # reason for appending rather than rewriting (D260 answered that objection by
  # making its own collapse quote-aware rather than by ignoring it). Test 10l
  # pins the adversarial shape deliberately: a GOAL_TITLE whose value
  # contains a line reading
  # `GOAL_IDENTIFIER=sneaky`. Extending D245's idiom to all four keys as
  # literally specified would have silently truncated that value.
  #
  # So records are found by shell-quoting state, not by line shape. Every value
  # is sq_escape output — wrapped in single quotes, with embedded quotes as the
  # 4-char sequence '\'' — so scanning for quote state identifies where a
  # record really ends. A line is the START of a record only when the scanner
  # is outside quotes; a continuation line inherits its record's keep/drop
  # decision, whatever it happens to look like. That protects non-GOAL
  # multi-line records (TASK_DESCRIPTION) from a continuation that looks like a
  # GOAL_ key, in the same motion.
  #
  # The scanner's correctness rests on an invariant that is now LOAD-BEARING:
  # every line in the cache is sq_escape (or jq @sh) output, so quoting is
  # balanced. That holds across every current writer, but a future writer
  # emitting an unbalanced line would desynchronise the scanner — and the
  # consequence is not merely a bad diff, because this cache is later sourced
  # with `set -a`, so an orphaned fragment left as a standalone line becomes
  # executable text. So the scanner FAILS CLOSED: if it reaches EOF still
  # inside a quoted value, the input was not what this function is allowed to
  # assume, and it exits non-zero rather than emitting a partially-parsed
  # cache. The `if` below then skips the collapse entirely.
  #
  # Skipping is always the safe degrade — for that case and for a missing awk
  # alike. (D260) What the degraded path actually leaves is not duplicates:
  # apply_env_lines has already collapsed the four keys, so the cache keeps one
  # record each. What goes unrecorded is the fallback's GOAL_ID, leaving the
  # empty default on file while the process env holds the parent id — the same
  # cache/env divergence this block exists to close, never a corrupted or
  # truncated cache.
  if _collapsed=$(awk -v q="'" "$CACHE_KEY_AWK_FNS"'
    function scan(s,   i, c) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (inq) { if (c == q) inq = 0 }
        else if (esc) { esc = 0 }
        else if (c == "\\") { esc = 1 }
        else if (c == q) { inq = 1 }
      }
    }
    BEGIN { inq = 0; esc = 0; drop = 0 }
    {
      # (D288) key_of, not a regex on $0 - same reason as every other cache
      # filter: the awk regex engine aborts on a byte >= 0x80 in a UTF-8
      # locale, and this one sits on a write path too. (No apostrophes in
      # here: this comment lives inside a single-quoted awk program.)
      if (!inq) {
        k = key_of($0)
        drop = (k == "GOAL_ID" || k == "GOAL_IDENTIFIER" \
                || k == "GOAL_TITLE" || k == "GOAL_DESCRIPTION")
      }
      scan($0)
      if (!drop) print
    }
    END { if (inq) exit 1 }
  ' "$ENV_CACHE" 2>/dev/null); then
    {
      [ -n "$_collapsed" ] && printf '%s\n' "$_collapsed"
      for _key in GOAL_ID GOAL_IDENTIFIER GOAL_TITLE GOAL_DESCRIPTION; do
        printf '%s=%s\n' "$_key" "$(sq_escape "${!_key:-}")"
      done
    } | write_env_cache || true
  fi
}

# --- After-goal execution (shared by the D118 fast path and the D119 fresh call) ---
# Export GOAL_* from the given payload and run the local ## after_goal section as
# a blocking hook, restoring HOOK_NAME afterward. Centralised so both detection
# paths run the section identically — and, because route_after_goal invokes
# exactly one path, exactly once (de-dup).
# (D228) An after_goal failure used to be completely silent to the agent.
#
# The swallow itself is deliberate and stays: `run_stride_section` returns 2 on
# a failing command, but a non-zero SCRIPT exit would misreport the completion
# curl, which genuinely succeeded — test 10d pins that. The bug is that exit 0
# also means the stderr diagnostic reaches only the raw transcript, so nothing
# told anyone that `git push origin main` never ran. Meanwhile the server's
# grace-window worker treats ABSENCE of a report as success and flips the goal
# to Done — it has no git access and cannot know a push did not land. So the
# work silently stays local and the board says it shipped.
#
# Three channels, none of which changes the exit code:
#   1. a loud stderr line naming the consequence, in the W1658 idiom.
#   2. a durable marker under .stride/, which is already gitignored AND already
#      excluded from the diff snapshot, which the after_review cleanup block
#      does not delete, and which is CLEARED when a later after_goal succeeds.
#   3. hookSpecificOutput.additionalContext, merged into after_goal's own
#      structured object — BEST-EFFORT ONLY, see the limitation below.
#
# THE LIMITATION, measured rather than assumed. Claude Code parses hook stdout
# as ONE JSON document. When a primary section (## before_review) also ran and
# emitted its own object, stdout carries TWO concatenated documents, a strict
# parse fails with "Extra data", and the field is never read. That is this
# repo's own configuration. So channel 3 lands only when after_goal's object is
# the sole document on stdout, and channels 1 and 2 are what carry the report
# in the common case. An earlier version of this comment claimed the merge kept
# stdout to a single document; that was wrong, and review caught it. Making the
# whole stdout a single document is a wider change to a contract other
# consumers read — filed separately rather than smuggled in here.
after_goal_failure_context() {
  printf 'Stride after_goal FAILED for goal %s. The `## after_goal` section did not complete, so its `git push origin main` did NOT run — the goal work is committed LOCALLY ONLY. The server grace-window worker will still mark the goal Done; that is bookkeeping and pushes nothing. Verify with `git log origin/main..main --oneline` (expect empty) and push, or re-run the after_goal commands.' \
    "${GOAL_IDENTIFIER:-${GOAL_ID:-unknown}}"
}

# Merge the PostToolUse context field into the section's structured JSON so a
# single object carries both. Falls back to the original text unchanged when jq
# is absent or the payload does not parse — never drops the domain output.
augment_after_goal_failure_json() {
  local _json="$1" _ctx _merged
  [ "${HAS_JQ:-false}" = "true" ] || { printf '%s' "$_json"; return 0; }
  [ -n "$_json" ] || { printf '%s' "$_json"; return 0; }
  _ctx=$(after_goal_failure_context)
  # NOT `jq -c`: run_stride_section emits pretty-printed JSON and the existing
  # bash suite matches on the spaced form, so compacting here would change the
  # shape those assertions read. Note the ps1 twin emits the COMPACT form via
  # ConvertTo-Json -Compress and its own suite asserts that — so the contract
  # is evidently whitespace-tolerant across platforms, and any consumer must
  # treat it as such. Keeping the spaced form here is about not churning this
  # side, not about a contract that forbids the other.
  _merged=$(printf '%s' "$_json" | jq \
    --arg ctx "$_ctx" \
    '. + {hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}' 2>/dev/null || true)
  if [ -n "$_merged" ]; then
    printf '%s' "$_merged"
  else
    printf '%s' "$_json"
  fi
}

# Loud stderr notice plus a durable marker. Both survive whether or not the
# JSON merge above is honoured by the harness.
report_after_goal_failure() {
  local _dir="$PROJECT_DIR/.stride" _ctx
  _ctx=$(after_goal_failure_context)
  printf 'stride-hook: AFTER_GOAL UNRESOLVED — %s\n' "$_ctx" >&2
  mkdir -p "$_dir" 2>/dev/null || return 0
  # Plain key=value, matching .stride-diff-upload-state's existing convention
  # rather than inventing a second one — and it sidesteps hand-rolled JSON
  # escaping for a value that contains both quotes and backticks.
  {
    printf 'unresolved=yes\n'
    printf 'pushed=no\n'
    printf 'goal_id=%s\n' "${GOAL_ID:-}"
    printf 'goal_identifier=%s\n' "${GOAL_IDENTIFIER:-}"
    printf 'detail=%s\n' "$_ctx"
  } > "$_dir/after-goal-unresolved" 2>/dev/null || true
}

run_after_goal_section() {
  # (D228) Self-gate rather than trust the callers. Both current call sites
  # already gate on jq, but the marker logic below breaks ASYMMETRICALLY if one
  # ever does not: report_after_goal_failure is pure printf/mkdir and needs no
  # jq, while the CLEAR needs jq to produce the object it tests. An ungated
  # caller would therefore write markers that can never be cleared — round 1's
  # permanent `unresolved=yes`, reintroduced by construction. Nine other
  # functions in this script self-gate the same way, including the sibling
  # augment_after_goal_failure_json.
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  local _payload="$1"
  AFTER_GOAL_ROUTED=true
  # (W1453) Export GOAL_* (server-supplied, with the parent-id fallback for
  # GOAL_ID) before the section runs. The section observes HOOK_NAME=after_goal
  # per the documented contract; the routed value is restored afterwards because
  # the cleanup gate and finalize_after_doing key on it.
  export_after_goal_env "$_payload"
  local _routed_hook_name="$HOOK_NAME"
  export HOOK_NAME="after_goal"
  # (D228) Capture the section's stdout so a failure can be augmented into ONE
  # JSON document rather than emitting a second object beside it. stderr is not
  # captured, so the section's own diagnostics still reach the hook output
  # exactly as before. The exit code is still swallowed — deliberately.
  local _ag_out _ag_rc
  _ag_out=$(run_stride_section "after_goal")
  _ag_rc=$?
  if [ "$_ag_rc" -ne 0 ]; then
    _ag_out=$(augment_after_goal_failure_json "$_ag_out")
    report_after_goal_failure
  elif [ -n "$_ag_out" ]; then
    # (D228) Clear the marker only when the section actually RAN and passed.
    #
    # `run_stride_section` returns 0 for two different things: commands ran and
    # passed, and there were NO commands to run (the empty/absent-section early
    # return). Gating the clear on the exit code alone conflated them, so an
    # empty `## after_goal` deleted a real report without any push having
    # happened — and plugin mode ships exactly that empty fence, so a mode swap
    # after a failure erased the evidence. Review caught it; I introduced it.
    #
    # Output presence is the discriminator because the no-commands path returns
    # BEFORE emitting any JSON, while a real success emits its object. That is
    # sound here specifically: `route_after_goal` gates on HAS_JQ, so this
    # function only ever runs with jq available to produce that object. And the
    # failure direction is the safe one — if the object were ever missing after
    # a real success, the marker merely persists (stale), never erases.
    #
    # WHY BASH CANNOT USE THE PS1'S FLAG — the load-bearing constraint, since
    # the jq argument above would otherwise invite exactly the wrong fix.
    # `_ag_out=$(run_stride_section "after_goal")` is a COMMAND SUBSTITUTION,
    # so any global the function sets is discarded with the subshell. A reader
    # who accepts the jq reasoning could reasonably conclude "then set a flag
    # like the ps1 and drop the jq dependence" — and silently break clearing,
    # because the flag never propagates back. The ps1 can use a flag precisely
    # because it writes its JSON to the host stream and needs no subshell.
    # Same semantics, different mechanism, structural rather than a preference.
    rm -f "$PROJECT_DIR/.stride/after-goal-unresolved" 2>/dev/null || true
  fi
  # (D238) Stash rather than print. stdout must carry exactly ONE JSON document
  # per invocation, and this object is the SECOND one whenever a primary section
  # also ran — Claude Code parses stdout strictly, so two concatenated documents
  # made the whole stream unparseable and every harness-facing field in it was
  # silently dropped. emit_hook_stdout below is now the single writer.
  # NOTE the D228 coupling this deliberately does not disturb: the marker clear
  # above still keys on `_ag_out` being non-empty, captured from
  # run_stride_section's own stdout, which still prints exactly as before.
  AFTER_GOAL_JSON="$_ag_out"
  HOOK_NAME="$_routed_hook_name"
  export HOOK_NAME
}

# (D119) Reliability guarantee. Detect after_goal via a fresh, hook-initiated
# GET /api/tasks/:id/after_goal_status (the compact endpoint from W1613). A curl
# the hook spawns is NOT subject to the Bash-tool output truncation that can gut
# the agent-handed /complete response, and it needs zero agent cooperation. Runs
# the ## after_goal section from the endpoint's compact GOAL_* env when
# after_goal_armed is true. Best-effort: a missing prerequisite (jq/curl/TASK_ID/
# URL/token) or an unreachable / non-JSON endpoint degrades to a clean no-op —
# the server's grace-window worker still completes the goal. Never echoes the
# token. Returns 0 when it reached a definitive answer, 1 when it could not run.
detect_after_goal_via_api() {
  [ "${HAS_JQ:-false}" = "true" ] || return 1
  command -v curl > /dev/null 2>&1 || return 1
  [ -n "${TASK_ID:-}" ] || return 1

  local _api_base _token _resp _armed _payload
  _api_base=$(resolve_stride_api_url)
  _token=$(resolve_stride_api_token)
  [ -n "$_api_base" ] && [ -n "$_token" ] || return 1

  _resp=$(curl -s --max-time 10 \
    -H "Authorization: Bearer $_token" \
    "$_api_base/api/tasks/$TASK_ID/after_goal_status" 2>/dev/null || printf '')
  [ -n "$_resp" ] || return 1
  echo "$_resp" | jq -e . > /dev/null 2>&1 || return 1

  _armed=$(echo "$_resp" | jq -r '.after_goal_armed // false' 2>/dev/null || printf 'false')
  # Reached the server and got a definitive answer. Not armed → clean success.
  [ "$_armed" = "true" ] || return 0

  # Wrap the endpoint's flat env into the after_goal-hook-entry shape that
  # export_after_goal_env consumes; carry goal_id as data.parent_id so the
  # GOAL_ID parent-id fallback still applies if env omits it.
  _payload=$(echo "$_resp" \
    | jq -c '{hooks: [{name: "after_goal", env: (.env // {})}], data: {parent_id: .goal_id}}' \
        2>/dev/null || printf '')
  [ -n "$_payload" ] || return 1

  run_after_goal_section "$_payload"
  return 0
}

# --- After-goal routing (W504 / D118 / D119) ---
# Decide whether to run the local ## after_goal section after a /complete or
# /mark_reviewed post. Two mutually-exclusive paths, so the section runs at most
# once (de-dup):
#   * Fast path (D118): when the handed response is COMPLETE, valid JSON it
#     answers definitively — armed runs the section, parseable-but-absent means
#     definitively not armed. No extra round-trip either way.
#   * Reliability guarantee (D119): when the handed response is truncated,
#     absent, or unparseable, ask the server directly with a hook-spawned curl.
route_after_goal() {
  local _payload="$1"

  [ "${HAS_JQ:-false}" = "true" ] || return 0

  if [ -n "$_payload" ] && echo "$_payload" | jq -e . > /dev/null 2>&1; then
    payload_has_after_goal "$_payload" && run_after_goal_section "$_payload"
    return 0
  fi

  detect_after_goal_via_api || true
}

# Exit early if no phase argument or no .stride.md. Placed AFTER the
# capture_changed_files, finalize_after_doing, run_stride_section,
# response_has_after_goal, and hook-env forwarding definitions so tests can
# source this script to use the functions in isolation.
if [ -z "$PHASE" ]; then
  return 0 2>/dev/null || exit 0
fi

# When this script is SOURCED rather than executed, stop here. Sourcing exists
# so tests can drive the functions above in isolation, and this guard must come
# BEFORE the stdin read below.
#
# Kept as cheap insurance rather than as the load-bearing fix (W2131). The
# ordering that made it load-bearing was reverted -- see the .stride.md gate
# below -- but the hazard it names is real and costs nothing to keep out.
# `source file` with no arguments
# leaves the CALLER's positional parameters visible to the sourced script, so a
# helper invoked as `d288_probe shape-gate-notice` makes $1 -- and therefore
# $PHASE -- non-empty inside it. The phase check above then does NOT fire, and
# without this guard the read below would consume the stdin the caller had
# staged for one of those functions. That is not hypothetical: it silently broke
# 19 cases across the D281 and D288 groups, which pipe records into
# write_env_cache immediately after sourcing.
#
# Before the read was hoisted, the .stride.md check happened to absorb this case
# for the temp directories those tests use. It no longer sits above the read, so
# the protection is made explicit here rather than left as a side effect.
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
  return 0 2>/dev/null || :
fi

if [ ! -f "$STRIDE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

# Read Claude Code hook input from stdin.
#
# W2131 note on ordering: the unsafe-curl guard below deliberately sits AFTER
# this .stride.md gate, not before it. An earlier revision hoisted the read
# above the gate so the guard would also fire in projects with no .stride.md,
# on the reasoning that such a project "still loses its diff silently". That
# reasoning was wrong: every capture path -- stride_route_command, the
# ENV_CACHE read, self_heal_changed_files_upload, finalize_before_doing -- sits
# below this gate, so a project without a .stride.md captures nothing in the
# first place and has no diff to lose. The hoist bought no protection, and it
# widened the guard's blast radius from Stride-configured projects to every
# project on the machine, since hooks.json fires on every Bash call.
INPUT=$(cat)

# Detect jq availability once
HAS_JQ=false
command -v jq > /dev/null 2>&1 && HAS_JQ=true

# Extract the Bash command from hook JSON
# Try jq first, fall back to pure bash for environments without jq
if [ "$HAS_JQ" = "true" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
else
  # Pure bash JSON extraction: find "command" : "value"
  _tmp="${INPUT#*\"command\"}"
  # If the expansion didn't change, the key wasn't found
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
fi

if [ -z "$COMMAND" ]; then
  exit 0
fi

# --- W2131: refuse unsafe Stride API curl shapes (PreToolUse) --------------
#
# The three curl invocation rules are stated in stride-claiming-tasks,
# stride-workflow and stride-completing-tasks. They were still broken under
# load, and the failure is SILENT: the hook reads the API response off stdout
# to capture the diff and refresh the env cache, so hiding stdout means the
# diff is never captured and the task shows an empty changed_files with no
# error at all. A written rule that cannot fail loudly needs a gate.
#
# Scope is deliberately narrow: a command must look like a Stride API call
# before any shape is judged, so ordinary shell usage is never touched.
#
# The command text carries a Bearer token. Nothing below inspects, stores or
# emits any part of it -- matching is on URL and flag/pipe shape only, and the
# refusal message is a static string that never interpolates the command.

# Transformers that consume or alter stdout. tee is NOT here: it is the one
# blessed pipe, because it passes stdout through unchanged.
STRIDE_GUARD_TRANSFORMERS="jq head awk grep sed"

# Resolve the effective command word of a pipeline stage: step over an
# `env`/`command` wrapper and any VAR=VALUE assignments, then basename it, so
# `env FOO=1 /usr/bin/jq` and `jq` resolve alike.
stride_guard_cmd_word() {
  _gw_seg="${1#"${1%%[![:space:]]*}"}"
  while : ; do
    _gw_word="${_gw_seg%%[[:space:]]*}"
    case "$_gw_word" in
      env|command)
        _gw_seg="${_gw_seg#"$_gw_word"}"
        _gw_seg="${_gw_seg#"${_gw_seg%%[![:space:]]*}"}"
        ;;
      ?*=*)
        _gw_seg="${_gw_seg#"$_gw_word"}"
        _gw_seg="${_gw_seg#"${_gw_seg%%[![:space:]]*}"}"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "${_gw_word##*/}"
}

stride_guard_unsafe_reason() {
  _g_cmd="$1"

  # --- Cheap prefilter on the RAW text ------------------------------------
  # Both literals must appear somewhere before any work is done. This is a
  # prefilter ONLY -- it is deliberately run on the raw text, because a
  # legitimate `curl -sS "$U/api/tasks/next"` carries the endpoint inside
  # quotes and would be filtered out if this ran on the quote-blanked text.
  # It decides nothing on its own; the confirmation below is what decides.
  case "$_g_cmd" in *"/api/tasks/"*) : ;; *) return 1 ;; esac
  case "$_g_cmd" in *curl*) : ;; *) return 1 ;; esac

  # Heredoc bodies are payload, not command shape: a JSON body may legitimately
  # contain "-o" or the word jq. Strip them before judging.
  #
  # Bounded, because _stride_strip_heredocs runs a pure-bash quote walk that is
  # superlinear: measured on this tree, a quote-dense Stride curl costs 1.4s at
  # 2,052 characters, 8.1s at 4,052, 25.2s at 6,052 and 57.1s at 8,052 -- a
  # fitted exponent of about 2.7. A PreToolUse hook killed on the harness
  # timeout does NOT refuse; it fails OPEN, the one direction this guard must
  # never fail. The ceiling is set from that curve rather than as a round
  # number: 4,000 holds the walk near ten seconds, leaving headroom inside a
  # 60-second budget while staying far larger than any legitimate Stride API
  # curl (the documented completion call is a few hundred bytes). An earlier
  # revision used 20,000, which does not bound the work at all -- the budget is
  # already gone by roughly 8,300 characters.
  #
  # Past the ceiling the whole quote-aware pipeline is skipped -- BOTH the
  # heredoc strip and the quote blanking -- and the raw text is judged. Skipping
  # only the strip was wrong, and the comment that used to sit here ("can only
  # make the guard MORE likely to refuse, never less") was false: the blanking
  # scanner carries quote state, so an apostrophe left behind in an unstripped
  # heredoc body flips it and blanks a real -o on a later line. With no scanner
  # there is no state to flip, so the oversized path can only add matches --
  # monotone as a property of the code rather than as a claim about it. The cost
  # is that a -o inside a very large quoted payload false-positives above the
  # ceiling; that is the rare case, and a refusal carrying a clear message is
  # recoverable where a silent bypass is not.
  if [ "${#_g_cmd}" -gt 4000 ]; then
    _g_oversize=1
    _g_scan="$_g_cmd"
  else
    _g_oversize=0
    _g_scan=$(_stride_strip_heredocs "$_g_cmd")
  fi

  # A backslash-newline CONTINUATION is one command written over several lines,
  # so join those first -- splitting a continued curl at its line breaks would
  # shatter one command into fragments and lose the flag that follows.
  _g_joined=$(printf '%s' "$_g_scan" | awk '
    {
      if (buf != "") { line = buf $0 } else { line = $0 }
      buf = ""
      if (line ~ /\\$/) { buf = substr(line, 1, length(line) - 1) " "; next }
      print line
    }
    END { if (buf != "") print buf }')

  # Judge SHAPE only on the parts of the command outside quotes. A -d payload
  # may legitimately contain "-o" or the word jq, and a rule that fired on those
  # is one an agent learns to route around. Quoted spans are BLANKED rather than
  # deleted so offsets and adjacency are preserved and a flag cannot be
  # manufactured by splicing two sides of a removed string together. Backslash
  # escapes are modelled, matching _stride_quotes above.
  #
  # Tabs become spaces, but NEWLINES ARE KEPT: a newline is a command separator
  # in shell exactly as `;` is, and flattening it away was a real defect in both
  # directions -- it merged a curl with an unrelated neighbour (refusing a
  # compliant curl for a flag on the next line) AND hid a curl behind one (an
  # unrelated first line meant curl was never seen in command position, so an
  # unsafe curl on line two was allowed). awk works per line, so quote state
  # resets at each newline, which is the correct reading once continuations are
  # already joined above.
  if [ "$_g_oversize" = "1" ]; then
    # Stateless above the ceiling -- see the note above.
    _g_flat=$(printf '%s' "$_g_joined" | tr '\t' ' ')
  else
  _g_flat=$(printf '%s' "$_g_joined" | tr '\t' ' ' | awk '
    {
      out = ""; q = ""; n = length($0); i = 1
      while (i <= n) {
        c = substr($0, i, 1)
        if (q == "") {
          if (c == "\\") { out = out " "; i += 2; continue }
          if (c == "\047") { q = "s"; out = out " "; i++; continue }
          if (c == "\"")   { q = "d"; out = out " "; i++; continue }
          out = out c; i++
        } else if (q == "s") {
          if (c == "\047") q = ""
          out = out " "; i++
        } else {
          if (c == "\\") { out = out " "; i += 2; continue }
          if (c == "\"") q = ""
          out = out " "; i++
        }
      }
      print out
    }')
  fi

  # --- Split into COMMAND SEGMENTS ----------------------------------------
  # `;`, `&&` and `||` end one command and begin another. Judging the whole
  # string instead is how a flag belonging to an unrelated neighbour gets
  # attributed to the curl: `curl ... | tee r.json && gcc -o app` carries a -o
  # that is not curl's, and refusing it names a flag the agent's curl does not
  # have -- leaving no correct edit to make, which is exactly how a guard gets
  # switched off. A pipeline stays INSIDE its segment, because `| tee` and
  # `| jq` genuinely are part of the curl's own command.
  # Newline is already a separator in $_g_flat; turn the other three into one too.
  _g_segs=$(printf '%s' "$_g_flat" | sed 's/&&/\
/g; s/||/\
/g; s/;/\
/g')

  # Iterate segments without a pipeline, so no subshell swallows the verdict.
  _g_oldopts=$-
  _g_hit=''
  _g_oldifs=$IFS
  set -f
  # Split on newline into positional parameters, then restore IFS immediately.
  # The segment loop needs newline-only splitting; the TOKEN loop inside it
  # needs ordinary whitespace splitting, so IFS cannot stay newline for both --
  # leaving it set made every segment arrive as a single token and silently
  # disabled every refusal.
  IFS='
'
  set -- $_g_segs
  IFS=$_g_oldifs
  for _g_seg in "$@"; do
    [ -n "$_g_hit" ] && break

    # Is curl the actual COMMAND of some stage of this segment? A mere mention
    # is not enough -- that is what let `grep -o "curl.*/api/tasks/" f` and
    # `grep -rn "/api/tasks/" skills/ | grep curl` be refused as Stride curls.
    _g_is_curl=0
    _g_stage_rest="$_g_seg"
    while : ; do
      _g_stage="${_g_stage_rest%%|*}"
      case "$(stride_guard_cmd_word "$_g_stage")" in curl) _g_is_curl=1 ;; esac
      case "$_g_stage_rest" in *"|"*) _g_stage_rest="${_g_stage_rest#*|}" ;; *) break ;; esac
    done
    [ "$_g_is_curl" = "1" ] || continue

    # --- Rule 1: never -o / --output / -O ---------------------------------
    # Token-wise, because curl CLUSTERS short options and ATTACHES their values:
    # `-o out.json`, `-oout.json` and `-sSo out.json` are all the output flag.
    # `-O`/`--remote-name` is included deliberately: it likewise takes the body
    # off stdout, which is the failure this rule is about. Judging only a curl
    # segment is what makes including it safe -- `gcc -O2` and `rustc -O` are
    # different commands and are never reached.
    for _g_tok in $_g_seg; do
      case "$_g_tok" in
        --output|--output=*|--output/*) _g_hit=flag; break ;;
        --remote-name) _g_hit=remote; break ;;
        --*) : ;;
        -*)
          _g_cluster="${_g_tok#-}"
          _g_alpha=''
          while [ -n "$_g_cluster" ]; do
            case "$_g_cluster" in
              [A-Za-z]*) _g_alpha="$_g_alpha${_g_cluster%"${_g_cluster#?}"}"
                         _g_cluster="${_g_cluster#?}" ;;
              *) break ;;
            esac
          done
          case "$_g_alpha" in
            *o*) _g_hit=flag; break ;;
            *O*) _g_hit=remote; break ;;
          esac
          ;;
      esac
    done
    [ -n "$_g_hit" ] && break

    # --- Rule 2: never pipe into a transformer ----------------------------
    _g_rest="$_g_seg"
    while : ; do
      case "$_g_rest" in *"|"*) : ;; *) break ;; esac
      _g_rest="${_g_rest#*|}"
      _g_word=$(stride_guard_cmd_word "$_g_rest")
      for _g_t in $STRIDE_GUARD_TRANSFORMERS; do
        if [ "$_g_word" = "$_g_t" ]; then _g_hit=pipe; break; fi
      done
      [ -n "$_g_hit" ] && break
    done
  done
  case "$_g_oldopts" in *f*) : ;; *) set +f ;; esac

  case "$_g_hit" in
    flag)   printf 'flag';   return 0 ;;
    remote) printf 'remote'; return 0 ;;
    pipe)   printf 'pipe';   return 0 ;;
  esac
  return 1
}

if [ "$PHASE" = "pre" ]; then
  STRIDE_GUARD_KIND=$(stride_guard_unsafe_reason "$COMMAND" || true)
  if [ -n "$STRIDE_GUARD_KIND" ]; then
    if [ "$STRIDE_GUARD_KIND" = "remote" ]; then
      STRIDE_GUARD_MSG="Refused: this Stride API curl uses -O/--remote-name, which writes the body to a file instead of stdout. The Stride hook reads that response to capture your file diff and refresh the env cache, so the diff is dropped silently and the task completes with an empty changed_files and no error. The rule is stated for -o/--output, and -O is refused for the same reason rather than as a separate rule: it takes the body off stdout. Use: curl ... | tee \"\$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json\""
    elif [ "$STRIDE_GUARD_KIND" = "flag" ]; then
      STRIDE_GUARD_MSG="Refused: this Stride API curl uses -o/--output, which removes the response from stdout. The Stride hook reads that response to capture your file diff and refresh the env cache, so hiding it drops the diff silently and the task completes with an empty changed_files and no error. Rule: never -o/--output, never pipe into a transformer (jq, head, awk, grep, sed), always pipe into tee. Use: curl ... | tee \"\$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json\""
    else
      STRIDE_GUARD_MSG="Refused: this Stride API curl pipes into a transformer (jq, head, awk, grep or sed), which alters or truncates what the Stride hook reads from stdout. The hook needs the response verbatim to capture your file diff and refresh the env cache, so the diff is dropped silently and the task completes with an empty changed_files and no error. tee is the one blessed pipe, because it passes stdout through unchanged. Use: curl ... | tee \"\$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json\""
    fi
    if [ "$HAS_JQ" = "true" ]; then
      printf '%s' "$STRIDE_GUARD_MSG" | jq -Rsc '{decision:"block",reason:.}' 2>/dev/null \
        || printf '{"decision":"block","reason":"%s"}\n' "$STRIDE_GUARD_MSG"
    else
      # Hand-rolled JSON. The reason is a static string chosen above, so no
      # caller-controlled data is interpolated -- but "static" is not the same
      # as "needs no escaping": both messages quote the tee path, so the value
      # carries literal double quotes that would close the JSON string early.
      # Escaping them here is what keeps the no-jq path emitting the same valid,
      # compact object the jq path does.
      printf '{"decision":"block","reason":"%s"}\n' "${STRIDE_GUARD_MSG//\"/\\\"}"
    fi
    printf 'stride-hook: %s\n' "$STRIDE_GUARD_MSG" >&2
    exit 2
  fi
fi

# --- Determine which Stride hook to run (D220) ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review
#
# stride_route_command is the ONLY place the command text is inspected for
# routing: it requires the call to actually ISSUE the request (client in command
# position, endpoint as the tail of a URL in argument position, matching method)
# rather than merely mention it. The after-goal gate below reads its published
# STRIDE_ROUTE_ENDPOINT so the two cannot drift.

stride_route_command "$PHASE" "$COMMAND"
HOOK_NAME="$STRIDE_ROUTE_HOOK"

# (W1453) Set when an after_goal entry is routed; defers the after_review
# env-cache cleanup so the agent can still read GOAL_* for the follow-up PATCH.
AFTER_GOAL_ROUTED=false

# Not a Stride API call — exit cleanly
if [ -z "$HOOK_NAME" ]; then
  exit 0
fi
# (W1454) Commands now run as `bash -c` children rather than in-shell eval,
# so the documented "section observes $HOOK_NAME" contract needs the export
# (the after_goal route already exports its override).
export HOOK_NAME

# (W1609) Persist THIS call's response to the canonical file before the claim
# env-cache refresh and env forwarding read it, so both resolve the current
# call's data (file-first) rather than a stale prior-call file. A no-op when the
# stdout is truncated (leaves any out-of-band tee/--output copy intact) or when
# this is a pre-phase call with no tool_response yet.
if [ "$PHASE" = "post" ]; then
  capture_canonical_response "$INPUT"
fi

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if [ "$HOOK_NAME" = "before_doing" ]; then
  # (W1609) Resolve the claim response through the ONE shared resolver
  # (extract_response_payload): canonical response file first, then the
  # tool_response.stdout unwrap, then the W1086 persisted-output file. This is
  # the same resolver after_goal detection and env forwarding use, so a
  # harness-truncated claim stdout no longer diverges — when a canonical
  # response file is present (the capture above, a curl tee, or D119) the full
  # task JSON is recovered and the task identity stays correct.
  #
  # (D142) This block refreshes IDENTITY only. TASK_BASE_REF is deliberately
  # NOT written here: the ## before_doing section has not run yet, and its
  # `git pull` moves HEAD — a base captured now would anchor the diff at the
  # PRE-pull commit and span another clone's pulled work (D132/W1678).
  # finalize_before_doing writes the base (and the dirty baseline) after the
  # section finishes.
  TASK_JSON=""
  if [ "$HAS_JQ" = "true" ]; then
    _claim_payload=$(extract_response_payload "$INPUT")
    if [ -n "$_claim_payload" ]; then
      if echo "$_claim_payload" | jq -e '.data.id' > /dev/null 2>&1; then
        TASK_JSON=$(echo "$_claim_payload" | jq -c '.data' 2>/dev/null)
      elif echo "$_claim_payload" | jq -e '.id' > /dev/null 2>&1; then
        TASK_JSON="$_claim_payload"
      fi
    fi
  fi

  # (D226) Whether THIS call's OWN response proved the task identity — which
  # is a stricter question than whether an identity was resolved at all, and
  # the distinction is load-bearing. The shared resolver prefers the canonical
  # response file, and that file SURVIVES ACROSS CALLS. So a nested claim
  # whose stdout is truncated resolves the PREVIOUS claim's payload and
  # reports the outer task's id. Stamping ownership from that is worse than
  # not stamping: it overwrites the outer task's record with the nested
  # claim's HEAD and then vouches for it, so the owner MATCHES at completion,
  # the refusal never fires, and the outer task uploads a purely foreign diff
  # — W2066 exactly. Measured, not theorised; review caught it.
  #
  # Identity refresh itself is unchanged, so D118/W1609 truncation recovery
  # still works. Only the ownership stamp is gated, and the cost of withholding
  # it is nil: the task falls back to the shared TASK_BASE_REF, which on its
  # own claim is genuinely its own base.
  # The gate compares IDS, not mere presence. Proving that this call carried
  # some id is weaker than proving it carried the SAME id that reached
  # TASK_ID: if capture_canonical_response's write fails (an unwritable
  # .stride/) while this call's stdout is valid JSON, a presence test passes
  # while TASK_ID still holds the PREVIOUS task's — the original defect shape.
  TASK_IDENTITY_REFRESHED=0
  TASK_OWNER_ID=""
  _own_call_payload=$(unwrap_tool_response "$INPUT" 2>/dev/null || true)
  if [ -n "$TASK_JSON" ]; then
    _own_call_id=$(echo "$_own_call_payload" | jq -r '.data.id // .id // empty' 2>/dev/null || true)
    _resolved_id=$(echo "$TASK_JSON" | jq -r '.id // empty' 2>/dev/null || true)
    if [ -n "$_own_call_id" ] && [ "$_own_call_id" = "$_resolved_id" ]; then
      TASK_IDENTITY_REFRESHED=1
      # (D226) Carry the VALIDATED id forward in-process. The stamp must not
      # be re-read from TASK_ID later: that value comes from the cache, which
      # is sourced AFTER the identity rewrite, so the two agree only when that
      # write landed. When it does not — a read-only project dir, ENOSPC —
      # TASK_ID is still the previous task's while this claim writes its own
      # base, which re-creates the original silent-foreign-diff hole through
      # the very helper added to make writes safe. Measured; review caught it.
      TASK_OWNER_ID="$_resolved_id"
    fi
    # (D226) This rewrite TRUNCATES the cache, so carry the per-task base-ref
    # records across it. Without this a nested claim erases the outer task's
    # anchor here — before finalize_before_doing ever runs — and the isolation
    # fix would protect nothing. The shared TASK_BASE_REF / _TRUSTED / _OWNER
    # keys are still dropped, exactly as D142 requires.
    # (D236) The per-task HEAD records have to survive for exactly the same
    # reason — and they are useless without their partner: a base says where a
    # nested task started, the head says where it stopped, and attribution
    # needs BOTH. Dropping them here is precisely how the first version of the
    # D226 fix silently reverted to over-collecting.
    # (D255) The owned-commit records ride with the head records — same bug
    # class.
    # (D268) The old three independent `tail -n 20` pipelines here evicted the
    # oldest record per family — structurally the still-open outer task's own
    # anchor once 20 nested claims had rewritten the cache, which is exactly
    # the erasure the D226 comment above promises to prevent, just 20 claims
    # later. Eviction is now per-window and open-window-aware, shared with
    # finalize_before_doing, and (D274) no longer caps open windows by count
    # at all — this call site is the one that reserves nothing, so before D274
    # it was the one whose cap fired at 20 rather than 19 — see
    # select_kept_window_records for the decided
    # policy and the family-desync answer (head/owned live and die with their
    # base; a half-bounded window can no longer be produced by the cap).
    # (D287 r2) Same rule as finalize_before_doing: an unparseable cache skips
    # the rebuild rather than committing one with every window record dropped.
    #
    # A parse failure here is a TORN WRITE, never an injection. Every writer
    # into this cache balances its quotes — jq `@sh` and sq_escape both render
    # an embedded quote as '\'' — so no server-supplied value can leave the
    # file unterminated. The reachable causes are the non-atomic append
    # fallback interrupted by a budget kill, or a missing awk. That is why
    # preserving the previous cache is the right answer rather than a risk:
    # the corrupt state is not attacker-shaped, and the records being preserved
    # are this checkout's real anchors.
    _kept_window_rebuild=1
    _kept_window_records=$(select_kept_window_records) || _kept_window_rebuild=0
    # (D273) Carry each KEPT window's claim-time stamp through the rebuild.
    # This branch emits ONLY the selector's three families plus the six fixed
    # identity keys, so without this every TASK_BASE_AT_ line is erased at the
    # very next claim — every surviving open window would then read as
    # unstamped, the predicate would retire live windows wholesale, and the
    # D255 nesting 23u/23w pin would stop narrowing. Eviction policy is
    # untouched: which windows survive is still decided entirely by
    # select_kept_window_records, and this only lets a newer family follow the
    # decision it already made.
    _kept_window_stamps=""
    while IFS= read -r _kept_line; do
      case "$_kept_line" in
        TASK_BASE_REF_*) : ;;
        *) continue ;;
      esac
      _kept_id="${_kept_line%%=*}"
      _kept_id="${_kept_id#TASK_BASE_REF_}"
      case "$_kept_id" in
        "" | TRUSTED | OWNER | UNPROVEN) continue ;;
      esac
      # Same sanitizer + shape-checked reader + re-emit as the finalize
      # carry-forward, and the same two families: the claim stamp AND the
      # narrowing verdict, which another task may still need for a self-heal
      # that has not run yet. finalize_before_doing drops self's verdict
      # immediately after this; see its comment for why carrying other tasks'
      # matters and why a copied grep hit is not safe.
      _kept_key=$(task_base_at_key "$_kept_id")
      if [ -n "$_kept_key" ] && _kept_stamp=$(read_task_record "$_kept_key"); then
        [ -n "$_kept_stamp" ] && _kept_window_stamps="${_kept_window_stamps}${_kept_key}=$(sq_escape "$_kept_stamp")"$'\n'
      fi
      _kept_key=$(task_narrowed_key "$_kept_id")
      if [ -n "$_kept_key" ] && _kept_stamp=$(read_task_record "$_kept_key"); then
        _kept_window_stamps="${_kept_window_stamps}${_kept_key}=$(sq_escape "$_kept_stamp")"$'\n'
      fi
    done <<< "$_kept_window_records"
    # Values are single-quote escaped via sq_escape (W1453) so titles with
    # spaces, quotes, or dollar signs survive the `set -a` sourcing without
    # any shell interpretation.
    #
    # (D287 r2) Skipped entirely when the selector could not parse the cache.
    # This claim then records no base of its own, which lands on the documented
    # unproven-base path: select_task_snapshot_base REFUSES rather than
    # attributing a wrong diff.
    #
    # (r3) That is the right trade but it is NOT self-healing, and an earlier
    # version of this comment said it was. Nothing on the claim path repairs a
    # torn cache: the next claim reads the same unparseable file, skips the
    # rebuild again and records no base again, and the `_preserved` fallback
    # below keeps the torn file rather than replacing it. The only unconditional
    # deletion is the after_review cleanup, which is itself skipped when
    # after_goal rode the response. So the honest statement is: every affected
    # task REFUSES rather than uploading a wrong diff, and it keeps refusing
    # until someone removes the cache. Refusal is recoverable; erasing every
    # other task's anchor is not.
    if [ "$_kept_window_rebuild" = 0 ]; then
      printf 'stride-hook: skipping the env-cache rebuild; the previous cache is kept intact\n' >&2
    else
    {
      [ -n "$_kept_window_records" ] && printf '%s\n' "$_kept_window_records"
      [ -n "$_kept_window_stamps" ] && printf '%s' "$_kept_window_stamps"
      echo "TASK_ID=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.id // empty')")"
      echo "TASK_IDENTIFIER=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.identifier // empty')")"
      # (D281) RULING, multi-line values: bash does NOT flatten, and must not
      # start. `source` reassembles a quoted value across newlines, and a
      # TASK_DESCRIPTION legitimately carries them for sections to consume;
      # flattening would be a user-visible regression on the shipping executor
      # for no security gain. The PowerShell twin DOES flatten its own writes,
      # deliberately — ConvertTo-FlatEnvValue is half of what closed D280's
      # BASH_ENV route, and .NET readers honour terminators bash does not. That
      # asymmetry is permanent and must not be copied back here. It is a CONTENT
      # divergence, not a PRESENCE one: both readers present a TASK_TITLE either
      # way. The full ruling is above Write-EnvCache in stride-hook.ps1.
      echo "TASK_TITLE=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.title // empty')")"
      echo "TASK_STATUS=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.status // empty')")"
      echo "TASK_COMPLEXITY=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.complexity // empty')")"
      echo "TASK_PRIORITY=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.priority // empty')")"
    } | write_env_cache || true
    fi
  elif [ -f "$ENV_CACHE" ]; then
    # (W1086/D142) No parseable response and no usable persisted file: keep
    # the existing TASK_ identity lines (a later completion can still recover
    # TASK_ID) but STRIP the inherited TASK_BASE_REF (and its trust marker)
    # NOW — even if this process dies before finalize_before_doing rewrites
    # it, a base from a previous task or session must never survive a claim.
    # (D226) TASK_BASE_REF_OWNER goes with the base it stamps — leaving it
    # behind would let a stripped cache still claim ownership. The per-task
    # TASK_BASE_REF_<id> records are deliberately kept: they belong to tasks
    # other than this claim and are the whole point of the isolation.
    # (D273) TASK_BASE_AT_ and TASK_NARROWED_ are both KEPT here, like the
    # per-task base records this branch already keeps and for the same reason:
    # they belong to OTHER tasks. This branch could not identify the claiming
    # task, so it cannot single out self's record — and a blanket strip is the
    # wrong trade, because it would destroy the verdict of a task still waiting
    # to self-heal, leaving its retry to re-derive the D255 gate and narrow a
    # snapshot that captured wide. finalize_before_doing drops self's own
    # verdict on the proven path.
    #
    # (D259) This is an ALLOW-list, and it used to be a four-key deny-list —
    # which meant the comment above and the code disagreed. The comment says
    # "keep the existing TASK_ identity lines"; the code kept everything that
    # was not one of four TASK_BASE_REF keys, so GOAL_*, BOARD_*, COLUMN_* and
    # AGENT_NAME all crossed the window boundary. Measured: a cache holding
    # GOAL_ID='6', two contradictory GOAL_TITLE lines and BOARD_ID='3' still
    # held all four after an unparseable claim. A fresh task window then opened
    # with the PREVIOUS goal's identity exported to every hook and agent
    # command in it — a goal-status PATCH aimed at a goal this task does not
    # belong to.
    #
    # The parseable branch above emits exactly the five per-task record
    # families plus six fixed TASK_ identity keys, and nothing else. The two
    # branches are two ways of surviving the same event, so they owe the same
    # guarantee; this list is that branch's emitted set, which is why it is
    # written as an allow-list rather than a deny-list with a fifth key added.
    # A deny-list here also has to be extended every time a family is added and
    # is silently wrong until someone notices — the accumulation that left
    # TASK_HEAD_REF unfenced through three defects until D258.
    #
    # What clearing GOAL_*/BOARD_*/COLUMN_*/AGENT_NAME actually costs, stated
    # accurately: on THIS branch nothing refills them. The branch runs because
    # the response did not parse, so extract_hook_env yields nothing and
    # apply_env_lines is a no-op — BOARD_*, COLUMN_*, AGENT_NAME,
    # TASK_DESCRIPTION and TASK_NEEDS_REVIEW are simply ABSENT for the whole
    # flaky window, including in the ## before_doing section that runs next.
    # They return on the next successful API response, because all five hooks
    # carry AGENT_NAME/BOARD_*/COLUMN_* in their env.
    #
    # That is the right trade, and absent is the point rather than a
    # side-effect: a section reading BOARD_NAME during a flaky window should
    # see nothing rather than the PREVIOUS window's board. GOAL_* is stronger
    # still — it is supplied only on after_goal and never at claim time, so a
    # surviving value could not be corrected by any later response in this
    # window, which is why the parseable path already drops it.
    #
    # THE SCAN IS QUOTE-AWARE for the same reason D257's is: values reach this
    # cache through apply_env_lines, TASK_DESCRIPTION routinely contains
    # newlines, and a line-based allow-list would keep a record's first line
    # and drop its continuations — or keep an orphaned continuation of a record
    # it dropped. Records are identified by shell-quoting state; a line starts
    # a record only when the scanner is outside quotes, and continuation lines
    # inherit their record's decision. It fails closed: EOF while still inside
    # a value means the sq_escape invariant was violated, so it falls back to
    # the previous deny-list behaviour, which over-preserves (today's bug)
    # rather than dropping a record it could not parse.
    # (D288) Matched with key_of/has_prefix rather than regexes on $0. This is
    # the PRIMARY branch, and it was the last cache filter still using a regex:
    # on a cache holding a byte >= 0x80 in a UTF-8 locale awk aborts with
    # "towc: multibyte conversion failure", which would send every such claim
    # down the fallback below forever. That degrades safely (the fallback
    # over-preserves) but it is not what this branch is for, and it made the
    # decision document's "every cache filter matches with index/substr" claim
    # untrue. The keep-set is unchanged: the six fixed identity keys, plus the
    # five per-task families, minus the three shared TASK_BASE_REF_ flags.
    if ! _preserved=$(awk -v q="'" "$CACHE_KEY_AWK_FNS"'
      function scan(s,   i, c) {
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (inq) { if (c == q) inq = 0 }
          else if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == q) { inq = 1 }
        }
      }
      function keep_key(k) {
        if (k == "TASK_ID" || k == "TASK_IDENTIFIER" || k == "TASK_TITLE" \
            || k == "TASK_STATUS" || k == "TASK_COMPLEXITY" || k == "TASK_PRIORITY") return 1
        if (k == "TASK_BASE_REF_TRUSTED" || k == "TASK_BASE_REF_OWNER" \
            || k == "TASK_BASE_REF_UNPROVEN") return 0
        # The regex required at least one character after the family prefix
        # (`_[A-Za-z0-9_]+=`), so a bare `TASK_OWNED_=` was never kept.
        if (has_prefix(k, "TASK_BASE_REF_") && length(k) > length("TASK_BASE_REF_")) return 1
        if (has_prefix(k, "TASK_HEAD_REF_") && length(k) > length("TASK_HEAD_REF_")) return 1
        if (has_prefix(k, "TASK_OWNED_") && length(k) > length("TASK_OWNED_")) return 1
        if (has_prefix(k, "TASK_BASE_AT_") && length(k) > length("TASK_BASE_AT_")) return 1
        if (has_prefix(k, "TASK_NARROWED_") && length(k) > length("TASK_NARROWED_")) return 1
        return 0
      }
      BEGIN { inq = 0; esc = 0; keep = 0 }
      {
        if (!inq) { keep = keep_key(key_of($0)) }
        scan($0)
        if (keep) print
      }
      END { if (inq) exit 1 }
    ' "$ENV_CACHE" 2>/dev/null); then
      # (D288) awk for the same reason as the writer sites, and this one bites
      # harder than they do: an empty result here does not commit a short cache,
      # it takes the else branch below and DELETES the cache outright. This is
      # the fallback for the quote-aware scan above having failed to parse, so
      # it stays a plain line filter - what it must not stay is a grep that can
      # decline to read the file at all.
      # (D288) Same distinction as finalize_before_doing, and the stakes are
      # higher: the else branch below deletes the cache. Only a filter that
      # RAN and found nothing may reach it.
      if ! _preserved=$(drop_shared_base_records); then
        _preserved=""
        _preserved_failed=1
      fi
    fi
    if [ -n "$_preserved" ]; then
      printf '%s\n' "$_preserved" | write_env_cache || true
    elif [ "${_preserved_failed:-0}" = 1 ]; then
      printf 'stride-hook: could not filter the env cache; keeping the previous cache rather than deleting it\n' >&2
    else
      rm -f "$ENV_CACHE" 2>/dev/null || true
    fi
  fi

  # A claim always opens a new task window: clear the previous task's
  # snapshot, upload state (W1094 — a stale 2xx would suppress the
  # before_review self-heal retry), and dirty baseline unconditionally.
  rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-dirty-baseline" 2>/dev/null || true
  # (D234) The durable hook results belong to the task window too. They carry
  # no task id, and the documented reader rule only covers ABSENCE ("no file
  # means the section was empty, keep 0") — so a file left behind by the
  # previous task is indistinguishable from this task's own. That is reachable,
  # not theoretical: swapping .stride.md to plugin mode empties every section,
  # so this task writes nothing and the previous task's figure survives to be
  # read as this one's. Clearing here makes absence mean what the reader is
  # told it means.
  rm -f "$PROJECT_DIR"/.stride/.hook-result-*.json 2>/dev/null || true
  # (W2123) The loop state belongs to the task window too, and it is the one
  # file whose staleness has teeth: it exists so a Stop gate can refuse to end
  # a session on an un-followed completion, so a record left over from the
  # PREVIOUS task would fire that gate on work that is already done. A claim is
  # exactly the event that proves the completion was followed.
  #
  # The clear is UNCONDITIONAL, and that is a decision rather than an oversight.
  # Preserving the record on a FAILED claim was implemented and then reverted:
  # the claim that fails most often is the one against an empty ready queue,
  # which is how essentially every session ends. A record preserved there is
  # byte-identical to one left by an agent that completed and never claimed at
  # all — yet a gate must refuse in the second case and must not in the first,
  # and none of the four keys can tell them apart. That is the same false gate
  # this file exists to avoid, reached through the failed-claim branch instead.
  # An over-eager clear costs only a missed gate, and missed is the safe side.
  #
  # The removal is best-effort but NOT silent: a clear that fails leaves a
  # stale record, the one direction this design calls dangerous, so it is
  # announced. The sibling artefacts above are cleared silently because their
  # staleness is benign; this one's staleness is the whole point of the task.
  # (W2125) The recorded terminal state belongs to the task window too: a claim
  # is precisely the event that proves a halt was resumed or an error resolved,
  # and a record surviving one would silently disable the Stop gate in every
  # later session. Cleared unconditionally, like its siblings above.
  rm -f "$PROJECT_DIR/.stride/.terminal-state.json" 2>/dev/null || true
  if [ -e "$LOOP_STATE_FILE" ]; then
    rm -f "$LOOP_STATE_FILE" 2>/dev/null || true
    if [ -e "$LOOP_STATE_FILE" ]; then
      printf 'stride-hook: could not clear the loop state at %s; a stale completion record remains\n' \
        "$LOOP_STATE_FILE" >&2
    fi
  fi
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  # (D287, superseding the D281 loader ruling) The cache is filtered by key
  # before the shell sees it. The reasoning — which of D281's two grounds
  # survived, and why the mechanism is still shell interpretation rather than a
  # hand-rolled parse-and-export — is above filter_cache_records.
  #
  # `eval` rather than `.` because the content is now a filtered STRING, not the
  # file. The two are equivalent for assignment lines, and apply_env_lines has
  # used `eval` under `set -a` on exactly this content since it was written.
  # An empty result — an absent cache, a cache with nothing admissible, or a
  # broken quote — evaluates to nothing, which is the fail-closed outcome.
  STRIDE_CACHE_LINES=$(filter_cache_records)
  set -a
  eval "$STRIDE_CACHE_LINES" 2>/dev/null || true
  set +a
  unset STRIDE_CACHE_LINES
fi

# (W1453) Forward the server-supplied hook env for the routed hook. The
# response's hook entry (singular `.hook` on claim, `.hooks[]` on complete/
# mark_reviewed) carries the authoritative env block. Applied AFTER the cache
# load so server-supplied keys override stale cached values; keys the server
# does not supply keep their cached values. PreToolUse (pre phase) has no
# tool_response yet, so this is post-only.
RESPONSE_PAYLOAD=""
if [ "$PHASE" = "post" ]; then
  RESPONSE_PAYLOAD=$(extract_response_payload "$INPUT")
  apply_env_lines "$(extract_hook_env "$RESPONSE_PAYLOAD" "$HOOK_NAME")"
fi

# (W1094) Verify-and-retry the changed_files upload before the primary
# before_review section runs — fresh PostToolUse budget; TASK_ID and
# TASK_BASE_REF are in scope from the env cache. Self-gates on
# HOOK_NAME=before_review; best-effort, never fails the hook.
self_heal_changed_files_upload || true

# (W2123) Record the loop state for a successful completion. Self-gates on
# HOOK_NAME=before_review — the hook that fires after /complete succeeds — and
# is best-effort: a failure to record is logged to stderr and swallowed, never
# fatal to the completion.
record_loop_state_for_completion || true

# (D238) THE SINGLE STDOUT WRITER. Claude Code parses a hook's stdout as ONE
# JSON document. run_stride_section emits one object per section, so whenever a
# primary section AND `## after_goal` both ran, stdout carried two concatenated
# documents; a strict parse fails with "Extra data" and the harness falls back to
# treating the whole stream as plain text. Every harness-facing field in it was
# therefore dropped in that configuration — including the
# hookSpecificOutput.additionalContext channel D228 added, which is why D228 had
# to document that channel as best-effort rather than reliable.
#
# jq is NOT a strict parser here and must never be used to verify this: both
# `jq .` and `jq -s` accept a concatenated stream, which is exactly how a D228
# guard test asserted the broken value and passed. Verify with python json.loads.
#
# SHAPE, and why it is conditional. One section ran -> that section's object,
# byte-identical to what shipped before this change; that covers every failure
# path and every route where after_goal does not fire, so no existing consumer
# moves. More than one ran -> a wrapper carrying them in order. The wrapper has
# no "hook" key and the section objects always do, so `if .hook then <single>
# else .sections[] end` discriminates without guessing. The multi-section case
# has no back-compat obligation because what it emitted before parsed for
# nobody.
#
# hookSpecificOutput is HOISTED to the top of the wrapper. It is addressed to the
# harness, not to a section, and the harness only reads the document root — the
# whole point of the fix.
#
# COLLISION RULE: after_goal wins. Only after_goal sets the key today, so this is
# unreachable — but the ordering was originally the other way round, and review
# pointed out it was backwards on the merits: a future primary-section field
# would silently clobber D228's after_goal failure context, which is the one
# payload this whole fix exists to deliver. The clauses below are applied
# primary-first, after_goal-second, so the later one wins. The PowerShell twin
# iterates the sections in order and takes the last, which is the same rule.
emit_hook_stdout() {
  local _primary="$1"
  if [ -z "$_primary" ] && [ -z "$AFTER_GOAL_JSON" ]; then
    return 0
  fi
  if [ -z "$AFTER_GOAL_JSON" ]; then
    printf '%s\n' "$_primary"
    return 0
  fi
  if [ -z "$_primary" ]; then
    printf '%s\n' "$AFTER_GOAL_JSON"
    return 0
  fi
  if [ "${HAS_JQ:-false}" != "true" ]; then
    # DEFENSIVE, and unreachable as the code stands: run_after_goal_section
    # self-gates on HAS_JQ and returns early without it, so AFTER_GOAL_JSON can
    # only be non-empty when jq is present. Kept because the alternative to a
    # merge we cannot perform is emitting a stream nothing can parse, which is
    # the exact defect this function exists to remove — and because a future
    # caller that stashes AFTER_GOAL_JSON without that gate would otherwise
    # reintroduce it silently. Losing the after_goal detail beats losing BOTH
    # objects; the durable per-hook result file (D234) still carries it.
    printf '%s\n' "$_primary"
    return 0
  fi
  jq -n --argjson primary "$_primary" --argjson after_goal "$AFTER_GOAL_JSON" \
    '{sections: [$primary, $after_goal]}
     + (if ($primary.hookSpecificOutput // null) != null
        then {hookSpecificOutput: $primary.hookSpecificOutput} else {} end)
     + (if ($after_goal.hookSpecificOutput // null) != null
        then {hookSpecificOutput: $after_goal.hookSpecificOutput} else {} end)' \
    2>/dev/null || printf '%s\n' "$_primary"
}

# --- Execute the primary hook ---
# run_stride_section emits the structured JSON itself (success or failed shape)
# and finalizes the per-file diff snapshot via the file-scope helper. Failure
# exits 2 here to preserve the existing PreToolUse blocking semantic for
# after_doing (other routes are PostToolUse where exit 2 has no gating effect
# but matches the historical exit shape).
# (D238) Buffered, not printed. A REDIRECT rather than a command substitution:
# `$( )` would run the section in a subshell and discard every global it sets,
# which is the same trap the D228 marker comment warns about.
#
# THE UNREDIRECTED FALLBACK IS NOT OPTIONAL, and review caught its absence as a
# critical regression. Bash does not execute a command at all when it cannot
# open the command's redirect target — so buffering into a file makes running
# the user's hook section conditional on that file being creatable. With
# `.stride/` unwritable (permissions, a full disk, a read-only filesystem) the
# section silently never ran: on the after_doing/PreToolUse route that is the
# quality gate skipped entirely, and since exit 1 does not block in PreToolUse,
# the completion proceeded with tests never having run. Measured against HEAD:
# HEAD exits 0 and runs the section, the buffered version exited 1 and did not.
# The PowerShell twin buffers in memory and its suite asserts this property
# outright (19g, "an unwritable .stride/ does not fail the hook").
#
# So: prefer a private temp file, fall back to the system temp dir, and if no
# buffer can be created anywhere, run the section UNREDIRECTED. Degrading to the
# pre-D238 two-document stdout is strictly better than not running the hook —
# the defect that costs is a parse failure, the one avoided here is a skipped
# quality gate.
PRIMARY_JSON_FILE=""
if mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null; then
  PRIMARY_JSON_FILE=$(mktemp "$PROJECT_DIR/.stride/.primary-section-out.XXXXXX" 2>/dev/null) || PRIMARY_JSON_FILE=""
fi
if [ -z "$PRIMARY_JSON_FILE" ]; then
  PRIMARY_JSON_FILE=$(mktemp "${TMPDIR:-/tmp}/stride-primary-out.XXXXXX" 2>/dev/null) || PRIMARY_JSON_FILE=""
fi
if [ -n "$PRIMARY_JSON_FILE" ]; then
  run_stride_section "$HOOK_NAME" > "$PRIMARY_JSON_FILE"
  PRIMARY_RC=$?
  PRIMARY_JSON=$(cat "$PRIMARY_JSON_FILE" 2>/dev/null || true)
  rm -f "$PRIMARY_JSON_FILE" 2>/dev/null || true
else
  # No buffer anywhere — run it for real. PRIMARY_JSON stays empty, so
  # emit_hook_stdout will not re-print what the section already wrote itself.
  #
  # ANNOUNCE IT. This path gives up the one-document guarantee: if after_goal
  # also runs, stdout carries two concatenated documents again — the pre-D238
  # behaviour, deliberately chosen over not running the user's hook, but a
  # degradation either way. Silence here would leave the rarest state in the
  # script also the least diagnosable, and this script's idiom is the opposite
  # (see AFTER_GOAL UNRESOLVED). Note emit_hook_stdout cannot infer this state:
  # an empty PRIMARY_JSON also means "the section had no commands", which is
  # entirely legitimate, so the notice has to be emitted here where the two are
  # still distinguishable.
  PRIMARY_UNREDIRECTED=true
  echo "stride-hook: could not create a stdout buffer in .stride/ or ${TMPDIR:-/tmp}; the ${HOOK_NAME} section ran unbuffered and stdout may carry two JSON documents" >&2
  run_stride_section "$HOOK_NAME"
  PRIMARY_RC=$?
  PRIMARY_JSON=""
fi

# (D142) Capture TASK_BASE_REF only now — AFTER ## before_doing ran its
# `git pull` / branch checkout — so the base is the post-pull branch point.
# Runs even when the section failed: the claim already succeeded (PostToolUse
# cannot veto it) and a partially-run section still leaves HEAD more accurate
# than the pre-pull value. No-op for every other hook route.
finalize_before_doing

if [ "$PRIMARY_RC" -ne 0 ]; then
  # (D238) Failure is always a single-section document — after_goal never runs
  # after a failed primary — so this emits the exact shape that shipped before
  # this change. That matters: exit 2 is the one path whose stdout reaches the
  # model, so it is the shape agents and hook-diagnostician actually read.
  emit_hook_stdout "$PRIMARY_JSON"
  exit "$PRIMARY_RC"
fi

# --- After-goal routing (W504 / D118 / D119) ---
# When completing the last child of a goal, run the local `## after_goal`
# section as a blocking hook. Detection prefers the handed response when it is
# complete (D118 fast path) and otherwise falls back to a fresh, hook-initiated
# GET /api/tasks/:id/after_goal_status that is immune to harness truncation
# (D119 — the reliability guarantee). route_after_goal keeps the two paths
# mutually exclusive so the section runs at most once. Missing `## after_goal`
# in .stride.md is a clean no-op; the server's grace-window worker still covers
# goal completion when neither path can detect it. A non-zero section exit is
# surfaced via the structured JSON shape, never as a non-zero script exit (the
# primary curl already succeeded).
# (D220) Gate on the endpoint the router already resolved, never on the raw
# command text — a mention of a completion URL is not a completion call.
if [ "$PHASE" = "post" ]; then
  case "$STRIDE_ROUTE_ENDPOINT" in
    complete|mark_reviewed)
      route_after_goal "$RESPONSE_PAYLOAD"
      ;;
  esac
fi

# Clean up env cache and per-file diff snapshot after the final hook in the
# lifecycle. after_goal piggy-backs on after_review's lifecycle when present,
# so this gate intentionally stays on $HOOK_NAME == "after_review".
if [ "$HOOK_NAME" = "after_review" ]; then
  # (W1453) Keep the env cache when after_goal rode this response — the agent
  # still needs GOAL_ID from it for the follow-up
  # PATCH /api/tasks/:goal_id/after_goal. The next claim rewrites the cache.
  if [ "$AFTER_GOAL_ROUTED" != "true" ]; then
    rm -f "$ENV_CACHE" 2>/dev/null || true
  fi
  rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-dirty-baseline" 2>/dev/null || true
fi

# (D238) The one and only stdout write on the success path, after after_goal
# routing has had its chance to contribute a second section.
emit_hook_stdout "$PRIMARY_JSON"

exit 0
