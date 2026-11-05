# Step 5.5 replay of G489 at its pre-campaign commit (W2588)

Measured 2026-11-05 UTC. This measurement shows what the Step 5.5 procedure in
stride v1.87.0 and stride-exploratory-testing v0.5.0 finds when it is replayed
against the attachments board UI goal G489 (W2510–W2515). The code under test
is `538aebc8`, the parent of `930cbbec`, which is the first fix of the
exploratory campaign that followed the goal.

**Read the comparator before any number.** The reference list is the 29 bugs
of the G489 exploratory campaign: the 27 in its debrief plus the 2 HEAD findings
of its follow-up charter. That campaign ran 17 charters after the goal was done, on the local dev host:
its probes were throwaway ExUnit files in `MIX_ENV=test`, and it also had the
running dev server for live checks and the Tidewave browser for the visual pass. The replay ran 14 sessions with no
server, no browser and only an in-process probe harness. The comparator is a
bug list, not an effort baseline: it says which bugs existed, not what a fair
session should have found. Counts are given per severity and per cause. No
single headline percentage is quoted. With one goal and 14 sessions, every
figure here is an observation, not an estimate.

**This is not a run of the installed plugins.** The plugin cache held stride
1.86.0 and stride-exploratory-testing 0.4.0, and the user was remote and could
not update it. Every charter-generator and explorer session was a
general-purpose agent. It was told to read
`stride-exploratory-testing/agents/charter-generator.md` or
`agents/explorer.md` (v0.5.0) by absolute path as its own agent definition and
to follow it exactly. It was also limited in words to that file's `tools:`
line. The Step 5.5 procedure, the goal-scope pass included, was followed from
`stride/skills/stride-workflow/optional-exploratory-testing.md` (v1.87.0),
read by path.

## The runs

| | Replay | Comparator (G489 campaign) |
|---|---|---|
| Tasks | W2510–W2515, each replayed through Step 5.5, plus the goal-scope pass for W2515 as the last open child | the whole goal after it shipped |
| Code under test | `538aebc8` in a throwaway git worktree, for every task | the same tree, then each fix as it landed |
| Per-task change set | `git diff <c>^ <c>` of each task's one commit: `7e2fb43b`, `59773a19`, `543f9040`, `8945caf1`, `ae02b333`, `538aebc8` | not applicable |
| Plugins | stride **1.87.0** and stride-exploratory-testing **0.5.0**, released source read by path (not installed; see above) | the installed plugins of 2026-11-02 |
| Model | `claude-opus-5-5` for the main loop; every dispatched agent inherits it | `claude-opus-5-5` |
| How dispatched | general-purpose agents, each told to follow one agent file and limited to its tools. The explorer dispatch is the fixed Step 5.5 template, filled by script from `.exploratory.md` and written to a file the agent read as its prompt | hand-run campaign charters, one session per charter |
| Charter source | 6 change-mode charter-generator calls (one per task) plus 1 goal-scope call, merged with each task's `manual_tests` | 17 human-framed charters |
| Surface | probe harness only: `mix test` on a scratch file, `MIX_ENV=test`, the local test database. No server, no browser | throwaway ExUnit probes in `MIX_ENV=test`, plus the running dev server for live checks and the Tidewave browser for the visual pass |
| Budget | 12 probes / 60 tool calls per session, the default | about 12 probes per charter |
| Sessions | 14 explorer dispatches (`r1`–`r14`), and 17 capped-in charters not dispatched (`u1`–`u17`) | 17 |
| Dates | 2026-11-05, all on one machine, up to 12 sessions in parallel | 2026-11-02 |

**Replay order, compressed.** The six change-mode charter-generator calls ran in
parallel, and so did the goal-scope call. Twelve explorer sessions then ran in
one parallel batch. The two goal-scope sessions went out only after W2515's own
three had returned, which is the order the procedure requires. Every probe ran
inside its own sandboxed test transaction, so no session could see another's
data. Running them in parallel changed only the wall clock. No figure below is
a time comparison.

## Charters: generated, capped, dispatched

Each charter-generator call returned 11–15 charters ranked by risk; the
goal-scope call returned 6. Step 1c caps a task at about five charters (about
three for a small one) and keeps the highest-risk. Then it records, without
dispatching, every generator charter whose `surface` is `browser`, because the
explorer's `tools:` line names no browser.

