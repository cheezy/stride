# D288 — how the bash env-cache record writers filter, and why

**Status:** decided and implemented. **Decision: harden, at both the source and the sink.**

## The defect

Every bash record writer had the shape

```sh
{ grep -v "^KEY=" "$ENV_CACHE"; printf "KEY=new\n"; } | write_env_cache
```

`write_env_cache` is a staging `cat` plus `mv`, so it faithfully commits whatever
reaches its stdin. A `grep` that declines to read the cache therefore leaves a
cache holding only the line the writer was adding. Every unrelated record — the
window anchors attribution depends on, `GOAL_*`, `BOARD_*`, `TASK_DESCRIPTION` —
is lost silently, at exit 0.

This is reachable. D281's PowerShell fix preserves invalid bytes that used to be
scrubbed to U+FFFD on the next ps1 write, so a cache carrying a byte >= 0x80 now
persists instead of self-healing, and some contributors have ugrep first on PATH.

## What was measured

Fixture: a 3-record cache, one record's value holding byte 0xE9. Command:
`grep -v "^TASK_ID=" <cache>` — the shape the writers used.

| implementation | LC_ALL | rc | bytes out | invalid byte | records kept | verdict |
|---|---|---|---|---|---|---|
| /usr/bin/grep — BSD grep 2.6.0-FreeBSD | C | 0 | 66 | survives | 2 | safe |
| /usr/bin/grep — BSD grep 2.6.0-FreeBSD | en_US.UTF-8 | 0 | 66 | survives | 2 | safe |
| ugrep 7.8.4, `-I` | C | 1 | 0 | — | 0 | **refuses, silent** |
| ugrep 7.8.4, `-I` | en_US.UTF-8 | 1 | 0 | — | 0 | **refuses, silent** |
| ugrep 7.8.4, default | C | 0 | 89 | — | 0 | **refuses, notice on stdout** |
| ugrep 7.8.4, default | en_US.UTF-8 | 0 | 89 | — | 0 | **refuses, notice on stdout** |
| ugrep 7.8.4, `-a` | either | 0 | 66 | survives | 2 | safe |

Locale changed nothing in any row. That is the empirical form of the task's first
pitfall: binary detection here is an implementation behaviour, not a locale one.

**The refusal is not always silent, and that is the finding that shaped the fix.**
ugrep's *default* prints

```
Binary file /path/to/.stride-env-cache matches
```

to **stdout**, at **exit 0**. Piped into `write_env_cache`, that commits a cache
whose whole content is one line of English prose plus the new record — and
embeds the cache's own path in it.

### A second measurement, taken after the first fix attempt

awk is immune to grep's binary refusal. Its **regex engine is not immune to the
same byte**:

| awk form | LC_ALL=C | a UTF-8 locale |
|---|---|---|
| `awk '/^AGENT_NAME=/ {next} {print}'` | rc 0, 2 lines | **rc 2, no output** — `awk: towc: multibyte conversion failure` |
| `awk 'substr($0,1,11) != "AGENT_NAME="'` | rc 0, 2 lines | rc 0, 2 lines |

A developer machine's ambient locale is a UTF-8 one. Swapping grep for a *regex*
awk would have reproduced the defect exactly — same empty stdout, same swallowed
exit code, new tool.

**The precise rule, stated precisely because an absolute here would be wrong:**
no cache filter matches a regex against `$0` or against a value. Matching is
done with `index`/`substr` on the ASCII key before the first `=`. A regex
applied to that *already-extracted* key is safe and two filters legitimately do
it — the family test in `cache_window_record_lines` and the loader's charset gate,
both of which need a regex to say what a well-formed key is. Verified rather
than assumed:

```sh
awk '{ if (index($0,"=")>1) { key=substr($0,1,index($0,"=")-1);
       if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/) printf "%s,", key } }' <cache>
```

returns every key, rc 0, under both `LC_ALL=C` and a UTF-8 locale, on a cache
holding a byte >= 0x80 — because the subject of the match is the ASCII key, not
the line. It is the subject that has to be clean, not the tool.

## The decision

