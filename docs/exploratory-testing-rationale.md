# Exploratory-testing rationale

Rationale, provenance and history moved out of `skills/stride-workflow/optional-exploratory-testing.md` (Step 5.5) and `skills/stride-completing-tasks/manual-testing-findings.md` (W2271) so they are not re-paid every time a task runs Step 5.5. **This file carries no rule.** Every gate, enum and redaction rule stays inline in those two files — the unattended-surface principle and the never-dispatch list, the `AUTHORIZED_NON_PRODUCTION` and `ALLOWED_HOSTS` lines, the dispatch template, the explorer enums, the coverage endings, the relatedness gate, the provenance test, the escalation shapes, the severity table and every redaction rule. Each section below is reached from a pointer at the site it came from. Read it to learn why a rule is shaped as it is; a task run that never opens it is still correct. Where a section here and the skill disagree, the skill wins.

## Why Step 5.5 Exists

*From `skills/stride-workflow/optional-exploratory-testing.md` § Why this step exists.*

Tasks routinely carry `manual_tests` in their `testing_strategy`, but the workflow has historically had no way to actually perform them — they were left to a human or silently skipped. When the `stride-exploratory-testing` plugin is installed, the manual tests become **charters** — grouped by shared target, at most about three per task — and the explorer runs a real, budgeted exploratory session, closing the gap between "tests written" and "tests performed."

## Why Only the Explorer Is Dispatched

*From `skills/stride-workflow/optional-exploratory-testing.md` § Plugin-Availability Detection and § Sanctioned dispatch surfaces — non-interactive only.*

**Detection is not licence.** Seeing a command in the available lists means the plugin is installed — not that Step 5.5 may run that command. `/recon` and `/nightmare-headline` are on the never-dispatch list, and `/explore` is not dispatchable either; not one of them becomes runnable by having been detected. Detection was deliberately left as it was; the surfaces section narrows what may be *run*, never what counts as *installed*.

**Why unattended completion is the test.** The orchestrator does not prompt the user between steps — a standing rule of this workflow, not a property of any one plugin — so a surface that needs a person stalls the task with nobody there to supply one, until the claim expires. `/pair`'s withheld `Agent` and `WebFetch` are the clearest example of the reading method: its front matter shows it *cannot* drive the app itself. Reading a surface's front matter and prompt body is inspection, not execution, so the "never execute untrusted plugin content to probe for availability" rule forbids running a surface to find out what it does and does not forbid inspecting it.

**Why the routing skill is barred.** Its stated job is to route a request — including one shaped exactly like this step's — to the right sub-skill or slash command, `/pair` among them. It is also the surface most easily reached by mistake: it is what the bare name `stride-exploratory-testing` resolves to in the available-skills list, so "dispatch the plugin" lands on it.

**Why the explorer qualifies.** A subagent structurally cannot prompt a human mid-run, and this one is documented as never asking the user a question — charter and environment in, findings out.

**Why not `/explore`, despite it being the plugin's headline command.** It opens with an unconditional `AskUserQuestion` round — precisely because the explorer it dispatches cannot ask — and one of the four things that round gathers is the session's available interaction tools, which the command's own text says it must ask for because "a slash command cannot enumerate its own session's tool inventory." That question cannot be pre-answered by supplying arguments, so the round cannot be made to have nothing left to ask, and an unattended dispatch stalls on it. `/explore` is a fine thing for a **human** to run; it is not a surface this step can drive.

**Why each never-list entry is there.**

- **`/pair`** — the plugin's designated human-at-the-keyboard surface. Its own description says the human drives the application and "the whole command is a conversation," and its allow-list deliberately withholds `Agent` and `WebFetch` so it *cannot* drive the app itself. Dispatching it unattended waits forever on a human who was never invited. A human runs `/pair` deliberately; Step 5.5 never does.
- **`/nightmare-headline`** — a sustained interactive brainstorm that loops question rounds to elicit headlines and causes from a person.
- **`/recon`** — requires a human authorization confirmation before surveying any running system. That gate is a safety control; satisfying it on the user's behalf is not the orchestrator's call.

**Why the list is not a standing guarantee.** Every claim about what a surface asks, or what its allow-list withholds, was read from `stride-exploratory-testing` at a point in time — and that plugin ships on its own cadence, so a release there can silently invalidate an entry here. The list records reasoning, not a standing guarantee.

