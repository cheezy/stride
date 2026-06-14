# Stride Plugin — Community Directory Submission Audit

Baseline audit for submitting the **stride** plugin to the Anthropic community
plugin directory. Produced by task **W1128** (goal **G234**). This document
**captures and classifies** findings only — it does not fix them. Each finding
names the downstream task that resolves it.

## Environment

- **Validator:** `claude plugin validate` from Claude Code `2.1.177`
- **Plugin source:** `stride/.claude-plugin/plugin.json` (repo `github.com/cheezy/stride`, v1.28.0)
- **Marketplace source:** `stride-marketplace/.claude-plugin/marketplace.json` (repo `github.com/cheezy/stride-marketplace`, v1.41.0) — local source clone, not the `~/.claude/plugins` cache
- **Date:** 2026-06-14

## Validator results (the hard gate)

| Target | Command | Result |
|--------|---------|--------|
| Plugin manifest | `claude plugin validate --strict stride/` | ✅ **Validation passed** (exit 0) |
| Plugin manifest | `claude plugin validate stride/` (non-strict) | ✅ Validation passed (exit 0) |
| Marketplace manifest | `claude plugin validate --strict stride-marketplace/` | ✅ **Validation passed** (exit 0) |

**Zero validator errors and zero `--strict` warnings.** Both manifests are
structurally valid, all referenced fields are recognized, and no unknown fields
were flagged. This is the clean baseline; downstream tasks must not regress it.

## Triaged findings (manual completeness review)

The validator passing means the manifests are *structurally* correct — not that
they are *directory-optimal*. The items below are completeness / discovery /
trust observations gathered by inspecting the manifests and repo against the
submission bar. None are validator errors.

| # | Finding | Severity | Classification | Resolved by |
|---|---------|----------|----------------|-------------|
| 1 | `plugin.json` has no `author.url` field. Present: name, description, version, author{name,email}, homepage, repository, license, keywords. | low | **fix-now** | W1129 |
| 2 | `description` is accurate but reads as a feature list, not a one-line catalog blurb. | low | **fix-now** (tune) | W1129 |
| 3 | The marketplace entry's `plugins[].description` is an enormous changelog-style paragraph (thousands of chars of release notes). As a catalog blurb this is unreadable. | medium | **fix-now** (separate `stride-marketplace` repo, out of this goal's plugin scope) | flagged for follow-up — see Notes |
| 4 | No `SECURITY.md` / reviewer-facing security doc exists; the client-side hook-execution + bearer-token model is undocumented for a safety reviewer. | high | **fix-now** | W1131 |
| 5 | README install section only documents the custom-marketplace path (`/plugin marketplace add cheezy/stride-marketplace`); no community-directory install path, prerequisites, component inventory, or security pointer. | medium | **fix-now** | W1132 |
| 6 | Credential hygiene (no bundled secrets, hooks read creds from user-local files/env only) is asserted but not yet verified end-to-end. | high | **fix-now** | W1130 |

## Security-relevant notes (forwarded to W1131)

Per this task's `security_considerations`, anything touching credential handling
or hook execution is flagged here for the security-doc task:

- `hooks.json` wires `stride-hook.sh` into **PostToolUse** and **PreToolUse**
  (matcher `Bash`, 300s timeout) and `stride-skill-gate.sh` into **PreToolUse**
  (matcher `Skill`, 10s timeout). All commands run on the user's machine via
  `${CLAUDE_PLUGIN_ROOT}`. This is the plugin's defining risk surface and must
  be described accurately in the W1131 security doc.
- No secret material was observed in either manifest (findings #1–#6 are all
  non-secret). The full credential-hygiene sweep is W1130's deliverable.

## Notes / out-of-scope follow-ups

- **Finding #3** lives in the separate `cheezy/stride-marketplace` repo, not the
  `stride` plugin repo this goal targets. It is recorded here so it isn't lost,
  but trimming the marketplace blurb is outside G234's plugin scope — raise it as
  a separate marketplace-repo task before the listing goes live.
- No real tokens, `.stride_auth.md`, or `.env` content appears in this audit, per
  the task's security constraint.

## Credential-hygiene audit (W1130) — ALL CLEAR

Full sweep of the `stride/` plugin repo for bundled secrets and credential
handling. **No leak found; no rotation or history remediation required.**

| Check | Method | Result |
|-------|--------|--------|
| No secret files tracked | `git ls-files \| grep -Ei 'auth\|secret\|token\|\.env\|\.pem\|\.key'` | ✅ none tracked |
| No hardcoded credentials | `grep -RInE 'stride_(dev\|prod)_…\|Bearer …' hooks skills commands agents` | ✅ only an obvious `Bearer token123` **test placeholder** against `example.com` in `hooks/test-stride-hook.sh` — not a real credential |
| No real token in history | `git log --all -S 'stride_dev_'` | ✅ no commit ever added/removed a `stride_dev_` literal |
| Hook tests pass clean | `bash test-stride-hook.sh` / `test-stride-skill-gate.sh` | ✅ 237/237 and 16/16 passed |
| User docs warn against committing creds | `README.md` § `.stride_auth.md` | ✅ states "never commit this file"; token shown as `your-token-here` placeholder |

### Credential-sourcing model (verified in `hooks/stride-hook.sh`)

The token and API base URL are resolved at runtime from **user-local sources
only** — never hardcoded:

1. **Primary:** `$PROJECT_DIR/.stride_auth.md` — deliberately the prod
   `**API Token:**` line, explicitly **not** the `**Local API Token:**` line.
2. **Fallback:** the `Bearer <token>` value parsed out of the intercepted
   completion `curl` command (`$COMMAND`).
3. **Env override:** `$STRIDE_API_URL` / `$STRIDE_API_TOKEN`.

`hooks/stride-skill-gate.sh` has **zero** credential handling — it is purely the
orchestrator-marker gate (no token, no network calls).

### Least privilege & external dependency

The hooks call only the Stride **task-lifecycle** endpoints
(`/api/tasks/claim`, `/api/tasks/:id/complete`, `/mark_reviewed`,
`/api/tasks/:id/changed_files`) against the single external dependency
**`stridelikeaboss.com`**. No broader scope is requested. These facts are
forwarded to the W1131 security document.

**W1130 verdict:** credential hygiene is clean. Audit findings #1 and #2 were
resolved by W1129; finding #6 (this sweep) is now closed with no remediation
needed.

## Baseline conclusion

The submission's **hard validation gate is already green.** The remaining work in
G234 is completeness and trust: manifest polish (W1129), credential-hygiene
verification (W1130), the reviewer security doc (W1131), and a directory-ready
README (W1132) — consolidated by the readiness checklist (W1133).