**Harden.** Test 7ii detects the failure, but only for someone who runs the bash
suite; a contributor whose grep refuses and who never runs it still loses records.
A detector is not a guard.

**At the source** — the five write-side filters, and the one reader in the
record path, no longer call grep:

- `record_task_head_ref`, `record_task_owned`, `record_task_narrowed` → `drop_cache_key`
- `finalize_before_doing`'s preserved set → `drop_task_window_records`
- the claim block's fallback preserved set → `drop_shared_base_records`
- `read_task_record`'s single-record lookup → an inline shape-checking awk
- the claim block's PRIMARY preserved-set filter and the `after_goal` GOAL_*
  collapse filter → the same `key_of` matching, so no cache filter anywhere
  matches with a regex

The last of these mattered more than its "fallback" status suggests: an empty
result there does not commit a short cache, it takes the `else` branch and
**deletes** the cache.

**At the sink** — `write_env_cache` gained two gates:

- a **shape gate**, unconditional: refuse a stream carrying a top-level line that
  does not begin a record, or ending inside an unterminated value. This is what
  catches the notice mode, which no emptiness test can catch. It is quote-aware,
  so the multi-line values the live cache really does carry (`TASK_DESCRIPTION` is
  a paragraph) pass untouched, and it is not steerable by cache content, because
  every value is `sq_escape`'d into single quotes where the gate does not look.
- a **count gate**, opt-in via `--preserve-from-cache`: refuse a write leaving
  fewer than (previous − 1) records. Opt-in because only the single-key record
  writers have that invariant; the rebuild sites legitimately shrink the cache
  (window eviction, the preserved-only fallback) and must not be held to it.

Both refuse by keeping the previous cache and warning on stderr, non-fatally —
the direction `Write-EnvCache` already fails in, and the direction the task's
first security consideration requires.

## Options rejected

- **`LC_ALL=C`** — does not address what was measured. It would not stop a
  refusing grep refusing. (It *would* make awk's regex byte-safe, but
  `index`/`substr` needs no locale assumption at all, which is stronger.)
- **`grep -a`** — not POSIX, and adopting it at five sites is a portability trade
  needing cross-host evidence this task does not have.
- **A sink guard that only refuses an empty stream** — the remedy this task was
  filed proposing. It does not survive the notice mode: 89 bytes is not empty.
- **Refusing every empty stream** — a cache legitimately becomes empty, and
  refusing that would strand a stale cache forever.

## Coverage, and what is still unmeasured

7ii now runs its five properties three times: against the host grep, and against a
refusing grep in **both** measured shapes, installed as a PATH stub. Before this
change the same fixture went from 4 records to 1 under either shim; after it, 4
records with the invalid byte intact under both.

**GNU grep on Linux remains unmeasured.** Docker's daemon was not running on the
machine this was done on and no GNU grep was installed. It is named here rather
than assumed — but it is **no longer load-bearing for these five sites**, because
none of them calls grep any more. It would still matter to anyone reintroducing a
grep into a cache filter, which is the reason to keep the row empty rather than
quietly drop the question.

## Two corrections the security review forced, recorded because the first
## draft of this document got them wrong

**The reader was not safe to leave alone.** This document first claimed the
`^KEY='...'$` lookup in `read_task_record` "degrades to a no-op rather than to
data loss" and left it as a grep. That is true of the silent refusal shape and
false of the notice shape: ugrep's default returns `Binary file <path> matches`
on stdout at exit 0, a line with no `=`, so the old strips were all no-ops and
the function handed that English diagnostic back to its callers **as the
record's value** — which reaches attribution and is re-written into the cache.
It now uses awk and checks the shape explicitly (starts `KEY='`, ends `'`, no
quote between) instead of trusting an anchored pattern.

**Propagating the filter's status is part of the fix, not a detail.** The first
implementation gave every new filter `2>/dev/null || true`, so a filter that
could not read the cache returned an empty string at exit 0 — indistinguishable
from a cache that genuinely holds nothing else. At the two rebuild sites, which
are deliberately outside the count gate, that would have committed a cache
missing `GOAL_*`, `BOARD_*` and `TASK_DESCRIPTION`, silently, at exit 0: the
D288 shape exactly, one tool along. The filters now propagate awk's status,
`finalize_before_doing` routes a failure into its existing `_rebuild_ok`
sentinel ("the previous cache stands, untouched"), and the claim block only
reaches its `rm -f "$ENV_CACHE"` when the filter **ran** and found nothing.

