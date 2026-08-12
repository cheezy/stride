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

# (D238) The after_goal section's structured result, stashed by
# run_after_goal_section so that emit_hook_stdout can emit ONE document. Declared
# here because `set -u` is active and the emitter reads it unconditionally.
AFTER_GOAL_JSON=""

# (D236) Sentinel for "attribution applies and this task owns NO commits" — as
# distinct from "no nested window applies", which is empty output. Cannot
# collide with a git range.
STRIDE_NO_OWN_COMMITS="__stride_no_own_commits__"

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

  # Tracked files that differ between base and the working tree (committed,
  # staged, and unstaged changes all surface in a single `git diff <base>`).
  local tracked_files
  if [ -n "$own_ranges" ]; then
    # Union of every attributed range plus the uncommitted working tree.
    tracked_files=$( {
      expand_own_ranges "$own_ranges" "" diff --name-only
      git diff --name-only HEAD 2>/dev/null || true
    } | awk 'NF && !seen[$0]++' )
  else
    tracked_files=$(git diff --name-only "$base" 2>/dev/null || printf '')
  fi

  # Untracked files not covered by .gitignore.
  local untracked_files
  untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null || printf '')

  # Combine; dedupe by path. Untracked entries should not overlap tracked
  # (git would report a path as one OR the other, not both), but the awk
  # `!seen` guard makes a single-entry-per-path invariant explicit.
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
  local all_files
  all_files=$(printf '%s\n%s\n' "$tracked_files" "$untracked_files" \
    | awk 'NF && $0 != ".stride-diff-upload-state" && $0 != ".stride-changed-files.json" && $0 != ".stride-dirty-baseline" && $0 != ".stride.md" && $0 != ".stride_auth.md" && $0 !~ /^\.stride\// && !seen[$0]++')

  if [ -z "$all_files" ]; then
    printf '[]\n'
    return 0
  fi

  # numstat for tracked changes — used to detect binaries among tracked files
  # via the `- - <path>` marker. Untracked files are not in numstat; their
  # binary detection runs separately on file contents.
  local numstat
  if [ -n "$own_ranges" ]; then
    numstat=$( {
      expand_own_ranges "$own_ranges" "" diff --numstat
      git diff --numstat HEAD 2>/dev/null || true
    } )
  else
    numstat=$(git diff --numstat "$base" 2>/dev/null || printf '')
  fi

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
  local committed_range
  if [ -n "$own_ranges" ]; then
    committed_range=$( {
      expand_own_ranges "$own_ranges" "" diff --name-only
    } | awk 'NF && !seen[$0]++' )
  else
    committed_range=$(git diff --name-only "$base" HEAD 2>/dev/null || printf '')
  fi

  local file
  while IFS= read -r file; do
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
      if [ "$_bl_excluded" -eq 1 ] && [ -n "$committed_range" ]; then
        local _cr
        while IFS= read -r _cr; do
          if [ "$_cr" = "$file" ]; then
            _bl_excluded=0
            break
          fi
        done <<< "$committed_range"
      fi
      [ "$_bl_excluded" -eq 1 ] && continue
    fi

    # Determine whether this path is in the untracked list (membership lookup,
    # not just empty check — tracked_files and untracked_files were merged
    # above with dedupe).
    local is_untracked=0
    if [ -n "$untracked_files" ]; then
      local u
      while IFS= read -r u; do
        if [ "$u" = "$file" ]; then
          is_untracked=1
          break
        fi
      done <<< "$untracked_files"
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
    elif [ -n "$numstat" ]; then
      local nl added rest deleted path
      while IFS= read -r nl; do
        added="${nl%%	*}"
        rest="${nl#*	}"
        deleted="${rest%%	*}"
        path="${rest#*	}"
        if [ "$added" = "-" ] && [ "$deleted" = "-" ] && [ "$path" = "$file" ]; then
          is_binary=1
          break
        fi
      done <<< "$numstat"
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
      local line_count=0
      if [ -n "$diff_text" ]; then
        local _no_nl="${diff_text//$'\n'/}"
        line_count=$(( ${#diff_text} - ${#_no_nl} + 1 ))
      fi
      if [ "$line_count" -gt "$max_lines" ]; then
        local truncated
        truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
        diff_text="${truncated}
${trunc_marker}"
      fi
    fi

    jq -n --arg path "$file" --arg diff "$diff_text" '{path: $path, diff: $diff}' >> "$jsonl_file"
  done <<< "$all_files"

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
  local _paths _p _h
  _paths=$( (cd "$PROJECT_DIR" 2>/dev/null && {
    git diff --name-only "$_base" 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | awk 'NF && !seen[$0]++') || true )
  [ -n "$_paths" ] || return 0
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    if [ -f "$PROJECT_DIR/$_p" ]; then
      _h=$( (cd "$PROJECT_DIR" && git hash-object -- "$_p") 2>/dev/null || echo "unhashable")
    else
      _h="absent"
    fi
    printf '%s %s\n' "$_h" "$_p" >> "$_bl_file" 2>/dev/null || true
  done <<< "$_paths"
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
  local _tmp
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
  if ! mv -f "$_tmp" "$ENV_CACHE" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null || true
    printf 'stride-hook: could not commit an env-cache write; keeping the previous cache\n' >&2
    return 1
  fi
  return 0
}

# The per-task keys share a namespace with TASK_BASE_REF_TRUSTED and
# TASK_BASE_REF_OWNER, so an id sanitizing to either would emit a record line
# that sets the trust flag or the owner from server data. Ids are integers, so
# this is theoretical — and it costs two lines to keep it that way.
task_base_ref_key() {
  local _s
  _s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_' '_')
  case "$_s" in
    "" | TRUSTED | OWNER | UNPROVEN) return 0 ;;
  esac
  printf 'TASK_BASE_REF_%s' "$_s"
}

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
task_head_ref_key() {
  local _s
  _s=$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9_' '_')
  case "$_s" in
    "" | TRUSTED | OWNER | UNPROVEN) return 0 ;;
  esac
  printf 'TASK_HEAD_REF_%s' "$_s"
}

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
  _head=$( (cd "$PROJECT_DIR" 2>/dev/null && git rev-parse HEAD 2>/dev/null) || printf '')
  [ -n "$_head" ] || return 0
  {
    grep -v "^${_key}=" "$ENV_CACHE" 2>/dev/null || true
    printf "%s='%s'\n" "$_key" "$_head"
  } | write_env_cache || true
  return 0
}

