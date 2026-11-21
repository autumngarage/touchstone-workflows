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
project schemas; the source-contract job executes fixtures for every advertised
schema with those exact bytes before an engine-pin change can land. Its
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

## Pull request task eligibility

The engine's [schema-4 task declaration](https://github.com/autumngarage/touchstone/blob/main/docs/validation-contract.md#schema-4--pull-request-eligibility)
can exclude a task from PR validation with `pull_request = false`. New tasks
remain eligible by default. The engine derives the PR inventory from those
same declarations: a mixed group keeps its eligible tasks; an entirely
deferred group needs no PR runner.

The protected planner admits that reduction only when the GitHub candidate
matches the checkout and the declaration is an identical regular Git blob at
both the event's base commit and candidate commit. The actual checkout bytes
must match too. It validates the complete contract without running project
code before building the matrix. Changed, symlinked, untracked or unverifiable
declarations retain the full plan. Missing eligibility metadata or an empty
reduced inventory also retains the full plan.

Both preparation and execution receive the admitted event. A full-plan
fallback omits that event, so PR exclusions cannot suppress tasks inside an
allocated group. Other events retain full integration coverage; pushes and
manual/reusable cache producers retain their serial runs. Fork placement stays
hosted, including when its declaration qualifies for fewer groups. Each run's
plan outputs govern failed-job reruns too.

This source capability does not migrate consumers or install a CLI. Before
opting into a new schema, verify that the normal local `validate`/`adopt`
entry points and every pinned validation caller, including cache producers,
support it. Existing schemas and callers need no declaration changes.

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

Set the optional repository variable `SWIFT_BUILD_CACHE_SKIP_GROUPS` to a
comma-separated list of exact, case-sensitive group names, without spaces,
for groups that do not consume SwiftPM build output. Their declared setup
and validation still run. An unset or unmatched value keeps existing cache
behavior. Serial runs, including default-branch cache producers, are not
named groups and always retain their existing cache behavior.

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

The protected plan assigns a runner to each validation group when the workflow
starts. A private repository can set `LINUX_LOCAL_PR_GROUPS` to a JSON array
of exact, case-sensitive group names it has qualified on its single-use Linux
pool, for example `["lint","unit"]`. On a pull request from the same repository,
each listed group waits for an eligible local runner. All other groups run on
GitHub-hosted Ubuntu. If groups differ only by case, every spelling in the
matrix must qualify before those jobs can use the pool.

With this setting, forks, merge candidates, scheduled validation and ordinary
cache producers use GitHub-hosted Ubuntu. A private repository’s default-branch
push or manual caller can explicitly select `runner: local` for its serial run
to seed a local cache. A Blacksmith request cannot select a paid runner
under this policy. Set `[]` to send all PR groups to GitHub-hosted Ubuntu.
An operator can temporarily place one of those local PR groups on GitHub-hosted
Ubuntu by setting the repository variable `LINUX_GITHUB_OVERFLOW` to a JSON
object. For example, the following grants group `unit` in one workflow run.

```json
{"v":1,"repository_id":"37","workflow_id":42,"run_number":19,"event":"pull_request","group":"unit","expires_at":1800000000}
```

Set `expires_at` to a Unix timestamp within the next ten minutes. The planner
checks GitHub’s record for the current run, including the repository, workflow,
path and run number. An expired grant, unavailable API, or ambiguous group
preserves the original placement. Failed-job and full reruns use the original
local assignment. The grant applies only to GitHub-hosted Ubuntu.

A private repository can place one native Arm-compatible integration group on
standard GitHub-hosted `ubuntu-24.04-arm`. Set `LINUX_QUEUE_ARM_GROUP` to
`{"group":"unit","workflow_id":42}`, using the numeric workflow ID from a
required validation run in the consuming repository. The planner confirms the
default-branch merge group, current run identity and unique group name. The
group must already target GitHub. Other workflows and groups keep their
planned runner. An absent or invalid configuration or an unavailable GitHub
API keeps the original placement. Qualify every command and container image in
the group for Arm before enabling it. Clearing the variable restores the
original placement on new runs.

