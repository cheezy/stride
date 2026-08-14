# When Hooks Fail

Read this only when `after_doing` or `before_review` returns non-zero. The Iron Law — never call the complete endpoint on a failed hook — stays in SKILL.md; this file is the remediation procedure.

## Diagnostician-Assisted Debugging (Claude Code Only)

When a blocking hook fails, dispatch the `stride:hook-diagnostician` agent **as the first step** before attempting manual fixes. The diagnostician parses the raw output, categorizes issues by severity, and returns a prioritized fix plan — saving time on complex multi-tool failures.

**When to dispatch:** Any blocking hook failure (after_doing or before_review) where exit_code is non-zero.

**What to provide the diagnostician:**
- `hook_name`: The hook that failed (e.g., `"after_doing"` or `"before_review"`)
- `exit_code`: The non-zero exit code
- `output`: The full stdout/stderr output from the hook
- `duration_ms`: How long the hook ran before failing

**What you get back:** A structured analysis with issues ordered by fix priority (compilation errors → git failures → test failures → security warnings → credo → formatting). Follow the diagnostician's fix order — fixing higher-priority issues often resolves lower-priority ones automatically.

**Fallback for non-Claude Code environments:** If you don't have access to the Agent tool (Cursor, Windsurf, Continue, etc.), skip the diagnostician and proceed directly to manual debugging using the steps below.

## If after_doing fails:

1. **DO NOT** call complete endpoint
2. **[Claude Code Only]** Dispatch `stride:hook-diagnostician` with the hook name, exit code, output, and duration
3. Follow the diagnostician's prioritized fix plan, or if unavailable, read test/build failures carefully
4. Fix the failing tests or build issues
5. Re-run after_doing hook to verify fix
6. Only call complete endpoint after success

**Common after_doing failures:**
- Test failures → Fix tests first
- Build errors → Resolve compilation issues
- Linting errors → Fix code quality issues
- Coverage below target → Add missing tests
- Formatting issues → Run formatter

## If before_review fails:

1. **DO NOT** call complete endpoint
2. **[Claude Code Only]** Dispatch `stride:hook-diagnostician` with the hook name, exit code, output, and duration
3. Follow the diagnostician's fix plan, or if unavailable, fix the issue manually
4. Re-run before_review hook to verify
5. Only proceed after success

**Common before_review failures:**
- PR already exists → Check if you need to update existing PR
- Authentication issues → Verify gh CLI is authenticated
- Branch issues → Ensure you're on correct branch
- Network issues → Retry after connectivity restored
