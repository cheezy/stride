# Community Directory Submission — Readiness Checklist

Go/no-go package for submitting the **stride** plugin to the Anthropic community
plugin directory. Produced by task **W1133**, the final task of goal **G234**.
**This package stops at ready-to-submit — it does NOT submit the form.**

- **Date:** 2026-06-14
- **Plugin:** `stride` v1.28.0
- **Public repo:** <https://github.com/cheezy/stride>
- **Marketplace (today's install path):** `cheezy/stride-marketplace`

## Prior-task status (G234)

| Task | Produced | State |
|------|----------|-------|
| **W1128** | `SUBMISSION-AUDIT.md` — baseline validation + triaged findings | ✅ Done |
| **W1129** | `plugin.json` completed (author.url, catalog-blurb description, broadened keywords) | ✅ Done |
| **W1130** | Credential-hygiene sweep — **all clear**, appended to the audit | ✅ Done |
| **W1131** | `SECURITY.md` — reviewer-facing hook-execution + token-auth model; README-linked | ✅ Done |
| **W1132** | `README.md` made self-contained (install paths, prerequisites, component inventory, external-service note) | ✅ Done |
| **W1133** | This readiness checklist | ✅ (this doc) |

## Hard validation gate (fresh run)

```
$ claude plugin validate --strict stride/
Validating plugin manifest: .../stride/.claude-plugin/plugin.json
✔ Validation passed        (exit 0)
```

Validator: Claude Code 2.1.177. The marketplace manifest
(`stride-marketplace/.claude-plugin/marketplace.json`) also passes `--strict`
(recorded in `SUBMISSION-AUDIT.md`).

## Submission package contents

- **Security doc:** [`SECURITY.md`](SECURITY.md) — trust boundary, hook lifecycle, single `changed_files` PUT, token handling, skill gate, `.ps1` parity.
- **Listing storefront:** [`README.md`](README.md) — self-contained: both install paths, prerequisites, component inventory, external-service disclosure, security link.
- **Audit trail:** [`SUBMISSION-AUDIT.md`](SUBMISSION-AUDIT.md) — validator results + credential-hygiene all-clear.
- **Manifest:** [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) — `name: stride`, `version: 1.28.0`, MIT, author + url, homepage/repository → public repo.

## Where to submit (this author)

The account on file (`cheezy@letstango.ca`) is an **individual author**, so the
Console submission path applies (not the claude.ai Teams/Enterprise admin
directory path).

| Author type | Submission entry point |
|-------------|------------------------|
| **Individual author (this case)** | Console plugin submission — `platform.claude.com/plugins/submit` |
| Teams / Enterprise | claude.ai admin directory — `claude.ai/admin-settings/directory/submissions/plugins/new` |

> ✅ **Verified.** The individual-author Console path
> (`platform.claude.com/plugins/submit`) has been confirmed against the live
> page and is the correct submission entry point.

## Open follow-ups before clicking submit

1. **✅ RESOLVED — plugin repo pushed.** The 5 G234 commits (`f3b5860`,
   `5ffe5aa`, `5386de2`, `bf058c4`, `0ac311c`) are now on `origin/main` at
   `github.com/cheezy/stride` (verified: local `main` is 0 ahead / 0 behind after
   a fresh fetch). The marketplace pin has also advanced to **stride 1.30.0**
   (commit `ffab240`).
2. **✅ RESOLVED — marketplace blurb trimmed.** The `plugins[].description` for
   `stride` in `cheezy/stride-marketplace` is now a clean one-line catalog blurb
   (commit `5212c3a`, pushed): *"Drive the full Stride kanban task lifecycle from
   Claude Code — claiming, completing, creating and enriching tasks and goals,
   workflow orchestration, subagent dispatch, and automatic lifecycle hook
   execution."*
3. **✅ RESOLVED — submission URL confirmed.** The individual-author Console
   path (`platform.claude.com/plugins/submit`) has been verified against the live
   page and is the correct submission entry point.

## Credential rotation

**Not required.** The W1130 credential-hygiene sweep found no tracked secrets,
no hardcoded credentials, and no token literal in git history. No rotation
blocks this submission.

## Go / No-Go

**Validation, manifest, security doc, README, and credential hygiene are all
GREEN.** All three operational follow-ups are now resolved: the plugin repo is
pushed public (item 1), the marketplace blurb is trimmed (item 2), and the
submission URL is confirmed (item 3). **No blockers remain — the package is
ready to submit.**

**This goal ends here. The submission form is intentionally NOT submitted** —
that is the user's call.
