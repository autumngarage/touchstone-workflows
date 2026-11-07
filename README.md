# Touchstone Workflows

Protected source for organization-required GitHub Actions workflows. Target
repositories execute these workflows from immutable commit SHAs, so a pull
request cannot weaken its own merge gate by editing a same-named local file.

Changes to `main` require a pull request. Touchstone's audited GitHub policy
owns which source repository, path, and full commit SHA are required.

The required job downloads `scripts/touchstone-run.sh` from a full Touchstone
commit SHA, verifies its pinned SHA-256 digest, and runs the target repository's
`.touchstone.toml` declaration. Consumers carry declarations only: they do not
copy the validator or own the authoritative workflow.

## Source contract

`.touchstone-source-contract.json` is the versioned boundary between this
repository and Touchstone's source policy. It names every top-level workflow,
the workflow and job that publish the `source contract` status, and the exact
required-check name. Its `validationEngine` declaration binds the consumer
workflow's Touchstone repository, path, revision, checksum, and supported
project schemas; the source-contract job executes schema-1 and schema-2
fixtures with those exact bytes before an engine-pin change can land. Its
`evidenceChecker` declaration publishes the delivery-evidence checker's repository,
path, revision and SHA-256 digest. The evidence workflow reads that manifest at
its defining job's immutable workflow revision (`job.workflow_*`), validates the
coordinates and verifies the fetched checker before execution. It never reads
the consumer's manifest or a moving default branch. Missing source metadata
fails explicitly; GitHub Enterprise Server is unsupported for this loader.
Consumers that vendor the checker can compare their bytes with the manifest
at their effective workflow pin; this source change does not update that pin.
The existing
`gateBehaviorContractVersion` declares the behavior
contract implemented by the pinned workflows. Version 4 means that
validation, review evidence, and delivery evidence are checksum-pinned,
read-only required workflows with aligned refresh triggers that run for pull
requests and merge groups; the review gate derives one trusted reviewer
verdict for the exact current PR head — only an unedited, explicit clean
result succeeds — and never adjudicates historical findings: threads belong
to GitHub conversation resolution and the merged result to the merge queue
(AUT-1132). Every review-gate run evaluates once and never waits (AUT-793):
the driver waits for the reviewer on its own machine, then re-runs the gate.
A waiting pull-request run asks the fallback reviewer only when the reviewer
has said it cannot answer (a usage or quota notice, or an explicit error
reply to the head's latest request), when a bot opened the pull request, or
when the head's latest review request is older than
`REVIEW_EVIDENCE_WAIT_SECONDS`. The fallback never overrides a completed
findings verdict (AUT-1581). Otherwise the run fails at once, naming its
state and the request's age. A merge-group run binds the queue commit and
base to the PR number in its ref and evaluates once. Evidence collection is
O(pages of current surfaces): every REST path crosses an enforced 12-request
evaluation limit with a four-page bound per surface, independent of how much
review history the pull request carries. Evidence that exceeds a bound fails
closed.
`tests/test-workflow.sh` refuses missing, extra, nested, or duplicate
workflow declarations, verifies that only the declared publisher owns the
status, refuses engine-pin drift between the manifest and consumer workflow,
and guards those version-4 behavior invariants.

Pull requests land through the repository's merge queue only after the source
contract check passes. Touchstone separately pins each consumer-required
workflow to an immutable commit from this repository.

Queue validation uses GitHub's native matrix fail-fast: a failed shard cancels
the same candidate's remaining Linux shards so a known-invalid generation does
not keep build slots. The required aggregate still fails for failed, cancelled
or skipped validation; a successful candidate must pass every declared group.
Author and maintenance runs retain all shard results. This does not supersede
healthy queue runs, change runner routing, or adopt a new consumer policy pin.

The optional repository variable `VALIDATION_MAX_PARALLEL` is the consumer's
administrator-selected matrix budget. Unset or empty keeps the default of two;
a positive decimal integer permits at most that many declared groups at once.
The planner caps the value to the actual matrix size, including the single
serial cache-seed/older-engine fallback. Malformed or nonpositive settings fail
planning before publishing matrix outputs. Every group and the required
aggregate still run under the existing rules. This does not select runners or
increase their resources. Changing a consumer's setting or adopting a new
required-workflow pin requires that consumer's normal approval and rollout;
source delivery alone does not change its live scheduling.

## Git history transfer

`VALIDATION_BLOBLESS_CHECKOUT=true` opts the candidate-execution checkout into
Git's `blob:none` partial fetch. Its full commit/tree history, refs and exact
worktree remain available; historical file contents are fetched from GitHub
when a command needs them. Unset or false keeps the existing complete fetch.
The source-contract and planning checkouts do not change. A reusable caller
can pass `force_full_checkout: true` to retain a complete checkout when
adopting a new pin. The default leaves the repository opt-in in control.

Opt in only after auditing historical readers: missing blobs require a
reachable origin and checkout credentials during validation. An offline
history reader or a reader after credential cleanup must retain a complete
checkout. Lazy fetches can offset the initial transfer reduction; measure a
complete ordinary validation, not just checkout. Adopting the reviewed
workflow pin and the consumer setting is a separate normal rollout.

## Swift build caches

Consumers can opt into the validation workflow's SwiftPM cache with the
repository variable `SWIFT_BUILD_CACHE=true`. It applies to Linux runners with
a checked-in `Package.resolved`. Declared setup runs before fingerprinting the
toolchain and restoring its cache, so it can select or install a compiler.
Installers must expose their selected path to later Actions steps. Setup must
be idempotent: ordinary validation runs it again and must retain the prepared
compiler; a later change fails before cache save. Without Swift after
preparation, validation runs normally without a cache. Non-cache consumers
retain their single ordinary setup run.

The workflow owns the cache key and its inputs. It separates platform,
architecture, toolchain and dependency/build declarations, with a compatible
restore prefix across revisions. Cached `.build` output accelerates compilation;
the declared validation command always runs, including on an exact cache hit.
No runner volume or writable cache is shared between job containers.

A consumer must also invoke this pinned workflow through `workflow_call` on
default-branch pushes to produce reusable default-branch caches. PR-only caches
are confined to their merge refs and do not seed other PRs, so required PR and
merge-group runs only restore. Successful default-branch pushes and manual
runs save after validation and the toolchain check; exact cache hits need no
upload. Existing candidate caches can still restore within their GitHub scope.
The producer uses
the same validator, so it cannot drift into a second validation implementation.
The protected workflow pin, consumer producer and repository opt-in must all be
deployed before measuring cold/warm improvements. Passing the source contract
alone is not evidence of a consumer cache hit or reduced build time.

A caller that schedules full validation separately from its seeds can pass
`separate_scheduled_validation: true` to separate the called workflow's group
as well. The option affects only the schedule event; seed coalescing, pull
request replacement and merge-queue validation retain their existing keys.
The two roles may then overlap, so peak runner demand can increase.

Validation keeps a 30-minute limit for consumers without
`SWIFT_BUILD_CACHE=true`. Swift-cache consumers get 60 minutes: the
measured two-CPU cold build took 20 minutes before tests, so a 30-minute limit
cancelled useful work and forced the next attempt to rebuild it. This is a
ceiling, not a target; backend/concurrency fixes and compatible caches still
reduce the work. Every validation command and spending guard remains in force.

A reusable-workflow caller may explicitly pass `timeout_minutes`, which takes
precedence; its existing default remains 30. Cache producers already passing
60 retain that limit. Required PR, push and merge-queue workflows have no
caller input and select the limit from their Swift-cache setting.
Consumer policy must adopt the reviewed workflow pin before this takes effect.

## Runner

Static repository settings route `validate-groups`, the job that runs the
candidate's declared commands. Nothing rewrites them at run time: no watcher,
no overflow, no org-variable membership (the dynamic `LINUX_RUNNER` and
`LINUX_GATE_RUNNER` routing is retired, AUT-3412).

| Setting | Applies to | Values |
|---|---|---|
| `LINUX_PR_RUNNER` | pull requests from the repository itself | `local`, `blacksmith`, `github` |
| `LINUX_QUEUE_RUNNER` | the merge queue | `local`, `blacksmith`, `github` |
| `LINUX_VALIDATION_RUNNER` | the default for both, and pushes and reusable callers | `blacksmith`, `github` |

- `local` is the single-use `linux-ephemeral` fleet: each runner takes one job
  in a fresh container with no mounts or credentials, then exits. A fork's
  pull request never runs there; it takes the default. Its supervisor is
  `runner/linux-runner.sh`, run at boot by
  `sudo bash runner/linux-runner.sh install-daemon <user>`: N identical
  single-use slots (`LINUX_RUNNER_SLOTS`), each registering a runner labeled
  `linux-ephemeral` for one job, with no slot roles or cache images.
- `blacksmith` is Blacksmith's 4-vCPU Ubuntu 24.04 runner, and `github` is
  GitHub-hosted `ubuntu-latest`.
- Unset settings fall through: the per-event setting, then
  `LINUX_VALIDATION_RUNNER`, then `BLACKSMITH_LINUX=true` (Blacksmith), then
  GitHub-hosted. A reusable caller's `blacksmith: true` input wins outright,
  then its `runner` input (`local`, `blacksmith` or `github`): a cache seed
  for the local fleet passes `runner: local`, because only a run on the
  fleet's architecture can save a cache the fleet restores.
- Planning fails on any other value, so a misspelling cannot fall through to
  another runner unnoticed.

Moving traffic is one command, for example
`gh variable set LINUX_QUEUE_RUNNER --body github -R <owner>/<repo>`, or
`gh variable delete LINUX_PR_RUNNER -R <owner>/<repo>` to return pull requests
to the default. A job keeps the runner it was given when it was created, so a
change applies to jobs created after it; queued `local` jobs wait for the fleet.
Blacksmith must be installed for the consumer repository and is billed
separately from GitHub. Adopt the reviewed workflow pin before setting a value
it does not know.

Validation planning (`plan`), its final summary (`validate`), `review-gate`,
`delivery-evidence` and the `source contract` job run for seconds and always
run on GitHub-hosted `ubuntu-latest`. macOS jobs keep their own routing.

### macOS runner pool (AUT-2013)

The consumer workflows above never run on macOS. A consumer's own macOS
workflow (nyx's `macos.yml`, hesperus's) runs in a CI account on the Mac,
whose first runner (`ci-studio`) was registered by hand and is named by the
consumer's `MACOS_RUNNER` variable. `runner/macos-runner.sh` adds a pool beside
it: slots of single-use runners in the same account's login session, where UI
tests have a window server, so one Mac runs several macOS jobs at once with
no second account to maintain.

Each slot asks GitHub for a just-in-time configuration labeled
`ci-studio-pool`, starts that runner as a one-shot launchd job in the
account's GUI domain (the keys `ci-studio`'s own service uses), and waits for
it to exit. A job that selects `ci-studio-pool` takes whichever slot is free;
`MACOS_RUNNER_SLOTS` sets how many there are. nyx's test shards select the
pool through `MACOS_TEST_RUNNER=ci-studio-pool`; unsetting that variable puts
them back on `ci-studio`. `ci-studio` alone keeps its name label, and work
that must not overlap itself in the account selects it: cleanup that stops the
account's processes (hesperus), and the smoke, whose macOS grants belong to
that runner.

