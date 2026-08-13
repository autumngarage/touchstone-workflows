# Touchstone Workflows

Protected source for organization-required GitHub Actions workflows. Target
repositories execute these workflows from immutable commit SHAs, so a pull
request cannot weaken its own merge gate by editing a same-named local file.

Changes to `main` require a pull request. Touchstone's audited GitHub policy
owns which source repository, path, and full commit SHA are required.
