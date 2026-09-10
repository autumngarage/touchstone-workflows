#!/usr/bin/env bash
#
# runner/linux-runner.sh -- keep single-use self-hosted Linux runners for the
# required workflows: one throwaway container per job (AUT-1596).
#
# Usage:
#   bash runner/linux-runner.sh build       build the job image from runner/Dockerfile
#   bash runner/linux-runner.sh run         supervise the runner slots in the foreground
#   bash runner/linux-runner.sh install     run them from a macOS LaunchAgent, kept awake
#   bash runner/linux-runner.sh uninstall   stop and remove the LaunchAgent
#   bash runner/linux-runner.sh status      show the agent, containers, and registrations
#
# Each slot asks GitHub for a just-in-time runner configuration, which
# registers a runner for exactly one job, starts a fresh container from the
# job image with that configuration, and waits for it to exit. The container
# receives the single-use configuration and nothing else: no volume, no Docker
# socket, no host network, no credential. Nothing a job does outlives its
# container, which is what lets `validate` -- it runs the candidate's declared
# commands -- use these runners at all (see "Runner" in README.md).
#
# Configuration, from the environment (defaults in parentheses):
#   LINUX_RUNNER_ORG      organization (autumngarage)
#   LINUX_RUNNER_GROUP    runner group, restricted to the private consumers (linux-ephemeral)
#   LINUX_RUNNER_LABEL    the label the LINUX_RUNNER variable names (linux-ephemeral)
#   LINUX_RUNNER_SLOTS    jobs run at once (2)
#   LINUX_RUNNER_MEMORY   memory limit per job container (6g)
#   LINUX_RUNNER_CPUS     CPU limit per job container (4)
#   LINUX_RUNNER_PIDS     process limit per job container (4096): a pull
#                         request that forks without end exhausts its own
#                         container, not the VM every slot shares
#   LINUX_RUNNER_IMAGE    job image tag (linux-ephemeral-runner:local)
#
# The host needs docker and a gh login with admin:org. The token is used here
# to register runners and never enters a container.
#
# Runs under macOS's /bin/bash 3.2: no associative arrays, mapfile, or wait -n.

set -euo pipefail

ORG="${LINUX_RUNNER_ORG:-autumngarage}"
GROUP="${LINUX_RUNNER_GROUP:-linux-ephemeral}"
LABEL="${LINUX_RUNNER_LABEL:-linux-ephemeral}"
SLOTS="${LINUX_RUNNER_SLOTS:-2}"
MEMORY="${LINUX_RUNNER_MEMORY:-6g}"
CPUS="${LINUX_RUNNER_CPUS:-4}"
PIDS="${LINUX_RUNNER_PIDS:-4096}"
IMAGE="${LINUX_RUNNER_IMAGE:-linux-ephemeral-runner:local}"
# A test seam and a one-shot probe: stop each slot after this many jobs. Unset
# (the default) means forever.
MAX_JOBS="${LINUX_RUNNER_MAX_JOBS:-}"
BACKOFF_START=15
BACKOFF_MAX=300
AGENT_ID="com.autumngarage.linux-ephemeral-runner"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_dir="${LINUX_RUNNER_STATE_DIR:-$HOME/Library/Application Support/linux-ephemeral-runner}"
host="$(hostname -s 2>/dev/null || hostname)"
prefix="$LABEL-$host"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "$SLOTS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_SLOTS must be a positive integer, not '$SLOTS'" ;; esac
case "$MAX_JOBS" in *[!0-9]*) die "LINUX_RUNNER_MAX_JOBS must be a non-negative integer, not '$MAX_JOBS'" ;; esac
case "$PIDS" in '' | *[!0-9]* | 0) die "LINUX_RUNNER_PIDS must be a positive integer, not '$PIDS'" ;; esac

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH; $2"
}

# The one runner group this fleet registers into. Exactly one must exist:
# registering into the wrong group would offer these runners to repositories
# the group was meant to exclude.
group_id() {
  local ids count
  ids="$(gh api --paginate "orgs/$ORG/actions/runner-groups" \
    --jq ".runner_groups[] | select(.name == \"$GROUP\") | .id")" \
    || die "could not list $ORG's runner groups; check 'gh auth status' for admin:org"
  count="$(printf '%s\n' "$ids" | grep -c '[0-9]' || true)"
  [ "$count" -eq 1 ] || die "expected one runner group named '$GROUP' in $ORG, found $count; create it as README.md \"Runner\" describes"
  printf '%s\n' "$ids"
}

# Best effort: GitHub removes a single-use runner after its job, so a 404 here
# is the normal case. A runner that never took a job would otherwise stay
# registered, offline, until GitHub expires it.
forget_runner() {
  local id="$1"
  [ -n "$id" ] || return 0
  gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null 2>&1 || true
}

