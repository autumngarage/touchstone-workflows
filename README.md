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

## Linux overflow

`runner/linux-overflow.sh` owns the Linux overflow functions used by
ci-studio's existing `ci-watch.sh`. The watcher supplies routing, usage state
and logging; this module does not start another controller. After review and
merge, install the module alongside the watcher and replace its inline block
from `OVERFLOW_WAIT` through `check_linux_overflow` with a source of that file.
Back up the watcher, validate its shell syntax and restart only the watcher
while it is sleeping. Existing state files retain their meaning; rollback
restores the backup. Installation does not enable overflow.

The timeout guard reads current PR, main and merge-queue Linux checks, so a
rerun is not excluded by its original workflow creation time. Unreadable or
truncated evidence returns routing to local runners. The captured API-shape
fixture and guard tests live in `tests/test-linux-overflow.sh`.

## Swift build caches

Consumers can opt into the validation workflow's SwiftPM cache with the
repository variable `SWIFT_BUILD_CACHE=true`. It applies to Linux runners with
a preinstalled Swift toolchain and a checked-in `Package.resolved`. Validation
setup must retain that toolchain; a change fails the job before cache save.
Without a preinstalled toolchain, validation runs normally without a cache.

The workflow owns the cache key and its inputs. It separates platform,
architecture, toolchain and dependency/build declarations, with a compatible
restore prefix across revisions. Cached `.build` output accelerates compilation;
the declared validation command always runs, including on an exact cache hit.
No runner volume or writable cache is shared between job containers.

On the single-use Linux runners, the job image can carry the products of the
consumer's last default-branch seed (`LINUX_RUNNER_CACHE_SEED`, AUT-2672), and
validation copies them into place instead of downloading GitHub's cache when
their recorded key has the run's restore prefix, the same products
`restore-keys` would accept. The supervisor keeps them only when GitHub's own
record says that runner ran the seed workflow's job for a push to the default
branch and the job succeeded; a key the job wrote proves nothing by itself.
The products sit in an image no job writes, so each job still starts from a
fresh container and nothing a pull request does reaches another job. The
image holds that repository's build, so a job starts from it only while the
runner group admits that repository and no other; the supervisor checks the
group before every registration.

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

Validation keeps a 30-minute limit on local runners and for consumers without
`SWIFT_BUILD_CACHE=true`. Hosted Swift-cache consumers get 60 minutes: the
measured two-CPU cold build took 20 minutes before tests, so a 30-minute limit
cancelled useful work and forced the next attempt to rebuild it. This is a
ceiling, not a target; backend/concurrency fixes and compatible caches still
reduce the work. Every validation command and spending guard remains in force.

A reusable-workflow caller may explicitly pass `timeout_minutes`, which takes
precedence; its existing default remains 30. Cache producers already passing
60 retain that limit. Required PR, push and merge-queue workflows have no
caller input and select the limit from their runner and Swift-cache settings.
Consumer policy must adopt the reviewed workflow pin before this takes effect.

## Runner

Set the repository variable `BLACKSMITH_LINUX=true` to use Blacksmith's managed
ephemeral 4-vCPU Ubuntu 24.04 runners when `LINUX_RUNNER` does not select a local
pool, including PR and merge-queue validation. Reusable callers can explicitly
select Blacksmith with `blacksmith: true`; that input takes precedence over
the local pool and defaults to false.
Validation planning, final summaries, and review/delivery gates use the gate
selector below; macOS jobs keep their existing routing.

Blacksmith must be installed for the consumer repository and is billed
separately from GitHub; the GitHub usage guard does not govern that bill.
Adopt the reviewed workflow pin before enabling the variable. Existing overflow
routing can retain the local pool as the default and remove its selection when
full; Blacksmith then supplies hosted capacity. Removing the variable restores
GitHub Ubuntu as that fallback without changing validation rules.

Without Blacksmith opt-in, validation reads `LINUX_RUNNER`:

```yaml
runs-on: ${{ vars.LINUX_RUNNER && fromJSON(format(github.event_name == 'merge_group' && '["self-hosted","{0}"]' || '["self-hosted","{0}","{0}-shared"]', vars.LINUX_RUNNER)) || 'ubuntu-latest' }}
```