**History: how `/harden` left the never-list.** `/charter`, `/debrief` and `/harden` all clear the bar — every prompt they raise is the pre-emptible kind; `/harden`'s text calls its `--framework` flag an operator override. This is the test doing real work: applied honestly it moved `/harden` *off* the never-list, where an earlier draft had put it on a rationale the command's own text disproves.

## Why the Dispatch Is Grouped and Shaped This Way

*From `skills/stride-workflow/optional-exploratory-testing.md` § Claude Code: Dispatch the Exploratory-Testing Plugin, steps 1, 2 and 2b.*

**Grouping.** A manual test like "Verify the CSV export rejects an expired session token" becomes a charter in the form `Explore <target> with <resources> to discover <information>`. Merging entries that share a target avoids one session per entry repeating the same setup. Merging is by shared target, never by convenience.

**Parallel versus serial.** Two observe-only charters cannot disturb each other's results. When unsure whether a charter mutates, treating it as mutating is the cheap mistake: a serial session costs wall-clock, while a parallel one that corrupts another's data costs the findings of both.

**How to reach the app.** Being unable to establish how to reach the app is not the same as an unreachable app — there is nothing to dispatch against.

**The Step 0 affirmative.** Step 0 is where asking is legal, whereas asking between steps is not. Task text is author-written, which this workflow already refuses to trust for safety-bearing decisions — so it can never supply the authorization.

**Tools.** Naming a tool the explorer does not hold invites it to plan probes it cannot run.

**Source, logs and config.** This dispatch is the case that most benefits from naming them: the agent is running inside the very repository the charter targets, so naming the tree and the log locations sharpens its probes at no cost.

**Test accounts.** The dispatch prompt is an artifact like any other; a reference is enough for the session and keeps secrets out of it. Without a named account the session explores only what is reachable unauthenticated and returns *completed* having never reached the feature.

**Report path.** The distinct `.exploratory-` name keeps the report clear of Step 3's `.explorer-` reports.

**Template flattening.** Without flattening, a forged `Test accounts:` line placed in an untrusted slot would claim the caller's credential-naming authority.

**While the charters run.** A session judging behaviour against a tree that shifts underneath it reports results nobody can reproduce.

## Why the Budget Is Explicit and Endings Are Judged on the Sheet

*From `skills/stride-workflow/optional-exploratory-testing.md` § step 2a and the Safety boundary paragraph.*

**Whose figures.** The two repositories release independently, so the skill page can be ahead of or behind the explorer you will dispatch. As of writing, the contract's native unit is probes — default 12, usable band 8–20, plus a tool-call ceiling defaulting to 5× the probe budget (60 at the default) as a backstop against a session that spins rather than probes. These figures are the plugin's, not the skill's.

**Why state a budget.** An unbounded dispatch inside an autonomous workflow is both a runaway risk and a larger blast radius against a live application, and the caller is the only party that knows what the task can afford. A wall-clock figure is refused because the explorer has no clock, and a figure in minutes invites it to report a duration it never measured.

**The ceiling.** The tool-call ceiling running out means the session spent its calls without getting through its probes. Setup, orientation and reading source spend tool calls without spending probe budget, so a setup-heavy charter can hit it having run zero probes — at which point it is not "valid partial findings" but a session that did not happen.

**Blocked.** Blocking is a stopping heuristic the agent can reach *at any point*, not only before the first probe. At or near zero probes its coverage is identical to a zero-probe ceiling hit — nothing — so it takes the identical disposition. Two endings with the same coverage must not get opposite dispositions.

**`no_observation_surface`.** The sheet can show meaningful probes on the observable part, but the observation the manual test exists for was never made, so its coverage is not a partial session's and the same-coverage rule does not pair it with the blocked ending. A reader that does not know the value still sees `blocked`, and the handed-back test is visibly owed.

**Why coverage claims matter.** Claiming a spun-out or zero-probe session as a performed manual test is worse than not running the plugin at all, because the plugin-absent path at least flags the test as still owed. For the same reason a token session that cannot reach the feature produces a false coverage claim, which is the one outcome worse than not running. A task with several charters needs proportionally more total budget — which the cap of about three bounds — not a thinner slice each.

**Follow-ups, not follow-up charters.** A charter is a transient dispatch input with no identifier and no lifetime past the session; discharging leftover risk to one drops it.