# (D236) capture_changed_files diffs base..working-tree, so every commit made
# between an outer task's claim and its completion lands in that task's
# snapshot — including commits from tasks that claimed, worked and completed
# inside the outer task's window. Measured on W2066's sequence: claim A,
# claim+complete B and C from inside A, complete A, and A's snapshot was
# [fileB.txt, fileC.txt, outerA.txt] when only outerA.txt is A's. Dispatcher
# mode makes that routine rather than exotic.
#
# KNOWN LIMITATION, in the under-reporting direction — read this before
# "improving" the window test. A commit the OUTER task makes WHILE a nested task
# is in flight falls inside that nested task's (base, head] window, so it is
# attributed to the child and does not appear in the outer task's snapshot.
# Measured: claim A, claim B, A commits, B commits, complete B, complete A gives
# B=[nested_b, outer_during] and A=[outer_after] — A loses outer_during.
#
# This is a real trade against pre-D236 behaviour, where A over-collected but at
# least included its own commit, and the trigger is not exotic: a nested
# after_doing running `git add -A` sweeps the outer task's in-progress files
# into the nested commit, and attribution then excludes that whole commit from
# the outer. Over-reporting is the safer failure — showing extra beats losing
# real task work — so this is NOT the direction to extend the window test in.
#
# Closing it properly needs per-COMMIT ownership rather than per-window: record
# the SHAs a task's own auto-commit actually created, so a window subtracts only
# commits the nested task authored. Filed rather than bolted on here. Test 23r
# pins the current behaviour so it stays a known trade-off rather than a
# surprise.
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
    _windows="${_windows}${_b} ${_h}"$'\n'
  done <<< "$(grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' "$ENV_CACHE" 2>/dev/null || true)"

  [ -n "$_windows" ] || return 0

  # Expand every window ONCE into the set of commits it covers, then test each
  # candidate with a string lookup. The obvious implementation — two
  # `git merge-base --is-ancestor` probes per (commit x window) pair — spawns a
  # few thousand processes on a long-lived dispatcher task with the cache's
  # 20-record cap, inside a hook budget this project has already blown before
  # (and a blown after_doing budget loses the diff upload entirely).
  local _w _wb _wh _covered_set="" _c
  while IFS= read -r _w; do
    [ -n "$_w" ] || continue
    _wb="${_w%% *}"; _wh="${_w##* }"
    # `rev-list <base>..<head>` is already base-EXCLUSIVE, which is the
    # semantics this needs: a nested task's base is normally the outer task's
    # own last commit, so including it attributed the outer's work to its child
    # and silently dropped it from the outer snapshot. The interleaved fixture
    # caught that; expressing the window as a rev-list range makes it
    # structural rather than a condition someone has to keep right.
    _covered_set="${_covered_set}$(git rev-list "${_wb}..${_wh}" 2>/dev/null || true)"$'\n'
  done <<< "$_windows"

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
    if [ "${SNAP_BASE_REFUSED:-false}" = "true" ]; then
      snapshot='[]'
    else
      snapshot=$(capture_changed_files "${SNAP_BASE_RESOLVED:-}" "${SNAP_OWN_RANGES:-}" 2>/dev/null || printf '[]')
    fi
    printf '%s\n' "$snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
    # (D236) Stamp where THIS task's commits stop, so an outer task completing
    # later can subtract this window. Written after the capture so it records
    # the HEAD the snapshot was actually taken against.
    record_task_head_ref "$_tid"

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
  _preserved=$(grep -v -e '^TASK_BASE_REF=' -e '^TASK_BASE_REF_TRUSTED=' \
    -e '^TASK_BASE_REF_OWNER=' -e '^TASK_BASE_REF_UNPROVEN=' \
    -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' "$ENV_CACHE" 2>/dev/null || true)
  # The cap keeps a long-lived checkout from growing the cache without bound.
  # `tail` drops the OLDEST record, which is the outer task's — and that
  # eviction order is what makes the cap safe: an outer task that outlives the
  # cap loses its record, falls through to the shared base, finds an owner
  # stamp naming a different task, and REFUSES loudly. Degradation is to
  # no-diff, never to wrong-diff. Do not reverse this order.
  if [ -n "$_key" ]; then
    _records=$(grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' "$ENV_CACHE" 2>/dev/null \
      | grep -v -e '^TASK_BASE_REF_TRUSTED=' -e '^TASK_BASE_REF_OWNER=' \
        -e '^TASK_BASE_REF_UNPROVEN=' -e "^$_key=" \
      | tail -n 19 || true)
  else
    _records=$(grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' "$ENV_CACHE" 2>/dev/null \
      | grep -v -e '^TASK_BASE_REF_TRUSTED=' -e '^TASK_BASE_REF_OWNER=' \
        -e '^TASK_BASE_REF_UNPROVEN=' \
      | tail -n 20 || true)
  fi
  # (D226) Atomic, via the shared writer. A true race still loses one task's
  # record (last writer wins) — which degrades to a REFUSAL rather than a
  # wrong diff, since the surviving owner stamp will name someone else — but
  # no reader can observe a partial file.
  {
    [ -n "$_preserved" ] && printf '%s\n' "$_preserved"
    [ -n "$_records" ] && printf '%s\n' "$_records"
    echo "TASK_BASE_REF=$(sq_escape "$_base_ref")"
    echo "TASK_BASE_REF_TRUSTED='1'"
    if [ -n "$_owner" ]; then
      echo "TASK_BASE_REF_OWNER=$(sq_escape "$_owner")"
      echo "$_key=$(sq_escape "$_base_ref")"
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
  local _state_task="" _state_code="" _state_base=""
  if [ -f "$_state_file" ]; then
    _state_task=$(grep '^task_id=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_code=$(grep '^http_code=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_base=$(grep '^base=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
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
  if [ "$_refused" = "true" ]; then
    _snapshot='[]'
  else
    _snapshot=$( (cd "$PROJECT_DIR" && capture_changed_files "$_snap_base" "${_own_ranges:-}") 2>/dev/null || printf '[]')
  fi
  printf '%s\n' "$_snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  _http_code=$(upload_changed_files_snapshot "$_tid" "$_api_base" "$_token")
  record_diff_upload_state "$_tid" "$_http_code" "$_snap_base"
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
# escape each value, export it into the running shell (set -a), and append it
# to the env cache so follow-up agent commands (e.g. the after_goal PATCH)
# can still read the values. Keys the server omits export as empty strings.

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
extract_hook_env() {
  local _payload="$1" _name="$2"
  [ "$HAS_JQ" = "true" ] || return 0
  [ -n "$_payload" ] || return 0
  printf '%s' "$_payload" | jq -r --arg name "$_name" '
    (
      (.hooks // []) + (if (has("hook") and (.hook | type == "object")) then [.hook] else [] end)
      | map(select(type == "object" and .name == $name))
      | (first // {})
      | (.env // {})
    )
    | if type == "object" then . else {} end
    | to_entries[]
    | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    | select(.key != "HOOK_NAME" and (.key | startswith("TASK_BASE_REF") | not))
    | .key + "=" + (.value | tostring | @sh)
  ' 2>/dev/null || true
}

# Export assignment lines into the running shell and append them to the env
# cache (best-effort) so the values survive for follow-up agent commands.
# Every line is KEY='escaped-value' (see extract_hook_env / sq_escape), so
# the eval is confined to plain assignments. Appending — not rewriting — is
# deliberate: sourcing is last-wins, and a line-based rewrite would corrupt
# values with embedded newlines. The next claim truncates the cache anyway,
# bounding growth. Never echoes values to stdout/stderr (they may contain
# task descriptions or other sensitive content).
apply_env_lines() {
  local _lines="$1"
  [ -n "$_lines" ] || return 0
  set -a
  eval "$_lines" 2>/dev/null || true
  set +a
  printf '%s\n' "$_lines" >> "$ENV_CACHE" 2>/dev/null || true
}

# after_goal env: export what the server supplied, default every documented
# GOAL_* key it omitted to an empty string (defined-but-empty, never an
# error), and fall back to the completed task's parent_id from the same
# response payload when GOAL_ID itself is missing or empty. The fallback is
# response-local — the executor still never queries the API for goal state.
export_after_goal_env() {
  local _payload="$1"
  local _lines _supplied _key _parent
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
      apply_env_lines "GOAL_ID=$(sq_escape "$_parent")"
    fi
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
if [ ! -f "$STRIDE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

# Read Claude Code hook input from stdin
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
    _kept_base_records=$(grep -e '^TASK_BASE_REF_[A-Za-z0-9_]*=' "$ENV_CACHE" 2>/dev/null \
      | grep -v -e '^TASK_BASE_REF_TRUSTED=' -e '^TASK_BASE_REF_OWNER=' \
        -e '^TASK_BASE_REF_UNPROVEN=' \
      | tail -n 20 || true)
    # (D236) The per-task HEAD records have to survive this rewrite for exactly
    # the same reason the base records do — and they are useless without their
    # partner. A base says where a nested task started, the head says where it
    # stopped, and attribution needs BOTH: with only the base the window is
    # unbounded and the nested task's commits cannot be told apart from the
    # outer task's own later ones. Dropping these here is precisely how the
    # first version of this fix silently reverted to over-collecting — every
    # subsequent claim erased the record the previous completion had just
    # written.
    _kept_head_records=$(grep -e '^TASK_HEAD_REF_[A-Za-z0-9_]*=' "$ENV_CACHE" 2>/dev/null \
      | tail -n 20 || true)
    # Values are single-quote escaped via sq_escape (W1453) so titles with
    # spaces, quotes, or dollar signs survive the `set -a` sourcing without
    # any shell interpretation.
    {
      [ -n "$_kept_base_records" ] && printf '%s\n' "$_kept_base_records"
      [ -n "$_kept_head_records" ] && printf '%s\n' "$_kept_head_records"
      echo "TASK_ID=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.id // empty')")"
      echo "TASK_IDENTIFIER=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.identifier // empty')")"
      echo "TASK_TITLE=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.title // empty')")"
      echo "TASK_STATUS=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.status // empty')")"
      echo "TASK_COMPLEXITY=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.complexity // empty')")"
      echo "TASK_PRIORITY=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.priority // empty')")"
    } | write_env_cache || true
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
    _preserved=$(grep -v -e '^TASK_BASE_REF=' -e '^TASK_BASE_REF_TRUSTED=' \
      -e '^TASK_BASE_REF_OWNER=' -e '^TASK_BASE_REF_UNPROVEN=' "$ENV_CACHE" 2>/dev/null || true)
    if [ -n "$_preserved" ]; then
      printf '%s\n' "$_preserved" | write_env_cache || true
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
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  set -a
  . "$ENV_CACHE" 2>/dev/null || true
  set +a
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