Outside the merge queue it also requires the label `LINUX_RUNNER-shared`. A
runner registered without it is queue-only: it takes only merge-queue jobs.
GitHub does not hand a freed runner to the job that has waited longest: on
2026-10-20, with three slots, a queue validation waited 26 minutes while freed
slots went to pull requests queued after it (AUT-2704), and a pull request
ships only through the queue.

`runner/linux-runner.sh` chooses each new runner's role when it registers,
from what is waiting for a runner of the fleet (AUT-2757), so the split
follows the load and no count needs tuning. With `LINUX_RUNNER_QUEUE_SLOTS=N`
(0, off, by default; every runner is then shared):

1. queue jobs waiting beyond the idle queue-only runners: the new runner is
   queue-only, so a freed slot goes to the queue first;
2. otherwise a slot among the first `N` stays queue-only, ready for the queue,
   while no pull-request job waits, so no slot idles while pull requests wait;
3. otherwise it is shared and takes anything.

At most `SLOTS-1` runners are queue-only at once, so pull requests always have
a runner, and queue jobs can use a shared one. Every minute, while a
pull-request job waits, idle queue-only runners that no waiting queue job needs
are removed and their slots register again with a fresh role. GitHub refuses to
remove a runner that has a job, so nothing running is cut.

**Stopping drains (AUT-2763).** The first `SIGTERM` or `SIGINT` to the
supervisor (a `launchctl bootout`, or a restart through `linux-runner-admin
apply`) stops registering runners, removes the registrations that have no job,
and lets the jobs that run finish before it exits, so a restart cuts none of
them. A cancelled merge-queue job evicts its entry and the ones behind it. A
second signal stops at once, and the daemon's plist gives the drain
`ExitTimeOut` 5400 s before the service manager kills it. A daemon installed
before this change still has the default 20 s; its first restart is not graceful.

The token the supervisor uses needs **Actions: read** on every repository in
the runner group, in addition to the organization's self-hosted-runner
permission, to see what waits. The supervisor checks at start and says so in
its log; without it, the first `N` slots are queue-only, fixed. Give the
runners the label before a consumer's validation pin requires it, or its
pull-request jobs wait for a runner that never matches.

Validation planning (`plan`), its final summary (`validate`), `review-gate`,
and `delivery-evidence` read `LINUX_GATE_RUNNER`, without the merge-queue split:
`fromJSON(format('["self-hosted","{0}"]', vars.LINUX_GATE_RUNNER))`. They run for seconds, and on one
variable they waited in line behind validations: on a repository with two
runners of its own, 23 minutes on average on 2026-10-11, long enough for
`touchstone pr open` to give up on them (AUT-2452). So a repository that sets
only `LINUX_RUNNER` validates on its own runners and runs its gates on
GitHub-hosted ones, where they start at once and bill a minute each. Set
`LINUX_GATE_RUNNER` as well only when GitHub-hosted jobs cannot start, for
example when the plan's included minutes are used up.

With a variable unset, its jobs run on GitHub-hosted `ubuntu-latest`, exactly
as before. Set, they run on a self-hosted runner with that label, and the
`self-hosted` label is always required, so a variable can never name a hosted
image (AUT-1595). The `source contract` job runs only in
this public repository and stays on `ubuntu-latest` by name.