**Queue priority (AUT-2813).** `MACOS_RUNNER_QUEUE_SLOTS=N` opts the Mac pool
into demand-based registration (`runner/queue.sh`, AUT-2704/AUT-2757). It
defaults to `0`. GitHub does not hand a freed runner to the job that has waited
longest, and a pull request ships only through the queue, so the supervisor
chooses each new runner's role when it registers, from what is waiting: a
queue-only runner when queue jobs wait beyond the idle queue-only runners;
otherwise a queue-only slot among the first `N` while no pull-request job
waits; otherwise a shared one. At most `SLOTS-1` runners are queue-only at
once. Shared registrations also advertise `ci-studio-pool-shared`; consumers
can require that extra label outside `merge_group`, leaving queue jobs able to
use either role. At least one slot stays shared. Idle queue-only registrations
are recycled when PRs wait and no queue job needs them. Demand includes queued
jobs in partially started workflows, including Nyx's multiple test shards.
The token needs Actions read access to every repository admitted by the group;
unreadable demand logs a warning and uses the configured fixed reservation.

Roll out in order: install the new supervisor with the reservation disabled;
verify shared registrations advertise the extra label; deploy the consumer
selectors behind their opt-in settings; then enable a reservation smaller than
`MACOS_RUNNER_SLOTS`. Keep the existing slot count, user and restart settings.
Install only after active pool jobs finish: replacing the current Mac service
stops its slots. Existing queued jobs retain their original selectors, so the
priority guarantee applies after legacy selectors drain. Old base-label
consumers remain routable but can consume a queue-only slot; update every
consumer in the group before treating the reservation as enforced. Rollback:
set the reservation to `0`; the shared-label selectors remain routable.