| Task | Complexity | Generated | Capped in | Of those, `browser` | Dispatched | Sessions |
|---|---|---|---|---|---|---|
| W2510 | medium | 12 | 5 | 0 | 5 | `r4`–`r8` |
| W2511 | medium | 15 | 5 | 4 | 1 | `r1` |
| W2512 | small | 13 | 3 | 3 | 0 | none |
| W2513 | medium | 14 | 5 | 3 | 2 | `r2`, `r3` |
| W2514 | medium | 13 | 5 | 5 | 1 (rank 2, dispatched because a mixed manual test merged into it) | `r9` |
| W2515 | small | 11 | 3 | 0 | 3 | `r10`–`r12` |
| G489 goal-scope | — | 6 | 5 | 3 | 2 | `r13`, `r14` |
| **Total** | | **84** | **31** | **18** | **14** | |

Every manual test merged into a charter, and every edge case mapped to a
charter or to a named unit test. None was silently dropped. A charter beyond
the cap, or a capped-in `browser` charter, is recorded as a human
responsibility. That is what the procedure prescribes.

**The browser rule is where most of the capped coverage went.** Of the 31
capped-in charters, 18 were tagged `browser`. Most of them describe LiveView
state that the probe harness can drive with `Phoenix.LiveViewTest`: count
limits, stale views after a remote delete, staging after a failed save. The
generator tags a charter `browser` when a person would test it in one. Step 1c
reads the tag as "needs a rendered view" and does not dispatch it. W2512 and
the four browser-tagged charters of W2514 never reached a session. This is
named as a new miss cause, C10, below.

## Sessions

`EXPLORATORY_REPORT_PATH` for every session was
`.stride/.exploratory-W2588-r<N>.json` in the kanban checkout. Probes counts and
endings are copied from each report's `session_sheet`.

| Session | Task | Charter (generator rank, surface) | Probes | Tool calls | `stop_reason` | Bugs (H / M / m) | Campaign bugs matched |
|---|---|---|---|---|---|---|---|
| `r1` | W2511 | 1, harness; merged with both manual tests | 9 of 12 | 25 | `no_observation_surface` | 0 / 1 / 0 | none (partials M1, M3) |
| `r2` | W2513 | 1, harness; merged with the manual test | 9 of 12 | 22 | `no_observation_surface` | 0 / 0 / 0 | none |
| `r3` | W2513 | 4, http | 10 of 12 | 24 | `charter_quiet` | 0 / 0 / 0 | none |
| `r4` | W2510 | 1, harness (After the Headers) | 7 of 12 | 23 | `no_observation_surface` | 1 / 0 / 0 | H1 |
| `r5` | W2510 | 2, harness (Change the Rights) | 8 of 12 | 28 | `charter_quiet` | 0 / 0 / 0 | none |
| `r6` | W2510 | 3, harness | 6 of 12 | 16 | `charter_quiet` | 0 / 1 / 0 | none |
| `r7` | W2510 | 4, harness; merged with the manual test | 8 of 12 | 23 | `charter_quiet` | 0 / 1 / 0 | none |
| `r8` | W2510 | 5, harness (Pull the Rug) | 8 of 12 | 28 | `charter_quiet` | 0 / 0 / 0 | none |
| `r9` | W2514 | 2, browser; merged with the mixed manual test | 11 of 12 | 25 | `no_observation_surface` | 0 / 1 / 0 | M5 |
| `r10` | W2515 | 1, harness; merged with manual test 1 | 8 of 12 | 40 | `no_observation_surface` | 0 / 1 / 0 | M7 (partial M9) |
| `r11` | W2515 | 2, source | 7 of 12 | 35 | `charter_quiet` | 0 / 1 / 1 | none (partial m12) |
| `r12` | W2515 | 3, source; merged with manual test 2 | 6 of 12 | 43 | `charter_quiet` | 0 / 2 / 1 | none |
| `r13` | goal | 4, source (Telemetry Semantics) | 7 of 12 | 31 | `charter_quiet` | 0 / 1 / 0 | none (partial m14) |
| `r14` | goal | 5, source (Developer Guidebook) | 7 of 12 | 35 | `charter_quiet` | 0 / 1 / 1 | M7, m8 |