**Both variables name only single-use runners.** `validate-groups` runs the
candidate's declared commands. On a persistent self-hosted runner, a pull
request could modify the host and reach every later job there, including
`review-gate`, which receives the fallback reviewer's credential
(touchstone-workflows#48). The workflow cannot see whether a runner is
ephemeral, so the guarantee lives where runners are registered:
`runner/linux-runner.sh` is the only thing that registers runners with this
label. For each job it asks GitHub for a just-in-time configuration, which
registers a runner for exactly one job, and starts a fresh container that
holds that configuration and nothing else: no volume, no Docker socket, no
host network, no credential (`tests/test-runner.sh` pins this). The image can
include a default-branch seed's build products (see "Swift build caches");
nothing else from a finished job is ever kept. Never register
a long-lived runner with the label or into its group. Before every
registration the supervisor also checks the group itself: it must be visible
only to selected repositories, closed to public ones, and hold only private
repositories, or nothing is registered.

`LINUX_RUNNER`'s repositories and the runner group's repositories must be the
same set, and `LINUX_GATE_RUNNER`'s, when it is set, must all be among them. A
repository that resolves a variable but is outside the group queues those
jobs forever. A public repository must be in none of them, because it takes
fork pull requests.

### Running the runners (AUT-1596)

On the host: Docker, and `gh` logged in with `admin:org`. Once per
organization, create the group for the private consumers that use it:

```bash
gh api -X POST orgs/autumngarage/actions/runner-groups -f name=linux-ephemeral \
  -f visibility=selected -F allows_public_repositories=false \
  -F 'selected_repository_ids[]=<repository id>'   # one per repository
```

Then, on the host, from a checkout of this repository:

```bash
bash runner/linux-runner.sh build     # the job image, from runner/Dockerfile
bash runner/linux-runner.sh install   # a LaunchAgent that keeps the slots running, under caffeinate
bash runner/linux-runner.sh status
gh variable set LINUX_RUNNER --org autumngarage --visibility selected \
  --repos '<the group repositories, comma-separated>' --body linux-ephemeral
```

`caffeinate -i` keeps the Mac from idle-sleeping while the agent runs; a
closed lid still sleeps it, and queued jobs wait until it wakes. To move the
fleet to another machine, install there and uninstall here
(`bash runner/linux-runner.sh uninstall`); the label does not change. To go
back to GitHub-hosted runners, `gh variable delete LINUX_RUNNER --org
autumngarage`.

#### On a headless Mac that runs other CI too

A LaunchAgent lives in its user's login session, and `admin:org` in a login
keychain is readable by anything that runs as that user. On a Mac that also
hosts a persistent macOS runner, whose jobs run branch code as their own
user, run the fleet at boot as an account that runs nothing else, with a
token only it can read:

1. Create a standard account for the fleet (e.g. `linuxci`) and never log in
   as it. Install Colima and the Docker CLI once (`brew install colima docker`;
   Docker Desktop needs a login session, Colima does not).
2. Create a fine-grained token owned by the organization with one
   organization permission, **Self-hosted runners: read and write**, and write
   it where the daemon reads it, private to the fleet's account:

   ```bash
   sudo -u linuxci -H bash -c 'd="$HOME/Library/Application Support/linux-ephemeral-runner"
     mkdir -p "$d" && umask 077 && cat >"$d/github-token"'   # paste the token, then Ctrl-D
   ```

3. Build the image as that account, from a checkout it can read (the build
   starts the account's Colima VM; `sudo` resets `PATH`, so name Homebrew's),
   then install the daemon:

   ```bash
   sudo -u linuxci -H env PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
     LINUX_RUNNER_ENGINE=colima bash runner/linux-runner.sh build
   sudo bash runner/linux-runner.sh install-daemon linuxci
   bash runner/linux-runner.sh status
   ```

The daemon starts before anyone logs in and after every reboot, starts the
Colima VM if it is down, and keeps the slots running; its log is the
account's `~/Library/Logs/linux-ephemeral-runner.log`. `sudo bash
runner/linux-runner.sh uninstall-daemon` removes it.

A required workflow runs in the consumer repository's context and reads the
variables visible to that repository; a repository variable overrides the
organization's. Confirm on the first run after setting it: the job's "Set up
job" step names the runner that took it. If the organization variable does not
resolve there, set it per repository instead:
`gh variable set LINUX_RUNNER -R autumngarage/<repository> --body linux-ephemeral`.

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

**Queue priority (AUT-2813).** `MACOS_RUNNER_QUEUE_SLOTS` opts the Mac pool
into the same demand-based registration policy as the Linux fleet. It defaults
to `0`. Shared registrations also advertise `ci-studio-pool-shared`; consumers
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
into the same runner group, `macos`, and checks it before every registration
as `linux-runner.sh` does: visible only to selected repositories, and holding
only private ones.

On the Mac, with the account logged in and `ci-studio` registered, give root a
copy of the Linux fleet's token (the same one permission, **Self-hosted
runners: read and write**), then install:

```bash
state="/Library/Application Support/com.autumngarage.macos-pool-runner"
sudo install -d -m 700 -o root -g wheel "$state"
sudo install -m 600 -o root -g wheel \
  "/Users/linuxci/Library/Application Support/linux-ephemeral-runner/github-token" "$state/github-token"
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