run_slot() {
  local slot="$1" gid="$2" backoff="$BACKOFF_START" jobs=0
  local name response jit id started rc
  while :; do
    if [ -n "$MAX_JOBS" ] && [ "$jobs" -ge "$MAX_JOBS" ]; then
      return 0
    fi
    name="$prefix-$slot-$(date +%s)"
    # A just-in-time registration gets only the labels it is given, not the
    # defaults config.sh adds, and every workflow selector requires both.
    if ! response="$(gh api -X POST "orgs/$ORG/actions/runners/generate-jitconfig" \
      -f name="$name" -F runner_group_id="$gid" -f "labels[]=self-hosted" -f "labels[]=$LABEL" \
      -f work_folder=_work 2>&1)"; then
      log "slot $slot: could not register a runner ($response); retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    jit="$(printf '%s' "$response" | jq -r '.encoded_jit_config // empty')"
    id="$(printf '%s' "$response" | jq -r '.runner.id // empty')"
    if [ -z "$jit" ] || [ -z "$id" ]; then
      log "slot $slot: GitHub returned no runner configuration; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
      continue
    fi
    printf '%s %s\n' "$id" "$name" >"$state_dir/slot-$slot"
    log "slot $slot: runner $name ($id) is waiting for a job"
    started="$(date +%s)"
    rc=0
    docker run --rm --init --name "$name" \
      --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS" --pull never \
      "$IMAGE" ./run.sh --jitconfig "$jit" || rc=$?
    forget_runner "$id"
    rm -f "$state_dir/slot-$slot"
    jobs=$((jobs + 1))
    log "slot $slot: runner $name exited ($rc) after $(($(date +%s) - started))s"
    # A container that dies at once (a missing image, a daemon that is down)
    # would otherwise register and discard runners in a tight loop.
    if [ "$rc" -ne 0 ] && [ $(($(date +%s) - started)) -lt 30 ]; then
      log "slot $slot: the container failed immediately; retrying in ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2 > BACKOFF_MAX ? BACKOFF_MAX : backoff * 2))
    else
      backoff="$BACKOFF_START"
    fi
  done
}

# On stop, take down this host's job containers and the registrations that
# have not taken a job yet, so nothing is left waiting for work.
stop_slots() {
  local file id name
  trap - INT TERM
  for file in "$state_dir"/slot-*; do
    [ -f "$file" ] || continue
    read -r id name <"$file" || true
    docker rm -f "$name" >/dev/null 2>&1 || true
    forget_runner "$id"
    rm -f "$file"
  done
  kill 0 2>/dev/null || true
}

cmd_run() {
  local gid slot
  need docker "install Docker Desktop"
  need gh "install the GitHub CLI and log in with admin:org"
  need jq "install jq"
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image $IMAGE is missing; run 'bash runner/linux-runner.sh build' first"
  gid="$(group_id)"
  mkdir -p "$state_dir"
  trap stop_slots INT TERM
  log "supervising $SLOTS slot(s) for label $LABEL in $ORG runner group $GROUP ($gid)"
  slot=1
  while [ "$slot" -le "$SLOTS" ]; do
    run_slot "$slot" "$gid" &
    slot=$((slot + 1))
  done
  wait
}

cmd_build() {
  need docker "install Docker Desktop"
  docker build -t "$IMAGE" -f "$here/Dockerfile" "$here"
}

plist_path() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$AGENT_ID"; }

cmd_install() {
  local installed plist log_file path_value
  need launchctl "install needs macOS launchd"
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "image $IMAGE is missing; run 'bash runner/linux-runner.sh build' first"
  group_id >/dev/null
  mkdir -p "$state_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  # A copy, so a checkout that later switches branches cannot change what runs.
  installed="$state_dir/linux-runner.sh"
  cp "$here/linux-runner.sh" "$installed"
  plist="$(plist_path)"
  log_file="$HOME/Library/Logs/linux-ephemeral-runner.log"
  path_value="$(dirname "$(command -v docker)"):$(dirname "$(command -v gh)"):$(dirname "$(command -v jq)"):/usr/bin:/bin:/usr/sbin:/sbin"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-i</string>
    <string>/bin/bash</string>
    <string>$installed</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$path_value</string>
    <key>LINUX_RUNNER_ORG</key><string>$ORG</string>
    <key>LINUX_RUNNER_GROUP</key><string>$GROUP</string>
    <key>LINUX_RUNNER_LABEL</key><string>$LABEL</string>
    <key>LINUX_RUNNER_SLOTS</key><string>$SLOTS</string>
    <key>LINUX_RUNNER_MEMORY</key><string>$MEMORY</string>
    <key>LINUX_RUNNER_CPUS</key><string>$CPUS</string>
    <key>LINUX_RUNNER_PIDS</key><string>$PIDS</string>
    <key>LINUX_RUNNER_IMAGE</key><string>$IMAGE</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$log_file</string>
  <key>StandardErrorPath</key><string>$log_file</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" \
    || die "launchctl could not load $plist"
  log "installed $AGENT_ID; logs in $log_file"
}

cmd_uninstall() {
  need launchctl "uninstall needs macOS launchd"
  launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
  rm -f "$(plist_path)"
  log "removed $AGENT_ID"
}

cmd_status() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl print "gui/$(id -u)/$AGENT_ID" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) =' \
      || echo "agent $AGENT_ID is not loaded"
  fi
  docker ps --filter "name=$prefix-" --format '{{.Names}}  {{.Status}}'
  gh api --paginate "orgs/$ORG/actions/runners" \
    --jq ".runners[] | select(any(.labels[]; .name == \"$LABEL\")) | \"\(.name)  \(.status)  busy=\(.busy)\""
}

case "${1:-}" in
  build) cmd_build ;;
  run) cmd_run ;;
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  *)
    sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