The general lesson is the one worth keeping: removing the tool that refuses does
not remove the structure that misreads a refusal as an answer. Both had to go.

**And propagating a status is not free either.** The first version of that
propagation treated an ABSENT cache as a filter failure, so a fresh checkout —
which has no cache at all — set `_rebuild_ok=0` and skipped the very rebuild a
claim exists to perform. Three existing cases (14h, 18g, 23l) caught it
immediately. The filters now return cleanly on a missing file and propagate only
when the cache EXISTS and could not be read, which is the distinction that was
wanted in the first place.

## Which greps survive, and why each is left alone

Stated precisely, because the first draft of this document said "one reader" and
that was wrong on both the count and the name.

No grep reads or writes the cache FILE any more — verified with an awk sweep
that joins backslash-continued lines and reports any `grep` invocation
mentioning `$ENV_CACHE`, which now returns nothing:

```sh
awk '/grep /{s=NR; b=$0; while (b ~ /\\$/ && (getline l)>0) b=b" "l;
             if (b ~ /ENV_CACHE/) print s": "b}' hooks/stride-hook.sh
```

**Eight** greps do still run on cache-DERIVED content, in **four** functions:
four in `select_kept_window_records`, one in `another_open_window_exists`, one
in `attributed_commit_ranges`, and two in `finalize_before_doing`. None of them
opens the cache. They filter strings already in hand — the output of
`cache_window_record_lines`, or the `_records` / `_at_lines` sets — and that
content is the shape-filtered window-record subset: quoted hex refs,
space-joined hex, ids, timestamps and `yes`/`no`. It cannot contain a byte
>= 0x80, so a binary refusal cannot fire on it, and the unconditional shape gate
would refuse a notice line at the sink in any case. Changing them would buy
nothing and churn eight working filters.

`select_kept_window_records` earns its explicit mention: its output is written
back into the cache, which is the one property this inventory's safety argument
is actually about.

(This section has been wrong twice. A first draft said "one reader". A second
said four greps in three functions and *retracted* the mention of
`select_kept_window_records` — but the retraction was the error, not the
original. The count above is what the sweep returns; it is recorded this way so
the next person can re-run the sweep rather than trust the prose.)

## Two operational notes

**awk is now load-bearing for every cache write.** The shape gate runs on every
`write_env_cache`, so on a host with no awk at all the failure mode is no longer
"writes work via grep" but "no cache write succeeds" — refused, warned on
stderr, previous cache kept. That is the fail-closed direction and awk is POSIX
and already load-bearing since D287, but it is a real cliff and it belongs in
writing rather than in someone's incident notes.

**A cache the scanner cannot balance refuses writes until it is removed.** The
shape gate has no repair path: an unbalanced legacy cache (written by a
pre-D275/pre-D287 hook) is kept, and every subsequent record write is refused.
No writer this version has can produce one — every value goes through
`sq_escape` or jq `@sh`, the staging `cat` status is checked, and the commit is
an atomic `mv` — so the trigger is historical, not reachable from here. The
refusal message names the cache path and says to remove that file, because the
operator-visible symptom (attribution quietly refusing on every task) does not
otherwise point at the cache.

**Refused writes are not only record writes**, and this is the part an operator
would otherwise be surprised by. The claim block's strip of
`TASK_BASE_REF`/`_TRUSTED`/`_OWNER` also goes through `write_env_cache`, so on
an unbalanced legacy cache that strip is refused too and the PREVIOUS window's
shared base survives the claim. That is new: before the shape gate became
unconditional, that write committed. It degrades to an attribution refusal via
the owner stamp rather than to a wrong diff — the safe direction — but "the
stale base was left behind" is a different symptom from "the write was refused",
and both follow from the same unbalanced file.