### Reserved isolated merge capacity

The protected planner can assign one qualified merge group to an isolated
single-use x64 KVM runner with Docker inside its guest. The committed
[`POLICY`](runner/merge-routing.py) owns the eligible repository, workflow,
group, capability and verified controller service identity. A missing issuer
keeps installation closed; qualification measurements alone do not enable
native placement. Other repositories require their own reviewed qualification.

The planner follows GitHub's native merge-queue candidate/base chain and
checks every contributing PR's private same-repository origin. It also requires
an unchanged regular `.touchstone.toml` blob. Only a uniquely named, already
hosted group can qualify. After those checks it reads commit statuses once on
that exact candidate, with no fixed intake wait. The controller's
fresh success status must bind the repository, required workflow, run, attempt
and group. Missing, stale, ambiguous or unavailable evidence preserves hosted
placement. The existing qualified GitHub Arm route remains available.

The controller uses the helper's `reserve` command under its existing
`register.lock`, sharing that state directory with every controller that could
admit the slot. Only `acquired: true` authorizes provisioning. Repeats return
the original reservation; competing requests cannot reserve the same slot.
After reservation, the provisioner checks capacity and release reservations,
starts the isolated guest and acknowledges a run-specific JIT runner. The
helper's `publish` command checks that fresh acknowledgement and GitHub's live
runner before appending the status through a restricted App installation token.
The returned status must identify the installed App's pinned bot account. Its
request, receipt, status context, TTL and label contracts are defined by the
helper; no runner administrator credential enters a workflow job.

The controller's `GH_TOKEN` remains a runner registration credential;
`GH_STATUS_TOKEN` is a separate short-lived installation token for the
qualified repository, with Actions, Contents and Pull requests read and Commit
statuses write. No release App private key belongs on the runner host. An
absent or empty status token cannot fall back to the registration credential.

Installation requires a separately verified service credential and a runner
group restricted to the qualified private repository and protected workflow.
The group must admit only isolated single-use guests, with no host Docker,
host workspace or release labels. Keep a reservation until the controller has
confirmed native job termination and reclaimed the guest. A grant whose
planning window was missed first removes its idle exact registration after
proving the group chose a different selector. Status expiry never
authorizes reusing possibly live capacity. A failed-job rerun cannot reuse an
earlier attempt's selector; a full rerun needs a fresh reservation and grant.
This route adds no paid provider admission or independent capacity controller.
GitHub's existing organization budget hard stop owns hosted credit admission;
a budget denial is an infrastructure hold, never a synthetic product verdict.
Keep the delivery intent and controller recovery material when that happens.

