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

## Runner

`review-gate` and `delivery-evidence` take their runner from one selector:

```yaml
runs-on: ${{ vars.LINUX_RUNNER && fromJSON(format('["self-hosted","{0}"]', vars.LINUX_RUNNER)) || 'ubuntu-latest' }}
```

With the `LINUX_RUNNER` variable unset, both run on GitHub-hosted
`ubuntu-latest`, exactly as before. Setting it moves them, in every consumer,
to the self-hosted runner with that label. The `self-hosted` label is always
required as well, so the variable can never name a hosted image (AUT-1595).
Both jobs execute only code pinned here and data read from the API, never the
pull request's code.

`validate` does not take the setting, and neither does the `source contract`
job. Both execute the candidate's code (`validate` runs the target's declared
commands), so each runs on a fresh GitHub-hosted runner every time. On a
persistent self-hosted runner, a pull request could modify the host and reach
every later job there, including `review-gate`, which receives the fallback
reviewer's credential (touchstone-workflows#48). The workflow cannot prove
that a runner is ephemeral, so moving `validate` off hosted runners needs an
ephemeral one-job runner and its own reviewed change.

To move the two gates to a self-hosted runner (Phase 2), register the runner in
a group restricted to the private consumers, then:

```bash
gh variable set LINUX_RUNNER --org autumngarage --visibility private --body '<runner label>'
```

`--visibility private` is load-bearing. The public repositories accept pull
requests from forks, and `validate` executes the candidate's code, so a public
repository must never resolve the variable or reach a persistent runner. Undo
the move with `gh variable delete LINUX_RUNNER --org autumngarage`.

A required workflow runs in the consumer repository's context and reads the
variables visible to that repository; a repository variable overrides the
organization's. Confirm on the first run after setting it: the job's "Set up
job" step names the runner that took it. If the organization variable does not
resolve there, set it per repository instead:
`gh variable set LINUX_RUNNER -R autumngarage/<repository> --body '<runner label>'`.