**The obstacle is never a finding.** The distinction is not pedantry: the contract requires a blocked session to set its status, record the obstacle in the session's `debrief`, and not fabricate results — so where the app was unreachable from the start there is nothing in the bug list either. Treating the obstacle as a finding hands it to the absent-severity rule, which maps it to `important` — filing an unreachable dev server as an important testing finding whose worst impact you are then asked to name. The blocked ending's disposition turns on what the session actually did: at or near zero probes the manual test was not performed, so it is handed back and the unexamined risk filed; after meaningful probes it is partial coverage.

## Why Results Are Captured Whole and Timed Under reviewer

*From `skills/stride-workflow/optional-exploratory-testing.md` § steps 3 and 4.*

**The summary is a headline.** The explorer's returned summary is never the findings source. A crashed dispatch's retry takes the next unallocated `<N>` so it never shares a still-running sibling's report path.

**Capture everything.** Enumerating fields in the skill rather than passing them through is how a later contract change silently drops one — the same failure this workflow already warns about for `reviewer_result`. The root-level `status` is the coarse signal; the sheet is the only carrier of the stop reason and the probe counts. Recording how the session ended matters because an exhausted session and a complete one otherwise produce identical records, and the Review-queue human is the only remaining control on this path.

**Telemetry.** The no-reviewer case is not an edge case: the small 0-1 `key_files` path, where the decision matrix skipped review, reaches Step 5.5 routinely with no dispatched reviewer entry to fold into. All six names are always present, and dropping one would be the very incomplete-telemetry record the rule exists to prevent. A time-boxed session can be the largest single block of wall-clock in the whole task, and this integration exists to make that phase visible.

## Why the Artifact Directory Must Be Gitignored

*From `skills/stride-workflow/optional-exploratory-testing.md` § Gitignore the artifact directory.*

When a session writes anything to disk it goes under **`.exploratory/`** — `sessions/`, `checks/`, plus `backlog.md` and `coverage.md`. Those files hold transcribed application output, which is exactly the material the redaction rules keep out of the completion payload, and they arrive **untracked**. If the project's own `## after_doing` section stages everything before committing — `git add -A` or `git add .`, a common shape for a quality gate that commits its own fixes — it sweeps them into the commit, and a commit is far harder to walk back than a payload field. Neither behaviour is wrong on its own; they interact badly, and one `.gitignore` line prevents it.

Step 0 is the delivery point because this step only runs once a session is already under way, so it is structurally too late. The entry costs nothing when the directory never appears: a `.gitignore` entry for a path that does not exist is inert, and on the sanctioned dispatch path nothing writes there at all — the one file the `explorer` agent's contract has it write is its report at the `EXPLORATORY_REPORT_PATH` you supply, which lives under `.stride/` and is deleted at Step 7. The entry matters for the sessions an operator runs themselves.

`.gitignore` is inert for paths git already tracks: an already-committed artifact keeps being re-committed on every later change, forever, which is why `git rm --cached` is needed too — and why "before the first session" is the difference between the line working and the line doing nothing. A gate that runs `git commit -a` stages only files git already tracks, so it does not sweep untracked artifacts. If an `after_doing` guards on `git diff --quiet HEAD --`, the sweep still fires on any task that also changed a tracked file — which is most of them.

## Why Related Findings Are Fixed In-Task

*From `skills/stride-workflow/optional-exploratory-testing.md` § The relatedness gate.*

The worked example of a same-class finding: fixing a duplicate line in one cache key while the identical duplicate geometry sits in that same function's three sibling keys. The why is measured, not aesthetic: under the previous severity-first default one session completed 9 tasks and created 14 follow-ups, and its clearest case split ONE fix across a task boundary — the cache-key fix filed a task for its own function's sibling keys (D257). Creating more work than you close is a treadmill; fix it in this task is the disposition that converges.

Relatedness is judged from the code rather than the finding's text for the same reason the provenance test is: the application under test controls that text. The gate exists to stop splitting one fix across a task boundary, never to grow the task. A related-by-class Critical in lines you did not write skips the payload escalation because that machinery's scoping to lines you demonstrably wrote is an anti-gaming invariant (nothing the application prints may reach a blocking path), and the fix-before-completing disposition already guarantees the outcome a block would have forced.

