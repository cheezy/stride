# Releasing the Stride plugin

A release of this plugin lands in two repositories: this one (manifest,
changelog, tag, GitHub release) and the `stride-marketplace` catalog, which is
what Claude Code reads to discover the new version. This file records what the
history of this repository shows; where that history is mixed, it says so
rather than picking a rule for you.

## The three facts

**Where the version lives.** `.claude-plugin/plugin.json` (`"version"`). It
is the only file that carries the release version — README "(vX.Y.Z+)" notes
are feature markers, not version carriers — and no test or script checks it
against the changelog. Keeping the manifest and the changelog's top heading in
step is a manual check (see the steps).

**Changelog shape: mixed, and the history does not settle it.** Both shapes
appear in the recent record, sometimes back to back:

- **A work commit opens the heading.** Several recent versions (1.73.0,
  1.74.0, 1.76.0, 1.77.0) had their heading written by the work commit that
  delivered the change. The release commit then finished the job — for
  1.77.0 by bumping `plugin.json` and nothing else, for 1.73.0 by dating a
  heading the work commit had opened as `- unreleased`. 1.79.0 went further:
  its work commit opened the heading **and** bumped `plugin.json` in lockstep,
  and that version has not been tagged yet.
- **Work appends under `[Unreleased]`, the release stamps it.** Other cycles
  accumulated entries under `## [Unreleased]`, and the release commit renamed
  it (1.78.0) or wrote the heading itself (1.75.0).

Either is consistent with the record. What is not consistent with it is
adding entries under a heading that has already been tagged.

**Catalog: `stride-marketplace`.** The catalog lists this plugin as a URL
source with a `version` field (`.claude-plugin/marketplace.json`), and that
field is what users are offered. A plugin release is therefore unfinished
until the catalog is updated. The catalog documents its own ritual in the
"Releases and tagging" section of its README, and that section is
authoritative: one catalog release is one commit that bumps the plugin's
version and description, bumps the catalog's `metadata.version`, syncs the
README table row and prose, and adds a catalog changelog entry — then a
catalog tag and GitHub release under the catalog's own number, which does not
mirror this plugin's version.

## Before you add to the changelog: is the top heading already tagged?

```bash
git tag -l "v$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n 1)"
```

Any output means the newest numbered heading has shipped: do not add to it —
open `## [Unreleased]` above it, or the next numbered heading. No output means
the newest heading is not yet tagged, so it is still the open release and work
can land under it. (The "Release record" section at the top of the changelog
is not a version heading; the command skips it.) The lite ports learned this
the hard way — entries appended under an already-released heading had to be
moved to a new one.

The same check is how you spot a version that was bumped but never tagged:
if `plugin.json` already carries a version whose heading prints nothing here,
that version is waiting for its tag, and every commit after it still needs
an entry before the release.

## Steps

1. Run the gates in this repository (the full hook suite is slow — budget for
   it):

   ```bash
   bash hooks/test-stride-hook.sh
   pwsh -File hooks/test-stride-hook.ps1
   bash hooks/test-stride-skill-gate.sh
   bash scripts/check-skill-budgets.sh
   bash scripts/check-ps1-compat.sh
   bash scripts/check-port-canon.sh
   ```

   The fleet drift check (`check-port-canon.sh`) is a release gate for every
   port and catalog, not just this repository. Its exit codes are documented
   in the script's own `EXIT CODES` header, and the "Release gate" section of
   `docs/port-canon.md` asks that a non-zero result be read as blocking.

2. Run the top-heading check. Make sure every commit since the last tag
   (`git log --oneline "$(git describe --tags --abbrev=0)"..HEAD`) has an
   entry, that the top numbered heading is the version you are releasing, and
   that `.claude-plugin/plugin.json` says the same version. Commit whatever
   that took on `main` — recent release commits are titled
   `Release X.Y.Z: <what it closes>` — and push.

3. Tag the commit whose `plugin.json` carries the version, and push the tag.
   Every version gets its own tag, so a batch of versions means a batch of
   tags, each on its own commit (`git show <sha>:.claude-plugin/plugin.json`
   tells you which commit carries which version):

   ```bash
   git tag -a vX.Y.Z <sha> -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

4. Publish a GitHub release per tag, with notes taken from that version's
   changelog section:

   ```bash
   gh release create vX.Y.Z --repo cheezy/stride --notes-file <notes.md>
   ```

5. Update `stride-marketplace` per its README's "Releases and tagging"
   section, then tag and release the catalog.

## Known gaps on the record

- Six older tags have no GitHub release; the gap is accepted and recorded at
  the top of `CHANGELOG.md`. Do not backfill. Every new tag gets a release.
- Tags are a mix of annotated and lightweight. Prefer annotated.
