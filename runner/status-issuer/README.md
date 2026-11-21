# Native admission credential renewal

This is the credential owner for the optional PC native-admission controller.
It extends the existing Studio launchd and outbound SSH deployment pattern;
it does not run a network service. The dedicated admission App's key remains
on Studio. The PC receives only a short-lived installation token. The gateway's
verdict App and release credentials are separate owners and must not be reused.

GitHub [installation tokens expire after one hour](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
The pinned [Octokit App authentication](https://github.com/octokit/auth-app.js)
and request packages own JWT signing and GitHub transport. Versions and the
supported Node runtime are declared in [package.json](package.json); the
lockfile pins the dependency tree. Studio's deployed Node was checked for
compatibility before adoption. Install dependencies with
`npm ci --prefix runner/status-issuer --ignore-scripts --no-audit --no-fund`.

Each invocation independently verifies the App key with `GET /app`, its public
bot identity with `GET /users/{username}`, and the pinned installation on the
one repository. The App installation must have exactly Actions, Contents and
Pull requests read, Commit statuses write, and GitHub's implicit Metadata read.
Minting explicitly requests that permission set and repository's numeric ID;
the returned token's permissions, private repository and expiry must agree.
The installation token is not authenticated through `/user`.

The launch agent runs once at load and every 20 minutes, leaving two normal
refresh opportunities before expiry. launchd does not overlap the same job.
Every invocation mints afresh, bounds each API request and SSH delivery, and
exits. Failure emits a sanitized infrastructure error and leaves the prior
credential intact; the next invocation retries. There is no per-candidate
GitHub Actions job or paid timer. Token expiry never authorizes a fallback to
a personal credential. The controller refuses a credential within 60 seconds
of expiry, preserves local intent/leases and uses its existing infrastructure
failure path. Renewal restores subsequent API requests without restarting a
healthy controller. A stopped controller must be restarted by its existing
service policy after its activation inputs are valid.

The dedicated SSH transport key has no remote shell, forwarding, PTY or
caller-selected command. The reviewed forced-command receiver accepts only a
bounded JSON envelope on stdin and writes only its fixed credential path.
It checks committed Bot identity, repository, exact permissions and expiry,
refuses stale delivery, and atomically replaces the private file under an
exclusive nonblocking lock. Neither token nor App key is an argument or log
field. Every controller API call reloads and validates the envelope. Raw-token
files from the earlier inert bundle are deliberately refused: this is a
versioned credential boundary, and the example config names the new path.

## Qualification and installation

`node runner/status-issuer/renew.mjs --install-dry-run` prints the exact inert
file/transport plan. It does not read a key, install a file, create an App or
load a launch agent. [config.example.json](config.example.json) names all
private inputs. The reviewed routing policy intentionally has no issuer until
the dedicated App and observed numeric bot identity are qualified. A missing
issuer refuses issuance and native activation.

The operator owns the already-prepared App registration, dedicated transport
key and host-key verification. Provision no credentials and enable no timer
until that App and the protected native build are qualified. At installation:

1. Retain the prior source SHA, hashes, controller config, unit/drop-in files,
   loaded-service state and existing qualification receipts outside the new
   bundle. This unit does not overwrite or discard those receipts.
2. Install the same reviewed source revision on Studio and PC. Keep Studio
   config, App key and SSH identity owner-private; pin the PC host key in the
   dedicated known-hosts file. Do not use Studio's administrative SSH key.
3. Install the receiver as root-owned, nonwritable code. Create its fixed
   directory as `linuxci`, mode `0700`. Add only the dedicated public transport
   key to that user's authorized keys with the exact options in the dry-run
   plan. Use existing sshd; no new inbound service is needed.
4. After qualification permits it, perform one foreground renewal, verify the
   private envelope and expiry without displaying its token, and verify a real
   status creator agrees with the committed App Bot identity. Then install/load
   the supplied user launch agent. Keep native admission disabled until its
   separate activation checks and real workload receipt pass.

Rollback disables native intake first, unloads only this launch agent, removes
only its authorized-key entry, and revokes the dedicated installation/key as
appropriate. Restore the retained reviewed bundle/config and service state;
do not restore an expired token or affect release slots. App-key rotation
replaces Studio's private file atomically; the next invocation reads it anew.
After an outage longer than token lifetime, foreground renewal (or the next
scheduled invocation) replaces an expired envelope. Malformed/foreign files
require inspection rather than silent replacement.

The source fixtures exercise the real pinned Octokit signing/request path
with an in-memory test key and fake HTTP transport, plus scope, expiry,
transport failure, delayed delivery, atomic failure and recovery. Real App
issuance, restricted SSH installation and unattended renewal remain deployment
qualification: they cannot be claimed while the App does not exist.