**The account never holds an organization credential.** Its jobs can rewrite
anything in its home, so the supervisor runs as root with a token only root
can read, and GitHub fixes each runner's name, labels, and group: the account
only ever receives one runner's own configuration, in the launchd job's
environment and never as a process argument. Root does no file work in the
account's home; the account copies `ci-studio`'s runner files into each slot
(`tests/test-macos-runner.sh` pins both). The runners are single-use, but the
host is shared with `ci-studio`'s persistent runner, so the pool registers
into the same runner group, `macos`, and checks it before every registration:
visible only to selected repositories, and holding only private ones.

On the Mac, with the account logged in and `ci-studio` registered, give root a
fine-grained token owned by the organization with the one organization
permission **Self-hosted runners: read and write** (and **Actions: read** on the
group's repositories for queue priority), then install:

```bash
state="/Library/Application Support/com.autumngarage.macos-pool-runner"
sudo install -d -m 700 -o root -g wheel "$state"
sudo install -m 600 -o root -g wheel <token file> "$state/github-token"
sudo bash runner/macos-runner.sh install-daemon      # MACOS_RUNNER_SLOTS=3 for more slots
sudo bash runner/macos-runner.sh status
gh variable set MACOS_TEST_RUNNER --repo autumngarage/nyx --body ci-studio-pool
```

The daemon starts at boot and waits for the account's login session, which
auto-login brings back after a restart; its log is
`/Library/Logs/com.autumngarage.macos-pool-runner.log`. After each job, and before the slot registers its next runner, the
supervisor ends any process in the account that still names that slot's work
directory: a test's children can outlive the job's own process group, and
every job shares the account (AUT-2076). `sudo bash
runner/macos-runner.sh uninstall-daemon` stops the pool and removes its
registrations. Rotating the token means replacing both copies.

**A lost session restarts the Mac, when asked to (AUT-2179).** The runners live
in the account's login session, and macOS ends every session when its window
server dies. Auto-login only happens at boot, so the pool and `ci-studio` then
stay down until a person logs the account in, and a login without a restart
leaves the account's per-user daemons from the old session, which breaks
xcodebuild's app launches. With `MACOS_RUNNER_RESTART_AFTER=<seconds>` in the
environment of `install-daemon`, the supervisor restarts the Mac once the
account has had no usable session for that long. A session whose login window
started before the running window server counts as lost too (AUT-2255): the
account still reads as logged in, but nothing in it can reach the display and
no runner is registered into it. It restarts only when nobody is at
the console, auto-login is configured for the account, and it has restarted
fewer than twice in the last 24 hours; otherwise it logs why it is waiting.
The default is 0: never restart.