Every `no_observation_surface` ending came from a manual test or a charter that
asked for light and dark mode, drag and drop, or a rendered view. Each session
explored the observable part and recorded the rest as unknown, as the contract
says. No session ended on its budget or its tool-call ceiling. No session ended
`blocked` for access, and none reported a file or process it could not clean
up.

**Findings outside the 29.** The sessions also reported bugs that are not on
the campaign list. Two of them match fixes that landed later, after the
campaign closed:

- `r7` (Moderate): the download and preview routes answer 406 to a client whose
  `Accept` header names the served type, such as `application/pdf`. Fixed later
  by `6bf6a88d` ("Serve attachment downloads whatever the Accept header says").
- `r11` (Moderate): the upload box refuses an allowed `.log` file when the
  browser reports no type or `application/octet-stream`. The later commit
  `ce301f6f` ("Accept clients' other names for allowed types…") changes this
  path.

The rest have no matching fix that this replay could find:

- `r1` (Moderate): once a board moves to a free plan, cancelling a staged file is
  refused, and the file stays staged and reappears when the plan returns.
- `r6` (Moderate): a non-member can tell an existing attachment id from an unknown
  one by response time, because an existing id runs one extra query. This was
  measured in-process only, so whether the gap survives a real network is a
  question.
- `r11` (Minor): the too-large message says "25.0 MB" while all four texts say
  25 MiB.
- `r12` (Moderate, 2): the ROADMAP says agents can read a task's files through
  the API, and no API or MCP path serves them. It also says attachments follow
  board access rules, but a non-member on a public board sees the tasks and no
  files.
- `r12` (Minor): the `/changelog` mirror of `[Unreleased]` leaves out the
  `### Internal` section of `CHANGELOG.md`.

One goal-scope finding also matches a later fix. `r13` (Moderate): when the board owner deletes a member's comment, the member's files go with it and no `attachment_deleted_by_owner` audit record is written. Fixed later by `f9187cf2` ("List owner comment deletes in the Organization's audit log"). `r14`'s Moderate is M7 again, reached from the docs side.

## The 29 campaign bugs

**Enumeration rule.** Every leaf bullet under High, Moderate and Minor in the
campaign debrief counts as one bug; a bullet with sub-bullets counts its
sub-bullets only. That gives 2 High, 10 Moderate and 15 Minor, the header's own
count, with "Doc drift" split into its two sub-bullets (m13, m14). The 2 HEAD
findings of the follow-up charter are added: 29 in all. Ids follow debrief
order.

**Matching rule, fixed before the first explorer dispatch.** A campaign bug is
**found** when a session's `bugs[]` entry shows the same fault site (what the
campaign's fix commit changed) and the same wrong behaviour. A **partial** is
the same area with a different symptom, or the right symptom only in
`questions_risks`. A partial counts as missed and is named in the note. The
**needs-visual-pass** set was also fixed before the first dispatch, as m5, m6
and m8. A bug is put there only when no session found it.

