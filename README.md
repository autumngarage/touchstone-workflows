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
required-check name. Its `gateBehaviorContractVersion` declares the behavior
contract implemented by the pinned workflows. Version 1 means that validation,
review evidence, and delivery evidence are checksum-pinned, read-only required
workflows that run for pull requests and merge groups; the review gate binds
trusted review and answered findings to the PR-event number, head, and base
ref (the base SHA may advance by ancestry), while a merge-group run binds the
queue commit and base to the PR number in its ref.
`tests/test-workflow.sh` refuses missing, extra, nested, or duplicate workflow
declarations, verifies that only the declared publisher owns the status, and
guards those version-1 behavior invariants.

Pull requests land through the repository's merge queue only after the source
contract check passes. Touchstone separately pins each consumer-required
workflow to an immutable commit from this repository.
