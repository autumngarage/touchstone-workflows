# Disposable release-runner operations

This document owns setup and recovery for `macos-release-vm.sh`. The script
is a one-job pilot, not an installed daemon. It does not change workflow
selectors, Google IAM, or the existing macOS test pool.

## Trust boundary

Run the supervisor in a dedicated host account whose files ordinary test
jobs cannot modify. Keep its scripts, tool installation, state, and runner
registration credential outside job-writable directories. The token needs
GitHub's organization **Self-hosted runners: read and write** permission;
use a private token file rather than an interactive GitHub login. The
supervisor deliberately ignores inherited `GH_TOKEN` and `GITHUB_TOKEN`.

Create a separate runner group restricted to selected private repositories
and explicitly selected release workflows. Pin those workflows to reviewed
revisions. Before every registration the script checks that the group is
private, has selected repositories, and has workflow restrictions enabled.
It does not audit the meaning of the selected workflows: reviewing that
allowlist remains part of provisioning.

Use a reviewed macOS image pinned by OCI digest. It must contain a clean
GitHub Actions runner at `/Users/admin/actions-runner`, with no previous
registration, personal credentials, or signing keys. Only a one-use JIT
configuration crosses into the guest over standard input. Host home,
keychain, directories, clipboard, audio, and USB are not attached.

Tart uses Softnet for guest networking. Install a pinned Softnet binary using
its documented privileged setup before starting the supervisor. Softnet
does not mean the guest has no network: validate both allowed egress and
blocked access to sensitive host/LAN services on the actual release host.
Do not weaken Google credential policy until those checks pass.

## Configure and run

Start with [release-vm.env.example](release-vm.env.example), replacing every
placeholder in a private copy. Make the token file mode 600 or 400 and the
state directory mode 700, owned by the supervisor. Keep `jit.sh` next to the
entry script when installing a reviewed revision. Supply Tart, Softnet,
GitHub CLI, and jq through trusted paths. Source the configuration, then run:

```sh
bash /absolute/path/to/runner/macos-release-vm.sh
```

The boot deadline bounds guest readiness. The job deadline includes waiting
for GitHub to assign work. A successful exit means the guest runner exited
successfully and cleanup succeeded; GitHub's workflow conclusion remains
the authority for the job's result. No second guest starts while a lease
exists in the same state directory. Different state directories are not a
machine-wide concurrency limit; provisioning must avoid oversubscribing
Apple's VM limit and the host's memory.

## Failure and recovery

Normal exit, failed commands, boot/job deadlines, and INT/TERM all attempt
guest shutdown, deletion, and GitHub registration removal. A GitHub 404 on
removal means the JIT runner already disappeared. Other cleanup failures
return an error and preserve the lease for inspection. Successful cleanup
removes the lease and its local logs; retain workflow evidence in GitHub.

A killed supervisor or host power loss cannot run an EXIT trap. Startup
therefore refuses an existing lease instead of assuming it is stale. Recovery
is deliberately manual in this pilot:

1. Stop the supervisor's service, if one has been provisioned, and establish
   that its process is no longer running. Do not infer this from file age.
2. Read the private lease's `vm` and optional `runner` files. Inspect its
   `host.log`, `job.log`, and `delete.out` as applicable; job output may contain
   sensitive data. Do not copy unredacted logs into issues.
3. With the same Tart account/storage, stop and delete only that named VM.
   Verify it is absent. Never prune other images or delete another lease.
4. With the supervisor's registration credential, remove that runner ID
   from the configured organization's Actions runners. Confirm absence;
   an API error other than 404 is not proof of removal.
5. Only after both resources are confirmed absent, remove the lease and
   restart the supervisor. Keep the base image for future clean clones.

If registration completed but the supervisor died before recording the ID,
find the runner by the exact unique VM name in the configured organization
and remove it. Preserve the lease until that reconciliation succeeds.

## Rollout evidence required before secrets

Run two sequential real GitHub jobs through this runner without signing
credentials. Verify that a marker and registration from the first guest
are absent in the second, that both guests and registrations are removed,
and that host/LAN isolation works. Exercise interruption and recovery on the
actual host. The Python fixtures cover transport and failure handling; they
do not prove hypervisor/network isolation or GitHub delivery.

Only then review the release-workflow selectors and narrowly scoped workload
identity policy together. Normal releases must work while the operator's
Google CLI credentials are unavailable. Roll back by stopping this pilot
and restoring the previous reviewed workflow selectors/policy; do not route
credential-bearing release jobs to the shared host test pool.