The optional [`merge-intake`](.github/workflows/merge-intake.yml) reusable
workflow emits a no-secret job to the already-qualified Runscaler control
pool. Its [consumer example](runner/merge-intake.example.yml) is a separate
workflow, outside every required workflow and status. Per-repository native
concurrency replaces older pending signals and cancels older active signals;
[GitHub expires a parked self-hosted job after 24 hours](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#routing-precedence-for-self-hosted-runners). Its one-minute job
timeout covers execution, not queue time. A missing control pool never blocks
required validation, and the controller refuses a target that makes the
signal required.

[`kvm-admission.py`](runner/kvm-admission.py) consumes the pinned Runscaler
manager's JSON lifecycle stream as a wake-up hint. It independently verifies
the signal's native run/attempt/job, immutable reusable source and private
runner group, then the unique still-planning native validation run and full
queue chain. A late signal cannot move a group already assigned to a runner.
The manager retains its standard outbound scale-set long poll; the adapter
adds no hosted polling job or public listener. The routine guest receives an
exact attempt-specific JIT selector, never the shared control-pool label.

The [observed timing fixture](tests/fixtures/runscaler-timing.json) records
the old cold control dispatch at 18 seconds and the organic validation plan
at 25 seconds. The control qualification included an intentional 90-second
sleep, which the new signal does not contain. The new path adds no fixed
planner delay. If the fresh grant misses the natural planning work, that
candidate stays hosted. The old hosted checks job ran 18m17s (19 billed Linux
job minutes); a successful local assignment removes that hosted job. These
are prior measurements, not a claim that the new dispatch has been qualified.
The measured planner already rounds to one billed minute; the new path adds
no fixed delay to that minimum. Actual timing and savings still need native
measurement. [GitHub rounds each job to whole minutes](https://docs.github.com/en/billing/reference/actions-runner-pricing).

Installation inputs live in the [configuration example](runner/kvm-admission.example.json),
[control pool configuration](runner/runscaler-intake.toml), and
[guest seed example](runner/kvm-guest.seed.example.yaml). The fixed systemd
guest uses a fresh overlay, a separate DynamicUser, bounded CPU/memory/I/O,
AF_VSOCK SSH, and no host mounts or private-network access. The release guard
attributes host runner processes to their containers, preserves all four
release listeners, refuses another guest/active release work, and removes
routine capacity if that evidence changes. Only Docker inside the guest is
available to a candidate. Reconciliation stops only the owned guest and
retains its lease if teardown or native assignment is uncertain.

Run `python3 runner/kvm-admission.py install-dry-run --config <configuration>`
to list exact installation files without changing the machine. The existing
Runscaler service's reviewed drop-in uses the adapter; the four-slot release
service and its shared helpers are not changed. Native files install beneath
`/opt/hesperus-runner/native`. Activation requires the dedicated App policy, qualified
native source/IDs, pinned immutable guest inputs and SSH identity, and a private
automatically renewed [private installation credential](runner/status-issuer/README.md).
The dedicated App key remains on Studio; its bounded launchd renewal sends
only a one-repo token over restricted SSH. The adapter reloads and checks the
credential's issuer, scope and expiry for every API request. Keep
the service disabled until those gates and a real native qualification pass.
GitHub's retained `prepared_workflow_job` audit evidence identifies imposed
validation by `@refs/heads/main`; `validation_source_ref` records that runner
admission identity. The separate `validation_source_sha` must match the
effective pinned required-workflow rule. Do not substitute one meaning for
the other. The optional reusable signal remains SHA-pinned.

The plan job requires `contents: read`, `actions: read`, `pull-requests: read`
and `statuses: read`. Before upgrading a reusable `uses:` caller to this
revision, allow those scopes on the calling job.
Candidate validation jobs retain only `contents: read`.

A missing or empty `LINUX_LOCAL_PR_GROUPS` preserves the following routing for
existing consumers. Fork PRs, or PRs whose same-repository origin cannot be
established, always use GitHub-hosted Ubuntu even when a global target is set.

| Setting | Applies to | Values |
|---|---|---|
| `LINUX_PR_RUNNER` | pull requests from the repository itself | `local`, `blacksmith`, `github` |
| `LINUX_QUEUE_RUNNER` | the merge queue | `local`, `blacksmith`, `github` |
| `LINUX_VALIDATION_RUNNER` | the default for both, and pushes and reusable callers | `blacksmith`, `github` |

- `local` is the single-use `linux-ephemeral` fleet: each runner takes one job
  in a fresh container with no mounts or credentials, then exits. Its supervisor is
  `runner/linux-runner.sh`, run at boot by
  `sudo bash runner/linux-runner.sh install-daemon <user>`: N identical
  single-use slots (`LINUX_RUNNER_SLOTS`), each registering a runner labeled
  `linux-ephemeral` for one job, with no slot roles or cache images. Installing
  again replaces a running fleet without cutting a job: its running jobs
  finish first, for up to the daemon's `ExitTimeOut` (90 minutes).
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

The final validation verdict uses GitHub’s single-CPU `ubuntu-slim` runner.
The planner, `review-gate` and `delivery-evidence` use `ubuntu-latest`.
The workflow source contract runs on `ubuntu-24.04`.

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
