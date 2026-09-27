#!/usr/bin/env bash
# One release job in one disposable guest. Registration stays with jit.sh.
# The caller owns the private state directory and token file. A service can
# invoke this again after it exits; failed cleanup always requires attention.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=runner/jit.sh
. "$here/jit.sh"
ORG="${RELEASE_RUNNER_ORG:-autumngarage}"
GROUP="${RELEASE_RUNNER_GROUP:-macos-release}"
LABEL="${RELEASE_RUNNER_LABEL:-macos-release}"
TOKEN_FILE="${RELEASE_RUNNER_TOKEN_FILE:?set a dedicated runner-registration token file}"
IMAGE="${RELEASE_RUNNER_IMAGE:?set an OCI image pinned by sha256}"
STATE="${RELEASE_RUNNER_STATE:?set a private state directory}"
TART="${RELEASE_RUNNER_TART:-tart}"
BOOT_SECONDS="${RELEASE_RUNNER_BOOT_SECONDS:-300}"
JOB_SECONDS="${RELEASE_RUNNER_JOB_SECONDS:-7200}"

case "$IMAGE" in *@sha256:*) ;; *) die 'release image must be pinned by sha256' ;; esac
digest="${IMAGE##*@sha256:}"
[ "${#digest}" -eq 64 ] && [[ "$digest" != *[!a-f0-9]* ]] || die 'invalid image digest'
for seconds in "$BOOT_SECONDS" "$JOB_SECONDS"; do
  case "$seconds" in ''|*[!0-9]*|0) die 'timeouts must be positive seconds' ;; esac
done
need "$TART" 'install the pinned Tart release'
need gh 'install GitHub CLI'
need jq 'install jq'
need softnet 'install the pinned Softnet network-isolation helper'
export TART_NO_AUTO_PRUNE=1
[ ! -L "$STATE" ] || die 'state directory must not be a symlink'
mkdir -p "$STATE"
[ "$(file_owner "$STATE")" = "$(id -un)" ] && [ "$(file_mode "$STATE")" = 700 ] \
  || die 'state directory must be owned by the supervisor and mode 700'
mkdir "$STATE/lease" 2>/dev/null || die 'an existing lease needs cleanup; refusing to start another guest'
lease="$STATE/lease"
name="aster-release-$(uuidgen | tr '[:upper:]' '[:lower:]')"
printf '%s\n' "$name" >"$lease/vm"
runner_id=''
vm_pid=''
job_pid=''
probe_pid=''
created=0

# Invoked by the EXIT trap, including INT/TERM exits.
# shellcheck disable=SC2329
cleanup() {
  local result=$? failed=0
  trap - EXIT INT TERM
  if [ "$created" -eq 1 ]; then
    "$TART" stop "$name" --timeout 30 >>"$lease/host.log" 2>&1 || failed=1
    if [ "$failed" -eq 0 ]; then
      "$TART" delete "$name" >>"$lease/host.log" 2>&1 || failed=1
    fi
  fi
  for pid in "$probe_pid" "$job_pid"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
  if [ "$failed" -eq 0 ]; then
    [ -z "$job_pid" ] || wait "$job_pid" 2>/dev/null || true
    [ -z "$vm_pid" ] || wait "$vm_pid" 2>/dev/null || true
  fi
  if [ -n "$runner_id" ]; then
    # A consumed JIT registration normally disappears itself. Distinguish
    # that from an API outage before reporting successful cleanup.
    if ! gh api -X DELETE "orgs/$ORG/actions/runners/$runner_id" >"$lease/delete.out" 2>&1; then
      grep -q 'HTTP 404' "$lease/delete.out" || failed=1
    fi
  fi
  if [ "$failed" -ne 0 ]; then
    printf 'ERROR: release cleanup incomplete; retained lease %s\n' "$lease" >&2
    exit 1
  fi
  rm -r "$lease"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# No fallback to the person's gh login, even when a credential is missing.
unset GH_TOKEN GITHUB_TOKEN
load_token

gid="$(group_id)"
gh api "orgs/$ORG/actions/runner-groups/$gid" \
  --jq '.restricted_to_workflows == true and (.selected_workflows | length > 0)' \
  | grep -qx true || die 'release runner group must restrict selected workflows'

# Register only after the guest is reachable. No host shares, clipboard,
# audio, or USB devices are attached. Host credentials never enter the guest.
created=1
"$TART" clone "$IMAGE" "$name" >>"$lease/host.log" 2>&1
env -u GH_TOKEN -u GITHUB_TOKEN "$TART" run --no-graphics --no-audio \
  --no-usb-accessories --no-clipboard --net-softnet "$name" >>"$lease/host.log" 2>&1 &
vm_pid=$!
env -u GH_TOKEN -u GITHUB_TOKEN "$TART" exec "$name" /usr/bin/true \
  >>"$lease/host.log" 2>&1 &
probe_pid=$!
deadline=$((SECONDS + BOOT_SECONDS))
while kill -0 "$probe_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ] || ! kill -0 "$vm_pid" 2>/dev/null; then
    kill "$probe_pid" 2>/dev/null || true
    wait "$probe_pid" 2>/dev/null || true
    die 'guest failed to become ready within its boot deadline'
  fi
  sleep 1
done
wait "$probe_pid" || die 'guest readiness command failed'
probe_pid=''

jit="$(request_jit "$name" "$gid")" || die 'JIT registration failed'
runner_id="$(printf '%s' "$jit" | jq -er '.runner.id | select(type == "number")')"
printf '%s\n' "$runner_id" >"$lease/runner"
configuration="$(printf '%s' "$jit" | jq -er '.encoded_jit_config | select(type == "string" and length > 0)')"
unset jit
# Only the one-use configuration crosses stdin. It is never a process argument
# or a host file. The guest receives no org token or interactive credentials.
printf '%s\n' "$configuration" | env -u GH_TOKEN -u GITHUB_TOKEN "$TART" exec -i "$name" \
  /bin/bash -c 'set -euo pipefail; IFS= read -r ACTIONS_RUNNER_INPUT_JITCONFIG; export ACTIONS_RUNNER_INPUT_JITCONFIG; cd /Users/admin/actions-runner; exec ./run.sh' \
  >"$lease/job.log" 2>&1 &
job_pid=$!
unset configuration
deadline=$((SECONDS + JOB_SECONDS))
while kill -0 "$job_pid" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || die 'release job exceeded its deadline'
  kill -0 "$vm_pid" 2>/dev/null || die 'guest stopped before the runner exited'
  sleep 1
done
result=0
wait "$job_pid" || result=$?
job_pid=''
exit "$result"
