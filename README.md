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
`gateBehaviorContractVersion` declares the behavior
contract implemented by the pinned workflows. Version 3 means that
validation, review evidence, and delivery evidence are checksum-pinned,
read-only required workflows with aligned refresh triggers that run for pull
requests and merge groups; the review gate derives one trusted reviewer
verdict for the exact current PR head — only an unedited, explicit clean
result succeeds — and never adjudicates historical findings: threads belong
to GitHub conversation resolution and the merged result to the merge queue
(AUT-1132). A merge-group run binds the queue commit and base to the PR
number in its ref and evaluates once, without waiting. Pull-request review
gates poll only evaluator-declared waiting states until their bounded
deadline. Evidence collection is O(pages of current surfaces): every REST
path crosses an enforced 12-request evaluation limit with a four-page bound
per surface, independent of how much review history the pull request
carries. The five-minute cadence budgets for three concurrent waiting pull
requests at that limit (432 requests/hour), leaving more than half of the
standard repository token's hourly API budget for unrelated work. Evidence
that exceeds a bound fails closed. Terminal failures and merge-group runs
remain immediate.
`tests/test-workflow.sh` refuses missing, extra, nested, or duplicate
workflow declarations, verifies that only the declared publisher owns the
status, refuses engine-pin drift between the manifest and consumer workflow,
and guards those version-3 behavior invariants.

Pull requests land through the repository's merge queue only after the source
contract check passes. Touchstone separately pins each consumer-required
workflow to an immutable commit from this repository.

## Hosted-runner check

`validate` refuses a consumer pull request whose workflows name a
GitHub-hosted macOS or Windows image, or take a runner from a setting without
also requiring the `self-hosted` label (AUT-1592). A macOS minute consumes
about ten included Actions minutes, and a Windows minute about two. The program
is embedded in the `Refuse GitHub-hosted macOS and Windows runners` step and
pinned with the workflow. `tests/test-hosted-runners.sh` extracts it and runs
it against fixtures. It needs Ruby, which `ubuntu-latest` ships and
`runner/Dockerfile` installs.

## Runner

Every consumer job (`validate`, `review-gate`, `delivery-evidence`) takes its
runner from one selector:

```yaml
runs-on: ${{ vars.LINUX_RUNNER && fromJSON(format('["self-hosted","{0}"]', vars.LINUX_RUNNER)) || 'ubuntu-latest' }}
```

With the `LINUX_RUNNER` variable unset, every job runs on GitHub-hosted
`ubuntu-latest`, exactly as before. Set, it runs on a self-hosted runner with
that label, and the `self-hosted` label is always required, so the variable can
never name a hosted image (AUT-1595). The `source contract` job runs only in
this public repository and stays on `ubuntu-latest` by name.

**`LINUX_RUNNER` names only single-use runners.** `validate` runs the
candidate's declared commands. On a persistent self-hosted runner, a pull
request could modify the host and reach every later job there, including
`review-gate`, which receives the fallback reviewer's credential
(touchstone-workflows#48). The workflow cannot see whether a runner is
ephemeral, so the guarantee lives where runners are registered:
`runner/linux-runner.sh` is the only thing that registers runners with this
label. For each job it asks GitHub for a just-in-time configuration, which
registers a runner for exactly one job, and starts a fresh container that
holds that configuration and nothing else: no volume, no Docker socket, no
host network, no credential (`tests/test-runner.sh` pins this). Never register
a long-lived runner with the label or into its group. Before every
registration the supervisor also checks the group itself: it must be visible
only to selected repositories, closed to public ones, and hold only private
repositories, or nothing is registered.

The variable's repositories and the runner group's repositories must be the
same set. A repository that resolves the variable but is outside the group
queues its jobs forever. A public repository must be in neither, because it
takes fork pull requests.

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

A required workflow runs in the consumer repository's context and reads the
variables visible to that repository; a repository variable overrides the
organization's. Confirm on the first run after setting it: the job's "Set up
job" step names the runner that took it. If the organization variable does not
resolve there, set it per repository instead:
`gh variable set LINUX_RUNNER -R autumngarage/<repository> --body linux-ephemeral`.