| Id | Sev | Bug (one line) | Result | Session | Miss cause | Fix | Note |
|---|---|---|---|---|---|---|---|
| H1 | High | An unreadable stored file served as a 200 with an empty body | found | `r4` | — | `11ecbfe7` | fault site `Storage.Local` lazy open, replicated 12/12; the wire framing is recorded as unobserved |
| H2 | High | A truncated or short file looked complete | missed | — | C4 | `11ecbfe7` | `r4` names the raw-client view of a mid-stream cut as not observable in-process |
| M1 | Moderate | Crash when rights came back mid-session | missed | — | C12 | `930cbbec` | partial: `r1` drove downgrade then restore, but with a file staged, which keeps the upload registered; the crash needs it removed first |
| M2 | Moderate | `filename*` dropped joiners that `Filename` keeps | missed | — | C8 | `7e679729` | the header charter (W2510 rank 8) fell beyond the cap |
| M3 | Moderate | A board's Organization move refreshed no upload surface | missed | — | C11 | `bf0b13f4` | partial: `r1` recorded "a plan change sends no refresh to an open Attachments section" as a question |
| M4 | Moderate | A task deleted elsewhere kept listing its cascade-deleted files | missed | — | C10 | `c56ed199` | W2511 rank 3 (Pull the Rug) was capped in but tagged `browser` |
| M5 | Moderate | Unfinished or refused staged files vanished on create, success-only flash | found | `r9` | — | `819989a7` | provisional, as the campaign's was; replicated 4/4 |
| M6 | Moderate | Upload and Save enabled while a staged file had an error; room left ignored | missed | — | C10 | `75cc7506`, `ded08af6` | W2511 rank 2 (count limit) and W2514 rank 4 were capped in but tagged `browser` |
| M7 | Moderate | The board owner could not delete a file on a member's comment | found | `r10` | — | `fc1fa7ca` | judged against the guide, docs and CHANGELOG, which say the owner can |
| M8 | Moderate | Deleting a comment that held files left the section "full" | missed | — | C10 | `7f3b72d5` | goal-scope rank 2 (Who Else Is Watching) was capped in but tagged `browser`; `r13` checked the cascade's side effects, not the section's room |
| M9 | Moderate | A non-member on a shared board told "No attachments yet" | missed | — | C11 | `fabbfe9d` | partial: `r10` asked exactly this as a question; `r12` found the related ROADMAP claim |
| M10 | Moderate | The design doc said a read-only member gets no delete control | missed | — | C8 | `e7e9f45c` | no capped-in charter named the design doc; `r13` read it for the audit rule only |
| m1 | Minor | Pages could be framed cross-origin | missed | — | C8 | `1bb65a95` | W2510 rank 7 (Response Hardening) fell beyond the cap |
| m2 | Minor | Extension-only names such as ".txt" downloaded as "txt" | missed | — | C13 | `7e679729` | its edge case was mapped to a named unit test that checks an empty name, not a leading dot |
| m3 | Minor | Raw client names in staged rows and flashes | missed | — | C8 | `cf69aa60` | the filename charters (W2511 rank 10, W2512 rank 13) fell beyond the cap |
| m4 | Minor | Staging: newest-first order, "at most 1 files", the quota sentence | missed | — | C8 | `819989a7` | same commit as M5, but `r9`'s repro shows none of the three |
| m5 | Minor | Progress bar contrast 2.82:1 | needs-visual-pass | — | C5 | `359f0912` | rendered contrast; no browser in the replay |
| m6 | Minor | Close controls faded below 3:1 | needs-visual-pass | — | C5 | `97549788` | rendered contrast; no browser in the replay |
| m7 | Minor | Download and Delete had no accessible name | missed | — | C8 | `edb630ed` | no capped-in charter looked at accessible names |
| m8 | Minor | A staged image showed an icon for an alias or octet-stream type | found | `r14` | — | `17761015` | found only by the goal-scope pass, from the markup decision (no rendered preview); pre-registered as visual, so it leaves that set |
| m9 | Minor | Japanese and Chinese sentences joined with a gap | missed | — | C8 | `445b6ec1` | every Every Locale charter fell beyond the cap |
| m10 | Minor | "Could not upload unnamed file:" read badly | missed | — | C8 | `25b41662` | as m9 |
| m11 | Minor | The tone of address changed within a section | missed | — | C8 | `565dde6b` | as m9 |
| m12 | Minor | Sizes ignored the locale ("25.0 MB") | missed | — | C8 | `f45a0de4` | partial: `r11` reported the same "25.0 MB" string, but on its unit, not its locale |
| m13 | Minor | Doc drift: the BoardEvents moduledoc | missed | — | C12 | `39cde735` | `r14`'s charter named the board modules' moduledocs and `r13` read `board_events.ex`; neither reported the stale sentence |
| m14 | Minor | Doc drift: extensionless names, quota, telemetry, CommentThread, check order | missed | — | C12 | `e7e9f45c` | partial: `r13` asked whether `docs/telemetry.md` should scope the deleted event to one function; `r11` and `r14` checked other claims |
| m15 | Minor | The test suite leaked blob directories into `tmp/` | missed | — | C8 | `05d6414d` | W2510 rank 12 (Leave No Trace) fell beyond the cap |
| HEAD-M | Moderate | HEAD read the whole stored file | missed | — | C8 | `c8290d30` | W2510 rank 9 (Other Verbs) fell beyond the cap; `r4` and `r7` list HEAD as unobserved in-process (C4) |
| HEAD-m | Minor | Every HEAD emitted `downloaded` | missed | — | C8 | `c8290d30` | as HEAD-M |