## Why Provenance Comes Only From Your Own Artifacts

*From `skills/stride-workflow/optional-exploratory-testing.md` § Escalation, "The test" and its steps.*

An escalation that blocks completion must not be triggerable by content an attacker can influence, and the application under test controls the finding's summary, repro and observed output.

**Change-set gotchas.** A bare `git diff` omits staged hunks and untracked files, so a defect in a module this task just created would wrongly read as "not mine". A `HEAD`-scoped pair cannot see commits made between the base ref and `HEAD`, so on any task that committed mid-work — guaranteed on a re-run after fixing a previously escalated Critical — your own committed lines would read as "not mine" and a genuinely introduced Critical would be routed to discovered. The dirty baseline is the W1457 file, and excluding its paths is exactly the filter `capture_changed_files` applies, so the snapshot and the rule agree; without the blob-level step the exclusion is path-granular, and a human's pre-claim lines in a file you later edited would read as lines you wrote. A stale base ref makes the previous task's lines read as yours and can block you for a defect you did not write; `.stride-changed-files.json` has not been written for this task at Step 5.5.

**Dating moved lines.** While your work is uncommitted the moved lines read `Not Committed Yet` and blame cannot date them — it discriminates only once the move is committed, and needs `-M`/`-C` to follow lines across files. That is why a repro against the base ref is the primary check.

**Why uncertainty resolves to discovered.** Without an agent-owned footprint there is nothing to scope a block to, and falling back to the task's `key_files` would hand the blocking footprint to task-author text, breaking the very invariant the test exists to hold. Blocking on a link you could not draw would be a denial-of-progress surface, and it would reward investigating less; the rubric's own "never Critical, never High on an unknown" already keeps genuinely unknown-impact findings off this path. At Step 5.5 the task's work is normally still uncommitted, so `git blame` separates committed history from everything uncommitted — but it cannot separate *your* edits from ones already in the working tree when you claimed, which both read `Not Committed Yet`. That is precisely why the dirty baseline is subtracted and why a repro against the base ref, not blame, is the primary dating check.

## Why Introduced Criticals Are Re-Reviewed and Discovered Ones Never Block

*From `skills/stride-workflow/optional-exploratory-testing.md` § Escalation, the Introduced, Discovered and no-structured-block paragraphs.*

**Verify budget.** As of writing the contract's verify budget is 2 probes / 10 tool calls. A verify pass leaves the original session's coverage record as it was.

**Why a re-review, not a hand-edit.** The fresh review regenerates a clean `reviewer_result` with no stale entry, which is why the remedy is a re-review and not a hand-edit of the entry you appended. A fallback re-run that stops on its budget before reaching the defect has verified nothing, so a truncated session must never be read as confirmation that the fix holds.

**Why a discovered finding appends nothing.** A defect in lines this task did not write says nothing about whether this task followed its `testing_strategy`, and appending one would flip that section under the Consistency rule.

**Why the labels are strict.** The undeterminable and unidentified branches never established provenance, and stamping them "pre-existing" would assert as fact something you could not determine — on the Review queue, where a human is the only remaining control. (`completion_notes` is persisted only by Stride servers from D188 onward and you cannot tell which server version you are talking to, while `completion_summary` is required, persisted, and rendered on the Review queue.)

**No structured block.** A Critical defect your own change produced is your change's defect, which is why it is still fixed before completing even when there is nothing to escalate into.

## Why completion_summary Mirrors the Record

*From `skills/stride-completing-tasks/manual-testing-findings.md` § the carrier list.*

`completion_notes` is persisted by Stride servers only from D188 onward and you cannot tell which version you are talking to, so a record that lives there alone may reach nobody; `completion_summary` is required, persisted, and rendered on the Review queue. This matters most in exactly the case that looks safest: a small task where no reviewer ran, `completion_notes` is the *only* carrier, and a session that surfaced real bugs would otherwise vanish silently on an older server.

Stakeholder impact is asked for because a severity word says how bad the failure is; it does not say who it lands on, and that is what a reader triaging the queue actually needs. The explorer's `bugs[]` schema versions separately from the skill page and is the source of truth for the impact field. Reflecting the verdict inside the `testing_strategy` note reuses the tolerant-field approach already used for `reviewer_result`.

## Why the Severity Mapping Falls Where It Does