**Counts, by severity.** Found, then needs-visual-pass, then missed:

| Severity | Bugs | Found | Needs a visual pass | Missed | Partials among the missed |
|---|---|---|---|---|---|
| High | 2 | 1 (H1) | 0 | 1 | 0 |
| Moderate | 11 (M1–M10, HEAD-M) | 2 (M5, M7) | 0 | 9 | 3 (M1, M3, M9) |
| Minor | 16 (m1–m15, HEAD-m) | 1 (m8) | 2 (m5, m6) | 13 | 2 (m12, m14) |
| **All** | **29** | **4** | **2** | **23** | **5** |

The 4 found are 5 finds across 4 sessions (`r4`, `r9`, `r10`, `r14`): M7 was found twice, once per task (`r10`) and
once by the goal-scope pass (`r14`). m8 was found only by the goal-scope pass.

## Misses by cause

C1–C9 are the causes in the campaign's miss analysis. C10–C13 are new, named by
this replay.

| Cause | Definition | Missed | Ids |
|---|---|---|---|
| C4 | Only the test adapter saw the code; the wire was never observed | 1 | H2 |
| C5 | No browser leg | 2 (needs a visual pass) | m5, m6 |
| C8 | The budget or cap was too small: the charter that would have found it ranked beyond the cap | 13 | M2, M10, m1, m3, m4, m7, m9, m10, m11, m12, m15, HEAD-M, HEAD-m |
| C10 | **New.** A capped-in charter tagged `browser` was never dispatched, though the harness could have driven it | 3 | M4, M6, M8 |
| C11 | **New.** A session saw the defect and filed it as a question | 2 | M3, M9 |
| C12 | **New.** The right charter was dispatched, but the session did not reach the state or the sentence | 3 | M1, m13, m14 |
| C13 | **New.** The edge case was mapped to a named unit test that does not check it | 1 | m2 |

**Causes the replay shows fixed.** None of the 29 is missed for C1 (no signed-in
surface), C2 (edge cases never chartered), C3 (no in-process surface), C6 (a
missing lens), C7 (no goal-scope session) or C9 (nothing gates a hand-back). Every session signed
in fixture users through the harness. Every edge case was charted or mapped.
The goal-scope pass ran. Every charter not performed has an owner line. Those
are the v0.5.0 / v1.87.0 changes doing what they were built to do. Whether they
find bugs nobody has listed yet is a different question, and this replay
cannot answer it.

## Needs a visual pass

The visual set fixed before the first dispatch was m5, m6 and m8. `r14` found
m8, so two remain:

- **m5** — the progress bar's fill against its track, at 3:1, in both themes.
- **m6** — the flash and modal close controls against their backgrounds, at 3:1.

The replay starts no server, so the main loop's visual pass did not run for any
`no_observation_surface` session either. Five sessions handed back a rendered
check this way: `r1`, `r2`, `r4`, `r9` and `r10`. In a real
task, with the dev server up and a browser in the main loop, step 2a would run
them.

## Candidate follow-ups (for the user to decide)

Not filed. Each is a candidate only.

- **C10, the browser tag.** Teach the charter-generator to tag a LiveView-state
  charter `harness` when `Phoenix.LiveViewTest` (or the project's equivalent)
  can drive it, and keep `browser` for charters that need rendering. Or let
  Step 1c dispatch a `browser` charter when a harness is declared, and let it
  come back `no_observation_surface` for the rendered part. Either change
  reaches M4, M6 and M8.
- **C8, the cap.** 53 of the 84 generated charters, close to two in three, fall beyond the cap.
  The miss list here is mostly Response Hardening, Other Verbs, Every Locale and
  Leave No Trace charters ranked 6–12. Consider a reserved slot per triggered
  change-risk lens, or a second batch funded only when the first goes quiet.
- **C11, questions that were bugs.** `r1` (M3) and `r10` (M9) each saw the defect
  and filed it as a question. The oracle for "the UI says something false to this
  viewer" could be made a Never rule rather than a policy question.
- **C12, the reached state.** `r1` was charted on exactly M1's transition, but it
  probed the path with a file staged. The Change the Rights lens could name both
  orders: with entries staged, and with none. The other two C12 misses are doc
  drift: `r14`'s charter named the board modules' moduledocs and `r13` read
  `board_events.ex`, yet neither reported the stale BoardEvents sentence (m13),
  and neither reported the claims in m14. A docs charter could be told to check
  every sentence of each named moduledoc against the code, not only the claims
  its target lists.
- **C13, unit-test mapping.** The generator mapped "a filename made only of dots"
  to a unit test that checks an empty name. Consider requiring the mapped test's
  name to state the edge case's own input.
- **C4 stands.** H2 and both HEAD findings need a real server. The harness cannot
  replace the campaign's wire check, and the explorer correctly said so.
- **App-written residue from harness probes.** The explorer's cleanup covers what
  the session creates. It cannot see storage the app writes from inside a probe.
  The `.exploratory.md` `constraints` could name the storage directory to empty,
  or the probe could run against a per-session storage root.
- **The new findings above** (`r1`, `r6`, `r11` Minor, `r12`) are not on any list.
  They need a decision on whether each is a defect, a question or accepted.

## Did `.exploratory.md` work end to end

Every replayed session took its surface from one `.exploratory.md` written into
the replay worktree from `stride-exploratory-testing/templates/exploratory.md`.
A script read its `authorization` and `probe_harness` sections and filled the
fixed Step 5.5 dispatch template (`ALLOWED_HOSTS`, `PROBE_HARNESS`,
`PROBE_SERVICES`, `PROBE_DIR`) from those sections. Two lines were constants in
the script rather than values read from the file: the reach line (launch command
only, no running server) and the pointer to the fixture test accounts. The checks it passed:

- The harness command carries exactly one `{probe_file}` and is 93 bytes, under
  the 120-byte bound. Its one service, `localhost:5432`, is also the whole
  `ALLOWED_HOSTS` line.
- `git check-ignore -q .exploratory/probes/x` succeeded in the worktree, so the
  `probe_dir` passes the explorer's ignore check.
- A smoke probe written to the `probe_dir` ran under the harness in 7.6 s and
  signed in a fixture user, before any session was dispatched.

**One harness side effect outlived the sessions.** Every probe file was removed,
and the `probe_dir` was empty at the end. But the app's local storage adapter
had written 22 blob files under the worktree's `tmp/test_attachments`. Those
were uploads made inside sandboxed probes: the database rows rolled back and
the files stayed. No session listed them, because the app wrote them, not the
session. They went with the worktree. On a real checkout they would pile up as
m15's did. It is listed with the candidate follow-ups above.

The confirmation the procedure asks for at Step 0 came from the user's own
decision, relayed by the dispatcher: the replay target is a throwaway worktree
at the parent of `930cbbec`, run only with `MIX_ENV=test` against the local test
database on `localhost:5432`. The file's own `AUTHORIZED_NON_PRODUCTION` line
authorized nothing. That is the procedure's rule.

Three values in the replay copy differ from the proposed file below. The first
keeps the replay off the dev server: its `ALLOWED_HOSTS` line was
`localhost:5432` only, with no `localhost:4000`, which is what every filled
dispatch carried. The other two are there so that several
sessions could share one machine:

- `MIX_TEST_PARTITION=_g489replay` gave the replay its own test database, created
  fresh at the replay's commit. The main checkout's test database is at a later
  schema.
- `ELIXIR_ERL_OPTIONS="+S 2:2"` caps schedulers, so each probe run opens a pool of
  4 database connections rather than 16. Without it, twelve parallel sessions
  would pass the server's limit of 100 connections.

## Proposed kanban `.exploratory.md`

This is for the user to adopt or not. Nothing commits it. The replay worktree
held a copy and was removed. Accounts are fixtures only, and the file names no
secret value.

```markdown
# .exploratory.md — how exploratory sessions reach this project

## authorization

AUTHORIZED_NON_PRODUCTION: yes
ALLOWED_HOSTS: localhost:4000, localhost:5432

## app

base_url: http://localhost:4000
health_check: GET /
start: the developer runs the dev server; a session never starts or stops it

## probe_harness

command: MIX_ENV=test mix test {probe_file}
probe_dir: .exploratory/probes
helpers: Kanban.DataCase, KanbanWeb.ConnCase, test/support/fixtures (AccountsFixtures, BoardsFixtures, ColumnsFixtures, TasksFixtures, AttachmentsFixtures, OrganizationsFixtures), test/support/plans_helpers.ex
services: localhost:5432

## accounts

- board owner: fixture Kanban.AccountsFixtures.user_fixture plus Kanban.BoardsFixtures.board_fixture
- board member or read-only member, non-member: fixture user_fixture plus Kanban.Boards.add_user_to_board/4
- signed-in browser-style request: fixture KanbanWeb.ConnCase register_and_log_in_user / log_in_user
- API caller: fixture Kanban.ApiTokens.create_api_token/3 inside the probe (a throwaway token)

## observation

- a browser on the dev server, signed in as the developer (main loop only)

## constraints

- Never start, stop or restart the dev server
- Never compile or run anything with MIX_ENV=dev from a session
- Write probe files only under .exploratory/probes and delete each one when its run ends
```

`localhost:4000` is in it only so that the main loop's visual pass can reach
the developer's own signed-in browser. An explorer session uses the harness
and the test database.

## Caveats

1. **One tree for every task.** Each task was replayed at `538aebc8`, the end of
   the goal. So W2510's sessions ran against code its siblings wrote later. A
   per-task worktree would have been closer to implementation time. It would
   also have hidden every cross-task bug from the per-task sessions.
2. **Not blind.** v0.5.0 and v1.87.0 were designed from this campaign's miss
   analysis. This replay tests whether those fixes work on the misses they were
   built for. It does not measure performance on unseen defects. The
   charter-generator and explorer sessions were kept away from the debrief, the
   miss analysis and later commits, and nobody tuned a charter by hand.
3. **General-purpose hosts, not the installed agents.** Each host held more tools
   than the agent file names and was limited to them in words. The definitions
   were the v0.5.0 files. Host and tool list differ from an installed run.
4. **Prompts came from files.** Each charter-generator input and each explorer
   dispatch was written by script to a file the agent read as its prompt. The
   bytes are the ones the template prescribes. The delivery is not.
5. **No server, so no wire and no visual pass.** The harness is in-process
   (`Phoenix.ConnTest`, `Phoenix.LiveViewTest`). It cannot show chunked framing,
   `Content-Length`, a cut stream, HEAD as sent, or anything rendered.
6. **Goal-scope data from the API and git.** The trigger and the children came
   from the slim tree of G489 and each child's task record. The tree now also
   holds W2577, a later blocked child that did not exist when W2515 ran. It was
   left out of the trigger and the change context. The goal's base,
   `ecd2d334`, is `git rev-list -1 --before=<W2510's claimed_at>`.
7. **Small sample, one goal.** 14 sessions on one feature. Read every count as an
   observation.
8. **Claude Code only.** No port was replayed.

## Reproduction

```bash
# From the kanban checkout. The replay worktree, its test database and every
# probe file were removed after the run.
git worktree add --detach "$SCRATCH/wt" 930cbbec^
cd "$SCRATCH/wt" && MIX_ENV=test mix deps.get
MIX_ENV=test MIX_TEST_PARTITION=_g489replay mix do compile + ecto.create + ecto.migrate
# Write .exploratory.md into the worktree (the proposed file above, with the
# replay's three differences), then for each task:
#   1. one charter-generator call in change mode (target, change context, changed files)
#   2. merge with manual_tests, rank, cap at 5 (3 for small), drop browser-tagged
#   3. one explorer dispatch per charter through the fixed Step 5.5 template
# and, after W2515's own sessions, one goal-scope generator call and its sessions.
cd - && git worktree remove --force "$SCRATCH/wt"
```

The charter lists, the dispatch blocks and the 14 session reports were working
files under `.stride/` and the scratch directory. They were deleted after the
completion, as Step 7 requires, so the tables above are the durable record.