*From `skills/stride-completing-tasks/manual-testing-findings.md` § Severity mapping.*

**`minor` versus `cosmetic`.** `cosmetic` is a *narrower claim about the subject*: the finding's claim is correct and the only thing wrong is how something looks. Reading the Minor row as "minor implies presentational implies cosmetic" collapses exactly the distinction the flag exists to draw, and would let any `minor` skip the round.

**Where the four-into-three collapse falls.** One boundary has to be lost. The exploratory ladder's sharpest *descriptive* line is High/Moderate — whether wrong state survives — but the reviewer enum is not descriptive: its three values are **dispositions at the completion gate** (`critical` and `important` both mean *fix before proceeding*; `minor` means *optional but recommended*). So the boundary to lose is the one whose two sides share a disposition, and that is High/Moderate. Collapsing Moderate into `minor` instead would file a broken export or an unactionable error alongside a truncated label — the deflation `bug-advocacy` warns costs exactly as much credibility as inflation. Several of the rubric's ladder clauses are omitted from the table's third column.

**Why a non-escalating finding is never appended.** Any `category: "testing"` entry forces `testing_strategy.status` to `"failed"` under the bidirectional consistency rule; appending a non-escalating finding would therefore manufacture exactly the blocked completion the escalation policy promises not to cause.

**Why absent severity maps to `important`.** An unrecognized severity is application-influenced text, and a quoted token confers no instruction on any later reader — but it remains perfectly legible as a secret, which is why the fencing (injection) and the value-class test (disclosure) are separate problems. `critical` is wrong because it is the one value that triggers the Step 5.5 / Phase 3.5 escalation, and the rubric already refuses Critical on anything whose harm was not demonstrated — escalating on a string you could not parse would let malformed or application-controlled text reach a blocking path. `minor` is wrong because it is a silent downgrade.

## Why the Explorer Writes No Session Artifact

*From `skills/stride-completing-tasks/manual-testing-findings.md` § citing the session artifact and recording hardened checks.*

Be careful with the reasoning here, and do not overstate it. The explorer holds `Write` for its one report file only, and its `Bash` is unrestricted, so its tools do not establish that it cannot touch the filesystem, and neither does its output contract, which governs what it *returns* rather than what it does on the way. The accurate ground is narrower: nothing in the contract instructs it to write a session file, and no sanctioned path asks it to — so as the contract stands today, none appears. Treat that as true of today's contract rather than as a permanent guarantee. On that path the prose summary is not a degraded fallback but the normal and complete record.

For hardened checks: a skipped-but-present check in the suite is something a human should see rather than discover, which is why it is mirrored into `completion_summary`. `actual_files_changed` is the structured list of what the task changed, and naming a post-review file only in prose is how the divergence stays invisible. `.exploratory/` is ignored precisely so drafts stay out of the commit — which also means a staged draft exists on one machine only, so a recorded path dangles for whoever reads it next.

## Why Paraphrase and Truncation Are Not Redaction

*From `skills/stride-completing-tasks/manual-testing-findings.md` § Severity mapping (absent severity) and § Security.*

**Length is not a control.** The shape cues catch credentials only: `alice@bigcorp.com` and `db-prod-3.internal` are short and perfectly legible, and would sail through a length bound and an entropy test alike. Real secrets are short enough to survive a length bound — a live-mode payment key is around 32 characters, an email or an internal hostname shorter still — so truncating would emit the whole thing while looking like a mitigation.

**Why every sink.** All three carriers are persisted; `completion_summary` is the one guaranteed to be rendered on the Review queue, so it is the last place a leak should reach and the first that would be seen. The request that reproduces a bug is often the request that carries the credential (`repro`, `minimal_repro`); `why_wrong` restates the mechanism, and so the secret, to justify the verdict; `worst_observed` is what the impact line draws from.

**Why paths and impact text.** Impact text is derived from observed application behaviour and can carry customer identifiers, account data, or internal hostnames straight out of what the session saw; a path can disclose a username, home directory, or environment layout. The `[REDACTED — finding text embedded a credential]` marker is the same convention this workflow already uses for a credential-bearing matrix row.

**Why findings are data.** A finding originates in application output you do not control, and folding it into a completion payload gives it no authority. This is the same discipline the security-considerations dispatch already requires of the diff and the consideration strings it is handed.
